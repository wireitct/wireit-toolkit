<#
 WireItAcl.ps1 - WireIt Toolkit 2.2.0: who may touch what under C:\WireIt, and the admin-made "Fix this site" task. Used by Install-Toolkit.ps1.
 Review H1 (Nov 7 2026): a folder made under C:\ gave "Authenticated Users: Modify", so the Crew login could edit scripts that later run as admin
 (the UAC window) or as SYSTEM (the camera-pictures task, the Fix NVR clean-up task, now the "Fix this site" task) - and config.json, whose
 "bitwardenCli" is a program the elevated run starts.
 After this: Administrators + SYSTEM = full control; Crew (Users) = read + execute on the whole tool folders, and Modify ONLY on the folders
 the Crew-run tools have to write to (logs, outbox, state, runs, ipc, inbox, CamReset out/replies/requests/state).
 vault\ (the site password store) = Administrators + SYSTEM only. Renaming or deleting Toolkit\ is not possible for Crew either: the
 folder gives Users neither DELETE nor delete-child, and C:\ gives "Modify" on C:\WireIt, which has no delete-child.
 Everything is a plan (a list of icacls argument arrays) that a test can read without Windows; Invoke-WireItAclPlan runs it.
#>
$script:SidAdmins = '*S-1-5-32-544'; $script:SidSystem = '*S-1-5-18'; $script:SidUsers = '*S-1-5-32-545'; $script:SidAuth = '*S-1-5-11'
# Crew-writable data folders, relative to C:\WireIt (everything else under the tool folders is read + execute only)
$script:WireItCrewWritable = @('Toolkit\logs', 'Toolkit\outbox', 'Toolkit\state', 'Toolkit\runs', 'Toolkit\ipc', 'Toolkit\inbox', 'CamReset\out', 'CamReset\replies', 'CamReset\requests', 'CamReset\state')
$script:WireItAdminOnly = @('Toolkit\vault')
function Wa-Join([string]$a, [string]$b) { return ($a.TrimEnd('\', '/') + '\' + $b) }   # plain text join: the plan is read on any OS
function Get-WireItAclPlan([string]$Root = 'C:\WireIt') {
  $plan = New-Object System.Collections.ArrayList
  $add = { param($path, $a, $why) [void]$plan.Add([pscustomobject]@{ path = $path; args = [string[]]$a; why = $why }) }
  foreach ($t in @('Toolkit', 'FixNVR', 'CamReset', 'NetCheck')) {
    $d = Wa-Join $Root $t
    & $add $d @($d, '/remove:g', $script:SidAuth, $script:SidUsers, '/T', '/C') ('clear any old grant to Authenticated Users / Users inside ' + $t)
    & $add $d @($d, '/inheritance:r', '/grant:r', ($script:SidAdmins + ':(OI)(CI)F'), ($script:SidSystem + ':(OI)(CI)F'), ($script:SidUsers + ':(OI)(CI)RX')) ($t + ': Administrators + SYSTEM full control, Crew read + execute only')
  }
  foreach ($rel in $script:WireItCrewWritable) {
    $d = Wa-Join $Root $rel
    # Modify on what is INSIDE (inherit-only), and only list / add files / add folders on the folder itself: Crew cannot delete, rename or
    # swap the folder for a link to somewhere else (the SYSTEM runner writes in ipc\ and inbox\)
    & $add $d @($d, '/grant', ($script:SidUsers + ':(OI)(CI)(IO)M'), ($script:SidUsers + ':(RX,WD,AD)')) ('Crew may write here: ' + $rel)
  }
  foreach ($rel in $script:WireItAdminOnly) {
    $d = Wa-Join $Root $rel
    & $add $d @($d, '/inheritance:r', '/grant:r', ($script:SidAdmins + ':(OI)(CI)F'), ($script:SidSystem + ':(OI)(CI)F')) ($rel + ': Administrators + SYSTEM only (the machine-wide DPAPI store)')
  }
  return ,@($plan.ToArray())
}
# makes the folders the plan needs, then runs it. $Run = { param([string[]]$IcaclsArgs) -> exit code } (tests pass a recorder). Returns { ok; failed = @(why) }.
function Invoke-WireItAclPlan([string]$Root = 'C:\WireIt', [scriptblock]$Run = $null) {
  if (-not $Run) { $Run = { param($a) & icacls.exe @a 2>&1 | Out-Null; return $LASTEXITCODE } }
  $failed = @()
  foreach ($rel in ($script:WireItCrewWritable + $script:WireItAdminOnly + @('Toolkit\inbox\hik'))) { if (-not $env:WIREIT_ACL_TEST) { New-Item -ItemType Directory -Force -Path (Join-Path $Root $rel) -ErrorAction SilentlyContinue | Out-Null } }
  foreach ($s in (Get-WireItAclPlan $Root)) {
    if (-not $env:WIREIT_ACL_TEST -and -not (Test-Path -LiteralPath $s.path)) { continue }   # a tool that is not on this PC
    $code = 1; try { $code = [int](& $Run $s.args) } catch { $code = 1 }
    if ($code -ne 0) { $failed += $s.why }
  }
  return [pscustomobject]@{ ok = ($failed.Count -eq 0); failed = @($failed) }
}

# ---------------- the "Fix this site" task (Crew may START it; only admins may change it) ----------------
# SDDL: Administrators + SYSTEM full control; Users: read + execute (= run on demand). Nothing for Everyone/Authenticated Users to edit.
$script:WireItTaskSddl = 'D:(A;;FA;;;BA)(A;;FA;;;SY)(A;;GRGX;;;BU)'
function Get-WireItRunnerTaskXml([string]$ToolkitDir) {
  $ps = '%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe'
  $arg = '-NoProfile -ExecutionPolicy Bypass -File "' + (Wa-Join $ToolkitDir 'FixSiteRunner.ps1') + '" -ToolkitDir "' + $ToolkitDir + '"'
  $esc = { param($s) [Security.SecurityElement]::Escape($s) }
  return ('<?xml version="1.0" encoding="UTF-16"?>' +
    '<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><RegistrationInfo><Description>WireIt Toolkit: Fix this site for the Crew login (no admin password). Started on demand from the Toolkit window; runs FixSiteRunner.ps1 as SYSTEM.</Description></RegistrationInfo>' +
    '<Triggers/><Principals><Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>' +
    '<Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><AllowHardTerminate>true</AllowHardTerminate><StartWhenAvailable>true</StartWhenAvailable><AllowStartOnDemand>true</AllowStartOnDemand><Enabled>true</Enabled><Hidden>false</Hidden><ExecutionTimeLimit>PT4H</ExecutionTimeLimit><Priority>6</Priority></Settings>' +
    '<Actions Context="Author"><Exec><Command>' + (& $esc $ps) + '</Command><Arguments>' + (& $esc $arg) + '</Arguments><WorkingDirectory>' + (& $esc $ToolkitDir) + '</WorkingDirectory></Exec></Actions></Task>')
}
# registers (or replaces) the task and sets who may run it. $Run = { param([string[]]$a) -> exit code } for schtasks (tests record). Returns { ok; why }.
function Register-WireItRunnerTask([string]$ToolkitDir, [scriptblock]$Run = $null, [scriptblock]$SetSd = $null) {
  if (-not $Run) { $Run = { param($a) & schtasks.exe @a 2>&1 | Out-Null; return $LASTEXITCODE } }
  if (-not $SetSd) { $SetSd = { param($name, $sddl) $svc = New-Object -ComObject 'Schedule.Service'; $svc.Connect(); $f = $svc.GetFolder('\WireIt'); $t = $f.GetTask('Fix this site'); $t.SetSecurityDescriptor($sddl, 0) } }
  $xml = Join-Path ([IO.Path]::GetTempPath()) ('wireit-task-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.xml')
  try {
    [IO.File]::WriteAllText($xml, (Get-WireItRunnerTaskXml $ToolkitDir), [Text.Encoding]::Unicode)
    $c = [int](& $Run @('/Create', '/F', '/TN', '\WireIt\Fix this site', '/XML', $xml))
    if ($c -ne 0) { return [pscustomobject]@{ ok = $false; why = ('schtasks /Create answered ' + $c) } }
    try { & $SetSd '\WireIt\Fix this site' $script:WireItTaskSddl } catch { return [pscustomobject]@{ ok = $false; why = ('the task was made, but who may run it was not set: ' + $_.Exception.Message) } }
    return [pscustomobject]@{ ok = $true; why = '' }
  } finally { Remove-Item -LiteralPath $xml -Force -ErrorAction SilentlyContinue }
}

# ---------------- review H2: the site-password word that older runs wrote to a log ----------------
# 2.1.0 asked for the word with a visible prompt and wrote "ANSWER <word>" under the ASK line. This blanks that one line in every old log.
# Returns how many lines were blanked.
function Clear-WordAnswerFromLogs([string[]]$LogRoots) {
  $n = 0
  foreach ($r in @($LogRoots)) {
    if (-not $r -or -not (Test-Path -LiteralPath $r)) { continue }
    foreach ($f in @(Get-ChildItem -LiteralPath $r -Recurse -Filter 'log.txt' -File -ErrorAction SilentlyContinue)) {
      try {
        $lines = [IO.File]::ReadAllLines($f.FullName); $chg = $false
        for ($i = 0; $i -lt $lines.Count - 1; $i++) {
          if ($lines[$i] -match 'ASK Site passwords start with your word' -and $lines[$i + 1] -match '^(\d\d:\d\d:\d\d )?ANSWER (?!\(hidden\))') { $lines[$i + 1] = ($Matches[1] + 'ANSWER (hidden)'); $chg = $true; $n++ }
        }
        if ($chg) { [IO.File]::WriteAllLines($f.FullName, $lines) }
      } catch {}
    }
  }
  return $n
}
