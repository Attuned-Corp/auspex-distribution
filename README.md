# Span Auspex Capture — Dev Container Feature

A [Dev Container Feature](https://containers.dev/implementors/features/) (id `span-auspex`) that installs
the auspex capture agent into a dev container or cloud agent and runs it under the **auspex-owned
supervisor** — the posture for ephemeral environments where no OS service manager (launchd / systemd /
Scheduled Task) is available to keep a daemon alive. `auspex` is the on-box agent; **Span** is the cloud
it enrolls with and egresses to.

The feature source lives in [`src/span-auspex/`](./src/span-auspex). The installer download-integrity test
that exercises it lives in [`tests/`](./tests). See [`CHANGELOG.md`](./CHANGELOG.md) for release notes —
what changed in the Feature and the installers.

> **This repo is auspex's public distribution / trust surface.** Besides the Dev Container Feature it hosts
> the standalone **`curl | sh` / PowerShell installers** ([`bootstrap/`](./bootstrap)) and the shared
> **verify recipe + Sigstore trust anchor** ([`src/span-auspex/verify-lib.sh`](./src/span-auspex/verify-lib.sh)
> + `trusted_root.json`) — a deliberate **second origin, independent of the artifact CDN**. All three
> consumers (Feature, bootstrap, MDM gate) share the one recipe; see [Network access](./docs/networking.md).

## Installing outside a dev container (`curl | sh` / PowerShell)

For laptops / CI / non-devcontainer hosts, a piped installer fetches the raw binary for your OS/arch **from
your auspex distribution host** (passed via `--base-url`), **verifies it fail-closed** against the pinned
release identity + Sigstore trust anchor (the same recipe the Feature uses), and places it on `PATH`. The
installers themselves are served from this repo's **GitHub Releases** (origin #2, independent of the artifact
host). This repo is **host-agnostic** — the artifact host is **not** baked in (matching the Feature's
pluggable `binaryUri`); your install instructions provide the exact `--base-url`:

```bash
# macOS / Linux
curl -fsSL https://github.com/Attuned-Corp/auspex-distribution/releases/latest/download/auspex-install.sh \
  | sh -s -- --version v0.1.0 --base-url <your-auspex-distribution-host>
```

```powershell
# Windows
& ([scriptblock]::Create((irm https://github.com/Attuned-Corp/auspex-distribution/releases/latest/download/auspex-install.ps1))) -Version v0.1.0 -BaseUrl <your-auspex-distribution-host>
```

Flags: `--version <tag>` (required — no `latest` alias on the download host), `--base-url <url>` /
`AUSPEX_BASE_URL` (**required** unless `--url` — your auspex distribution host, from your install
instructions, or an internal mirror), `--verify cosign|checksum|none` (default `cosign`), `--bin-dir <dir>`,
and `AUSPEX_COSIGN_BASE_URL` (mirror the pinned cosign CLI for air-gapped installs). Same verify tiers as the
Feature.

> **The piped script cannot verify its own bytes** — its integrity roots in TLS + origin. For higher
> assurance, each Release asset is cosign-signed (a `.cosign.bundle` beside it): download, verify the
> installer's own signature with a pre-present cosign, then run it. The truly self-verifying acquisition is
> the packaged / notarized / MDM channel (the platform is the pre-present verifier). See
> [Network access](./docs/networking.md) for the per-path host allow-lists and the offline story.

The installers are **assembled** ([`bootstrap/assemble.sh`](./bootstrap/assemble.sh)) from the one
`verify-lib.sh` recipe with `trusted_root.json` embedded — there is no bootstrap-specific copy of the trust
material.

## Managed installs (MDM verify-before-install gate)

For fleet deploys via MDM (macOS Mosyle `.pkg` / Windows Intune `.msi`), a **pre-install gate** verifies the
signed OS-native package against the pinned cosign release identity — adding **build provenance** on top of
Gatekeeper / Authenticode — and **refuses to install on any failure**. It reuses the same `verify-lib.sh`
recipe; the self-contained `auspex-verify-gate.sh` / `.ps1` are published alongside the installers on GitHub
Releases. Integration recipes (Mosyle Custom Command, Intune Win32 wrapper), the exit-code contract, and the
network allow-list are in [`mdm/README.md`](./mdm/README.md).

## What it does

| Phase | Command | Effect |
|-------|---------|--------|
| feature install (root, build time) | [`install.sh`](./src/span-auspex/install.sh) | Places an auspex binary on PATH from a **pluggable source**, persists the resolved options, drops the lifecycle helper. With `hookScope: system`, **also** places the machine-wide `/etc` capture hooks as root (`auspex hooks install --system`) — the one phase with the privilege to write `/etc`. |
| `onCreateCommand` (user) | `lifecycle.sh install` | Service-free, **idempotent** cold install: `auspex install --supervised` enrolls, arms the cold-start capture relax, and wires user-tier capture. It **adapts to `hookScope`**: under `user` it wires the full user catalog; under `system` it defers the machine-wide cells (already placed at build) and wires only the user-scoped VS Code cell. |
| `postStartCommand` (user) | `lifecycle.sh supervise` | (Re)launches `auspex daemon --supervise` — the supervisor respawns the worker and forwards SIGTERM. Serial-safe: a repeat on orchestrator resume is a no-op while a supervisor is already running. |

`install --supervised` is distinct from `install --service` (the two are mutually exclusive): the former
arms the **run-mode relax** so the dumb capture hook spools *before* the daemon's first heartbeat and
across respawns (the cold-start / no-OS-supervisor window); the latter registers a heartbeat-gated OS
service. Neither flag falls back to the other.

## Usage

Reference the **published Feature** by its OCI ref and point `binaryUri` at your auspex **download host**
(the concrete URL is provided to you at onboarding — substitute it for `<your-auspex-download-host>`
below). A copy-paste starting point lives in [`examples/devcontainer.json`](./examples/devcontainer.json).

```jsonc
{
  "image": "mcr.microsoft.com/devcontainers/base:ubuntu",
  "features": {
    // Published Feature (see "Publishing / consuming the Feature"). Pin to the major (:0) for
    // non-breaking updates, a full :0.3.0 to freeze the version, or — strongest — an immutable
    // @sha256:… digest you verified once with cosign (see "Publishing / consuming the Feature").
    "ghcr.io/attuned-corp/auspex-distribution/span-auspex:0": {
      // Raw per-os/arch binary on your download host. {{version}} is substituted from the `version`
      // option below; swap amd64 → arm64 for an arm container. The default verify: cosign resolves the
      // cosign-signed version→digest manifest and installs the artifact BY DIGEST from the content-addressed
      // blob store (auto-provisions cosign + jq; no Sigstore network) — it needs egress to github.com. Use
      // verify: checksum for a no-egress SHA-256-only check against the .sha256 sidecar.
      "binaryUri": "https://<your-auspex-download-host>/releases/{{version}}/linux/amd64/auspex",
      "version": "v0.1.0"
    }
  },
  // Enrollment credentials are ENV, sourced from the platform — never committed literals.
  // The supervised daemon reads them at start (see "Enrolling with Span"). On Codespaces / most
  // CDEs, a repo/org secret named AUSPEX_CLOUD_TOKEN already arrives as an env var, so this block
  // is only needed to forward from a LOCAL shell via ${localEnv:...}:
  "containerEnv": {
    "AUSPEX_CLOUD_TOKEN": "${localEnv:AUSPEX_CLOUD_TOKEN}",
    "AUSPEX_CLOUD_WORK_EMAIL": "${localEnv:AUSPEX_CLOUD_WORK_EMAIL}"
  }
}
```

> **Two independent version numbers.** The `span-auspex:0.3.0` in the Feature ref is the **Feature's** own
> version (what ghcr serves); the `version` option (`v0.1.0` above) is the **auspex binary release tag**
> substituted into `binaryUri`. They advance on separate cadences — pin each to the value you want.

> **Contributing to the Feature itself?** Reference the source in-tree instead of the published ref —
> `"./src/span-auspex": { … }` — with any `binaryUri` (an internal artifact URL or an
> in-container path). That is what the smoke rig uses.

### Options

| Option | Default | Purpose |
|--------|---------|---------|
| `binaryUri` | `""` (required) | Where to get the binary. An `http(s)://` URL is downloaded (and verified — see `verify`); any other value is a path already present in the container and is copied. `{{version}}` in the URL is replaced with `version`. Your download host serves the raw binary at `https://<your-auspex-download-host>/releases/<version>/<os>/<arch>/auspex[.exe]`. |
| `version` | `""` | Release tag substituted into the `binaryUri` template (e.g. `v0.1.0`) and recorded alongside the binary. Empty is fine for a non-templated `binaryUri`; a `{{version}}` template with no `version` **fails the install** (there is no `latest` alias on the download host). |
| `verify` | `cosign` | Integrity/provenance check for a **downloaded** `binaryUri`. `cosign` (default) resolves the cosign-signed version→digest manifest for the requested tag + os/arch, then installs the artifact **by digest** from the content-addressed blob store and self-verifies (`sha256(bytes)` == the signed digest) — **authenticity**, and it closes the version-substitution gap by binding the tag into the signed index. It needs **no** pre-installed cosign or jq (the Feature auto-provisions pinned ones) and makes **no** Sigstore network calls (a pinned `trusted_root.json` ships in the Feature); it does need egress to `github.com` (a ~150 MB cosign + a small jq, once per build). `checksum` fetches the adjacent `<binaryUri>.sha256` and fails on a SHA-256 mismatch or a missing sidecar (integrity only, no egress beyond the download host). `none` skips verification. Ignored for an in-container path `binaryUri`. See [Verifying the download](#verifying-the-download). |
| `auspexHome` | `""` | `AUSPEX_HOME` for the binary, config, and runspace. Empty uses the daemon default (`~/.auspex`). A non-default value is **published container-wide** by the feature (see [Custom home](#custom-home)) so coding-tool hooks resolve the same home as the daemon — no manual `containerEnv` override needed. |
| `tokenFile` | `""` | **Path** to a platform-mounted file holding the org token (not the token itself). The more secure enrollment path — see [Enrolling with Span](#enrolling-with-span). |
| `deviceId` | `""` | Pins `AUSPEX_DEVICE_ID`. **Leave empty in almost all cases** — see [Device identity](#device-identity). There is deliberately **no `token` option** for the secret value itself (a secret doesn't belong in committed config). |
| `hookScope` | `user` | Where capture hooks are placed: `user` (per-user tool configs, wired at onCreate) or `system` (machine-wide `/etc`, placed as root at build time). See [Hook placement](#hook-placement). |

## Pluggable binary source

The binary source is supplied through `binaryUri` — the feature embeds no default — so the same feature
works whether the binary comes from the auspex **download host**, an internal artifact store, an
authenticated release URL, an image layer, or a path mounted into the container. If `binaryUri` is empty
the install fails fast with guidance rather than guessing a source.

**Download host (recommended).** Each release is mirrored to your auspex download host (the concrete URL
is provided at onboarding — shown here as `<your-auspex-download-host>`) under a stable, guessable layout:

```
https://<your-auspex-download-host>/releases/<version>/<os>/<arch>/auspex[.exe]        # raw binary (one-hop human path)
https://<your-auspex-download-host>/releases/<version>/<os>/<arch>/auspex[.exe].sha256 # its checksum sidecar (verify: checksum)
https://<your-auspex-download-host>/releases/<version>/manifest.json                   # + .cosign.bundle — signed version→digest index (verify: cosign)
https://<your-auspex-download-host>/releases/<version>/checksums.txt                   # + .cosign.bundle (signed digest list)
https://<your-auspex-download-host>/blobs/sha256/<digest>                              # content-addressed artifact bytes (verify: cosign installs here)
```

So a devcontainer pins a release with `version` + a templated `binaryUri` (see [Usage](#usage)):
`https://<your-auspex-download-host>/releases/{{version}}/linux/amd64/auspex`.

### Verifying the download

A downloaded binary is verified **before** it is placed on PATH; a failed check refuses the install (fails
closed) rather than running unverified bytes. `binaryUri` must be **https** (an `http://` URL is refused —
no cleartext fetch of the agent). The `verify` option selects the check:

- **`cosign` (default) — resolve → fetch-by-digest → verify.** Proves *authenticity*, not just integrity.
  The auspex release workflow **keyless-signs** a `version→digest` index (`manifest.json`, an OCI
  image-index) that binds the tag + each os/arch to the artifact's sha256 (Sigstore; auspex ADR 0033 §4/§5,
  ADR 0047). The Feature keyless-verifies that manifest against auspex's pinned release identity, **asserts
  its version annotation matches the requested tag** (closing the version-substitution gap), reads the digest
  for this os/arch, then fetches the bytes **by digest** from the content-addressed blob store
  (`blobs/sha256/<digest>`) and self-verifies `sha256(bytes)` == the signed digest. It is **self-contained**:
  it **auto-provisions** a pinned cosign **and jq** (each verified against a hardcoded SHA-256) when not on
  PATH, and verifies **fully locally** against a pinned `trusted_root.json` shipped in the Feature — **no
  Sigstore (TUF/Rekor) network**. It does need egress to `github.com` for cosign + jq (a one-time download
  per build) unless they're already in the image. On non-Linux/macOS, or a CPU with no pinned cosign,
  pre-install cosign (and jq) or use `checksum`.
- **`checksum`.** Fetches `<binaryUri>.sha256` and compares it to the SHA-256 of the download. A mismatch
  **or a missing sidecar** fails the install. Integrity only (not provenance), but needs no tooling and no
  egress beyond the download host.
- **`none`.** Skips verification — only for a source you already trust out of band.

To verify by hand (the same check `verify: cosign` runs; this uses Sigstore's TUF over the network, whereas
the Feature pins `trusted_root.json` to stay offline):

```bash
HOST=<your-auspex-download-host>   # the concrete download host, provided at onboarding
V=v0.1.0; OS=linux; ARCH=amd64
curl -fsSLO https://$HOST/releases/$V/manifest.json
curl -fsSLO https://$HOST/releases/$V/manifest.json.cosign.bundle
cosign verify-blob \
  --bundle manifest.json.cosign.bundle \
  --certificate-identity-regexp '^https://github\.com/(?i:attuned-corp)/auspex/\.github/workflows/release\.yml@refs/tags/v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  manifest.json
# confirm the manifest is for the tag you asked for, then read + fetch the by-digest artifact for your os/arch:
test "$(jq -r '.annotations["org.opencontainers.image.version"]' manifest.json)" = "$V"
DIGEST=$(jq -r --arg os "$OS" --arg arch "$ARCH" \
  '.manifests[] | select(.mediaType=="application/octet-stream" and .platform.os==$os and .platform.architecture==$arch) | .digest' manifest.json)
curl -fsSLO "https://$HOST/blobs/sha256/${DIGEST#sha256:}"
# then confirm sha256(the downloaded blob) == ${DIGEST#sha256:}
```

### Updating the pinned cosign / jq / trust root

`verify: cosign` is self-contained by pinning four things in the **shared verify recipe**
([`src/span-auspex/verify-lib.sh`](./src/span-auspex/verify-lib.sh)): the cosign **version**
(`COSIGN_VERSION`) + per-os/arch **SHA-256** (`COSIGN_SHA256_linux_amd64` / `_linux_arm64` /
`_darwin_amd64` / `_darwin_arm64` / `_windows_amd64`); the **jq** version (`JQ_VERSION`) + per-os/arch
**SHA-256** (`JQ_SHA256_linux_amd64` / `_linux_arm64` / `_macos_amd64` / `_macos_arm64`), which the cosign
tier auto-provisions to parse the signed manifest (bash only — the PowerShell installer parses it with
native JSON); and the Sigstore **`trusted_root.json`** beside it. These pins are the **single source of
truth** shared by the Feature, the `curl|sh` + PowerShell bootstrap, and the MDM gate; the `reconcile-trust`
guard fails CI if `COSIGN_VERSION` / the identity / the issuer drift from the auspex signer's descriptor.
Keep `COSIGN_VERSION` in lock-step with the **signer** — the auspex repo's `Makefile.setup.mk`
`COSIGN_VERSION`, the version the release workflow signs with — and bump them together:

```bash
# 1) match the signer's cosign version, then capture the release binary hashes (all pinned platforms):
curl -fsSL https://github.com/sigstore/cosign/releases/download/<vX.Y.Z>/cosign_checksums.txt \
  | grep -E 'cosign-(linux|darwin)-(amd64|arm64)$|cosign-windows-amd64\.exe$'
# 2) refresh the pinned jq (any recent jq parses the manifest; bump to keep current):
curl -fsSL https://github.com/jqlang/jq/releases/download/<jq-X.Y.Z>/sha256sum.txt \
  | grep -E 'jq-(linux|macos)-(amd64|arm64)$'
# 3) refresh the pinned Sigstore trust root (only when cosign or Sigstore rotates roots):
cosign initialize
cp ~/.sigstore/root/tuf-repo-cdn.sigstore.dev/targets/trusted_root.json \
   src/span-auspex/trusted_root.json
```

Bump the Feature `version` in the same PR (any behavioural change) and re-publish. The
`make verify-test` gate asserts the pinned-hash gate still fails closed on a tampered cosign.

### License

Every release archive bundles the `LICENSE` file (pinned into the `.tar.gz`/`.zip`), so it travels with
the artifacts on the public host. The raw single-binary asset is the executable only — see the release
archive for the license text.

## Publishing / consuming the Feature

The Feature is published to **GitHub Container Registry** as
`ghcr.io/attuned-corp/auspex-distribution/span-auspex`, versioned from the `version` in
[`devcontainer-feature.json`](./src/span-auspex/devcontainer-feature.json) (e.g. `0.3.0` publishes
`:0.3.0`, `:0.3`, `:0`, `:latest`). Consumers reference it directly (see [Usage](#usage)) — no vendoring
of the source.

Publishing is a manual go-live step (the [Publish Dev Container Feature](./.github/workflows/publish-feature.yml)
workflow, `workflow_dispatch`), decoupled from merging a change — bump the Feature `version` in the same
PR as any behavioural change, then dispatch. A newly-created package lands **private** and is administrable
only by org owners; make it **Public** once in the org's package settings so customers can pull it (a
one-time flip). Because this repo is public, the package landing page then shows this README — the
customer-facing Feature doc, with working provenance.

### Signature + digest pinning

The Feature is the **top of the trust chain**: its `install.sh` runs at container build and performs the
`verify: cosign` check of the downloaded binary, so its own authenticity matters. The publish workflow
**keylessly cosign-signs** the pushed OCI artifact by its immutable digest (OIDC → Fulcio → Rekor, no
stored key) and prints the `@sha256:…` pin + verify command to its run summary.

For the strongest supply-chain posture, **pin the digest** in your `devcontainer.json` rather than a
mutable tag. Learn (and verify) the digest once:

```bash
cosign verify \
  --certificate-identity-regexp '^https://github\.com/(?i:attuned-corp)/auspex-distribution/\.github/workflows/publish-feature\.yml@refs/heads/main$' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  ghcr.io/attuned-corp/auspex-distribution/span-auspex:0.3.0
```

cosign prints the verified digest; pin it as `ghcr.io/attuned-corp/auspex-distribution/span-auspex@sha256:<digest>`.
Note: the devcontainer CLI does **not** verify Feature signatures itself, so a digest pin (plus this
one-time out-of-band `cosign verify`) is what turns the signature into real protection; a bare `:0` /
`:0.3.0` tag is convenient but mutable.

## Enrolling with Span

Enrollment is **environment-driven** and happens at daemon start — you do **not** run `auspex install
--token` in the container (the feature already ran the install; the supervised daemon reads the env
directly):

| Credential | Env var | Effect |
|------------|---------|--------|
| Org token | `AUSPEX_CLOUD_TOKEN` | **Required to send to Span.** Non-empty ⇒ the device enrolls and Span becomes the primary egress route. |
| Work email | `AUSPEX_CLOUD_WORK_EMAIL` | Optional; sets the `X-Span-Work-Email` header on egress. Empty ⇒ header omitted. |

**Without a token the agent still runs** — it just writes an OTLP-JSON file to
`<AUSPEX_HOME>/run/events.jsonl` and sends nothing off-box (the local, unenrolled posture). So the token
is required for *cloud capture*, not for the agent to function.

### Providing the token — file (preferred) or env

The token is the one true secret; provide it from the platform's secret store, **never** as a committed
literal or the token *value* in a feature option.

**Preferred — mounted file (`tokenFile`).** Point the `tokenFile` option at a path where the platform
mounts the secret **as a file**; onCreate reads it once via `auspex install --token-file` into the 0600
identity file. The secret never enters the process environment, so it isn't exposed through
`/proc/<pid>/environ` or inherited by every child process — tighter than an env var. The option value is
the *path*, not the secret:

```jsonc
"features": {
  "./src/span-auspex": {
    "binaryUri": "…",
    "tokenFile": "/run/secrets/auspex-token"   // platform-mounted secret file; NOT the token
  }
}
```

If the file is absent at onCreate, the feature warns and installs **unenrolled** (local-only) rather than
failing the container.

**Alternative — env (`AUSPEX_CLOUD_TOKEN`).** Simpler where only env secrets are available:
- **Codespaces / most CDEs:** define a **Codespaces (or org) secret** `AUSPEX_CLOUD_TOKEN`; the platform
  injects it as an env var the daemon reads — no `devcontainer.json` change needed.
- **Local `devcontainer` CLI:** forward from your shell with `"AUSPEX_CLOUD_TOKEN":
  "${localEnv:AUSPEX_CLOUD_TOKEN}"` under `containerEnv` (as in [Usage](#usage)) — the `${localEnv:…}`
  reference is safe to commit; the value never is.

### Work email is per-user, not a shared secret

The **org token is org-scoped** (the same value for everyone in the org — a shared org/repo secret is
fine). The **work email is per-user** and identifies *which* user within that org, so it must differ per
person. Set it as a **per-user** value, not a team/project literal:

- **Codespaces:** a per-user **Codespaces secret** `AUSPEX_CLOUD_WORK_EMAIL` (each user sets their own
  under their account) arrives as a per-user env var — correct per user.
- **Ona / Gitpod:** a per-user **account environment variable** `AUSPEX_CLOUD_WORK_EMAIL` is injected into
  that user's workspaces — correct per user.

Both work **because the value comes from a per-user setting**; neither platform auto-injects the user's
verified email, so each user configures it once. **Do not** hard-code `AUSPEX_CLOUD_WORK_EMAIL` in
`containerEnv` as a shared literal — every user would then be misattributed to one email. (Email is not
sensitive, so it needs no file mount; the per-user scoping is the only concern.)

### Rotation caveat

An **env**-supplied token/email is captured **once at daemon start**; rotating it takes effect on the next
supervised (re)start — the orchestrator's resume, which re-runs `postStart`. A **file**-supplied identity
(the `tokenFile` path → identity file) is **hot-reloaded** by the daemon on its next scheduler tick, so
file-based rotation needs no restart. To rotate the identity file directly, `auspex auth set --token …`.

## Hook placement

The `hookScope` option selects **where** capture hooks are written. It is orthogonal to enrollment and to
the supervised run mode — it only moves the hook files.

### `user` (default)

Hooks are wired into the **container user's own tool configs** at onCreate — e.g.
`~/.claude/settings.json`, `~/.cursor/hooks.json`, `~/.codex/hooks.json`. For Claude/Codex/Cursor this is a
**surgical merge into a shared settings file**, which carries a real hazard in a dev container: another
feature (or the user) can overwrite that file, or clobber the hook entries auspex merged in. Prefer `user`
when nothing else in the image contends for those files.

### `system`

Hooks are written to **dedicated machine-wide `/etc` files** the tools also read — e.g.
`/etc/claude-code/managed-settings.d/auspex.json` and `/etc/github-copilot/policy.d/zz-auspex.json`
(auspex-owned whole files), and `/etc/codex/hooks.json` / `/etc/cursor/hooks.json` (dedicated system
paths). Two reasons to pick it:

- **Clobber-isolation.** auspex's hooks live in their own `/etc` files, not merged into a shared user
  config another Feature can overwrite.
- **Enterprise lockdown.** System placement is the only tier that fires under Claude's
  `allowManagedHooksOnly`.

The machine-wide cells are placed **at build time, as root** (`install.sh` runs `auspex hooks install
--system`) — the one lifecycle phase with the privilege to write `/etc`, since onCreate/postStart run as
the (usually non-root) container user. onCreate's `install --supervised` then sees the system placement
and **defers** those cells (they are already at `/etc`; re-wiring them at the user tier would
double-capture), while still enrolling, arming capture, and wiring the user-scoped VS Code cell.

This is **placement only** — it writes **no** MDM governance marker (`/etc/auspex/managed.yaml`), does not
turn the container into a "managed device", and does not refuse the user-tier onCreate. It is distinct
from `auspex install --system`, which is the MDM *governance converge* (asserts an MDM marker, tears down
the user tier, provisions a managed identity) and is **not** what the Feature runs.

**Rootless builders:** writing `/etc` needs a root feature-install phase (the default). On a rootless
builder the system placement is **skipped with guidance** and onCreate falls back to a normal user-tier
install — so the container still captures; you can then run `sudo auspex hooks install --system` inside it,
or set `hookScope: user`.

**Wire-once (no self-heal).** A non-root supervised daemon cannot rewrite `/etc`, so unlike the user tier
there is no reconcile that re-wires a tool installed *after* the build. The build-time placement is the one
write; a tool added later at the system tier needs a rebuild (or a manual `sudo auspex hooks install
--system`).

### VS Code is user-scoped either way

VS Code has **no machine-wide hook path** — its hook registration lives in the user's settings — so
`hookScope: system` never places it at `/etc` (it is skipped there with a note). In a dev container the VS
Code **Server** reads its settings from **machine-settings** (`~/.vscode-server/data/Machine/settings.json`),
not the desktop `settings.json` a command would write, so the Feature registers VS Code capture
**declaratively**: it contributes `customizations.vscode.settings` (`chat.useHooks` +
`chat.hookFilesLocations` pointing at `~/.auspex/vscode/hooks.json`) that the Server picks up. The hooks
*file* those settings point at is written by onCreate's user-scoped VS Code cell under either scope.

> Note: the declarative VS Code settings assume the **default** `~/.auspex` home (a Feature cannot
> interpolate an option value into `customizations` — the same [spec#164](https://github.com/devcontainers/spec/issues/164)
> limitation as `containerEnv`). With a custom `auspexHome`, the machine-wide `/etc` cells and the user-tier
> hooks are unaffected, but the container VS Code Server would need the `chat.hookFilesLocations` entry
> pointed at `<auspexHome>/vscode/hooks.json` yourself.

```jsonc
"features": {
  "./src/span-auspex": {
    "binaryUri": "…",
    "hookScope": "system"
  }
}
```

## Custom home

Setting `auspexHome` to a non-default path (anything other than `~/.auspex`) risks the **home-divergence
footgun**: the supervised daemon runs under the custom home, but coding-tool hooks inherit the *container*
environment — not the lifecycle shell that runs the install/supervise — so without help they resolve the
default `~/.auspex` and spool into a runspace the daemon never drains (silent capture loss).

The feature closes this itself. At feature-install time it **publishes `AUSPEX_HOME` container-wide** —
written to `/etc/environment` (read by PAM for every login session) and dropped as
`/etc/profile.d/auspex-home.sh` — so any shell or agent a coding tool spawns inherits the custom home and
its hooks resolve the *same* home as the daemon. You do **not** need to mirror `auspexHome` into
`containerEnv` (a Dev Container Feature cannot interpolate an option value into `containerEnv`
[[spec#164](https://github.com/devcontainers/spec/issues/164)], which is why the feature publishes it at
install time instead). Leaving `auspexHome` empty (the default `~/.auspex`) publishes nothing — the daemon
and a clean hook already agree.

## Device identity

The device id is resolved as: **operator override (`AUSPEX_DEVICE_ID` / `device.id`) → persisted
`<AUSPEX_HOME>/run/device-id` → a generated v4 UUID** (written once). There is no hardware/host
fingerprint.

**Leave `deviceId` empty by default.** The daemon then generates a UUID per container, so each container
is a **distinct device** in Span. Two failure modes to avoid:

- **Do NOT hard-code a shared literal** (e.g. `deviceId: "team-alpha"`) in a template/`devcontainer.json`
  used by many people or many containers — every one of them would report the **same** device id and
  collapse into a single device in Span. This is the common mistake.
- On a fully ephemeral runspace (no persistent volume), a rebuild mints a **new** id, so one logical
  workspace can look like a series of short-lived devices.

If — and only if — you need one *logical* device to stay stable across rebuilds, either mount
`<AUSPEX_HOME>/run/` on a durable volume, or set `deviceId` to a value that is **unique per user +
workspace**, e.g. via an expansion rather than a literal:

```jsonc
"features": {
  "./src/span-auspex": {
    "binaryUri": "…",
    // unique-per-user, stable across rebuilds — NOT a shared constant:
    "deviceId": "${localEnv:USER}-myrepo-devcontainer"
  }
}
```

## Operational notes

### Egress allowlist

In a network-restricted container, **add the Span egress endpoints to the allowlist** (or the enterprise
proxy's) or enrollment traffic is dropped. Egress is fail-soft: when the endpoint is unreachable, events
stay spooled locally and drain when connectivity returns rather than being lost — but a container torn
down while egress is blocked loses whatever had not yet drained (ephemeral filesystem). Size the
environment's idle window / allowlist accordingly.

### Out-of-band restart & teardown flush (limitation)

Restart is **orchestrator-driven**: the supervisor is relaunched by `postStartCommand` when the platform
resumes the container. A raw `docker start` / `docker restart` does **not** re-run lifecycle hooks, so the
supervisor will not come back that way — resume through the dev-container orchestrator (or the CDE), not
the raw container runtime.

Because `postStart` launches the supervisor as a background child of the lifecycle runner (not as PID 1),
a container **stop** does not reliably deliver SIGTERM to it — the teardown spool flush is **best-effort**.
Events already egressed are safe; the last unflushed spool may be lost on a hard stop. This is inherent to
the no-PID-1 posture and is why the run-mode relax keeps spooling across the restart window rather than
relying on a clean shutdown.

### Codex user namespaces

Codex's sandbox uses bubblewrap, which needs **unprivileged user namespaces**. Many container runtimes
restrict them, so Codex may fail to start its sandbox in a dev container. Enable user namespaces for the
container (e.g. an appropriate `--security-opt` / runtime setting), or run Codex with a sandbox mode that
does not require them. This is a Codex-in-container requirement, independent of auspex capture.

## CI / testing

```bash
make verify-test    # install.sh + curl|sh bootstrap download-verify contract — pure bash+HTTP, no Docker
make assemble       # build dist/auspex-install.sh|.ps1 from the shared recipe (Release assets)
make shellcheck     # lint all shell scripts
```

`verify-test` serves a fixture binary + `.sha256` over localhost and drives **both** `install.sh` and the
`curl|sh` bootstrap (in its repo-checkout form *and* the assembled release form with the trust anchor
embedded) through every `verify:` tier, asserting a tampered/absent/identity-mismatched artifact fails
closed (nothing installed) and a matching one installs — the fast gate that runs on every PR (see
[`ci.yml`](./.github/workflows/ci.yml)). It also proves the pinned-cosign hash gate refuses a tampered
downloaded cosign.

Two more workflows guard the trust surface: [`reconcile-trust.yml`](./.github/workflows/reconcile-trust.yml)
diffs this repo's verifier config against the auspex signer's descriptor at a pinned ref (AC5), and
[`release-bootstrap.yml`](./.github/workflows/release-bootstrap.yml) assembles + cosign-signs the installers
and cuts a Release.

> **Docker-backed behavioural smoke (follow-up).** The full `devcontainer up` smoke — bring a throwaway
> container up through this Feature and assert one synthetic capture event reaches the local sink with
> `run_mode=SUPERVISED`, plus the `hookScope: system` `/etc`-placement variant — needs a built auspex
> binary, which lives in the private `auspex` repo. It has not yet been reconstituted in this repo; when it
> is, it will obtain the binary from a CDN-published release (or a path passed in) rather than a local
> `go build`.
