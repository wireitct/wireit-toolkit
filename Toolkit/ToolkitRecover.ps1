# Startup recovery is independent of ToolkitCore.ps1: that file may have been interrupted by an older updater.
# All live replacements use a complete sibling temporary file and one atomic filesystem replacement.
function Copy-TkAtomicFile([string]$src, [string]$dst, [string]$hash = '') {
  $ErrorActionPreference = 'Stop'
  $tmp = $dst + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
  try {
    Copy-Item -LiteralPath $src -Destination $tmp -Force -ErrorAction Stop
    if (-not $hash) { $hash = (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash }
    if ((Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash -ne $hash) { throw ('Copy check failed for ' + $dst) }
    $flush = [IO.File]::Open($tmp, 'Open', 'Write', 'None'); try { $flush.Flush($true) } finally { $flush.Dispose() }
    if ([IO.File]::Exists($dst)) { [IO.File]::Replace($tmp, $dst, [System.Management.Automation.Language.NullString]::Value) } else { [IO.File]::Move($tmp, $dst) }
  } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}
function Invoke-TkStartupRecovery([string]$toolkitDir) {
  $root = Split-Path -Parent $toolkitDir
  $journal = Join-Path $toolkitDir 'previous/update-pending.json'
  if (-not (Test-Path -LiteralPath $journal)) { return '' }
  $j = $null; try { $j = [IO.File]::ReadAllText($journal) | ConvertFrom-Json -ErrorAction Stop } catch {}
  if (-not $j -or -not $j.prev -or -not (Test-Path -LiteralPath ([string]$j.prev))) { throw 'An earlier update stopped half-way and its saved copy is missing. Run the Toolkit installer again.' }
  $prev = [string]$j.prev; $bad = @()
  foreach ($fi in @(Get-ChildItem -LiteralPath $prev -Recurse -File | Where-Object { $_.Name -notin @('undo.json', 'version.json.prev') })) {
    $rel = $fi.FullName.Substring($prev.Length).TrimStart('\', '/')
    $dst = Join-Path $root $rel
    try { New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) -ErrorAction Stop | Out-Null; Copy-TkAtomicFile $fi.FullName $dst } catch { $bad += $rel }
  }
  foreach ($a in @($j.added)) {
    if (-not $a) { continue }
    $dst = Join-Path $root ([string]$a)
    try { if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Force -ErrorAction Stop } } catch { $bad += [string]$a }
  }
  $vp = Join-Path $prev 'version.json.prev'
  try { if (Test-Path -LiteralPath $vp) { Copy-TkAtomicFile $vp (Join-Path $toolkitDir 'version.json') } } catch { $bad += 'version.json' }
  if ($bad.Count) { throw ('An earlier update could not be put back: ' + ($bad -join ', ') + '. Run the Toolkit installer again.') }
  Remove-Item -LiteralPath $journal -Force -ErrorAction Stop
  return ('An earlier update to ' + $j.to + ' stopped half-way, so version ' + $j.from + ' was put back.')
}
