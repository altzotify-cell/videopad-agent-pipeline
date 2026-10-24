$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$export = Join-Path $root 'out\cut9-filters.mp4'
$source = Join-Path $root 'out\testmedia\bars.mp4'
$temp = Join-Path $env:TEMP 'cut9'

New-Item -ItemType Directory -Force -Path $temp | Out-Null

# One gray frame as a byte array. -ss before -i is a fast seek, which is fine for
# a still frame: the clip boundaries in the export are exact to the ms, and every
# probe sits 1 s inside a 2 s clip.
function Get-GrayFrame {
    param([string]$Source, [double]$Seconds)
    $raw = Join-Path $temp ("frame-{0}.raw" -f [guid]::NewGuid().ToString('N'))
    $cmd = "ffmpeg -hide_banner -loglevel error -ss $Seconds -i `"$Source`" -frames:v 1 -vf format=gray -f rawvideo -y `"$raw`""
    cmd /c "$cmd 2>&1" | Out-Null
    if (-not (Test-Path $raw)) { throw "No frame at $Seconds s from $Source" }
    $bytes = [IO.File]::ReadAllBytes($raw)
    Remove-Item $raw -Force
    return $bytes
}

# Per-pixel 4-neighbour Laplacian of the frame. Two statistics come out of it:
#   mean  - how much fine detail the frame carries overall (grain inflates it)
#   p99.5 - how hard the strongest edges are (blur rounds those off first)
function Measure-Edge {
    param([byte[]]$Pixels, [int]$Width = 640, [int]$Height = 360)
    $laps = New-Object 'double[]' (($Width - 2) * ($Height - 2))
    $k = 0
    $sum = 0.0
    for ($y = 1; $y -lt $Height - 1; $y++) {
        $row = $y * $Width
        $up = $row - $Width
        $down = $row + $Width
        for ($x = 1; $x -lt $Width - 1; $x++) {
            $c = [int]$Pixels[$row + $x]
            $v = [Math]::Abs(4 * $c - [int]$Pixels[$row + $x - 1] - [int]$Pixels[$row + $x + 1] - [int]$Pixels[$up + $x] - [int]$Pixels[$down + $x]) / 4.0
            $laps[$k++] = $v
            $sum += $v
        }
    }
    [Array]::Sort($laps)
    $peak = $laps[[int][Math]::Floor($laps.Length * 0.995)]
    return [pscustomobject]@{
        Mean = [math]::Round($sum / $laps.Length, 3)
        Peak = [math]::Round($peak, 1)
    }
}

function Measure-Mae {
    param([byte[]]$A, [byte[]]$B)
    if ($A.Length -ne $B.Length) { throw "Frame sizes differ: $($A.Length) vs $($B.Length)" }
    $sum = 0.0
    for ($i = 0; $i -lt $A.Length; $i++) { $sum += [Math]::Abs([int]$A[$i] - [int]$B[$i]) }
    return [math]::Round($sum / $A.Length, 2)
}

# examples/cut9-filters.json: 10x2 s from bars.mp4, every clip starting at source 0,
# so every clip shows the same underlying frame and any difference is the effect.
$clips = @(
    @{ From = 0.0;  What = 'control' },
    @{ From = 2.0;  What = 'blur 25' },
    @{ From = 4.0;  What = 'blur 100' },
    @{ From = 6.0;  What = 'blur 100 x2 slots' },
    @{ From = 8.0;  What = 'noise 80' },
    @{ From = 10.0; What = 'noise 80, sat 100' },
    @{ From = 12.0; What = 'noise 80, cov 50' },
    @{ From = 14.0; What = 'noise 80, cov 10' },
    @{ From = 16.0; What = 'noise 20' },
    @{ From = 18.0; What = 'blur 40 + noise 30, cov 60' }
)

$control = $null
$sourceFrame = Get-GrayFrame -Source $source -Seconds 1.0
$rows = foreach ($c in $clips) {
    $frame = Get-GrayFrame -Source $export -Seconds ($c.From + 1.0)
    if ($null -eq $control) { $control = $frame }
    $edge = Measure-Edge -Pixels $frame
    [pscustomobject]@{
        Clip            = ('{0:0.0}-{1:0.0}s' -f $c.From, ($c.From + 2.0))
        Effect          = $c.What
        'detail mean'   = $edge.Mean
        'edge peak'     = $edge.Peak
        'MAE vs control' = $(if ($c.From -eq 0.0) { 0 } else { Measure-Mae -A $frame -B $control })
        'MAE vs source' = Measure-Mae -A $frame -B $sourceFrame
    }
}

$duration = (& ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 $export)
$rows | Format-Table -AutoSize | Out-String -Width 120
"duration: $([math]::Round([double]$duration, 3)) s"

# --- noise 'saturation': does it add colour noise on top of luma noise? ---------
# Chroma planes of a yuv444p frame; a pixel's distance from neutral (128) is how
# much colour it carries, so the mean distance is "how colourful the frame is".
function Get-YuvFrame {
    param([string]$Source, [double]$Seconds)
    $raw = Join-Path $temp ("yuv-{0}.raw" -f [guid]::NewGuid().ToString('N'))
    $cmd = "ffmpeg -hide_banner -loglevel error -ss $Seconds -i `"$Source`" -frames:v 1 -vf format=yuv444p -f rawvideo -y `"$raw`""
    cmd /c "$cmd 2>&1" | Out-Null
    $bytes = [IO.File]::ReadAllBytes($raw)
    Remove-Item $raw -Force
    return $bytes
}

function Measure-Chroma {
    param([byte[]]$Yuv, [int]$Width = 640, [int]$Height = 360)
    $plane = $Width * $Height
    $u = 0.0; $v = 0.0
    for ($i = 0; $i -lt $plane; $i++) {
        $u += [Math]::Abs([int]$Yuv[$plane + $i] - 128)
        $v += [Math]::Abs([int]$Yuv[2 * $plane + $i] - 128)
    }
    return [pscustomobject]@{
        U = [math]::Round($u / $plane, 3)
        V = [math]::Round($v / $plane, 3)
    }
}

$chromaRows = foreach ($c in @(
        @{ At = 1.0;  What = 'control' },
        @{ At = 9.0;  What = 'noise 80 (sat default 0)' },
        @{ At = 11.0; What = 'noise 80, sat 100' }
    )) {
    $ch = Measure-Chroma -Yuv (Get-YuvFrame -Source $export -Seconds $c.At)
    [pscustomobject]@{
        Clip              = $c.What
        'mean |U-128|'   = $ch.U
        'mean |V-128|'    = $ch.V
    }
}

# --- noise 'coverage': what fraction of the frame does it actually touch? -------
# Counting tiles by detail was useless (speckle lands in every tile), so this
# counts the pixels that actually moved: the fraction of pixels differing from the
# control frame by more than a threshold. If coverage is a percentage of pixels,
# that fraction should track it regardless of where the speckle lands.
function Measure-NoisePixelFraction {
    param([byte[]]$Pixels, [byte[]]$Control, [int]$Threshold = 8)
    $hit = 0
    for ($i = 0; $i -lt $Pixels.Length; $i++) {
        if ([Math]::Abs([int]$Pixels[$i] - [int]$Control[$i]) -gt $Threshold) { $hit++ }
    }
    return [math]::Round($hit / $Pixels.Length, 3)
}

$coverageRows = foreach ($c in @(
        @{ At = 9.0;  What = 'coverage 100 (default)'; Expected = 1.0 },
        @{ At = 13.0; What = 'coverage 50'; Expected = 0.5 },
        @{ At = 15.0; What = 'coverage 10'; Expected = 0.1 }
    )) {
    $frac = Measure-NoisePixelFraction -Pixels (Get-GrayFrame -Source $export -Seconds $c.At) -Control $control
    [pscustomobject]@{
        Clip             = $c.What
        'pixels moved'   = $frac
        'coverage asked' = $c.Expected
    }
}

$chromaRows | Format-Table -AutoSize | Out-String -Width 110
$coverageRows | Format-Table -AutoSize | Out-String -Width 110


