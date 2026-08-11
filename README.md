# Emberweft

*A native macOS, Apple-Silicon-GPU fractal-flame dream machine.*

[![License: PolyForm Noncommercial](https://img.shields.io/badge/license-PolyForm--NC-1.0.0-blue.svg)](https://polyformproject.org/licenses/noncommercial/1.0.0)
![Status](https://img.shields.io/badge/status-pre--alpha-orange)
![Platform](https://img.shields.io/badge/platform-macOS%2026%20·%20Apple%20Silicon-lightgrey)

**Status:** pre-alpha · v0.5.5: CPU + Metal renderers, animation + realtime playback, motion-blurred real-genome parity, seamless boundaries, a full native SwiftUI studio (sidebar browser, multi-select, tri-state sentiment, search/filter, drag-drop import, collections, non-modal playback with configurable preview presets + live FPS, distinct preview/export quality settings), and the full video-export studio — a GUI export sheet (single/sequence/batch) with non-blocking progress + ETA + cancel, plus the `emberweft export` CLI, mastering-quality ProRes 422 HQ (and H.264/HEVC), calmer loop/transition pacing with eased boundaries, and loop render-once-repeat, plus export pause/resume + crash recovery, and temporal smoothing for low-spp exports (retuned quality tiers v0.5.3) — are working · source-available (PolyForm Noncommercial)

<!-- hero: a striking flame frame -->

## What is it?

Emberweft is an independent re-implementation of Scott Draves' **fractal flame** algorithm — the math behind the famous *Electric Sheep* screensaver — built natively for Apple Silicon and Metal. It turns flame **genomes** (standard `.flam3` parameter files) into morphing, endlessly-evolving animations called **sheep**, and is designed to grow into a full generative-video studio: realtime playback, long-form export, audio-reactive music videos, a macOS screensaver, and multi-resolution output from vertical social clips to 4K.

It reads the standard `.flam3` genome format while remaining entirely independent of the Electric Sheep / Infinidream codebase and servers.

## Features

**Works now (M0–M4 + M6 + M6.1 complete, v0.5.2):**
- `emberweft` CLI — `render`, `validate`, `info`, `animate`, `curate` — parses standard `.flam3` genomes into stills and animation sequences
- CPU reference renderer, a faithful port of `flam3` (near-byte-exact parity on synthetic goldens; **49–52 dB on real ES genomes**)
- Metal compute renderer — a faithful twin of the CPU path, **12–18× faster** at 1080p
- `--backend cpu|metal` switch; byte-deterministic within each backend
- Realtime playback engine — adaptive-quality `PlaybackDispatcher` + `FlameUI` (≥ 58 fps @ 1080p, M2 Max)
- Animation: seamless sheep **loops** (pure affine rotation) + smooth **transitions** between genomes, alternating endlessly — the Electric Sheep sequence
- **Motion blur** — faithful `temporal_samples` port (`--temporal-samples N`); box / gaussian / exp temporal filters
- Complete flam3 variation coverage — all **99 of 99** variations ported to CPU + Metal and validated ≥38 dB vs `flam3` (the classic set, the 16 special-sauce variations, the trig family, and the parametric/RNG remainder through `pre_blur`)
- **Native SwiftUI studio** (`emberweft-gui`): a `NavigationSplitView` sidebar browser (All / Library / ★ Liked / Imported / Folders), multi-select with bulk actions, tri-state sentiment (👍/○/👎), search + filter (sentiment / category / palette), drag-and-drop import, collections/playlists with drag reorder, and a non-modal click-to-play playback window. Thumbnails render on a background Metal queue (off-main, no UI freeze); settings persist.
- **Video export studio**: a GUI export sheet (single genome, collection-as-sequence, multi-select batch) with a non-blocking progress banner + ETA + cancel, and the `emberweft export` CLI. Mastering-quality **ProRes 422 HQ** default (and H.264/HEVC) via AVFoundation; frames byte-identical to `animate` (`--frame N --png` mastering path). Calmer pacing (separate loop/transition durations, eased transition boundaries) and loop render-once-repeat (seamless, halves loop render cost).

**Planned (M5, M7+):**
- macOS screensaver bundle
- Music-video mode: offline + realtime audio-reactive

<!-- Screenshots placeholder: app window, screensaver preview, export dialog -->

## Why native Metal?

Apple Silicon's unified memory lets Metal compute shaders read and write the renderer's histogram buffers with no CPU–GPU copies, so a data-parallel fractal-flame pipeline runs at interactive framerates for far less energy than a CPU-only renderer. Emberweft is also built **test-first**: a portable CPU reference renderer is validated against the original `flam3`, and the Metal path is validated against the CPU one — see [development-approach.md](docs/engineering/development-approach.md).

## Status & Roadmap

| Milestone | Status | Description |
|-----------|--------|-------------|
| M0 | ✅ Done | Docs + repo scaffold |
| M1 | ✅ Done | CPU reference renderer + `emberweft` CLI (validated vs `flam3`) |
| M2 | ✅ Done | Metal compute renderer + Metal↔CPU parity |
| M3 | ✅ Done | Animation (loops + transitions) + realtime adaptive pipeline |
| **v0.1.0** | ✅ Done | Real-genome parity (`highlight_power` / `filter`), motion blur, 4 more variations |
| **v0.1.1** | ✅ Done | Corpus-variation coverage (57/99 — 100% of ES-corpus-used variations) |
| **v0.1.2** | ✅ Done | **Full flam3 variation coverage (99/99)** — all validated ≥38 dB vs `flam3` + Metal↔CPU |
| **v0.1.3** | ✅ Done | **Fix:** Metal empty-frame regression on fragile multi-xform animations (const-ref `GPUXform` in kernels) |
| **v0.1.4** | ✅ Done | **Fix:** Metal Float-overflow collapses in 15 hyperbolic/trig/exp variations (clamp args to ±88) |
| **v0.1.5** | ✅ Done | **Fix:** transition endpoint faithfulness — `Transition(A,B,1.0)` now = B (mergeLog per-param INTERP + padding-final fields + propagate `paletteMode`) |
| **v0.1.6** | ✅ Done | **Fix:** transition smoothness — Quality field interpolation + `.log` det guard + endpoint padding-final drop |
| **v0.1.7** | ✅ Done | Transition-faithfulness audit (no remaining INTERP gaps) + Camera.scale log-space (perceptual, Weber-Fechner) |
| **v0.1.8–v0.1.9** | ✅ Done | Loop→transition boundary: port flam3's seqflag shortcut (v0.1.8), revert the offline sharp-frame regression (v0.1.9) |
| **v0.1.10** | ✅ Done | **Fix:** seamless boundaries — clip one-sided variation "leaks" (the blur-invariant over-bright at loop↔transition boundaries) |
| **v0.2.0** | ✅ Done | **M4 (part 1):** SwiftUI app first slice: library browser + click-to-play (off-main Metal thumbnails); `curate` CLI |
| **v0.3.0** | ✅ Done | **M4 complete:** sidebar browser, multi-select, tri-state sentiment, search/filter, drag-drop import, collections + reorder, non-modal playback window |
| **v0.3.1** | ✅ Done | **M4 polish:** configurable preview presets + live FPS readout (both playback windows); `testFiniteDeterministicRenders` crash fix (`intTrunc` guard) |
| **v0.3.2** | ✅ Done | **M4 polish:** distinct preview/export quality in Settings, per-parameter help tooltips, `⌘,` shortcut-collision fix, `make dist` target |
| **v0.4.0** | ✅ Done | **M6:** `emberweft export` to MP4/MOV (H.264 + HEVC), long-form concat, batch; `FramePlan` extraction; `ThreadSeedBudget` acceleration |
| **v0.5.5** | ✅ Done | **Quality tier auto-sets temporal samples:** picking Draft/Standard/High/Genome auto-sets ts to 1/4/16/genome-default (data-derived free motion blur); user can override |
| **v0.5.4** | ✅ Done | **Temporal-samples default fix:** named tiers (Draft/Standard/High) default to single-pass (was the genome's ~64) — eliminates +136% render overhead at spp 8 / +35% at spp 30 for invisible motion blur; genome-default unchanged |
| **v0.5.3** | ✅ Done | **Export quality-tier retune:** Draft/Standard/High → spp 8/30/100 (was 2/8/30); uniform smoothing window h=5 (free supersampling) — Standard ≈ genome-default clean at ~33× the speed |
| **v0.5.2** | ✅ Done | **M6.1 slice 2 temporal smoothing:** centered box window over per-frame histograms (smooth from frame 1, no lag), Metal fused-chaos + atomicBuf readback, per-chunk window + resume; early-pause checkpoint fix |
| **v0.5.1** | ✅ Done | **M6.1 export pause/resume:** Pause/Resume/Discard + crash recovery, interleaved byte-identical render loop, CLI `--checkpoint-frames`/`--resume`/`--discard` |
| **v0.5.0** | ✅ Done | **M6 GUI export:** export sheet + non-blocking progress/ETA/cancel, ProRes 422 HQ mastering default, off-main temporal Metal, separate loop/transition durations + rotation easing, loop render-once-repeat |
| M4 | ✅ Done | Native SwiftUI generative-flame studio |
| M5 | Current | macOS screensaver bundle |
| M6 | ✅ Done | Export pipeline + codecs (engine + CLI v0.4.0; GUI export studio v0.5.0; pause/resume v0.5.1; temporal smoothing v0.5.2) |
| M7 | Planned | Music-video / audio-reactive (offline + realtime VJ) |
| M8 | Planned | 4K/HDR, vertical/social presets, local genetics/breeding |

See full details in [docs/engineering/roadmap.md](docs/engineering/roadmap.md).

## Build & run

Requires macOS 26 on Apple Silicon (M1+) and Swift 6.2.

```
swift build                  # build
swift run emberweft render Tests/Goldens/genomes/sierpinski.flam3 -o out.png
swift run emberweft render Tests/Goldens/genomes/sierpinski.flam3 -o out.png --backend metal --size 160x100
swift run emberweft animate --frames 480 --segments 4 --backend metal --out seq/   # PNG sequence + manifest.json
swift run emberweft --list-backends
```

### The app (M4)

```
swift run emberweft-gui      # launch the SwiftUI app
```

The sidebar switches between **All** (unified), **Library** (curated 24-genome bundle), **★ Liked**, **Imported**, and each folder you open (**Open Directory…** → point at `genomes/electric-sheep/sheep/` for the full flock; open several at once). **Drag-and-drop** `.flam3` files in to import them. Click a thumbnail to open a non-modal realtime playback window (browse and rate while it plays); **filter** by name / sentiment / category / palette; **multi-select** (`⌘`/shift/`⌘A`) for bulk Like/Dislike or to **Save as Collection**; mark each genome with a tri-state **sentiment** (👍/○/👎). Collections play as a loop+transition sequence in their own window. Keyboard: Space, Esc, `+`/`0`/`−`, `⌘1–4`, `⌘?`. Thumbnails render off-main (Metal background queue) so the UI never freezes; settings persist across launches.

`--backend cpu` is the default for the CLI. `metal` is used when a Metal device is available (check with `--list-backends`). `animate` honors `--temporal-samples N` for motion blur (defaults to the genome's value on CPU; capped at 64 on Metal).

## Generating animations (loops & transitions)

`emberweft animate` writes a PNG sequence + `manifest.json` to `--out`; mux to MP4 with `ffmpeg`. Segments alternate **loop → transition → loop → …** (even segments loop one sheep, odd segments morph between two). Motion blur is `--temporal-samples N`.

**A single sheep loop** — `sheep_loop`: the genome rotates one full turn over the segment:

```bash
swift run -c release emberweft animate sheep.flam3 \
  --segments 1 --frames 160 --loop-cycles 1 \
  --backend metal --size 1280x720 --quality 500 --temporal-samples 32 --out loop/
ffmpeg -framerate 30 -i loop/%06d.png -c:v libx264 -pix_fmt yuv420p -movflags +faststart loop.mp4
```

**An edge / transition between two sheep** — `sheep_edge`: loop A → morph A→B → loop B:

```bash
swift run -c release emberweft animate a.flam3 b.flam3 \
  --segments 3 --frames 160 --loop-cycles 1 --selector sequential \
  --backend metal --size 1280x720 --quality 500 --temporal-samples 32 --out edge/
ffmpeg -framerate 30 -i edge/%06d.png -c:v libx264 -pix_fmt yuv420p -movflags +faststart edge.mp4
```

**A sequence of many sheep** — the Electric Sheep model (long-form video). Pass N genomes with `--segments 2N−1`; loops and transitions alternate over all of them:

```bash
swift run -c release emberweft animate s1.flam3 s2.flam3 s3.flam3 s4.flam3 \
  --segments 7 --frames 160 --loop-cycles 1 --selector sequential \
  --backend metal --size 1280x720 --quality 1000 --temporal-samples 32 --out flock/
ffmpeg -framerate 30 -i flock/%06d.png -c:v libx264 -pix_fmt yuv420p -movflags +faststart flock.mp4
```

- `--segments 1` = loop only (one sheep); `--segments 3` = loop + transition + loop (needs ≥2 genomes). For N genomes use `--segments 2N−1`. Default `--segments 3`.
- `--frames N` = frames per segment (one loop revolution over N frames; 160 @ 30 fps ≈ 5.3 s). `--loop-cycles N` = N revolutions per loop segment.
- `--temporal-samples N` = motion-blur sub-passes (defaults to the genome's `temporal_samples` on CPU; capped at 64 on Metal). Omit or set `1` for sharp frames.
- `--selector sequential` walks the library in order (`similarity` does ε-greedy pairing; needs `--library <dir>`).
- Use `--backend cpu` for byte-deterministic offline renders (uncapped temporal samples); `metal` for speed.
- **Seamless transitions need `--temporal-samples ≥ 16`** (motion blur). Lower reads as a hard cut. Since v0.1.10, one-sided variation "leaks" are clipped so loop↔transition boundaries match the loops (see [CHANGELOG](CHANGELOG.md)).
- **Re-render a single frame** after a change with `--frame N` (writes only `00000N.png`, skips the rest): render it, copy it over the old PNG in the sequence, re-mux.

Full flag reference + the `sheep_loop`/`sheep_edge` mapping: [docs/rendering/animation.md](docs/rendering/animation.md).

## Exporting video (M6)

The export studio has a **GUI sheet** (single genome / collection-as-sequence / multi-select batch, with a non-blocking progress banner + ETA + cancel) and the `emberweft export` **CLI**. It renders flame animations directly to MOV/MP4 via AVFoundation (mastering-quality **ProRes 422 HQ** default, or H.264/HEVC), reusing the same deterministic renderers as `animate`, so exported frames are byte-identical to `animate --frame N` (the `--frame N --png` path is the byte-exact mastering pin). The encoded file is NOT byte-stable across machines/OS versions; for byte-exact mastering use `animate` to PNG + ffmpeg.

```bash
# A single sheep loop to MP4
swift run -c release emberweft export sheep.flam3 --segments 1 --frames 160 \
  --backend metal --resolution 1080p --fps 30 --quality genome \
  --temporal-samples 32 --out loop.mp4

# An edge (loop A -> morph A->B -> loop B)
swift run -c release emberweft export a.flam3 b.flam3 --segments 3 --frames 160 \
  --backend metal --resolution 1080p --temporal-samples 32 --out edge.mp4

# Long-form (chunked + passthrough concat) and batch
swift run -c release emberweft export flock/*.flam3 --segment-frames 1600 --out long.mp4
swift run -c release emberweft export --jobs manifest.json --out /tmp/batch/ --fail-fast
```

- `--codec prores-422-hq|h264|hevc` (GUI default ProRes 422 HQ mastering, `.mov`; H.264/HEVC for `.mp4`; HEVC falls back to H.264 on unsupported hardware, or errors with `--strict-backend`). `--loop-repeat N` (render each loop once, output N× — seamless), `--transition-frames N`.
- `--quality genome` (faithful default, byte-matches `animate`) or `--quality N` (samples-per-pixel).
- `--temporal-samples N` for motion blur (defaults to the genome's value; essential for seamless transitions).
- `--segment-frames N` enables long-form (chunked render + passthrough concat, no re-encode).
- `--jobs manifest.json` runs a batch serially (continue-on-failure by default, or `--fail-fast`); each `out` is path-sanitized under `--out`.

## Validation

Emberweft is built test-first against two oracles: the CPU reference matches `flam3`, and Metal matches the CPU reference.

| Gate | Result |
|------|--------|
| CPU reference vs `flam3` goldens | 51–72 dB PSNR, SSIM ≈ 1.0 |
| Real ES genomes vs `flam3` (v0.1.0) | 49–52 dB PSNR across 7 gen-248 fixtures (≥ 38 gate) |
| Metal vs CPU (end-to-end) | 39–60 dB / SSIM ≥ 0.95 over 6 frozen genomes + fuzz |
| Metal display vs CPU tone-map (same histogram) | byte-exact (inf dB) |
| Metal chaos histogram vs CPU | count correlation > 0.999 |
| MSL ISAAC vs Swift ISAAC | byte-identical stream |
| Animation vs `flam3-animate` (loops + transitions) | 43–58 dB PSNR |
| Realtime capability (M3 gate) | ≥ 58 fps sustained @ 1080p (M2 Max) |
| Within-backend determinism | byte-identical output across runs |
| Metal speedup vs single-threaded CPU (1080p) | 12–18× |

The local test suite is the source of truth (320+ tests, all green). GitHub is a plain git mirror; see [testing.md](docs/engineering/testing.md).

## Documentation

### Overview
- [Project Overview](docs/overview.md) — vision, audience, and feature pillars
- [Background](docs/background.md) — fractal flames history and context

### Architecture
- [System Architecture](docs/architecture.md) — components, data flow, and design decisions

### Rendering
- [Flame Algorithm](docs/rendering/flame-algorithm.md) — the fractal flame math and IFS
- [Metal Pipeline](docs/rendering/metal-pipeline.md) — GPU compute architecture and shaders
- [Genome Format](docs/rendering/genome-format.md) — .flam3 parameter structure and parsing
- [Transitions](docs/rendering/transitions.md) — morphing and interpolation between genomes

### Playback
- [Playback Modes](docs/playback/playback-modes.md) — real-time, cached, and screensaver modes
- [Formats](docs/playback/formats.md) — resolutions, aspect ratios, and output containers

### Export
- [Export Pipeline](docs/export/export-pipeline.md) — encoding, quality settings, and batch rendering
- [Music Video](docs/export/music-video.md) — audio-reactive rendering and offline processing

### Platform
- [Screensaver](docs/platform/screensaver.md) — macOS ScreenSaver.framework integration
- [App UI](docs/platform/app-ui.md) — SwiftUI/AppKit interface and controls

### Library
- [Seed Library](docs/library/seed-library.md) — curated genome collection and metadata
- [Genetics](docs/library/genetics.md) — mutation, crossover, and evolution

### Engineering
- [Development Approach](docs/engineering/development-approach.md) — methodology, build order, GPU strategy, testing
- [Testing](docs/engineering/testing.md) — test methodology, oracles, and the local pre-merge gate
- [Tech Stack](docs/engineering/tech-stack.md) — Swift 6, Metal 4, AVFoundation, dependencies
- [Project Layout](docs/engineering/project-layout.md) — source organization and conventions
- [Performance](docs/engineering/performance.md) — benchmarks, profiling, and optimization targets
- [Roadmap](docs/engineering/roadmap.md) — milestones and timeline
- [Glossary](docs/engineering/glossary.md) — domain terminology

### License
- [License & Attribution](docs/license-and-attribution.md) — licensing policy and credits

## Tech Stack

Swift 6 · Metal 4 (compute) · SwiftUI/AppKit · AVFoundation · Accelerate · **macOS 26 · Apple Silicon (M1 or later)**

## Contributing

Emberweft is **source-available under PolyForm Noncommercial** — free to study, use, and modify for noncommercial purposes; commercial use requires a commercial license.

- **Contributions are welcome once the project's Contributor License Agreement (CLA) is in place** (added at the M0 bootstrap). The CLA preserves the maintainer's commercial option — a necessity under a noncommercial license. See `CONTRIBUTING.md`.
- By contributing you acknowledge the noncommercial license terms and the CLA requirement.
- Questions or ideas? Open a GitHub Issue, or pick a slice from the [roadmap](docs/engineering/roadmap.md).

## License, Credit & Trademarks

**Code:** [PolyForm Noncommercial 1.0.0](https://polyformproject.org/licenses/noncommercial/1.0.0/) — **source-available**, free for noncommercial use; commercial use requires a commercial license. **Curated seed library:** CC-BY-NC 4.0. Emberweft is *not* "open source" (OSI); it is source-available.

The fractal flame algorithm was created by **Scott Draves** in 1992. "Electric Sheep" and "Infinidream" are trademarks of Scott Draves / e-dream, inc. Emberweft is an independent re-implementation, format-compatible with `.flam3`, and is **not affiliated with, endorsed by, or derived from** the Electric Sheep or Infinidream source code or servers.

Full details: [docs/license-and-attribution.md](docs/license-and-attribution.md).

## References

**Algorithm & primary sources**
- [The Fractal Flame Algorithm](https://flam3.com/flame_draves.pdf) — original paper by Scott Draves & Erik Reckase
- [Fractal flame — Wikipedia](https://en.wikipedia.org/wiki/Fractal_flame) — algorithm overview
- [Electric Sheep — Wikipedia](https://en.wikipedia.org/wiki/Electric_Sheep) — history & technical overview
- [scottdraves/flam3](https://github.com/scottdraves/flam3) — reference C implementation
- [electricsheep.org](https://electricsheep.org) · [infinidream.ai](https://infinidream.ai) — original & current-generation services

**Related clients (study, not bundled)**
- [scottdraves/electricsheep](https://github.com/scottdraves/electricsheep) — original distributed screensaver client
- [e-dream-ai/client](https://github.com/e-dream-ai/client) — Infinidream client
- [guysoft/electricsheep-hd-client](https://github.com/guysoft/electricsheep-hd-client) — HD client fork

**Content ecosystem (commercial precedents for long-form / 4K / relaxation use cases)**
- [Sheep Dreams (esheeper.com)](https://esheeper.com) — 1080p gold-sheep pack distributor
- [Stream Dreamz](https://streamdreamz.vhx.tv) — hour-long relaxation/meditation flame videos (up to 4K)

---

**M0–M4 + M6 + M6.1 are complete (v0.5.2):** the CPU reference renderer, the Metal compute renderer, animation + realtime playback, motion-blurred real-genome parity, the full native SwiftUI studio (sidebar browser, multi-select, tri-state sentiment, search/filter, drag-drop import, collections, non-modal playback with configurable preview presets + live FPS), and the full video-export studio (GUI sheet + `emberweft export` CLI, ProRes mastering, eased pacing, loop render-once-repeat, temporal smoothing for low-spp exports) all work today. **M6.1** (export pause/resume v0.5.1 + temporal smoothing v0.5.2) is done; **M5** (the macOS screensaver bundle) is next: see the [roadmap](docs/engineering/roadmap.md).
