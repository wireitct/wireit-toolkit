<# Regressions from the independent 2.2.5 review. Real functions/entry points; hardware and Windows ACL calls are mocked. #>
$ErrorActionPreference = 'Stop'
$tk = Split-Path -Parent $PSScriptRoot; $repo = Split-Path -Parent $tk
$exe = (Get-Process -Id $PID).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('review225-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$script:pass = 0; $script:fail = 0
function Check([bool]$ok, [string]$name) { if ($ok) { $script:pass++; Write-Host ('PASS ' + $name) } else { $script:fail++; Write-Host ('FAIL ' + $name) } }
function Load-Function([string]$file, [string]$name) {
  $a = [Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$null)
  $f = $a.Find({ param($x) $x -is [Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $name }.GetNewClosure(), $true)
  return [scriptblock]::Create($f.Extent.Text)
}
try {
  . (Join-Path $tk 'FixSiteCore.ps1'); . (Join-Path $tk 'FixSiteDevices.ps1'); . (Join-Path $tk 'ToolkitMigrate.ps1')
  $fresh = Join-Path $tmp 'fresh/Toolkit'; New-Item -ItemType Directory -Force -Path $fresh | Out-Null
  $script:locks = @()
  $ops = @{ taskExists = { $false }; exists = { param($p) Test-Path -LiteralPath $p }; isLocked = { $false }
    create = { param($p) New-Item -ItemType Directory -Force -Path $p | Out-Null }
    icacls = { param($a) $script:locks += ,$a; 0 }; adminUsers = { @() } }
  $r = Invoke-TkMigration -Root (Split-Path $fresh) -ToolkitDir $fresh -OwnerSid 'S-1-5-21-1-1-1-1001' -Ops $ops
  Check ((Test-Path (Join-Path $fresh 'vault')) -and (Test-Path (Join-Path $fresh 'secrets')) -and $script:locks.Count -eq 2) 'fresh install creates and locks both private directories'
  $script:events = @(); $script:FsVaultAcl = { param($d) $script:events += 'acl'; $true }
  $script:FsDpapi = { param($op, $data, $scope) $script:events += $op; [byte[]]$data }
  $sec = Read-FsSecrets (Join-Path $tmp 'first-save') 'Review'; $sec.password = 'Testpass123'
  Save-FsSecrets (Join-Path $tmp 'first-save') $sec
  Check (($script:events -join ',') -eq 'acl,protect') 'first password save protects its directory before writing'
  $script:FsVaultAcl = { $false }; $threw = $false
  try { Save-FsSecrets (Join-Path $tmp 'denied') $sec } catch { $threw = $true }
  Check ($threw -and -not @(Get-ChildItem (Join-Path $tmp 'denied') -File).Count) 'a failed private ACL stops the save without leaving a password file'
  $script:FsVaultAcl = $null; $script:FsDpapi = $null

  . (Join-Path $tk 'HikMail.ps1'); . (Join-Path $tk 'HikEmailDrop.ps1')
  $serial = 'DS-7608NI-K2/8P20210505CCWRF99887766'
  $hikTk = Join-Path $tmp 'serial/Toolkit'; $inbox = Get-HikInboxDir $hikTk
  New-Item -ItemType Directory -Force -Path $inbox | Out-Null
  @{ devices = @(@{ serial = $serial; shortSerial = 'F99887766' }) } | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $inbox 'waiting.json')
  Check (@(Get-HikWaitingDevices $hikTk).Count -eq 1) 'NVR with slash in full serial remains in the waiting list'
  $drop = Save-HikEmailDrop $inbox $serial '' 'AB12CD34'
  Check ($drop.ok -and (Split-Path -Parent $drop.path) -eq $inbox) 'NVR code drop uses a safe filename under the inbox'
  $matches = Find-HikReplyMatches @([pscustomobject]@{ serial=$serial; shortSerial='F99887766'; mac='' }) @(Get-HikFolderMessages $inbox (Get-Date).AddMinutes(-1))
  Check (@($matches.matched).Count -eq 1 -and $matches.matched[0].device.serial -eq $serial) 'escaped inbox filename still matches the complete serial'

  . (Join-Path $tk 'ToolkitCore.ps1')
  $recover = Join-Path $tmp 'recovery/Toolkit'; $prev = Join-Path $recover 'previous/2.2.5'
  New-Item -ItemType Directory -Force -Path (Join-Path $prev 'Toolkit') | Out-Null
  Copy-Item (Join-Path $tk 'ToolkitCore.ps1') (Join-Path $prev 'Toolkit/ToolkitCore.ps1')
  [IO.File]::WriteAllText((Join-Path $recover 'ToolkitCore.ps1'), 'function Broken {')
  Save-TkJson @{ prev=$prev; from='2.2.5'; to='2.2.6'; added=@() } (Join-Path $recover 'previous/update-pending.json')
  $msg = Invoke-TkStartupRecovery $recover
  Check ($msg -match 'put back' -and (Get-TkSha256 (Join-Path $recover 'ToolkitCore.ps1')) -eq (Get-TkSha256 (Join-Path $tk 'ToolkitCore.ps1'))) 'startup recovers a truncated core without loading it'
  Check (-not (Test-Path (Join-Path $recover 'previous/update-pending.json'))) 'recovery clears the journal only after restoring files'
  # The actual launcher must recover before it parses even one line of the damaged core.
  foreach ($f in @('WireItToolkit.ps1','ToolkitRecover.ps1')) { Copy-Item (Join-Path $tk $f) (Join-Path $recover $f) }
  $marker = Join-Path $tmp 'core-loaded.txt'
  [IO.File]::WriteAllText((Join-Path $prev 'Toolkit/ToolkitCore.ps1'), ("[IO.File]::WriteAllText('" + $marker.Replace("'","''") + "','restored'); exit 0"))
  [IO.File]::WriteAllText((Join-Path $recover 'ToolkitCore.ps1'), 'function Broken {')
  Save-TkJson @{ prev=$prev; from='2.2.5'; to='2.2.6'; added=@() } (Join-Path $recover 'previous/update-pending.json')
  & $exe -NoProfile -File (Join-Path $recover 'WireItToolkit.ps1') -NoUpdate | Out-Null
  Check ($LASTEXITCODE -eq 0 -and (Test-Path $marker)) 'real launcher restores a truncated core before loading it'
  Remove-Item $marker
  Save-TkJson @{ prev=(Join-Path $tmp 'missing-backup'); from='2.2.5'; to='2.2.6'; added=@() } (Join-Path $recover 'previous/update-pending.json')
  $null = & $exe -NoProfile -File (Join-Path $recover 'WireItToolkit.ps1') -NoUpdate 2>&1
  Check ($LASTEXITCODE -eq 1 -and -not (Test-Path $marker)) 'real launcher stops before loading the core when recovery fails'
  $src = Join-Path $tmp 'source.ps1'; $dst = Join-Path $tmp 'live.ps1'
  Set-Content $src 'new complete script'; Set-Content $dst 'old complete script'; $before = Get-TkSha256 $dst
  & {
    function Copy-Item { param($LiteralPath,$Destination,[switch]$Force,$ErrorAction) [IO.File]::WriteAllText($Destination,'partial'); throw 'interrupted copy' }
    $stopped = $false; try { Copy-TkAtomicFile $src $dst } catch { $stopped = $true }
    Check ($stopped -and (Get-TkSha256 $dst) -eq $before) 'an interrupted staging copy leaves the live script intact'
  }
  Copy-TkAtomicFile $src $dst
  Check ((Get-TkSha256 $dst) -eq (Get-TkSha256 $src)) 'a complete replacement installs the verified script'

  $mod = Import-Module (Join-Path $tk 'modules/NvrHealth/NvrHealth.psm1') -Force -PassThru -DisableNameChecking
  $transport = & $mod {
    $script:Opt.MockUrl = ''; $script:NhSecretTls = @{}; $script:captured = @(); $script:scenario = 'ok'
    function Invoke-WebRequest {
      [CmdletBinding()] param($Uri,$Method,$Body,$Credential,$ContentType,$Headers,$TimeoutSec,[switch]$UseBasicParsing,[switch]$SkipCertificateCheck,[switch]$AllowUnencryptedAuthentication)
      $script:captured += [string]$Uri
      if ($script:scenario -eq 'tls-fail') { throw [Security.Authentication.AuthenticationException]::new('TLS handshake failed') }
      [pscustomobject]@{ StatusCode=200; Content='<ResponseStatus><statusCode>1</statusCode></ResponseStatus>' }
    }
    $c = [pscredential]::new('admin',(ConvertTo-SecureString 'Testpass123' -AsPlainText -Force))
    $r = Http -Ip '10.0.0.20' -Method PUT -Path '/ISAPI/Security/users/1' -Body '<User><password>Newpass456</password></User>' -Credential $c -NoLogBody
    $https = ($r.code -eq 200 -and $script:captured.Count -eq 1 -and $script:captured[0] -eq 'https://10.0.0.20/ISAPI/Security/users/1')
    $script:captured = @(); $script:scenario = 'tls-fail'
    $r = Http -Ip '10.0.0.21' -Method PUT -Path '/ISAPI/Security/users/1' -Body '<User><password>Newpass456</password></User>' -Credential $c -NoLogBody
    [pscustomobject]@{ https=$https; noDowngrade=($r.code -eq 0 -and -not @($script:captured | Where-Object { $_ -like 'http://*' }).Count) }
  }
  Check $transport.https 'legacy password write uses HTTPS even when HTTP works'
  Check $transport.noDowngrade 'legacy TLS failure never retries a password over HTTP'
  $verify = & $mod {
    param($tmp)
    $script:Opt.LogDir = Join-Path $tmp 'recording-logs'; $script:reads = 0
    function Http {
      param($Ip,$Method='GET',$Path,$Body,$Credential,$Port,$ContentType,$Timeout,[switch]$NoLogBody)
      if ($Path -eq '/ISAPI/ContentMgmt/record/tracks') { $script:reads++; if ($script:reads -ge 3) { return @{code=503;body=''} }; return @{code=200;body='<TrackList><Track><id>101</id><Enable>false</Enable></Track></TrackList>'} }
      if ($Method -eq 'PUT') { return @{code=500;body=''} }
      @{code=200;body='<Track><id>101</id><Enable>false</Enable></Track>'}
    }
    Invoke-NvrFix -Fix recording -Ip '10.0.0.20' -Vendor Hikvision -Credential ([pscredential]::new('admin',(ConvertTo-SecureString 'Testpass123' -AsPlainText -Force))) -BackupDir (Join-Path $tmp 'backup') -Confirm { 'YES' }
  } $tmp
  Check (-not $verify.ok -and @($verify.changed).Count -eq 0) 'failed recording write and unreadable verification cannot report success'
  Remove-Module $mod -Force

  foreach ($row in @(@('modules/NvrHealth/tests/Test-NvrHealth.ps1','Writes'),@('tests/Test-FixIt.ps1','W'),@('tests/Test-Toolkit.ps1','MockWrites'))) {
    & {
      . (Load-Function (Join-Path $tk $row[0]) $row[1]); $base='http://unused'; $mb=$base; $mbase=$base
      function Invoke-WebRequest { param($Uri,[switch]$UseBasicParsing) [pscustomobject]@{Content='[{"ip":"10.0.0.1","method":"GET"},{"ip":"10.0.0.2","method":"PUT"}]'} }
      function ConvertFrom-Json { [CmdletBinding()]param([Parameter(ValueFromPipeline=$true)][string]$InputObject) process { $v=Microsoft.PowerShell.Utility\ConvertFrom-Json $InputObject; $PSCmdlet.WriteObject($v,$false) } }
      $writes = @(& $row[1]); $bad = @($writes | Where-Object { $_.ip -eq '10.0.0.1' -and $_.method -eq 'PUT' })
      Check ($writes.Count -eq 2 -and $bad.Count -eq 0) ($row[1] + ' enumerates JSON rows under the PS 5.1 rule without cross-row matches')
    }
  }

  $export = Join-Path $tmp 'export'; New-Item -ItemType Directory -Force -Path (Join-Path $export 'Toolkit/fixsite-runs/demo/backup'), (Join-Path $export 'tools') | Out-Null
  Copy-Item (Join-Path $tk 'ToolkitCore.ps1') (Join-Path $export 'Toolkit/ToolkitCore.ps1')
  Set-Content (Join-Path $export 'tools/shipped-files.txt') 'Toolkit/ToolkitCore.ps1'
  Set-Content (Join-Path $export 'Toolkit/fixsite-runs/demo/backup/configurationData.bin') 'SIMULATED CUSTOMER BACKUP'
  & (Join-Path $repo 'tools/Build-Manifest.ps1') -Repo $export -Out (Join-Path $tmp 'built.json') -Commit ('a' * 40) | Out-Null
  $built = Get-Content (Join-Path $tmp 'built.json') -Raw | ConvertFrom-Json
  Check (@($built.files).Count -eq 1 -and $built.files[0].path -eq 'Toolkit/ToolkitCore.ps1') 'no-git release inventory excludes runtime customer backups'

  # Run the real scan uploader twice, offline, in a completely separate Toolkit directory.
  $scanTk = Join-Path $tmp 'scan/Toolkit'; $cr = Join-Path $tmp 'scan/CamReset'; New-Item -ItemType Directory -Force -Path $scanTk, (Join-Path $cr 'out') | Out-Null
  foreach ($f in @('ScanUpload.ps1','CamViews.ps1','ToolkitCore.ps1','ToolkitRecover.ps1')) { Copy-Item (Join-Path $tk $f) (Join-Path $scanTk $f) }
  @{devices=@(@{Brand='Hikvision';Model='DS-2CD';Serial='TESTSERIAL';IP='10.0.0.21';MAC='c4:2f:90:00:00:21'})} | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $cr 'out/latest.json')
  $oldKey = $env:WIREIT_UPLOAD_KEY; $env:WIREIT_UPLOAD_KEY = ''
  try { foreach ($site in @('A B','A_B')) { & $exe -NoProfile -File (Join-Path $scanTk 'ScanUpload.ps1') -Site $site -CamResetDir $cr | Out-Null } } finally { $env:WIREIT_UPLOAD_KEY=$oldKey }
  $queued = @(Get-ChildItem (Join-Path $scanTk 'outbox') -Filter 'scan-*.json' | ForEach-Object { (Get-Content $_.FullName -Raw | ConvertFrom-Json).site })
  Check ($queued.Count -eq 2 -and $queued -contains 'A B' -and $queued -contains 'A_B') 'different site names keep independent offline scan lists'

  # A controlled wrong MAC parser forces assertions in the actual SiteCheck suite to fail; its process must return those failures.
  $shim = Join-Path $tmp 'sitecheck-shim.ps1'; $sc = (Join-Path $repo 'sitecheck/SiteCheck.ps1').Replace("'", "''")
  Set-Content $shim ("param([switch]`$LoadOnly)`n. '$sc' -LoadOnly`nfunction ConvertTo-ScMac { 'BROKEN' }")
  $oldTemp = $env:TEMP; $env:TEMP = $tmp
  try { $badSuite = & $exe -NoProfile -File (Join-Path $repo 'sitecheck/tests/Test-SiteCheck.ps1') -Script $shim 2>&1 | Out-String; $exitCode = $LASTEXITCODE } finally { $env:TEMP=$oldTemp }
  Check ($badSuite -match 'RESULT \d+ passed, ([1-9]\d*) failed' -and $exitCode -eq [int]$Matches[1]) 'SiteCheck assertion failures become a nonzero suite exit code'

  . (Join-Path $PSScriptRoot 'TestPython.ps1'); $py = Get-TestPython
  $scenario = & $py (Join-Path $PSScriptRoot 'review225/scenarios.py') --repo $repo --powershell $exe 2>&1 | Out-String
  if ($LASTEXITCODE -ne 0) { throw $scenario }
  $result = $scenario | ConvertFrom-Json
  Check ($result.retarget_exit -eq 0 -and $result.retarget_camera_password -and $result.retarget_channel_password -and $result.retarget_saved_nvr) 'live recorder retarget updates camera operations, channel credentials and saved associations'
  Check ($result.interrupted_attempt_only -and $result.undo_exit -eq 0 -and $result.undo_restored_password -and $result.undo_marker) 'killing a real fix after its password write still allows Undo to restore the original password'
} catch { $script:fail++; Write-Host ('FAIL unexpected error: ' + $_.Exception.Message + ' at ' + $_.InvocationInfo.ScriptLineNumber) }
finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host ('Test-Review225: ' + $script:pass + ' passed, ' + $script:fail + ' failed')
exit $script:fail
