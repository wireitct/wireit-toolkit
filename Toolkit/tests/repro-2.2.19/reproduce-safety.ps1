# Codex 2.2.19 review reproduction reproduce-safety.ps1 (copied verbatim from the review evidence, Nov 11 2026). Only adaptation: the
# reviewer's output folder '/workspace/review-2219' is $env:REPRO2219_OUT (a fresh temp folder per run). Run by Test-Repro2219.ps1.
param([string]$Repo='/workspace/wireit-toolkit')
$out=($env:REPRO2219_OUT + '')
. "$Repo/Toolkit/FixSiteCore.ps1"
. "$Repo/Toolkit/FixSiteDevices.ps1"
$script:FsLoginLedger="$out/ambiguous-login.json"
Remove-Item $script:FsLoginLedger -ErrorAction SilentlyContinue
$script:attempts=0
function Test-FsLoginOnce {param($ip,$brand,$pw) $script:attempts++; 'noanswer'}
1..6|ForEach-Object{[void](Test-FsLogin '10.0.0.21' Hikvision 'Wrong123')}
$b=Get-FsLoginBudget '10.0.0.21'
"REPRO lost-login-answer attempts=$script:attempts remainingCount=$($b.fails) max=$script:FsMaxLoginFails"

. "$Repo/Toolkit/HikResetFlow.ps1"
$script:HkSubnetCheckOff=$true
$script:exportWrites=0;$script:saveCalls=0
$sp="$out/retry-state.json"
$dev=[pscustomobject]@{serial='CAM123456789';mac='AA:BB:CC:00:00:01';model='IPC';ip='10.0.0.21';shortSerial='123456789';kind='camera';activated=$true;salt='';encrypt=$false;bootTime='NEW-BOOT'}
$d=[pscustomobject]@{serial=$dev.serial;mac=$dev.mac;model=$dev.model;ip=$dev.ip;status='refused';bootTime='OLD-BOOT';rebootRetries=0;refusedChecksOk=$true}
$s=[pscustomobject]@{version=1;devices=@($d);exports=@()}
Save-HikState $sp $s
function Request-HikResetExport {param($dev) $script:exportWrites++;[pscustomobject]@{ok=$true;request=[pscustomobject]@{value='CODE'}}}
function Save-HikResetFile {param($dev,$e,$dir) $p="$out/request.xml";[IO.File]::WriteAllText($p,'CODE');$p}
function Save-HikStateOk {param($Path,$State) $script:saveCalls++;if($script:saveCalls%2 -eq 0){$script:HkStateSaveWhy='simulated disk failure after export';return $false};Save-HikState $Path $State;return $script:HkStateSaved}
1..2|ForEach-Object{$s=Read-HikState $sp;[void](Export-HikRequests @($dev) "$out/requests" $s $sp)}
$back=Read-HikState $sp
"REPRO reset-retry-reservation exports=$script:exportWrites savedRetries=$($back.devices[0].rebootRetries) savedStatus=$($back.devices[0].status)"

$m=Import-Module "$Repo/Toolkit/modules/NvrHealth/NvrHealth.psm1" -Force -PassThru
& $m {
 Set-NvrHealthOption LogDir ($env:REPRO2219_OUT + '/storage-logs')
 function script:Http {param($Ip,$Path,$Headers,$Port,$Scheme,$ContentType) @{code=200;body='[{"totalSpace":"unreadable","isOnline":true}]'}}
 $r=Dw-Storage @{ip='10.0.0.20';token='x'}
 "REPRO DW-modern-storage-invalid-number read=$($r.ok) status=$($r.disks[0].status) capacity=$($r.disks[0].capMB)"
}
