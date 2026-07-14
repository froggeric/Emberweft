# Project Layout

*Repository structure and module organization for the multi-target renderer and platform.*

> **Status:** preliminary — for review · Emberweft

## Directory Structure

The repository is organized around the Swift Package module structure, with separate targets for the app and screensaver:

```
Emberweft/
  Package.swift                          # Swift Package manifest
  Sources/
    FlameKit/                           # Genome model and I/O
      FlameGenome.swift                # Core genome data structures
      GenomeParser.swift                # .flam3 XML parsing
      GenomeSerializer.swift            # .flam3 XML serialization
      GenomeInterpolator.swift          # Transition blending logic
      ColorPalette.swift                # Palette model and built-in palettes
      Transform.swift                   # Affine and variation transforms
    FlameReference/                     # CPU reference renderer (oracle + fallback)
      ReferenceRenderer.swift           # Full pipeline in pure Swift + Accelerate
      Variations.swift                  # Shared variation math (also used by Metal kernel)
      DensityFilter.swift               # CPU density-estimation filter
    FlameRenderer/                      # Metal rendering pipeline
      MetalDevice.swift                 # MTLDevice wrapper and setup
      ComputePipeline.swift             # Chaos-game compute kernels
      RenderPipeline.swift              # Tone-mapping and presentation
      HistogramBuffer.swift             # Log-density estimation buffer
      AccumulationBuffer.swift           # Frame accumulation for smooth playback
      Kernels/
        ChaosGame.metal                 # Main chaos-game iteration kernel
        Histogram.metal                 # Histogram accumulation kernel
        Tonemap.metal                   # Gamma correction and tone-mapping
        Filter.metal                    # Supersampling filter kernel
    FlamePlayer/                        # Playback engine and sequencing
      PlaybackEngine.swift              # Main playback controller
      AdaptiveController.swift          # Quality adaptation based on performance
      Sequencer.swift                   # Genome sequencing and transitions
      Timeline.swift                    # Timeline and transport controls
    FlameExport/                        # Export and audio processing
      ExportPipeline.swift              # AVFoundation export coordinator
      VideoWriter.swift                 # AVAssetWriter wrapper
      AudioAnalyzer.swift               # Beat detection and BPM analysis
      AudioReactiveRenderer.swift       # Audio-reactive parameter modulation
    FlameUI/                            # Shared UI components
      MetalView.swift                   # CAMetalLayer host for SwiftUI
      TransportView.swift               # Playback controls (play/pause/scrub)
      TimelineView.swift                # Timeline and scrubber UI
      QualityIndicator.swift            # Real-time performance HUD
    EmberweftCLI/                       # `emberweft` command-line tool (ships before UI)
      Commands/
        RenderCommand.swift             # `emberweft render` (still image)
        AnimateCommand.swift            # `emberweft animate` (transitions)
        ValidateCommand.swift           # `emberweft validate` (lint a genome)
        InfoCommand.swift               # `emberweft info`
      main.swift                        # Argument parsing + dispatch
  Apps/
    EmberweftApp/                       # Main application target
      App.swift                         # SwiftUI app entry point
      LibraryView.swift                 # Seed library browser
      PlaybackView.swift                 # Main playback interface
      SettingsView.swift                # App settings and preferences
      ExportView.swift                  # Export configuration and progress
      AppDelegate.swift                 # App lifecycle and app-group setup
      Info.plist                        # App metadata and entitlements
    EmberweftScreenSaver/               # Screensaver bundle target
      ScreenSaverView.swift             # Main screensaver view (AppKit)
      ScreenSaverPreferences.swift      # Settings panel
      ScreenSaverController.swift       # Playback coordination
      Info.plist                        # Screensaver metadata
      EmberweftScreenSaver.defs         # Screensaver configuration
  Resources/
    Library/                            # Seed library and manifest
      manifest.json                     # Genome metadata index
      thumbnails/                       # Pre-rendered thumbnails
      genomes/                          # .flam3 genome files
    Palettes/                           # Built-in color palettes
      default-palette.json
      cosmic-gradient.json
      warm-fire.json
      cool-ocean.json
    Shaders/                            # Additional .metal files (if any)
  Tests/
    FlameKitTests/
      GenomeParserTests.swift
      InterpolationTests.swift
      RoundtripTests.swift
    FlameReferenceTests/
      VariationTests.swift              # Per-variation known-input/output
      ReferencePipelineTests.swift      # CPU renderer invariants (bounded, no-NaN)
    Goldens/                            # Golden-image oracle harness
      genomes/                          # Frozen ~12 .flam3 reference genomes
      reference/                        # flam3-rendered goldens (dev-only generated)
      compare/                          # PSNR/SSIM comparison helpers
    FlameRendererTests/
      MetalValidationTests.swift
      SnapshotTests.swift
      DeterminismTests.swift
    FlamePlayerTests/
      SequencingTests.swift
      AdaptiveQualityTests.swift
    FlameExportTests/
      AudioAnalysisTests.swift
      ExportValidationTests.swift
  docs/
    overview.md                         # Project overview and goals
    architecture.md                     # System architecture and module diagram
    rendering/
      flame-algorithm.md               # Core fractal flame algorithm
      metal-pipeline.md                # Metal implementation details
      genome-format.md                 # .flam3 file format specification
      transitions.md                   # Genome interpolation and morphing
    playback/
      playback-modes.md                # Realtime and cached playback
      formats.md                       # Output formats and codecs
    export/
      export-pipeline.md               # Export pipeline architecture
      music-video.md                   # Audio-reactive rendering
    platform/
      screensaver.md                   # ScreenSaver.framework integration
      app-ui.md                        # Main app UI architecture
    library/
      seed-library.md                  # Seed library and metadata
      genetics.md                      # Genetic algorithm features
    engineering/
      tech-stack.md                   # Technology choices
      project-layout.md                # This file
      performance.md                   # Performance targets
      roadmap.md                       # Development milestones
      glossary.md                      # Canonical terminology
```

## Module Dependencies

The modules form a dependency hierarchy from low-level to high-level:

```
FlameKit (genome model, parsing, interpolation)
    ↓
FlameReference (CPU renderer)   ←── also depends on FlameKit (sibling of FlameRenderer)
FlameRenderer (Metal device, kernels, rendering)
    ↓
FlamePlayer (playback engine, sequencing) + FlameExport (export, audio)
    ↓
FlameUI (shared UI components)
    ↓
Apps (App and ScreenSaver targets)   EmberweftCLI (emberweft executable)
```

**Dependency arrows:**
- **FlameReference** depends on **FlameKit**; implements the same pipeline as FlameRenderer in pure Swift (oracle + fallback)
- **FlameRenderer** depends on **FlameKit** for genome data structures; validated against **FlameReference** via parity tests
- **FlamePlayer** depends on **FlameRenderer** for rendering and **FlameKit** for interpolation
- **FlameExport** depends on **FlameRenderer** for rendering and **FlameKit** for genome handling
- **FlameUI** depends on **FlamePlayer** and **FlameRenderer** for presentation
- **App and ScreenSaver** depend on **FlameUI**, **FlamePlayer**, **FlameExport**, and **FlameRenderer**
- **EmberweftCLI** depends on **FlameKit**, **FlameReference**, and **FlameRenderer** (the `--backend cpu|metal` switch)

**No circular dependencies:** The hierarchy is strictly layered, enabling clean separation and testing.

## Module Responsibilities

### FlameKit

**Purpose:** Core data model and I/O for flame genomes.

**Responsibilities:**
- Parse `.flam3` XML files into `FlameGenome` structs
- Serialize `FlameGenome` structs to `.flam3` XML
- Provide interpolation between two genomes (for transitions and breeding)
- Manage color palettes (built-in and custom)
- Validate genome parameters

**Key types:**
- `FlameGenome`: Top-level genome structure with transforms, palette, quality settings
- `Transform`: Affine coefficients and variation weights
- `Variation`: Enum of variation functions (linear, spherical, sinusoidal, etc.)
- `ColorPalette`: Array of RGB colors with interpolation methods

**Dependencies:** None (stdlib only)

### FlameRenderer

**Purpose:** Metal-based rendering pipeline for chaos-game iteration and tone-mapping.

**Responsibilities:**
- Initialize and configure Metal device
- Compile and manage compute and render pipelines
- Allocate and manage GPU buffers (histogram, accumulation)
- Execute chaos-game iteration kernels
- Apply tone-mapping and gamma correction
- Present rendered frames to CAMetalLayer

**Key types:**
- `MetalDevice`: Wrapper around MTLDevice with resource pools
- `ComputePipeline`: Manages chaos-game and histogram kernels
- `RenderPipeline`: Manages tone-mapping and presentation shaders
- `HistogramBuffer`: Log-density estimation buffer management
- `AccumulationBuffer`: Frame accumulation for smooth transitions

**Dependencies:** FlameKit

**.metal files:** All Metal Shading Language code lives in `Sources/FlameRenderer/Kernels/`

### FlamePlayer

**Purpose:** Playback engine, sequencing, and adaptive quality control.

**Responsibilities:**
- Coordinate playback of genome sequences with transitions
- Manage adaptive quality based on thermal state and battery
- Execute smooth transitions between genomes
- Handle transport controls (play, pause, scrub, seek)
- Manage timeline and sequencing logic

**Key types:**
- `PlaybackEngine`: Main playback coordinator
- `AdaptiveController`: Monitors performance and adjusts quality
- `Sequencer`: Orders genomes and plans transitions
- `Timeline`: Manages playback position and transport state

**Dependencies:** FlameRenderer, FlameKit

### FlameExport

**Purpose:** Video export and audio analysis.

**Responsibilities:**
- Encode rendered frames to video files via AVFoundation
- Analyze audio for beat detection and BPM
- Modulate genome parameters based on audio (music video mode)
- Manage export progress and cancellation

**Key types:**
- `ExportPipeline`: Coordinates rendering and encoding
- `VideoWriter`: Wraps AVAssetWriter for H.264/HEVC encoding
- `AudioAnalyzer`: Performs FFT-based beat detection
- `AudioReactiveRenderer`: Modulates parameters based on audio features

**Dependencies:** FlameRenderer, FlameKit

### FlameUI

**Purpose:** Shared UI components for app and screensaver.

**Responsibilities:**
- Provide CAMetalLayer hosting view for SwiftUI
- Implement transport controls (play/pause/scrub)
- Display timeline and scrubber
- Show real-time quality/performance indicators

**Key types:**
- `MetalView`: NSViewRepresentable wrapper for CAMetalLayer
- `TransportView`: Playback control buttons and slider
- `TimelineView`: Timeline visualization and scrubber
- `QualityIndicator`: Real-time FPS and quality tier display

**Dependencies:** FlamePlayer, FlameRenderer

## Target-Specific Code

### EmberweftApp

**Purpose:** Main application for browsing, playing, and exporting genomes.

**Key files:**
- `App.swift`: SwiftUI app entry point
- `LibraryView.swift`: Seed library browser with filters
- `PlaybackView.swift`: Main playback interface
- `SettingsView.swift`: User preferences and quality controls
- `ExportView.swift`: Export configuration and progress
- `AppDelegate.swift`: App lifecycle and app-group container setup

**Dependencies:** FlameUI, FlamePlayer, FlameExport, FlameRenderer, FlameKit

### EmberweftScreenSaver

**Purpose:** Screensaver bundle for automated playback.

**Key files:**
- `ScreenSaverView.swift`: Main screensaver view (inherits ScreenSaverView)
- `ScreenSaverPreferences.swift`: Settings panel
- `ScreenSaverController.swift`: Coordinates playback and quality
- `EmberweftScreenSaver.defs`: Screensaver configuration (name, description, etc.)
- `Info.plist`: Bundle metadata and ScreenSaver framework linkage

**Dependencies:** FlameRenderer, FlameKit (no FlameUI — uses AppKit directly)

**Difference from app:**
- Uses ScreenSaver.framework instead of SwiftUI for main view
- Simpler UI (settings panel only, no full library browser)
- Stricter performance budgets (lower default quality)

## Resource Organization

### Seed Library

**Location:** `Resources/Library/`

**Contents:**
- `manifest.json`: Genome metadata index
- `thumbnails/`: Pre-rendered thumbnail PNGs
- `genomes/`: .flam3 genome files

**Access:** Both app and screensaver read from the app-group container copy; this is the bundled default library.

### Palettes

**Location:** `Resources/Palettes/`

**Contents:** JSON files defining built-in color palettes

**Format:** Array of RGB triples with metadata (name, author, source)

**Usage:** FlameKit loads these at startup for interpolation and reference.

### Shaders

**Location:** `Resources/Shaders/` (if needed)

**Contents:** Additional .metal files (currently all shaders are in FlameRenderer/Kernels/)

**Purpose:** This directory is reserved for future shader variants or user-customizable shaders.

## Build and Module System

### Package.swift

The Swift Package manifest defines:

**Products:**
- `FlameKit`: Genome model and I/O library
- `FlameRenderer`: Metal rendering library
- `FlamePlayer`: Playback engine library
- `FlameExport`: Export and audio library

**Targets:**
- Each module is a separate target with its own sources
- Dependencies between targets are explicit
- All targets share the same deployment target (macOS 26)

**Xcode integration:**
- The Xcode app and screensaver targets link the Swift Package products
- Changes to the package trigger rebuilds of dependent targets
- Package.swift is the single source of truth for module structure

### Module Boundaries

**Separation principles:**
- **FlameKit**: No GPU code, pure data model
- **FlameRenderer**: GPU code only, no UI or audio
- **FlamePlayer**: Playback logic, no rendering details
- **FlameExport**: Export and audio, separate from playback
- **FlameUI**: UI only, thin wrapper over other modules

**Testing implications:**
- Each module can be unit tested independently
- Mock objects can substitute for lower-level modules
- Integration tests verify module interaction

## Naming Conventions

**Product name:** **Emberweft** — coined from *ember* (a glowing flame) + *weft* (the woven threads of a loom), evoking woven, morphing fire. Chosen for distinctiveness/ownability (clean trademark + free `emberweft.com`), accuracy (it renders fractal *flames*), and a calm, craft-forward feel.

**Module / target prefixes:** Code identifiers still use the neutral **`Flame`** prefix (`FlameKit`, `FlameRenderer`, `FlamePlayer`, `FlameExport`, `FlameUI`) because it is technically descriptive and reads well in source. The *user-facing* product, app bundle (`EmberweftApp`), and screensaver bundle (`EmberweftScreenSaver`) carry the brand name. If you prefer the brand on the code too, swap the prefix to `Ember` (e.g., `EmberKit`, `EmberRenderer`) — a single mechanical rename.

## Related Documentation

- [`../architecture.md`](../architecture.md) — System architecture and module interaction
- [`tech-stack.md`](tech-stack.md) — Technology choices and rationale
- [`performance.md`](performance.md) — Performance targets and resource budgets

---

**Credit**: fractal flame algorithm © Scott Draves (1992). Electric Sheep™ and Infinidream™ are trademarks of Scott Draves / e-dream, inc.
