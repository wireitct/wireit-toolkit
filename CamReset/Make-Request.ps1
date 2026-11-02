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
Copy-Item $XmlPath (Join-Path $dir ([IO.Path]::GetFileName($XmlPath))) -Force
$now = Get-Date
$req = [ordered]@{ brand = 'Hikvision'; model = $dev.Model; serial = $sn; shortSerial = $short; startTime = $dev.StartTime; ip = $dev.IP; mac = $dev.MAC
  xmlFile = [IO.Path]::GetFileName($XmlPath); exportedAt = $now.ToString('s'); validUntil = $now.AddHours(48).ToString('s'); status = 'exported'; pc = $env:COMPUTERNAME }
Set-Content -Path (Join-Path $dir 'request.json') -Value ($req | ConvertTo-Json) -Encoding UTF8
Add-Content -Path (Join-Path $here 'camreset.log') -Value ((Get-Date -Format 's') + ' REQUEST ' + $sn + ' xml=' + $req.xmlFile)
Write-Host ''
Write-Host ('Request ready for ' + $dev.Model + '  serial ' + $sn)
Write-Host ('  Short serial (form): ' + $short)
Write-Host ('  Start time (SADP):   ' + $dev.StartTime)
Write-Host ('  XML:                 ' + (Join-Path $dir $req.xmlFile))
Write-Host ('  Valid until about:   ' + $now.AddHours(48).ToString('ddd MMM d h:mm tt') + '   DO NOT unplug or reboot the camera before the key is imported.')
