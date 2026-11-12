# Codex 2.2.20 review reproduction reproduce-persistence.ps1 (copied verbatim from the review evidence bundle, Nov 12 2026). Only adaptation: the
# reviewer's output folder '/workspace/review-2220' is $env:REPRO2220_OUT (a fresh temp folder per run). Run by Test-Repro2220.ps1.
# Second adaptation: $ErrorActionPreference 'Continue' instead of 'Stop' (as in repro-2.2.19), so one refusing call does not hide the later REPRO lines.
param([string]$Repo='/workspace/wireit-toolkit')
$ErrorActionPreference='Continue'
$out=($env:REPRO2220_OUT + '/extra-persistence');New-Item -ItemType Directory -Force $out|Out-Null
. "$Repo/Toolkit/FixSiteCore.ps1"
. "$Repo/Toolkit/FixSiteDevices.ps1"
$script:FsPcBefore=[pscustomobject]@{ifIndex=5;name='Ethernet';guid='guid-a';dhcp=$false;coexist='disabled';addrs=@([pscustomobject]@{ip='10.0.0.10';prefix=24;skip=$false});gw=@()}
$script:FsTemps.Clear();$script:FsRestoreChecks=1
$script:FsNetOps=@{
 ident={param($a)[pscustomobject]@{name='Ethernet';guid='guid-a'}}
 state={param($a)[pscustomobject]@{dhcp=$false;coexist='disabled';addrs=@([pscustomobject]@{ip='10.0.0.10';prefix=24;skip=$false});gw=@();unread=@()}}
}
$jf="$out/native-remove-denied.json";Save-FsNetState $jf
function Remove-Item { [CmdletBinding()]param($LiteralPath,[switch]$Force) Write-Error 'delete denied' }
$r=Restore-FsPcNet $jf
"REPRO native-site-record-remove-denied ok=$($r.ok) journalExists=$(Test-Path $jf) problems=$($r.problems.Count)"
Microsoft.PowerShell.Management\Remove-Item function:Remove-Item

$script:netRead=[pscustomobject]@{ip='10.0.0.21';mask='255.255.255.0';dhcp=$false;gw='';dns1='';dns2='';has=[pscustomobject]@{gw=$false;dns1=$false;dns2=$false}}
function Get-FsNet {param($ip,$brand,$cred)$script:netRead}
$before=[pscustomobject]@{dns1='';dns2='';has=[pscustomobject]@{gw=$true;dns1=$true;dns2=$true}}
$w=Get-FsNetMismatch '10.0.0.21' Hikvision $null $before '10.0.0.21' '255.255.255.0' '' '' ''
"REPRO site-empty-net-unread mismatch='$w' fieldsPresent=$($script:netRead.has|ConvertTo-Json -Compress)"

. "$Repo/Toolkit/HikResetFlow.ps1"
$script:HkSubnetCheckOff=$true;$script:HkSay={param($t,$c)};$script:exports=0
function Request-HikResetExport {param($dev)$script:exports++;[pscustomobject]@{ok=$false;error='lost'}}
$dev=[pscustomobject]@{serial='CAM123456789';mac='aa-bb-cc-00-00-21';model='IPC';ip='10.0.0.21';shortSerial='123456789';kind='camera';activated=$true;bootTime='BOOT'}
foreach($shape in @('null','[null]')){
 $sp="$out/damaged-$($script:exports).json";[IO.File]::WriteAllText($sp,('{"version":1,"devices":'+$shape+',"exports":[]}'))
 $st=Read-HikState $sp;$beforeCount=$script:exports
 [void](Export-HikRequests @($dev) "$out/requests" $st $sp)
 "REPRO reset-null-device-list shape=$shape exports=$($script:exports-$beforeCount) quarantined=$(@($st.quarantined|Where-Object{$_}).Count)"
}

$m=Import-Module "$Repo/Toolkit/modules/NvrHealth/NvrHealth.psm1" -Force -PassThru
& $m {
 param($out)
 $sp="$out/limit-race.json";Remove-Item $sp -ErrorAction SilentlyContinue
 $script:realWriter=${function:Write-FixLimits};$script:nested=$false;$script:second=$null
 $script:t1=Get-Date;$script:t2=$script:t1.AddSeconds(1)
 function script:Write-FixLimits {
  param($path,$map)
  if(-not $script:nested){$script:nested=$true;$script:second=Fix-LimitReserve $path '10.0.0.21' $script:t2}
  & $script:realWriter $path $map
 }
 $first=Fix-LimitReserve $sp '10.0.0.21' $script:t1
 $back=Read-FixLimits $sp
 "REPRO restart-reservation-interleave first=$($first.ok) second=$($script:second.ok) durableReservations=$(@($back.map['10.0.0.21']).Count)"
} $out
