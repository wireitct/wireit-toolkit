<# Test-Fix2221Garage.ps1 - WireIt Toolkit 2.2.21 (Nov 12 2026). The office garage trial on 2.2.20 (real cameras, Nov 12 2026, report
 files/office-switch-trial/garage-trial-2026-11-12.md "Toolkit bugs" 1-7 + the LTS label) found F20-F27. Each check runs the real function
 (dot-sourced / loaded from the file's own AST) with stand-ins for the devices; a "code shape" check reads the source. No device, no Windows.
 Usage: pwsh -File Test-Fix2221Garage.ps1. Exit code = failed checks. #>
$ErrorActionPreference = 'Continue'
if (-not $env:TEMP) { $env:TEMP = [IO.Path]::GetTempPath() }
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$tk = Join-Path $repo 'Toolkit'
$script:pass = 0; $script:fail = 0
function Check([bool]$ok, [string]$name, [string]$more = '') { if ($ok) { $script:pass++; Write-Host ('PASS ' + $name) } else { $script:fail++; Write-Host ('FAIL ' + $name); if ($more) { Write-Host ('     ' + $more) } } }
function Load-Funcs([string]$file, [string[]]$names) {
  $ast = [Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$null)
  foreach ($n in $names) { $f = $ast.Find({ param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $n }, $true); if ($f) { . ([scriptblock]::Create($f.Extent.Text)) } else { Write-Host ('missing function ' + $n) } }
}
. (Join-Path $tk 'FixSiteCore.ps1')
. (Join-Path $tk 'FixSiteDevices.ps1')

# ---- F20 + F21: a Hikvision on ANOTHER IP range (10.1.60.35; the site / PC are 192.168.4.x) that does not answer HTTP ----
$obs = [pscustomobject]@{ devices = @([pscustomobject]@{ kind = 'camera'; ip = '10.1.60.35'; mac = 'c4:2f:90:00:00:35'; brand = 'Hikvision'; model = 'DS-2CD2143G2-I'; serial = 'CAM35'; login = ''; answers = $false; activated = $true; online = $null }); nvrs = @() }
$list = [pscustomobject]@{ scheme = '192.168.4'; cameras = @() }
$p = $null; try { $p = New-FsPlan $list $obs } catch { Write-Host ('New-FsPlan threw: ' + $_.Exception.Message) }
$c = $(if ($p) { @($p.cams | Where-Object { $_.mac -eq 'c4:2f:90:00:00:35' })[0] } else { $null })
$why = $(if ($c) { (@($c.why) -join ' | ') } else { '' }); $steps = $(if ($c) { @($c.steps) } else { @() })
Check ($c -and $why -match 'different IP range' -and $why -notmatch 'hung') 'F20: a camera on another IP range is reported "on a different IP range", not "hung - not answering"' $why
Check ($c -and $steps -notcontains 'unplug' -and $steps -notcontains 'poe') 'F20: ...and it gets no "unplug its cable" / power-cycle step' ($steps -join ',')
Check ($c -and $steps -contains 'reset') 'F20: ...and an other-range Hikvision whose password could not be tried stays in the official reset' ($steps -join ',')
$words = $(if ($c) { (@(Get-FsStepWords $c) -join ' | ') } else { '' })
Check ($words -match 'move 10\.1\.60\.35 -> 192\.168\.4\.\d+') 'F21: the plan prints the FULL new address ("move 10.1.60.35 -> 192.168.4.x", not "-> .35")' $words
# control: a camera on the SITE range that does not answer is still "hung" and still gets the unplug step
$obs2 = [pscustomobject]@{ devices = @([pscustomobject]@{ kind = 'camera'; ip = '192.168.4.36'; mac = 'c4:2f:90:00:00:36'; brand = 'Hikvision'; model = 'DS-2CD2143G2-I'; serial = 'CAM36'; login = ''; answers = $false; activated = $true; online = $null }); nvrs = @() }
$p2 = $null; try { $p2 = New-FsPlan $list $obs2 } catch {}
$c2 = $(if ($p2) { @($p2.cams | Where-Object { $_.mac -eq 'c4:2f:90:00:00:36' })[0] } else { $null })
Check ($c2 -and (@($c2.why) -join ' ') -match 'hung' -and (@($c2.steps) -contains 'unplug' -or @($c2.steps) -contains 'poe')) 'F20 control: a camera on the site''s own range that does not answer is still "hung" with the unplug step' $(if ($c2) { (@($c2.why) -join ' | ') + ' / ' + (@($c2.steps) -join ',') })
# ---- F26: factory-fresh camera, plain words ----
$ca = [pscustomobject]@{ steps = @('activate'); ip = '192.168.4.155'; target = ''; brand = 'Hikvision' }
Check ((@(Get-FsStepWords $ca) -join ' ') -match 'SADP') 'F26: the activation step says plainly it is done in SADP (the Toolkit does not send the password over the network unencrypted)' (@(Get-FsStepWords $ca) -join ' ')

# ---- F22: the receipt counts what was fixed and lists skipped devices apart ----
. Load-Funcs (Join-Path $tk 'FixSite.ps1') @('Write-FsReceipt')
function Fs-Log { param($s) }
$script:FsVersion = '2.2.21'; $Mode = 'Fix'; $siteName = 'Office garage test'; $Site = ''; $runDir = ''; $stamp = 'test'; $here = $tk
$rd = Join-Path ([IO.Path]::GetTempPath()) ('fix2221g-' + [guid]::NewGuid().ToString('N')); $env:WIREIT_RECEIPT_DIR = $rd
$ok = [string][char]0x2705; $x = [string][char]0x274C
$script:results = @(('cam 192.168.4.156: password not reset - skipped ' + $x), ('cam 192.168.4.155: activate - skipped ' + $x), ('cam 10.1.60.35: skipped ' + $x)); $script:okCount = 0; $script:badCount = 3
$f = Write-FsReceipt 4 $null; $txt = $(if ($f -and (Test-Path -LiteralPath $f)) { [IO.File]::ReadAllText($f) } else { '' })
Check ($txt -match 'Result: NOTHING FIXED \(0 of 3\)' -and $txt -notmatch 'DONE, but') 'F22: 0 of 3 fixed -> "Result: NOTHING FIXED (0 of 3)", never "DONE, but some steps did not work"' (($txt -split "`n" | Select-Object -First 5) -join ' / ')
$chgPart = $(if ($txt -match '(?s)Changed on the cameras / NVR:(.*?)(\r?\n\r?\n|$)') { $Matches[1] } else { '' })
Check ($chgPart -match '- nothing' -and $chgPart -notmatch '192\.168\.4\.156' -and $txt -match '(?s)Not done / skipped:.*192\.168\.4\.156') 'F22: skipped cameras are listed under "Not done / skipped", not under "Changed on the cameras / NVR"' $chgPart
$script:results = @(('cam 192.168.4.21: settings ' + $ok), ('cam 192.168.4.22: password not reset - skipped ' + $x)); $script:okCount = 1; $script:badCount = 1
$f = Write-FsReceipt 4 $null; $txt = $(if ($f -and (Test-Path -LiteralPath $f)) { [IO.File]::ReadAllText($f) } else { '' })
Check ($txt -match 'Result: PARTLY DONE: 1 of 2 fixed' -and $txt -match '(?s)Changed on the cameras / NVR:\s*\r?\n\s*- cam 192\.168\.4\.21') 'F22 control: 1 of 2 fixed -> "PARTLY DONE: 1 of 2 fixed", the fixed camera under Changed' (($txt -split "`n" | Select-Object -First 8) -join ' / ')
$script:results = @(('cam 192.168.4.21: settings ' + $ok)); $script:okCount = 1; $script:badCount = 0
$f = Write-FsReceipt 0 $null; $txt = $(if ($f -and (Test-Path -LiteralPath $f)) { [IO.File]::ReadAllText($f) } else { '' })
Check ($txt -match 'Result: DONE' -and $txt -notmatch 'Not done / skipped') 'F22 control: everything fixed -> "Result: DONE", no skipped section'
Remove-Item Env:WIREIT_RECEIPT_DIR -ErrorAction SilentlyContinue; Remove-Item -Recurse -Force -LiteralPath $rd -ErrorAction SilentlyContinue

# ---- F23: installer clean-up on a PC that never had the old task ----
. (Join-Path $tk 'ToolkitMigrate.ps1')
$ops = Get-TkRealOps
function schtasks.exe { Write-Error 'ERROR: The system cannot find the file specified.'; $global:LASTEXITCODE = 1 }
$eapSave = $ErrorActionPreference; $ErrorActionPreference = 'Stop'; $threw = $false; $r = $null
try { $r = & $ops.taskExists 'WireIt Fix this site' } catch { $threw = $true }
$ErrorActionPreference = $eapSave
Check (-not $threw -and $r -eq $false) 'F23: with ErrorActionPreference Stop (as the installer runs), schtasks'' "cannot find the file" for a missing task is "no task", not an error (2.2.20: "the 2.2.x clean-up did not run")' ('threw=' + $threw + ' result=' + $r)
function schtasks.exe { $global:LASTEXITCODE = 0 }
$ErrorActionPreference = 'Stop'; $r2 = $null; try { $r2 = & $ops.taskExists 'WireIt Fix this site' } catch {}; $ErrorActionPreference = $eapSave
Check ($r2 -eq $true) 'F23 control: an existing task is still found (so it is still removed)'
Remove-Item function:schtasks.exe -ErrorAction SilentlyContinue
Write-Host 'DEFERRED F23 on real Windows PowerShell 5.1 (native stderr under Stop) - the stand-in above raises the same error record'

# ---- F24 + F27: Find Cameras ----
$fc = Join-Path $repo 'CamReset\Find-Cameras.ps1'; if (-not (Test-Path -LiteralPath $fc)) { $fc = Join-Path $repo 'CamReset/Find-Cameras.ps1' }
$src = [IO.File]::ReadAllText($fc)
Check ($src -match [regex]::Escape("`$(if ([string]`$r.DeviceDate) { ' | date ' + `$r.DeviceDate } else { '' })") -and $src -notmatch [regex]::Escape("' | date ' + `$r.DeviceDate)")) 'F24 (code shape): Find Cameras prints "| date" (and "| start") only when there is one'
. Load-Funcs $fc @('Test-CrLtsModel', 'Get-CrBrandLabel')
Check ((Test-CrLtsModel 'LXIP3C82W-28MDA') -and -not (Test-CrLtsModel 'DS-2CD2143G2-I') -and (Test-CrLtsModel 'CMIP3C42W-28')) 'F27: an LTS model (LXIP..., CMIP...) is recognised; a Hikvision DS-2CD is not'
Check ((Get-CrBrandLabel 'Hikvision (OEM: LTS)') -eq 'LTS (Hikvision-made)' -and (Get-CrBrandLabel 'Hikvision') -eq 'Hikvision') 'F27: it is shown as "LTS (Hikvision-made)"; a plain Hikvision stays "Hikvision"'
Check ($src -match "Test-CrLtsModel \(\[string\]\`$d\.Model\)\)\) \{ \`$d\.Brand = 'Hikvision \(OEM: LTS\)'") 'F27 (code shape): the brand kept for the reset tools still starts with "Hikvision" (Make-Request and the Toolkit select Hikvision*), so an LTS camera keeps every Hikvision step'

# ---- F25: a look-only (Plan) run asks no password ----
$fs = [IO.File]::ReadAllText((Join-Path $tk 'FixSite.ps1'))
Check ($fs -match [regex]::Escape("if (`$unk.Count -and -not `$skipCamAsk -and `$Mode -ne 'Plan') {")) 'F25 (code shape): the "Know the password for this camera" question is not asked in a look-only (Plan) run'

Write-Host ''
Write-Host ('Test-Fix2221Garage: ' + $script:pass + ' passed, ' + $script:fail + ' failed, 1 deferred')
exit $script:fail
