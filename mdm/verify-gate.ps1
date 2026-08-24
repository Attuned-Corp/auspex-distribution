<#
.SYNOPSIS
  auspex MDM verify-before-install gate (Windows / Intune .msi) — verify fail-closed, then let the wrapper install.

.DESCRIPTION
  TEMPLATE: the trust material (identity regex, OIDC issuer, cosign version + windows digest, and the
  embedded Sigstore trusted_root.json) is INJECTED from src/span-auspex/verify-lib.sh by bootstrap/assemble.sh
  — verify-lib.sh stays the single source of truth (SSOT) for the pins; this file is not runnable until
  assembled into dist/auspex-verify-gate.ps1. PowerShell cannot share the bash verify recipe, so this is the
  Windows-native equivalent of verify_cosign_bundle (cross-language duplication is unavoidable; the reconcile
  guard checks verify-lib.sh, the SSOT the assembler injects from).

  Verifies a staged (or fetched) .msi + its per-artifact cosign bundle against the pinned release identity
  and EXITS NON-ZERO on any failure, so the Intune install command (chained `; if ($LASTEXITCODE)… ` or a
  requirement script) never installs an unverified/tampered package. It does NOT run msiexec itself — the
  wrapper does, only on exit 0 (see mdm/README.md). Post-trust: with a pre-provisioned pinned cosign on the
  runner, verify needs no Fulcio/Rekor/TUF/GitHub egress (CDN-only to fetch, or fully offline if staged).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File auspex-verify-gate.ps1 -Installer C:\Windows\Temp\auspex.msi
  if ($LASTEXITCODE -eq 0) { Start-Process msiexec.exe -ArgumentList '/i','C:\Windows\Temp\auspex.msi','/qn' -Wait }
#>
[CmdletBinding()]
param(
  [string]$Installer,
  [string]$Url,
  [string]$Out,
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

function Fail([string]$msg, [int]$code = 1) {
  Write-Error "auspex mdm-gate: $msg"
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

$script:CosignBin = $null
function Ensure-Cosign {
  $existing = Get-Command cosign -ErrorAction SilentlyContinue
  if ($existing) { $script:CosignBin = $existing.Source; return }
  $arch = $env:PROCESSOR_ARCHITECTURE
  if ($arch -ne 'AMD64') {
    Fail "cosign auto-provisioning is pinned for windows/amd64; on '$arch' bake cosign into the runner image" 16
  }
  $u = "$CosignBaseUrl/$CosignVersion/cosign-windows-amd64.exe"
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ("cosign-" + [guid]::NewGuid().ToString() + ".exe")
  Fetch $u $tmp
  $got = Get-Sha256Hex $tmp
  if ($got -ne $CosignWinSha256.ToLower()) {
    Remove-Item -LiteralPath $tmp -Force
    Fail "pinned cosign SHA-256 mismatch (expected $CosignWinSha256, got $got) — refusing to use a tampered cosign" 15
  }
  $script:CosignBin = $tmp
}

function Write-TrustedRoot {
  $path = Join-Path ([IO.Path]::GetTempPath()) ("auspex-trusted-root-" + [guid]::NewGuid().ToString() + ".json")
  [IO.File]::WriteAllBytes($path, [Convert]::FromBase64String($TrustedRootB64))
  return $path
}

# Provenance check for a .msi carrying its OWN per-artifact cosign bundle (auspex ADR 0033 §9): the
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
    Fail "cosign bundle not found at $bundleSrc — refusing to install" 11
  }
  & $script:CosignBin verify-blob `
    --bundle $bundlePath `
    --trusted-root $rootPath `
    --certificate-identity-regexp $CosignIdentityRe `
    --certificate-oidc-issuer $CosignOidcIssuer `
    $file *> $null
  $rc = $LASTEXITCODE
  if ($tmpBundle) { Remove-Item -LiteralPath $tmpBundle.FullName -Force }
  Remove-Item -LiteralPath $rootPath -Force
  if ($rc -ne 0) {
    Fail "cosign FAILED to verify $file against the pinned release identity — refusing to install" 13
  }
  Write-Host "auspex mdm-gate: cosign-verified ($file signature valid for the pinned release identity)"
}

# --- resolve installer (fetch if -Url) -------------------------------------------------------------------
if ($Installer -and $Url) { Fail "pass -Installer OR -Url, not both" 2 }
if (-not $Installer -and -not $Url) { Fail "one of -Installer <path> or -Url <url> is required" 2 }

$fetched = $false
if ($Url) {
  if (-not $Out) { $Out = (New-TemporaryFile).FullName }
  $Installer = $Out
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
    'none'   { Write-Warning "auspex mdm-gate: -Verify none — NOT verifying provenance (not recommended)" }
    'cosign' { Verify-CosignBundle $Installer $Bundle }
  }
} catch {
  if ($fetched -and (Test-Path -LiteralPath $Installer)) { Remove-Item -LiteralPath $Installer -Force }
  throw
}

Write-Host "auspex mdm-gate: VERIFIED — safe to install: $Installer"
