# reproduce-reset-unread.ps1 - Codex 2.2.14 review R1 (official reset target selection), adapted to run from the repo and ASSERT
# the safe outcome. The recorder logged in but its channel list could not be read (the scan keeps channelsRead = $false): the camera it
# records must NOT become an official-reset target (the reset changes its password), and the unread NVR is a problem line.
param([string]$Repo = (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))))
$ErrorActionPreference = 'Stop'
. (Join-Path $Repo 'Toolkit/FixSiteCore.ps1')
$pass = 0; $fail = 0
function Check([string]$what, [bool]$ok) { if ($ok) { $script:pass++; Write-Output ('PASS ' + $what) } else { $script:fail++; Write-Output ('FAIL ' + $what) } }
function New-Obs([bool]$read, $chs) {
  [pscustomobject]@{
    pc = [pscustomobject]@{ ip = '192.168.1.105'; gw = '192.168.1.1'; prefix = 24; mask = '255.255.255.0' }
    devices = @([pscustomobject]@{ kind = 'camera'; ip = '192.168.1.50'; mac = 'c4:2f:90:00:01:50'; brand = 'Hikvision'; model = 'DS-2CD'; serial = 'CAM50'; login = 'unknown'; answers = $true; activated = $true })
    nvrs = @([pscustomobject]@{ ip = '192.168.1.19'; brand = 'Hikvision'; login = 'site password'; channels = @($chs); channelsRead = $read })
  }
}
$list = [pscustomobject]@{ scheme = '192.168.1'; cameras = @([pscustomobject]@{ name = 'Gate'; mac = 'c4:2f:90:00:01:50'; ip = '192.168.1.50'; nvr = '192.168.1.19'; channel = 1 }) }
# the production representation after the recorder list read fails: logged in, no channels, channelsRead = $false
$p = New-FsPlan $list (New-Obs $false @())
$r = Get-FsHikResetTargets $p @{ '192.168.1.19' = 'known' } { param($ip) 'ok' }
'REPRO=' + (@{ targets = $r.targets; blocked = @($r.blocked | ForEach-Object { $_.why }); steps = $p.cams[0].steps } | ConvertTo-Json -Depth 5 -Compress)
Check 'unread channel list: the camera is NOT an official-reset target' (-not @($r.targets | Where-Object { $_.kind -eq 'camera' }).Count)
Check 'unread channel list: the camera is blocked with a plain reason' (@($r.blocked).Count -eq 1 -and [string]$r.blocked[0].why -match 'channel list')
Check 'unread channel list: the NVR is a problem line (NOT CHECKED), never a clean result' (@(Get-FsManualLines $p | Where-Object { $_ -match '192\.168\.1\.19' -and $_ -match 'NOT CHECKED' }).Count -eq 1)
Check 'unread channel list: the address move guard refuses too' ([string](Get-FsMoveBlock $p.cams[0]) -match 'channel list')
# control: the same recorder WITH its list read (one channel, this camera) - the camera is still a reset target (the guard is not too wide)
$p2 = New-FsPlan $list (New-Obs $true @([pscustomobject]@{ channel = 1; ip = '192.168.1.50'; online = $false; name = 'Gate' }))
$r2 = Get-FsHikResetTargets $p2 @{ '192.168.1.19' = 'known' } { param($ip) 'ok' }
Check 'control: list read, one channel: the camera is a reset target' (@($r2.targets | Where-Object { $_.kind -eq 'camera' }).Count -eq 1)
Write-Output ('' + $pass + ' passed, ' + $fail + ' failed')
if ($fail) { exit 1 } else { exit 0 }
