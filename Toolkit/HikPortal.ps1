<#
 HikPortal.ps1 - WireIt Toolkit 2.1: Hikvision's own online password-reset page, filled in for you.
 Official page: https://www.hikvision.com/us-en/support/password-reset/  (read live Nov 2 + Nov 6 2026: First/Last name, Email, Company, Country, State, Business type,
 Zip, Device Serial Number = the 9-character short serial, Model, "XML upload" (up to 3 files, 5 MB), a PICTURE VERIFICATION CODE, and the owner statement).
 What is automated: opening the page in a clean Chrome/Edge window, filling every field from config.json "form" + the device, attaching the device's request file.
 What is NOT automated, by design: the picture code (it exists to tell a person from a program) and the Submit click. The window comes up with the cursor in the code box.
 The Toolkit watches the page and carries on by itself when the page accepts the form.
 Driven over the browser's own debugging port (Chrome DevTools protocol) with a throw-away profile: no extension, no saved logins touched.
 Test harness: $script:PortalBrowser = path of a browser, $script:PortalUrl = a local copy of the page.
#>
$script:PortalUrl = 'https://www.hikvision.com/us-en/support/password-reset/'
$script:PortalBrowser = ''
$script:PortalExtraArgs = @()
$script:PortalLog = $null
function Portal-Log([string]$s) { if ($script:PortalLog) { try { & $script:PortalLog $s } catch {} } }

function Find-HikBrowser {
  if ($script:PortalBrowser) { return $script:PortalBrowser }
  $c = @()
  foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
    if (-not $base) { continue }
    $c += (Join-Path $base 'Google\Chrome\Application\chrome.exe'); $c += (Join-Path $base 'Microsoft\Edge\Application\msedge.exe')
  }
  foreach ($x in $c) { if ($x -and (Test-Path -LiteralPath $x)) { return $x } }
  return ''
}
# ---------------- minimal Chrome DevTools protocol client ----------------
function Open-Cdp([string]$WsUrl) {
  $ws = New-Object System.Net.WebSockets.ClientWebSocket
  $ct = [Threading.CancellationToken]::None
  $ws.ConnectAsync([uri]$WsUrl, $ct).Wait()
  return [pscustomobject]@{ ws = $ws; id = 0 }
}
function Send-Cdp($c, [string]$Method, $Params = $null, [int]$TimeoutSec = 20) {
  $c.id++; $myId = $c.id
  $msg = @{ id = $myId; method = $Method }; if ($null -ne $Params) { $msg.params = $Params }
  $bytes = [Text.Encoding]::UTF8.GetBytes(($msg | ConvertTo-Json -Depth 12 -Compress))
  $seg = New-Object 'System.ArraySegment[byte]' -ArgumentList (, $bytes)
  $c.ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).Wait()
  $end = (Get-Date).AddSeconds($TimeoutSec)
  while ((Get-Date) -lt $end) {
    $buf = New-Object byte[] 65536; $sb = New-Object Text.StringBuilder
    do {
      $s2 = New-Object 'System.ArraySegment[byte]' -ArgumentList (, $buf)
      $t = $c.ws.ReceiveAsync($s2, [Threading.CancellationToken]::None)
      $left = [int](($end - (Get-Date)).TotalMilliseconds); if ($left -lt 100) { $left = 100 }
      if (-not $t.Wait($left)) { throw ('browser did not answer ' + $Method) }
      $r = $t.Result; [void]$sb.Append([Text.Encoding]::UTF8.GetString($buf, 0, $r.Count))
    } while (-not $r.EndOfMessage)
    $o = $sb.ToString() | ConvertFrom-Json
    if ($o.PSObject.Properties['id'] -and $o.id -eq $myId) { if ($o.PSObject.Properties['error']) { throw ('browser error: ' + $o.error.message) }; return $o.result }
  }
  throw ('browser did not answer ' + $Method)
}
function Invoke-CdpJs($c, [string]$Js, [int]$TimeoutSec = 20) {
  $r = Send-Cdp $c 'Runtime.evaluate' @{ expression = $Js; returnByValue = $true; awaitPromise = $true } $TimeoutSec
  if ($r.PSObject.Properties['exceptionDetails'] -and $r.exceptionDetails) { throw ('page script failed: ' + $r.exceptionDetails.text + ' ' + $r.exceptionDetails.exception.description) }
  return $r.result.value
}
function Test-RunningAsSystem { try { return [bool][Security.Principal.WindowsIdentity]::GetCurrent().IsSystem } catch { return $false } }
function Start-HikBrowserSession([string]$Url) {
  # 2.1.0 (3 Hewlett, Nov 6 2026): a window opened by a SYSTEM process lands on a Desktop nobody can see or use (systemprofile\Desktop is unavailable). Never do that.
  if (Test-RunningAsSystem) { throw 'This is running as the SYSTEM account, which has no screen. Start the Toolkit from the logged-in user (the Toolkit window or a scheduled task set to run as that user, only when logged on).' }
  $exe = Find-HikBrowser
  if (-not $exe) { return $null }
  $port = Get-Random -Minimum 20000 -Maximum 40000
  $prof = Join-Path ([IO.Path]::GetTempPath()) ('wireit-hik-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Force -Path $prof | Out-Null
  $args2 = @('--remote-debugging-port=' + $port, '--user-data-dir=' + $prof, '--no-first-run', '--no-default-browser-check', '--disable-extensions', '--remote-allow-origins=*') + @($script:PortalExtraArgs) + @($Url)
  $proc = Start-Process -FilePath $exe -ArgumentList $args2 -PassThru
  $ws = ''; $end = (Get-Date).AddSeconds(25)
  while ((Get-Date) -lt $end -and -not $ws) {
    Start-Sleep -Milliseconds 400
    try { $js = [string](Invoke-WebRequest -UseBasicParsing -Uri ('http://127.0.0.1:' + $port + '/json/list') -TimeoutSec 3).Content; $lst = $js | ConvertFrom-Json; foreach ($t in @($lst)) { if ([string]$t.type -eq 'page' -and -not $ws) { $ws = [string]$t.webSocketDebuggerUrl } } } catch {}
  }
  if (-not $ws) { try { $proc.Kill() } catch {}; return $null }
  $c = Open-Cdp $ws
  [void](Send-Cdp $c 'Page.enable'); [void](Send-Cdp $c 'DOM.enable'); [void](Send-Cdp $c 'Runtime.enable')
  return [pscustomobject]@{ cdp = $c; proc = $proc; profile = $prof; port = $port; exe = $exe }
}
function Stop-HikBrowserSession($s) {
  if (-not $s) { return }
  try { [void](Send-Cdp $s.cdp 'Browser.close' $null 3) } catch {}
  try { $s.cdp.ws.Dispose() } catch {}
  Start-Sleep -Milliseconds 500
  try { if (-not $s.proc.HasExited) { $s.proc.Kill() } } catch {}
  try { Start-Sleep -Milliseconds 300; Remove-Item -Recurse -Force -LiteralPath $s.profile -ErrorAction SilentlyContinue } catch {}
}


# a real mouse click at the middle of an element (some drop-downs on Hikvision's page open only for a real click, not a scripted one)
function Click-CdpSelector($c, [string]$Selector) {
  $pos = Invoke-CdpJs $c ('(function(s){ var e=document.querySelector(s); if(!e) return null; e.scrollIntoView({block:"center"}); var r=e.getBoundingClientRect(); return {x:Math.round(r.left+r.width/2), y:Math.round(r.top+r.height/2)}; })(' + ($Selector | ConvertTo-Json -Compress) + ')')
  if (-not $pos) { return $false }
  [void](Send-Cdp $c 'Input.dispatchMouseEvent' @{ type = 'mouseMoved'; x = $pos.x; y = $pos.y })
  [void](Send-Cdp $c 'Input.dispatchMouseEvent' @{ type = 'mousePressed'; x = $pos.x; y = $pos.y; button = 'left'; clickCount = 1 })
  [void](Send-Cdp $c 'Input.dispatchMouseEvent' @{ type = 'mouseReleased'; x = $pos.x; y = $pos.y; button = 'left'; clickCount = 1 })
  return $true
}

# types into a field the way a person does: real click, select-all, one key press per character, then Tab out. Hikvision's page floats its field labels
# and checks fields from key and focus events, so a value set by script reads back fine but can still LOOK empty (label drawn over it) - this does not.
function Type-PortalField($c, [string]$Name, [string]$Text) {
  $sel = 'form#enquiry-form input[name=' + $Name + ']'
  if (-not (Click-CdpSelector $c $sel)) { return 'missing' }
  Start-Sleep -Milliseconds 120
  [void](Invoke-CdpJs $c ('(function(s){var e=document.querySelector(s); e.focus(); e.select(); return 1})(' + ($sel | ConvertTo-Json -Compress) + ')'))
  [void](Send-Cdp $c 'Input.dispatchKeyEvent' @{ type = 'keyDown'; key = 'Backspace'; code = 'Backspace'; windowsVirtualKeyCode = 8 })
  [void](Send-Cdp $c 'Input.dispatchKeyEvent' @{ type = 'keyUp'; key = 'Backspace'; code = 'Backspace'; windowsVirtualKeyCode = 8 })
  foreach ($ch in $Text.ToCharArray()) {
    $t = [string]$ch
    [void](Send-Cdp $c 'Input.dispatchKeyEvent' @{ type = 'keyDown'; text = $t; unmodifiedText = $t; key = $t })
    [void](Send-Cdp $c 'Input.dispatchKeyEvent' @{ type = 'keyUp'; key = $t })
  }
  [void](Send-Cdp $c 'Input.dispatchKeyEvent' @{ type = 'keyDown'; key = 'Tab'; code = 'Tab'; windowsVirtualKeyCode = 9 })
  [void](Send-Cdp $c 'Input.dispatchKeyEvent' @{ type = 'keyUp'; key = 'Tab'; code = 'Tab'; windowsVirtualKeyCode = 9 })
  return [string](Invoke-CdpJs $c ('document.querySelector(' + ($sel | ConvertTo-Json -Compress) + ').value'))
}

# ---------------- the form ----------------
$script:PortalClickJs = 'function __hikClick(el){ ["mousedown","mouseup","click"].forEach(function(t){ el.dispatchEvent(new MouseEvent(t,{bubbles:true})) }) }'
function Wait-PortalForm($s, [int]$Seconds = 45) {
  $end = (Get-Date).AddSeconds($Seconds)
  while ((Get-Date) -lt $end) {
    try { if (Invoke-CdpJs $s.cdp 'document.readyState === "complete" && !!document.querySelector("form#enquiry-form input[name=firstName]")' 5) { return $true } } catch {}
    Start-Sleep -Milliseconds 700
  }
  return $false
}
# $form = config.json "form" (firstName lastName email company state zip businessType); $dev = { shortSerial; model; serial }; $file = the request file
function Fill-HikPortalForm($s, $form, $dev, [string]$File) {
  $c = $s.cdp; $res = [ordered]@{}
  $vals = [ordered]@{ firstName = [string]$form.firstName; lastName = [string]$form.lastName; email = [string]$form.email; company = [string]$form.company; zipCode = [string]$form.zip; serialNo = [string]$dev.shortSerial; modelNumber = [string]$dev.model }
  foreach ($k in $vals.Keys) {
    $got = ''; try { $got = Type-PortalField $c $k $vals[$k] } catch { $got = '' }
    if ($got -ceq $vals[$k]) { $res[$k] = 'ok' }
    else {
      $js = '(function(n,v){ var el=document.querySelector("form#enquiry-form input[name="+n+"]"); if(!el) return "missing"; var setter=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,"value").set; setter.call(el,v); ["input","change","blur"].forEach(function(t){el.dispatchEvent(new Event(t,{bubbles:true}))}); return el.value===v?"ok":"MISMATCH"; })(' + ($k | ConvertTo-Json -Compress) + ',' + ($vals[$k] | ConvertTo-Json -Compress) + ')'
      $res[$k] = [string](Invoke-CdpJs $c $js)
    }
  }
  # State (province) list and business type list: the page's own drop-downs, driven with the same events a click makes
  $st = [string]$form.state
  [void](Click-CdpSelector $c '#selected-province')
  [void](Invoke-CdpJs $c ($script:PortalClickJs + ';(function(){ var i=document.querySelector("#selected-province"); if(!i) return "missing"; i.focus(); i.dispatchEvent(new Event("focus")); __hikClick(i); return "opened"; })()'))
  Start-Sleep -Milliseconds 900
  $js = $script:PortalClickJs + ';(function(st){ var li=document.querySelector("#global-province li[data-value=\""+st+"\"]"); if(!li){ var all=[].slice.call(document.querySelectorAll("#global-province li")); li=all.filter(function(x){return x.textContent.trim()===st})[0]; } if(!li) return "no such state"; __hikClick(li); return document.querySelector("form#enquiry-form input[name=province]").value; })(' + ($st | ConvertTo-Json -Compress) + ')'
  $res.state = [string](Invoke-CdpJs $c $js); Start-Sleep -Milliseconds 600
  $bt = [string]$form.businessType
  [void](Invoke-CdpJs $c ($script:PortalClickJs + ';(function(){ var box=document.querySelector(".business-type .hik-select-input"); if(!box) return "missing"; __hikClick(box); return "opened"; })()'))
  Start-Sleep -Milliseconds 900
  $js = $script:PortalClickJs + ';(function(bt){ var li=document.querySelector(".business-type li[data-value=\""+bt+"\"]"); if(!li) return "no such type"; __hikClick(li); return "picked"; })(' + ($bt | ConvertTo-Json -Compress) + ')'
  $null = Invoke-CdpJs $c $js; Start-Sleep -Milliseconds 1500
  $res.businessType = [string](Invoke-CdpJs $c ($script:PortalClickJs + ';(function(){ var d=document.querySelector(".password-reset-dialog"); var x=document.querySelector(".password-reset-dialog .close-btn"); if(d && d.offsetWidth && x){ __hikClick(x); } return document.querySelector("form#enquiry-form input[name=type]").value; })()')); Start-Sleep -Milliseconds 600
  # the request file: DOM.setFileInputFiles on the page's own file box (what a click on "upload" ends in)
  if ($File) {
    $doc = Send-Cdp $c 'DOM.getDocument' @{ depth = 1 }
    $q = Send-Cdp $c 'DOM.querySelector' @{ nodeId = $doc.root.nodeId; selector = 'form#enquiry-form input[type=file]' }
    if ($q.nodeId) { [void](Send-Cdp $c 'DOM.setFileInputFiles' @{ files = @($File); nodeId = $q.nodeId }); Start-Sleep -Milliseconds 1200; $res.file = [string](Invoke-CdpJs $c '(function(){var e=document.querySelector(".file-display"); var i=document.querySelector("form#enquiry-form input[type=file]"); return (e&&e.innerText.trim())||((i&&i.files&&i.files.length)?i.files[0].name:"")})()') }
    else { $res.file = 'no file box on the page' }
  }
  # start time field (shown on some regions only)
  try { $res.startTimeField = [string](Invoke-CdpJs $c '(function(){var g=document.querySelector(".date-time-field"); return g?getComputedStyle(g).display:"none"})()') } catch {}
  return [pscustomobject]$res
}
function Test-PortalFilled($r, $dev) {
  # every field must read back what was typed; returns a list of problems (empty = fine)
  $bad = @(); foreach ($k in @('firstName', 'lastName', 'email', 'company', 'zipCode', 'serialNo', 'modelNumber')) { if ($r.PSObject.Properties[$k] -and $r.$k -ne 'ok') { $bad += ($k + ': ' + $r.$k) } elseif (-not $r.PSObject.Properties[$k]) { $bad += ($k + ': not filled') } }
  if ($r.PSObject.Properties['state'] -and ([string]$r.state -in @('', 'missing', 'no such state'))) { $bad += ('state: ' + $r.state) }
  if ($r.PSObject.Properties['businessType'] -and ([string]$r.businessType -in @('', 'missing', 'no such type'))) { $bad += ('business type: ' + $r.businessType) }
  if ($r.PSObject.Properties['file'] -and -not [string]$r.file) { $bad += 'request file did not attach' }
  return $bad
}
# puts the cursor in the picture-code box, brings the window forward and watches for the page to accept the form.
# Returns 'submitted' | 'timeout' | 'closed'. $Cancel is checked every few seconds.
function Wait-PortalSubmitted($s, [int]$TimeoutSec = 900, [scriptblock]$Tick = $null, [scriptblock]$Refill = $null) {
  $lastRefill = Get-Date
  $c = $s.cdp
  try { [void](Invoke-CdpJs $c '(function(){var i=document.querySelector("form#enquiry-form input[name=Verification]")||document.querySelector("form#enquiry-form input[maxlength=\"6\"]"); if(i){i.scrollIntoView({block:"center"}); i.focus();} window.__hikPosts=[]; (function(){ var ox=XMLHttpRequest.prototype.open, os=XMLHttpRequest.prototype.send; XMLHttpRequest.prototype.open=function(m,u){this.__m=m;this.__u=u;return ox.apply(this,arguments)}; XMLHttpRequest.prototype.send=function(){var x=this; x.addEventListener("loadend",function(){ if(String(x.__m).toUpperCase()==="POST") window.__hikPosts.push({u:String(x.__u).slice(0,160),s:x.status}); }); return os.apply(this,arguments)}; var of=window.fetch; window.fetch=function(i,o){ var p=of.apply(this,arguments); var m=(o&&o.method)||"GET"; if(String(m).toUpperCase()==="POST"){ var u=(typeof i==="string")?i:(i&&i.url); p.then(function(r){window.__hikPosts.push({u:String(u).slice(0,160),s:r.status})}).catch(function(){}); } return p; } })(); window.__hikClicked=0; var b=document.querySelector("#formSubmit"); if(b) b.addEventListener("click",function(){window.__hikClicked=(window.__hikClicked||0)+1},true); return 1})()') } catch {}
  try { [void](Send-Cdp $c 'Page.bringToFront') } catch {}
  $end = (Get-Date).AddSeconds($TimeoutSec); $clickedAt = $null; $lastTick = Get-Date
  while ((Get-Date) -lt $end) {
    Start-Sleep -Milliseconds 1500
    if ($Refill -and ((Get-Date) - $lastRefill).TotalSeconds -ge 8) { $lastRefill = Get-Date; try { & $Refill } catch {} }
    if ($Tick -and ((Get-Date) - $lastTick).TotalSeconds -ge 20) { $lastTick = Get-Date; try { & $Tick } catch {} }
    try {
      $st = Invoke-CdpJs $c '(function(){var f=document.querySelector("form#enquiry-form"); return {url:location.href, formShown: !!(f && f.offsetHeight>0), clicks: window.__hikClicked||0, posts: window.__hikPosts||[], modal: !!(document.querySelector("[class*=verify],[class*=captcha],[class*=slider]") && document.querySelector("[class*=verify],[class*=captcha],[class*=slider]").offsetHeight>0), text: (document.body&&document.body.innerText||"").slice(0,4000)}})()' 8
    } catch { if ($s.proc.HasExited) { return 'closed' }; continue }
    if ($st.clicks -gt 0 -and -not $clickedAt) { $clickedAt = Get-Date }
    $ok = ($st.text -match '(?i)(thank you|has been (successfully )?submitted|successfully submitted|submission (was )?successful|we have received|will (be )?(reply|respond|contact|send)|request (has been )?(received|sent))') -or $st.url -match '(?i)success|thank'
    if ($ok -and -not ($st.text -match '(?i)verification code (is )?(wrong|incorrect|error)|incorrect (verification|code)')) { return 'submitted' }
    if ($clickedAt -and -not $st.formShown) { return 'submitted' }
    # the form's own POST (not the puzzle check, not tracking) answered 2xx after the click
    $fp = @($st.posts | Where-Object { $_.u -notmatch '(?i)captcha|verify|slide|track|analytic|collect|log|cookie|beacon|geetest' -and [int]$_.s -ge 200 -and [int]$_.s -lt 300 })
    if ($clickedAt -and $fp.Count -and -not $st.modal -and ((Get-Date) - $clickedAt).TotalSeconds -gt 4) { $script:PortalLastPost = ($fp | ForEach-Object { $_.u }) -join ' '; return 'submitted' }
  }
  return 'timeout'
}
function Get-PortalPageText($s) { try { return [string](Invoke-CdpJs $s.cdp '(document.body&&document.body.innerText||"").slice(0,1500)' 8) } catch { return '' } }

# reads the visible fields; any that are empty (and not the one being typed in) are typed again. Returns the names it had to refill.
function Restore-PortalFields($s, $form, $dev) {
  $c = $s.cdp; $vals = [ordered]@{ firstName = [string]$form.firstName; lastName = [string]$form.lastName; email = [string]$form.email; company = [string]$form.company; zipCode = [string]$form.zip; serialNo = [string]$dev.shortSerial; modelNumber = [string]$dev.model }
  $now = Invoke-CdpJs $c '(function(){ var o={active:(document.activeElement&&document.activeElement.name)||"", v:{}}; document.querySelectorAll("form#enquiry-form input").forEach(function(i){ if(i.name) o.v[i.name]=i.value }); return o; })()' 8
  $fixed = @()
  foreach ($k in $vals.Keys) { $cur = [string]$now.v.$k; if ($cur -ne $vals[$k] -and $now.active -ne $k -and -not $cur) { [void](Type-PortalField $c $k $vals[$k]); $fixed += $k } }
  return $fixed
}
