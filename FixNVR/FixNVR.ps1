<#
 FixNVR.ps1 - WireIt CT "Fix NVR" tool (Windows PowerShell 5.1, no installs)
 Gets an NVR (and the cameras that sit on switches) back online after the internet service changed:
   - wrong IP scheme (new router), DNS removed, platform access (Hik-Connect / EZCloud) unticked.
 Modes:
   Check    (default) read-only: find NVR + cameras on ANY IP scheme, show what is wrong and the exact plan.
   Fix      same as Check, then ONE "YES" applies the plan, verifies, and writes a rollback file.
   Snapshot install-time "known-good" record (MAC/IP/serial/channel map, no passwords) + install-standard check.
   Rollback put devices back exactly as a Fix run found them (-RollbackFile).
   Cleanup  remove any temporary PC address a crashed run left behind (also runs at every start).
   Pictures read-only: one picture of every camera on the NVR(s) for the site page (Toolkit CamViews.ps1).
            Snapshot and a finished Fix also take the pictures at the end (needs -Site; skipped with a note otherwise).
 Devices are only READ until you type YES. The PC gets a temporary extra address on the old scheme while the
 tool runs (memory-only, removed at the end, even on error; a reboot also clears it).
 Official interfaces only: Hikvision ISAPI, Hikvision SADP discovery (read), ONVIF (standard), Uniview LAPI.
 Address standard (v1.1): router DHCP .100-.254, NVR .20 (.19/.18 if taken), switch cameras .21-.99 (Dn -> .20+n),
 other WireIt gear .10-.19, DNS 8.8.8.8 / 1.1.1.1. Each address is checked free before use.
#>
param(
  [ValidateSet('Check','Fix','Snapshot','Rollback','Cleanup','Pictures')][string]$Mode = 'Check',
  [string]$Site = '',               # site name: finds/saves the snapshot in the site's Drive folder
  [string]$User = 'admin',          # device login user
  [string]$BitwardenExport = '',    # optional: unencrypted Bitwarden .json export (delete it after!)
  [string]$BitwardenItem = '',      # name of the item in that export
  [string]$CredFile = '',           # tests only: line1 user, line2 password
  [string]$Snapshot = '',           # path to a known-good snapshot json (else latest for -Site)
  [string[]]$OldSubnet = @(),       # force old scheme(s), e.g. 192.168.1  (first 3 octets)
  [string]$Nvr = '',                # NVR's current IP if you already know it
  [string]$RollbackFile = '',
  [int]$SniffSeconds = -1,          # passive listen for devices on other schemes (-1 = config)
  [switch]$NoLogin,
  [switch]$MoveUnlisted,             # also move old-scheme cameras that are NOT on an NVR's camera list (lone camera / no NVR login)                 # discovery only: list what is on the network, no logins, no plan
  [switch]$AllowUnverifiedUniview,  # let the tool write Uniview NVR network/cloud settings by LAPI (see README)
  [string]$ConfigPath = '',
  [string]$MockFile = '',           # TEST HARNESS ONLY
  [string]$ConfirmWith = '',        # TEST HARNESS ONLY (answers the YES prompt)
  [string]$RouterModel = '',        # Snapshot: router make/model typed by the tech (optional)
  [string]$DhcpRange = ''           # Snapshot: router DHCP range typed by the tech, e.g. 100-254, or "reserved" (optional)
)
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$Version = '1.2 (2026-11-02)'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ConfigPath) { $ConfigPath = Join-Path $here 'config.json' }
# 2.2.11 (Codex R14 / F16): no config.json, an empty one or one that is not valid JSON: ONE plain message and stop (after the run
# folder exists, so the Toolkit window shows the message too), before anything is looked at or changed. 2.2.10 printed a red
# Get-Content error and carried on with no settings. -Mode Cleanup still runs on built-in defaults: it only takes this tool's own
# temporary addresses off this PC, and a missing settings file must never keep the PC's network from being put back.
$cfgNeed = @('nvr_hosts', 'router_dhcp_start', 'camera_block_start', 'camera_block_end', 'temp_ip_hosts')
$cfg = $null; $cfgWhy = ''
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { $cfgWhy = 'is missing' }
else {
  $cfgText = ''; try { $cfgText = [IO.File]::ReadAllText($ConfigPath) } catch { $cfgWhy = 'could not be read' }
  if (-not $cfgWhy) {
    if (-not $cfgText.Trim()) { $cfgWhy = 'is empty' }
    else {
      try { $cfg = $cfgText | ConvertFrom-Json -ErrorAction Stop } catch { $cfg = $null; $cfgWhy = 'is damaged (not valid JSON)' }
      if (-not $cfgWhy) {
        $cfgMiss = @($cfgNeed | Where-Object { -not $cfg -or $null -eq $cfg.$_ })
        if ($cfgMiss.Count) { $cfgWhy = 'is missing settings (' + ($cfgMiss -join ', ') + ')' }
      }
    }
  }
}
if ($cfgWhy -and $Mode -eq 'Cleanup') { $cfg = [pscustomobject]@{ temp_ip_hosts = @(253, 252, 247); safety_cleanup_minutes = 30; nvr_hosts = @(20, 19, 18); router_dhcp_start = 100; camera_block_start = 21; camera_block_end = 99 } }
# 2.2.1 (review H2): certificate checks are skipped ONLY for devices on the local network (a private IPv4 address: cameras, NVRs).
# Anything with a name (the service log, Google, the download service) keeps Windows' normal certificate check. Same code in
# FixSiteDevices.ps1, NvrHealth.psm1, SiteCheck.ps1, FixNVR.ps1 and NetCheck.ps1 (it is compiled once per PowerShell).
$script:WireItLanTlsCode = @"
using System; using System.Net; using System.Net.Security; using System.Security.Cryptography.X509Certificates;
public static class WireItLanTls {
  public static bool IsLanHost(string h) {
    if (string.IsNullOrEmpty(h)) return false;
    IPAddress a; if (!IPAddress.TryParse(h.Trim('[', ']'), out a)) return false;
    if (a.AddressFamily != System.Net.Sockets.AddressFamily.InterNetwork) return false;
    byte[] b = a.GetAddressBytes();
    if (b[0] == 10 || b[0] == 127) return true;
    if (b[0] == 172 && b[1] >= 16 && b[1] <= 31) return true;
    if (b[0] == 192 && b[1] == 168) return true;
    if (b[0] == 169 && b[1] == 254) return true;
    return false;
  }
  public static bool Check(object sender, X509Certificate cert, X509Chain chain, SslPolicyErrors errors) {
    if (errors == SslPolicyErrors.None) return true;
    string host = null;
    HttpWebRequest r = sender as HttpWebRequest; if (r != null) { host = r.RequestUri.Host; } else { string s = sender as string; if (s != null) host = s; }
    return IsLanHost(host);
  }
  public static readonly RemoteCertificateValidationCallback Callback = new RemoteCertificateValidationCallback(Check);
  public static void Install() { ServicePointManager.ServerCertificateValidationCallback = Callback; }
}
"@
# 2.2.2 (Codex): -IgnoreWarnings - PowerShell 7.5 (.NET 9) turned the SYSLIB0014 'ServicePointManager is obsolete' warning into a failed compile
# 2.2.2 (Codex H2): the same private-IPv4 test in plain PowerShell, for PowerShell 7's per-call certificate skip and curl's -k
function Test-WireItLanHost([string]$h) {
  if (-not $h) { return $false }; $a = $null; if (-not [Net.IPAddress]::TryParse($h.Trim('[', ']'), [ref]$a)) { return $false }
  if ($a.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { return $false }
  $b = $a.GetAddressBytes()
  return ($b[0] -eq 10 -or $b[0] -eq 127 -or ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) -or ($b[0] -eq 192 -and $b[1] -eq 168) -or ($b[0] -eq 169 -and $b[1] -eq 254))
}
function Enable-WireItLanTls { try { if (-not ('WireItLanTls' -as [type])) { Add-Type -TypeDefinition $script:WireItLanTlsCode -IgnoreWarnings -WarningAction SilentlyContinue -ErrorAction Stop }; [WireItLanTls]::Install(); return $true } catch { return $false } }
$IsPs5 = $PSVersionTable.PSVersion.Major -lt 6
if ($IsPs5) {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls   # 2.2.2 (re-review): old camera/NVR firmware that only speaks TLS 1.0/1.1 stays on HTTPS
  [void](Enable-WireItLanTls)   # 2.2.1 (review H2): devices on private addresses only
  [Net.ServicePointManager]::Expect100Continue = $false
}
$Mock = $null
if ($MockFile) { $Mock = Get-Content $MockFile -Raw | ConvertFrom-Json }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$stateDir = Join-Path $here 'state'; New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
$runDir = Join-Path (Join-Path $here 'runs') ($Mode + '-' + $stamp); New-Item -ItemType Directory -Force -Path $runDir | Out-Null
$logFile = Join-Path $runDir 'log.txt'
$sum = New-Object System.Collections.Generic.List[string]
function Redact([string]$s) {
  if (-not $s) { return $s }
  $s = [regex]::Replace($s, '(?is)<password[^>]*>.*?</password>', '<password>***</password>')
  $s = [regex]::Replace($s, '(?i)"(password|passwd|pwd)"\s*:\s*"[^"]*"', '"$1":"***"')
  $s = [regex]::Replace($s, '(?is)<(wsse:)?Password[^>]*>.*?</(wsse:)?Password>', '<Password>***</Password>')
  $s = [regex]::Replace($s, '(?is)<verificationCode>.*?</verificationCode>', '<verificationCode>***</verificationCode>')
  return $s
}
function Log([string]$s) { Add-Content -Path $logFile -Value ((Get-Date -Format 'HH:mm:ss') + ' ' + (Redact $s)) }
function Say([string]$s, [string]$color = '') { if ($color) { Write-Host $s -ForegroundColor $color } else { Write-Host $s }; $sum.Add($s); Log ('SAY ' + $s) }
if ($cfgWhy -and $Mode -ne 'Cleanup') {   # 2.2.11 (Codex R14 / F16)
  Say ('Fix NVR cannot start: its settings file config.json ' + $cfgWhy + ' (' + $ConfigPath + ').') 'Yellow'
  Say 'Nothing was checked or changed. Run the Toolkit installer again (it puts config.json back), then run this again.'
  try { Set-Content -LiteralPath (Join-Path $runDir 'summary.txt') -Value ($sum -join "`r`n") } catch {}
  exit 2
}
# 2.2.7 (Codex file-by-file F04): written to a temporary file and swapped in whole; a write that fails THROWS (2.2.6 wrote with
# Set-Content under 'Continue': a failed rollback save was only a warning and the run went on changing devices)
# 2.2.20 (Codex 2.2.19 class A sweep): a save counts only when the FINAL file reads back: it exists, it is the exact text written and
# it parses. Anything else THROWS, so every caller stops before the change the record protects.
function Save-Json($obj, [string]$path) {
  $tmp = $path + '.' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.tmp'
  $json = ($obj | ConvertTo-Json -Depth 12)
  try {
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($true)))
    if ([IO.File]::Exists($path)) { [IO.File]::Replace($tmp, $path, [NullString]::Value) } else { [IO.File]::Move($tmp, $path) }
  } finally { if ([IO.File]::Exists($tmp)) { try { [IO.File]::Delete($tmp) } catch {} } }
  if (-not [IO.File]::Exists($path)) { throw ('the saved file ' + $path + ' is not there after the save') }
  $back = [IO.File]::ReadAllText($path)
  if ($back.Length -gt 0 -and [int][char]$back[0] -eq 0xFEFF) { $back = $back.Substring(1) }
  if ($back -cne $json) { throw ('the saved file ' + $path + ' does not read back as written') }
  try { [void]($back | ConvertFrom-Json -ErrorAction Stop) } catch { throw ('the saved file ' + $path + ' does not read back as JSON') }
}
# 2.2.7 (F05): Undo takes back every step that was SENT (done, or sent and not confirmed: a timeout, a stopped run), newest first
function Get-FnRollbackSteps($rb) {
  $tmp = @($rb.steps | Where-Object { $_ -and ($_.done -or ($_.PSObject.Properties['attempted'] -and $_.attempted)) -and $_.type -ne 'nvr-platform' })
  [array]::Reverse($tmp); return $tmp
}
# 2.2.20 (Codex 2.2.19 class E sweep): '' = the undo file has the structure and the field types the Fix run writes; else why not
function Get-FnRollbackWhy($rb) {
  if (-not ($rb -is [pscustomobject])) { return 'is damaged (not an undo file this tool writes)' }
  if (-not $rb.PSObject.Properties['steps'] -or -not ($rb.steps -is [array])) { return 'is damaged (it has no list of steps)' }
  $i = 0
  foreach ($st in @($rb.steps)) {
    $i++; $w = 'is damaged (step ' + $i
    if (-not ($st -is [pscustomobject])) { return ($w + ' is not a step)') }
    $nm = @($st.PSObject.Properties | ForEach-Object { $_.Name })
    foreach ($k in 'type', 'how', 'done') { if ($nm -notcontains $k) { return ($w + ' has no "' + $k + '")') } }
    if (-not ($st.type -is [string]) -or [string]$st.type -notmatch '^(cam-net|nvr-net|nvr-channel|nvr-platform)$') { return ($w + ' has an unknown kind "' + [string]$st.type + '")') }
    if (-not ($st.how -is [string]) -or [string]$st.how -notmatch '^(isapi|onvif|lapi|manual)$') { return ($w + ' has an unknown method "' + [string]$st.how + '")') }
    if (-not ($st.done -is [bool])) { return ($w + ': "done" is not true/false)') }
    if ($nm -contains 'attempted' -and -not ($st.attempted -is [bool])) { return ($w + ': "attempted" is not true/false)') }
    foreach ($k in 'dev_mac', 'dev_serial', 'cam_mac', 'cam_serial', 'brand', 'old_addressing', 'old_mask', 'old_gw', 'old_dns1', 'old_dns2', 'nvr_ip') { if ($nm -contains $k -and $null -ne $st.$k -and -not ($st.$k -is [string])) { return ($w + ': "' + $k + '" is not text)') } }
    if (-not [string]$st.dev_mac -and -not [string]$st.dev_serial) { return ($w + ' does not say which device it changed)') }
    if ([string]$st.type -ne 'nvr-platform') {
      foreach ($k in 'old_ip', 'new_ip') { if ($nm -notcontains $k -or -not (Test-FnIpv4 $st.$k)) { return ($w + ': "' + $k + '" is not an address)') } }
    }
    if ([string]$st.type -match '^(cam|nvr)-net$') {
      foreach ($k in 'old_mask', 'old_gw', 'old_dns1', 'old_dns2', 'old_addressing') { if ($nm -notcontains $k) { return ($w + ' has no "' + $k + '")') } }
      if ([string]$st.old_mask -and -not (Test-FnMask $st.old_mask)) { return ($w + ': its old mask "' + [string]$st.old_mask + '" is not a mask)') }
      foreach ($k in 'old_gw', 'old_dns1', 'old_dns2') { if ([string]$st.$k -and [string]$st.$k -ne '0.0.0.0' -and -not (Test-FnIpv4 $st.$k)) { return ($w + ': "' + $k + '" is not an address)') } }
      if ([string]$st.old_addressing -and -not (Get-FnAddrMode $st.old_addressing)) { return ($w + ': its old addressing "' + [string]$st.old_addressing + '" is not one the tool knows)') }
    }
    if ([string]$st.type -eq 'nvr-channel' -and ($nm -notcontains 'channel' -or [string]$st.channel -notmatch '^\d+$')) { return ($w + ': its channel number is not readable)') }
  }
  return ''
}
# 2.2.7 (F05): an NVR channel is not pointed at a camera's new address when that camera's move failed
function Test-FnSkipDependent($st, [hashtable]$failedTo) { return ([string]$st.type -eq 'nvr-channel' -and $failedTo.ContainsKey([string]$st.new_ip)) }

# ---------------- IP helpers ----------------
function IpToInt([string]$ip) { $b = ([Net.IPAddress]::Parse($ip)).GetAddressBytes(); return ([uint32]$b[0] -shl 24) -bor ([uint32]$b[1] -shl 16) -bor ([uint32]$b[2] -shl 8) -bor [uint32]$b[3] }
function MaskToPrefix([string]$m) { if (-not $m) { return 24 }; $n = IpToInt $m; $c = 0; for ($i = 31; $i -ge 0; $i--) { if ($n -band ([uint32]1 -shl $i)) { $c++ } else { break } }; return $c }
function PrefixToMask([int]$p) { $n = [uint32]0; for ($i = 0; $i -lt $p; $i++) { $n = $n -bor ([uint32]1 -shl (31 - $i)) }; return (([math]::Floor($n / 16777216)) % 256).ToString() + '.' + (([math]::Floor($n / 65536)) % 256) + '.' + (([math]::Floor($n / 256)) % 256) + '.' + ($n % 256) }
function InNet([string]$ip, [string]$netIp, [int]$prefix) {
  if (-not $ip -or -not $netIp) { return $false }
  try { $m = [uint32]0; for ($i = 0; $i -lt $prefix; $i++) { $m = $m -bor ([uint32]1 -shl (31 - $i)) }; return ((IpToInt $ip) -band $m) -eq ((IpToInt $netIp) -band $m) } catch { return $false }
}
function P3([string]$ip) { if (-not $ip) { return '' }; return (($ip -split '\.')[0..2] -join '.') }
function Last([string]$ip) { return [int](($ip -split '\.')[3]) }
function NormMac([string]$m) { if (-not $m) { return '' }; $h = ($m -replace '[^0-9A-Fa-f]', '').ToUpper(); if ($h.Length -ne 12) { return $m.ToUpper() }; return (($h -split '(..)' | Where-Object { $_ }) -join '-') }
$oui = @{ 'DC-07-F8'='Hikvision'; '28-57-BE'='Hikvision'; '44-19-B6'='Hikvision'; '4C-BD-8F'='Hikvision'; '54-C4-15'='Hikvision'; '58-03-FB'='Hikvision'; 'BC-AD-28'='Hikvision'; 'C0-56-E3'='Hikvision'; 'C4-2F-90'='Hikvision'; 'E0-50-8B'='Hikvision'; '18-68-CB'='Hikvision'; '24-48-45'='Hikvision'; '80-BE-AF'='Hikvision'; 'A4-14-37'='Hikvision'; '8C-E7-48'='Hikvision'; '94-E1-AC'='Hikvision'; 'BC-BA-C2'='Hikvision'; '64-DB-8B'='Hikvision'; '98-DF-82'='Hikvision'; 'E0-CA-3C'='Hikvision'; '08-A1-89'='Hikvision'; '24-0F-9B'='Hikvision'; '2C-A5-9C'='Hikvision'; '40-AC-BF'='Hikvision'; '44-47-CC'='Hikvision'; '4C-F5-DC'='Hikvision'; '68-6D-BC'='Hikvision'; '84-94-37'='Hikvision'; 'AC-B9-2F'='Hikvision'; 'B4-A3-82'='Hikvision'; 'C8-A7-02'='Hikvision'; '48-EA-63'='Uniview'; '6C-F1-7E'='Uniview'; '1C-6A-1B'='Ubiquiti'; '24-5A-4C'='Ubiquiti'; '74-83-C2'='Ubiquiti'; '78-8A-20'='Ubiquiti'; 'B4-FB-E4'='Ubiquiti'; 'F0-9F-C2'='Ubiquiti'; 'FC-EC-DA'='Ubiquiti' }
# 2.2.19 (Codex 2.2.18 F10, class D): one meaning for an addressing mode, whatever the device or the record calls it. Hikvision ISAPI
# says "dynamic" for DHCP, SADP / older records say "dhcp", ONVIF says <DHCP>true</DHCP>. Returns 'dhcp', 'static', or '' when the
# value is missing or not one the tool knows (unknown is NEVER taken as static or as DHCP).
function Get-FnAddrMode($v) {
  if ($null -eq $v) { return '' }
  if ($v -is [bool]) { if ($v) { return 'dhcp' } else { return 'static' } }
  $s = ([string]$v).Trim().ToLowerInvariant()
  if ($s -in @('dhcp', 'dynamic', 'auto', 'automatic', 'dhcpv4')) { return 'dhcp' }
  if ($s -in @('static', 'manual', 'fixed', 'staticip', 'static ip')) { return 'static' }
  return ''
}
# 2.2.19 (Codex 2.2.18 F11, class D): an empty DNS server is a real setting. "0.0.0.0" is how some devices write "none".
function NormDns([string]$v) { $s = ([string]$v).Trim(); if ($s -eq '0.0.0.0') { return '' }; return $s }
function Vendor([string]$mac) { $mac = NormMac $mac; if ($mac.Length -lt 8) { return '' }; $p = $mac.Substring(0, 8); if ($oui.ContainsKey($p)) { return $oui[$p] }; return '' }

# ---------------- this PC ----------------
function Get-PcNet {
  if ($Mock) { return $Mock.pc }
  $r = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4 -ErrorAction SilentlyContinue | Sort-Object { $_.RouteMetric + $_.InterfaceMetric } |
       Where-Object { (Get-NetAdapter -InterfaceIndex $_.ifIndex -ErrorAction SilentlyContinue).Status -eq 'Up' -and (Get-NetAdapter -InterfaceIndex $_.ifIndex).InterfaceDescription -notmatch 'Tailscale|WireGuard|TAP|VPN|Cellular|Mobile Broadband|Hyper-V' } | Select-Object -First 1
  if (-not $r) { return $null }
  $a = Get-NetIPAddress -InterfaceIndex $r.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike '169.254*' -and -not $_.SkipAsSource } | Select-Object -First 1
  $nic = Get-NetAdapter -InterfaceIndex $r.ifIndex
  $ipi = Get-NetIPInterface -InterfaceIndex $r.ifIndex -AddressFamily IPv4
  return [pscustomobject]@{ ifIndex = $r.ifIndex; alias = $nic.Name; guid = [string]$nic.InterfaceGuid; desc = $nic.InterfaceDescription; ip = $a.IPAddress; prefix = [int]$a.PrefixLength; gw = $r.NextHop; dhcp = ($ipi.Dhcp -eq 'Enabled'); link = $nic.LinkSpeed; wifi = ($nic.PhysicalMediaType -match '802.11' -or $nic.InterfaceDescription -match 'Wi-?Fi|Wireless') }
}

# ---------------- temporary PC address on an old scheme (always removed) ----------------
$tempFile = Join-Path $stateDir 'temp-ips.json'
$script:temps = New-Object System.Collections.Generic.List[object]
$script:pcChanges = [ordered]@{ coexistence_before = $null; firewall_rule = $false; cleanup_task = $false; ifIndex = $null; alias = $null; guid = $null; dhcp = $null; ip = $null; gw = $null }
$taskName = 'WireIt FixNVR cleanup'
# 2.2.10 (Codex R04): the journal is a precondition. Write-TempState returns $false when it could not be saved, and no adapter
# change happens without it. Each entry stays until a fresh read shows the address gone; DHCP + coexistence go back from the
# saved before-state on the SAVED adapter; the journal and the safety task are deleted only when all of that checked back.
# A clean-up that is not verified says "FAILED - Run again" (screen + log). NEEDS WINDOWS CHECK (New/Remove-NetIPAddress, netsh).
function Write-TempState { try { Save-Json ([ordered]@{ version = 2; temps = $script:temps.ToArray(); pc = $script:pcChanges; written = (Get-Date -Format 's') }) $tempFile; return $true } catch { Log ('temp state not saved: ' + $_.Exception.Message); return $false } }
function Set-SafetyTask {
  if ($Mock -or $script:pcChanges.cleanup_task) { return }
  try {
    $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Mode Cleanup')
    $trg = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes([int]$cfg.safety_cleanup_minutes)
    $pr = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest -LogonType ServiceAccount
    Register-ScheduledTask -TaskName $taskName -Action $act -Trigger $trg -Principal $pr -Force -ErrorAction Stop | Out-Null   # 2.2.19 (class F): set only when Windows took it
    $script:pcChanges.cleanup_task = $true; Log ('safety cleanup task set for +' + $cfg.safety_cleanup_minutes + ' min')
    # 2.2.19 (class F): the record of the task must be saved too. A failed save is said, not ignored. The task is KEPT: it is the
    # safety net that removes the temporary address if this run stops, and the clean-up removes it by its name in any case.
    if (-not (Write-TempState)) { Log 'safety cleanup task set, but the clean-up record could not be updated to say so'; Say 'Note: the safety clean-up task is set, but the clean-up record on this PC could not be updated. If this window closes early, run "Fix NVR.cmd" again so it can clean up.' 'Yellow' }
  } catch { Log ('safety task not set: ' + $_.Exception.Message) }
}
# 2.2.19 (Codex 2.2.18 F08 twin, class C): "gone" only from a query that worked. Windows answers "No matching MSFT_NetIPAddress
# objects" for an address that is not there (= gone); any other failure of the query is NOT proof, so the address stays journaled.
function Test-TempGone([string]$ip, $ifIndex) {
  try { return (-not @(Get-NetIPAddress -IPAddress $ip -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_ }).Count) }
  catch {
    $cat = ''; try { $cat = [string]$_.CategoryInfo.Category } catch {}
    if ($cat -eq 'ObjectNotFound' -or [string]$_.Exception.Message -match '(?i)No matching MSFT_NetIPAddress') { return $true }
    Log ('could not check whether temp ip ' + $ip + ' is gone: ' + $_.Exception.Message); return $false
  }
}
# 2.2.20 (Codex 2.2.19 R02, class B): ONE gate for every change this run makes on a network adapter (adding or removing a temporary
# address, the DHCP+static coexistence setting, DHCP) and for every read that certifies one: right before it, the adapter at the
# number is read again and must positively be the one this run saved (its name AND its InterfaceGuid, both as saved). A different
# adapter, an unreadable one, or a record without both = '' is NOT returned and nothing is changed (Moshe's decision: unreadable =
# refuse). 2.2.19 checked the identity only in the final restore, after the addresses had already been added and removed by number.
function Get-FnRunAdapterWhy($ifIndex) {
  if ($null -eq $script:pcChanges.ifIndex) { return 'the record does not say which network adapter this run uses' }
  if ([string]$ifIndex -ne [string]$script:pcChanges.ifIndex) { return ('network adapter number ' + $ifIndex + ' is not the one this run recorded (number ' + $script:pcChanges.ifIndex + ')') }
  if (-not [string]$script:pcChanges.alias -or -not [string]$script:pcChanges.guid) { return 'the record does not have both the name and the ID of the network adapter this run uses' }
  return (Get-FnAdapterIdWhy ([pscustomobject]@{ alias = [string]$script:pcChanges.alias; guid = [string]$script:pcChanges.guid }) $ifIndex)
}
# 2.2.20 (R02): the adapter a JOURNAL from disk names, checked the same way for each change (never cached across addresses)
function Get-FnRecordAdapterWhy($pcc, $ifIndex) {
  if ($null -eq $ifIndex -or [string]$ifIndex -ne [string]$pcc.ifIndex) { return ('the record does not say which adapter number ' + $ifIndex + ' was') }
  return (Get-FnAdapterIdWhy $pcc $ifIndex)
}
# 2.2.20 (R02): a refused first change leaves no "this run changed the adapter" record behind when nothing was changed on it
function Reset-FnUnusedAdapterRecord {
  if ($script:temps.Count -or $null -ne $script:pcChanges.coexistence_before) { return }
  foreach ($k in 'ifIndex', 'alias', 'guid', 'dhcp', 'ip', 'gw') { $script:pcChanges[$k] = $null }
  [void](Write-TempState)
}
function Add-TempIp([string]$p3, $pc, $avoid) {
  if ($script:coexNotConfirmed) { return $null }   # 2.2.19: once the DHCP+static setting did not take, no temporary address this run
  foreach ($h in $cfg.temp_ip_hosts) {
    $ip = $p3 + '.' + $h
    if ($avoid -contains $ip) { continue }
    if ($Mock) { $script:temps.Add([pscustomobject]@{ ip = $ip; ifIndex = $pc.ifIndex }); Log ('MOCK temp ip ' + $ip); return $ip }
    if ($null -eq $script:pcChanges.ifIndex) {
      # 2.2.20 (R02): the identity saved is the adapter's name AND its InterfaceGuid; without both nothing is changed (unreadable = refuse)
      if (-not [string]$pc.alias -or -not [string]$pc.guid) { Log 'temp ip refused: the adapter name or ID could not be read'; Say 'Old scheme: no temporary address was added. Windows did not give both the name and the ID of this PC''s network adapter, so the tool could not check it changes the right one. Nothing on this PC was changed.' 'Yellow'; return $null }
      $script:pcChanges.ifIndex = [int]$pc.ifIndex; $script:pcChanges.alias = [string]$pc.alias; $script:pcChanges.guid = [string]$pc.guid; $script:pcChanges.dhcp = [bool]$pc.dhcp; $script:pcChanges.ip = [string]$pc.ip; $script:pcChanges.gw = [string]$pc.gw
    }
    $aw0 = Get-FnRunAdapterWhy $pc.ifIndex
    if ($aw0) { Log ('temp ip refused: ' + $aw0); Reset-FnUnusedAdapterRecord; Say ('Old scheme: no temporary address was added: ' + $aw0 + '. Nothing more on this PC was changed.') 'Yellow'; return $null }
    if ($script:pcChanges.coexistence_before -eq $null -and $pc.dhcp) {
      $t = (netsh interface ipv4 show interface ([string]$pc.ifIndex)) -join "`n"
      $m = [regex]::Match($t, '(?i)DHCP/Static IP coexistence\s*:\s*(\w+)')
      # 2.2.12 (Codex P1-9): an answer the tool cannot read now stops here, before anything changes. Clean-up must read the
      # setting back to call it restored, so a PC whose netsh answer cannot be read would otherwise be left "not restored" for good.
      if (-not $m.Success) { Log ('coexistence not readable from netsh: ' + $t); Say 'Old scheme: no temporary address was added. Windows did not say how this PC''s DHCP setting is set (netsh gave an answer the tool cannot read), so the tool could not put it back afterwards. Nothing on this PC was changed.' 'Yellow'; return $null }
      $script:pcChanges.coexistence_before = $m.Groups[1].Value
      # the before-state is on disk BEFORE coexistence is switched on (2.2.9 switched first)
      if (-not (Write-TempState)) { $script:pcChanges.coexistence_before = $null; Say 'FAILED - Run again. The record of this PC''s network could not be saved, so no temporary address was added (nothing on this PC was changed).' 'Red'; return $null }
      if ($script:pcChanges.coexistence_before -notmatch 'enabled') {
        $aw1 = Get-FnRunAdapterWhy $pc.ifIndex   # 2.2.20 (R02): fresh, right before this change
        if ($aw1) { Log ('coexistence change refused: ' + $aw1); $script:pcChanges.coexistence_before = $null; Reset-FnUnusedAdapterRecord; Say ('Old scheme: no temporary address was added: ' + $aw1 + '. Nothing more on this PC was changed.') 'Yellow'; return $null }
        netsh interface ipv4 set interface ([string]$pc.ifIndex) dhcpstaticipcoexistence=enabled | Out-Null
        # 2.2.19 (class F): the setting is read back before a temporary address is added. Without it, Windows can turn this PC's DHCP
        # off when the address is added, so a setting that did not take = no temporary address (the before-state is already on disk).
        $t2 = ''; try { $t2 = (netsh interface ipv4 show interface ([string]$pc.ifIndex)) -join "`n" } catch { $t2 = '' }
        $m2 = [regex]::Match($t2, '(?i)DHCP/Static IP coexistence\s*:\s*(\w+)')
        if (-not $m2.Success -or $m2.Groups[1].Value -notmatch '(?i)enabled') { Log ('coexistence did not read back as enabled: ' + $t2); $script:coexNotConfirmed = $true; Say 'Old scheme: no temporary address was added. Windows did not confirm the DHCP+static setting the tool needs, so adding an address could have turned this PC''s DHCP off. Old-scheme devices will be listed as not reached.' 'Yellow'; return $null }
      }
    }
    $script:temps.Add([pscustomobject]@{ ip = $ip; ifIndex = $pc.ifIndex })
    if (-not (Write-TempState)) { [void]$script:temps.RemoveAt($script:temps.Count - 1); Say 'FAILED - Run again. The record of this PC''s network could not be saved, so no temporary address was added.' 'Red'; return $null }
    Set-SafetyTask
    $aw2 = Get-FnRunAdapterWhy $pc.ifIndex   # 2.2.20 (R02): fresh, right before the address is added
    if ($aw2) { Log ('temp ip ' + $ip + ' refused: ' + $aw2); [void]$script:temps.RemoveAt($script:temps.Count - 1); [void](Write-TempState); Reset-FnUnusedAdapterRecord; Say ('Old scheme: no temporary address was added: ' + $aw2 + '. Nothing more on this PC was changed (run "Fix NVR.cmd" again so it can clean up if this PC was changed before).') 'Yellow'; return $null }
    try {
      New-NetIPAddress -InterfaceIndex $pc.ifIndex -IPAddress $ip -PrefixLength 24 -SkipAsSource $true -PolicyStore ActiveStore -ErrorAction Stop | Out-Null
    } catch { Log ('add ' + $ip + ' failed: ' + $_.Exception.Message); if (-not (Remove-OneTemp $ip $pc.ifIndex)) { return $null }; continue }
    $st = 'Tentative'
    for ($w = 0; $w -lt 8 -and $st -eq 'Tentative'; $w++) { Start-Sleep -Seconds 1; $st = (Get-NetIPAddress -InterfaceIndex $pc.ifIndex -IPAddress $ip -ErrorAction SilentlyContinue).AddressState }
    if ($st -eq 'Duplicate') { Log ($ip + ' is used by another device, trying the next'); if (-not (Remove-OneTemp $ip $pc.ifIndex)) { return $null }; continue }
    Log ('temp ip ' + $ip + ' added (' + $st + ')'); return $ip
  }
  return $null
}
# returns $true only when the address is checked gone; otherwise it stays tracked and journaled
function Remove-OneTemp([string]$ip, $ifIndex) {
  if (-not $Mock) {
    # 2.2.20 (R02): removed only from the adapter this run saved, checked right before the removal and again before "gone" is believed
    $aw = Get-FnRunAdapterWhy $ifIndex
    if ($aw) { Log ('temp ip ' + $ip + ' NOT removed: ' + $aw + ' (kept in the journal)'); [void](Write-TempState); return $false }
    Remove-NetIPAddress -IPAddress $ip -InterfaceIndex $ifIndex -PolicyStore ActiveStore -Confirm:$false -ErrorAction SilentlyContinue
    if (-not (Test-TempGone $ip $ifIndex)) { Log ('temp ip ' + $ip + ' is still on the adapter (kept in the journal)'); [void](Write-TempState); return $false }
    $aw = Get-FnRunAdapterWhy $ifIndex
    if ($aw) { Log ('temp ip ' + $ip + ' reads gone, but ' + $aw + ' (kept in the journal)'); [void](Write-TempState); return $false }
  }
  $x = @($script:temps | Where-Object { $_.ip -eq $ip }); foreach ($e in $x) { [void]$script:temps.Remove($e) }
  if (-not $Mock) { [void](Write-TempState) }
  return $true
}
# 2.2.19 (Codex 2.2.18 F05, class A; Moshe's decision: an unreadable adapter identity = REFUSE). '' = the adapter at this number is
# positively the one the record saved: its InterfaceGuid (when the record has one) AND its name (when the record has one) read back
# the same. A failed read, an empty answer, or a record with neither saved is NOT a match: nothing is changed and the record stays.
function Get-FnAdapterIdWhy($pcc, $ifIndex) {
  $sg = ''; if ($pcc.PSObject.Properties['guid'] -and $pcc.guid) { $sg = ([string]$pcc.guid).Trim('{}').ToLowerInvariant() }
  $sn = ''; if ($pcc.PSObject.Properties['alias'] -and $pcc.alias) { $sn = [string]$pcc.alias }
  if (-not $sg -and -not $sn) { return ('the record does not say which network adapter number ' + $ifIndex + ' was (no adapter name or ID saved)') }
  $a = $null; try { $a = Get-NetAdapter -InterfaceIndex $ifIndex -ErrorAction Stop | Select-Object -First 1 } catch { Log ('adapter identity not readable for ifIndex ' + $ifIndex + ': ' + $_.Exception.Message); $a = $null }
  if (-not $a) { return ('Windows could not say which network adapter has number ' + $ifIndex + ' now, so the tool cannot check it is "' + $(if ($sn) { $sn } else { $sg }) + '" as recorded') }
  if ($sg) {
    $ng = ([string]$a.InterfaceGuid).Trim('{}').ToLowerInvariant()
    if (-not $ng) { return ('Windows did not give the ID of network adapter number ' + $ifIndex + ', so the tool cannot check it is the recorded one') }
    if ($ng -ne $sg) { return ('the network adapter number ' + $ifIndex + ' is now a different adapter ("' + [string]$a.Name + '", another ID) than the one recorded') }
  }
  if ($sn) {
    $nn = [string]$a.Name
    if (-not $nn) { return ('Windows did not give the name of network adapter number ' + $ifIndex + ', so the tool cannot check it is "' + $sn + '" as recorded') }
    if ($nn -ne $sn) { return ('the network adapter number ' + $ifIndex + ' is now "' + $nn + '", not "' + $sn + '" as recorded') }
  }
  if (-not $sg) { Log ('adapter ' + $ifIndex + ' checked by name only ("' + $sn + '"): this record has no adapter ID saved') }
  return ''
}
function Restore-PcSettings($pcc, $ifIndex, [ref]$problems) {
  if ($null -eq $ifIndex) { return }
  # 2.2.19 (Codex 2.2.18 F05): before ANY change on the saved adapter number (and before a journal can be closed as "back to normal"),
  # the adapter there must be positively the saved one. 2.2.18 went ahead when the name could not be read.
  # 2.2.20 (Codex 2.2.19 R08, class E): the saved values are used only with the types this tool writes. A DHCP value that is not a
  # real true/false (for example the text "false", which PowerShell takes as TRUE) or a coexistence value outside the known words
  # = nothing is changed and the record is kept (2.2.19 would have switched DHCP ON for "false").
  if ($null -ne $pcc.dhcp -and -not ($pcc.dhcp -is [bool])) { $problems.Value += 'the record''s DHCP value is damaged (not true/false), so this PC''s settings were NOT put back automatically (the record is kept)'; return }
  if ($null -ne $pcc.coexistence_before -and -not (Test-FnCoexWord $pcc.coexistence_before)) { $problems.Value += 'the record''s DHCP+static coexistence value is damaged, so this PC''s settings were NOT put back automatically (the record is kept)'; return }
  $wasDhcp = ($pcc.dhcp -eq $true)
  $touched0 = $true; if ($pcc.PSObject.Properties['changed'] -and -not $pcc.changed) { $touched0 = $false }
  $coNeed = ($pcc.coexistence_before -ne $null -and [string]$pcc.coexistence_before -notmatch 'enabled')
  $dhcpNeed = $false
  if ($wasDhcp) { $ipi0 = Get-NetIPInterface -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue; $dhcpNeed = (-not $ipi0 -or $ipi0.Dhcp -ne 'Enabled') }
  if ($touched0 -or $coNeed -or $dhcpNeed) {
    $aw = Get-FnAdapterIdWhy $pcc $ifIndex
    if ($aw) { $problems.Value += ($aw + ', so its settings were NOT put back automatically (the record is kept)'); return }
  }
  if ($pcc.coexistence_before -ne $null -and [string]$pcc.coexistence_before -notmatch 'enabled') {
    $aw = Get-FnAdapterIdWhy $pcc $ifIndex   # 2.2.20 (R02): fresh, right before this change
    if ($aw) { $problems.Value += ($aw + ', so its settings were NOT put back automatically (the record is kept)'); return }
    netsh interface ipv4 set interface ([string]$ifIndex) dhcpstaticipcoexistence=disabled | Out-Null
    $co = ((netsh interface ipv4 show interface ([string]$ifIndex)) -join "`n"); $m = [regex]::Match($co, '(?i)DHCP/Static IP coexistence\s*:\s*(\w+)')
    # 2.2.12 (Codex P1-9): an answer that cannot be read is NOT "restored" (2.2.11 logged "coexistence restored" for it)
    if (-not $m.Success) { Log ('coexistence read-back not understood: ' + $co); $problems.Value += 'the DHCP+static coexistence setting could not be read back (Windows gave an answer the tool does not understand)' }
    elseif ($m.Groups[1].Value -match 'enabled') { $problems.Value += 'the DHCP+static coexistence setting could not be put back' } else { Log 'coexistence restored (read back)' }
  }
  if ($wasDhcp) {
    $ipi = Get-NetIPInterface -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    if ($ipi -and $ipi.Dhcp -ne 'Enabled') { $aw = Get-FnAdapterIdWhy $pcc $ifIndex; if ($aw) { $problems.Value += ($aw + ', so DHCP was NOT put back automatically (the record is kept)'); return } }   # 2.2.20 (R02)
    if ($ipi -and $ipi.Dhcp -ne 'Enabled') { try { Set-NetIPInterface -InterfaceIndex $ifIndex -AddressFamily IPv4 -Dhcp Enabled -ErrorAction Stop; Log 'DHCP re-enabled on PC NIC' } catch {} }
    $ipi = Get-NetIPInterface -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    if (-not $ipi -or $ipi.Dhcp -ne 'Enabled') { $problems.Value += 'DHCP is not back on' }
  }
  # 2.2.12 (Codex P1-9): back to normal = a WORKING connection on the saved adapter, the way FixSite checks it: a usable address
  # (not 169.254, not one of this tool's temporary ones) and a default route; for a fixed-address PC its own saved address and
  # router. Windows gets time to renew the lease. Until this checks, the journal (and the safety clean-up) stay.
  $touched = $true; if ($pcc.PSObject.Properties['changed'] -and -not $pcc.changed) { $touched = $false }   # a journal from disk always counts as touched
  if ($touched -and -not $problems.Value.Count) { $why = Wait-PcRecovered $pcc $ifIndex; if ($why) { $problems.Value += $why } }
  # 2.2.20 (R02): a "back to normal" read counts only when it was read from the saved adapter: its identity is checked again after it
  if ($touched -and -not $problems.Value.Count) { $aw = Get-FnAdapterIdWhy $pcc $ifIndex; if ($aw) { $problems.Value += ($aw + ', so the tool cannot say this PC''s network is back (the record is kept)') } }
}
# 2.2.20 (R08): the words netsh gives for the DHCP+static coexistence setting (the only values this tool saves)
function Test-FnCoexWord($v) { return (($v -is [string]) -and ([string]$v -match '^(?i)(enabled|disabled)$')) }
function Get-PcRecoveredWhy($pcc, $ifIndex) {
  # this tool's temporary addresses are SkipAsSource, so they never count as the PC's own address
  $addrs = @(Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_ -and [string]$_.IPAddress -and [string]$_.IPAddress -notlike '169.254.*' -and [string]$_.IPAddress -notlike '127.*' -and -not $_.SkipAsSource -and ([string]$_.AddressState -eq '' -or [string]$_.AddressState -eq 'Preferred') } | ForEach-Object { [string]$_.IPAddress })
  $routes = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_ -and [string]$_.NextHop -and [string]$_.NextHop -ne '0.0.0.0' } | ForEach-Object { [string]$_.NextHop })
  $name = $(if ($pcc.alias) { '"' + $pcc.alias + '"' } else { 'the network adapter' })
  if (-not $pcc.dhcp -and $pcc.ip) {
    if ($addrs -notcontains [string]$pcc.ip) { return ('this PC''s own fixed address ' + $pcc.ip + ' is not working on ' + $name + ' (check the cable / Wi-Fi)') }
    if ($pcc.gw -and $routes -notcontains [string]$pcc.gw) { return ('this PC has no route to its router ' + $pcc.gw + ' on ' + $name + ' (check the cable / Wi-Fi)') }
    return ''
  }
  if (-not $addrs.Count) { return ('this PC has no working address from the router on ' + $name + ' (no lease yet; check the cable / Wi-Fi)') }
  if (-not $routes.Count) { return ('this PC has an address but no route to the router (no default gateway) on ' + $name) }
  return ''
}
function Wait-PcRecovered($pcc, $ifIndex) {
  $tries = $(if ($null -ne $script:FnRecoverTries) { [int]$script:FnRecoverTries } else { 10 })
  $wait = $(if ($null -ne $script:FnRecoverWaitSec) { [int]$script:FnRecoverWaitSec } else { 3 })
  $why = ''
  for ($k = 0; $k -lt [math]::Max(1, $tries); $k++) {
    if ($k -gt 0) { Start-Sleep -Seconds $wait }
    $why = Get-PcRecoveredWhy $pcc $ifIndex
    if (-not $why) { Log ('PC network checked back: address and default route on ifIndex ' + $ifIndex); return '' }
    Log ('PC network not back yet (' + $why + ')')
  }
  return $why
}
function Say-CleanupFailed([string[]]$problems) {
  $m = 'FAILED - Run again. THIS PC''S NETWORK IS NOT BACK TO NORMAL: ' + ($problems -join '; ') + '. The record is kept: run "Fix NVR.cmd" again (it cleans up first) or restart the PC (the temporary address is memory-only).'
  Write-Host $m -ForegroundColor Red; Log ('SAY ' + $m)
}
function Remove-AllTemp {
  if ($Mock) { foreach ($t in $script:temps.ToArray()) { [void](Remove-OneTemp $t.ip $t.ifIndex); Log ('temp ip ' + $t.ip + ' removed') }; return $true }
  $problems = @()
  foreach ($t in $script:temps.ToArray()) { if (Remove-OneTemp $t.ip $t.ifIndex) { Log ('temp ip ' + $t.ip + ' removed') } else { $problems += ('the temporary address ' + $t.ip + ' is still on the adapter') } }
  $ix = $script:pcChanges.ifIndex; if ($null -eq $ix -and $script:pcNet) { $ix = $script:pcNet.ifIndex }
  $pcc = [pscustomobject]@{ coexistence_before = $script:pcChanges.coexistence_before; dhcp = $(if ($null -ne $script:pcChanges.dhcp) { $script:pcChanges.dhcp } elseif ($script:pcNet) { $script:pcNet.dhcp } else { $false })
    ip = $(if ($script:pcChanges.ip) { $script:pcChanges.ip } elseif ($script:pcNet) { [string]$script:pcNet.ip } else { '' }); gw = $(if ($script:pcChanges.gw) { $script:pcChanges.gw } elseif ($script:pcNet) { [string]$script:pcNet.gw } else { '' })
    alias = $(if ($script:pcChanges.alias) { $script:pcChanges.alias } elseif ($script:pcNet) { [string]$script:pcNet.alias } else { '' })
    guid = $(if ($script:pcChanges.guid) { $script:pcChanges.guid } elseif ($script:pcNet -and $script:pcNet.PSObject.Properties['guid']) { [string]$script:pcNet.guid } else { '' })
    changed = ($null -ne $script:pcChanges.ifIndex -or $null -ne $script:pcChanges.coexistence_before) }   # 2.2.12: the connection check is for a PC this run touched
  if (-not $problems.Count) { Restore-PcSettings $pcc $ix ([ref]$problems) }
  if ($script:pcChanges.firewall_rule) { Remove-NetFirewallRule -DisplayName 'WireIt FixNVR discovery (temp)' -ErrorAction SilentlyContinue; Log 'temp firewall rule removed' }
  if ($problems.Count) { [void](Write-TempState); Say-CleanupFailed $problems; return $false }
  if ($script:pcChanges.cleanup_task) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue }
  $script:pcChanges.coexistence_before = $null; $script:pcChanges.firewall_rule = $false; $script:pcChanges.cleanup_task = $false
  if (-not (Remove-FnRecordChecked $tempFile)) { Say-CleanupFailed @('this PC''s network is back, but the clean-up record could not be removed (' + $tempFile + ')'); return $false }
  $left = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.SkipAsSource -and $_.PolicyStore -eq 'ActiveStore' -and ($cfg.temp_ip_hosts -contains (Last $_.IPAddress)) })
  if ($left.Count) { Log ('WARNING possible leftover temp addresses: ' + (($left | ForEach-Object { $_.IPAddress }) -join ', ')) }
  return $true
}
# 2.2.18 (Codex 2.2.17 #5): an unreadable record is NOT forgotten. The renamed file (temp-ips.unreadable-<when>.json) IS the durable
# "recovery not done" marker: every start finds it and stops before any change, until a CHECKED recovery clears it: this PC was
# restarted after the record was found (the temporary addresses are memory-only), none of this tool's temporary addresses is on any
# adapter, and the PC has a working connection with a router. Only then is the file renamed .resolved-<when>.json. 2.2.17 kept the
# "blocked" flag only in memory, so the next start found no journal and carried on.
function Get-FnBootTime { try { return [datetime](Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime } catch { return $null } }
function Get-FnUnreadableStamp($file) {
  $m = [regex]::Match([string]$file.Name, 'unreadable-(\d{8}-\d{6})')
  if ($m.Success) { try { return [datetime]::ParseExact($m.Groups[1].Value, 'yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture) } catch {} }
  return $file.LastWriteTime
}
# 2.2.19 (Codex 2.2.18 F08/F09 twins; Moshe's decision: no clear just because the PC restarted). The restart is still required (the
# temporary addresses are memory-only), but the clear itself is a POSITIVE check of the PC as it is now, with every query readable:
# the address list could be read and none of this tool's temporary addresses is on any adapter; the DHCP+static coexistence setting
# could be read on every connected adapter and is off (this tool switches it on); and the PC has a working connection with a router.
function Get-FnCoexistenceOnWhy {
  $ifs = $null; try { $ifs = @(Get-NetIPInterface -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_ -and [string]$_.ConnectionState -eq 'Connected' -and [string]$_.InterfaceAlias -notmatch '(?i)loopback' }) } catch { return ('the tool could not list this PC''s network adapters (' + $_.Exception.Message + ')') }
  if (-not $ifs.Count) { return 'the tool could not find a connected network adapter on this PC' }
  foreach ($i in $ifs) {
    $t = ''; try { $t = ((netsh interface ipv4 show interface ([string]$i.ifIndex)) -join "`n") } catch { $t = '' }
    $m = [regex]::Match($t, '(?i)DHCP/Static IP coexistence\s*:\s*(\w+)')
    if (-not $m.Success) { return ('the DHCP+static coexistence setting of "' + [string]$i.InterfaceAlias + '" could not be read') }
    if ($m.Groups[1].Value -match '(?i)enabled') { return ('the DHCP+static coexistence setting is ON on "' + [string]$i.InterfaceAlias + '" (an earlier run may have switched it on; switch it off with: netsh interface ipv4 set interface ' + [string]$i.ifIndex + ' dhcpstaticipcoexistence=disabled)') }
  }
  return ''
}
function Get-FnUnreadableClearWhy($file) {
  $boot = Get-FnBootTime
  if (-not $boot) { return 'the tool could not read when this PC last started' }
  if ($boot -le (Get-FnUnreadableStamp $file)) { return 'this PC has not been restarted since then' }
  $all = $null; try { $all = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop) } catch { return ('the tool could not read this PC''s addresses (' + $_.Exception.Message + ')') }
  # 2.2.20 (Codex 2.2.19 R07; Moshe's decision: a COMPLETE positive check). The record could not be read, so the tool does not know
  # which addresses it added: EVERY SkipAsSource address on any adapter (whatever its last number) blocks the clear (2.2.19 looked
  # only at the last numbers in today's temp_ip_hosts).
  $left = @($all | Where-Object { $_ -and $_.SkipAsSource } | ForEach-Object { [string]$_.IPAddress })
  if ($left.Count) { return ('an address of the kind this tool adds (not used for sending) is still on this PC (' + ($left -join ', ') + ')') }
  $cw = Get-FnCoexistenceOnWhy; if ($cw) { return $cw }
  $aw = Get-FnConnectedAdaptersWhy $all; if ($aw) { return $aw }
  $pcn = Get-PcNet
  if (-not $pcn -or -not $pcn.ip -or -not $pcn.gw) { return 'this PC has no working network connection with a router yet' }
  return ''
}
# 2.2.20 (Codex 2.2.19 R07): every CONNECTED adapter is read completely: its DHCP setting must be readable (on or off), and it must
# have its own working address (not 169.254, not a temporary SkipAsSource one, a valid prefix), whether it uses DHCP or a fixed
# address. An adapter that cannot be read, or a connected one with no working address of its own, = '' is NOT returned.
function Get-FnConnectedAdaptersWhy($all) {
  $ifs = $null; try { $ifs = @(Get-NetIPInterface -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_ -and [string]$_.ConnectionState -eq 'Connected' -and [string]$_.InterfaceAlias -notmatch '(?i)loopback' }) } catch { return ('the tool could not list this PC''s network adapters (' + $_.Exception.Message + ')') }
  if (-not $ifs.Count) { return 'the tool could not find a connected network adapter on this PC' }
  foreach ($i in $ifs) {
    $nm = '"' + [string]$i.InterfaceAlias + '"'
    if ($null -eq $i.ifIndex -or [string]$i.ifIndex -notmatch '^\d+$') { return ('the tool could not read the number of the network adapter ' + $nm) }
    if ([string]$i.Dhcp -notmatch '^(?i)(enabled|disabled)$') { return ('the tool could not read whether ' + $nm + ' uses DHCP or a fixed address') }
    $own = @($all | Where-Object { $_ -and [string]$_.ifIndex -eq [string]$i.ifIndex -and -not $_.SkipAsSource -and [string]$_.IPAddress -and [string]$_.IPAddress -notlike '169.254.*' -and ([string]$_.AddressState -eq '' -or [string]$_.AddressState -eq 'Preferred') })
    $good = @($own | Where-Object { (Test-FnIpv4 ([string]$_.IPAddress)) -and ($null -eq $_.PrefixLength -or ([string]$_.PrefixLength -match '^\d+$' -and [int]$_.PrefixLength -ge 1 -and [int]$_.PrefixLength -le 32)) })
    if (-not $good.Count) { return ('the connected network adapter ' + $nm + ' has no working address of its own (' + $(if ([string]$i.Dhcp -match '(?i)enabled') { 'no lease from the router' } else { 'its fixed address is not there or not working' }) + '), so the tool cannot say an earlier run put it back') }
  }
  return ''
}
# 2.2.20 (R08 / R07): a real dotted IPv4 address (four numbers 0-255)
function Test-FnIpv4($v) {
  if (-not ($v -is [string]) -or [string]$v -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { return $false }
  foreach ($p in ([string]$v -split '\.')) { if ([int]$p -gt 255) { return $false } }
  return $true
}
function Get-FnUnreadableRecords {
  $dir = Split-Path -Parent $tempFile; $leaf = [IO.Path]::GetFileNameWithoutExtension($tempFile)
  if (-not (Test-Path -LiteralPath $dir)) { return @() }
  try { return @(Get-ChildItem -LiteralPath $dir -Filter ($leaf + '.unreadable-*.json') -File -ErrorAction Stop) } catch { return @([pscustomobject]@{ Name = '(the tool''s state folder could not be listed)'; FullName = ''; LastWriteTime = (Get-Date) }) }
}
# 2.2.19 (Codex 2.2.18 F09): '' = the clean-up record has the structure Write-TempState writes (version 2: temps = list of
# { ip, ifIndex }, pc = the before-state with every field this tool saves); otherwise the reason it is damaged.
function Get-FnJournalWhy($o) {
  if (-not ($o -is [pscustomobject])) { return 'is damaged (not a record this tool writes)' }
  $names = @($o.PSObject.Properties | ForEach-Object { $_.Name })
  foreach ($k in 'version', 'temps', 'pc') { if ($names -notcontains $k) { return ('is damaged (it has no "' + $k + '")') } }
  if (-not (Test-FnJsonInt $o.version) -or [long]$o.version -ne 2) { return ('is damaged or from an unknown version ("' + [string]$o.version + '")') }
  if (-not ($o.pc -is [pscustomobject])) { return 'is damaged (its PC part is missing)' }
  $pn = @($o.pc.PSObject.Properties | ForEach-Object { $_.Name })
  foreach ($k in 'coexistence_before', 'firewall_rule', 'cleanup_task', 'ifIndex', 'alias', 'dhcp', 'ip', 'gw') { if ($pn -notcontains $k) { return ('is damaged (its PC part has no "' + $k + '")') } }
  # 2.2.20 (Codex 2.2.19 R08, class E): every field must also have the TYPE Write-TempState writes. 2.2.19 checked only that the
  # names were there, so "dhcp":"false" (text, which PowerShell takes as TRUE) passed and recovery would have switched DHCP on.
  foreach ($k in 'firewall_rule', 'cleanup_task') { if (-not ($o.pc.$k -is [bool])) { return ('is damaged (its "' + $k + '" is not true/false)') } }
  if ($null -ne $o.pc.dhcp -and -not ($o.pc.dhcp -is [bool])) { return 'is damaged (its "dhcp" is not true/false)' }
  if ($null -ne $o.pc.coexistence_before -and -not (Test-FnCoexWord $o.pc.coexistence_before)) { return ('is damaged (its DHCP+static coexistence value "' + [string]$o.pc.coexistence_before + '" is not one Windows gives)') }
  foreach ($k in 'alias', 'guid') { if ($pn -contains $k -and $null -ne $o.pc.$k -and -not ($o.pc.$k -is [string])) { return ('is damaged (its adapter "' + $k + '" is not text)') } }
  foreach ($k in 'ip', 'gw') { if ($null -ne $o.pc.$k -and (-not ($o.pc.$k -is [string]) -or ([string]$o.pc.$k -and -not (Test-FnIpv4 $o.pc.$k)))) { return ('is damaged (its "' + $k + '" is not an address)') } }
  $pix = $o.pc.ifIndex; $pixOk = (Test-FnJsonInt $pix)
  if ($null -ne $pix -and -not $pixOk) { return ('is damaged (adapter number "' + [string]$pix + '")') }
  # the writer saves the adapter and its DHCP state together, the moment it first changes the adapter
  if ($pixOk -and -not ($o.pc.dhcp -is [bool])) { return 'is damaged (it names an adapter but not whether it used DHCP)' }
  if ($null -ne $o.temps -and -not ($o.temps -is [array])) { return 'is damaged (its address list is not a list)' }
  $tl = @($o.temps | Where-Object { $null -ne $_ })
  foreach ($t in $tl) {
    if (-not ($t -is [pscustomobject]) -or -not $t.PSObject.Properties['ip'] -or -not (Test-FnIpv4 $t.ip)) { return 'is damaged (an address in it is not readable)' }
    $tix = $(if ($t.PSObject.Properties['ifIndex']) { $t.ifIndex } else { $null })
    if ($null -ne $tix -and -not (Test-FnJsonInt $tix)) { return ('is damaged (adapter number "' + [string]$tix + '" for ' + [string]$t.ip + ')') }
    if ($null -eq $tix -and -not $pixOk) { return ('is damaged (no adapter number for ' + [string]$t.ip + ')') }
  }
  if (($tl.Count -or $null -ne $o.pc.coexistence_before) -and -not $pixOk) { return 'is damaged (it changed this PC but does not say which adapter)' }
  if ($tl.Count -and -not $o.pc.alias -and -not ($o.pc.PSObject.Properties['guid'] -and $o.pc.guid)) { return 'is damaged (it does not say which adapter it changed)' }
  return ''
}
# 2.2.20 (R08): a JSON whole number (never text such as "5")
function Test-FnJsonInt($v) { return (($v -is [int] -or $v -is [long] -or $v -is [int16] -or $v -is [uint32]) -and [long]$v -ge 0) }
function Invoke-LeftoverCleanup {
  if ($Mock) { return $true }
  foreach ($ev in @(Get-FnUnreadableRecords)) {
    $why = $(if ($ev.FullName) { Get-FnUnreadableClearWhy $ev } else { 'the record could not be checked' })
    if ($why) {
      Say-CleanupFailed @('an earlier run''s record of its temporary address could not be read (kept as ' + $ev.Name + '), so the tool cannot check this PC''s network was put back; ' + $why + '. Restart this PC, then run again')
      return $false
    }
    $done = $ev.FullName -replace '\.unreadable-', '.resolved-'
    try { Move-Item -LiteralPath $ev.FullName -Destination $done -Force -ErrorAction Stop } catch { Say-CleanupFailed @('the unreadable record ' + $ev.Name + ' could not be marked as cleared (' + $_.Exception.Message + ')'); return $false }
    # 2.2.20 (class A sweep): the durable block counts as cleared only when a fresh look shows the marker gone and the cleared copy there
    if ((Test-Path -LiteralPath $ev.FullName) -or -not (Test-Path -LiteralPath $done)) { Say-CleanupFailed @('the unreadable record ' + $ev.Name + ' could not be marked as cleared (it did not read back as moved)'); return $false }
    Log ('unreadable record ' + $ev.Name + ' cleared: PC restarted since, address list read with no temporary address left, coexistence read as off on every connected adapter, connection working')
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host ('An earlier unreadable record was cleared after a check of this PC as it is now: restarted since, no temporary address on any adapter, DHCP+static coexistence off, and the connection works.') -ForegroundColor Yellow
  }
  if (-not (Test-Path $tempFile)) { return $true }
  $o = $null; try { $o = Get-Content $tempFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch { $o = $null }
  # 2.2.19 (Codex 2.2.18 F09, class E): a record that parses but does not have the structure this tool writes (for example {}) is
  # damaged, not "nothing to do": it gets the same durable block as an unreadable one (2.2.18 took {} as clean and deleted it).
  $bad = $(if (-not $o) { 'could not be read' } else { Get-FnJournalWhy $o })
  if ($bad) {
    # unreadable / damaged: kept (renamed) as evidence = the durable marker above; the safety task stays, and this run says FAILED
    $keep = $tempFile -replace '\.json$', ('.unreadable-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json'); try { Move-Item -LiteralPath $tempFile -Destination $keep -Force -ErrorAction Stop } catch { $keep = $tempFile }
    Log ('clean-up record ' + $bad + ': kept as ' + (Split-Path -Leaf $keep))
    Say-CleanupFailed @('the record of an earlier run''s temporary address ' + $bad + ' (kept as ' + (Split-Path -Leaf $keep) + '); restart this PC, then run again (every run stops here until the PC is checked)')
    return $false
  }
  $problems = @(); $still = New-Object System.Collections.Generic.List[object]
  $sx = $o.pc.ifIndex
  foreach ($t in @($o.temps)) {
    if (-not $t) { continue }
    $ix = $(if ($null -ne $t.ifIndex) { $t.ifIndex } else { $sx })
    # 2.2.19 (Codex 2.2.18 F05, class A): an address still there is removed only from the adapter the record saved (GUID / name read
    # back the same). An address already gone needs no change; one on an adapter that is not positively the saved one stays journaled.
    # 2.2.20 (Codex 2.2.19 R02): the identity is read again for EACH address, right before its removal (2.2.19 cached it per number)
    if (-not (Test-TempGone $t.ip $ix)) {
      $aw = Get-FnRecordAdapterWhy $o.pc $ix
      if ($aw) { $still.Add($t); $problems += ('the temporary address ' + $t.ip + ' a previous run left is still on adapter number ' + $ix + ', but ' + $aw + ', so it was NOT removed automatically'); if ($null -eq $sx) { $sx = $ix }; continue }
      Remove-NetIPAddress -IPAddress $t.ip -InterfaceIndex $ix -PolicyStore ActiveStore -Confirm:$false -ErrorAction SilentlyContinue
      if (Test-TempGone $t.ip $ix) { $aw = Get-FnRecordAdapterWhy $o.pc $ix; if ($aw) { $still.Add($t); $problems += ('the temporary address ' + $t.ip + ' reads gone, but ' + $aw + ', so the tool cannot say it was removed from the right adapter'); if ($null -eq $sx) { $sx = $ix }; continue } }
    }
    if (Test-TempGone $t.ip $ix) { Write-Host ('Removed a temporary address a previous run left behind: ' + $t.ip); Log ('leftover temp ip ' + $t.ip + ' removed') } else { $still.Add($t); $problems += ('the temporary address ' + $t.ip + ' a previous run left is still on the adapter') }
    if ($null -eq $sx) { $sx = $ix }
  }
  if (-not $problems.Count) { Restore-PcSettings $o.pc $sx ([ref]$problems) }
  if ($o.pc.firewall_rule) { Remove-NetFirewallRule -DisplayName 'WireIt FixNVR discovery (temp)' -ErrorAction SilentlyContinue }
  if ($problems.Count) {
    try { Save-Json ([ordered]@{ version = 2; temps = $still.ToArray(); pc = $o.pc; written = (Get-Date -Format 's') }) $tempFile } catch { Log ('temp state not re-saved: ' + $_.Exception.Message) }
    Say-CleanupFailed $problems; return $false
  }
  Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
  if (-not (Remove-FnRecordChecked $tempFile)) { Say-CleanupFailed @('the earlier run''s changes are put back, but its clean-up record could not be removed (' + $tempFile + ')'); return $false }
  return $true
}
# 2.2.20 (Codex 2.2.19 class A sweep): a recovery record is "removed" only when a fresh look shows it gone (2.2.19 ignored a failed delete)
function Remove-FnRecordChecked([string]$path) {
  try { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction Stop } } catch { Log ('record not removed: ' + $_.Exception.Message); return $false }
  if (Test-Path -LiteralPath $path) { Log ('record still there after removal: ' + $path); return $false }
  return $true
}

# ---------------- discovery ----------------
function Open-Firewall {
  if ($Mock -or $script:pcChanges.firewall_rule) { return }
  # 2.2.19 (class E): the record says "rule added" BEFORE the rule is added (2.2.18 added it first and ignored a failed save, so a
  # crash could leave a rule nobody knew about). No saved record = no rule (discovery still runs, some replies may be blocked).
  $script:pcChanges.firewall_rule = $true
  if (-not (Write-TempState)) { $script:pcChanges.firewall_rule = $false; Log 'firewall rule not added: the clean-up record could not be saved first'; return }
  try { New-NetFirewallRule -DisplayName 'WireIt FixNVR discovery (temp)' -Direction Inbound -Protocol UDP -LocalPort 37020,3702 -Action Allow -Profile Any -ErrorAction Stop | Out-Null }
  catch { Log ('firewall rule not added: ' + $_.Exception.Message); $script:pcChanges.firewall_rule = $false; [void](Write-TempState) }
}
function XVal([string]$xml, [string]$name) { $m = [regex]::Match($xml, '<(?:\w+:)?' + $name + '(?:\s[^>]*)?>([^<]*)</(?:\w+:)?' + $name + '>'); if ($m.Success) { return $m.Groups[1].Value.Trim() } else { return '' } }
function Parse-Sadp([string]$x) {
  $ch = 0; [void][int]::TryParse((XVal $x 'DigitalChannelNum'), [ref]$ch); $an = 0; [void][int]::TryParse((XVal $x 'AnalogChannelNum'), [ref]$an)
  $model = XVal $x 'DeviceDescription'
  $isRec = ($ch -gt 0 -or $an -gt 0 -or $model -match '^(i?DS-7|i?DS-9|NRA|HNR|ERI-K|.*NVR)')
  return [pscustomobject]@{ ip = (XVal $x 'IPv4Address'); mask = (XVal $x 'IPv4SubnetMask'); gw = (XVal $x 'IPv4Gateway'); mac = (NormMac (XVal $x 'MAC')); serial = (XVal $x 'DeviceSN'); model = $model; firmware = (XVal $x 'SoftwareVersion'); dhcp = ((XVal $x 'DHCP') -eq 'true'); activated = (XVal $x 'Activated'); http_port = (XVal $x 'HttpPort'); boot = (XVal $x 'BootTime'); oem = (XVal $x 'OEMInfo'); brand = 'hik'; kind = $(if ($isRec) { 'nvr' } else { 'camera' }); found_by = 'SADP' }
}
function Find-Sadp($localIps) {
  $out = @{}
  if ($Mock) { foreach ($x in @($Mock.sadp)) { $d = Parse-Sadp $x; $out[$d.mac] = $d }; return $out }
  $socks = @()
  foreach ($l in $localIps) {
    try {
      $u = New-Object System.Net.Sockets.UdpClient
      $u.Client.SetSocketOption([Net.Sockets.SocketOptionLevel]::Socket, [Net.Sockets.SocketOptionName]::ReuseAddress, $true)
      $u.Client.Bind((New-Object Net.IPEndPoint ([Net.IPAddress]::Parse($l)), 37020))
      try { $u.JoinMulticastGroup([Net.IPAddress]::Parse('239.255.255.250'), [Net.IPAddress]::Parse($l)) } catch {}
      $u.Client.SetSocketOption([Net.Sockets.SocketOptionLevel]::IP, [Net.Sockets.SocketOptionName]::MulticastInterface, ([Net.IPAddress]::Parse($l)).GetAddressBytes())
      $socks += $u
    } catch { Log ('SADP socket on ' + $l + ': ' + $_.Exception.Message + ' (close SADP/HiTools if open)') }
  }
  $probe = [Text.Encoding]::UTF8.GetBytes('<?xml version="1.0" encoding="utf-8"?><Probe><Uuid>' + ([guid]::NewGuid().ToString().ToUpper()) + '</Uuid><Types>inquiry</Types></Probe>')
  $ep0 = New-Object Net.IPEndPoint ([Net.IPAddress]::Parse('239.255.255.250')), 37020
  foreach ($s in $socks) { for ($k = 0; $k -lt 2; $k++) { try { [void]$s.Send($probe, $probe.Length, $ep0) } catch {} } }
  $end = (Get-Date).AddSeconds([int]$cfg.sadp_listen_seconds)
  while ((Get-Date) -lt $end) {
    foreach ($s in $socks) { while ($s.Available -gt 0) { $ep = New-Object Net.IPEndPoint ([Net.IPAddress]::Any), 0; try { $t = [Text.Encoding]::UTF8.GetString($s.Receive([ref]$ep)); if ($t -match '<ProbeMatch>' -and $t -match '<DeviceSN>') { $d = Parse-Sadp $t; if ($d.mac) { $out[$d.mac] = $d } } } catch {} } }
    Start-Sleep -Milliseconds 100
  }
  foreach ($s in $socks) { $s.Close() }
  return $out
}
function Find-ArpSniff([int]$seconds) {
  # passive: devices stuck on an old scheme keep ARPing for their old gateway/NVR. Uses Windows' built-in pktmon.
  $res = @{}
  if ($Mock) { foreach ($a in @($Mock.arp)) { $res[(NormMac $a.mac)] = $a.ip }; return $res }
  if ($seconds -le 0 -or -not (Get-Command pktmon.exe -ErrorAction SilentlyContinue)) { return $res }
  $st = (pktmon status 2>&1) -join "`n"
  if ($st -notmatch '(?i)not running') { Log 'pktmon busy, passive listen skipped'; return $res }
  $fl = (pktmon filter list 2>&1) -join "`n"
  if ($fl -notmatch '(?i)no filters|There are no|Filters:\s*None') { Log 'pktmon has filters set by someone else, passive listen skipped'; return $res }
  $etl = Join-Path $runDir 'arp.etl'; $txt = Join-Path $runDir 'arp.txt'
  try {
    pktmon filter add FixNVRarp -d ARP | Out-Null
    pktmon start --capture --pkt-size 128 --file-name $etl | Out-Null
    Start-Sleep -Seconds $seconds
  } finally { pktmon stop | Out-Null; pktmon filter remove | Out-Null }
  pktmon etl2txt $etl --out $txt 2>&1 | Out-Null
  if (-not (Test-Path $txt)) { pktmon format $etl -o $txt 2>&1 | Out-Null }
  if (Test-Path $txt) {
    foreach ($ln in (Get-Content $txt)) {
      $m = [regex]::Match($ln, '([0-9A-Fa-f]{2}(?:-[0-9A-Fa-f]{2}){5}) > [0-9A-Fa-f-]{17}.*?(?:who-has \S+ tell (\d+\.\d+\.\d+\.\d+)|Reply (\d+\.\d+\.\d+\.\d+) is-at)')
      if ($m.Success) { $ip = $m.Groups[2].Value; if (-not $ip) { $ip = $m.Groups[3].Value }; if ($ip -and $ip -ne '0.0.0.0' -and $ip -notlike '169.254.*') { $res[(NormMac $m.Groups[1].Value)] = $ip } }
    }
  }
  Remove-Item $etl -ErrorAction SilentlyContinue
  Log ('passive listen: ' + $res.Count + ' device(s) heard')
  return $res
}
function Find-Onvif($localIps) {
  # WS-Discovery (ONVIF standard). Replies come back to the address we sent from, so run it from the temp address too.
  $out = @{}
  if ($Mock) { foreach ($o in @($Mock.onvif)) { $out[$o.ip] = $o.scopes }; return $out }
  $msg = '<?xml version="1.0" encoding="UTF-8"?><e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope" xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing" xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery" xmlns:dn="http://www.onvif.org/ver10/network/wsdl"><e:Header><w:MessageID>uuid:' + [guid]::NewGuid() + '</w:MessageID><w:To e:mustUnderstand="true">urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To><w:Action e:mustUnderstand="true">http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action></e:Header><e:Body><d:Probe><d:Types>dn:NetworkVideoTransmitter</d:Types></d:Probe></e:Body></e:Envelope>'
  $b = [Text.Encoding]::UTF8.GetBytes($msg); $socks = @()
  foreach ($l in $localIps) { try { $u = New-Object System.Net.Sockets.UdpClient (New-Object Net.IPEndPoint ([Net.IPAddress]::Parse($l)), 0); [void]$u.Send($b, $b.Length, (New-Object Net.IPEndPoint ([Net.IPAddress]::Parse('239.255.255.250')), 3702)); $socks += $u } catch {} }
  $end = (Get-Date).AddSeconds(3)
  while ((Get-Date) -lt $end) { foreach ($s in $socks) { while ($s.Available -gt 0) { $ep = New-Object Net.IPEndPoint ([Net.IPAddress]::Any), 0; try { $t = [Text.Encoding]::UTF8.GetString($s.Receive([ref]$ep)); if ($t -match 'XAddrs') { $out[$ep.Address.ToString()] = (XVal $t 'Scopes') } } catch {} } }; Start-Sleep -Milliseconds 100 }
  foreach ($s in $socks) { $s.Close() }
  return $out
}
function Test-IpFree([string]$ip) {
  if ($Mock) { try { $r = Invoke-RestMethod -Uri ($Mock.url + '/mockctl/has/' + $ip) -TimeoutSec 5; return -not $r.used } catch { return $true } }
  $p = New-Object Net.NetworkInformation.Ping
  for ($k = 0; $k -lt 2; $k++) { try { if ($p.Send($ip, 700).Status -eq 'Success') { return $false } } catch {} }
  # 2.2.19 (class C): the neighbour table is read with errors visible; "no entry for that address" = free, any other error = the tool
  # cannot tell, so the address is NOT treated as free (2.2.18 read every error as free)
  $n = $null
  try { $n = Get-NetNeighbor -IPAddress $ip -ErrorAction Stop | Where-Object { $_.State -in 'Reachable','Stale','Permanent' -and $_.LinkLayerAddress -and $_.LinkLayerAddress -ne '00-00-00-00-00-00' } }
  catch { if ($_.CategoryInfo.Category -ne 'ObjectNotFound' -and $_.Exception.Message -notmatch '(?i)No matching MSFT_NetNeighbor') { Log ('could not read the neighbour table for ' + $ip + ': ' + $_.Exception.Message); return $false } }
  return -not $n
}

# ---------------- credentials (asked once, kept in memory only) ----------------
$script:credNvr = $null; $script:credCam = $null
function Get-Creds {
  if ($CredFile -and (Test-Path $CredFile)) {
    $cl = Get-Content $CredFile; $script:credNvr = New-Object PSCredential($cl[0], (ConvertTo-SecureString $cl[1] -AsPlainText -Force))
    if ($cl.Count -ge 3 -and $cl[2]) { $script:credCam = New-Object PSCredential($cl[0], (ConvertTo-SecureString $cl[2] -AsPlainText -Force)) } else { $script:credCam = $script:credNvr }
    return
  }
  if ($BitwardenExport -and (Test-Path $BitwardenExport)) {
    $bw = Get-Content $BitwardenExport -Raw | ConvertFrom-Json
    $items = @($bw.items | Where-Object { $_.login -and $_.login.password })
    $it = $null
    if ($BitwardenItem) { $it = $items | Where-Object { $_.name -eq $BitwardenItem } | Select-Object -First 1 }
    if (-not $it) {
      $cand = @($items | Where-Object { $_.name -match '(?i)nvr|camera|cam|hik|uniview|unv|dvr' -or ($Site -and $_.name -like ('*' + $Site + '*')) })
      if (-not $cand.Count) { $cand = $items }
      Write-Host 'Bitwarden items:'; for ($i = 0; $i -lt [math]::Min($cand.Count, 40); $i++) { Write-Host ('  ' + ($i + 1) + ') ' + $cand[$i].name) }
      $n = Read-Host 'Number of the NVR login item'; $it = $cand[[int]$n - 1]
    }
    $u = $(if ($it.login.username) { $it.login.username } else { $User })
    $script:credNvr = New-Object PSCredential($u, (ConvertTo-SecureString $it.login.password -AsPlainText -Force)); $bw = $null; $items = $null; $it = $null
    Write-Host 'Using that login (password not shown). Delete the Bitwarden export file when you are done.' -ForegroundColor Yellow
  } else {
    $s = Read-Host ('NVR password for user "' + $User + '" (typing is hidden)') -AsSecureString
    $script:credNvr = New-Object PSCredential($User, $s)
  }
  $c = Read-Host 'Camera password (just press Enter if it is the same as the NVR)' -AsSecureString
  if ($c.Length -gt 0) { $script:credCam = New-Object PSCredential($script:credNvr.UserName, $c) } else { $script:credCam = $script:credNvr }
}
function Cred-For($dev) { if ($dev.kind -eq 'nvr') { return $script:credNvr } else { return $script:credCam } }

# ---------------- HTTP (digest login, ONE attempt per device; a refused login is never retried) ----------------
$script:refused = @{}
$script:scheme = @{}
function Base([string]$ip) {
  if ($Mock) { return ($Mock.url + '/dev/' + $ip) }
  if ($script:scheme.ContainsKey($ip)) { return ($script:scheme[$ip] + '://' + $ip) }
  return ('http://' + $ip)
}
# 2.2.2 (re-review H1, classic Fix NVR): a request whose body carries a password goes over HTTPS first. It drops to plain HTTP
# ONLY when nothing listens on the HTTPS port (the device has no HTTPS); a timeout or a TLS/certificate failure stops it instead.
$script:nvrTls = @{}   # ip -> 'ok' (HTTPS worked) | 'none' (nothing on 443) | 'failed:<why>'
function Test-NvrSecretBody([string]$body) { return ($body -match '(?i)<(\w+:)?password[\s>/]' -or $body -match '(?i)"(password|passwd|pwd)"\s*:') }
function Test-NvrTlsPort([string]$ip, [int]$ms = 3000) {
  $h = $ip; $port = 443; if ($ip -match '^(.+):(\d+)$') { $h = $Matches[1]; $port = [int]$Matches[2] }
  $c = New-Object Net.Sockets.TcpClient
  try {
    $ar = $c.BeginConnect($h, $port, $null, $null)
    if (-not $ar.AsyncWaitHandle.WaitOne($ms)) { return 'timeout' }
    $c.EndConnect($ar); return 'tls'   # the port answers, so the HTTPS failure was the TLS handshake or the certificate
  } catch {
    $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
    if ($e -is [Net.Sockets.SocketException] -and ([string]$e.SocketErrorCode -eq 'ConnectionRefused' -or [int]$e.NativeErrorCode -eq 10061 -or [int]$e.NativeErrorCode -eq 111)) { return 'refused' }
    return 'error'
  } finally { try { $c.Close() } catch {} }
}
# 2.2.7 (Codex file-by-file F06): over plain HTTP a password is only answered to a Digest challenge (the password itself never
# crosses the wire). A device - or a box pretending to be one - that asks only for Basic gets NO password over plain HTTP.
# Same check in FixNVR.ps1, CamViews.ps1, NetCheck.ps1 and SiteCheck.ps1 (FixSite and NvrHealth have had it since 2.2.3).
$script:WiAuthSeen = @{}
function Test-WireItPlainBasicOnly([string]$uri) {
  $u = $null; try { $u = [uri]$uri } catch { return $false }
  if (-not $u -or $u.Scheme -ne 'http') { return $false }
  if ($null -eq $script:WiAuthSeen) { $script:WiAuthSeen = @{} }
  $k = $u.Authority; if ($script:WiAuthSeen.ContainsKey($k)) { return [bool]$script:WiAuthSeen[$k] }
  $basicOnly = $false
  try { $rq = [Net.HttpWebRequest]::Create($u); $rq.Method = 'GET'; $rq.Timeout = 6000; $rq.AllowAutoRedirect = $false; $rs = $rq.GetResponse(); $rs.Close() }
  catch { $ex = $_.Exception; while ($ex -and -not ($ex -is [Net.WebException])) { $ex = $ex.InnerException }
    if ($ex -and $ex.Response) { $h = [string]$ex.Response.Headers['WWW-Authenticate']; if ($h -match '(?i)\bbasic\b' -and $h -notmatch '(?i)\bdigest\b') { $basicOnly = $true }; try { $ex.Response.Close() } catch {} } }
  $script:WiAuthSeen[$k] = $basicOnly; return $basicOnly
}
function Err-Body($ex) { try { $r = $ex.Exception.Response; if ($r) { $sr = New-Object IO.StreamReader($r.GetResponseStream()); return $sr.ReadToEnd() } } catch {}; return '' }
function Http([string]$ip, [string]$method, [string]$path, [string]$body = '', [string]$ctype = 'application/xml', $cred = $null, [int]$timeout = 10) {
  if ($script:refused.ContainsKey($ip)) { return @{ code = 401; body = ''; err = 'login refused earlier, not retried' } }
  $args2 = @{ Uri = ((Base $ip) + $path); Method = $method; UseBasicParsing = $true; TimeoutSec = $timeout }
  if ($cred) { $args2.Credential = $cred }
  if ($body) { $args2.Body = [Text.Encoding]::UTF8.GetBytes($body); $args2.ContentType = $ctype }
  if (-not $IsPs5) { if (Test-WireItLanHost $ip) { $args2.SkipCertificateCheck = $true }; if ($cred) { $args2.AllowUnencryptedAuthentication = $true } }   # 2.2.2 (Codex H2): the skip only for a device on the LAN
  $secret = ((-not $Mock) -and (Test-NvrSecretBody $body))
  if ($secret) {
    $st = [string]$script:nvrTls[$ip]
    if ($st -like 'failed:*') { return @{ code = 0; body = ''; err = ('HTTPS did not work (' + $st.Substring(7) + ') - the password was not sent over plain HTTP') } }
    $args2.Uri = $(if ($st -eq 'none') { 'http://' } else { 'https://' }) + $ip + $path
  }
  Log ($method + ' ' + $args2.Uri + $(if ($body) { ' BODY ' + $body } else { '' }))
  if ($cred -and -not $Mock -and (Test-WireItPlainBasicOnly $args2.Uri)) { Log ('  -> refused: plain HTTP with Basic login only (the password is not sent)'); return @{ code = 0; body = ''; err = 'plain HTTP with Basic login only - the password was not sent' } }   # 2.2.7 (F06)
  for ($try = 0; $try -lt 2; $try++) {
    try {
      $r = Invoke-WebRequest @args2
      if ($secret -and $args2.Uri.StartsWith('https://')) { $script:nvrTls[$ip] = 'ok' }
      $c = [string]$r.Content; if ($r.Content -is [byte[]]) { $c = [Text.Encoding]::UTF8.GetString($r.Content) }
      Log ('  -> ' + [int]$r.StatusCode + ' ' + $(if ($c.Length -gt 600) { $c.Substring(0, 600) + '...' } else { $c }))
      return @{ code = [int]$r.StatusCode; body = $c; err = '' }
    } catch {
      $code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch {}
      $eb = Err-Body $_
      Log ('  -> ' + $code + ' ' + $_.Exception.Message + ' ' + $eb)
      if ($code -eq 401 -and $cred) { $script:refused[$ip] = $true; return @{ code = 401; body = $eb; err = 'login refused' } }
      if ($secret -and $code -ne 0 -and $args2.Uri.StartsWith('https://')) { $script:nvrTls[$ip] = 'ok' }
      if ($secret -and $code -eq 0 -and $args2.Uri.StartsWith('https://')) {
        $why = $(if ([string]$_.Exception.Message -match '(?i)timed? ?out|timeout') { 'timeout' } else { Test-NvrTlsPort $ip })
        if ($why -eq 'refused') {
          $script:nvrTls[$ip] = 'none'; $args2.Uri = 'http://' + $ip + $path
          Say ('  WARNING: ' + $ip + ' has no HTTPS (nothing on port 443) - its password goes over plain HTTP.') 'Yellow'
          Log ('  HTTPS refused on ' + $ip + ' -> plain HTTP'); continue
        }
        $script:nvrTls[$ip] = 'failed:' + $why
        Say ('  ' + $ip + ': HTTPS did not work (' + $why + ') - the password was NOT sent over plain HTTP. Change it on the device page instead.') 'Red'
        return @{ code = 0; body = $eb; err = ('HTTPS did not work (' + $why + ') - the password was not sent over plain HTTP') }
      }
      if ($code -eq 0 -and $try -eq 0 -and -not $Mock -and -not $script:scheme.ContainsKey($ip)) { $script:scheme[$ip] = 'https'; $args2.Uri = ((Base $ip) + $path); continue }
      return @{ code = $code; body = $eb; err = $_.Exception.Message }
    }
  }
  return @{ code = 0; body = ''; err = 'no answer' }
}
function Hik-Status([string]$body) { return [pscustomobject]@{ code = (XVal $body 'statusCode'); text = (XVal $body 'statusString'); sub = (XVal $body 'subStatusCode') } }
# 2.2.20 (Codex 2.2.19 R12, class C twin): an accepted write is a ResponseStatus document saying OK (1) or "reboot needed" (7). An HTTP
# 200 with a login page, an empty body or another document is NOT accepted (2.2.19 took a 200 with no statusCode as OK).
function Hik-Ok($r) { if ($r.code -ne 200) { return $false }; if ([string]$r.body -notmatch '<(\w+:)?ResponseStatus[\s>/]') { return $false }; $s = Hik-Status $r.body; return ($s.code -eq '1' -or $s.code -eq '7') }
function Hik-Reboot($r) { $s = Hik-Status $r.body; return ($s.code -eq '7' -or $s.sub -match '(?i)reboot') }

# XML edit helpers (namespace-agnostic, keep everything the device sent)
function XNode($parent, [string]$path, [switch]$Create) {
  $n = $parent
  foreach ($seg in ($path -split '/')) {
    $c = $null; foreach ($ch in $n.ChildNodes) { if ($ch.LocalName -eq $seg) { $c = $ch; break } }
    if (-not $c) { if (-not $Create) { return $null }; $c = $n.OwnerDocument.CreateElement($seg, $n.NamespaceURI); [void]$n.AppendChild($c) }
    $n = $c
  }
  return $n
}
function XGet($doc, [string]$path) { $n = XNode $doc.DocumentElement $path; if ($n) { return $n.InnerText } else { return '' } }
function XSet($doc, [string]$path, [string]$v) { $n = XNode $doc.DocumentElement $path -Create; $n.InnerText = $v }

# ---------------- Hikvision (ISAPI) ----------------
# 2.2.14 (Codex F4): set a field even on a device object made before the field existed
function SetP($o, [string]$name, $value) { if ($o.PSObject.Properties[$name]) { $o.$name = $value } else { $o | Add-Member -NotePropertyName $name -NotePropertyValue $value } }
# 2.2.14 (Codex F4): only a real EZVIZ answer fills the platform fields. A failed or unparseable read = unknown ($null), never the old value.
function Set-FnHikPlatform($dev, $ez) {
  $ok = [bool]($ez -and $ez.code -eq 200 -and ([string]$ez.body) -match '<(\w+:)?EZVIZ[\s>/]')
  SetP $dev 'platform_read' $ok
  if (-not $ok) { $dev.platform_enabled = $null; $dev.platform_online = $null; return $false }
  $dev.platform_xml = $ez.body
  $en = XVal $ez.body 'enabled'; $rs = XVal $ez.body 'registerStatus'
  $dev.platform_enabled = $(if ($en -eq 'true') { $true } elseif ($en -eq 'false') { $false } else { $null })
  $dev.platform_online = $(if ($rs -eq 'true') { $true } elseif ($rs -eq 'false') { $false } else { $null })
  $dev.platform_has_code = [bool](XVal $ez.body 'verificationCode')
  return $true
}
# 2.2.14 (Codex F4): before the after-fix reread, forget everything the earlier read filled, so nothing from before the fix can pass as checked
function Clear-FnReadState($dev) {
  foreach ($k in 'login','model','serial','firmware','mask','gw','dns1','dns2','addressing','addressing_raw','net_xml','net_json','dns_json','platform_xml','platform_json','id_mac','net_ip') { SetP $dev $k '' }
  foreach ($k in 'platform_enabled','platform_online','platform_has_code','platform_read','net_read','dns_read','channels','channels_read','status_read') { SetP $dev $k $null }
}
function Hik-Read($dev) {
  $cred = Cred-For $dev
  $d = Http $dev.ip 'GET' '/ISAPI/System/deviceInfo' '' 'application/xml' $cred
  if ($d.code -ne 200) { $dev.login = $(if ($d.code -eq 401) { 'REFUSED (wrong password? not retried)' } else { 'no answer (' + $d.code + ')' }); return $false }
  # 2.2.20 (Codex 2.2.19 R12, class C twin): logged in = the device's own DeviceInfo document, not any HTTP 200 (a login page is not)
  if ([string]$d.body -notmatch '<(\w+:)?DeviceInfo[\s>/]') { $dev.login = 'no answer (the answer was not its device information)'; return $false }
  # 2.2.18 (Codex 2.2.17 #1): the MAC this device reports is checked against the MAC on record. A different MAC is a DIFFERENT
  # device at this address: it is rejected (not read, never written to), and the record keeps the MAC it had (2.2.17 overwrote it).
  $m = NormMac (XVal $d.body 'macAddress'); SetP $dev 'id_mac' ''
  if (Test-FnMacConflict $dev $m) { Set-FnDifferentDevice $dev $m; return $false }
  $dev.login = 'ok'; $dev.brand = 'hik'
  $dev.model = XVal $d.body 'model'; $dev.serial = XVal $d.body 'serialNumber'; if ($m) { $dev.mac = $m; $dev.id_mac = $m }
  $dt = XVal $d.body 'deviceType'; if ($dt -match '(?i)NVR|DVR|HVR|recorder') { $dev.kind = 'nvr' } elseif ($dt) { $dev.kind = 'camera' }
  $dev.firmware = XVal $d.body 'firmwareVersion'
  $ifs = Http $dev.ip 'GET' '/ISAPI/System/Network/interfaces' '' 'application/xml' $cred
  $ifid = '1'
  foreach ($mm in [regex]::Matches($ifs.body, '(?s)<NetworkInterface[ >].*?</NetworkInterface>')) { if ((XVal $mm.Value 'ipAddress') -eq $dev.ip) { $ifid = XVal $mm.Value 'id'; break } }
  $dev.if_id = $ifid
  $ipx = Http $dev.ip 'GET' ('/ISAPI/System/Network/interfaces/' + $ifid + '/ipAddress') '' 'application/xml' $cred
  # 2.2.14 (Codex F4): each settings read is tracked on its own; a failed read is "not read", never the old value
  SetP $dev 'net_read' $false
  if ($ipx.code -eq 200) {
    $doc = $null; try { $doc = [xml]$ipx.body } catch { Log ('network settings answer could not be read: ' + $_.Exception.Message) }
    if ($doc -and $doc.DocumentElement -and $doc.DocumentElement.LocalName -eq 'IPAddress') {
      $dev.net_xml = $ipx.body
      # 2.2.19 (Codex 2.2.18 F10): ISAPI says "dynamic" for DHCP; the record keeps one meaning ('dhcp' / 'static' / '' = not known)
      SetP $dev 'addressing_raw' (XGet $doc 'addressingType'); $dev.addressing = Get-FnAddrMode $dev.addressing_raw; $dev.mask = XGet $doc 'subnetMask'; $dev.gw = XGet $doc 'DefaultGateway/ipAddress'; SetP $dev 'net_ip' (XGet $doc 'ipAddress')
      $dev.dns1 = XGet $doc 'PrimaryDNS/ipAddress'; $dev.dns2 = XGet $doc 'SecondaryDNS/ipAddress'
      # 2.2.20 (Codex 2.2.19 R09, class C): which fields the device's answer CARRIES is kept apart from their values, so a missing mask
      # or gateway is "not read", never an empty setting Undo would put back
      SetP $dev 'net_has' @{ mask = [bool](XNode $doc.DocumentElement 'subnetMask'); gw = [bool](XNode $doc.DocumentElement 'DefaultGateway/ipAddress'); dns1 = [bool](XNode $doc.DocumentElement 'PrimaryDNS/ipAddress'); dns2 = [bool](XNode $doc.DocumentElement 'SecondaryDNS/ipAddress') }
      SetP $dev 'net_read' $true
    }
  }
  if ($dev.kind -eq 'nvr') {
    $ez = Http $dev.ip 'GET' '/ISAPI/System/Network/EZVIZ' '' 'application/xml' $cred
    [void](Set-FnHikPlatform $dev $ez)
    $chs = Http $dev.ip 'GET' '/ISAPI/ContentMgmt/InputProxy/channels' '' 'application/xml' $cred
    $st = Http $dev.ip 'GET' '/ISAPI/ContentMgmt/InputProxy/channels/status' '' 'application/xml' $cred
    $online = @{}; foreach ($mm in [regex]::Matches($st.body, '(?s)<InputProxyChannelStatus[ >].*?</InputProxyChannelStatus>')) { $online[(XVal $mm.Value 'id')] = ((XVal $mm.Value 'online') -eq 'true') }
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($mm in [regex]::Matches($chs.body, '(?s)<InputProxyChannel[ >].*?</InputProxyChannel>')) {
      $id = XVal $mm.Value 'id'
      $list.Add([pscustomobject]@{ id = $id; ip = (XVal $mm.Value 'ipAddress'); port = (XVal $mm.Value 'managePortNo'); protocol = (XVal $mm.Value 'proxyProtocol'); online = $online[$id]; poe = $false })
    }
    $dev.channels = $list
    # 2.2.13 (Codex #2/#3): an unanswered or unparseable camera list / camera status is NOT the same as "no cameras" / "all fine"
    $dev.channels_read = ($chs.code -eq 200 -and $chs.body -match '<(\w+:)?InputProxyChannelList[\s>/]')
    $dev.status_read = ($st.code -eq 200 -and $st.body -match '<(\w+:)?InputProxyChannelStatusList[\s>/]')
  }
  return $true
}
function Hik-SetNet($dev, [string]$ip, [string]$mask, [string]$gw, [string]$dns1, [string]$dns2, [switch]$Dhcp) {
  $doc = [xml]$dev.net_xml
  XSet $doc 'addressingType' $(if ($Dhcp) { 'dynamic' } else { 'static' })   # 2.2.3 (Codex #62): Undo gives a DHCP device DHCP back
  XSet $doc 'ipAddress' $ip; XSet $doc 'subnetMask' $mask; XSet $doc 'DefaultGateway/ipAddress' $gw
  # 2.2.19 (Codex 2.2.18 F11, class D): an empty DNS is a real value and is written back (2.2.18 skipped it, so Undo kept the DNS the
  # fix had put in). A DNS element the device never had is only created when there is a value for it.
  $hasD1 = $doc.DocumentElement.SelectSingleNode('*[local-name()="PrimaryDNS"]/*[local-name()="ipAddress"]'); $hasD2 = $doc.DocumentElement.SelectSingleNode('*[local-name()="SecondaryDNS"]/*[local-name()="ipAddress"]')
  if ($dns1 -or $hasD1) { XSet $doc 'PrimaryDNS/ipAddress' $dns1 }
  if ($dns2 -or $hasD2) { XSet $doc 'SecondaryDNS/ipAddress' $dns2 }
  $r = Http $dev.ip 'PUT' ('/ISAPI/System/Network/interfaces/' + $dev.if_id + '/ipAddress') $doc.OuterXml 'application/xml' (Cred-For $dev) 15
  if ($r.code -eq 0 -and $r.err -match '(?i)timed out|closed|aborted|reset') { return @{ ok = $true; reboot = $false; note = 'device dropped the connection while moving (normal)' } }
  return @{ ok = (Hik-Ok $r); reboot = (Hik-Reboot $r); note = ((Hik-Status $r.body).text + ' ' + $r.err).Trim() }
}
function Hik-EnablePlatform($dev) {
  $doc = [xml]$dev.platform_xml
  XSet $doc 'enabled' 'true'
  $r = Http $dev.ip 'PUT' '/ISAPI/System/Network/EZVIZ' $doc.OuterXml 'application/xml' $script:credNvr 15
  return @{ ok = (Hik-Ok $r); note = ((Hik-Status $r.body).text + ' ' + $r.err).Trim() }
}
# 2.2.18 (Codex 2.2.17 #1/#2 twin): the channel is read right before the write and changed only while it still points at the camera
# this step expects ($expectIp: the old address going forward, the address this run wrote going back). A channel that now points at
# another camera is left alone. After the write the channel is read back: it must point at $newIp.
# 2.2.20 (Codex 2.2.19 R06, class B): the channel is changed only for the camera this step saved. Right before the write the camera is
# read at $camIp (where it is now) on a fresh record and must positively be the saved one (MAC; an exact serial only when only a
# serial was saved). A step with no camera saved, a camera that is gone, moved or unreadable, or a different camera = the channel is
# LEFT ALONE (refused, NOT CHECKED). 2.2.19 recognised the camera by the channel's address alone, so another live camera that had taken
# the address would have had its channel and password replaced.
function Hik-SetChannel($nvr, [string]$id, [string]$newIp, [string]$expectIp = '', [string]$camIp = '', [string]$camMac = '', [string]$camSerial = '') {
  if (-not $camMac -and -not $camSerial) { return @{ ok = $false; refused = $true; note = ('channel D' + $id + ': the tool has no MAC or serial saved for the camera on this channel, so it cannot check the channel still belongs to it - LEFT ALONE, NOT CHECKED') } }
  $g = Http $nvr.ip 'GET' ('/ISAPI/ContentMgmt/InputProxy/channels/' + $id) '' 'application/xml' $script:credNvr
  if ($g.code -ne 200) { return @{ ok = $false; note = 'could not read channel ' + $id + ' (left alone)' } }
  $doc = $null; try { $doc = [xml]$g.body } catch { $doc = $null }
  if (-not $doc -or -not $doc.DocumentElement) { return @{ ok = $false; note = 'channel ' + $id + ' answer could not be read (left alone)' } }
  $cur = XGet $doc 'sourceInputPortDescriptor/ipAddress'
  if ($cur -eq $newIp) { return @{ ok = $true; note = 'channel D' + $id + ' already points at ' + $newIp + ' (read now)' } }
  if ($expectIp -and $cur -ne $expectIp) { return @{ ok = $false; refused = $true; note = ('channel D' + $id + ' now points at ' + $(if ($cur) { $cur } else { 'nothing' }) + ', not ' + $expectIp + ': it belongs to another camera now, so it was LEFT ALONE') } }
  if (-not $camIp) { return @{ ok = $false; refused = $true; note = ('channel D' + $id + ': the tool does not know where its camera is now, so it cannot check it - LEFT ALONE, NOT CHECKED') } }
  $cid = Read-FnIdentity $camIp $camMac 'camera' '' $camSerial
  if ($cid.why) { return @{ ok = $false; refused = $true; note = ('channel D' + $id + ' was LEFT ALONE - NOT CHECKED: its camera (' + $(if ($camMac) { $camMac } else { 'serial ' + $camSerial }) + ') could not be confirmed on ' + $camIp + ': ' + $cid.why) } }
  $sd = XNode $doc.DocumentElement 'sourceInputPortDescriptor'
  XSet $doc 'sourceInputPortDescriptor/ipAddress' $newIp
  $pw = XNode $sd 'password'
  if (-not $pw) { $pw = $doc.CreateElement('password', $sd.NamespaceURI); $un = XNode $sd 'userName'; if ($un) { [void]$sd.InsertAfter($pw, $un) } else { [void]$sd.AppendChild($pw) } }
  $pw.InnerText = $script:credCam.GetNetworkCredential().Password
  $r = Http $nvr.ip 'PUT' ('/ISAPI/ContentMgmt/InputProxy/channels/' + $id) $doc.OuterXml 'application/xml' $script:credNvr 15
  $pw.InnerText = ''; $doc = $null
  $note = ((Hik-Status $r.body).text + ' ' + $r.err).Trim()
  if (-not (Hik-Ok $r)) { return @{ ok = $false; note = $note } }
  $g2 = Http $nvr.ip 'GET' ('/ISAPI/ContentMgmt/InputProxy/channels/' + $id) '' 'application/xml' $script:credNvr
  $now = ''; if ($g2.code -eq 200) { try { $now = XGet ([xml]$g2.body) 'sourceInputPortDescriptor/ipAddress' } catch { $now = '' } }
  if ($now -ne $newIp) { return @{ ok = $false; note = ($note + ' accepted, but channel D' + $id + ' reads back ' + $(if ($now) { $now } else { '(could not be read)' }) + ', not ' + $newIp + ' - NOT confirmed').Trim() } }
  return @{ ok = $true; note = $note }
}
function Hik-RebootNow($dev) { $r = Http $dev.ip 'PUT' '/ISAPI/System/reboot' '' 'application/xml' (Cred-For $dev) 15; return (Hik-Ok $r) }

# ---------------- Uniview (LAPI read; network writes need -AllowUnverifiedUniview until tested on a real unit) ----------------
function Unv-Data([string]$body) { try { $j = $body | ConvertFrom-Json; if ($j.Response) { return $j.Response.Data } ; return $j } catch { return $null } }
function Unv-Ok([string]$body) { try { $j = $body | ConvertFrom-Json; return ($j.Response.ResponseCode -eq 0 -or $j.Response.StatusCode -eq 0) } catch { return $false } }
function Unv-Read($dev) {
  $cred = Cred-For $dev
  $d = Http $dev.ip 'GET' '/LAPI/V1.0/System/DeviceBasicInfo' '' 'application/json' $cred
  if ($d.code -ne 200) { if ($d.code -eq 401) { $dev.login = 'REFUSED (wrong password? not retried)' }; return $false }
  # 2.2.20 (R12 class C twin): only a LAPI answer that says success (ResponseCode 0) with its data counts as read
  $x = $(if (Unv-Ok $d.body) { Unv-Data $d.body } else { $null }); if (-not $x) { if (-not $dev.login) { $dev.login = 'no answer (the answer was not a successful device information reply)' }; return $false }
  $um = NormMac ([string]$x.MAC); SetP $dev 'id_mac' ''
  if (Test-FnMacConflict $dev $um) { Set-FnDifferentDevice $dev $um; return $false }   # 2.2.18 (Codex 2.2.17 #1), as Hik-Read
  $dev.login = 'ok'; $dev.brand = 'unv'; $dev.model = $x.DeviceModel; $dev.serial = $x.SerialNumber; if ($um) { $dev.mac = $um; $dev.id_mac = $um }
  $dev.firmware = $x.FirmwareVersion; if ($x.Netmask) { $dev.mask = $x.Netmask }; if ($x.Gateway) { $dev.gw = $x.Gateway }
  if ($dev.model -match '(?i)^NVR|^VMS|^DVR') { $dev.kind = 'nvr' } elseif (-not $dev.kind) { $dev.kind = 'camera' }
  if ($dev.kind -eq 'nvr') {
    # 2.2.14 (Codex F4): network, DNS and EZCloud reads are each tracked; a failed read leaves the field unknown, not the old value
    SetP $dev 'net_read' $false; SetP $dev 'dns_read' $false; SetP $dev 'platform_read' $false
    $n = Http $dev.ip 'GET' $cfg.uniview.net_path '' 'application/json' $cred; if ($n.code -eq 200 -and (Unv-Ok $n.body) -and (Unv-Data $n.body)) { $dev.net_json = $n.body; SetP $dev 'net_read' $true; $nd = Unv-Data $n.body; $dev.addressing = Get-FnUnvMode $nd; $ia = @(Find-JsonVals $nd '(?i)^(IPv4)?(IP)?Address$'); SetP $dev 'net_ip' $(if ($ia.Count) { [string]$ia[0] } else { '' }) }
    $dn = Http $dev.ip 'GET' $cfg.uniview.dns_path '' 'application/json' $cred; if ($dn.code -eq 200 -and (Unv-Ok $dn.body)) { $dd = Unv-Data $dn.body; if ($dd) { $dev.dns_json = $dn.body; $vals = @(Find-JsonVals $dd '(?i)dns'); if ($vals.Count) { $dev.dns1 = $vals[0]; if ($vals.Count -gt 1) { $dev.dns2 = $vals[1] }; SetP $dev 'dns_read' $true } } }
    if ($cfg.uniview.cloud_path) { $cl = Http $dev.ip 'GET' $cfg.uniview.cloud_path '' 'application/json' $cred; if ($cl.code -eq 200 -and (Unv-Ok $cl.body)) { $cd = Unv-Data $cl.body; $en = @(Find-JsonVals $cd '(?i)^enable'); if ($cd -and $en.Count) { $dev.platform_json = $cl.body; $dev.platform_enabled = ([string]$en[0] -match '^(1|true)$'); SetP $dev 'platform_read' $true } } }
    $c = Http $dev.ip 'GET' $cfg.uniview.channels_path '' 'application/json' $cred
    $list = New-Object System.Collections.Generic.List[object]
    $dev.channels_read = $false
    if ($c.code -eq 200 -and (Unv-Ok $c.body)) {
      $cd = Unv-Data $c.body; $arr = @(); foreach ($p in $cd.PSObject.Properties) { if ($p.Value -is [array]) { $arr = $p.Value } }
      $dev.channels_read = ($cd -ne $null)
      foreach ($ch in $arr) { $ip = @(Find-JsonVals $ch '(?i)^(IPAddress|Address|IP)$'); $st = @(Find-JsonVals $ch '(?i)^(Status|Online|OnlineStatus)$'); $list.Add([pscustomobject]@{ id = [string]$ch.ID; ip = $(if ($ip.Count) { [string]$ip[0] } else { '' }); port = ''; protocol = 'unv'; online = $(if ($st.Count) { [string]$st[0] -match '^(1|true|online)$' } else { $null }); poe = $false }) }
    }
    $dev.channels = $list
  }
  return $true
}
function Find-JsonVals($o, [string]$keyRx) {
  $res = @()
  if ($o -eq $null) { return $res }
  if ($o -is [array]) { foreach ($e in $o) { $res += Find-JsonVals $e $keyRx }; return $res }
  if ($o -is [pscustomobject]) { foreach ($p in $o.PSObject.Properties) { if ($p.Name -match $keyRx -and $p.Name -notmatch '(?i)mac' -and ($p.Value -is [string] -or $p.Value -is [int] -or $p.Value -is [long] -or $p.Value -is [bool])) { $res += $p.Value } elseif ($p.Value -is [pscustomobject] -or $p.Value -is [array]) { $res += Find-JsonVals $p.Value $keyRx } } }
  return $res
}
function Set-JsonVals($o, [string]$keyRx, $value) {
  if ($o -is [array]) { foreach ($e in $o) { Set-JsonVals $e $keyRx $value }; return }
  if ($o -is [pscustomobject]) { foreach ($p in $o.PSObject.Properties) { if ($p.Name -match $keyRx -and $p.Name -notmatch '(?i)mac|v6' -and -not ($p.Value -is [pscustomobject] -or $p.Value -is [array])) { $p.Value = $value } elseif ($p.Value -is [pscustomobject] -or $p.Value -is [array]) { Set-JsonVals $p.Value $keyRx $value } } }
}
# 2.2.19 (Codex 2.2.18 F10/F12): the Uniview network answer's own address, mask, gateway and addressing mode. The mode is read only
# from a field whose meaning is plain (a DHCP on/off flag, or a mode word Get-FnAddrMode knows); any other shape = '' (not known).
$script:FnUnvModeRx = '(?i)^(IPv4)?(AddressingType|AddressMode|IPMode|IPv4Mode|DHCPEnable|DHCPEnabled|DhcpEnable|DHCP)$'
function Get-FnUnvMode($d) {
  $mode = ''
  foreach ($p in @(Get-FnJsonProps $d $script:FnUnvModeRx)) {
    $v = $p.Value; $m = ''
    if ($p.Name -match '(?i)dhcp') { if ($v -is [bool]) { $m = $(if ($v) { 'dhcp' } else { 'static' }) } elseif ([string]$v -match '^(0|1)$') { $m = $(if ([string]$v -eq '1') { 'dhcp' } else { 'static' }) } elseif ([string]$v -match '^(?i)(true|false)$') { $m = $(if ([string]$v -match '(?i)true') { 'dhcp' } else { 'static' }) } }
    else { $m = Get-FnAddrMode ([string]$v) }
    if (-not $m) { return '' }
    if ($mode -and $mode -ne $m) { return '' }   # two fields that disagree = not known
    $mode = $m
  }
  return $mode
}
function Get-FnJsonProps($o, [string]$keyRx) {
  $res = @()
  if ($o -eq $null) { return $res }
  if ($o -is [array]) { foreach ($e in $o) { $res += Get-FnJsonProps $e $keyRx }; return $res }
  if ($o -is [pscustomobject]) { foreach ($p in $o.PSObject.Properties) { if ($p.Name -match $keyRx -and -not ($p.Value -is [pscustomobject] -or $p.Value -is [array])) { $res += $p } elseif ($p.Value -is [pscustomobject] -or $p.Value -is [array]) { $res += Get-FnJsonProps $p.Value $keyRx } } }
  return $res
}
function Unv-PlanNet($dev, [string]$ip, [string]$mask, [string]$gw) {
  $j = $dev.net_json | ConvertFrom-Json; $d = $j.Response.Data; if (-not $d) { $d = $j }
  Set-JsonVals $d '(?i)^(IPv4)?(IP)?Address$' $ip; Set-JsonVals $d '(?i)(Sub)?net ?mask$' $mask; Set-JsonVals $d '(?i)(Default)?Gateway$' $gw
  # 2.2.19 (Codex 2.2.18 F10): the move is to a FIXED address, so a plain DHCP on/off flag is switched off (same type as it was).
  # Any other mode field is left as it is; the read-back after the move then says whether the recorder really is static.
  foreach ($p in @(Get-FnJsonProps $d '(?i)^(IPv4)?(DHCPEnable|DHCPEnabled|DhcpEnable|DHCP)$')) { if ($p.Value -is [bool]) { $p.Value = $false } elseif ([string]$p.Value -match '^(0|1)$') { $p.Value = 0 } }
  return ($d | ConvertTo-Json -Depth 10 -Compress)
}
function Unv-PlanDns($dev, [string]$d1, [string]$d2) {
  $j = $dev.dns_json | ConvertFrom-Json; $d = $j.Response.Data; if (-not $d) { $d = $j }
  $props = @($d.PSObject.Properties | Where-Object { $_.Name -match '(?i)dns' -and -not ($_.Value -is [pscustomobject]) })
  if ($props.Count -ge 1) { $props[0].Value = $d1 }; if ($props.Count -ge 2) { $props[1].Value = $d2 }
  return ($d | ConvertTo-Json -Depth 10 -Compress)
}
function Unv-PlanCloud($dev) { $j = $dev.platform_json | ConvertFrom-Json; $d = $j.Response.Data; if (-not $d) { $d = $j }; Set-JsonVals $d '(?i)^enable' 1; return ($d | ConvertTo-Json -Depth 10 -Compress) }
function Unv-Put($dev, [string]$path, [string]$json) { $r = Http $dev.ip 'PUT' $path $json 'application/json' (Cred-For $dev) 15; if ($r.code -eq 0 -and $r.err -match '(?i)timed out|closed|aborted') { return @{ ok = $true; note = 'connection dropped while moving (normal)' } }; return @{ ok = ($r.code -eq 200 -and (Unv-Ok $r.body)); note = $r.err } }

# ---------------- ONVIF (open standard; used to move Uniview / other-brand cameras) ----------------
function Onvif([string]$ip, [string]$inner, $cred) {
  $nonce = New-Object byte[] 16; (New-Object Security.Cryptography.RNGCryptoServiceProvider).GetBytes($nonce)
  $created = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
  $pwb = [Text.Encoding]::UTF8.GetBytes($cred.GetNetworkCredential().Password); $cb = [Text.Encoding]::UTF8.GetBytes($created)
  $all = New-Object byte[] ($nonce.Length + $cb.Length + $pwb.Length); [Array]::Copy($nonce, 0, $all, 0, 16); [Array]::Copy($cb, 0, $all, 16, $cb.Length); [Array]::Copy($pwb, 0, $all, 16 + $cb.Length, $pwb.Length)
  $dig = [Convert]::ToBase64String((New-Object Security.Cryptography.SHA1Managed).ComputeHash($all)); [Array]::Clear($all, 0, $all.Length); [Array]::Clear($pwb, 0, $pwb.Length)
  $env = '<?xml version="1.0" encoding="UTF-8"?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:tds="http://www.onvif.org/ver10/device/wsdl" xmlns:tt="http://www.onvif.org/ver10/schema"><s:Header><wsse:Security xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd" xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd"><wsse:UsernameToken><wsse:Username>' + [Security.SecurityElement]::Escape($cred.UserName) + '</wsse:Username><wsse:Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">' + $dig + '</wsse:Password><wsse:Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary">' + [Convert]::ToBase64String($nonce) + '</wsse:Nonce><wsu:Created>' + $created + '</wsu:Created></wsse:UsernameToken></wsse:Security></s:Header><s:Body>' + $inner + '</s:Body></s:Envelope>'
  return (Http $ip 'POST' '/onvif/device_service' $env 'application/soap+xml; charset=utf-8' $null 15)
}
function Onvif-Read($dev) {
  $r = Onvif $dev.ip '<tds:GetNetworkInterfaces/>' (Cred-For $dev)
  if ($r.code -ne 200) { if (-not $dev.login) { $dev.login = 'ONVIF no answer/refused (' + $r.code + ')' }; return $false }
  # 2.2.20 (R12 class C twin): the answer must be the interface list, not a SOAP Fault or another page
  if ([string]$r.body -notmatch 'GetNetworkInterfacesResponse' -or [string]$r.body -match '<(\w+:)?Fault[\s>]') { if (-not $dev.login) { $dev.login = 'ONVIF no answer/refused (the answer was not its network interfaces)' }; return $false }
  $m = [regex]::Match($r.body, '<(?:\w+:)?NetworkInterfaces[^>]*token="([^"]+)"'); $dev.onvif_token = $(if ($m.Success) { $m.Groups[1].Value } else { 'eth0' })
  $pl = XVal $r.body 'PrefixLength'; if ($pl) { $dev.mask = PrefixToMask ([int]$pl) }
  $hw = NormMac (XVal $r.body 'HwAddress'); SetP $dev 'id_mac' ''
  if (Test-FnMacConflict $dev $hw) { Set-FnDifferentDevice $dev $hw; return $false }   # 2.2.18 (Codex 2.2.17 #1), as Hik-Read
  if ($hw) { $dev.mac = $hw; $dev.id_mac = $hw }
  $dev.onvif = $true; if (-not $dev.login) { $dev.login = 'ok (ONVIF)' }
  # 2.2.19 (Codex 2.2.18 F10/F11/F12, class C): for a device the tool reads only over ONVIF, its whole network setting (address, mode,
  # gateway, DNS) is read now, so a move is planned from - and Undo puts back - real values. A part that did not answer leaves
  # net_read false: such a device is not moved (2.2.18 saved empty gateway / DNS for it and Undo would have written them).
  if ($dev.net_read -ne $true) {
    $o = Onvif-ReadNet $dev; SetP $dev 'onvif_net' $o
    SetP $dev 'net_read' ([bool]$o.read)
    if ($o.read) { $dev.addressing = $o.mode; SetP $dev 'net_ip' $o.ip; if ($o.mask) { $dev.mask = $o.mask }; $dev.gw = $o.gw; $dev.dns1 = $o.dns1; $dev.dns2 = $o.dns2 }
  }
  return $true
}
function Onvif-SetNet($dev, [string]$ip, [int]$prefix, [string]$gw, [string]$d1, [string]$d2) {
  $c = Cred-For $dev
  # 2.2.19 (Codex 2.2.18 F06, class A): the follow-up writes go to the NEW address, where any device may answer. They need this
  # camera's MAC to compare with, so a camera with no MAC on record is not moved at all.
  $myMac = NormMac ([string]$dev.mac)
  if (-not $myMac) { return @{ ok = $false; refused = $true; reboot = $false; note = 'the tool has no MAC for this camera, so it could not check the device at the new address afterwards: NOT changed' } }
  $r = Onvif $dev.ip ('<tds:SetNetworkInterfaces><tds:InterfaceToken>' + $dev.onvif_token + '</tds:InterfaceToken><tds:NetworkInterface><tt:Enabled>true</tt:Enabled><tt:IPv4><tt:Enabled>true</tt:Enabled><tt:Manual><tt:Address>' + $ip + '</tt:Address><tt:PrefixLength>' + $prefix + '</tt:PrefixLength></tt:Manual><tt:DHCP>false</tt:DHCP></tt:IPv4></tds:NetworkInterface></tds:SetNetworkInterfaces>') $c
  $dropped = ($r.code -eq 0 -and $r.err -match '(?i)timed out|closed|aborted')
  if ($r.code -ne 200 -and -not $dropped) { return @{ ok = $false; note = 'SetNetworkInterfaces ' + $r.code + ' ' + $r.err } }
  # 2.2.20 (R12 class C twin): an HTTP 200 that is not the SetNetworkInterfaces answer (a SOAP Fault, a login page) is not accepted
  if (-not $dropped -and ([string]$r.body -notmatch 'SetNetworkInterfacesResponse' -or [string]$r.body -match '<(\w+:)?Fault[\s>]')) { return @{ ok = $false; note = 'SetNetworkInterfaces was not accepted (the answer was not its SetNetworkInterfaces reply)' } }
  $reboot = ((XVal $r.body 'RebootNeeded') -eq 'true')
  if ($reboot) { [void](Onvif $dev.ip '<tds:SystemReboot/>' $c) }
  # gateway + DNS are set on the NEW address (the old gateway setting would be off-subnet)
  $ok2 = $false; $seen = $false
  for ($k = 0; $k -lt [int]$cfg.camera_wait_seconds; $k += 5) {
    Start-Sleep -Seconds 5
    # 2.2.19 (Codex 2.2.18 F06): gateway + DNS go to the new address only when the device answering there gives THIS camera's MAC.
    # A different MAC, or an answer with no MAC (2.2.18 went ahead on that), = nothing written there, NOT CHECKED.
    $hw = Onvif $ip '<tds:GetNetworkInterfaces/>' $c
    if ($hw.code -ne 200) { continue }
    $seen = $true
    $hwm = NormMac (XVal $hw.body 'HwAddress')
    if (-not $hwm) { return @{ ok = $false; reboot = $reboot; note = ('moved, but the device answering on ' + $ip + ' did not say its MAC, so the tool cannot tell it is this camera: gateway / DNS NOT set - NOT CHECKED') } }
    if ($hwm -ne $myMac) { return @{ ok = $false; reboot = $reboot; note = ('a DIFFERENT device (MAC ' + $hwm + ') answers on ' + $ip + ': gateway / DNS NOT set') } }
    # an empty saved gateway is a real value (2.2.19, class D): the request then carries no gateway address
    $g = Onvif $ip ('<tds:SetNetworkDefaultGateway>' + $(if ($gw) { '<tds:IPv4Address>' + $gw + '</tds:IPv4Address>' } else { '' }) + '</tds:SetNetworkDefaultGateway>') $c
    if ($g.code -eq 200 -and [string]$g.body -match 'SetNetworkDefaultGatewayResponse' -and [string]$g.body -notmatch '<(\w+:)?Fault[\s>]') { $ok2 = $true; break }   # 2.2.20 (R12 twin): the expected reply, not any 200
  }
  if ($ok2) {
    # 2.2.19 (Codex 2.2.18 F11, class D): only the DNS servers that are set are sent; none = an empty fixed list (2.2.18 sent empty
    # entries). The answer must be accepted, and the caller reads the whole setting back afterwards.
    $dl = ''; foreach ($x in @($d1, $d2)) { if ($x) { $dl += '<tds:DNSManual><tt:Type>IPv4</tt:Type><tt:IPv4Address>' + $x + '</tt:IPv4Address></tds:DNSManual>' } }
    # 2.2.20 (Codex 2.2.19 class B sweep): the DNS change is its own write, so the device at the new address is identified again first
    $hw2 = Onvif $ip '<tds:GetNetworkInterfaces/>' $c; $hwm2 = $(if ($hw2.code -eq 200) { NormMac (XVal $hw2.body 'HwAddress') } else { '' })
    if ($hwm2 -ne $myMac) { return @{ ok = $false; reboot = $reboot; note = ('moved and gateway set, but the DNS change was NOT sent: the device on ' + $ip + ' could not be confirmed as this camera again' + $(if ($hwm2) { ' (it says MAC ' + $hwm2 + ')' } else { '' }) + ' - NOT CHECKED') } }
    $dr = Onvif $ip ('<tds:SetDNS><tds:FromDHCP>false</tds:FromDHCP>' + $dl + '</tds:SetDNS>') $c
    if ($dr.code -ne 200 -or [string]$dr.body -notmatch 'SetDNSResponse' -or [string]$dr.body -match '<(\w+:)?Fault[\s>]') { return @{ ok = $false; reboot = $reboot; note = ('moved and gateway set, but the DNS change was not accepted (' + $dr.code + ' ' + $dr.err + ')').Trim() } }
  }
  return @{ ok = $ok2; reboot = $reboot; note = $(if ($ok2) { '' } elseif ($seen) { 'moved, but the gateway change was not accepted on the new address' } else { 'moved, but did not answer on the new address in time' }) }
}


# ---------------- device records ----------------
$script:devs = New-Object System.Collections.Generic.List[object]
function New-Dev([string]$ip, [string]$mac, [string]$by) {
  $d = [pscustomobject]@{ ip = $ip; mac = (NormMac $mac); vendor = (Vendor $mac); brand = ''; kind = ''; model = ''; serial = ''; firmware = ''; mask = ''; gw = ''; dns1 = ''; dns2 = ''; addressing = ''; dhcp = $null
    found_by = $by; login = ''; if_id = '1'; net_xml = ''; net_json = ''; dns_json = ''; platform_xml = ''; platform_json = ''; platform_enabled = $null; platform_online = $null; platform_has_code = $null; platform_read = $null; net_read = $null; dns_read = $null
    channels = $null; channels_read = $null; status_read = $null; channel_of = ''; channel_id = ''; activated = ''; poe = $false; onvif = $false; onvif_token = ''; snap_ip = ''; target_ip = '' }
  if ($d.vendor -eq 'Hikvision') { $d.brand = 'hik' } elseif ($d.vendor -eq 'Uniview') { $d.brand = 'unv' }
  $script:devs.Add($d); return $d
}
function Dev-ByMac([string]$mac) { $mac = NormMac $mac; if (-not $mac) { return $null }; return ($script:devs | Where-Object { $_.mac -eq $mac } | Select-Object -First 1) }
function Dev-ByIp([string]$ip) { return ($script:devs | Where-Object { $_.ip -eq $ip } | Select-Object -First 1) }
function Merge-Dev($src) {
  # 2.2.19 (class A): a record found at the same address is only merged when it has no MAC or the same MAC (two devices answering
  # one address are two devices; 2.2.18 merged them and overwrote the first one's MAC)
  $d = Dev-ByMac $src.mac; if (-not $d) { $d2 = Dev-ByIp $src.ip; if ($d2 -and (-not $d2.mac -or -not $src.mac -or (NormMac $d2.mac) -eq (NormMac $src.mac))) { $d = $d2 } }
  if (-not $d) { $d = New-Dev $src.ip $src.mac $src.found_by }
  foreach ($k in 'ip','mask','gw','serial','model','firmware','brand','kind','activated') { if ($src.$k) { $d.$k = $src.$k } }
  if ($src.mac) { $d.mac = $src.mac }; if ($src.dhcp -ne $null) { $d.dhcp = $src.dhcp; $d.addressing = $(if ($src.dhcp) { 'dhcp' } else { 'static' }) }
  if ($d.found_by -notmatch [regex]::Escape($src.found_by)) { $d.found_by = ($d.found_by + ', ' + $src.found_by).Trim(', ') }
  return $d
}
function Is-Poe([string]$ip) { foreach ($p in $cfg.poe_internal_subnets) { if ((P3 $ip) -eq $p) { return $true } }; return $false }
function Is-Private([string]$ip) { return ($ip -match '^10\.' -or $ip -match '^192\.168\.' -or $ip -match '^172\.(1[6-9]|2[0-9]|3[01])\.') }
function Short($d) { $n = $(if ($d.kind -eq 'nvr') { 'NVR' } elseif ($d.channel_id) { 'Camera D' + $d.channel_id } elseif ($d.kind -eq 'camera') { 'Camera' } else { 'Device' }); return ($n + ' ' + $d.ip + $(if ($d.model) { ' (' + $d.model + ')' } else { '' })) }
# 2.2.13 (Codex #2): what the tool's own read shows is still wrong or unread on the recorders it logged in to. Used when there is
# nothing the tool can change automatically (and in Check mode), so a run that SAW a problem never ends on the green all-right line.
function Get-FnHealthProblems($nvrList) {
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($n in @($nvrList)) {
    if (-not $n -or $n.login -ne 'ok') { continue }
    $nm = 'NVR ' + $n.ip
    if ($n.platform_enabled -eq $false) { $out.Add($nm + ': platform access (Hik-Connect / EZCloud) is OFF') }
    elseif ($n.platform_enabled -eq $null) { $out.Add($nm + ': platform access could not be read - NOT CHECKED') }
    elseif ($n.brand -eq 'unv') { if ($n.platform_online -ne $true) { $out.Add($nm + ': EZCloud online status NOT CHECKED (the tool cannot read it; check the EZView app)') } }
    elseif ($n.platform_online -ne $true) { $out.Add($nm + ': platform access is on but OFFLINE (the app will not work)') }
    if ($n.channels_read -eq $false) { $out.Add($nm + ': the camera list could not be read - cameras NOT CHECKED'); continue }
    $chs = @($n.channels | Where-Object { $_ })
    if (-not $chs.Count) { continue }
    if ($n.status_read -eq $false) { $out.Add($nm + ': the camera status could not be read - ' + $chs.Count + ' camera(s) NOT CHECKED'); continue }
    $offl = @($chs | Where-Object { $_.online -eq $false })
    $unk = @($chs | Where-Object { $_.online -ne $true -and $_.online -ne $false })
    if ($offl.Count) { $out.Add($nm + ': ' + $offl.Count + ' of ' + $chs.Count + ' camera(s) OFFLINE (' + (($offl | ForEach-Object { 'D' + $_.id }) -join ' ') + ')') }
    if ($unk.Count) { $out.Add($nm + ': ' + $unk.Count + ' camera(s) with no online status - NOT CHECKED (' + (($unk | ForEach-Object { 'D' + $_.id }) -join ' ') + ')') }
  }
  return $out.ToArray()
}
function Read-Dev($d) {
  if ($d.login -eq 'ok' -or $d.login -like 'REFUSED*' -or $d.login -like 'DIFFERENT DEVICE*') { return }
  if ($d.brand -ne 'unv') { if (Hik-Read $d) { return } }
  if ($d.login -like 'REFUSED*' -or $d.login -like 'DIFFERENT DEVICE*') { return }
  if ($d.brand -ne 'hik') { if (Unv-Read $d) { [void](Onvif-Read $d); return } }
  if ($d.login -like 'DIFFERENT DEVICE*') { return }
  if ($d.kind -ne 'nvr' -and -not $d.login) { [void](Onvif-Read $d) }
}
# ---------------- 2.2.18 (Codex 2.2.17 #1): device identity before every write, and settings read back after it ----------------
# A write (camera / NVR network, NVR camera list) goes only to a device whose OWN answer, read right before the write, gives the MAC
# saved for it (and the serial, when the undo file has one). There is no fall-back to "whatever answers at the saved address".
function Test-FnMacConflict($dev, [string]$got) {
  if (-not $got -or -not $dev.mac) { return $false }
  return ((NormMac ([string]$dev.mac)) -ne (NormMac $got))
}
function Set-FnDifferentDevice($dev, [string]$got) {
  SetP $dev 'id_mismatch' $got
  $dev.login = 'DIFFERENT DEVICE (it says MAC ' + $got + ', expected ' + $dev.mac + ')'
  Log ('device at ' + $dev.ip + ' says MAC ' + $got + ', expected ' + $dev.mac + ': a different device, not read and not changed')
}
# a fresh, separate record for reading the device at an address right before a write (never the record of another device there)
function New-FnProbe([string]$ip, [string]$mac, [string]$kind, [string]$brand) {
  $p = New-Dev $ip $mac 'identity check'; [void]$script:devs.Remove($p)
  $p.kind = $kind; if ($brand) { $p.brand = $brand }
  return $p
}
# '' = this is the device; otherwise the reason (plain words) why the tool cannot be sure it is
# 2.2.19 (Codex 2.2.18 F24): a record with a MAC is checked strictly by MAC (and serial when both are known); a record that has ONLY
# a serial is checked by an exact, non-empty serial in the device's own fresh answer. Never by address. Nothing saved = refused.
function Get-FnIdentityWhy($d, [string]$expMac, [string]$expSerial) {
  if (-not $expMac -and -not $expSerial) { return 'the tool has no MAC or serial saved for this device, so it cannot check it is the same one' }
  if (-not $expMac) {
    if ([string]$d.login -like 'DIFFERENT DEVICE*') { return ('a DIFFERENT device answers at ' + $d.ip + ' (it says MAC ' + $d.id_mismatch + ')') }
    if ([string]$d.login -notlike 'ok*') { return ('the device at ' + $d.ip + ' could not be read (' + $(if ($d.login) { $d.login } else { 'no answer' }) + ')') }
    if (-not [string]$d.serial) { return ('the device at ' + $d.ip + ' did not say its serial number, and only a serial was saved for this device, so the tool cannot check it is the same one') }
    if ([string]$d.serial -cne [string]$expSerial) { return ('a DIFFERENT device answers at ' + $d.ip + ' (serial ' + $d.serial + ', expected ' + $expSerial + ')') }
    return ''
  }
  if ([string]$d.login -like 'DIFFERENT DEVICE*') { return ('a DIFFERENT device answers at ' + $d.ip + ' (it says MAC ' + $d.id_mismatch + ', expected ' + (NormMac $expMac) + ')') }
  if ([string]$d.login -notlike 'ok*') { return ('the device at ' + $d.ip + ' could not be read (' + $(if ($d.login) { $d.login } else { 'no answer' }) + ')') }
  if (-not $d.id_mac) { return ('the device at ' + $d.ip + ' did not say its MAC, so the tool cannot check it is the same one') }
  if ((NormMac ([string]$d.id_mac)) -ne (NormMac $expMac)) { return ('a DIFFERENT device answers at ' + $d.ip + ' (MAC ' + $d.id_mac + ', expected ' + (NormMac $expMac) + ')') }
  if ($expSerial -and $d.serial -and [string]$d.serial -ne $expSerial) { return ('a DIFFERENT device answers at ' + $d.ip + ' (serial ' + $d.serial + ', expected ' + $expSerial + ')') }
  return ''
}
function Read-FnIdentity([string]$ip, [string]$mac, [string]$kind, [string]$brand, [string]$serial) {
  $p = New-FnProbe $ip $mac $kind $brand; Read-Dev $p
  return @{ dev = $p; why = (Get-FnIdentityWhy $p $mac $serial) }
}
# ONVIF settings read back: address + prefix, addressing mode, default gateway, DNS (each '' when it could not be read)
# 2.2.19 (Codex 2.2.18 F10/F12): the mode (<DHCP>true/false</DHCP>) is read too, and read=true only when EVERY part answered: the
# interface (with its address and its mode), the gateway call and the DNS call. dns1 / dns2 are the fixed DNS servers in order
# ('' = none set, a real value); dns_extra counts any beyond two.
function Onvif-ReadNet($dev) {
  $c = Cred-For $dev; $o = @{ ip = ''; mask = ''; gw = ''; dns = @(); dns1 = ''; dns2 = ''; dns_extra = 0; mode = ''; mac = ''; read = $false }
  $r = Onvif $dev.ip '<tds:GetNetworkInterfaces/>' $c
  if ($r.code -ne 200) { return $o }
  $o.mac = NormMac (XVal $r.body 'HwAddress')
  $v4 = [regex]::Match($r.body, '(?s)<(?:\w+:)?IPv4>.*?</(?:\w+:)?IPv4>').Value
  $dh = XVal $v4 'DHCP'; if ($dh -match '^(?i)true$') { $o.mode = 'dhcp' } elseif ($dh -match '^(?i)false$') { $o.mode = 'static' }
  $blk = $(if ($o.mode -eq 'dhcp') { 'FromDHCP' } else { 'Manual' })
  $m = [regex]::Match($r.body, '(?s)<(?:\w+:)?' + $blk + '>.*?<(?:\w+:)?Address>([^<]+)</(?:\w+:)?Address>.*?<(?:\w+:)?PrefixLength>(\d+)<')
  if ($m.Success) { $o.ip = $m.Groups[1].Value.Trim(); $o.mask = PrefixToMask ([int]$m.Groups[2].Value) }
  $g = Onvif $dev.ip '<tds:GetNetworkDefaultGateway/>' $c; if ($g.code -eq 200) { $o.gw = XVal $g.body 'IPv4Address' }
  $dn = Onvif $dev.ip '<tds:GetDNS/>' $c
  if ($dn.code -eq 200) { $o.dns = @([regex]::Matches($dn.body, '(?s)<(?:\w+:)?DNSManual>.*?<(?:\w+:)?IPv4Address>([^<]*)<') | ForEach-Object { $_.Groups[1].Value.Trim() } | Where-Object { $_ }) }
  if ($o.dns.Count -ge 1) { $o.dns1 = [string]$o.dns[0] }; if ($o.dns.Count -ge 2) { $o.dns2 = [string]$o.dns[1] }; $o.dns_extra = [math]::Max(0, $o.dns.Count - 2)
  # 2.2.20 (Codex 2.2.19 R09 / R12 class C twin): each answer must be the expected ONVIF document carrying the part it is read for
  # (the interface list, a NetworkGateway element, a DNSInformation element) and no SOAP Fault; HTTP 200 alone proves nothing
  $o.read = [bool]($o.ip -and $o.mode -and $r.body -match 'GetNetworkInterfacesResponse' -and $r.body -notmatch '<(\w+:)?Fault[\s>]' -and $g.code -eq 200 -and $g.body -match 'GetNetworkDefaultGatewayResponse' -and $g.body -match '<(\w+:)?NetworkGateway[\s>/]' -and $g.body -notmatch '<(\w+:)?Fault[\s>]' -and $dn.code -eq 200 -and $dn.body -match 'GetDNSResponse' -and $dn.body -match '<(\w+:)?DNSInformation[\s>/]' -and $dn.body -notmatch '<(\w+:)?Fault[\s>]')
  return $o
}

# 2.2.19 (Codex 2.2.18 F10/F11/F12, class C/D): the device's whole network setting as its OWN fresh answer gives it: address, mode
# ('dhcp' / 'static'), mask, gateway, DNS 1, DNS 2 ('' = none set, a real value). read=$false (with why) when any part could not be
# read - a missing address or mode is "not read", never "matches".
function Get-FnNetNow($d) {
  $o = @{ read = $false; why = ''; ip = ''; mode = ''; mask = ''; gw = ''; dns1 = ''; dns2 = ''; extra = 0 }
  if ($d.brand -eq 'hik') {
    if ($d.net_read -ne $true) { $o.why = 'its network settings could not be read'; return $o }
    $o.ip = [string]$d.net_ip; $o.mode = Get-FnAddrMode $d.addressing; $o.mask = [string]$d.mask; $o.gw = [string]$d.gw; $o.dns1 = NormDns $d.dns1; $o.dns2 = NormDns $d.dns2
    # 2.2.20 (Codex 2.2.19 R09): the answer must CARRY a gateway field (an empty one is a real "none"); a record that does not say
    # which fields the answer carried counts a field as carried only when it has a value
    $has = $(if ($d.PSObject.Properties['net_has'] -and $d.net_has -is [hashtable]) { $d.net_has } else { @{ mask = [bool]$o.mask; gw = [bool]$o.gw } })
    if (-not $has.mask -or -not $o.mask) { $o.why = 'its network answer did not give its subnet mask'; return $o }
    if (-not $has.gw) { $o.why = 'its network answer has no gateway field'; return $o }
  } elseif ($d.brand -eq 'unv' -and [string]$d.login -eq 'ok' -and $d.kind -eq 'nvr') {
    if ($d.net_read -ne $true -or $d.dns_read -ne $true) { $o.why = 'its network settings could not be read'; return $o }
    $nd = Unv-Data $d.net_json
    $ia = @(Find-JsonVals $nd '(?i)^(IPv4)?(IP)?Address$'); $ma = @(Find-JsonVals $nd '(?i)(Sub)?net ?mask$'); $ga = @(Find-JsonVals $nd '(?i)(Default)?Gateway$')
    $o.ip = $(if ($ia.Count) { [string]$ia[0] } else { '' }); $o.mask = $(if ($ma.Count) { [string]$ma[0] } else { '' }); $o.gw = $(if ($ga.Count) { [string]$ga[0] } else { '' })
    $o.mode = Get-FnUnvMode $nd; $o.dns1 = NormDns $d.dns1; $o.dns2 = NormDns $d.dns2
    if (-not $ma.Count -or -not $ga.Count) { $o.why = 'its network answer has no mask or gateway field the tool can read'; return $o }
  } elseif ($d.onvif -or (Onvif-Read $d)) {
    $n = Onvif-ReadNet $d
    if (-not $n.read) { $o.why = 'its network settings could not be read (ONVIF)'; return $o }
    $o.ip = [string]$n.ip; $o.mode = [string]$n.mode; $o.mask = [string]$n.mask; $o.gw = [string]$n.gw; $o.dns1 = NormDns $n.dns1; $o.dns2 = NormDns $n.dns2; $o.extra = [int]$n.dns_extra
  } else { $o.why = 'its network settings could not be read'; return $o }
  if (-not $o.ip) { $o.why = 'its network answer did not give its address'; return $o }
  if (-not $o.mode) { $o.why = 'its network answer did not say whether it uses DHCP or a fixed address'; return $o }
  # 2.2.20 (Codex 2.2.19 R09, class C, every brand): a mask is always part of a device's address setting. A missing, empty or invalid
  # one = not read (2.2.19 returned read=True and the backup kept no real old mask for Undo).
  if (-not (Test-FnMask $o.mask)) { $o.why = $(if ($o.mask) { 'its network answer gives a subnet mask the tool cannot read ("' + $o.mask + '")' } else { 'its network answer did not give its subnet mask' }); return $o }
  if ($o.gw -and $o.gw -ne '0.0.0.0' -and -not (Test-FnIpv4 $o.gw)) { $o.why = ('its network answer gives a gateway the tool cannot read ("' + $o.gw + '")'); return $o }
  $o.read = $true; return $o
}
# 2.2.20 (R09): a real dotted subnet mask (contiguous, /1 to /32)
function Test-FnMask($m) {
  if (-not (Test-FnIpv4 ([string]$m))) { return $false }
  $n = IpToInt ([string]$m); if ($n -eq 0) { return $false }
  $inv = ([uint32]4294967295 - [uint32]$n); return ((([uint64]$inv + 1) -band [uint64]$inv) -eq 0)
}
# '' = every field below matches; otherwise the list of differences. $want: ip, mode, mask, gw, dns1, dns2 (all compared, '' included)
function Get-FnNetDiff($now, $want, [string]$w = 'set') {
  $bad = @()
  if ([string]$now.ip -ne [string]$want.ip) { $bad += ('address ' + $(if ($now.ip) { $now.ip } else { '(none)' }) + ' (' + $w + ' ' + $want.ip + ')') }
  if ((Get-FnAddrMode $now.mode) -ne (Get-FnAddrMode $want.mode)) { $bad += ('addressing ' + $(if ($now.mode) { $now.mode } else { '(unknown)' }) + ' (' + $w + ' ' + $(if ($want.mode) { $want.mode } else { '(unknown)' }) + ')') }
  if ([string]$now.mask -ne [string]$want.mask) { $bad += ('mask ' + $now.mask + ' (' + $w + ' ' + $want.mask + ')') }
  if ([string]$now.gw -ne [string]$want.gw) { $bad += ('gateway ' + $(if ($now.gw) { $now.gw } else { '(none)' }) + ' (' + $w + ' ' + $(if ($want.gw) { $want.gw } else { '(none)' }) + ')') }
  if ((NormDns $now.dns1) -ne (NormDns $want.dns1)) { $bad += ('DNS ' + $(if ($now.dns1) { $now.dns1 } else { '(none)' }) + ' (' + $w + ' ' + $(if ($want.dns1) { $want.dns1 } else { '(none)' }) + ')') }
  if ((NormDns $now.dns2) -ne (NormDns $want.dns2)) { $bad += ('DNS 2 ' + $(if ($now.dns2) { $now.dns2 } else { '(none)' }) + ' (' + $w + ' ' + $(if ($want.dns2) { $want.dns2 } else { '(none)' }) + ')') }
  if ($now.extra) { $bad += ('' + $now.extra + ' extra DNS server(s)') }
  return ($bad -join ', ')
}
# 2.2.18 (Codex 2.2.17 #3 twin) / 2.2.19 (Codex 2.2.18 F12): a network change counts only when the device, identified at the NEW
# address (by MAC, or by serial for a serial-only record), reads back EVERY requested setting - address, mode, mask, gateway, both DNS
# (empty included). A field the answer does not carry = NOT CHECKED, never "matches".
function Get-FnNetReadBackWhy([string]$ip, [string]$mac, [string]$kind, [string]$brand, [string]$mask, [string]$gw, [string]$d1, [string]$d2, [string]$serial = '', [string]$mode = 'static') {
  $id = Read-FnIdentity $ip $mac $kind $brand $serial
  if ($id.why) { return $id.why }
  $now = Get-FnNetNow $id.dev
  if (-not $now.read) { return ($now.why + ' on ' + $ip + ' - NOT CHECKED') }
  $diff = Get-FnNetDiff $now @{ ip = $ip; mode = $mode; mask = $mask; gw = $gw; dns1 = $d1; dns2 = $d2 }
  if ($diff) { return ('the settings read back are NOT what was set: ' + $diff) }
  return ''
}
function Wait-FnNetReadBack([string]$ip, [string]$mac, [string]$kind, [string]$brand, [string]$mask, [string]$gw, [string]$d1, [string]$d2, [string]$serial, [int]$seconds) {
  $why = 'no answer on ' + $ip
  $tries = [math]::Max(1, [int][math]::Ceiling($seconds / 10)); if ($Mock) { $tries = [math]::Min($tries, 2) }
  for ($k = 0; $k -lt $tries; $k++) {
    if ($k -gt 0) { Start-Sleep -Seconds $(if ($Mock) { 0 } else { 10 }) }
    $why = Get-FnNetReadBackWhy $ip $mac $kind $brand $mask $gw $d1 $d2 $serial 'static'
    if (-not $why) { return '' }
    if ($why -like 'the settings read back*' -or $why -like 'a DIFFERENT device*') { return $why }
  }
  return $why
}
# 2.2.19 (Codex 2.2.18 F04 twin, class B): forward, the device's network setting is read again AFTER the YES (on the fresh identity
# read) and must be exactly what the plan showed and the undo file saved - address, mode, mask, gateway, both DNS. Changed since, or
# not readable now (so Undo could not put it back) = '' is NOT returned and nothing is sent.
function Get-FnBackupWhy($st, $fresh) {
  $now = Get-FnNetNow $fresh
  if (-not $now.read) { return ($now.why + ' just before the change, so Undo could not put it back') }
  $was = @{ ip = [string]$st.old_ip; mode = $(if ($st.PSObject.Properties['old_addressing']) { [string]$st.old_addressing } else { '' }); mask = [string]$st.old_mask; gw = [string]$st.old_gw; dns1 = [string]$st.old_dns1; dns2 = [string]$st.old_dns2 }
  if (-not (Get-FnAddrMode $was.mode)) { return 'the plan did not know whether it uses DHCP or a fixed address, so Undo could not put that back' }
  $diff = Get-FnNetDiff $now $was 'plan:'
  if ($diff) { return ('its network settings changed after the plan was shown (' + $diff + '); run Fix again so the plan and the undo file match the device') }
  return ''
}
# 2.2.19 (Moshe's decision, Codex 2.2.18 F13 twin): after a DHCP Undo the router picks the address, so the device is looked for again
# BY ITS MAC (the same SADP search the tool starts with), identified at the address it answers from, and must read back DHCP there.
# Anything less = ok $false with the reason (the Undo stays NOT RESTORED). Only Hikvision answers SADP; others are not found = NOT CHECKED.
function Find-FnDhcpBack([string]$mac, [string]$serial, [string]$kind, [string]$brand, [int]$seconds) {
  $km = NormMac $mac
  if (-not $km) { return @{ ok = $false; ip = ''; why = 'the tool has no MAC for it, so it cannot find it again on the network' } }
  $why = 'it was not found again by its MAC on the network'
  $tries = [math]::Max(1, [int][math]::Ceiling($seconds / 10)); if ($Mock) { $tries = [math]::Min($tries, 2) }
  $from = @(); if ($pc -and $pc.ip) { $from += [string]$pc.ip }; foreach ($t in @($tempIps)) { if ($t) { $from += [string]$t } }
  for ($k = 0; $k -lt $tries; $k++) {
    if ($k -gt 0) { Start-Sleep -Seconds $(if ($Mock) { 0 } else { 10 }) }
    $found = $null; try { $found = Find-Sadp $from } catch { $found = $null; $why = 'the network search for it did not work (' + $_.Exception.Message + ')'; continue }
    $hit = $null; if ($found) { foreach ($fk in @($found.Keys)) { if ((NormMac ([string]$fk)) -eq $km -or (NormMac ([string]$found[$fk].mac)) -eq $km) { $hit = $found[$fk]; break } } }
    if (-not $hit -or -not $hit.ip) { $why = 'it was not found again by its MAC on the network'; continue }
    $id = Read-FnIdentity ([string]$hit.ip) $mac $kind $brand $serial
    if ($id.why) { $why = $id.why; continue }
    $now = Get-FnNetNow $id.dev
    if (-not $now.read) { $why = ($now.why + ' on ' + $hit.ip); continue }
    if ($now.mode -ne 'dhcp') { return @{ ok = $false; ip = [string]$hit.ip; why = ('it answers at ' + $hit.ip + ' (same MAC) but reads back ' + $now.mode + ', not DHCP') } }
    if ($now.ip -ne [string]$hit.ip) { $why = ('it answers at ' + $hit.ip + ' but says its address is ' + $now.ip); continue }
    return @{ ok = $true; ip = [string]$hit.ip; why = '' }
  }
  return @{ ok = $false; ip = ''; why = $why }
}
function Wait-Answer([string]$ip, [int]$seconds, $cred) {
  $end = (Get-Date).AddSeconds($seconds)
  while ((Get-Date) -lt $end) {
    $r = Http $ip 'GET' '/ISAPI/System/deviceInfo' '' 'application/xml' $cred 5
    if ($r.code -eq 200) { return $true }
    $r = Http $ip 'GET' '/LAPI/V1.0/System/DeviceBasicInfo' '' 'application/json' $cred 5
    if ($r.code -eq 200) { return $true }
    Start-Sleep -Seconds 5
  }
  return $false
}

# ---------------- router DHCP range (WireIt standard: router hands out .100 and up) ----------------
function Router-Step([string]$gw, [int]$prefix) {
  $p3 = P3 $gw; $lines = @()
  switch -regex ($gw) {
    '^10\.0\.0\.1$'       { $lines += ('Xfinity home router (10.0.0.1): in the Xfinity app turn on WiFi > View WiFi equipment > Advanced settings > Admin Tool online access. Then open http://10.0.0.1 > Gateway > Connection > Local IP Network and set the DHCP range to 10.0.0.100 - 10.0.0.253. Save.') }
    '^10\.1\.10\.1$'      { $lines += ('Comcast Business router (10.1.10.1): open http://10.1.10.1 (user cusadmin, password on the sticker) > DHCP settings: change the start address from 10.1.10.10 to 10.1.10.100 (end 10.1.10.199 or higher). Save.') }
    '^192\.168\.4\.1$'    { $lines += ('eero (192.168.4.1): eero app only: Settings > Network settings > DHCP & NAT > Manual IP. Set mask 255.255.255.0 and the range to start at 192.168.4.100. eero defaults to a /22 mask: check it.') }
    '^192\.168\.68\.1$'   { $lines += ('TP-Link Deco (192.168.68.1): Deco app > More > Advanced > DHCP Server: set the range to start at 192.168.68.100. Deco defaults to a /22 mask: check it.') }
    '^192\.168\.86\.1$'   { $lines += ('Google Nest Wifi (192.168.86.1): Google Home app > Wi-Fi > Settings > Advanced networking > DHCP IP range: set it to 192.168.86.100 - 192.168.86.250.') }
    '^192\.168\.(1|254)\.254$' { $lines += ('Frontier / AT&T-style router (' + $gw + '): open http://' + $gw + ' (device access code on the sticker) > Home Network > Subnets & DHCP: set the DHCP range to ' + $p3 + '.100 - ' + $p3 + '.253. Save.') }
    default               { $lines += ('Router ' + $gw + ': open http://' + $gw + ' (login on the router sticker) > LAN / DHCP settings: set the DHCP range to ' + $p3 + '.100 - ' + $p3 + '.254. Save.') }
  }
  if ($prefix -ne 24) { $lines += ('The router uses a /' + $prefix + ' mask (' + (PrefixToMask $prefix) + '), not 255.255.255.0. eero and TP-Link Deco do this by default. The NVR and cameras must use the same mask as the router.') }
  $lines += 'Menu names can differ by model. If you cannot get into the router, reserve the NVR''s address in the router/app instead and type "reserved" when NVR Snapshot asks for the DHCP range.'
  return $lines
}
function Show-RouterStep([string]$why) {
  Say ''; Say ('ROUTER STEP NEEDED: ' + $why) 'Yellow'
  Say ('  WireIt standard: router hands out .' + [int]$cfg.router_dhcp_start + ' and up; ours are below it (NVR .' + ([int]@($cfg.nvr_hosts)[0]) + ', switch cameras .' + [int]$cfg.camera_block_start + '-.' + [int]$cfg.camera_block_end + ', other WireIt gear .10-.19).') 'Yellow'
  foreach ($l in (Router-Step $pc.gw $pc.prefix)) { Say ('  - ' + $l) 'Yellow' }
}
function Range-Start([string]$r) {
  # "100-254", ".100-.254", "10.0.0.100 - 10.0.0.253" -> 100 ; nothing usable -> -1
  if (-not $r) { return -1 }
  $m = [regex]::Match($r, '(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})'); if ($m.Success) { return [int]$m.Groups[4].Value }
  $m = [regex]::Match($r, '(\d{1,3})'); if ($m.Success) { return [int]$m.Groups[1].Value }
  return -1
}

# ---------------- snapshot files ----------------
function Find-SiteFolder([string]$site) {
  if (-not $site) { return $null }
  foreach ($root in $cfg.snapshot_roots) {
    $r = [Environment]::ExpandEnvironmentVariables($root)
    if (-not (Test-Path $r)) { continue }
    $f = Get-ChildItem $r -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $site } | Select-Object -First 1
    if (-not $f) { $f = Get-ChildItem $r -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like ('*' + $site + '*') } | Select-Object -First 1 }
    if ($f) { return $f.FullName }
  }
  return $null
}
function Load-Snapshot {
  $p = $Snapshot
  if (-not $p -and $Site) {
    $folders = @(); $sf = Find-SiteFolder $Site; if ($sf) { $folders += (Join-Path $sf $cfg.snapshot_subfolder); $folders += $sf }
    $folders += (Join-Path $here 'snapshots')
    foreach ($f in $folders) { $c = Get-ChildItem $f -Filter 'FixNVR snapshot*.json' -ErrorAction SilentlyContinue | Where-Object { $_.Name -like ('*' + $Site + '*') -or $f -ne (Join-Path $here 'snapshots') } | Sort-Object Name -Descending | Select-Object -First 1; if ($c) { $p = $c.FullName; break } }
  }
  if (-not $p -or -not (Test-Path $p)) { return $null }
  Say ('Using known-good snapshot: ' + $p)
  return (Get-Content $p -Raw | ConvertFrom-Json)
}

# =====================================================================================
#  MAIN
# =====================================================================================
Write-Host ''
Write-Host ('=== WireIt Fix NVR ' + $Version + ' | mode ' + $Mode + ' | ' + (Get-Date -Format 'yyyy-MM-dd HH:mm') + ' on ' + $env:COMPUTERNAME + ' ===') -ForegroundColor Cyan
Log ('start mode=' + $Mode + ' site=' + $Site + ' ps=' + $PSVersionTable.PSVersion)
$script:leftoverOk = Invoke-LeftoverCleanup
if ($Mode -eq 'Cleanup') { if ($script:leftoverOk) { Write-Host 'Cleanup done.'; exit 0 } else { exit 6 } }
# 2.2.10 (Codex R04): an earlier run's change that could not be put back stops this run before anything else changes
if (-not $script:leftoverOk) { exit 6 }
if (-not $Mock) {
  $adm = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if (-not $adm) { Say 'Please run as administrator (right-click "Fix NVR.cmd" > Run as administrator). The tool needs it to reach devices on the old IP scheme.' 'Red'; exit 2 }
}
$pc = Get-PcNet; $script:pcNet = $pc
if (-not $pc -or -not $pc.ip -or -not $pc.gw) { Say 'This PC has no working network connection with a router. Plug it into the site network and run again.' 'Red'; exit 2 }
$newP3 = P3 $pc.gw; $newMask = PrefixToMask $pc.prefix
Say ('This PC: ' + $pc.ip + '/' + $pc.prefix + ' on "' + $pc.alias + '", router (gateway) ' + $pc.gw + $(if ($pc.wifi) { '  [Wi-Fi: works, a cable is better]' } else { '' }))
Say ('Current IP scheme: ' + $newP3 + '.x  (mask ' + $newMask + ')')
$rb = $null; if ($Mode -eq 'Rollback') {
  if (-not $RollbackFile -or -not (Test-Path $RollbackFile)) { Say 'Rollback needs -RollbackFile <path to rollback.json from the Fix run>.' 'Red'; exit 2 }
  # 2.2.20 (Codex 2.2.19 class E sweep, the R08 twin for the undo file): the undo file is a recovery journal. It is read with errors
  # stopping, and its whole structure and every field TYPE are checked before Undo sends anything; a damaged file = NOTHING is sent.
  try { $rb = Get-Content -LiteralPath $RollbackFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch { $rb = $null }
  $rbWhy = $(if (-not $rb) { 'could not be read (not valid JSON)' } else { Get-FnRollbackWhy $rb })
  if ($rbWhy) { Say ('Undo did NOT start: the undo file ' + $RollbackFile + ' ' + $rbWhy + '. Nothing was sent to any device. Undo the changes by hand from the run''s plan.json / summary.txt.') 'Red'; Log ('rollback file refused: ' + $rbWhy); exit 2 }
}
$snap = $null; if ($Mode -ne 'Rollback') { $snap = Load-Snapshot }
$script:routerStepShown = $false
if ($Mode -ne 'Rollback') {
  if ($snap -and ($snap.router_model -or $snap.router_dhcp_range)) { Say ('At install (snapshot ' + $snap.taken + '): router ' + $(if ($snap.router_model) { $snap.router_model } else { '?' }) + ' at ' + $snap.router + ', DHCP range ' + $(if ($snap.router_dhcp_range) { $snap.router_dhcp_range } else { 'not recorded' })) }
  $lowLease = ($pc.dhcp -and (((P3 $pc.ip) -eq $newP3 -and (Last $pc.ip) -lt [int]$cfg.router_dhcp_start) -or ($pc.prefix -lt 24 -and (P3 $pc.ip) -ne $newP3)))
  if ($lowLease) { Show-RouterStep ('this PC got ' + $pc.ip + ' from the router, so the router still hands out addresses below .' + [int]$cfg.router_dhcp_start + '. One day it could give the NVR''s or a camera''s address to a phone (double IP).'); $script:routerStepShown = $true }
  elseif ($snap -and $snap.router -and $snap.router -ne $pc.gw) { Show-RouterStep ('the router changed since install (was ' + $snap.router + ', now ' + $pc.gw + '). A new router starts with its factory DHCP range.'); $script:routerStepShown = $true }
  elseif ($pc.prefix -ne 24) { Say ('Note: the router uses a /' + $pc.prefix + ' mask (' + $newMask + '). eero and TP-Link Deco do this by default; the NVR and cameras will get the same mask.') 'Yellow' }
}
$plan = New-Object System.Collections.Generic.List[object]
$applied = New-Object System.Collections.Generic.List[object]
$script:exitCode = 0
function Invoke-CamViews($list) {
  # last known view of each camera (Toolkit CamViews.ps1, read-only). Never fails the run.
  $site0 = $Site; $mock0 = $Mock
  $cv = Join-Path (Split-Path -Parent $here) 'Toolkit\CamViews.ps1'
  if ($mock0) { if (-not $mock0.camviews) { return }; $cv = [string]$mock0.camviews }
  if (-not (Test-Path $cv)) { Say ''; Say 'Camera pictures: skipped (the Toolkit''s CamViews.ps1 is not on this PC).' 'Yellow'; return }
  if (-not $site0) { Say ''; Say 'Camera pictures: skipped - no site given (type the Site ID, e.g. WI-061, in the Toolkit''s Site box).' 'Yellow'; return }
  $ok = @($list | Where-Object { $_.login -eq 'ok' -and $_.brand -in @('hik', 'unv') })
  if (-not $ok.Count) { Say ''; Say 'Camera pictures: skipped - no NVR login.' 'Yellow'; return }
  try {
    . $cv -Lib
    if ($mock0) { $script:CvApi = $mock0.url + '/api'; $script:CvMock = $mock0.url }
    $i = 0
    foreach ($n in $ok) { $i++; [void](Save-CameraViews -Nvr $n.ip -Cred $script:credNvr -Site $site0 -Vendor $(if ($n.brand -eq 'unv') { 'uniview' } else { 'hik' }) -RecorderNo $i) }
  } catch { Say ('Camera pictures: did not work (' + $_.Exception.Message + '). Nothing else is affected.') 'Yellow'; Log $_.ScriptStackTrace }
}
function Invoke-Main {
  Open-Firewall
  # ---------- 1. find devices on ANY scheme ----------
  Say ''; Say 'Looking for the NVR and cameras (any IP scheme)...' 'Cyan'
  $sadp = Find-Sadp @($pc.ip)
  foreach ($k in $sadp.Keys) { [void](Merge-Dev $sadp[$k]) }
  $sn = $SniffSeconds; if ($sn -lt 0) { $sn = [int]$cfg.arp_sniff_seconds }
  if ($Mode -eq 'Rollback') { $sn = 0 }
  if ($sn -gt 0) { Write-Host ('  listening ' + $sn + ' s for devices stuck on another scheme...') }
  $arp = Find-ArpSniff $sn
  foreach ($k in $arp.Keys) { $ip = $arp[$k]; if (-not (InNet $ip $pc.ip $pc.prefix) -and (Is-Private $ip)) { $d = Dev-ByMac $k; if (-not $d) { [void](New-Dev $ip $k 'passive listen') } } }
  if ($snap) {
    foreach ($s in @($snap.nvrs) + @($snap.cameras)) { if (-not $s) { continue }; $d = Dev-ByMac $s.mac; if (-not $d) { $d = New-Dev $s.ip $s.mac 'snapshot' }; $d.snap_ip = $s.ip; if (-not $d.kind) { $d.kind = $(if (@($snap.nvrs) -contains $s) { 'nvr' } else { 'camera' }) }; if (-not $d.brand -and $s.brand) { $d.brand = $s.brand }; if ($s.channel) { $d.channel_id = [string]$s.channel } }
  }
  # 2.2.18: an NVR camera-list step records the NVR at the NVR's address (2.2.17 put it at the camera's new address)
  if ($rb) {
    $rbAt = @{}; foreach ($st in @($rb.steps)) { if ($st -and $st.done -and $st.dev_mac -and $st.type -match '^(cam|nvr)-net$') { $rbAt[(NormMac ([string]$st.dev_mac))] = [string]$st.new_ip } }
    foreach ($st in @($rb.steps)) { if ($st.done -and $st.dev_mac) { $d = Dev-ByMac $st.dev_mac; if (-not $d) { $k = NormMac ([string]$st.dev_mac); $at = $(if ($rbAt.ContainsKey($k)) { $rbAt[$k] } elseif ($st.nvr_ip) { [string]$st.nvr_ip } else { [string]$st.new_ip }); $d = New-Dev $at $st.dev_mac 'rollback file' }; $d.kind = $st.kind; $d.brand = $st.brand } }
  }
  if ($Nvr) { $d = Dev-ByIp $Nvr; if (-not $d) { $d = New-Dev $Nvr '' 'given' }; $d.kind = 'nvr' }
  # ---------- 2. old schemes -> temporary PC address ----------
  $old = [ordered]@{}
  foreach ($o in $OldSubnet) { $o = ($o -replace '/\d+$', ''); if (($o -split '\.').Count -eq 4) { $o = P3 $o }; $old[$o] = 99 }
  foreach ($d in $script:devs) { if ($d.ip -and -not (InNet $d.ip $pc.ip $pc.prefix) -and (Is-Private $d.ip) -and -not (Is-Poe $d.ip)) { $p = P3 $d.ip; if ($old.Contains($p)) { $old[$p]++ } else { $old[$p] = 1 } } }
  if ($rb) { foreach ($o in @($rb.old_subnets)) { if (-not $old.Contains($o)) { $old[$o] = 50 } } }
  $old.Remove($newP3)
  $oldList = @($old.Keys | Sort-Object { -$old[$_] } | Select-Object -First ([int]$cfg.max_old_subnets))
  $avoid = @($script:devs | ForEach-Object { $_.ip })
  $tempIps = @()
  foreach ($o in $oldList) {
    $t = Add-TempIp $o $pc $avoid
    if ($t) { $tempIps += $t; Say ('Old scheme ' + $o + '.x found. This PC temporarily also answers on ' + $t + ' to reach it (removed at the end).') }
    else { Say ('Old scheme ' + $o + '.x found, but no free temporary address worked. Devices there can only be listed.') 'Yellow' }
  }
  if ($tempIps.Count) { $s2 = Find-Sadp $tempIps; foreach ($k in $s2.Keys) { [void](Merge-Dev $s2[$k]) } }
  $onv = Find-Onvif (@($pc.ip) + $tempIps)
  foreach ($ip in $onv.Keys) { $d = Dev-ByIp $ip; if (-not $d) { $d = New-Dev $ip '' 'ONVIF search' }; if ($onv[$ip] -match '(?i)uniview|unv') { if (-not $d.brand) { $d.brand = 'unv' } }; if ($onv[$ip] -match '(?i)NVR|recorder') { $d.kind = 'nvr' } }
  # a device with an unknown role on an old scheme that answers like a recorder is checked below
  $nvrs = @($script:devs | Where-Object { $_.kind -eq 'nvr' })
  if (-not $nvrs.Count) {
    $cand = @($script:devs | Where-Object { $_.brand -or $_.found_by -match 'listen' })
    if ($cand.Count) { Say 'No device identified itself as an NVR yet; checking the candidates after login.' 'Yellow' }
  }
  Say ('Found ' + $script:devs.Count + ' device(s): ' + (($script:devs.ToArray() | ForEach-Object { $_.ip + $(if ($_.kind) { ' ' + $_.kind } else { '' }) + $(if (-not (InNet $_.ip $pc.ip $pc.prefix)) { ' [OLD SCHEME]' } else { '' }) }) -join ', '))
  if (-not $script:devs.Count) { Say 'Nothing found. Is this PC on the same network/switch as the NVR? (Wi-Fi guest networks and some mesh systems hide devices.)' 'Red'; $script:exitCode = 3; return }
  if ($NoLogin) {
    Say ''; Say '----- Devices (discovery only, no logins) -----' 'Cyan'
    foreach ($d in $script:devs.ToArray()) { Say ('  ' + $d.ip + ' | ' + $(if ($d.mac) { $d.mac } else { '?' }) + ' | ' + $(if ($d.vendor) { $d.vendor } elseif ($d.brand) { $d.brand } else { '?' }) + ' | ' + $d.kind + ' ' + $d.model + ' ' + $d.serial + ' | found by ' + $d.found_by + $(if (-not (InNet $d.ip $pc.ip $pc.prefix)) { ' | OLD/OTHER SCHEME' } else { '' })) }
    return
  }
  # ---------- 3. log in and read (read-only) ----------
  Get-Creds
  Say ''; Say 'Reading settings (read-only)...' 'Cyan'
  if (-not $nvrs.Count) { foreach ($d in @($script:devs | Where-Object { -not $_.kind })) { Read-Dev $d } ; $nvrs = @($script:devs | Where-Object { $_.kind -eq 'nvr' }) }
  foreach ($n in $nvrs) { Read-Dev $n }
  foreach ($n in $nvrs) {
    if (-not $n.channels) { continue }
    foreach ($ch in $n.channels) {
      if (-not $ch.ip) { continue }
      if (Is-Poe $ch.ip) { $ch.poe = $true; continue }
      $d = Dev-ByIp $ch.ip
      if (-not $d -and $snap) { $s = @($snap.cameras) | Where-Object { $_.channel -eq $ch.id -and $_.ip -eq $ch.ip } | Select-Object -First 1; if ($s) { $d = Dev-ByMac $s.mac } }
      if (-not $d) { $d = New-Dev $ch.ip '' 'NVR camera list'; $d.kind = 'camera' }
      $d.channel_of = $n.ip; $d.channel_id = $ch.id; if (-not $d.kind) { $d.kind = 'camera' }
    }
  }
  foreach ($d in @($script:devs | Where-Object { $_.kind -ne 'nvr' -and ($_.channel_of -or $_.snap_ip -or $Mode -eq 'Snapshot' -or ($MoveUnlisted -and -not (InNet $_.ip $pc.ip $pc.prefix))) -and -not (Is-Poe $_.ip) })) { Read-Dev $d }

  # ---------- 4. report what is wrong ----------
  Say ''; Say '----- What I found -----' 'Cyan'
  foreach ($n in $nvrs) {
    Say ((Short $n) + ' | login ' + $n.login + ' | ' + $(if ($n.addressing) { $n.addressing } else { '?' }) + ' | gateway ' + $n.gw + ' | DNS ' + $n.dns1 + ' ' + $n.dns2)
    if ((InNet $n.ip $pc.ip $pc.prefix) -and (Last $n.ip) -ge [int]$cfg.router_dhcp_start) { Say ('  NOTE: the NVR is at .' + (Last $n.ip) + ', inside the usual router range (.' + [int]$cfg.router_dhcp_start + ' and up). The standard is now .' + ([int]@($cfg.nvr_hosts)[0]) + '. Fix leaves it where it is unless it is on the wrong scheme; move it by hand when convenient, or reserve it in the router.') 'Yellow' }
    if (-not (InNet $n.ip $pc.ip $pc.prefix)) { Say ('  PROBLEM: the NVR is on the OLD scheme (' + (P3 $n.ip) + '.x). The router is now ' + $pc.gw + '.') 'Yellow' }
    elseif ($n.gw -and $n.gw -ne $pc.gw) { Say ('  PROBLEM: NVR gateway is ' + $n.gw + ', router is ' + $pc.gw + '.') 'Yellow' }
    if ($n.login -eq 'ok' -and (-not $n.dns1 -or $n.dns1 -eq '0.0.0.0')) { Say '  PROBLEM: NVR has no DNS server (the app cannot find the cloud).' 'Yellow' }
    if ($n.platform_enabled -eq $false) { Say '  PROBLEM: platform access (Hik-Connect / EZCloud) is turned OFF.' 'Yellow' }
    elseif ($n.platform_enabled -and $n.platform_online -eq $false) { Say '  Platform access is on but shows OFFLINE right now.' 'Yellow' }
    elseif ($n.platform_online) { Say '  Platform access: on and ONLINE.' 'Green' }
    if ($n.login -eq 'ok' -and $n.channels_read -eq $false) { Say '  PROBLEM: the NVR''s camera list could not be read - cameras NOT CHECKED.' 'Yellow' }
    elseif ($n.login -eq 'ok' -and $n.channels -and $n.status_read -eq $false) { Say '  PROBLEM: the NVR''s camera status could not be read - online/offline NOT CHECKED.' 'Yellow' }
    if ($n.channels) { $on = @($n.channels | Where-Object { $_.online }).Count; $poe = @($n.channels | Where-Object { $_.poe }).Count; Say ('  Cameras on the NVR: ' + $n.channels.Count + ' (' + $on + ' online; ' + $poe + ' on the NVR''s own PoE ports, left alone)') }
  }
  if (-not $nvrs.Count) { Say 'No NVR found or identified. Give its address with -Nvr if you know it.' 'Yellow' }
  $wrongCams = @($script:devs | Where-Object { $_.kind -eq 'camera' -and $_.channel_of -and -not (InNet $_.ip $pc.ip $pc.prefix) -and -not (Is-Poe $_.ip) })
  if ($wrongCams.Count) { Say ('  PROBLEM: ' + $wrongCams.Count + ' switch camera(s) on the OLD scheme: ' + (($wrongCams | ForEach-Object { 'D' + $_.channel_id + ' ' + $_.ip }) -join ', ')) 'Yellow' }
  $inact = @($script:devs | Where-Object { $_.activated -eq 'false' })
  if ($inact.Count) { Say ('  Not activated (factory reset, no password yet): ' + (($inact | ForEach-Object { $_.ip }) -join ', ') + '. Activate it in HiTools/SADP first.') 'Yellow' }
  $loose = @($script:devs | Where-Object { $_.kind -ne 'nvr' -and -not $_.channel_of -and -not (InNet $_.ip $pc.ip $pc.prefix) })
  if ($loose.Count) { Say ('  Also on an old scheme but NOT on the NVR''s camera list' + $(if ($MoveUnlisted) { ' (will be moved: -MoveUnlisted)' } else { ' (left alone; add -MoveUnlisted to move them)' }) + ': ' + (($loose | ForEach-Object { $_.ip + $(if ($_.vendor) { ' ' + $_.vendor } else { '' }) }) -join ', ')) }
  $ref = @($script:devs | Where-Object { $_.login -like 'REFUSED*' }); if ($ref.Count) { Say ('  Login refused (not retried, so nothing gets locked): ' + (($ref | ForEach-Object { $_.ip }) -join ', ')) 'Yellow' }

  # ---------- PICTURES mode: last known view of each camera (read-only) ----------
  if ($Mode -eq 'Pictures') { Invoke-CamViews $nvrs; return }
  # ---------- SNAPSHOT mode: record known-good + install standard check ----------
  if ($Mode -eq 'Snapshot') {
    $chk = New-Object System.Collections.Generic.List[string]
    function Chk([bool]$ok, [string]$what) { $chk.Add($(if ($ok) { 'PASS ' } else { 'FIX  ' }) + $what); Say ($(if ($ok) { '  PASS  ' } else { '  FIX   ' }) + $what) $(if ($ok) { 'Green' } else { 'Yellow' }) }
    Say ''; Say '----- NVR install standard -----' 'Cyan'
    foreach ($n in $nvrs) {
      Chk ($n.addressing -eq 'static') ('NVR ' + $n.ip + ' uses a static address')
      Chk ((Last $n.ip) -ge 10 -and (Last $n.ip) -lt [int]$cfg.router_dhcp_start) ('NVR address .' + (Last $n.ip) + ' is in the WireIt block (.10-.99), below the router''s range (.' + [int]$cfg.router_dhcp_start + ' and up). Standard: .' + ([int]@($cfg.nvr_hosts)[0]))
      Chk ($n.gw -eq $pc.gw) ('NVR gateway = router ' + $pc.gw)
      Chk ($n.dns1 -eq $cfg.dns1 -and $n.dns2 -eq $cfg.dns2) ('NVR DNS = ' + $cfg.dns1 + ' / ' + $cfg.dns2 + ' (now ' + $n.dns1 + ' / ' + $n.dns2 + ')')
      Chk ($n.platform_enabled -eq $true) 'Platform access (Hik-Connect / EZCloud) is ON'
      Chk ($n.platform_online -eq $true) 'Platform shows ONLINE'
      if ($n.channels) { $off = @($n.channels | Where-Object { -not $_.online }); Chk ($off.Count -eq 0) ('All ' + $n.channels.Count + ' cameras online' + $(if ($off.Count) { ' (offline: ' + (($off | ForEach-Object { 'D' + $_.id }) -join ' ') + ')' } else { '' })) }
    }
    foreach ($c in @($script:devs | Where-Object { $_.kind -eq 'camera' -and $_.channel_of })) {
      Chk ($c.addressing -ne 'dhcp' -and (Last $c.ip) -ge [int]$cfg.camera_block_start -and (Last $c.ip) -le [int]$cfg.camera_block_end) ('Switch camera D' + $c.channel_id + ' ' + $c.ip + ' static, in the camera block .' + [int]$cfg.camera_block_start + '-.' + [int]$cfg.camera_block_end)
    }
    # router DHCP range: typed by the tech (router model + range are optional), plus what this PC's own lease shows
    $rs = Range-Start $DhcpRange; $reserved = ($DhcpRange -match '(?i)reserv')
    if ($reserved) { Chk $true ('Router range not changed; NVR address reserved in the router (typed: ' + $DhcpRange + ')') }
    elseif ($rs -ge 0) { Chk ($rs -ge [int]$cfg.router_dhcp_start) ('Router DHCP range starts at .' + [int]$cfg.router_dhcp_start + ' or higher (typed: ' + $DhcpRange + ')') }
    else { Say '  NOTE  Router DHCP range not typed (optional). Type it when NVR Snapshot asks, so Fix NVR knows it later.' 'Yellow' }
    if ($pc.dhcp -and (P3 $pc.ip) -eq $newP3) { Chk ((Last $pc.ip) -ge [int]$cfg.router_dhcp_start -or $reserved) ('This PC got .' + (Last $pc.ip) + ' from the router (.' + [int]$cfg.router_dhcp_start + ' or higher means the range was changed)') }
    if (($rs -ge 0 -and $rs -lt [int]$cfg.router_dhcp_start -and -not $reserved) -or ($chk | Where-Object { $_ -like 'FIX  This PC got*' })) { if (-not $script:routerStepShown) { Show-RouterStep 'the router still hands out addresses in the WireIt block.'; $script:routerStepShown = $true } }
    $snapObj = [ordered]@{ tool = 'WireIt FixNVR ' + $Version; site = $Site; taken = (Get-Date -Format 's'); taken_on = $env:COMPUTERNAME; router = $pc.gw; scheme = $newP3; mask = $newMask
      router_model = $RouterModel; router_dhcp_range = $DhcpRange; nvr_address_reserved_in_router = [bool]$reserved; pc_lease = $(if ($pc.dhcp) { $pc.ip } else { '' })
      nvrs = @($nvrs | ForEach-Object { [ordered]@{ brand = $_.brand; model = $_.model; serial = $_.serial; mac = $_.mac; ip = $_.ip; mask = $_.mask; gw = $_.gw; dns1 = $_.dns1; dns2 = $_.dns2; addressing = $_.addressing; firmware = $_.firmware; platform_enabled = $_.platform_enabled; platform_online = $_.platform_online
        channels = @($_.channels | ForEach-Object { [ordered]@{ channel = $_.id; ip = $_.ip; port = $_.port; protocol = $_.protocol; poe_port = $_.poe; online = $_.online } }) } })
      cameras = @($script:devs | Where-Object { $_.kind -eq 'camera' -and ($_.channel_of -or $_.found_by -match 'SADP') } | ForEach-Object { [ordered]@{ channel = $_.channel_id; nvr = $_.channel_of; brand = $_.brand; model = $_.model; serial = $_.serial; mac = $_.mac; ip = $_.ip; mask = $_.mask; gw = $_.gw; addressing = $_.addressing; poe_port = $_.poe } })
      checklist = @($chk); note = 'No passwords are stored in this file.' }
    $name = 'FixNVR snapshot ' + $(if ($Site) { $Site + ' ' } else { '' }) + (Get-Date -Format 'yyyy-MM-dd HHmm') + '.json'
    $localDir = Join-Path $here 'snapshots'; New-Item -ItemType Directory -Force -Path $localDir | Out-Null
    Save-Json $snapObj (Join-Path $localDir $name); Say ''; Say ('Snapshot saved: ' + (Join-Path $localDir $name)) 'Green'
    $sf = Find-SiteFolder $Site
    # 2.2.19 (class F): "also saved" only when the copy really worked (2.2.18 said it after a copy that could have failed)
    if ($sf) { $dd = Join-Path $sf $cfg.snapshot_subfolder; try { New-Item -ItemType Directory -Force -Path $dd -ErrorAction Stop | Out-Null; Copy-Item -LiteralPath (Join-Path $localDir $name) -Destination (Join-Path $dd $name) -ErrorAction Stop; if (-not (Test-Path -LiteralPath (Join-Path $dd $name))) { throw 'the copy is not there' }; Say ('Also saved to the site''s Drive folder: ' + (Join-Path $dd $name)) 'Green' } catch { Say ('NOT saved to the site''s Drive folder (' + $_.Exception.Message + '). Copy the file above into the site''s Drive folder (Docs) by hand.') 'Yellow' } }
    elseif ($Site) { Say ('Site folder "' + $Site + '" not found in Google Drive on this PC. Copy the file above into the site''s Drive folder (Docs).') 'Yellow' }
    else { Say 'Tip: run with -Site "<site folder name>" to save it straight into the site''s Drive folder.' }
    Invoke-CamViews $nvrs
    return
  }

  # ---------- 5. build the plan ----------
  $taken = @{}; foreach ($d in $script:devs) { if ($d.ip) { $taken[$d.ip] = $true } }; $taken[$pc.gw] = $true; $taken[$pc.ip] = $true
  function Free-Target([string]$want, [int[]]$fallbackHosts) {
    $list = @(); if ($want) { $list += $want }; foreach ($h in $fallbackHosts) { $list += ($newP3 + '.' + $h) }
    foreach ($ip in $list) { if ($taken.ContainsKey($ip)) { continue }; if (Test-IpFree $ip) { $taken[$ip] = $true; return $ip } else { $taken[$ip] = $true } }
    return $null
  }
  $nvrHosts = @($cfg.nvr_hosts | ForEach-Object { [int]$_ })
  $cbS = [int]$cfg.camera_block_start; $cbE = [int]$cfg.camera_block_end; $chBase = [int]$cfg.camera_channel_base
  $blk = @(); for ($h = $cbS; $h -le $cbE; $h++) { if ($nvrHosts -notcontains $h) { $blk += $h } }
  $camMap = @{}   # old ip -> new ip
  $notChecked = New-Object System.Collections.Generic.List[string]
  if ($Mode -eq 'Rollback') {
    foreach ($st0 in @(Get-FnRollbackSteps $rb)) { $plan.Add($st0) }   # 2.2.7 (F05): also the sent-but-unconfirmed steps
  } else {
   foreach ($c in @($script:devs | Where-Object { ($_.kind -eq 'camera' -or ($MoveUnlisted -and $_.login -like 'ok*' -and $_.kind -ne 'nvr')) -and ($_.channel_of -or $MoveUnlisted) -and -not (Is-Poe $_.ip) })) {
    if (InNet $c.ip $pc.ip $pc.prefix) { continue }
    $want = ''
    if ($c.snap_ip) { $want = $newP3 + '.' + (Last $c.snap_ip) }
    elseif ($cfg.camera_ip_mode -match '^keep_last_octet' -and (Last $c.ip) -ge $cbS -and (Last $c.ip) -le $cbE -and $nvrHosts -notcontains (Last $c.ip)) { $want = $newP3 + '.' + (Last $c.ip) }
    elseif ($c.channel_id -match '^\d+$' -and ($chBase + [int]$c.channel_id) -ge $cbS -and ($chBase + [int]$c.channel_id) -le $cbE) { $want = $newP3 + '.' + ($chBase + [int]$c.channel_id) }
    $t = Free-Target $want $blk
    if (-not $t) { Say ('  No free address for camera ' + $c.ip + ' in the camera block. Skipped.') 'Yellow'; continue }
    $c.target_ip = $t; $camMap[$c.ip] = $t
    if ($c.login -eq 'ok' -and $c.brand -eq 'hik' -and $c.net_xml) { $how = 'isapi' } elseif ($c.onvif) { $how = 'onvif' } else { $how = 'manual' }
    $plan.Add([pscustomobject]@{ type = 'cam-net'; how = $how; kind = 'camera'; brand = $c.brand; dev_mac = $c.mac; dev_serial = $c.serial; channel = $c.channel_id; old_ip = $c.ip; new_ip = $t; old_mask = $c.mask; new_mask = $newMask; old_gw = $c.gw; new_gw = $pc.gw; old_dns1 = $c.dns1; old_dns2 = $c.dns2; old_addressing = $c.addressing; done = $false; result = '' })
   }
   # 2.2.12 (Codex P1-5): a recorder the tool could not log in to is NOT CHECKED, never "looks right"
   if (-not $nvrs.Count) { $notChecked.Add('no NVR was found or identified, so no recorder was checked') }
   foreach ($n in $nvrs) {
    if ($n.login -ne 'ok') { Say ('  Cannot change ' + (Short $n) + ' without a working login.') 'Yellow'; $notChecked.Add((Short $n) + ': ' + $(if ($n.login -like 'REFUSED*') { 'login refused (wrong password?)' } else { 'could not log in / no answer' }) + ' - NOT CHECKED'); continue }
    if ($n.channels) {
      foreach ($ch in $n.channels) {
        if ($ch.poe -or -not $ch.ip) { continue }
        $newIp = $camMap[$ch.ip]
        $camDev = $(if ($newIp) { Dev-ByIp $ch.ip } else { $null })
        if (-not $newIp -and -not $ch.online -and $snap) {
          $s = @($snap.cameras) | Where-Object { [string]$_.channel -eq [string]$ch.id } | Select-Object -First 1
          if ($s) { $d = Dev-ByMac $s.mac; if ($d -and $d.ip -ne $ch.ip -and (InNet $d.ip $pc.ip $pc.prefix)) { $newIp = $d.ip; $camDev = $d } }
        }
        if ($newIp -and $newIp -ne $ch.ip) {
          $how = $(if ($n.brand -eq 'hik') { 'isapi' } else { 'manual' })
          # 2.2.20 (Codex 2.2.19 R06): the step also saves WHICH camera the channel is for (its MAC / serial), so the channel is changed
          # (forward and Undo) only while that camera is confirmed
          $plan.Add([pscustomobject]@{ type = 'nvr-channel'; how = $how; kind = 'nvr'; brand = $n.brand; dev_mac = $n.mac; dev_serial = $n.serial; nvr_ip = $n.ip; channel = $ch.id; old_ip = $ch.ip; new_ip = $newIp; cam_mac = $(if ($camDev) { [string]$camDev.mac } else { '' }); cam_serial = $(if ($camDev) { [string]$camDev.serial } else { '' }); done = $false; result = '' })
        }
      }
    }
    if ($n.platform_enabled -eq $false) { $how = $(if ($n.brand -eq 'hik') { 'isapi' } elseif ($AllowUnverifiedUniview -and $n.platform_json) { 'lapi' } else { 'manual' }); $plan.Add([pscustomobject]@{ type = 'nvr-platform'; how = $how; kind = 'nvr'; brand = $n.brand; dev_mac = $n.mac; dev_serial = $n.serial; nvr_ip = $n.ip; done = $false; result = '' }) }
    $wrong = -not (InNet $n.ip $pc.ip $pc.prefix)
    $target = $n.ip
    if ($wrong -or $n.addressing -eq 'dhcp') {
      $want = $(if ($n.snap_ip) { $newP3 + '.' + (Last $n.snap_ip) } else { '' })
      $target = Free-Target $want $nvrHosts
      if (-not $target) { Say ('  No free address for the NVR (' + (($nvrHosts | ForEach-Object { '.' + $_ }) -join '/') + ' all in use). Pick one below .' + [int]$cfg.router_dhcp_start + ' by hand with config.json nvr_hosts.') 'Yellow'; $target = $n.ip }
    }
    $needNet = ($target -ne $n.ip) -or ($n.mask -and $n.mask -ne $newMask) -or ($n.gw -ne $pc.gw) -or ($n.dns1 -ne $cfg.dns1) -or ($n.dns2 -ne $cfg.dns2) -or ($n.addressing -eq 'dhcp')
    if ($needNet) {
      $how = $(if ($n.brand -eq 'hik' -and $n.net_xml) { 'isapi' } elseif ($n.brand -eq 'unv' -and $AllowUnverifiedUniview -and $n.net_json) { 'lapi' } else { 'manual' })
      $plan.Add([pscustomobject]@{ type = 'nvr-net'; how = $how; kind = 'nvr'; brand = $n.brand; dev_mac = $n.mac; dev_serial = $n.serial; old_ip = $n.ip; new_ip = $target; old_mask = $n.mask; new_mask = $newMask; old_gw = $n.gw; new_gw = $pc.gw; old_dns1 = $n.dns1; old_dns2 = $n.dns2; new_dns1 = $cfg.dns1; new_dns2 = $cfg.dns2; old_addressing = $n.addressing; done = $false; result = '' })
    }
   }
  }

  # ---------- 6. preview ----------
  $rev = ($Mode -eq 'Rollback')
  Say ''; Say $(if ($rev) { '----- Rollback plan (puts things back as the Fix run found them) -----' } else { '----- Plan (nothing has been changed yet) -----' }) 'Cyan'
  if (-not $plan.Count -and -not $rev -and $notChecked.Count) {
    foreach ($nc in $notChecked) { Say ('NOT CHECKED: ' + $nc + '.') 'Red' }
    foreach ($hp in @(Get-FnHealthProblems $nvrs)) { Say ('PROBLEM: ' + $hp + '.') 'Red' }
    Say 'Nothing was changed, but this is NOT an all-clear: the recorder was not checked. Use the right NVR login (Bitwarden) or give its address, then run again.' 'Red'
    $script:exitCode = 2; return
  }
  # 2.2.13 (Codex #2): no automatic plan is not the same as "all right" - the finish comes from what the read showed (Fix and Check mode)
  $health = $(if ($rev) { @() } else { @(Get-FnHealthProblems $nvrs) })
  if (-not $plan.Count -and $health.Count) {
    foreach ($hp in $health) { Say ('PROBLEM: ' + $hp + '.') 'Red' }
    Say ('Nothing was changed: the tool has no automatic fix for ' + $(if ($health.Count -eq 1) { 'this' } else { 'these ' + $health.Count + ' problems' }) + '. This is NOT an all-clear. Check the red lines on the NVR / camera (power, cable, Hik-Connect / EZCloud), then run again, or call the office.') 'Red'
    $script:exitCode = 4; return
  }
  if (-not $plan.Count) { Say 'Nothing to change. Everything the tool can check looks right.' 'Green'; if ($Mode -ne 'Rollback') { $script:exitCode = 0 }; return }
  if (-not $rev -and $notChecked.Count) { Say ''; foreach ($nc in $notChecked) { Say ('NOT CHECKED: ' + $nc + '. The plan below does not cover it.') 'Red' } }
  $i = 0
  foreach ($st in $plan) {
    $i++; $from = $(if ($rev) { $st.new_ip } else { $st.old_ip }); $to = $(if ($rev) { $st.old_ip } else { $st.new_ip })
    $tag = $(if ($st.how -eq 'manual') { '  [BY HAND - see below]' } else { '' })
    switch ($st.type) {
      'cam-net'      { Say ('' + $i + '. Camera ' + $(if ($st.channel) { 'D' + $st.channel } else { '(not on an NVR list)' }) + ': ' + $from + ' -> ' + $(if ($rev -and (Get-FnAddrMode $st.old_addressing) -eq 'dhcp') { 'DHCP (was ' + $to + ')' } else { $to }) + $(if (-not $rev) { ', gateway ' + $st.new_gw + ', DNS ' + $cfg.dns1 + '/' + $cfg.dns2 + ', static' } else { '' }) + $tag) }
      'nvr-channel'  { Say ('' + $i + '. NVR camera list, channel D' + $st.channel + ': ' + $from + ' -> ' + $to + $tag) }
      'nvr-platform' { Say ('' + $i + '. NVR: turn ON platform access (' + $(if ($st.brand -eq 'unv') { 'EZCloud' } else { 'Hik-Connect' }) + ')' + $tag) }
      'nvr-net'      { Say ('' + $i + '. NVR: ' + $from + ' -> ' + $to + $(if ($rev -and (Get-FnAddrMode $st.old_addressing) -eq 'dhcp') { ' back on DHCP' } else { ' static' }) + $(if (-not $rev) { ', mask ' + $st.new_mask + ', gateway ' + $st.new_gw + ', DNS ' + $st.new_dns1 + ' / ' + $st.new_dns2 } else { ', gateway ' + $st.old_gw + ', DNS ' + $st.old_dns1 + ' ' + $st.old_dns2 }) + $tag + '  (the NVR may restart: about 2 min)') }
    }
  }
  $movesScheme = @($plan | Where-Object { $_.type -eq 'nvr-net' -and (P3 $_.old_ip) -ne $newP3 }).Count
  if (-not $rev -and $movesScheme -and -not $script:routerStepShown -and -not $pc.dhcp) { Show-RouterStep ('this PC has a fixed address, so the tool cannot see the router''s range. The NVR is moving onto this router''s scheme; make sure the router hands out .' + [int]$cfg.router_dhcp_start + ' and up.'); $script:routerStepShown = $true }
  elseif (-not $rev -and $script:routerStepShown) { Say ''; Say ('Remember the ROUTER STEP above (router hands out .' + [int]$cfg.router_dhcp_start + ' and up). Do it today, before or right after the fix.') 'Yellow' }
  $manual = @($plan | Where-Object { $_.how -eq 'manual' })
  if ($manual.Count) { Say ''; Say ('' + $manual.Count + ' step(s) must be done by hand (Uniview NVR settings are not yet verified for automatic change, or no login). Steps are printed after the automatic part.') 'Yellow' }
  $plan | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $runDir 'plan.json')
  $before = @($script:devs | ForEach-Object { [ordered]@{ ip = $_.ip; mac = $_.mac; kind = $_.kind; brand = $_.brand; model = $_.model; serial = $_.serial; mask = $_.mask; gw = $_.gw; dns1 = $_.dns1; dns2 = $_.dns2; addressing = $_.addressing; platform_enabled = $_.platform_enabled; platform_online = $_.platform_online; channel = $_.channel_id; found_by = $_.found_by; login = $_.login } })
  try { Save-Json $before (Join-Path $runDir 'before.json') } catch { Log ('before.json not saved: ' + $_.Exception.Message) }
  if ($Mode -eq 'Check') {
    Say ''; Say 'Check only: nothing was changed. Run "Fix NVR.cmd" (Fix mode) to apply this plan.' 'Cyan'
    if ($notChecked.Count) { Say ('Not an all-clear: ' + $notChecked.Count + ' recorder(s) NOT CHECKED (see the red lines).') 'Red'; $script:exitCode = 4 }
    # 2.2.13 (Codex #2): Check mode never ends as an all-clear when the read showed a problem
    if ($health.Count) { foreach ($hp in $health) { Say ('PROBLEM now: ' + $hp + '.') 'Red' }; Say ('Not an all-clear: ' + $health.Count + ' problem(s) seen now (the plan above may fix some of them; Fix mode checks again after the change).') 'Red'; $script:exitCode = 4 }
    return
  }

  # ---------- 7. ONE confirm ----------
  Say ''
  $ans = $(if ($ConfirmWith) { $ConfirmWith } else { Read-Host 'Type YES to make these changes (anything else cancels)' })
  Log ('confirm answer: ' + $ans)
  if ($ans -cne 'YES') { Say 'Cancelled. Nothing was changed.' 'Yellow'; return }
  $rbPath = Join-Path $runDir 'rollback.json'
  $rbObj = [ordered]@{ tool = 'WireIt FixNVR ' + $Version; created = (Get-Date -Format 's'); site = $Site; pc = $pc.ip; router = $pc.gw; old_subnets = @($oldList); steps = $plan }
  if (-not $rev) {
    try { Save-Json $rbObj $rbPath } catch { Say ('STOPPED: the rollback (undo) file could not be saved (' + $_.Exception.Message + '). Nothing was changed.') 'Red'; $script:exitCode = 7; return }
    Say ('Rollback info saved first: ' + $rbPath)
  }
  $failedTo = @{}   # 2.2.7 (F05): addresses a camera move did NOT reach
  $netUnchecked = New-Object System.Collections.Generic.List[string]   # 2.2.18: changes sent that the tool cannot read back (DHCP)

  # ---------- 8. apply ----------
  $pfx = $pc.prefix
  foreach ($st in $plan) {
    if ($st.how -eq 'manual') { continue }
    $from = $(if ($rev) { $st.new_ip } else { $st.old_ip }); $to = $(if ($rev) { $st.old_ip } else { $st.new_ip })
    $res = $null
    if (-not $rev -and (Test-FnSkipDependent $st $failedTo)) {
      $st.result = 'SKIPPED: the camera did not move to ' + $st.new_ip + ', so its NVR channel was left as it was'; $applied.Add($st); Say ('  ' + $st.type + ' ' + $from + ' -> ' + $to + ': ' + $st.result) 'Red'; continue
    }
    # 2.2.7 (F05): marked as sent (and saved) BEFORE it is sent: an accepted change that then times out, or a stopped run, is still undone
    if (-not $rev) {
      if (-not $st.PSObject.Properties['attempted']) { $st | Add-Member -NotePropertyName attempted -NotePropertyValue $false }
      $st.attempted = $true
      try { Save-Json $rbObj $rbPath } catch { Say ('STOPPED: the rollback (undo) file could not be saved (' + $_.Exception.Message + '). Nothing more was changed.') 'Red'; $script:exitCode = 7; return }
    }
    # 2.2.18 (Codex 2.2.17 #1): EVERY write below (forward and Undo) first reads the device at the address it is about to change,
    # on a fresh record, and goes ahead only when the device's own answer gives the MAC saved for it (and the serial, when saved).
    # A different device, no MAC, or no answer = NOT restored / NOT changed, nothing is sent. No fall-back to "the device at the saved
    # address" and no "first NVR" stand-in. After the write the settings are read back from the device (by MAC) at the new address.
    $stMac = [string]$st.dev_mac; $stSer = $(if ($st.PSObject.Properties['dev_serial']) { [string]$st.dev_serial } else { '' })
    $word = $(if ($rev) { 'NOT restored' } else { 'NOT changed' })
    $stOldMode = $(if ($st.PSObject.Properties['old_addressing']) { Get-FnAddrMode $st.old_addressing } else { '' })
    # 2.2.19 (Codex 2.2.18 F10/F11/F12): "it never moved" (an Undo step sent but not confirmed) counts only when the same device (by MAC,
    # or serial for a serial-only record) answers at its OLD address and reads back ALL its old settings there (mode included).
    if ($rev -and $st.type -match '^(cam|nvr)-net$' -and -not $st.done -and $to -ne $from) {
      $nmMask = $(if ($st.old_mask) { [string]$st.old_mask } else { $newMask })
      $nmWhy = Get-FnNetReadBackWhy $to $stMac $(if ($st.type -eq 'nvr-net') { 'nvr' } else { 'camera' }) ([string]$st.brand) $nmMask ([string]$st.old_gw) ([string]$st.old_dns1) ([string]$st.old_dns2) $stSer $(if ($stOldMode) { $stOldMode } else { 'static' })
      if (-not $nmWhy -and $stOldMode) { $res = @{ ok = $true; note = ('it never moved: it is still on ' + $to + ' with its old settings (checked: same device, settings read back)') } }
    }
    if (-not $res) {
    switch ($st.type) {
      'cam-net' {
        $d0 = $(if ($stMac) { Dev-ByMac $stMac } else { $null })
        $id = Read-FnIdentity $from $stMac 'camera' ([string]$st.brand) $stSer; $d = $id.dev
        if ($id.why) { $res = @{ ok = $false; refused = $true; note = ($word + ': ' + $id.why + '. Nothing was sent to ' + $from + '.') }; break }
        $toDhcp = ($rev -and $stOldMode -eq 'dhcp')
        # 2.2.20 (Codex 2.2.19 R09): Undo with an unknown saved addressing mode is refused BEFORE anything is written (2.2.19 wrote a
        # fixed address first and only then said NOT CHECKED)
        if ($rev -and -not $stOldMode) { $res = @{ ok = $false; refused = $true; note = ($word + ': the Fix run did not record whether it used DHCP or a fixed address before, so the tool cannot put it back safely. Nothing was sent to ' + $from + '. Set its network back by hand (see the list below).') }; break }
        # 2.2.19 (class B): forward, the settings read now (after YES) must still be the ones the plan showed and the undo file holds
        if (-not $rev) { $bw = Get-FnBackupWhy $st $d; if ($bw) { $res = @{ ok = $false; refused = $true; note = ($word + ': ' + $bw + '. Nothing was sent to ' + $from + '.') }; break } }
        # 2.2.18 / 2.2.19 (sweep A, class A): a device is moved only onto a FREE address, checked right before the write, in BOTH
        # directions (2.2.18 checked Undo only; forward relied on the check made before the YES)
        if (-not $toDhcp -and $to -ne $from -and -not (Test-IpFree $to)) { $res = @{ ok = $false; refused = $true; note = ($word + ': the address ' + $to + ' is now used by another device. Nothing was sent.') }; break }
        $mask = $(if ($rev -and $st.old_mask) { $st.old_mask } else { $newMask }); $gw = $(if ($rev) { [string]$st.old_gw } else { $pc.gw })
        $d1 = $(if ($rev) { [string]$st.old_dns1 } else { $cfg.dns1 }); $d2 = $(if ($rev) { [string]$st.old_dns2 } else { $cfg.dns2 })
        if ($d.brand -eq 'hik' -and $d.net_xml) {
          Write-Host ('Moving camera ' + $st.channel + ' ' + $from + ' -> ' + $to + ' ...')
          $res = Hik-SetNet $d $to $mask $gw $d1 $d2 -Dhcp:$toDhcp
          if ($res.ok -and $res.reboot) { $rid = Read-FnIdentity $from $stMac 'camera' ([string]$st.brand) $stSer; if ($rid.why) { $res.ok = $false; $res.note = ('accepted (restart needed), but the restart was NOT sent: ' + $rid.why + ' - NOT CHECKED') } else { [void](Hik-RebootNow $rid.dev) } }   # 2.2.20 (class B sweep): identity fresh before the restart too
        } elseif ($d.onvif -or (Onvif-Read $d)) {
          # 2.2.19 (Codex 2.2.18 F10 twin): ONVIF Undo of a camera that was on DHCP is NOT done as a fixed address (2.2.18 did that)
          if ($toDhcp) { $res = @{ ok = $false; refused = $true; note = ($word + ': it was on DHCP before; set DHCP back in its own menu (the tool does not do that over ONVIF). Nothing was sent.') }; break }
          Write-Host ('Moving camera ' + $st.channel + ' ' + $from + ' -> ' + $to + ' ...')
          $res = Onvif-SetNet $d $to (MaskToPrefix $mask) $gw $d1 $d2
        }
        else { $res = @{ ok = $false; note = 'could not log in to the camera' } }
        if ($res.ok -and $toDhcp) {
          # 2.2.19 (Moshe's decision): DHCP Undo is NOT CHECKED unless the camera is found again by its MAC and reads back DHCP
          $fb = Find-FnDhcpBack $stMac $stSer 'camera' ([string]$d.brand) ([int]$cfg.camera_wait_seconds)
          if ($fb.ok) { $res.note = ('back on DHCP: found again by its MAC at ' + $fb.ip + ' and read back as DHCP'); $to = $fb.ip }
          else { $res.ok = $false; $res.note = ('sent: back on DHCP (the router gives its address), but NOT CHECKED: ' + $fb.why + '. Check camera ' + $stMac + ' is online') }
        }
        elseif ($res.ok) {
          $ans2 = Wait-Answer $to ([int]$cfg.camera_wait_seconds) $script:credCam
          if (-not $ans2) { $res.ok = $false; $res.note = ($res.note + ' camera did not answer on ' + $to).Trim() }
          else { $rbw = Wait-FnNetReadBack $to $stMac 'camera' ([string]$d.brand) $mask $gw $d1 $d2 $stSer 30; if ($rbw) { $res.ok = $false; $res.note = ($res.note + ' answers on ' + $to + ', but ' + $rbw).Trim() } }
          if ($res.ok -and $rev -and -not $stOldMode) { $res.ok = $false; $res.note = ('put back as a fixed address on ' + $to + ' and read back, but the Fix run did not record whether it used DHCP before - NOT CHECKED') }
        }
        if ($res.ok) { $d.ip = $to; if ($d0) { $d0.ip = $to } }
      }
      'nvr-channel' {
        $n0 = $(if ($stMac) { Dev-ByMac $stMac } else { $null })
        $nAt = $(if ($n0 -and $n0.ip) { [string]$n0.ip } elseif ($st.nvr_ip) { [string]$st.nvr_ip } else { '' })
        Write-Host ('NVR camera list D' + $st.channel + ' -> ' + $to + ' ...')
        if (-not $nAt) { $res = @{ ok = $false; refused = $true; note = ($word + ': the NVR for this channel (' + $(if ($stMac) { $stMac } else { 'serial ' + $stSer }) + ') was not found. Nothing was sent.') }; break }
        $id = Read-FnIdentity $nAt $stMac 'nvr' ([string]$st.brand) $stSer
        if ($id.why) { $res = @{ ok = $false; refused = $true; note = ($word + ': ' + $id.why + '. Nothing was sent to the NVR.') }; break }
        # 2.2.20 (R06): the camera this channel is for is at the step's NEW address in both directions (forward: it has just moved
        # there; Undo: channels are put back before the camera moves back). An older undo file with no camera saved = refused.
        $cm = $(if ($st.PSObject.Properties['cam_mac']) { [string]$st.cam_mac } else { '' }); $cs = $(if ($st.PSObject.Properties['cam_serial']) { [string]$st.cam_serial } else { '' })
        $res = Hik-SetChannel $id.dev $st.channel $to $from ([string]$st.new_ip) $cm $cs
        if (-not $res.ok -and $res.refused) { $res.note = $word + ': ' + $res.note }
      }
      'nvr-platform' {
        $n0 = $(if ($stMac) { Dev-ByMac $stMac } else { $null })
        $pAt = $(if ($n0 -and $n0.ip) { [string]$n0.ip } elseif ($st.PSObject.Properties['nvr_ip'] -and $st.nvr_ip) { [string]$st.nvr_ip } else { '' })
        Write-Host 'Turning platform access on ...'
        $id = $(if ($pAt) { Read-FnIdentity $pAt $stMac 'nvr' ([string]$st.brand) $stSer } else { @{ dev = $null; why = 'the NVR (' + $(if ($stMac) { $stMac } else { 'serial ' + $stSer }) + ') was not found' } })
        if ($id.why) { $res = @{ ok = $false; refused = $true; note = ($word + ': ' + $id.why + '. Nothing was sent.') }; break }
        $n = $id.dev
        # 2.2.19 (class B/C): read again after YES - the platform setting must have been READ now to be changed from it
        if ($n.platform_read -ne $true) { $res = @{ ok = $false; refused = $true; note = ($word + ': its platform access setting could not be read now. Nothing was sent.') }; break }
        if ($n.platform_enabled -eq $true) { $res = @{ ok = $true; note = 'platform access is already on (read now)' }; break }
        if ($st.how -eq 'isapi') { $res = Hik-EnablePlatform $n } else { $res = Unv-Put $n $cfg.uniview.cloud_path (Unv-PlanCloud $n) }
        if (-not $res.ok -and $n.platform_has_code -eq $false) { $res.note = ($res.note + ' (the NVR may need a Hik-Connect verification code set in its web page first)').Trim() }
      }
      'nvr-net' {
        $n0 = $(if ($stMac) { Dev-ByMac $stMac } else { $null })
        $id = Read-FnIdentity $from $stMac 'nvr' ([string]$st.brand) $stSer; $n = $id.dev
        if ($id.why) { $res = @{ ok = $false; refused = $true; note = ($word + ': ' + $id.why + '. Nothing was sent to ' + $from + '.') }; break }
        $toDhcpN = ($rev -and $stOldMode -eq 'dhcp')
        if ($rev -and -not $stOldMode) { $res = @{ ok = $false; refused = $true; note = ($word + ': the Fix run did not record whether it used DHCP or a fixed address before, so the tool cannot put it back safely. Nothing was sent to ' + $from + '. Set its network back by hand (see the list below).') }; break }   # 2.2.20 (R09)
        if (-not $rev) { $bw = Get-FnBackupWhy $st $n; if ($bw) { $res = @{ ok = $false; refused = $true; note = ($word + ': ' + $bw + '. Nothing was sent to ' + $from + '.') }; break } }
        # 2.2.19 (Codex 2.2.18 F10 twin): a Uniview recorder that was on DHCP is not given a fixed address by Undo (2.2.18 wrote the
        # fixed address first and only then said "set DHCP by hand"): nothing is sent, and the step is left to a person
        if ($toDhcpN -and $st.how -ne 'isapi') { $res = @{ ok = $false; refused = $true; note = ($word + ': it was on DHCP before; set DHCP back in its own menu. Nothing was sent.') }; break }
        if (-not $toDhcpN -and $to -ne $from -and -not (Test-IpFree $to)) { $res = @{ ok = $false; refused = $true; note = ($word + ': the address ' + $to + ' is now used by another device. Nothing was sent.') }; break }   # 2.2.18 / 2.2.19 (sweep A)
        $mask = $(if ($rev -and $st.old_mask) { $st.old_mask } else { $newMask }); $gw = $(if ($rev) { [string]$st.old_gw } else { $pc.gw })
        $d1 = $(if ($rev) { [string]$st.old_dns1 } else { $cfg.dns1 }); $d2 = $(if ($rev) { [string]$st.old_dns2 } else { $cfg.dns2 })
        Write-Host ('Moving the NVR ' + $from + ' -> ' + $to + ' (DNS ' + $d1 + ' / ' + $d2 + ') ...')
        if ($st.how -eq 'isapi') {
          $res = Hik-SetNet $n $to $mask $gw $d1 $d2 -Dhcp:$toDhcpN
          if ($res.ok -and $res.reboot) {
            # 2.2.20 (class B sweep): the restart is a second write; the NVR is identified again right before it
            $rid = Read-FnIdentity $from $stMac 'nvr' ([string]$st.brand) $stSer
            if ($rid.why) { $res.ok = $false; $res.note = ('accepted (restart needed), but the restart was NOT sent: ' + $rid.why + ' - NOT CHECKED') } else { Write-Host '  NVR asked for a restart; restarting it now (about 2 min).'; [void](Hik-RebootNow $rid.dev) }
          }
        }
        else {
          $r1 = Unv-Put $n $cfg.uniview.dns_path (Unv-PlanDns $n $d1 $d2)
          # 2.2.20 (class B sweep): the network write is a second write; the recorder is identified again right before it
          $r2 = @{ ok = $false; note = '' }
          if ($r1.ok) { $rid = Read-FnIdentity $from $stMac 'nvr' ([string]$st.brand) $stSer; if ($rid.why) { $r2.note = ('the DNS change was sent, but the address change was NOT sent: ' + $rid.why + ' - NOT CHECKED') } else { $r2 = Unv-Put $rid.dev $cfg.uniview.net_path (Unv-PlanNet $rid.dev $to $mask $gw) } }
          $res = @{ ok = ($r1.ok -and $r2.ok); note = ($r1.note + ' ' + $r2.note).Trim() }
        }
        if ($res.ok -and $toDhcpN) {
          # 2.2.19 (Moshe's decision): DHCP Undo is NOT CHECKED unless the NVR is found again by its MAC and reads back DHCP
          $fb = Find-FnDhcpBack $stMac $stSer 'nvr' ([string]$n.brand) ([int]$cfg.verify_wait_seconds)
          if ($fb.ok) { $res.note = ('back on DHCP: found again by its MAC at ' + $fb.ip + ' and read back as DHCP'); $to = $fb.ip }
          else { $res.ok = $false; $res.note = ('sent: back on DHCP (the router gives its address), but NOT CHECKED: ' + $fb.why + '. Check NVR ' + $(if ($stMac) { $stMac } else { $stSer }) + ' is online') }
        }
        elseif ($res.ok) {
          Write-Host ('  waiting for the NVR on ' + $to + ' ...')
          if (-not (Wait-Answer $to ([int]$cfg.verify_wait_seconds) $script:credNvr)) { $res.ok = $false; $res.note = ($res.note + ' NVR did not answer on ' + $to + ' yet').Trim() }
          else { $rbw = Wait-FnNetReadBack $to $stMac 'nvr' ([string]$n.brand) $mask $gw $d1 $d2 $stSer 30; if ($rbw) { $res.ok = $false; $res.note = ($res.note + ' answers on ' + $to + ', but ' + $rbw).Trim() } }
          if ($res.ok -and $rev -and -not $stOldMode) { $res.ok = $false; $res.note = ('put back as a fixed address on ' + $to + ' and read back, but the Fix run did not record whether it used DHCP before - NOT CHECKED') }
        }
        if ($res.ok) { $n.ip = $to; if ($n0) { $n0.ip = $to } }
      }
    }
    }
    if ($res) { $st.done = [bool]$res.ok; $st.result = $(if ($res.ok) { 'done' + $(if ($res.note -match 'already|never moved|back on DHCP') { ' (' + $res.note + ')' } else { '' }) } elseif ($res.refused) { $res.note } else { 'FAILED ' + $res.note }); if ($res.ok -and $res.unchecked) { $netUnchecked.Add([string]$res.unchecked) } }
    if (-not $rev -and $st.type -eq 'cam-net' -and -not $st.done) { $failedTo[[string]$st.new_ip] = $true }
    $applied.Add($st)
    Say ('  ' + $st.type + ' ' + $from + ' -> ' + $to + ': ' + $st.result) $(if ($st.done) { 'Green' } else { 'Red' })
    if (-not $rev) { try { Save-Json $rbObj $rbPath } catch { Say ('STOPPED: the rollback (undo) file could not be saved (' + $_.Exception.Message + '). Nothing more was changed.') 'Red'; $script:exitCode = 7; return } }
  }
  # manual steps while the PC can still reach the old scheme
  if ($manual.Count) {
    Say ''; Say 'DO THESE BY HAND NOW (this PC can reach the old addresses until you press Enter):' 'Yellow'
    foreach ($st in $manual) {
      $ipNow = $(if ($rev) { $st.new_ip } else { $st.old_ip })
      switch ($st.type) {
        'nvr-net'      { Say ('  - Open http://' + $ipNow + ' > Setup > Network > Basic (Uniview) / Configuration > Network > TCP/IP (Hikvision): Static, IP ' + $st.new_ip + ', mask ' + $st.new_mask + ', gateway ' + $st.new_gw + ', DNS ' + $st.new_dns1 + ' and ' + $st.new_dns2 + '. Save.') }
        'nvr-platform' { Say ('  - Open http://' + $(if ($st.nvr_ip) { $st.nvr_ip } else { $ipNow }) + ' > Setup > Network > EZCloud (Uniview) / Network > Platform Access (Hikvision): tick Enable. Save.') }
        'nvr-channel'  { Say ('  - In the NVR camera list change channel D' + $st.channel + ' from ' + $st.old_ip + ' to ' + $st.new_ip + '.') }
        'cam-net'      { Say ('  - Camera ' + $ipNow + ' (D' + $st.channel + '): open http://' + $ipNow + ', set Static ' + $st.new_ip + ' mask ' + $st.new_mask + ' gateway ' + $st.new_gw + ' DNS ' + $cfg.dns1 + '/' + $cfg.dns2 + '.') }
      }
    }
    if (-not $ConfirmWith) { [void](Read-Host 'Press Enter when done (the temporary address is removed after this)') }
  }
  # ---------- 9. verify ----------
  # 2.2.12 (Codex P1-5): the result decides the finish. An NVR that cannot be read, a camera status that cannot be read, cameras
  # still offline, platform access still off / not online = NOT a clean finish ("not checked" is never "checked OK").
  $verify = New-Object System.Collections.Generic.List[string]
  if (-not $rev) {
    foreach ($nc in $notChecked) { $verify.Add($nc) }
    Say ''; Say '----- Checking the result -----' 'Cyan'
    foreach ($n in $nvrs) {
      # 2.2.13 (Codex #3): keep what the NVR had BEFORE the fix, so a missing / empty list afterwards is NOT CHECKED, never skipped
      $expIds = @($n.channels | Where-Object { $_ } | ForEach-Object { [string]$_.id })
      # 2.2.14 (Codex F4): forget EVERYTHING the earlier read filled (platform, network, DNS, login, lists) before rereading, so a failed
      # read after the fix is NOT CHECKED, never the value from before the fix; and remember who the NVR was, to catch a different device
      $expMac = [string]$n.mac; $expSerial = [string]$n.serial
      Clear-FnReadState $n; Read-Dev $n
      if ($n.login -ne 'ok') { Say ('NVR ' + $n.ip + ': cannot read it now (' + $(if ($n.login) { $n.login } else { 'no answer' }) + ') - NOT CHECKED.') 'Red'; $verify.Add('NVR ' + $n.ip + ' could not be read after the fix - NOT CHECKED'); continue }
      if (($expMac -and $n.mac -and (NormMac $n.mac) -ne (NormMac $expMac)) -or ($expSerial -and $n.serial -and $n.serial -ne $expSerial)) {
        Say ('NVR ' + $n.ip + ': a DIFFERENT device answers at this address now (' + $n.model + ' ' + $n.mac + ', expected ' + $expMac + ') - NOT CHECKED.') 'Red'
        $verify.Add('NVR ' + $n.ip + ': a different device answers at this address after the fix (expected ' + $expMac + ') - this NVR NOT CHECKED')
        continue
      }
      if ($n.brand -eq 'hik' -and $n.platform_enabled -ne $false) {
        # wait for Hik-Connect to come online, and also re-try a platform read that failed (only a real answer can say ONLINE)
        $end = (Get-Date).AddSeconds([int]$cfg.verify_wait_seconds); $tries = [int][math]::Ceiling([int]$cfg.verify_wait_seconds / 10)
        for ($k = 0; $k -lt $tries -and (Get-Date) -lt $end -and -not ($n.platform_read -eq $true -and ($n.platform_enabled -ne $true -or $n.platform_online -eq $true)); $k++) {
          Write-Host $(if ($n.platform_read -eq $true) { '  waiting for the NVR to come online in Hik-Connect ...' } else { '  reading platform access again ...' }); Start-Sleep -Seconds 10
          $ez = Http $n.ip 'GET' '/ISAPI/System/Network/EZVIZ' '' 'application/xml' $script:credNvr; [void](Set-FnHikPlatform $n $ez)
        }
      }
      $platOk = ($n.platform_read -eq $true -and $n.platform_enabled -eq $true -and $n.platform_online -eq $true)
      $netOk = ($n.net_read -eq $true -and ($n.brand -ne 'unv' -or $n.dns_read -eq $true))
      Say ('NVR ' + $n.ip + ' | gateway ' + $(if ($netOk) { $n.gw } else { 'NOT CHECKED' }) + ' | DNS ' + $(if ($netOk) { $n.dns1 + ' ' + $n.dns2 } else { 'NOT CHECKED' }) + ' | platform ' + $(if ($n.platform_enabled -eq $true) { 'ON' } elseif ($n.platform_enabled -eq $false) { 'OFF' } else { 'NOT CHECKED' }) + ' / ' + $(if ($platOk) { 'ONLINE (app should work)' } elseif ($n.brand -eq 'unv') { 'NOT CHECKED by the tool - check the EZView app' } elseif ($n.platform_read -ne $true -or $n.platform_online -eq $null) { 'NOT CHECKED (could not be read now)' } else { 'NOT online yet' })) $(if ($platOk -and $netOk) { 'Green' } else { 'Red' })
      if (-not $platOk) {
        if ($n.platform_enabled -eq $false) { $verify.Add('NVR ' + $n.ip + ': platform access (Hik-Connect / EZCloud) is still OFF') }
        elseif ($n.brand -eq 'unv') { $verify.Add('NVR ' + $n.ip + ': EZCloud online status NOT CHECKED (the tool cannot read it; check the EZView app)') }
        elseif ($n.platform_enabled -eq $true -and $n.platform_online -eq $false) { $verify.Add('NVR ' + $n.ip + ': platform access is on but NOT online yet (the app will not work yet)') }
        else { $verify.Add('NVR ' + $n.ip + ': platform access NOT CHECKED (could not be read after the fix)') }
      }
      if (-not $netOk) { $verify.Add('NVR ' + $n.ip + ': its network settings (gateway / DNS) could not be read after the fix - NOT CHECKED') }
      elseif ($n.brand -eq 'hik') {
        # 2.2.14: a network change counts only when the NVR reads back what was set
        foreach ($ns in @($applied | Where-Object { $_.type -eq 'nvr-net' -and $_.done -and (NormMac ([string]$_.dev_mac)) -eq (NormMac $expMac) })) {
          $bad = @()
          # 2.2.19 (Codex 2.2.18 F12): the address and the mode are part of the check too (static at the new address)
          if ([string]$n.net_ip -ne [string]$ns.new_ip) { $bad += ('address ' + $(if ($n.net_ip) { $n.net_ip } else { '(not given)' }) + ' (set ' + $ns.new_ip + ')') }
          if ((Get-FnAddrMode $n.addressing) -ne 'static') { $bad += ('addressing ' + $(if ($n.addressing) { $n.addressing } else { '(not given)' }) + ' (set static)') }
          if ($ns.new_mask -and $n.mask -ne $ns.new_mask) { $bad += ('mask ' + $n.mask + ' (set ' + $ns.new_mask + ')') }
          if ($ns.new_gw -and $n.gw -ne $ns.new_gw) { $bad += ('gateway ' + $n.gw + ' (set ' + $ns.new_gw + ')') }
          if ($ns.new_dns1 -and $n.dns1 -ne $ns.new_dns1) { $bad += ('DNS ' + $n.dns1 + ' (set ' + $ns.new_dns1 + ')') }
          if ($ns.new_dns2 -and $n.dns2 -ne $ns.new_dns2) { $bad += ('DNS 2 ' + $n.dns2 + ' (set ' + $ns.new_dns2 + ')') }
          if ($bad.Count) { Say ('NVR ' + $n.ip + ': the network settings read back different from what was set: ' + ($bad -join ', ')) 'Red'; $verify.Add('NVR ' + $n.ip + ': network settings NOT as set (' + ($bad -join ', ') + ')') }
        }
      }
      $curChs = @($n.channels | Where-Object { $_ })
      if ($n.channels_read -eq $false -or (-not $curChs.Count -and $expIds.Count)) {
        Say ('Cameras: the NVR''s camera list could not be read now' + $(if ($expIds.Count) { ' (it had ' + $expIds.Count + ' camera(s) before the fix)' } else { '' }) + ' - NOT CHECKED.') 'Red'
        $verify.Add('NVR ' + $n.ip + ': camera list could not be read after the fix' + $(if ($expIds.Count) { ' (' + $expIds.Count + ' camera(s) before: ' + (($expIds | ForEach-Object { 'D' + $_ }) -join ' ') + ')' } else { '' }) + ' - cameras NOT CHECKED')
        continue
      }
      $curIds = @($curChs | ForEach-Object { [string]$_.id })
      $gone = @($expIds | Where-Object { $curIds -notcontains $_ })
      if ($gone.Count) { Say ('Cameras: ' + $gone.Count + ' camera(s) the NVR had before the fix are not on its list now (' + (($gone | ForEach-Object { 'D' + $_ }) -join ' ') + ') - NOT CHECKED.') 'Red'; $verify.Add('NVR ' + $n.ip + ': ' + $gone.Count + ' camera(s) missing from the camera list after the fix (' + (($gone | ForEach-Object { 'D' + $_ }) -join ' ') + ') - NOT CHECKED') }
      if ($curChs.Count) {
        Start-Sleep -Seconds $(if ($Mock) { 0 } else { 20 })
        if ($n.brand -eq 'hik') {
          $st2 = Http $n.ip 'GET' '/ISAPI/ContentMgmt/InputProxy/channels/status' '' 'application/xml' $script:credNvr
          if ($st2.code -ne 200) { Say ('Cameras: the NVR''s camera status could not be read now - NOT CHECKED.') 'Red'; $verify.Add('NVR ' + $n.ip + ': camera status could not be read - NOT CHECKED'); continue }
          $onl = @{}; foreach ($mm in [regex]::Matches($st2.body, '(?s)<InputProxyChannelStatus[ >].*?</InputProxyChannelStatus>')) { $onl[(XVal $mm.Value 'id')] = ((XVal $mm.Value 'online') -eq 'true') }
          foreach ($ch in $n.channels) { if ($onl.ContainsKey($ch.id)) { $ch.online = $onl[$ch.id] } else { $ch.online = $null } }
        }
        $off = @($n.channels | Where-Object { -not $_.online })
        Say ('Cameras online: ' + ($n.channels.Count - $off.Count) + ' of ' + $n.channels.Count + $(if ($off.Count) { '  | offline or not checked: ' + (($off | ForEach-Object { 'D' + $_.id + ' ' + $_.ip }) -join ', ') } else { '' })) $(if ($off.Count) { 'Red' } else { 'Green' })
        if ($off.Count) { $verify.Add('NVR ' + $n.ip + ': ' + $off.Count + ' camera(s) offline or not checked (' + (($off | ForEach-Object { 'D' + $_.id }) -join ' ') + ')') }
      }
    }
  }
  $fails = @($applied | Where-Object { -not $_.done })
  # 2.2.3 (Codex #62): steps left to a person, and platform access that Undo cannot turn back off, are NOT a clean finish
  $fails += @($manual | ForEach-Object { [pscustomobject]@{ type = $_.type; done = $false; result = 'by hand' } })
  if ($rev) { foreach ($pp in @($rb.steps | Where-Object { $_.done -and $_.type -eq 'nvr-platform' })) { Say ('Undo does not turn platform access (Hik-Connect / EZCloud) back off: turn it off in the NVR''s own menu if it was off before.') 'Yellow'; $fails += [pscustomobject]@{ type = 'nvr-platform'; done = $false; result = 'by hand' } } }
  $nSteps = $fails.Count
  foreach ($u in $netUnchecked) { $verify.Add($u) }   # 2.2.18: sent but not read back (DHCP) is never a clean finish
  $fails += @($verify | ForEach-Object { [pscustomobject]@{ type = 'check'; done = $false; result = $_ } })
  if ($fails.Count) { $script:exitCode = 4 }
  Say ''
  if ($verify.Count) { Say 'After the fix, NOT OK or NOT CHECKED:' 'Red'; foreach ($v in $verify) { Say ('  - ' + $v) 'Red' } }
  # 2.2.18 (Codex 2.2.17 #1): an Undo that left anything not put back says NOT RESTORED (never "Done.", never exit 0)
  if ($rev -and $fails.Count) {
    Say ('NOT RESTORED - see the red lines. ' + $nSteps + ' step(s) not put back. Nothing was sent to a device the tool could not identify by its MAC. Check the devices named above (an address may now belong to a different device), then run Undo again or fix them by hand.') 'Red'
  } else {
    Say $(if ($fails.Count) { 'NOT DONE - see the red lines. ' + $(if ($nSteps) { '' + $nSteps + ' step(s) not done or not confirmed (failed, by hand, or not undoable). ' } else { '' }) + $(if ($verify.Count) { '' + $verify.Count + ' check(s) after the fix not OK or not checked. ' } else { '' }) + 'Fix what is listed and run again, or undo everything with: FixNVR.ps1 -Mode Rollback -RollbackFile "' + $rbPath + '"' } else { 'Done.' + $(if (-not $rev) { ' Undo if needed: FixNVR.ps1 -Mode Rollback -RollbackFile "' + $rbPath + '"' } else { '' }) }) $(if ($fails.Count) { 'Red' } else { 'Green' })
  }
  if (-not $rev -and $Mode -eq 'Fix' -and -not $fails.Count) { Invoke-CamViews $nvrs }
  if (-not $rev) { Say 'Tip: run "NVR Snapshot.cmd" now so the site has a known-good record.' }
}
try { Invoke-Main }
catch { Say ('ERROR: ' + $_.Exception.Message + ' (line ' + $_.InvocationInfo.ScriptLineNumber + ')') 'Red'; Log $_.ScriptStackTrace; $script:exitCode = 5 }
finally {
  # 2.2.10 (Codex R04): a clean-up that is not verified is FAILED (exit 6), whatever the run's own result
  $cleanOk = $false; try { $cleanOk = [bool](Remove-AllTemp) } catch { Say-CleanupFailed @('the clean-up stopped: ' + $_.Exception.Message) }
  if (-not $cleanOk) { $script:exitCode = 6 }
  $after = @($script:devs | ForEach-Object { [ordered]@{ ip = $_.ip; mac = $_.mac; kind = $_.kind; model = $_.model; gw = $_.gw; dns1 = $_.dns1; dns2 = $_.dns2; platform_enabled = $_.platform_enabled; platform_online = $_.platform_online; channel = $_.channel_id } })
  try { Save-Json $after (Join-Path $runDir 'after.json') } catch { Log ('after.json not saved: ' + $_.Exception.Message) }
  $sum | Set-Content (Join-Path $runDir 'summary.txt')
  $script:credNvr = $null; $script:credCam = $null
  Write-Host ('Log folder: ' + $runDir)
}
exit $script:exitCode
