<# Test-Fix2219Sweep.ps1 - tests for WireIt Toolkit 2.2.19 (Nov 11 2026), the "sweep" area after Codex's NO-GO review of 2.2.18:
   F16 (reset resume checked the saved address, not the device found again by its MAC), F17 (a reset record that could not be saved
   only warned - a refused unlock file was sent again), F20 (camera pictures "saved on this PC" when the file write failed), F25 (a
   damaged waiting upload was deleted without a word), F23 (the update helper rebuilt the saved copy over an update still half-way),
   F26 (Go back without the saved version record said "back on the old version" while version.json kept the new one), and the site
   check summary (red only for a problem that was READ; amber NOT CHECKED for no result). Each finding's Codex reproduction is here as
   a check, plus one check per twin of the same pattern that was fixed.
   Every check RUNS the real function or script; only the network / SADP / file-system boundary is replaced. No real device or
   Windows feature is touched: real-device and Windows PowerShell 5.1 behaviour is DEFERRED (never a pass).
   PS 5.1 or pwsh 7. FIX2219SWEEP_REPO (tests only) = run against another checkout (old-code proof: on 2.2.18 the finding checks FAIL,
   the controls pass). #>
$ErrorActionPreference = 'Stop'
$repo = $(if ($env:FIX2219SWEEP_REPO) { $env:FIX2219SWEEP_REPO } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) })
$tk = Join-Path $repo 'Toolkit'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fix2219sweep-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$script:pass = 0; $script:fail = 0; $script:deferred = 0
function Check([bool]$ok, [string]$name, [string]$more = '') {
  if ($ok) { $script:pass++; Write-Host ('PASS ' + $name) } else { $script:fail++; Write-Host ('FAIL ' + $name); if ($more) { Write-Host ('     ' + $more) } }
}
function Deferred([string]$name) { $script:deferred++; Write-Host ('DEFERRED ' + $name) }
$exe = $(if ($PSVersionTable.PSEdition -eq 'Core') { (Get-Process -Id $PID).Path } else { Join-Path $PSHOME 'powershell.exe' })
$isWin = ($env:OS -eq 'Windows_NT')
function Lock-Dir([string]$p) { if (-not $isWin) { & chmod 555 $p } }
function Unlock-Dir([string]$p) { if (-not $isWin) { & chmod 755 $p } }
# can this login be kept from writing into a folder? (off Windows: chmod; root ignores it -> those checks are DEFERRED)
$canLock = $false
if (-not $isWin) { try { $pd = Join-Path $tmp 'lockprobe'; New-Item -ItemType Directory -Force -Path $pd | Out-Null; Lock-Dir $pd; try { [IO.File]::WriteAllText((Join-Path $pd 'x'), 'x') } catch { $canLock = $true }; Unlock-Dir $pd } catch {} }
function Run-Safe([string]$name, [scriptblock]$sb) { try { & $sb } catch { Check $false ($name + ' (the check itself stopped)') ([string]$_.Exception.Message + ' @' + [string]$_.InvocationInfo.ScriptLineNumber) } }

foreach ($f in @('HikResetFlow.ps1', 'HikReset.ps1', 'CamViews.ps1', 'ScanUpload.ps1', 'ToolkitCore.ps1', 'ToolkitRecover.ps1')) {
  $e = $null; [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $tk $f), [ref]$null, [ref]$e); Check ($e.Count -eq 0) ('parses: ' + $f) ($e | Out-String)
}

try {
. (Join-Path $tk 'HikResetFlow.ps1')
$script:said = New-Object System.Collections.Generic.List[string]
$script:HkSay = { param($t, $c) [void]$script:said.Add([string]$t) }
$script:HkSubnetCheckOff = $true
function Start-Sleep { param([int]$Seconds = 0, [int]$Milliseconds = 0) }   # the import's waits, not the test's
$MAC = 'c4-2f-90-00-01-50'; $SN = 'CAMSER150'
$cfg = [pscustomobject]@{ replyDir = ''; replyTo = ''; form = [pscustomobject]@{ firstName = 'Test'; email = 'test@example.invalid' }; relay = [pscustomobject]@{ url = ''; address = ''; everySec = 60 } }
$script:exportAsks = 0
function Request-HikResetExport { param($dev, [double]$Seconds = 4.0) $script:exportAsks++; return [pscustomobject]@{ ok = $false; error = 'test: no export' } }

# ==============================================================================================================================
Write-Host ''
Write-Host 'F16 (class A): reset resume checks the device found again by its MAC in this scan, never the saved address'
function New-ImportedState([string]$dir, [string]$status = 'imported', [string]$mac = 'c4-2f-90-00-01-50', [string]$serial = 'CAMSER150') {
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $st = [pscustomobject]@{ devices = @([pscustomobject]@{ mac = $mac; serial = $serial; model = 'DS-2CD'; ip = '192.168.1.50'; status = $status; note = ''; verifiedAt = '' }); exports = @() }
  Save-HikState (Join-Path $dir 'state.json') $st
}
function Invoke-Resume([string]$dir, $live, [scriptblock]$okFor) {
  $script:liveDevs = @($live)
  Set-Item -Path Function:\Find-HikSadp -Value { param([double]$Seconds = 3.5, $Socks = $null) return @($script:liveDevs) }
  $global:F2219Verify = New-Object System.Collections.Generic.List[string]
  $global:F2219OkFor = $okFor
  $vf = { param($ip, $pw) [void]$global:F2219Verify.Add([string]$ip); return [bool](& $global:F2219OkFor $ip) }
  $script:said.Clear()
  $res = Invoke-HikResetStage -Targets @([pscustomobject]@{ mac = $MAC }) -SitePassword 'Sitepass456' -StateDir $dir -Config $cfg -VerifyLogin $vf -WaitMinutes 0
  $script:verifyIps = @($global:F2219Verify)
  return $res
}
Run-Safe 'F16 repro' {
  # Codex reset.ps1: the selected camera is live at .60; ANOTHER camera at the saved .50 takes the site password
  $d = Join-Path $tmp 'f16-repro'; New-ImportedState $d
  $rr = Invoke-Resume $d ([pscustomobject]@{ mac = $MAC; serial = $SN; model = 'DS-2CD'; ip = '192.168.1.60'; activated = $true }) { param($ip) $ip -eq '192.168.1.50' }
  Check (-not (@($rr.fixed) -contains $MAC) -and -not ($script:verifyIps -contains '192.168.1.50')) 'F16 (Codex reset.ps1): resume with the camera now at .60 and another camera answering the site password at the saved .50 -> NOT "fixed", the old address is not checked (2.2.18: fixed by checking .50)' ('fixed=' + (@($rr.fixed) -join ',') + ' verified at=' + ($script:verifyIps -join ','))
  Check ($script:verifyIps -contains '192.168.1.60' -and @($rr.pending | Where-Object { (ConvertTo-SadpMac ([string]$_.mac)) -eq $MAC }).Count -ge 1) 'F16: ...the site password is checked at the address the device has NOW (.60), and the camera stays pending' ('verified at=' + ($script:verifyIps -join ',') + ' pending=' + (@($rr.pending | ForEach-Object { $_.reason }) -join ' | '))
}
Run-Safe 'F16 live address control' {
  $d = Join-Path $tmp 'f16-live'; New-ImportedState $d
  $rr = Invoke-Resume $d ([pscustomobject]@{ mac = $MAC; serial = $SN; model = 'DS-2CD'; ip = '192.168.1.60'; activated = $true }) { param($ip) $ip -eq '192.168.1.60' }
  $disk = Read-HikState (Join-Path $d 'state.json')
  Check ((@($rr.fixed) -contains $MAC) -and ($script:verifyIps -join ',') -eq '192.168.1.60' -and [string]$disk.devices[0].status -eq 'verified') 'F16 twin: the same device (same MAC) that moved to .60 and takes the site password there -> fixed, checked once at .60, record "verified" (2.2.18: checked only the old .50, not fixed)' ('fixed=' + (@($rr.fixed) -join ',') + ' verified at=' + ($script:verifyIps -join ',') + ' status=' + $disk.devices[0].status)
}
Run-Safe 'F16 not seen' {
  $d = Join-Path $tmp 'f16-gone'; New-ImportedState $d
  $rr = Invoke-Resume $d @() { param($ip) $true }
  Check (-not @($rr.fixed).Count -and -not $script:verifyIps.Count -and @($rr.pending | Where-Object { [string]$_.reason -match 'NOT CHECKED|not seen' }).Count -ge 1) 'F16 twin: the device is not seen in this scan -> no password check anywhere, NOT CHECKED, pending (2.2.18: checked the saved address and said fixed)' ('fixed=' + (@($rr.fixed) -join ',') + ' verified at=' + ($script:verifyIps -join ',') + ' pending=' + (@($rr.pending | ForEach-Object { $_.reason }) -join ' | '))
}
Run-Safe 'F16 serial mismatch' {
  $d = Join-Path $tmp 'f16-serial'; New-ImportedState $d
  $rr = Invoke-Resume $d ([pscustomobject]@{ mac = $MAC; serial = 'OTHERSER999'; model = 'DS-2CD'; ip = '192.168.1.50'; activated = $true }) { param($ip) $true }
  Check (-not @($rr.fixed).Count -and -not $script:verifyIps.Count) 'F16 twin: a device with the saved MAC but a DIFFERENT serial is not taken as the saved device -> not checked, not fixed (2.2.18: fixed)' ('fixed=' + (@($rr.fixed) -join ',') + ' verified at=' + ($script:verifyIps -join ','))
}
Run-Safe 'F16 import twin (no MAC saved)' {
  # Import-HikReplies picked the live device by "mac -eq saved mac": with no MAC saved, ANY device without a MAC matched
  $d = Join-Path $tmp 'f16-import'; New-Item -ItemType Directory -Force -Path $d | Out-Null
  $rf = Join-Path $d 'reply.xml'; [IO.File]::WriteAllText($rf, 'x')
  $st = [pscustomobject]@{ devices = @([pscustomobject]@{ mac = ''; serial = $SN; shortSerial = $SN; model = 'DS-2CD'; ip = '192.168.1.50'; status = 'replied'; note = ''; bootTime = ''; validUntil = (Get-Date).AddDays(1).ToString('s'); exportedAt = (Get-Date).AddHours(-1).ToString('s'); exportId = 'x'; replyForExport = 'x'; requestFile = ''; replyFile = $rf; rebootRetries = 0 }); exports = @() }
  $sp = Join-Path $d 'state.json'; Save-HikState $sp $st
  $script:liveDevs = @([pscustomobject]@{ mac = ''; serial = 'OTHERSER999'; ip = '192.168.1.77'; bootTime = '' })
  Set-Item -Path Function:\Find-HikSadp -Value { param([double]$Seconds = 3.5, $Socks = $null) return @($script:liveDevs) }
  Set-Item -Path Function:\Read-HikUnlock -Value { param([string]$Path = '', [string]$Key = '') return @{ type = 'code'; value = 'ABCD1234'; code = 'ABCD1234' } }
  $script:importTo = @()
  Set-Item -Path Function:\Import-HikUnlock -Value { param($dev, $unlock, [string]$NewPassword, [double]$Seconds = 5.0) $script:importTo += [string]$dev.serial; return @{ ok = $false; result = 'failed'; error = 'device refused' } }
  [void](Import-HikReplies (Read-HikState $sp) $sp 'Sitepass456' { param($ip, $p) $false })
  Check (-not $script:importTo.Count) 'F16 twin (Import-HikReplies): a record with no MAC is NOT matched to a different device that also shows no MAC -> nothing imported (2.2.18: the unlock file went to that other device)' ('imported into: ' + ($script:importTo -join ','))
}

# ==============================================================================================================================
Write-Host ''
Write-Host 'F17 (class E): what the reset is about to send is saved first; no save = nothing is sent'
Set-Item -Path Function:\Read-HikUnlock -Value { param([string]$Path = '', [string]$Key = '') return @{ type = 'code'; value = 'ABCD1234'; code = 'ABCD1234' } }
function New-RepliedState([string]$dir) {
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $st = [pscustomobject]@{ devices = @([pscustomobject]@{ mac = $MAC; serial = $SN; shortSerial = $SN; model = 'DS-2CD'; ip = '192.168.1.50'; status = 'replied'; note = ''; bootTime = 'boot'; validUntil = (Get-Date).AddDays(1).ToString('s'); exportedAt = (Get-Date).AddHours(-1).ToString('s'); exportId = 'x'; replyForExport = 'x'; requestFile = ''; replyFile = 'reply.xml'; rebootRetries = 0 }); exports = @() }
  Save-HikState (Join-Path $dir 'state.json') $st
}
$script:liveDevs = @([pscustomobject]@{ mac = $MAC; serial = $SN; ip = '192.168.1.50'; bootTime = 'boot'; activated = $true; model = 'DS-2CD' })
Set-Item -Path Function:\Find-HikSadp -Value { param([double]$Seconds = 3.5, $Socks = $null) return @($script:liveDevs) }
if ($canLock) {
  Run-Safe 'F17 repro' {
    # Codex reset-persistence.ps1: a readable "replied" record in a folder this login cannot write; the device refuses the file; run twice
    $d = Join-Path $tmp 'f17-repro'; New-RepliedState $d; $sp = Join-Path $d 'state.json'
    $script:imports = 0
    Set-Item -Path Function:\Import-HikUnlock -Value { param($dev, $unlock, [string]$NewPassword, [double]$Seconds = 5.0) $script:imports++; return @{ ok = $false; result = 'failed'; error = 'device refused' } }
    Lock-Dir $d
    try { foreach ($run in 1..2) { $s = Read-HikState $sp; [void](Import-HikReplies $s $sp 'Sitepass456' { return $false }) } } finally { Unlock-Dir $d }
    $disk = Read-HikState $sp
    Check ($script:imports -eq 0) 'F17 (Codex reset-persistence.ps1): the record cannot be saved -> the unlock file is NOT sent at all, in either run (2.2.18: sent twice, "will not be tried again" was false)' ('imports=' + $script:imports + ' disk status=' + $disk.devices[0].status)
    Check (@($script:said | Where-Object { $_ -match 'STOPPED' -and $_ -match 'NOT done' }).Count -ge 1) 'F17: ...and it says plainly that the import was NOT done because the record could not be saved' ((@($script:said) | Select-Object -Last 4) -join ' | ')
  }
  Run-Safe 'F17 refusal not saved' {
    # the intent is saved, the device refuses, then the folder can no longer be written: the refusal cannot be saved
    $d = Join-Path $tmp 'f17-late'; New-RepliedState $d; $sp = Join-Path $d 'state.json'
    $script:imports = 0; $script:lockMe = $d
    Set-Item -Path Function:\Import-HikUnlock -Value { param($dev, $unlock, [string]$NewPassword, [double]$Seconds = 5.0) $script:imports++; & chmod 555 $script:lockMe; return @{ ok = $false; result = 'failed'; error = 'device refused' } }
    try { foreach ($run in 1..2) { $s = Read-HikState $sp; [void](Import-HikReplies $s $sp 'Sitepass456' { return $false }) } } finally { Unlock-Dir $d }
    $disk = Read-HikState $sp
    Check ($script:imports -eq 1 -and [string]$disk.devices[0].status -ne 'replied') 'F17 twin: the refusal itself could not be saved -> the record on disk already says the import was started, so the second run does NOT send the file again (2.2.18: disk still "replied", sent again)' ('imports=' + $script:imports + ' disk status=' + $disk.devices[0].status)
  }
  Run-Safe 'F17 stage start' {
    $d = Join-Path $tmp 'f17-stage'; New-RepliedState $d
    $script:sadpCalls = 0
    Set-Item -Path Function:\Find-HikSadp -Value { param([double]$Seconds = 3.5, $Socks = $null) $script:sadpCalls++; return @($script:liveDevs) }
    Lock-Dir $d
    $rr = $null; try { $rr = Invoke-HikResetStage -Targets @([pscustomobject]@{ mac = $MAC }) -SitePassword 'Sitepass456' -StateDir $d -Config $cfg -VerifyLogin { param($ip, $p) $false } -WaitMinutes 0 } finally { Unlock-Dir $d }
    Check ($script:sadpCalls -eq 0 -and $rr -and @($rr.pending | Where-Object { [string]$_.reason -match 'could not be saved' }).Count -eq 1) 'F17 twin (Fix this site reset stage): the record folder cannot be written -> no device is asked anything, the camera is pending "record could not be saved" (2.2.18: went ahead)' ('sadp calls=' + $script:sadpCalls + ' pending=' + $(if ($rr) { (@($rr.pending | ForEach-Object { $_.reason }) -join ' | ') } else { '-' }))
    Set-Item -Path Function:\Find-HikSadp -Value { param([double]$Seconds = 3.5, $Socks = $null) return @($script:liveDevs) }
  }
  Run-Safe 'F17 export' {
    # a new export voids every earlier reply: it is not asked for when the record cannot say so first
    $d = Join-Path $tmp 'f17-export'; New-Item -ItemType Directory -Force -Path $d | Out-Null; $sp = Join-Path $d 'state.json'
    $st = Read-HikState $sp; Save-HikState $sp $st
    $script:exportAsks = 0
    Lock-Dir $d
    try { [void](Export-HikRequests @([pscustomobject]@{ mac = $MAC; serial = $SN; model = 'DS-2CD'; ip = '192.168.1.50'; activated = $true; bootTime = 'boot' }) (Join-Path $tmp 'f17-req') $st $sp) } finally { Unlock-Dir $d }
    Check ($script:exportAsks -eq 0) 'F17 twin (Export-HikRequests): the record cannot be saved -> the device is NOT asked for a new request file (2.2.18: asked, and the export that voids older replies went unrecorded)' ('export asks=' + $script:exportAsks)
  }
  Run-Safe 'F17 drop kept' {
    # Receive-HikReplies removed the dropped reply BEFORE the record said "replied"; with the save failing the reply was lost
    $base = Join-Path $tmp 'f17-rcv'; $sd = Join-Path $base 'state'; $inb = Join-Path $base 'inbox/hik'; $rep = Join-Path $base 'replies'
    New-Item -ItemType Directory -Force -Path $sd, $inb, $rep | Out-Null
    $unlockB = [Text.Encoding]::UTF8.GetBytes('<ResetPassword><Code>Ab3dE5gH</Code></ResetPassword>')
    $drop = Join-Path $inb ('drop-' + $SN + '-20261110-210000.xml'); [IO.File]::WriteAllBytes($drop, $unlockB)
    $req = Join-Path $base 'request.xml'; [IO.File]::WriteAllText($req, 'our own request file')
    $sp = Join-Path $sd 'state.json'
    $st = [pscustomobject]@{ version = 1; devices = @([pscustomobject]@{ serial = $SN; shortSerial = $SN; mac = $MAC; ip = '192.168.1.50'; model = 'DS-2CD'; status = 'submitted'; exportedAt = (Get-Date).AddHours(-1).ToString('s'); validUntil = (Get-Date).AddHours(47).ToString('s'); requestFile = $req; bootTime = ''; exportId = 'x' }); exports = @() }
    Save-HikState $sp $st
    Set-Item -Path Function:\Get-HikReplyMessages -Value { param($Cfg, [string]$ToolkitDir, [string]$ReplyDir, [datetime]$Since, $Pending = @(), [string]$InboxDir = '', [switch]$ForceRelay) return @() }
    $script:mDrop = $drop; $script:mBytes = $unlockB
    Set-Item -Path Function:\Find-HikReplyMatches -Value { param($Pending, $Msgs, $All) $dv = @($Pending)[0]; $src = $script:mDrop; if (-not (Test-Path -LiteralPath $src)) { $src = Join-Path $script:repDirT ('reply-' + $dv.serial + '.xml') }; return [pscustomobject]@{ matched = @([pscustomobject]@{ device = $dv; bytes = $script:mBytes; src = $src; date = (Get-Date).AddMinutes(-5).ToString('s'); name = (Split-Path -Leaf $src); mail = ''; how = 'serial' }); unmatched = @(); skipped = @() } }
    $script:repDirT = $rep
    Lock-Dir $sd
    try { $s1 = Read-HikState $sp; [void](Receive-HikReplies $s1 $sp $null $base $rep $inb) } finally { Unlock-Dir $sd }
    $d1 = Read-HikState $sp
    Check ((Test-Path -LiteralPath $drop) -and [string]$d1.devices[0].status -eq 'submitted') 'F17 twin (Receive-HikReplies): the record cannot be saved -> the dropped unlock file stays in the inbox (2.2.18: deleted before the record was saved, so the reply was lost)' ('drop there=' + (Test-Path -LiteralPath $drop) + ' disk status=' + $d1.devices[0].status)
    $s2 = Read-HikState $sp; [void](Receive-HikReplies $s2 $sp $null $base $rep $inb)
    $d2 = Read-HikState $sp
    Check ([string]$d2.devices[0].status -eq 'replied' -and -not (Test-Path -LiteralPath $drop)) 'F17 twin: ...the next look (record writable again) takes the same reply: "replied", and only then the drop is removed' ('disk status=' + $d2.devices[0].status + ' drop there=' + (Test-Path -LiteralPath $drop))
    Remove-Item Function:\Get-HikReplyMessages, Function:\Find-HikReplyMatches -ErrorAction SilentlyContinue
    . (Join-Path $tk 'HikResetFlow.ps1'); $script:HkSay = { param($t, $c) [void]$script:said.Add([string]$t) }; $script:HkSubnetCheckOff = $true
    Set-Item -Path Function:\Find-HikSadp -Value { param([double]$Seconds = 3.5, $Socks = $null) return @($script:liveDevs) }
    Set-Item -Path Function:\Read-HikUnlock -Value { param([string]$Path = '', [string]$Key = '') return @{ type = 'code'; value = 'ABCD1234'; code = 'ABCD1234' } }
    Set-Item -Path Function:\Request-HikResetExport -Value { param($dev, [double]$Seconds = 4.0) $script:exportAsks++; return [pscustomobject]@{ ok = $false; error = 'test: no export' } }
  }
} else {
  Deferred 'F17 (Codex reset-persistence.ps1) and its twins: this login cannot be kept from writing a folder (Windows / root), so the save-failure checks did not run'
}
Run-Safe 'F17 importing resume' {
  # a record left at "importing" (started, result never saved): never imported again; the next stage checks the login on the device by MAC
  $d = Join-Path $tmp 'f17-importing'; New-RepliedState $d; $sp = Join-Path $d 'state.json'
  $s = Read-HikState $sp; $s.devices[0].status = 'importing'; Save-HikState $sp $s
  $script:imports = 0
  Set-Item -Path Function:\Import-HikUnlock -Value { param($dev, $unlock, [string]$NewPassword, [double]$Seconds = 5.0) $script:imports++; return @{ ok = $true; result = 'success'; error = '' } }
  $rr = Invoke-Resume $d ([pscustomobject]@{ mac = $MAC; serial = $SN; model = 'DS-2CD'; ip = '192.168.1.61'; activated = $true; bootTime = 'boot' }) { param($ip) $ip -eq '192.168.1.61' }
  Check ((@($rr.fixed) -contains $MAC) -and $script:imports -eq 0 -and ($script:verifyIps -join ',') -eq '192.168.1.61') 'F17 twin: an import that was started but never recorded is not sent again; the site password is checked on the device found by its MAC (.61) and it counts as fixed (2.2.18 had no such record)' ('fixed=' + (@($rr.fixed) -join ',') + ' imports=' + $script:imports + ' verified at=' + ($script:verifyIps -join ','))
}
Run-Safe 'F17 voided reply' {
  # an export was STARTED after the one this reply answers (recorded before the device was asked): the reply no longer fits
  $d = Join-Path $tmp 'f17-void'; New-RepliedState $d; $sp = Join-Path $d 'state.json'
  $s = Read-HikState $sp
  $s | Add-Member -NotePropertyName intents -NotePropertyValue @([pscustomobject]@{ serial = $SN; mac = $MAC; action = 'export'; at = (Get-Date).AddMinutes(-10).ToString('s') }) -Force
  Save-HikState $sp $s
  $script:imports = 0
  Set-Item -Path Function:\Import-HikUnlock -Value { param($dev, $unlock, [string]$NewPassword, [double]$Seconds = 5.0) $script:imports++; return @{ ok = $false; result = 'failed'; error = 'device refused' } }
  [void](Import-HikReplies (Read-HikState $sp) $sp 'Sitepass456' { return $false })
  Check ($script:imports -eq 0 -and [string](Read-HikState $sp).devices[0].status -eq 'expired') 'F17 twin: a newer export was started after the request this reply answers -> the reply is NOT imported, the record says it needs a new request (2.2.18: no record of the started export; imported and refused)' ('imports=' + $script:imports)
}
Run-Safe 'F17 control' {
  $d = Join-Path $tmp 'f17-ok'; New-RepliedState $d; $sp = Join-Path $d 'state.json'
  $script:imports = 0
  Set-Item -Path Function:\Import-HikUnlock -Value { param($dev, $unlock, [string]$NewPassword, [double]$Seconds = 5.0) $script:imports++; return @{ ok = $false; result = 'failed'; error = 'device refused' } }
  foreach ($run in 1..2) { $s = Read-HikState $sp; [void](Import-HikReplies $s $sp 'Sitepass456' { return $false }) }
  Check ($script:imports -eq 1 -and [string](Read-HikState $sp).devices[0].status -eq 'refused') 'control: a writable record - the refused file is sent once, saved as refused, and not sent on the second run'
}

# ==============================================================================================================================
Write-Host ''
Write-Host 'F20 (class F): camera pictures count as saved only when the file on this PC is written and reads back'
Remove-Item Function:\Start-Sleep -ErrorAction SilentlyContinue
. (Join-Path $tk 'CamViews.ps1') -Lib
$script:CvLogDir = Join-Path $tmp 'cv-logs'
$script:cvSaid = New-Object System.Collections.Generic.List[string]
function Say([string]$t, [string]$c = '') { [void]$script:cvSaid.Add([string]$t) }
function Get-CvChannels { return @([pscustomobject]@{ id = '1'; ip = '10.0.0.21'; online = $true }) }
function Get-CvPicture { return [byte[]](1..200) }
function Get-CvPrepared { return @{ jpg = [byte[]](1..200); sig = ''; sh = '' } }
Run-Safe 'F20 repro' {
  # Codex pictures.ps1: the pictures folder sits under a plain FILE, so no picture can be written
  $blocker = Join-Path $tmp 'pictures-not-directory'; [IO.File]::WriteAllText($blocker, 'x'); $script:CvPics = Join-Path $blocker 'pictures'
  $script:cvSaid.Clear()
  $rr = Save-CameraViews -Nvr '10.0.0.20' -Site 'Review' -NoUpload
  $txt = (@($script:cvSaid) -join ' | ')
  Check (-not $rr.ok -and [int]$rr.pictures -eq 0) 'F20 (Codex pictures.ps1): the picture file cannot be written -> ok=false, pictures=0 (2.2.18: ok=true, pictures=1 with no file)' ('ok=' + $rr.ok + ' pictures=' + $rr.pictures)
  Check ($txt -notmatch 'Pictures saved on this PC' -and $txt -match 'could NOT be saved on this PC') 'F20: ...it does not say "Pictures saved on this PC"; it says the picture could NOT be saved' $txt
}
Run-Safe 'F20 control' {
  $script:CvPics = Join-Path $tmp 'pictures-ok'; $script:cvSaid.Clear()
  $rr = Save-CameraViews -Nvr '10.0.0.20' -Site 'Review' -NoUpload
  $files = @(Get-ChildItem -LiteralPath $script:CvPics -Recurse -Filter '*.jpg' -ErrorAction SilentlyContinue)
  Check ($rr.ok -and [int]$rr.pictures -eq 1 -and $files.Count -eq 1 -and $files[0].Length -eq 200) 'control: a writable pictures folder - ok, 1 picture, and the file is there with all its bytes'
}
Run-Safe 'F20 outbox twin' {
  # upload mode with no upload key: the pictures "wait in the outbox" - only true if the outbox file was written
  $script:CvPics = Join-Path $tmp 'pictures-ok2'
  $blk = Join-Path $tmp 'outbox-not-directory'; [IO.File]::WriteAllText($blk, 'x'); $script:CvOutbox = Join-Path $blk 'outbox'
  Set-Item -Path Function:\Get-CvKey -Value { return '' }
  $script:cvSaid.Clear()
  $rr = Save-CameraViews -Nvr '10.0.0.20' -Site 'Review'
  $txt = (@($script:cvSaid) -join ' | ')
  Check (-not $rr.queued -and -not $rr.ok -and $txt -notmatch 'Pictures wait in the outbox') 'F20 twin (Save-CvOutbox): the outbox file cannot be written -> not "queued", not ok, and it does not say the pictures wait in the outbox (2.2.18: queued=true, ok=true)' ('queued=' + $rr.queued + ' ok=' + $rr.ok + ' said: ' + $txt)
  $script:CvOutbox = Join-Path $tmp 'outbox-ok'; $script:cvSaid.Clear()
  $rr2 = Save-CameraViews -Nvr '10.0.0.20' -Site 'Review'
  Check ($rr2.queued -and @(Get-ChildItem -LiteralPath $script:CvOutbox -Filter 'camviews-*.json').Count -ge 1) 'control: a writable outbox - queued, and the waiting files are there'
}

# ==============================================================================================================================
Write-Host ''
Write-Host 'F25 (class E): a waiting upload that cannot be used is kept aside and named, never deleted without a word'
Set-Item -Path Function:\Get-CvKey -Value { return 'test-only' }
Run-Safe 'F25 repro' {
  # Codex known-open.ps1 (outbox part): a truncated camera-pictures file in the outbox
  $script:CvOutbox = Join-Path $tmp 'corrupt-outbox'; New-Item -ItemType Directory -Force -Path $script:CvOutbox | Out-Null
  $f = Join-Path $script:CvOutbox 'camviews-corrupt.json'; [IO.File]::WriteAllText($f, '{truncated')
  $script:cvSaid.Clear(); $script:sentBodies = 0
  Set-Item -Path Function:\Send-CvBody -Value { param($body) $script:sentBodies++; return [pscustomobject]@{ ok = $true } }
  $sent = Send-CvOutbox
  $q = @(Get-ChildItem -LiteralPath (Join-Path $script:CvOutbox 'quarantine') -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'camviews-corrupt.json.corrupt-*' })
  Check ($q.Count -eq 1 -and [IO.File]::ReadAllText($q[0].FullName) -eq '{truncated') 'F25 (Codex known-open.ps1): a damaged waiting file is moved to outbox\quarantine with its content kept (2.2.18: deleted)' ('quarantined=' + $q.Count + ' original there=' + (Test-Path -LiteralPath $f))
  Check ((@($script:cvSaid) -join ' ') -match 'NOT sent' -and [int]$sent -eq 0 -and $script:sentBodies -eq 0) 'F25: ...the technician is told those pictures were NOT sent, and nothing was sent' (@($script:cvSaid) -join ' | ')
}
Run-Safe 'F25 foreign file' {
  $script:CvOutbox = Join-Path $tmp 'foreign-outbox'; New-Item -ItemType Directory -Force -Path $script:CvOutbox | Out-Null
  $f = Join-Path $script:CvOutbox 'camviews-foreign.json'; [IO.File]::WriteAllText($f, '{"op":"somethingElse","site":"X"}')
  $script:sentBodies = 0; [void](Send-CvOutbox)
  $q = @(Get-ChildItem -LiteralPath (Join-Path $script:CvOutbox 'quarantine') -ErrorAction SilentlyContinue)
  Check ($q.Count -eq 1 -and $script:sentBodies -eq 0) 'F25 twin: a waiting file that is not a camera-pictures push is not sent and is kept in quarantine (2.2.18: deleted)' ('quarantined=' + $q.Count + ' sent=' + $script:sentBodies)
}
Run-Safe 'F25 refused' {
  $script:CvOutbox = Join-Path $tmp 'refused-outbox'; New-Item -ItemType Directory -Force -Path $script:CvOutbox | Out-Null
  $f = Join-Path $script:CvOutbox 'camviews-refused.json'; [IO.File]::WriteAllText($f, '{"op":"camPush","site":"X","pics":[{"key":"CH01"}]}')
  Set-Item -Path Function:\Send-CvBody -Value { param($body) return [pscustomobject]@{ ok = $false; msg = 'site not found' } }
  $script:cvSaid.Clear(); [void](Send-CvOutbox)
  $q = @(Get-ChildItem -LiteralPath (Join-Path $script:CvOutbox 'quarantine') -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*.refused-*' })
  Check ($q.Count -eq 1 -and (@($script:cvSaid) -join ' ') -match 'NOT sent') 'F25 twin: waiting pictures the service log refused are kept in quarantine and named as NOT sent (2.2.18: deleted)' ('quarantined=' + $q.Count + ' said: ' + (@($script:cvSaid) -join ' | '))
  Set-Item -Path Function:\Send-CvBody -Value { param($body) return [pscustomobject]@{ ok = $true } }
  $f2 = Join-Path $script:CvOutbox 'camviews-good.json'; [IO.File]::WriteAllText($f2, '{"op":"camPush","site":"X","pics":[{"key":"CH01"}]}')
  $n = Send-CvOutbox
  Check ([int]$n -eq 1 -and -not (Test-Path -LiteralPath $f2)) 'control: a good waiting file is sent and only then removed'
}
Run-Safe 'F25 ScanUpload' {
  # ScanUpload.ps1 (the scan list uploader, a separate script): a damaged waiting camera list
  $base = Join-Path $tmp 'su'; $sTk = Join-Path $base 'Toolkit'; New-Item -ItemType Directory -Force -Path $sTk | Out-Null
  foreach ($n in @('ScanUpload.ps1', 'ToolkitCore.ps1', 'ToolkitRecover.ps1', 'CamViews.ps1')) { Copy-Item -LiteralPath (Join-Path $tk $n) -Destination (Join-Path $sTk $n) }
  $ob = Join-Path $sTk 'outbox'; New-Item -ItemType Directory -Force -Path $ob | Out-Null
  $bad = Join-Path $ob 'scan-other-12345678.json'; [IO.File]::WriteAllText($bad, '{"op":"scanPush","site":"Oth')
  $cr = Join-Path $base 'CamReset'; New-Item -ItemType Directory -Force -Path (Join-Path $cr 'out') | Out-Null
  [IO.File]::WriteAllText((Join-Path $cr 'out/latest.json'), '{"devices":[{"Brand":"Hikvision","Model":"DS-2CD2143G0-I","Serial":"DS-2CD2143G0-I20200101AAWRF12345678","MAC":"c4:2f:90:00:00:50","IP":"192.0.2.50","Firmware":"V5.7.3"}]}')
  $env:WIREIT_UPLOAD_KEY = 'test-only-key-000000000000'
  try { $o = & $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $sTk 'ScanUpload.ps1') -Site 'Review' -CamResetDir $cr -ApiUrl 'http://127.0.0.1:9/none' 2>&1 | Out-String } finally { Remove-Item Env:\WIREIT_UPLOAD_KEY -ErrorAction SilentlyContinue }
  $q = @(Get-ChildItem -LiteralPath (Join-Path $ob 'quarantine') -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'scan-other-12345678.json.corrupt-*' })
  Check ($q.Count -eq 1 -and -not (Test-Path -LiteralPath $bad)) 'F25 twin (ScanUpload.ps1): a damaged waiting camera list is moved to outbox\quarantine, not deleted (2.2.18: deleted)' ('quarantined=' + $q.Count + ' original there=' + (Test-Path -LiteralPath $bad) + ' out: ' + $o.Trim())
  Check ($o -match '!! A waiting camera list' -and $o -match 'NOT saved to the site page') 'F25 twin: ...and ScanUpload says it in red ("!! ... was NOT saved to the site page")' $o.Trim()
}

# ==============================================================================================================================
Write-Host ''
Write-Host 'F23 / F26 (class E): the update helper and Go back keep the way back and a version record that matches the files'
. (Join-Path $tk 'ToolkitCore.ps1')
function New-Manifest([string]$ver, [string]$text) {
  $b = [Text.Encoding]::UTF8.GetBytes($text); $sha = [Security.Cryptography.SHA256]::Create(); $hash = ([BitConverter]::ToString($sha.ComputeHash($b))).Replace('-', '').ToLower()
  return [pscustomobject]@{ version = $ver; base = 'https://raw.githubusercontent.com/wireitct/wireit-toolkit/e6f2cb5063145b32ebfb6cff96e50dc2f14a8e79'; released = 'test'; commit = 'test'; files = @([pscustomobject]@{ path = 'Toolkit/example.ps1'; sha256 = $hash }) }
}
$script:fetches = 0
$fetchNew = { param($url) $script:fetches++; return [Text.Encoding]::UTF8.GetBytes('NEW') }
Run-Safe 'F23 repro' {
  # Codex updater.ps1: an outstanding recovery record with the ORIGINAL saved file and a HALF-UPDATED live file
  $root = Join-Path $tmp 'upd1'; $tkd = Join-Path $root 'Toolkit'; $prev = Join-Path $tkd 'previous/9.9.1'
  New-Item -ItemType Directory -Force -Path (Join-Path $prev 'Toolkit') | Out-Null
  [IO.File]::WriteAllText((Join-Path $prev 'Toolkit/example.ps1'), 'ORIGINAL, must recover this')
  [IO.File]::WriteAllText((Join-Path $tkd 'example.ps1'), 'HALF-UPDATED')
  [IO.File]::WriteAllText((Join-Path $tkd 'version.json'), '{"version":"9.9.1"}')
  Save-TkJson ([pscustomobject]@{ prev = $prev; from = '9.9.1'; to = '9.9.2'; added = @() }) (Join-Path $tkd 'previous/update-pending.json')
  $script:fetches = 0; $err = ''; $r = $null
  try { $r = Install-TkUpdate (New-Manifest '9.9.2' 'NEW') $tkd $fetchNew } catch { $err = $_.Exception.Message }
  Check ($err -match 'refused' -and $err -match 'half-way' -and $script:fetches -eq 0) 'F23 (Codex updater.ps1): an update or Go back still half-way -> Install-TkUpdate refuses before downloading anything, plain message (2.2.18: installed over it)' ('err=' + $err + ' fetches=' + $script:fetches)
  Check ([IO.File]::ReadAllText((Join-Path $prev 'Toolkit/example.ps1')) -eq 'ORIGINAL, must recover this' -and (Test-Path (Join-Path $tkd 'previous/update-pending.json')) -and -not (Test-Path (Join-Path $tkd 'update-staging'))) 'F23: ...the saved ORIGINAL and the pending record are untouched and no staging folder was made (2.2.18: saved copy overwritten with HALF-UPDATED, record gone)'
}
Run-Safe 'F23 control' {
  $root = Join-Path $tmp 'upd2'; $tkd = Join-Path $root 'Toolkit'; New-Item -ItemType Directory -Force -Path $tkd | Out-Null
  [IO.File]::WriteAllText((Join-Path $tkd 'example.ps1'), 'OLD'); [IO.File]::WriteAllText((Join-Path $tkd 'version.json'), '{"version":"9.9.1"}')
  $r = Install-TkUpdate (New-Manifest '9.9.2' 'NEW') $tkd $fetchNew
  Check ($r -eq '9.9.1' -and [IO.File]::ReadAllText((Join-Path $tkd 'example.ps1')) -eq 'NEW' -and (Read-TkJson (Join-Path $tkd 'version.json')).version -eq '9.9.2' -and -not (Test-Path (Join-Path $tkd 'previous/update-pending.json'))) 'control: with nothing half-way the update installs, version.json says 9.9.2, no pending record left'
}
Run-Safe 'F26 repro' {
  # Codex known-open.ps1 (Go back part): the saved version record (version.json.prev) is missing
  $root = Join-Path $tmp 'undo1'; $tkd = Join-Path $root 'Toolkit'; New-Item -ItemType Directory -Force -Path $tkd | Out-Null
  [IO.File]::WriteAllText((Join-Path $tkd 'example.ps1'), 'OLD'); [IO.File]::WriteAllText((Join-Path $tkd 'version.json'), '{"version":"9.9.1"}')
  [void](Install-TkUpdate (New-Manifest '9.9.2' 'NEW') $tkd $fetchNew)
  Remove-Item -LiteralPath (Join-Path $tkd 'previous/9.9.1/version.json.prev') -Force
  $u = $null; $err = ''; try { $u = Undo-TkUpdate $tkd } catch { $err = $_.Exception.Message }
  $rec = [string](Read-TkJson (Join-Path $tkd 'version.json')).version
  Check (-not ($u -eq '9.9.1' -and $rec -ne '9.9.1')) 'F26 (Codex known-open.ps1): Go back with no saved version record never says "back on 9.9.1" while version.json still says 9.9.2 (2.2.18: returned 9.9.1, record 9.9.2, journal deleted)' ('returned=' + $u + ' record=' + $rec + ' err=' + $err)
  Check ($u -eq '9.9.1' -and $rec -eq '9.9.1' -and [IO.File]::ReadAllText((Join-Path $tkd 'example.ps1')) -eq 'OLD' -and -not (Test-Path (Join-Path $tkd 'previous/update-pending.json'))) 'F26: ...the saved copy''s own undo record names exactly this update, so the old files are back AND the version record is rebuilt as 9.9.1 (coherent), journal done' ('returned=' + $u + ' record=' + $rec)
}
Run-Safe 'F26 unreadable record' {
  $root = Join-Path $tmp 'undo2'; $tkd = Join-Path $root 'Toolkit'; New-Item -ItemType Directory -Force -Path $tkd | Out-Null
  [IO.File]::WriteAllText((Join-Path $tkd 'example.ps1'), 'OLD'); [IO.File]::WriteAllText((Join-Path $tkd 'version.json'), '{"version":"9.9.1"}')
  [void](Install-TkUpdate (New-Manifest '9.9.2' 'NEW') $tkd $fetchNew)
  [IO.File]::WriteAllText((Join-Path $tkd 'previous/9.9.1/version.json.prev'), '{ "vers')
  $u = $null; $err = ''; try { $u = Undo-TkUpdate $tkd } catch { $err = $_.Exception.Message }
  Check (-not $u -and $err -match 'Nothing was changed' -and [IO.File]::ReadAllText((Join-Path $tkd 'example.ps1')) -eq 'NEW' -and (Read-TkJson (Join-Path $tkd 'version.json')).version -eq '9.9.2' -and -not (Test-Path (Join-Path $tkd 'previous/update-pending.json'))) 'F26 twin: a saved version record that cannot be read -> Go back refuses BEFORE changing anything ("Nothing was changed"; 9.9.2 stays whole) (2.2.18: put the old files back under the 9.9.2 record)' ('returned=' + $u + ' err=' + $err)
}
Run-Safe 'F26 undo record mismatch' {
  $root = Join-Path $tmp 'undo3'; $tkd = Join-Path $root 'Toolkit'; New-Item -ItemType Directory -Force -Path $tkd | Out-Null
  [IO.File]::WriteAllText((Join-Path $tkd 'example.ps1'), 'OLD'); [IO.File]::WriteAllText((Join-Path $tkd 'version.json'), '{"version":"9.9.1"}')
  [void](Install-TkUpdate (New-Manifest '9.9.2' 'NEW') $tkd $fetchNew)
  Remove-Item -LiteralPath (Join-Path $tkd 'previous/9.9.1/version.json.prev') -Force
  Save-TkJson ([ordered]@{ from = '9.8.0'; to = '9.9.2'; at = 'x'; added = @() }) (Join-Path $tkd 'previous/9.9.1/undo.json')
  $u = $null; $err = ''; try { $u = Undo-TkUpdate $tkd } catch { $err = $_.Exception.Message }
  Check (-not $u -and $err -match 'Nothing was changed' -and [IO.File]::ReadAllText((Join-Path $tkd 'example.ps1')) -eq 'NEW') 'F26 twin: no saved version record and an undo record that does not name this update -> refused, nothing changed (2.2.18: went back and said 9.9.1)' ('returned=' + $u + ' err=' + $err)
}
Run-Safe 'F26 startup twin' {
  # an update that stopped half-way, whose saved copy has no version record: the start-up recovery puts the files back
  $root = Join-Path $tmp 'rec1'; $tkd = Join-Path $root 'Toolkit'; $prev = Join-Path $tkd 'previous/9.9.1'
  New-Item -ItemType Directory -Force -Path (Join-Path $prev 'Toolkit') | Out-Null
  [IO.File]::WriteAllText((Join-Path $prev 'Toolkit/example.ps1'), 'OLD'); [IO.File]::WriteAllText((Join-Path $tkd 'example.ps1'), 'NEW')
  [IO.File]::WriteAllText((Join-Path $tkd 'version.json'), '{"version":"9.9.2","previous":"9.9.1"}')
  Save-TkJson ([pscustomobject]@{ prev = $prev; from = '9.9.1'; to = '9.9.2'; added = @() }) (Join-Path $tkd 'previous/update-pending.json')
  $msg = ''; $err = ''; try { $msg = Invoke-TkStartupRecovery $tkd } catch { $err = $_.Exception.Message }
  $rec = [string](Read-TkJson (Join-Path $tkd 'version.json')).version
  Check ($rec -eq '9.9.1' -and [IO.File]::ReadAllText((Join-Path $tkd 'example.ps1')) -eq 'OLD') 'F26 startup twin (Invoke-TkStartupRecovery): the old files are put back and the version record says 9.9.1 too (2.2.18: files 9.9.1, record still 9.9.2)' ('record=' + $rec + ' msg=' + $msg + ' err=' + $err)
  Check ($msg -match 'rebuilt') 'F26 startup twin: ...and the start-up message says the version record was rebuilt' $msg
}
Run-Safe 'F26 control' {
  $root = Join-Path $tmp 'undo4'; $tkd = Join-Path $root 'Toolkit'; New-Item -ItemType Directory -Force -Path $tkd | Out-Null
  [IO.File]::WriteAllText((Join-Path $tkd 'example.ps1'), 'OLD'); [IO.File]::WriteAllText((Join-Path $tkd 'version.json'), '{"version":"9.9.1"}')
  [void](Install-TkUpdate (New-Manifest '9.9.2' 'NEW') $tkd $fetchNew)
  $u = Undo-TkUpdate $tkd
  Check ($u -eq '9.9.1' -and (Read-TkJson (Join-Path $tkd 'version.json')).version -eq '9.9.1' -and [IO.File]::ReadAllText((Join-Path $tkd 'example.ps1')) -eq 'OLD') 'control: a normal Go back with its saved version record - files and record both 9.9.1'
}

# ==============================================================================================================================
Write-Host ''
Write-Host 'Site check summary (New-TkSiteCheck, class C): red only for a problem that was read; no result = amber NOT CHECKED'
function New-Health($rec, $fw) {
  return [pscustomobject]@{ vendor = 'Hikvision'; recording = $rec; clock = [pscustomobject]@{ ok = $true; problems = @() }; firmware = $fw }
}
$recOk = [pscustomobject]@{ ok = $true; problems = @(); channels = @(); recording = 4; days_held = 30; target_days = 30 }
$fwOk = [pscustomobject]@{ ok = $true; problems = @(); devices = @() }
Run-Safe 'sitecheck no recording result' {
  $sc = New-TkSiteCheck (New-Health $null $fwOk) $null $null
  $l = @($sc.lines | Where-Object { [string]$_.t -match '^Recording' })
  Check (-not @($l | Where-Object { $_.k -eq 'red' }).Count -and @($l | Where-Object { $_.k -eq 'warn' -and $_.t -match 'NOT CHECKED' }).Count -eq 1 -and -not $sc.ok) 'site check: no recording result -> amber "Recording: NOT CHECKED", not red, not OK (2.2.18: a red "Recording: " with no reason)' (($l | ForEach-Object { $_.k + ':' + $_.t }) -join ' | ')
}
Run-Safe 'sitecheck no firmware result' {
  $sc = New-TkSiteCheck (New-Health $recOk ([pscustomobject]@{ ok = $false; problems = @(); devices = @() })) $null $null
  $l = @($sc.lines | Where-Object { [string]$_.t -match '^Firmware' })
  Check (-not @($l | Where-Object { $_.k -eq 'red' }).Count -and @($l | Where-Object { $_.k -eq 'warn' }).Count -ge 1 -and @($sc.fixes) -notcontains 'firmware') 'site check: a firmware result that names no problem -> amber "not checked", no red line, no firmware fix offered (2.2.18: red + "update firmware" offered)' (($l | ForEach-Object { $_.k + ':' + $_.t }) -join ' | ')
}
Run-Safe 'sitecheck mixed' {
  $rec = [pscustomobject]@{ ok = $false; problems = @('CH 3 not recording', 'storage NOT CHECKED (HTTP 500)'); channels = @(); recording = 3; days_held = 30; target_days = 30 }
  $sc = New-TkSiteCheck (New-Health $rec $fwOk) $null $null
  $red = @($sc.lines | Where-Object { $_.k -eq 'red' -and [string]$_.t -match '^Recording' }); $amb = @($sc.lines | Where-Object { $_.k -eq 'warn' -and [string]$_.t -match '^Recording' })
  Check ($red.Count -eq 1 -and $red[0].t -match 'CH 3 not recording' -and $red[0].t -notmatch 'NOT CHECKED' -and $amb.Count -eq 1 -and $amb[0].t -match 'NOT CHECKED') 'site check: a real problem and a part that could not be read -> the real one is red, the unread part is amber NOT CHECKED (2.2.18: both in one red line)' (($sc.lines | ForEach-Object { $_.k + ':' + $_.t }) -join ' | ')
}
Run-Safe 'sitecheck control' {
  $rec = [pscustomobject]@{ ok = $false; problems = @('CH 3 not recording'); channels = @(); recording = 3; days_held = 30; target_days = 30 }
  $fw = [pscustomobject]@{ ok = $false; problems = @('NVR on firmware with a known security hole'); devices = @() }
  $sc = New-TkSiteCheck (New-Health $rec $fw) $null $null
  Check (@($sc.lines | Where-Object { $_.k -eq 'red' -and $_.t -match 'CH 3 not recording' }).Count -eq 1 -and @($sc.lines | Where-Object { $_.k -eq 'red' -and $_.t -match 'security hole' }).Count -eq 1 -and @($sc.fixes) -contains 'firmware') 'control: problems that were read stay red (recording, firmware) and the firmware fix is still offered'
}

Run-Safe 'migration ACL unread' {
  # ToolkitMigrate (class C twin): a folder whose permissions cannot be read was taken as "not locked" and skipped without a word
  . (Join-Path $tk 'ToolkitMigrate.ps1')
  $script:icaclsN = 0
  $ops = @{ taskExists = { param($n) $false }; taskDelete = { param($n) $true }; icacls = { param([string[]]$a) $script:icaclsN++; 0 }; isLocked = { param($p) $null }
    adminUsers = { @() }; exists = { param($p) -not ([string]$p -match '(?i)ipc|upload-key|\.ps1$|\.cmd$|\.json$') }; create = { param($p) }; remove = { param($p) }; children = { param($p) @() } }
  $m = Invoke-TkMigration -Root '/r' -ToolkitDir '/r/Toolkit' -OwnerSid 'S-1-5-21-1' -Ops $ops
  Check (@($m.warnings | Where-Object { $_ -match 'NOT CHECKED' }).Count -ge 1) 'ToolkitMigrate twin (class C): folder permissions that cannot be read are reported NOT CHECKED, not taken as "no old lock" (2.2.18: skipped silently)' ((@($m.warnings) + @($m.log)) -join ' | ')
}

Run-Safe 'Install-Toolkit pending guard' {
  # 2.2.19 (lead, F23 twin in the installer): a real run of Install-Toolkit.ps1 onto a PC whose earlier update is still half-way
  $isrc = Join-Path $tmp 'inst-src'; New-Item -ItemType Directory -Force -Path $isrc | Out-Null
  foreach ($d in @('Toolkit', 'FixNVR', 'CamReset', 'NetCheck')) { Copy-Item -LiteralPath (Join-Path $repo $d) -Destination $isrc -Recurse -Force }
  $iroot = Join-Path $tmp 'inst-root/WireIt'; $itk = Join-Path $iroot 'Toolkit'; New-Item -ItemType Directory -Force -Path (Join-Path $itk 'previous') | Out-Null
  [IO.File]::WriteAllText((Join-Path $itk 'ToolkitCore.ps1'), 'ORIGINAL-HALF-WAY'); [IO.File]::WriteAllText((Join-Path (Join-Path $itk 'previous') 'update-pending.json'), '{"from":"2.2.18","to":"2.2.19"}')
  $psx = (Get-Process -Id $PID).Path
  $io = & $psx -NoProfile -File (Join-Path $isrc 'Toolkit/Install-Toolkit.ps1') -Root $iroot -NoShortcut 2>&1 | Out-String; $ic = $LASTEXITCODE
  Check ($ic -eq 5 -and $io -match 'INSTALL STOPPED - nothing was changed' -and [IO.File]::ReadAllText((Join-Path $itk 'ToolkitCore.ps1')) -eq 'ORIGINAL-HALF-WAY' -and (Test-Path (Join-Path (Join-Path $itk 'previous') 'update-pending.json'))) 'F23 twin (Install-Toolkit.ps1): with an update still half-way (previous\update-pending.json) the installer stops, changes no file and keeps the record (2.2.18 copied over it)' ('exit ' + $ic + ' ' + ($io -replace '\s+', ' '))
  Remove-Item -LiteralPath (Join-Path (Join-Path $itk 'previous') 'update-pending.json') -Force
  $io2 = & $psx -NoProfile -File (Join-Path $isrc 'Toolkit/Install-Toolkit.ps1') -Root $iroot -NoShortcut -PlanOnly 2>&1 | Out-String; $ic2 = $LASTEXITCODE
  Check ($ic2 -eq 0 -and $io2 -match '"updatePending":\s*false') 'control: with no half-way record the installer plan goes ahead (exit 0)' ('exit ' + $ic2 + ' ' + ($io2 -replace '\s+', ' '))
}

Deferred 'real devices: the SADP reset resume / import on real Hikvision cameras (MAC/serial as SADP reports them)'
Deferred 'Windows: a reset record / pictures / outbox folder that Windows refuses to write (ACLs, a full disk), Windows PowerShell 5.1'
}
finally { if (-not $isWin) { & chmod -R u+w $tmp 2>$null }; Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
Write-Host ''
Write-Host ('Test-Fix2219Sweep: ' + $script:pass + ' passed, ' + $script:fail + ' failed, ' + $script:deferred + ' deferred')
if ($script:fail) { exit 1 }
exit 0
