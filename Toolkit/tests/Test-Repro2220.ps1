<# Test-Repro2220.ps1 - WireIt Toolkit 2.2.21 (Nov 12 2026). Runs Codex's OWN reproductions from the 2.2.20 review (F01-F19 and the two
 test-quality notes), kept in Toolkit\tests\repro-2.2.20 (adaptations: the reviewer's output folder is $env:REPRO2220_OUT, a fresh temp
 folder per run, and $ErrorActionPreference Continue instead of Stop; both written in each script's header), against this checkout or
 -Repo <folder>, and checks each REPRO line for the SAFE outcome. On 2.2.20 (ad27e75) every REPRO line shows the unsafe outcome (FAIL here);
 on 2.2.21 each must show the safe one. These are Codex's stand-ins for HTTP, Windows adapter commands, ping, SADP and persistence: a pass is
 evidence for that scenario, not proof of Windows or real-device behaviour. A missing REPRO line is a FAIL (the script died before it).
 The positive controls (the fixes do not just refuse everything) are in Test-Fix2221.ps1.
 Usage: pwsh -File Test-Repro2220.ps1 [-Repo <folder>]. Exit code = failed checks. #>
param([string]$Repo = '')
$ErrorActionPreference = 'Continue'
if (-not $env:TEMP) { $env:TEMP = [IO.Path]::GetTempPath() }
if (-not $Repo) { $Repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
$Repo = (Resolve-Path -LiteralPath $Repo).Path
$dir = Join-Path $PSScriptRoot 'repro-2.2.20'
$exe = $(if ($PSVersionTable.PSEdition -eq 'Core') { (Get-Process -Id $PID).Path } else { Join-Path $PSHOME 'powershell.exe' })
$script:pass = 0; $script:fail = 0; $script:deferred = 0
function Check([bool]$ok, [string]$name, [string]$more = '') {
  if ($ok) { $script:pass++; Write-Host ('PASS ' + $name) } else { $script:fail++; Write-Host ('FAIL ' + $name); if ($more) { Write-Host ('     ' + $more) } }
}
# key = the REPRO name; safe = regex the line MUST match; unsafe = regex it must NOT match
$expect = @(
  @{ f = 'reproduce-extra-review.ps1'; k = 'site-recovery-adapter-swap'; r = 'F03'; safe = '\bok=False\b.*\bjournalExists=True\b'; why = 'site recovery does not certify a replacement adapter, and keeps the recovery record' },
  @{ f = 'reproduce-extra-review.ps1'; k = 'site-damaged-prefix'; r = 'F04'; safe = "validator='[^']+'"; unsafe = 'addstatic|\bok=True\b'; why = 'a saved address with a damaged prefix is refused before any recovery write' },
  @{ f = 'reproduce-extra-review.ps1'; k = 'site-clear-unknown-dhcp'; r = 'F05'; unsafe = "recoveryWhy=''"; why = 'an unknown DHCP reading cannot clear the damaged-record block' },
  @{ f = 'reproduce-extra-review.ps1'; k = 'dahua-stream-swap'; r = 'F02'; unsafe = '\bB:|\bok=True\b'; why = 'the second Dahua stream write is not sent to a device that changed after the first' },
  @{ f = 'reproduce-extra-review.ps1'; k = 'classic-channel-nvr-swap'; r = 'F01'; unsafe = '\bB:|\bok=True\b'; why = 'the channel write is not sent to a recorder that changed during the camera check' },
  @{ f = 'reproduce-extra-review.ps1'; k = 'classic-missing-dns'; r = 'F06'; safe = '\bread=False\b'; why = 'a network reading without the DNS fields is not a complete backup' },
  @{ f = 'reproduce-extra-review.ps1'; k = 'reset-new-export-answer-lost'; r = 'F09'; safe = '\bexports=1\b'; why = 'a first export whose answer was lost keeps its reservation: the same boot is not exported again' },
  @{ f = 'reproduce-nvr-diagnostics.ps1'; k = 'dw-recording-replaced-on-readback'; r = 'F12'; unsafe = '\bok=True\b|Recording is ON again'; why = 'a replacement camera in the same DW entry does not certify the recording repair' },
  @{ f = 'reproduce-nvr-diagnostics.ps1'; k = 'hik-time-html-first-answer'; r = 'F13'; safe = 'writes=/ISAPI/System/time/ntpServers/1 '; why = 'an HTTP 200 unreadable answer to the NTP-server write stops before the time-mode write' },
  @{ f = 'reproduce-nvr-diagnostics.ps1'; k = 'standalone-reset-other-device-verified'; r = 'F08'; safe = '\bok=False\b'; why = 'standalone HikReset does not verify a different device that accepts the password' },
  @{ f = 'reproduce-nvr-diagnostics.ps1'; k = 'legacy-reset-lost-then-refused'; r = 'F10'; safe = '\bsends=1\b'; unsafe = "result='failed'"; why = 'a legacy reset form whose answer was lost is not followed by another form, and is not reported as a refusal' },
  @{ f = 'reproduce-nvr-diagnostics.ps1'; k = 'sitecheck-unsent-sweep-no-history'; r = 'F14'; unsafe = 'No network problems found'; why = 'SiteCheck with no pings sent does not say "no network problems"' },
  @{ f = 'reproduce-nvr-diagnostics.ps1'; k = 'sitecheck-unsent-sweep'; r = 'F14'; unsafe = 'answered last time .* but not now'; why = 'a previous device whose ping was never sent is NOT CHECKED, not "gone"' },
  @{ f = 'reproduce-persistence.ps1'; k = 'native-site-record-remove-denied'; r = 'F19'; unsafe = '\bok=True\b'; why = 'the native site completion does not report success when its record cannot be deleted' },
  @{ f = 'reproduce-persistence.ps1'; k = 'site-empty-net-unread'; r = 'F07'; unsafe = "mismatch=''"; why = 'an empty gateway/DNS is accepted only when the field was actually read' },
  @{ f = 'reproduce-persistence.ps1'; k = 'reset-null-device-list shape=null'; r = 'F11'; safe = '\bexports=0\b'; why = 'devices:null is damaged history: no new export' },
  @{ f = 'reproduce-persistence.ps1'; k = 'reset-null-device-list shape=[null]'; r = 'F11'; safe = '\bexports=0\b'; why = 'devices:[null] is damaged history: no new export' },
  @{ f = 'reproduce-persistence.ps1'; k = 'restart-reservation-interleave'; r = 'F15'; test = { param($l) -not ($l -match '\bfirst=True\b' -and $l -match '\bsecond=True\b') }; why = 'two windows cannot both reserve the one restart per hour' },
  @{ f = 'reproduce-static-and-netcheck.ps1'; k = 'netcheck-truncated-stream-document'; r = 'F16'; unsafe = '\bresult=nobody\b'; why = 'a truncated stream-status document is not "nobody streaming"' },
  @{ f = 'reproduce-static-and-netcheck.ps1'; k = 'ps51-static-embedded-ternary'; r = 'note'; unsafe = '\boffenders=0\b'; why = 'the PS5.1 scanner finds a PS7 ternary inside an executable here-string ($SC_CODE)' },
  @{ f = 'reproduce-classic-legacy-adapter.ps1'; k = 'classic-legacy-journal-unread-guid'; r = 'F17'; safe = '\bremoves=0\b.*\bjournalExists=True\b'; unsafe = "gateWhy=''"; why = 'older-journal cleanup refuses while the current adapter GUID is unreadable, and keeps the record' },
  @{ f = 'reproduce-reset-request-swap.ps1'; k = 'reset-request-swap-during-page-load'; r = 'F18'; unsafe = '\battachedReplacement=True\b|\bsubmitted=1\b'; why = 'a request file changed while the portal page loads is not attached or submitted' }
)
$outs = @{}
foreach ($f in @($expect | ForEach-Object { $_.f } | Select-Object -Unique)) {
  $p = Join-Path $dir $f
  if (-not (Test-Path -LiteralPath $p)) { $outs[$f] = @(); Write-Host ('missing ' + $p); continue }
  $o = Join-Path ([IO.Path]::GetTempPath()) ('repro2220-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Force -Path $o | Out-Null
  $env:REPRO2220_OUT = $o
  Write-Host ('--- ' + $f)
  $lines = @(& $exe -NoProfile -ExecutionPolicy Bypass -File $p -Repo $Repo 2>&1 | ForEach-Object { [string]$_ })
  foreach ($l in $lines) { if ($l -match '^REPRO ') { Write-Host ('    ' + $l) } }
  $outs[$f] = $lines
  if (Test-Path /bin/chmod) { & /bin/chmod -R u+w $o 2>$null }
  Remove-Item -Recurse -Force -LiteralPath $o -ErrorAction SilentlyContinue
}
Remove-Item Env:REPRO2220_OUT -ErrorAction SilentlyContinue
foreach ($e in $expect) {
  $line = @($outs[$e.f] | Where-Object { $_ -match ('^REPRO ' + [regex]::Escape($e.k) + '([ =]|$)') }) | Select-Object -Last 1
  $name = ($e.r + ' ' + $e.k + ': ' + $e.why)
  if (-not $line) { Check $false $name ('no REPRO line (the reproduction stopped before it): ' + ((@($outs[$e.f]) | Select-Object -Last 4) -join ' | ')); continue }
  $ok = $true
  if ($e.safe -and $line -notmatch $e.safe) { $ok = $false }
  if ($e.unsafe -and $line -match $e.unsafe) { $ok = $false }
  if ($e.test -and -not (& $e.test $line)) { $ok = $false }
  Check $ok $name $line
}
Write-Host ''
Write-Host ('Test-Repro2220: ' + $script:pass + ' passed, ' + $script:fail + ' failed, ' + $script:deferred + ' deferred')
exit $script:fail
