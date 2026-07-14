# Emberweft

*A native macOS, Apple-Silicon-GPU fractal-flame dream machine.*

[![License: PolyForm Noncommercial](https://img.shields.io/badge/license-PolyForm--NC-1.0.0-blue.svg)](https://polyformproject.org/licenses/noncommercial/1.0.0)
![Status](https://img.shields.io/badge/status-pre--alpha-orange)
![Platform](https://img.shields.io/badge/platform-macOS%2026%20·%20Apple%20Silicon-lightgrey)

**Status:** pre-alpha · docs-only · source-available (PolyForm Noncommercial)

<!-- hero: a striking flame frame -->

## What is it?

Emberweft is an independent re-implementation of Scott Draves' **fractal flame** algorithm — the math behind the famous *Electric Sheep* screensaver — built natively for Apple Silicon and Metal. It turns flame **genomes** (standard `.flam3` parameter files) into morphing, endlessly-evolving animations called **sheep**, and is designed to grow into a full generative-video studio: realtime playback, long-form export, audio-reactive music videos, a macOS screensaver, and multi-resolution output from vertical social clips to 4K.

It reads the standard `.flam3` genome format while remaining entirely independent of the Electric Sheep / Infinidream codebase and servers.

## Planned highlights

> Everything below is **on the roadmap** — Emberweft is pre-alpha and ships no runnable code yet. See [Status & Roadmap](#status--roadmap).

- Per-sheep video generation with local save (MP4/MOV)
- Endless playback with smooth [sheep transitions](docs/rendering/transitions.md) between genomes
- Realtime GPU generation or cached playback
- Long-form export for music videos and installations
- Music-video mode: offline + realtime audio-reactive
- macOS screensaver
- Multi-resolution: 720p / 1080p / 1440p / 4K
- Landscape & vertical formats for social media
- Curated seed library of hand-picked genomes

<!-- Screenshots placeholder: app window, screensaver preview, export dialog -->

## Why native Metal?

Apple Silicon's unified memory lets Metal compute shaders read and write the renderer's histogram buffers with no CPU–GPU copies, so a data-parallel fractal-flame pipeline runs at interactive framerates for far less energy than a CPU-only renderer. Emberweft is also built **test-first**: a portable CPU reference renderer is validated against the original `flam3`, and the Metal path is validated against the CPU one — see [development-approach.md](docs/engineering/development-approach.md).

## Status & Roadmap

| Milestone | Status | Description |
|-----------|--------|-------------|
| M0 | **Current** | Docs + repo scaffold |
| M1 | Planned | CPU reference renderer + `emberweft` CLI (validated vs `flam3`) |
| M2 | Planned | Metal compute renderer + Metal↔CPU parity |
| M3 | Planned | Animation (transitions) + realtime adaptive pipeline |
| M4 | Planned | SwiftUI app + player + library browser |
| M5 | Planned | macOS screensaver bundle |
| M6 | Planned | Export pipeline (incl. long-form) + codecs |
| M7 | Planned | Music-video / audio-reactive (offline + realtime VJ) |
| M8 | Planned | 4K/HDR, vertical/social presets, local genetics/breeding |

See full details in [docs/engineering/roadmap.md](docs/engineering/roadmap.md).

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
- [Testing](docs/engineering/testing.md) — test methodology, oracles, and CI gates
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

**No code yet — this repository currently contains design and specification documents only.** First usable build is expected at milestone **M1** (CPU reference renderer + `emberweft` CLI).
