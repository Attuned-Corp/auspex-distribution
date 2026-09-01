# Changelog

All notable, user-facing changes to the **auspex-distribution** surface — the
`span-auspex` Dev Container Feature and the `curl | bash` / MDM installers — are
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
  installer scripts, cut as a GitHub Release), so sections are **date-stamped**
  rather than carrying one repo version.
- **Component versions go in a short list under the date**, not in the heading —
  keep the heading a bare `## [YYYY-MM-DD]`, then list the moved components as
  bullets (`- **span-auspex Feature** — 0.5.0`, `- **Install surface** —
  installers-v0.1.0`). Omit a component the release didn't move.
- **Each change bullet leads with a bold component tag** so the reader can see at
  a glance what it touches — one of **Feature**, **Installers**, or **Shared**
  (the verify recipe / trust anchor / cross-cutting docs, or a capability that
  lands in both). Format: `- **<tag>** · **<change name>** — <description>`,
  e.g. `- **Installers** · **Bootstrap installer** — …`.
- **Publishing** (a Feature `workflow_dispatch`, or an installer Release) rolls the
  relevant `## [Unreleased]` bullets into a new dated `## [YYYY-MM-DD]` section.
- Categories are fixed: **Added**, **Changed**, **Fixed**, **Security**,
  **Removed**, **Deprecated**. `validate-changelog` (a light structural guard —
  no private-repo leak-check, no release tag-gate) keeps the shape, dates, and
  ordering honest.

## [Unreleased]

### Added

- **Installers** · **Claude cloud capture recipe** — a `claude-cloud/` recipe
  (`install.sh` setup script + `session-start.sh` `SessionStart` launcher +
  `preflight.sh`) that captures **Claude Code cloud agents** (Claude Code on the
  web / `claude --cloud` / tag / routines). The environment setup script fetches +
  cosign-verifies the signed binary, places one **managed** hook tier
  (`/etc/claude-code/managed-settings.d/`), **provisions the org token into
  auspex's identity file** (`auspex auth set`), and wires a `SessionStart` hook
  that launches the supervised daemon in-session (which enrolls from that identity
  file). Claude cloud injects **no session secrets**, so all config is supplied
  inline in the setup script; attribution resolves Claude's per-session
  `CLAUDE_CODE_USER_EMAIL` (then `git config user.email`, then a baked
  `AUSPEX_CLOUD_WORK_EMAIL` fallback). Token usage /
  turn enrichment / sub-agent metrics ride along via auspex's built-in tailer. Scripts
  are cosign-signed Release assets (`claude-cloud-install/session-start/preflight.sh`)
  consumed from `releases/latest/download/`. See `examples/claude-cloud/README.md`.

## [2026-08-31]

Published components:

- **span-auspex Feature** — `0.5.0` (GHCR OCI tag/digest)
- **Install surface** — `installers-v0.1.1` (GitHub Release; `curl | bash` / PowerShell bootstrap, MDM verify-gate, Cursor cloud recipe scripts) — supersedes same-day `installers-v0.1.0`

### Added

- **Shared** · **Pin-by-digest install** — a `digest` option (`--digest` /
  `-Digest` for the bootstrap) that pins the **exact artifact by content**: the
  install fetches it straight from the version-free content-addressed blob store
  (`<host>/blobs/sha256/<digest>`) and self-verifies `sha256(bytes)==digest`,
  bypassing version→manifest resolution. A digest is a version-free address (the
  `@sha256:…`-style pin) that survives a re-tag and needs no cosign/jq — the
  strongest supply-chain pin for a lockfile or fleet baseline. `version`/`verify`
  are not consulted for a pinned digest, and a byte mismatch, missing blob, or
  malformed digest fails closed. Obtain the digest via the by-hand two-hop
  verification or your org's published pin.
- **Installers** · **Bootstrap installer** — a piped `curl … | bash`
  (macOS/Linux) and `irm … | iex` (PowerShell, Windows) installer that fetches
  the auspex binary for the detected OS/arch from the release CDN, **verifies it
  fail-closed** (default `verify: cosign` against auspex's pinned release
  identity; `checksum` and `none` opt-downs), and installs it. Published from
  this repo's **GitHub Releases** — a second origin, independent of the artifact
  CDN — and cosign-signed.
- **Installers** · **MDM verify-gate** — a verify-before-install gate
  (`mdm/verify-gate.sh` / `.ps1`) for managed installs (macOS Mosyle `.pkg`,
  Windows Intune `.msi`): the fleet runner verifies the installer and its
  per-artifact cosign bundle fail-closed against the pinned release identity and
  **does not install on a verification failure**. Ships with Mosyle / Intune
  wiring recipes (`mdm/README.md`).
- **Shared** · **Networking guide** (`docs/networking.md`) — the exact host
  allow-list each acquisition path needs, the zero-Sigstore-egress verification
  invariant, and internal-mirror base-URL overrides (`AUSPEX_BASE_URL` /
  `AUSPEX_COSIGN_BASE_URL`) for egress-restricted / air-gapped fleets.
- **Installers** · **Cursor cloud agent recipe** — capture coding-agent activity
  from **Cursor cloud agents** (Cursor-managed Linux VMs). The recipe places one
  Cursor hook tier, runs the supervised daemon, and enrolls with Span using a
  team-scoped org token; the engineer's work email is auto-discovered from Cursor's
  agent metadata socket, so no per-user secret is needed. The scripts
  (`cursor-cloud-install.sh` / `-start.sh` / `-preflight.sh`, sourced from
  `cursor-cloud/`) are **cosign-signed and published as GitHub Release assets**,
  consumed from `releases/latest/download/` — the same trust posture as the Dev
  Container Feature. A consumer example (team-level and per-repository, plus a
  custom-image Dockerfile variant) lives in `examples/cursor-cloud/`.

### Changed

- **Installers** · **Default to `latest`** — the `curl | bash` / PowerShell bootstrap (and the Cursor cloud
  recipe) now install the **newest signed release by default**: when no `--version` / `-Version` (and no
  `--url` / `--digest`) is given, the installer resolves the download host's `latest` pointer
  (`releases/latest/VERSION`) to a concrete tag and verifies against **that** tag, so `verify: cosign` stays
  fail-closed (tag-bound — a bare `latest` can't satisfy the signed manifest's version-annotation check).
  Previously `--version` was mandatory. Pass `--version` / `AUSPEX_VERSION` to pin a release, or `--digest`
  to pin exact bytes.
- **Shared** · **Repo renamed to `auspex-distribution`** — broadened from
  `auspex-devcontainer-features` into the public distribution / trust-surface
  repo. The Feature's OCI namespace and keyless-signing identity re-anchor to
  `ghcr.io/attuned-corp/auspex-distribution/span-auspex`; old URLs redirect, but
  the new coordinates are canonical.
- **Feature** · **Shared verify recipe** — `install.sh` now sources **one shared
  verify recipe** (`src/span-auspex/verify-lib.sh`, also used by the bootstrap
  and the MDM gate) instead of carrying its own copy of the identity regex / OIDC
  issuer / cosign pins / trusted root, so there is a single source of trust
  material. Download verification behavior is at parity (still fail-closed).
- **Shared** · **Verify recipe: install by signed digest** — `verify: cosign`
  now **resolves a cosign-signed `version→digest` manifest and installs the
  artifact by digest** from the content-addressed blob store
  (`blobs/sha256/<digest>`), self-verifying `sha256(bytes)` against the signed
  digest — replacing the previous check of the binary's digest against a signed
  `checksums.txt`. The Feature, the `curl | sh` + PowerShell installers, and the
  MDM gate move together (one recipe). The bash tiers auto-provision a pinned,
  hash-checked **jq** to parse the manifest (the PowerShell installer uses native
  JSON, no jq); `AUSPEX_JQ_BASE_URL` mirrors it for air-gapped fleets.
  `verify: checksum` and `none` are unchanged.

### Security

- **Shared** · **Version-substitution gap closed in `verify: cosign`** —
  verification is now bound to the requested release tag: the signed manifest's
  version annotation must equal the tag in the install URL, and the bytes are
  fetched by the manifest's signed digest — so one release's artifact can no
  longer be served under a different version's path and pass verification. (The
  previous digest-membership check against a signed `checksums.txt` was
  tag-agnostic.)

## [2026-08-19]

Published components:

- **span-auspex Feature** — `0.3.0` (GHCR OCI tag/digest)

Initial public availability of the auspex distribution surface.

### Added

- **Feature** · **Dev Container Feature `span-auspex`** — a [Dev Container Feature](https://containers.dev/implementors/features/)
  that installs the auspex capture agent into a dev container or cloud agent and
  runs it under the auspex-owned supervisor (the posture for ephemeral
  environments with no OS service manager). Pluggable binary source (`binaryUri`)
  with fail-closed download verification — default `verify: cosign` keyless-verifies
  auspex's signed `checksums.txt` against a pinned release identity, fully offline
  via a bundled `trusted_root.json` (`checksum` and `none` tiers also available);
  user- or system-scope hook placement; and environment-driven Span enrollment.
  Published as an OCI artifact to GitHub Container Registry and cosign-signed by
  digest.
