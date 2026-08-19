# Security Policy

This repository is the **top of the customer trust chain** for the `span-auspex`
Dev Container Feature: [`src/span-auspex/install.sh`](src/span-auspex/install.sh)
runs the cosign verification of the downloaded auspex binary at container build,
and [`.github/workflows/publish-feature.yml`](.github/workflows/publish-feature.yml)
mints the keyless signing identity customers pin against. Both are load-bearing,
so we take security reports seriously.

## Reporting a vulnerability

**Please report vulnerabilities privately — do not open a public issue.**

- Preferred: GitHub **private vulnerability reporting** — the *Security* tab →
  *Report a vulnerability* on this repository.
- Alternatively, email **security@span.app**.

Please include a description, reproduction steps, the affected Feature version
(the `version` in [`devcontainer-feature.json`](src/span-auspex/devcontainer-feature.json)
or the published OCI tag) or commit, and the impact. Give us a reasonable window
to remediate before any public disclosure.

## Response targets

While the project is pre-release these are intentions, not guarantees:

- **Acknowledge** a report within **3 business days**.
- Provide an **initial assessment** within **7 business days**.
- Prioritize a fix or mitigation for confirmed high-severity issues, and
  coordinate disclosure timing with the reporter.

## Scope

In scope: the Feature source and its supply-chain surface — the installer
(`install.sh`) and its download-verification (`verify:` cosign/checksum) logic,
the pinned cosign / `trusted_root.json` trust anchors, the lifecycle helper
(`lifecycle.sh`), and the publish workflow's keyless signing + digest pinning.

Out of scope: the auspex agent binary itself and its on-device behavior (report
those against the auspex agent's own security policy), vulnerabilities in the
third-party coding tools the agent observes, and issues that require an
already-compromised host or physical access.

## Supported versions

The project is pre-1.0 and under active development; security fixes target the
latest `main` and the most recently published Feature version. There are no
long-term-supported release branches yet.
