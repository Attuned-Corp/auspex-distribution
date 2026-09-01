# auspex — Claude Code cloud agent capture

> ⚠️ **EXPERIMENTAL — not yet supported for production.** The capture path is proven end-to-end, but Claude
> cloud environments inject **no session secrets**, and the only way this recipe currently gets the org token
> in is by placing `AUSPEX_CLOUD_TOKEN` **inline in the setup-script config** — which is **not an acceptable
> production posture** (hard-coding the token in the environment config, or committing it to the repo, both
> expose an org credential). We are **not advertising Claude cloud support** until a secure token-provisioning
> mechanism is decided (see the workspace `DECISIONS.md` "Claude cloud capture — token provisioning"). Treat
> this directory as a working reference for the *capture* mechanics, not an install guide.

Capture coding-agent activity (shell / file / tool events + token usage) from **Claude Code cloud agents** —
the Anthropic-hosted Linux VMs behind *Claude Code on the web*, `claude --cloud`, the Claude tag, and routines
— and send it to Span, attributed to the human who dispatched the agent.

This recipe installs auspex on the agent VM at environment setup, wires **one** Claude hook tier (the
**managed** tier), **provisions the org token into auspex's identity file at setup**, launches the supervised
daemon from a **`SessionStart` hook**, and enrolls with Span.

> **Claude cloud injects no session secrets.** The setup-script config is the only config surface, so the org
> token is supplied *inline* there and written into auspex's identity file at setup — the in-session daemon
> enrolls from that file, no session secret required. Work-email attribution prefers Claude's per-session
> **`CLAUDE_CODE_USER_EMAIL`** (then git identity), falling back to a baked value.

> No auspex code change is involved — this recipe only composes shipped auspex commands (`auth set`,
> `hooks install`, `daemon --supervise`, `status`) with Claude's environment + hook lifecycle. Token usage,
> turn enrichment, and sub-agent metrics ride along for free via auspex's built-in session-log tailer once the
> daemon runs.

## Why the run phase is a hook (the one thing that differs from a laptop)

Claude cloud exposes only a **build-time setup script**, which runs *before* the session — it can't start a
long-lived daemon that survives into the session. So the recipe splits the work:

- **Setup script** (`claude-cloud-install.sh`, runs as root at environment build): fetch + verify the signed
  binary, place the managed hook tier, **provision the org token** (`auspex auth set`, from the inline
  `AUSPEX_CLOUD_TOKEN`), and wire a **`SessionStart` daemon-launch hook**.
- **`SessionStart` hook** (`claude-cloud-session-start.sh`, runs in-session): resolves the work email
  (`CLAUDE_CODE_USER_EMAIL` → git identity → baked fallback), records it with `auspex auth set --email`, then
  launches `auspex daemon --supervise`, which enrolls **from the provisioned identity file**. Claude runs
  `command` hooks under `/bin/sh`, so the launcher is POSIX-`sh`-safe.

## What's here

This directory holds the **consumer example** — what you paste into your Claude cloud environment. The
executable recipe itself lives in [`claude-cloud/`](../../claude-cloud/) and is **cosign-signed and published
as GitHub Release assets**, so setup fetches it from an immutable, signed URL.

| File | Role |
|---|---|
| `setup.sh` | The environment **setup script** to paste — a download-then-run (`curl -o` + `bash`) of the signed installer. |

| Published asset (from `claude-cloud/`) | Role |
|---|---|
| `claude-cloud-install.sh` | Setup phase: fetch + verify the signed binary, place one hook tier (`auspex hooks install --system`), **provision the org token** (`auspex auth set`), wire the `SessionStart` daemon-launch hook, stage its launcher. |
| `claude-cloud-session-start.sh` | Run phase: resolve the work email (`CLAUDE_CODE_USER_EMAIL` → git identity → baked fallback) via `auspex auth set --email`, launch the supervised daemon (which enrolls from the identity file). POSIX-`sh`. |
| `claude-cloud-preflight.sh` | Optional in-agent check of the resolved identity (`auspex auth show`) + shipped health report. |

## Install

### Step 1 — set the environment setup script

Claude cloud injects **no session secrets**, so all config is supplied **inline** in the setup script (the only
config surface). Set your environment's **setup script** to export the config, then fetch + run the signed
installer:

```bash
export AUSPEX_BASE_URL="https://<your-auspex-download-host>"
export AUSPEX_CLOUD_TOKEN="span_…"                  # org token — provisioned into the identity file at setup
curl -fsSL https://github.com/Attuned-Corp/auspex-distribution/releases/latest/download/claude-cloud-install.sh -o /tmp/claude-cloud-install.sh && bash /tmp/claude-cloud-install.sh
```

> **Download-then-run, not `curl … | bash`.** Piping the installer to `bash` over stdin ties the script's stdin
> to the pipe, so anything it (or a child process) reads from stdin swallows the rest of the script. Fetch to a
> temp file first, then run it (the same pattern the Cursor recipe uses).

`latest/download` tracks the newest non-prerelease release; pin a specific tag
(`.../releases/download/<tag>/claude-cloud-install.sh`) for a reproducible setup. The asset is cosign-signed
(a `.cosign.bundle` accompanies it) — see [Verifying the recipe](#verifying-the-recipe) to check it first.

### Step 2 — inline configuration

The setup script reads these from its environment (export them, as above — there are no session secrets):

| Name | Required | Value |
|---|---|---|
| `AUSPEX_BASE_URL` | yes | your auspex download host / mirror (provided at onboarding), e.g. `https://<your-auspex-download-host>` |
| `AUSPEX_CLOUD_TOKEN` | yes | your Span org auth token — **provisioned into the identity file at setup** (`auspex auth set`); the in-session daemon enrolls from it |
| `AUSPEX_CLOUD_WORK_EMAIL` | optional | baked attribution fallback; the `SessionStart` launcher **prefers Claude's per-session `CLAUDE_CODE_USER_EMAIL`** (then git identity) |
| `AUSPEX_VERSION` | optional | pin a signed release tag; **unset installs the latest** |
| `AUSPEX_VERIFY` | optional | `cosign` (default) · `checksum` · `none` |

- All values are read at **setup** (build time). The token is written into auspex's identity file there; nothing
  needs to be visible in-session.
- Work email: the launcher prefers Claude's per-session `CLAUDE_CODE_USER_EMAIL` (the dispatching human), then
  the dispatcher's `git config user.email`, then the baked `AUSPEX_CLOUD_WORK_EMAIL`. Every tier is guarded —
  an unset one is skipped.
- Without any resolved work email, capture still runs — events are just **unattributed**.

> **Posture note.** Because there are no session secrets, the org token lives in the environment's
> setup-script config (admin-controlled). Treat that config as sensitive; rotate the org token if it leaks.

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
auspex auth show                        # token: set (source: user) · work_email attributed
auspex status --verbose --check-token   # daemon up · placement · token valid · single tier · delivery
# or the bundled preflight (resolved identity + the health report above):
curl -fsSL https://github.com/Attuned-Corp/auspex-distribution/releases/latest/download/claude-cloud-preflight.sh -o /tmp/claude-cloud-preflight.sh && bash /tmp/claude-cloud-preflight.sh
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
- **Token provisioned at setup (no session secret).** Claude cloud injects no secrets, so `install.sh`
  provisions the inline `AUSPEX_CLOUD_TOKEN` into auspex's identity file with `auspex auth set` (targeting
  root's home, where the session daemon reads it). The daemon resolves identity `env > managed > user`, so the
  provisioned **user tier** enrolls it — nothing is read from the session environment.
- **Daemon launches from a `SessionStart` hook.** The setup script can't keep a daemon alive into the session,
  so it drops a *separate* own-file (`auspex-daemon.json`) into `managed-settings.d/` whose `SessionStart`
  `command` runs the staged launcher. Claude merges every `*.json` there (concatenate + de-dup), so auspex's
  capture hooks and the daemon-launch hook both fire; the launcher supervises `auspex daemon`, which enrolls
  from the provisioned identity file. It's idempotent — a reachable daemon means it does nothing.
- **Attribution: `CLAUDE_CODE_USER_EMAIL` → git identity → baked fallback.** The launcher resolves the work
  email from Claude's per-session `CLAUDE_CODE_USER_EMAIL` (the dispatching human), then the dispatcher's `git
  config user.email`, records it with `auspex auth set --email` (preserve-on-omit, so the token stays), and
  falls back to the setup-baked email; every tier is guarded and absence is non-fatal (capture continues,
  unattributed).
- **Token usage / turn enrichment / sub-agent metrics** are sourced by auspex's built-in session-log tailer
  from the Claude transcript once the daemon runs — no extra recipe wiring.

## Limitations

- **Teardown:** a burst of events in the final moments before the VM is torn down may not flush.
- **Owner-scoped attribution:** the resolved email is the dispatching human (`CLAUDE_CODE_USER_EMAIL` / git
  identity / baked fallback), so a multi-person agent attributes to that identity.
- **Token in setup config:** with no session secrets, the org token lives in the environment's setup-script
  config — treat it as sensitive and rotate on leak.
