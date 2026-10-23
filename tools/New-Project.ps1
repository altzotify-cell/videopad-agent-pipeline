<#
.SYNOPSIS
    Builds a VideoPad .vpj project by re-cutting a template project.

.DESCRIPTION
    VideoPad's .vpj is a plain-text, LF-terminated, sectioned querystring file
    (see docs/vpj-format-findings.md). Rather than synthesizing one from nothing,
    this script edits a known-good template so that every field we do not
    understand is preserved byte-for-byte.

    v2 can add and remove timeline clips, so it is no longer limited to one
    segment per source:

      * rename the sequence
      * trim every segment (per-segment in/out, milliseconds)
      * reorder, drop clips, and reuse a source any number of times
      * add new media files, measured with ffprobe
      * mute individual segments

    New objects need handles. v2 allocates them from the project's hindex counter
    (bumped past the allocations) and clones the records VideoPad requires for
    each one: a type=7 video/audio trackclip pair plus one effectchains line per
    handle. Clips that are no longer used have their trackclip *and* effectchain
    records removed, so nothing is left orphaned on the timeline.

    Media records in the bin are never deleted: an unused source simply has no
    timeline clip, which is what the app itself produces when a clip is deleted.

    Audio/video trackclip pairs are kept in lockstep via hlinked, timeline
    offsets are recomputed, and the sequence duration is set to the exact sum of
    the trims (VideoPad stores duration = sum of clip lengths).

    The trailing checksum= line is intentionally left stale. VideoPad then shows
    the "Damaged File / Try Load" prompt, which tools/Open-Project.ps1 answers
    automatically - so there is no need to reproduce NCH's hash function.

.PARAMETER Spec
    Path to a JSON spec:

        {
          "template": "C:\\Users\\user\\Documents\\probe.vpj",
          "output":   "C:\\...\\out\\cut2.vpj",
          "sequenceName": "Agent Cut",
          "media": [ { "id": "bars", "path": "C:\\...\\bars.mp4" } ],
          "segments": [
            { "source": 1, "start": 0,      "end": 90000  },
            { "source": 1, "start": 300000, "end": 330000 },
            { "source": "bars", "start": 1000, "end": 9000, "mute": true }
          ]
        }

    "source" is an integer index into the template's distinct sources in timeline
    order, or the "id" of an entry in "media". "start"/"end" are milliseconds
    within that source; "mute" is optional and defaults to false.

.OUTPUTS
    PSCustomObject: Output, DurationMs, SequenceName, SourceCount, SegmentCount,
    AllocatedHandles, MediaAdded, Clips

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

# Relative paths in a spec resolve against the spec's own folder, so specs stay
# portable between machines and checkouts.
$specDir = Split-Path -Parent (Resolve-Path -LiteralPath $Spec).Path
function Resolve-SpecPath {
    param([string]$Path)
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $specDir $Path))
}
$s.template = Resolve-SpecPath $s.template
$s.output = Resolve-SpecPath $s.output
if ($s.PSObject.Properties.Name -contains 'media' -and $s.media) {
    foreach ($m in @($s.media)) { if ($m.path) { $m.path = Resolve-SpecPath $m.path } }
}

foreach ($key in @('template', 'output', 'segments')) {
    if ($s.PSObject.Properties.Name -notcontains $key) { throw "Spec is missing required key '$key'." }
}
if (-not (Test-Path -LiteralPath $s.template)) { throw "Template not found: $($s.template)" }
if (@($s.segments).Count -eq 0) { throw 'Spec has no segments.' }

$outDir = Split-Path -Parent $s.output
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}

# --- querystring field helpers ----------------------------------------------
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

function Get-MediaProbe {
    param([string]$Path)
    if (-not (Get-Command ffprobe -ErrorAction SilentlyContinue)) {
        throw "ffprobe is not on PATH, so added media cannot be measured. Add a 'duration' (ms) to the media entry to skip probing."
    }
    $json = & ffprobe -v error -print_format json -show_format -show_streams $Path 2>$null | Out-String
    try { $p = $json | ConvertFrom-Json } catch { throw "ffprobe produced unreadable output for $Path" }
    $sec = 0.0
    if ($p.format -and $p.format.duration) { $sec = [double]$p.format.duration }
    if ($sec -le 0) { throw "ffprobe reports no duration for $Path" }
    $hasAudio = @($p.streams | Where-Object { $_.codec_type -eq 'audio' }).Count -gt 0
    [pscustomobject]@{ OutMs = [int64][math]::Round($sec * 1000); HasAudio = $hasAudio }
}

# --- read the template and map its sections ---------------------------------
# Reassembly is driven by the <key>=<count> lines, so everything this writer does
# not model (the glued Type=2SubtitlesExport field, the stray CR, export blobs)
# is copied through untouched.
$text = [IO.File]::ReadAllText($s.template)
$Lines = [System.Collections.ArrayList]@($text -split "`n")

$sectionKeys = @('folders', 'clips', 'tracks', 'trackclips', 'subtitletracks', 'subtitleclips', 'transitions', 'effectchains', 'groups', 'bookmarks')
$sections = @{}
foreach ($k in $sectionKeys) {
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $m = [regex]::Match($Lines[$i], '^' + $k + '=(\d+)(.*)$')
        if ($m.Success) {
            $sections[$k] = [pscustomobject]@{
                Key    = $k
                Index  = $i
                Count  = [int]$m.Groups[1].Value
                Suffix = $m.Groups[2].Value
            }
            break
        }
    }
    if (-not $sections.ContainsKey($k)) { throw "Template has no '$k=' section." }
}

function Get-SectionBody {
    param([string]$Key)
    $sec = $sections[$Key]
    $items = @()
    for ($i = 1; $i -le $sec.Count; $i++) { $items += $Lines[$sec.Index + $i] }
    return , $items
}

# --- project bin: the sequence record plus media records --------------------
$clipsBody = Get-SectionBody 'clips'
$mediaByH = @{}
$seqH = $null
for ($i = 0; $i -lt $clipsBody.Count; $i++) {
    $l = $clipsBody[$i]
    $h = Get-Field $l 'h'
    if (-not $h) { throw "Template clip record without an h= field: $l" }
    if ((Get-Field $l 'type') -eq '6') { $seqH = $h; continue }
    $mediaByH[$h] = [pscustomobject]@{
        H        = [int64]$h
        Type     = Get-Field $l 'type'
        Name     = Get-Field $l 'name'
        Path     = Get-Field $l 'path'
        OutMs    = [int64](Get-Field $l 'out')
        Hlinked  = Get-Field $l 'hlinked'
        Creation = Get-Field $l 'creationtime'
        Line     = $l
    }
}
if (-not $seqH) { throw 'Template has no sequence record (h=<n>&type=6&...) in the clips section.' }

# --- tracks and the existing timeline clips --------------------------------
$videoTrackH = $null
$audioTrackH = $null
foreach ($l in (Get-SectionBody 'tracks')) {
    $t = Get-Field $l 'type'
    $h = Get-Field $l 'h'
    if ($t -eq '1' -and -not $videoTrackH) { $videoTrackH = $h }
    if ($t -eq '2' -and -not $audioTrackH) { $audioTrackH = $h }
}
if (-not $videoTrackH) { throw 'Template has no video track (type=1).' }

$tcBody = Get-SectionBody 'trackclips'
$videoClips = @()
$audioClipFor = @{}
$audioPrototype = $null
for ($i = 0; $i -lt $tcBody.Count; $i++) {
    $l = $tcBody[$i]
    if ($l -notmatch '^h=\d+&type=7&') { continue }
    $track = Get-Field $l 'htrack'
    if ($track -eq $videoTrackH) {
        $videoClips += [pscustomobject]@{
            BodyIndex = $i
            H         = [int64](Get-Field $l 'h')
            Orig      = [int64](Get-Field $l 'horiginalclip')
            Offset    = [int64](Get-Field $l 'offset')
        }
    }
    elseif ($audioTrackH -and $track -eq $audioTrackH) {
        if ($null -eq $audioPrototype) { $audioPrototype = $l }
        $linked = Get-Field $l 'hlinked'
        if ($linked) {
            $audioClipFor[$linked] = [pscustomobject]@{
                BodyIndex = $i
                H         = [int64](Get-Field $l 'h')
                Orig      = [int64](Get-Field $l 'horiginalclip')
            }
        }
    }
}
if ($videoClips.Count -eq 0) { throw 'Template has no video trackclips on the video track.' }
if ($null -eq $audioPrototype) { throw 'Template has no audio trackclip to clone; an A/V template is required.' }
$videoClips = @($videoClips | Sort-Object Offset)
$videoPrototype = $tcBody[$videoClips[0].BodyIndex]

# --- sources: template sources in timeline order, then free pairs to reuse ---
$sourceList = @()
foreach ($vc in $videoClips) {
    $key = [string]$vc.Orig
    if ($sourceList -notcontains $key) { $sourceList += $key }
}

$pairs = @()
foreach ($vc in $videoClips) {
    $a = $audioClipFor["$($vc.H)"]
    $pairs += [pscustomobject]@{
        VideoH   = $vc.H
        VideoIdx = $vc.BodyIndex
        AudioH   = $(if ($a) { $a.H } else { $null })
        AudioIdx = $(if ($a) { $a.BodyIndex } else { $null })
        Orig     = [int64]$vc.Orig
        Used     = $false
    }
}

# --- handle allocation: above hindex and above every handle already present --
$maxH = 0
$declaredHindex = 0
foreach ($l in $Lines) {
    $mh = [regex]::Match($l, '^h=(\d+)&')
    if ($mh.Success) { $v = [int64]$mh.Groups[1].Value; if ($v -gt $maxH) { $maxH = $v } }
    $mi = [regex]::Match($l, '^hindex=(\d+)')
    if ($mi.Success) { $declaredHindex = [int64]$mi.Groups[1].Value }
}
$script:NextHandle = [Math]::Max($declaredHindex, $maxH + 1)
$script:Allocated = 0
function New-Handle {
    $h = $script:NextHandle
    $script:NextHandle = $h + 1
    $script:Allocated = $script:Allocated + 1
    return $h
}

# --- media the spec wants added to the bin ---------------------------------
$mediaSpecs = @{}
if ($s.PSObject.Properties.Name -contains 'media' -and $s.media) {
    foreach ($m in @($s.media)) {
        $id = [string]$m.id
        if (-not $id) { throw "Every 'media' entry needs an 'id'." }
        if (-not $m.path) { throw "Media '$id' needs a 'path'." }
        if ($mediaSpecs.ContainsKey($id)) { throw "Duplicate media id '$id'." }
        if (-not (Test-Path -LiteralPath $m.path)) { throw "Media file not found: $($m.path)" }
        $mediaSpecs[$id] = $m
    }
}

$addedMedia = @{}
$addedOrder = New-Object System.Collections.ArrayList

function Resolve-Source {
    param($Key)

    $asId = [string]$Key
    if ($mediaSpecs.ContainsKey($asId)) {
        if (-not $addedMedia.ContainsKey($asId)) {
            $spec = $mediaSpecs[$asId]
            if ($spec.PSObject.Properties.Name -contains 'duration' -and $spec.duration) {
                $outMs = [int64]$spec.duration
            }
            else {
                $probe = Get-MediaProbe -Path $spec.path
                $outMs = $probe.OutMs
                if (-not $probe.HasAudio) {
                    throw "Media '$asId' has no audio stream. v2 adds media as an A/V pair, so an audio-less file is not supported yet."
                }
            }
            $leaf = Split-Path -Leaf $spec.path
            $created = [int64]((Get-Item -LiteralPath $spec.path).CreationTime.ToUniversalTime() - [datetime]'1970-01-01').TotalSeconds
            $addedMedia[$asId] = [pscustomobject]@{
                Id       = $asId
                AudioH   = (New-Handle)   # audio record first, matching the app's own ordering
                VideoH   = (New-Handle)
                Name     = $leaf
                EncName  = [System.Uri]::EscapeDataString($leaf)
                EncPath  = [System.Uri]::EscapeDataString($spec.path)
                OutMs    = $outMs
                Creation = $created
            }
            [void]$addedOrder.Add($asId)
        }
        $a = $addedMedia[$asId]
        return [pscustomobject]@{
            Kind = 'added'; Key = $asId; Name = $a.Name; EncName = $a.EncName
            VideoMediaH = $a.VideoH; AudioMediaH = $a.AudioH; OutMs = $a.OutMs
        }
    }

    if ($asId -notmatch '^\d+$') {
        throw "Segment references unknown source '$asId': it is neither a template index nor a media id."
    }
    $idx = [int]$asId
    if ($idx -lt 0 -or $idx -ge $sourceList.Count) {
        throw "Segment references source $idx, but only 0..$($sourceList.Count - 1) exist."
    }
    $vH = $sourceList[$idx]
    $rec = $mediaByH[$vH]
    if (-not $rec) { throw "Template source $idx points at handle $vH, which has no media record." }
    return [pscustomobject]@{
        Kind        = 'template'
        Key         = $idx
        Name        = $(try { [System.Uri]::UnescapeDataString($rec.Name) } catch { $rec.Name })
        EncName     = $rec.Name
        VideoMediaH = [int64]$vH
        AudioMediaH = $(if ($rec.Hlinked) { [int64]$rec.Hlinked } else { $null })
        OutMs       = $rec.OutMs
    }
}

# --- lay the segments out end to end ---------------------------------------
$plan = @()
$cursor = [int64]0
foreach ($seg in @($s.segments)) {
    if ($seg.PSObject.Properties.Name -notcontains 'source') { throw 'Every segment needs a "source".' }
    $src = Resolve-Source -Key $seg.source

    $start = [int64]$seg.start
    $end = [int64]$seg.end
    if ($start -lt 0) { throw "Segment for source '$($seg.source)' has a negative start." }
    if ($end -le $start) { throw "Segment for source '$($seg.source)' has end <= start." }
    if ($end -gt $src.OutMs) {
        throw "Segment for source '$($seg.source)' ends at $end ms but the source is only $($src.OutMs) ms long."
    }
    $mute = $false
    if ($seg.PSObject.Properties.Name -contains 'mute' -and $seg.mute) { $mute = $true }

    # Reuse an existing pair when this source still has an unused one, so a spec
    # that never repeats a source rewrites the template in place (byte-identical
    # to v1 output). Otherwise allocate a fresh pair of handles.
    $reuse = @($pairs | Where-Object { (-not $_.Used) -and $_.Orig -eq $src.VideoMediaH }) | Select-Object -First 1
    if ($reuse) {
        $reuse.Used = $true
        $videoH = [int64]$reuse.VideoH
        $audioH = $(if ($null -ne $reuse.AudioH) { [int64]$reuse.AudioH } else { $null })
        $videoIdx = [int]$reuse.VideoIdx
        $audioIdx = $reuse.AudioIdx
        $isNew = $false
    }
    else {
        $videoH = [int64](New-Handle)
        $audioH = [int64](New-Handle)
        $videoIdx = -1
        $audioIdx = $null
        $isNew = $true
    }

    $plan += [pscustomobject]@{
        SourceKey    = $seg.source
        Name         = $src.Name
        EncName      = $src.EncName
        VideoMediaH  = $src.VideoMediaH
        AudioMediaH  = $src.AudioMediaH
        StartMs      = $start
        EndMs        = $end
        LengthMs     = ($end - $start)
        OffsetMs     = $cursor
        Mute         = $mute
        VideoH       = $videoH
        AudioH       = $audioH
        VideoIdx     = $videoIdx
        AudioIdx     = $audioIdx
        IsNew        = $isNew
        IsAddedMedia = ($src.Kind -eq 'added')
    }
    $cursor += ($end - $start)
}

# --- rewrite the timeline: reused clips are edited in place ------------------
$keepIdx = @{}
$newTcLines = @()
foreach ($p in $plan) {
    if (-not $p.IsNew) {
        $vl = Set-Field $tcBody[$p.VideoIdx] 'in' ([string]$p.StartMs)
        $vl = Set-Field $vl 'out' ([string]$p.EndMs)
        $vl = Set-Field $vl 'offset' ([string]$p.OffsetMs)
        $tcBody[$p.VideoIdx] = $vl
        $keepIdx[$p.VideoIdx] = $true

        if ($null -ne $p.AudioIdx) {
            $al = Set-Field $tcBody[$p.AudioIdx] 'in' ([string]$p.StartMs)
            $al = Set-Field $al 'out' ([string]$p.EndMs)
            $al = Set-Field $al 'offset' ([string]$p.OffsetMs)
            $tcBody[$p.AudioIdx] = $al
            $keepIdx[$p.AudioIdx] = $true
        }
        continue
    }

    $vl = Set-Field $videoPrototype 'h' ([string]$p.VideoH)
    $vl = Set-Field $vl 'horiginalclip' ([string]$p.VideoMediaH)
    $vl = Set-Field $vl 'hlinked' ([string]$p.AudioH)
    $vl = Set-Field $vl 'name' ([string]$p.EncName)
    $vl = Set-Field $vl 'in' ([string]$p.StartMs)
    $vl = Set-Field $vl 'out' ([string]$p.EndMs)
    $vl = Set-Field $vl 'offset' ([string]$p.OffsetMs)
    $newTcLines += $vl

    $al = Set-Field $audioPrototype 'h' ([string]$p.AudioH)
    $al = Set-Field $al 'horiginalclip' ([string]$p.AudioMediaH)
    $al = Set-Field $al 'hlinked' ([string]$p.VideoH)
    $al = Set-Field $al 'name' ([string]$p.EncName)
    $al = Set-Field $al 'in' ([string]$p.StartMs)
    $al = Set-Field $al 'out' ([string]$p.EndMs)
    $al = Set-Field $al 'offset' ([string]$p.OffsetMs)
    $newTcLines += $al
}

$tcBodyNew = @()
for ($i = 0; $i -lt $tcBody.Count; $i++) {
    if ($keepIdx.ContainsKey($i)) { $tcBodyNew += $tcBody[$i] }
}
$tcBodyNew += $newTcLines

# --- effectchains: exactly one record per clip, sequence and media handle ---
$ecBody = Get-SectionBody 'effectchains'
if ($ecBody.Count -eq 0) { throw 'Template has no effectchains records to clone.' }
$ecPrototype = $ecBody[0]

$muteFor = @{}
$ecKeep = @{}
foreach ($p in $plan) {
    if ($null -ne $p.VideoH) { $muteFor[[string]$p.VideoH] = $p.Mute; $ecKeep[[string]$p.VideoH] = $true }
    if ($null -ne $p.AudioH) { $muteFor[[string]$p.AudioH] = $p.Mute; $ecKeep[[string]$p.AudioH] = $true }
}
foreach ($h in $mediaByH.Keys) { $ecKeep[[string]$h] = $true }   # bin media keep theirs
$ecKeep[[string]$seqH] = $true

$ecBodyNew = @()
foreach ($l in $ecBody) {
    $hc = [string](Get-Field $l 'hclip')
    if (-not $ecKeep.ContainsKey($hc)) { continue }   # clip was dropped
    if ($muteFor.ContainsKey($hc)) {
        $l = Set-Field $l 'mute' $(if ($muteFor[$hc]) { '1' } else { '0' })
    }
    $ecBodyNew += $l
}
foreach ($p in $plan) {
    if (-not $p.IsNew) { continue }
    foreach ($h in @($p.VideoH, $p.AudioH)) {
        if ($null -eq $h) { continue }
        $l = Set-Field $ecPrototype 'hclip' ([string]$h)
        $l = Set-Field $l 'mute' $(if ($p.Mute) { '1' } else { '0' })
        $ecBodyNew += $l
    }
}
foreach ($id in $addedOrder) {
    $a = $addedMedia[$id]
    foreach ($h in @($a.AudioH, $a.VideoH)) {
        $l = Set-Field $ecPrototype 'hclip' ([string]$h)
        $l = Set-Field $l 'mute' '0'
        $ecBodyNew += $l
    }
}

# --- bin: append media records for anything new -----------------------------
$vProto = @($mediaByH.Values | Where-Object { $_.Type -eq '3' }) | Select-Object -First 1
if (-not $vProto) { throw 'Template has no video media record (type=3) to clone when adding media.' }
$aProto = $null
if ($vProto.Hlinked -and $mediaByH.ContainsKey($vProto.Hlinked)) { $aProto = $mediaByH[$vProto.Hlinked] }
if (-not $aProto) { $aProto = @($mediaByH.Values | Where-Object { $_.Type -eq '5' }) | Select-Object -First 1 }
if (-not $aProto) { throw 'Template has no audio media record (type=5) to clone when adding media.' }

$clipsBodyNew = @()
$seqNameEnc = $null
foreach ($l in $clipsBody) {
    if ((Get-Field $l 'h') -eq $seqH) {
        $l = Set-Field $l 'in' '0'
        $l = Set-Field $l 'out' ([string]$cursor)
        $l = Set-Field $l 'duration' ([string]$cursor)
        if ($s.PSObject.Properties.Name -contains 'sequenceName' -and $s.sequenceName) {
            $l = Set-Field $l 'name' ([System.Uri]::EscapeDataString($s.sequenceName))
        }
        $seqNameEnc = Get-Field $l 'name'
    }
    $clipsBodyNew += $l
}
foreach ($id in $addedOrder) {
    $a = $addedMedia[$id]

    $al = Set-Field $aProto.Line 'h' ([string]$a.AudioH)
    $al = Set-Field $al 'hlinked' ([string]$a.VideoH)
    $al = Set-Field $al 'name' $a.EncName
    $al = Set-Field $al 'path' $a.EncPath
    $al = Set-Field $al 'creationtime' ([string]$a.Creation)
    $al = Set-Field $al 'in' '0'
    $al = Set-Field $al 'out' ([string]$a.OutMs)
    $clipsBodyNew += $al

    $vl = Set-Field $vProto.Line 'h' ([string]$a.VideoH)
    $vl = Set-Field $vl 'hlinked' ([string]$a.AudioH)
    $vl = Set-Field $vl 'name' $a.EncName
    $vl = Set-Field $vl 'path' $a.EncPath
    $vl = Set-Field $vl 'creationtime' ([string]$a.Creation)
    $vl = Set-Field $vl 'in' '0'
    $vl = Set-Field $vl 'out' ([string]$a.OutMs)
    $clipsBodyNew += $vl
}

# --- reassemble: rebuilt sections, everything else copied verbatim ----------
$rebuilt = @{
    'clips'        = $clipsBodyNew
    'trackclips'   = $tcBodyNew
    'effectchains' = $ecBodyNew
}
$out = New-Object System.Collections.Generic.List[string]
for ($i = 0; $i -lt $Lines.Count; $i++) {
    $secKey = $null
    foreach ($k in $sectionKeys) {
        if ($sections[$k].Index -eq $i) { $secKey = $k; break }
    }
    if ($null -eq $secKey) { $out.Add([string]$Lines[$i]); continue }

    $sec = $sections[$secKey]
    if ($rebuilt.ContainsKey($secKey)) {
        $body = @($rebuilt[$secKey])
        $out.Add($secKey + '=' + $body.Count + $sec.Suffix)
        foreach ($l in $body) { $out.Add([string]$l) }
    }
    else {
        $out.Add($secKey + '=' + $sec.Count + $sec.Suffix)
        for ($j = 1; $j -le $sec.Count; $j++) { $out.Add([string]$Lines[$sec.Index + $j]) }
    }
    $i += $sec.Count
}

if ($script:Allocated -gt 0) {
    for ($i = 0; $i -lt $out.Count; $i++) {
        if ($out[$i] -match '^hindex=\d+') { $out[$i] = 'hindex=' + $script:NextHandle; break }
    }
}

# --- integrity checks -------------------------------------------------------
$originalCount = $Lines.Count
$droppedClips = @($pairs | Where-Object { -not $_.Used }).Count
if ($script:Allocated -eq 0 -and $droppedClips -eq 0 -and $out.Count -ne $originalCount) {
    throw "Internal error: line count changed from $originalCount to $($out.Count) with nothing allocated or dropped."
}

$handleSeen = @{}
foreach ($l in $out) {
    $mh = [regex]::Match($l, '^h=(\d+)&')
    if (-not $mh.Success) { continue }
    $h = $mh.Groups[1].Value
    if ($handleSeen.ContainsKey($h)) { throw "Internal error: handle $h is used by two records." }
    $handleSeen[$h] = $true
}

$ecSeen = @{}
foreach ($l in $ecBodyNew) {
    $hc = [string](Get-Field $l 'hclip')
    if ($ecSeen.ContainsKey($hc)) { throw "Internal error: two effectchains records for handle $hc." }
    $ecSeen[$hc] = $true
}
foreach ($p in $plan) {
    foreach ($h in @($p.VideoH, $p.AudioH)) {
        if ($null -eq $h) { continue }
        if (-not $ecSeen.ContainsKey([string]$h)) {
            throw "Internal error: timeline clip $h has no effectchains record."
        }
    }
}

$checksumBefore = @($text -split "`n" | Where-Object { $_ -match '^checksum=' })[0]
$checksumAfter = @($out | Where-Object { $_ -match '^checksum=' })[0]
if ($checksumBefore -ne $checksumAfter) { throw 'Internal error: checksum line was modified.' }

[IO.File]::WriteAllText($s.output, ($out -join "`n"), [Text.Encoding]::ASCII)

$seqName = ''
if ($seqNameEnc) {
    try { $seqName = [System.Uri]::UnescapeDataString($seqNameEnc) } catch { $seqName = $seqNameEnc }
}

[pscustomobject]@{
    Output           = $s.output
    DurationMs       = $cursor
    SequenceName     = $seqName
    SourceCount      = $sourceList.Count
    SegmentCount     = @($plan).Count
    DroppedClips     = $droppedClips
    AllocatedHandles = $script:Allocated
    MediaAdded       = @($addedOrder).Count
    Clips            = @($plan | ForEach-Object {
            [pscustomobject]@{
                Source      = $_.SourceKey
                Name        = $_.Name
                StartMs     = $_.StartMs
                EndMs       = $_.EndMs
                LengthMs    = $_.LengthMs
                OffsetMs    = $_.OffsetMs
                Mute        = $_.Mute
                VideoHandle = $_.VideoH
                AudioHandle = $_.AudioH
                ReusedPair  = (-not $_.IsNew)
            }
        })
}





