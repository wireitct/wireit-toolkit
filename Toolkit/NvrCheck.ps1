<#
NvrCheck.ps1 - WireIt Toolkit buttons 9-12 (recorder health). Runs NvrHealth (modules\NvrHealth) in its own window
so the recorder password is typed hidden there; everything it says goes to runs\Nvr<Mode>-<time>\log.txt, which the
Toolkit shows live.
  -Mode Recording  read-only: every camera recording? days of footage vs. the site's target, hard drives + health
  -Mode Clock      read-only: recorder (and camera) clocks vs. real time, time server on, US Eastern + DST
  -Mode FixClock   THE ONLY WRITE: shows the plan first (what-if, nothing changes); changes the time settings only
                   after you type YES in this window. Anything else = nothing changes.
  -Mode Firmware   read-only: firmware vs. the newest published + known security holes. Reports only, never updates.
No password is saved or logged.
#>
param(
  [Parameter(Mandatory)][ValidateSet('Recording', 'Clock', 'FixClock', 'Firmware')][string]$Mode,
  [Parameter(Mandatory)][string]$Ip,
  [string]$Site = '', [int]$Days = 0, [switch]$Cameras,
  [ValidateSet('Auto', 'Hikvision', 'Uniview', 'DW', 'Onvif')][string]$Vendor = 'Auto', [int]$Port = 0,
  [string]$RunsDir = '', [string]$MockUrl = '', [string]$TestAnswer = '', [int]$CloseAfter = 8
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'ToolkitCore.ps1')
$titles = @{ Recording = 'Recording check'; Clock = 'Clock check'; FixClock = 'Fix clock (NTP)'; Firmware = 'Firmware / security check' }
try { $Host.UI.RawUI.WindowTitle = 'WireIt Toolkit - ' + $titles[$Mode] + ' - ' + $Ip } catch {}
if (-not $RunsDir) { $RunsDir = Join-Path $here 'runs' }
$run = Join-Path $RunsDir ('Nvr' + $Mode + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $run | Out-Null
$log = Join-Path $run 'log.txt'
function Say2([string]$s, [string]$color = '') { if ($color) { Write-Host $s -ForegroundColor $color } else { Write-Host $s }; Add-Content -Path $log -Value ((Get-Date -Format 'HH:mm:ss') + ' SAY ' + $s) }
function Done([int]$code) {
  if ($CloseAfter -gt 0) { Write-Host ''; Write-Host ('Done. The results are in the Toolkit window. This window closes in ' + $CloseAfter + ' seconds.'); Start-Sleep -Seconds $CloseAfter }
  exit $code
}

$mod = Join-Path $here 'modules\NvrHealth\NvrHealth.psm1'
if (-not (Test-Path $mod)) { Say2 'PROBLEM The NvrHealth module is missing (modules\NvrHealth). Use "Check for update" in the Toolkit.' 'Red'; Done 2 }
Import-Module $mod -Force
Set-NvrHealthOption LogFile $log
$ref = Get-TkNvrReference $here
if ($ref) { Set-NvrHealthOption ReferenceFile $ref }
if ($MockUrl) { Set-NvrHealthOption MockUrl $MockUrl }
if ($Days -gt 0) { Set-NvrHealthOption TargetDays $Days }

Say2 ('=== ' + $titles[$Mode] + ' - ' + $Ip + $(if ($Site) { ' (' + $Site + ')' } else { '' }) + ' ===') 'Cyan'
if ($Mode -eq 'Recording') { Say2 ('Target: ' + $(if ($Days -gt 0) { $Days } else { (Get-NvrHealthOption).TargetDays }) + ' days of footage' + $(if ($Site) { ' for ' + $Site } else { '' }) + '.') }
if ($Mode -eq 'FixClock') { Say2 'Step 1 shows what would change. NOTHING changes unless you type YES in this window.' 'Yellow' }

if ($TestAnswer -and $MockUrl) { $cred = New-Object PSCredential('admin', (ConvertTo-SecureString ($env:NVRCHECK_TEST_PW) -AsPlainText -Force)) }   # test harness only
else { $cred = Read-NvrCredential ('the recorder at ' + $Ip) }
$common = @{ Ip = $Ip; Vendor = $Vendor; Credential = $cred; Port = $Port }
$code = 0
try {
  Set-NvrHealthOption LogFile $log
  switch ($Mode) {
    'Recording' { $r = Get-RecordingStatus @common -TargetDays $Days }
    'Clock'     { $r = Get-ClockStatus @common -IncludeCameras:$Cameras }
    'Firmware'  { $r = Get-FirmwareStatus @common -IncludeCameras:$Cameras }
    'FixClock' {
      $plan = Set-NtpTime @common -IncludeCameras:$Cameras -WhatIf
      $todo = @($plan.devices | Where-Object { $_.result -eq 'what-if (not changed)' })
      if (-not $todo.Count) {
        Say2 ''; Say2 'Nothing to change: the time settings are already right (or could not be read, see above).'
        $r = $plan
      } else {
        Write-Host ''
        Write-Host ('Type YES (capital letters) and Enter to change the time settings on ' + $todo.Count + ' device(s). Anything else = no change.') -ForegroundColor Yellow
        $ans = $(if ($TestAnswer) { $TestAnswer } else { Read-Host 'Change them now?' })
        if ($ans -ceq 'YES') {
          Say2 ''; Say2 'You typed YES. Changing the time settings now...'
          $r = Set-NtpTime @common -IncludeCameras:$Cameras -WhatIf:$false -Confirm:$false
        } else {
          Say2 ''; Say2 'Not confirmed (you did not type YES). Nothing was changed.'
          $r = $plan; $code = 0
        }
      }
    }
  }
  if ($r -and $r.PSObject.Properties['failed'] -and $r.failed) { $code = 4 }
  elseif ($r -and $r.PSObject.Properties['problems'] -and @($r.problems).Count) {
    if (@($r.problems | Where-Object { $_ -match 'login refused|no answer|unreadable' }).Count) { $code = 2 } else { $code = 4 }
  }
} catch {
  Say2 ('PROBLEM ' + $_.Exception.Message) 'Red'; $code = 1
}
Set-Content -Path (Join-Path $run 'result.json') -Value (@{ mode = $Mode; ip = $Ip; site = $Site; days = $Days; code = $code; finished = (Get-Date -Format s) } | ConvertTo-Json)
Done $code
