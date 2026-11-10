<# Test-Fix2213Site.ps1 - WireIt Toolkit 2.2.13, Fix this site: Codex's 2.2.12 review finding #1 (P1).
   A camera's password is changed only when EVERY recorder of it (its NVR, the NVR the saved site list names - even offline today -
   and every NVR channel the scan found pointing at it) is the one recorder the run updates and checks, and it answers right now.
   Codex's reproductions as permanent tests: the real FixSite.ps1 against mock devices (fix2213site/scenarios.py, loopback only)
   and the real functions of FixSiteCore.ps1 in their own process.
   Moshe's rule: failing half-way (the NVR stops answering right after the camera's backup), the wrong device (the live NVR records
   ANOTHER camera on ch 1) and running twice (every scenario runs twice). Controls (marked "control") pass on old and new code.
   FIX2213_REPO = another checkout (e.g. the 2.2.12 head ea667c6) to prove these tests fail there.
   Windows PowerShell 5.1 or pwsh 7. #>
$ErrorActionPreference = 'Stop'
$tk = Split-Path -Parent $PSScriptRoot; $repo = Split-Path -Parent $tk
if ($env:FIX2213_REPO) { $repo = $env:FIX2213_REPO; $tk = Join-Path $repo 'Toolkit' }
$exe = $(if ($PSVersionTable.PSEdition -eq 'Core') { (Get-Process -Id $PID).Path } else { Join-Path $PSHOME 'powershell.exe' })
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fix2213site-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$script:pass = 0; $script:fail = 0
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
$load = ". " + (Q (Join-Path $tk 'FixSiteCore.ps1')) + "; . " + (Q (Join-Path $tk 'FixSiteDevices.ps1')) + "`n"
try {
  . (Join-Path $PSScriptRoot 'TestPython.ps1'); $py = Get-TestPython

  # =====================================================================================
  # the real recorder set and the real password guard (no devices)
  $d = Invoke-Driver 'guard' ($load + @'
$ErrorActionPreference = 'Continue'
$o = @{}
function C($nvr, $orig, $list, $links, $steps) { return [pscustomobject]@{ nvr = $nvr; nvrOriginal = $orig; listNvr = $list; links = @($links | ForEach-Object { [pscustomobject]@{ nvr = $_; channel = 1 } }); steps = $steps } }
$cr = @{ '192.168.1.19' = 'x'; '192.168.1.21' = 'x' }
$c = C '192.168.1.19' '192.168.1.19' '192.168.1.20' @('192.168.1.19') @('backup', 'password', 'nvr', 'verify')
$o.recA = (@(Get-FsCamRecorders $c) -join ',')
try { $o.blkA = [string](Get-FsPwChangeBlock $c @(Get-FsCamRecorders $c) $cr) } catch { $o.blkA = 'NOFUNC' }
$c = C '192.168.1.19' '192.168.1.19' '192.168.1.19' @('192.168.1.19') @('backup', 'password', 'nvr', 'verify')
$o.recB = (@(Get-FsCamRecorders $c) -join ',')
try { $o.blkB = [string](Get-FsPwChangeBlock $c @(Get-FsCamRecorders $c) $cr) } catch { $o.blkB = 'NOFUNC' }
$c = C '192.168.1.21' '192.168.1.20' '192.168.1.20' @() @('backup', 'password', 'nvr', 'verify')
$o.recC = (@(Get-FsCamRecorders $c) -join ',')
$c = C '192.168.1.19' '192.168.0.20' '' @('192.168.0.20') @('backup', 'password', 'nvr', 'verify')
$o.recG = (@(Get-FsCamRecorders $c) -join ',')
$c = C '192.168.1.22' '192.168.1.22' '' @('192.168.1.22') @('backup', 'password', 'nvr', 'verify')
try { $o.blkD = [string](Get-FsPwChangeBlock $c @(Get-FsCamRecorders $c) $cr) } catch { $o.blkD = 'NOFUNC' }
$c = C '192.168.1.19' '192.168.1.19' '' @('192.168.1.19') @('backup', 'password', 'verify')
try { $o.blkE = [string](Get-FsPwChangeBlock $c @(Get-FsCamRecorders $c) $cr) } catch { $o.blkE = 'NOFUNC' }
$c = C '' '' '' @() @('backup', 'password', 'verify')
try { $o.blkF = [string](Get-FsPwChangeBlock $c @(Get-FsCamRecorders $c) $cr) } catch { $o.blkF = 'NOFUNC' }
'JSON=' + ($o | ConvertTo-Json -Compress)
'@)
  $j = Get-Json $d
  Check ($j -and $j.recA -eq '192.168.1.19,192.168.1.20') 'control: the recorder set holds the live NVR AND the NVR the site list names' $d
  Check ($j -and $j.blkA -match '2 NVRs record this camera' -and $j.blkA -match 'site list') '#1 guard: live .19 + list .20 = the password is NOT changed, and the reason names both NVRs and the site list' $d
  Check ($j -and $j.recB -eq '192.168.1.19' -and $j.blkB -eq '') '#1 guard (control): one known recorder that the run updates = the password may change' $d
  Check ($j -and $j.recC -eq '192.168.1.21') '#1 the list NVR this run moved (.20 -> .21) is the SAME recorder, not a second one (no false refusal)' $d
  Check ($j -and $j.recG -eq '192.168.1.19') '#1 ...the same for the scan''s channel link: NVR .0.20 moved to .19 this run is ONE recorder (Review225 retarget: no false refusal)' $d
  Check ($j -and $j.blkD -match 'login is unknown') '#1 guard: its only NVR has no known login = the password is NOT changed' $d
  Check ($j -and $j.blkE -match 'not the one this run updates') '#1 guard: a recorder the run would not update = the password is NOT changed' $d
  Check ($j -and $j.blkF -eq '') '#1 guard (control): a camera no NVR records keeps the old behaviour (may change)' $d

  # =====================================================================================
  # the real Fix this site, each scenario run twice
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  $scen = & $py (Join-Path $PSScriptRoot 'fix2213site/scenarios.py') --repo $repo --powershell $exe 2>&1 | Out-String
  $ErrorActionPreference = $prev
  $r = $null; try { $r = (($scen.Trim() -split "`n")[-1]) | ConvertFrom-Json } catch {}
  if (-not $r) { Check $false 'Fix this site scenarios ran' $scen }
  else {
    foreach ($n in 1, 2) {
      $tw = $(if ($n -eq 2) { ' (run twice: the 2nd run too)' } else { '' })
      # Codex repro: camera .50 right address, list names offline .20, live .19 records it, -PasswordAll
      $x = $r.('sameip' + $n)
      Check ($x.pw -eq 'Oldpass123' -and $x.pwchanges -eq 0) ('#1 Codex repro (same address): -PasswordAll does NOT change the camera password while offline .20 (on the site list) still uses the old one' + $tw) $x.out
      Check ($x.chans.'192.168.1.20'.'1'.pw -eq 'Oldpass123' -and $x.chans.'192.168.1.19'.'1'.pw -eq 'Oldpass123' -and $x.online.'192.168.1.19/1') ('#1 ...both NVR channels still match the camera and .19 still records it' + $tw) $x.out
      Check ($x.exit -ne 0 -and $x.problems -ge 1 -and $x.said_multi -and -not $x.said_pwset) ('#1 ...not "Fixed": Still a problem, the tech is told why, nonzero exit (exit ' + $x.exit + ', Still a problem: ' + $x.problems + ')' + $tw) $x.out
      # wrong-subnet variant: the move is refused, so the password must not be changed first
      $x = $r.('move' + $n)
      Check ($x.pw -eq 'Oldpass123' -and $x.pwchanges -eq 0 -and $x.camip -eq '192.168.0.150') ('#1 Codex wrong-subnet variant: the password is NOT changed ahead of the move that is refused (camera stays put, old password)' + $tw) $x.out
      Check ($x.chans.'192.168.1.19'.'1'.pw -eq 'Oldpass123' -and $x.online.'192.168.1.19/1' -and $x.exit -ne 0 -and $x.problems -ge 1) ('#1 ....19 still records it; Still a problem, nonzero exit (exit ' + $x.exit + ')' + $tw) $x.out
      # wrong device
      $x = $r.('wrongcam' + $n)
      Check ($x.pw -eq 'Oldpass123' -and $x.pwchanges -eq 0 -and $x.exit -ne 0) ('#1 wrong device: .19 ch 1 is ANOTHER camera, ch 2 ours, list names offline .20 for ours: our password is NOT changed (exit ' + $x.exit + ')' + $tw) $x.out
      Check ($x.pw51 -eq 'Sitepass456' -and $x.pwchanges51 -eq 0 -and $x.chans.'192.168.1.19'.'1'.ip -eq '192.168.1.51' -and $x.online.'192.168.1.19/1' -and $x.online.'192.168.1.19/2') ('control (wrong device): the other camera and both .19 channels are untouched and still record' + $tw) $x.out
      # failing half-way
      $x = $r.('nvrdown' + $n)
      Check ($x.pw -eq 'Oldpass123' -and $x.pwchanges -eq 0) ('#1 failing half-way: the only NVR stops answering after the camera backup: the password is NEVER written (nothing to roll back)' + $tw) $x.out
      Check ($x.chans.'192.168.1.19'.'1'.pw -eq 'Oldpass123' -and $x.exit -ne 0 -and $x.problems -ge 1 -and $x.said_down) ('#1 ...the NVR channel still matches, Still a problem, the tech is told the NVR does not answer (exit ' + $x.exit + ')' + $tw) $x.out
    }
    $x = $r.single1
    Check ($x.pw -eq 'Sitepass456' -and $x.pwchanges -eq 1 -and $x.chans.'192.168.1.19'.'1'.pw -eq 'Sitepass456' -and $x.online.'192.168.1.19/1' -and $x.exit -eq 0) ('control: a camera only ONE live NVR records (the one the list names) gets the site password, its channel follows, video back, exit ' + $x.exit) $x.out
    $x = $r.single2
    Check ($x.pw -eq 'Sitepass456' -and $x.pwchanges -eq 1 -and $x.online.'192.168.1.19/1' -and $x.exit -eq 0) ('control: ...running it twice writes nothing more and still exits 0 (exit ' + $x.exit + ')') $x.out
  }
  # NEEDS WINDOWS CHECK: real Hikvision NVRs answering/not answering and the PS 5.1 console; counted as DEFERRED, never PASS
  $script:deferred = 1; Write-Host 'DEFERRED real NVR/camera password change on Windows PowerShell 5.1 with real recorders (NEEDS WINDOWS CHECK)'
} catch { $script:fail++; Write-Host ('FAIL unexpected error: ' + $_.Exception.Message + ' at ' + $_.InvocationInfo.ScriptLineNumber) }
finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
if (-not $script:deferred) { $script:deferred = 0 }
Write-Host ('Test-Fix2213Site: ' + $script:pass + ' passed, ' + $script:fail + ' failed' + $(if ($script:deferred) { ', ' + $script:deferred + ' deferred' } else { '' }))
exit $script:fail
