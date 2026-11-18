# auspex MDM scheduled update loader (Windows). Paste it whole into your MDM, such as an Intune Remediation's
# detection script, and run it as SYSTEM on a schedule. Each run runs the auspex-scheduled-update.ps1 it pins only
# if its SHA-256 matches, downloading it only when the cached copy is missing or stale. To update, paste a newer
# release's.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# --- Settings: edit these two lines ---
$AuspexBaseUrl = ''       # required: your auspex download host (https://...), from your install instructions
$AuspexChannel = 'stable' # stable (the default) or latest

# --- The pinned script (filled in by the release; do not edit) ---
$ScriptUrl = 'https://github.com/Attuned-Corp/auspex-distribution/releases/download/@TAG@/auspex-scheduled-update.ps1'
$ScriptSha256 = '@SHA256@'

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$StateDir = if ($env:AUSPEX_UPDATE_STATE_DIR) { $env:AUSPEX_UPDATE_STATE_DIR } else { 'C:\ProgramData\auspex-update' }
function Fail([int]$code, [string]$msg) { # Intune counts only exit 1 as a problem
  Write-Host "auspex update: $msg"
  Write-Host "auspex update: failed with code $code (codes: mdm/README.md)"
  exit 1
}
function Get-Sha256Hex([byte[]]$b) { -join ([Security.Cryptography.SHA256]::Create().ComputeHash($b) | ForEach-Object { $_.ToString('x2') }) }
function Test-StateDir { # the cache lives only in a state folder the script accepts: SYSTEM and Administrators only, not a link
  $d = Get-Item -LiteralPath $StateDir -Force -ErrorAction SilentlyContinue
  if (-not $d -or -not $d.PSIsContainer -or ($d.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $false }
  $acl = Get-Acl -LiteralPath $StateDir
  $ok = @('S-1-5-18', 'S-1-5-32-544')
  $acl.AreAccessRulesProtected -and ($ok -contains $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value) -and
    @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object { $ok -notcontains $_.IdentityReference.Value }).Count -eq 0
}
$cache = Join-Path $StateDir 'scheduled-update.ps1'
# The hash is checked on the bytes this run executes, held in memory, so nothing can change between the two.
$bytes = $null
if ((Test-StateDir) -and (Test-Path -LiteralPath $cache -PathType Leaf)) { $bytes = [IO.File]::ReadAllBytes($cache) }
if ($null -eq $bytes -or (Get-Sha256Hex $bytes) -ne $ScriptSha256) {
  if ($ScriptUrl -notmatch '^https://') { Fail 11 "refusing to download over a non-https URL: $ScriptUrl" }
  try { $bytes = (Invoke-WebRequest -UseBasicParsing -MaximumRedirection 5 -TimeoutSec 300 -Uri $ScriptUrl).RawContentStream.ToArray() }
  catch { Fail 11 "could not download $ScriptUrl" }
  $got = Get-Sha256Hex $bytes
  if ($got -ne $ScriptSha256) { Fail 12 "the downloaded script has SHA-256 $got, not the pinned $ScriptSha256; running nothing" }
  if (Test-StateDir) { try { [IO.File]::WriteAllBytes($cache, $bytes) } catch { } }
}
& ([scriptblock]::Create([Text.Encoding]::UTF8.GetString($bytes))) -BaseUrl $AuspexBaseUrl -Channel $AuspexChannel
