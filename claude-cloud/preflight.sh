#!/usr/bin/env bash
# auspex — Claude Code cloud agent preflight (run by hand inside a session to confirm setup).
#
# Checks ONLY the two cloud-env facts that `auspex status` can't see: the org token was injected into the
# session, and a work email resolved. For all health (daemon up · placement · token valid · single tier ·
# delivery to Span) it defers to the shipped diagnostic — there is deliberately no bespoke verify.sh.
set -euo pipefail
fail=0

# 1) The org token was injected into the session (Claude has no metadata socket, so it must be injected as a
#    session/environment secret; the SessionStart launcher reads it to enroll the daemon).
if [ -n "${AUSPEX_CLOUD_TOKEN:-}" ]; then
  echo "[OK]   AUSPEX_CLOUD_TOKEN injected into the session"
else
  echo "[FAIL] AUSPEX_CLOUD_TOKEN is not set — inject it as a team/session secret so the daemon can enroll" >&2
  fail=1
fi

# 2) A work email resolved (injected) — else events are unattributed (Claude has no socket to auto-derive it).
if [ -n "${AUSPEX_CLOUD_WORK_EMAIL:-}" ]; then
  echo "[OK]   work email resolved: ${AUSPEX_CLOUD_WORK_EMAIL}"
else
  echo "[WARN] no AUSPEX_CLOUD_WORK_EMAIL — events unattributed (inject it as a session secret)" >&2
fi

# 3) Everything else: the shipped health report (bounded token probe included).
echo "--- auspex status --verbose --check-token ---"
auspex status --verbose --check-token || fail=1

exit "$fail"
