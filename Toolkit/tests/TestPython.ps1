<#
 TestPython.ps1 - one shared way for the tests to find a REAL Python 3 (2.2.5). Dot-source it, then:  $py = Get-TestPython
 Order: "py -3" (the Windows launcher), then "python", then "python3". Each one is RUN once (-c "import sys; print(sys.executable)")
 and only kept when it exits 0 and names a real interpreter. On Windows "python3"/"python" are often the Microsoft Store stub in
 ...\Microsoft\WindowsApps\ ("Python was not found ...", exit 9009): it fails the run, so it is never picked.
 Returns the full path of the interpreter itself (sys.executable), so callers start it with no extra arguments; '' when none works.
#>
function Test-TestPythonCandidate([string]$exe, [string[]]$pre) {
  try {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $args1 = @($pre) + @('-c', '"import sys; assert sys.version_info[0] == 3; print(sys.executable)"')
    $psi.Arguments = (($args1 | Where-Object { $_ }) -join ' ')
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync(); $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit(15000)) { try { $p.Kill() } catch { }; return '' }
    $out = ([string]$outTask.Result).Trim()
    if ($p.ExitCode -ne 0 -or -not $out) { return '' }
    $real = ($out -split "`r?`n")[-1].Trim()
    if (-not $real -or -not (Test-Path -LiteralPath $real)) { return '' }
    return $real
  } catch { return '' }
}
function Get-TestPython {
  if ($script:TestPythonCache) { return $script:TestPythonCache }
  $onWin = ($env:OS -eq 'Windows_NT')
  $tries = @()
  if ($onWin) { $tries += ,@('py', '-3') }
  $tries += ,@('python', ''); $tries += ,@('python3', '')
  foreach ($t in $tries) {
    $cmds = @(Get-Command $t[0] -CommandType Application -All -ErrorAction SilentlyContinue)
    foreach ($c in $cmds) {
      $src = [string]$c.Source
      if (-not $src) { continue }
      $real = Test-TestPythonCandidate $src @($t[1])
      if (-not $real) { continue }
      if ($onWin -and $real -match '\\Microsoft\\WindowsApps\\' -and $real -notmatch 'PythonSoftwareFoundation') { continue }   # the Store stub (or an alias of it)
      $script:TestPythonCache = $real
      return $real
    }
  }
  return ''
}
