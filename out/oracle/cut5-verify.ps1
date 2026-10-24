$ErrorActionPreference = 'Stop'
$root = 'C:\Users\user\Downloads\videopad'
$export = Join-Path $root 'out\cut5-cadence.mp4'
$bars = Join-Path $root 'out\testmedia\bars.mp4'
$frames = Join-Path $root 'out\frames'
New-Item -ItemType Directory -Path $frames -Force | Out-Null

# Same 32x32 greyscale MAE method as cut4-verify.ps1: ~0 means "the same picture",
# 70+ means unrelated. testsrc2 burns its own timecode into the frame, so the MAE
# minimum over candidate source times is a direct read-out of *which* source
# millisecond the clip is playing — which is exactly what a speed change alters.
function Get-Gray {
    param([string]$Source, [double]$Seconds, [string]$Name, [string]$VF = '')
    $out = Join-Path $frames "$Name.gray"
    $chain = 'scale=32:32,format=gray'
    if ($VF) { $chain = "$chain,$VF" }
    & ffmpeg -hide_banner -loglevel error -y -ss $Seconds -i $Source -frames:v 1 -vf $chain -f rawvideo $out
    return , ([IO.File]::ReadAllBytes($out))
}

function Get-Mae {
    param([byte[]]$A, [byte[]]$B)
    $sum = 0.0
    for ($i = 0; $i -lt $A.Length; $i++) { $sum += [Math]::Abs([int]$A[$i] - [int]$B[$i]) }
    return [Math]::Round($sum / $A.Length, 2)
}

# Mean luma of a frame: the fade metric. A fade multiplies the whole picture, so
# this falls towards 0 and returns to the source's own level.
function Get-Luma {
    param([string]$Source, [double]$Seconds, [string]$Name, [string]$VF = '')
    $b = Get-Gray -Source $Source -Seconds $Seconds -Name $Name -VF $VF
    $sum = 0.0
    foreach ($v in $b) { $sum += $v }
    return [Math]::Round($sum / $b.Length, 1)
}

$duration = [double](& ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 $export)

# The mirror effect's *default* direction is not a flip: it keeps the left half
# and reflects it onto the right (a "half mirror"), so a plain hflip/vflip does
# not describe the picture. Measured against bars@4.0: unflipped 53.99,
# hflip 53.98, vflip 58.36, half-mirrored 1.67.
$halfMirror = 'crop=iw/2:ih:0:0,split[a][b];[b]hflip[h];[a][h]hstack'

# --- speed -------------------------------------------------------------------
# clip 1: bars 0-6000 at 2x  -> in=0,    out=3000, slot 0-3000
# clip 3: bars 0-3000 at 0.5x-> in=0,    out=6000, slot 6000-12000
# clip 4: bars 3000-6000 2x  -> in=1500, out=3000, slot 12000-13500 (mirrored)
# "naive" is the reading where in/out would be plain source milliseconds, i.e.
# the interpretation that would apply if speedchangef were ignored.
$speed = [pscustomobject]@{
    'speed: export@2.9  vs bars@5.8 (2x, expected)' = Get-Mae (Get-Gray $export 2.9 'c5_exp2_9') (Get-Gray $bars 5.8 'c5_bars5_8')
    'speed: export@2.9  vs bars@2.9 (naive)       ' = Get-Mae (Get-Gray $export 2.9 'c5_exp2_9b') (Get-Gray $bars 2.9 'c5_bars2_9')
    'speed: export@8.5  vs bars@1.25 (0.5x, expect)' = Get-Mae (Get-Gray $export 8.5 'c5_exp8_5') (Get-Gray $bars 1.25 'c5_bars1_25')
    'speed: export@8.5  vs bars@2.5 (naive)       ' = Get-Mae (Get-Gray $export 8.5 'c5_exp8_5b') (Get-Gray $bars 2.5 'c5_bars2_5')
    'speed: export@12.5 vs bars@4.0 2x, in=1500     ' = Get-Mae (Get-Gray $export 12.5 'c5_exp12_5') (Get-Gray $bars 4.0 'c5_bars4' -VF $halfMirror)
    'speed: export@12.5 vs bars@2.0 naive, in=1500  ' = Get-Mae (Get-Gray $export 12.5 'c5_exp12_5b') (Get-Gray $bars 2.0 'c5_bars2' -VF $halfMirror)
}

# --- mirror on the sped clip --------------------------------------------------
# Axis-agnostic framing: the clip matches the source half-mirrored (the effect's
# default direction, mirrordirection=0) and does not match the plain source. That
# also proves effects and speed compose — the clip is playing at 2x *and*
# carrying a chain at the same time.
$exp125 = Get-Gray $export 12.5 'c5_exp12_5_m'
$mirror = [pscustomobject]@{
    'mirror: export@12.5 vs bars@4.0 half-mirrored' = Get-Mae $exp125 (Get-Gray $bars 4.0 'c5_bars4_hm' -VF $halfMirror)
    'mirror: export@12.5 vs bars@4.0 unflipped    ' = Get-Mae $exp125 (Get-Gray $bars 4.0 'c5_bars4_m')
}

# --- fades --------------------------------------------------------------------
# clip 1 fades in over 250 ms from t=0; clip 2 fades out over 500 ms to t=6000;
# clip 4 fades in over 200 ms from t=12000 and out over 200 ms to t=13500.
$fades = [pscustomobject]@{
    'fadeIn  clip1 t=0.01' = Get-Luma $export 0.01 'c5_f1a'
    'fadeIn  clip1 t=0.12' = Get-Luma $export 0.12 'c5_f1b'
    'fadeIn  clip1 t=0.26' = Get-Luma $export 0.26 'c5_f1c'
    'fadeIn  clip1 t=0.60' = Get-Luma $export 0.60 'c5_f1d'
    'fadeOut clip2 t=5.40' = Get-Luma $export 5.40 'c5_f2a'
    'fadeOut clip2 t=5.75' = Get-Luma $export 5.75 'c5_f2b'
    'fadeOut clip2 t=5.95' = Get-Luma $export 5.95 'c5_f2c'
    'fadeIn  clip4 t=12.05' = Get-Luma $export 12.05 'c5_f4a'
    'fadeIn  clip4 t=12.40' = Get-Luma $export 12.40 'c5_f4b'
    'fadeOut clip4 t=13.35' = Get-Luma $export 13.35 'c5_f4c'
    'fadeOut clip4 t=13.45' = Get-Luma $export 13.45 'c5_f4d'
}

[pscustomobject]@{
    'export          ' = $export
    'duration (s)    ' = [Math]::Round($duration, 3)
    'expected (s)    ' = 13.5
    'delta (ms)      ' = [Math]::Round(($duration - 13.5) * 1000, 1)
} | Format-List
$speed | Format-List
$mirror | Format-List
$fades | Format-List
