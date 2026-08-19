.DEFAULT_GOAL := help

# Installer download-integrity regression — pure bash + HTTP (no Docker / devcontainer CLI), so it runs
# anywhere. It serves a fixture binary + .sha256 over localhost and drives src/span-auspex/install.sh
# through every verify: mode, asserting a tampered/absent checksum fails CLOSED (nothing installed) and a
# matching one installs. Needs python3 + curl|wget (skips, not fails, without). This is the fast PR gate.
.PHONY: verify-test
verify-test:
	@./tests/install-verify-test.sh

# Docker-backed behavioural smoke of the Feature is a follow-up in this repo (it needs a built auspex
# binary, which the private auspex repo produces). Until it is reconstituted here, run it from a checkout
# that can supply a binary, or against a CDN-published release. See README "CI / testing".

.PHONY: help
help:
	@echo "Targets:"
	@echo "  verify-test   installer download-integrity contract (pure bash+HTTP; the PR gate)"
