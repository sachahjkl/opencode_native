# Draws the client's logo: a bolt of brushed silver on a machined dark tile, with hints of the peach accent: vertical gradients, a lit
# rim, shadows. Small sizes drop the shadows (detail picked from the size).
#   powershell -File tools/make_logo.ps1 [-Out assets]
# Writes logo.png (512), logo_256/64/32/16.png and opencode-native.ico (16/20/24/32/40/48/64/128/256, PNG entries).
param([string]$Out = '', [int]$Hint = 1)   # (0: silver alone; 1: a peach edge; 2: and a warm tip)
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

  # the mark: a bolt of brushed silver, lit from above, with a warm edge of the peach accent where it would catch the light of the tile
  $pts = @(@(38, 8), @(17, 36), @(30, 36), @(26, 56), @(47, 27), @(34, 27))
  $bolt = New-Object Drawing.Drawing2D.GraphicsPath
  $poly = New-Object 'Drawing.PointF[]' $pts.Count
  for ($i = 0; $i -lt $pts.Count; $i++) { $poly[$i] = New-Object Drawing.PointF ($pts[$i][0] * $u), ($pts[$i][1] * $u) }
  $bolt.AddPolygon($poly)
  # its shadow on the tile, and the peach behind it
  if ($detail -ge 1) {
    foreach ($k in 3, 2, 1) {
      $sp = $bolt.Clone()
      $mt = New-Object Drawing.Drawing2D.Matrix; $mt.Translate(0, ($k * 0.8 * $u)); $sp.Transform($mt)
      $g.FillPath((New-Object Drawing.SolidBrush (Hex 0x000000 (40 + 25 * (3 - $k)))), $sp)
    }
  }
  if ($Hint -ge 1) {
    $sp = $bolt.Clone()
    $d = if ($detail -eq 0) { 2.2 } else { 1.6 }
    $mt = New-Object Drawing.Drawing2D.Matrix; $mt.Translate((-$d * $u), ($d * $u)); $sp.Transform($mt)
    $g.FillPath((New-Object Drawing.SolidBrush (Hex 0xe8935a)), $sp)
  }
  # the face: silver, turning warm at its tip
  $y0 = 8 * $u; $y1 = 56 * $u
  $face = New-Object Drawing.Drawing2D.LinearGradientBrush((New-Object Drawing.PointF 0, ($y0 - 1)), (New-Object Drawing.PointF 0, ($y1 + 1)), (Hex 0xffffff), (Hex 0xa9a9a9))
  $blend = New-Object Drawing.Drawing2D.ColorBlend 4
  $tip = if ($Hint -ge 2) { Hex 0xfab283 } else { Hex 0x9c9c9c }
  $blend.Colors = [Drawing.Color[]]@((Hex 0xffffff), (Hex 0xdcdcdc), (Hex 0xb4b4b4), $tip)
  $blend.Positions = [single[]]@(0, 0.45, 0.72, 1)
  $face.InterpolationColors = $blend
  $g.FillPath($face, $bolt)
  if ($detail -ge 1) {
    $e = [Math]::Max(0.7 * $u, $SS)
    $g.DrawPath((New-Object Drawing.Pen((Hex 0x000000 170), $e)), $bolt)
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
