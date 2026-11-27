<#
.SYNOPSIS
  auspex MDM verify-before-install gate (Windows / Intune .msi) - verify fail-closed, then let the wrapper install.

.DESCRIPTION
  TEMPLATE: the trust material (identity regex, OIDC issuer, cosign version + windows digest, and the
  embedded Sigstore trusted_root.json) is INJECTED from src/span-auspex/verify-lib.sh by bootstrap/assemble.sh
  - verify-lib.sh stays the single source of truth (SSOT) for the pins; this file is not runnable until
  assembled into dist/auspex-verify-gate.ps1. PowerShell cannot share the bash verify recipe, so this is the
  Windows-native equivalent of verify_cosign_bundle (cross-language duplication is unavoidable; the reconcile
  guard checks verify-lib.sh, the SSOT the assembler injects from).

  Verifies a staged (or fetched) .msi + its per-artifact cosign bundle against the pinned release identity
  and EXITS NON-ZERO on any failure, so the Intune install command (chained `; if ($LASTEXITCODE)... ` or a
  requirement script) never installs an unverified/tampered package. It does NOT run msiexec itself - the
  wrapper does, only on exit 0 (see mdm/README.md). Post-trust: with a pre-provisioned pinned cosign on the
  runner, verify needs no Fulcio/Rekor/TUF/GitHub egress (CDN-only to fetch, or fully offline if staged).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File auspex-verify-gate.ps1 -Installer C:\Windows\Temp\auspex.msi
  if ($LASTEXITCODE -eq 0) { Start-Process msiexec.exe -ArgumentList '/i','C:\Windows\Temp\auspex.msi','/qn' -Wait }

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File auspex-verify-gate.ps1 -BaseUrl https://<cdn> -Version v1.2.3 -OutDir C:\Windows\Temp
  Downloads release v1.2.3's .msi for this device's CPU (or -Arch amd64|arm64) under its published file name, and
  accepts it only if it carries that release's own signature. With no -Out or -OutDir it saves to the current
  directory.
#>
[CmdletBinding()]
param(
  [string]$Installer,
  [string]$Url,
  [string]$Version,
  [string]$BaseUrl = $env:AUSPEX_BASE_URL,
  [string]$Arch,
  [string]$Out,
  [string]$OutDir,
  [string]$Bundle,
  [ValidateSet('cosign', 'none')]
  [string]$Verify = 'cosign',
  [string]$CosignBaseUrl = $(if ($env:AUSPEX_COSIGN_BASE_URL) { $env:AUSPEX_COSIGN_BASE_URL } else { 'https://github.com/sigstore/cosign/releases/download' })
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

# --- trust material (INJECTED from verify-lib.sh by assemble.sh) -----------------------------------------
$CosignIdentityRe = '@@AUSPEX_IDENTITY_RE@@'
$CosignOidcIssuer = '@@AUSPEX_OIDC_ISSUER@@'
$CosignVersion    = '@@AUSPEX_COSIGN_VERSION@@'
$CosignWinSha256  = '@@AUSPEX_COSIGN_WINDOWS_AMD64_SHA@@'
$TrustedRootB64   = '@@AUSPEX_TRUSTED_ROOT_B64@@'

# Fail removes an unverified download and exits with $code. It writes to stderr directly: Write-Error under 'Stop'
# would throw, and the script would exit 1 instead of the documented code.
$script:Partial = $null
function Fail([string]$msg, [int]$code = 1) {
  if ($script:Partial -and (Test-Path -LiteralPath $script:Partial)) { Remove-Item -LiteralPath $script:Partial -Force }
  [Console]::Error.WriteLine("auspex mdm-gate: $msg")
  exit $code
}

function Assert-Https([string]$u) {
  if ($u -notmatch '^https://') { Fail "refusing to fetch over non-https URL: $u" 16 }
}

function Fetch([string]$u, [string]$out) {
  Assert-Https $u
  try {
    Invoke-WebRequest -Uri $u -OutFile $out -UseBasicParsing -MaximumRedirection 5
  } catch {
    Fail "failed to download $u : $($_.Exception.Message)" 11
  }
}

function Get-Sha256Hex([string]$path) {
  (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLower()
}

# A 32-bit PowerShell on 64-bit Windows, such as Intune's default script host, reports x86 in PROCESSOR_ARCHITECTURE
# and the real CPU in PROCESSOR_ARCHITEW6432.
function Get-DeviceCpu {
  if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
}

$script:CosignBin = $null
function Ensure-Cosign {
  $existing = Get-Command cosign -ErrorAction SilentlyContinue
  if ($existing) { $script:CosignBin = $existing.Source; return }
  $arch = Get-DeviceCpu
  if ($arch -ne 'AMD64') {
    Fail "cosign auto-provisioning is pinned for windows/amd64; on '$arch' bake cosign into the runner image" 16
  }
  $u = "$CosignBaseUrl/$CosignVersion/cosign-windows-amd64.exe"
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ("cosign-" + [guid]::NewGuid().ToString() + ".exe")
  Fetch $u $tmp
  $got = Get-Sha256Hex $tmp
  if ($got -ne $CosignWinSha256.ToLower()) {
    Remove-Item -LiteralPath $tmp -Force
    Fail "pinned cosign SHA-256 mismatch (expected $CosignWinSha256, got $got) - refusing to use a tampered cosign" 15
  }
  $script:CosignBin = $tmp
}

# Invoke-Cosign runs cosign quietly, leaving its exit code in $LASTEXITCODE. cosign reports on stderr even when it
# passes, which Windows PowerShell 5.1 turns into a terminating error under 'Stop', so it runs under 'Continue'.
function Invoke-Cosign {
  $ErrorActionPreference = 'Continue'
  & $script:CosignBin @args *> $null
}

function Write-TrustedRoot {
  $path = Join-Path ([IO.Path]::GetTempPath()) ("auspex-trusted-root-" + [guid]::NewGuid().ToString() + ".json")
  [IO.File]::WriteAllBytes($path, [Convert]::FromBase64String($TrustedRootB64))
  return $path
}

# Provenance check for a .msi carrying its OWN per-artifact cosign bundle (auspex ADR 0033 section 9): the
# signature is directly over the artifact bytes (no checksums.txt indirection).
function Verify-CosignBundle([string]$file, [string]$bundleSrc) {
  Ensure-Cosign
  $rootPath = Write-TrustedRoot
  $tmpBundle = $null
  if ($bundleSrc -match '^https?://') {
    $tmpBundle = New-TemporaryFile
    Fetch $bundleSrc $tmpBundle.FullName
    $bundlePath = $tmpBundle.FullName
  } elseif (Test-Path -LiteralPath $bundleSrc) {
    $bundlePath = $bundleSrc
  } else {
    Remove-Item -LiteralPath $rootPath -Force
    Fail "cosign bundle not found at $bundleSrc - refusing to install" 11
  }
  Invoke-Cosign verify-blob `
    --bundle $bundlePath `
    --trusted-root $rootPath `
    --certificate-identity-regexp $CosignIdentityRe `
    --certificate-oidc-issuer $CosignOidcIssuer `
    $file
  $rc = $LASTEXITCODE
  if ($tmpBundle) { Remove-Item -LiteralPath $tmpBundle.FullName -Force }
  Remove-Item -LiteralPath $rootPath -Force
  if ($rc -ne 0) {
    Fail "cosign FAILED to verify $file against the pinned release identity - refusing to install" 13
  }
  Write-Host "auspex mdm-gate: cosign-verified ($file signature valid for the pinned release identity)"
}

# --- resolve installer (fetch if -Url or -Version) --------------------------------------------------------
$sources = @($Installer, $Url, $Version | Where-Object { $_ }).Count
if ($sources -gt 1) { Fail "pass one of -Installer, -Url or -Version, not several" 2 }
if ($sources -eq 0) { Fail "one of -Installer <path>, -Url <url> or -Version <tag> is required" 2 }
if ($Out -and $OutDir) { Fail "pass -Out OR -OutDir, not both" 2 }
if ($Out -and (Test-Path -LiteralPath $Out -PathType Container)) { Fail "-Out $Out is a directory - pass -OutDir to save in it" 2 }
if ($Installer -and ($Out -or $OutDir)) { Fail "-Out and -OutDir apply to a download, not to -Installer" 2 }
if ($Arch -and -not $Version) { Fail "-Arch picks the installer for -Version" 2 }

if ($Version) {
  if (-not $Version.StartsWith('v')) { $Version = "v$Version" }
  if ($Version -cnotmatch '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$') {
    Fail "-Version must be a release tag such as v1.2.3 (got '$Version')" 2
  }
  if (-not $BaseUrl) {
    Fail "-Version needs your auspex download host - pass -BaseUrl <url> (from your install instructions) or set AUSPEX_BASE_URL" 2
  }
  if (-not $Arch) {
    # Off Windows, such as an admin fetching the .msi to upload, there is no device CPU to match: default to amd64.
    $Arch = switch (Get-DeviceCpu) { 'ARM64' { 'arm64' } default { 'amd64' } }
  }
  if ($Arch -cnotin @('amd64', 'arm64')) { Fail "-Arch must be amd64 or arm64 (got '$Arch')" 2 }
  $Url = "$($BaseUrl.TrimEnd('/'))/releases/$Version/windows/auspex_$($Version.Substring(1))_windows_$Arch.msi"
  # Pin the signer to this tag's, or a genuine older .msi served at this release's URL would verify.
  $CosignIdentityRe = ($CosignIdentityRe -replace '@refs/tags/.*$', '') + '@refs/tags/' + $Version.Replace('.', '\.') + '$'
  if (-not $Out -and -not $OutDir) { $OutDir = (Get-Location).Path }
}
if ($OutDir) { $Out = Join-Path $OutDir ($Url -replace '^.*/', '') }

# A download to -Out lands beside it and replaces it only once verified, so a failed run keeps a good copy.
$fetched = $false
if ($Url) {
  if ($Out) {
    $outParent = Split-Path -Parent $Out
    if ($outParent -and -not (Test-Path -LiteralPath $outParent -PathType Container)) { Fail "cannot write beside $Out" 16 }
    $Installer = "$Out.partial." + [guid]::NewGuid().ToString('N').Substring(0, 8)
  } else {
    $Installer = (New-TemporaryFile).FullName
  }
  $script:Partial = $Installer
  Write-Host "auspex mdm-gate: downloading $Url"
  Fetch $Url $Installer
  $fetched = $true
  if (-not $Bundle) { $Bundle = "$Url.cosign.bundle" }
} else {
  if (-not (Test-Path -LiteralPath $Installer)) { Fail "installer not found at $Installer" 11 }
  if (-not $Bundle) { $Bundle = "$Installer.cosign.bundle" }
}

try {
  switch ($Verify) {
    'none'   { Write-Warning "auspex mdm-gate: -Verify none - NOT verifying provenance (not recommended)" }
    'cosign' { Verify-CosignBundle $Installer $Bundle }
  }
} catch {
  if ($fetched -and (Test-Path -LiteralPath $Installer)) { Remove-Item -LiteralPath $Installer -Force }
  throw
}

if ($Url -and $Out) {
  try { Move-Item -LiteralPath $Installer -Destination $Out -Force }
  catch { Fail "cannot replace $Out : $($_.Exception.Message)" 16 }
  $Installer = (Get-Item -LiteralPath $Out).FullName # absolute, for MDM logs
}
$script:Partial = $null
Write-Host "auspex mdm-gate: VERIFIED - safe to install: $Installer"
