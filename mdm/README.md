# MDM verify-before-install gate (AC7)

The managed (MDM) install paths ship a **signed OS-native package** — a macOS `.pkg` (Gatekeeper /
notarization) or a Windows `.msi` (Authenticode). Those prove **publisher authenticity**, but carry **no
build provenance** (which workflow / which tag produced the bytes) and are not checked against auspex's
cosign release signature anywhere on the fleet path. This gate closes that gap: a small **pre-install
verification step** that confirms the installer is a genuine, unmodified auspex release artifact —
cosign-verified against the **pinned release identity** — and **refuses to install on any failure**.

It adds the cosign **provenance binding** on top of the OS-native gate, bringing the managed channel to
**parity with the Dev Container Feature** (which already verifies before use). It reuses the **one shared
verify recipe** (`src/span-auspex/verify-lib.sh`) — the same pinned cosign + `trusted_root.json` the Feature
and the `curl | sh` bootstrap use — so there is a single verifier to maintain.

## The scripts

| Script | Platform | Verifies | Notes |
|---|---|---|---|
| `mdm/verify-gate.sh` | macOS / any bash runner | `.pkg` + its `.cosign.bundle` | the mechanically-tested core (`tests/install-verify-test.sh`) |
| `mdm/verify-gate.ps1` | Windows / Intune | `.msi` + its `.cosign.bundle` | PowerShell-native mirror; trust material injected at assembly |

Both **verify only** — they do **not** run the native installer. The MDM recipe chains the install **after**
a successful verify, so a non-zero exit **aborts the deploy** (fail-closed). Use the **self-contained
assembled** forms published on this repo's GitHub Releases (origin #2) — they inline the verify recipe and
embed the trust anchor, so the runner fetches one file:

- `auspex-verify-gate.sh` — `…/releases/latest/download/auspex-verify-gate.sh`
- `auspex-verify-gate.ps1` — `…/releases/latest/download/auspex-verify-gate.ps1`

> Pin to a **specific release tag** (not `latest`) in a production fleet so the gate itself is immutable.

### Exit-code contract

`0` = verified (safe to install). Non-zero = **refuse**: `2` usage · `11` fetch (installer/bundle missing)
· `13` cosign (bad signature **or** identity/issuer mismatch) · `15` cosign could not be provisioned · `16`
environment. The MDM wrapper keys on **exit 0** to proceed.

## macOS — Mosyle (Custom Command)

A Mosyle **Custom Command** runs elevated (root). Verify the release `.pkg` fail-closed, then hand it to
`installer` **only** on success:

```bash
#!/bin/bash
set -euo pipefail

VER="v0.1.0"                                   # the auspex release tag to deploy
BASE="${AUSPEX_BASE_URL:?set to your auspex distribution host — see your install instructions}"
PKG="${BASE%/}/releases/${VER}/darwin/auspex_${VER#v}_darwin_universal.pkg"
STAGE="/tmp/auspex_${VER}.pkg"
GATE="/tmp/auspex-verify-gate.sh"

# Fetch the (self-contained) gate from origin #2 — pin to a gate release tag in production.
curl -fsSL --proto '=https' --proto-redir '=https' -o "$GATE" \
  "https://github.com/Attuned-Corp/auspex-distribution/releases/latest/download/auspex-verify-gate.sh"

# Verify-before-install: the gate fetches the .pkg + its .cosign.bundle from the CDN and verifies fail-closed;
# `installer` runs ONLY if the gate exits 0. Any verify failure aborts the command (and the deploy).
bash "$GATE" --url "$PKG" --out "$STAGE" \
  && installer -pkg "$STAGE" -target /
```

## Windows — Intune (Win32 / line-of-business wrapper)

Wrap the `.msi` install so verify runs first and `msiexec` runs only on exit 0:

```powershell
$ErrorActionPreference = 'Stop'
$Ver  = 'v0.1.0'
$Base = $env:AUSPEX_BASE_URL   # your auspex distribution host — see your install instructions
if (-not $Base) { throw 'set AUSPEX_BASE_URL to your auspex distribution host' }
$Msi  = "$($Base.TrimEnd('/'))/releases/$Ver/windows/auspex_$($Ver.TrimStart('v'))_windows_amd64.msi"
$Stage = "$env:TEMP\auspex_$Ver.msi"
$Gate  = "$env:TEMP\auspex-verify-gate.ps1"

Invoke-WebRequest -UseBasicParsing -MaximumRedirection 5 `
  -Uri 'https://github.com/Attuned-Corp/auspex-distribution/releases/latest/download/auspex-verify-gate.ps1' `
  -OutFile $Gate

& powershell -ExecutionPolicy Bypass -File $Gate -Url $Msi -Out $Stage
if ($LASTEXITCODE -ne 0) { throw "auspex verify-gate refused the installer (rc=$LASTEXITCODE) — aborting" }
Start-Process msiexec.exe -ArgumentList '/i', "`"$Stage`"", '/qn', '/norestart' -Wait -PassThru
```

> These integration recipes are **documented, not CI-tested against a live MDM**. What CI *does* test is the
> gate's **fail-closed behavior + exit-code contract** over a tampered / identity-mismatched installer
> (`tests/install-verify-test.sh`).

## Fail posture

**Default = hard-fail.** A verify miss aborts the deploy — the correct posture for a security agent (never
install an installer you can't prove is genuine). The `--verify none` / `-Verify none` opt-out exists for
break-glass only and is **not recommended** for a managed fleet.

## Network access

With a **pre-provisioned pinned cosign** baked into the runner image, verify needs **only the artifact CDN**
(your auspex distribution host, from `AUSPEX_BASE_URL`) to fetch the `.pkg`/`.msi` + `.cosign.bundle` —
**zero** Fulcio / Rekor / TUF / GitHub egress at verify time (the pinned `trusted_root.json` is embedded).
If cosign is **not** pre-provisioned, the
gate auto-downloads the pinned cosign from `github.com` (verified against its pinned SHA-256 before use);
point `AUSPEX_COSIGN_BASE_URL` at an internal mirror for an air-gapped fleet. Full enumeration:
[`../docs/networking.md`](../docs/networking.md).
