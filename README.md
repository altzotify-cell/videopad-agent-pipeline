# videopad — agent-driven video editing

Turns a JSON edit spec into a VideoPad project and renders it to `.mp4`
unattended. VideoPad is the renderer; the agent only writes the project and
supplies the click.

```
examples/cut1.json  →  tools/New-Project.ps1  →  out/cut1.vpj  →  VideoPad  →  out/*.mp4
```

**Can an agent edit in VideoPad?** Yes for cutting *and* for structural edits that
add or remove timeline clips: the writer (v2) reuses a source any number of times,
drops clips, adds new media files and mutes segments. Cut-only work was verified
end to end to within 6 ms of expected duration and byte-identical across runs;
the v2 features were verified against VideoPad's own autosave re-serialisation and
a real export (`out/oracle/`). Not yet: split, effects/transitions/titles, speed,
audio mixing.

| start here | what it is |
|---|---|
| **[docs/HANDOFF.md](docs/HANDOFF.md)** | **read this first** — verdict, environment, commands, UI-automation rules, open work, new-session bootstrap prompt |
| [docs/vpj-format-findings.md](docs/vpj-format-findings.md) | `.vpj` format reference: sections, handles, checksum, timeline semantics, export details |

Quickstart (VideoPad must not already be running — `Open-Project.ps1` closes it):

```powershell
.\tools\New-Project.ps1 -Spec .\examples\cut1.json
.\tools\Export-Project.ps1 -ProjectPath .\out\cut1.vpj `
    -OutputPath .\out\agent-cut.mp4 -ExpectedDurationMs 210000
```

Three specs to copy from:

| spec | shows |
|---|---|
| [`examples/cut1.json`](examples/cut1.json) | trim + reorder, one segment per source (byte-identical to the v1 writer) |
| [`examples/cut2-reuse.json`](examples/cut2-reuse.json) | one source used 3×, a dropped clip, a muted segment |
| [`examples/cut3-addmedia.json`](examples/cut3-addmedia.json) | added media between two episode segments |

`.\tools\Test-Examples.ps1` rebuilds all three and fails unless each one reproduces
its committed `.vpj` byte-for-byte — run it after touching the writer.

`cut3` needs its scratch clip first (it is gitignored):

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
per-file limit, so they are gitignored. Their SHA256 is in
[docs/HANDOFF.md](docs/HANDOFF.md) §8 — both runs produced the identical file:
`FDCA15802A463E3E7D0BF63AFF595E2E76013E8B6D7353891E48D31FB13CB16D`.

Also absent by design: the VideoPad installers, the registration backup, scratch
frame dumps, and the source media itself — the `.vpj` stores paths, not media.

