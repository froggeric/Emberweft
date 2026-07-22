# Emberweft

*A native macOS, Apple-Silicon-GPU fractal-flame dream machine.*

[![License: PolyForm Noncommercial](https://img.shields.io/badge/license-PolyForm--NC-1.0.0-blue.svg)](https://polyformproject.org/licenses/noncommercial/1.0.0)
![Status](https://img.shields.io/badge/status-pre--alpha-orange)
![Platform](https://img.shields.io/badge/platform-macOS%2026%20·%20Apple%20Silicon-lightgrey)

**Status:** pre-alpha · v0.1.0 — CPU + Metal renderers, animation + realtime playback, and motion-blurred real-genome parity are working · source-available (PolyForm Noncommercial)

<!-- hero: a striking flame frame -->

## What is it?

Emberweft is an independent re-implementation of Scott Draves' **fractal flame** algorithm — the math behind the famous *Electric Sheep* screensaver — built natively for Apple Silicon and Metal. It turns flame **genomes** (standard `.flam3` parameter files) into morphing, endlessly-evolving animations called **sheep**, and is designed to grow into a full generative-video studio: realtime playback, long-form export, audio-reactive music videos, a macOS screensaver, and multi-resolution output from vertical social clips to 4K.

It reads the standard `.flam3` genome format while remaining entirely independent of the Electric Sheep / Infinidream codebase and servers.

## Features

**Works now (M0–M3, v0.1.0):**
- `emberweft` CLI — `render`, `validate`, `info`, `animate` — parses standard `.flam3` genomes into stills and animation sequences
- CPU reference renderer, a faithful port of `flam3` (near-byte-exact parity on synthetic goldens; **49–52 dB on real ES genomes**)
- Metal compute renderer — a faithful twin of the CPU path, **12–18× faster** at 1080p
- `--backend cpu|metal` switch; byte-deterministic within each backend
- Realtime playback engine — adaptive-quality `PlaybackDispatcher` + `FlameUI` (≥ 58 fps @ 1080p, M2 Max)
- Animation: seamless sheep **loops** (pure affine rotation) + smooth **transitions** between genomes, alternating endlessly — the Electric Sheep sequence
- **Motion blur** — faithful `temporal_samples` port (`--temporal-samples N`); box / gaussian / exp temporal filters
- Wide variation coverage — the classic set plus the 16 special-sauce variations and `bubble` / `eyefish` / `pie` / `radial_blur`

**Planned (M4+):**
- SwiftUI app with library browser, search, and playback controls
- macOS screensaver bundle
- Long-form export (MP4/MOV) for music videos and installations
- Music-video mode: offline + realtime audio-reactive
- Multi-resolution: 720p / 1080p / 1440p / 4K; landscape & vertical
- Curated seed library of hand-picked genomes

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
| M4 | **Current** | SwiftUI app + player + library browser |
| M5 | Planned | macOS screensaver bundle |
| M6 | Planned | Export pipeline (incl. long-form) + codecs |
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

`--backend cpu` is the default. `metal` is used when a Metal device is available (check with `--list-backends`). `animate` honors `--temporal-samples N` for motion blur (defaults to the genome's value on CPU; capped at 64 on Metal).

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

- `--segments 1` = loop only (one sheep); `--segments 3` = loop + transition + loop (needs ≥2 genomes). Default `--segments 3`.
- `--frames N` = frames per segment (one loop revolution over N frames; 160 @ 30 fps ≈ 5.3 s). `--loop-cycles N` = N revolutions per loop segment.
- `--temporal-samples N` = motion-blur sub-passes (defaults to the genome's `temporal_samples` on CPU; capped at 64 on Metal). Omit or set `1` for sharp frames.
- `--selector sequential` walks the library in order (`similarity` does ε-greedy pairing; needs `--library <dir>`).
- Use `--backend cpu` for byte-deterministic offline renders (uncapped temporal samples); `metal` for speed.

Full flag reference + the `sheep_loop`/`sheep_edge` mapping: [docs/rendering/animation.md](docs/rendering/animation.md).

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

**M0–M3 are complete (v0.1.0):** the CPU reference renderer, the Metal compute renderer, animation + realtime playback, and motion-blurred real-genome parity all work today. M4 (SwiftUI app + library browser) is next — see the [roadmap](docs/engineering/roadmap.md).
