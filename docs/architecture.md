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
│                 │   (.saver target)       │   (render/animate/validate)        │
├─────────────────┴─────────────────────────┴─────────────────────────────────┤
│                              FlamePlayer                                      │
│   (Playback Engine: adaptive generation, caching, transitions)              │
├─────────────────────────────────────────────────────────────────────────────┤
│                              FlameExport                                      │
│   (AVFoundation export: codecs, long-form rendering)                       │
├─────────────────────────────────────────────────────────────────────────────┤
│                            FlameRenderer                                     │
│   (Metal Compute Pipeline: histogram → density → tone-map)                  │
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

FlameKit has no Metal dependencies and can be used in headless tools or tests.

### FlameReference (CPU Reference Renderer)

**Purpose:** Portable, deterministic CPU implementation of the full fractal-flame pipeline.

FlameReference is a **permanent, shippable module** with three roles:

1. **Parity oracle** — the source of truth that `FlameRenderer` (Metal) is validated against in CI (see [testing.md](engineering/testing.md)).
2. **Deterministic offline renderer** — verifies export reproducibility and renders in environments without a usable GPU.
3. **Algorithm laboratory** — the easiest place to unit-test variations, filters, and interpolation with per-function tests.

It implements the same pipeline as FlameRenderer (chaos game → histogram → log-density → density-estimation filter → palette/gamma) in pure Swift using Accelerate/vDSP. Maintaining two renderers is deliberate: algorithm bugs and GPU bugs localize instantly (CPU-passes-`flam3`-but-Metal-doesn't ⇒ GPU bug; CPU-fails-`flam3` ⇒ algorithm bug).

### FlameRenderer (Metal Compute Pipeline)

**Purpose:** GPU-accelerated fractal flame rendering

FlameRenderer implements the three-stage Metal compute pipeline:

1. **Chaos Game / Histogram Accumulation** — Iterates the IFS, accumulating point samples into a spatial histogram
2. **Density Estimation Filter** — Adaptive kernel that removes noise while preserving detail
3. **Palette + Tone Mapping** — Log-density alpha, palette lookup, gamma correction, HDR tone-map to output texture

Key implementation details:
- Separate compute kernels for each stage, chained via `MTLCommandBuffer`
- Histogram buffer with per-bin atomic accumulation (count, RGB sums)
- Variation functions implemented as MSL functions with function-constant specialization
- Iteration budget controls quality (default **(preliminary)**: 100-500 iterations per pixel)
- Output texture format: 16-bit half-float for HDR capability

### FlamePlayer (Playback Engine)

**Purpose:** Realtime adaptive generation with pre-rendered caching

FlamePlayer manages the infinite playback loop:

- **Adaptive Generation** — Realtime rendering when cache miss; quality scales to frame budget
- **Pre-rendered Cache** — Background thread renders upcoming sheep at high quality
- **Transition Sequencing** — Smooth morphs between genomes over **(preliminary)** 120-180 frames
- **Loop Management** — Determines next sheep, handles edge cases (xform count mismatch, palette crossfade)
- **Deterministic Seeds** — Fixed RNG seeds ensure offline renders match realtime playback

FlamePlayer uses `MTKView` with `CAMetalLayer` for display, with offscreen compute for cache generation.

### FlameExport (Export Module)

**Purpose:** AVFoundation-based offline rendering and export

FlameExport handles long-form output:

- **AVAssetWriter Integration** — ProRes/HEVC encoding at target resolution
- **High-Quality Mode** — Increased iterations, supersampled histogram, larger filter kernel
- **Audio Support** — Optional soundtrack with flame parameter reactive to audio (future)
- **Batch Export** — Render multiple sheep or transition sequences to disk
- **Progress Reporting** — Cancellable jobs with frame-count progress

Export runs offscreen compute (no `MTKView`), fully CPU-detached from rendering.

### App (SwiftUI User Interface)

**Purpose:** Interactive library browser and player controls

The App target provides the main application:

- **Library Browser** — Grid/list of genomes with thumbnail previews
- **Player View** — Fullscreen playback with transport controls
- **Settings Panel** — Quality presets, cache size, export options
- **Genome Inspector** — View/edit .flam3 XML with validation
- **Screen Saver Preferences** — Integration with macOS System Settings

SwiftUI views are backed by view models that interact with FlamePlayer and FlameRenderer via Swift 6 actor boundaries.

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
├── FlameRenderer (library product)
│   ├── Sources/FlameRenderer/ — Metal kernels, pipeline
│   └── Tests/FlameRendererTests/ — reference renders
├── App (executable product)
│   ├── Sources/App/ — SwiftUI app
│   └── Resources/ — assets, genomes, icons
└── ScreenSaver (bundle product)
    └── Sources/ScreenSaver/ — .saver bundle
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
