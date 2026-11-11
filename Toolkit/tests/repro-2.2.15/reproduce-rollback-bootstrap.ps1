# Codex 2.2.15 F2 (adapted from the reviewer's reproduce-rollback-bootstrap.ps1): a Go back stopped right after the INSTALLED
# recovery loader (ToolkitRecover.ps1) was swapped for the older version's copy. The next start sources the installed (old) loader,
# exactly as WireItToolkit.ps1 does. Safe outcome: the old version is back, the version being left is in skip-version.txt, and the
# start-up update check would NOT re-install it on its own; the notice names the right versions.
# -Repo = the checkout under test (the version being LEFT); -OldRepo = the older checkout whose files the saved copy holds.
param([string]$Repo = '', [string]$OldRepo = '', [string]$KillAt = 'ToolkitRecover.ps1', [switch]$Child, [string]$Root = '')
if (-not $Repo) { $Repo = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path }
# the older version's files: -OldRepo <2.2.14 checkout>, else the unchanged 2.2.14 copies kept next to this script (old-2.2.14\*.ps1.txt)
function Get-OldFile([string]$name) { if ($OldRepo) { return (Join-Path $OldRepo "Toolkit/$name") } ; return (Join-Path (Join-Path $PSScriptRoot 'old-2.2.14') ($name + '.txt')) }
$pwshExe = $(if ($PSVersionTable.PSEdition -eq 'Core') { (Get-Process -Id $PID).Path } else { Join-Path $PSHOME 'powershell.exe' })
function New-Fixture([string]$root) {
  $tk = Join-Path $root 'Toolkit'; $prev = Join-Path $tk 'previous/2.2.14'
  [void][IO.Directory]::CreateDirectory((Join-Path $prev 'Toolkit'))
  foreach ($name in 'ToolkitCore.ps1', 'ToolkitRecover.ps1') {
    [IO.File]::Copy((Join-Path $Repo "Toolkit/$name"), (Join-Path $tk $name), $true)
    [IO.File]::Copy((Get-OldFile $name), (Join-Path $prev "Toolkit/$name"), $true)
  }
  [IO.File]::WriteAllText((Join-Path $tk 'version.json'), '{"version":"2.2.15","previous":"2.2.14"}')
  [IO.File]::WriteAllText((Join-Path $prev 'version.json.prev'), '{"version":"2.2.14"}')
  [IO.File]::WriteAllText((Join-Path $prev 'undo.json'), '{"added":[]}')
  return $tk
}
if ($Child) {
  $tk = Join-Path $Root 'Toolkit'
  . "$Repo/Toolkit/ToolkitCore.ps1"
  $script:KillName = $KillAt
  function Copy-TkAtomicFile([string]$src, [string]$dst, [string]$hash = '') {
    [IO.File]::WriteAllBytes($dst, [IO.File]::ReadAllBytes($src))
    if ($script:KillName -and (Split-Path -Leaf $dst) -eq $script:KillName) { [Environment]::Exit(9) }
  }
  Undo-TkUpdate $tk | Out-Null
  exit 0
}
$p = 0; $f = 0
function Chk([bool]$ok, [string]$what) { if ($ok) { "PASS $what"; $script:p++ } else { "FAIL $what"; $script:f++ } }
function Run-Case([string]$kill) {
  $root = Join-Path ([IO.Path]::GetTempPath()) ('repro2216-bootstrap-' + [guid]::NewGuid().ToString('N'))
  $tk = New-Fixture $root
  & $pwshExe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Child -Repo $Repo -KillAt $kill -Root $root | Out-Null
  $killed = $LASTEXITCODE
  # the start-up side runs as a script FILE (-File), never -Command / -EncodedCommand
  $sf = Join-Path $root 'startup.ps1'
  [IO.File]::WriteAllText($sf, @'
param([string]$tk)
    $notice = ''; $err = ''
    try { . (Join-Path $tk 'ToolkitRecover.ps1'); $notice = [string](Invoke-TkStartupRecovery $tk) } catch { $err = $_.Exception.Message }
    . (Join-Path $tk 'ToolkitCore.ps1')
    function Get-TkWeb { param($url, $timeoutMs); return [Text.Encoding]::UTF8.GetBytes('{"version":"2.2.15","base":"https://raw.githubusercontent.com/wireitct/wireit-toolkit/95a764fcdca33d8b9fba693faab429db514f289c/","files":[{"path":"Toolkit/a.ps1","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}') }
    $cfg = Get-TkConfig $tk; $u = Get-TkUpdateInfo $cfg $tk; $skip = Get-TkSkipVersion $tk
    [pscustomobject]@{ notice = $notice; err = $err; version = (Get-TkVersion $tk); skip = $skip; updateState = $u.state; autoUpdate = $cfg.autoUpdate
      wouldReinstall = ($u.state -eq 'available' -and $cfg.autoUpdate -and [string]$u.manifest.version -ne $skip)
      journal = (Test-Path -LiteralPath (Join-Path $tk 'previous/update-pending.json')) } | ConvertTo-Json -Compress
  
'@)
  $res = & $pwshExe -NoProfile -ExecutionPolicy Bypass -File $sf -tk $tk
  try { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue } catch {}
  $o = $null; try { $o = (@($res) -join '') | ConvertFrom-Json } catch {}
  return @{ killed = $killed; o = $o; raw = (@($res) -join '') }
}
foreach ($kill in @('ToolkitRecover.ps1', 'ToolkitCore.ps1', '')) {
  $r = Run-Case $kill; $o = $r.o
  $tag = $(if ($kill) { 'stopped right after ' + $kill + ' was swapped' } else { 'control: Go back not stopped' })
  'REPRO=' + $tag + ' killedExit=' + $r.killed + ' ' + $r.raw
  if (-not $o) { Chk $false ($tag + ': recovery produced a readable result'); continue }
  if ($kill) { Chk ($r.killed -eq 9) ($tag + ': the Go back really was stopped at that file') }
  Chk ([string]$o.version -eq '2.2.14') ($tag + ': the older version 2.2.14 is in place (got ' + $o.version + ')')
  Chk ([string]$o.skip -eq '2.2.15') ($tag + ': the version being left (2.2.15) is in skip-version.txt (got "' + $o.skip + '")')
  Chk (-not $o.wouldReinstall) ($tag + ': the start-up update check would NOT re-install 2.2.15 on its own')
  Chk (-not $o.journal) ($tag + ': no half-done journal is left behind')
  if ($kill) { Chk ([string]$o.notice -notmatch 'version 2\.2\.15 (was|is) (put )?back' -and [string]$o.notice -match '2\.2\.14') ($tag + ': the start-up notice names 2.2.14 as the version put back ("' + $o.notice + '")') }
}
"$p passed, $f failed"
if ($f) { exit 1 } else { exit 0 }
