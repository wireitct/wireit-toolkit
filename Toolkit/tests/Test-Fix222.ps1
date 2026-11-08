<#
 Test-Fix222.ps1 - WireIt Toolkit 2.2.2 tests: the 2.2.1 re-review (Tab, Nov 7-8 2026) and Codex's re-review of 8bafca6.
 One block per finding; a check marked "reproduction" failed on 8bafca6 (2.2.1). pwsh 7 or Windows PowerShell 5.1.
 Devices are the mock site (tests\fixsite\mock_site.py, 127.0.0.1 only); real sockets on 127.0.0.1 give the TLS error kinds; this PC's
 network is a simulated adapter ($script:FsNetOps); Bitwarden is tests\fixsite\fakebw.py; ACLs and schtasks are recorders.
 Nothing here touches a real network, adapter, vault, task or ACL.
 Usage: pwsh -File Test-Fix222.ps1   (exit code = number of failed checks). WIREIT_PWSH75 = a PowerShell 7.5 for the SYSLIB0014 check.
#>
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path; $tk = Split-Path -Parent $here; $repo = Split-Path -Parent $tk
$script:fail = 0; $script:pass = 0
function Check([bool]$ok, [string]$what) { if ($ok) { $script:pass++; Write-Host ('  ok    ' + $what) } else { $script:fail++; Write-Host ('  FAIL  ' + $what) -ForegroundColor Red } }
function Eq($a, $b, [string]$what) { Check ("$a" -eq "$b") ($what + ' (got "' + $a + '", want "' + $b + '")') }
$isWin = ($env:OS -eq 'Windows_NT')
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fix222-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Force -Path $tmp | Out-Null
. (Join-Path $tk 'WireItAcl.ps1'); . (Join-Path $tk 'FixSiteIpc.ps1'); . (Join-Path $tk 'FixSiteCore.ps1'); . (Join-Path $tk 'FixSiteDevices.ps1')
$script:LogLines = New-Object System.Collections.ArrayList
function Fs-LogLine([string]$s) { [void]$script:LogLines.Add($s) }
function Read-Src([string]$rel) { return [IO.File]::ReadAllText((Join-Path $repo $rel)) }
$py = $(if (Get-Command python3 -ErrorAction SilentlyContinue) { 'python3' } else { 'python' })
$procs = New-Object System.Collections.ArrayList
function Start-Py([string]$script, [string[]]$a) {
  $psi = New-Object Diagnostics.ProcessStartInfo; $psi.FileName = (Get-Command $py).Source
  $psi.Arguments = '"' + $script + '" ' + (@($a | ForEach-Object { '"' + $_ + '"' }) -join ' '); $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.CreateNoWindow = $true
  $p = [Diagnostics.Process]::Start($psi); [void]$procs.Add($p); return [int]$p.StandardOutput.ReadLine()
}
function Mock-State([string]$url) { return (Invoke-WebRequest -Uri ($url + '/dev/_pc/state') -UseBasicParsing).Content | ConvertFrom-Json }
# small servers: 'hang' accepts and never answers; 'plain' answers plain HTTP (so an https:// call fails its TLS handshake); 'web' serves a folder
$srv = Join-Path $tmp 'srv.py'
[IO.File]::WriteAllText($srv, @'
import socket, sys, os, http.server, functools
if sys.argv[1] == 'web':
    h = functools.partial(http.server.SimpleHTTPRequestHandler, directory=sys.argv[2]); h.log_message = lambda *a: None
    s = http.server.HTTPServer(('127.0.0.1', 0), h); print(s.server_address[1], flush=True); s.serve_forever()
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('127.0.0.1', 0)); s.listen(8)
print(s.getsockname()[1], flush=True); keep = []
while True:
    c, _ = s.accept(); keep.append(c)
    if sys.argv[1] == 'plain':
        try:
            c.recv(4096); c.sendall(b'HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'); c.close()
        except Exception:
            pass
'@)
$fs = Read-Src 'Toolkit/FixSite.ps1'; $rn = Read-Src 'Toolkit/FixSiteRunner.ps1'; $ins = Read-Src 'Toolkit/Install-Toolkit.ps1'
try {
# =====================================================================================
Write-Host 'H1. plain HTTP only when the device truly has no HTTPS (refused on 443, or a known no-HTTPS model)'
$hangPort = Start-Py $srv @('hang'); $plainPort = Start-Py $srv @('plain')
$r = Fs-Http -Ip '127.0.0.1:1' -Path '/x' -Tls -Timeout 3
Eq $r.err 'refused' 'real socket: nothing listening (port closed) is "refused" = no HTTPS'
$r = Fs-Http -Ip ('127.0.0.1:' + $hangPort) -Path '/x' -Tls -Timeout 2
Eq $r.err 'timeout' 'real socket: no answer in time is "timeout", not "no HTTPS"'
$r = Fs-Http -Ip ('127.0.0.1:' + $plainPort) -Path '/x' -Tls -Timeout 4
Eq $r.err 'tls' 'real socket: a failed TLS handshake is "tls", not "no HTTPS"'
$script:FsTlsState = @{}; $script:FsPlainSecret.Clear(); $script:FsTlsFailed = @{}
$hp = '127.0.0.1:' + $hangPort; $pp = '127.0.0.1:' + $plainPort
$r = Fs-HttpSecret -Ip $hp -Path '/x' -Method 'PUT' -Body '<password>x</password>' -Timeout 2
Check ($r.code -eq 0 -and $r.tlsFailed -and -not (Test-FsSentPlain $hp)) 'reproduction (Codex H1): HTTPS timeout -> the password is NOT retried over plain HTTP (2.2.1 did)'
Eq (Get-FsTlsFailure $hp) 'timeout' '...and the reason is kept for the red line'
$r = Fs-HttpSecret -Ip $pp -Path '/x' -Method 'PUT' -Body '<password>x</password>' -Timeout 4
Check ($r.tlsFailed -and -not (Test-FsSentPlain $pp)) 'reproduction: TLS handshake failure -> the password is NOT sent over plain HTTP'
Check (@($script:LogLines | Where-Object { $_ -like '*ERROR 127.0.0.1:*HTTPS did not work*NOT sent*' }).Count -ge 2) 'the log says HTTPS did not work and the password was not sent'
$mu = 'http://127.0.0.1:' + (Start-Py (Join-Path $here 'fixsite\mock_site.py') @((Join-Path $here 'fixsite\mock-222.json'), '0'))
$script:FsMockUrl = $mu; $script:FsTlsState = @{}; $script:FsPlainSecret.Clear(); $script:FsTlsFailed = @{}
$cr = Fs-Cred 'Campass1357'
Check (-not (Set-FsPassword '192.168.1.31' 'Hikvision' $cr 'Newcam24680')) 'mock: HTTPS times out -> password NOT changed'
Check (-not (Set-FsPassword '192.168.1.32' 'Hikvision' $cr 'Newcam24680')) 'mock: HTTPS certificate/TLS fails -> password NOT changed'
$ms = Mock-State $mu
Check (-not (@($ms.plain_secrets) -contains '192.168.1.31') -and -not (@($ms.plain_secrets) -contains '192.168.1.32')) 'mock: neither got the password over plain HTTP'
Check (Set-FsPassword '192.168.1.33' 'Hikvision' $cr 'Newcam24680') 'mock: nothing on 443 (refused) = the one case that falls back to plain HTTP'
Check ((Test-FsSentPlain '192.168.1.33') -and (@((Mock-State $mu).plain_secrets) -contains '192.168.1.33')) 'mock: ...and it is on the warning list'
$script:FsModels['192.168.1.34'] = 'DS-OLDNOTLS-1'; $script:FsNoTlsModels = @('^DS-OLDNOTLS')
$c0 = @((Mock-State $mu).log).Count
Check (Set-FsPassword '192.168.1.34' 'Hikvision' $cr 'Newcam24680') 'mock: a model on the no-HTTPS list gets it over plain HTTP (with the warning)'
Check (-not @(@((Mock-State $mu).log | Select-Object -Skip $c0) | Where-Object { $_ -like 'TLS*' }).Count -and (Test-FsSentPlain '192.168.1.34')) 'mock: ...without an HTTPS try first'
Check (Set-FsPassword '192.168.1.35' 'Hikvision' $cr 'Newcam24680') 'mock: a device with working HTTPS: changed over HTTPS'
Check (-not (Test-FsSentPlain '192.168.1.35')) 'mock: ...and not on the warning list'
$script:FsNoTlsModels = @(); $script:FsMockUrl = ''
Check ($fs -match 'HTTPS did not work \(' -and $fs -match 'noHttpsModels' -and $fs -match '\$script:FsModels\[\[string\]\$d\.ip\]') 'FixSite: a red line per device, config.json noHttpsModels, the models from the scan'
Check ((Read-Src 'Toolkit/FixSiteDevices.ps1') -match 'Tls12 -bor \[Net\.SecurityProtocolType\]::Tls11 -bor \[Net\.SecurityProtocolType\]::Tls;') 'PS 5.1: TLS 1.0/1.1 allowed for devices (old firmware stays on HTTPS)'
foreach ($rel in @('FixNVR/FixNVR.ps1', 'NetCheck/NetCheck.ps1', 'Toolkit/modules/NvrHealth/NvrHealth.psm1')) { $src = Read-Src $rel; Check (($src -match 'Tls12 -bor \[Net\.SecurityProtocolType\]::Tls11 -bor \[Net\.SecurityProtocolType\]::Tls\b') -and -not ($src -match 'SecurityProtocol = \[Net\.SecurityProtocolType\]::Tls12\s*(\r?\n|#|;|$)')) ('reproduction (re-review risk 2): ' + $rel + ' - PS 5.1 allows TLS 1.0/1.1 for old firmware (2.2.1: exactly TLS 1.2)') }
$src = Read-Src 'Toolkit/ToolkitCore.ps1'; Check (($src -match 'SecurityProtocol = \[Net\.ServicePointManager\]::SecurityProtocol -bor \[Net\.SecurityProtocolType\]::Tls12') -and -not ($src -match 'SecurityProtocol = \[Net\.SecurityProtocolType\]::Tls12\s*(\r?\n|#|;|$)')) 'ToolkitCore: the update download adds TLS 1.2 instead of switching the device TLS versions off'
$sp0 = [Net.ServicePointManager]::SecurityProtocol
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls; [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12; Check (([int][Net.ServicePointManager]::SecurityProtocol -band [int][Net.SecurityProtocolType]::Tls11) -ne 0) 'the update line keeps TLS 1.1 on when a device tool set it (same process)' } finally { [Net.ServicePointManager]::SecurityProtocol = $sp0 }

# =====================================================================================
Write-Host 'H1 (classic Fix NVR). a password in the body goes over HTTPS; plain HTTP only when nothing listens on 443 (re-review H1)'
$nvrAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'FixNVR/FixNVR.ps1'), [ref]$null, [ref]$null)
foreach ($fn in @('Test-NvrSecretBody', 'Test-NvrTlsPort', 'Http', 'Base', 'Err-Body')) { $fa = $nvrAst.Find({ param($x) $x -is [Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $fn }, $true); . ([scriptblock]::Create($fa.Extent.Text)) }
$Mock = $null; $IsPs5 = ($PSVersionTable.PSVersion.Major -lt 6); $script:refused = @{}; $script:scheme = @{}; $script:nvrTls = @{}
$script:NvrLog = New-Object System.Collections.ArrayList; $script:NvrSay = New-Object System.Collections.ArrayList
function Log([string]$s) { [void]$script:NvrLog.Add($s) }; function Say([string]$s, [string]$c = '') { [void]$script:NvrSay.Add($s) }
Check ((Test-NvrSecretBody '<User><id>1</id><password>x</password></User>') -and (Test-NvrSecretBody '{"password":"x"}') -and -not (Test-NvrSecretBody '<passwordLevel>1</passwordLevel>') -and -not (Test-NvrSecretBody '<ipAddress>1.2.3.4</ipAddress>')) 'Fix NVR: a body with a password is recognised (and a body without one is not)'
Eq (Test-NvrTlsPort '127.0.0.1:1') 'refused' 'Fix NVR: nothing listening on the HTTPS port = "refused" (no HTTPS)'
$cr = New-Object PSCredential('admin', (ConvertTo-SecureString 'x' -AsPlainText -Force))
$r = Http ('127.0.0.1:' + $plainPort) 'PUT' '/ISAPI/ContentMgmt/InputProxy/channels/1' '<InputProxyChannel><sourceInputPortDescriptor><password>secret1</password></sourceInputPortDescriptor></InputProxyChannel>' 'application/xml' $cr 4
Check ($r.code -eq 0 -and ([string]$script:nvrTls['127.0.0.1:' + $plainPort]) -like 'failed:*' -and -not (@($script:NvrLog | Where-Object { $_ -like '*http://127.0.0.1:*' }).Count)) 'reproduction (re-review H1): Fix NVR, HTTPS handshake fails -> the channel password is NOT sent over plain HTTP (2.2.1 used http:// only)'
Check (@($script:NvrSay | Where-Object { $_ -match 'NOT sent over plain HTTP' }).Count -gt 0) 'Fix NVR: ...and the tech is told in red'
$r = Http ('127.0.0.1:' + $hangPort) 'PUT' '/ISAPI/Security/users/1' '<User><password>secret2</password></User>' 'application/xml' $cr 2
Check ($r.code -eq 0 -and ([string]$script:nvrTls['127.0.0.1:' + $hangPort]) -like 'failed:*') 'Fix NVR: HTTPS times out -> NOT sent over plain HTTP'
$n0 = $script:NvrLog.Count; $r = Http ('127.0.0.1:' + $hangPort) 'PUT' '/ISAPI/Security/users/1' '<User><password>secret2</password></User>' 'application/xml' $cr 2
Check ($script:NvrLog.Count -eq $n0) 'Fix NVR: the same device is not tried again in this run once HTTPS failed'
$script:NvrLog.Clear(); $r = Http '127.0.0.1:1' 'PUT' '/ISAPI/Security/users/1' '<User><password>secret3</password></User>' 'application/xml' $cr 3
Check ([string]$script:nvrTls['127.0.0.1:1'] -eq 'none' -and @($script:NvrLog | Where-Object { $_ -like '*https://127.0.0.1:1/*' }).Count -and @($script:NvrLog | Where-Object { $_ -like '*plain HTTP*' }).Count) 'Fix NVR: nothing on 443 (refused) = the one case that goes on over plain HTTP'
Check (@($script:NvrSay | Where-Object { $_ -match 'has no HTTPS' }).Count -gt 0) 'Fix NVR: ...with the yellow warning'
$script:NvrLog.Clear(); $r = Http '127.0.0.1:1' 'GET' '/ISAPI/System/deviceInfo' '' 'application/xml' $cr 3
Check (@($script:NvrLog | Where-Object { $_ -like 'GET http://127.0.0.1:1/*' }).Count -eq 1) 'Fix NVR: a read with no password keeps the old http:// first'
Remove-Item Function:\Log, Function:\Say, Function:\Http, Function:\Base -ErrorAction SilentlyContinue
# =====================================================================================
Write-Host 'H2. PowerShell 7 wrappers and curl: certificate check skipped for private IPv4 devices only (Codex H2)'
Check ((Test-WireItLanHost '192.168.1.20') -and (Test-WireItLanHost '10.0.0.5') -and (Test-WireItLanHost '172.20.1.1') -and (Test-WireItLanHost '169.254.3.4') -and (Test-WireItLanHost '127.0.0.1')) 'private / link-local / loopback IPv4 = LAN'
Check (-not (Test-WireItLanHost 'wireit-toolkit-dl.wireitct.workers.dev') -and -not (Test-WireItLanHost '8.8.8.8') -and -not (Test-WireItLanHost '172.32.0.1') -and -not (Test-WireItLanHost '') -and -not (Test-WireItLanHost '127.0.0.1:7001')) 'names, public addresses, host:port = not LAN'
foreach ($rel in @('Toolkit/FixSiteDevices.ps1', 'Toolkit/CamViews.ps1', 'Toolkit/modules/NvrHealth/NvrHealth.psm1', 'FixNVR/FixNVR.ps1', 'Toolkit/ToolkitCore.ps1', 'sitecheck/SiteCheck.ps1', 'NetCheck/NetCheck.ps1')) {
  $sx = Read-Src $rel
  $bad = @(($sx -split "`n") | Where-Object { $_ -match 'SkipCertificateCheck = \$true' -and $_ -notmatch 'Test-WireItLanHost' })
  $badK = @(($sx -split "`n") | Where-Object { $_ -notmatch '^\s*#' -and ($_ -match "'-k'," -or $_ -match "curl\.exe'\) -k ") -and $_ -notmatch 'Test-WireItLanHost' })
  Check ($bad.Count -eq 0 -and $badK.Count -eq 0) ('reproduction (Codex H2): ' + $rel + ' - no unconditional certificate skip and no unconditional curl -k')
}
$cvs = Read-Src 'Toolkit/CamViews.ps1'
Check ((Read-Src 'Toolkit/modules/NvrHealth/NvrHealth.psm1') -match "if \(Test-WireItLanHost \`$hostK\) \{ \`$ca \+= '-k' \}") 'NvrHealth curl fallback: -k only for a LAN address'
Write-Host 'SYSLIB0014. the TLS helper compiles on PowerShell 7.5 (.NET 9)'
foreach ($rel in @('Toolkit/FixSiteDevices.ps1', 'Toolkit/modules/NvrHealth/NvrHealth.psm1', 'sitecheck/SiteCheck.ps1', 'FixNVR/FixNVR.ps1', 'NetCheck/NetCheck.ps1')) {
  Check ((Read-Src $rel) -match 'Add-Type -TypeDefinition \$script:WireItLanTlsCode -IgnoreWarnings -WarningAction SilentlyContinue -ErrorAction Stop') ($rel + ': Add-Type ignores the obsolete-API warning')
}
Check (Enable-WireItLanTls) ('this PowerShell (' + $PSVersionTable.PSVersion + '): the helper compiles and installs')
$pw75 = $env:WIREIT_PWSH75; if (-not $pw75 -and (Test-Path '/home/user/opt/pwsh75/pwsh')) { $pw75 = '/home/user/opt/pwsh75/pwsh' }
if ($pw75 -and (Test-Path $pw75)) {
  $c75 = Join-Path $tmp 'c75.ps1'
  [IO.File]::WriteAllText($c75, @'
param([string]$Fsd)
. $Fsd
'V=' + $PSVersionTable.PSVersion.ToString()
'NEW=' + [string](Enable-WireItLanTls)
$code2 = $script:WireItLanTlsCode -replace 'WireItLanTls', 'WireItLanTlsOld'
try { Add-Type -TypeDefinition $code2 -ErrorAction Stop; 'OLD=ok' } catch { 'OLD=fails ' + ($_.Exception.Message -replace '\s+', ' ') }
'@)
  $o75 = & $pw75 -NoProfile -File $c75 (Join-Path $tk 'FixSiteDevices.ps1') 2>&1 | Out-String
  Check ($o75 -match 'V=7\.5' -and $o75 -match 'NEW=True') ('PowerShell 7.5: the 2.2.2 helper compiles (' + (($o75 -split "`n" | Where-Object { $_ -like 'V=*' }) -join '') + ')')
  Check ($o75 -match 'OLD=fails .*SYSLIB0014') 'reproduction (Codex): the 2.2.1 Add-Type (no -IgnoreWarnings) fails on 7.5 with SYSLIB0014'
} else { Write-Host '  (no PowerShell 7.5 here: set WIREIT_PWSH75 to run the 7.5 compile check)' }

# =====================================================================================
Write-Host 'H3/M2/installer. the SYSTEM helper only exists while Crew cannot change what it runs (Codex H3, M2, EXTRA)'
$wr = Join-Path $tmp 'acl/WireIt'; foreach ($d in @('Toolkit', 'Toolkit/modules/NvrHealth', 'CamReset', 'FixNVR', 'NetCheck')) { New-Item -ItemType Directory -Force -Path (Join-Path $wr $d) | Out-Null }
foreach ($f in @('Toolkit/FixSite.ps1', 'Toolkit/FixSiteRunner.ps1', 'Toolkit/config.json', 'Toolkit/modules/NvrHealth/NvrHealth.psm1', 'CamReset/Find-Cameras.ps1')) { Set-Content -LiteralPath (Join-Path $wr $f) 'x' }
$wrW = $wr.Replace('/', '\')
$script:aclMode = 'locked'
$script:WaGetAcl = { param($p)
  $e = @([pscustomobject]@{ sid = 'S-1-5-32-544'; rights = 0x1F01FF; allow = $true }, [pscustomobject]@{ sid = 'S-1-5-18'; rights = 0x1F01FF; allow = $true }, [pscustomobject]@{ sid = 'S-1-5-32-545'; rights = 0x1200A9; allow = $true })
  if ($script:aclMode -eq 'crewmodify' -and $p -like '*FixSiteRunner.ps1') { $e += [pscustomobject]@{ sid = 'S-1-5-32-545'; rights = 0x1301BF; allow = $true } }
  if ($script:aclMode -eq 'authwrite' -and $p -like '*config.json') { $e += [pscustomobject]@{ sid = 'S-1-5-11'; rights = 0x116; allow = $true } }
  if ($script:aclMode -eq 'unreadable' -and $p -like '*Find-Cameras.ps1') { throw 'access denied' }
  return $e }
function Wa-Join([string]$a, [string]$b) { return (Join-Path $a ($b -replace '\\', [string][IO.Path]::DirectorySeparatorChar)) }   # test: real paths on this OS
$lk0 = Test-WireItLocked $wr
Check ($lk0.ok -and @(Get-WireItLockPaths $wr).Count -ge 6) 'read back: Administrators + SYSTEM full, Users read + execute = locked (scripts, config.json, modules, CamReset all read)'
$script:aclMode = 'crewmodify'; $lk = Test-WireItLocked $wr
Check (-not $lk.ok -and (@($lk.why) -join ' ') -match 'FixSiteRunner\.ps1: S-1-5-32-545') 'Users with Modify on FixSiteRunner.ps1 = NOT locked (named)'
$script:aclMode = 'authwrite'; Check (-not (Test-WireItLocked $wr).ok) 'Authenticated Users able to write config.json (its bitwardenCli is run) = NOT locked'
$script:aclMode = 'unreadable'; Check (-not (Test-WireItLocked $wr).ok) 'a permission that cannot be read = NOT locked (never assumed fine)'
$script:aclMode = 'locked'
$env:WIREIT_ACL_TEST = '1'
$script:sch = New-Object System.Collections.ArrayList; $script:schQuery = 0
$schRun = { param($a) [void]$script:sch.Add(($a -join ' ')); if ($a[0] -eq '/Query') { return $script:schQuery }; return 0 }
$sdRun = { param($n, $s) }
$cs = Install-WireItCrewSetup $wr { param($a) return 5 } $schRun $sdRun
Check (-not $cs.ok -and -not $cs.taskOn) 'reproduction (Codex H3): icacls fails -> the setup stops (2.2.1 registered the SYSTEM task anyway)'
Check (-not @($script:sch | Where-Object { $_ -like '/Create*' }).Count -and @($script:sch | Where-Object { $_ -like '/Change*/DISABLE' }).Count -eq 1) '...no task is made, and a task an earlier install made is switched OFF'
$script:sch.Clear(); $script:aclMode = 'crewmodify'
$cs = Install-WireItCrewSetup $wr { param($a) return 0 } $schRun $sdRun
Check (-not $cs.ok -and -not @($script:sch | Where-Object { $_ -like '/Create*' }).Count -and @($script:sch | Where-Object { $_ -like '/Change*/DISABLE' }).Count -eq 1) 'reproduction (Codex EXTRA, upgrade): icacls says OK but Crew can still write a script -> task switched off, not (re)made'
$script:sch.Clear(); $script:aclMode = 'locked'
$cs = Install-WireItCrewSetup $wr { param($a) return 0 } $schRun $sdRun
Check ($cs.ok -and $cs.taskOn -and @($script:sch | Where-Object { $_ -like '/Create /F /TN \WireIt\Fix this site*' }).Count -eq 1) 'everything locked and read back: then (and only then) the task is made'
$script:sch.Clear(); $script:schQuery = 1
Check (Disable-WireItRunnerTask $schRun) 'no task yet: nothing to switch off'
$script:schQuery = 0
Check ($ins -notmatch 'Register-WireItRunnerTask' -and $ins -match '\$cs = Install-WireItCrewSetup \$Root' -and $ins -match "if \(-not \`$cs\.ok\) \{ 'INSTALL STOPPED") 'the installer makes the task only through the checked set-up, and stops (exit 5) when it fails'
Check ($ins -match "if \(\`$LASTEXITCODE -ne 0\) \{ \`$aclBad \+=" -and $ins -match 'if \(\$aclBad\.Count\) \{ \[void\]\(Disable-WireItRunnerTask\)') 'reproduction (Codex M2): the NVR-login move checks icacls'' exit code; a failure stops the install, task off'
Check ($rn -match 'Test-WireItLocked' -and $rn.IndexOf('Test-WireItLocked') -lt $rn.IndexOf('$psexe = ') -and $rn -match 'exit 8') 'the SYSTEM runner itself refuses while Crew could change the scripts (an upgrade nobody locked)'
Remove-Item Env:\WIREIT_ACL_TEST
Remove-Item Function:\Wa-Join; . (Join-Path $tk 'WireItAcl.ps1')

# =====================================================================================
Write-Host 'Release package. after an update the Crew set-up is put in place, or the update says "run the installer as admin"'
$script:WaGetAcl = { param($p) @([pscustomobject]@{ sid = 'S-1-5-32-545'; rights = 0x1200A9; allow = $true }) }
$su = Test-WireItCrewSetup $wr { param($a) return 1 }
Check (-not $su.ok -and (@($su.missing) -join ', ') -match 'Fix this site" task' -and (@($su.missing) -join ', ') -match 'vault') 'an update onto a 2.0.x PC: no task, no vault -> named as missing'
$script:WaGetAcl = $null
Check ($rn -match 'Install-WireItCrewSetup \(Split-Path -Parent \$ToolkitDir\) -KeepTask' -and $rn -match '\$res\.ok = \[bool\]\$cs\.ok' -and $rn -match 'run the Toolkit installer as administrator') 'Update through the SYSTEM task: permissions + vault\ + folders made after the files; a failure is NOT reported as success'
$wt = Read-Src 'Toolkit/WireItToolkit.ps1'
Check ($wt -match 'Test-WireItCrewSetup' -and $wt -match 'Install-WireItCrewSetup' -and $wt -match 'NOT FINISHED: .*Run the Toolkit installer as administrator') 'the window: an admin start repairs it; any other login is told plainly to run the installer as admin'

# =====================================================================================
Write-Host 'H4. network recovery: addresses, routes and gateway checked; a failure keeps the state and fails the run (Codex H4)'
function New-SimNet2([bool]$dhcp) {
  $script:sim = @{ dhcp = $dhcp; coexist = 'disabled'; addrs = New-Object System.Collections.ArrayList; gw = @('192.168.1.1'); calls = New-Object System.Collections.ArrayList; lease = 0; noRoute = $false; n = 0 }
  [void]$script:sim.addrs.Add([pscustomobject]@{ ip = '192.168.1.105'; prefix = 24; origin = $(if ($dhcp) { 'Dhcp' } else { 'Manual' }); skip = $false; store = 'ActiveStore'; addrState = 'Preferred' })
  $script:FsNetOps = @{
    state = { param($a) [void]$script:sim.calls.Add('state'); [pscustomobject]@{ dhcp = $script:sim.dhcp; coexist = $script:sim.coexist; addrs = @($script:sim.addrs); gw = @($script:sim.gw) } }
    coexist = { param($a) $script:sim.coexist = $(if ($a.on) { 'enabled' } else { 'disabled' }); return $true }
    dhcp = { param($a) $script:sim.dhcp = [bool]$a.on; return $true }
    addtemp = { param($a) [void]$script:sim.addrs.Add([pscustomobject]@{ ip = $a.ip; prefix = 24; origin = 'Manual'; skip = $true; store = 'ActiveStore'; addrState = 'Preferred' }); return 'Preferred' }
    remove = { param($a) foreach ($x in @($script:sim.addrs | Where-Object { $_.ip -eq $a.ip })) { $script:sim.addrs.Remove($x) }; return $true }
    addstatic = { param($a) [void]$script:sim.addrs.Add([pscustomobject]@{ ip = $a.ip; prefix = $a.prefix; origin = 'Manual'; skip = $false; store = 'ActiveStore'; addrState = 'Preferred' }); return $true }
    addroute = { param($a) if ($script:sim.noRoute) { return $true }; $script:sim.gw = @($script:sim.gw) + $a.gw; return $true }
    renew = { param($a) [void]$script:sim.calls.Add('renew'); return $true }
    wait = { param($a) [void]$script:sim.calls.Add('wait'); if ($script:sim.lease -gt 0) { $script:sim.lease--; if ($script:sim.lease -eq 0) { [void]$script:sim.addrs.Add([pscustomobject]@{ ip = '192.168.1.105'; prefix = 24; origin = 'Dhcp'; skip = $false; store = 'ActiveStore'; addrState = 'Preferred' }); $script:sim.gw = @('192.168.1.1') } }; return $true }
    free = { param($a) return $true }
  }
  $script:FsTemps.Clear(); $script:FsPcBefore = $null; $script:FsCoexistChanged = $false
}
function Drop-Lease { $script:sim.addrs.Clear(); [void]$script:sim.addrs.Add([pscustomobject]@{ ip = '192.168.0.253'; prefix = 24; origin = 'Manual'; skip = $true; store = 'ActiveStore'; addrState = 'Preferred' }); $script:sim.gw = @() }
$pcA = [pscustomobject]@{ ip = '192.168.1.105'; prefix = 24; mask = '255.255.255.0'; gw = '192.168.1.1'; ifIndex = 5; dhcp = $true; name = 'Ethernet' }
$st4 = Join-Path $tmp 'st4/fixsite-temp-ips.json'
New-SimNet2 $true; [void](Add-FsTempIp '192.168.0' $pcA $st4); Drop-Lease
$r = Remove-FsTempIps $st4
Check (-not $r.ok -and (@($r.problems) -join ' ') -match 'no address from DHCP' -and (@($r.problems) -join ' ') -match 'router 192\.168\.1\.1') 'reproduction (Codex H4): DHCP on, but no address and no gateway = NOT back (2.2.1: success, state deleted)'
Check (Test-Path -LiteralPath $st4) '...the state file is KEPT for the next start'
Check (@($script:sim.calls) -contains 'renew' -and @($script:sim.calls | Where-Object { $_ -eq 'wait' }).Count -ge 1) '...DHCP was asked again and the check repeated before giving up'
New-SimNet2 $true; [void](Add-FsTempIp '192.168.0' $pcA $st4); Drop-Lease; $script:sim.lease = 2
$r = Remove-FsTempIps $st4
Check ($r.ok -and -not (Test-Path -LiteralPath $st4)) 'DHCP hands address and router back after a few seconds: back, state deleted'
New-SimNet2 $false; $pcS = [pscustomobject]@{ ip = '192.168.1.105'; prefix = 24; mask = '255.255.255.0'; gw = '192.168.1.1'; ifIndex = 5; dhcp = $false; name = 'Ethernet' }
[void](Add-FsTempIp '192.168.0' $pcS $st4); $script:sim.gw = @(); $script:sim.noRoute = $true
$r = Remove-FsTempIps $st4
Check (-not $r.ok -and (@($r.problems) -join ' ') -match 'default route' -and (Test-Path -LiteralPath $st4)) 'reproduction: the default route is verified too - missing = NOT back, state kept'
$script:sim.noRoute = $false; [void](Remove-FsTempIps $st4)
New-SimNet2 $true; [void](Add-FsTempIp '192.168.0' $pcA $st4); $script:FsRestoreChecks = 2
$script:FsNetOps['state'] = { param($a) $script:sim.n = 1 + [int]$script:sim.n; if ($script:sim.n -ge 2) { throw 'read failed' }; [pscustomobject]@{ dhcp = $script:sim.dhcp; coexist = $script:sim.coexist; addrs = @($script:sim.addrs); gw = @($script:sim.gw) } }
$r = Remove-FsTempIps $st4
Check (-not $r.ok -and (@($r.problems) -join ' ') -match 'could not be read back' -and (Test-Path -LiteralPath $st4)) 'reproduction: the check-read fails = NOT back (2.2.1 swallowed it and deleted the state)'
$script:FsRestoreChecks = 5; $script:FsNetOps = $null; $script:FsTemps.Clear(); $script:FsPcBefore = $null
Check ($fs -match "if \(\`$nr -and -not \`$nr\.ok -and \`$code -in @\(0, 4\)\) \{ \`$code = 6 \}") 'reproduction: FixSite with the network not back exits 6, not success'
Check ($rn -match "if \(-not \`$nr\.ok\) \{ if \(\`$code -in @\(0, 4\)\) \{ \`$code = 6 \}") 'the SYSTEM runner: its own clean-up failing also makes the run a failure'
Check ((Get-FsExitWords 6) -match 'network could not be put back') 'the window says it in words (code 6)'

# =====================================================================================
Write-Host 'H8. a second Undo after the NVR was moved back goes to the NVR''s address NOW (Codex H8)'
$rbN = @([pscustomobject]@{ ip = '10.0.0.64'; target = '192.168.1.20'; old = [pscustomobject]@{ ip = '10.0.0.64' } })
$doneK = @{}; $isD = { param($k) $doneK.ContainsKey($k) }
Eq (Resolve-FsUndoNvrIp $rbN '192.168.1.20' $isD) '192.168.1.20' 'first Undo (NVR not moved back yet): the run address'
$doneK['nvrmove|10.0.0.64'] = 1
Eq (Resolve-FsUndoNvrIp $rbN '192.168.1.20' $isD) '10.0.0.64' 'reproduction: second Undo after the move-back: the OLD address (2.2.1 used the obsolete one)'
Eq (Resolve-FsUndoNvrIp $rbN '192.168.1.30' $isD) '192.168.1.30' 'an NVR that was never moved: unchanged'
Check ($fs -match '\$nv = Resolve-FsUndoNvrIp @\(\$r0\.nvrs\) \$nv0 \$isDone' -and $fs -match '\$nip = Resolve-FsUndoNvrIp @\(\$r0\.nvrs\) \$nip0 \$isDone' -and $fs -match "markDone \('nvrpw\|' \+ \`$nip0\)") 'Undo uses it for the channel restore and the NVR password, and records the step under its first key'

# =====================================================================================
Write-Host 'H9. an isolated camera switch: an adapter with only 169.254, or no router, can be picked and used'
$script:FsNetOps = @{ adapters = { @(
  [pscustomobject]@{ ip = '192.168.50.9'; prefix = 24; mask = '255.255.255.0'; gw = '192.168.50.1'; ifIndex = 3; dhcp = $true; name = 'Wi-Fi'; metric = 25 },
  [pscustomobject]@{ ip = '169.254.12.7'; prefix = 16; mask = '255.255.0.0'; gw = ''; ifIndex = 9; dhcp = $true; name = 'Ethernet (camera switch)'; metric = 99999 }) } }
$nets = @(Get-FsPcNets)
Eq $nets.Count 2 'the 169.254-only Ethernet is listed'
Eq (Select-FsPcNet $nets '2').ifIndex 9 '...and can be picked'
Check ((Format-FsPcNetChoice $nets)[1] -match 'no router, no DHCP address') 'the choice line says what it is'
$script:FsNetOps = @{ adapters = { @([pscustomobject]@{ ip = '192.168.1.250'; prefix = 24; mask = '255.255.255.0'; gw = ''; ifIndex = 4; dhcp = $false; name = 'Ethernet'; metric = 99999 }) } }
Eq (Get-FsPcNet).ifIndex 4 'reproduction: one adapter, no router: it is used (2.2.1 returned none and stopped)'
$script:FsNetOps = $null
$fdv = Read-Src 'Toolkit/FixSiteDevices.ps1'
Check ($fdv -notmatch "IPAddress -notlike '169\.254\.\*' \} \| Select-Object -First 1\s*\r?\n\s*if \(-not \`$a\) \{ continue \}") 'reproduction: Windows adapters with only 169.254 are no longer filtered out'
$ll = [pscustomobject]@{ ip = '169.254.12.7'; gw = ''; mask = '255.255.0.0'; prefix = 16 }
Eq (Get-FsScheme ([pscustomobject]@{ pc = $ll }) ([pscustomobject]@{ scheme = '192.168.1' })) '192.168.1' 'no router, 169.254 PC: the scheme comes from the saved site list'
Eq (Get-FsScheme ([pscustomobject]@{ pc = $ll }) $null) '' 'no router, 169.254 PC, no list: no scheme (never "169.254")'
Eq (Get-FsScheme ([pscustomobject]@{ pc = [pscustomobject]@{ ip = '192.168.7.250'; gw = '' } }) $null) '192.168.7' 'no router, fixed PC address: its scheme'
$dn = Get-FsDeviceNet $ll '192.168.1'; Check ($dn.mask -eq '255.255.255.0' -and $dn.gw -eq '192.168.1.1') 'a moved device on an isolated switch gets /24 and router .1 (never the 169.254 mask)'
$dn = Get-FsDeviceNet ([pscustomobject]@{ ip = '10.20.0.50'; gw = '10.20.0.1'; mask = '255.255.252.0' }) '10.20.0'; Check ($dn.mask -eq '255.255.252.0' -and $dn.gw -eq '10.20.0.1') 'with a router: the PC''s real mask and router, as before'
Check ($fs -notmatch "if \(-not \`$pc -or -not \`$pc\.gw\) \{ Say 'This PC is not on a network with a router" -and $fs -match '\$scheme = Get-FsScheme \(\[pscustomobject\]@\{ pc = \$pc \}\) \$list' -and $fs -match '\$devNet\.mask \$devNet\.gw') 'reproduction (Codex H9): FixSite no longer stops on "no router"; scheme from the list; device mask/router from Get-FsDeviceNet'
Check ($fs -match 'a PC with only 169\.254 needs an address on the site scheme too') 'a 169.254-only PC gets a temporary address on the site scheme to reach the cameras'

# =====================================================================================
Write-Host 'H11 + NEW-3. Bitwarden: the tech''s own login, the WireIt CT org collection, syncs checked, honest words (Codex H11)'
$bwState = Join-Path $tmp 'bw.json'; $env:FAKEBW_STATE = $bwState; $bw = Join-Path $here 'fixsite/fakebw.py'
if (-not $isWin) {
  $env:FAKEBW_MODE = ''; $env:FAKEBW_NOORG = ''; $env:FAKEBW_STATUS = ''
  Eq (Save-FsBitwarden $bw 'Lieber' 'Firstpw1234') 'saved' 'a new item: saved and read back'
  $it = @((Get-Content $bwState -Raw | ConvertFrom-Json).items)[0]
  Check ($it.organizationId -eq 'org-1' -and @($it.collectionIds) -contains 'col-sites') 'reproduction: it went into the WireIt CT organization, collection Sites (2.2.1: organizationId null = personal vault)'
  Check ($script:FsBwLast.where -eq 'org' -and (Format-FsBwResult 'saved' $script:FsBwLast 'Lieber - site password') -match 'WireIt CT organization, collection Sites: the office can see it') 'the words say where it is'
  $env:FAKEBW_NOORG = '1'
  Eq (Save-FsBitwarden $bw 'Durham' 'Otherpw5678') 'saved' 'a login that does not see the WireIt CT org: still saved...'
  Check ($script:FsBwLast.where -eq 'personal' -and (Format-FsBwResult 'saved' $script:FsBwLast 'x') -match 'YOUR OWN Bitwarden vault.*office can NOT see it') 'reproduction: ...and the words say PERSONAL vault, the office can NOT see it (2.2.1: "The office can see it")'
  $env:FAKEBW_NOORG = ''; $env:FAKEBW_MODE = 'nosync'
  Eq (Save-FsBitwarden $bw 'Lieber' 'Firstpw1234') 'failed' 'reproduction (Codex H11): syncs fail but the cached item matches -> NOT "exists" (2.2.1: exists = office-visible)'
  Eq $script:FsBwLast.why 'sync' '...the reason is the server'
  $env:FAKEBW_MODE = 'syncafter'; Remove-Item $bwState -Force
  Eq (Save-FsBitwarden $bw 'Lieber' 'Firstpw1234') 'failed' 'created, but the check-sync fails: not confirmed'
  Check ((Format-FsBwResult 'failed' $script:FsBwLast 'x') -match 'could not reach its server to confirm') '...and said so'
  $env:FAKEBW_MODE = ''; Remove-Item $bwState -Force -ErrorAction SilentlyContinue
  $script:FsBwLookup = $bw
  function Find-FsBitwarden($cfg) { return $script:FsBwLookup }
  $ans = Invoke-FsBwForRun ([pscustomobject]@{ site = 'Strand'; value = 'Strandpw2468' }) $null { param($t) '' }
  Check ($ans -like 'saved;org;*' -and $ans -notmatch 'Strandpw2468') 'the window saves it on the tech''s own login and answers "saved;org" (no password in the answer)'
  $pa = ConvertFrom-FsIpcAnswer 'bitwarden' ([pscustomobject]@{ answer = $ans })
  Check ($pa.result -eq 'saved' -and $pa.where -eq 'org' -and $pa.org -eq 'WireIt CT' -and $pa.collection -eq 'Sites') 'the run reads the answer (checked values only)'
  Eq (ConvertFrom-FsIpcAnswer 'bitwarden' ([pscustomobject]@{ answer = 'rm -rf;evil' })).result 'failed' 'a strange answer counts as failed'
  $env:FAKEBW_STATUS = 'locked'
  Eq (Invoke-FsBwForRun ([pscustomobject]@{ site = 'S2'; value = 'S2pw13579x' }) $null { param($t) '' }) 'locked;;skipped' 'locked and nothing typed: not saved, said so'
  Check ((Invoke-FsBwForRun ([pscustomobject]@{ site = 'S2'; value = 'S2pw13579x' }) $null { param($t) 'Master#1' }) -like 'saved;org;*') 'locked: the master password is asked in the window, then saved'
  $env:FAKEBW_STATUS = 'unauthenticated'
  Eq (Invoke-FsBwForRun ([pscustomobject]@{ site = 'S3'; value = 'S3pw13579x' }) $null $null) 'unauthenticated;;' 'not logged in on this login: said so'
  $env:FAKEBW_STATUS = ''
  Remove-Item Function:\Find-FsBitwarden; . (Join-Path $tk 'FixSiteBw.ps1')
} else { Write-Host '  (fakebw.py runs directly on Linux/macOS only; the source checks below still run)' }
$ask = Read-Src 'Toolkit/FixSiteAsk.ps1'
Check ($fs -match "kind = 'bitwarden'; site = \`$siteName; value = \`$pw" -and $fs -match "if \(\`$Ipc -and -not \`$BwPath\)") 'reproduction (NEW-3): a background (SYSTEM) run hands the Bitwarden save to the window instead of running bw as SYSTEM'
Check ($ask -match "'bitwarden' \{" -and $ask -match "FixSiteBw\.ps1" -and $ask.IndexOf("Remove-Item -LiteralPath (Join-Path `$Session ('q-{0:D4}.json' -f `$n))", $ask.IndexOf("'bitwarden' {")) -lt $ask.IndexOf('Invoke-FsBwForRun', $ask.IndexOf("'bitwarden' {"))) 'the window answers it with bw on its own login, deleting the question file (it holds the password) first'
Check ($fs -match "if \(\`$a\.where -eq 'org'\) \{ \`$sec\.bitwardenSaved = \`$true") 'only an item in the org counts as "saved for the office"'

# =====================================================================================
Write-Host 'M3. install from a copy of the repository, and run the installer again in place (Codex M3)'
$acp = Get-WireItAclPlan 'C:\WireIt'
Check (@($acp | Where-Object { $_.path -eq 'C:\WireIt\NetCheck\runs' -and ($_.args -join ' ') -match '\(OI\)\(CI\)\(IO\)M' }).Count -eq 1) 'reproduction (Codex M3): NetCheck\runs gets the Crew write grant (the Network check writes there)'
if (-not $isWin) {
  # a real run of the installer from a repository copy, then again from the installed folder (here it stops at the Windows-only firewall step)
  $src = Join-Path $tmp 'repo'; New-Item -ItemType Directory -Force -Path $src | Out-Null
  foreach ($d in @('Toolkit', 'FixNVR', 'CamReset', 'NetCheck')) { Copy-Item -LiteralPath (Join-Path $repo $d) -Destination $src -Recurse -Force }
  Copy-Item -LiteralPath (Join-Path $repo 'version.json') -Destination $src
  $iroot = Join-Path $tmp 'inst/WireIt'; $psx = (Get-Process -Id $PID).Path
  $o1 = & $psx -NoProfile -File (Join-Path $src 'Toolkit/Install-Toolkit.ps1') -Root $iroot -NoShortcut 2>&1 | Out-String
  $ivj = Join-Path $iroot 'Toolkit/version.json'
  Check ((Test-Path $ivj) -and ((Get-Content $ivj -Raw | ConvertFrom-Json).version -eq '2.2.2')) 'reproduction (NEW-2/M3): a repository copy installs Toolkit\version.json with its version (2.2.1: none -> "0.0.0")'
  $o2 = & $psx -NoProfile -File (Join-Path $iroot 'Toolkit/Install-Toolkit.ps1') -Root $iroot -NoShortcut 2>&1 | Out-String
  Check ($o2 -match 'FixNVR is already in place' -and $o2 -notmatch 'with itself') 'reproduction (Codex M3): run again from C:\WireIt\Toolkit it does not copy the tool folders onto themselves'
  Check (Test-Path (Join-Path $iroot 'Toolkit/FixSiteBw.ps1')) 'the new FixSiteBw.ps1 is installed'
} else { Write-Host '  (the installer run itself is checked on Windows by the Crew test)' }
Check ($ins -match "'FixSiteBw\.ps1'") 'the installer lists FixSiteBw.ps1'

# =====================================================================================
Write-Host 'M5. a code in the mail text needs its label; pictures and PDFs are never the unlock file (Codex M5)'
. (Join-Path $tk 'HikMail.ps1')
Eq (Get-HikCodeFromText 'Please enter the code provided by your installer.') '' 'reproduction: "the code provided" is no code (2.2.1 took "provided")'
Eq (Get-HikCodeFromText 'This code is valid for 48 hours.') '' '"code is valid" is no code'
Eq (Get-HikCodeFromText "Your verification code is: AB12CD34`r`nThanks") 'AB12CD34' 'labelled 8-character code: read'
Eq (Get-HikCodeFromText 'Security code: 7F3K9Q') '7F3K9Q' 'labelled 6-character code: read (2.2.1 needed exactly 8)'
Eq (Get-HikCodeFromText 'Reset key: aB3dE5fG7hJ9kL1mN3pQ') 'aB3dE5fG7hJ9kL1mN3pQ' 'labelled 20-character key: read (the relay''s 4-64 rule)'
Eq (Get-HikCodeFromText 'key: password') '' 'a label with a plain word after it (no digit): no code'
Eq (Get-HikCodeFromText 'Barcode: 12345678') '' '"barcode" is not the label "code"'
$devs = @([pscustomobject]@{ serial = 'DS-2CD2143G2-I20231111AAWRJ12345678'; shortSerial = 'J12345678'; mac = 'c4-2f-90-00-00-21' })
$msg = [pscustomobject]@{ subject = 'Hik'; id = 'm1'; text = ''; attachments = @(
  [pscustomobject]@{ name = 'DS-2CD2143G2-I20231111AAWRJ12345678.pdf'; bytes = [Text.Encoding]::ASCII.GetBytes('%PDF serial DS-2CD2143G2-I20231111AAWRJ12345678'); type = 'application/pdf' },
  [pscustomobject]@{ name = 'J12345678.jpg'; bytes = [byte[]](1, 2, 3); type = 'image/jpeg' }) }
$mr = Find-HikReplyMatches $devs @($msg)
Eq @($mr.matched).Count 0 'reproduction (Codex M5): a PDF / picture carrying our serial is NOT taken as the unlock file'
$msg.attachments = @($msg.attachments) + @([pscustomobject]@{ name = 'unlock-J12345678.xml'; bytes = [Text.Encoding]::ASCII.GetBytes('<x/>'); type = 'file' })
$mr = Find-HikReplyMatches $devs @($msg)
Check (@($mr.matched).Count -eq 1 -and $mr.matched[0].name -eq 'unlock-J12345678.xml') 'the real unlock file beside them is still found'

# =====================================================================================
Write-Host 'Reset resume. an "imported" device is checked BEFORE any new export (Codex: the export flipped it back to "exported")'
. (Join-Path $tk 'HikResetFlow.ps1')
$script:HkSay = { param($t, $c) }; $script:HkAsk = { param($t) '' }
$script:exports = New-Object System.Collections.ArrayList
function Find-HikSadp([int]$s) { return @([pscustomobject]@{ mac = 'aa-aa-aa-00-00-01'; ip = '192.168.1.31'; serial = 'S1'; model = 'm'; activated = $true; bootTime = '' }) }
function Request-HikResetExport($d) { [void]$script:exports.Add($d.serial); return [pscustomobject]@{ ok = $true } }
function Save-HikResetFile($d, $e, $o) { return (Join-Path $tmp 'req-S1.xml') }
function Receive-HikReplies { return [pscustomobject]@{ got = @(); unmatched = @() } }
function Save-HikWaitingList { }
function Submit-HikRequests { return @() }
function Start-Sleep { param([int]$Seconds, [int]$Milliseconds) }
$sd = Join-Path $tmp 'hikres'; New-Item -ItemType Directory -Force -Path $sd | Out-Null
$vu = (Get-Date).AddHours(10).ToString('s')
([ordered]@{ version = 1; devices = @([ordered]@{ serial = 'S1'; mac = 'aa-aa-aa-00-00-01'; ip = '192.168.1.31'; model = 'm'; status = 'imported'; validUntil = $vu; requestFile = (Join-Path $tmp 'old.xml'); bootTime = '' }) } | ConvertTo-Json -Depth 5) | Set-Content (Join-Path $sd 'state.json')
$res = Invoke-HikResetStage -Targets @([pscustomobject]@{ mac = 'aa:aa:aa:00:00:01' }) -SitePassword 'Sitepw12345' -StateDir $sd -Config ([pscustomobject]@{ form = [pscustomobject]@{ name = 'x' }; replyTo = '' }) -VerifyLogin { param($ip, $pw) $true } -WaitMinutes 0 -InboxEverySec 1
Check (@($res.fixed) -contains 'aa-aa-aa-00-00-01') 'reproduction: the device whose unlock file an earlier run imported is found fixed'
Eq $script:exports.Count 0 '...and is NOT asked for a new request file (that would cancel the reset that worked)'
Eq ([string]@((Get-Content (Join-Path $sd 'state.json') -Raw | ConvertFrom-Json).devices)[0].status) 'verified' '...its state is "verified"'
Remove-Item Function:\Start-Sleep

# =====================================================================================
$scc = [IO.File]::ReadAllText((Join-Path $repo 'sitecheck/WireIt-SiteCheck.cmd')); $sci = $scc.IndexOf('##' + 'PSSTART')
Check ($sci -gt 0 -and $scc.Substring($sci + 11).Trim() -eq (Read-Src 'sitecheck/SiteCheck.ps1').Trim()) 'reproduction (2.2.2 WIP): the Site check launcher .cmd carries the 2.2.2 SiteCheck.ps1 (the WIP changed the .ps1 only)'
# =====================================================================================
Write-Host 'Version. never 0.0.0, never a downgrade; 2.2.2 everywhere; the manifest lists every shipped file'
. (Join-Path $tk 'ToolkitCore.ps1')
$vt = Join-Path $tmp 'ver/WireIt/Toolkit'; New-Item -ItemType Directory -Force -Path $vt | Out-Null
Eq (Get-TkVersion $vt) '2.2.2' 'reproduction (NEW-2): no version.json anywhere -> the code''s own 2.2.2 (2.2.1: "0.0.0")'
Save-TkJson ([ordered]@{ version = '2.0.4' }) (Join-Path $vt 'version.json')
Eq (Get-TkVersion $vt) '2.2.2' 'a stale version.json (2.0.4) beside 2.2.2 code still reads 2.2.2'
$web = Join-Path $tmp 'web'; New-Item -ItemType Directory -Force -Path $web | Out-Null
$m204 = [ordered]@{ version = '2.0.4'; base = 'https://raw.githubusercontent.com/wireitct/wireit-toolkit/d424688ba2a6f6032b98384b549578e66ed796d6/'; files = @([ordered]@{ path = 'Toolkit/a.ps1'; sha256 = ('0' * 64) }) }
($m204 | ConvertTo-Json -Depth 4) | Set-Content (Join-Path $web 'version.json')
$wp = Start-Py $srv @('web', $web)
$ui = Get-TkUpdateInfo ([pscustomobject]@{ updateUrl = ('http://127.0.0.1:' + $wp + '/version.json'); updateTimeoutMs = 4000 }) $vt
Check ($ui.state -eq 'current') ('reproduction (NEW-2): the published 2.0.4 is NOT offered over 2.2.2 (state ' + $ui.state + ': ' + $ui.message + ')')
Remove-Item (Join-Path $vt 'version.json')
$ui = Get-TkUpdateInfo ([pscustomobject]@{ updateUrl = ('http://127.0.0.1:' + $wp + '/version.json'); updateTimeoutMs = 4000 }) $vt
Check ($ui.state -eq 'current' -and $ui.message -match 'newer than the published') 'a repository install with no version.json: still no "update" to 2.0.4, and it says why'
$threw = $false; try { Install-TkUpdate ([pscustomobject]$m204) $vt { param($u) [byte[]]@() } | Out-Null } catch { $threw = $_.Exception.Message -match 'not newer' }
Check $threw 'Install-TkUpdate itself refuses a version that is not newer'
$m9 = [ordered]@{ version = '2.2.3'; base = $m204.base; files = $m204.files }; ($m9 | ConvertTo-Json -Depth 4) | Set-Content (Join-Path $web 'version.json')
Eq (Get-TkUpdateInfo ([pscustomobject]@{ updateUrl = ('http://127.0.0.1:' + $wp + '/version.json'); updateTimeoutMs = 4000 }) $vt).state 'available' 'a NEWER published version (2.2.3) is offered'
$fcv = ''; if ((Read-Src 'Toolkit/FixSiteCore.ps1') -match "\`$script:FsVersion = '([^']+)'") { $fcv = $Matches[1] }
$tcv = ''; if ((Read-Src 'Toolkit/ToolkitCore.ps1') -match "\`$script:TkBuiltVersion = '([^']+)'") { $tcv = $Matches[1] }
$bwv = ''; if ((Read-Src 'Toolkit/FixSiteBw.ps1') -match "\`$script:FsVersion = '([^']+)'") { $bwv = $Matches[1] }
$man = Get-Content (Join-Path $repo 'version.json') -Raw | ConvertFrom-Json
Check ($fcv -eq '2.2.2' -and $tcv -eq '2.2.2' -and $bwv -eq '2.2.2' -and [string]$man.version -eq '2.2.2') ('one version everywhere: FixSiteCore ' + $fcv + ', ToolkitCore ' + $tcv + ', FixSiteBw ' + $bwv + ', version.json ' + $man.version)
Check ([string]$man.base -like ('*/' + [string]$man.commit + '/') -and [string]$man.commit -match '^[0-9a-f]{40}$') 'the manifest downloads from the commit it names'
Check (-not (Test-TkManifest $man)) 'the manifest passes the Toolkit''s own manifest check'
$listed = @($man.files | ForEach-Object { [string]$_.path })
$shipped = @(foreach ($top in @('Toolkit', 'FixNVR', 'CamReset', 'NetCheck')) { Get-ChildItem -LiteralPath (Join-Path $repo $top) -Recurse -File | Where-Object { $_.Name -ne 'config.json' -and $_.FullName -notmatch '[\\/](__pycache__|vault|secrets|ipc|inbox|logs)[\\/]' -and $_.Extension -ne '.pyc' } | ForEach-Object { $_.FullName.Substring($repo.Length + 1).Replace('\', '/') } })
$miss = @($shipped | Where-Object { $listed -notcontains $_ })
Check ($miss.Count -eq 0) ('every shipped file is in the manifest' + $(if ($miss.Count) { ' - missing: ' + ($miss -join ', ') } else { ' (' + $listed.Count + ' files)' }))
foreach ($h in @('HikSadp.ps1', 'HikPortal.ps1', 'HikPortalStep.ps1', 'HikMail.ps1', 'HikReset.ps1', 'HikResetFlow.ps1', 'HikEmailDrop.ps1', 'FixSiteAsk.ps1', 'FixSiteIpc.ps1', 'FixSiteRunner.ps1', 'WireItAcl.ps1', 'FixSiteBw.ps1')) { if ($listed -notcontains ('Toolkit/' + $h)) { Check $false ('manifest lists Toolkit/' + $h) } }
Check ((@('HikSadp.ps1', 'HikPortal.ps1', 'HikPortalStep.ps1', 'HikMail.ps1', 'HikReset.ps1', 'HikResetFlow.ps1', 'HikEmailDrop.ps1') | Where-Object { $listed -contains ('Toolkit/' + $_) }).Count -eq 7) 'reproduction (Codex): all the Hik reset files are in the manifest (2.0.4 listed none)'
$hb = @($man.files | Where-Object { (Get-TkSha256 (Join-Path $repo ([string]$_.path))) -ne ([string]$_.sha256).ToLower() } | ForEach-Object { $_.path })
Check ($hb.Count -eq 0) ('every listed hash is the file on this branch' + $(if ($hb.Count) { ' - wrong: ' + ($hb -join ', ') } else { '' }))
$bmOut = Join-Path $tmp 'version-built.json'
& (Join-Path $repo 'tools/Build-Manifest.ps1') -Commit ([string]$man.commit) -Released ([string]$man.released) -Out $bmOut | Out-Null
$bm = [IO.File]::ReadAllText($bmOut) | ConvertFrom-Json
Check ([string]$bm.version -eq '2.2.2' -and -not (Test-TkManifest $bm)) 'release package: tools\Build-Manifest.ps1 builds a manifest the Toolkit accepts, at the code''s own version'
Check ((@($bm.files | ForEach-Object { $_.path + '=' + $_.sha256 } | Sort-Object) -join '|') -eq (@($man.files | ForEach-Object { $_.path + '=' + ([string]$_.sha256).ToLower() } | Sort-Object) -join '|')) 'release package: version.json is exactly what the builder makes from this branch (no file missed, no stale hash)'
Check (@($man.files | Where-Object { -not (Test-Path (Join-Path $repo ([string]$_.path))) }).Count -eq 0) 'every listed file exists'
} finally { foreach ($p in $procs) { try { $p.Kill() } catch {} }; $script:FsMockUrl = '' }
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host ('' + $script:pass + ' passed, ' + $script:fail + ' failed') -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
exit $script:fail
