# Network access for verified auspex installs (AC6)

Exactly which hosts each acquisition path must reach, and how to verify with **no egress to Sigstore**.
This is the reference for locked-down / egress-restricted / air-gapped fleets deciding what to allow-list.

## Two deliberate origins

auspex verified acquisition is split across **two independent origins** on purpose (substitution-resistance —
a compromise of one origin can't silently swap the artifact *and* the trust anchor):

- **Origin #1 — the artifact CDN**: the cosign-signed version→digest index (`manifest.json` +
  `.cosign.bundle`) at the version root, the content-addressed artifact **blobs**
  (`blobs/sha256/<digest>` — what `verify: cosign` resolves and installs), plus the raw binary, its
  `.sha256` sidecar, and the version-root `checksums.txt` (for the `checksum` tier / by-hand humans).
- **Origin #2 — this repo's GitHub Releases** (`github.com` / `objects.githubusercontent.com`, Fastly):
  the `curl|sh` + PowerShell bootstrap installers and their cosign bundles; the Dev Container Feature's
  OCI artifact (ghcr.io). The pinned Sigstore **trust anchor** (`trusted_root.json`) is *embedded in* the
  Feature and the assembled installers — it ships from origin #2, never fetched at verify time.

The pinned **cosign CLI** is a third fetch (`github.com`, sigstore/cosign releases) for the
first-acquisition paths, unless cosign is pre-provisioned or mirrored (see below). The `verify: cosign` tier
also parses the signed `manifest.json` with **jq**; when jq isn't already on PATH the bash recipe fetches a
pinned, hash-checked **jq CLI** the same way (`github.com`, jqlang/jq releases). The PowerShell installer
parses the manifest with native JSON and needs no jq. Both CLIs are pinned by SHA-256 in the shared recipe
and fail closed on a mismatch.

## Hosts per path

| Path | Trust epoch | Artifact (origin #1) | Script / anchor (origin #2) | cosign / jq CLI | Sigstore (Fulcio/Rekor/TUF) |
|---|---|---|---|---|---|
| **MDM verify-gate** (pinned cosign pre-provisioned) | post-trust | CDN | — | none — cosign baked in, no manifest parse (no jq) | **never** |
| **Dev Container Feature** `install.sh` | first-acquisition | CDN | ghcr.io (the Feature itself) | `github.com` (cosign + jq, once/build, unless in image) | **never** |
| **`curl\|sh` bootstrap** | first-acquisition | CDN | `github.com` / `objects.githubusercontent.com` (the installer) | `github.com` (cosign + jq, unless present/mirrored) | **never** |
| **`irm\|iex` bootstrap** (Windows) | first-acquisition | CDN | `github.com` / `objects.githubusercontent.com` (the installer) | `github.com` (cosign only — native JSON, no jq) | **never** |

**Key invariant:** the cosign *verification step itself* makes **zero** Sigstore network calls. cosign v3
verifies the new-format bundle's embedded Rekor inclusion proof against the **pinned `trusted_root.json`**,
so there is no Fulcio, Rekor, or TUF traffic — proven mechanically by the network-blocked case in
`tests/install-verify-test.sh`. The only egress is fetching the *artifact* and (for first acquisition) the
*cosign CLI*.

## Minimal allow-lists

- **MDM gate (best case):** the **artifact CDN only** — cosign is pre-provisioned on the runner, and
  verification is offline. Zero external egress at verify time.
- **Feature / bootstrap (default):** the **artifact CDN** **+** `github.com` **+** `objects.githubusercontent.com`
  (the last two cover Releases assets and the cosign + jq CLI downloads). The origin split is deliberate; both
  origins must be reachable, or use the packaged/MDM path.

## Egress-restricted / air-gapped

Everything is base-URL overridable, so a fleet can point both origins at an internal mirror and verify with
**no external egress**:

| Override | What it redirects | Default |
|---|---|---|
| `--base-url` / `AUSPEX_BASE_URL` (bootstrap), `binaryUri` (Feature) | the **artifact** origin (#1) | *required — no baked default (your distribution host / mirror)* |
| `AUSPEX_COSIGN_BASE_URL` | the pinned **cosign CLI** download | `https://github.com/sigstore/cosign/releases/download` |
| `AUSPEX_JQ_BASE_URL` | the pinned **jq CLI** download (cosign tier's manifest parse) | `https://github.com/jqlang/jq/releases/download` |

Mirror the `manifest.json(.cosign.bundle)` + the content-addressed `blobs/sha256/<digest>` (plus the
`checksums.txt(.cosign.bundle)` + raw binary for the `checksum` tier), and the pinned `cosign-<os>-<arch>`
and `jq-<os>-<arch>` binaries internally; point the overrides at the mirror, and verification runs fully
offline against the embedded `trusted_root.json`. (Shrinking the first-acquisition allow-list toward
**single-origin** — mirroring the pinned cosign + jq on the CDN and defaulting `AUSPEX_COSIGN_BASE_URL` /
`AUSPEX_JQ_BASE_URL` there — is a CDN-publish change tracked separately; the overrides above are the
supported answer today.)

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
