# VideoPad 8.91 `.vpj` — agent-writability findings

**Verdict: an agent can write `.vpj` files and get them loaded unattended.**
The integrity check is an advisory modal, not a hard reject, and it can be
answered without focus or a human. The project can then be **exported**
unattended too — for the operational picture (commands, environment, UI
automation rules, open work) start at `docs/HANDOFF.md`; this file is the
format-level reference.

## Container format

- Sample project: 6,248 bytes, 43 lines.
- **LF (`\n`) line endings**, with one stray CR near the end. No BOM, no magic header.
- Line 0 is `version=11`.
- Section pattern: a `<key>=<count>` line followed by that many querystring lines.
- Values are URL-encoded (`%20`, `%3A%5C` for `C:\`, `%40` for `@`).
- Quirk to reproduce verbatim: line 37 begins `Type=2SubtitlesExport=1` — two
  fields glued together with no separator.
- `duration`/`out` appear to be **milliseconds** (2882166 ≈ 48.0 min for a
  two-episode sequence).

### Section map (line numbers from the sample)

| lines | content |
|---|---|
| 0 | `version=11` |
| 1 | `hindex=` (next-free handle counter; changes between saves) |
| 2–6 | `folders=4` + folder records (`Images`, `Audio Files`, `Video Files`, `Sequences`) |
| 7–12 | `clips=5` + sequence record (`type=6`, carries `name=`) + media/clip records (`h=`, `path=`) |
| 13–15 | `tracks=2` + track records (`type=2` audio, `type=1` video) |
| 16–20 | `trackclips=4` + per-clip timeline records (`horiginalclip=` points at the media handle) |
| 21–22 | `subtitletracks=1` + subtitle track |
| 23–24 | `subtitleclips=0`, `transitions=0` |
| 25–34 | `effectchains=9` + one line per clip/sequence (`hclip=`, speed, volume, mute, and `size=` effect slots) |
| 35–36 | `groups=0`, `bookmarks=0` |
| 37 | export settings blob |
| 38 | `EditOutput_*` settings |
| 39–40 | `wizardused=0`, `revision=565488` |
| 41 | `checksum=<64 lowercase hex>` |

The sequence name lives at line 8: `h=9&type=6&...&name=Sequence%201&note=&hfolder=5&duration=...`
Handles (`h=`) are arbitrary integers that must stay mutually consistent — media
handles are referenced by `horiginalclip=`, and `effectchains` reference `hclip=`.

## The checksum

- 64 lowercase hex, the last content line.
- It **is** verified on load. A mismatch raises a modal:

  > **Damaged File** — "The provided file may be damaged. Do you want to try to load it anyway?" — `[Try Load] [Cancel]`

- Clicking **Try Load** loads the file with all edits intact (verified twice:
  sequence renamed to `MODDED SEQ`, then to `Agent Test`).
- Therefore the hash is a **corruption warning, not a signature or DRM gate**.
  Recomputing NCH's hash is *not* required to write `.vpj` files.

## Unattended open recipe (verified end-to-end, 4.4 s)

1. Close any running instance with `WM_CLOSE` — VideoPad is single-instance and
   **silently drops the file argument** when another copy is already running.
   A modal open at that moment swallows the close (and each swallowed close spawns
   *another* prompt), so answer stale dialogs first: `Discard` on "The current
   project has been changed…", `No` on "New media has been connected…". Both are
   real `#32770` windows with real `Button`s that **UI Automation cannot see**, so
   they are found via `Get-PadWindows` + `EnumChildWindows`.
2. `videopad.exe "<absolute path>.vpj"` (only a *fresh* process honours the path).
3. Poll UI Automation for a descendant named `Damaged File`; post
   `WM_COMMAND (0x0111)` with `IDOK (1)` to that dialog's HWND.
4. The title flips to `<file>.vpj` → loaded.

Implemented in `tools/Open-Project.ps1`; the P/Invoke layer is `tools/NativeInput.cs`.

### What does *not* work (and why)

- **UI Automation.** Every UIA descendant of the main window is an unnamed
  `Pane`; nothing implements `InvokePattern`. VideoPad is a Delphi app with no
  MSAA/UIA provider, so UIA is a dead end. That is *not* the same as the UI
  having no real Win32 windows — see the export section, where dialogs turn out
  to expose ordinary named buttons.
- **Posted `WM_LBUTTONDOWN`/`WM_LBUTTONUP`** to the checksum dialog's panes: they
  are custom-drawn and ignore hit-test messages.
- **Synthetic mouse *without* DPI awareness.** This was long recorded as "blocked
  by the Windows foreground lock". That explanation was wrong. PowerShell is
  DPI-unaware by default, so `GetWindowRect` reports *logical* pixels while
  `CopyFromScreen`/`BitBlt` and `SetCursorPos` work in *physical* pixels; on a
  150% display every click was off by half the screen and the capture was cropped
  to the top-left two-thirds of the window. After `SetProcessDPIAware()` clicks
  land reliably and `ForceForeground` genuinely works (verified:
  `GetForegroundWindow() == hwnd` afterwards). See `tools/PadUi.ps1`.

`WM_COMMAND/IDOK` still works for the checksum dialog because **Try Load is that
dialog's default button**, and it avoids depending on coordinates at all.

## Gotchas

- **Never force-kill** VideoPad: it arms crash recovery ("Abnormal Termination"),
  which suppresses the CLI argument on the next start.
- `WM_CLOSE` is **swallowed** while a modal is open — dismiss the modal first.
- The timeline is custom-drawn; UIA exposes only ~65 elements and no clip text,
  so the window title is the reliable load indicator.
- The `.vpj` holds paths, not media. Referenced files must exist or clips resolve
  offline.

## Timeline field semantics (verified)

Trackclip record (`type=7`):

| field | meaning |
|---|---|
| `horiginalclip` | source media handle → a `type=3` (video) or `type=5` (audio) record |
| `htrack` | owning track handle → `type=1` video track, `type=2` audio track |
| `hlinked` | the paired clip on the other track (video ↔ audio) |
| `in` / `out` | trim window **inside the source**, milliseconds |
| `offset` | position **on the timeline**, milliseconds |
| `tlstart`/`tlend`/`tlstartoff`/`tlendoff` | `0` in every sample seen so far |

Sequence record (`type=6`): `duration` and `out` are the **exact sum of
(out - in) over its trackclips** — the sample's 2 × 1441083 = 2882166 to the
millisecond. Keep them in sync when trimming.

Audio and video clips of the same source are independent `type=7` records joined
by `hlinked`; they must be trimmed identically or A/V drifts.

**Records are addressed by handle, not by line position.** On save the app
re-emits `trackclips` and `effectchains` in its own internal order (the sample
came back as 392, 390, 391, 389 instead of 390, 392, 389, 391) while every
`offset`/`in`/`out` round-tripped unchanged. A writer may therefore keep the
template's order — and v2's appended records (allocated handles 3382…3387) came
back from the app unchanged too, so appending is safe.

**There is no split record.** A split clip is simply two (or more) `type=7` pairs
with the same `horiginalclip`, `out` of one equal to `in` of the next, and
`offset` continuing where the previous ended. `cut4-split-effects.vpj` writes a
6 s clip split at 2 s/4 s that way and the app re-saves it as a split — the
round-trip returns three adjacent pairs, not one pair plus a marker. No
GOP/keyframe alignment is needed: the trim window is expressed in source
milliseconds and the decoder seeks, so a cut in the middle of a GOP renders like
any other trim.

## The autosave oracle — verify an edit without exporting

`%APPDATA%\NCH Software\VideoPad\autosave.vpj` is rewritten roughly **3 seconds
after a project loads** (and on a slower periodic timer afterwards). It is a full
re-serialization of the in-memory project model, so it is a direct read-out of
what the parser actually absorbed — far cheaper than an export, and it works
around the fact that the timeline is custom-drawn and invisible to UIA.

This is how content fidelity was confirmed. A project produced by
`tools/New-Project.ps1` (renamed to `Agent Cut`, both clips trimmed, order
reversed) came back from autosave as:

```
name=Agent%20Cut&...&duration=210000&in=0&out=210000
...&horiginalclip=343&...&offset=0&in=0&out=90000
...&horiginalclip=325&...&offset=90000&in=60000&out=180000
```

i.e. byte-for-byte the numbers the writer wrote. `thumbpos` was also recomputed
(1440000 → 100000), which proves the app **rebuilt** the timeline from our
values instead of echoing the file back.

Across every comparison so far, only three lines differ between a file we wrote
and the app's re-serialization: `hindex` (app's handle counter), one folder
`open=` UI flag, and `checksum`. Everything else is preserved verbatim — so the
app's writer and this writer agree on the format.

`tools/Watch-Autosave.ps1` automates the loop: open (auto-dismissing the damaged
file prompt) → wait for the autosave refresh → capture it next to the log and
report the parsed sequence name, checksum and `hindex`.

## Writer: `tools/New-Project.ps1` (v3)

Takes a JSON spec and produces a `.vpj` by editing a known-good template, so
every field not explicitly modelled survives byte-for-byte. The template's
checksum is intentionally left stale; `Open-Project.ps1` answers the resulting
prompt in ~4 s.

```json
{
  "template": "probe.vpj",
  "output":   "../out/cut4-split-effects.vpj",
  "sequenceName": "Split + Effect Test",
  "media":    [ { "id": "bars", "path": "../out/testmedia/bars.mp4" } ],
  "defaultEffects": [ { "name": "saturation", "preset": "Completely Unsaturated" } ],
  "segments": [
    { "source": 1,      "start": 0,      "end": 6000,   "split": [ 2000, 4000 ] },
    { "source": "bars", "start": 0,      "end": 6000,   "split": [ 3000 ],
      "effects": [ { "name": "rotate", "params": { "z": 90 } } ] },
    { "source": 1,      "start": 900000, "end": 903000,
      "effects": [ { "name": "mirror", "params": { "mirrordirection": "vertical" } },
                   { "name": "colorAdjust", "preset": "Bright", "params": { "contrast": 60 } } ] }
  ]
}
```

`source` is a template source index (timeline order) or a `media` id; `start`/`end`
are milliseconds; paths resolve against the spec's folder. Segment order becomes
timeline order, so the list doubles as a reorder, a drop and a reuse. `split`
holds absolute source milliseconds strictly inside `start`/`end`.

**Handles.** `hindex` is the project's next-free counter and sits far above the
handles in use (3382 vs 392 in the sample). The writer allocates upward from
`max(hindex, max handle + 1)` and writes the bumped value back, so a project it
produced and the app then re-saved stays collision-free.

**Clips.** Each segment needs a `type=7` video/audio pair. A pair whose
`horiginalclip` matches the segment's source is reused when still free — that is
what keeps a one-segment-per-source spec byte-identical to the v1 output.
Otherwise the pair is cloned from the template's own prototype line, with `h`,
`horiginalclip`, `hlinked`, `name`, `offset`, `in`, `out` replaced. Pairs whose
clips are no longer wanted are **removed**, together with their `effectchains`
records: a `trackclips` record with no `effectchains` record (or the reverse)
would be a dangling reference, and leaving the clip in place would put a ghost
clip on the timeline.

**Media.** Adding a file means adding the pair VideoPad creates when a clip
is imported — an audio record and a video record pointing at the same `path`,
cross-linked by `hlinked`, with `hadlinkedvideo` / `hadlinkedaudio` set:

```
h=3382&type=5&name=bars.mp4&path=...&note=&creationtime=1792795562&hfolder=7&hlinked=3383&in=0&out=6000&hadlinkedvideo=1&thumbpos=4500&soundstreamindex=-1&isbackgroundsound=0
h=3383&type=3&sphen=0&sphho=0&sphve=0&name=bars.mp4&path=...&note=&creationtime=1792795562&stereoformat=0&stereostretch=0&hfolder=6&hlinked=3382&in=0&out=6000&thumb=4500&hadlinkedaudio=1&thumbpos=4500
```

`out` is the media duration in ms (`ffprobe`, or an explicit `duration`),
`hfolder` 7 = Audio Files, 6 = Video Files, `creationtime` is Unix seconds and
`thumb`/`thumbpos` are a placeholder frame time. VideoPad re-saved these two
records **byte-identically**, including field order, so cloning a prototype line
is the right shape. Note `clips=` counts the sequence record *plus* every media
record — adding one file therefore raises `clips=` by 2 and `effectchains=` by 2,
and adding one clip raises `trackclips=` by 2 and `effectchains=` by 2.

**Scope after v3:** rename, trim, reorder, drop, reuse (n×), add media, mute,
split at arbitrary cut points, and video effect chains per clip. Not modelled:
transitions, titles, audio mixing, keyframed parameters, speed, extra tracks,
audio-less media.

## Effect chains (`effectchains`) — the slot format

One record per clip, sequence and media handle, keyed by `hclip=` (not by line
position), so a chain is found by the handle of the clip it belongs to. The
record is a **fixed slot list**, and each slot is a set of querystring parameters:

```
hclip=3392&fadepoints=0&speedchangef=1.000000&size=2&type0=36&preset0=Default%20Preset&data0=...&type1=6&preset1=Bright&data1=...&fadeinlen=0&...&mute=0
```

| key | meaning |
|---|---|
| `size` | number of effect slots; **the only thing that says how many `typeN`/`dataN` to read** |
| `typeN` | the effect's id (the `id` field in `tools/effects.json`), matching the `Type` of its `%APPDATA%\…\VideoPad\EffectPresets` key |
| `presetN` | display label of the preset — a *name*, not a lookup key |
| `dataN` | **the effect's own parameter set, as a querystring, URL-escaped exactly once** |

`dataN` is itself a querystring, one entry per parameter, and each entry's value
is `value=<n>&userdata=<n>&keys=<n>` (itself escaped):

```
data0 = enabled%3Dvalue%3D1%26userdata%3D0%26keys%3D0%26mirrordirection%3D1
        │        │                 │
        │        └ params of type 36
        └ & between params is %26
```

- `value` is the numeric value in `%f` form (6 decimals) or an enum's integer;
- `keys=0` means "no keyframes" — a non-zero `keys` means the parameter is
  animated and its value blob is a keyframe list. **Overriding such a parameter is
  refused by the writer** rather than silently dropped;
- `userdata=0` in everything seen so far.

Because the escaping is single-pass on a nested querystring, the practical rule
is: **build the inner querystring, escape it once, put it after `dataN=`**, and
never double-escape.

Effect ids observed (all 15 registry entries were checked against the live
`EffectPresets` hive): `6` colour adjust, `24` saturation, `33` rotate, `36`
mirror, plus brightness/contrast/gamma-style groups inside `6`.

**What the app does to a chain on save:**

- `dataN` comes back **verbatim** — a hand-authored chain round-trips intact
  (`out/oracle/cut4-split-effects.roundtrip.vpj`);
- `presetN` is **re-derived** from `dataN`: if the parameters still equal a
  shipped preset the name survives, otherwise it becomes `Custom`. So an edited
  effect loses its preset *label* even though its values are untouched —
  **diff `dataN`, not `presetN`**;
- `size` and slot order are preserved; audio clips keep the empty default
  (`size=0`) unless an audio effect is authored, and the writer does not.

Parameter metadata (which keys exist, their types, enums, defaults and preset
blobs) lives in `tools/effects.json`, not here.


## Export — driving it, and proving the output

### Three kinds of UI surface, three techniques

| surface | technology | how to drive it |
| --- | --- | --- |
| Ribbon (Home…Suite, Export Video) and the Export dropdown | custom-drawn: no HWNDs, no UIA | synthetic mouse at calibrated coordinates |
| Export dialog | `DirectUIHWND` (embedded IE) inside a `NativeHWNDHost` popup | its *buttons* are real Win32 `Button`s with window text → find by name, activate with `BM_CLICK` |
| Preview transport (Split, Full Screen, Cursor) | ordinary `Button` / `Edit` / `Static` | address by window text |

**Dialogs are owned popups, not children.** `GetParent` on a dialog control
returns the *owner* window, so a dialog looks like a descendant — but
`EnumChildWindows(main)` never reaches it. Enumerate the process's top-level
windows instead (`Get-PadWindows` in `tools/PadUi.ps1`).

### The path that works

1. `Home` tab `(175,66)` → `Export Video` `(543,105)` → `Video File` `(515,176)`,
   calibrated at 1536×817 physical and scaled by `window.Width / 1536`.
2. `Find-PadControl -Text 'Create' -ClassName 'Button'`, then `BM_CLICK`.
   A synthetic *mouse* click on Create is silently ignored by the DirectUI host;
   `BM_CLICK` works. `Enter` also works, because Create is the default button.

Two traps, both hit during development:

- The dropdown is **transient**. All three clicks must happen inside one process;
  a tool round-trip between them lets the menu auto-close and the next click lands
  on the ribbon — which is how the ribbon silently got knocked to Sequence, then
  Effects, and opened a Text Effects gallery.
- Coordinates are only valid for the **tab that is selected**. Normalise to Home
  first, and keep everything in **physical pixels** (DPI-aware process).

### Naming and output location

- Export File Name defaults to the **sequence name**; the folder comes from the
  project's export settings (`Computer_FilePath`, line 37), defaulting to
  `%USERPROFILE%\Videos`.
- VideoPad **never overwrites**: an existing target is written as `Name 1.mp4`.
- The dialog's text fields live inside the DirectUI tree and cannot be set
  programmatically, so the tool snapshots the folder and adopts the newly
  created/changed `.mp4`, then moves it to the requested path.
- A completion dialog appears afterwards; its `Close` button is found and clicked
  so the file is released.

### Verified output (the 210 000 ms autosave-oracle project)

| check | result |
| --- | --- |
| duration | 210.006 s — delta 6 ms, i.e. 0.14 of a frame |
| streams | 1920×1080 h264 + AAC, 5036 frames @ 23.976 fps |
| size | 178 212 640 bytes |
| repeatability | two independent runs produced **byte-identical** files |
| cut point | export@91 s vs Ep2@61 s MAE **0.23**; vs Ep3@91 s **73.67**; vs Ep2@91 s **73.64** |

Frame comparison is mean absolute error over 32×32 greyscale frames extracted
with `ffmpeg -ss <t>`, so ≈0 means identical and 70+ means unrelated.

`export@200 s` vs Ep2@170 s = **0.18** (vs Ep3@170 s = 79.08) independently
confirms the second segment's in-point. `export@86 s` matches *both* sources
(0.23 / 0.26) because the two episodes share an identical opening, so frames
cannot distinguish Ep3 from Ep2 inside the first 90 s — what is provable there is
the segment's 90 s length and that the switch lands exactly at 90 s.

### Operational notes

- The encode runs **inside VideoPad** (~7 min for 3.5 min of 1080p). The file is
  unreadable until the `moov` atom is written, so `ffprobe` reports
  `moov atom not found` mid-encode. Completion test: size stopped changing **and**
  ffprobe returns a duration.
- Because the work happens in VideoPad and not in the calling script, an
  interrupted run is recoverable: `Export-Project.ps1 -WaitOnly` adopts the newest
  export rather than re-driving the UI.
- Export presets are plain querystrings in
  `%APPDATA%\NCH Software\VideoPad\ComputerPresets\*.dat`
  (`EditOutput_Width=1280&…&VIDEO_CODEC_MP4=28&Type=4`), so a preset is authorable
  as a file even though the dialog's preset picker is DirectUI.

Implemented in `tools/Export-Project.ps1`, on top of `tools/PadUi.ps1`
(`Get-PadWindows`, `Find-PadControl`, `Invoke-PadControlClick`, `Save-PadCapture`)
and `tools/Probe-ExportDialog.ps1` (control-map dump).

## Still open

- **Transitions**: a `transitions` section has not even been inventoried; effect
  chains cover per-clip effects only, not the between-clip crossfade records.
- **Titles**: the `Type=2SubtitlesExport=1` fragment is in every file, but no
  title object has been authored or round-tripped.
- **Audio effects and mixing**: audio `effectchains` records keep `size=0`;
  volume, pan and audio filters are unwritten.
- **Keyframed parameters**: a parameter group with `keys!=0` is read but never
  merged — the writer refuses to override it.
- **Speed**: `speedchangef≠1` duration semantics are unverified.
- **Audio-less media**: added media is written as a `type=5`/`type=3` pair and
  rejected when `ffprobe` finds no audio stream.
- **Round-trip through a real save** to normalise the checksum, instead of relying
  on the auto-dismissed "Damaged File" prompt.
- **Concurrency**: the autosave file is global and the app is single-instance, so
  validation and export are serialised.
- The dialog's preset picker can't be scripted, so non-default presets currently
  mean editing `ComputerPresets\*.dat` (or the `Computer_Preset` value in the
  project) before exporting.
