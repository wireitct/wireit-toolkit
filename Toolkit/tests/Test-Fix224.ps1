<#
 Test-Fix224.ps1 - WireIt Toolkit 2.2.4 tests: Codex's re-review of toolkit-2.2.3-fixes @6c20133 (Nov 8 2026).
 Every check RUNS the real function or script against temp folders and mocks; none reads the source.
 A check marked "reproduction" failed on 6c20133 (2.2.3). pwsh 7 or Windows PowerShell 5.1, from any folder.
 Usage: powershell -NoProfile -ExecutionPolicy Bypass -File Toolkit\tests\Test-Fix224.ps1   (exit code = number of failed checks)
#>
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path; $tk = Split-Path -Parent $here; $repo = Split-Path -Parent $tk
$script:fail = 0; $script:pass = 0
function Check([bool]$ok, [string]$what) { if ($ok) { $script:pass++; Write-Host ('  ok    ' + $what) } else { $script:fail++; Write-Host ('  FAIL  ' + $what) -ForegroundColor Red } }
function Eq($a, $b, [string]$what) { Check ("$a" -eq "$b") ($what + ' (got "' + $a + '", want "' + $b + '")') }
function Try-Check([scriptblock]$b, [string]$what) { try { Check ([bool](& $b)) $what } catch { Check $false ($what + ' (threw: ' + $_.Exception.Message + ')') } }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fix224-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Force -Path $tmp | Out-Null
. (Join-Path $tk 'FixSiteCore.ps1'); . (Join-Path $tk 'FixSiteDevices.ps1')
$script:LogLines = New-Object System.Collections.ArrayList
function Fs-LogLine([string]$s) { [void]$script:LogLines.Add($s) }
$script:RealFsHttp = ${function:Fs-Http}
try {

# ------------------------------------------------------------------------------------------------------------------------------
Write-Host '1. site names that differ only in punctuation or spacing never share a store, list file or pictures folder'
$script:FsTestSecrets = $true
$sd = Join-Path $tmp 'sec1'; New-Item -ItemType Directory -Force -Path $sd | Out-Null
$names = @('A B', 'A_B', 'A  B', 'A/B', 'A-B')
foreach ($nm in $names) { $s = Read-FsSecrets $sd $nm; $s.password = 'Pw-' + $nm; Save-FsSecrets $sd $s }
foreach ($nm in $names) { Eq (Read-FsSecrets $sd $nm).password ('Pw-' + $nm) ('reproduction: "' + $nm + '" reads back its own password (2.2.3: "A B" and "A_B" overwrote each other)') }
Eq @(Get-ChildItem -LiteralPath $sd -Filter 'site-*.dat').Count $names.Count 'one password store per site name'
Eq (Read-FsSecrets $sd 'a b').password 'Pw-A B' 'the same name in another case is the same site'
# list files: write each site's list where Resolve-FsLocalList says, then read them all back
$ld = Join-Path $tmp 'lists1'; New-Item -ItemType Directory -Force -Path $ld | Out-Null
foreach ($nm in $names) { $p = Resolve-FsLocalList $ld $nm; ([ordered]@{ site = $nm; cameras = @() } | ConvertTo-Json) | Set-Content -LiteralPath $p }
foreach ($nm in $names) { Eq ((Get-Content -LiteralPath (Resolve-FsLocalList $ld $nm) -Raw | ConvertFrom-Json).site) $nm ('reproduction: "' + $nm + '" list file is its own') }
# 2.2.2 files (no fingerprint) are still read, only by the site they name
$od = Join-Path $tmp 'old1'; New-Item -ItemType Directory -Force -Path $od | Out-Null
[IO.File]::WriteAllText((Join-Path $od 'site-A_B.dat'), (Protect-FsText ([ordered]@{ site = 'A B'; password = 'OldPwAB' } | ConvertTo-Json -Compress)))
([ordered]@{ site = 'A B'; cameras = @() } | ConvertTo-Json) | Set-Content -LiteralPath (Join-Path $od 'A_B.json')
Eq (Read-FsSecrets $od 'A B').password 'OldPwAB' 'a 2.2.2 store (old file name) is still read by "A B"'
Check (-not (Read-FsSecrets $od 'A_B').password) '...and not by "A_B"'
Eq (Split-Path -Leaf (Resolve-FsLocalList $od 'A B')) 'A_B.json' 'a 2.2.2 list file is still read by its own site'
Check ((Split-Path -Leaf (Resolve-FsLocalList $od 'A_B')) -ne 'A_B.json') '...and "A_B" gets a new file of its own'
Check (Test-Path -LiteralPath (Get-FsSecretPath $od 'A B')) 'the 2.2.2 store was moved to the collision-proof name on first read'
# 2.2.3 file (6-hex fingerprint on punctuated names) still read
$o3 = Join-Path $tmp 'old3'; New-Item -ItemType Directory -Force -Path $o3 | Out-Null
$sha = [Security.Cryptography.SHA256]::Create(); $h3 = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes('a/b'))[0..2] | ForEach-Object { $_.ToString('x2') }); $sha.Dispose()
([ordered]@{ site = 'A/B'; cameras = @() } | ConvertTo-Json) | Set-Content -LiteralPath (Join-Path $o3 ('A_B-' + $h3 + '.json'))
Eq (Split-Path -Leaf (Resolve-FsLocalList $o3 'A/B')) ('A_B-' + $h3 + '.json') 'a 2.2.3 list file is still read by its own site'
$script:FsTestSecrets = $false
# camera pictures folder (CamViews): run the real save twice, same camera key
$cvd = Join-Path $tmp 'cv1'; New-Item -ItemType Directory -Force -Path $cvd | Out-Null
$job = Start-Job -ScriptBlock { param($tk, $cvd)
  . (Join-Path $tk 'CamViews.ps1') -Lib; $script:CvLogDir = Join-Path $cvd '_logs'; $script:CvPics = $cvd
  Save-CvLocal 'A B' 'ch1' '10.0.0.5' '20261108-1000' ([byte[]](1, 2, 3)); Save-CvLocal 'A/B' 'ch1' '10.0.0.5' '20261108-1000' ([byte[]](4, 5, 6)); Save-CvLocal 'A?B' 'ch1' '10.0.0.5' '20261108-1000' ([byte[]](7, 8, 9))
  @(Get-ChildItem -LiteralPath $cvd -Directory | Where-Object { $_.Name -ne '_logs' }).Count } -ArgumentList $tk, $cvd
$nCv = Receive-Job -Job $job -Wait -AutoRemoveJob
Eq $nCv 3 'reproduction: "A B", "A/B", "A?B" camera pictures go to 3 folders (2.2.3: "A/B" and "A?B" shared one)'

# ------------------------------------------------------------------------------------------------------------------------------
Write-Host '2. a backup that is only a login/HTML page (or an error answer) is FAILED, never "complete"'
$script:Fake = @{}; $script:Calls = New-Object System.Collections.ArrayList
Set-Item -Path function:global:Fs-Http -Value {
  param([string]$Ip, [string]$Path, [string]$Method = 'GET', [string]$Body = '', [string]$ContentType = 'application/xml', $Cred = $null, [int]$Timeout = 8, [string]$OutFile = '', [switch]$Secret, [switch]$Tls)
  $k = $Method + ' ' + $Ip + $Path; $v = $null; foreach ($p in $script:Fake.Keys) { if ($k -like $p) { $v = $script:Fake[$p]; break } }
  if ($null -eq $v) { return [pscustomobject]@{ code = 404; body = '' } }
  if ($v -is [string]) { $v = @{ code = 200; body = $v } }
  if ($OutFile -and $v.code -eq 200) { [IO.File]::WriteAllText($OutFile, [string]$v.body); return [pscustomobject]@{ code = 200; body = '' } }
  return [pscustomobject]@{ code = [int]$v.code; body = [string]$v.body }
}
$login = '<!DOCTYPE html><html><head><title>Login</title></head><body><form action="/doc/page/login.asp"><input type="password" name="pw"></form>' + ('<!-- pad -->' * 200) + '</body></html>'
$goodBin = ('HIKCFG' + [string][char]0) * 700
$net = '<?xml version="1.0"?><NetworkInterfaceList><NetworkInterface><id>1</id></NetworkInterface></NetworkInterfaceList>'
$str = '<?xml version="1.0"?><StreamingChannel><id>101</id></StreamingChannel>'
function Hik-Fake([string]$ip, $cfg, $nw = $net, $st = $str) { $script:Fake = @{ ('GET ' + $ip + '/ISAPI/System/configurationData') = $cfg; ('GET ' + $ip + '/ISAPI/System/Network/interfaces') = $nw; ('GET ' + $ip + '/ISAPI/Streaming/channels/101') = $st } }
$script:LogLines.Clear()
Hik-Fake '10.0.2.1' $login; $bf = @(Save-FsBackup '10.0.2.1' 'Hikvision' $null (Join-Path $tmp 'bk2a'))
Check (-not (Test-FsBackupComplete $bf 'Hikvision')) 'reproduction: configurationData answered with a login page -> NOT complete (2.2.3: "backup saved")'
Check ($script:FsBackupWhy -match 'login/HTML') ('...and why says login/HTML page (' + $script:FsBackupWhy + ')')
Check (@($script:LogLines | Where-Object { $_ -match 'backup FAILED: configurationData.bin' }).Count -eq 1) '...and the log says backup FAILED'
Check (-not (Test-Path -LiteralPath (Join-Path (Join-Path $tmp 'bk2a') 'configurationData.bin'))) '...and the login page is not kept as a "backup"'
Hik-Fake '10.0.2.2' $goodBin $login; $bf = @(Save-FsBackup '10.0.2.2' 'Hikvision' $null (Join-Path $tmp 'bk2b'))
Check (-not (Test-FsBackupComplete $bf 'Hikvision' -Nvr)) 'reproduction: network settings answered with a login page -> NOT complete'
Hik-Fake '10.0.2.3' '<?xml version="1.0" encoding="UTF-8"?><ResponseStatus><statusCode>4</statusCode><subStatusCode>notSupport</subStatusCode></ResponseStatus>'; $bf = @(Save-FsBackup '10.0.2.3' 'Hikvision' $null (Join-Path $tmp 'bk2c'))
Check (-not (Test-FsBackupComplete $bf 'Hikvision')) 'reproduction: an error answer saved as configurationData.bin -> NOT complete'
Hik-Fake '10.0.2.4' 'tiny'; $bf = @(Save-FsBackup '10.0.2.4' 'Hikvision' $null (Join-Path $tmp 'bk2d'))
Check (-not (Test-FsBackupComplete $bf 'Hikvision')) 'reproduction: a 4-byte "export" -> NOT complete'
Hik-Fake '10.0.2.5' $goodBin; $bf = @(Save-FsBackup '10.0.2.5' 'Hikvision' $null (Join-Path $tmp 'bk2e'))
Check (Test-FsBackupComplete $bf 'Hikvision') 'a real-looking export + network + stream = complete'
# files handed in directly (not through Save-FsBackup): the content is still checked
$d2 = Join-Path $tmp 'bk2f'; New-Item -ItemType Directory -Force -Path $d2 | Out-Null
[IO.File]::WriteAllText((Join-Path $d2 'configurationData.bin'), $login); [IO.File]::WriteAllText((Join-Path $d2 'network.xml'), $net)
Check (-not (Test-FsBackupComplete @((Join-Path $d2 'configurationData.bin'), (Join-Path $d2 'network.xml')) 'Hikvision' -Nvr)) 'a login page already on disk under the right name -> NOT complete'
# Dahua
$script:Fake = @{ 'GET 10.0.2.9/cgi-bin/Config.backup*' = ('{"Dahua":1}' + (' ' * 1000)); 'GET 10.0.2.9/cgi-bin/configManager.cgi?action=getConfig&name=Network' = $login; 'GET 10.0.2.9/cgi-bin/configManager.cgi?action=getConfig&name=Encode' = 'table.Encode[0].MainFormat[0].Video.Width=1920' }
$bf = @(Save-FsBackup '10.0.2.9' 'Dahua' $null (Join-Path $tmp 'bk2g'))
Check (-not (Test-FsBackupComplete $bf 'Dahua')) 'reproduction: Dahua network settings answered with a login page -> NOT complete'
$script:Fake['GET 10.0.2.9/cgi-bin/configManager.cgi?action=getConfig&name=Network'] = 'table.Network.eth0.IPAddress=10.0.2.9'
$bf = @(Save-FsBackup '10.0.2.9' 'Dahua' $null (Join-Path $tmp 'bk2h'))
Check (Test-FsBackupComplete $bf 'Dahua') 'Dahua export + key=value settings = complete'
# Fix NVR firmware update: the export taken first is checked the same way (real module function)
$nm2 = Import-Module (Join-Path $tk 'modules\NvrHealth\NvrHealth.psm1') -Force -PassThru -DisableNameChecking
$f2 = Join-Path $tmp 'fw-login.bin'; [IO.File]::WriteAllText($f2, $login); $f3 = Join-Path $tmp 'fw-ok.bin'; [IO.File]::WriteAllText($f3, $goodBin)
Check ((& $nm2 { param($p) Test-NhBackupFile $p } $f2) -match 'login') 'reproduction: Fix NVR: a login page as the pre-update export is FAILED (the update does not run)'
Eq (& $nm2 { param($p) Test-NhBackupFile $p } $f3) '' 'Fix NVR: a real-looking export passes'
Remove-Module NvrHealth -Force -ErrorAction SilentlyContinue

# ------------------------------------------------------------------------------------------------------------------------------
Write-Host '3. retention comes from continuous footage back from now, never from the oldest clip or the drive size alone'
$nm3 = Import-Module (Join-Path $tk 'modules\NvrHealth\NvrHealth.psm1') -Force -PassThru -DisableNameChecking
& $nm3 { param($ld) Set-NvrHealthOption LogDir $ld } (Join-Path $tmp 'nhlogs')
# a fake Hikvision NVR inside the module: one camera; $segs = the recorded spans (local time); drive 100% full
$run3 = {
  param($nm, [object[]]$spans, [switch]$FailSearch, [int]$Target = 45)
  & $nm {
    param($spans, $fail, $target)
    $script:FakeSpans = $spans; $script:FakeFail = $fail; $script:FakeNow = [datetime]'2026-11-08T10:00:00'
    function script:Http {
      param([string]$Ip, [string]$Method = 'GET', [string]$Path, [string]$Body = '', [string]$ContentType = '', $Credential = $null, [hashtable]$Headers = $null, [int]$Port = 0, [string]$Scheme = '', [switch]$NoLogBody, [int]$Timeout = 0, [byte[]]$BodyBytes = $null, [string]$OutFile = '')
      $ok = { param($b) [pscustomobject]@{ code = 200; body = $b; err = '' } }
      switch -Wildcard ($Path) {
        '/ISAPI/System/deviceInfo' { return (& $ok '<DeviceInfo><model>DS-7608NI-K2</model><serialNumber>S1</serialNumber><firmwareVersion>V4.1</firmwareVersion></DeviceInfo>') }
        '/ISAPI/System/time' { return (& $ok ('<Time><timeMode>NTP</timeMode><localTime>' + $script:FakeNow.ToString('yyyy-MM-ddTHH:mm:ss') + '</localTime><timeZone>CST+5:00:00DST01:00:00,M3.2.0/02:00:00,M11.1.0/02:00:00</timeZone></Time>')) }
        '/ISAPI/ContentMgmt/InputProxy/channels' { return (& $ok '<InputProxyChannelList><InputProxyChannel><id>1</id><name>Door</name><ipAddress>10.0.0.64</ipAddress></InputProxyChannel></InputProxyChannelList>') }
        '/ISAPI/ContentMgmt/InputProxy/channels/status' { return (& $ok '<InputProxyChannelStatusList><InputProxyChannelStatus><id>1</id><online>true</online><chanDetectResult>connect</chanDetectResult></InputProxyChannelStatus></InputProxyChannelStatusList>') }
        # 2.2.15 (Codex 2.2.14 R5): the stand-in track has a real recording schedule; Enable alone (no schedule) is now NOT CHECKED
        '/ISAPI/ContentMgmt/record/tracks' { return (& $ok '<TrackList><Track><id>101</id><Enable>true</Enable><TrackSchedule><ScheduleBlock><ScheduleAction><Actions><Record>true</Record></Actions></ScheduleAction></ScheduleBlock></TrackSchedule></Track></TrackList>') }
        '/ISAPI/ContentMgmt/Storage' { return (& $ok '<storage><hddList><hdd><id>1</id><capacity>3815447</capacity><freeSpace>0</freeSpace><status>ok</status><property>RW</property></hdd></hddList></storage>') }
        '/ISAPI/ContentMgmt/search' {
          if ($script:FakeFail -and $Body -notmatch '<startTime>2000-') { return [pscustomobject]@{ code = 500; body = ''; err = 'x' } }
          $fs = [datetime][regex]::Match($Body, '<startTime>([^<Z]+)').Groups[1].Value; $fe = [datetime][regex]::Match($Body, '<endTime>([^<Z]+)').Groups[1].Value
          $hit = @($script:FakeSpans | Where-Object { [datetime]$_[0] -lt $fe -and [datetime]$_[1] -gt $fs } | Sort-Object { [datetime]$_[0] })
          if ($Body -match '<maxResults>1<') { $hit = @($hit | Select-Object -First 1) }
          $items = -join ($hit | ForEach-Object { '<searchMatchItem><timeSpan><startTime>' + ([datetime]$_[0]).ToString('yyyy-MM-ddTHH:mm:ss') + 'Z</startTime><endTime>' + ([datetime]$_[1]).ToString('yyyy-MM-ddTHH:mm:ss') + 'Z</endTime></timeSpan></searchMatchItem>' })
          return (& $ok ('<CMSearchResult><responseStatusStrg>OK</responseStatusStrg><matchList>' + $items + '</matchList></CMSearchResult>'))
        }
        default { return [pscustomobject]@{ code = 404; body = ''; err = '' } }
      }
    }
    $script:LoginState = @{}
    Get-RecordingStatus -Ip '10.0.0.20' -Vendor Hikvision -Credential (New-Object PSCredential('admin', (ConvertTo-SecureString 'x1234567' -AsPlainText -Force))) -TargetDays $target -NoLog
  } $spans ([bool]$FailSearch) $Target
}
$now3 = [datetime]'2026-11-08T10:00:00'
$oneDay = @(,@($now3.AddHours(-26).ToString('s'), $now3.AddMinutes(-1).ToString('s')))
$orphan = @(,@($now3.AddDays(-60).ToString('s'), $now3.AddDays(-60).AddMinutes(5).ToString('s')))
$r3 = & $run3 $nm3 ($orphan + $oneDay)
Check (-not $r3.ok) 'reproduction: 1 day of footage + one isolated 60-day-old clip, drive full -> NOT "45-day target met" (2.2.3 said met)'
Check ($null -ne $r3.days_held -and [int]$r3.days_held -le 2) ('...days held is the continuous footage, not 60 (got ' + $r3.days_held + ')')
Check (@($r3.problems | Where-Object { $_ -match 'of 45 days' }).Count -eq 1) '...and the problem says "only N of 45 days"'
$r3 = & $run3 $nm3 $oneDay
Check (-not $r3.ok -and [int]$r3.days_held -le 1) '1 day of footage, drive full -> red, not met'
$full = @(,@($now3.AddDays(-50).ToString('s'), $now3.AddMinutes(-1).ToString('s')))
$r3 = & $run3 $nm3 $full
Check ($r3.ok -and [int]$r3.days_held -ge 45) ('50 days of continuous footage -> target met (got ' + $r3.days_held + ', ok=' + $r3.ok + ')')
$r3 = & $run3 $nm3 $full -FailSearch
Check (-not $r3.ok -and $null -eq $r3.days_held) 'the in-between footage search fails -> days held UNKNOWN, not met'
Remove-Module NvrHealth -Force -ErrorAction SilentlyContinue

# ------------------------------------------------------------------------------------------------------------------------------
# an ACL + Task Scheduler mock: paths are plain strings; icacls arguments are interpreted the way icacls.exe does for /reset, /T,
# /inheritance:r, /grant:r and /grant. ACL = @{ prot = inheritance off; aces = @(...) } ('inherited' = Windows' normal permissions)
$sep = [IO.Path]::DirectorySeparatorChar
function New-AclMock([string]$root, [switch]$Old222) {
  $m = @{ acl = @{}; files = New-Object System.Collections.ArrayList; task = [bool]$Old222; calls = New-Object System.Collections.ArrayList; adminUsers = @('S-1-5-21-9-9-9-1001', 'S-1-5-21-9-9-9-1002') }
  $tkd = $root + $sep + 'Toolkit'
  foreach ($p in @($root, $tkd, ($tkd + $sep + 'logs'), ($tkd + $sep + 'state'), ($tkd + $sep + 'vault'), ($tkd + $sep + 'secrets'), ($tkd + $sep + 'secrets' + $sep + 'upload-key.bin'), ($tkd + $sep + 'vault' + $sep + 'site-x.dat'), ($root + $sep + 'FixNVR'), ($root + $sep + 'CamReset'))) { [void]$m.files.Add($p); $m.acl[$p] = @{ prot = $false; aces = @('inherited') } }
  if ($Old222) {
    foreach ($p in @(($tkd + $sep + 'ipc'), ($tkd + $sep + 'ipc' + $sep + 'req.json'), ($tkd + $sep + 'FixSiteRunner.ps1'), ($tkd + $sep + 'WireItAcl.ps1'))) { [void]$m.files.Add($p); $m.acl[$p] = @{ prot = $false; aces = @('inherited') } }
    foreach ($t in @($tkd, ($root + $sep + 'FixNVR'), ($root + $sep + 'CamReset'))) { $m.acl[$t] = @{ prot = $true; aces = @('S-1-5-32-544:F', 'S-1-5-18:F', 'S-1-5-32-545:RX') } }
    foreach ($v in @(($tkd + $sep + 'vault'), ($tkd + $sep + 'secrets'))) { $m.acl[$v] = @{ prot = $true; aces = @('S-1-5-32-544:F', 'S-1-5-18:F') } }
  }
  return $m
}
function Get-AclMockOps($m) {
  return @{
    taskExists = { param($n) [void]$m.calls.Add('taskExists'); return $m.task }.GetNewClosure()
    taskDelete = { param($n) [void]$m.calls.Add('taskDelete ' + $n); $m.task = $false; return $true }.GetNewClosure()
    exists     = { param($p) return ($m.files -contains $p) }.GetNewClosure()
    remove     = { param($p) [void]$m.calls.Add('remove ' + $p); foreach ($f in @($m.files | Where-Object { $_ -eq $p -or $_.StartsWith($p + $sep) })) { $m.files.Remove($f); $m.acl.Remove($f) } }.GetNewClosure()
    children   = { param($p) return @($m.files | Where-Object { $_.StartsWith($p + $sep) -and -not $_.Substring($p.Length + 1).Contains([string]$sep) }) }.GetNewClosure()
    isLocked   = { param($p) return [bool]$m.acl[$p].prot }.GetNewClosure()
    adminUsers = { return $m.adminUsers }.GetNewClosure()
    icacls     = { param([string[]]$a)
      [void]$m.calls.Add('icacls ' + ($a -join ' ')); $p = $a[0]
      $targets = @($p); if ($a -contains '/T') { $targets += @($m.files | Where-Object { $_.StartsWith($p + $sep) }) }
      foreach ($t in $targets) {
        if (-not $m.acl.ContainsKey($t)) { continue }; $e = $m.acl[$t]
        for ($i = 1; $i -lt $a.Count; $i++) {
          switch -Regex ($a[$i]) {
            '^/reset$' { $e.prot = $false; $e.aces = @('inherited') }
            '^/inheritance:r$' { $e.prot = $true; $e.aces = @($e.aces | Where-Object { $_ -ne 'inherited' }) }
            '^/grant(:r)?$' { $repl = ($a[$i] -eq '/grant:r'); $i++; while ($i -lt $a.Count -and -not $a[$i].StartsWith('/')) { $g = $a[$i].TrimStart('*') -replace '\(OI\)|\(CI\)|\(IO\)', ''; $sid = $g.Split(':')[0]; if ($repl) { $e.aces = @($e.aces | Where-Object { -not $_.StartsWith($sid + ':') }) }; $e.aces = @($e.aces) + $g; $i++ }; $i-- }
          }
        }
      }
      return 0 }.GetNewClosure()
  }
}
. (Join-Path $tk 'ToolkitMigrate.ps1')
$owner = 'S-1-5-21-9-9-9-1001'
Write-Host '4. the installer''s permission reset never loosens vault\ or secrets\'
$root4 = Join-Path $tmp 'WireIt4'; $tk4 = $root4 + $sep + 'Toolkit'
$m4 = New-AclMock $root4 -Old222; $r4 = Invoke-TkMigration -Root $root4 -ToolkitDir $tk4 -OwnerSid $owner -Ops (Get-AclMockOps $m4)
foreach ($v in @('vault', 'secrets')) {
  $e = $m4.acl[$tk4 + $sep + $v]
  Check ($e.prot -and -not (@($e.aces) -contains 'inherited')) ('reproduction: ' + $v + '\ stays locked after the reset (2.2.3: icacls /reset /T opened it to inherited permissions)')
  Eq ((@($e.aces | ForEach-Object { $_.Split(':')[0] }) | Sort-Object -Unique) -join ',') (@('S-1-5-18', 'S-1-5-21-9-9-9-1001', 'S-1-5-32-544') -join ',') ('...' + $v + '\ = Administrators + SYSTEM + the installing owner only')
}
Check (@($m4.calls | Where-Object { $_ -match 'icacls .*(vault|secrets)\S* /reset' }).Count -eq 0) 'no /reset is ever run on vault\ or secrets\'
Check (-not $m4.acl[$tk4].prot -and @($m4.acl[$tk4 + $sep + 'logs'].aces) -contains 'inherited') 'the rest of the Toolkit folder gets Windows'' normal permissions back'
# a vault\ that an older installer already loosened is locked again
$m4b = New-AclMock $root4; $r4b = Invoke-TkMigration -Root $root4 -ToolkitDir $tk4 -OwnerSid $owner -Ops (Get-AclMockOps $m4b)
Check ($m4b.acl[$tk4 + $sep + 'vault'].prot -and -not (@($m4b.acl[$tk4 + $sep + 'vault'].aces) -contains 'inherited')) 'a vault\ left open by 2.2.3 is locked again on the next install'

Write-Host '5. #26: the upload key is readable by the logged-in admin without "Run as administrator"'
$keyAces = @($m4.acl[$tk4 + $sep + 'secrets' + $sep + 'upload-key.bin'].aces)
foreach ($u in @('S-1-5-21-9-9-9-1001', 'S-1-5-21-9-9-9-1002')) { Check ($keyAces -contains ($u + ':R')) ('reproduction: local admin user ' + $u + ' has read on upload-key.bin by its own SID (UAC: the Administrators group is deny-only unelevated)') }
Check (-not (@($m4.acl[$tk4 + $sep + 'vault' + $sep + 'site-x.dat'].aces) -match '1002:R').Count) '...and on nothing else (the site password store is not opened)'
# no read access at all: Get-CvKey says plainly what to do (a real file the process may not read)
$kd = Join-Path $tmp 'tk5'; New-Item -ItemType Directory -Force -Path (Join-Path $kd 'secrets') | Out-Null; $kf = Join-Path (Join-Path $kd 'secrets') 'upload-key.bin'; [IO.File]::WriteAllBytes($kf, [byte[]](1, 2, 3))
$canDeny = $false; if ($IsLinux -or $IsMacOS) { & chmod 000 $kf; try { [void][IO.File]::ReadAllBytes($kf) } catch { $canDeny = $true } }
if ($canDeny) {
  $job5 = Start-Job -ScriptBlock { param($tk, $kd) . (Join-Path $tk 'CamViews.ps1') -Lib; $script:CvHere = $kd; $script:CvLogDir = Join-Path $kd 'logs'; $env:WIREIT_UPLOAD_KEY = ''; $script:said = @(); function CvSay([string]$s, [string]$c = '') { $script:said += $s }; $k = Get-CvKey; Write-Output ($script:said -join ' | '); Write-Output ('KEY[' + $k + ']') } -ArgumentList $tk, $kd
  $o5 = @(Receive-Job -Job $job5 -Wait -AutoRemoveJob)
  Check ((@($o5) -join "`n") -match 'Run as administrator') 'reproduction: an unreadable key -> a clear "Run as administrator" message (2.2.3: silently no key)'
  Check ((@($o5) -join "`n") -match 'KEY\[\]') '...and no key is used'
  & chmod 600 $kf
} else { Write-Host '  skip  (Windows) the unreadable-key message needs a file this account may not read; checked on Linux/macOS' }

Write-Host '6. migration from 2.2.2: the SYSTEM task, the IPC folder and the old lock come off, once, and are logged'
Check (-not $m4.task) 'reproduction: the old SYSTEM task "\WireIt\Fix this site" is removed'
Check (-not ($m4.files -contains ($tk4 + $sep + 'ipc'))) 'the old IPC folder is removed'
Check (-not ($m4.files -contains ($tk4 + $sep + 'FixSiteRunner.ps1')) -and -not ($m4.files -contains ($tk4 + $sep + 'WireItAcl.ps1'))) 'the files only the SYSTEM design used are removed'
Check (-not $m4.acl[$root4 + $sep + 'FixNVR'].prot -and -not $m4.acl[$root4 + $sep + 'CamReset'].prot) 'the old lock is off FixNVR and CamReset too'
$lg = (@($r4.log) -join "`n")
Check ($lg -match 'SYSTEM task' -and $lg -match 'IPC folder' -and $lg -match 'folder lock' -and $lg -match 'FixSiteRunner') 'the log names each thing it removed'
Eq @($r4.warnings).Count 0 'no warnings'
$n0 = $m4.calls.Count
$r4c = Invoke-TkMigration -Root $root4 -ToolkitDir $tk4 -OwnerSid $owner -Ops (Get-AclMockOps $m4)
$again = @($m4.calls | Select-Object -Skip $n0)
Check (-not @($again | Where-Object { $_ -match '/reset|^remove|^taskDelete' }).Count) 'run again: nothing is removed or reset a second time (idempotent)'
Check ((@($r4c.log) -join ' ') -match 'nothing to remove') '...and the log says "nothing to remove"'
Check ($m4.acl[$tk4 + $sep + 'vault'].prot -and @($m4.acl[$tk4 + $sep + 'secrets' + $sep + 'upload-key.bin'].aces) -contains 'S-1-5-21-9-9-9-1002:R') '...and vault\ is still locked, the key still readable'
# the installer itself uses it (run the real installer script in plan-only mode is not possible off Windows; its migration block is the function above)

# ------------------------------------------------------------------------------------------------------------------------------
Write-Host '7. (replaces 2.2.3 source-reading checks) the real code, run'
Set-Item -Path function:global:Fs-Http -Value $script:RealFsHttp
. (Join-Path $PSScriptRoot 'TestPython.ps1'); $py7 = Get-TestPython   # 2.2.5: a real Python, never the Windows Store stub
if ($py7) {
  $seen7 = Join-Path $tmp 'auth7.txt'; $srv7 = Join-Path $tmp 'srv7.py'
  [IO.File]::WriteAllText($srv7, "import http.server, sys`nclass H(http.server.BaseHTTPRequestHandler):`n  def log_message(self, *a): pass`n  def do_GET(self):`n    if self.headers.get('Authorization'): open(sys.argv[1], 'a').write('AUTH ' + self.headers.get('Authorization')[:6] + '\n')`n    self.send_response(401); self.send_header('WWW-Authenticate', 'Basic realm=""cam""'); self.send_header('Content-Length', '0'); self.end_headers()`ns = http.server.HTTPServer(('127.0.0.1', 0), H); print(s.server_address[1], flush=True); s.serve_forever()`n")
  $psi7 = New-Object Diagnostics.ProcessStartInfo; $psi7.FileName = $py7; $psi7.Arguments = '"' + $srv7 + '" "' + $seen7 + '"'; $psi7.UseShellExecute = $false; $psi7.RedirectStandardOutput = $true; $psi7.CreateNoWindow = $true
  $p7 = [Diagnostics.Process]::Start($psi7); $port7 = [int]$p7.StandardOutput.ReadLine()
  try {
    $script:FsMockUrl = ''
    $r7 = Fs-Http -Ip ('127.0.0.1:' + $port7) -Path '/ISAPI/System/deviceInfo' -Cred (New-Object PSCredential('admin', (ConvertTo-SecureString 'NotSent#123' -AsPlainText -Force))) -Timeout 5
    Eq $r7.err 'basic-over-http' '#7 (was a source grep): a Basic-only challenge over plain HTTP -> refused'
    Check (-not (Test-Path -LiteralPath $seen7)) '#7: the camera never received an Authorization header (the password was not sent)'
  } finally { try { $p7.Kill() } catch {} }
} else { Write-Host '  skip  #7 live check: no Python on this PC' }

#@@NEXT@@

} finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host ''; Write-Host ('Test-Fix224: ' + $script:pass + ' passed, ' + $script:fail + ' failed')
exit $script:fail
