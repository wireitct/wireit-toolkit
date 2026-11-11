# Codex 2.2.19 review reproduction reproduce-diagnostics.ps1 (copied verbatim from the review evidence, Nov 11 2026). Only adaptation: the
# reviewer's output folder '/workspace/review-2219' is $env:REPRO2219_OUT (a fresh temp folder per run). Run by Test-Repro2219.ps1.
param([string]$Repo='/workspace/wireit-toolkit')
$ErrorActionPreference='Continue'
$ast=[Management.Automation.Language.Parser]::ParseFile("$Repo/NetCheck/NetCheck.ps1",[ref]$null,[ref]$null)
foreach($name in 'Get-NcStreamsText','Format-NcStreamsTo'){
 $f=$ast.Find({param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $name},$true)
 . ([scriptblock]::Create($f.Extent.Text))
}
$s=Get-NcStreamsText @{code=200;body='<ResponseStatus><statusCode>4</statusCode><statusString>Invalid Operation</statusString></ResponseStatus>'}
"REPRO stream-error-document result=$(Format-NcStreamsTo $s)"
function New-ScheduledTaskAction { @{test='action'} }
function New-ScheduledTaskTrigger { @{test='trigger'} }
function New-ScheduledTaskSettingsSet { @{test='settings'} }
function Register-ScheduledTask {
 [CmdletBinding()]param($TaskName,$Description,$Action,$Trigger,$Settings,$User,$RunLevel,[switch]$Force)
 Write-Error 'registration access denied'
}
. "$Repo/wifiwatch/install-task.ps1"
"REPRO task-registration-error script-continued-to-installed-message=True"
