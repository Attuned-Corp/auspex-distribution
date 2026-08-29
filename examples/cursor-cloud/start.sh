#!/usr/bin/env bash
# auspex — Cursor cloud agent `start` phase (runs at each agent run).
#
# Resolves the dispatching human's work email, then launches the supervised daemon in the background. The
# email is auto-discovered from Cursor's agent metadata socket so NO per-user secret is required — only the
# team-scoped AUSPEX_CLOUD_TOKEN. Attribution precedence:
#   1. an explicitly-set AUSPEX_CLOUD_WORK_EMAIL secret (if you chose to set one) wins,
#   2. else owner/user-email curled from the metadata socket,
#   3. else empty — capture still runs, events are just unattributed.
# A socket/curl failure is non-fatal by design (never blocks capture).
set -euo pipefail

SOCK="${CURSOR_AGENT_SOCKET:-/run/cursor/api.sock}"

if [ -z "${AUSPEX_CLOUD_WORK_EMAIL:-}" ]; then
  AUSPEX_CLOUD_WORK_EMAIL="$(curl -fsS --unix-socket "$SOCK" \
    http://cursor-agent/v1/meta-data/owner/user-email 2>/dev/null || true)"
  export AUSPEX_CLOUD_WORK_EMAIL
fi

if [ -n "${AUSPEX_CLOUD_WORK_EMAIL:-}" ]; then
  echo "auspex(start): attributing capture to ${AUSPEX_CLOUD_WORK_EMAIL}"
else
  echo "auspex(start): no work email resolved — events will be unattributed" >&2
fi

# The daemon inherits the exported AUSPEX_CLOUD_WORK_EMAIL + AUSPEX_CLOUD_TOKEN and enrolls at runtime.
# The runspace is an OWNER-ONLY (0700) private dir: the daemon FAILS CLOSED if run/ grants group/other
# access ("has mode 0755, must be 0700 … refusing to serve") and it will NOT re-permission an existing dir.
# A plain `mkdir` lands at 0755 under the default umask, so create it under a 077 umask AND chmod it
# explicitly (the dir may already exist at 0755 from a prior run baked into the Build snapshot).
AUSPEX_STATE="${AUSPEX_HOME:-$HOME/.auspex}"
LOG_DIR="$AUSPEX_STATE/run"
umask 077
mkdir -p "$LOG_DIR"
chmod 700 "$AUSPEX_STATE" "$LOG_DIR"
auspex daemon --supervise >> "$LOG_DIR/supervise.log" 2>&1 &
echo "auspex(start): supervised daemon launched (log: $LOG_DIR/supervise.log)"
