<# Test-Fix2218Sweep.ps1 - tests for WireIt Toolkit 2.2.18 (Nov 11 2026), the whole-repo sweep after Codex's review of 2.2.17.
   The sweep read every device write / success claim / failed read / safety record outside Fix this site, classic Fix NVR and the
   NvrHealth module for four patterns: (A) a write whose target is not confirmed right before it, (B) "done" resting on an
   acknowledgement instead of a read-back, (C) a failed read taken as a definite "no", (D) safety state that a restart or a failed
   read loses. Each check below RUNS the real function (or the real script) with the file system / network boundary replaced.
   No real device or Windows feature is touched, so real-device and real-Windows behaviour is DEFERRED (never a pass).
   PS 5.1 or pwsh 7. FIX2218SWEEP_REPO (tests only) = run against another checkout (old-code proof: on 2.2.17 the sweep checks FAIL,
   the controls pass). #>
$ErrorActionPreference = 'Stop'
$repo = $(if ($env:FIX2218SWEEP_REPO) { $env:FIX2218SWEEP_REPO } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) })
$tk = Join-Path $repo 'Toolkit'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fix2218sweep-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$script:pass = 0; $script:fail = 0; $script:deferred = 0
function Check([bool]$ok, [string]$name, [string]$more = '') {
  if ($ok) { $script:pass++; Write-Host ('PASS ' + $name) } else { $script:fail++; Write-Host ('FAIL ' + $name); if ($more) { Write-Host ('     ' + $more) } }
}
function Deferred([string]$name) { $script:deferred++; Write-Host ('DEFERRED ' + $name) }
$exe = $(if ($PSVersionTable.PSEdition -eq 'Core') { (Get-Process -Id $PID).Path } else { Join-Path $PSHOME 'powershell.exe' })
$isWin = ($env:OS -eq 'Windows_NT')
# a file this login cannot read (chmod 000 off Windows; a deny ACE on Windows)
function Lock-Unreadable([string]$p) {
  if ($isWin) { $acl = Get-Acl -LiteralPath $p; $rule = New-Object Security.AccessControl.FileSystemAccessRule([Security.Principal.WindowsIdentity]::GetCurrent().Name, 'Read', 'Deny'); $acl.AddAccessRule($rule); Set-Acl -LiteralPath $p $acl }
  else { & chmod 000 $p }
}
function Unlock-File([string]$p) { if ($isWin) { $acl = Get-Acl -LiteralPath $p; foreach ($r in @($acl.Access | Where-Object { $_.AccessControlType -eq 'Deny' })) { [void]$acl.RemoveAccessRule($r) }; Set-Acl -LiteralPath $p $acl } else { & chmod 644 $p } }
function Lock-Dir([string]$p) { if (-not $isWin) { & chmod 555 $p } }
function Unlock-Dir([string]$p) { if (-not $isWin) { & chmod 755 $p } }
$canLock = $true
try { $probe = Join-Path $tmp 'probe.txt'; [IO.File]::WriteAllText($probe, 'x'); Lock-Unreadable $probe; try { [void][IO.File]::ReadAllText($probe); $canLock = $false } catch {}; Unlock-File $probe } catch { $canLock = $false }

foreach ($f in @('HikResetFlow.ps1', 'HikReset.ps1', 'HikEmailDrop.ps1', 'ToolkitCore.ps1', 'WireItToolkit.ps1')) {
  $e = $null; [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $tk $f), [ref]$null, [ref]$e); Check ($e.Count -eq 0) ('parses: ' + $f) ($e | Out-String)
}
$scPs = Join-Path $repo 'sitecheck/SiteCheck.ps1'
$e = $null; [void][Management.Automation.Language.Parser]::ParseFile($scPs, [ref]$null, [ref]$e); Check ($e.Count -eq 0) 'parses: SiteCheck.ps1' ($e | Out-String)

try {
# ==============================================================================================================================
Write-Host ''
Write-Host 'HikResetFlow: the reset record (state.json) that cannot be read is not an empty record (classes C + D)'
. (Join-Path $tk 'HikResetFlow.ps1'); . (Join-Path $tk 'HikEmailDrop.ps1')
$script:said = New-Object System.Collections.Generic.List[string]
$script:HkSay = { param($t, $c) [void]$script:said.Add([string]$t) }
$SN = 'DS-2CD2143G0-I20200101AAWRF12345678'
$good = [ordered]@{ version = 1; site = 'Review'; created = '2026-11-10T20:00:00'; devices = @([ordered]@{ serial = $SN; shortSerial = 'F12345678'; mac = 'c4-2f-90-00-00-50'; ip = '192.0.2.50'; model = 'DS-2CD2143G0-I'; status = 'refused'; note = 'the device refused the unlock file'; rebootRetries = 2; refusedChecksOk = $true; exportedAt = '2026-11-10T20:00:00'; validUntil = '2026-11-12T20:00:00'; requestFile = ''; bootTime = '' }); exports = @() }
$cases = [ordered]@{ 'torn (half written)' = '{ "version": 1, "devices": [ { "serial": "DS-2CD'; 'empty file' = ''; 'not a record' = '{ "hello": 1 }' }
foreach ($k in $cases.Keys) {
  $sp = Join-Path $tmp ('state-' + ($k -replace '[^a-z]', '') + '.json'); [IO.File]::WriteAllText($sp, $cases[$k])
  $threw = $false; $msg = ''; $st = $null
  try { $st = Read-HikState $sp } catch { $threw = $true; $msg = $_.Exception.Message }
  Check ($threw -and $msg -match 'could not be read' -and $msg -match 'Nothing was sent') ('sweep D: Read-HikState with a ' + $k + ' record stops with "could not be read ... Nothing was sent" (2.2.17: started over with an empty record)') ('threw=' + $threw + ' devices=' + $(if ($st) { @($st.devices).Count } else { '-' }) + ' msg=' + $msg)
  Check ([IO.File]::ReadAllText($sp) -eq $cases[$k]) ('sweep D: ...the ' + $k + ' record is left exactly as it was')
}
if ($canLock) {
  $spL = Join-Path $tmp 'state-locked.json'; [IO.File]::WriteAllText($spL, ($good | ConvertTo-Json -Depth 6)); Lock-Unreadable $spL
  $threw = $false; try { $null = Read-HikState $spL } catch { $threw = $true }
  Unlock-File $spL
  Check $threw 'sweep D: Read-HikState with a record this login cannot open stops (2.2.17: read as "no devices")'
} else { Deferred 'sweep D: Read-HikState with a record this login cannot open (this test login reads everything)' }
# controls
$spG = Join-Path $tmp 'state-good.json'; [IO.File]::WriteAllText($spG, ($good | ConvertTo-Json -Depth 6))
$stG = Read-HikState $spG
Check (@($stG.devices).Count -eq 1 -and [string]$stG.devices[0].status -eq 'refused' -and [int]$stG.devices[0].rebootRetries -eq 2) 'control: a good record reads back its refused device and its 2 reboot-retries'
$stN = Read-HikState (Join-Path $tmp 'no-such-dir/state.json')
Check (@($stN.devices).Count -eq 0) 'control: no record yet (first reset on this PC) = a new empty record'
$spS = Join-Path $tmp 'save/state.json'
Save-HikState $spS $stG
$back = Read-HikState $spS
Check (@($back.devices).Count -eq 1 -and [string]$back.devices[0].serial -eq $SN -and -not @(Get-ChildItem -LiteralPath (Join-Path $tmp 'save') -Filter '*.tmp').Count) 'control: Save-HikState writes a record that reads back whole, no temp file left'

Write-Host ''
Write-Host 'HikReset.ps1 -Mode Retry with a damaged record: not "nothing to retry" (class C)'
$sd = Join-Path $tmp 'retry'; New-Item -ItemType Directory -Force -Path $sd | Out-Null
$cfgR = Join-Path $sd 'config.json'; '{ "form": { "firstName": "Moshe", "lastName": "Reichman", "email": "moshe@wireitct.com", "company": "WireIt CT LLC" } }' | Set-Content $cfgR
$torn = '{ "version": 1, "devices": [ { "serial": "' + $SN + '", "status": "refu'
[IO.File]::WriteAllText((Join-Path $sd 'state.json'), $torn)
$o = & $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tk 'HikReset.ps1') -Mode Retry -StateDir $sd -ConfigPath $cfgR -SadpTest '127.0.0.1:9' 2>&1 | Out-String
$rc = $LASTEXITCODE
Check ($rc -ne 0 -and $o -notmatch 'nothing to retry' -and $o -match 'could not be read') 'sweep C: Retry with a damaged reset record exits non-zero and says the record could not be read (2.2.17: "nothing to retry", exit 0)' ('exit ' + $rc + ': ' + $o.Trim())
Check ([IO.File]::ReadAllText((Join-Path $sd 'state.json')) -eq $torn) 'sweep D: ...and the damaged record is not overwritten'
# control: a good record with a refused device that may not be retried yet still says why (no export), exit 0
[IO.File]::WriteAllText((Join-Path $sd 'state.json'), ($good | ConvertTo-Json -Depth 6))
$o2 = & $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tk 'HikReset.ps1') -Mode Retry -StateDir $sd -ConfigPath $cfgR -SadpTest '127.0.0.1:9' 2>&1 | Out-String
Check ($LASTEXITCODE -eq 0 -and $o2 -match 'reboot-retries' -and $o2 -notmatch 'request file saved') 'control: Retry with a good record (2 reboot-retries used) still says no more retries, exit 0' $o2.Trim()

Write-Host ''
Write-Host 'Invoke-HikResetStage (Fix this site) with a damaged record: nothing is asked of any device (classes C + D)'
$script:sadpCalls = 0
$sdF = Join-Path $tmp 'stage'; New-Item -ItemType Directory -Force -Path $sdF | Out-Null
[IO.File]::WriteAllText((Join-Path $sdF 'state.json'), $torn)
function Find-HikSadp { param([double]$Seconds = 3.5, $Socks = $null) $script:sadpCalls++; return @() }
$stageR = $null; $stageErr = ''
try { $stageR = Invoke-HikResetStage -Targets @([pscustomobject]@{ mac = 'c4:2f:90:00:00:50'; ip = '192.0.2.50' }) -SitePassword 'Site-Pass-1234' -StateDir $sdF -Config ([pscustomobject]@{ form = $null; replyDir = '' }) -VerifyLogin { param($ip, $p) $false } -WaitMinutes 0 } catch { $stageErr = $_.Exception.Message }
Check ($script:sadpCalls -eq 0 -and $stageR -and -not @($stageR.fixed).Count -and @($stageR.pending | Where-Object { [string]$_.reason -match 'could not be read' }).Count -eq 1) 'sweep C/D: the reset stage with a damaged record asks no device anything and returns the camera as pending "record could not be read"' ('sadp calls ' + $script:sadpCalls + ', err ' + $stageErr + ', pending ' + $(if ($stageR) { (@($stageR.pending | ForEach-Object { $_.reason }) -join ' | ') } else { '-' }))
Check ([IO.File]::ReadAllText((Join-Path $sdF 'state.json')) -eq $torn) 'sweep D: ...and the damaged record is left as it was'
Remove-Item Function:\Find-HikSadp
. (Join-Path $tk 'HikSadp.ps1')   # the real Find-HikSadp back (not called again below)

Write-Host ''
Write-Host 'Receive-HikReplies: an unlock file counts as received only when its saved copy reads back (classes B + D)'
# These run in their own PowerShell, the way HikReset.ps1 and the Toolkit window run them: ErrorActionPreference Continue and no
# try around the call (a failed .NET write then does NOT stop the code that follows it)
$rcvChild = Join-Path $tmp 'receive-child.ps1'
[IO.File]::WriteAllText($rcvChild, @'
param($tk, $base, $mode, $SN)
$ErrorActionPreference = 'Continue'
. (Join-Path $tk 'HikResetFlow.ps1'); . (Join-Path $tk 'HikEmailDrop.ps1')
$script:said = New-Object System.Collections.Generic.List[string]
$script:HkSay = { param($t, $c) [void]$script:said.Add([string]$t) }
function Get-HikReplyMessages { param($Cfg, [string]$ToolkitDir, [string]$ReplyDir, [datetime]$Since, $Pending = @(), [string]$InboxDir = '', [switch]$ForceRelay) return @() }
$unlockB = [Text.Encoding]::UTF8.GetBytes('<?xml version="1.0"?><ResetPassword><Code>Ab3dE5gH</Code><DeviceSN>' + $SN + '</DeviceSN></ResetPassword>')
$inb = Join-Path $base 'inbox/hik'; $rep = Join-Path $base 'replies'
New-Item -ItemType Directory -Force -Path $inb, $rep | Out-Null
$drop = Join-Path $inb ('drop-' + $SN + '-20261110-210000.xml'); [IO.File]::WriteAllBytes($drop, $unlockB)
$req = Join-Path $base 'request.xml'; [IO.File]::WriteAllText($req, 'our own request file')
$dest = Join-Path $rep ('reply-' + ($SN -replace '[^A-Za-z0-9\-]', '_') + '.xml')
if ($mode -eq 'blocked') { New-Item -ItemType Directory -Force -Path $dest | Out-Null }   # a folder sits where the reply file goes: the write fails
$st = [pscustomobject]@{ version = 1; site = 'Review'; devices = @([pscustomobject]@{ serial = $SN; shortSerial = 'F12345678'; mac = 'c4-2f-90-00-00-50'; ip = '192.0.2.50'; model = 'DS-2CD2143G0-I'; status = 'submitted'; exportedAt = (Get-Date).AddHours(-1).ToString('s'); validUntil = (Get-Date).AddHours(47).ToString('s'); requestFile = $req; bootTime = '' }); exports = @() }
$script:theMatch = [pscustomobject]@{ device = $st.devices[0]; bytes = $unlockB; src = $drop; date = (Get-Date).AddMinutes(-5).ToString('s'); name = (Split-Path -Leaf $drop); mail = ''; how = 'serial' }
function Find-HikReplyMatches { param($Pending, $Msgs, $All) return [pscustomobject]@{ matched = @($script:theMatch); unmatched = @(); skipped = @() } }
$null = Receive-HikReplies $st (Join-Path $base 'state.json') $null $base $rep $inb 2>$null
$dv = $st.devices[0]
$same = $false; if (Test-Path -LiteralPath $dest -PathType Leaf) { $same = ([Convert]::ToBase64String([IO.File]::ReadAllBytes($dest)) -eq [Convert]::ToBase64String($unlockB)) }
# the "I got Hik's email" drop into an inbox this login cannot write (off Windows only)
$dr = $null; $dc = $null
if ($mode -eq 'blocked' -and $env:OS -ne 'Windows_NT') { $ro = Join-Path $base 'inbox-ro/hik'; New-Item -ItemType Directory -Force -Path $ro | Out-Null; & chmod 555 $ro; $src = Join-Path $base 'Hik-reply.xml'; [IO.File]::WriteAllBytes($src, $unlockB); $dr = Save-HikEmailDrop $ro $SN $src '' 2>$null; $dc = Save-HikEmailDrop $ro $SN '' 'Ab3dE5gH' 2>$null; & chmod 755 $ro }
'JSON:' + ([pscustomobject]@{ status = [string]$dv.status; replyFile = [string]$dv.replyFile; dest = $dest; same = $same; dropThere = [bool](Test-Path -LiteralPath $drop -PathType Leaf); said = @($script:said); drOk = $(if ($dr) { [bool]$dr.ok } else { $null }); drWhy = $(if ($dr) { [string]$dr.why } else { '' }); dcOk = $(if ($dc) { [bool]$dc.ok } else { $null }); dcWhy = $(if ($dc) { [string]$dc.why } else { '' }) } | ConvertTo-Json -Depth 4 -Compress)
'@)
foreach ($mode in @('blocked', 'ok')) {
  $base = Join-Path $tmp ('rcv-' + $mode); New-Item -ItemType Directory -Force -Path $base | Out-Null
  $co = & $exe -NoProfile -ExecutionPolicy Bypass -File $rcvChild $tk $base $mode $SN 2>&1 | Out-String
  $jl = @($co -split "`r?`n" | Where-Object { $_ -like 'JSON:*' }); $rr = $(if ($jl.Count) { $jl[0].Substring(5) | ConvertFrom-Json } else { $null })
  if (-not $rr) { Check $false ('receive child run (' + $mode + ') answered') $co.Trim(); continue }
  if ($mode -eq 'blocked') {
    Check ($rr.status -eq 'submitted' -and $rr.dropThere) 'sweep B/D: reply file could not be saved -> the device stays waiting and the dropped unlock file is NOT deleted (2.2.17: marked "replied", drop deleted)' ('status ' + $rr.status + ', drop there: ' + $rr.dropThere)
    Check (@($rr.said | Where-Object { $_ -match 'could NOT be saved' }).Count -eq 1) 'sweep B: ...and it says the reply could NOT be saved' ((@($rr.said)) -join ' | ')
    if ($env:OS -ne 'Windows_NT') {
      Check ($rr.drOk -eq $false -and $rr.drWhy -match 'could not be saved') 'sweep B: "I got Hik''s email": a dropped file that cannot be saved in the inbox -> not ok, "could not be saved" (2.2.17: ok with no file)' ('ok=' + $rr.drOk + ' why=' + $rr.drWhy)
      Check ($rr.dcOk -eq $false -and $rr.dcWhy -match 'could not be saved') 'sweep B: "I got Hik''s email": a pasted code that cannot be saved -> not ok (2.2.17: ok with no file)' ('ok=' + $rr.dcOk + ' why=' + $rr.dcWhy)
    } else { Deferred 'sweep B: drop into a read-only inbox (real NTFS permissions DEFERRED)' }
  } else {
    Check ($rr.status -eq 'replied' -and $rr.replyFile -eq $rr.dest -and $rr.same -and -not $rr.dropThere) 'control: a reply that saves is marked replied, saved byte for byte, and the drop is taken out of the inbox'
  }
}

Write-Host ''
Write-Host 'Save-HikEmailDrop ("I got Hik''s email"): control'
$unlockB = [Text.Encoding]::UTF8.GetBytes('<?xml version="1.0"?><ResetPassword><Code>Ab3dE5gH</Code></ResetPassword>')
$src = Join-Path $tmp 'Hik-reply.xml'; [IO.File]::WriteAllBytes($src, $unlockB)
$okIn = Join-Path $tmp 'inbox-ok/hik'
$d1 = Save-HikEmailDrop $okIn $SN $src ''; $d2 = Save-HikEmailDrop $okIn $SN '' 'Ab3d-E5gH'
Check ($d1.ok -and (Test-Path -LiteralPath $d1.path) -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($d1.path)) -eq [Convert]::ToBase64String($unlockB) -and $d2.ok -and ([IO.File]::ReadAllText($d2.path)) -eq 'Ab3dE5gH' -and -not @(Get-ChildItem -LiteralPath $okIn -Filter '*.tmp').Count) 'control: a file and a code drop into a good inbox are saved exactly, no temp file left'

# ==============================================================================================================================
Write-Host ''
Write-Host 'Updater: an unreadable "do not re-install" note holds the automatic update (class D)'
. (Join-Path $tk 'ToolkitRecover.ps1'); . (Join-Path $tk 'ToolkitCore.ps1')
# the start-up decision exactly as WireItToolkit.ps1 makes it ($true = installs this version on its own)
# (in its own PowerShell, like the window: ErrorActionPreference Continue, no try around the decision; 2.2.17's line was
#  "$u.manifest.version -ne (Get-TkSkipVersion $here)", 2.2.18's is "-not (Test-TkSkipUpdate $here $version)")
$updChild = Join-Path $tmp 'update-child.ps1'
[IO.File]::WriteAllText($updChild, @'
param($tk, $dir, $ver)
$ErrorActionPreference = 'Continue'
. (Join-Path $tk 'ToolkitRecover.ps1'); . (Join-Path $tk 'ToolkitCore.ps1')
if (Get-Command Test-TkSkipUpdate -ErrorAction SilentlyContinue) { $install = (-not (Test-TkSkipUpdate $dir $ver)) } else { $install = ([string]$ver -ne (Get-TkSkipVersion $dir)) }
'INSTALL:' + $install
'@)
$wouldInstall = { param($dir, $ver) $o = & $exe -NoProfile -ExecutionPolicy Bypass -File $updChild $tk $dir $ver 2>$null | Out-String; return ($o -match 'INSTALL:True') }
$ud = Join-Path $tmp 'upd'; New-Item -ItemType Directory -Force -Path $ud | Out-Null; $skp = Join-Path $ud 'skip-version.txt'
Check (& $wouldInstall $ud '2.2.19') 'control: no note -> the start-up installs 2.2.19 on its own'
[IO.File]::WriteAllText($skp, '2.2.19')
Check (-not (& $wouldInstall $ud '2.2.19')) 'control: note "2.2.19" (Go back from 2.2.19) -> 2.2.19 is NOT re-installed on its own'
Check (& $wouldInstall $ud '2.2.20') 'control: note "2.2.19" -> a newer 2.2.20 still installs'
if ($canLock) {
  Lock-Unreadable $skp
  $wi = & $wouldInstall $ud '2.2.19'
  Unlock-File $skp
  Check (-not $wi) 'sweep D: the note is there but this login cannot read it -> the start-up does NOT re-install the version the tech went back from (2.2.17: read as "no note", re-installed it)'
} else { Deferred 'sweep D: unreadable "do not re-install" note (this test login reads everything)' }
Write-Host ''
Write-Host 'Find cameras result (Test-TkFreshScan): a fresh list that cannot be read is not "a scan that found nothing" (class C)'
. (Join-Path $tk 'ToolkitRecover.ps1'); . (Join-Path $tk 'ToolkitCore.ps1')
$cr = Join-Path $tmp 'camreset'; New-Item -ItemType Directory -Force -Path (Join-Path $cr 'out') | Out-Null
$lj = Join-Path $cr 'out/latest.json'; $t0 = (Get-Date).ToUniversalTime().AddSeconds(-5)
[IO.File]::WriteAllText($lj, '{ "scannedAt": "2026-11-11T04:00:00", "devices": [ { "IP": "192.0.2.50", "MAC": "c4-2f')
Check (-not (Test-TkFreshScan $cr 0 $t0)) 'sweep C: Find cameras exit 0 but latest.json half written -> NOT a fresh scan (2.2.17: fresh, then read as no devices)'
[IO.File]::WriteAllText($lj, '{ "scannedAt": "2026-11-11T04:00:00", "devices": [ { "IP": "192.0.2.50", "MAC": "c4-2f-90-00-00-50", "Brand": "Hikvision" } ] }')
Check (Test-TkFreshScan $cr 0 $t0) 'control: a fresh readable latest.json from exit 0 is a fresh scan'
[IO.File]::WriteAllText($lj, '{ "scannedAt": "2026-11-11T04:00:00", "devices": [] }')
Check (Test-TkFreshScan $cr 0 $t0) 'control: a fresh readable list with no devices is still a scan that ran (it found nothing)'
Check (-not (Test-TkFreshScan $cr 1 $t0)) 'control: Find cameras exit 1 is never a fresh scan'
$wtSrc = [IO.File]::ReadAllText((Join-Path $tk 'WireItToolkit.ps1'))
Check ($wtSrc -match "-not \(Test-TkSkipUpdate \`$here") 'source check (not a behaviour run): WireItToolkit.ps1 decides the automatic update with Test-TkSkipUpdate'
Deferred 'real Windows: the start-up window with a locked skip-version.txt (WinForms, NTFS ACLs)'

# ==============================================================================================================================
Write-Host ''
Write-Host 'Check this site summary (New-TkSiteCheck): storage that could not be read is NOT CHECKED with its reason (class C, NvrHealth F6 consumer)'
$mkRec = { param($vendor, $problems) [pscustomobject]@{ ok = $false; vendor = $vendor; channels = @([pscustomobject]@{ ch = 1; ip = '192.0.2.21'; name = 'Front'; online = $true; scheduled = $true; recording_now = $true; mode = 'CMR' }); recording = 1; problems = @($problems); days_held = 12; target_days = 30; streams = $null } }
$mkH = { param($vendor, $rec) [pscustomobject]@{ vendor = $vendor; recording = $rec; clock = [pscustomobject]@{ ok = $true; problems = @() }; firmware = [pscustomobject]@{ ok = $true; problems = @(); devices = @() } } }
$c1 = New-TkSiteCheck -Health (& $mkH 'Hikvision' (& $mkRec 'Hikvision' @('storage NOT CHECKED (HTTP 500)'))) -Scan $null -Upnp $null
$rl = @($c1.lines | Where-Object { $_.t -match '^Recording' })
Check ($rl.Count -eq 1 -and $rl[0].k -eq 'warn' -and $rl[0].t -match 'NOT CHECKED' -and $rl[0].t -match 'storage' -and $rl[0].t -notmatch '(?i)no hard drive' -and -not $c1.ok -and @($c1.page.notChecked) -contains 'recording') 'sweep C: storage NOT CHECKED only -> amber "Recording: NOT CHECKED (storage NOT CHECKED ...)", page not OK (2.2.17 said only "could not read it")' (($c1.lines | ForEach-Object { $_.k + ':' + $_.t }) -join ' | ')
$dwCam = @()   # DW list read fine, nothing offline
$c2 = New-TkSiteCheck -Health (& $mkH 'DW' (& $mkRec 'DW' @('storage NOT CHECKED (both DW storage reads failed)'))) -Scan $null -Upnp $null -Dw $dwCam
$dwl = @($c2.lines | Where-Object { $_.t -match 'in DW' })
Check ($dwl.Count -eq 1 -and $dwl[0].t -notmatch 'NOT CHECKED' -and @($c2.lines | Where-Object { $_.t -match '^Recording: NOT CHECKED \(storage' }).Count -eq 1 -and -not $c2.ok) 'sweep C: DW storage NOT CHECKED does not make the DW camera list (which WAS read) "NOT CHECKED"; recording still NOT CHECKED, page not OK' (($c2.lines | ForEach-Object { $_.k + ':' + $_.t }) -join ' | ')
$c3 = New-TkSiteCheck -Health (& $mkH 'Hikvision' (& $mkRec 'Hikvision' @('not checked (login refused)'))) -Scan $null -Upnp $null
Check (@($c3.lines | Where-Object { $_.t -eq 'Recording: NOT CHECKED (login refused)' -and $_.k -eq 'warn' }).Count -eq 1 -and -not $c3.ok) 'control: login refused still reads "Recording: NOT CHECKED (login refused)"'
$c4 = New-TkSiteCheck -Health (& $mkH 'Hikvision' (& $mkRec 'Hikvision' @('No hard drive found. This recorder is NOT saving footage.'))) -Scan $null -Upnp $null
Check (@($c4.lines | Where-Object { $_.t -match '^Recording: No hard drive' -and $_.k -eq 'red' }).Count -eq 1 -and -not $c4.ok) 'control: a storage list that WAS read with no disk is still red "No hard drive"'

# ==============================================================================================================================
Write-Host ''
Write-Host 'Site Check (read-only): an NVR answer with no channel in it is NOT "0 cameras" (class C)'
$hikSLine = @'
$hikS = '<?xml version="1.0" encoding="UTF-8"?><InputProxyChannelStatusList version="2.0" xmlns="http://www.isapi.org/ver20/XMLSchema"><InputProxyChannelStatus version="2.0"><id>1</id><sourceInputPortDescriptor><proxyProtocol>HIKVISION</proxyProtocol><ipAddress>192.0.2.21</ipAddress><managePortNo>8000</managePortNo></sourceInputPortDescriptor><online>true</online><chanDetectResult>connect</chanDetectResult></InputProxyChannelStatus><InputProxyChannelStatus version="2.0"><id>5</id><sourceInputPortDescriptor><proxyProtocol>ONVIF</proxyProtocol><ipAddress>192.0.2.85</ipAddress></sourceInputPortDescriptor><online>false</online><chanDetectResult>netUnreachable</chanDetectResult></InputProxyChannelStatus></InputProxyChannelStatusList>'
'@
# (in its own PowerShell, so its functions do not mix with the Toolkit's)
$scChild = Join-Path $tmp 'sitecheck-child.ps1'
$childSrc = @'
param($scPs)
$ErrorActionPreference = 'Stop'
# Site Check's own start loads the Windows drawing library (not on this test box), so its check code is taken from the script
# ($SC_CODE, the here-string that holds every check function, exactly as the window's background run loads it)
$ast = [Management.Automation.Language.Parser]::ParseFile($scPs, [ref]$null, [ref]$null)
$asg = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$SC_CODE' }, $false))[0]
$SC_CODE = $asg.Right.Expression.Value
. ([scriptblock]::Create($SC_CODE))
HIKS_LINE
function Enable-WireItLanTls { return $true }
$out = @()
foreach ($case in @('empty', 'junk', 'good')) {
  $script:body = $(switch ($case) { 'empty' { '<?xml version="1.0"?><InputProxyChannelStatusList version="2.0"></InputProxyChannelStatusList>' } 'junk' { '<html>Error</html>' } 'good' { $hikS } })
  Set-Item -Path Function:\Invoke-ScHttpGet -Value ([scriptblock]::Create('param($url, $cred, [int]$timeoutMs = 6000) if ($url -match ''deviceInfo'') { return [pscustomobject]@{ Code = 200; Body = ''<DeviceInfo><model>DS-7608NI-K2/8P</model></DeviceInfo>'' } }; if ($url -match ''channels/status'') { return [pscustomobject]@{ Code = 200; Body = $script:body } }; return [pscustomobject]@{ Code = 200; Body = ''<InputProxyChannelList></InputProxyChannelList>'' }'))
  $nv = Get-ScNvrChannels '192.0.2.10' $null @(80)
  $R = [ordered]@{ nvr = '192.0.2.10'; nvrRead = [ordered]@{ brand = $nv.Brand; model = $nv.Model; ok = $nv.Ok; msg = $nv.Msg }; devices = @(); channels = @(); duplicates = @(); nets = @(); previous = $null }
  if ($nv.Ok) { $R.channels = @($nv.Channels) }
  $D = Get-ScDiagnosis $R
  $out += [pscustomobject]@{ case = $case; ok = [bool]$nv.Ok; n = @($nv.Channels).Count; msg = [string]$nv.Msg; findings = @($D.Findings | ForEach-Object { [pscustomobject]@{ level = [string]$_.Level; text = [string]$_.Text } }) }
}
'JSON:' + ($out | ConvertTo-Json -Depth 5 -Compress)
'@
[IO.File]::WriteAllText($scChild, $childSrc.Replace('HIKS_LINE', $hikSLine))
$co = & $exe -NoProfile -ExecutionPolicy Bypass -File $scChild $scPs 2>&1 | Out-String
$jl = @($co -split "`r?`n" | Where-Object { $_ -like 'JSON:*' })
$sc = $(if ($jl.Count) { @(($jl[0].Substring(5)) | ConvertFrom-Json) } else { @() })
Check ($sc.Count -eq 3) 'Site Check child run answered for the 3 cases' $co.Trim()
foreach ($x in $sc) {
  if ($x.case -eq 'good') { Check ($x.ok -and $x.n -ge 1) 'control: a real channel list reads as OK with its channels' }
  else {
    Check (-not $x.ok -and $x.msg -match 'NOT CHECKED') ('sweep C: channel status answer "' + $x.case + '" (HTTP 200, no channel in it) -> not OK, "channel status NOT CHECKED" (2.2.17: OK with 0 channels)') ('ok=' + $x.ok + ' msg=' + $x.msg)
    Check (@($x.findings | Where-Object { $_.level -eq 'warn' -and $_.text -match 'NOT CHECKED' }).Count -ge 1 -and -not @($x.findings | Where-Object { $_.level -eq 'ok' }).Count) ('sweep C: ...the "' + $x.case + '" diagnosis carries an amber NOT CHECKED line, not "No network problems found"') (($x.findings | ForEach-Object { $_.level + ':' + $_.text }) -join ' | ')
  }
}
$cmdP = Join-Path $repo 'sitecheck/WireIt-SiteCheck.cmd'; $cc = [IO.File]::ReadAllText($cmdP); $ci = $cc.IndexOf('##' + 'PSSTART')
Check ($ci -gt 0 -and $cc.Substring($ci + 11).Trim() -eq ([IO.File]::ReadAllText($scPs)).Trim()) 'control: the Site Check launcher (.cmd) carries exactly the same script'
Deferred 'real NVRs: Site Check against a real Hikvision / Dahua recorder that answers 200 with an empty list'
Deferred 'real devices: the SADP reset flow (export, import) on a real Hikvision camera with a damaged state.json'
}
finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
Write-Host ''
Write-Host ('Test-Fix2218Sweep: ' + $script:pass + ' passed, ' + $script:fail + ' failed, ' + $script:deferred + ' deferred')
if ($script:fail) { exit 1 }
exit 0
