$ErrorActionPreference = 'Stop'
$root = 'C:\Users\user\Downloads\videopad'
$export = Join-Path $root 'out\cut3-addmedia.mp4'
$bars = Join-Path $root 'out\testmedia\bars.mp4'
$ep3 = 'C:\Users\user\Downloads\Telegram Desktop\One_Punch_Man_Season_3_Episode_3_1080p_@Tv_Series_ETY_.Mkv'
$ep2 = 'C:\Users\user\Downloads\Telegram Desktop\One_Punch_Man_Season_3_Episode_2_1080p_@Tv_Series_ETY_.Mkv'
$frames = Join-Path $root 'out\frames'
New-Item -ItemType Directory -Path $frames -Force | Out-Null

# 32x32 greyscale frames, mean absolute error - the same method used for the
# earlier content checks: ~0 means the same picture, 70+ means unrelated.
function Get-Gray {
    param([string]$Source, [double]$Seconds, [string]$Name)
    $out = Join-Path $frames "$Name.gray"
    & ffmpeg -hide_banner -loglevel error -y -ss $Seconds -i $Source -frames:v 1 -vf 'scale=32:32,format=gray' -f rawvideo $out
    return , ([IO.File]::ReadAllBytes($out))
}

function Get-Mae {
    param([byte[]]$A, [byte[]]$B)
    $sum = 0.0
    for ($i = 0; $i -lt $A.Length; $i++) { $sum += [Math]::Abs([int]$A[$i] - [int]$B[$i]) }
    return [Math]::Round($sum / $A.Length, 2)
}

$exp18 = Get-Gray -Source $export -Seconds 18 -Name 'cut3_exp18'
$exp5 = Get-Gray -Source $export -Seconds 5 -Name 'cut3_exp5'
$exp30 = Get-Gray -Source $export -Seconds 30 -Name 'cut3_exp30'

$bars3 = Get-Gray -Source $bars -Seconds 3 -Name 'bars3'
$bars0 = Get-Gray -Source $bars -Seconds 0.5 -Name 'bars05'
$ep3_5 = Get-Gray -Source $ep3 -Seconds 5 -Name 'ep3_5'
$ep3_909 = Get-Gray -Source $ep3 -Seconds 909 -Name 'ep3_909'
$ep2_5 = Get-Gray -Source $ep2 -Seconds 5 -Name 'ep2_5'

[pscustomobject]@{
    'export@18 vs bars@3' = Get-Mae $exp18 $bars3
    'export@18 vs bars@0.5' = Get-Mae $exp18 $bars0
    'export@18 vs Ep3@5' = Get-Mae $exp18 $ep3_5
    'export@5  vs Ep3@5' = Get-Mae $exp5 $ep3_5
    'export@5  vs Ep2@5' = Get-Mae $exp5 $ep2_5
    'export@30 vs Ep3@909' = Get-Mae $exp30 $ep3_909
    'export@30 vs Ep3@5' = Get-Mae $exp30 $ep3_5
} | Format-List
