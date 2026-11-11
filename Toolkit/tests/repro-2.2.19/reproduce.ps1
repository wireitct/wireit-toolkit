# Codex 2.2.19 review reproduction reproduce.ps1 (copied verbatim from the review evidence, Nov 11 2026). Only adaptation: the
# reviewer's output folder '/workspace/review-2219' is $env:REPRO2219_OUT (a fresh temp folder per run). Run by Test-Repro2219.ps1.
param([string]$Repo = '/workspace/wireit-toolkit')
$ErrorActionPreference = 'Continue'
. "$Repo/Toolkit/FixSiteCore.ps1"
. "$Repo/Toolkit/FixSiteDevices.ps1"
$out = ($env:REPRO2219_OUT + '')

# A neighbor query that cannot be read must not certify an address free.
function New-Object {
 param($TypeName)
 if($TypeName -eq 'Net.NetworkInformation.Ping'){
  $p=[pscustomobject]@{}
  $p|Add-Member -MemberType ScriptMethod -Name Send -Value {param($ip,$ms) [pscustomobject]@{Status='TimedOut'}}
  return $p
 }
 Microsoft.PowerShell.Utility\New-Object $TypeName
}
function Get-NetNeighbor { [CmdletBinding()]param($IPAddress) Write-Error 'neighbor provider unavailable' }
"REPRO site-free-on-query-error=$(Test-FsIpFree '127.0.0.77')"
Remove-Item function:New-Object

# Save-FsNetState runs under the real caller's Continue preference.
function Move-Item { [CmdletBinding()]param($LiteralPath,$Destination,[switch]$Force) Write-Error 'journal final move denied' }
$script:FsNetOps = @{
 state = { [pscustomobject]@{ dhcp=$false; coexist='disabled'; addrs=@([pscustomobject]@{ip='10.0.0.10';prefix=24;skip=$false});gw=@();unread=@() } }
 ident = { [pscustomobject]@{name='Ethernet';guid='guid-a'} }
 free = { $true }
 addtemp = { $script:siteWrites++; 'Preferred' }
}
$script:siteWrites=0
$journal = "$out/denied-journal.json"
Remove-Item $journal -ErrorAction SilentlyContinue
$answer = Add-FsTempIp '192.168.99' ([pscustomobject]@{ifIndex=5;name='Ethernet'}) $journal
"REPRO site-save-failed returned=$answer writes=$script:siteWrites journalExists=$(Test-Path $journal)"
Remove-Item function:Move-Item

$script:netXml='<IPAddress><addressingType>static</addressingType><ipAddress>10.0.0.20</ipAddress><subnetMask>255.255.255.0</subnetMask><DefaultGateway><ipAddress>10.0.0.1</ipAddress></DefaultGateway></IPAddress>'
function Fs-Http {
 param($Ip,$Method='GET',$Path,$Cred,$Body,$Timeout,$OutFile)
 if($Method -eq 'PUT'){$script:netXml=$Body;return @{code=200;body='<ResponseStatus><statusCode>1</statusCode></ResponseStatus>'}}
 if($Path -eq '/ISAPI/System/Network/interfaces'){return @{code=200;body='<NetworkInterfaceList><NetworkInterface><id>1</id></NetworkInterface></NetworkInterfaceList>'}}
 return @{code=200;body=$script:netXml}
}
$n=Get-FsNet '10.0.0.20' Hikvision $null
$w=Set-FsNet '10.0.0.20' Hikvision $null $n '10.0.0.20' '255.255.255.0' '10.0.0.1' '8.8.8.8' '1.1.1.1'
$why=Get-FsNetMismatch '10.0.0.20' Hikvision $null $n '10.0.0.20' '255.255.255.0' '10.0.0.1' '8.8.8.8' '1.1.1.1'
"REPRO site-missing-DNS writeOk=$($w.ok) writtenDnsNode=$($script:netXml -match 'DNS') verificationWhy='$why'"

# Load classic function definitions without running discovery or platform commands.
$ast=[Management.Automation.Language.Parser]::ParseFile("$Repo/FixNVR/FixNVR.ps1",[ref]$null,[ref]$null)
foreach($f in $ast.FindAll({param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst]},$false)) { . ([scriptblock]::Create($f.Extent.Text)) }
function Log { param($s) }
function Say { param($s,$color) Write-Host $s }
function Start-Sleep { }
function Set-SafetyTask { }
function netsh { 'DHCP/Static IP coexistence : disabled' }
function Write-TempState { $true }
function Get-NetAdapter { [CmdletBinding()]param($InterfaceIndex) [pscustomobject]@{Name='REPLACEMENT';InterfaceGuid='guid-b'} }
function New-NetIPAddress { [CmdletBinding()]param($InterfaceIndex,$IPAddress,$PrefixLength,$SkipAsSource,$PolicyStore) $script:classicWrites++; }
function Get-NetIPAddress { [CmdletBinding()]param($InterfaceIndex,$IPAddress,$AddressFamily) [pscustomobject]@{IPAddress='192.168.99.253';AddressState='Preferred';SkipAsSource=$true} }
$script:temps=New-Object 'System.Collections.Generic.List[object]'
$script:pcChanges=[ordered]@{ifIndex=$null;alias=$null;guid=$null;dhcp=$null;ip=$null;gw=$null;coexistence_before=$null}
$Mock=$null;$cfg=[pscustomobject]@{temp_ip_hosts=@(253)};$script:classicWrites=0
$pc=[pscustomobject]@{ifIndex=5;alias='Ethernet';guid='guid-a';dhcp=$false;ip='10.0.0.10';gw='10.0.0.1'}
$a=Add-TempIp '192.168.99' $pc @()
"REPRO classic-add-replacement returned=$a writes=$script:classicWrites"
function Remove-NetIPAddress { [CmdletBinding()]param($IPAddress,$InterfaceIndex,$PolicyStore,[switch]$Confirm) $script:classicRemoves++ }
function Test-TempGone { $true }
$script:classicRemoves=0
$r=Remove-OneTemp '192.168.99.253' 5
"REPRO classic-remove-replacement returned=$r removes=$script:classicRemoves"

# Real NVR fix orchestration; stand in only for the HTTP answers.
$m=Import-Module "$Repo/Toolkit/modules/NvrHealth/NvrHealth.psm1" -Force -PassThru
& $m {
 param($out)
 Set-NvrHealthOption LogDir "$out/nvr-logs"
 $c=New-Object PSCredential('admin',(ConvertTo-SecureString 'Review123' -AsPlainText -Force))
 $new=New-Object PSCredential('admin',(ConvertTo-SecureString 'NewReview456' -AsPlainText -Force))
 $script:phase='before';$script:mode='password';$script:writes=0
 function script:Http {
  param($Ip,$Method='GET',$Path,$Body,$ContentType,$Credential,$Headers,$Port,$Scheme,[switch]$NoLogBody,$Timeout,$BodyBytes,$OutFile,[switch]$SecretTransport)
  if($OutFile){[IO.File]::WriteAllBytes($OutFile,[byte[]](@(1..255)*4));return @{code=200;body=''}}
  if($Method -eq 'PUT'){$script:writes++;$script:sentBytes=$BodyBytes;$script:phase='after';return @{code=200;body='<ResponseStatus><statusCode>1</statusCode></ResponseStatus>'}}
  if($Path -eq '/ISAPI/System/deviceInfo'){
   if($script:phase -eq 'after' -and $script:mode -eq 'password'){return @{code=200;body='<html>Login page</html>'}}
   $mac=if($script:phase -eq 'after' -and $script:mode -ne 'file-changed'){'AA:BB:CC:00:00:99'}else{'AA:BB:CC:00:00:01'}
   $ver=if($script:phase -eq 'after'){'V5.0'}else{'V4.0'}
   return @{code=200;body="<DeviceInfo><model>DS-7608</model><macAddress>$mac</macAddress><firmwareVersion>$ver</firmwareVersion></DeviceInfo>"}
  }
  return @{code=404;body=''}
 }
 $r=Invoke-NvrFix -Fix password -Ip '10.0.0.20' -Vendor Hikvision -Credential $c -NewCredential $new -Confirm {'YES'}
 "REPRO password-html ok=$($r.ok) msg=$($r.msg)"
 $script:phase='before';$script:mode='firmware'
 $fw="$out/fw.bin";[IO.File]::WriteAllBytes($fw,[byte[]](1..20));$hash=(Get-FileHash $fw).Hash
 $r=Invoke-NvrFix -Fix firmware -Ip '10.0.0.20' -Vendor Hikvision -Credential $c -File $fw -Sha256 $hash -BackupDir "$out/fw-backup" -Confirm {'YES'}
 "REPRO firmware-other-mac ok=$($r.ok) msg=$($r.msg)"
 $script:phase='before';$script:mode='file-changed';$script:writes=0
 [IO.File]::WriteAllBytes($fw,[byte[]](1..20));$hash=(Get-FileHash $fw).Hash
 $r=Invoke-NvrFix -Fix firmware -Ip '10.0.0.20' -Vendor Hikvision -Credential $c -File $fw -Sha256 $hash -BackupDir "$out/fw-backup" -Confirm { [IO.File]::WriteAllBytes($fw,[byte[]](100..140));'YES' }
 "REPRO firmware-file-changed writes=$script:writes sentLength=$($script:sentBytes.Length) approvedLength=20 ok=$($r.ok)"
} $out
