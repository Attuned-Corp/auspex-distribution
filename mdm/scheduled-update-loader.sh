#!/bin/bash
# auspex MDM scheduled update loader (macOS). Paste it whole into your MDM, such as a Mosyle Custom Command,
# and run it as root on a schedule. Each run runs the auspex-scheduled-update.sh it pins only if its SHA-256
# matches, downloading it only when the cached copy is missing or stale. To update, paste a newer release's.
set -euo pipefail

# --- Settings: edit these two lines ---
AUSPEX_BASE_URL=""      # required: your auspex download host (https://...), from your install instructions
AUSPEX_CHANNEL="stable" # stable (the default) or latest

# --- The pinned script (filled in by the release; do not edit) ---
SCRIPT_URL="https://github.com/Attuned-Corp/auspex-distribution/releases/download/@TAG@/auspex-scheduled-update.sh"
SCRIPT_SHA256="@SHA256@"

PATH="/usr/bin:/bin:/usr/sbin:/sbin"
umask 077
STATE_DIR="${AUSPEX_UPDATE_STATE_DIR:-/Library/Application Support/auspex-update}"
fail() { # <exit-code> <message>
  echo "auspex update: $2" >&2
  echo "auspex update: failed with exit $1 (exit codes: mdm/README.md)" >&2
  exit "$1"
}
sha256_of() { (shasum -a 256 "$1" 2>/dev/null || sha256sum "$1") | cut -d ' ' -f 1; }
state_ok() { # the cache lives only in a state directory the script accepts: ours, 0700, not a link
  [ -d "$STATE_DIR" ] && [ ! -L "$STATE_DIR" ] &&
    [ "$(stat -c '%u %a' "$STATE_DIR" 2>/dev/null || stat -f '%u %Lp' "$STATE_DIR")" = "$(id -u) 700" ]
}
dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT
cache="$STATE_DIR/scheduled-update.sh"
# The hash is checked on this run's own copy, so the cache can't change between the check and the run.
if state_ok && [ -f "$cache" ]; then cp "$cache" "$dir/update.sh" || true; fi
if [ ! -f "$dir/update.sh" ] || [ "$(sha256_of "$dir/update.sh")" != "$SCRIPT_SHA256" ]; then
  curl -fsSL --proto '=https' --proto-redir '=https' --max-time 300 -o "$dir/update.sh" "$SCRIPT_URL" ||
    fail 11 "could not download ${SCRIPT_URL}"
  got="$(sha256_of "$dir/update.sh")"
  [ "$got" = "$SCRIPT_SHA256" ] ||
    fail 12 "the downloaded script has SHA-256 ${got}, not the pinned ${SCRIPT_SHA256}; running nothing"
  if state_ok; then cp "$dir/update.sh" "$cache" || true; fi
fi
AUSPEX_BASE_URL="$AUSPEX_BASE_URL" AUSPEX_CHANNEL="$AUSPEX_CHANNEL" /bin/bash "$dir/update.sh"
