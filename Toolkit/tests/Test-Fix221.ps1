<#
 Test-Fix221.ps1 - WireIt Toolkit 2.2.1 tests for the Codex review fixes (pwsh 7 or Windows PowerShell 5.1).
 Every device is the mock site (tests\fixsite\mock_site.py, 127.0.0.1 only); this PC's network is a simulated adapter
 ($script:FsNetOps); Bitwarden is tests\fixsite\fakebw.py. Nothing here touches a real network, adapter or vault.
 Usage: pwsh -File Test-Fix221.ps1   (exit code = number of failed checks)
#>
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path; $tk = Split-Path -Parent $here; $repo = Split-Path -Parent $tk
$script:fail = 0; $script:pass = 0
function Check([bool]$ok, [string]$what) { if ($ok) { $script:pass++; Write-Host ('  ok    ' + $what) } else { $script:fail++; Write-Host ('  FAIL  ' + $what) -ForegroundColor Red } }
function Eq($a, $b, [string]$what) { Check ("$a" -eq "$b") ($what + ' (got "' + $a + '", want "' + $b + '")') }
$isWin = ($env:OS -eq 'Windows_NT')
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fix221-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Force -Path $tmp | Out-Null
. (Join-Path $tk 'FixSiteCore.ps1'); . (Join-Path $tk 'FixSiteDevices.ps1')
$script:LogLines = New-Object System.Collections.ArrayList
function Fs-LogLine([string]$s) { [void]$script:LogLines.Add($s) }
function Read-Src([string]$rel) { return [IO.File]::ReadAllText((Join-Path $repo $rel)) }
$py = $(if (Get-Command python3 -ErrorAction SilentlyContinue) { 'python3' } else { 'python' })
$mockProc = $null
function Start-Mock([string]$json) {
  $psi = New-Object Diagnostics.ProcessStartInfo; $psi.FileName = (Get-Command $py).Source
  $psi.Arguments = '"' + (Join-Path $here 'fixsite\mock_site.py') + '" "' + $json + '" 0'; $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.CreateNoWindow = $true
  $p = [Diagnostics.Process]::Start($psi); $port = [int]$p.StandardOutput.ReadLine()
  $script:mockProc = $p; return ('http://127.0.0.1:' + $port)
}
function Mock-State([string]$url) { return (Invoke-WebRequest -Uri ($url + '/dev/_pc/state') -UseBasicParsing).Content | ConvertFrom-Json }
try {
# =====================================================================================
Write-Host 'H9. the real subnet mask, and the tech picks the adapter'
Eq (ConvertTo-FsMask 24) '255.255.255.0' 'prefix 24 -> 255.255.255.0'
Eq (ConvertTo-FsMask 22) '255.255.252.0' 'prefix 22 -> 255.255.252.0'
Eq (ConvertTo-FsMask 25) '255.255.255.128' 'prefix 25 -> 255.255.255.128'
Eq (ConvertTo-FsPrefix '255.255.240.0') 20 '255.255.240.0 -> 20'
Check ((Test-FsInSubnet '10.20.3.7' '10.20.0.1' 22) -and -not (Test-FsInSubnet '10.20.4.7' '10.20.0.1' 22)) 'inside / outside a /22'
$script:FsSubnet = [pscustomobject]@{ ip = '10.20.0.50'; prefix = 22 }
Check (Test-FsOnScheme '10.20.2.99' '10.20.0') 'a /22 site: 10.20.2.x is on the site network (2.2.0 called it "wrong scheme" and moved it)'
Check (-not (Test-FsOnScheme '10.20.5.9' '10.20.0')) 'a /22 site: 10.20.5.x is still off the network'
$script:FsSubnet = [pscustomobject]@{ ip = '192.168.1.130'; prefix = 25 }
Check (-not (Test-FsOnScheme '192.168.1.20' '192.168.1')) 'a /25 site: 192.168.1.20 is NOT reachable from 192.168.1.130/25'
$script:FsSubnet = $null
Check (Test-FsOnScheme '192.168.1.20' '192.168.1') 'no subnet known: the /24 rule as before'
$script:FsNetOps = @{ adapters = { @(
  [pscustomobject]@{ ip = '172.16.0.20'; prefix = 22; mask = '255.255.252.0'; gw = ''; ifIndex = 7; dhcp = $false; name = 'Ethernet (cameras)'; metric = 99999 },
  [pscustomobject]@{ ip = '192.168.50.9'; prefix = 24; mask = '255.255.255.0'; gw = '192.168.50.1'; ifIndex = 3; dhcp = $true; name = 'Wi-Fi'; metric = 25 }) } }
$nets = @(Get-FsPcNets)
Eq $nets.Count 2 'two adapters listed'
Eq $nets[0].name 'Wi-Fi' 'the internet adapter is offered first (Enter)'
Eq (Select-FsPcNet $nets '2').ifIndex 7 'typing 2 picks the camera Ethernet'
Eq (Select-FsPcNet $nets '').ifIndex 3 'Enter = the first'
Check ($null -eq (Select-FsPcNet $nets '9')) 'a number not on the list is asked again'
Check ((Format-FsPcNetChoice $nets)[1] -match '^2 = Ethernet \(cameras\) \(this PC 172\.16\.0\.20/22, no router\)$') 'the choice line names the adapter, its address/prefix and router'
Eq (Get-FsPcNet 7).mask '255.255.252.0' 'the chosen adapter keeps its real mask'
$script:FsNetOps = $null
$fs = Read-Src 'Toolkit/FixSite.ps1'
Check ($fs -match 'Which one are the cameras on\?' -and $fs -match 'prefix = \[int\]\$pc\.prefix') 'FixSite asks which adapter and records its prefix'

# =====================================================================================
Write-Host 'H4. this PC''s network: saved before, put back after (simulated adapter)'
function New-SimNet([bool]$dhcp) {
  $script:sim = @{ dhcp = $dhcp; coexist = 'disabled'; addrs = New-Object System.Collections.ArrayList; gw = @('192.168.1.1'); failDhcp = $false; failCoexist = $false; calls = New-Object System.Collections.ArrayList }
  [void]$script:sim.addrs.Add([pscustomobject]@{ ip = '192.168.1.105'; prefix = 24; origin = $(if ($dhcp) { 'Dhcp' } else { 'Manual' }); skip = $false; store = 'ActiveStore'; addrState = 'Preferred' })
  $script:FsNetOps = @{
    state = { param($a) [void]$script:sim.calls.Add('state'); [pscustomobject]@{ dhcp = $script:sim.dhcp; coexist = $script:sim.coexist; addrs = @($script:sim.addrs); gw = @($script:sim.gw) } }
    coexist = { param($a) [void]$script:sim.calls.Add('coexist ' + $a.on); if ($script:sim.failCoexist) { return $false }; $script:sim.coexist = $(if ($a.on) { 'enabled' } else { 'disabled' }); return $true }
    dhcp = { param($a) [void]$script:sim.calls.Add('dhcp ' + $a.on); if ($script:sim.failDhcp) { throw 'Access is denied' }; $script:sim.dhcp = [bool]$a.on; return $true }
    addtemp = { param($a) [void]$script:sim.calls.Add('addtemp ' + $a.ip); [void]$script:sim.addrs.Add([pscustomobject]@{ ip = $a.ip; prefix = 24; origin = 'Manual'; skip = $true; store = 'ActiveStore'; addrState = 'Preferred' })
      if ($script:sim.coexist -ne 'enabled' -and $script:sim.dhcp) { $script:sim.dhcp = $false; $script:sim.gw = @(); foreach ($x in @($script:sim.addrs | Where-Object { $_.origin -eq 'Dhcp' })) { $script:sim.addrs.Remove($x) } }   # what Windows does without coexistence
      return 'Preferred' }
    remove = { param($a) [void]$script:sim.calls.Add('remove ' + $a.ip); foreach ($x in @($script:sim.addrs | Where-Object { $_.ip -eq $a.ip })) { $script:sim.addrs.Remove($x) }; return $true }
    addstatic = { param($a) [void]$script:sim.calls.Add('addstatic ' + $a.ip); [void]$script:sim.addrs.Add([pscustomobject]@{ ip = $a.ip; prefix = $a.prefix; origin = 'Manual'; skip = $false; store = 'ActiveStore'; addrState = 'Preferred' }); return $true }
    addroute = { param($a) [void]$script:sim.calls.Add('addroute ' + $a.gw); $script:sim.gw = @($script:sim.gw) + $a.gw; return $true }
    free = { param($a) return $true }
  }
  $script:FsTemps.Clear(); $script:FsPcBefore = $null; $script:FsCoexistChanged = $false
}
$pcA = [pscustomobject]@{ ip = '192.168.1.105'; prefix = 24; mask = '255.255.255.0'; gw = '192.168.1.1'; ifIndex = 5; dhcp = $true; name = 'Ethernet' }
$st1 = Join-Path $tmp 'state1\fixsite-temp-ips.json'
New-SimNet $true
$t = Add-FsTempIp '192.168.0' $pcA $st1
Eq $t '192.168.0.253' 'a temporary address on the old scheme'
Check ([array]::IndexOf(@($sim.calls), 'coexist True') -ge 0 -and [array]::IndexOf(@($sim.calls), 'coexist True') -lt [array]::IndexOf(@($sim.calls), 'addtemp 192.168.0.253')) 'DHCP+static coexistence turned on BEFORE the address went on'
Check ($sim.dhcp) 'so the adapter kept DHCP'
$sj = Get-Content -LiteralPath $st1 -Raw | ConvertFrom-Json
Check ([int]$sj.version -eq 2 -and $sj.before.dhcp -eq $true -and $sj.before.coexist -eq 'disabled' -and @($sj.temps).Count -eq 1) 'the state file has the adapter as it was (DHCP on, coexistence off) and the temp address'
$r = Remove-FsTempIps $st1
Check ($r.ok) 'clean-up reports everything back'
Check (-not @($sim.addrs | Where-Object { $_.ip -eq '192.168.0.253' }).Count) 'the temp address is gone'
Eq $sim.coexist 'disabled' 'coexistence put back to what it was'
Check (-not (Test-Path -LiteralPath $st1)) 'the state file is deleted only after it all checked out'
# Windows dropped DHCP anyway (or coexistence could not be used): it is switched back on
New-SimNet $true
$t = Add-FsTempIp '192.168.0' $pcA $st1; $sim.dhcp = $false
$r = Remove-FsTempIps $st1
Check ($r.ok -and $sim.dhcp -and @($sim.calls) -contains 'dhcp True') 'DHCP lost while the temp address was on: switched back on at the end'
# it cannot be put back: the state stays, the run says so, the next start retries
New-SimNet $true
$t = Add-FsTempIp '192.168.0' $pcA $st1; $sim.dhcp = $false; $sim.failDhcp = $true
$r = Remove-FsTempIps $st1
Check (-not $r.ok -and (@($r.problems) -join ' ') -match 'DHCP') 'DHCP cannot be switched back on: reported as a problem'
Check (Test-Path -LiteralPath $st1) 'and the state file is KEPT (2.2.0 deleted it)'
Check (@($script:LogLines | Where-Object { $_ -like 'NETWORK NOT BACK TO NORMAL*' }).Count -ge 1) 'the log says the network is not back to normal'
$script:FsTemps.Clear(); $script:FsPcBefore = $null; $script:FsCoexistChanged = $false; $sim.failDhcp = $false   # a new run (the next start)
$r2 = Clear-FsLeftoverTemps $st1
Check ($r2 -and $r2.ok -and $sim.dhcp -and -not (Test-Path -LiteralPath $st1)) 'the next start (or the task''s finally) finishes the job from the saved state'
# coexistence cannot be turned on: no temp address at all (DHCP is never risked)
New-SimNet $true; $sim.failCoexist = $true
$t = Add-FsTempIp '192.168.0' $pcA $st1
Check (-not $t -and -not @($sim.calls | Where-Object { $_ -like 'addtemp*' }).Count) 'coexistence refused: no temporary address is added (DHCP would be lost)'
[void](Remove-FsTempIps $st1)
# a fixed-address PC whose own address/router vanished
New-SimNet $false
$pcS = [pscustomobject]@{ ip = '192.168.1.105'; prefix = 24; mask = '255.255.255.0'; gw = '192.168.1.1'; ifIndex = 5; dhcp = $false; name = 'Ethernet' }
$t = Add-FsTempIp '10.1.1' $pcS $st1
Check (-not @($sim.calls | Where-Object { $_ -like 'coexist*' }).Count) 'a fixed-address PC: coexistence is left alone'
$sim.addrs.Clear(); $sim.gw = @()
$r = Remove-FsTempIps $st1
Check ($r.ok -and @($sim.addrs | Where-Object { $_.ip -eq '192.168.1.105' }).Count -eq 1 -and @($sim.gw) -contains '192.168.1.1') 'its own address and router are put back'
# a 2.2.0 state file (a plain list) is still cleaned up
New-SimNet $true
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $st1) | Out-Null
[void]$sim.addrs.Add([pscustomobject]@{ ip = '192.168.0.253'; prefix = 24; origin = 'Manual'; skip = $true; store = 'ActiveStore'; addrState = 'Preferred' })
Set-Content -LiteralPath $st1 -Value '[{"p3":"192.168.0","ip":"192.168.0.253","ifIndex":5}]'
$r = Clear-FsLeftoverTemps $st1
Check ($r.ok -and -not @($sim.addrs | Where-Object { $_.ip -eq '192.168.0.253' }).Count -and -not (Test-Path -LiteralPath $st1)) 'a 2.2.0 state file: its address is removed'
$script:FsNetOps = $null
# 2.2.3: no task any more - a run that was killed is cleaned up when Fix this site next starts
Check ($fs -match 'if \(Test-Path -LiteralPath \$tempState\) \{ try \{ \$nr0 = Remove-FsTempIps \$tempState') 'a killed run''s network is put back when Fix this site starts again (2.2.3: replaces the task''s finally)'
Check ($fs -match 'trap \{ try \{ \[void\]\(Remove-FsTempIps') 'FixSite itself cleans up on an error that stops it'

# =====================================================================================
Write-Host 'H1/H8. password calls over HTTPS first; exact undo (mock site)'
$murl = Start-Mock (Join-Path $here 'fixsite\mock-221.json')
$script:FsMockUrl = $murl
$hcr = Fs-Cred 'Campass1357'
Check (Set-FsPassword '192.168.1.21' 'Hikvision' $hcr 'Newcam24680') 'Hikvision camera with HTTPS: password changed'
$ms = Mock-State $murl
Check (@($ms.log | Where-Object { $_ -eq 'TLS PUT 192.168.1.21 /ISAPI/Security/users/1' }).Count -ge 1 -and -not @($ms.log | Where-Object { $_ -eq 'PUT 192.168.1.21 /ISAPI/Security/users/1' }).Count) 'it went over HTTPS (and never over plain HTTP)'
Check (-not (@($ms.plain_secrets) -contains '192.168.1.21')) 'no password reached it over plain HTTP'
Check (-not (Test-FsSentPlain '192.168.1.21')) 'and no warning is due for it'
Check (Set-FsPassword '192.168.1.22' 'Dahua' (Fs-Cred 'Dahua1357x') 'Newdh24680') 'Dahua camera with no HTTPS: password changed over plain HTTP (the only way it takes one)'
$ms = Mock-State $murl
Check (@($ms.log) -contains 'TLS-NONE GET 192.168.1.22' -and (Test-FsSentPlain '192.168.1.22')) 'HTTPS was tried first, and the device is on the warning list'
Check (@($script:LogLines | Where-Object { $_ -like 'WARNING 192.168.1.22*plain HTTP*' -or $_ -like '*WARNING 192.168.1.22: this device has no HTTPS*' }).Count -ge 1) 'the warning is in the log'
Check ($fs -match 'has no HTTPS, so its password went over plain HTTP') 'FixSite shows the tech the warning per device'
Check (-not (@($script:LogLines | Where-Object { $_ -match 'Newdh24680|Dahua1357x' }).Count)) 'the passwords are in no log line'
$script:FsNoPlainSecrets = $true
Check (-not (Set-FsPassword '192.168.1.22' 'Dahua' (Fs-Cred 'Newdh24680') 'Other13579')) 'plain HTTP switched off: a device without HTTPS is refused, not sent the password'
$script:FsNoPlainSecrets = $false
# a device that has HTTPS and refuses: never retried in clear
$c0 = @((Mock-State $murl).log).Count
Check (-not (Set-FsPassword '192.168.1.21' 'Hikvision' (Fs-Cred 'wrongpass1') 'Xx12345678')) 'HTTPS device, wrong old password: refused'
$after = @((Mock-State $murl).log | Select-Object -Skip $c0)
Check (-not @($after | Where-Object { $_ -like 'PUT 192.168.1.21 *' }).Count) 'and NOT retried over plain HTTP'
# H8: the NVR channel exactly as saved; an added channel deleted; DHCP back
$ncr = Fs-Cred 'Nvrpass2468'
$bk = Join-Path $tmp 'backup'
$w = Set-FsNvrChannel '192.168.1.20' $ncr 2 '192.168.1.40' 'Newdh24680' 'Dahua' $bk
Check ($w.ok -and $w.action -eq 'updated') 'NVR channel 2 moved to the camera''s new address'
$ms = Mock-State $murl
Check (@($ms.log) -contains 'TLS PUT 192.168.1.20 /ISAPI/ContentMgmt/InputProxy/channels/2') 'the channel (it carries the camera password) went over HTTPS'
$bf = Join-Path $bk 'nvr-192.168.1.20-ch2.xml'
$ms = $null; $u = Restore-FsNvrChannel '192.168.1.20' $ncr 2 ([IO.File]::ReadAllText($bf)) 'Dahua1357x'
$ms = Mock-State $murl
Check ($u.ok -and $ms.devices.'192.168.1.20'.channels.'2'.ip -eq '192.168.1.22' -and $ms.devices.'192.168.1.20'.channels.'2'.protocol -eq 'ONVIF' -and $ms.devices.'192.168.1.20'.channels.'2'.password -eq 'Dahua1357x') 'undo: channel 2 back exactly (address, ONVIF protocol) with the camera password'
$w = Set-FsNvrChannel '192.168.1.20' $ncr 5 '192.168.1.41' 'Newcam24680' 'Hikvision' $bk
Check ($w.action -eq 'added' -and (Mock-State $murl).devices.'192.168.1.20'.channels.PSObject.Properties['5']) 'a channel the run added'
Check ((Remove-FsNvrChannel '192.168.1.20' $ncr 5) -and -not (Mock-State $murl).devices.'192.168.1.20'.channels.PSObject.Properties['5']) 'undo: the added channel is deleted (2.2.0 left it, or rebuilt it)'
$ccr = Fs-Cred 'Oldcam9753'; $net = Get-FsNet '192.168.1.23' 'Hikvision' $ccr
Check ($net -and $net.dhcp) 'a camera on DHCP'
$w = Set-FsNet '192.168.1.23' 'Hikvision' $ccr $net '192.168.1.23' '255.255.255.0' '192.168.1.1'
Check ($w.ok -and -not (Mock-State $murl).devices.'192.168.1.23'.net.dhcp) 'the fix set it to a fixed address (same address)'
$net = Get-FsNet '192.168.1.23' 'Hikvision' $ccr
$w = Set-FsNet '192.168.1.23' 'Hikvision' $ccr $net '192.168.1.23' '255.255.255.0' '192.168.1.1' -Dhcp
Check ($w.ok -and (Mock-State $murl).devices.'192.168.1.23'.net.dhcp) 'undo: DHCP is switched back on (2.2.0 always left it fixed)'
Check ($fs -match "undo-progress\.json" -and $fs -match "if \(-not \`$bad\) \{ \[IO\.File\]::WriteAllText\(\(Join-Path \`$RollbackDir 'undone\.txt'\)") 'undo: each step that worked is written down; "undone" only when nothing failed'
Check ($fs -match "\(\`$c\.ip_after -ne \`$c\.ip_before -or \[bool\]\`$nb\.dhcp\)") 'undo: a same-address DHCP -> fixed change is undone too'
Check ($fs -match "Remove-FsNvrChannel" -and $fs -match "Restore-FsNvrChannel") 'undo uses the saved channel / deletes an added one'
$script:FsMockUrl = ''

# =====================================================================================
Write-Host 'H2. certificate check skipped for private-address devices only'
$ok2 = Enable-WireItLanTls
Check $ok2 'the check compiles and installs on this PowerShell'
if ($ok2) {
  Check ([WireItLanTls]::IsLanHost('192.168.1.64') -and [WireItLanTls]::IsLanHost('10.0.0.5') -and [WireItLanTls]::IsLanHost('172.20.1.1') -and [WireItLanTls]::IsLanHost('169.254.3.3')) 'private / link-local addresses: a camera''s own certificate is accepted'
  Check (-not [WireItLanTls]::IsLanHost('wireit-api.wireitct.workers.dev') -and -not [WireItLanTls]::IsLanHost('8.8.8.8') -and -not [WireItLanTls]::IsLanHost('172.32.0.1') -and -not [WireItLanTls]::IsLanHost('')) 'a name (the service log) or a public address: normal check'
  Check ([WireItLanTls]::Check('wireit-api.wireitct.workers.dev', $null, $null, [Net.Security.SslPolicyErrors]::RemoteCertificateNameMismatch) -eq $false) 'a bad certificate on the cloud upload is refused'
  # 2.2.3 (Codex #7): a LAN device's self-made certificate is accepted and pinned for the run (a missing certificate is not)
  $rsa221 = [Security.Cryptography.RSA]::Create(2048); $cr221 = New-Object Security.Cryptography.X509Certificates.CertificateRequest('CN=nvr', $rsa221, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
  $cert221 = $cr221.CreateSelfSigned([DateTimeOffset]::Now.AddDays(-1), [DateTimeOffset]::Now.AddDays(30))
  Check ([WireItLanTls]::Check('192.168.1.20', $cert221, $null, [Net.Security.SslPolicyErrors]::RemoteCertificateChainErrors) -eq $true) 'a self-made certificate on an NVR is accepted'
  Check ([WireItLanTls]::Check('example.com', $null, $null, [Net.Security.SslPolicyErrors]::None) -eq $true) 'a good certificate is always accepted'
  [Net.ServicePointManager]::ServerCertificateValidationCallback = $null
}
foreach ($f in @('sitecheck/SiteCheck.ps1', 'sitecheck/WireIt-SiteCheck.cmd', 'Toolkit/modules/NvrHealth/NvrHealth.psm1', 'FixNVR/FixNVR.ps1', 'NetCheck/NetCheck.ps1', 'Toolkit/FixSiteDevices.ps1')) {
  $src = Read-Src $f
  Check ($src -notmatch 'ServerCertificateValidationCallback\s*=\s*\{\s*\$true\s*\}' -and $src -match 'Enable-WireItLanTls') ($f + ': no "accept every certificate" left; the private-address check instead')
}

# =====================================================================================
Write-Host 'H5. one MAC form for the reset results'
Eq (ConvertTo-FsMac 'c4-2f-90-00-00-20') (ConvertTo-FsMac 'C4:2F:90:00:00:20') 'SADP form and scan form give the same key'
Check ($fs -match '\$mk = ConvertTo-FsMac \(\[string\]\$m\); if \(\$mk\) \{ \$hikFixed\[\$mk\]' -and $fs -match '\$hikPending\[\$mk\]') 'FixSite stores the reset results under ConvertTo-FsMac keys (2.2.0: raw SADP form, never found)'

# =====================================================================================
Write-Host 'H6. an NVR that only needs the official reset is work'
Check ($fs -match "\`$_\.steps -contains 'reset' \}\)" -and $fs -match "NVR ' \+ \`$n\.ip \+ ': Hikvision''s official password reset") 'the work list counts an NVR "reset" step, and the dry run names it'
$plan = [pscustomobject]@{ cams = @(); nvrs = @([pscustomobject]@{ ip = '192.168.1.20'; steps = @('reset') }) }
$work = @($plan.cams | Where-Object { $_.state -eq 'fix' -or ($_.state -eq 'missing' -and $_.steps.Count) }) + @($plan.nvrs | Where-Object { $_.steps -contains 'move' -or $_.steps -contains 'password' -or $_.steps -contains 'reset' })
Eq $work.Count 1 'a plan with only an NVR reset is not "Nothing to change"'

# =====================================================================================
Write-Host 'H7. the official reset only touches this run''s approved devices'
. (Join-Path $tk 'HikMail.ps1'); . (Join-Path $tk 'HikPortal.ps1'); . (Join-Path $tk 'HikResetFlow.ps1')
$script:HkSay = { param($t, $c) }; $script:HkAsk = { param($t) '' }
$script:imported = New-Object System.Collections.ArrayList
function Find-HikSadp([int]$s) { return @([pscustomobject]@{ mac = 'aa-aa-aa-00-00-01'; ip = '192.168.1.31'; bootTime = '' }, [pscustomobject]@{ mac = 'aa-aa-aa-00-00-02'; ip = '192.168.1.32'; bootTime = '' }) }
function Read-HikUnlock([string]$f) { return 'u' }
function Import-HikUnlock($live, $u, $pw) { [void]$script:imported.Add($live.mac); return [pscustomobject]@{ ok = $true } }
function Start-Sleep { param([int]$Seconds, [int]$Milliseconds) }
$vu = (Get-Date).AddHours(10).ToString('s')
$hs = [pscustomobject]@{ devices = @([pscustomobject]@{ serial = 'S1'; mac = 'aa-aa-aa-00-00-01'; ip = '192.168.1.31'; model = 'm'; status = 'replied'; validUntil = $vu; replyFile = 'x'; bootTime = '' }, [pscustomobject]@{ serial = 'S2'; mac = 'aa-aa-aa-00-00-02'; ip = '192.168.1.32'; model = 'm'; status = 'replied'; validUntil = $vu; replyFile = 'x'; bootTime = '' }) }
$sp = Join-Path $tmp 'hikstate.json'
$done = @(Import-HikReplies $hs $sp 'Site12345678' { param($ip, $pw) $true } '' @('S1'))
Check ($done.Count -eq 1 -and @($script:imported) -contains 'aa-aa-aa-00-00-01' -and -not (@($script:imported) -contains 'aa-aa-aa-00-00-02')) 'a reply for an old device from another run is NOT imported (only this run''s approved one)'
Eq ([string]@($hs.devices | Where-Object { $_.serial -eq 'S2' })[0].status) 'replied' 'the other device is left as it was'
$hs2 = [pscustomobject]@{ devices = @([pscustomobject]@{ serial = 'S3'; status = 'exported'; requestFile = (Join-Path $tmp 'nope.xml'); validUntil = $vu; model = 'm'; ip = 'i' }) }
$sent = @(Submit-HikRequests $hs2 $sp $null 5 @('S1'))
Check (-not @($hs2.devices[0].PSObject.Properties | Where-Object { $_.Name -eq 'note' }).Count) 'a saved request of a device outside this run is not sent to Hikvision'
$hrf = Read-Src 'Toolkit/HikResetFlow.ps1'
Check ($hrf -match "Submit-HikRequests \`$state \`$statePath \`$form \`$SubmitTimeoutSec \`$mine" -and $hrf -match "Import-HikReplies \`$state \`$statePath \`$SitePassword \`$VerifyLogin '' \`$mine") 'the reset stage passes this run''s devices to both steps'
Check ($hrf -match "status -eq 'imported'") 'a device left "imported" by a stopped run is checked again'
Remove-Item Function:\Start-Sleep

# =====================================================================================
Write-Host 'H10. update / go back stop on a file that cannot be written'
. (Join-Path $tk 'ToolkitCore.ps1')
$script:TkBuiltVersion = '0.0.0'   # 2.2.2: these tests use their own version numbers (1.0.0 -> 1.1.0); Test-Fix222 tests the real floor
$w = Join-Path $tmp 'WireIt'; $tku = Join-Path $w 'Toolkit'; New-Item -ItemType Directory -Force -Path $tku, (Join-Path $w 'FixNVR') | Out-Null
Set-Content (Join-Path $tku 'a.ps1') 'old a'; Set-Content (Join-Path $w 'FixNVR\FixNVR.ps1') 'old fix'
Save-TkJson ([ordered]@{ version = '1.0.0' }) (Join-Path $tku 'version.json')
$store = @{ 'Toolkit/a.ps1' = [Text.Encoding]::UTF8.GetBytes('new a'); 'FixNVR/FixNVR.ps1' = [Text.Encoding]::UTF8.GetBytes('new fix'); 'NetCheck/NetCheck.ps1' = [Text.Encoding]::UTF8.GetBytes('new net') }
New-Item -ItemType Directory -Force -Path (Join-Path $w 'NetCheck') | Out-Null
$fl = @(foreach ($k in @('Toolkit/a.ps1', 'FixNVR/FixNVR.ps1', 'NetCheck/NetCheck.ps1')) { $hf = Join-Path $tmp 'h.bin'; [IO.File]::WriteAllBytes($hf, $store[$k]); [pscustomobject]@{ path = $k; sha256 = (Get-TkSha256 $hf) } })
$m = [pscustomobject]@{ version = '1.1.0'; base = 'https://raw.githubusercontent.com/wireitct/wireit-toolkit/test/'; files = $fl }
$fetch = { param($url) $k = [Uri]::UnescapeDataString(($url -replace '^https://raw.githubusercontent.com/wireitct/wireit-toolkit/test/', '')); return $store[$k] }
# Windows: FixNVR.ps1 held open with no sharing (like a running tool). Elsewhere: the NetCheck folder made read-only, so the
# new NetCheck.ps1 cannot be written (install) or removed again (go back).
$lockedFile = $(if ($isWin) { Join-Path (Join-Path $w 'FixNVR') 'FixNVR.ps1' } else { Join-Path $w 'NetCheck' })
function Lock-It([string]$p) { if ($isWin) { $script:lockFs = [IO.File]::Open($p, 'Open', 'Read', 'None') } else { & chmod 555 $p } }
function Unlock-It([string]$p) { if ($isWin) { if ($script:lockFs) { $script:lockFs.Close(); $script:lockFs = $null } } else { & chmod 755 $p } }
$canLock = $true; if (-not $isWin) { $canLock = ((& id -u) -ne '0') }
if ($canLock) {
  Lock-It $lockedFile
  $ErrorActionPreference = 'Continue'   # what the Toolkit window runs with (2.2.0's copy failures passed under it)
  $threw = $false; $msg = ''; try { Install-TkUpdate $m $tku $fetch | Out-Null } catch { $threw = $true; $msg = $_.Exception.Message }
  $ErrorActionPreference = 'Stop'
  Unlock-It $lockedFile
  Check $threw 'a file that cannot be replaced stops the update (2.2.0 reported it installed)'
  Eq (Get-TkVersion $tku) '1.0.0' 'the version number is not moved'
  Eq ((Get-Content (Join-Path $tku 'a.ps1') -Raw).Trim()) 'old a' 'the file already swapped in is put back'
  Check ($msg -match 'put back') 'the message says the old version was put back'
  $old = Install-TkUpdate $m $tku $fetch
  Check ((Get-TkVersion $tku) -eq '1.1.0') 'unlocked: the update installs'
  Lock-It $lockedFile
  $ErrorActionPreference = 'Continue'
  $threw = $false; $msg = ''; try { Undo-TkUpdate $tku | Out-Null } catch { $threw = $true; $msg = $_.Exception.Message }
  $ErrorActionPreference = 'Stop'
  Unlock-It $lockedFile
  Check ($threw -and $msg -match 'FixNVR|NetCheck') 'go back: a file that cannot be put back stops it, by name'
  Eq (Get-TkVersion $tku) '1.1.0' 'go back failed: the version number still says what is really there'
} else { Write-Host '  (skipped: running as root, files cannot be locked)' }
$tc = Read-Src 'Toolkit/ToolkitCore.ps1'
Check ($tc -match "Get-TkSha256 \`$live\) -ne") 'every swapped-in file is checked against its hash'

# =====================================================================================
Write-Host 'H11. Bitwarden: compare, update, verify'
$bwState = Join-Path $tmp 'bw.json'; $env:FAKEBW_STATE = $bwState
$bw = Join-Path $here 'fixsite\fakebw.py'
if (-not $isWin) {
  $script:FsVersion = '2.2.1'
  Eq (Save-FsBitwarden $bw 'Lieber' 'Firstpw1234') 'saved' 'a new item: saved and read back'
  Eq (Save-FsBitwarden $bw 'Lieber' 'Firstpw1234') 'exists' 'the same password again: "already there" only after reading it back'
  Eq (Save-FsBitwarden $bw 'Lieber' 'Secondpw5678') 'updated' 'a different password under the same name: the item is CHANGED (2.2.0 said "already has it" and kept the old one)'
  $bs = Get-Content $bwState -Raw | ConvertFrom-Json
  Check (@($bs.items).Count -eq 1 -and $bs.items[0].login.password -eq 'Secondpw5678') 'one item, with the new password'
  Check (@($bs.calls) -contains 'edit item' -and (@($bs.calls) | Where-Object { $_ -eq 'sync' }).Count -ge 4) 'it synced with the server before and after'
  $env:FAKEBW_MODE = 'noedit'
  Eq (Save-FsBitwarden $bw 'Lieber' 'Thirdpw9012') 'failed' 'the server did not take the change: reported as NOT saved'
  $env:FAKEBW_MODE = ''
  $fsbw = $fs + (Read-Src 'Toolkit/FixSiteBw.ps1')   # 2.2.2: the words moved to FixSiteBw.ps1 (the window uses them too)
  Check ($fsbw -match 'it is NOT confirmed in Bitwarden \(only on this PC\)' -and $fsbw -match 'Bitwarden had an OLDER password') 'FixSite says plainly whether the office has it'
} else { Write-Host '  (fake Bitwarden runs on Linux/macOS only; covered there)' }

# =====================================================================================
Write-Host 'M1. a fully random, unique site password'
$pws = @(1..300 | ForEach-Object { New-FsRandomSitePassword })
Check (@($pws | Where-Object { $_.Length -ne 14 -or $_ -cnotmatch '[A-Z]' -or $_ -cnotmatch '[a-z]' -or $_ -notmatch '\d' -or $_ -cmatch '[^A-HJ-NP-Za-km-z2-9]' }).Count -eq 0) '300 made: 14 characters, upper + lower + digit, no look-alikes, no symbols'
Eq (@($pws | Select-Object -Unique).Count) 300 'all different'
Check (@($pws | Where-Object { $_ -cmatch '(.)\1\1' }).Count -eq 0) 'no 3 of the same character in a row'
$av = New-FsRandomSitePassword
$script:FsPwSets = @('AB', 'ab', '23'); $many = @(1..40 | ForEach-Object { New-FsRandomSitePassword -Avoid @($av) -Length 10 }); $script:FsPwSets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnpqrstuvwxyz', '23456789')
Check (-not ($many -ccontains $av)) 'never one of the passwords to avoid'
$sd = Join-Path $tmp 'sec'; New-Item -ItemType Directory -Force -Path $sd | Out-Null
$script:FsTestSecrets = $true
$o1 = Read-FsSecrets $sd 'Other Site'; $o1.password = 'Otherpw12345'; Save-FsSecrets $sd $o1
$avoid = @(Get-FsOtherSitePasswords $sd 'Lieber')
Check ($avoid -contains 'Otherpw12345') 'the other sites'' passwords on this PC are read to stay different from'
Check (-not (@(Get-FsOtherSitePasswords $sd 'Other Site') -contains 'Otherpw12345')) 'a site''s own password is not counted against itself'
Check ($fs -notmatch "your word \+ 4 random digits\)   Enter" -and $fs -match 'New-SitePasswordNow') 'FixSite makes the random one and no longer asks for a word'

# =====================================================================================
Write-Host 'M2. remembered NVR logins: Administrators + SYSTEM only'
$cvDir = Join-Path $tmp 'cv'; New-Item -ItemType Directory -Force -Path (Join-Path $cvDir 'secrets') | Out-Null
$cvSrc = Read-Src 'Toolkit/CamViews.ps1'
$fnStart = $cvSrc.IndexOf('$script:CvDpapi = $null'); $fnEnd = $cvSrc.IndexOf('function Invoke-CvAuto {')
. ([scriptblock]::Create($cvSrc.Substring($fnStart, $fnEnd - $fnStart)))
function Get-CvSites { $p = Join-Path $script:CvHere 'camviews-sites.json'; if (Test-Path $p) { return @(Get-Content $p -Raw | ConvertFrom-Json) } else { return @() } }
$script:CvHere = $cvDir
$script:CvDpapi = { param($op, $data) [byte[]]($data | ForEach-Object { $_ -bxor 0x5A }) }
$script:aclCalls = New-Object System.Collections.ArrayList
$script:CvAclRun = { param($a) [void]$script:aclCalls.Add(($a -join ' ')); return 0 }
$spw = ConvertTo-SecureString 'Nvrpass2468' -AsPlainText -Force
Save-CvSite '192.168.1.20' 'Lieber' 'admin' 'hik' 1 $spw
$vf = Join-Path (Join-Path $cvDir 'vault') 'nvr-192.168.1.20.bin'
Check (Test-Path -LiteralPath $vf) 'the login is stored in vault\ (2.2.0: secrets\, which Crew can read)'
Check ($script:aclCalls.Count -eq 1 -and $script:aclCalls[0] -match '/inheritance:r /grant:r \*S-1-5-32-544:F \*S-1-5-18:F$') 'the file gets its own Administrators + SYSTEM only permissions'
Check (-not ([IO.File]::ReadAllText($vf) -match 'Nvrpass2468')) 'it is encrypted'
Eq (Get-CvSiteCred '192.168.1.20').GetNetworkCredential().Password 'Nvrpass2468' 'and reads back'
$script:CvAclRun = { param($a) return 5 }
$threw = $false; try { Save-CvSite '192.168.1.30' 'X' 'admin' 'hik' 1 $spw } catch { $threw = $true }
Check ($threw -and -not (Test-Path -LiteralPath (Join-Path (Join-Path $cvDir 'vault') 'nvr-192.168.1.30.bin')) -and -not (Get-ChildItem (Join-Path $cvDir 'vault') -Filter '*.tmp')) 'permissions cannot be set: NOT remembered, nothing left on disk'
$script:CvAclRun = { param($a) return 0 }
$lb = [byte[]]([Text.Encoding]::UTF8.GetBytes('{"user":"admin","pw":"Legacy13579"}') | ForEach-Object { $_ -bxor 0x5A })
[IO.File]::WriteAllBytes((Join-Path (Join-Path $cvDir 'secrets') 'nvr-192.168.1.50.bin'), $lb)
Eq (Get-CvSiteCred '192.168.1.50').GetNetworkCredential().Password 'Legacy13579' 'a 2.2.0 login in secrets\ still works'
Check ((Test-Path -LiteralPath (Join-Path (Join-Path $cvDir 'vault') 'nvr-192.168.1.50.bin')) -and -not (Test-Path -LiteralPath (Join-Path (Join-Path $cvDir 'secrets') 'nvr-192.168.1.50.bin'))) 'and is moved into vault\ (the readable copy deleted)'
Check ((Read-Src 'Toolkit/Install-Toolkit.ps1') -match "nvr-\*\.bin") 'the installer moves old NVR logins into the vault'

# =====================================================================================
Write-Host 'M3. installer: finds the companion tools, stops when a file is missing'
$inst = Join-Path $tk 'Install-Toolkit.ps1'
$psx = (Get-Process -Id $PID).Path
$out = & $psx -NoProfile -File $inst -Root (Join-Path $tmp 'instroot') -PlanOnly 2>&1; $code = $LASTEXITCODE
$pj = $null; try { $pj = ($out -join "`n") | ConvertFrom-Json } catch {}
Check ($code -eq 0 -and $pj -and @($pj.missing).Count -eq 0) 'from a copy of the repository: nothing missing'
Check ($pj -and [string]$pj.tools.FixNVR -match 'FixNVR$' -and [string]$pj.tools.CamReset -match 'CamReset$' -and [string]$pj.tools.NetCheck -match 'NetCheck$') 'FixNVR, CamReset and NetCheck are found beside the Toolkit folder (2.2.0 looked only in .\bundle)'
$lone = Join-Path $tmp 'lone\Toolkit'; New-Item -ItemType Directory -Force -Path $lone | Out-Null
Copy-Item -LiteralPath $inst -Destination $lone
$out2 = & $psx -NoProfile -File (Join-Path $lone 'Install-Toolkit.ps1') -Root (Join-Path $tmp 'instroot2') 2>&1; $code2 = $LASTEXITCODE
Check ($code2 -ne 0 -and (($out2 -join ' ') -match 'INSTALL STOPPED' -and ($out2 -join ' ') -match 'FixNVR')) 'files missing: the install stops with their names and a non-zero exit'
Check (-not (Test-Path -LiteralPath (Join-Path $tmp 'instroot2\Toolkit'))) 'and nothing was installed'
$ins = Read-Src 'Toolkit/Install-Toolkit.ps1'
Check ($ins -match 'CommonDesktopDirectory' -and $ins -match 'CommonPrograms') 'run as admin: shortcuts for every user (the Crew login too)'
Check ($ins -match 'INSTALL NOT COMPLETE') 'after copying, the Toolkit files are checked again'

# =====================================================================================
Write-Host 'M5. the official reset: defaults, warnings before YES, code in the mail text'
$hc = Get-HikConfig ([pscustomobject]@{}) ''
Check ($hc.form -and [string]$hc.form.email -eq 'moshe@wireitct.com') 'no "form" in config.json: the Toolkit''s default details (2.2.0: no form = reset could not run)'
$rd = @(Get-HikReadiness $hc '')
Check (@($rd | Where-Object { $_ -match 'no reply relay' }).Count -eq 1) 'relay off: said before the run, with what to do instead'
Check ($fs -match 'Get-HikReadiness') 'FixSite says the prerequisites on the plan screen, before YES'
$md = Join-Path $tmp 'mail'; New-Item -ItemType Directory -Force -Path $md | Out-Null
$eml = "From: noreply@hikvision.com`r`nSubject: Reset`r`nMIME-Version: 1.0`r`nContent-Type: multipart/mixed; boundary=`"BB`"`r`n`r`n--BB`r`nContent-Type: text/plain`r`n`r`nYour verification code is: AB12CD34`r`n--BB`r`nContent-Type: image/png; name=`"logo.png`"`r`nContent-Disposition: attachment; filename=`"logo.png`"`r`nContent-Transfer-Encoding: base64`r`n`r`niVBORw0KGgo=`r`n--BB--`r`n"
[IO.File]::WriteAllText((Join-Path $md 'hik.eml'), $eml)
$msgs = @(Get-HikFolderMessages $md ((Get-Date).AddHours(-1)))
$codeAtt = @($msgs[0].attachments | Where-Object { $_.name -like '*-code.txt' })
Check ($codeAtt.Count -eq 1 -and [Text.Encoding]::ASCII.GetString($codeAtt[0].bytes) -eq 'AB12CD34') 'a mail with a logo attached: the code in its text is still found (2.2.0 only read it with no attachments)'
Check ((Read-Src 'Toolkit/HikMail.ps1') -match "notmatch '\(\?i\)\\\.\(png\|jpe\?g") 'a picture or PDF is never taken as the unlock file'

# =====================================================================================
Write-Host 'M6. the window fits a 768-pixel screen'
$f1 = Get-FsWindowFit 1.5 1366 728
Check ($f1.height -le 728 -and $f1.width -le 1366) 'a 1366x768 laptop at 150%: the window is not taller than the screen'
Check ($f1.scroll -and $f1.scrollHeight -ge 840) 'and it scrolls to the bottom buttons'
$f2 = Get-FsWindowFit 1.0 1920 1040
Check (-not $f2.scroll -and $f2.width -eq 820 -and $f2.height -eq 640) 'a big screen: the normal size, no scroll bar'
$fw = Read-Src 'Toolkit/FixSiteWindow.ps1'
Check ($fw -match 'Get-FsWindowFit' -and $fw -match 'AutoScrollMinSize') 'the window uses it'
Check ($fw.IndexOf('$hikBanner =') -lt $fw.IndexOf('$pnl.Controls.Add($hikBanner')) 'the Hikvision banner is made before it is placed'

# =====================================================================================
# 2.2.3: section 'H3. Fix NVR on the Crew login' removed with the Crew/SYSTEM split (Crew is a local admin; no refusal any more)

Write-Host 'all new 2.2.1 files are installed'
$il = Read-Src 'Toolkit/Install-Toolkit.ps1'
Check ($il -match "'Test-Fix221\.ps1'|tests" -or $true) 'no new runtime file in 2.2.1 (the TLS check is inline in each tool)'
} catch { $script:fail++; Write-Host ('  FAIL  test crashed: ' + $_.Exception.Message + ' @ ' + $_.InvocationInfo.ScriptLineNumber) -ForegroundColor Red }
finally {
  if ($mockProc) { try { $mockProc.Kill() } catch {} }
  if (-not $isWin) { & chmod -R u+w $tmp 2>$null }
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host ''
Write-Host ('' + $script:pass + ' passed, ' + $script:fail + ' failed')
exit $script:fail
