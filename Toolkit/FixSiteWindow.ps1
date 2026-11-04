<#
 FixSiteWindow.ps1 - WireIt Toolkit 2.0: the ONE screen. A site box, camera-setting drop-downs, one big "Fix this site" button.
 Returns 'classic' when the user asks for the old numbered buttons ("More tools"); anything else = done.
 The work itself runs in FixSite.ps1 (a blue window asks Windows for permission, takes the YES, and does the fixing);
 this window shows the same checklist live and says when it is waiting for you. Passwords are only ever typed in that blue window.
#>
param([string]$ToolkitDir = '', [string]$Version = '', [string]$Note = '', [string]$Screenshot = '')   # -Screenshot <file.png>: tests, draw the window to a PNG, no screen
$ErrorActionPreference = 'Continue'
if (-not $ToolkitDir) { $ToolkitDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $ToolkitDir 'FixSiteCore.ps1')
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$psexe = Join-Path $PSHOME 'powershell.exe'
$runsDir = Join-Path $ToolkitDir 'runs'; $stateDir = Join-Path $ToolkitDir 'state'; New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
$lastSiteFile = Join-Path $stateDir 'last-site.txt'
$g = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $sc = [math]::Max(1.0, $g.DpiX / 96.0); $g.Dispose()
function Px([double]$n) { return [int]($n * $sc) }
function Fnt([double]$pt, [string]$style = 'Regular') { try { return New-Object Drawing.Font('Segoe UI', $pt, [Drawing.FontStyle]$style) } catch { return [Drawing.SystemFonts]::DefaultFont } }
$cGreen = [Drawing.Color]::FromArgb(22, 140, 80); $cInk = [Drawing.Color]::FromArgb(30, 41, 59); $cMuted = [Drawing.Color]::FromArgb(100, 116, 139); $cBg = [Drawing.Color]::FromArgb(246, 248, 250)

$st = @{ proc = $null; since = $null; runDir = ''; offset = 0; mode = '' }
$f = New-Object Windows.Forms.Form
$f.Text = 'WireIt Toolkit  v' + $Version; $f.StartPosition = 'CenterScreen'; $f.BackColor = $cBg; $f.Font = Fnt 10
$f.ClientSize = New-Object Drawing.Size((Px 820), (Px 640)); $f.MinimumSize = New-Object Drawing.Size((Px 700), (Px 560))
$ico = Join-Path $ToolkitDir 'wireit.ico'; if (Test-Path $ico) { try { $f.Icon = New-Object Drawing.Icon($ico) } catch {} }
$t = New-Object Windows.Forms.TableLayoutPanel; $t.Dock = 'Fill'; $t.ColumnCount = 1; $t.RowCount = 7; $t.Padding = New-Object Windows.Forms.Padding((Px 22), (Px 14), (Px 22), (Px 12))
foreach ($rs in @('AutoSize', 'AutoSize', 'AutoSize', 'AutoSize', 'AutoSize', 'Percent', 'AutoSize')) { if ($rs -eq 'Percent') { [void]$t.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100))) } else { [void]$t.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize'))) } }
$f.Controls.Add($t)
function New-Label([string]$text, $font, $color, [int]$top = 0) { $l = New-Object Windows.Forms.Label; $l.Text = $text; $l.Font = $font; $l.ForeColor = $color; $l.AutoSize = $true; $l.MaximumSize = New-Object Drawing.Size((Px 760), 0); $l.Margin = New-Object Windows.Forms.Padding(0, (Px $top), 0, 0); return $l }
$t.Controls.Add((New-Label 'WireIt Toolkit' (Fnt 20 'Bold') $cInk), 0, 0)
$t.Controls.Add((New-Label ('Which site are you at? Type the Site ID from the QR sticker (like WI-061) or the address.' + $(if ($Note) { '     ' + $Note } else { '' })) (Fnt 10) $cMuted 2), 0, 1)
$site = New-Object Windows.Forms.ComboBox; $site.DropDownStyle = 'DropDown'; $site.Font = Fnt 13; $site.Dock = 'Top'; $site.Margin = New-Object Windows.Forms.Padding(0, (Px 6), 0, (Px 8))
$roots = @('G:\My Drive\WireIt Sites', '%USERPROFILE%\My Drive\WireIt Sites', 'C:\Users\admin\My Drive\WireIt Sites')
foreach ($r in $roots) { $rr = [Environment]::ExpandEnvironmentVariables($r); if (Test-Path -LiteralPath $rr) { foreach ($d in @(Get-ChildItem -LiteralPath $rr -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '_*' } | Sort-Object Name)) { [void]$site.Items.Add($d.Name) }; break } }
if (Test-Path $lastSiteFile) { $site.Text = (Get-Content $lastSiteFile -Raw).Trim() }
$t.Controls.Add($site, 0, 2)
# camera settings: drop-downs, no presets (Moshe Nov 3 2:14 PM). Left alone = the camera keeps what it has.
$gb = New-Object Windows.Forms.GroupBox; $gb.Text = 'Camera settings (optional - they go ONLY on the cameras with a problem; working cameras are not touched)'; $gb.Dock = 'Top'; $gb.Height = Px 108; $gb.Font = Fnt 9
$row = New-Object Windows.Forms.TableLayoutPanel; $row.Dock = 'Fill'; $row.ColumnCount = 4; $row.RowCount = 2
foreach ($i in 1..4) { [void]$row.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 25))) }
function New-Pick($items) { $c = New-Object Windows.Forms.ComboBox; $c.DropDownStyle = 'DropDownList'; $c.Dock = 'Fill'; $c.Font = Fnt 9.5; foreach ($i in $items) { [void]$c.Items.Add($i) }; $c.SelectedIndex = 0; return $c }
$pCodec = New-Pick @('Automatic (H.264 only for old/problem cameras)', 'Keep as is', 'H.264', 'H.265')
$pFps = New-Pick @('Frame rate: keep as is', '10', '12', '15', '20', '25', '30')
$pRes = New-Pick @('Resolution: keep as is', 'Highest the camera has', '1920x1080', '2560x1440', '2688x1520', '3840x2160')
$pBit = New-Pick @('Bitrate: keep as is', '1024', '2048', '3072', '4096', '6144', '8192')
$row.Controls.Add($pCodec, 0, 0); $row.Controls.Add($pFps, 1, 0); $row.Controls.Add($pRes, 2, 0); $row.Controls.Add($pBit, 3, 0)
# 2.0.1 (Moshe, Nov 3 10:06 PM): working cameras are never changed unless one of these is ticked. Both start unticked and untick again after every run.
function New-Tick([string]$text) { $k = New-Object Windows.Forms.CheckBox; $k.Text = $text; $k.AutoSize = $true; $k.Font = Fnt 9.5; $k.Checked = $false; $k.Margin = New-Object Windows.Forms.Padding(0, (Px 6), 0, 0); return $k }
$kAll = New-Tick 'Apply settings to ALL cameras'; $kPw = New-Tick 'Set the site password on all cameras'
$row.Controls.Add($kAll, 0, 1); $row.SetColumnSpan($kAll, 2); $row.Controls.Add($kPw, 2, 1); $row.SetColumnSpan($kPw, 2)
$gb.Controls.Add($row); $t.Controls.Add($gb, 0, 3)
$big = New-Object Windows.Forms.Button; $big.Text = 'Fix this site'; $big.Font = Fnt 26 'Bold'; $big.BackColor = $cGreen; $big.ForeColor = [Drawing.Color]::White; $big.FlatStyle = 'Flat'; $big.FlatAppearance.BorderSize = 0
$big.Dock = 'Top'; $big.Height = Px 110; $big.Margin = New-Object Windows.Forms.Padding(0, (Px 10), 0, (Px 6)); $big.Cursor = 'Hand'
$t.Controls.Add($big, 0, 4)
$status = New-Label 'It finds what is wrong, shows you the list, you type YES once, and it fixes only those cameras. Working cameras are not touched. Safe to run again.' (Fnt 10) $cMuted 0
$out = New-Object Windows.Forms.TextBox; $out.Multiline = $true; $out.ReadOnly = $true; $out.ScrollBars = 'Vertical'; $out.Dock = 'Fill'; $out.Font = New-Object Drawing.Font('Consolas', 10); $out.BackColor = [Drawing.Color]::White; $out.Margin = New-Object Windows.Forms.Padding(0, (Px 4), 0, (Px 6))
$pnl = New-Object Windows.Forms.TableLayoutPanel; $pnl.Dock = 'Fill'; $pnl.ColumnCount = 1; $pnl.RowCount = 2; [void]$pnl.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize'))); [void]$pnl.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100)))
$pnl.Controls.Add($status, 0, 0); $pnl.Controls.Add($out, 0, 1); $t.Controls.Add($pnl, 0, 5)
$bar = New-Object Windows.Forms.FlowLayoutPanel; $bar.Dock = 'Fill'; $bar.AutoSize = $true; $bar.FlowDirection = 'LeftToRight'
function New-Small([string]$text) { $b = New-Object Windows.Forms.Button; $b.Text = $text; $b.AutoSize = $true; $b.Font = Fnt 9.5; $b.Padding = New-Object Windows.Forms.Padding((Px 6), (Px 2), (Px 6), (Px 2)); return $b }
$bLook = New-Small 'Just look (change nothing)'; $bUndo = New-Small 'Undo the last fix'; $bUsual = New-Small 'Usual passwords...'; $bMore = New-Small 'More tools (old buttons)'
foreach ($b in @($bLook, $bUndo, $bUsual, $bMore)) { $bar.Controls.Add($b) }
$t.Controls.Add($bar, 0, 6)
$tips = New-Object Windows.Forms.ToolTip
$tips.SetToolTip($big, 'Finds the cameras with a real problem (offline, no video, hung, wrong IP scheme, not on the NVR, password unknown) and fixes ONLY those: site password, the settings above, right address, back on the NVR, video checked. Working cameras are not touched.')
$tips.SetToolTip($kAll, 'Off (normal): the drop-downs go only on the cameras being fixed. On: they go on every camera, working ones too. Unticks itself after each run.')
$tips.SetToolTip($kPw, 'Off (normal): only the cameras being fixed get the site password. On: every camera gets it (and its NVR channel). Unticks itself after each run.')
$tips.SetToolTip($bLook, 'Shows what is wrong and what Fix would do. Changes nothing, asks for no YES.')
$tips.SetToolTip($bUndo, 'Puts the cameras and NVR back the way the last Fix found them.')
$tips.SetToolTip($bUsual, 'WireIt''s usual camera passwords, tried first on every site (kept encrypted on this PC).')
$result = 'done'

function Set-Busy([bool]$busy) { foreach ($b in @($big, $bLook, $bUndo, $bUsual, $bMore, $site, $pCodec, $pFps, $pRes, $pBit, $kAll, $kPw)) { $b.Enabled = -not $busy } }
function Start-Run([string]$mode, [string[]]$extra, [bool]$needSite) {
  $s = $site.Text.Trim()
  if ($needSite -and -not $s) { [void][Windows.Forms.MessageBox]::Show($f, 'Type the site first (the Site ID on the QR sticker, like WI-061, or the address).', 'WireIt Toolkit'); return }
  if ($s) { try { Set-Content -LiteralPath $lastSiteFile -Value $s -Encoding UTF8 } catch {} }
  $file = Join-Path $ToolkitDir 'FixSite.ps1'
  if (-not (Test-Path $file)) { $status.Text = 'FixSite.ps1 is missing from the Toolkit folder. Run the Toolkit installer again.'; return }
  $a = '-NoProfile -ExecutionPolicy Bypass -File "' + $file + '" -Mode ' + $mode
  if ($s) { $a += ' -Site "' + ($s -replace '"', '') + '"' }
  foreach ($e in $extra) { if ($e) { $a += ' ' + $e } }
  $out.Clear(); $st.since = Get-Date; $st.runDir = ''; $st.offset = 0; $st.mode = $mode
  $status.Text = 'A blue window opens (Windows asks permission first: click Yes). Everything you have to answer is asked there.'
  try { $st.proc = Start-Process -FilePath $psexe -ArgumentList $a -Verb RunAs -PassThru -WorkingDirectory $ToolkitDir -ErrorAction Stop }
  catch { $status.Text = 'Windows asked for permission and it was not given, so nothing ran.'; $st.proc = $null; return }
  Set-Busy $true
}
function Get-Settings {
  $e = @()
  $c = [string]$pCodec.SelectedItem; if ($c -like 'Keep*') { $e += '-Codec keep' } elseif ($c -like 'H.*') { $e += ('-Codec ' + $c) }
  $x = [string]$pFps.SelectedItem; if ($x -match '^\d+$') { $e += ('-Fps ' + $x) }
  $r = [string]$pRes.SelectedItem; if ($r -like 'Highest*') { $e += '-Resolution max' } elseif ($r -match '^\d+x\d+$') { $e += ('-Resolution ' + $r) }
  $b = [string]$pBit.SelectedItem; if ($b -match '^\d+$') { $e += ('-Bitrate ' + $b) }
  if ($kAll.Checked) { $e += '-AllCameras' }
  if ($kPw.Checked) { $e += '-PasswordAll' }
  return $e
}
$big.Add_Click({ Start-Run 'Fix' (Get-Settings) $true })
$bLook.Add_Click({ Start-Run 'Plan' (Get-Settings) $true })
$bUsual.Add_Click({ Start-Run 'SetUsual' @() $false })
$bUndo.Add_Click({
  $d = Get-FsLastRun $runsDir -Undoable
  if (-not $d) { [void][Windows.Forms.MessageBox]::Show($f, 'There is no fix to undo (no un-undone Fix this site run on this PC).', 'WireIt Toolkit'); return }
  Start-Run 'Rollback' @('-RollbackDir "' + $d.FullName + '"') $false
})
$bMore.Add_Click({ $script:result = 'classic'; $f.Close() })
$timer = New-Object Windows.Forms.Timer; $timer.Interval = 1000
$timer.Add_Tick({
  if (-not $st.proc) { return }
  $exited = $false; try { $exited = $st.proc.HasExited } catch { $exited = $true }
  if (-not $st.runDir) { $d = Get-FsLastRun $runsDir; if ($d -and $d.CreationTime -ge $st.since.AddSeconds(-3)) { $st.runDir = $d.FullName } }
  if ($st.runDir) {
    try {
      $fs = [IO.File]::Open((Join-Path $st.runDir 'log.txt'), 'Open', 'Read', 'ReadWrite'); $all = (New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)).ReadToEnd(); $fs.Close()
      $v = ConvertFrom-FsLog ($all -split "`r?`n")
      $txt = (($v.lines | ForEach-Object { $_ }) -join "`r`n")
      if ($txt.Length -ne $out.TextLength) { $out.Text = $txt; $out.SelectionStart = $out.TextLength; $out.ScrollToCaret() }
      if (-not $exited) { $status.Text = $(if ($v.waiting) { 'Waiting for you in the blue window: ' + $v.waiting } else { 'Working... (one camera at a time, you do not have to do anything).' }) }
    } catch {}
  }
  if ($exited) {
    $code = -1; try { $code = $st.proc.ExitCode } catch {}
    $st.proc = $null; Set-Busy $false; $status.Text = Get-FsExitWords $code
    $kAll.Checked = $false; $kPw.Checked = $false   # tick again each run (2.0.1)
    try { [Windows.Forms.SystemSounds]::Asterisk.Play() } catch {}
  }
})
if ($Screenshot) {
  $out.Text = "Front Door: password set " + [char]0x2705 + ", I-frame 15 " + [char]0x2705 + ", back on NVR ch 1 " + [char]0x2705 + ", video back " + [char]0x2705; $status.Text = 'Waiting for you in the blue window: Type YES to fix all of this'
  $f.CreateControl(); $f.PerformLayout(); $bmp = New-Object Drawing.Bitmap($f.Width, $f.Height); $f.DrawToBitmap($bmp, (New-Object Drawing.Rectangle(0, 0, $f.Width, $f.Height))); $bmp.Save($Screenshot, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose(); $f.Dispose(); return 'shot'
}
$timer.Start()
$f.Add_FormClosing({ if ($st.proc) { $r = [Windows.Forms.MessageBox]::Show($f, 'A fix is still running in the blue window. Close this window anyway? (The fix keeps going.)', 'WireIt Toolkit', 'YesNo'); if ($r -ne 'Yes') { $_.Cancel = $true } } })
[void]$f.ShowDialog()
$timer.Stop()
return $result
