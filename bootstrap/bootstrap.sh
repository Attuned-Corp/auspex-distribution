# shellcheck shell=bash
# auspex curl|sh bootstrap (macOS/Linux) — fetch + fail-closed verify + place on PATH, the portable
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
# Usage (piped):  curl -fsSL <release-asset-url>/auspex-install.sh | sh -s -- --version v0.1.0
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

usage() {
  cat >&2 <<EOF
auspex install — fetch, verify, and install the auspex binary.

  --version <tag>     auspex release tag to install (e.g. v0.1.0). Required unless --url is given.
  --verify <mode>     cosign (default) | checksum | none
  --base-url <url>    artifact source base — REQUIRED unless --url (your auspex distribution host / mirror)
  --url <url>         full binary URL (overrides --base-url/--version/os/arch derivation)
  --bin-dir <dir>     install dir (default: /usr/local/bin if writable, else \$HOME/.local/bin)
  -h, --help          this help

Env equivalents: AUSPEX_VERSION, AUSPEX_VERIFY, AUSPEX_BASE_URL, AUSPEX_BINARY_URL, AUSPEX_BIN_DIR,
AUSPEX_COSIGN_BASE_URL (mirror the pinned cosign CLI for air-gapped installs).
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version) VERSION="${2:-}"; shift 2 ;;
    --verify) VERIFY="${2:-}"; shift 2 ;;
    --base-url) BASE_URL="${2:-}"; shift 2 ;;
    --url) BINARY_URL="${2:-}"; shift 2 ;;
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

if [ -z "$BINARY_URL" ]; then
  if [ -z "$BASE_URL" ]; then
    echo "${AUSPEX_VERIFY_LOG_PREFIX}: no artifact source — pass --base-url <url> (your auspex distribution host; see your install instructions) or --url <full-url>, or set AUSPEX_BASE_URL" >&2
    usage
    exit "$AUSPEX_VERIFY_EX_USAGE"
  fi
  if [ -z "$VERSION" ]; then
    echo "${AUSPEX_VERIFY_LOG_PREFIX}: --version is required (there is no 'latest' alias on the download host) — e.g. --version v0.1.0" >&2
    usage
    exit "$AUSPEX_VERIFY_EX_USAGE"
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

echo "${AUSPEX_VERIFY_LOG_PREFIX}: downloading ${BINARY_URL}"
dl_tmp="$(mktemp)"
fetch "$BINARY_URL" "$dl_tmp"

case "$VERIFY" in
  none)
    echo "${AUSPEX_VERIFY_LOG_PREFIX}: --verify none — installing WITHOUT verification (not recommended)" >&2
    ;;
  checksum)
    verify_sha256 "$dl_tmp" "$BINARY_URL"
    ;;
  cosign)
    verify_sha256 "$dl_tmp" "$BINARY_URL"
    verify_cosign "$dl_tmp" "$BINARY_URL"
    ;;
esac

chmod 0755 "$dl_tmp"
mv "$dl_tmp" "$BIN_DEST"
dl_tmp="" # moved into place; nothing to clean
echo "${AUSPEX_VERIFY_LOG_PREFIX}: installed ${BIN_DEST}"
case ":${PATH}:" in
  *":${BIN_DIR%/}:"*) ;;
  *) echo "${AUSPEX_VERIFY_LOG_PREFIX}: note — ${BIN_DIR} is not on your PATH; add it (e.g. export PATH=\"${BIN_DIR}:\$PATH\")" >&2 ;;
esac
