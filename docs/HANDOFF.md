# HANDOFF — agent-driven video editing through VideoPad

> **Read this first if you are a new session.** It is self-contained: goal,
> verdict, environment, exact commands, hard-won gotchas, current state, open
> work. `docs/vpj-format-findings.md` holds the deep format detail; this file
> holds the operational picture and the traps.

## 1. Goal

An agent pipeline that edits video unattended:

```
JSON edit spec  →  .vpj project  →  VideoPad  →  exported .mp4
```

No ffmpeg rendering, no screen recording, no NLE SDK — VideoPad itself is the
renderer, and the agent only supplies a project file plus a click.

## 2. Verdict: can an agent edit in VideoPad?

**Yes, with a precise scope.** Three separate questions hide inside that one:

| question | answer | why |
|---|---|---|
| Can a tool write a `.vpj` VideoPad will open and honour? | **Yes, proven** | `.vpj` is plain-text LF-terminated sectioned querystrings; a stale checksum only raises a "Damaged File" prompt that is auto-answerable |
| Can VideoPad be made to *export* that project unattended? | **Yes, proven** | ribbon coordinate clicks + `BM_CLICK` on the export dialog's `Create` button; output verified frame-by-frame |
| Can an agent perform *arbitrary* edits? | **Partly — v3** | the writer renames, trims, reorders, **reuses a source any number of times**, adds and removes clips, **adds new media files**, mutes segments, **splits a clip at arbitrary cut points** and writes **per-segment video effect chains** registered in `tools/effects.json`. Not yet: transitions, titles, audio mixing, speed changes. See §9 |

So: **the loop closes today for a cut** *and* for structural edits that only add
or remove timeline clips and bin media, *and* for split + effect chains. It does
not yet cover transitions, titles or audio mixing.


There is **no scripting API**: VideoPad is a Delphi app with no MSAA/UIA
provider (all ~65 UIA descendants are unnamed `Pane`s). Everything below is
Win32 window enumeration + synthetic input, so it is inherently calibrated to a
window size and DPI. Treat the UI layer as the fragile part and the `.vpj`
writer as the durable part.

## 3. Environment (this machine — re-verify if anything looks off)

| item | value |
|---|---|
| VideoPad | Professional **8.91+**, 32-bit, `C:\Program Files (x86)\NCH Software\VideoPad\videopad.exe` |
| display | **150% scaling** (this is the source of the historical DPI bug, §7) |
| main window | 1536×817 physical px at the calibration used for ribbon coords |
| ffmpeg / ffprobe | `C:\Users\user\scoop\shims\ffmpeg.exe` (on PATH) |
| workspace | `C:\Users\user\Downloads\videopad` |
| template project | `C:\Users\user\Documents\probe.vpj` |
| autosave read-out | `%APPDATA%\NCH Software\VideoPad\autosave.vpj` |
| export presets | `%APPDATA%\NCH Software\VideoPad\ComputerPresets\*.dat` |

Source media in the template (two distinct sources, timeline order):

| index | handle | file |
|---|---|---|
| `source: 0` | media `h=327` | `One_Punch_Man_Season_3_Episode_2_1080p_@Tv_Series_ETY_.Mkv` (1 441 083 ms) |
| `source: 1` | media `h=345` | `One_Punch_Man_Season_3_Episode_3_1080p_@Tv_Series_ETY_.Mkv` (1 441 083 ms) |

The two episodes **share an identical opening**, which matters for verification:
any frame from the first ~90 s matches both sources, so content checks are only
conclusive past the opening (§8).

## 4. Pipeline and file map

| file | role |
|---|---|
| `examples/cut1.json` | the edit spec (template, output, sequence name, segments) |
| `examples/cut2-reuse.json`, `examples/cut3-addmedia.json` | v2 specs: source reuse / dropped clip / mute, and added media |
| `examples/cut4-split-effects.json` | v3 spec: `split`, `defaultEffects`, per-segment `effects` |
| `tools/effects.json` | **effect registry**: for each effect, its `id` (the value that goes in `typeN`), the blob VideoPad ships (`defaults`), named `presets`, and per-key metadata (number, enum, bool, keyframed). Keys were dumped from the live `HKCU:\…\VideoPad\EffectPresets` |
| `tools/New-Project.ps1` | **spec → .vpj** by editing the template; preserves unknown fields byte-for-byte |
| `tools/Test-Examples.ps1` | rebuilds every spec and asserts the output is **byte-identical** — the gate before a commit (no VideoPad needed) |
| `tools/Open-Project.ps1` | launches VideoPad on a `.vpj`, clears stale modals, auto-answers "Damaged File" via `WM_COMMAND/IDOK`; ~4.5 s |
| `tools/Watch-Autosave.ps1` | load → wait for autosave refresh → report what the parser actually absorbed |
| `tools/Export-Project.ps1` | **.vpj → .mp4**: ribbon clicks, `Create`, wait, adopt file, verify duration |
| `tools/PadUi.ps1` | UI primitives: DPI-aware capture/click, top-level window enumeration, control search, `BM_CLICK`, window resizing |
| `tools/NativeInput.cs` | P/Invoke layer (`mouse_event`, `keybd_event`, `SendMessage`, `EnumWindows`, …) |
| `tools/Probe-ExportDialog.ps1` | diagnostic: dumps the control map of whatever dialog is under a point |
| `tools/Get-WindowCapture.ps1`, `tools/Send-PadClick.ps1` | earlier standalone capture / click tools, still useful for calibration |
| `docs/vpj-format-findings.md` | format reference: sections, handles, checksum, timeline semantics, export |
| `out/cut1.vpj`, `out/cut2-reuse.vpj`, `out/cut3-addmedia.vpj` | the generated projects (210 000 / 150 000 / 36 000 ms) |
| `out/cut4-split-effects.vpj` | v3 project: 15 000 ms, 6 clips from 3 segments (one split in three, one split in two) + effect chains |
| `out/agent-cut-v2.mp4`, `out/agent-cut-first-export.mp4` | the two verified 210 s exports (identical) |
| `out/cut3-addmedia.mp4`, `out/cut4-effects.mp4` | the v2 add-media and v3 split+effects exports (gitignored) |

| `out/oracle/` | evidence: v2/v3 autosave round-trips, watcher logs, export logs, frame-MAE scripts and results (`cut3-verify.*`, `cut4-verify.*`), and `compare-projects.ps1` — the timeline/effect-chain differ used against a round-trip |

End-to-end invocation, in order:

```powershell
cd C:\Users\user\Downloads\videopad

# 0. regression gate (~2 s, no VideoPad): every spec must reproduce its .vpj exactly
.\tools\Test-Examples.ps1

# 1. spec -> project
.\tools\New-Project.ps1 -Spec .\examples\cut1.json

# 2. cheap content check (~5 s, no encode)
.\tools\Watch-Autosave.ps1 -Project .\out\cut1.vpj -LogPath .\logs\autosave-check.log

# 3. render (drives the UI, ~7 min for 3.5 min of 1080p)
.\tools\Export-Project.ps1 -ProjectPath .\out\cut1.vpj `
    -OutputPath .\out\agent-cut.mp4 -ExpectedDurationMs 210000

# 3b. if the click phase already started an encode and you lost the process:
.\tools\Export-Project.ps1 -OutputPath .\out\agent-cut.mp4 `
    -ExpectedDurationMs 210000 -WaitOnly
```

`Export-Project.ps1` parameters:

| param | meaning |
|---|---|
| `-OutputPath` (required) | where the finished mp4 must end up |
| `-ProjectPath` | open this project first (delegates to `Open-Project.ps1`); omit to use whatever is open |
| `-ExpectedDurationMs` | asserts the result within ±42 ms (one frame at 23.976); `0` skips |
| `-ExportFolder` | folder VideoPad writes into. The *dialog* inherits the project's `Computer_FilePath` (usually `%USERPROFILE%\Videos`); the *tool* defaults to `%USERPROFILE%\Videos` if not given |
| `-TimeoutSeconds` | whole-run budget, default 1800 |
| `-WaitOnly` | skip all clicks, adopt the newest export in `-ExportFolder` (recovery path) |

## 5. The `.vpj` format in one screen

Plain text, LF line endings, one record per line, each line a querystring of
`key=value&key=value`. Lines are grouped into named sections; a record's identity
is its handle, **not** its line position.

| `type=` | record | key fields |
|---|---|---|
| 1 / 2 | video / audio track | `h`, `htrack` |
| 3 / 5 | video / audio media (source) | `h`, `name`, `out` (source length, ms) |
| 6 | sequence | `h`, `name`, `duration`, `in`, `out` |
| 7 | trackclip | `h`, `htrack`, `horiginalclip`, `hlinked`, `offset`, `in`, `out` |

Semantics that matter when writing:

- `in`/`out` on a trackclip = trim window **inside the source** (ms); `offset` =
  position **on the timeline** (ms).
- A source's video and audio are **two separate `type=7` records** joined by
  `hlinked` — trim them identically or A/V drifts.
- Sequence `duration`/`out` must equal the **exact sum** of `(out - in)` over its
  trackclips (the sample's 2 × 1 441 083 = 2 882 166 to the millisecond).
- `effectchains` has exactly one line per clip/sequence/media handle, which is why
  adding a handle is not just "add a line".
- The last line is `checksum=…`. **Do not reverse-engineer it** — leave it stale.
  VideoPad then shows "Damaged File / Try Load", which `Open-Project.ps1` answers
  in ~4 s. (This is the single biggest time-saver in the whole project.)
- The file stores **paths, not media**. Missing files resolve offline.

## 6. The writer: spec schema and guard rails

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

- `source` is either an integer index into the template's distinct sources **in
  timeline order**, or the `id` of an entry in `media`. `start`/`end` are ms
  inside that source; `mute` is optional.
- Segment order *is* timeline order, so the list doubles as a reorder, a drop
  (omit a source) and a reuse (repeat one).
- `split` is a list of **absolute ms inside the source** (not offsets into the
  segment) that must lie strictly between `start` and `end`. It expands into
  adjacent segments sharing one media handle and one effect chain, which is
  exactly how VideoPad stores a split (no special "split" record exists).
- `effects` is that segment's video effect chain; `defaultEffects` is inherited by
  every segment that does not define `effects`. An **explicit `[]` means "no
  effects"** and does override `defaultEffects`. Audio is unaffected — an audio
  clip's chain is the empty default, as the app writes it.
- An effect entry is `{ "name": <key in tools/effects.json>, "preset": <name>, "params": { … } }`.
  `preset` fills the blob from the registry, then `params` overrides only the keys
  given; `params` alone starts from the effect's `defaults`. Overriding a
  keyframed parameter group (`keys!=0`) is refused rather than silently discarded.
- `sequenceName` is optional and URL-encoded into the sequence record.
- **All paths resolve against the spec's own folder** unless absolute, so a spec
  is portable between checkouts.
- `media` entries are measured with `ffprobe` — supply `"duration"` (ms) to skip
  that. A file without an audio stream is rejected: added media is written as an
  A/V pair and the audio-less variant has not been verified.

What `New-Project.ps1` does:

- trims `in`/`out` on the video **and** linked audio trackclip, rewrites `offset`
  cumulatively from 0, sets sequence `duration`/`out` to the exact sum;
- **reuses** a template trackclip pair when the segment's source still has an
  unused one, so a spec that never repeats a source rewrites the file in place
  (byte-identical to the v1 output — `examples/cut1.json` still reproduces
  `out/cut1.vpj` exactly);
- otherwise **allocates** a fresh `type=7` video/audio handle pair from `hindex`,
  bumps `hindex`, and clones the pair from the template's own prototype line;
- **expands `split`** into consecutive segments before anything else runs, so a
  cut point is just two adjacent clips — VideoPad shows it as a split (same media
  handle, touching offsets) and nothing downstream needs to know;
- **writes effect chains**: resolves each segment's `effects`/`defaultEffects`
  through `tools/effects.json`, then rewrites the `size`/`typeN`/`presetN`/`dataN`
  slots of that clip's `effectchains` record (found by its `hclip`). Everything
  else in the record — fades, speed, `hclip` itself — is preserved field by field;
- **removes** the trackclip *and* `effectchains` records of clips no longer used,
  so nothing is orphaned on the timeline (bin media records are kept, matching
  what the app does when a clip is deleted);
- **adds** a `type=5`/`type=3` media pair plus one `effectchains` line per handle
  for every new file; segments of the same added media share that one record;
- refuses trims past source length, and **asserts**: every handle unique, exactly
  one `effectchains` record per clip handle, section counts consistent with their
  bodies, and the checksum line untouched — so a format drift fails loudly
  instead of producing a subtly broken project.

It returns one summary object — `Output`, `DurationMs`, `SequenceName`,
`SourceCount`, `SegmentCount` (after split expansion), `DroppedClips`,
`AllocatedHandles`, `MediaAdded`, `EffectCount`, and `Clips` with each clip's
handles and resolved chain — which is what `Test-Examples.ps1` prints next to its
byte comparison.

It works by editing a known-good template and reassembling by section, so every
field nobody understands survives byte-for-byte (including the glued
`Type=2SubtitlesExport=1` quirk and the stray CR).

## 7. UI automation: the rules that took the longest to learn

**R1 — DPI awareness before any coordinate.** PowerShell is DPI-unaware by
default: `GetWindowRect` returns *logical* px while `BitBlt`/`SetCursorPos` use
*physical* px. At 150% every click was displaced by half a screen and every
capture was cropped to the window's top-left ⅔. Call `SetProcessDPIAware()` first
(`PadUi.ps1` does). A long-standing note in this repo claimed "mouse clicks are
blocked by the Windows foreground lock" — **that was wrong**, it was DPI.

**R2 — Dialogs are owned popups, not children.** `GetParent` on a dialog control
returns the *owner*, so a dialog looks like a descendant, but
`EnumChildWindows(main)` never reaches it. Enumerate process **top-level** windows
(`Get-PadWindows`).

**R3 — Ribbon is custom-drawn, dialogs are not.** The ribbon has no HWNDs and no
UIA → coordinate clicks only. The export dialog is a `DirectUIHWND` (embedded IE)
inside a `NativeHWNDHost` popup, but its buttons are **real Win32 `Button`s with
window text** → find by name and `BM_CLICK`. A synthetic *mouse* click on `Create`
is silently swallowed; `BM_CLICK` works; `Enter` also works (default button).

**R4 — The export dropdown is transient.** Home → Export Video → Video File must
be three clicks **inside one process**. A tool round-trip between them lets the
menu auto-close and the next click lands on the ribbon — that failure mode
silently changed the active tab to Sequence, then Effects, and opened a Text
Effects gallery. If the ribbon looks "possessed", this is why.

**R5 — Coordinate frame.** Ribbon coords were calibrated at **1536×817** physical:
Home `(175,66)`, Export Video `(543,105)`, Video File `(515,176)`.
`Export-Project.ps1` now **resizes the window to 1536×817** (`Set-PadWindowSize`)
before clicking. Scaling the coordinates by `window.Width / 1536` alone is not
enough: the ribbon scales with **DPI, not with window width**, so on a maximised
1942×1030 window every width-scaled click lands *below* the ribbon and the Export
dropdown never opens (seen live — the driver waited out its timeout for a dialog
that never appeared). Recalibrate if the DPI changes; capture a screenshot with
`Save-PadCapture` and read coords off the **physical** image.

**R6 — Single instance, and never force-kill.** VideoPad silently **drops the file
argument** if another instance is already running — close first via `WM_CLOSE`.
Force-killing arms crash recovery ("Abnormal Termination"), which then suppresses
the CLI argument on the next start and poisons the next several runs.

**R7 — `WM_CLOSE` is swallowed while a modal is open.** Dismiss the modal first —
and note that each swallowed `WM_CLOSE` spawns *another* prompt, so a naive retry
loop leaves a stack of identical dialogs. `Open-Project.ps1` answers them
(`Clear-PadModals`) before closing. The ones seen in practice:

| modal | buttons | answer |
|---|---|---|
| "The current project has been changed since the last time you saved…" | `Save` `Discard` `Cancel` | **Discard** (one per swallowed close) |
| "New media has been connected to your computer." | `Add Files` `No` | **No** (raised when files land in a watched folder — e.g. our own export) |
| "Damaged File … try to load it anyway?" | `Try Load` `Cancel` | **Try Load** via `WM_COMMAND/IDOK`, never `Cancel` |

These are **real `#32770` windows with real `Button` children, but UI Automation
does not expose them at all** — not the window, not the buttons. `Clear-PadModals`
therefore enumerates with Win32 (`Get-PadWindows` + `EnumChildWindows`) and never
answers anything whose text mentions "damaged".

**R8 — The encode happens inside VideoPad.** The calling script is not the renderer,
so an interrupted script does not lose the render: `-WaitOnly` adopts the newest
export. The mp4 is unreadable until the `moov` atom is written (`ffprobe` says
`moov atom not found` mid-encode); completion = size stopped changing **and**
ffprobe returns a duration.

**R9 — Output naming cannot be set.** The dialog's text fields are inside the
DirectUI tree. VideoPad **never overwrites**: an existing target becomes
`Name 1.mp4`. Hence the tool snapshots the folder, adopts the new/changed file,
moves it to `-OutputPath`, then dismisses the completion dialog (its `Close`
button is found by name).

**R10 — Run the UI-driving scripts in a console you can see, and clear modals
before anything else.** A hidden / detached `Start-Process powershell -File …`
launched from another PowerShell session produced *no window enumeration and no
clicks at all* — the script appeared to run and did nothing. Whatever the cause
(session/desktop or job-object teardown), the reliable patterns are (a) run
`Export-Project.ps1` in the interactive console, or (b) if you must detach, create
the process with `Invoke-CimMethod -ClassName Win32_Process -MethodName Create`
and point its stdout/stderr at a log file, then poll the log — that is how the
`cut4` export was driven. Related: after a killed VideoPad the next start raises
**"Abnormal Termination Detected"** (an "unexpectedly terminated" report dialog)
that swallows clicks on the ribbon until dismissed; treat it like any other modal
(`Get-PadWindows` + `WM_COMMAND`/`IDOK`) instead of force-killing the app again.

## 8. Evidence the pipeline is real (not "the export dialog opened")

Two independent oracles, deliberately: one for *what VideoPad parsed*, one for
*what came out the far end*.

**Oracle A — autosave (`tools/Watch-Autosave.ps1`).** VideoPad rewrites
`%APPDATA%\NCH Software\VideoPad\autosave.vpj` ~3 s after a load, as a full
re-serialization of its in-memory model. A project we wrote and the app's own
re-emission differ on **exactly three lines**: `hindex`, one folder `open=` UI
flag, and `checksum`. `thumbpos` was also recomputed (1 440 000 → 100 000), which
proves the app *rebuilt* the timeline from our values instead of echoing the file
back. That is how content fidelity was confirmed cheaply, without rendering.

**Oracle B — exported frames.** `ffmpeg -ss <t> -frames:v 1 -vf scale=32:32,format=gray`
on both the export and the sources, then mean absolute error (0 ≈ identical,
70+ ≈ unrelated).

Spec under test: `source 1` 0–90 000 ms, then `source 0` 60 000–180 000 ms →
expected 210 000 ms.

| check | result |
|---|---|
| duration | **210.005751 s** vs 210.000 requested → 5.8 ms ≈ 0.14 frame |
| streams | 1920×1080 h264 + AAC, 5036 frames @ 23.976 |
| size | 178 212 640 bytes |
| determinism | two runs **byte-identical**, SHA256 `FDCA15802A463E3E7D0BF63AFF595E2E76013E8B6D7353891E48D31FB13CB16D` |
| export@91 s vs Ep2@61 s | **0.23** ← match (91−90 = 1 s into segment 2, in-point 60 s) |
| export@91 s vs Ep3@91 s | 73.67 ← control |
| export@91 s vs Ep2@91 s | 73.64 ← control |
| export@200 s vs Ep2@170 s | **0.18** ← match (200−90 = 110 s + 60 s in-point) |
| export@200 s vs Ep3@170 s | 79.08 ← control |

Read the matches backwards: they pin the **switch at exactly 90 000 ms**, because
the match only holds at `t − 90 000 + source in-point`.

**Honest limitation:** `export@86 s` matches *both* sources (0.23 / 0.26), because
the two episodes share an identical opening. Frames therefore **cannot**
distinguish Ep3 from Ep2 inside the first 90 s. What is provable there is the
segment's 90 s length and that the switch lands at 90 s — not which episode fills
it. Segment 2 is conclusively Ep2.

Reproduce the frame check:

```powershell
$t=91
& ffmpeg -v error -ss $t -i .\out\agent-cut-v2.mp4 -frames:v 1 -vf scale=32:32,format=gray -f rawvideo -y out\a.gray
& ffmpeg -v error -ss 61 -i 'D:\path\to\Episode_2.mkv' -frames:v 1 -vf scale=32:32,format=gray -f rawvideo -y out\b.gray
$A=[IO.File]::ReadAllBytes("$PWD\out\a.gray"); $B=[IO.File]::ReadAllBytes("$PWD\out\b.gray")
$s=0; for($i=0;$i -lt $A.Length;$i++){ $s += [Math]::Abs($A[$i]-$B[$i]) }; 'MAE = ' + [Math]::Round($s/$A.Length,2)
```

### v2 evidence (structure *and* new media)

Both v2 features were checked against both oracles, and the artefacts are in
`out/oracle/`:

| project | what it proves | result |
|---|---|---|
| `out/cut2-reuse.vpj` (5 clips, one source used 3×, 3 allocated pairs, one muted) | source reuse + drop + mute survive the parser | autosave returned all 10 trackclips **byte-identical** (handle, `horiginalclip`, `htrack`, `offset`, `in`, `out`), `clips=5 / trackclips=10 / effectchains=15`, `mute=1` kept. Only deltas: checksum, `hindex`, folder `open=`, recomputed `thumb` |
| `out/cut3-addmedia.vpj` (Ep3 0–15 s, `bars.mp4` 0–6 s, Ep3 900–915 s) | added media + reuse + trim, end to end | autosave: `clips=7 / trackclips=6 / effectchains=13`, all 6 clips identical, and the two synthesised media records identical **down to field order and `creationtime`**. Export: **36.011 s** vs 36.000 expected (Δ 11 ms) |

Frame MAE for the export (`out/oracle/cut3-verify.ps1` → `.txt`):

| comparison | MAE | reading |
|---|---|---|
| `export@18s` vs `bars@3s` | **0.59** | the added media really is on screen, at the right source time |
| `export@18s` vs `Ep3@5s` | 97.41 | …and it is not the episode |
| `export@5s` vs `Ep3@5s` | **0.20** | segment 1 correct (`Ep2@5s` = 1.04: shared opening) |
| `export@30s` vs `Ep3@909s` | **0.42** | segment 3's `in=900000` is exact |
| `export@30s` vs `Ep3@5s` | 121.23 | …and unrelated to the episode's opening |

Regenerate the scratch clip the add-media example points at:

```powershell
ffmpeg -y -f lavfi -i "testsrc2=size=640x360:rate=25:duration=6" `
       -f lavfi -i "sine=frequency=440:duration=6" `
       -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest out\testmedia\bars.mp4
```

### v3 evidence (split + effect chains)

Spec `examples/cut4-split-effects.json` → `out/cut4-split-effects.vpj`: 15 000 ms,
3 spec segments expanding to **6 clips**, `defaultEffects` on every segment,
one segment overriding with its own chain:

| timeline (ms) | source | chain actually written |
|---|---|---|
| 0–2 000 / 2 000–4 000 / 4 000–6 000 | Ep3 (one clip, `split [2000, 4000]`) | `type=24` saturation `value=-100` — inherited `defaultEffects` |
| 6 000–9 000 / 9 000–12 000 | `bars.mp4` (`split [3000]`) | `type=33` rotate `z=90` — explicit `effects`, and the frame stays **colourful**, so it replaced the default rather than appending to it |
| 12 000–15 000 | Ep3 @ 900 000 | `type=36` mirror `mirrordirection=1` **and** `type=6` colour `contrast=60` |

**Oracle A — autosave round-trip** (`out/oracle/cut4-split-effects.roundtrip.vpj`,
differ with `out/oracle/compare-projects.ps1 -A out/cut4-split-effects.vpj -B …`):
all 6 video/audio pairs came back with identical `h`, `hlinked`, `in`, `out`,
`offset` — the split survived as three and two adjacent clips sharing one media
handle, which is exactly how the app itself stores a split. All six chains came
back slot-for-slot identical (`size`, `typeN`, `dataN`).

Two deltas, both benign, both worth knowing:

- **line order**: the app emits all video trackclips, then all audio. Pure
  re-serialisation; the format keys off handles, not line positions.
- **`presetN` is re-derived.** `rotate`/`mirror`/`colour` came back as
  `preset=Custom` instead of `Default Preset`/`Bright`, because our params no
  longer equal the shipped preset. Saturation kept
  `preset=Completely Unsaturated` because `value=-100` *is* that preset. So the
  app validates `dataN` against the preset table and relabels accordingly —
  **diff `dataN`, never `presetN`**, and never expect a preset *name* to round-trip
  once you override a single parameter.

**Oracle B — export** `out/cut4-effects.mp4`: 15.019 s vs 15 000 (Δ 19 ms ≈ 0.5
frame), 7 461 497 bytes, 1920×1080 h264 + AAC. Numbers from
`out/oracle/cut4-verify.ps1` (output in `cut4-verify.txt`):

| claim | measurement | reading |
|---|---|---|
| clips 0–2 are desaturated | mean chroma `0.0` at t = 1 / 3 / 5 s vs **33.4** on Ep3@5 s; frame MAE export@5 vs Ep3@5 = **4.06** | same picture, colour removed — MAE 4 is as close as a deliberate effect gets |
| clips 3–4 are rotated | export@7 vs `bars@1` **transposed ccw = 46.86**, cw = 99.26, as-is = 95.49 | the 90° turn is there and it is the right way round; the residual is the pillarbox crop at 32×32 |
| …and keep their colour | chroma export@7 = **133.1** vs source 226.3 | `effects` overrode `defaultEffects`; had it been inherited the export would have been grey |
| clip 6 is mirrored | export@13 vs **its own L-R mirror = 0.19**, vs its own T-B mirror = 152.91; the unmirrored source scores **35.69** against its own L-R mirror | left-right symmetric, and the source is not — mirror active, axis = vertical. (`effects.json`'s "vertical" means *mirror across the vertical axis*, i.e. a horizontal flip.) |
| …and contrast-boosted | frame is visibly blown out; MAE against the mirror-flipped source is ~64 for both flipped and unflipped, i.e. luma was rescaled too much for MAE to arbitrate | read from the frames, not the metric |

The saturation check is the one that needs care: Ep3's opening 0–4 s is a
pencil-sketch title card that is *already* near-grey (source chroma 2.0 / 1.7), so
t = 1 s and t = 3 s prove nothing on their own. Only t = 5 s, where the source
chroma is 33.4 and the export's is 0.0, separates "effect applied" from "source
was grey".

Sampling times follow from the spec, not from guessing: clip 3 starts at timeline
6 000 with `in=0`, so export@7 s is `bars@1 s`; clip 6 starts at 12 000 with
`in=900000`, so export@13 s is `Ep3@901 s`.

## 9. What is NOT supported yet (and the shape of the fix)

**Writer — still needs records this writer does not model:**

- **transitions** between clips (`transitions` section — not even inventoried yet),
- **titles** (the `Type=2SubtitlesExport=1` quirk is in every file, but no title
  record has been authored),
- **audio effects / mixing** — only the video chain is written; an audio clip keeps
  the empty default chain, and volume is not touched,
- **keyframed effect parameters** — an override of a group with `keys!=0` is
  refused rather than merged, so animated effects still have to be authored by hand,
- **speed changes** (`speedchangef`) — parsed past, never written,
- adding media **without an audio stream** — added media is written as a
  `type=5`/`type=3` pair, so a silent video is currently rejected rather than
  guessed at,
- more than one video/audio track or a second sequence.

Mechanically, everything else is now done: handles above `hindex` with `hindex`
bumped, cloned `type=7` pairs, cloned `effectchains` per handle, consistent
`hlinked`, recomputed `offset`/`duration`, split expansion into adjacent clips,
and removal of the records belonging to dropped clips.

**Other open items:**

- **Presets can't be picked** — the picker is DirectUI. Workaround: author
  `%APPDATA%\NCH Software\VideoPad\ComputerPresets\*.dat`, which are plain
  querystrings (`EditOutput_Width=1280&…&VIDEO_CODEC_MP4=28&Type=4`), or set
  `Computer_Preset` in the project.
- **Output path/filename can't be typed** — see R9.
- **Checksum** — never reversed. Stale checksum + auto-answered prompt is the
  strategy; a real save round-trip could normalise it if a clean file is needed.
- **No concurrency** — single instance, global autosave file, so validation and
  export are serialised.
- **UI layer is calibrated** — different DPI/window size ⇒ recalibrate (§7 R5).
- **Encode speed** — ~7 min per 3.5 min of 1080p, no progress read-out, only size
  stability.

## 10. Current state (as of this handoff)

- `out/cut1.vpj` — v1 regression: 210 000 ms, sequence "Agent Cut", still
  byte-identical when regenerated by the v3 writer.
- `out/cut2-reuse.vpj` — v2 reuse/drop/mute: 150 000 ms, 5 clips from 2 sources,
  round-tripped through the app unchanged.
- `out/cut3-addmedia.vpj` — v2 add-media: 36 000 ms, exported to
  `out/cut3-addmedia.mp4` (16.5 MB, gitignored) and verified by frame MAE.
- `out/cut4-split-effects.vpj` — v3 split + effects: 15 000 ms, 3 spec segments
  → 6 clips, 3 distinct chains (7 effect slots). Round-tripped through the app
  (`out/oracle/cut4-split-effects.roundtrip.vpj`) and exported to
  `out/cut4-effects.mp4` (7.46 MB, Δ 19 ms), verified by chroma + symmetry +
  transpose comparison (§8, `out/oracle/cut4-verify.*`).
- `tools/Test-Examples.ps1` reports **all 4 examples byte-identical** (the v3
  writer still reproduces `cut1`/`cut2`/`cut3` exactly), so v3 is a superset.
- All `tools/*.ps1` and the three `out/oracle/*.ps1` helpers parse clean (AST check).
- VideoPad is **left running**; `Open-Project.ps1` now clears stale modals first,
  so the next run does not get stuck on a "Save changes?" prompt.
- The user's `Videos` folder is clean again — VideoPad writes there by default
  when the project's `Computer_FilePath` points there, and
  `Export-Project.ps1` moves the file out afterwards.

## 11. Bootstrap prompt for a new session

Paste this to continue the work with full context:

> You are continuing an agent video-editing project in
> `C:\Users\user\Downloads\videopad`. Read `docs/HANDOFF.md` first (operational
> picture, verdict, gotchas, commands), then `docs/vpj-format-findings.md` for
> format detail. It is a PowerShell toolchain that turns a JSON edit spec into a
> VideoPad `.vpj` and drives VideoPad's UI (DPI-aware synthetic clicks + `BM_CLICK`
> on the export dialog) to render an `.mp4` unattended. Proven: spec → `.vpj` →
> export, verified to within 19 ms of expected duration, by frame MAE against the
> sources, and byte-identical across runs. The writer is at **v3**: it can reuse a
> source any number of times, add and remove timeline clips, add new media files
> (ffprobe-measured), mute segments, **split a clip at arbitrary cut points
> (`split`)**, and write **per-segment video effect chains (`effects`/
> `defaultEffects`, resolved through `tools/effects.json`)** — each proven against
> VideoPad's own autosave re-serialisation and a real export (`out/oracle/`). Not
> yet done: transitions, titles, audio mixing, keyframed effect params, silent
> (audio-less) media, presets, and setting the output path in the dialog.
> VideoPad 8.91 32-bit, display at 150% scaling, ffmpeg on PATH. Rules that
> matter: call `SetProcessDPIAware()` before touching coordinates; enumerate
> process top-level windows (dialogs are owned popups, not children); pin the
> editor window to 1536×817 before clicking the ribbon; never force-kill
> VideoPad; answer stale modals *before* `WM_CLOSE` (UIA cannot see them); keep
> the stale checksum and let `Open-Project.ps1` answer the "Damaged File" prompt;
> use `-WaitOnly` to recover an interrupted export; diff `dataN` not `presetN`
> (the app relabels any edited effect as `Custom`).
> [State the specific task here.]



