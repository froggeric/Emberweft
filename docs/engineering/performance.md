# Performance

*Performance targets, resource budgets, and optimization strategies for realtime rendering.*

> **Status:** preliminary — for review · Emberweft

## Measured results (M2)

Recorded on the dev machine (Apple Silicon) via `EMBERWEFT_PERF=1 swift test --filter PerformanceBaselineTests`. Single-frame render at 100 samples/pixel, oversample 1. CPU is single-threaded (`ReferenceRenderer`); Metal is `MetalRenderer`.

**Metal vs CPU — single-frame speedup:**

| Genome | 720p CPU / Metal | 1080p CPU / Metal | 1080p speedup |
|--------|------------------|-------------------|---------------|
| final_warp | 75.6s / 4.3s | 169.5s / 9.5s | **17.8×** |
| rich | 70.6s / 4.3s | 157.8s / 9.6s | 16.5× |
| julia_bubbles | 69.0s / 4.3s | 156.1s / 9.7s | 16.2× |
| heart_disc | 66.7s / 4.3s | 150.4s / 9.5s | 15.8× |
| swirl_field | 63.5s / 4.2s | 142.3s / 9.6s | 14.9× |
| sierpinski | 49.1s / 4.2s | 110.5s / 9.5s | 11.6× |

Metal clears the 1.0× sanity floor on every genome with large headroom. The targets below (60 fps @ 1080p) are for M3 once the three stages are fused into one command buffer and the histogram stays on-GPU — the headline M3 optimization (today the histogram round-trips through CPU between stages).

**Correctness-at-speed is proven:** at these frame times Metal still matches the CPU reference at 39–60 dB PSNR / SSIM ≥ 0.95 (see [testing.md](testing.md)). Faster rendering did not cost parity.

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
- Format: 5×`uint32` fixed-point per bin (`count, R, G, B, A`; 20 bytes/bin)
- 64×64 grid: 64 × 64 × 20 = 80 KB
- 128×128 grid: 128 × 128 × 20 = 320 KB
- 256×256 grid: 256 × 256 × 20 = 1.3 MB
- 512×512 grid: 512 × 512 × 20 = 5 MB

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

## Determinism

Determinism is mandatory (CLAUDE.md rule #2): the same genome + seed + params yields an identical frame **within a backend**, run after run and machine to machine. CPU and Metal are independent deterministic backends that agree within the parity threshold (PSNR ≥ 38 dB); they are not byte-identical to each other.

**How it holds on Metal:**
- **Faithful ISAAC**, ported to MSL byte-exact and seeded per-thread via flam3's parent→child mechanism.
- **`uint32` fixed-point atomic histogram** — integer addition is associative, so the accumulated sum is independent of thread scheduling (float atomics would be order-dependent and are not used).
- **Pinned thread geometry** derived from params, not from device caps.

**Verification:** byte-identical-output tests across repeated runs (both backends); MSL ISAAC byte-equality vs the Swift ISAAC; golden-image parity vs `flam3` and vs the CPU reference. See [testing.md](testing.md).

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
