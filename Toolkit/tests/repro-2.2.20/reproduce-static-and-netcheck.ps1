# Codex 2.2.20 review reproduction reproduce-static-and-netcheck.ps1 (copied verbatim from the review evidence bundle, Nov 12 2026). Only adaptation: the
# reviewer's output folder '/workspace/review-2220' is $env:REPRO2220_OUT (a fresh temp folder per run). Run by Test-Repro2220.ps1.
# Second adaptation: $ErrorActionPreference 'Continue' instead of 'Stop' (as in repro-2.2.19), so one refusing call does not hide the later REPRO lines.
param([string]$Repo='/workspace/wireit-toolkit')
$ErrorActionPreference='Continue'
$out=($env:REPRO2220_OUT + '/extra-static');New-Item -ItemType Directory -Force $out|Out-Null
$ast=[Management.Automation.Language.Parser]::ParseFile("$Repo/NetCheck/NetCheck.ps1",[ref]$null,[ref]$null)
foreach($name in @('Get-NcStreamsText','Format-NcStreamsTo')){
 $f=$ast.Find({param($a)$a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $name},$true)
 . ([scriptblock]::Create($f.Extent.Text))
}
$r=@{code=200;body='<StreamingStatus><totalStreamingSessions>'}
$text=Format-NcStreamsTo (Get-NcStreamsText $r)
$badXml=$false;try{[void][xml]$r.body}catch{$badXml=$true}
"REPRO netcheck-truncated-stream-document invalidXml=$badXml result=$text"

# Prove the source scanner does not parse code held in production here-strings.
$ast=[Management.Automation.Language.Parser]::ParseFile("$Repo/Toolkit/tests/Test-Ps51Static.ps1",[ref]$null,[ref]$null)
$f=$ast.Find({param($a)$a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Get-Findings'},$true)
. ([scriptblock]::Create($f.Extent.Text))
$sample=Join-Path $out 'embedded.ps1'
[IO.File]::WriteAllText($sample, ('$SC_CODE = @' + "'`n" + '$a = $b ? 1 : 2' + "`n'@`n" + '. ([scriptblock]::Create($SC_CODE))'))
$hits=@(Get-Findings $sample ternary)
"REPRO ps51-static-embedded-ternary offenders=$($hits.Count)"
