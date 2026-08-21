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
BUNDLE=""                    # per-artifact .cosign.bundle (path or URL); default: <installer|url>.cosign.bundle
OUT=""                       # where a --url download is saved (default: a temp file; printed on success)
VERIFY="cosign"              # cosign (default) | none (explicit, discouraged escape hatch)

usage() {
  cat >&2 <<EOF
auspex mdm-gate — verify a managed installer (.pkg/.msi) before install; fail-closed.

  --installer <path>  local, already-staged installer to verify
  --url <url>         CDN URL to fetch the installer from, then verify (origin #1)
  --out <path>        where to save the --url download (default: a temp file, path printed on success)
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
    --out) OUT="${2:-}"; shift 2 ;;
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

if [ -n "$INSTALLER" ] && [ -n "$URL" ]; then
  echo "${AUSPEX_VERIFY_LOG_PREFIX}: pass --installer OR --url, not both" >&2
  exit "$AUSPEX_VERIFY_EX_USAGE"
fi
if [ -z "$INSTALLER" ] && [ -z "$URL" ]; then
  echo "${AUSPEX_VERIFY_LOG_PREFIX}: one of --installer <path> or --url <url> is required" >&2
  usage
  exit "$AUSPEX_VERIFY_EX_USAGE"
fi

# --- fetch (if --url) → verify (fail-closed) -------------------------------------------------------------
# A download we created is removed on ANY non-zero exit so a refused/unverified installer is never left on
# disk (fail-closed); a pre-staged --installer is left untouched. verify_* funcs exit directly on failure.
_fetched_tmp=""
# Preserve the real exit status: a bare `[ -n "" ] && …` tail would return non-zero and CLOBBER a
# fail-closed exit code (e.g. 13) down to 1 (bash EXIT-trap semantics).
_gate_cleanup() { local rc=$?; [ -n "$_fetched_tmp" ] && rm -f "$_fetched_tmp"; return "$rc"; }
trap _gate_cleanup EXIT

if [ -n "$URL" ]; then
  if [ -n "$OUT" ]; then
    INSTALLER="$OUT"
  else
    INSTALLER="$(mktemp)"
  fi
  _fetched_tmp="$INSTALLER"
  echo "${AUSPEX_VERIFY_LOG_PREFIX}: downloading ${URL}"
  fetch "$URL" "$INSTALLER"
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
_fetched_tmp=""
echo "${AUSPEX_VERIFY_LOG_PREFIX}: VERIFIED — safe to install: ${INSTALLER}"
