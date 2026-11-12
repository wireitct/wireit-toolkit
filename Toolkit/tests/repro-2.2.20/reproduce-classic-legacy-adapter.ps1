# Codex 2.2.20 review reproduction reproduce-classic-legacy-adapter.ps1 (copied verbatim from the review evidence bundle, Nov 12 2026). Only adaptation: the
# reviewer's output folder '/workspace/review-2220' is $env:REPRO2220_OUT (a fresh temp folder per run). Run by Test-Repro2220.ps1.
# Second adaptation: $ErrorActionPreference 'Continue' instead of 'Stop' (as in repro-2.2.19), so one refusing call does not hide the later REPRO lines.
param([string]$Repo='/workspace/wireit-toolkit')
$ErrorActionPreference='Continue'
$ast=[Management.Automation.Language.Parser]::ParseFile("$Repo/FixNVR/FixNVR.ps1",[ref]$null,[ref]$null)
foreach($f in $ast.FindAll({param($a)$a -is [Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($f.Extent.Text))}
function Log {param($s)}
function Say {param($s,$color)}
function Start-Sleep {param($Seconds)}
function Get-NetAdapter {[CmdletBinding()]param($InterfaceIndex)[pscustomobject]@{Name='Ethernet';InterfaceGuid=''}}
function Get-NetIPInterface {[CmdletBinding()]param($InterfaceIndex,$AddressFamily)[pscustomobject]@{Dhcp='Disabled'}}
function Get-NetIPAddress {[CmdletBinding()]param($InterfaceIndex,$AddressFamily)[pscustomobject]@{IPAddress='10.0.0.10';SkipAsSource=$false;AddressState='Preferred'}}
function Get-NetRoute {[CmdletBinding()]param($InterfaceIndex,$DestinationPrefix,$AddressFamily)[pscustomobject]@{NextHop='10.0.0.1';ifIndex=5}}
function Test-TempGone {param($ip,$ifIndex)$script:gone}
function Remove-NetIPAddress {[CmdletBinding()]param($IPAddress,$InterfaceIndex,$PolicyStore,[switch]$Confirm)$script:removes++;$script:gone=$true}
function Unregister-ScheduledTask {[CmdletBinding()]param($TaskName,[switch]$Confirm)}
function Remove-NetFirewallRule {[CmdletBinding()]param($DisplayName)}
$tempFile=($env:REPRO2220_OUT + '/legacy-adapter.json');$taskName='test';$Mock=$null;$script:gone=$false;$script:removes=0
$cfg=[pscustomobject]@{temp_ip_hosts=@(253);verify_wait_seconds=0};$script:FnRecoverTries=1;$script:FnRecoverWaitSec=0
$o=[pscustomobject]@{version=2;temps=@([pscustomobject]@{ip='10.99.0.253';ifIndex=5});pc=[pscustomobject]@{coexistence_before=$null;firewall_rule=$false;cleanup_task=$false;ifIndex=5;alias='Ethernet';dhcp=$false;ip='10.0.0.10';gw='10.0.0.1'}}
Save-Json $o $tempFile
$w=Get-FnRecordAdapterWhy $o.pc 5
$ok=Invoke-LeftoverCleanup
"REPRO classic-legacy-journal-unread-guid gateWhy='$w' removes=$script:removes ok=$ok journalExists=$(Test-Path $tempFile)"
