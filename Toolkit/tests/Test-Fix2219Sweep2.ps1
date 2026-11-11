<# Test-Fix2219Sweep2.ps1 - tests for WireIt Toolkit 2.2.19 (Nov 11 2026), the follow-up "sweep2" after Codex's NO-GO review of
   2.2.18: the files the first round did not fully sweep, checked for the review's classes C (unknown is not fine), E (safety state
   persists or stops) and F (success only on verified results):
   - appsscript/HikRelay.gs: a damaged stored record / an empty stored file is not "no reply" and not marked used; one mail that
     cannot be kept no longer stops the scan or leaves a Drive copy behind; an old record stays until its Drive copy is really binned
     (node: the sweep2 checks in appsscript/tests/hikrelay.test.js, run here against this checkout's HikRelay.gs)
   - Toolkit/WireItToolkit.ps1: an unreadable tool exit code is NOT CHECKED (never green "done"); only the result file THIS run wrote is
     shown (never the previous run's "all OK" / "FIX: ok"); green needs ok AND code 0; Restore Network refuses when the adapter list
     could not be read (it ran "-Auto" on the tool's own pick before)
   - the .cmd launchers: the tool's exit code is passed on (they all ended 0 through "pause")
   - NetCheck/NetCheck.ps1: failed NVR channel / stream / log reads are NOT CHECKED, never "0 of 0 online" / "nobody" / no events
   - sitecheck/SiteCheck.ps1 (+ the .cmd that carries it): a channel with no online state is amber NOT CHECKED, never red OFFLINE
   WinForms code cannot run off Windows: the window's decisions were moved into small functions in WireItToolkit.ps1 (behaviour
   unchanged apart from the fix), which this suite extracts from the file and RUNS; the button handlers that call them get a source
   check (labelled). .cmd files cannot run here: source checks (labelled), real Windows behaviour DEFERRED (never a pass).
   PS 5.1 or pwsh 7. FIX2219SWEEP2_REPO (tests only) = run against another checkout (old-code proof: on 2.2.18 the finding checks FAIL,
   the controls pass). #>
$ErrorActionPreference = 'Stop'
$exe = $(if ($PSVersionTable.PSEdition -eq 'Core') { (Get-Process -Id $PID).Path } else { Join-Path $PSHOME 'powershell.exe' })
$repo = $(if ($env:FIX2219SWEEP2_REPO) { $env:FIX2219SWEEP2_REPO } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) })
$tk = Join-Path $repo 'Toolkit'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fix2219sweep2-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$script:pass = 0; $script:fail = 0; $script:deferred = 0
function Check([bool]$ok, [string]$name, [string]$more = '') {
  if ($ok) { $script:pass++; Write-Host ('PASS ' + $name) } else { $script:fail++; Write-Host ('FAIL ' + $name); if ($more) { Write-Host ('     ' + $more) } }
}
function Deferred([string]$name) { $script:deferred++; Write-Host ('DEFERRED ' + $name) }
function Run-Safe([string]$name, [scriptblock]$sb) { try { & $sb } catch { Check $false ($name + ' (the check itself stopped)') ([string]$_.Exception.Message + ' @' + [string]$_.InvocationInfo.ScriptLineNumber) } }
function Read-Src([string]$rel) { return [IO.File]::ReadAllText((Join-Path $repo ($rel -replace '/', [string][IO.Path]::DirectorySeparatorChar))) }
# the named functions, taken from the real file and defined here (the file itself starts a window / a network scan when run)
function Import-Fn([string]$rel, [string[]]$names) {
  $e = $null; $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo ($rel -replace '/', [string][IO.Path]::DirectorySeparatorChar)), [ref]$null, [ref]$e)
  $missing = @()
  foreach ($n in $names) {
    $f = $ast.Find({ param($x) $x -is [Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $n }, $true)
    if ($f) { . ([scriptblock]::Create($f.Extent.Text.Replace('function ' + $n, 'function global:' + $n))) } else { $missing += $n }
  }
  return $missing
}
foreach ($f in @('Toolkit/WireItToolkit.ps1', 'NetCheck/NetCheck.ps1', 'sitecheck/SiteCheck.ps1')) {
  $e = $null; [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $repo $f), [ref]$null, [ref]$e); Check ($e.Count -eq 0) ('parses: ' + $f) ($e | Out-String)
}

# ==============================================================================================================================
Write-Host ''
Write-Host 'Relay (HikRelay.gs, class C/E/F): the sweep2 checks of hikrelay.test.js, run with node against this checkout''s HikRelay.gs'
Run-Safe 'relay' {
  $node = $(if ($env:WIREIT_TEST_NODE -eq 'none') { '' } elseif ($env:WIREIT_TEST_NODE) { $env:WIREIT_TEST_NODE } else { $nc = Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1; if ($nc) { $nc.Source } else { '' } })
  $js = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'appsscript/tests/hikrelay.test.js'
  if (-not $node) { Deferred 'relay checks: no node on this PC (they did NOT run)'; return }
  $env:HIKRELAY_GS = Join-Path $repo 'appsscript/HikRelay.gs'
  try { $out = @(& $node $js 2>&1 | ForEach-Object { [string]$_ }) } finally { Remove-Item Env:\HIKRELAY_GS -ErrorAction SilentlyContinue }
  $mine = @($out | Where-Object { $_ -match '^(PASS|FAIL) (sweep2 relay|\.\.\.)' })
  Check ($mine.Count -ge 13) ('relay: the 13 sweep2 relay checks ran (' + $mine.Count + ' seen)') (($out | Select-Object -Last 5) -join ' | ')
  foreach ($l in $mine) { Check ($l -like 'PASS *') ('relay (node): ' + $l.Substring(5)) }
}

# ==============================================================================================================================
Write-Host ''
Write-Host 'Toolkit window (WireItToolkit.ps1, class C/F): every done/ok it shows rests on THIS run''s real result'
. (Join-Path $tk 'ToolkitCore.ps1')
$miss = @(Import-Fn 'Toolkit/WireItToolkit.ps1' @('Get-TkConsoleEnd', 'Read-TkRunResult', 'Get-TkResultView', 'Get-TkToneColor', 'Get-TkAdapterList', 'Show-SiteCheck', 'Show-FixDone', 'Show-Doctor'))
$wt = Read-Src 'Toolkit/WireItToolkit.ps1'
Run-Safe 'console end' {
  $ok = $false; $more = 'Get-TkConsoleEnd is missing'
  if (Get-Command Get-TkConsoleEnd -ErrorAction SilentlyContinue) { $ce = Get-TkConsoleEnd (-1) 'Fix NVR' $false; $ok = ($ce.code -ne 0 -and $ce.plain -match 'NOT CHECKED'); $more = ($ce | Out-String) }
  Check $ok 'reproduction (sweep2 W1): a tool window whose exit code could not be read ends amber NOT CHECKED, never code 0 "done"' $more
  Check (-not ($wt -match "End-Run 0 \(\`$r\.Name \+ ': the tool window closed")) 'source check (not a behaviour run): Poll-Run no longer ends an unknown exit code as "End-Run 0 ... the tool window closed"'
  Check ([regex]::Matches($wt, 'Get-TkConsoleEnd \$code \$r\.Name').Count -eq 2) 'source check: both Poll-Run branches (hidden + tool window) end through Get-TkConsoleEnd'
  if (Get-Command Get-TkConsoleEnd -ErrorAction SilentlyContinue) {
    $c0 = Get-TkConsoleEnd 0 'Check NVR' $true; $c4 = Get-TkConsoleEnd 4 'Check NVR' $true
    Check ($c0.code -eq 0 -and $c0.plain -eq (Get-TkNvrPlainEnd 'Check NVR' 0) -and $c4.code -eq 4 -and $c4.plain -eq (Get-TkNvrPlainEnd 'Check NVR' 4)) 'control: a real exit code is passed through unchanged with the same plain words as before'
  } else { Check $false 'control: a real exit code is passed through unchanged (Get-TkConsoleEnd missing)' }
}
Run-Safe 'run result' {
  $d = Join-Path $tmp 'rr'; New-Item -ItemType Directory -Force -Path $d | Out-Null
  $f = Join-Path $d 'r.json'; '{"ok":true,"msg":"old"}' | Set-Content -LiteralPath $f -Encoding UTF8
  (Get-Item -LiteralPath $f).LastWriteTime = (Get-Date).AddMinutes(-30)
  $has = [bool](Get-Command Read-TkRunResult -ErrorAction SilentlyContinue)
  Check ($has -and $null -eq (Read-TkRunResult $f (Get-Date).AddMinutes(-1))) 'reproduction (sweep2 W2): a result file from BEFORE this run started is not this run''s result ($null)'
  '{"ok":true,"msg":"new"}' | Set-Content -LiteralPath $f -Encoding UTF8
  Check ($has -and [string](Read-TkRunResult $f (Get-Date).AddMinutes(-1)).msg -eq 'new') 'control: the file this run wrote is read'
  '{"ok":tr' | Set-Content -LiteralPath $f -Encoding UTF8
  Check ($has -and $null -eq (Read-TkRunResult $f (Get-Date).AddMinutes(-1))) '...a damaged result file is $null (NOT CHECKED), and a missing one too' 
}
Run-Safe 'result view' {
  $has = [bool](Get-Command Get-TkResultView -ErrorAction SilentlyContinue)
  $v = $null; if ($has) { $v = Get-TkResultView 'fix' $null 0 }
  Check ($has -and $v.tone -eq 'warn' -and $v.text -match 'NOT CHECKED') 'sweep2 W3: no fix result from this run = amber "FIX: NOT CHECKED" (before: nothing shown, the pill said done)'
  if ($has) { $v = Get-TkResultView 'fix' ([pscustomobject]@{ ok = $true; ran = $true; msg = 'Recording is on' }) 4 }
  Check ($has -and $v.tone -ne 'ok' -and $v.text -match 'NOT CHECKED') 'sweep2 W3: a fix result that says ok while the tool ended with code 4 is NOT green'
  if ($has) { $v1 = Get-TkResultView 'fix' ([pscustomobject]@{ ok = $true; ran = $true; msg = 'done' }) 0; $v2 = Get-TkResultView 'fix' ([pscustomobject]@{ ok = $false; ran = $true; msg = 'did not take' }) 4; $v3 = Get-TkResultView 'fix' ([pscustomobject]@{ ok = $false; ran = $false; msg = 'not started' }) 2 }
  Check ($has -and $v1.tone -eq 'ok' -and $v2.tone -eq 'red' -and $v3.tone -eq 'warn') 'control: ok + code 0 is green, a fix that ran and failed is red, one that never ran is amber (same colours as before)'
  if ($has) { $v = Get-TkResultView 'doctor' ([pscustomobject]@{ ip = '10.1.61.29'; fixes = @() }) 0 }
  Check ($has -and $v.tone -eq 'warn' -and $v.text -match 'NOT CHECKED') 'sweep2 W4: a camera doctor result with no verdict is amber NOT CHECKED (before: green, because it named no fixes)'
  if ($has) { $v = Get-TkResultView 'doctor' ([pscustomobject]@{ ip = '10.1.61.29'; verdict = 'Camera answers'; fixes = @() }) 2 }
  Check ($has -and $v.tone -eq 'warn') 'sweep2 W4: a camera doctor that ended with code 2 is not green'
  if ($has) { $va = Get-TkResultView 'doctor' ([pscustomobject]@{ ip = '10.1.61.29'; verdict = 'Camera is fine'; fixes = @() }) 0; $vb = Get-TkResultView 'doctor' ([pscustomobject]@{ ip = '10.1.61.29'; verdict = 'No power'; fixes = @('poe') }) 4 }
  Check ($has -and $va.tone -eq 'ok' -and $vb.tone -eq 'red') 'control: a verdict with code 0 and no fixes is green; named fixes are red'
}
Run-Safe 'show site/fix/doctor' {
  $global:sw2Top = New-Object System.Collections.Generic.List[string]
  function global:Add-OutTop($lines, $color) { foreach ($l in @($lines)) { [void]$global:sw2Top.Add([string]$color + '|' + [string]$l) } }
  function global:Show-Fixes($keys) { }
  function global:Add-Out($t, $c) { }
  $global:cOk = 'green'; $global:cWarn = 'amber'; $global:cRed = 'red'; $global:cBlue = 'blue'
  $root = Join-Path $tmp 'tkwin'; New-Item -ItemType Directory -Force -Path (Join-Path $root 'logs') | Out-Null
  $global:TK = @{ P = @{ Toolkit = $root }; lastRunStarted = (Get-Date).AddMinutes(-1) }
  $cs = Join-Path $root 'logs/check-site-last.json'; '{"ok":true,"lines":[],"fixes":[]}' | Set-Content -LiteralPath $cs -Encoding UTF8
  (Get-Item -LiteralPath $cs).LastWriteTime = (Get-Date).AddHours(-3)
  $global:sw2Top.Clear(); Show-SiteCheck 4
  Check (-not ($global:sw2Top -match 'all OK') -and ($global:sw2Top -match 'NOT CHECKED')) 'reproduction (sweep2 W5): "Check this site" that stopped (code 4, no new result) never shows the PREVIOUS check''s "all OK"' ($global:sw2Top -join ' / ')
  '{"ok":true,"lines":[],"fixes":[]}' | Set-Content -LiteralPath $cs -Encoding UTF8
  $global:sw2Top.Clear(); Show-SiteCheck 4
  Check (-not ($global:sw2Top -match 'all OK')) 'sweep2 W5: a fresh check that says ok while the tool ended with code 4 is not "all OK"' ($global:sw2Top -join ' / ')
  $global:sw2Top.Clear(); Show-SiteCheck 0
  Check (@($global:sw2Top -match '^green\|CHECK THIS SITE: all OK').Count -eq 1) 'control: a fresh ok check with code 0 is "all OK" in green' ($global:sw2Top -join ' / ')
  $fx = Join-Path $root 'logs/fix-last.json'; '{"ok":true,"ran":true,"msg":"Recording is back on"}' | Set-Content -LiteralPath $fx -Encoding UTF8
  (Get-Item -LiteralPath $fx).LastWriteTime = (Get-Date).AddHours(-3)
  $global:sw2Top.Clear(); Show-FixDone 4
  Check (-not ($global:sw2Top -match '^green\|') -and -not ($global:sw2Top -match 'back on')) 'reproduction (sweep2 W5 twin): a fix that stopped never shows the PREVIOUS fix''s green "FIX: Recording is back on"' ($global:sw2Top -join ' / ')
  $dc = Join-Path $root 'logs/doctor-last.json'; '{"ip":"10.1.61.29","verdict":"Camera is fine","fixes":[]}' | Set-Content -LiteralPath $dc -Encoding UTF8
  (Get-Item -LiteralPath $dc).LastWriteTime = (Get-Date).AddHours(-3)
  $global:sw2Top.Clear(); Show-Doctor 2
  Check (-not ($global:sw2Top -match '^green\|') -and ($global:sw2Top -match 'NOT CHECKED')) 'reproduction (sweep2 W5 twin): a camera doctor that stopped never shows the PREVIOUS camera''s green verdict' ($global:sw2Top -join ' / ')
  Check ($wt -match "Start-Nvr 'Check this site' 'Site' \`$TK\.scArgs \{ param\(\`$code\) Show-SiteCheck \`$code \}" -and $wt -match 'Show-FixDone \$code \}' -and $wt -match 'Show-Doctor \$code \}') 'source check: the three after-run steps are handed the tool''s exit code'
  Check ($wt -match "Read-TkRunResult \(Join-Path \`$TK\.P\.Toolkit 'logs\\scan-upload-last\.json'\) \`$TK\.lastRunStarted" -and $wt -match '\$TK\.lastRunStarted = \$r\.Started') 'source check: "Save to site page" also reads only this run''s result; End-Run records the run''s start'
}
Run-Safe 'restore net list' {
  $has = [bool](Get-Command Get-TkAdapterList -ErrorAction SilentlyContinue)
  $two = 'JSON=[{"name":"Ethernet","desc":"Intel","needs":true},{"name":"Wi-Fi","desc":"Realtek","needs":false}]'
  $r1 = $null; $r2 = $null; $r3 = $null; $r4 = $null; $r5 = $null
  if ($has) { $r1 = Get-TkAdapterList '' $true 0; $r2 = Get-TkAdapterList $two $false $null; $r3 = Get-TkAdapterList 'JSON=[{"name":"Eth' $true 0; $r4 = Get-TkAdapterList $two $true 1; $r5 = Get-TkAdapterList 'JSON=[{"name":"","desc":"x"}]' $true 0 }
  Check ($has -and -not $r1.ok -and $r1.msg -match 'Nothing was changed') 'reproduction (sweep2 W6, decision "adapter unreadable -> refuse"): Restore Network with no adapter list refuses (before: ran -Auto on the tool''s own pick)'
  Check ($has -and -not $r2.ok) 'sweep2 W6: the adapter list that did not come back in time is a refusal'
  Check ($has -and -not $r3.ok -and -not $r4.ok -and -not $r5.ok) 'sweep2 W6: a damaged list, a list tool that ended with an error, and an adapter with no name are refusals'
  $g = $null; $g1 = $null; if ($has) { $g = Get-TkAdapterList $two $true 0; $g1 = Get-TkAdapterList 'JSON=[{"name":"Ethernet","desc":"Intel","needs":true}]' $true 0 }
  Check ($has -and $g.ok -and @($g.ads).Count -eq 2 -and [string]@($g.ads)[1].name -eq 'Wi-Fi' -and $g1.ok -and @($g1.ads).Count -eq 1) 'control: a good list gives each adapter by name (one-item list too: the 2.2.11 PS 5.1 unroll is kept)'
  Check ($wt -match 'if \(-not \$al\.ok\) \{ \$TK\.out\.Clear\(\); Add-Out \$al\.msg' -and $wt -match "\`$a2 = '-Auto -Adapter `"'" -and -not ($wt -match "\`$a2 = '-Auto' \+ \`$\(if \(\`$pick\)")) 'source check: Do-RestoreNet stops on a refusal and always names the chosen adapter (no bare -Auto)'
}

# ==============================================================================================================================
Write-Host ''
Write-Host 'Launchers (.cmd, class F): the tool''s exit code is passed on, never turned into success by "pause"'
Run-Safe 'cmd' {
  foreach ($rel in @('CamReset/Find Cameras.cmd', 'FixNVR/Check NVR.cmd', 'FixNVR/Fix NVR.cmd', 'FixNVR/NVR Snapshot.cmd', 'NetCheck/Network Check.cmd', 'Toolkit/Restore Network.cmd', 'Toolkit/Set upload key.cmd')) {
    $lines = @((Read-Src $rel) -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $i = -1; for ($k = 0; $k -lt $lines.Count; $k++) { if ($lines[$k] -match '^powershell(\.exe)? .*-File ') { $i = $k } }
    $ok = ($i -ge 0 -and $i + 1 -lt $lines.Count -and $lines[$i + 1] -eq 'set "WIREIT_RC=%ERRORLEVEL%"' -and $lines[-1] -eq 'exit /b %WIREIT_RC%')
    Check $ok ('source check (cmd cannot run here): ' + $rel + ' keeps the tool''s exit code straight after it runs and ends with it')
    if ((Read-Src $rel) -match 'Verb RunAs') {
      $src = Read-Src $rel
      Check ($src -match '-Verb RunAs -Wait -PassThru' -and $src -match 'exit \$p\.ExitCode' -and $src -notmatch 'exit /b %ERRORLEVEL%') ('source check: ' + $rel + ' waits for the elevated window and ends with ITS code (UAC refused = 5), not the asking window''s 0')
    }
  }
  Deferred 'launchers on real Windows (cmd.exe, UAC): not run here'
}

# ==============================================================================================================================
Write-Host ''
Write-Host 'NetCheck (NetCheck.ps1, class C): a failed probe is NOT CHECKED, never "0 of 0 online", "nobody" or no events'
$nmiss = @(Import-Fn 'NetCheck/NetCheck.ps1' @('Tag', 'Get-NcChannelSummary', 'Get-NcStreamsText', 'Format-NcStreamsTo', 'Read-Logs'))
$ncs = Read-Src 'NetCheck/NetCheck.ps1'
Run-Safe 'netcheck' {
  $has = [bool](Get-Command Get-NcChannelSummary -ErrorAction SilentlyContinue)
  $s1 = $null; $s2 = $null; $s3 = $null
  if ($has) { $s1 = Get-NcChannelSummary 401 ''; $s2 = Get-NcChannelSummary 200 '<InputProxyChannelStatusList></InputProxyChannelStatusList>'; $s3 = Get-NcChannelSummary 200 '<InputProxyChannelStatus><id>1</id><ipAddress>10.0.0.11</ipAddress><online>true</online></InputProxyChannelStatus><InputProxyChannelStatus><id>2</id><ipAddress>10.0.0.12</ipAddress></InputProxyChannelStatus><InputProxyChannelStatus><id>3</id><ipAddress>10.0.0.13</ipAddress><online>false</online></InputProxyChannelStatus>' }
  Check ($has -and $s1.note -match 'NOT CHECKED' -and $s1.note -notmatch '0 of 0') 'reproduction (sweep2 N1): an NVR channel list that could not be read says NOT CHECKED (before: "NVR: 0 of 0 channels online")'
  Check ($has -and $s2.note -match 'NOT CHECKED') 'sweep2 N1: an answer with no channel in it is NOT CHECKED'
  Check ($has -and @($s3.off).Count -eq 1 -and @($s3.unknown).Count -eq 1 -and $s3.note -match '1 of 3 channels online, 1 NOT CHECKED') 'sweep2 N1: a channel with no online state is NOT CHECKED, not offline; a channel READ as false is offline' $(if ($s3) { $s3.note })
  $hs = [bool](Get-Command Get-NcStreamsText -ErrorAction SilentlyContinue)
  $t1 = ''; $t2 = ''; $t3 = ''; if ($hs) { $t1 = Get-NcStreamsText @{ code = 0; body = '' }; $t2 = Format-NcStreamsTo (Get-NcStreamsText @{ code = 200; body = '<x><ipAddress>10.0.0.20</ipAddress></x><x><ipAddress>10.0.0.20</ipAddress></x>' }); $t3 = Format-NcStreamsTo (Get-NcStreamsText @{ code = 200; body = '<StreamingSessionStatusList/>' }) }
  Check ($hs -and $t1 -match '^NOT CHECKED' -and (Format-NcStreamsTo $t1) -match '^NOT CHECKED') 'reproduction (sweep2 N2): a stream status that could not be read shows NOT CHECKED (before: "->nobody")'
  Check ($hs -and $t2 -eq '10.0.0.20' -and $t3 -eq 'nobody') 'control: a read stream list names who pulls video; a read empty list is "nobody"'
  $global:LogDays = 7; $global:OutDir = $tmp; New-Item -ItemType Directory -Force -Path (Join-Path $tmp 'raw') | Out-Null
  function global:Post-Isapi($base, $path, $xml) { return @{ code = 0; body = '' } }
  $lg = ''; if (Get-Command Read-Logs -ErrorAction SilentlyContinue) { $lg = [string](Read-Logs 'http://127.0.0.1' '127.0.0.1') }
  Check ($lg -match 'NOT CHECKED') 'reproduction (sweep2 N3): a device log search that failed is NOT CHECKED (before: an empty answer, read as no events)' $lg
  function global:Post-Isapi($base, $path, $xml) { return @{ code = 200; body = '<x><metaId>log.std-cgi.com/Exception/netBroken</metaId></x><x><metaId>log.std-cgi.com/Exception/netBroken</metaId></x>' } }
  $lg = ''; if (Get-Command Read-Logs -ErrorAction SilentlyContinue) { $lg = [string](Read-Logs 'http://127.0.0.1' '127.0.0.1') }
  Check ($lg -eq 'Exception/netBroken=2') 'control: a log search that answered is counted as before' $lg
  Check ($ncs -match "if \(-not \`$gw\) \{ Say 'Gateway: NOT CHECKED") 'source check (the summary runs only on Windows): no readable default route says Gateway NOT CHECKED, not "this PC is cut off"'
  Check ($ncs -match "Traffic into this PC: NOT CHECKED") 'source check: adapter counters that could not be read say NOT CHECKED (before: the storm line was silently left out)'
  Check ($ncs -match '\$cs = Get-NcChannelSummary \$c\.code \$c\.body' -and $ncs -match '\$row\.streams_to = Get-NcStreamsText \$ss') 'source check: the per-host pass uses the two readers above'
}

# ==============================================================================================================================
Write-Host ''
Write-Host 'Site Check (SiteCheck.ps1, class C): red only for a channel READ as down, amber NOT CHECKED for no state'
Run-Safe 'sitecheck' {
  # its own PowerShell: SiteCheck.ps1 compiles its own copy of the LAN certificate helper, which clashes with ToolkitCore's in one process
  $scp = Join-Path $tmp 'sc-child.ps1'
  $body = @'
param([string]$repo)
$ErrorActionPreference = 'Stop'
function Check([bool]$ok, [string]$name, [string]$more = '') { if ($ok) { Write-Output ('PASS ' + $name) } else { Write-Output ('FAIL ' + $name); if ($more) { Write-Output ('     ' + $more) } } }
function Read-Src([string]$rel) { return [IO.File]::ReadAllText((Join-Path $repo ($rel -replace '/', [string][IO.Path]::DirectorySeparatorChar))) }
try {

  # SiteCheck.ps1 -LoadOnly needs the Windows drawing library (GDI+): take its check code ($SC_CODE, what the window and the
  # console both run) and its New-ScMock straight from the file instead
  $e = $null; $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'sitecheck/SiteCheck.ps1'), [ref]$null, [ref]$e)
  $as = $ast.Find({ param($x) $x -is [Management.Automation.Language.AssignmentStatementAst] -and $x.Left.Extent.Text -eq '$SC_CODE' }, $true)
  . ([scriptblock]::Create([string]$as.Right.Expression.Value))
  $mk = $ast.Find({ param($x) $x -is [Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'New-ScMock' }, $true)
  . ([scriptblock]::Create($mk.Extent.Text))
  $hik = ConvertFrom-ScHikStatus '<InputProxyChannelStatus><id>1</id><ipAddress>192.0.2.21</ipAddress><online>true</online></InputProxyChannelStatus><InputProxyChannelStatus><id>2</id><ipAddress>192.0.2.22</ipAddress><chanDetectResult></chanDetectResult></InputProxyChannelStatus><InputProxyChannelStatus><id>3</id><ipAddress>192.0.2.23</ipAddress><online>false</online></InputProxyChannelStatus>' ''
  $c2 = @($hik | Where-Object { $_.Ch -eq 2 })[0]; $c3 = @($hik | Where-Object { $_.Ch -eq 3 })[0]
  Check ($c2.PSObject.Properties['Known'] -and -not $c2.Known -and $c3.Known -and -not $c3.Online) 'reproduction (sweep2 S1): a Hikvision channel with no <online> is NOT CHECKED (Known false), one READ as false is offline'
  $dh = ConvertFrom-ScDahuaStatus "states[0].channel=0`nstates[0].connectionState=Connected`nstates[1].channel=1`nstates[1].connectionState=" '' ''
  $d1 = @($dh | Where-Object { $_.Ch -eq 2 })[0]
  Check ($d1 -and $d1.PSObject.Properties['Known'] -and -not $d1.Known) 'sweep2 S1 twin (Dahua branch): an empty connection state is NOT CHECKED, not offline'
  $R = New-ScMock
  $R.channels = @(@($R.channels | Where-Object { $_.Online }) + [pscustomobject]@{ Ch = 9; Ip = '192.0.2.29'; Online = $false; Known = $false; Detail = ''; Name = 'Roof'; Protocol = 'HIKVISION'; Model = '' })
  $D = Get-ScDiagnosis $R
  $bad = @($D.Findings | Where-Object { $_.Level -eq 'bad' -and $_.Text -match 'ch 9' }); $warn = @($D.Findings | Where-Object { $_.Level -eq 'warn' -and $_.Text -match 'ch 9' -and $_.Text -match 'NOT CHECKED' })
  Check ($bad.Count -eq 0 -and $warn.Count -eq 1) 'reproduction (sweep2 S2): the diagnosis gives a channel with no state an amber NOT CHECKED line, not a red PROBLEM' (($D.Findings | ForEach-Object { $_.Level + ':' + $_.Text }) -join ' | ')
  Check ($D.Headline -notmatch '^All ' -and $D.Headline -match 'NOT CHECKED' -and $D.Headline -notmatch 'NOT working') 'sweep2 S2: the headline says NOT CHECKED - not "All N online" and not "N NOT working"' $D.Headline
  $txt = Format-ScReport $R $D
  Check ($txt -match 'ch 9 .*NOT CHKD' -and $txt -cnotmatch 'ch 9 .*OFFLINE') 'sweep2 S2: the report''s channel table says NOT CHKD for it, not OFFLINE'
  $R0 = New-ScMock; $D0 = Get-ScDiagnosis $R0
  Check (@($D0.Findings | Where-Object { $_.Level -eq 'bad' }).Count -ge 3) 'control: the mock''s channels READ as offline are still red PROBLEMs'
  $sc = Read-Src 'sitecheck/SiteCheck.ps1'
  Check ($sc -match "online = \`$\(if \(\`$_\.PSObject\.Properties\['Known'\] -and -not \`$_\.Known\) \{ \`$null \}") 'source check (upload needs the service): the site page gets online = null (NOT CHECKED) for such a channel, never false'
  $scc = Read-Src 'sitecheck/WireIt-SiteCheck.cmd'; $sci = $scc.IndexOf('##' + 'PSSTART')
  Check ($sci -gt 0 -and $scc.Substring($sci + 11).Trim() -eq $sc.Trim()) 'the Site check launcher .cmd carries this SiteCheck.ps1 exactly'

} catch { Write-Output ('FAIL sitecheck (the check itself stopped): ' + $_.Exception.Message + ' @' + $_.InvocationInfo.ScriptLineNumber) }
'@
  [IO.File]::WriteAllText($scp, $body)
  $out = @(& $exe -NoProfile -ExecutionPolicy Bypass -File $scp -repo $repo 2>&1 | ForEach-Object { [string]$_ })
  $seen = 0
  foreach ($l in $out) { if ($l -match '^PASS (.*)$') { $seen++; Check $true $Matches[1] } elseif ($l -match '^FAIL (.*)$') { $seen++; Check $false $Matches[1] } elseif ($l -match '^\s{5}') { Write-Host $l } }
  Check ($seen -ge 8) ('sitecheck: the child run gave its checks (' + $seen + ' seen)') (($out | Select-Object -Last 4) -join ' | ')
}

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host ('RESULT: ' + $script:pass + ' passed, ' + $script:fail + ' failed, ' + $script:deferred + ' deferred')
if ($script:fail) { exit 1 } else { exit 0 }
