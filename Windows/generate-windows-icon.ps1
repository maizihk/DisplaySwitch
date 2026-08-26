$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing

$projectRoot = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $projectRoot 'Resources\AppIcon.png'
$destinationPath = Join-Path $PSScriptRoot 'DisplaySwitcher.Native\AppIcon.ico'

$source = [System.Drawing.Bitmap]::FromFile($sourcePath)
$transparent = [System.Drawing.Bitmap]::new(256, 256, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$graphics = [System.Drawing.Graphics]::FromImage($transparent)
$graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
$graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
$graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
$graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
$graphics.DrawImage($source, [System.Drawing.Rectangle]::new(0, 0, 256, 256))
$graphics.Dispose()
$source.Dispose()

$visited = [bool[]]::new(256 * 256)
$queue = [int[]]::new(256 * 256)
$head = 0
$tail = 0
for ($x = 0; $x -lt 256; $x++) {
    foreach ($y in @(0, 255)) {
        $index = ($y * 256) + $x
        if (-not $visited[$index]) { $visited[$index] = $true; $queue[$tail++] = $index }
    }
}
for ($y = 1; $y -lt 255; $y++) {
    foreach ($x in @(0, 255)) {
        $index = ($y * 256) + $x
        if (-not $visited[$index]) { $visited[$index] = $true; $queue[$tail++] = $index }
    }
}

while ($head -lt $tail) {
    $index = $queue[$head++]
    $x = $index % 256
    $y = [math]::Floor($index / 256)
    $color = $transparent.GetPixel($x, $y)
    if ($color.R -lt 240 -or $color.G -lt 240 -or $color.B -lt 240) { continue }
    $transparent.SetPixel($x, $y, [System.Drawing.Color]::FromArgb(0, $color.R, $color.G, $color.B))
    if ($x -gt 0) { $next = $index - 1; if (-not $visited[$next]) { $visited[$next] = $true; $queue[$tail++] = $next } }
    if ($x -lt 255) { $next = $index + 1; if (-not $visited[$next]) { $visited[$next] = $true; $queue[$tail++] = $next } }
    if ($y -gt 0) { $next = $index - 256; if (-not $visited[$next]) { $visited[$next] = $true; $queue[$tail++] = $next } }
    if ($y -lt 255) { $next = $index + 256; if (-not $visited[$next]) { $visited[$next] = $true; $queue[$tail++] = $next } }
}

$sizes = @(16, 20, 24, 32, 40, 48, 64, 128, 256)
$images = [System.Collections.Generic.List[byte[]]]::new()
foreach ($size in $sizes) {
    $resized = [System.Drawing.Bitmap]::new($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($resized)
    $graphics.Clear([System.Drawing.Color]::Transparent)
    $graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
    $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
    $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $graphics.DrawImage($transparent, [System.Drawing.Rectangle]::new(0, 0, $size, $size))
    $graphics.Dispose()
    $stream = [System.IO.MemoryStream]::new()
    $resized.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
    $resized.Dispose()
    $images.Add($stream.ToArray())
    $stream.Dispose()
}
$transparent.Dispose()

$output = [System.IO.FileStream]::new($destinationPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
$writer = [System.IO.BinaryWriter]::new($output)
$writer.Write([uint16]0)
$writer.Write([uint16]1)
$writer.Write([uint16]$sizes.Count)
$offset = 6 + (16 * $sizes.Count)
for ($index = 0; $index -lt $sizes.Count; $index++) {
    $writer.Write([byte]$(if ($sizes[$index] -eq 256) { 0 } else { $sizes[$index] }))
    $writer.Write([byte]$(if ($sizes[$index] -eq 256) { 0 } else { $sizes[$index] }))
    $writer.Write([byte]0)
    $writer.Write([byte]0)
    $writer.Write([uint16]1)
    $writer.Write([uint16]32)
    $writer.Write([uint32]$images[$index].Length)
    $writer.Write([uint32]$offset)
    $offset += $images[$index].Length
}
foreach ($image in $images) { $writer.Write($image) }
$writer.Dispose()
$output.Dispose()

Write-Output $destinationPath
