# Test-SiteCheck.ps1 - mock tests for SiteCheck.ps1 (no real devices; local mock HTTP on 127.0.0.1 only)
param([string]$Script = (Join-Path (Split-Path -Parent $PSScriptRoot) 'SiteCheck.ps1'))
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$pass = 0; $fail = 0
function Check($name, [scriptblock]$t) { try { $r = & $t; if ($r) { $script:pass++; Write-Output ('PASS ' + $name) } else { $script:fail++; Write-Output ('FAIL ' + $name) } } catch { $script:fail++; Write-Output ('FAIL ' + $name + ' : ' + $_.Exception.Message) } }
$errs = $null; [void][Management.Automation.PSParser]::Tokenize((Get-Content $Script -Raw), [ref]$errs)
Check 'script parses on this PowerShell' { $errs.Count -eq 0 }
$cmdPath = Join-Path (Split-Path -Parent $Script) 'WireIt-SiteCheck.cmd'
if (Test-Path $cmdPath) { $c = [IO.File]::ReadAllText($cmdPath); $i = $c.IndexOf('##' + 'PSSTART'); $e2 = $null; [void][Management.Automation.PSParser]::Tokenize($c.Substring($i), [ref]$e2)
  Check 'launcher .cmd embedded script parses' { $i -gt 0 -and $e2.Count -eq 0 }
  Check 'launcher .cmd embedded script == SiteCheck.ps1' { $c.Substring($i + 11).Trim() -eq (Get-Content $Script -Raw).Trim() } }
. $Script -LoadOnly
Check 'version set' { $script:SC_VERSION -match '^\d+\.\d+\.\d+$' }
Check 'subnet math' { (Test-ScSameSubnet '192.168.1.20' '192.168.1.200' 24) -and -not (Test-ScSameSubnet '192.168.1.20' '192.168.2.20' 24) -and (Test-ScSameSubnet '10.1.0.5' '10.1.200.9' 16) -and (Get-ScPrefixFromMask '255.255.252.0') -eq 22 }
Check 'IP validation' { (Test-ScIp '192.168.1.64') -and -not (Test-ScIp '192.168.1.256') -and -not (Test-ScIp 'abc') }
Check 'MAC vendor lookup' { (Get-ScVendor 'c4:2f:90:11:22:33') -eq 'Hikvision' -and (Get-ScVendor 'E0-50-8B-00-00-01') -eq 'Dahua' -and (Get-ScVendor '02-11-22-33-44-55') -eq 'random/private MAC' }

$sadp = '<?xml version="1.0" encoding="UTF-8"?><ProbeMatch><Uuid>X</Uuid><Types>inquiry</Types><DeviceDescription>DS-7732NI-I4/16P</DeviceDescription><DeviceSN>DS-7732NI-I4/16P1620190101CCRRD12345678WCVU</DeviceSN><MAC>c4-2f-90-00-00-10</MAC><IPv4Address>192.0.2.10</IPv4Address><IPv4SubnetMask>255.255.255.0</IPv4SubnetMask><IPv4Gateway>192.0.2.1</IPv4Gateway><SoftwareVersion>V4.30.085</SoftwareVersion><Activated>true</Activated></ProbeMatch>'
$sadp2 = $sadp.Replace('c4-2f-90-00-00-10', 'c4-2f-90-00-00-99').Replace('DS-7732NI-I4/16P', 'DS-2CD2143G0-I')
$onvif = '<?xml version="1.0"?><SOAP-ENV:Envelope><SOAP-ENV:Body><d:ProbeMatches><d:ProbeMatch><d:Scopes>onvif://www.onvif.org/name/Dahua onvif://www.onvif.org/hardware/IPC-HDW2431T</d:Scopes><d:XAddrs>http://192.0.2.22/onvif/device_service</d:XAddrs></d:ProbeMatch></d:ProbeMatches></SOAP-ENV:Body></SOAP-ENV:Envelope>'
$disc = @(ConvertFrom-ScDiscovery @([pscustomobject]@{ From = '192.0.2.10'; Text = $sadp }, [pscustomobject]@{ From = '192.0.2.10'; Text = $sadp2 }, [pscustomobject]@{ From = '192.0.2.22'; Text = $onvif }))
Check 'discovery parses SADP (2 answers, same IP) + ONVIF' { $disc.Count -eq 3 -and @($disc | Where-Object { $_.Source -eq 'ONVIF' -and $_.Brand -eq 'Dahua' -and $_.Model -eq 'IPC-HDW2431T' -and $_.Ip -eq '192.0.2.22' }).Count -eq 1 -and @($disc | Where-Object { $_.Model -eq 'DS-7732NI-I4/16P' -and $_.Mac -eq 'C4-2F-90-00-00-10' }).Count -eq 1 }

$hikS = '<?xml version="1.0" encoding="UTF-8"?><InputProxyChannelStatusList version="2.0" xmlns="http://www.isapi.org/ver20/XMLSchema"><InputProxyChannelStatus version="2.0"><id>1</id><sourceInputPortDescriptor><proxyProtocol>HIKVISION</proxyProtocol><ipAddress>192.0.2.21</ipAddress><managePortNo>8000</managePortNo></sourceInputPortDescriptor><online>true</online><chanDetectResult>connect</chanDetectResult></InputProxyChannelStatus><InputProxyChannelStatus version="2.0"><id>5</id><sourceInputPortDescriptor><proxyProtocol>ONVIF</proxyProtocol><ipAddress>192.0.2.85</ipAddress></sourceInputPortDescriptor><online>false</online><chanDetectResult>netUnreachable</chanDetectResult></InputProxyChannelStatus></InputProxyChannelStatusList>'
$hikN = '<InputProxyChannelList><InputProxyChannel version="2.0"><id>1</id><name>Front</name></InputProxyChannel><InputProxyChannel version="2.0"><id>5</id><name>Back lot</name></InputProxyChannel></InputProxyChannelList>'
$hc = @(ConvertFrom-ScHikStatus $hikS $hikN)
Check 'Hikvision channel status parse' { $hc.Count -eq 2 -and $hc[1].Ch -eq 5 -and -not $hc[1].Online -and $hc[1].Ip -eq '192.0.2.85' -and $hc[1].Name -eq 'Back lot' -and $hc[1].Detail -eq 'netUnreachable' -and $hc[0].Online }
$dS = "states[0].channel=0`r`nstates[0].connectionState=Connected`r`nstates[1].channel=1`r`nstates[1].connectionState=Disconnected`r`nstates[2].channel=2`r`nstates[2].connectionState=Disconnected"
$dR = "table.RemoteDevice.uuid:System_CONFIG_NETCAMERA_INFO_0.Address=192.0.2.31`r`ntable.RemoteDevice.uuid:System_CONFIG_NETCAMERA_INFO_0.Enable=true`r`ntable.RemoteDevice.uuid:System_CONFIG_NETCAMERA_INFO_0.Password=NOT-A-REAL-PW-1`r`ntable.RemoteDevice.uuid:System_CONFIG_NETCAMERA_INFO_1.Address=192.0.2.32`r`ntable.RemoteDevice.uuid:System_CONFIG_NETCAMERA_INFO_1.Enable=true`r`ntable.RemoteDevice.uuid:System_CONFIG_NETCAMERA_INFO_2.Address=192.168.0.0`r`ntable.RemoteDevice.uuid:System_CONFIG_NETCAMERA_INFO_2.Enable=false"
$dT = "table.ChannelTitle[0].Name=Gate`r`ntable.ChannelTitle[1].Name=Yard"
$dc = @(ConvertFrom-ScDahuaStatus $dS $dR $dT)
Check 'Dahua camera state parse (disabled empty channel skipped)' { $dc.Count -eq 2 -and $dc[0].Ch -eq 1 -and $dc[0].Online -and $dc[1].Ch -eq 2 -and -not $dc[1].Online -and $dc[1].Ip -eq '192.0.2.32' -and $dc[1].Name -eq 'Yard' }
Check 'Dahua parse keeps no password' { -not (($dc | ConvertTo-Json) -match 'NOT-A-REAL-PW-1') }

$R = New-ScMock; $D = Get-ScDiagnosis $R; $txt = ($D.Findings | ForEach-Object { $_.Text }) -join "`n"
Check 'headline names the down channels' { $D.Headline -match '^4 of 6 cameras are NOT working' -and $D.Headline -match 'ch 2' -and $D.Headline -match 'ch 6' }
Check 'ch 2 camera on network but no video -> frozen/reboot' { $txt -match 'ch 2  192\.0\.2\.22.*ON the network.*Reboot' }
Check 'ch 4 IP conflict' { $txt -match 'ch 4  192\.0\.2\.24.*IP CONFLICT' }
Check 'ch 5 nothing answers -> power/link' { $txt -match 'ch 5  192\.0\.2\.85.*Nothing answers.*PoE switch' }
Check 'ch 6 behind NVR PoE ports' { $txt -match 'ch 6  192\.168\.254\.7.*NVR''s own PoE ports' }
Check 'ch 3 online but flaky (30% loss)' { $txt -match 'ch 3  192\.0\.2\.23 is up but drops 30%' }
Check 'camera on a different IP scheme flagged' { $txt -match '10\.0\.0\.64.*DIFFERENT IP scheme' }
Check 'NVR read-only names included (internal report)' { $txt -match '"Lobby"' }
$R2 = New-ScMock; foreach ($c in $R2.channels) { if ($c.Ch -in 1, 2, 3) { $c.Online = $false; $c.Ip = '192.0.2.1' + $c.Ch + '0' } }
$D2 = Get-ScDiagnosis $R2
Check '3+ dead cameras -> shared PoE switch first' { $D2.Findings[0].Text -match 'ONE shared thing' }
$R3 = New-ScMock; $R3.nvr = '192.0.2.10'; $R3.devices = @($R3.devices | Where-Object { $_.Ip -ne '192.0.2.10' }); $R3.channels = @(); $R3.nvrRead = $null
$D3 = Get-ScDiagnosis $R3
Check 'NVR not answering is reported' { (($D3.Findings | ForEach-Object { $_.Text }) -join ' ') -match 'NVR 192\.0\.2\.10 is NOT answering' }
Check 'no-login headline asks for password' { $D3.Headline -match 'Type the NVR password' }
$R4 = New-ScMock; $R4.channels = @(); $R4.nvrRead = $null; $R4.duplicates = @(); $R4.previous = @([pscustomobject]@{ ip = '192.0.2.99'; vendor = 'Hikvision' }); $R4.previousWhen = '2026-11-01 10:00:00'
Check 'device missing since last run flagged' { ((Get-ScDiagnosis $R4).Findings | ForEach-Object { $_.Text }) -join ' ' -match '192\.0\.2\.99 \(Hikvision\) answered last time' }
$R5 = New-ScMock; $R5.channels = @($R5.channels | ForEach-Object { $_.Online = $true; $_ }); $R5.duplicates = @(); foreach ($dv in $R5.devices) { if ($dv.Ok -gt 0) { $dv.Ok = 20; $dv.LossPct = 0 }; $dv.DiffSubnet = $false }; $R5.devices = @($R5.devices | Where-Object { $_.Ok -gt 0 })
$D5 = Get-ScDiagnosis $R5
Check 'all good -> green headline' { $D5.Headline -eq 'All 6 cameras on the NVR are online.' -and $D5.Bad -eq 0 -and $D5.Findings[0].Level -eq 'ok' }

$R7 = New-ScMock; $R7.channels = @(); $R7.duplicates = @(); $R7.devices += [pscustomobject]@{ Ip = '192.0.2.77'; Mac = '02-00-00-00-00-77'; Vendor = 'random/private MAC'; Model = ''; Kind = ''; Sent = 20; Ok = 8; LossPct = 60; Median = 80; Max = 300; Ports = @(); InArp = $true; DiffSubnet = $false; Firmware = ''; Source = '' }
Check 'phones/laptops with ping loss are not flagged' { -not ((((Get-ScDiagnosis $R7).Findings | ForEach-Object { $_.Text }) -join ' ') -match '192\.0\.2\.77') }
$tmp = Join-Path $env:TEMP ('sctest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$s = Save-ScReport $R $D $tmp
Check 'report txt + json + last-scan saved' { (Test-Path $s.Txt) -and (Test-Path $s.Json) -and (Test-Path (Join-Path $tmp 'last-scan.json')) }
Check 'json report is valid and has findings' { $j = Get-Content $s.Json -Raw | ConvertFrom-Json; @($j.findings).Count -ge 5 -and $j.headline -match 'NOT working' }
$R6 = New-ScMock; Read-ScPrevious $R6 $tmp
Check 'previous run read back' { @($R6.previous).Count -ge 4 }
Check 'report text has channel table + device table' { $s.Text -match 'NVR CHANNELS' -and $s.Text -match 'DEVICES THAT ANSWERED' -and $s.Text -match 'Nothing was changed' }
Check 'upload needs both Site ID and code' { (Send-ScReport $R $D '' 'ABC123') -like 'Upload is off*' }
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

# ---- local mock NVR on 127.0.0.1 (proves the HTTP read path and the one-login-try rule) ----
function Start-MockNvr([int]$port, [string]$mode) {
  $rs = [runspacefactory]::CreateRunspace(); $rs.Open(); $p = [powershell]::Create(); $p.Runspace = $rs
  $state = [hashtable]::Synchronized(@{ Count = 0; Paths = (New-Object Collections.ArrayList) })
  $rs.SessionStateProxy.SetVariable('state', $state); $rs.SessionStateProxy.SetVariable('hikS', $hikS); $rs.SessionStateProxy.SetVariable('hikN', $hikN)
  [void]$p.AddScript({ param($port, $mode)
    $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $port); $l.Start()
    $end = (Get-Date).AddSeconds(25)
    while ((Get-Date) -lt $end) {
      if (-not $l.Pending()) { Start-Sleep -Milliseconds 30; continue }
      $c = $l.AcceptTcpClient(); $st = $c.GetStream(); $rd = New-Object IO.StreamReader($st)
      $line = $rd.ReadLine(); while (($h = $rd.ReadLine()) -ne '' -and $h -ne $null) {}
      $state.Count++; $path = ($line -split ' ')[1]; [void]$state.Paths.Add($path)
      if ($mode -eq 'deny') { $resp = "HTTP/1.1 401 Unauthorized`r`nWWW-Authenticate: Digest realm=`"x`", nonce=`"abc`", qop=`"auth`"`r`nContent-Length: 0`r`nConnection: close`r`n`r`n" }
      else {
        $body = '<x/>'; if ($path -like '*deviceInfo*') { $body = '<DeviceInfo><model>DS-TEST</model></DeviceInfo>' } elseif ($path -like '*channels/status*') { $body = $hikS } elseif ($path -like '*InputProxy/channels*') { $body = $hikN }
        $b = [Text.Encoding]::UTF8.GetBytes($body); $resp = "HTTP/1.1 200 OK`r`nContent-Type: application/xml`r`nContent-Length: " + $b.Length + "`r`nConnection: close`r`n`r`n" + $body
      }
      $o = [Text.Encoding]::UTF8.GetBytes($resp); $st.Write($o, 0, $o.Length); $st.Flush(); $c.Close()
    }
    $l.Stop() }).AddArgument($port).AddArgument($mode)
  $h = $p.BeginInvoke(); Start-Sleep -Milliseconds 400
  return [pscustomobject]@{ P = $p; Rs = $rs; State = $state }
}
$m = Start-MockNvr 18731 'ok'
$sec = New-Object Security.SecureString; 'pw-test'.ToCharArray() | ForEach-Object { $sec.AppendChar($_) }; $cr = New-Object PSCredential('admin', $sec)
$nv = Get-ScNvrChannels '127.0.0.1:18731' $cr @(80)
Check 'mock Hikvision NVR read over HTTP (GET only)' { $nv.Ok -and $nv.Brand -eq 'Hikvision' -and @($nv.Channels).Count -eq 2 -and $nv.Model -eq 'DS-TEST' }
Check 'only ISAPI GET paths were requested' { @($m.State.Paths | Where-Object { $_ -notlike '/ISAPI/*' }).Count -eq 0 }
$m.P.Stop(); $m.Rs.Close()
$m = Start-MockNvr 18732 'deny'
$nv2 = Get-ScNvrChannels '127.0.0.1:18732' $cr @(80)
Check 'wrong password -> plain message, stops after one login try' { $nv2.Msg -match 'wrong' -and -not $nv2.Ok -and $m.State.Count -le 2 -and @($m.State.Paths | Where-Object { $_ -like '*cgi-bin*' }).Count -eq 0 }
$m.P.Stop(); $m.Rs.Close()
# upload (Send-ScReport, v1.1.0) against a local mock on 127.0.0.1: Site ID + code sent, no password / user / camera names
$upState = [hashtable]::Synchronized(@{ Body = '' })
$upRs = [runspacefactory]::CreateRunspace(); $upRs.Open(); $upRs.SessionStateProxy.SetVariable('st', $upState)
$upPs = [powershell]::Create(); $upPs.Runspace = $upRs
[void]$upPs.AddScript({ $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 18741); $l.Start(); try { $c = $l.AcceptTcpClient(); $s = $c.GetStream(); $s.ReadTimeout = 5000; $buf = New-Object byte[] 262144; $got = 0; $txt = ''; $hi = -1; $len = 0
  do { $n = $s.Read($buf, $got, $buf.Length - $got); $got += $n; $txt = [Text.Encoding]::UTF8.GetString($buf, 0, $got); $hi = $txt.IndexOf("`r`n`r`n"); if ($hi -ge 0 -and $txt -match 'Content-Length:\s*(\d+)') { $len = [int]$matches[1] } } while ($n -gt 0 -and ($hi -lt 0 -or ($got - [Text.Encoding]::UTF8.GetByteCount($txt.Substring(0, $hi + 4))) -lt $len))
  $st.Body = $txt.Substring($hi + 4); $resp = '{"ok":true,"msg":"Posted"}'; $h = "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: " + $resp.Length + "`r`nConnection: close`r`n`r`n" + $resp; $b = [Text.Encoding]::ASCII.GetBytes($h); $s.Write($b, 0, $b.Length); $s.Flush(); Start-Sleep -Milliseconds 200; $c.Close() } finally { $l.Stop() } })
$upH = $upPs.BeginInvoke(); Start-Sleep -Milliseconds 500
$mR = New-ScMock; $mD = Get-ScDiagnosis $mR
$upOld = $script:SC_UPLOAD_URL; $script:SC_UPLOAD_URL = 'http://127.0.0.1:18741/'
$upMsg = Send-ScReport $mR $mD 'wi-061' 'abc123'
$script:SC_UPLOAD_URL = $upOld
[void]$upH.AsyncWaitHandle.WaitOne(5000); $upPs.Dispose(); $upRs.Close()
Check 'upload: posted, plain answer for the status bar' { $upMsg -eq 'Results posted to the site page.' }
Check 'upload: siteCheckPush with Site ID + code (upper case)' { $upState.Body -match '"op":"siteCheckPush"' -and $upState.Body -match '"site":"WI-061"' -and $upState.Body -match '"code":"ABC123"' }
Check 'upload: no password, no user, no camera names' { $b = $upState.Body; $b.Length -gt 100 -and $b -notmatch 'password' -and $b -notmatch '"name"' -and $b -notmatch '"user"' -and $b -cnotmatch 'Front door|Lobby|Back lot|Stairs|Gym|Hall' }
Check 'upload off without a code' { (Send-ScReport $mR $mD 'WI-061' '') -like 'Upload is off*' }
Check 'upload goes to the WireIt service log' { $upOld -eq 'https://wireit-api.wireitct.workers.dev/' }
Write-Output ('RESULT ' + $pass + ' passed, ' + $fail + ' failed')

exit $fail
