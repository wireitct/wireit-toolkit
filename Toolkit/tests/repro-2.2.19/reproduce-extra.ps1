# Codex 2.2.19 review reproduction reproduce-extra.ps1 (copied verbatim from the review evidence, Nov 11 2026). Only adaptation: the
# reviewer's output folder '/workspace/review-2219' is $env:REPRO2219_OUT (a fresh temp folder per run). Run by Test-Repro2219.ps1.
# Second adaptation (2.2.20): Undo-TkUpdate's refusal (a throw) is caught and printed as returned=REFUSED(...), so the state after it is still measured.
param([string]$Repo='/workspace/wireit-toolkit')
$ErrorActionPreference='Continue'
$out=($env:REPRO2219_OUT + '')
$ast=[Management.Automation.Language.Parser]::ParseFile("$Repo/FixNVR/FixNVR.ps1",[ref]$null,[ref]$null)
foreach($f in $ast.FindAll({param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($f.Extent.Text))}
function Log {param($s)}
function Get-FnBootTime {Get-Date}
function Get-NetIPAddress {[CmdletBinding()]param($AddressFamily) @([pscustomobject]@{IPAddress='10.0.0.100';SkipAsSource=$false;ifIndex=5},[pscustomobject]@{IPAddress='10.0.0.123';SkipAsSource=$true;ifIndex=6})}
function Get-NetIPInterface {[CmdletBinding()]param($AddressFamily) @([pscustomobject]@{ConnectionState='Connected';InterfaceAlias='Ethernet';ifIndex=5;Dhcp='Enabled'},[pscustomobject]@{ConnectionState='Connected';InterfaceAlias='BrokenStatic';ifIndex=6;Dhcp='Disabled'})}
function netsh {'DHCP/Static IP coexistence : disabled'}
function Get-PcNet {[pscustomobject]@{ip='10.0.0.100';gw='10.0.0.1'}}
$cfg=[pscustomobject]@{temp_ip_hosts=@(253,252,247)}
$file=[pscustomobject]@{Name='temp-ips.unreadable-20260101-000000.json';LastWriteTime=[datetime]'2026-01-01'}
"REPRO classic-clear-with-unrecovered-static-and-skip reason='$(Get-FnUnreadableClearWhy $file)'"
$d=[pscustomobject]@{brand='hik';net_read=$true;net_ip='10.0.0.20';addressing='static';mask='';gw='';dns1='';dns2=''}
$n=Get-FnNetNow $d
"REPRO classic-missing-mask-gateway read=$($n.read) why='$($n.why)'"
$j='{"version":2,"temps":[{"ip":"192.168.99.253","ifIndex":5}],"pc":{"coexistence_before":"disabled","firewall_rule":false,"cleanup_task":false,"ifIndex":5,"alias":"Ethernet","dhcp":"false","ip":"10.0.0.10","gw":"10.0.0.1"}}'|ConvertFrom-Json
"REPRO classic-damaged-dhcp journalWhy='$(Get-FnJournalWhy $j)' dhcpAsBool=$([bool]$j.pc.dhcp)"
$script:channelAddress='192.168.1.60';$script:channelWrites=0;$script:channelReads=@()
$script:credCam=New-Object PSCredential('admin',(ConvertTo-SecureString 'Review123' -AsPlainText -Force));$script:credNvr=$script:credCam
function Http {
 param($ip,$method,$path,$body,$ctype,$cred,$timeout)
 $script:channelReads+=($ip+' '+$method+' '+$path)
 if($method -eq 'PUT'){$script:channelWrites++;$script:channelAddress='192.168.1.50';return @{code=200;body='<ResponseStatus><statusCode>1</statusCode></ResponseStatus>'}}
 return @{code=200;body=('<InputProxyChannel><id>1</id><sourceInputPortDescriptor><ipAddress>'+$script:channelAddress+'</ipAddress><userName>admin</userName><password>OTHER-CAMERA-PASSWORD</password></sourceInputPortDescriptor></InputProxyChannel>')}
}
$r=Hik-SetChannel ([pscustomobject]@{ip='192.168.1.19'}) '1' '192.168.1.50' '192.168.1.60'
"REPRO classic-channel-no-camera-identity writes=$script:channelWrites ok=$($r.ok) requests=$($script:channelReads -join '; ')"

$m=Import-Module "$Repo/Toolkit/modules/NvrHealth/NvrHealth.psm1" -Force -PassThru
& $m {
 param($out)
 Set-NvrHealthOption LogDir "$out/extra-nvr-logs"
 $c=New-Object PSCredential('admin',(ConvertTo-SecureString 'Review123' -AsPlainText -Force))
 $script:reboots=0
 function script:Http {
  param($Ip,$Method='GET',$Path,$Body,$ContentType,$Credential,$Headers,$Port,$Scheme,[switch]$NoLogBody,$Timeout,$BodyBytes,$OutFile,[switch]$SecretTransport)
  if($Path -eq '/LAPI/V1.0/System/Reboot'){$script:reboots++;return @{code=200;body='<html>connection interrupted after reboot</html>'}}
  if($Path -eq '/LAPI/V1.0/System/DeviceInfo'){return @{code=200;body='{"Response":{"ResponseCode":0,"Data":{"SerialNumber":"CAM1","DeviceModel":"IPC","FirmwareVersion":"B123","MAC":"AA:BB:CC:00:00:01"}}}'}}
  return @{code=404;body=''}
 }
 $sf="$out/restart-malformed.json";Remove-Item $sf -ErrorAction SilentlyContinue
 $r=Invoke-NvrFix -Fix restart -Ip '10.0.0.21' -Vendor Uniview -Credential $c -StateFile $sf -BackupDir "$out/restart-backup" -Confirm {'YES'} -WaitSec 1
 $lim=Fix-LimitOk $sf '10.0.0.21' (Get-Date)
 $r2=Invoke-NvrFix -Fix restart -Ip '10.0.0.21' -Vendor Uniview -Credential $c -StateFile $sf -BackupDir "$out/restart-backup" -Confirm {'YES'} -WaitSec 1
 "REPRO malformed-reboot-answer writes=$script:reboots nextBudgetOk=$($lim.ok) msg=$($r.msg)"
} $out

. "$Repo/Toolkit/ToolkitCore.ps1"
$root="$out/update-mismatch";$tk="$root/Toolkit";$prev="$tk/previous/9.9.8"
New-Item -ItemType Directory -Force $prev | Out-Null
[IO.File]::WriteAllText("$tk/version.json",'{"version":"9.9.9","previous":"9.9.8"}')
[IO.File]::WriteAllText("$prev/version.json.prev",'{"version":"9.9.7"}')
[IO.File]::WriteAllText("$prev/undo.json",'{"from":"9.9.8","to":"9.9.9","added":[]}')
[IO.File]::WriteAllText("$prev/tool.txt",'old 9.9.8 code')
$r=try { Undo-TkUpdate $tk } catch { 'REFUSED(' + ($_.Exception.Message -replace '\s+',' ') + ')' }   # Tab 2.2.20 adaptation: a refusal (throw) is caught so the REPRO line still prints the state after it
$v=Read-TkJson "$tk/version.json"
"REPRO undo-version-mismatch returned=$r installedVersion=$($v.version) journalExists=$(Test-Path "$tk/previous/update-pending.json")"
