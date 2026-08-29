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

| File | Role |
|---|---|
| `environment.json` | **Primary** recipe (no custom image). `install` + `start` hooks. |
| `install.sh` | Build-phase: fetch + verify the signed binary, place one hook tier, arm the daemon. |
| `start.sh` | Run-phase: derive the work email from the metadata socket, launch the supervised daemon. |
| `preflight.sh` | Optional in-agent check for the two cloud-env facts `auspex status` can't see. |
| `environment.docker.json` + `Dockerfile` | **Variant** for teams already using a custom base image (bakes the binary at build). |

## Install

Set up the environment once — either at the **team level** (recommended; covers every repo) or
**per-repository**. Then configure the secret and launch. `install.sh` and `start.sh` are self-contained
(they reference no repo files), so the team-level path can run them straight from this repo.

### Option A — team-level environment (recommended)

In Cursor, go to **Dashboard → Cloud Agents → Environments** and create/edit your **team** environment.
Point its commands at this recipe — no per-repository files needed:

- **Install command:**

```bash
curl -fsSL https://raw.githubusercontent.com/Attuned-Corp/auspex-distribution/main/examples/cursor-cloud/install.sh | bash
```

- **Start command:**

```bash
curl -fsSL https://raw.githubusercontent.com/Attuned-Corp/auspex-distribution/main/examples/cursor-cloud/start.sh | bash
```

Pin `main` to a release tag (e.g. `v0.1.0`) for a reproducible setup. A repo that ships its own
`.cursor/environment.json` overrides the team environment (Cursor resolves repo → personal → team,
first match wins), so the team environment applies to every repo that doesn't define its own.

### Option B — per-repository

Copy the files into the repo's `.cursor/` directory:

```bash
mkdir -p .cursor
cp examples/cursor-cloud/environment.json .cursor/environment.json
cp examples/cursor-cloud/install.sh .cursor/install.sh
cp examples/cursor-cloud/start.sh .cursor/start.sh
cp examples/cursor-cloud/preflight.sh .cursor/preflight.sh   # optional
```

For the Dockerfile variant instead: also copy `Dockerfile`, then
`cp examples/cursor-cloud/environment.docker.json .cursor/environment.json`. Then **commit and push** to the
branch you'll launch the agent on — Cursor reads `.cursor/environment.json` from the launch branch, so an
uncommitted file is not seen.

### Then: secret + settings, and launch

Configure these in Cursor's cloud agent **Secrets** tab. Prefer the **team** scope — the token is one
org-wide credential, and it pairs with a team environment:

| Name | Kind | Scope | Value |
|---|---|---|---|
| `AUSPEX_CLOUD_TOKEN` | **Runtime Secret** | **Team** | your org token |
| `AUSPEX_BASE_URL` | Environment variable | Team | your auspex download host / mirror (provided at onboarding), e.g. `https://<your-auspex-download-host>` |
| `AUSPEX_VERSION` | Environment variable (optional) | Team | the signed release tag (default `v0.1.0`) |
| `AUSPEX_VERIFY` | Environment variable (optional) | Team | `cosign` (default) · `checksum` · `none` |

`AUSPEX_CLOUD_WORK_EMAIL` is **optional** — leave it unset and the work email is auto-discovered; set it
only to override the discovered value.

Then **launch a normal cloud agent**. (Don't use the interactive "Set up agent" button — that is a
different, ephemeral setup mode.)

## Networking / egress allowlist

If your org restricts agent egress, allowlist (all hosts are your own / provided at onboarding — nothing is
hardcoded here; see [`docs/networking.md`](../../docs/networking.md) for the full per-path reference):

- your **Span capture ingest host** (the enrollment / egress endpoint from onboarding) — captured events go here.
- your **`AUSPEX_BASE_URL` download host** — the signed binary artifact.
- `github.com` + `objects.githubusercontent.com` — the bootstrap script asset, and (only when
  `AUSPEX_VERIFY=cosign`) the pinned cosign/jq CLIs. Use `AUSPEX_VERIFY=checksum` to drop the cosign egress
  (SHA-256 integrity only).
- `raw.githubusercontent.com` — only for the **team-level** path (Option A), which fetches this recipe's
  scripts. The per-repository path (Option B) commits them, so it doesn't need this host.

## Verification

Inside the running agent:

```bash
auspex status --verbose --check-token   # daemon up · placement · token valid · single tier · delivery
bash .cursor/preflight.sh               # + the two cloud-env facts: token injected, email resolved
```

A healthy setup shows the daemon reachable, `capture_wiring` passing, `token_validity` OK, and a single
placement tier (no double-capture).

## How it works

- **Signed install.** `install.sh` pipes the release's `auspex-install.sh` bootstrap, which fetches the
  pinned binary from `AUSPEX_BASE_URL` and **cosign-verifies it against an offline embedded trust root
  before execution** — a tampered/unsigned/wrong-version artifact fails closed (no capture wired). A custom
  image (Dockerfile variant) bakes this at build so the run-phase skips the download.
- **Single hook tier (no double-capture).** `install.sh` prefers the **system** tier
  (`/etc/cursor/hooks.json`, via `sudo`) and falls back to the **user** tier (`~/.cursor/hooks.json`) when
  `sudo` is unavailable — never both. auspex's placement marker guard refuses a conflicting second tier, so
  events are captured exactly once.
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
