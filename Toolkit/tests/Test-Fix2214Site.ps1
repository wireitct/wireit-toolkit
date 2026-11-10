<# Test-Fix2214Site.ps1 - WireIt Toolkit 2.2.14, Fix this site: Codex's 2.2.13 review findings F1, F2 and F8 (all P1).
   F1: a camera password change or address change guards, updates and verifies per recorder AND per CHANNEL: two channels of ONE
       NVR recording the camera = refused (Still a problem, nonzero exit), and a second channel of the camera without video is a
       problem (never "Still a problem: 0").
   F2: the Hikvision official reset/import changes the password, so every camera passes the same guard BEFORE it becomes a reset
       target (Get-FsHikResetTargets, the selection FixSite itself calls); a blocked camera is reported with its reason.
   F8: Undo of a channel replacement never puts the replacement camera's password on a DIFFERENT original camera; back = video on
       it again from the camera the saved channel names, otherwise "NOT confirmed" (by hand), nonzero exit, never "everything is back".
   Codex's reproductions as permanent tests: the real FixSite.ps1 against mock devices (fix2214site/scenarios.py, loopback only)
   and the real functions of FixSiteCore.ps1 in their own process.
   Moshe's rule: failing half-way, the wrong device, running twice (every FixSite scenario runs twice). Controls (marked "control")
   pass on old and new code. FIX2214_REPO = another checkout (e.g. the 2.2.13 head b6037f2) to prove these tests fail there.
   Windows PowerShell 5.1 or pwsh 7. #>
$ErrorActionPreference = 'Stop'
$tk = Split-Path -Parent $PSScriptRoot; $repo = Split-Path -Parent $tk
if ($env:FIX2214_REPO) { $repo = $env:FIX2214_REPO; $tk = Join-Path $repo 'Toolkit' }
$exe = $(if ($PSVersionTable.PSEdition -eq 'Core') { (Get-Process -Id $PID).Path } else { Join-Path $PSHOME 'powershell.exe' })
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fix2214site-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$script:pass = 0; $script:fail = 0; $script:deferred = 0
function Check([bool]$ok, [string]$name, [string]$more = '') {
  if ($ok) { $script:pass++; Write-Host ('PASS ' + $name) } else { $script:fail++; Write-Host ('FAIL ' + $name); if ($more) { Write-Host ('     ' + ($more -replace "`n", "`n     ")) } }
}
function Q([string]$s) { return "'" + $s.Replace("'", "''") + "'" }
function Invoke-Driver([string]$name, [string]$code) {
  $f = Join-Path $tmp ($name + '.ps1'); [IO.File]::WriteAllText($f, $code, (New-Object Text.UTF8Encoding($true)))
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $o = & $exe -NoProfile -ExecutionPolicy Bypass -File $f 2>&1 | Out-String } finally { $ErrorActionPreference = $prev }
  return $o
}
function Get-Json([string]$out) { $m = [regex]::Match($out, '(?m)^JSON=(\{.*\})\s*$'); if ($m.Success) { try { return ($m.Groups[1].Value | ConvertFrom-Json) } catch {} }; return $null }
function NoPw($puts, [string]$pw) { return (-not @($puts | Where-Object { [string]$_.pw -eq $pw }).Count) }
$load = ". " + (Q (Join-Path $tk 'FixSiteCore.ps1')) + "; . " + (Q (Join-Path $tk 'FixSiteDevices.ps1')) + "`n"
try {
  . (Join-Path $PSScriptRoot 'TestPython.ps1'); $py = Get-TestPython

  # =====================================================================================
  # F1 + F2: the real planner, the real guard and the real reset-target selection (no devices)
  $d = Invoke-Driver 'guard' ($load + @'
$ErrorActionPreference = 'Continue'
$o = @{}
$pc = [pscustomobject]@{ ip = '192.168.1.105'; gw = '192.168.1.1'; mask = '255.255.255.0'; prefix = 24; dhcp = $true }
function Obs($nvrs, $login = 'unknown') {
  $devs = @([pscustomobject]@{ kind = 'camera'; ip = '192.168.1.50'; mac = 'c4:2f:90:00:01:50'; brand = 'Hikvision'; model = 'DS-2CD2143G2-I'; serial = 'REVIEWCAM50'; login = $login; answers = $true; activated = $true },
             [pscustomobject]@{ kind = 'camera'; ip = '192.168.1.51'; mac = 'c4:2f:90:00:01:51'; brand = 'Hikvision'; model = 'DS-2CD2143G2-I'; serial = 'REVIEWCAM51'; login = 'site password'; answers = $true; activated = $true })
  foreach ($n in $nvrs) { $devs += [pscustomobject]@{ kind = 'nvr'; ip = $n.ip; brand = 'Hikvision'; model = 'DS-7608NI-K2'; login = 'site password' } }
  return [pscustomobject]@{ pc = $pc; devices = $devs; nvrs = @($nvrs) }
}
function N($ip, $chs) { return [pscustomobject]@{ ip = $ip; channels = @($chs | ForEach-Object { [pscustomobject]@{ channel = $_[0]; ip = $_[1]; online = $_[2] } }) } }
function Sel($obs, $cred, $live) {
  $plan = New-FsPlan $null $obs
  try { $r = Get-FsHikResetTargets $plan $cred $live } catch { return [pscustomobject]@{ err = 'NOFUNC'; ips = ''; blocked = ''; why = '' } }
  return [pscustomobject]@{ err = ''; ips = ((@($r.targets) | Where-Object { $_.kind -eq 'camera' } | ForEach-Object { $_.ip }) -join ','); blocked = ((@($r.blocked) | ForEach-Object { $_.ip }) -join ','); why = ((@($r.blocked) | ForEach-Object { $_.why }) -join ' | ') }
}
$cr2 = @{ '192.168.1.19' = 'k'; '192.168.1.20' = 'k' }; $ok = { param($n) 'ok' }
# Codex repro (reset-target): primary ch on .19 offline, .20 still has video
$o.repro = Sel (Obs @((N '192.168.1.19' @(,@(1, '192.168.1.50', $false))), (N '192.168.1.20' @(,@(1, '192.168.1.50', $true))))) $cr2 $ok
$o.repro2 = Sel (Obs @((N '192.168.1.19' @(,@(1, '192.168.1.50', $false))), (N '192.168.1.20' @(,@(1, '192.168.1.50', $true))))) $cr2 $ok
# two channels of ONE NVR record the camera (one without video)
$o.twoch = Sel (Obs @((N '192.168.1.19' @(@(1, '192.168.1.50', $false), @(2, '192.168.1.50', $true))))) $cr2 $ok
# control: one NVR, one channel (no video), known login, answers: it IS a reset target
$o.one = Sel (Obs @((N '192.168.1.19' @(,@(1, '192.168.1.50', $false))))) $cr2 $ok
# failing half-way: that one NVR stops answering at the live check
$o.down = Sel (Obs @((N '192.168.1.19' @(,@(1, '192.168.1.50', $false))))) $cr2 { param($n) 'timeout' }
# wrong device (control): ch 1 of the NVR is ANOTHER camera (.51, online), ch 2 ours (no video): ours is ONE dependent -> target
$o.wrong = Sel (Obs @((N '192.168.1.19' @(@(1, '192.168.1.51', $true), @(2, '192.168.1.50', $false))))) $cr2 $ok
# its only NVR has no known login
$o.nologin = Sel (Obs @((N '192.168.1.19' @(,@(1, '192.168.1.50', $false))))) @{} $ok
# per-channel guard and move guard on the real planner's camera
$plan = New-FsPlan $null (Obs @((N '192.168.1.19' @(@(1, '192.168.1.50', $true), @(2, '192.168.1.50', $true)))) 'Oldpass')
$c = @($plan.cams | Where-Object { $_.ip -eq '192.168.1.50' })[0]
try { $o.chs = ((@(Get-FsCamChannels $c) | ForEach-Object { $_.nvr + '/' + $_.channel }) -join ',') } catch { $o.chs = 'NOFUNC' }
$o.pwblk = [string](Get-FsPwChangeBlock ([pscustomobject]@{ nvr = $c.nvr; channel = $c.channel; links = $c.links; steps = @('backup', 'password', 'nvr', 'verify') }) @(Get-FsCamRecorders $c) $cr2)
try { $o.mvblk = [string](Get-FsMoveBlock $c) } catch { $o.mvblk = 'NOFUNC' }
$plan = New-FsPlan $null (Obs @((N '192.168.1.19' @(@(1, '192.168.1.51', $true), @(2, '192.168.1.50', $true)))) 'Oldpass')
$c = @($plan.cams | Where-Object { $_.ip -eq '192.168.1.50' })[0]
$o.pwblkW = [string](Get-FsPwChangeBlock ([pscustomobject]@{ nvr = $c.nvr; channel = $c.channel; links = $c.links; steps = @('backup', 'password', 'nvr', 'verify') }) @(Get-FsCamRecorders $c) $cr2)
try { $o.mvblkW = [string](Get-FsMoveBlock $c) } catch { $o.mvblkW = 'NOFUNC' }
# a second channel of the camera with no video is a manual (problem) line
$plan = New-FsPlan $null (Obs @((N '192.168.1.19' @(@(1, '192.168.1.50', $true), @(2, '192.168.1.50', $false)))) 'site password')
$o.manual = ((@(Get-FsManualLines $plan)) -join ' | ')
$plan = New-FsPlan $null (Obs @((N '192.168.1.19' @(,@(1, '192.168.1.50', $true)))) 'site password')
$o.manual1 = ((@(Get-FsManualLines $plan)) -join ' | ')
'JSON=' + ($o | ConvertTo-Json -Compress -Depth 4)
'@)
  $j = Get-Json $d
  Check ($j -and $j.repro.err -eq '' -and $j.repro.ips -notmatch '192\.168\.1\.50' -and $j.repro.blocked -eq '192.168.1.50' -and $j.repro.why -match 'official reset NOT run' -and $j.repro.why -match '2 NVRs record this camera') 'F2 Codex repro: primary channel offline, a 2nd NVR still records it: the camera is NOT a reset target, blocked with the reason' $d
  Check ($j -and $j.repro2.blocked -eq '192.168.1.50' -and $j.repro2.ips -eq '') 'F2 ...running the selection twice gives the same honest answer' $d
  Check ($j -and $j.twoch.blocked -eq '192.168.1.50' -and $j.twoch.why -match '2 NVR channels record this camera') 'F2+F1 two channels of ONE NVR record it: NOT a reset target (per-channel rule)' $d
  Check ($j -and $j.one.ips -eq '192.168.1.50' -and $j.one.blocked -eq '') 'F2 control: one NVR, one channel, known login that answers: it IS a reset target (the guard is not too wide)' $d
  Check ($j -and $j.down.blocked -eq '192.168.1.50' -and $j.down.why -match 'does not answer right now') 'F2 failing half-way: its NVR does not answer at the live check: NOT reset' $d
  Check ($j -and $j.wrong.ips -eq '192.168.1.50' -and $j.wrong.blocked -eq '') 'F2 wrong device (control): another camera on ch 1 of the same NVR is not a dependent of ours: ours is a reset target' $d
  Check ($j -and $j.nologin.blocked -eq '192.168.1.50' -and $j.nologin.why -match 'login is unknown') 'F2 its only NVR has no known login: NOT reset' $d
  Check ($j -and $j.chs -eq '192.168.1.19/1,192.168.1.19/2') 'F1 the camera''s dependents are every CHANNEL (two on one NVR), not only every recorder' $d
  Check ($j -and $j.pwblk -match '2 NVR channels record this camera' -and $j.mvblk -match 'NOT moved: 2 NVR channels') 'F1 guard: two channels of ONE NVR = the password is NOT changed and the camera is NOT moved' $d
  Check ($j -and $j.pwblkW -eq '' -and $j.mvblkW -eq '') 'F1 wrong device (control): another camera on ch 1 does not block ours (one dependent channel)' $d
  Check ($j -and $j.manual -match 'NVR 192\.168\.1\.19 ch 2 also records this camera and has NO video') 'F1 a second channel of the camera with no video is a problem line (never OK)' $d
  Check ($j -and $j.manual1 -notmatch 'also records this camera') 'F1 control: one channel with video gives no problem line' $d

  # F2: FixSite itself uses the shared selection (no private copy of the old predicate)
  $fsSrc = [IO.File]::ReadAllText((Join-Path $tk 'FixSite.ps1'))
  Check ($fsSrc -match 'Get-FsHikResetTargets \$plan' -and $fsSrc -notmatch "ip = \`$c\.ip; kind = 'camera'") 'F2 FixSite.ps1 picks reset targets with Get-FsHikResetTargets (the tested production function), not its own predicate' ''

  # =====================================================================================
  # the real Fix this site and Undo, each scenario run twice
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  $scen = & $py (Join-Path $PSScriptRoot 'fix2214site/scenarios.py') --repo $repo --powershell $exe 2>&1 | Out-String
  $ErrorActionPreference = $prev
  $r = $null; try { $r = (($scen.Trim() -split "`n")[-1]) | ConvertFrom-Json } catch {}
  if (-not $r) { Check $false 'Fix this site scenarios ran' $scen }
  else {
    foreach ($n in 1, 2) {
      $tw = $(if ($n -eq 2) { ' (run twice: the 2nd run too)' } else { '' })
      $x = $r.('multi' + $n)
      Check ($x.pw -eq 'Oldpass123' -and $x.pwchanges -eq 0 -and $x.chans.'192.168.1.19'.'1'.pw -eq 'Oldpass123' -and $x.chans.'192.168.1.19'.'2'.pw -eq 'Oldpass123' -and $x.online.'192.168.1.19/1' -and $x.online.'192.168.1.19/2') ('F1 Codex repro: .19 ch 1 + ch 2 record camera .50, -PasswordAll: the password is NOT changed, both channels keep their video' + $tw) $x.out
      Check ($x.exit -ne 0 -and $x.problems -ge 1 -and $x.said_chans -and -not $x.said_pwset) ('F1 ...Still a problem, the tech is told both channels, nonzero exit (exit ' + $x.exit + ')' + $tw) $x.out
      $x = $r.('multioff' + $n)
      Check ($x.exit -ne 0 -and $x.problems -ge 1 -and $x.said_alsonovideo) ('F1 Codex 2nd-run repro: ch 1 has video, ch 2 of the same camera has none: a problem, nonzero exit - never "Still a problem: 0" (exit ' + $x.exit + ', problems ' + $x.problems + ')' + $tw) $x.out
      Check ($x.pwchanges -eq 0 -and $x.chans.'192.168.1.19'.'2'.pw -eq 'Oldpass123') ('F1 ...and nothing is written to the camera or ch 2 behind the tech''s back' + $tw) $x.out
      $x = $r.('multimove' + $n)
      Check ($x.camip -eq '192.168.0.150' -and $x.chans.'192.168.1.19'.'1'.ip -eq '192.168.0.150' -and $x.chans.'192.168.1.19'.'2'.ip -eq '192.168.0.150' -and $x.online.'192.168.1.19/2') ('F1 address change: camera recorded on 2 channels of ONE NVR is NOT moved (both channels keep it)' + $tw) $x.out
      Check ($x.exit -ne 0 -and $x.problems -ge 1 -and $x.said_chans) ('F1 ...Still a problem, told why, nonzero exit (exit ' + $x.exit + ')' + $tw) $x.out
      $x = $r.('multihalf' + $n)
      Check ($x.pw -eq 'Oldpass123' -and $x.pwchanges -eq 0 -and $x.chans.'192.168.1.19'.'2'.pw -eq 'Oldpass123' -and $x.exit -ne 0 -and $x.problems -ge 1) ('F1 failing half-way: 2-channel camera, the NVR stops answering after the backup: nothing written, nonzero exit (exit ' + $x.exit + ')' + $tw) $x.out
      $x = $r.('reset' + $n)
      Check ($x.said_resetblocked -and $x.pw -eq 'Unknown999' -and $x.pwchanges -eq 0 -and $x.exit -ne 0 -and $x.problems -ge 1) ('F2 FixSite under -MockUrl: camera with no video on .19 but recorded by .20: "official reset NOT run" with the reason, password untouched, nonzero exit (exit ' + $x.exit + ')' + $tw) $x.out
      Check ($x.online.'192.168.1.20/1') ('F2 ....20 still records it' + $tw) $x.out
      $x = $r.('undo' + $n)
      Check ((NoPw $x.puts 'Sitepass456') -and $x.pw51 -eq 'Othercam789' -and $x.pwchanges51 -eq 0) ('F8 Codex repro: Undo of a channel replacement never writes the replacement''s password (Sitepass456) for the original camera .51' + $tw) (($x.puts | ConvertTo-Json -Compress) + "`n" + $x.out)
      Check ($x.exit -ne 0 -and $x.said_notconfirmed -and -not $x.said_allback -and $x.chans.'192.168.1.19'.'1'.ip -eq '192.168.1.51') ('F8 ...the address goes back to .51, its password is "NOT confirmed" (by hand), nonzero exit, never "everything is back" (exit ' + $x.exit + ')' + $tw) $x.out
      $x = $r.('undohalf' + $n)
      Check ($x.exit -ne 0 -and $x.said_notconfirmed -and -not $x.said_allback -and (NoPw $x.puts 'Sitepass456')) ('F8 failing half-way: the original camera does not answer during Undo: NOT confirmed, nonzero exit (exit ' + $x.exit + ')' + $tw) $x.out
      $x = $r.('undook' + $n)
      Check ($x.exit -eq 0 -and $x.said_allback -and $x.online.'192.168.1.19/1' -and $x.chans.'192.168.1.19'.'1'.ip -eq '192.168.1.51') ('F8 control: the original camera logs in with the site password: channel back with it, video back, exit 0' + $tw) $x.out
      $x = $r.('undosame' + $n)
      Check ($x.exit -eq 0 -and $x.said_allback -and $x.online.'192.168.1.19/1') ('control: Undo of the SAME camera''s channel: its own password, video back, exit 0' + $tw) $x.out
      $x = $r.('wrongcam' + $n)
      Check ($x.pw51 -eq 'Sitepass456' -and $x.pwchanges51 -eq 0 -and $x.chans.'192.168.1.19'.'1'.ip -eq '192.168.1.51' -and $x.online.'192.168.1.19/1' -and $x.online.'192.168.1.19/2') ('F1 wrong device (control): .19 ch 1 is ANOTHER camera: it and its channel are untouched and still record' + $tw) $x.out
      Check ($x.pw -eq 'Sitepass456' -and $x.pwchanges -eq 1 -and $x.chans.'192.168.1.19'.'2'.pw -eq 'Sitepass456' -and $x.exit -eq 0) ('F1 wrong device (control): ours (ONE dependent channel) gets the site password once, ch 2 follows, exit ' + $x.exit + $tw) $x.out
      $x = $r.('single' + $n)
      Check ($x.pw -eq 'Sitepass456' -and $x.pwchanges -eq 1 -and $x.online.'192.168.1.19/1' -and $x.exit -eq 0) ('control: one NVR, one channel: site password once, channel follows, video back, exit ' + $x.exit + $tw) $x.out
    }
  }
  # NEEDS WINDOWS CHECK: real multi-sensor Hikvision cameras on 2 NVR channels, the real official reset (SADP + Hikvision's page) and
  # a real NVR keeping/clearing a channel password on a PUT without one, on Windows PowerShell 5.1 - DEFERRED, never PASS
  $script:deferred = 1; Write-Host 'DEFERRED real 2-channel camera, official reset guard and Undo channel restore on real Hikvision NVRs with Windows PowerShell 5.1 (NEEDS WINDOWS CHECK)'
} catch { $script:fail++; Write-Host ('FAIL unexpected error: ' + $_.Exception.Message + ' at ' + $_.InvocationInfo.ScriptLineNumber) }
finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host ('Test-Fix2214Site: ' + $script:pass + ' passed, ' + $script:fail + ' failed' + $(if ($script:deferred) { ', ' + $script:deferred + ' deferred' } else { '' }))
exit $script:fail
