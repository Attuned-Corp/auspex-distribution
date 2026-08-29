#!/usr/bin/env bash
# auspex — Cursor cloud agent `install` phase (post-clone Build, root/sudo-capable).
#
# Fetches + fail-closed-verifies the signed auspex binary, places EXACTLY ONE Cursor hook tier, and arms the
# supervised daemon + enrollment. Idempotent — safe to re-run. Runs from the repo root (=/workspace).
#
# Env it reads (set these as Cursor environment variables; the TOKEN as a Runtime Secret — see README):
#   AUSPEX_BASE_URL     (required, https)  your auspex download host / mirror (provided at onboarding)
#   AUSPEX_VERSION      (default v0.1.0)    the signed release tag to install
#   AUSPEX_VERIFY       (default cosign)    cosign | checksum | none  (cosign needs github.com egress)
#   AUSPEX_CLOUD_TOKEN  (Runtime Secret)    team-scoped org token; consumed by enrollment
set -euo pipefail

AUSPEX_VERSION="${AUSPEX_VERSION:-v0.1.0}"
AUSPEX_VERIFY="${AUSPEX_VERIFY:-cosign}"
BOOTSTRAP_URL="${AUSPEX_BOOTSTRAP_URL:-https://github.com/attuned-corp/auspex-distribution/releases/download/${AUSPEX_VERSION}/auspex-install.sh}"

# 1) Acquire the binary — skipped when a custom image already baked it (Dockerfile variant). The bootstrap
#    script's own bytes are TLS+origin-trusted; it verifies the DOWNLOADED BINARY fail-closed against the
#    embedded trust root, so a tampered/unsigned/wrong-version artifact aborts here (no capture wired).
if ! command -v auspex >/dev/null 2>&1; then
  : "${AUSPEX_BASE_URL:?set AUSPEX_BASE_URL to your auspex download host (https://…)}"
  curl -fsSL "$BOOTSTRAP_URL" \
    | sh -s -- --version "$AUSPEX_VERSION" --base-url "$AUSPEX_BASE_URL" --verify "$AUSPEX_VERIFY"
fi

AUSPEX_BIN="$(command -v auspex)"

# 2) Single-tier placement + supervised daemon + enrollment, via ONE `auspex install` call (it self-copies
#    the binary, places the hook tier, arms the run mode, and provisions identity from AUSPEX_CLOUD_TOKEN).
#    Ladder: prefer the SYSTEM tier (/etc/cursor/hooks.json) — documented cloud support, out-of-tree (no
#    commit-leak). Use it whenever we can write /etc: DIRECTLY when already root (the usual cloud case — the
#    install phase runs as root, no sudo needed, and the stock image may not even ship sudo), else via
#    passwordless sudo. Fall back to the USER tier (~/.cursor/hooks.json) only when neither is possible.
#    NEVER both: auspex's ConflictingPlacement marker guard refuses a second tier, so no double-capture.
if [ "$(id -u)" -eq 0 ]; then
  echo "auspex(install): running as root — installing at the SYSTEM tier (/etc/cursor)"
  "$AUSPEX_BIN" install --system --supervised
elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  echo "auspex(install): passwordless sudo — installing at the SYSTEM tier (/etc/cursor)"
  sudo -E "$AUSPEX_BIN" install --system --supervised
else
  echo "auspex(install): no root/sudo — installing at the USER tier (~/.cursor)"
  "$AUSPEX_BIN" install --supervised
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
