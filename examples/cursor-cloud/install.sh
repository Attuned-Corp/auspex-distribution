#!/usr/bin/env bash
# auspex — Cursor cloud agent `install` phase (post-clone Build, runs as ROOT).
#
# Fetches + fail-closed-verifies the signed auspex binary, then places EXACTLY ONE Cursor hook tier with the
# shipped placement primitive `auspex hooks install [--system]`. Identity + run mode are handled at RUN time
# by `auspex daemon --supervise` (start.sh) — it enrolls from AUSPEX_CLOUD_TOKEN and arms the cold-start
# capture relax — so NO `auspex install` is run here. Idempotent — safe to re-run.
#
# Why not `auspex install`? That is the per-user laptop installer: it REFUSES to run as root (the cloud VM
# is root), and `auspex install --system` is a different thing entirely — an MDM *converge* that requires a
# pre-deployed managed-config tree and places no binary. `hooks install --system` is the placement primitive
# the auspex dev-container Feature drives, and it is happy as a direct root shell (no MDM tree needed).
#
# Env it reads (set these as Cursor environment variables; the TOKEN as a Runtime Secret — see README):
#   AUSPEX_BASE_URL     (required, https)  your auspex download host / mirror (provided at onboarding)
#   AUSPEX_VERSION      (default v0.1.0)    the signed release tag to install
#   AUSPEX_VERIFY       (default cosign)    cosign | checksum | none  (cosign needs github.com egress)
#   AUSPEX_CLOUD_TOKEN  (Runtime Secret)    team-scoped org token; consumed by the daemon's enrollment
set -euo pipefail

AUSPEX_VERSION="${AUSPEX_VERSION:-v0.1.0}"
AUSPEX_VERIFY="${AUSPEX_VERIFY:-cosign}"
BOOTSTRAP_URL="${AUSPEX_BOOTSTRAP_URL:-https://github.com/attuned-corp/auspex-distribution/releases/download/${AUSPEX_VERSION}/auspex-install.sh}"

# 1) Acquire the binary at the machine-wide path the SYSTEM-tier hook command references
#    (appinfo.SystemBinaryPath = /usr/local/bin/auspex) — skipped when a custom image already baked it
#    (Dockerfile variant). The bootstrap script's own bytes are TLS+origin-trusted; it verifies the
#    DOWNLOADED BINARY fail-closed against the embedded trust root, so a tampered/unsigned/wrong-version
#    artifact aborts here (no capture wired).
if ! command -v auspex >/dev/null 2>&1; then
  # NOTE: install runs at BUILD time, where only ENVIRONMENT VARIABLES are available — NOT Runtime Secrets
  # (those are injected only at agent run time). So AUSPEX_BASE_URL must be set as an environment variable;
  # a Runtime Secret is invisible here and this fetch fails. (AUSPEX_CLOUD_TOKEN, by contrast, IS a Runtime
  # Secret — the daemon consumes it at run time, not here.)
  : "${AUSPEX_BASE_URL:?set AUSPEX_BASE_URL to your auspex download host (https://…) as an ENVIRONMENT VARIABLE (available at build), not a Runtime Secret}"
  curl -fsSL "$BOOTSTRAP_URL" \
    | sh -s -- --version "$AUSPEX_VERSION" --base-url "$AUSPEX_BASE_URL" --verify "$AUSPEX_VERIFY"
fi

AUSPEX_BIN="$(command -v auspex)"

# 2) Place EXACTLY ONE hook tier with the shipped placement primitive `auspex hooks install`. Prefer the
#    SYSTEM tier (/etc/cursor/hooks.json) — documented cloud support, out-of-tree (no commit-leak), and the
#    only tier that fires under Claude's allowManagedHooksOnly lockdown; its command references the fixed
#    /usr/local/bin/auspex placed above. It needs root (the cloud install phase runs as root); fall back to
#    the USER tier (~/.cursor/hooks.json) only if somehow not root. NEVER both: auspex's placement-
#    exclusivity guard refuses a conflicting second tier, so double-capture can't happen. No `auspex install`
#    (identity + run mode come from the daemon at start), so the root-refusing per-user installer is avoided.
if [ "$(id -u)" -eq 0 ]; then
  echo "auspex(install): root — placing SYSTEM-tier hooks (/etc/cursor)"
  "$AUSPEX_BIN" hooks install --system
else
  echo "auspex(install): not root — placing USER-tier hooks (~/.cursor)"
  "$AUSPEX_BIN" hooks install
fi

# 3) Stage the run-phase launcher at a STABLE ABSOLUTE PATH. Cursor's `start` command runs from an
#    unspecified working directory (typically $HOME, not the repo root), so a repo-relative
#    `bash .cursor/start.sh` won't resolve. Copy start.sh next to auspex's state so `start` can invoke it by
#    absolute path. (The team-level curl|bash path re-fetches start.sh each run and skips this — hence the
#    presence check keeps it non-fatal there.)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
LAUNCHER="${AUSPEX_HOME:-$HOME/.auspex}/cloud-start.sh"
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/start.sh" ]; then
  mkdir -p "$(dirname "$LAUNCHER")"
  cp "$SCRIPT_DIR/start.sh" "$LAUNCHER"
  chmod +x "$LAUNCHER"
  echo "auspex(install): staged run-phase launcher at $LAUNCHER"
fi

echo "auspex(install): ready — the daemon launches from the start command each agent run"
