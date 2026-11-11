# reproduce-reset-second-unread.ps1 - Codex 2.2.15 review F1 (official reset target selection), adapted to run from the repo and ASSERT
# the safe outcome. The camera's own recorder .19 WAS read (one channel, this camera); a second NVR .20 logged in but its channel list
# could not be read (channelsRead = $false). .20 may record the camera too, so the camera must NOT become an official-reset target
# (the reset changes its password), its password change and move are refused, .20 is a NOT CHECKED problem line, and the problem line
# does not claim the cameras kept their password and address. Control: with .20 read (no channel for this camera), it is a target.
param([string]$Repo = '')
$ErrorActionPreference = 'Stop'
if (-not $Repo) { $Repo = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path }
. (Join-Path $Repo 'Toolkit/FixSiteCore.ps1')
$pass = 0; $fail = 0
function Check([string]$what, [bool]$ok) { if ($ok) { $script:pass++; Write-Output ('PASS ' + $what) } else { $script:fail++; Write-Output ('FAIL ' + $what) } }
function New-Obs([bool]$read20, $chs20) {
  [pscustomobject]@{
    pc = [pscustomobject]@{ ip = '192.168.1.105'; gw = '192.168.1.1'; prefix = 24; mask = '255.255.255.0' }
    devices = @([pscustomobject]@{ kind = 'camera'; ip = '192.168.1.50'; mac = 'c4:2f:90:00:01:50'; brand = 'Hikvision'; model = 'DS-2CD'; serial = 'CAM50'; login = 'unknown'; answers = $true; activated = $true })
    nvrs = @([pscustomobject]@{ ip = '192.168.1.19'; brand = 'Hikvision'; login = 'site password'; channels = @([pscustomobject]@{ channel = 1; ip = '192.168.1.50'; online = $false; name = 'Gate' }); channelsRead = $true },
             [pscustomobject]@{ ip = '192.168.1.20'; brand = 'Hikvision'; login = 'site password'; channels = @($chs20); channelsRead = $read20 })
  }
}
$list = [pscustomobject]@{ scheme = '192.168.1'; cameras = @([pscustomobject]@{ name = 'Gate'; mac = 'c4:2f:90:00:01:50'; ip = '192.168.1.50'; nvr = '192.168.1.19'; channel = 1 }) }
$cred = @{ '192.168.1.19' = 'known'; '192.168.1.20' = 'known' }
$p = New-FsPlan $list (New-Obs $false @())
$r = Get-FsHikResetTargets $p $cred { param($ip) 'ok' }
$cam = @($p.cams | Where-Object { $_.mac -eq 'c4:2f:90:00:01:50' })[0]
$man = @(Get-FsManualLines $p)
'REPRO=' + (@{ targets = $r.targets; blocked = @($r.blocked | ForEach-Object { $_.why }); unknown = @($cam.chUnknown); manual = $man } | ConvertTo-Json -Depth 6 -Compress)
Check '.19 read, .20 unread: the camera is NOT an official-reset target' (-not @($r.targets | Where-Object { $_.kind -eq 'camera' }).Count)
Check '.19 read, .20 unread: the camera is blocked with a plain reason naming .20' (@($r.blocked).Count -eq 1 -and [string]$r.blocked[0].why -match '192\.168\.1\.20')
Check '.19 read, .20 unread: .20 is an unresolved dependency of the camera' (@($cam.chUnknown) -contains '192.168.1.20')
Check '.19 read, .20 unread: password change refused' ([string](Get-FsPwChangeBlock $cam @(Get-FsCamRecorders $cam) $cred) -match '192\.168\.1\.20')
Check '.19 read, .20 unread: address move refused' ([string](Get-FsMoveBlock $cam) -match '192\.168\.1\.20')
Check '.19 read, .20 unread: .20 is a NOT CHECKED problem line' (@($man | Where-Object { $_ -match '192\.168\.1\.20' -and $_ -match 'NOT CHECKED' }).Count -eq 1)
Check 'the problem line does not claim cameras "kept their password and address"' (-not @($man | Where-Object { $_ -match 'kept their password and address' }).Count)
$p2 = New-FsPlan $list (New-Obs $true @())
$r2 = Get-FsHikResetTargets $p2 $cred { param($ip) 'ok' }
Check 'control: .20 read too (no channel for this camera): the camera is a reset target' (@($r2.targets | Where-Object { $_.kind -eq 'camera' }).Count -eq 1)
Write-Output ('' + $pass + ' passed, ' + $fail + ' failed')
if ($fail) { exit 1 } else { exit 0 }
