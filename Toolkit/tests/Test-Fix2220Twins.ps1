<# Test-Fix2220Twins.ps1 - WireIt Toolkit 2.2.20 (Nov 11 2026), second-pass twin helper: the twins of Codex's 2.2.19 findings (review of
   head ca8d5b3, NO-GO) that the first-pass helpers and the lead's cross-check left open, in the classes Codex named:
   class A  a record a later step (Undo, recovery, the next run, the window) trusts is written TERMINATING and READ BACK before the change
            it protects, and "saved / cleared / done" is said only after that: FixSite scan.json / plan.json / site list / site.txt /
            summary.json / undone.txt, FixNVR plan.json + before.json, the network-recovery marker clear, the mock-mode journal removal,
            the secret-store and hikreset-folder migration, CamViews' site list, Find cameras' devices.json / latest.json, the Hik
            "waiting" list, NvrHealth -Json, SiteCheck last-scan.json (and NvrFix's restart-limit ledger, proven already safe).
   class B/C the login check the Hikvision reset stage uses ("the site password works") certifies only the device the reset record names
            (MAC, else exact serial); a record with neither, an unreadable MAC or another device at the address = NOT verified.
   class C  SiteCheck: a device no ping could even be sent to is NOT CHECKED (never 100% loss, never "nothing answers", never "gone").
   class D  FixSite uses the Find cameras result only when it carries the run id this run gave the finder (-RunId), read ONCE.
   class E  the Hik reset record's device rows are TYPE-checked before any reset step; a bad row is quarantined (kept, evidence copy,
            nothing done to that device).
   Every check RUNS the real production functions (dot-sourced, or loaded from the file's own function definitions) in a child
   PowerShell; only Windows commands, devices and chosen file failures are stand-ins. "control" = passes on old and new code;
   "(already safe)" = a place checked and found safe in 2.2.19 too; "(code shape)" = reads the source text only.
   FIX2220TWINS_REPO = another checkout (2.2.19 ca8d5b3) to prove every finding check fails there. Windows PowerShell 5.1 or pwsh 7. #>
$ErrorActionPreference = 'Stop'
$tk = Split-Path -Parent $PSScriptRoot; $repo = Split-Path -Parent $tk
if ($env:FIX2220TWINS_REPO) { $repo = $env:FIX2220TWINS_REPO; $tk = Join-Path $repo 'Toolkit' }
$exe = $(if ($PSVersionTable.PSEdition -eq 'Core') { (Get-Process -Id $PID).Path } else { Join-Path $PSHOME 'powershell.exe' })
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fix2220twins-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$script:pass = 0; $script:fail = 0; $script:deferred = 0
function Check([bool]$ok, [string]$name, $more = '') {
  if ($ok) { $script:pass++; Write-Host ('PASS ' + $name) } else { $script:fail++; Write-Host ('FAIL ' + $name); if ($more) { $m = $(if ($more -is [string]) { $more } else { ConvertTo-Json -Compress -Depth 6 -InputObject $more }); if ($m.Length -gt 900) { $m = $m.Substring(0, 900) }; Write-Host ('     ' + $m) } }
}
function Deferred([string]$name) { $script:deferred++; Write-Host ('DEFERRED ' + $name) }
function Q([string]$s) { return "'" + $s.Replace("'", "''") + "'" }
function Invoke-Driver([string]$name, [string]$code) {
  $f = Join-Path $tmp ($name + '.ps1'); [IO.File]::WriteAllText($f, $code, (New-Object Text.UTF8Encoding($true)))
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $o = & $exe -NoProfile -ExecutionPolicy Bypass -File $f 2>&1 | Out-String } finally { $ErrorActionPreference = $prev }
  return $o
}
function Get-Json([string]$out) { $m = [regex]::Match($out, '(?m)^JSON=(\{.*\})\s*$'); if ($m.Success) { try { return ($m.Groups[1].Value | ConvertFrom-Json) } catch {} }; return $null }
function P($o, [string]$k) { if ($o -and $o.PSObject.Properties[$k]) { return $o.$k }; return $null }
function Read-Src([string]$rel) { return [IO.File]::ReadAllText((Join-Path $repo ($rel -replace '/', [string][IO.Path]::DirectorySeparatorChar))) }

$head = @'
$ErrorActionPreference = 'Continue'
$R = [ordered]@{}
function Run([string]$name, [scriptblock]$sb) { try { $R[$name] = (& $sb) } catch { $R[$name] = [ordered]@{ error = ($_.Exception.Message + ' @' + $_.InvocationInfo.ScriptLineNumber) } } }
# loads ONLY the function definitions of a script (no top-level code runs), like Codex's reproduce*.ps1
function Import-Fns([string]$file) { $ast = [Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$null); foreach ($f in $ast.FindAll({ param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) { . ([scriptblock]::Create($f.Extent.Text.Replace('function ' + $f.Name, 'function global:' + $f.Name))) } }
function Move-Denied { [CmdletBinding()]param($LiteralPath, $Path, $Destination, [switch]$Force, $WhatIf, $Confirm) Write-Error ('move denied (test stand-in): ' + $LiteralPath) }
'@
$tail = "`n" + '"JSON=" + (ConvertTo-Json -Compress -Depth 8 -InputObject ([pscustomobject]$R))' + "`n"
$W = Q $tmp
foreach ($f in @('Toolkit/HikResetFlow.ps1', 'Toolkit/FixSite.ps1', 'Toolkit/FixSiteCore.ps1', 'Toolkit/FixSiteDevices.ps1', 'FixNVR/FixNVR.ps1', 'Toolkit/CamViews.ps1', 'CamReset/Find-Cameras.ps1', 'CamReset/Make-Request.ps1', 'sitecheck/SiteCheck.ps1', 'Toolkit/modules/NvrHealth/NvrHealth.psm1', 'Toolkit/modules/NvrHealth/NvrFix.ps1')) {
  $e = $null; [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $repo $f), [ref]$null, [ref]$e); Check ($e.Count -eq 0) ('control: parses: ' + $f) ($e | Out-String)
}
$scBytes = [IO.File]::ReadAllBytes((Join-Path $repo 'sitecheck/SiteCheck.ps1')); $cmdBytes = [IO.File]::ReadAllBytes((Join-Path $repo 'sitecheck/WireIt-SiteCheck.cmd'))
$scTxt = [Text.Encoding]::UTF8.GetString($scBytes); $cmdTxt = [Text.Encoding]::UTF8.GetString($cmdBytes)
Check ($cmdTxt.EndsWith($scTxt) -or $cmdTxt.Contains($scTxt)) 'control: WireIt-SiteCheck.cmd carries SiteCheck.ps1 byte for byte (code shape)'

# ======================= class E: the Hik reset record's device rows are type-checked =======================
Write-Host ''; Write-Host 'class E (HikResetFlow.ps1 Read-HikState): every device row is type-checked; a bad row is quarantined, kept, and nothing is done to that device'
$hs = $head + "`n" + '. ' + (Q (Join-Path $tk 'HikResetFlow.ps1')) + "`n" + '$D = ' + $W + "`n" + @'
$script:said = New-Object System.Collections.Generic.List[string]
$script:HkSay = { param($t, $c) [void]$script:said.Add([string]$t) }
$script:HkSubnetCheckOff = $true
function Start-Sleep { param([int]$Seconds, [int]$Milliseconds) }
function Good([string]$sn, [string]$mac) { [ordered]@{ serial = $sn; shortSerial = $sn.Substring($sn.Length - 9); model = 'DS-2CD2143G0-I'; mac = $mac; ip = '10.0.0.21'; kind = 'camera'; status = 'submitted'; requestFile = ''; bootTime = '2026-11-10 08:00:00'; note = ''; exportedAt = '2026-11-11T08:00:00'; validUntil = '2026-11-13T08:00:00'; exportStartedAt = '2026-11-11T07:59:00'; rebootRetries = 0; refusedChecksOk = $false; replySha = ('ab' * 32) } }
$GS = 'DS-2CD2143G0-I20200101AAWRD11111111'; $BS = 'DS-2CD2143G0-I20200101AAWRD22222222'
function Case([string]$name, [scriptblock]$mut) {
  $dir = Join-Path $D ('hs-' + $name); New-Item -ItemType Directory -Force -Path $dir | Out-Null; $sp = Join-Path $dir 'state.json'
  $g = Good $GS 'c4-2f-90-00-00-11'; $b = Good $BS 'c4-2f-90-00-00-22'; & $mut $b
  $raw = ConvertTo-Json -Depth 6 -InputObject ([ordered]@{ version = 1; site = 'T'; created = '2026-11-11T08:00:00'; devices = @($g, $b); exports = @() })
  [IO.File]::WriteAllText($sp, $raw)
  $s = $null; $err = ''; try { $s = Read-HikState $sp } catch { $err = $_.Exception.Message }
  $inDev = @(@($(if ($s) { $s.devices } else { @() })) | ForEach-Object { [string]$_.serial })
  $q = @(); if ($s -and $s.PSObject.Properties['quarantined']) { $q = @(@($s.quarantined) | ForEach-Object { [string]$_.serial }) }
  $blocked = ''; try { $blocked = [string](Test-HikQuarantined $s ([pscustomobject]@{ serial = $BS; mac = 'c4-2f-90-00-00-22' })) } catch { $blocked = '' }
  $goodBlocked = ''; try { $goodBlocked = [string](Test-HikQuarantined $s ([pscustomobject]@{ serial = $GS; mac = 'c4-2f-90-00-00-11' })) } catch { $goodBlocked = 'x' }
  $ev = @(Get-ChildItem -LiteralPath $dir -Filter 'state.json.quarantined-*' -ErrorAction SilentlyContinue).Count
  [ordered]@{ err = $err; good = ($inDev -contains $GS); badInDevices = ($inDev -contains $BS); quarantined = ($q.Count -eq 1); blocked = [bool]$blocked; goodBlocked = [bool]$goodBlocked; evidence = $ev; fileSame = ([IO.File]::ReadAllText($sp) -ceq $raw); said = (@($script:said | Where-Object { $_ -match 'QUARANTINED' }).Count) }
}
Run 'retriesString' { Case 'retriesString' { param($b) $b.rebootRetries = '2' } }
Run 'retriesNeg' { Case 'retriesNeg' { param($b) $b.rebootRetries = -1 } }
Run 'refusedString' { Case 'refusedString' { param($b) $b.refusedChecksOk = 'false' } }
Run 'statusUnknown' { Case 'statusUnknown' { param($b) $b.status = 'done' } }
Run 'statusNumber' { Case 'statusNumber' { param($b) $b.status = 3 } }
Run 'startedNotTime' { Case 'startedNotTime' { param($b) $b.exportStartedAt = 'yesterday-ish' } }
Run 'validNotTime' { Case 'validNotTime' { param($b) $b.validUntil = 'soon' } }
Run 'shaNotHex' { Case 'shaNotHex' { param($b) $b.replySha = 'not-a-sha' } }
Run 'serialNumber' { Case 'serialNumber' { param($b) $b.serial = 12345 } }
Run 'macNotMac' { Case 'macNotMac' { param($b) $b.mac = 'zz-zz' } }
Run 'retryBootNumber' { Case 'retryBootNumber' { param($b) $b.retryBootTime = 7 } }
Run 'allGood' { Case 'allGood' { param($b) } }
# behaviour: a damaged row (its validUntil is not a time) is not exported: 2.2.19's [datetime] cast failed inside the "still good" test
# under 'Continue' and the flow went on to ask the device for a NEW request file (voiding the one already sent to Hikvision)
Run 'exportDamaged' {
  $dir = Join-Path $D 'hs-export'; New-Item -ItemType Directory -Force -Path $dir | Out-Null; $sp = Join-Path $dir 'state.json'
  $b = Good $BS 'c4-2f-90-00-00-22'; $b.status = 'exported'; $b.validUntil = 'not-a-time'; $rf = Join-Path $dir 'req.xml'; [IO.File]::WriteAllText($rf, ('CODE' + $BS)); $b.requestFile = $rf
  [IO.File]::WriteAllText($sp, (ConvertTo-Json -Depth 6 -InputObject ([ordered]@{ version = 1; devices = @($b); exports = @() })))
  $script:exports = 0
  function Request-HikResetExport { param($dev) $script:exports++; [pscustomobject]@{ ok = $false; error = 'stand-in: no answer' } }
  $s = $null; try { $s = Read-HikState $sp } catch {}
  $dev = [pscustomobject]@{ serial = $BS; mac = 'c4-2f-90-00-00-22'; model = 'DS-2CD2143G0-I'; ip = '10.0.0.21'; shortSerial = 'D22222222'; kind = 'camera'; activated = $true; bootTime = '2026-11-10 08:00:00'; prefix = 24 }
  if ($s) { try { [void](Export-HikRequests @($dev) (Join-Path $dir 'requests') $s $sp) } catch {} }
  [ordered]@{ exports = $script:exports }
}
# the quarantine is durable: saved with the record and still blocking on the next read
Run 'durable' {
  $dir = Join-Path $D 'hs-durable'; New-Item -ItemType Directory -Force -Path $dir | Out-Null; $sp = Join-Path $dir 'state.json'
  $b = Good $BS 'c4-2f-90-00-00-22'; $b.rebootRetries = 'two'
  [IO.File]::WriteAllText($sp, (ConvertTo-Json -Depth 6 -InputObject ([ordered]@{ version = 1; devices = @($b); exports = @() })))
  $s = Read-HikState $sp; Save-HikState $sp $s; $s2 = Read-HikState $sp
  $bl = ''; try { $bl = [string](Test-HikQuarantined $s2 ([pscustomobject]@{ serial = $BS; mac = '' })) } catch {}
  [ordered]@{ saved = [bool]$script:HkStateSaved; stillBlocked = [bool]$bl; kept = (([IO.File]::ReadAllText($sp)) -match 'quarantined' -and ([IO.File]::ReadAllText($sp)) -match '"two"') }
}
# the reset stage: a target whose record row is quarantined is pending with the reason and never exported
Run 'stage' {
  $dir = Join-Path $D 'hs-stage'; New-Item -ItemType Directory -Force -Path $dir | Out-Null; $sp = Join-Path $dir 'state.json'
  $b = Good $BS 'c4-2f-90-00-00-22'; $b.refusedChecksOk = 'yes'
  [IO.File]::WriteAllText($sp, (ConvertTo-Json -Depth 6 -InputObject ([ordered]@{ version = 1; devices = @($b); exports = @() })))
  $script:exports = 0
  function Request-HikResetExport { param($dev) $script:exports++; [pscustomobject]@{ ok = $false; error = 'stand-in' } }
  function Find-HikSadp { param($n) @([pscustomobject]@{ serial = $BS; mac = 'c4-2f-90-00-00-22'; model = 'DS-2CD2143G0-I'; ip = '10.0.0.21'; shortSerial = 'D22222222'; kind = 'camera'; activated = $true; bootTime = 'B'; prefix = 24 }) }
  $hs = $null; try { $hs = Invoke-HikResetStage -Targets @([pscustomobject]@{ mac = 'c4:2f:90:00:00:22'; ip = '10.0.0.21' }) -SitePassword 'x' -StateDir $dir -Config ([pscustomobject]@{ replyDir = ''; form = $null; waitMinutes = 0 }) -VerifyLogin { param($i, $p, $d) $false } -WaitMinutes 0 } catch {}
  $why = @(@($(if ($hs) { $hs.pending } else { @() })) | ForEach-Object { [string]$_.reason }) -join ' | '
  [ordered]@{ exports = $script:exports; why = $why }
}
# class A/C twin: the "I got Hik's email" waiting list - an existing list that cannot be read is NOT empty (other sites' devices kept)
Run 'waitingUnreadable' {
  $dir = Join-Path $D 'hs-wait'; New-Item -ItemType Directory -Force -Path $dir | Out-Null; $f = Join-Path $dir 'waiting.json'; [IO.File]::WriteAllText($f, '{ broken json')
  $st = [pscustomobject]@{ devices = @([pscustomobject]@{ serial = $BS; shortSerial = 'D22222222'; model = 'M'; ip = '10.0.0.21'; status = 'submitted'; submittedAt = '2026-11-11T08:00:00' }) }
  try { [void](Save-HikWaitingList $dir $st 'Site B' '') } catch {}
  [ordered]@{ kept = ([IO.File]::ReadAllText($f) -ceq '{ broken json') }
}
Run 'waitingControl' {
  $dir = Join-Path $D 'hs-wait2'; New-Item -ItemType Directory -Force -Path $dir | Out-Null; $f = Join-Path $dir 'waiting.json'
  [IO.File]::WriteAllText($f, '{"devices":[{"serial":"OTHER","site":"Site A"}]}')
  $st = [pscustomobject]@{ devices = @([pscustomobject]@{ serial = $BS; shortSerial = 'D22222222'; model = 'M'; ip = '10.0.0.21'; status = 'submitted'; submittedAt = '2026-11-11T08:00:00' }) }
  try { [void](Save-HikWaitingList $dir $st 'Site B' '') } catch {}
  $o = [IO.File]::ReadAllText($f) | ConvertFrom-Json
  [ordered]@{ serials = (@($o.devices) | ForEach-Object { [string]$_.serial }) -join ',' }
}
Run 'waitingMoveDenied' {
  $dir = Join-Path $D 'hs-wait3'; New-Item -ItemType Directory -Force -Path $dir | Out-Null; $f = Join-Path $dir 'waiting.json'
  $st = [pscustomobject]@{ devices = @([pscustomobject]@{ serial = $BS; shortSerial = 'D22222222'; model = 'M'; ip = '10.0.0.21'; status = 'submitted'; submittedAt = '2026-11-11T08:00:00' }) }
  function Move-Item { [CmdletBinding()]param($LiteralPath, $Destination, [switch]$Force) Write-Error 'move denied (test stand-in)' }
  function Set-Content { [CmdletBinding()]param($LiteralPath, $Value, $Encoding) Write-Error 'write denied (test stand-in)' }
  $r = $null; try { $r = Save-HikWaitingList $dir $st 'Site B' '' } catch {}
  Remove-Item function:Move-Item; Remove-Item function:Set-Content
  [ordered]@{ returned = $r; said = (@($script:said | Where-Object { $_ -match 'waiting list' -and $_ -match 'could not be saved' }).Count) }
}
'@ + $tail
$o = Invoke-Driver 'hikstate' $hs; $j = Get-Json $o
if (-not $j) { Check $false 'class E driver ran' $o }
$cases = [ordered]@{ retriesString = 'rebootRetries "2" (a string)'; retriesNeg = 'rebootRetries -1'; refusedString = 'refusedChecksOk "false" (a string)'; statusUnknown = 'status "done" (not one this tool writes)'; statusNumber = 'status 3 (a number)'; startedNotTime = 'exportStartedAt not a time'; validNotTime = 'validUntil not a time'; shaNotHex = 'replySha not a SHA-256'; serialNumber = 'serial 12345 (a number)'; macNotMac = 'mac "zz-zz"'; retryBootNumber = 'retryBootTime 7 (a number)' }
foreach ($k in $cases.Keys) {
  $c = P $j $k
  Check ($c -and -not (P $c 'err') -and (P $c 'good') -and -not (P $c 'badInDevices') -and (P $c 'quarantined') -and (P $c 'blocked') -and -not (P $c 'goodBlocked') -and [int](P $c 'evidence') -ge 1 -and (P $c 'fileSame') -and [int](P $c 'said') -ge 1) ('class E: a reset-record row with ' + $cases[$k] + ' is quarantined (kept, evidence copy, said), the good row is used, only that device is blocked') $c
}
$c = P $j 'allGood'; Check ($c -and -not (P $c 'err') -and (P $c 'good') -and (P $c 'badInDevices') -and -not (P $c 'blocked') -and [int](P $c 'evidence') -eq 0) 'control: a record whose rows all have the right types is used as it is (nothing quarantined)' $c
$c = P $j 'exportDamaged'; Check ($c -and [int](P $c 'exports') -eq 0) 'control: a device whose row is damaged (validUntil not a time) is NOT asked for a new request file (2.2.19 did not either: its cast error stopped that device)' $c
$c = P $j 'durable'; Check ($c -and (P $c 'saved') -and (P $c 'stillBlocked') -and (P $c 'kept')) 'class E: the quarantine is saved with the record and still blocks that device on the next read (the bad row is kept as it was)' $c
$c = P $j 'stage'; Check ($c -and [int](P $c 'exports') -eq 0 -and [string](P $c 'why') -match 'QUARANTINED') 'class E: the reset stage (FixSite) leaves a quarantined device pending with the reason and sends it nothing' $c
$c = P $j 'waitingUnreadable'; Check ($c -and (P $c 'kept')) 'class A/C: an unreadable "I got Hik''s email" waiting list is left as it is, not overwritten as empty (2.2.19 dropped other sites'' devices)' $c
$c = P $j 'waitingControl'; Check ($c -and [string](P $c 'serials') -match 'OTHER' -and [string](P $c 'serials') -match '22222222') 'control: a readable waiting list keeps the other sites'' devices and adds this site''s' $c
$c = P $j 'waitingMoveDenied'; Check ($c -and (P $c 'returned') -eq $false -and [int](P $c 'said') -ge 1) 'class A: a waiting list whose write is refused (non-terminating) is said as NOT saved' $c

# ======================= FixSite / FixSiteDevices / FixSiteCore =======================
Write-Host ''; Write-Host 'class B/C (FixSite.ps1 reset-stage login check): "the site password works" only on the device the reset record names'
$fsLoad = $head + "`n" + '. ' + (Q (Join-Path $tk 'FixSiteCore.ps1')) + "`n" + '. ' + (Q (Join-Path $tk 'FixSiteDevices.ps1')) + "`n" + 'function Fs-LogLine([string]$s) { }' + "`n" + '$D = ' + $W + "`n" + '$FixSiteSrc = [IO.File]::ReadAllText(' + (Q (Join-Path $tk 'FixSite.ps1')) + ')' + "`n" + '$FixSitePath = ' + (Q (Join-Path $tk 'FixSite.ps1')) + "`n"
$g2 = $fsLoad + @'
$m = [regex]::Match($FixSiteSrc, '(?m)^\s*\$verify = (\{.*\})\s*$')
$verify = $null; if ($m.Success) { $verify = & ([scriptblock]::Create($m.Groups[1].Value)) }   # the scriptblock literal FixSite passes to the reset stage
$script:id = $null
function Test-FsLogin { param($ip, $brand, $pw) 'ok' }   # stand-in: the site password logs in at that address (authenticated document)
function Get-FsIdentity { param($ip, $brand, $cred) $script:id }
function V($idMac, $idSerial, $rec) { $script:id = [pscustomobject]@{ mac = (ConvertTo-FsMac $idMac); serial = $idSerial }; $o = @(& $verify '10.0.0.21' 'Site-pw-1' $rec); return ($o.Count -eq 1 -and $o[0] -is [bool] -and $o[0]) }
$rec = [pscustomobject]@{ serial = 'DS-2CD2143G0-I20200101AAWRD22222222'; mac = 'c4-2f-90-00-00-22'; model = 'DS-2CD2143G0-I' }
Run 'other' { [ordered]@{ ok = (V 'c4:2f:90:00:00:99' 'OTHERSERIAL' $rec) } }
Run 'same' { [ordered]@{ ok = (V 'c4:2f:90:00:00:22' 'DS-2CD2143G0-I20200101AAWRD22222222' $rec) } }
Run 'macUnread' { [ordered]@{ ok = (V '' 'DS-2CD2143G0-I20200101AAWRD22222222' $rec) } }
Run 'noRecord' { [ordered]@{ ok = (V 'c4:2f:90:00:00:22' 'X' $null) } }
Run 'noIdentity' { [ordered]@{ ok = (V 'c4:2f:90:00:00:22' 'X' ([pscustomobject]@{ serial = ''; mac = ''; model = 'M' })) } }
Run 'serialOnlyOther' { [ordered]@{ ok = (V 'c4:2f:90:00:00:99' 'OTHERSERIAL' ([pscustomobject]@{ serial = 'DS-2CD2143G0-I20200101AAWRD22222222'; mac = '' })) } }
Run 'serialOnlySame' { [ordered]@{ ok = (V 'c4:2f:90:00:00:99' 'DS-2CD2143G0-I20200101AAWRD22222222' ([pscustomobject]@{ serial = 'DS-2CD2143G0-I20200101AAWRD22222222'; mac = '' })) } }

# ---- class A: FixSiteDevices ----
function Test-FsNetRecoveryVerified { param($created) '' }   # stand-in: the PC restarted since and no temporary address is on it
Run 'markerDenied' {
  $dir = Join-Path $D 'mk1'; New-Item -ItemType Directory -Force -Path $dir | Out-Null; $sf = Join-Path $dir 'fixsite-temp-ips.json'
  $mk = Get-FsNetMarkerPath $sf; [IO.File]::WriteAllText($mk, '{"createdUtcTicks":1,"kept":"x"}')
  function Move-Item { [CmdletBinding()]param($LiteralPath, $Destination, [switch]$Force) Write-Error 'move denied (test stand-in)' }
  $w = Test-FsNetRecoveryMarker $sf
  Remove-Item function:Move-Item
  [ordered]@{ why = [string]$w; markerThere = (Test-Path -LiteralPath $mk) }
}
Run 'markerOk' {
  $dir = Join-Path $D 'mk2'; New-Item -ItemType Directory -Force -Path $dir | Out-Null; $sf = Join-Path $dir 'fixsite-temp-ips.json'
  $mk = Get-FsNetMarkerPath $sf; [IO.File]::WriteAllText($mk, '{"createdUtcTicks":1,"kept":"x"}')
  $w = Test-FsNetRecoveryMarker $sf
  [ordered]@{ why = [string]$w; markerThere = (Test-Path -LiteralPath $mk) }
}
Run 'mockRemoveDenied' {
  $dir = Join-Path $D 'mj'; New-Item -ItemType Directory -Force -Path $dir | Out-Null; $sf = Join-Path $dir 'fixsite-temp-ips.json'; [IO.File]::WriteAllText($sf, '{"version":2}')
  $script:FsMockUrl = 'http://127.0.0.1:9'; $script:FsNetOps = $null
  function Fs-Http { param($Ip, $Path) [pscustomobject]@{ code = 200; body = 'ok' } }
  [void]$script:FsTemps.Add([pscustomobject]@{ p3 = '192.168.99'; ip = '192.168.99.253' })
  function Remove-Item { [CmdletBinding()]param($LiteralPath, $Path, [switch]$Force) Write-Error 'remove denied (test stand-in)' }
  $r = Remove-FsTempIps $sf
  Remove-Item function:Remove-Item
  $script:FsMockUrl = ''
  [ordered]@{ ok = [bool]$r.ok; there = (Test-Path -LiteralPath $sf); problems = (@($r.problems) -join ' | ') }
}
Run 'hikDirMoveDenied' {
  $from = Join-Path $D 'mig-from'; $to = Join-Path $D 'mig-to'; New-Item -ItemType Directory -Force -Path (Join-Path $from 'hikreset-site-a') | Out-Null; [IO.File]::WriteAllText((Join-Path (Join-Path $from 'hikreset-site-a') 'state.json'), '{"devices":[]}')
  $script:FsTestSecrets = $true
  function Move-Item { [CmdletBinding()]param($LiteralPath, $Destination, [switch]$Force) Write-Error 'move denied (test stand-in)' }
  $r = Convert-FsSecretStores $from $to
  Remove-Item function:Move-Item
  [ordered]@{ moved = [int]$r.moved; stillThere = (Test-Path -LiteralPath (Join-Path $from 'hikreset-site-a')) }
}
Run 'hikDirMoveOk' {
  $from = Join-Path $D 'mig2-from'; $to = Join-Path $D 'mig2-to'; New-Item -ItemType Directory -Force -Path (Join-Path $from 'hikreset-site-a') | Out-Null; [IO.File]::WriteAllText((Join-Path (Join-Path $from 'hikreset-site-a') 'state.json'), '{"devices":[]}')
  $script:FsTestSecrets = $true
  $r = Convert-FsSecretStores $from $to
  [ordered]@{ moved = [int]$r.moved; arrived = (Test-Path -LiteralPath (Join-Path (Join-Path $to 'hikreset-site-a') 'state.json')) }
}
# ---- class A: FixSite.ps1's own record writers (loaded from FixSite.ps1's function definitions) ----
$fsAst = [Management.Automation.Language.Parser]::ParseFile($FixSitePath, [ref]$null, [ref]$null)
foreach ($n in @('Save-FsSiteListFiles', 'Save-FsRunText')) { $f = $fsAst.Find({ param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $n }, $true); if ($f) { . ([scriptblock]::Create($f.Extent.Text)) } }
function Fs-Log([string]$s) { }
Run 'listLocalRefused' {
  $sd = Join-Path $D 'sites'; New-Item -ItemType Directory -Force -Path $sd | Out-Null
  $local = Join-Path $sd 'Site A.json'; New-Item -ItemType Directory -Force -Path $local | Out-Null   # the list's place is taken: the write cannot land
  $drive = Join-Path (Join-Path $D 'drive') 'Docs\WireIt site list.json'
  $r = Save-FsSiteListFiles '{"cameras":[]}' $local $drive
  [ordered]@{ local = $r.local; drive = $r.drive; why = [string]$r.why }
}
Run 'listOk' {
  $sd = Join-Path $D 'sites2'; $local = Join-Path $sd 'Site B.json'
  $r = Save-FsSiteListFiles '{"cameras":[1]}' $local ''
  $back = ''; try { $back = [IO.File]::ReadAllText($local).TrimStart([char]0xFEFF) } catch {}
  [ordered]@{ local = $r.local; drive = $r.drive; back = $back }
}
Run 'runTextRefused' {
  $p = Join-Path $D 'run1'; New-Item -ItemType Directory -Force -Path (Join-Path $p 'plan.json') | Out-Null
  [ordered]@{ ok = (Save-FsRunText (Join-Path $p 'plan.json') '{"a":1}') }
}
# ---- class D: the Find cameras result must carry THIS run's id (FixSiteCore Read-FsScanForRun) ----
function LJ([string]$n, [string]$text) { $p = Join-Path (Join-Path $D ('lj-' + $n)) 'latest.json'; New-Item -ItemType Directory -Force -Path (Split-Path -Parent $p) | Out-Null; if ($null -ne $text) { [IO.File]::WriteAllText($p, $text) }; return $p }
Run 'scanOld' { $r = Read-FsScanForRun (LJ 'old' '{"scannedAt":"2026-11-11T08:00:00","devices":[{"IP":"10.0.0.21"}]}') 0 'run-1'; [ordered]@{ ok = $r.ok; why = $r.why } }
Run 'scanOther' { $r = Read-FsScanForRun (LJ 'other' '{"runId":"run-0","devices":[{"IP":"10.0.0.21"}]}') 0 'run-1'; [ordered]@{ ok = $r.ok; why = $r.why } }
Run 'scanMine' { $r = Read-FsScanForRun (LJ 'mine' '{"runId":"run-1","devices":[{"IP":"10.0.0.21","Brand":"Hikvision"}]}') 0 'run-1'; [ordered]@{ ok = $r.ok; n = @($r.scan.devices).Count } }
Run 'scanMineFailed' { $r = Read-FsScanForRun (LJ 'minefail' '{"runId":"run-1","devices":[]}') 5 'run-1'; [ordered]@{ ok = $r.ok; why = $r.why } }
Run 'scanGarbled' { $r = Read-FsScanForRun (LJ 'garbled' '{"runId":"run-1","devi') 0 'run-1'; [ordered]@{ ok = $r.ok; why = $r.why } }
'@ + $tail
$o = Invoke-Driver 'fixsite' $g2; $j = Get-Json $o
if (-not $j) { Check $false 'FixSite driver ran' $o }
$v = { param($k) $c = P $j $k; if ($c -and -not (P $c 'error')) { return [bool](P $c 'ok') }; return $null }
Check ((& $v 'other') -eq $false) 'class B/C: ANOTHER device at the reset camera''s address that takes the site password is NOT "verified" (2.2.19''s checker ignored the record and said it was)' (P $j 'other')
Check ((& $v 'macUnread') -eq $false) 'class B/C: a device that does not tell its MAC is NOT "verified" when the record has one (missing current value = mismatch)' (P $j 'macUnread')
Check ((& $v 'noRecord') -eq $false) 'class B/C: no reset-record row given = NOT "verified"' (P $j 'noRecord')
Check ((& $v 'noIdentity') -eq $false) 'class B/C: a reset-record row with neither MAC nor serial = NOT "verified"' (P $j 'noIdentity')
Check ((& $v 'serialOnlyOther') -eq $false) 'class B/C: a serial-only record and a device with another serial = NOT "verified"' (P $j 'serialOnlyOther')
Check ((& $v 'same') -eq $true) 'control: the device the record names (same MAC) with the site password = verified' (P $j 'same')
Check ((& $v 'serialOnlySame') -eq $true) 'control: a serial-only record and the same serial = verified' (P $j 'serialOnlySame')
Write-Host ''; Write-Host 'class A (FixSiteDevices.ps1 / FixSite.ps1): "cleared / saved / back to normal" only after the record is verified in place or gone'
$c = P $j 'markerDenied'; Check ($c -and [string](P $c 'why') -match 'could not be marked as cleared' -and (P $c 'markerThere')) 'class A: a network-recovery reminder whose move is refused is NOT "sorted out" - the block stays, with the reason (2.2.19 cleared it inside catch {})' $c
$c = P $j 'markerOk'; Check ($c -and -not [string](P $c 'why') -and -not (P $c 'markerThere')) 'control: a verified recovery with a movable reminder is cleared' $c
$c = P $j 'mockRemoveDenied'; Check ($c -and (P $c 'ok') -eq $false -and (P $c 'there') -and [string](P $c 'problems') -match 'could not be removed') 'class A (R19 class): the finished network record that cannot be removed is NOT "back to normal" (2.2.19: Remove-Item SilentlyContinue, said OK)' $c
$c = P $j 'hikDirMoveDenied'; Check ($c -and [int](P $c 'moved') -eq 0 -and (P $c 'stillThere')) 'class A: a reset-record folder whose move to vault\ is refused is not counted as moved (2.2.19 counted it)' $c
$c = P $j 'hikDirMoveOk'; Check ($c -and [int](P $c 'moved') -eq 1 -and (P $c 'arrived')) 'control: a reset-record folder that moves is counted and is at the new place' $c
$c = P $j 'listLocalRefused'; Check ($c -and (P $c 'local') -eq $false -and (P $c 'drive') -eq $true -and [string](P $c 'why')) 'class A: a site list that cannot be written on this PC is NOT "saved" (2.2.19 said "Saved this site" after a refused Set-Content)' $c
$c = P $j 'listOk'; Check ($c -and (P $c 'local') -eq $true -and $null -eq (P $c 'drive') -and [string](P $c 'back') -eq '{"cameras":[1]}') 'class A: a writable site list is saved by the new checked writer and reads back' $c
$c = P $j 'runTextRefused'; Check ($c -and -not (P $c 'error') -and (P $c 'ok') -eq $false) 'class A: a run record (plan.json / scan.json / site.txt / summary.json) whose write cannot land reports NOT saved' $c
Write-Host ''; Write-Host 'class D (FixSite.ps1 / FixSiteCore.ps1 Read-FsScanForRun): only the Find cameras result carrying THIS run''s id is used'
$c = P $j 'scanOld'; Check ($c -and (P $c 'ok') -eq $false -and -not (P $c 'error')) 'class D: an older latest.json with no run id (another site''s scan) is NOT used, even when it is fresh by time' $c
$c = P $j 'scanOther'; Check ($c -and (P $c 'ok') -eq $false -and -not (P $c 'error')) 'class D: a latest.json from another run (other run id) is NOT used' $c
$c = P $j 'scanMineFailed'; Check ($c -and (P $c 'ok') -eq $false -and -not (P $c 'error')) 'class D: this run''s id but the finder ended with an error code = NOT used' $c
$c = P $j 'scanGarbled'; Check ($c -and (P $c 'ok') -eq $false -and -not (P $c 'error')) 'class D: a half-written latest.json = NOT used' $c
$c = P $j 'scanMine'; Check ($c -and (P $c 'ok') -eq $true -and [int](P $c 'n') -eq 1) 'class D: the result carrying this run''s id IS used (read once, its devices handed over)' $c
$fsSrc = Read-Src 'Toolkit/FixSite.ps1'
Check ($fsSrc -match '-RunId \$fcRun' -and $fsSrc -match 'Read-FsScanForRun \$lj \$fcExit \$fcRun' -and $fsSrc -match '\$scanOk = \$ljAside -and \$fcRead\.ok' -and $fsSrc -notmatch 'Get-TkScanDevices \$camResetDir' -and $fsSrc -notmatch "Get-Content \(Join-Path \`$camResetDir 'out\\\\latest\.json'\)") 'class D: FixSite gives the finder a new run id, uses only the result carrying it, and reads it ONCE (no second read of latest.json) (code shape)'
Check ($fsSrc -notmatch "Set-Content -LiteralPath \`$localList" -and $fsSrc -notmatch "Set-Content -LiteralPath \`$listPath" -and $fsSrc -notmatch "'scan\.json'\) -Encoding" -and $fsSrc -notmatch "'plan\.json'\) -Encoding" -and $fsSrc -notmatch "'summary\.json'\) -Encoding" -and $fsSrc -notmatch "Set-Content -LiteralPath \(Join-Path \`$runDir 'site\.txt'\)") 'class A: FixSite writes no record (site list, scan, plan, summary, site.txt) with a plain Set-Content any more (code shape)'
Check ($fsSrc -match "(?s)scan\.json.{0,400}if \(\`$Mode -eq 'Fix'\) \{ Say \('STOPPED.{0,300}Done 7" -and $fsSrc -match "(?s)plan\.json.{0,400}if \(\`$Mode -eq 'Fix'\) \{ Say \('STOPPED.{0,300}Done 7") 'class A: in Fix mode a scan.json / plan.json that cannot be saved stops the run before any change (exit 7) (code shape)'

# ======================= CamReset: Find cameras' result files (class A/D), Make-Request (class A) =======================
Write-Host ''; Write-Host 'class A/D (CamReset Find-Cameras.ps1): the result echoes the run id it was given, and counts only when it reads back'
$crSrc = Join-Path $repo 'CamReset'
function Invoke-Fc([string]$name, [string[]]$extra, [scriptblock]$prep) {
  $dir = Join-Path $tmp ('cr-' + $name); New-Item -ItemType Directory -Force -Path $dir | Out-Null
  Copy-Item -Path (Join-Path $crSrc '*') -Destination $dir -Recurse -Force
  [IO.File]::WriteAllText((Join-Path $dir 'config.json'), '{ "univiewTryDefault": false, "listenSeconds": 9 }')
  New-Item -ItemType Directory -Force -Path (Join-Path $dir 'out') | Out-Null
  if ($prep) { & $prep $dir }
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $out = & $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dir 'Find-Cameras.ps1') -NoMulticast -NoPing -NoLogin -SweepTargets '127.0.0.71' -SweepPorts 9 -SweepTimeoutMs 100 @extra 2>&1 | Out-String; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $prev }
  $lj = Join-Path (Join-Path $dir 'out') 'latest.json'; $o = $null; try { if (Test-Path -LiteralPath $lj -PathType Leaf) { $o = [IO.File]::ReadAllText($lj) | ConvertFrom-Json } } catch {}
  return [pscustomobject]@{ code = $code; latest = $o; out = $out; dir = $dir }
}
$f1 = Invoke-Fc 'runid' @('-RunId', 'twins-run-7')
Check ($f1.code -eq 0 -and $f1.latest -and [string](P $f1.latest 'runId') -ceq 'twins-run-7') 'class D: Find cameras -RunId writes that run id into out\latest.json (FixSite proves the result is THIS run''s by it, not by time)' ([string]$f1.code + ' ' + $(if ($f1.latest) { ConvertTo-Json -Compress -InputObject $f1.latest } else { ($f1.out -split "`n" | Select-Object -Last 3) -join ' | ' }))
$f2 = Invoke-Fc 'latestblocked' @() { param($d) New-Item -ItemType Directory -Force -Path (Join-Path (Join-Path $d 'out') 'latest.json') | Out-Null }
Check ($f2.code -ne 0 -and $f2.out -match 'could NOT save') 'class A: Find cameras whose latest.json cannot be written ends with an error code and says so (2.2.19: a warning, exit 0, so the caller took the old result)' ('exit ' + $f2.code + ' | ' + (($f2.out -split "`n" | Where-Object { $_ -match 'latest|save' } | Select-Object -First 2) -join ' | '))
$mrDir = Join-Path $tmp 'mr'; New-Item -ItemType Directory -Force -Path (Join-Path $mrDir 'out') | Out-Null; Copy-Item -Path (Join-Path $crSrc '*') -Destination $mrDir -Recurse -Force
$mrSn = 'DS-2CD2143G2-I20230101AAWRK12345678'
[IO.File]::WriteAllText((Join-Path $mrDir 'out/latest.json'), ('{"devices":[{"Brand":"Hikvision","Model":"DS-2CD2143G2-I","Serial":"' + $mrSn + '","IP":"192.168.1.64","MAC":"aa-bb","StartTime":"x"}]}'))
$xml = Join-Path $mrDir 'export.xml'; [IO.File]::WriteAllText($xml, ('<x>' + $mrSn + '</x>'))
New-Item -ItemType Directory -Force -Path (Join-Path (Join-Path (Join-Path $mrDir 'requests') ($mrSn -replace '[^\w\-]', '_')) 'request.json') | Out-Null
$prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
try { $mrOut = & $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $mrDir 'Make-Request.ps1') -Serial K12345678 -XmlPath $xml 2>&1 | Out-String; $mrCode = $LASTEXITCODE } finally { $ErrorActionPreference = $prev }
Check ($mrCode -ne 0 -and $mrOut -notmatch 'Request ready') 'class A (already safe): Make-Request whose request.json cannot be written does NOT say "Request ready" and ends with an error code (2.2.19 had $ErrorActionPreference Stop; 2.2.20 adds the read-back)' ('exit ' + $mrCode)

# ======================= FixNVR: plan.json + before.json before the YES (class A) =======================
Write-Host ''; Write-Host 'class A (FixNVR.ps1): plan.json and before.json are saved and read back before the YES; a Fix run that cannot save them stops'
$fnv = $head + "`n" + 'Import-Fns ' + (Q (Join-Path $repo 'FixNVR/FixNVR.ps1')) + "`n" + '$D = ' + $W + "`n" + @'
function Log { param($s) }
Run 'denied' {
  $rd = Join-Path $D 'fnv1'; New-Item -ItemType Directory -Force -Path (Join-Path $rd 'plan.json') | Out-Null   # the plan's place is taken
  [ordered]@{ why = [string](Save-FnRunRecords $rd @([pscustomobject]@{ type = 'cam-net'; old_ip = '10.0.0.5'; new_ip = '192.168.1.5' }) @([ordered]@{ ip = '10.0.0.5'; mac = 'aa' })) }
}
Run 'beforeDenied' {
  $rd = Join-Path $D 'fnv2'; New-Item -ItemType Directory -Force -Path (Join-Path $rd 'before.json') | Out-Null
  [ordered]@{ why = [string](Save-FnRunRecords $rd @([pscustomobject]@{ type = 'cam-net'; old_ip = '10.0.0.5'; new_ip = '192.168.1.5' }) @([ordered]@{ ip = '10.0.0.5'; mac = 'aa' })) }
}
Run 'ok' {
  $rd = Join-Path $D 'fnv3'; New-Item -ItemType Directory -Force -Path $rd | Out-Null
  $w = [string](Save-FnRunRecords $rd @([pscustomobject]@{ type = 'cam-net'; old_ip = '10.0.0.5'; new_ip = '192.168.1.5' }) @([ordered]@{ ip = '10.0.0.5'; mac = 'aa' }))
  $p = $null; try { $p = [IO.File]::ReadAllText((Join-Path $rd 'plan.json')).TrimStart([char]0xFEFF) | ConvertFrom-Json } catch {}
  [ordered]@{ why = $w; planIp = $(if ($p) { [string]@($p)[0].new_ip } else { '' }); before = (Test-Path -LiteralPath (Join-Path $rd 'before.json')) }
}
Run 'listPlan' {
  $rd = Join-Path $D 'fnv4'; New-Item -ItemType Directory -Force -Path $rd | Out-Null
  $pl = New-Object System.Collections.Generic.List[object]; $pl.Add([pscustomobject]@{ type = 'nvr-net'; old_ip = '192.168.1.20'; how = 'static' })   # the plan as FixNVR builds it (a List[object])
  $w = [string](Save-FnRunRecords $rd $pl @([ordered]@{ ip = '192.168.1.20'; mac = 'aa' }))
  [ordered]@{ why = $w; plan = (Test-Path -LiteralPath (Join-Path $rd 'plan.json') -PathType Leaf) }
}
# NvrFix (already safe): the restart-limit ledger's move runs under a local 'Stop', and the record is read back
Import-Fns ([IO.Path]::Combine((Split-Path -Parent (Split-Path -Parent $D)), 'x'))
'@ + $tail
$fnv = $fnv.Replace("Import-Fns ([IO.Path]::Combine((Split-Path -Parent (Split-Path -Parent `$D)), 'x'))", '')
$o = Invoke-Driver 'fixnvr' $fnv; $j = Get-Json $o
if (-not $j) { Check $false 'FixNVR driver ran' $o }
$c = P $j 'denied'; Check ($c -and -not (P $c 'error') -and [string](P $c 'why') -match 'plan\.json') 'class A: a plan.json that cannot be saved is reported (Save-FnRunRecords), so Fix stops before the YES (2.2.19: plain Set-Content under Continue)' $c
$c = P $j 'beforeDenied'; Check ($c -and -not (P $c 'error') -and [string](P $c 'why') -match 'before\.json') 'class A: a before.json that cannot be saved is reported, not only logged (2.2.19 logged it and went on to change devices)' $c
$c = P $j 'ok'; Check ($c -and -not (P $c 'error') -and -not [string](P $c 'why') -and [string](P $c 'planIp') -eq '192.168.1.5' -and (P $c 'before')) 'class A: a writable run folder gets plan.json and before.json, read back' $c
$c = P $j 'listPlan'; Check ($c -and -not (P $c 'error') -and -not [string](P $c 'why') -and (P $c 'plan')) 'control: the plan as FixNVR really builds it (a List of steps) is saved - the new STOP does not fire on an ordinary run' $c
$fnSrc = Read-Src 'FixNVR/FixNVR.ps1'
$iRec = $fnSrc.IndexOf('$recWhy = Save-FnRunRecords'); $iYes = $fnSrc.IndexOf("Read-Host 'Type YES"); $iStop = $fnSrc.IndexOf("if (`$Mode -ne 'Check') { Say ('STOPPED: ' + `$recWhy")
Check ($iRec -gt 0 -and $iStop -gt $iRec -and $iYes -gt $iStop -and $fnSrc -notmatch "Set-Content \(Join-Path \`$runDir 'plan\.json'\)") 'class A: FixNVR saves plan.json + before.json (Save-FnRunRecords) and stops a Fix run on failure BEFORE the YES prompt (code shape)'

$nf = $head + "`n" + 'Import-Fns ' + (Q (Join-Path $tk 'modules/NvrHealth/NvrFix.ps1')) + "`n" + '$D = ' + $W + "`n" + @'
function Log { param($s) }
Run 'moveSilent' {
  $sf = Join-Path $D 'lim1.json'; [IO.File]::WriteAllText($sf, '{"10.0.0.5":["2026-11-10T08:00:00"]}')
  function Move-Item { [CmdletBinding()]param($LiteralPath, $Destination, [switch]$Force, $WhatIf, $Confirm) Write-Error 'move denied (test stand-in)' }
  $h = @{ '10.0.0.5' = @([datetime]'2026-11-10T08:00:00', [datetime]'2026-11-11T08:00:00') }
  $ok = Write-FixLimits $sf $h
  Remove-Item function:Move-Item
  [ordered]@{ ok = $ok; file = [IO.File]::ReadAllText($sf) }
}
Run 'moveNoop' {
  $sf = Join-Path $D 'lim2.json'; [IO.File]::WriteAllText($sf, '{"10.0.0.5":["2026-11-10T08:00:00"]}')
  function Move-Item { [CmdletBinding()]param($LiteralPath, $Destination, [switch]$Force, $WhatIf, $Confirm) }
  $h = @{ '10.0.0.5' = @([datetime]'2026-11-10T08:00:00', [datetime]'2026-11-11T08:00:00') }
  $ok = Write-FixLimits $sf $h
  Remove-Item function:Move-Item
  [ordered]@{ ok = $ok }
}
'@ + $tail
$o = Invoke-Driver 'nvrfix' $nf; $j = Get-Json $o
if (-not $j) { Check $false 'NvrFix driver ran' $o }
$c = P $j 'moveSilent'; Check ($c -and (P $c 'ok') -eq $false) 'class A (already safe): the restart-limit ledger whose final move fails NON-terminating under Continue is NOT saved (Write-FixLimits runs with a local Stop and reads back)' $c
$c = P $j 'moveNoop'; Check ($c -and (P $c 'ok') -eq $false) 'class A (already safe): a move that silently does nothing is caught by the read-back (the old ledger does not hold the new restart)' $c

# ======================= CamViews: the site list (class A) =======================
Write-Host ''; Write-Host 'class A (CamViews.ps1 Save-CvSite): "Remembered" only when camviews-sites.json reads back with this NVR'
$cv = $head + "`n" + 'Import-Fns ' + (Q (Join-Path $tk 'CamViews.ps1')) + "`n" + '$D = ' + $W + "`n" + @'
$script:CvDpapi = { param([string]$op, [byte[]]$data) $data }
$script:CvAclRun = { param([string[]]$a) 0 }
function Run-Save([string]$n, [scriptblock]$prep) {
  $script:CvHere = Join-Path $D ('cv-' + $n); New-Item -ItemType Directory -Force -Path (Join-Path $script:CvHere 'vault') | Out-Null
  if ($prep) { & $prep }
  $err = ''; try { Save-CvSite '10.0.0.2' 'Site A' 'admin' 'hikvision' 1 (ConvertTo-SecureString 'Test-only-1' -AsPlainText -Force) } catch { $err = $_.Exception.Message }
  $sites = @(); try { $sites = @(Get-CvSites) } catch {}
  [ordered]@{ err = $err; n = $sites.Count }
}
Run 'listBlocked' { Run-Save 'blocked' { New-Item -ItemType Directory -Force -Path (Join-Path $script:CvHere 'camviews-sites.json') | Out-Null } }
Run 'listOk' { Run-Save 'ok' $null }
'@ + $tail
$o = Invoke-Driver 'camviews' $cv; $j = Get-Json $o
if (-not $j) { Check $false 'CamViews driver ran' $o }
$c = P $j 'listBlocked'; Check ($c -and [string](P $c 'err') -match 'site list') 'class A: a camviews-sites.json that cannot be written THROWS (so "Remembered" is not said); 2.2.19 only warned' $c
$c = P $j 'listOk'; Check ($c -and -not [string](P $c 'err') -and [int](P $c 'n') -eq 1) 'control: a writable site list is saved and reads back with the NVR on it' $c

# ======================= NvrHealth -Json (class A) =======================
$nhSrc = Read-Src 'Toolkit/modules/NvrHealth/NvrHealth.psm1'
Check ($nhSrc -notmatch "Set-Content -Path \`$Json" -and $nhSrc -match 'json_saved' -and $nhSrc -match "Move-Item -LiteralPath \`$jtmp -Destination \`$Json -Force -ErrorAction Stop") 'class A: NvrHealth -Json writes its result whole, reads it back and says when it could not (json_saved) (code shape)'

# ======================= SiteCheck: a device no ping could be sent to (class C) + last-scan.json (class A) =======================
Write-Host ''; Write-Host 'class C (sitecheck/SiteCheck.ps1): a device no ping could even be sent to is NOT CHECKED - not 100% loss, not "nothing answers", not "gone"'
$sc = $head + "`n" + '$scPath = ' + (Q (Join-Path $repo 'sitecheck/SiteCheck.ps1')) + "`n" + '$D = ' + $W + "`n" + @'
# SiteCheck keeps its report code in the $SC_CODE here-string (run in a background runspace): its functions are defined from there
$scAst = [Management.Automation.Language.Parser]::ParseFile($scPath, [ref]$null, [ref]$null)
$hsA = $scAst.Find({ param($x) $x -is [Management.Automation.Language.AssignmentStatementAst] -and $x.Left.Extent.Text -match 'SC_CODE' }, $true)
$inner = [Management.Automation.Language.Parser]::ParseInput([string]$hsA.Right.Expression.Value, [ref]$null, [ref]$null)
foreach ($f in $inner.FindAll({ param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) { . ([scriptblock]::Create($f.Extent.Text.Replace('function ' + $f.Name, 'function global:' + $f.Name))) }
function New-R {
  $R = [ordered]@{ tool = 'WireIt Site Check'; version = 'test'; started = '2026-11-11T08:00:00'; pc = 'T'; nets = @([pscustomobject]@{ ip = '192.168.1.10'; prefix = 24; adapter = 'Ethernet'; speed = '1 Gbps' }); nvr = '192.168.1.2'
    nvrRead = [pscustomobject]@{ ok = $true; brand = 'Hikvision'; model = 'DS-7608'; Channels = @() }; devices = @(); channels = @(); duplicates = @(); notes = @(); seconds = 5; previous = $null; previousWhen = '' }
  $R.devices = @(
    [pscustomobject]@{ Ip = '192.168.1.2'; Mac = 'aa:aa:aa:aa:aa:02'; Vendor = 'Hikvision'; Model = 'DS-7608'; Kind = 'NVR'; Sent = 20; Ok = 20; LossPct = 0; Median = 1; Max = 2; Ports = @(80, 554); InArp = $true; DiffSubnet = $false; Firmware = ''; Source = 'SADP'; PingNotSent = $false },
    [pscustomobject]@{ Ip = '192.168.1.64'; Mac = 'aa:aa:aa:aa:aa:64'; Vendor = 'Hikvision'; Model = 'DS-2CD'; Kind = 'camera'; Sent = 0; Ok = 0; LossPct = $null; Median = $null; Max = $null; Ports = @(); InArp = $true; DiffSubnet = $false; Firmware = ''; Source = 'SADP'; PingNotSent = $true },
    [pscustomobject]@{ Ip = '192.168.1.80'; Mac = 'aa:aa:aa:aa:aa:80'; Vendor = 'Hikvision'; Model = 'DS-2CD'; Kind = 'camera'; Sent = 0; Ok = 0; LossPct = $null; Median = $null; Max = $null; Ports = @(); InArp = $true; DiffSubnet = $false; Firmware = ''; Source = 'ARP'; PingNotSent = $true })
  $R.channels = @([pscustomobject]@{ Ch = 1; Ip = '192.168.1.64'; Name = 'Front'; Online = $false; Known = $true; Detail = 'Disconnected' })
  $R.previous = @([pscustomobject]@{ ip = '192.168.1.80'; mac = 'aa:aa:aa:aa:aa:80'; vendor = 'Hikvision' }); $R.previousWhen = '2026-11-10 08:00:00'
  return $R
}
Run 'diag' {
  $R = New-R; $Dg = Get-ScDiagnosis $R
  $t = @(@($Dg.Findings) | ForEach-Object { [string]$_.Text })
  [ordered]@{ ch = (@($t | Where-Object { $_ -match '^ch 1' }) -join ' | '); prev = (@($t | Where-Object { $_ -match '192\.168\.1\.80' }) -join ' | ') }
}
Run 'report' {
  $R = New-R; $Dg = Get-ScDiagnosis $R; $txt = Format-ScReport $R $Dg
  $l64 = @(($txt -split "`r?`n") | Where-Object { $_ -match '192\.168\.1\.64' })
  [ordered]@{ ch = (@($l64 | Where-Object { $_ -match '^\s+ch 1\s+192' }) -join ' | '); dev = (@($l64 | Where-Object { $_ -match '^\s+192\.168\.1\.64\s' }) -join ' | ') }
}
Run 'lastScanBlocked' {
  $dir = Join-Path $D 'sc1'; New-Item -ItemType Directory -Force -Path (Join-Path $dir 'last-scan.json') | Out-Null
  $R = New-R; $Dg = Get-ScDiagnosis $R; $s = Save-ScReport $R $Dg $dir
  [ordered]@{ saved = $(if ($s -and $s.PSObject.Properties['LastScanSaved']) { $s.LastScanSaved } else { 'no answer' }); txt = [bool]($s -and (Test-Path -LiteralPath $s.Txt)) }
}
Run 'lastScanCarry' {
  $dir = Join-Path $D 'sc2'; New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $R = New-R; $Dg = Get-ScDiagnosis $R; $s = Save-ScReport $R $Dg $dir
  $o = [IO.File]::ReadAllText((Join-Path $dir 'last-scan.json')) | ConvertFrom-Json
  [ordered]@{ ips = (@($o.devices) | ForEach-Object { [string]$_.ip }) -join ',' }
}
Run 'prevUnreadable' {
  $dir = Join-Path $D 'sc3'; New-Item -ItemType Directory -Force -Path $dir | Out-Null; [IO.File]::WriteAllText((Join-Path $dir 'last-scan.json'), '{ broken')
  $R = New-R; $R.previous = $null; Read-ScPrevious $R $dir
  [ordered]@{ notes = (@($R.notes) -join ' | ') }
}
'@ + $tail
$o = Invoke-Driver 'sitecheck' $sc; $j = Get-Json $o
if (-not $j) { Check $false 'SiteCheck driver ran' $o }
$c = P $j 'diag'
Check ($c -and [string](P $c 'ch') -match 'NOT CHECKED' -and [string](P $c 'ch') -notmatch 'Nothing answers|frozen') 'class C: an offline channel whose camera this PC could not send one ping to is diagnosed NOT CHECKED (2.2.19: "does not answer ping - frozen" / "nothing answers")' $c
Check ($c -and [string](P $c 'prev') -match 'NOT CHECKED' -and [string](P $c 'prev') -notmatch 'but not now') 'class C: a device that answered last time and could not be pinged now is NOT CHECKED, not "answered last time but not now"' $c
$c = P $j 'report'
Check ($c -and [string](P $c 'ch') -match 'NOT SENT' -and [string](P $c 'ch') -notmatch '100% ok') 'class C: the report''s channel line says "ping NOT SENT" for it (2.2.19 printed "ping 100% ok" from an empty count)' $c
Check ($c -and [string](P $c 'dev') -match 'n/a' -and [string](P $c 'dev') -notmatch ' 100%') 'class C: the report''s device line shows its loss as n/a, never 100%' $c
$c = P $j 'lastScanBlocked'; Check ($c -and (P $c 'saved') -eq $false -and (P $c 'txt')) 'class A: a last-scan.json (the next run''s comparison) that cannot be written is said as NOT saved; the report itself is still saved (2.2.19 threw away the run''s result)' $c
$c = P $j 'lastScanCarry'; Check ($c -and [string](P $c 'ips') -match '192\.168\.1\.80') 'class C: a device that could not be pinged stays in the next comparison as it was last time (not checked is not gone)' $c
$c = P $j 'prevUnreadable'; Check ($c -and [string](P $c 'notes') -match 'NOT compared') 'class C: an unreadable previous scan is said ("NOT compared"), not silently skipped' $c
$scSrc = Read-Src 'sitecheck/SiteCheck.ps1'
Check ($scSrc -match 'PingNotSent = \(-not \$pq\.Sent\)' -and $scSrc -match '\$loss = \$\(if \(\$pq\.Sent\) \{ \[math\]::Round\(100\.0 \* \(\$pq\.Sent - \$pq\.Ok\) / \$pq\.Sent\) \} else \{ \$null \}\)') 'class C: SiteCheck marks a device with no ping sent (PingNotSent) and gives it no loss figure (code shape)'

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host ('Fix2220Twins: ' + $script:pass + ' passed, ' + $script:fail + ' failed, ' + $script:deferred + ' deferred')
if ($script:fail) { exit 1 }
