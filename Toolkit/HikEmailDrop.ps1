<#
 HikEmailDrop.ps1 - WireIt Toolkit 2.2.0: the "I got Hik's email" button (backup for the reply relay), in Fix this site and in Reset passwords.
 The tech drags Hikvision's attachment in (or picks it) or pastes the code from the email, picks the device if more than one is waiting,
 and it is saved in inbox\hik\ as drop-<serial>-<time>.<ext>. A running Fix this site picks it up within seconds and carries on by itself
 (import + login check); with no run going, the next Fix this site uses it. Only a file (2 MB at most) or a code of letters/digits is taken.
#>
function Get-HikInboxDir([string]$ToolkitDir) { return (Join-Path $ToolkitDir 'inbox\hik') }
# the devices waiting for Hikvision's reply: inbox\hik\waiting.json from the last run (2.2.3: -SessionDir is only an optional extra list; nothing writes ipc\ any more)
function Get-HikWaitingDevices([string]$ToolkitDir, [string]$SessionDir = '') {
  $list = @()
  if ($SessionDir) { $f = Join-Path $SessionDir 'hik.json'; if (Test-Path -LiteralPath $f) { try { $j = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json; $list = @($j.waiting | Where-Object { $_ }) } catch {} } }
  if (-not $list.Count) { $f = Join-Path (Get-HikInboxDir $ToolkitDir) 'waiting.json'; if (Test-Path -LiteralPath $f) { try { $j = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json; $list = @($j.devices | Where-Object { $_ }) } catch {} } }
  return @($list | Where-Object { [string]$_.serial -match '^[A-Za-z0-9][A-Za-z0-9/._-]{5,127}$' })
}
function ConvertTo-HikCode([string]$Text) {
  $t = ([string]$Text).Trim() -replace '[\s\-]', ''
  if ($t -match '^[A-Za-z0-9]{4,64}$') { return $t }
  return ''
}
# returns { ok; why; path }
function Save-HikEmailDrop([string]$InboxDir, [string]$Serial, [string]$File = '', [string]$Code = '') {
  $no = { param($w) return [pscustomobject]@{ ok = $false; why = $w; path = '' } }
  if ([string]$Serial -notmatch '^[A-Za-z0-9][A-Za-z0-9/._-]{5,127}$') { return (& $no 'pick the device first') }
  # Keep the complete serial for matching; only its filename representation is escaped (a slash is common in NVR models).
  $fileSerial = [uri]::EscapeDataString($Serial)
  New-Item -ItemType Directory -Force -Path $InboxDir | Out-Null
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  if ($File) {
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { return (& $no 'that file is not there any more') }
    $fi = Get-Item -LiteralPath $File
    if ($fi.Length -eq 0) { return (& $no 'that file is empty') }
    if ($fi.Length -gt 2MB) { return (& $no 'that file is too big to be Hikvision''s reply (more than 2 MB)') }
    if ($fi.Extension -match '(?i)^\.(json|exe|bat|cmd|ps1|lnk|dll|vbs|js)$') { return (& $no 'that is not Hikvision''s reply file') }
    $ext = $(if ($fi.Extension -match '^\.[A-Za-z0-9]{1,5}$') { $fi.Extension.ToLower() } else { '.xml' })
    $dst = Join-Path $InboxDir ('drop-' + $fileSerial + '-' + $stamp + $ext)
    [IO.File]::WriteAllBytes($dst + '.tmp', [IO.File]::ReadAllBytes($fi.FullName)); Move-Item -LiteralPath ($dst + '.tmp') -Destination $dst -Force
    return [pscustomobject]@{ ok = $true; why = ''; path = $dst }
  }
  $c = ConvertTo-HikCode $Code
  if (-not $c) { return (& $no 'paste the code from Hikvision''s email (letters and digits only)') }
  $dst = Join-Path $InboxDir ('drop-' + $fileSerial + '-' + $stamp + '-code.txt')
  [IO.File]::WriteAllText($dst + '.tmp', $c); Move-Item -LiteralPath ($dst + '.tmp') -Destination $dst -Force
  return [pscustomobject]@{ ok = $true; why = ''; path = $dst }
}
# the dialog. $Devices: objects with serial, shortSerial, model, ip. $OnSave: { param($serial, $file, $code) -> { ok; why; message } }.
function Show-HikEmailDialog($Owner, $Devices, [scriptblock]$OnSave, [string]$Intro = '') {
  Add-Type -AssemblyName System.Windows.Forms, System.Drawing
  $fm = New-Object Windows.Forms.Form; $fm.Text = 'I got Hik''s email'; $fm.StartPosition = 'CenterParent'; $fm.FormBorderStyle = 'FixedDialog'; $fm.MaximizeBox = $false; $fm.MinimizeBox = $false
  $fm.AutoScaleMode = 'Dpi'; $fm.ClientSize = New-Object Drawing.Size(560, 420); $fm.Font = New-Object Drawing.Font('Segoe UI', 10); $fm.TopMost = $true; $fm.AllowDrop = $true
  $l0 = New-Object Windows.Forms.Label; $l0.SetBounds(16, 10, 528, 44); $l0.Text = $(if ($Intro) { $Intro } else { 'Hikvision''s reply came to your email? Drag its attachment onto this window (save it first), or paste the code from the email. Then press Use it.' })
  $l1 = New-Object Windows.Forms.Label; $l1.SetBounds(16, 60, 528, 20); $l1.Text = 'Which device is it for?'
  $cb = New-Object Windows.Forms.ComboBox; $cb.DropDownStyle = 'DropDownList'; $cb.SetBounds(16, 82, 528, 28)
  foreach ($d in @($Devices)) { [void]$cb.Items.Add(([string]$d.model + '  ' + [string]$d.ip + '  serial ' + $(if ($d.shortSerial) { [string]$d.shortSerial } else { [string]$d.serial }))) }
  if ($cb.Items.Count) { $cb.SelectedIndex = 0 }
  $dz = New-Object Windows.Forms.Label; $dz.SetBounds(16, 120, 528, 96); $dz.BorderStyle = 'FixedSingle'; $dz.TextAlign = 'MiddleCenter'; $dz.AllowDrop = $true; $dz.BackColor = [Drawing.Color]::FromArgb(241, 245, 249)
  $dz.Text = 'Drag the attachment from Hikvision''s email here'
  $bp = New-Object Windows.Forms.Button; $bp.Text = 'Pick the file...'; $bp.SetBounds(16, 222, 150, 32)
  $l2 = New-Object Windows.Forms.Label; $l2.SetBounds(16, 266, 528, 20); $l2.Text = 'Or paste the code from the email:'
  $tb = New-Object Windows.Forms.TextBox; $tb.SetBounds(16, 288, 528, 30); $tb.Font = New-Object Drawing.Font('Consolas', 13); $tb.MaxLength = 80
  $msg = New-Object Windows.Forms.Label; $msg.SetBounds(16, 324, 528, 40); $msg.ForeColor = [Drawing.Color]::FromArgb(185, 28, 28)
  $bu = New-Object Windows.Forms.Button; $bu.Text = 'Use it'; $bu.SetBounds(300, 370, 120, 36)
  $bx = New-Object Windows.Forms.Button; $bx.Text = 'Close'; $bx.SetBounds(424, 370, 120, 36); $bx.DialogResult = [Windows.Forms.DialogResult]::Cancel
  $st = @{ file = ''; result = $null }
  $setFile = { param($p) $st.file = $p; $dz.Text = ('File: ' + (Split-Path -Leaf $p)); $tb.Text = '' }
  $de = { if ($_.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) { $_.Effect = 'Copy' } }
  $dd = { $fl = $_.Data.GetData([Windows.Forms.DataFormats]::FileDrop); if ($fl) { & $setFile ([string]$fl[0]) } }
  $dz.Add_DragEnter($de); $dz.Add_DragDrop($dd); $fm.Add_DragEnter($de); $fm.Add_DragDrop($dd)
  $bp.Add_Click({ $o = New-Object Windows.Forms.OpenFileDialog; $o.Filter = 'Hikvision reply (*.xml;*.zip;*.txt;*.eml;*.dat)|*.xml;*.zip;*.txt;*.eml;*.dat|All files|*.*'; if ($o.ShowDialog($fm) -eq 'OK') { & $setFile $o.FileName } })
  $bu.Add_Click({
    if (-not $cb.Items.Count -or $cb.SelectedIndex -lt 0) { $msg.Text = 'No device is waiting for Hikvision''s reply on this PC.'; return }
    $dev = @($Devices)[$cb.SelectedIndex]
    if (-not $st.file -and -not $tb.Text.Trim()) { $msg.Text = 'Drag the attachment in, or paste the code.'; return }
    $r = & $OnSave ([string]$dev.serial) ([string]$st.file) ([string]$tb.Text)
    if ($r -and $r.ok) { $st.result = $r; $fm.Close() } else { $msg.Text = $(if ($r) { [string]$r.why } else { 'That did not work.' }) }
  })
  $fm.Controls.AddRange(@($l0, $l1, $cb, $dz, $bp, $l2, $tb, $msg, $bu, $bx)); $fm.CancelButton = $bx
  if ($Owner) { [void]$fm.ShowDialog($Owner) } else { [void]$fm.ShowDialog() }
  $fm.Dispose()
  return $st.result
}
