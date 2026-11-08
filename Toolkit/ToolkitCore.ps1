<#
 ToolkitCore.ps1 - the non-screen part of the WireIt Toolkit (Windows PowerShell 5.1, no installs).
 Dot-sourced by WireItToolkit.ps1 and by tests\Test-Toolkit.ps1. Holds no passwords and writes none.
#>
$script:TkAllowedTop = @('Toolkit', 'FixNVR', 'CamReset', 'NetCheck')
$script:TkUpdatePrefix = 'https://raw.githubusercontent.com/wireitct/wireit-toolkit/'
# 2.0.4: updates come from WireIt's own Cloudflare download service, so the GitHub repo can be private.
# The download key below only lets a PC download Toolkit files from that service; it opens nothing else
# (no cameras, no Drive, no site data). Raw GitHub stays as a fallback only while the repo is still public.
$script:TkDlBase = 'https://wireit-toolkit-dl.wireitct.workers.dev/'
$script:TkDlKey = 'OXO1mhmkMJevVhd5f2Sk-ylPBogt6vmD'
$script:TkOldUpdateUrl = 'https://raw.githubusercontent.com/wireitct/wireit-toolkit/main/version.json'
$script:TkUpdatePrefixes = @(($script:TkDlBase + 'f/'), $script:TkUpdatePrefix)
$script:TkCurVersion = ''
# 2.2.2 (re-review NEW-2): the version these files ARE. Get-TkVersion never reads lower than this, so a copy installed from the
# repository (no Toolkit\version.json) is not "0.0.0", and an update is only taken when the published one is NEWER (never a downgrade).
# Same number as FixSiteCore.ps1 $FsVersion and the release manifest (version.json); Test-Fix222 checks all three.
$script:TkBuiltVersion = '2.2.3'

function Get-TkPaths([string]$toolkitDir) {
  $root = Split-Path -Parent $toolkitDir
  [pscustomobject]@{
    Root = $root; Toolkit = $toolkitDir
    FixNVR = Join-Path $root 'FixNVR'; CamReset = Join-Path $root 'CamReset'; NetCheck = Join-Path $root 'NetCheck'
    NvrHealth = Join-Path $toolkitDir 'modules\NvrHealth'; NvrDaily = Join-Path $root 'NvrHealth'
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
    updateUrl = 'https://wireit-toolkit-dl.wireitct.workers.dev/version.json'
    updateFallbackUrl = 'https://raw.githubusercontent.com/wireitct/wireit-toolkit/main/version.json'
    updateTimeoutMs = 4000; autoUpdate = $true
    hikvisionForm = 'https://www.hikvision.com/us-en/support/password-reset/'
    bitwardenUrl = 'https://vault.bitwarden.com/'
    hiTools = @('C:\Program Files (x86)\HiToolsDelivery\client\HiToolsDelivery.exe', 'C:\Program Files\HiToolsDelivery\client\HiToolsDelivery.exe')
    form = [ordered]@{ firstName = 'Moshe'; lastName = 'Reichman'; email = 'moshe@wireitct.com'; company = 'WireIt CT LLC'; state = 'Connecticut'; zip = '06710'; businessType = 'Installer' }
    passwordLength = 14
    daysToKeep = [ordered]@{ default = 30; sites = [ordered]@{ YKW = 45 } }
  }
  if ($c) {
    foreach ($p in $c.PSObject.Properties) {
      if ($p.Name -eq 'form' -and $p.Value) { foreach ($q in $p.Value.PSObject.Properties) { $d.form[$q.Name] = $q.Value } }
      else { $d[$p.Name] = $p.Value }
    }
  }
  # 2.0.4: a config.json written before 2.0.4 names the old raw GitHub address; move it to the download service
  # (raw GitHub becomes the fallback). Any other address someone typed in config.json is kept as it is.
  if (-not [string]$d.updateUrl -or ([string]$d.updateUrl).TrimEnd('/') -ieq $script:TkOldUpdateUrl) {
    $d.updateUrl = $script:TkDlBase + 'version.json'; $d.updateFallbackUrl = $script:TkOldUpdateUrl
  }
  return [pscustomobject]$d
}

function Get-TkDaysToKeep($cfg, [string]$site) {
  # days of footage a site must keep: config.json "daysToKeep": { "default": 30, "sites": { "YKW": 45 } }
  # a key matches when the site name starts with it or contains it as a word (not case sensitive)
  $dk = $null; if ($cfg -and $cfg.PSObject.Properties['daysToKeep']) { $dk = $cfg.daysToKeep }
  $def = 30; $sites = $null
  if ($dk) {
    if ($dk -is [Collections.IDictionary]) { if ($dk.Contains('default') -and [int]$dk['default'] -gt 0) { $def = [int]$dk['default'] }; $sites = $dk['sites'] }
    else { if ($dk.PSObject.Properties['default'] -and [int]$dk.default -gt 0) { $def = [int]$dk.default }; if ($dk.PSObject.Properties['sites']) { $sites = $dk.sites } }
  }
  if (-not $site -or -not $sites) { return $def }
  $pairs = @(); if ($sites -is [Collections.IDictionary]) { foreach ($k in $sites.Keys) { $pairs += [pscustomobject]@{ k = [string]$k; v = $sites[$k] } } } else { foreach ($p in $sites.PSObject.Properties) { $pairs += [pscustomobject]@{ k = [string]$p.Name; v = $p.Value } } }
  $s = $site.Trim()
  foreach ($p in @($pairs | Sort-Object { - $_.k.Length })) {
    $k = $p.k; if (-not $k -or $k.StartsWith('_')) { continue }
    if ($s.StartsWith($k, [StringComparison]::OrdinalIgnoreCase) -or $s -match ('(?i)\b' + [regex]::Escape($k) + '\b')) { if ([int]$p.v -gt 0) { return [int]$p.v } }
  }
  return $def
}

function Get-TkNvrReference([string]$toolkitDir) {
  # the firmware list: the newer of the Toolkit's own copy and the daily check's monthly refresh (C:\WireIt\NvrHealth)
  $P = Get-TkPaths $toolkitDir
  $best = $null; $bestDate = ''
  foreach ($f in @((Join-Path $P.NvrDaily 'firmware-latest.json'), (Join-Path $P.NvrHealth 'firmware-latest.json'))) {
    if (-not (Test-Path -LiteralPath $f)) { continue }
    $j = Read-TkJson $f; if (-not $j -or -not $j.models) { continue }
    $d = [string]$j.updated
    if (-not $best -or ($d -gt $bestDate)) { $best = $f; $bestDate = $d }
  }
  return $best
}

function Get-TkNvrPlainEnd([string]$tool, [int]$code) {
  switch ($code) {
    0 { return ($tool + ': finished. All good, or see the CHECK lines above.') }
    2 { return ($tool + ': could not read the recorder (wrong password, wrong address, or not on its network). Nothing was changed.') }
    4 { return ($tool + ': finished - PROBLEM lines above need a look.') }
    default { return ($tool + ': stopped with a problem (code ' + $code + '). The full log is in the runs folder.') }
  }
}

function Get-TkVersion([string]$toolkitDir) {
  # Toolkit\version.json (written by the installer and by every update); a repository copy has it one folder up (the release manifest).
  # 2.2.2: never lower than the version of the code itself ($TkBuiltVersion) - never "0.0.0"
  $best = $script:TkBuiltVersion
  foreach ($p in @((Join-Path $toolkitDir 'version.json'), (Join-Path (Split-Path -Parent $toolkitDir) 'version.json'))) {
    $v = Read-TkJson $p
    if ($v -and $v.version) { if ((Compare-TkVersion ([string]$v.version) $best) -gt 0) { $best = [string]$v.version }; break }
  }
  return $best
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
  if (@($parts | Where-Object { $_ -in @('vault', 'secrets', 'ipc', 'inbox') }).Count) { return $false }   # 2.2.0: an update never writes the password stores or the Crew drop folders
  return $true
}

function Test-TkManifest($m) {
  if (-not $m -or -not $m.version -or -not $m.base -or -not $m.files) { return 'manifest is missing version/base/files' }
  $okBase = $false; foreach ($pre in $script:TkUpdatePrefixes) { if (([string]$m.base).StartsWith($pre)) { $okBase = $true } }
  if (-not $okBase) { return 'download address is not the WireIt toolkit repository' }
  foreach ($f in $m.files) {
    if (-not (Test-TkManifestPath ([string]$f.path))) { return ('file path not allowed: ' + $f.path) }
    if (-not ($f.sha256 -match '^[0-9a-fA-F]{64}$')) { return ('bad hash for ' + $f.path) }
  }
  return ''
}

function Get-TkWeb([string]$url, [int]$timeoutMs) {
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12   # 2.2.2 (re-review): add TLS 1.2 for GitHub, never take the device TLS versions away
  $req = [Net.WebRequest]::Create($url)
  $req.Timeout = $timeoutMs
  if ($req -is [Net.HttpWebRequest]) { $req.ReadWriteTimeout = $timeoutMs; $req.UserAgent = 'WireIt-Toolkit' }
  if ($url.StartsWith($script:TkDlBase)) {
    # the download service wants the Toolkit's key; the PC name + version let Moshe see which PCs have updated
    $req.Headers.Add('X-WireIt-Key', $script:TkDlKey)
    $req.Headers.Add('X-WireIt-PC', [string]$env:COMPUTERNAME)
    if ($script:TkCurVersion) { $req.Headers.Add('X-WireIt-Version', $script:TkCurVersion) }
  }
  $req.CachePolicy = New-Object Net.Cache.RequestCachePolicy([Net.Cache.RequestCacheLevel]::NoCacheNoStore)
  $resp = $req.GetResponse()
  try { $ms = New-Object IO.MemoryStream; $resp.GetResponseStream().CopyTo($ms); return $ms.ToArray() } finally { $resp.Close() }
}

function Get-TkUpdateInfo($cfg, [string]$toolkitDir) {
  # returns @{ state = 'offline'|'current'|'available'|'error'; manifest; message }
  $cur = Get-TkVersion $toolkitDir
  $script:TkCurVersion = $cur
  # 2.0.4: the download service first; raw GitHub only if that fails (works only while the repo is public)
  $urls = @([string]$cfg.updateUrl)
  if ($cfg.PSObject.Properties['updateFallbackUrl'] -and [string]$cfg.updateFallbackUrl -and ([string]$cfg.updateFallbackUrl -ne [string]$cfg.updateUrl)) { $urls += [string]$cfg.updateFallbackUrl }
  $m = $null; $reached = $false
  foreach ($uu in $urls) {
    try { $bytes = Get-TkWeb $uu ([int]$cfg.updateTimeoutMs); $reached = $true } catch { continue }
    try { $m = [Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF) | ConvertFrom-Json; break } catch { $m = $null }
  }
  if (-not $reached) { return [pscustomobject]@{ state = 'offline'; manifest = $null; current = $cur; message = 'No internet (or update site not reachable) - running this version.' } }
  if (-not $m) { return [pscustomobject]@{ state = 'error'; manifest = $null; current = $cur; message = 'Update info unreadable - running this version.' } }
  $bad = Test-TkManifest $m
  if ($bad) { return [pscustomobject]@{ state = 'error'; manifest = $null; current = $cur; message = ('Update refused: ' + $bad) } }
  # only a NEWER published version is ever installed (2.2.2: also checked against the code's own version, never a downgrade)
  if ((Compare-TkVersion ([string]$m.version) $cur) -le 0 -or (Compare-TkVersion ([string]$m.version) $script:TkBuiltVersion) -le 0) { return [pscustomobject]@{ state = 'current'; manifest = $m; current = $cur; message = $(if ((Compare-TkVersion ([string]$m.version) $cur) -lt 0) { 'This version (v' + $cur + ') is newer than the published one (v' + $m.version + ') - not changed.' } else { 'Up to date (v' + $cur + ').' }) } }
  return [pscustomobject]@{ state = 'available'; manifest = $m; current = $cur; message = ('New version ' + $m.version + ' available (this is ' + $cur + ').') }
}

function Install-TkUpdate($m, [string]$toolkitDir, [scriptblock]$Fetch = $null) {
  # Downloads every file to staging, checks each SHA-256, then swaps them in. Keeps the replaced files in previous\
  # so "Go back" restores them. Any failure before the swap changes nothing; a failure during the swap restores.
  # 2.2.1 (review H10): every file step stops on its first error (the callers run with ErrorActionPreference Continue, which let a
  # locked or access-denied copy pass as done), and every swapped-in file is checked against its hash before the version is written.
  $ErrorActionPreference = 'Stop'
  $P = Get-TkPaths $toolkitDir
  $bad = Test-TkManifest $m; if ($bad) { throw ('Update refused: ' + $bad) }
  $cur0 = Get-TkVersion $toolkitDir
  if ((Compare-TkVersion ([string]$m.version) $cur0) -le 0) { throw ('Update refused: version ' + $m.version + ' is not newer than this one (' + $cur0 + ').') }   # 2.2.2: never a downgrade
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
    if (Test-Path -LiteralPath $live) { $b = Join-Path $prev $f.path; New-Item -ItemType Directory -Force -Path (Split-Path -Parent $b) -ErrorAction Stop | Out-Null; Copy-Item -LiteralPath $live $b -Force -ErrorAction Stop }
    else { $added.Add([string]$f.path) }
  }
  $vj = Join-Path $toolkitDir 'version.json'
  if (Test-Path $vj) { Copy-Item $vj (Join-Path $prev 'version.json.prev') -Force -ErrorAction Stop }
  Save-TkJson ([ordered]@{ from = $old; to = [string]$m.version; at = (Get-Date -Format 's'); added = $added.ToArray() }) (Join-Path $prev 'undo.json')
  $done = New-Object System.Collections.Generic.List[string]
  try {
    foreach ($f in $m.files) {
      $live = Join-Path $P.Root $f.path; New-Item -ItemType Directory -Force -Path (Split-Path -Parent $live) -ErrorAction Stop | Out-Null
      $done.Add([string]$f.path)   # before the copy: a half-written file is put back too
      Copy-Item -LiteralPath (Join-Path $P.Staging $f.path) $live -Force -ErrorAction Stop
      if ((Get-TkSha256 $live) -ne ([string]$f.sha256).ToLower()) { throw ('after copying, ' + $f.path + ' is not the new file (locked or not allowed?)') }
    }
    Save-TkJson ([ordered]@{ version = [string]$m.version; released = $m.released; commit = $m.commit; previous = $old; installed = (Get-Date -Format 's') }) $vj
  } catch {
    $why = $_.Exception.Message; $notBack = @()
    # (2.2.1: the loop variable is $rp - PowerShell names are not case-sensitive, so 2.2.0's "$p" overwrote the paths object $P
    # and the put-back never found the Toolkit folder: a failed update was NOT rolled back)
    foreach ($rp in $done) {
      try { $b = Join-Path $prev $rp; if (Test-Path -LiteralPath $b) { Copy-Item -LiteralPath $b (Join-Path $P.Root $rp) -Force -ErrorAction Stop } elseif ($added -contains $rp) { $ap = Join-Path $P.Root $rp; if (Test-Path -LiteralPath $ap) { Remove-Item -LiteralPath $ap -Force -ErrorAction Stop } } }
      catch { $notBack += $rp }
    }
    try { if (Test-Path (Join-Path $prev 'version.json.prev')) { Copy-Item (Join-Path $prev 'version.json.prev') $vj -Force -ErrorAction Stop } } catch { $notBack += 'version.json' }
    if ($notBack.Count) { throw ('Update could not be installed (' + $why + '), and these files could not be put back: ' + ($notBack -join ', ') + '. Run the Toolkit installer as an admin.') }
    throw ('Update could not be installed, the old version was put back: ' + $why)
  }
  Remove-Item $P.Staging -Recurse -Force -ErrorAction SilentlyContinue
  return $old
}

function Undo-TkUpdate([string]$toolkitDir) {
  # put back the version that the last update replaced. 2.2.1 (review H10): any file that cannot be put back stops it with its name.
  $ErrorActionPreference = 'Stop'
  $P = Get-TkPaths $toolkitDir
  $cur = Read-TkJson (Join-Path $toolkitDir 'version.json')
  if (-not $cur -or -not $cur.previous) { throw 'There is no earlier version saved on this PC.' }
  $prev = Join-Path $P.Previous ([string]$cur.previous)
  $u = Read-TkJson (Join-Path $prev 'undo.json')
  if (-not $u) { throw ('The saved copy of version ' + $cur.previous + ' is missing.') }
  $bad = @()
  foreach ($fi in @(Get-ChildItem -LiteralPath $prev -Recurse -File | Where-Object { $_.Name -notin @('undo.json', 'version.json.prev') })) {
    $rel = $fi.FullName.Substring($prev.Length).TrimStart('\', '/')
    $dst = Join-Path $P.Root $rel
    try { New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null; Copy-Item -LiteralPath $fi.FullName $dst -Force -ErrorAction Stop; if ((Get-TkSha256 $dst) -ne (Get-TkSha256 $fi.FullName)) { $bad += $rel } } catch { $bad += $rel }
  }
  foreach ($a in @($u.added)) { if ($a -and (Test-TkManifestPath $a)) { $ap = Join-Path $P.Root $a; try { if (Test-Path -LiteralPath $ap) { Remove-Item -LiteralPath $ap -Force -ErrorAction Stop } } catch { $bad += $a } } }
  if ($bad.Count) { throw ('Going back did not finish: ' + ($bad -join ', ') + ' could not be put back (locked or not allowed). The version number was not changed. Run it as an admin.') }
  $vp = Join-Path $prev 'version.json.prev'
  if (Test-Path $vp) { Copy-Item $vp (Join-Path $toolkitDir 'version.json') -Force -ErrorAction Stop }
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
  # 2.2.0: with the reply relay on, Hikvision replies to the relay's address (hikreset@...), where the Toolkit picks it up by itself
  try { if ($cfg.PSObject.Properties['hikReset'] -and $cfg.hikReset.relay -and [string]$cfg.hikReset.relay.url) { $f2 = [ordered]@{}; if ($f -is [Collections.IDictionary]) { foreach ($k in @($f.Keys)) { $f2[$k] = $f[$k] } } else { foreach ($p in $f.PSObject.Properties) { $f2[$p.Name] = $p.Value } }; $f = $f2; $f.email = $(if ([string]$cfg.hikReset.relay.address) { [string]$cfg.hikReset.relay.address } else { 'hikreset@wireitct.com' }) } } catch {}
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

function Add-TkLine([string]$path, [string]$line) {
  # 1.6.2: append one line to a run log the Toolkit window is reading at the same time (shared, short retry, never throws)
  $b = [Text.Encoding]::UTF8.GetBytes($line + "`r`n")
  for ($i = 0; $i -lt 6; $i++) {
    try { $fs = New-Object IO.FileStream($path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]'ReadWrite, Delete'); try { $fs.Write($b, 0, $b.Length) } finally { $fs.Dispose() }; return $true }
    catch { Start-Sleep -Milliseconds (40 * ($i + 1)) }
  }
  return $false
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


# ---------------- site camera list (Nov 3 2026): "1 Find cameras" / "6 Save install snapshot" -> the site page ----------------
# Moshe Nov 2 9:24 PM: "after the scan it could get saved to this site ... to mesh with everything else". ONE list per site on the
# service site (op scanPush, the same upload key as Save camera pictures). Only the fields below are ever sent: never a password.
function Get-TkDeviceKind([string]$model, [string]$brand = '') {
  $m = ([string]$model).Trim().ToUpper()
  # 2.2.3 (Codex #11): OEM recorders (ERI-K108-P8 at 3 Hewlett, HWN-, Dahua DHI-NVR/XVR, Uniview NVR301) are recorders too, the same
  # list SADP discovery (HikSadp.ps1) already uses; a recorder must never get camera planning.
  if ($m -match '^I?DS-[789]\d' -or $m -match '^(ERI-|HWN-|HNR|DHI-(NVR|XVR|HCVR|DVR)|DH-(NVR|XVR|HCVR))' -or $m -match '(^|[-_ ])(NVR|DVR|XVR|HCVR)') { return 'recorder' }
  if ($m) { return 'camera' }
  return 'other'
}
function ConvertTo-TkScanDevice($d, [string]$kind = '') {
  if (-not $d) { return $null }
  $g = { param($n) $p = $d.PSObject.Properties[$n]; if ($p -and $null -ne $p.Value) { return ([string]$p.Value).Trim() } else { return '' } }
  $brand = (& $g 'Brand'); if (-not $brand) { $brand = (& $g 'brand') }; $brand = ($brand -replace '\s*\(ONVIF\)', '').Trim()
  $model = (& $g 'Model'); if (-not $model) { $model = (& $g 'model') }
  $o = [ordered]@{
    kind = $(if ($kind) { $kind } else { Get-TkDeviceKind $model $brand }); brand = $brand; model = $model
    serial = $(& $g 'Serial'); mac = $(& $g 'MAC'); ip = $(& $g 'IP'); firmware = $(& $g 'Firmware')
  }
  if (-not $o.serial) { $o.serial = (& $g 'serial') }; if (-not $o.mac) { $o.mac = (& $g 'mac') }; if (-not $o.ip) { $o.ip = (& $g 'ip') }; if (-not $o.firmware) { $o.firmware = (& $g 'firmware') }
  $ch = (& $g 'channel'); if ($ch) { $o.channel = $ch }
  if (-not ($o.mac -or $o.serial -or $o.ip)) { return $null }
  return $o
}
# the last "Find cameras" scan (CamReset out\latest.json) as the list the site page keeps
function Get-TkScanDevices([string]$camResetDir) {
  $l = Read-TkJson (Join-Path $camResetDir 'out\latest.json')
  if (-not $l) { return @() }
  # Nov 3 2026: cameras found only by the network sweep carry Kind 'camera' (often no model) - keep that kind
  return @(foreach ($d in @($l.devices)) { $kd = ''; $kp = $d.PSObject.Properties['Kind']; if ($kp -and $kp.Value) { $kd = [string]$kp.Value }; $x = ConvertTo-TkScanDevice $d $kd; if ($x) { $x } })
}
# 1.6.1 (YKW Elm live test): "Check this site" uses the list Find cameras just made on THIS PC (CamReset out\scan-*\devices.json
# or out\latest.json, newest one, at most $maxMin minutes old) even when nothing was uploaded (no Site ID typed). $null = none fresh.
function Get-TkFreshScan([string]$camResetDir, [int]$maxMin = 30, $now = $null) {
  if (-not $now) { $now = Get-Date }
  $outDir = Join-Path $camResetDir 'out'; if (-not (Test-Path -LiteralPath $outDir)) { return $null }
  $c = @(Get-ChildItem -LiteralPath $outDir -Directory -Filter 'scan-*' -ErrorAction SilentlyContinue | ForEach-Object { Get-Item -LiteralPath (Join-Path $_.FullName 'devices.json') -ErrorAction SilentlyContinue })
  $c += @(Get-Item -LiteralPath (Join-Path $outDir 'latest.json') -ErrorAction SilentlyContinue)
  $best = $c | Where-Object { $_ } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if (-not $best -or ($now - $best.LastWriteTime).TotalMinutes -gt $maxMin -or $best.LastWriteTime -gt $now.AddMinutes(5)) { return $null }
  $j = Read-TkJson $best.FullName; if ($null -eq $j) { return $null }
  $rows = $(if ($j -is [array]) { $j } elseif ($j.PSObject.Properties['devices']) { @($j.devices) } else { @($j) })
  $devs = @(foreach ($d in $rows) { if (-not $d) { continue }; $kd = ''; $kp = $d.PSObject.Properties['Kind']; if ($kp -and $kp.Value) { $kd = [string]$kp.Value }; $x = ConvertTo-TkScanDevice $d $kd; if ($x) { $x } })
  if (-not $devs.Count) { return $null }
  $cams = @($devs | Where-Object { $_.kind -eq 'camera' }).Count
  $line = 'Find cameras found ' + $devs.Count + ' device(s) on this PC at ' + $best.LastWriteTime.ToString('h:mm tt') + ': ' + $cams + ' camera(s), ' + ($devs.Count - $cams) + ' recorder(s) / other. (Not uploaded - type the Site ID to compare with the site list.)'
  return [pscustomobject]@{ local = $true; at = $best.LastWriteTime.ToString('s'); file = $best.FullName; count = $devs.Count; cameras = $cams; devices = $devs; answer = $null; lines = @($line); red = @() }
}
# an install snapshot (FixNVR snapshot json) as the known-good list: NVRs + the cameras this PC can see (not the NVR's own PoE ports)
function Get-TkSnapshotDevices([string]$path) {
  $s = Read-TkJson $path
  if (-not $s) { return @() }
  $out = New-Object System.Collections.Generic.List[object]
  foreach ($n in @($s.nvrs)) { $x = ConvertTo-TkScanDevice $n 'recorder'; if ($x) { $out.Add($x) } }
  foreach ($c in @($s.cameras)) {
    if (-not $c) { continue }
    if ([string]$c.ip -like '192.168.254.*' -or -not ($c.mac -or $c.serial)) { continue }   # behind the NVR's PoE ports: a PC scan never sees those
    $x = ConvertTo-TkScanDevice $c 'camera'; if ($x) { $out.Add($x) }
  }
  return $out.ToArray()
}
function Get-TkNewestSnapshot([string]$fixDir, [datetime]$since) {
  $d = Join-Path $fixDir 'snapshots'
  if (-not (Test-Path $d)) { return $null }
  return (Get-ChildItem $d -Filter 'FixNVR snapshot*.json' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $since.AddSeconds(-5) } | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
}
# the server's answer -> lines for the results pane: @{ t = text; k = red | ok | warn | plain }; red ones go at the top
function Format-TkScanAnswer($r, [string]$site) {
  $L = New-Object System.Collections.Generic.List[object]
  $add = { param($t, $k) $L.Add(@{ t = $t; k = $k }) }
  $dash = [string][char]0x2014
  if (-not $r) { & $add ('Not saved to the site page: no answer from the service site (no internet?). It is sent next time you run Find cameras with this site.') 'warn'; return $L.ToArray() }
  if (-not $r.ok) { & $add ('Not saved to the site page: ' + [string]$r.msg) 'warn'; return $L.ToArray() }
  $j = { param($a) (@($a) | Where-Object { $_ }) -join '; ' }
  if (@($r.missing).Count) { & $add ('MISSING since last scan: ' + (& $j $r.missing)) 'red' }
  if (@($r.stillMissing).Count) { & $add ('Still missing: ' + (& $j $r.stillMissing)) 'red' }
  if (@($r.added).Count -and -not $r.snapshot -and [int]$r.total -gt @($r.added).Count) { & $add ('NEW: ' + (& $j $r.added)) 'red' }
  foreach ($c in @($r.changedIp)) { if ($c) { & $add ('CHANGED IP: ' + [string]$c.label + ' ' + [string]$c.from + ' -> ' + [string]$c.to) 'red' } }
  foreach ($c in @($r.changed)) { if ($c) { & $add ('Changed: ' + [string]$c) 'plain' } }
  if (@($r.back).Count) { & $add ('Back again: ' + (& $j $r.back)) 'ok' }
  $nm = [string]$r.site + $(if ($r.code) { ' (' + [string]$r.code + ')' } else { '' })
  if ($r.same) { & $add ('No changes ' + $dash + ' site list already up to date (' + $nm + ', ' + [int]$r.total + ' devices).') 'ok' }
  elseif ($r.snapshot) { & $add ('Install snapshot saved as the known-good camera list on the site page: ' + $nm + ', ' + [int]$r.total + ' devices.') 'ok' }
  else { & $add ('Saved to the site page: ' + $nm + ', ' + [int]$r.total + ' devices' + $(if (@($r.added).Count -eq [int]$r.total) { ' (first list for this site)' } else { '' }) + '.') 'ok' }
  if ([int]$r.alerted -gt 0) { & $add ('Alert sent to the office for ' + [int]$r.alerted + ' missing device(s).') 'warn' }
  return $L.ToArray()
}


# ---------------- router exposure (Nov 3 2026, "Check this site"): UPnP on? camera/NVR ports open to the internet? ----------------
# READ-ONLY: one SSDP search on the LAN, the router's own description page, and the UPnP read calls GetExternalIPAddress /
# GetGenericPortMappingEntry. Never AddPortMapping / DeletePortMapping, never the router's login or settings.
$script:TkCamPorts = @(80, 443, 554, 8000, 8080, 8200, 8443, 8554, 7001, 37777, 34567, 9000, 10554)
function Find-TkUpnpGateway([int]$timeoutMs = 2500) {
  $found = @()
  $u = New-Object Net.Sockets.UdpClient
  try {
    $u.Client.ReceiveTimeout = 600
    $msg = "M-SEARCH * HTTP/1.1`r`nHOST: 239.255.255.250:1900`r`nMAN: `"ssdp:discover`"`r`nMX: 2`r`nST: urn:schemas-upnp-org:device:InternetGatewayDevice:1`r`n`r`n"
    $b = [Text.Encoding]::ASCII.GetBytes($msg); $ep = New-Object Net.IPEndPoint([Net.IPAddress]::Parse('239.255.255.250'), 1900)
    [void]$u.Send($b, $b.Length, $ep); Start-Sleep -Milliseconds 100; [void]$u.Send($b, $b.Length, $ep)
    $end = (Get-Date).AddMilliseconds($timeoutMs)
    while ((Get-Date) -lt $end) {
      try { $from = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0); $r = [Text.Encoding]::ASCII.GetString($u.Receive([ref]$from)) } catch { continue }
      $m = [regex]::Match($r, '(?im)^LOCATION:\s*(\S+)')
      if ($m.Success -and $found -notcontains $m.Groups[1].Value) { $found += $m.Groups[1].Value }
    }
  } catch {} finally { $u.Close() }
  return $found
}
function Get-TkUpnpXVal([string]$xml, [string]$name) { $m = [regex]::Match($xml, '<(?:\w+:)?' + $name + '(?:\s[^>]*)?>([^<]*)</(?:\w+:)?' + $name + '>'); if ($m.Success) { return $m.Groups[1].Value.Trim() } else { return '' } }
function Invoke-TkUpnpRead([string]$ctl, [string]$svc, [string]$action, [string]$inner = '') {
  if ($action -notin @('GetGenericPortMappingEntry', 'GetExternalIPAddress', 'GetStatusInfo')) { throw ('not a read action: ' + $action) }   # read-only, always
  $body = '<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:' + $action + ' xmlns:u="' + $svc + '">' + $inner + '</u:' + $action + '></s:Body></s:Envelope>'
  try {
    $r = Invoke-WebRequest -Uri $ctl -Method Post -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'text/xml; charset="utf-8"' -Headers @{ SOAPAction = ('"' + $svc + '#' + $action + '"') } -UseBasicParsing -TimeoutSec 5
    return @{ ok = $true; xml = [string]$r.Content }
  } catch { return @{ ok = $false; xml = '' } }
}
function Get-TkUpnpExposure([string[]]$Locations = @(), [string[]]$CameraIps = @(), [switch]$NoSearch) {
  # -> @{ answered; upnp; router; external; maps = @(@{ ext; proto; client; port; desc; on; camera }); exposed = @(maps that reach a camera/NVR); lines = @(@{ t; k }) }
  $res = [ordered]@{ answered = $false; upnp = $false; router = ''; external = ''; maps = @(); exposed = @(); lines = @() }
  $L = New-Object System.Collections.Generic.List[object]
  if (-not $Locations.Count -and -not $NoSearch) { $Locations = @(Find-TkUpnpGateway) }
  foreach ($loc in $Locations) {
    try { $d = [string](Invoke-WebRequest -Uri $loc -UseBasicParsing -TimeoutSec 5).Content } catch { continue }
    $res.answered = $true
    $res.router = ((Get-TkUpnpXVal $d 'manufacturer') + ' ' + (Get-TkUpnpXVal $d 'modelName')).Trim()
    $svc = ''; $ctl = ''
    foreach ($m in [regex]::Matches($d, '(?s)<service>(.*?)</service>')) {
      $st = Get-TkUpnpXVal $m.Groups[1].Value 'serviceType'
      if ($st -match 'WAN(IP|PPP)Connection') { $svc = $st; $ctl = Get-TkUpnpXVal $m.Groups[1].Value 'controlURL'; break }
    }
    if (-not $svc) { continue }
    $res.upnp = $true
    $u = [Uri]$loc; $ctlUri = $(if ($ctl -match '^https?://') { $ctl } else { $u.Scheme + '://' + $u.Authority + '/' + $ctl.TrimStart('/') })
    $e = Invoke-TkUpnpRead $ctlUri $svc 'GetExternalIPAddress'; if ($e.ok) { $res.external = Get-TkUpnpXVal $e.xml 'NewExternalIPAddress' }
    for ($i = 0; $i -lt 128; $i++) {
      $g = Invoke-TkUpnpRead $ctlUri $svc 'GetGenericPortMappingEntry' ('<NewPortMappingIndex>' + $i + '</NewPortMappingIndex>')
      if (-not $g.ok) { break }
      $cl = Get-TkUpnpXVal $g.xml 'NewInternalClient'; $ip = [int](Get-TkUpnpXVal $g.xml 'NewInternalPort')
      $cam = ($CameraIps -contains $cl) -or ($script:TkCamPorts -contains $ip)
      $res.maps += [pscustomobject]@{ ext = [int](Get-TkUpnpXVal $g.xml 'NewExternalPort'); proto = (Get-TkUpnpXVal $g.xml 'NewProtocol'); client = $cl; port = $ip; desc = (Get-TkUpnpXVal $g.xml 'NewPortMappingDescription'); on = ((Get-TkUpnpXVal $g.xml 'NewEnabled') -ne '0'); camera = $cam }
    }
    break
  }
  $res.exposed = @($res.maps | Where-Object { $_.camera -and $_.on })
  # 2.2.3 (Codex #43): this check sees UPnP only. It does not show port forwards made by hand or other router services, so it never says "nothing is open".
  if (-not $res.answered) { $L.Add(@{ t = 'Router: UPnP did not answer (off or blocked). Port forwards made by hand are NOT checked: look at the router''s port-forwarding page.'; k = 'plain' }) }
  elseif (-not $res.upnp) { $L.Add(@{ t = 'Router (' + $res.router + '): no UPnP port-opening service. Port forwards made by hand are NOT checked: look at the router''s port-forwarding page.'; k = 'plain' }) }
  else {
    $L.Add(@{ t = 'Router UPnP is ON (' + $res.router + '): any device inside can open ports to the internet by itself. Turn UPnP off on the router.'; k = 'red' })
    foreach ($x in $res.exposed) { $L.Add(@{ t = 'OPEN TO THE INTERNET: port ' + $x.ext + '/' + $x.proto + ' -> ' + $x.client + ':' + $x.port + $(if ($x.desc) { ' (' + $x.desc + ')' } else { '' }) + ' - camera/NVR reachable from outside.'; k = 'red' }) }
    $other = @($res.maps | Where-Object { -not $_.camera }); if ($other.Count) { $L.Add(@{ t = 'Other ports the router opened (not cameras): ' + (($other | ForEach-Object { '' + $_.ext + '/' + $_.proto + ' -> ' + $_.client }) -join ', '); k = 'plain' }) }
    if (-not $res.maps.Count) { $L.Add(@{ t = 'No ports are open through UPnP right now (ports opened by hand are not visible here).'; k = 'ok' }) }
  }
  $res.lines = $L.ToArray()
  return [pscustomobject]$res
}



# ---------------- camera reachability (Nov 3 2026): ping, ARP / MAC, TCP ports - read-only ----------------
# Tests set WIREIT_TEST_REACH = {"10.9.1.29": {"ping": true, "mac": "44:19:B6:00:0A:29", "ports": [80, 554], "rtsp": "hung"}} (no real network)
function Get-TkTestReach([string]$ip) {
  if (-not $env:WIREIT_TEST_REACH) { return $null }
  try { $m = $env:WIREIT_TEST_REACH | ConvertFrom-Json; $p = $m.PSObject.Properties[$ip]; if ($p) { return $p.Value } } catch {}
  return [pscustomobject]@{ ping = $false; mac = ''; ports = @(); rtsp = 'none' }
}
function Get-TkArpTable {
  $t = @{}
  try { foreach ($n in @(Get-NetNeighbor -AddressFamily IPv4 -ErrorAction Stop)) { $ll = [string]$n.LinkLayerAddress; if ($ll -and $ll -ne '00-00-00-00-00-00' -and $ll -notmatch '^(FF-){5}FF$' -and [string]$n.State -ne 'Unreachable') { $t[[string]$n.IPAddress] = $ll.ToUpper().Replace('-', ':') } } }
  catch { foreach ($l in @(arp -a 2>$null)) { $m = [regex]::Match([string]$l, '^\s*(\d+\.\d+\.\d+\.\d+)\s+([0-9a-fA-F-]{17})\s'); if ($m.Success) { $t[$m.Groups[1].Value] = $m.Groups[2].Value.ToUpper().Replace('-', ':') } } }
  return $t
}
function Test-TkTcp([string]$ip, [int]$port, [int]$ms = 800) {
  $c = New-Object Net.Sockets.TcpClient
  try { $a = $c.BeginConnect($ip, $port, $null, $null); return ($a.AsyncWaitHandle.WaitOne($ms) -and $c.Connected) } catch { return $false } finally { $c.Close() }
}
function Test-TkCamReach([string]$ip, [string]$mac = '', [int[]]$ports = @(80, 443, 554, 8000), $arp = $null) {
  $mac = ([string]$mac).ToUpper().Replace('-', ':')
  $t = Get-TkTestReach $ip
  if ($t) {
    $ping = [bool]$t.ping; $seen = ([string]$t.mac).ToUpper(); $open = @($t.ports | Where-Object { $_ } | ForEach-Object { [int]$_ }); $moved = $(if ($t.PSObject.Properties['movedTo']) { [string]$t.movedTo } else { '' }); $rtsp = [string]$t.rtsp
  } else {
    $ping = $false; try { $ping = ((New-Object Net.NetworkInformation.Ping).Send($ip, 1000).Status -eq 'Success') } catch {}
    $open = @($ports | Where-Object { Test-TkTcp $ip $_ })
    if (-not $arp) { $arp = Get-TkArpTable }
    $seen = $(if ($arp.ContainsKey($ip)) { $arp[$ip] } else { '' })
    $moved = ''; if ($mac -and $seen -ne $mac) { foreach ($k in $arp.Keys) { if ($arp[$k] -eq $mac -and $k -ne $ip) { $moved = $k; break } } }
    $rtsp = ''
  }
  return [pscustomobject]@{ ip = $ip; ping = $ping; mac = $seen; macMatch = $(if ($mac -and $seen) { $seen -eq $mac } else { $null }); movedTo = $moved; open = $open; rtsp = $rtsp }
}
function Test-TkHasLink([string]$ip) {
  # 1.4: does this camera still have a network link from this PC (ping, ARP entry or an open web/video port)?
  if (-not $ip) { return $false }
  try { $r = Test-TkCamReach $ip '' @(80, 443, 554) } catch { return $false }
  return [bool]($r.ping -or $r.mac -or @($r.open).Count)
}
function Get-TkLikelyCause($reach, [string]$dwStatus = '') {
  if ($reach.movedTo) { return @{ k = 'moved'; t = 'IP MOVED: its MAC now answers at ' + $reach.movedTo + ' - DW still looks at the old address. Fix the address in DW (or set the camera back).' } }
  if (-not $reach.ping -and -not $reach.mac -and -not @($reach.open).Count) { return @{ k = 'dead'; t = 'NO LINK: no ping, not in the ARP table - cable, switch port / PoE power, or the camera is dead.' } }
  if ($dwStatus -eq 'Unauthorized') { return @{ k = 'dwpw'; t = 'DW HAS THE WRONG PASSWORD (DW says Unauthorized). A Uniview locks itself while DW keeps retrying - fix the password in DW. Camera doctor shows more.' } }
  if (-not @($reach.open).Count) { return @{ k = 'hung'; t = 'HUNG: on the network (' + $(if ($reach.ping) { 'pings' } else { 'MAC seen' }) + ') but no service answers - restart its PoE port (or power).' } }
  return @{ k = 'check'; t = 'Answers ping and ports ' + (@($reach.open) -join '/') + ' but DW cannot use it - run Camera doctor on it (password, lockout, hung web page).' }
}
# DW cameras that are offline / not recording, or have not recorded for 24 h -> with the likely cause
function Get-TkDwProblemCams($channels, [int]$staleHours = 24, $nowUtc = $null) {
  if (-not $nowUtc) { $nowUtc = [DateTime]::UtcNow }
  $arp = $(if ($env:WIREIT_TEST_REACH) { @{} } else { Get-TkArpTable })
  $out = @()
  foreach ($c in @($channels)) {
    if (-not $c) { continue }
    $st = [string]$c.detect; $nw = $null; if ($c.newest) { try { $nw = ([datetime]$c.newest).ToUniversalTime() } catch {} }
    if ($c.newest -is [datetime]) { $nw = $c.newest }
    $hrs = $(if ($nw) { [math]::Round(($nowUtc - $nw).TotalHours) } else { $null })
    $bad = ($st -and $st -notin @('Recording', 'Online')); $stale = ($null -eq $hrs -and $c.scheduled) -or ($null -ne $hrs -and $hrs -gt $staleHours -and -not $c.recording_now)
    if (-not $bad -and -not $stale) { continue }
    $rch = $(if ($c.ip) { Test-TkCamReach ([string]$c.ip) ([string]$c.mac) @(80, 554) $arp } else { $null })
    $cause = $(if ($rch) { Get-TkLikelyCause $rch $st } else { @{ k = 'noip'; t = 'no IP known in DW' } })
    $when = $(if ($nw) { 'last recording ' + $nw.ToLocalTime().ToString('MMM d') + $(if ($hrs -ge 48) { ' (' + [math]::Floor($hrs / 24) + ' days ago)' } else { ' (' + $hrs + ' h ago)' }) } else { 'no recording found' })
    $nm = $(if ($c.name) { [string]$c.name } else { 'camera ' + $c.ch })
    $out += [pscustomobject]@{ name = $nm; ip = [string]$c.ip; status = $st; hours = $hrs; cause = $cause.k; reach = $rch; t = ($nm + ' (' + $c.ip + ') - DW: ' + $(if ($st) { $st } else { '?' }) + ', ' + $when + ': ' + $cause.t) }
  }
  return $out
}

# ---------------- "Check this site" summary (Nov 3 2026): one record for the results pane + the site page's "Latest check" card ----------------
# -> @{ ok; lines = @(@{ t; k = red|ok|warn|plain }); fixes = @('recording','restart','readd','ntp','firmware','password'); page = <small, no passwords> }
# 1.6.1 (YKW Elm live test): words that mean "could not look" - never shown as OK, never offered as a fix
$TkNotCheckedRx = 'login refused|login skipped|not checked|no answer|unreadable'
function Test-TkNotChecked($x) { if (-not $x -or $x.ok) { return $false }; $p = @($x.problems | Where-Object { $_ }); return ($p.Count -gt 0 -and -not @($p | Where-Object { $_ -notmatch $TkNotCheckedRx }).Count) }
function Get-TkNotCheckedWhy($x) { $p = (@($x.problems) -join ';'); if ($p -match 'login skipped') { return 'login skipped' }; if ($p -match 'login refused') { return 'login refused' }; if ($p -match 'no answer') { return 'no answer' }; return 'could not read it' }
function New-TkSiteCheck($Health, $Scan, $Upnp, [string]$Site = '', [string]$Ip = '', $Dw = $null, [string]$DwNotChecked = '', [string]$StopWhy = '') {
  $L = New-Object System.Collections.Generic.List[object]; $fix = New-Object System.Collections.Generic.List[string]
  $add = { param($t, $k) $L.Add(@{ t = $t; k = $k }) }
  $j = { param($a) (@($a) | Where-Object { $_ }) -join '; ' }
  $page = [ordered]@{ t = (Get-Date -Format 's'); ip = $Ip; ok = $true }
  $nc = New-Object System.Collections.Generic.List[string]   # parts that could not be checked (amber, page not OK)
  $isDw = ($Health -and [string]$Health.vendor -eq 'DW')
  $loginWhy = ''; if ($Health -and $Health.recording -and (Test-TkNotChecked $Health.recording)) { $loginWhy = Get-TkNotCheckedWhy $Health.recording }
  # cameras (the list Find cameras just saved)
  $sa = $(if ($Scan) { $Scan.answer } else { $null })
  if ($sa -and $sa.ok) {
    $miss = @($sa.missing) + @($sa.stillMissing) | Where-Object { $_ }
    $page.cams = [ordered]@{ total = [int]$sa.total; missing = @($miss).Count; added = @($sa.added).Count; changedIp = @($sa.changedIp).Count; missingNames = @($miss | Select-Object -First 8) }
    if (@($miss).Count) { & $add ('Cameras: ' + @($miss).Count + ' MISSING of ' + [int]$sa.total + ' on the site list: ' + (& $j ($miss | Select-Object -First 5))) 'red' }
    else { & $add ('Cameras: all ' + [int]$sa.total + ' on the site list found.') 'ok' }
  } elseif ($Scan -and $Scan.local) {
    # 1.6.1: the list Find cameras just made on this PC (no Site ID / no upload) - counted, not compared with a site list
    $dwN = $(if ($isDw -and $Health.recording) { @($Health.recording.channels).Count } else { 0 })
    $page.cams = [ordered]@{ total = [int]$Scan.count; cameras = [int]$Scan.cameras; local = $true; missing = 0; dwListed = $dwN }
    & $add ('Cameras: ' + [int]$Scan.count + ' found on the network by Find cameras just now (' + [int]$Scan.cameras + ' cameras)' + $(if ($dwN) { ', DW lists ' + $dwN } else { '' }) + '. Not compared with a site list - type the Site ID to compare.') 'ok'
  } else { $page.cams = $null; & $add 'Cameras: no fresh list (Find cameras did not run in the last 30 minutes or found nothing).' 'warn' }
  # recorder
  if ($Health) {
    $rec = $Health.recording; $clk = $Health.clock; $fw = $Health.firmware
    $page.vendor = [string]$Health.vendor
    $chs = @($rec.channels)
    $off = @($chs | Where-Object { $_.online -eq $false } | ForEach-Object { $_.ch }); $sched = @($chs | Where-Object { $_.scheduled -eq $false } | ForEach-Object { $_.ch })
    $notRec = @($chs | Where-Object { -not $_.recording_now -and -not ($_.mode -match '(?i)motion|alarm|event|smart|vmd') } | ForEach-Object { $_.ch })
    $page.rec = [ordered]@{ ok = [bool]$rec.ok; channels = $chs.Count; recording = [int]$rec.recording; offline = $off; scheduleOff = $sched; daysHeld = $rec.days_held; target = $rec.target_days; problems = @($rec.problems) }
    if ($rec.ok) { & $add ('Recording: all ' + [int]$rec.recording + ' cameras recording, ' + $rec.days_held + ' days kept (target ' + $rec.target_days + ').') 'ok' }
    elseif ($loginWhy) { & $add ('Recording: NOT CHECKED (' + $loginWhy + ')') 'warn'; $nc.Add('recording'); $page.rec.notChecked = $loginWhy }
    else { & $add ('Recording: ' + (& $j $rec.problems)) 'red' }
    $sf = $(if ($rec.streams) { @($rec.streams.flags) } else { @() })
    $page.streams = $(if ($rec.streams -and $rec.streams.checked) { [ordered]@{ checked = [int]$rec.streams.checked; flags = $sf } } else { $null })
    if ($sf.Count) { & $add ('Streams (report only): ' + (& $j ($sf | Select-Object -First 6))) 'warn' } elseif ($page.streams) { & $add ('Streams: sub-stream, bitrate and frame rate normal on ' + $rec.streams.checked + ' cameras.') 'ok' }
    $page.clock = [ordered]@{ ok = [bool]$clk.ok; problems = @($clk.problems | Select-Object -First 8) }
    # 1.6.1: an unreadable clock = "not checked" (amber); only a clock that was READ and is wrong is red and gets the time fix
    $clkReal = @($clk.problems | Where-Object { $_ -and $_ -notmatch $TkNotCheckedRx })
    if ($clk.ok) { & $add 'Clocks: right, time server on.' 'ok' }
    elseif ($clkReal.Count) {
      & $add ('Clocks: ' + (& $j ($clkReal | Select-Object -First 4))) 'red'
      # 1.4: behind a DW server a wrong CAMERA clock was read without a login - "Fix time" has no camera password, so no button for it
      if (-not ($isDw -and -not @($clkReal | Where-Object { $_ -notmatch '^camera ' }).Count)) { $fix.Add('ntp') }
    }
    else { & $add ('Clock: not checked (' + $(if ($loginWhy) { $loginWhy } else { 'could not read it' }) + ')') 'warn'; $nc.Add('clock'); $page.clock.notChecked = $true }
    $page.fw = [ordered]@{ ok = [bool]$fw.ok; problems = @($fw.problems | Select-Object -First 8) }
    if ($fw.ok) { & $add 'Firmware: current, no known security holes.' 'ok' }
    elseif (Test-TkNotChecked $fw) { & $add ('Firmware: not checked (' + $(if ($loginWhy) { $loginWhy } else { Get-TkNotCheckedWhy $fw }) + ')') 'warn'; $nc.Add('firmware') }
    elseif ($isDw) { & $add ('Firmware (report only - a DW server is updated with the DW installer, not by the Toolkit): ' + (& $j ($fw.problems | Select-Object -First 4))) 'warn'; $page.fw.reportOnly = $true }   # 1.6.1: never a firmware fix for DW
    else { & $add ('Firmware: ' + (& $j ($fw.problems | Select-Object -First 4))) 'red'; $fix.Add('firmware') }
    if ($sched.Count) { $fix.Add('recording') }
    # 1.4 (YKW Elm): "Put the camera back on the NVR" is never offered on a DW server (there is no NVR channel), and
    # "Restart the camera" only for a camera that still has a network link (it reboots through the camera's own web page).
    # DW cameras: decided below from the ping / ARP cause. NVR cameras: an offline camera whose IP shows no link is left out.
    if ($off.Count -and -not $isDw) {
      $offLinked = @($chs | Where-Object { $_.online -eq $false } | Where-Object { -not $_.PSObject.Properties['ip'] -or -not $_.ip -or (Test-TkHasLink ([string]$_.ip)) })
      if ($offLinked.Count) { $fix.Add('restart') }
      $fix.Add('readd')
    }
    if ((@($rec.problems) -join ';') -match $TkNotCheckedRx) { $page.ok = $false }
  } elseif ($StopWhy) {
    # 1.6.2: the check itself stopped (it may have logged in fine) - say that, not 'no login'
    $sw = $StopWhy; if ($sw.Length -gt 120) { $sw = $sw.Substring(0, 117) + '...' }
    & $add ('Recorder: NOT CHECKED - the check stopped with a problem (' + $sw + '). Run it again; the full log is in the runs folder.') 'warn'; $nc.Add('recorder')
  } else { & $add 'Recorder: not checked (no answer or no login).' 'warn'; $nc.Add('recorder') }
  # DW: cameras offline / not recording / nothing for 24 h, with the likely cause (read-only)
  # 1.6.1 (YKW Elm): a failed / skipped DW login gave an EMPTY camera list, which used to print "every camera online". Now:
  # no DW data = "Offline in DW: NOT CHECKED (...)" in amber, never green.
  $dwWhy = $DwNotChecked
  if (-not $dwWhy -and $isDw) {
    if ($loginWhy) { $dwWhy = $loginWhy } elseif ($null -eq $Dw) { $dwWhy = 'no DW data' } elseif (-not @($Health.recording.channels).Count) { $dwWhy = 'DW returned no cameras' }
  }
  if ($dwWhy) {
    $page.dw = [ordered]@{ notChecked = $dwWhy }; $nc.Add('dw')
    & $add ('Offline in DW: NOT CHECKED (' + $dwWhy + ')') 'warn'
  }
  elseif ($null -ne $Dw) {
    $dwl = @($Dw)
    $page.dw = [ordered]@{ problems = $dwl.Count; cams = @($dwl | Select-Object -First 30 | ForEach-Object { [ordered]@{ name = $_.name; ip = $_.ip; status = $_.status; hours = $_.hours; cause = $_.cause } }) }
    if ($dwl.Count) { foreach ($x in ($dwl | Select-Object -First 12)) { & $add ('DW: ' + $x.t) 'red' }; if ($dwl.Count -gt 12) { & $add ('DW: ' + ($dwl.Count - 12) + ' more - see the log.') 'red' } }
    else { & $add ('Offline in DW: none - all ' + $(if ($Health -and $Health.recording) { @($Health.recording.channels).Count } else { '' }) + ' cameras online and recorded in the last 24 h.') 'ok' }
    if (@($dwl | Where-Object { $_.cause -eq 'dwpw' }).Count) { $fix.Add('dwpassword') }
    if (@($dwl | Where-Object { $_.cause -in @('hung', 'check') }).Count) { $fix.Add('restart') }   # 1.4: only cameras that still answer on the network
  }
  # 1.4: a camera MISSING from Find cameras has no network link here, so "Restart the camera" (through its web page) cannot reach it - not offered
  # router
  if ($Upnp) {
    $page.router = [ordered]@{ checked = $true; answered = [bool]$Upnp.answered; upnp = [bool]$Upnp.upnp; model = [string]$Upnp.router; exposed = @($Upnp.exposed | ForEach-Object { '' + $_.ext + '/' + $_.proto + ' -> ' + $_.client + ':' + $_.port }) }
    if ($Upnp.upnp -or @($Upnp.exposed).Count) { foreach ($ul in @($Upnp.lines | Where-Object { $_.k -eq 'red' })) { & $add $ul.t 'red' } } else { & $add ('Router: ' + $(if ($Upnp.answered) { 'no ports opened through UPnP' } else { 'UPnP did not answer (off or blocked)' }) + '. Port forwards made by hand are not checked - look in the router.') 'ok' }
  } else { $page.router = $null }
  $page.fixes = @($fix | Select-Object -Unique)
  $page.notChecked = @($nc | Select-Object -Unique)
  $page.ok = $page.ok -and -not @($L | Where-Object { $_.k -eq 'red' }).Count -and -not $nc.Count
  return [pscustomobject]@{ ok = $page.ok; lines = $L.ToArray(); fixes = @($page.fixes); page = $page }
}

# 2.2.2 (Codex H2): the same private-IPv4 test in plain PowerShell, for PowerShell 7's per-call certificate skip and curl's -k
function Test-WireItLanHost([string]$h) {
  if (-not $h) { return $false }; $a = $null; if (-not [Net.IPAddress]::TryParse($h.Trim('[', ']'), [ref]$a)) { return $false }
  if ($a.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { return $false }
  $b = $a.GetAddressBytes()
  return ($b[0] -eq 10 -or $b[0] -eq 127 -or ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) -or ($b[0] -eq 192 -and $b[1] -eq 168) -or ($b[0] -eq 169 -and $b[1] -eq 254))
}
# ---------------- Nov 3 2026 (YKW Elm live test) small helpers ----------------
# the DW server's own name, no login needed (moduleInformation) - used for the days-to-keep target when no site was typed
function Get-TkDwName([string]$ip, [string]$mockUrl = '') {
  $u = $(if ($mockUrl) { $mockUrl.TrimEnd('/') + '/dev/' + $ip + '/api/moduleInformation' } else { 'https://' + $ip + ':7001/api/moduleInformation' })
  $j = $null
  try { $j = (Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 4).Content | ConvertFrom-Json } catch {}
  if (-not $j -and -not $mockUrl) { try { $ka = @('-s', '-m', '4'); if (Test-WireItLanHost $ip) { $ka = @('-k') + $ka }; $o = & (Join-Path $env:SystemRoot 'System32\curl.exe') @ka $u 2>$null; if ($o) { $j = ($o | Out-String) | ConvertFrom-Json } } catch {} }
  if ($j -and $j.PSObject.Properties['reply']) { $j = $j.reply }
  if ($j) { if ($j.PSObject.Properties['systemName'] -and $j.systemName) { return [string]$j.systemName }; return [string]$j.name }
  return ''
}
# "Recorder type" box -> NvrCheck -Vendor
function Get-TkVendorArg([string]$s) {
  switch -regex (([string]$s).Trim()) { '(?i)^(dw|digital|spectrum|watchdog)' { return 'DW' } '(?i)^hik' { return 'Hikvision' } '(?i)^(uni|unv)' { return 'Uniview' } '(?i)^onvif' { return 'Onvif' } default { return 'Auto' } }
}
