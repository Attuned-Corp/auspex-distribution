#!/usr/bin/env pwsh
# PowerShell installer contract: the shipped scripts are ASCII and parse, the auspexw.exe version gate holds, and
# -ManifestDigest and -Channel install or refuse as they should, run against a local fixture tree so nothing is
# downloaded.
# Run: make ps1-test (needs pwsh; preinstalled on the GitHub-hosted ubuntu image).
$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot '../bootstrap/bootstrap.ps1'

# Every shipped PowerShell script must be pure ASCII: Windows PowerShell 5.1 reads a BOM-less file as ANSI, and
# a UTF-8 em dash (E2 80 94) then decodes to a closing curly quote that ends any string it sits in, so the script
# no longer parses there. pwsh 7 (this CI) reads UTF-8 fine, so only this byte check catches it.
$shipped = @('bootstrap/bootstrap.ps1', 'mdm/verify-gate.ps1')
$broken = $false
foreach ($rel in $shipped) {
  $path = Join-Path $PSScriptRoot "../$rel"
  $bytes = [IO.File]::ReadAllBytes($path)
  $bad = @(for ($i = 0; $i -lt $bytes.Length; $i++) { if ($bytes[$i] -gt 126 -or ($bytes[$i] -lt 32 -and @(9, 10, 13) -notcontains $bytes[$i])) { $i } })
  if ($bad.Count) {
    $line = ([Text.Encoding]::ASCII.GetString($bytes, 0, $bad[0]) -split "`n").Count
    Write-Host "FAIL  $rel has $($bad.Count) non-ASCII byte(s), first on line $line"; $broken = $true
  } else { Write-Host "ok    $rel is ASCII" }
  $errs = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errs)
  if ($errs) { $errs | ForEach-Object { Write-Host "FAIL  $rel parse: $_" }; $broken = $true } else { Write-Host "ok    $rel parses" }
}
if ($broken) { exit 1 }

$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$null, [ref]$parseErrors)

foreach ($name in 'Get-ReleaseVersion', 'Test-ShipsAuspexw', 'Test-TagBelow', 'Split-ReleaseTag', 'Test-SameIds') {
  $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
  if (-not $fn) { Write-Host "FAIL bootstrap.ps1 has no function $name"; exit 1 }
  Invoke-Expression $fn.Extent.Text
}
# The threshold is the script's own, not a copy.
$since = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$AuspexwSince' }, $true)
Invoke-Expression $since.Extent.Text
Write-Host "      AuspexwSince = $AuspexwSince"

$failures = 0
function Check([string]$what, $got, $want) {
  if ("$got" -ceq "$want") { Write-Host "ok    $what -> $got" }
  else { Write-Host "FAIL  $what -> '$got', want '$want'"; $script:failures++ }
}
function Url([string]$v) { "https://cdn.example/releases/$v/windows/amd64/auspex.exe" }

# Version parsing: numeric per part (never lexical), pre-release and build metadata dropped.
Check 'version v0.10.0'          (Get-ReleaseVersion (Url 'v0.10.0'))        '0.10.0'
Check 'version 0.10.0 (no v)'    (Get-ReleaseVersion (Url '0.10.0'))         '0.10.0'
Check 'version v0.10.0-rc2'      (Get-ReleaseVersion (Url 'v0.10.0-rc2'))    '0.10.0'
Check 'version v0.10.0+build.7'  (Get-ReleaseVersion (Url 'v0.10.0+build.7')) '0.10.0'
Check 'version v12.345.6789'     (Get-ReleaseVersion (Url 'v12.345.6789'))   '12.345.6789'
Check 'version v0.10 (no patch)' (Get-ReleaseVersion (Url 'v0.10'))          ''
Check 'version latest'           (Get-ReleaseVersion (Url 'latest'))         ''
Check 'version no /releases/'    (Get-ReleaseVersion 'https://host/custom/auspex.exe') ''

# The auspexw.exe gate: from 0.10.0 on (its pre-releases included), never before.
foreach ($c in @(
    @('v0.10.0', $true), @('v0.10.0-rc1', $true), @('v0.10.1', $true), @('v0.11.0', $true),
    @('v1.0.0', $true), @('v0.100.0', $true),
    @('v0.9.1', $false), @('v0.9.99', $false), @('v0.8.2-rc1', $false), @('v0.1.0', $false),
    @('latest', $false))) {
  Check "ships auspexw $($c[0])" (Test-ShipsAuspexw (Url $c[0])) $c[1]
}

# Release tag order, as verify-lib.sh's vlt: SemVer 2.0.0 precedence.
foreach ($c in @(
    @('v0.9.1', 'v0.10.0', $true), @('v0.10.0', 'v0.9.1', $false), @('v0.10.0', 'v0.10.0', $false),
    @('v0.10.1', 'v0.10.2', $true), @('v1.0.0', 'v0.99.99', $false),
    @('v1.0.0-rc.1', 'v1.0.0', $true), @('v1.0.0', 'v1.0.0-rc.1', $false),
    @('v1.0.0-rc.2', 'v1.0.0-rc.10', $true), @('v1.0.0-rc10', 'v1.0.0-rc2', $true),
    @('v1.0.0-1', 'v1.0.0-rc', $true), @('v1.0.0-rc', 'v1.0.0-1', $false),
    @('v1.0.0-rc', 'v1.0.0-rc.1', $true), @('v1.0.0-rc.1', 'v1.0.0-rc.1', $false))) {
  Check "$($c[0]) below $($c[1])" (Test-TagBelow $c[0] $c[1]) $c[2]
}

# ---- -ManifestDigest, end to end ----------------------------------------------------------------------
# Runs the real bootstrap.ps1 in a child of this same shell with only Fetch (serves https://cdn.test/ from a
# fixture tree) and Ensure-Cosign (a recording stub) swapped, so the flag checks and order are real. The stub
# passes, unless $cosignFail holds text its arguments contain.
foreach ($n in 'AUSPEX_VERSION', 'AUSPEX_CHANNEL', 'AUSPEX_VERIFY', 'AUSPEX_BASE_URL', 'AUSPEX_BINARY_URL', 'AUSPEX_DIGEST',
  'AUSPEX_CAPTURE_DIGEST', 'AUSPEX_MANIFEST_DIGEST', 'AUSPEX_BIN_DIR', 'AUSPEX_COSIGN_BASE_URL') {
  Remove-Item "Env:$n" -ErrorAction SilentlyContinue
}
$env:PROCESSOR_ARCHITECTURE = 'AMD64'
$work = Join-Path ([IO.Path]::GetTempPath()) ('auspex-ps1-test-' + [guid]::NewGuid().ToString())
$cdn = Join-Path $work 'cdn'
$cosignLog = Join-Path $work 'cosign.log'
$cosignFail = Join-Path $work 'cosign.fail'
New-Item -ItemType Directory -Force -Path $cdn | Out-Null

$swaps = @{
  'Fetch'         = @"
function Fetch([string]`$u, [string]`$out) {
  Assert-Https `$u
  `$src = Join-Path '$cdn' (`$u -replace '^https://cdn\.test/', '')
  if (-not (Test-Path -LiteralPath `$src -PathType Leaf)) { Fail "failed to download `$u : not found" 11 }
  Copy-Item -LiteralPath `$src -Destination `$out -Force
}
"@
  'Ensure-Cosign' = @"
function Ensure-Cosign { `$script:CosignBin = 'Invoke-StubCosign' }
function Invoke-StubCosign {
  Add-Content -LiteralPath '$cosignLog' -Value (`$args -join ' ')
  `$global:LASTEXITCODE = 0
  if ((Test-Path -LiteralPath '$cosignFail') -and (`$args -join ' ').Contains((Get-Content -Raw -LiteralPath '$cosignFail').Trim())) { `$global:LASTEXITCODE = 1 }
}
"@
}
$text = [IO.File]::ReadAllText($script)
$defs = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $swaps.ContainsKey($n.Name) }, $true) |
    Sort-Object { $_.Extent.StartOffset } -Descending)
if ($defs.Count -ne 2) { Write-Host 'FAIL  bootstrap.ps1 must define Fetch and Ensure-Cosign once each'; exit 1 }
foreach ($d in $defs) {
  $text = $text.Substring(0, $d.Extent.StartOffset) + $swaps[$d.Name] + $text.Substring($d.Extent.EndOffset)
}
$text = $text.Replace('@@AUSPEX_TRUSTED_ROOT_B64@@', [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes('{}')))
$text = $text.Replace('@@AUSPEX_CHANNEL_IDENTITY_RE@@', 'channel-identity')
$text = $text -replace '@@AUSPEX_[A-Z0-9_]+@@', 'test'
$installer = Join-Path $work 'install.ps1'
[IO.File]::WriteAllText($installer, $text, [Text.Encoding]::ASCII)
$shell = (Get-Process -Id $PID).Path

function Write-Ascii([string]$path, [string]$content) {
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
  [IO.File]::WriteAllText($path, $content, [Text.Encoding]::ASCII)
}
function Get-Sha([string]$path) { (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLower() }
$exeFile = Join-Path $work 'auspex.exe'
$wFile = Join-Path $work 'auspexw.exe'
Write-Ascii $exeFile ('fake-auspex-exe-' + [guid]::NewGuid().ToString())
Write-Ascii $wFile ('fake-auspexw-exe-' + [guid]::NewGuid().ToString())
$exeSum = Get-Sha $exeFile
$wSum = Get-Sha $wFile

# New-Release writes release $v's manifest layout and blobs and returns the manifest's digest. $variant breaks it:
# no-auspex/no-auspexw, no-version/not-a-tag, or auspexw-tampered/blob-tampered (wrong bytes served).
function New-Release([string]$v, [string]$variant = '') {
  $blobs = Join-Path $cdn 'blobs/sha256'
  New-Item -ItemType Directory -Force -Path $blobs | Out-Null
  Copy-Item -LiteralPath $exeFile -Destination (Join-Path $blobs $exeSum) -Force
  if ($variant -eq 'auspexw-tampered') { Write-Ascii (Join-Path $blobs $wSum) 'tampered-auspexw' }
  else { Copy-Item -LiteralPath $wFile -Destination (Join-Path $blobs $wSum) -Force }
  $descs = @()
  if ($variant -ne 'no-auspex') {
    $descs += @{ mediaType = 'application/octet-stream'; digest = "sha256:$exeSum"; platform = @{ os = 'windows'; architecture = 'amd64' } }
  }
  if ($variant -ne 'no-auspexw') {
    $descs += @{ mediaType = 'application/vnd.microsoft.portable-executable'; digest = "sha256:$wSum"; platform = @{ os = 'windows'; architecture = 'amd64' } }
  }
  $ann = @{ 'org.opencontainers.image.version' = $v }
  if ($variant -eq 'no-version') { $ann = @{} }
  if ($variant -eq 'not-a-tag') { $ann = @{ 'org.opencontainers.image.version' = 'latest' } }
  $manifest = Join-Path $cdn "releases/$v/manifest.json"
  Write-Ascii $manifest (@{ schemaVersion = 2; mediaType = 'application/vnd.oci.image.index.v1+json'; manifests = $descs; annotations = $ann } | ConvertTo-Json -Depth 6)
  Write-Ascii (Join-Path $cdn "releases/$v/manifest.json.cosign.bundle") 'dummy-bundle'
  $sum = Get-Sha $manifest
  if ($variant -eq 'blob-tampered') { Write-Ascii (Join-Path $blobs $sum) 'tampered-manifest' }
  else { Copy-Item -LiteralPath $manifest -Destination (Join-Path $blobs $sum) -Force }
  return $sum
}

function Get-Flat([string]$s) { ($s -replace '\r?\n\s*\|', '') -replace '\s', '' }

# Test-Install runs the installer with $argv and checks what it placed: both, exe (auspex.exe alone) or none
# (a refusal that placed nothing). -Pin also requires that cosign never ran. Returns the installer's output.
function Test-Install([string]$what, [string[]]$argv, [string]$want, [string]$expect = '', [switch]$Pin) {
  $bin = Join-Path $work 'bin'
  Remove-Item -LiteralPath $bin, $cosignLog -Recurse -Force -ErrorAction SilentlyContinue
  $ErrorActionPreference = 'Continue' # the child's stderr must not stop this script
  $out = & $shell -NoProfile -ExecutionPolicy Bypass -File $installer @argv -BinDir $bin 2>&1 | Out-String
  $rc = $LASTEXITCODE
  $exe = Join-Path $bin 'auspex.exe'
  $w = Join-Path $bin 'auspexw.exe'
  $problem = ''
  if ($want -eq 'none') {
    if ($rc -eq 0) { $problem = 'expected a refusal' }
    elseif ((Test-Path -LiteralPath $exe) -or (Test-Path -LiteralPath $w)) { $problem = 'a refused install placed a binary' }
  }
  elseif ($rc -ne 0) { $problem = "expected success, rc=$rc" }
  elseif (-not (Test-Path -LiteralPath $exe) -or (Get-Sha $exe) -ne $exeSum) { $problem = 'auspex.exe is missing or not the served bytes' }
  elseif ($want -eq 'both' -and (-not (Test-Path -LiteralPath $w) -or (Get-Sha $w) -ne $wSum)) { $problem = 'auspexw.exe is missing or not the served bytes' }
  elseif ($want -eq 'exe' -and (Test-Path -LiteralPath $w)) { $problem = 'auspexw.exe placed for a release that predates it' }
  # Errors wrap to the console width (pwsh 7 behind '| ' gutters, 5.1 mid-word), so match with no whitespace.
  if (-not $problem -and $expect -and -not (Get-Flat $out).Contains((Get-Flat $expect))) { $problem = "the output lacks '$expect'" }
  if (-not $problem -and $Pin -and (Test-Path -LiteralPath $cosignLog)) { $problem = 'a manifest pin called cosign' }
  if ($problem) {
    Write-Host "FAIL  $what - $problem"
    Write-Host ($out -replace '(?m)^', '        ')
    $script:failures++
  }
  else { Write-Host "ok    $what" }
  return $out
}

$base = 'https://cdn.test'
$m = New-Release 'v0.13.0'
$out = Test-Install 'a cosign install prints the manifest pin' @('-BaseUrl', $base, '-Version', 'v0.13.0') 'both' "manifest digest sha256:$m"
$printed = [regex]::Match((Get-Flat $out), 'manifestdigestsha256:([0-9a-f]{64})').Groups[1].Value
$null = Test-Install 'the printed pin installs the same bytes, with no cosign' @('-BaseUrl', $base, '-ManifestDigest', $printed) 'both' -Pin
$null = Test-Install 'a sha256:-prefixed uppercase pin' @('-BaseUrl', $base, '-ManifestDigest', "sha256:$($m.ToUpper())") 'both' -Pin
$null = Test-Install 'the host derived from -Url' @('-Url', "$base/releases/v0.13.0/windows/amd64/auspex.exe", '-ManifestDigest', $m) 'both' -Pin
$null = Test-Install 'a matching -Version' @('-BaseUrl', $base, '-ManifestDigest', $m, '-Version', 'v0.13.0') 'both' -Pin
$null = Test-Install 'a mismatched -Version is refused' @('-BaseUrl', $base, '-ManifestDigest', $m, '-Version', 'v0.12.9') 'none' 'but the pinned manifest is v0.13.0'
$null = Test-Install '-Digest beside it is refused' @('-BaseUrl', $base, '-ManifestDigest', $m, '-Digest', $exeSum) 'none' 'drop -Digest/-CaptureDigest'
$null = Test-Install '-CaptureDigest beside it is refused' @('-BaseUrl', $base, '-ManifestDigest', $m, '-CaptureDigest', $wSum) 'none' 'drop -Digest/-CaptureDigest'
$m = New-Release 'v0.9.1' 'no-auspexw'
$null = Test-Install 'a release before auspexw.exe installs auspex.exe alone' @('-BaseUrl', $base, '-ManifestDigest', $m) 'exe' -Pin
foreach ($c in @(
    @('no-auspexw', 'no unique raw-binary (application/vnd.microsoft.portable-executable)'),
    @('auspexw-tampered', 'self-verify FAILED'),
    @('no-auspex', 'no unique raw-binary (application/octet-stream)'),
    @('no-version', 'not a release tag'),
    @('not-a-tag', 'not a release tag'),
    @('blob-tampered', 'self-verify FAILED'))) {
  $m = New-Release 'v0.13.0' $c[0]
  $null = Test-Install "refused, nothing placed: $($c[0])" @('-BaseUrl', $base, '-ManifestDigest', $m) 'none' $c[1]
}

# ---- -Channel: the release the signed channel document names -----------------------------------------
# Write-Channel serves a channel document; Test-Channel runs the installer and checks which release it chose.
function Write-Channel([string]$json) { Write-Ascii (Join-Path $cdn 'releases/channels.json') $json; Write-Ascii (Join-Path $cdn 'releases/channels.json.cosign.bundle') 'dummy-bundle' }
function Test-Channel([string]$what, [string[]]$argv, [string]$want, [string]$expect) {
  $out = Test-Install $what $argv $want $expect
  if ($want -ne 'none' -and -not ((Test-Path -LiteralPath $cosignLog) -and (Get-Content -Raw -LiteralPath $cosignLog).Contains('channel-identity'))) {
    Write-Host "FAIL  $what - the channel document wasn't verified against the channel identity"
    $script:failures++
  }
}
$null = New-Release 'v0.13.0'
$null = New-Release 'v0.12.0'
$null = New-Release 'v0.11.0'
$null = New-Release 'v0.13.1-rc.1'
Write-Channel '{"schema":1,"sequence":4,"issued_at":"2026-11-11T22:04:30Z","latest":"v0.13.0","stable":"v0.12.0","minimum":null}'
Test-Channel 'no -Version follows latest' @('-BaseUrl', $base) 'both' 'the latest channel names v0.13.0'
Test-Channel '-Channel latest' @('-BaseUrl', $base, '-Channel', 'latest') 'both' 'resolved v0.13.0 windows/amd64'
Test-Channel '-Channel stable' @('-BaseUrl', $base, '-Channel', 'stable') 'both' 'resolved v0.12.0 windows/amd64'
Test-Channel '-Channel is case-insensitive' @('-BaseUrl', $base, '-Channel', 'Stable') 'both' 'the stable channel names v0.12.0'
Write-Channel '{"schema":1,"sequence":5,"latest":"v0.13.1-rc.1","stable":"v0.12.0","minimum":"v0.12.0"}'
Test-Channel 'a pre-release latest installs' @('-BaseUrl', $base) 'both' 'the latest channel names v0.13.1-rc.1'
foreach ($c in @(
    @('a stable that names no release', 'stable', '{"schema":1,"sequence":5,"latest":"v0.13.0","stable":null,"minimum":null}', 'the stable channel names no release'),
    @('a latest that names no release', 'latest', '{"schema":1,"sequence":5,"latest":null,"stable":"v0.12.0","minimum":null}', 'the latest channel names no release'),
    @('a pre-release stable', 'stable', '{"schema":1,"sequence":5,"latest":"v0.13.1-rc.1","stable":"v0.13.1-rc.1","minimum":null}', 'names a pre-release (v0.13.1-rc.1)'),
    @('a latest below the minimum', 'latest', '{"schema":1,"sequence":5,"latest":"v0.11.0","stable":"v0.12.0","minimum":"v0.12.0"}', 'names v0.11.0, below the minimum'),
    @('a minimum without a stable', 'latest', '{"schema":1,"sequence":5,"latest":"v0.13.0","stable":null,"minimum":"v0.12.0"}', "isn't a schema-1 channel document"),
    @('a minimum above stable', 'latest', '{"schema":1,"sequence":5,"latest":"v0.13.0","stable":"v0.12.0","minimum":"v0.13.0"}', "isn't a schema-1 channel document"),
    @('schema 2', 'latest', '{"schema":2,"sequence":5,"latest":"v0.13.0","stable":"v0.12.0","minimum":null}', "isn't a schema-1 channel document"),
    @('a string sequence', 'latest', '{"schema":1,"sequence":"5","latest":"v0.13.0","stable":"v0.12.0","minimum":null}', "isn't a schema-1 channel document"),
    @('a fractional sequence', 'latest', '{"schema":1,"sequence":5.5,"latest":"v0.13.0","stable":"v0.12.0","minimum":null}', "isn't a schema-1 channel document"),
    @('a tag that is a path', 'latest', '{"schema":1,"sequence":5,"latest":"v0.13.0/../v0.12.0","stable":"v0.12.0","minimum":null}', "isn't a schema-1 channel document"),
    @('not JSON', 'latest', 'not json', "isn't a schema-1 channel document"))) {
  Write-Channel $c[2]
  $null = Test-Install "refused, nothing placed: $($c[0])" @('-BaseUrl', $base, '-Channel', $c[1]) 'none' $c[3]
}
Write-Channel '{"schema":1,"sequence":4,"latest":"v0.13.0","stable":"v0.12.0","minimum":null}'
Write-Ascii $cosignFail 'channel-identity'
# 5.1 splits a long error across records, so match only its start.
$null = Test-Install 'refused: a channel document cosign rejects' @('-BaseUrl', $base) 'none' 'cosign FAILED to verify https://cdn.test/releases/channels.json'
Remove-Item -LiteralPath $cosignFail -Force
Remove-Item -LiteralPath (Join-Path $cdn 'releases/channels.json.cosign.bundle') -Force
$null = Test-Install 'refused: no channel document bundle' @('-BaseUrl', $base) 'none' 'channels.json.cosign.bundle'
$null = Test-Install 'refused: -Channel beside -Version' @('-BaseUrl', $base, '-Channel', 'stable', '-Version', 'v0.13.0') 'none' "can't be combined with -Version"
$null = Test-Install 'refused: an unknown channel' @('-BaseUrl', $base, '-Channel', 'beta') 'none' 'must be latest or stable'
$null = Test-Install 'refused: -Channel stable without cosign' @('-BaseUrl', $base, '-Channel', 'stable', '-Verify', 'checksum') 'none' 'needs -Verify cosign'

# -Verify checksum can't check the channel document's signature, so it follows the unsigned latest marker.
$rel = Join-Path $cdn 'releases/v0.13.0/windows/amd64'
New-Item -ItemType Directory -Force -Path $rel | Out-Null
Copy-Item -LiteralPath $exeFile -Destination (Join-Path $rel 'auspex.exe') -Force
Copy-Item -LiteralPath $wFile -Destination (Join-Path $rel 'auspexw.exe') -Force
Write-Ascii (Join-Path $rel 'auspex.exe.sha256') "$exeSum  auspex.exe"
Write-Ascii (Join-Path $rel 'auspexw.exe.sha256') "$wSum  auspexw.exe"
Write-Ascii (Join-Path $cdn 'releases/latest/VERSION') 'v0.13.0'
$null = Test-Install '-Verify checksum follows the latest marker' @('-BaseUrl', $base, '-Verify', 'checksum') 'both' 'resolved latest -> v0.13.0'
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue

if ($failures) { Write-Host "$failures failure(s)"; exit 1 }
Write-Host 'bootstrap.ps1 contract: all checks passed'
