# Contributing to auspex-devcontainer-features

Thanks for your interest in the `span-auspex` Dev Container Feature. This guide
covers how to test and propose changes. Please also read the
[Code of Conduct](CODE_OF_CONDUCT.md).

## Before you start

- **Read the [`README.md`](README.md) first** — it is the full reference for the
  Feature: its options, the pluggable binary source, download verification
  (`verify:` cosign/checksum), hook placement, enrollment, and publishing.
- This repo is the **top of the customer trust chain** (`install.sh` verifies the
  downloaded binary; `publish-feature.yml` mints the signing identity customers
  pin against), so changes to those paths get extra scrutiny — see
  [`.github/CODEOWNERS`](.github/CODEOWNERS) and [`SECURITY.md`](SECURITY.md).
- For anything non-trivial, **open an issue first** to discuss the approach
  before investing in a large change.

## Testing

The fast PR gate is a pure bash + HTTP test (no Docker / devcontainer CLI) that
drives `src/span-auspex/install.sh` through every `verify:` mode and asserts a
tampered/absent checksum fails closed. Run it from the repository root:

```sh
make verify-test
```

The same gate runs in CI on every PR that touches `src/`, `tests/`, or the
`Makefile` (see [`.github/workflows/ci.yml`](.github/workflows/ci.yml)). A
Docker-backed behavioural smoke of a full `devcontainer up` is a documented
follow-up (it needs a built auspex binary from the private auspex repo) — see the
README's *CI / testing* section.

## Proposing a change

1. **Fork and branch.** Create a topic branch from `main`.
2. **Keep PRs small and reviewable.** Aim for focused, self-contained changes
   that another person can review in one sitting.
3. **Bump the Feature version.** Any behavioural change to the Feature must bump
   `version` in [`src/span-auspex/devcontainer-feature.json`](src/span-auspex/devcontainer-feature.json)
   in the same PR — that version is what gets published to ghcr.
4. **Keep the cosign pin in lock-step.** If you touch verification, keep
   `install.sh`'s `COSIGN_VERSION` (and the per-arch SHA-256s) aligned with the
   auspex release signer and the `publish-feature.yml` cosign step, and refresh
   `trusted_root.json` only when Sigstore rotates roots (README →
   *Updating the pinned cosign / trust root*).
5. **Keep history clean.** Use short, scoped, imperative commit subjects.
6. **Make sure `make verify-test` is green** before you open the PR.
7. **Open the PR** against `main` and fill in the pull request template.

Publishing a new Feature version to ghcr is a **separate, manual go-live step**
(the `workflow_dispatch`-only [publish-feature.yml](.github/workflows/publish-feature.yml)),
deliberately decoupled from merging — merging a version bump does not publish it.

## Reporting bugs and requesting features

Use the issue templates:

- **Bug report** — steps to reproduce, expected vs. actual, and the affected
  Feature version / platform (CDE).
- **Feature request** — the problem you're trying to solve and the outcome you
  want.

Please **do not** file security vulnerabilities as public issues — see
[`SECURITY.md`](SECURITY.md) for private reporting.

## License of contributions

The licensing terms for this repository are not yet finalized. While that
decision is deferred, external contributions are not being accepted. If you wish
to propose a change, please open an issue first to discuss it.
