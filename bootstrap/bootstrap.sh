# shellcheck shell=bash
# auspex curl|bash bootstrap (macOS/Linux) — fetch + fail-closed verify + place on PATH, the portable
# non-devcontainer acquisition path. Served from this repo's GitHub Releases as a SELF-CONTAINED assembled
# script (origin #2, independent of the artifact CDN); see bootstrap/assemble.sh. The artifact itself comes
# from the CDN (origin #1). The script's OWN bytes are trusted via TLS + origin (a piped script cannot
# verify itself); it verifies the DOWNLOADED BINARY fail-closed against the origin-#2 trust anchor.
#
# It shares the ONE verify recipe (src/span-auspex/verify-lib.sh): in a repo checkout it sources the lib;
# in the assembled release form the lib + embedded trusted_root.json are inlined ABOVE this logic (the
# assembler sets _AUSPEX_VERIFY_LIB_SOURCED + AUSPEX_TRUSTED_ROOT), so this block is skipped. Either way
# there is a single verifier, not a bootstrap-specific copy.
#
# Usage (piped):  curl -fsSL <release-asset-url>/auspex-install.sh | bash -s -- --version v0.1.0
# The assembled script uses bash-only constructs (indirect ${!pinvar} expansion, BASH_SOURCE), so pipe to
# `bash`, not `sh` — under dash (Debian/Ubuntu /bin/sh) it aborts on `set -o pipefail`.
# Or download-then-run for the security-conscious (verify the script's own detached sig first; README).

set -euo pipefail

AUSPEX_VERIFY_LOG_PREFIX="auspex install"

# --- share the ONE verify recipe -------------------------------------------------------------------------
# Assembled release form inlines the lib above; a checkout sources it (TRUSTED_ROOT auto-resolves next to
# the lib, so no AUSPEX_TRUSTED_ROOT needed here).
if [ -z "${_AUSPEX_VERIFY_LIB_SOURCED:-}" ]; then
  _BOOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  # shellcheck source=src/span-auspex/verify-lib.sh
  # shellcheck disable=SC1091  # runtime-resolved; source= aids `shellcheck -x`
  . "${_BOOT_DIR}/../src/span-auspex/verify-lib.sh"
fi

# --- options ---------------------------------------------------------------------------------------------
# Artifact source base (origin #1) — REQUIRED, with NO baked-in default: this public repo is intentionally
# host-agnostic (matching the Dev Container Feature's pluggable, defaultless binaryUri), so the distribution
# host is never committed here. Supply it via --base-url / AUSPEX_BASE_URL (your auspex distribution host,
# from your install instructions) or a full --url. Point it at an internal mirror for an air-gapped fleet.
BASE_URL="${AUSPEX_BASE_URL:-}"
VERSION="${AUSPEX_VERSION:-}"
VERIFY="${AUSPEX_VERIFY:-cosign}"
BIN_DIR="${AUSPEX_BIN_DIR:-}"
BINARY_URL="${AUSPEX_BINARY_URL:-}" # full override; bypasses BASE_URL/version/os/arch derivation
DIGEST="${AUSPEX_DIGEST:-}"         # pin a raw sha256 (of the artifact) — installs the version-free blob directly

usage() {
  cat >&2 <<EOF
auspex install — fetch, verify, and install the auspex binary.

  --version <tag>     auspex release tag to install (e.g. v0.1.0). Optional: when omitted (and no
                      --url/--digest), resolves the CDN's 'latest' pointer to a concrete tag, then verifies.
  --verify <mode>     cosign (default) | checksum | none (ignored with --digest — self-verify is the check)
  --base-url <url>    artifact source base — REQUIRED unless --url (your auspex distribution host / mirror)
  --url <url>         full binary URL (overrides --base-url/--version/os/arch derivation)
  --digest <sha256>   pin by content: install <base-url>/blobs/sha256/<digest> directly and self-verify
                      (version-free — survives a re-tag; needs --base-url, or --url to derive the host)
  --bin-dir <dir>     install dir (default: /usr/local/bin if writable, else \$HOME/.local/bin)
  -h, --help          this help

Env equivalents: AUSPEX_VERSION, AUSPEX_VERIFY, AUSPEX_BASE_URL, AUSPEX_BINARY_URL, AUSPEX_DIGEST,
AUSPEX_BIN_DIR, AUSPEX_COSIGN_BASE_URL (mirror the pinned cosign CLI for air-gapped installs).
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version) VERSION="${2:-}"; shift 2 ;;
    --verify) VERIFY="${2:-}"; shift 2 ;;
    --base-url) BASE_URL="${2:-}"; shift 2 ;;
    --url) BINARY_URL="${2:-}"; shift 2 ;;
    --digest) DIGEST="${2:-}"; shift 2 ;;
    --bin-dir) BIN_DIR="${2:-}"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) echo "${AUSPEX_VERIFY_LOG_PREFIX}: unknown argument '$1'" >&2; usage; exit "$AUSPEX_VERIFY_EX_USAGE" ;;
  esac
done

case "$VERIFY" in
  cosign | checksum | none) ;;
  *) echo "${AUSPEX_VERIFY_LOG_PREFIX}: --verify must be one of cosign|checksum|none (got '${VERIFY}')" >&2; exit "$AUSPEX_VERIFY_EX_USAGE" ;;
esac

# --- OS/arch detection + URL derivation ------------------------------------------------------------------
detect_os() {
  case "$(uname -s | tr '[:upper:]' '[:lower:]')" in
    linux) echo linux ;;
    darwin) echo darwin ;;
    *) echo "${AUSPEX_VERIFY_LOG_PREFIX}: unsupported OS '$(uname -s)' — this bootstrap covers macOS/Linux; on Windows use the PowerShell installer (auspex-install.ps1)" >&2; exit "$AUSPEX_VERIFY_EX_ENV" ;;
  esac
}
detect_arch() {
  case "$(uname -m)" in
    x86_64 | amd64) echo amd64 ;;
    aarch64 | arm64) echo arm64 ;;
    *) echo "${AUSPEX_VERIFY_LOG_PREFIX}: unsupported CPU '$(uname -m)'" >&2; exit "$AUSPEX_VERIFY_EX_ENV" ;;
  esac
}

PIN_BASE="" # host root for a pin-by-digest fetch
if [ -n "$DIGEST" ]; then
  # Pin-by-digest needs only a host root (the blob is version/os/arch-free). Prefer --base-url; else derive
  # it from a full --url (everything before /releases/). No version/os/arch derivation.
  if [ -n "$BASE_URL" ]; then
    PIN_BASE="${BASE_URL%/}"
  elif [ -n "$BINARY_URL" ]; then
    PIN_BASE="${BINARY_URL%%/releases/*}"
  else
    echo "${AUSPEX_VERIFY_LOG_PREFIX}: --digest needs a host — pass --base-url <url> (or a full --url to derive it), or set AUSPEX_BASE_URL" >&2
    usage
    exit "$AUSPEX_VERIFY_EX_USAGE"
  fi
elif [ -z "$BINARY_URL" ]; then
  if [ -z "$BASE_URL" ]; then
    echo "${AUSPEX_VERIFY_LOG_PREFIX}: no artifact source — pass --base-url <url> (your auspex distribution host; see your install instructions) or --url <full-url>, or set AUSPEX_BASE_URL" >&2
    usage
    exit "$AUSPEX_VERIFY_EX_USAGE"
  fi
  if [ -z "$VERSION" ]; then
    # No explicit --version: resolve the CDN's canonical `latest` pointer to a CONCRETE tag, then verify
    # against that tag. `releases/latest/` is a mutable mirror of the highest published version and carries a
    # `VERSION` marker naming the tag it mirrors; resolving to the concrete tag keeps verify: cosign
    # tag-bound (the signed manifest's version annotation must equal the tag in the URL — a bare "latest"
    # would fail that check). Pass --version <tag> (or --digest) to pin instead.
    echo "${AUSPEX_VERIFY_LOG_PREFIX}: no --version given — resolving latest from ${BASE_URL%/}/releases/latest/VERSION" >&2
    VERSION="$(curl -fsSL "${BASE_URL%/}/releases/latest/VERSION" 2>/dev/null | tr -d '[:space:]' || true)"
    if [ -z "$VERSION" ]; then
      echo "${AUSPEX_VERIFY_LOG_PREFIX}: could not resolve 'latest' (no ${BASE_URL%/}/releases/latest/VERSION) — pass --version <tag> (e.g. v0.1.0) or --digest <sha256>" >&2
      exit "$AUSPEX_VERIFY_EX_FETCH"
    fi
    case "$VERSION" in
      v[0-9]*) ;;
      *) echo "${AUSPEX_VERIFY_LOG_PREFIX}: resolved 'latest' is not a version tag ('${VERSION}') — refusing" >&2; exit "$AUSPEX_VERIFY_EX_FETCH" ;;
    esac
    echo "${AUSPEX_VERIFY_LOG_PREFIX}: resolved latest -> ${VERSION}" >&2
  fi
  OS="$(detect_os)"
  ARCH="$(detect_arch)"
  BINARY_URL="${BASE_URL%/}/releases/${VERSION}/${OS}/${ARCH}/auspex"
fi

# --- install dir -----------------------------------------------------------------------------------------
if [ -z "$BIN_DIR" ]; then
  if [ -w /usr/local/bin ] 2>/dev/null; then
    BIN_DIR=/usr/local/bin
  else
    BIN_DIR="${HOME}/.local/bin"
  fi
fi
mkdir -p "$BIN_DIR" 2>/dev/null || {
  echo "${AUSPEX_VERIFY_LOG_PREFIX}: cannot create install dir ${BIN_DIR} — pass --bin-dir to a writable path (or re-run with sudo)" >&2
  exit "$AUSPEX_VERIFY_EX_ENV"
}
BIN_DEST="${BIN_DIR%/}/auspex"

# --- fetch → verify (fail-closed) → place ----------------------------------------------------------------
# Clean up the download temp AND (in the assembled release form) the embedded trust-root temp on any exit.
dl_tmp=""
_boot_cleanup() { rm -f "${dl_tmp:-}" "${_AUSPEX_EMBEDDED_ROOT:-}"; }
trap _boot_cleanup EXIT

dl_tmp="$(mktemp)"
# Both write the TRUSTED bytes to dl_tmp and only return on success (fail-closed), so a tampered artifact is
# never placed on PATH. --digest pins the version-free content-addressed blob (<base>/blobs/sha256/<digest>)
# and self-verifies; otherwise verify: cosign resolves the signed version→digest manifest and fetches the
# blob (the version URL is only the resolution anchor), while checksum/none fetch the version path directly.
if [ -n "$DIGEST" ]; then
  echo "${AUSPEX_VERIFY_LOG_PREFIX}: pinning by digest (host ${PIN_BASE})"
  acquire_by_digest "$PIN_BASE" "$DIGEST" "$dl_tmp"
else
  echo "${AUSPEX_VERIFY_LOG_PREFIX}: acquiring binary (verify: ${VERIFY}) for ${BINARY_URL}"
  acquire_verified "$BINARY_URL" "$VERIFY" "$dl_tmp"
fi

chmod 0755 "$dl_tmp"
mv "$dl_tmp" "$BIN_DEST"
dl_tmp="" # moved into place; nothing to clean
echo "${AUSPEX_VERIFY_LOG_PREFIX}: installed ${BIN_DEST}"
case ":${PATH}:" in
  *":${BIN_DIR%/}:"*) ;;
  *) echo "${AUSPEX_VERIFY_LOG_PREFIX}: note — ${BIN_DIR} is not on your PATH; add it (e.g. export PATH=\"${BIN_DIR}:\$PATH\")" >&2 ;;
esac
