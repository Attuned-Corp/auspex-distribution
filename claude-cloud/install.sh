#!/usr/bin/env bash
# auspex — Claude Code cloud agent `setup` phase (the root setup script pasted into the environment).
#
# Fetches + fail-closed-verifies the signed auspex binary, places EXACTLY ONE Claude hook tier with the
# shipped placement primitive `auspex hooks install [--system]`, then wires a SessionStart DAEMON-LAUNCH hook
# and stages its launcher. Idempotent — safe to re-run.
#
# Why the run phase is a HOOK, not this script: Claude cloud exposes only this build-time setup script, which
# runs BEFORE the session and therefore CANNOT read the session-injected AUSPEX_CLOUD_TOKEN. A SessionStart
# hook runs IN-SESSION (it can read the token), so the daemon must launch from there — not here. This script
# only installs + wires; `session-start.sh` (the launcher) enrolls + supervises at each session (see step 4).
#
# PRIVILEGE: Claude cloud runs the session (and typically this setup) as ROOT (HOME=/root), so the decision-
# grade MANAGED tier (/etc/claude-code/managed-settings.d/, the only tier that fires under Claude's
# allowManagedHooksOnly lockdown) is the primary. Privileged steps go through a resolved $SUDO: empty when
# already root, `sudo -E` when non-root-but-passwordless-sudo, else unavailable (→ user-tier ~/.claude fallback).
#
# Env it reads (inject as team/environment secrets the setup phase can see):
#   AUSPEX_BASE_URL       (required, https)  your auspex download host / mirror (provided at onboarding)
#   AUSPEX_VERSION        (optional)          pin a signed auspex BINARY release (--version); unset => CDN 'latest'
#   AUSPEX_VERIFY         (default cosign)    cosign | checksum | none  (cosign needs github.com egress)
#   AUSPEX_BOOTSTRAP_TAG  (default latest)    the auspex-distribution release carrying the recipe + installer
#   AUSPEX_CLOUD_TOKEN    (session secret)    team/session-scoped org token; read by the SessionStart launcher
set -euo pipefail

AUSPEX_VERSION="${AUSPEX_VERSION:-}"   # optional: unset => the bootstrap resolves the CDN 'latest' pointer
AUSPEX_VERIFY="${AUSPEX_VERIFY:-cosign}"
# Pass --version only when pinned; unset lets the bootstrap default to the CDN 'latest' (resolved to a
# concrete signed tag, so verify: cosign stays fail-closed). Built as an array so the empty case adds no arg.
VERSION_ARGS=()
[ -n "$AUSPEX_VERSION" ] && VERSION_ARGS=(--version "$AUSPEX_VERSION")
# The recipe scripts + bootstrap installer are published on the auspex-distribution release (tagged
# installers-vX.Y.Z), INDEPENDENT of the auspex binary version. Resolve from `latest/download` (or a pinned
# AUSPEX_BOOTSTRAP_TAG); AUSPEX_BOOTSTRAP_URL / AUSPEX_CLOUD_BASE override the derived URLs.
if [ -n "${AUSPEX_BOOTSTRAP_TAG:-}" ]; then
  _boot_ref="download/${AUSPEX_BOOTSTRAP_TAG}"
else
  _boot_ref="latest/download"
fi
_rel="https://github.com/attuned-corp/auspex-distribution/releases/${_boot_ref}"
BOOTSTRAP_URL="${AUSPEX_BOOTSTRAP_URL:-${_rel}/auspex-install.sh}"
CLAUDE_CLOUD_BASE="${AUSPEX_CLOUD_BASE:-${_rel}}"

# Resolve how to run privileged commands: direct if root, else passwordless sudo, else unprivileged.
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""; PRIVILEGED=1
  echo "auspex(setup): running as root"
elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  SUDO="sudo -E"; PRIVILEGED=1
  echo "auspex(setup): non-root with passwordless sudo"
else
  SUDO=""; PRIVILEGED=0
  echo "auspex(setup): non-root, no sudo — will use the USER tier (~/.claude)"
fi

# 1) Acquire the binary at the machine-wide path the MANAGED-tier hook command references
#    (appinfo.SystemBinaryPath = /usr/local/bin/auspex) — skipped when already on PATH (a custom image baked
#    it, or an e2e shim staged it). The bootstrap verifies the DOWNLOADED BINARY fail-closed against the
#    embedded trust root, so a tampered/unsigned/wrong-version artifact aborts here (no capture wired).
if ! command -v auspex >/dev/null 2>&1; then
  : "${AUSPEX_BASE_URL:?set AUSPEX_BASE_URL to your auspex download host (https://…) as an environment/team secret the setup phase can see}"
  curl -fsSL "$BOOTSTRAP_URL" -o /tmp/auspex-install.sh
  # Run the bootstrap with BASH: the assembled auspex-install.sh uses `set -o pipefail` (a bash builtin), so
  # `sh` (dash on Debian/Ubuntu) aborts with "Illegal option -o pipefail".
  if [ "$PRIVILEGED" -eq 1 ]; then
    $SUDO bash /tmp/auspex-install.sh ${VERSION_ARGS[@]+"${VERSION_ARGS[@]}"} --base-url "$AUSPEX_BASE_URL" --verify "$AUSPEX_VERIFY" --bin-dir /usr/local/bin
  else
    bash /tmp/auspex-install.sh ${VERSION_ARGS[@]+"${VERSION_ARGS[@]}"} --base-url "$AUSPEX_BASE_URL" --verify "$AUSPEX_VERIFY"
  fi
fi

AUSPEX_BIN="$(command -v auspex)"

# 2) Place EXACTLY ONE hook tier with the shipped placement primitive `auspex hooks install`. Prefer the
#    MANAGED tier (/etc/claude-code/managed-settings.d/auspex.json) whenever privileged — documented cloud
#    support, out-of-tree (no commit-leak), the only tier that fires under Claude's allowManagedHooksOnly
#    lockdown, and its command references the fixed /usr/local/bin/auspex placed above. Fall back to the USER
#    tier (~/.claude/settings.json) only when we cannot elevate. NEVER both: auspex's placement-exclusivity
#    guard refuses a conflicting second tier, so double-capture can't happen.
if [ "$PRIVILEGED" -eq 1 ]; then
  echo "auspex(setup): placing MANAGED-tier hooks (/etc/claude-code/managed-settings.d)"
  $SUDO "$AUSPEX_BIN" hooks install --system
else
  echo "auspex(setup): placing USER-tier hooks (~/.claude)"
  "$AUSPEX_BIN" hooks install
fi

# 3) Stage the SessionStart LAUNCHER at a stable absolute path (baked into the hook in step 4). Prefer a local
#    sibling (baked image / e2e checkout); else fetch the signed recipe asset from the release. Privileged →
#    a machine-wide dir the root session can read; unprivileged → the per-user auspex home.
if SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"; then :; else SCRIPT_DIR=""; fi
if [ "$PRIVILEGED" -eq 1 ]; then
  LAUNCHER_DIR="/usr/local/lib/auspex"
else
  LAUNCHER_DIR="${AUSPEX_HOME:-$HOME/.auspex}"
fi
LAUNCHER="$LAUNCHER_DIR/cloud-session-start.sh"
$SUDO mkdir -p "$LAUNCHER_DIR"
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/session-start.sh" ]; then
  $SUDO cp "$SCRIPT_DIR/session-start.sh" "$LAUNCHER"
else
  _tmp_launcher="$(mktemp)"
  curl -fsSL "$CLAUDE_CLOUD_BASE/claude-cloud-session-start.sh" -o "$_tmp_launcher"
  $SUDO cp "$_tmp_launcher" "$LAUNCHER"
  rm -f "$_tmp_launcher"
fi
$SUDO chmod 0755 "$LAUNCHER"
echo "auspex(setup): staged SessionStart launcher at $LAUNCHER"

# 4) Wire the SessionStart DAEMON-LAUNCH hook so `auspex daemon --supervise` starts IN-SESSION (where the
#    injected token is readable). This is a SEPARATE hook from auspex's own capture SessionStart entry —
#    auspex owns auspex.json (its capture hooks), we own the launch hook in a sibling own-file. Claude merges
#    every *.json in managed-settings.d (concatenate + de-dup), so both fire; and because our command is not
#    auspex-owned, a re-run of `auspex hooks install --system` never rewrites it.
#      - MANAGED (privileged): drop our own-file auspex-daemon.json into managed-settings.d/ (write wholesale).
#      - USER (fallback): merge a SessionStart group into ~/.claude/settings.json (python3-based; a fresh file
#        when absent; a warning rather than a clobber when we can't safely merge).
write_managed_launch_hook() {
  managed_dir="/etc/claude-code/managed-settings.d"
  $SUDO mkdir -p "$managed_dir"
  printf '%s\n' \
    '{' \
    '  "hooks": {' \
    '    "SessionStart": [' \
    '      { "hooks": [ { "type": "command", "command": "'"$LAUNCHER"'" } ] }' \
    '    ]' \
    '  }' \
    '}' | $SUDO tee "$managed_dir/auspex-daemon.json" >/dev/null
  echo "auspex(setup): wired SessionStart daemon-launch hook ($managed_dir/auspex-daemon.json)"
}

merge_user_launch_hook() {
  settings="$HOME/.claude/settings.json"
  mkdir -p "$(dirname "$settings")"
  if command -v python3 >/dev/null 2>&1; then
    LAUNCHER="$LAUNCHER" SETTINGS="$settings" python3 - <<'PY'
import json, os
settings, launcher = os.environ["SETTINGS"], os.environ["LAUNCHER"]
try:
    with open(settings) as f:
        doc = json.load(f)
    if not isinstance(doc, dict):
        raise ValueError("settings.json is not an object")
except FileNotFoundError:
    doc = {}
hooks = doc.setdefault("hooks", {})
groups = hooks.setdefault("SessionStart", [])
cmd = {"type": "command", "command": launcher}
present = any(
    isinstance(g, dict) and any(
        isinstance(h, dict) and h.get("command") == launcher for h in g.get("hooks", [])
    )
    for g in groups
)
if not present:
    groups.append({"hooks": [cmd]})
with open(settings, "w") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
PY
    echo "auspex(setup): wired SessionStart daemon-launch hook ($settings)"
  elif [ ! -e "$settings" ]; then
    printf '%s\n' \
      '{' \
      '  "hooks": {' \
      '    "SessionStart": [' \
      '      { "hooks": [ { "type": "command", "command": "'"$LAUNCHER"'" } ] }' \
      '    ]' \
      '  }' \
      '}' > "$settings"
    echo "auspex(setup): wrote fresh SessionStart daemon-launch hook ($settings)"
  else
    echo "auspex(setup): WARNING — python3 absent and $settings exists; not clobbering it." >&2
    echo "auspex(setup): the daemon will not auto-launch. Add a SessionStart hook running $LAUNCHER by hand." >&2
  fi
}

if [ "$PRIVILEGED" -eq 1 ]; then
  write_managed_launch_hook
else
  merge_user_launch_hook
fi

echo "auspex(setup): ready — the supervised daemon launches from the SessionStart hook each agent session"
