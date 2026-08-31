#!/usr/bin/env bash
# auspex — Cursor cloud agent `install` phase (post-clone Build).
#
# Fetches + fail-closed-verifies the signed auspex binary, then places EXACTLY ONE Cursor hook tier with the
# shipped placement primitive `auspex hooks install [--system]`. Identity + run mode are handled at RUN time
# by `auspex daemon --supervise` (start.sh) — it enrolls from AUSPEX_CLOUD_TOKEN and arms the cold-start
# capture relax — so NO `auspex install` is run here. Idempotent — safe to re-run.
#
# Why not `auspex install`? That is the per-user laptop installer: it REFUSES to run as root, and
# `auspex install --system` is a different thing entirely — an MDM *converge* that requires a pre-deployed
# managed-config tree and places no binary. `hooks install --system` is the placement primitive the auspex
# dev-container Feature drives, and it is happy under elevation (root or sudo) with no MDM tree needed.
#
# PRIVILEGE: the install phase's identity depends on the base image — the STOCK image runs it as a NON-root
# user (e.g. `ubuntu`) WITH passwordless sudo; a custom Dockerfile image runs it as root. Privileged steps
# (writing /usr/local/bin, placing /etc/cursor hooks) therefore go through a resolved $SUDO: empty when
# already root, `sudo -E` when non-root-but-sudo, and unavailable otherwise (→ user-tier fallback).
#
# Env it reads (set these as TEAM-scoped secrets so the install phase can see them — for the no-Dockerfile
# recipe a Runtime Secret or an environment variable both work; only user-scoped values are invisible here.
# See README):
#   AUSPEX_BASE_URL       (required, https)  your auspex download host / mirror (provided at onboarding)
#   AUSPEX_VERSION        (optional)          pin a signed auspex BINARY release (--version); unset => the bootstrap resolves the CDN 'latest'
#   AUSPEX_VERIFY         (default cosign)    cosign | checksum | none  (cosign needs github.com egress)
#   AUSPEX_BOOTSTRAP_TAG  (default latest)    the auspex-distribution BOOTSTRAP release carrying auspex-install.sh
#   AUSPEX_CLOUD_TOKEN    (Runtime Secret)    team-scoped org token; consumed by the daemon's enrollment
set -euo pipefail

AUSPEX_VERSION="${AUSPEX_VERSION:-}"   # optional: unset => the bootstrap resolves the CDN 'latest' pointer
AUSPEX_VERIFY="${AUSPEX_VERIFY:-cosign}"
# Pass --version only when pinned; unset lets the bootstrap default to the CDN 'latest' (resolved to a
# concrete signed tag, so verify: cosign stays fail-closed). Built as an array so the empty case adds no arg.
VERSION_ARGS=()
[ -n "$AUSPEX_VERSION" ] && VERSION_ARGS=(--version "$AUSPEX_VERSION")
# The bootstrap installer (auspex-install.sh) is published on its OWN version-resolving release
# (tagged installers-vX.Y.Z), INDEPENDENT of the auspex binary version — it takes --version to pick the binary.
# So resolve it from the bootstrap release's `latest/download` alias (or a pinned AUSPEX_BOOTSTRAP_TAG),
# NOT from an AUSPEX_VERSION-tagged release (no such asset exists there). AUSPEX_BOOTSTRAP_URL overrides both.
if [ -n "${AUSPEX_BOOTSTRAP_TAG:-}" ]; then
  _boot_ref="download/${AUSPEX_BOOTSTRAP_TAG}"
else
  _boot_ref="latest/download"
fi
BOOTSTRAP_URL="${AUSPEX_BOOTSTRAP_URL:-https://github.com/attuned-corp/auspex-distribution/releases/${_boot_ref}/auspex-install.sh}"

# Resolve how to run privileged commands: direct if root, else passwordless sudo, else unprivileged.
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""; PRIVILEGED=1
  echo "auspex(install): running as root"
elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  SUDO="sudo -E"; PRIVILEGED=1
  echo "auspex(install): non-root with passwordless sudo"
else
  SUDO=""; PRIVILEGED=0
  echo "auspex(install): non-root, no sudo — will use the USER tier"
fi

# 1) Acquire the binary at the machine-wide path the SYSTEM-tier hook command references
#    (appinfo.SystemBinaryPath = /usr/local/bin/auspex) — skipped when already on PATH (a custom image baked
#    it, or an e2e shim staged it). The bootstrap verifies the DOWNLOADED BINARY fail-closed against the
#    embedded trust root, so a tampered/unsigned/wrong-version artifact aborts here (no capture wired).
#    Privileged installs place it at /usr/local/bin (via $SUDO) so the system-tier hook resolves it;
#    unprivileged installs let the bootstrap use its user-writable default and wire the user tier below.
if ! command -v auspex >/dev/null 2>&1; then
  # The no-Dockerfile install phase runs in the AGENT context (as the agent user), so it sees TEAM-scoped
  # secrets — a Runtime Secret OR an environment variable both work — but NOT user-scoped values. So set
  # AUSPEX_BASE_URL as a TEAM-scoped secret (type doesn't matter here); a user-scoped value is invisible and
  # this fetch fails. (Dockerfile variant: a true image build sees only build args — pass it via --build-arg.)
  : "${AUSPEX_BASE_URL:?set AUSPEX_BASE_URL to your auspex download host (https://…) as a TEAM-scoped secret (Runtime Secret or environment variable); a user-scoped value is not visible to install}"
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
#    SYSTEM tier (/etc/cursor/hooks.json) whenever we are privileged (root or sudo) — documented cloud
#    support, out-of-tree (no commit-leak), the only tier that fires under Claude's allowManagedHooksOnly
#    lockdown, and its command references the fixed /usr/local/bin/auspex placed above. Fall back to the USER
#    tier (~/.cursor/hooks.json) only when we cannot elevate. NEVER both: auspex's placement-exclusivity
#    guard refuses a conflicting second tier, so double-capture can't happen. No `auspex install` (identity +
#    run mode come from the daemon at start), so the root-refusing per-user installer is avoided.
if [ "$PRIVILEGED" -eq 1 ]; then
  echo "auspex(install): placing SYSTEM-tier hooks (/etc/cursor)"
  $SUDO "$AUSPEX_BIN" hooks install --system
else
  echo "auspex(install): placing USER-tier hooks (~/.cursor)"
  "$AUSPEX_BIN" hooks install
fi

# 3) Stage the run-phase launcher at a STABLE ABSOLUTE PATH. Cursor's `start` command runs from an
#    unspecified working directory (typically $HOME, not the repo root), so a repo-relative
#    `bash .cursor/start.sh` won't resolve. Copy start.sh next to auspex's state so `start` can invoke it by
#    absolute path. (The team-level curl|bash path re-fetches start.sh each run and skips this — hence the
#    presence check keeps it non-fatal there.)
if SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"; then :; else SCRIPT_DIR=""; fi
LAUNCHER="${AUSPEX_HOME:-$HOME/.auspex}/cloud-start.sh"
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/start.sh" ]; then
  mkdir -p "$(dirname "$LAUNCHER")"
  cp "$SCRIPT_DIR/start.sh" "$LAUNCHER"
  chmod +x "$LAUNCHER"
  echo "auspex(install): staged run-phase launcher at $LAUNCHER"
fi

echo "auspex(install): ready — the daemon launches from the start command each agent run"
