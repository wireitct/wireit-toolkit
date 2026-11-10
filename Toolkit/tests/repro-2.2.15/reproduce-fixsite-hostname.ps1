# reproduce-fixsite-hostname.ps1 - Codex 2.2.15 review F4 (adapted to run from the repo and ASSERT the safe outcome).
# Set-FsNvrChannel (Fix this site's channel writer) must not overwrite a configured channel whose camera is addressed by NAME
# (addressingFormatType=hostname, hostName=working-camera.local), by IPv6 or with an odd address type: the tool cannot check that
# camera, so no PUT, action=refused, reason reported - whatever the status list says. Control: the same explicit-offline case with a
# plain IP-addressed channel is still updated. Also: a 200 answer that is not a channel is refused, a 404 (no channel) is added.
param([string]$Repo = '')
$ErrorActionPreference = 'Stop'
if (-not $Repo) { $Repo = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path }
. (Join-Path $Repo 'Toolkit/FixSiteCore.ps1')
. (Join-Path $Repo 'Toolkit/FixSiteDevices.ps1')
function Fs-LogLine { param($t) }
$script:Writes = 0; $script:Status = ''; $script:StatusCode = 200; $script:ChCode = 200
$script:Addr = '<addressingFormatType>hostname</addressingFormatType><hostName>working-camera.local</hostName>'
function Fs-Http {
  param($Ip, $Method = 'GET', $Path, $Cred, $Body, $Timeout, $OutFile)
  if ($Method -eq 'PUT' -or $Method -eq 'POST') { $script:Writes++; return @{ code = 200; body = '<ResponseStatus><statusCode>1</statusCode></ResponseStatus>' } }
  if ($Path -like '*/status') { return @{ code = $script:StatusCode; body = $script:Status } }
  if ($script:ChCode -ne 200) { return @{ code = $script:ChCode; body = '' } }
  if ($script:Addr -eq 'NOTCHANNEL') { return @{ code = 200; body = '<ResponseStatus><statusCode>4</statusCode><ipAddress>192.168.1.77</ipAddress></ResponseStatus>' } }
  return @{ code = 200; body = ('<InputProxyChannel><id>1</id><sourceInputPortDescriptor>' + $script:Addr + '<proxyProtocol>HIKVISION</proxyProtocol><managePortNo>8000</managePortNo><userName>admin</userName></sourceInputPortDescriptor></InputProxyChannel>') }
}
function Fs-HttpSecret { param($Ip, $Method, $Path, $Body, $Cred); return (Fs-Http -Ip $Ip -Method $Method -Path $Path -Body $Body -Cred $Cred) }
$pass = 0; $fail = 0
function Check([string]$what, [bool]$ok) { if ($ok) { $script:pass++; Write-Output ('PASS ' + $what) } else { $script:fail++; Write-Output ('FAIL ' + $what) } }
$L = '<InputProxyChannelStatusList>'; $E = '</InputProxyChannelStatusList>'
$off = ($L + '<InputProxyChannelStatus><id>1</id><online>false</online></InputProxyChannelStatus>' + $E)
$cases = @(
  @{ n = 'hostname channel, status entry has no <online> flag'; b = ($L + '<InputProxyChannelStatus><id>1</id></InputProxyChannelStatus>' + $E); c = 200 },
  @{ n = 'hostname channel, status <online> is empty'; b = ($L + '<InputProxyChannelStatus><id>1</id><online></online></InputProxyChannelStatus>' + $E); c = 200 },
  @{ n = 'hostname channel, status <online> is garbled ("maybe")'; b = ($L + '<InputProxyChannelStatus><id>1</id><online>maybe</online></InputProxyChannelStatus>' + $E); c = 200 },
  @{ n = 'hostname channel, no status entry for ch 1 (only ch 2)'; b = ($L + '<InputProxyChannelStatus><id>2</id><online>false</online></InputProxyChannelStatus>' + $E); c = 200 },
  @{ n = 'hostname channel, status answer is not a status list'; b = '<ResponseStatus><statusCode>4</statusCode><online>false</online><id>1</id></ResponseStatus>'; c = 200 },
  @{ n = 'hostname channel, status read failed (HTTP 500)'; b = $off; c = 500 },
  @{ n = 'hostname channel, status says the camera is live (true)'; b = ($L + '<InputProxyChannelStatus><id>1</id><online>true</online></InputProxyChannelStatus>' + $E); c = 200 },
  @{ n = 'hostname channel, status says explicitly false (the name cannot be checked)'; b = $off; c = 200 }
)
$rep = @()
foreach ($k in $cases) {
  $script:Writes = 0; $script:Status = $k.b; $script:StatusCode = $k.c
  $r = Set-FsNvrChannel '192.168.1.19' $null 1 '192.168.1.50' 'Sitepass123' 'Hikvision'
  $rep += @{ case = $k.n; writes = $script:Writes; action = [string]$r.action }
  Check ($k.n + ': the channel is NOT overwritten and the reason is reported') ($script:Writes -eq 0 -and $r.action -eq 'refused' -and [string]$r.why)
}
$more = @(
  @{ n = 'IPv6-addressed channel (explicit offline)'; a = '<addressingFormatType>ipaddress</addressingFormatType><ipv6Address>fe80::1</ipv6Address>' },
  @{ n = 'odd address type "domain" with an IP beside it (explicit offline)'; a = '<addressingFormatType>domain</addressingFormatType><ipAddress>192.168.1.77</ipAddress>' },
  @{ n = 'IP plus a hostName beside it (explicit offline)'; a = '<addressingFormatType>ipaddress</addressingFormatType><ipAddress>192.168.1.77</ipAddress><hostName>working-camera.local</hostName>' },
  @{ n = 'configured channel with no readable address (explicit offline)'; a = '<addressingFormatType>ipaddress</addressingFormatType>' },
  @{ n = 'the 200 answer is not a channel (explicit offline)'; a = 'NOTCHANNEL' }
)
foreach ($k in $more) {
  $script:Writes = 0; $script:Status = $off; $script:StatusCode = 200; $script:Addr = $k.a
  $r = Set-FsNvrChannel '192.168.1.19' $null 1 '192.168.1.50' 'Sitepass123' 'Hikvision'
  $rep += @{ case = $k.n; writes = $script:Writes; action = [string]$r.action }
  Check ($k.n + ': NOT overwritten, reason reported') ($script:Writes -eq 0 -and $r.action -eq 'refused' -and [string]$r.why)
}
$script:Writes = 0; $script:Status = $off; $script:StatusCode = 200; $script:Addr = '<addressingFormatType>hostname</addressingFormatType><hostName>working-camera.local</hostName>'; $script:ChCode = 500
$r = Set-FsNvrChannel '192.168.1.19' $null 1 '192.168.1.50' 'Sitepass123' 'Hikvision'
$rep += @{ case = 'channel read HTTP 500'; writes = $script:Writes; action = [string]$r.action }
Check 'channel read failed (HTTP 500): nothing is added or overwritten' ($script:Writes -eq 0 -and $r.action -eq 'refused')
$script:Writes = 0; $script:Addr = '<addressingFormatType>ipaddress</addressingFormatType><ipAddress>192.168.1.77</ipAddress>'; $script:ChCode = 200
$r = Set-FsNvrChannel '192.168.1.19' $null 1 '192.168.1.50' 'Sitepass123' 'Hikvision'
$rep += @{ case = 'control ip explicit offline'; writes = $script:Writes; action = [string]$r.action }
Check 'control: IP-addressed channel whose camera is explicitly offline is still updated' ($script:Writes -eq 1 -and $r.action -eq 'updated')
$script:Writes = 0; $script:ChCode = 404
$r = Set-FsNvrChannel '192.168.1.19' $null 1 '192.168.1.50' 'Sitepass123' 'Hikvision'
Check 'control: a channel that does not exist (404) is added' ($script:Writes -eq 1 -and $r.action -eq 'added')
'REPRO=' + (@{ case = 'fixsite-hostname-channel'; results = $rep } | ConvertTo-Json -Compress -Depth 4)
Write-Output ('' + $pass + ' passed, ' + $fail + ' failed')
if ($fail) { exit 1 } else { exit 0 }
