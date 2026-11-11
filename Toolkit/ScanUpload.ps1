<#
 ScanUpload.ps1 - WireIt Toolkit: puts the camera list on the site's page (Nov 3 2026).
 Moshe Nov 2 9:24 PM: "after the scan it could get saved to this site, wherever it's supposed to go to, to mesh with everything else".
   -Site <WI-### or address>            after "1 Find cameras": the last scan (CamReset out\latest.json)
   -Site <..> -Snapshot <file.json>     after "6 Save install snapshot": that snapshot as the known-good baseline
 ONE list per site on the service site (op scanPush): compared with what is saved and updated in place; a device the scan no
 longer finds stays on the site page marked Missing (one alert to the office); the same scan twice saves nothing.
 Sends ONLY type, brand, model, serial, MAC, IP, firmware, NVR channel. Never a password. The upload key is the one from
 "Set upload key.cmd" (encrypted for this PC, never written in plain text). No internet: the newest list per site waits in
 outbox\ and goes with the next scan.
 Prints plain lines; lines starting "!! " are shown in red at the top of the Toolkit's results. Result also in logs\scan-upload-last.json.
#>
param([string]$Site = '', [string]$Snapshot = '', [string]$CamResetDir = '', [string]$ApiUrl = '', [switch]$NoSend)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$here = $PSScriptRoot; if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $here 'ToolkitCore.ps1')
$my = @{ Site = $Site; Snapshot = $Snapshot; CamResetDir = $CamResetDir; ApiUrl = $ApiUrl; NoSend = [bool]$NoSend }   # dot-sourcing CamViews re-sets its own -Site etc.
. (Join-Path $here 'CamViews.ps1') -Lib            # the upload key + sender (same as Save camera pictures)
$Site = $my.Site; $Snapshot = $my.Snapshot; $CamResetDir = $my.CamResetDir; $ApiUrl = $my.ApiUrl; $NoSend = $my.NoSend
$ErrorActionPreference = 'Stop'
if ($ApiUrl) { $script:CvApi = $ApiUrl }
if (-not $CamResetDir) { $CamResetDir = Join-Path (Split-Path -Parent $here) 'CamReset' }
$box = Join-Path $here 'outbox'
function Pending-Path([string]$s) { return (Join-Path $box ('scan-' + (Get-CvSiteFolderName $s) + '.json')) }
function Remove-OlderPendingSite([string]$site, [string]$keep = '') {
  foreach ($f in @(Get-ChildItem -LiteralPath $box -Filter 'scan-*.json' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'scan-*.json' })) {
    if ($f.FullName -eq $keep) { continue }
    # a list that cannot be read is NOT removed here (it is not known to be this site's): the waiting-list pass below quarantines it
    try { $v = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json; if ([string]$v.site -eq $site) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop } } catch {}
  }
}
# 2.2.19 (Codex 2.2.18 F25, class E): a waiting list that cannot be read, or that the service refused, is never deleted: it is moved to
# outbox\quarantine\ (Move-CvQuarantine, CamViews.ps1) and named in red, so the technician knows that list was NOT saved to the site page.
function Set-SuQuarantined([string]$path, [string]$why, [string]$tag) {
  $kept = Move-CvQuarantine $path $why $tag
  Write-Output ('!! A waiting camera list (' + (Split-Path -Leaf $path) + ') was NOT saved to the site page: ' + $why + '. ' + $(if ($kept) { 'It is kept as ' + $kept + '.' } else { 'It could not be moved aside, so it stays in the outbox.' }))
}
# 2.2.12 (Codex P2-11 / F18): the waiting list is written to a temporary file beside it first and only then put in its place
# in one step (the same pattern as the Undo file). A write that stops half-way (disk full, power cut) leaves the old list whole.
function Write-SuFileAtomic([string]$path, [string]$text) {
  $tmp = $path + '.' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.tmp'
  try {
    [IO.File]::WriteAllText($tmp, $text, (New-Object Text.UTF8Encoding($false, $true)))   # throws on text it can not write: never a garbled list
    if ([IO.File]::Exists($path)) { [IO.File]::Replace($tmp, $path, [NullString]::Value) } else { [IO.File]::Move($tmp, $path) }
  } finally { if ([IO.File]::Exists($tmp)) { try { [IO.File]::Delete($tmp) } catch {} } }
}
function Say-Lines($lines) {
  foreach ($l in @($lines)) { if (-not $l) { continue }; if ($l.k -eq 'red') { Write-Output ('!! ' + $l.t) } else { Write-Output $l.t } }
}
$Site = $Site.Trim()
$lastFile = Join-Path (Join-Path $here 'logs') 'scan-upload-last.json'; Remove-Item -LiteralPath $lastFile -Force -ErrorAction SilentlyContinue
if (-not $Site) { Write-Output 'Tip: type the site to save this list to the site page.'; exit 0 }
if ($Snapshot) { $devs = @(Get-TkSnapshotDevices $Snapshot); $what = 'install snapshot' } else { $devs = @(Get-TkScanDevices $CamResetDir); $what = 'camera list' }
if (-not $devs.Count) { Write-Output ('Nothing to save to the site page: the ' + $what + ' has no cameras or NVRs.'); exit 0 }
$body = [ordered]@{ op = 'scanPush'; site = $Site; pc = $env:COMPUTERNAME; snapshot = [bool]$Snapshot; devices = @($devs) }
if ($NoSend) { $body | ConvertTo-Json -Depth 5 -Compress; exit 0 }
Write-Output ''
Write-Output ('Saving the ' + $what + ' (' + $devs.Count + ' devices, no passwords) to the site page for "' + $Site + '"...')
$key = Get-CvKey
# lists that waited for internet (other sites; this site's newest list is the one being sent now)
# 2.2.19 (F25): a damaged waiting list is quarantined and named even without a key (and the damaged list for THIS site too: it would
# otherwise be overwritten below without a word)
if (Test-Path $box) {
  foreach ($f in @(Get-ChildItem $box -Filter 'scan-*.json' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'scan-*.json' })) {
    $o = $null; $bad = ''
    try { $o = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch { $bad = 'it is damaged (' + $_.Exception.Message + ')' }
    if (-not $bad -and (-not $o -or [string]$o.op -ne 'scanPush' -or -not [string]$o.site)) { $bad = 'it is not a camera list for a site' }
    if ($bad) { Set-SuQuarantined $f.FullName $bad 'corrupt'; continue }
    if ($f.FullName -eq (Pending-Path $Site)) { continue }   # 2.2.3 (Codex #59): replaced only once the new list is sent or kept (below)
    if ([string]$o.site -eq $Site) { continue }   # an old filename for this site is replaced only after this run is sent or saved
    if (-not $key) { continue }
    $b = @{}; foreach ($p in $o.PSObject.Properties) { $b[$p.Name] = $p.Value }; $b.key = $key
    $r0 = Send-CvBody $b
    if ($r0 -and $r0.ok) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue; Write-Output ('Sent the list that was waiting for ' + [string]$o.site + '.') }
    elseif ($r0 -and -not $r0.ok -and $r0.msg -notmatch '(?i)busy|too many') { Set-SuQuarantined $f.FullName ('the site page refused it for ' + [string]$o.site + ': ' + [string]$r0.msg) 'refused' }
  }
}
$r = $null
if (-not $key) {
  Write-Output 'No upload key on this PC yet: run "Set upload key.cmd" in C:\WireIt\Toolkit once (the same key as Save camera pictures).'
} else {
  $b = @{}; foreach ($k in $body.Keys) { $b[$k] = $body[$k] }; $b.key = $key
  $r = Send-CvBody $b
}
# 2.2.3 (Codex #59): a "busy / too many" answer is not a refusal: the list waits like a no-answer one (it was lost in 2.2.2)
$retry = (-not $r) -or ($r -and -not $r.ok -and ([string]$r.msg) -match '(?i)busy|too many|try again')
if ($r -and $r.ok) { Remove-OlderPendingSite $Site }
if ($retry) {
  # keep ONLY the newest list per site (no pile-up); the key is never written
  New-Item -ItemType Directory -Force -Path $box | Out-Null
  $kept = $false
  try { Write-SuFileAtomic (Pending-Path $Site) ($body | ConvertTo-Json -Depth 5 -Compress); $kept = $true } catch { $kept = $false }
  if ($kept) { Remove-OlderPendingSite $Site (Pending-Path $Site) }
  else { Write-Output ('!! This list could NOT be saved to send later (the disk may be full). Any list that was already waiting for ' + $Site + ' is kept. Free some space and run it again.') }
}
$lines = Format-TkScanAnswer $r $Site
Say-Lines $lines
try {
  $logDir = Join-Path $here 'logs'; New-Item -ItemType Directory -Force -Path $logDir | Out-Null
  $keep = [ordered]@{ at = (Get-Date -Format 's'); site = $Site; snapshot = [bool]$Snapshot; sent = [bool]$r; answer = $r; lines = @($lines | ForEach-Object { $_.t }); red = @($lines | Where-Object { $_.k -eq 'red' } | ForEach-Object { $_.t }) }
  ($keep | ConvertTo-Json -Depth 6) | Set-Content -Path $lastFile -Encoding UTF8
} catch {}
if ($r -and $r.ok) { exit 0 } else { exit 4 }
