<#
 Make-Request.ps1 - package one Hikvision reset request after HiTools "Export XML File".
 Run after: HiTools Delivery > tick the camera > Reset Password > Import/Export Key > Export XML File
            (save into C:\WireIt\CamReset\requests\export ; any folder works, this one is checked first).
 Usage: .\Make-Request.ps1                     (newest .xml exported in the last 2 h; device from the last scan)
        .\Make-Request.ps1 -Serial L12345678 -XmlPath D:\x.xml
 Writes requests\<full serial>\request.json + a copy of the XML. Changes nothing on any device.
 REMEMBER: the camera must NOT reboot or lose power until the key is imported (48 h max).
#>
param([string]$Serial = '', [string]$XmlPath = '')
$ErrorActionPreference = 'Stop'
# 9-char serial: camera ...AAWRK87654321 -> K87654321 ; NVR ...CCRRJ12345678WCVU -> J12345678 (fixed Nov 2: NVRs end in a 4-letter suffix)
function Short([string]$sn) { $m = [regex]::Match($sn, '\d{8}[A-Z]{4}([A-Z0-9]{9})(?:[A-Z]{4})?$'); if ($m.Success) { return $m.Groups[1].Value }; if ($sn.Length -ge 9) { return $sn.Substring($sn.Length - 9) }; return $sn }
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$latest = Get-Content (Join-Path $here 'out\latest.json') -Raw | ConvertFrom-Json
$devs = @($latest.devices | Where-Object { $_.Brand -like 'Hikvision*' })
if (-not $XmlPath) {
  $dirs = @((Join-Path $here 'requests\export'), [Environment]::GetFolderPath('MyDocuments'), (Join-Path $env:USERPROFILE 'Downloads'), [Environment]::GetFolderPath('Desktop'), 'C:\Users\Public\Documents')
  $cand = foreach ($d in $dirs) { if (Test-Path $d) { Get-ChildItem $d -Filter *.xml -File -Recurse -Depth 1 -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt (Get-Date).AddHours(-2) } } }
  $cand = @($cand | Sort-Object LastWriteTime -Descending)
  if (-not $cand) { Write-Host 'No exported .xml from the last 2 hours found. Export it in HiTools first (README step H2).'; exit 1 }
  $XmlPath = $cand[0].FullName
}
$xmlText = Get-Content $XmlPath -Raw
$fn = [IO.Path]::GetFileNameWithoutExtension($XmlPath)
$dev = $null
foreach ($d in $devs) { $sn = [string]$d.Serial; $short = Short $sn
  if (($Serial -and ($sn -eq $Serial -or $short -eq $Serial)) -or (-not $Serial -and ($fn -like "*$short*" -or $xmlText -like "*$short*"))) { $dev = $d } }
if (-not $dev -and -not $Serial -and $devs.Count -eq 1) { $dev = $devs[0] }
if (-not $dev) { Write-Host ('Could not match ' + $XmlPath + ' to a camera from the last scan. Run Find Cameras again, then: .\Make-Request.ps1 -Serial <9-char short serial> -XmlPath "' + $XmlPath + '"'); exit 1 }
$sn = [string]$dev.Serial; $short = Short $sn
$dir = Join-Path $here ('requests\' + ($sn -replace '[^\w\-]', '_')); New-Item -ItemType Directory -Force -Path $dir | Out-Null
Copy-Item $XmlPath (Join-Path $dir ([IO.Path]::GetFileName($XmlPath))) -Force   # (Copy-Item keeps the export time)
# 2.2.3 (Codex #64): the 48 hours run from when HiTools EXPORTED the file (its time on disk), not from packaging it now
$now = (Get-Item -LiteralPath $XmlPath).LastWriteTime; if ($now -gt (Get-Date)) { $now = Get-Date }
if ($now.AddHours(48) -le (Get-Date)) { Write-Host ('That export is from ' + $now.ToString('ddd MMM d h:mm tt') + ' - more than 48 hours ago, so Hikvision will not accept it. Export a new XML in HiTools.'); exit 1 }
$req = [ordered]@{ brand = 'Hikvision'; model = $dev.Model; serial = $sn; shortSerial = $short; startTime = $dev.StartTime; ip = $dev.IP; mac = $dev.MAC
  xmlFile = [IO.Path]::GetFileName($XmlPath); exportedAt = $now.ToString('s'); validUntil = $now.AddHours(48).ToString('s'); status = 'exported'; pc = $env:COMPUTERNAME }
# 2.2.20 (Codex 2.2.19 class A, second pass): "Request ready" only when request.json reads back as written (2.2.19 used a plain
# Set-Content under 'Continue': a refused write was only a warning and "Request ready" was still printed)
$rqPath = Join-Path $dir 'request.json'; $rqJson = [string]($req | ConvertTo-Json); $rqTmp = $rqPath + '.tmp'
try {
  [IO.File]::WriteAllText($rqTmp, $rqJson, (New-Object Text.UTF8Encoding($true)))
  Move-Item -LiteralPath $rqTmp -Destination $rqPath -Force -ErrorAction Stop
  $rqBack = [IO.File]::ReadAllText($rqPath); if ($rqBack.Length -and [int][char]$rqBack[0] -eq 0xFEFF) { $rqBack = $rqBack.Substring(1) }
  if ($rqBack -cne $rqJson) { throw 'it does not read back as written' }
} catch { Write-Host ('The request was NOT saved (' + $rqPath + ': ' + $_.Exception.Message + '). Make the CamReset folder writable, then run this again.'); exit 1 }
# 2.2.3 (Codex #46): the log is best-effort and goes where this login can write; the request is already saved, so it never fails here
$crLog = Join-Path $here 'camreset.log'; try { [IO.File]::AppendAllText($crLog, '') } catch { $crLog = Join-Path $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'WireIt' } else { Join-Path ([IO.Path]::GetTempPath()) 'WireIt' }) 'camreset.log'; try { New-Item -ItemType Directory -Force -Path (Split-Path $crLog) | Out-Null } catch {} }
try { Add-Content -Path $crLog -Value ((Get-Date -Format 's') + ' REQUEST ' + $sn + ' xml=' + $req.xmlFile) -ErrorAction Stop } catch {}
Write-Host ''
Write-Host ('Request ready for ' + $dev.Model + '  serial ' + $sn)
Write-Host ('  Short serial (form): ' + $short)
Write-Host ('  Start time (SADP):   ' + $dev.StartTime)
Write-Host ('  XML:                 ' + (Join-Path $dir $req.xmlFile))
Write-Host ('  Valid until about:   ' + $now.AddHours(48).ToString('ddd MMM d h:mm tt') + '   DO NOT unplug or reboot the camera before the key is imported.')
