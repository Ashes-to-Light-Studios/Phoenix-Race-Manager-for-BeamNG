# Makes prm.ico, the installer's icon, from the splash: the badge cropped
# square at the sizes Windows asks for. The .ico is committed; run this again
# only when the logo changes.
#
#   pwsh installer/windows/icon.ps1
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$src = [System.Drawing.Image]::FromFile((Resolve-Path (Join-Path $here '..\..\ui\modules\apps\RaceManager\splash.png')).Path)
try {
  # The whole badge at 256; below that its lettering turns to noise, so the
  # small sizes are the phoenix alone.
  $side = [Math]::Min($src.Width, $src.Height)
  $badge = New-Object System.Drawing.Rectangle ([int](($src.Width - $side) / 2)), ([int](($src.Height - $side) / 2)), $side, $side
  $bird = New-Object System.Drawing.Rectangle 228, 150, 180, 180
  $sizes = 256, 64, 48, 32, 24, 16
  $images = foreach ($s in $sizes) {
    $crop = if ($s -ge 128) { $badge } else { $bird }
    $bmp = New-Object System.Drawing.Bitmap $s, $s, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.DrawImage($src, (New-Object System.Drawing.Rectangle 0, 0, $s, $s), $crop, [System.Drawing.GraphicsUnit]::Pixel)
    $g.Dispose()
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    , $ms.ToArray()
  }
} finally { $src.Dispose() }

# An .ico is a 6-byte header, a 16-byte entry per image, then the images (PNG
# inside an .ico is fine from Windows Vista on). A size of 0 means 256.
$out = New-Object System.IO.MemoryStream
$w = New-Object System.IO.BinaryWriter $out
$w.Write([UInt16]0); $w.Write([UInt16]1); $w.Write([UInt16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
  $s = $sizes[$i]; $data = $images[$i]
  $w.Write([byte]($s % 256)); $w.Write([byte]($s % 256))
  $w.Write([byte]0); $w.Write([byte]0)
  $w.Write([UInt16]1); $w.Write([UInt16]32)
  $w.Write([UInt32]$data.Length); $w.Write([UInt32]$offset)
  $offset += $data.Length
}
foreach ($data in $images) { $w.Write($data) }
$w.Flush()
[System.IO.File]::WriteAllBytes((Join-Path $here 'prm.ico'), $out.ToArray())
Write-Host ("wrote prm.ico, {0:N0} bytes" -f $out.Length)
