<#
 FixSiteRunner.ps1 - WireIt Toolkit 2.2.0: runs "Fix this site" for the Crew login with no admin name or password (review H3).
 Started ONLY by the scheduled task "\WireIt\Fix this site" (made by Install-Toolkit as an admin; runs as SYSTEM; Crew may start it but
 cannot change it). It takes nothing from Crew but ipc\request.json, checked by Test-FsRunRequest (FixSiteIpc.ps1): the mode from a
 fixed list, the site, the drop-downs from fixed lists and two ticks. Undo picks the last undoable run by itself. Update / Go back run
 the Toolkit's own signed-by-hash updater here, because Crew can no longer write into the Toolkit folder (review H1).
 One run at a time (fixsite-runs\runner.lock). The run's questions go to the Toolkit window through ipc\s-<id>\ (FixSiteIpc.ps1).
 -TestPsExe / -TestArgsList (Name=value|Switch): tests only (run FixSite.ps1 with a mock device server).
#>
param([string]$ToolkitDir = '', [string]$TestPsExe = '', [string]$TestArgsList = '')
$TestArgs = @(); if ($TestPsExe -and $TestArgsList) { foreach ($kv in ($TestArgsList -split '\|')) { $i = $kv.IndexOf('='); if ($i -gt 0) { $TestArgs += @(('-' + $kv.Substring(0, $i)), $kv.Substring($i + 1)) } else { $TestArgs += ('-' + $kv) } } }
$ErrorActionPreference = 'Continue'; $ProgressPreference = 'SilentlyContinue'
if (-not $ToolkitDir) { $ToolkitDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $ToolkitDir 'FixSiteIpc.ps1')
. (Join-Path $ToolkitDir 'FixSiteCore.ps1')
$root = Get-FsIpcRoot $ToolkitDir; $runs = Get-FsRunnerRunsDir $ToolkitDir
New-Item -ItemType Directory -Force -Path $root, $runs | Out-Null
# the ipc folder must be the real folder the installer made, never a link to somewhere else (this runs as SYSTEM)
foreach ($chk in @($root, $runs)) { try { if (((Get-Item -LiteralPath $chk -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { exit 5 } } catch { exit 5 } }
$logF = Join-Path $runs 'runner.log'
function Rn-Log([string]$s) { try { Add-Content -LiteralPath $logF -Value ((Get-Date -Format 's') + ' ' + $s) -Encoding UTF8 } catch {} }
$lockF = Join-Path $runs 'runner.lock'; $lock = $null
try { $lock = [IO.File]::Open($lockF, 'OpenOrCreate', 'ReadWrite', 'None') } catch { Rn-Log 'another run is going - request left for later'; exit 3 }
$code = 0
try {
  Clear-FsIpcOld $root
  $rf = Join-Path $root 'request.json'
  $raw = Read-FsIpcJson $rf 600000
  Remove-Item -LiteralPath $rf -Force -ErrorAction SilentlyContinue
  $t = Test-FsRunRequest $raw
  if (-not $t.ok) {
    Rn-Log ('request refused: ' + $t.why)
    Write-FsIpcJson (Join-Path $root 'current.json') ([ordered]@{ id = $(if ($raw -and $raw.PSObject.Properties['id']) { ([string]$raw.id -replace '[^A-Za-z0-9-]', '') } else { '' }); state = 'refused'; why = $t.why; ended = (Get-Date -Format 's') })
    exit 2
  }
  $req = $t.req
  # 2.2.2 (Codex H3, upgrades): this runs as SYSTEM, so it refuses to run anything while the Crew login could change the scripts or
  # config.json it would run (an old install, or permissions an update could not set). Only an admin running the installer fixes that.
  if (-not $TestPsExe -and $env:OS -eq 'Windows_NT') {
    $lk = $null; try { . (Join-Path $ToolkitDir 'WireItAcl.ps1'); $lk = Test-WireItLocked (Split-Path -Parent $ToolkitDir) } catch { $lk = [pscustomobject]@{ ok = $false; why = @('the permissions could not be checked: ' + $_.Exception.Message) } }
    if (-not $lk.ok) {
      Rn-Log ('refused: not locked: ' + (@($lk.why) -join '; '))
      Write-FsIpcJson (Join-Path $root 'current.json') ([ordered]@{ id = $req.id; state = 'refused'; why = 'this PC''s Toolkit folder can still be changed by the Crew login, so Fix this site is switched off. Ask the office to run the Toolkit installer as administrator.'; ended = (Get-Date -Format 's') })
      exit 8
    }
  }
  Rn-Log ('request ' + $req.id + ' mode=' + $req.mode + ' site=' + $req.site + ' newSite=' + $req.newSite + ' by=' + $(if ($raw.PSObject.Properties['user']) { ([string]$raw.user -replace '[^A-Za-z0-9._ -]', '') } else { '?' }))
  if ($req.mode -in @('Update', 'UndoUpdate')) {
    . (Join-Path $ToolkitDir 'ToolkitCore.ps1')
    $res = [ordered]@{ id = $req.id; state = 'ended'; mode = $req.mode; ok = $false; message = ''; ended = '' }
    try {
      if ($req.mode -eq 'Update') {
        $cfg = Get-TkConfig $ToolkitDir; $u = Get-TkUpdateInfo $cfg $ToolkitDir
        if ($u.state -eq 'available') {
          $old = Install-TkUpdate $u.manifest $ToolkitDir; $res.from = $old; $res.to = [string]$u.manifest.version
          # 2.2.2 (release package): the new version's permissions, vault\ and data folders are put in place here (this is SYSTEM);
          # anything that does not work is said, and the update is NOT reported as a success
          $cs = $null; try { . (Join-Path $ToolkitDir 'WireItAcl.ps1'); New-Item -ItemType Directory -Force -Path (Join-Path $ToolkitDir 'vault') | Out-Null; $cs = Install-WireItCrewSetup (Split-Path -Parent $ToolkitDir) -KeepTask } catch { $cs = [pscustomobject]@{ ok = $false; why = @($_.Exception.Message) } }
          $res.ok = [bool]$cs.ok
          $res.message = ('Updated from ' + $old + ' to ' + $u.manifest.version + '.' + $(if ($cs.ok) { '' } else { ' BUT the set-up is not finished (' + (@($cs.why) -join '; ') + '): run the Toolkit installer as administrator. Fix this site is switched off until then.' }))
        }
        else { $res.ok = ($u.state -eq 'current'); $res.message = [string]$u.message }
      } else { $v = Undo-TkUpdate $ToolkitDir; $res.ok = $true; $res.message = ('Went back to ' + $v + '.'); $res.to = [string]$v }
    } catch { $res.message = [string]$_.Exception.Message }
    $res.ended = (Get-Date -Format 's'); Write-FsIpcJson (Join-Path $root 'current.json') $res; Rn-Log ($req.mode + ': ' + $res.message)
    exit $(if ($res.ok) { 0 } else { 4 })
  }
  $sid = 's-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
  $sess = Join-Path $root $sid; New-Item -ItemType Directory -Force -Path $sess | Out-Null
  $listFile = ''
  if ($req.siteList) { $listFile = Join-Path $sess 'site-list.json'; [IO.File]::WriteAllText($listFile, [string]$req.siteList) }
  $rbDir = ''
  if ($req.mode -eq 'Rollback') { $d = Get-FsLastRun $runs -Undoable; if ($d) { $rbDir = $d.FullName } }
  $cur = [ordered]@{ id = $req.id; session = $sid; mode = $req.mode; site = $req.site; newSite = $req.newSite; state = 'running'; started = (Get-Date -Format 's'); pid = $PID }
  Write-FsIpcJson (Join-Path $root 'current.json') $cur
  $fsArgs = Get-FsRunArgs $req $sess $runs $rbDir $listFile
  if ($req.mode -eq 'Rollback' -and -not $rbDir) { $fsArgs = @('-Mode', 'Rollback', '-Ipc', $sess, '-RunsRoot', $runs, '-CloseAfter', '0') }
  $psexe = $(if ($TestPsExe) { $TestPsExe } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' })
  $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $ToolkitDir 'FixSite.ps1')) + @($fsArgs) + @($TestArgs)
  $null = & $psexe @all 2>&1
  $code = $LASTEXITCODE
  $cur.state = 'ended'; $cur.code = $code; $cur.ended = (Get-Date -Format 's')
  Write-FsIpcJson (Join-Path $sess 'end.json') ([ordered]@{ code = $code; ended = $cur.ended })
  Write-FsIpcJson (Join-Path $root 'current.json') $cur
  Rn-Log ('run ' + $req.id + ' ended with ' + $code)
} catch {
  Rn-Log ('runner error: ' + $_.Exception.Message); $code = 9
  try { $c0 = Read-FsIpcJson (Join-Path $root 'current.json'); if ($c0 -and [string]$c0.state -eq 'running') { $c0.state = 'ended'; $c0 | Add-Member -NotePropertyName code -NotePropertyValue 9 -Force; Write-FsIpcJson (Join-Path $root 'current.json') $c0 } } catch {}
} finally {
  # 2.2.1 (review H4): whatever happened to the run (stopped, crashed, killed after 4 hours), this PC's network is put back here too
  try {
    $ts = Join-Path (Join-Path $runs '_state') 'fixsite-temp-ips.json'
    if (Test-Path -LiteralPath $ts) {
      . (Join-Path $ToolkitDir 'FixSiteDevices.ps1'); $nr = Clear-FsLeftoverTemps $ts
      if ($nr) {
        Rn-Log ('network put back after the run: ' + $(if ($nr.ok) { 'ok' } else { 'NOT ok: ' + (@($nr.problems) -join '; ') }))
        # 2.2.2 (re-review H4): a clean-up that did not work makes the run's result a failure the window shows
        if (-not $nr.ok) { if ($code -in @(0, 4)) { $code = 6 }; try { $c1 = Read-FsIpcJson (Join-Path $root 'current.json'); if ($c1) { $c1 | Add-Member -NotePropertyName code -NotePropertyValue $code -Force; $c1 | Add-Member -NotePropertyName network -NotePropertyValue ('NOT back to normal: ' + (@($nr.problems) -join '; ')) -Force; Write-FsIpcJson (Join-Path $root 'current.json') $c1 } } catch {} }
      }
    }
  } catch { Rn-Log ('network clean-up error: ' + $_.Exception.Message); if ($code -in @(0, 4)) { $code = 6 } }
  if ($sess) { Clear-FsIpcSession $sess }
  if ($lock) { $lock.Close() }
}
exit $code
