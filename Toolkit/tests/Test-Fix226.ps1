<# Test-Fix226.ps1 - behavioural tests for the 2.2.6 fixes (real functions and the real FixSite / ScanUpload / CamViews entry points;
   devices are mock_site.py on loopback). Each check failed on 2.2.5 review head aa306ef.
   Windows PowerShell 5.1 or pwsh 7. The password-folder check runs on Windows only (it needs a real Windows ACL). #>
$ErrorActionPreference = 'Stop'
$tk = Split-Path -Parent $PSScriptRoot; $repo = Split-Path -Parent $tk
$exe = $(if ($PSVersionTable.PSEdition -eq 'Core') { (Get-Process -Id $PID).Path } else { Join-Path $PSHOME 'powershell.exe' })
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fix226-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$script:pass = 0; $script:fail = 0
function Check([bool]$ok, [string]$name, [string]$more = '') { if ($ok) { $script:pass++; Write-Host ('PASS ' + $name) } else { $script:fail++; Write-Host ('FAIL ' + $name); if ($more) { Write-Host $more } } }
$srv = $null
try {
  # ---- bug 1: the password folder is made private by a normal (not "Run as administrator") login ----
  if ($env:OS -eq 'Windows_NT') {
    . (Join-Path $tk 'FixSiteCore.ps1'); . (Join-Path $tk 'FixSiteDevices.ps1')
    $script:FsTestSecrets = $false; $script:FsVaultAcl = $null
    $vd = Join-Path $tmp 'vault-acl'
    $err = ''; try { Initialize-FsSecretDirectory $vd; Initialize-FsSecretDirectory $vd } catch { $err = $_.Exception.Message }
    $isAdmin = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    Check (-not $err) ('password folder made private without SeSecurityPrivilege (this run elevated: ' + $isAdmin + ')' + $(if ($err) { ' - ' + $err } else { '' }))
    $acl = (Get-Item -LiteralPath $vd).GetAccessControl('Access')
    $sids = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique)
    $want = @('S-1-5-32-544', 'S-1-5-18', [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) | Sort-Object -Unique
    Check ($acl.AreAccessRulesProtected -and (($sids -join ',') -eq ($want -join ','))) ('...it inherits nothing and only admins, SYSTEM and this user have access (' + ($sids -join ',') + ')')
    $wrote = $false; try { [IO.File]::WriteAllText((Join-Path $vd 'probe.tmp'), 'x'); $wrote = $true } catch {}
    Check $wrote '...and this user can still write its password file there'
  } else { Write-Host 'SKIP password-folder ACL check (Windows only)' }

  # ---- bug 5: Save camera pictures must not delete the camera lists waiting in the shared outbox ----
  . (Join-Path $PSScriptRoot 'TestPython.ps1'); $py = Get-TestPython
  $otk = Join-Path $tmp 'outbox/Toolkit'; $ocr = Join-Path $tmp 'outbox/CamReset'; New-Item -ItemType Directory -Force -Path $otk, (Join-Path $ocr 'out') | Out-Null
  foreach ($f in @('ScanUpload.ps1', 'CamViews.ps1', 'ToolkitCore.ps1', 'ToolkitRecover.ps1')) { Copy-Item (Join-Path $tk $f) (Join-Path $otk $f) }
  @{ devices = @(@{ Brand = 'Hikvision'; Model = 'DS-2CD'; Serial = 'TESTSERIAL'; IP = '10.0.0.21'; MAC = 'c4:2f:90:00:00:21' }) } | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $ocr 'out/latest.json')
  $oldKey = $env:WIREIT_UPLOAD_KEY
  try { $env:WIREIT_UPLOAD_KEY = ''; & $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $otk 'ScanUpload.ps1') -Site 'WI-226' -CamResetDir $ocr | Out-Null } finally { $env:WIREIT_UPLOAD_KEY = $oldKey }
  $box = Join-Path $otk 'outbox'
  $scanF = @(Get-ChildItem -LiteralPath $box -Filter 'scan-*.json' -ErrorAction SilentlyContinue)
  Check ($scanF.Count -eq 1) 'setup: the real scan uploader, offline, left one camera list waiting in the outbox'
  '{"op":"camPush","site":"WI-226","source":"test","pc":"T","pics":[],"complete":true}' | Set-Content (Join-Path $box 'camviews-20261108-000000-abcdef.json')
  $portF = Join-Path $tmp 'ok-port.txt'; $bodies = Join-Path $tmp 'ok-bodies.txt'
  $spa = @{ FilePath = $py; ArgumentList = @((Join-Path $PSScriptRoot 'fix226/ok_server.py'), $portF, $bodies); PassThru = $true }; if ($env:OS -eq 'Windows_NT') { $spa.WindowStyle = 'Hidden' }
  $srv = Start-Process @spa
  for ($i = 0; $i -lt 100 -and -not (Test-Path $portF); $i++) { Start-Sleep -Milliseconds 100 }
  $port = (Get-Content $portF -Raw).Trim()
  $drv = Join-Path $tmp 'send-outbox.ps1'
  Set-Content $drv ("param([string]`$tk, [string]`$api)`n`$script:CvHere = `$tk`n. (Join-Path `$tk 'CamViews.ps1') -Lib -ApiUrl `$api`n`$n = Send-CvOutbox`n'SENT=' + `$n")
  try { $env:WIREIT_UPLOAD_KEY = ('T' * 32); $o = & $exe -NoProfile -ExecutionPolicy Bypass -File $drv -tk $otk -api ('http://127.0.0.1:' + $port + '/') 2>&1 | Out-String } finally { $env:WIREIT_UPLOAD_KEY = $oldKey }
  $sentBodies = $(if (Test-Path $bodies) { Get-Content $bodies -Raw } else { '' })
  Check ($o -match 'SENT=1' -and -not (Test-Path (Join-Path $box 'camviews-20261108-000000-abcdef.json')) -and $sentBodies -match '"op":"camPush"') 'the camera-pictures uploader still sends and clears its own waiting pictures' $o
  Check (@(Get-ChildItem -LiteralPath $box -Filter 'scan-*.json' -ErrorAction SilentlyContinue).Count -eq 1) 'reproduction (Codex file-by-file A): the waiting camera list is NOT deleted by the camera-pictures uploader'
  Check ($sentBodies -notmatch 'scanPush') '...and it is not sent by it either (the scan uploader sends it, with its own rules)'
  try { $srv.Kill() } catch {}; $srv = $null

  # ---- bugs 7, 8, 9: the real Fix this site against mock devices ----
  $scenario = & $py (Join-Path $PSScriptRoot 'fix226/scenarios.py') --repo $repo --powershell $exe 2>&1 | Out-String
  $res = $null; try { $res = $scenario | ConvertFrom-Json } catch {}
  if (-not $res) { Check $false 'Fix this site scenarios ran' $scenario }
  else {
    Check ($res.identity_saved_a_kept -and $res.identity_b_own) 'reproduction (Codex file-by-file C): a camera at a saved camera''s address does not take on its identity (saved password stays with the saved camera; the new one is saved under its own MAC)' $res.identity_out
    Check ($res.journal_exit -ne 0 -and $res.journal_password_untouched -and $res.journal_says_why) ('reproduction (Codex file-by-file D): an undo file that cannot be written stops the run before the password change (exit ' + $res.journal_exit + ')') $res.journal_out
    Check ($res.move_new_address_recorded) 'reproduction (Codex file-by-file E): a run killed mid-move has the new address in its undo file'
    Check ($res.move_undo_exit -eq 0 -and $res.move_undo_back) ('...and Undo finds the camera there and puts it back on its old address (exit ' + $res.move_undo_exit + ')') $res.move_out
  }
} catch { $script:fail++; Write-Host ('FAIL unexpected error: ' + $_.Exception.Message + ' at ' + $_.InvocationInfo.ScriptLineNumber) }
finally { if ($srv) { try { $srv.Kill() } catch {} }; Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host ('Test-Fix226: ' + $script:pass + ' passed, ' + $script:fail + ' failed')
exit $script:fail
