# reproduce-wifiwatch-marker.ps1 - Codex review of 2.2.14, R7 (reviewer's reproduction, adapted to run from the repo and to ASSERT).
# The marker path is made unwritable, the adapter "off" step kills the child (as a crash/power loss would), then two fresh runs try
# to recover. 2.2.14: the adapter stays OFF with no marker. 2.2.15: the adapter is never switched off without a saved marker.
param([ValidateSet('Parent','Kill','Recover')][string]$Phase='Parent', [string]$Repo = '', [string]$Dir = '')
if (-not $Repo) { $Repo = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))) }
if (-not $Dir) { $Dir = Join-Path ([IO.Path]::GetTempPath()) ('wifiwatch-repro-' + [guid]::NewGuid().ToString('N').Substring(0, 8)) }
$dir = $Dir
[void][IO.Directory]::CreateDirectory($dir)
if ($Phase -eq 'Parent') {
  [IO.File]::WriteAllText((Join-Path $dir 'not-a-directory'),'blocks marker creation')
  [IO.File]::WriteAllText((Join-Path $dir 'adapter-state.txt'),'on')
  $exe=(Get-Process -Id $PID).Path
  & $exe -NoProfile -File $PSCommandPath -Phase Kill -Repo $Repo -Dir $dir
  $killed=$LASTEXITCODE
  & $exe -NoProfile -File $PSCommandPath -Phase Recover -Repo $Repo -Dir $dir
  & $exe -NoProfile -File $PSCommandPath -Phase Recover -Repo $Repo -Dir $dir
  $state=[IO.File]::ReadAllText((Join-Path $dir 'adapter-state.txt'))
  $log=''; $lp = Join-Path $dir 'wifiwatch.log'; if (Test-Path -LiteralPath $lp) { $log = [IO.File]::ReadAllText($lp) }
  'REPRO='+(@{killedExit=$killed;adapterState=$state;markerExists=[IO.File]::Exists((Join-Path $dir 'not-a-directory/adapter-off.txt'))}|ConvertTo-Json -Compress)
  $p = 0; $f = 0
  if ($state -eq 'on') { 'PASS Wi-Fi adapter is still ON after a crash at the off step with no marker'; $p++ } else { 'FAIL Wi-Fi adapter left OFF with no recovery marker (R7)'; $f++ }
  if ($killed -ne 9) { 'PASS the adapter was never switched off (the child was not killed at the off step)'; $p++ } else { 'FAIL the adapter was switched off although the marker could not be saved'; $f++ }
  if ($log -match 'NOT switched off') { 'PASS the log says the cycle was skipped because the marker could not be saved'; $p++ } else { 'FAIL the log does not say the cycle was skipped'; $f++ }
  Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
  ('' + $p + ' passed, ' + $f + ' failed')
  exit $f
}
. "$Repo/wifiwatch/WifiWatch.ps1" -Dir $dir -PauseFile (Join-Path $dir 'pause')
$marker=Join-Path $dir 'not-a-directory/adapter-off.txt'
$script:WwOps={
  param($op,$a)
  if ($op -eq 'disable') {[IO.File]::WriteAllText((Join-Path $dir 'adapter-state.txt'),'off');[Environment]::Exit(9)}
  if ($op -eq 'enable') {[IO.File]::WriteAllText((Join-Path $dir 'adapter-state.txt'),'on')}
  if ($op -eq 'isup') {return ([IO.File]::ReadAllText((Join-Path $dir 'adapter-state.txt')) -eq 'on')}
  return $true
}
if ($Phase -eq 'Kill') {Invoke-WwAdapterCycle 'Wi-Fi' 'Site'} else {Repair-WwAdapter}
