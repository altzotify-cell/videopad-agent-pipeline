$ErrorActionPreference = 'Stop'
$root = 'C:\Users\user\Downloads\videopad'
$export = Join-Path $root 'out\cut4-effects.mp4'
$bars = Join-Path $root 'out\testmedia\bars.mp4'
$ep3 = 'C:\Users\user\Downloads\Telegram Desktop\One_Punch_Man_Season_3_Episode_3_1080p_@Tv_Series_ETY_.Mkv'
$frames = Join-Path $root 'out\frames'
New-Item -ItemType Directory -Path $frames -Force | Out-Null

# 32x32 greyscale frames, mean absolute error - the same method as the earlier
# content checks: ~0 means the same picture, 70+ means unrelated. An optional
# -VF chain runs *after* the scale so a source frame can be transposed/flipped
# and compared against what an effect should have produced.
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

# Mean chroma of a frame: average of (max channel - min channel) per pixel.
# 0 = greyscale, and it is the one number that separates "desaturated" from
# "the source happened to be grey already".
function Get-Chroma {
    param([string]$Source, [double]$Seconds, [string]$Name)
    $out = Join-Path $frames "$Name.rgb"
    & ffmpeg -hide_banner -loglevel error -y -ss $Seconds -i $Source -frames:v 1 -vf 'scale=32:32,format=rgb24' -f rawvideo $out
    $b = [IO.File]::ReadAllBytes($out)
    $sum = 0.0
    for ($i = 0; $i -lt $b.Length; $i += 3) {
        $mx = [Math]::Max($b[$i], [Math]::Max($b[$i + 1], $b[$i + 2]))
        $mn = [Math]::Min($b[$i], [Math]::Min($b[$i + 1], $b[$i + 2]))
        $sum += ($mx - $mn)
    }
    return [Math]::Round($sum / ($b.Length / 3), 1)
}

# --- saturation (type=24, value=-100) on clips 0-2 ----------------------------
# Clip 1 is Ep3 0-6 s, so export@5 is source@5.
$exp5 = Get-Gray -Source $export -Seconds 5 -Name 'cut4_exp5'
$ep3_5 = Get-Gray -Source $ep3 -Seconds 5 -Name 'ep3_5'
$chroma = [pscustomobject]@{
    'chroma export@1' = Get-Chroma $export 1 'cut4_exp1'
    'chroma export@3' = Get-Chroma $export 3 'cut4_exp3'
    'chroma export@5' = Get-Chroma $export 5 'cut4_exp5'
    'chroma Ep3@5   ' = Get-Chroma $ep3 5 'ep3_5'
}

# --- rotate (type=33, z=90) on clips 3-4 --------------------------------------
# Clip 3 is bars 0-3 s at timeline 6 s, so export@7 is bars@1. A 90 deg rotation
# pillarboxes the picture, so the export is cropped to its centre third before
# scaling; the source is transposed into the same box.
$exp7 = Get-Gray -Source $export -Seconds 7 -Name 'cut4_exp7' -VF 'crop=iw/3:ih'
$rot = [pscustomobject]@{
    'rotate: export@7 vs bars@1 transposed cw ' = Get-Mae $exp7 (Get-Gray -Source $bars -Seconds 1 -Name 'bars1_cw' -VF 'transpose=1')
    'rotate: export@7 vs bars@1 transposed ccw' = Get-Mae $exp7 (Get-Gray -Source $bars -Seconds 1 -Name 'bars1_ccw' -VF 'transpose=2')
    'rotate: export@7 vs bars@1 as-is        ' = Get-Mae $exp7 (Get-Gray -Source $bars -Seconds 1 -Name 'bars1' -VF 'crop=iw/3:ih')
    'rotate: export@7 keeps source chroma    ' = ('{0} vs {1}' -f (Get-Chroma $export 7 'cut4_exp7c'), (Get-Chroma $bars 1 'bars1c'))
}

# --- mirror (type=36, mirrordirection=vertical) + colour (type=6, contrast=60)
# Clip 6 is Ep3 900-903 s at timeline 12 s, so export@13 is source@901.
$exp13 = Get-Gray -Source $export -Seconds 13 -Name 'cut4_exp13'
$mirror = [pscustomobject]@{
    'mirror: export@13 vs Ep3@901 mirrored L-R' = Get-Mae $exp13 (Get-Gray -Source $ep3 -Seconds 901 -Name 'ep3_901_hflip' -VF 'hflip')
    'mirror: export@13 vs Ep3@901 mirrored T-B' = Get-Mae $exp13 (Get-Gray -Source $ep3 -Seconds 901 -Name 'ep3_901_vflip' -VF 'vflip')
    'mirror: export@13 vs Ep3@901 unmirrored  ' = Get-Mae $exp13 (Get-Gray -Source $ep3 -Seconds 901 -Name 'ep3_901')
}

# Left/right symmetry of the export frame itself: MAE between the frame and its
# own mirror image is 0 for a perfectly symmetric picture.
$selfLr = $null; $selfTb = $null
$sym = Join-Path $frames 'cut4_exp13_hflip.gray'
& ffmpeg -hide_banner -loglevel error -y -ss 13 -i $export -frames:v 1 -vf 'scale=32:32,format=gray,hflip' -f rawvideo $sym
$selfLr = Get-Mae $exp13 ([IO.File]::ReadAllBytes($sym))
$sym2 = Join-Path $frames 'cut4_exp13_vflip.gray'
& ffmpeg -hide_banner -loglevel error -y -ss 13 -i $export -frames:v 1 -vf 'scale=32:32,format=gray,vflip' -f rawvideo $sym2
$selfTb = Get-Mae $exp13 ([IO.File]::ReadAllBytes($sym2))
$srcSym = Join-Path $frames 'ep3_901_hflipself.gray'
& ffmpeg -hide_banner -loglevel error -y -ss 901 -i $ep3 -frames:v 1 -vf 'scale=32:32,format=gray,hflip' -f rawvideo $srcSym
$srcSelfLr = Get-Mae (Get-Gray -Source $ep3 -Seconds 901 -Name 'ep3_901b') ([IO.File]::ReadAllBytes($srcSym))

[pscustomobject]@{
    'saturation: export@5 vs Ep3@5' = Get-Mae $exp5 $ep3_5
} | Format-List
$chroma | Format-List
$rot | Format-List
$mirror | Format-List
[pscustomobject]@{
    'mirror: export@13 vs its own L-R mirror' = $selfLr
    'mirror: export@13 vs its own T-B mirror' = $selfTb
    'mirror: Ep3@901 vs its own L-R mirror  ' = $srcSelfLr
} | Format-List
