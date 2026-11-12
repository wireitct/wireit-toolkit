# Codex 2.2.20 review reproduction reproduce-extra-review.ps1 (copied verbatim from the review evidence bundle, Nov 12 2026). Only adaptation: the
# reviewer's output folder '/workspace/review-2220' is $env:REPRO2220_OUT (a fresh temp folder per run). Run by Test-Repro2220.ps1.
# Second adaptation: $ErrorActionPreference 'Continue' instead of 'Stop' (as in repro-2.2.19), so one refusing call does not hide the later REPRO lines.
param([string]$Repo='/workspace/wireit-toolkit')
$ErrorActionPreference='Continue'
$out=($env:REPRO2220_OUT + '/extra')
New-Item -ItemType Directory -Force $out | Out-Null
. "$Repo/Toolkit/FixSiteCore.ps1"
. "$Repo/Toolkit/FixSiteDevices.ps1"

# Recovery may not certify a replacement adapter using the first adapter's ID.
$script:FsPcBefore=[pscustomobject]@{ifIndex=5;name='Ethernet';guid='guid-a';dhcp=$false;coexist='disabled';addrs=@([pscustomobject]@{ip='10.0.0.10';prefix=24;skip=$false});gw=@()}
$script:FsTemps.Clear(); [void]$script:FsTemps.Add([pscustomobject]@{ip='10.99.0.253';ifIndex=5})
$script:FsCoexistChanged=$false;$script:FsRestoreChecks=1
$script:device='A';$script:ids=0
$script:FsNetOps=@{
 ident={param($a) $script:ids++; [pscustomobject]@{name='Ethernet';guid=$(if($script:device -eq 'A'){'guid-a'}else{'guid-b'})}}
 remove={param($a) $script:device='B'; $true}
 state={param($a) [pscustomobject]@{dhcp=$false;coexist='disabled';addrs=@([pscustomobject]@{ip='10.0.0.10';prefix=24;skip=$false});gw=@();unread=@()}}
}
$jf="$out/site-swap.json"; Save-FsNetState $jf
$r=Restore-FsPcNet $jf
"REPRO site-recovery-adapter-swap ok=$($r.ok) identityReads=$script:ids journalExists=$(Test-Path $jf) actualAdapter=$script:device"

# Valid JSON with an impossible prefix must block before any adapter mutation.
$j='{"version":2,"coexistChanged":false,"temps":[],"before":{"ifIndex":5,"name":"Ethernet","guid":"guid-a","dhcp":false,"coexist":"disabled","addrs":[{"ip":"10.0.0.10","prefix":false}],"gw":[]}}'|ConvertFrom-Json
$why=Get-FsNetJournalProblem $j
$script:FsPcBefore=$j.before;$script:FsTemps.Clear();$script:ops=@();$script:added=$false
$script:FsNetOps=@{
 ident={param($a) [pscustomobject]@{name='Ethernet';guid='guid-a'}}
 state={param($a) [pscustomobject]@{dhcp=$false;coexist='disabled';addrs=$(if($script:added){@([pscustomobject]@{ip='10.0.0.10';prefix=0;skip=$false})}else{@()});gw=@();unread=@()}}
 addstatic={param($a) $script:ops+=('addstatic prefix='+[int]$a.prefix);$script:added=$true;$true}
}
$r=Restore-FsPcNet "$out/damaged-site.json"
"REPRO site-damaged-prefix validator='$why' writes=$($script:ops -join ',') ok=$($r.ok)"

# Unknown DHCP state from the native Windows API cannot clear a damaged-record block.
$script:FsNetOps=$null
function Get-NetIPInterface { [CmdletBinding()]param($InterfaceIndex,$AddressFamily) [pscustomobject]@{Dhcp='Unknown'} }
function netsh { 'DHCP/Static IP coexistence : disabled' }
function Get-NetIPAddress { [CmdletBinding()]param($InterfaceIndex,$AddressFamily) [pscustomobject]@{IPAddress='10.0.0.10';PrefixLength=24;SkipAsSource=$false;AddressState='Preferred';PrefixOrigin='Manual';PolicyStore='PersistentStore'} }
function Get-NetRoute { [CmdletBinding()]param($InterfaceIndex,$DestinationPrefix,$AddressFamily) }
$native=Invoke-FsNetOp 'state' @{ifIndex=5}
$script:FsNetOps=@{
 boottime={param($a) (Get-Date).ToUniversalTime()}
 skipaddrs={param($a) [pscustomobject]@{ips=@()}}
 allstate={param($a) [pscustomobject]@{adapters=@([pscustomobject]@{name='Ethernet';state=$native})}}
}
$w=Test-FsNetRecoveryVerified ((Get-Date).AddDays(-1).ToUniversalTime())
"REPRO site-clear-unknown-dhcp nativeDhcp=$($native.dhcp) unread=$($native.unread -join ',') recoveryWhy='$w'"

# The Dahua stream path has two writes within one caller's identity approval.
$script:device='A'; $script:writes=@()
function Fs-DhSet {param($ip,$cred,$kv) $script:writes+=($script:device+':'+($kv.Keys -join ','));$script:device='B';$true}
$diff=@([pscustomobject]@{field='smartCodec';to='off'},[pscustomobject]@{field='fps';to=15})
$r=Set-FsStream '10.0.0.21' Dahua $null $null $diff
"REPRO dahua-stream-swap ok=$($r.ok) writes=$($script:writes -join ';')"

# Load classic functions without launching discovery.
$ast=[Management.Automation.Language.Parser]::ParseFile("$Repo/FixNVR/FixNVR.ps1",[ref]$null,[ref]$null)
foreach($f in $ast.FindAll({param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($f.Extent.Text))}
function Log {param($s)}
$script:credCam=New-Object PSCredential('admin',(ConvertTo-SecureString 'Review123' -AsPlainText -Force));$script:credNvr=$script:credCam
$script:device='A';$script:writes=@();$script:chIp='10.0.0.21'
function Http {
 param($ip,$method,$path,$body,$contentType,$cred,$timeout)
 if($method -eq 'PUT'){$script:writes+=($script:device+':'+$path);$script:chIp='10.0.0.22';return @{code=200;body='<ResponseStatus><statusCode>1</statusCode></ResponseStatus>'}}
 return @{code=200;body=('<InputProxyChannel><id>1</id><sourceInputPortDescriptor><ipAddress>'+$script:chIp+'</ipAddress><userName>admin</userName></sourceInputPortDescriptor></InputProxyChannel>')}
}
function Read-FnIdentity {param($ip,$mac,$kind,$brand,$serial) if($kind -eq 'camera'){$script:device='B'};@{why='';dev=[pscustomobject]@{ip=$ip;mac=$mac;serial=$serial}}}
$nvr=[pscustomobject]@{ip='10.0.0.20';mac='AA:BB:CC:00:00:01';serial='ORIGINAL'}
$id=Read-FnIdentity $nvr.ip $nvr.mac nvr hik $nvr.serial
$r=Hik-SetChannel $id.dev 1 '10.0.0.22' '10.0.0.21' '10.0.0.22' 'AA:BB:CC:00:00:21' 'CAM1'
"REPRO classic-channel-nvr-swap ok=$($r.ok) writes=$($script:writes -join ';')"

$d=[pscustomobject]@{brand='hik';kind='camera';net_read=$true;net_ip='10.0.0.21';addressing='static';mask='255.255.255.0';gw='10.0.0.1';dns1='';dns2='';net_has=@{mask=$true;gw=$true;dns1=$false;dns2=$false}}
$net=Get-FnNetNow $d
"REPRO classic-missing-dns read=$($net.read) dns1='$($net.dns1)' dns2='$($net.dns2)' why='$($net.why)'"

# A failed first export's sent reservation disappears and the next run exports again.
. "$Repo/Toolkit/HikResetFlow.ps1"
$script:HkSubnetCheckOff=$true;$script:HkSay={param($t,$c)};$script:exports=0
$dv=[pscustomobject]@{serial='CAM123456789';mac='AA:BB:CC:00:00:21';model='IPC';ip='10.0.0.21';shortSerial='123456789';kind='camera';activated=$true;salt='';encrypt=$false;bootTime='SAME-BOOT'}
function Request-HikResetExport {param($dev) $script:exports++;[pscustomobject]@{ok=$false;request=$null;error='answer lost after send'}}
$sp="$out/new-export.json";Remove-Item $sp -ErrorAction SilentlyContinue
1..2|ForEach-Object{$s=Read-HikState $sp;[void](Export-HikRequests @($dv) "$out/requests" $s $sp)}
$back=Read-HikState $sp
"REPRO reset-new-export-answer-lost exports=$script:exports savedDevices=$(@($back.devices).Count) intents=$(@($back.intents).Count)"
