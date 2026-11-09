# shellcheck shell=bash
# Shared pinned-cosign verify recipe for auspex release artifacts — the ONE verifier for this repo,
# sourced by three callers: the Dev Container Feature's install.sh (container build), the curl|sh
# bootstrap (assembled into the released installer, see bootstrap/), and the MDM verify-before-install
# gate (mdm/). It is a LIBRARY: sourcing it defines constants + functions and runs nothing.
#
# What it proves (verify: cosign, the default — resolve → fetch-by-digest → verify, auspex ADR 0047): the
# release publishes a cosign keyless-signed `version→digest` index (manifest.json, an OCI image-index) at
# the version root, binding <tag> + per-os/arch → the artifact's sha256 (auspex ADR 0033 §4/§5). We
# keyless-verify that manifest against the pinned release identity + a pinned Sigstore trusted_root.json
# (FULLY LOCAL — cosign v3 checks the new-format bundle's embedded Rekor inclusion proof against the shipped
# keys; no TUF/Rekor/Fulcio network), ASSERT its version annotation matches the requested tag (closing the
# version-substitution gap a bare digest-membership check leaves open), read the raw-binary digest for this
# os/arch, then FETCH THE BYTES from the global content-addressed blob (blobs/sha256/<digest>) and
# self-verify (sha256(bytes) == the signed digest). Authenticity roots in the signed manifest; the bytes
# come from the version-free, self-verifying blob. Parsing the manifest needs jq (auto-provisioned + pinned,
# exactly like cosign). verify: checksum collapses to an integrity-only sha256 against the adjacent .sha256
# sidecar (no cosign/jq); per-artifact .pkg/.msi carry their own .cosign.bundle (verify_cosign_bundle,
# unchanged). The ONE raw-binary entrypoint is acquire_verified <version-url> <mode> <out> — it owns the
# fetch so the cosign tier never pulls the version-path bytes it would then discard for the blob. To pin a
# specific artifact regardless of version, acquire_by_digest <base> <digest> <out> fetches straight from the
# content-addressed blob and self-verifies (the digest is the trust anchor; no version/manifest/cosign/jq).
# acquire_by_manifest_digest pins a whole release the same way, by its manifest's digest (needs jq, not cosign).
#
# TRUST MATERIAL SSOT: the identity regex + OIDC issuer + cosign pins below are the distribution repo's
# VERIFIER CONFIG (origin-#2 anchor). auspex is canonical for the *signing* descriptor it owns
# (release.yml / .goreleaser.yaml / Makefile.setup.mk); the reconcile guard (.github/workflows) diffs the
# overlapping fields (identity/issuer/cosign version) against auspex at a pinned SHA so they cannot drift.
# The pinned Sigstore trusted_root.json tracks Sigstore (not auspex) — this repo owns keeping it current.
# Bump the cosign version + BOTH per-arch SHAs + trusted_root.json together; see README "Updating the
# pinned cosign / trust root".

# Many constants below are a deliberate API: exit codes + per-os/arch cosign pins consumed by callers
# (bootstrap / MDM gate / the PowerShell installer) or resolved indirectly (${!pinvar}), so shellcheck's
# "appears unused" (SC2034) is expected for the file.
# shellcheck disable=SC2034

# Guard against double-sourcing (install.sh + an embedded copy, etc.).
[ -n "${_AUSPEX_VERIFY_LIB_SOURCED:-}" ] && return 0
_AUSPEX_VERIFY_LIB_SOURCED=1

# Log prefix — callers set this so messages read in their own voice ("auspex feature:", "auspex install:",
# "auspex mdm-gate:"). Defaults to a neutral "auspex".
: "${AUSPEX_VERIFY_LOG_PREFIX:=auspex}"

# Documented exit codes (AC2) — the MDM gate + tests key on these to distinguish failure classes.
AUSPEX_VERIFY_EX_USAGE=2            # bad arguments / unsupported option
AUSPEX_VERIFY_EX_ENV=16            # environment can't verify (no sha256 tool, unsupported os/arch, missing trust root)
AUSPEX_VERIFY_EX_FETCH=11         # required material could not be fetched (manifest / by-digest blob / sidecar / bundle)
AUSPEX_VERIFY_EX_CHECKSUM=12      # SHA-256 mismatch against the .sha256 sidecar
AUSPEX_VERIFY_EX_COSIGN=13        # cosign verify-blob failed (bad signature OR identity/issuer mismatch)
AUSPEX_VERIFY_EX_DIGEST_ABSENT=14 # signed manifest doesn't bind this version/os-arch to a digest (or the
                                  # manifest's version annotation doesn't match the requested tag)
AUSPEX_VERIFY_EX_COSIGN_PROVISION=15 # pinned cosign could not be provisioned (download / hash mismatch)
AUSPEX_VERIFY_EX_JQ_PROVISION=17  # pinned jq could not be provisioned (download / hash mismatch) — needed
                                  # only by the cosign tier to parse the signed manifest
AUSPEX_VERIFY_EX_CHANNEL_INVALID=18 # a correctly signed channel document isn't a schema-1 document
AUSPEX_VERIFY_EX_CHANNEL_REPLAY=19  # the channel document's sequence is below the caller's --min-sequence

# Pinned keyless-signing identity for the auspex release workflow — the binary SIGNER lives in the private
# Attuned-Corp/auspex repo, so this stays in LOCK-STEP with that repo's signing descriptor
# (tools/release/signing-identity.env, mirrored by release.yml + .goreleaser.yaml; auspex ADR 0033 §4/§5).
# The cert identity is anchored (^…$) and dot-escaped to the auspex release workflow on a SEMVER tag ref
# (incl. an optional pre-release, e.g. v1.2.3 / v0.0.1-rc1), owner matched case-insensitively. Anchoring to
# semver — not any v* tag — keeps the trust surface to the tag shapes the release actually cuts. The
# reconcile guard fails CI if this drifts from auspex's signing descriptor.
COSIGN_IDENTITY_RE='^https://github\.com/(?i:attuned-corp)/auspex/\.github/workflows/release\.yml@refs/tags/v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'
COSIGN_OIDC_ISSUER='https://token.actions.githubusercontent.com'

# Signer of the release channel document (auspex ADR 0066), disjoint from COSIGN_IDENTITY_RE so neither
# signature verifies as the other. The reconcile guard diffs it against auspex's COSIGN_CHANNEL_IDENTITY_REGEXP.
COSIGN_CHANNEL_IDENTITY_RE='^https://github\.com/(?i:attuned-corp)/auspex/\.github/workflows/publish-release\.yml@refs/heads/main$'

# Self-provisioned cosign: verify: cosign needs no pre-installed CLI. When cosign is not on PATH we download
# a PINNED release binary and verify it against a hardcoded per-arch SHA-256 BEFORE using it (fail closed) —
# the pinned hash is the trust anchor, and it ships inside this (already-trusted) file. Keep COSIGN_VERSION
# in LOCK-STEP with the SIGNER (auspex/Makefile.setup.mk COSIGN_VERSION); the reconcile guard enforces it.
COSIGN_VERSION='v3.1.2'
COSIGN_SHA256_linux_amd64='f7622ed3cf22e55e1ae6377c080979ff77a22da9981c11df222a2e444991e7cf'
COSIGN_SHA256_linux_arm64='90e7ae0b5dfd60f20816b52c012addf7fc055ebcc7bea4ce81c428ca8518c302'
COSIGN_SHA256_darwin_amd64='acd180f8b015be25240ca33abee8a1e564eb65cdf1a3cee4725456d2dceb7da6'
COSIGN_SHA256_darwin_arm64='dec1c3f802320b19c2fbcf2dc7bcfb3f258e1c181a046c23a1a074bdf932f10a'
# Windows is verified by the PowerShell installer (bootstrap/auspex-install.ps1), which pins the same
# version + this digest independently; kept here as the SSOT the reconcile guard checks against both.
COSIGN_SHA256_windows_amd64='fe4d621d7ae5e900ee62089837c00f996ae9acb82027d573d1d157b6ee875cb2'
COSIGN_BASE_URL="${AUSPEX_COSIGN_BASE_URL:-https://github.com/sigstore/cosign/releases/download}"

# Self-provisioned jq (verify: cosign only): parsing the signed manifest (an OCI image-index JSON) needs a
# JSON reader, and we refuse to shell-parse security-critical JSON by hand. Mirroring the cosign approach,
# when jq is not on PATH we download a PINNED release binary and verify it against a hardcoded per-os/arch
# SHA-256 BEFORE using it (fail closed) — the pinned hash is the trust anchor, shipped inside this already-
# trusted file. jq is a small static binary. Note jq's asset OS token is `macos` (not `darwin`); ensure_jq
# maps it. Windows never needs this — the PowerShell installer parses the manifest with native
# ConvertFrom-Json. Refresh the version + all four SHAs together (README "Updating the pinned cosign / jq").
JQ_VERSION='jq-1.8.2'
JQ_SHA256_linux_amd64='b1c22172dd303f3be49e935aa56aa48a8b7a46e0bc838b4997d3bb451495870f'
JQ_SHA256_linux_arm64='8b85c817833814ddca00a144c33705546355afccf0cf39b188f3cdb48b852309'
JQ_SHA256_macos_amd64='e94b266e3c26690550006abe63152b782280f4e14374accdf04cbde844f00bc0'
JQ_SHA256_macos_arm64='2d75340ba57a4b4b4c8708a21c2dc8e958a48aaa8bba13b27f77f6e4c0eca07e'
JQ_BASE_URL="${AUSPEX_JQ_BASE_URL:-https://github.com/jqlang/jq/releases/download}"

# Pinned Sigstore trust root, shipped beside this library (or handed in via AUSPEX_TRUSTED_ROOT for an
# assembled/embedded bootstrap). cosign v3 verifies the new-format bundle's embedded Rekor inclusion proof
# against these keys, so verify: cosign is FULLY LOCAL — no TUF, no Rekor network.
_AUSPEX_VERIFY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRUSTED_ROOT="${AUSPEX_TRUSTED_ROOT:-${_AUSPEX_VERIFY_LIB_DIR}/trusted_root.json}"

# Download caps (defense-in-depth against a hung / oversized origin). The ceiling comfortably covers the
# auspex binary and the ~150 MB cosign release binary.
FETCH_MAX_TIME="${AUSPEX_FETCH_MAX_TIME:-300}"
FETCH_MAX_BYTES="${AUSPEX_FETCH_MAX_BYTES:-524288000}" # 500 MiB

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
      echo "${AUSPEX_VERIFY_LOG_PREFIX}: refusing to fetch over cleartext http (non-loopback): ${url} — use https" >&2
      return 1
    } ;;
    *)
      echo "${AUSPEX_VERIFY_LOG_PREFIX}: unsupported URL scheme for ${url} — only https (or loopback http) is allowed" >&2
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
    echo "${AUSPEX_VERIFY_LOG_PREFIX}: neither curl nor wget is available to download from ${url}" >&2
    exit "$AUSPEX_VERIFY_EX_ENV"
  fi
}

sha256_of() { # <file> — bare hex digest, using whichever tool the platform ships.
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    echo "${AUSPEX_VERIFY_LOG_PREFIX}: no sha256sum/shasum available to verify the download — install one or use the 'none' tier" >&2
    exit "$AUSPEX_VERIFY_EX_ENV"
  fi
}

# Integrity check: fetch the adjacent <url>.sha256 sidecar (the publish pipeline emits it next to the raw
# binary, auspex ADR 0045) and fail CLOSED on any mismatch or a missing sidecar. The sidecar is
# `<digest>  auspex` (GoReleaser/shasum style), so the first field is the expected digest.
verify_sha256() { # <file> <url>
  local file="$1" url="$2" sumtmp expected got
  sumtmp="$(mktemp)"
  if ! fetch "${url}.sha256" "$sumtmp"; then
    rm -f "$sumtmp"
    echo "${AUSPEX_VERIFY_LOG_PREFIX}: could not fetch the checksum sidecar ${url}.sha256 — refusing to install an unverified binary (use the 'none' tier to override)" >&2
    exit "$AUSPEX_VERIFY_EX_FETCH"
  fi
  expected="$(awk 'NR==1{print $1}' "$sumtmp")"
  rm -f "$sumtmp"
  got="$(sha256_of "$file")"
  if [ -z "$expected" ] || [ "$expected" != "$got" ]; then
    echo "${AUSPEX_VERIFY_LOG_PREFIX}: SHA-256 mismatch for ${url} (expected '${expected:-<empty>}', got '${got}') — refusing to install" >&2
    exit "$AUSPEX_VERIFY_EX_CHECKSUM"
  fi
  echo "${AUSPEX_VERIFY_LOG_PREFIX}: SHA-256 verified (${got})"
}

# Provision a cosign CLI for verify: cosign. Prefer one already on PATH; otherwise download the PINNED
# release binary and verify it against the hardcoded per-arch SHA-256 BEFORE using it (fail closed) — that
# pinned hash is the trust anchor the whole default check bottoms out in. Sets COSIGN_BIN (and
# COSIGN_CLEANUP for a downloaded one). cosign is a static Go binary, so the downloaded one works on glibc
# and musl/Alpine alike.
COSIGN_BIN=""
COSIGN_CLEANUP=""
ensure_cosign() {
  if command -v cosign >/dev/null 2>&1; then
    COSIGN_BIN="cosign"
    return 0
  fi
  if [ -n "$COSIGN_CLEANUP" ] && [ -x "$COSIGN_CLEANUP" ]; then # downloaded and hash-checked earlier this run
    COSIGN_BIN="$COSIGN_CLEANUP"
    return 0
  fi
  local os arch expected
  case "$(uname -s | tr '[:upper:]' '[:lower:]')" in
    linux) os="linux" ;;
    darwin) os="darwin" ;;
    *)
      echo "${AUSPEX_VERIFY_LOG_PREFIX}: cosign auto-provisioning covers Linux/macOS; on '$(uname -s)' install cosign yourself (it will be used) or use the 'checksum' tier" >&2
      exit "$AUSPEX_VERIFY_EX_ENV"
      ;;
  esac
  case "$(uname -m)" in
    x86_64 | amd64) arch="amd64" ;;
    aarch64 | arm64) arch="arm64" ;;
    *)
      echo "${AUSPEX_VERIFY_LOG_PREFIX}: no pinned cosign for CPU '$(uname -m)' — pre-install cosign on PATH, or use the 'checksum' tier" >&2
      exit "$AUSPEX_VERIFY_EX_ENV"
      ;;
  esac
  # Resolve the pinned per-os/arch digest (COSIGN_SHA256_<os>_<arch>) via indirect expansion.
  local pinvar="COSIGN_SHA256_${os}_${arch}"
  expected="${!pinvar:-}"
  if [ -z "$expected" ]; then
    echo "${AUSPEX_VERIFY_LOG_PREFIX}: no pinned cosign digest for ${os}/${arch} — pre-install cosign on PATH, or use the 'checksum' tier" >&2
    exit "$AUSPEX_VERIFY_EX_ENV"
  fi
  local url tmp got
  url="${COSIGN_BASE_URL}/${COSIGN_VERSION}/cosign-${os}-${arch}"
  tmp="$(mktemp)"
  echo "${AUSPEX_VERIFY_LOG_PREFIX}: provisioning pinned cosign ${COSIGN_VERSION} (${os}/${arch})"
  if ! fetch "$url" "$tmp"; then
    rm -f "$tmp"
    echo "${AUSPEX_VERIFY_LOG_PREFIX}: failed to download cosign ${COSIGN_VERSION} from ${url} — cosign verify needs egress to github.com (or pre-install cosign / use the 'checksum' tier)" >&2
    exit "$AUSPEX_VERIFY_EX_COSIGN_PROVISION"
  fi
  got="$(sha256_of "$tmp")"
  if [ "$got" != "$expected" ]; then
    rm -f "$tmp"
    echo "${AUSPEX_VERIFY_LOG_PREFIX}: pinned cosign SHA-256 mismatch (expected ${expected}, got ${got}) — refusing to use a tampered cosign" >&2
    exit "$AUSPEX_VERIFY_EX_COSIGN_PROVISION"
  fi
  chmod 0755 "$tmp"
  COSIGN_BIN="$tmp"
  COSIGN_CLEANUP="$tmp"
}

# Provision a jq CLI for the cosign tier's manifest parse. Prefer one already on PATH; otherwise download
# the PINNED release binary and verify it against the hardcoded per-os/arch SHA-256 BEFORE using it (fail
# closed). Sets JQ_BIN (and JQ_CLEANUP for a downloaded one). jq is a static binary, so the downloaded one
# works on glibc and musl/Alpine alike. Only the cosign tier calls this — checksum/none never parse JSON.
JQ_BIN=""
JQ_CLEANUP=""
ensure_jq() {
  if command -v jq >/dev/null 2>&1; then
    JQ_BIN="jq"
    return 0
  fi
  if [ -n "$JQ_CLEANUP" ] && [ -x "$JQ_CLEANUP" ]; then # downloaded and hash-checked earlier this run
    JQ_BIN="$JQ_CLEANUP"
    return 0
  fi
  local os arch expected
  case "$(uname -s | tr '[:upper:]' '[:lower:]')" in
    linux) os="linux" ;;
    darwin) os="macos" ;; # jq's release asset uses `macos`, not `darwin`
    *)
      echo "${AUSPEX_VERIFY_LOG_PREFIX}: parsing the signed manifest needs jq; auto-provisioning covers Linux/macOS. On '$(uname -s)' install jq yourself (it will be used) or use the 'checksum' tier" >&2
      exit "$AUSPEX_VERIFY_EX_ENV"
      ;;
  esac
  case "$(uname -m)" in
    x86_64 | amd64) arch="amd64" ;;
    aarch64 | arm64) arch="arm64" ;;
    *)
      echo "${AUSPEX_VERIFY_LOG_PREFIX}: no pinned jq for CPU '$(uname -m)' — pre-install jq on PATH, or use the 'checksum' tier" >&2
      exit "$AUSPEX_VERIFY_EX_ENV"
      ;;
  esac
  local pinvar="JQ_SHA256_${os}_${arch}"
  expected="${!pinvar:-}"
  if [ -z "$expected" ]; then
    echo "${AUSPEX_VERIFY_LOG_PREFIX}: no pinned jq digest for ${os}/${arch} — pre-install jq on PATH, or use the 'checksum' tier" >&2
    exit "$AUSPEX_VERIFY_EX_ENV"
  fi
  local url tmp got
  url="${JQ_BASE_URL}/${JQ_VERSION}/jq-${os}-${arch}"
  tmp="$(mktemp)"
  echo "${AUSPEX_VERIFY_LOG_PREFIX}: provisioning pinned jq ${JQ_VERSION} (${os}/${arch})"
  if ! fetch "$url" "$tmp"; then
    rm -f "$tmp"
    echo "${AUSPEX_VERIFY_LOG_PREFIX}: failed to download jq ${JQ_VERSION} from ${url} — the cosign tier parses the signed manifest with jq (needs egress to github.com); pre-install jq or use the 'checksum' tier" >&2
    exit "$AUSPEX_VERIFY_EX_JQ_PROVISION"
  fi
  got="$(sha256_of "$tmp")"
  if [ "$got" != "$expected" ]; then
    rm -f "$tmp"
    echo "${AUSPEX_VERIFY_LOG_PREFIX}: pinned jq SHA-256 mismatch (expected ${expected}, got ${got}) — refusing to use a tampered jq" >&2
    exit "$AUSPEX_VERIFY_EX_JQ_PROVISION"
  fi
  chmod 0755 "$tmp"
  JQ_BIN="$tmp"
  JQ_CLEANUP="$tmp"
}

# Assert the pinned trust root is present before any cosign verify (fail closed on an incomplete checkout /
# assembled bootstrap missing its embedded root).
_require_trusted_root() {
  if [ ! -f "$TRUSTED_ROOT" ]; then
    echo "${AUSPEX_VERIFY_LOG_PREFIX}: missing pinned trust root at ${TRUSTED_ROOT} — this checkout/installer is incomplete; reinstall or use the 'checksum' tier" >&2
    exit "$AUSPEX_VERIFY_EX_ENV"
  fi
}

# auspex-capture is indexed under its platform's executable type, so octet-stream stays the one auspex per
# os/arch (auspex ADR 0068); any other name keeps the octet-stream lookup.
raw_binary_media_type() { # <file-name> <os>
  case "$1:$2" in
    auspex-capture:darwin) printf 'application/x-mach-binary' ;;
    auspex-capture:linux) printf 'application/x-executable' ;;
    *) printf 'application/octet-stream' ;;
  esac
}

# Resolve the raw-binary digest for a version-path URL from the SIGNED manifest (verify: cosign — auspex
# ADR 0047). From .../releases/<v>/<os>/<arch>/<name> we derive the version root, tag, os and arch;
# fetch + keyless-verify the version→digest index (manifest.json) against the pinned identity +
# trusted_root.json; ASSERT its version annotation equals the requested tag (this is what closes the
# version-substitution gap — the manifest is cryptographically bound to <v>, not merely to "some semver
# tag"); then read the unique descriptor of <name>'s media type for this os/arch and emit its bare-hex
# sha256. Sets RESOLVED_DIGEST (a global, so no command-substitution captures the progress echoes). Parsing
# uses jq (auto-provisioned + pinned); the descriptor lookup requires EXACTLY ONE match and a 64-hex digest,
# else it fails closed (an ambiguous or absent binding must never resolve). A verified manifest is kept in
# memory for its version root, so resolving auspex-capture after auspex re-verifies nothing.
RESOLVED_DIGEST=""
_VERIFIED_MANIFEST_ROOT=""
_VERIFIED_MANIFEST_JSON=""
_VERIFIED_MANIFEST_DIGEST=""
_VERIFIED_MANIFEST_HOW="signed manifest verified" # or "pinned manifest", once seeded by a manifest pin
resolve_binary_digest() { # <version_url>
  local url="$1" ver_root version os arch media digest
  ver_root="$(dirname "$(dirname "$(dirname "$url")")")" # .../releases/<v>
  version="$(basename "$ver_root")"
  arch="$(basename "$(dirname "$url")")"
  os="$(basename "$(dirname "$(dirname "$url")")")"
  media="$(raw_binary_media_type "$(basename "$url")" "$os")"
  if [ "$_VERIFIED_MANIFEST_ROOT" = "$ver_root" ]; then
    ensure_jq
  else
    _verify_release_manifest "$ver_root" "$version"
  fi
  # The RAW BINARY is the sole descriptor of its media type for a platform (archives/packages carry their
  # own media types), so (media type + os + arch) is a unique key. Require exactly one match.
  # shellcheck disable=SC2016  # $media/$os/$arch are jq --arg variables, deliberately single-quoted (not shell)
  digest="$(printf '%s' "$_VERIFIED_MANIFEST_JSON" | "$JQ_BIN" -r --arg media "$media" --arg os "$os" --arg arch "$arch" '
    [ .manifests[]
      | select(.mediaType == $media
        and .platform.os == $os
        and .platform.architecture == $arch) ]
    | if length == 1 then .[0].digest else empty end' 2>/dev/null)"
  [ -n "$COSIGN_CLEANUP" ] && rm -f "$COSIGN_CLEANUP"
  [ -n "$JQ_CLEANUP" ] && rm -f "$JQ_CLEANUP"
  case "$digest" in
    sha256:*) digest="${digest#sha256:}" ;;
    *)
      echo "${AUSPEX_VERIFY_LOG_PREFIX}: the release manifest (${_VERIFIED_MANIFEST_HOW}) has no unique raw-binary (${media}) descriptor for ${os}/${arch} — refusing to install" >&2
      exit "$AUSPEX_VERIFY_EX_DIGEST_ABSENT"
      ;;
  esac
  case "$digest" in
    *[!0-9a-f]* | "")
      echo "${AUSPEX_VERIFY_LOG_PREFIX}: the resolved digest '${digest}' is not a bare sha256 hex — refusing to install" >&2
      exit "$AUSPEX_VERIFY_EX_DIGEST_ABSENT"
      ;;
  esac
  if [ "${#digest}" -ne 64 ]; then
    echo "${AUSPEX_VERIFY_LOG_PREFIX}: the resolved digest '${digest}' is not 64 hex chars — refusing to install" >&2
    exit "$AUSPEX_VERIFY_EX_DIGEST_ABSENT"
  fi
  RESOLVED_DIGEST="$digest"
  echo "${AUSPEX_VERIFY_LOG_PREFIX}: resolved ${version} ${os}/${arch} $(basename "$url") → sha256:${digest} (${_VERIFIED_MANIFEST_HOW})"
}

# Fetch + keyless-verify <ver_root>/manifest.json and assert its version annotation is <version>; on success
# keep its bytes in _VERIFIED_MANIFEST_JSON and print its digest as a pin for the whole release (fails closed
# otherwise). Leaves cosign/jq for the caller to clean.
_verify_release_manifest() { # <ver_root> <version>
  local ver_root="$1" version="$2" manifest bundle m_version
  ensure_cosign
  ensure_jq
  _require_trusted_root
  manifest="$(mktemp)"
  bundle="$(mktemp)"
  if ! fetch "${ver_root}/manifest.json" "$manifest" || ! fetch "${ver_root}/manifest.json.cosign.bundle" "$bundle"; then
    rm -f "$manifest" "$bundle"
    echo "${AUSPEX_VERIFY_LOG_PREFIX}: could not fetch ${ver_root}/manifest.json(.cosign.bundle) — is this a signed release published under the ADR 0047 layout?" >&2
    exit "$AUSPEX_VERIFY_EX_FETCH"
  fi
  if ! "$COSIGN_BIN" verify-blob \
    --bundle "$bundle" \
    --trusted-root "$TRUSTED_ROOT" \
    --certificate-identity-regexp "$COSIGN_IDENTITY_RE" \
    --certificate-oidc-issuer "$COSIGN_OIDC_ISSUER" \
    "$manifest" >/dev/null 2>&1; then
    rm -f "$manifest" "$bundle"
    echo "${AUSPEX_VERIFY_LOG_PREFIX}: cosign FAILED to verify ${ver_root}/manifest.json against the pinned release identity — refusing to install" >&2
    exit "$AUSPEX_VERIFY_EX_COSIGN"
  fi
  m_version="$("$JQ_BIN" -r '.annotations["org.opencontainers.image.version"] // empty' "$manifest" 2>/dev/null)"
  if [ "$m_version" != "$version" ]; then
    rm -f "$manifest" "$bundle"
    echo "${AUSPEX_VERIFY_LOG_PREFIX}: the signed manifest is for '${m_version:-<none>}' but the requested path is version '${version}' — refusing (version substitution)" >&2
    exit "$AUSPEX_VERIFY_EX_DIGEST_ABSENT"
  fi
  # Hash the file: $(cat) drops the trailing newline, so the variable's bytes aren't the pinned ones.
  _VERIFIED_MANIFEST_DIGEST="$(sha256_of "$manifest")"
  _VERIFIED_MANIFEST_JSON="$(cat "$manifest")"
  _VERIFIED_MANIFEST_ROOT="$ver_root"
  rm -f "$manifest" "$bundle"
  echo "${AUSPEX_VERIFY_LOG_PREFIX}: manifest digest sha256:${_VERIFIED_MANIFEST_DIGEST} pins every binary of ${version} (signed manifest verified)"
}

# auspex-capture, the capture-only binary coding-tool hooks run on macOS and Linux (auspex ADR 0068), ships
# in every release from this version on (its pre-releases included) and in none before it.
AUSPEX_CAPTURE_SINCE="0.13.0"

# Sets CAPTURE_URL to auspex-capture beside <auspex_version_url>, which the caller must acquire fail-closed;
# empty, with a note, for a release before AUSPEX_CAPTURE_SINCE or a URL without that layout.
CAPTURE_URL=""
resolve_capture_url() { # <auspex_version_url>
  local url="$1" re='/releases/v?([0-9]+)\.([0-9]+)\.([0-9]+)[^/]*/[^/]+/[^/]+/auspex$' since s_major s_minor s_patch
  CAPTURE_URL=""
  if ! [[ "$url" =~ $re ]]; then
    echo "${AUSPEX_VERIFY_LOG_PREFIX}: note — ${url} is not a .../releases/<version>/<os>/<arch>/auspex path, so auspex-capture is not fetched; \`auspex install\` links it to auspex (slower hooks)" >&2
    return 0
  fi
  local major="${BASH_REMATCH[1]}" minor="${BASH_REMATCH[2]}" patch="${BASH_REMATCH[3]}"
  IFS=. read -r s_major s_minor s_patch <<<"$AUSPEX_CAPTURE_SINCE"
  since=0
  if [ "$major" -ne "$s_major" ]; then
    [ "$major" -gt "$s_major" ] && since=1
  elif [ "$minor" -ne "$s_minor" ]; then
    [ "$minor" -gt "$s_minor" ] && since=1
  else
    [ "$patch" -ge "$s_patch" ] && since=1
  fi
  if [ "$since" -eq 0 ]; then
    echo "${AUSPEX_VERIFY_LOG_PREFIX}: release ${major}.${minor}.${patch} predates auspex-capture (${AUSPEX_CAPTURE_SINCE}) — installing auspex alone"
    return 0
  fi
  CAPTURE_URL="${url%/auspex}/auspex-capture"
}

# Fetch an artifact from the global content-addressed blob namespace and SELF-VERIFY (verify: cosign — auspex
# ADR 0047). The blob lives at <base>/blobs/sha256/<digest> where <base> is everything before /releases/ in
# the version URL (the CDN/bucket root, or an internal-mirror prefix) — so the by-digest fetch tracks the
# same host as the version path. Self-verify asserts sha256(bytes) == the digest we asked for: for a
# resolved digest this seals the chain from the signed manifest to the installed bytes; for a directly-pinned
# digest (Chunk E) it IS the whole check (the key is the trust anchor). A mismatch means a corrupt/tampered
# blob — fail closed and remove the download.
fetch_blob_by_digest() { # <version_url_or_base> <digest> <out>
  local url="$1" digest="$2" out="$3" base blob_url got
  base="${url%%/releases/*}"
  if [ "$base" = "$url" ]; then base="${url%/}"; fi # already a base (no /releases/ segment)
  blob_url="${base}/blobs/sha256/${digest}"
  if ! fetch "$blob_url" "$out"; then
    rm -f "$out"
    echo "${AUSPEX_VERIFY_LOG_PREFIX}: could not fetch the content-addressed blob ${blob_url} — refusing to install" >&2
    exit "$AUSPEX_VERIFY_EX_FETCH"
  fi
  got="$(sha256_of "$out")"
  if [ "$got" != "$digest" ]; then
    rm -f "$out"
    echo "${AUSPEX_VERIFY_LOG_PREFIX}: by-digest self-verify FAILED — ${blob_url} hashes to ${got}, not ${digest} (corrupt or tampered blob) — refusing to install" >&2
    exit "$AUSPEX_VERIFY_EX_CHECKSUM"
  fi
  echo "${AUSPEX_VERIFY_LOG_PREFIX}: by-digest verified (sha256:${got})"
}

# The ONE raw-binary acquisition entrypoint shared by install.sh and the curl|sh bootstrap: fetch + verify
# per tier and write the TRUSTED bytes to <out> (fail-closed — the verify_* helpers exit non-zero on any
# failure, so a caller only ever promotes <out> to PATH on success). Owning the fetch here is deliberate:
# the cosign tier must NOT pull the version-path bytes and then discard them for the blob, so only
# checksum/none touch the version path; cosign resolves the digest then fetches the content-addressed blob.
#   cosign   — resolve version+os/arch → digest from the signed manifest, fetch the blob by digest, self-verify
#   checksum — fetch the version-path binary + its .sha256 sidecar; integrity only (no cosign/jq/manifest)
#   none     — fetch the version-path binary with NO verification (explicit opt-out)
acquire_verified() { # <version_url> <mode> <out>
  local url="$1" mode="$2" out="$3"
  case "$mode" in
    none)
      echo "${AUSPEX_VERIFY_LOG_PREFIX}: verify: none — installing WITHOUT integrity verification (not recommended for a remote source)" >&2
      if ! fetch "$url" "$out"; then
        rm -f "$out"
        echo "${AUSPEX_VERIFY_LOG_PREFIX}: failed to download ${url}" >&2
        exit "$AUSPEX_VERIFY_EX_FETCH"
      fi
      ;;
    checksum)
      if ! fetch "$url" "$out"; then
        rm -f "$out"
        echo "${AUSPEX_VERIFY_LOG_PREFIX}: failed to download ${url}" >&2
        exit "$AUSPEX_VERIFY_EX_FETCH"
      fi
      verify_sha256 "$out" "$url"
      ;;
    cosign)
      resolve_binary_digest "$url" # sets RESOLVED_DIGEST
      fetch_blob_by_digest "$url" "$RESOLVED_DIGEST" "$out"
      ;;
    *)
      echo "${AUSPEX_VERIFY_LOG_PREFIX}: unknown verify mode '${mode}' — expected cosign|checksum|none" >&2
      exit "$AUSPEX_VERIFY_EX_USAGE"
      ;;
  esac
}

# Pin-by-digest acquisition (auspex ADR 0047 — the version-free pin): fetch the artifact STRAIGHT from the
# global content-addressed blob (<base>/blobs/sha256/<digest>) and self-verify, bypassing the version →
# manifest resolution entirely. The digest IS the trust anchor — obtained out-of-band (from a
# once-cosign-verified manifest, an org-distributed pin, or the by-hand two-hop) — so no version, manifest,
# cosign, or jq is consulted; the by-digest self-verify (sha256(bytes) == digest) is the whole check, and it
# is version-free (a re-tag or de-index never moves it). <base> is the CDN/bucket root; a full version URL is
# also accepted (its root before /releases/ is used), so a caller can reuse the same source it already has.
acquire_by_digest() { # <base_or_version_url> <digest> <out>
  local base="$1" out="$3"
  normalize_pinned_digest "$2"
  echo "${AUSPEX_VERIFY_LOG_PREFIX}: pinning by digest sha256:${PINNED_DIGEST} (version-free; self-verify only)"
  fetch_blob_by_digest "$base" "$PINNED_DIGEST" "$out"
}

# Sets PINNED_DIGEST to <digest> as bare lowercase hex, or exits EX_USAGE unless it is a full sha256
# (optionally 'sha256:'-prefixed, any case).
PINNED_DIGEST=""
normalize_pinned_digest() { # <digest>
  local digest="${1#sha256:}"
  digest="$(printf '%s' "$digest" | tr 'A-F' 'a-f')"
  case "$digest" in
    "" | *[!0-9a-f]*)
      echo "${AUSPEX_VERIFY_LOG_PREFIX}: invalid pinned digest '${1}' — expected a 64-char sha256 hex (optionally 'sha256:'-prefixed)" >&2
      exit "$AUSPEX_VERIFY_EX_USAGE"
      ;;
  esac
  if [ "${#digest}" -ne 64 ]; then
    echo "${AUSPEX_VERIFY_LOG_PREFIX}: pinned digest '${1}' is not 64 hex chars — expected a full sha256" >&2
    exit "$AUSPEX_VERIFY_EX_USAGE"
  fi
  PINNED_DIGEST="$digest"
}

# Manifest pin: one digest for a whole release. Fetch the release's manifest by digest and self-verify it,
# read its version, and seed the verified-manifest cache with it, so acquire_verified <MANIFEST_BINARY_URL>
# cosign resolves every binary from the pinned manifest with no cosign. The digest is the trust anchor, as
# for acquire_by_digest. Sets MANIFEST_VERSION and MANIFEST_BINARY_URL (<base>/releases/<v>/<os>/<arch>/auspex).
MANIFEST_VERSION=""
MANIFEST_BINARY_URL=""
acquire_by_manifest_digest() { # <base_or_version_url> <digest> <os> <arch>
  local url="$1" os="$3" arch="$4" base manifest version re='^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'
  normalize_pinned_digest "$2"
  base="${url%%/releases/*}"
  base="${base%/}"
  echo "${AUSPEX_VERIFY_LOG_PREFIX}: pinning the release manifest by digest sha256:${PINNED_DIGEST} (self-verify; no cosign)"
  ensure_jq
  manifest="$(mktemp)"
  fetch_blob_by_digest "$base" "$PINNED_DIGEST" "$manifest"
  version="$("$JQ_BIN" -r '.annotations["org.opencontainers.image.version"] // empty' "$manifest" 2>/dev/null || true)"
  # The version names a URL path below, so only the tag shape the release identity signs is accepted.
  if ! [[ "$version" =~ $re ]]; then
    rm -f "$manifest"
    echo "${AUSPEX_VERIFY_LOG_PREFIX}: the pinned manifest's version annotation is not a release tag ('${version:-<none>}') — refusing to install" >&2
    exit "$AUSPEX_VERIFY_EX_DIGEST_ABSENT"
  fi
  _VERIFIED_MANIFEST_JSON="$(cat "$manifest")"
  _VERIFIED_MANIFEST_ROOT="${base}/releases/${version}"
  _VERIFIED_MANIFEST_DIGEST="$PINNED_DIGEST"
  _VERIFIED_MANIFEST_HOW="pinned manifest"
  rm -f "$manifest"
  MANIFEST_VERSION="$version"
  MANIFEST_BINARY_URL="${_VERIFIED_MANIFEST_ROOT}/${os}/${arch}/auspex"
  echo "${AUSPEX_VERIFY_LOG_PREFIX}: the pinned manifest is release ${version}"
}

# Provenance check for an artifact carrying its OWN per-artifact cosign bundle (the cross-runner .pkg/.msi,
# auspex ADR 0033 §9): the bundle is <artifact>.cosign.bundle beside it (or supplied via a URL/path). Unlike
# the raw-binary cosign path there is no manifest resolve — the signature is directly over the artifact bytes.
# <file> is the local artifact; <bundle_src> is the .cosign.bundle URL (fetched) or a local path.
verify_cosign_bundle() { # <file> <bundle_src>
  local file="$1" bundle_src="$2" bundle tmp_bundle=""
  ensure_cosign
  _require_trusted_root
  case "$bundle_src" in
    http://* | https://*)
      tmp_bundle="$(mktemp)"
      if ! fetch "$bundle_src" "$tmp_bundle"; then
        rm -f "$tmp_bundle"
        echo "${AUSPEX_VERIFY_LOG_PREFIX}: could not fetch the cosign bundle ${bundle_src} — refusing to install" >&2
        exit "$AUSPEX_VERIFY_EX_FETCH"
      fi
      bundle="$tmp_bundle"
      ;;
    *)
      if [ ! -f "$bundle_src" ]; then
        echo "${AUSPEX_VERIFY_LOG_PREFIX}: cosign bundle not found at ${bundle_src} — refusing to install" >&2
        exit "$AUSPEX_VERIFY_EX_FETCH"
      fi
      bundle="$bundle_src"
      ;;
  esac
  if ! "$COSIGN_BIN" verify-blob \
    --bundle "$bundle" \
    --trusted-root "$TRUSTED_ROOT" \
    --certificate-identity-regexp "$COSIGN_IDENTITY_RE" \
    --certificate-oidc-issuer "$COSIGN_OIDC_ISSUER" \
    "$file" >/dev/null 2>&1; then
    [ -n "$tmp_bundle" ] && rm -f "$tmp_bundle"
    echo "${AUSPEX_VERIFY_LOG_PREFIX}: cosign FAILED to verify ${file} against the pinned release identity — refusing to install" >&2
    exit "$AUSPEX_VERIFY_EX_COSIGN"
  fi
  [ -n "$tmp_bundle" ] && rm -f "$tmp_bundle"
  [ -n "$COSIGN_CLEANUP" ] && rm -f "$COSIGN_CLEANUP"
  echo "${AUSPEX_VERIFY_LOG_PREFIX}: cosign-verified (${file} signature valid for the pinned release identity)"
}

# Verify the release channel document (auspex ADR 0066) against the pinned CHANNEL identity, then require
# schema 1, well-formed tags and `minimum` <= `stable`, as auspex's own reader does. --min-sequence N refuses
# a lower `sequence`, a replay (ADR 0066 §3). Sets CHANNEL_SEQUENCE. It keeps a downloaded cosign or jq for
# the caller's next verify: run verify_lib_cleanup when done (a `trap … EXIT` also covers a refusal).
CHANNEL_SEQUENCE=""
verify_channel_document() { # <doc> <bundle> [--min-sequence N]
  if [ "$#" -lt 2 ]; then
    echo "${AUSPEX_VERIFY_LOG_PREFIX}: usage: verify_channel_document <doc> <bundle> [--min-sequence N]" >&2
    exit "$AUSPEX_VERIFY_EX_USAGE"
  fi
  local doc="$1" bundle="$2" min_seq="" seq
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --min-sequence)
        case "${2:-}" in
          "" | *[!0-9]*)
            echo "${AUSPEX_VERIFY_LOG_PREFIX}: --min-sequence needs a whole number, got '${2:-}'" >&2
            exit "$AUSPEX_VERIFY_EX_USAGE"
            ;;
        esac
        min_seq="$(printf '%s' "$2" | sed 's/^0*//')" # JSON numbers can't have leading zeros
        min_seq="${min_seq:-0}"
        shift 2
        ;;
      *)
        echo "${AUSPEX_VERIFY_LOG_PREFIX}: verify_channel_document: unknown option '$1'" >&2
        exit "$AUSPEX_VERIFY_EX_USAGE"
        ;;
    esac
  done
  if [ ! -f "$doc" ] || [ ! -f "$bundle" ]; then
    echo "${AUSPEX_VERIFY_LOG_PREFIX}: channel document or its bundle not found (${doc}, ${bundle}) — refusing to trust it" >&2
    exit "$AUSPEX_VERIFY_EX_FETCH"
  fi
  ensure_cosign
  ensure_jq
  _require_trusted_root
  if ! "$COSIGN_BIN" verify-blob \
    --bundle "$bundle" \
    --trusted-root "$TRUSTED_ROOT" \
    --certificate-identity-regexp "$COSIGN_CHANNEL_IDENTITY_RE" \
    --certificate-oidc-issuer "$COSIGN_OIDC_ISSUER" \
    "$doc" >/dev/null 2>&1; then
    echo "${AUSPEX_VERIFY_LOG_PREFIX}: cosign FAILED to verify ${doc} against the pinned channel identity — refusing to trust it" >&2
    exit "$AUSPEX_VERIFY_EX_COSIGN"
  fi
  # vlt is SemVer 2.0.0 precedence: numeric parts compare as numbers, and a pre-release sorts below its
  # release; within pre-releases, numeric identifiers sort below alphanumeric ones and compare as numbers.
  # shellcheck disable=SC2016  # $a/$b/$x/$y/$d are jq variables, deliberately single-quoted (not shell)
  if ! "$JQ_BIN" -e '
    def tag: . == null or (type == "string" and test("^v[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.-]+)?$"));
    def parts: capture("^v(?<core>[0-9]+\\.[0-9]+\\.[0-9]+)(-(?<pre>.+))?$")
      | {core: (.core | split(".") | map(tonumber)), pre: (if .pre then .pre | split(".") else [] end)};
    def num: test("^[0-9]+$");
    def idlt($a; $b):
      if ($a | num) and ($b | num) then ($a | tonumber) < ($b | tonumber)
      elif ($a | num) or ($b | num) then ($a | num)
      else $a < $b end;
    def prelt($a; $b):
      if $a == $b or $a == [] then false
      elif $b == [] then true
      else [range(0; [($a | length), ($b | length)] | min) | select($a[.] != $b[.])] as $d
        | if $d == [] then ($a | length) < ($b | length) else idlt($a[$d[0]]; $b[$d[0]]) end
      end;
    def vlt($x; $y):
      ($x | parts) as $a | ($y | parts) as $b
      | if $a.core != $b.core then $a.core < $b.core else prelt($a.pre; $b.pre) end;
    .schema == 1
    and (.sequence | type == "number" and . >= 1 and . == floor and . < 9007199254740992)
    and (.latest | tag) and (.stable | tag) and (.minimum | tag)
    and (.minimum == null or (.stable != null and (vlt(.stable; .minimum) | not)))' "$doc" >/dev/null 2>&1; then
    echo "${AUSPEX_VERIFY_LOG_PREFIX}: ${doc} is signed but isn't a schema-1 channel document — refusing to trust it" >&2
    exit "$AUSPEX_VERIFY_EX_CHANNEL_INVALID"
  fi
  seq="$("$JQ_BIN" -r '.sequence' "$doc")"
  # Compared in jq: the shell's -lt errors past 64 bits, and inside an if that error would accept.
  # shellcheck disable=SC2016  # $min is a jq --argjson variable, deliberately single-quoted (not shell)
  if [ -n "$min_seq" ] && ! "$JQ_BIN" -e --argjson min "$min_seq" '.sequence >= $min' "$doc" >/dev/null 2>&1; then
    echo "${AUSPEX_VERIFY_LOG_PREFIX}: channel document sequence ${seq} is below ${min_seq}, the last one accepted — refusing a replayed document" >&2
    exit "$AUSPEX_VERIFY_EX_CHANNEL_REPLAY"
  fi
  CHANNEL_SEQUENCE="$seq"
  echo "${AUSPEX_VERIFY_LOG_PREFIX}: channel document verified (sequence ${seq}, signed by the pinned channel identity)"
}

# For callers of verify_channel_document, which keeps the cosign or jq it downloaded.
verify_lib_cleanup() {
  [ -z "$COSIGN_CLEANUP" ] || rm -f "$COSIGN_CLEANUP"
  [ -z "$JQ_CLEANUP" ] || rm -f "$JQ_CLEANUP"
  COSIGN_CLEANUP=""
  JQ_CLEANUP=""
}
