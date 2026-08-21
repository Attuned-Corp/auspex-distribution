# Network access for verified auspex installs (AC6)

Exactly which hosts each acquisition path must reach, and how to verify with **no egress to Sigstore**.
This is the reference for locked-down / egress-restricted / air-gapped fleets deciding what to allow-list.

## Two deliberate origins

auspex verified acquisition is split across **two independent origins** on purpose (substitution-resistance —
a compromise of one origin can't silently swap the artifact *and* the trust anchor):

- **Origin #1 — the artifact CDN**: the raw binary, its `.sha256`
  sidecar, the version-root `checksums.txt`, and the cosign bundles.
- **Origin #2 — this repo's GitHub Releases** (`github.com` / `objects.githubusercontent.com`, Fastly):
  the `curl|sh` + PowerShell bootstrap installers and their cosign bundles; the Dev Container Feature's
  OCI artifact (ghcr.io). The pinned Sigstore **trust anchor** (`trusted_root.json`) is *embedded in* the
  Feature and the assembled installers — it ships from origin #2, never fetched at verify time.

The pinned **cosign CLI** is a third fetch (`github.com`, sigstore/cosign releases) for the
first-acquisition paths, unless cosign is pre-provisioned or mirrored (see below).

## Hosts per path

| Path | Trust epoch | Artifact (origin #1) | Script / anchor (origin #2) | cosign CLI | Sigstore (Fulcio/Rekor/TUF) |
|---|---|---|---|---|---|
| **MDM verify-gate** (pinned cosign pre-provisioned) | post-trust | CDN | — | none (baked into runner image) | **never** |
| **Dev Container Feature** `install.sh` | first-acquisition | CDN | ghcr.io (the Feature itself) | `github.com` (once/build, unless in image) | **never** |
| **`curl\|sh` / `irm\|iex` bootstrap** | first-acquisition | CDN | `github.com` / `objects.githubusercontent.com` (the installer) | `github.com` (unless present/mirrored) | **never** |

**Key invariant:** the cosign *verification step itself* makes **zero** Sigstore network calls. cosign v3
verifies the new-format bundle's embedded Rekor inclusion proof against the **pinned `trusted_root.json`**,
so there is no Fulcio, Rekor, or TUF traffic — proven mechanically by the network-blocked case in
`tests/install-verify-test.sh`. The only egress is fetching the *artifact* and (for first acquisition) the
*cosign CLI*.

## Minimal allow-lists

- **MDM gate (best case):** the **artifact CDN only** — cosign is pre-provisioned on the runner, and
  verification is offline. Zero external egress at verify time.
- **Feature / bootstrap (default):** the **artifact CDN** **+** `github.com` **+** `objects.githubusercontent.com`
  (the last two cover Releases assets and the cosign CLI download). The origin split is deliberate; both
  origins must be reachable, or use the packaged/MDM path.

## Egress-restricted / air-gapped

Everything is base-URL overridable, so a fleet can point both origins at an internal mirror and verify with
**no external egress**:

| Override | What it redirects | Default |
|---|---|---|
| `--base-url` / `AUSPEX_BASE_URL` (bootstrap), `binaryUri` (Feature) | the **artifact** origin (#1) | *required — no baked default (your distribution host / mirror)* |
| `AUSPEX_COSIGN_BASE_URL` | the pinned **cosign CLI** download | `https://github.com/sigstore/cosign/releases/download` |

Mirror the raw binary + `checksums.txt(.cosign.bundle)` and the pinned `cosign-<os>-<arch>` binary
internally, point the two overrides at the mirror, and verification runs fully offline against the embedded
`trusted_root.json`. (Shrinking the first-acquisition allow-list toward **single-origin** — mirroring the
pinned cosign on the CDN and defaulting `AUSPEX_COSIGN_BASE_URL` there — is a CDN-publish change tracked
separately; the override above is the supported answer today.)

## Corporate TLS-intercepting proxy

Verification is over the **artifact bytes + signature**, independent of the TLS chain:

- **Transparent / re-signing proxy that preserves bytes:** verification **passes** (the artifact is
  byte-identical; the signature is over content, not the transport).
- **Byte-altering MITM:** verification **fails closed** (correct — a modified artifact is rejected).

## What is *not* self-verifying

A piped script cannot verify its own bytes; the default one-liner roots the *script's* integrity in TLS +
origin and verifies the **downloaded binary** fail-closed. For higher assurance, the installer's own bytes
are cosign-signed on origin #2 (a `.cosign.bundle` beside each Release asset) — download-then-verify-then-run
(README → *Installing outside a dev container*), or use the **packaged / notarized / MDM** channel, where the
platform is the pre-present verifier.
