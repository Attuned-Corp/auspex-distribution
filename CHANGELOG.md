# Changelog

All notable, user-facing changes to the **auspex-distribution** surface — the
`span-auspex` Dev Container Feature and the `curl | sh` / MDM installers — are
recorded here. This repo is **public**, so this file is simply the durable "what
changed" for the things customers install from it.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## How to maintain this

- **Every user-facing change** adds a bullet to `## [Unreleased]` under one of the
  categories below, in the same PR as the change (reviewed in the diff).
- Write for **users**, not for the git log: describe the observable change and why
  it matters, not the implementation.
- This repo ships **two independently-versioned artifacts** (the Dev Container
  Feature, versioned in `src/span-auspex/devcontainer-feature.json`; and the
  installer scripts, cut as a GitHub Release). Rather than pretend the repo has
  one version, sections are **date-stamped** and each bullet names the component
  (and its version, where relevant): e.g. `**Feature 0.4.0** — …`,
  `**Installers** — …`. Shared changes (the verify recipe, the trust anchor)
  affect both and are noted once.
- **Publishing** (a Feature `workflow_dispatch`, or an installer Release) rolls the
  relevant `## [Unreleased]` bullets into a new dated `## [YYYY-MM-DD]` section.
- Categories are fixed: **Added**, **Changed**, **Fixed**, **Security**,
  **Removed**, **Deprecated**. `validate-changelog` (a light structural guard —
  no private-repo leak-check, no release tag-gate) keeps the shape, dates, and
  ordering honest.

## [Unreleased]

## [2026-08-19]

Initial public availability of the auspex distribution surface.

### Added

- **Feature `span-auspex` (0.3.0)** — a [Dev Container Feature](https://containers.dev/implementors/features/)
  that installs the auspex capture agent into a dev container or cloud agent and
  runs it under the auspex-owned supervisor (the posture for ephemeral
  environments with no OS service manager). Pluggable binary source (`binaryUri`)
  with fail-closed download verification — default `verify: cosign` keyless-verifies
  auspex's signed `checksums.txt` against a pinned release identity, fully offline
  via a bundled `trusted_root.json` (`checksum` and `none` tiers also available);
  user- or system-scope hook placement; and environment-driven Span enrollment.
  Published as an OCI artifact to GitHub Container Registry and cosign-signed by
  digest.
