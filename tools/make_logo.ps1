# Draws the client’s logo: opencode’s "O" (a tall square ring, the lower half of its hole filled) machined on a dark
# tile: vertical gradients, lit top edges, dark lower edges, shadows; the filled half is the peach accent, glowing a little.
# Small sizes thicken the ring and drop the shadows (detail picked from the size).
#   powershell -File tools/make_logo.ps1 [-Out assets]
# Writes logo.png (512), logo_256/64/32/16.png and opencode-native.ico (16/20/24/32/40/48/64/128/256, PNG entries).
param([string]$Out = '')
if (-not $Out) { $Out = Join-Path (Split-Path $PSScriptRoot -Parent) 'assets' }
New-Item -ItemType Directory -Force $Out | Out-Null
Add-Type -AssemblyName System.Drawing
$SS = 4   # supersampling: drawn at size*SS, then scaled down

function Hex($v, $a = 255) { return [Drawing.Color]::FromArgb($a, ($v -shr 16) -band 255, ($v -shr 8) -band 255, $v -band 255) }
function RoundRect($x, $y, $w, $h, $r) {
  $p = New-Object Drawing.Drawing2D.GraphicsPath; $d = 2 * $r
  $p.AddArc([single]$x, [single]$y, [single]$d, [single]$d, 180, 90)
  $p.AddArc([single]($x + $w - $d), [single]$y, [single]$d, [single]$d, 270, 90)
  $p.AddArc([single]($x + $w - $d), [single]($y + $h - $d), [single]$d, [single]$d, 0, 90)
  $p.AddArc([single]$x, [single]($y + $h - $d), [single]$d, [single]$d, 90, 90); $p.CloseFigure(); return $p
}

function Draw($size) {
  $S = $size * $SS
  $bmp = New-Object Drawing.Bitmap $S, $S
  $g = [Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'; $g.Clear([Drawing.Color]::Transparent)
  $detail = if ($size -ge 48) { 2 } elseif ($size -ge 24) { 1 } else { 0 }
  $u = $S / 64.0   # drawing units: a 64 x 64 grid

  # the tile
  $m = if ($detail -eq 0) { 1 * $u } else { 3 * $u }
  $r = 13 * $u
  $tile = RoundRect $m $m ($S - 2 * $m) ($S - 2 * $m) $r
  $grad = New-Object Drawing.Drawing2D.LinearGradientBrush((New-Object Drawing.PointF 0, $m), (New-Object Drawing.PointF 0, ($S - $m)), (Hex 0x303030), (Hex 0x0e0e0e))
  $g.FillPath($grad, $tile)
  if ($detail -ge 1) {
    # lit rim (top) fading to nothing (bottom)
    $rim = RoundRect ($m + 1.2 * $u) ($m + 1.2 * $u) ($S - 2 * $m - 2.4 * $u) ($S - 2 * $m - 2.4 * $u) ($r - 1.2 * $u)
    $rb = New-Object Drawing.Drawing2D.LinearGradientBrush((New-Object Drawing.PointF 0, $m), (New-Object Drawing.PointF 0, ($S * 0.7)), (Hex 0xffffff 70), (Hex 0xffffff 0))
    $g.DrawPath((New-Object Drawing.Pen($rb, (1.4 * $u))), $rim)
  }
  $g.DrawPath((New-Object Drawing.Pen((Hex 0x000000 230), ([Math]::Max(1.6 * $u, $SS)))), $tile)

  # the mark: opencode’s "O", a tall square ring cut in whole cells, the lower half of its hole filled (here with the
  # peach accent, lit), the ring itself machined: light face, lit top edge, dark lower edge, a shadow under it
  $t = if ($detail -eq 0) { 9 } elseif ($detail -eq 1) { 8 } else { 7 }   # ring thickness, grid units
  $x0 = 15 * $u; $x1 = 49 * $u; $y0 = 10 * $u; $y1 = 54 * $u
  $hx0 = $x0 + $t * $u; $hx1 = $x1 - $t * $u; $hy0 = $y0 + $t * $u; $hy1 = $y1 - $t * $u
  $hmid = ($hy0 + $hy1) / 2
  $outer = New-Object Drawing.RectangleF $x0, $y0, ($x1 - $x0), ($y1 - $y0)
  $hole = New-Object Drawing.RectangleF $hx0, $hy0, ($hx1 - $hx0), ($hy1 - $hy0)
  $ring = New-Object Drawing.Drawing2D.GraphicsPath
  $ring.FillMode = "Alternate"
  $ring.AddRectangle($outer); $ring.AddRectangle($hole)
  # shadow under the ring
  if ($detail -ge 1) {
    foreach ($k in 3, 2, 1) {
      $sp = New-Object Drawing.Drawing2D.GraphicsPath; $sp.FillMode = "Alternate"
      $sp.AddRectangle((New-Object Drawing.RectangleF ($x0 - $k * 0.6 * $u), ($y0 + 1.5 * $u), ($x1 - $x0 + $k * 1.2 * $u), ($y1 - $y0 + $k * 0.8 * $u)))
      $g.FillPath((New-Object Drawing.SolidBrush (Hex 0x000000 (40 + 25 * (3 - $k)))), $sp)
    }
  }
  # the hole: dark above, the peach block below with its glow
  $g.FillRectangle((New-Object Drawing.SolidBrush (Hex 0x050505)), $hole)
  if ($detail -ge 1) {
    $ish = New-Object Drawing.Drawing2D.LinearGradientBrush((New-Object Drawing.PointF 0, $hy0), (New-Object Drawing.PointF 0, ($hy0 + 4 * $u)), (Hex 0x000000 230), (Hex 0x000000 0))
    $g.FillRectangle($ish, $hole)
  }
  $block = New-Object Drawing.RectangleF $hx0, $hmid, ($hx1 - $hx0), ($hy1 - $hmid)
  if ($detail -ge 1) {
    foreach ($k in 3, 2, 1) {
      $gl = New-Object Drawing.RectangleF ($hx0), ($hmid - $k * 1.2 * $u), ($hx1 - $hx0), ($hy1 - $hmid + $k * 1.2 * $u)
      $g.FillRectangle((New-Object Drawing.SolidBrush (Hex 0xfab283 (14 * (4 - $k)))), $gl)
    }
  }
  $bb = New-Object Drawing.Drawing2D.LinearGradientBrush((New-Object Drawing.PointF 0, $hmid), (New-Object Drawing.PointF 0, $hy1), (Hex 0xffc59e), (Hex 0xd9824e))
  $g.FillRectangle($bb, $block)
  if ($detail -ge 2) { $g.FillRectangle((New-Object Drawing.SolidBrush (Hex 0xffffff 110)), $hx0, $hmid, ($hx1 - $hx0), 0.9 * $u) }
  # the ring: light face
  $rb = New-Object Drawing.Drawing2D.LinearGradientBrush((New-Object Drawing.PointF 0, $y0), (New-Object Drawing.PointF 0, $y1), (Hex 0xf6f6f6), (Hex 0xa9a9a9))
  $g.FillPath($rb, $ring)
  if ($detail -ge 1) {
    $e = [Math]::Max(0.9 * $u, $SS)
    $g.FillRectangle((New-Object Drawing.SolidBrush (Hex 0xffffff 220)), $x0, $y0, ($x1 - $x0), $e)                # lit top edge
    $g.FillRectangle((New-Object Drawing.SolidBrush (Hex 0x000000 90)), $x0, ($y1 - $e), ($x1 - $x0), $e)         # dark lower edge
    $g.FillRectangle((New-Object Drawing.SolidBrush (Hex 0x000000 120)), $hx0, ($hy1), ($hx1 - $hx0), $e)         # the hole’s lower lip
    $g.FillRectangle((New-Object Drawing.SolidBrush (Hex 0x000000 160)), $hx0, ($hy0 - $e), ($hx1 - $hx0), $e)    # the hole’s upper cut
    $g.DrawRectangle((New-Object Drawing.Pen((Hex 0x000000 200), $e)), $x0, $y0, ($x1 - $x0), ($y1 - $y0))
  }
  $g.Dispose()

  $out = New-Object Drawing.Bitmap $size, $size
  $g2 = [Drawing.Graphics]::FromImage($out)
  $g2.InterpolationMode = 'HighQualityBicubic'; $g2.PixelOffsetMode = 'HighQuality'; $g2.CompositingQuality = 'HighQuality'
  $g2.DrawImage($bmp, 0, 0, $size, $size)
  $g2.Dispose(); $bmp.Dispose()
  return $out
}

function PngBytes($bmp) { $ms = New-Object IO.MemoryStream; $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png); return $ms.ToArray() }

foreach ($s in 512, 256, 64, 32, 16) {
  $b = Draw $s
  $name = if ($s -eq 512) { 'logo.png' } else { "logo_$s.png" }
  $b.Save((Join-Path $Out $name), [Drawing.Imaging.ImageFormat]::Png); $b.Dispose()
}

# the .ico: one PNG entry per size (Windows Vista and later read them; rc.exe embeds them as they are)
$sizes = 16, 20, 24, 32, 40, 48, 64, 128, 256
$pngs = New-Object 'System.Collections.Generic.List[byte[]]'
foreach ($s in $sizes) { $b = Draw $s; $pngs.Add([byte[]](PngBytes $b)); $b.Dispose() }
$ms = New-Object IO.MemoryStream
$bw = New-Object IO.BinaryWriter $ms
$bw.Write([UInt16]0); $bw.Write([UInt16]1); $bw.Write([UInt16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
  $s = $sizes[$i]; $d = $pngs[$i]
  $bw.Write([byte]($s % 256)); $bw.Write([byte]($s % 256)); $bw.Write([byte]0); $bw.Write([byte]0)
  $bw.Write([UInt16]1); $bw.Write([UInt16]32); $bw.Write([UInt32]$d.Length); $bw.Write([UInt32]$offset)
  $offset += $d.Length
}
foreach ($d in $pngs) { $bw.Write($d) }
[IO.File]::WriteAllBytes((Join-Path $Out 'opencode-native.ico'), $ms.ToArray())
"wrote $Out\opencode-native.ico and logo*.png"
