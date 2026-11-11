# Codex 2.2.19 review reproduction reproduce-update-journal.ps1 (copied verbatim from the review evidence, Nov 11 2026). Only adaptation: the
# reviewer's output folder '/workspace/review-2219' is $env:REPRO2219_OUT (a fresh temp folder per run). Run by Test-Repro2219.ps1.
param([string]$Repo='/workspace/wireit-toolkit')
. "$Repo/Toolkit/ToolkitCore.ps1"
$root=($env:REPRO2219_OUT + '/update-left-journal');$tk="$root/Toolkit"
New-Item -ItemType Directory -Force $tk|Out-Null
[IO.File]::WriteAllText("$tk/version.json",'{"version":"9.9.8"}')
[IO.File]::WriteAllText("$tk/example.ps1",'OLD')
$bytes=[Text.Encoding]::UTF8.GetBytes('NEW')
$h=[Security.Cryptography.SHA256]::Create();$hash=([BitConverter]::ToString($h.ComputeHash($bytes))).Replace('-','').ToLower();$h.Dispose()
$m=[pscustomobject]@{version='9.9.9';released='2026-11-11';commit='x';base='https://raw.githubusercontent.com/wireitct/wireit-toolkit/x';files=@([pscustomobject]@{path='Toolkit/example.ps1';sha256=$hash})}
function Remove-Item {
 [CmdletBinding()]param([Parameter(Position=0)]$Path,$LiteralPath,[switch]$Force,[switch]$Recurse)
 $p=if($LiteralPath){$LiteralPath}else{$Path}
 if($p -like '*update-pending.json'){Write-Error 'journal deletion denied';return}
 Microsoft.PowerShell.Management\Remove-Item @PSBoundParameters
}
$result=Install-TkUpdate $m $tk {param($url) ,$bytes}
"REPRO update-returns-success journalExists=$(Test-Path "$tk/previous/update-pending.json") installed=$((Read-TkJson "$tk/version.json").version) content=$([IO.File]::ReadAllText("$tk/example.ps1")) returned=$result"
Remove-Item function:Remove-Item
$recovery=Invoke-TkStartupRecovery $tk
"REPRO next-start content=$([IO.File]::ReadAllText("$tk/example.ps1")) installed=$((Read-TkJson "$tk/version.json").version) message=$recovery"
