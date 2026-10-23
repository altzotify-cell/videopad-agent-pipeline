# videopad — agent-driven video editing

Turns a JSON edit spec into a VideoPad project and renders it to `.mp4`
unattended. VideoPad is the renderer; the agent only writes the project and
supplies the click.

```
examples/cut1.json  →  tools/New-Project.ps1  →  out/cut1.vpj  →  VideoPad  →  out/*.mp4
```

**Can an agent edit in VideoPad?** Yes for cutting, for structural edits that add
or remove timeline clips, and for splits plus video effects: the writer (v3)
reuses a source any number of times, drops clips, adds new media files, mutes
segments, splits a clip at arbitrary cut points and writes per-segment effect
chains from `tools/effects.json`. Cut-only work was verified end to end to within
6 ms of expected duration and byte-identical across runs; the v2 and v3 features
were verified against VideoPad's own autosave re-serialisation and a real export
(`out/oracle/`). Not yet: transitions, titles, speed, audio mixing, keyframed
effect parameters.

| start here | what it is |
|---|---|
| **[docs/HANDOFF.md](docs/HANDOFF.md)** | **read this first** — verdict, environment, commands, UI-automation rules, open work, new-session bootstrap prompt |
| [docs/vpj-format-findings.md](docs/vpj-format-findings.md) | `.vpj` format reference: sections, handles, effect-chain slots, checksum, timeline semantics, export details |
| [tools/effects.json](tools/effects.json) | effect registry: ids, parameter schemas, preset blobs — the vocabulary `effects`/`defaultEffects` use |

Quickstart (VideoPad must not already be running — `Open-Project.ps1` closes it):

```powershell
.\tools\New-Project.ps1 -Spec .\examples\cut1.json
.\tools\Export-Project.ps1 -ProjectPath .\out\cut1.vpj `
    -OutputPath .\out\agent-cut.mp4 -ExpectedDurationMs 210000
```

Four specs to copy from:

| spec | shows |
|---|---|
| [`examples/cut1.json`](examples/cut1.json) | trim + reorder, one segment per source (byte-identical to the v1 writer) |
| [`examples/cut2-reuse.json`](examples/cut2-reuse.json) | one source used 3×, a dropped clip, a muted segment |
| [`examples/cut3-addmedia.json`](examples/cut3-addmedia.json) | added media between two episode segments |
| [`examples/cut4-split-effects.json`](examples/cut4-split-effects.json) | splits at 2 s/4 s and 3 s, saturation on all three episode clips, rotate, mirror + Bright-with-contrast |

`.\tools\Test-Examples.ps1` rebuilds all four and fails unless each one reproduces
its committed `.vpj` byte-for-byte — run it after touching the writer.

`cut3` and `cut4` need the same scratch clip first (it is gitignored, and it is
also what the rotate/crop checks in `out/oracle/cut4-verify.ps1` use as source):

```powershell
ffmpeg -y -f lavfi -i "testsrc2=size=640x360:rate=25:duration=6" `
       -f lavfi -i "sine=frequency=440:duration=6" `
       -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest out\testmedia\bars.mp4
```

Environment: VideoPad Professional 8.91 (32-bit), display at 150% scaling,
`ffmpeg`/`ffprobe` on PATH. Coordinates in `tools/Export-Project.ps1` are
calibrated for a 1536×817 main window, and the window is **resized to that size**
before clicking — the ribbon scales with DPI, not with window width, so scaling
coordinates alone misses it.

## Not in this repo

The rendered exports (`out/agent-cut-v2.mp4`, 170 MB each) exceed GitHub's
per-file limit, so they are gitignored — as is `out/cut4-effects.mp4`, the
verified split+effects export. Their SHA256 is in
[docs/HANDOFF.md](docs/HANDOFF.md) §8: both v2 runs produced the identical file
`FDCA15802A463E3E7D0BF63AFF595E2E76013E8B6D7353891E48D31FB13CB16D`.

Also absent by design: the VideoPad installers, the registration backup, scratch
frame dumps, and the source media itself — the `.vpj` stores paths, not media.

