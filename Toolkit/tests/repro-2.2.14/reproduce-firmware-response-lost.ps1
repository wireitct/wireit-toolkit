param([string]$Repo = '')
# Adapted from the Codex 2.2.14 review (evidence/review/reproduce-firmware-response-lost.ps1). Runs the PRODUCTION code of -Repo with
# stand-ins for the device (loopback only, nothing real is contacted) and ASSERTS the safe outcome.
# Prints PASS/FAIL per check, then "N passed, M failed"; exit 0 only when nothing failed.
if (-not $Repo) { $Repo = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path }
$script:Pass = 0; $script:Fail = 0
function Check([bool]$cond, [string]$what) { if ($cond) { $script:Pass++; Write-Output ('PASS ' + $what) } else { $script:Fail++; Write-Output ('FAIL ' + $what) } }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('wireit-repro-firmware-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$m = Import-Module (Join-Path $Repo 'Toolkit/modules/NvrHealth/NvrHealth.psm1') -Force -PassThru -DisableNameChecking

$rows = & $m {
  param($tmp)
  Set-NvrHealthOption LogDir (Join-Path $tmp 'logs')
  $f = Join-Path $tmp 'mock-firmware.bin'; [IO.File]::WriteAllBytes($f, [byte[]]((1..255) * 4))
  $c = [pscredential]::new('admin', (ConvertTo-SecureString 'Review123' -AsPlainText -Force))
  $out = @()
  # reviewer's case: the update is taken (V2) but its answer is lost; then: lost answer and the device still shows V1;
  # then: lost answer and the device cannot be read back at all
  foreach ($case in @('lost-new-version', 'lost-still-old', 'lost-no-readback')) {
    $script:Version = 'V1'; $script:ReadsAfter = 0; $script:Sent = $false; $script:Case = $case
    function script:Http {
      param($Ip, $Method = 'GET', $Path, $Body, $ContentType, $Credential, $Headers, $Port, $Scheme, $NoLogBody, $Timeout, $BodyBytes, $OutFile)
      switch ($Path) {
        '/ISAPI/System/deviceInfo' {
          if ($script:Sent) { $script:ReadsAfter++; if ($script:Case -eq 'lost-no-readback') { return @{ code = 0; body = ''; err = 'no answer' } } }
          return @{ code = 200; body = "<DeviceInfo><model>DS-2CD</model><serialNumber>REVIEW</serialNumber><firmwareVersion>$script:Version</firmwareVersion></DeviceInfo>" }
        }
        '/ISAPI/System/configurationData' { [IO.File]::WriteAllBytes($OutFile, [byte[]]((1..255) * 4)); return @{ code = 200; body = '' } }
        '/ISAPI/System/updateFirmware' { $script:Sent = $true; if ($script:Case -eq 'lost-new-version') { $script:Version = 'V2' }; return @{ code = 0; body = ''; err = 'connection dropped' } }
      }
      return @{ code = 404; body = '' }
    }
    $bk = Join-Path $tmp ('backup-' + $case)
    $r = Invoke-NvrFix -Fix firmware -Ip '10.0.0.50' -Vendor Hikvision -Credential $c -File $f -Sha256 (Get-FileHash $f).Hash -BackupDir $bk -Confirm { 'YES' }
    $out += [pscustomobject]@{ case = $case; ok = [bool]$r.ok; msg = [string]$r.msg; history = [string]$r.history; backup = [string]$r.backup; backupThere = [bool]($r.backup -and (Test-Path -LiteralPath $r.backup)); actualFirmware = $script:Version; readsAfter = $script:ReadsAfter }
  }
  return $out
} $tmp 6>$null
$rows = @($rows | Where-Object { $_ -and $_.PSObject.Properties['case'] })
foreach ($x in $rows) {
  Write-Output ('REPRO=' + (@{ case = $x.case; ok = $x.ok; msg = $x.msg; actualFirmware = $x.actualFirmware; readsAfter = $x.readsAfter } | ConvertTo-Json -Compress))
  Check ($x.readsAfter -ge 1) ($x.case + ': the device info is read back after the lost answer (reads after=' + $x.readsAfter + ')')
  Check ($x.msg -notmatch '(?i)still runs the old firmware' -and $x.msg -notmatch '(?i)refused') ($x.case + ': no "refused" / "still runs the old firmware" claim (' + $x.msg + ')')
  Check ($x.backupThere -and $x.history) ($x.case + ': the settings export and a history line are kept (' + $x.history + ')')
  if ($x.case -eq 'lost-new-version') {
    Check ($x.ok -and $x.msg -match 'V2') ('lost answer, device now reports V2: says it is updated, read back (' + $x.msg + ')')
  } else {
    Check (-not $x.ok -and $x.msg -match 'NOT confirmed' -and $x.msg -match '(?i)wait' -and $x.msg -match '(?i)firmware check') ($x.case + ': NOT confirmed, tells the crew to wait and run the Firmware check before retrying (' + $x.msg + ')')
  }
}
Check ($rows.Count -eq 3) ('all 3 cases ran (' + $rows.Count + ')')
Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Output ('' + $script:Pass + ' passed, ' + $script:Fail + ' failed')
if ($script:Fail) { exit 1 } else { exit 0 }
