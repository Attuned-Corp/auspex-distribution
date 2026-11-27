# shellcheck shell=bash
# auspex MDM verify-before-install gate (macOS Mosyle .pkg / any bash-capable managed runner). Verifies a
# staged (or fetched) installer + its per-artifact cosign bundle FAIL-CLOSED against the pinned release
# identity using the ONE shared verify recipe (src/span-auspex/verify-lib.sh: pinned cosign +
# trusted_root.json), and REFUSES (non-zero exit) on any verification failure so the managed deploy never
# installs an unverified/tampered package. It does NOT run the native installer itself — the MDM recipe
# chains `&& installer -pkg …` (macOS) so a non-zero exit aborts the install (see mdm/README.md). This adds
# the cosign PROVENANCE binding (which workflow/tag built it) on top of the OS-native Gatekeeper gate, and
# brings the managed channel to parity with the Dev Container Feature. Windows/Intune use verify-gate.ps1.
#
# Post-trust vs. the bootstrap/Feature (first-acquisition): the fleet runner is expected to carry a
# PRE-PROVISIONED pinned cosign baked into the image, so verify runs with NO Fulcio/Rekor/TUF/GitHub egress
# — CDN-only to fetch the .pkg/.msi + bundle, or fully offline for a pre-staged file (docs/networking.md).
#
# It shares the ONE verify recipe: in a repo checkout it sources the lib; in the assembled release form
# (dist/auspex-verify-gate.sh) the lib + embedded trusted_root.json are inlined ABOVE this logic, so the
# source block is skipped. Either way there is a single verifier, not a gate-specific copy.
#
# Usage:  verify-gate.sh --installer /path/auspex.pkg              # verify a pre-staged installer
#         verify-gate.sh --url https://<cdn>/…/auspex.pkg --out /tmp/auspex.pkg   # fetch then verify
#         verify-gate.sh --base-url https://<cdn> --version v1.2.3 --out /tmp/auspex.pkg   # that release's macOS .pkg
set -euo pipefail

AUSPEX_VERIFY_LOG_PREFIX="auspex mdm-gate"

# --- share the ONE verify recipe -------------------------------------------------------------------------
if [ -z "${_AUSPEX_VERIFY_LIB_SOURCED:-}" ]; then
  _GATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  # shellcheck source=src/span-auspex/verify-lib.sh
  # shellcheck disable=SC1091  # runtime-resolved; source= aids `shellcheck -x`
  . "${_GATE_DIR}/../src/span-auspex/verify-lib.sh"
fi

# --- options ---------------------------------------------------------------------------------------------
INSTALLER=""                 # local path to the staged .pkg/.msi to verify
URL=""                       # OR a CDN URL to fetch the installer from (origin #1) before verifying
VERSION=""                   # OR an auspex release tag: fetch that release's installer from BASE_URL
BASE_URL="${AUSPEX_BASE_URL:-}" # the download host for --version; no default, the host is never committed here
OS="darwin"                  # --version: darwin (.pkg) | windows (.msi)
ARCH=""                      # --version --os windows: amd64 (default) | arm64
BUNDLE=""                    # per-artifact .cosign.bundle (path or URL); default: <installer|url>.cosign.bundle
OUT=""                       # where the download is saved
OUT_DIR=""                   # OR the directory to save it in under its published file name
VERIFY="cosign"              # cosign (default) | none (explicit, discouraged escape hatch)

usage() {
  cat >&2 <<EOF
auspex mdm-gate — verify a managed installer (.pkg/.msi) before install; fail-closed.

  --installer <path>  local, already-staged installer to verify
  --url <url>         CDN URL to fetch the installer from, then verify (origin #1)
  --version <tag>     auspex release to fetch the installer of (e.g. v1.2.3 or 1.2.3), then verify it carries
                      that release's own signature. Needs --base-url.
  --base-url <url>    your auspex download host (https://…), from your install instructions. Env: AUSPEX_BASE_URL
  --os <os>           with --version: darwin (default, the .pkg) | windows (the .msi)
  --arch <arch>       with --version --os windows: amd64 (default) | arm64
  --out <path>        where to save the download
  --out-dir <dir>     OR the directory to save it in, under its published file name
                      (default: --version saves to the current directory; --url to a temp file)
  --bundle <path|url> per-artifact cosign bundle (default: the installer path/url + '.cosign.bundle')
  --verify <mode>     cosign (default) | none (explicit opt-out — NOT recommended for a security agent)
  -h, --help          this help

Exit 0 = verified (safe to install); non-zero = REFUSED (do not install). Exit codes: 2 usage, 11 fetch,
13 cosign (bad signature or identity/issuer mismatch), 15 cosign-provision, 16 environment.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --installer) INSTALLER="${2:-}"; shift 2 ;;
    --url) URL="${2:-}"; shift 2 ;;
    --version) VERSION="${2:-}"; shift 2 ;;
    --base-url) BASE_URL="${2:-}"; shift 2 ;;
    --os) OS="${2:-}"; shift 2 ;;
    --arch) ARCH="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --out-dir) OUT_DIR="${2:-}"; shift 2 ;;
    --bundle) BUNDLE="${2:-}"; shift 2 ;;
    --verify) VERIFY="${2:-}"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) echo "${AUSPEX_VERIFY_LOG_PREFIX}: unknown argument '$1'" >&2; usage; exit "$AUSPEX_VERIFY_EX_USAGE" ;;
  esac
done

case "$VERIFY" in
  cosign | none) ;;
  *) echo "${AUSPEX_VERIFY_LOG_PREFIX}: --verify must be cosign|none (got '${VERIFY}')" >&2; exit "$AUSPEX_VERIFY_EX_USAGE" ;;
esac

sources=0
for s in "$INSTALLER" "$URL" "$VERSION"; do
  if [ -n "$s" ]; then sources=$((sources + 1)); fi
done
if [ "$sources" -gt 1 ]; then
  echo "${AUSPEX_VERIFY_LOG_PREFIX}: pass one of --installer, --url or --version, not several" >&2
  exit "$AUSPEX_VERIFY_EX_USAGE"
fi
if [ "$sources" -eq 0 ]; then
  echo "${AUSPEX_VERIFY_LOG_PREFIX}: one of --installer <path>, --url <url> or --version <tag> is required" >&2
  usage
  exit "$AUSPEX_VERIFY_EX_USAGE"
fi
if [ -n "$OUT" ] && [ -n "$OUT_DIR" ]; then
  echo "${AUSPEX_VERIFY_LOG_PREFIX}: pass --out OR --out-dir, not both" >&2
  exit "$AUSPEX_VERIFY_EX_USAGE"
fi
if [ -n "$OUT" ] && [ -d "$OUT" ]; then
  echo "${AUSPEX_VERIFY_LOG_PREFIX}: --out ${OUT} is a directory — pass --out-dir to save in it" >&2
  exit "$AUSPEX_VERIFY_EX_USAGE"
fi
if [ -n "$INSTALLER" ] && { [ -n "$OUT" ] || [ -n "$OUT_DIR" ]; }; then
  echo "${AUSPEX_VERIFY_LOG_PREFIX}: --out and --out-dir apply to a download, not to --installer" >&2
  exit "$AUSPEX_VERIFY_EX_USAGE"
fi
if [ -z "$VERSION" ] && { [ "$OS" != darwin ] || [ -n "$ARCH" ]; }; then
  echo "${AUSPEX_VERIFY_LOG_PREFIX}: --os and --arch pick the installer for --version" >&2
  exit "$AUSPEX_VERIFY_EX_USAGE"
fi

if [ -n "$VERSION" ]; then
  case "$VERSION" in v*) ;; *) VERSION="v${VERSION}" ;; esac
  release_tag_re='^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'
  if ! [[ "$VERSION" =~ $release_tag_re ]]; then
    echo "${AUSPEX_VERIFY_LOG_PREFIX}: --version must be a release tag such as v1.2.3 (got '${VERSION}')" >&2
    exit "$AUSPEX_VERIFY_EX_USAGE"
  fi
  if [ -z "$BASE_URL" ]; then
    echo "${AUSPEX_VERIFY_LOG_PREFIX}: --version needs your auspex download host — pass --base-url <url> (from your install instructions) or set AUSPEX_BASE_URL" >&2
    exit "$AUSPEX_VERIFY_EX_USAGE"
  fi
  case "${OS}/${ARCH}" in
    darwin/) URL="${BASE_URL%/}/releases/${VERSION}/darwin/auspex_${VERSION#v}_darwin_universal.pkg" ;;
    windows/ | windows/amd64 | windows/arm64)
      URL="${BASE_URL%/}/releases/${VERSION}/windows/auspex_${VERSION#v}_windows_${ARCH:-amd64}.msi" ;;
    darwin/*)
      echo "${AUSPEX_VERIFY_LOG_PREFIX}: the macOS .pkg is universal — --arch applies only to --os windows" >&2
      exit "$AUSPEX_VERIFY_EX_USAGE" ;;
    *)
      echo "${AUSPEX_VERIFY_LOG_PREFIX}: --os must be darwin|windows and --arch amd64|arm64 (got '${OS}' '${ARCH}')" >&2
      exit "$AUSPEX_VERIFY_EX_USAGE" ;;
  esac
  # The library accepts any release's signature. Pin it to this tag's, or a genuine older installer served
  # at this release's URL would verify.
  COSIGN_IDENTITY_RE="${COSIGN_IDENTITY_RE%%@refs/tags/*}@refs/tags/${VERSION//./\\.}\$"
  [ -z "$OUT" ] && [ -z "$OUT_DIR" ] && OUT_DIR="."
fi
[ -n "$OUT_DIR" ] && OUT="${OUT_DIR%/}/${URL##*/}"

# --- fetch (if --url) → verify (fail-closed) -------------------------------------------------------------
# A download we created is removed on ANY non-zero exit so a refused/unverified installer is never left on
# disk (fail-closed); a pre-staged --installer is left untouched. verify_* funcs exit directly on failure.
# A download to --out lands beside it and replaces it only once verified, so a failed run keeps a good copy.
_fetched_tmp=""
# Preserve the real exit status: a bare `[ -n "" ] && …` tail would return non-zero and CLOBBER a
# fail-closed exit code (e.g. 13) down to 1 (bash EXIT-trap semantics).
_gate_cleanup() { local rc=$?; [ -n "$_fetched_tmp" ] && rm -f "$_fetched_tmp"; return "$rc"; }
trap _gate_cleanup EXIT

if [ -n "$URL" ]; then
  if [ -n "$OUT" ]; then
    INSTALLER="$(mktemp "${OUT}.partial.XXXXXX")" || {
      echo "${AUSPEX_VERIFY_LOG_PREFIX}: cannot write beside ${OUT}" >&2
      exit "$AUSPEX_VERIFY_EX_ENV"
    }
  else
    INSTALLER="$(mktemp)"
  fi
  _fetched_tmp="$INSTALLER"
  echo "${AUSPEX_VERIFY_LOG_PREFIX}: downloading ${URL}"
  fetch "$URL" "$INSTALLER" || {
    echo "${AUSPEX_VERIFY_LOG_PREFIX}: could not fetch ${URL}" >&2
    exit "$AUSPEX_VERIFY_EX_FETCH"
  }
  [ -z "$BUNDLE" ] && BUNDLE="${URL}.cosign.bundle"
else
  [ -f "$INSTALLER" ] || {
    echo "${AUSPEX_VERIFY_LOG_PREFIX}: installer not found at ${INSTALLER}" >&2
    exit "$AUSPEX_VERIFY_EX_FETCH"
  }
  [ -z "$BUNDLE" ] && BUNDLE="${INSTALLER}.cosign.bundle"
fi

case "$VERIFY" in
  none)
    echo "${AUSPEX_VERIFY_LOG_PREFIX}: --verify none — NOT verifying provenance (not recommended for a managed security-agent deploy)" >&2
    ;;
  cosign)
    verify_cosign_bundle "$INSTALLER" "$BUNDLE"
    ;;
esac

# Verified: the download (if any) is trusted — keep it and hand its path to the caller to install.
if [ -n "$URL" ] && [ -n "$OUT" ]; then
  chmod 0644 "$INSTALLER" # mktemp's 0600; a signed public package needs no secrecy
  mv -f "$INSTALLER" "$OUT"
  case "$OUT" in /*) INSTALLER="$OUT" ;; *) INSTALLER="${PWD%/}/${OUT#./}" ;; esac # absolute, for MDM logs
fi
_fetched_tmp=""
echo "${AUSPEX_VERIFY_LOG_PREFIX}: VERIFIED — safe to install: ${INSTALLER}"
