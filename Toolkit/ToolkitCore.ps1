<#
 ToolkitCore.ps1 - the non-screen part of the WireIt Toolkit (Windows PowerShell 5.1, no installs).
 Dot-sourced by WireItToolkit.ps1 and by tests\Test-Toolkit.ps1. Holds no passwords and writes none.
#>
$script:TkAllowedTop = @('Toolkit', 'FixNVR', 'CamReset', 'NetCheck')
$script:TkUpdatePrefix = 'https://raw.githubusercontent.com/wireitct/wireit-toolkit/'

function Get-TkPaths([string]$toolkitDir) {
  $root = Split-Path -Parent $toolkitDir
  [pscustomobject]@{
    Root = $root; Toolkit = $toolkitDir
    FixNVR = Join-Path $root 'FixNVR'; CamReset = Join-Path $root 'CamReset'; NetCheck = Join-Path $root 'NetCheck'
    Logs = Join-Path $toolkitDir 'logs'; Previous = Join-Path $toolkitDir 'previous'; Staging = Join-Path $toolkitDir 'update-staging'
  }
}

function Read-TkJson([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  try { return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}
function Save-TkJson($obj, [string]$path) { ($obj | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $path -Encoding UTF8 }

function Get-TkConfig([string]$toolkitDir) {
  $c = Read-TkJson (Join-Path $toolkitDir 'config.json')
  $d = [ordered]@{
    updateUrl = 'https://raw.githubusercontent.com/wireitct/wireit-toolkit/main/version.json'
    updateTimeoutMs = 4000; autoUpdate = $true
    hikvisionForm = 'https://www.hikvision.com/us-en/support/password-reset/'
    bitwardenUrl = 'https://vault.bitwarden.com/'
    hiTools = @('C:\Program Files (x86)\HiToolsDelivery\client\HiToolsDelivery.exe', 'C:\Program Files\HiToolsDelivery\client\HiToolsDelivery.exe')
    form = [ordered]@{ firstName = 'Moshe'; lastName = 'Reichman'; email = 'moshe@wireitct.com'; company = 'WireIt CT LLC'; state = 'Connecticut'; zip = '06710'; businessType = 'Installer' }
    passwordLength = 14
  }
  if ($c) {
    foreach ($p in $c.PSObject.Properties) {
      if ($p.Name -eq 'form' -and $p.Value) { foreach ($q in $p.Value.PSObject.Properties) { $d.form[$q.Name] = $q.Value } }
      else { $d[$p.Name] = $p.Value }
    }
  }
  return [pscustomobject]$d
}

function Get-TkVersion([string]$toolkitDir) {
  $v = Read-TkJson (Join-Path $toolkitDir 'version.json')
  if ($v -and $v.version) { return [string]$v.version } else { return '0.0.0' }
}

function Compare-TkVersion([string]$a, [string]$b) {
  # -1 a<b, 0 equal, 1 a>b ; numeric parts only
  $pa = @($a -split '[^\d]+' | Where-Object { $_ -ne '' } | ForEach-Object { [int]$_ })
  $pb = @($b -split '[^\d]+' | Where-Object { $_ -ne '' } | ForEach-Object { [int]$_ })
  for ($i = 0; $i -lt [math]::Max($pa.Count, $pb.Count); $i++) {
    $x = 0; $y = 0; if ($i -lt $pa.Count) { $x = $pa[$i] }; if ($i -lt $pb.Count) { $y = $pb[$i] }
    if ($x -lt $y) { return -1 }; if ($x -gt $y) { return 1 }
  }
  return 0
}

function Get-TkSha256([string]$path) {
  $sha = [Security.Cryptography.SHA256]::Create()
  $fs = [IO.File]::OpenRead($path)
  try { return ([BitConverter]::ToString($sha.ComputeHash($fs)) -replace '-', '').ToLower() } finally { $fs.Close(); $sha.Dispose() }
}

function Test-TkManifestPath([string]$p) {
  # only plain relative paths under the 4 tool folders; never config.json (local settings stay local)
  if (-not $p) { return $false }
  if ($p -match '\.\.' -or $p -match '^[\\/]' -or $p -match ':' ) { return $false }
  $parts = $p -split '[\\/]'
  if ($parts.Count -lt 2) { return $false }
  if ($script:TkAllowedTop -notcontains $parts[0]) { return $false }
  if ($parts[-1] -ieq 'config.json') { return $false }
  return $true
}

function Test-TkManifest($m) {
  if (-not $m -or -not $m.version -or -not $m.base -or -not $m.files) { return 'manifest is missing version/base/files' }
  if (-not ([string]$m.base).StartsWith($script:TkUpdatePrefix)) { return 'download address is not the WireIt toolkit repository' }
  foreach ($f in $m.files) {
    if (-not (Test-TkManifestPath ([string]$f.path))) { return ('file path not allowed: ' + $f.path) }
    if (-not ($f.sha256 -match '^[0-9a-fA-F]{64}$')) { return ('bad hash for ' + $f.path) }
  }
  return ''
}

function Get-TkWeb([string]$url, [int]$timeoutMs) {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $req = [Net.WebRequest]::Create($url)
  $req.Timeout = $timeoutMs
  if ($req -is [Net.HttpWebRequest]) { $req.ReadWriteTimeout = $timeoutMs; $req.UserAgent = 'WireIt-Toolkit' }
  $req.CachePolicy = New-Object Net.Cache.RequestCachePolicy([Net.Cache.RequestCacheLevel]::NoCacheNoStore)
  $resp = $req.GetResponse()
  try { $ms = New-Object IO.MemoryStream; $resp.GetResponseStream().CopyTo($ms); return $ms.ToArray() } finally { $resp.Close() }
}

function Get-TkUpdateInfo($cfg, [string]$toolkitDir) {
  # returns @{ state = 'offline'|'current'|'available'|'error'; manifest; message }
  $cur = Get-TkVersion $toolkitDir
  try { $bytes = Get-TkWeb ([string]$cfg.updateUrl) ([int]$cfg.updateTimeoutMs) }
  catch { return [pscustomobject]@{ state = 'offline'; manifest = $null; current = $cur; message = 'No internet (or update site not reachable) - running this version.' } }
  try { $m = [Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF) | ConvertFrom-Json } catch { return [pscustomobject]@{ state = 'error'; manifest = $null; current = $cur; message = 'Update info unreadable - running this version.' } }
  $bad = Test-TkManifest $m
  if ($bad) { return [pscustomobject]@{ state = 'error'; manifest = $null; current = $cur; message = ('Update refused: ' + $bad) } }
  if ((Compare-TkVersion ([string]$m.version) $cur) -le 0) { return [pscustomobject]@{ state = 'current'; manifest = $m; current = $cur; message = ('Up to date (v' + $cur + ').') } }
  return [pscustomobject]@{ state = 'available'; manifest = $m; current = $cur; message = ('New version ' + $m.version + ' available (this is ' + $cur + ').') }
}

function Install-TkUpdate($m, [string]$toolkitDir, [scriptblock]$Fetch = $null) {
  # Downloads every file to staging, checks each SHA-256, then swaps them in. Keeps the replaced files in previous\
  # so "Go back" restores them. Any failure before the swap changes nothing; a failure during the swap restores.
  $P = Get-TkPaths $toolkitDir
  $bad = Test-TkManifest $m; if ($bad) { throw ('Update refused: ' + $bad) }
  if (Test-Path $P.Staging) { Remove-Item $P.Staging -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $P.Staging | Out-Null
  foreach ($f in $m.files) {
    $dst = Join-Path $P.Staging $f.path; New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
    $url = ([string]$m.base).TrimEnd('/') + '/' + (($f.path -split '[\\/]' | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/')
    if ($Fetch) { $bytes = & $Fetch $url } else { $bytes = Get-TkWeb $url 30000 }
    [IO.File]::WriteAllBytes($dst, [byte[]]$bytes)
    $h = Get-TkSha256 $dst
    if ($h -ne ([string]$f.sha256).ToLower()) { Remove-Item $P.Staging -Recurse -Force; throw ('Download check failed for ' + $f.path + ' (file damaged or changed). Nothing was changed.') }
  }
  $old = Get-TkVersion $toolkitDir
  $prev = Join-Path $P.Previous $old
  if (Test-Path $prev) { Remove-Item $prev -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $prev | Out-Null
  $added = New-Object System.Collections.Generic.List[string]
  foreach ($f in $m.files) {
    $live = Join-Path $P.Root $f.path
    if (Test-Path -LiteralPath $live) { $b = Join-Path $prev $f.path; New-Item -ItemType Directory -Force -Path (Split-Path -Parent $b) | Out-Null; Copy-Item -LiteralPath $live $b -Force }
    else { $added.Add([string]$f.path) }
  }
  $vj = Join-Path $toolkitDir 'version.json'
  if (Test-Path $vj) { Copy-Item $vj (Join-Path $prev 'version.json.prev') -Force }
  Save-TkJson ([ordered]@{ from = $old; to = [string]$m.version; at = (Get-Date -Format 's'); added = $added.ToArray() }) (Join-Path $prev 'undo.json')
  $done = New-Object System.Collections.Generic.List[string]
  try {
    foreach ($f in $m.files) {
      $live = Join-Path $P.Root $f.path; New-Item -ItemType Directory -Force -Path (Split-Path -Parent $live) | Out-Null
      Copy-Item -LiteralPath (Join-Path $P.Staging $f.path) $live -Force; $done.Add([string]$f.path)
    }
    Save-TkJson ([ordered]@{ version = [string]$m.version; released = $m.released; commit = $m.commit; previous = $old; installed = (Get-Date -Format 's') }) $vj
  } catch {
    foreach ($p in $done) { $b = Join-Path $prev $p; if (Test-Path -LiteralPath $b) { Copy-Item -LiteralPath $b (Join-Path $P.Root $p) -Force } elseif ($added -contains $p) { Remove-Item -LiteralPath (Join-Path $P.Root $p) -Force -ErrorAction SilentlyContinue } }
    if (Test-Path (Join-Path $prev 'version.json.prev')) { Copy-Item (Join-Path $prev 'version.json.prev') $vj -Force }
    throw ('Update could not be installed, the old version was put back: ' + $_.Exception.Message)
  }
  Remove-Item $P.Staging -Recurse -Force -ErrorAction SilentlyContinue
  return $old
}

function Undo-TkUpdate([string]$toolkitDir) {
  # put back the version that the last update replaced
  $P = Get-TkPaths $toolkitDir
  $cur = Read-TkJson (Join-Path $toolkitDir 'version.json')
  if (-not $cur -or -not $cur.previous) { throw 'There is no earlier version saved on this PC.' }
  $prev = Join-Path $P.Previous ([string]$cur.previous)
  $u = Read-TkJson (Join-Path $prev 'undo.json')
  if (-not $u) { throw ('The saved copy of version ' + $cur.previous + ' is missing.') }
  Get-ChildItem -LiteralPath $prev -Recurse -File | Where-Object { $_.Name -notin @('undo.json', 'version.json.prev') } | ForEach-Object {
    $rel = $_.FullName.Substring($prev.Length).TrimStart('\', '/')
    $dst = Join-Path $P.Root $rel; New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
    Copy-Item -LiteralPath $_.FullName $dst -Force
  }
  foreach ($a in @($u.added)) { if ($a -and (Test-TkManifestPath $a)) { Remove-Item -LiteralPath (Join-Path $P.Root $a) -Force -ErrorAction SilentlyContinue } }
  $vp = Join-Path $prev 'version.json.prev'
  if (Test-Path $vp) { Copy-Item $vp (Join-Path $toolkitDir 'version.json') -Force }
  # stop the next start from re-installing the version we just left
  $cfgPath = Join-Path $toolkitDir 'skip-version.txt'; Set-Content -Path $cfgPath -Value ([string]$cur.version)
  return [string]$cur.previous
}

function Get-TkSkipVersion([string]$toolkitDir) { $p = Join-Path $toolkitDir 'skip-version.txt'; if (Test-Path $p) { return (Get-Content $p -Raw).Trim() } ; return '' }

# ---------------- passwords ----------------
function New-TkPassword([int]$length = 14) {
  # Hikvision rule: 8-16 chars, 2+ kinds; we use all 4 kinds, no look-alike characters, no "admin".
  if ($length -lt 10) { $length = 10 }; if ($length -gt 16) { $length = 16 }
  $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnpqrstuvwxyz', '23456789', '#@!%*+=?')
  $all = -join $sets
  $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
  $pick = { param($s) $b = New-Object byte[] 4; do { $rng.GetBytes($b); $n = [BitConverter]::ToUInt32($b, 0) } while ($n -ge ([uint32]::MaxValue - ([uint32]::MaxValue % $s.Length))); $s[[int]($n % $s.Length)] }
  for ($try = 0; $try -lt 50; $try++) {
    $c = New-Object System.Collections.Generic.List[char]
    foreach ($s in $sets) { $c.Add((& $pick $s)) }
    while ($c.Count -lt $length) { $c.Add((& $pick $all)) }
    for ($i = $c.Count - 1; $i -gt 0; $i--) { $b = New-Object byte[] 4; $rng.GetBytes($b); $j = [int]([BitConverter]::ToUInt32($b, 0) % [uint32]($i + 1)); $t = $c[$i]; $c[$i] = $c[$j]; $c[$j] = $t }
    $pw = -join $c
    if ($pw -notmatch '(?i)admin' -and $pw -notmatch '(.)\1\1' -and $sets[3].IndexOfAny($pw[0]) -lt 0) { $rng.Dispose(); return $pw }
  }
  $rng.Dispose(); return $pw
}

# ---------------- cameras / reset requests ----------------
function Get-TkShortSerial([string]$serial) {
  # Hikvision full serial = model + date (8 digits) + 4 letters + the 9-character serial [+ 4-letter suffix on NVRs]:
  #   camera ...20220101AAWRK87654321 -> K87654321 ; NVR ...20210101CCRRJ12345678WCVU -> J12345678 ; new ...AAWRAF1234567 -> AF1234567
  if (-not $serial) { return '' }
  $s = $serial.Trim()
  $m = [regex]::Match($s, '\d{8}[A-Z]{4}([A-Z0-9]{9})(?:[A-Z]{4})?$')
  if ($m.Success) { return $m.Groups[1].Value }
  if ($s.Length -gt 9) { return $s.Substring($s.Length - 9) } ; return $s
}

function Get-TkDevices([string]$camResetDir) {
  $l = Read-TkJson (Join-Path $camResetDir 'out\latest.json')
  if (-not $l) { return @() }
  $out = foreach ($d in @($l.devices)) {
    if (-not $d) { continue }
    [pscustomobject]@{
      Brand = [string]$d.Brand; Model = [string]$d.Model; Serial = [string]$d.Serial; ShortSerial = (Get-TkShortSerial ([string]$d.Serial))
      IP = [string]$d.IP; MAC = [string]$d.MAC; StartTime = [string]$d.StartTime; Activated = [string]$d.Activated
      Status = [string]$d.Status; NextStep = [string]$d.NextStep; DefaultLoginWorks = [string]$d.DefaultLoginWorks
    }
  }
  return @($out)
}
function Get-TkScanTime([string]$camResetDir) { $l = Read-TkJson (Join-Path $camResetDir 'out\latest.json'); if ($l -and $l.scannedAt) { try { return ([datetime]::Parse([string]$l.scannedAt)).ToString('ddd MMM d, h:mm tt') } catch { return [string]$l.scannedAt } }; $p = Join-Path $camResetDir 'out\latest.json'; if (Test-Path $p) { return (Get-Item $p).LastWriteTime.ToString('ddd h:mm tt') }; return '' }

function Get-TkRequests([string]$camResetDir) {
  $dir = Join-Path $camResetDir 'requests'
  if (-not (Test-Path $dir)) { return @() }
  $r = foreach ($f in Get-ChildItem $dir -Recurse -Filter request.json -File -ErrorAction SilentlyContinue) {
    $j = Read-TkJson $f.FullName; if (-not $j) { continue }
    $j | Add-Member -NotePropertyName folder -NotePropertyValue $f.DirectoryName -Force
    $j
  }
  return @($r | Sort-Object { [string]$_.exportedAt } -Descending)
}

function Get-TkHoursLeft($req, [datetime]$now = (Get-Date)) {
  try { $u = [datetime]::Parse([string]$req.validUntil); return [math]::Round(($u - $now).TotalHours, 1) } catch { return -1 }
}

function Find-TkNewXml([string[]]$dirs, [datetime]$since) {
  $c = foreach ($d in $dirs) { if ($d -and (Test-Path $d)) { Get-ChildItem $d -Filter *.xml -File -Recurse -Depth 1 -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $since } } }
  return @($c | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
}

function Get-TkExportDirs([string]$camResetDir) {
  return @((Join-Path $camResetDir 'requests\export'), [Environment]::GetFolderPath('MyDocuments'), (Join-Path $env:USERPROFILE 'Downloads'), [Environment]::GetFolderPath('Desktop'), 'C:\Users\Public\Documents')
}

function Import-TkReply([string]$path, [string]$camResetDir, [string]$preferSerial = '') {
  # Takes the file from Hikvision's reply email (xml, or a zip holding it), files it under replies\<serial>\
  # and marks the matching request. Returns @{ ok; message; file; serial; request }
  if (-not (Test-Path -LiteralPath $path)) { return [pscustomobject]@{ ok = $false; message = 'File not found.'; file = ''; serial = ''; request = $null } }
  $item = Get-Item -LiteralPath $path
  $cands = @()
  $tmp = $null
  if ($item.Extension -ieq '.zip') {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('wireit-reply-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($item.FullName, $tmp)
    $cands = @(Get-ChildItem $tmp -Recurse -File | Where-Object { $_.Extension -match '^\.(xml|txt|dat|key)$' })
    if (-not $cands) { $cands = @(Get-ChildItem $tmp -Recurse -File) }
  } else { $cands = @($item) }
  if (-not $cands) { return [pscustomobject]@{ ok = $false; message = 'The zip file is empty.'; file = ''; serial = ''; request = $null } }
  $reqs = @(Get-TkRequests $camResetDir)
  $match = $null; $by = ''; $file = $null
  foreach ($c in $cands) {
    $txt = ''; try { if ($c.Length -lt 2MB) { $txt = [IO.File]::ReadAllText($c.FullName) } } catch {}
    foreach ($r in $reqs) {
      $short = [string]$r.shortSerial; $full = [string]$r.serial
      if (($short -and ($c.Name -like "*$short*" -or $txt -like "*$short*")) -or ($full -and $txt -like "*$full*")) { $match = $r; $by = 'serial'; $file = $c; break }
    }
    if ($match) { break }
  }
  if (-not $match -and $preferSerial) { $match = $reqs | Where-Object { $_.shortSerial -eq $preferSerial -or $_.serial -eq $preferSerial } | Select-Object -First 1; if ($match) { $by = 'chosen device'; $file = $cands[0] } }
  if (-not $match -and $reqs.Count -eq 1) { $match = $reqs[0]; $by = 'only open request'; $file = $cands[0] }
  if (-not $match) { if (-not $file) { $file = $cands[0] } }
  $serial = ''; if ($match) { $serial = [string]$match.serial } elseif ($preferSerial) { $serial = $preferSerial } else { $serial = 'unmatched' }
  $dest = Join-Path (Join-Path $camResetDir 'replies') ($serial -replace '[^\w\-]', '_')
  New-Item -ItemType Directory -Force -Path $dest | Out-Null
  $target = Join-Path $dest $file.Name
  Copy-Item -LiteralPath $file.FullName $target -Force
  if ($tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
  $msg = ''
  if ($match) {
    $rj = Join-Path $match.folder 'request.json'
    $j = Read-TkJson $rj
    if ($j) { $j | Add-Member -NotePropertyName status -NotePropertyValue 'reply received' -Force; $j | Add-Member -NotePropertyName replyFile -NotePropertyValue $target -Force; $j | Add-Member -NotePropertyName replyAt -NotePropertyValue (Get-Date -Format 's') -Force; Save-TkJson $j $rj }
    $hl = Get-TkHoursLeft $match
    $msg = 'Reply file saved for ' + $match.model + ' (serial ' + $match.shortSerial + '), matched by ' + $by + '.'
    if ($hl -lt 0) { $msg += ' WARNING: the 48-hour window has passed; if HiTools refuses the file, make a new request.' } else { $msg += ' About ' + $hl + ' h left to use it.' }
  } else { $msg = 'Reply file saved, but it did not match a request on this PC. Pick the device in step 1 and drop it again, or use it in HiTools anyway.' }
  return [pscustomobject]@{ ok = $true; message = $msg; file = $target; serial = $serial; request = $match }
}

function Get-TkFormFields($cfg, $dev) {
  $f = $cfg.form
  $list = New-Object System.Collections.Generic.List[object]
  foreach ($p in @(@('First name', $f.firstName), @('Last name', $f.lastName), @('Email', $f.email), @('Company', $f.company), @('State', $f.state), @('Zip code', $f.zip), @('Business type', $f.businessType))) { $list.Add([pscustomobject]@{ Label = $p[0]; Value = [string]$p[1] }) }
  if ($dev) {
    $list.Add([pscustomobject]@{ Label = 'Serial (9)'; Value = [string]$dev.ShortSerial })
    $list.Add([pscustomobject]@{ Label = 'Model'; Value = [string]$dev.Model })
  }
  return $list.ToArray()
}

# ---------------- Fix NVR runs ----------------
function Get-TkLastFix([string]$fixDir) {
  $runs = Join-Path $fixDir 'runs'
  if (-not (Test-Path $runs)) { return $null }
  $d = Get-ChildItem $runs -Directory -Filter 'Fix-*' -ErrorAction SilentlyContinue | Where-Object { Test-Path (Join-Path $_.FullName 'rollback.json') } | Sort-Object Name -Descending | Select-Object -First 1
  if (-not $d) { return $null }
  return [pscustomobject]@{ Folder = $d.FullName; File = (Join-Path $d.FullName 'rollback.json'); When = $d.LastWriteTime; Undone = (Test-Path (Join-Path $d.FullName 'undone.txt')) }
}

function Get-TkNewRunDir([string]$fixDir, [string]$mode, [datetime]$since) {
  $runs = Join-Path $fixDir 'runs'
  if (-not (Test-Path $runs)) { return $null }
  return (Get-ChildItem $runs -Directory -Filter ($mode + '-*') -ErrorAction SilentlyContinue | Where-Object { $_.CreationTime -ge $since.AddSeconds(-3) } | Sort-Object Name -Descending | Select-Object -First 1)
}

function ConvertFrom-TkFixLog([string[]]$lines) {
  # FixNVR log lines look like "10:41:02 SAY text" - keep only what the tool said on screen
  $o = foreach ($l in $lines) { if ($l -match '^\d\d:\d\d:\d\d SAY ?(.*)$') { $Matches[1] } }
  return @($o)
}

function Read-TkShared([string]$path, [long]$offset, [Text.Encoding]$enc) {
  # read new text from a file another process is still writing
  if (-not (Test-Path -LiteralPath $path)) { return [pscustomobject]@{ text = ''; offset = $offset } }
  $fs = New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite, Delete')
  try {
    if ($fs.Length -le $offset) { return [pscustomobject]@{ text = ''; offset = $offset } }
    $fs.Seek($offset, 'Begin') | Out-Null
    $n = [int]($fs.Length - $offset); $buf = New-Object byte[] $n; $got = $fs.Read($buf, 0, $n)
    # do not cut a line in half
    $last = [Array]::LastIndexOf($buf, [byte]10, $got - 1); if ($last -lt 0) { return [pscustomobject]@{ text = ''; offset = $offset } }
    return [pscustomobject]@{ text = $enc.GetString($buf, 0, $last + 1); offset = $offset + $last + 1 }
  } finally { $fs.Close() }
}

function Write-TkLog([string]$logDir, [string]$tool, [string]$text) {
  New-Item -ItemType Directory -Force -Path $logDir | Out-Null
  $name = (Get-Date -Format 'yyyy-MM-dd_HHmmss') + '_' + ($tool -replace '[^\w]+', '-') + '.txt'
  $p = Join-Path $logDir $name
  Set-Content -LiteralPath $p -Value $text -Encoding UTF8
  return $p
}

function Get-TkPlainEnd([string]$tool, [int]$code) {
  switch ($code) {
    0 { return ($tool + ': finished.') }
    2 { return ($tool + ': could not start (see the line above, e.g. not plugged into the network).') }
    4 { return ($tool + ': finished, but some steps did not work (see above). "7 Undo last fix" puts everything back.') }
    default { return ($tool + ': stopped with a problem (code ' + $code + '). The full log is in the logs folder.') }
  }
}

function New-TkHiddenPsi([string]$psexe, [string]$file, [string]$argLine, [string]$outFile) {
  # runs a tool with no window; everything it prints goes to $outFile (the Toolkit shows it live)
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = $env:ComSpec
  $psi.Arguments = '/d /s /c ""' + $psexe + '" -NoProfile -ExecutionPolicy Bypass -File "' + $file + '" ' + $argLine + ' > "' + $outFile + '" 2>&1"'
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.WorkingDirectory = (Split-Path -Parent $file)
  return $psi
}
