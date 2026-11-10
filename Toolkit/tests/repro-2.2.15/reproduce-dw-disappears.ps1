param([string]$Repo = '')
# Adapted from the Codex 2.2.15 review (evidence/review-2.2.15/reproduce-dw-disappears.ps1). Runs the PRODUCTION code of -Repo with
# stand-ins for the device (nothing real is contacted) and ASSERTS the safe outcome.
# Prints PASS/FAIL per check, then "N passed, M failed"; exit 0 only when nothing failed.
if (-not $Repo) { $Repo = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path }
$script:Pass = 0; $script:Fail = 0
function Check([bool]$cond, [string]$what) { if ($cond) { $script:Pass++; Write-Output ('PASS ' + $what) } else { $script:Fail++; Write-Output ('FAIL ' + $what) } }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('wireit-repro-dwdisappear-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$m = Import-Module (Join-Path $Repo 'Toolkit/modules/NvrHealth/NvrHealth.psm1') -Force -PassThru -DisableNameChecking
$rows = & $m {
  param($tmp)
  Set-NvrHealthOption LogDir (Join-Path $tmp 'logs')
  $cred = [pscredential]::new('admin', (ConvertTo-SecureString 'Review123' -AsPlainText -Force))
  $script:Case = ''; $script:put = $false; $script:Writes = 0
  function script:Dw-Login { return $true }
  function script:Dw-Send { $script:put = $true; $script:Writes++; return @{ code = 200; body = '{}' } }
  function script:Http {
    param($Ip, $Method = 'GET', $Path, $Body, $ContentType, $Credential, $Headers, $Port, $Scheme, $NoLogBody, $Timeout, $BodyBytes, $OutFile)
    if ($Path -like '/rest/v3/devices*') {
      $one = '{"id":"c1","name":"One","url":"http://10.0.0.41","schedule":{"isEnabled":' + $(if ($script:put) { 'true' } else { 'false' }) + '}}'
      $two = '{"id":"c2","name":"Two","url":"http://10.0.0.42","schedule":{}}'
      # the trigger (as the reviewer ran it): after the change the read-back omits camera Two
      if ($script:Case -eq 'disappears' -and $script:put) { $b = '[' + $one + ']' } else { $b = '[' + $one + ',' + $two + ']' }
      return @{ code = 200; body = $b }
    }
    return @{ code = 404; body = '' }
  }
  $out = @()
  foreach ($case in @('disappears', 'still-unknown')) {
    $script:Case = $case; $script:put = $false; $script:Writes = 0
    $r = Invoke-NvrFix -Fix recording -Ip 10.0.0.20 -Vendor DW -Credential $cred -Confirm { 'YES' } -BackupDir (Join-Path $tmp ('backup-' + $case))
    $out += [pscustomobject]@{ case = $case; ok = [bool]$r.ok; ran = [bool]$r.ran; writes = $script:Writes; changed = (@($r.changed) -join ', '); msg = [string]$r.msg; history = [string]$r.history }
  }
  return $out
} $tmp 6>$null
$rows = @($rows | Where-Object { $_ -and $_.PSObject.Properties['case'] })
foreach ($x in $rows) {
  Write-Output ('REPRO=' + ($x | ConvertTo-Json -Compress))
  $c = 'F5 DW ' + $x.case + ': '
  Check ($x.ran -and $x.writes -eq 1 -and $x.changed -eq 'One') ($c + 'camera One (recording off) was turned on with one write (writes=' + $x.writes + ', changed=' + $x.changed + ')')
  Check (-not $x.ok) ($c + 'the result is NOT green, camera Two was never confirmed (ok=' + $x.ok + ')')
  Check ($x.msg -match 'Two \(10\.0\.0\.42\)' -and $x.msg -match 'NOT (CHECKED|confirmed)') ($c + 'the result names camera Two as NOT CHECKED / NOT confirmed (' + $x.msg + ')')
  Check ($x.msg -notmatch '^Recording is ON again') ($c + 'no "Recording is ON again" all-clear')
  Check ($x.history -match 'NOT (CHECKED|confirmed)' -and $x.history -notmatch '^Recording turned back on:') ($c + 'the history line is not a success line (' + $x.history + ')')
}
Check ($rows.Count -eq 2) ('both cases ran (' + $rows.Count + ')')
Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Output ('' + $script:Pass + ' passed, ' + $script:Fail + ' failed')
if ($script:Fail) { exit 1 } else { exit 0 }
