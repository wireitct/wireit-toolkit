<#
 WireItToolkit.ps1 - the "WireIt Toolkit" window (Windows PowerShell 5.1 + Windows Forms, nothing to install).
 One window, big buttons, plain results. It runs the existing WireIt tools; it does not change how they work:
   C:\WireIt\CamReset (Find Cameras, Make-Request), C:\WireIt\FixNVR (Check / Fix / Snapshot / Rollback), C:\WireIt\NetCheck.
 Every run is logged to C:\WireIt\Toolkit\logs. Passwords are only typed into hidden prompts and are never saved or logged.
 Start: double-click "WireIt Toolkit" on the desktop (or "WireIt Toolkit.cmd").
 Switches: -NoUpdate (skip the update check)   -Screenshot <folder> (tests: draw the windows to PNG, no screen)
#>
param([string]$Screenshot = '', [switch]$NoUpdate, [string]$DemoCamReset = '', [string]$UpdatedFrom = '')
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'ToolkitCore.ps1')
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
if (-not $Screenshot) {
  try { Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public static class WireItDpi{[DllImport("user32.dll")]public static extern bool SetProcessDPIAware();}' -ErrorAction Stop; [void][WireItDpi]::SetProcessDPIAware() } catch {}
}
[Windows.Forms.Application]::EnableVisualStyles()

$TK = @{}
$TK.P = Get-TkPaths $here
if ($DemoCamReset) { $TK.P.CamReset = $DemoCamReset }
$TK.cfg = Get-TkConfig $here
$TK.ver = Get-TkVersion $here
$TK.psexe = Join-Path $PSHOME 'powershell.exe'
$TK.oem = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
$TK.run = $null
$TK.bw = ''
$TK.updateMsg = ''
$TK.rs = $null

# ---------------- one copy open at a time ----------------
if (-not $Screenshot) {
  $created = $false
  $TK.mutex = [Threading.Mutex]::new($true, 'Local\WireItToolkit', [ref]$created)
  if (-not $created) { [void][Windows.Forms.MessageBox]::Show('The WireIt Toolkit is already open (check the taskbar).', 'WireIt Toolkit'); exit 0 }
}

# ---------------- self-update (before the window opens; offline = just run) ----------------
if (-not $NoUpdate -and -not $Screenshot) {
  $u = Get-TkUpdateInfo $TK.cfg $here
  $TK.updateMsg = $u.message
  if ($u.state -eq 'available' -and $TK.cfg.autoUpdate -and ([string]$u.manifest.version -ne (Get-TkSkipVersion $here))) {
    try {
      $old = Install-TkUpdate $u.manifest $here
      Write-TkLog $TK.P.Logs 'update' ('Updated from ' + $old + ' to ' + $u.manifest.version + ' at ' + (Get-Date)) | Out-Null
      $TK.mutex.ReleaseMutex(); $TK.mutex.Dispose()
      Start-Process -FilePath $TK.psexe -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "' + (Join-Path $here 'WireItToolkit.ps1') + '" -NoUpdate -UpdatedFrom ' + $old) -WindowStyle Hidden
      exit 0
    } catch { $TK.updateMsg = $_.Exception.Message }
  }
}
if ($UpdatedFrom) { $TK.updateMsg = 'Updated itself from v' + $UpdatedFrom + '.' }

# ---------------- look ----------------
$g = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $TK.scale = [math]::Max(1.0, $g.DpiX / 96.0); $g.Dispose()
function Px([double]$n) { return [int]([math]::Round($n * $TK.scale)) }
$fBig = New-Object Drawing.Font('Segoe UI', 13, [Drawing.FontStyle]::Bold)
$fBtn = New-Object Drawing.Font('Segoe UI', 12.5, [Drawing.FontStyle]::Bold)
$fNorm = New-Object Drawing.Font('Segoe UI', 10.5)
$fBold = New-Object Drawing.Font('Segoe UI', 10.5, [Drawing.FontStyle]::Bold)
$fMono = New-Object Drawing.Font('Consolas', 10.5)
$cBlue = [Drawing.Color]::FromArgb(0, 84, 166); $cRed = [Drawing.Color]::FromArgb(176, 32, 32); $cGrey = [Drawing.Color]::FromArgb(240, 242, 245)

# ---------------- results pane helpers ----------------
function Add-Out([string]$text) {
  if ($null -eq $text) { return }
  $t = $text -replace "`r?`n", "`r`n"
  if (-not $t.EndsWith("`r`n")) { $t += "`r`n" }
  $TK.out.AppendText($t)
  if ($TK.run -and $TK.run.Log) { [void]$TK.run.Log.Append($t) }
}
function Set-Status([string]$s) { $TK.status.Text = $s }
function Set-Busy([bool]$b) { foreach ($x in $TK.buttons) { $x.Enabled = -not $b }; $TK.out.Cursor = $(if ($b) { [Windows.Forms.Cursors]::AppStarting } else { [Windows.Forms.Cursors]::IBeam }) }
function Set-Clip([string]$text, [string]$what) {
  if (-not $text) { Set-Status ('Nothing to copy for ' + $what); return }
  try { [Windows.Forms.Clipboard]::SetText($text); Set-Status ('Copied ' + $what + '. Paste it with Ctrl+V.') } catch { Set-Status ('Could not copy ' + $what) }
}
function Begin-Run([string]$name) {
  $TK.out.Clear()
  $TK.run = @{ Name = $name; Log = (New-Object Text.StringBuilder); Started = Get-Date }
  Add-Out ('=== ' + $name + ' - ' + (Get-Date -Format 'ddd MMM d, h:mm tt') + ' ===')
  Set-Busy $true; Set-Status ($name + ' is running...')
}
function End-Run([int]$code, [string]$plain) {
  $r = $TK.run; if (-not $r) { return }
  if ($plain) { Add-Out ''; Add-Out $plain }
  $logPath = Write-TkLog $TK.P.Logs $r.Name $r.Log.ToString()
  $TK.run = $null
  Set-Busy $false; Set-Status ($r.Name + ' done. Saved to the logs folder.')
  if ($r.OnDone) { try { & $r.OnDone $code } catch { Add-Out ('(after-run step failed: ' + $_.Exception.Message + ')') } }
}
function Test-Tool([string]$path, [string]$name) {
  if (Test-Path -LiteralPath $path) { return $true }
  Add-Out ($name + ' is not on this PC (' + $path + '). Copy the whole C:\WireIt folder from the other PC, or run Install-Toolkit again.')
  return $false
}

# hidden run: output streams into the results pane
function Start-Hidden([string]$name, [string]$file, [string]$argLine, [scriptblock]$onDone) {
  if ($TK.run) { Set-Status 'Wait for the running tool to finish.'; return $false }
  Begin-Run $name
  if (-not (Test-Tool $file $name)) { End-Run 2 ''; return $false }
  $outFile = Join-Path ([IO.Path]::GetTempPath()) ('wireit-tk-' + [guid]::NewGuid().ToString('N').Substring(0, 10) + '.txt')
  $psi = New-TkHiddenPsi $TK.psexe $file $argLine $outFile
  try { $proc = [Diagnostics.Process]::Start($psi) } catch { Add-Out ('Could not start: ' + $_.Exception.Message); End-Run 5 ''; return $false }
  $TK.run.Kind = 'hidden'; $TK.run.Proc = $proc; $TK.run.OutFile = $outFile; $TK.run.Offset = [long]0; $TK.run.OnDone = $onDone
  return $true
}

# console run (Fix NVR family): its own window for hidden password prompts and the typed YES; results come back here
function Start-Fix([string]$name, [string]$mode, [string[]]$extra, [scriptblock]$onDone) {
  if ($TK.run) { Set-Status 'Wait for the running tool to finish.'; return }
  Begin-Run $name
  $file = Join-Path $TK.P.FixNVR 'FixNVR.ps1'
  if (-not (Test-Tool $file 'Fix NVR')) { End-Run 2 ''; return }
  $a = '-NoProfile -ExecutionPolicy Bypass -File "' + $file + '" -Mode ' + $mode
  if ($TK.bw) { $a += ' -BitwardenExport "' + $TK.bw + '"' }
  foreach ($e in $extra) { if ($e) { $a += ' ' + $e } }
  Add-Out 'A blue tool window opens (Windows asks permission first: click Yes).'
  Add-Out 'Type passwords there - they are hidden and never saved. Results show up here as it works.'
  Add-Out ''
  $since = Get-Date
  try { $proc = Start-Process -FilePath $TK.psexe -ArgumentList $a -Verb RunAs -PassThru -WorkingDirectory $TK.P.FixNVR -ErrorAction Stop }
  catch { Add-Out 'Windows asked for permission and it was not given, so nothing ran.'; End-Run 2 ''; return }
  $TK.run.Kind = 'console'; $TK.run.Proc = $proc; $TK.run.Mode = $mode; $TK.run.Since = $since; $TK.run.RunDir = $null; $TK.run.Offset = [long]0; $TK.run.Shown = 0; $TK.run.OnDone = $onDone
}

function Poll-Run {
  $r = $TK.run; if (-not $r -or -not $r.Proc) { return }
  $exited = $false; try { $exited = $r.Proc.HasExited } catch { $exited = $true }
  if ($r.Kind -eq 'hidden') {
    $x = Read-TkShared $r.OutFile $r.Offset $TK.oem; $r.Offset = $x.offset
    if ($x.text) { Add-Out ($x.text.TrimEnd("`r", "`n")) }
    if ($exited) {
      Start-Sleep -Milliseconds 150
      $x = Read-TkShared $r.OutFile $r.Offset $TK.oem; if ($x.text) { Add-Out ($x.text.TrimEnd("`r", "`n")) }
      try { $rest = [IO.File]::ReadAllBytes($r.OutFile); if ($rest.Length -gt $x.offset) { Add-Out ($TK.oem.GetString($rest, [int]$x.offset, $rest.Length - [int]$x.offset)) } } catch {}
      $code = -1; try { $code = $r.Proc.ExitCode } catch {}
      Remove-Item -LiteralPath $r.OutFile -Force -ErrorAction SilentlyContinue
      End-Run $code (Get-TkPlainEnd $r.Name $code)
    }
  } else {
    if (-not $r.RunDir) { $d = Get-TkNewRunDir $TK.P.FixNVR $r.Mode $r.Since; if ($d) { $r.RunDir = $d.FullName } }
    if ($r.RunDir) {
      $x = Read-TkShared (Join-Path $r.RunDir 'log.txt') $r.Offset ([Text.Encoding]::UTF8); $r.Offset = $x.offset
      if ($x.text) { $said = ConvertFrom-TkFixLog ($x.text -split "`r?`n"); foreach ($l in $said) { Add-Out $l; $r.Shown++ } }
    }
    if ($exited) {
      $code = -1; try { $code = $r.Proc.ExitCode } catch {}
      if ($r.RunDir) {
        $x = Read-TkShared (Join-Path $r.RunDir 'log.txt') $r.Offset ([Text.Encoding]::UTF8)
        if ($x.text) { foreach ($l in (ConvertFrom-TkFixLog ($x.text -split "`r?`n"))) { Add-Out $l; $r.Shown++ } }
        $s = Join-Path $r.RunDir 'summary.txt'
        if ($r.Shown -eq 0 -and (Test-Path $s)) { Add-Out (Get-Content $s -Raw) }
        Add-Out ('(Full log: ' + $r.RunDir + ')')
      } elseif ($r.Shown -eq 0) { Add-Out 'The tool window closed before it started its work.' }
      if ($code -eq -1) { End-Run 0 ($r.Name + ': the tool window closed. Results are above.') } else { End-Run $code (Get-TkPlainEnd $r.Name $code) }
    }
  }
}

# ---------------- small input dialog ----------------
function Ask-Fields([string]$title, [string]$intro, $fields) {
  $f = New-Object Windows.Forms.Form; $f.Text = $title; $f.Font = $fNorm; $f.StartPosition = 'CenterParent'; $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false
  $f.AutoSize = $true; $f.AutoSizeMode = 'GrowAndShrink'; $f.Padding = New-Object Windows.Forms.Padding (Px 12)
  $t = New-Object Windows.Forms.TableLayoutPanel; $t.ColumnCount = 2; $t.AutoSize = $true; $t.Dock = 'Fill'
  $l0 = New-Object Windows.Forms.Label; $l0.Text = $intro; $l0.AutoSize = $true; $l0.MaximumSize = New-Object Drawing.Size((Px 520), 0); $t.Controls.Add($l0); $t.SetColumnSpan($l0, 2)
  $boxes = @{}
  foreach ($fd in $fields) {
    $l = New-Object Windows.Forms.Label; $l.Text = $fd[1]; $l.AutoSize = $true; $l.Anchor = 'Left'; $t.Controls.Add($l)
    $b = New-Object Windows.Forms.TextBox; $b.Width = Px 300; $b.Text = [string]$fd[2]; $t.Controls.Add($b); $boxes[$fd[0]] = $b
  }
  $ok = New-Object Windows.Forms.Button; $ok.Text = 'OK'; $ok.DialogResult = 'OK'; $ok.AutoSize = $true; $ok.Height = Px 34
  $cn = New-Object Windows.Forms.Button; $cn.Text = 'Cancel'; $cn.DialogResult = 'Cancel'; $cn.AutoSize = $true; $cn.Height = Px 34
  $fl = New-Object Windows.Forms.FlowLayoutPanel; $fl.AutoSize = $true; $fl.Controls.AddRange(@($ok, $cn)); $t.Controls.Add($fl); $t.SetColumnSpan($fl, 2)
  $f.Controls.Add($t); $f.AcceptButton = $ok; $f.CancelButton = $cn
  if ($f.ShowDialog($TK.form) -ne 'OK') { return $null }
  $res = @{}; foreach ($k in $boxes.Keys) { $res[$k] = $boxes[$k].Text.Trim() }; return $res
}
function Q([string]$s) { return '"' + ($s -replace '"', '') + '"' }

# ---------------- the 7 jobs ----------------
function Do-Find {
  [void](Start-Hidden 'Find cameras' (Join-Path $TK.P.CamReset 'Find-Cameras.ps1') '' {
    param($code)
    $d = @(Get-TkDevices $TK.P.CamReset)
    if ($d.Count) {
      $hik = @($d | Where-Object { $_.Brand -like 'Hikvision*' }).Count; $unv = @($d | Where-Object { $_.Brand -eq 'Uniview' }).Count
      $other = @($d | Where-Object { $_.Status -like '*different IP scheme*' }).Count
      Add-Out ('In short: ' + $d.Count + ' device(s) found - ' + $hik + ' Hikvision, ' + $unv + ' Uniview' + $(if ($other) { '; ' + $other + ' on a different IP scheme (button 3 Fix NVR moves them)' } else { '' }) + '.')
      if ($TK.log) { }
    }
    if ($TK.rs -and $TK.rs.form -and -not $TK.rs.form.IsDisposed) { Fill-ResetList }
  })
}
function Fix-Extras { $e = @(); if ($TK.site.Text.Trim()) { $e += '-Site ' + (Q $TK.site.Text.Trim()) }; if ($TK.lone.Checked) { $e += '-MoveUnlisted' }; return $e }
function Do-Check { Start-Fix 'Check NVR' 'Check' (Fix-Extras) $null }
function Do-Fix {
  Start-Fix 'Fix NVR' 'Fix' (Fix-Extras) $null
  if ($TK.run) { Add-Out 'Fix NVR first shows the plan. Nothing changes until you type YES in its window.'; Add-Out '' }
}
function Do-Net {
  $nc = Join-Path $TK.P.NetCheck 'NetCheck.ps1'
  $od = Join-Path $TK.P.NetCheck ('runs\NetCheck-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
  [void](Start-Hidden 'Network check' $nc ('-OutDir ' + (Q $od)) $null)
  if ($TK.run) { Add-Out 'Read-only: pings every address, reads cable speed and errors. Takes about a minute.'; Add-Out '' }
}
function Do-Snapshot {
  $a = Ask-Fields 'Save install snapshot' 'Saves a known-good record of the NVR and cameras (no passwords). Fill what you know; blanks are fine.' @(
    @('site', 'Site (Drive folder name):', $TK.site.Text), @('router', 'Router make/model (e.g. Xfinity XB8):', ''), @('range', 'Router DHCP range (e.g. 100-254, or reserved):', ''))
  if (-not $a) { return }
  $e = @(); if ($a.site) { $e += '-Site ' + (Q $a.site); $TK.site.Text = $a.site }; if ($a.router) { $e += '-RouterModel ' + (Q $a.router) }; if ($a.range) { $e += '-DhcpRange ' + (Q $a.range) }
  Start-Fix 'Install snapshot' 'Snapshot' $e $null
}
function Do-Undo {
  if (-not (Test-Path (Join-Path $TK.P.FixNVR 'FixNVR.ps1'))) { $TK.out.Clear(); Add-Out 'Fix NVR is not on this PC.'; return }
  $last = Get-TkLastFix $TK.P.FixNVR
  if (-not $last) { $TK.out.Clear(); Add-Out 'There is no Fix NVR run on this PC to undo.'; return }
  $msg = 'Put the NVR and cameras back the way they were before the fix of ' + $last.When.ToString('ddd MMM d, h:mm tt') + '?'
  if ($last.Undone) { $msg = 'That fix (' + $last.When.ToString('ddd MMM d, h:mm tt') + ') was already undone once. Undo it again?' }
  if ([Windows.Forms.MessageBox]::Show($TK.form, $msg, 'Undo last fix', 'YesNo', 'Question') -ne 'Yes') { return }
  $folder = $last.Folder
  Start-Fix 'Undo last fix' 'Rollback' @('-RollbackFile ' + (Q $last.File)) ([scriptblock]::Create('param($code) if ($code -eq 0) { Set-Content -Path ' + (Q (Join-Path $folder 'undone.txt')) + ' -Value (Get-Date -Format s) }'))
}

# ---------------- 4 Reset passwords (Hikvision) ----------------
function New-Btn([string]$text, [scriptblock]$click, $tag = $null) {
  $b = New-Object Windows.Forms.Button; $b.Text = $text; $b.AutoSize = $true; $b.MinimumSize = New-Object Drawing.Size((Px 90), (Px 36)); $b.Font = $fNorm; $b.Tag = $tag
  $b.Margin = New-Object Windows.Forms.Padding (Px 3); if ($click) { $b.Add_Click($click) }; return $b
}
function New-Lbl([string]$text, $font = $null, [int]$width = 0) {
  $l = New-Object Windows.Forms.Label; $l.Text = $text; $l.AutoSize = $true; if ($font) { $l.Font = $font } else { $l.Font = $fNorm }
  if ($width -gt 0) { $l.MaximumSize = New-Object Drawing.Size($width, 0) }; $l.Margin = New-Object Windows.Forms.Padding (Px 3); return $l
}
function New-Step([string]$title) {
  $W = $TK.rs.W
  $hdr = New-Lbl $title $fBig $W; $hdr.ForeColor = $cBlue; $hdr.Margin = New-Object Windows.Forms.Padding((Px 3), (Px 14), (Px 3), (Px 2))
  $TK.rs.flow.Controls.Add($hdr)
  $fl = New-Object Windows.Forms.FlowLayoutPanel; $fl.AutoSize = $true; $fl.WrapContents = $true; $fl.MaximumSize = New-Object Drawing.Size($W, 0); $fl.MinimumSize = New-Object Drawing.Size($W, 0)
  $TK.rs.flow.Controls.Add($fl); $TK.rs.flow.SetFlowBreak($fl, $true)
  return $fl
}
function Find-HiTools { foreach ($h in @($TK.cfg.hiTools)) { if ($h -and (Test-Path -LiteralPath $h)) { return $h } }; return '' }
function Open-HiTools {
  $h = Find-HiTools
  if (-not $h) { Set-Status 'HiTools Delivery is not installed on this PC (free from hikvision.com).'; return }
  try { Start-Process -FilePath $h -WorkingDirectory (Split-Path -Parent $h); Set-Status 'HiTools is opening (give it a few seconds).' } catch { Set-Status ('HiTools did not open: ' + $_.Exception.Message) }
}
function Rs-Log([string]$s) { Write-TkLog $TK.P.Logs 'reset-passwords' ((Get-Date -Format 's') + ' ' + $s) | Out-Null }

function Fill-ResetList {
  $rs = $TK.rs; $lv = $rs.list; $lv.Items.Clear()
  $devs = @(Get-TkDevices $TK.P.CamReset)
  foreach ($d in $devs) {
    $it = New-Object Windows.Forms.ListViewItem([string]$d.Brand)
    foreach ($v in @($d.Model, $d.ShortSerial, $d.IP, $d.Status)) { [void]$it.SubItems.Add([string]$v) }
    $it.Tag = $d; [void]$lv.Items.Add($it)
  }
  $st = Get-TkScanTime $TK.P.CamReset
  if ($devs.Count) { $rs.scanLbl.Text = 'From the scan of ' + $st + '. Click the device to reset.' } else { $rs.scanLbl.Text = 'No scan yet on this PC. Click "Scan now" (read-only, about 15 seconds).' }
  if ($devs.Count -eq 1) { $lv.Items[0].Selected = $true }
}
function Get-Req($dev) {
  if (-not $dev) { return $null }
  return (Get-TkRequests $TK.P.CamReset | Where-Object { $_.shortSerial -eq $dev.ShortSerial -or $_.serial -eq $dev.Serial } | Select-Object -First 1)
}
function Show-Selected {
  $rs = $TK.rs; $d = $rs.dev
  foreach ($b in $rs.fieldBtns) { $b.Dispose() }; $rs.fieldBtns = @()
  foreach ($f in (Get-TkFormFields $TK.cfg $d)) {
    $b = New-Btn ($f.Label + ':  ' + $f.Value) { Set-Clip $this.Tag.Value $this.Tag.Label } $f
    $rs.fields.Controls.Add($b); $rs.fieldBtns += $b
  }
  $note = ''
  if (-not $d) { $rs.devLbl.Text = 'No device picked yet.'; return }
  $rs.devLbl.Text = 'Picked: ' + $d.Brand + ' ' + $d.Model + '   serial ' + $d.ShortSerial + '   IP ' + $d.IP
  if ($d.Activated -eq 'false') { $note = 'This one is factory fresh: NO reset needed. In HiTools, tick it > Activate, and use a password from step 5.' }
  elseif ($d.Brand -eq 'Uniview') { $note = $(if ($d.DefaultLoginWorks -eq 'YES') { 'Uniview with the factory password (admin/123456): NO reset needed. Log in and set a password from step 5.' } else { 'Uniview: this screen is for Hikvision. Locked Uniview cameras use the Uniview bulk form (CamReset README, step U).' }) }
  elseif ($d.Brand -notlike 'Hikvision*') { $note = 'Not a Hikvision device.' }
  $rs.noteLbl.Text = $note
  $q = Get-Req $d; $rs.req = $q; Show-Req
}
function Show-Req {
  $rs = $TK.rs; $q = $rs.req
  if ($q) {
    $hl = Get-TkHoursLeft $q
    $rs.xmlLbl.Text = 'Reset file ready: ' + $q.xmlFile + '. ' + $(if ($hl -ge 0) { 'Good for about ' + $hl + ' more hours.' } else { 'OLD: the 48 hours are over, export a new one.' }) + ' Do NOT unplug or reboot the device until the reset is done.'
    $rs.xmlLbl.ForeColor = $(if ($hl -ge 0) { [Drawing.Color]::DarkGreen } else { $cRed })
    if ($q.replyFile) { $rs.replyLbl.Text = 'Reply file in: ' + $q.replyFile; $rs.replyLbl.ForeColor = [Drawing.Color]::DarkGreen }
  } else {
    $rs.xmlLbl.Text = 'Waiting for the exported file (the Toolkit watches the save folder and Downloads).'; $rs.xmlLbl.ForeColor = [Drawing.Color]::Black
  }
}
function Get-XmlPath { $q = $TK.rs.req; if ($q) { return (Join-Path $q.folder ([string]$q.xmlFile)) }; return '' }
function Use-Xml([string]$path) {
  $rs = $TK.rs; $rs.watch = $false
  $a = '-XmlPath ' + (Q $path); if ($rs.dev) { $a += ' -Serial ' + (Q $rs.dev.ShortSerial) }
  $ok = Start-Hidden 'Reset request' (Join-Path $TK.P.CamReset 'Make-Request.ps1') $a {
    param($code)
    $rs = $TK.rs; if (-not $rs -or $rs.form.IsDisposed) { return }
    if ($rs.dev) { $rs.req = Get-Req $rs.dev } else { $rs.req = Get-TkRequests $TK.P.CamReset | Select-Object -First 1 }
    Show-Req
    if ($code -eq 0 -and $rs.req) { Rs-Log ('request filed for ' + $rs.req.model + ' ' + $rs.req.shortSerial) }
    else { $rs.xmlLbl.Text = 'That file could not be matched to a device. Pick the device in step 1 (or run Scan now), then pick the file again.'; $rs.xmlLbl.ForeColor = $cRed }
  }
  if (-not $ok) { $rs.xmlLbl.Text = 'Another tool is still running; pick the file again in a moment.' }
}
function Take-Reply([string]$path) {
  $rs = $TK.rs; $pref = ''; if ($rs.dev) { $pref = $rs.dev.ShortSerial }
  $r = Import-TkReply $path $TK.P.CamReset $pref
  $rs.replyLbl.Text = $r.message; $rs.replyLbl.ForeColor = $(if ($r.ok -and $r.request) { [Drawing.Color]::DarkGreen } else { $cRed })
  if ($r.ok) { $rs.replyFile = $r.file; if ($r.request) { $rs.req = Get-TkRequests $TK.P.CamReset | Where-Object { $_.serial -eq $r.request.serial } | Select-Object -First 1 }; Rs-Log ('reply file filed: ' + $r.file) }
}
function Show-ResetWindow([string]$dropFile = '') {
  $rs = @{ fieldBtns = @(); dev = $null; req = $null; watch = $false; watchSince = (Get-Date); replyFile = ''; pw = ''; lastWatch = (Get-Date) }
  $TK.rs = $rs
  $f = New-Object Windows.Forms.Form; $rs.form = $f
  $f.Text = 'WireIt Toolkit - Reset passwords (Hikvision, official method)'; $f.Font = $fNorm; $f.BackColor = [Drawing.Color]::White
  $wa = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $f.Size = New-Object Drawing.Size([math]::Min((Px 1060), [int]($wa.Width * 0.95)), [math]::Min((Px 900), [int]($wa.Height * 0.95))); $f.StartPosition = 'CenterScreen'
  $f.AllowDrop = $true
  $rs.W = $f.ClientSize.Width - (Px 50)
  $flow = New-Object Windows.Forms.FlowLayoutPanel; $flow.Dock = 'Fill'; $flow.FlowDirection = 'TopDown'; $flow.WrapContents = $false; $flow.AutoScroll = $true; $flow.Padding = New-Object Windows.Forms.Padding (Px 10)
  $rs.flow = $flow; $f.Controls.Add($flow)
  $W = $rs.W
  $flow.Controls.Add((New-Lbl 'Unknown password on a Hikvision camera or NVR: Hikvision unlocks it with a reset file. You type the picture code on their form; the Toolkit does the rest. Go top to bottom.' $fNorm $W))

  $s1 = New-Step '1  Pick the device'
  $lv = New-Object Windows.Forms.ListView; $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.HideSelection = $false; $lv.MultiSelect = $false; $lv.Font = $fNorm
  $lv.Size = New-Object Drawing.Size($W, (Px 150))
  foreach ($c in @(@('Brand', 110), @('Model', 210), @('Serial (9)', 120), @('IP', 130), @('Status', 400))) { [void]$lv.Columns.Add($c[0], (Px $c[1])) }
  $lv.Add_SelectedIndexChanged({ if ($TK.rs.list.SelectedItems.Count) { $TK.rs.dev = $TK.rs.list.SelectedItems[0].Tag } else { $TK.rs.dev = $null }; Show-Selected })
  $rs.list = $lv; $s1.Controls.Add($lv)
  $rs.scanLbl = New-Lbl '' $null ($W - (Px 200)); $s1.Controls.Add((New-Btn 'Scan now' { Do-Find })); $s1.Controls.Add($rs.scanLbl)
  $rs.devLbl = New-Lbl '' $fBold $W; $s1.Controls.Add($rs.devLbl); $s1.SetFlowBreak($rs.devLbl, $true)
  $rs.noteLbl = New-Lbl '' $fBold $W; $rs.noteLbl.ForeColor = $cRed; $s1.Controls.Add($rs.noteLbl)

  $s2 = New-Step '2  Make the reset file in HiTools (about 30 seconds)'
  $exportDir = Join-Path $TK.P.CamReset 'requests\export'
  $s2.Controls.Add((New-Lbl ('Open HiTools > tick the device > Reset Password > Import/Export Key > Export XML File > save it in ' + $exportDir + '  (click "Copy save folder", paste it in the save box). NVR: one file also covers its cameras if you tick them too.') $null $W))
  $s2.Controls.Add((New-Btn 'Open HiTools' { Open-HiTools }))
  $s2.Controls.Add((New-Btn 'Copy save folder' { New-Item -ItemType Directory -Force -Path $this.Tag | Out-Null; Set-Clip $this.Tag 'the save folder' } $exportDir))
  $s2.Controls.Add((New-Btn 'I saved it somewhere else - pick the file' {
    $o = New-Object Windows.Forms.OpenFileDialog; $o.Filter = 'Hikvision export (*.xml)|*.xml|All files|*.*'; $o.Title = 'Pick the XML file HiTools exported'
    if ($o.ShowDialog($TK.rs.form) -eq 'OK') { Use-Xml $o.FileName } }))
  $rs.xmlLbl = New-Lbl '' $fBold $W; $s2.Controls.Add($rs.xmlLbl)

  $s3 = New-Step '3  Send it to Hikvision (their US form)'
  $s3.Controls.Add((New-Lbl 'Click "Open the Hikvision form", then click each button below and paste (Ctrl+V) into the matching box. Upload: click "Copy XML file path", paste it into the File name box and press Enter. Tick the owner/authorized statement, type the picture code, Submit.' $null $W))
  $s3.Controls.Add((New-Btn 'Open the Hikvision form' { try { Start-Process ([string]$TK.cfg.hikvisionForm) } catch { Set-Status 'Could not open the browser.' } }))
  $s3.Controls.Add((New-Btn 'Copy XML file path' { Set-Clip (Get-XmlPath) 'the XML file path' }))
  $s3.Controls.Add((New-Btn 'Show XML file' { $x = Get-XmlPath; if ($x -and (Test-Path -LiteralPath $x)) { Start-Process explorer.exe ('/select,"' + $x + '"') } else { Set-Status 'No XML file yet (step 2).' } }))
  $fields = New-Object Windows.Forms.FlowLayoutPanel; $fields.AutoSize = $true; $fields.MaximumSize = New-Object Drawing.Size($W, 0); $fields.MinimumSize = New-Object Drawing.Size($W, 0); $rs.fields = $fields; $s3.Controls.Add($fields)
  $s3.Controls.Add((New-Lbl ('The answer goes to ' + $TK.cfg.form.email + ' (usually a few hours). It is only good for 48 hours and only if the device has NOT rebooted.') $null $W))

  $s4 = New-Step '4  When Hikvision emails back: drag the attached file here'
  $drop = New-Object Windows.Forms.Label; $drop.Text = 'Drag the file from Hikvision''s email here' + "`r`n" + '(save the attachment first, then drag it onto this box, or onto the Toolkit window)'
  $drop.TextAlign = 'MiddleCenter'; $drop.BorderStyle = 'FixedSingle'; $drop.BackColor = $cGrey; $drop.Font = $fBold; $drop.Size = New-Object Drawing.Size(($W - (Px 220)), (Px 80)); $drop.AllowDrop = $true
  $s4.Controls.Add($drop)
  $s4.Controls.Add((New-Btn 'Pick the file' { $o = New-Object Windows.Forms.OpenFileDialog; $o.Filter = 'Hikvision reply (*.xml;*.zip;*.txt)|*.xml;*.zip;*.txt|All files|*.*'; if ($o.ShowDialog($TK.rs.form) -eq 'OK') { Take-Reply $o.FileName } }))
  $rs.replyLbl = New-Lbl '' $fBold $W; $s4.Controls.Add($rs.replyLbl)
  $dragEnter = { if ($_.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) { $_.Effect = 'Copy' } }
  $dragDrop = { $files = $_.Data.GetData([Windows.Forms.DataFormats]::FileDrop); if ($files) { Take-Reply ([string]$files[0]) } }
  $drop.Add_DragEnter($dragEnter); $drop.Add_DragDrop($dragDrop); $f.Add_DragEnter($dragEnter); $f.Add_DragDrop($dragDrop)

  $s5 = New-Step '5  Put it in and set the new password'
  $s5.Controls.Add((New-Lbl 'HiTools > tick the device > Reset Password > Reset via XML File (or Import Key) > pick the reply file (click "Copy reply file path", paste, Enter) > paste the new password in both boxes > OK. NVR: tick "also reset the connected cameras".' $null $W))
  $s5.Controls.Add((New-Btn 'Make a new password' {
    $TK.rs.pw = New-TkPassword ([int]$TK.cfg.passwordLength); $TK.rs.pwBox.Text = $TK.rs.pw; $TK.rs.pwBox.Visible = $true
    Rs-Log 'new password made (not logged)'; Set-Status 'New password made. Copy it into HiTools, then save it in Bitwarden.' }))
  $pwBox = New-Object Windows.Forms.TextBox; $pwBox.ReadOnly = $true; $pwBox.Font = New-Object Drawing.Font('Consolas', 16, [Drawing.FontStyle]::Bold); $pwBox.Width = Px 260; $pwBox.Visible = $false; $rs.pwBox = $pwBox
  $s5.Controls.Add($pwBox)
  $s5.Controls.Add((New-Btn 'Copy password' { Set-Clip $TK.rs.pw 'the new password' }))
  $s5.Controls.Add((New-Btn 'Copy reply file path' { $r = $TK.rs.replyFile; if (-not $r -and $TK.rs.req -and $TK.rs.req.replyFile) { $r = [string]$TK.rs.req.replyFile }; Set-Clip $r 'the reply file path' }))
  $s5.Controls.Add((New-Btn 'Open HiTools' { Open-HiTools }))
  $s5.Controls.Add((New-Lbl 'Save it in Bitwarden right away (WireIt CT > Sites): name = site + model + serial, user admin, the new password.' $fBold $W))
  $s5.Controls.Add((New-Btn 'Copy Bitwarden name' { $d = $TK.rs.dev; $n = ''; if ($TK.site.Text.Trim()) { $n = $TK.site.Text.Trim() + ' - ' }; if ($d) { $n += $d.Model + ' ' + $d.ShortSerial }; Set-Clip $n 'the Bitwarden item name' }))
  $s5.Controls.Add((New-Btn 'Open Bitwarden' { try { Start-Process ([string]$TK.cfg.bitwardenUrl) } catch {} }))
  $s5.Controls.Add((New-Btn 'Saved in Bitwarden - hide it' { Clear-Pw; Set-Status 'Password hidden and cleared from the clipboard.' }))

  $s6 = New-Step 'Other way (no email wait): Reset via QR Code'
  $s6.Controls.Add((New-Lbl 'HiTools > tick the device > Reset Password > Reset via QR Code > scan the QR with the Hik-Partner Pro app (WireIt CT account) > open an online support case. The code comes back in the app; type it into HiTools with the new password from step 5.' $null $W))

  $f.Add_FormClosing({ Clear-Pw; $TK.rs.watch = $false })
  $f.Add_Shown({ Fill-ResetList; Show-Selected; $TK.rs.watch = $true; $TK.rs.watchSince = (Get-Date).AddMinutes(-1) })
  if ($dropFile) { $rs.pendingDrop = $dropFile; $f.Add_Shown({ Take-Reply $TK.rs.pendingDrop }) }
  if ($Screenshot) { return $f }
  [void]$f.ShowDialog($TK.form)
  $TK.rs = $null
}
function Clear-Pw {
  $rs = $TK.rs; if (-not $rs) { return }
  try { if ($rs.pw -and [Windows.Forms.Clipboard]::ContainsText() -and [Windows.Forms.Clipboard]::GetText() -eq $rs.pw) { [Windows.Forms.Clipboard]::Clear() } } catch {}
  $rs.pw = ''; if ($rs.pwBox) { $rs.pwBox.Text = ''; $rs.pwBox.Visible = $false }
}
function Watch-Export {
  $rs = $TK.rs; if (-not $rs -or -not $rs.watch -or $TK.run) { return }
  if (((Get-Date) - $rs.lastWatch).TotalSeconds -lt 2) { return }; $rs.lastWatch = Get-Date
  $x = @(Find-TkNewXml (Get-TkExportDirs $TK.P.CamReset) $rs.watchSince)
  if ($x.Count) {
    $known = @(Get-TkRequests $TK.P.CamReset | ForEach-Object { [string]$_.xmlFile })
    if ($known -notcontains $x[0].Name -or -not $rs.req) { $rs.watchSince = $x[0].LastWriteTime; Use-Xml $x[0].FullName; $rs.xmlLbl.Text = 'Found ' + $x[0].Name + ' - filing it...' }
    else { $rs.watchSince = $x[0].LastWriteTime }
  }
}

# ---------------- main window ----------------
$form = New-Object Windows.Forms.Form; $TK.form = $form
$form.Text = 'WireIt Toolkit  v' + $TK.ver; $form.Font = $fNorm; $form.BackColor = [Drawing.Color]::White; $form.AllowDrop = $true
$ico = Join-Path $here 'wireit.ico'; if (Test-Path $ico) { try { $form.Icon = New-Object Drawing.Icon($ico) } catch {} }
$wa = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Size = New-Object Drawing.Size([math]::Min((Px 1180), [int]($wa.Width * 0.95)), [math]::Min((Px 800), [int]($wa.Height * 0.95))); $form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object Drawing.Size((Px 800), (Px 560))

$root = New-Object Windows.Forms.TableLayoutPanel; $root.Dock = 'Fill'; $root.ColumnCount = 2; $root.RowCount = 3; $root.Padding = New-Object Windows.Forms.Padding (Px 10)
[void]$root.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 36))); [void]$root.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 64)))
[void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize'))); [void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100))); [void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize')))
$form.Controls.Add($root)

$title = New-Object Windows.Forms.Label; $title.Text = 'WireIt Toolkit'; $title.Font = New-Object Drawing.Font('Segoe UI', 18, [Drawing.FontStyle]::Bold); $title.ForeColor = $cBlue; $title.AutoSize = $true
$root.Controls.Add($title, 0, 0)
$upd = New-Object Windows.Forms.Label; $upd.AutoSize = $true; $upd.Anchor = 'Right'; $upd.ForeColor = [Drawing.Color]::DimGray
$upd.Text = 'v' + $TK.ver + $(if ($TK.updateMsg) { '  -  ' + $TK.updateMsg } elseif ($NoUpdate) { '' } else { '' })
$root.Controls.Add($upd, 1, 0)

$left = New-Object Windows.Forms.TableLayoutPanel; $left.Dock = 'Fill'; $left.ColumnCount = 1; $left.RowCount = 8; $left.Margin = New-Object Windows.Forms.Padding 0
for ($i = 0; $i -lt 7; $i++) { [void]$left.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 14.28))) }
[void]$left.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize')))
$jobs = @(
  @('1   Find cameras', 'Read-only. Lists every Hikvision / Uniview camera and NVR, even on another IP scheme.', { Do-Find }),
  @('2   Check NVR', 'Read-only. Shows what is wrong (IP scheme, DNS, app access) and the fix plan.', { Do-Check }),
  @('3   Fix NVR', 'Shows the plan, then fixes it after you type YES. Can be undone with 7.', { Do-Fix }),
  @('4   Reset passwords (Hikvision)', 'Unknown password: reset file, Hikvision form, new password.', { Show-ResetWindow }),
  @('5   Network check', 'Read-only. Cable speed, errors, ping every device.', { Do-Net }),
  @('6   Save install snapshot', 'Install day: saves a known-good record (no passwords).', { Do-Snapshot }),
  @('7   Undo last fix', 'Puts the NVR and cameras back the way the last Fix found them.', { Do-Undo })
)
$tips = New-Object Windows.Forms.ToolTip
$TK.buttons = @()
$row = 0
foreach ($j in $jobs) {
  $b = New-Object Windows.Forms.Button; $b.Text = $j[0]; $b.Font = $fBtn; $b.Dock = 'Fill'; $b.TextAlign = 'MiddleLeft'; $b.Padding = New-Object Windows.Forms.Padding((Px 10), 0, 0, 0)
  $b.Margin = New-Object Windows.Forms.Padding((Px 2), (Px 3), (Px 8), (Px 3)); $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderColor = $cBlue; $b.BackColor = $cGrey; $b.ForeColor = $cBlue
  if ($row -eq 2) { $b.BackColor = [Drawing.Color]::FromArgb(255, 244, 229); $b.ForeColor = [Drawing.Color]::FromArgb(150, 70, 0); $b.FlatAppearance.BorderColor = $b.ForeColor }
  $b.Add_Click($j[2]); $tips.SetToolTip($b, $j[1])
  $left.Controls.Add($b, 0, $row); $TK.buttons += $b; $row++
}
$opt = New-Object Windows.Forms.TableLayoutPanel; $opt.ColumnCount = 2; $opt.AutoSize = $true; $opt.Dock = 'Fill'; $opt.Margin = New-Object Windows.Forms.Padding(0, (Px 8), 0, 0)
$l1 = New-Object Windows.Forms.Label; $l1.Text = 'Site (optional):'; $l1.AutoSize = $true; $l1.Anchor = 'Left'; $opt.Controls.Add($l1, 0, 0)
$site = New-Object Windows.Forms.TextBox; $site.Dock = 'Fill'; $TK.site = $site; $opt.Controls.Add($site, 1, 0); $tips.SetToolTip($site, 'Site folder name as in Google Drive (finds/saves the snapshot). Used by 2, 3 and 6.')
$lone = New-Object Windows.Forms.CheckBox; $lone.Text = 'Also move lone cameras (not on an NVR list)'; $lone.AutoSize = $true; $TK.lone = $lone; $opt.Controls.Add($lone, 0, 1); $opt.SetColumnSpan($lone, 2)
$pwType = New-Object Windows.Forms.RadioButton; $pwType.Text = 'Passwords: type them when asked (hidden)'; $pwType.AutoSize = $true; $pwType.Checked = $true; $opt.Controls.Add($pwType, 0, 2); $opt.SetColumnSpan($pwType, 2)
$pwBw = New-Object Windows.Forms.RadioButton; $pwBw.Text = 'Passwords: from a Bitwarden export file...'; $pwBw.AutoSize = $true; $opt.Controls.Add($pwBw, 0, 3); $opt.SetColumnSpan($pwBw, 2)
$TK.pwType = $pwType; $TK.pwBw = $pwBw
$pwBw.Add_Click({
  $o = New-Object Windows.Forms.OpenFileDialog; $o.Filter = 'Bitwarden export (*.json)|*.json'; $o.Title = 'Pick the Bitwarden export (.json, unencrypted)'
  if ($o.ShowDialog($TK.form) -eq 'OK') { $TK.bw = $o.FileName; $TK.pwBw.Text = 'Passwords: from ' + [IO.Path]::GetFileName($o.FileName) + ' (delete it when done)' }
  else { $TK.bw = ''; $TK.pwType.Checked = $true }
})
$pwType.Add_Click({ $TK.bw = ''; $TK.pwBw.Text = 'Passwords: from a Bitwarden export file...' })
$left.Controls.Add($opt, 0, 7)
$root.Controls.Add($left, 0, 1)

$out = New-Object Windows.Forms.TextBox; $out.Multiline = $true; $out.ReadOnly = $true; $out.ScrollBars = 'Vertical'; $out.WordWrap = $true; $out.Font = $fMono; $out.BackColor = [Drawing.Color]::FromArgb(250, 251, 252); $out.Dock = 'Fill'
$TK.out = $out; $root.Controls.Add($out, 1, 1)

$foot = New-Object Windows.Forms.FlowLayoutPanel; $foot.AutoSize = $true; $foot.Dock = 'Fill'; $foot.WrapContents = $false
$foot.Controls.Add((New-Btn 'Copy results' { Set-Clip $TK.out.Text 'the results' }))
$foot.Controls.Add((New-Btn 'Open logs folder' { New-Item -ItemType Directory -Force -Path $TK.P.Logs | Out-Null; Start-Process explorer.exe (Q $TK.P.Logs) }))
$foot.Controls.Add((New-Btn 'Go back to the previous version' {
  if ([Windows.Forms.MessageBox]::Show($TK.form, 'Go back to the Toolkit version that was installed before the last update?', 'WireIt Toolkit', 'YesNo', 'Question') -ne 'Yes') { return }
  try { $v = Undo-TkUpdate $here; [void][Windows.Forms.MessageBox]::Show($TK.form, ('Back on version ' + $v + '. The Toolkit will close; open it again.'), 'WireIt Toolkit'); $TK.form.Close() }
  catch { [void][Windows.Forms.MessageBox]::Show($TK.form, $_.Exception.Message, 'WireIt Toolkit') } }))
$status = New-Object Windows.Forms.Label; $status.AutoSize = $true; $status.Anchor = 'Left'; $status.ForeColor = [Drawing.Color]::DimGray; $status.Margin = New-Object Windows.Forms.Padding((Px 10), (Px 10), 0, 0); $TK.status = $status
$foot.Controls.Add($status)
$root.Controls.Add($foot, 0, 2); $root.SetColumnSpan($foot, 2)

$out.Text = 'Pick a job on the left. Results show here in plain words, and every run is saved in the logs folder.' + "`r`n`r`n" +
  'Usual order on a site:' + "`r`n" + '  1 Find cameras  >  2 Check NVR  >  3 Fix NVR (type YES)  >  6 Save install snapshot' + "`r`n" +
  '  Unknown password?  4 Reset passwords.   Slow or dropping video?  5 Network check.   Fix went wrong?  7 Undo last fix.' + "`r`n`r`n" +
  'Plug this PC into the same switch as the NVR and cameras first. Cable is better than Wi-Fi.' + "`r`n" +
  'Hikvision reply email arrived? Drag its file onto this window.' + "`r`n"
Set-Status ('Ready. ' + $env:COMPUTERNAME)

$form.Add_DragEnter({ if ($_.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) { $_.Effect = 'Copy' } })
$form.Add_DragDrop({ $files = $_.Data.GetData([Windows.Forms.DataFormats]::FileDrop); if ($files) { $p = [string]$files[0]; if ($p -match '(?i)\.json$') { [void][Windows.Forms.MessageBox]::Show($TK.form, 'That looks like a settings/Bitwarden file, not a Hikvision reply. Use "Passwords: from a Bitwarden export file" for that.', 'WireIt Toolkit') } else { Show-ResetWindow $p } } })
$timer = New-Object Windows.Forms.Timer; $timer.Interval = 400
$timer.Add_Tick({ try { Poll-Run; Watch-Export } catch { Set-Status ('(' + $_.Exception.Message + ')') } })
$form.Add_FormClosing({
  if ($TK.run -and $TK.run.Kind -eq 'console') { [void][Windows.Forms.MessageBox]::Show($TK.form, 'A Fix NVR tool window is still open. Finish it there first; its log is saved in C:\WireIt\FixNVR\runs.', 'WireIt Toolkit') }
  if ($TK.bw -and (Test-Path -LiteralPath $TK.bw)) {
    if ([Windows.Forms.MessageBox]::Show($TK.form, ('Delete the Bitwarden export file now? It holds passwords unencrypted:' + "`r`n" + $TK.bw), 'WireIt Toolkit', 'YesNo', 'Warning') -eq 'Yes') { Remove-Item -LiteralPath $TK.bw -Force -ErrorAction SilentlyContinue }
  }
})

if ($Screenshot) {
  New-Item -ItemType Directory -Force -Path $Screenshot | Out-Null
  $form.StartPosition = 'Manual'; $form.Location = New-Object Drawing.Point(-20000, -20000); $form.ShowInTaskbar = $false
  $form.Show(); [Windows.Forms.Application]::DoEvents()
  Add-Out '=== Find cameras - demo ==='; Add-Out 'Hikvision DS-7616NI-Q2/16P  serial F12345678  192.168.1.250  (different IP scheme)'; Add-Out 'In short: 3 device(s) found - 3 Hikvision, 0 Uniview; 3 on a different IP scheme (button 3 Fix NVR moves them).'
  [Windows.Forms.Application]::DoEvents()
  $bmp = New-Object Drawing.Bitmap($form.Width, $form.Height); $form.DrawToBitmap($bmp, (New-Object Drawing.Rectangle(0, 0, $form.Width, $form.Height))); $bmp.Save((Join-Path $Screenshot 'toolkit-main.png'), [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
  $rf = @(Show-ResetWindow)[-1]
  $rf.StartPosition = 'Manual'; $rf.Location = New-Object Drawing.Point(-20000, -20000); $rf.ShowInTaskbar = $false; $rf.Height = Px 1750
  $rf.Show(); [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 300; [Windows.Forms.Application]::DoEvents()
  if ($TK.rs.list.Items.Count) { $TK.rs.list.Items[0].Selected = $true; [Windows.Forms.Application]::DoEvents() }
  $TK.rs.pw = New-TkPassword 14; $TK.rs.pwBox.Text = 'Xy7#demo-only'; $TK.rs.pwBox.Visible = $true; [Windows.Forms.Application]::DoEvents()
  $bmp = New-Object Drawing.Bitmap($rf.Width, $rf.Height); $rf.DrawToBitmap($bmp, (New-Object Drawing.Rectangle(0, 0, $rf.Width, $rf.Height))); $bmp.Save((Join-Path $Screenshot 'toolkit-reset.png'), [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
  $TK.rs.replyLbl.Text = 'Reply file saved for DS-7608NI-K2/8P (serial J12345678), matched by serial. About 41.5 h left to use it.'; $TK.rs.replyLbl.ForeColor = [Drawing.Color]::DarkGreen
  $TK.rs.flow.AutoScrollPosition = New-Object Drawing.Point(0, 5000); [Windows.Forms.Application]::DoEvents()
  $bmp = New-Object Drawing.Bitmap($rf.Width, $rf.Height); $rf.DrawToBitmap($bmp, (New-Object Drawing.Rectangle(0, 0, $rf.Width, $rf.Height))); $bmp.Save((Join-Path $Screenshot 'toolkit-reset-2.png'), [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
  $TK.rs.watch = $false; $rf.Close(); $form.Close()
  Write-Output ('screenshots saved in ' + $Screenshot + '; buttons=' + $TK.buttons.Count + '; resetFields=' + $TK.rs.fieldBtns.Count)
  exit 0
}
$timer.Start()
[void]$form.ShowDialog()
$timer.Stop()
if ($TK.mutex) { try { $TK.mutex.ReleaseMutex() } catch {} }
