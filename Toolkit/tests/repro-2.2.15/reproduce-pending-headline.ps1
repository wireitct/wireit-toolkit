param([string]$Repo = '')
# Adapted from the Codex 2.2.15 review (evidence/review-2.2.15/reproduce-pending-headline.ps1). Runs the PRODUCTION code of -Repo with
# stand-ins for the device (nothing real is contacted) and ASSERTS the safe outcome.
# Prints PASS/FAIL per check, then "N passed, M failed"; exit 0 only when nothing failed.
if (-not $Repo) { $Repo = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path }
$script:Pass = 0; $script:Fail = 0
function Check([bool]$cond, [string]$what) { if ($cond) { $script:Pass++; Write-Output ('PASS ' + $what) } else { $script:Fail++; Write-Output ('FAIL ' + $what) } }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('wireit-repro-pendhead-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
. (Join-Path $Repo 'Toolkit/ToolkitCore.ps1')
# Execute the REAL site-check summary and the REAL headline renderer (Show-SiteCheck, taken from WireItToolkit.ps1 by its AST);
# only the UI output and the file read are replaced.
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Repo 'Toolkit/WireItToolkit.ps1'), [ref]$null, [ref]$null)
$f = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Show-SiteCheck' }, $true)
Invoke-Expression $f.Extent.Text
$TK = @{ P = @{ Toolkit = $tmp } }; $cOk = 'green'; $cWarn = 'amber'; $cRed = 'red'
$script:Top = @()
function Read-TkJson { return $script:check }
function Read-TkRunResult { return $script:check }   # 2.2.19: Show-SiteCheck reads this run's result through Read-TkRunResult (freshness is tested in Test-Fix2219Sweep2)
function Add-OutTop($lines, $colour) { $script:Top += [pscustomobject]@{ text = (@($lines) -join ' | '); colour = $colour } }
function Show-Fixes {}
$scan = [pscustomobject]@{ answer = @{ ok = $true; total = 1; missing = @(); stillMissing = @(); added = @(); changedIp = @() } }
$mk = { param($days, $pending)
  $rec = [pscustomobject]@{ ok = (-not $pending); target_pending = $pending; problems = @(); recording = 1; days_held = $days; target_days = 30; channels = @([pscustomobject]@{ ch = 1; online = $true; scheduled = $true; recording_now = $true }) }
  [pscustomobject]@{ vendor = 'Hikvision'; recording = $rec; clock = @{ ok = $true; problems = @() }; firmware = @{ ok = $true; problems = @(); devices = @() } } }
# the trigger (as the reviewer ran it): 5 days kept of a 30-day target, healthy cameras / clocks / firmware
$script:check = New-TkSiteCheck (& $mk 5 $true) $scan $null
$script:Top = @(); Show-SiteCheck; $top = $script:Top
Write-Output ('REPRO=' + (@{ headline = @($top | ForEach-Object { $_.text + ' COLOUR=' + $_.colour }); ok = $script:check.ok; page = $script:check.page } | ConvertTo-Json -Depth 6 -Compress))
$c = $script:check
Check (-not $c.ok) ('F6 still filling: the overall check is NOT ok (ok=' + $c.ok + ')')
Check (-not $c.page.ok) ('F6 still filling: the site-page card is NOT ok (page.ok=' + $c.page.ok + ')')
Check ($c.PSObject.Properties['pending'] -and $c.pending -eq $true) ('F6 still filling: the check says it is PENDING (pending=' + $(if ($c.PSObject.Properties['pending']) { $c.pending } else { 'missing' }) + ')')
Check (-not @($c.lines | Where-Object { $_.k -eq 'red' }).Count -and -not @($c.page.rec.problems).Count -and -not @($c.fixes).Count) 'F6 still filling is not a fault: no red line, no problem, no fix offered'
Check ($top.Count -eq 1 -and $top[0].text -notmatch '(?i)all OK') ('F6 the headline is NOT "all OK" (' + (@($top | ForEach-Object { $_.text }) -join ' / ') + ')')
Check ($top.Count -eq 1 -and $top[0].colour -eq 'amber') ('F6 the headline is amber, not green and not red (' + (@($top | ForEach-Object { $_.colour }) -join ',') + ')')
Check ($top.Count -eq 1 -and $top[0].text -match '(?i)still filling' -and $top[0].text -match '5 of 30' -and $top[0].text -match '(?i)nothing broken') ('F6 the headline says still filling, 5 of 30 days, nothing broken found (' + (@($top | ForEach-Object { $_.text }) -join ' / ') + ')')
# a check saved by the previous version (ok=true, no pending field, page.rec.stillFilling) must not render green either
$old = $script:check | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$old.ok = $true; $old.PSObject.Properties.Remove('pending'); $old.PSObject.Properties.Remove('pendingWhy')
$script:check = $old; $script:Top = @(); Show-SiteCheck; $top = $script:Top
Check ($top.Count -eq 1 -and $top[0].colour -eq 'amber' -and $top[0].text -notmatch '(?i)all OK') ('F6 an older saved check (ok=true + stillFilling) is not shown as green "all OK" (' + (@($top | ForEach-Object { $_.text + ' ' + $_.colour }) -join ' / ') + ')')
# the tool-window ending: the "still filling" exit code is not read as "All good"
$pe = Get-TkNvrPlainEnd 'Check this site' 3
Check ($pe -notmatch '(?i)all good' -and $pe -match '(?i)still filling') ('F6 the ending for exit code 3 says still filling, not "All good" (' + $pe + ')')
# control: target met (30 of 30) stays green "all OK"
$script:check = New-TkSiteCheck (& $mk 30 $false) $scan $null
$script:Top = @(); Show-SiteCheck; $top = $script:Top
Check ($script:check.ok -and $top.Count -eq 1 -and $top[0].colour -eq 'green' -and $top[0].text -match 'all OK') ('control: 30 of 30 days, everything healthy -> green "all OK" (' + (@($top | ForEach-Object { $_.text + ' ' + $_.colour }) -join ' / ') + ')')
Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Output ('' + $script:Pass + ' passed, ' + $script:Fail + ' failed')
if ($script:Fail) { exit 1 } else { exit 0 }
