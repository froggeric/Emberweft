# Metal Pipeline
*Metal-compute fractal-flame renderer — as built in M2*

> **Status:** as-built · Emberweft

Companion to [flame-algorithm.md](flame-algorithm.md) and [../engineering/testing.md](../engineering/testing.md).

## Overview

`FlameRenderer` is the Metal-compute twin of the CPU reference (`FlameReference`). It is a **faithful**, not approximate, implementation of the same flam3-derived algorithm: the same affine convention, variation formulas, ISAAC RNG + consumption order, density-estimation filter, and display pipeline. It is a **statistical** twin, not a byte-exact one — the two backends are independently deterministic and agree within PSNR ≥ 38 dB / SSIM ≥ 0.95 on the frozen golden set (see [Parity model](#parity-model)).

The pipeline is three compute stages, each a faithful Metal twin of the corresponding CPU stage:

```
Flame (FlameKit) + RenderParams
        │
        ▼
┌──────────────────────────────────────────────┐
│  Stage 1: Chaos game                         │
│  chaosGame kernel (per-thread ISAAC)         │
│  → uint32 fixed-point atomic histogram       │
└──────────────────────────────────────────────┘
        │
        ▼
┌──────────────────────────────────────────────┐
│  Stage 2: Density estimation                 │
│  densityEstimate kernel (radius > 0;         │
│  radius == 0 is a passthrough)               │
└──────────────────────────────────────────────┘
        │
        ▼
┌──────────────────────────────────────────────┐
│  Stage 3a: Display pipeline                  │
│  logDensity kernel  →  displayPipeline       │
│  kernel (spatial filter + gamma + vibrancy)  │
│  → RGBA8Unorm output buffer                  │
└──────────────────────────────────────────────┘
```

The entry point is `MetalRenderer.render(flame:params:) -> RGBA8Image`.

## Determinism and parity model

- **Within-backend determinism is mandatory.** Same `(flame, params, seed)` → byte-identical frame on the Metal backend, run after run and machine to machine. Thread geometry is **pinned from params alone** (not from device caps): `MetalHost.pinnedThreadCount` derives a fixed thread count from `totalSamples`, rounded to a multiple of 256, so the same sample budget yields the same per-thread ISAAC seeds on every machine.
- **CPU and Metal are not byte-identical to each other.** They differ in atomic-accumulation order and per-thread sample split. They agree within the parity threshold (PSNR ≥ 38 dB, SSIM ≥ 0.95 end-to-end; byte-exact on the Stage-3a display path when run on the same histogram).

This is the model the [testing.md](../engineering/testing.md) parity gates enforce.

## Stage 1 — Chaos game

Kernel: `chaosGame` (`Metal/Kernels.metal`). Host: `ChaosGameMetal.iterate`.

Each thread runs the chaos game independently:

1. Seed its own ISAAC state from the precomputed per-thread `randrsl` (see [RNG](#rng-isaac-and-per-thread-seeding) below).
2. Execute `fuse` (15) skip iterations to leave the attractor basin.
3. For each of `iterationsPerThread` iterations (first `remainder` threads do one extra so the total is exactly `totalSamples`): choose a transform via the precomputed `distrib` table, apply the affine + 19-slot variation table + post-affine, optionally apply the final xform to a separate binning point, and atomically accumulate into the histogram bin under the camera projection.

### Histogram encoding — `uint32` fixed-point atomics

Each histogram bin is **5 × `uint32`**: `{count, r, g, b, a}`. Per-hit accumulation is:

```
atomic_fetch_add_explicit(&bin.count, 1, relaxed)
atomic_fetch_add_explicit(&bin.r, uint(clamp(v.r,0,255) * colorScale + 0.5), relaxed)  // g, b, a likewise
```

where `colorScale = 2^31 / (totalSamples · 255)` (`MetalHost.colorScale`). Decode on the host divides each channel by `colorScale` to recover dmap-units Doubles matching the CPU oracle's `hist.colors`/`hist.alpha`. `count` is exact (1 per hit).

**Why `uint32` fixed-point, not float or `uint64`:**

- **Float atomics were rejected.** Metal has no native `atomic_fetch_add` on `float`; a compare-and-swap (CAS) loop would make accumulation order **data-dependent** and break within-backend byte-determinism (the mandate). Atomic-order nondeterminism is acceptable *across backends* (statistical parity), but not *within* a backend.
- **64-bit atomics were rejected.** `metal::atomic<uint64>` requires Apple8/M2+; Emberweft targets **M1+** (the explicit deployment floor). Using 64-bit atomics would exclude the M1 machines the project must support.
- The `uint32` fixed-point encoding is deterministic, overflow-safe (the `2^31` headroom and per-frame `colorScale` scale the per-hit contribution to fit), and M1+-compatible. Its precision is bounded by the sample budget T — see [Known limitation](#known-limitation-precision-floor).

## RNG: ISAAC and per-thread seeding

Per-thread RNG is a **faithful MSL port of flam3's ISAAC** (`isaac.c`), byte-equal to the Swift `FlameKit.ISAAC` for identical seeds (verified by `MSLIsaacParityTests`). The chaos-game RNG and its consumption order match flam3 exactly — no other hash-based PRNG is substituted.

Seeding replicates flam3's parent→child mechanism on the host (`MetalHost.buildThreadSeeds`): a single parent ISAAC seeded with `"emberweft-metal-<seed>"` draws `randsizWords` (256) `UInt64` values per thread, filling a flat `[UInt64]` of size `threadCount · 256`. Each GPU thread loads its 256-word slice into its private `randrsl` and initializes its ISAAC. This is collision-free, deterministic, and machine-independent.

## Stage 2 — Density estimation

Kernel: `densityEstimate` (`Metal/Kernels.metal`). Host: `DensityEstimationMetal.apply`. Faithful twin of the CPU M1 density estimator: adaptive kernel radius from per-bin density, neighbor gather, normalized accumulate. When `flame.quality.estimatorRadius == 0` (the case for the frozen goldens) the stage is a **passthrough** — the host skips the kernel and hands the histogram straight to Stage 3a.

## Stage 3a — Display pipeline

Two kernels in one command buffer, executed in enqueue order with full write-visibility between them (the portable, API-stable sync):

1. **`logDensity`** — one thread per grid cell; computes the per-bin log-density scale (flam3 `rect.c` k1/k2) and writes `accumRGB`/`accumA`.
2. **`displayPipeline`** — one thread per output pixel; gathers through the Gaussian spatial-filter kernel, applies gamma/vibrancy/background blend (`calcAlpha`/`calcNewRGB`), and writes one `RGBA8` pixel.

Host: `DisplayPipelineMetal.render`. The spatial-filter kernel is computed in `Double` and cast to `Float` so the MSL convolves with the same coefficients the CPU oracle uses, to float precision. The `DisplayParams` struct (9 floats + 7 uints = 64 bytes) is laid out identically to its MSL mirror; `MemoryLayout<DisplayParams>.size == 64` is asserted at runtime.

Output is `RGBA8Unorm` (8-bit per channel, sRGB). The display pipeline faithfully follows flam3's 8-bit output path; no half-float/HDR output or alternative global tone-map operator is applied.

## Build mechanism — `.metal` as a SwiftPM resource

The `.metal` sources are **not** compiled by the SwiftPM/Metal toolchain into a `.metallib`. Instead they are bundled as SwiftPM resources and compiled at runtime:

```swift
// Package.swift — FlameRenderer target
.target(
    name: "FlameRenderer",
    dependencies: ["FlameKit"],
    path: "Sources/FlameRenderer",
    exclude: ["Metal"],
    resources: [.copy("Metal")]
)
```

`MetalRenderer.deviceAndLibrary()` loads `Kernels.metal` from `Bundle.module`, reads it as source text, and compiles it with `device.makeLibrary(source:options:)`. The result is memoized along with the system default `MTLDevice` and a `MTLCommandQueue`. This keeps the build a pure SwiftPM build (no separate `.metal` build step, no checked-in `.metallib`) and lets the renderer compile against whatever Metal SDK is present at run time.

`MetalRenderer` is an `enum` (no instances). The public surface is:

- `MetalRenderer.isAvailable: Bool` — true iff a Metal device exists **and** `Kernels.metal` compiles. Gate `--backend metal` on this; the CLI falls back to CPU otherwise.
- `MetalRenderer.render(flame:params:) -> RGBA8Image` — the full pipeline; `@MainActor`. Calls `isAvailable` internally and `fatalError`s if false (the host should never route here without a device).

The production path depends on **FlameKit only** (not FlameReference), matching the M2 task goal.

## Stage-3b on-ramp — a test-only parity-bisect tool

`Tests/FlameRendererTests/OnRamp3b.swift` + `EndToEndParity3bTests.swift` keep the historical Stage-3b configuration (Metal chaos-game → CPU `ToneMapping`) as a **debug tool** in the test target. It is not part of the production path. Its purpose is parity bisection: if the end-to-end parity gate regresses but the Stage-3b on-ramp still passes, the regression is localized to the Metal display pipeline; if the on-ramp also fails, the regression is in the Metal chaos kernel. It was the first end-to-end image-level parity gate and remains the cleanest way to isolate chaos-side bugs.

## Parity model

CPU and Metal agree within the thresholds enforced in [testing.md](../engineering/testing.md):

| Stage | Gate |
|---|---|
| MSL ISAAC vs Swift ISAAC | byte-equal stream for identical seeds |
| Stage-1 histogram | per-bin `count` correlation > 0.999 |
| Stage-3a (same histogram) | PSNR ≥ 50 dB (byte-exact, `inf` in practice) |
| End-to-end (production) | PSNR ≥ 38 dB, SSIM ≥ 0.95 |
| Determinism | byte-identical Metal output across repeated runs |

End-to-end parity on the frozen golden set at 320×200 / seed 0 / oversample 1 / 1000 spp:

| Genome | PSNR (dB) | SSIM |
|---|---|---|
| `final_warp` | 59.80 | 1.0000 |
| `swirl_field` | 52.84 | 0.9999 |
| `sierpinski` | 50.59 | 1.0000 |
| `rich` | 43.53 | 0.9921 |
| `heart_disc` | 41.72 | 0.9771 |
| `julia_bubbles` | 39.04 | 0.9533 |
| fuzz (julia+spherical) | 40.78 | 0.9947 |

## Known limitation — precision floor

The `uint32` fixed-point atomic encoding (`colorScale = 2^31 / (T · 255)`) has a **precision floor tied to the total sample count T**. Mathematically ill-posed genomes whose orbit passes through a variation's `1/r²`-type singularity (e.g. `spherical` at the origin) can produce unbounded-density bins that saturate this floor, observable as sub-threshold PSNR that **does not improve** with more samples. Real flam3 genomes — and all six frozen goldens — are well-posed and unaffected.

This is a documented tradeoff of the M1+-compatible `uint32` encoding, not a renderer bug. The fix would be 64-bit atomics, which would raise the floor but require Apple8/M2+ and so violate the M1+ deployment target. The fuzz genome above (julia+spherical, 40.78 dB / 0.9947) is the stress test that exercises this regime and stays above threshold.

## Performance

Single-frame baseline (M-series, `EMBERWEFT_PERF=1`, 100 spp, oversample 1):

- 1080p speedup: **11.62×** (`sierpinski`) … **17.82×** (`final_warp`).
- Representative: `final_warp` 1080p CPU 169.51 s → Metal 9.51 s = **17.82×**.
- 720p speedup is in the same 11.6×–17.8× band.

Stage 1 (chaos game) dominates frame time, as expected for a flame renderer. See [../engineering/performance.md](../engineering/performance.md) for targets.

## References

- [flame-algorithm.md](flame-algorithm.md) — algorithm description
- [../engineering/testing.md](../engineering/testing.md) — test layers, local pre-merge gate, thresholds
- [../engineering/development-approach.md](../engineering/development-approach.md) — Reference-then-Optimize methodology
