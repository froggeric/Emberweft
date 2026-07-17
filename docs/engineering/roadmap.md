# Roadmap

*Development milestones from initial documentation through post-MVP features and enhancements.*

> **Status:** preliminary — for review · Emberweft

## Current Status

**Current milestone:** M3 — Animation and Realtime Pipeline · **M0, M1, and M2 complete** (see [CHANGELOG.md](../../CHANGELOG.md))

> **How we build:** milestones describe *what* ships; the slice-by-slice build order, TDD methodology, GPU strategy, and oracle validation live in [development-approach.md](development-approach.md), and the test gates in [testing.md](testing.md). Milestones map to development slices as **M0→S0, M1→S1–S4, M2→S5, M3→S6–S7, M4→S8, M5→S9, M6→S10, M7→S11, M8→S12.**

## Milestones

### M0 — Docs + Repo Scaffold ✅

**Goal:** Establish project foundation with comprehensive documentation and repository structure. (Slice S0.)

**Key deliverables:**
- Complete documentation set (all docs/*.md files)
- `git init` + repository structure (Sources, Tests, Resources)
- `Package.swift` with module targets: FlameKit, FlameReference, FlameRenderer, FlamePlayer, FlameExport + `emberweft` executable
- `LICENSE` (PolyForm-Noncommercial-1.0.0) + `LICENSE-SEEDS` (CC-BY-NC-4.0)
- `CONTRIBUTING.md` (CLA-before-external-PR note), `CLAUDE.md`, `.gitignore`
- CI workflow (GitHub Actions macOS runner): build + test + lint
- `swift-format` config + pre-commit hook
- README updated to "source-available" wording with build instructions

**Dependencies:** None (starting point)

**Definition of done:**
- All documentation files are substantive (no stubs or TODOs)
- Repository can be cloned and `swift build` succeeds
- CI runs green on an empty-but-compiling package
- README provides clear build/run instructions
- Documentation cross-references are complete and accurate

### M1 — CPU Reference Renderer + CLI ✅

**Goal:** A correct, usable CPU renderer and CLI that produces a single still image from a `.flam3` file, validated against `flam3`. (Slices S1–S4.) This is a complete, shippable product slice on its own.

**Key deliverables:**
- **FlameKit** — genome model, `.flam3` parse/serialize, validation, temporal interpolation (S1)
- **FlameReference** — CPU renderer: chaos game → histogram → log-density → density-estimation filter → palette/gamma (S2)
- **Golden oracle harness** — dev-only `flam3` (Homebrew); frozen genome set; PSNR/SSIM comparison (S3)
- **`emberweft` CLI** — `render` / `validate` / `info`, CPU backend (S4)

**Dependencies:** M0 complete

**Definition of done:**
- Parses `.flam3` files; rejects malformed input
- CPU renderer matches `flam3` goldens within thresholds (PSNR/SSIM — see [testing.md](testing.md))
- `emberweft render` works end-to-end on the CPU backend
- Same seed → identical frame (determinism)
- Single-frame CPU performance baseline recorded

### M2 — Metal Renderer + Parity ✅

**Goal:** Port the renderer to Metal compute and prove it matches the CPU reference. (Slice S5.)

**Key deliverables:**
- **FlameRenderer (Metal compute)** — chaos-game/histogram kernel, density-estimation filter, palette/gamma
- `--backend cpu|metal` switch in the CLI
- **Parity tests** — Metal output vs FlameReference (statistical + PSNR)

**Dependencies:** M1 complete

**Definition of done:**
- Metal renderer matches the CPU renderer within parity thresholds (see [testing.md](testing.md))
- `--backend metal` produces correct stills
- Same seed → identical frame on Metal
- Metal single-frame performance baseline recorded; Metal-vs-CPU speedup measured

### M3 — Animation and Realtime Pipeline

**Goal:** Seamless looping sheep, smooth transitions between them, and realtime Metal playback with adaptive quality. (Slices S6–S7.)

**Two segment kinds (mirrors the original Electric Sheep):**
- **Loop** — animate a single sheep by rotating the 2×2 linear part of each xform's affine matrix through a full 360° while cycling its palette circularly (flam3 `sheep_loop`, driven by `blend ∈ [0,1]`); seamless because 360°=0° and the palette wraps. This is structural motion of one genome via the same blend pipeline transitions use, and it is what animates still (single-keyframe) sheep. Segment length matches the original ES: **128 (classic) / 160 (modern) frames at ~23 fps ≈ 5.5–7 s**, played once then transitioned.
- **Transition** — a morph from genome A's parameters to genome B's over a short segment.

**Sequencing rule:** loops and transitions **alternate** — `loop(A) → transition(A→B) → loop(B) → transition(B→C) → …`. Transitions are always bracketed by loops; **never two transitions in a row**. This matches how the original Electric Sheep sequences its videos.

**Key deliverables:**
- **Loop playback** — animate each (still) sheep via flam3 `sheep_loop`: rotate the genome 0→360° + circular palette cycle over `nframes` (seamless). Same blend pipeline as transitions.
- Genome interpolation for smooth **transitions** between genomes ([transitions.md](../rendering/transitions.md))
- `emberweft animate` (CLI) producing alternating loop/transition segments (S6)
- **FlamePlayer** realtime adaptive engine (S7)
- **FlameUI** Metal-layer wrapper (`CAMetalLayer`)
- Adaptive quality controller based on performance/thermal state
- Genome sequencing logic that alternates loop and transition segments per the rule above

**Dependencies:** M2 complete

**Definition of done:**
- A sheep's `sheep_loop` (360° rotation + palette cycle) plays seamlessly (frame N = frame 0)
- Can play a sequence of genomes where loops and transitions alternate, with no two transitions consecutive
- Realtime playback at target fps at 1080p *(preliminary: 60 fps on M2 Max)*
- Adaptive quality adjusts based on thermal state
- Transitions are visually smooth (no popping or discontinuities)
- Unit tests for interpolation math (both within-genome loops and between-genome transitions); animated-frame parity

### M4 — SwiftUI App and Library Browser

**Goal:** Build the main application UI with library browsing, search, and playback controls. (Slice S8.)

**Key deliverables:**
- SwiftUI app structure (EmberweftApp target)
- Library browser with grid/list views
- Thumbnail generation for library entries
- Search and filter UI (tags, rating, palette)
- Playback view with transport controls
- Settings view (quality preferences, feature toggles)
- Metadata editor (edit genome title, tags, rating)
- Seed library with at least 20 curated genomes
- Drag-and-drop import of .flam3 files
- Bookmark/favorite system

**Dependencies:** M3 complete

**Definition of done:**
- App launches and displays seed library
- Can browse, search, and filter genomes
- Click-to-play from library
- Can import new genomes via drag-and-drop
- Settings are persisted and respected
- Thumbnails are generated and cached
- Basic accessibility support (VoiceOver labels)

### M5 — macOS Screensaver Bundle

**Goal:** Complete the screensaver bundle with settings and performance optimization. (Slice S9.)

**Key deliverables:**
- Complete ScreenSaver.framework integration
- Screensaver preferences panel
- Quality settings specific to screensaver
- App-group container sharing for seed library access
- Energy-efficient defaults (lower FPS, adaptive quality)
- Screen-sleep detection and respect
- Multi-monitor support (render on each display)
- Installation and testing on real screensaver

**Dependencies:** M4 complete

**Definition of done:**
- Screensaver installs and activates correctly
- Reads seed library from app-group container
- Plays smoothly *(preliminary: 30 fps on 1080p displays)*
- Settings panel works and persists preferences
- Respects screen sleep and system power events
- Tested on at least two displays (if available)

### M6 — Export Pipeline

**Goal:** Implement video export with codec support and progress tracking. (Slice S10.)

**Key deliverables:**
- FlameExport module with AVFoundation integration
- Export pipeline coordinator
- Codec support (H.264 baseline, HEVC optional)
- Resolution and quality presets
- Export progress UI with cancellation
- Batch export (multiple genomes)
- Export settings (duration, resolution, codec, quality)
- Export validation (compare output to realtime rendering)

**Dependencies:** M4 complete (can proceed in parallel with M5)

**Definition of done:**
- Can export a single genome to MP4 (H.264)
- Can export a sequence with transitions
- Progress bar updates accurately
- Can cancel export mid-stream
- Exported video matches realtime rendering quality (determinism)
- At least 3 export presets (720p/1080p/4K)

### M7 — Music Video and Audio-Reactive Features

**Goal:** Add audio analysis and audio-reactive parameter modulation for music-video generation. (Slice S11.)

**Key deliverables:**
- Audio analysis module (beat detection, BPM, onsets)
- Audio-reactive renderer (modulate parameters based on audio)
- Real-time VJ mode (live audio input)
- Offline music-video export (audio file → synchronized video)
- Audio visualization modes (beat-sync, spectrum-based)
- Audio file import UI
- Parameter mapping UI (which genome parameters respond to which audio features)

**Dependencies:** M6 complete

**Definition of done:**
- Can import audio files and analyze them
- Beat detection accuracy >80% on test tracks *(preliminary)*
- Offline export produces synchronized music videos
- Real-time VJ mode responds to live audio within *(preliminary: 50 ms)*
- UI for customizing parameter mapping
- Example music-video exports for demo

### M8 — Advanced Features

**Goal:** Add polish, advanced formats, and exploratory features. (Slice S12.)

**Key deliverables:**
- 4K and HDR support (10-bit color, HDR displays)
- Vertical/social media presets (TikTok, Instagram Reels)
- Local genetics/breeding system (if not completed earlier)
- Advanced export codecs (ProRes, AV1)
- Custom palette editor
- Genome comparison/diff view
- Performance optimization pass

**Dependencies:** M7 complete

**Definition of done:**
- 4K export at target fps on M2 Max
- HDR output validates on HDR display
- Vertical presets render at 1080×1920
- Genetics system allows mutation and breeding
- Custom palette can be created and saved
- Performance benchmarks meet targets
- Documentation is complete and up-to-date

## Milestone Dependencies

```
M0 (Foundation)
  ↓
M1 (CPU reference + CLI)
  ↓
M2 (Metal renderer + parity)
  ↓
M3 (Animation + realtime)
  ↓
M4 (SwiftUI app) ←───→ M5 (Screensaver)
  ↓
M6 (Export)
  ↓
M7 (Audio-reactive)
  ↓
M8 (Advanced features)
```

**Parallel development:**
- M4 (app) and M5 (screensaver) can be developed in parallel after M3
- M6 (export) can proceed in parallel with M5
- M7 and M8 are sequential and depend on all previous milestones

## Timeline and Prioritization

**No timeline commitment:** This roadmap defines milestone order and dependencies, but not specific dates or durations. Each milestone will be estimated based on progress and resources available.

**Prioritization principles:**
1. **Core rendering first:** M1 (CPU reference) and M2 (Metal) are the foundation — proven correct before anything else
2. **Realtime next:** M3 makes it move
3. **App before screensaver:** M4 before M5 for easier debugging
4. **Export before audio:** M6 before M7 for a simpler dependency chain
5. **Polish last:** M8 features can be deferred if needed

**Milestone completion criteria:**
- All key deliverables are implemented
- Definition of done checklist is satisfied
- Documentation is updated for the milestone
- No known regressions from previous milestones
- Basic performance targets are met

## Future / Exploratory

Features that may be explored after the core product is complete. These are **not committed** and may never be implemented — they represent potential directions if there is user interest and developer capacity.

**Community and sharing:**
- Import/export of curated genome packs
- Genome sharing via file or URL
- Collaborative breeding challenges

**Advanced rendering:**
- Stereoscopic 3D rendering
- VR headset support (visionOS)
- Multi-screen gallery installations
- Projection mapping support

**Generative / exploratory:** *(non-neural — these are search, curation, and heuristic tools, not AI models)*
- Assisted genome generation and curation tools
- Style transfer / palette matching between genomes
- Fitness heuristics for the local genetics system
- Quality prediction for batch rendering

**Platform expansion:**
- iOS/iPadOS app (with Metal rendering)
- Web version (WebGPU port)

**Creative tools:**
- Keyframe animation editor
- Custom variation editor (create new variations)
- Shader graph editor for advanced users

## Related Documentation

- [`development-approach.md`](development-approach.md) — Methodology, build order (S0–S12), GPU strategy
- [`testing.md`](testing.md) — Test methodology, oracles, CI gates
- [`../architecture.md`](../architecture.md) — System architecture and module organization
- [`tech-stack.md`](tech-stack.md) — Technology choices supporting the roadmap
- [`project-layout.md`](project-layout.md) — Repository structure for milestone work
- [`performance.md`](performance.md) — Performance targets for each milestone

---

**Credit**: fractal flame algorithm © Scott Draves (1992). Electric Sheep™ and Infinidream™ are trademarks of Scott Draves / e-dream, inc.
