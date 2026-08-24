<#
.SYNOPSIS
  auspex Windows installer (irm | iex) — fetch + fail-closed verify + place on PATH.

.DESCRIPTION
  TEMPLATE: the trust material (identity regex, OIDC issuer, cosign version + windows digest, and the
  embedded Sigstore trusted_root.json) is INJECTED from src/span-auspex/verify-lib.sh by bootstrap/assemble.sh
  — verify-lib.sh stays the single source of truth (SSOT) for the pins; this file is not runnable until
  assembled into dist/auspex-install.ps1. PowerShell cannot share the bash verify recipe, so this is the
  Windows-native equivalent of verify_cosign / verify_sha256 (cross-language duplication is unavoidable;
  the reconcile guard checks verify-lib.sh, the SSOT the assembler injects from).

  Served from this repo's GitHub Releases (origin #2); the artifact comes from the CDN (origin #1). The
  script's own bytes are trusted via TLS + origin (a piped script can't verify itself); it verifies the
  DOWNLOADED binary fail-closed.

.EXAMPLE
  irm https://<release-asset-url>/auspex-install.ps1 | iex
  # or, with arguments:
  & ([scriptblock]::Create((irm https://<release-asset-url>/auspex-install.ps1))) -Version v0.1.0
#>
[CmdletBinding()]
param(
  [string]$Version = $env:AUSPEX_VERSION,
  [ValidateSet('cosign', 'checksum', 'none')]
  [string]$Verify = $(if ($env:AUSPEX_VERIFY) { $env:AUSPEX_VERIFY } else { 'cosign' }),
  [string]$BaseUrl = $env:AUSPEX_BASE_URL,   # REQUIRED unless -Url: no baked default (host-agnostic public repo)
  [string]$Url = $env:AUSPEX_BINARY_URL,
  [string]$BinDir = $env:AUSPEX_BIN_DIR,
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
  Write-Error "auspex install: $msg"
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

function Verify-Checksum([string]$file, [string]$u) {
  $sumTmp = New-TemporaryFile
  Fetch "$u.sha256" $sumTmp.FullName
  $expected = ((Get-Content -LiteralPath $sumTmp.FullName -First 1) -split '\s+')[0].ToLower()
  Remove-Item -LiteralPath $sumTmp.FullName -Force
  $got = Get-Sha256Hex $file
  if (-not $expected -or $expected -ne $got) {
    Fail "SHA-256 mismatch for $u (expected '$expected', got '$got') — refusing to install" 12
  }
  Write-Host "auspex install: SHA-256 verified ($got)"
}

$script:CosignBin = $null
function Ensure-Cosign {
  $existing = Get-Command cosign -ErrorAction SilentlyContinue
  if ($existing) { $script:CosignBin = $existing.Source; return }
  $arch = $env:PROCESSOR_ARCHITECTURE
  if ($arch -ne 'AMD64') {
    Fail "cosign auto-provisioning is pinned for windows/amd64; on '$arch' install cosign yourself (it will be used) or use -Verify checksum" 16
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

function Verify-Cosign([string]$file, [string]$u) {
  Ensure-Cosign
  $rootPath = Write-TrustedRoot
  # version root = dirname^3 of .../releases/<v>/<os>/<arch>/auspex.exe
  $verRoot = ($u -replace '/[^/]+/[^/]+/[^/]+$', '')
  $checks = New-TemporaryFile
  $bundle = New-TemporaryFile
  Fetch "$verRoot/checksums.txt" $checks.FullName
  Fetch "$verRoot/checksums.txt.cosign.bundle" $bundle.FullName
  & $script:CosignBin verify-blob `
    --bundle $bundle.FullName `
    --trusted-root $rootPath `
    --certificate-identity-regexp $CosignIdentityRe `
    --certificate-oidc-issuer $CosignOidcIssuer `
    $checks.FullName *> $null
  $rc = $LASTEXITCODE
  if ($rc -ne 0) {
    Remove-Item -LiteralPath $checks.FullName, $bundle.FullName, $rootPath -Force
    Fail "cosign FAILED to verify $verRoot/checksums.txt against the pinned release identity — refusing to install" 13
  }
  $got = Get-Sha256Hex $file
  $present = Select-String -LiteralPath $checks.FullName -SimpleMatch -Pattern $got -Quiet
  Remove-Item -LiteralPath $checks.FullName, $bundle.FullName, $rootPath -Force
  if (-not $present) {
    Fail "the binary's digest $got is not present in the cosign-verified checksums.txt — refusing to install" 14
  }
  Write-Host "auspex install: cosign-verified (checksums.txt signed by the release workflow; binary digest present)"
}

# --- derive URL ------------------------------------------------------------------------------------------
if (-not $Url) {
  if (-not $BaseUrl) { Fail "no artifact source — pass -BaseUrl <url> (your auspex distribution host; see your install instructions) or -Url <full-url>, or set AUSPEX_BASE_URL" 2 }
  if (-not $Version) { Fail "-Version is required (there is no 'latest' alias on the download host) — e.g. -Version v0.1.0" 2 }
  $arch = switch ($env:PROCESSOR_ARCHITECTURE) {
    'AMD64' { 'amd64' }
    'ARM64' { 'arm64' }
    default { Fail "unsupported CPU '$($env:PROCESSOR_ARCHITECTURE)'" 16 }
  }
  $Url = "$($BaseUrl.TrimEnd('/'))/releases/$Version/windows/$arch/auspex.exe"
}

# --- install dir -----------------------------------------------------------------------------------------
if (-not $BinDir) { $BinDir = Join-Path $env:LOCALAPPDATA 'auspex\bin' }
New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
$binDest = Join-Path $BinDir 'auspex.exe'

# --- fetch -> verify (fail-closed) -> place --------------------------------------------------------------
Write-Host "auspex install: downloading $Url"
$dlTmp = New-TemporaryFile
try {
  Fetch $Url $dlTmp.FullName
  switch ($Verify) {
    'none'     { Write-Warning "auspex install: -Verify none — installing WITHOUT verification (not recommended)" }
    'checksum' { Verify-Checksum $dlTmp.FullName $Url }
    'cosign'   { Verify-Checksum $dlTmp.FullName $Url; Verify-Cosign $dlTmp.FullName $Url }
  }
  Move-Item -LiteralPath $dlTmp.FullName -Destination $binDest -Force
} finally {
  if (Test-Path -LiteralPath $dlTmp.FullName) { Remove-Item -LiteralPath $dlTmp.FullName -Force }
}

Write-Host "auspex install: installed $binDest"
if (($env:PATH -split ';') -notcontains $BinDir) {
  Write-Host "auspex install: note — $BinDir is not on your PATH; add it (setx PATH \"$BinDir;%PATH%\") and reopen your shell"
}
