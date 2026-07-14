# Performance

*Performance targets, resource budgets, and optimization strategies for realtime rendering.*

> **Status:** preliminary — for review · Emberweft

## Realtime Performance Targets

The renderer targets smooth playback at common resolutions and frame rates on Apple Silicon hardware. Performance is GPU-bound, with the chaos-game iteration kernel consuming the majority of frame time.

**Target framerates (preliminary, M2 Max):**

| Resolution | Target FPS | Target FPS (Battery) | Quality Tier |
|------------|-----------|---------------------|--------------|
| 720p (1280×720) | 60 | 45 | Medium |
| 1080p (1920×1080) | 60 | 30 | High |
| 1440p (2560×1440) | 60 | 30 | High |
| 4K (3840×2160) | 30 | 24 | Ultra |

**Target framerates (preliminary, M1/M2 base):**

| Resolution | Target FPS | Quality Tier |
|------------|-----------|--------------|
| 720p (1280×720) | 60 | Low |
| 1080p (1920×1080) | 30 | Medium |
| 1440p (2560×1440) | 30 | Medium |
| 4K (3840×2160) | 15 (fallback) | Low |

**Screensaver targets:**
- Default quality tier: Medium (balanced)
- FPS cap: 30 **(preliminary)**
- Adaptive quality enabled by default

## Quality Tiers and Parameters

The primary quality knob is the number of chaos-game iterations per frame. More iterations produce smoother, more detailed flames but consume more GPU time.

**Quality tier parameters (preliminary):**

| Tier | Iterations | Histogram Grid | Filter Radius | Use Case |
|------|-----------|----------------|----------------|----------|
| Low | 500 | 64×64 | 1.0 | Battery, 4K fallback |
| Medium | 1000 | 128×128 | 1.5 | Default playback |
| High | 2000 | 256×256 | 2.0 | High-end machines |
| Ultra | 5000 | 512×512 | 3.0 | Export, screenshots |

**Per-resolution defaults (preliminary):**

| Resolution | Iterations (Plugged) | Iterations (Battery) |
|------------|---------------------|----------------------|
| 720p | 1000 | 500 |
| 1080p | 2000 | 1000 |
| 1440p | 2000 | 1000 |
| 4K | 3000 | 1500 |

**Trade-offs:**
- **Iterations**: Primary quality control. Higher = smoother gradients, finer details.
- **Histogram grid**: Larger grids capture more spatial detail but increase memory bandwidth.
- **Filter radius**: Larger radii produce smoother edges but increase blur.

## GPU Memory Budget

GPU memory is dominated by the histogram buffer and accumulation buffer. Careful sizing ensures the renderer fits within the GPU's memory budget without spilling to system RAM.

**Buffer sizing (preliminary):**

**Histogram buffer:**
- Format: 32-bit float RGBA (16 bytes per bin)
- 64×64 grid: 64 × 64 × 16 = 64 KB
- 128×128 grid: 128 × 128 × 16 = 256 KB
- 256×256 grid: 256 × 256 × 16 = 1 MB
- 512×512 grid: 512 × 512 × 16 = 4 MB

**Accumulation buffer:**
- Format: 32-bit float RGBA (16 bytes per pixel)
- 720p: 1280 × 720 × 16 = 14.6 MB
- 1080p: 1920 × 1080 × 16 = 33.1 MB
- 1440p: 2560 × 1440 × 16 = 58.9 MB
- 4K: 3840 × 2160 × 16 = 132 MB

**Total GPU memory per frame:**

| Quality Tier | Histogram | Accumulation (1080p) | Total |
|--------------|-----------|----------------------|-------|
| Low | 64 KB | 33 MB | ~33 MB |
| Medium | 256 KB | 33 MB | ~33 MB |
| High | 1 MB | 33 MB | ~34 MB |
| Ultra | 4 MB | 33 MB | ~37 MB |

**Texture pool:**
- Pre-allocated textures for ping-pong rendering
- 3 textures per resolution for triple-buffering
- Total pool size: ~100 MB at 1080p

**Total GPU memory budget:**
- Working set: ~150 MB per renderer instance
- ScreenSaver overhead: ~200 MB total
- App overhead: ~250 MB total (includes UI and library caches

Apple Silicon GPUs have 7–8 GB of shared memory, so the renderer fits comfortably even at Ultra quality.

## CPU Performance

The main thread must remain free to handle UI, audio, and system events. Rendering and heavy I/O are offloaded to dedicated threads/actors.

**Main thread responsibilities:**
- SwiftUI/AppKit UI rendering
- Event handling (mouse, keyboard, touches)
- Metal drawable presentation (lightweight)

**Dedicated threads:**
- **Renderer thread**: Coordinates Metal command buffer encoding
- **Export thread**: Runs AVFoundation export pipeline
- **I/O actor**: Asynchronous file I/O for library operations

**CPU usage targets:**
- Main thread: <10% CPU during playback
- Renderer thread: <20% CPU (GPU-bound, so CPU usage is low)
- Export thread: <30% CPU during export (encoding is GPU-accelerated)

## Energy and Thermal Management

As a screensaver and long-running app, energy efficiency is critical. The renderer adapts to thermal state and battery level to maintain performance while minimizing power consumption.

**Adaptation strategies:**

**Battery-based adaptation:**
- Reduce iteration count by 50% on battery **(preliminary)**
- Disable supersampling on battery
- Limit FPS to 30 on battery **(preliminary)**

**Thermal state adaptation:**
- Monitor `ProcessInfo.thermalState` for thermal pressure
- Reduce quality gradually as thermal state increases:
  - **Nominal**: Full quality
  - **Fair**: Reduce iterations by 25%
  - **Serious**: Reduce iterations by 50%
- Return to full quality when thermal state returns to nominal

**Low Power Mode respect:**
- Detect system Low Power Mode setting
- Cap FPS at 30 when Low Power Mode is enabled **(preliminary)**
- Use Medium quality tier regardless of resolution

**Energy budgeting:**
- Target: <5W sustained power draw during playback
- Strategy: Limit GPU utilization to 60–70% to leave headroom
- Measurement: Use Metal performance counters and Instruments Energy Log

## Performance Profiling Plan

Performance is validated through a combination of real-time monitoring and offline benchmarks.

**Profiling tools:**

**Xcode GPU Capture:**
- Capture single frames for detailed analysis
- Identify bottlenecks in compute or render pipelines
- Verify shader compilation and optimization

**Instruments:**
- **Time Profiler**: Identify CPU hotspots
- **Metal System Trace**: GPU utilization, memory bandwidth, warp execution
- **Energy Log**: Power consumption over time
- **Allocations**: Memory allocation patterns and leaks

**Built-in profiling:**
- **Metal Performance HUD**: Real-time FPS, GPU utilization, frame time
- **Custom metrics**: Frame time histogram, quality tier changes

**Benchmark suite:**
- **Determinism benchmarks**: Verify same seed produces identical frames
- **Regression benchmarks**: Automated performance regression tests
- **Quality benchmarks**: Visual quality vs. iteration count trade-offs

**Benchmark scenarios:**
1. **Static playback**: Single genome, no transitions, 60 seconds
2. **Transition playback**: Rapid genome switching every 10 seconds
3. **Export mode**: High-quality offline rendering
4. **Battery mode**: Reduced quality on battery power
5. **Thermal stress**: Sustained playback to trigger thermal throttling

## Determinism Requirements

For export and offline rendering, determinism is critical: the same genome seed must produce identical frames every time, regardless of machine or timing.

**Determinism strategies:**
- **Fixed random seed**: Chaos-game uses a seeded RNG for reproducibility
- **Integer coordinates**: Histogram bins use integer indices to avoid floating-point drift
- **No frame-skipping**: Export mode never skips frames, even if slow
- **Consistent precision**: Use 32-bit float consistently (no 16-bit half-float in iteration)

**Verification:**
- **Snapshot tests**: Compare rendered frames against golden images
- **Hash verification**: Hash output frames and compare to known values
- **Cross-platform verification**: Ensure same output on different Apple Silicon models

Determinism is only required for export. Realtime playback may skip frames or vary slightly based on performance.

## Performance Regression Prevention

To prevent performance regressions over time:

**Automated benchmarks:**
- CI runs performance benchmarks on each commit
- Alerts if frame time increases by >10%
- Tests across all quality tiers and resolutions

**Performance budgeting:**
- Each quality tier has a maximum frame time budget
- Metal pipeline must fit within budget (e.g., 16.6ms for 60 FPS)
- Kernels are profiled individually and in aggregate

**Profiling schedule:**
- **Pre-milestone**: Full profiling suite before each milestone release
- **Post-refactor**: Profile after significant refactoring
- **Quarterly**: Comprehensive performance audit

## Adaptive Quality Controller

The `AdaptiveController` in FlamePlayer manages quality adaptation based on performance:

**Controller logic:**
1. Measure frame time over a sliding window (e.g., 60 frames) **(preliminary)**
2. If average frame time exceeds budget (e.g., >20ms for 60 FPS), reduce quality
3. If frame time is well under budget, increase quality
4. Apply hysteresis to avoid rapid quality changes

**Quality adjustment steps:**
- Step down: Reduce iterations by 25%
- Step up: Increase iterations by 25%
- Minimum: Low quality tier (cannot go lower)
- Maximum: Ultra quality tier (cannot go higher)

**User override:**
- Users can lock quality tier in settings
- Screensaver can disable adaptation for consistency
- Export always uses Ultra quality

## Related Documentation

- [`../rendering/metal-pipeline.md`](../rendering/metal-pipeline.md) — Metal implementation and optimization
- [`../playback/playback-modes.md`](../playback/playback-modes.md) — Realtime vs. cached modes
- [`../platform/screensaver.md`](../platform/screensaver.md) — Screensaver-specific performance considerations

---

**Credit**: fractal flame algorithm © Scott Draves (1992). Electric Sheep™ and Infinidream™ are trademarks of Scott Draves / e-dream, inc.
