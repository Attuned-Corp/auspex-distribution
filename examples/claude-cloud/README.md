# auspex — Claude Code cloud agent capture

Capture coding-agent activity (shell / file / tool events + token usage) from **Claude Code cloud agents** —
the Anthropic-hosted Linux VMs behind *Claude Code on the web*, `claude --cloud`, the Claude tag, and routines
— and send it to Span, attributed to the human who dispatched the agent.

This recipe installs auspex on the agent VM at environment setup, wires **one** Claude hook tier (the
**managed** tier), launches the supervised daemon from a **`SessionStart` hook**, and enrolls with Span. It
needs **one secret** (a team/session-scoped org token) plus an **injected work email** for attribution
(Claude has no metadata socket to auto-discover it).

> No auspex code change is involved — this recipe only composes shipped auspex commands (`hooks install`,
> `daemon --supervise`, `status`) with Claude's environment + hook lifecycle. Token usage, turn enrichment,
> and sub-agent metrics ride along for free via auspex's built-in session-log tailer once the daemon runs.

## Why the run phase is a hook (the one thing that differs from a laptop)

Claude cloud exposes only a **build-time setup script**, which runs *before* the session and therefore
**cannot read the session-injected `AUSPEX_CLOUD_TOKEN`**. So the recipe splits the work:

- **Setup script** (`claude-cloud-install.sh`, runs as root at environment build): fetch + verify the signed
  binary, place the managed hook tier, and wire a **`SessionStart` daemon-launch hook**.
- **`SessionStart` hook** (`claude-cloud-session-start.sh`, runs in-session): reads the injected token + work
  email and launches `auspex daemon --supervise`, which enrolls. Claude runs `command` hooks under `/bin/sh`,
  so the launcher is POSIX-`sh`-safe.

## What's here

This directory holds the **consumer example** — what you paste into your Claude cloud environment. The
executable recipe itself lives in [`claude-cloud/`](../../claude-cloud/) and is **cosign-signed and published
as GitHub Release assets**, so setup fetches it from an immutable, signed URL.

| File | Role |
|---|---|
| `setup.sh` | The environment **setup script** to paste — one `curl \| bash` of the signed installer. |

| Published asset (from `claude-cloud/`) | Role |
|---|---|
| `claude-cloud-install.sh` | Setup phase: fetch + verify the signed binary, place one hook tier (`auspex hooks install --system`), wire the `SessionStart` daemon-launch hook, stage its launcher. |
| `claude-cloud-session-start.sh` | Run phase: resolve the injected work email, launch the supervised daemon (which enrolls). POSIX-`sh`. |
| `claude-cloud-preflight.sh` | Optional in-agent check for the two cloud-env facts `auspex status` can't see. |

## Install

### Step 1 — set the environment setup script

In your Claude cloud environment settings, set the **setup script** to fetch + run the signed installer:

```bash
curl -fsSL https://github.com/Attuned-Corp/auspex-distribution/releases/latest/download/claude-cloud-install.sh | bash
```

`latest/download` tracks the newest non-prerelease release; pin a specific tag
(`.../releases/download/<tag>/claude-cloud-install.sh`) for a reproducible setup. The asset is cosign-signed
(a `.cosign.bundle` accompanies it) — see [Verifying the recipe](#verifying-the-recipe) to check it first.

### Step 2 — secrets

Configure these as **team/environment secrets** (the token is one org-wide credential):

| Name | Scope | Value |
|---|---|---|
| `AUSPEX_CLOUD_TOKEN` | Team / session | your Span org auth token — read **in-session** by the `SessionStart` launcher to enroll |
| `AUSPEX_CLOUD_WORK_EMAIL` | Session | the dispatching engineer's work email — **inject it**; Claude has no metadata socket to auto-discover it |
| `AUSPEX_BASE_URL` | Environment | your auspex download host / mirror (provided at onboarding), e.g. `https://<your-auspex-download-host>` |
| `AUSPEX_VERSION` | Environment (optional) | pin a signed release tag; **unset installs the latest** |
| `AUSPEX_VERIFY` | Environment (optional) | `cosign` (default) · `checksum` · `none` |

- `AUSPEX_BASE_URL` (± `AUSPEX_VERSION`/`AUSPEX_VERIFY`) must be visible to the **setup script** (build time).
- `AUSPEX_CLOUD_TOKEN` and `AUSPEX_CLOUD_WORK_EMAIL` must be visible **in-session** (the launcher and daemon
  read them at each `SessionStart`).
- Without `AUSPEX_CLOUD_WORK_EMAIL`, capture still runs — events are just **unattributed**.

### Step 3 — allowlist egress

Claude cloud's default **`Trusted`** network access excludes the Span ingest host, so choose **`Custom`** or
**`Full`** and allowlist (hosts are your own / provided at onboarding — see
[`docs/networking.md`](../../docs/networking.md) for the full per-path reference):

- your **Span capture ingest host** — captured events go here.
- your **`AUSPEX_BASE_URL` download host** — the signed binary artifact.
- `github.com` + `objects.githubusercontent.com` — the Release assets (the `auspex-install.sh` bootstrap and
  this recipe's `claude-cloud-*.sh` scripts, fetched at setup; downloads redirect to
  `objects.githubusercontent.com`), and — only when `AUSPEX_VERIFY=cosign` — the pinned cosign CLI. Use
  `AUSPEX_VERIFY=checksum` to drop the cosign egress (SHA-256 integrity only).

### Step 4 — launch a normal cloud session

Launch a Claude cloud agent the way you normally would; the managed hooks + `SessionStart` daemon launch are
picked up automatically — **no bespoke base image**.

## Verifying the recipe

The recipe scripts are cosign keyless-signed; each Release asset ships a `.cosign.bundle`:

```bash
base=https://github.com/Attuned-Corp/auspex-distribution/releases/latest/download
curl -fsSLO "$base/claude-cloud-install.sh"
curl -fsSLO "$base/claude-cloud-install.sh.cosign.bundle"
cosign verify-blob --bundle claude-cloud-install.sh.cosign.bundle \
  --certificate-identity-regexp '^https://github.com/Attuned-Corp/auspex-distribution' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  claude-cloud-install.sh
```

(`checksums.txt` on the Release covers all assets for a SHA-256-only check.)

## Verification (inside the running agent)

```bash
auspex status --verbose --check-token   # daemon up · placement · token valid · single tier · delivery
# + the two cloud-env facts (token injected, email resolved):
curl -fsSL https://github.com/Attuned-Corp/auspex-distribution/releases/latest/download/claude-cloud-preflight.sh | bash
```

A healthy setup shows the daemon reachable, `capture_wiring` passing, `token_validity` OK, and a single
placement tier (no double-capture).

## How it works

- **Signed recipe + signed install.** The recipe scripts are cosign-signed Release assets. At setup,
  `claude-cloud-install.sh` pipes the release's `auspex-install.sh` bootstrap (resolved from
  `releases/latest/download`, independent of the `AUSPEX_VERSION` binary tag it passes through as `--version`),
  which fetches the pinned binary from `AUSPEX_BASE_URL` and **cosign-verifies it against an offline embedded
  trust root before execution** — a tampered/unsigned/wrong-version artifact fails closed (no capture wired).
- **Single managed hook tier (no double-capture).** `install.sh` runs `auspex hooks install --system`, wiring
  the **managed** tier — auspex's own-file at `/etc/claude-code/managed-settings.d/auspex.json`, out-of-tree
  (no commit-leak) and the only tier that fires under Claude's `allowManagedHooksOnly` lockdown. It elevates
  as needed (direct when root, `sudo -E` otherwise) and only falls back to the **user** tier
  (`~/.claude/settings.json`) when it can't elevate. Never both: auspex's placement marker guard refuses a
  conflicting second tier.
- **Daemon launches from a `SessionStart` hook.** The setup script can't read the session-injected token, so
  it drops a *separate* own-file (`auspex-daemon.json`) into `managed-settings.d/` whose `SessionStart`
  `command` runs the staged launcher. Claude merges every `*.json` there (concatenate + de-dup), so auspex's
  capture hooks and the daemon-launch hook both fire; the launcher enrolls from `AUSPEX_CLOUD_TOKEN` and
  supervises. It's idempotent — a reachable daemon means it does nothing.
- **Attribution via injected email.** The launcher exports `AUSPEX_CLOUD_WORK_EMAIL` (injected — Claude has no
  metadata socket) for the daemon's enrollment; absence is non-fatal (capture continues, unattributed).
- **Token usage / turn enrichment / sub-agent metrics** are sourced by auspex's built-in session-log tailer
  from the Claude transcript once the daemon runs — no extra recipe wiring.

## Limitations

- **Teardown:** a burst of events in the final moments before the VM is torn down may not flush.
- **Owner-scoped attribution:** the injected email is the dispatching human, so a multi-person agent
  attributes to that identity.
