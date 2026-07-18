# Playback Modes

*Runtime playback architecture for the fractal flame renderer.*

> **Status:** preliminary — for review · Emberweft

## Overview

Emberweft supports three distinct playback modes, each optimized for different use cases and system constraints. The runtime dynamically selects between these modes based on performance metrics, thermal state, and user preferences.

## Playback Modes

### 1. Realtime Adaptive Generation

**REALTIME** mode renders each frame on-the-fly using the GPU chaos-game algorithm as it's displayed. This is the default mode for systems with adequate thermal headroom and GPU performance.

**Characteristics:**
- Deterministic RNG seeding ensures frame reproducibility
- Each frame is a histogram accumulated from billions of particle iterations
- Infinite variety — no pre-rendered content required
- GPU-bound workload with minimal CPU involvement

**Implementation Details:**
The render loop submits compute shaders to Metal that execute the chaos-game iteration per particle. A typical frame at 1080p with quality settings balanced for 60fps requires approximately **(preliminary)** 2-5 billion particle iterations distributed across 8-16 histogram bins per pixel.

### 2. Pre-Rendered Cache Playback

**PRE-RENDERED** mode plays back previously encoded video files of sheep. This mode provides guaranteed performance at minimal energy cost.

**Characteristics:**
- Near-zero CPU/GPU overhead (video decode only)
- Deterministic playback timing
- Limited to available cached content
- Ideal for battery operation or thermal-constrained environments

**Cache Location:**
Cached sheep are stored in the app-group container at `~/Library/Group Containers/group.«project».screensaver/Library/Cache/` with `.mov` or `.mp4` extensions.

### 3. Hybrid Mode

**HYBRID** mode dynamically switches between realtime generation and cached playback based on current system conditions.

**Decision Logic:**

```swift
// Pseudocode for mode selection
func selectPlaybackMode(
    frameTimeHistory: [TimeInterval],
    resolution: Resolution,
    qualitySetting: Quality,
    thermalState: ProcessInfo.ThermalState
) -> PlaybackMode {
    let targetFrameTime = 1.0 / targetFPS
    
    // If thermally critical, force cached
    if thermalState == .critical {
        return .preRendered
    }
    
    // If recent frame times consistently exceed budget, fall back
    let recentAverage = frameTimeHistory.suffix(30).mean()
    if recentAverage > targetFrameTime * 1.5 {
        return qualitySetting.allowCached ? .preRendered : .realtime(lowQuality)
    }
    
    // If headroom available, use realtime
    if recentAverage < targetFrameTime * 0.8 {
        return .realtime(qualitySetting)
    }
    
    // Hysteresis: maintain current mode if marginal
    return currentMode
}
```

## Adaptive Quality Control

> **Shipped (M3):** the real controller is `AdaptiveQualityController` — a **pure
> `Sendable` value type** (no hidden state) mapping `(measuredFps, thermalState,
> currentBudget)` to a new `samplesPerPixel` via hysteretic feedback (±3 fps
> deadband; halve on underperformance, double on headroom; `.critical` thermal
> forces a floor). The PID sketch below is the original preliminary design; the
> hysteretic controller is what runs (see [architecture.md](../architecture.md)).

### Feedback Controller

The adaptive quality system uses a PID-like controller to maintain target framerate by adjusting iteration budgets and histogram resolution.

**Control Loop:**

```swift
class QualityController {
    var targetFPS: Double = 60.0
    var minIterations: Int = 100_000_000  // per frame
    var maxIterations: Int = 10_000_000_000
    var currentIterations: Int = 2_000_000_000
    
    func update(measuredFPS: Double) {
        let error = targetFPS - measuredFPS
        
        // Proportional: adjust iterations inversely to fps error
        let adjustment = Int(error * -50_000_000)
        
        // Integral: accumulate sustained bias
        integralAccumulator += error * 0.1
        
        // Derivative: dampen oscillation
        let derivative = error - lastError
        
        let delta = adjustment + Int(integralAccumulator * 10_000_000) 
                  + Int(derivative * 5_000_000)
        
        currentIterations = clamp(
            currentIterations + delta,
            min: minIterations,
            max: maxIterations
        )
    }
}
```

**Hysteresis Parameters (preliminary):**
- Quality up-step threshold: fps > target + 5 for 10 consecutive frames
- Quality down-step threshold: fps < target - 3 for 5 consecutive frames
- Iteration adjustment granularity: ±10% per step

**Resolution-Scaling Strategy:**

| Resolution | Target FPS | Iteration Budget (typical) | Histogram Grid |
|------------|------------|----------------------------|----------------|
| 720p | 60 fps | 1.5B iterations | 256×144 bins |
| 1080p | 60 fps | 3B iterations | 384×216 bins |
| 1440p | 30 fps | 4B iterations | 512×288 bins |
| 4K | 30 fps | 8B iterations | 768×432 bins |

## Segment & Transition Engine Integration

The playback system orchestrates **two segment kinds** — loops and transitions —
using the interpolation engine described in
[`../rendering/transitions.md`](../rendering/transitions.md).

- **Loop:** a single sheep animated via flam3 `sheep_loop` — **purely rotate**
  each xform's pre-affine 2×2 0→360° (`R(θ)·M`) over `nframes` (seamless; the
  **palette is static** during a loop). This is what animates still sheep.
- **Transition:** a morph from sheep A's genome to sheep B's via `sheep_edge`
  (interpolate coefs + palette over `blend`).

**Alternation rule:** loops and transitions alternate — `loop → transition →
loop → transition`. Never two transitions in a row; every transition is
bracketed by loops.

**Segment Scheduling (pure `Schedule` + `PlaybackDispatcher`):**

The M3 realtime path is not a stateful scheduler class. It is a **pure
`Sendable` value-type `Schedule`** (FlameKit, Task 15) consumed by a
**`PlaybackDispatcher` actor** (FlamePlayer, Task 20):

```swift
// Schedule — pure value type, O(1) global-frame → (segmentId, kind, blend).
// Strict loop/transition alternation by segment-id parity (transitions only
// occupy odd ids → "no two transitions consecutive" holds by construction).
let schedule = Schedule(librarySize: n, framesPerSegment: 160,
                        selector: Sequential(seed: 0), seed: 0)

// PlaybackDispatcher — actor-isolated; advances the timeline one global frame
// at a time, renders via an injected Renderer, paces to targetFPS via an
// injected PlaybackClock, and PREFETCHES the next sheep mid-loop so the
// transition's first frame is ready.
let dispatcher = PlaybackDispatcher(
    schedule: schedule,
    sheepProvider: provider,
    renderer: MetalFrameRenderer(),     // @MainActor conformer wrapping MetalRenderer
    sink: flameUI,                      // FlameUI: FrameSink + CAMetalLayer
    clock: WallClock(),
    params: params,
    targetFPS: 60)
await dispatcher.run(frameCount: schedule.totalFrames(segmentCount: 1_000))
```

The dispatcher's prefetch launches at most one background fetch per loop segment
(`SheepProvider.sheep(at:)` for the upcoming transition's target), so the
transition's first frame is resident when the loop ends. The triple-buffered
`MTLTexture` rotation lives **behind** the production `Renderer` conformer (on
the `@MainActor`), not in the dispatcher actor — keeping the dispatcher Metal-free
and testable with fakes. `AdaptiveQualityController` (a pure value type) reads the
measured batch fps and emits the next `samplesPerPixel` budget.

**Segment Timing:**
- Frame budget grew with hardware: 128 (classic) → 160 → 320 → 900 (newest gen-248). Emberweft applies one budget to all sheep (loops are generated live by `sheep_loop`, so a sheep's era doesn't constrain it): **160 frames (~5.5–7 s) realtime**, **320 (~11–14 s) standard**, **900 (~15–39 s) premium (screensaver/export)**.
- Loops and transitions share the same budget; loops are played **once** then transitioned ("continuously morphing sequence").
- **Transitions are generated on the fly** (`sheep_edge(A, B)` from two still sheep, pairs chosen by similarity); stored ES edges are an optional curation oracle / classic-flock mode, not a render requirement (an edge is just its two endpoint stills + a time extent).
- Configurable; adaptive transitions may run shorter/longer for similar/dissimilar sheep.

**Stills are animated, not filtered:** every sheep (still or otherwise) becomes a moving loop via flam3 `sheep_loop` (pure 360° affine rotation; palette static). See [transitions.md](../rendering/transitions.md).

## Frame Pacing

### Display Synchronization

Frame timing is driven by `CVDisplayLink` for precise vsync alignment:

```swift
CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
CVDisplayLinkSetOutputHandler(displayLink) { 
    _, _, _, _, _ -> CVReturn in
    // Render frame for this display refresh
    renderFrame(for: displayLinkTimestamp)
    return kCVReturnSuccess
}
```

**Triple-Buffering Strategy:**

The renderer maintains a pool of three `MTLTexture` objects in rotation:
1. **Texture A**: Currently displayed by CAMetalLayer
2. **Texture B**: Being rendered by GPU compute
3. **Texture C**: Available for next frame submission

This pipeline hides GPU latency and prevents vsync misses.

### Preferred Frame Rates

The system respects `MTKView.preferredFramesPerSecond` and adapts to display capabilities:

- Standard displays: 60 fps
- ProMotion displays: 120 fps (when thermal state allows)
- Battery/Low Power mode: cap at 30 fps
- Screensaver mode: cap at 30 fps

## Energy and Power Management

### Battery-Aware Quality Scaling

```swift
func updateForPowerMode() {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal:
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            targetFPS = 30
            iterationBudget = baseBudget * 0.6
        } else {
            targetFPS = 60
            iterationBudget = baseBudget
        }
    case .fair:
        targetFPS = 30
        iterationBudget = baseBudget * 0.5
    case .serious, .critical:
        targetFPS = 24
        iterationBudget = baseBudget * 0.3
        // Force cached playback if available
        if cachedContentAvailable {
            playbackMode = .preRendered
        }
    }
}
```

**Power State Observers:**
- `ProcessInfo.thermalState` — monitored every 1 second
- `ProcessInfo.isLowPowerModeEnabled` — listened via notification
- IOPSBatteryState — for battery level and charger status

### Sleep and Display Coordination

- When display sleeps: pause all GPU work, release Metal command buffers
- On wake: reinitialize Metal pipeline, prefetch first frame
- On battery threshold **(preliminary)** < 15%: warn user, offer to pause or switch to cached

## Seek and Scrub

### Deterministic Re-Seeding

The chaos-game algorithm is fully deterministic given a fixed RNG seed. This enables frame-accurate seeking within a sheep or transition:

```swift
func seekToFrame(_ frameNumber: Int, in sheep: Sheep) {
    // Reinitialize RNG with sheep seed + frame offset
    rng.seed = sheep.baseSeed
    rng.advance(by: frameNumber * iterationsPerFrame)
    
    // Render from this state
    renderFrame(at: rng.state)
}
```

**Implementation Notes:**
- `iterationsPerFrame` is fixed per quality setting
- RNG advancement uses O(1) skip-ahead algorithm for the xoroshiro256+ generator
- Cached values for seek points (every 30 frames) avoid expensive RNG skips

### Scrubbing UI

- Scrubbing during transition: shows interpolated state at scrub position
- Scrubbing within sheep: jumps to deterministically re-rendered frame
- Visual feedback: frame number overlay, transition progress bar

## Performance Metrics

The playback system continuously reports the following metrics for performance analysis (see [`../engineering/performance.md`](../engineering/performance.md)):

- Frame time percentiles (p50, p95, p99)
- GPU utilization via `MTLDevice.gpuUtilization`
- Memory footprint (texture pools, histogram buffers)
- Thermal state transitions
- Mode switches (realtime ↔ cached)

## Related Documentation

- [`../rendering/transitions.md`](../rendering/transitions.md) — Transition interpolation engine
- [`../playback/formats.md`](../playback/formats.md) — Resolution and format support
- [`../engineering/performance.md`](../engineering/performance.md) — Performance profiling
- [`../overview.md`](../overview.md) — Project overview
- [`../architecture.md`](../architecture.md) — System architecture

---

**Credits:** The fractal flame algorithm is © Scott Draves. Electric Sheep™ and Infinidream™ are trademarks of Scott Draves and e-dream, inc.
