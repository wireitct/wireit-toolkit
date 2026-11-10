param([string]$Repo = '')
# Adapted from the Codex 2.2.15 review (evidence/review-2.2.15/reproduce-recording-disappears.ps1). Runs the PRODUCTION code of -Repo with
# stand-ins for the device (nothing real is contacted) and ASSERTS the safe outcome.
# Prints PASS/FAIL per check, then "N passed, M failed"; exit 0 only when nothing failed.
if (-not $Repo) { $Repo = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path }
$script:Pass = 0; $script:Fail = 0
function Check([bool]$cond, [string]$what) { if ($cond) { $script:Pass++; Write-Output ('PASS ' + $what) } else { $script:Fail++; Write-Output ('FAIL ' + $what) } }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('wireit-repro-recdisappear-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$m = Import-Module (Join-Path $Repo 'Toolkit/modules/NvrHealth/NvrHealth.psm1') -Force -PassThru -DisableNameChecking
$rows = & $m {
  param($tmp)
  Set-NvrHealthOption LogDir (Join-Path $tmp 'logs')
  $cred = [pscredential]::new('admin', (ConvertTo-SecureString 'Review123' -AsPlainText -Force))
  $script:Case = ''; $script:put = $false; $script:Writes = 0
  function script:Http {
    param($Ip, $Method = 'GET', $Path, $Body, $ContentType, $Credential, $Headers, $Port, $Scheme, $NoLogBody, $Timeout, $BodyBytes, $OutFile)
    # camera 1 (track 101) is switched off; camera 2 (track 201) is enabled with no readable schedule.
    if ($Method -eq 'PUT') { $script:put = $true; $script:Writes++; return @{ code = 200; body = '<ResponseStatus><statusCode>1</statusCode></ResponseStatus>' } }
    $one = '<Track><id>101</id><Enable>' + $(if ($script:put) { 'true' } else { 'false' }) + '</Enable><TrackSchedule><Record>true</Record></TrackSchedule></Track>'
    $two = '<Track><id>201</id><Enable>true</Enable></Track>'
    if ($Path -eq '/ISAPI/ContentMgmt/record/tracks') {
      # the trigger (as the reviewer ran it): after camera 1's PUT the read-back lists ONLY camera 1, on with a real schedule
      if ($script:Case -eq 'disappears') { return @{ code = 200; body = ('<TrackList>' + $one + $(if (-not $script:put) { $two }) + '</TrackList>') } }
      # control: camera 2 is still in the read-back, still unknown
      return @{ code = 200; body = ('<TrackList>' + $one + $two + '</TrackList>') }
    }
    if ($Path -eq '/ISAPI/ContentMgmt/record/tracks/101') { return @{ code = 200; body = $one } }
    return @{ code = 404; body = '' }
  }
  $out = @()
  foreach ($case in @('disappears', 'still-unknown')) {
    $script:Case = $case; $script:put = $false; $script:Writes = 0
    $r = Invoke-NvrFix -Fix recording -Ip 10.0.0.20 -Vendor Hikvision -Credential $cred -Confirm { 'YES' } -BackupDir (Join-Path $tmp ('backup-' + $case))
    $out += [pscustomobject]@{ case = $case; ok = [bool]$r.ok; ran = [bool]$r.ran; writes = $script:Writes; changed = (@($r.changed) -join ', '); msg = [string]$r.msg; history = [string]$r.history }
  }
  return $out
} $tmp 6>$null
$rows = @($rows | Where-Object { $_ -and $_.PSObject.Properties['case'] })
foreach ($x in $rows) {
  Write-Output ('REPRO=' + ($x | ConvertTo-Json -Compress))
  $c = 'F5 Hik ' + $x.case + ': '
  Check ($x.ran -and $x.writes -eq 1 -and $x.changed -eq 'camera 1') ($c + 'camera 1 (switched off) was turned on with one write (writes=' + $x.writes + ', changed=' + $x.changed + ')')
  Check (-not $x.ok) ($c + 'the result is NOT ok, camera 2 was never confirmed (ok=' + $x.ok + ')')
  Check ($x.msg -match 'camera\(s\) 2\b' -and $x.msg -match 'NOT (CHECKED|confirmed)') ($c + 'the result names camera 2 as NOT CHECKED / NOT confirmed (' + $x.msg + ')')
  Check ($x.msg -notmatch '^Recording is ON again') ($c + 'no "Recording is ON again" all-clear')
  Check ($x.history -match 'NOT (CHECKED|confirmed)' -and $x.history -notmatch '^Recording turned back on:') ($c + 'the history line is not a success line (' + $x.history + ')')
}
Check ($rows.Count -eq 2) ('both cases ran (' + $rows.Count + ')')
Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Output ('' + $script:Pass + ' passed, ' + $script:Fail + ' failed')
if ($script:Fail) { exit 1 } else { exit 0 }
