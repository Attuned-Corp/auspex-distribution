.DEFAULT_GOAL := help

# Installer download-integrity regression — pure bash + HTTP (no Docker / devcontainer CLI), so it runs
# anywhere. It serves a fixture binary + .sha256 over localhost and drives src/span-auspex/install.sh
# through every verify: mode, asserting a tampered/absent checksum fails CLOSED (nothing installed) and a
# matching one installs. Needs python3 + curl|wget (skips, not fails, without). This is the fast PR gate.
.PHONY: verify-test
verify-test:
	@./tests/install-verify-test.sh

# Assemble the self-contained curl|sh + PowerShell installers (dist/auspex-install.sh|.ps1) from the ONE
# verify recipe + embedded trust root. CI runs this before uploading the Release assets (origin #2).
.PHONY: assemble
assemble:
	@./bootstrap/assemble.sh

# Lint every shell script (the shared recipe, installer, bootstrap, assembler, cursor-cloud recipe, tests).
# Requires shellcheck.
.PHONY: shellcheck
shellcheck:
	@shellcheck -x src/span-auspex/verify-lib.sh src/span-auspex/install.sh \
		cursor-cloud/install.sh cursor-cloud/start.sh cursor-cloud/preflight.sh \
		bootstrap/bootstrap.sh bootstrap/assemble.sh mdm/verify-gate.sh tests/install-verify-test.sh

# Docker-backed behavioural smoke of the Feature is a follow-up in this repo (it needs a built auspex
# binary, which the private auspex repo produces). Until it is reconstituted here, run it from a checkout
# that can supply a binary, or against a CDN-published release. See README "CI / testing".

# Light structural guard for the public CHANGELOG.md (no leak-check, no release tag-gate — this repo is
# public and versions its two artifacts independently). --self-test proves the guard bites on bad fixtures.
.PHONY: validate-changelog validate-changelog-test
validate-changelog:
	@./tools/scripts/validate-changelog.sh

validate-changelog-test:
	@./tools/scripts/validate-changelog.sh --self-test

.PHONY: help
help:
	@echo "Targets:"
	@echo "  verify-test               installer + bootstrap download-verify contract (pure bash+HTTP; the PR gate)"
	@echo "  assemble                  build dist/auspex-install.sh|.ps1 from the shared recipe (Release assets)"
	@echo "  shellcheck                lint all shell scripts"
	@echo "  validate-changelog        structural check of CHANGELOG.md"
	@echo "  validate-changelog-test   prove the changelog guard bites on bad fixtures"
