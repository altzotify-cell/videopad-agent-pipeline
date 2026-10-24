# videopad — agent-driven video editing

Turns a JSON edit spec into a VideoPad project and renders it to `.mp4`
unattended. VideoPad is the renderer; the agent only writes the project and
supplies the click.

```
examples/cut1.json  →  tools/New-Project.ps1  →  out/cut1.vpj  →  VideoPad  →  out/*.mp4
```

**Can an agent edit in VideoPad?** Yes for cutting, for structural edits that add
or remove timeline clips, for splits plus video effects, and for pacing: the
writer (v4) reuses a source any number of times, drops clips, adds new media
files, mutes segments, splits a clip at arbitrary cut points, writes per-segment
effect chains from `tools/effects.json`, changes playback speed and fades clips
in/out. Cut-only work was verified end to end to within 6 ms of expected duration
and byte-identical across runs; the v2, v3 and v4 features were verified against
VideoPad's own autosave re-serialisation and a real export (`out/oracle/`). Not
yet: transitions, titles and audio mixing (per-clip volume has no known carrier —
the obvious fields round-trip but do nothing; see
[docs/HANDOFF.md](docs/HANDOFF.md) §8).

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

Five specs to copy from:

| spec | shows |
|---|---|
| [`examples/cut1.json`](examples/cut1.json) | trim + reorder, one segment per source (byte-identical to the v1 writer) |
| [`examples/cut2-reuse.json`](examples/cut2-reuse.json) | one source used 3×, a dropped clip, a muted segment |
| [`examples/cut3-addmedia.json`](examples/cut3-addmedia.json) | added media between two episode segments |
| [`examples/cut4-split-effects.json`](examples/cut4-split-effects.json) | splits at 2 s/4 s and 3 s, saturation on all three episode clips, rotate, mirror + Bright-with-contrast |
| [`examples/cut5-cadence.json`](examples/cut5-cadence.json) | 2× / 1× / 0.5× / 2× speed segments, partial fades in and out, mirror on a sped clip |

`.\tools\Test-Examples.ps1` rebuilds all five and fails unless each one reproduces
its committed `.vpj` byte-for-byte — run it after touching the writer.

`cut3`, `cut4` and `cut5` need the same scratch clip first (it is gitignored, and
it is also what the rotate/crop checks in `out/oracle/cut4-verify.ps1` and the
timecode/luma checks in `out/oracle/cut5-verify.ps1` use as source):

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

## Driving it from an agent

The repo is built to be operated by an agent rather than by hand, and that part is
documented separately:

- [docs/AGENT-RUNBOOK.md](docs/AGENT-RUNBOOK.md) — the loop, measured costs, a
  failure taxonomy, and the invariants that must not be automated away.
- [agent/tools.json](agent/tools.json) — seven functions with JSON-Schema
  arguments, so you can hand a model a tool list instead of a codebase.
- [agent/system-prompt.md](agent/system-prompt.md) — a paste-ready contract:
  rules, loop, budgets, reporting format.
- [tools/Invoke-AgentStep.ps1](tools/Invoke-AgentStep.ps1) — runs one step in a
  child PowerShell and prints `{ok, exitCode, seconds, stdout, stderr}`.
- [agent/Invoke-PadTool.ps1](agent/Invoke-PadTool.ps1) — fills a manifest
  template and runs it, validating every argument first.

```powershell
.\tools\Invoke-AgentStep.ps1 -Step gate -Command '.\tools\Test-Examples.ps1'
.\agent\Invoke-PadTool.ps1 -Name videopad_build -Arguments @{ spec = 'examples\cut5-cadence.json' }
```

## Not in this repo

The rendered exports (`out/agent-cut-v2.mp4`, 170 MB each) exceed GitHub's
per-file limit, so they are gitignored — as are `out/cut4-effects.mp4` and
`out/cut5-cadence.mp4`, the verified split+effects and speed+fade exports. Their
SHA256 is in [docs/HANDOFF.md](docs/HANDOFF.md) §8: both v2 runs produced the
identical file
`FDCA15802A463E3E7D0BF63AFF595E2E76013E8B6D7353891E48D31FB13CB16D`. Everything
needed to regenerate and re-measure them is committed
(`out/oracle/cut*verify.ps1`, `tools/Compare-Vpj.ps1`).

Also absent by design: the VideoPad installers, the registration backup, scratch
frame dumps, and the source media itself — the `.vpj` stores paths, not media.

