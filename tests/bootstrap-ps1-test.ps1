#!/usr/bin/env pwsh
# bootstrap.ps1 contract: the script parses, and the release-version gate decides auspexw.exe as intended.
# Loads only the functions under test from the script's AST, so nothing is downloaded or installed.
# Run: make ps1-test (needs pwsh; preinstalled on the GitHub-hosted ubuntu image).
$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot '../bootstrap/bootstrap.ps1'

$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$null, [ref]$parseErrors)
if ($parseErrors) { $parseErrors | ForEach-Object { Write-Host "FAIL parse: $_" }; exit 1 }
Write-Host 'ok    bootstrap.ps1 parses'

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
