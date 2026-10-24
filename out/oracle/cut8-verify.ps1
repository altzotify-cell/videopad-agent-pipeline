$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$export = Join-Path $root 'out\cut8-audiofade.mp4'

function Get-MeanVolume {
    param([string]$Source, [double]$Seconds, [double]$Length = 0.15)
    $line = cmd /c "ffmpeg -hide_banner -nostats -ss $Seconds -t $Length -i `"$Source`" -af volumedetect -f null NUL 2>&1" |
        Select-String 'mean_volume'
    if (-not $line) { return $null }
    $m = [regex]::Match([string]$line, 'mean_volume:\s*(-?[\d.]+) dB')
    if (-not $m.Success) { return $null }
    return [double]$m.Groups[1].Value
}

# examples/cut8-audiofade.json: 4x3 s from asym.mp4 -
#   0.0-3.0  no audio keys                     (control)
#   3.0-6.0  audioFadeIn 800
#   6.0-9.0  audioFadeOut 800
#   9.0-12.0 audioGainDb -6, audioFadeIn/Out 500
$control = Get-MeanVolume -Source $export -Seconds 1.5
$probes = @(
    @{ Clip = 'no keys (control)'; At = 1.5 },
    @{ Clip = 'fadeIn 800:  3.10 s'; At = 3.10 },
    @{ Clip = 'fadeIn 800:  3.40 s'; At = 3.40 },
    @{ Clip = 'fadeIn 800:  3.70 s'; At = 3.70 },
    @{ Clip = 'fadeIn 800:  3.90 s'; At = 3.90 },
    @{ Clip = 'fadeIn 800:  4.50 s'; At = 4.50 },
    @{ Clip = 'fadeOut 800: 7.50 s'; At = 7.50 },
    @{ Clip = 'fadeOut 800: 8.30 s'; At = 8.30 },
    @{ Clip = 'fadeOut 800: 8.60 s'; At = 8.60 },
    @{ Clip = 'fadeOut 800: 8.85 s'; At = 8.85 },
    @{ Clip = '-6dB+500:   9.10 s'; At = 9.10 },
    @{ Clip = '-6dB+500:   9.40 s'; At = 9.40 },
    @{ Clip = '-6dB+500:   9.60 s'; At = 9.60 },
    @{ Clip = '-6dB+500:  10.50 s'; At = 10.50 },
    @{ Clip = '-6dB+500:  11.60 s'; At = 11.60 },
    @{ Clip = '-6dB+500:  11.85 s'; At = 11.85 }
) | ForEach-Object {
    $v = Get-MeanVolume -Source $export -Seconds $_.At
    [pscustomobject]@{
        Clip        = $_.Clip
        'mean dB'   = $v
        'vs control' = $(if ($null -ne $v) { [math]::Round($v - $control, 2) } else { $null })
    }
}

[pscustomobject]@{ 'control mean dB (1.5 s)' = $control } | Format-List
$probes | Format-Table -AutoSize | Out-String -Width 100
