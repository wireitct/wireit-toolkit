# Codex 2.2.20 review reproduction reproduce-reset-request-swap.ps1 (copied verbatim from the review evidence bundle, Nov 12 2026). Only adaptation: the
# reviewer's output folder '/workspace/review-2220' is $env:REPRO2220_OUT (a fresh temp folder per run). Run by Test-Repro2220.ps1.
# Second adaptation: $ErrorActionPreference 'Continue' instead of 'Stop' (as in repro-2.2.19), so one refusing call does not hide the later REPRO lines.
param([string]$Repo='/workspace/wireit-toolkit')
$ErrorActionPreference='Continue'
. "$Repo/Toolkit/HikResetFlow.ps1"
$out=($env:REPRO2220_OUT + '/request-swap');New-Item -ItemType Directory -Force $out|Out-Null
$script:HkSay={param($t,$c)}
$sn='CAM123456789';$script:request=Join-Path $out 'request.xml'
$script:original=([Convert]::ToBase64String([byte[]](@(3,0,0,0)+@(1..24))))+$sn
$script:replacement=([Convert]::ToBase64String([byte[]](@(3,0,0,0)+@(25..48))))+$sn
[IO.File]::WriteAllText($script:request,$script:original)
$dev=[pscustomobject]@{serial=$sn;shortSerial='123456789';model='IPC';mac='aa-bb-cc-00-00-21';ip='10.0.0.21';kind='camera';salt='';encrypt=$false}
$state=[pscustomobject]@{version=1;devices=@();exports=@()}
$d=Add-HikStateDevice $state $dev $script:request 'BOOT'
$sp=Join-Path $out 'state.json';Save-HikState $sp $state
$before=Test-HikRequestFileInForce $d
function Find-HikBrowser {'browser-stand-in'}
function Start-HikBrowserSession {param($url)[pscustomobject]@{test=$true}}
function Wait-PortalForm {param($s,$seconds)[IO.File]::WriteAllText($script:request,$script:replacement);$true}
function Fill-HikPortalForm {param($s,$form,$dev,$file)$script:attached=[IO.File]::ReadAllText($file);[pscustomobject]@{file=$file}}
function Test-PortalFilled {param($r,$d)@()}
function Wait-PortalSubmitted {param($s,$seconds,$a,$b)'submitted'}
function Stop-HikBrowserSession {param($s)}
$form=[pscustomobject]@{firstName='Test';lastName='Technician';company='Example';email='test@example.invalid';state='NY';zip='00000';businessType='test'}
$sent=@(Submit-HikRequests $state $sp $form 0)
$after=Test-HikRequestFileInForce $d
"REPRO reset-request-swap-during-page-load beforeWhy='$before' submitted=$($sent.Count) status=$($d.status) attachedReplacement=$($script:attached -ceq $script:replacement) nowMismatch=$([bool]$after)"
