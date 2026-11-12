<#
.SYNOPSIS
  auspex Windows installer (irm | iex) - fetch + fail-closed verify + place on PATH.

.DESCRIPTION
  TEMPLATE: the trust material (release + channel identity regexes, OIDC issuer, cosign version + windows
  digest, and the embedded Sigstore trusted_root.json) is INJECTED from src/span-auspex/verify-lib.sh by
  bootstrap/assemble.sh - verify-lib.sh stays the single source of truth (SSOT) for the pins; this file is not runnable until
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
  [string]$Channel = $env:AUSPEX_CHANNEL,   # latest (default) | stable: the release to install when no -Version
  [ValidateSet('cosign', 'checksum', 'none')]
  [string]$Verify = $(if ($env:AUSPEX_VERIFY) { $env:AUSPEX_VERIFY } else { 'cosign' }),
  [string]$BaseUrl = $env:AUSPEX_BASE_URL,   # REQUIRED unless -Url: no baked default (host-agnostic public repo)
  [string]$Url = $env:AUSPEX_BINARY_URL,
  [string]$Digest = $env:AUSPEX_DIGEST,      # pin a raw sha256 (of the artifact) - installs the version-free blob directly
  [string]$CaptureDigest = $env:AUSPEX_CAPTURE_DIGEST, # with -Digest: pin auspexw.exe's sha256 too
  [string]$ManifestDigest = $env:AUSPEX_MANIFEST_DIGEST, # pin a whole release by its manifest's sha256
  [string]$BinDir = $env:AUSPEX_BIN_DIR,
  [string]$CosignBaseUrl = $(if ($env:AUSPEX_COSIGN_BASE_URL) { $env:AUSPEX_COSIGN_BASE_URL } else { 'https://github.com/sigstore/cosign/releases/download' })
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

# --- trust material (INJECTED from verify-lib.sh by assemble.sh) -----------------------------------------
$CosignIdentityRe = '@@AUSPEX_IDENTITY_RE@@'
$CosignChannelIdentityRe = '@@AUSPEX_CHANNEL_IDENTITY_RE@@'
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

# auspexw.exe ships in every auspex release from this version on (its pre-releases included) and in none before
# it. From it on the installer requires auspexw.exe: a missing one there is a broken or tampered release, and
# installing without it would silently lose the hook speed-up. Older releases install auspex.exe alone.
$AuspexwSince = [version]'0.10.0'

# Get-ReleaseVersion reads the release version from a .../releases/<v>/<os>/<arch>/<file> URL as a [version]
# (major.minor.patch); a pre-release reads as its base version (v0.10.0-rc1 -> 0.10.0). $null when the path
# carries no version.
function Get-ReleaseVersion([string]$u) {
  if ($u -notmatch '/releases/v?(\d+)\.(\d+)\.(\d+)[^/]*/') { return $null }
  return [version]"$($Matches[1]).$($Matches[2]).$($Matches[3])"
}

# Test-ShipsAuspexw reports whether the release at $u carries auspexw.exe. A path without a version is treated
# as an older release.
function Test-ShipsAuspexw([string]$u) {
  $v = Get-ReleaseVersion $u
  return ($null -ne $v) -and ($v -ge $AuspexwSince)
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
    Fail "SHA-256 mismatch for $u (expected '$expected', got '$got') - refusing to install" 12
  }
  Write-Host "auspex install: SHA-256 verified ($got)"
}

$script:CosignBin = $null
$script:PinPrinted = $false # Resolve-BinaryDigest runs once per binary; the manifest pin prints once
function Ensure-Cosign {
  if ($script:CosignBin) { return } # on PATH, or downloaded and hash-checked earlier this run
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
    Fail "pinned cosign SHA-256 mismatch (expected $CosignWinSha256, got $got) - refusing to use a tampered cosign" 15
  }
  $script:CosignBin = $tmp
}

function Write-TrustedRoot {
  $path = Join-Path ([IO.Path]::GetTempPath()) ("auspex-trusted-root-" + [guid]::NewGuid().ToString() + ".json")
  [IO.File]::WriteAllBytes($path, [Convert]::FromBase64String($TrustedRootB64))
  return $path
}

# Resolve the raw-binary digest for a version-path URL from the SIGNED manifest (verify: cosign - auspex
# ADR 0047), the Windows-native equivalent of verify-lib.sh's resolve_binary_digest. Fetch + cosign-verify
# the version->digest index (manifest.json), assert its version annotation matches the requested tag (closes
# the version-substitution gap), then read the unique descriptor of $MediaType for this os/arch and return its
# bare-hex sha256: application/octet-stream is auspex.exe; application/vnd.microsoft.portable-executable is
# auspexw.exe, the windowless build Windows coding tools run (a distinct type, so a selector written for one
# raw binary per os/arch still finds exactly one). PowerShell parses the manifest with native ConvertFrom-Json -
# no jq.
function Resolve-BinaryDigest([string]$u, [string]$MediaType = 'application/octet-stream') {
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
      Fail "cosign FAILED to verify $verRoot/manifest.json against the pinned release identity - refusing to install" 13
    }
    try {
      $json = Get-Content -Raw -LiteralPath $manifest.FullName | ConvertFrom-Json
      $mver = $json.annotations.'org.opencontainers.image.version'
    } catch {
      Fail "could not parse the signed manifest $verRoot/manifest.json - refusing to install" 14
    }
    if ($mver -ne $version) {
      Fail "the signed manifest is for '$mver' but the requested path is version '$version' - refusing (version substitution)" 14
    }
    if (-not $script:PinPrinted) {
      Write-Host "auspex install: manifest digest sha256:$(Get-Sha256Hex $manifest.FullName) pins every binary of $version (signed manifest verified)"
      $script:PinPrinted = $true
    }
    $digest = Select-BinaryDigest $json $MediaType $os $arch 'signed manifest'
    Write-Host "auspex install: resolved $version $os/$arch -> sha256:$digest (signed manifest verified)"
    return $digest
  } finally {
    Remove-Item -LiteralPath $manifest.FullName, $bundle.FullName, $rootPath -Force -ErrorAction SilentlyContinue
  }
}

# Select-BinaryDigest returns the bare-hex digest of the one descriptor of $MediaType for $os/$arch in a parsed
# manifest ($what names it in errors), failing closed when there isn't exactly one.
function Select-BinaryDigest($json, [string]$MediaType, [string]$os, [string]$arch, [string]$what) {
  try {
    $descs = @($json.manifests | Where-Object {
        $_.mediaType -eq $MediaType -and $_.platform.os -eq $os -and $_.platform.architecture -eq $arch
      })
  } catch {
    Fail "could not read the descriptors of the $what - refusing to install" 14
  }
  if ($descs.Count -ne 1) {
    Fail "the $what has no unique raw-binary ($MediaType) descriptor for $os/$arch - refusing to install" 14
  }
  $digest = "$($descs[0].digest)"
  if ($digest -notmatch '^sha256:[0-9a-f]{64}$') {
    Fail "the resolved digest '$digest' is not a bare sha256 hex - refusing to install" 14
  }
  return ($digest -replace '^sha256:', '')
}

# Fetch an artifact from the global content-addressed blob namespace and SELF-VERIFY (verify: cosign - auspex
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
    Fail "by-digest self-verify FAILED - $blobUrl hashes to $got, not $digest (corrupt or tampered blob) - refusing to install" 12
  }
  Write-Host "auspex install: by-digest verified (sha256:$got)"
}

# Pin-by-digest (auspex ADR 0047 - the version-free pin): install the artifact STRAIGHT from the global
# content-addressed blob and self-verify, bypassing the version->manifest resolution. The digest is the
# trust anchor (obtained out-of-band), so no version/manifest/cosign is consulted - the self-verify is the
# whole check and it survives a re-tag. <base> is the host root (blobs/sha256/<digest> is appended).
function Acquire-ByDigest([string]$base, [string]$digest, [string]$out) {
  $d = Get-PinnedDigest $digest
  Write-Host "auspex install: pinning by digest sha256:$d (version-free; self-verify only)"
  Fetch-BlobByDigest ($base.TrimEnd('/')) $d $out
}

# Get-PinnedDigest returns $digest as bare lowercase hex, failing unless it is a full sha256 (optionally
# 'sha256:'-prefixed, any case).
function Get-PinnedDigest([string]$digest) {
  $d = ($digest -replace '^sha256:', '').ToLower()
  if ($d -notmatch '^[0-9a-f]{64}$') {
    Fail "invalid pinned digest '$digest' - expected a 64-char sha256 hex (optionally 'sha256:'-prefixed)" 2
  }
  return $d
}

# Manifest pin: returns the release manifest pinned by digest, parsed, once it self-verifies and its version
# is a release tag. The digest is the trust anchor, as for -Digest, so no cosign runs.
function Get-PinnedManifest([string]$base, [string]$digest) {
  $d = Get-PinnedDigest $digest
  Write-Host "auspex install: pinning the release manifest by digest sha256:$d (self-verify; no cosign)"
  $tmp = New-TemporaryFile
  try {
    Fetch-BlobByDigest ($base.TrimEnd('/')) $d $tmp.FullName
    try {
      $json = Get-Content -Raw -LiteralPath $tmp.FullName | ConvertFrom-Json
    } catch {
      Fail "could not parse the pinned manifest - refusing to install" 14
    }
  } finally {
    Remove-Item -LiteralPath $tmp.FullName -Force -ErrorAction SilentlyContinue
  }
  $mver = ''
  if ($json.PSObject.Properties['annotations'] -and $json.annotations.PSObject.Properties['org.opencontainers.image.version']) {
    $mver = "$($json.annotations.'org.opencontainers.image.version')"
  }
  # The version names a URL path, so only the tag shape the release identity signs is accepted.
  if ($mver -cnotmatch '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$') {
    Fail "the pinned manifest's version annotation is not a release tag ('$mver') - refusing to install" 14
  }
  Write-Host "auspex install: the pinned manifest is release $mver"
  return $json
}

$ReleaseTagRe = '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'

# Test-TagBelow reports whether release tag $x sorts below $y by SemVer 2.0.0 precedence, as verify-lib.sh's vlt:
# numeric parts compare as numbers, a pre-release sorts below its release, and within pre-releases numeric
# identifiers sort below alphanumeric ones.
function Test-TagBelow([string]$x, [string]$y) {
  $a = Split-ReleaseTag $x
  $b = Split-ReleaseTag $y
  for ($i = 0; $i -lt 3; $i++) {
    if ($a.Core[$i] -ne $b.Core[$i]) { return $a.Core[$i] -lt $b.Core[$i] }
  }
  if (Test-SameIds $a.Pre $b.Pre) { return $false }
  if ($a.Pre.Count -eq 0) { return $false }
  if ($b.Pre.Count -eq 0) { return $true }
  $n = [Math]::Min($a.Pre.Count, $b.Pre.Count)
  for ($i = 0; $i -lt $n; $i++) {
    $p = $a.Pre[$i]; $q = $b.Pre[$i]
    if ($p -ceq $q) { continue }
    $pn = $p -match '^[0-9]+$'; $qn = $q -match '^[0-9]+$'
    if ($pn -and $qn) { return [decimal]$p -lt [decimal]$q }
    if ($pn -or $qn) { return $pn }
    return [string]::CompareOrdinal($p, $q) -lt 0
  }
  return $a.Pre.Count -lt $b.Pre.Count
}

function Split-ReleaseTag([string]$tag) {
  $null = $tag -cmatch '^v([0-9]+)\.([0-9]+)\.([0-9]+)(-(.+))?$'
  $pre = @()
  if ($Matches[5]) { $pre = @($Matches[5] -split '\.') }
  return @{ Core = @([decimal]$Matches[1], [decimal]$Matches[2], [decimal]$Matches[3]); Pre = $pre }
}

function Test-SameIds([string[]]$p, [string[]]$q) {
  if ($p.Count -ne $q.Count) { return $false }
  for ($i = 0; $i -lt $p.Count; $i++) { if ($p[$i] -cne $q[$i]) { return $false } }
  return $true
}

# Get-ChannelField returns a channel document field, or $null when it is absent (StrictMode throws on a missing
# property).
function Get-ChannelField($doc, [string]$name) {
  if ($doc.PSObject.Properties[$name]) { return $doc.$name }
  return $null
}

# Test-ChannelTag accepts $null or a release tag string, as verify-lib.sh's jq `tag`.
function Test-ChannelTag($v) {
  return ($null -eq $v) -or (($v -is [string]) -and ($v -cmatch $ReleaseTagRe))
}

# Resolve-ChannelRelease returns the tag release channel $Channel names in $base's signed channel document (auspex
# ADR 0066), the Windows-native equivalent of verify-lib.sh's resolve_channel_release. It verifies the document
# against the pinned CHANNEL identity, applies the reader's schema checks, then refuses what every client must: a
# channel naming no release, a pre-release stable, or one below the minimum.
function Resolve-ChannelRelease([string]$base, [string]$channel) {
  $u = "$($base.TrimEnd('/'))/releases/channels.json"
  Write-Host "auspex install: resolving the $channel channel from $u"
  Ensure-Cosign
  $rootPath = Write-TrustedRoot
  $doc = New-TemporaryFile
  $bundle = New-TemporaryFile
  try {
    Fetch $u $doc.FullName
    Fetch "$u.cosign.bundle" $bundle.FullName
    & $script:CosignBin verify-blob `
      --bundle $bundle.FullName `
      --trusted-root $rootPath `
      --certificate-identity-regexp $CosignChannelIdentityRe `
      --certificate-oidc-issuer $CosignOidcIssuer `
      $doc.FullName *> $null
    if ($LASTEXITCODE -ne 0) {
      Fail "cosign FAILED to verify $u against the pinned channel identity - refusing to trust it" 13
    }
    $json = $null
    try { $json = Get-Content -Raw -LiteralPath $doc.FullName | ConvertFrom-Json } catch { }
  } finally {
    Remove-Item -LiteralPath $doc.FullName, $bundle.FullName, $rootPath -Force -ErrorAction SilentlyContinue
  }
  $valid = $json -is [System.Management.Automation.PSCustomObject]
  if ($valid) {
    $seq = Get-ChannelField $json 'sequence'
    $latest = Get-ChannelField $json 'latest'
    $stable = Get-ChannelField $json 'stable'
    $minimum = Get-ChannelField $json 'minimum'
    $schema = Get-ChannelField $json 'schema'
    # Whole numbers parse as [int] under Windows PowerShell 5.1 and [long] under pwsh 7.
    $valid = (($schema -is [int]) -or ($schema -is [long])) -and ($schema -eq 1) -and
      (($seq -is [int]) -or ($seq -is [long])) -and ($seq -ge 1) -and ($seq -lt 9007199254740992) -and
      (Test-ChannelTag $latest) -and (Test-ChannelTag $stable) -and (Test-ChannelTag $minimum) -and
      (($null -eq $minimum) -or (($null -ne $stable) -and -not (Test-TagBelow $stable $minimum)))
  }
  if (-not $valid) { Fail "$u is signed but isn't a schema-1 channel document - refusing to trust it" 18 }
  Write-Host "auspex install: channel document verified (sequence $seq, signed by the pinned channel identity)"
  $target = Get-ChannelField $json $channel
  if ($null -eq $target) { Fail "the $channel channel names no release - pass -Version <tag> to choose one" 20 }
  if ($channel -eq 'stable' -and $target.Contains('-')) { Fail "the stable channel names a pre-release ($target) - refusing it" 20 }
  if ($null -ne $minimum -and (Test-TagBelow $target $minimum)) { Fail "the $channel channel names $target, below the minimum - refusing it" 20 }
  Write-Host "auspex install: the $channel channel names $target"
  return $target
}

function Get-WindowsArch {
  switch ($env:PROCESSOR_ARCHITECTURE) {
    'AMD64' { return 'amd64' }
    'ARM64' { return 'arm64' }
    default { Fail "unsupported CPU '$($env:PROCESSOR_ARCHITECTURE)'" 16 }
  }
}

# --- derive source ---------------------------------------------------------------------------------------
if ($Channel -and @('latest', 'stable') -notcontains $Channel) { Fail "-Channel must be latest or stable (got '$Channel')" 2 }
if ($Channel -and ($Version -or $Url -or $Digest -or $ManifestDigest)) {
  Fail "-Channel picks the release, so it can't be combined with -Version, -Url, -Digest or -ManifestDigest" 2
}
$Channel = if ($Channel) { $Channel.ToLower() } else { 'latest' }
if ($Channel -eq 'stable' -and $Verify -ne 'cosign') {
  Fail "-Channel stable reads the signed channel document, which needs -Verify cosign - pass -Version <tag> instead" 2
}
if ($ManifestDigest -and ($Digest -or $CaptureDigest)) {
  Fail "-ManifestDigest pins every binary already - drop -Digest/-CaptureDigest" 2
}
if ($CaptureDigest -and -not $Digest) {
  Fail "-CaptureDigest pins auspexw.exe beside a -Digest pin of auspex.exe - pass -Digest too (a version install fetches auspexw.exe itself)" 2
}
$pinBase = $null
$pinned = $null
if ($Digest -or $ManifestDigest) {
  # Pin-by-digest needs only a host root (the blob is version/os/arch-free). Prefer -BaseUrl; else derive it
  # from a full -Url (everything before /releases/). No version/os/arch derivation.
  if ($BaseUrl)  { $pinBase = $BaseUrl.TrimEnd('/') }
  elseif ($Url)  { $pinBase = ($Url -replace '/releases/.*$', '') }
  else { Fail "a digest pin needs a host - pass -BaseUrl <url> (or -Url to derive it), or set AUSPEX_BASE_URL" 2 }
  if ($ManifestDigest) {
    $pinned = Get-PinnedManifest $pinBase $ManifestDigest
    $mver = "$($pinned.annotations.'org.opencontainers.image.version')"
    if ($Version -and $Version -ne $mver) { Fail "-Version $Version but the pinned manifest is $mver - refusing" 14 }
    $Version = $mver
    $Url = "$pinBase/releases/$Version/windows/$(Get-WindowsArch)/auspex.exe"
  }
}
elseif (-not $Url) {
  if (-not $BaseUrl) { Fail "no artifact source - pass -BaseUrl <url> (your auspex distribution host; see your install instructions) or -Url <full-url>, or set AUSPEX_BASE_URL" 2 }
  if (-not $Version -and $Verify -eq 'cosign') {
    # No -Version: install the release the channel names in the host's signed channel document (auspex ADR
    # 0066). The tag stays concrete, so verify: cosign still binds the manifest to it.
    $Version = Resolve-ChannelRelease $BaseUrl $Channel
  }
  elseif (-not $Version) {
    # checksum/none run no cosign, so they can't check the channel document's signature. They follow `latest`
    # through the CDN's unsigned `releases/latest/VERSION` marker, resolved to a CONCRETE tag.
    $verUrl = "$($BaseUrl.TrimEnd('/'))/releases/latest/VERSION"
    Write-Host "auspex install: no -Version given - resolving latest from $verUrl"
    $verTmp = New-TemporaryFile
    Fetch $verUrl $verTmp.FullName
    $Version = ((Get-Content -LiteralPath $verTmp.FullName -First 1) + '').Trim()
    Remove-Item -LiteralPath $verTmp.FullName -Force -ErrorAction SilentlyContinue
    # The marker is unsigned: accept only a full release tag (the shape the release identity signs, no room for a path).
    if (-not $Version -or $Version -cnotmatch $ReleaseTagRe) { Fail "resolved 'latest' is not a release tag ('$Version') - pass -Version <tag> or -Digest" 11 }
    Write-Host "auspex install: resolved latest -> $Version"
  }
  $Url = "$($BaseUrl.TrimEnd('/'))/releases/$Version/windows/$(Get-WindowsArch)/auspex.exe"
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
# A manifest pin fetches auspexw.exe too, before either binary is placed.
$dlTmp = New-TemporaryFile
$wPinnedTmp = $null
try {
  if ($pinned) {
    $arch = ($Url -split '/')[-2]
    Fetch-BlobByDigest $Url (Select-BinaryDigest $pinned 'application/octet-stream' 'windows' $arch 'pinned manifest') $dlTmp.FullName
    if (Test-ShipsAuspexw $Url) {
      $wPinnedTmp = New-TemporaryFile
      Fetch-BlobByDigest $Url (Select-BinaryDigest $pinned 'application/vnd.microsoft.portable-executable' 'windows' $arch 'pinned manifest') $wPinnedTmp.FullName
    }
  }
  elseif ($Digest) {
    Write-Host "auspex install: pinning by digest (host $pinBase)"
    Acquire-ByDigest $pinBase $Digest $dlTmp.FullName
  }
  else {
    Write-Host "auspex install: acquiring binary (verify: $Verify) for $Url"
    switch ($Verify) {
      'none'     { Write-Warning "auspex install: -Verify none - installing WITHOUT verification (not recommended)"; Fetch $Url $dlTmp.FullName }
      'checksum' { Fetch $Url $dlTmp.FullName; Verify-Checksum $dlTmp.FullName $Url }
      # Not $digest: names are case-insensitive, so that would overwrite -Digest and skip auspexw.exe below.
      'cosign'   { $exeDigest = Resolve-BinaryDigest $Url; Fetch-BlobByDigest $Url $exeDigest $dlTmp.FullName }
    }
  }
  Move-Item -LiteralPath $dlTmp.FullName -Destination $binDest -Force
} catch {
  if ($wPinnedTmp) { Remove-Item -LiteralPath $wPinnedTmp.FullName -Force -ErrorAction SilentlyContinue }
  throw
} finally {
  if (Test-Path -LiteralPath $dlTmp.FullName) { Remove-Item -LiteralPath $dlTmp.FullName -Force }
}

Write-Host "auspex install: installed $binDest"

# --- auspexw.exe: the windowless build coding tools run ----------------------------------------------------
# `auspex install` places auspexw.exe from beside auspex.exe and wires the Windows coding tools to it: it opens no
# console window, which makes every hook about a third faster (the python.exe / pythonw.exe pairing). A release
# from $AuspexwSince on ships it, so it is fetched and verified exactly like auspex.exe, fail-closed. A release
# before that installs auspex.exe alone, and its hooks run auspex.exe, as before. A digest pin names one
# artifact, so auspexw.exe needs its own (-CaptureDigest); without it, from $AuspexwSince on, `auspex install`
# needs auspexw.exe put beside auspex.exe.
$wDest = Join-Path $BinDir 'auspexw.exe'
if ($wPinnedTmp) {
  Move-Item -LiteralPath $wPinnedTmp.FullName -Destination $wDest -Force
  Write-Host "auspex install: installed $wDest"
}
elseif ($pinned) {
  Write-Host "auspex install: this release predates auspexw.exe - coding-tool hooks will run through auspex.exe"
}
elseif ($CaptureDigest) {
  $wTmp = New-TemporaryFile
  try {
    Acquire-ByDigest $pinBase $CaptureDigest $wTmp.FullName
    Move-Item -LiteralPath $wTmp.FullName -Destination $wDest -Force
    Write-Host "auspex install: installed $wDest"
  } finally {
    if (Test-Path -LiteralPath $wTmp.FullName) { Remove-Item -LiteralPath $wTmp.FullName -Force }
  }
}
elseif ($Digest) {
  Write-Host "auspex install: -Digest pins auspex.exe only - from auspex 0.10.0 on, pass -CaptureDigest with auspexw.exe's sha256, or put auspexw.exe beside it before running auspex install"
}
elseif ($Url -match '/auspex\.exe$' -and (Test-ShipsAuspexw $Url)) {
  $wUrl = $Url -replace '/auspex\.exe$', '/auspexw.exe'
  $wTmp = New-TemporaryFile
  try {
    switch ($Verify) {
      'none'     { Fetch $wUrl $wTmp.FullName }
      'checksum' { Fetch $wUrl $wTmp.FullName; Verify-Checksum $wTmp.FullName $wUrl }
      'cosign'   { Fetch-BlobByDigest $wUrl (Resolve-BinaryDigest $wUrl 'application/vnd.microsoft.portable-executable') $wTmp.FullName }
    }
    Move-Item -LiteralPath $wTmp.FullName -Destination $wDest -Force
    Write-Host "auspex install: installed $wDest"
  } finally {
    if (Test-Path -LiteralPath $wTmp.FullName) { Remove-Item -LiteralPath $wTmp.FullName -Force }
  }
}
else {
  Write-Host "auspex install: this release predates auspexw.exe - coding-tool hooks will run through auspex.exe"
}
if (($env:PATH -split ';') -notcontains $BinDir) {
  Write-Host "auspex install: note - $BinDir is not on your PATH; add it (setx PATH `"$BinDir;%PATH%`") and reopen your shell"
}
