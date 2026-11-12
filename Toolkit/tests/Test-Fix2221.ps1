<# Test-Fix2221.ps1 - WireIt Toolkit 2.2.21 (Nov 12 2026). POSITIVE CONTROLS for the 2.2.21 fixes: the same Codex reproductions that
 Test-Repro2220.ps1 runs (Toolkit\tests\repro-2.2.20), each with its one fault taken out (no device swap, a complete answer, a readable
 field, a file that does not change, ...). Each control must now show the NORMAL outcome, so a fix that just refuses everything fails here.
 Each edit is a literal text replacement that must match exactly once in Codex's script (else FAIL: the script changed under the test).
 Stand-ins for HTTP, adapters, ping, SADP and files as in the reproductions: evidence for the scenario, not a Windows or device run.
 Usage: pwsh -File Test-Fix2221.ps1 [-Repo <folder>]. Exit code = failed checks. #>
param([string]$Repo = '')
$ErrorActionPreference = 'Continue'
if (-not $env:TEMP) { $env:TEMP = [IO.Path]::GetTempPath() }
if (-not $Repo) { $Repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
$Repo = (Resolve-Path -LiteralPath $Repo).Path
$dir = Join-Path $PSScriptRoot 'repro-2.2.20'
$exe = $(if ($PSVersionTable.PSEdition -eq 'Core') { (Get-Process -Id $PID).Path } else { Join-Path $PSHOME 'powershell.exe' })
$script:pass = 0; $script:fail = 0
function Check([bool]$ok, [string]$name, [string]$more = '') {
  if ($ok) { $script:pass++; Write-Host ('PASS ' + $name) } else { $script:fail++; Write-Host ('FAIL ' + $name); if ($more) { Write-Host ('     ' + $more) } }
}
$controls = @(
  @{ f = 'reproduce-extra-review.ps1'; k = 'site-recovery-adapter-swap'; r = 'F03'; find = "remove={param(`$a) `$script:device='B'; `$true}"; repl = "remove={param(`$a) `$true}"; safe = '\bok=True\b'; why = 'the SAME adapter throughout: site recovery completes' },
  @{ f = 'reproduce-extra-review.ps1'; k = 'site-damaged-prefix'; r = 'F04'; find = '"prefix":false}'; repl = '"prefix":24}'; safe = "validator=''"; why = 'a saved address with a valid prefix passes the validator' },
  @{ f = 'reproduce-extra-review.ps1'; k = 'site-clear-unknown-dhcp'; r = 'F05'; find = "[pscustomobject]@{Dhcp='Unknown'}"; repl = "[pscustomobject]@{Dhcp='Disabled'}"; safe = '\bnativeDhcp=False unread= '; why = 'a DHCP reading Windows does give (Disabled) is read as static, with nothing unread' },
  @{ f = 'reproduce-extra-review.ps1'; k = 'dahua-stream-swap'; r = 'F02'; edits = @(@("`$script:device='B';`$true}", '$true}'), @("`$r=Set-FsStream '10.0.0.21' Dahua `$null `$null `$diff", "function Get-FsIdentity {param(`$ip,`$brand,`$cred) [pscustomobject]@{mac=`$(if(`$script:device -eq 'A'){'AA:BB:CC:00:00:21'}else{'AA:BB:CC:00:00:99'});serial=''}}`n`$r=Set-FsStream '10.0.0.21' Dahua `$null `$null `$diff 'AA:BB:CC:00:00:21'")); safe = '\bok=True\b.*writes=A:[^;]*;A:'; why = 'the SAME Dahua camera throughout (it answers its MAC each time): both stream writes are sent and the change is OK' },
  @{ f = 'reproduce-extra-review.ps1'; k = 'dahua-stream-swap'; r = 'F02'; edits = @(,@("`$r=Set-FsStream '10.0.0.21' Dahua `$null `$null `$diff", "function Get-FsIdentity {param(`$ip,`$brand,`$cred) [pscustomobject]@{mac=`$(if(`$script:device -eq 'A'){'AA:BB:CC:00:00:21'}else{'AA:BB:CC:00:00:99'});serial=''}}`n`$r=Set-FsStream '10.0.0.21' Dahua `$null `$null `$diff 'AA:BB:CC:00:00:21'")); safe = '\bok=False\b writes=A:[^;]*$'; why = 'refused for the RIGHT reason: a camera that answers its MAC, swapped after the first write, gets the first write only' },
  @{ f = 'reproduce-extra-review.ps1'; k = 'classic-channel-nvr-swap'; r = 'F01'; edits = @(@("if(`$kind -eq 'camera'){`$script:device='B'};", ''), @("param(`$ip,`$method,`$path,`$body,`$contentType,`$cred,`$timeout)", "param(`$ip,`$method,`$path,`$body,`$contentType,`$cred,`$timeout)`n if(`$path -eq '/ISAPI/System/deviceInfo'){return @{code=200;body=('<DeviceInfo><serialNumber>'+`$(if(`$script:device -eq 'A'){'ORIGINAL'}else{'OTHER'})+'</serialNumber><macAddress>'+`$(if(`$script:device -eq 'A'){'AA:BB:CC:00:00:01'}else{'AA:BB:CC:00:00:99'})+'</macAddress></DeviceInfo>')}}")); safe = '\bok=True\b.*writes=A:'; why = 'the SAME recorder throughout (it answers its MAC each time): the channel write is sent and OK' },
  @{ f = 'reproduce-extra-review.ps1'; k = 'classic-channel-nvr-swap'; r = 'F01'; edits = @(,@("param(`$ip,`$method,`$path,`$body,`$contentType,`$cred,`$timeout)", "param(`$ip,`$method,`$path,`$body,`$contentType,`$cred,`$timeout)`n if(`$path -eq '/ISAPI/System/deviceInfo'){return @{code=200;body=('<DeviceInfo><serialNumber>'+`$(if(`$script:device -eq 'A'){'ORIGINAL'}else{'OTHER'})+'</serialNumber><macAddress>'+`$(if(`$script:device -eq 'A'){'AA:BB:CC:00:00:01'}else{'AA:BB:CC:00:00:99'})+'</macAddress></DeviceInfo>')}}")); safe = '\bok=False writes=$'; why = 'refused for the RIGHT reason: a recorder that answers its MAC but was swapped during the camera check gets nothing' },
  @{ f = 'reproduce-extra-review.ps1'; k = 'classic-missing-dns'; r = 'F06'; find = "dns1='';dns2='';net_has=@{mask=`$true;gw=`$true;dns1=`$false;dns2=`$false}"; repl = "dns1='10.0.0.1';dns2='';net_has=@{mask=`$true;gw=`$true;dns1=`$true;dns2=`$true}"; safe = '\bread=True\b'; why = 'a reading WITH the DNS fields (one of them empty) is a complete backup' },
  @{ f = 'reproduce-nvr-diagnostics.ps1'; k = 'dw-recording-replaced-on-readback'; r = 'F12'; find = "`$mac=if(`$script:swapped){'AA:BB:CC:00:00:99'}else{'AA:BB:CC:00:00:21'}"; repl = "`$mac='AA:BB:CC:00:00:21'"; safe = '\bok=True\b'; why = 'the SAME camera in the DW entry: recording ON is certified' },
  @{ f = 'reproduce-nvr-diagnostics.ps1'; k = 'hik-time-html-first-answer'; r = 'F13'; find = "return @{code=200;body='<html>Login</html>'}"; repl = "return @{code=200;body='<ResponseStatus><statusCode>1</statusCode></ResponseStatus>'}"; safe = 'writes=/ISAPI/System/time/ntpServers/1,/ISAPI/System/time\b'; why = 'a readable OK answer to the NTP-server write goes on to the time-mode write' },
  @{ f = 'reproduce-nvr-diagnostics.ps1'; k = 'standalone-reset-other-device-verified'; r = 'F08'; find = '<serialNumber>OTHER</serialNumber><macAddress>AA:BB:CC:00:00:99</macAddress>'; repl = '<serialNumber>CAM1</serialNumber><macAddress>AA:BB:CC:00:00:21</macAddress>'; safe = '\bok=True\b'; why = 'the SAME device accepts the new password: standalone HikReset verifies it' },
  @{ f = 'reproduce-nvr-diagnostics.ps1'; k = 'legacy-reset-lost-then-refused'; r = 'F10'; find = 'if($script:resetSends -eq 1){return @()}'; repl = ''; safe = "result='failed'"; why = 'a legacy reset form the camera REALLY refuses is still reported as refused' },
  @{ f = 'reproduce-persistence.ps1'; k = 'native-site-record-remove-denied'; r = 'F19'; find = "Write-Error 'delete denied'"; repl = 'Microsoft.PowerShell.Management\Remove-Item -LiteralPath $LiteralPath -Force'; safe = '\bok=True journalExists=False\b'; why = 'a record that CAN be deleted: the native site completion reports success and the record is gone' },
  @{ f = 'reproduce-persistence.ps1'; k = 'site-empty-net-unread'; r = 'F07'; find = 'has=[pscustomobject]@{gw=$false;dns1=$false;dns2=$false}'; repl = 'has=[pscustomobject]@{gw=$true;dns1=$true;dns2=$true}'; safe = "mismatch=''"; why = 'an empty gateway/DNS that WAS read matches an empty saved value' },
  @{ f = 'reproduce-persistence.ps1'; k = 'reset-null-device-list shape=[]'; r = 'F11'; find = "foreach(`$shape in @('null','[null]'))"; repl = "foreach(`$shape in @('[]'))"; safe = '\bexports=1\b'; why = 'devices:[] (an empty, undamaged history) still lets the first export go' },
  @{ f = 'reproduce-persistence.ps1'; k = 'restart-reservation-interleave'; r = 'F15'; find = '$script:nested=$false;$script:second=$null'; repl = '$script:nested=$true;$script:second=$null'; safe = '\bfirst=True\b.*\bdurableReservations=1\b'; why = 'one window alone reserves the restart, and it is on disk' },
  @{ f = 'reproduce-static-and-netcheck.ps1'; k = 'netcheck-truncated-stream-document'; r = 'F16'; find = "body='<StreamingStatus><totalStreamingSessions>'"; repl = "body='<StreamingStatus><totalStreamingSessions>0</totalStreamingSessions></StreamingStatus>'"; safe = '\bresult=nobody\b'; why = 'a complete stream-status document with 0 sessions is still "nobody streaming"' },
  @{ f = 'reproduce-static-and-netcheck.ps1'; k = 'ps51-static-embedded-ternary'; r = 'note'; find = "'`$a = `$b ? 1 : 2'"; repl = "'`$a = `$(if (`$b) { 1 } else { 2 })'"; safe = '\boffenders=0\b'; why = 'PS5.1-safe code inside an executable here-string is not flagged' },
  @{ f = 'reproduce-classic-legacy-adapter.ps1'; k = 'classic-legacy-journal-unread-guid'; r = 'F17'; find = "InterfaceGuid=''"; repl = "InterfaceGuid='{0F0F0F0F-0000-0000-0000-000000000005}'"; safe = '\bremoves=1\b.*\bok=True\b.*\bjournalExists=False\b'; why = 'GUID readable now, OLD record without a GUID (compatibility): the leftover cleanup runs and the record is removed' },
  @{ f = 'reproduce-reset-request-swap.ps1'; k = 'reset-request-swap-during-page-load'; r = 'F18'; find = '{param($s,$seconds)[IO.File]::WriteAllText($script:request,$script:replacement);$true}'; repl = '{param($s,$seconds)$true}'; safe = '\bsubmitted=1\b'; why = 'a request file that does NOT change is attached and submitted' }
)
$work = Join-Path ([IO.Path]::GetTempPath()) ('fix2221-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Force -Path $work | Out-Null
foreach ($c in $controls) {
  $name = ($c.r + ' control ' + $c.k + ': ' + $c.why)
  $src = [IO.File]::ReadAllText((Join-Path $dir $c.f))
  if ($c.edits) { $edits = $c.edits } else { $edits = @(,@($c.find, $c.repl)) }; $bad = ''
  foreach ($e in $edits) {
    $n = ([regex]::Matches($src, [regex]::Escape([string]$e[0]))).Count
    if ($n -ne 1) { $bad = ('the control edit "' + $e[0] + '" matched ' + $n + ' times in ' + $c.f + ' (must be exactly 1)'); break }
    $src = $src.Replace([string]$e[0], [string]$e[1])
  }
  if ($bad) { Check $false $name $bad; continue }
  $p = Join-Path $work ('ctl-' + [guid]::NewGuid().ToString('N') + '.ps1')
  [IO.File]::WriteAllText($p, $src, (New-Object Text.UTF8Encoding($true)))
  $o = Join-Path $work ('out-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Force -Path $o | Out-Null
  $env:REPRO2220_OUT = $o
  $lines = @(& $exe -NoProfile -ExecutionPolicy Bypass -File $p -Repo $Repo 2>&1 | ForEach-Object { [string]$_ })
  $line = @($lines | Where-Object { $_ -match ('^REPRO ' + [regex]::Escape($c.k) + '([ =]|$)') }) | Select-Object -Last 1
  if (-not $line) { Check $false $name ('no REPRO line: ' + ((@($lines) | Select-Object -Last 4) -join ' | ')); continue }
  Write-Host ('    ' + $line)
  Check ($line -match $c.safe) $name $line
}
Remove-Item Env:REPRO2220_OUT -ErrorAction SilentlyContinue
if (Test-Path /bin/chmod) { & /bin/chmod -R u+w $work 2>$null }
Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue
Write-Host ''
Write-Host ('Test-Fix2221: ' + $script:pass + ' passed, ' + $script:fail + ' failed')
exit $script:fail
