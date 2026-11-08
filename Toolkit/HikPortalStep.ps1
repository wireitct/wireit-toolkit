<#
 HikPortalStep.ps1 - WireIt Toolkit 2.2.0: Hikvision's reset page for ONE device, on the tech's own login (started by the Toolkit window
 when a background "Fix this site" run gets to the picture check). Reads the run's question file, fills the page, waits for the tech to
 slide the picture check and press Submit, writes the answer: submitted | failed | timeout | no-browser. No admin, nothing else.
#>
param([Parameter(Mandatory = $true)][string]$Question)
$ErrorActionPreference = 'Continue'; $ProgressPreference = 'SilentlyContinue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'FixSiteIpc.ps1')
. (Join-Path $here 'HikSadp.ps1')
. (Join-Path $here 'HikPortal.ps1')
$sess = Split-Path -Parent $Question
$q = Read-FsIpcJson $Question 2097152
if (-not $q -or [string]$q.kind -ne 'portal') { exit 2 }
$n = [int]$q.n; $res = 'failed'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('wireit-req-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
  $nm = ([string]$q.requestName) -replace '[^A-Za-z0-9._-]', '_'; if (-not $nm) { $nm = 'request.xml' }
  $file = Join-Path $tmp $nm; [IO.File]::WriteAllText($file, [string]$q.request)
  $d = [pscustomobject]@{ model = [string]$q.model; serial = [string]$q.serial; shortSerial = [string]$q.shortSerial; ip = [string]$q.ip }
  if (-not (Find-HikBrowser)) { $res = 'no-browser'; try { Start-Process $script:PortalUrl } catch {} }
  else {
    $s = Start-HikBrowserSession $script:PortalUrl
    if (-not $s) { $res = 'no-browser' }
    else {
      try {
        if (Wait-PortalForm $s 60) {
          $fill = Fill-HikPortalForm $s $q.form $d $file
          $tmo = [int]$q.timeoutSec; if ($tmo -le 0) { $tmo = 900 }
          $form = $q.form
          if (@(Test-PortalFilled $fill $d).Count) { $res = 'failed' }   # 2.2.3 (Codex #49): a page that did not take every field (or the file) is not sent
          else {
            $r = Wait-PortalSubmitted $s $tmo $null ({ [void](Restore-PortalFields $s $form $d) }.GetNewClosure())
            $res = $(if ($r -eq 'submitted') { 'submitted' } elseif ($r -match 'time') { 'timeout' } else { 'failed' })
          }
        }
      } finally { Stop-HikBrowserSession $s }
    }
  }
} catch { $res = 'failed' }
finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
Write-FsIpcAnswer $sess $n $res
exit 0
