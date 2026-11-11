<# Test-Fix229.ps1 - behavioural tests for 2.2.9 (three on-site lessons from the 3 Hewlett camera .7 reset, Nov 8 2026).
   What happened on site: camera .7 was on 10.243.1.7/24 while the laptop was on 192.168.1.x (the first tries could not work);
   setting the laptop to a static IP took it fully offline; several exports / replies piled up and every import was refused; Hik's
   page wanted a person for its slider and the Toolkit waited without saying so.
   HS1 subnet check: a camera that is not on any subnet of this PC's active adapters stops the export / the reset, with plain steps
       (a SECOND IP on the camera's subnet on the wired adapter, "Obtain automatically" kept, no gateway; remove it afterwards).
       Never a switch to static IP; never a suggested address that answers ping (or that a Hik device here already has).
   HS2 one-session guard: "Keep SADP open from export until import. Export once. Submit that file. Import only Hik's reply to it."
       and the export's time and file name next to the reply chosen.
   HS4 (Moshe 9:55 PM) "device refused" when the Toolkit's checks passed: "Steps were correct. Reboot the camera ..." then Retry =
       one fresh cycle; at most 2 reboot-retries, then "Call Hik support with the serial and the SADP log."; checks not passed = what
       was wrong instead.
   HS3 slider: a clear "Solve the slider in the browser window now" line when Hik's page shows its slider, the window brought to the
       front, a reminder while waiting (never silent), and a timeout that says what to do next.
   Real functions (HikResetFlow, HikPortal). Only the device's SADP answers, this PC's adapter list, ping and the browser's page
   answers are stood in for. No adapter is changed by any code here. Windows PowerShell 5.1 or pwsh 7. #>
$ErrorActionPreference = 'Stop'
$tk = Split-Path -Parent $PSScriptRoot; $repo = Split-Path -Parent $tk
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fix229-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$script:pass = 0; $script:fail = 0
function Check([bool]$ok, [string]$name, [string]$more = '') {
  if ($ok) { $script:pass++; Write-Host ('PASS ' + $name) } else { $script:fail++; Write-Host ('FAIL ' + $name); if ($more) { Write-Host ('     ' + $more) } }
}
function Said([string]$rx) { return @($script:said | Where-Object { $_ -match $rx }) }
function All { return (($script:said) -join ' | ') }
$SN = 'ECI-T44F220220903AAWRK52336660'; $SH = 'K52336660'; $MAC = '24-0f-9b-11-22-07'
$GUARD = 'Keep SADP open from export until import. Export once. Submit that file. Import only Hik''s reply to it.'
$unlockXml = '<?xml version="1.0" encoding="UTF-8"?><ResetPassword><SerialNumber>' + $SN + '</SerialNumber><Code>Ab3dE5fG</Code></ResetPassword>'
function Net([string]$name, [string]$ip, [int]$prefix, [bool]$wired = $true, [int]$count = 1) { return [pscustomobject]@{ name = $name; ip = $ip; prefix = $prefix; wired = $wired; count = $count } }
$laptop = @((Net 'Ethernet' '192.168.1.127' 24 $true), (Net 'Wi-Fi' '192.168.1.130' 24 $false))
$cam = [pscustomobject]@{ serial = $SN; shortSerial = $SH; mac = $MAC; model = 'ECI-T44F2'; ip = '10.243.1.7'; mask = '255.255.255.0'; gw = '10.243.1.1'; kind = 'camera'; activated = $true; bootTime = '2026-11-08 21:08:00'; salt = ''; encrypt = $false }

try {
  . (Join-Path $tk 'HikResetFlow.ps1')
  $script:said = New-Object System.Collections.ArrayList
  $script:HkSay = { param($t, $c) [void]$script:said.Add([string]$t) }; $script:HkAsk = { param($t) '' }
  $script:pinged = New-Object System.Collections.ArrayList; $script:answers = @()
  $script:HkPing = { param($ip) [void]$script:pinged.Add([string]$ip); return ($script:answers -contains [string]$ip) }
  $script:exportN = 0
  function Request-HikResetExport($d) { $script:exportN++; return [pscustomobject]@{ ok = $true; type = 'file'; raw = ''; request = [pscustomobject]@{ value = ('REQ' + $script:exportN + 'X') }; bootTime = $d.bootTime; error = '' } }

  # =====================================================================================
  Write-Host 'HS1. a camera on another subnet stops the export, with the second-IP steps'
  Check ((Get-Command Test-HikOnLocalSubnet -ErrorAction SilentlyContinue) -and (Get-Command Get-HikLocalNets -ErrorAction SilentlyContinue)) 'HS1 the reset flow has a subnet check (Test-HikOnLocalSubnet, Get-HikLocalNets)'
  Check ((Test-HikSameSubnet '10.243.1.7' '192.168.1.127' 24) -eq $false -and (Test-HikSameSubnet '10.243.1.7' '10.243.1.50' 24) -eq $true -and (Test-HikSameSubnet '10.243.9.7' '10.243.1.50' 16) -eq $true -and (Test-HikSameSubnet '192.168.2.10' '192.168.1.127' 24) -eq $false) 'HS1 same-subnet maths: 10.243.1.7 is not on 192.168.1.127/24, is on 10.243.1.50/24; /16 and a neighbouring /24 right'
  $script:HkLocalNets = $laptop
  $sp = Join-Path $tmp 'hs1/state.json'; $rq = Join-Path $tmp 'hs1/requests'; $st = Read-HikState $sp
  $script:said.Clear(); $script:exportN = 0; $script:pinged.Clear(); $script:HkSaidOnce = @{}
  $made = @(Export-HikRequests @($cam) $rq $st $sp)
  Check ($script:exportN -eq 0 -and $made.Count -eq 0 -and -not @(@($st.devices) | Where-Object { $_.status -eq 'exported' }).Count) 'HS1 tonight''s case (camera 10.243.1.7/24, laptop 192.168.1.x): NO export is made (the device is never asked)' (All)
  Check (@(Said '10\.243\.1\.7').Count -and @(Said '(?i)192\.168\.1\.127').Count -and @(Said '(?i)not on (any|a) network|another network|different network|other subnet').Count) 'HS1 ...the screen says why: the camera''s address and this PC''s addresses, not on the same network' (All)
  $a = All
  Check ($a -match '10\.243\.1\.50' -and $a -match '255\.255\.255\.0' -and $a -match '(?i)gateway.{0,20}(empty|blank|none|no)|no gateway|(empty|blank).{0,20}gateway') 'HS1 ...suggests a second IP on the camera''s subnet: 10.243.1.50 / 255.255.255.0, no gateway' $a
  Check ($a -match 'Control Panel' -and $a -match 'Network Connections' -and $a -match '(?i)Ethernet' -and $a -match 'IPv4' -and $a -match 'Properties' -and $a -match 'Advanced' -and $a -match '\bAdd\b') 'HS1 ...the path: Control Panel > Network Connections > Ethernet > IPv4 > Properties > Advanced > Add' $a
  Check ($a -match '(?i)keep.{0,40}Obtain an IP address automatically|Obtain an IP address automatically.{0,40}(stays|keep|leave)') 'HS1 ...while keeping "Obtain an IP address automatically"' $a
  Check ($a -match '(?i)after the reset.{0,80}remove|remove.{0,80}after the reset') 'HS1 ...and to remove it after the reset' $a
  # 2.2.10 (R02): the netsh coexistence setting's own name (dhcpstaticipcoexistence / "DHCP/Static IP Coexistence") is not a static-IP step
  $staticBad = @($script:said | Where-Object { ($_ -replace '(?i)dhcpstaticipcoexistence|DHCP/Static IP Coexistence', '') -match '(?i)static|Use the following IP address' -and $_ -notmatch '(?i)\b(not|never|don''t)\b' })
  Check (-not $staticBad.Count) 'HS1 it never tells the tech to switch to a static IP ("Use the following IP address") - that took the laptop offline' ($staticBad -join ' | ')
  Check ($script:pinged -contains '10.243.1.50') 'HS1 the suggested address is checked with ping before it is offered' (($script:pinged) -join ',')
  Check (@(Said '(?i)wired|Ethernet').Count -and -not @(Said '(?i)on .{0,10}Wi-?Fi.{0,30}(add|second)').Count) 'HS1 the second IP goes on the wired adapter (named), not on Wi-Fi' (All)
  # a suggestion that answers ping is never offered; nor the camera's own address, the gateway or another Hik device seen here
  $script:answers = @('10.243.1.50', '10.243.1.51'); $script:pinged.Clear()
  $sg = Get-HikSecondIpSuggestion $cam @([pscustomobject]@{ ip = '10.243.1.52' })
  Check ($sg -and $sg.ip -eq '10.243.1.53' -and $sg.mask -eq '255.255.255.0') ('HS1 .50 and .51 answer ping, .52 is another Hik device here: the suggestion is .53 (' + [string]$sg.ip + ')')
  Check ($script:pinged -contains '10.243.1.50' -and $script:pinged -contains '10.243.1.51' -and $script:pinged -notcontains '10.243.1.52') 'HS1 ...each candidate was pinged (the one a device already has was skipped without a ping)' (($script:pinged) -join ',')
  $cam50 = [pscustomobject]@{ ip = '10.243.1.50'; mask = '255.255.255.0'; gw = '10.243.1.1' }
  $script:answers = @()
  $sg2 = Get-HikSecondIpSuggestion $cam50 @()
  Check ($sg2 -and $sg2.ip -ne '10.243.1.50' -and $sg2.ip -ne '10.243.1.1' -and $sg2.ip -like '10.243.1.*') ('HS1 a camera that itself is .50: never suggests its own address or the gateway (' + [string]$sg2.ip + ')')
  $script:answers = @(1..254 | ForEach-Object { '10.243.1.' + $_ })
  $sg3 = Get-HikSecondIpSuggestion $cam @()
  Check ($null -eq $sg3 -or -not $sg3.ip) 'HS1 when every candidate answers ping, NO address is suggested (never a duplicate)'
  $script:said.Clear(); $script:HkSaidOnce = @{}
  [void](Test-HikOnLocalSubnet $cam)
  Check (@(Said '(?i)ping').Count -and -not @(Said '10\.243\.1\.50').Count) 'HS1 ...and the screen says to pick a free one and check it with ping instead' (All)
  $script:answers = @()
  $camNoMask = [pscustomobject]@{ serial = $SN; mac = $MAC; model = 'ECI-T44F2'; ip = '10.243.1.7'; mask = ''; gw = '' }
  $sg4 = Get-HikSecondIpSuggestion $camNoMask @()
  Check ($sg4 -and $sg4.mask -eq '255.255.255.0' -and $sg4.ip -eq '10.243.1.50') 'HS1 a camera whose mask SADP did not give: 255.255.255.0 is used for the suggestion'
  # on the same subnet: the export goes ahead, no steps
  $script:HkLocalNets = @((Net 'Ethernet' '192.168.1.127' 24 $true 2), (Net 'Ethernet' '10.243.1.50' 24 $true 2))
  $script:said.Clear(); $script:exportN = 0; $script:HkSaidOnce = @{}
  $sp2 = Join-Path $tmp 'hs1b/state.json'; $st2 = Read-HikState $sp2
  $made = @(Export-HikRequests @($cam) (Join-Path $tmp 'hs1b/req') $st2 $sp2)
  Check ($script:exportN -eq 1 -and (Get-HikStateDevice $st2 $SN).status -eq 'exported' -and -not @(Said '(?i)Control Panel').Count) 'HS1 with the second IP on (10.243.1.50/24 on Ethernet): the export goes ahead, no steps shown' (All)
  # this PC's addresses could not be read: not blocked, but said
  $script:HkLocalNets = @(); $script:said.Clear(); $script:exportN = 0; $script:HkSaidOnce = @{}
  $sp3 = Join-Path $tmp 'hs1c/state.json'; $st3 = Read-HikState $sp3
  $null = Export-HikRequests @($cam) (Join-Path $tmp 'hs1c/req') $st3 $sp3
  Check ($script:exportN -eq 1 -and @(Said '(?i)could not (read|check)|not checked').Count) 'HS1 when this PC''s addresses cannot be read, it does not block, and says it was not checked' (All)
  # the reset (import) is stopped the same way, and the reply is kept (not "refused")
  $script:HkLocalNets = $laptop; $script:said.Clear(); $script:HkSaidOnce = @{}
  $script:importN = 0
  function Find-HikSadp($s) { return @($cam) }
  function Read-HikUnlock([string]$f) { return [pscustomobject]@{ kind = 'file'; code = 'Ab3dE5fG'; file = $f } }
  function Import-HikUnlock($l, $u, $pw) { $script:importN++; return [pscustomobject]@{ ok = $true; result = 'success'; form = 'x'; tries = 1; error = '' } }
  $d = Get-HikStateDevice $st2 $SN; $rf = Join-Path $tmp 'hs1b/reply.xml'; [IO.File]::WriteAllText($rf, $unlockXml)
  Set-HikStateField $d 'status' 'replied'; Set-HikStateField $d 'replyFile' $rf; Save-HikState $sp2 $st2
  $done = @(Import-HikReplies $st2 $sp2 'Site-Pass-1234' { param($ip, $p) $true })
  Check ($script:importN -eq 0 -and $done.Count -eq 0 -and (Get-HikStateDevice $st2 $SN).status -eq 'replied') 'HS1 the reset itself (SADP import) is not tried while the camera is on another subnet; the reply is kept for later (not marked refused)' (All)
  Check (@(Said '10\.243\.1\.50').Count -and @(Said '(?i)Control Panel').Count) 'HS1 ...with the same second-IP steps' (All)
  # after a reset that worked with a second IP on: reminder to remove it
  $script:HkLocalNets = @((Net 'Ethernet' '192.168.1.127' 24 $true 2), (Net 'Ethernet' '10.243.1.50' 24 $true 2)); $script:said.Clear(); $script:HkSaidOnce = @{}
  $script:HkVerifyMaxLogins = 1
  function Start-Sleep { param([int]$Seconds, [int]$Milliseconds) }
  $done = @(Import-HikReplies $st2 $sp2 'Site-Pass-1234' { param($ip, $p) $true })
  Remove-Item function:Start-Sleep
  Check ($script:importN -eq 1 -and $done.Count -eq 1) 'HS1 with the second IP on, the reset goes ahead' (All)
  Check (@(Said '(?i)remove.{0,60}10\.243\.1\.50|10\.243\.1\.50.{0,80}remove').Count -and @(Said '(?i)Obtain an IP address automatically').Count) 'HS1 ...and after it worked, it says to remove the extra 10.243.1.50 from Ethernet (keeping "Obtain automatically")' (All)
  # Fix this site's stage: the blocked camera is listed as pending with the reason
  $script:HkLocalNets = $laptop; $script:said.Clear(); $script:exportN = 0; $script:HkSaidOnce = @{}
  $sd4 = Join-Path $tmp 'hs1d'
  $hs = Invoke-HikResetStage -Targets @([pscustomobject]@{ mac = $MAC }) -SitePassword 'x' -StateDir $sd4 -Config ([pscustomobject]@{ form = $null; relay = $null; replyTo = ''; replyDir = '' }) -VerifyLogin { param($ip, $p) $false } -WaitMinutes 0
  $pr = @($hs.pending | Where-Object { (ConvertTo-SadpMac ([string]$_.mac)) -eq (ConvertTo-SadpMac $MAC) })
  Check ($script:exportN -eq 0 -and $pr.Count -eq 1 -and [string]$pr[0].reason -match '(?i)network|subnet' -and [string]$pr[0].reason -match '10\.243\.1') ('HS1 Fix this site''s reset stage: no export, and the camera is pending with the reason (' + [string]@($pr)[0].reason + ')')
  # this PC's real adapters can be read without an error (whatever this machine has)
  $script:HkLocalNets = $null
  $real = $null; $rthrew = ''; try { $real = @(Get-HikLocalNets) } catch { $rthrew = $_.Exception.Message }
  Check (-not $rthrew -and @($real | Where-Object { -not $_.ip -or $null -eq $_.prefix }).Count -eq 0) ('HS1 this PC''s own adapters are read without an error (' + @($real).Count + ' address(es): ' + (($real | ForEach-Object { $_.name + ' ' + $_.ip + '/' + $_.prefix }) -join ', ') + ')') $rthrew
  # no adapter is changed by code
  $flowSrc = [IO.File]::ReadAllText((Join-Path $tk 'HikResetFlow.ps1')); $hrSrc0 = [IO.File]::ReadAllText((Join-Path $tk 'HikReset.ps1'))
  Check (($flowSrc + $hrSrc0) -notmatch '(?i)New-NetIPAddress|Set-NetIPInterface|Set-NetIPAddress|Remove-NetIPAddress|Start-Process[^\r\n]*netsh|&\s*''?netsh|Invoke-Expression[^\r\n]*netsh|cmd(\.exe)?\s*/c[^\r\n]*netsh') 'HS1 no code changes an adapter (no New-NetIPAddress / Set-NetIPInterface / netsh run): it only checks and tells'

  # =====================================================================================
  Write-Host 'HS2. one session: the guard text, and the export''s time + file next to the reply chosen'
  $script:HkLocalNets = @((Net 'Ethernet' '10.243.1.50' 24 $true 1)); $script:said.Clear(); $script:HkSaidOnce = @{}
  $sp5 = Join-Path $tmp 'hs2/state.json'; $st5 = Read-HikState $sp5; $rq5 = Join-Path $tmp 'hs2/requests'
  $null = Export-HikRequests @($cam) $rq5 $st5 $sp5
  Check (@($script:said | Where-Object { $_.Contains($GUARD) }).Count -ge 1) 'HS2 the export says: "Keep SADP open from export until import. Export once. Submit that file. Import only Hik''s reply to it."' (All)
  $d5 = Get-HikStateDevice $st5 $SN; Set-HikStateField $d5 'status' 'submitted'; Set-HikStateField $d5 'submittedAt' (Get-Date -Format 's'); Save-HikState $sp5 $st5
  $reqLeaf = Split-Path -Leaf ([string]$d5.requestFile); $expT = ([datetime]$d5.exportedAt).ToString('h:mm tt')
  $rep5 = Join-Path $tmp 'hs2/replies'; New-Item -ItemType Directory -Force -Path $rep5 | Out-Null
  Start-Sleep -Milliseconds 1100
  $nf = Join-Path $rep5 ($SN + '.xml'); [IO.File]::WriteAllText($nf, $unlockXml)
  $script:said.Clear()
  $rr = Receive-HikReplies $st5 $sp5 (Get-HikConfig $null) $tmp $rep5
  $gl = @(Said '(?i)Reply for ')
  Check (@($rr.got).Count -eq 1 -and $gl.Count -eq 1 -and $gl[0].Contains($reqLeaf) -and $gl[0].Contains($expT)) ('HS2 the reply chosen is shown with the export''s time (' + $expT + ') and file name (' + $reqLeaf + ')') (All)
  $script:said.Clear(); $script:importN = 0
  function Start-Sleep { param([int]$Seconds, [int]$Milliseconds) }
  $null = @(Import-HikReplies $st5 $sp5 'Site-Pass-1234' { param($ip, $p) $true })
  Remove-Item function:Start-Sleep
  $il = @(Said '(?i)Importing')
  Check ($il.Count -ge 1 -and (($il -join ' ').Contains($reqLeaf)) -and (($il -join ' ').Contains($expT)) -and (($il -join ' ').Contains((Split-Path -Leaf ([string](Get-HikStateDevice $st5 $SN).replyFile))))) 'HS2 the import line names the reply file AND the export it answers (time and file name)' (All)
  Check (@($script:said | Where-Object { $_.Contains($GUARD) }).Count -ge 1) 'HS2 the guard text is said again at the import' (All)
  $hrSrc = [IO.File]::ReadAllText((Join-Path $tk 'HikReset.ps1'))
  Check ($hrSrc.Contains('Show-HikSessionGuard')) 'HS2 HikReset.ps1 (the manual / SADP path) shows the same guard text'

  # =====================================================================================
  Write-Host 'HS3. Hik''s slider: a clear line, window to the front, reminders, and a timeout that says what next'
  . (Join-Path $tk 'HikPortal.ps1')
  $script:psaid = New-Object System.Collections.ArrayList
  $script:PortalSay = { param($t, $c) [void]$script:psaid.Add([string]$t) }
  $script:cdpSent = New-Object System.Collections.ArrayList
  $script:pollN = 0
  function Send-Cdp($c, [string]$Method, $Params = $null, [int]$TimeoutSec = 20) { [void]$script:cdpSent.Add($Method); return $null }
  function Invoke-CdpJs($c, [string]$Js, [int]$TimeoutSec = 20) {
    if ($Js -notmatch 'formShown') { return 1 }
    $script:pollN++
    $modal = ($script:pollN -ge 3 -and $script:pollN -le 12) -or ($script:pollN -ge 20)
    return [pscustomobject]@{ url = 'https://www.hikvision.com/en/support/tools/password-reset/'; formShown = $true; clicks = 0; posts = @(); modal = $modal; slider = $modal; text = 'Reset form'; base = 'Reset form' }
  }
  $script:PortalPollMs = 40; $script:PortalRemindSec = 1
  $sess = [pscustomobject]@{ cdp = 'x'; proc = [pscustomobject]@{ HasExited = $false; MainWindowHandle = [IntPtr]::Zero }; profile = ''; port = 1; exe = 'x' }
  $res = Wait-PortalSubmitted $sess 3
  $sl = @($script:psaid | Where-Object { $_ -match 'Solve the slider in the browser window now' })
  Check ($res -eq 'timeout' -and $sl.Count -eq 2) ('HS3 "Solve the slider in the browser window now" is said when the slider appears - once per appearance, not every poll (' + $sl.Count + ' times for 2 appearances)') ((($script:psaid) -join ' | '))
  $btf = @($script:cdpSent | Where-Object { $_ -eq 'Page.bringToFront' }).Count
  Check ($btf -ge 3) ('HS3 ...and the browser window is brought to the front each time (Page.bringToFront ' + $btf + ' times: start + 2 slider appearances)')
  Check (@($script:psaid | Where-Object { $_ -match '(?i)still waiting' }).Count -ge 1) 'HS3 while it waits, it says so (a "still waiting" line with what to do), not silence' ((($script:psaid) -join ' | '))
  # Submit's timeout: what next
  function Find-HikBrowser { return 'chrome.exe' }
  function Start-HikBrowserSession([string]$Url) { return $sess }
  function Stop-HikBrowserSession($s) { }
  function Wait-PortalForm($s, [int]$Seconds = 45) { return $true }
  function Fill-HikPortalForm($s, $form, $dev, [string]$File) { return [pscustomobject]@{} }
  function Test-PortalFilled($r, $dev) { return @() }
  function Wait-PortalSubmitted($s, [int]$TimeoutSec = 900, [scriptblock]$Tick = $null, [scriptblock]$Refill = $null) { return 'timeout' }
  $sp6 = Join-Path $tmp 'hs3/state.json'; $st6 = Read-HikState $sp6
  $script:HkLocalNets = @((Net 'Ethernet' '10.243.1.50' 24 $true 1))
  $null = Export-HikRequests @($cam) (Join-Path $tmp 'hs3/req') $st6 $sp6
  $script:said.Clear()
  $sent = @(Submit-HikRequests $st6 $sp6 ([pscustomobject]$script:HkDefaultForm) 600)
  $a = All
  $d6 = Get-HikStateDevice $st6 $SN
  Check ($sent.Count -eq 0 -and $d6.status -eq 'exported') 'HS3 a timeout on Hik''s page: not submitted, and the request file stays as it is' $a
  Check ($a -match '(?i)slider' -and $a -match '(?i)(10 min|600)' -and $a -match '(?i)(not|never|no|don''t) .{0,30}export' -and $a -match '(?i)(run|press).{0,40}again' -and $a -match '(?i)Submit') 'HS3 ...the timeout says what to do next: it waited 10 min for the slider/Submit, do not export again, run it again, solve the slider and press Submit' $a
  Check ($a.Contains(([datetime]$d6.exportedAt).ToString('h:mm tt'))) 'HS3 ...naming the request file''s time (the same file is used again)' $a
  $portalSrc = [IO.File]::ReadAllText((Join-Path $tk 'HikPortal.ps1'))
  Check ($portalSrc -match 'SetForegroundWindow') 'HS3 on Windows the browser window itself is also raised (SetForegroundWindow), beyond the page''s bringToFront'

  # =====================================================================================
  Write-Host 'HS4. "device refused" after correct steps: reboot the camera, then Retry (at most 2), then Hik support'
  $REBOOT = 'Steps were correct. Reboot the camera: unplug it or its PoE port for 10 seconds. Wait until SADP shows it Active, then press Retry.'
  $script:HkLocalNets = @((Net 'Ethernet' '10.243.1.50' 24 $true 1)); $script:HkSaidOnce = @{}
  $sp7 = Join-Path $tmp 'hs4/state.json'; $st7 = Read-HikState $sp7; $rq7 = Join-Path $tmp 'hs4/requests'
  $script:boot = '2026-11-08 21:08:00'
  function Live7 { return [pscustomobject]@{ serial = $SN; shortSerial = $SH; mac = $MAC; model = 'ECI-T44F2'; ip = '10.243.1.7'; mask = '255.255.255.0'; gw = ''; kind = 'camera'; activated = $true; bootTime = $script:boot; salt = ''; encrypt = $false } }
  function Find-HikSadp($s) { return @(Live7) }
  function Import-HikUnlock($l, $u, $pw) { $script:importN++; return [pscustomobject]@{ ok = $false; result = 'failed'; form = ''; tries = 2; error = 'the device answered "failed"' } }
  function Replied7 {
    $d = Get-HikStateDevice $st7 $SN; $rf = Join-Path $tmp 'hs4/reply.xml'; [IO.File]::WriteAllText($rf, $unlockXml)
    Set-HikStateField $d 'status' 'replied'; Set-HikStateField $d 'replyFile' $rf; Set-HikStateField $d 'replyAt' ([datetime]$d.exportedAt).AddMinutes(2).ToString('s'); Set-HikStateField $d 'replyForExport' ([string]$d.exportId); Save-HikState $sp7 $st7
  }
  $script:exportN = 0; $null = Export-HikRequests @(Live7) $rq7 $st7 $sp7; Replied7
  $script:said.Clear(); $script:importN = 0
  $null = @(Import-HikReplies $st7 $sp7 'Site-Pass-1234' { param($ip, $p) $false })
  $d7 = Get-HikStateDevice $st7 $SN
  Check ($d7.status -eq 'refused' -and @($script:said | Where-Object { $_.Contains($REBOOT) }).Count -eq 1) 'HS4 refused although every check passed: "Steps were correct. Reboot the camera: unplug it or its PoE port for 10 seconds. Wait until SADP shows it Active, then press Retry."' (All)
  Check (@(Said '(?i)Retry.{0,60}(Fix this site again|-Mode Retry)').Count -and @(Said '(?i)ONE new request').Count) 'HS4 ...it says where Retry is and that Retry is one fresh cycle (ONE new request, submit, its reply only)' (All)
  # Retry before the reboot: no export
  $script:said.Clear(); $script:exportN = 0
  $null = Export-HikRequests @(Live7) $rq7 $st7 $sp7
  Check ($script:exportN -eq 0 -and @(Said '(?i)has not restarted').Count -and @(Said '(?i)unplug it or its PoE port for 10 seconds').Count) 'HS4 Retry before the camera rebooted: no export (it would void nothing and fail the same way); it says to reboot first' (All)
  # after the reboot: one fresh export, reboot-retry 1 of 2
  $script:boot = '2026-11-08 21:40:00'; $script:said.Clear(); $script:exportN = 0
  $null = Export-HikRequests @(Live7) $rq7 $st7 $sp7
  $d7 = Get-HikStateDevice $st7 $SN
  Check ($script:exportN -eq 1 -and $d7.status -eq 'exported' -and [int]$d7.rebootRetries -eq 1 -and @(Said 'Reboot-retry 1 of 2').Count) 'HS4 after the reboot, Retry makes ONE fresh export (reboot-retry 1 of 2)' (All)
  # refused again -> reboot again (1 left) -> reboot-retry 2 -> refused again -> Hik support
  Replied7; $script:said.Clear()
  $null = @(Import-HikReplies $st7 $sp7 'Site-Pass-1234' { param($ip, $p) $false })
  Check (@($script:said | Where-Object { $_.Contains($REBOOT) }).Count -eq 1 -and @(Said 'left: 1 of 2').Count) 'HS4 refused again after reboot-retry 1: the reboot message again, 1 retry left' (All)
  $script:boot = '2026-11-08 21:55:00'; $script:exportN = 0; $script:said.Clear()
  $null = Export-HikRequests @(Live7) $rq7 $st7 $sp7
  Check ($script:exportN -eq 1 -and [int](Get-HikStateDevice $st7 $SN).rebootRetries -eq 2) 'HS4 reboot-retry 2 of 2 makes one more fresh export'
  Replied7; $script:said.Clear()
  $null = @(Import-HikReplies $st7 $sp7 'Site-Pass-1234' { param($ip, $p) $false })
  Check (-not @($script:said | Where-Object { $_.Contains($REBOOT) }).Count -and @(Said 'Call Hik support with the serial and the SADP log').Count -and @(Said ([regex]::Escape($SN))).Count) 'HS4 refused after 2 reboot-retries: no third reboot; "Call Hik support with the serial and the SADP log." with the serial' (All)
  $script:boot = '2026-11-08 22:10:00'; $script:exportN = 0; $script:said.Clear()
  $null = Export-HikRequests @(Live7) $rq7 $st7 $sp7
  Check ($script:exportN -eq 0 -and @(Said 'Call Hik support').Count) 'HS4 ...and no further export, even after another reboot (at most 2 reboot-retries)' (All)
  $hs = Invoke-HikResetStage -Targets @([pscustomobject]@{ mac = $MAC }) -SitePassword 'x' -StateDir (Join-Path $tmp 'hs4') -Config (Get-HikConfig $null) -VerifyLogin { param($ip, $p) $false } -WaitMinutes 0 -InboxEverySec 1
  Check (@($hs.pending | Where-Object { [string]$_.reason -match '(?i)Hik support' }).Count -eq 1) 'HS4 Fix this site''s end-of-run list says "call Hik support" for it' ((@($hs.pending) | ForEach-Object { $_.reason }) -join ' | ')
  # checks NOT passed: say what was wrong instead of the reboot message
  $sp8 = Join-Path $tmp 'hs4b/state.json'; $st8 = Read-HikState $sp8; $script:boot = '2026-11-08 21:08:00'
  $null = Export-HikRequests @(Live7) (Join-Path $tmp 'hs4b/req') $st8 $sp8
  $d8 = Get-HikStateDevice $st8 $SN; $rf8 = Join-Path $tmp 'hs4b/reply.xml'; [IO.File]::WriteAllText($rf8, $unlockXml)
  Set-HikStateField $d8 'status' 'replied'; Set-HikStateField $d8 'replyFile' $rf8; Set-HikStateField $d8 'replyAt' ([datetime]$d8.exportedAt).AddMinutes(2).ToString('s'); Set-HikStateField $d8 'replyForExport' 'aaaaaaaaaaaa'; Save-HikState $sp8 $st8
  $script:said.Clear()
  $null = @(Import-HikReplies $st8 $sp8 'Site-Pass-1234' { param($ip, $p) $false })
  Check (-not @($script:said | Where-Object { $_.Contains($REBOOT) }).Count -and @(Said '(?i)checks found what was wrong').Count -and @(Said '(?i)older export').Count -and @(Said '(?i)power.?cycle').Count) 'HS4 when a check did NOT pass (the reply answers an older export): it says what was wrong, not "Steps were correct"' (All)
  # the entry point: HikReset.ps1 -Mode Retry
  $exe = $(if ($PSVersionTable.PSEdition -eq 'Core') { (Get-Process -Id $PID).Path } else { Join-Path $PSHOME 'powershell.exe' })
  $sd9 = Join-Path $tmp 'hs4c'; New-Item -ItemType Directory -Force -Path $sd9 | Out-Null
  $cfg9 = Join-Path $sd9 'config.json'; '{ "form": { "firstName": "Moshe", "lastName": "Reichman", "email": "moshe@wireitct.com", "company": "WireIt CT LLC" } }' | Set-Content $cfg9
  $d9 = (Get-HikStateDevice $st7 $SN); ($st7 | ConvertTo-Json -Depth 6) | Set-Content (Join-Path $sd9 'state.json') -Encoding UTF8
  $o9 = & $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tk 'HikReset.ps1') -Mode Retry -StateDir $sd9 -ConfigPath $cfg9 2>&1 | Out-String
  Check ($LASTEXITCODE -eq 0 -and $o9 -match 'Call Hik support with the serial and the SADP log' -and $o9 -match 'hikreset\.log' -and $o9 -notmatch '(?i)request file saved') 'HikReset.ps1 -Mode Retry after 2 reboot-retries: exit 0, no export, "Call Hik support" naming the SADP log file' $o9
  # =====================================================================================
  Write-Host 'version'
  $v = @(([regex]::Match([IO.File]::ReadAllText((Join-Path $tk 'ToolkitCore.ps1')), "TkBuiltVersion = '([0-9.]+)'")).Groups[1].Value, ([regex]::Match([IO.File]::ReadAllText((Join-Path $tk 'FixSiteCore.ps1')), "FsVersion = '([0-9.]+)'")).Groups[1].Value, ([regex]::Match([IO.File]::ReadAllText((Join-Path $tk 'FixSiteBw.ps1')), "FsVersion = '([0-9.]+)'")).Groups[1].Value, [string](Get-Content (Join-Path $repo 'version.json') -Raw | ConvertFrom-Json).version)
  Check ((($v | Select-Object -Unique) -join ',') -eq '2.2.16') ('version 2.2.16 (2.2.16: bumped from 2.2.15) in ToolkitCore, FixSiteCore, FixSiteBw and version.json (' + ($v -join ',') + ')')
} catch {
  $script:fail++; Write-Host ('FAIL the suite stopped: ' + $_.Exception.Message + ' at ' + $_.InvocationInfo.PositionMessage)
} finally {
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
Write-Host ''
Write-Host ('Fix229: ' + $script:pass + ' passed, ' + $script:fail + ' failed')
exit $(if ($script:fail) { 1 } else { 0 })
