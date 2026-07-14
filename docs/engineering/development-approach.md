# Development Approach

*How Emberweft is built: methodology, build order, GPU strategy, and testing.*

> **Status:** preliminary — for review · Emberweft

This document is the agreed development strategy. It governs *how* the project is implemented; the [roadmap](roadmap.md) governs *what* ships when; [architecture.md](../architecture.md) describes the runtime structure; [testing.md](testing.md) details the test methodology referenced below.

## Principles

1. **Correctness is the foundation.** The renderer is validated against an independent oracle before it is trusted.
2. **Reference-then-Optimize.** A portable CPU reference renderer is built and proven first; the Metal renderer is then validated against it.
3. **CLI-first.** A headless `emberweft` executable ships before any UI, forcing a clean engine/UI boundary and enabling CI-driven image tests.
4. **Test-driven.** Every slice starts with a failing test (the golden/parity tests *are* the "red" for the renderers).
5. **Source-available, not open source.** PolyForm Noncommercial code + CC-BY-NC seed library (see [license-and-attribution.md](../license-and-attribution.md)).
6. **YAGNI.** Editor UI, genetics, HDR, vertical presets, and flock import are deferred until the core renderer is solid.

## Methodology

- **TDD red-green-refactor** for all production code.
- **Small conventional commits** (`feat:`, `fix:`, `test:`, `docs:`, `refactor:`, `perf:`, `chore:`).
- **Branch-per-feature / branch-per-slice**, PRs required, `main` always green.
- **Code review** required on every PR before merge.
- **CI gates** every PR: build, unit tests, golden-image tests, parity tests, performance-bench check, and `swift-format` lint.
- **Determinism is mandatory.** Same genome + seed + params → identical frame, offline and realtime. This is a hard requirement, not a nice-to-have.

## Build order — vertical slices

Each slice is independently testable and shippable. Nothing proceeds until the previous slice is green.

| Slice | Deliverable | Oracle / validation |
|---|---|---|
| **S0** | Repo bootstrap: `git init`, `Package.swift` (module targets + `emberweft` exe), `LICENSE`/`LICENSE-SEEDS`, `CONTRIBUTING.md` (CLA note), `CLAUDE.md`, `swift-format` config, CI workflow, `justfile`/`Makefile`, `.gitignore`. Fix "open source"→"source-available" in docs. | CI builds an empty package. |
| **S1** | **`FlameKit`** — genome model, `.flam3` parse/serialize, validation, temporal interpolation. Pure Swift, no GPU. | Round-trip + property tests; parser-rejects-malformed. |
| **S2** | **`FlameReference`** — the CPU renderer: chaos game → histogram → log-density → density-estimation filter → palette/gamma. Permanent, shippable module. | Unit tests per variation function; bounded/no-NaN invariants. |
| **S3** | Golden-oracle harness: brew-install `flam3` (dev-only); frozen set of ~12 reference genomes; script renders goldens; tests compare `FlameReference` output by PSNR/SSIM. | `FlameReference` vs `flam3` goldens. |
| **S4** | **`emberweft` CLI (still)** — `emberweft render genome.flam3 -o out.png`, CPU backend. | CLI snapshot tests on frozen genomes. |
| **S5** | **`FlameRenderer` (Metal compute)** — port the algorithm; `--backend cpu\|metal`. | **Parity tests: Metal vs `FlameReference`** (statistical + PSNR). |
| **S6** | CLI animation — `emberweft animate` with genome transitions/morphs. | Animated-frame parity; transition continuity. |
| **S7** | **`FlamePlayer`** realtime adaptive engine + **`FlameUI`** Metal-layer wrapper. | Fps/throughput benchmarks; adaptive-quality tests. |
| **S8** | SwiftUI app + library browser. | UI snapshot/smoke tests. |
| **S9** | macOS screensaver bundle (`EmberweftScreenSaver`). | Launch + low-power tests. |
| **S10** | **`FlameExport`** — AVFoundation offline/long-form export, codecs. | Round-trip encode/decode; determinism. |
| **S11** | Music-video / audio-reactive (offline + realtime VJ). | Audio-feature + sync tests. |
| **S12** | 4K/HDR, vertical/social presets, local genetics/breeding. | Format coverage; HDR pipeline checks. |

S0–S6 are the **core**: a correct, oracle-validated, Metal-accelerated renderer with a CLI. Everything from S7 on is productization on top of that proven core.

## GPU acceleration — Metal compute (the decision)

Emberweft renders with **Metal compute shaders** (`MTLComputeCommandEncoder` + `.metal` kernels). The pipeline is three compute passes:

1. **Chaos-game / histogram accumulation.** GPU threads iterate the iterated-function-system, atomically accumulating (count + accumulated color) into a histogram buffer. Per-thread RNG is a fixed-seed PCG / wang-hash so output is deterministic.
2. **Density-estimation filter.** A compute kernel applies an adaptive kernel whose radius grows where samples are sparse and shrinks where they are dense — removing noise without blurring detail.
3. **Palette + log-density + gamma.** Maps the filtered histogram through the palette LUT, applies log-density alpha and tone-mapping/gamma, writes the output texture (half-float, HDR-capable).

### Why Metal compute, and not the alternatives

| Option | Verdict |
|---|---|
| **Metal compute** ✅ | Native to Apple Silicon; unified-memory zero-copy buffers; **atomic adds** for the histogram; threadgroup shared memory; half-float; Metal 4. The chaos game is data-parallel and divergent — a compute problem, not a rasterization one. |
| Metal Performance Shaders (MPS) | ❌ No flame primitives — irrelevant. |
| Core Image / fragment shaders | ❌ Wrong model; rasterization does not fit variable-iteration histogramming. |
| Accelerate / vDSP / SIMD | CPU-only — correct and useful **for `FlameReference`**, but cannot do realtime 4K. |
| BNNS / Apple Neural Engine | ❌ Neural-network workload, wrong shape entirely. |
| OpenCL | ❌ Deprecated/removed on macOS. |
| Vulkan / MoltenVK | ❌ An unnecessary translation layer; Metal is native. |

The CPU path (`FlameReference`) is kept as the **deterministic oracle and offline fallback**; the Metal path is the production realtime renderer. See [metal-pipeline.md](../rendering/metal-pipeline.md) for the detailed kernel design.

## The CPU reference renderer — a permanent module

`FlameReference` is **not throwaway**. It serves three permanent roles:

1. **Parity oracle** — the source of truth that `FlameRenderer` (Metal) is validated against in CI.
2. **Deterministic offline renderer** — used to verify export reproducibility and to render in environments without a usable GPU.
3. **Algorithm laboratory** — the easiest place to prototype and unit-test variations, filters, and interpolation, with per-function unit tests.

Maintaining two renderers is the cost; the payoff is that algorithm bugs and GPU bugs localize instantly (CPU-passes-flam3-but-Metal-doesn't ⇒ GPU bug; CPU-fails-flam3 ⇒ algorithm bug). This is how production renderers are built (reference path vs optimized path).

## CLI-first

The `emberweft` executable ships at S4, before any UI:

```
emberweft render  <genome.flam3> [-o out.png]  [--backend cpu|metal] [--quality N] [--size WxH] [--palette <name|file>] [--seed N]
emberweft animate <a.flam3> <b.flam3> [--frames N] [-o out] [--backend cpu|metal] ...
emberweft validate <genome.flam3>            # parse + lint, report issues
emberweft info <genome.flam3>                 # summarize transforms/variations/palette
```

Rationale: a CLI is **snapshot-testable in CI** (render frozen genomes → compare), **scriptable** for batch/library work, and forces the engine to be usable with no UI — so the SwiftUI app and the screensaver become trivial thin hosts over the same engine.

## Testing (summary)

Full detail in [testing.md](testing.md). In brief:

- **Unit (pure):** genome parse/serialize round-trip, interpolation math, every variation function, affine transforms.
- **Golden-image (correctness oracle):** frozen genome set; goldens generated by dev-only `flam3`; `FlameReference` must match within PSNR/SSIM thresholds. Re-goldening is an explicit, reviewed action.
- **Parity (Metal ↔ CPU):** statistical (histogram L1, color moments) + PSNR on identical inputs.
- **Property/invariant:** bounded output, no NaN/Inf, parser rejects malformed, RNG determinism.
- **Performance/benchmark:** fps/throughput/memory regression guards (±N%), feeding the adaptive quality controller.
- **CLI snapshots:** byte-stable PNG output on frozen genomes in CI.

## Quality infrastructure

- **CI:** GitHub Actions macOS runner — build + unit + golden + parity + bench + `swift-format` lint on every PR. `main` stays green. Golden regressions block merge with an explicit, documented re-golden path.
- **Formatting/linting:** Apple `swift-format` (format + lint). Pre-commit hook.
- **Profiling:** Xcode GPU capture, Instruments (Time Profiler, Metal System Trace, Energy Log).
- **Versioning:** semantic versioning + tags (once S5 ships a usable renderer).
- **CLA:** `CONTRIBUTING.md` notes that a Contributor License Agreement is required before the first external contribution (necessary under PolyForm-NC to preserve the maintainer's commercial option).

## Deferred (post-S6, YAGNI)

Flame editor UI · local genetics/breeding · HDR pipeline · vertical/social-format presets · Infinidream / Electric-Sheep flock import · multi-screen gallery · collaborative/social control.
