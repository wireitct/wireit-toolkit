# reproduce-update-undo-interruption.ps1 - Codex review of 2.2.14, R8 (reviewer's reproduction, adapted to run from the repo and to ASSERT).
# A child runs the real Undo-TkUpdate ("Go back") and dies right after its first file swap; then the real startup recovery runs.
# 2.2.14: one file old, one new, version.json still new, no notice. 2.2.15: startup recovery finishes the go-back and says so.
param([switch]$Child, [string]$Repo = '', [string]$Root = '')
if (-not $Repo) { $Repo = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))) }
if (-not $Root) { $Root = Join-Path ([IO.Path]::GetTempPath()) ('update-undo-repro-' + [guid]::NewGuid().ToString('N').Substring(0, 8)) }
$root=$Root; $tk=Join-Path $root 'Toolkit'; $prev=Join-Path $tk 'previous/9.9.8'
if (-not $Child) {
 [void][IO.Directory]::CreateDirectory((Join-Path $prev 'Toolkit'))
 [IO.File]::WriteAllText((Join-Path $tk 'a.ps1'),'new-a')
 [IO.File]::WriteAllText((Join-Path $tk 'b.ps1'),'new-b')
 [IO.File]::WriteAllText((Join-Path $prev 'Toolkit/a.ps1'),'old-a')
 [IO.File]::WriteAllText((Join-Path $prev 'Toolkit/b.ps1'),'old-b')
 [IO.File]::WriteAllText((Join-Path $tk 'version.json'),'{"version":"9.9.9","previous":"9.9.8"}')
 [IO.File]::WriteAllText((Join-Path $prev 'version.json.prev'),'{"version":"9.9.8"}')
 [IO.File]::WriteAllText((Join-Path $prev 'undo.json'),'{"added":[]}')
 & (Get-Process -Id $PID).Path -NoProfile -File $PSCommandPath -Child -Repo $Repo -Root $root
 $childExit=$LASTEXITCODE
 . "$Repo/Toolkit/ToolkitRecover.ps1"
 $notice=''; $err=''; try { $notice=[string](Invoke-TkStartupRecovery $tk) } catch { $err = $_.Exception.Message }
 $a=[IO.File]::ReadAllText((Join-Path $tk 'a.ps1')); $b=[IO.File]::ReadAllText((Join-Path $tk 'b.ps1')); $ver=[IO.File]::ReadAllText((Join-Path $tk 'version.json'))
 $jr=[IO.File]::Exists((Join-Path $tk 'previous/update-pending.json'))
 'REPRO='+(@{childExit=$childExit;startupNotice=$notice;error=$err;a=$a;b=$b;version=$ver;journal=$jr}|ConvertTo-Json -Compress)
 $p = 0; $f = 0
 if ($childExit -eq 9) { 'PASS the child really died after its first file swap'; $p++ } else { 'FAIL the child did not die at the first swap (exit ' + $childExit + ')'; $f++ }
 if ($a -eq 'old-a' -and $b -eq 'old-b') { 'PASS after startup recovery both files are the old version (no mixed Toolkit)'; $p++ } else { 'FAIL mixed Toolkit after startup recovery: a=' + $a + ' b=' + $b; $f++ }
 if ($ver -match '"9\.9\.8"' -and $ver -notmatch '9\.9\.9') { 'PASS version.json names the old version again'; $p++ } else { 'FAIL version.json still names the new release'; $f++ }
 if ($notice -match 'Go back' -and $notice -match 'half-way') { 'PASS startup recovery tells the crew the Go back stopped half-way and was finished'; $p++ } else { 'FAIL startup recovery gave no notice'; $f++ }
 if (-not $jr) { 'PASS the journal is cleared once the go-back is finished'; $p++ } else { 'FAIL the journal is still there after recovery'; $f++ }
 Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
 ('' + $p + ' passed, ' + $f + ' failed')
 exit $f
}
. "$Repo/Toolkit/ToolkitCore.ps1"
function Copy-TkAtomicFile([string]$src,[string]$dst,[string]$hash='') {
 [IO.File]::WriteAllBytes($dst,[IO.File]::ReadAllBytes($src))
 [Environment]::Exit(9)
}
Undo-TkUpdate $tk
