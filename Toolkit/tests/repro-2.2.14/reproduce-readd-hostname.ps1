param([string]$Repo = '')
# Adapted from the Codex 2.2.14 review (evidence/review/reproduce-readd-hostname.ps1). Runs the PRODUCTION code of -Repo with
# stand-ins for the device (loopback only, nothing real is contacted) and ASSERTS the safe outcome.
# Prints PASS/FAIL per check, then "N passed, M failed"; exit 0 only when nothing failed.
if (-not $Repo) { $Repo = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path }
$script:Pass = 0; $script:Fail = 0
function Check([bool]$cond, [string]$what) { if ($cond) { $script:Pass++; Write-Output ('PASS ' + $what) } else { $script:Fail++; Write-Output ('FAIL ' + $what) } }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('wireit-repro-readd-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$m = Import-Module (Join-Path $Repo 'Toolkit/modules/NvrHealth/NvrHealth.psm1') -Force -PassThru -DisableNameChecking

$out = & $m {
  param($tmp)
  Set-NvrHealthOption LogDir (Join-Path $tmp 'logs')
  $c = [pscredential]::new('admin', (ConvertTo-SecureString 'Review123' -AsPlainText -Force))
  $rows = @()
  # case: the reviewer's (hostname channel with a working camera); then no address at all; then an unknown address type
  foreach ($case in @('hostname', 'no-address', 'odd-type')) {
    $script:Writes = 0; $script:StatusBeforeWrite = 0; $script:Case = $case
    function script:Http {
      param($Ip, $Method = 'GET', $Path, $Body, $ContentType, $Credential, $Headers, $Port, $Scheme, [switch]$NoLogBody, $Timeout, $BodyBytes, $OutFile)
      if ($Method -eq 'PUT') { $script:Writes++; return @{ code = 200; body = '<ResponseStatus><statusCode>1</statusCode></ResponseStatus>' } }
      if ($Path -like '*/status') { if (-not $script:Writes) { $script:StatusBeforeWrite++ }; return @{ code = 200; body = '<InputProxyChannelStatusList><InputProxyChannelStatus><id>1</id><online>true</online></InputProxyChannelStatus></InputProxyChannelStatusList>' } }
      $address = $(if ($script:Writes) { '<addressingFormatType>ipaddress</addressingFormatType><ipAddress>10.0.0.41</ipAddress>' }
                   elseif ($script:Case -eq 'hostname') { '<addressingFormatType>hostname</addressingFormatType><hostName>working-camera.local</hostName>' }
                   elseif ($script:Case -eq 'no-address') { '<proxyProtocol>HIKVISION</proxyProtocol>' }
                   else { '<addressingFormatType>domain</addressingFormatType><ipAddress>10.0.0.77</ipAddress>' })
      return @{ code = 200; body = ('<InputProxyChannelList><InputProxyChannel><id>1</id><sourceInputPortDescriptor>' + $address + '</sourceInputPortDescriptor></InputProxyChannel></InputProxyChannelList>') }
    }
    $r = Invoke-NvrFix -Fix readd -Ip '10.0.0.20' -Vendor Hikvision -Credential $c -NewCredential $c -Channel 1 -CameraIp '10.0.0.41' -Confirm { 'YES' } -BackupDir (Join-Path $tmp 'backup')
    $rows += [pscustomobject]@{ case = $case; ok = [bool]$r.ok; writes = $script:Writes; statusReadsBeforeWrite = $script:StatusBeforeWrite; msg = [string]$r.msg }
  }
  return $rows
} $tmp 6>$null
foreach ($x in @($out | Where-Object { $_ -and $_.PSObject.Properties['case'] })) {
  if ($x.case -eq 'hostname') { Write-Output ('REPRO=' + (@{ ok = $x.ok; writes = $x.writes; statusReadsBeforeWrite = $x.statusReadsBeforeWrite; msg = $x.msg } | ConvertTo-Json -Compress)) }
  Check ($x.writes -eq 0) ($x.case + ': channel 1 is set up but not by a plain IP -> no PUT (writes=' + $x.writes + ')')
  Check (-not $x.ok) ($x.case + ': the result is not OK (ok=' + $x.ok + ')')
  Check ($x.msg -match '(?i)nothing changed' -and $x.msg -match '(?i)by hand') ($x.case + ': the message says nothing changed and to check the channel by hand: ' + $x.msg)
}
Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Output ('' + $script:Pass + ' passed, ' + $script:Fail + ' failed')
if ($script:Fail) { exit 1 } else { exit 0 }
