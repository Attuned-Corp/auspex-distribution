#!/usr/bin/env pwsh
# mdm/scheduled-update.ps1 and its loader. Anywhere: the decision, channel document and installed-tag functions,
# and that the functions shared with bootstrap.ps1 haven't drifted. On Windows, also the assembled script and the
# released loader end to end, as an MDM runs them: real cosign over the signed channel fixture and the
# release-signed manifest fixture standing in for the .msi, real folder ACLs and lock, with msiexec and the
# installed-version read stubbed. Every run's own cosign download points at a refused port, so a case passes only
# if the seeded cache is used.
# Run: make scheduled-update-ps1-test. The Windows cases need dist/ from `RELEASE_TAG=test-release
# bootstrap/assemble.sh`, python on PATH to serve the fixtures, and an elevated shell.
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$template = Join-Path $repo 'mdm/scheduled-update.ps1'
$failures = 0
$passes = 0
function Pass([string]$what) { Write-Host "ok    $what"; $script:passes++ }
function Flunk([string]$what) { Write-Host "FAIL  $what"; $script:failures++ }
function Check([string]$what, $got, $want) {
  if ("$got" -ceq "$want") { Pass $what } else { Flunk "$what -> '$got', want '$want'" }
}
function Get-Ast([string]$path) {
  $errs = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errs)
  if ($errs) { throw "$path does not parse: $($errs[0])" }
  return $ast
}
function Get-FunctionText($ast, [string]$name) {
  $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
  if (-not $fn) { throw "no function $name" }
  return $fn.Extent.Text
}
function Get-AssignmentText($ast, [string]$name) {
  $a = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq $name }, $false)
  if (-not $a) { throw "no assignment to $name" }
  return $a.Extent.Text
}

$ast = Get-Ast $template
$bootAst = Get-Ast (Join-Path $repo 'bootstrap/bootstrap.ps1')

Write-Host '==> shared with bootstrap.ps1'
foreach ($name in 'Test-TagBelow', 'Split-ReleaseTag', 'Test-SameIds', 'Get-ChannelField', 'Test-ChannelTag', 'Get-Sha256Hex') {
  if ((Get-FunctionText $ast $name) -ceq (Get-FunctionText $bootAst $name)) { Pass "$name matches bootstrap.ps1" }
  else { Flunk "$name differs from bootstrap.ps1's" }
}
Check 'ReleaseTagRe matches bootstrap.ps1' (Get-AssignmentText $ast '$ReleaseTagRe') (Get-AssignmentText $bootAst '$ReleaseTagRe')

foreach ($name in 'Stop-Update', 'Test-TagBelow', 'Split-ReleaseTag', 'Test-SameIds', 'Get-ChannelField', 'Test-ChannelTag',
  'Test-ChannelDocument', 'Get-UpdateDecision', 'Get-InstalledTag', 'Get-ReleaseIdentityRe') {
  Invoke-Expression (Get-FunctionText $ast $name)
}
Invoke-Expression (Get-AssignmentText $ast '$ReleaseTagRe')

Write-Host '==> decisions'
function Doc([string]$latest, [string]$stable, [string]$minimum) {
  "{`"schema`":1,`"sequence`":1,`"latest`":$latest,`"stable`":$stable,`"minimum`":$minimum}" | ConvertFrom-Json
}
foreach ($c in @(
    @('a channel naming no release', 'none -', 'stable', 'v0.11.0', (Doc '"v0.11.0"' 'null' 'null')),
    @('a pre-release stable', 'prerelease v0.13.0-rc1', 'stable', 'v0.11.0', (Doc '"v0.13.0-rc1"' '"v0.13.0-rc1"' 'null')),
    @('a pre-release latest is allowed', 'upgrade v0.13.0-rc1', 'latest', 'v0.12.1', (Doc '"v0.13.0-rc1"' '"v0.12.1"' 'null')),
    @('a target below the minimum', 'below-minimum v0.10.0', 'latest', 'v0.9.0', (Doc '"v0.10.0"' '"v0.12.0"' '"v0.11.0"')),
    @('an install below the minimum still upgrades', 'upgrade v0.12.0', 'stable', 'v0.9.0', (Doc '"v0.12.0"' '"v0.12.0"' '"v0.11.0"')),
    @('nothing installed', 'install v0.11.0', 'stable', '', (Doc '"v0.11.0"' '"v0.11.0"' 'null')),
    @('up to date', 'current v0.11.0', 'stable', 'v0.11.0', (Doc '"v0.11.0"' '"v0.11.0"' 'null')),
    @('versions compare as numbers', 'upgrade v0.10.0', 'stable', 'v0.9.0', (Doc '"v0.10.0"' '"v0.10.0"' 'null')),
    @('a release candidate sorts below its release', 'upgrade v0.11.0', 'stable', 'v0.11.0-rc1', (Doc '"v0.11.0"' '"v0.11.0"' 'null')),
    @('an installed release candidate of a later version is ahead', 'ahead v0.11.0', 'stable', 'v0.12.0-rc1', (Doc '"v0.11.0"' '"v0.11.0"' 'null')))) {
  Check "decide: $($c[0])" (Get-UpdateDecision $c[4] $c[2] $c[3]) $c[1]
}

Write-Host '==> channel documents'
Check 'the signed fixture is a channel document' (Test-ChannelDocument (Get-Content -Raw (Join-Path $repo 'tests/fixtures/channel/channels.json') | ConvertFrom-Json)) $true
foreach ($c in @(
    @('a minimum without a stable', '{"schema":1,"sequence":5,"latest":"v0.13.0","stable":null,"minimum":"v0.12.0"}'),
    @('a minimum above stable', '{"schema":1,"sequence":5,"latest":"v0.13.0","stable":"v0.12.0","minimum":"v0.13.0"}'),
    @('schema 2', '{"schema":2,"sequence":5,"latest":"v0.13.0","stable":"v0.12.0","minimum":null}'),
    @('a string sequence', '{"schema":1,"sequence":"5","latest":"v0.13.0","stable":"v0.12.0","minimum":null}'),
    @('a fractional sequence', '{"schema":1,"sequence":5.5,"latest":"v0.13.0","stable":"v0.12.0","minimum":null}'),
    @('a zero sequence', '{"schema":1,"sequence":0,"latest":"v0.13.0","stable":"v0.12.0","minimum":null}'),
    @('a tag that is a path', '{"schema":1,"sequence":5,"latest":"v0.13.0/../v0.12.0","stable":"v0.12.0","minimum":null}'),
    @('a list', '[1]'))) {
  Check "refused: $($c[0])" (Test-ChannelDocument ($c[1] | ConvertFrom-Json)) $false
}

Write-Host '==> the installed tag'
$StateDir = Join-Path ([IO.Path]::GetTempPath()) ('auspex-installed-' + [guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $StateDir | Out-Null
foreach ($c in @(
    @('nothing installed', '', $null, ''),
    @('no record', '0.11.0', $null, 'v0.11.0'),
    @('a record of a pre-release of the installed version', '0.11.0', 'v0.11.0-rc.1', 'v0.11.0-rc.1'),
    @('a record of another version', '0.12.0', 'v0.11.0-rc.1', 'v0.12.0'),
    @('a record that is not a tag', '0.11.0', 'junk', 'v0.11.0'))) {
  $msiVersion = $c[1]
  function Get-InstalledMsiVersion { return $msiVersion }
  Remove-Item -LiteralPath (Join-Path $StateDir 'installed') -ErrorAction SilentlyContinue
  if ($c[2]) { [IO.File]::WriteAllText((Join-Path $StateDir 'installed'), "$($c[2])`n") }
  Check "installed: $($c[0])" (Get-InstalledTag) $c[3]
}
Remove-Item -LiteralPath $StateDir -Recurse -Force

Write-Host '==> the .msi signature names its release'
$CosignIdentityRe = '^https://github\.com/(?i:attuned-corp)/auspex/\.github/workflows/release\.yml@refs/tags/v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'
Check 'the identity is pinned to the tag' (Get-ReleaseIdentityRe 'v0.11.0-rc.1') '^https://github\.com/(?i:attuned-corp)/auspex/\.github/workflows/release\.yml@refs/tags/v0\.11\.0-rc\.1$'

$onWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or $IsWindows
if (-not $onWindows) {
  Write-Host 'skip  the end-to-end cases run on Windows only'
  Write-Host "scheduled-update-ps1-test: $passes passed, $failures failed"
  if ($failures) { exit 1 }
  exit 0
}

# ---- Windows: the assembled script and the released loader, end to end ------------------------------------
$dist = Join-Path $repo 'dist'
$built = Join-Path $dist 'auspex-scheduled-update.ps1'
$releasedLoader = Join-Path $dist 'auspex-scheduled-update-loader.ps1'
foreach ($f in $built, $releasedLoader) {
  if (-not (Test-Path -LiteralPath $f)) { Write-Host "FAIL  $f is missing; run RELEASE_TAG=test-release bootstrap/assemble.sh first"; exit 1 }
}
$python = Get-Command python, python3 -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $python) { Write-Host 'FAIL  python is needed to serve the fixtures'; exit 1 }
$shell = (Get-Process -Id $PID).Path
$builtAst = Get-Ast $built
$SystemSid = 'S-1-5-18'
$AdminsSid = 'S-1-5-32-544'
foreach ($name in 'Test-StateDir', 'New-StateDir', 'Get-InstalledMsiVersion', 'Get-ReleaseIdentityRe') {
  Invoke-Expression (Get-FunctionText $builtAst $name)
}
foreach ($name in '$UpgradeCode', '$CosignIdentityRe', '$CosignOidcIssuer', '$CosignVersion', '$CosignWinSha256', '$TrustedRootB64') {
  Invoke-Expression (Get-AssignmentText $builtAst $name)
}
function Get-Sha([string]$path) { (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLower() }

$work = Join-Path ([IO.Path]::GetTempPath()) ('auspex-update-ps1-' + [guid]::NewGuid().ToString())
$web = Join-Path $work 'web'
$fix = Join-Path $repo 'tests/fixtures/channel'
$msiDir = Join-Path $web 'releases/v0.11.0/windows'
$msiPath = Join-Path $msiDir 'auspex_0.11.0_windows_amd64.msi'
New-Item -ItemType Directory -Force -Path $msiDir, (Join-Path $web 'loader'), (Join-Path $work 'tools') | Out-Null
Copy-Item (Join-Path $fix 'channels.json'), (Join-Path $fix 'channels.json.cosign.bundle') (Join-Path $web 'releases')
Copy-Item (Join-Path $fix 'manifest.json') $msiPath
Copy-Item (Join-Path $fix 'manifest.json.cosign.bundle') "$msiPath.cosign.bundle"

# The pinned cosign, downloaded once and seeded into each case's state folder.
$cosign = Join-Path $work 'tools/cosign.exe'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'
Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/sigstore/cosign/releases/download/$CosignVersion/cosign-windows-amd64.exe" -OutFile $cosign
if ((Get-Sha $cosign) -ne $CosignWinSha256) { Write-Host 'FAIL  the downloaded cosign does not match its pin'; exit 1 }

$serve = Join-Path $work 'serve.py'
[IO.File]::WriteAllText($serve, @'
import sys, os, http.server, socketserver
os.chdir(sys.argv[1])
class Q(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a):
        pass
with socketserver.TCPServer(("127.0.0.1", 0), Q) as httpd:
    with open(sys.argv[2], "w") as f:
        f.write(str(httpd.server_address[1]))
    httpd.serve_forever()
'@)
$portFile = Join-Path $work 'port'
$server = Start-Process -FilePath $python.Source -ArgumentList "`"$serve`"", "`"$web`"", "`"$portFile`"" -PassThru -WindowStyle Hidden
$i = 0
while ($i++ -lt 100 -and -not ((Test-Path $portFile) -and (Get-Content -Raw $portFile))) { Start-Sleep -Milliseconds 100 }
if (-not (Test-Path $portFile)) { Write-Host 'FAIL  the fixture server never reported its port'; exit 1 }
$base = "http://127.0.0.1:$((Get-Content -Raw $portFile).Trim())"

# The assembled script with its two Windows Installer touch points stubbed: the installed version is
# $STUB_CASE\receipt, and msiexec logs its call, then sets the receipt to $STUB_CASE\msiexec-sets (default 0.11.0)
# and returns $STUB_CASE\msiexec-rc (default 0).
$swaps = @{
  'Get-InstalledMsiVersion' = @'
function Get-InstalledMsiVersion {
  $f = Join-Path $env:STUB_CASE 'receipt'
  if (Test-Path -LiteralPath $f) { return ([IO.File]::ReadAllText($f)).Trim() }
  return ''
}
'@
  'Invoke-Msiexec'          = @'
function Invoke-Msiexec([string]$msi, [string]$log) {
  [IO.File]::AppendAllText((Join-Path $env:STUB_CASE 'msiexec.log'), "$msi $((Get-FileHash -Algorithm SHA256 -LiteralPath $msi).Hash.ToLower())`n")
  $rcFile = Join-Path $env:STUB_CASE 'msiexec-rc'
  $rc = if (Test-Path -LiteralPath $rcFile) { [int]([IO.File]::ReadAllText($rcFile).Trim()) } else { 0 }
  if ($rc -eq 0 -or $rc -eq 3010) {
    $sets = Join-Path $env:STUB_CASE 'msiexec-sets'
    $v = if (Test-Path -LiteralPath $sets) { [IO.File]::ReadAllText($sets).Trim() } else { '0.11.0' }
    [IO.File]::WriteAllText((Join-Path $env:STUB_CASE 'receipt'), $v)
  }
  return $rc
}
'@
}
$text = [IO.File]::ReadAllText($built)
$defs = @($builtAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $swaps.ContainsKey($n.Name) }, $true) |
    Sort-Object { $_.Extent.StartOffset } -Descending)
if ($defs.Count -ne 2) { Write-Host 'FAIL  the script must define Get-InstalledMsiVersion and Invoke-Msiexec once each'; exit 1 }
foreach ($d in $defs) { $text = $text.Substring(0, $d.Extent.StartOffset) + $swaps[$d.Name] + $text.Substring($d.Extent.EndOffset) }
$update = Join-Path $work 'update.ps1'
[IO.File]::WriteAllText($update, $text, [Text.Encoding]::ASCII)
$served = Join-Path $web 'loader/auspex-scheduled-update.ps1'
Copy-Item $update $served

# The released loader with the fixture host and $channel in its settings lines, downloading the stubbed script
# from the fixture (loopback http in place of its https-only check).
$loader = Join-Path $work 'loader.ps1'
function Set-Loader([string]$channel) {
  $l = [IO.File]::ReadAllText($releasedLoader)
  $l = $l.Replace("`$AuspexBaseUrl = ''  ", "`$AuspexBaseUrl = '$base'").Replace("`$AuspexChannel = 'stable'", "`$AuspexChannel = '$channel'")
  $l = $l -replace "(?m)^\`$ScriptUrl = .*$", "`$ScriptUrl = '$base/loader/auspex-scheduled-update.ps1'"
  $l = $l -replace "(?m)^\`$ScriptSha256 = .*$", "`$ScriptSha256 = '$(Get-Sha $update)'"
  $l = $l.Replace("-notmatch '^https://'", "-notmatch '^http://127\.0\.0\.1:'")
  [IO.File]::WriteAllText($loader, $l, [Text.Encoding]::ASCII)
}

$script:Case = ''
$script:Out = ''
function New-Case([switch]$NoState) {
  $script:Case = Join-Path $work ('case-' + [guid]::NewGuid().ToString())
  New-Item -ItemType Directory -Path $script:Case | Out-Null
  if (-not $NoState) {
    New-StateDir (Join-Path $script:Case 'state')
    New-Item -ItemType Directory -Path (Join-Path $script:Case 'state/bin') | Out-Null
    Copy-Item $cosign (Join-Path $script:Case 'state/bin/cosign.exe')
  }
}
$state = { Join-Path $script:Case 'state' }

# Expect runs the script (or, with -Loader, the loader) for the current case, then each check. $want is the code
# the last line names; 0 means success.
function Expect([string]$label, [int]$want, [hashtable]$envs = @{}, [scriptblock[]]$checks = @(), [switch]$Loader) {
  $vars = @{
    AUSPEX_BASE_URL = $base; AUSPEX_CHANNEL = $null; STUB_CASE = $script:Case
    AUSPEX_UPDATE_STATE_DIR = (& $state); AUSPEX_COSIGN_BASE_URL = 'http://127.0.0.1:9'
  }
  if ($Loader) { $vars.AUSPEX_BASE_URL = $null }
  foreach ($k in $envs.Keys) { $vars[$k] = $envs[$k] }
  $saved = @{}
  foreach ($k in $vars.Keys) {
    $saved[$k] = [Environment]::GetEnvironmentVariable($k)
    [Environment]::SetEnvironmentVariable($k, $vars[$k])
  }
  $file = if ($Loader) { $loader } else { $update }
  $ErrorActionPreference = 'Continue'
  $script:Out = & $shell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $file 2>&1 | Out-String
  $rc = $LASTEXITCODE
  $ErrorActionPreference = 'Stop'
  foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
  $problem = ''
  $last = (($script:Out.TrimEnd() -split "`r?`n") | Select-Object -Last 1)
  if ($want -eq 0 -and $rc -ne 0) { $problem = "exit $rc, want 0" }
  elseif ($want -ne 0 -and $rc -ne 1) { $problem = "exit $rc, want 1" }
  elseif ($want -ne 0 -and $last -cne "auspex update: failed with code $want (codes: mdm/README.md)") { $problem = "last line '$last', want code $want" }
  elseif ($want -eq 0 -and $script:Out.Contains('failed with code')) { $problem = 'a successful run named a failure' }
  else {
    foreach ($c in $checks) { if (-not (& $c)) { $problem = "check failed: $c"; break } }
  }
  if ($problem) {
    Flunk "$label ($problem)"
    Write-Host ($script:Out -replace '(?m)^', '        ')
  } else { Pass $label }
}

function Installed-Is([string]$v) { (Test-Path -LiteralPath "$script:Case/receipt") -and ([IO.File]::ReadAllText("$script:Case/receipt").Trim() -eq $v) }
function Not-Installed { -not (Test-Path -LiteralPath "$script:Case/msiexec.log") }
function Said([string]$s) { $script:Out.Contains($s) }
function LastLine-Says([string]$s) { (($script:Out.TrimEnd() -split "`r?`n") | Select-Object -Last 1).Contains($s) }
function Sequence-Is([string]$s) { (Test-Path -LiteralPath "$(& $state)/sequence") -and ([IO.File]::ReadAllText("$(& $state)/sequence").Trim() -eq $s) }
function Tidy { -not (Test-Path -LiteralPath "$(& $state)/staging") }
# msiexec ran once, on the staged .msi holding the verified fixture's bytes.
function Installed-Verified-Msi {
  $lines = @([IO.File]::ReadAllLines("$script:Case/msiexec.log"))
  ($lines.Count -eq 1) -and ($lines[0] -ceq "$(& $state)\staging\auspex.msi $(Get-Sha (Join-Path $fix 'manifest.json'))")
}
function Recorded-Is([string]$t) { [IO.File]::ReadAllText("$(& $state)/installed").Trim() -ceq $t }
function Cosign-Is-Pinned { (Get-Sha "$(& $state)/bin/cosign.exe") -eq $CosignWinSha256 }

try {
  Write-Host '==> outcomes'
  New-Case
  Expect 'first install: nothing installed installs stable' 0 @{} @(
    { Installed-Is '0.11.0' }, { LastLine-Says 'installed auspex v0.11.0 from stable (was not installed)' },
    { Sequence-Is '1' }, { Tidy }, { Installed-Verified-Msi }, { Recorded-Is 'v0.11.0' })
  Remove-Item "$script:Case/msiexec.log"
  Expect 'a second run is up to date and installs nothing' 0 @{} @({ Not-Installed }, { LastLine-Says 'auspex v0.11.0 is up to date with stable' })

  New-Case; [IO.File]::WriteAllText("$script:Case/receipt", '0.10.0')
  Expect 'an older install upgrades' 0 @{} @({ Installed-Is '0.11.0' }, { LastLine-Says '(was v0.10.0)' })

  New-Case; [IO.File]::WriteAllText("$script:Case/receipt", '0.12.1')
  Expect 'a newer install is ahead and exits 0' 0 @{} @({ Not-Installed }, { LastLine-Says 'auspex v0.12.1 is ahead of stable (v0.11.0); nothing to do' })

  New-Case; [IO.File]::WriteAllText("$script:Case/receipt", '0.10.0')
  Expect 'latest is honored, named in any case' 0 @{ AUSPEX_CHANNEL = 'Latest' } @({ Installed-Is '0.11.0' }, { Said 'from latest' })

  New-Case; [IO.File]::WriteAllText("$script:Case/receipt", '0.11.0'); [IO.File]::WriteAllText("$(& $state)/installed", 'v0.11.0-rc.1')
  Expect 'a release candidate this script installed upgrades to its release' 0 @{} @(
    { Installed-Is '0.11.0' }, { LastLine-Says '(was v0.11.0-rc.1)' }, { Recorded-Is 'v0.11.0' })

  New-Case; '3010' | Set-Content "$script:Case/msiexec-rc"
  Expect 'msiexec asking for a restart is a success' 0 @{} @({ Installed-Is '0.11.0' })

  Write-Host '==> refusals'
  $channelDoc = Join-Path $web 'releases/channels.json'
  New-Case; [IO.File]::AppendAllText($channelDoc, ' ')
  Expect 'a tampered channel document' 13 @{} @({ Not-Installed }, { Tidy })
  Copy-Item (Join-Path $fix 'channels.json') $channelDoc -Force

  New-Case
  Copy-Item (Join-Path $fix 'manifest.json') $channelDoc -Force
  Copy-Item (Join-Path $fix 'manifest.json.cosign.bundle') "$channelDoc.cosign.bundle" -Force
  Expect 'a release-signed document as the channel (wrong signer)' 13 @{} @({ Not-Installed })
  Copy-Item (Join-Path $fix 'channels.json'), (Join-Path $fix 'channels.json.cosign.bundle') (Join-Path $web 'releases') -Force

  New-Case; [IO.File]::WriteAllText("$(& $state)/sequence", "2`n")
  Expect 'a replayed lower sequence' 19 @{} @({ Not-Installed }, { Sequence-Is '2' })

  New-Case; [IO.File]::WriteAllText("$(& $state)/sequence", "junk`n")
  Expect 'a corrupt sequence record' 21 @{} @({ Not-Installed }, { Said 'does not hold a sequence number' })

  New-Case; [IO.File]::AppendAllText($msiPath, ' ')
  Expect 'a tampered .msi is never installed' 13 @{} @({ Not-Installed }, { Tidy })
  Copy-Item (Join-Path $fix 'manifest.json') $msiPath -Force

  New-Case; Move-Item "$msiPath.cosign.bundle" (Join-Path $work 'held.bundle')
  Expect 'a .msi without its bundle' 11 @{} @({ Not-Installed })
  Move-Item (Join-Path $work 'held.bundle') "$msiPath.cosign.bundle"

  New-Case; '1603' | Set-Content "$script:Case/msiexec-rc"
  Expect 'a failing msiexec' 22 @{} @({ Said 'msiexec failed for auspex v0.11.0 with exit 1603' }, { Tidy })

  New-Case; '0.10.0' | Set-Content "$script:Case/msiexec-sets"
  Expect 'an installed version that does not name the target after install' 23 @{} @({ Said 'but Windows Installer reports 0.10.0' })

  New-Case; [IO.File]::WriteAllText("$script:Case/receipt", 'garbage')
  Expect 'an unreadable installed version' 16 @{} @({ Not-Installed })

  Write-Host '==> cached cosign'
  New-Case; Remove-Item "$(& $state)/bin/cosign.exe"
  Expect 'an empty cache with an unreachable download fails provisioning' 15 @{} @({ Not-Installed })

  New-Case; [IO.File]::WriteAllText("$(& $state)/bin/cosign.exe", 'tampered')
  Expect 'a tampered cache is never run, and cannot be replaced offline' 15 @{} @({ Not-Installed })

  $cosignDir = Join-Path $web "cosign/$CosignVersion"
  New-Item -ItemType Directory -Force -Path $cosignDir | Out-Null
  Copy-Item $cosign (Join-Path $cosignDir 'cosign-windows-amd64.exe')
  New-Case; [IO.File]::WriteAllText("$(& $state)/bin/cosign.exe", 'tampered')
  Expect 'a tampered cache is replaced by the pinned download' 0 @{ AUSPEX_COSIGN_BASE_URL = "$base/cosign" } @({ Cosign-Is-Pinned }, { Installed-Is '0.11.0' })

  $planted = Join-Path $work 'planted'
  New-Item -ItemType Directory -Force -Path $planted | Out-Null
  [IO.File]::WriteAllText((Join-Path $planted 'cosign.cmd'), "@echo off`r`necho ran> `"%STUB_CASE%\planted-ran`"`r`n")
  New-Case; Remove-Item "$(& $state)/bin/cosign.exe"
  Expect 'a cosign on PATH is never run' 15 @{ PATH = "$planted;$env:PATH" } @({ -not (Test-Path "$script:Case/planted-ran") }, { Not-Installed })

  Write-Host '==> state folder and lock'
  New-Case -NoState
  Expect 'a missing state folder is created for SYSTEM and Administrators only' 0 @{ AUSPEX_COSIGN_BASE_URL = "$base/cosign" } @(
    { Test-StateDir (& $state) }, { Cosign-Is-Pinned }, { Installed-Is '0.11.0' })

  New-Case
  $acl = Get-Acl -LiteralPath (& $state)
  $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-545'), 'Read', 'Allow')))
  Set-Acl -LiteralPath (& $state) -AclObject $acl
  Expect 'a state folder users can read' 21 @{} @({ Not-Installed })

  New-Case -NoState; New-Item -ItemType Directory -Path (& $state) | Out-Null
  Expect 'a state folder that inherits its rules' 21 @{} @({ Not-Installed })

  New-Case -NoState
  New-StateDir "$script:Case/real-state"
  New-Item -ItemType Junction -Path (& $state) -Target "$script:Case/real-state" | Out-Null
  Expect 'a linked state folder' 21 @{} @({ Not-Installed })

  New-Case
  $held = [IO.File]::Open("$(& $state)/lock", 'OpenOrCreate', 'ReadWrite', 'None')
  Expect 'a lock held by another run exits 0 and does nothing' 0 @{} @({ Not-Installed }, { LastLine-Says 'another run is in progress; nothing to do' })
  $held.Dispose()

  Write-Host '==> settings'
  New-Case
  Expect 'no base URL' 2 @{ AUSPEX_BASE_URL = $null } @({ Not-Installed })
  Expect 'an unknown channel' 2 @{ AUSPEX_CHANNEL = 'beta' } @({ Not-Installed }, { Said 'the channel must be stable or latest, not beta' })
  Expect 'a cleartext non-loopback host' 2 @{ AUSPEX_BASE_URL = 'http://example.com' } @({ Not-Installed })

  Write-Host '==> Windows Installer'
  Check 'the real query finds no auspex .msi on this machine' (Get-InstalledMsiVersion) ''
  $root = Join-Path $work 'trusted_root.json'
  [IO.File]::WriteAllBytes($root, [Convert]::FromBase64String($TrustedRootB64))
  $ErrorActionPreference = 'Continue' # cosign reports on stderr, which 5.1 turns into a terminating error under 'Stop'
  foreach ($c in @(@('v0.11.0', 0), @('v0.12.1', 1), @('v0.11', 1))) {
    & $cosign verify-blob --bundle "$msiPath.cosign.bundle" --trusted-root $root --certificate-identity-regexp (Get-ReleaseIdentityRe $c[0]) `
      --certificate-oidc-issuer $CosignOidcIssuer $msiPath *> $null
    Check "the v0.11.0 .msi verifies as $($c[0])" ([int]($LASTEXITCODE -ne 0)) $c[1]
  }
  $ErrorActionPreference = 'Stop'

  Write-Host '==> loader'
  $l = [IO.File]::ReadAllText($releasedLoader)
  Check 'the released loader pins the released script by SHA-256' ($l.Contains("`$ScriptSha256 = '$(Get-Sha $built)'")) $true
  Check 'the released loader downloads from its own release' ($l.Contains("`$ScriptUrl = 'https://github.com/Attuned-Corp/auspex-distribution/releases/download/test-release/auspex-scheduled-update.ps1'")) $true
  Check 'the released loader downloads over https only' ($l.Contains("-notmatch '^https://'")) $true
  Check 'the released loader is short enough to read' (@([IO.File]::ReadAllLines($releasedLoader)).Count -le 45) $true

  Set-Loader 'stable'
  $cached = { (Test-Path -LiteralPath "$(& $state)/scheduled-update.ps1") -and ((Get-Sha "$(& $state)/scheduled-update.ps1") -eq (Get-Sha $update)) }
  New-Case
  Expect 'the loader runs the pinned script with its own settings, and caches it' 0 @{} @(
    { Installed-Is '0.11.0' }, { LastLine-Says 'installed auspex v0.11.0 from stable' }, { Tidy }, $cached) -Loader
  Set-Loader 'latest'
  New-Case
  Expect 'the loader passes its channel through' 0 @{} @({ Installed-Is '0.11.0' }, { Said 'from latest' }) -Loader
  Set-Loader 'beta'
  New-Case
  Expect 'a bad channel fails in the script, with one failure line' 2 @{} @(
    { Not-Installed }, { Said 'not beta' }, { ([regex]::Matches($script:Out, 'failed with code')).Count -eq 1 }) -Loader

  Set-Loader 'stable'
  [IO.File]::AppendAllText($served, ' ')
  New-Case
  Expect 'a script that does not match the pin is never run' 12 @{} @(
    { Not-Installed }, { Said 'running nothing' }, { -not (Test-Path "$(& $state)/sequence") }, { -not (Test-Path "$(& $state)/scheduled-update.ps1") }) -Loader
  Remove-Item $served
  New-Case
  Expect 'a script that cannot be downloaded is never run' 11 @{} @({ Not-Installed }, { -not (Test-Path "$(& $state)/sequence") }) -Loader
  New-Case; Copy-Item $update "$(& $state)/scheduled-update.ps1"
  Expect 'a cached script that matches the pin runs without a download' 0 @{} @({ Installed-Is '0.11.0' }) -Loader
  New-Case; [IO.File]::WriteAllText("$(& $state)/scheduled-update.ps1", "Write-Host planted`n")
  Expect 'a cached script that does not match the pin is never run' 11 @{} @({ Not-Installed }, { -not (Said 'planted') }) -Loader
  New-Case -NoState; New-Item -ItemType Directory -Path (& $state) | Out-Null; Copy-Item $update "$(& $state)/scheduled-update.ps1"
  Expect 'a cache in a state folder others can use is not read' 11 @{} @({ Not-Installed }) -Loader
  Copy-Item $update $served
  New-Case; [IO.File]::WriteAllText("$(& $state)/scheduled-update.ps1", "Write-Host stale`n")
  Expect 'a stale cached script is replaced by the pinned download' 0 @{} @({ Installed-Is '0.11.0' }, { -not (Said 'stale') }, $cached) -Loader
} finally {
  Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "scheduled-update-ps1-test: $passes passed, $failures failed"
if ($failures) { exit 1 }
exit 0
