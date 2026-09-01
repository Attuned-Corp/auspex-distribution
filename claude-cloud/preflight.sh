#!/usr/bin/env bash
# auspex — Claude Code cloud agent preflight (run by hand inside a session to confirm setup).
#
# Claude cloud injects NO session secrets, so the org token is NOT a session env var — it is provisioned into
# auspex's identity file at setup, and the daemon enrolls from there. This preflight therefore checks the
# RESOLVED identity (`auspex auth show`: token present, work email attributed) rather than an env var, then
# defers all remaining health (daemon up · placement · token valid · single tier · delivery to Span) to the
# shipped diagnostic — there is deliberately no bespoke verify.sh.
set -euo pipefail
fail=0

# 1) The org token is provisioned into the identity file (enrolled). `auth show` masks the secret and reports
#    presence + winning tier; "token: set" means the setup script provisioned it and the daemon can enroll.
echo "--- auspex auth show ---"
if auspex auth show | tee /tmp/auspex-auth.$$ | grep -q '^token: *set'; then
  echo "[OK]   org token provisioned (identity file)"
else
  echo "[FAIL] no org token in the identity file — set AUSPEX_CLOUD_TOKEN inline in the setup script" >&2
  fail=1
fi

# 2) A work email resolved (setup-baked or session git identity) — else events are unattributed.
if grep -q '^work_email: *(unset)' /tmp/auspex-auth.$$; then
  echo "[WARN] no work email resolved — events unattributed (bake AUSPEX_CLOUD_WORK_EMAIL or set git config user.email)" >&2
fi
rm -f /tmp/auspex-auth.$$

# 3) Everything else: the shipped health report (bounded token probe included).
echo "--- auspex status --verbose --check-token ---"
auspex status --verbose --check-token || fail=1

exit "$fail"
