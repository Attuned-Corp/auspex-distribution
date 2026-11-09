#!/usr/bin/env pwsh
# PowerShell installer contract: the shipped scripts are ASCII and parse, bootstrap.ps1's release-version
# gate decides auspexw.exe as intended, and a cosign install places both binaries.
# The gate checks load only the functions under test from the script's AST. The install check runs the whole
# script against a local fixture tree, so nothing is downloaded.
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

foreach ($name in 'Get-ReleaseVersion', 'Test-ShipsAuspexw') {
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

# ---- a cosign install, end to end ----------------------------------------------------------------------
# Runs the real bootstrap.ps1 in a child process of this same PowerShell, with two functions swapped out: Fetch
# serves https://cdn.test/ from a fixture tree, and Ensure-Cosign installs a stub that passes.
foreach ($n in 'AUSPEX_VERSION', 'AUSPEX_VERIFY', 'AUSPEX_BASE_URL', 'AUSPEX_BINARY_URL', 'AUSPEX_DIGEST',
  'AUSPEX_BIN_DIR', 'AUSPEX_COSIGN_BASE_URL') {
  Remove-Item "Env:$n" -ErrorAction SilentlyContinue
}
$env:PROCESSOR_ARCHITECTURE = 'AMD64'
$work = Join-Path ([IO.Path]::GetTempPath()) ('auspex-ps1-test-' + [guid]::NewGuid().ToString())
$cdn = Join-Path $work 'cdn'
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
function Invoke-StubCosign { `$global:LASTEXITCODE = 0 }
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
$text = $text -replace '@@AUSPEX_[A-Z0-9_]+@@', 'test'
$installer = Join-Path $work 'install.ps1'
[IO.File]::WriteAllText($installer, $text, [Text.Encoding]::ASCII)

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
$blobs = Join-Path $cdn 'blobs/sha256'
New-Item -ItemType Directory -Force -Path $blobs | Out-Null
Copy-Item -LiteralPath $exeFile -Destination (Join-Path $blobs $exeSum)
Copy-Item -LiteralPath $wFile -Destination (Join-Path $blobs $wSum)
$platform = @{ os = 'windows'; architecture = 'amd64' }
Write-Ascii (Join-Path $cdn 'releases/v0.10.0/manifest.json') (@{
    schemaVersion = 2
    mediaType     = 'application/vnd.oci.image.index.v1+json'
    manifests     = @(
      @{ mediaType = 'application/octet-stream'; digest = "sha256:$exeSum"; platform = $platform },
      @{ mediaType = 'application/vnd.microsoft.portable-executable'; digest = "sha256:$wSum"; platform = $platform })
    annotations   = @{ 'org.opencontainers.image.version' = 'v0.10.0' }
  } | ConvertTo-Json -Depth 6)
Write-Ascii (Join-Path $cdn 'releases/v0.10.0/manifest.json.cosign.bundle') 'dummy-bundle'

# The bin dir is never on PATH here, so the run also prints the PATH note.
$bin = Join-Path $work 'bin'
$ErrorActionPreference = 'Continue' # the child's stderr must not stop this script
$out = & (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -File $installer -BaseUrl 'https://cdn.test' -Version v0.10.0 -BinDir $bin 2>&1 | Out-String
$rc = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
$exe = Join-Path $bin 'auspex.exe'
$w = Join-Path $bin 'auspexw.exe'
if ($rc -ne 0) { $problem = "expected success, rc=$rc" }
elseif (-not (Test-Path -LiteralPath $exe) -or (Get-Sha $exe) -ne $exeSum) { $problem = 'auspex.exe is missing or not the served bytes' }
elseif (-not (Test-Path -LiteralPath $w) -or (Get-Sha $w) -ne $wSum) { $problem = 'auspexw.exe is missing or not the served bytes' }
else { $problem = '' }
if ($problem) {
  Write-Host "FAIL  a cosign install places auspex.exe and auspexw.exe - $problem"
  Write-Host ($out -replace '(?m)^', '        ')
  $failures++
}
else { Write-Host 'ok    a cosign install places auspex.exe and auspexw.exe' }
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue

if ($failures) { Write-Host "$failures failure(s)"; exit 1 }
Write-Host 'bootstrap.ps1 contract: all checks passed'
