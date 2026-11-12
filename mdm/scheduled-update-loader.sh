#!/bin/bash
# auspex MDM scheduled update loader (macOS). Paste it whole into your MDM, such as a Mosyle Custom Command,
# and run it as root on a schedule. Each run downloads the auspex-scheduled-update.sh it pins and runs it
# only if its SHA-256 matches. To update, replace the whole loader with a newer release's. See mdm/README.md.
set -euo pipefail

# --- Settings: edit these two lines ---
AUSPEX_BASE_URL=""      # required: your auspex download host (https://...), from your install instructions
AUSPEX_CHANNEL="stable" # stable (the default) or latest

# --- The pinned script (filled in by the release; do not edit) ---
SCRIPT_URL="https://github.com/Attuned-Corp/auspex-distribution/releases/download/@TAG@/auspex-scheduled-update.sh"
SCRIPT_SHA256="@SHA256@"

PATH="/usr/bin:/bin:/usr/sbin:/sbin"
umask 077
fail() { # <exit-code> <message>
  echo "auspex update: $2" >&2
  echo "auspex update: failed with exit $1 (exit codes: mdm/README.md)" >&2
  exit "$1"
}
dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT
curl -fsSL --proto '=https' --proto-redir '=https' --max-time 300 -o "$dir/update.sh" "$SCRIPT_URL" ||
  fail 11 "could not download ${SCRIPT_URL}"
got="$( (shasum -a 256 "$dir/update.sh" 2>/dev/null || sha256sum "$dir/update.sh") | cut -d ' ' -f 1)"
[ "$got" = "$SCRIPT_SHA256" ] ||
  fail 12 "the downloaded script has SHA-256 ${got}, not the pinned ${SCRIPT_SHA256}; running nothing"
AUSPEX_BASE_URL="$AUSPEX_BASE_URL" AUSPEX_CHANNEL="$AUSPEX_CHANNEL" /bin/bash "$dir/update.sh"
