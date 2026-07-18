# Changelog

All notable changes to Emberweft are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Emberweft is **source-available** (PolyForm Noncommercial). The CPU renderer is a
faithful Swift port of the flam3 algorithm; the final license (including any GPL
implications of porting flam3) is the owner's decision and under review.

## [M3] — Animation and Realtime Pipeline

Faithful flam3 animation (loops + transitions) rendered through a realtime Metal
playback engine. Loops and transitions alternate endlessly — the Electric Sheep
sequence — driven by a pure `Schedule` timeline, a `PlaybackDispatcher` actor,
and an `AdaptiveQualityController`. Exposed via `emberweft animate` (PNG sequence
+ `manifest.json`) and the `FlameUI` Metal-layer view. Two slice prerequisites
landed first: a widened genome model with the 16 special-sauce variations on
both CPU and Metal, and a histogram-fusion perf optimization that recovers the
1080p realtime floor.

### S6-pre — widened genome model + 16 special-sauce variations
`Variation`/`Xform`/`Flame` widened to carry per-variation parameters, animation
attributes (`animate`, `padding`, `interpolationType`, `paletteInterpolation`,
`hsvRgbPaletteBlend`, `stagger`, `hueRotation`), and a `VariationDescriptor`
registry of parameter schemas + special-sauce rest positions. The 16
special-sauce variations (`spherical`, `ngon`, `julian`, `juliascope`, `polar`,
`wedge_sph`, `wedge_julia`, `rect`, `rings2`, `fan2`, `blob`, `supershape`,
`curl`, `perspective`, `fan`, `rings`) were ported to **both** CPU
(`FlameReference`) and Metal (MSL), with a 33-slot canonical `GPUXform` table +
flat-packed param channel. Per-variation parity (additivity oracle) verified
against the pre-S6-pre Metal baseline hashes.

### S6 — FlameKit animation math + `animate` CLI
A faithful port of flam3's `sheep_loop` / `sheep_edge` / `flam3_interpolate`:

- **`Loop.blend`** — `sheep_loop`: pure 360° pre-affine rotation `R(θ)·M`
  (θ = `t·2π`) of each animating, non-final xform. **Palette is static during a
  loop** (seamless because `R(360°)=R(0°)` within FP residual; not a palette
  wrap). Translation, post-affine, and camera untouched.
- **`Transition.blend`** — `sheep_edge`: `SpecialSauce.align` (pad to equal xform
  count + per-variation rest positions) → `RefAngles.establish` (wind anchors) →
  rotate **both** endpoints by `t·360°` → `GenomeInterpolator.interpolate`
  (`.log` polar matrix blend + per-xform `stagger`) → `PaletteBlend` (HSV-circular
  palette mix via `hsv_rgb_palette_blend` + linear `hue_rotation`).
- **`GenomeInterpolator`** — `.linear` (byte-identical to the legacy path) and
  `.log` (polar decomposition: wind-anchored angle unwrap, per-column magnitude
  guard, zero-column angle copy). `stagger` desynchronizes per-xform timing.
- **`Schedule`** — a pure `Sendable` value-type timeline: O(1) global-frame →
  `(segmentId, kind, blend)`, O(1) amortized `segmentId → Segment`. Strict
  loop/transition alternation by segment-id parity (transitions only occupy odd
  ids → "no two transitions consecutive" holds by construction). Blend is
  1-indexed in `(0, 1]` — never 0 — so consecutive segments tile with no
  duplicate boundary frame.
- **`PairSelector`** — `Sequential` (deterministic cyclic walk) and
  `SimilarityExploration` (ε-greedy similarity-biased jumps with escapes, over a
  sorted-array `FeatureVector` — F1 bit-reproducible across launches).
- **`emberweft animate`** — renders a PNG sequence (`frames/000000.png …`) plus a
  `manifest.json` (per-segment/per-frame metadata). Flags: `--frames`,
  `--segments`, `--selector sequential|similarity`, `--seed`, `--stagger`,
  `--backend cpu|metal`, `--out`, `--library`, `--size`, `--quality`,
  `--rebuild-cache`.

### S7 — realtime engine
- **`PlaybackDispatcher`** — an actor-isolated driver that advances a `Schedule`
  one global frame at a time, hands the interpolated `Flame` to an injected
  `Renderer`, paces to a target fps via an injected `PlaybackClock`, and
  **prefetches the next sheep mid-loop** so the transition's first frame is
  ready. Triple-buffered `MTLTexture` rotation lives behind the production
  `Renderer` conformer (on the MainActor); the dispatcher itself is Metal-free
  and fully testable with fakes. Swift 6 isolation throughout — no
  `nonisolated(unsafe)`.
- **`AdaptiveQualityController`** — a **pure** value type mapping
  `(measuredFps, thermalState, currentBudget)` to a new `samplesPerPixel` via
  hysteretic feedback (±3 fps deadband, halve on underperformance, double on
  headroom). No hidden state; identical inputs always yield identical output.
  `.critical` thermal forces a floor regardless of fps.
- **`FlameUI`** — a `@MainActor` `NSView` backed by `CAMetalLayer` that conforms
  to the dispatcher's `FrameSink` protocol and drives vsync-paced presentation.

### Histogram-fusion performance optimization
The three Metal stages (chaos-game → density-estimation → display) were fused
into one command buffer with a **GPU-resident histogram** (previously the
histogram CPU-round-tripped between stages, a fixed ~25 ms 1080p cost that
budget tuning could not close). This recovers the 1080p realtime floor — see the
baseline below.

### Realtime capability baseline (M2 Max, release, nominal thermal, paced to 60 fps)

| Resolution | Duration | p50 fps | p95 fps | adaptive budget (spp) | gate |
|---|---|---|---|---|---|
| 1280×720  | 8 s  | ≈ 60   | ≈ 64   | 2…4 | **PASS** (≥ 58) |
| 1920×1080 | 30 s | ≈ 58.7–59 | ≈ 59 | 2…4 | **PASS** (≥ 58, thin margin) |

The gate (median sustained fps ≥ 58) **holds at 1080p after the histogram-fusion
optimization**, but with a thin margin: the adaptive controller sheds to a low
quality budget (2–4 `samplesPerPixel`) to fit the 60 fps deadline. Absolute
image quality at target fps is an **M4 concern** — the M3 gate is a capability
floor, not a quality target. The hard 60 fps-under-real-UI-load gate (window /
compositing / drawable load) is also M4's.

### Animation parity
- **vs-flam3** (`flam3-genome`/`flam3-animate` oracle, motion blur OFF):
  **43–58 dB PSNR** across loops and transition interiors (skip-or-pass — F10
  auto-skips when the dev-only oracle build is absent; never a failure).
- **Metal ↔ CPU** on animated frames (incl. a mismatched transition pair —
  differing xform count **and** special-sauce variation set, exercising
  `SpecialSauce.align` padding + multiple Metal variation slots): **≥ 38 dB**.
- **Continuity** — consecutive transition frames: **≥ 40 dB** (no pops).
- **G2 determinism** — full animated sequence byte-deterministic across runs
  (both backends); `manifest.json` byte-stable (declaration-order keys,
  index-ordered array).
- `hsv_rgb_palette_blend` exercises the HSV-circular palette mix on transitions
  (loops keep the palette static).

## [M2] — Metal Renderer (Faithful Twin)

A Metal-compute renderer (`FlameRenderer`) that is a faithful statistical twin of
the CPU reference: same affine convention, variation formulas, ISAAC RNG +
consumption order, density-estimation filter, and display pipeline. Exposed via
`emberweft render --backend cpu|metal` and `--list-backends`. The production path
depends on **FlameKit only** (shared types lifted out of `FlameReference`).

### Faithful Metal twin
Four MSL kernels (`chaosGame`, `densityEstimation`, `logDensity`, `displayPipeline`)
port the CPU stages field-for-field. The RNG is a **faithful MSL port of flam3
ISAAC**, byte-equal to the Swift `FlameKit.ISAAC` for identical seeds, seeded
per-thread via flam3's parent→child mechanism. Thread geometry is **pinned from
params** (not device caps), so Metal output is byte-identical across machines.
The histogram uses a **`uint32` fixed-point atomic encoding**
(`colorScale = 2^31 / (T·255)`): deterministic, overflow-safe, and M1+-compatible.

### Statistical parity (production path, 320×200, seed 0, oversample 1, 1000 spp)
| Genome | PSNR (dB) | SSIM |
|---|---|---|
| `final_warp` | 59.80 | 1.0000 |
| `swirl_field` | 52.84 | 0.9999 |
| `sierpinski` | 50.59 | 1.0000 |
| `rich` | 43.53 | 0.9921 |
| `heart_disc` | 41.72 | 0.9771 |
| `julia_bubbles` | 39.04 | 0.9533 |
| fuzz (julia+spherical) | 40.78 | 0.9947 |

- Stage-1 histogram: per-bin `count` correlation > 0.999 on all six goldens.
- Stage-3a (Metal display vs CPU `ToneMapping`, **same histogram**): `inf` dB —
  byte-exact. Isolates the display path from chaos-game divergence.
- Determinism: byte-identical Metal output across repeated runs.
- Finiteness: no NaN/Inf in any output pixel across the frozen set + fuzz.

### Performance baseline
`EMBERWEFT_PERF=1`, 100 spp, oversample 1. Single-frame Metal speedup vs CPU:

- **1080p:** 11.62× (`sierpinski`) … 17.82× (`final_warp`). Representative:
  `final_warp` CPU 169.51 s → Metal 9.51 s.
- **720p:** same 11.6×–17.8× band.

### CLI
- `--backend cpu|metal` selects the backend (Metal falls back to CPU when
  `MetalRenderer.isAvailable` is false).
- `--list-backends` reports backend availability.

### Infrastructure
- **Shared types lifted to FlameKit** (`RenderParams`, `Histogram`, `RGBA8Image`,
  spatial-filter helpers, `buildDmap`, `Flam3XformDistrib`) so `FlameRenderer`
  depends on `FlameKit` only — `FlameReference` remains the parity oracle but is
  no longer a build dependency of the production Metal path.
- **GitHub Actions workflow removed** (`.github/workflows/ci.yml`). GitHub is a
  plain git mirror; the **local pre-merge gate** (`swift build` debug + release,
  full `swift test`, optional `EMBERWEFT_PERF=1` baseline, `swift-format` lint)
  is the source of truth. Run with the bash sandbox disabled (Metal device).
- Tests: the parity gate is decomposed into per-stage checks (MSL ISAAC
  byte-equality, histogram correlation, Stage-3a byte-exactness, end-to-end
  PSNR/SSIM, determinism, finiteness) plus a test-only **Stage-3b on-ramp**
  (Metal chaos → CPU tone-map) retained as a parity-bisect debug tool.

### Known limitation — precision floor
The `uint32` fixed-point atomic encoding has a precision floor tied to total
sample count T. Mathematically ill-posed genomes whose orbit hits a variation's
`1/r²`-type singularity (e.g. `spherical` at the origin) can produce
unbounded-density bins that saturate this floor — observable as sub-threshold
PSNR that does **not** improve with more samples. Real flam3 genomes (and all
six frozen goldens) are well-posed and unaffected. This is a documented tradeoff
of the M1+-compatible `uint32` encoding, not a renderer bug; 64-bit atomics
(which would raise the floor) require Apple8/M2+ and were rejected as violating
the M1+ deployment target.

## [M1] — CPU Reference Renderer + CLI

A correct, deterministic CPU fractal-flame renderer that parses `.flam3`, renders
a still PNG, and is validated against the dev-only `flam3` oracle — exposed
through an `emberweft render|validate|info` CLI. The CPU reference is the oracle
against which the M2 Metal renderer will be validated (Reference-then-Optimize).

### Faithful flam3 port
The CPU reference is a **faithful Swift port of flam3's algorithms** (not an
approximation), achieving near-byte-exact parity: **51–72 dB PSNR, SSIM ≈ 1.0**
on all 6 frozen golden genomes, against single-threaded strict-IEEE `flam3`.
Ported: affine convention (`tx=a·x+c·y+e`, `ty=b·x+d·y+f`), the full classic
variation set with flam3's `precalc_atan = atan2(x,y)`, the **ISAAC RNG** (byte-exact
vs flam3's `isaac.c`) with its exact chaos-game consumption order, and the complete
display pipeline (log-density k1/k2, Gaussian spatial filter, `calcAlpha`/`calcNewRGB`,
gamma/vibrancy/background). All renderer math is in `Double` to match flam3 precision.

### Added
- **FlameKit** — genome value model (`AffineTransform`, `Xform`, `Flame`, `Palette`,
  `Camera`, `Quality`); `.flam3` XML parser (both Apophysis `<color>` and flam3
  hex-block palettes) and canonical serializer with round-trip equality; temporal
  interpolation (log-space scale, endpoint-correct size/quality); the classic
  variation registry; deterministic **PCG32** and faithful **ISAAC** RNGs.
- **FlameReference** — single-threaded deterministic chaos-game engine → histogram →
  density-estimation filter → log-density/palette/gamma tone-mapping → RGBA8;
  `ReferenceRenderer.render(flame:params:)`; PNG I/O via ImageIO (sRGB, opaque).
- **`emberweft` CLI** — testable `EmberweftCLI` library + thin `EmberweftApp`
  executable; `render`/`validate`/`info`/`--version`, CPU backend, exit codes.
- **Golden oracle harness** — 6 frozen genomes; `Tools/regen_goldens.sh` invoking
  the dev-only `flam3` oracle with pinned `seed`/`isaac_seed`/`nthreads=1`
  (single-threaded, byte-reproducible); committed reference PNGs; PSNR/SSIM parity
  gate (`GoldenParityTests`) that passes without `flam3` installed in CI.
- **Tests** — 61 tests: unit (genome, RNG, variations, parser, serializer,
  interpolation), chaos-game (determinism, budget, finiteness, termination),
  tone-mapping/density, PNG round-trip + orientation, property tests, golden
  parity, CLI behavior, and a byte-stable CLI PNG snapshot.

### Fixed (parity oracle findings)
- **Affine convention** — was `x'=a·x+b·y+c`; correct is `tx=a·x+c·y+e`,
  `ty=b·x+d·y+f` (verified against `flam3` `parser.c`/`variations.c`).
- **Variation angle source** — flam3's basic variations use `precalc_atan = atan2(x,y)`,
  not `atan2(y,x)`.
- **Final-xform feedback** — the final xform must transform a separate binning
  point, not feed back into the chaos-game trajectory (`flam3.c:246-296`).
- **Golden harness `nthreads`** — goldens must render `nthreads=1`; flam3's default
  multi-threaded render is a non-reproducible, machine-dependent sample split that a
  single-threaded reference cannot match. (Root cause of the apparent "julia parity
  gap" — Emberweft was byte-correct throughout.)

### Notes
- `flam3` remains a **dev-only external oracle** — built from source outside the
  repo, invoked only by `Tools/regen_goldens.sh`; never linked, bundled, copied,
  or distributed. CI runs the parity gate against committed PNGs without `flam3`.
- Density estimation is the M1 approximation (frozen goldens set
  `estimator_radius="0"`, so it is not exercised by the parity gate); the true
  flam3 estimator is deferred until non-zero-radius goldens are added.

## [M0] — Docs + Repo Scaffold

Project foundation: documentation set, repository structure, `Package.swift`
module targets (FlameKit/FlameReference/FlameRenderer/FlamePlayer/FlameExport +
`emberweft` executable), PolyForm-NC license, CI workflow, `swift-format` config.
