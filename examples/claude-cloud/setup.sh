#!/usr/bin/env bash
# auspex — Claude Code cloud capture: the ENVIRONMENT SETUP SCRIPT to paste into your Claude cloud
# environment. It fetches the cosign-signed claude-cloud-install.sh Release asset and runs it, so an upstream
# recipe fix flows in automatically (nothing is vendored). `latest/download` tracks the newest release; swap
# in .../releases/download/<tag>/claude-cloud-install.sh to pin.
#
# Claude cloud injects NO session secrets and this setup script runs BEFORE the session, so every value is
# supplied INLINE here (this setup-script config is the only config surface). The org token is provisioned
# into auspex's identity file at setup — the in-session daemon enrolls from that file, no secret needed.
# Export the config so the installer inherits it, then allowlist egress — see README.md.
#
# Download-then-run (NOT `curl … | bash`): piping the installer to bash over stdin ties the script's stdin to
# the pipe, so anything the installer (or a child it spawns) reads from stdin swallows the rest of the script.
# Fetch to a temp file first, then run it — the same pattern the Cursor recipe uses.
set -euo pipefail

export AUSPEX_BASE_URL="https://auspex.span.app"        # your auspex download host (from onboarding)
export AUSPEX_CLOUD_TOKEN="span_REPLACE_ME"             # org token — provisioned into the identity file

curl -fsSL https://github.com/Attuned-Corp/auspex-distribution/releases/latest/download/claude-cloud-install.sh -o /tmp/claude-cloud-install.sh && bash /tmp/claude-cloud-install.sh
