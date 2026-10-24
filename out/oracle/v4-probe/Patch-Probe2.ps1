# Second probe: is effect 28 audio volume or video opacity, and is a clip's `in`
# a source offset or a speed-scaled timeline offset?
param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Destination
)

$ErrorActionPreference = 'Stop'

function Set-Field {
    param([string]$Line, [string]$Key, [string]$Value)
    $pattern = '(^|&)' + [regex]::Escape($Key) + '=[^&]*'
    if ([regex]::IsMatch($Line, $pattern)) {
        return [regex]::Replace($Line, $pattern, { param($m) $m.Groups[1].Value + $Key + '=' + $Value }, 1)
    }
    return $Line + '&' + $Key + '=' + $Value
}

function New-SlotLine {
    param([string]$Line, [int]$Id, [string]$Preset, [string]$Data)
    $escPreset = [uri]::EscapeDataString($Preset)
    $escData = [uri]::EscapeDataString($Data)
    $out = @('size=1')
    $out += 'type0=' + $Id
    $out += 'preset0=' + $escPreset
    $out += 'data0=' + $escData
    foreach ($part in ($Line -split '&')) {
        if ($part -eq '') { continue }
        $k = ($part -split '=', 2)[0]
        if ($k -eq 'size' -or $k -match '^(type|preset|data)\d+$') { continue }
        $out += $part
    }
    return ($out -join '&')
}

# The app's own Fade In and Out preset, verbatim from the EffectPresets dump.
$fadeInOut = 'value=100.000000&userdata=0&keys=3' +
    '&position0=0.000000&value0=0.000000&userdata0=0&prevcpposition0=0.000000&prevcpvalue0=0.000000&nextcpposition0=0.000000&nextcpvalue0=0.000000' +
    '&position1=0.500000&value1=100.000000&userdata1=0&prevcpposition1=0.000000&prevcpvalue1=0.000000&nextcpposition1=0.000000&nextcpvalue1=0.000000' +
    '&position2=1.000000&value2=0.000000&userdata2=0&prevcpposition2=0.000000&prevcpvalue2=0.000000&nextcpposition2=0.000000&nextcpvalue2=0.000000'
$fadeIn = 'value=50.000000&userdata=0&keys=2' +
    '&position0=0.000000&value0=0.000000&userdata0=0&prevcpposition0=0.000000&prevcpvalue0=0.000000&nextcpposition0=0.000000&nextcpvalue0=0.000000' +
    '&position1=1.000000&value1=100.000000&userdata1=0&prevcpposition1=0.000000&prevcpvalue1=0.000000&nextcpposition1=0.000000&nextcpvalue1=0.000000'
$static25 = 'value=25.000000&userdata=0&keys=0'

# offset -> what to do: which domain gets effect 28, and whether speed is set
$cases = @(
    @{ Offset = [int64]3000; Domain = 'audio'; Preset = 'Default Preset'; Data = $static25; Note = 'audio chain, 28 static 25' }
    @{ Offset = [int64]6000; Domain = 'audio'; Preset = 'Fade In and Out'; Data = $fadeInOut; Note = 'audio chain, 28 fade in/out keys' }
    @{ Offset = [int64]9000; Domain = 'video'; Preset = 'Fade In'; Data = $fadeIn; Note = 'video chain, 28 fade in' }
    @{ Offset = [int64]12000; Domain = 'speed'; Note = 'speed 2, in=1000 out=4000' }
)

$lines = [IO.File]::ReadAllLines($Source)
$audioOf = @{}
foreach ($l in $lines) {
    if ($l -match '^h=\d+&type=7&' -and $l -match '(?:^|&)htrack=12') {
        $h = [int64]([regex]::Match($l, '^h=(\d+)').Groups[1].Value)
        $audioOf[$h] = [int64]([regex]::Match($l, '(?:^|&)hlinked=(\d+)').Groups[1].Value)
    }
}

for ($i = 0; $i -lt $lines.Count; $i++) {
    $l = $lines[$i]

    if ($l -match '^h=\d+&type=7&') {
        $offset = [int64]([regex]::Match($l, '(?:^|&)offset=(-?\d+)').Groups[1].Value)
        $case = $cases | Where-Object { $_.Offset -eq $offset } | Select-Object -First 1
        if ($case -and $case.Domain -eq 'speed') {
            $l = Set-Field $l 'in' '1000'
            $l = Set-Field $l 'out' '4000'
        }
    }
    elseif ($l -match '(?:^|&)hclip=(\d+)') {
        $hc = [int64]$Matches[1]

        # Which clip does this chain belong to? Each clip is a video handle plus
        # its hlinked audio handle, and each has its own record.
        $videoH = $null
        foreach ($v in $audioOf.Keys) {
            if ($v -eq $hc -or $audioOf[$v] -eq $hc) { $videoH = $v }
        }
        if ($null -ne $videoH) {
            $offsetOfClip = $null
            foreach ($tl in $lines) {
                if ($tl -match '^h=(\d+)&type=7&' -and [int64]$Matches[1] -eq $videoH) {
                    $offsetOfClip = [int64]([regex]::Match($tl, '(?:^|&)offset=(-?\d+)').Groups[1].Value)
                }
            }
            $case = $cases | Where-Object { $_.Offset -eq $offsetOfClip } | Select-Object -First 1
            if ($case) {
                if ($case.Domain -eq 'speed') { $l = Set-Field $l 'speedchangef' '2.000000' }
                elseif ($case.Domain -eq 'audio' -and $audioOf[$videoH] -eq $hc) { $l = New-SlotLine $l 28 $case.Preset $case.Data }
                elseif ($case.Domain -eq 'video' -and $videoH -eq $hc) { $l = New-SlotLine $l 28 $case.Preset $case.Data }
            }
        }
    }
    $lines[$i] = $l
}

[IO.File]::WriteAllLines($Destination, $lines)
foreach ($c in $cases) { '{0,6} ms  {1}' -f $c.Offset, $c.Note }
