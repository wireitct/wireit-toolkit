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
$script:PortalSay = { param($t, $c) Hk-Say $t $c }   # 2.2.9: the page's prompts (slider) on the same screen as the rest
. (Join-Path $here0 'HikMail.ps1')

$script:HkSay = { param($t, $c) Write-Host $t }
$script:HkAsk = { param($t) Read-Host $t }
$script:HkStatus = $null       # 2.2.0: optional: gets the waiting state for a screen (2.2.3: nothing sets it in the Toolkit)
function Hk-Say([string]$t, [string]$c = '') { & $script:HkSay $t $c }
function Hk-Ask([string]$t) { return (& $script:HkAsk $t) }
$script:HkValidHours = 48

# ---------------- state ----------------
function Read-HikState([string]$Path) {
  # 2.2.18 (sweep C/D): this record holds what keeps a reset safe (which unlock file a device REFUSED and must not get again, which
  # request file is in force, how many reboot-retries were used). A record that is there but cannot be read is NOT an empty record:
  # 2.2.17 started over with an empty one (and saved it over the damaged file), so a refused file could be tried again and a Retry
  # said "nothing to retry". Now the reset stops with the reason; the damaged file is left as it is.
  if (Test-Path -LiteralPath $Path) {
    $o = $null; $why = ''
    try { $raw = [IO.File]::ReadAllText($Path); if (-not ([string]$raw).Trim()) { $why = 'the file is empty' } else { $o = $raw | ConvertFrom-Json -ErrorAction Stop } } catch { $why = $_.Exception.Message }
    if ($o -and $o.PSObject.Properties['devices']) { $o.devices = @($o.devices | Where-Object { $null -ne $_ }); if ($o.PSObject.Properties['exports']) { $o.exports = @($o.exports | Where-Object { $null -ne $_ }) } else { $o | Add-Member -NotePropertyName exports -NotePropertyValue @() -Force }; return $o }
    if (-not $why) { $why = 'it has no device list' }
    throw ('The Hikvision reset record on this PC (' + $Path + ') could not be read (' + $why + '). Nothing was sent to any device. It says which unlock files a device refused and which request file is in force, so the reset does not start over without it. Check in SADP that no reset is half-way, then move that file away and run again.')
  }
  return [pscustomobject]@{ version = 1; site = ''; created = (Get-Date -Format 's'); devices = @(); exports = @() }
}
# 2.2.19 (Codex 2.2.18 F17, class E): a save that fails is no longer only a warning. $script:HkStateSaved says whether the LAST save
# reached the disk (written, read back, swapped in); Save-HikStateOk returns it. Every step that sends something to a device
# (export, import) saves what it is about to do FIRST and does not go ahead when that save fails.
$script:HkStateSaved = $true
$script:HkStateSaveWhy = ''
function Save-HikState([string]$Path, $State) {
  $script:HkStateSaved = $false; $script:HkStateSaveWhy = ''
  # 2.2.18 (sweep D): written to a temp file, read back, then swapped in whole, so a stop half-way never leaves a damaged record
  $tmp = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
  try {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) -ErrorAction Stop | Out-Null
    $json = [string]($State | ConvertTo-Json -Depth 8)
    [IO.File]::WriteAllText($tmp, $json)
    $fs = [IO.File]::Open($tmp, 'Open', 'Write', 'None'); try { $fs.Flush($true) } finally { $fs.Dispose() }
    $chk = [IO.File]::ReadAllText($tmp) | ConvertFrom-Json -ErrorAction Stop
    if (-not $chk -or -not $chk.PSObject.Properties['devices']) { throw 'the saved copy did not read back' }
    if ([IO.File]::Exists($Path)) { [IO.File]::Replace($tmp, $Path, [System.Management.Automation.Language.NullString]::Value) } else { [IO.File]::Move($tmp, $Path) }
    # 2.2.20 (class A): the FINAL file is read back too (2.2.19 read back only the temp copy): it must hold exactly what was written
    if ([IO.File]::ReadAllText($Path) -ne $json) { throw 'the saved record did not read back as written' }
    $script:HkStateSaved = $true
  } catch {
    $script:HkStateSaveWhy = [string]$_.Exception.Message
    $w = ('  WARNING: the reset record ' + $Path + ' could not be saved (' + $_.Exception.Message + '). Do not start another reset of these devices until it saves.')
    try { Hk-Say $w 'Red' } catch { Write-Warning $w }
  } finally { if ([IO.File]::Exists($tmp)) { try { [IO.File]::Delete($tmp) } catch {} } }
}
function Save-HikStateOk([string]$Path, $State) { Save-HikState $Path $State; return [bool]$script:HkStateSaved }
# 2.2.19: the plain stop line when the record could not be saved before a device step
function Get-HikNotSavedStop([string]$What) {
  return ('  STOPPED: ' + $What + ' was NOT done, because the reset record could not be saved first (see the warning above). The record must say what is being sent to a device before it is sent, so a refused file is never sent twice. Make the folder writable (or free some disk space), then run it again.')
}
# 2.2.19 (Codex 2.2.18 F16, class A): the device a saved record names, found in a FRESH SADP scan by its own identity - the MAC; the serial
# only when the record has no MAC (an exact, non-empty match). A device whose MAC matches but whose serial is different is NOT it.
# $null = not found / not the same device: nothing is checked or sent to the old address.
function Find-HikLiveDevice($D, $Seen) {
  $mac = ConvertTo-SadpMac ([string]$D.mac); $sn = ([string]$D.serial).Trim()
  foreach ($x in @($Seen)) {
    if (-not $x) { continue }
    $xm = ConvertTo-SadpMac ([string]$x.mac); $xs = ([string]$x.serial).Trim()
    if ($mac) {
      if ($xm -ne $mac) { continue }
      if ($sn -and $xs -and $xs -ne $sn) { continue }
      return $x
    }
    elseif ($sn -and $xs -and $xs -eq $sn) { return $x }
  }
  return $null
}

function Get-HikStateDevice($State, [string]$Serial) { foreach ($d in @($State.devices)) { if ($d.serial -eq $Serial) { return $d } }; return $null }
function Set-HikStateField($d, [string]$Name, $Value) { if ($d.PSObject.Properties[$Name]) { $d.$Name = $Value } else { $d | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force } }
# 2.2.8: every request file made (or registered) is recorded: serial, when, an export id (the first 12 hex of the file's SHA-256),
# the file and the boot time. Hikvision's reply only fits the LATEST export of a device: each new export voids the one before
# (3 Hewlett, Nov 8 2026: re-exports between replies, every import "Device refused to process").
function Get-HikExportId([string]$File) {
  try { $sha = [Security.Cryptography.SHA256]::Create(); try { $h = $sha.ComputeHash([IO.File]::ReadAllBytes($File)) } finally { $sha.Dispose() }; return (-join ($h[0..5] | ForEach-Object { $_.ToString('x2') })) } catch { return '' }
}
function Add-HikExportRecord($State, $Dev, [string]$File, [string]$BootTime, [datetime]$At) {
  if (-not $State.PSObject.Properties['exports']) { $State | Add-Member -NotePropertyName exports -NotePropertyValue @() -Force }
  $rec = [pscustomobject]@{ serial = [string]$Dev.serial; at = $At.ToString('s'); id = (Get-HikExportId $File); file = $File; bootTime = $BootTime }
  $State.exports = @(@($State.exports | Where-Object { $null -ne $_ }) + @($rec) | Select-Object -Last 100)
  return $rec
}
function Get-HikExports($State, [string]$Serial) { if (-not $State.PSObject.Properties['exports']) { return @() }; return @($State.exports | Where-Object { $_ -and [string]$_.serial -eq $Serial }) }
function Add-HikStateDevice($State, $Dev, [string]$File, [string]$BootTime, $At = $null) {
  $d = Get-HikStateDevice $State $Dev.serial
  $now = $(if ($At) { [datetime]$At } else { Get-Date })
  $rec = Add-HikExportRecord $State $Dev $File $BootTime $now
  $row = [ordered]@{ serial = $Dev.serial; shortSerial = $Dev.shortSerial; model = $Dev.model; mac = $Dev.mac; ip = $Dev.ip; kind = $Dev.kind; salt = $Dev.salt; encrypt = [bool]$Dev.encrypt; requestFile = $File; bootTime = $BootTime
    exportedAt = $now.ToString('s'); validUntil = $now.AddHours($script:HkValidHours).ToString('s'); exportId = $rec.id; status = 'exported'; submittedAt = ''; replyFile = ''; replyFrom = ''; replyAt = ''; replyForExport = ''; importedAt = ''; verifiedAt = ''; note = '' }
  if ($d) { foreach ($k in $row.Keys) { Set-HikStateField $d $k $row[$k] }; return $d }
  $State.devices = @($State.devices) + @([pscustomobject]$row); return (Get-HikStateDevice $State $Dev.serial)
}
# 2.2.19 (F17 twin): "an export of this device was started at <time>" - saved before the device is asked. A reply is only good for an
# export made at or after the newest of these; Test-HikExportVoided says when a later, unrecorded export voided the saved reply.
function Add-HikExportIntent($State, $Dev) {
  if (-not $State.PSObject.Properties['intents']) { $State | Add-Member -NotePropertyName intents -NotePropertyValue @() -Force }
  $rec = [pscustomobject]@{ serial = [string]$Dev.serial; mac = (ConvertTo-SadpMac ([string]$Dev.mac)); action = 'export'; at = (Get-Date -Format 's') }
  $State.intents = @(@($State.intents | Where-Object { $null -ne $_ }) + @($rec) | Select-Object -Last 100)
  return $rec
}
function Test-HikExportVoided($State, $D) {
  if (-not $State.PSObject.Properties['intents']) { return $false }
  $exp = $null; try { $exp = [datetime]([string]$D.exportedAt) } catch { return $false }
  foreach ($i in @($State.intents | Where-Object { $_ -and [string]$_.action -eq 'export' -and [string]$_.serial -eq [string]$D.serial })) {
    $at = $null; try { $at = [datetime]([string]$i.at) } catch { continue }
    if ($at -gt $exp) { return $true }
  }
  return $false
}
# 2.2.8: the plain warning when a NEW export would void a request that is still waiting at Hikvision ('' = nothing to warn about)
function Get-HikVoidWarning($Cur, $Dev = $null) {
  if (-not $Cur -or [string]$Cur.status -notin @('submitted', 'replied')) { return '' }
  $when = ''; try { $when = ([datetime]$Cur.exportedAt).ToString('h:mm tt') } catch {}
  $who = ([string]$Cur.model + ' ' + [string]$Cur.ip + ' (serial ' + [string]$Cur.serial + ')').Trim()
  if ($Dev -and $Cur.bootTime -and $Dev.bootTime -and [string]$Dev.bootTime -ne [string]$Cur.bootTime) { return ('  ' + $who + ' restarted since its request from ' + $when + ', so that request (and any reply to it) no longer works. Making one new request file.') }
  try { if (([datetime]$Cur.validUntil) -lt (Get-Date)) { return ('  ' + $who + ': the request from ' + $when + ' is older than 48 hours and no longer works. Making one new request file.') } } catch {}
  $sent = $(if ([string]$Cur.status -eq 'replied') { 'sent to Hikvision and answered' } else { 'sent to Hikvision' })
  return ('  WARNING ' + $who + ': a new request file VOIDS the one from ' + $when + ' that was ' + $sent + '. Hikvision''s reply to that one will then be refused by the device. Use only the reply to the NEW file, and do not export again after it.')
}

# ---------------- 2.2.9 (3 Hewlett, Nov 8 2026): the camera must be on a network of this PC ----------------
# Camera .7 was on 10.243.1.7/24 while the laptop was on 192.168.1.x: the first tries could not work. Setting the laptop to a static
# IP took it fully offline. So: before an export or a reset, check; when the camera is on no subnet of this PC's active adapters,
# STOP and tell the tech how to add a SECOND address on the camera's subnet (DHCP kept). This code never changes an adapter.
$script:HkLocalNets = $null        # TEST ONLY: @({ name; ip; prefix; wired; count }) instead of this PC's own adapters
$script:HkSubnetCheckOff = $false  # TEST ONLY: suites whose devices are stand-ins with made-up addresses
$script:HkPing = $null             # TEST ONLY: { param($ip) -> $true when something answers }
$script:HkSubnetBlocked = @{}      # serial -> the reason, for this run's end-of-run list
$script:HkLogPath = ''             # the SADP log (HikReset.ps1 sets it), named in "call Hik support"
$script:HkGuardText = 'Keep SADP open from export until import. Export once. Submit that file. Import only Hik''s reply to it.'
$script:HkMaxRebootRetries = 2
function ConvertTo-HikIpNum([string]$Ip) {
  $a = $null; if (-not [Net.IPAddress]::TryParse(([string]$Ip).Trim(), [ref]$a) -or $a.AddressFamily -ne 'InterNetwork') { return $null }
  $b = $a.GetAddressBytes(); return ([int64]$b[0] * 16777216 + [int64]$b[1] * 65536 + [int64]$b[2] * 256 + [int64]$b[3])
}
function ConvertFrom-HikIpNum([int64]$n) { return ('{0}.{1}.{2}.{3}' -f [int][math]::Floor($n / 16777216), [int]([math]::Floor($n / 65536) % 256), [int]([math]::Floor($n / 256) % 256), [int]($n % 256)) }
function Get-HikPrefixFromMask([string]$Mask) {
  $n = ConvertTo-HikIpNum $Mask; if ($null -eq $n) { return $null }
  $p = 0; $seenZero = $false
  for ($i = 31; $i -ge 0; $i--) { $bit = [math]::Floor($n / [math]::Pow(2, $i)) % 2; if ($bit -eq 1) { if ($seenZero) { return $null }; $p++ } else { $seenZero = $true } }
  return $p
}
function Get-HikMaskFromPrefix([int]$Prefix) { return (ConvertFrom-HikIpNum ([int64]([math]::Pow(2, 32) - [math]::Pow(2, 32 - $Prefix)))) }
function Test-HikSameSubnet([string]$Ip, [string]$LocalIp, [int]$Prefix) {
  $a = ConvertTo-HikIpNum $Ip; $b = ConvertTo-HikIpNum $LocalIp
  if ($null -eq $a -or $null -eq $b -or $Prefix -lt 0 -or $Prefix -gt 32) { return $false }
  $size = [int64][math]::Pow(2, 32 - $Prefix)
  return ([math]::Floor($a / $size) -eq [math]::Floor($b / $size))
}
# this PC's active IPv4 addresses: adapter name, address, prefix, wired?, how many IPv4 addresses that adapter has
function Get-HikLocalNets {
  if ($null -ne $script:HkLocalNets) { return @($script:HkLocalNets) }
  $L = @()
  try {
    foreach ($ni in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
      if ([string]$ni.OperationalStatus -ne 'Up' -or [string]$ni.NetworkInterfaceType -in @('Loopback', 'Tunnel')) { continue }
      $v4 = @($ni.GetIPProperties().UnicastAddresses | Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' })
      foreach ($ua in $v4) {
        $p = $null; try { $p = [int]$ua.PrefixLength } catch {}
        if (-not $p) { try { $p = Get-HikPrefixFromMask ([string]$ua.IPv4Mask) } catch {} }
        if ($null -eq $p -or $p -le 0 -or $p -gt 32) { continue }
        $L += [pscustomobject]@{ name = [string]$ni.Name; ip = $ua.Address.ToString(); prefix = [int]$p; wired = ([string]$ni.NetworkInterfaceType -match 'Ethernet'); count = $v4.Count }
      }
    }
  } catch {}
  return $L
}
function Test-HikPingAnswers([string]$Ip) {
  if ($script:HkPing) { try { return [bool](& $script:HkPing $Ip) } catch { return $false } }
  try { $p = New-Object Net.NetworkInformation.Ping; try { return ([string]$p.Send($Ip, 800).Status -eq 'Success') } finally { $p.Dispose() } } catch { return $false }
}
# a free address for the PC on the camera's subnet: never the camera's own, its gateway, another Hik device seen here, or one that
# answers ping. $null = none found (then the tech picks one).
function Get-HikSecondIpSuggestion($Dev, $Others = @()) {
  $cam = ConvertTo-HikIpNum ([string]$Dev.ip); if ($null -eq $cam) { return $null }
  $p = Get-HikPrefixFromMask ([string]$Dev.mask)
  if ($null -eq $p -or $p -lt 8 -or $p -gt 30) { $p = 24 }
  $mask = Get-HikMaskFromPrefix $p
  $size = [int64][math]::Pow(2, 32 - $p); $net = [int64]([math]::Floor($cam / $size) * $size); $bcast = $net + $size - 1
  $base = $(if ($p -le 24) { [int64]([math]::Floor($cam / 256) * 256) } else { $net })
  $taken = @{}; foreach ($x in @([string]$Dev.ip, [string]$Dev.gw) + @(@($Others) | Where-Object { $_ } | ForEach-Object { [string]$_.ip })) { if ($x) { $taken[$x.Trim()] = 1 } }
  $offs = $(if ($p -le 24) { @(50..69) + @(200..219) } else { @(1..($size - 2)) | Sort-Object -Descending })
  $tries = 0
  foreach ($o in $offs) {
    $n = $base + $o; if ($n -le $net -or $n -ge $bcast) { continue }
    $ip = ConvertFrom-HikIpNum $n; if ($taken.ContainsKey($ip)) { continue }
    if ($tries -ge 30) { break }; $tries++
    if (Test-HikPingAnswers $ip) { continue }
    return [pscustomobject]@{ ip = $ip; mask = $mask; prefix = $p }
  }
  return $null
}
function Format-HikNets($Nets) { return ((@($Nets) | ForEach-Object { [string]$_.name + ' ' + [string]$_.ip + '/' + [string]$_.prefix }) -join ', ') }
function Get-HikWiredName($Nets) {
  $w = @(@($Nets) | Where-Object { $_.wired -and [string]$_.name })
  $e = @($w | Where-Object { [string]$_.name -match '^(?i)Ethernet' })
  if ($e.Count) { return [string]$e[0].name }; if ($w.Count) { return [string]$w[0].name }; return 'Ethernet'
}
# the plain steps (no adapter is touched by the Toolkit). Never "switch to a static IP": that took the laptop offline on Nov 8.
function Get-HikSubnetSteps($Dev, $Nets, $Sg) {
  $who = ([string]$Dev.model + ' ' + [string]$Dev.ip).Trim()
  $eth = Get-HikWiredName $Nets
  $camMask = $(if ([string]$Dev.mask) { [string]$Dev.mask } else { 'mask not given' })
  $L = @(
    ('STOP: ' + $who + ' (serial ' + [string]$Dev.shortSerial + ') is not on any network of this PC, so the reset cannot work from here. Nothing was exported or imported.'),
    ('  The camera: ' + [string]$Dev.ip + ' / ' + $camMask + '. This PC: ' + $(if (@($Nets).Count) { Format-HikNets $Nets } else { 'no address' }) + '.')
  )
  if ($Sg) {
    # 2.2.10 (Codex R02): the command route is the main route (Control Panel's Add is greyed out while "Obtain an IP address
    # automatically" is on). Write the adapter down first, turn on DHCP/static coexistence BEFORE the add (without it Windows can
    # switch DHCP off), check DHCP afterwards, and the way back is given. NEEDS WINDOWS CHECK on a real DHCP adapter.
    $q = '"' + $eth + '"'
    $L += @(
      ('  Fix: give this PC a SECOND address on the camera''s network, on the wired adapter "' + $eth + '" (the one cabled to the camera''s switch).'),
      '  Open Command Prompt as administrator (Start > type cmd > right-click > Run as administrator) and type, one line at a time:',
      ('    1. Write down how the adapter is now:  netsh interface ipv4 show config name=' + $q + '   (note "DHCP enabled: Yes")  and  netsh interface ipv4 show interface ' + $q + '   (note "DHCP/Static IP Coexistence")'),
      ('    2. Let DHCP and the extra address live side by side:  netsh interface ipv4 set interface ' + $q + ' dhcpstaticipcoexistence=enabled'),
      ('    3. Add the address (no gateway):  netsh interface ipv4 add address ' + $q + ' ' + $Sg.ip + ' ' + $Sg.mask),
      ('    4. Check:  netsh interface ipv4 show config name=' + $q + '   must still say "DHCP enabled: Yes" and list ' + $Sg.ip + '.'),
      ('       If it says "DHCP enabled: No": put it back now with  netsh interface ipv4 set address name=' + $q + ' source=dhcp   (that also takes ' + $Sg.ip + ' off) and stop.'),
      ('       ' + $Sg.ip + ' did not answer ping from here. If Windows says the address is already in use, remove it (step A below) and pick another one.'),
      '    5. Run the reset again (Fix this site again).',
      ('  After the reset, remove it again in the same window:  A. netsh interface ipv4 delete address ' + $q + ' ' + $Sg.ip),
      ('    B. if step 1 said Coexistence "Disabled":  netsh interface ipv4 set interface ' + $q + ' dhcpstaticipcoexistence=disabled'),
      ('    C. netsh interface ipv4 show config name=' + $q + '   must say "DHCP enabled: Yes" again; if not:  netsh interface ipv4 set address name=' + $q + ' source=dhcp'),
      ('  In Control Panel > Network Connections > ' + $eth + ' > IPv4 > Properties, keep "Obtain an IP address automatically" selected (Advanced > Add is greyed out there while it is; use the commands above).')
    )
  } else {
    $L += @(
      ('  Fix: give this PC a SECOND address on the camera''s network, on the wired adapter "' + $eth + '": Control Panel > Network Connections > ' + $eth + ' > IPv4 > Properties > Advanced > Add, keeping "Obtain an IP address automatically".'),
      '  The Toolkit found no free address to suggest: every one it tried answered ping. Pick one on the camera''s network that nobody uses and check first that ping gets NO answer. Never use an address another device has.',
      '  After the reset: remove it again, keeping "Obtain an IP address automatically".'
    )
  }
  $L += '  Do not switch the adapter to "Use the following IP address" (a fixed IP): that takes this PC off its own network.'
  return $L
}
# $true = go ahead. $false = the steps were said (once per device per run) and the caller does not export / import.
function Test-HikOnLocalSubnet($Dev, $Others = @()) {
  if ($script:HkSubnetCheckOff) { return $true }
  if ($null -eq $script:HkLocalNets -and $script:SadpTest) { return $true }   # the loopback test harness: no real network to compare
  $ip = [string]$Dev.ip
  if (-not $ip -or $ip -eq '0.0.0.0' -or $null -eq (ConvertTo-HikIpNum $ip)) { return $true }
  $nets = @(Get-HikLocalNets)
  if (-not $nets.Count) {
    $k = 'subnet-unknown'; if (-not $script:HkSaidOnce.ContainsKey($k)) { $script:HkSaidOnce[$k] = 1; Hk-Say '  Could not read this PC''s network addresses, so the camera''s network was not checked.' 'Yellow' }
    return $true
  }
  foreach ($n in $nets) { if (Test-HikSameSubnet $ip ([string]$n.ip) ([int]$n.prefix)) { return $true } }
  $key = 'subnet|' + [string]$Dev.serial
  $sg = $null
  if (-not $script:HkSaidOnce.ContainsKey($key)) {
    $sg = Get-HikSecondIpSuggestion $Dev @(@($Others) | Where-Object { $_ -and [string]$_.ip -ne $ip })
    $script:HkSaidOnce[$key] = 1
    $first = $true; foreach ($l in @(Get-HikSubnetSteps $Dev $nets $sg)) { Hk-Say $l $(if ($first) { 'Red' } else { 'Yellow' }); $first = $false }
  }
  $script:HkSubnetBlocked[[string]$Dev.serial] = ('on another network than this PC (camera ' + $ip + ', this PC ' + ((@($nets) | ForEach-Object { [string]$_.ip }) -join ', ') + '): add a second IP on the camera''s network (steps on screen), then press Fix this site again')
  return $false
}
# after a reset that worked: the PC's extra address on the camera's subnet (an adapter with more than one IPv4) is to be removed
function Show-HikExtraIpReminder($Dev) {
  if ($script:HkSubnetCheckOff -or ($null -eq $script:HkLocalNets -and $script:SadpTest)) { return }
  $x = @(@(Get-HikLocalNets) | Where-Object { [int]$_.count -gt 1 -and (Test-HikSameSubnet ([string]$Dev.ip) ([string]$_.ip) ([int]$_.prefix)) })
  foreach ($n in $x) {
    $q = '"' + [string]$n.name + '"'
    Hk-Say ('  Now remove the extra address ' + [string]$n.ip + ' from ' + $q + ', keeping "Obtain an IP address automatically" (Command Prompt as administrator):') 'Cyan'
    Hk-Say ('    A. netsh interface ipv4 delete address ' + $q + ' ' + [string]$n.ip) 'Cyan'
    Hk-Say ('    B. if Coexistence was "Disabled" before you started:  netsh interface ipv4 set interface ' + $q + ' dhcpstaticipcoexistence=disabled') 'Cyan'
    Hk-Say ('    C. netsh interface ipv4 show config name=' + $q + '   must say "DHCP enabled: Yes"; if not:  netsh interface ipv4 set address name=' + $q + ' source=dhcp') 'Cyan'
  }
}
# 2.2.9: one SADP session from export to import
function Show-HikSessionGuard { Hk-Say ('  ' + $script:HkGuardText) 'Cyan' }
function Get-HikExportLabel($D) {
  $t = ''; try { $t = ([datetime]$D.exportedAt).ToString('h:mm tt') } catch {}
  return ('the request file ' + $(if ([string]$D.requestFile) { Split-Path -Leaf ([string]$D.requestFile) } else { '(no file)' }) + $(if ($t) { ' made ' + $t } else { '' }))
}

# ---------------- 2.2.9 (Moshe, Nov 8 9:55 PM): "device refused" after correct steps = reboot the camera, then Retry ----------------
# What the Toolkit can check about a refused reply. Empty = every check passed (the steps were right).
function Get-HikRefusalProblems($State, $D) {
  $P = @()
  $eid = $(if ($D.PSObject.Properties['exportId']) { [string]$D.exportId } else { '' })
  $rfe = $(if ($D.PSObject.Properties['replyForExport']) { [string]$D.replyForExport } else { '' })
  if (-not $eid) { $P += 'the Toolkit has no record of the export this reply answers (it was made outside the Toolkit or before 2.2.8), so it may answer an older request' }
  elseif ($rfe -and $rfe -ne $eid) { $P += ('the reply answers an older export (' + $rfe + '), not the latest one (' + $eid + ')') }
  elseif (-not $rfe) { $P += 'the reply was not tied to the latest export when it came in' }
  $later = @(@($State.exports) | Where-Object { $_ -and [string]$_.serial -eq [string]$D.serial } | Sort-Object { [string]$_.at })
  if ($later.Count -and $eid -and [string]$later[-1].id -ne $eid) { $P += ('a newer export was made after this one (' + $(try { ([datetime]$later[-1].at).ToString('h:mm tt') } catch { [string]$later[-1].at }) + '), which voids this reply') }
  $ra = $null; $ea = $null; try { if ([string]$D.replyAt) { $ra = [datetime]$D.replyAt } } catch {}; try { $ea = [datetime]$D.exportedAt } catch {}
  if (-not $ra) { $P += 'when the reply arrived is not known, so it may answer an older request' }
  elseif ($ea -and $ra -lt $ea.AddSeconds(-60)) { $P += ('the reply arrived ' + $ra.ToString('h:mm tt') + ', before the request file was made (' + $ea.ToString('h:mm tt') + ')') }
  return $P
}
function Get-HikSupportLine($D) {
  return ('  Call Hik support with the serial and the SADP log: serial ' + [string]$D.serial + ' (' + ([string]$D.model).Trim() + '), SADP log ' + $(if ($script:HkLogPath) { $script:HkLogPath } else { 'hikreset.log in the Toolkit''s runs\HikReset folder' }) + '.')
}
# may a refused device get a fresh export now? { ok; why }
function Get-HikRetryReadiness($D, $Live) {
  $n = 0; try { $n = [int]$D.rebootRetries } catch {}
  $who = ([string]$D.model + ' ' + [string]$D.ip).Trim()
  # 2.2.20 (R14): an export whose result was never recorded is settled by Export-HikRequests (its file is registered, or it waits for a
  # reboot); it is never repeated blindly. Seen + Active is all that is needed to get there.
  if ([string]$D.status -eq 'exporting') {
    if (-not $Live) { return [pscustomobject]@{ ok = $false; why = ('  ' + $who + ' is not seen right now. Wait until SADP shows it Active, then press Retry.') } }
    return [pscustomobject]@{ ok = $true; why = '' }
  }
  if ($D.PSObject.Properties['refusedChecksOk'] -and $D.refusedChecksOk -and $n -ge $script:HkMaxRebootRetries) { return [pscustomobject]@{ ok = $false; why = ('  ' + $who + ': refused again after ' + $n + ' reboot-retries. No more retries from the Toolkit.' + "`n" + (Get-HikSupportLine $D)) } }
  if (-not $Live) { return [pscustomobject]@{ ok = $false; why = ('  ' + $who + ' is not seen right now. Wait until SADP shows it Active, then press Retry.') } }
  if ($Live.PSObject.Properties['activated'] -and -not $Live.activated) { return [pscustomobject]@{ ok = $false; why = ('  ' + $who + ' does not show as Active yet. Wait until SADP shows it Active, then press Retry.') } }
  if ($D.PSObject.Properties['refusedChecksOk'] -and $D.refusedChecksOk -and [string]$D.bootTime -and [string]$Live.bootTime -and [string]$Live.bootTime -eq [string]$D.bootTime) {
    return [pscustomobject]@{ ok = $false; why = ('  ' + $who + ' has not restarted since it refused the file. Reboot the camera: unplug it or its PoE port for 10 seconds. Wait until SADP shows it Active, then press Retry.') }
  }
  # 2.2.20 (Codex 2.2.19 R14, class A/F): a reboot-retry is used up the moment it is RESERVED (saved before the device is asked), for the
  # boot it was reserved on. The same boot never gets a second retry, whatever happened to the first one's answer.
  if ($D.PSObject.Properties['retryBootTime'] -and [string]$D.retryBootTime -and [string]$Live.bootTime -and [string]$Live.bootTime -eq [string]$D.retryBootTime) {
    return [pscustomobject]@{ ok = $false; why = ('  ' + $who + ' already had reboot-retry ' + $n + ' on this start-up of the camera. Reboot the camera again (unplug it or its PoE port for 10 seconds), wait until SADP shows it Active, then press Retry.') }
  }
  return [pscustomobject]@{ ok = $true; why = '' }
}
# 2.2.20 (Codex 2.2.19 R14): an export that was RESERVED (status "exporting", saved before the device was asked) but whose result was never
# recorded - the run stopped, or the save after the export failed. It is settled, never repeated blindly:
#   - the request file the record names is there, was written after the export started, ends with this serial, and the camera has not
#     restarted: that file is registered as the one in force (no new export);
#   - otherwise, while the camera is on the same start-up: NOT CONFIRMED, nothing is sent (a second export would void the first);
#   - after a reboot: it goes on like the state before ($go), and the reboot-retry reserved for the earlier start-up stays used.
# Returns { made; go; lines }
function Resolve-HikUnfinishedExport($State, $Cur, $Dev, [string]$StatePath) {
  $who = ([string]$Cur.model + ' ' + [string]$Dev.ip + ' (serial ' + [string]$Cur.serial + ')').Trim()
  $started = $null; try { $started = [datetime]([string]$Cur.exportStartedAt) } catch {}
  $boot = $(if ($Cur.PSObject.Properties['exportBootTime']) { [string]$Cur.exportBootTime } else { '' })
  $sameBoot = (-not $boot -or -not [string]$Dev.bootTime -or [string]$Dev.bootTime -eq $boot)
  $file = $(if ($Cur.PSObject.Properties['exportFile']) { [string]$Cur.exportFile } else { '' })
  if ($sameBoot -and $file -and $started -and (Test-Path -LiteralPath $file)) {
    $fi = Get-Item -LiteralPath $file; $txt = ''; try { $txt = [IO.File]::ReadAllText($file).Trim() } catch {}
    $code = $(if ($txt.EndsWith([string]$Cur.serial)) { $txt.Substring(0, $txt.Length - ([string]$Cur.serial).Length) } else { '' })
    if ($code -and (Test-HikSafeCode $code) -and $fi.LastWriteTime -ge $started.AddSeconds(-2)) {
      $d = Add-HikStateDevice $State $Dev $file $boot $fi.LastWriteTime
      Set-HikStateField $d 'refusedChecksOk' $false; Set-HikStateField $d 'exportPrevStatus' ''
      if (-not (Save-HikStateOk $StatePath $State)) { return [pscustomobject]@{ made = $false; go = $false; lines = @((Get-HikNotSavedStop ('Registering the request file of ' + $who))) } }
      return [pscustomobject]@{ made = $true; go = $false; lines = @(('  ' + $who + ': the export started ' + $started.ToString('h:mm tt') + ' was not recorded, but its request file ' + (Split-Path -Leaf $file) + ' (made ' + $fi.LastWriteTime.ToString('h:mm tt') + ') is there: it is registered as the one in force. NOT exported again.')) }
    }
  }
  if ($sameBoot) {
    return [pscustomobject]@{ made = $false; go = $false; lines = @(
        ('  NOT CONFIRMED: ' + $who + ' was asked for a request file' + $(if ($started) { ' at ' + $started.ToString('h:mm tt') } else { '' }) + ', but the result was not recorded. It is NOT asked again (a second export would void the first).'),
        '  If you have that request file (SADP export folder or Downloads), register it: HikReset -RegisterDir <that folder>. Otherwise reboot the camera (unplug it or its PoE port for 10 seconds), wait until SADP shows it Active, then press Retry.') }
  }
  # rebooted since: the unfinished export is void; carry on from the state before it (its reboot-retry stays used)
  $prev = $(if ($Cur.PSObject.Properties['exportPrevStatus']) { [string]$Cur.exportPrevStatus } else { '' })
  Set-HikStateField $Cur 'status' $(if ($prev) { $prev } else { 'expired' })
  Set-HikStateField $Cur 'note' 'an export was started but not recorded; the camera restarted since'
  return [pscustomobject]@{ made = $false; go = $true; lines = @() }
}
# 2.2.20 (R14): a reservation saved before the device is asked: the export intent, the reboot-retry (when it is one), the boot it is for
# and the file it will write. $Cur may be $null (a device the record does not have yet): a row is made for it.
function Set-HikExportReservation($State, $Cur, $Dev, [string]$OutDir, [int]$RetryN) {
  $row = $Cur
  if (-not $row) {
    $row = [pscustomobject]@{ serial = [string]$Dev.serial; shortSerial = [string]$Dev.shortSerial; model = [string]$Dev.model; mac = [string]$Dev.mac; ip = [string]$Dev.ip; kind = [string]$Dev.kind; status = ''; requestFile = ''; bootTime = [string]$Dev.bootTime; note = '' }
    $State.devices = @($State.devices) + @($row)
  }
  $undo = [ordered]@{}; foreach ($k in 'status', 'exportStartedAt', 'exportPrevStatus', 'exportBootTime', 'exportFile', 'rebootRetries', 'retryBootTime') { $undo[$k] = $(if ($row.PSObject.Properties[$k]) { $row.$k } else { $null }) }
  Set-HikStateField $row 'exportPrevStatus' ([string]$row.status)
  Set-HikStateField $row 'status' 'exporting'
  Set-HikStateField $row 'exportStartedAt' (Get-Date -Format 's')
  Set-HikStateField $row 'exportBootTime' ([string]$Dev.bootTime)
  Set-HikStateField $row 'exportFile' (Get-HikResetFilePath $Dev $OutDir)
  if ($RetryN) { Set-HikStateField $row 'rebootRetries' $RetryN; Set-HikStateField $row 'retryBootTime' ([string]$Dev.bootTime) }
  return [pscustomobject]@{ row = $row; isNew = (-not $Cur); undo = $undo }
}
function Undo-HikExportReservation($State, $Res) {
  if ($Res.isNew) { $State.devices = @(@($State.devices) | Where-Object { -not [object]::ReferenceEquals($_, $Res.row) }); return }
  foreach ($k in $Res.undo.Keys) { if ($null -eq $Res.undo[$k]) { if ($Res.row.PSObject.Properties[$k]) { $Res.row.PSObject.Properties.Remove($k) } } else { Set-HikStateField $Res.row $k $Res.undo[$k] } }
}

# ---------------- 1. find + export ----------------
# $Devices = Find-HikSadp result. A device that is not activated has no password to reset: it is only activated (the caller does that).
function Export-HikRequests($Devices, [string]$OutDir, $State, [string]$StatePath, [switch]$Redo) {
  $made = @(); $newOnes = 0
  foreach ($dev in @($Devices | Where-Object { $_.activated })) {
    $cur = Get-HikStateDevice $State $dev.serial
    # 2.2.20 (Codex 2.2.19 R14): an export reserved earlier whose result was never recorded is settled first, never repeated blindly
    if ($cur -and [string]$cur.status -eq 'exporting') {
      $rc = Resolve-HikUnfinishedExport $State $cur $dev $StatePath
      foreach ($l in @($rc.lines)) { Hk-Say $l $(if ($rc.made) { 'Green' } else { 'Yellow' }) }
      if ($rc.made) { $made += $cur; continue }
      if (-not $rc.go) { continue }
    }
    if ($cur -and -not $Redo -and $cur.status -in @('exported', 'submitted', 'replied') -and [string]$cur.requestFile -and (Test-Path -LiteralPath $cur.requestFile) -and ([datetime]$cur.validUntil) -gt (Get-Date) -and $cur.bootTime -eq $dev.bootTime) {
      Hk-Say ('  ' + $dev.model + ' ' + $dev.ip + ': request file from ' + ([datetime]$cur.exportedAt).ToString('h:mm tt') + ' is still good - not asking the device again (a new one would cancel it).'); $made += $cur; continue
    }
    # 2.2.9: a camera on no network of this PC: stop BEFORE exporting (an export from here cannot be finished; it would only void)
    if (-not (Test-HikOnLocalSubnet $dev $Devices)) { if ($cur) { Set-HikStateField $cur 'note' 'on another network than this PC' }; continue }
    # 2.2.9: a camera that refused Hik's file after correct steps gets a fresh export only after a reboot, at most 2 times
    $retryN = 0
    if ($cur -and [string]$cur.status -eq 'refused') {
      $rr = Get-HikRetryReadiness $cur $dev
      if (-not $rr.ok) { foreach ($l in ([string]$rr.why -split "`n")) { Hk-Say $l 'Yellow' }; continue }
      if ($cur.PSObject.Properties['refusedChecksOk'] -and $cur.refusedChecksOk) { $retryN = 1; try { $retryN = [int]$cur.rebootRetries + 1 } catch {} }
    }
    $vw = Get-HikVoidWarning $cur $dev; if ($vw) { Hk-Say $vw $(if ($vw -match 'WARNING') { 'Red' } else { 'Yellow' }) }
    # 2.2.19 (Codex 2.2.18 F17, class E): a new export voids every earlier reply of this device. That is written down BEFORE the device
    # is asked (exportStartedAt), so a run that stops (or cannot save) after the export never imports an older reply as if it still fit.
    # 2.2.20 (Codex 2.2.19 R14, class A/F): the same save now RESERVES the reboot-retry (count + the boot it is for), the "exporting" state
    # and the file it will write, and is read back from disk, all BEFORE the device is asked. A result that is lost after that (no
    # answer, a failed save, a stop) never gives the retry back and never lets the same boot pass again. No save = no export.
    [void](Add-HikExportIntent $State $dev)
    $res = Set-HikExportReservation $State $cur $dev $OutDir $retryN
    if (-not (Save-HikStateOk $StatePath $State)) { Undo-HikExportReservation $State $res; Hk-Say (Get-HikNotSavedStop ('Asking ' + $dev.model + ' ' + $dev.ip + ' for a request file')) 'Red'; break }
    $row = $res.row
    $e = Request-HikResetExport $dev
    $f = $null; $why = ''
    if (-not $e.ok) { $why = $e.error } else { $f = Save-HikResetFile $dev $e $OutDir; if (-not $f) { $why = 'its answer had no request code - no file saved' } }
    if (-not $f) {
      Hk-Say ('  ' + $dev.model + ' ' + $dev.ip + ': could not read its request code - ' + $why) 'Yellow'
      # no file: the state before stands (an earlier reply is still void: the intent says an export was started); a reserved
      # reboot-retry stays used for this start-up of the camera (the device may have made a code whose answer was lost)
      if ($res.isNew) { Undo-HikExportReservation $State $res } else { Set-HikStateField $row 'status' ([string]$row.exportPrevStatus); Set-HikStateField $row 'note' ('export: ' + $why) }
      if (-not (Save-HikStateOk $StatePath $State)) { Hk-Say (Get-HikNotSavedStop 'Asking the next device for a request file') 'Red'; break }
      continue
    }
    $d = Add-HikStateDevice $State $dev $f $dev.bootTime
    Set-HikStateField $d 'refusedChecksOk' $false; Set-HikStateField $d 'exportPrevStatus' ''
    if ($retryN) { Set-HikStateField $d 'rebootRetries' $retryN }
    if (-not (Save-HikStateOk $StatePath $State)) {
      Hk-Say ('  ' + $dev.model + ' ' + $dev.ip + ': a request file WAS made (' + $f + '), but the reset record could not be saved. Do NOT export again. Make the folder writable, then run it again: the record already names that file, and it is registered from there (no new export).') 'Red'
      $made += $d; $newOnes++; break
    }
    Hk-Say ('  ' + $dev.model + ' ' + $dev.ip + '  serial ' + $dev.serial + ': request file saved (' + (Split-Path -Leaf $f) + ', ' + ([datetime]$d.exportedAt).ToString('h:mm tt') + ')') 'Green'
    if ($retryN) { Hk-Say ('  Reboot-retry ' + $retryN + ' of ' + $script:HkMaxRebootRetries + ' after the refusal: this is the ONE new request file. Submit it and import only Hik''s reply to it.') 'Cyan' }
    $made += $d; $newOnes++
  }
  if ($newOnes) { Show-HikSessionGuard }   # 2.2.9
  return $made
}

# 2.2.20 (class C, R12/R13 twins in the reset flow): a login check counts as passed ONLY when the checker answers a real $true. 2.2.19 took
# [bool] of whatever came back, so an answer like "noanswer" or "locked" (any non-empty text) read as "the site password logs in".
# The saved device record is passed as a third argument, so a checker that reads the device's own information document can also
# match its identity (MAC / serial). A checker that throws = NOT a pass.
function Test-HikLoginOk([scriptblock]$VerifyLogin, [string]$Ip, [string]$Password, $D = $null) {
  if (-not $VerifyLogin) { return $false }
  $o = $null; try { $o = @(& $VerifyLogin $Ip $Password $D) } catch { return $false }
  return ($o.Count -eq 1 -and $o[0] -is [bool] -and $o[0])
}
# 2.2.20 (class D): the full SHA-256 of a file (lower-case hex), '' when it cannot be read
function Get-HikFileSha([string]$File) {
  try { $sha = [Security.Cryptography.SHA256]::Create(); try { $h = $sha.ComputeHash([IO.File]::ReadAllBytes($File)) } finally { $sha.Dispose() }; return (-join ($h | ForEach-Object { $_.ToString('x2') })) } catch { return '' }
}
function Get-HikBytesSha([byte[]]$Bytes) {
  $sha = [Security.Cryptography.SHA256]::Create(); try { $h = $sha.ComputeHash($Bytes) } finally { $sha.Dispose() }; return (-join ($h | ForEach-Object { $_.ToString('x2') }))
}
# 2.2.20 (class D): the request file that goes to Hikvision's page must still be the one the record made for THIS device: its export id
# (first 12 hex of its SHA-256) as recorded, and it ends with this serial. '' = good; otherwise why not.
function Test-HikRequestFileInForce($D) {
  $file = [string]$D.requestFile
  if (-not $file -or -not (Test-Path -LiteralPath $file)) { return 'request file missing' }
  $txt = ''; try { $txt = [IO.File]::ReadAllText($file).Trim() } catch { return ('the request file could not be read (' + $_.Exception.Message + ')') }
  if (-not [string]$D.serial -or -not $txt.EndsWith([string]$D.serial)) { return 'the request file does not end with this device''s serial' }
  $eid = $(if ($D.PSObject.Properties['exportId']) { [string]$D.exportId } else { '' })
  if (-not $eid) { return '' }   # a record from before 2.2.8 has no export id: nothing to compare (as before)
  if ((Get-HikExportId $file) -ne $eid) { return ('the request file changed since it was made (it is not export ' + $eid + ' any more): another export or an edit replaced it') }
  return ''
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
    # 2.2.20 (class D): the file sent is the one this record made for this device (a replaced file is refused, not submitted)
    $rq = Test-HikRequestFileInForce $d
    if ($rq) { Set-HikStateField $d 'note' $rq; Hk-Say ('  ' + $d.model + ' ' + $d.ip + ' (serial ' + $d.serial + '): NOT sent to Hikvision - ' + $rq + '. Export it again (one new request file).') 'Red'; continue }
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
            Hk-Say '  YOUR STEP: type the picture code in the browser window and press Submit; if Hikvision shows a slider, slide it. (These are there to tell a person from a program, so the Toolkit leaves them to you.)' 'Cyan'
            $res = Wait-PortalSubmitted $s $PerDeviceTimeoutSec $null ({ $f = @(Restore-PortalFields $s $Form $d); if ($f.Count) { Hk-Say ('  (the page cleared ' + ($f -join ', ') + ' - filled again)') } }.GetNewClosure())
            if ($res -eq 'submitted') { $ok = $true; Set-HikStateField $d 'status' 'submitted'; Set-HikStateField $d 'submittedAt' (Get-Date -Format 's'); Hk-Say ('  Hikvision accepted it. The reply goes to ' + $Form.email) 'Green' }
            else { foreach ($l in @(Get-HikSubmitNextSteps $d $res $PerDeviceTimeoutSec)) { Hk-Say $l 'Yellow' } }
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
    # 2.2.19 (class E): a "sent to Hikvision" that cannot be saved stops the loop (the next run would not know this file is at Hikvision)
    if (-not (Save-HikStateOk $StatePath $State)) { if ($ok) { $sent += $d }; Hk-Say (Get-HikNotSavedStop 'Sending the next request file to Hikvision') 'Red'; break }
    if ($ok) { $sent += $d }
  }
  return $sent
}

# 2.2.9: Hik's page was not finished in time (the slider / picture code / Submit is a person's step): say what to do next
function Get-HikSubmitNextSteps($D, [string]$Res, [int]$TimeoutSec) {
  $min = [int][math]::Max(1, [math]::Round($TimeoutSec / 60))
  $what = $(if ($Res -eq 'closed') { 'The browser window was closed before Hikvision took the form' } else { 'Not submitted: nobody finished Hikvision''s page in ' + $min + ' min (the slider or picture code, then Submit)' })
  return @(
    ('  ' + $what + '.'),
    ('  ' + (Get-HikExportLabel $D) + ' is still good - do NOT export again (a new export voids it).'),
    '  Next: run it again (press Fix this site again, or HikReset -Mode Submit). When the window comes up, solve the slider in it, type the picture code and press Submit.'
  )
}
# ---------------- registering request files that already exist (made by SADP / HiTools / an earlier run) ----------------
# SADP's own export is one line: <code><DeviceSN>. The serial at the end names the device; $Devices (Find-HikSadp) gives the rest.
function Register-HikRequestFiles($State, [string]$Dir, $Devices, [string]$StatePath) {
  # 2.2.8: several exports of one device in a folder (Downloads, Nov 8 2026): only the NEWEST is in force (each export voids the one
  # before), so files are taken oldest first and the newest per serial wins; each older one is named as not used.
  $added = @(); $bySerial = @{}
  foreach ($f in @(Get-ChildItem -LiteralPath $Dir -File -Filter *.xml -ErrorAction SilentlyContinue | Sort-Object LastWriteTime, Name)) {
    $t = ''; try { $t = [IO.File]::ReadAllText($f.FullName).Trim() } catch { Hk-Say ('  ' + $f.Name + ': could not be read - skipped.') 'Yellow'; continue }
    if (-not $t) { Hk-Say ('  ' + $f.Name + ': the file is empty - skipped.') 'Yellow'; continue }
    $dev = $null; foreach ($d in @($Devices)) { if ($d.serial -and $t.EndsWith([string]$d.serial)) { $dev = $d; break } }
    if (-not $dev) { Hk-Say ('  ' + $f.Name + ': no device here has the serial this file ends with - skipped.') 'Yellow'; continue }
    $k = [string]$dev.serial; if (-not $bySerial.ContainsKey($k)) { $bySerial[$k] = @() }; $bySerial[$k] += $f
  }
  foreach ($k in $bySerial.Keys) {
    $files = @($bySerial[$k]); $f = $files[-1]
    $dev = $null; foreach ($d in @($Devices)) { if ([string]$d.serial -eq $k) { $dev = $d; break } }
    foreach ($o in @($files | Select-Object -First ($files.Count - 1))) { Hk-Say ('  ' + $o.Name + ' (made ' + $o.LastWriteTime.ToString('h:mm tt') + ') is not used: a newer request file for serial ' + $k + ' (' + $f.Name + ', ' + $f.LastWriteTime.ToString('h:mm tt') + ') replaces it. Hikvision''s reply to the older one will not work.') 'Yellow' }
    $cur = Get-HikStateDevice $State $dev.serial
    if ($cur -and $cur.requestFile -eq $f.FullName) { $added += $cur; continue }
    $vw = Get-HikVoidWarning $cur $dev; if ($vw) { Hk-Say $vw $(if ($vw -match 'WARNING') { 'Red' } else { 'Yellow' }) }
    $d2 = Add-HikStateDevice $State $dev $f.FullName $dev.bootTime $f.LastWriteTime
    $added += $d2
  }
  # 2.2.20 (class A): "registered" only once the record says so on disk (2.2.19 ignored a failed save and returned them as registered)
  if (-not (Save-HikStateOk $StatePath $State)) { Hk-Say (Get-HikNotSavedStop 'Registering the request files') 'Red'; return @() }
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
# 2.2.8: a reply is used only when it arrived AFTER the device's latest export (relay: the mail's receivedAt; .eml: its Date; any other
# file: its file time, which a drop keeps from the downloaded file). An older one answers a request that a later export voided, so the
# device would refuse it: it is listed in "stale" with the reason and never saved or imported. Returns
#   { got; unmatched; stale = [{ serial; name; mail; why }]; skipped = [{ mail; name; why; quiet }] }
# A drop from inbox\hik that is stale, unusable (no / empty / non-xml file) is moved to inbox\hik\not-used\, so it is said once.
function Move-HikDropNotUsed([string]$InboxDir, [string]$Src) {
  if (-not $InboxDir -or -not $Src -or -not $Src.StartsWith($InboxDir) -or -not (Test-Path -LiteralPath $Src)) { return }
  try { $nu = Join-Path $InboxDir 'not-used'; New-Item -ItemType Directory -Force -Path $nu | Out-Null; Move-Item -LiteralPath $Src -Destination (Join-Path $nu (Split-Path -Leaf $Src)) -Force } catch {}
}
$script:HkReplySkewSec = 60   # 2.2.8: see Receive-HikReplies
function Receive-HikReplies($State, [string]$StatePath, $Cfg, [string]$ToolkitDir, [string]$ReplyDir, [string]$InboxDir = '', [switch]$ForceRelay) {
  $pend = @($State.devices | Where-Object { $_.status -in @('submitted', 'replied') })
  if (-not $pend.Count) { return [pscustomobject]@{ got = @(); unmatched = @(); stale = @(); skipped = @() } }
  # 2.2.8: look back 2 days before the oldest waiting export (a request lives 48 hours), so an older reply is SEEN and named stale
  # instead of being silently out of view (2.2.7 looked back one hour)
  $since = (Get-Date).AddDays(-4); try { $since = ([datetime](@($pend | ForEach-Object { $_.exportedAt } | Sort-Object)[0])).AddDays(-2) } catch {}
  $msgs = @(Get-HikReplyMessages $Cfg $ToolkitDir $ReplyDir $since @($pend | Where-Object { $_.status -eq 'submitted' }) $InboxDir -ForceRelay:$ForceRelay)
  $m = Find-HikReplyMatches $pend $msgs @($State.devices)
  $got = @(); $stale = @(); $usedDrops = @()
  New-Item -ItemType Directory -Force -Path $ReplyDir | Out-Null
  $isDrop = { param($s) [bool]($InboxDir -and [string]$s -and ([string]$s).StartsWith($InboxDir)) }
  foreach ($x in $m.matched) {
    $d = $x.device
    # our own request file is not a reply (folder mode could see it); a reply is a different file
    $own = ''; try { $own = [IO.File]::ReadAllText($d.requestFile).Trim() } catch {}
    if ($own -and (Hm-Latin1).GetString($x.bytes).Trim() -eq $own) { continue }
    $dest = Join-Path $ReplyDir ('reply-' + ($d.serial -replace '[^A-Za-z0-9\-]', '_') + '.xml')
    if ($x.src -and $x.src -eq $dest -and $d.status -eq 'replied') { continue }   # the file saved by an earlier look (2.2.19: only once the record says so)
    # 2.2.8: only a reply that arrived after the LATEST export of this device
    $at = ConvertTo-HikLocalTime ([string]$x.date); $exp = ConvertTo-HikLocalTime ([string]$d.exportedAt)
    # a file time is this PC's own clock (no slack); a mail's time (relay / .eml Date) is the mail server's, so $script:HkReplySkewSec
    # of clock difference is allowed. A true reply comes at least a minute after the export (form, picture code, Hikvision's mail).
    $slack = $(if ([string]$x.src -like 'relay:*' -or [string]$x.src -match '(?i)\.eml$') { $script:HkReplySkewSec } else { 0 })
    if ($at -and $exp -and $at -lt $exp.AddSeconds(-$slack)) {
      $why = ('it arrived ' + $at.ToString('MMM d h:mm tt') + ', before the latest request file for this device (made ' + $exp.ToString('MMM d h:mm tt') + '). It answers an older request, so the device would refuse it.')
      $stale += [pscustomobject]@{ serial = [string]$d.serial; shortSerial = [string]$d.shortSerial; model = [string]$d.model; ip = [string]$d.ip; name = [string]$x.name; mail = [string]$x.mail; src = [string]$x.src; at = $at.ToString('s'); why = $why }
      if (& $isDrop $x.src) { Move-HikDropNotUsed $InboxDir ([string]$x.src) }
      continue
    }
    if ($d.status -eq 'replied' -and (Test-Path -LiteralPath $dest)) { try { if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($dest)) -eq [Convert]::ToBase64String([byte[]]$x.bytes)) { if (& $isDrop $x.src) { Remove-Item -LiteralPath $x.src -Force -ErrorAction SilentlyContinue }; continue } } catch {} }
    # 2.2.18 (sweep B/D): the reply counts as saved only when the saved copy reads back the same; otherwise the device stays waiting
    # and a dropped file is NOT removed (2.2.17 marked it replied and deleted the drop even when the save had failed)
    $saveWhy = ''
    try { [IO.File]::WriteAllBytes($dest, [byte[]]$x.bytes); if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($dest)) -ne [Convert]::ToBase64String([byte[]]$x.bytes)) { $saveWhy = 'the saved copy does not match' } } catch { $saveWhy = $_.Exception.Message }
    if ($saveWhy) { Hk-Say ('  Reply for ' + $d.model + ' ' + $d.ip + ' (serial ' + $d.serial + ') could NOT be saved to ' + $dest + ' (' + $saveWhy + '). It was left where it was; nothing was imported.') 'Yellow'; continue }
    Set-HikStateField $d 'status' 'replied'; Set-HikStateField $d 'replyFile' $dest; Set-HikStateField $d 'replyFrom' ([string]$x.mail)
    Set-HikStateField $d 'replyAt' $(if ($at) { $at.ToString('s') } else { '' }); Set-HikStateField $d 'replyForExport' $(if ($d.PSObject.Properties['exportId']) { [string]$d.exportId } else { '' })
    Set-HikStateField $d 'replySha' (Get-HikBytesSha ([byte[]]$x.bytes))   # 2.2.20 (class D): the import sends exactly these bytes
    $got += $d
    $how = $(if ([string]$x.src -like 'relay:*') { 'the reply mailbox' } elseif (& $isDrop $x.src) { 'the "I got Hik''s email" button' } else { 'the replies folder' })
    Hk-Say ('  Reply for ' + $d.model + ' ' + $d.ip + ' (serial ' + $d.serial + ') found in ' + $how + ', matched by ' + $x.how + $(if ($at) { '; it came ' + $at.ToString('h:mm tt') + ', after ' } else { '; it answers ' }) + (Get-HikExportLabel $d) + '.') 'Green'
    if (& $isDrop $x.src) { $usedDrops += [string]$x.src }
  }
  foreach ($s in @($m.skipped)) { if (-not $s.quiet -and (& $isDrop $s.src)) { Move-HikDropNotUsed $InboxDir ([string]$s.src) } }
  # 2.2.19 (class E): a dropped reply is removed from inbox\hik only once the record that says "replied" is saved; if the save fails the
  # drop stays where it is, so the reply is not lost (2.2.18 removed it first, and the saved copy was then skipped as "already saved")
  if (Save-HikStateOk $StatePath $State) { foreach ($u in @($usedDrops)) { Remove-Item -LiteralPath $u -Force -ErrorAction SilentlyContinue } }
  elseif (@($usedDrops).Count) { Hk-Say '  The reply files were kept in the inbox folder, because the reset record could not be saved.' 'Yellow' }
  # the replies this Toolkit saved itself (replies\reply-<serial>.xml, from earlier runs) are not news about other devices
  $ownSaved = { param($s) [bool]([string]$s -and (Split-Path -Leaf ([string]$s)) -like 'reply-*.xml' -and (Split-Path -Parent ([string]$s)) -eq $ReplyDir) }
  return [pscustomobject]@{ got = $got; unmatched = @($m.unmatched | Where-Object { -not (& $ownSaved $_.src) }); stale = @($stale); skipped = @($m.skipped | Where-Object { -not (& $ownSaved $_.src) }) }
}
# 2.2.8: the plain lines about replies that are NOT used - each said once per run, not on every look (the wait loop looks every few seconds)
$script:HkSaidOnce = @{}
function Show-HikReplyNotes($R) {
  if (-not $R) { return }
  $lines = @()
  foreach ($s in @($R.skipped | Where-Object { $_ -and -not $_.quiet })) {
    $when = ''; $t = ConvertTo-HikLocalTime ([string]$s.date); if ($t) { $when = ', ' + $t.ToString('h:mm tt') }
    $what = $(if ([string]$s.mail) { 'An email from Hikvision ("' + [string]$s.mail + '"' + $when + ')' } else { 'A file from Hikvision' })
    if ([string]$s.why -eq 'it has no attachment') { $lines += , @(($what + ' has no attachment - skipped. If Hikvision sent two emails, the other one has the file.'), 'Yellow') }
    else { $lines += , @(($what + ' skipped: ' + $(if ([string]$s.name) { [string]$s.name + ' - ' } else { '' }) + [string]$s.why + '.'), 'Yellow') }
  }
  foreach ($u in @($R.unmatched | Where-Object { $_ })) { $lines += , @(('A file from Hikvision matches no device here: ' + [string]$u.name + ' - ' + [string]$u.why + '. It is not used.'), 'Yellow') }
  foreach ($s in @($R.stale | Where-Object { $_ })) { $lines += , @(('Not used: the reply ' + [string]$s.name + ' for ' + ([string]$s.model + ' ' + [string]$s.ip).Trim() + ' (serial ' + [string]$s.shortSerial + ') - ' + [string]$s.why + ' Waiting for the reply to the latest request.'), 'Yellow') }
  foreach ($l in $lines) { if ($script:HkSaidOnce.ContainsKey($l[0])) { continue }; $script:HkSaidOnce[$l[0]] = 1; Hk-Say ('  ' + $l[0]) $l[1] }
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
# 2.2.8: what to do after "device refused", in order, with no re-export in between (each export voids the one before)
function Get-HikRefusedSteps($d) {
  $who = ([string]$d.model + ' ' + [string]$d.ip).Trim()
  return @(
    ('  Next, for ' + $who + ' (serial ' + [string]$d.shortSerial + '), in this order and nothing else in between:'),
    '    1. Power-cycle the camera: unplug its power (or its PoE cable) for 10 seconds, plug it back, wait until SADP shows it again.',
    '    2. Export ONE new request file (press Fix this site again, or in SADP: Forgot password > Export). Export only once.',
    '    3. Submit THAT file on Hikvision''s reset page.',
    '    4. Import Hikvision''s reply to that request (the first email after you submitted) - without exporting again first.',
    '    Do not import older files from Downloads: each export voids every earlier reply.'
  )
}
# 2.2.9: what to say after a refusal: reboot + Retry when the checks passed (support after 2), else what was wrong + the steps
function Get-HikRefusedMessage($D, $Problems) {
  $n = 0; try { $n = [int]$D.rebootRetries } catch {}
  if (-not @($Problems).Count) {
    if ($n -ge $script:HkMaxRebootRetries) {
      return @(('  Steps were correct, and the camera also refused after ' + $n + ' reboot-retries.'), (Get-HikSupportLine $D))
    }
    return @(
      '  Steps were correct. Reboot the camera: unplug it or its PoE port for 10 seconds. Wait until SADP shows it Active, then press Retry.',
      ('    Checked: the reply answers the latest export (' + (Get-HikExportLabel $D) + '), no export after it, the camera did not restart before the import, and it is on this PC''s network.'),
      '    Retry = press Fix this site again (or HikReset -Mode Retry). After the power-cycle it makes ONE new request file, you submit it on Hikvision''s page, and only the reply to it is imported, without exporting again in between.',
      ('    Reboot-retries left: ' + ($script:HkMaxRebootRetries - $n) + ' of ' + $script:HkMaxRebootRetries + '. After that: Hik support.')
    )
  }
  $L = @('  The Toolkit''s checks found what was wrong:')
  foreach ($p in @($Problems)) { $L += ('    - ' + $p) }
  return @($L) + @(Get-HikRefusedSteps $D)
}
# $VerifyLogin = scriptblock { param($ip, $password) -> $true when the password logs in } (the caller supplies Test-FsLogin).
# $FindIp = scriptblock { param($dev) -> the device's current IP (it may have moved) }.
function Import-HikReplies($State, [string]$StatePath, [string]$NewPassword, [scriptblock]$VerifyLogin, [string]$Only = '', $OnlySerials = $null) {
  $done = @()
  foreach ($d in @($State.devices | Where-Object { $_.status -eq 'replied' -and ($null -eq $OnlySerials -or @($OnlySerials) -contains [string]$_.serial) -and (-not $Only -or $_.serial -like ('*' + $Only + '*') -or $_.ip -eq $Only -or $_.mac -eq $Only) })) {
    # 2.2.9: the reply chosen is named with the export it answers (time and file), and the one-session rule is said again
    Hk-Say ''; Hk-Say ('Importing the unlock file ' + $(if ([string]$d.replyFile) { Split-Path -Leaf ([string]$d.replyFile) } else { '' }) + ' into ' + $d.model + ' ' + $d.ip + ' (serial ' + $d.serial + ') - Hikvision''s reply to ' + (Get-HikExportLabel $d)) 'Cyan'
    Show-HikSessionGuard
    $seen = @(Find-HikSadp 3)
    # 2.2.19 (class A): the device is the one the record names - its MAC (the serial only when no MAC was saved), never "whatever answers"
    $live = Find-HikLiveDevice $d $seen
    if (-not $live) { Hk-Say '  The device does not answer on the network right now.' 'Yellow'; Set-HikStateField $d 'note' 'not answering'; continue }
    # 2.2.9: the reset needs the camera on a network of this PC; the reply is kept for when it is (not marked refused)
    if (-not (Test-HikOnLocalSubnet $live $seen)) { Set-HikStateField $d 'note' 'on another network than this PC'; if (-not (Save-HikStateOk $StatePath $State)) { Hk-Say (Get-HikNotSavedStop 'The import') 'Red'; break }; continue }
    if ($d.bootTime -and $live.bootTime -and $live.bootTime -ne $d.bootTime) { Hk-Say '  This device restarted after the request file was made, so Hikvision''s file no longer fits it. It needs a new request.' 'Red'; Set-HikStateField $d 'status' 'expired'; Set-HikStateField $d 'note' 'restarted since the request'; if (-not (Save-HikStateOk $StatePath $State)) { Hk-Say (Get-HikNotSavedStop 'The import') 'Red'; break }; continue }
    if (([datetime]$d.validUntil) -lt (Get-Date)) { Hk-Say '  The file is older than 48 hours - Hikvision''s files stop working then. It needs a new request.' 'Red'; Set-HikStateField $d 'status' 'expired'; if (-not (Save-HikStateOk $StatePath $State)) { Hk-Say (Get-HikNotSavedStop 'The import') 'Red'; break }; continue }
    # 2.2.19 (F17 twin): a request file made after the one this reply answers (its start was recorded, the file itself maybe not) voids it
    if (Test-HikExportVoided $State $d) { Hk-Say '  A newer request file was started for this device after the one this reply answers, so Hikvision''s file no longer fits it. It was NOT imported. It needs a new request.' 'Red'; Set-HikStateField $d 'status' 'expired'; Set-HikStateField $d 'note' 'a newer export was started after this request'; if (-not (Save-HikStateOk $StatePath $State)) { Hk-Say (Get-HikNotSavedStop 'The import') 'Red'; break }; continue }
    # 2.2.19 (Codex 2.2.18 F17, class E): the import is written down as STARTED (status importing) and that save is checked BEFORE the
    # file goes to the device. If the PC cannot save it, nothing is sent: a refusal that cannot be recorded must not be repeatable.
    # A record left at "importing" (the run stopped, or the result could not be saved) is never imported again on its own; the next run
    # checks the site password on the device found by its MAC (Invoke-HikResetStage).
    Set-HikStateField $d 'status' 'importing'; Set-HikStateField $d 'importStartedAt' (Get-Date -Format 's'); Set-HikStateField $d 'importFile' ([string]$d.replyFile)
    if (-not (Save-HikStateOk $StatePath $State)) {
      Set-HikStateField $d 'status' 'replied'
      Hk-Say (Get-HikNotSavedStop ('Importing the unlock file into ' + $d.model + ' ' + $d.ip)) 'Red'
      break
    }
    # 2.2.20 (class D): the bytes sent are the bytes that were matched to this device's export when the reply came in (replySha); a reply
    # file replaced on disk since then is NOT imported. A record from before 2.2.20 has no replySha: imported as before.
    $rsha = $(if ($d.PSObject.Properties['replySha']) { [string]$d.replySha } else { '' })
    if ($rsha -and (Get-HikFileSha ([string]$d.replyFile)) -ne $rsha) {
      Set-HikStateField $d 'status' 'replied'; Set-HikStateField $d 'note' 'the saved reply file changed since it was matched - not imported'
      Hk-Say ('  NOT imported: the saved unlock file ' + [string]$d.replyFile + ' is not the one that was matched to this device''s request (it changed on disk since). Nothing was sent. Get Hikvision''s reply again (relay / "I got Hik''s email").') 'Red'
      if (-not (Save-HikStateOk $StatePath $State)) { Hk-Say (Get-HikNotSavedStop 'Any further import') 'Red'; break }
      continue
    }
    $u = Read-HikUnlock $d.replyFile
    $r = Import-HikUnlock $live $u $NewPassword
    # 2.2.20 (Codex 2.2.19 R13 twin, class F): an import that was SENT but got no answer is NOT CONFIRMED - it may have worked. It is not
    # "the reply stays usable" (2.2.19 put it back to "replied", so the next run sent the same file again): the record stays at
    # "importing" (never imported again on its own) and the site password is checked. Only an import that was never sent (no key
    # exchange answer, the old unencrypted form refused) leaves the reply usable. A checker answer without "sent" = treated as sent.
    $ambiguous = (-not $r.ok) -and -not ([string]$r.result -and [string]$r.result -notmatch '^(?i)success') -and -not ($r.PSObject.Properties['sent'] -and $r.sent -eq $false)
    if ($r.ok -or $ambiguous) {
      if ($r.ok) { Set-HikStateField $d 'status' 'imported'; Set-HikStateField $d 'importedAt' (Get-Date -Format 's') }
      else { Set-HikStateField $d 'note' ('import NOT CONFIRMED: ' + [string]$r.error); Hk-Say ('  NOT CONFIRMED: the import was sent but ' + $(if ([string]$r.error) { [string]$r.error } else { 'the device did not answer' }) + '. The file is NOT sent again; checking the site password instead.') 'Yellow' }
      if (-not (Save-HikStateOk $StatePath $State)) { Hk-Say ('  The import result for ' + $d.model + ' ' + $d.ip + ' could not be saved; the record still says the import was started, so the file is not sent again.') 'Red' }
      Start-Sleep -Seconds 3
      $ip = $live.ip; $chk = $false
      # 2.2.3 (Codex #29): wait for the device to be back (SADP, no login), then at most 2 login tries - a wrong password 6 times
      # in a row is how Hikvision locks a device. 2.2.20 (class C): only a real $true from the checker counts (Test-HikLoginOk).
      $logins = 0; for ($i = 0; $i -lt 8 -and -not $chk -and $logins -lt $script:HkVerifyMaxLogins; $i++) { $now = Find-HikLiveDevice $d @(Find-HikSadp 2); if ($now) { $ip = $now.ip; $logins++; $chk = Test-HikLoginOk $VerifyLogin $ip $NewPassword $d }; if (-not $chk) { Start-Sleep -Seconds 4 } }
      if ($chk) { Set-HikStateField $d 'status' 'verified'; Set-HikStateField $d 'verifiedAt' (Get-Date -Format 's'); Hk-Say ('  Reset done. The site password logs in on ' + $ip + '.') 'Green'; $done += $d; Show-HikExtraIpReminder $live }
      elseif ($r.ok) { Hk-Say ('  The device accepted the file, but the site password does not log in yet on ' + $ip + '. Check it in a minute.') 'Yellow' }
      else { Hk-Say ('  NOT CONFIRMED: the site password does not log in on ' + $ip + ' (yet). The file is not sent again; the next run checks the site password once more. If it still does not log in, it needs a new request.') 'Yellow' }
    } elseif ([string]$r.result -and [string]$r.result -notmatch '^(?i)success') {
      # 2.2.8: the device ANSWERED and said no (SADP shows it as "Resetting the password failed. Device refused to process").
      # Almost always: the file does not belong to the device's latest request (an older reply, or a new export made after it was
      # sent). Importing it again, or other files from Downloads, cannot work; a new export now would void the next reply too.
      Set-HikStateField $d 'status' 'refused'; Set-HikStateField $d 'note' ('the device refused the unlock file (it answered "' + [string]$r.result + '")')
      # 2.2.19 (F17): "will not be tried again" is true either way now - the record already says "importing" on disk (saved above), and an
      # "importing" record is never imported again; the refusal itself is saved here
      Hk-Say ('  The device REFUSED Hikvision''s file (it answered "' + [string]$r.result + '"). This file will not be tried again.') 'Red'
      # 2.2.9 (Moshe, Nov 8 9:55 PM): when the Toolkit's own checks passed, the steps were right: reboot the camera, then Retry
      # (at most 2 reboot-retries, then Hik support). When a check did not pass, say what was wrong instead.
      $probs = @(Get-HikRefusalProblems $State $d)
      Set-HikStateField $d 'refusedChecksOk' (-not $probs.Count)
      if (-not $d.PSObject.Properties['rebootRetries']) { Set-HikStateField $d 'rebootRetries' 0 }
      Save-HikState $StatePath $State
      foreach ($l in @(Get-HikRefusedMessage $d $probs)) { Hk-Say $l $(if ($l -match '^\s*(Steps were correct|Call Hik support)') { 'Cyan' } else { 'Yellow' }) }
    } else {
      Hk-Say ('  The import did not work (' + $r.error + ').') 'Yellow'
      # nothing reached the device (no key exchange answer / the file needs SADP by hand): the reply stays usable, as before
      Set-HikStateField $d 'status' 'replied'
      Set-HikStateField $d 'note' ('import: ' + $r.error)
      # last resort, still the official path: SADP's own "Forgot password > Import file" with the file ready
      Hk-Say ('  Finish this one in SADP: tick the device, Forgot password, Import file, pick ' + $d.replyFile + ', type the site password.') 'Yellow'
    }
    if (-not (Save-HikStateOk $StatePath $State)) {
      Hk-Say ('  The result for ' + $d.model + ' ' + $d.ip + ' could not be saved. The record still says the import was started, so this file is NOT sent again; the next run checks the site password on the device instead.') 'Red'
      Hk-Say (Get-HikNotSavedStop 'Any further import') 'Red'
      break
    }
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
$script:HkVerifyMaxLogins = 2   # 2.2.3 (Codex #29)
function Get-HikConfig($CfgAll, [string]$ToolkitDir = '') {
  $relay = [pscustomobject]@{ url = ''; address = 'hikreset@wireitct.com'; everySec = 60 }
  $wait = 15; $replyDir = ''
  if ($CfgAll -and $CfgAll.PSObject.Properties['hikReset'] -and $CfgAll.hikReset) {
    $h = $CfgAll.hikReset
    if ($h.PSObject.Properties['relay'] -and $h.relay) { foreach ($p in $h.relay.PSObject.Properties) { if ($relay.PSObject.Properties[$p.Name]) { $relay.($p.Name) = $p.Value } } }
    if ($h.PSObject.Properties['waitMinutes'] -and [int]$h.waitMinutes -gt 0) { $wait = [int]$h.waitMinutes }
    if ($h.PSObject.Properties['replyDir']) { $replyDir = [string]$h.replyDir }
    if ($h.PSObject.Properties['sadpLegacyPlainPassword'] -and $h.sadpLegacyPlainPassword -eq $true) { $script:SadpAllowPlainPassword = $true }   # 2.2.3 (Codex #6): Admin's explicit opt-in only
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
  # 2.2.18 (sweep C/D): a reset record that cannot be read stops the reset here (nothing sent); every target is pending with the reason
  $state = $null; try { $state = Read-HikState $statePath } catch { $rsWhy = $_.Exception.Message; Hk-Say ('  ' + $rsWhy) 'Red'; return [pscustomobject]@{ fixed = @(); pending = @(@($Targets) | ForEach-Object { [pscustomobject]@{ mac = (ConvertTo-SadpMac ([string]$_.mac)); reason = 'reset not started: the reset record on this PC could not be read (see above)' } }) } }
  $want = @{}; foreach ($t in @($Targets)) { $m = ConvertTo-SadpMac ([string]$t.mac); if ($m) { $want[$m] = $t } }
  # 2.2.19 (Codex 2.2.18 F17, class E): the record must be savable before anything is sent to a device; if it is not, nothing starts
  if (-not (Save-HikStateOk $statePath $state)) {
    Hk-Say (Get-HikNotSavedStop 'The reset') 'Red'
    return [pscustomobject]@{ fixed = @(); pending = @(@($Targets) | ForEach-Object { [pscustomobject]@{ mac = (ConvertTo-SadpMac ([string]$_.mac)); reason = 'reset not started: the reset record on this PC could not be saved (see above)' } }) }
  }
  Hk-Say 'Finding the Hikvision devices (any IP range)...'
  $devs = @(Find-HikSadp 4 | Where-Object { $want.ContainsKey($_.mac) })
  $fixed = @(); $pending = @()
  foreach ($m in $want.Keys) { if (-not @($devs | Where-Object { $_.mac -eq $m }).Count) { $pending += [pscustomobject]@{ mac = $m; reason = 'not seen on the network (check power and cable)' } } }
  $forMine = { param($st) @($st.devices | Where-Object { $want.ContainsKey((ConvertTo-SadpMac ([string]$_.mac))) }) }
  # 2.2.1: a device whose unlock file was imported in an earlier run that stopped before the check: check its login now (once)
  # 2.2.2 (Codex, reset resume): this check runs BEFORE any new export. 2.2.1 exported first, which reset an "imported" device to
  # "exported", so the check never saw it (and a fresh request cancelled the reset that had worked).
  # 2.2.19 (Codex 2.2.18 F16, class A): the device is found again in THIS scan by its MAC (serial only when no MAC was saved) and its
  # password is checked at the address it has NOW. 2.2.18 checked the saved address: another camera that moved onto it and took the site
  # password made the selected camera "fixed". Not found = NOT CHECKED (it stays pending; nothing is checked at the old address).
  # "importing" = an import was started but its result was never saved (F17): same check, and the file is never sent again on its own.
  foreach ($d in @(& $forMine $state | Where-Object { $_.status -eq 'imported' -or $_.status -eq 'importing' })) {
    $live = Find-HikLiveDevice $d $devs
    if (-not $live) { Hk-Say ('  ' + $d.model + ' (serial ' + [string]$d.serial + '): the unlock file was imported earlier, but the device is not seen in this scan - the site password is NOT CHECKED.') 'Yellow'; continue }
    $ipNow = [string]$live.ip
    $okv = Test-HikLoginOk $VerifyLogin $ipNow $SitePassword $d   # 2.2.20 (class C): only a real $true
    if ($okv) {
      Set-HikStateField $d 'status' 'verified'; Set-HikStateField $d 'verifiedAt' (Get-Date -Format 's'); Set-HikStateField $d 'ip' $ipNow
      if (-not (Save-HikStateOk $statePath $state)) { Hk-Say ('  (the reset record could not be saved: the next run checks this device''s password once more)') 'Yellow' }
      $fixed += (ConvertTo-SadpMac ([string]$d.mac)); Hk-Say ('  ' + $d.model + ' ' + $ipNow + ': the earlier reset worked - the site password logs in.') 'Green'
    } elseif ([string]$d.status -eq 'importing') {
      Hk-Say ('  ' + $d.model + ' ' + $ipNow + ': an earlier import of Hikvision''s file was started but its result was not saved, and the site password does not log in. That file is NOT sent again. It needs a new request.') 'Yellow'
    }
  }
  # 2.2.3 (Codex #57): a reset verified in an EARLIER run counts only if the site password still logs in now (one try, at the address
  # the device has now). A factory reset or password change since then = it is reset again.
  foreach ($d in @(& $forMine $state | Where-Object { $_.status -eq 'verified' })) {
    $mv = ConvertTo-SadpMac ([string]$d.mac); if ($fixed -contains $mv) { continue }
    $live = Find-HikLiveDevice $d $devs; $ipNow = $(if ($live) { [string]$live.ip } else { [string]$d.ip })
    $okv = $false; if ($live) { $okv = Test-HikLoginOk $VerifyLogin $ipNow $SitePassword $d }   # 2.2.20 (class C): only a real $true
    if ($okv) { $fixed += $mv }
    elseif ($live) { Set-HikStateField $d 'status' 'stale'; if (-not (Save-HikStateOk $statePath $state)) { Hk-Say ('  The reset record could not be saved (' + $script:HkStateSaveWhy + ').') 'Red' }; Hk-Say ('  ' + $d.model + ' ' + $ipNow + ': was reset before, but the site password no longer logs in - it is reset again.') 'Yellow' }
  }
  # a device that is already done is never asked for a new request file
  $todo = @($devs | Where-Object { $_.activated -and $fixed -notcontains (ConvertTo-SadpMac ([string]$_.mac)) })
  # 2.2.9: a camera on no network of this PC is not exported (the steps are said once); it is pending with the reason
  $todo = @(foreach ($t in $todo) { if (Test-HikOnLocalSubnet $t $devs) { $t } else { $pending += [pscustomobject]@{ mac = $t.mac; reason = [string]$script:HkSubnetBlocked[[string]$t.serial] } } })
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
    Show-HikReplyNotes $r   # 2.2.8: skipped / stale / unmatched files, each with its reason, said once
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
    if ($script:HkSubnetBlocked.ContainsKey([string]$d.serial) -and @($pending | Where-Object { (ConvertTo-SadpMac ([string]$_.mac)) -eq (ConvertTo-SadpMac ([string]$d.mac)) }).Count) { continue }   # 2.2.9: said once
    $why = switch ($d.status) { 'submitted' { 'sent to Hikvision, waiting for the unlock email (it can take a few hours). When it comes: press "I got Hik''s email" (or, with the reply mailbox set up, just press Fix this site again). The device must NOT restart meanwhile.' } 'exported' { 'request file made, not sent to Hikvision yet' } 'replied' { 'unlock file arrived but the import did not work' + $(if ($d.note) { ' (' + $d.note + ')' } else { '' }) } 'imported' { 'the unlock file was imported, but the site password is NOT CHECKED yet (the device was not seen, or it did not log in yet). Press Fix this site again when SADP shows it.' } 'exporting' { 'a request file was asked for but the result was not recorded: NOT CONFIRMED. It is not asked again on this start-up of the camera: register that file (HikReset -RegisterDir), or reboot the camera and press Fix this site again' } 'importing' { 'an import of Hikvision''s file was started but its result was not saved: NOT CHECKED. That file is not sent again; if the site password does not log in, it needs a new request.' } 'expired' { 'the request is no longer valid (' + $d.note + '): it needs a new one' } 'refused' { $(if (-not ($d.PSObject.Properties['refusedChecksOk'] -and $d.refusedChecksOk -and [int]$d.rebootRetries -ge $script:HkMaxRebootRetries)) { 'the device refused Hikvision''s file. Power-cycle it (unplug it or its PoE port for 10 seconds), wait until SADP shows it Active, then press Fix this site again: it makes ONE new request; submit it and import only the reply to it (no export in between)' } else { 'the device refused Hikvision''s file after correct steps and ' + [int]$d.rebootRetries + ' reboot-retries: call Hik support with the serial (' + [string]$d.serial + ') and the SADP log' }) } default { [string]$d.status } }
    $pending += [pscustomobject]@{ mac = $d.mac; reason = $why }
  }
  return [pscustomobject]@{ fixed = @($fixed); pending = @($pending) }
}
