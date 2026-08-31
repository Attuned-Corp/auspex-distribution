<#
.SYNOPSIS
  auspex Windows installer (irm | iex) — fetch + fail-closed verify + place on PATH.

.DESCRIPTION
  TEMPLATE: the trust material (identity regex, OIDC issuer, cosign version + windows digest, and the
  embedded Sigstore trusted_root.json) is INJECTED from src/span-auspex/verify-lib.sh by bootstrap/assemble.sh
  — verify-lib.sh stays the single source of truth (SSOT) for the pins; this file is not runnable until
  assembled into dist/auspex-install.ps1. PowerShell cannot share the bash verify recipe, so this is the
  Windows-native equivalent of the bash recipe's resolve_binary_digest / fetch_blob_by_digest / verify_sha256 (cross-language duplication is unavoidable;
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
  [string]$Digest = $env:AUSPEX_DIGEST,      # pin a raw sha256 (of the artifact) — installs the version-free blob directly
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

# Resolve the raw-binary digest for a version-path URL from the SIGNED manifest (verify: cosign — auspex
# ADR 0047), the Windows-native equivalent of verify-lib.sh's resolve_binary_digest. Fetch + cosign-verify
# the version→digest index (manifest.json), assert its version annotation matches the requested tag (closes
# the version-substitution gap), then read the unique application/octet-stream descriptor for this os/arch
# and return its bare-hex sha256. PowerShell parses the manifest with native ConvertFrom-Json — no jq.
function Resolve-BinaryDigest([string]$u) {
  Ensure-Cosign
  $rootPath = Write-TrustedRoot
  # version root = dirname^3 of .../releases/<v>/<os>/<arch>/auspex.exe; os/arch/version from the path.
  $verRoot = ($u -replace '/[^/]+/[^/]+/[^/]+$', '')
  $version = ($verRoot -split '/')[-1]
  $parts = $u -split '/'
  $arch = $parts[$parts.Length - 2]
  $os = $parts[$parts.Length - 3]
  $manifest = New-TemporaryFile
  $bundle = New-TemporaryFile
  try {
    Fetch "$verRoot/manifest.json" $manifest.FullName
    Fetch "$verRoot/manifest.json.cosign.bundle" $bundle.FullName
    & $script:CosignBin verify-blob `
      --bundle $bundle.FullName `
      --trusted-root $rootPath `
      --certificate-identity-regexp $CosignIdentityRe `
      --certificate-oidc-issuer $CosignOidcIssuer `
      $manifest.FullName *> $null
    if ($LASTEXITCODE -ne 0) {
      Fail "cosign FAILED to verify $verRoot/manifest.json against the pinned release identity — refusing to install" 13
    }
    try {
      $json = Get-Content -Raw -LiteralPath $manifest.FullName | ConvertFrom-Json
      $mver = $json.annotations.'org.opencontainers.image.version'
      $descs = @($json.manifests | Where-Object {
          $_.mediaType -eq 'application/octet-stream' -and $_.platform.os -eq $os -and $_.platform.architecture -eq $arch
        })
    } catch {
      Fail "could not parse the signed manifest $verRoot/manifest.json — refusing to install" 14
    }
    if ($mver -ne $version) {
      Fail "the signed manifest is for '$mver' but the requested path is version '$version' — refusing (version substitution)" 14
    }
    if ($descs.Count -ne 1) {
      Fail "the signed manifest has no unique raw-binary (application/octet-stream) descriptor for $os/$arch — refusing to install" 14
    }
    $digest = $descs[0].digest
    if ($digest -notmatch '^sha256:[0-9a-f]{64}$') {
      Fail "the resolved digest '$digest' is not a bare sha256 hex — refusing to install" 14
    }
    Write-Host "auspex install: resolved $version $os/$arch -> $digest (signed manifest verified)"
    return ($digest -replace '^sha256:', '')
  } finally {
    Remove-Item -LiteralPath $manifest.FullName, $bundle.FullName, $rootPath -Force -ErrorAction SilentlyContinue
  }
}

# Fetch an artifact from the global content-addressed blob namespace and SELF-VERIFY (verify: cosign — auspex
# ADR 0047): the blob lives at <base>/blobs/sha256/<digest> where <base> is everything before /releases/ in
# the version URL. sha256(bytes) must equal the digest we asked for, sealing the chain from the signed
# manifest to the installed bytes; a mismatch is a corrupt/tampered blob and fails closed.
function Fetch-BlobByDigest([string]$u, [string]$digest, [string]$out) {
  $base = ($u -replace '/releases/.*$', '')
  $blobUrl = "$base/blobs/sha256/$digest"
  Fetch $blobUrl $out
  $got = Get-Sha256Hex $out
  if ($got -ne $digest) {
    Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
    Fail "by-digest self-verify FAILED — $blobUrl hashes to $got, not $digest (corrupt or tampered blob) — refusing to install" 12
  }
  Write-Host "auspex install: by-digest verified (sha256:$got)"
}

# Pin-by-digest (auspex ADR 0047 — the version-free pin): install the artifact STRAIGHT from the global
# content-addressed blob and self-verify, bypassing the version->manifest resolution. The digest is the
# trust anchor (obtained out-of-band), so no version/manifest/cosign is consulted — the self-verify is the
# whole check and it survives a re-tag. <base> is the host root (blobs/sha256/<digest> is appended).
function Acquire-ByDigest([string]$base, [string]$digest, [string]$out) {
  $d = ($digest -replace '^sha256:', '').ToLower()
  if ($d -notmatch '^[0-9a-f]{64}$') {
    Fail "invalid pinned digest '$digest' — expected a 64-char sha256 hex (optionally 'sha256:'-prefixed)" 2
  }
  Write-Host "auspex install: pinning by digest sha256:$d (version-free; self-verify only)"
  Fetch-BlobByDigest ($base.TrimEnd('/')) $d $out
}

# --- derive source ---------------------------------------------------------------------------------------
$pinBase = $null
if ($Digest) {
  # Pin-by-digest needs only a host root (the blob is version/os/arch-free). Prefer -BaseUrl; else derive it
  # from a full -Url (everything before /releases/). No version/os/arch derivation.
  if ($BaseUrl)  { $pinBase = $BaseUrl.TrimEnd('/') }
  elseif ($Url)  { $pinBase = ($Url -replace '/releases/.*$', '') }
  else { Fail "-Digest needs a host — pass -BaseUrl <url> (or -Url to derive it), or set AUSPEX_DIGEST with AUSPEX_BASE_URL" 2 }
}
elseif (-not $Url) {
  if (-not $BaseUrl) { Fail "no artifact source — pass -BaseUrl <url> (your auspex distribution host; see your install instructions) or -Url <full-url>, or set AUSPEX_BASE_URL" 2 }
  if (-not $Version) {
    # No -Version: resolve the CDN's canonical `latest` pointer to a CONCRETE tag, then verify against it
    # (keeps verify: cosign tag-bound — a bare "latest" would fail the manifest version-annotation check).
    # Pass -Version <tag> (or -Digest) to pin instead.
    $verUrl = "$($BaseUrl.TrimEnd('/'))/releases/latest/VERSION"
    Write-Host "auspex install: no -Version given — resolving latest from $verUrl"
    $verTmp = New-TemporaryFile
    Fetch $verUrl $verTmp.FullName
    $Version = ((Get-Content -LiteralPath $verTmp.FullName -First 1) + '').Trim()
    Remove-Item -LiteralPath $verTmp.FullName -Force -ErrorAction SilentlyContinue
    if (-not $Version -or $Version -notmatch '^v[0-9]') { Fail "resolved 'latest' is not a version tag ('$Version') — pass -Version <tag> or -Digest" 11 }
    Write-Host "auspex install: resolved latest -> $Version"
  }
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
# -Digest pins the version-free content-addressed blob (<base>/blobs/sha256/<digest>) and self-verifies.
# Otherwise verify: cosign resolves the signed version->digest manifest and fetches the BLOB, self-verifying
# it (the version-path $Url is only the resolution anchor), while checksum/none fetch the version path
# directly. Only a passing check promotes the temp to $binDest.
$dlTmp = New-TemporaryFile
try {
  if ($Digest) {
    Write-Host "auspex install: pinning by digest (host $pinBase)"
    Acquire-ByDigest $pinBase $Digest $dlTmp.FullName
  }
  else {
    Write-Host "auspex install: acquiring binary (verify: $Verify) for $Url"
    switch ($Verify) {
      'none'     { Write-Warning "auspex install: -Verify none — installing WITHOUT verification (not recommended)"; Fetch $Url $dlTmp.FullName }
      'checksum' { Fetch $Url $dlTmp.FullName; Verify-Checksum $dlTmp.FullName $Url }
      'cosign'   { $digest = Resolve-BinaryDigest $Url; Fetch-BlobByDigest $Url $digest $dlTmp.FullName }
    }
  }
  Move-Item -LiteralPath $dlTmp.FullName -Destination $binDest -Force
} finally {
  if (Test-Path -LiteralPath $dlTmp.FullName) { Remove-Item -LiteralPath $dlTmp.FullName -Force }
}

Write-Host "auspex install: installed $binDest"
if (($env:PATH -split ';') -notcontains $BinDir) {
  Write-Host "auspex install: note — $BinDir is not on your PATH; add it (setx PATH \"$BinDir;%PATH%\") and reopen your shell"
}
