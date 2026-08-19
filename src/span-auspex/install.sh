#!/usr/bin/env bash
# Auspex Dev Container Feature installer. Runs once as root during the feature-install phase: it places
# an auspex binary on PATH from a PLUGGABLE source (URL or in-container path — distribution is
# intentionally undecided), persists the resolved options for the lifecycle hooks, and drops the
# lifecycle helper. The actual per-user wiring + supervision happens later in onCreate/postStart, which
# run as the container user (see lifecycle.sh).
set -euo pipefail

BINARY_URI="${BINARYURI:-}"
VERSION="${VERSION:-}"
VERIFY="${VERIFY:-cosign}"
FEATURE_HOME="${AUSPEXHOME:-}"
DEVICE_ID="${DEVICEID:-}"
TOKEN_FILE="${TOKENFILE:-}"
HOOK_SCOPE="${HOOKSCOPE:-user}"

# Destinations are env-overridable ONLY to make the download+verify path testable off-root (the
# verify regression harness points them at a temp dir); the feature never sets them, so a real
# install lands at the canonical /usr/local paths.
SHARE_DIR="${AUSPEX_SHARE_DIR:-/usr/local/share/auspex}"
BIN_DEST="${AUSPEX_BIN_DEST:-/usr/local/bin/auspex}"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

# Pinned keyless-signing identity for the auspex release workflow — the binary SIGNER lives in the private
# Attuned-Corp/auspex repo, so this stays in LOCK-STEP with that repo's .goreleaser.yaml `signs` comment +
# release.yml verify step, and this repo's README.md (ADR 0033 §4/§5): the cert identity is anchored (^…$)
# and dot-escaped to the auspex release workflow on a SEMVER tag ref (incl. an
# optional pre-release, e.g. v1.2.3 / v0.0.1-rc1), owner matched case-insensitively. Anchoring to semver —
# not any v* tag — keeps the trust surface to the tag shapes the release actually cuts.
COSIGN_IDENTITY_RE='^https://github\.com/(?i:attuned-corp)/auspex/\.github/workflows/release\.yml@refs/tags/v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'
COSIGN_OIDC_ISSUER='https://token.actions.githubusercontent.com'

# Self-provisioned cosign (verify: cosign, the default): the check no longer needs a pre-installed CLI. When
# cosign is not already on PATH we download a PINNED release binary and verify it against a hardcoded per-arch
# SHA-256 — the pinned hash is the trust anchor, and it ships inside this (already-trusted) Feature. Keep
# COSIGN_VERSION in LOCK-STEP with the SIGNER, auspex/Makefile.setup.mk COSIGN_VERSION (the release workflow
# signs with that version); bump the version + BOTH hashes + trusted_root.json together — see
# this repo's README.md "Updating the pinned cosign / trust root".
COSIGN_VERSION='v3.1.2'
COSIGN_SHA256_amd64='f7622ed3cf22e55e1ae6377c080979ff77a22da9981c11df222a2e444991e7cf'
COSIGN_SHA256_arm64='90e7ae0b5dfd60f20816b52c012addf7fc055ebcc7bea4ce81c428ca8518c302'
COSIGN_BASE_URL="${AUSPEX_COSIGN_BASE_URL:-https://github.com/sigstore/cosign/releases/download}"
# Pinned Sigstore trust root, shipped beside this script. cosign v3 verifies the new-format bundle's embedded
# Rekor inclusion proof against these keys, so verify: cosign is FULLY LOCAL — no TUF, no Rekor network.
TRUSTED_ROOT="${SRC_DIR}/trusted_root.json"

# Download caps (defense-in-depth against a hung / oversized origin during the container build). The ceiling
# comfortably covers the auspex binary and the ~150 MB cosign release binary.
FETCH_MAX_TIME="${AUSPEX_FETCH_MAX_TIME:-300}"
FETCH_MAX_BYTES="${AUSPEX_FETCH_MAX_BYTES:-524288000}" # 500 MiB

mkdir -p "$SHARE_DIR"

if [ -z "$BINARY_URI" ]; then
  echo "auspex feature: option 'binaryUri' is required — set it to an http(s):// URL or a path to the auspex binary already present in the container." >&2
  echo "auspex feature: distribution is intentionally pluggable and has no default source yet (see this Feature's README)." >&2
  exit 1
fi

# A single URL template can pin a release: the literal {{version}} token is replaced with the version option.
# Fail CLOSED if the template is used without a concrete version (there is no mutable `latest` alias on the
# download host — the layout is /releases/<tag>/… — so an empty version would resolve to a 404 path).
case "$BINARY_URI" in
  *'{{version}}'*)
    if [ -z "$VERSION" ]; then
      echo "auspex feature: binaryUri uses the {{version}} token but no 'version' was set — set 'version' to a release tag (e.g. v0.1.0). There is no 'latest' alias on the download host." >&2
      exit 1
    fi
    ;;
esac
BINARY_URI="${BINARY_URI//\{\{version\}\}/$VERSION}"

case "$VERIFY" in
  checksum | cosign | none) ;;
  *)
    echo "auspex feature: option 'verify' must be one of checksum|cosign|none (got '${VERIFY}')" >&2
    exit 1
    ;;
esac

# True for a loopback URL (the dev/CI fixture harness serves over http on 127.0.0.1/localhost/::1). Loopback
# never leaves the host, so it is the ONE http source allowed; every real source must be https (see fetch).
is_loopback_url() {
  case "$1" in
    http://127.0.0.1 | http://127.0.0.1:* | http://127.0.0.1/* | \
      http://localhost | http://localhost:* | http://localhost/* | \
      'http://[::1]' | 'http://[::1]:'* | 'http://[::1]/'*) return 0 ;;
    *) return 1 ;;
  esac
}

fetch() { # <url> <out> — download via curl or wget; non-zero on any HTTP/transport error.
  # HTTPS-only with NO protocol downgrade on redirect: a security agent must never fetch its own binary (or
  # its checksum/signature/cosign) over cleartext, and an https→http redirect must fail closed. http is
  # permitted ONLY for loopback (the fixture harness). Time + size caps bound a hung/oversized origin.
  local url="$1" out="$2"
  case "$url" in
    https://*) ;;
    http://*) is_loopback_url "$url" || {
      echo "auspex feature: refusing to fetch over cleartext http (non-loopback): ${url} — use https" >&2
      return 1
    } ;;
    *)
      echo "auspex feature: unsupported URL scheme for ${url} — only https (or loopback http) is allowed" >&2
      return 1
      ;;
  esac
  if command -v curl >/dev/null 2>&1; then
    # --proto/--proto-redir pin the transport to https for a real (non-loopback) source and block a
    # downgrade redirect; loopback http needs http in the allowed set.
    if case "$url" in https://*) true ;; *) false ;; esac; then
      curl -fsSL --proto '=https' --proto-redir '=https' --max-time "$FETCH_MAX_TIME" --max-filesize "$FETCH_MAX_BYTES" "$url" -o "$out"
    else
      curl -fsSL --proto '=http' --max-time "$FETCH_MAX_TIME" --max-filesize "$FETCH_MAX_BYTES" "$url" -o "$out"
    fi
  elif command -v wget >/dev/null 2>&1; then
    if case "$url" in https://*) true ;; *) false ;; esac; then
      wget -q --https-only --timeout="$FETCH_MAX_TIME" -O "$out" "$url"
    else
      wget -q --timeout="$FETCH_MAX_TIME" -O "$out" "$url"
    fi
  else
    echo "auspex feature: neither curl nor wget is available to download from ${url}" >&2
    exit 1
  fi
}

sha256_of() { # <file> — bare hex digest, using whichever tool the base image ships.
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    echo "auspex feature: no sha256sum/shasum available to verify the download — install one or set verify: none" >&2
    exit 1
  fi
}

# Default integrity check: fetch the adjacent <binaryUri>.sha256 sidecar (the publish pipeline emits it
# next to the raw binary, ADR 0045) and fail CLOSED on any mismatch or a missing sidecar — an unverified
# download is refused rather than installed. The sidecar is `<digest>  auspex` (GoReleaser/shasum style),
# so the first field is the expected digest.
verify_sha256() { # <file> <url>
  local file="$1" url="$2" sumtmp expected got
  sumtmp="$(mktemp)"
  if ! fetch "${url}.sha256" "$sumtmp"; then
    rm -f "$sumtmp"
    echo "auspex feature: could not fetch the checksum sidecar ${url}.sha256 — refusing to install an unverified binary (set verify: none to override)" >&2
    exit 1
  fi
  expected="$(awk 'NR==1{print $1}' "$sumtmp")"
  rm -f "$sumtmp"
  got="$(sha256_of "$file")"
  if [ -z "$expected" ] || [ "$expected" != "$got" ]; then
    echo "auspex feature: SHA-256 mismatch for ${url} (expected '${expected:-<empty>}', got '${got}') — refusing to install" >&2
    exit 1
  fi
  echo "auspex feature: SHA-256 verified (${got})"
}

# Provision a cosign CLI for verify: cosign. Prefer one already on PATH; otherwise download the PINNED
# release binary and verify it against the hardcoded per-arch SHA-256 BEFORE using it (fail closed) — that
# pinned hash, shipped in this trusted Feature, is the trust anchor the whole default check bottoms out in.
# Echoes nothing; sets COSIGN_BIN (and COSIGN_CLEANUP for a downloaded one). cosign is a static Go binary,
# so the downloaded one works on glibc and musl/Alpine alike.
COSIGN_BIN=""
COSIGN_CLEANUP=""
ensure_cosign() {
  if command -v cosign >/dev/null 2>&1; then
    COSIGN_BIN="cosign"
    return 0
  fi
  local os arch expected
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  if [ "$os" != "linux" ]; then
    echo "auspex feature: verify: cosign auto-provisions a Linux cosign binary; on '${os}' install cosign yourself (it will be used) or use verify: checksum" >&2
    exit 1
  fi
  case "$(uname -m)" in
    x86_64 | amd64) arch="amd64"; expected="$COSIGN_SHA256_amd64" ;;
    aarch64 | arm64) arch="arm64"; expected="$COSIGN_SHA256_arm64" ;;
    *)
      echo "auspex feature: no pinned cosign for CPU '$(uname -m)' — pre-install cosign on PATH, or use verify: checksum" >&2
      exit 1
      ;;
  esac
  local url tmp got
  url="${COSIGN_BASE_URL}/${COSIGN_VERSION}/cosign-linux-${arch}"
  tmp="$(mktemp)"
  echo "auspex feature: provisioning pinned cosign ${COSIGN_VERSION} (linux/${arch})"
  if ! fetch "$url" "$tmp"; then
    rm -f "$tmp"
    echo "auspex feature: failed to download cosign ${COSIGN_VERSION} from ${url} — verify: cosign needs egress to github.com (or pre-install cosign / use verify: checksum)" >&2
    exit 1
  fi
  got="$(sha256_of "$tmp")"
  if [ "$got" != "$expected" ]; then
    rm -f "$tmp"
    echo "auspex feature: pinned cosign SHA-256 mismatch (expected ${expected}, got ${got}) — refusing to use a tampered cosign" >&2
    exit 1
  fi
  chmod 0755 "$tmp"
  COSIGN_BIN="$tmp"
  COSIGN_CLEANUP="$tmp"
}

# Provenance check (verify: cosign — the DEFAULT): the raw binary carries no per-file signature, but its
# digest is in the version-root checksums.txt, and THAT file is cosign-signed by the release workflow (ADR
# 0033 §4/§5). So: provision cosign (above), derive the version root from the path-encoded binaryUri
# (.../releases/<v>/<os>/<arch>/auspex → strip <os>/<arch>/<binary>), keyless-verify checksums.txt against
# the pinned identity + the pinned trusted_root.json (FULLY LOCAL — cosign v3 checks the new-format bundle's
# embedded Rekor inclusion proof against the shipped keys, no TUF/Rekor network), then confirm the
# downloaded binary's digest is a line in that now-trusted file. No name-guessing: a digest membership
# check is version/arch-agnostic and survives verify running before the binary is renamed.
verify_cosign() { # <file> <url>
  local file="$1" url="$2" root checks bundle got
  ensure_cosign
  if [ ! -f "$TRUSTED_ROOT" ]; then
    echo "auspex feature: missing pinned trust root at ${TRUSTED_ROOT} — this Feature checkout is incomplete; reinstall it or use verify: checksum" >&2
    exit 1
  fi
  root="$(dirname "$(dirname "$(dirname "$url")")")"
  checks="$(mktemp)"
  bundle="$(mktemp)"
  if ! fetch "${root}/checksums.txt" "$checks" || ! fetch "${root}/checksums.txt.cosign.bundle" "$bundle"; then
    rm -f "$checks" "$bundle"
    echo "auspex feature: could not fetch ${root}/checksums.txt(.cosign.bundle) — is this a signed release published under the ADR 0045 layout?" >&2
    exit 1
  fi
  if ! "$COSIGN_BIN" verify-blob \
    --bundle "$bundle" \
    --trusted-root "$TRUSTED_ROOT" \
    --certificate-identity-regexp "$COSIGN_IDENTITY_RE" \
    --certificate-oidc-issuer "$COSIGN_OIDC_ISSUER" \
    "$checks" >/dev/null 2>&1; then
    rm -f "$checks" "$bundle"
    echo "auspex feature: cosign FAILED to verify ${root}/checksums.txt against the pinned release identity — refusing to install" >&2
    exit 1
  fi
  got="$(sha256_of "$file")"
  if ! grep -q -- "$got" "$checks"; then
    rm -f "$checks" "$bundle"
    echo "auspex feature: the binary's digest ${got} is not present in the cosign-verified checksums.txt — refusing to install" >&2
    exit 1
  fi
  rm -f "$checks" "$bundle"
  [ -n "$COSIGN_CLEANUP" ] && rm -f "$COSIGN_CLEANUP"
  echo "auspex feature: cosign-verified (checksums.txt signed by the release workflow; binary digest present)"
}

case "$BINARY_URI" in
  http://* | https://*)
    # https only for a real source; http is refused unless loopback (the dev/CI fixture). A security agent
    # must not fetch its own binary over cleartext.
    case "$BINARY_URI" in
      http://*)
        is_loopback_url "$BINARY_URI" || {
          echo "auspex feature: binaryUri must be https:// (got a cleartext http:// URL) — refusing to fetch the agent binary over the network in cleartext. Use https, or an in-container path." >&2
          exit 1
        }
        ;;
    esac
    echo "auspex feature: downloading binary from ${BINARY_URI}"
    # Download to a temp file and verify BEFORE it becomes the on-PATH binary — a tampered or truncated
    # download must never be chmod +x'd into place. Only a passing (or explicitly disabled) verification
    # promotes it to BIN_DEST.
    dl_tmp="$(mktemp)"
    fetch "$BINARY_URI" "$dl_tmp"
    case "$VERIFY" in
      none)
        echo "auspex feature: verify: none — installing WITHOUT integrity verification (not recommended for a remote source)" >&2
        ;;
      checksum)
        verify_sha256 "$dl_tmp" "$BINARY_URI"
        ;;
      cosign)
        verify_sha256 "$dl_tmp" "$BINARY_URI"
        verify_cosign "$dl_tmp" "$BINARY_URI"
        ;;
    esac
    mv "$dl_tmp" "$BIN_DEST"
    ;;
  *)
    # A plain in-container path is a locally-present, already-trusted artifact — no network fetch, so the
    # verify option does not apply (there is no sidecar to check and nothing was downloaded).
    echo "auspex feature: copying binary from path ${BINARY_URI}"
    if [ ! -f "$BINARY_URI" ]; then
      echo "auspex feature: binaryUri path '${BINARY_URI}' does not exist in the container" >&2
      exit 1
    fi
    cp "$BINARY_URI" "$BIN_DEST"
    ;;
esac
chmod 0755 "$BIN_DEST"

# Persist the resolved options for the lifecycle hooks. They run as the container user (not root), so
# this file is how onCreate/postStart learn the binary path, the home override, and the pinned device id.
# feature.env is SOURCED by lifecycle.sh (`. feature.env`), so every value must be SHELL-QUOTED: a bare
# `echo AUSPEX_FEATURE_HOME=/home/my user` would set the var to `/home/my` and try to run `user` as a
# command on source — silently truncating the home the daemon uses while the hooks (published below) get
# the full one, the exact home-divergence this feature closes. %q emits a bash-safe token that round-trips
# through sourcing verbatim for any value (spaces, metacharacters).
{
  printf 'AUSPEX_BIN=%q\n' "$BIN_DEST"
  printf 'AUSPEX_FEATURE_VERSION=%q\n' "$VERSION"
  printf 'AUSPEX_FEATURE_HOOK_SCOPE=%q\n' "$HOOK_SCOPE"
  [ -n "$FEATURE_HOME" ] && printf 'AUSPEX_FEATURE_HOME=%q\n' "$FEATURE_HOME"
  [ -n "$DEVICE_ID" ] && printf 'AUSPEX_FEATURE_DEVICE_ID=%q\n' "$DEVICE_ID"
  [ -n "$TOKEN_FILE" ] && printf 'AUSPEX_FEATURE_TOKEN_FILE=%q\n' "$TOKEN_FILE"
} >"$SHARE_DIR/feature.env"
chmod 0644 "$SHARE_DIR/feature.env"

install -m 0755 "$SRC_DIR/lifecycle.sh" "$SHARE_DIR/lifecycle.sh"

# Publish a CUSTOM home CONTAINER-WIDE. Coding-tool hooks inherit the container environment — not the
# lifecycle.sh shell that install/supervise run in — so a non-default auspexHome would otherwise leave
# hooks resolving the default ~/.auspex while the supervised daemon drains the custom home: silent
# capture loss (the home-divergence footgun). A Dev Container Feature cannot interpolate an option value
# into `containerEnv` (devcontainers/spec#164), so publish it here at feature-install time (as root):
#   - /etc/environment      — read by PAM for every login session; the shells/agents a coding tool spawns
#                             inherit AUSPEX_HOME, so their hooks resolve the SAME home as the daemon.
#   - /etc/profile.d/*.sh   — belt-and-suspenders for a login shell that sources /etc/profile without a
#                             PAM session (the case flagged in devcontainers/spec#164).
# Default (empty) home ⇒ nothing published: the daemon and a clean hook both resolve ~/.auspex — no
# divergence. Idempotent so a rebuild's re-run doesn't accumulate duplicate lines.
#
# The two files take DIFFERENT quoting BY DESIGN, because they have different parsers:
#   - /etc/environment is NOT shell-sourced — pam_env reads `KEY=VALUE` and takes the whole rest of the
#     line as the literal value, so a bare (unquoted) value is correct and a space survives intact.
#     Shell-quoting it (e.g. %q's backslash-escapes or surrounding quotes) would instead be stored as
#     LITERAL characters in the value, corrupting the path.
#   - /etc/profile.d/auspex-home.sh IS shell-sourced, so its value must be shell-quoted (%q) to survive a
#     space/metacharacter — exactly like feature.env above.
if [ -n "$FEATURE_HOME" ]; then
  ETC_ENV=/etc/environment
  if [ -f "$ETC_ENV" ]; then
    grep -v '^AUSPEX_HOME=' "$ETC_ENV" >"$ETC_ENV.auspex-tmp" 2>/dev/null || true
    mv "$ETC_ENV.auspex-tmp" "$ETC_ENV"
  fi
  printf 'AUSPEX_HOME=%s\n' "$FEATURE_HOME" >>"$ETC_ENV" # pam_env literal value — see note above; NOT shell-quoted

  PROFILE_D=/etc/profile.d/auspex-home.sh
  mkdir -p /etc/profile.d
  printf 'export AUSPEX_HOME=%q\n' "$FEATURE_HOME" >"$PROFILE_D" # shell-sourced — MUST be %q-quoted
  chmod 0644 "$PROFILE_D"
  echo "auspex feature: published AUSPEX_HOME=${FEATURE_HOME} container-wide (/etc/environment + /etc/profile.d) so coding-tool hooks resolve the same home as the daemon"
fi

# SYSTEM-tier hook placement (hookScope: system) — placed HERE, at feature-install time, because it is
# the one phase that runs as ROOT: the machine-wide cells live in /etc, and onCreate/postStart run as the
# (usually non-root) container user. Placing them now means onCreate's `install --supervised` sees the
# system placement marker and partial-defers the machine-wide wiring (it is already at /etc) — it still
# enrolls, arms the cold-start relax, and wires the user-scoped VS Code cell. VS Code itself is NEVER a
# system-tier tool (`hooks install --system` skips it with a note): its capture is registered declaratively
# via this feature's customizations.vscode.settings, which the container VS Code Server reads from its
# machine-settings (the desktop settings.json a command writes is not read by the Server).
#
# Fail-soft on a rootless builder: if the feature-install phase is somehow not root, the /etc write would
# fail — so warn with guidance and leave the marker unset. onCreate then does a normal user-tier install
# (no system marker to defer on), which still captures; the operator can re-run `sudo auspex hooks install
# --system` inside the container, or set hookScope: user.
if [ "$HOOK_SCOPE" = "system" ]; then
  home_args=()
  [ -n "$FEATURE_HOME" ] && home_args=(--home "$FEATURE_HOME")
  if [ "$(id -u)" -ne 0 ]; then
    echo "auspex feature: hookScope=system needs a root feature-install phase to write the machine-wide /etc hooks, but this build is not running as root — skipping system placement." >&2
    echo "auspex feature: onCreate will place USER-tier hooks instead. To use system scope, run 'sudo auspex hooks install --system' in the container, or set hookScope: user." >&2
  else
    echo "auspex feature: placing machine-wide (/etc) capture hooks (hookScope=system)"
    "$BIN_DEST" hooks install --system "${home_args[@]}"
  fi
fi

echo "auspex feature: installed ${BIN_DEST} (version ${VERSION}); lifecycle helper at ${SHARE_DIR}/lifecycle.sh"
