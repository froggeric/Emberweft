# Testing

*Test methodology, oracles, and quality gates for Emberweft.*

> **Status:** preliminary — for review · Emberweft

Companion to [development-approach.md](development-approach.md) and [performance.md](performance.md). Emberweft is developed test-first; the tests described here are written *before* the code that satisfies them.

## Testing philosophy

- **Oracle-validated.** Correctness is measured against an independent reference — the dev-only `flam3` renderer for the CPU path, and the CPU path for the Metal path.
- **Determinism is non-negotiable.** Same genome + seed + params → identical frame within a backend, run after run and machine to machine. CPU and Metal are independent deterministic backends that agree within the parity threshold; they are not byte-identical to each other. Most tests exploit this.
- **Layered tests.** Fast, pure unit tests run constantly; expensive image/parity tests run in the local pre-merge gate; benchmarks run as regression guards.
- **No silent re-goldening.** When a golden reference must change, it is a deliberate, reviewed action with a recorded reason — never a side-effect of a refactor.

## Test layers

### 1. Unit tests (pure, fast)
XCTest, run on every save and in the local pre-merge gate.

- **Genome model & parser:** `.flam3` parse → serialize round-trip equality; known-genome field extraction; default-filling for missing attributes; rejection of malformed XML and degenerate transforms (NaN/Inf coefficients, non-finite weights).
- **Interpolation:** temporal interpolation between two genomes (coefficients, variation weights, color index, opacity, camera center/scale-in-log-space); boundary cases (different transform counts, missing final xform).
- **Variation functions:** each variation (sinusoidal, spherical, swirl, horseshoe, …) tested with known (x,y) inputs → expected outputs, including NaN/Inf guards.
- **Affine/transform math:** coefficient application, post-transforms, variation composition.
- **RNG:** deterministic output for a fixed seed; distinct streams per thread index.

### 2. Golden-image tests (correctness oracle)
The correctness backbone for `FlameReference` (and transitively for the algorithm).

- **Frozen genome set.** A curated, versioned set of ~12 `.flam3` genomes covering: a few transforms, many transforms, final xforms, edge-heavy and detail-heavy attractors, varied palettes. Lives under `Tests/Goldens/genomes/`.
- **Golden generation.** A checked-in script renders each frozen genome with dev-only `flam3` at a fixed size/quality and stores the result under `Tests/Goldens/reference/`. `flam3` is **never** linked into or distributed with Emberweft (see [license-and-attribution.md](../license-and-attribution.md)). `flam3` has **no Homebrew formula** — it is built from source (`scottdraves/flam3`, autotools + zlib/libpng/libxml2); see the M3 [animation spec](../superpowers/specs/2026-07-17-m3-animation-design.md) and `Tools/flam3_oracle.sh`.
- **Comparison.** `FlameReference` renders the same genomes; output is compared to the goldens by **PSNR ≥ threshold** and **SSIM ≥ threshold** *(preliminary: PSNR ≥ 30 dB, SSIM ≥ 0.95 — to be tuned after first parity runs)*. Near-exact match is not expected (different RNG/filter implementations), so thresholds are statistical.
- **Re-goldening.** A dedicated, review-required workflow; the local pre-merge gate fails loudly on unexpected golden drift.

#### 2a. Animation oracle (`flam3-genome` / `flam3-animate`) — dev-machine prerequisite, F10 auto-skip
The M3 animation pipeline extends the still-frame oracle to motion genomes. The same locally-built `flam3` (above) provides two more binaries — `flam3-genome` (generate motion genomes) and `flam3-animate` (render them) — driven entirely by **env vars** (no CLI flags): `sequence`/`rotate`/`inter` + `nframes`/`frame` for `flam3-genome`; `begin`/`end`/`prefix` for `flam3-animate`. The Swift harness `Tests/FlameReferenceTests/Flam3Oracle.swift` spawns them via `Process`.

- **Build-from-source instructions** live in `Tools/flam3_oracle.sh` (pinned `scottdraves/flam3` commit, `brew install` deps, `./configure && make`, the literal env-var invocations). This is a **dev-machine prerequisite, not a CI step** (GitHub is a plain mirror; no CI runs).
- **Motion blur OFF for clean parity (F6).** `flam3-animate`'s temporal oversampling is on by default (`temporal_samples=1000` → heavy blur on fast-moving frames). For vs-Emberweft parity the harness injects **`passes="1"` and `temporal_samples="1"`** onto every `<flame>` control point before spawning `flam3-animate` — these are **genome attributes, not env vars**. Without this, the ≥30 dB vs-flam3 gate would fail systematically on transition interiors (motion-blur signal, not a port bug). *(v0.1.0 note: Emberweft now ports `temporal_samples` motion blur on both backends — `--temporal-samples N` — so this blur-off oracle comparison isolates structural parity rather than measuring an Emberweft capability gap.)*
- **F10 auto-skip.** `Flam3Oracle.isAvailable` returns true iff both binaries resolve on `$PATH`; every vs-flam3 test calls `try Flam3Oracle.require()`, which `XCTSkip`s with a clear warning when the build is absent. vs-flam3 tests are therefore **no-ops (never failures)** on machines without the build. **Metal↔CPU parity (≥38 dB) remains the hard gate** and is independent of flam3 availability.

### 3. Parity tests (Metal ↔ CPU)
Validate that `FlameRenderer` (Metal) matches `FlameReference` (CPU) on identical inputs. Parity is **statistical, not byte-exact**: the two backends are independent deterministic implementations (different atomic-accumulation order, different per-thread sample split). Parity is measured PSNR ≥ 38 dB / SSIM ≥ 0.95 end-to-end, with tighter per-stage gates below.

- Same genome + seed + size + quality → compare outputs.
- Run across the frozen genome set plus randomized fuzz genomes.
- Per-stage gates (see "Metal per-stage tests" below): MSL ISAAC byte-equality, histogram correlation, Stage-3a byte-exactness vs CPU ToneMapping on the same histogram, end-to-end PSNR/SSIM, byte-determinism, and finiteness.

### 4. Metal per-stage tests
The parity gate (section 3) is decomposed into per-stage checks that localize regressions to the offending Metal kernel. Each check runs against the frozen genome set (and randomized fuzz for the end-to-end gate):

- **MSL ISAAC byte-equality** — the MSL ISAAC port produces the same 32-bit stream as the Swift `FlameKit.ISAAC` for identical seeds, verified word-for-word. (`MSLIsaacParityTests`)
- **Stage-1 histogram** — Metal chaos-game histogram vs CPU chaos-game histogram: per-bin `count` correlation > 0.999 and L1 distance within tolerance. The count channel is exact (1 per hit); color/alpha are recovered from the `uint32` fixed-point encoding within bounded quantization. (`HistogramParityTests`)
- **Stage-3a display pipeline** — Metal `logDensity` + `displayPipeline` vs CPU `ToneMapping.render` on the **same input histogram**: byte-exact (`inf` dB). Isolates the display path from chaos-game divergence. (`Stage3aParityTests`)
- **Stage-3b on-ramp (debug, test-only)** — Metal chaos-game → CPU `ToneMapping`, the first end-to-end image-level parity gate. Kept as a parity-bisect tool in the test target: a failure here means the regression is in the chaos kernel, not the display pipeline. (`OnRamp3b`, `EndToEndParity3bTests`)
- **End-to-end (production)** — full Metal pipeline (`MetalRenderer.render`) vs full CPU pipeline (`ReferenceRenderer.render`): PSNR ≥ 38 dB / SSIM ≥ 0.95 on all frozen goldens + fuzz genomes at 1000 spp. (`EndToEndParityTests`)
- **Determinism** — repeated `MetalRenderer.render` calls on the same inputs produce byte-identical output.
- **Finiteness** — no NaN/Inf in any output pixel, across the frozen set + fuzz.
- **Performance baseline** — `EMBERWEFT_PERF=1` records a single-frame CPU/Metal timing baseline at 720p/1080p and the speedup ratio. Non-gating; a regression guard. (`PerformanceBaselineTests`)

### 4a. Animated-frame parity (M3)

The M3 animation pipeline extends the still-frame gates (§2 golden, §3 parity) to
motion. Two test targets split by Metal dependency, mirroring the still split:

- **`AnimationParityTests`** (CPU/vs-flam3 rows — `[FlameReference, FlameKit]`
  only, no Metal) — drives `Loop`/`Transition`/`GenomeInterpolator`/`Schedule`/
  `SpecialSauce` through `ReferenceRenderer` and compares to the `flam3-genome` /
  `flam3-animate` oracle (§2a). vs-flam3 rows call `try Flam3Oracle.require()`
  first (F10 auto-skip when the build is absent — **skip-or-pass, never a
  failure**). Target: **vs-flam3 ≥ 30 dB** across loops and transition interiors;
  measured **43–58 dB**. Also: loop seamlessness (genome-space `‖Δ‖` bounded —
  rotation-only, so coefficients line up 1:1), and finiteness of every animated
  `Flame` (a NaN in `Loop`/`Transition` output would poison the whole render).
- **`AnimatedFrameParityTests`** (Metal-touching rows — `[FlameRenderer]`) —
  renders animated frames through `MetalRenderer` and checks:
  - **Metal ↔ CPU ≥ 38 dB** on animated frames, including a **mismatched
    transition pair** (differing xform count **and** special-sauce variation set,
    so `SpecialSauce.align` padding and multiple Metal variation slots exercise
    together).
  - **Continuity ≥ 40 dB** between consecutive transition frames (no pops) — a
    gentle, non-chaotic pair isolates morph smoothness.
  - **G2 determinism** — the full animated sequence is byte-deterministic across
    repeated runs (both backends).
  - **Finiteness** — no NaN/Inf in any animated output pixel.

**`hsv_rgb_palette_blend`** — transitions exercise the HSV-circular palette mix
(`PaletteBlend.blend` with the genome's `hsvRgbPaletteBlend` as the RGB/HSV mix
fraction + linear `hue_rotation` interpolation). Loops keep the palette **static**
(the rotation is affine-only), so palette motion is transitions-only — verified
by the loop-seamlessness genome-space gate (no palette delta) and the vs-flam3
transition-interior rows (which depend on the HSV blend matching flam3).

### 5. Property / invariant tests
QuickCheck-style randomized checks over generated genomes:

- Output is finite everywhere (no NaN/Inf pixels).
- Alpha/density is non-negative and bounded.
- Camera transforms keep the attractor within frame for well-formed genomes.
- The parser accepts all valid `.flam3` samples and rejects all mutations that break the schema.
- Same seed → byte-identical frame across runs, within a backend (determinism).

### 6. Performance / benchmark tests
Regression guards, not absolute gates (see [performance.md](performance.md)).

- Single-frame render time at 720p/1080p/4K on the reference machine (M2 Max).
- Iteration throughput (samples/sec) for CPU and Metal backends.
- Peak memory for the histogram + accumulators at each resolution.
- Realtime fps at target resolutions and quality tiers.
- The local pre-merge gate compares against stored baselines; regressions beyond ±N% *(preliminary: ±10%)* flag a failure for review. Enabled with `EMBERWEFT_PERF=1`; non-gating.

### 6a. Realtime capability gate (M3)

`Tests/FlamePlayerTests/RealtimeCapabilityTests.swift` — an `EMBERWEFT_PERF=1`-gated, 30 s sustained-fps proof of the M3 animation pipeline (PlaybackDispatcher + AdaptiveQualityController + MetalRenderer). SKIPS cleanly when `EMBERWEFT_PERF != 1`, when Metal is unavailable, or when the sandbox blocks device creation. Run in **release** (`EMBERWEFT_PERF=1 swift test -c release --filter RealtimeCapabilityTests`) with the bash sandbox DISABLED — a debug build's unoptimized host pipeline is ~30× slower and not representative.

Method (honest measurement): the PlaybackDispatcher is driven batch-by-batch against an **injected pacing clock** (the Task-20 fake-clock *injection* pattern — no `CAMetalLayer` vsync, no window, no drawable) that sleeps in real wall time to the 60 fps deadline. Every frame is rendered via the REAL offscreen `MetalRenderer.render` (no fake renderer), so the measured fps reflects actual GPU cost. The measured batch fps is fed into the pure `AdaptiveQualityController`, whose output `samplesPerPixel` becomes the next batch's `RenderParams` — so the adaptive loop is genuinely live. Per-frame wall timestamps are sampled in the sink; p50/p95 of the instantaneous sustained fps are computed and printed.

**Ownership split (load-bearing — what M3 owns vs. what it does NOT):**

- **M3 OWNS** the harness, the dispatcher, the adaptive controller, and the proof that the PIPELINE is realtime-capable where the GPU frame cost permits. This is demonstrated at **720p, where the engine sustains p50 ≈ 60 fps** (budget held in [2, 4] samplesPerPixel, no transition-frame freeze).
- **M3 owns the 1080p capability floor (≥ 58 fps) — now MET**, after the histogram-fusion optimization fused the three Metal stages into one command buffer with a GPU-resident histogram (previously the histogram CPU-round-tripped between stages, a fixed ~25 ms 1080p cost that budget tuning could not close). The gate holds with a **thin margin**: 1080p p50 ≈ 58.7–59 fps, with the adaptive controller shedding to a low quality budget (2–4 `samplesPerPixel`). `samplesPerPixel` is the adaptive lever; it is correctly exercised, but at 1080p the engine is budget-constrained to the low end of its range to hold the floor.
- **M4 OWNS** (a) the hard 60 fps-under-real-UI-load gate (compositing / window / drawable load), which is not present in M3, and (b) **visual quality at target fps** — the M3 gate is a capability floor, not a quality target; the thin 1080p margin means image quality at 58–59 fps is deliberately low (2–4 spp) and is an M4 concern.

**Recorded baseline (M2 Max, release, nominal thermal, paced to 60 fps):**

| Resolution | Duration | p50 fps | p95 fps | adaptive budget (spp) | transition freeze | gate |
|---|---|---|---|---|---|---|
| 1280×720  | 8 s  | ≈ 60   | ≈ 64   | 2…4 | none | **PASS** (≥ 58) |
| 1920×1080 | 30 s | ≈ 58.7–59 | ≈ 59 | 2…4 | none | **PASS** (≥ 58, thin margin — low quality budget) |

The 1080p row moved above 58 fps after the histogram-fusion optimization landed;
the 58 floor was **NOT lowered**. The margin is thin and the adaptive budget
sits at its low end (2–4 spp), so absolute image quality at target fps is
deferred to M4.

**Thermal sensitivity (re-witnessed 2026-07-19):** because the margin is ~0.3 fps
above the floor, the 1080p gate is sensitive to GPU thermal/load at test time.
On a cool, quiet machine the 1080p p50 measures ≈ 58.3 fps (PASS). Run
immediately after sustained GPU work (e.g. a long `animate` render), the same
machine dipped to **57.96 fps — just under the floor** — and failed, with no
code change. The capability is real but the gate is borderline on this (M2 Max)
hardware: run `make test-perf` on a thermally nominal machine, and treat a
sub-58 result under load as environmental, not a regression.

### 7. CLI snapshot tests
End-to-end checks through the `emberweft` executable:

- `emberweft render` on frozen genomes produces byte-stable PNGs (after gamma/palette fix-up) committed to the repo; any change fails the local pre-merge gate until reviewed.
- `emberweft validate` / `info` exit codes and stdout are snapshot-tested.
- `--backend cpu` and `--backend metal` produce parity-equivalent output; `--list-backends` reports availability.

### 8. Integration / smoke tests (later slices)
- Playback engine produces frames at target fps without drops under sustained load.
- Export writes a valid, decodable container with correct duration/codec.
- Screensaver bundle launches, renders, and respects low-power/thermal state.

## Local pre-merge gate

The source of truth for merge readiness is the **local gate run on a developer machine**. GitHub is a plain git mirror; no CI workflow runs. Before merging any PR to `main`, run:

1. `swift build` and `swift build -c release` — both must succeed.
2. `swift test` — the full suite: unit + property + golden (`FlameReference` vs committed flam3 goldens) + Metal↔CPU parity (all per-stage gates in section 4) + finiteness + determinism. Run with the bash sandbox **disabled** (the Metal device needs it).
3. `EMBERWEFT_PERF=1 swift test` — records the perf baseline (non-gating; a regression reference).
4. `swift-format lint` — formatting and lint must be clean.

`main` is always green. Golden-regression failures include a documented re-golden procedure (`Tools/regen_goldens.sh`) so they are resolved deliberately, not by force-updating.

### Fast path & opt-in gates (Makefile)

The `swift test` gate is correct but heavy (~12 min: the vs-flam3 rows spawn `flam3-animate` PNG sequences and the Metal↔CPU rows render at high `samplesPerPixel`). The `Makefile` splits it so a skip is never mistaken for a pass:

| Target | Runs | Wall-clock | Opt-in? |
|---|---|---|---|
| `make test-fast` | FlameKitTests + EmberweftCLITests + FlamePlayerTests (mechanics, CLI, engine units) | ~2 s | no |
| `make test-parity` | FlameReferenceTests + FlameRendererTests (vs-flam3 + Metal↔CPU parity) | ~12 min | needs flam3 on `$PATH` for the vs-flam3 rows (else they **silently `XCTSkip`**) |
| `make test-perf` | RealtimeCapabilityTests (≥58 fps @1080p capability gate) | ~1 min | **`EMBERWEFT_PERF=1`**, release build, sandbox OFF |
| `make test` | fast + parity (everything but perf) | ~12 min | no |

**Two gates are opt-in and silently skip otherwise** — do not read a green `swift test` as having exercised them: (1) the **realtime fps gate** (`test-perf`; skips unless `EMBERWEFT_PERF=1`), and (2) the **vs-flam3 parity rows** (skip unless the oracle is on `$PATH`). The Metal↔CPU parity (≥38 dB) is the one gate that always runs when a Metal device is reachable.

## Thresholds

| Metric | Threshold |
|---|---|
| `FlameReference` vs `flam3` golden | PSNR ≥ 30 dB, SSIM ≥ 0.95 |
| Real ES genomes vs `flam3` (v0.1.0, `RealGenomeParityTests`) | PSNR ≥ 38 dB (measured 49–52 dB across 7 gen-248 fixtures) |
| Metal vs CPU parity (end-to-end) | PSNR ≥ 38 dB, SSIM ≥ 0.95 |
| Metal Stage-3a vs CPU ToneMapping (same histogram) | PSNR ≥ 50 dB (byte-exact, `inf` in practice) |
| Metal determinism | byte-identical across repeated runs |
| Metal per-stage histogram | count correlation > 0.999 |
| Perf regression | within ±10% of baseline (non-gating) |
| Realtime capability (M3 gate, §6a) | median sustained fps ≥ 58; **MET at 720p (p50 ≈ 60) and 1080p (p50 ≈ 58.7–59, thin margin, low quality budget 2–4 spp — after the histogram-fusion optimization; floor NOT lowered)** |
| Realtime target (post-optimization) | 60 fps @ 1080p, 30 fps @ 4K (M2 Max) |
| Animated-frame vs-flam3 (§4a) | PSNR ≥ 30 dB (skip-or-pass; measured 43–58 dB) |
| Animated-frame Metal↔CPU (§4a) | PSNR ≥ 38 dB (incl. mismatched transition) |
| Animated-frame continuity (§4a) | consecutive-frame PSNR ≥ 40 dB |
| Animated-frame determinism (§4a) | byte-identical across runs (both backends) |

The Metal↔CPU thresholds reflect the statistical parity model: the two backends are independently deterministic but not byte-identical (different atomic-accumulation order, different per-thread sample split). The Stage-3a gate is tight because it runs both display pipelines on the *same* histogram, eliminating chaos-game divergence.
