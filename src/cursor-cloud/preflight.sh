#!/usr/bin/env bash
# auspex — Cursor cloud agent preflight (run by hand inside the agent to confirm setup).
#
# Checks ONLY the two cloud-env facts that `auspex status` can't see: the org token was injected as a
# Runtime Secret, and a work email resolved. For all health (daemon up · placement · token valid · single
# tier · delivery to Span) it defers to the shipped diagnostic — there is deliberately no bespoke verify.sh.
set -euo pipefail
fail=0

# 1) Cursor injected the org token as a Runtime Secret (right type/scope). Cursor exports the list of
#    injected secret names in CLOUD_AGENT_INJECTED_SECRET_NAMES.
case "${CLOUD_AGENT_INJECTED_SECRET_NAMES:-}" in
  *AUSPEX_CLOUD_TOKEN*) echo "[OK]   AUSPEX_CLOUD_TOKEN injected as a secret" ;;
  *) echo "[FAIL] AUSPEX_CLOUD_TOKEN not in CLOUD_AGENT_INJECTED_SECRET_NAMES — add it as a Runtime Secret" >&2; fail=1 ;;
esac

# 2) A work email resolved (explicit secret or socket-derived) — else events are unattributed.
if [ -n "${AUSPEX_CLOUD_WORK_EMAIL:-}" ]; then
  echo "[OK]   work email resolved: ${AUSPEX_CLOUD_WORK_EMAIL}"
else
  echo "[WARN] no AUSPEX_CLOUD_WORK_EMAIL — events unattributed (the metadata-socket curl may have failed)" >&2
fi

# 3) Everything else: the shipped health report (bounded token probe included).
echo "--- auspex status --verbose --check-token ---"
auspex status --verbose --check-token || fail=1

exit "$fail"
