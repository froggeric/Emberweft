# Testing

*Test methodology, oracles, and quality gates for Emberweft.*

> **Status:** preliminary — for review · Emberweft

Companion to [development-approach.md](development-approach.md) and [performance.md](performance.md). Emberweft is developed test-first; the tests described here are written *before* the code that satisfies them.

## Testing philosophy

- **Oracle-validated.** Correctness is measured against an independent reference — the dev-only `flam3` renderer for the CPU path, and the CPU path for the Metal path.
- **Determinism is non-negotiable.** Same genome + seed + params → identical frame, whether rendered offline or in realtime. Most tests exploit this.
- **Layered tests.** Fast, pure unit tests run constantly; expensive image/parity tests run in CI; benchmarks run as regression guards.
- **No silent re-goldening.** When a golden reference must change, it is a deliberate, reviewed action with a recorded reason — never a side-effect of a refactor.

## Test layers

### 1. Unit tests (pure, fast)
XCTest, run on every save and in CI.

- **Genome model & parser:** `.flam3` parse → serialize round-trip equality; known-genome field extraction; default-filling for missing attributes; rejection of malformed XML and degenerate transforms (NaN/Inf coefficients, non-finite weights).
- **Interpolation:** temporal interpolation between two genomes (coefficients, variation weights, color index, opacity, camera center/scale-in-log-space); boundary cases (different transform counts, missing final xform).
- **Variation functions:** each variation (sinusoidal, spherical, swirl, horseshoe, …) tested with known (x,y) inputs → expected outputs, including NaN/Inf guards.
- **Affine/transform math:** coefficient application, post-transforms, variation composition.
- **RNG:** deterministic output for a fixed seed; distinct streams per thread index.

### 2. Golden-image tests (correctness oracle)
The correctness backbone for `FlameReference` (and transitively for the algorithm).

- **Frozen genome set.** A curated, versioned set of ~12 `.flam3` genomes covering: a few transforms, many transforms, final xforms, edge-heavy and detail-heavy attractors, varied palettes. Lives under `Tests/Goldens/genomes/`.
- **Golden generation.** A checked-in script renders each frozen genome with dev-only `flam3` (Homebrew) at a fixed size/quality and stores the result under `Tests/Goldens/reference/`. `flam3` is **never** linked into or distributed with Emberweft (see [license-and-attribution.md](../license-and-attribution.md)).
- **Comparison.** `FlameReference` renders the same genomes; output is compared to the goldens by **PSNR ≥ threshold** and **SSIM ≥ threshold** *(preliminary: PSNR ≥ 30 dB, SSIM ≥ 0.95 — to be tuned after first parity runs)*. Near-exact match is not expected (different RNG/filter implementations), so thresholds are statistical.
- **Re-goldening.** A dedicated, review-required workflow; CI fails loudly on unexpected golden drift.

### 3. Parity tests (Metal ↔ CPU)
Validate that `FlameRenderer` (Metal) matches `FlameReference` (CPU) on identical inputs.

- Same genome + seed + size + quality → compare outputs.
- **Statistical checks:** histogram L1 distance, per-channel color moments, output-energy ratio — robust to GPU atomics/ordering nondeterminism.
- **PSNR** between CPU and Metal frames, with a threshold tighter than the flam3 oracle (same algorithm, different implementation) *(preliminary)*.
- Run across the frozen genome set plus randomized fuzz genomes.

### 4. Property / invariant tests
QuickCheck-style randomized checks over generated genomes:

- Output is finite everywhere (no NaN/Inf pixels).
- Alpha/density is non-negative and bounded.
- Camera transforms keep the attractor within frame for well-formed genomes.
- The parser accepts all valid `.flam3` samples and rejects all mutations that break the schema.
- Same seed → byte-identical frame across runs (determinism).

### 5. Performance / benchmark tests
Regression guards, not absolute gates (see [performance.md](performance.md)).

- Single-frame render time at 720p/1080p/4K on the reference machine (M2 Max).
- Iteration throughput (samples/sec) for CPU and Metal backends.
- Peak memory for the histogram + accumulators at each resolution.
- Realtime fps at target resolutions and quality tiers.
- CI compares against stored baselines; regressions beyond ±N% *(preliminary: ±10%)* flag a failure for review.

### 6. CLI snapshot tests
End-to-end checks through the `emberweft` executable:

- `emberweft render` on frozen genomes produces byte-stable PNGs (after gamma/palette fix-up) committed to the repo; any change fails CI until reviewed.
- `emberweft validate` / `info` exit codes and stdout are snapshot-tested.
- `--backend cpu` and `--backend metal` produce parity-equivalent output.

### 7. Integration / smoke tests (later slices)
- Playback engine produces frames at target fps without drops under sustained load.
- Export writes a valid, decodable container with correct duration/codec.
- Screensaver bundle launches, renders, and respects low-power/thermal state.

## CI gates

Every PR must pass on a macOS runner:

1. `swift build` (debug + release)
2. Unit + property tests
3. Golden-image tests (vs committed goldens)
4. Parity tests (Metal ↔ CPU)
5. Performance-bench regression check
6. `swift-format` lint (and format check)
7. CLI snapshot tests

`main` is always green. Golden-regression failures include a documented re-golden procedure so they are resolved deliberately, not by force-updating.

## Thresholds (all preliminary — tuned after first parity data)

| Metric | Preliminary threshold |
|---|---|
| `FlameReference` vs `flam3` golden | PSNR ≥ 30 dB, SSIM ≥ 0.95 |
| Metal vs CPU parity | PSNR ≥ 38 dB (tighter) |
| Perf regression | within ±10% of baseline |
| Realtime target | 60 fps @ 1080p, 30 fps @ 4K (M2 Max) |

These numbers are starting points, not decisions; they will be revised once real CPU/flam3/Metal comparison data exists.
