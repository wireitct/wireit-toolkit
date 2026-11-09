<# Test-Fix227.ps1 - behavioural tests for the 2.2.7 fixes (Codex's file-by-file review of 2.2.6, findings F01-F20).
   Real functions and the real entry points (FixSite.ps1, FixNVR.ps1, HikReset.ps1, ScanUpload.ps1, CamViews, NvrHealth, the
   Toolkit's Find cameras callback) against loopback servers / mock devices only. Each check failed on 2.2.6 head a64924e.
   Windows PowerShell 5.1 or pwsh 7. Checks that need a real Windows ACL / DPAPI run on Windows only; the half-way write checks
   (F03, F18) need a per-process file-size limit and run on Linux only. Each skipped check says so. #>
$ErrorActionPreference = 'Stop'
$tk = Split-Path -Parent $PSScriptRoot; $repo = Split-Path -Parent $tk
$exe = $(if ($PSVersionTable.PSEdition -eq 'Core') { (Get-Process -Id $PID).Path } else { Join-Path $PSHOME 'powershell.exe' })
$isWin = ($env:OS -eq 'Windows_NT')
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fix227-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$script:pass = 0; $script:fail = 0
# Findings Moshe left for a later round (Nov 8 2026, 7:41 PM: "finish only the serious ones now"): their checks still RUN and are
# printed, a failing one as DEFERRED (not fixed in 2.2.7) instead of FAIL, so the suite says exactly what 2.2.7 does not fix yet.
$script:deferred = @('F15', 'F16', 'F18', 'F19', 'F20'); $script:defer = 0
function Check([bool]$ok, [string]$name, [string]$more = '') {
  $id = [regex]::Match($name, '^F\d\d').Value
  if ($ok) { $script:pass++; Write-Host ('PASS ' + $name) }
  elseif ($id -and $script:deferred -contains $id) { $script:defer++; Write-Host ('DEFERRED ' + $name + '  [not fixed in 2.2.7 - left for a later round]') }
  else { $script:fail++; Write-Host ('FAIL ' + $name); if ($more) { Write-Host $more } }
}
# every top-level function definition of a script, without running the script itself (the real code, nothing copied by hand)
function Get-FnText([string]$file, [string[]]$only = @()) {
  $ast = [Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$null)
  $fns = @($ast.FindAll({ param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] }, $true))
  $top = @($fns | Where-Object { $p = $_.Parent; $inFn = $false; while ($p) { if ($p -is [Management.Automation.Language.FunctionDefinitionAst]) { $inFn = $true; break }; $p = $p.Parent }; -not $inFn })
  if ($only.Count) { $top = @($top | Where-Object { $only -contains $_.Name }) }
  return (($top | ForEach-Object { $_.Extent.Text }) -join "`n")
}
# a small PowerShell driver in its own process (no test leaks into another); returns its output as text
function Invoke-Driver([string]$name, [string]$code) {
  $f = Join-Path $tmp ($name + '.ps1'); [IO.File]::WriteAllText($f, $code, (New-Object Text.UTF8Encoding($true)))
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $o = & $exe -NoProfile -ExecutionPolicy Bypass -File $f 2>&1 | Out-String } finally { $ErrorActionPreference = $prev }
  return $o
}
function Get-Json([string]$out) { $m = [regex]::Match($out, '(?m)^JSON=(\{.*\})\s*$'); if ($m.Success) { try { return ($m.Groups[1].Value | ConvertFrom-Json) } catch {} }; return $null }
function Q([string]$s) { return "'" + $s.Replace("'", "''") + "'" }
$servers = @()
try {
  . (Join-Path $PSScriptRoot 'TestPython.ps1'); $py = Get-TestPython

  # =====================================================================================
  # F01 F02 F03 F09: the real Fix this site, stopped at the worst moment, then the real Undo
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  $scenario = & $py (Join-Path $PSScriptRoot 'fix227/scenarios.py') --repo $repo --powershell $exe 2>&1 | Out-String
  $ErrorActionPreference = $prev
  $res = $null; try { $res = (($scenario.Trim() -split "`n")[-1]) | ConvertFrom-Json } catch {}
  if (-not $res) { Check $false 'Fix this site scenarios ran' $scenario }
  else {
    Check ($res.channel_video_back -and $res.channel_cam_old_pw -and $res.channel_undo_exit -eq 0) ('F01 a run stopped right after the NVR took a camera''s channel change: Undo puts the channel back too, so the video comes back (Undo exit ' + $res.channel_undo_exit + ')') ([string]$res.channel_out + [string]$res.channel_error)
    Check ($res.channel_video_back -or (-not $res.channel_said_all_back -and -not $res.channel_undone_file)) 'F01 ...and Undo never says "everything is back" while the channel is still changed' ([string]$res.channel_out)
    Check ($res.nvrmove_back -and $res.nvrmove_undo_exit -eq 0 -and -not $res.nvrmove_no_login_msg) ('F02 a run stopped while the NVR moved: Undo logs in at the new address with the saved login and moves it back (Undo exit ' + $res.nvrmove_undo_exit + ')') ([string]$res.nvrmove_out + [string]$res.nvrmove_error)
    if ($res.PSObject.Properties['atomic_skipped']) { Write-Host ('SKIP F03 half-way undo-file write: ' + $res.atomic_skipped) }
    else {
      Check ($res.atomic_exit -eq 7) ('F03 setup: a later undo-file write fails half-way (file-size limit) and the run stops with exit 7 (exit ' + $res.atomic_exit + ')') ([string]$res.atomic_out + [string]$res.atomic_error)
      Check ([bool]$res.atomic_journal_valid) ('F03 ...and the undo file already on disk is still whole and readable (' + $res.atomic_journal_size + ' bytes), so Undo still knows the earlier changes') ([string]$res.atomic_out)
      Check (-not @($res.atomic_left_tmp).Count) ('F03 ...and no half-written temporary undo file is left beside it (' + (@($res.atomic_left_tmp) -join ',') + ')')
    }
    Check ([bool]$res.settings_smart_back) 'F09 Undo puts Smart Codec back on when the run found it on' ([string]$res.settings_out + [string]$res.settings_error)
    Check ($res.settings_undo_exit -ne 0 -and -not $res.settings_undone_file -and [string]$res.settings_out -notmatch 'everything is back') ('F09 a camera that keeps the wrong I-frame interval (now ' + $res.settings_gop_now + ', was 30) is NOT reported as put back (Undo exit ' + $res.settings_undo_exit + ')') ([string]$res.settings_out)
  }

  # =====================================================================================
  # F04 F05: classic Fix NVR - the rollback file must be saved before (and while) anything changes; Undo includes accepted-but-unconfirmed steps
  $fnv = Join-Path $repo 'FixNVR/FixNVR.ps1'
  $d = Invoke-Driver 'f04' ((Get-FnText $fnv) + @"

`$ErrorActionPreference = 'Continue'
`$logFile = Join-Path $(Q $tmp) 'f04-log.txt'; `$sum = New-Object System.Collections.Generic.List[string]
`$bad = Join-Path $(Q $tmp) 'no-such-folder/deeper/rollback.json'
`$threw = `$false; try { Save-Json @{ a = 1 } `$bad } catch { `$threw = `$true }
`$good = Join-Path $(Q $tmp) 'f04-ok.json'; Save-Json @{ a = 1; steps = @(1, 2) } `$good
'JSON=' + (@{ threw = `$threw; okFile = (Test-Path `$good); okJson = [bool]((Get-Content `$good -Raw | ConvertFrom-Json).a -eq 1); tmpLeft = @(Get-ChildItem $(Q $tmp) | Where-Object { `$_.Name -like 'f04-ok.json.*.tmp' }).Count } | ConvertTo-Json -Compress)
"@)
  $j = Get-Json $d
  Check ($j -and $j.threw) 'F04 classic Fix NVR: a rollback file that cannot be written STOPS the run (the writer fails loudly, it no longer just goes on)' $d
  Check ($j -and $j.okFile -and $j.okJson -and $j.tmpLeft -eq 0) 'F04 ...and a rollback file that can be written is saved whole (no temporary file left)' $d
  $fsrc = [IO.File]::ReadAllText($fnv)
  Check ($fsrc -notmatch "if \(-not \`$rev\) \{ Save-Json \`$rbObj \`$rbPath; Say \('Rollback info saved first") 'F04 ...and "Rollback info saved first" is said only after the save worked (the caller stops on a failed save)'
  $d = Invoke-Driver 'f05' ((Get-FnText $fnv) + @"

`$ErrorActionPreference = 'Continue'
`$logFile = Join-Path $(Q $tmp) 'f05-log.txt'; `$sum = New-Object System.Collections.Generic.List[string]
`$rb = [pscustomobject]@{ steps = @(
  [pscustomobject]@{ type = 'cam-net'; old_ip = '10.0.5.31'; new_ip = '192.168.1.31'; channel = '1'; done = `$true },
  [pscustomobject]@{ type = 'cam-net'; old_ip = '10.0.5.32'; new_ip = '192.168.1.32'; channel = '2'; done = `$false; attempted = `$true },
  [pscustomobject]@{ type = 'nvr-channel'; old_ip = '10.0.5.33'; new_ip = '192.168.1.33'; channel = '3'; done = `$false },
  [pscustomobject]@{ type = 'nvr-platform'; done = `$true }) }
`$sel = @(Get-FnRollbackSteps `$rb)
`$failed = @{ '192.168.1.32' = `$true }
`$dep = Test-FnSkipDependent ([pscustomobject]@{ type = 'nvr-channel'; new_ip = '192.168.1.32'; channel = '2' }) `$failed
`$indep = Test-FnSkipDependent ([pscustomobject]@{ type = 'nvr-channel'; new_ip = '192.168.1.31'; channel = '1' }) `$failed
'JSON=' + (@{ n = `$sel.Count; first = [string]`$sel[0].new_ip; second = [string]`$sel[1].new_ip; dep = [bool]`$dep; indep = [bool]`$indep } | ConvertTo-Json -Compress)
"@)
  $j = Get-Json $d
  Check ($j -and $j.n -eq 2 -and $j.first -eq '192.168.1.32' -and $j.second -eq '192.168.1.31') 'F05 classic Undo takes back a step that was sent but not confirmed (timeout / stopped run) as well as the done ones, newest first' $d
  Check ($j -and $j.dep -and -not $j.indep) 'F05 ...and the NVR channel of a camera whose move FAILED is not pointed at the address the camera never took' $d
  Check ($fsrc -match '\$st\.attempted = \$true' -and $fsrc -match 'Test-FnSkipDependent \$st') 'F05 ...the apply loop marks each step as sent (saved) before it is sent, and uses the dependent-step rule'

  # =====================================================================================
  # F06: no password over plain HTTP to a box that only asks for Basic (FixNVR, CamViews, NetCheck, SiteCheck)
  $srvs = @{}
  foreach ($mode in @('basic', 'digest')) {
    $pf = Join-Path $tmp ('auth-' + $mode + '.port'); $lf = Join-Path $tmp ('auth-' + $mode + '.log')
    $spa = @{ FilePath = $py; ArgumentList = @((Join-Path $PSScriptRoot 'fix227/auth_server.py'), $mode, $pf, $lf); PassThru = $true }; if ($isWin) { $spa.WindowStyle = 'Hidden' }
    $p = Start-Process @spa; $servers += $p
    for ($i = 0; $i -lt 100 -and -not (Test-Path $pf); $i++) { Start-Sleep -Milliseconds 100 }
    $srvs[$mode] = @{ port = (Get-Content $pf -Raw).Trim(); log = $lf }
  }
  # SiteCheck's read-only core is the $SC_CODE text inside SiteCheck.ps1 (its window part needs Windows' drawing library): that text is run as is
  $scAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'sitecheck/SiteCheck.ps1'), [ref]$null, [ref]$null)
  $scCore = [string]@($scAst.FindAll({ param($a) $a -is [Management.Automation.Language.AssignmentStatementAst] -and $a.Left.Extent.Text -eq '$SC_CODE' }, $false))[0].Right.Expression.Value
  $credLine = '$cred = New-Object PSCredential(''admin'', (ConvertTo-SecureString ''Synthetic#Pw227'' -AsPlainText -Force))'
  $tools = [ordered]@{
    'FixNVR' = @{ pre = ((Get-FnText $fnv) + "`n`$ErrorActionPreference = 'Continue'; `$script:refused = @{}; `$script:scheme = @{}; `$script:nvrTls = @{}; `$Mock = `$null; `$IsPs5 = (`$PSVersionTable.PSVersion.Major -lt 6); `$logFile = Join-Path " + (Q $tmp) + " 'f06-fn.txt'; `$sum = New-Object System.Collections.Generic.List[string]`n"); call = '$r = Http ("127.0.0.1:" + $port) ''GET'' ''/ISAPI/System/deviceInfo'' '''' ''application/xml'' $cred 5; $code = [int]$r.code' }
    'CamViews' = @{ pre = (". " + (Q (Join-Path $tk 'CamViews.ps1')) + " -Lib`n`$ErrorActionPreference = 'Continue'`n"); call = '$r = CvGet ("http://127.0.0.1:" + $port + "/ISAPI/System/deviceInfo") $cred 5; $code = [int]$r.code' }
    'NetCheck' = @{ pre = ((Get-FnText (Join-Path $repo 'NetCheck/NetCheck.ps1')) + "`n`$ErrorActionPreference = 'Continue'`n"); call = '$r = Get-Isapi ("http://127.0.0.1:" + $port) ''/ISAPI/System/deviceInfo''; $code = [int]$r.code' }
    'SiteCheck' = @{ pre = ($scCore + "`n`$ErrorActionPreference = 'Continue'`n"); call = '$r = Invoke-ScHttpGet ("http://127.0.0.1:" + $port + "/ISAPI/System/deviceInfo") $cred 5000; $code = [int]$r.Code' }
  }
  foreach ($tn in $tools.Keys) {
    foreach ($mode in @('basic', 'digest')) {
      [IO.File]::WriteAllText($srvs[$mode].log, '')
      $d = Invoke-Driver ('f06-' + $tn + '-' + $mode) ($tools[$tn].pre + $credLine + "`n`$port = " + $srvs[$mode].port + "`n" + $tools[$tn].call + "`n'JSON=' + (@{ code = `$code } | ConvertTo-Json -Compress)`n")
      $j = Get-Json $d; $seen = @((Get-Content -LiteralPath $srvs[$mode].log -ErrorAction SilentlyContinue) | Where-Object { $_ })
      if ($mode -eq 'basic') { Check ($j -and -not @($seen | Where-Object { $_ -match '^(?i)basic' }).Count) ('F06 ' + $tn + ': a plain-HTTP box that asks only for Basic gets NO password (headers seen: ' + ($seen -join ',') + ')') $d }
      else { Check ($j -and $j.code -eq 200 -and @($seen | Where-Object { $_ -match '^(?i)digest' }).Count) ('F06 ' + $tn + ': ...a Digest login still works (answer ' + $(if ($j) { $j.code } else { '?' }) + ')') $d }
    }
  }


  $scSrc = [IO.File]::ReadAllText((Join-Path $repo 'sitecheck/SiteCheck.ps1')).Replace("`r`n", "`n").Trim()
  $cmdT = [IO.File]::ReadAllText((Join-Path $repo 'sitecheck/WireIt-SiteCheck.cmd')).Replace("`r`n", "`n")
  $mk = $cmdT.IndexOf('##' + 'PSSTART'); $emb = $(if ($mk -ge 0) { $cmdT.Substring($mk + 10).Trim() } else { '' })
  Check ($emb -and $emb -eq $scSrc) 'F06 the copy of SiteCheck inside WireIt-SiteCheck.cmd is identical to SiteCheck.ps1 (same fix in both)'

  # =====================================================================================
  # F07: a failed Find cameras never uploads the PREVIOUS scan under the site now typed
  $wtk = Join-Path $tk 'WireItToolkit.ps1'
  $f07 = Join-Path $tmp 'f07'; New-Item -ItemType Directory -Force -Path (Join-Path $f07 'CamReset/out'), (Join-Path $f07 'Toolkit') | Out-Null
  $d = Invoke-Driver 'f07' ((". " + (Q (Join-Path $tk 'ToolkitCore.ps1')) + "`n") + (Get-FnText $wtk @('Do-Find')) + @"

`$ErrorActionPreference = 'Continue'
`$cRed = 'Red'; `$cBlue = 'Blue'; `$script:outLines = @(); `$script:uploads = 0; `$script:cb = `$null
function Start-Hidden(`$title, `$file, `$a, `$cb, `$x) { `$script:cb = `$cb; return `$true }
function Add-Out(`$t, `$c) { `$script:outLines += [string]`$t }
function Add-OutTop(`$t, `$c) { `$script:outLines += [string]`$t }
function Fill-ResetList {}
function Invoke-AfterScan {}
function Start-ScanUpload([string]`$s) { `$script:uploads++ }
`$cr = Join-Path $(Q $f07) 'CamReset'
`$TK = @{ P = @{ CamReset = `$cr; Toolkit = (Join-Path $(Q $f07) 'Toolkit') }; site = [pscustomobject]@{ Text = 'Site B' }; rs = `$null }
`$lat = Join-Path (Join-Path `$cr 'out') 'latest.json'
function Write-Scan { @{ devices = @(@{ Brand = 'Hikvision'; Model = 'DS-2CD'; Serial = 'SITEASERIAL1'; IP = '10.0.0.21'; MAC = 'c4:2f:90:00:00:21' }) } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath `$lat }
Write-Scan; (Get-Item -LiteralPath `$lat).LastWriteTime = (Get-Date).AddHours(-3)   # Site A's scan from this morning
Do-Find; & `$script:cb 1; `$a = `$script:uploads
`$script:uploads = 0; Do-Find; & `$script:cb 0; `$b = `$script:uploads           # "finished" but wrote no new list
`$script:uploads = 0; Do-Find; Start-Sleep -Milliseconds 1100; Write-Scan; & `$script:cb 0; `$c = `$script:uploads   # a real new scan
'JSON=' + (@{ failed = `$a; stale = `$b; fresh = `$c; said = (`$script:outLines -join ' | ') } | ConvertTo-Json -Compress)
"@)
  $j = Get-Json $d
  Check ($j -and $j.failed -eq 0) 'F07 Find cameras that FAILED (exit 1) does not upload the previous site''s devices under the new site' $d
  Check ($j -and $j.stale -eq 0) 'F07 ...nor when it ended without writing a new list (the old file is not this scan)' $d
  Check ($j -and $j.fresh -eq 1) 'F07 ...a real new scan is still uploaded' $d
  Check ($j -and $j.said -match '(?i)not (used|saved|uploaded)') 'F07 ...and the tech is told the old list was not used' $d

  # =====================================================================================
  # F08: CamViews secrets are locked BEFORE they are written; a lock that fails is never reported as saved
  $f08 = Join-Path $tmp 'f08'; New-Item -ItemType Directory -Force -Path $f08 | Out-Null
  $d = Invoke-Driver 'f08' ((". " + (Q (Join-Path $tk 'CamViews.ps1')) + " -Lib`n") + @"
`$ErrorActionPreference = 'Continue'
`$script:CvHere = $(Q $f08); `$script:said = @()
function CvSay([string]`$t, [string]`$c = '') { `$script:said += `$t }
`$script:CvDpapi = { param([string]`$op, [byte[]]`$data) return `$data }
`$script:seen = @()
`$script:CvAclRun = { param([string[]]`$a) `$p = [string]`$a[0]; `$len = `$(if (Test-Path -LiteralPath `$p -PathType Leaf) { (Get-Item -LiteralPath `$p).Length } elseif (Test-Path -LiteralPath `$p) { -1 } else { -2 }); `$script:seen += `$len; return `$script:aclCode }
`$script:aclCode = 0
`$pw = ConvertTo-SecureString 'Synthetic#Nvr227' -AsPlainText -Force
`$err = ''; try { Save-CvSite '10.0.0.5' 'Site A' 'admin' 'hik' 1 `$pw } catch { `$err = `$_.Exception.Message }
`$f = Get-CvCredFile '10.0.0.5'
`$siteLen = @(`$script:seen); `$fileLen = `$(if (Test-Path -LiteralPath `$f) { (Get-Item -LiteralPath `$f).Length } else { 0 })
`$script:seen = @(); `$script:aclCode = 5; `$k1 = `$null; `$e1 = ''
try { `$k1 = Save-CvKey ('K' * 32) } catch { `$e1 = `$_.Exception.Message }
`$kf = Join-Path (Join-Path $(Q $f08) 'secrets') 'upload-key.bin'
`$keyLeftAfterFail = Test-Path -LiteralPath `$kf
`$saidSaved = [bool](@(`$script:said | Where-Object { `$_ -match '(?i)key saved' }).Count)
`$script:seen = @(); `$script:aclCode = 0; `$script:said = @(); `$k2 = `$null
try { `$k2 = Save-CvKey ('K' * 32) } catch { `$e1 += ' / ' + `$_.Exception.Message }
'JSON=' + (@{ err = `$err; siteLen = `$siteLen; fileLen = `$fileLen; k1 = `$k1; e1 = `$e1; keyLeftAfterFail = `$keyLeftAfterFail; saidSaved = `$saidSaved; k2 = `$k2; keyNow = (Test-Path -LiteralPath `$kf); keySeen = @(`$script:seen) } | ConvertTo-Json -Compress)
"@)
  $j = Get-Json $d
  Check ($j -and -not $j.err -and @($j.siteLen).Count -ge 1 -and @($j.siteLen)[0] -eq 0 -and $j.fileLen -gt 0) ('F08 a remembered NVR login file is locked while it is still EMPTY, then written (size at lock time: ' + $(if ($j) { @($j.siteLen) -join ',' } else { '?' }) + ')') $d
  Check ($j -and $j.k1 -eq $false -and -not $j.keyLeftAfterFail -and -not $j.saidSaved) 'F08 upload key: when its folder cannot be locked, the key is NOT kept and NOT reported as saved' $d
  Check ($j -and $j.k2 -eq $true -and $j.keyNow -and @($j.keySeen).Count -ge 1 -and @($j.keySeen)[0] -eq -1) ('F08 ...when the lock works the key is saved, and its folder was locked before the key went in (first lock saw: ' + $(if ($j) { @($j.keySeen) -join ',' } else { '?' }) + ')') $d
  if ($isWin) {
    $f08w = Join-Path $tmp 'f08w'; New-Item -ItemType Directory -Force -Path $f08w | Out-Null
    $d = Invoke-Driver 'f08w' ((". " + (Q (Join-Path $tk 'CamViews.ps1')) + " -Lib`n") + @"
`$ErrorActionPreference = 'Continue'; `$script:CvHere = $(Q $f08w)
function CvSay([string]`$t, [string]`$c = '') { }
`$ok = Save-CvKey ('K' * 32)
`$dir = Join-Path $(Q $f08w) 'secrets'; `$acl = (Get-Item -LiteralPath `$dir).GetAccessControl('Access')
`$sids = @(`$acl.GetAccessRules(`$true, `$true, [Security.Principal.SecurityIdentifier]) | ForEach-Object { `$_.IdentityReference.Value } | Sort-Object -Unique)
'JSON=' + (@{ ok = `$ok; prot = `$acl.AreAccessRulesProtected; sids = `$sids; users = [bool](@(`$sids | Where-Object { `$_ -in @('S-1-5-32-545', 'S-1-1-0', 'S-1-5-11') }).Count); key = (Test-Path (Join-Path `$dir 'upload-key.bin')) } | ConvertTo-Json -Compress)
"@)
    $j = Get-Json $d
    Check ($j -and $j.ok -and $j.key -and $j.prot -and -not $j.users) ('F08 Windows: the real upload-key folder inherits nothing and has no Users / Everyone entry (' + $(if ($j) { @($j.sids) -join ',' } else { '?' }) + ')') $d
  } else { Write-Host 'SKIP F08 real Windows ACL on the upload-key folder (Windows only)' }

  # =====================================================================================
  # F10 F11 F13: NvrHealth's real result logic (the recorder answers are stood in inside the module)
  $nhm = Join-Path $tk 'modules/NvrHealth/NvrHealth.psm1'
  $d = Invoke-Driver 'f10' (@"
`$ErrorActionPreference = 'Continue'
`$m = Import-Module $(Q $nhm) -Force -PassThru
Set-NvrHealthOption MockUrl 'http://127.0.0.1:9'; Set-NvrHealthOption LogDir $(Q (Join-Path $tmp 'nhlogs'))
& `$m {
  function script:Resolve-Target { param(`$Ip, `$Vendor, `$Credential, `$Port) return @{ ip = `$Ip; vendor = 'Hikvision'; cred = `$Credential; port = 0 } }
  function script:Login-Blocked(`$t) { return '' }
  function script:Hik-DeviceInfo(`$t) { return @{ login = 'ok'; model = 'DS-7608NI-K2'; serial = 'X'; firmware = 'V4.85' } }
  function script:Hik-Streams(`$t) { throw 'no streams in this test' }
  function script:Hik-Recording(`$t) {
    `$now = [DateTime]::UtcNow
    `$disk = [pscustomobject]@{ id = '1'; capMB = 3815447; freeMB = 1000; status = 'ok'; smartOk = `$true; smartAll = ''; tempC = 38; powerOnDays = 100; property = 'RW' }
    `$c1 = [pscustomobject]@{ ch = 1; ip = '10.0.0.21'; online = `$false; scheduled = `$true; recording_now = `$true; mode = 'CMR'; newest = `$now.AddMinutes(-5); oldest = `$now.AddDays(-50); days_held = 50; detect = '' }
    `$c2 = [pscustomobject]@{ ch = 2; ip = '10.0.0.22'; online = `$true; scheduled = `$false; recording_now = `$true; mode = 'CMR'; newest = `$now.AddMinutes(-5); oldest = `$now.AddDays(-50); days_held = 50; detect = '' }
    return @{ now = `$now; channels = @(`$c1, `$c2); disks = @(`$disk) }
  }
}
`$c = New-Object PSCredential('admin', (ConvertTo-SecureString 'x' -AsPlainText -Force))
`$r = Get-RecordingStatus -Ip 10.9.0.20 -Vendor Hikvision -Credential `$c -TargetDays 30 -NoLog
'JSON=' + (@{ ok = `$r.ok; rec = `$r.recording; problems = @(`$r.problems) } | ConvertTo-Json -Compress)
"@)
  $j = Get-Json $d
  Check ($j -and $j.ok -eq $false -and $j.rec -eq 0) ('F10 a camera known OFFLINE, and one with recording OFF in its schedule, are not "recording" because of a clip from 5 minutes ago (ok ' + $(if ($j) { $j.ok } else { '?' }) + ', recording ' + $(if ($j) { $j.rec } else { '?' }) + ')') $d
  $refF = Join-Path $tk 'modules/NvrHealth/firmware-latest.json'
  $d = Invoke-Driver 'f11' (@"
`$ErrorActionPreference = 'Continue'
`$m = Import-Module $(Q $nhm) -Force -PassThru
Set-NvrHealthOption MockUrl 'http://127.0.0.1:9'; Set-NvrHealthOption LogDir $(Q (Join-Path $tmp 'nhlogs'))
`$ref = Get-Content $(Q $refF) -Raw | ConvertFrom-Json
`$dwv = & `$m { param(`$r) `$mm = Find-RefModel `$r 'DW Spectrum'; `$l = @(`$mm.latest) | Where-Object { `$_ } | Sort-Object { [string]`$_.build }, { [string]`$_.version } | Select-Object -Last 1; [string]`$l.version } `$ref
`$global:dwv = `$dwv; `$global:loginOk = `$true
& `$m {
  function script:Resolve-Target { param(`$Ip, `$Vendor, `$Credential, `$Port) return @{ ip = `$Ip; vendor = 'DW'; cred = `$Credential; port = 0 } }
  function script:Dw-Info(`$t) { return @{ version = `$global:dwv; name = 'srv' } }
  function script:Dw-Login(`$t) { return `$global:loginOk }
  function script:Dw-Devices(`$t) { return @([pscustomobject]@{ id = '{1}'; ip = '10.9.1.11'; model = 'IPC328SR3'; vendor = 'Uniview'; firmware = ''; status = 'Recording'; name = 'Lobby' }) }
}
`$c = New-Object PSCredential('admin', (ConvertTo-SecureString 'x' -AsPlainText -Force))
`$a = Get-FirmwareStatus -Ip 10.9.0.40 -Vendor DW -Credential `$c -IncludeCameras -ReferenceFile $(Q $refF) -NoLog
`$global:loginOk = `$false
`$b = Get-FirmwareStatus -Ip 10.9.0.40 -Vendor DW -Credential `$c -IncludeCameras -ReferenceFile $(Q $refF) -NoLog
'JSON=' + (@{ dwv = `$dwv; aOk = `$a.ok; aNj = `$a.not_judged; bOk = `$b.ok; bNj = `$b.not_judged } | ConvertTo-Json -Compress)
"@)
  $j = Get-Json $d
  Check ($j -and $j.dwv -and $j.aOk -eq $false -and $j.aNj -ge 1) ('F11 DW: a camera whose firmware DW does not report is counted as not checked - never "firmware OK" (ok ' + $(if ($j) { $j.aOk } else { '?' }) + ', not judged ' + $(if ($j) { $j.aNj } else { '?' }) + ')') $d
  Check ($j -and $j.bOk -eq $false -and $j.bNj -ge 1) ('F11 ...and asked-for camera checks skipped because the DW login failed are counted too (ok ' + $(if ($j) { $j.bOk } else { '?' }) + ', not judged ' + $(if ($j) { $j.bNj } else { '?' }) + ')') $d
  $d = Invoke-Driver 'f13' (@"
`$ErrorActionPreference = 'Continue'
`$m = Import-Module $(Q $nhm) -Force -PassThru
Set-NvrHealthOption MockUrl 'http://127.0.0.1:9'; Set-NvrHealthOption LogDir $(Q (Join-Path $tmp 'nhlogs'))
& `$m {
  function script:Resolve-Target { param(`$Ip, `$Vendor, `$Credential, `$Port) return @{ ip = `$Ip; vendor = 'Hikvision'; cred = `$Credential; port = 0 } }
  function script:Login-Blocked(`$t) { return '' }
  function script:Get-CameraTargets(`$t, `$a, `$b, `$c) { return @(@{ ip = '10.9.0.31'; vendor = 'Hikvision'; cred = `$null; port = 0; token = `$null }) }
  function script:Clock-Of(`$t) { if (`$t.ip -eq '10.9.0.20') { Start-Sleep -Seconds 4; return `$null }; return @{ utc = [DateTime]::UtcNow; mode = 'NTP'; tz = `$null; ntp = @('time.nist.gov') } }
}
`$c = New-Object PSCredential('admin', (ConvertTo-SecureString 'x' -AsPlainText -Force))
`$r = Get-ClockStatus -Ip 10.9.0.20 -Vendor Hikvision -Credential `$c -IncludeCameras -NoLog
'JSON=' + (@{ r = (`$r | ConvertTo-Json -Depth 5 -Compress) } | ConvertTo-Json -Compress)
"@)
  $j = Get-Json $d
  $drift = $null; if ($j) { $m13 = [regex]::Match([string]$j.r, '10\.9\.0\.31[^}]*?"(drift_sec|driftSec|drift)"\s*:\s*(-?[0-9.]+)'); if ($m13.Success) { $drift = [double]$m13.Groups[2].Value } }
  Check ($null -ne $drift -and [math]::Abs($drift) -le 1.5) ('F13 a camera read after a slow (4 s) recorder is compared with the time NOW, not the time the check started (drift ' + $drift + ' s)') $d

  # =====================================================================================
  # F12: the site summary never calls old firmware "current"
  $d = Invoke-Driver 'f12' ((". " + (Q (Join-Path $tk 'ToolkitCore.ps1')) + "`n") + @"
`$ErrorActionPreference = 'Continue'
`$rec = [pscustomobject]@{ ok = `$true; recording = 4; days_held = 40; target_days = 30; channels = @(); problems = @() }
`$clk = [pscustomobject]@{ ok = `$true; problems = @() }
`$fw = [pscustomobject]@{ ok = `$true; not_judged = 0; problems = @(); devices = @([pscustomobject]@{ label = 'Recorder'; verdict = 'old'; latest = 'V4.85.040 build 260725' }) }
`$h = [pscustomobject]@{ vendor = 'Hikvision'; recording = `$rec; clock = `$clk; firmware = `$fw }
`$o = New-TkSiteCheck `$h `$null `$null 'Site A' '10.0.0.20'
`$txt = (`$o | ConvertTo-Json -Depth 8 -Compress)
'JSON=' + (@{ current = (`$txt -match 'Firmware: current'); older = (`$txt -match '(?i)older firmware') } | ConvertTo-Json -Compress)
"@)
  $j = Get-Json $d
  Check ($j -and -not $j.current -and $j.older) 'F12 a recorder on OLD firmware (no listed hole) is "older firmware" on the site summary, not "current, no known security holes"' $d

  # =====================================================================================
  # F14: the stand-alone HikReset reads this site's saved password (it loads every helper it needs)
  $f14 = Join-Path $tmp 'f14'; New-Item -ItemType Directory -Force -Path $f14 | Out-Null
  $null = Invoke-Driver 'f14a' ((". " + (Q (Join-Path $tk 'FixSiteCore.ps1')) + "; . " + (Q (Join-Path $tk 'FixSiteDevices.ps1')) + "`n") + @"
`$script:FsTestSecrets = `$true
`$s = Read-FsSecrets $(Q $f14) 'Site 14'; `$s.password = 'Sitepass#14x'; Save-FsSecrets $(Q $f14) `$s
"@)
  $hr = Join-Path $tk 'HikReset.ps1'
  $ast = [Management.Automation.Language.Parser]::ParseFile($hr, [ref]$null, [ref]$null)
  $loads = @($ast.EndBlock.Statements | ForEach-Object { $_.Extent.Text } | Where-Object { $_ -match "^\.\s*\(Join-Path \`$here '([^']+)'\)\s*$" } | ForEach-Object { [regex]::Match($_, "'([^']+)'").Groups[1].Value })
  $d = Invoke-Driver 'f14b' ((($loads | ForEach-Object { ". " + (Q (Join-Path $tk $_)) }) -join "`n") + @"

`$ErrorActionPreference = 'Continue'; `$script:FsTestSecrets = `$true
`$pw = ''; `$e = ''; try { `$pw = [string](Read-FsSecrets $(Q $f14) 'Site 14').password } catch { `$e = `$_.Exception.Message }
'JSON=' + (@{ pw = (`$pw -eq 'Sitepass#14x'); err = `$e } | ConvertTo-Json -Compress)
"@)
  $j = Get-Json $d
  Check ($j -and $j.pw) ('F14 HikReset loads what it needs (' + ($loads -join ', ') + ') and reads the site''s saved password' + $(if ($j -and $j.err) { ' - ' + $j.err } else { '' })) $d
  $hsrc = [IO.File]::ReadAllText($hr)
  Check ($hsrc -notmatch "try \{ \`$pw = \[string\]\(Read-FsSecrets \`$SiteSecretsDir \`$Site\)\.password \} catch \{\}") 'F14 ...and an error reading the password store is said as that error, not hidden as "no site password saved"'
  if ($isWin) {
    $f14w = Join-Path $tmp 'f14w'; New-Item -ItemType Directory -Force -Path $f14w, (Join-Path $f14w 'state') | Out-Null
    $null = Invoke-Driver 'f14c' ((". " + (Q (Join-Path $tk 'FixSiteCore.ps1')) + "; . " + (Q (Join-Path $tk 'FixSiteDevices.ps1')) + "`n") + "`$s = Read-FsSecrets " + (Q $f14w) + " 'Site 14'; `$s.password = 'Sitepass#14x'; Save-FsSecrets " + (Q $f14w) + " `$s")
    $cfg14 = Join-Path $f14w 'config.json'; '{"form":{"name":"Test","email":"t@example.invalid","company":"T","phone":"1","country":"United States"}}' | Set-Content $cfg14
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $o14 = & $exe -NoProfile -ExecutionPolicy Bypass -File $hr -Mode Import -Site 'Site 14' -SiteSecretsDir $f14w -StateDir (Join-Path $f14w 'state') -ConfigPath $cfg14 2>&1 | Out-String; $c14 = $LASTEXITCODE
    $ErrorActionPreference = $prev
    Check ($c14 -eq 0 -and $o14 -notmatch 'No site password saved') ('F14 Windows: the real HikReset.ps1 -Mode Import -Site finds the site password saved on this PC (exit ' + $c14 + ')') $o14
  } else { Write-Host 'SKIP F14 real HikReset run with a DPAPI password store (Windows only)' }

  # F15: the relay - see appsscript/tests/hikrelay.test.js (node)

  # =====================================================================================
  # F16: classic Fix NVR with no (or an empty) config stops before it looks at the network
  $f16 = Join-Path $tmp 'f16'; New-Item -ItemType Directory -Force -Path $f16 | Out-Null
  Copy-Item $fnv (Join-Path $f16 'FixNVR.ps1')
  $mock16 = Join-Path $f16 'mock.json'; '{"url":"http://127.0.0.1:9","pc":{"ifIndex":1,"alias":"Ethernet","desc":"t","ip":"192.168.1.105","prefix":24,"gw":"192.168.1.1","dhcp":true,"link":"1 Gbps","wifi":false},"sadp":[],"arp":[],"onvif":[]}' | Set-Content $mock16
  $cfgE = Join-Path $f16 'empty.json'; '{}' | Set-Content $cfgE
  foreach ($cp in @((Join-Path $f16 'missing.json'), $cfgE)) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $o16 = & $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $f16 'FixNVR.ps1') -Mode Check -ConfigPath $cp -MockFile $mock16 -NoLogin -SniffSeconds 0 2>&1 | Out-String; $c16 = $LASTEXITCODE
    $ErrorActionPreference = $prev
    $plans = @(Get-ChildItem -LiteralPath (Join-Path $f16 'runs') -Recurse -Filter 'before.json' -ErrorAction SilentlyContinue).Count
    Check ($c16 -ne 0 -and $o16 -match '(?i)config\.json' -and $o16 -match '(?i)nothing was (checked|changed)' -and -not $plans) ('F16 classic Fix NVR with ' + $(if ($cp -eq $cfgE) { 'an EMPTY' } else { 'NO' }) + ' config.json stops with a plain message before any discovery (exit ' + $c16 + ')') $o16
  }

  # =====================================================================================
  # F17: a 2.2.5 install sees these fixes as an update
  $f17 = Join-Path $tmp 'f17'; New-Item -ItemType Directory -Force -Path (Join-Path $f17 'Toolkit') | Out-Null
  '{"version":"2.2.5"}' | Set-Content (Join-Path $f17 'Toolkit/version.json')
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  $null = & $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'tools/Build-Manifest.ps1') -Commit ('0' * 40) -Out (Join-Path $f17 'built.json') 2>&1
  $ErrorActionPreference = $prev
  foreach ($mf in @((Join-Path $f17 'built.json'), (Join-Path $repo 'version.json'))) {
    $d = Invoke-Driver 'f17' ((". " + (Q (Join-Path $tk 'ToolkitCore.ps1')) + "`n") + @"
`$ErrorActionPreference = 'Continue'
`$built = `$script:TkBuiltVersion; `$script:TkBuiltVersion = '2.2.5'   # the code of an installed 2.2.5
function Get-TkWeb([string]`$u, [int]`$t) { return [IO.File]::ReadAllBytes($(Q $mf)) }
`$u = Get-TkUpdateInfo ([pscustomobject]@{ updateUrl = 'https://example.invalid/version.json'; updateTimeoutMs = 1000 }) $(Q (Join-Path $f17 'Toolkit'))
'JSON=' + (@{ state = [string]`$u.state; msg = [string]`$u.message; built = `$built; man = [string](Get-Content $(Q $mf) -Raw | ConvertFrom-Json).version } | ConvertTo-Json -Compress)
"@)
    $j = Get-Json $d
    Check ($j -and $j.state -eq 'available' -and $j.man -eq $j.built) ('F17 ' + $(if ($mf -like '*built.json') { 'a manifest built from this code' } else { 'the repository''s version.json' }) + ' (v' + $(if ($j) { $j.man } else { '?' }) + ', code v' + $(if ($j) { $j.built } else { '?' }) + ') is offered to an installed 2.2.5 as an update (' + $(if ($j) { $j.state + ': ' + $j.msg } else { '?' }) + ')') $d
  }

  # =====================================================================================
  # F18: a new waiting list for the same site never destroys the one already waiting (Linux: write stopped half-way)
  if ($isWin) { Write-Host 'SKIP F18 half-way write of the waiting list (needs a per-process file-size limit: Linux)' }
  else {
    $f18 = Join-Path $tmp 'f18'; $otk = Join-Path $f18 'Toolkit'; $ocr = Join-Path $f18 'CamReset'; New-Item -ItemType Directory -Force -Path $otk, (Join-Path $ocr 'out'), (Join-Path $f18 'home') | Out-Null
    foreach ($f in @('ScanUpload.ps1', 'CamViews.ps1', 'ToolkitCore.ps1', 'ToolkitRecover.ps1')) { Copy-Item (Join-Path $tk $f) (Join-Path $otk $f) }
    $mkScan = { param($n) $devs = @(for ($i = 0; $i -lt $n; $i++) { @{ Brand = 'Hikvision'; Model = 'DS-2CD2143G2-I'; Serial = ('DS-2CD2143G2-I20230101AAWRK' + ('{0:D8}' -f $i)); IP = ('10.0.' + [int][math]::Floor($i / 200) + '.' + (($i % 200) + 2)); MAC = ('c4:2f:90:00:{0:x2}:{1:x2}' -f [int][math]::Floor($i / 256), ($i % 256)) } }); @{ devices = $devs } | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $ocr 'out/latest.json') }
    $old = $env:WIREIT_UPLOAD_KEY; $oh = $env:HOME
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
      $env:WIREIT_UPLOAD_KEY = ''; $env:HOME = (Join-Path $f18 'home')
      & $mkScan 3
      $null = & $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $otk 'ScanUpload.ps1') -Site 'WI-218' -CamResetDir $ocr 2>&1
      $q = @(Get-ChildItem -LiteralPath (Join-Path $otk 'outbox') -Filter 'scan-*.json')
      $len1 = $(if ($q.Count) { $q[0].Length } else { 0 })
      & $mkScan 400
      $o18 = & $py (Join-Path $PSScriptRoot 'fix227/limit_run.py') ([string]($len1 + 3000)) $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $otk 'ScanUpload.ps1') -Site 'WI-218' -CamResetDir $ocr 2>&1 | Out-String
    } finally { $env:WIREIT_UPLOAD_KEY = $old; $env:HOME = $oh; $ErrorActionPreference = $prev }
    $q2 = @(Get-ChildItem -LiteralPath (Join-Path $otk 'outbox') -Filter 'scan-*.json')
    $valid = $false; $nDev = -1; if ($q2.Count -eq 1) { try { $v = Get-Content -LiteralPath $q2[0].FullName -Raw | ConvertFrom-Json; $nDev = @($v.devices).Count; $valid = ($nDev -gt 0) } catch {} }
    Check ($len1 -gt 0) ('F18 setup: the real uploader, offline, left one waiting list (' + $len1 + ' bytes)')
    Check ($valid -and $nDev -eq 3) ('F18 a newer list whose write stops half-way leaves the waiting list whole (' + $q2.Count + ' file(s), ' + $nDev + ' devices readable)') $o18
  }

  # =====================================================================================
  # F19: adding cameras to a saved list does not duplicate cameras that have no MAC
  $d = Invoke-Driver 'f19' ((". " + (Q (Join-Path $tk 'FixSiteCore.ps1')) + "; . " + (Q (Join-Path $tk 'FixSiteDevices.ps1')) + "`n") + @"
`$ErrorActionPreference = 'Continue'
`$old = @([pscustomobject]@{ name = 'Gate'; brand = 'Dahua'; serial = '7J0ABC123456789'; mac = ''; ip = '192.168.1.40'; nvr = '192.168.1.20'; channel = 5 })
`$new = @([pscustomobject]@{ name = 'Camera 192.168.1.40'; brand = 'Dahua'; serial = '7J0ABC123456789'; mac = ''; ip = '192.168.1.40'; nvr = '192.168.1.20'; channel = 5 },
          [pscustomobject]@{ name = 'Yard'; brand = 'Hikvision'; serial = 'DS-2CDX1'; mac = 'c4:2f:90:00:00:41'; ip = '192.168.1.41'; nvr = '192.168.1.20'; channel = 6 })
`$m = @(Merge-FsSiteListCams `$old `$new)
`$n2 = @(Merge-FsSiteListCams @([pscustomobject]@{ name = 'A'; serial = ''; mac = ''; ip = '192.168.1.50'; nvr = '192.168.1.20'; channel = 7 }) @([pscustomobject]@{ name = 'B'; serial = ''; mac = ''; ip = '192.168.1.50'; nvr = '192.168.1.20'; channel = 7 }))
`$n3 = @(Merge-FsSiteListCams @([pscustomobject]@{ name = 'A'; serial = 'SER-A-0001'; mac = ''; ip = '192.168.1.60' }) @([pscustomobject]@{ name = 'B'; serial = 'SER-B-0002'; mac = ''; ip = '192.168.1.61' }))
'JSON=' + (@{ n = `$m.Count; gate = [string](@(`$m | Where-Object { [string]`$_.serial -eq '7J0ABC123456789' })[0].name); n2 = `$n2.Count; n3 = `$n3.Count } | ConvertTo-Json -Compress)
"@)
  $j = Get-Json $d
  Check ($j -and $j.n -eq 2 -and $j.gate -eq 'Gate') ('F19 a saved camera with no MAC, found again (same serial, channel, address), is ONE row and keeps its name (' + $(if ($j) { $j.n } else { '?' }) + ' rows)') $d
  Check ($j -and $j.n2 -eq 1 -and $j.n3 -eq 2) 'F19 ...no serial either: the same NVR channel at the same address is the same camera; two different serials stay two cameras' $d

  # =====================================================================================
  # F20: the Fix this site window really checks the site name (quotes can not reach the command line)
  $d = Invoke-Driver 'f20' ((". " + (Q (Join-Path $tk 'FixSiteCore.ps1')) + "`n") + @"
`$ErrorActionPreference = 'Continue'
`$re = `$script:FsSiteRe
'JSON=' + (@{ defined = [bool]`$re; ok1 = ('WI-061' -match `$re); ok2 = ('177 Main St, New Britain (Strand) #2 & Co.' -match `$re); bad1 = ('Site" -Mode Rollback -RollbackDir "C:\x' -match `$re); bad2 = (('x' * 81) -match `$re); bad3 = ('a`$(calc)' -match `$re) } | ConvertTo-Json -Compress)
"@)
  $j = Get-Json $d
  Check ($j -and $j.defined -and $j.ok1 -and $j.ok2) 'F20 the site-name rule exists where the Fix this site window reads it, and normal site names pass' $d
  Check ($j -and -not $j.bad1 -and -not $j.bad2 -and -not $j.bad3) 'F20 ...a name with a quote (extra switches), over 80 characters, or $( ) is refused' $d
  $win = [IO.File]::ReadAllText((Join-Path $tk 'FixSiteWindow.ps1'))
  Check ($win -match '\$script:FsSiteRe' -and $win -match "\. \(Join-Path \`$ToolkitDir 'FixSiteCore\.ps1'\)") 'F20 ...the window loads FixSiteCore.ps1 (where the rule is) before it checks the name'
} catch { $script:fail++; Write-Host ('FAIL unexpected error: ' + $_.Exception.Message + ' at ' + $_.InvocationInfo.ScriptLineNumber) }
finally {
  foreach ($p in $servers) { try { $p.Kill() } catch {} }
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host ('Test-Fix227: ' + $script:pass + ' passed, ' + $script:fail + ' failed, ' + $script:defer + ' deferred (' + ($script:deferred -join ', ') + ')')
exit $script:fail
