<!--
Thanks for contributing! Keep PRs small and self-contained.
See CONTRIBUTING.md for the full workflow.
-->

## Summary

<!-- What does this change do, and why? Link any related issue (e.g. "Closes #123"). -->

## Changes

<!-- Bullet the notable changes so a reviewer can orient quickly. -->

-

## Checklist

- [ ] `make verify-test` passes locally (installer download-integrity contract)
- [ ] Feature `version` in `src/span-auspex/devcontainer-feature.json` bumped if this is a behavioural change
- [ ] If verification changed: cosign pin (`install.sh` `COSIGN_VERSION` + SHA-256s) and `publish-feature.yml` stay in lock-step; `trusted_root.json` refreshed only if Sigstore roots rotated
- [ ] Docs (`README.md`) updated where relevant
- [ ] Commit history is clean and PR is scoped to one logical change

## Notes for reviewers

<!-- Anything reviewers should focus on, known trade-offs, or follow-ups deferred to a later PR. -->
