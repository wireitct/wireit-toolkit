<#
 Test-Fix225.ps1 - WireIt Toolkit 2.2.5 tests (fix 10, Nov 8 2026): CamViews' remembered-NVR list (camviews-sites.json).
 Every check RUNS the real CamViews functions (Get-CvSites, Save-CvSite, Get-CvSiteCred, Invoke-CvAuto) against temp folders, with
 DPAPI, icacls and the camera save (Save-CameraViews) mocked. Each scenario runs twice: with this host's own ConvertFrom-Json, and
 under Windows PowerShell 5.1's rule (a JSON array is written as ONE object), so pwsh 7 on Linux proves the 5.1 behaviour too.
 A check marked "reproduction" fails with the 0441d8e Get-CvSites under 5.1's rule (proven on the Office PC, Nov 8 2026).
 pwsh 7 or Windows PowerShell 5.1, from any folder.
 Usage: powershell -NoProfile -ExecutionPolicy Bypass -File Toolkit\tests\Test-Fix225.ps1   (exit code = number of failed checks)
#>
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path; $tk = Split-Path -Parent $here
$script:fail = 0; $script:pass = 0
function Check([bool]$ok, [string]$what) { if ($ok) { $script:pass++; Write-Host ('  ok    ' + $what) } else { $script:fail++; Write-Host ('  FAIL  ' + $what) -ForegroundColor Red } }
function Eq($a, $b, [string]$what) { Check ("$a" -eq "$b") ($what + ' (got "' + $a + '", want "' + $b + '")') }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fix225-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$hostEap = $ErrorActionPreference
. (Join-Path $tk 'CamViews.ps1') -Lib
$ErrorActionPreference = $hostEap
$script:CvLogDir = Join-Path $tmp '_logs'
$script:CvDpapi = { param($op, $data) [byte[]]($data | ForEach-Object { $_ -bxor 0x5A }) }   # stands in for DPAPI (reversible)
$script:CvAclRun = { param($a) return 0 }                                                     # stands in for icacls
$script:Said = New-Object System.Collections.ArrayList
function Say([string]$s, [string]$c = '') { [void]$script:Said.Add($s) }
# the camera save itself is mocked: it records which NVR the daily refresh asked for, with which site, vendor, recorder and login
$script:Refreshed = New-Object System.Collections.ArrayList
function Save-CameraViews { param([string]$Nvr, $Cred, [string]$Site, [string]$Vendor = 'auto', [int]$RecorderNo = 1, [switch]$NoUpload)
  [void]$script:Refreshed.Add(($Nvr + '|' + $Site + '|' + $Vendor + '|' + $RecorderNo + '|' + $(if ($Cred) { $Cred.GetNetworkCredential().Password } else { '' }))); return @{ ok = $true } }

# Windows PowerShell 5.1's ConvertFrom-Json: collects its input, parses it, and writes the result WITHOUT enumerating it, so a JSON
# array comes out as one object. On 5.1 itself this is just the real cmdlet; on pwsh 7 it is the cmdlet with -NoEnumerate.
function Invoke-Ps51Json([scriptblock]$b) {
  function ConvertFrom-Json { [CmdletBinding()] param([Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)][AllowEmptyString()][string]$InputObject)
    begin { $buf = New-Object System.Collections.Generic.List[string] }
    process { $buf.Add($InputObject) }
    end {
      $t = $buf -join "`n"
      if ($PSVersionTable.PSVersion.Major -le 5) { $v = Microsoft.PowerShell.Utility\ConvertFrom-Json -InputObject $t } else { $v = Microsoft.PowerShell.Utility\ConvertFrom-Json -InputObject $t -NoEnumerate }
      $PSCmdlet.WriteObject($v, $false)
    } }
  . $b
}
function Invoke-As([string]$mode, [scriptblock]$b) { if ($mode -eq 'ps51') { Invoke-Ps51Json $b } else { & $b } }
# the 0441d8e (2.2.4 / 2.2.5-pre) Get-CvSites, word for word, for the reproductions
$oldGetCvSites = 'function Get-CvSites { $p = Join-Path $script:CvHere ''camviews-sites.json''; if (Test-Path $p) { return @(Get-Content $p -Raw | ConvertFrom-Json) } else { return @() } }'

function New-CvDir([string]$name) { $d = Join-Path $tmp $name; New-Item -ItemType Directory -Force -Path $d | Out-Null; $script:CvHere = $d; return $d }
function Get-Sites([string]$name, [int]$n) { @(1..$n | ForEach-Object { [ordered]@{ nvr = ('10.0.' + $_ + '.20'); site = ('Site ' + [char](64 + $_)); vendor = $(if ($_ % 2) { 'hik' } else { 'uniview' }); recorder = $_ } }) }
function Write-SitesFile([string]$dir, $sites) {   # what a correct save looks like: a plain JSON array, one object per NVR
  $j = '[' + (($sites | ForEach-Object { '{"nvr":"' + $_.nvr + '","site":"' + $_.site + '","vendor":"' + $_.vendor + '","recorder":' + $_.recorder + '}' }) -join ',') + ']'
  [IO.File]::WriteAllText((Join-Path $dir 'camviews-sites.json'), $j)
}
function Save-Logins($sites) {   # each NVR's login, through the real Save-CvSite (vault\, encrypted)
  foreach ($s in $sites) { Save-CvSite $s.nvr $s.site 'admin' $s.vendor ([int]$s.recorder) (ConvertTo-SecureString ('Pw-' + $s.nvr) -AsPlainText -Force) }
}
function Want-Refreshed($sites) { @($sites | ForEach-Object { $_.nvr + '|' + $_.site + '|' + $_.vendor + '|' + $_.recorder + '|Pw-' + $_.nvr }) -join ' ; ' }
function Read-FileHost([string]$dir) { $v = Microsoft.PowerShell.Utility\ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $dir 'camviews-sites.json'))); foreach ($i in $v) { $i } }
function B64([string]$dir) { [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $dir 'camviews-sites.json'))) }

try {
# ------------------------------------------------------------------------------------------------------------------------------
Write-Host '0. the 5.1 rule is reproduced here (so the checks below prove Windows PowerShell 5.1 as well as this host)'
$two = '[{"nvr":"10.0.0.1","site":"A"},{"nvr":"10.0.0.2","site":"B"}]'
Eq @(Invoke-Ps51Json { @($two | ConvertFrom-Json) }).Count 1 '5.1 rule: @(json-array | ConvertFrom-Json) is ONE item'
$d0 = New-CvDir 'repro'; [IO.File]::WriteAllText((Join-Path $d0 'camviews-sites.json'), $two)
$r0 = Invoke-Ps51Json { . ([scriptblock]::Create($oldGetCvSites)); , @(Get-CvSites) }
Eq $r0.Count 1 'reproduction: the 0441d8e Get-CvSites with 2 remembered NVRs under 5.1''s rule gives 1 item (Office PC: "1 item(s)")'
Eq ([string]$r0[0].nvr) '10.0.0.1 10.0.0.2' 'reproduction: ...whose .nvr is "10.0.0.1 10.0.0.2" (Office PC, word for word)'
$s0 = Get-Sites 'r' 2; $d0 = New-CvDir 'repro-auto'; Save-Logins $s0; Write-SitesFile $d0 $s0; $script:Refreshed.Clear(); $script:Said.Clear()
Invoke-Ps51Json { . ([scriptblock]::Create($oldGetCvSites)); Invoke-CvAuto }
Eq $script:Refreshed.Count 0 'reproduction: the 0441d8e daily refresh under 5.1''s rule refreshes 0 of 2 NVRs'
Check (@($script:Said | Where-Object { $_ -eq 'No saved login for 10.0.1.20 10.0.2.20' }).Count -eq 1) 'reproduction: ...and says "No saved login for 10.0.1.20 10.0.2.20"'

foreach ($mode in @('host', 'ps51')) {
  $tag = $(if ($mode -eq 'ps51') { '[5.1 rule] ' } else { '[this host, PowerShell ' + $PSVersionTable.PSVersion.Major + '] ' })
  # ----------------------------------------------------------------------------------------------------------------------------
  Write-Host ('1. ' + $tag + '1, 2 and 3 remembered NVRs: Get-CvSites reads each one; the daily refresh refreshes every NVR and leaves the file as it was')
  foreach ($n in @(1, 2, 3)) {
    $sites = Get-Sites 's' $n; $d = New-CvDir ($mode + '-auto' + $n); Save-Logins $sites; Write-SitesFile $d $sites; $before = B64 $d
    $got = Invoke-As $mode { , @(Get-CvSites) }
    Eq $got.Count $n ($tag + $n + ' NVR(s): Get-CvSites gives ' + $n + ' site(s)' + $(if ($n -ge 2) { ' (reproduction)' } else { '' }))
    Eq (@($got | ForEach-Object { [string]$_.nvr }) -join ',') (@($sites | ForEach-Object { $_.nvr }) -join ',') ($tag + $n + ' NVR(s): ...each with its own address')
    $script:Refreshed.Clear(); $script:Said.Clear()
    Invoke-As $mode { Invoke-CvAuto }
    Eq ($script:Refreshed -join ' ; ') (Want-Refreshed $sites) ($tag + $n + ' NVR(s): the daily refresh refreshes every NVR with its own site, vendor, recorder and login' + $(if ($n -ge 2) { ' (reproduction)' } else { '' }))
    Check (-not @($script:Said | Where-Object { $_ -like 'No saved login*' }).Count) ($tag + $n + ' NVR(s): ...and no "No saved login"')
    Eq (B64 $d) $before ($tag + $n + ' NVR(s): camviews-sites.json is unchanged, byte for byte')
  }
  # ----------------------------------------------------------------------------------------------------------------------------
  Write-Host ('2. ' + $tag + 'remembering NVRs one after another (the real -Remember save) keeps one flat entry per NVR')
  $sites = Get-Sites 'w' 3; $d = New-CvDir ($mode + '-save')
  foreach ($k in 1..3) {
    Invoke-As $mode { Save-Logins @($sites[$k - 1]) }
    $f = @(Read-FileHost $d)
    Eq (@($f | ForEach-Object { [string]$_.nvr }) -join ',') (@($sites[0..($k - 1)] | ForEach-Object { $_.nvr }) -join ',') ($tag + 'after ' + $k + ' save(s) the file lists ' + $k + ' NVR(s), in order' + $(if ($k -ge 3) { ' (reproduction)' } else { '' }))
    Check (-not @($f | Where-Object { $_.PSObject.Properties['value'] -or $_.PSObject.Properties['Count'] -or $_ -is [array] }).Count) ($tag + 'after ' + $k + ' save(s): no {"value":...,"Count":n} or list inside the list')
  }
  Invoke-As $mode { Save-Logins @($sites[1]) }
  Eq @(Read-FileHost $d).Count 3 ($tag + 'remembering an NVR again replaces its entry (still 3)')
  $script:Refreshed.Clear(); Invoke-As $mode { Invoke-CvAuto }
  Eq ($script:Refreshed -join ' ; ') (Want-Refreshed @($sites[0], $sites[2], $sites[1])) ($tag + '...and the refresh refreshes all 3')
  # ----------------------------------------------------------------------------------------------------------------------------
  Write-Host ('3. ' + $tag + 'a file a 5.1 PC already wrote wrong (Office PC, Nov 8) reads back as its sites; the next save writes it right')
  $s3 = @([ordered]@{ nvr = '10.0.0.1'; site = 'A'; vendor = 'hik'; recorder = 1 }, [ordered]@{ nvr = '10.0.0.2'; site = 'B'; vendor = 'hik'; recorder = 1 }, [ordered]@{ nvr = '10.0.0.3'; site = 'C'; vendor = 'hik'; recorder = 1 })
  $d = New-CvDir ($mode + '-bad'); Save-Logins $s3
  [IO.File]::WriteAllText((Join-Path $d 'camviews-sites.json'), '[{"value":[{"nvr":"10.0.0.1","site":"A","vendor":"hik","recorder":1},{"nvr":"10.0.0.2","site":"B","vendor":"hik","recorder":1}],"Count":2},{"nvr":"10.0.0.3","site":"C","vendor":"hik","recorder":1}]')
  $got = Invoke-As $mode { , @(Get-CvSites) }
  Eq (@($got | ForEach-Object { [string]$_.nvr }) -join ',') '10.0.0.1,10.0.0.2,10.0.0.3' ($tag + 'the {"value":[...],"Count":2} file gives its 3 NVRs')
  $script:Refreshed.Clear(); Invoke-As $mode { Invoke-CvAuto }
  Eq ($script:Refreshed -join ' ; ') (Want-Refreshed $s3) ($tag + '...and the refresh refreshes all 3')
  Invoke-As $mode { Save-Logins @([ordered]@{ nvr = '10.0.0.4'; site = 'D'; vendor = 'hik'; recorder = 1 }) }
  $f = @(Read-FileHost $d)
  Eq (@($f | ForEach-Object { [string]$_.nvr }) -join ',') '10.0.0.1,10.0.0.2,10.0.0.3,10.0.0.4' ($tag + 'the next save writes 4 flat entries')
  # ----------------------------------------------------------------------------------------------------------------------------
  Write-Host ('4. ' + $tag + 'a 2.2.0 login (secrets\) moved into vault\ during the refresh keeps the whole list')
  $sites = Get-Sites 'l' 3; $d = New-CvDir ($mode + '-legacy'); Save-Logins $sites; Write-SitesFile $d $sites
  $vf = Get-CvCredFile $sites[1].nvr; $lf = Get-CvCredFile $sites[1].nvr -Legacy; New-Item -ItemType Directory -Force -Path (Split-Path -Parent $lf) | Out-Null; Move-Item -LiteralPath $vf -Destination $lf
  $script:Refreshed.Clear(); Invoke-As $mode { Invoke-CvAuto }
  Eq ($script:Refreshed -join ' ; ') (Want-Refreshed $sites) ($tag + 'all 3 NVRs refreshed, the moved one too')
  $f = @(Read-FileHost $d)
  Eq ((@($f | ForEach-Object { [string]$_.nvr + '=' + $_.site + '/' + $_.vendor + '/' + $_.recorder }) | Sort-Object) -join ',') ((@($sites | ForEach-Object { $_.nvr + '=' + $_.site + '/' + $_.vendor + '/' + $_.recorder }) | Sort-Object) -join ',') ($tag + '...and the list still has the same 3 NVRs with their sites, vendors and recorders')
  Check ((Test-Path -LiteralPath $vf) -and -not (Test-Path -LiteralPath $lf)) ($tag + '...the login is now in vault\ only')
  # ----------------------------------------------------------------------------------------------------------------------------
  Write-Host ('5. ' + $tag + 'no list, an empty file, or [] : nothing remembered, nothing refreshed')
  foreach ($c in @(@{ n = 'none'; t = $null }, @{ n = 'empty'; t = '' }, @{ n = 'brackets'; t = '[]' })) {
    $d = New-CvDir ($mode + '-' + $c.n); if ($null -ne $c.t) { [IO.File]::WriteAllText((Join-Path $d 'camviews-sites.json'), $c.t) }
    $got = Invoke-As $mode { , @(Get-CvSites) }; $script:Refreshed.Clear(); $script:Said.Clear(); Invoke-As $mode { Invoke-CvAuto }
    Check ($got.Count -eq 0 -and $script:Refreshed.Count -eq 0 -and @($script:Said | Where-Object { $_ -like 'No NVR remembered*' }).Count -eq 1) ($tag + $c.n + ': 0 sites, 0 refreshed, "No NVR remembered on this PC"')
  }
}
} finally {
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host ''
Write-Host ('Test-Fix225: ' + $script:pass + ' passed, ' + $script:fail + ' failed') -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
exit $script:fail
