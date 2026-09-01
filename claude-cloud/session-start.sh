#!/bin/sh
# auspex — Claude Code cloud agent SessionStart launcher (runs IN-SESSION from the daemon-launch hook).
#
# Claude runs `type:"command"` hooks under /bin/sh, so this is POSIX sh — NO bashisms (a `${x//y/z}` or
# `[[ … ]]` here is exactly the class that produced the observed "Bad substitution" block). It resolves the
# dispatching human's work email, records it via `auspex auth set --email`, then launches the supervised
# daemon (which enrolls from the identity file the setup script provisioned — Claude injects no session secret,
# so the ORG TOKEN was written at setup, not here). Work-email attribution, in order (every tier GUARDED — an
# unset/empty tier is skipped, never fatal):
#   1. CLAUDE_CODE_USER_EMAIL — Claude's per-session dispatcher identity (the authoritative human; the platform
#      populates it in-session, and it may be absent at setup — so we resolve it HERE, not in install.sh),
#   2. an explicit AUSPEX_CLOUD_WORK_EMAIL override, if present in the session env,
#   3. the dispatcher's git identity (repo, then global) — cloud agents configure it for commits/PRs,
#   4. else whatever the setup script baked (kept — `auth set --email` is preserve-on-omit) or empty
#      (capture still runs, events are just unattributed — never blocks capture).
#
# It runs at EVERY SessionStart (which can fire more than once per VM), so it is idempotent: if a daemon is
# already reachable it does nothing.
set -eu

# Resolve the work email from the session. CLAUDE_CODE_USER_EMAIL is Claude's purpose-built dispatcher signal
# (best); git identity is the fallback. Empty is fine — we skip the write and keep whatever setup provisioned.
resolve_email() {
  if [ -n "${CLAUDE_CODE_USER_EMAIL:-}" ]; then printf '%s' "$CLAUDE_CODE_USER_EMAIL"; return; fi
  if [ -n "${AUSPEX_CLOUD_WORK_EMAIL:-}" ]; then printf '%s' "$AUSPEX_CLOUD_WORK_EMAIL"; return; fi
  e="$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" config user.email 2>/dev/null || true)"
  [ -z "$e" ] && e="$(git config --global user.email 2>/dev/null || true)"
  printf '%s' "$e"
}
EMAIL="$(resolve_email)"
if [ -n "$EMAIL" ]; then
  # Refine attribution without re-passing the token (preserve-on-omit). Best-effort: never block capture.
  auspex auth set --email "$EMAIL" >/dev/null 2>&1 || true
  echo "auspex(session): attributing capture to $EMAIL"
else
  echo "auspex(session): no work email resolved — events may be unattributed (bake AUSPEX_CLOUD_WORK_EMAIL at setup or set git config user.email)" >&2
fi

# Already up? SessionStart can fire repeatedly; a reachable daemon means nothing to do. `status` is quiet and
# fast; a non-zero exit (no daemon yet) falls through to launch.
if auspex status >/dev/null 2>&1; then
  echo "auspex(session): daemon already running — nothing to do"
  exit 0
fi

# The daemon enrolls from the identity file provisioned at setup (org token) + refined above (work email).
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
