<#
 ToolkitMigrate.ps1 - WireIt Toolkit 2.2.4: the installer's clean-up of a 2.2.x PC (dot-sourced by Install-Toolkit.ps1; Windows PowerShell 5.1).
 Crew is a local admin and nothing runs as SYSTEM any more. On a PC that had 2.2.0-2.2.2 this removes, once, and logs each thing it removed:
   - the SYSTEM scheduled task "\WireIt\Fix this site"
   - the old IPC folder (Toolkit\ipc) and the files only the SYSTEM design used
   - the 2.2.x folder lock (inheritance turned off on the tool folders) -> Windows' normal permissions again,
     EXCEPT vault\ and secrets\: those are never reset; they are (re)locked to Administrators + SYSTEM + the installing owner only.
 2.2.4 (#26): secrets\upload-key.bin also gets READ for each local admin USER account (by its own SID), so a Toolkit started without
 "Run as administrator" (UAC: the Administrators group is deny-only then) can still read the upload key.
 Every Windows call goes through $Ops (a hashtable of scriptblocks) so a test can run all of it against a mock. Running it again changes nothing
 that is already right and logs "nothing to remove".
#>
$script:TkSidAdmins = 'S-1-5-32-544'; $script:TkSidSystem = 'S-1-5-18'
$script:TkOldTask = '\WireIt\Fix this site'
$script:TkOldFiles = @('FixSiteIpc.ps1', 'FixSiteRunner.ps1', 'FixSiteAsk.ps1', 'HikPortalStep.ps1', 'WireItAcl.ps1')
$script:TkSecretDirs = @('vault', 'secrets')
function Get-TkSecretLockArgs([string]$dir, [string]$ownerSid) {
  $a = @($dir, '/inheritance:r', '/grant:r', ('*' + $script:TkSidAdmins + ':(OI)(CI)F'), ('*' + $script:TkSidSystem + ':(OI)(CI)F'))
  if ($ownerSid -and $ownerSid -ne $script:TkSidAdmins -and $ownerSid -ne $script:TkSidSystem) { $a += ('*' + $ownerSid + ':(OI)(CI)F') }
  return ,[string[]]($a + @('/C', '/Q'))
}
function Get-TkKeyReadArgs([string]$file, [string]$userSid) { return ,[string[]]@($file, '/grant', ('*' + $userSid + ':R'), '/C', '/Q') }
function Get-TkRealOps {
  return @{
    # 2.2.21 (garage trial F23): on Windows PowerShell 5.1 with $ErrorActionPreference Stop, schtasks' own stderr ("ERROR: The system cannot
    # find the file specified." = no such task) became a terminating error and the installer warned "the 2.2.x clean-up did not run" on
    # every PC that never had the old task. The query/delete run with Continue for the call only; the exit code decides (a missing task =
    # nothing to clean, no warning).
    taskExists = { param($n) $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'; try { $null = & schtasks.exe /Query /TN $n 2>&1 } catch { $global:LASTEXITCODE = 1 } finally { $ErrorActionPreference = $eap }; return ($LASTEXITCODE -eq 0) }
    taskDelete = { param($n) $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'; try { $null = & schtasks.exe /Delete /TN $n /F 2>&1 } catch { $global:LASTEXITCODE = 1 } finally { $ErrorActionPreference = $eap }; return ($LASTEXITCODE -eq 0) }
    icacls     = { param([string[]]$a) $null = & icacls.exe @a 2>&1; return [int]$LASTEXITCODE }
    isLocked   = { param($p) try { return [bool](Get-Acl -LiteralPath $p).AreAccessRulesProtected } catch { return $null } }   # 2.2.19 (class C): unread = $null, not "not locked"
    adminUsers = { try { return @(Get-LocalGroupMember -SID $script:TkSidAdmins -ErrorAction Stop | Where-Object { $_.ObjectClass -eq 'User' } | ForEach-Object { [string]$_.SID.Value }) } catch { return @() } }
    exists     = { param($p) return (Test-Path -LiteralPath $p) }
    create     = { param($p) New-Item -ItemType Directory -Force -Path $p -ErrorAction Stop | Out-Null }
    remove     = { param($p) Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop }
    children   = { param($p) return @(Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }) }
  }
}
function Invoke-TkMigration {
  param([string]$Root, [string]$ToolkitDir, [string]$OwnerSid, [hashtable]$Ops = $null)
  if (-not $Ops) { $Ops = Get-TkRealOps }
  $log = New-Object System.Collections.ArrayList; $warn = New-Object System.Collections.ArrayList
  $J = { param($a, $b) return ($a.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar + $b) }
  # 1) the SYSTEM task
  if (& $Ops.taskExists $script:TkOldTask) {
    if (& $Ops.taskDelete $script:TkOldTask) { [void]$log.Add('Removed the old SYSTEM task "' + $script:TkOldTask + '".') } else { [void]$warn.Add('Could not remove the old task "' + $script:TkOldTask + '" (Task Scheduler > WireIt): delete it by hand.') }
  }
  # 2) the IPC folder and the files only the SYSTEM design used
  $ipc = & $J $ToolkitDir 'ipc'
  if (& $Ops.exists $ipc) { try { & $Ops.remove $ipc; [void]$log.Add('Removed the old IPC folder ' + $ipc + '.') } catch { [void]$warn.Add('Could not remove ' + $ipc + ': ' + $_.Exception.Message) } }
  foreach ($f in $script:TkOldFiles) { $p = & $J $ToolkitDir $f; if (& $Ops.exists $p) { try { & $Ops.remove $p; [void]$log.Add('Removed the old file ' + $f + '.') } catch { [void]$warn.Add('Could not remove ' + $p) } } }
  # 3) the 2.2.x folder lock: only where it is still on (inheritance off on a tool folder); vault\ and secrets\ are never reset
  $secret = @($script:TkSecretDirs | ForEach-Object { & $J $ToolkitDir $_ })
  foreach ($t in @('Toolkit', 'FixNVR', 'CamReset', 'NetCheck')) {
    $d = $(if ($t -eq 'Toolkit') { $ToolkitDir } else { & $J $Root $t })
    if (-not (& $Ops.exists $d)) { continue }
    $lk = & $Ops.isLocked $d
    if ($null -eq $lk) { [void]$warn.Add('Could not read the permissions of ' + $d + ': the old 2.2.x folder lock there is NOT CHECKED. Run the Toolkit installer again as administrator.'); continue }
    if (-not $lk) { continue }
    $bad = 0
    if ($t -eq 'Toolkit') {
      $bad += [int]((& $Ops.icacls ([string[]]@($d, '/reset', '/C', '/Q'))) -ne 0)
      foreach ($ch in @(& $Ops.children $d)) { if ($secret -contains $ch) { continue }; $bad += [int]((& $Ops.icacls ([string[]]@($ch, '/reset', '/T', '/C', '/Q'))) -ne 0) }
    } else { $bad += [int]((& $Ops.icacls ([string[]]@($d, '/reset', '/T', '/C', '/Q'))) -ne 0) }
    if ($bad) { [void]$warn.Add('Could not put the normal permissions back on everything in ' + $d + ' (icacls failed ' + $bad + ' time(s)).') } else { [void]$log.Add('Removed the old 2.2.x folder lock on ' + $d + ' (vault\ and secrets\ kept locked).') }
  }
  # 4) vault\ and secrets\: Administrators + SYSTEM + the installing owner only (every run: cheap, and repairs a loosened one)
  foreach ($sd in $secret) {
    if (-not (& $Ops.exists $sd)) {
      try {
        if ($Ops.ContainsKey('create')) { & $Ops.create $sd } else { New-Item -ItemType Directory -Force -Path $sd -ErrorAction Stop | Out-Null }
      } catch { throw ('Cannot create the private password folder ' + $sd + ': ' + $_.Exception.Message) }
    }
    if ((& $Ops.icacls (Get-TkSecretLockArgs $sd $OwnerSid)) -ne 0) { [void]$warn.Add('Could not lock ' + $sd + ' to administrators + SYSTEM + you.') }
  }
  # 5) #26: the upload key readable by each local admin USER without elevation (that one file only)
  $key = & $J (& $J $ToolkitDir 'secrets') 'upload-key.bin'
  if (& $Ops.exists $key) {
    $users = @(@(& $Ops.adminUsers) + @($OwnerSid) | Where-Object { $_ -and $_ -ne $script:TkSidAdmins -and $_ -ne $script:TkSidSystem } | Select-Object -Unique)
    foreach ($u in $users) { if ((& $Ops.icacls (Get-TkKeyReadArgs $key $u)) -ne 0) { [void]$warn.Add('Could not give ' + $u + ' read on the upload key.') } }
  }
  if (-not $log.Count) { [void]$log.Add('2.2.x clean-up: nothing to remove (already clean).') }
  return [pscustomobject]@{ log = @($log); warnings = @($warn) }
}
