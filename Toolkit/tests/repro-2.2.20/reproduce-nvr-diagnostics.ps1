# Codex 2.2.20 review reproduction reproduce-nvr-diagnostics.ps1 (copied verbatim from the review evidence bundle, Nov 12 2026). Only adaptation: the
# reviewer's output folder '/workspace/review-2220' is $env:REPRO2220_OUT (a fresh temp folder per run). Run by Test-Repro2220.ps1.
# Second adaptation: $ErrorActionPreference 'Continue' instead of 'Stop' (as in repro-2.2.19), so one refusing call does not hide the later REPRO lines.
param([string]$Repo='/workspace/wireit-toolkit')
$ErrorActionPreference='Continue'
$out=($env:REPRO2220_OUT + '/extra-nvr')
New-Item -ItemType Directory -Force $out | Out-Null
$m=Import-Module "$Repo/Toolkit/modules/NvrHealth/NvrHealth.psm1" -Force -PassThru
& $m {
 param($out)
 Set-NvrHealthOption LogDir "$out/logs"
 $c=New-Object PSCredential('admin',(ConvertTo-SecureString 'Review123' -AsPlainText -Force))
 $script:writes=@();$script:swapped=$false
 function script:Http {
  param($Ip,$Method='GET',$Path,$Body,$ContentType,$Credential,$Headers,$Port,$Scheme,[switch]$NoLogBody,$Timeout,$BodyBytes,$OutFile,[switch]$SecretTransport)
  if($Path -eq '/rest/v3/login/sessions'){return @{code=200;body='{"token":"tok"}'}}
  if($Method -eq 'PATCH'){$script:writes+=$Path;$script:swapped=$true;return @{code=200;body='{}'}}
  if($Path -like '/rest/v3/devices*'){
   $mac=if($script:swapped){'AA:BB:CC:00:00:99'}else{'AA:BB:CC:00:00:21'}
   $on=if($script:swapped){'true'}else{'false'}
   return @{code=200;body=('[{"id":"{c1}","name":"Cam1","status":"Online","url":"http://10.0.0.21","mac":"'+$mac+'","schedule":{"isEnabled":'+$on+'}}]')}
  };return @{code=404;body=''}
 }
 $r=Invoke-NvrFix -Fix recording -Ip 10.0.0.5 -Vendor DW -Credential $c -BackupDir "$out/dw" -Confirm {'YES'}
 "REPRO dw-recording-replaced-on-readback ok=$($r.ok) writes=$($script:writes.Count) finalMAC=AA:BB:CC:00:00:99 msg=$($r.msg)"

 $script:writes=@()
 function script:Http {
  param($Ip,$Method='GET',$Path,$Body,$ContentType,$Credential,$Headers,$Port,$Scheme,[switch]$NoLogBody,$Timeout,$BodyBytes,$OutFile,[switch]$SecretTransport)
  if($Path -eq '/ISAPI/System/deviceInfo'){return @{code=200;body='<DeviceInfo><serialNumber>NVR1</serialNumber><macAddress>AA:BB:CC:00:00:01</macAddress></DeviceInfo>'}}
  if($Method -eq 'PUT'){$script:writes+=$Path;return @{code=200;body='<html>Login</html>'}}
  if($Path -eq '/ISAPI/System/time'){return @{code=200;body='<Time><timeMode>manual</timeMode><localTime>2026-11-11T07:00:00</localTime><timeZone>CST+8:00:00</timeZone></Time>'}}
  if($Path -like '/ISAPI/System/time/ntpServers*'){return @{code=200;body='<NTPServerList><NTPServer><id>1</id><addressingFormatType>hostname</addressingFormatType><hostName>old.pool</hostName><portNo>123</portNo><synchronizeInterval>1440</synchronizeInterval></NTPServer></NTPServerList>'}}
  return @{code=404;body=''}
 }
 $t=@{ip='10.0.0.20';vendor='Hikvision';cred=$c;port=0;token=$null}
 $p=Hik-NtpPlan $t 'time.nist.gov';$id=Get-NhDeviceId $t
 $r=Hik-NtpApply $t 'time.nist.gov' $p $id
 "REPRO hik-time-html-first-answer writes=$($script:writes -join ',') ok=$($r.ok) why=$($r.why)"
} $out

# Run the standalone reset's actual verification callback with the saved row.
. "$Repo/Toolkit/FixSiteCore.ps1"
. "$Repo/Toolkit/FixSiteDevices.ps1"
. "$Repo/Toolkit/HikResetFlow.ps1"
$script:FsLoginLedger="$out/login.json"
function Fs-Http {param($Ip,$Path,$Method,$Cred,$Timeout) [pscustomobject]@{code=200;body='<DeviceInfo><serialNumber>OTHER</serialNumber><macAddress>AA:BB:CC:00:00:99</macAddress></DeviceInfo>'}}
$ast=[Management.Automation.Language.Parser]::ParseFile("$Repo/Toolkit/HikReset.ps1",[ref]$null,[ref]$null)
$va=$ast.Find({param($a) $a -is [Management.Automation.Language.AssignmentStatementAst] -and $a.Left.Extent.Text -eq '$verify'},$true)
. ([scriptblock]::Create($va.Extent.Text))
$d=[pscustomobject]@{mac='AA:BB:CC:00:00:21';serial='CAM1'}
$ok=Test-HikLoginOk $verify '10.0.0.21' 'Review123' $d
"REPRO standalone-reset-other-device-verified ok=$ok actualSerial=OTHER savedSerial=CAM1"

# A legacy reset with a lost answer must stop before another form consumes its key.
$script:SadpOldForms=$true;$script:SadpAllowPlainPassword=$true;$script:resetSends=0
function Invoke-SadpExchange {
 param($packets,$seconds,$times,$local,$stop)
 $script:resetSends++
 if($script:resetSends -eq 1){return @()}
 return @([pscustomobject]@{text='<ProbeMatch><MAC>aa-bb-cc-00-00-21</MAC><Result>failed</Result></ProbeMatch>'})
}
$r=Import-HikUnlock ([pscustomobject]@{serial='CAM1';mac='aa-bb-cc-00-00-21'}) ([pscustomobject]@{code='12345678'}) 'Review123' 0
"REPRO legacy-reset-lost-then-refused sends=$script:resetSends result='$($r.result)' sent=$($r.sent) error=$($r.error)"

# Keep the real scan orchestration; stand in only for networking / discovery.
$ast=[Management.Automation.Language.Parser]::ParseFile("$Repo/sitecheck/SiteCheck.ps1",[ref]$null,[ref]$null)
$hs=$ast.Find({param($a) $a -is [Management.Automation.Language.AssignmentStatementAst] -and $a.Left.Extent.Text -eq '$SC_CODE'},$true)
$ast=[Management.Automation.Language.Parser]::ParseInput([string]$hs.Right.Expression.Value,[ref]$null,[ref]$null)
foreach($f in $ast.FindAll({param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($f.Extent.Text))}
function Get-ScLocalNets { [pscustomobject]@{Ip='10.0.0.10';Prefix=24;Alias='Ethernet';Speed=1000} }
function Invoke-ScDiscovery {param($locals,$seconds) @()}
function Get-ScArp {param($prefixes) $script:ScArpWhy=''; @{} }
function Invoke-ScPingRounds {param($ips,$rounds,$ms,$delay,$after) $h=@{};foreach($ip in $ips){$h[$ip]=[pscustomobject]@{Sent=0;Ok=0;Rtt=@()}};$h}
function Invoke-ScPorts {param($ips,$ports) $h=@{};foreach($ip in $ips){$h[$ip]=@()};$h}
$R=Invoke-SiteCheck -Say {param($s)}
$D0=Get-ScDiagnosis $R
"REPRO sitecheck-unsent-sweep-no-history devices=$(@($R.devices).Count) findings=$(@($D0.Findings|ForEach-Object{$_.Text}) -join ';')"
$R.previous=@([pscustomobject]@{ip='10.0.0.21';mac='AA:BB:CC:00:00:21';vendor='Hikvision'});$R.previousWhen='yesterday'
$D=Get-ScDiagnosis $R
"REPRO sitecheck-unsent-sweep devices=$(@($R.devices).Count) findings=$(@($D.Findings|ForEach-Object{$_.Text}) -join ';')"
