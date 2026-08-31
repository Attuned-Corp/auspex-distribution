# auspex — Cursor cloud agent capture

Capture coding-agent activity (shell / file / tool events + token usage) from **Cursor cloud agents** —
the Cursor-managed Linux VMs launched from `cursor.com/agents`, Desktop, Slack, or GitHub `@cursor` — and
send it to Span, attributed to the human who dispatched the agent.

This recipe installs auspex on the agent VM at startup, wires **one** Cursor hook tier, runs the supervised
daemon, and enrolls with Span. It needs **one secret** (a team-scoped org token); the per-user work email is
**auto-discovered** from Cursor's agent metadata socket, so nothing per-user is required.

> No auspex code change is involved — this recipe only composes shipped auspex commands (`install`,
> `daemon --supervise`, `status`) with Cursor's environment lifecycle.

## What's here

This directory holds the **consumer example** — the Cursor environment config you point at the recipe. The
executable recipe itself lives in [`cursor-cloud/`](../../cursor-cloud/) and is **cosign-signed and
published as GitHub Release assets** (`cursor-cloud-install.sh` / `-start.sh` / `-preflight.sh`), so the
recommended install fetches it from an immutable, signed URL — the same posture as the Dev Container Feature.

| File | Role |
|---|---|
| `environment.json` | **Primary** recipe config (no custom image). `install` + `start` hooks. |
| `environment.docker.json` + `Dockerfile` | **Variant** for teams already using a custom base image (bakes the binary at build). |

| Published asset (from `cursor-cloud/`) | Role |
|---|---|
| `cursor-cloud-install.sh` | Build phase: fetch + verify the signed binary, place one hook tier (`auspex hooks install --system`). |
| `cursor-cloud-start.sh` | Run phase: derive the work email from the metadata socket, launch the supervised daemon (which enrolls). |
| `cursor-cloud-preflight.sh` | Optional in-agent check for the two cloud-env facts `auspex status` can't see. |

## Install

Set up the environment once — either at the **team level** (recommended; covers every repo) or
**per-repository**. Then configure the secret and launch. The recipe scripts are self-contained (they
reference no repo files), so the team-level path fetches them straight from the signed Release assets.

### Option A — team-level environment (recommended)

In Cursor, go to **Dashboard → Cloud Agents → Environments** and create/edit your **team** environment.
Point its commands at the **signed Release assets** — no per-repository files needed:

- **Install command:**

```bash
curl -fsSL https://github.com/Attuned-Corp/auspex-distribution/releases/latest/download/cursor-cloud-install.sh | bash
```

- **Start command:**

```bash
curl -fsSL https://github.com/Attuned-Corp/auspex-distribution/releases/latest/download/cursor-cloud-start.sh | bash
```

`latest/download` tracks the newest non-prerelease release; pin a specific tag
(`.../releases/download/<tag>/cursor-cloud-install.sh`) for a reproducible setup. The assets are
cosign-signed (a `.cosign.bundle` accompanies each) — see [Verifying the recipe](#verifying-the-recipe) to
check them before running. A repo that ships its own `.cursor/environment.json` overrides the team
environment (Cursor resolves repo → personal → team, first match wins), so the team environment applies to
every repo that doesn't define its own.

### Option B — per-repository

Commit just a `.cursor/environment.json` that fetches the **same signed recipe** — no scripts are vendored,
so an upstream `install.sh` / `start.sh` fix flows in automatically (nothing to keep in sync):

```bash
mkdir -p .cursor
cp examples/cursor-cloud/environment.json .cursor/environment.json
```

The committed `environment.json` runs the same signed Release assets as Option A, just from the repo so it
overrides the team environment:

```json
{
  "install": "curl -fsSL https://github.com/Attuned-Corp/auspex-distribution/releases/latest/download/cursor-cloud-install.sh | bash",
  "start": "curl -fsSL https://github.com/Attuned-Corp/auspex-distribution/releases/latest/download/cursor-cloud-start.sh | bash"
}
```

For the Dockerfile variant instead — the one case that must vendor files, since it bakes the verified binary
into the image at build — also copy the scripts and Dockerfile, then swap in its config:

```bash
cp examples/cursor-cloud/Dockerfile .cursor/Dockerfile
cp cursor-cloud/install.sh .cursor/install.sh
cp cursor-cloud/start.sh .cursor/start.sh
cp examples/cursor-cloud/environment.docker.json .cursor/environment.json
```

Then **commit and push** to the branch you'll launch the agent on — Cursor reads `.cursor/environment.json`
from the launch branch, so an uncommitted file is not seen.

### Then: secret + settings, and launch

Configure these in Cursor's cloud agent **Secrets** tab. Prefer the **team** scope — the token is one
org-wide credential, and it pairs with a team environment:

| Name | Kind | Scope | Value |
|---|---|---|---|
| `AUSPEX_CLOUD_TOKEN` | Runtime Secret | **Team** | your org token |
| `AUSPEX_BASE_URL` | Runtime Secret or env var | **Team** | your auspex download host / mirror (provided at onboarding), e.g. `https://<your-auspex-download-host>` |
| `AUSPEX_VERSION` | Runtime Secret or env var (optional) | **Team** | pin a signed release tag; **unset installs the latest** signed release |
| `AUSPEX_VERIFY` | Runtime Secret or env var (optional) | **Team** | `cosign` (default) · `checksum` · `none` |

`AUSPEX_CLOUD_WORK_EMAIL` is **optional** — leave it unset and the work email is auto-discovered; set it
only to override the discovered value.

> **Scope matters more than kind (no-Dockerfile recipe).** The primary recipe's `install` step runs in the
> **agent context**, so it sees **team-scoped** secrets — a Runtime Secret *or* an environment variable both
> work — but **not user-scoped** values (those reach only the run phase). So set `AUSPEX_BASE_URL` (and
> `AUSPEX_VERSION`/`AUSPEX_VERIFY`) at the **Team** scope; the *kind* doesn't matter. A user-scoped
> `AUSPEX_BASE_URL` is invisible to `install` and the fetch fails.
> (Dockerfile variant: a true image **Build** sees only build args — pass `AUSPEX_BASE_URL` via `--build-arg`
> instead; see `environment.docker.json`.)

Then **launch a normal cloud agent**. (Don't use the interactive "Set up agent" button — that is a
different, ephemeral setup mode.)

## Networking / egress allowlist

If your org restricts agent egress, allowlist (all hosts are your own / provided at onboarding — nothing is
hardcoded here; see [`docs/networking.md`](../../docs/networking.md) for the full per-path reference):

- your **Span capture ingest host** (the enrollment / egress endpoint from onboarding) — captured events go here.
- your **`AUSPEX_BASE_URL` download host** — the signed binary artifact.
- `github.com` + `objects.githubusercontent.com` — the Release assets (the `auspex-install.sh` bootstrap and
  this recipe's `cursor-cloud-*.sh` scripts, which both the team-level path in Option A and the per-repository
  path in Option B fetch at run time; Release-asset downloads redirect to `objects.githubusercontent.com`),
  and — only when `AUSPEX_VERIFY=cosign` — the pinned cosign/jq CLIs. Use `AUSPEX_VERIFY=checksum` to drop the
  cosign egress (SHA-256 integrity only). Only the Dockerfile variant vendors the scripts, so it alone skips
  the run-time script fetch.

## Verifying the recipe

The recipe scripts are cosign keyless-signed; each Release asset ships a `.cosign.bundle`. To verify a script
before running it (the security-conscious team-level path):

```bash
base=https://github.com/Attuned-Corp/auspex-distribution/releases/latest/download
curl -fsSLO "$base/cursor-cloud-install.sh"
curl -fsSLO "$base/cursor-cloud-install.sh.cosign.bundle"
cosign verify-blob --bundle cursor-cloud-install.sh.cosign.bundle \
  --certificate-identity-regexp '^https://github.com/Attuned-Corp/auspex-distribution' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  cursor-cloud-install.sh
```

(`checksums.txt` on the Release covers all assets for a SHA-256-only check.)

## Verification (inside the running agent)

```bash
auspex status --verbose --check-token   # daemon up · placement · token valid · single tier · delivery
# + the two cloud-env facts (token injected, email resolved):
curl -fsSL https://github.com/Attuned-Corp/auspex-distribution/releases/latest/download/cursor-cloud-preflight.sh | bash
```

A healthy setup shows the daemon reachable, `capture_wiring` passing, `token_validity` OK, and a single
placement tier (no double-capture).

## How it works

- **Signed recipe + signed install.** The recipe scripts themselves are cosign-signed Release assets (verify
  them per [Verifying the recipe](#verifying-the-recipe)). At build, `cursor-cloud-install.sh` pipes the
  release's `auspex-install.sh` bootstrap (resolved from `releases/latest/download`, independent of the
  `AUSPEX_VERSION` binary tag it passes through as `--version`), which fetches the pinned binary from
  `AUSPEX_BASE_URL` and **cosign-verifies it against an offline embedded trust root before execution** — a
  tampered/unsigned/wrong-version artifact fails closed (no capture wired). A custom image (Dockerfile
  variant) bakes this at build so the run-phase skips the download.
- **Single hook tier (no double-capture).** `install.sh` runs the shipped placement primitive
  `auspex hooks install --system`, wiring the **system** tier (`/etc/cursor/hooks.json`) — the same primitive
  auspex's dev-container Feature uses. The install phase runs as root on a custom Dockerfile image and as a
  non-root user *with passwordless sudo* on the stock image, so the script elevates accordingly (direct when
  root, `sudo -E` otherwise) and only falls back to the **user** tier (`~/.cursor/hooks.json`) when it can't
  elevate at all. It deliberately does **not** run `auspex install` (a per-user installer that refuses root)
  or `auspex install --system` (an MDM converge needing a pre-deployed managed tree). Never both tiers:
  auspex's placement marker guard refuses a conflicting second, so events are captured exactly once.
- **Identity + run mode from the daemon, not the installer.** `start.sh` runs `auspex daemon --supervise`,
  which enrolls from `AUSPEX_CLOUD_TOKEN` (+ the resolved work email) at run time and arms the cold-start
  capture relax itself — so no install-time enrollment step is needed, and nothing needs to run as a
  non-root user.
- **Run-phase launcher.** Cursor's `start` command runs from an unspecified working directory (typically
  `$HOME`, not the repo root). The primary recipe (Option A and the fetch-based Option B) re-fetches
  `start.sh` via `curl|bash` each run, so the working directory is irrelevant. The Dockerfile variant, which
  vendors the scripts instead, relies on `install.sh` staging `start.sh` at `$HOME/.auspex/cloud-start.sh` so
  its `start` hook can invoke it by absolute path.
- **Attribution with no per-user secret.** `start.sh` curls the agent metadata socket
  (`/run/cursor/api.sock` → `/v1/meta-data/owner/user-email`) and exports `AUSPEX_CLOUD_WORK_EMAIL`, which
  auspex's enrollment consumes. An explicit secret (if you set one) takes precedence; a socket failure is
  non-fatal (capture continues, unattributed).

## Limitations

- **Read-only head:** Cursor's `sessionStart` hook does not fire in the cloud head; the first shell/file/
  tool events are still captured.
- **Teardown:** a burst of events in the final moments before the VM is torn down may not flush.
- **Owner-scoped attribution:** the email is resolved once at start (`owner/user-email`), so a multi-person
  agent attributes to the owner.
