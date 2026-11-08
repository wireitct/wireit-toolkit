<#
 FixSiteIpc.ps1 - WireIt Toolkit 2.2.0: how "Fix this site" runs for the Crew login without any admin name or password (review H3).
   The Toolkit window (Crew, no admin) writes ONE request file and starts the scheduled task "\WireIt\Fix this site", which an admin
   made at install and which runs FixSiteRunner.ps1 as SYSTEM. The runner reads the request, keeps ONLY the allowed fields
   (mode from a fixed list, the site, the camera-setting drop-downs from fixed lists, two ticks), and runs FixSite.ps1 itself.
   Nothing from the request becomes a path, a program or a command: Undo picks the last run by itself, and every value is checked
   against its fixed list or pattern. While it runs, every question (Yes/No buttons, the passwords it asks for, YES) is a small file
   in ipc\s-<id>\ that the window shows and answers; answers are checked the same way (yes/no only for a choice; one line of text,
   at most 256 characters, for a typed answer) and deleted the moment they are read.
 Dot-sourced by FixSiteRunner.ps1, FixSite.ps1 (-Ipc) and FixSiteWindow.ps1. Tested in tests\Test-Fix22.ps1.
#>
$script:FsTaskPath = '\WireIt\'; $script:FsTaskName = 'Fix this site'
$script:FsRunModes = @('Fix', 'Plan', 'SitePassword', 'Rollback', 'Update', 'UndoUpdate')
$script:FsCodecs = @('auto', 'keep', 'H.264', 'H.265')
$script:FsFpsList = @(0, 10, 12, 15, 20, 25, 30)
$script:FsResList = @('keep', 'max', '1920x1080', '2560x1440', '2688x1520', '3840x2160')
$script:FsBitList = @(0, 1024, 2048, 3072, 4096, 6144, 8192)
$script:FsRequestFields = @('v', 'id', 'mode', 'site', 'newSite', 'codec', 'fps', 'resolution', 'bitrate', 'allCameras', 'passwordAll', 'at', 'user', 'siteList')
$script:FsSiteRe = '^[A-Za-z0-9][A-Za-z0-9 .,#&''()/_-]{0,79}$'
function Get-FsIpcRoot([string]$ToolkitDir) { return (Join-Path $ToolkitDir 'ipc') }
function Get-FsRunnerRunsDir([string]$ToolkitDir) { return (Join-Path $ToolkitDir 'fixsite-runs') }

# ---------------- files: written whole (tmp + rename), read with a size limit ----------------
function Write-FsIpcJson([string]$Path, $Obj) {
  $tmp = $Path + '.' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.tmp'
  [IO.File]::WriteAllText($tmp, ($Obj | ConvertTo-Json -Depth 6 -Compress), (New-Object Text.UTF8Encoding($false)))
  Move-Item -LiteralPath $tmp -Destination $Path -Force
}
function Read-FsIpcJson([string]$Path, [int]$MaxBytes = 65536) {
  try {
    $fi = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($fi.Length -gt $MaxBytes -or $fi.Length -eq 0) { return $null }
    return ([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8).TrimStart([char]0xFEFF) | ConvertFrom-Json)
  } catch { return $null }
}

# ---------------- the request (Crew -> runner) ----------------
# returns { ok; why; req (only the allowed fields, typed) }
function Test-FsRunRequest($r) {
  $bad = { param($w) return [pscustomobject]@{ ok = $false; why = $w; req = $null } }
  if (-not $r) { return (& $bad 'no request or not readable') }
  foreach ($p in $r.PSObject.Properties) { if ($script:FsRequestFields -notcontains $p.Name) { return (& $bad ('field not allowed: ' + $p.Name)) } }
  $mode = [string]$r.mode
  if ($script:FsRunModes -cnotcontains $mode) { return (& $bad 'mode not allowed') }
  $id = [string]$r.id; if ($id -notmatch '^[A-Za-z0-9-]{8,40}$') { return (& $bad 'bad request id') }
  $o = [ordered]@{ id = $id; mode = $mode; site = ''; newSite = $false; codec = 'auto'; fps = 0; resolution = 'keep'; bitrate = 0; allCameras = $false; passwordAll = $false; siteList = '' }
  foreach ($k in @('newSite', 'allCameras', 'passwordAll')) { if ($r.PSObject.Properties[$k]) { if ($r.$k -isnot [bool]) { return (& $bad ($k + ' must be true or false')) }; $o[$k] = [bool]$r.$k } }
  if ($mode -in @('Fix', 'Plan', 'SitePassword')) {
    $site = ([string]$r.site).Trim()
    if ($o.newSite -and $mode -ne 'SitePassword') { $site = '' }
    elseif ($site -notmatch $script:FsSiteRe) { return (& $bad 'site name has characters that are not allowed (letters, digits, space . , # & '' ( ) / _ - only, at most 80)') }
    $o.site = $site
    if ($mode -eq 'SitePassword') { $o.newSite = $false }
  } else { $o.newSite = $false; $o.allCameras = $false; $o.passwordAll = $false }
  if ($mode -in @('Fix', 'Plan')) {
    if ($r.PSObject.Properties['codec']) { $c = [string]$r.codec; if ($script:FsCodecs -cnotcontains $c) { return (& $bad 'codec not in the list') }; $o.codec = $c }
    if ($r.PSObject.Properties['fps']) { $v = 0; if (-not [int]::TryParse([string]$r.fps, [ref]$v) -or $script:FsFpsList -notcontains $v) { return (& $bad 'frame rate not in the list') }; $o.fps = $v }
    if ($r.PSObject.Properties['resolution']) { $c = [string]$r.resolution; if ($script:FsResList -cnotcontains $c) { return (& $bad 'resolution not in the list') }; $o.resolution = $c }
    if ($r.PSObject.Properties['bitrate']) { $v = 0; if (-not [int]::TryParse([string]$r.bitrate, [ref]$v) -or $script:FsBitList -notcontains $v) { return (& $bad 'bitrate not in the list') }; $o.bitrate = $v }
    # a copy of the site's list from the tech's Google Drive (SYSTEM cannot see the G: drive): data only, must be a site list
    if ($r.PSObject.Properties['siteList'] -and [string]$r.siteList) {
      $t = [string]$r.siteList; if ($t.Length -gt 524288) { return (& $bad 'site list too big') }
      $j = $null; try { $j = $t | ConvertFrom-Json } catch {}
      if (-not $j -or -not $j.PSObject.Properties['cameras']) { return (& $bad 'site list is not a WireIt site list') }
      $o.siteList = ($j | ConvertTo-Json -Depth 8 -Compress)
    }
  } else { $o.codec = 'auto'; $o.fps = 0; $o.resolution = 'keep'; $o.bitrate = 0 }
  return [pscustomobject]@{ ok = $true; why = ''; req = [pscustomobject]$o }
}
# the FixSite.ps1 arguments for a checked request: an ARRAY (never one command string), every value from the checks above
function Get-FsRunArgs($Req, [string]$Session, [string]$RunsRoot, [string]$RollbackDir = '', [string]$ListFile = '') {
  $a = @('-Mode', [string]$Req.mode, '-Ipc', $Session, '-RunsRoot', $RunsRoot, '-CloseAfter', '0')
  if ($Req.newSite) { $a += '-NewSite' } elseif ($Req.site) { $a += @('-Site', [string]$Req.site) }
  if ($Req.mode -in @('Fix', 'Plan')) {
    $a += @('-Codec', [string]$Req.codec)
    if ([int]$Req.fps) { $a += @('-Fps', [string][int]$Req.fps) }
    $a += @('-Resolution', [string]$Req.resolution)
    if ([int]$Req.bitrate) { $a += @('-Bitrate', [string][int]$Req.bitrate) }
    if ($Req.allCameras) { $a += '-AllCameras' }
    if ($Req.passwordAll) { $a += '-PasswordAll' }
    if ($ListFile) { $a += @('-ListFile', $ListFile) }
  }
  if ($Req.mode -eq 'Rollback' -and $RollbackDir) { $a += @('-RollbackDir', $RollbackDir) }
  return ,$a
}

# ---------------- questions and answers (runner -> window -> runner) ----------------
# kinds: text | secret | choice | show (the site password shown once with Copy) | clip | clipclear | portal (Hikvision's page) | info
#        | bitwarden (2.2.2: the window saves the site password in Bitwarden on the tech's login; answer "result;where;why;org;collection")
$script:FsIpcN = 0
function Send-FsIpc([string]$Dir, [hashtable]$Msg) {
  $script:FsIpcN++
  $Msg['n'] = $script:FsIpcN; $Msg['at'] = (Get-Date -Format 's')
  Write-FsIpcJson (Join-Path $Dir ('q-{0:D4}.json' -f $script:FsIpcN)) $Msg
  return $script:FsIpcN
}
# waits for a-<n>.json. Returns the checked answer (string / bool / portal result), or $null on timeout or a stop.
function Wait-FsIpcAnswer([string]$Dir, [int]$N, [string]$Kind, [int]$TimeoutSec = 3600, [int]$PollMs = 250) {
  $af = Join-Path $Dir ('a-{0:D4}.json' -f $N); $qf = Join-Path $Dir ('q-{0:D4}.json' -f $N)
  $end = (Get-Date).AddSeconds($TimeoutSec)
  while ((Get-Date) -lt $end) {
    if (Test-Path -LiteralPath $af) {
      Start-Sleep -Milliseconds 50
      $a = Read-FsIpcJson $af 8192
      Remove-Item -LiteralPath $af -Force -ErrorAction SilentlyContinue; Remove-Item -LiteralPath $qf -Force -ErrorAction SilentlyContinue
      return (ConvertFrom-FsIpcAnswer $Kind $a)
    }
    if (Test-Path -LiteralPath (Join-Path $Dir 'stop.json')) { Remove-Item -LiteralPath $qf -Force -ErrorAction SilentlyContinue; return $null }
    Start-Sleep -Milliseconds $PollMs
  }
  Remove-Item -LiteralPath $qf -Force -ErrorAction SilentlyContinue
  return $null
}
function ConvertFrom-FsIpcAnswer([string]$Kind, $a) {
  if (-not $a -or -not $a.PSObject.Properties['answer']) { return $null }
  $v = $a.answer
  switch ($Kind) {
    'choice' { $t = ([string]$v).Trim().ToLower(); if ($t -eq 'yes') { return $true }; if ($t -eq 'no') { return $false }; return $null }
    'portal' { $t = ([string]$v).Trim().ToLower(); if ($t -in @('submitted', 'skipped', 'failed', 'timeout', 'no-browser')) { return $t }; return 'failed' }
    'bitwarden' {
      $p = @(([string]$v -replace '[\x00-\x1F\x7F]', '') -split ';'); while ($p.Count -lt 5) { $p += '' }
      $res = $p[0].Trim().ToLower(); if ($res -notin @('saved', 'updated', 'exists', 'failed', 'nobw', 'unauthenticated', 'locked')) { $res = 'failed' }
      $wh = $p[1].Trim().ToLower(); if ($wh -notin @('org', 'personal')) { $wh = '' }
      $cut = { param($s) $s = ([string]$s).Trim(); if ($s.Length -gt 60) { $s = $s.Substring(0, 60) }; $s }
      return [pscustomobject]@{ result = $res; where = $wh; why = (& $cut $p[2]); org = (& $cut $p[3]); collection = (& $cut $p[4]) }
    }
    default { $t = [string]$v; $t = ($t -replace '[\x00-\x1F\x7F]', ''); if ($t.Length -gt 256) { $t = $t.Substring(0, 256) }; return $t }
  }
}
# the window's side: the questions still open, oldest first
function Get-FsIpcQuestions([string]$Dir) {
  $out = @()
  foreach ($f in @(Get-ChildItem -LiteralPath $Dir -Filter 'q-*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
    $q = Read-FsIpcJson $f.FullName 2097152
    if ($q -and -not (Test-Path -LiteralPath (Join-Path $Dir ('a-{0:D4}.json' -f [int]$q.n)))) { $out += $q }
  }
  return $out
}
function Write-FsIpcAnswer([string]$Dir, [int]$N, $Answer) {
  Write-FsIpcJson (Join-Path $Dir ('a-{0:D4}.json' -f $N)) ([ordered]@{ n = $N; answer = $Answer; at = (Get-Date -Format 's') })
  # fire-and-forget kinds have nobody waiting: their question file goes now
  $qf = Join-Path $Dir ('q-{0:D4}.json' -f $N)
  try { $q = Read-FsIpcJson $qf 2097152; if ($q -and [string]$q.kind -in @('clip', 'clipclear', 'info')) { Remove-Item -LiteralPath $qf -Force -ErrorAction SilentlyContinue; Remove-Item -LiteralPath (Join-Path $Dir ('a-{0:D4}.json' -f $N)) -Force -ErrorAction SilentlyContinue } } catch {}
}
# removes every question/answer file of a finished run (the answers can hold a typed password) and old sessions
function Clear-FsIpcSession([string]$Dir) {
  foreach ($p in @('q-*.json', 'a-*.json', '*.tmp', 'portal-*', 'site-list.json')) { Get-ChildItem -LiteralPath $Dir -Filter $p -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue }
}
function Clear-FsIpcOld([string]$Root, [int]$Hours = 24) {
  foreach ($d in @(Get-ChildItem -LiteralPath $Root -Directory -Filter 's-*' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddHours(-$Hours) })) { Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue }
}

# ---------------- starting the task (the window's side) ----------------
function Test-FsRunnerTask {
  if ($env:WIREIT_RUNNER_TEST) { return $true }
  try { $o = & schtasks.exe /Query /TN ($script:FsTaskPath + $script:FsTaskName) 2>$null; return ($LASTEXITCODE -eq 0) } catch { return $false }
}
# writes the request and starts the task. Returns { ok; why; id }
function Start-FsRunner([string]$ToolkitDir, [hashtable]$Request) {
  $root = Get-FsIpcRoot $ToolkitDir
  if (-not (Test-Path -LiteralPath $root)) { return [pscustomobject]@{ ok = $false; why = 'the Toolkit is not set up for the Crew login on this PC yet (ask the office to run the Toolkit installer once as admin)'; id = '' } }
  $cur = Read-FsIpcJson (Join-Path $root 'current.json')
  if ($cur -and [string]$cur.state -eq 'running' -and $cur.started -and ([datetime]$cur.started) -gt (Get-Date).AddHours(-4)) { return [pscustomobject]@{ ok = $false; why = 'a Fix this site run is still going'; id = [string]$cur.id } }
  $Request['v'] = 1; if (-not $Request['id']) { $Request['id'] = [guid]::NewGuid().ToString('N') }; $Request['at'] = (Get-Date -Format 's'); $Request['user'] = [string]$env:USERNAME
  Write-FsIpcJson (Join-Path $root 'request.json') $Request
  if ($env:WIREIT_RUNNER_TEST) { return [pscustomobject]@{ ok = $true; why = ''; id = [string]$Request['id'] } }
  $o = & schtasks.exe /Run /TN ($script:FsTaskPath + $script:FsTaskName) 2>&1 | Out-String
  if ($LASTEXITCODE -ne 0) { Remove-Item -LiteralPath (Join-Path $root 'request.json') -Force -ErrorAction SilentlyContinue; return [pscustomobject]@{ ok = $false; why = ('Windows did not start the Fix this site task (' + ($o.Trim() -replace '\s+', ' ') + ')'); id = '' } }
  return [pscustomobject]@{ ok = $true; why = ''; id = [string]$Request['id'] }
}
