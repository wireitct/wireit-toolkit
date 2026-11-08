<#
 HikResetFlow.ps1 - WireIt Toolkit 2.1: Hikvision's official password reset, as ONE automatic flow.
   find (SADP, any subnet) -> export each device's request file -> fill + attach on Hikvision's reset page (you type the picture code)
   -> watch the reply mailbox -> match each returned unlock file to its serial -> import it (SADP) with the site password -> check the login.
 The state of every device is kept in a small file (state.json) so the flow can stop (the reply takes time) and carry on later:
   exported -> submitted -> replied -> imported -> verified            (or: failed, with the reason)
 Official path only. No guessing, no default passwords, no exploits, nothing sent anywhere except Hikvision's own page and your own mailbox.
 Dot-sourced by HikReset.ps1 (command line), FixSite.ps1 (the wizard) and the tests.
#>
$here0 = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here0 'HikSadp.ps1')
. (Join-Path $here0 'HikPortal.ps1')
. (Join-Path $here0 'HikMail.ps1')

$script:HkSay = { param($t, $c) Write-Host $t }
$script:HkAsk = { param($t) Read-Host $t }
function Hk-Say([string]$t, [string]$c = '') { & $script:HkSay $t $c }
function Hk-Ask([string]$t) { return (& $script:HkAsk $t) }
$script:HkValidHours = 48

# ---------------- state ----------------
function Read-HikState([string]$Path) {
  if (Test-Path -LiteralPath $Path) { try { $o = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json; if ($o -and $o.PSObject.Properties['devices']) { $o.devices = @($o.devices); return $o } } catch {} }
  return [pscustomobject]@{ version = 1; site = ''; created = (Get-Date -Format 's'); devices = @() }
}
function Save-HikState([string]$Path, $State) {
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
  ($State | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $Path -Encoding UTF8
}
function Get-HikStateDevice($State, [string]$Serial) { foreach ($d in @($State.devices)) { if ($d.serial -eq $Serial) { return $d } }; return $null }
function Set-HikStateField($d, [string]$Name, $Value) { if ($d.PSObject.Properties[$Name]) { $d.$Name = $Value } else { $d | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force } }
function Add-HikStateDevice($State, $Dev, [string]$File, [string]$BootTime) {
  $d = Get-HikStateDevice $State $Dev.serial
  $now = Get-Date
  $row = [ordered]@{ serial = $Dev.serial; shortSerial = $Dev.shortSerial; model = $Dev.model; mac = $Dev.mac; ip = $Dev.ip; kind = $Dev.kind; salt = $Dev.salt; encrypt = [bool]$Dev.encrypt; requestFile = $File; bootTime = $BootTime
    exportedAt = $now.ToString('s'); validUntil = $now.AddHours($script:HkValidHours).ToString('s'); status = 'exported'; submittedAt = ''; replyFile = ''; replyFrom = ''; importedAt = ''; verifiedAt = ''; note = '' }
  if ($d) { foreach ($k in $row.Keys) { Set-HikStateField $d $k $row[$k] }; return $d }
  $State.devices = @($State.devices) + @([pscustomobject]$row); return (Get-HikStateDevice $State $Dev.serial)
}

# ---------------- 1. find + export ----------------
# $Devices = Find-HikSadp result. A device that is not activated has no password to reset: it is only activated (the caller does that).
function Export-HikRequests($Devices, [string]$OutDir, $State, [string]$StatePath, [switch]$Redo) {
  $made = @()
  foreach ($dev in @($Devices | Where-Object { $_.activated })) {
    $cur = Get-HikStateDevice $State $dev.serial
    if ($cur -and -not $Redo -and $cur.status -in @('exported', 'submitted', 'replied') -and (Test-Path -LiteralPath $cur.requestFile) -and ([datetime]$cur.validUntil) -gt (Get-Date) -and $cur.bootTime -eq $dev.bootTime) {
      Hk-Say ('  ' + $dev.model + ' ' + $dev.ip + ': request file from ' + ([datetime]$cur.exportedAt).ToString('h:mm tt') + ' is still good - not asking the device again (a new one would cancel it).'); $made += $cur; continue
    }
    $e = Request-HikResetExport $dev
    if (-not $e.ok) { Hk-Say ('  ' + $dev.model + ' ' + $dev.ip + ': could not read its request code - ' + $e.error) 'Yellow'; if ($cur) { Set-HikStateField $cur 'note' $e.error }; continue }
    $f = Save-HikResetFile $dev $e $OutDir
    $d = Add-HikStateDevice $State $dev $f $dev.bootTime
    Save-HikState $StatePath $State
    Hk-Say ('  ' + $dev.model + ' ' + $dev.ip + '  serial ' + $dev.serial + ': request file saved (' + (Split-Path -Leaf $f) + ')') 'Green'
    $made += $d
  }
  return $made
}

# ---------------- 2. Hikvision's page ----------------
function Submit-HikRequests($State, [string]$StatePath, $Form, [int]$PerDeviceTimeoutSec = 900) {
  $todo = @($State.devices | Where-Object { $_.status -eq 'exported' })
  if (-not $todo.Count) { Hk-Say 'Nothing waiting to be sent to Hikvision.'; return @() }
  $sent = @(); $n = 0
  $exe = Find-HikBrowser
  foreach ($d in $todo) {
    $n++
    if (-not (Test-Path -LiteralPath $d.requestFile)) { Set-HikStateField $d 'note' 'request file missing'; continue }
    if (([datetime]$d.validUntil) -lt (Get-Date)) { Set-HikStateField $d 'status' 'expired'; Set-HikStateField $d 'note' 'older than 48 hours - export again'; Save-HikState $StatePath $State; Hk-Say ($d.model + ' ' + $d.ip + ': the request file is older than 48 hours - it needs a new export.') 'Yellow'; continue }
    Hk-Say ''
    Hk-Say ('[' + $n + '/' + $todo.Count + '] ' + $d.model + ' ' + $d.ip + ' (serial ' + $d.serial + ', form serial ' + $d.shortSerial + ')') 'Cyan'
    $ok = $false
    if ($exe) {
      $s = Start-HikBrowserSession $script:PortalUrl
      if ($s) {
        try {
          if (-not (Wait-PortalForm $s 60)) { Hk-Say 'Hikvision''s page did not load the form. Check the internet on this PC.' 'Yellow' }
          else {
            $r = Fill-HikPortalForm $s $Form $d $d.requestFile
            $bad = @(Test-PortalFilled $r $d)
            if ($bad.Count) { Hk-Say ('  Form filled, but check: ' + ($bad -join '; ')) 'Yellow' } else { Hk-Say ('  Form filled in: ' + $Form.firstName + ' ' + $Form.lastName + ', ' + $Form.company + ', ' + $Form.email + ', serial ' + $d.shortSerial + ', file attached.') 'Green' }
            Hk-Say '  YOUR STEP: type the picture code in the browser window and press Submit. (The code is there to tell a person from a program, so the Toolkit leaves it to you.)' 'Cyan'
            $res = Wait-PortalSubmitted $s $PerDeviceTimeoutSec $null ({ $f = @(Restore-PortalFields $s $Form $d); if ($f.Count) { Hk-Say ('  (the page cleared ' + ($f -join ', ') + ' - filled again)') } }.GetNewClosure())
            if ($res -eq 'submitted') { $ok = $true; Set-HikStateField $d 'status' 'submitted'; Set-HikStateField $d 'submittedAt' (Get-Date -Format 's'); Hk-Say ('  Hikvision accepted it. The reply goes to ' + $Form.email) 'Green' }
            else { Hk-Say ('  Not submitted (' + $res + '). Run it again to retry this one.') 'Yellow' }
          }
        } finally { Stop-HikBrowserSession $s }
      } else { Hk-Say '  Could not open the browser window.' 'Yellow' }
    }
    if (-not $ok -and -not $exe) {
      # no Chrome/Edge: open the page in whatever browser is default, with the values on screen (copy + paste)
      Hk-Say ('  No Chrome or Edge found. Opening the page in your browser. Fill it with: ' + $Form.firstName + ' ' + $Form.lastName + ' / ' + $Form.email + ' / ' + $Form.company + ' / ' + $Form.state + ' / ' + $Form.zip + ' / ' + $Form.businessType + ' / serial ' + $d.shortSerial + ' / model ' + $d.model + ' / file ' + $d.requestFile) 'Yellow'
      try { Start-Process $script:PortalUrl } catch {}
      $a = Hk-Ask '  When Hikvision says it is sent, press Enter (S = skip this one)'
      if ($a -notmatch '^(?i)s') { $ok = $true; Set-HikStateField $d 'status' 'submitted'; Set-HikStateField $d 'submittedAt' (Get-Date -Format 's') }
    }
    Save-HikState $StatePath $State
    if ($ok) { $sent += $d }
  }
  return $sent
}

# ---------------- registering request files that already exist (made by SADP / HiTools / an earlier run) ----------------
# SADP's own export is one line: <code><DeviceSN>. The serial at the end names the device; $Devices (Find-HikSadp) gives the rest.
function Register-HikRequestFiles($State, [string]$Dir, $Devices, [string]$StatePath) {
  $added = @()
  foreach ($f in @(Get-ChildItem -LiteralPath $Dir -File -Filter *.xml -ErrorAction SilentlyContinue)) {
    $t = ''; try { $t = [IO.File]::ReadAllText($f.FullName).Trim() } catch { continue }
    $dev = $null; foreach ($d in @($Devices)) { if ($d.serial -and $t.EndsWith([string]$d.serial)) { $dev = $d; break } }
    if (-not $dev) { Hk-Say ('  ' + $f.Name + ': no device here has the serial this file ends with - skipped.') 'Yellow'; continue }
    $cur = Get-HikStateDevice $State $dev.serial
    if ($cur -and $cur.requestFile -eq $f.FullName) { $added += $cur; continue }
    $d2 = Add-HikStateDevice $State $dev $f.FullName $dev.bootTime
    Set-HikStateField $d2 'exportedAt' $f.LastWriteTime.ToString('s'); Set-HikStateField $d2 'validUntil' $f.LastWriteTime.AddHours($script:HkValidHours).ToString('s')
    $added += $d2
  }
  Save-HikState $StatePath $State
  return $added
}

# ---------------- 3. the reply ----------------
function Get-HikReplyMessages($Cfg, [string]$SecretDir, [string]$ReplyDir, [datetime]$Since) {
  $msgs = @()
  $mode = [string]$Cfg.mail.mode
  if ($mode -eq 'imap') {
    $pw = Get-HikMailPassword $SecretDir
    if (-not $pw) { Hk-Say '  The reply mailbox password is not saved on this PC yet (run "Set mail password"); looking only in the replies folder.' 'Yellow' }
    else { try { $msgs += @(Get-HikImapMessages $Cfg.mail $pw ([int]$(if ($Cfg.mail.days) { $Cfg.mail.days } else { 4 })) $(if ($Cfg.mail.fromLike) { [string]$Cfg.mail.fromLike } else { 'hikvision' })) } catch { Hk-Say ('  Mailbox check failed: ' + $_.Exception.Message) 'Yellow' } }
  }
  $msgs += @(Get-HikFolderMessages $ReplyDir $Since)
  return $msgs
}
# looks for replies for every 'submitted' device, saves each matched file under replies\<serial>.xml, marks the device 'replied'.
function Receive-HikReplies($State, [string]$StatePath, $Cfg, [string]$SecretDir, [string]$ReplyDir) {
  $pend = @($State.devices | Where-Object { $_.status -in @('submitted', 'replied') })
  if (-not $pend.Count) { return [pscustomobject]@{ got = @(); unmatched = @() } }
  $since = (Get-Date).AddDays(-4); try { $since = ([datetime](@($pend | ForEach-Object { $_.exportedAt } | Sort-Object)[0])).AddHours(-1) } catch {}
  $msgs = Get-HikReplyMessages $Cfg $SecretDir $ReplyDir $since
  $m = Find-HikReplyMatches $pend $msgs
  $got = @()
  New-Item -ItemType Directory -Force -Path $ReplyDir | Out-Null
  foreach ($x in $m.matched) {
    $d = $x.device
    # our own request file is not a reply (folder mode could see it); a reply is a different file
    $own = ''; try { $own = [IO.File]::ReadAllText($d.requestFile).Trim() } catch {}
    if ($own -and (Hm-Latin1).GetString($x.bytes).Trim() -eq $own) { continue }
    $dest = Join-Path $ReplyDir ('reply-' + ($d.serial -replace '[^A-Za-z0-9\-]', '_') + '.xml')
    [IO.File]::WriteAllBytes($dest, $x.bytes)
    Set-HikStateField $d 'status' 'replied'; Set-HikStateField $d 'replyFile' $dest; Set-HikStateField $d 'replyFrom' ([string]$x.mail); $got += $d
    Hk-Say ('  Reply for ' + $d.model + ' ' + $d.ip + ' (serial ' + $d.serial + ') found, matched by ' + $x.how + '.') 'Green'
  }
  Save-HikState $StatePath $State
  return [pscustomobject]@{ got = $got; unmatched = @($m.unmatched) }
}

# ---------------- 4. import + check ----------------
# $VerifyLogin = scriptblock { param($ip, $password) -> $true when the password logs in } (the caller supplies Test-FsLogin).
# $FindIp = scriptblock { param($dev) -> the device's current IP (it may have moved) }.
function Import-HikReplies($State, [string]$StatePath, [string]$NewPassword, [scriptblock]$VerifyLogin, [string]$Only = '') {
  $done = @()
  foreach ($d in @($State.devices | Where-Object { $_.status -eq 'replied' -and (-not $Only -or $_.serial -like ('*' + $Only + '*') -or $_.ip -eq $Only -or $_.mac -eq $Only) })) {
    Hk-Say ''; Hk-Say ('Importing the unlock file into ' + $d.model + ' ' + $d.ip + ' (serial ' + $d.serial + ')') 'Cyan'
    $live = @(Find-HikSadp 3 | Where-Object { $_.mac -eq $d.mac })[0]
    if (-not $live) { Hk-Say '  The device does not answer on the network right now.' 'Yellow'; Set-HikStateField $d 'note' 'not answering'; continue }
    if ($d.bootTime -and $live.bootTime -and $live.bootTime -ne $d.bootTime) { Hk-Say '  This device restarted after the request file was made, so Hikvision''s file no longer fits it. It needs a new request.' 'Red'; Set-HikStateField $d 'status' 'expired'; Set-HikStateField $d 'note' 'restarted since the request'; Save-HikState $StatePath $State; continue }
    if (([datetime]$d.validUntil) -lt (Get-Date)) { Hk-Say '  The file is older than 48 hours - Hikvision''s files stop working then. It needs a new request.' 'Red'; Set-HikStateField $d 'status' 'expired'; Save-HikState $StatePath $State; continue }
    $u = Read-HikUnlock $d.replyFile
    $r = Import-HikUnlock $live $u $NewPassword
    if ($r.ok) {
      Set-HikStateField $d 'status' 'imported'; Set-HikStateField $d 'importedAt' (Get-Date -Format 's'); Save-HikState $StatePath $State
      Start-Sleep -Seconds 3
      $ip = $live.ip; $chk = $false
      for ($i = 0; $i -lt 6 -and -not $chk; $i++) { $now = @(Find-HikSadp 2 | Where-Object { $_.mac -eq $d.mac })[0]; if ($now) { $ip = $now.ip }; try { $chk = [bool](& $VerifyLogin $ip $NewPassword) } catch {}; if (-not $chk) { Start-Sleep -Seconds 4 } }
      if ($chk) { Set-HikStateField $d 'status' 'verified'; Set-HikStateField $d 'verifiedAt' (Get-Date -Format 's'); Hk-Say ('  Reset done. The site password logs in on ' + $ip + '.') 'Green'; $done += $d }
      else { Hk-Say ('  The device accepted the file, but the site password does not log in yet on ' + $ip + '. Check it in a minute.') 'Yellow' }
    } else {
      Hk-Say ('  The import did not work (' + $r.error + ').') 'Yellow'
      Set-HikStateField $d 'note' ('import: ' + $r.error)
      # last resort, still the official path: SADP's own "Forgot password > Import file" with the file ready
      Hk-Say ('  Finish this one in SADP: tick the device, Forgot password, Import file, pick ' + $d.replyFile + ', type the site password.') 'Yellow'
    }
    Save-HikState $StatePath $State
  }
  return $done
}
function Format-HikStatus($State) {
  $L = @()
  foreach ($d in @($State.devices)) { $L += ('{0,-12} {1,-16} {2,-18} {3}{4}' -f $d.model, $d.ip, $d.serial, $d.status, $(if ($d.note) { ' (' + $d.note + ')' } else { '' })) }
  return $L
}

# ---------------- config ----------------
function Get-HikConfig($CfgAll, [string]$SecretDir) {
  $mail = [pscustomobject]@{ mode = 'folder'; host = 'imap.gmail.com'; port = 993; ssl = $true; user = ''; folder = 'INBOX'; days = 4; fromLike = 'hikvision' }
  $wait = 10; $replyDir = ''
  if ($CfgAll -and $CfgAll.PSObject.Properties['hikReset']) {
    $h = $CfgAll.hikReset
    if ($h.PSObject.Properties['mail']) { foreach ($p in $h.mail.PSObject.Properties) { if ($mail.PSObject.Properties[$p.Name]) { $mail.($p.Name) = $p.Value } else { $mail | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force } } }
    if ($h.PSObject.Properties['waitMinutes']) { $wait = [int]$h.waitMinutes }
    if ($h.PSObject.Properties['replyDir']) { $replyDir = [string]$h.replyDir }
  }
  # imap is used only when a mailbox user is set AND its password is saved on this PC; otherwise the replies folder
  if ($mail.mode -eq 'imap' -and (-not $mail.user -or -not (Get-HikMailPassword $SecretDir))) { $mail.mode = 'folder' }
  $form = $null; if ($CfgAll -and $CfgAll.PSObject.Properties['form']) { $form = $CfgAll.form }
  return [pscustomobject]@{ form = $form; mail = $mail; waitMinutes = $wait; replyDir = $replyDir }
}

# ---------------- the whole thing for a list of devices ----------------
# $Targets: objects with .mac (the devices whose password is unknown). Returns { fixed = @(macs); pending = @({ mac; reason }) }.
function Invoke-HikResetStage {
  param($Targets, [string]$SitePassword, [string]$StateDir, $Config, [string]$SecretDir, [scriptblock]$VerifyLogin, [int]$WaitMinutes = 10, [int]$SubmitTimeoutSec = 900)
  $statePath = Join-Path $StateDir 'state.json'; $reqDir = Join-Path $StateDir 'requests'
  $repDir = $(if ($Config.replyDir) { $Config.replyDir } else { Join-Path $StateDir 'replies' })
  New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
  $state = Read-HikState $statePath
  $want = @{}; foreach ($t in @($Targets)) { $m = ConvertTo-SadpMac ([string]$t.mac); if ($m) { $want[$m] = $t } }
  Hk-Say 'Finding the Hikvision devices (any IP range)...'
  $devs = @(Find-HikSadp 4 | Where-Object { $want.ContainsKey($_.mac) })
  $fixed = @(); $pending = @()
  foreach ($m in $want.Keys) { if (-not @($devs | Where-Object { $_.mac -eq $m }).Count) { $pending += [pscustomobject]@{ mac = $m; reason = 'not seen on the network (check power and cable)' } } }
  $todo = @($devs | Where-Object { $_.activated })
  # an old state (reply still waiting from an earlier run) is picked up as it is
  Hk-Say ('Asking each of the ' + $todo.Count + ' device(s) for its reset request file (same as SADP "Forgot password > Export file")...')
  [void](Export-HikRequests $todo $reqDir $state $statePath)
  $form = $Config.form
  if (-not $form) { return [pscustomobject]@{ fixed = @(); pending = @($pending) + @($todo | ForEach-Object { [pscustomobject]@{ mac = $_.mac; reason = 'config.json has no "form" (name, email, company)' } }) } }
  $forMine = { param($st) @($st.devices | Where-Object { $want.ContainsKey($_.mac) }) }
  [void](Submit-HikRequests $state $statePath $form $SubmitTimeoutSec)
  $end = (Get-Date).AddMinutes($WaitMinutes)
  do {
    $r = Receive-HikReplies $state $statePath $Config $SecretDir $repDir
    foreach ($u in @($r.unmatched)) { Hk-Say ('  A file from Hikvision matches no device here: ' + $u.name + ' (' + $u.why + '). It is not used.') 'Yellow' }
    $waiting = @(& $forMine $state | Where-Object { $_.status -eq 'submitted' })
    if (-not $waiting.Count -or (Get-Date) -ge $end) { break }
    Hk-Say ('  Waiting for Hikvision''s reply (' + $waiting.Count + ' device(s)); looking again in a minute. You can press Fix the site again later: it carries on from here.')
    Start-Sleep -Seconds 60
  } while ($true)
  $ready = @(& $forMine $state | Where-Object { $_.status -eq 'replied' })
  if ($ready.Count) { $done = @(Import-HikReplies $state $statePath $SitePassword $VerifyLogin); foreach ($d in $done) { $fixed += $d.mac } }
  foreach ($d in @(& $forMine $state)) {
    if ($fixed -contains $d.mac) { continue }
    $why = switch ($d.status) { 'submitted' { 'sent to Hikvision, waiting for the unlock file by email (it can take a few hours; press Fix the site again then - the device must NOT restart meanwhile)' } 'exported' { 'request file made, not sent to Hikvision yet' } 'replied' { 'unlock file arrived but the import did not work' + $(if ($d.note) { ' (' + $d.note + ')' } else { '' }) } 'expired' { 'the request is no longer valid (' + $d.note + '): it needs a new one' } default { [string]$d.status } }
    $pending += [pscustomobject]@{ mac = $d.mac; reason = $why }
  }
  return [pscustomobject]@{ fixed = @($fixed); pending = @($pending) }
}
