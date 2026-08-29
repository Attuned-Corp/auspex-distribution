# auspex Cursor cloud capture — DOCKERFILE variant base image (pairs with environment.docker.json).
#
# Everything here runs AS ROOT AT BUILD. We install the deps Cursor cloud itself needs, then fetch +
# fail-closed-verify the signed auspex binary so it's baked into the image (install.sh then skips the
# download and just places the hook tier). Placement is NOT done here — install.sh does it (`auspex hooks
# install --system`) so the same script serves both variants and the tier logic stays in one place.
FROM ubuntu:24.04

# Cursor cloud runs `git clone` INSIDE the image (a custom image without git fails the clone) and downloads
# its exec-daemon with `curl` (a missing curl fails env setup with "curl: command not found"). ca-certificates
# for TLS; jq for parsing the metadata-socket JSON. (sudo is not needed — the build/install phase is root.)
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git jq \
 && rm -rf /var/lib/apt/lists/*

# Fetch + verify the pinned signed binary at build. AUSPEX_BASE_URL is your download host; pass it with
#   "build": { "args": { "AUSPEX_BASE_URL": "https://…" } }  in environment.docker.json, or --build-arg.
ARG AUSPEX_VERSION=v0.1.0
ARG AUSPEX_BASE_URL
ARG AUSPEX_VERIFY=cosign
RUN test -n "$AUSPEX_BASE_URL" || { echo "build-arg AUSPEX_BASE_URL is required (your auspex download host)"; exit 1; } \
 && curl -fsSL "https://github.com/attuned-corp/auspex-distribution/releases/download/${AUSPEX_VERSION}/auspex-install.sh" \
    | sh -s -- --version "$AUSPEX_VERSION" --base-url "$AUSPEX_BASE_URL" --verify "$AUSPEX_VERIFY" --bin-dir /usr/local/bin
