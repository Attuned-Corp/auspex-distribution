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
DIGEST="${DIGEST:-}" # optional pin: a raw sha256 (of the artifact) that bypasses version→manifest resolution
CAPTURE_DIGEST="${CAPTUREDIGEST:-}" # with digest: auspex-capture's own sha256 pin
MANIFEST_DIGEST="${MANIFESTDIGEST:-}" # pin a whole release by its manifest's sha256
FEATURE_HOME="${AUSPEXHOME:-}"
DEVICE_ID="${DEVICEID:-}"
TOKEN_FILE="${TOKENFILE:-}"
HOOK_SCOPE="${HOOKSCOPE:-user}"

# Destinations are env-overridable ONLY to make the download+verify path testable off-root (the
# verify regression harness points them at a temp dir); the feature never sets them, so a real
# install lands at the canonical /usr/local paths.
SHARE_DIR="${AUSPEX_SHARE_DIR:-/usr/local/share/auspex}"
BIN_DEST="${AUSPEX_BIN_DEST:-/usr/local/bin/auspex}"
# auspex-capture, the capture-only binary hooks run (auspex 0.13.0 and later), goes beside auspex: `auspex
# install` looks for it there, and links it to auspex when it is missing (hooks still capture, more slowly).
CAPTURE_DEST="$(dirname "$BIN_DEST")/auspex-capture"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

# Verification recipe + pinned trust material (identity regex, OIDC issuer, cosign pins, trusted_root.json,
# and the fetch/verify functions) live in the SHARED verify library beside this script — the ONE verifier
# this repo ships, also assembled into the curl|sh bootstrap and sourced by the MDM gate, so there is a
# single recipe to maintain rather than a per-consumer copy. Sourcing it defines COSIGN_* / TRUSTED_ROOT +
# fetch / acquire_verified (the raw-binary resolve→fetch-by-digest→verify entrypoint) / …; TRUSTED_ROOT resolves next to the lib (this same dir once
# packaged into the Feature). The reconcile guard keeps the pins in lock-step with auspex's signing descriptor.
# shellcheck disable=SC2034  # consumed by the sourced verify-lib.sh (sets the message voice)
AUSPEX_VERIFY_LOG_PREFIX="auspex feature"
# shellcheck source=src/span-auspex/verify-lib.sh
# shellcheck disable=SC1091  # sourced via a runtime-resolved ${SRC_DIR}; source= above aids `shellcheck -x`
. "${SRC_DIR}/verify-lib.sh"

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
    # A pinned digest addresses the version-free blob, so an empty version is fine then (the blob path is
    # derived from the host root, before /releases/); otherwise a {{version}} template needs a concrete tag.
    if [ -z "$VERSION" ] && [ -z "$DIGEST" ] && [ -z "$MANIFEST_DIGEST" ]; then
      echo "auspex feature: binaryUri uses the {{version}} token but no 'version' (or 'manifestDigest' or 'digest') was set — set 'version' to a release tag (e.g. v0.1.0), or pin by content. A concrete tag is required here (cosign verification is tag-bound)." >&2
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
if [ -n "$MANIFEST_DIGEST" ] && { [ -n "$DIGEST" ] || [ -n "$CAPTURE_DIGEST" ]; }; then
  echo "auspex feature: option 'manifestDigest' pins every binary already — unset 'digest'/'captureDigest'" >&2
  exit 1
fi
if [ -n "$CAPTURE_DIGEST" ] && [ -z "$DIGEST" ]; then
  echo "auspex feature: option 'captureDigest' pins auspex-capture beside a 'digest' pin of auspex — set 'digest' too (a version install fetches auspex-capture itself)" >&2
  exit 1
fi

# Fail unless the local <file> hashes to the pinned digest (optionally 'sha256:'-prefixed, any case).
require_local_pin() { # <file> <digest>
  local pin="${2#sha256:}" got
  pin="$(printf '%s' "$pin" | tr 'A-F' 'a-f')"
  got="$(sha256_of "$1")"
  if [ "$pin" != "$got" ]; then
    echo "auspex feature: pinned digest mismatch for ${1} (expected sha256:${pin}, got sha256:${got}) — refusing to install" >&2
    exit 1
  fi
  echo "auspex feature: ${1} matches pinned digest sha256:${got}"
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
    # A manifest pin takes the host and os/arch from binaryUri, resolves the release's version URL, then
    # installs through the cosign path below, which reads the pinned manifest instead of a signature.
    if [ -n "$MANIFEST_DIGEST" ]; then
      platform_re='/releases/[^/]*/([^/]+)/([^/]+)/auspex$'
      if ! [[ "$BINARY_URI" =~ $platform_re ]]; then
        echo "auspex feature: 'manifestDigest' needs a binaryUri of the form <host>/releases/<version>/<os>/<arch>/auspex, for the host and platform (got ${BINARY_URI})" >&2
        exit 1
      fi
      acquire_by_manifest_digest "$BINARY_URI" "$MANIFEST_DIGEST" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
      if [ -n "$VERSION" ] && [ "$VERSION" != "$MANIFEST_VERSION" ]; then
        echo "auspex feature: 'version' is ${VERSION} but the pinned manifest is ${MANIFEST_VERSION} — refusing" >&2
        exit 1
      fi
      BINARY_URI="$MANIFEST_BINARY_URL"
      VERSION="$MANIFEST_VERSION"
      VERIFY=cosign
    fi
    # Both write the TRUSTED bytes to the temp and only return on success, so a tampered/truncated artifact
    # is never chmod +x'd into place; only a passing check promotes it to BIN_DEST.
    dl_tmp="$(mktemp)"
    if [ -n "$DIGEST" ]; then
      # Pin-by-digest: fetch straight from the version-free content-addressed blob (host derived from
      # binaryUri) and self-verify. The 'version' + 'verify' options don't apply — the digest is the anchor.
      echo "auspex feature: pinning by digest (host ${BINARY_URI%%/releases/*})"
      acquire_by_digest "$BINARY_URI" "$DIGEST" "$dl_tmp"
    else
      # verify: cosign resolves the signed manifest and fetches the content-addressed BLOB (not the
      # version-path bytes); checksum/none fetch the version path.
      echo "auspex feature: acquiring binary (verify: ${VERIFY}) for ${BINARY_URI}"
      acquire_verified "$BINARY_URI" "$VERIFY" "$dl_tmp"
    fi
    # auspex-capture is acquired the same way before either binary is placed, so a failed verify leaves
    # nothing installed. A digest pin names one artifact, so auspex-capture needs its own (captureDigest).
    cap_tmp=""
    if [ -n "$CAPTURE_DIGEST" ]; then
      cap_tmp="$(mktemp)"
      acquire_by_digest "$BINARY_URI" "$CAPTURE_DIGEST" "$cap_tmp"
    elif [ -n "$DIGEST" ]; then
      echo "auspex feature: note — a 'digest' pin installs auspex only; set 'captureDigest' to pin auspex-capture too, or auspex install links it to auspex (slower hooks)" >&2
    else
      resolve_capture_url "$BINARY_URI" # sets CAPTURE_URL, or leaves it empty with a note
      if [ -n "$CAPTURE_URL" ]; then
        cap_tmp="$(mktemp)"
        echo "auspex feature: acquiring binary (verify: ${VERIFY}) for ${CAPTURE_URL}"
        acquire_verified "$CAPTURE_URL" "$VERIFY" "$cap_tmp"
      fi
    fi
    mv "$dl_tmp" "$BIN_DEST"
    # mv renames over a placeholder link a previous install may have left, rather than writing through it.
    if [ -n "$cap_tmp" ]; then
      chmod 0755 "$cap_tmp"
      mv -f "$cap_tmp" "$CAPTURE_DEST"
    fi
    ;;
  *)
    # A plain in-container path is a locally-present artifact — no network fetch, so the verify option does
    # not apply. When a 'digest' is pinned we still self-verify the local bytes against it (cheap assurance a
    # pre-staged binary matches the pin); otherwise it is treated as already-trusted and copied.
    if [ -n "$MANIFEST_DIGEST" ]; then
      echo "auspex feature: 'manifestDigest' needs an http(s) binaryUri; for an in-container path, pin each binary with 'digest' and 'captureDigest'" >&2
      exit 1
    fi
    echo "auspex feature: copying binary from path ${BINARY_URI}"
    if [ ! -f "$BINARY_URI" ]; then
      echo "auspex feature: binaryUri path '${BINARY_URI}' does not exist in the container" >&2
      exit 1
    fi
    [ -z "$DIGEST" ] || require_local_pin "$BINARY_URI" "$DIGEST"
    # A staged auspex-capture is copied unless it is a placeholder link, or a digest pins auspex without a
    # captureDigest for it. Both pins are checked before either binary is placed.
    capture_src="$(dirname "$BINARY_URI")/auspex-capture"
    copy_capture=0
    if [ -n "$CAPTURE_DIGEST" ]; then
      if [ ! -f "$capture_src" ] || [ -L "$capture_src" ]; then
        echo "auspex feature: 'captureDigest' is set but there is no auspex-capture file beside ${BINARY_URI} — refusing to install" >&2
        exit 1
      fi
      require_local_pin "$capture_src" "$CAPTURE_DIGEST"
      copy_capture=1
    elif [ -f "$capture_src" ] && [ ! -L "$capture_src" ] && [ -z "$DIGEST" ]; then
      copy_capture=1
    fi
    cp "$BINARY_URI" "$BIN_DEST"
    # The destination is removed first so cp can't write through a placeholder link into auspex.
    if [ "$copy_capture" -eq 1 ]; then
      rm -f "$CAPTURE_DEST"
      cp "$capture_src" "$CAPTURE_DEST"
      chmod 0755 "$CAPTURE_DEST"
      echo "auspex feature: copied ${capture_src}"
    fi
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
