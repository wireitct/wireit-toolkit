<#
 Build-Manifest.ps1 - writes version.json (the update manifest) from the files git tracks on this branch (2.2.5: without git, from the
 checked-in tools/shipped-files.txt inventory).
 Not shipped (tools\ is outside the Toolkit's allowed folders). Windows PowerShell 5.1 or pwsh 7.
 Usage: powershell -File tools\Build-Manifest.ps1 -Commit <40-hex commit that holds exactly these files> [-Released yyyy-MM-dd] [-Notes '...']
 The commit must be the one whose files are listed (commit the code first, then build the manifest naming that commit, then commit version.json):
 the update downloads every file from raw.githubusercontent.com/<repo>/<commit>/ and checks each SHA-256.
 The version is the code's own ($script:TkBuiltVersion in Toolkit\ToolkitCore.ps1), so the manifest can never claim another version.
#>
param(
  [Parameter(Mandatory = $true)][string]$Commit,
  [string]$Released = (Get-Date -Format 'yyyy-MM-dd'),
  [string]$Notes = '',
  [string]$Repo = '',
  [string]$Out = '',
  [string]$RawBase = 'https://raw.githubusercontent.com/wireitct/wireit-toolkit/'
)
$ErrorActionPreference = 'Stop'
if (-not $Repo) { $Repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
if (-not $Out) { $Out = Join-Path $Repo 'version.json' }
if ($Commit -notmatch '^[0-9a-f]{40}$') { throw 'Commit must be the full 40-character commit id' }
$core = [IO.File]::ReadAllText((Join-Path $Repo 'Toolkit\ToolkitCore.ps1'))
$m = [regex]::Match($core, "\`$script:TkBuiltVersion\s*=\s*'([0-9]+\.[0-9]+\.[0-9]+)'"); if (-not $m.Success) { throw 'TkBuiltVersion not found in ToolkitCore.ps1' }
$version = $m.Groups[1].Value
$m2 = [regex]::Match($core, "\`$script:TkAllowedTop\s*=\s*@\(([^)]*)\)"); if (-not $m2.Success) { throw 'TkAllowedTop not found in ToolkitCore.ps1' }
$tops = @([regex]::Matches($m2.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
if (-not $Notes -and (Test-Path $Out)) { try { $old = [IO.File]::ReadAllText($Out) | ConvertFrom-Json; if ([string]$old.version -eq $version) { $Notes = [string]$old.notes } } catch {} }
# An exported tree has no git index. Its checked-in release inventory is the authority, never arbitrary files a tool created on disk.
function Get-BmDiskFiles([string]$root, [string[]]$tops) {
  $inventory = Join-Path $root 'tools/shipped-files.txt'
  if (-not (Test-Path -LiteralPath $inventory)) { throw 'tools/shipped-files.txt is missing. Build from a complete source export, not an installed PC folder.' }
  foreach ($p in @(Get-Content -LiteralPath $inventory | Where-Object { $_ -and -not $_.StartsWith('#') })) {
    if ($p -match '\.\.|[\\:]|^/' -or $tops -notcontains ($p -split '/')[0]) { throw ('Invalid release inventory path: ' + $p) }
    if (-not (Test-Path -LiteralPath (Join-Path $root $p) -PathType Leaf)) { throw ('Release file missing: ' + $p) }
    $p
  }
}
$list = $null
$git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($git -and (Test-Path -LiteralPath (Join-Path $Repo '.git'))) {
  $list = @(& $git.Source -C $Repo ls-files 2>$null)
  if ($LASTEXITCODE -ne 0) { Write-Host 'git ls-files failed - listing the files on disk instead' -ForegroundColor Yellow; $list = $null }
} else { Write-Host 'git is not on this PC (or this is not a clone) - listing the files on disk instead' -ForegroundColor Yellow }
if ($null -eq $list) { $list = @(Get-BmDiskFiles $Repo $tops) }
$sha = [Security.Cryptography.SHA256]::Create()
$files = @()
foreach ($p in ($list | Sort-Object)) {
  $top = ($p -split '/')[0]
  if ($tops -notcontains $top) { continue }
  $full = Join-Path $Repo ($p -replace '/', [IO.Path]::DirectorySeparatorChar)
  $bytes = [IO.File]::ReadAllBytes($full)
  $h = -join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') })
  $files += [ordered]@{ path = $p; sha256 = $h; size = $bytes.Length }
}
$man = [ordered]@{ version = $version; released = $Released; commit = $Commit; base = ($RawBase + $Commit + '/'); notes = $Notes; files = $files }
$json = ($man | ConvertTo-Json -Depth 5)
[IO.File]::WriteAllText($Out, $json + "`n", (New-Object Text.UTF8Encoding($false)))
Write-Host ('version.json: ' + $version + ', ' + $files.Count + ' files, commit ' + $Commit)
