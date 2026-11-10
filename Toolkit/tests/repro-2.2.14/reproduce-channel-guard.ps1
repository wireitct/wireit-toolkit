# reproduce-channel-guard.ps1 - Codex 2.2.14 review R3 (adapted to run from the repo and ASSERT the safe outcome).
# Set-FsNvrChannel may overwrite a channel that shows ANOTHER camera only when that channel's status says explicitly <online>false</online>
# in a valid status list. A missing / garbled flag, no entry for the channel, or a failed status read = leave it alone and say so.
param([string]$Repo = (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))))
$ErrorActionPreference = 'Stop'
. (Join-Path $Repo 'Toolkit/FixSiteCore.ps1')
. (Join-Path $Repo 'Toolkit/FixSiteDevices.ps1')
function Fs-LogLine { param($t) }
$script:Writes = 0; $script:Status = ''; $script:StatusCode = 200
function Fs-Http {
  param($Ip, $Method = 'GET', $Path, $Cred, $Body, $Timeout, $OutFile)
  if ($Method -eq 'PUT' -or $Method -eq 'POST') { $script:Writes++; return @{ code = 200; body = '<ResponseStatus><statusCode>1</statusCode></ResponseStatus>' } }
  if ($Path -like '*/status') { return @{ code = $script:StatusCode; body = $script:Status } }
  return @{ code = 200; body = '<InputProxyChannel><id>1</id><sourceInputPortDescriptor><ipAddress>192.168.1.51</ipAddress><proxyProtocol>HIKVISION</proxyProtocol><managePortNo>8000</managePortNo><userName>admin</userName></sourceInputPortDescriptor></InputProxyChannel>' }
}
function Fs-HttpSecret { param($Ip, $Method, $Path, $Body, $Cred); return (Fs-Http -Ip $Ip -Method $Method -Path $Path -Body $Body -Cred $Cred) }
$pass = 0; $fail = 0
function Check([string]$what, [bool]$ok) { if ($ok) { $script:pass++; Write-Output ('PASS ' + $what) } else { $script:fail++; Write-Output ('FAIL ' + $what) } }
$L = '<InputProxyChannelStatusList>'; $E = '</InputProxyChannelStatusList>'
$cases = @(
  @{ n = 'status entry for ch 1 has no <online> flag'; b = ($L + '<InputProxyChannelStatus><id>1</id></InputProxyChannelStatus>' + $E); c = 200; free = $false },
  @{ n = 'status <online> is empty'; b = ($L + '<InputProxyChannelStatus><id>1</id><online></online></InputProxyChannelStatus>' + $E); c = 200; free = $false },
  @{ n = 'status <online> is garbled ("maybe")'; b = ($L + '<InputProxyChannelStatus><id>1</id><online>maybe</online></InputProxyChannelStatus>' + $E); c = 200; free = $false },
  @{ n = 'no status entry for ch 1 (only ch 2)'; b = ($L + '<InputProxyChannelStatus><id>2</id><online>false</online></InputProxyChannelStatus>' + $E); c = 200; free = $false },
  @{ n = 'status answer is not a status list'; b = '<ResponseStatus><statusCode>4</statusCode><online>false</online><id>1</id></ResponseStatus>'; c = 200; free = $false },
  @{ n = 'status read failed (HTTP 500)'; b = ($L + '<InputProxyChannelStatus><id>1</id><online>false</online></InputProxyChannelStatus>' + $E); c = 500; free = $false },
  @{ n = 'status says the other camera is live (true)'; b = ($L + '<InputProxyChannelStatus><id>1</id><online>true</online></InputProxyChannelStatus>' + $E); c = 200; free = $false },
  @{ n = 'control: status says explicitly false (offline)'; b = ($L + '<InputProxyChannelStatus><id>1</id><online>false</online></InputProxyChannelStatus>' + $E); c = 200; free = $true }
)
$rep = @()
foreach ($k in $cases) {
  $script:Writes = 0; $script:Status = $k.b; $script:StatusCode = $k.c
  $r = Set-FsNvrChannel '192.168.1.19' $null 1 '192.168.1.50' 'Sitepass123' 'Hikvision'
  $rep += @{ case = $k.n; writes = $script:Writes; action = [string]$r.action }
  if ($k.free) { Check ($k.n + ': the channel is updated') ($script:Writes -eq 1 -and $r.action -eq 'updated') }
  else { Check ($k.n + ': another camera''s channel is NOT overwritten and the reason is reported') ($script:Writes -eq 0 -and $r.action -eq 'refused' -and [string]$r.why) }
}
'REPRO=' + (@{ case = 'different-camera-missing-online'; results = $rep } | ConvertTo-Json -Compress -Depth 4)
Write-Output ('' + $pass + ' passed, ' + $fail + ' failed')
if ($fail) { exit 1 } else { exit 0 }
