# Codex 2.2.19 review reproduction reproduce-restore.ps1 (copied verbatim from the review evidence, Nov 11 2026). Only adaptation: the
# reviewer's output folder '/workspace/review-2219' is $env:REPRO2219_OUT (a fresh temp folder per run). Run by Test-Repro2219.ps1.
param([string]$Repo='/workspace/wireit-toolkit')
$out=($env:REPRO2219_OUT + '')
$journal="$out/classic-rn.json"
[IO.File]::WriteAllText($journal,'{"version":2,"temps":[{"ip":"192.168.99.253","ifIndex":5}],"pc":{"ifIndex":5,"alias":"OLD-Ethernet","guid":"guid-a","dhcp":true,"coexistence_before":"disabled"}}')
. "$Repo/Toolkit/RestoreNetwork.ps1" -ToolkitDir $out -FixNvrState $journal
$js=@(Get-RnJournals)
$ad=[pscustomobject]@{name='NEW-Ethernet';guid='guid-b';ifIndex=5;disabled=$false}
$st=[pscustomobject]@{dhcp=$false;coexist='disabled';active=@([pscustomobject]@{ip='10.0.0.10';prefix=24;origin='Manual'});persistent=@();routes=@();dnsStatic=$false;unread=@()}
$own=Get-RnOwnStatic $ad $st $js
$plan=@(Get-RnPlan $ad $st $js ([bool]$own))
"REPRO RN-classic-journal savedName='$($js[0].name)' savedGuid='$($js[0].guid)' matchesReplacement=$(Test-RnJournalFor $js[0] $ad) ownStaticRecognized=$([bool]$own) planned=$($plan.op -join ',')"
$script:RnOps={param($op,$a) if($op -eq 'list'){[pscustomobject]@{name='Ethernet';guid='';ifIndex=5}}}
$again=Get-RnAdapterAgain ([pscustomobject]@{name='Ethernet';guid='guid-a';ifIndex=5})
"REPRO RN-known-guid-now-missing accepted=$([bool]$again)"

# Read only GUI helper definitions, without loading WinForms.
$ast=[Management.Automation.Language.Parser]::ParseFile("$Repo/Toolkit/WireItToolkit.ps1",[ref]$null,[ref]$null)
$f=$ast.Find({param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Read-TkRunResult'},$true)
. ([scriptblock]::Create($f.Extent.Text))
. "$Repo/Toolkit/ToolkitCore.ps1"
$result="$out/old-result.json";[IO.File]::WriteAllText($result,'{"ok":true,"msg":"OLD run successful"}')
$since=Get-Date;[IO.File]::SetLastWriteTime($result,$since.AddSeconds(-1))
$r=Read-TkRunResult $result $since
"REPRO GUI-previous-run-within-two-seconds accepted=$([bool]$r) message=$($r.msg)"
