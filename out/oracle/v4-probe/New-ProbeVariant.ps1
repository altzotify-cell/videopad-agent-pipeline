# Patches one experimental audio/timing field per clip so a single load tells us
# which of them VideoPad's parser actually absorbs (and what it re-emits).
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

# Each entry: the *trackclip* whose offset selects the clip, plus field edits to
# apply to that clip's trackclip records and to the two effectchains records
# (video handle first, then its hlinked audio handle).
$cases = @(
    @{ Offset = 0;     Note = 'baseline' }
    @{ Offset = 3000;  Note = 'volume 50/50';            Ec = @{ voll = '50'; volr = '50' } }
    @{ Offset = 6000;  Note = 'volume -6/-6';            Ec = @{ voll = '-6'; volr = '-6' } }
    @{ Offset = 9000;  Note = 'speed 2x';                Ec = @{ speedchangef = '2.000000' } }
    @{ Offset = 12000; Note = 'fadeinduration 1000';     Tc = @{ fadeinduration = '1000' } }
    @{ Offset = 15000; Note = 'fadepoints 2';            Ec = @{ fadepoints = '2' } }
)

$lines = [IO.File]::ReadAllLines($Source)
$offsetToHandles = @{}
$videoToAudio = @{}

foreach ($l in $lines) {
    if ($l -notmatch '^h=\d+&type=7&') { continue }
    $offset = [int64]([regex]::Match($l, '(^|&)offset=(-?\d+)').Groups[2].Value)
    $h = [int64]([regex]::Match($l, '^h=(\d+)').Groups[1].Value)
    $link = [int64]([regex]::Match($l, '(^|&)hlinked=(\d+)').Groups[2].Value)
    $track = [int]([regex]::Match($l, '(^|&)htrack=(\d+)').Groups[2].Value)
    if (-not $offsetToHandles.ContainsKey($offset)) { $offsetToHandles[$offset] = @() }
    $offsetToHandles[$offset] += [pscustomobject]@{ H = $h; Track = $track }
    $videoToAudio[$h] = $link
}

for ($i = 0; $i -lt $lines.Count; $i++) {
    $l = $lines[$i]
    $case = $null

    if ($l -match '^h=\d+&type=7&') {
        $offset = [int64]([regex]::Match($l, '(^|&)offset=(-?\d+)').Groups[2].Value)
        $case = $cases | Where-Object { $_.Offset -eq $offset } | Select-Object -First 1
        if ($case -and $case.ContainsKey('Tc')) {
            foreach ($k in $case.Tc.Keys) { $l = Set-Field $l $k $case.Tc[$k] }
        }
    }
    elseif ($l -match '(^|&)hclip=\d+') {
        $hc = [int64]([regex]::Match($l, '(^|&)hclip=(\d+)').Groups[2].Value)
        # The clip is identified through the trackclip whose video handle owns
        # this effectchains row (audio rows are reached through hlinked).
        $owner = $null
        foreach ($off in $offsetToHandles.Keys) {
            foreach ($t in $offsetToHandles[$off]) {
                if ($t.Track -eq 12 -and ($t.H -eq $hc -or $videoToAudio[$t.H] -eq $hc)) {
                    $owner = $off; break
                }
            }
            if ($null -ne $owner) { break }
        }
        if ($null -ne $owner) {
            $case = $cases | Where-Object { $_.Offset -eq $owner } | Select-Object -First 1
            if ($case -and $case.ContainsKey('Ec')) {
                foreach ($k in $case.Ec.Keys) { $l = Set-Field $l $k $case.Ec[$k] }
            }
        }
    }
    $lines[$i] = $l
}

[IO.File]::WriteAllLines($Destination, $lines)

# Report what went in, so the diff against the round-trip is unambiguous.
foreach ($c in $cases) {
    $handles = @($offsetToHandles[[int64]$c.Offset] | ForEach-Object { $_.H }) -join ','
    '{0,6} ms  {1,-22} handles {2}' -f $c.Offset, $c.Note, $handles
}
