<#
.SYNOPSIS
  auspex MDM scheduled update (Windows). An MDM runs it as SYSTEM on a schedule, through the pasted
  mdm/scheduled-update-loader.ps1 (an Intune Remediation, for example).

.DESCRIPTION
  TEMPLATE: the trust material is INJECTED from src/span-auspex/verify-lib.sh by bootstrap/assemble.sh, as for
  bootstrap.ps1; this file is not runnable until assembled into dist/auspex-scheduled-update.ps1. It is the
  Windows twin of mdm/scheduled-update.sh, and the functions it shares with bootstrap.ps1 are kept identical
  (tests/scheduled-update-ps1-test.ps1 checks).

  Each run reads the signed release channel document and, when the channel names a newer release than the
  installed .msi, installs that release's .msi, verified fail-closed against that release's own signature. It
  also does the first install on a device without auspex. See mdm/README.md.

  It keeps its state in AUSPEX_UPDATE_STATE_DIR (default C:\ProgramData\auspex-update), a folder only SYSTEM
  and Administrators can use: the pinned cosign, the loader's copy of this script, the highest channel sequence
  accepted (a replayed older document is refused, auspex ADR 0066 section 3), the tag this script last
  installed, and the last msiexec log.

  Intune counts only exit 1 as a problem, so every failure exits 1 and the last output line names its code.
#>
[CmdletBinding()]
param(
  [string]$BaseUrl = $env:AUSPEX_BASE_URL,  # your auspex download host (https://...), from your install instructions
  [string]$Channel = $(if ($env:AUSPEX_CHANNEL) { $env:AUSPEX_CHANNEL } else { 'stable' }),  # stable or latest
  [string]$CosignBaseUrl = $(if ($env:AUSPEX_COSIGN_BASE_URL) { $env:AUSPEX_COSIGN_BASE_URL } else { 'https://github.com/sigstore/cosign/releases/download' })
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue' # Windows PowerShell 5.1's progress bar slows a download many times over
Set-StrictMode -Version Latest
$Channel = "$Channel".ToLower()
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

# --- trust material (INJECTED from verify-lib.sh by assemble.sh) -----------------------------------------
$CosignIdentityRe = '@@AUSPEX_IDENTITY_RE@@'
$CosignChannelIdentityRe = '@@AUSPEX_CHANNEL_IDENTITY_RE@@'
$CosignOidcIssuer = '@@AUSPEX_OIDC_ISSUER@@'
$CosignVersion    = '@@AUSPEX_COSIGN_VERSION@@'
$CosignWinSha256  = '@@AUSPEX_COSIGN_WINDOWS_AMD64_SHA@@'
$TrustedRootB64   = '@@AUSPEX_TRUSTED_ROOT_B64@@'

# The auspex .msi's fixed UpgradeCode (auspex package/windows/auspex.wxs; the reconcile CI job checks it).
$UpgradeCode = '{6F3D2B1A-8C4E-4F2A-9D7B-1E5A6C9F0B23}'
$StateDir = if ($env:AUSPEX_UPDATE_STATE_DIR) { $env:AUSPEX_UPDATE_STATE_DIR } else { 'C:\ProgramData\auspex-update' }
$Staging = Join-Path $StateDir 'staging'
$SystemSid = 'S-1-5-18'
$AdminsSid = 'S-1-5-32-544'
$Prefix = 'auspex update'
$script:Lock = $null

# Exit codes, named in the last line of a failed run (mdm/README.md): 1 an unexpected error, 2 a bad setting,
# 11 a download, 13 a signature, 15 cosign provisioning, 16 the environment, 18 a malformed channel document,
# 19 a replayed one, 20 a target this script won't install, 21 the state folder, 22 msiexec, 23 the installed
# version after the install.
function Stop-Update([int]$code, [string]$msg) {
  $e = New-Object Exception $msg
  $e.Data['AuspexCode'] = $code
  throw $e
}

function Write-Result([string]$msg) { Write-Host "${Prefix}: $msg" }

function Test-AllowedUrl([string]$u) {
  return ($u -match '^https://') -or ($u -match '^http://(127\.0\.0\.1|localhost|\[::1\])(:[0-9]+)?(/|$)')
}

function Fetch([string]$u, [string]$out, [int]$code = 11) {
  if (-not (Test-AllowedUrl $u)) { Stop-Update $code "refusing to fetch over a non-https URL: $u" }
  try {
    Invoke-WebRequest -Uri $u -OutFile $out -UseBasicParsing -MaximumRedirection 5 -TimeoutSec 600
  } catch {
    Stop-Update $code "could not fetch $u"
  }
}

function Get-Sha256Hex([string]$path) {
  (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLower()
}

function Test-Elevated {
  $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# A 32-bit PowerShell on 64-bit Windows reports x86 here and the real CPU in PROCESSOR_ARCHITEW6432.
function Get-WindowsArch {
  $a = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
  switch ($a) {
    'AMD64' { return 'amd64' }
    'ARM64' { return 'arm64' }
  }
  Stop-Update 16 "unsupported CPU $a"
}

# The state folder must be usable only by SYSTEM and Administrators, as root's 0700 folder is on macOS: a user
# could otherwise plant the cosign or script it caches. ProgramData lets any user create a folder, so one that
# isn't owned by SYSTEM or Administrators, inherits its rules, grants anyone else, or is a link is refused.
function Test-StateDir([string]$path) {
  $d = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
  if (-not $d -or -not $d.PSIsContainer -or ($d.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $false }
  $acl = Get-Acl -LiteralPath $path
  $trusted = @($SystemSid, $AdminsSid)
  if (-not $acl.AreAccessRulesProtected) { return $false }
  if ($trusted -notcontains $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value) { return $false }
  $others = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) |
      Where-Object { $trusted -notcontains $_.IdentityReference.Value })
  return $others.Count -eq 0
}

# Created with its rules in one step, so no user can slip a file in before they apply.
function New-StateDir([string]$path) {
  $sec = New-Object Security.AccessControl.DirectorySecurity
  $sec.SetAccessRuleProtection($true, $false)
  foreach ($sid in $SystemSid, $AdminsSid) {
    $sec.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
          (New-Object Security.Principal.SecurityIdentifier $sid), 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
  }
  if ($PSVersionTable.PSEdition -eq 'Desktop') { [void][IO.Directory]::CreateDirectory($path, $sec) }
  else { [void][IO.FileSystemAclExtensions]::Create((New-Object IO.DirectoryInfo $path), $sec) }
}

function Initialize-StateDir {
  if (-not (Test-Path -LiteralPath $StateDir)) {
    try { New-StateDir $StateDir } catch { Stop-Update 21 "could not create ${StateDir}: $($_.Exception.Message)" }
  }
  if (-not (Test-StateDir $StateDir)) {
    Stop-Update 21 "$StateDir must be a folder only SYSTEM and Administrators can use, owned by one of them, not a link; refusing to use it"
  }
  New-Item -ItemType Directory -Force -Path (Join-Path $StateDir 'bin') | Out-Null
}

# Windows releases an open file when its process exits, so a run that died never leaves the lock held.
function Lock-State {
  try {
    $script:Lock = [IO.File]::Open((Join-Path $StateDir 'lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    return $true
  } catch [IO.IOException] {
    return $false
  }
}

# The pinned cosign, hash-checked before every use and downloaded only when the cached copy doesn't match. Never
# one from PATH. Its pin is windows/amd64; Windows 11 on Arm runs it under emulation.
function Get-Cosign {
  $cache = Join-Path $StateDir 'bin\cosign.exe'
  if ((Test-Path -LiteralPath $cache -PathType Leaf) -and (Get-Sha256Hex $cache) -eq $CosignWinSha256.ToLower()) { return $cache }
  Remove-Item -LiteralPath $cache -Force -ErrorAction SilentlyContinue
  $tmp = Join-Path $Staging 'cosign.exe'
  Fetch "$CosignBaseUrl/$CosignVersion/cosign-windows-amd64.exe" $tmp 15
  $got = Get-Sha256Hex $tmp
  if ($got -ne $CosignWinSha256.ToLower()) {
    Stop-Update 15 "the downloaded cosign has SHA-256 $got, not the pinned $CosignWinSha256; refusing to run it"
  }
  Move-Item -LiteralPath $tmp -Destination $cache -Force
  return $cache
}

function Invoke-CosignVerify([string]$cosign, [string]$file, [string]$bundle, [string]$identityRe, [string]$what) {
  $root = Join-Path $Staging 'trusted_root.json'
  if (-not (Test-Path -LiteralPath $root)) { [IO.File]::WriteAllBytes($root, [Convert]::FromBase64String($TrustedRootB64)) }
  # cosign reports on stderr, which Windows PowerShell 5.1 turns into a terminating error under 'Stop'.
  $ErrorActionPreference = 'Continue'
  & $cosign verify-blob --bundle $bundle --trusted-root $root --certificate-identity-regexp $identityRe `
    --certificate-oidc-issuer $CosignOidcIssuer $file *> $null
  if ($LASTEXITCODE -ne 0) { Stop-Update 13 "cosign could not verify $what against the pinned signer; refusing it" }
}

# The release identity pinned to <tag>, so a genuine older .msi served at the target's URL can't verify and
# downgrade the device.
function Get-ReleaseIdentityRe([string]$tag) {
  return ($CosignIdentityRe -replace '@refs/tags/.*$', '') + '@refs/tags/' + $tag.Replace('.', '\.') + '$'
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

# The reader's schema checks, as bootstrap.ps1's Resolve-ChannelRelease and verify-lib.sh's verify_channel_document.
function Test-ChannelDocument($json) {
  if ($json -isnot [System.Management.Automation.PSCustomObject]) { return $false }
  $seq = Get-ChannelField $json 'sequence'
  $stable = Get-ChannelField $json 'stable'
  $minimum = Get-ChannelField $json 'minimum'
  $schema = Get-ChannelField $json 'schema'
  # Whole numbers parse as [int] under Windows PowerShell 5.1 and [long] under pwsh 7.
  return (($schema -is [int]) -or ($schema -is [long])) -and ($schema -eq 1) -and
    (($seq -is [int]) -or ($seq -is [long])) -and ($seq -ge 1) -and ($seq -lt 9007199254740992) -and
    (Test-ChannelTag (Get-ChannelField $json 'latest')) -and (Test-ChannelTag $stable) -and (Test-ChannelTag $minimum) -and
    (($null -eq $minimum) -or (($null -ne $stable) -and -not (Test-TagBelow $stable $minimum)))
}

function Read-Channel([string]$cosign) {
  $u = "$($BaseUrl.TrimEnd('/'))/releases/channels.json"
  $doc = Join-Path $Staging 'channels.json'
  Fetch $u $doc
  Fetch "$u.cosign.bundle" "$doc.cosign.bundle"
  $record = Join-Path $StateDir 'sequence'
  $min = $null
  if (Test-Path -LiteralPath $record) {
    $text = ([IO.File]::ReadAllText($record)).Trim()
    if ($text -notmatch '^[0-9]{1,16}$') { Stop-Update 21 "$record does not hold a sequence number; remove it to start over" }
    $min = [decimal]$text
  }
  Invoke-CosignVerify $cosign $doc "$doc.cosign.bundle" $CosignChannelIdentityRe $u
  $json = $null
  try { $json = [IO.File]::ReadAllText($doc) | ConvertFrom-Json } catch { }
  if (-not (Test-ChannelDocument $json)) { Stop-Update 18 "$u is signed but is not a schema-1 channel document; refusing it" }
  if ($null -ne $min -and $json.sequence -lt $min) {
    Stop-Update 19 "channel document sequence $($json.sequence) is below $min, the last one accepted; refusing a replayed document"
  }
  [IO.File]::WriteAllText("$record.new", "$($json.sequence)`n")
  Move-Item -LiteralPath "$record.new" -Destination $record -Force
  return $json
}

# Get-UpdateDecision returns "<action> <target>": none (no release named), prerelease or below-minimum (refusals,
# auspex ADR 0066 section 2), install, current, ahead or upgrade. <installed> is a tag, or empty when nothing is.
function Get-UpdateDecision($doc, [string]$channel, [string]$installed) {
  $t = Get-ChannelField $doc $channel
  $minimum = Get-ChannelField $doc 'minimum'
  if ($null -eq $t) { return 'none -' }
  if ($channel -eq 'stable' -and $t.Contains('-')) { return "prerelease $t" }
  if ($null -ne $minimum -and (Test-TagBelow $t $minimum)) { return "below-minimum $t" }
  if (-not $installed) { return "install $t" }
  if ($installed -ceq $t) { return "current $t" }
  if (Test-TagBelow $t $installed) { return "ahead $t" }
  return "upgrade $t"
}

# The installed auspex .msi's ProductVersion (0.12.1), or empty when none is installed.
function Get-InstalledMsiVersion {
  $msi = New-Object -ComObject WindowsInstaller.Installer
  $codes = @($msi.RelatedProducts($UpgradeCode))
  if ($codes.Count -eq 0) { return '' }
  if ($codes.Count -gt 1) { Stop-Update 16 "more than one auspex .msi is installed ($($codes -join ', '))" }
  return [string]$msi.ProductInfo($codes[0], 'VersionString')
}

# The .msi drops a pre-release suffix (0.13.0-rc.1 installs as 0.13.0), so when the tag this script last
# installed has the installed version, it names the install whole.
function Get-InstalledTag {
  $v = Get-InstalledMsiVersion
  if (-not $v) { return '' }
  if ($v -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') { Stop-Update 16 "cannot read the installed auspex version: $v" }
  $record = Join-Path $StateDir 'installed'
  if (Test-Path -LiteralPath $record -PathType Leaf) {
    $t = ([IO.File]::ReadAllText($record)).Trim()
    if ($t -cmatch $ReleaseTagRe -and ($t.Substring(1) -replace '-.*$', '') -eq $v) { return $t }
  }
  return "v$v"
}

function Invoke-Msiexec([string]$msi, [string]$log) {
  $p = [Diagnostics.Process]::Start("$env:SystemRoot\System32\msiexec.exe", "/i `"$msi`" /qn /norestart /l*v `"$log`"")
  $p.WaitForExit()
  return $p.ExitCode
}

function Install-Release([string]$cosign, [string]$tag) {
  $core = $tag.Substring(1) -replace '-.*$', ''
  $u = "$($BaseUrl.TrimEnd('/'))/releases/$tag/windows/auspex_$($tag.Substring(1))_windows_$(Get-WindowsArch).msi"
  $msi = Join-Path $Staging 'auspex.msi'
  Fetch $u $msi
  Fetch "$u.cosign.bundle" "$msi.cosign.bundle"
  Invoke-CosignVerify $cosign $msi "$msi.cosign.bundle" (Get-ReleaseIdentityRe $tag) $u
  $log = Join-Path $StateDir 'msiexec.log'
  $rc = Invoke-Msiexec $msi $log
  # 3010: installed, and Windows wants a restart for some file; auspex itself is running.
  if ($rc -ne 0 -and $rc -ne 3010) { Stop-Update 22 "msiexec failed for auspex $tag with exit $rc; see $log" }
  $got = Get-InstalledMsiVersion
  if ($got -ne $core) { Stop-Update 23 "installed auspex $tag, but Windows Installer reports $(if ($got) { $got } else { 'no version' })" }
  [IO.File]::WriteAllText((Join-Path $StateDir 'installed'), "$tag`n")
}

function Invoke-Update {
  if (-not (Test-Elevated)) { Stop-Update 16 'run as SYSTEM or an administrator, from an MDM' }
  if (@('stable', 'latest') -cnotcontains $Channel) { Stop-Update 2 "the channel must be stable or latest, not $Channel" }
  if (-not $BaseUrl) { Stop-Update 2 'set the base URL to your auspex download host (https://...), from your install instructions' }
  if (-not (Test-AllowedUrl $BaseUrl)) { Stop-Update 2 "the base URL must be an https URL, not $BaseUrl" }

  Initialize-StateDir
  if (-not (Lock-State)) {
    Write-Result 'another run is in progress; nothing to do'
    return
  }
  if (Test-Path -LiteralPath $Staging) { Remove-Item -LiteralPath $Staging -Recurse -Force }
  New-Item -ItemType Directory -Path $Staging | Out-Null

  $cosign = Get-Cosign
  $doc = Read-Channel $cosign
  $installed = Get-InstalledTag
  $action, $target = (Get-UpdateDecision $doc $Channel $installed) -split ' ', 2
  switch ($action) {
    'none' { Write-Result "the $Channel channel names no release; nothing to do" }
    'prerelease' { Stop-Update 20 "the stable channel names a pre-release ($target); refusing to install it" }
    'below-minimum' { Stop-Update 20 "the $Channel channel names $target, below the minimum; refusing to install it" }
    'current' { Write-Result "auspex $target is up to date with $Channel" }
    'ahead' { Write-Result "auspex $installed is ahead of $Channel ($target); nothing to do" }
    default {
      Install-Release $cosign $target
      Write-Result "installed auspex $target from $Channel (was $(if ($installed) { $installed } else { 'not installed' }))"
    }
  }
}

$code = 0
try {
  Invoke-Update
} catch {
  $code = 1
  if ($_.Exception.Data.Contains('AuspexCode')) { $code = $_.Exception.Data['AuspexCode'] }
  Write-Result $_.Exception.Message
} finally {
  if ($script:Lock) {
    Remove-Item -LiteralPath $Staging -Recurse -Force -ErrorAction SilentlyContinue
    $script:Lock.Dispose()
  }
}
if ($code -ne 0) {
  Write-Result "failed with code $code (codes: mdm/README.md)"
  exit 1
}
exit 0
