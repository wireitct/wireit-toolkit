<#
 FixSiteAsk.ps1 - WireIt Toolkit 2.2.0: the Toolkit window's side of a background "Fix this site" run (see FixSiteIpc.ps1).
 Shows each question of the run as a small window on the tech's own login (Yes/No buttons; a masked box for a password; the site
 password once with Copy), sets/clears the clipboard when the run asks, and opens Hikvision's page (HikPortalStep.ps1) for the
 picture check. Answers go back as a-<n>.json. Nothing here needs admin.
#>
# 2.2.2 (re-review H11 + NEW-3): the site password goes into Bitwarden HERE, on the tech's own login (a run as SYSTEM has no Bitwarden)
. (Join-Path $PSScriptRoot 'FixSiteBw.ps1')
function Get-FsAskBwCfg([string]$ToolkitDir) { try { $c = Get-Content -LiteralPath (Join-Path $ToolkitDir 'config.json') -Raw | ConvertFrom-Json; if ($c -and $c.PSObject.Properties['fixSite']) { return $c.fixSite } } catch {}; return $null }
function New-FsAskForm([string]$Title, [int]$W = 540, [int]$H = 200) {
  $fm = New-Object Windows.Forms.Form; $fm.Text = $Title; $fm.StartPosition = 'CenterScreen'; $fm.TopMost = $true; $fm.FormBorderStyle = 'FixedDialog'; $fm.MaximizeBox = $false; $fm.MinimizeBox = $false
  $fm.AutoScaleMode = 'Dpi'; $fm.ClientSize = New-Object Drawing.Size($W, $H); $fm.Font = New-Object Drawing.Font('Segoe UI', 10); $fm.ControlBox = $false
  return $fm
}
function Show-FsAskChoice($Owner, [string]$Text, [string]$Yes, [string]$No) {
  $fm = New-FsAskForm 'WireIt Toolkit' 520 170
  $l = New-Object Windows.Forms.Label; $l.Text = $Text; $l.SetBounds(16, 14, 488, 90)
  $b1 = New-Object Windows.Forms.Button; $b1.Text = $Yes; $b1.SetBounds(16, 114, 236, 42); $b1.DialogResult = [Windows.Forms.DialogResult]::Yes
  $b2 = New-Object Windows.Forms.Button; $b2.Text = $No; $b2.SetBounds(268, 114, 236, 42); $b2.DialogResult = [Windows.Forms.DialogResult]::No
  $fm.Controls.AddRange(@($l, $b1, $b2)); $fm.AcceptButton = $b1
  $r = $fm.ShowDialog($Owner); $fm.Dispose()
  return $(if ($r -eq [Windows.Forms.DialogResult]::Yes) { 'yes' } else { 'no' })
}
function Show-FsAskText($Owner, [string]$Text, [bool]$Secret) {
  $fm = New-FsAskForm 'WireIt Toolkit' 540 200
  $l = New-Object Windows.Forms.Label; $l.Text = $Text; $l.SetBounds(16, 12, 508, 84)
  $tb = New-Object Windows.Forms.TextBox; $tb.SetBounds(16, 100, 508, 30); $tb.MaxLength = 256; $tb.Font = New-Object Drawing.Font('Segoe UI', 12)
  if ($Secret) { $tb.UseSystemPasswordChar = $true }   # 2.2.0 (review H2): a password or the site-password word is never shown
  $bo = New-Object Windows.Forms.Button; $bo.Text = 'OK'; $bo.SetBounds(284, 146, 116, 38); $bo.DialogResult = [Windows.Forms.DialogResult]::OK
  $bs = New-Object Windows.Forms.Button; $bs.Text = $(if ($Secret) { 'Skip' } else { 'Enter (nothing)' }); $bs.SetBounds(408, 146, 116, 38); $bs.DialogResult = [Windows.Forms.DialogResult]::Cancel
  $fm.Controls.AddRange(@($l, $tb, $bo, $bs)); $fm.AcceptButton = $bo; $fm.CancelButton = $bs
  $fm.Add_Shown({ $tb.Focus() })
  $r = $fm.ShowDialog($Owner); $v = $(if ($r -eq [Windows.Forms.DialogResult]::OK) { $tb.Text } else { '' }); $tb.Text = ''; $fm.Dispose()
  return $v
}
function Show-FsShowSecret($Owner, [string]$Site, [string]$Value, [string]$BwItem) {
  $fm = New-FsAskForm 'WireIt Toolkit - site password' 480 230
  $l1 = New-Object Windows.Forms.Label; $l1.Text = ('Site password for ' + $Site + ' (user admin):'); $l1.SetBounds(16, 12, 448, 24)
  $tb = New-Object Windows.Forms.TextBox; $tb.ReadOnly = $true; $tb.Text = $Value; $tb.Font = New-Object Drawing.Font('Consolas', 20, [Drawing.FontStyle]::Bold); $tb.SetBounds(16, 40, 448, 40); $tb.BackColor = [Drawing.Color]::White
  $l2 = New-Object Windows.Forms.Label; $l2.Text = ('Save this in Bitwarden (item "' + $BwItem + '"). Paste it there, then Close (Close clears the clipboard).'); $l2.SetBounds(16, 92, 448, 70); $l2.ForeColor = [Drawing.Color]::FromArgb(150, 60, 0)
  $bc = New-Object Windows.Forms.Button; $bc.Text = 'Copy'; $bc.SetBounds(16, 176, 120, 36); $bc.Add_Click({ try { [Windows.Forms.Clipboard]::SetText($Value) } catch {}; $bc.Text = 'Copied' })
  $bx = New-Object Windows.Forms.Button; $bx.Text = 'Close'; $bx.SetBounds(344, 176, 120, 36); $bx.DialogResult = [Windows.Forms.DialogResult]::OK
  $fm.Controls.AddRange(@($l1, $tb, $l2, $bc, $bx)); $fm.AcceptButton = $bx
  [void]$fm.ShowDialog($Owner); $tb.Text = ''; $fm.Dispose()
  try { [Windows.Forms.Clipboard]::SetText(' ') } catch {}
}
# one open question of the run -> its answer. $St: the window's state (portal helper process is kept there so it is not started twice).
function Invoke-FsIpcQuestion($Owner, [string]$Session, $Q, [string]$ToolkitDir, $St) {
  $n = [int]$Q.n
  switch ([string]$Q.kind) {
    'choice' { Write-FsIpcAnswer $Session $n (Show-FsAskChoice $Owner ([string]$Q.text) ([string]$Q.yes) ([string]$Q.no)) }
    'text' { Write-FsIpcAnswer $Session $n (Show-FsAskText $Owner ([string]$Q.text) $false) }
    'secret' { Write-FsIpcAnswer $Session $n (Show-FsAskText $Owner ([string]$Q.text) $true) }
    'show' { Remove-Item -LiteralPath (Join-Path $Session ('q-{0:D4}.json' -f $n)) -Force -ErrorAction SilentlyContinue; Show-FsShowSecret $Owner ([string]$Q.site) ([string]$Q.value) ([string]$Q.bwItem); Write-FsIpcAnswer $Session $n 'shown' }
    'bitwarden' {
      # the question file holds the password: it goes at once; the answer holds only the result
      Remove-Item -LiteralPath (Join-Path $Session ('q-{0:D4}.json' -f $n)) -Force -ErrorAction SilentlyContinue
      $ans = 'failed;;window'; try { $ans = Invoke-FsBwForRun $Q (Get-FsAskBwCfg $ToolkitDir) { param($t) Show-FsAskText $Owner $t $true } } catch {}
      Write-FsIpcAnswer $Session $n $ans
    }
    'clip' { try { [Windows.Forms.Clipboard]::SetText([string]$Q.value) } catch {}; Write-FsIpcAnswer $Session $n 'ok' }
    'clipclear' { try { [Windows.Forms.Clipboard]::SetText(' ') } catch {}; Write-FsIpcAnswer $Session $n 'ok' }
    'portal' {
      if ($St.portal -and $St.portal.n -eq $n) { return }   # already open
      $helper = Join-Path $ToolkitDir 'HikPortalStep.ps1'
      $psexe = Join-Path $PSHOME 'powershell.exe'
      $qf = Join-Path $Session ('q-{0:D4}.json' -f $n)
      try { $p = Start-Process -FilePath $psexe -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "' + $helper + '" -Question "' + $qf + '"') -PassThru -WindowStyle Hidden; $St.portal = @{ n = $n; proc = $p } }
      catch { Write-FsIpcAnswer $Session $n 'no-browser' }
    }
    default { Write-FsIpcAnswer $Session $n '' }
  }
}
