$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$export = Join-Path $root 'out\cut7-audio.mp4'
$asym = Join-Path $root 'out\testmedia\asym.mp4'

# Mean volume of a window, straight from volumedetect. cmd /c keeps ffmpeg's
# banner on one stream so PowerShell does not turn it into an error record.
function Get-MeanVolume {
    param([string]$Source, [double]$Seconds, [double]$Length = 1.0)
    $line = cmd /c "ffmpeg -hide_banner -nostats -ss $Seconds -t $Length -i `"$Source`" -af volumedetect -f null NUL 2>&1" |
        Select-String 'mean_volume'
    if (-not $line) { return $null }
    $m = [regex]::Match([string]$line, 'mean_volume:\s*(-?[\d.]+) dB')
    if (-not $m.Success) { return $null }
    return [double]$m.Groups[1].Value
}

# Spec examples/cut7-audio.json: 4x3 s from asym.mp4 -
#   0.0-3.0  audioGainDb 0    (control)
#   3.0-6.0  audioGainDb -6
#   6.0-9.0  audioGainDb -12  (split at 7.5)
#   9.0-12.0 mute
$base = Get-MeanVolume -Source $asym -Seconds 1.5
$control = Get-MeanVolume -Source $export -Seconds 1.5
$rows = @(
    @{ Clip = 'audioGainDb 0 (control), 1.5 s'; At = 1.5 },
    @{ Clip = 'audioGainDb -6,          4.5 s'; At = 4.5 },
    @{ Clip = 'audioGainDb -12,         7.5 s'; At = 7.5 },
    @{ Clip = 'audioGainDb -12 (2nd),   8.2 s'; At = 8.2 },
    @{ Clip = 'mute,                   10.5 s'; At = 10.5 }
) | ForEach-Object {
    $v = Get-MeanVolume -Source $export -Seconds $_.At
    [pscustomobject]@{
        Clip          = $_.Clip
        'mean dB'     = $v
        'vs control'  = $(if ($null -ne $v) { [math]::Round($v - $control, 2) } else { $null })
        'vs source'   = $(if ($null -ne $v) { [math]::Round($v - $base, 2) } else { $null })
    }
}

[pscustomobject]@{
    'source asym@1.5s mean dB'   = $base
    'export control mean dB'     = $control
    'exporter lift vs source, dB' = [math]::Round($control - $base, 2)
} | Format-List
$rows | Format-Table -AutoSize | Out-String -Width 100
