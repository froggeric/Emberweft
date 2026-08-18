# Architecture
*System design and component organization*
> **Status:** preliminary — for review · Emberweft

## Overview

Emberweft is a native macOS application that implements the fractal flame algorithm as a GPU-accelerated renderer. The architecture is organized into distinct layers separating genome modeling, rendering, playback, export, and user interface. A **CPU reference renderer** (`FlameReference`) sits beside the Metal renderer as the correctness oracle, deterministic offline renderer, and GPU-less fallback — see [development-approach.md](engineering/development-approach.md).

## Layered Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              APP LAYER                                       │
├─────────────────┬─────────────────────────┬─────────────────────────────────┤
│   SwiftUI App   │   ScreenSaver Bundle    │   emberweft CLI             │
│  (emberweft-gui)│   (.saver target, M5)   │   (render/animate/curate/…)      │
├─────────────────┴─────────────────────────┴─────────────────────────────────┤
│                            EmberweftUI (M4)                                  │
│   (SwiftUI↔AppKit bridge, playback conformers, thumbnail service,          │
│    library/settings models — shared by app + screensaver)                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                              FlamePlayer                                      │
│   (Playback Engine: adaptive generation, caching, transitions)              │
├─────────────────────────────────────────────────────────────────────────────┤
│                              FlameExport                                      │
│   (AVFoundation export: codecs, long-form rendering)                       │
├─────────────────────────────────────────────────────────────────────────────┤
│                            FlameRenderer                                     │
│   (Metal Compute Pipeline: histogram → density → tone-map;                  │
│    @MainActor realtime path + off-main background path)                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                              FlameKit                                        │
│   (Genome Model + .flam3 Parse/Serialize + Temporal Interpolation)         │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Component Modules

### FlameKit (Core Model)

**Purpose:** Pure Swift genome modeling and XML parsing

FlameKit provides the data model for fractal flame genomes:

- **Flame struct** — Root genome container: transforms, color palette, camera/view parameters, quality settings
- **Xform struct** — Individual affine transform with variation weights, color index, chaos matrix
- **Variation enum** — Non-linear functions (linear, sinusoidal, spherical, swirl, etc.)
- **Palette struct** — 256-entry color lookup table with interpolation support
- **Camera/View structs** — Center, scale, rotation, aspect ratio handling
- **XML Parser** — .flam3 format deserialization/serialization with validation
- **Temporal Interpolation** — Smooth parameter morphing between animation keyframes
- **Animation subsystem (M3)** — the faithful flam3 port that drives motion:
  - `Loop.blend` — `sheep_loop`: pure 360° pre-affine rotation `R(θ)·M` of each
    animating, non-final xform (palette static; seamless because `R(360°)=R(0°)`).
  - `Transition.blend` — `sheep_edge`: align + special-sauce-pad → rotate both
    endpoints → `GenomeInterpolator` (`.log` polar matrix blend) → `PaletteBlend`
    (HSV-circular palette mix + linear `hue_rotation`).
  - `GenomeInterpolator` — `.linear` (legacy) and `.log` (polar decomposition
    with wind-anchored angle unwrap + per-column magnitude guard); per-xform
    `stagger`.
  - `Schedule` — a pure `Sendable` value-type timeline: O(1) global-frame →
    `(segmentId, kind, blend)`, strict loop/transition alternation by id parity.
  - `PairSelector` — `Sequential` (cyclic) and `SimilarityExploration`
    (ε-greedy, F1-deterministic over sorted-array `FeatureVector`s).
  - `PaletteBlend` / `SpecialSauce` / `RefAngles` — the supporting `sheep_edge`
    pieces (HSV palette mix, rest-position padding, wind-angle anchors).
  - `Framing` — the pure M6.6 width normalization: a genome's `camera.scale`
    is absolute pixels-per-unit authored for its `size`, so rendering at
    another width rescales it by `renderWidth / size.x` (identity at the
    authored width; degenerate headers pass through unchanged). Consumed at
    the export/flock/preview entry points via `ExportSettings.framing`; the
    renderers and `animate` never apply it.

FlameKit has no Metal dependencies and can be used in headless tools or tests.

### FlameReference (CPU Reference Renderer)

**Purpose:** Portable, deterministic CPU implementation of the full fractal-flame pipeline.

FlameReference is a **permanent, shippable module** with three roles:

1. **Parity oracle** — the source of truth that `FlameRenderer` (Metal) is validated against under the local pre-merge gate (see [testing.md](engineering/testing.md)).
2. **Deterministic offline renderer** — verifies export reproducibility and renders in environments without a usable GPU.
3. **Algorithm laboratory** — the easiest place to unit-test variations, filters, and interpolation with per-function tests.

It is a faithful Swift port of `flam3`'s algorithms (affine convention, variation formulas, ISAAC RNG, density estimation, display pipeline) in pure Swift, Double precision. Maintaining two renderers is deliberate: algorithm bugs and GPU bugs localize instantly (CPU-passes-`flam3`-but-Metal-doesn't ⇒ GPU bug; CPU-fails-`flam3` ⇒ algorithm bug).

### FlameRenderer (Metal Compute Pipeline)

**Purpose:** GPU-accelerated fractal flame rendering

FlameRenderer implements the three-stage Metal compute pipeline (as built in M2):

1. **Chaos Game / Histogram Accumulation** — a per-thread faithful ISAAC iterates the IFS, accumulating into a `uint32` fixed-point atomic histogram (count + RGB + alpha per bin)
2. **Density Estimation Filter** — adaptive kernel, a twin of the CPU approximation (a passthrough when `estimator_radius == 0`)
3. **Display Pipeline** — log-density, Gaussian spatial filter, palette, gamma, vibrancy → 8-bit RGBA

Key implementation details:
- One MSL kernel per stage; a faithful ISAAC port (byte-equal to the Swift ISAAC) drives the chaos game
- Per-thread ISAAC seeded via flam3's parent→child mechanism; thread geometry pinned from params → deterministic
- `uint32` fixed-point accumulation is associative, so the histogram sum is independent of thread scheduling
- Production `FlameRenderer` depends on `FlameKit` only; MSL source is bundled as a SwiftPM resource and compiled at runtime via `makeLibrary(source:)`
- Statistical twin of `FlameReference` (PSNR ≥ 38 dB), not byte-identical — see [metal-pipeline.md](../rendering/metal-pipeline.md)

### FlamePlayer (Playback Engine)

**Purpose:** Realtime adaptive generation with pre-rendered caching

FlamePlayer manages the infinite playback loop. The M3 realtime path is built on
three components (see [playback-modes.md](../playback/playback-modes.md)):

- **`PlaybackDispatcher`** (S7, Task 20) — an actor-isolated driver that advances
  a `Schedule` one global frame at a time, hands the interpolated `Flame` to an
  injected `Renderer`, paces to a target fps via an injected `PlaybackClock`, and
  **prefetches the next sheep mid-loop** so the transition's first frame is ready.
  Triple-buffered `MTLTexture` rotation lives behind the production `Renderer`
  conformer (on the `@MainActor`); the dispatcher itself is Metal-free and fully
  testable with fakes. Swift 6 isolation throughout — no `nonisolated(unsafe)`.
- **`AdaptiveQualityController`** (S7, Task 21) — a **pure** value type mapping
  `(measuredFps, thermalState, currentBudget)` to a new `samplesPerPixel` via
  hysteretic feedback (±3 fps deadband; halve on underperformance, double on
  headroom; `.critical` thermal forces a floor). No hidden state — identical
  inputs always yield identical output, so it is verified deterministically
  against simulated fps/thermal signals.
- **`FlameUI`** (S7, Task 22) — a `@MainActor` `NSView` backed by `CAMetalLayer`
  that conforms to the dispatcher's `FrameSink` protocol and drives vsync-paced
  presentation.

Legacy responsibilities (pre-rendered cache, library management) remain as
described below; the adaptive generation + transition sequencing path is the
`PlaybackDispatcher` + `Schedule` + `AdaptiveQualityController` triad above.

- **Pre-rendered Cache** — Background thread renders upcoming sheep at high quality
- **Deterministic Seeds** — Fixed RNG seeds ensure offline renders match realtime playback

### FlameUI (Metal-Layer Presentation)

**Purpose:** `@MainActor` `NSView` presenting the dispatcher's frames

`FlameUI` is the production `FrameSink`: the `PlaybackDispatcher` hands it one
`RGBA8Image` per global frame and `FlameUI.display` crosses the MainActor
explicitly (the conformance is `@MainActor`-isolated, satisfying
`FrameSink: Sendable`). It builds a `CGImage` from the renderer's RGBA8 pixels
and hands it to the `CAMetalLayer.contents`. Teardown of any owned dispatcher is
an explicit `async stop()` the owner calls (Swift 6 forbids async work in
`deinit`). Availability mirrors `MetalRenderer.isAvailable`.

### EmberweftUI (GUI Support Library — M4)

**Purpose:** SwiftUI/AppKit hosting + the app's non-engine logic, shared by the GUI
app (M4) and the screensaver (M5)

`EmberweftUI` is a SwiftPM **library** (so M5 can reuse it), not the executable.
It depends on `FlameKit`, `FlameReference`, `FlameRenderer`, `FlamePlayer` and adds:

- **`FlameUIView`** — an `NSViewRepresentable` bridge over the `@MainActor`
  `FlameUI` sink; `updateNSView` is a no-op so the SwiftUI body stays inert during
  playback (the thin realtime gate).
- **Production conformers** — `MetalFrameRenderer` / `CPUFrameRenderer`
  (`Renderer`), `WallClock` (`PlaybackClock`), `SingleFlameProvider`
  (`SheepProvider`). The FlamePlayer protocols ship without production conformers;
  the app provides them.
- **`ThumbnailService`** — renders small posters off-main (see below), downscales,
  caches (bounded `NSCache` + disk). Excludes degenerate genomes.
- **Library + metadata model:** `LibraryIndex` / `LibraryEntry` / `LibrarySource`
  / `LibraryFilter` / `CuratorRank` / `AppPreferences` (multi-folder sources, the
  filter, the ranking sidecar schema, JSON-persisted settings + density).
- **`MetadataStore` / `GenomeMetadata`:** the tri-state sentiment store
  (`-1`/`0`/`+1`), `metadata.json` schema v2, and the v1 `favorite → +1` migration.
- **`CollectionsStore` / `GenomeCollection` / `CollectionEntry`:** create / rename
  / delete / add / remove / reorder, persisted to `collections.json`; entries carry
  source + id so a removed folder is skipped, not crashed.
- **`ImportKit`:** pure, testable import planning: path-traversal-safe filename
  sanitize, dedup, batch plan (parse-before-copy lives in `AppModel`).
- **`FacetCache`:** per-genome heuristic category + palette-hue facet (derived
  from the rendered thumbnail's dominant pixels), so every genome is categorizeable
  and palette-filterable even without a curated rank.
- **`SequencePlaybackViewModel`:** drives the validated `PlaybackDispatcher` over
  a collection's genomes (`Schedule(librarySize:, selector: Sequential)`, loop +
  transition segments) for the Play-as-Sequence window.
- **`RGBAImage+CGImage`** — the upright CGImage/NSImage bridging (distinct from
  `FlameUI.makeCGImage`'s layer-oriented flip, see CLAUDE.md gotcha).

**Off-main Metal (no UI freeze):** thumbnails use `MetalRenderer.renderOffMain`,
which runs the fused pipeline on a dedicated background `DispatchQueue` with its
own device/library/queue/PSO cache (`MetalOffMainCache`). It never touches the
MainActor, so thumbnail rendering cannot hitch the UI. The realtime `@MainActor`
path is unchanged; both call the shared actor-agnostic `renderFusedCore` and
produce byte-identical output.

### FlameExport (Export Module)

**Purpose:** AVFoundation-based offline rendering and export

FlameExport handles long-form output:

- **AVAssetWriter Integration** — ProRes/HEVC encoding at target resolution
- **High-Quality Mode** — Increased iterations, supersampled histogram, larger filter kernel
- **Audio Support** — Optional soundtrack with flame parameter reactive to audio (future)
- **Batch Export** — Render multiple sheep or transition sequences to disk
- **Progress Reporting** — Cancellable jobs with frame-count progress

Export runs offscreen compute (no `MTKView`), fully CPU-detached from rendering.

### FlameFlock (Flock Archive — M6.5/M6.6)

**Purpose:** A local archive of pre-rendered loop/edge videos that makes long
compositions cheap: **Generate** pre-bakes material into the archive,
**Stitch** composes long videos from it (per-segment HIT reuses the cached
file; MISS renders into the archive first) with a no-reencode
`AVMutableComposition` passthrough concat. The `flock.sqlite` catalog
(`FlockCatalog`, a serialized-writer actor, rebuildable from file names +
embedded `mdta` tags) is the source of truth; shards partition the archive by
resolution / frame rate / pace; ES-sourced sheep keep their real `(gen, id)`
while user genomes get minted ids in reserved flock `900000`. `FlameFlock`
links the system `sqlite3` directly (Apple SDKs only — no SwiftPM
dependency). Archive renders go through `FlameExport.renderSegmentRange`
(single-sourced with the one-shot export path) and always render with
normalized framing (M6.6).

#### Artifact geometry: core + wrap / ext (seam-aware, geometry v2)

Temporal smoothing averages each frame's histogram over an 11-frame centered
window (h = 5). Standalone video files would clip that window at their first
and last frames — and because the display pipeline tracks the *brightest*
window member (gamma compression), the boundary frames on the two sides of a
stitch seam differed wildly (measured up to 35× the normal frame-to-frame
change). The fix re-slices the timeline so **every encoded frame's window
lies strictly inside its own unit's render plan**, and every seam is *owned*
by a file whose plan contains both sides:

- **A loop is TWO files.** The **core** encodes phases `[h, L−h)` of a
  1-cycle plan (all windows interior — this is why the core plays h frames
  short at each end, imperceptible on ambient content). The **wrap** (the
  short `…=wrap.mov`, `2h ≈ 10` frames) encodes `[2L−h, 2L+h)` of a
  **3-cycle** plan — the last h frames of a cycle plus the first h of the
  next, rendered as one contiguous range whose windows straddle the cycle
  wrap internally. A stitch playing a loop N times concatenates
  `[core, (wrap, core) × (N−1)]`: the wrap is the glue at every
  loop-to-itself boundary.
- **An edge is ONE file (ext).** It is rendered from a 3-segment plan
  `loop(A) + transition + loop(B)` and encodes `[L−h, L+T+h)` — the
  transition plus h boundary frames of EACH neighboring loop, so its windows
  straddle both boundaries already. **Edges need no wrap**: the loop-core ↔
  edge seams are owned by the edge's built-in margins.

The rule: every seam between files must be owned by a file whose plan
contains both sides. Loop-repeat seams get a dedicated owner (the wrap);
loop↔edge seams are owned by the edge. The `geom` catalog column (v2) is an
exact hit-gate so geometry-v1 artifacts are never mixed into v2 stitches.

### App (SwiftUI User Interface, M4)

**Purpose:** Interactive genome-library studio and player

The `EmberweftGUI` executable target (`emberweft-gui`) is a thin SwiftUI shell over
`EmberweftUI` + `AppModel` (the `@MainActor @Observable` app-wide state: preferences,
the library index, thumbnail service, metadata store, collections store, palette
facets, multi-selection, and per-section load + rendered-id state). It provides:

- **`NavigationSplitView` studio:** a sidebar of destinations (All / Library /
  Liked / Imported, plus one row per opened folder and one per collection) drives a
  single detail grid (one section at a time). `⌘1–4` jump; density S/M/L persists.
- **Grid browser:** a `LazyVGrid` of `ThumbnailCell` (off-main Metal thumbnails,
  category pill, hover selection tick, hover-revealed tri-state sentiment bar plus
  an always-on badge), skeleton loading, and destination-aware
  `ContentUnavailableView` empty/error states.
- **Multi-select + collections:** click / `⌘` / shift / `⌘A` selection with a
  bottom-floating selection bar (bulk Like/Dislike, Save as Collection, Add to);
  collections with rename / delete / add / remove and a custom in-app drag reorder.
- **Non-modal playback windows:** a value-driven `WindowGroup(for: PlaybackRoute.self)`
  (one window per genome; browse and rate while it plays) and a second
  `WindowGroup(for: CollectionPlaybackRoute.self)` that plays a collection as a
  loop+transition sequence via the M3 `PlaybackDispatcher`. Transport: play/pause,
  scrub, `←`/`→` frame-step, frame/time readouts, sentiment bar.
- **Search & filter:** `.searchable` plus a filter popover (sentiment / category /
  palette) with an active-count badge and removable active-filter chips.

SwiftUI views are backed by `AppModel` and the `EmberweftUI` models, crossing into
`FlamePlayer` and `FlameRenderer` via Swift 6 actor boundaries. A bundled-executable
`AppDelegate` sets the activation policy so the app becomes the key app on launch
(see the CLAUDE.md gotcha).

### ScreenSaver (macOS Bundle)

**Purpose:** Native .saver bundle for system screen saver activation

The ScreenSaver target packages the rendering engine as a macOS screen saver:

- Uses `ScreenSaverView` with Metal layer
- Loads genomes from bundled library or user directory
- Respects energy saver and wake events
- Optional password-delay compatibility

## Data Flow

```
.flam3 XML → FlameKit Parser → Flame Genome Model
                                    │
                                    ▼
                    FlameRenderer ←───┴─── FlamePlayer (scheduling)
                        │                      │
                        ▼                      ▼
                    Metal Compute        Pre-rendered Cache
                    (3-stage pipeline)    (background thread)
                        │                      │
                        ▼                      ▼
                    MTLTexture (frame)  →  AVAssetWriter (export)
                        │
                        ▼
                    CAMetalLayer / MTKView
                        │
                        ▼
                    Screen Display
```

## Concurrency and Threading

### Swift 6 Strict Concurrency

The codebase adopts Swift 6 strict concurrency with actor-isolated state:

- **FlameRenderer** — `@MainActor` for Metal commands (MTLCommandQueue must be created on main thread)
- **FlamePlayer** — Actor-isolated state machine; async methods for frame requests
- **FlameExport** — Detached actor for long-running jobs; progress via Combine publisher
- **FlameKit** — Non-isolated value types (structs) — freely copyable across actors

### Metal Scheduling

- **Display Path** — `MTKView` delegate calls `draw(in:)` per frame; command buffer commits present
- **Export Path** — Offscreen `MTLTexture` from `MTLDevice.makeTexture`; async I/O to disk
- **Cache Generation** — Background compute with separate `MTLCommandBuffer`; completion signals semaphore

### I/O Concurrency

- Genome library loading uses `URLSession`/`FileManager` with async/await
- Thumbnails generated lazily via task queue; cached to disk
- AVAssetWriter runs on dedicated dispatch queue to avoid blocking render thread

## Swift Package Layout

Emberweft uses Swift Package Manager with multiple products (see [project layout](engineering/project-layout.md)):

```
Package.swift
├── FlameKit (library product)
│   ├── Sources/FlameKit/ — genome model, parser, interpolation
│   └── Tests/FlameKitTests/ — unit tests
├── FlameReference (library product)
├── FlameRenderer (library product)
│   ├── Sources/FlameRenderer/ — Metal kernels, pipeline (+ off-main cache)
│   └── Tests/FlameRendererTests/ — reference renders
├── FlamePlayer (library product)
├── FlameExport (library product)
├── FlameFlock (library product — M6.5; links system sqlite3)
├── EmberweftUI (library product — M4)
│   ├── Sources/EmberweftUI/ — SwiftUI bridge, playback conformers, thumbnails, models
│   └── Tests/EmberweftUITests/ — unit + Metal smoke + parity tests
├── emberweft (executable product) — CLI
│   └── Sources/EmberweftApp/ + Sources/EmberweftCLI/
└── emberweft-gui (executable product — M4)
    └── Sources/EmberweftGUI/ — SwiftUI app shell (+ CuratedLibrary resource)
```

## Dependencies

- **Metal 4** — GPU compute; minimum macOS 26 (Metal 4 features)
- **AVFoundation** — Video encoding (FlameExport)
- **SwiftUI** — UI framework
- **ScreenSaver** — macOS screen saver framework
- **No external dependencies** — Pure Metal/Swift implementation

## Performance Targets

See [performance.md](engineering/performance.md) for detailed benchmarks:

- **Realtime** — 30-60 FPS at 1080p, adaptive quality
- **Export Quality** — 4K at 24 FPS, high-iteration preset
- **Memory** — < 500 MB working set for typical session
- **Power** — Efficient for sustained laptop use; thermal-aware quality scaling

## Future Extensions

Potential additions within the architecture:

- **Audio Reactivity** — Microphone input drives variation parameters
- **Flock Import** — Optional compatibility with Electric Sheep server genomes
- **Cloud Render** — Distributed rendering farm (original ES model)
- **VR/AR** — 360-degree equirectangular output for head-mounted displays
