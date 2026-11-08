<#
 Test-Fix22.ps1 - WireIt Toolkit 2.2.0 tests for the review fixes (pwsh 7 or Windows PowerShell 5.1; no Windows-only parts).
   H1  the icacls plan (who may touch what under C:\WireIt), the "Fix this site" task definition and who may run it
   H2  the site-password word: asked hidden, never in a log; old 2.1 logs are blanked
   H3  the runner: only a checked request runs; the questions go to the window and back (file channel); end to end with a fake window
   M1  the secrets store: machine-wide (LM1), 2.1 files moved, a file another account made is reported, never replaced
 Usage: pwsh -File Test-Fix22.ps1   (exit code = number of failed checks)
#>
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path; $tk = Split-Path -Parent $here
$script:fail = 0; $script:pass = 0
function Check([bool]$ok, [string]$what) { if ($ok) { $script:pass++; Write-Host ('  ok    ' + $what) } else { $script:fail++; Write-Host ('  FAIL  ' + $what) -ForegroundColor Red } }
function Eq($a, $b, [string]$what) { Check ("$a" -eq "$b") ($what + ' (got "' + $a + '", want "' + $b + '")') }
$psx = (Get-Process -Id $PID).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fix22-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Force -Path $tmp | Out-Null
. (Join-Path $tk 'WireItAcl.ps1'); . (Join-Path $tk 'FixSiteIpc.ps1'); . (Join-Path $tk 'FixSiteCore.ps1'); . (Join-Path $tk 'FixSiteDevices.ps1')
function Fs-LogLine([string]$s) { }
try {
Write-Host 'H1. permissions plan'
$plan = Get-WireItAclPlan 'C:\WireIt'
$tkStep = @($plan | Where-Object { $_.path -eq 'C:\WireIt\Toolkit' -and $_.args -contains '/inheritance:r' })[0]
Check ($null -ne $tkStep) 'Toolkit: inheritance removed (the "Authenticated Users: Modify" from C:\ no longer reaches it)'
Check ($tkStep.args -contains '*S-1-5-32-544:(OI)(CI)F' -and $tkStep.args -contains '*S-1-5-18:(OI)(CI)F') 'Toolkit: Administrators + SYSTEM full control'
Check ($tkStep.args -contains '*S-1-5-32-545:(OI)(CI)RX') 'Toolkit: Crew (Users) read + execute'
Check (@($tkStep.args | Where-Object { $_ -match 'S-1-5-32-545:.*(\bM\b|\bF\b|\bW\b)' }).Count -eq 0) 'Toolkit: Crew gets no write/modify/full on the Toolkit folder (scripts, config.json)'
Check (@($plan | Where-Object { $_.path -eq 'C:\WireIt\Toolkit' -and $_.args -contains '/remove:g' -and $_.args -contains '/T' }).Count -eq 1) 'Toolkit: old grants to Users / Authenticated Users inside it are removed (whole tree)'
foreach ($t in 'FixNVR', 'CamReset', 'NetCheck') { Check (@($plan | Where-Object { $_.path -eq ('C:\WireIt\' + $t) -and $_.args -contains '/inheritance:r' -and $_.args -contains '*S-1-5-32-545:(OI)(CI)RX' }).Count -eq 1) ($t + ': locked the same way (its scripts run elevated too)') }
$wr = @($plan | Where-Object { $_.args -contains '*S-1-5-32-545:(OI)(CI)(IO)M' } | ForEach-Object { $_.path })
Check ($wr -contains 'C:\WireIt\Toolkit\logs' -and $wr -contains 'C:\WireIt\Toolkit\ipc' -and $wr -contains 'C:\WireIt\Toolkit\inbox' -and $wr -contains 'C:\WireIt\CamReset\replies') 'Crew can write only its data folders (logs, ipc, inbox, CamReset replies, ...)'
Check (-not ($wr | Where-Object { $_ -match 'fixsite-runs|vault|secrets|modules' -or $_ -eq 'C:\WireIt\Toolkit' })) 'no write for Crew on fixsite-runs (undo files), vault, secrets, modules or the Toolkit folder itself'
Check (@($plan | Where-Object { $_.args -contains '*S-1-5-32-545:(RX,WD,AD)' }).Count -eq $wr.Count) 'data folders: Crew cannot delete or swap the folder itself (inherit-only Modify + add files on the folder)'
$v = @($plan | Where-Object { $_.path -eq 'C:\WireIt\Toolkit\vault' })[0]
Check ($v -and $v.args -contains '/inheritance:r' -and -not ($v.args | Where-Object { $_ -match 'S-1-5-32-545|S-1-5-11' })) 'vault: Administrators + SYSTEM only, Crew nothing'
Check ([array]::IndexOf(@($plan), $v) -gt [array]::IndexOf(@($plan), $tkStep)) 'vault is locked after the Toolkit folder (its own rule wins)'
$calls = New-Object System.Collections.ArrayList
$env:WIREIT_ACL_TEST = '1'
$ar = Invoke-WireItAclPlan 'C:\WireIt' { param($a) [void]$calls.Add(($a -join ' ')); return 0 }
Check ($ar.ok -and $calls.Count -eq @($plan).Count) 'the plan runs through icacls, step by step'
$ar = Invoke-WireItAclPlan 'C:\WireIt' { param($a) if (($a -join ' ') -match 'vault') { return 5 }; return 0 }
Check (-not $ar.ok -and ($ar.failed -join ' ') -match 'vault') 'a failed icacls step is reported by name (the installer prints it)'
Remove-Item Env:\WIREIT_ACL_TEST
Write-Host 'H1/H3. the task'
[xml]$x = Get-WireItRunnerTaskXml 'C:\WireIt\Toolkit'
$ns = New-Object Xml.XmlNamespaceManager($x.NameTable); $ns.AddNamespace('t', 'http://schemas.microsoft.com/windows/2004/02/mit/task')
Eq $x.SelectSingleNode('//t:Principal/t:UserId', $ns).InnerText 'S-1-5-18' 'task runs as SYSTEM'
Eq $x.SelectSingleNode('//t:Principal/t:RunLevel', $ns).InnerText 'HighestAvailable' 'task runs elevated'
Eq $x.SelectSingleNode('//t:Settings/t:MultipleInstancesPolicy', $ns).InnerText 'IgnoreNew' 'one run at a time'
Eq $x.SelectSingleNode('//t:Settings/t:ExecutionTimeLimit', $ns).InnerText 'PT4H' 'stopped after 4 hours'
Check ($x.SelectNodes('//t:Triggers/*', $ns).Count -eq 0) 'no schedule: it only runs when the Toolkit starts it'
$arg = $x.SelectSingleNode('//t:Exec/t:Arguments', $ns).InnerText
Check ($arg -match 'FixSiteRunner\.ps1' -and $arg -match '-ToolkitDir "C:\\WireIt\\Toolkit"' -and $arg -notmatch 'TestPsExe|TestArgs') 'task runs FixSiteRunner.ps1 from the locked folder, fixed arguments only'
Check ($script:WireItTaskSddl -match '\(A;;GRGX;;;BU\)' -and $script:WireItTaskSddl -notmatch ';;(FA|GA|GW|GRGW)[^)]*;;;(BU|AU|WD)\)') 'who may run it: Users read + run; only Administrators/SYSTEM full'
$sc = New-Object System.Collections.ArrayList; $sd = @{}
$rt = Register-WireItRunnerTask 'C:\WireIt\Toolkit' { param($a) [void]$sc.Add($a); return 0 } { param($n, $s) $sd.n = $n; $sd.s = $s }
Check ($rt.ok -and ($sc[0] -join ' ') -match '^/Create /F /TN \\WireIt\\Fix this site /XML ' -and $sd.n -eq '\WireIt\Fix this site' -and $sd.s -eq $script:WireItTaskSddl) 'installer: schtasks /Create with the XML, then the run-permission is set'
$rt = Register-WireItRunnerTask 'C:\WireIt\Toolkit' { param($a) return 1 } { param($n, $s) }
Check (-not $rt.ok -and $rt.why -match 'schtasks') 'installer: a failed task creation is reported'
$rt = Register-WireItRunnerTask 'C:\WireIt\Toolkit' { param($a) return 0 } { param($n, $s) throw 'access denied' }
Check (-not $rt.ok -and $rt.why -match 'who may run it') 'installer: if the run-permission cannot be set it says so (Crew would not be able to start it)'

Write-Host 'H3. the request Crew sends'
$good = [pscustomobject]@{ v = 1; id = 'abcdef0123456789'; mode = 'Fix'; site = '2336 Main St (Bridgeport)'; newSite = $false; codec = 'H.264'; fps = 15; resolution = 'keep'; bitrate = 4096; allCameras = $true; passwordAll = $false; at = '2026-11-08T10:00:00'; user = 'Crew' }
$t = Test-FsRunRequest $good; Check ($t.ok -and $t.req.site -eq '2336 Main St (Bridgeport)' -and $t.req.fps -eq 15 -and $t.req.allCameras) 'a normal Fix request is accepted'
$a = Get-FsRunArgs $t.req 'S' 'R'
Check ($a -is [array] -and ($a -join '|') -match '\|-Site\|2336 Main St \(Bridgeport\)\|' -and $a -contains '-AllCameras' -and $a -notcontains '-PasswordAll') 'the run arguments are an array (no command string), every value from the checks'
function Bad($o, $w) { $c = $good.PSObject.Copy(); foreach ($k in $o.Keys) { if ($c.PSObject.Properties[$k]) { $c.$k = $o[$k] } else { $c | Add-Member -NotePropertyName $k -NotePropertyValue $o[$k] } }; $r = Test-FsRunRequest $c; Check (-not $r.ok) ('refused: ' + $w + ' (' + $r.why + ')') }
Bad @{ mode = 'Shell' } 'a mode not in the list'
Bad @{ mode = 'fix' } 'mode in the wrong case'
Bad @{ site = 'x"; Start-Process calc; "' } 'a site name with quotes/semicolons'
Bad @{ site = ('a' * 81) } 'a site name over 80'
Bad @{ codec = 'H.266' } 'a codec not in the list'
Bad @{ fps = 7 } 'a frame rate not in the list'
Bad @{ bitrate = '4096; calc' } 'a bitrate not a number from the list'
Bad @{ allCameras = 'yes' } 'a tick that is not true/false'
Bad @{ rollbackDir = 'C:\Windows' } 'an undo folder chosen by Crew (the runner picks it)'
Bad @{ script = 'C:\x.ps1' } 'any other field'
Bad @{ id = '../../x' } 'a bad request id'
Bad @{ siteList = '{"nope":1}' } 'a site list that is not a WireIt site list'
$t = Test-FsRunRequest ([pscustomobject]@{ v = 1; id = 'abcdef0123456789'; mode = 'Rollback'; site = 'whatever'; allCameras = $true })
Check ($t.ok -and -not $t.req.allCameras -and -not $t.req.site) 'Undo: site and ticks are dropped (the runner picks the last undoable run)'
Check ($null -eq (Read-FsIpcJson (Join-Path $tmp 'none.json'))) 'a missing request reads as none'
$bigf = Join-Path $tmp 'big.json'; [IO.File]::WriteAllText($bigf, ('{"a":"' + ('x' * 70000) + '"}')); Check ($null -eq (Read-FsIpcJson $bigf)) 'an oversized file is not read'

Write-Host 'H3. questions and answers (file channel)'
$sd2 = Join-Path $tmp 'sess'; New-Item -ItemType Directory -Force -Path $sd2 | Out-Null
$n = Send-FsIpc $sd2 @{ kind = 'choice'; text = 'Q?'; yes = 'Y'; no = 'N' }
$qs = @(Get-FsIpcQuestions $sd2); Check ($qs.Count -eq 1 -and [int]$qs[0].n -eq $n -and $qs[0].kind -eq 'choice') 'the window sees the question'
Write-FsIpcAnswer $sd2 $n 'yes'; Check ((Wait-FsIpcAnswer $sd2 $n 'choice' 5 50) -eq $true) 'Yes comes back as true'
Check (-not (Test-Path (Join-Path $sd2 ('a-{0:D4}.json' -f $n)))) 'the answer file is removed once read'
$n = Send-FsIpc $sd2 @{ kind = 'choice'; text = 'Q2' }; Write-FsIpcAnswer $sd2 $n 'rm -rf /'; Check ($null -eq (Wait-FsIpcAnswer $sd2 $n 'choice' 5 50)) 'a choice answer that is not yes/no is ignored'
$n = Send-FsIpc $sd2 @{ kind = 'text'; text = 'T' }; Write-FsIpcAnswer $sd2 $n (('a' * 300) + "`r`n`u{0007}"); $ta = Wait-FsIpcAnswer $sd2 $n 'text' 5 50
Check ($ta.Length -eq 256 -and $ta -notmatch '[\x00-\x1F]') 'a typed answer is cut to 256 characters, control characters dropped'
$n = Send-FsIpc $sd2 @{ kind = 'portal' }; Write-FsIpcAnswer $sd2 $n 'whatever'; Eq (Wait-FsIpcAnswer $sd2 $n 'portal' 5 50) 'failed' 'a portal answer outside the fixed set counts as failed'
$n = Send-FsIpc $sd2 @{ kind = 'text'; text = 'T' }; Check ($null -eq (Wait-FsIpcAnswer $sd2 $n 'text' 1 50)) 'no answer: times out (the run stops safely)'
$n = Send-FsIpc $sd2 @{ kind = 'secret'; text = 'S' }; Write-FsIpcAnswer $sd2 $n 'Hunter22'; Clear-FsIpcSession $sd2
Check (-not @(Get-ChildItem $sd2 -Filter 'a-*').Count -and -not @(Get-ChildItem $sd2 -Filter 'q-*').Count) 'end of a run: every question/answer file is removed (a typed password does not stay on disk)'

Write-Host 'H2. the word: old logs'
$lr = Join-Path $tmp 'oldruns\2026-11-06_1012_Lieber'; New-Item -ItemType Directory -Force -Path $lr | Out-Null
[IO.File]::WriteAllLines((Join-Path $lr 'log.txt'), @('10:12:01 SAY hi', '10:12:02 ASK Site passwords start with your word, then 4 random digits. Type the word (same capital letters; letters/digits, 4-16 long, starting with a letter). Asked once - kept encrypted on this PC:', '10:12:09 ANSWER Zebrafish', '10:12:10 ASK Which site?', '10:12:11 ANSWER Lieber'))
Eq (Clear-WordAnswerFromLogs @((Join-Path $tmp 'oldruns'))) 1 'installer: the one logged word is found'
$ll = Get-Content (Join-Path $lr 'log.txt') -Raw
Check ($ll -notmatch 'Zebrafish' -and $ll -match '10:12:09 ANSWER \(hidden\)' -and $ll -match 'ANSWER Lieber') 'the word is blanked; other answers stay'
Eq (Clear-WordAnswerFromLogs @((Join-Path $tmp 'oldruns'))) 0 'run again: nothing left to blank'

Write-Host 'M1. secrets store'
$script:FsDpapi = { param($op, $data, $scope) if ($op -eq 'protect') { return [byte[]](@([byte]$(if ($scope -eq 'LocalMachine') { 1 } else { 2 })) + $data) }; if ($data[0] -eq 1 -and $scope -eq 'LocalMachine') { return [byte[]]$data[1..($data.Length - 1)] }; if ($data[0] -eq 2 -and $scope -eq 'CurrentUser' -and $env:FAKE_SAME_USER) { return [byte[]]$data[1..($data.Length - 1)] }; throw 'cannot decrypt' }
$vault = Join-Path $tmp 'vault'; $legacy = Join-Path $tmp 'secrets'; New-Item -ItemType Directory -Force -Path $legacy | Out-Null
$enc = Protect-FsText 'abc'; Check ($enc.StartsWith('LM1:')) 'new files are machine-wide (LM1)'; Eq (Unprotect-FsText $enc) 'abc' 'and read back'
$cu = { param($t) [Convert]::ToBase64String([byte[]](@([byte]2) + [Text.Encoding]::UTF8.GetBytes($t))) }
[IO.File]::WriteAllText((Join-Path $legacy 'site-Lieber.dat'), (& $cu '{"site":"Lieber","password":"Lieber#7788"}'))
New-Item -ItemType Directory -Force -Path $vault | Out-Null; [IO.File]::WriteAllText((Join-Path $vault 'site-Other.dat'), (& $cu '{"site":"Other","password":"x"}'))
$env:FAKE_SAME_USER = ''
$s0 = Read-FsSecrets $vault 'Other'; Check ($s0.unreadable -and -not $s0.password) 'a 2.1 file in vault made by another account: unreadable, not "no password"'
$script:FsLegacySecretsDir = $legacy
$s1 = Read-FsSecrets $vault 'Lieber'; Check ($s1.unreadable -and (Get-FsUnreadableText $s1.unreadableWhy) -match 'another Windows account') 'another admin than the one who saved it: reported as "saved by another Windows account"'
$env:FAKE_SAME_USER = '1'
$s2 = Read-FsSecrets $vault 'Lieber'; Check (-not $s2.unreadable -and $s2.password -eq 'Lieber#7788') 'the account that saved it reads it'
Check ((Test-Path (Join-Path $vault 'site-Lieber.dat')) -and (Get-Content (Join-Path $vault 'site-Lieber.dat') -Raw).StartsWith('LM1:') -and -not (Test-Path (Join-Path $legacy 'site-Lieber.dat'))) 'and it is moved into vault\ as machine-wide'
$env:FAKE_SAME_USER = ''
$s3 = Read-FsSecrets $vault 'Lieber'; Check ($s3.password -eq 'Lieber#7788') 'after the move ANY admin account (or SYSTEM) reads it'
$script:FsLegacySecretsDir = ''
[IO.File]::WriteAllText((Join-Path $legacy 'password-word.dat'), (& $cu 'Zebrafish'))
$env:FAKE_SAME_USER = '1'; $cv = Convert-FsSecretStores $legacy (Join-Path $tmp 'vault2')
Check ($cv.moved -eq 1 -and @($cv.unreadable).Count -eq 0 -and (Get-FsSitePrefix $null (Join-Path $tmp 'vault2')) -eq 'Zebrafish') 'installer: Convert-FsSecretStores moves what this account can read'
[IO.File]::WriteAllText((Join-Path $legacy 'site-Nope.dat'), (& $cu '{"site":"Nope"}')); $env:FAKE_SAME_USER = ''
$cv = Convert-FsSecretStores $legacy (Join-Path $tmp 'vault2'); Check (@($cv.unreadable) -contains 'site-Nope.dat' -and (Test-Path (Join-Path $legacy 'site-Nope.dat'))) 'installer: a file another account made is listed and left where it is'
[IO.File]::WriteAllText((Join-Path $vault 'site-Pc.dat'), 'LM1:' + [Convert]::ToBase64String([byte[]](9, 9, 9)))
$s4 = Read-FsSecrets $vault 'Pc'; Check ($s4.unreadable -and (Get-FsUnreadableText $s4.unreadableWhy) -match 'another PC') 'a vault file copied from another PC: reported as such'
$script:FsDpapi = $null; Remove-Item Env:\FAKE_SAME_USER -ErrorAction SilentlyContinue

Write-Host 'H2/H3. end to end: the runner, a fake Toolkit window, the word asked hidden'
$tkd = Join-Path $tmp 'tk'; New-Item -ItemType Directory -Force -Path (Join-Path $tkd 'ipc') | Out-Null
foreach ($f in @(Get-ChildItem $tk -Filter '*.ps1' -File)) { Copy-Item $f.FullName $tkd }
Copy-Item (Join-Path $tk 'modules') $tkd -Recurse -ErrorAction SilentlyContinue
$sec = Join-Path $tmp 'e2e-vault'; $sites = Join-Path $tmp 'e2e-sites'
$env:WIREIT_RUNNER_TEST = '1'
$st = Start-FsRunner $tkd @{ mode = 'SitePassword'; site = 'Qq Runner Test 301'; newSite = $false }
Check ($st.ok -and (Test-Path (Join-Path $tkd 'ipc\request.json'))) 'the window writes the request (the task would start the runner)'
$rp = Start-Process -FilePath $psx -ArgumentList @('-NoProfile', '-File', (Join-Path $tkd 'FixSiteRunner.ps1'), '-ToolkitDir', $tkd, '-TestPsExe', $psx, '-TestArgsList', 'MockUrl=http://127.0.0.1:9') -PassThru
$seen = New-Object System.Collections.ArrayList; $shown = ''; $end = (Get-Date).AddSeconds(150); $state = ''
while ((Get-Date) -lt $end) {
  $cur = Read-FsIpcJson (Join-Path $tkd 'ipc\current.json')
  if ($cur -and $cur.session) {
    $sd3 = Join-Path $tkd ('ipc\' + $cur.session)
    foreach ($q in @(Get-FsIpcQuestions $sd3)) {
      [void]$seen.Add([string]$q.kind + ':' + [string]$q.text)
      switch ([string]$q.kind) { 'choice' { Write-FsIpcAnswer $sd3 ([int]$q.n) 'no' } 'secret' { Write-FsIpcAnswer $sd3 ([int]$q.n) 'Zebraword' } 'text' { Write-FsIpcAnswer $sd3 ([int]$q.n) $(if ([string]$q.text -match 'N = no, make one') { 'N' } else { '' }) } 'show' { $shown = [string]$q.value; Write-FsIpcAnswer $sd3 ([int]$q.n) 'closed' } default { Write-FsIpcAnswer $sd3 ([int]$q.n) 'ok' } }
    }
    if ([string]$cur.state -in @('ended', 'refused')) { $state = [string]$cur.state; break }
  }
  Start-Sleep -Milliseconds 200
}
try { if (-not $rp.HasExited) { $rp.Kill() } } catch {}
if ($env:F22DBG) { 'SEEN: ' + ($seen -join ' || '); Get-ChildItem (Join-Path $tkd 'fixsite-runs') -Recurse -File | ForEach-Object { '--- ' + $_.FullName; Get-Content $_.FullName -TotalCount 40 } }
Eq $state 'ended' 'the runner ran the request and said when it ended'
Check (@($seen | Where-Object { $_ -like 'text:Y = yes, I know it*N = no, make one*' }).Count -eq 1) 'the Yes / No question (Site password... button) came to the window and the answer went back'
# 2.2.1 (review M1): a made site password is fully random - no word is asked any more
Check (@($seen | Where-Object { $_ -like 'secret:*your word*' -or $_ -like 'secret:*again to confirm*' }).Count -eq 0) 'no site-password word is asked any more (2.2.1: fully random, review M1)'
Check ($shown -cmatch '^[A-HJ-NP-Za-km-z2-9]{14}$' -and $shown -cmatch '[A-Z]' -and $shown -cmatch '[a-z]' -and $shown -cmatch '\d') 'the made site password (14 random characters) went to the window to show once'
$runLogs = @(Get-ChildItem (Join-Path $tkd 'fixsite-runs') -Recurse -File -ErrorAction SilentlyContinue)
Check ($runLogs.Count -ge 1) 'the run wrote its log in the admin-owned fixsite-runs folder'
Check (-not @($runLogs | Select-String -SimpleMatch -Pattern 'Zebraword' -List).Count) 'the word is in no log file (not even inside the made password)'
Check (-not @(Get-ChildItem (Join-Path $tkd 'ipc') -Recurse -File -Filter 'a-*.json').Count -and -not @(Get-ChildItem (Join-Path $tkd 'ipc') -Recurse -File -Filter 'q-*.json').Count) 'no question/answer file is left in ipc\ after the run'
# a refused request: the window hears why
$env:WIREIT_RUNNER_TEST = '1'
Write-FsIpcJson (Join-Path $tkd 'ipc\request.json') ([ordered]@{ v = 1; id = 'zzzzzzzz12345678'; mode = 'Fix'; site = 'Bad;site'; extra = 'x' })
$p2 = Start-Process -FilePath $psx -ArgumentList @('-NoProfile', '-File', (Join-Path $tkd 'FixSiteRunner.ps1'), '-ToolkitDir', $tkd) -PassThru -Wait
$cur = Read-FsIpcJson (Join-Path $tkd 'ipc\current.json')
Check ($p2.ExitCode -eq 2 -and $cur.state -eq 'refused' -and $cur.id -eq 'zzzzzzzz12345678' -and [string]$cur.why -match 'not allowed') 'a bad request is refused, nothing runs, and the window is told why'
Check (-not (Test-Path (Join-Path $tkd 'ipc\request.json'))) 'the request file is used once'
Remove-Item Env:\WIREIT_RUNNER_TEST -ErrorAction SilentlyContinue
} finally { try { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue } catch {} }
Write-Host ''
Write-Host ($script:pass.ToString() + ' passed, ' + $script:fail + ' failed')
exit $script:fail
