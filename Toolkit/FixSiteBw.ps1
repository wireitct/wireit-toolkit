<#
 FixSiteBw.ps1 - WireIt Toolkit 2.2.2: the site password into Bitwarden (the bw command), as "<site> - site password".
 2.2.2 (re-review H11 + NEW-3): moved out of FixSiteDevices.ps1 so the Toolkit WINDOW can run it on the tech's own login. A Crew run of
 "Fix this site" runs as SYSTEM, and SYSTEM's profile has no Bitwarden login: the run now hands the save to the window (FixSiteAsk.ps1,
 question kind "bitwarden"), which runs bw with the Crew user's own PATH, APPDATA and Bitwarden login.
 New items go into the WireIt CT organization, collection "Sites" (config.json fixSite.bitwardenOrg / bitwardenCollection change the
 names). Every answer is read back from Bitwarden after a sync that WORKED, and the message says where the item really is.
 The password only goes to bw on its stdin (base64 item JSON), never on a command line or in a file. Dot-sourced by FixSiteDevices.ps1
 (so FixSite.ps1 and the tests have it) and by FixSiteAsk.ps1 (the window).
#>
if (-not (Get-Variable -Name FsVersion -Scope Script -ErrorAction SilentlyContinue)) { $script:FsVersion = '2.2.2' }
$script:FsBwLast = $null   # { where ('org' | 'personal' | ''); org; collection; why } of the last Save-FsBitwarden
function Find-FsBitwarden($cfg) {
  if ($cfg -and $cfg.PSObject.Properties['bitwardenCli'] -and $cfg.bitwardenCli -and (Test-Path ([string]$cfg.bitwardenCli))) { return [string]$cfg.bitwardenCli }
  foreach ($n in @('bw.exe', 'bw.cmd', 'bw')) { $c = Get-Command $n -ErrorAction SilentlyContinue | Select-Object -First 1; if ($c -and $c.Source) { return $c.Source } }
  foreach ($p in @($(if ($env:APPDATA) { Join-Path $env:APPDATA 'npm\bw.cmd' }), $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Programs\Bitwarden CLI\bw.exe' }))) { if ($p -and (Test-Path $p)) { return $p } }
  return ''
}
function Invoke-FsBw([string]$bw, [string[]]$a, [string]$stdin = $null) {
  try {
    if ($null -ne $stdin) { $o = $stdin | & $bw @a 2>$null } else { $o = & $bw @a 2>$null }
    return [pscustomobject]@{ code = $LASTEXITCODE; out = (@($o) -join "`n").Trim() }
  } catch { return [pscustomobject]@{ code = 1; out = '' } }
}
function Get-FsBwStatus([string]$bw) {
  # 'unlocked' | 'locked' | 'unauthenticated' | '' (no bw / no answer)
  if (-not $bw) { return '' }
  $r = Invoke-FsBw $bw @('status')
  try { return [string](($r.out | ConvertFrom-Json).status) } catch { return '' }
}
# 2.2.3 (Codex #25): Windows PowerShell 5.1's ConvertFrom-Json writes a JSON array as ONE object, so @(text | ConvertFrom-Json) is a
# 1-item array there. Parsed into a variable first, then unrolled, it is the real list on 5.1 and 7 alike.
$script:FsJsonParse = { param($t) ConvertFrom-Json -InputObject $t }
function ConvertFrom-FsJsonArray([string]$text) { if (-not $text) { return }; $v = & $script:FsJsonParse $text; foreach ($i in $v) { $i } }
function Get-FsBwItemName([string]$site) { return ($site + ' ' + [char]0x2013 + ' site password') }
function Get-FsBwItem([string]$bw, [string]$id) { $g = Invoke-FsBw $bw @('get', 'item', $id); if ($g.code -ne 0 -or -not $g.out) { return $null }; try { return ($g.out | ConvertFrom-Json) } catch { return $null } }
function Get-FsBwCfgValue($cfg, [string]$name, [string]$default) { if ($cfg -and $cfg.PSObject.Properties[$name] -and [string]$cfg.$name) { return [string]$cfg.$name }; return $default }
# the WireIt CT organization and its "Sites" collection, by name, as this Bitwarden login sees them. Returns { orgId; org; colId; col } or $null.
function Get-FsBwTarget([string]$bw, $cfg = $null) {
  $on = Get-FsBwCfgValue $cfg 'bitwardenOrg' 'WireIt CT'; $cn = Get-FsBwCfgValue $cfg 'bitwardenCollection' 'Sites'
  $plain = { param($s) (([string]$s) -replace '[^\x20-\x7E]', '').Trim() }
  $orgs = @(); try { $orgs = @(ConvertFrom-FsJsonArray ((Invoke-FsBw $bw @('list', 'organizations')).out)) } catch {}
  $org = @($orgs | Where-Object { $_ -and (& $plain $_.name) -ieq (& $plain $on) })[0]
  if (-not $org) { return $null }
  $cols = @(); try { $cols = @(ConvertFrom-FsJsonArray ((Invoke-FsBw $bw @('list', 'org-collections', '--organizationid', ([string]$org.id))).out)) } catch {}
  $col = @($cols | Where-Object { $_ -and (& $plain $_.name) -ieq (& $plain $cn) })[0]
  if (-not $col) { return $null }
  return [pscustomobject]@{ orgId = [string]$org.id; org = [string]$org.name; colId = [string]$col.id; col = [string]$col.name }
}
function Save-FsBitwarden([string]$bw, [string]$site, [string]$pw, [string]$session = '', $cfg = $null) {
  # returns 'saved' (new item) | 'updated' (the item had an older password) | 'exists' (it already had exactly this one) | 'failed'.
  # 2.2.1 (review H11): an item with the same name is no longer taken as "saved": its password is compared, changed when different,
  # and every answer except 'failed' is checked by reading the item back after a sync with the Bitwarden server (= the office sees it).
  # 2.2.2 (re-review H11): both syncs must WORK (2.2.1 ignored their answers, so a cached item passed as "the office sees it"); a new
  # item goes into the WireIt CT org collection; $script:FsBwLast.where says where the item really is ('org' or 'personal').
  $script:FsBwLast = [pscustomobject]@{ where = ''; org = ''; collection = ''; why = '' }
  if (-not $bw -or -not $pw) { $script:FsBwLast.why = 'no bw'; return 'failed' }
  $hadEnv = $env:BW_SESSION; if ($session) { $env:BW_SESSION = $session }
  try {
    $name = Get-FsBwItemName $site
    $s1 = Invoke-FsBw $bw @('sync')   # the newest copy from the server first: a stale local copy must not decide
    if ($s1.code -ne 0) { $script:FsBwLast.why = 'sync'; return 'failed' }
    $tg = Get-FsBwTarget $bw $cfg
    $where = { param($it) if ($it -and $it.PSObject.Properties['organizationId'] -and [string]$it.organizationId) { $script:FsBwLast.where = 'org'; if ($tg -and [string]$it.organizationId -eq $tg.orgId) { $script:FsBwLast.org = $tg.org; $script:FsBwLast.collection = $tg.col } } else { $script:FsBwLast.where = 'personal' } }
    $l = Invoke-FsBw $bw @('list', 'items', '--search', $name)
    $plainName = $name -replace '[^\x20-\x7E]', ''   # Windows PowerShell may read bw's UTF-8 dash wrongly: compare without it
    $found = @(); try { $found = @(ConvertFrom-FsJsonArray $l.out | Where-Object { ([string]$_.name -replace '[^\x20-\x7E]', '') -eq $plainName -and [int]$_.type -eq 1 }) } catch {}
    if ($tg -and $found.Count -gt 1) { $found = @(@($found | Where-Object { [string]$_.organizationId -eq $tg.orgId }) + @($found | Where-Object { [string]$_.organizationId -ne $tg.orgId })) }   # the org's copy first
    $verify = { param($id) $s2 = Invoke-FsBw $bw @('sync'); if ($s2.code -ne 0) { $script:FsBwLast.why = 'sync after'; return $false }; $it = Get-FsBwItem $bw $id; if (-not ($it -and $it.login -and ([string]$it.login.password) -ceq $pw)) { $script:FsBwLast.why = 'read back'; return $false }; & $where $it; return $true }
    if ($found.Count) {
      $it0 = $found[0]
      if ($it0.login -and ([string]$it0.login.password) -ceq $pw) { if (& $verify ([string]$it0.id)) { return 'exists' }; return 'failed' }
      $full = Get-FsBwItem $bw ([string]$it0.id); if (-not $full) { $full = $it0 }
      if (-not $full.login) { $script:FsBwLast.why = 'not a login item'; return 'failed' }
      $full.login.password = $pw
      $n0 = [string]$full.notes; $full.notes = (($n0.TrimEnd() + "`n" + 'Password changed by the WireIt Toolkit ' + $script:FsVersion + ' on ' + (Get-Date -Format 'yyyy-MM-dd') + ' (the old one is in this item''s password history).').Trim())
      $enc = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($full | ConvertTo-Json -Depth 8 -Compress)))
      $r = Invoke-FsBw $bw @('edit', 'item', ([string]$it0.id)) $enc
      if ($r.code -ne 0) { $script:FsBwLast.why = 'edit'; return 'failed' }
      if (& $verify ([string]$it0.id)) { return 'updated' }; return 'failed'
    }
    $item = [ordered]@{ organizationId = $(if ($tg) { $tg.orgId } else { $null }); collectionIds = $(if ($tg) { @($tg.colId) } else { $null }); folderId = $null; type = 1; name = $name
      notes = ('Made by the WireIt Toolkit ' + $script:FsVersion + ' on ' + (Get-Date -Format 'yyyy-MM-dd') + '. Every camera and NVR at this site uses it. User: admin.')
      favorite = $false; fields = @(); login = [ordered]@{ uris = @(); username = 'admin'; password = $pw; totp = $null }; secureNote = $null; card = $null; identity = $null; reprompt = 0 }
    if (-not $tg) { $script:FsBwLast.why = 'no org' }
    $enc = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($item | ConvertTo-Json -Depth 5 -Compress)))
    $r = Invoke-FsBw $bw @('create', 'item') $enc
    if ($r.code -ne 0 -or $r.out -notmatch '"id"') { $script:FsBwLast.why = 'create'; return 'failed' }
    $nid = ''; try { $nid = [string](($r.out | ConvertFrom-Json).id) } catch {}
    if ($nid -and (& $verify $nid)) { return 'saved' }
    return 'failed'
  } finally { if ($session) { $env:BW_SESSION = $hadEnv } }
}
# the words for the tech: they say where the item really is (2.2.2: 2.2.1 said "The office can see it" for a personal-vault item)
function Format-FsBwResult([string]$result, $last, [string]$shown) {
  $w = $(if ($last) { [string]$last.where } else { '' })
  $orgTxt = $(if ($last -and $last.org) { 'the ' + $last.org + ' organization' + $(if ($last.collection) { ', collection ' + $last.collection } else { '' }) } else { 'a Bitwarden organization' })
  $place = $(if ($w -eq 'org') { 'It is in ' + $orgTxt + ': the office can see it.' } else { 'It is in YOUR OWN Bitwarden vault, not the WireIt CT organization' + $(if ($last -and $last.why -eq 'no org') { ' (this Bitwarden login does not see WireIt CT > Sites)' } else { '' }) + ': the office can NOT see it yet. Move it to WireIt CT > Sites in Bitwarden.' })
  switch ($result) {
    'saved' { return ('Saved in Bitwarden and checked: "' + $shown + '" (user admin). ' + $place) }
    'updated' { return ('Bitwarden had an OLDER password in "' + $shown + '": changed to this one and checked (the old one stays in the item''s history). ' + $place) }
    'exists' { return ('Bitwarden already has exactly this password in "' + $shown + '" (checked) - not added twice. ' + $place) }
    default {
      $why = $(if ($last) { [string]$last.why } else { '' })
      return ('Bitwarden did not take it, or it could not be checked' + $(switch ($why) { 'sync' { ' (Bitwarden could not reach its server)' } 'sync after' { ' (saved, but Bitwarden could not reach its server to confirm it)' } default { '' } }) + ': it is NOT confirmed in Bitwarden (only on this PC).')
    }
  }
}
function Unlock-FsBitwarden([string]$bw, [string]$master) {
  # bw unlock with the master password in a process-only variable (not on the command line); returns the session key or ''
  if (-not $bw -or -not $master) { return '' }
  $env:WIREIT_BWPW = $master
  try { $r = Invoke-FsBw $bw @('unlock', '--passwordenv', 'WIREIT_BWPW', '--raw'); if ($r.code -eq 0 -and $r.out -and $r.out -notmatch '\s') { return $r.out }; return '' }
  finally { Remove-Item Env:\WIREIT_BWPW -ErrorAction SilentlyContinue }
}
# 2.2.2 (re-review H11 + NEW-3): the window's side of a run's "bitwarden" question - bw runs HERE, on the tech's own login.
# $AskMaster = { param($text) -> the typed master password or '' }. Returns the answer string "result;where;why" (no secret in it).
function Invoke-FsBwForRun($Q, $cfg, [scriptblock]$AskMaster = $null) {
  $bw = Find-FsBitwarden $cfg
  if (-not $bw) { return 'nobw;;' }
  $st = Get-FsBwStatus $bw; $session = ''
  if ($st -eq 'unauthenticated') { return 'unauthenticated;;' }
  if ($st -eq 'locked') {
    $mp = ''; if ($AskMaster) { $mp = [string](& $AskMaster 'Bitwarden is on this PC but locked. Type your Bitwarden master password to save the site password there (hidden; Skip = do not save it in Bitwarden):') }
    if (-not $mp) { return 'locked;;skipped' }
    $session = Unlock-FsBitwarden $bw $mp; $mp = $null
    if (-not $session) { return 'locked;;wrong master password' }
  } elseif ($st -ne 'unlocked') { return 'nobw;;no answer' }
  $r = Save-FsBitwarden $bw ([string]$Q.site) ([string]$Q.value) $session $cfg
  $l = $script:FsBwLast
  return ($r + ';' + [string]$l.where + ';' + ([string]$l.why -replace '[;\r\n]', ' ') + ';' + ([string]$l.org -replace '[;\r\n]', ' ') + ';' + ([string]$l.collection -replace '[;\r\n]', ' '))
}
