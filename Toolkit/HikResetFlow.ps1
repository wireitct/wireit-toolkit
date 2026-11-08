<#
 HikResetFlow.ps1 - WireIt Toolkit 2.2: Hikvision's official password reset, as ONE automatic flow.
   find (SADP, any subnet) -> export each device's request file -> fill + attach on Hikvision's reset page (you type the picture code)
   -> ask the reply relay (HTTPS, by serial; no mail password on the PC) and the "I got Hik's email" drops -> match each returned unlock file to its serial -> import it (SADP) with the site password -> check the login.
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
$script:HkPortalHook = $null   # 2.2.0: set by Fix this site when it runs in the background (FixSiteRunner)
$script:HkStatus = $null       # 2.2.0: gets the waiting state for the screen
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
function Submit-HikRequests($State, [string]$StatePath, $Form, [int]$PerDeviceTimeoutSec = 900, $Only = $null) {
  # 2.2.1 (review H7): $Only = the serials this run may act on (the approved targets); an old saved device outside it is left alone
  $todo = @($State.devices | Where-Object { $_.status -eq 'exported' -and ($null -eq $Only -or @($Only) -contains [string]$_.serial) })
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
    if ($script:HkPortalHook) {
      # 2.2.0: Fix this site runs in the background (no screen): the Toolkit window on the tech's own login opens Hikvision's page for this device
      Hk-Say '  YOUR STEP: Hikvision''s page opens on this screen, filled in. Slide the picture check and press Submit. (The check is there to tell a person from a program, so the Toolkit leaves it to you.)' 'Cyan'
      $res = 'failed'; try { $res = [string](& $script:HkPortalHook $d $Form $PerDeviceTimeoutSec) } catch { $res = 'failed: ' + $_.Exception.Message }
      if ($res -eq 'submitted') { $ok = $true; Set-HikStateField $d 'status' 'submitted'; Set-HikStateField $d 'submittedAt' (Get-Date -Format 's'); Hk-Say ('  Hikvision accepted it. The reply goes to ' + $Form.email) 'Green' }
      else { Hk-Say ('  Not submitted (' + $res + '). Press Fix this site again to retry this one.') 'Yellow' }
      Save-HikState $StatePath $State
      if ($ok) { $sent += $d }
      continue
    }
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
# 2.2.0: the relay (HTTPS, by serial) first, then the folders: the reset's replies folder and inbox\hik (the "I got Hik's email" button).
# $script:HkRelayStatus says what the last relay check found, for the screen: state = off | ok | failed; msg; at.
$script:HkRelayStatus = [pscustomobject]@{ state = 'off'; msg = ''; at = '' }
$script:HkRelayNext = [datetime]::MinValue
function Get-HikReplyMessages($Cfg, [string]$ToolkitDir, [string]$ReplyDir, [datetime]$Since, $Pending = @(), [string]$InboxDir = '', [switch]$ForceRelay) {
  $msgs = @()
  $relay = $null; if ($Cfg -and $Cfg.PSObject.Properties['relay']) { $relay = $Cfg.relay }
  if ($relay -and [string]$relay.url -and @($Pending).Count -and ($ForceRelay -or (Get-Date) -ge $script:HkRelayNext)) {
    $every = 60; if ($relay.PSObject.Properties['everySec'] -and [int]$relay.everySec -gt 0) { $every = [int]$relay.everySec }
    $script:HkRelayNext = (Get-Date).AddSeconds($every)
    $key = Get-HikRelayKey $ToolkitDir
    $bad = ''
    foreach ($d in @($Pending)) {
      $r = Get-HikRelayReply $relay $key $d
      if ($r.state -eq 'found') { $msgs += $r.message } elseif ($r.state -eq 'failed') { $bad = $r.msg; break }
    }
    $script:HkRelayStatus = [pscustomobject]@{ state = $(if ($bad) { 'failed' } else { 'ok' }); msg = $bad; at = (Get-Date -Format 's') }
  } elseif (-not $relay -or -not [string]$relay.url) { $script:HkRelayStatus = [pscustomobject]@{ state = 'off'; msg = 'no reply relay set up for this PC'; at = (Get-Date -Format 's') } }
  $msgs += @(Get-HikFolderMessages $ReplyDir $Since)
  if ($InboxDir) { $msgs += @(Get-HikFolderMessages $InboxDir $Since) }
  return $msgs
}
# looks for replies for every 'submitted' device, saves each matched file under replies\reply-<serial>.xml, marks the device 'replied'.
# A file taken from inbox\hik is removed from there once it is saved (it is never used twice).
function Receive-HikReplies($State, [string]$StatePath, $Cfg, [string]$ToolkitDir, [string]$ReplyDir, [string]$InboxDir = '', [switch]$ForceRelay) {
  $pend = @($State.devices | Where-Object { $_.status -in @('submitted', 'replied') })
  if (-not $pend.Count) { return [pscustomobject]@{ got = @(); unmatched = @() } }
  $since = (Get-Date).AddDays(-4); try { $since = ([datetime](@($pend | ForEach-Object { $_.exportedAt } | Sort-Object)[0])).AddHours(-1) } catch {}
  $msgs = @(Get-HikReplyMessages $Cfg $ToolkitDir $ReplyDir $since @($pend | Where-Object { $_.status -eq 'submitted' }) $InboxDir -ForceRelay:$ForceRelay)
  $m = Find-HikReplyMatches $pend $msgs
  $got = @()
  New-Item -ItemType Directory -Force -Path $ReplyDir | Out-Null
  foreach ($x in $m.matched) {
    $d = $x.device
    # our own request file is not a reply (folder mode could see it); a reply is a different file
    $own = ''; try { $own = [IO.File]::ReadAllText($d.requestFile).Trim() } catch {}
    if ($own -and (Hm-Latin1).GetString($x.bytes).Trim() -eq $own) { continue }
    $dest = Join-Path $ReplyDir ('reply-' + ($d.serial -replace '[^A-Za-z0-9\-]', '_') + '.xml')
    if ($x.src -and $x.src -eq $dest) { continue }   # the file saved by an earlier look
    if ($d.status -eq 'replied' -and (Test-Path -LiteralPath $dest)) { try { if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($dest)) -eq [Convert]::ToBase64String([byte[]]$x.bytes)) { if ($InboxDir -and [string]$x.src -and ([string]$x.src).StartsWith($InboxDir)) { Remove-Item -LiteralPath $x.src -Force -ErrorAction SilentlyContinue }; continue } } catch {} }
    [IO.File]::WriteAllBytes($dest, $x.bytes)
    Set-HikStateField $d 'status' 'replied'; Set-HikStateField $d 'replyFile' $dest; Set-HikStateField $d 'replyFrom' ([string]$x.mail); $got += $d
    $how = $(if ([string]$x.src -like 'relay:*') { 'the reply mailbox' } elseif ($InboxDir -and [string]$x.src -and ([string]$x.src).StartsWith($InboxDir)) { 'the "I got Hik''s email" button' } else { 'the replies folder' })
    Hk-Say ('  Reply for ' + $d.model + ' ' + $d.ip + ' (serial ' + $d.serial + ') found in ' + $how + ', matched by ' + $x.how + '.') 'Green'
    if ($InboxDir -and [string]$x.src -and ([string]$x.src).StartsWith($InboxDir)) { Remove-Item -LiteralPath $x.src -Force -ErrorAction SilentlyContinue }
  }
  Save-HikState $StatePath $State
  return [pscustomobject]@{ got = $got; unmatched = @($m.unmatched) }
}
# the devices still waiting for Hikvision, for the "I got Hik's email" button (inbox\hik\waiting.json; no passwords, no codes)
function Save-HikWaitingList([string]$InboxDir, $State, [string]$Site, [string]$ReplyTo = '') {
  if (-not $InboxDir) { return }
  try {
    New-Item -ItemType Directory -Force -Path $InboxDir | Out-Null
    $w = @($State.devices | Where-Object { $_.status -eq 'submitted' } | ForEach-Object { [ordered]@{ serial = [string]$_.serial; shortSerial = [string]$_.shortSerial; model = [string]$_.model; ip = [string]$_.ip; site = $Site; submittedAt = [string]$_.submittedAt } })
    $f = Join-Path $InboxDir 'waiting.json'
    $old = @(); if (Test-Path -LiteralPath $f) { try { $old = @((Get-Content -LiteralPath $f -Raw | ConvertFrom-Json).devices | Where-Object { $_ -and [string]$_.site -ne $Site }) } catch {} }
    $all = @($old) + @($w)
    ([ordered]@{ updated = (Get-Date -Format 's'); replyTo = $ReplyTo; devices = $all } | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $f -Encoding UTF8
  } catch {}
}
# one plain line for the screen about where the reply stands (the waiting message, or why the mailbox could not be checked)
function Format-HikWaitLine($Cfg, [int]$Count, [int]$MinutesLeft) {
  $to = $(if ($Cfg.replyTo) { [string]$Cfg.replyTo } else { 'the email on the form' })
  $st = $script:HkRelayStatus
  $btn = 'Got the email yourself? Press "I got Hik''s email" and drag the attachment in or paste the code.'
  if (-not $Cfg.relay -or -not [string]$Cfg.relay.url -or $st.state -eq 'off') { return [pscustomobject]@{ color = 'Yellow'; text = ('Waiting for Hikvision''s email (' + $Count + ' device(s)). This PC has no reply mailbox set up, so it cannot read the email by itself. When it comes to ' + $to + ', press "I got Hik''s email" and drag the attachment in or paste the code.') } }
  if ($st.state -eq 'failed') { return [pscustomobject]@{ color = 'Yellow'; text = ('Could not check the reply mailbox: ' + $st.msg + '. It keeps trying every minute. ' + $btn) } }
  $at = ''; try { $at = ([datetime]$st.at).ToString('h:mm tt') } catch {}
  return [pscustomobject]@{ color = 'Cyan'; text = ('Waiting for Hikvision''s email to ' + $to + ' (' + $Count + ' device(s)). Checked the mailbox at ' + $at + ': not there yet. Looking every minute for ' + $MinutesLeft + ' more min; it carries on by itself when it comes. ' + $btn) }
}

# ---------------- 4. import + check ----------------
# $VerifyLogin = scriptblock { param($ip, $password) -> $true when the password logs in } (the caller supplies Test-FsLogin).
# $FindIp = scriptblock { param($dev) -> the device's current IP (it may have moved) }.
function Import-HikReplies($State, [string]$StatePath, [string]$NewPassword, [scriptblock]$VerifyLogin, [string]$Only = '', $OnlySerials = $null) {
  $done = @()
  foreach ($d in @($State.devices | Where-Object { $_.status -eq 'replied' -and ($null -eq $OnlySerials -or @($OnlySerials) -contains [string]$_.serial) -and (-not $Only -or $_.serial -like ('*' + $Only + '*') -or $_.ip -eq $Only -or $_.mac -eq $Only) })) {
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
# 2.2.0: "hikReset": { "relay": { "url": "", "address": "hikreset@wireitct.com", "everySec": 60 }, "waitMinutes": 15, "replyDir": "" }
# No url (or an empty config) = no relay: the flow waits with the "I got Hik's email" button only, and the form keeps config "form.email".
# With a url, Hikvision's form gets relay.address as the email, so the reply lands where the relay reads it.
$script:HkDefaultForm = [ordered]@{ firstName = 'Moshe'; lastName = 'Reichman'; email = 'moshe@wireitct.com'; company = 'WireIt CT LLC'; state = 'Connecticut'; zip = '06710'; businessType = 'Installer' }
# 2.2.1 (review M5): what the official reset still needs, in plain words, said BEFORE the run starts (empty = ready)
function Get-HikReadiness($Cfg, [string]$ToolkitDir = '') {
  $w = @()
  $f = Get-HikFormFor $Cfg
  if (-not $f -or -not [string]$f.email -or -not [string]$f.firstName) { $w += 'Hikvision''s form needs a name and an email (config.json "form").' }
  if (-not [string]$Cfg.relay.url) { $w += 'no reply relay is set up on this PC: when Hikvision''s email comes, press "I got Hik''s email" (the reply goes to ' + $(if ($f) { [string]$f.email } else { 'the form''s email' }) + ').' }
  elseif ($ToolkitDir -and -not (Get-HikRelayKey $ToolkitDir)) { $w += 'this PC has no upload key, so the reply relay cannot be asked (an admin runs "Set upload key.cmd" once); until then use "I got Hik''s email".' }
  try { if (-not (Find-HikBrowser)) { $w += 'Chrome or Edge is not on this PC: Hikvision''s page cannot open here.' } } catch {}
  return @($w)
}
function Get-HikConfig($CfgAll, [string]$ToolkitDir = '') {
  $relay = [pscustomobject]@{ url = ''; address = 'hikreset@wireitct.com'; everySec = 60 }
  $wait = 15; $replyDir = ''
  if ($CfgAll -and $CfgAll.PSObject.Properties['hikReset'] -and $CfgAll.hikReset) {
    $h = $CfgAll.hikReset
    if ($h.PSObject.Properties['relay'] -and $h.relay) { foreach ($p in $h.relay.PSObject.Properties) { if ($relay.PSObject.Properties[$p.Name]) { $relay.($p.Name) = $p.Value } } }
    if ($h.PSObject.Properties['waitMinutes'] -and [int]$h.waitMinutes -gt 0) { $wait = [int]$h.waitMinutes }
    if ($h.PSObject.Properties['replyDir']) { $replyDir = [string]$h.replyDir }
  }
  if ([string]$relay.url -and -not (Test-HikRelayUrl ([string]$relay.url))) { $relay.url = '' }   # http:// or junk = off (never send the key in clear)
  if (-not [string]$relay.address) { $relay.address = 'hikreset@wireitct.com' }
  $form = $null; if ($CfgAll -and $CfgAll.PSObject.Properties['form']) { $form = $CfgAll.form }
  # 2.2.1 (review M5): no "form" in config.json = the Toolkit's own default details (the same ones ToolkitCore uses), not "no reset"
  if (-not $form) { if (Get-Command Get-TkConfig -ErrorAction SilentlyContinue) { try { $form = [pscustomobject](Get-TkConfig $ToolkitDir).form } catch {} }; if (-not $form) { $form = [pscustomobject]$script:HkDefaultForm } }
  $replyTo = $(if ($form -and $form.PSObject.Properties['email']) { [string]$form.email } else { '' })
  if ([string]$relay.url) { $replyTo = [string]$relay.address }
  return [pscustomobject]@{ form = $form; relay = $relay; waitMinutes = $wait; replyDir = $replyDir; replyTo = $replyTo }
}
# the form as it goes to Hikvision: the reply address is the relay's when the relay is on
function Get-HikFormFor($Cfg) {
  if (-not $Cfg.form) { return $null }
  $f = [ordered]@{}
  if ($Cfg.form -is [Collections.IDictionary]) { foreach ($k in @($Cfg.form.Keys)) { $f[$k] = $Cfg.form[$k] } } else { foreach ($p in $Cfg.form.PSObject.Properties) { $f[$p.Name] = $p.Value } }
  if ($Cfg.replyTo) { $f['email'] = [string]$Cfg.replyTo }
  return [pscustomobject]$f
}

# ---------------- the whole thing for a list of devices ----------------
# $Targets: objects with .mac (the devices whose password is unknown). Returns { fixed = @(macs); pending = @({ mac; reason }) }.
function Invoke-HikResetStage {
  # 2.2.0: $ToolkitDir (the relay key), $InboxDir (the "I got Hik's email" drops), $Site (named in inbox\hik\waiting.json)
  param($Targets, [string]$SitePassword, [string]$StateDir, $Config, [string]$ToolkitDir = '', [scriptblock]$VerifyLogin, [int]$WaitMinutes = 15, [int]$SubmitTimeoutSec = 900, [string]$InboxDir = '', [string]$Site = '', [int]$InboxEverySec = 5)
  $statePath = Join-Path $StateDir 'state.json'; $reqDir = Join-Path $StateDir 'requests'
  $repDir = $(if ($Config.replyDir) { $Config.replyDir } else { Join-Path $StateDir 'replies' })
  New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
  $state = Read-HikState $statePath
  $want = @{}; foreach ($t in @($Targets)) { $m = ConvertTo-SadpMac ([string]$t.mac); if ($m) { $want[$m] = $t } }
  Hk-Say 'Finding the Hikvision devices (any IP range)...'
  $devs = @(Find-HikSadp 4 | Where-Object { $want.ContainsKey($_.mac) })
  $fixed = @(); $pending = @()
  foreach ($m in $want.Keys) { if (-not @($devs | Where-Object { $_.mac -eq $m }).Count) { $pending += [pscustomobject]@{ mac = $m; reason = 'not seen on the network (check power and cable)' } } }
  $forMine = { param($st) @($st.devices | Where-Object { $want.ContainsKey((ConvertTo-SadpMac ([string]$_.mac))) }) }
  # 2.2.1: a device whose unlock file was imported in an earlier run that stopped before the check: check its login now (once)
  # 2.2.2 (Codex, reset resume): this check runs BEFORE any new export. 2.2.1 exported first, which reset an "imported" device to
  # "exported", so the check never saw it (and a fresh request cancelled the reset that had worked).
  foreach ($d in @(& $forMine $state | Where-Object { $_.status -eq 'imported' })) {
    $okv = $false; try { $okv = [bool](& $VerifyLogin ([string]$d.ip) $SitePassword) } catch {}
    if ($okv) { Set-HikStateField $d 'status' 'verified'; Set-HikStateField $d 'verifiedAt' (Get-Date -Format 's'); Save-HikState $statePath $state; $fixed += (ConvertTo-SadpMac ([string]$d.mac)); Hk-Say ('  ' + $d.model + ' ' + $d.ip + ': the earlier reset worked - the site password logs in.') 'Green' }
  }
  foreach ($d in @(& $forMine $state | Where-Object { $_.status -eq 'verified' })) { $mv = ConvertTo-SadpMac ([string]$d.mac); if ($fixed -notcontains $mv) { $fixed += $mv } }
  # a device that is already done is never asked for a new request file
  $todo = @($devs | Where-Object { $_.activated -and $fixed -notcontains (ConvertTo-SadpMac ([string]$_.mac)) })
  # an old state (reply still waiting from an earlier run) is picked up as it is
  Hk-Say ('Asking each of the ' + $todo.Count + ' device(s) for its reset request file (same as SADP "Forgot password > Export file")...')
  [void](Export-HikRequests $todo $reqDir $state $statePath)
  $form = Get-HikFormFor $Config
  if (-not $form) { return [pscustomobject]@{ fixed = @($fixed); pending = @($pending) + @($todo | ForEach-Object { [pscustomobject]@{ mac = $_.mac; reason = 'config.json has no "form" (name, email, company)' } }) } }
  $mine = @(& $forMine $state | ForEach-Object { [string]$_.serial })
  [void](Submit-HikRequests $state $statePath $form $SubmitTimeoutSec $mine)
  Save-HikWaitingList $InboxDir $state $Site ([string]$Config.replyTo)
  $end = (Get-Date).AddMinutes($WaitMinutes); $lastLine = ''; $lastSaid = [datetime]::MinValue; $first = $true
  do {
    $r = Receive-HikReplies $state $statePath $Config $ToolkitDir $repDir $InboxDir -ForceRelay:$first
    $first = $false
    foreach ($u in @($r.unmatched)) { Hk-Say ('  A file from Hikvision matches no device here: ' + $u.name + ' (' + $u.why + '). It is not used.') 'Yellow' }
    $waiting = @(& $forMine $state | Where-Object { $_.status -eq 'submitted' })
    if ($r.got.Count) { Save-HikWaitingList $InboxDir $state $Site ([string]$Config.replyTo) }
    $left = [math]::Max(0, [int][math]::Ceiling(($end - (Get-Date)).TotalMinutes))
    $line = Format-HikWaitLine $Config $waiting.Count $left
    if ($script:HkStatus) { try { & $script:HkStatus ([pscustomobject]@{ waiting = @($waiting | ForEach-Object { [pscustomobject]@{ serial = $_.serial; shortSerial = $_.shortSerial; model = $_.model; ip = $_.ip } }); relay = $script:HkRelayStatus; replyTo = [string]$Config.replyTo; minutesLeft = $left; line = $line.text }) } catch {} }
    if (-not $waiting.Count -or (Get-Date) -ge $end) { break }
    # say it when it changes (or every 5 minutes), not every few seconds
    $key = $script:HkRelayStatus.state + '|' + $script:HkRelayStatus.msg + '|' + $waiting.Count
    if ($key -ne $lastLine -or ((Get-Date) - $lastSaid).TotalMinutes -ge 5) { Hk-Say ('  ' + $line.text) $line.color; $lastLine = $key; $lastSaid = Get-Date }
    Start-Sleep -Seconds ([math]::Max(1, $InboxEverySec))
  } while ($true)
  $ready = @(& $forMine $state | Where-Object { $_.status -eq 'replied' })
  if ($ready.Count) { $done = @(Import-HikReplies $state $statePath $SitePassword $VerifyLogin '' $mine); foreach ($d in $done) { $fixed += (ConvertTo-SadpMac ([string]$d.mac)) } }
  Save-HikWaitingList $InboxDir $state $Site ([string]$Config.replyTo)
  if ($script:HkStatus) { try { & $script:HkStatus ([pscustomobject]@{ waiting = @(); relay = $script:HkRelayStatus; replyTo = [string]$Config.replyTo; minutesLeft = 0; line = ''; done = $true }) } catch {} }
  foreach ($d in @(& $forMine $state)) {
    if ($fixed -contains (ConvertTo-SadpMac ([string]$d.mac))) { continue }
    $why = switch ($d.status) { 'submitted' { 'sent to Hikvision, waiting for the unlock email (it can take a few hours). When it comes: press "I got Hik''s email" (or, with the reply mailbox set up, just press Fix this site again). The device must NOT restart meanwhile.' } 'exported' { 'request file made, not sent to Hikvision yet' } 'replied' { 'unlock file arrived but the import did not work' + $(if ($d.note) { ' (' + $d.note + ')' } else { '' }) } 'expired' { 'the request is no longer valid (' + $d.note + '): it needs a new one' } default { [string]$d.status } }
    $pending += [pscustomobject]@{ mac = $d.mac; reason = $why }
  }
  return [pscustomobject]@{ fixed = @($fixed); pending = @($pending) }
}
