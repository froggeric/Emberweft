# Changelog

All notable changes to Emberweft are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Emberweft is **source-available** (PolyForm Noncommercial). The CPU renderer is a
faithful Swift port of the flam3 algorithm; the final license (including any GPL
implications of porting flam3) is the owner's decision and under review.

## [M2] — Metal Renderer (Faithful Twin)

A Metal-compute renderer (`FlameRenderer`) that is a faithful statistical twin of
the CPU reference: same affine convention, variation formulas, ISAAC RNG +
consumption order, density-estimation filter, and display pipeline. Exposed via
`emberweft render --backend cpu|metal` and `--list-backends`. The production path
depends on **FlameKit only** (shared types lifted out of `FlameReference`).

### Faithful Metal twin
Three MSL kernels (`chaosGame`, `densityEstimate`, `logDensity` + `displayPipeline`)
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
