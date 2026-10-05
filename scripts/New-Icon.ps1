$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
function Draw-RelayIcon([int]$size, [bool]$trayOnly = $false) {
    $renderSize = [Math]::Max(256, $size * 4)
    $canvas = [System.Drawing.Bitmap]::new($renderSize, $renderSize)
    $g = [System.Drawing.Graphics]::FromImage($canvas)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)
    $g.ScaleTransform($renderSize / 64.0, $renderSize / 64.0)
    if (-not $trayOnly) {
        $tile = [System.Drawing.Drawing2D.GraphicsPath]::new()
        $tile.AddArc(2,2,26,26,180,90); $tile.AddArc(36,2,26,26,270,90)
        $tile.AddArc(36,36,26,26,0,90); $tile.AddArc(2,36,26,26,90,90); $tile.CloseFigure()
        $base = [System.Drawing.Drawing2D.LinearGradientBrush]::new([System.Drawing.Point]::new(0,0),[System.Drawing.Point]::new(64,64),[System.Drawing.ColorTranslator]::FromHtml('#273B3C'),[System.Drawing.ColorTranslator]::FromHtml('#101B25'))
        $g.FillPath($base,$tile)
        $rim = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(65,185,236,218),0.65)
        $g.DrawPath($rim,$tile)
        $rim.Dispose(); $base.Dispose(); $tile.Dispose()
    }
    # An open relay loop: one incoming path, a shared bend, an outgoing handoff.
    $route = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $route.AddLine(19,43,19,26)
    $route.AddBezier(19,26,19,12,46,12,46,26)
    $route.AddBezier(46,26,46,35,34,35,30,35)
    $route.AddLine(30,35,44,47)
    $paint = [System.Drawing.Drawing2D.LinearGradientBrush]::new([System.Drawing.Point]::new(16,12),[System.Drawing.Point]::new(48,51),[System.Drawing.ColorTranslator]::FromHtml('#BEF6DA'),[System.Drawing.ColorTranslator]::FromHtml('#53CBBB'))
    $pen = [System.Drawing.Pen]::new($paint,6.5)
    $pen.StartCap='Round'; $pen.EndCap='Round'; $pen.LineJoin='Round'
    $g.DrawPath($pen,$route)
    # Separate endpoint gives the mark a recognizable relay/handoff detail at 16px.
    $dot = [System.Drawing.SolidBrush]::new([System.Drawing.ColorTranslator]::FromHtml('#BCF5D8'))
    $g.FillEllipse($dot,15.5,48,7,7)
    $dot.Dispose(); $pen.Dispose(); $paint.Dispose(); $route.Dispose(); $g.Dispose()
    $bitmap = [System.Drawing.Bitmap]::new($size,$size)
    $scaled = [System.Drawing.Graphics]::FromImage($bitmap)
    $scaled.InterpolationMode='HighQualityBicubic'; $scaled.PixelOffsetMode='HighQuality'
    $scaled.DrawImage($canvas,0,0,$size,$size)
    $scaled.Dispose(); $canvas.Dispose()
    return $bitmap
}
function Write-RelayIco([string]$path,[bool]$trayOnly) {
    $frames = @()
    foreach ($size in @(16,20,24,32,40,48,64,128,256)) {
        $bitmap = Draw-RelayIcon $size $trayOnly
        $stream = [System.IO.MemoryStream]::new()
        $bitmap.Save($stream,[System.Drawing.Imaging.ImageFormat]::Png)
        $frames += @{ Size=$size; Bytes=$stream.ToArray() }
        $stream.Dispose(); $bitmap.Dispose()
    }
    $file=[System.IO.File]::Create($path); $writer=[System.IO.BinaryWriter]::new($file)
    try {
        $writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$frames.Count)
        $offset=6+16*$frames.Count
        foreach ($frame in $frames) {
            $dimension=if ($frame.Size -eq 256) {0} else {$frame.Size}
            $writer.Write([byte]$dimension); $writer.Write([byte]$dimension); $writer.Write([byte]0); $writer.Write([byte]0)
            $writer.Write([uint16]1); $writer.Write([uint16]32); $writer.Write([uint32]$frame.Bytes.Length); $writer.Write([uint32]$offset)
            $offset += $frame.Bytes.Length
        }
        foreach ($frame in $frames) {$writer.Write([byte[]]$frame.Bytes)}
    } finally {$writer.Dispose(); $file.Dispose()}
}
Write-RelayIco (Join-Path $PSScriptRoot '..\Assets\Relay.ico') $false
Write-RelayIco (Join-Path $PSScriptRoot '..\Assets\Relay-tray.ico') $true
$preview=Draw-RelayIcon 512 $false
$preview.Save((Join-Path $PSScriptRoot '..\Assets\Relay-preview.png'),[System.Drawing.Imaging.ImageFormat]::Png)
$preview.Dispose()
