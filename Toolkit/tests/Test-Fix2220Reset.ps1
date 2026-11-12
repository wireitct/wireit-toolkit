<# Test-Fix2220Reset.ps1 - tests for WireIt Toolkit 2.2.20 (Nov 11 2026): the "reset" part of the fix round after Codex's NO-GO review of
   2.2.19 (findings R14 and R18, plus their twins in the Hikvision reset flow, NetCheck and SiteCheck):
   - R14 (class A/F): the reboot-retry, the boot it is for and the "exporting" state are RESERVED (saved + read back) before the camera is
     asked for a request file; a result that is lost afterwards never gives the retry back and the same boot never passes again; an
     unfinished export is settled (its file registered) instead of being repeated.  Codex: reproduce-safety.ps1 "reset-retry-reservation".
   - R13 twin (class F): an import of Hikvision's file that was SENT but got no answer is NOT CONFIRMED: no second layout / legacy form is
     sent after it, the record stays "importing" (never imported again on its own) and the site password is checked.
   - R12 twin (class C): a login check counts only on a real $true (2.2.19 took [bool] of any answer: "noanswer" read as logged in).
   - class D: the request file sent to Hikvision's page and the unlock file imported are the exact bytes the record approved.
   - class A: registering request files reports them only once the record is saved; the reset record is read back from its FINAL file.
   - R18 (class C): NetCheck: HTTP 200 with an ISAPI error document / a login page is NOT CHECKED, never "nobody", no events or "auth ok".
     Codex: reproduce-diagnostics.ps1 "stream-error-document".
   - SiteCheck (class C): an ARP table that could not be read is NOT CHECKED and never the "No network problems found" all-clear.
   Real production functions are run; stand-ins only for SADP/HTTP/Windows commands and selected persistence failures. A check that only
   reads source text says "(code shape)". PS 5.1 or pwsh 7. FIX2220RESET_REPO = run against another checkout (old-code proof: on 2.2.19 the
   finding checks FAIL, the controls pass). #>
$ErrorActionPreference = 'Stop'
$repo = $(if ($env:FIX2220RESET_REPO) { $env:FIX2220RESET_REPO } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) })
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fix2220reset-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$script:pass = 0; $script:fail = 0; $script:deferred = 0
function Check([bool]$ok, [string]$name, [string]$more = '') {
  if ($ok) { $script:pass++; Write-Host ('PASS ' + $name) } else { $script:fail++; Write-Host ('FAIL ' + $name); if ($more) { Write-Host ('     ' + $more) } }
}
function Deferred([string]$name) { $script:deferred++; Write-Host ('DEFERRED ' + $name) }
function Run-Safe([string]$name, [scriptblock]$sb) { try { & $sb } catch { Check $false ($name + ' (the check itself stopped)') ([string]$_.Exception.Message + ' @' + [string]$_.InvocationInfo.ScriptLineNumber) } }
function Read-Src([string]$rel) { return [IO.File]::ReadAllText((Join-Path $repo ($rel -replace '/', [string][IO.Path]::DirectorySeparatorChar))) }
function Import-FnFromAst($ast, [string[]]$names) {
  $missing = @()
  foreach ($n in $names) {
    $f = $ast.Find({ param($x) $x -is [Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $n }, $true)
    if ($f) { . ([scriptblock]::Create($f.Extent.Text.Replace('function ' + $n, 'function global:' + $n))) } else { $missing += $n }
  }
  return $missing
}
foreach ($f in @('Toolkit/HikResetFlow.ps1', 'Toolkit/HikSadp.ps1', 'Toolkit/HikReset.ps1', 'NetCheck/NetCheck.ps1', 'sitecheck/SiteCheck.ps1')) {
  $e = $null; [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $repo $f), [ref]$null, [ref]$e); Check ($e.Count -eq 0) ('parses: ' + $f) ($e | Out-String)
}

# ------------------------------------------------------------------------------------------------------------------------------
. (Join-Path $repo 'Toolkit/HikResetFlow.ps1')
$script:said = New-Object System.Collections.Generic.List[string]
$script:HkSay = { param($t, $c) [void]$script:said.Add([string]$t) }
$script:HkSubnetCheckOff = $true
function Start-Sleep { param([int]$Seconds, [int]$Milliseconds) }   # stand-in: the flow waits for devices to come back
$orig = @{}; foreach ($n in 'Request-HikResetExport', 'Save-HikResetFile', 'Save-HikStateOk', 'Import-HikUnlock', 'Find-HikSadp', 'Invoke-SadpExchange', 'Invoke-SadpKeyExchange', 'Protect-SadpPassword', 'Save-HikState') { $c = Get-Command $n -CommandType Function -ErrorAction SilentlyContinue; if ($c) { $orig[$n] = $c.ScriptBlock } }
function Restore-Orig { foreach ($k in $orig.Keys) { Set-Item -Path ('function:script:' + $k) -Value $orig[$k] } }
$safeCode = [Convert]::ToBase64String([byte[]](@(3, 0, 0, 0) + @(1..24)))
function New-Dev([string]$boot = 'NEW-BOOT') { [pscustomobject]@{ serial = 'DS-2CD2143G0-I20200101AAWRD12345678'; mac = 'c4-2f-90-00-00-21'; model = 'DS-2CD2143G0-I'; ip = '10.0.0.21'; shortSerial = 'D12345678'; kind = 'camera'; activated = $true; salt = ''; encrypt = $false; bootTime = $boot } }
function New-RefusedState([string]$sp, [int]$retries = 0, [string]$refusedBoot = 'OLD-BOOT') {
  $dv = New-Dev
  $d = [pscustomobject]@{ serial = $dv.serial; shortSerial = $dv.shortSerial; mac = $dv.mac; model = $dv.model; ip = $dv.ip; kind = 'camera'; status = 'refused'; bootTime = $refusedBoot; rebootRetries = $retries; refusedChecksOk = $true; requestFile = ''; exportedAt = (Get-Date).AddHours(-3).ToString('s'); validUntil = (Get-Date).AddHours(45).ToString('s'); exportId = 'aaaaaaaaaaaa'; note = '' }
  $s = [pscustomobject]@{ version = 1; devices = @($d); exports = @() }
  Save-HikState $sp $s
}

Write-Host ''
Write-Host 'R14 (HikResetFlow.ps1 Export-HikRequests, class A/F): the reboot-retry is reserved before the camera is asked'
Run-Safe 'R14 repro' {
  Restore-Orig
  $dir = Join-Path $tmp 'r14a'; New-Item -ItemType Directory -Force -Path $dir | Out-Null; $sp = Join-Path $dir 'state.json'
  New-RefusedState $sp
  $script:exportWrites = 0; $script:saveCalls = 0; $script:diskAtExport = $null
  function Request-HikResetExport { param($dev) $script:exportWrites++; $script:diskAtExport = [IO.File]::ReadAllText($sp) | ConvertFrom-Json; [pscustomobject]@{ ok = $true; request = [pscustomobject]@{ value = $safeCode } } }
  function Save-HikResetFile { param($dev, $e, $dir) $p = Join-Path $tmp 'r14a-request.xml'; [IO.File]::WriteAllText($p, 'CODE'); $p }
  # Codex's stand-in: every 2nd save fails (the save after the export)
  function Save-HikStateOk { param($Path, $State) $script:saveCalls++; if ($script:saveCalls % 2 -eq 0) { $script:HkStateSaveWhy = 'simulated disk failure after export'; return $false }; Save-HikState $Path $State; return $script:HkStateSaved }
  $dev = New-Dev
  1..2 | ForEach-Object { $s = Read-HikState $sp; [void](Export-HikRequests @($dev) (Join-Path $dir 'requests') $s $sp) }
  $back = Read-HikState $sp
  "REPRO reset-retry-reservation exports=$script:exportWrites savedRetries=$($back.devices[0].rebootRetries) savedStatus=$($back.devices[0].status)" | Write-Host
  Check ($script:exportWrites -eq 1) 'reproduction (Codex R14 reset-retry-reservation): a lost post-export save does not let the same boot export again (2.2.19: exports=2)' ('exports=' + $script:exportWrites)
  Check ([int]$back.devices[0].rebootRetries -eq 1) 'R14: the reboot-retry stays counted on disk after the post-export save failed (2.2.19: savedRetries=0)' ('savedRetries=' + $back.devices[0].rebootRetries)
  Check ([string]$back.devices[0].status -ne 'refused') 'R14: the record no longer says plain "refused" (it says the export is unfinished)' ('savedStatus=' + $back.devices[0].status)
  $dk = $script:diskAtExport; $d0 = $(if ($dk) { @($dk.devices)[0] } else { $null })
  Check ($d0 -and [int]$d0.rebootRetries -eq 1 -and [string]$d0.status -eq 'exporting' -and $d0.PSObject.Properties['retryBootTime'] -and [string]$d0.retryBootTime -eq 'NEW-BOOT') 'R14: retry count, boot and "exporting" are ON DISK at the moment the camera is asked (reserve before act)' $(if ($d0) { 'disk: status=' + $d0.status + ' retries=' + $d0.rebootRetries } else { 'no record read' })
  Check (@($script:said | Where-Object { $_ -match 'NOT CONFIRMED' }).Count -ge 1) 'R14: the second run says NOT CONFIRMED (asked, result not recorded) instead of exporting'
}
Run-Safe 'R14 reserve fails' {
  Restore-Orig
  $dir = Join-Path $tmp 'r14b'; New-Item -ItemType Directory -Force -Path $dir | Out-Null; $sp = Join-Path $dir 'state.json'
  New-RefusedState $sp
  $script:exportWrites = 0
  function Request-HikResetExport { param($dev) $script:exportWrites++; [pscustomobject]@{ ok = $true; request = [pscustomobject]@{ value = $safeCode } } }
  function Save-HikStateOk { param($Path, $State) $script:HkStateSaveWhy = 'disk full'; return $false }
  $s = Read-HikState $sp; [void](Export-HikRequests @(New-Dev) (Join-Path $dir 'requests') $s $sp)
  $d = @($s.devices)[0]
  Check ($script:exportWrites -eq 0) 'R14 control: the reservation cannot be saved -> the camera is NOT asked'
  Check ([string]$d.status -eq 'refused' -and [int]$d.rebootRetries -eq 0) 'R14 control (passes on 2.2.19 too; renamed in 2.2.21 per Codex note): a reservation that did not save is taken back in memory. Proves only the in-memory undo; the R14 proof is the reserve-before-act check above' ('status=' + $d.status + ' retries=' + $d.rebootRetries)
}
Run-Safe 'R14 settle with file' {
  Restore-Orig
  $dir = Join-Path $tmp 'r14c'; New-Item -ItemType Directory -Force -Path $dir | Out-Null; $sp = Join-Path $dir 'state.json'
  New-RefusedState $sp
  $script:exportWrites = 0; $script:saveCalls = 0
  function Request-HikResetExport { param($dev) $script:exportWrites++; [pscustomobject]@{ ok = $true; request = [pscustomobject]@{ value = $safeCode } } }
  function Save-HikStateOk { param($Path, $State) $script:saveCalls++; if ($script:saveCalls -eq 2) { $script:HkStateSaveWhy = 'simulated'; return $false }; Save-HikState $Path $State; return $script:HkStateSaved }
  $reqDir = Join-Path $dir 'requests'
  1..2 | ForEach-Object { $s = Read-HikState $sp; [void](Export-HikRequests @(New-Dev) $reqDir $s $sp) }
  $back = Read-HikState $sp; $d = @($back.devices)[0]
  Check ($script:exportWrites -eq 1) 'R14: an unfinished export whose request file is there is NOT exported again'
  Check ($script:exportWrites -eq 1 -and [string]$d.status -eq 'exported' -and [string]$d.requestFile -and (Test-Path -LiteralPath ([string]$d.requestFile)) -and [int]$d.rebootRetries -eq 1) 'R14: the existing file is REUSED without a second export: one export only AND it is registered as the one in force (status exported, retry still counted) (2.2.21: joint check, Codex note: the status part alone passed on 2.2.19)' ('status=' + $d.status + ' file=' + $d.requestFile)
}
Run-Safe 'R14 no answer keeps the retry' {
  Restore-Orig
  $dir = Join-Path $tmp 'r14d'; New-Item -ItemType Directory -Force -Path $dir | Out-Null; $sp = Join-Path $dir 'state.json'
  New-RefusedState $sp
  $script:exportWrites = 0
  function Request-HikResetExport { param($dev) $script:exportWrites++; [pscustomobject]@{ ok = $false; request = $null; error = 'no answer (stand-in)' } }
  1..2 | ForEach-Object { $s = Read-HikState $sp; [void](Export-HikRequests @(New-Dev) (Join-Path $dir 'requests') $s $sp) }
  $back = Read-HikState $sp; $d = @($back.devices)[0]
  Check ($script:exportWrites -eq 1) 'R14 twin (class F): an export that got no answer does not give the retry back - the same boot is not asked again' ('exports=' + $script:exportWrites)
  Check ([int]$d.rebootRetries -eq 1 -and [string]$d.status -eq 'refused') 'R14 twin: after the unanswered export the record says refused with retry 1 used' ('status=' + $d.status + ' retries=' + $d.rebootRetries)
  # control: after a real reboot (new boot time) the next retry is allowed and counted as 2
  $s = Read-HikState $sp; [void](Export-HikRequests @(New-Dev 'BOOT-3') (Join-Path $dir 'requests') $s $sp)
  $back = Read-HikState $sp; $d = @($back.devices)[0]
  Check ($script:exportWrites -eq 2 -and [int]$d.rebootRetries -eq 2) 'R14 twin: after a reboot the next retry goes ahead and is counted as retry 2 (the unanswered one stayed counted)' ('exports=' + $script:exportWrites + ' retries=' + $d.rebootRetries)
  $s = Read-HikState $sp; [void](Export-HikRequests @(New-Dev 'BOOT-4') (Join-Path $dir 'requests') $s $sp)
  Check ($script:exportWrites -eq 2) 'R14 twin: with both reboot-retries counted, no third export (Hik support)'
}
Run-Safe 'R14 rebooted unfinished' {
  Restore-Orig
  $dir = Join-Path $tmp 'r14e'; New-Item -ItemType Directory -Force -Path $dir | Out-Null; $sp = Join-Path $dir 'state.json'
  New-RefusedState $sp
  $script:exportWrites = 0; $script:saveCalls = 0
  function Request-HikResetExport { param($dev) $script:exportWrites++; [pscustomobject]@{ ok = $true; request = [pscustomobject]@{ value = $safeCode } } }
  function Save-HikResetFile { param($dev, $e, $dir) $p = Join-Path $tmp 'r14e-elsewhere.xml'; [IO.File]::WriteAllText($p, 'CODE'); $p }
  function Save-HikStateOk { param($Path, $State) $script:saveCalls++; if ($script:saveCalls -eq 2) { return $false }; Save-HikState $Path $State; return $script:HkStateSaved }
  $s = Read-HikState $sp; [void](Export-HikRequests @(New-Dev) (Join-Path $dir 'requests') $s $sp)
  $s = Read-HikState $sp; [void](Export-HikRequests @(New-Dev 'BOOT-2') (Join-Path $dir 'requests') $s $sp)
  $back = Read-HikState $sp; $d = @($back.devices)[0]
  Check ($script:exportWrites -eq 2 -and [int]$d.rebootRetries -eq 2) 'R14: after a reboot, an unfinished export counts as used: the new export is retry 2, not retry 1 again' ('exports=' + $script:exportWrites + ' retries=' + $d.rebootRetries)
}
Run-Safe 'R14 first export reservation' {
  Restore-Orig
  $dir = Join-Path $tmp 'r14f'; New-Item -ItemType Directory -Force -Path $dir | Out-Null; $sp = Join-Path $dir 'state.json'
  Save-HikState $sp ([pscustomobject]@{ version = 1; devices = @(); exports = @() })
  $script:diskAtExport = $null
  function Request-HikResetExport { param($dev) $script:diskAtExport = [IO.File]::ReadAllText($sp) | ConvertFrom-Json; [pscustomobject]@{ ok = $true; request = [pscustomobject]@{ value = $safeCode } } }
  $s = Read-HikState $sp; $m = @(Export-HikRequests @(New-Dev) (Join-Path $dir 'requests') $s $sp)
  $dk = @($script:diskAtExport.devices)
  Check ($dk.Count -eq 1 -and [string]$dk[0].status -eq 'exporting' -and [string]$dk[0].exportFile -like '*.xml') 'R14 twin: a first export (no record yet) is also written down with the file it will make, before the camera is asked'
  $back = Read-HikState $sp
  Check ($m.Count -eq 1 -and [string]@($back.devices)[0].status -eq 'exported') 'control: a normal first export ends "exported" with its file'
}
Run-Safe 'R14 Retry entry' {
  $hr = Read-Src 'Toolkit/HikReset.ps1'
  Check ($hr -match "status -eq 'exporting'") 'R14 (code shape): HikReset -Mode Retry also takes a device whose export was left unfinished (it is settled, not "nothing to retry")'
}

Write-Host ''
Write-Host 'R13 twin (HikSadp.ps1 Import-HikUnlockReset / Import-HikUnlock, class F): a reset that was sent but not answered is NOT CONFIRMED'
Run-Safe 'sadp import' {
  Restore-Orig
  $dev = New-Dev; $unlock = [pscustomobject]@{ kind = 'file'; code = 'AB12CD34'; file = '' }
  function Invoke-SadpKeyExchange { param($dev, $Seconds) [pscustomobject]@{ ok = $true; key = 'k' } }
  function Protect-SadpPassword { param($Password, $SessionKeyText, $Layout) 'enc' }
  $script:resetSends = 0; $script:answers = @('', '')
  function Invoke-SadpExchange { param($Probes, $Seconds, $ResendAt, $Socks, $Stop) $script:resetSends++; $a = $script:answers[$script:resetSends - 1]; if ($a) { return @([pscustomobject]@{ text = ('<ProbeMatch><Types>reset</Types><MAC>c4-2f-90-00-00-21</MAC><Result>' + $a + '</Result></ProbeMatch>') }) }; return @() }
  $r = Import-HikUnlockReset $dev $unlock 'Site-Pass-1234' 1
  Check ($script:resetSends -eq 1) 'R13 twin: the reset got NO answer -> the second layout is NOT sent (2.2.19 sent it, and its "failed" was recorded as a refusal)' ('resets sent=' + $script:resetSends)
  Check (-not $r.ok -and -not [string]$r.result -and $r.PSObject.Properties['sent'] -and $r.sent) 'R13 twin: the answer says sent, no result (NOT CONFIRMED), never a refusal' ('result=' + $r.result)
  $script:resetSends = 0; $script:answers = @('failed', 'success')
  $r = Import-HikUnlockReset $dev $unlock 'Site-Pass-1234' 1
  Check ($script:resetSends -eq 2 -and $r.ok) 'control: a reset ANSWERED "failed" still tries the second layout (seen on the wire: failed, then success)'
  # legacy forms allowed: a reset with no answer does not fall through to the old plain-password forms
  $script:SadpAllowPlainPassword = $true
  try { $script:resetSends = 0; $script:answers = @('', '', '', ''); $r = Import-HikUnlock $dev $unlock 'Site-Pass-1234' 1 } finally { $script:SadpAllowPlainPassword = $false }
  Check ($script:resetSends -eq 1) 'R13 twin: no answer to the reset -> the old forms are NOT sent after it' ('sends=' + $script:resetSends)
  $script:SadpAllowPlainPassword = $true
  try { $script:resetSends = 0; $script:answers = @('', '', ''); $r = Import-HikUnlock $dev ([pscustomobject]@{ kind = 'file'; code = 'LONGERTHAN8CHARSCODE'; file = '' }) 'Site-Pass-1234' 1 } finally { $script:SadpAllowPlainPassword = $false }
  Check (-not $r.ok -and -not [string]$r.result -and $r.sent -and [string]$r.error -match 'NOT CONFIRMED') 'R13 twin: old forms that all got no answer are NOT CONFIRMED (sent, no result), never a refusal' ('sends=' + $script:resetSends + ' error=' + $r.error)
}

Write-Host ''
Write-Host 'R12/R13 twins (HikResetFlow.ps1 Import-HikReplies / Invoke-HikResetStage, class C/F): import outcome and the login check'
function New-RepliedState([string]$dir) {
  $sp = Join-Path $dir 'state.json'; $dv = New-Dev 'BOOT-1'
  $rf = Join-Path $dir 'reply.xml'; [IO.File]::WriteAllText($rf, '<Code>AB12CD34</Code>')
  $d = [pscustomobject]@{ serial = $dv.serial; shortSerial = $dv.shortSerial; mac = $dv.mac; model = $dv.model; ip = $dv.ip; kind = 'camera'; status = 'replied'; bootTime = 'BOOT-1'; requestFile = ''; exportedAt = (Get-Date).AddHours(-1).ToString('s'); validUntil = (Get-Date).AddHours(40).ToString('s'); exportId = 'aaaaaaaaaaaa'; replyFile = $rf; replyForExport = 'aaaaaaaaaaaa'; replyAt = (Get-Date).ToString('s'); note = '' }
  Save-HikState $sp ([pscustomobject]@{ version = 1; devices = @($d); exports = @() })
  return $sp
}
Run-Safe 'import ambiguous' {
  Restore-Orig
  $dir = Join-Path $tmp 'imp1'; New-Item -ItemType Directory -Force -Path $dir | Out-Null; $sp = New-RepliedState $dir
  function Find-HikSadp { param($s) @(New-Dev 'BOOT-1') }
  $script:imports = 0; $script:logins = 0
  function Import-HikUnlock { param($dev, $u, $pw) $script:imports++; [pscustomobject]@{ ok = $false; result = ''; error = 'the device did not answer the reset'; sent = $true } }
  $vf = { param($ip, $p) $script:logins++; $false }
  1..2 | ForEach-Object { $s = Read-HikState $sp; [void](Import-HikReplies $s $sp 'Site-Pass-1234' $vf) }
  $d = @((Read-HikState $sp).devices)[0]
  Check ($script:imports -eq 1) 'R13 twin: an import sent with no answer is NOT sent again on the next run (2.2.19: back to "replied", sent again)' ('imports=' + $script:imports)
  Check ([string]$d.status -eq 'importing') 'R13 twin: the record stays "importing" (NOT CONFIRMED), never "replied"' ('status=' + $d.status)
  Check ($script:logins -ge 1) 'R13 twin: the site password is checked after the unanswered import (it may have worked)'
  # it did work: the login check makes it verified
  $dir = Join-Path $tmp 'imp2'; New-Item -ItemType Directory -Force -Path $dir | Out-Null; $sp = New-RepliedState $dir
  $s = Read-HikState $sp; $done = @(Import-HikReplies $s $sp 'Site-Pass-1234' { param($ip, $p) $true })
  Check ($done.Count -eq 1 -and [string]@((Read-HikState $sp).devices)[0].status -eq 'verified') 'R13 twin: an unanswered import whose site password then logs in is verified'
  # nothing sent (no key exchange): the reply stays usable, as before
  $dir = Join-Path $tmp 'imp3'; New-Item -ItemType Directory -Force -Path $dir | Out-Null; $sp = New-RepliedState $dir
  function Import-HikUnlock { param($dev, $u, $pw) [pscustomobject]@{ ok = $false; result = ''; error = 'no key exchange answer (nothing was sent)'; sent = $false } }
  $s = Read-HikState $sp; [void](Import-HikReplies $s $sp 'Site-Pass-1234' { param($ip, $p) $false })
  Check ([string]@((Read-HikState $sp).devices)[0].status -eq 'replied') 'control: an import that never reached the device leaves the reply usable ("replied")'
}
Run-Safe 'strict login' {
  Restore-Orig
  $dir = Join-Path $tmp 'imp4'; New-Item -ItemType Directory -Force -Path $dir | Out-Null; $sp = New-RepliedState $dir
  function Find-HikSadp { param($s) @(New-Dev 'BOOT-1') }
  function Import-HikUnlock { param($dev, $u, $pw) [pscustomobject]@{ ok = $true; result = 'success'; error = ''; sent = $true } }
  $script:third = $null
  $s = Read-HikState $sp; $done = @(Import-HikReplies $s $sp 'Site-Pass-1234' { param($ip, $p, $dv) $script:third = $dv; 'noanswer' })
  $d = @((Read-HikState $sp).devices)[0]
  Check ($done.Count -eq 0 -and [string]$d.status -ne 'verified') 'R12 twin (class C): a login checker that answers "noanswer" is NOT a working password (2.2.19: [bool]"noanswer" = verified)' ('status=' + $d.status)
  Check ($script:third -and [string]$script:third.serial -eq (New-Dev).serial) 'R12 twin: the login checker is given the saved device record, so it can match the device''s own identity'
  $dir = Join-Path $tmp 'imp5'; New-Item -ItemType Directory -Force -Path $dir | Out-Null; $sp = New-RepliedState $dir
  $s = Read-HikState $sp; $done = @(Import-HikReplies $s $sp 'Site-Pass-1234' { param($ip, $p) $true })
  Check ($done.Count -eq 1) 'control: a checker that answers $true verifies the reset'
  # the stage: an "importing" record and a checker that answers "locked" is NOT fixed
  $dir = Join-Path $tmp 'stage1'; New-Item -ItemType Directory -Force -Path $dir | Out-Null; $sp = New-RepliedState $dir
  $st = Read-HikState $sp; @($st.devices)[0].status = 'importing'; Save-HikState $sp $st
  function Find-HikSadp { param($s) @(New-Dev 'BOOT-1') }
  function Request-HikResetExport { param($dev) [pscustomobject]@{ ok = $false; error = 'stand-in: not asked' } }
  $res = Invoke-HikResetStage -Targets @([pscustomobject]@{ mac = (New-Dev).mac }) -SitePassword 'Site-Pass-1234' -StateDir $dir -Config ([pscustomobject]@{ form = $null; replyDir = '' }) -VerifyLogin { param($ip, $p) 'locked' } -WaitMinutes 0
  Check (@($res.fixed).Count -eq 0) 'R12 twin: Fix this site''s reset stage does not count a device fixed on a checker answer of "locked"' ('fixed=' + (@($res.fixed) -join ','))
}

Write-Host ''
Write-Host 'class D (HikResetFlow.ps1 Submit-HikRequests / Import-HikReplies): the file approved is the file used'
Run-Safe 'submit file' {
  Restore-Orig
  $dir = Join-Path $tmp 'sub1'; New-Item -ItemType Directory -Force -Path $dir | Out-Null; $sp = Join-Path $dir 'state.json'
  $s = [pscustomobject]@{ version = 1; devices = @(); exports = @() }
  $rq = Join-Path $dir 'req.xml'; [IO.File]::WriteAllText($rq, $safeCode + (New-Dev).serial)
  [void](Add-HikStateDevice $s (New-Dev) $rq 'BOOT-1'); Save-HikState $sp $s
  function Find-HikBrowser { 'chrome' }; function Start-HikBrowserSession { param($u) [pscustomobject]@{ id = 1 } }; function Stop-HikBrowserSession { param($x) }
  function Wait-PortalForm { param($x, $y) $true }; function Test-PortalFilled { param($r, $d) @() }; function Wait-PortalSubmitted { param($a, $b, $c, $d) 'submitted' }; function Restore-PortalFields { param($a, $b, $c) @() }
  $script:filled = 0; function Fill-HikPortalForm { param($s, $form, $dev, $file) $script:filled++; [pscustomobject]@{} }
  [IO.File]::WriteAllText($rq, ([Convert]::ToBase64String([byte[]](@(3, 0, 0, 0) + @(9..33)))) + (New-Dev).serial)   # another export replaced the file
  $s = Read-HikState $sp; $sent = @(Submit-HikRequests $s $sp ([pscustomobject]@{ firstName = 'a'; lastName = 'b'; company = 'c'; email = 'd' }) 5)
  Check ($script:filled -eq 0 -and $sent.Count -eq 0) 'class D: a request file replaced after it was made (export id differs) is NOT sent to Hikvision' ('filled=' + $script:filled)
  $dir = Join-Path $tmp 'sub2'; New-Item -ItemType Directory -Force -Path $dir | Out-Null; $sp = Join-Path $dir 'state.json'
  $s = [pscustomobject]@{ version = 1; devices = @(); exports = @() }
  $rq = Join-Path $dir 'req.xml'; [IO.File]::WriteAllText($rq, $safeCode + (New-Dev).serial)
  [void](Add-HikStateDevice $s (New-Dev) $rq 'BOOT-1'); Save-HikState $sp $s
  $script:filled = 0
  $s = Read-HikState $sp; $sent = @(Submit-HikRequests $s $sp ([pscustomobject]@{ firstName = 'a'; lastName = 'b'; company = 'c'; email = 'd' }) 5)
  Check ($script:filled -eq 1 -and $sent.Count -eq 1) 'control: the request file as made is sen'
}
Run-Safe 'import bytes' {
  Restore-Orig
  $dir = Join-Path $tmp 'rep1'; New-Item -ItemType Directory -Force -Path $dir | Out-Null; $sp = Join-Path $dir 'state.json'
  $rd = Join-Path $dir 'replies'; New-Item -ItemType Directory -Force -Path $rd | Out-Null
  $s = [pscustomobject]@{ version = 1; devices = @(); exports = @() }
  $rq = Join-Path $dir 'req.xml'; [IO.File]::WriteAllText($rq, $safeCode + (New-Dev 'BOOT-1').serial)
  $d = Add-HikStateDevice $s (New-Dev 'BOOT-1') $rq 'BOOT-1' ((Get-Date).AddMinutes(-30)); $d.status = 'submitted'; Save-HikState $sp $s
  $drop = Join-Path $dir 'in'; New-Item -ItemType Directory -Force -Path $drop | Out-Null
  $df = Join-Path $drop ('reply-' + (New-Dev).shortSerial + '.xml'); [IO.File]::WriteAllText($df, '<Code>AB12CD34</Code>' + (New-Dev).serial)
  $s = Read-HikState $sp; $r = Receive-HikReplies $s $sp $null '' $rd $drop
  $d = @((Read-HikState $sp).devices)[0]
  if ([string]$d.status -ne 'replied') { Deferred ('class D import-bytes: the stand-in reply was not matched here (status ' + $d.status + '), the check did not run'); return }
  Check ($d.PSObject.Properties['replySha'] -and [string]$d.replySha) 'class D: the matched reply''s SHA-256 is written in the record'
  [IO.File]::WriteAllText([string]$d.replyFile, '<Code>ZZ99ZZ99</Code>')   # the saved reply replaced on disk before the import
  function Find-HikSadp { param($s) @(New-Dev 'BOOT-1') }
  $script:imports = 0; function Import-HikUnlock { param($dev, $u, $pw) $script:imports++; [pscustomobject]@{ ok = $true; result = 'success'; sent = $true } }
  $s = Read-HikState $sp; [void](Import-HikReplies $s $sp 'Site-Pass-1234' { param($ip, $p) $true })
  Check ($script:imports -eq 0) 'class D: an unlock file changed on disk after it was matched is NOT imported' ('imports=' + $script:imports)
}

Write-Host ''
Write-Host 'class A (HikResetFlow.ps1 Register-HikRequestFiles / Save-HikState; HikSadp.ps1 Save-HikResetFile)'
Run-Safe 'register' {
  Restore-Orig
  $dir = Join-Path $tmp 'reg1'; New-Item -ItemType Directory -Force -Path $dir | Out-Null; $sp = Join-Path $dir 'state.json'
  $rd = Join-Path $dir 'files'; New-Item -ItemType Directory -Force -Path $rd | Out-Null; [IO.File]::WriteAllText((Join-Path $rd 'x.xml'), $safeCode + (New-Dev).serial)
  $s = [pscustomobject]@{ version = 1; devices = @(); exports = @() }
  function Save-HikStateOk { param($Path, $State) $script:HkStateSaveWhy = 'disk full'; return $false }
  function Save-HikState { param($Path, $State) $script:HkStateSaved = $false; $script:HkStateSaveWhy = 'disk full' }
  $added = @(Register-HikRequestFiles $s $rd @(New-Dev) $sp)
  Check ($added.Count -eq 0) 'class A: request files are NOT reported registered when the record could not be saved (2.2.19 returned them)' ('returned=' + $added.Count)
}
Run-Safe 'register control' {
  $dir = Join-Path $tmp 'reg2'; New-Item -ItemType Directory -Force -Path $dir | Out-Null; $sp = Join-Path $dir 'state.json'
  $rd = Join-Path $dir 'files'; New-Item -ItemType Directory -Force -Path $rd | Out-Null; [IO.File]::WriteAllText((Join-Path $rd 'x.xml'), $safeCode + (New-Dev).serial)
  $s = [pscustomobject]@{ version = 1; devices = @(); exports = @() }
  $added = @(Register-HikRequestFiles $s $rd @(New-Dev) $sp)
  Check ($added.Count -eq 1 -and (Test-Path -LiteralPath $sp)) 'control: with a working save the file is registered'
  $src = Read-Src 'Toolkit/HikResetFlow.ps1'
  Check ($src -match 'ReadAllText\(\$Path\) -ne \$json') 'class A (code shape): Save-HikState reads back the FINAL record file (not only the temp copy) before it says saved'
  $ss = Read-Src 'Toolkit/HikSadp.ps1'
  Check ($ss -match 'ReadAllText\(\$path\) -ne \$text') 'class A (code shape): Save-HikResetFile returns the file only when it reads back as written'
}

# ------------------------------------------------------------------------------------------------------------------------------
Write-Host ''
Write-Host 'R18 (NetCheck.ps1, class C): HTTP 200 is not a document'
$ncAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'NetCheck/NetCheck.ps1'), [ref]$null, [ref]$null)
Run-Safe 'netcheck streams' {
  [void](Import-FnFromAst $ncAst @('Get-NcStreamsText', 'Format-NcStreamsTo', 'Tag', 'Read-Logs', 'Get-NcIsapiProblem'))
  $errDoc = '<ResponseStatus><statusCode>4</statusCode><statusString>Invalid Operation</statusString></ResponseStatus>'
  $t = Format-NcStreamsTo (Get-NcStreamsText @{ code = 200; body = $errDoc })
  Write-Host ('REPRO stream-error-document result=' + $t)
  Check ($t -match '^NOT CHECKED') 'reproduction (Codex R18 stream-error-document): HTTP 200 with <ResponseStatus> statusCode 4 is NOT CHECKED (2.2.19: "nobody")' $t
  $t = Format-NcStreamsTo (Get-NcStreamsText @{ code = 200; body = '<html><body>Login</body></html>' })
  Check ($t -match '^NOT CHECKED') 'R18: HTTP 200 with a login web page is NOT CHECKED, never "nobody"' $t
  $t = Format-NcStreamsTo (Get-NcStreamsText @{ code = 200; body = '<StreamingStatus><totalStreamingSessions>2</totalStreamingSessions></StreamingStatus>' })
  Check ($t -match '^NOT CHECKED') 'R18: a status that says 2 sessions but names no client is NOT CHECKED, never "nobody"' $t
  $t = Format-NcStreamsTo (Get-NcStreamsText @{ code = 200; body = '<?xml version="1.0"?><Other/>' })
  Check ($t -match '^NOT CHECKED') 'R18: an answer that is not a streaming-status document is NOT CHECKED' $t
  $t = Format-NcStreamsTo (Get-NcStreamsText @{ code = 200; body = '<StreamingStatus version="2.0"><totalStreamingSessions>0</totalStreamingSessions></StreamingStatus>' })
  Check ($t -eq 'nobody') 'control: a streaming-status document with 0 sessions is "nobody"' $t
  $t = Format-NcStreamsTo (Get-NcStreamsText @{ code = 200; body = '<StreamingStatus><totalStreamingSessions>1</totalStreamingSessions><StreamingSessionStatusList><StreamingSessionStatus><clientAddress><ipAddress>10.0.0.20</ipAddress></clientAddress></StreamingSessionStatus></StreamingSessionStatusList></StreamingStatus>' })
  Check ($t -eq '10.0.0.20') 'control: a session list names who pulls video' $t
}
Run-Safe 'netcheck logs' {
  $global:LogDays = 7; $global:OutDir = $tmp; New-Item -ItemType Directory -Force -Path (Join-Path $tmp 'raw') | Out-Null
  $global:ncAnswer = ''
  function global:Post-Isapi($base, $path, $xml) { return @{ code = 200; body = $global:ncAnswer } }
  $global:ncAnswer = '<ResponseStatus><statusCode>4</statusCode><statusString>Invalid Operation</statusString></ResponseStatus>'
  $lg = [string](Read-Logs 'http://127.0.0.1' '127.0.0.1')
  Check ($lg -match 'NOT CHECKED') 'R18 twin (log search): HTTP 200 with an error document is NOT CHECKED (2.2.19: empty = no events)' $lg
  $global:ncAnswer = '<CMSearchResult><searchID>X</searchID><responseStatus>false</responseStatus><responseStatusStrg>FAILED</responseStatusStrg></CMSearchResult>'
  $lg = [string](Read-Logs 'http://127.0.0.1' '127.0.0.1')
  Check ($lg -match 'NOT CHECKED') 'R18 twin: a search result that says responseStatus false is NOT CHECKED' $lg
  $global:ncAnswer = '<html>Login</html>'
  $lg = [string](Read-Logs 'http://127.0.0.1' '127.0.0.1')
  Check ($lg -match 'NOT CHECKED') 'R18 twin: a login page is NOT CHECKED' $lg
  $global:ncAnswer = '<CMSearchResult><searchID>X</searchID><responseStatus>true</responseStatus><responseStatusStrg>NO MATCHES</responseStatusStrg><numOfMatches>0</numOfMatches></CMSearchResult>'
  $lg = [string](Read-Logs 'http://127.0.0.1' '127.0.0.1')
  Check ($lg -match '^none') 'R18 twin: a search result with no matches says none (read) - 2.2.19 left it blank' $lg
}
Run-Safe 'netcheck device info' {
  $has = [bool](Get-Command Get-NcIsapiProblem -ErrorAction SilentlyContinue)
  $p1 = ''; $p2 = ''; $p3 = 'x'
  if ($has) { $p1 = Get-NcIsapiProblem @{ code = 200; body = '<ResponseStatus><statusCode>4</statusCode></ResponseStatus>' } @('DeviceInfo'); $p2 = Get-NcIsapiProblem @{ code = 200; body = '<html>login</html>' } @('DeviceInfo'); $p3 = Get-NcIsapiProblem @{ code = 200; body = '<DeviceInfo version="2.0"><model>DS</model></DeviceInfo>' } @('DeviceInfo') }
  Check ($has -and $p1 -and $p2 -and -not $p3) 'R18 twin (device information): an error document / login page with HTTP 200 is not a DeviceInfo answer; the real document is' ('err=' + $p1 + ' html=' + $p2 + ' ok=' + $p3)
  $src = Read-Src 'NetCheck/NetCheck.ps1'
  Check ($src -match "Get-NcIsapiProblem \`$d @\('DeviceInfo'\)" -and $src -match "\`$row\.auth = 'NOT CHECKED \(' \+ \`$dw") 'R18 twin (code shape): the per-device pass says auth NOT CHECKED (not "ok") unless deviceInfo is a <DeviceInfo> document, and asks nothing more of that device'
  Check ($src -match "Get-NcIsapiProblem \`$s @\('DeviceStatus'\)" -and $src -match "link NOT CHECKED") 'R18 twin (code shape): uptime and link speed from an error document are NOT CHECKED, never blank'
  Check ($src -match 'ARP table: NOT CHECKED') 'class C (code shape): an ARP table that could not be read is said as NOT CHECKED'
}

Write-Host ''
Write-Host 'SiteCheck (SiteCheck.ps1, class C): an ARP table that could not be read is not an all-clear'
Run-Safe 'sitecheck arp' {
  $scAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'sitecheck/SiteCheck.ps1'), [ref]$null, [ref]$null)
  $hs = $scAst.Find({ param($x) $x -is [Management.Automation.Language.AssignmentStatementAst] -and $x.Left.Extent.Text -match 'SC_CODE' }, $true)
  $code = [string]$hs.Right.Expression.Value
  $inner = [Management.Automation.Language.Parser]::ParseInput($code, [ref]$null, [ref]$null)
  $allFn = @($inner.FindAll({ param($x) $x -is [Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name } | Select-Object -Unique)
  [void](Import-FnFromAst $inner $allFn)   # every helper of the report code (defining them runs nothing)
  [void](Import-FnFromAst $scAst @('New-ScMock'))
  function global:Get-NetNeighbor { param($AddressFamily, $ErrorAction) throw 'the neighbour table could not be read (stand-in)' }
  $a = Get-ScArp @('192.0.2'); $why = [string]$script:ScArpWhy; if (-not $why) { $why = [string]$global:ScArpWhy }
  Check ($a.Count -eq 0 -and $why) 'SiteCheck: a failed ARP read is recorded as failed (2.2.19: silently an empty table)' ('why=' + $why)
  Remove-Item function:\Get-NetNeighbor -ErrorAction SilentlyContinue
  $src = Read-Src 'sitecheck/SiteCheck.ps1'
  Check ($src -match 'arpRead -eq \$false' -and $src -match 'ARP table NOT CHECKED: this PC') 'SiteCheck (code shape): the diagnosis adds an amber ARP NOT CHECKED finding when the table was not read, so the "No network problems found" all-clear cannot be given'
  $hasMock = [bool](Get-Command New-ScMock -ErrorAction SilentlyContinue)
  if (-not $hasMock) { Deferred 'SiteCheck diagnosis run: New-ScMock not found'; return }
  $R = New-ScMock; $R.devices = @(); $R.channels = @(); $R.duplicates = @(); $R.nvr = ''; $R.nvrRead = $null
  $D = Get-ScDiagnosis $R
  Check (@($D.Findings | Where-Object { $_.Level -eq 'ok' }).Count -eq 1) 'control: a clean scan with the ARP table read gives the all-clear'
  $R['arpRead'] = $false; $D = Get-ScDiagnosis $R
  Check (@($D.Findings | Where-Object { $_.Level -eq 'ok' }).Count -eq 0 -and @($D.Findings | Where-Object { $_.Level -eq 'warn' -and $_.Text -match 'ARP' }).Count -eq 1) 'SiteCheck: the same scan with the ARP table NOT read gives no all-clear, one amber NOT CHECKED' (($D.Findings | ForEach-Object { $_.Level + ':' + $_.Text }) -join ' | ')
  # the report upload: only ok = true (a boolean) is "posted"
  $script:SC_UPLOAD_URL = 'https://example.invalid/'
  $global:scAns = $null
  function global:Invoke-RestMethod { param($Uri, $Method, $ContentType, $Body, $TimeoutSec, [switch]$UseBasicParsing) return $global:scAns }
  $global:scAns = [pscustomobject]@{ ok = 'false'; msg = '' }
  $m1 = [string](Send-ScReport $R $D 'WI-100' 'ABCD1234')
  Check ($m1 -notmatch 'Results posted') 'SiteCheck upload: an answer whose ok is the text "false" is NOT "Results posted" (2.2.19: any truthy ok)' $m1
  $global:scAns = [pscustomobject]@{ ok = $true }
  $m2 = [string](Send-ScReport $R $D 'WI-100' 'ABCD1234')
  Check ($m2 -eq 'Results posted to the site page.') 'control: ok = true is posted' $m2
  Remove-Item function:\Invoke-RestMethod -ErrorAction SilentlyContinue
  $src2 = Read-Src 'sitecheck/SiteCheck.ps1'
  Check ($src2 -match 'if \(-not \$t\) \{ continue \}') 'SiteCheck (code shape): a ping that could not be sent is not counted as a lost ping'
  $cmd = [IO.File]::ReadAllText((Join-Path $repo 'sitecheck/WireIt-SiteCheck.cmd')); $i = $cmd.IndexOf('##' + 'PSSTART')
  Check ($i -gt 0 -and $cmd.Substring($i + 11).Trim() -eq ([IO.File]::ReadAllText((Join-Path $repo 'sitecheck/SiteCheck.ps1'))).Trim()) 'SiteCheck: the .cmd launcher carries the same script'
}

try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch {}
Write-Host ''
Write-Host ('Test-Fix2220Reset: ' + $script:pass + ' passed, ' + $script:fail + ' failed, ' + $script:deferred + ' deferred')
if ($script:fail) { exit 1 }
