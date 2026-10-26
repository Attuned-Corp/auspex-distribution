#!/usr/bin/env pwsh
# PowerShell installer contract: the shipped scripts are ASCII and parse, and bootstrap.ps1's release-version
# gate decides auspexw.exe as intended.
# Loads only the functions under test from the script's AST, so nothing is downloaded or installed.
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

if ($failures) { Write-Host "$failures failure(s)"; exit 1 }
Write-Host 'bootstrap.ps1 contract: all checks passed'
