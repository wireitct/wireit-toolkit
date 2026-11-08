<#
 Test-Fix223.ps1 - WireIt Toolkit 2.2.3 tests: Codex's full review of toolkit-2.2.2-fixes @5e465b9 (Nov 8 2026).
 One block per finding (#N = Codex's number). A check marked "reproduction" failed on 5e465b9 (2.2.2).
 Device calls are faked by redefining Fs-Http (no sockets) unless a block says otherwise. pwsh 7 or Windows PowerShell 5.1.
 Usage: pwsh -File Test-Fix223.ps1   (exit code = number of failed checks)
#>
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path; $tk = Split-Path -Parent $here; $repo = Split-Path -Parent $tk
$script:fail = 0; $script:pass = 0
function Check([bool]$ok, [string]$what) { if ($ok) { $script:pass++; Write-Host ('  ok    ' + $what) } else { $script:fail++; Write-Host ('  FAIL  ' + $what) -ForegroundColor Red } }
function Eq($a, $b, [string]$what) { Check ("$a" -eq "$b") ($what + ' (got "' + $a + '", want "' + $b + '")') }
function Read-Src([string]$rel) { return [IO.File]::ReadAllText((Join-Path $repo $rel)) }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fix223-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Force -Path $tmp | Out-Null
. (Join-Path $tk 'WireItAcl.ps1'); . (Join-Path $tk 'FixSiteIpc.ps1'); . (Join-Path $tk 'FixSiteCore.ps1'); . (Join-Path $tk 'FixSiteDevices.ps1')
$script:LogLines = New-Object System.Collections.ArrayList
function Fs-LogLine([string]$s) { [void]$script:LogLines.Add($s) }
# fake device: $script:Fake = @{ 'GET 1.2.3.4/path' = 'body' or @{code=..;body=..} }; every call is recorded in $script:Calls
$script:Fake = @{}; $script:Calls = New-Object System.Collections.ArrayList
$script:RealFsHttp = ${function:Fs-Http}
function Use-Fake { Set-Item -Path function:global:Fs-Http -Value {
  param([string]$Ip, [string]$Path, [string]$Method = 'GET', [string]$Body = '', [string]$ContentType = 'application/xml', $Cred = $null, [int]$Timeout = 8, [string]$OutFile = '', [switch]$Secret, [switch]$Tls)
  $k = $Method + ' ' + $Ip + $Path; [void]$script:Calls.Add([pscustomobject]@{ key = $k; body = $Body; tls = [bool]$Tls; cred = $Cred })
  $v = $null; foreach ($p in $script:Fake.Keys) { if ($k -like $p) { $v = $script:Fake[$p]; break } }
  if ($v -is [scriptblock]) { $v = & $v $k $Body }
  if ($null -eq $v) { return [pscustomobject]@{ code = 404; body = '' } }
  if ($v -is [string]) { $v = @{ code = 200; body = $v } }
  if ($OutFile -and $v.code -eq 200) { [IO.File]::WriteAllText($OutFile, [string]$v.body); return [pscustomobject]@{ code = 200; body = '' } }
  return [pscustomobject]@{ code = [int]$v.code; body = [string]$v.body; err = [string]$v.err }
} }
Use-Fake
try {
Write-Host '#10 Get-FsNet picks the interface carrying the address being contacted'
$script:Fake = @{
  'GET 192.168.1.20/ISAPI/System/Network/interfaces' = '<NetworkInterfaceList><NetworkInterface><id>1</id><IPAddress><ipAddress>10.10.0.1</ipAddress><subnetMask>255.255.255.0</subnetMask></IPAddress></NetworkInterface><NetworkInterface><id>2</id><IPAddress><ipAddress>192.168.1.20</ipAddress><subnetMask>255.255.255.0</subnetMask></IPAddress></NetworkInterface></NetworkInterfaceList>'
  'GET 192.168.1.20/ISAPI/System/Network/interfaces/1/ipAddress' = '<IPAddress><addressingType>static</addressingType><ipAddress>10.10.0.1</ipAddress><subnetMask>255.255.255.0</subnetMask></IPAddress>'
  'GET 192.168.1.20/ISAPI/System/Network/interfaces/2/ipAddress' = '<IPAddress><addressingType>static</addressingType><ipAddress>192.168.1.20</ipAddress><subnetMask>255.255.255.0</subnetMask></IPAddress>'
}
$n = Get-FsNet '192.168.1.20' 'Hikvision' $null
Eq $n.iface '2' 'reproduction: dual-interface NVR -> the LAN interface (2), not the PoE camera interface (1)'
Eq $n.ip '192.168.1.20' '...and its address'
$script:Fake['GET 192.168.1.30/ISAPI/System/Network/interfaces'] = '<NetworkInterfaceList><NetworkInterface><id>1</id><IPAddress><ipAddress>192.168.1.30</ipAddress></IPAddress></NetworkInterface></NetworkInterfaceList>'
$script:Fake['GET 192.168.1.30/ISAPI/System/Network/interfaces/1/ipAddress'] = '<IPAddress><ipAddress>192.168.1.30</ipAddress></IPAddress>'
Eq (Get-FsNet '192.168.1.30' 'Hikvision' $null).iface '1' 'single interface still works'
$script:Fake['GET 192.168.1.31/ISAPI/System/Network/interfaces'] = '<NetworkInterfaceList><NetworkInterface><id>1</id><IPAddress><ipAddress>10.1.1.1</ipAddress></IPAddress></NetworkInterface><NetworkInterface><id>2</id><IPAddress><ipAddress>10.2.2.2</ipAddress></IPAddress></NetworkInterface></NetworkInterfaceList>'
Check ($null -eq (Get-FsNet '192.168.1.31' 'Hikvision' $null)) 'several interfaces and none carries the contacted address -> no answer (nothing is changed), not a guess'
Write-Host '#11 OEM / other-brand recorders are recorders, not cameras'
. (Join-Path $tk 'ToolkitCore.ps1')
foreach ($m in @('ERI-K108-P8', 'HWN-4108MH-8P', 'DHI-NVR4108HS-8P-4KS2', 'NVR4216-16P-4KS2', 'XVR5108HS', 'NVR301-08S', 'DS-7608NI-K2/8P', 'iDS-7204HUHI-M1/S', 'DS-9632NI-I8')) { Eq (Get-TkDeviceKind $m) 'recorder' ('reproduction: ' + $m + ' is a recorder') }
foreach ($m in @('DS-2CD2143G2-I', 'IPC2124LB-SF28KM-G', 'ECI-T44F2', 'IPC-HFW2431S-S-S2', 'DS-2DE4425IW-DE')) { Eq (Get-TkDeviceKind $m) 'camera' ($m + ' stays a camera') }
#@@BLOCKS@@
} finally {
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
Write-Host ''; Write-Host ('Test-Fix223: ' + $script:pass + ' passed, ' + $script:fail + ' failed') -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
exit $script:fail
