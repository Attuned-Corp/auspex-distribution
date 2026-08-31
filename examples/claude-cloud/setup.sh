#!/usr/bin/env bash
# auspex — Claude Code cloud capture: the ENVIRONMENT SETUP SCRIPT to paste into your Claude cloud
# environment. It fetches the cosign-signed claude-cloud-install.sh Release asset and runs it, so an upstream
# recipe fix flows in automatically (nothing is vendored). `latest/download` tracks the newest release; swap
# in .../releases/download/<tag>/claude-cloud-install.sh to pin. Set AUSPEX_BASE_URL + AUSPEX_CLOUD_TOKEN
# (and inject AUSPEX_CLOUD_WORK_EMAIL) as secrets, and allowlist egress — see README.md.
curl -fsSL https://github.com/Attuned-Corp/auspex-distribution/releases/latest/download/claude-cloud-install.sh | bash
