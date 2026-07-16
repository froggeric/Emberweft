# M2 — Metal Compute Renderer (Design Spec)

> **Status:** design — for owner approval · Emberweft · 2026-07-16
> Companion to [roadmap.md M2](../../engineering/roadmap.md), [development-approach.md S5](../../engineering/development-approach.md), [testing.md](../../engineering/testing.md), [metal-pipeline.md](../../rendering/metal-pipeline.md) (to be revised).

## Goal

Build `FlameRenderer`: a Metal-compute fractal-flame renderer that is a **faithful twin of the CPU reference** (`FlameReference`), proven to match it within parity thresholds, exposed through the CLI as `--backend cpu|metal`, with a recorded single-frame performance baseline and Metal-vs-CPU speedup. This is roadmap slice **S5**.

## Owner decisions (locked)

1. **Parity model = statistical, not byte-exact.** Each GPU thread runs its own chaos game with an **ISAAC stream deterministically seeded from the master seed** (flam3's parent→child per-thread derivation). The aggregate histogram converges to the same IFS invariant measure as the CPU, so Metal frames match CPU within the parity threshold, but are **not** byte-identical. Determinism is preserved **on Metal** (same seed → same Metal frame, machine-independent). Metal does **not** reproduce the CPU's single serial ISAAC stream — that is mathematically impossible under parallelism and would negate GPU acceleration (Stage 1 is ~70% of frame time). *Quotable: "Yes, go with A."*
2. **Faithful port, not reinterpretation.** ISAAC is ported to MSL (not a Wang/PCG hash); the affine convention (`tx=a·x+c·y+e`), `precalc_atan=atan2(x,y)`, EPS/badvalue guards, and the entire display pipeline (log-density k1/k2, Gaussian spatial filter, `calcAlpha`/`calcNewRGB`, vibrancy/background, palette×256, WHITE_LEVEL) are faithfully ported into Metal. Same 19-variation set as M1. (Carries forward the faithful-port directive and the M1 lessons in `renderer-is-faithful-flam3-port`.)
3. **Local-only execution is the source of truth; GitHub is a plain git mirror.** Build, all tests, and lint run locally before every merge — that is the hard gate. (See §CI.)

## Architecture

`FlameRenderer` mirrors `FlameReference` stage-for-stage so the two are true twins and bugs localize instantly (CPU-passes/Metal-fails ⇒ GPU bug; CPU-fails ⇒ algorithm bug):

```
Flame (Swift)  ──►  MetalHost (Swift, @MainActor command recording)
                         │  builds GPUXform/xform_distrib/palette buffers
                         ▼
              ┌───────────────────────────────────┐
   Stage 1    │ chaosGame kernel (MSL)             │  → Histogram buffer
              │  per-thread ISAAC, atomic bin      │     (count + color, fixed-pt)
              └───────────────────────────────────┘
                         ▼  (radius>0 gate)
              ┌───────────────────────────────────┐
   Stage 2    │ densityEstimation kernel           │  → filtered Histogram
              │  (M1 approximation, twin of CPU)   │     (bypassed when radius=0)
              └───────────────────────────────────┘
                         ▼
              ┌───────────────────────────────────┐
   Stage 3    │ displayPipeline kernel             │  → RGBA8 texture
              │  log-density, Gaussian filter,     │     (matches CPU ToneMapping)
              │  calcAlpha, calcNewRGB, palette,   │
              │  gamma, vibrancy, background       │
              └───────────────────────────────────┘
                         ▼
              readback → RGBA8Image  (makeBytesReadable)
```

**Shared render types:** `RGBA8Image` and `RenderParams` currently live in `FlameReference`. For `FlameRenderer` to expose the same signature without duplicating them (and without `FlameRenderer` depending on the whole CPU renderer — an undesirable coupling), these two pure value types are **moved up to `FlameKit`** as an M2 prerequisite refactor. `FlameReference` then re-exports them so existing call sites are unaffected. The CLI swap is thus signature-identical.

**Public API** (mirrors `ReferenceRenderer`):
```swift
public enum MetalRenderer {
    public static func render(flame: Flame, params: RenderParams) -> RGBA8Image
    public static var isAvailable: Bool { get }   // MTLCreateSystemDefaultDevice() != nil
}
```

## Kernel architecture (chosen: direct-binding, one kernel per stage)

Three MSL kernels, each a compute pass; host binds buffers/textures directly via `setBuffer`/`setTexture`. This is the simplest structure that reaches a green parity gate fastest and gives one parity check per stage (cleanest bisection). Threadgroup-privatized histograms (Option 3) and Metal-4 argument buffers (Option 2) are deferred to M3 as optimizations — the kernel design carries a deliberate hook for privatization so it lands without rearchitecting.

### Host↔device contract

- **`GPUXform`** (constant buffer): pre-affine `a,b,c,d,e,f`; post-affine `pa,pb,pc,pd,pe,pf`; `color` (xform color, default `index&1`); `colorSpeed`; `opacity`; `varWeights[19]` (fixed M1 order); `weight` (selection probability). Array length = xform count.
- **`xform_distrib[16384]`** — flam3's precomputed CDF, built **on the host** from `weight` (identical construction to CPU `ChaosGame`), uploaded as a constant buffer. The kernel selects a transform via `isaac.next() & 16383 → distrib[idx]`. This makes the *selection distribution* match the CPU byte-for-byte; only per-thread *ordering* differs (the source of statistical parity).
- **Histogram buffer**: per-bin `{atomic_uint count; atomic_uint r,g,b}`. MSL atomics are integer-only, so the CPU's floating color accumulation is accumulated as **`uint32` fixed-point with a per-frame rescale** `scale = 2³¹/(totalSamples·255)` (added in-kernel then dequantized on readback). `uint32` add mod 2³² is fully associative/commutative, so the sum is **identical regardless of thread scheduling** (deterministic), and the rescale makes overflow impossible by construction (no clamping, which would silently destroy log-density energy). Count is a plain exact `uint32`. (A naive Q8.24 scheme was rejected: it overflows hot bins and clamping corrupts parity. 64-bit atomics were rejected as Apple8-only, breaking the M1+ target.) See the plan for the exact encode/decode.
- **Palette**: 256-entry RGBA, constant buffer (matches `FlameKit.Palette`).

### RNG — faithful ISAAC, parallelized

- Port `Sources/FlameKit/ISAAC.swift` → ISAAC in MSL (RANDSIZ=16, same mix, same 64-bit overflow semantics). The Swift ISAAC is already byte-exact vs flam3's C; the MSL port is validated by a **host-side unit test running both on identical seeds and asserting identical streams** — this is the load-bearing parity primitive and the first thing proven.
- **Per-thread seeding:** thread `t` derives its ISAAC seed from `params.seed` via flam3's parent→child mechanism, with `t` folded into the seed material, so every thread gets a distinct deterministic stream. Thread geometry (groups × threads) is **pinned from params** (not live device caps) → machine-independent reproducibility.

### Stage 1 — chaos game kernel

Each thread runs `iterationsPerThread = totalSamples / threadCount` iterations: fuse=15 warmup, then iterate { pick xform via `distrib[isaac & 16383]`; apply pre-affine `tx=a·x+c·y+e`; sum weighted variations (faithful formulas, `precalc_atan=atan2(x,y)`, EPS=1e-10, badvalue `|·|>1e10`); apply post-affine; apply the **final xform to a separate binning point** (the M1 lesson — final-xform must not feed back into the trajectory); camera/project to grid identical to CPU; atomic-add count + quantized color }. The grid dimensions, gutter, and oversample match `RenderParams` exactly.

### Stage 2 — density estimation

Metal applies DE **iff** `estimatorRadius > 0`, mirroring `ReferenceRenderer`'s gate. For M2 it carries the **same M1 approximation** the CPU has — keeping the renderers twins (when CPU's DE becomes faithful, Metal's does too). All 6 parity genomes use `radius=0`, so DE is **not exercised** in M2 and is documented honestly (same posture as M1's notes in `CHANGELOG.md`).

### Stage 3 — display pipeline

The parity-critical stage. Ported in two steps to make parity bugs localize:

- **3b (on-ramp, first):** read back the Metal histogram and run the **existing CPU `ToneMapping`** on it. This isolates Stage 1 (chaos-game histogram) for parity proof before any Metal tone-mapping exists.
- **3a (full Metal, second):** a `displayPipeline` kernel faithfully porting `ToneMapping.swift` → writes an RGBA8 texture. Proven against CPU stage-3 on the **same** histogram (near-byte-exact; FP32 vs Double → high but finite dB).

Both paths ship: 3b remains available as a debug/parity-bisect mode.

## Determinism

Within the Metal backend, the same `(flame, params)` always yields an identical frame: ISAAC is seeded deterministically, thread geometry is pinned from params (not device caps), and there is no time-based or scheduling-dependent randomness. Metal output is **not** byte-identical to CPU output (different sample-to-thread mapping); they agree to the parity threshold.

**CLAUDE.md rule #2 wording (refined as part of M2):** *"Determinism is mandatory. Same genome + seed + params → identical frame within a backend, run after run and machine to machine. CPU and Metal are independent deterministic backends that agree within the parity threshold (PSNR ≥ 38 dB); they are not required to be byte-identical."*

## Parity & testing (per-stage, the heart of M2)

New module `Tests/FlameRendererTests/`:

| Test | Compares | Metric / threshold |
|---|---|---|
| MSL ISAAC vs Swift ISAAC | identical-seed streams | byte-equal |
| Metal histogram vs CPU histogram | per-bin count + color | L1 distance + count correlation; tightened vs the image gate |
| Metal stage-3 vs CPU stage-3 | identical input histogram | near-byte-exact (high dB; FP32 vs Double) |
| End-to-end Metal vs CPU | `RGBA8Image` | **PSNR ≥ 38 dB, SSIM ≥ 0.95** over 6 frozen genomes + fuzz genomes |
| Determinism | Metal PNG across runs | byte-identical |
| Finiteness | all pixels finite | no NaN/Inf |

Plus a **performance baseline** (regression guard, not a gate): single-frame time at 720p/1080p for both backends; record Metal:CPU speedup. M2 records the number; M3 targets fps.

## CI / execution posture

**Local-only is the source of truth; GitHub is a plain git mirror.** Rationale: Metal needs a real Apple-Silicon GPU that GA runners don't reliably expose (and shared/metered GPUs make timing baselines flaky/meaningless); the dev-only flam3 oracle isn't installable in GA; byte-stable golden PNGs are inherently a local concern.

- Build, all tests (unit, golden parity vs flam3, Metal↔CPU parity, perf baselines), and lint run **locally before every merge** — the hard gate.
- **`docs/engineering/testing.md`** "CI gates" section is rewritten to a **"Local pre-merge gate"** section.
- **The M0-era GitHub Actions workflow** (`.github/workflows/*`) — **owner decision (open):** (a) delete it entirely (cleanest, matches "repo only"), or (b) keep a minimal *advisory, non-gating* build+lint smoke (no Metal, no oracle) that may be red without blocking. Recommended: **(a) delete**. This is flagged for the owner; the plan will not assume either without confirmation.

## CLI

`emberweft render g.flam3 --backend metal` → `MetalRenderer.render`; `--backend cpu` remains default. `--list-backends` reports availability (`isAvailable`). Same exit codes, same PNG output path, same byte-stable-output expectations *per backend*. `EmberweftCLI` already depends on `FlameRenderer`.

## Docs updated as part of M2

- **`docs/rendering/metal-pipeline.md`** — rewritten to the faithful-port reality: drop the pre-pivot Wang/PCG-hash RNG and Reinhard/HDR speculation; document faithful ISAAC, FP32+fixed-point accumulation, statistical parity, and the three stages as actually built.
- **`CLAUDE.md` rule #2** — refined wording (above).
- **`docs/engineering/testing.md`** — confirm the ≥38 dB Metal gate; add the per-stage test table; replace "CI gates" with "Local pre-merge gate".
- **`CHANGELOG.md`** — M2 entry on completion.

## Out of scope for M2 (deferred)

- Threadgroup-privatized histograms and Metal-4 argument buffers (M3 optimization).
- Faithful (non-approximation) density estimation (separate work; radius=0 goldens don't exercise it).
- Variations beyond the M1 set of 19 (waves/popcorn/tangent/square/cross, etc.).
- Realtime playback, animation, adaptive quality (M3+).
- HDR / 10-bit / Reinhard tone-mapping (M8).

## Risks & mitigations

- **FP32 vs Double parity floor.** Iteration math in `Float` may cost dB near dense regions. Mitigation: accumulate histogram color in wider fixed-point (Q8.24 or Q16.16); if a genome dips under 38 dB, the lever is more samples, not an algorithm change.
- **Atomic color quantization.** The `uint32` per-frame-rescale encoding makes overflow impossible by construction and needs no clamp; the host validates the dequantized Double range against the CPU buckets. (Resolved in the plan; see "Color accumulation encoding" there.)
- **MSL ISAAC correctness.** The byte-equal unit test (Swift vs MSL) is the guardrail; it lands first, before any chaos-game kernel depends on it.
- **Runner-GPU uncertainty** is moot under local-only execution.
