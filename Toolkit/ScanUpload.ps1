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
function Pending-Path([string]$s) { return (Join-Path $box ('scan-' + (($s -replace '[^A-Za-z0-9_-]+', '_').Trim('_')) + '.json')) }
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
if ($key -and (Test-Path $box)) {
  foreach ($f in @(Get-ChildItem $box -Filter 'scan-*.json' -ErrorAction SilentlyContinue)) {
    if ($f.FullName -eq (Pending-Path $Site)) { continue }   # 2.2.3 (Codex #59): replaced only once the new list is sent or kept (below)
    try { $o = Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { Remove-Item $f.FullName -Force; continue }
    $b = @{}; foreach ($p in $o.PSObject.Properties) { $b[$p.Name] = $p.Value }; $b.key = $key
    $r0 = Send-CvBody $b
    if ($r0 -and $r0.ok) { Remove-Item $f.FullName -Force; Write-Output ('Sent the list that was waiting for ' + [string]$o.site + '.') }
    elseif ($r0 -and -not $r0.ok -and $r0.msg -notmatch '(?i)busy|too many') { Remove-Item $f.FullName -Force; Write-Output ('A waiting list for ' + [string]$o.site + ' was refused: ' + [string]$r0.msg) }
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
if ($r -and $r.ok) { Remove-Item -LiteralPath (Pending-Path $Site) -Force -ErrorAction SilentlyContinue }
if ($retry) {
  # keep ONLY the newest list per site (no pile-up); the key is never written
  New-Item -ItemType Directory -Force -Path $box | Out-Null
  ($body | ConvertTo-Json -Depth 5 -Compress) | Set-Content -Path (Pending-Path $Site) -Encoding UTF8
}
$lines = Format-TkScanAnswer $r $Site
Say-Lines $lines
try {
  $logDir = Join-Path $here 'logs'; New-Item -ItemType Directory -Force -Path $logDir | Out-Null
  $keep = [ordered]@{ at = (Get-Date -Format 's'); site = $Site; snapshot = [bool]$Snapshot; sent = [bool]$r; answer = $r; lines = @($lines | ForEach-Object { $_.t }); red = @($lines | Where-Object { $_.k -eq 'red' } | ForEach-Object { $_.t }) }
  ($keep | ConvertTo-Json -Depth 6) | Set-Content -Path $lastFile -Encoding UTF8
} catch {}
if ($r -and $r.ok) { exit 0 } else { exit 4 }
