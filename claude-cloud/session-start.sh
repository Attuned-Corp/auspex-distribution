#!/bin/sh
# auspex — Claude Code cloud agent SessionStart launcher (runs IN-SESSION from the daemon-launch hook).
#
# Claude runs `type:"command"` hooks under /bin/sh, so this is POSIX sh — NO bashisms (a `${x//y/z}` or
# `[[ … ]]` here is exactly the class that produced the observed "Bad substitution" block). It resolves the
# dispatching human's work email, then launches the supervised daemon in the background. Attribution:
#   1. an explicitly-injected AUSPEX_CLOUD_WORK_EMAIL wins (Claude has NO metadata socket — inject it),
#   2. else empty — capture still runs, events are just unattributed (never blocks capture).
#
# It runs at EVERY SessionStart (which can fire more than once per VM), so it is idempotent: if a daemon is
# already reachable it does nothing.
set -eu

# Already up? SessionStart can fire repeatedly; a reachable daemon means nothing to do. `status` is quiet and
# fast; a non-zero exit (no daemon yet) falls through to launch.
if auspex status >/dev/null 2>&1; then
  echo "auspex(session): daemon already running — nothing to do"
  exit 0
fi

if [ -n "${AUSPEX_CLOUD_WORK_EMAIL:-}" ]; then
  export AUSPEX_CLOUD_WORK_EMAIL
  echo "auspex(session): attributing capture to ${AUSPEX_CLOUD_WORK_EMAIL}"
else
  echo "auspex(session): no AUSPEX_CLOUD_WORK_EMAIL injected — events will be unattributed" >&2
fi

# The daemon inherits the exported AUSPEX_CLOUD_WORK_EMAIL + AUSPEX_CLOUD_TOKEN and enrolls at runtime.
# The runspace is an OWNER-ONLY (0700) private dir: the daemon FAILS CLOSED if run/ grants group/other
# access ("has mode 0755, must be 0700 … refusing to serve") and it will NOT re-permission an existing dir.
# A plain `mkdir` lands at 0755 under the default umask, so create it under a 077 umask AND chmod it
# explicitly (the dir may already exist at 0755 from a prior run).
AUSPEX_STATE="${AUSPEX_HOME:-$HOME/.auspex}"
LOG_DIR="$AUSPEX_STATE/run"
umask 077
mkdir -p "$LOG_DIR"
chmod 700 "$AUSPEX_STATE" "$LOG_DIR"

# Detach so the daemon outlives this short-lived hook process: prefer setsid (own session), else nohup.
if command -v setsid >/dev/null 2>&1; then
  setsid auspex daemon --supervise >> "$LOG_DIR/supervise.log" 2>&1 &
else
  nohup auspex daemon --supervise >> "$LOG_DIR/supervise.log" 2>&1 &
fi
echo "auspex(session): supervised daemon launched (log: $LOG_DIR/supervise.log)"
