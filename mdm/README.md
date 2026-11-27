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
and the `curl | bash` bootstrap use — so there is a single verifier to maintain.

## The scripts

| Script | Platform | Verifies | Notes |
|---|---|---|---|
| `mdm/verify-gate.sh` | macOS / any bash runner | `.pkg` + its `.cosign.bundle` | the mechanically-tested core (`tests/install-verify-test.sh`) |
| `mdm/verify-gate.ps1` | Windows / Intune | `.msi` + its `.cosign.bundle` | PowerShell-native mirror; trust material injected at assembly |
| `mdm/scheduled-update.sh` | macOS | the channel document, then the `.pkg` + its `.cosign.bundle` | verifies **and installs** on a schedule, run by the pasted `mdm/scheduled-update-loader.sh`; see [below](#macos--keep-auspex-up-to-date-on-a-schedule) (`tests/scheduled-update-test.sh`) |
| `mdm/scheduled-update.ps1` | Windows / Intune | the channel document, then the `.msi` + its `.cosign.bundle` | the Windows twin, run by the pasted `mdm/scheduled-update-loader.ps1`; see [below](#windows--keep-auspex-up-to-date-on-a-schedule) (`tests/scheduled-update-ps1-test.ps1`) |

The two gates **verify only** — they do **not** run the native installer. The MDM recipe chains the install **after**
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

### Fetch a release by version

Pass a release tag instead of a URL, and the gate downloads that release's installer and accepts it only if it
carries that release's own signature, so a genuine older installer served at the release's URL is refused. The
host comes from `--base-url` / `-BaseUrl`, or `AUSPEX_BASE_URL`.

The verified file is saved under its published name, such as `auspex_0.1.0_darwin_universal.pkg`, in the
current directory, or in the directory `--out-dir` / `-OutDir` names. `--out` / `-Out` saves it to an exact
path instead. A download replaces an existing file only once it verifies, so a failed run keeps a good copy.
That suits an MDM that hosts packages itself: download the installer on your own machine, then upload it.
In an MDM script, always pass `--out` / `-Out`: an agent's current directory is often `/` or
`C:\Windows\System32`. The gate prints the verified file's absolute path on success.

| Script | Picks the installer with | Default |
|---|---|---|
| `auspex-verify-gate.sh` | `--os darwin` (the `.pkg`) or `--os windows --arch amd64\|arm64` (the `.msi`) | the macOS `.pkg`; `amd64` for Windows |
| `auspex-verify-gate.ps1` | `-Arch amd64\|arm64` (always the `.msi`) | the device's CPU, or `amd64` off Windows |

```bash
bash auspex-verify-gate.sh --base-url "$AUSPEX_BASE_URL" --version v0.1.0                    # the macOS .pkg
bash auspex-verify-gate.sh --base-url "$AUSPEX_BASE_URL" --version v0.1.0 --os windows --out-dir ./msi
```

## macOS — Mosyle (Custom Command)

A Mosyle **Custom Command** runs elevated (root). Verify the release `.pkg` fail-closed, then hand it to
`installer` **only** on success:

```bash
#!/bin/bash
set -euo pipefail

VER="v0.1.0"                                   # the auspex release tag to deploy
BASE="${AUSPEX_BASE_URL:?set to your auspex distribution host — see your install instructions}"
STAGE="/tmp/auspex_${VER}.pkg"
GATE="/tmp/auspex-verify-gate.sh"

# Fetch the (self-contained) gate from origin #2 — pin to a gate release tag in production.
curl -fsSL --proto '=https' --proto-redir '=https' -o "$GATE" \
  "https://github.com/Attuned-Corp/auspex-distribution/releases/latest/download/auspex-verify-gate.sh"

# Verify-before-install: the gate fetches the .pkg + its .cosign.bundle from the CDN and verifies fail-closed;
# `installer` runs ONLY if the gate exits 0. Any verify failure aborts the command (and the deploy).
bash "$GATE" --base-url "$BASE" --version "$VER" --out "$STAGE" \
  && installer -pkg "$STAGE" -target /
```

## macOS — keep auspex up to date on a schedule

`auspex-scheduled-update.sh` keeps a Mac on a release channel without approving each release. An MDM runs it
as root on a schedule, such as a Mosyle Custom Command, through a short loader. Each run:

1. verifies the signed release channel document (`releases/channels.json`) against the pinned channel
   signer, and refuses a document older than one it has already accepted (auspex ADR 0066);
2. picks the channel's release: `stable` by default, or `latest`;
3. does nothing when the installed package is that release or newer;
4. otherwise downloads that release's `.pkg`, verifies it the way the gate does but requires that release's
   own signature, and installs it with `installer`. A Mac without auspex gets its first install the same way.

Whatever release the channel names installs with no per-release approval. To approve each release, use the
gate above instead. A forged channel document can't install a build auspex didn't sign; at worst it holds a
Mac back.

Paste the loader, `auspex-scheduled-update-loader.sh` from a release (about 40 lines), into the MDM's script
field, and set the two lines at its top:

```bash
AUSPEX_BASE_URL=""      # required: your auspex download host (https://...), from your install instructions
AUSPEX_CHANNEL="stable" # stable (the default) or latest
```

Each run, the loader checks `auspex-scheduled-update.sh` against the SHA-256 the release wrote into the
loader, and runs it with those two settings. It downloads the script from the same release on GitHub only
when its cached copy in the state directory is missing or doesn't match, so GitHub is fetched about once per
Mac for each loader you paste. A script that doesn't match runs nothing, so a damaged paste or a tampered
download fails closed. To update the script, paste a newer release's loader. You can check the loader you
downloaded against its `.cosign.bundle`, as for the other release files.

Every 12 hours is often enough. A promotion to `stable` comes after a soak period, so it doesn't need to reach
a Mac within the hour, and a repeating interval still runs on a Mac that was asleep at a fixed time of day.

It keeps its state in `/Library/Application Support/auspex-update/`, a root-owned 0700 directory: the pinned
cosign and the loader's copy of the script, each hash-checked before every use, and the last channel sequence
it accepted. auspex's managed uninstall script removes it. Each run's last line of output is its result. An
MDM may not show exit codes (Mosyle shows only the output), so a failed run's last line names its code, for
example `auspex update: failed with exit 13 (exit codes: mdm/README.md)`.

| Exit | Meaning |
|---|---|
| `0` | Installed, or nothing to do: up to date, ahead of the channel, a channel that names no release, or another run in progress |
| `2` | A setting is missing or invalid |
| `11` | A download failed (the script, by the loader, or a file the script needs) |
| `12` | The downloaded script doesn't match the loader's pinned SHA-256; nothing ran |
| `13` | A signature didn't verify |
| `15` / `17` | The pinned cosign / jq couldn't be provisioned |
| `16` | Environment: not root, an unreadable package receipt, or an unsupported platform |
| `18` | The channel document is signed but malformed |
| `19` | The channel document is older than one already accepted (a replay) |
| `20` | The channel names a release this script won't install: a pre-release `stable`, or one below the minimum |
| `21` | The state directory or its sequence record isn't safe to use |
| `22` | `installer` failed |
| `23` | After the install, the package receipt doesn't name the release |

## Windows — keep auspex up to date on a schedule

`auspex-scheduled-update.ps1` is the Windows twin of the [macOS script](#macos--keep-auspex-up-to-date-on-a-schedule).
It keeps a Windows device on a release channel without approving each release. An Intune Remediation runs it as
SYSTEM on a schedule, through a short loader. Each run takes the same four steps as on macOS, with the `.msi`
for the device's CPU (amd64 or arm64) in place of the `.pkg`, installed by `msiexec /qn`. Whatever release the
channel names installs with no per-release approval.

Paste the loader, `auspex-scheduled-update-loader.ps1` from a release (about 45 lines), and set the two lines
at its top:

```powershell
$AuspexBaseUrl = ''       # required: your auspex download host (https://...), from your install instructions
$AuspexChannel = 'stable' # stable (the default) or latest
```

The loader pins `auspex-scheduled-update.ps1` by SHA-256 and caches it, as the macOS loader does. It checks the
hash on the bytes it runs, held in memory, so the script can't change between the check and the run.

### Intune Remediation

Remediations need each device's users to hold a Windows Enterprise E3 or E5, Education A3 or A5, or VDA license
([Microsoft](https://learn.microsoft.com/en-us/intune/device-management/tools/deploy-remediations)). Deploy the
identity script from the Intune guide first, so the first install picks up your organization's identity.

In **Scripts and remediations**, create a script package with these settings:

| Setting | Value |
|---|---|
| Detection script file | the loader, with your two settings |
| Remediation script file | none: the loader does the work, and a detection-only package still runs on its schedule |
| Run this script using the logged-on credentials | **No**, so it runs as SYSTEM |
| Enforce script signature check | **No**: the loader isn't Authenticode-signed; its pinned SHA-256 checks the script |
| Run script in 64-bit PowerShell | Yes (No works too) |
| Assignment schedule | **Hourly**, repeating every 12 hours, for the reason given for macOS |

Don't also assign the auspex line-of-business app as Required. Intune detects that app by its `.msi` product
code, which changes with every release. Once the script upgrades a device, expect Intune to retry the older
`.msi`, which refuses the downgrade and reports a failed install. The scheduled update does the first install
itself.

### Reading the result

Intune counts only exit 1 as an issue, so every failed run exits 1 and the device shows **With issues**. The
run's output is short, and its last line is the result, for example `auspex update: failed with code 13 (codes:
mdm/README.md)`. The codes are the [macOS ones](#macos--keep-auspex-up-to-date-on-a-schedule), with these
differences:

| Code | On Windows |
|---|---|
| `1` | An unexpected error; the line before names it |
| `16` | Also: not elevated, an unsupported CPU, or more than one auspex `.msi` installed |
| `17` | Not used: PowerShell reads the channel document without jq |
| `21` | The state folder isn't usable by SYSTEM and Administrators alone, or is a link |
| `22` | `msiexec` failed; its log is `msiexec.log` in the state folder. Exit 3010 (restart wanted) counts as installed |
| `23` | After the install, Windows Installer doesn't report the release |

It keeps its state in `C:\ProgramData\auspex-update`, created so only SYSTEM and Administrators can use it. The
script refuses a folder anyone else could have planted, so delete such a folder to start over. It holds the
pinned cosign and the loader's copy of the script, each hash-checked before every use. It also holds the last
channel sequence accepted, the tag the script last installed and the last `msiexec` log. auspex's managed
uninstall script doesn't remove this folder yet, so delete it by hand when you decommission a device.

The `.msi` drops a pre-release suffix from its version, so `v0.13.0-rc.1` installs as 0.13.0. The script
remembers the tag it installed, so on `latest` it still moves that device on to `v0.13.0`. A release candidate
installed some other way reads as its final release.

## Windows — Intune (Win32 / line-of-business wrapper)

Wrap the `.msi` install so verify runs first and `msiexec` runs only on exit 0:

```powershell
$ErrorActionPreference = 'Stop'
$Ver  = 'v0.1.0'
$Base = $env:AUSPEX_BASE_URL   # your auspex distribution host — see your install instructions
if (-not $Base) { throw 'set AUSPEX_BASE_URL to your auspex distribution host' }
$Stage = "$env:TEMP\auspex_$Ver.msi"
$Gate  = "$env:TEMP\auspex-verify-gate.ps1"

Invoke-WebRequest -UseBasicParsing -MaximumRedirection 5 `
  -Uri 'https://github.com/Attuned-Corp/auspex-distribution/releases/latest/download/auspex-verify-gate.ps1' `
  -OutFile $Gate

# -Version picks the .msi for this device's CPU (amd64 or arm64).
& powershell -ExecutionPolicy Bypass -File $Gate -BaseUrl $Base -Version $Ver -Out $Stage
if ($LASTEXITCODE -ne 0) { throw "auspex verify-gate refused the installer (rc=$LASTEXITCODE) — aborting" }
Start-Process msiexec.exe -ArgumentList '/i', "`"$Stage`"", '/qn', '/norestart' -Wait -PassThru
```

> These integration recipes are **documented, not CI-tested against a live MDM**. What CI *does* test is the
> gate's **fail-closed behavior + exit-code contract** over a tampered / identity-mismatched installer
> (`tests/install-verify-test.sh`). CI runs the Windows scheduled update end to end under Windows PowerShell
> 5.1 with only `msiexec` stubbed (`tests/scheduled-update-ps1-test.ps1`); it hasn't yet run in a live
> Intune tenant.

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
