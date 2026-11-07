# Makes the download page's images (site/) from the PRM logo:
#
#   logo.jpg     the page's logo, 1120 wide (sharp on a 2x screen at 560)
#   og.jpg       the link preview, 1200x630, the size Discord and others crop
#                to: the logo full height, its sides faded into its own colours
#   favicon.png  the tab icon: the phoenix alone, as in the installer's icon
#
# The images are committed; run this again only when the logo changes. Give it
# the full-size logo: splash.png, the fallback, is small and quantized.
#
#   pwsh tools/site-images.ps1 -Logo C:\path\to\PhoenixRaceManager.png
param([string]$Logo = (Join-Path $PSScriptRoot '..\ui\modules\apps\RaceManager\splash.png'))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$out = (Resolve-Path (Join-Path $PSScriptRoot '..\site')).Path
$src = [System.Drawing.Image]::FromFile((Resolve-Path $Logo).Path)

function Canvas([int]$w, [int]$h) {
  $bmp = New-Object System.Drawing.Bitmap $w, $h, ([System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
  return $bmp, $g
}

function SaveJpeg($bmp, [string]$path, [int]$quality) {
  $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object MimeType -eq 'image/jpeg'
  $params = New-Object System.Drawing.Imaging.EncoderParameters 1
  $params.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter ([System.Drawing.Imaging.Encoder]::Quality), ([long]$quality)
  $bmp.Save($path, $codec, $params)
}

try {
  # The logo.
  $w = 1120; $h = [int][Math]::Round($src.Height * $w / $src.Width)
  $bmp, $g = Canvas $w $h
  $g.DrawImage($src, 0, 0, $w, $h); $g.Dispose()
  SaveJpeg $bmp (Join-Path $out 'logo.jpg') 86; $bmp.Dispose()

  # The preview. The logo is a rectangle with its own background, so it is
  # drawn full height and its two sides fade into a backdrop made of its own
  # edge colours, one band at a time: near black at the top, ember red below.
  $bmp, $g = Canvas 1200 630
  $lw = [int][Math]::Round($src.Width * 630 / $src.Height)
  $lx = [int]((1200 - $lw) / 2)
  $edge = New-Object System.Drawing.Bitmap $src
  $bands = 42
  $colors = for ($i = 0; $i -lt $bands; $i++) {
    $y = [int](($i + 0.5) * $edge.Height / $bands)
    $l = $edge.GetPixel(4, $y); $r = $edge.GetPixel($edge.Width - 5, $y)
    [System.Drawing.Color]::FromArgb([int](($l.R + $r.R) / 2), [int](($l.G + $r.G) / 2), [int](($l.B + $r.B) / 2))
  }
  $edge.Dispose()
  $bh = 630.0 / $bands
  for ($i = 0; $i -lt $bands; $i++) {
    $brush = New-Object System.Drawing.SolidBrush $colors[$i]
    $g.FillRectangle($brush, 0, [float]($i * $bh), 1200, [float]($bh + 1)); $brush.Dispose()
  }
  $g.DrawImage($src, $lx, 0, $lw, 630)
  $fade = 110
  for ($i = 0; $i -lt $bands; $i++) {
    $top = [float]($i * $bh); $c = $colors[$i]
    $clear = [System.Drawing.Color]::FromArgb(0, $c.R, $c.G, $c.B)
    $left = New-Object System.Drawing.Drawing2D.LinearGradientBrush (New-Object System.Drawing.PointF ($lx - 1), 0), (New-Object System.Drawing.PointF ($lx + $fade), 0), $c, $clear
    $g.FillRectangle($left, [float]$lx, $top, [float]$fade, [float]($bh + 1)); $left.Dispose()
    $right = New-Object System.Drawing.Drawing2D.LinearGradientBrush (New-Object System.Drawing.PointF ($lx + $lw + 1), 0), (New-Object System.Drawing.PointF ($lx + $lw - $fade), 0), $c, $clear
    $g.FillRectangle($right, [float]($lx + $lw - $fade), $top, [float]$fade, [float]($bh + 1)); $right.Dispose()
  }
  $g.Dispose()
  SaveJpeg $bmp (Join-Path $out 'og.jpg') 88; $bmp.Dispose()

  # The icon: the phoenix's body, the same crop as the installer's small sizes.
  $s = $src.Width / 640.0
  $bird = New-Object System.Drawing.Rectangle ([int](228 * $s)), ([int](150 * $s)), ([int](180 * $s)), ([int](180 * $s))
  $icon = New-Object System.Drawing.Bitmap 64, 64
  $ig = [System.Drawing.Graphics]::FromImage($icon)
  $ig.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $ig.DrawImage($src, (New-Object System.Drawing.Rectangle 0, 0, 64, 64), $bird, [System.Drawing.GraphicsUnit]::Pixel)
  $ig.Dispose()
  $icon.Save((Join-Path $out 'favicon.png'), [System.Drawing.Imaging.ImageFormat]::Png); $icon.Dispose()
} finally { $src.Dispose() }

Get-ChildItem $out -Include logo.jpg, og.jpg, favicon.png -Recurse |
  ForEach-Object { Write-Host ("{0,-12} {1,8:N0} bytes" -f $_.Name, $_.Length) }
