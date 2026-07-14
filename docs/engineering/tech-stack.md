# Technology Stack

*Core technologies, frameworks, and tooling for the native macOS renderer and platform.*

> **Status:** preliminary — for review · Emberweft

## Language and Runtime

### Swift 6 (Strict Concurrency)

Emberweft is implemented in **Swift 6** with strict concurrency enabled. This choice provides:

**Language advantages:**
- **Type-safe concurrency**: Actor-based isolation eliminates data races at compile time
- **Modern memory management**: ARC with move semantics eliminates manual memory management
- **Interop**: Seamless bridging to Objective-C frameworks (Metal, AVFoundation)
- **Performance**: Near-C performance with compiler optimizations
- **Energy efficiency**: Language-level support for energy-aware patterns

**Strict concurrency mode:**
- All mutable state is actor-isolated or `Sendable`
- Main-thread-only types (UI, Metal command buffer) are explicitly marked
- Data races are caught at compile time rather than runtime
- Region-based isolation for fine-grained concurrent access

Swift 6 is the right choice for a GPU-accelerated renderer because it combines low-level system access with high-level safety — critical for a long-running screensaver process.

## Graphics and Rendering

### Metal 4 / Metal Shading Language (MSL)

All rendering uses **Metal 4**, Apple's low-level graphics and compute API:

**Metal advantages:**
- **Unified compute + rendering**: Chaos-game iteration in compute kernels, tone-mapping in render pipeline
- **Apple Silicon optimization**: Direct access to GPU performance counters and power management
- **Explicit control**: Fine-grained resource management for predictable performance
- **MetalKit**: MTKView integration for easy presentation
- **Debug tooling**: GPU capture, Frame Debugger, shader validation

> **Metal is compute-first here.** The chaos game + histogram + density-estimation filter are data-parallel and divergent, so Emberweft uses `MTLComputeCommandEncoder` (not rasterization) for the core pipeline. The CPU reference renderer (`FlameReference`) is the parity oracle the Metal path is validated against — see [development-approach.md](development-approach.md) and [rendering/metal-pipeline.md](../rendering/metal-pipeline.md).

**Shading language:**
- **Metal Shading Language (MSL)**: C++14-based shader language
- **Compute kernels**: Chaos-game iteration, histogram accumulation
- **Fragment shaders**: Tone-mapping, filtering, presentation
- **Headers**: Shared between `.metal` files and Swift via bridging

**Why not metal-cpp?**
The Swift API is native and more ergonomic than metal-cpp (C++ bindings). Swift's closure syntax and value semantics integrate cleanly with Metal's Objective-C heritage.

**Metal-specific features used:**
- **Compute pipelines**: Parallel chaos-game iteration
- **Argument buffers**: Organize kernel parameters efficiently
- **Heaps**: Memory pooling for histogram and accumulation buffers
- **Indirect command buffers**: (Future) Multi-pass rendering with minimal CPU involvement

### MTKView vs CAMetalLayer

For the screensaver and app preview, Emberweft uses **CAMetalLayer** directly rather than MTKView:

**CAMetalLayer advantages:**
- **Lower overhead**: No view wrapper overhead
- **Better control**: Explicit control over drawable presentation and timing
- **Screensaver compatibility**: ScreenSaver.framework expects NSView, not MTKView

The app preview uses an `NSViewRepresentable` wrapper around a CAMetalLayer-hosting NSView for SwiftUI integration.

## User Interface

### SwiftUI (Primary)

The main app UI uses **SwiftUI** for:

**SwiftUI scope:**
- **Library browser**: Grid/list of genomes with filters and search
- **Settings panels**: Preferences, quality controls, feature toggles
- **Transport controls**: Playback controls, timeline scrubbing
- **Metadata editors**: Genome editing, tagging, rating

**SwiftUI advantages:**
- **Declarative UI**: Clean separation of state and presentation
- **State management**: `@State`, `@Observable`, `@Environment` for reactive updates
- **Previews**: Live previews of UI components during development
- **Accessibility**: Built-in support for VoiceOver and dynamic type

### AppKit Integration (Where Needed)

Some UI components require AppKit interop:

**NSViewRepresentable uses:**
- **Metal presentation layer**: Hosts CAMetalLayer in SwiftUI hierarchy
- **Advanced panels**: Complex views that are easier in AppKit (e.g., timeline editor)

**Screensaver.framework:**
- **ScreenSaverView**: Base class for .saver bundle
- **Preferences sheet**: For screensaver-specific settings

The screensaver uses pure AppKit (no SwiftUI) to minimize runtime overhead and ensure stability in the screensaver context.

## Media and Audio

### AVFoundation

Export and audio processing use **AVFoundation**:

**Video export:**
- **AVAssetWriter**: Encode rendered frames to H.264/HEVC
- **AVAssetWriterInput**: Frame-by-frame writing from Metal textures
- **CMTime**: Frame timing for accurate duration

**Audio analysis:**
- **AVAudioEngine**: Real-time audio playback and analysis
- **AVAssetReader**: Decode audio tracks for beat detection
- **AVAudioPCMBuffer**: Access raw audio samples for processing

### Accelerate and AudioToolbox

Audio analysis uses **Accelerate** and **AudioToolbox**:

**vDSP (Digital Signal Processing):**
- **FFT**: Frequency-domain analysis for beat detection
- **Windowing**: Hanning/Hamming windows for spectral analysis
- **Filtering**: Noise reduction and signal conditioning

**AudioToolbox:**
- **AudioConverter**: Format conversion (AAC → PCM for analysis)
- **AudioFile**: Reading audio file metadata

## Packaging and Module Structure

### Swift Package (Package.swift)

The renderer is packaged as a **Swift Package** with multiple library products:

**Package structure:**
```swift
// Package.swift (simplified)
let package = Package(
    name: "emberweft",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "FlameKit", targets: ["FlameKit"]),
        .library(name: "FlameReference", targets: ["FlameReference"]),
        .library(name: "FlameRenderer", targets: ["FlameRenderer"]),
        .library(name: "FlamePlayer", targets: ["FlamePlayer"]),
        .library(name: "FlameExport", targets: ["FlameExport"]),
        .executable(name: "emberweft", targets: ["EmberweftCLI"]),
    ],
    targets: [
        .target(name: "FlameKit"),
        .target(name: "FlameReference", dependencies: ["FlameKit"]),     // CPU renderer = oracle + fallback
        .target(name: "FlameRenderer", dependencies: ["FlameKit"]),       // Metal compute renderer
        .target(name: "FlamePlayer", dependencies: ["FlameRenderer", "FlameKit"]),
        .target(name: "FlameExport", dependencies: ["FlameRenderer", "FlameKit"]),
        .executableTarget(name: "EmberweftCLI", dependencies: ["FlameRenderer", "FlameReference", "FlameKit"]),
    ]
)
```

**Module responsibilities:**
- **FlameKit**: Genome model, .flam3 parsing/serialization, interpolation
- **FlameReference**: CPU reference renderer — the parity oracle, deterministic offline renderer, and GPU-less fallback (see [development-approach.md](development-approach.md))
- **FlameRenderer**: Metal device, compute pipelines, .metal kernels
- **FlamePlayer**: Playback engine, adaptive controller, sequencing
- **FlameExport**: AVFoundation export, audio analysis
- **EmberweftCLI**: The `emberweft` command-line tool (`render`, `animate`, `validate`, `info`) — ships before any UI; the CI test driver

### Multi-Target Sharing

The Swift Package is consumed by two Xcode targets:

**Targets:**
1. **EmberweftApp**: Main application (SwiftUI + Metal preview)
2. **EmberweftScreenSaver**: Screensaver bundle (AppKit + Metal)

**Code sharing:**
- Both targets link the same Swift Package products
- UI code is duplicated (SwiftUI for app, AppKit for screensaver) but renderer is shared
- Resources (palettes, shaders) are bundled once and referenced from both targets

This approach ensures rendering parity between app and screensaver while allowing UI specialization.

## Deployment Target

### macOS 26 (Tahoe)

**Minimum OS: macOS 26** — this is the floor that ships **Metal 4**, which Emberweft's compute pipeline requires. (It is deliberately *not* pinned to a point release like 26.5; the deployment target is the lowest OS that supports the APIs we use.)

**Justification:**
- **Metal 4** — the compute features (atomics on histogram buffers, Metal 4 improvements) require macOS 26
- **Swift 6 runtime** — full strict-concurrency support on the 26 toolchain
- **Apple Silicon focus** — Intel Macs are unsupported; macOS 26 is Apple-Silicon-native

**Hardware support:**
- **Required**: Apple Silicon (M1 or later)
- **Recommended**: M2 Pro or later for realtime 4K
- **Unsupported**: Intel-based Macs (may work in software rendering mode, but not supported)

### Xcode 26.6

**Development tooling:**
- **Xcode 26.6**: Latest stable Xcode with Swift 6 support
- **Metal Shader Debugger**: For shader optimization
- **Instruments**: Performance profiling and energy analysis

## Testing and Quality Assurance

Emberweft is **oracle-validated and test-driven**. Full methodology in [testing.md](testing.md); methodology and build order in [development-approach.md](development-approach.md).

### XCTest

Unit, property, and integration tests use **XCTest**:

**Test coverage:**
- **Genome parsing**: .flam3 round-trips; malformed input rejected
- **Interpolation**: transition smoothness and determinism
- **Variation functions**: known-input → expected-output per variation
- **Golden-image**: `FlameReference` vs dev-only `flam3` goldens (PSNR/SSIM)
- **Parity**: Metal output vs CPU reference (statistical + PSNR)
- **Determinism**: same seed → identical frame, offline and realtime

**Test types:**
- **Unit (pure)**: parameter and math correctness
- **Golden-image**: rendered frames vs reference oracles
- **Parity**: Metal ↔ CPU on identical inputs
- **Property/invariant**: bounded output, no NaN/Inf
- **Performance**: kernel/render-time regression guards
- **CLI snapshots**: byte-stable `emberweft render` output

### GPU Capture and Validation

**Metal validation workflow:**
1. **Xcode GPU Capture**: Capture frame for debugging
2. **Shader validation**: Verify MSL compilation and execution
3. **Frame Debugger**: Step through draw/dispatch calls
4. **Metal Performance HUD**: Real-time performance metrics

### Instruments

Performance profiling uses **Instruments**:

**Instruments tools:**
- **Time Profiler**: Identify CPU bottlenecks
- **Metal System Trace**: GPU utilization and memory bandwidth
- **Energy Log**: Power consumption and thermal state
- **Allocations**: Memory allocation patterns and leaks

## Dependencies Policy

### Zero-Dependency Preference

Emberweft prefers **zero external dependencies** beyond the Apple SDK:

**Rationale:**
- **Stability**: No third-party breakage or security issues
- **License clarity**: No ambiguous licensing for redistribution
- **Build simplicity**: No dependency management or version conflicts
- **Binary size**: Smaller app bundle and faster startup

**Stdlib reliance:**
- Swift standard library (Foundation, SwiftUI, Metal, AVFoundation)
- Apple frameworks (Accelerate, AudioToolbox, ScreenSaver)
- No Swift Package Manager dependencies

### Potential Future Dependencies

If external dependencies are needed, they will be:

**Candidate dependencies:**
- **Compression**: zlib (for .flam3 gzip support if not in stdlib)
- **Math**: Accelerate (already in stdlib)
- **Testing**: Quick/Nimble for nicer test syntax (optional)

**Dependency criteria:**
- Must be permissively licensed (MIT, Apache, BSD)
- Must be actively maintained
- Must have Apple Silicon support
- Must be audited for security

As of M0 (Docs + repo scaffold), **no external dependencies are planned**.

## Technology Alternatives Considered

### Why Not Other Languages/Frameworks?

**Why not C++?**
- Swift 6 provides memory safety without garbage collection
- Better SwiftUI/AppKit integration than Objective-C++
- Fewer buffer overflows and memory safety bugs

**Why not Rust?**
- Less native Apple platform integration than Swift
- More complex interop with Objective-C frameworks
- Smaller ecosystem for macOS-specific APIs

**Why not Unity/Unreal?**
- Overkill for a single-purpose renderer
- License and royalty complications
- Larger runtime and slower startup

**Why not Vulkan/OpenGL?**
- Deprecated on macOS (OpenGL)
- Worse Apple Silicon performance than Metal
- Missing platform-specific features

## Related Documentation

- [`development-approach.md`](development-approach.md) — Methodology, build order, GPU strategy
- [`testing.md`](testing.md) — Test methodology, oracles, CI gates
- [`../architecture.md`](../architecture.md) — System architecture and module interaction
- [`project-layout.md`](project-layout.md) — Repository and module layout
- [`performance.md`](performance.md) — Performance targets and profiling

---

**Credit**: fractal flame algorithm © Scott Draves (1992). Electric Sheep™ and Infinidream™ are trademarks of Scott Draves / e-dream, inc.
