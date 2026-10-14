# Make-Icon.ps1
# Generates NetKnife.ico (multi-size, PNG frames): gradient rounded square + key + prompt.
# Usage: pwsh -File Make-Icon.ps1 [-Out path] [-PreviewPng path]

param(
    [string]$Out = (Join-Path $PSScriptRoot "NetKnife.ico"),
    [string]$PreviewPng
)

Add-Type -AssemblyName System.Drawing

function New-IconBitmap {
    param([int]$Size)

    $Bmp = New-Object System.Drawing.Bitmap $Size, $Size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $G = [System.Drawing.Graphics]::FromImage($Bmp)
    $G.SmoothingMode = "AntiAlias"
    $G.TextRenderingHint = "AntiAliasGridFit"
    $G.InterpolationMode = "HighQualityBicubic"
    $G.Clear([System.Drawing.Color]::Transparent)

    $S = [float]$Size
    $Pad = [Math]::Max(0.5, $S * 0.03)
    $R = $S * 0.24
    $Rect = New-Object System.Drawing.RectangleF $Pad, $Pad, ($S - 2 * $Pad), ($S - 2 * $Pad)

    $Path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $D = $R * 2
    $Path.AddArc($Rect.X, $Rect.Y, $D, $D, 180, 90)
    $Path.AddArc($Rect.Right - $D, $Rect.Y, $D, $D, 270, 90)
    $Path.AddArc($Rect.Right - $D, $Rect.Bottom - $D, $D, $D, 0, 90)
    $Path.AddArc($Rect.X, $Rect.Bottom - $D, $D, $D, 90, 90)
    $Path.CloseFigure()

    $Grad = New-Object System.Drawing.Drawing2D.LinearGradientBrush $Rect, ([System.Drawing.Color]::FromArgb(255, 56, 189, 248)), ([System.Drawing.Color]::FromArgb(255, 124, 58, 237)), 45.0
    $Blend = New-Object System.Drawing.Drawing2D.ColorBlend 3
    $Blend.Colors = @(
        [System.Drawing.Color]::FromArgb(255, 34, 211, 238),
        [System.Drawing.Color]::FromArgb(255, 79, 109, 245),
        [System.Drawing.Color]::FromArgb(255, 139, 61, 238)
    )
    $Blend.Positions = @(0.0, 0.5, 1.0)
    $Grad.InterpolationColors = $Blend
    $G.FillPath($Grad, $Path)

    # soft top highlight
    if ($Size -ge 32) {
        $HiRect = New-Object System.Drawing.RectangleF $Rect.X, $Rect.Y, $Rect.Width, ($Rect.Height * 0.5)
        $BrushRect = New-Object System.Drawing.RectangleF $Rect.X, ($Rect.Y - 1), $Rect.Width, ($Rect.Height * 0.5 + 2)
        $Hi = New-Object System.Drawing.Drawing2D.LinearGradientBrush $BrushRect, ([System.Drawing.Color]::FromArgb(60, 255, 255, 255)), ([System.Drawing.Color]::FromArgb(0, 255, 255, 255)), 90.0
        $G.SetClip($Path)
        $G.FillRectangle($Hi, $HiRect)
        $G.ResetClip()
    }

    # key glyph (Segoe Fluent Icons: Permissions)
    $White = [System.Drawing.Brushes]::White
    $Fmt = New-Object System.Drawing.StringFormat
    $Fmt.Alignment = "Center"
    $Fmt.LineAlignment = "Center"

    $GlyphSize = $S * 0.50
    $Font = New-Object System.Drawing.Font("Segoe Fluent Icons", $GlyphSize, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
    $GlyphRect = New-Object System.Drawing.RectangleF ($S * 0.07), ($S * -0.07), $S, $S
    $G.DrawString([string][char]0xE8D7, $Font, $White, $GlyphRect, $Fmt)

    # prompt ">_" in bottom-left corner for larger sizes
    if ($Size -ge 48) {
        $PFont = New-Object System.Drawing.Font("Cascadia Mono SemiBold", ($S * 0.17), [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        $PBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(230, 255, 255, 255))
        $G.DrawString(">_", $PFont, $PBrush, ($S * 0.12), ($S * 0.67))
    }

    $G.Dispose()
    return $Bmp
}

$Sizes = @(16, 20, 24, 32, 40, 48, 64, 128, 256)
$Frames = foreach ($Size in $Sizes) {
    $Bmp = New-IconBitmap $Size
    $Ms = New-Object System.IO.MemoryStream
    $Bmp.Save($Ms, [System.Drawing.Imaging.ImageFormat]::Png)
    if ($PreviewPng -and $Size -eq 256) { $Bmp.Save($PreviewPng, [System.Drawing.Imaging.ImageFormat]::Png) }
    $Bmp.Dispose()
    [pscustomobject]@{ Size = $Size; Data = $Ms.ToArray() }
}

# ICO container with PNG entries
$Fs = [System.IO.File]::Create($Out)
$W = New-Object System.IO.BinaryWriter $Fs
$W.Write([uint16]0); $W.Write([uint16]1); $W.Write([uint16]$Frames.Count)
$Offset = 6 + 16 * $Frames.Count
foreach ($F in $Frames) {
    $Dim = if ($F.Size -ge 256) { 0 } else { $F.Size }
    $W.Write([byte]$Dim); $W.Write([byte]$Dim); $W.Write([byte]0); $W.Write([byte]0)
    $W.Write([uint16]1); $W.Write([uint16]32)
    $W.Write([uint32]$F.Data.Length); $W.Write([uint32]$Offset)
    $Offset += $F.Data.Length
}
foreach ($F in $Frames) { $W.Write($F.Data) }
$W.Close()

"Icon written: $Out"
