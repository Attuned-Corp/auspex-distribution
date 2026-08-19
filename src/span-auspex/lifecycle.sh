#!/usr/bin/env bash
# Auspex Dev Container Feature lifecycle helper. install.sh drops this at /usr/local/share/auspex and the
# feature's onCreateCommand/postStartCommand invoke it AS THE CONTAINER USER:
#
#   install    — onCreate: a service-free, idempotent cold install. Wires capture into each detected
#                coding tool and arms the no-OS-supervisor cold-start relax so the hook spools before the
#                first heartbeat. Safe to re-run.
#   supervise  — postStart: (re)launch `auspex daemon --supervise`, the auspex-owned supervisor that
#                respawns the worker and forwards SIGTERM. Serial-safe: a postStart that fires again on an
#                orchestrator resume is a no-op while a supervisor is already running.
#
# NOTE: because postStart launches the supervisor as a background child of the lifecycle runner (not as
# PID 1), a container STOP does not reliably deliver SIGTERM to it — the teardown spool flush is
# best-effort, and restart is orchestrator-driven (postStart on resume), not raw `docker start`. This is
# a documented limitation (see this repo's README.md).
set -euo pipefail

ENV_FILE=/usr/local/share/auspex/feature.env
# shellcheck source=/dev/null
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

AUSPEX_BIN="${AUSPEX_BIN:-/usr/local/bin/auspex}"

# The feature's home override (if any) becomes AUSPEX_HOME for both the install and the daemon, so the
# hook wiring, the runspace, and the supervised worker all agree on one home.
if [ -n "${AUSPEX_FEATURE_HOME:-}" ]; then
  export AUSPEX_HOME="$AUSPEX_FEATURE_HOME"
fi
# Pin the device dimension across stop/start + rebuild when the feature supplied one.
if [ -n "${AUSPEX_FEATURE_DEVICE_ID:-}" ]; then
  export AUSPEX_DEVICE_ID="$AUSPEX_FEATURE_DEVICE_ID"
fi

HOME_DIR="${AUSPEX_HOME:-$HOME/.auspex}"

home_args=()
if [ -n "${AUSPEX_HOME:-}" ]; then
  home_args=(--home "$AUSPEX_HOME")
fi

case "${1:-}" in
  install)
    # onCreate does the service-free `install --supervised` for BOTH hook scopes — it enrolls, scaffolds the
    # runspace, and arms the cold-start capture relax. Its hook wiring adapts to the scope AUTOMATICALLY via
    # the placement-exclusivity marker:
    #   - hookScope: user   → no system marker, so it auto-wires the full USER-tier catalog (all coding tools
    #                         + the user-scoped VS Code cell).
    #   - hookScope: system → install.sh already placed the machine-wide /etc hooks (+ the root-owned system
    #                         marker) at build, so this PARTIAL-DEFERS: it skips the four machine-wide cells
    #                         (already at /etc; wiring them at the user tier would double-capture) and writes
    #                         no user marker, but STILL wires the user-scoped VS Code cell (no /etc layer) and
    #                         still enrolls + arms capture. So one command is correct for either scope.
    # VS Code's container capture is completed by this feature's declarative customizations.vscode.settings
    # (the Server reads its machine-settings), which point at the ~/.auspex/vscode/hooks.json this write lays.
    if [ "${AUSPEX_FEATURE_HOOK_SCOPE:-user}" = "system" ]; then
      echo "auspex: onCreate install (hookScope=system) — machine-wide hooks were placed at build; deferring them and wiring the user-scoped VS Code cell + enrolling"
    else
      echo "auspex: onCreate install (hookScope=user) — wiring user-tier capture hooks + enrolling"
    fi
    # File-based enrollment (more secure than an env token): if a token file was configured, hand its
    # PATH to `install --token-file` so the secret is read once into the 0600 identity file and never
    # enters the process environment. Fail-soft: if the configured file is not present at onCreate (the
    # mount is missing), warn and install unenrolled rather than bricking the whole container.
    token_args=()
    if [ -n "${AUSPEX_FEATURE_TOKEN_FILE:-}" ]; then
      if [ -r "$AUSPEX_FEATURE_TOKEN_FILE" ]; then
        token_args=(--token-file "$AUSPEX_FEATURE_TOKEN_FILE")
      else
        echo "auspex: tokenFile '$AUSPEX_FEATURE_TOKEN_FILE' not readable at onCreate — installing unenrolled (set AUSPEX_CLOUD_TOKEN or fix the mount)" >&2
      fi
    fi
    exec "$AUSPEX_BIN" install --supervised "${home_args[@]}" "${token_args[@]}"
    ;;
  supervise)
    RUN_DIR="$HOME_DIR/run"
    mkdir -p "$RUN_DIR"
    PIDFILE="$RUN_DIR/supervise.pid"
    if [ -f "$PIDFILE" ]; then
      existing="$(cat "$PIDFILE" 2>/dev/null || true)"
      if [ -n "$existing" ] && kill -0 "$existing" 2>/dev/null; then
        echo "auspex: supervisor already running (pid ${existing}) — skipping"
        exit 0
      fi
    fi
    LOG="$RUN_DIR/supervise.log"
    # nohup (not setsid): it does not fork, so $! is the supervisor's own pid for the pidfile, and it
    # ignores SIGHUP so the supervisor outlives the postStart shell that launched it.
    nohup "$AUSPEX_BIN" daemon --supervise "${home_args[@]}" >>"$LOG" 2>&1 &
    echo "$!" >"$PIDFILE"
    echo "auspex: launched supervisor (pid $!); logs at ${LOG}"
    ;;
  *)
    echo "usage: lifecycle.sh {install|supervise}" >&2
    exit 2
    ;;
esac
