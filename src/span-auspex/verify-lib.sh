# shellcheck shell=bash
# Shared pinned-cosign verify recipe for auspex release artifacts — the ONE verifier for this repo,
# sourced by three callers: the Dev Container Feature's install.sh (container build), the curl|sh
# bootstrap (assembled into the released installer, see bootstrap/), and the MDM verify-before-install
# gate (mdm/). It is a LIBRARY: sourcing it defines constants + functions and runs nothing.
#
# What it proves (verify: cosign, the default): the raw artifact's digest lives in the version-root
# checksums.txt, and THAT file is cosign keyless-signed by the auspex release workflow (auspex ADR 0033
# §4/§5). So we keyless-verify checksums.txt against the pinned release identity + a pinned Sigstore
# trusted_root.json (FULLY LOCAL — cosign v3 checks the new-format bundle's embedded Rekor inclusion proof
# against the shipped keys; no TUF/Rekor/Fulcio network), then confirm the artifact's digest is a line in
# that now-trusted file. Per-artifact .pkg/.msi carry their own .cosign.bundle (verify_cosign_bundle).
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
AUSPEX_VERIFY_EX_FETCH=11         # required material could not be fetched (sidecar / checksums.txt / bundle)
AUSPEX_VERIFY_EX_CHECKSUM=12      # SHA-256 mismatch against the .sha256 sidecar
AUSPEX_VERIFY_EX_COSIGN=13        # cosign verify-blob failed (bad signature OR identity/issuer mismatch)
AUSPEX_VERIFY_EX_DIGEST_ABSENT=14 # cosign verified checksums.txt, but the artifact's digest is not in it
AUSPEX_VERIFY_EX_COSIGN_PROVISION=15 # pinned cosign could not be provisioned (download / hash mismatch)

# Pinned keyless-signing identity for the auspex release workflow — the binary SIGNER lives in the private
# Attuned-Corp/auspex repo, so this stays in LOCK-STEP with that repo's signing descriptor
# (tools/release/signing-identity.env, mirrored by release.yml + .goreleaser.yaml; auspex ADR 0033 §4/§5).
# The cert identity is anchored (^…$) and dot-escaped to the auspex release workflow on a SEMVER tag ref
# (incl. an optional pre-release, e.g. v1.2.3 / v0.0.1-rc1), owner matched case-insensitively. Anchoring to
# semver — not any v* tag — keeps the trust surface to the tag shapes the release actually cuts. The
# reconcile guard fails CI if this drifts from auspex's signing descriptor.
COSIGN_IDENTITY_RE='^https://github\.com/(?i:attuned-corp)/auspex/\.github/workflows/release\.yml@refs/tags/v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'
COSIGN_OIDC_ISSUER='https://token.actions.githubusercontent.com'

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

# Assert the pinned trust root is present before any cosign verify (fail closed on an incomplete checkout /
# assembled bootstrap missing its embedded root).
_require_trusted_root() {
  if [ ! -f "$TRUSTED_ROOT" ]; then
    echo "${AUSPEX_VERIFY_LOG_PREFIX}: missing pinned trust root at ${TRUSTED_ROOT} — this checkout/installer is incomplete; reinstall or use the 'checksum' tier" >&2
    exit "$AUSPEX_VERIFY_EX_ENV"
  fi
}

# Provenance check for a checksums.txt-covered artifact (verify: cosign — the DEFAULT for the raw binary):
# derive the version root from the path-encoded URL (.../releases/<v>/<os>/<arch>/auspex → strip
# <os>/<arch>/<binary>), keyless-verify checksums.txt against the pinned identity + trusted_root.json, then
# confirm the artifact's digest is a line in that now-trusted file. A digest-membership check is
# version/arch-agnostic and survives verify running before the binary is renamed.
verify_cosign() { # <file> <url>
  local file="$1" url="$2" root checks bundle got
  ensure_cosign
  _require_trusted_root
  root="$(dirname "$(dirname "$(dirname "$url")")")"
  checks="$(mktemp)"
  bundle="$(mktemp)"
  if ! fetch "${root}/checksums.txt" "$checks" || ! fetch "${root}/checksums.txt.cosign.bundle" "$bundle"; then
    rm -f "$checks" "$bundle"
    echo "${AUSPEX_VERIFY_LOG_PREFIX}: could not fetch ${root}/checksums.txt(.cosign.bundle) — is this a signed release published under the ADR 0045 layout?" >&2
    exit "$AUSPEX_VERIFY_EX_FETCH"
  fi
  if ! "$COSIGN_BIN" verify-blob \
    --bundle "$bundle" \
    --trusted-root "$TRUSTED_ROOT" \
    --certificate-identity-regexp "$COSIGN_IDENTITY_RE" \
    --certificate-oidc-issuer "$COSIGN_OIDC_ISSUER" \
    "$checks" >/dev/null 2>&1; then
    rm -f "$checks" "$bundle"
    echo "${AUSPEX_VERIFY_LOG_PREFIX}: cosign FAILED to verify ${root}/checksums.txt against the pinned release identity — refusing to install" >&2
    exit "$AUSPEX_VERIFY_EX_COSIGN"
  fi
  got="$(sha256_of "$file")"
  if ! grep -q -- "$got" "$checks"; then
    rm -f "$checks" "$bundle"
    echo "${AUSPEX_VERIFY_LOG_PREFIX}: the artifact's digest ${got} is not present in the cosign-verified checksums.txt — refusing to install" >&2
    exit "$AUSPEX_VERIFY_EX_DIGEST_ABSENT"
  fi
  rm -f "$checks" "$bundle"
  [ -n "$COSIGN_CLEANUP" ] && rm -f "$COSIGN_CLEANUP"
  echo "${AUSPEX_VERIFY_LOG_PREFIX}: cosign-verified (checksums.txt signed by the release workflow; artifact digest present)"
}

# Provenance check for an artifact carrying its OWN per-artifact cosign bundle (the cross-runner .pkg/.msi,
# auspex ADR 0033 §9): the bundle is <artifact>.cosign.bundle beside it (or supplied via a URL/path). Unlike
# verify_cosign there is no checksums.txt indirection — the signature is directly over the artifact bytes.
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
