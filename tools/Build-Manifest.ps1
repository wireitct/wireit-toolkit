<#
 Build-Manifest.ps1 - writes version.json (the update manifest) from the files git tracks on this branch.
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
$list = @(& git -C $Repo ls-files)
if ($LASTEXITCODE -ne 0) { throw 'git ls-files failed' }
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
