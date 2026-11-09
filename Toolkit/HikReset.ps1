<#
 HikReset.ps1 - WireIt Toolkit 2.2: Hikvision's OFFICIAL password reset for every Hik device with an unknown password (NVR and cameras, any subnet).
 Same path as SADP's "Forgot password": the device gives its request file, Hikvision's own page returns an unlock file by email, SADP's import sets the new password.
 No guessing, no default passwords, no exploits. Nothing is power-cycled and no reset button is touched.
 Modes:
   Run      find -> export -> fill Hikvision's page (you type the picture code) -> wait for the reply -> import -> check the login   (default)
   Find     list every Hik device on any subnet (model, serial, MAC, IP, firmware, activated?)
   Export   make the request files only
   Submit   fill Hikvision's page for every exported file (needs your picture code, once per device)
   Watch    look for Hikvision's reply now (reply relay + replies folder + inbox\hik); -WaitMinutes N keeps looking
   Import   apply the replies that have arrived (needs -PasswordFile or a typed password)
   Status   where every device stands
 -RegisterDir <folder>   use request files that already exist (SADP/HiTools exports) instead of asking the devices again.
 State: <StateDir>\state.json - stop any time, run again, it carries on.
#>
param(
  [ValidateSet('Run', 'Find', 'Export', 'Submit', 'Watch', 'Import', 'Status')][string]$Mode = 'Run',
  [string]$StateDir = '', [string]$ConfigPath = '', [string]$RegisterDir = '', [string]$PasswordFile = '',
  [int]$WaitMinutes = 0, [string]$Only = '', [switch]$Redo, [string]$Site = '', [string]$SiteSecretsDir = '',
  [string]$SadpTest = '', [string]$PortalUrlOverride = ''
)
$ErrorActionPreference = 'Continue'; $ProgressPreference = 'SilentlyContinue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'HikResetFlow.ps1')
. (Join-Path $here 'FixSiteCore.ps1')   # 2.2.7 (Codex file-by-file F14): Read-FsSecrets needs Get-FsSiteSlug and the rest of the core
. (Join-Path $here 'FixSiteDevices.ps1')
if ($SadpTest) { $script:SadpTest = $SadpTest }
if ($PortalUrlOverride) { $script:PortalUrl = $PortalUrlOverride }
if (-not $ConfigPath) { $ConfigPath = Join-Path $here 'config.json' }
$cfgAll = $null; if (Test-Path $ConfigPath) { try { $cfgAll = Get-Content $ConfigPath -Raw | ConvertFrom-Json } catch {} }
$cfg = Get-HikConfig $cfgAll $here   # 2.2.0: the reply relay (no mail password on this PC) + the inbox\hik drops
$inboxDir = Join-Path $here 'inbox\hik'
if (-not $cfg.form) { Write-Host 'config.json has no "form" (name, email, company ...). Cannot fill Hikvision''s page.' -ForegroundColor Red; exit 2 }
if (-not $StateDir) { $StateDir = Join-Path (Join-Path $here 'runs') 'HikReset' }
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
$statePath = Join-Path $StateDir 'state.json'; $reqDir = Join-Path $StateDir 'requests'; $repDir = Join-Path $StateDir 'replies'; $secDir = Join-Path $here 'vault'
$script:FsLegacySecretsDir = Join-Path $here 'secrets'   # 2.2.3 (Codex #47): the installer moved site passwords to vault\ (secrets\ = old PCs)
$logFile = Join-Path $StateDir 'hikreset.log'
$script:SadpLog = { param($l) try { Add-Content -LiteralPath $logFile -Value ((Get-Date -Format 's') + ' ' + $l) } catch {} }
$script:HkSay = { param($t, $c) $col = switch ($c) { 'Green' { 'Green' } 'Yellow' { 'Yellow' } 'Red' { 'Red' } 'Cyan' { 'Cyan' } default { 'Gray' } }; Write-Host $t -ForegroundColor $col; try { Add-Content -LiteralPath $logFile -Value ((Get-Date -Format 's') + ' ' + $t) } catch {} }
$state = Read-HikState $statePath
function Show-Devices($devs) {
  foreach ($d in $devs) { Hk-Say ('{0,-6} {1,-14} {2,-18} {3,-17} {4,-16} {5}  {6}' -f $d.kind, $d.model, $d.serial, $d.mac, $d.ip, $d.firmware.Split(' ')[0], $(if ($d.activated) { 'activated (password set)' } else { 'NOT activated' })) }
}
if ($Mode -eq 'Status') { Format-HikStatus $state | ForEach-Object { Write-Host $_ }; exit 0 }
if ($Mode -in @('Run', 'Find', 'Export')) {
  Hk-Say 'Looking for Hikvision devices on every network this PC is plugged into (any IP range)...' 'Cyan'
  $devs = @(Find-HikSadp 4)
  if ($Only) { $devs = @($devs | Where-Object { $_.serial -like ('*' + $Only + '*') -or $_.ip -eq $Only -or $_.mac -eq $Only }) }
  Hk-Say ('Found ' + $devs.Count + ' Hikvision device(s):')
  Show-Devices $devs
  if ($Mode -eq 'Find') { exit 0 }
  if ($RegisterDir) { Hk-Say ('Using the request files already in ' + $RegisterDir); [void](Register-HikRequestFiles $state $RegisterDir $devs $statePath) }
  else { Hk-Say 'Asking each device for its password-reset request file (the same step as SADP "Forgot password > Export file")...' 'Cyan'; [void](Export-HikRequests $devs $reqDir $state $statePath -Redo:$Redo) }
  if ($Mode -eq 'Export') { Format-HikStatus $state | ForEach-Object { Write-Host $_ }; exit 0 }
}
# 2.2.3 (Codex #58): -Only limits EVERY stage: the submission sees only the matching saved devices (old pending ones stay out)
$onlySerials = $null; if ($Only) { $onlySerials = @(@($state.devices) | Where-Object { [string]$_.serial -like ('*' + $Only + '*') -or [string]$_.ip -eq $Only -or [string]$_.mac -eq $Only } | ForEach-Object { [string]$_.serial }) }
if ($Mode -in @('Run', 'Submit')) { Hk-Say 'Hikvision''s reset page' 'Cyan'; [void](Submit-HikRequests $state $statePath (Get-HikFormFor $cfg) 900 $onlySerials) }
if ($Mode -in @('Run', 'Watch')) {
  $end = (Get-Date).AddMinutes($WaitMinutes)
  do {
    $r = Receive-HikReplies $state $statePath $cfg $here $repDir $inboxDir
    Show-HikReplyNotes $r   # 2.2.8: skipped / stale / unmatched files, each with its reason, said once
    $left = @($state.devices | Where-Object { $_.status -eq 'submitted' })
    if (-not $left.Count -or (Get-Date) -ge $end) { break }
    $wl = Format-HikWaitLine $cfg $left.Count ([math]::Max(0, [int][math]::Ceiling(($end - (Get-Date)).TotalMinutes)))
    Hk-Say ('  ' + $wl.text) $wl.color
    Start-Sleep -Seconds 60
  } while ($true)
}
if ($Mode -in @('Run', 'Import')) {
  $pw = ''; if ($PasswordFile -and (Test-Path $PasswordFile)) { $pw = (Get-Content -LiteralPath $PasswordFile -Raw).Trim() }
  # 2.1.0: the site's own password from Fix this site's encrypted store on this PC (never typed, never shown)
  # 2.2.7 (Codex file-by-file F14): a store that cannot be read is said as that error (exit 3), not hidden as "no site password saved"
  if (-not $pw -and $Site) { if (-not $SiteSecretsDir) { $SiteSecretsDir = $secDir }; try { $pw = [string](Read-FsSecrets $SiteSecretsDir $Site).password } catch { Hk-Say ('Could not read this PC''s saved site passwords (' + $_.Exception.Message + '). Nothing was changed.') 'Red'; exit 3 }; if (-not $pw) { Hk-Say ('No site password saved on this PC for "' + $Site + '". Make it in Fix this site (Site password... > M) first.') 'Red'; exit 3 } }
  if (@($state.devices | Where-Object { $_.status -eq 'replied' }).Count) {
    if (-not $pw) { $sec = Read-Host 'Type the new password for these devices (hidden)' -AsSecureString; $pw = (New-Object PSCredential('x', $sec)).GetNetworkCredential().Password }
    $verify = { param($ip, $p) return ((Test-FsLogin $ip 'Hikvision' $p) -eq 'ok') }
    [void](Import-HikReplies $state $statePath $pw $verify $Only)
  }
}
Hk-Say ''
Hk-Say 'Where each device stands:' 'Cyan'
Format-HikStatus $state | ForEach-Object { Hk-Say ('  ' + $_) }
