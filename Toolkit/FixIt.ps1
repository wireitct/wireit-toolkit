<#
FixIt.ps1 - WireIt Toolkit Release C fix buttons (Nov 3 2026). UNTESTED ON REAL GEAR (mock devices only).
Runs ONE fix in its own window so passwords are typed hidden here. Each fix: shows the plan, saves a backup/export first,
changes something ONLY after you type YES (capital letters). Passwords are never saved or logged.
  -Fix recording   turn recording back on (Hikvision NVR / DW)          -Ip = recorder
  -Fix restart     reboot one camera (Hikvision / Uniview), 1/hour 2/day -Ip = camera
  -Fix readd       put a camera back on its NVR channel (Hikvision NVR)  -Ip = NVR, -Channel, -CameraIp
  -Fix firmware    one device, official file + SHA-256 (Hikvision)       -Ip = device, -File, -Sha256
  -Fix password    set the site password, typed twice (Hikvision)        -Ip = device
  -Fix dwpassword  give DW the camera's right password                   -Ip = DW server, -CameraIp
  (time server: the existing "Fix clock (NTP)" button)
A history line (logs\fix-history.txt, and the result for the site page) is written ONLY when a fix actually ran.
#>
param(
  [Parameter(Mandatory)][ValidateSet('recording', 'restart', 'readd', 'firmware', 'password', 'dwpassword')][string]$Fix,
  [Parameter(Mandatory)][string]$Ip, [ValidateSet('Auto', 'Hikvision', 'Uniview', 'DW', 'Onvif')][string]$Vendor = 'Auto', [int]$Port = 0,
  [int]$Channel = 0, [string]$CameraIp = '', [string]$File = '', [string]$Sha256 = '', [string]$Site = '',
  [string]$RunsDir = '', [string]$MockUrl = '', [string]$TestAnswer = '', [int]$CloseAfter = 8, [int]$WaitSec = 180, [string]$LogsDir = ''
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'ToolkitCore.ps1')
$names = @{ recording = 'Turn recording back on'; restart = 'Restart camera'; readd = 'Put camera back on the NVR'; firmware = 'Update firmware (one device)'; password = 'Set the site password'; dwpassword = 'Fix the camera password in DW' }
try { $Host.UI.RawUI.WindowTitle = 'WireIt Toolkit - ' + $names[$Fix] + ' - ' + $Ip } catch {}
if (-not $RunsDir) { $RunsDir = Join-Path $here 'runs' }
$run = Join-Path $RunsDir ('Fix-' + $Fix + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss')); New-Item -ItemType Directory -Force -Path $run | Out-Null
$log = Join-Path $run 'log.txt'
if (-not $LogsDir) { $LogsDir = Join-Path $here 'logs' }; New-Item -ItemType Directory -Force -Path $LogsDir | Out-Null
function Say2([string]$s, [string]$color = '') { if ($color) { Write-Host $s -ForegroundColor $color } else { Write-Host $s }; [void](Add-TkLine $log ((Get-Date -Format 'HH:mm:ss') + ' SAY ' + $s)) }
function Done([int]$code) { if ($CloseAfter -gt 0) { Write-Host ''; Write-Host ('Done. This window closes in ' + $CloseAfter + ' seconds.'); Start-Sleep -Seconds $CloseAfter }; exit $code }
Import-Module (Join-Path $here 'modules\NvrHealth\NvrHealth.psm1') -Force
Set-NvrHealthOption LogFile $log
if ($MockUrl) { Set-NvrHealthOption MockUrl $MockUrl }
Say2 ('=== ' + $names[$Fix] + ' - ' + $Ip + ' ===') 'Cyan'
Say2 'Nothing changes unless you type YES in this window. A backup is saved first. Not yet tested on real equipment.' 'Yellow'
$test = [bool]($TestAnswer -and $MockUrl)
function TestCred([string]$envName) { return New-Object PSCredential('admin', (ConvertTo-SecureString ([Environment]::GetEnvironmentVariable($envName)) -AsPlainText -Force)) }
function Ask-New([string]$what, [switch]$Twice) {
  if ($test) { return (TestCred 'FIXIT_TEST_NEWPW') }
  $a = Read-Host ('New ' + $what + ' - type it') -AsSecureString
  if ($Twice) { $b = Read-Host ('Type it again') -AsSecureString
    $p1 = (New-Object PSCredential('x', $a)).GetNetworkCredential().Password; $p2 = (New-Object PSCredential('x', $b)).GetNetworkCredential().Password
    $same = ($p1 -ceq $p2); $p1 = $null; $p2 = $null
    if (-not $same) { Say2 'The two passwords are not the same. Nothing changed.' 'Red'; return $null } }
  return New-Object PSCredential('admin', $a)
}
$code = 0; $r = $null
try {
  $cred = $(if ($test) { TestCred 'NVRCHECK_TEST_PW' } else { Read-NvrCredential $(if ($Fix -eq 'dwpassword') { 'the DW server at ' + $Ip } else { 'the device at ' + $Ip + ' (current password)' }) })
  $new = $null
  if ($Fix -eq 'password') { $new = Ask-New 'site password' -Twice }
  elseif ($Fix -in @('readd', 'dwpassword')) { $new = Ask-New ('camera password for ' + $CameraIp) }
  $p = @{ Fix = $Fix; Ip = $Ip; Vendor = $Vendor; Credential = $cred; Port = $Port; BackupDir = (Join-Path $run 'backup'); StateFile = (Join-Path $LogsDir 'fix-limits.json'); WaitSec = $WaitSec }
  if ($new) { $p.NewCredential = $new }; if ($Channel) { $p.Channel = $Channel }; if ($CameraIp) { $p.CameraIp = $CameraIp }; if ($File) { $p.File = $File }; if ($Sha256) { $p.Sha256 = $Sha256 }
  $p.Confirm = $(if ($test) { [scriptblock]::Create('param($plan) return ' + "'" + $TestAnswer.Replace("'", "''") + "'") } else { { param($plan) Write-Host ''; Read-Host 'Type YES (capital letters) to do this now, anything else = no change' } })
  $r = Invoke-NvrFix @p
  if (-not $r.ok) { $code = 4 }
} catch { Say2 ('PROBLEM ' + $_.Exception.Message) 'Red'; $code = 1 }
$hist = ''
if ($r -and $r.ran -and $r.history) {
  $hist = (Get-Date -Format 'yyyy-MM-dd HH:mm') + ' | ' + $env:COMPUTERNAME + ' | ' + $(if ($Site) { $Site } else { '-' }) + ' | ' + $r.history
  [void](Add-TkLine (Join-Path $LogsDir 'fix-history.txt') $hist)
}
$out = [ordered]@{ fix = $Fix; ip = $Ip; site = $Site; code = $code; ran = [bool]($r -and $r.ran); ok = [bool]($r -and $r.ok); msg = $(if ($r) { $r.msg } else { '' }); history = $hist; backup = $(if ($r) { $r.backup } else { '' }) }
Save-TkJson ([pscustomobject]$out) (Join-Path $run 'result.json'); Save-TkJson ([pscustomobject]$out) (Join-Path $LogsDir 'fix-last.json')
Done $code
