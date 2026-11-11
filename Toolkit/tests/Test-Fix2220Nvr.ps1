<# Test-Fix2220Nvr.ps1 - tests for WireIt Toolkit 2.2.20 (Nov 11 2026), the NvrHealth module part of Codex's review of 2.2.19
   (head ca8d5b3, NO-GO): R05, R10, R11, R12, R15, R21, plus the class a-f sweep of NvrFix.ps1, NvrHealth.psm1 and NvrCheck.ps1:
   R05 (class D) firmware: the bytes sent are read ONCE after YES and hashed; a file changed after YES is refused, nothing sent.
   R10 (class F) restart: an unreadable / unclear reboot answer keeps the reservation and says NOT CONFIRMED (never "NOT restarted");
       twins: Hikvision 5xx answers, re-add and time-fix lost answers are not "refused".
   R11 (class B) firmware outcome (both branches) and the restart's "came back" need the SAME saved identity (MAC as well as serial).
   R12 (class C) password: an HTTP 200 login / HTML page is not "the new password works" (accepted-write and lost-answer branches).
   R15 (class C) DW v3 + legacy storage: sizes must be real numbers and rows need an address; twin: Hikvision drive sizes;
       the report says NOT CHECKED, never "healthy" with 0 GB.
   R21 (class B) recording repair: the recorder is identified again before EACH track write and around the certifying read;
       twins: DW recording per-camera re-read, DW password final read by DW id, re-add final read, time fix (Hik + ONVIF).
   Every finding check RUNS the real module functions with stand-ins only for the device's web answers (as Codex's reproduce*.ps1
   did). Checks that only read source text say "(code shape)". No real device is touched: real-device behaviour stays DEFERRED.
   PS 5.1 or pwsh 7. FIX2220NVR_REPO (tests only) = run against another checkout (old-code proof: on 2.2.19 the finding checks FAIL). #>
$ErrorActionPreference = 'Stop'
$repo = $(if ($env:FIX2220NVR_REPO) { $env:FIX2220NVR_REPO } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) })
$tkDir = Join-Path $repo 'Toolkit'
$nhMod = Join-Path $tkDir 'modules/NvrHealth/NvrHealth.psm1'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fix2220nvr-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$script:pass = 0; $script:fail = 0; $script:deferred = 0
function Check([bool]$ok, [string]$name, [string]$more = '') {
  if ($ok) { $script:pass++; Write-Host ('PASS ' + $name) } else { $script:fail++; Write-Host ('FAIL ' + $name); if ($more) { Write-Host ('     ' + $more) } }
}
function Deferred([string]$name) { $script:deferred++; Write-Host ('DEFERRED ' + $name) }
foreach ($f in @($nhMod, (Join-Path $tkDir 'modules/NvrHealth/NvrFix.ps1'), (Join-Path $tkDir 'NvrCheck.ps1'))) {
  $e = $null; [void][Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$e); Check ($e.Count -eq 0) ('parses: ' + (Split-Path -Leaf $f)) ($e | Out-String)
}
$cred = New-Object PSCredential('admin', (ConvertTo-SecureString 'Review123' -AsPlainText -Force))
$newCred = New-Object PSCredential('admin', (ConvertTo-SecureString 'NewReview456' -AsPlainText -Force))
$script:n = 0
function InMod([scriptblock]$body, [object[]]$args2) {
  $script:n++
  $m = Import-Module $nhMod -Force -PassThru -DisableNameChecking
  try {
    & $m { param($ld) Set-NvrHealthOption LogDir $ld } (Join-Path $tmp ('logs' + $script:n))
    return (& $m $body @args2)
  } catch { return @{ threw = $_.Exception.Message } }
  finally { Remove-Module $m -Force -ErrorAction SilentlyContinue }
}
function J($o) { try { return ($o | ConvertTo-Json -Compress -Depth 5) } catch { return [string]$o } }

# ---------------- R05 + R11: firmware (Codex reproduce.ps1 "firmware-file-changed" / "firmware-other-mac") ----------------
# Hikvision device stand-in: deviceInfo answers MAC $script:MacB before the PUT and $script:MacA after it, version V4.0 -> V5.0;
# $script:PutCode = the HTTP code of the firmware PUT (0 = the answer is lost)
$fwRun = {
  param($cred, [string]$dir, [string]$mode)
  $script:phase = 'before'; $script:writes = 0; $script:sent = $null
  $script:MacB = 'AA:BB:CC:00:00:01'; $script:MacA = $(if ($mode -in @('othermac', 'lost-othermac')) { 'AA:BB:CC:00:00:99' } else { 'AA:BB:CC:00:00:01' })
  $script:PutCode = $(if ($mode -like 'lost*') { 0 } else { 200 })
  function script:Http {
    param($Ip, $Method = 'GET', $Path, $Body, $ContentType, $Credential, $Headers, $Port, $Scheme, [switch]$NoLogBody, $Timeout, $BodyBytes, $OutFile, [switch]$SecretTransport)
    if ($OutFile) { [IO.File]::WriteAllBytes($OutFile, [byte[]](@(1..255) * 4)); return @{ code = 200; body = '' } }
    if ($Method -eq 'PUT') { $script:writes++; $script:sent = $BodyBytes; $script:phase = 'after'; return @{ code = $script:PutCode; body = $(if ($script:PutCode -eq 200) { '<ResponseStatus><statusCode>1</statusCode></ResponseStatus>' } else { '' }) } }
    if ($Path -eq '/ISAPI/System/deviceInfo') {
      $mac = $(if ($script:phase -eq 'after') { $script:MacA } else { $script:MacB }); $ver = $(if ($script:phase -eq 'after') { 'V5.0' } else { 'V4.0' })
      return @{ code = 200; body = ('<DeviceInfo><model>DS-7608</model><macAddress>' + $mac + '</macAddress><firmwareVersion>' + $ver + '</firmwareVersion></DeviceInfo>') }
    }
    return @{ code = 404; body = '' }
  }
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $fw = Join-Path $dir 'fw.bin'; [IO.File]::WriteAllBytes($fw, [byte[]](1..20)); $hash = (Get-FileHash -LiteralPath $fw -Algorithm SHA256).Hash
  $script:FwPath = $fw
  $confirm = $(if ($mode -eq 'changed') { { [IO.File]::WriteAllBytes($script:FwPath, [byte[]](100..140)); 'YES' } } else { { 'YES' } })
  $r = Invoke-NvrFix -Fix firmware -Ip '10.0.0.20' -Vendor Hikvision -Credential $cred -File $fw -Sha256 $hash -BackupDir (Join-Path $dir 'bk') -Confirm $confirm
  $sentHash = ''; if ($script:sent) { $sh = [Security.Cryptography.SHA256]::Create(); $sentHash = ([BitConverter]::ToString($sh.ComputeHash([byte[]]$script:sent))).Replace('-', ''); $sh.Dispose() }
  return @{ ok = [bool]$r.ok; msg = [string]$r.msg; history = [string]$r.history; writes = $script:writes; sentLen = $(if ($script:sent) { $script:sent.Length } else { 0 }); sentOk = ($sentHash -eq $hash) }
}
$r = InMod $fwRun @($cred, (Join-Path $tmp 'fw1'), 'changed')
Check ($r.writes -eq 0 -and -not $r.ok -and $r.msg -match 'CHANGED after you typed YES') 'R05 (Codex reproduce.ps1 firmware-file-changed): the file is replaced after YES -> refused, NOTHING sent (2.2.19: 41 unapproved bytes uploaded, ok=True)' (J $r)
$r = InMod $fwRun @($cred, (Join-Path $tmp 'fw2'), 'same')
Check ($r.writes -eq 1 -and $r.sentOk -and $r.sentLen -eq 20 -and $r.ok) 'R05 control: an unchanged file is sent byte for byte (the sent bytes hash to the approved SHA-256) and the update is confirmed' (J $r)
$r = InMod $fwRun @($cred, (Join-Path $tmp 'fw3'), 'othermac')
Check (-not $r.ok -and $r.msg -match 'NOT confirmed' -and $r.msg -notmatch '^Updated') 'R11 (Codex reproduce.ps1 firmware-other-mac): MAC-only identity, a device with ANOTHER MAC reports the new version -> NOT confirmed (2.2.19: "Updated: V4.0 -> V5.0", ok=True)' (J $r)
$r = InMod $fwRun @($cred, (Join-Path $tmp 'fw4'), 'lost-othermac')
Check (-not $r.ok -and $r.msg -notmatch '^Updated') 'R11 twin (lost-answer branch): the answer is lost, a device with ANOTHER MAC reports the new version -> NOT confirmed (2.2.19: ok=True)' (J $r)
$r = InMod $fwRun @($cred, (Join-Path $tmp 'fw5'), 'lost')
Check ($r.ok -and $r.msg -match '^Updated') 'R11 control: the answer is lost and the SAME device (same MAC) reports the new version -> confirmed' (J $r)

# ---------------- R10 + R11: restart ----------------
# Uniview / Hikvision camera stand-in. $rebootAns = the reboot answer; after the reboot the camera is down for $downPolls polls,
# then answers with MAC $macAfter.
$rsRun = {
  param($cred, [string]$dir, [string]$vendor, $rebootAns, [int]$downPolls, [string]$macAfter)
  $script:reboots = 0; $script:after = $false; $script:down = $downPolls; $script:MacAfter = $macAfter; $script:RebootAns = $rebootAns; $script:DownPolls = $downPolls
  function script:Http {
    param($Ip, $Method = 'GET', $Path, $Body, $ContentType, $Credential, $Headers, $Port, $Scheme, [switch]$NoLogBody, $Timeout, $BodyBytes, $OutFile, [switch]$SecretTransport)
    if ($Path -in @('/LAPI/V1.0/System/Reboot', '/ISAPI/System/reboot')) { $script:reboots++; $script:after = $true; $script:down = $script:DownPolls; return $script:RebootAns }
    if ($script:after -and $script:down -gt 0) { $script:down--; return @{ code = 0; body = '' } }
    $mac = $(if ($script:after) { $script:MacAfter } else { 'AA:BB:CC:00:00:01' })
    if ($Path -eq '/LAPI/V1.0/System/DeviceInfo') { return @{ code = 200; body = ('{"Response":{"ResponseCode":0,"Data":{"SerialNumber":"CAM1","DeviceModel":"IPC","FirmwareVersion":"B123","MAC":"' + $mac + '"}}}') } }
    if ($Path -eq '/ISAPI/System/deviceInfo') { return @{ code = 200; body = ('<DeviceInfo><model>DS-2CD</model><serialNumber>CAM1</serialNumber><macAddress>' + $mac + '</macAddress><firmwareVersion>V5.7</firmwareVersion></DeviceInfo>') } }
    return @{ code = 404; body = '' }
  }
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $sf = Join-Path $dir 'restart.json'
  $r = Invoke-NvrFix -Fix restart -Ip '10.0.0.21' -Vendor $vendor -Credential $cred -StateFile $sf -BackupDir (Join-Path $dir 'bk') -Confirm { 'YES' } -WaitSec 1
  $lim = Fix-LimitOk $sf '10.0.0.21' (Get-Date)
  $script:after = $false
  $r2 = Invoke-NvrFix -Fix restart -Ip '10.0.0.21' -Vendor $vendor -Credential $cred -StateFile $sf -BackupDir (Join-Path $dir 'bk') -Confirm { 'YES' } -WaitSec 1
  return @{ ok = [bool]$r.ok; msg = [string]$r.msg; history = [string]$r.history; reboots = $script:reboots; nextBudgetOk = [bool]$lim.ok }
}
$r = InMod $rsRun @($cred, (Join-Path $tmp 'rs1'), 'Uniview', @{ code = 200; body = '<html>connection interrupted after reboot</html>' }, 0, 'AA:BB:CC:00:00:01')
Check ($r.reboots -eq 1 -and -not $r.nextBudgetOk -and $r.msg -notmatch 'NOT restarted' -and $r.msg -match 'NOT CONFIRMED') 'R10 (Codex reproduce-extra.ps1 malformed-reboot-answer): Uniview HTTP 200 with no readable code -> the reservation STAYS (no 2nd reboot), NOT CONFIRMED, never "It was NOT restarted" (2.2.19: two reboots, nextBudgetOk=True)' (J $r)
$r = InMod $rsRun @($cred, (Join-Path $tmp 'rs2'), 'Uniview', @{ code = 200; body = '{"Response":{"ResponseURL":"/LAPI/V1.0/System/Reboot","ResponseString":"Succeed"}}' }, 0, 'AA:BB:CC:00:00:01')
Check ($r.reboots -eq 1 -and -not $r.nextBudgetOk -and $r.msg -notmatch 'NOT restarted') 'R10 twin: Uniview JSON with NO ResponseCode -> unknown, the reservation stays (2.2.19: released, "NOT restarted")' (J $r)
$r = InMod $rsRun @($cred, (Join-Path $tmp 'rs3'), 'Hikvision', @{ code = 503; body = '' }, 0, 'AA:BB:CC:00:00:01')
Check ($r.reboots -eq 1 -and -not $r.nextBudgetOk -and $r.msg -notmatch 'NOT restarted') 'R10 twin (Hikvision): a 503 answer to the reboot is unknown, not a refusal -> the reservation stays, NOT CONFIRMED (2.2.19: released, "NOT restarted")' (J $r)
$r = InMod $rsRun @($cred, (Join-Path $tmp 'rs4'), 'Uniview', @{ code = 200; body = '{"Response":{"ResponseURL":"/LAPI/V1.0/System/Reboot","ResponseCode":3,"ResponseString":"Not Authorized","Data":{}}}' }, 0, 'AA:BB:CC:00:00:01')
Check ($r.nextBudgetOk -and $r.reboots -eq 2 -and $r.msg -match 'refused') 'R10 control (kept): an EXPLICIT refusal (ResponseCode 3) still takes the reservation back' (J $r)
$r = InMod $rsRun @($cred, (Join-Path $tmp 'rs5'), 'Uniview', @{ code = 200; body = '{"Response":{"ResponseCode":0}}' }, 1, 'AA:BB:CC:00:00:99')
Check (-not $r.ok -and $r.msg -match 'NOT proven to be the same camera' -and -not $r.nextBudgetOk) 'R11 twin (restart polling): the device that comes back at the address has ANOTHER MAC -> NOT confirmed, the restart stays counted (2.2.19: "The camera restarted and is back")' (J $r)
$r = InMod $rsRun @($cred, (Join-Path $tmp 'rs6'), 'Uniview', @{ code = 200; body = '{"Response":{"ResponseCode":0}}' }, 1, 'AA:BB:CC:00:00:01')
Check ($r.ok) 'R11 control: the SAME camera goes down and comes back -> restarted' (J $r)

# ---------------- R12: password ----------------
# $putAns = the password PUT answer; after it, deviceInfo answers $afterNew to the new login and $afterOld to the old one
$pwRun = {
  param($cred, $newCred, $putAns, $afterNew, $afterOld)
  $script:phase = 'before'; $script:writes = 0; $script:PutAns = $putAns; $script:AfterNew = $afterNew; $script:AfterOld = $afterOld
  $script:NewPw = $newCred.GetNetworkCredential().Password
  function script:Http {
    param($Ip, $Method = 'GET', $Path, $Body, $ContentType, $Credential, $Headers, $Port, $Scheme, [switch]$NoLogBody, $Timeout, $BodyBytes, $OutFile, [switch]$SecretTransport)
    if ($Method -eq 'PUT') { $script:writes++; $script:phase = 'after'; return $script:PutAns }
    if ($Path -eq '/ISAPI/System/deviceInfo') {
      if ($script:phase -eq 'after') { if ($Credential -and $Credential.GetNetworkCredential().Password -eq $script:NewPw) { return $script:AfterNew } else { return $script:AfterOld } }
      return @{ code = 200; body = '<DeviceInfo><model>DS-7608</model><macAddress>AA:BB:CC:00:00:01</macAddress><firmwareVersion>V4.0</firmwareVersion></DeviceInfo>' }
    }
    return @{ code = 404; body = '' }
  }
  $r = Invoke-NvrFix -Fix password -Ip '10.0.0.20' -Vendor Hikvision -Credential $cred -NewCredential $newCred -Confirm { 'YES' }
  return @{ ok = [bool]$r.ok; msg = [string]$r.msg; history = [string]$r.history; writes = $script:writes }
}
$okPut = @{ code = 200; body = '<ResponseStatus><statusCode>1</statusCode></ResponseStatus>' }
$html = @{ code = 200; body = '<html>Login page</html>' }
$good = @{ code = 200; body = '<DeviceInfo><model>DS-7608</model><macAddress>AA:BB:CC:00:00:01</macAddress></DeviceInfo>' }
$other = @{ code = 200; body = '<DeviceInfo><model>DS-7608</model><macAddress>AA:BB:CC:00:00:99</macAddress></DeviceInfo>' }
$r401 = @{ code = 401; body = '' }
$r = InMod $pwRun @($cred, $newCred, $okPut, $html, $html)
Check (-not $r.ok -and $r.msg -notmatch '^The new password works') 'R12 (Codex reproduce.ps1 password-html): the read-back is an HTTP 200 <html>Login page</html> -> NOT confirmed (2.2.19: "The new password works.", ok=True)' (J $r)
$r = InMod $pwRun @($cred, $newCred, $okPut, $other, $r401)
Check (-not $r.ok) 'R12 twin (identity): the new login is answered by ANOTHER device (other MAC) -> NOT confirmed (2.2.19: ok=True)' (J $r)
$r = InMod $pwRun @($cred, $newCred, @{ code = 0; body = '' }, $html, $html)
Check (-not $r.ok -and $r.msg -match 'UNKNOWN') 'R12 twin (lost-answer branch): answer lost, the new login gets an HTTP 200 login page -> UNKNOWN, not "the password IS changed" (2.2.19: ok=True)' (J $r)
$r = InMod $pwRun @($cred, $newCred, @{ code = 0; body = '' }, $r401, $html)
Check (-not $r.ok -and $r.msg -notmatch 'refused the new password') 'R12 twin (lost-answer branch): new refused, the OLD login gets an HTTP 200 login page -> UNKNOWN, not "refused, the old one still works" (2.2.19: refused)' (J $r)
$r = InMod $pwRun @($cred, $newCred, $okPut, $good, $r401)
Check ($r.ok -and $r.writes -eq 1) 'R12 control: the new login returns the same device''s DeviceInfo -> the new password works' (J $r)

# ---------------- R15: DW storage + Hikvision drives ----------------
$dwSt = {
  param([string]$v3, [string]$legacy)
  $script:V3 = $v3; $script:Legacy = $legacy
  function script:Http { param($Ip, $Method = 'GET', $Path, $Credential, $Port, $Timeout, $OutFile, $BodyBytes, $ContentType, $Body, $Headers, [switch]$NoLogBody, $Scheme)
    if ($Path -eq '/rest/v3/servers/this/storages/*/status') { if ($script:V3) { return @{ code = 200; body = $script:V3 } } else { return @{ code = 500; body = '' } } }
    if ($Path -eq '/api/storageSpace') { if ($script:Legacy) { return @{ code = 200; body = $script:Legacy } } else { return @{ code = 500; body = '' } } }
    return @{ code = 404; body = '' }
  }
  $t = @{ ip = '10.0.0.5'; vendor = 'DW'; cred = $null; port = 0; token = 'tok1' }
  $s = Dw-Storage $t
  return @{ ok = [bool]$s.ok; disks = @($s.disks).Count; status = $(if (@($s.disks).Count) { [string]@($s.disks)[0].status } else { '' }); cap = $(if (@($s.disks).Count) { @($s.disks)[0].capMB } else { $null }); why = [string]$s.why }
}
$r = InMod $dwSt @('[{"totalSpace":"unreadable","isOnline":true}]', '')
Check (-not $r.ok -and $r.status -ne 'ok') 'R15 (Codex reproduce-safety.ps1 DW-modern-storage-invalid-number): v3 [{"totalSpace":"unreadable","isOnline":true}] -> storage NOT CHECKED (2.2.19: read=True status=ok capacity 0)' (J $r)
$r = InMod $dwSt @('[{"url":"D:\\","totalSpace":"8000000000","freeSpace":"n/a","isOnline":true}]', '')
Check (-not $r.ok) 'R15 twin: v3 row with a free space that is not a number -> NOT CHECKED (2.2.19: healthy, free 0)' (J $r)
$r = InMod $dwSt @('[{"totalSpace":"8000000000","freeSpace":"100","isOnline":true}]', '')
Check (-not $r.ok) 'R15 twin (row identity): v3 row with no url / path -> NOT CHECKED (2.2.19: a drive with no name, healthy)' (J $r)
$r = InMod $dwSt @('', '{"error":"0","reply":{"storages":[{"url":"D:\\","totalSpace":"8000000000","freeSpace":"busy","isOnline":true}]}}')
Check (-not $r.ok) 'R15 twin (legacy endpoint): freeSpace "busy" -> NOT CHECKED (2.2.19: healthy, free 0)' (J $r)
$r = InMod $dwSt @('[{"url":"D:\\","totalSpace":"8000000000","freeSpace":"1000000000","isOnline":true}]', '')
Check ($r.ok -and $r.disks -eq 1 -and $r.status -eq 'ok') 'R15 control: a real v3 storage row still reads (1 drive ok)' (J $r)
$hikSt = {
  param([string]$cap)
  $script:Cap = $cap
  function script:Http { param($Ip, $Method = 'GET', $Path, $Credential, $Port, $Timeout, $OutFile, $BodyBytes, $ContentType, $Body, $Headers, [switch]$NoLogBody, $Scheme)
    if ($Path -eq '/ISAPI/ContentMgmt/Storage') { return @{ code = 200; body = ('<storage><hddList><hdd><id>1</id><capacity>' + $script:Cap + '</capacity><freeSpace>1000</freeSpace><status>ok</status></hdd></hddList><nasList><nas><id>1</id><capacity>' + $script:Cap + '</capacity><freeSpace>5</freeSpace><status>ok</status></nas></nasList></storage>') } }
    return @{ code = 404; body = '' }
  }
  $t = @{ ip = '10.0.0.20'; vendor = 'Hikvision'; cred = $null; port = 0 }
  $s = Hik-Storage $t
  return @{ ok = [bool]$s.ok; disks = @($s.disks).Count; known = @(@($s.disks) | ForEach-Object { if ($_.PSObject.Properties['sizeKnown']) { [string]$_.sizeKnown } else { 'none' } }) }
}
$r = InMod $hikSt @('garbage')
Check ($r.disks -eq 2 -and @($r.known | Where-Object { $_ -ne 'False' }).Count -eq 0) 'R15 twin (Hikvision): a drive / NAS capacity "garbage" is marked size UNKNOWN (2.2.19: hdd = 0 MB healthy; NAS threw)' (J $r)
$r = InMod $hikSt @('4000000')
Check ($r.disks -eq 2 -and @($r.known | Where-Object { $_ -ne 'True' }).Count -eq 0) 'R15 control (Hikvision): real sizes stay known' (J $r)
# what the technician reads (DW recording check, end to end): the unreadable drive is NOT CHECKED, never "healthy"
$dwRec = {
  param($cred)
  function script:Http { param($Ip, $Method = 'GET', $Path, $Credential, $Port, $Timeout, $OutFile, $BodyBytes, $ContentType, $Body, $Headers, [switch]$NoLogBody, $Scheme)
    if ($Path -eq '/rest/v3/login/sessions') { return @{ code = 200; body = '{"token":"tok1"}' } }
    if ($Path -eq '/api/moduleInformation') { return @{ code = 200; body = '{"reply":{"version":"5.1.0","name":"DW"}}' } }
    if ($Path -eq '/api/gettime') { return @{ code = 200; body = ('{"reply":{"utcTime":' + [long]([DateTime]::UtcNow - (New-Object DateTime(1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc)))).TotalMilliseconds + ',"timezoneId":"America/New_York"}}') } }
    if ($Path -like '/rest/v3/devices*') { return @{ code = 200; body = '[{"id":"{c1}","name":"Cam 1","status":"Online","url":"http://10.0.0.21","schedule":{"isEnabled":true}}]' } }
    if ($Path -eq '/rest/v3/servers/this/storages/*/status') { return @{ code = 200; body = '[{"totalSpace":"unreadable","isOnline":true}]' } }
    if ($Path -eq '/api/storageSpace') { return @{ code = 500; body = '' } }
    if ($Path -like '/ec2/recordedTimePeriods*') { return @{ code = 200; body = '[]' } }
    return @{ code = 404; body = '' }
  }
  $r = Get-RecordingStatus -Ip '10.0.0.5' -Vendor DW -Credential $cred -TargetDays 30 -NoLog
  return @{ ok = [bool]$r.ok; problems = @($r.problems); say = @(Get-NvrHealthSummary) -join ' | ' }
}
$r = InMod $dwRec @($cred)
Check ($r.say -notmatch 'healthy' -and @($r.problems | Where-Object { $_ -match 'storage NOT CHECKED' }).Count -ge 1) 'R15 (reporting, end to end): the DW recording check with the unreadable v3 size says storage NOT CHECKED and never "healthy" (2.2.19: "Drive : 0 GB - healthy")' ((@($r.problems) -join '; '))

# ---------------- R21: recording repair, identity before EACH write ----------------
# Codex reproduce-recording-swap.ps1: the answering recorder switches from ORIGINAL to OTHER after the first PUT
$recSwap = {
  param($cred, [string]$dir, [string]$mode)
  $script:owner = 'ORIGINAL'; $script:writes = @()
  $script:tracks = @{ ORIGINAL = @{ 101 = 'false'; 201 = 'false' }; OTHER = @{ 101 = 'true'; 201 = 'true' } }
  if ($mode -eq 'one') { $script:tracks.ORIGINAL = @{ 101 = 'false' }; $script:tracks.OTHER = @{ 101 = 'true' } }
  function script:TrackXml($id) { '<Track><id>' + $id + '</id><Enable>' + $script:tracks[$script:owner][$id] + '</Enable><TrackSchedule><Record>true</Record></TrackSchedule></Track>' }
  function script:Http {
    param($Ip, $Method = 'GET', $Path, $Body, $ContentType, $Credential, $Headers, $Port, $Scheme, [switch]$NoLogBody, $Timeout, $BodyBytes, $OutFile, [switch]$SecretTransport)
    if ($Path -eq '/ISAPI/System/deviceInfo') { return @{ code = 200; body = ('<DeviceInfo><model>NVR</model><serialNumber>' + $script:owner + '</serialNumber><macAddress>' + $(if ($script:owner -eq 'ORIGINAL') { 'AA:BB:CC:00:00:01' } else { 'AA:BB:CC:00:00:99' }) + '</macAddress></DeviceInfo>') } }
    if ($Method -eq 'PUT') { $id = [int]($Path -split '/')[-1]; $script:writes += ($script:owner + ' track ' + $id); $script:tracks[$script:owner][$id] = 'true'; if ($script:owner -eq 'ORIGINAL') { $script:owner = 'OTHER' }; return @{ code = 200; body = '<ResponseStatus><statusCode>1</statusCode></ResponseStatus>' } }
    if ($Path -eq '/ISAPI/ContentMgmt/record/tracks') { return @{ code = 200; body = ('<TrackList>' + (@($script:tracks[$script:owner].Keys | Sort-Object | ForEach-Object { TrackXml $_ }) -join '') + '</TrackList>') } }
    if ($Path -like '/ISAPI/ContentMgmt/record/tracks/*') { return @{ code = 200; body = (TrackXml ([int]($Path -split '/')[-1])) } }
    return @{ code = 404; body = '' }
  }
  $r = Invoke-NvrFix -Fix recording -Ip '10.0.0.20' -Vendor Hikvision -Credential $cred -BackupDir $dir -Confirm { 'YES' }
  return @{ ok = [bool]$r.ok; msg = [string]$r.msg; history = [string]$r.history; writes = @($script:writes); orig201 = $(if ($script:tracks.ORIGINAL.ContainsKey(201)) { $script:tracks.ORIGINAL[201] } else { '' }) }
}
$r = InMod $recSwap @($cred, (Join-Path $tmp 'rec1'), 'two')
Check ((@($r.writes) -join ',') -eq 'ORIGINAL track 101' -and -not $r.ok -and $r.msg -match 'STOPPED' -and $r.msg -match 'NOT done: camera 2') 'R21 (Codex reproduce-recording-swap.ps1): the recorder at the IP changes after the first track write -> NO write to the other recorder, STOPPED, camera 2 reported NOT done (2.2.19: wrote OTHER track 201, ok=True "Recording is ON again")' (J $r)
$r = InMod $recSwap @($cred, (Join-Path $tmp 'rec2'), 'one')
Check (-not $r.ok -and $r.msg -notmatch 'Recording is ON again') 'R21 twin (certifying read): one track written, then another recorder answers the read-back -> NOT confirmed (2.2.19: the other recorder''s list certified ok=True)' (J $r)

# DW recording: the camera list is read again right before EACH camera's write
$dwRecFix = {
  param($cred, [string]$dir)
  $script:Writes = @()
  function script:Http {
    param($Ip, $Method = 'GET', $Path, $Body, $ContentType, $Credential, $Headers, $Port, $Scheme, [switch]$NoLogBody, $Timeout, $BodyBytes, $OutFile, [switch]$SecretTransport)
    if ($Path -eq '/rest/v3/login/sessions' -and $Method -eq 'POST') { return @{ code = 200; body = '{"token":"tok1"}' } }
    if ($Method -in @('PATCH', 'PUT', 'POST', 'DELETE')) { $script:Writes += ($Method + ' ' + $Path); return @{ code = 200; body = '{}' } }
    if ($Path -like '/rest/v3/devices*') {
      # after the first PATCH, camera 2's DW entry points at another address (another camera now)
      $ip2 = $(if (@($script:Writes).Count -ge 1) { '10.0.0.77' } else { '10.0.0.22' })
      $s1 = $(if (@($script:Writes | Where-Object { $_ -match 'c1' }).Count) { 'true' } else { 'false' })
      return @{ code = 200; body = ('[{"id":"{c1}","name":"Cam 1","status":"Online","url":"http://10.0.0.21","mac":"AA:BB:CC:00:00:21","schedule":{"isEnabled":' + $s1 + '}},{"id":"{c2}","name":"Cam 2","status":"Online","url":"http://' + $ip2 + '","mac":"AA:BB:CC:00:00:22","schedule":{"isEnabled":false}}]') }
    }
    return @{ code = 404; body = '' }
  }
  $r = Invoke-NvrFix -Fix recording -Ip '10.0.0.5' -Vendor DW -Credential $cred -BackupDir $dir -Confirm { 'YES' }
  return @{ ok = [bool]$r.ok; msg = [string]$r.msg; writes = @($script:Writes | Where-Object { $_ -notmatch 'login' }) }
}
$r = InMod $dwRecFix @($cred, (Join-Path $tmp 'dwrec'))
Check (@($r.writes).Count -eq 1 -and @($r.writes)[0] -match 'c1' -and -not $r.ok) 'R21 twin (DW recording): camera 2''s DW entry changes to another address between the writes -> camera 2 is NOT written (2.2.19: written from the list read once after YES)' (J $r)

# DW password: the final "DW now says Online" read must be the SAME DW camera (DW id), not just the same address
$dwPw = {
  param($cred, $newCred, [string]$dir)
  $script:Writes = @()
  function script:Http {
    param($Ip, $Method = 'GET', $Path, $Body, $ContentType, $Credential, $Headers, $Port, $Scheme, [switch]$NoLogBody, $Timeout, $BodyBytes, $OutFile, [switch]$SecretTransport)
    if ($Path -eq '/rest/v3/login/sessions' -and $Method -eq 'POST') { return @{ code = 200; body = '{"token":"tok1"}' } }
    if ($Method -in @('PATCH', 'PUT', 'POST', 'DELETE')) { $script:Writes += ($Method + ' ' + $Path); return @{ code = 200; body = '{}' } }
    if ($Path -like '/rest/v3/devices*') {
      if (@($script:Writes).Count) { return @{ code = 200; body = '[{"id":"{other}","name":"Other cam","status":"Online","url":"http://10.0.0.21","mac":"AA:BB:CC:00:00:99","schedule":{"isEnabled":true}},{"id":"{c1}","name":"Cam 1","status":"Unauthorized","url":"http://10.0.0.21","mac":"AA:BB:CC:00:00:21","schedule":{"isEnabled":true}}]' } }
      return @{ code = 200; body = '[{"id":"{c1}","name":"Cam 1","status":"Unauthorized","url":"http://10.0.0.21","mac":"AA:BB:CC:00:00:21","schedule":{"isEnabled":true}}]' }
    }
    return @{ code = 404; body = '' }
  }
  $r = Invoke-NvrFix -Fix dwpassword -Ip '10.0.0.5' -Vendor DW -Credential $cred -CameraIp '10.0.0.21' -NewCredential $newCred -BackupDir $dir -Confirm { 'YES' } -WaitSec 0
  return @{ ok = [bool]$r.ok; msg = [string]$r.msg; writes = @($script:Writes) }
}
$r = InMod $dwPw @($cred, $newCred, (Join-Path $tmp 'dwpw'))
Check (-not $r.ok -and $r.msg -notmatch 'DW now says Online') 'R21 twin (DW password, certifying read): another DW camera entry with the same address says Online while Cam 1 is still Unauthorized -> NOT confirmed (2.2.19: matched by address only, ok=True)' (J $r)

# re-add: the read that certifies the channel must come from the same NVR; a lost write answer is not "refused"
$readd = {
  param($cred, $newCred, [string]$dir, [string]$mode)
  $script:owner = 'NVR1'; $script:chIp = ''; $script:Writes = @(); $script:mode = $mode
  function script:Http {
    param($Ip, $Method = 'GET', $Path, $Body, $ContentType, $Credential, $Headers, $Port, $Scheme, [switch]$NoLogBody, $Timeout, $BodyBytes, $OutFile, [switch]$SecretTransport)
    if ($Path -eq '/ISAPI/System/deviceInfo') { return @{ code = 200; body = ('<DeviceInfo><model>NVR</model><serialNumber>' + $script:owner + '</serialNumber><macAddress>' + $(if ($script:owner -eq 'NVR1') { 'AA:BB:CC:00:00:01' } else { 'AA:BB:CC:00:00:99' }) + '</macAddress></DeviceInfo>') } }
    if ($Method -eq 'PUT') {
      $script:Writes += $Path; $script:chIp = '10.0.0.31'
      if ($script:mode -eq 'swap') { $script:owner = 'NVR2'; return @{ code = 200; body = '<ResponseStatus><statusCode>1</statusCode></ResponseStatus>' } }
      return @{ code = 0; body = '' }
    }
    if ($Path -eq '/ISAPI/ContentMgmt/InputProxy/channels') { $c = $(if ($script:chIp) { '<InputProxyChannel><id>1</id><sourceInputPortDescriptor><ipAddress>' + $script:chIp + '</ipAddress></sourceInputPortDescriptor></InputProxyChannel>' } else { '' }); return @{ code = 200; body = ('<InputProxyChannelList>' + $c + '</InputProxyChannelList>') } }
    if ($Path -eq '/ISAPI/ContentMgmt/InputProxy/channels/status') { return @{ code = 200; body = '<InputProxyChannelStatusList><InputProxyChannelStatus><id>1</id><online>true</online></InputProxyChannelStatus></InputProxyChannelStatusList>' } }
    return @{ code = 404; body = '' }
  }
  $r = Invoke-NvrFix -Fix readd -Ip '10.0.0.20' -Vendor Hikvision -Credential $cred -Channel 1 -CameraIp '10.0.0.31' -NewCredential $newCred -BackupDir $dir -Confirm { 'YES' }
  return @{ ok = [bool]$r.ok; msg = [string]$r.msg; history = [string]$r.history; writes = @($script:Writes) }
}
$r = InMod $readd @($cred, $newCred, (Join-Path $tmp 'ra1'), 'swap')
Check (@($r.writes).Count -eq 1 -and -not $r.ok -and $r.msg -match 'NOT confirmed') 'R21 twin (re-add, certifying read): another NVR answers the channel read-back -> NOT confirmed (2.2.19: the other NVR''s channel certified ok=True)' (J $r)
$r = InMod $readd @($cred, $newCred, (Join-Path $tmp 'ra2'), 'lost')
Check ($r.msg -notmatch 'refused' -and $r.ok -and $r.msg -match 'read back') 'R10 twin (re-add): the write answer is LOST (code 0) -> not "refused"; the channel is read back and the camera is there (2.2.19: "The NVR refused it (answer 0)")' (J $r)

# time fix: the device is identified again before EACH of its writes; a lost answer is not "refused"
$ntp = {
  param($cred, [string]$mode)
  $script:sn = 'NVR1'; $script:Writes = @(); $script:PutCode = $(if ($mode -eq 'lost') { 0 } else { 200 }); $script:mode = $mode
  function script:Http {
    param($Ip, $Method = 'GET', $Path, $Body, $ContentType, $Credential, $Headers, $Port, $Scheme, [switch]$NoLogBody, $Timeout, $BodyBytes, $OutFile, [switch]$SecretTransport)
    if ($Path -eq '/ISAPI/System/deviceInfo') { return @{ code = 200; body = ('<DeviceInfo><model>NVR</model><serialNumber>' + $script:sn + '</serialNumber><macAddress>AA:BB:CC:00:00:0' + $(if ($script:sn -eq 'NVR1') { '1' } else { '9' }) + '</macAddress></DeviceInfo>') } }
    if ($Method -eq 'PUT') { $script:Writes += $Path; if ($script:mode -eq 'swap') { $script:sn = 'NVR2' }; return @{ code = $script:PutCode; body = $(if ($script:PutCode -eq 200) { '<ResponseStatus><statusCode>1</statusCode></ResponseStatus>' } else { '' }) } }
    if ($Path -eq '/ISAPI/System/time') { return @{ code = 200; body = '<Time><timeMode>manual</timeMode><localTime>2026-11-11T07:00:00</localTime><timeZone>CST+8:00:00</timeZone></Time>' } }
    if ($Path -like '/ISAPI/System/time/ntpServers*') { return @{ code = 200; body = '<NTPServerList><NTPServer><id>1</id><addressingFormatType>hostname</addressingFormatType><hostName>old.pool</hostName><portNo>123</portNo><synchronizeInterval>1440</synchronizeInterval></NTPServer></NTPServerList>' } }
    return @{ code = 404; body = '' }
  }
  $t = @{ ip = '10.0.0.20'; vendor = 'Hikvision'; cred = $cred; port = 0; token = $null }
  $plan = Hik-NtpPlan $t 'time.nist.gov'
  $id = Get-NhDeviceId $t
  $w = Hik-NtpApply $t 'time.nist.gov' $plan $id
  return @{ planOk = [bool]$plan.ok; needNtp = [bool]$plan.needNtp; needMode = [bool]($plan.needMode -or $plan.needTz); ok = [bool]$w.ok; why = [string]$w.why; writes = @($script:Writes) }
}
$r = InMod $ntp @($cred, 'swap')
Check ($r.planOk -and $r.needNtp -and $r.needMode -and @($r.writes).Count -eq 1 -and -not $r.ok -and $r.why -match 'STOPPED') 'R21 twin (time fix, Hikvision): another device answers after the time-server write -> the time-mode / time-zone write is NOT sent, STOPPED (2.2.19: both writes sent to whatever answered)' (J $r)
$r = InMod $ntp @($cred, 'lost')
Check (@($r.writes).Count -eq 1 -and -not $r.ok -and $r.why -notmatch 'refused') 'R10 twin (time fix): the time-server write answer is LOST -> not "refused", no further write, NOT confirmed (2.2.19: "it refused the time-server setting (HTTP 0)")' (J $r)

# ---------------- sweep: code shape ----------------
$fixSrc = [IO.File]::ReadAllText((Join-Path $tkDir 'modules/NvrHealth/NvrFix.ps1'))
Check ($fixSrc -notmatch 'BodyBytes \(\[IO\.File\]::ReadAllBytes') 'R05 (code shape): the firmware upload sends the bytes hashed after YES, never a second ReadAllBytes of the file' ''
$ncSrc = [IO.File]::ReadAllText((Join-Path $tkDir 'NvrCheck.ps1'))
Check ($ncSrc -match 'function Save-NcResult' -and -not $ncSrc.Contains("Set-Content -Path (Join-Path `$run 'result.json')")) 'class A sweep (code shape): NvrCheck saves result.json only through Save-NcResult (terminating write + read back, never exit 0 when unsaved)' ''
Deferred 'real Hikvision / Uniview / DW devices (firmware bytes, reboot answers, password read-back, storage numbers) - mock answers only'
Deferred 'Windows PowerShell 5.1 run of this suite (pwsh 7 here; the 5.1 syntax rules are kept, the lead runs the static 5.1 check)'

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host ('Test-Fix2220Nvr: ' + $script:pass + ' passed, ' + $script:fail + ' failed, ' + $script:deferred + ' deferred')
if ($script:fail) { exit 1 }
exit 0
