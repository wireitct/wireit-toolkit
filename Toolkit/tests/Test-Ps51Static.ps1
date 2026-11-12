<# Test-Ps51Static.ps1 - WireIt Toolkit 2.2.20 (Nov 11 2026). STATIC (source/parse) check, not a scenario test: every
 PowerShell file in the repo (*.ps1, *.psm1, shipped code AND tests) is parsed and searched for constructs that Windows PowerShell 5.1
 cannot run. Each rule is ONE check over the whole repo (it lists every offender); a detector self-test first proves each rule
 catches a planted sample, so a rule that silently matches nothing cannot pass. This does NOT prove 5.1 behaviour: only a real
 Windows PowerShell 5.1 run does (DEFERRED here when powershell.exe is absent; on Windows it parses every file with 5.1 itself).
 Rules: ternary ?:, pipeline chains && ||, ?? and ??=, ?. and ?[] (null-conditional), clean{} blocks, ForEach-Object -Parallel,
 PS6+/7-only cmdlet parameters (ConvertFrom-Json -AsHashtable/-Depth/-NoEnumerate, ConvertTo-Json -AsArray/-EnumsAsStrings,
 Get/Set/Add-Content -AsByteStream, -Encoding utf8NoBOM/utf8BOM, Invoke-WebRequest/RestMethod -SkipCertificateCheck/
 -SkipHttpErrorCheck/-StatusCodeVariable/-ResponseHeadersVariable/-Authentication/-MaximumRetryCount, Split-Path -LeafBase/-Extension,
 Join-Path -AdditionalChildPath or a 3rd positional child, Get-Date -AsUTC/-UnixTimeSeconds, Select-String -Raw, Sort-Object -Top/-Bottom,
 Start-Process -Environment, Test-Connection -TargetName/-TcpPort), PS7-only cmdlets (Join-String, Get-Error, Test-Json,
 ConvertFrom-Markdown, Get-Uptime, Remove-Alias), .NET Core-only APIs ([Convert]::ToHexString/FromHexString, ::HashData,
 *Async file APIs, [IO.Path]::GetRelativePath/Join, [math]::Clamp, [Environment]::ProcessPath, System.Text.Json),
 "#requires -Version 6/7", $PSStyle, and FILE ENCODING: a file with non-ASCII bytes must start with a UTF-8 BOM (5.1 reads a
 BOM-less file as ANSI, so a UTF-8 dash or quote becomes cp1252 bytes and can end a string early).
 Usage: pwsh -File Test-Ps51Static.ps1 [-Repo <folder>]; env PS51STATIC_REPO works too. Exit code = failed checks. #>
param([string]$Repo = '')
$ErrorActionPreference = 'Stop'
if (-not $Repo) { $Repo = $env:PS51STATIC_REPO }
if (-not $Repo) { $Repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
$script:pass = 0; $script:fail = 0; $script:deferred = 0
function Check([bool]$ok, [string]$name, [string]$more = '') {
  if ($ok) { $script:pass++; Write-Host ('PASS ' + $name) } else { $script:fail++; Write-Host ('FAIL ' + $name); if ($more) { Write-Host ('     ' + $more.Substring(0, [math]::Min(3000, $more.Length))) } }
}
$paramRules = @(
  @{ cmd = 'ConvertFrom-Json'; p = @('AsHashtable', 'Depth', 'NoEnumerate') },
  @{ cmd = 'ConvertTo-Json'; p = @('AsArray', 'EnumsAsStrings', 'EscapeHandling') },
  @{ cmd = 'Get-Content'; p = @('AsByteStream') }, @{ cmd = 'Set-Content'; p = @('AsByteStream') }, @{ cmd = 'Add-Content'; p = @('AsByteStream') },
  @{ cmd = 'Invoke-WebRequest'; p = @('SkipCertificateCheck', 'SkipHttpErrorCheck', 'StatusCodeVariable', 'ResponseHeadersVariable', 'Authentication', 'MaximumRetryCount', 'RetryIntervalSec', 'Resume', 'NoProxy', 'HttpVersion', 'SslProtocol', 'Token', 'ConnectionTimeoutSeconds', 'OperationTimeoutSeconds') },
  @{ cmd = 'Invoke-RestMethod'; p = @('SkipCertificateCheck', 'SkipHttpErrorCheck', 'StatusCodeVariable', 'ResponseHeadersVariable', 'Authentication', 'MaximumRetryCount', 'RetryIntervalSec', 'Resume', 'NoProxy', 'HttpVersion', 'SslProtocol', 'Token', 'FollowRelLink', 'ConnectionTimeoutSeconds', 'OperationTimeoutSeconds') },
  @{ cmd = 'Split-Path'; p = @('LeafBase', 'Extension') }, @{ cmd = 'Join-Path'; p = @('AdditionalChildPath') },
  @{ cmd = 'Get-Date'; p = @('AsUTC', 'UnixTimeSeconds') }, @{ cmd = 'Select-String'; p = @('Raw', 'NoEmphasis') },
  @{ cmd = 'Sort-Object'; p = @('Top', 'Bottom', 'Stable') }, @{ cmd = 'Start-Process'; p = @('Environment') },
  @{ cmd = 'Test-Connection'; p = @('TargetName', 'TcpPort', 'Ping', 'Traceroute', 'MtuSize') },
  @{ cmd = 'Get-ChildItem'; p = @('FollowSymlink') }, @{ cmd = 'Format-Hex'; p = @('Count', 'Offset') },
  @{ cmd = 'ForEach-Object'; p = @('Parallel', 'ThrottleLimit', 'AsJob') }, @{ cmd = 'foreach'; p = @('Parallel') }, @{ cmd = '%'; p = @('Parallel') }
)
$ps7Cmds = @('Join-String', 'Get-Error', 'Test-Json', 'ConvertFrom-Markdown', 'Show-Markdown', 'Get-Uptime', 'Remove-Alias', 'Get-MarkdownOption', 'Set-MarkdownOption', 'Remove-Service', 'Clear-RecycleBin')
$netCore = '(?i)\[(System\.)?Convert\]::(To|From)HexString|::HashData\s*\(|\b(ReadAll(Bytes|Text|Lines)|WriteAll(Bytes|Text|Lines)|AppendAll(Text|Lines))Async\b|\[(System\.)?IO\.Path\]::(GetRelativePath|Join|TrimEndingDirectorySeparator|EndsInDirectorySeparator)\b|\[(System\.)?Math\]::Clamp\b|\[(System\.)?Environment\]::ProcessPath\b|System\.Text\.Json|\[(System\.)?String\]::Create\b|\.Contains\([^)]*StringComparison'
# 2.2.21 (Codex 2.2.20 test note): code held in a here-string ($SC_CODE in SiteCheck.ps1, run by [scriptblock]::Create) is code too.
# Get-Findings checks the file, then every here-string in it that parses as PowerShell without an error (a code block, not prose), and
# the here-strings inside those (3 levels). A finding inside one names the file line of the here-string and the line inside it.
function Get-Findings([string]$file, [string]$rule) {
  # the helpers live INSIDE Get-Findings, so a caller that loads only this function (Codex's repro does) gets the whole scanner
  function Get-HereStringFindings($ast, [string]$where, [string]$rule, [int]$depth) {
    if ($depth -gt 3) { return }
    $hs = @($ast.FindAll({ param($x) ($x -is [Management.Automation.Language.StringConstantExpressionAst] -and [string]$x.StringConstantType -match 'HereString') -or ($x -is [Management.Automation.Language.ExpandableStringExpressionAst] -and [string]$x.StringConstantType -match 'HereString') }, $true))
    foreach ($h in $hs) {
      $txt = [string]$h.Value; if (-not $txt.Trim()) { continue }
      $t2 = $null; $e2 = $null
      $a2 = [Management.Automation.Language.Parser]::ParseInput($txt, [ref]$t2, [ref]$e2)
      if (@($e2 | Where-Object { $_ }).Count) { continue }   # not code (prose, XML, a template): not scanned
      $w2 = ($where + ':' + $h.Extent.StartLineNumber + ' (inside a here-string)')
      foreach ($o in @(Get-FindingsAst $a2 $e2 $w2 $rule '')) { $o }
      foreach ($o in @(Get-HereStringFindings $a2 $w2 $rule ($depth + 1))) { $o }
    }
  }
  function Get-FindingsAst($ast, $err, [string]$rel, [string]$rule, [string]$file) {
    $out = @()
    switch ($rule) {
      'parse' { foreach ($e in @($err)) { if ($e) { $out += ('{0}:{1} {2}' -f $rel, $e.Extent.StartLineNumber, $e.Message) } } }
      'ternary' { foreach ($a in $ast.FindAll({ param($x) $x.GetType().Name -eq 'TernaryExpressionAst' }, $true)) { $out += ('{0}:{1} {2}' -f $rel, $a.Extent.StartLineNumber, $a.Extent.Text) } }
      'chain' { foreach ($a in $ast.FindAll({ param($x) $x.GetType().Name -eq 'PipelineChainAst' }, $true)) { $out += ('{0}:{1} {2}' -f $rel, $a.Extent.StartLineNumber, $a.Extent.Text) } }
      'coalesce' {
        foreach ($a in $ast.FindAll({ param($x) ($x -is [Management.Automation.Language.BinaryExpressionAst] -and [string]$x.Operator -eq 'QuestionQuestion') -or ($x -is [Management.Automation.Language.AssignmentStatementAst] -and [string]$x.Operator -eq 'QuestionQuestionEquals') }, $true)) { $out += ('{0}:{1} {2}' -f $rel, $a.Extent.StartLineNumber, $a.Extent.Text) }
      }
      'nullcond' {
        foreach ($a in $ast.FindAll({ param($x) $p = $x.PSObject.Properties['NullConditional']; ($p -and $p.Value) }, $true)) { $out += ('{0}:{1} {2}' -f $rel, $a.Extent.StartLineNumber, $a.Extent.Text) }
      }
      'clean' {
        foreach ($a in $ast.FindAll({ param($x) $x -is [Management.Automation.Language.ScriptBlockAst] }, $true)) { $p = $a.PSObject.Properties['CleanBlock']; if ($p -and $p.Value) { $out += ('{0}:{1} clean block' -f $rel, $a.Extent.StartLineNumber) } }
      }
      'params' {
        foreach ($c in $ast.FindAll({ param($x) $x -is [Management.Automation.Language.CommandAst] }, $true)) {
          $n = $c.GetCommandName(); if (-not $n) { continue }
          foreach ($r in $paramRules) {
            if ($n -ne $r.cmd) { continue }
            foreach ($e in $c.CommandElements) {
              if ($e -is [Management.Automation.Language.CommandParameterAst]) {
                foreach ($p in $r.p) { if ($p -ieq $e.ParameterName) { $out += ('{0}:{1} {2} -{3}' -f $rel, $c.Extent.StartLineNumber, $n, $e.ParameterName) } }
              }
            }
          }
          if ($n -eq 'Join-Path') {
            $pos = @($c.CommandElements | Select-Object -Skip 1 | Where-Object { $_ -isnot [Management.Automation.Language.CommandParameterAst] })
            $named = @($c.CommandElements | Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] })
            if ($pos.Count -ge 3 -or ($pos.Count -ge 2 -and $named.Count -eq 0 -and $false)) { $out += ('{0}:{1} Join-Path with 3+ positional paths' -f $rel, $c.Extent.StartLineNumber) }
          }
          foreach ($e in $c.CommandElements) {
            if ($e -is [Management.Automation.Language.CommandParameterAst] -and $e.ParameterName -eq 'Encoding' -and $e.Argument) { }
          }
          $i = 0; $els = @($c.CommandElements)
          for ($i = 0; $i -lt $els.Count; $i++) {
            $e = $els[$i]
            if ($e -is [Management.Automation.Language.CommandParameterAst] -and $e.ParameterName -eq 'Encoding') {
              $v = $(if ($e.Argument) { $e.Argument.Extent.Text } elseif ($i + 1 -lt $els.Count) { $els[$i + 1].Extent.Text } else { '' })
              if ($v -match "(?i)^['""]?utf8(NoBOM|BOM)['""]?$") { $out += ('{0}:{1} -Encoding {2}' -f $rel, $c.Extent.StartLineNumber, $v) }
            }
          }
        }
      }
      'cmds' { foreach ($c in $ast.FindAll({ param($x) $x -is [Management.Automation.Language.CommandAst] }, $true)) { $n = $c.GetCommandName(); if ($n -and ($ps7Cmds -contains $n)) { $out += ('{0}:{1} {2}' -f $rel, $c.Extent.StartLineNumber, $n) } } }
      'netcore' {
        # only code tokens: comments are skipped (a comment that names an API is not a call)
        $code = @($ast.FindAll({ param($x) $x -is [Management.Automation.Language.InvokeMemberExpressionAst] -or $x -is [Management.Automation.Language.MemberExpressionAst] -or $x -is [Management.Automation.Language.TypeExpressionAst] }, $true))
        foreach ($a in $code) { if ($a.Extent.Text -match $netCore) { $out += ('{0}:{1} {2}' -f $rel, $a.Extent.StartLineNumber, $a.Extent.Text) } }
        $out = @($out | Select-Object -Unique)
      }
      'requires' {
        $sr = $ast.ScriptRequirements
        if ($sr -and $sr.RequiredPSVersion -and $sr.RequiredPSVersion.Major -ge 6) { $out += ('{0} #requires -Version {1}' -f $rel, $sr.RequiredPSVersion) }
        if ($sr -and $sr.RequiredPSEditions -and ($sr.RequiredPSEditions -contains 'Core') -and -not ($sr.RequiredPSEditions -contains 'Desktop')) { $out += ('{0} #requires -PSEdition Core' -f $rel) }
        foreach ($a in $ast.FindAll({ param($x) $x -is [Management.Automation.Language.VariableExpressionAst] -and $x.VariablePath.UserPath -eq 'PSStyle' }, $true)) { $out += ('{0}:{1} $PSStyle' -f $rel, $a.Extent.StartLineNumber) }
      }
      'encoding' {
        $b = [IO.File]::ReadAllBytes($file)
        $bom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
        if (-not $bom) { $first = -1; for ($k = 0; $k -lt $b.Length; $k++) { if ($b[$k] -gt 127) { $first = $k; break } }; if ($first -ge 0) { $line = 1; for ($k = 0; $k -lt $first; $k++) { if ($b[$k] -eq 10) { $line++ } }; $out += ('{0}:{1} non-ASCII byte without a UTF-8 BOM' -f $rel, $line) } }
      }
    }
    foreach ($o in $out) { $o }
  }
  $tok = $null; $err = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile($file, [ref]$tok, [ref]$err)
  foreach ($o in @(Get-FindingsAst $ast $err $file $rule $file)) { $o }
  if ($rule -eq 'encoding') { return }
  foreach ($o in @(Get-HereStringFindings $ast $file $rule 1)) { $o }
}
$rules = [ordered]@{
  parse = 'every file parses'; ternary = 'no ternary ?: (PS7)'; chain = 'no && / || pipeline chains (PS7)'; coalesce = 'no ?? / ??= (PS7)'
  nullcond = 'no ?. / ?[] null-conditional access (PS7)'; clean = 'no clean{} block (PS7.3)'; params = 'no PS6+/7-only cmdlet parameters (incl. ForEach-Object -Parallel, 3-path Join-Path, utf8NoBOM)'
  cmds = 'no PS7-only cmdlets'; netcore = 'no .NET Core-only APIs'; requires = 'no #requires PS6+/Core, no $PSStyle'; encoding = 'non-ASCII files carry a UTF-8 BOM (5.1 reads BOM-less files as ANSI)'
}
# --- detector self-test: each rule must catch a planted sample (else the rule proves nothing) ---
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('ps51static-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$samples = [ordered]@{
  parse = 'function x( {'; ternary = '$a = $b ? 1 : 2'; chain = 'Get-Item x && Get-Item y'; coalesce = '$a = $b ?? 3'; nullcond = '$a = ${b}?.Name'
  clean = 'function f { process { 1 } clean { 2 } }'; params = '$j = $t | ConvertFrom-Json -AsHashtable; Join-Path a b c; 1..2 | ForEach-Object -Parallel { $_ }; Set-Content -Path x -Encoding utf8NoBOM -Value 1'
  cmds = 'Get-Error'; netcore = '$h = [Convert]::ToHexString($b)'; requires = "#requires -Version 7`n1"
}
Write-Host 'Detector self-test (each rule catches a planted PS7-only sample)'
foreach ($k in $samples.Keys) {
  $f = Join-Path $tmp ($k + '.ps1'); [IO.File]::WriteAllText($f, $samples[$k], (New-Object Text.UTF8Encoding($false)))
  $hit = @(Get-Findings $f $k)
  if ($k -eq 'params') { Check ($hit.Count -ge 4) ('self-test (code shape): rule "' + $k + '" catches its planted samples (' + $hit.Count + ' of 4)') ($hit -join ' | ') }
  else { Check ($hit.Count -ge 1) ('self-test (code shape): rule "' + $k + '" catches its planted sample') }
}
$f = Join-Path $tmp 'enc.ps1'; [IO.File]::WriteAllText($f, "'a " + [char]0x2014 + " b'", (New-Object Text.UTF8Encoding($false)))
Check (@(Get-Findings $f 'encoding').Count -ge 1) 'self-test (code shape): rule "encoding" catches a BOM-less UTF-8 dash'
$f2 = Join-Path $tmp 'enc2.ps1'; [IO.File]::WriteAllText($f2, "'a " + [char]0x2014 + " b'", (New-Object Text.UTF8Encoding($true)))
Check (@(Get-Findings $f2 'encoding').Count -eq 0) 'self-test (code shape): rule "encoding" accepts the same text with a BOM (control)'
$ok51 = Join-Path $tmp 'ok.ps1'; [IO.File]::WriteAllText($ok51, '$a = $(if ($b) { 1 } else { 2 }); $c = [Security.Cryptography.SHA256]::Create(); Join-Path $a ''b''; Get-Content -Encoding Byte x', (New-Object Text.UTF8Encoding($false)))
$neg = @(); foreach ($k in $rules.Keys) { $neg += @(Get-Findings $ok51 $k) }
Check ($neg.Count -eq 0) 'self-test (code shape): 5.1-safe forms (if-subexpression, SHA256.Create, 2-path Join-Path, -Encoding Byte) are not flagged (control)' ($neg -join ' | ')
Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
# --- the repo ---
$files = @(Get-ChildItem -LiteralPath $Repo -Recurse -File -Include '*.ps1', '*.psm1' | Where-Object { $_.FullName -notmatch '[\\/](\.git|node_modules)[\\/]' } | Sort-Object FullName)
Write-Host ('Repo: ' + $Repo + ' (' + $files.Count + ' PowerShell files, shipped code and tests)')
Check ($files.Count -gt 20) ('found the repo''s PowerShell files (' + $files.Count + ')')
foreach ($k in $rules.Keys) {
  $all = @(); foreach ($f in $files) { $all += @(Get-Findings $f.FullName $k) }
  $all = @($all | ForEach-Object { $_.Replace($Repo, '').TrimStart('\', '/') })
  Check ($all.Count -eq 0) ('repo (code shape): ' + $rules[$k] + ' - ' + $all.Count + ' offender(s)') ($all -join ' | ')
}
# --- real Windows PowerShell 5.1 parse, where it exists ---
$ps51 = $(if ($env:SystemRoot) { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' } else { '' })
if ($ps51 -and (Test-Path -LiteralPath $ps51)) {
  $list = Join-Path ([IO.Path]::GetTempPath()) ('ps51files-' + [guid]::NewGuid().ToString('N') + '.txt'); [IO.File]::WriteAllLines($list, [string[]]@($files | ForEach-Object { $_.FullName }))
  $cmd = '$bad=0; foreach($f in Get-Content -LiteralPath ''' + $list + '''){ $e=$null; [void][Management.Automation.Language.Parser]::ParseFile($f,[ref]$null,[ref]$e); if($e){ $bad++; Write-Output (''PARSEERR '' + $f + '': '' + $e[0].Message) } }; Write-Output (''BAD='' + $bad)'
  $o = @(& $ps51 -NoProfile -Command $cmd 2>&1 | ForEach-Object { [string]$_ })
  Remove-Item -LiteralPath $list -ErrorAction SilentlyContinue
  Check ([bool]($o -contains 'BAD=0')) ('Windows PowerShell 5.1 itself parses all ' + $files.Count + ' files') (($o | Select-Object -First 20) -join ' | ')
} else { $script:deferred++; Write-Host 'DEFERRED Windows PowerShell 5.1 parse of every file (no powershell.exe here; runs when this suite runs on Windows)' }
Write-Host ''
Write-Host ('Test-Ps51Static: ' + $script:pass + ' passed, ' + $script:fail + ' failed, ' + $script:deferred + ' deferred')
exit $script:fail
