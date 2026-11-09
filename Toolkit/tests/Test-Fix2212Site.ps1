<# Test-Fix2212Site.ps1 - WireIt Toolkit 2.2.12, Fix this site: Codex's 2.2.11 review findings #1, #2, #4, #12 (F19), #13 (F20), #14.
   Codex's reproductions as permanent tests: the real FixSite.ps1 against mock devices (fix2212site/scenarios.py, loopback only) and
   the real functions of FixSiteCore.ps1 / FixSiteDevices.ps1 in their own process. Every check here failed on 2.2.11 head 91d5353
   (the controls marked "control" pass on both: they prove a fix is not too wide).
   Moshe's rule: failing half-way (one bad network read; a write the camera accepts but does not apply), the wrong device (a camera
   only ONE NVR records still moves; two different MACs are never merged) and running twice (every scenario runs twice).
   Windows PowerShell 5.1 or pwsh 7. #>
$ErrorActionPreference = 'Stop'
$tk = Split-Path -Parent $PSScriptRoot; $repo = Split-Path -Parent $tk
$exe = $(if ($PSVersionTable.PSEdition -eq 'Core') { (Get-Process -Id $PID).Path } else { Join-Path $PSHOME 'powershell.exe' })
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fix2212site-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$script:pass = 0; $script:fail = 0
function Check([bool]$ok, [string]$name, [string]$more = '') {
  if ($ok) { $script:pass++; Write-Host ('PASS ' + $name) } else { $script:fail++; Write-Host ('FAIL ' + $name); if ($more) { Write-Host ('     ' + ($more -replace "`n", "`n     ")) } }
}
function Q([string]$s) { return "'" + $s.Replace("'", "''") + "'" }
function Invoke-Driver([string]$name, [string]$code) {
  $f = Join-Path $tmp ($name + '.ps1'); [IO.File]::WriteAllText($f, $code, (New-Object Text.UTF8Encoding($true)))
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $o = & $exe -NoProfile -ExecutionPolicy Bypass -File $f 2>&1 | Out-String } finally { $ErrorActionPreference = $prev }
  return $o
}
function Get-Json([string]$out) { $m = [regex]::Match($out, '(?m)^JSON=(\{.*\})\s*$'); if ($m.Success) { try { return ($m.Groups[1].Value | ConvertFrom-Json) } catch {} }; return $null }
$load = ". " + (Q (Join-Path $tk 'FixSiteCore.ps1')) + "; . " + (Q (Join-Path $tk 'FixSiteDevices.ps1')) + "`n"
try {
  . (Join-Path $PSScriptRoot 'TestPython.ps1'); $py = Get-TestPython

  # =====================================================================================
  # #2 Get-FsNet: an error answer or a half answer is never a network state (canned device answers, the real function)
  $d = Invoke-Driver 'getnet' ($load + @'
$ErrorActionPreference = 'Continue'
$script:canned = @{}
function Fs-Http { param([string]$Ip, [string]$Path, [string]$Method = 'GET', [string]$Body = '', [string]$ContentType = '', $Cred = $null, [int]$Timeout = 8, [string]$OutFile = '', [switch]$Secret, [switch]$Tls)
  $k = ($Path -replace '\?.*name=', '?'); if ($script:canned.ContainsKey($k)) { return $script:canned[$k] }; return [pscustomobject]@{ code = 404; body = '' } }
function New-Resp($code, $body) { return [pscustomobject]@{ code = $code; body = $body } }
$dhOk = "table.Network.DefaultInterface=eth0`r`ntable.Network.eth0.IPAddress=192.168.0.40`r`ntable.Network.eth0.SubnetMask=255.255.255.0`r`ntable.Network.eth0.DefaultGateway=192.168.0.1`r`ntable.Network.eth0.DhcpEnable=false`r`ntable.Network.eth0.DnsServers[0]=8.8.8.8`r`n"
$hikOk = '<IPAddress xmlns="http://www.hikvision.com/ver20/XMLSchema"><ipVersion>v4</ipVersion><addressingType>static</addressingType><ipAddress>192.168.1.21</ipAddress><subnetMask>255.255.255.0</subnetMask><DefaultGateway><ipAddress>192.168.1.1</ipAddress></DefaultGateway><PrimaryDNS><ipAddress>8.8.8.8</ipAddress></PrimaryDNS></IPAddress>'
$hikNoGw = '<IPAddress xmlns="http://www.hikvision.com/ver20/XMLSchema"><ipVersion>v4</ipVersion><addressingType>dynamic</addressingType><ipAddress>192.168.1.22</ipAddress><subnetMask>255.255.255.0</subnetMask></IPAddress>'
$hikErr = '<?xml version="1.0" encoding="UTF-8"?><ResponseStatus version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema"><requestURL>/ISAPI/System/Network/interfaces/1/ipAddress</requestURL><statusCode>4</statusCode><statusString>Invalid Operation</statusString><subStatusCode>notSupport</subStatusCode></ResponseStatus>'
$o = @{}
$DN = '/cgi-bin/configManager.cgi?Network'; $HL = '/ISAPI/System/Network/interfaces'; $HI = '/ISAPI/System/Network/interfaces/1/ipAddress'
$script:canned = @{ $DN = (New-Resp 200 $dhOk) }; $o.dhOk = [string](Get-FsNet '192.168.0.40' 'Dahua' $null).ip
$script:canned = @{ $DN = (New-Resp 500 "Error`r`nInternal error`r`n") }; $o.dh500 = ($null -eq (Get-FsNet '192.168.0.40' 'Dahua' $null)); $o.dh500why = $script:FsNetWhy
$script:canned = @{ $DN = (New-Resp 200 "Error`r`nBad Request!`r`n") }; $o.dhErr200 = ($null -eq (Get-FsNet '192.168.0.40' 'Dahua' $null))
$script:canned = @{ $DN = (New-Resp 200 ($dhOk -replace 'table.Network.eth0.DhcpEnable=false\r\n', '')) }; $o.dhNoDhcp = ($null -eq (Get-FsNet '192.168.0.40' 'Dahua' $null))
$script:canned = @{ $DN = (New-Resp 200 ($dhOk -replace 'SubnetMask=255.255.255.0', 'SubnetMask=')) }; $o.dhNoMask = ($null -eq (Get-FsNet '192.168.0.40' 'Dahua' $null))
$script:canned = @{ $HI = (New-Resp 200 $hikOk) }; $n = Get-FsNet '192.168.1.21' 'Hikvision' $null; $o.hikOk = [string]$n.ip; $o.hikOkGw = [string]$n.gw; $o.hikOkDhcp = $n.dhcp
$script:canned = @{ $HI = (New-Resp 200 $hikNoGw) }; $n = Get-FsNet '192.168.1.22' 'Hikvision' $null; $o.hikNoGw = [string]$n.ip; $o.hikNoGwDhcp = $n.dhcp
$script:canned = @{ $HI = (New-Resp 200 $hikErr) }; $o.hikErr200 = ($null -eq (Get-FsNet '192.168.1.21' 'Hikvision' $null))
$script:canned = @{ $HI = (New-Resp 403 $hikErr) }; $o.hikErr403 = ($null -eq (Get-FsNet '192.168.1.21' 'Hikvision' $null))
$script:canned = @{ $HI = (New-Resp 500 '') }; $o.hik500 = ($null -eq (Get-FsNet '192.168.1.21' 'Hikvision' $null))
$script:canned = @{ $HI = (New-Resp 200 ($hikOk -replace '<addressingType>static</addressingType>', '')) }; $o.hikNoType = ($null -eq (Get-FsNet '192.168.1.21' 'Hikvision' $null))
'JSON=' + ($o | ConvertTo-Json -Compress)
'@)
  $j = Get-Json $d
  Check ($j -and $j.dhOk -eq '192.168.0.40' -and $j.hikOk -eq '192.168.1.21' -and $j.hikOkGw -eq '192.168.1.1' -and $j.hikOkDhcp -eq $false) 'control: a good Dahua and a good Hikvision network answer are read as before' $d
  Check ($j -and $j.hikNoGw -eq '192.168.1.22' -and $j.hikNoGwDhcp -eq $true) 'control: a camera with no gateway set (legit on a closed camera LAN) is still read' $d
  Check ($j -and $j.dh500 -and $j.dh500why -match '500') ('#2 Dahua: an HTTP 500 is not a network state (nothing to journal), and the reason names it (' + $(if ($j) { $j.dh500why } else { '' }) + ')') $d
  Check ($j -and $j.dhErr200 -and $j.dhNoDhcp -and $j.dhNoMask) '#2 Dahua: an "Error" page, or an answer without the DHCP flag or the mask, is rejected' $d
  Check ($j -and $j.hikErr200 -and $j.hikErr403 -and $j.hik500) '#2 Hikvision: an error <ResponseStatus> (with 200 or 403) or an HTTP 500 is not an interface document' $d
  Check ($j -and $j.hikNoType) '#2 Hikvision: an answer that does not say static or DHCP is rejected' $d

  # =====================================================================================
  # #1 #2 #4: the real Fix this site, each scenario run twice
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  $scen = & $py (Join-Path $PSScriptRoot 'fix2212site/scenarios.py') --repo $repo --powershell $exe 2>&1 | Out-String
  $ErrorActionPreference = $prev
  $r = $null; try { $r = (($scen.Trim() -split "`n")[-1]) | ConvertFrom-Json } catch {}
  if (-not $r) { Check $false 'Fix this site scenarios ran' $scen }
  else {
    foreach ($k in @('multinvr', 'multilist')) {
      foreach ($n in 1, 2) {
        $x = $r.($k + $n); $tw = $(if ($n -eq 2) { ' (run twice: the 2nd run too)' } else { '' })
        $what = $(if ($k -eq 'multinvr') { 'two NVRs (.20 and .19) record it' } else { 'the site list names NVR .20 (offline today) and the scan finds .19 recording it' })
        Check ($x.cams -contains '192.168.0.150' -and $x.chans.'192.168.1.19'.'1' -eq '192.168.0.150' -and $x.online19) ('#1 ' + $what + ': the camera is NOT moved and NVR .19 still records it' + $tw) $x.out
        Check ($x.chans.'192.168.1.20'.'1' -eq '192.168.0.150') ($(if ($k -eq 'multilist') { 'control: ' } else { '#1 ' }) + '...and NVR .20 still points at it too (nothing half-moved)' + $tw) $x.out
        Check ($x.exit -ne 0 -and $x.problems -ge 1 -and $x.said_multi) ('#1 ...the tech is told plainly (N NVRs record this camera) and it counts as Still a problem (exit ' + $x.exit + ', Still a problem: ' + $x.problems + ')' + $tw) $x.out
      }
    }
    $x = $r.singlenvr1
    Check ($x.cams -contains '192.168.1.21' -and $x.chans.'192.168.1.19'.'1' -eq '192.168.1.21' -and $x.exit -eq 0 -and -not $x.said_multi) ('control (wrong device): a camera only ONE NVR records still moves and its NVR follows (exit ' + $x.exit + ')') $x.out
    $x = $r.singlenvr2
    Check ($x.cams -contains '192.168.1.21' -and $x.exit -eq 0) ('control: ...and running it twice changes nothing more (exit ' + $x.exit + ')') $x.out

    $x = $r.netfail1
    Check ($x.failed500 -eq 1 -and $x.cams -contains '192.168.0.40' -and $x.pw -eq 'Oldpass123') '#2 one HTTP 500 on the network read after the backup: the camera is not moved and not even its password is changed' $x.out
    $empty = @(@($x.nets) | Where-Object { $_ -and -not [string]$_.ip }).Count
    Check ($empty -eq 0) ('#2 ...and the undo file never holds an empty network state (' + $empty + ' empty)') ($x.nets | ConvertTo-Json -Compress)
    Check ($x.exit -ne 0 -and $x.problems -ge 1 -and $x.said_netread) ('#2 ...the tech is told its network settings could not be read (run again), Still a problem (exit ' + $x.exit + ')') $x.out
    $x = $r.netfail2; $nb = @(@($x.nets) | Where-Object { $_ })
    Check ($x.cams -contains '192.168.1.40' -and $x.exit -eq 0 -and $nb.Count -ge 1 -and $nb[-1].ip -eq '192.168.0.40' -and $nb[-1].mask -eq '255.255.255.0' -and $nb[-1].gw -eq '192.168.0.1' -and $nb[-1].dhcp -eq $false) ('#2 running it again (the camera answers now) moves it, with its complete old network in the undo file (exit ' + $x.exit + ')') $x.out

    foreach ($n in 1, 2) {
      $x = $r.('settings' + $n); $tw = $(if ($n -eq 2) { ' (run twice: the 2nd run too)' } else { '' })
      Check ($x.fps -eq 12 -and $x.said_unconfirmed -and -not $x.said_20fps_green) ('#4 the camera accepts "20 fps" but stays at 12: no green check, it says NOT confirmed' + $tw) $x.out
      Check ($x.exit -ne 0 -and $x.problems -ge 1) ('#4 ...and it counts as Still a problem, exit not 0 (exit ' + $x.exit + ', Still a problem: ' + $x.problems + ')' + $tw) $x.out
    }
    $x = $r.settingsok1
    Check ($x.fps -eq 20 -and $x.exit -eq 0 -and $x.said_20fps_green -and -not $x.said_unconfirmed) ('control: a camera that really takes 20 fps gets its green check (read back), exit ' + $x.exit) $x.out
    $x = $r.settingsok2
    Check ($x.fps -eq 20 -and $x.exit -eq 0) ('control: ...and running it twice is fine (exit ' + $x.exit + ')') $x.out
  }

  # =====================================================================================
  # #4 the read-back comparison itself (every field, and an unreadable camera)
  $d = Invoke-Driver 'mismatch' ($load + @'
$ErrorActionPreference = 'Continue'
$diff = @([pscustomobject]@{ field = 'codec'; from = 'H.265'; to = 'H.264' }, [pscustomobject]@{ field = 'fps'; from = 12; to = 20 }, [pscustomobject]@{ field = 'resolution'; from = '1920x1080'; to = '2688x1520' },
          [pscustomobject]@{ field = 'bitrate'; from = 2048; to = 4096 }, [pscustomobject]@{ field = 'gop'; from = 12; to = 20 }, [pscustomobject]@{ field = 'smartCodec'; from = 'on'; to = 'off' })
$good = [pscustomobject]@{ codec = 'H.264'; fps = 20; width = 2688; height = 1520; bitrate = 4096; gop = 20; smartCodec = 'off' }
$bad = [pscustomobject]@{ codec = 'H.265'; fps = 12; width = 1920; height = 1080; bitrate = 2048; gop = 12; smartCodec = 'on' }
'JSON=' + (@{ good = @(Get-FsStreamMismatch $good $diff).Count; bad = @(Get-FsStreamMismatch $bad $diff).Count; none = @(Get-FsStreamMismatch $null $diff).Count; text = (@(Get-FsStreamMismatch $bad @($diff[1])) -join '|') } | ConvertTo-Json -Compress)
'@)
  $j = Get-Json $d
  Check ($j -and $j.good -eq 0 -and $j.bad -eq 6 -and $j.none -eq 6) ('#4 read-back: all six requested fields are compared; a camera that cannot be read back confirms nothing (' + $(if ($j) { '' + $j.good + '/' + $j.bad + '/' + $j.none } else { '?' }) + ')') $d
  Check ($j -and $j.text -match 'asked 20 fps, camera still has 12') ('#4 ...in plain words (' + $(if ($j) { $j.text } else { '' }) + ')') $d

  # =====================================================================================
  # #12 (F19): adding cameras to a saved list without MACs, more cases than Test-Fix227's F19 (wrong camera, running twice)
  $d = Invoke-Driver 'merge' ($load + @'
$ErrorActionPreference = 'Continue'
$old = @([pscustomobject]@{ name = 'Gate'; brand = 'Dahua'; serial = '7J0ABC123456789'; mac = ''; ip = '192.168.1.40'; nvr = '192.168.1.20'; channel = 5 })
$new = @([pscustomobject]@{ name = 'Camera 192.168.1.40'; brand = 'Dahua'; serial = '7J0ABC123456789'; mac = ''; ip = '192.168.1.41'; nvr = '192.168.1.20'; channel = 5 },
         [pscustomobject]@{ name = 'Yard'; brand = 'Hikvision'; serial = 'DS-2CDX1'; mac = 'c4:2f:90:00:00:41'; ip = '192.168.1.42'; nvr = '192.168.1.20'; channel = 6 })
$m1 = @(Merge-FsSiteListCams $old $new); $m2 = @(Merge-FsSiteListCams $m1 $new)
$g = @($m1 | Where-Object { [string]$_.serial -eq '7J0ABC123456789' })
$mac2 = @(Merge-FsSiteListCams @([pscustomobject]@{ name = 'A'; serial = 'SAME1'; mac = 'aa:bb:cc:00:00:01'; ip = '192.168.1.50'; nvr = '192.168.1.20'; channel = 7 }) @([pscustomobject]@{ name = 'B'; serial = 'SAME1'; mac = 'aa:bb:cc:00:00:02'; ip = '192.168.1.50'; nvr = '192.168.1.20'; channel = 7 }))
$otherNvr = @(Merge-FsSiteListCams @([pscustomobject]@{ name = 'A'; serial = ''; mac = ''; ip = '192.168.1.60'; nvr = '192.168.1.20'; channel = 3 }) @([pscustomobject]@{ name = 'B'; serial = ''; mac = ''; ip = '192.168.1.60'; nvr = '192.168.1.19'; channel = 3 }))
$macLate = @(Merge-FsSiteListCams @([pscustomobject]@{ name = 'Door'; serial = 'SN9'; mac = ''; ip = '192.168.1.70'; nvr = '192.168.1.20'; channel = 9 }) @([pscustomobject]@{ name = 'Camera 192.168.1.70'; serial = 'SN9'; mac = 'aa:bb:cc:00:00:09'; ip = '192.168.1.70'; nvr = '192.168.1.20'; channel = 9 }))
'JSON=' + (@{ n1 = $m1.Count; n2 = $m2.Count; gname = [string]$g[0].name; gip = [string]$g[0].ip; mac2 = $mac2.Count; otherNvr = $otherNvr.Count; macLate = $macLate.Count; macLateName = [string]$macLate[0].name; macLateMac = [string]$macLate[0].mac } | ConvertTo-Json -Compress)
'@)
  $j = Get-Json $d
  Check ($j -and $j.n1 -eq 2 -and $j.gname -eq 'Gate' -and $j.gip -eq '192.168.1.41') ('#12 a saved camera with no MAC found again (same serial, NVR, channel) is one row, keeps its name and gets its new address (' + $(if ($j) { $j.n1 } else { '?' }) + ' rows)') $d
  Check ($j -and $j.n2 -eq 2) ('#12 ...running the merge twice adds nothing (' + $(if ($j) { $j.n2 } else { '?' }) + ' rows)') $d
  Check ($j -and $j.mac2 -eq 2 -and $j.otherNvr -eq 2) 'control (wrong camera): two different MACs are never merged, and the same channel number on another NVR is another camera' $d
  Check ($j -and $j.macLate -eq 1 -and $j.macLateName -eq 'Door' -and $j.macLateMac -eq 'aa:bb:cc:00:00:09') '#12 ...a saved row without MAC found again WITH its MAC is one row, keeps its name and learns the MAC' $d

  # =====================================================================================
  # #13 (F20): the site-name rule and the command line of the blue window
  $d = Invoke-Driver 'sitename' (". " + (Q (Join-Path $tk 'FixSiteCore.ps1')) + "`n" + @'
$ErrorActionPreference = 'Continue'
$names = @('WI-061', '3 Hewlett St (Lieber)', '177 Main St, New Britain (Strand) #2 & Co.', 'New site 10.0.5.x 2026-11-04', 'Shimmy Vago', '32 Hillside Ave, Waterbury')
$badn = @('Site" -Mode Rollback -RollbackDir "C:\x', ('x' * 81), 'a$(calc)', 'a`b', 'x; y', 'a|b', '-Mode', ' lead', 'C:\temp\x', "O'Brien", 'a<b>')
'JSON=' + (@{ defined = [bool]$script:FsSiteRe; good = @($names | Where-Object { Test-FsSiteName $_ }).Count; goodN = $names.Count; bad = @($badn | Where-Object { Test-FsSiteName $_ }); arg = (ConvertTo-FsCmdArg '3 Hewlett St (Lieber)'); argBad = ($null -eq (ConvertTo-FsCmdArg 'Site" -Mode Rollback')) } | ConvertTo-Json -Compress)
'@)
  $j = Get-Json $d
  Check ($j -and $j.defined -and $j.good -eq $j.goodN) ('#13 the site-name rule exists and every real site name passes (' + $(if ($j) { '' + $j.good + '/' + $j.goodN } else { '?' }) + ')') $d
  Check ($j -and -not @($j.bad).Count) ('#13 quotes, $( ), backtick, ; | < > \, a leading - or space, and over 80 characters are refused (' + $(if ($j) { @($j.bad) -join ' / ' } else { '?' }) + ')') $d
  Check ($j -and $j.arg -eq '"3 Hewlett St (Lieber)"' -and $j.argBad) '#13 the command-line argument is one quoted piece; a name outside the rule gives no argument at all' $d
  $win = [IO.File]::ReadAllText((Join-Path $tk 'FixSiteWindow.ps1'))
  $ixCore = $win.IndexOf("(Join-Path `$ToolkitDir 'FixSiteCore.ps1')"); $ixCheck = $win.IndexOf('Test-FsSiteName $s')
  Check ($ixCore -ge 0 -and $ixCheck -gt $ixCore -and $win -match "\`$a \+= ' -Site ' \+ \`$qs" -and $win -notmatch "-Site `"' \+ \`$s") '#13 the window loads FixSiteCore.ps1 before it checks the name, and builds -Site only from the checked, quoted argument'

  # =====================================================================================
  # #14: an unexpected stop never says "Nothing is half-done"
  $d = Invoke-Driver 'exitwords' (". " + (Q (Join-Path $tk 'FixSiteCore.ps1')) + "`n" + @'
$ErrorActionPreference = 'Continue'
'JSON=' + (@{ w9 = (Get-FsExitWords 9 'Fix'); w1 = (Get-FsExitWords 1 'Fix'); wm1 = (Get-FsExitWords -1 ''); wr = (Get-FsExitWords 1 'Rollback'); wp = (Get-FsExitWords 1 'Plan'); w0 = (Get-FsExitWords 0 'Fix'); w6 = (Get-FsExitWords 6 'Fix') } | ConvertTo-Json -Compress)
'@)
  $j = Get-Json $d
  $all = $(if ($j) { @($j.w9, $j.w1, $j.wm1, $j.wr, $j.wp) -join ' || ' } else { '' })
  Check ($j -and $all -notmatch 'half-done') '#14 no unexpected stop says "Nothing is half-done"' $all
  Check ($j -and (@($j.w9, $j.w1, $j.wm1, $j.wr) | Where-Object { $_ -match 'may already have been changed' -and $_ -match 'Undo the last fix' -and $_ -match 'call the office' }).Count -eq 4) '#14 a Fix / Undo that stopped unexpectedly says cameras or NVRs may already be changed, and what to do (Undo, run again, call)' $all
  Check ($j -and $j.w9 -match 'network was put back' -and $j.wm1 -notmatch 'network was put back') '#14 ..."this PC''s network was put back" only when the stop''s own clean-up did it (code 9), never guessed' $all
  Check ($j -and $j.wp -match 'changes nothing' -and $j.wp -notmatch 'may already') '#14 ...a stopped Just look says nothing was changed (it changes nothing)' $j.wp
  Check ($j -and $j.w0 -match '^Done' -and $j.w6 -match '^FAILED') 'control: the normal end words (Done / FAILED - Run again) are unchanged' $all
  $fs = [IO.File]::ReadAllText((Join-Path $tk 'FixSite.ps1'))
  $trap = [regex]::Match($fs, '(?m)^trap \{.*$').Value
  Check ($trap -match 'STOPPED HALF-WAY' -and $trap -match 'exit \$\(if' -and $trap -notmatch '; break \}') '#14 the stop trap tells the blue window it stopped half-way and exits with the code the window explains (9, or 6 when the network is not back)' $trap
} catch { $script:fail++; Write-Host ('FAIL unexpected error: ' + $_.Exception.Message + ' at ' + $_.InvocationInfo.ScriptLineNumber) }
finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host ('Test-Fix2212Site: ' + $script:pass + ' passed, ' + $script:fail + ' failed')
exit $script:fail
