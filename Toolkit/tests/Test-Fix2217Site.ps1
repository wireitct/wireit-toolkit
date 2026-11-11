<# Test-Fix2217Site.ps1 - WireIt Toolkit 2.2.17, Fix this site: Codex's re-review of 2.2.16 (head c9f9fb2): "a forward camera fix can
   succeed without the NVR identity that Undo now requires".
   A camera fix that writes to its NVR (new password on the NVR channel, a move the channel follows, the channel put back) first reads
   and records WHICH NVR that is (MAC / serial). If the NVR does not tell it, nothing is changed on the camera or the NVR (Still a
   problem, nonzero exit, the reason said plainly). The in-run undo of a camera password (Undo-CamPassword, when the picture does not
   come back) follows the same rule as Undo: it writes nothing unless the NVR answering now is the one recorded before the change.
   The real FixSite.ps1 against the repo's mock devices (tests/repro-2.2.16, loopback only, each mode runs twice), and the real
   Undo-CamPassword taken from FixSite.ps1 by its AST with the real FixSiteCore.ps1 / FixSiteDevices.ps1 (stand-ins for the HTTP layer
   and the device writes only). Controls (marked "control") pass on old and new code. FIX2217_REPO = another checkout (e.g. 2.2.16
   c9f9fb2) to prove these tests fail there. Windows PowerShell 5.1 or pwsh 7. #>
$ErrorActionPreference = 'Stop'
$tk = Split-Path -Parent $PSScriptRoot; $repo = Split-Path -Parent $tk
if ($env:FIX2217_REPO) { $repo = $env:FIX2217_REPO; $tk = Join-Path $repo 'Toolkit' }
$exe = $(if ($PSVersionTable.PSEdition -eq 'Core') { (Get-Process -Id $PID).Path } else { Join-Path $PSHOME 'powershell.exe' })
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fix2217site-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$script:pass = 0; $script:fail = 0; $script:deferred = 0
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
$load = ". " + (Q (Join-Path $tk 'FixSiteCore.ps1')) + "; . " + (Q (Join-Path $tk 'FixSiteDevices.ps1')) + "`n" + '$FixSitePath = ' + (Q (Join-Path $tk 'FixSite.ps1')) + "`n"
try {
  . (Join-Path $PSScriptRoot 'TestPython.ps1'); $py = Get-TestPython
  $e = $null; [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $tk 'FixSite.ps1'), [ref]$null, [ref]$e); Check ($e.Count -eq 0) 'parses: FixSite.ps1' ($e | Out-String)

  # =====================================================================================
  # The in-run undo of a camera password (Undo-CamPassword) checks the NVR's identity before it writes anything
  $d = Invoke-Driver 'undocam' ($load + @'
$ErrorActionPreference = 'Continue'
$ast = [Management.Automation.Language.Parser]::ParseFile($FixSitePath, [ref]$null, [ref]$null)
$fn = $ast.FindAll({ param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Undo-CamPassword' }, $true) | Select-Object -First 1
. ([scriptblock]::Create($fn.Extent.Text))
function Fs-LogLine { param($t) }
function Fs-Sleep { param($s) }
$script:FsMockUrl = 'http://127.0.0.1:1'
$script:Dev = @{ mac = 'c4:2f:90:00:00:19'; serial = 'NVRSER19' }
function Fs-Http { param($Ip, $Method = 'GET', $Path, $Cred, $Body, $Timeout, $OutFile)
  if ($Path -eq '/ISAPI/System/deviceInfo' -and $Ip -eq '192.168.1.50') { return @{ code = 200; body = '<DeviceInfo><model>DS-2CD</model><serialNumber>CAMSER150</serialNumber><macAddress>c4:2f:90:00:01:50</macAddress></DeviceInfo>' } }   # 2.2.19: the camera itself (Undo-CamPassword now checks the camera's MAC too)
  if ($Path -eq '/ISAPI/System/deviceInfo') { return @{ code = 200; body = ('<DeviceInfo><model>DS-7608</model>' + $(if ($script:Dev.serial) { '<serialNumber>' + $script:Dev.serial + '</serialNumber>' } else { '' }) + $(if ($script:Dev.mac) { '<macAddress>' + $script:Dev.mac + '</macAddress>' } else { '' }) + '</DeviceInfo>') } }
  return @{ code = 404; body = '' } }
$script:W = @()
function Set-FsPassword { param($ip, $brand, $cred, $new) $script:W += ('camera-password ' + $ip); return $true }
function Test-FsLogin { param($ip, $brand, $pw) return 'ok' }
function Set-FsNvrChannel { param($nvr, $cred, $ch, $ip, $pw, $brand, $dir) $script:W += ('nvr-channel ' + $nvr + ' ch ' + $ch); return [pscustomobject]@{ ok = $true; action = 'updated'; before = '' } }
function Test-FsVideo { return $true }
$sitePw = 'Sitepass456'
$nvrCred = @{ '192.168.1.19' = (Fs-Cred 'Sitepass456') }
$c = [pscustomobject]@{ name = 'Gate'; brand = 'Hikvision'; nvr = '192.168.1.19'; channel = 1; mac = 'c4:2f:90:00:01:50' }
$rbc = [ordered]@{ name = 'Gate'; nvr_id = [ordered]@{ nvr = '192.168.1.19'; mac = 'c4:2f:90:00:00:19'; serial = 'NVRSER19' } }
$o = [ordered]@{}
foreach ($k in @('same', 'other', 'noid')) {
  $script:W = @(); $script:FsNvrIdOk = @{}; $script:FsNvrIds = @{}
  if ($k -eq 'same') { $script:Dev = @{ mac = 'c4:2f:90:00:00:19'; serial = 'NVRSER19' } }
  elseif ($k -eq 'other') { $script:Dev = @{ mac = 'c4:2f:90:00:00:20'; serial = 'OTHER-NVR' } }
  else { $script:Dev = @{ mac = ''; serial = '' } }
  $u = Undo-CamPassword $c '192.168.1.50' 'Oldpass123'
  $o[$k] = [ordered]@{ ok = [bool]$u.ok; writes = @($script:W); why = $(if ($u.PSObject.Properties['why']) { [string]$u.why } else { '' }) }
}
'JSON=' + ($o | ConvertTo-Json -Compress -Depth 5)
'@)
  $j = Get-Json $d
  if (-not $j) { Check $false 'Undo-CamPassword driver ran' $d }
  else {
    Check ($j.same.ok -and @($j.same.writes).Count -eq 2) 'control: in-run undo of a camera password, the SAME NVR answers: old password back on the camera and its NVR channel' ((@($j.same.writes)) -join ', ')
    Check (-not $j.other.ok -and @($j.other.writes).Count -eq 0) 'in-run undo of a camera password, ANOTHER NVR answers at the address: nothing written (camera or NVR), not ok (2.2.16: wrote both)' ((@($j.other.writes)) -join ', ')
    Check ($j.other.why -match 'ANOTHER device') 'in-run undo of a camera password, ANOTHER NVR: the reason names it' $j.other.why
    Check (-not $j.noid.ok -and @($j.noid.writes).Count -eq 0 -and $j.noid.why -match 'did not tell') 'in-run undo of a camera password, the NVR does not tell its MAC / serial: nothing written, not ok, reason given (2.2.16: wrote both)' ($j.noid.why + ' | ' + ((@($j.noid.writes)) -join ', '))
  }

  # =====================================================================================
  # Source order: the identity is read before the first camera write, and the in-run undo checks it before its first write
  $fsSrc = [IO.File]::ReadAllText((Join-Path $tk 'FixSite.ps1'))
  $loop = [regex]::Match($fsSrc, '(?s)\nforeach \(\$c in \$ordered\) \{\r?\n.*?\n\}')
  $gi = $(if ($loop.Success) { $loop.Value.IndexOf('$nidPre = Get-FsNvrIdRecord') } else { -1 })
  Check ($gi -ge 0 -and $gi -lt $loop.Value.IndexOf('[void](Set-FsPassword') -and $gi -lt $loop.Value.IndexOf('$w = Set-FsNet') -and $gi -lt $loop.Value.IndexOf('$w = Set-FsNvrChannel')) '(source): the camera loop reads the NVR identity before Set-FsPassword, Set-FsNet and Set-FsNvrChannel'
  $ucp = [regex]::Match($fsSrc, '(?s)function Undo-CamPassword.*?\n\}')
  Check ($ucp.Success -and $ucp.Value.IndexOf('Get-FsUndoNvrBlock') -ge 0 -and $ucp.Value.IndexOf('Get-FsUndoNvrBlock') -lt $ucp.Value.IndexOf('Set-FsPassword')) '(source): Undo-CamPassword checks the NVR identity before Set-FsPassword'
  $mis = [regex]::Match($fsSrc, '(?s)\nforeach \(\$c in @\(\$plan\.cams \| Where-Object \{ \$_\.state -eq ''missing'' \}\)\) \{\r?\n.*?\n\}')
  Check ($mis.Success -and $mis.Value -match 'nidM' -and $mis.Value.IndexOf('-not $nidM.mac') -lt $mis.Value.IndexOf('Set-FsNvrChannel')) '(source): a missing camera put back on its NVR channel after a power-cycle needs the NVR identity first'

  # =====================================================================================
  # End to end: the real FixSite.ps1 against the mock devices (each mode runs twice)
  if (-not $py) { $script:deferred++; Write-Host 'DEFERRED end-to-end reproduction: no python on this PC (NEEDS PYTHON)' }
  else {
    $rp = Join-Path $PSScriptRoot 'repro-2.2.16'
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $o = & $py (Join-Path $rp 'reproduce-forward-no-nvr-id.py') --repo $repo --powershell $exe 2>&1 | Out-String; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $prev }
    $lines = @($o -split "`r?`n" | Where-Object { $_ -match '^(PASS|FAIL) ' })
    foreach ($l in $lines) { Check ($l -match '^PASS ') ('end to end: ' + ($l -replace '^(PASS|FAIL) ', '')) }
    $m = [regex]::Match($o, '(?m)^(\d+) passed, (\d+) failed')
    Check ($code -eq 0 -and $m.Success -and [int]$m.Groups[2].Value -eq 0 -and $lines.Count -eq 15) ('end to end: reproduce-forward-no-nvr-id.py exits 0 with all 15 checks [' + $(if ($m.Success) { $m.Value } else { 'no summary' }) + ']') ($o.Substring([Math]::Max(0, $o.Length - 1500)))
  }
  $script:deferred++; Write-Host 'DEFERRED a real Hikvision NVR that does not report its MAC / serial on deviceInfo, and the in-run password undo on a real camera + NVR, on Windows PowerShell 5.1 (NEEDS WINDOWS / REAL-DEVICE CHECK)'
} catch { $script:fail++; Write-Host ('FAIL unexpected error: ' + $_.Exception.Message + ' at ' + $_.InvocationInfo.ScriptLineNumber) }
finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host ('Test-Fix2217Site: ' + $script:pass + ' passed, ' + $script:fail + ' failed' + $(if ($script:deferred) { ', ' + $script:deferred + ' deferred' } else { '' }))
exit $script:fail
