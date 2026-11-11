<# Test-Repro2219.ps1 - WireIt Toolkit 2.2.20 (Nov 11 2026). Runs Codex's OWN reproductions from the 2.2.19 review (R01-R21),
 kept verbatim in Toolkit\tests\repro-2.2.19 (only the reviewer's output folder is moved to a temp folder; any other adaptation is
 written in the script's header comment), against this checkout or -Repo <folder>, and checks each REPRO line for the SAFE outcome.
 On 2.2.19 (ca8d5b3) every one of the 26 REPRO lines shows the unsafe outcome (FAIL here); on 2.2.20 each must show the safe one.
 These are Codex's stand-ins for HTTP, Windows adapter commands, ping and persistence failures: a pass is evidence for that
 scenario, not proof of Windows or real-device behaviour. A missing REPRO line is a FAIL (the script died before it), except where
 the safe outcome IS that the script stops (R20: the installer must stop before its "Installed" line).
 Usage: pwsh -File Test-Repro2219.ps1 [-Repo <folder>]. Exit code = failed checks. #>
param([string]$Repo = '')
$ErrorActionPreference = 'Continue'
if (-not $env:TEMP) { $env:TEMP = [IO.Path]::GetTempPath() }
if (-not $Repo) { $Repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
$Repo = (Resolve-Path -LiteralPath $Repo).Path
$dir = Join-Path $PSScriptRoot 'repro-2.2.19'
$exe = $(if ($PSVersionTable.PSEdition -eq 'Core') { (Get-Process -Id $PID).Path } else { Join-Path $PSHOME 'powershell.exe' })
$script:pass = 0; $script:fail = 0; $script:deferred = 0
function Check([bool]$ok, [string]$name, [string]$more = '') {
  if ($ok) { $script:pass++; Write-Host ('PASS ' + $name) } else { $script:fail++; Write-Host ('FAIL ' + $name); if ($more) { Write-Host ('     ' + $more) } }
}
# key = the REPRO name; safe = regex the line MUST match; unsafe = regex it must NOT match; absent = the safe outcome is no such line
$expect = @(
  @{ f = 'reproduce.ps1'; k = 'site-free-on-query-error'; r = 'R04'; safe = 'site-free-on-query-error=False'; why = 'an unreadable neighbour table never certifies an address free' },
  @{ f = 'reproduce.ps1'; k = 'site-save-failed'; r = 'R01'; safe = '\bwrites=0\b'; why = 'no adapter write when the final journal move fails' },
  @{ f = 'reproduce.ps1'; k = 'site-missing-DNS'; r = 'R09'; unsafe = "writeOk=True writtenDnsNode=False verificationWhy=''"; why = 'a DNS the device document does not carry is not written-and-verified' },
  @{ f = 'reproduce.ps1'; k = 'classic-add-replacement'; r = 'R02'; safe = '\bwrites=0\b'; why = 'no address added to a replacement adapter at the saved index' },
  @{ f = 'reproduce.ps1'; k = 'classic-remove-replacement'; r = 'R02'; safe = '\bremoves=0\b'; why = 'no address removed from a replacement adapter at the saved index' },
  @{ f = 'reproduce.ps1'; k = 'password-html'; r = 'R12'; unsafe = '\bok=True\b'; why = 'an HTTP 200 login page is not "the new password works"' },
  @{ f = 'reproduce.ps1'; k = 'firmware-other-mac'; r = 'R11'; unsafe = '\bok=True\b'; why = 'a device with another MAC does not certify the firmware update' },
  @{ f = 'reproduce.ps1'; k = 'firmware-file-changed'; r = 'R05'; safe = '\bwrites=0\b'; why = 'a firmware file changed after YES is not uploaded' },
  @{ f = 'reproduce-real-save.ps1'; k = 'native-journal-move-denied'; r = 'R01'; safe = '\badapterWrites=0\b'; why = 'a real directory-permission failure of the journal stops before the adapter write' },
  @{ f = 'reproduce-extra.ps1'; k = 'classic-clear-with-unrecovered-static-and-skip'; r = 'R07'; unsafe = "reason=''"; why = 'the damaged-record block is not cleared over an unrecovered adapter' },
  @{ f = 'reproduce-extra.ps1'; k = 'classic-missing-mask-gateway'; r = 'R09'; safe = '\bread=False\b'; why = 'a network reading without mask/gateway is not complete' },
  @{ f = 'reproduce-extra.ps1'; k = 'classic-damaged-dhcp'; r = 'R08'; unsafe = "journalWhy=''"; why = 'a journal with "dhcp":"false" (a string) is refused as damaged' },
  @{ f = 'reproduce-extra.ps1'; k = 'classic-channel-no-camera-identity'; r = 'R06'; safe = '\bwrites=0\b'; why = 'channel Undo does not rewrite a channel whose camera was not identified' },
  @{ f = 'reproduce-extra.ps1'; k = 'malformed-reboot-answer'; r = 'R10'; safe = '\bnextBudgetOk=False\b'; why = 'an unreadable reboot answer keeps the restart allowance used' },
  @{ f = 'reproduce-extra.ps1'; k = 'undo-version-mismatch'; r = 'R17'; safe = 'returned=REFUSED\(.*installedVersion=9\.9\.9 |\bjournalExists=True\b'; unsafe = 'installedVersion=9\.9\.7'; why = 'a saved version record for the wrong release is refused (9.9.9 stays installed) or keeps the recovery block; never installs 9.9.7' },
  @{ f = 'reproduce-recording-swap.ps1'; k = 'recording-recorder-swapped'; r = 'R21'; unsafe = 'OTHER track|\bok=True\b'; why = 'no track write to, and no OK from, a replacement recorder' },
  @{ f = 'reproduce-restore.ps1'; k = 'RN-classic-journal'; r = 'R03'; unsafe = 'matchesReplacement=True|planned=[^ ]*(dhcp|removeaddr)'; why = 'a classic journal keeps its adapter identity and does not match a replacement adapter' },
  @{ f = 'reproduce-restore.ps1'; k = 'RN-known-guid-now-missing'; r = 'R03'; safe = '\baccepted=False\b'; why = 'a known saved GUID with no current GUID is a mismatch' },
  @{ f = 'reproduce-restore.ps1'; k = 'GUI-previous-run-within-two-seconds'; r = 'R16'; safe = '\baccepted=False\b'; why = 'the previous run''s result is not read as this run''s' },
  @{ f = 'reproduce-safety.ps1'; k = 'lost-login-answer'; r = 'R13'; test = { param($l) $m = [regex]::Match($l, 'attempts=(\d+) .*max=(\d+)'); $m.Success -and [int]$m.Groups[1].Value -le [int]$m.Groups[2].Value }; why = 'lost login answers stay counted: attempts never exceed the maximum' },
  @{ f = 'reproduce-safety.ps1'; k = 'reset-retry-reservation'; r = 'R14'; safe = '\bexports=1\b'; why = 'the reset retry is reserved before the export, so the same boot is not exported twice' },
  @{ f = 'reproduce-safety.ps1'; k = 'DW-modern-storage-invalid-number'; r = 'R15'; unsafe = '\bstatus=ok\b|\bread=True\b'; why = 'an unreadable DW storage number is not a healthy disk' },
  @{ f = 'reproduce-update-journal.ps1'; k = 'update-returns-success'; r = 'R19'; test = { param($l) ($l -match 'returned=REFUSED\(') -and (($l -match 'installed=9\.9\.8 content=OLD ') -or ($l -match 'journalExists=False installed=9\.9\.9 content=NEW ')) }; why = 'the update is not reported finished while its pending journal remains (refused, and the files match the version record)' },
  @{ f = 'reproduce-diagnostics.ps1'; k = 'stream-error-document'; r = 'R18'; unsafe = '\bresult=nobody\b'; why = 'an HTTP 200 error document is not "nobody streaming"' },
  @{ f = 'reproduce-diagnostics.ps1'; k = 'task-registration-error'; r = 'R20'; absent = $true; why = 'the WifiWatch installer stops before "Installed" when registration fails' }
)
$outs = @{}
foreach ($f in @($expect | ForEach-Object { $_.f } | Select-Object -Unique)) {
  $p = Join-Path $dir $f
  if (-not (Test-Path -LiteralPath $p)) { $outs[$f] = @(); Write-Host ('missing ' + $p); continue }
  $o = Join-Path ([IO.Path]::GetTempPath()) ('repro2219-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Force -Path $o | Out-Null
  $env:REPRO2219_OUT = $o
  Write-Host ('--- ' + $f)
  $lines = @(& $exe -NoProfile -ExecutionPolicy Bypass -File $p -Repo $Repo 2>&1 | ForEach-Object { [string]$_ })
  foreach ($l in $lines) { if ($l -match '^REPRO ') { Write-Host ('    ' + $l) } }
  $outs[$f] = $lines
  & /bin/chmod -R u+w $o 2>$null; Remove-Item -Recurse -Force -LiteralPath $o -ErrorAction SilentlyContinue
}
Remove-Item Env:REPRO2219_OUT -ErrorAction SilentlyContinue
foreach ($e in $expect) {
  $line = @($outs[$e.f] | Where-Object { $_ -match ('^REPRO ' + [regex]::Escape($e.k) + '[ =]') }) | Select-Object -Last 1
  $name = ($e.r + ' ' + $e.k + ': ' + $e.why)
  if ($e.absent) {
    $ran = @($outs[$e.f] | Where-Object { $_ -match '^REPRO ' }).Count -gt 0
    Check ($ran -and -not $line) $name ($(if ($line) { $line } elseif (-not $ran) { 'the script printed no REPRO line at all' } else { '' }))
    continue
  }
  if (-not $line) { Check $false $name ('no REPRO line (the reproduction stopped before it): ' + ((@($outs[$e.f]) | Select-Object -Last 4) -join ' | ')); continue }
  $ok = $true
  if ($e.safe -and $line -notmatch $e.safe) { $ok = $false }
  if ($e.unsafe -and $line -match $e.unsafe) { $ok = $false }
  if ($e.test -and -not (& $e.test $line)) { $ok = $false }
  Check $ok $name $line
}
Write-Host ''
Write-Host ('Test-Repro2219: ' + $script:pass + ' passed, ' + $script:fail + ' failed, ' + $script:deferred + ' deferred')
exit $script:fail
