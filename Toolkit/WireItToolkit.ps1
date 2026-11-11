<#
 WireItToolkit.ps1 - the "WireIt Toolkit" window (Windows PowerShell 5.1 + Windows Forms, nothing to install).
 One window, big buttons, plain results. It runs the existing WireIt tools; it does not change how they work:
   C:\WireIt\CamReset (Find Cameras, Make-Request), C:\WireIt\FixNVR (Check / Fix / Snapshot / Rollback), C:\WireIt\NetCheck.
 Every run is logged to C:\WireIt\Toolkit\logs. Passwords are only typed into hidden prompts and are never saved or logged.
 Start: double-click "WireIt Toolkit" on the desktop (or "WireIt Toolkit.cmd").
 Switches: -NoUpdate (skip the update check)   -Screenshot <folder> (tests: draw the windows to PNG, no screen)   -SimScale 1.5 (with -Screenshot: draw as a 150% screen)
#>
param([string]$Screenshot = '', [switch]$NoUpdate, [switch]$Classic, [string]$DemoCamReset = '', [string]$UpdatedFrom = '', [double]$SimScale = 0, [string]$SimScreen = '')
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'ToolkitRecover.ps1')
$script:TkRepairMsg = ''
if (-not $Screenshot) {
  try { $script:TkRepairMsg = [string](Invoke-TkStartupRecovery $here) }
  catch { Write-Error $_ -ErrorAction Continue; exit 1 }
}
. (Join-Path $here 'ToolkitCore.ps1')
foreach ($lib in @('HikMail.ps1', 'HikEmailDrop.ps1')) { if (Test-Path (Join-Path $here $lib)) { . (Join-Path $here $lib) } }   # 2.2.0: Hik's reply - relay + the "I got Hik's email" button
# 2.2.3: Crew is a local admin - an update (or Go back) runs right here; there is no background task to hand it to
function Test-TkCanWrite([string]$dir) { $p = Join-Path $dir ('.w' + [guid]::NewGuid().ToString('N').Substring(0, 6)); try { [IO.File]::WriteAllText($p, 'x'); Remove-Item -LiteralPath $p -Force; return $true } catch { return $false } }
$script:TkNoWriteMsg = 'This login cannot write the Toolkit folder. Open the Toolkit with "Run as administrator" and try again.'
$script:WireItUiCode = @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace WireItUi {
  public static class Gfx {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    public static float S = 1f;
    public static Color Line = Color.FromArgb(222, 227, 233);
    // 1.6.1 (YKW Elm, 1024x768): shrink a caption's font (down to 70 %) until it fits, instead of cutting it with "..."
    public static Font Fit(Graphics g, string text, Font f, int w, out bool clipped) {
      clipped = false; if (f == null || String.IsNullOrEmpty(text) || w <= 0) return f;
      TextFormatFlags fl = TextFormatFlags.NoPadding | TextFormatFlags.SingleLine;
      if (TextRenderer.MeasureText(g, text, f, new Size(9999, 9999), fl).Width <= w) return f;
      float min = f.Size * 0.70f;
      for (float sz = f.Size - 0.5f; sz >= min; sz -= 0.5f) {
        Font t = new Font(f.FontFamily, sz, f.Style, f.Unit);
        if (TextRenderer.MeasureText(g, text, t, new Size(9999, 9999), fl).Width <= w) return t;
        t.Dispose();
      }
      clipped = true; return new Font(f.FontFamily, min, f.Style, f.Unit);
    }
    public static GraphicsPath Round(RectangleF r, float rad) {
      GraphicsPath p = new GraphicsPath(); float d = Math.Min(rad * 2, Math.Min(r.Width, r.Height));
      if (d <= 1) { p.AddRectangle(r); return p; }
      p.AddArc(r.X, r.Y, d, d, 180, 90); p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
      p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90); p.AddArc(r.X, r.Bottom - d, d, d, 90, 90); p.CloseFigure(); return p;
    }
    public static Color Mix(Color a, Color b, float t) {
      return Color.FromArgb((int)(a.R + (b.R - a.R) * t), (int)(a.G + (b.G - a.G) * t), (int)(a.B + (b.B - a.B) * t));
    }
    public static void Smooth(Graphics g) {
      g.SmoothingMode = SmoothingMode.AntiAlias; g.PixelOffsetMode = PixelOffsetMode.HighQuality;
      g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit; g.InterpolationMode = InterpolationMode.HighQualityBicubic;
    }
    public static void Glyph(Graphics g, string glyph, Font f, Color c, RectangleF r) {
      if (f == null || String.IsNullOrEmpty(glyph)) return;
      using (StringFormat sf = new StringFormat()) using (SolidBrush b = new SolidBrush(c)) {
        sf.Alignment = StringAlignment.Center; sf.LineAlignment = StringAlignment.Center;
        g.DrawString(glyph, f, b, r, sf);
      }
    }
    public static Color ParentBack(Control c) {
      Control p = c.Parent;
      while (p != null && p.BackColor.A < 255) p = p.Parent;
      return p != null ? p.BackColor : SystemColors.Control;
    }
    public static void Card(Graphics g, Control c, Color fill, Color border, float radius, bool shadow) {
      Smooth(g); g.Clear(ParentBack(c)); float s = S;
      float sh = shadow ? 2 * s : 0;
      RectangleF r = new RectangleF(0.5f, 0.5f, c.Width - 1.5f, c.Height - 1.5f - sh);
      if (shadow) {
        using (GraphicsPath p = Round(new RectangleF(r.X, r.Y + sh, r.Width, r.Height), radius * s))
        using (SolidBrush b = new SolidBrush(Color.FromArgb(16, 20, 30, 45))) g.FillPath(b, p);
      }
      using (GraphicsPath p = Round(r, radius * s)) {
        using (SolidBrush b = new SolidBrush(fill)) g.FillPath(b, p);
        using (Pen pen = new Pen(border, 1f)) g.DrawPath(pen, p);
      }
    }
    // a RichTextBox draws blank in DrawToBitmap; this prints it into the picture (screenshots only)
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] struct CHARRANGE { public int Min, Max; }
    [StructLayout(LayoutKind.Sequential)] struct FORMATRANGE { public IntPtr hdc, hdcTarget; public RECT rc, rcPage; public CHARRANGE chrg; }
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, int m, IntPtr w, ref FORMATRANGE l);
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, int m, IntPtr w, IntPtr l);
    public static void PrintRtb(RichTextBox rtb, Bitmap bmp, Rectangle r) {
      using (Graphics g = Graphics.FromImage(bmp)) {
        using (SolidBrush b = new SolidBrush(rtb.BackColor)) g.FillRectangle(b, r);
        float tw = 1440f / g.DpiX;
        IntPtr hdc = g.GetHdc();
        try {
          FORMATRANGE fr = new FORMATRANGE(); fr.hdc = hdc; fr.hdcTarget = hdc;
          fr.rc.L = (int)(r.Left * tw); fr.rc.T = (int)(r.Top * tw); fr.rc.R = (int)(r.Right * tw); fr.rc.B = (int)(r.Bottom * tw);
          fr.rcPage = fr.rc; fr.chrg.Min = 0; fr.chrg.Max = -1;
          SendMessage(rtb.Handle, 0x439, (IntPtr)1, ref fr);
          SendMessage(rtb.Handle, 0x439, IntPtr.Zero, IntPtr.Zero);
        } finally { g.ReleaseHdc(hdc); }
      }
    }
  }

  // dark top bar: logo chip, title, subtitle, version
  public class Header : Control {
    public Image Logo; public string Title = "", Sub = "", Badge = "", Note = "";
    public Font TitleFont, SubFont, BadgeFont;
    public Color Back = Color.FromArgb(31, 36, 43), Strip = Color.FromArgb(200, 16, 46);
    public Header() { SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true); }
    protected override void OnPaint(PaintEventArgs e) {
      Graphics g = e.Graphics; Gfx.Smooth(g); float s = Gfx.S;
      int strip = Math.Max(3, (int)(4 * s)); int h = Height - strip;
      using (LinearGradientBrush br = new LinearGradientBrush(new Rectangle(0, 0, Math.Max(1, Width), h + 1), Gfx.Mix(Back, Color.White, 0.06f), Gfx.Mix(Back, Color.Black, 0.30f), LinearGradientMode.Horizontal)) g.FillRectangle(br, 0, 0, Width, h);
      using (SolidBrush br = new SolidBrush(Strip)) g.FillRectangle(br, 0, h, Width, strip);
      float x = 16 * s;
      if (Logo != null) {
        float ch = h - 18 * s; float lh = ch - 10 * s; float lw = lh * Logo.Width / Logo.Height;
        RectangleF chip = new RectangleF(x, (h - ch) / 2f, lw + 20 * s, ch);
        using (GraphicsPath p = Gfx.Round(chip, 8 * s)) g.FillPath(Brushes.White, p);
        g.DrawImage(Logo, new RectangleF(chip.X + 10 * s, chip.Y + 5 * s, lw, lh));
        x = chip.Right + 18 * s;
      }
      Size ts = TextRenderer.MeasureText(g, Title, TitleFont, new Size(9999, 9999), TextFormatFlags.NoPadding);
      Size ss = String.IsNullOrEmpty(Sub) ? Size.Empty : TextRenderer.MeasureText(g, Sub, SubFont, new Size(9999, 9999), TextFormatFlags.NoPadding);
      float gap = ss.Height > 0 ? 3 * s : 0; float y = (h - ts.Height - gap - ss.Height) / 2f;
      TextRenderer.DrawText(g, Title, TitleFont, new Point((int)x, (int)y), Color.White, TextFormatFlags.NoPadding);
      if (ss.Height > 0) TextRenderer.DrawText(g, Sub, SubFont, new Point((int)x + (int)(1 * s), (int)(y + ts.Height + gap)), Color.FromArgb(170, 180, 192), TextFormatFlags.NoPadding);
      float rx = Width - 16 * s;
      if (!String.IsNullOrEmpty(Badge)) {
        Size bs = TextRenderer.MeasureText(g, Badge, BadgeFont, new Size(9999, 9999), TextFormatFlags.NoPadding);
        RectangleF pill = new RectangleF(rx - bs.Width - 20 * s, (h - bs.Height - 10 * s) / 2f, bs.Width + 20 * s, bs.Height + 10 * s);
        using (GraphicsPath p = Gfx.Round(pill, pill.Height / 2f)) {
          using (SolidBrush b = new SolidBrush(Color.FromArgb(40, 255, 255, 255))) g.FillPath(b, p);
          using (Pen pen = new Pen(Color.FromArgb(70, 255, 255, 255))) g.DrawPath(pen, p);
        }
        TextRenderer.DrawText(g, Badge, BadgeFont, new Point((int)(pill.X + 10 * s), (int)(pill.Y + 5 * s)), Color.White, TextFormatFlags.NoPadding);
        rx = pill.X - 12 * s;
      }
      if (!String.IsNullOrEmpty(Note)) {
        int w = (int)Math.Max(10, rx - x - TextRenderer.MeasureText(Title, TitleFont).Width - 30 * s);
        Size ns = TextRenderer.MeasureText(g, Note, SubFont, new Size(w, 9999), TextFormatFlags.WordBreak | TextFormatFlags.NoPadding);
        Rectangle nr = new Rectangle((int)(rx - Math.Min(ns.Width, w)), (int)((h - ns.Height) / 2f), Math.Min(ns.Width, w) + 2, ns.Height + 2);
        TextRenderer.DrawText(g, Note, SubFont, nr, Color.FromArgb(200, 208, 218), TextFormatFlags.WordBreak | TextFormatFlags.Right | TextFormatFlags.NoPadding);
      }
    }
  }

  // one big job button: colored icon tile with its number, title, one-line explanation
  public class Card : Button {
    public Color Accent = Color.FromArgb(37, 99, 235);
    public string Title = "", Sub = "", Glyph = "", Num = "", Tag2 = "";
    public Font TitleFont, SubFont, GlyphFont, NumFont, TagFont, ChevFont;
    public bool Clipped;   // 1.6.1: true when the title still does not fit at the smallest font (checked by the tests at 1024x768)
    bool hover, down;
    public Card() {
      SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
      FlatStyle = FlatStyle.Flat; FlatAppearance.BorderSize = 0; Cursor = Cursors.Hand;
    }
    protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { hover = false; down = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnMouseDown(MouseEventArgs e) { down = true; Invalidate(); base.OnMouseDown(e); }
    protected override void OnMouseUp(MouseEventArgs e) { down = false; Invalidate(); base.OnMouseUp(e); }
    protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }
    protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
    protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }
    protected override void OnPaint(PaintEventArgs e) {
      Graphics g = e.Graphics; float s = Gfx.S; bool on = Enabled;
      Color acc = on ? Accent : Color.FromArgb(176, 183, 192);
      Color fill = !on ? Color.FromArgb(246, 247, 249) : down ? Gfx.Mix(Accent, Color.White, 0.80f) : hover ? Gfx.Mix(Accent, Color.White, 0.93f) : Color.White;
      Color border = on && (hover || Focused) ? Gfx.Mix(Accent, Color.White, 0.35f) : Gfx.Line;
      Gfx.Card(g, this, fill, border, 10, true);
      float sh = 2 * s; RectangleF r = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f - sh);
      // accent edge
      using (GraphicsPath clip = Gfx.Round(r, 10 * s)) {
        Region old = g.Clip; g.SetClip(clip);
        using (SolidBrush b = new SolidBrush(acc)) g.FillRectangle(b, r.X, r.Y, 4 * s, r.Height);
        g.Clip = old;
      }
      float ts = Math.Min(r.Height - 14 * s, 42 * s); if (ts < 24 * s) ts = Math.Min(r.Height - 8 * s, 24 * s);
      RectangleF tile = new RectangleF(r.X + 18 * s, r.Y + (r.Height - ts) / 2f, ts, ts);
      using (GraphicsPath p = Gfx.Round(tile, 9 * s))
      using (LinearGradientBrush b = new LinearGradientBrush(tile, Gfx.Mix(acc, Color.White, 0.15f), Gfx.Mix(acc, Color.Black, 0.12f), 45f)) g.FillPath(b, p);
      bool glyph = GlyphFont != null && !String.IsNullOrEmpty(Glyph);
      if (glyph) Gfx.Glyph(g, Glyph, GlyphFont, Color.White, new RectangleF(tile.X, tile.Y + 1 * s, tile.Width, tile.Height));
      else Gfx.Glyph(g, Num, TitleFont, Color.White, tile);
      if (glyph && !String.IsNullOrEmpty(Num)) {
        float bs = 18 * s; RectangleF bc = new RectangleF(tile.X - 7 * s, tile.Y - 6 * s, bs, bs);
        using (SolidBrush b = new SolidBrush(fill)) g.FillEllipse(b, bc.X - 2 * s, bc.Y - 2 * s, bs + 4 * s, bs + 4 * s);
        using (SolidBrush b = new SolidBrush(Gfx.Mix(acc, Color.Black, 0.25f))) g.FillEllipse(b, bc);
        Gfx.Glyph(g, Num, NumFont, Color.White, new RectangleF(bc.X, bc.Y + 0.5f * s, bc.Width, bc.Height));
      }
      float x0 = tile.Right + 16 * s; float right = r.Right - 30 * s; int w = (int)Math.Max(20, right - x0);
      Color ink = on ? Color.FromArgb(28, 33, 40) : Color.FromArgb(150, 156, 165);
      Color muted = on ? Color.FromArgb(98, 107, 118) : Color.FromArgb(170, 176, 184);
      TextFormatFlags one = TextFormatFlags.NoPadding | TextFormatFlags.EndEllipsis | TextFormatFlags.SingleLine;
      bool tclip; Font tf = Gfx.Fit(g, Title, TitleFont, w, out tclip); Clipped = tclip;
      Size tsz = TextRenderer.MeasureText(g, Title, tf, new Size(w, 9999), one);
      int lineH = TextRenderer.MeasureText(g, "Ag", SubFont, new Size(9999, 9999), TextFormatFlags.NoPadding).Height;
      int maxLines = (int)((r.Height - 12 * s - tsz.Height - 2 * s) / lineH); if (maxLines > 2) maxLines = 2; if (maxLines < 0) maxLines = 0;
      int subH = 0;
      if (maxLines > 0 && !String.IsNullOrEmpty(Sub)) {
        Size full = TextRenderer.MeasureText(g, Sub, SubFont, new Size(w, 9999), TextFormatFlags.NoPadding | TextFormatFlags.WordBreak);
        subH = Math.Min(full.Height, lineH * maxLines);
      }
      float gap = subH > 0 ? 2 * s : 0; float y = r.Y + (r.Height - tsz.Height - gap - subH) / 2f;
      TextRenderer.DrawText(g, Title, tf, new Rectangle((int)x0, (int)y, w, tsz.Height + 2), ink, one);
      if (!Object.ReferenceEquals(tf, TitleFont)) tf.Dispose();
      if (!String.IsNullOrEmpty(Tag2) && TagFont != null) {
        Size tg = TextRenderer.MeasureText(g, Tag2, TagFont, new Size(9999, 9999), TextFormatFlags.NoPadding);
        RectangleF pill = new RectangleF(x0 + tsz.Width + 10 * s, y + (tsz.Height - tg.Height - 6 * s) / 2f + 1 * s, tg.Width + 12 * s, tg.Height + 6 * s);
        if (pill.Right < right) {
          using (GraphicsPath p = Gfx.Round(pill, pill.Height / 2f)) using (SolidBrush b = new SolidBrush(Gfx.Mix(acc, Color.White, 0.88f))) g.FillPath(b, p);
          TextRenderer.DrawText(g, Tag2, TagFont, new Point((int)(pill.X + 6 * s), (int)(pill.Y + 3 * s)), Gfx.Mix(acc, Color.Black, 0.25f), TextFormatFlags.NoPadding);
        }
      }
      if (subH > 0) {
        if (maxLines == 1) TextRenderer.DrawText(g, Sub, SubFont, new Rectangle((int)x0, (int)(y + tsz.Height + gap), w, subH + 2), muted, one);
        else using (StringFormat sf = new StringFormat()) using (SolidBrush b = new SolidBrush(muted)) {
          sf.Trimming = StringTrimming.EllipsisWord; sf.FormatFlags = StringFormatFlags.LineLimit;
          g.DrawString(Sub, SubFont, b, new RectangleF(x0 - 1 * s, y + tsz.Height + gap, w, subH + 4 * s), sf);
        }
      }
      if (ChevFont != null) Gfx.Glyph(g, "\uE76C", ChevFont, on && hover ? acc : Color.FromArgb(180, 187, 196), new RectangleF(r.Right - 30 * s, r.Y, 22 * s, r.Height));
    }
  }

  public class RoundPanel : Panel {
    public Color Fill = Color.White; public Color Border = Gfx.Line; public float Radius = 10; public bool Shadow = true;
    public RoundPanel() { SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true); BackColor = Color.White; }
    protected override void OnPaint(PaintEventArgs e) { Gfx.Card(e.Graphics, this, Fill, Border, Radius, Shadow); }
  }
  public class RoundFlow : FlowLayoutPanel {
    public Color Fill = Color.White; public Color Border = Gfx.Line; public float Radius = 10; public bool Shadow = true;
    public RoundFlow() { SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true); BackColor = Color.White; }
    protected override void OnPaint(PaintEventArgs e) { Gfx.Card(e.Graphics, this, Fill, Border, Radius, Shadow); }
  }

  // flat rounded button; Filled = main action
  public class FlatBtn : Button {
    public Color Accent = Color.FromArgb(37, 99, 235); public bool Filled; public string Glyph = ""; public Font GlyphFont;
    public Color TextColor = Color.Empty;
    public bool Clipped;
    bool hover, down;
    public FlatBtn() {
      SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
      FlatStyle = FlatStyle.Flat; FlatAppearance.BorderSize = 0; Cursor = Cursors.Hand;
    }
    int GW { get { return (GlyphFont != null && !String.IsNullOrEmpty(Glyph)) ? (int)(22 * Gfx.S) : 0; } }
    public override Size GetPreferredSize(Size proposed) {
      Size t = TextRenderer.MeasureText(Text, Font, new Size(9999, 9999), TextFormatFlags.NoPadding); float s = Gfx.S;
      return new Size(t.Width + GW + (int)(30 * s), Math.Max(t.Height + (int)(16 * s), (int)(34 * s)));
    }
    protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { hover = false; down = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnMouseDown(MouseEventArgs e) { down = true; Invalidate(); base.OnMouseDown(e); }
    protected override void OnMouseUp(MouseEventArgs e) { down = false; Invalidate(); base.OnMouseUp(e); }
    protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }
    protected override void OnPaint(PaintEventArgs e) {
      Graphics g = e.Graphics; Gfx.Smooth(g); float s = Gfx.S; g.Clear(Gfx.ParentBack(this));
      RectangleF r = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
      Color fill, border, text;
      if (!Enabled) { fill = Color.FromArgb(240, 242, 245); border = Gfx.Line; text = Color.FromArgb(160, 166, 175); }
      else if (Filled) { fill = down ? Gfx.Mix(Accent, Color.Black, 0.25f) : hover ? Gfx.Mix(Accent, Color.Black, 0.12f) : Accent; border = fill; text = Color.White; }
      else { fill = down ? Gfx.Mix(Accent, Color.White, 0.80f) : hover ? Gfx.Mix(Accent, Color.White, 0.92f) : Color.White; border = hover ? Gfx.Mix(Accent, Color.White, 0.40f) : Color.FromArgb(206, 212, 220); text = TextColor.IsEmpty ? Gfx.Mix(Accent, Color.Black, 0.15f) : TextColor; }
      using (GraphicsPath p = Gfx.Round(r, 7 * s)) {
        using (SolidBrush b = new SolidBrush(fill)) g.FillPath(b, p);
        using (Pen pen = new Pen(border)) g.DrawPath(pen, p);
      }
      int gw = GW; bool bclip; Font bf = Gfx.Fit(g, Text, Font, Width - gw - (int)(20 * s), out bclip); Clipped = bclip;
      Size t = TextRenderer.MeasureText(g, Text, bf, new Size(9999, 9999), TextFormatFlags.NoPadding);
      int tw = Math.Min(t.Width, Width - gw - (int)(20 * s));
      float x = (Width - tw - gw) / 2f;
      if (gw > 0) Gfx.Glyph(g, Glyph, GlyphFont, Filled || !Enabled ? text : Accent, new RectangleF(x - 2 * s, 0, gw, Height));
      TextRenderer.DrawText(g, Text, bf, new Rectangle((int)(x + gw), (Height - t.Height) / 2, tw + 2, t.Height + 2), text, TextFormatFlags.NoPadding | TextFormatFlags.EndEllipsis | TextFormatFlags.SingleLine);
      if (!Object.ReferenceEquals(bf, Font)) bf.Dispose();
    }
  }

  // small rounded status pill with a dot
  public class Pill : Control {
    public Color Accent = Color.FromArgb(100, 116, 139);
    public Pill() { SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true); }
    public void SetState(string text, Color c) {
      Text = text; Accent = c; Size t = TextRenderer.MeasureText(text, Font, new Size(9999, 9999), TextFormatFlags.NoPadding); float s = Gfx.S;
      Size = new Size(t.Width + (int)(34 * s), t.Height + (int)(10 * s)); Invalidate();
    }
    protected override void OnPaint(PaintEventArgs e) {
      Graphics g = e.Graphics; Gfx.Smooth(g); float s = Gfx.S; g.Clear(Gfx.ParentBack(this));
      RectangleF r = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
      using (GraphicsPath p = Gfx.Round(r, r.Height / 2f)) using (SolidBrush b = new SolidBrush(Gfx.Mix(Accent, Color.White, 0.87f))) g.FillPath(b, p);
      float d = 8 * s; using (SolidBrush b = new SolidBrush(Accent)) g.FillEllipse(b, 11 * s, (Height - d) / 2f, d, d);
      Size t = TextRenderer.MeasureText(g, Text, Font, new Size(9999, 9999), TextFormatFlags.NoPadding);
      TextRenderer.DrawText(g, Text, Font, new Point((int)(25 * s), (Height - t.Height) / 2), Gfx.Mix(Accent, Color.Black, 0.30f), TextFormatFlags.NoPadding);
    }
  }

  // numbered step title for the reset screen
  public class StepHead : Control {
    public Color Accent = Color.FromArgb(200, 16, 46); public string Num = ""; public Font NumFont, GlyphFont; public string Glyph = "";
    public StepHead() { SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true); }
    protected override void OnPaint(PaintEventArgs e) {
      Graphics g = e.Graphics; Gfx.Smooth(g); float s = Gfx.S; g.Clear(Gfx.ParentBack(this));
      float d = Math.Min(Height - 4 * s, 30 * s); RectangleF c = new RectangleF(0, (Height - d) / 2f, d, d);
      using (SolidBrush b = new SolidBrush(Accent)) g.FillEllipse(b, c);
      if (!String.IsNullOrEmpty(Num)) Gfx.Glyph(g, Num, NumFont, Color.White, new RectangleF(c.X, c.Y + 0.5f * s, c.Width, c.Height));
      else if (GlyphFont != null) Gfx.Glyph(g, Glyph, GlyphFont, Color.White, new RectangleF(c.X, c.Y + 1 * s, c.Width, c.Height));
      Size t = TextRenderer.MeasureText(g, Text, Font, new Size(9999, 9999), TextFormatFlags.NoPadding);
      TextRenderer.DrawText(g, Text, Font, new Rectangle((int)(d + 12 * s), (Height - t.Height) / 2, Width - (int)(d + 12 * s), t.Height + 2), Color.FromArgb(28, 33, 40), TextFormatFlags.NoPadding | TextFormatFlags.EndEllipsis | TextFormatFlags.SingleLine);
    }
  }

  // dashed drop box for the Hikvision reply file
  public class DropZone : Label {
    public Color Accent = Color.FromArgb(37, 99, 235); public string Glyph = ""; public Font GlyphFont, SmallFont; public string Small = "";
    bool over;
    public DropZone() { SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true); }
    public bool Over { get { return over; } set { over = value; Invalidate(); } }
    protected override void OnPaint(PaintEventArgs e) {
      Graphics g = e.Graphics; Gfx.Smooth(g); float s = Gfx.S; g.Clear(Gfx.ParentBack(this));
      RectangleF r = new RectangleF(1, 1, Width - 3, Height - 3);
      using (GraphicsPath p = Gfx.Round(r, 10 * s)) {
        using (SolidBrush b = new SolidBrush(Gfx.Mix(Accent, Color.White, over ? 0.82f : 0.95f))) g.FillPath(b, p);
        using (Pen pen = new Pen(Gfx.Mix(Accent, Color.White, 0.25f), 1.5f * s)) { pen.DashStyle = DashStyle.Dash; g.DrawPath(pen, p); }
      }
      Size t = TextRenderer.MeasureText(g, Text, Font, new Size(Width - (int)(20 * s), 9999), TextFormatFlags.NoPadding | TextFormatFlags.WordBreak);
      Size sm = String.IsNullOrEmpty(Small) ? Size.Empty : TextRenderer.MeasureText(g, Small, SmallFont, new Size(Width - (int)(20 * s), 9999), TextFormatFlags.NoPadding | TextFormatFlags.WordBreak);
      float gh = (GlyphFont != null && !String.IsNullOrEmpty(Glyph)) ? 30 * s : 0;
      float y = (Height - gh - t.Height - sm.Height - 4 * s) / 2f;
      if (gh > 0) Gfx.Glyph(g, Glyph, GlyphFont, Accent, new RectangleF(0, y, Width, gh));
      TextRenderer.DrawText(g, Text, Font, new Rectangle((int)(10 * s), (int)(y + gh), Width - (int)(20 * s), t.Height + 2), Gfx.Mix(Accent, Color.Black, 0.35f), TextFormatFlags.NoPadding | TextFormatFlags.WordBreak | TextFormatFlags.HorizontalCenter);
      if (sm.Height > 0) TextRenderer.DrawText(g, Small, SmallFont, new Rectangle((int)(10 * s), (int)(y + gh + t.Height + 4 * s), Width - (int)(20 * s), sm.Height + 2), Color.FromArgb(98, 107, 118), TextFormatFlags.NoPadding | TextFormatFlags.WordBreak | TextFormatFlags.HorizontalCenter);
    }
  }
}
'@
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
# the look (rounded cards, header, colored results) is drawn by a small built-in C# part; if Windows cannot build it, plain buttons are used
$TK_UI = $false
try {
  if (-not ('WireItUi.Card' -as [type])) { Add-Type -TypeDefinition $script:WireItUiCode -ReferencedAssemblies System.Windows.Forms, System.Drawing -ErrorAction Stop }
  $TK_UI = $true
} catch { $TK_UI = $false }
if (-not $Screenshot) {
  # sharp text on high-DPI screens (the Dell runs at 150%): the window sizes itself with Px() below
  try { if ($TK_UI) { [void][WireItUi.Gfx]::SetProcessDPIAware() } else { Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public static class WireItDpi{[DllImport("user32.dll")]public static extern bool SetProcessDPIAware();}' -ErrorAction Stop; [void][WireItDpi]::SetProcessDPIAware() } } catch {}
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
  # 2.2.18 (sweep D): Test-TkSkipUpdate - an unreadable "do not re-install" note holds the automatic update (was: read as no note)
  if ($u.state -eq 'available' -and $TK.cfg.autoUpdate -and -not (Test-TkSkipUpdate $here ([string]$u.manifest.version))) {
    try {
      if (Test-TkCanWrite $here) { $old = Install-TkUpdate $u.manifest $here }
      else { throw $script:TkNoWriteMsg }
      Write-TkLog $TK.P.Logs 'update' ('Updated from ' + $old + ' to ' + $u.manifest.version + ' at ' + (Get-Date)) | Out-Null
      $TK.mutex.ReleaseMutex(); $TK.mutex.Dispose()
      Start-Process -FilePath $TK.psexe -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "' + (Join-Path $here 'WireItToolkit.ps1') + '" -NoUpdate -UpdatedFrom ' + $old) -WindowStyle Hidden
      exit 0
    } catch { $TK.updateMsg = $_.Exception.Message }
  }
}
if ($UpdatedFrom) { $TK.updateMsg = 'Updated itself from v' + $UpdatedFrom + '.' }
if ($script:TkRepairMsg) { $TK.updateMsg = $script:TkRepairMsg + ' Close the Toolkit and open it again.' }
# 2.0.4: right after an update, check in once with the download service so it records this PC's new version
if ($UpdatedFrom -and -not $Screenshot) { try { [void](Get-TkUpdateInfo $TK.cfg $here) } catch {} }
# 2.2.3: an older install may still have the 2.2.x "Fix this site" task: it is switched off and deleted once (nothing runs as SYSTEM)
if (-not $Screenshot -and $env:OS -eq 'Windows_NT') { try { $null = & schtasks.exe /Query /TN '\WireIt\Fix this site' 2>$null; if ($LASTEXITCODE -eq 0) { $null = & schtasks.exe /Delete /TN '\WireIt\Fix this site' /F 2>$null; Write-TkLog $TK.P.Logs 'update' 'removed the old "Fix this site" SYSTEM task' | Out-Null } } catch {} }

# ---------------- 2.0: ONE screen first ("Fix this site"). The numbered buttons are behind "More tools" (or -Classic) ----------------
if (-not $Classic -and -not $Screenshot) {
  $fsw = Join-Path $here 'FixSiteWindow.ps1'
  if ((Test-Path $fsw) -and (Test-Path (Join-Path $here 'FixSite.ps1'))) {
    $fswResult = 'classic'
    try { $fswResult = [string](@(& $fsw -ToolkitDir $here -Version $TK.ver -Note $TK.updateMsg) | Select-Object -Last 1) } catch { $fswResult = 'classic'; Write-TkLog $TK.P.Logs 'window' ('One-button screen failed, opening the classic window: ' + $_.Exception.Message) | Out-Null }
    if ($fswResult -ne 'classic') { try { $TK.mutex.ReleaseMutex() } catch {}; exit 0 }
  }
}

# ---------------- look ----------------
$g = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $TK.scale = [math]::Max(1.0, $g.DpiX / 96.0); $g.Dispose()
$TK.fmul = 1.0
if ($Screenshot -and $SimScale -gt 0) { $TK.fmul = $SimScale / $TK.scale; $TK.scale = $SimScale }   # tests: draw like a 150% screen
function Get-WorkArea { if ($Screenshot) { if ($SimScreen -match '^(\d+)x(\d+)$') { return (New-Object Drawing.Rectangle(0, 0, [int]$Matches[1], ([int]$Matches[2] - 40))) }; return (New-Object Drawing.Rectangle(0, 0, 1920, 1032)) }; return [Windows.Forms.Screen]::PrimaryScreen.WorkingArea }
function Px([double]$n) { return [int]([math]::Round($n * $TK.scale)) }
function Fnt([double]$pt, [string]$face = 'Segoe UI', $style = 'Regular') { return (New-Object Drawing.Font($face, [single]($pt * $TK.fmul), [Drawing.FontStyle]$style)) }
$fams = @((New-Object Drawing.Text.InstalledFontCollection).Families | ForEach-Object { $_.Name })
$semi = $(if ($fams -contains 'Segoe UI Semibold') { 'Segoe UI Semibold' } else { 'Segoe UI' })
$TK.icons = $(if ($fams -contains 'Segoe Fluent Icons') { 'Segoe Fluent Icons' } elseif ($fams -contains 'Segoe MDL2 Assets') { 'Segoe MDL2 Assets' } else { '' })
function Ico([double]$pt) { if ($TK.icons) { return (Fnt $pt $TK.icons) }; return $null }
$fBig = Fnt 12.5 $semi
$fBtn = Fnt 11.5 $semi
$fNorm = Fnt 10
$fSmall = Fnt 9
$fBold = Fnt 10 $semi
$monoFace = 'Consolas'
$fMono = Fnt 9.5 $monoFace
$fCaps = Fnt 8.5 $semi
# WireIt colors: charcoal + the logo red, one accent color per job
$cInk = [Drawing.Color]::FromArgb(28, 33, 40); $cMuted = [Drawing.Color]::FromArgb(98, 107, 118); $cBg = [Drawing.Color]::FromArgb(241, 243, 246)
$cBrand = [Drawing.Color]::FromArgb(200, 16, 46); $cBlue = [Drawing.Color]::FromArgb(37, 99, 235); $cTeal = [Drawing.Color]::FromArgb(13, 148, 136)
$cAmber = [Drawing.Color]::FromArgb(217, 119, 6); $cIndigo = [Drawing.Color]::FromArgb(79, 70, 229); $cGreen = [Drawing.Color]::FromArgb(22, 163, 74); $cSlate = [Drawing.Color]::FromArgb(100, 116, 139)
$cOk = [Drawing.Color]::FromArgb(21, 128, 61); $cWarn = [Drawing.Color]::FromArgb(180, 83, 9); $cRed = [Drawing.Color]::FromArgb(200, 30, 30)
$cGrey = [Drawing.Color]::FromArgb(240, 242, 245)
if ($TK_UI) { [WireItUi.Gfx]::S = [single]$TK.scale }
$TK.logo = $null; $lp = Join-Path $here 'wireit-logo.png'; if (Test-Path $lp) { try { $TK.logo = [Drawing.Image]::FromStream((New-Object IO.MemoryStream(, [IO.File]::ReadAllBytes($lp)))) } catch {} }

# ---------------- building blocks (fancy when the C# part built, plain otherwise) ----------------
function New-Header([string]$title, [string]$sub, [string]$badge, [int]$h) {
  if ($TK_UI) {
    $x = New-Object WireItUi.Header; $x.Logo = $TK.logo; $x.Title = $title; $x.Sub = $sub; $x.Badge = $badge
    $x.TitleFont = Fnt 17 $semi; $x.SubFont = Fnt 9.5; $x.BadgeFont = Fnt 8.5 $semi
  } else {
    $x = New-Object Windows.Forms.Label; $x.Text = '  WireIt ' + $title + '   ' + $badge; $x.Font = Fnt 16 'Segoe UI' 'Bold'; $x.ForeColor = [Drawing.Color]::White; $x.BackColor = [Drawing.Color]::FromArgb(31, 36, 43); $x.TextAlign = 'MiddleLeft'
  }
  $x.Height = $h; $x.Margin = New-Object Windows.Forms.Padding 0; return $x
}
function New-Round([switch]$Flow) {
  if ($TK_UI) { if ($Flow) { $p = New-Object WireItUi.RoundFlow } else { $p = New-Object WireItUi.RoundPanel } }
  else { if ($Flow) { $p = New-Object Windows.Forms.FlowLayoutPanel } else { $p = New-Object Windows.Forms.Panel }; $p.BackColor = [Drawing.Color]::White; $p.BorderStyle = 'FixedSingle' }
  return $p
}
function New-Pill {
  if ($TK_UI) { $p = New-Object WireItUi.Pill } else { $p = New-Object Windows.Forms.Label; $p.AutoSize = $true }
  $p.Font = $fCaps; return $p
}
function Set-Pill([string]$text, $color) {
  if (-not $TK.pill) { return }
  if ($TK_UI) { $TK.pill.SetState($text, $color) } else { $TK.pill.Text = $text; $TK.pill.ForeColor = $color }
}
function Set-Primary($b, $color = $null) { if ($TK_UI -and $b -is [WireItUi.FlatBtn]) { $b.Filled = $true; if ($color) { $b.Accent = $color } }; return $b }
function Set-Glyph($b, [string]$glyph) { if ($TK_UI -and $TK.icons -and $b -is [WireItUi.FlatBtn]) { $b.Glyph = $glyph; $b.GlyphFont = Ico 10 }; return $b }
function New-Caps([string]$text) {
  $l = New-Object Windows.Forms.Label; $l.Text = $text.ToUpper(); $l.Font = $fCaps; $l.ForeColor = $cMuted; $l.AutoSize = $true; $l.BackColor = [Drawing.Color]::Transparent
  $l.Margin = New-Object Windows.Forms.Padding((Px 2), 0, 0, (Px 6)); return $l
}

# ---------------- results pane helpers ----------------
function Get-LineColor([string]$l) {
  if ($l -match '^\s*===') { return $cBlue }
  if ($l -match '(?i)\b(error|failed|fail|could not|cannot|can''t|not found|problem|denied|refused|wrong|missing|no answer|unreachable|not given|nothing ran)\b') {
    if ($l -match '(?i)did not work|finished, but') { return $cWarn }; return $cRed }
  if ($l -match '(?i)\b(warning|warn|router step needed|different ip scheme|did not work|old:|not on this pc|heads up|note:|unknown|reboot)\b') { return $cWarn }
  if ($l -match '(?i)\b(ok|done|fixed|finished|success|saved|ready|in short|all good|passed|online|moved|updated)\b') { return $cOk }
  return $cInk
}
function Add-Out([string]$text, $color = $null) {
  if ($null -eq $text) { return }
  $t = $text -replace "`r?`n", "`r`n"
  if (-not $t.EndsWith("`r`n")) { $t += "`r`n" }
  $box = $TK.out
  if ($box -is [Windows.Forms.RichTextBox]) {
    foreach ($ln in ($t.Substring(0, $t.Length - 2) -split "`r`n")) {
      $lc = $color; if ($ln.StartsWith('!! ')) { $ln = $ln.Substring(3); $lc = $cRed }   # ScanUpload: missing / new / changed IP
      $box.SelectionStart = $box.TextLength; $box.SelectionLength = 0
      $box.SelectionColor = $(if ($lc) { $lc } else { Get-LineColor $ln })
      $box.SelectionFont = $(if ($ln -match '^\s*===' -or $ln -match '^(In short|Usual order)') { $TK.fMonoB } else { $box.Font })
      $box.AppendText($ln + "`n")
    }
    $box.SelectionStart = $box.TextLength; $box.ScrollToCaret()
  } else { $box.AppendText($t) }
  if ($TK.run -and $TK.run.Log) { [void]$TK.run.Log.Append($t) }
}
function Set-Status([string]$s) { $TK.status.Text = $s }
function Add-OutTop([string[]]$lines, $color) {
  # puts lines at the very top of the results (red: missing / new / changed IP after a scan was saved to the site page)
  $box = $TK.out; $lines = @($lines | Where-Object { $_ }); if (-not $lines.Count -or -not ($box -is [Windows.Forms.RichTextBox])) { return }
  $ro = $box.ReadOnly; $box.ReadOnly = $false
  try { $box.SelectionStart = 0; $box.SelectionLength = 0; $box.SelectionColor = $color; $box.SelectionFont = $TK.fMonoB; $box.SelectedText = (($lines -join "`n") + "`n`n") } finally { $box.ReadOnly = $ro }
  $box.SelectionStart = 0; $box.SelectionLength = 0; $box.ScrollToCaret()
}
function Set-Busy([bool]$b) { foreach ($x in $TK.buttons) { $x.Enabled = -not $b }; $TK.out.Cursor = $(if ($b) { [Windows.Forms.Cursors]::AppStarting } else { [Windows.Forms.Cursors]::IBeam }) }
function Set-Clip([string]$text, [string]$what) {
  if (-not $text) { Set-Status ('Nothing to copy for ' + $what); return }
  try { [Windows.Forms.Clipboard]::SetText($text); Set-Status ('Copied ' + $what + '. Paste it with Ctrl+V.') } catch { Set-Status ('Could not copy ' + $what) }
}
function Begin-Run([string]$name, [bool]$keep = $false) {
  if (-not $keep) { $TK.out.Clear() }   # keep = a follow-up step (saving the list) under the results it follows
  $TK.run = @{ Name = $name; Log = (New-Object Text.StringBuilder); Started = Get-Date }
  if (-not $keep) { Add-Out ('=== ' + $name + ' - ' + (Get-Date -Format 'ddd MMM d, h:mm tt') + ' ===') }
  Set-Busy $true; Set-Status ($name + ' is running...'); Set-Pill ($name + ' - running') $cAmber
}
function End-Run([int]$code, [string]$plain) {
  $r = $TK.run; if (-not $r) { return }
  if ($plain) { Add-Out ''; Add-Out $plain }
  switch ($code) { 0 { Set-Pill ($r.Name + ' - done') $cOk } 4 { Set-Pill ($r.Name + ' - done, check the warnings') $cWarn } 3 { Set-Pill ($r.Name + ' - done, still filling (not an all-clear)') $cWarn } default { Set-Pill ($r.Name + ' - problem') $cRed } }
  $logPath = Write-TkLog $TK.P.Logs $r.Name $r.Log.ToString()
  $TK.run = $null
  Set-Busy $false; Set-Status ($r.Name + ' done. Saved to the logs folder.')
  $TK.lastRunStarted = $r.Started   # 2.2.19 (sweep2): the after-run step reads only result files THIS run wrote
  if ($r.OnDone) { try { & $r.OnDone $code } catch { Add-Out ('(after-run step failed: ' + $_.Exception.Message + ')') } }
}
function Test-Tool([string]$path, [string]$name) {
  if (Test-Path -LiteralPath $path) { return $true }
  Add-Out ($name + ' is not on this PC (' + $path + '). Copy the whole C:\WireIt folder from the other PC, or run Install-Toolkit again.')
  return $false
}

# 2.2.19 (sweep2, class C): a tool window whose exit code could not be read has NO known result: amber NOT CHECKED, never a green
# "done" (before, the Fix NVR / recorder windows ended green with "the tool window closed. Results are above.")
function Get-TkConsoleEnd([int]$code, [string]$name, [bool]$nvr) {
  if ($code -eq -1) { return [pscustomobject]@{ code = 4; plain = ('NOT CHECKED - ' + $name + ': the tool window closed and its result could not be read. Read the lines above; this is not an all-clear.') } }
  if ($nvr) { return [pscustomobject]@{ code = $code; plain = (Get-TkNvrPlainEnd $name $code) } }
  return [pscustomobject]@{ code = $code; plain = (Get-TkPlainEnd $name $code) }
}
# 2.2.19 (sweep2, class C/F): a "last result" file counts only when THIS run wrote it (not older than the run's start) and it can be
# read. Otherwise $null, and the caller says NOT CHECKED - never the PREVIOUS run's "all OK" / "fixed".
function Read-TkRunResult([string]$path, $since) {
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  if ($null -ne $since) {
    $wt = $null; try { $wt = (Get-Item -LiteralPath $path -ErrorAction Stop).LastWriteTime } catch { return $null }
    if ($wt -lt ([datetime]$since).AddSeconds(-2)) { return $null }
  }
  return (Read-TkJson $path)
}
# 2.2.19 (sweep2, class C): what the window shows for a fix / camera doctor result: green only when the tool said ok AND ended with
# code 0; red only for a confirmed failure (fix ran and did not work, doctor named fixes); anything unknown is amber NOT CHECKED
function Get-TkResultView([string]$kind, $j, $code) {
  $c = $(if ($null -eq $code -or "$code" -eq '') { -1 } else { [int]$code })
  if ($kind -eq 'fix') {
    if (-not $j) { return [pscustomobject]@{ text = ('FIX: NOT CHECKED - no result came back from this run (code ' + $c + '). Read the lines above.'); tone = 'warn' } }
    $m = $(if ($j.PSObject.Properties['msg'] -and [string]$j.msg) { [string]$j.msg } else { 'NOT CHECKED - the result had no message' })
    $okd = [bool]($j.PSObject.Properties['ok'] -and $j.ok -eq $true); $ran = [bool]($j.PSObject.Properties['ran'] -and $j.ran)
    if ($okd -and $c -ne 0) { $m += ' (but the tool ended with code ' + $c + ' - NOT CHECKED)' }
    return [pscustomobject]@{ text = ('FIX: ' + $m); tone = $(if ($okd -and $c -eq 0) { 'ok' } elseif ($ran -and -not $okd) { 'red' } else { 'warn' }) }
  }
  if (-not $j) { return [pscustomobject]@{ text = ('CAMERA DOCTOR: NOT CHECKED - no result came back from this run (code ' + $c + '). Read the lines above.'); tone = 'warn' } }
  $fx = @(@($j.fixes) | Where-Object { $_ })
  $v = $(if ($j.PSObject.Properties['verdict'] -and [string]$j.verdict) { [string]$j.verdict } else { 'NOT CHECKED - the result named no verdict' })
  return [pscustomobject]@{ text = ('CAMERA DOCTOR ' + [string]$j.ip + ': ' + $v); tone = $(if ($fx.Count) { 'red' } elseif ($c -eq 0 -and $j.PSObject.Properties['verdict'] -and [string]$j.verdict) { 'ok' } else { 'warn' }) }
}
function Get-TkToneColor([string]$tone) { if ($tone -eq 'ok') { return $cOk } elseif ($tone -eq 'red') { return $cRed } else { return $cWarn } }
# 2.2.19 (sweep2, class A/C; decision "classic adapter name unreadable -> refuse"): Restore Network's adapter list must be READ before
# anything runs. A list that could not be read (tool did not finish, no JSON line, damaged JSON) is a refusal, never a silent
# "-Auto" run on whatever adapter the tool picks by itself; an adapter with no name is not offered.
function Get-TkAdapterList([string]$text, [bool]$exited, $exitCode) {
  $no = { param($why) [pscustomobject]@{ ok = $false; ads = @(); msg = ('Restore Network: ' + $why + ' Nothing was changed. Run "Restore Network.cmd" from the Toolkit folder instead, or try again.') } }
  if (-not $exited) { return (& $no 'the list of this PC''s network adapters did not come back in time.') }
  if ($null -ne $exitCode -and "$exitCode" -ne '' -and [int]$exitCode -ne 0) { return (& $no ('the list of this PC''s network adapters could not be read (code ' + $exitCode + ').')) }
  $m = [regex]::Match([string]$text, '(?m)^JSON=(.+)$')
  if (-not $m.Success) { return (& $no 'the list of this PC''s network adapters could not be read.') }
  $ads = @(); try { $ads = @($m.Groups[1].Value.Trim() | ConvertFrom-Json -ErrorAction Stop | ForEach-Object { $_ }) } catch { return (& $no 'the list of this PC''s network adapters was damaged.') }   # 2.2.11: ForEach-Object unrolls PS 5.1's one-item array
  $ads = @($ads | Where-Object { $_ -and $_.PSObject.Properties['name'] -and ([string]$_.name).Trim() })
  if (-not $ads.Count) { return (& $no 'no network adapter with a readable name was found.') }
  return [pscustomobject]@{ ok = $true; ads = $ads; msg = '' }
}

# hidden run: output streams into the results pane
function Start-Hidden([string]$name, [string]$file, [string]$argLine, [scriptblock]$onDone, [bool]$keep = $false) {
  if ($TK.run) { Set-Status 'Wait for the running tool to finish.'; return $false }
  Begin-Run $name $keep
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
  # 2.2.16: on the STANDARD Crew login RunAs asks for an administrator's name + password and this runs as that admin account (not Crew); UNVERIFIED, DEFERRED
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
      $ce = Get-TkConsoleEnd $code $r.Name $false; End-Run $ce.code $ce.plain
    }
  } else {
    if (-not $r.RunDir) { $d = Get-TkNewRunDir $(if ($r.Root) { $r.Root } else { $TK.P.FixNVR }) $r.Mode $r.Since; if ($d) { $r.RunDir = $d.FullName } }
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
      $ce = Get-TkConsoleEnd $code $r.Name ([bool]$r.Nvr); End-Run $ce.code $ce.plain
    }
  }
}

# ---------------- small input dialog ----------------
function New-AskForm([string]$title, [string]$intro, $fields) {
  # a single field @(@('site','Site:','')) arrives unrolled as 3 strings (Nov 3 bug: 3 boxes labelled "i", "t" and blank)
  $fields = @($fields); if ($fields.Count -gt 0 -and $fields[0] -is [string]) { $fields = ,$fields }
  $f = New-Object Windows.Forms.Form; $f.Text = $title; $f.Font = $fNorm; $f.BackColor = [Drawing.Color]::White; if ($TK.form -and $TK.form.Icon) { $f.Icon = $TK.form.Icon }; $f.StartPosition = 'CenterParent'; $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false
  $f.AutoSize = $true; $f.AutoSizeMode = 'GrowAndShrink'; $f.Padding = New-Object Windows.Forms.Padding (Px 18)
  $t = New-Object Windows.Forms.TableLayoutPanel; $t.ColumnCount = 2; $t.AutoSize = $true; $t.Dock = 'Fill'
  $l0 = New-Object Windows.Forms.Label; $l0.Text = $intro; $l0.AutoSize = $true; $l0.MaximumSize = New-Object Drawing.Size((Px 520), 0); $t.Controls.Add($l0); $t.SetColumnSpan($l0, 2)
  $boxes = @{}
  foreach ($fd in $fields) {
    $l = New-Object Windows.Forms.Label; $l.Text = $fd[1]; $l.AutoSize = $true; $l.Anchor = 'Left'; $t.Controls.Add($l)
    $b = New-Object Windows.Forms.TextBox; $b.Width = Px 320; $b.Margin = New-Object Windows.Forms.Padding((Px 3), (Px 5), (Px 3), (Px 5)); $b.Text = [string]$fd[2]; $t.Controls.Add($b); $boxes[$fd[0]] = $b
  }
  $ok = Set-Primary (New-Btn 'OK' $null) $cBlue; $ok.DialogResult = 'OK'
  $cn = New-Btn 'Cancel' $null; $cn.DialogResult = 'Cancel'
  $fl = New-Object Windows.Forms.FlowLayoutPanel; $fl.AutoSize = $true; $fl.Margin = New-Object Windows.Forms.Padding(0, (Px 10), 0, 0); $fl.Controls.AddRange(@($ok, $cn)); $t.Controls.Add($fl); $t.SetColumnSpan($fl, 2)
  $f.Controls.Add($t); $f.AcceptButton = $ok; $f.CancelButton = $cn
  return @{ form = $f; boxes = $boxes }
}
function Ask-Fields([string]$title, [string]$intro, $fields) {
  $fields = @($fields); if ($fields.Count -gt 0 -and $fields[0] -is [string]) { $fields = ,$fields }
  $af = New-AskForm $title $intro $fields; $f = $af.form; $boxes = $af.boxes
  if ($f.ShowDialog($TK.form) -ne 'OK') { return $null }
  $res = @{}; foreach ($k in $boxes.Keys) { $res[$k] = $boxes[$k].Text.Trim() }; return $res
}
function Q([string]$s) { return '"' + ($s -replace '"', '') + '"' }

# ---------------- the 12 jobs ----------------
function Do-Find {
  $TK.findStarted = [DateTime]::UtcNow   # 2.2.7 (F07): what counts as THIS scan's list
  [void](Start-Hidden 'Find cameras' (Join-Path $TK.P.CamReset 'Find-Cameras.ps1') '' {
    param($code)
    if (-not (Test-TkFreshScan $TK.P.CamReset $code $TK.findStarted)) {
      # 2.2.7 (Codex file-by-file F07): a failed or stopped Find cameras never shows, saves or uploads the PREVIOUS list
      Add-Out ('Find cameras did not finish' + $(if ($null -ne $code -and [int]$code -ne 0) { ' (code ' + $code + ')' } else { ' with a new camera list' }) + '. The previous camera list was not used, saved or uploaded.') $cRed
      Invoke-AfterScan; return
    }
    $d = @(Get-TkDevices $TK.P.CamReset)
    if ($d.Count) {
      $hik = @($d | Where-Object { $_.Brand -like 'Hikvision*' }).Count; $unv = @($d | Where-Object { $_.Brand -eq 'Uniview' }).Count
      $other = @($d | Where-Object { $_.Status -like '*different IP scheme*' }).Count
      $swp = @($d | Where-Object { $_.PSObject.Properties['SweepOnly'] -and $_.SweepOnly }).Count
      Add-Out ('In short: ' + $d.Count + ' device(s) found - ' + $hik + ' Hikvision, ' + $unv + ' Uniview' + $(if ($swp) { '; ' + $swp + ' found only by the network sweep' } else { '' }) + $(if ($other) { '; ' + $other + ' on a different IP scheme (button 3 Fix NVR moves them)' } else { '' }) + '.')
    }
    if ($TK.rs -and $TK.rs.form -and -not $TK.rs.form.IsDisposed) { Fill-ResetList }
    # Nov 3 2026: the list goes to the site's page (one list per site, compared with the last scan)
    if ($d.Count -and $TK.site.Text.Trim()) { Start-ScanUpload '' }
    else { if ($d.Count) { Add-Out ''; Add-Out 'Tip: type the site to save this list to the site page.' $cBlue }; Invoke-AfterScan }
  })
}
function Start-ScanUpload([string]$snapshotFile) {
  $su = Join-Path $TK.P.Toolkit 'ScanUpload.ps1'
  $a = '-Site ' + (Q $TK.site.Text.Trim()) + ' -CamResetDir ' + (Q $TK.P.CamReset); if ($snapshotFile) { $a += ' -Snapshot ' + (Q $snapshotFile) }
  [void](Start-Hidden 'Save to site page' $su $a {
    param($code)
    $j = Read-TkRunResult (Join-Path $TK.P.Toolkit 'logs\scan-upload-last.json') $TK.lastRunStarted   # 2.2.19 (sweep2): this run's result only
    if ($j -and @($j.red).Count) { Add-OutTop @($j.red) $cRed }
    elseif (-not $j -and $null -ne $code -and [int]$code -ne 0) { Add-Out ('Save to site page: no result came back (code ' + $code + ') - the list is NOT confirmed saved on the site page.') $cWarn }
    Invoke-AfterScan
  } $true)
}
# "Check this site" goes on after the camera list step (whatever happened there)
function Invoke-AfterScan { if ($TK.afterScan) { $n = $TK.afterScan; $TK.afterScan = $null; & $n } }
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
# 2.2.11 (add-on #3): Restore Network - this PC's network adapter back to normal (RestoreNetwork.ps1 does it all and says
# "DONE - network is back to normal" or "FAILED - Run again"; Windows asks permission only when something must change)
function Do-RestoreNet {
  $rn = Join-Path $here 'RestoreNetwork.ps1'
  if (-not (Test-Tool $rn 'Restore Network')) { return }
  $t = ''; $done = $false; $xc = $null
  try {
    $lo = Join-Path ([IO.Path]::GetTempPath()) ('wireit-rnlist-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.txt')
    $p = [Diagnostics.Process]::Start((New-TkHiddenPsi $TK.psexe $rn '-List' $lo)); $done = [bool]$p.WaitForExit(20000)
    if ($done) { try { $xc = $p.ExitCode } catch { $xc = $null } } else { try { $p.Kill() } catch {} }
    $t = [IO.File]::ReadAllText($lo); Remove-Item -LiteralPath $lo -Force -ErrorAction SilentlyContinue
  } catch { $t = '' }
  # 2.2.11 Office GUI click: PS 5.1 ConvertFrom-Json gives the whole array as ONE item; Get-TkAdapterList unrolls it.
  # 2.2.19 (sweep2): a list that could not be read is a refusal - before, it ran "-Auto" on the adapter the tool chose by itself
  $al = Get-TkAdapterList $t $done $xc
  if (-not $al.ok) { $TK.out.Clear(); Add-Out $al.msg $cWarn; Set-Status 'Restore Network did not run.'; return }
  $ads = @($al.ads)
  $pick = ''
  if ($ads.Count -gt 1) {
    $f = New-Object Windows.Forms.Form; $f.Text = 'Restore network'; $f.Font = $fNorm; $f.StartPosition = 'CenterParent'; $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.AutoSize = $true; $f.AutoSizeMode = 'GrowAndShrink'; $f.Padding = New-Object Windows.Forms.Padding (Px 14)
    $fl = New-Object Windows.Forms.FlowLayoutPanel; $fl.FlowDirection = 'TopDown'; $fl.AutoSize = $true; $fl.WrapContents = $false
    $l = New-Object Windows.Forms.Label; $l.AutoSize = $true; $l.Text = 'Reset chosen adapter to DHCP (extra addresses off). Which network adapter?'   # 2.2.13 (Codex advice): the label says what it does; $fl.Controls.Add($l)
    $lb = New-Object Windows.Forms.ListBox; $lb.Width = Px 460; $lb.Height = Px 120
    $sel = 0; for ($i = 0; $i -lt $ads.Count; $i++) { $a = $ads[$i]; [void]$lb.Items.Add(([string]$a.name + '  (' + [string]$a.desc + ')' + $(if ($a.needs) { '   <- not normal' } else { '' }))); if ($a.needs -and -not $sel) { $sel = $i } }
    $lb.SelectedIndex = $sel; $fl.Controls.Add($lb)
    $bp = New-Object Windows.Forms.FlowLayoutPanel; $bp.AutoSize = $true
    $ok = Set-Primary (New-Btn 'Restore' $null) $cBlue; $ok.DialogResult = 'OK'; $cn = New-Btn 'Cancel' $null; $cn.DialogResult = 'Cancel'
    $bp.Controls.Add($ok); $bp.Controls.Add($cn); $fl.Controls.Add($bp); $f.Controls.Add($fl); $f.AcceptButton = $ok; $f.CancelButton = $cn
    if ($f.ShowDialog($TK.form) -ne 'OK') { return }
    $pick = [string]$ads[$lb.SelectedIndex].name
  } elseif ($ads.Count -eq 1) { $pick = [string]$ads[0].name }
  if (-not $pick) { $TK.out.Clear(); Add-Out 'Restore Network: no adapter was chosen. Nothing was changed.' $cWarn; return }
  $a2 = '-Auto -Adapter "' + ($pick -replace '"', '') + '"'
  [void](Start-Hidden 'Restore Network' $rn $a2 $null)
  if ($TK.run) { Add-Out 'Restore network: Reset chosen adapter to DHCP (extra addresses off; its old settings are saved first). If Windows asks for permission, click Yes.'; Add-Out '' }
}
function Do-Snapshot {
  $a = Ask-Fields 'Save install snapshot' 'Saves a known-good record of the NVR and cameras (no passwords). Fill what you know; blanks are fine.' @(
    @('site', 'Site ID or address:', $TK.site.Text), @('router', 'Router make/model (e.g. Xfinity XB8):', ''), @('range', 'Router DHCP range (e.g. 100-254, or reserved):', ''))
  if (-not $a) { return }
  $e = @(); if ($a.site) { $e += '-Site ' + (Q $a.site); $TK.site.Text = $a.site }; if ($a.router) { $e += '-RouterModel ' + (Q $a.router) }; if ($a.range) { $e += '-DhcpRange ' + (Q $a.range) }
  $TK.snapSince = Get-Date
  Start-Fix 'Install snapshot' 'Snapshot' $e {
    param($code)
    # the snapshot is also the site's known-good camera list on the site page (one list, Moshe Nov 3)
    $sn = Get-TkNewestSnapshot $TK.P.FixNVR $TK.snapSince
    if ($sn -and $TK.site.Text.Trim()) { Start-ScanUpload $sn.FullName } elseif ($sn) { Add-Out 'Tip: type the site to save this snapshot to the site page.' $cBlue }
  }
}
function Do-Pics {
  $a = Ask-Fields 'Save camera pictures' 'Takes one picture of every camera on the NVR (read-only) and puts it on the site page, so a camera that goes down shows where it is. Type the Site ID (e.g. WI-061) or the site folder name.' (,@('site', 'Site ID or address:', $TK.site.Text))
  if (-not $a) { return }
  if (-not $a.site) { $TK.out.Clear(); Add-Out 'Type the site (Site ID like WI-061, or the site folder name) so the pictures go to the right site page.'; return }
  $TK.site.Text = $a.site
  Start-Fix 'Camera pictures' 'Pictures' @('-Site ' + (Q $a.site)) $null
}
# ---------------- 9-12 Recorder health (NvrHealth module) ----------------
# its own (not elevated) window: the recorder password is typed hidden there; the results come back here
function Start-Nvr([string]$name, [string]$mode, [string[]]$extra, [scriptblock]$onDone = $null, [bool]$keep = $false, [string]$script = 'NvrCheck.ps1') {
  if ($TK.run) { Set-Status 'Wait for the running tool to finish.'; return }
  Begin-Run $name $keep
  $file = Join-Path $TK.P.Toolkit $script; $isFix = ($script -eq 'FixIt.ps1')
  if (-not (Test-Tool $file $name)) { End-Run 2 ''; return }
  if (-not (Test-Path (Join-Path $TK.P.NvrHealth 'NvrHealth.psm1'))) { Add-Out 'The NvrHealth part of the Toolkit is missing. Use "Check for update".'; End-Run 2 ''; return }
  $a = '-NoProfile -ExecutionPolicy Bypass -File "' + $file + '" ' + $(if ($isFix) { '-Fix ' } else { '-Mode ' }) + $mode
  foreach ($e in $extra) { if ($e) { $a += ' ' + $e } }
  Add-Out $(if ($isFix) { 'A tool window opens. Type the passwords there - hidden, never saved. Nothing changes until you type YES there.' } else { 'A tool window opens. Type the recorder''s user name and password there - hidden, never saved.' })
  Add-Out 'Results show up here as it works.'
  Add-Out ''
  $since = Get-Date
  try { $proc = Start-Process -FilePath $TK.psexe -ArgumentList $a -PassThru -WorkingDirectory $TK.P.Toolkit -ErrorAction Stop }
  catch { Add-Out ('Could not start: ' + $_.Exception.Message); End-Run 2 ''; return }
  $TK.run.Kind = 'console'; $TK.run.Proc = $proc; $TK.run.Mode = $(if ($isFix) { 'Fix-' + $mode } else { 'Nvr' + $mode }); $TK.run.Root = $TK.P.Toolkit; $TK.run.Nvr = $true
  $TK.run.Since = $since; $TK.run.RunDir = $null; $TK.run.Offset = [long]0; $TK.run.Shown = 0; $TK.run.OnDone = $onDone
}
# ---------------- Camera doctor (Nov 3 2026): ONE camera, why is it offline? Read-only + ONE login try ----------------
function Do-Doctor {
  $a = Ask-Fields 'Camera doctor' 'One camera, step by step: ping, MAC, ports, web page, ONE login try with the site password (typed in the tool window, never saved), video port, and what DW says about it. Changes nothing - it tells you the fix.' @(
    @('ip', 'Camera IP address:', ''), @('dw', 'DW server IP (blank = not a DW site):', ''), @('maker', 'Maker (auto / uniview / hikvision):', 'auto'))
  if (-not $a) { return }
  if ($a.ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { $TK.out.Clear(); Add-Out 'Type the camera''s IP address, e.g. 10.1.61.29.'; return }
  $e = @('-Ip ' + $a.ip); if ($a.dw -match '^\d{1,3}(\.\d{1,3}){3}$') { $e += '-DwIp ' + $a.dw }
  $mk = Get-TkVendorArg $a.maker; if ($mk -in @('Uniview', 'Hikvision')) { $e += '-Maker ' + $mk }
  $mac = Get-TkSavedMac $a.ip; if ($mac) { $e += '-Mac ' + $mac }
  Start-Nvr 'Camera doctor' 'Doctor' $e { param($code) Show-Doctor $code }
}
function Get-TkSavedMac([string]$ip) {
  try { foreach ($d in @(Get-TkDevices $TK.P.CamReset)) { if ([string]$d.IP -eq $ip -and $d.MAC) { return ([string]$d.MAC).ToUpper().Replace('-', ':') } } } catch {}
  return ''
}
function Show-Doctor($code = $null) {
  # 2.2.19 (sweep2): only the result THIS run wrote; no result / no verdict / a non-zero end is amber NOT CHECKED, never green
  $c = Read-TkRunResult (Join-Path $TK.P.Toolkit 'logs\doctor-last.json') $TK.lastRunStarted
  $v = Get-TkResultView 'doctor' $c $code
  Add-OutTop @($v.text) (Get-TkToneColor $v.tone)
  if ($c) { Show-Fixes @($c.fixes) }
}
function Get-LastNvrIp { $f = Join-Path $TK.P.Logs 'last-nvr-ip.txt'; if (Test-Path $f) { return ([string](Get-Content $f -TotalCount 1)).Trim() }; return '' }
function Do-Nvr([string]$mode) {
  $names = @{ Recording = 'Recording check'; Clock = 'Clock check'; FixClock = 'Fix clock (NTP)'; Firmware = 'Firmware / security check' }
  $intro = @{
    Recording = 'Read-only. Is every camera recording? How many days of footage are kept vs. the site''s target? Hard drives and their health.'
    Clock     = 'Read-only. Recorder (and camera) clocks vs. real time, time server on, US Eastern with daylight saving.'
    FixClock  = 'CHANGES the recorder''s time settings (time server + US Eastern). It shows the plan first; nothing changes until you type YES in its window.'
    Firmware  = 'Read-only. Firmware vs. the newest published and known security holes. Only REPORTS - it never updates anything.'
  }
  $fields = @(@('ip', 'Recorder IP address:', (Get-LastNvrIp)), @('site', 'Site ID or address (optional):', $TK.site.Text), @('vendor', 'Recorder type (auto / hikvision / uniview / dw):', 'auto'))
  if ($mode -eq 'Recording') { $fields += ,@('days', 'Days to keep (blank = from the site):', '') }
  else { $fields += ,@('cams', 'Cameras too? (yes / no):', 'yes') }
  $a = Ask-Fields $names[$mode] $intro[$mode] $fields
  if (-not $a) { return }
  if ($a.ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { $TK.out.Clear(); Add-Out 'Type the recorder''s IP address, e.g. 192.168.1.20 (button 1 Find cameras lists it).'; return }
  if ($mode -eq 'FixClock') {
    $m = 'Fix clock changes the time settings on the recorder at ' + $a.ip + $(if ($a.cams -match '^(y|yes)$') { ' and its cameras' } else { '' }) + ' (time server time.nist.gov + US Eastern with daylight saving).' + "`r`n`r`n" + 'Step 1 only shows what would change. Nothing changes until you type YES in the tool window.' + "`r`n`r`n" + 'Do this on site, with the customer''s OK. Continue?'
    if ([Windows.Forms.MessageBox]::Show($TK.form, $m, 'Fix clock (NTP)', 'YesNo', 'Warning') -ne 'Yes') { return }
  }
  try { New-Item -ItemType Directory -Force -Path $TK.P.Logs | Out-Null; Set-Content -Path (Join-Path $TK.P.Logs 'last-nvr-ip.txt') -Value $a.ip } catch {}
  if ($a.site) { $TK.site.Text = $a.site }
  $e = @('-Ip ' + $a.ip); if ($a.site) { $e += '-Site ' + (Q $a.site) }; $vd = Get-TkVendorArg $a.vendor; if ($vd -ne 'Auto') { $e += '-Vendor ' + $vd }
  if ($mode -eq 'Recording') {
    $d = 0; if ($a.days -match '^\d+$') { $d = [int]$a.days } elseif ($a.site) { $d = Get-TkDaysToKeep $TK.cfg $a.site }   # 0 = NvrCheck asks the DW server's name
    $e += '-Days ' + $d
  } elseif ($a.cams -match '^(y|yes)$') { $e += '-Cameras' }
  Start-Nvr $names[$mode] $mode $e
}

# ---------------- Check this site (Nov 3 2026): ONE read-only button - find cameras + compare, router, recording, clocks, firmware ----------------
# Never runs a fix. Writes ONE "Latest check" card on the site page (overwritten each time). Fix buttons appear only for what failed.
function Do-SiteCheck {
  $a = Ask-Fields 'Check this site' 'Read-only, about 2 minutes: finds the cameras and compares them with the site list, checks the router (UPnP / ports open to the internet), recording, streams, clocks and firmware. Changes nothing. The result goes to the site page as its "Latest check".' @(
    @('ip', 'Recorder IP address:', (Get-LastNvrIp)), @('site', 'Site ID or address:', $TK.site.Text), @('vendor', 'Recorder type (auto / hikvision / uniview / dw):', 'auto'), @('cams', 'Cameras too? (yes / no):', 'yes'))
  if (-not $a) { return }
  if ($a.ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { $TK.out.Clear(); Add-Out 'Type the recorder''s IP address, e.g. 192.168.1.20 (button 1 Find cameras lists it).'; return }
  try { New-Item -ItemType Directory -Force -Path $TK.P.Logs | Out-Null; Set-Content -Path (Join-Path $TK.P.Logs 'last-nvr-ip.txt') -Value $a.ip } catch {}
  $TK.site.Text = [string]$a.site
  $e = @('-Ip ' + $a.ip, '-Days ' + $(if ($a.site) { Get-TkDaysToKeep $TK.cfg $a.site } else { 0 })); if ($a.site) { $e += '-Site ' + (Q $a.site) }; if ($a.cams -match '^(y|yes)$') { $e += '-Cameras' }
  $vd = Get-TkVendorArg $a.vendor; if ($vd -ne 'Auto') { $e += '-Vendor ' + $vd }
  $TK.scArgs = $e; Hide-Fixes
  $TK.afterScan = {
    Add-Out ''; Add-Out 'Next: router, recording, clocks and firmware. A tool window opens - type the recorder''s user name and password there (hidden, never saved, ONE try). Leave the password empty to skip the login: nothing is sent and those parts show NOT CHECKED.' $cBlue
    Start-Nvr 'Check this site' 'Site' $TK.scArgs { param($code) Show-SiteCheck $code } $true
  }
  Do-Find
  if (-not $TK.run) { $TK.afterScan = $null }
}
function Show-SiteCheck($code = $null) {
  # 2.2.19 (sweep2, class C): only the check THIS run wrote counts; none (tool stopped, file damaged, an older file) = NOT CHECKED
  $c = Read-TkRunResult (Join-Path $TK.P.Toolkit 'logs\check-site-last.json') $TK.lastRunStarted
  if (-not $c) { Add-OutTop @('CHECK THIS SITE: NOT CHECKED - no result came back from this check' + $(if ($null -ne $code) { ' (code ' + $code + ')' } else { '' }) + '. This is not an all-clear.') $cWarn; return }
  $red = @($c.lines | Where-Object { $_.k -eq 'red' } | ForEach-Object { [string]$_.t })
  # 1.6.1: "not checked" parts (login refused / skipped, unreadable clock) are amber and the result is never "all OK"
  $ncl = @($c.lines | Where-Object { $_.k -eq 'warn' -and [string]$_.t -match '(?i)not checked' } | ForEach-Object { [string]$_.t })
  # 2.2.16 (Codex 2.2.15 F6): a recorder still filling toward its days-to-keep target is PENDING - amber, not a fault, never "all OK".
  # (A check saved by 2.2.15 has no 'pending' field, only page.rec.stillFilling - read that too.)
  $pend = ''; if ($c.PSObject.Properties['pending'] -and $c.pending) { $pend = $(if ($c.PSObject.Properties['pendingWhy'] -and $c.pendingWhy) { [string]$c.pendingWhy } else { 'recorder still filling' }) }
  elseif ($c.page -and $c.page.rec -and $c.page.rec.PSObject.Properties['stillFilling'] -and $c.page.rec.stillFilling) { $pend = 'recorder still filling (' + $c.page.rec.daysHeld + ' of ' + $c.page.rec.target + ' days)' }
  if ($red.Count) { Add-OutTop (@('CHECK THIS SITE - needs attention:') + $red + $ncl) $cRed }
  elseif ($ncl.Count -or ($c.page -and @($c.page.notChecked).Count)) { Add-OutTop (@('CHECK THIS SITE - NOT everything could be checked (this is not an all-clear):') + $ncl + $(if ($pend) { @('Also: ' + $pend + '.') } else { @() })) $cWarn }
  elseif ($pend) { Add-OutTop @('CHECK THIS SITE: ' + $pend + ', nothing broken found. Not an all-clear yet - check again when it has filled.') $cWarn }
  elseif ($c.ok -eq $true -and ($null -eq $code -or [int]$code -eq 0)) { Add-OutTop @('CHECK THIS SITE: all OK.') $cOk }   # 2.2.19 (sweep2): "all OK" needs the tool's own code 0 too
  else { Add-OutTop @('CHECK THIS SITE: see the details below.') $cWarn }
  Show-Fixes @($c.fixes)
}
# Release C fills these in; until then the row only says which fixes would apply
function Hide-Fixes { if ($TK.fixRow) { $TK.fixRow.Controls.Clear(); $TK.fixRow.Visible = $false } }
function Show-Fixes([string[]]$keys) {
  if (-not $keys -or -not $keys.Count) { return }
  $names = @(@(foreach ($k in $keys) { if ($TK.fixNames.Contains($k)) { $TK.fixNames[$k] } elseif ($k -eq 'replace') { 'replace the camera (by hand)' } }) | Select-Object -Unique)
  if ($TK.fixOn) { Add-Out ''; Add-Out ('Nothing was changed. Press "Fix what failed" for: ' + ($names -join ', ') + '. Each fix shows its plan and asks for YES first.') $cWarn }
  else { Add-Out ''; Add-Out ('Nothing was changed. What would fix it: ' + ($names -join ', ') + ' (fix buttons come in the next update).') $cWarn }
}
# ---------------- Release C (Nov 3 2026): fix buttons - only for what the last check / Camera doctor found. UNTESTED ON REAL GEAR ----------------
$TK.fixNames = [ordered]@{ recording = 'Turn recording back on'; restart = 'Restart the camera'; poe = 'Restart the camera'; readd = 'Put the camera back on the NVR'; ntp = 'Set the time server'; firmware = 'Update firmware (one device)'; password = 'Set the site password'; dwpassword = 'Fix the camera password in DW' }
function Get-TkFailedFixes {
  $keys = @(); $now = Get-Date
  foreach ($f in @('logs\check-site-last.json', 'logs\doctor-last.json')) {
    $p = Join-Path $TK.P.Toolkit $f; if (-not (Test-Path $p)) { continue }
    if (($now - (Get-Item $p).LastWriteTime).TotalHours -gt 24) { continue }   # only a recent check counts
    $j = Read-TkJson $p; if ($j) { $keys += @($j.fixes | ForEach-Object { if ($_ -eq 'poe') { 'restart' } else { [string]$_ } }) }
  }
  return @($keys | Where-Object { $TK.fixNames.Contains($_) } | Select-Object -Unique)
}
function Do-FixMenu {
  $keys = @(Get-TkFailedFixes)
  if (-not $keys.Count) { $TK.out.Clear(); Add-Out 'Nothing to fix: run "Check this site" or "Camera doctor" first. Fix buttons show only for a check that failed (in the last 24 hours).'; return }
  $f = New-Object Windows.Forms.Form; $f.Text = 'Fix what failed'; $f.Font = $fNorm; $f.StartPosition = 'CenterParent'; $f.AutoSize = $true; $f.AutoSizeMode = 'GrowAndShrink'; $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false
  $fl = New-Object Windows.Forms.FlowLayoutPanel; $fl.FlowDirection = 'TopDown'; $fl.AutoSize = $true; $fl.Padding = New-Object Windows.Forms.Padding((Px 12)); $f.Controls.Add($fl)
  $fl.Controls.Add((New-Lbl 'Only fixes for what the last check found. Each one shows its plan, saves a backup, and changes nothing until you type YES. Not yet tested on real equipment.' $null (Px 420)))
  foreach ($k in $keys) { $b = New-Btn $TK.fixNames[$k] $null $k; $b.Add_Click({ param($sender) $sender.FindForm().Tag = [string]$sender.Tag; $sender.FindForm().Close() }); $fl.Controls.Add($b) }
  $c = New-Btn 'Cancel' { param($sender) $sender.FindForm().Close() }; $fl.Controls.Add($c)
  [void]$f.ShowDialog($TK.form)
  if ($f.Tag) { Do-FixFailed ([string]$f.Tag) }
}
# 2.2.3 (Codex #27): was a second "Do-Fix", which replaced the Fix NVR button's own Do-Fix (the button then did nothing)
function Do-FixFailed([string]$key) {
  $doc = Read-TkJson (Join-Path $TK.P.Toolkit 'logs\doctor-last.json'); $camIp = $(if ($doc) { [string]$doc.ip } else { '' })
  $rx = '^\d{1,3}(\.\d{1,3}){3}$'
  switch ($key) {
    'ntp' { Do-Nvr 'FixClock'; return }
    'recording' { $a = Ask-Fields $TK.fixNames[$key] 'Turns recording back on for the cameras whose recording is switched off. Backup first; YES needed.' @(@('ip', 'Recorder IP address:', (Get-LastNvrIp)), @('vendor', 'Recorder type (auto / hikvision / dw):', 'auto')); if (-not $a -or $a.ip -notmatch $rx) { return }; $e = @('-Ip ' + $a.ip); $vd = Get-TkVendorArg $a.vendor; if ($vd -ne 'Auto') { $e += '-Vendor ' + $vd } }
    'restart' { $a = Ask-Fields $TK.fixNames[$key] 'Reboots ONE camera through its own web page (Hikvision / Uniview). At most once an hour, twice a day. YES needed.' @(@('ip', 'Camera IP address:', $camIp)); if (-not $a -or $a.ip -notmatch $rx) { return }; $e = @('-Ip ' + $a.ip) }
    'readd' { $a = Ask-Fields $TK.fixNames[$key] 'Puts a camera back on its NVR channel (Hikvision NVR). The camera password is typed in the tool window, never saved.' @(@('ip', 'NVR IP address:', (Get-LastNvrIp)), @('ch', 'Channel number:', ''), @('cam', 'Camera IP address:', $camIp)); if (-not $a -or $a.ip -notmatch $rx -or $a.ch -notmatch '^\d+$' -or $a.cam -notmatch $rx) { return }; $e = @('-Ip ' + $a.ip, '-Channel ' + $a.ch, '-CameraIp ' + $a.cam) }
    'firmware' { $a = Ask-Fields $TK.fixNames[$key] 'ONE device. Download the file from the maker''s site and copy its SHA-256 from that page. Settings are exported first.' @(@('ip', 'Device IP address:', ''), @('file', 'Firmware file (full path):', ''), @('sha', 'SHA-256 from the maker''s page:', '')); if (-not $a -or $a.ip -notmatch $rx -or -not $a.file) { return }; $e = @('-Ip ' + $a.ip, '-File ' + (Q $a.file), '-Sha256 ' + $a.sha) }
    'password' { $a = Ask-Fields $TK.fixNames[$key] 'Sets the site password on ONE device (Hikvision). You type it twice in the tool window; it is never saved.' @(@('ip', 'Device IP address:', $camIp)); if (-not $a -or $a.ip -notmatch $rx) { return }; $e = @('-Ip ' + $a.ip) }
    'dwpassword' { $a = Ask-Fields $TK.fixNames[$key] 'Gives DW the camera''s right password so DW stops locking it. Type the DW login and the camera password in the tool window.' @(@('ip', 'DW server IP address:', (Get-LastNvrIp)), @('cam', 'Camera IP address:', $camIp)); if (-not $a -or $a.ip -notmatch $rx -or $a.cam -notmatch $rx) { return }; $e = @('-Ip ' + $a.ip, '-CameraIp ' + $a.cam) }
    default { return }
  }
  if ($TK.site.Text) { $e += '-Site ' + (Q $TK.site.Text) }
  Start-Nvr $TK.fixNames[$key] $key $e { param($code) Show-FixDone $code } $false 'FixIt.ps1'
}
function Show-FixDone($code = $null) {
  # 2.2.19 (sweep2, class C/F): the PREVIOUS fix's "ok" is never shown for this run; green needs ok AND the tool's code 0
  $j = Read-TkRunResult (Join-Path $TK.P.Toolkit 'logs\fix-last.json') $TK.lastRunStarted
  $v = Get-TkResultView 'fix' $j $code
  Add-OutTop @($v.text) (Get-TkToneColor $v.tone)
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
  if ($TK_UI) { $b = New-Object WireItUi.FlatBtn; $b.Accent = $cBlue } else { $b = New-Object Windows.Forms.Button; $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderColor = $cBlue; $b.ForeColor = $cBlue; $b.BackColor = [Drawing.Color]::White }
  $b.Text = $text; $b.AutoSize = $true; $b.MinimumSize = New-Object Drawing.Size((Px 90), (Px 36)); $b.Font = $fBold; $b.Tag = $tag
  $b.Margin = New-Object Windows.Forms.Padding((Px 0), (Px 4), (Px 8), (Px 4)); if ($click) { $b.Add_Click($click) }; return $b
}
function New-Lbl([string]$text, $font = $null, [int]$width = 0) {
  $l = New-Object Windows.Forms.Label; $l.Text = $text; $l.AutoSize = $true; if ($font) { $l.Font = $font } else { $l.Font = $fNorm }
  $l.ForeColor = $cInk; $l.BackColor = [Drawing.Color]::Transparent
  if ($width -gt 0) { $l.MaximumSize = New-Object Drawing.Size($width, 0) }; $l.Margin = New-Object Windows.Forms.Padding((Px 0), (Px 4), (Px 3), (Px 4)); return $l
}
function New-Step([string]$title, [string]$num = '', $accent = $null) {
  # one white rounded card per step: a numbered circle + title, then the step's buttons and words
  $W = $TK.rs.W
  if (-not $accent) { $accent = $cBrand }
  $card = New-Round -Flow; $card.FlowDirection = 'TopDown'; $card.WrapContents = $false; $card.AutoSize = $true; $card.AutoSizeMode = 'GrowAndShrink'
  $card.Padding = New-Object Windows.Forms.Padding((Px 20), (Px 14), (Px 20), (Px 16)); $card.Margin = New-Object Windows.Forms.Padding(0, 0, 0, (Px 12))
  if ($TK_UI) {
    $hdr = New-Object WireItUi.StepHead; $hdr.Text = $title; $hdr.Num = $num; $hdr.Accent = $accent; $hdr.Font = $fBig; $hdr.NumFont = Fnt 10.5 $semi
    if (-not $num) { $hdr.GlyphFont = Ico 10.5; $hdr.Glyph = [string][char]0xE8B1 }
    $hdr.Size = New-Object Drawing.Size($W, (Px 36))
  } else { $hdr = New-Lbl ($(if ($num) { $num + '  ' } else { '' }) + $title) $fBig $W; $hdr.ForeColor = $accent }
  $hdr.Margin = New-Object Windows.Forms.Padding(0, 0, 0, (Px 6))
  $card.Controls.Add($hdr)
  $fl = New-Object Windows.Forms.FlowLayoutPanel; $fl.AutoSize = $true; $fl.WrapContents = $true; $fl.MaximumSize = New-Object Drawing.Size($W, 0); $fl.MinimumSize = New-Object Drawing.Size($W, 0)
  $fl.BackColor = [Drawing.Color]::White; $fl.Margin = New-Object Windows.Forms.Padding(0)
  $card.Controls.Add($fl)
  $TK.rs.flow.Controls.Add($card)
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
    $b = Set-Glyph (New-Btn ($f.Label + ':  ' + $f.Value) { Set-Clip $this.Tag.Value $this.Tag.Label } $f) ([string][char]0xE8C8); if ($TK_UI) { $b.TextColor = $cInk; $b.Font = $fNorm }
    $rs.fields.Controls.Add($b); $rs.fieldBtns += $b
  }
  $note = ''
  if (-not $d) { $rs.devLbl.Text = 'No device picked yet.'; return }
  $rs.devLbl.Text = 'Picked: ' + $d.Brand + ' ' + $d.Model + '   serial ' + $d.ShortSerial + '   IP ' + $d.IP
  if ($d.Activated -eq 'false') { $note = 'This one is factory fresh: NO reset needed. In HiTools, tick it > Activate, and use a password from step 5.' }
  elseif ($d.Brand -eq 'Uniview') { $note = $(if ($d.DefaultLoginWorks -eq 'YES') { 'Uniview with the factory password (admin/123456): NO reset needed. Log in and set a password from step 5.' } else { 'Uniview: this screen is for Hikvision. Locked Uniview cameras use the Uniview bulk form (CamReset README, step U).' }) }
  elseif ($d.Brand -notlike 'Hikvision*') { $note = 'Not a Hikvision device.' }
  $rs.noteLbl.Text = $note; $rs.noteLbl.Visible = [bool]$note
  $q = Get-Req $d; $rs.req = $q; Show-Req
}
function Show-Req {
  $rs = $TK.rs; $q = $rs.req
  if ($q) {
    $hl = Get-TkHoursLeft $q
    $rs.xmlLbl.Text = 'Reset file ready: ' + $q.xmlFile + '. ' + $(if ($hl -ge 0) { 'Good for about ' + $hl + ' more hours.' } else { 'OLD: the 48 hours are over, export a new one.' }) + ' Do NOT unplug or reboot the device until the reset is done.'
    $rs.xmlLbl.ForeColor = $(if ($hl -ge 0) { $cOk } else { $cRed })
    if ($q.replyFile) { $rs.replyLbl.Text = 'Reply file in: ' + $q.replyFile; $rs.replyLbl.ForeColor = $cOk }
  } else {
    $rs.xmlLbl.Text = 'Waiting for the exported file (the Toolkit watches the save folder and Downloads).'; $rs.xmlLbl.ForeColor = $cMuted
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
  $rs.replyLbl.Text = $r.message; $rs.replyLbl.ForeColor = $(if ($r.ok -and $r.request) { $cOk } else { $cRed })
  if ($r.ok) { $rs.replyFile = $r.file; if ($r.request) { $rs.req = Get-TkRequests $TK.P.CamReset | Where-Object { $_.serial -eq $r.request.serial } | Select-Object -First 1 }; Rs-Log ('reply file filed: ' + $r.file) }
}
# 2.2.0: "I got Hik's email" in Reset passwords: the file goes the same way as a dragged one; a pasted code is kept as a small file
# next to the request and copied, for HiTools' "Import Key"
function Show-RsHikDrop {
  $rs = $TK.rs; if (-not $rs) { return }
  $devs = @(Get-TkRequests $TK.P.CamReset | Where-Object { $_.serial -or $_.shortSerial } | ForEach-Object { [pscustomobject]@{ serial = $(if ($_.serial) { [string]$_.serial } else { [string]$_.shortSerial }); shortSerial = [string]$_.shortSerial; model = [string]$_.model; ip = [string]$_.ip } })
  if ($rs.req) { $cur = @($devs | Where-Object { $_.shortSerial -eq [string]$rs.req.shortSerial }); $devs = @($cur) + @($devs | Where-Object { $_.shortSerial -ne [string]$rs.req.shortSerial }) }
  if (-not $devs.Count) { [void][Windows.Forms.MessageBox]::Show($rs.form, 'No reset request is on this PC yet. Do steps 1-3 first (the request file goes to Hikvision, then their email comes back).', 'WireIt Toolkit'); return }
  $save = {
    param($sn, $file, $code)
    if ($file) { Take-Reply $file; return [pscustomobject]@{ ok = $true; why = '' } }
    $c = ConvertTo-HikCode $code
    if (-not $c) { return [pscustomobject]@{ ok = $false; why = 'paste the code from Hikvision''s email (letters and digits only)' } }
    $tmpD = Join-Path ([IO.Path]::GetTempPath()) ('wireit-code-' + [guid]::NewGuid().ToString('N').Substring(0, 6)); New-Item -ItemType Directory -Force -Path $tmpD | Out-Null
    $cf = Join-Path $tmpD ('hik-code-' + ($sn -replace '[^A-Za-z0-9-]', '_') + '.txt'); [IO.File]::WriteAllText($cf, $c)
    $r = Import-TkReply $cf $TK.P.CamReset ([string]$sn); Remove-Item -LiteralPath $tmpD -Recurse -Force -ErrorAction SilentlyContinue
    if ($r.ok) { $TK.rs.replyFile = $r.file; Set-Clip $c 'the code from Hikvision'; $TK.rs.replyLbl.Text = 'Code saved for serial ' + $sn + ' and copied. In HiTools use Reset Password > Import Key and paste it, with the new password from step 5.'; $TK.rs.replyLbl.ForeColor = $cOk; Rs-Log 'code from Hikvision filed (not logged)' }
    return [pscustomobject]@{ ok = [bool]$r.ok; why = [string]$r.message }
  }
  [void](Show-HikEmailDialog $rs.form $devs $save)
}
# 2.2.0: while a request waits for Hikvision, ask the reply relay once a minute (no mail password on this PC; off when config has no relay url)
function Poll-RsRelay {
  $rs = $TK.rs; if (-not $rs -or -not (Get-Command Get-HikRelayReply -ErrorAction SilentlyContinue)) { return }
  $rc = $null; try { if ($TK.cfg.PSObject.Properties['hikReset'] -and $TK.cfg.hikReset.relay -and [string]$TK.cfg.hikReset.relay.url) { $rc = $TK.cfg.hikReset.relay } } catch {}
  if (-not $rc) { return }
  if ($rs.relayNext -and (Get-Date) -lt $rs.relayNext) { return }
  $rs.relayNext = (Get-Date).AddSeconds(60)
  $open = @(Get-TkRequests $TK.P.CamReset | Where-Object { -not $_.replyFile -and (Get-TkHoursLeft $_) -ge 0 })
  if (-not $open.Count) { return }
  $key = Get-HikRelayKey $here
  foreach ($q in $open) {
    $r = Get-HikRelayReply $rc $key ([pscustomobject]@{ serial = $(if ($q.serial) { [string]$q.serial } else { [string]$q.shortSerial }); shortSerial = [string]$q.shortSerial }) 15
    if ($r.state -eq 'failed') { $rs.replyLbl.Text = 'Could not check the reply mailbox (' + $r.msg + '). When Hikvision''s email comes, press "I got Hik''s email".'; $rs.replyLbl.ForeColor = $cRed; return }
    if ($r.state -eq 'found') {
      $a = @($r.message.attachments)[0]
      $tmpD = Join-Path ([IO.Path]::GetTempPath()) ('wireit-relay-' + [guid]::NewGuid().ToString('N').Substring(0, 6)); New-Item -ItemType Directory -Force -Path $tmpD | Out-Null
      $tf = Join-Path $tmpD ([string]$a.name); [IO.File]::WriteAllBytes($tf, [byte[]]$a.bytes)
      Take-Reply $tf; Remove-Item -LiteralPath $tmpD -Recurse -Force -ErrorAction SilentlyContinue
      if ($a.name -like '*-code.txt') { Set-Clip ([Text.Encoding]::ASCII.GetString([byte[]]$a.bytes)) 'the code from Hikvision' }
      Set-Status ('Hikvision''s reply for ' + [string]$q.model + ' came in by itself (reply mailbox).')
    }
  }
}
function Show-ResetWindow([string]$dropFile = '') {
  $rs = @{ fieldBtns = @(); dev = $null; req = $null; watch = $false; watchSince = (Get-Date); replyFile = ''; pw = ''; lastWatch = (Get-Date) }
  $TK.rs = $rs
  $f = New-Object Windows.Forms.Form; $rs.form = $f
  $f.Text = 'WireIt Toolkit - Reset passwords (Hikvision, official method)'; $f.Font = $fNorm; $f.BackColor = $cBg; if ($TK.form -and $TK.form.Icon) { $f.Icon = $TK.form.Icon }
  $wa = Get-WorkArea
  $want = New-Object Drawing.Size([math]::Min((Px 1060), [int]($wa.Width * 0.95)), [math]::Min((Px 900), [int]($wa.Height * 0.95)))
  $f.Size = $want; $f.StartPosition = 'CenterScreen'
  $f.AllowDrop = $true
  $rs.client = New-Object Drawing.Size(($want.Width - ($f.Width - $f.ClientSize.Width)), ($want.Height - ($f.Height - $f.ClientSize.Height)))
  $padX = Px 22
  $rs.CW = $rs.client.Width - 2 * $padX - [Windows.Forms.SystemInformation]::VerticalScrollBarWidth - (Px 4)   # card width
  $rs.W = $rs.CW - (Px 40)                                                                                         # inside a card
  $flow = New-Object Windows.Forms.FlowLayoutPanel; $flow.Dock = 'Fill'; $flow.FlowDirection = 'TopDown'; $flow.WrapContents = $false; $flow.AutoScroll = $true
  $flow.Padding = New-Object Windows.Forms.Padding($padX, (Px 16), $padX, (Px 16)); $flow.BackColor = $cBg
  $hostP = New-Object Windows.Forms.Panel; $hostP.Dock = 'Fill'; $hostP.BackColor = $cBg; $rs.host = $hostP; $f.Controls.Add($hostP)
  $rs.flow = $flow; $hostP.Controls.Add($flow)
  $hd = New-Header 'Reset passwords' ('Hikvision camera or NVR   ' + [char]0x00B7 + '   official Hikvision method') ('v' + $TK.ver) (Px 72); $hd.Dock = 'Top'; $hostP.Controls.Add($hd); $flow.BringToFront(); $rs.head = $hd
  $W = $rs.W
  $intro = New-Lbl 'Unknown password on a Hikvision camera or NVR: Hikvision unlocks it with a reset file. You type the picture code on their form; the Toolkit does the rest. Go top to bottom.' $fNorm $rs.CW
  $intro.ForeColor = $cMuted; $intro.Margin = New-Object Windows.Forms.Padding((Px 2), 0, 0, (Px 12)); $flow.Controls.Add($intro)

  $s1 = New-Step 'Pick the device' '1'
  $lv = New-Object Windows.Forms.ListView; $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.HideSelection = $false; $lv.MultiSelect = $false; $lv.Font = $fNorm; $lv.BorderStyle = 'FixedSingle'; $lv.ForeColor = $cInk; $lv.Margin = New-Object Windows.Forms.Padding(0, (Px 2), 0, (Px 6))
  $lv.Size = New-Object Drawing.Size($W, (Px 150))
  foreach ($c in @(@('Brand', 110), @('Model', 200), @('Serial (9)', 110), @('IP', 130), @('Status', [math]::Max(200, ($W / $TK.scale) - 560)))) { [void]$lv.Columns.Add($c[0], (Px $c[1])) }
  $lv.Add_SelectedIndexChanged({ if ($TK.rs.list.SelectedItems.Count) { $TK.rs.dev = $TK.rs.list.SelectedItems[0].Tag } else { $TK.rs.dev = $null }; Show-Selected })
  $rs.list = $lv; $s1.Controls.Add($lv)
  $rs.scanLbl = New-Lbl '' $null ($W - (Px 200)); $rs.scanLbl.ForeColor = $cMuted; $rs.scanLbl.Margin = New-Object Windows.Forms.Padding(0, (Px 11), 0, 0); $s1.Controls.Add((Set-Glyph (New-Btn 'Scan now' { Do-Find }) ([string][char]0xE72C))); $s1.Controls.Add($rs.scanLbl)
  $rs.devLbl = New-Lbl '' $fBold $W; $s1.Controls.Add($rs.devLbl); $s1.SetFlowBreak($rs.devLbl, $true)
  $rs.noteLbl = New-Lbl '' $fBold $W; $rs.noteLbl.ForeColor = $cRed; $rs.noteLbl.Visible = $false; $s1.Controls.Add($rs.noteLbl)

  $s2 = New-Step 'Make the reset file in HiTools (about 30 seconds)' '2'
  $exportDir = Join-Path $TK.P.CamReset 'requests\export'
  $s2.Controls.Add((New-Lbl ('Open HiTools > tick the device > Reset Password > Import/Export Key > Export XML File > save it in ' + $exportDir + '  (click "Copy save folder", paste it in the save box). NVR: one file also covers its cameras if you tick them too.') $null $W))
  $s2.Controls.Add((Set-Glyph (Set-Primary (New-Btn 'Open HiTools' { Open-HiTools })) ([string][char]0xE8A7)))
  $s2.Controls.Add((Set-Glyph (New-Btn 'Copy save folder' { New-Item -ItemType Directory -Force -Path $this.Tag | Out-Null; Set-Clip $this.Tag 'the save folder' } $exportDir) ([string][char]0xE8C8)))
  $s2.Controls.Add((New-Btn 'I saved it somewhere else - pick the file' {
    $o = New-Object Windows.Forms.OpenFileDialog; $o.Filter = 'Hikvision export (*.xml)|*.xml|All files|*.*'; $o.Title = 'Pick the XML file HiTools exported'
    if ($o.ShowDialog($TK.rs.form) -eq 'OK') { Use-Xml $o.FileName } }))
  $rs.xmlLbl = New-Lbl '' $fBold $W; $s2.Controls.Add($rs.xmlLbl)

  $s3 = New-Step 'Send it to Hikvision (their US form)' '3'
  $s3.Controls.Add((New-Lbl 'Click "Open the Hikvision form", then click each button below and paste (Ctrl+V) into the matching box. Upload: click "Copy XML file path", paste it into the File name box and press Enter. Tick the owner/authorized statement, type the picture code, Submit.' $null $W))
  $s3.Controls.Add((Set-Glyph (Set-Primary (New-Btn 'Open the Hikvision form' { try { Start-Process ([string]$TK.cfg.hikvisionForm) } catch { Set-Status 'Could not open the browser.' } })) ([string][char]0xE774)))
  $s3.Controls.Add((Set-Glyph (New-Btn 'Copy XML file path' { Set-Clip (Get-XmlPath) 'the XML file path' }) ([string][char]0xE8C8)))
  $s3.Controls.Add((New-Btn 'Show XML file' { $x = Get-XmlPath; if ($x -and (Test-Path -LiteralPath $x)) { Start-Process explorer.exe ('/select,"' + $x + '"') } else { Set-Status 'No XML file yet (step 2).' } }))
  $fields = New-Object Windows.Forms.FlowLayoutPanel; $fields.AutoSize = $true; $fields.BackColor = [Drawing.Color]::FromArgb(248, 249, 251); $fields.Padding = New-Object Windows.Forms.Padding((Px 8)); $fields.Margin = New-Object Windows.Forms.Padding(0, (Px 6), 0, (Px 6)); $fields.MaximumSize = New-Object Drawing.Size($W, 0); $fields.MinimumSize = New-Object Drawing.Size($W, 0); $rs.fields = $fields; $s3.Controls.Add($fields)
  $s3.Controls.Add((New-Lbl ('The answer goes to ' + $TK.cfg.form.email + ' (usually a few hours). It is only good for 48 hours and only if the device has NOT rebooted.') $null $W))

  $s4 = New-Step 'When Hikvision emails back: drag the attached file here' '4'
  if ($TK_UI) {
    $drop = New-Object WireItUi.DropZone; $drop.Text = 'Drag the file from Hikvision''s email here'; $drop.Small = 'Save the attachment first, then drag it onto this box (or onto the Toolkit window).'
    $drop.Accent = $cBlue; $drop.Font = $fBold; $drop.SmallFont = $fSmall; $drop.GlyphFont = Ico 18; $drop.Glyph = [string][char]0xE896
  } else {
    $drop = New-Object Windows.Forms.Label; $drop.Text = 'Drag the file from Hikvision''s email here' + "`r`n" + '(save the attachment first, then drag it onto this box, or onto the Toolkit window)'
    $drop.TextAlign = 'MiddleCenter'; $drop.BorderStyle = 'FixedSingle'; $drop.BackColor = $cGrey; $drop.Font = $fBold
  }
  $drop.Size = New-Object Drawing.Size(($W - (Px 190)), (Px 104)); $drop.AllowDrop = $true; $drop.Margin = New-Object Windows.Forms.Padding(0, (Px 4), (Px 12), (Px 4))
  $s4.Controls.Add($drop)
  $s4.Controls.Add((Set-Glyph (New-Btn 'Pick the file' { $o = New-Object Windows.Forms.OpenFileDialog; $o.Filter = 'Hikvision reply (*.xml;*.zip;*.txt)|*.xml;*.zip;*.txt|All files|*.*'; if ($o.ShowDialog($TK.rs.form) -eq 'OK') { Take-Reply $o.FileName } }) ([string][char]0xE8E5)))
  # 2.2.0: the reply mailbox is checked by itself (the relay, every minute while a request waits); this button is the backup
  $s4.Controls.Add((Set-Glyph (New-Btn "I got Hik's email" { Show-RsHikDrop }) ([string][char]0xE715)))
  $rs.replyLbl = New-Lbl '' $fBold $W; $s4.Controls.Add($rs.replyLbl)
  $dragEnter = { if ($_.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) { $_.Effect = 'Copy'; if ($TK_UI -and $TK.rs.drop) { $TK.rs.drop.Over = $true } } }
  $dragDrop = { if ($TK_UI -and $TK.rs.drop) { $TK.rs.drop.Over = $false }; $files = $_.Data.GetData([Windows.Forms.DataFormats]::FileDrop); if ($files) { Take-Reply ([string]$files[0]) } }
  $rs.drop = $drop; $drop.Add_DragEnter($dragEnter); $drop.Add_DragDrop($dragDrop); $drop.Add_DragLeave({ if ($TK_UI -and $TK.rs.drop) { $TK.rs.drop.Over = $false } }); $f.Add_DragEnter($dragEnter); $f.Add_DragDrop($dragDrop)

  $s5 = New-Step 'Put it in and set the new password' '5'
  $s5.Controls.Add((New-Lbl 'HiTools > tick the device > Reset Password > Reset via XML File (or Import Key) > pick the reply file (click "Copy reply file path", paste, Enter) > paste the new password in both boxes > OK. NVR: tick "also reset the connected cameras".' $null $W))
  $s5.Controls.Add((Set-Glyph (Set-Primary (New-Btn 'Make a new password' {
    $TK.rs.pw = New-TkPassword ([int]$TK.cfg.passwordLength); $TK.rs.pwBox.Text = $TK.rs.pw; $TK.rs.pwBox.Visible = $true
    Rs-Log 'new password made (not logged)'; Set-Status 'New password made. Copy it into HiTools, then save it in Bitwarden.' }) $cGreen) ([string][char]0xE8D7)))
  $pwBox = New-Object Windows.Forms.TextBox; $pwBox.ReadOnly = $true; $pwBox.Font = Fnt 16 'Consolas' 'Bold'; $pwBox.Width = Px 280; $pwBox.BackColor = [Drawing.Color]::FromArgb(236, 253, 243); $pwBox.ForeColor = $cOk; $pwBox.BorderStyle = 'FixedSingle'; $pwBox.Margin = New-Object Windows.Forms.Padding(0, (Px 4), (Px 8), (Px 4)); $pwBox.Visible = $false; $rs.pwBox = $pwBox
  $s5.Controls.Add($pwBox)
  $s5.Controls.Add((Set-Glyph (New-Btn 'Copy password' { Set-Clip $TK.rs.pw 'the new password' }) ([string][char]0xE8C8)))
  $s5.Controls.Add((Set-Glyph (New-Btn 'Copy reply file path' { $r = $TK.rs.replyFile; if (-not $r -and $TK.rs.req -and $TK.rs.req.replyFile) { $r = [string]$TK.rs.req.replyFile }; Set-Clip $r 'the reply file path' }) ([string][char]0xE8C8)))
  $s5.Controls.Add((Set-Glyph (New-Btn 'Open HiTools' { Open-HiTools }) ([string][char]0xE8A7)))
  $bwl = New-Lbl 'Save it in Bitwarden right away (WireIt CT > Sites): name = site + model + serial, user admin, the new password.' $fBold $W; $bwl.MinimumSize = New-Object Drawing.Size($W, 0); $bwl.Margin = New-Object Windows.Forms.Padding(0, (Px 10), 0, (Px 2)); $s5.Controls.Add($bwl)
  $s5.Controls.Add((Set-Glyph (New-Btn 'Copy Bitwarden name' { $d = $TK.rs.dev; $n = ''; if ($TK.site.Text.Trim()) { $n = $TK.site.Text.Trim() + ' - ' }; if ($d) { $n += $d.Model + ' ' + $d.ShortSerial }; Set-Clip $n 'the Bitwarden item name' }) ([string][char]0xE8C8)))
  $s5.Controls.Add((Set-Glyph (New-Btn 'Open Bitwarden' { try { Start-Process ([string]$TK.cfg.bitwardenUrl) } catch {} }) ([string][char]0xE774)))
  $s5.Controls.Add((Set-Glyph (New-Btn 'Saved in Bitwarden - hide it' { Clear-Pw; Set-Status 'Password hidden and cleared from the clipboard.' }) ([string][char]0xE73E)))

  $s6 = New-Step 'Other way (no email wait): Reset via QR Code' '' $cSlate
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
$form.Text = 'WireIt Toolkit  v' + $TK.ver; $form.Font = $fNorm; $form.BackColor = $cBg; $form.ForeColor = $cInk; $form.AllowDrop = $true
$ico = Join-Path $here 'wireit.ico'; if (Test-Path $ico) { try { $form.Icon = New-Object Drawing.Icon($ico) } catch {} }
$wa = Get-WorkArea
$TK.want = New-Object Drawing.Size([math]::Min((Px 1180), [int]($wa.Width * 0.95)), [math]::Min((Px 800), [int]($wa.Height * 0.95)))
$form.Size = $TK.want; $form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object Drawing.Size([math]::Min((Px 800), $form.Width), [math]::Min((Px 560), $form.Height))
$TK.fMonoB = Fnt 9.5 $monoFace 'Bold'

$root = New-Object Windows.Forms.TableLayoutPanel; $root.Dock = 'Fill'; $root.ColumnCount = 1; $root.RowCount = 3; $root.Margin = New-Object Windows.Forms.Padding 0
[void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', (Px 74)))); [void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100))); [void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize')))
# Nov 3 2026 (YKW Elm, 1024x768 over AnyDesk: bottom row cut off): below this size the window scrolls instead of squeezing
$hostP = New-Object Windows.Forms.Panel; $hostP.Dock = 'Fill'; $hostP.AutoScroll = $true; $hostP.AutoScrollMinSize = New-Object Drawing.Size((Px 900), (Px 600)); $TK.hostP = $hostP
$hostP.Controls.Add($root); $form.Controls.Add($hostP)

# header: WireIt logo, title, version
$note = $(if ($TK.updateMsg) { $TK.updateMsg } else { '' })
$dot = '   ' + [char]0x00B7 + '   '
$hdr = New-Header 'Toolkit' (('Find cameras', 'Fix NVRs', 'Reset passwords', 'Check the network') -join $dot) ('v' + $TK.ver) (Px 74); $hdr.Dock = 'Fill'
if ($TK_UI) { $hdr.Note = $note }
$root.Controls.Add($hdr, 0, 0)
$upd = New-Object Windows.Forms.Label; $upd.Visible = $false; $upd.Text = 'v' + $TK.ver + $(if ($note) { '  -  ' + $note } else { '' })   # (kept for the plain look)
if (-not $TK_UI -and $note) { $hdr.Text += '    ' + $note }

$body = New-Object Windows.Forms.TableLayoutPanel; $body.Dock = 'Fill'; $body.ColumnCount = 2; $body.RowCount = 1; $body.Margin = New-Object Windows.Forms.Padding 0
$body.Padding = New-Object Windows.Forms.Padding((Px 16), (Px 14), (Px 16), (Px 4))
[void]$body.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 40))); [void]$body.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 60)))
[void]$body.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100)))
$root.Controls.Add($body, 0, 1)
# 1.6.1 (YKW Elm, 1024x768): on a narrow window the job buttons get more room (left 48 %) so captions are not cut
$TK.body = $body
$body.Add_SizeChanged({ $lp = $(if ($TK.body.ClientSize.Width -lt (Px 1180)) { 48 } else { 40 }); if ([int]$TK.body.ColumnStyles[0].Width -ne $lp) { $TK.body.ColumnStyles[0].Width = $lp; $TK.body.ColumnStyles[1].Width = 100 - $lp } })

# left: the 8 jobs, in job order, then the 4 recorder-health checks (2 x 2)
$left = New-Object Windows.Forms.TableLayoutPanel; $left.Dock = 'Fill'; $left.ColumnCount = 1; $left.RowCount = 11; $left.Margin = New-Object Windows.Forms.Padding(0, 0, (Px 8), 0)
[void]$left.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize')))
for ($i = 0; $i -lt 8; $i++) { [void]$left.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 10))) }
[void]$left.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize'))); [void]$left.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 20)))
$TK.fixOn = (Test-Path (Join-Path $TK.P.Toolkit 'FixIt.ps1'))   # Release C (1.6.0) fix buttons; absent in 1.5.0
# Nov 3 2026: caption, then "Check this site" full width, then Camera doctor + Fix what failed side by side (fits 1024x768)
$topRow = New-Object Windows.Forms.TableLayoutPanel; $topRow.Dock = 'Fill'; $topRow.AutoSize = $true; $topRow.ColumnCount = 2; $topRow.RowCount = 3; $topRow.Margin = New-Object Windows.Forms.Padding 0
foreach ($pc in 50, 50) { [void]$topRow.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', $pc))) }
foreach ($r0 in 1..3) { [void]$topRow.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize'))) }
$caps0 = New-Caps 'Jobs  -  usual order 1, 2, 3, 6'; $caps0.Anchor = 'Left, Bottom'; $topRow.Controls.Add($caps0, 0, 0); $topRow.SetColumnSpan($caps0, 2)
$scBtn = Set-Glyph (Set-Primary (New-Btn 'Check this site (read-only)' { Do-SiteCheck }) $cBrand) ([string][char]0xE9D5)
$scBtn.Dock = 'Fill'; $scBtn.Font = $fBtn; $scBtn.Margin = New-Object Windows.Forms.Padding(0, (Px 2), 0, (Px 2)); $TK.scBtn = $scBtn
$topRow.Controls.Add($scBtn, 0, 1); $topRow.SetColumnSpan($scBtn, 2)
$docBtn = Set-Glyph (New-Btn 'Camera doctor' { Do-Doctor }) ([string][char]0xE9D9)
$docBtn.Dock = 'Fill'; $docBtn.Font = $fBtn; $docBtn.Margin = New-Object Windows.Forms.Padding(0, (Px 2), (Px 3), (Px 4)); $TK.docBtn = $docBtn
$topRow.Controls.Add($docBtn, 0, 2)
if ($TK.fixOn) {
  $fixBtn = Set-Glyph (New-Btn 'Fix what failed' { Do-FixMenu }) ([string][char]0xE90F)
  $fixBtn.Dock = 'Fill'; $fixBtn.Font = $fBtn; $fixBtn.Margin = New-Object Windows.Forms.Padding((Px 3), (Px 2), 0, (Px 4)); $TK.fixBtn = $fixBtn
  $topRow.Controls.Add($fixBtn, 1, 2)
} else { $topRow.SetColumnSpan($docBtn, 2) }
$left.Controls.Add($topRow, 0, 0)
$jobs = @(
  @('1   Find cameras', 'Read-only. Lists every Hikvision / Uniview camera and NVR, even on another IP scheme.', { Do-Find }, $cBlue, 0xE721, 'Every camera and NVR, even on another IP scheme.'),
  @('2   Check NVR', 'Read-only. Shows what is wrong (IP scheme, DNS, app access) and the fix plan.', { Do-Check }, $cTeal, 0xE9D9, 'Shows what is wrong and the fix plan.'),
  @('3   Fix NVR', 'Shows the plan, then fixes it after you type YES. Can be undone with 7.', { Do-Fix }, $cAmber, 0xE90F, 'Shows the plan, fixes it after you type YES.'),
  @('4   Reset passwords (Hikvision)', 'Unknown password: reset file, Hikvision form, new password.', { Show-ResetWindow }, $cBrand, 0xE8D7, 'Unknown password: reset file, Hikvision form, new password.'),
  @('5   Network check', 'Read-only. Cable speed, errors, ping every device.', { Do-Net }, $cIndigo, 0xE839, 'Cable speed, errors, ping every device.'),
  @('6   Save install snapshot', 'Install day: saves a known-good record (no passwords).', { Do-Snapshot }, $cGreen, 0xE74E, 'Install day: a known-good record (no passwords).'),
  @('7   Undo last fix', 'Puts the NVR and cameras back the way the last Fix found them.', { Do-Undo }, $cSlate, 0xE7A7, 'Puts everything back the way the last Fix found it.'),
  @('8   Save camera pictures', 'Read-only. One picture of every camera for the site page, so a camera that goes down shows where it is. Also runs at the end of 3 and 6.', { Do-Pics }, $cTeal, 0xE722, 'One picture per camera for the site page.')
)
$health = @(
  @('9   Recording check', 'Read-only. Every camera recording? Days of footage kept vs. the site''s target (YKW 45, others 30 - set in config.json). Hard drives and their health.', { Do-Nvr 'Recording' }, $cIndigo, 0xE714, 'Recording, days kept, drive health.'),
  @('10   Clock check', 'Read-only. Recorder and camera clocks vs. real time, time server, US Eastern + daylight saving.', { Do-Nvr 'Clock' }, $cTeal, 0xE823, 'Clocks, time server, time zone.'),
  @('11   Fix clock (NTP)', 'Sets the time server + US Eastern on the recorder (and cameras). Shows the plan first; changes nothing until you type YES.', { Do-Nvr 'FixClock' }, $cAmber, 0xE916, 'Plan first, changes after you type YES.'),
  @('12   Firmware check', 'Read-only. Security check: firmware vs. the newest published and known security holes. Reports only, never updates.', { Do-Nvr 'Firmware' }, $cBrand, 0xEA18, 'Newest firmware + known holes. Reports only.')
)
$tips = New-Object Windows.Forms.ToolTip
$TK.buttons = @()
$tips.SetToolTip($scBtn, 'One button, read-only: finds the cameras and compares them with the site list, router (UPnP / open ports), recording + streams, clocks, firmware. Writes ONE "Latest check" on the site page. Never fixes anything by itself.')
$TK.buttons += $scBtn
$tips.SetToolTip($docBtn, 'One camera that is offline: ping, MAC, ports, web page, ONE login try, video port, and what DW says. Plain verdict and which fix applies. Changes nothing.')
$TK.buttons += $docBtn
if ($TK.fixOn) { $tips.SetToolTip($fixBtn, 'Fixes only what the last Check this site / Camera doctor found. Each fix shows its plan, saves a backup, and needs YES. Not yet tested on real equipment.'); $TK.buttons += $fixBtn }
function New-JobCard($j) {
  $num = ($j[0] -split '\s+')[0]; $name = ($j[0] -replace '^\d+\s+', '')
  if ($TK_UI) {
    $b = New-Object WireItUi.Card; $b.Text = $j[0]; $b.Num = $num; $b.Title = $name; $b.Accent = $j[3]
    if ([string]$j[1] -like 'Read-only. *') { $b.Tag2 = 'READ-ONLY' }; $b.Sub = [string]$j[5]
    $b.TitleFont = $fBtn; $b.SubFont = $fSmall; $b.NumFont = Fnt 8 $semi; $b.TagFont = Fnt 7 $semi
    if ($TK.icons) { $b.GlyphFont = Ico 15; $b.Glyph = [string][char]$j[4]; $b.ChevFont = Ico 9 }
  } else {
    $b = New-Object Windows.Forms.Button; $b.Text = $j[0]; $b.Font = $fBtn; $b.TextAlign = 'MiddleLeft'; $b.Padding = New-Object Windows.Forms.Padding((Px 10), 0, 0, 0)
    $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderColor = $j[3]; $b.BackColor = [Drawing.Color]::White; $b.ForeColor = $j[3]
  }
  $b.Dock = 'Fill'; $b.Margin = New-Object Windows.Forms.Padding(0, (Px 3), 0, (Px 5))
  $b.Add_Click($j[2]); $tips.SetToolTip($b, $j[1])
  $TK.buttons += $b
  return $b
}
$row = 1
foreach ($j in $jobs) { $left.Controls.Add((New-JobCard $j), 0, $row); $row++ }
$left.Controls.Add((New-Caps 'Recorder health  -  only 11 changes anything, after you type YES'), 0, $row); $row++
$hgrid = New-Object Windows.Forms.TableLayoutPanel; $hgrid.Dock = 'Fill'; $hgrid.ColumnCount = 2; $hgrid.RowCount = 2; $hgrid.Margin = New-Object Windows.Forms.Padding 0
[void]$hgrid.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 50))); [void]$hgrid.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 50)))
[void]$hgrid.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 50))); [void]$hgrid.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 50)))
for ($k = 0; $k -lt $health.Count; $k++) {
  $hb = New-JobCard $health[$k]
  $hb.Margin = New-Object Windows.Forms.Padding($(if ($k % 2) { (Px 4) } else { 0 }), (Px 3), $(if ($k % 2) { 0 } else { (Px 4) }), (Px 5))
  $hgrid.Controls.Add($hb, ($k % 2), [math]::Floor($k / 2))
}
$left.Controls.Add($hgrid, 0, $row)
$body.Controls.Add($left, 0, 0)

# right: job options on top, results below
$right = New-Object Windows.Forms.TableLayoutPanel; $right.Dock = 'Fill'; $right.ColumnCount = 1; $right.RowCount = 3; $right.Margin = New-Object Windows.Forms.Padding((Px 8), 0, 0, 0)
[void]$right.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize'))); [void]$right.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', (Px 110)))); [void]$right.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100)))
$right.Controls.Add((New-Caps 'Job options'), 0, 0)
$optCard = New-Round; $optCard.Dock = 'Fill'; $optCard.Padding = New-Object Windows.Forms.Padding((Px 16), (Px 10), (Px 16), (Px 8)); $optCard.Margin = New-Object Windows.Forms.Padding(0, (Px 3), 0, (Px 12))
$opt = New-Object Windows.Forms.TableLayoutPanel; $opt.ColumnCount = 2; $opt.RowCount = 3; $opt.Dock = 'Fill'; $opt.Margin = New-Object Windows.Forms.Padding 0
[void]$opt.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize'))); [void]$opt.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize'))); [void]$opt.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100)))
[void]$opt.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('AutoSize'))); [void]$opt.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
# Nov 3 2026 (Moshe on the Dell: "it says site, and then optional ... what does that mean?"): plain labels, Bitwarden under Advanced
$l1 = New-Object Windows.Forms.Label; $l1.Text = 'Site ID or address:'; $l1.AutoSize = $true; $l1.Anchor = 'Left'; $l1.Font = $fBold; $l1.ForeColor = $cInk; $l1.Margin = New-Object Windows.Forms.Padding(0, 0, (Px 4), 0); $opt.Controls.Add($l1, 0, 0); $TK.l1 = $l1
$site = New-Object Windows.Forms.TextBox; $site.Anchor = 'Left, Right'; $site.Font = Fnt 10.5; $site.BorderStyle = 'FixedSingle'; $site.Margin = New-Object Windows.Forms.Padding((Px 6), (Px 4), 0, (Px 2)); $TK.site = $site; $opt.Controls.Add($site, 1, 0)
$tips.SetToolTip($site, 'The Site ID on the QR sticker (e.g. WI-061) or the address / site folder name (e.g. 2336 Main St). Find cameras saves its camera list to that site''s page; Check / Fix NVR, the install snapshot and camera pictures use it too. Leave it blank to keep everything on this PC only.')
$hint = New-Object Windows.Forms.Label; $hint.Text = 'e.g. WI-061 or 2336 Main St. Saves the camera list and results to that site''s page.'
$hint.AutoSize = $false; $hint.AutoEllipsis = $true; $hint.Dock = 'Fill'; $hint.Font = $fSmall; $hint.ForeColor = $cMuted; $hint.Height = [int]([math]::Ceiling($fSmall.GetHeight() * 1.3)); $hint.Margin = New-Object Windows.Forms.Padding((Px 6), 0, 0, 0)
$opt.Controls.Add($hint, 1, 1); $tips.SetToolTip($hint, $tips.GetToolTip($site)); $TK.hint = $hint
$pwRow = New-Object Windows.Forms.FlowLayoutPanel; $pwRow.AutoSize = $true; $pwRow.WrapContents = $true; $pwRow.Dock = 'Fill'; $pwRow.Margin = New-Object Windows.Forms.Padding(0, (Px 6), 0, 0)
$lone = New-Object Windows.Forms.CheckBox; $lone.Text = 'Also fix cameras plugged into the switch that aren''t added to the NVR'; $lone.AutoSize = $true; $lone.ForeColor = $cInk; $lone.Margin = New-Object Windows.Forms.Padding(0, (Px 2), (Px 18), (Px 2)); $TK.lone = $lone
$tips.SetToolTip($lone, 'For 3 Fix NVR: also move cameras that are on the network but not on the NVR''s camera list to the new address scheme.')
# passwords: typed when asked (hidden) is the normal way; a Bitwarden export file is tucked under Advanced
$adv = New-Object Windows.Forms.LinkLabel; $adv.Text = 'Advanced...'; $adv.AutoSize = $true; $adv.LinkColor = $cMuted; $adv.ActiveLinkColor = $cBlue; $adv.Margin = New-Object Windows.Forms.Padding(0, (Px 4), 0, (Px 2)); $TK.adv = $adv
$advMenu = New-Object Windows.Forms.ContextMenuStrip; $TK.advMenu = $advMenu
$miBw = $advMenu.Items.Add('Read NVR passwords from a Bitwarden export file...'); $miType = $advMenu.Items.Add('Type passwords when asked (normal)')
$miBw.Add_Click({
  $o = New-Object Windows.Forms.OpenFileDialog; $o.Filter = 'Bitwarden export (*.json)|*.json'; $o.Title = 'Pick the Bitwarden export (.json, unencrypted)'
  if ($o.ShowDialog($TK.form) -eq 'OK') { $TK.bw = $o.FileName; $TK.adv.Text = 'Advanced: passwords from ' + [IO.Path]::GetFileName($o.FileName) + ' (delete it when done)' }
})
$miType.Add_Click({ $TK.bw = ''; $TK.adv.Text = 'Advanced...' })
$adv.Add_LinkClicked({ $TK.advMenu.Show($TK.adv, (New-Object Drawing.Point(0, $TK.adv.Height))) })
$tips.SetToolTip($adv, 'Passwords are typed when a tool asks (hidden, never saved). Advanced: read them from a Bitwarden export file instead.')
$pwRow.Controls.AddRange(@($lone, $adv)); $opt.Controls.Add($pwRow, 0, 2); $opt.SetColumnSpan($pwRow, 2)
$optCard.Controls.Add($opt)
$right.Controls.Add($optCard, 0, 1)

$resCard = New-Round; $resCard.Dock = 'Fill'; $resCard.Padding = New-Object Windows.Forms.Padding((Px 16), (Px 12), (Px 16), (Px 12)); $resCard.Margin = New-Object Windows.Forms.Padding(0, 0, 0, (Px 4))
$res = New-Object Windows.Forms.TableLayoutPanel; $res.Dock = 'Fill'; $res.ColumnCount = 2; $res.RowCount = 3; $res.Margin = New-Object Windows.Forms.Padding 0
[void]$res.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('AutoSize'))); [void]$res.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
[void]$res.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize'))); [void]$res.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100))); [void]$res.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize')))
$rt = New-Object Windows.Forms.Label; $rt.Text = 'Results'; $rt.Font = $fBig; $rt.ForeColor = $cInk; $rt.AutoSize = $true; $rt.Anchor = 'Left'; $rt.Margin = New-Object Windows.Forms.Padding(0, 0, (Px 12), (Px 6)); $res.Controls.Add($rt, 0, 0)
$pill = New-Pill; $pill.Anchor = 'Left'; $pill.Margin = New-Object Windows.Forms.Padding(0, 0, 0, (Px 6)); $TK.pill = $pill; $res.Controls.Add($pill, 1, 0)
$out = New-Object Windows.Forms.RichTextBox; $out.ReadOnly = $true; $out.ScrollBars = 'Vertical'; $out.WordWrap = $true; $out.Font = $fMono; $out.BorderStyle = 'None'; $out.DetectUrls = $false
$out.BackColor = [Drawing.Color]::White; $out.ForeColor = $cInk; $out.Dock = 'Fill'; $out.Margin = New-Object Windows.Forms.Padding(0, (Px 2), 0, (Px 8))
$TK.out = $out; $res.Controls.Add($out, 0, 1); $res.SetColumnSpan($out, 2)
$rb = New-Object Windows.Forms.FlowLayoutPanel; $rb.AutoSize = $true; $rb.WrapContents = $false; $rb.Dock = 'Fill'; $rb.Margin = New-Object Windows.Forms.Padding 0
$rb.Controls.Add((Set-Glyph (Set-Primary (New-Btn 'Copy results' { Set-Clip ($TK.out.Text -replace "\r?\n", "`r`n") 'the results' }) $cInk) ([string][char]0xE8C8)))
$rb.Controls.Add((Set-Glyph (New-Btn 'Open logs folder' { New-Item -ItemType Directory -Force -Path $TK.P.Logs | Out-Null; Start-Process explorer.exe (Q $TK.P.Logs) }) ([string][char]0xE838)))
$rb.Controls.Add((Set-Glyph (New-Btn 'Restore network' { Do-RestoreNet }) ([string][char]0xE777)))   # 2.2.11 (#3)
$res.Controls.Add($rb, 0, 2); $res.SetColumnSpan($rb, 2)
$resCard.Controls.Add($res)
$right.Controls.Add($resCard, 0, 2)
$body.Controls.Add($right, 1, 0)
function Fit-Options {
  $w = [math]::Max(100, $TK.opt.ClientSize.Width)
  # 1.6.1: the long checkbox caption wraps onto 2 lines on a narrow window instead of being cut (1024x768)
  $lw = [math]::Max((Px 160), $w - (Px 24)); $one = $TK.lone.GetPreferredSize((New-Object Drawing.Size(0, 0)))
  if ($one.Width -le $lw) { $lsz = $one } else { $th = [Windows.Forms.TextRenderer]::MeasureText($TK.lone.Text, $TK.lone.Font, (New-Object Drawing.Size(($lw - (Px 22)), 0)), [Windows.Forms.TextFormatFlags]::WordBreak).Height; $lsz = New-Object Drawing.Size($lw, ([math]::Max($one.Height, $th + (Px 6)))) }
  if ($TK.lone.AutoSize) { $TK.lone.AutoSize = $false }; if ($TK.lone.Size -ne $lsz) { $TK.lone.Size = $lsz }
  $line = [math]::Max($TK.lone.Height, $TK.adv.PreferredSize.Height) + (Px 4)
  $pw = [math]::Max($line, $TK.pwRow.GetPreferredSize((New-Object Drawing.Size($w, 0))).Height)
  $h = $TK.site.PreferredHeight + $TK.site.Margin.Vertical + $TK.hint.Height + $TK.hint.Margin.Vertical + $TK.pwRow.Margin.Vertical + $pw + $TK.optCard.Padding.Vertical + $TK.optCard.Margin.Vertical
  $rsy = $TK.right.RowStyles[1]; if ([int]$rsy.Height -ne $h) { $rsy.Height = $h; $TK.right.PerformLayout() }
}
$TK.optCard = $optCard; $TK.opt = $opt; $TK.right = $right; $TK.pwRow = $pwRow
$optCard.Add_SizeChanged({ Fit-Options })

# footer: status line + going back to the previous version
$foot = New-Object Windows.Forms.TableLayoutPanel; $foot.ColumnCount = 2; $foot.RowCount = 1; $foot.AutoSize = $true; $foot.Dock = 'Fill'; $foot.Margin = New-Object Windows.Forms.Padding 0
$foot.Padding = New-Object Windows.Forms.Padding((Px 18), 0, (Px 16), (Px 8))
[void]$foot.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100))); [void]$foot.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('AutoSize')))
$status = New-Object Windows.Forms.Label; $status.AutoSize = $true; $status.Anchor = 'Left'; $status.ForeColor = $cMuted; $status.Margin = New-Object Windows.Forms.Padding 0; $TK.status = $status
$foot.Controls.Add($status, 0, 0)
$back = New-Btn 'Go back to the previous version' {
  if ([Windows.Forms.MessageBox]::Show($TK.form, 'Go back to the Toolkit version that was installed before the last update?', 'WireIt Toolkit', 'YesNo', 'Question') -ne 'Yes') { return }
  try { if (Test-TkCanWrite $here) { $v = Undo-TkUpdate $here } else { throw $script:TkNoWriteMsg }; [void][Windows.Forms.MessageBox]::Show($TK.form, ('Back on version ' + $v + '. The Toolkit will close; open it again.'), 'WireIt Toolkit'); $TK.form.Close() }
  catch { [void][Windows.Forms.MessageBox]::Show($TK.form, $_.Exception.Message, 'WireIt Toolkit') } }
$back.Font = $fSmall; $back.MinimumSize = New-Object Drawing.Size((Px 60), (Px 30)); if ($TK_UI) { $back.TextColor = $cMuted; $back.Accent = $cSlate; $back = Set-Glyph $back ([string][char]0xE777); $back.GlyphFont = Ico 8.5 }
$back.Margin = New-Object Windows.Forms.Padding 0; $foot.Controls.Add($back, 1, 0)
$root.Controls.Add($foot, 0, 2)
Fit-Options

Add-Out 'Pick a job on the left. Results show here in plain words, and every run is saved in the logs folder.' $cInk
Add-Out ''
Add-Out 'New: Check this site (top) - one read-only run: cameras vs. the site list, router, recording, clocks, firmware, DW offline cameras.' $cInk
Add-Out 'Camera doctor: one offline camera step by step, with a plain verdict.' $cMuted
Add-Out ''
Add-Out 'Usual order on a site:' $cInk
Add-Out '  1 Find cameras  >  2 Check NVR  >  3 Fix NVR (type YES)  >  6 Save install snapshot' $cBlue
Add-Out '  Type the Site ID or address first: Find cameras then saves its camera list to the site page and flags any camera missing since the last scan.' $cMuted
Add-Out '  Unknown password?  4 Reset passwords.   Slow or dropping video?  5 Network check.   Fix went wrong?  7 Undo last fix.' $cMuted
Add-Out '  8 Save camera pictures: the site page shows each camera''s last picture (3 and 6 take them too when the Site box is filled).' $cMuted
Add-Out ''
Add-Out 'Plug this PC into the same switch as the NVR and cameras first. Cable is better than Wi-Fi.' $cInk
Add-Out 'Hikvision reply email arrived? Drag its file onto this window.' $cInk
Set-Pill 'Ready' $cSlate
Set-Status ('Ready. ' + $env:COMPUTERNAME)

$form.Add_DragEnter({ if ($_.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) { $_.Effect = 'Copy' } })
$form.Add_DragDrop({ $files = $_.Data.GetData([Windows.Forms.DataFormats]::FileDrop); if ($files) { $p = [string]$files[0]; if ($p -match '(?i)\.json$') { [void][Windows.Forms.MessageBox]::Show($TK.form, 'That looks like a settings/Bitwarden file, not a Hikvision reply. For Bitwarden use Advanced... under Job options.', 'WireIt Toolkit') } else { Show-ResetWindow $p } } })
$timer = New-Object Windows.Forms.Timer; $timer.Interval = 400
$timer.Add_Tick({ try { Poll-Run; Watch-Export; Poll-RsRelay } catch { Set-Status ('(' + $_.Exception.Message + ')') } })
$form.Add_FormClosing({
  if ($TK.run -and $TK.run.Kind -eq 'console') { [void][Windows.Forms.MessageBox]::Show($TK.form, 'A Fix NVR tool window is still open. Finish it there first; its log is saved in C:\WireIt\FixNVR\runs.', 'WireIt Toolkit') }
  if ($TK.bw -and (Test-Path -LiteralPath $TK.bw)) {
    if ([Windows.Forms.MessageBox]::Show($TK.form, ('Delete the Bitwarden export file now? It holds passwords unencrypted:' + "`r`n" + $TK.bw), 'WireIt Toolkit', 'YesNo', 'Warning') -eq 'Yes') { Remove-Item -LiteralPath $TK.bw -Force -ErrorAction SilentlyContinue }
  }
})

if ($Screenshot) {
  # The SSH test session has a small virtual screen that would squeeze the window, so the window's
  # contents are drawn at the size they get on the real screen (no window shows on the desktop).
  New-Item -ItemType Directory -Force -Path $Screenshot | Out-Null
  function Save-Shot($ctl, [string]$path, $rtb = $null) {
    $bmp = New-Object Drawing.Bitmap($ctl.Width, $ctl.Height)
    $ctl.DrawToBitmap($bmp, (New-Object Drawing.Rectangle(0, 0, $ctl.Width, $ctl.Height)))
    if ($TK_UI -and $rtb) {
      # DrawToBitmap leaves a RichTextBox blank, so print its text into the picture
      $o = $ctl.PointToScreen([Drawing.Point]::Empty); $p = $rtb.PointToScreen([Drawing.Point]::Empty)
      [WireItUi.Gfx]::PrintRtb($rtb, $bmp, (New-Object Drawing.Rectangle(($p.X - $o.X), ($p.Y - $o.Y), ($rtb.ClientSize.Width - [Windows.Forms.SystemInformation]::VerticalScrollBarWidth), $rtb.ClientSize.Height)))
    }
    $bmp.Save($path, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
  }
  $form.StartPosition = 'Manual'; $form.Location = New-Object Drawing.Point(-20000, -20000); $form.ShowInTaskbar = $false
  $form.Show(); [Windows.Forms.Application]::DoEvents()
  $cs = New-Object Drawing.Size(($TK.want.Width - ($form.Width - $form.ClientSize.Width)), ($TK.want.Height - ($form.Height - $form.ClientSize.Height)))
  if ($SimScreen) { $hostP.Dock = 'None'; $hostP.Location = New-Object Drawing.Point(0, 0); $hostP.Size = $cs; [Windows.Forms.Application]::DoEvents() }
  else { $root.Dock = 'None'; $root.Location = New-Object Drawing.Point(0, 0); $root.Size = $cs }
  $TK.out.Clear()
  Add-Out ('=== Find cameras - ' + (Get-Date -Format 'ddd MMM d, h:mm tt') + ' (demo) ===')
  Add-Out 'Looking for Hikvision and Uniview devices on every network this PC is plugged into (read-only)...'
  Add-Out 'Hikvision  DS-7616NI-Q2/16P  NVR     serial F12345678  192.168.1.250  (different IP scheme)'
  Add-Out 'Hikvision  DS-2CD2143G2-I    camera  serial J12345678  192.168.1.64   (different IP scheme)'
  Add-Out 'Hikvision  DS-2CD2143G2-I    camera  serial J12345679  192.168.1.65   (different IP scheme)'
  Add-Out ''
  Add-Out 'In short: 3 device(s) found - 3 Hikvision, 0 Uniview; 3 on a different IP scheme (button 3 Fix NVR moves them).'
  Add-Out 'Find cameras: finished.'
  $TK.site.Text = '2336 Main St'
  Add-Out ''; Add-Out 'Saving the camera list (3 devices, no passwords) to the site page for "2336 Main St"...'
  Add-Out '!! MISSING since last scan: Camera DS-2CD2143G2-I 192.168.1.66 44:19:B6:00:01:03'
  Add-Out 'Saved to the site page: 2336 Main St (WI-064), 4 devices.'
  Add-OutTop @('MISSING since last scan: Camera DS-2CD2143G2-I 192.168.1.66 44:19:B6:00:01:03') $cRed
  Set-Pill 'Find cameras - done' $cOk; Set-Status 'Find cameras done. Saved to the logs folder.'
  [Windows.Forms.Application]::DoEvents(); Fit-Options; [Windows.Forms.Application]::DoEvents()
  if ($SimScreen) { Save-Shot $hostP (Join-Path $Screenshot 'toolkit-small.png') $TK.out } else { Save-Shot $root (Join-Path $Screenshot 'toolkit-main.png') $TK.out }
  # 1.6.1: every caption must fit (the 1024x768 YKW Elm test showed "Fix what faile", "Recording ch...")
  $script:clipN = @(); function Find-Clipped($c) { foreach ($x in $c.Controls) { if ($x.Visible -and $x.PSObject.Properties['Clipped'] -and $x.Clipped) { $script:clipN += $(if ($x.PSObject.Properties['Title'] -and $x.Title) { $x.Title } else { $x.Text }) }; Find-Clipped $x } }
  if ($TK_UI) { Find-Clipped $root; Write-Output ('clipped=' + $script:clipN.Count + $(if ($script:clipN.Count) { ' ' + ($script:clipN -join ' | ') } else { '' })) }
  $rf = @(Show-ResetWindow)[-1]
  $rf.StartPosition = 'Manual'; $rf.Location = New-Object Drawing.Point(-20000, -20000); $rf.ShowInTaskbar = $false
  $rf.Show(); [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 300; [Windows.Forms.Application]::DoEvents()
  $hp = $TK.rs.host; $hp.Dock = 'None'; $hp.Location = New-Object Drawing.Point(0, 0); $hp.Size = $TK.rs.client; [Windows.Forms.Application]::DoEvents()
  if ($TK.rs.list.Items.Count) { $TK.rs.list.Items[0].Selected = $true; [Windows.Forms.Application]::DoEvents() }
  $TK.rs.pw = New-TkPassword 14; $TK.rs.pwBox.Text = 'Xy7#demo-only'; $TK.rs.pwBox.Visible = $true
  $TK.rs.replyLbl.Text = 'Reply file saved for DS-7608NI-K2/8P (serial J12345678), matched by serial. About 41.5 h left to use it.'; $TK.rs.replyLbl.ForeColor = $cOk
  [Windows.Forms.Application]::DoEvents()
  # what the tech sees first (normal window size)
  Save-Shot $hp (Join-Path $Screenshot 'toolkit-reset.png')
  # the whole screen, top to bottom
  $need = $TK.rs.flow.GetPreferredSize((New-Object Drawing.Size($TK.rs.flow.ClientSize.Width, 0))).Height + $TK.rs.head.Height
  $hp.Size = New-Object Drawing.Size($TK.rs.client.Width, [math]::Max($TK.rs.client.Height, $need)); [Windows.Forms.Application]::DoEvents()
  Save-Shot $hp (Join-Path $Screenshot 'toolkit-reset-2.png')
  $TK.rs.watch = $false; $rf.Close()
  # Nov 3 2026 checks: the plain option labels, no password radio buttons on the main window, a 1-field dialog = 1 box
  $script:radioN = 0; function Count-Radios($c) { foreach ($x in $c.Controls) { if ($x -is [Windows.Forms.RadioButton] -and $x.Visible) { $script:radioN++ }; Count-Radios $x } }; Count-Radios $TK.opt
  Write-Output ('label site=' + $TK.l1.Text); Write-Output ('label hint=' + $TK.hint.Text); Write-Output ('label lone=' + $TK.lone.Text); Write-Output ('label advanced=' + $TK.adv.Text + ' items=' + (@($TK.advMenu.Items | ForEach-Object { $_.Text }) -join ' | '))
  Write-Output ('main radios=' + $script:radioN)
  $af1 = New-AskForm 'Save camera pictures' 'Type the Site ID (e.g. WI-061) or the site folder name.' @(@('site', 'Site ID or address:', 'WI-061'))
  $tl = $af1.form.Controls[0]; $lbls = @($tl.Controls | Where-Object { $_ -is [Windows.Forms.Label] } | Select-Object -Skip 1 | ForEach-Object { $_.Text })
  Write-Output ('ask1 boxes=' + @($tl.Controls | Where-Object { $_ -is [Windows.Forms.TextBox] }).Count + ' labels=' + ($lbls -join '|') + ' value=' + $af1.boxes['site'].Text)
  $af1.form.StartPosition = 'Manual'; $af1.form.Location = New-Object Drawing.Point(-20000, -20000); $af1.form.ShowInTaskbar = $false; $af1.form.Show(); [Windows.Forms.Application]::DoEvents()
  Save-Shot $af1.form (Join-Path $Screenshot 'toolkit-ask-site.png'); $af1.form.Close()
  $form.Close()
  Write-Output ('screenshots saved in ' + $Screenshot + '; buttons=' + $TK.buttons.Count + '; resetFields=' + $TK.rs.fieldBtns.Count + '; look=' + $(if ($TK_UI) { 'new' } else { 'plain' }) + '; icons=' + $TK.icons + '; scale=' + $TK.scale + '; scroll=' + $(if ($hostP.VerticalScroll.Visible -or $hostP.HorizontalScroll.Visible) { 'yes' } else { 'no' }))
  exit 0
}
$timer.Start()
[void]$form.ShowDialog()
$timer.Stop()
if ($TK.mutex) { try { $TK.mutex.ReleaseMutex() } catch {} }
