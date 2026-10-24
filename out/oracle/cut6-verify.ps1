$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$export = Join-Path $root 'out\cut6-flip.mp4'
$asym = Join-Path $root 'out\testmedia\asym.mp4'
$frames = Join-Path $root 'out\frames'
New-Item -ItemType Directory -Path $frames -Force | Out-Null

# Same method as cut4-verify: 32x32 greyscale frames, mean absolute error,
# ~0 = the same picture, 70+ = unrelated. The -VF chain runs after the scale, so
# a source frame can be flipped and compared with what a `flip` slot should have
# produced.
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

# Timeline -> source-time map for examples/cut6-flip.json (12 s, 5 clips):
#   0.0-3.0  flip horizontal  source 0.0-3.0
#   3.0-6.0  flip vertical    source 0.0-3.0
#   6.0-7.5  flip both        source 0.0-1.5   (split)
#   7.5-9.0  flip both        source 1.5-3.0   (split)
#   9.0-12.0 flip none        source 0.0-3.0
$cases = @(
    @{ Clip = 'horizontal, clip 1'; Exp = 1.5;  Src = 1.5;  Expect = 'hflip' }
    @{ Clip = 'vertical,   clip 2'; Exp = 4.5;  Src = 1.5;  Expect = 'vflip' }
    @{ Clip = 'both,       clip 3a'; Exp = 6.75; Src = 0.75; Expect = 'hflip,vflip' }
    @{ Clip = 'both,       clip 3b'; Exp = 8.25; Src = 2.25; Expect = 'hflip,vflip' }
    @{ Clip = 'none,       clip 4'; Exp = 10.5; Src = 1.5;  Expect = '' }
)

$rows = foreach ($c in $cases) {
    $shot = Get-Gray -Source $export -Seconds $c.Exp -Name ('c6_exp' + $c.Exp)
    [pscustomobject]@{
        Clip          = $c.Clip
        'as expected' = Get-Mae $shot (Get-Gray -Source $asym -Seconds $c.Src -Name ('c6_src' + $c.Src + '_' + $c.Expect) -VF $c.Expect)
        'hflip'       = Get-Mae $shot (Get-Gray -Source $asym -Seconds $c.Src -Name ('c6_src' + $c.Src + '_h') -VF 'hflip')
        'vflip'       = Get-Mae $shot (Get-Gray -Source $asym -Seconds $c.Src -Name ('c6_src' + $c.Src + '_v') -VF 'vflip')
        'h+v flip'    = Get-Mae $shot (Get-Gray -Source $asym -Seconds $c.Src -Name ('c6_src' + $c.Src + '_hv') -VF 'hflip,vflip')
        'unflipped'   = Get-Mae $shot (Get-Gray -Source $asym -Seconds $c.Src -Name ('c6_src' + $c.Src + '_n'))
    }
}

$rows | Format-Table -AutoSize | Out-String -Width 120
