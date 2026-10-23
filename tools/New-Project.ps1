<#
.SYNOPSIS
    Builds a VideoPad .vpj project by re-cutting a template project.

.DESCRIPTION
    VideoPad's .vpj is a plain-text, LF-terminated, sectioned querystring file
    (see docs/vpj-format-findings.md). Rather than synthesizing one from
    nothing, this script edits a known-good template so that every field we do
    not understand is preserved byte-for-byte.

    v1 supports the operations an auto-editor needs most, without ever adding
    or removing handles:

      * rename the sequence
      * trim every source clip (per-clip in/out, milliseconds)
      * reorder the clips on the timeline

    Each source must appear exactly once in the segment list. Duplicating a
    source (so a clip is used twice) requires allocating new handles and
    cloning effect-chain records, which v1 deliberately refuses.

    Audio/video trackclip pairs are kept in lockstep via their hlinked field,
    timeline offsets are recomputed, and the sequence duration is set to the
    exact sum of the trims (VideoPad stores duration = sum of clip lengths).

    The trailing checksum= line is intentionally left stale. VideoPad then
    shows the "Damaged File / Try Load" prompt, which
    tools/Open-Project.ps1 answers automatically - so there is no need to
    reproduce NCH's hash function.

.PARAMETER Spec
    Path to a JSON spec:

        {
          "template": "C:\\Users\\user\\Documents\\probe.vpj",
          "output":   "C:\\Users\\user\\Downloads\\videopad\\out\\cut1.vpj",
          "sequenceName": "Agent Cut",
          "segments": [
            { "source": 0, "start": 0,      "end": 60000  },
            { "source": 1, "start": 120000, "end": 240000 }
          ]
        }

    "source" indexes the template's distinct sources in timeline order,
    "start"/"end" are milliseconds within that source.

.OUTPUTS
    PSCustomObject: Output, DurationMs, Sources, SegmentCount, SequenceName

.EXAMPLE
    .\New-Project.ps1 -Spec .\examples\cut1.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Spec
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Spec)) { throw "Spec not found: $Spec" }
$s = Get-Content -LiteralPath $Spec -Raw | ConvertFrom-Json

foreach ($key in @('template', 'output', 'segments')) {
    if ($s.PSObject.Properties.Name -notcontains $key) { throw "Spec is missing required key '$key'." }
}
if (-not (Test-Path -LiteralPath $s.template)) { throw "Template not found: $($s.template)" }

$outDir = Split-Path -Parent $s.output
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}

function Get-Field {
    param([string]$Line, [string]$Key)
    $m = [regex]::Match($Line, '(^|&)' + [regex]::Escape($Key) + '=([^&]*)')
    if ($m.Success) { return $m.Groups[2].Value }
    return $null
}

function Set-Field {
    param([string]$Line, [string]$Key, [string]$Value)
    $pattern = '(^|&)' + [regex]::Escape($Key) + '=[^&]*'
    if ([regex]::IsMatch($Line, $pattern)) {
        return [regex]::Replace($Line, $pattern, { param($m) $m.Groups[1].Value + $Key + '=' + $Value }, 1)
    }
    return $Line + '&' + $Key + '=' + $Value
}

function Get-CountLineIndex {
    param([string]$Key)
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match ('^' + [regex]::Escape($Key) + '=\d+')) { return $i }
    }
    return -1
}

$text = [IO.File]::ReadAllText($s.template)
$Lines = [System.Collections.ArrayList]@($text -split "`n")
$originalCount = $Lines.Count

# --- locate the structural anchors -------------------------------------------
$seqIdx = -1
for ($i = 0; $i -lt $Lines.Count; $i++) {
    if ($Lines[$i] -match '^h=\d+&type=6&') { $seqIdx = $i; break }
}
if ($seqIdx -lt 0) { throw 'Template has no sequence record (h=<n>&type=6&...).' }

$videoTrackH = $null
$audioTrackH = $null
for ($i = 0; $i -lt $Lines.Count; $i++) {
    if ($null -eq $videoTrackH -and $Lines[$i] -match '^h=\d+&type=1&') { $videoTrackH = Get-Field $Lines[$i] 'h' }
    if ($null -eq $audioTrackH -and $Lines[$i] -match '^h=\d+&type=2&') { $audioTrackH = Get-Field $Lines[$i] 'h' }
}
if ($null -eq $videoTrackH) { throw 'Template has no video track (type=1).' }

$vclips = @()
$audioLineFor = @{}
for ($i = 0; $i -lt $Lines.Count; $i++) {
    if ($Lines[$i] -notmatch '^h=\d+&type=7&') { continue }
    $track = Get-Field $Lines[$i] 'htrack'
    if ($track -eq $videoTrackH) {
        $vclips += [pscustomobject]@{
            Index  = $i
            H      = (Get-Field $Lines[$i] 'h')
            Orig   = (Get-Field $Lines[$i] 'horiginalclip')
            Offset = [int64](Get-Field $Lines[$i] 'offset')
        }
    }
    elseif ($null -ne $audioTrackH -and $track -eq $audioTrackH) {
        $linked = Get-Field $Lines[$i] 'hlinked'
        if ($linked) { $audioLineFor[$linked] = $i }
    }
}
if ($vclips.Count -eq 0) { throw 'Template has no video trackclips on the video track.' }

$vclips = @($vclips | Sort-Object Offset)

$sources = @($vclips | ForEach-Object { $_.Orig })
$distinct = @($sources | Select-Object -Unique)
if ($distinct.Count -ne $sources.Count) {
    throw "Template already reuses a source ($($sources.Count) clips across $($distinct.Count) sources); v1 supports one segment per source."
}

$segments = @($s.segments)
if ($segments.Count -ne $distinct.Count) {
    throw "Spec has $($segments.Count) segment(s) but the template has $($distinct.Count) distinct source(s); v1 requires exactly one segment per source."
}
$seen = @{}
foreach ($seg in $segments) {
    $idx = [int]$seg.source
    if ($idx -lt 0 -or $idx -ge $distinct.Count) { throw "Segment references source $idx, but only 0..$($distinct.Count - 1) exist." }
    if ($seen.ContainsKey($idx)) { throw "Source $idx appears in more than one segment; v1 cannot duplicate a source." }
    $seen[$idx] = $true
    if ([int64]$seg.end -le [int64]$seg.start) { throw "Segment for source $idx has end <= start." }
}

# --- apply: trim, then lay the clips end-to-end in spec order ----------------
$report = @()
$cursor = [int64]0

foreach ($seg in $segments) {
    $srcH = $distinct[[int]$seg.source]
    $start = [int64]$seg.start
    $end = [int64]$seg.end

    $mediaIdx = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match ('^h=' + [regex]::Escape($srcH) + '&')) { $mediaIdx = $i; break }
    }
    if ($mediaIdx -lt 0) { throw "Template has no media record for handle $srcH." }
    $srcOut = [int64](Get-Field $Lines[$mediaIdx] 'out')
    if ($end -gt $srcOut) {
        throw "Segment for source $($seg.source) ends at $end ms but the source is only $srcOut ms long."
    }

    $vc = $vclips | Where-Object { $_.Orig -eq $srcH } | Select-Object -First 1
    $targets = @($vc.Index)
    if ($audioLineFor.ContainsKey($vc.H)) { $targets += $audioLineFor[$vc.H] }

    foreach ($li in $targets) {
        $Lines[$li] = Set-Field $Lines[$li] 'in' ([string]$start)
        $Lines[$li] = Set-Field $Lines[$li] 'out' ([string]$end)
        $Lines[$li] = Set-Field $Lines[$li] 'offset' ([string]$cursor)
    }

    $mediaName = Get-Field $Lines[$mediaIdx] 'name'
    try { $mediaName = [System.Uri]::UnescapeDataString($mediaName) } catch { }

    $report += [pscustomobject]@{
        Source   = [int]$seg.source
        Name     = $mediaName
        StartMs  = $start
        EndMs    = $end
        LengthMs = ($end - $start)
        OffsetMs = $cursor
    }
    $cursor += ($end - $start)
}

# --- sequence record: VideoPad stores duration as the exact sum of the clips --
$Lines[$seqIdx] = Set-Field $Lines[$seqIdx] 'in' '0'
$Lines[$seqIdx] = Set-Field $Lines[$seqIdx] 'out' ([string]$cursor)
$Lines[$seqIdx] = Set-Field $Lines[$seqIdx] 'duration' ([string]$cursor)

$seqName = Get-Field $Lines[$seqIdx] 'name'
if ($s.PSObject.Properties.Name -contains 'sequenceName' -and $s.sequenceName) {
    $seqName = [System.Uri]::EscapeDataString($s.sequenceName)
    $Lines[$seqIdx] = Set-Field $Lines[$seqIdx] 'name' $seqName
}

# --- sanity: nothing added/removed, checksum deliberately left stale ---------
if ($Lines.Count -ne $originalCount) {
    throw "Internal error: line count changed from $originalCount to $($Lines.Count)."
}
$checksumBefore = $text -split "`n" | Where-Object { $_ -match '^checksum=' } | Select-Object -First 1
$checksumAfter = $Lines | Where-Object { $_ -match '^checksum=' } | Select-Object -First 1
if ($checksumBefore -ne $checksumAfter) { throw 'Internal error: checksum line was modified.' }

$outText = $Lines -join "`n"
[IO.File]::WriteAllText($s.output, $outText, [Text.Encoding]::ASCII)

[pscustomobject]@{
    Output       = $s.output
    DurationMs   = $cursor
    SequenceName = $(if ($seqName) { [System.Uri]::UnescapeDataString($seqName) } else { '' })
    SourceCount  = $distinct.Count
    SegmentCount = $segments.Count
    Clips        = $report
}

