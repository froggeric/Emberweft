# Real-Genome Motion Blur + Density-Gap Parity — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Emberweft's offline render of real Electric Sheep genomes production-quality and relaxing (motion blur, fixing the transition→loop "jump") and close the real-genome vs-flam3 density-parity gap (≈20 dB → ≥38 dB).

**Architecture:** Motion blur is added as **density-domain temporal accumulation** — a faithful port of flam3's `temporal_samples` loop (`rect.c:754` + `filters.c:409`). For each output frame, run `N` chaos sub-passes at sub-times across a ±`temporal_filter_width/2` window. Each sub-pass builds its own dmap with `color_scalar = temporal_filter[i]` baked in (`rect.c:757`, `rect.c:778-782`), runs with `samplesPerPixel/N` of the total sample budget (`rect.c:833`), and accumulates **into one histogram** — colors+alpha weighted (via dmap), counts UNWEIGHTED (`rect.c:501-505`). Then density-estimate + tone-map **once**, with `k2`'s `sumfilt` factor set to `Σweights/N` returned by the temporal-filter builder (`filters.c:447`, `rect.c:937`). This is **cost-neutral** (total samples unchanged), **faithful** (every scalar matches flam3), and **CPU↔Metal consistent** (both backends use the same dmap-with-colorScalar mechanism). The density gap is fixed by diagnosing the chaos-game density distribution vs flam3 and correcting it, gated by a real-genome PSNR test.

**Tech Stack:** Swift 6 (Apple Silicon, Metal 4), SwiftPM, XCTest; the flam3 oracle (`flam3-render`/`flam3-genome`/`flam3-animate` on `$PATH` at `~/.local/bin`, source at `/tmp/flam3`/`/tmp/flam3-build`); ffmpeg for muxing.

**User decisions (already made):**
- "Motion blur is necessary to make it more relaxing" — implement it (render-time `temporal_samples`, NOT a video post-process).
- Scope = items #1–#3 (motion blur + production quality) and #5a (density gap). **#5b (pre-rendered video cache + realtime player) is deferred to a later plan.**
- Visual comparison uses the 4 real gen-248 genomes that have working IA official videos: **05739, 31943, 16636, 17549** (official loops in `/tmp/es_official/electricsheep.248.<id>.official.mp4`).
- "Slow meditative production" render-time cost is acceptable → **CPU path honors the genome's full `temporal_samples` (e.g. 1000), uncapped.** Metal caps at 64 to bound dispatch overhead (see Task 4).

---

## Background (read this first — the plan assumes it)

### What changed this week (real-genome rendering, on `main`)

Emberweft now **renders real ES genomes** after two fixes (both committed):
- **Palette parser** (`22efae49d`): real genomes use `<color index="i" rgb="r g b"/>` (DECIMAL, direct `<flame>` children); the parser had only read `<color>` inside `<palette>` as hex. Fixed + regression tests (`Tests/FlameKitTests/RealGenomePaletteTests.swift`, `Tests/FlameReferenceTests/RealGenomeRenderTests.swift`) + 5 real-genome fixtures at `Tests/Goldens/genomes_real/`.
- **Brightness** (`8a7fa2e9b`): `Quality.brightness` was hardcoded to 4.0; real genomes carry up to ~81. Now parsed + wired into CPU `ToneMapping` + Metal `renderFused` + unfused display. Goldens unchanged (GoldenParity 51–72 dB).

### Current state on real genomes (measured 2026-07-19/20)

- Real gen-248 genomes render non-black across a diverse survey (60–99% coverage).
- vs-flam3 parity on `00256` (matched params, q500): **PSNR ≈ 20 dB**. Structure/framing are **correct** (identical full-frame bbox; centroids flam3 395,304 vs Emberweft 370,329; mean channel matches 114 vs 108). Gap is the **density tail**: Emberweft is peakier (78.5% vs 93.5% pixels above threshold, same total light).
- **Ruled out as the density cause:** density estimation (`estimator_radius=0` → still 20 dB); `PREFILTER_WHITE` (`#define PREFILTER_WHITE 255` in flam3 `private.h:46` — a constant, so Emberweft's hardcoded 255 is correct); brightness (fixed).
- **The transition→loop "jump"** is NOT a structural bug — consecutive-frame PSNR at the boundary is 14.4 dB vs 15.7 dB within-loop (only ~1 dB worse). The perceived jump is the **uncorrelated Monte-Carlo noise changing abruptly at the genome switch**, which motion blur hides. Confirmed by measuring boundary PSNR with ffmpeg.

### The faithful flam3 motion-blur mechanism (READ THIS — every step below assumes it)

Verified end-to-end against `/tmp/flam3` source. **This is the algorithm being ported; do not deviate.**

**1. `flam3_create_temporal_filter` (`filters.c:409-450`)** — returns TWO arrays + a scalar:

```c
// deltas: evenly spaced across [-width/2, +width/2], centered (numsteps > 1)
deltas[i] = ((double)i / (double)(numsteps - 1) - 0.5) * filter_width;

// filter: UN-NORMALIZED weights (NOT normalized to sum 1!)
if (box)         filter[i] = 1.0;                                       // each literally 1.0
if (gaussian)    filter[i] = flam3_spatial_filter(gaussian,             // the SPATIAL filter fn
                             support * |i - halfsteps| / halfsteps);
if (exp)         filter[i] = pow(slpx, |filter_exp|);

// Then: divide every weight by `maxfilt` (so the max becomes 1.0).
//       Return sumfilt = (Σ adjusted weights) / numsteps.
for (i…) { filter[i] /= maxfilt; sumfilt += filter[i]; }
sumfilt /= numsteps;
```

**For `numsteps == 1`: `deltas[0]=0`, `filter[0]=1.0`, `sumfilt=1.0`** (single-pass identity).

**Critical consequence for box:** every weight is literally `1.0` (max=1, divide by 1, sumfilt = N/N = 1.0). **Box sub-passes are unit-weighted**, NOT 1/N. (Gaussian/exp weights are max-normalized to 1.0; sumfilt < 1.0.)

**2. Per-sub-pass dmap build (`rect.c:757, 778-782`)** — `color_scalar = temporal_filter[i]` is **baked into the dmap** BEFORE iteration, into ALL FOUR channels (rgb AND alpha):

```c
double color_scalar = temporal_filter[batch_num*ntemporal_samples + temporal_sample_num];
…
for (j = 0; j < CMAP_SIZE; j++)
   for (k = 0; k < 4; k++)
      dmap[j].color[k] = (cp.palette[(j*256)/CMAP_SIZE].color[k] * WHITE_LEVEL) * color_scalar;
```

**3. Accumulation (`rect.c:501-505`)** — bucket RGB+alpha get the dmap values (already weighted by `color_scalar`); **count increments UNWEIGHTED**:

```c
bump_no_overflow(b[0][0], interpcolor[0]);   // already color_scalar-scaled
bump_no_overflow(b[0][1], interpcolor[1]);
bump_no_overflow(b[0][2], interpcolor[2]);
bump_no_overflow(b[0][3], interpcolor[3]);
bump_no_overflow(b[0][4], 255.0);            // UNWEIGHTED count
```

**4. Budget split (`rect.c:833`)** — cost-neutral:

```c
batch_size = nsamples / (nbatches * ntemporal_samples);   // per sub-pass
```

**5. Tone-map once (`rect.c:933-974`)** — `k2` carries the `sumfilt` factor:

```c
k1 = (contrast * brightness * PREFILTER_WHITE * 268.0 * batch_filter[batch_num]) / 256;
   // batch_filter[i] = 1/nbatches; for us nbatches=1 → batch_filter=1.0
k2 = (oversample * oversample * nbatches) /
     (contrast * area * WHITE_LEVEL * sample_density * sumfilt);
…
// log-density (rect.c:963)
ls = (k1 * log(1.0 + c3 * k2)) / c3;     // c3 = bucket[3] = sum of (weighted) alphas
c[0..3] *= ls;
abump_no_overflow(a[0][0..3], c[0..3]);  // accumulate into cross-batch/passes abucket
```

(`abucket` is then spatial-filtered + gamma-corrected once. The plan's ToneMapping doc comment says `c3 = b[0][3]` — the alpha channel — which is correct; rect.c:959 confirms.)

### Why this matters for Emberweft

The current CPU `ChaosGame.iterate` hardcodes `colorScalar = 1.0` and builds the dmap once (`Sources/FlameReference/ChaosGame.swift:80-83`). The current Metal `renderFused` does the same (`Sources/FlameRenderer/MetalRenderer.swift:134-137`). For a **single-pass** render this is correct (flam3's box with N=1 has weight 1.0). For temporal motion blur:

- **Box filter (the only type real genomes use, verified on all fixtures):** each sub-pass's `colorScalar` is still `1.0` → dmap is byte-identical to the existing single-pass build. The only per-pass differences are the budget (`samplesPerPixel/N`) and the sub-time at which we re-blend the genome. The accumulated histogram after N box sub-passes ≈ a single full-budget pass at the center time (modulo Monte-Carlo noise from independent streams). **No brightness shift; no k2 change (sumfilt=1.0).**
- **Gaussian/exp:** would need per-pass dmap rebuild (different `colorScalar` per pass) + `sumfilt<1` threaded into `k2`. The plan supports this structurally but Metal defers it (Task 3 guard); CPU supports it (Task 2).

### Emberweft render path (both backends) — exact symbols verified

`emberweft animate` per-frame: `Schedule.frameToBlend(globalFrame:)` → `FrameMapping {segmentId, kind: Segment.Kind, blend ∈ (0,1]}` → `Schedule.segment(at:)` → `Segment {id, kind, fromSheep, toSheep, framesPerSegment}` → `Loop.blend(_:t:cycles:)` / `Transition.blend(_:_:t:stagger:)` → `MetalRenderer.render` / `ReferenceRenderer.render` (`Sources/EmberweftCLI/AnimateCommand.swift:186-222`).

- `RenderParams` (`Sources/FlameKit/RenderTypes.swift:20`): all `let`, `Sendable`+`Equatable`. `samplesPerPixel` participates in `totalSamples = width * height * samplesPerPixel` and feeds `ToneMapping.render(... sampleDensity: Double(params.samplesPerPixel) …)`. **The `pixelsPerUnit` passed to tone-map is `flame.camera.scale * pow(2, flame.camera.zoom)` — NO oversample factor** (verify in `ReferenceRenderer.swift:24` and `MetalRenderer.swift:190`); oversample enters `area` via `imageW = width * oversample`.
- `Histogram` (`RenderTypes.swift:44`): `var counts/colors/alpha` arrays, `let gridWidth/gridHeight`. The chaos game writes `hist.colors[idx] += SIMD3(...)`, `hist.alpha[idx] += interpA`, `hist.counts[idx] += 1` (`ChaosGame.swift:242-244`) — so summing M histograms (same grid) is a trivial elementwise `+=`.
- CPU `ChaosGame.iterate(flame:params:) -> Histogram` builds a **fresh** `Histogram` per call. CRITICAL: it uses the **hardcoded** `goldenIsaacSeed = "emberweftgoldens"` (`ChaosGame.swift:45`) — `params.seed` is NOT consumed by the CPU path. Calling `iterate` twice with the same flame+params produces **identical** histograms (just shorter trajectories if budget is smaller, but perfectly correlated). **The CPU temporal path must vary the per-pass ISAAC seed** — see Task 2 Step 3.
- Metal `MetalHost.buildThreadSeeds(seed: params.seed, threadCount:)` (`MetalHost.swift:143`) **does** consume `params.seed`, salting `"emberweft-metal-\(seed)"`. Per-pass regeneration: just rebuild with `seed: params.seed &+ UInt64(pass)`.
- The Metal chaosGame kernel reads `threadSeeds[gid * ISAAC_RANDSIZ_MS]` and does atomic adds into `atomicBuf` (`Kernels.metal:518, 501-504`). The host-side `colorScale` (`GPUFrameParams.colorScale = 2^31 / (T·255)`, `MetalHost.swift:153`) is the uint32 fixed-point atomic normalizer — **orthogonal** to flam3's temporal `color_scalar`; do not confuse them. The kernel's `accumulate` uses `fp.colorScale` to scale dmap values for atomic encoding; dmap values themselves come from the host's `buildDmap(... colorScalar:)` call and **already** carry any per-pass temporal weight.

### Comparison set for final validation

4 real gen-248 sheep with official videos —
`genomes/electric-sheep/sheep/gen-248/electricsheep.248.{05739,31943,16636,17549}.flam3`
↔ `/tmp/es_official/electricsheep.248.{05739,31943,16636,17549}.official.mp4` (each ~5.3 s, 648×480, motion-blurred, production quality). Re-download if missing (see Task 4 Step 4).

---

## File Structure

**Create:**
- `Sources/FlameReference/TemporalFilter.swift` — port of `flam3_create_temporal_filter` (`filters.c:409`). Returns `(samples: [(delta: Double, weight: Double)], sumfilt: Double)`. Weights are UN-NORMALIZED (1.0 for box; max-normalized to 1.0 for gaussian/exp).
- `Tests/FlameReferenceTests/RealGenomeParityTests.swift` — real-genome vs-flam3 PSNR gate (Task 6; currently ~20 dB, target ≥38).
- `Tools/density_diff.py` — diagnostic: pixel-intensity/alpha density histograms of Emberweft vs flam3 renders (Task 5).
- `Tools/density_diff.md` — diagnostic findings (Task 5 Step 3).

**Modify:**
- `Sources/FlameKit/Genome.swift` — add `temporalSamples`, `temporalFilterType`, `temporalFilterWidth`, `temporalFilterExp` to `Quality`.
- `Sources/FlameKit/Flam3Parser.swift` — parse `temporal_samples`, `temporal_filter_type`, `temporal_filter_width`, `temporal_filter_exp`.
- `Sources/FlameKit/Flam3Serializer.swift` — emit them (round-trip).
- `Sources/FlameKit/RenderTypes.swift` — `Histogram.scale(by:)` + `Histogram.accumulate(_:)` + `RenderParams.settingSamplesPerPixel(_:)` builder (keeps `samplesPerPixel` `let`).
- `Sources/FlameReference/ChaosGame.swift` — add `isaacSeed:` parameter (default `goldenIsaacSeed` for golden byte-compat) and `colorScalar:` parameter (default 1.0) threaded into the existing `buildDmap(... colorScalar:)` call.
- `Sources/FlameReference/ReferenceRenderer.swift` — add `render(blendAt:centerTime:temporal:params:)`.
- `Sources/FlameReference/ToneMapping.swift` — add `sumfilt: Double = 1.0` parameter on `render(...)`; thread into `k2`. **No change to the formula otherwise** (the doc already reads `ls = k1·log(1 + c3·k2) / c3` with `c3 = histogram.alpha[idx]`, which is correct).
- `Sources/FlameRenderer/MetalRenderer.swift` — add `render(blendAt:centerTime:temporal:params:)` (N chaos passes into one `atomicBuf`, single decode/DE/display).
- `Sources/EmberweftCLI/AnimateCommand.swift` — `--temporal-samples N` flag; build `blendAt` closure; dispatch to the temporal render path when N>1.

---

## Task 1: Parse temporal params + temporal-filter helper + RenderParams

**Goal:** Make the genome's `temporal_samples` / `temporal_filter_type` / `temporal_filter_width` / `temporal_filter_exp` first-class (parsed, modeled, round-tripped) and provide a faithful `TemporalFilter.samples(_:type:width:exp:)` helper that returns the **un-normalized** weights and the `sumfilt` scalar exactly as flam3's `filters.c:409` does.

**Files:**
- Modify: `Sources/FlameKit/Genome.swift` (the `Quality` struct, ~line 111)
- Modify: `Sources/FlameKit/Flam3Parser.swift` (`makeFlame`, ~line 140) + serializer `Sources/FlameKit/Flam3Serializer.swift` (~line 30)
- Modify: `Sources/FlameKit/RenderTypes.swift` (add `Histogram.scale` + `Histogram.accumulate` + `RenderParams.settingSamplesPerPixel`)
- Create: `Sources/FlameReference/TemporalFilter.swift`
- Test: extend `Tests/FlameKitTests/RealGenomePaletteTests.swift` + create `Tests/FlameReferenceTests/TemporalFilterTests.swift`

**Acceptance Criteria:**
- [ ] A real genome with `temporal_samples="1000" temporal_filter_type="box" temporal_filter_width="1.2"` parses to `quality.temporalSamples == 1000`, `.temporalFilterType == .box`, `.temporalFilterWidth == 1.2`. (All real fixtures carry exactly these — verified.)
- [ ] `TemporalFilter.samples(4, type: .box, width: 1.2)` returns 4 entries whose **weights are all exactly 1.0** (box = un-normalized; matches `filters.c:444-447`), and whose **deltas are evenly spaced across `[-0.6, +0.6]`** (span 1.2 = width, mean 0). `sumfilt == 1.0`.
- [ ] `TemporalFilter.samples(1, type: .box, width: 1.0)` returns `[(delta: 0.0, weight: 1.0)]` with `sumfilt == 1.0` (single-pass identity, `filters.c:419-423`).
- [ ] `TemporalFilter.samples(8, type: .gaussian, width: 1.2)` returns weights whose **max is exactly 1.0** (max-normalized; `filters.c:431-436` for the gaussian branch + `filters.c:441-447` for the `/maxfilt` normalization) and `sumfilt < 1.0` (specifically `Σweights/8`).
- [ ] Serializer round-trips the three attrs (`testRoundTripFullFeatures` extended and green).
- [ ] `Histogram.accumulate(other)` precondition-errors on grid-dimension mismatch; `scale(by:)` multiplies colors/alpha/counts elementwise.
- [ ] `RenderParams.settingSamplesPerPixel(N)(_:)` returns a copy with `samplesPerPixel=N` (original `let` preserved; `Sendable`+`Equatable` sound).

**Verify:** `swift test --filter TemporalFilterTests --filter RealGenomePaletteTests --filter SerializerTests` → all pass.

**Steps:**

- [ ] **Step 1: Write the failing tests.**

`Tests/FlameReferenceTests/TemporalFilterTests.swift`:
```swift
import XCTest
@testable import FlameReference
@testable import FlameKit

final class TemporalFilterTests: XCTestCase {
    func testBoxFilterUnitWeightsEvenDeltasSpanWidth() {
        let (f, sumfilt) = TemporalFilter.samples(4, type: .box, width: 1.2, exp: 0)
        XCTAssertEqual(f.count, 4)
        // Box: every weight is LITERALLY 1.0 (filters.c:444-447, max=1, /1).
        for s in f { XCTAssertEqual(s.weight, 1.0, accuracy: 1e-12) }
        XCTAssertEqual(sumfilt, 1.0, accuracy: 1e-12)            // (4·1)/4 == 1
        // deltas: ((i/(n-1)) - 0.5) * width, i.e. {-0.6, -0.2, +0.2, +0.6}
        let mean = f.map(\.delta).reduce(0, +) / Double(f.count)
        XCTAssertEqual(mean, 0.0, accuracy: 1e-12)
        XCTAssertEqual(f.last!.delta - f.first!.delta, 1.2, accuracy: 1e-12)   // span == width
    }
    func testSingleSampleIsNoBlur() {
        let (f, sumfilt) = TemporalFilter.samples(1, type: .box, width: 1.0, exp: 0)
        XCTAssertEqual(f.count, 1)
        XCTAssertEqual(f[0].weight, 1.0)
        XCTAssertEqual(f[0].delta, 0.0, accuracy: 1e-12)
        XCTAssertEqual(sumfilt, 1.0, accuracy: 1e-12)
    }
    func testGaussianMaxNormalizedToUnit() {
        let (f, sumfilt) = TemporalFilter.samples(8, type: .gaussian, width: 1.2, exp: 0)
        XCTAssertEqual(f.count, 8)
        // Max-normalized to 1.0 (filters.c:441 for the gaussian branch).
        let mx = f.map(\.weight).max()!
        XCTAssertEqual(mx, 1.0, accuracy: 1e-12)
        // Symmetric, peak in the middle.
        XCTAssertEqual(f[0].weight, f[7].weight, accuracy: 1e-12)
        XCTAssertLessThan(f[0].weight, f[3].weight)
        XCTAssertLessThan(sumfilt, 1.0)                         // (Σw)/8 < 1
    }
}
```

Extend `RealGenomePaletteTests`'s `cases` tuple with an expected `temporalSamples` and assert `flame.quality.temporalSamples` for `00000` (=1000) and `00256` (=1000), and `temporalFilterType == .box` + `temporalFilterWidth == 1.2` for both. (Verified against the fixtures at `Tests/Goldens/genomes_real/`.)

- [ ] **Step 2: Run → fail** (TemporalFilter undefined; temporalSamples unset).

- [ ] **Step 3: Implement.**

`Sources/FlameReference/TemporalFilter.swift`:
```swift
import Foundation
import FlameKit

/// Faithful port of flam3's `flam3_create_temporal_filter` (filters.c:409-450).
/// Produces N (delta, weight) sub-samples across a ±width/2 frame window + the
/// `sumfilt` scalar (Σweights/N) that the caller threads into ToneMapping's k2.
///
/// `delta` is in frames (added to the frame's center time); `weight` scales the
/// sub-pass's dmap via `color_scalar` (rect.c:757, 778-782). Weights are
/// UN-NORMALIZED — box weights are each literally 1.0 (so a box sub-pass is
/// byte-identical to the existing single-pass iterate); gaussian/exp weights
/// are max-normalized to 1.0. The caller MUST NOT re-normalize.
public enum TemporalFilter {
    public static func samples(
        _ n: Int, type: FilterShape, width: Double, exp: Double
    ) -> (samples: [(delta: Double, weight: Double)], sumfilt: Double) {
        let n = max(1, n)
        let w = width > 0 ? width : 1.0
        if n == 1 {
            // filters.c:419-423 — single step is the identity.
            return ([(delta: 0.0, weight: 1.0)], 1.0)
        }
        var deltas = [Double](repeating: 0, count: n)
        var filter = [Double](repeating: 0, count: n)
        // deltas[i] = ((i/(n-1)) - 0.5) * width  (filters.c:417)
        for i in 0..<n {
            deltas[i] = ((Double(i) / Double(n - 1)) - 0.5) * w
        }
        // filter weights (filters.c:425-444)
        switch type {
        case .box:
            for i in 0..<n { filter[i] = 1.0 }
        case .gaussian:
            // filters.c:431-436: filter[i] = flam3_spatial_filter(gaussian_kernel,
            //   flam3_spatial_support[gaussian_kernel] * |i - halfsteps| / halfsteps)
            // — i.e. it REUSES the SPATIAL gaussian filter function (not a fresh
            // exp). halfsteps = n/2.0.
            let halfsteps = Double(n) / 2.0
            let support = 1.5  // flam3_spatial_support[gaussian] (filters.c:31)
            for i in 0..<n {
                let arg = support * abs(Double(i) - halfsteps) / halfsteps
                // flam3_gaussian_filter (filters.c:156-158): exp(-2x²) · sqrt(2/π)
                filter[i] = exp(-2.0 * arg * arg) * (2.0 / Double.pi).squareRoot()
            }
        }
        // filters.c:441-447 — divide by max (so max → 1.0), then sumfilt = Σ / n.
        let maxfilt = filter.max() ?? 1.0
        var sumfilt = 0.0
        for i in 0..<n {
            filter[i] /= maxfilt
            sumfilt += filter[i]
        }
        sumfilt /= Double(n)
        let out = (0..<n).map { i in (delta: deltas[i], weight: filter[i]) }
        return (out, sumfilt)
    }
}
```

Add to `Quality` (`Genome.swift`), after `estimatorCurveRate`:
```swift
public var temporalSamples: Int
public var temporalFilterType: FilterShape
public var temporalFilterWidth: Double
public var temporalFilterExp: Double    // flam3 temporal_filter_exp (default 0; unused for box/gaussian)
```
+ init params `temporalSamples: Int = 1, temporalFilterType: FilterShape = .box, temporalFilterWidth: Double = 1.0, temporalFilterExp: Double = 0` and assignments.

Parse in `Flam3Parser.makeFlame`:
```swift
f.quality.temporalSamples = attr["temporal_samples"].flatMap { Int($0) } ?? 1
// FilterShape.rawValue is already "box"/"gaussian" (RenderTypes.swift:81) — matches
// flam3's temporal_filter_type strings EXACTLY, so no mapping layer is needed.
f.quality.temporalFilterType = attr["temporal_filter_type"].flatMap { FilterShape(rawValue: $0) } ?? .box
f.quality.temporalFilterWidth = attr["temporal_filter_width"].flatMap { Double($0) } ?? 1.0
f.quality.temporalFilterExp = attr["temporal_filter_exp"].flatMap { Double($0) } ?? 0
```

Emit in `Flam3Serializer` (only when non-default, to keep genomes compact):
```swift
if f.quality.temporalSamples != 1 { a += " temporal_samples=\"\(f.quality.temporalSamples)\"" }
if f.quality.temporalFilterType != .box { a += " temporal_filter_type=\"\(f.quality.temporalFilterType.rawValue)\"" }
if f.quality.temporalFilterWidth != 1.0 { a += " temporal_filter_width=\"\(f6(f.quality.temporalFilterWidth))\"" }
if f.quality.temporalFilterExp != 0 { a += " temporal_filter_exp=\"\(f6(f.quality.temporalFilterExp))\"" }
```

Add to `Histogram` (`RenderTypes.swift`):
```swift
/// Elementwise histogram multiplication (used for the temporal color_scalar
/// path on CPU; NOT used by box — box passes colorScalar=1.0). Multiplies
/// colors, alpha, AND counts by `factor` so the log-density curve stays
/// correctly scaled when sub-passes use max-normalized weights < 1.
public mutating func scale(by factor: Double) {
    for i in colors.indices {
        colors[i] *= factor
        alpha[i] *= factor
        counts[i] *= factor
    }
}
/// Elementwise histogram accumulation across temporal sub-passes (same grid).
public mutating func accumulate(_ other: Histogram) {
    precondition(gridWidth == other.gridWidth && gridHeight == other.gridHeight,
        "Histogram.accumulate requires equal grid dimensions")
    for i in colors.indices {
        colors[i] += other.colors[i]
        alpha[i]   += other.alpha[i]
        counts[i]  += other.counts[i]
    }
}
```

Add to `RenderParams`:
```swift
/// Builder that returns a copy with `samplesPerPixel` replaced. Keeps the
/// existing `let` field (Sendable sound) while letting the temporal render
/// path split the sample budget across sub-passes.
public func settingSamplesPerPixel(_ n: Int) -> RenderParams {
    RenderParams(seed: seed, width: width, height: height,
                 oversample: oversample, samplesPerPixel: n)
}
```

- [ ] **Step 4: Run → pass.** `swift test --filter TemporalFilterTests --filter RealGenomePaletteTests --filter SerializerTests`

- [ ] **Step 5: Commit.** `feat(flamekit): parse temporal_samples/filter + TemporalFilter helper (motion-blur prep)`

---

## Task 2: CPU temporal motion blur (faithful color_scalar accumulation)

**Goal:** `ReferenceRenderer` renders a motion-blurred frame by running N chaos sub-passes (one per sub-time) with per-pass `colorScalar` baked into the dmap, accumulating into one `Histogram`, then DE + tone-map once — cost-neutral vs a single-frame render (`rect.c:833`).

**Files:**
- Modify: `Sources/FlameReference/ChaosGame.swift` (add `isaacSeed:` + `colorScalar:` params on `iterate`)
- Modify: `Sources/FlameReference/ReferenceRenderer.swift` (add `render(blendAt:centerTime:temporal:sumfilt:params:)`)
- Modify: `Sources/FlameReference/ToneMapping.swift` (add `sumfilt:` param)
- Test: `Tests/FlameReferenceTests/TemporalBlurTests.swift` (create)

**Acceptance Criteria:**
- [ ] `ReferenceRenderer.render(blendAt: …, temporal: [(0, 1.0)], sumfilt: 1.0, …)` is byte-identical to `ReferenceRenderer.render(flame: blendAt(centerTime), params:)` (no-blur identity).
- [ ] When `blendAt` is constant (returns the same `Flame` G for every sub-time) and the per-pass ISAAC seed varies by pass index, `render(…, temporal: N box samples, …)` has mean channel brightness within 5% of `render(G, params)` — i.e. temporal blur of a static genome preserves total light (faithful color_scalar + sumfilt=1 → no brightness shift for box).
- [ ] When `blendAt` is constant and the per-pass ISAAC seed is NOT varied, the result is a strict subset of the single-pass render (correlated streams) — this is a NEGATIVE test that proves the seed-salting is load-bearing.
- [ ] `make test-fast` still green.

**Verify:** `swift test --filter TemporalBlurTests` → pass; `make test-fast` → 0 failures.

**Steps:**

- [ ] **Step 1: Write failing tests.**

```swift
import XCTest
@testable import FlameReference
@testable import FlameKit

final class TemporalBlurTests: XCTestCase {
    private func meanChannel(_ img: RGBA8Image) -> Double {
        var s = 0.0
        for i in stride(from: 0, to: img.pixels.count, by: 4) {
            s += Double(img.pixels[i] + img.pixels[i+1] + img.pixels[i+2])
        }
        return s / Double(img.pixels.count / 4) / 3.0
    }
    func testSingleTemporalSampleMatchesPlainRender() throws {
        let url = URL(fileURLWithPath: "Tests/Goldens/genomes_real/electricsheep.248.00256.flam3")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("fixture missing") }
        let g = try Flam3Parser.parse(Data(contentsOf: url)).first!
        let p = RenderParams(seed: 7, width: 240, height: 180, oversample: 1, samplesPerPixel: 200)
        let plain = ReferenceRenderer.render(flame: g, params: p)
        let (temporal, sumfilt) = TemporalFilter.samples(1, type: .box, width: 1.0, exp: 0)
        let blurred = ReferenceRenderer.render(
            blendAt: { _ in g }, centerTime: 0.5,
            temporal: temporal, sumfilt: sumfilt, params: p)
        XCTAssertEqual(blurred.pixels, plain.pixels, "temporalSamples=1 must equal plain render")
    }
    func testStaticBoxBlurPreservesTotalLight() throws {
        let url = URL(fileURLWithPath: "Tests/Goldens/genomes_real/electricsheep.248.00256.flam3")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("fixture missing") }
        let g = try Flam3Parser.parse(Data(contentsOf: url)).first!
        let p = RenderParams(seed: 7, width: 200, height: 150, oversample: 1, samplesPerPixel: 300)
        let plain = ReferenceRenderer.render(flame: g, params: p)
        // constant blendAt → box blur of a static genome == static (sumfilt=1, no brightness shift).
        let (temporal, sumfilt) = TemporalFilter.samples(8, type: .box, width: 1.2, exp: 0)
        let blurred = ReferenceRenderer.render(
            blendAt: { _ in g }, centerTime: 0.3,
            temporal: temporal, sumfilt: sumfilt, params: p)
        let meanA = meanChannel(plain), meanB = meanChannel(blurred)
        // Box weights are all 1.0 → totals ≈ match; tolerance is Monte-Carlo noise from
        // per-pass seed variation (each sub-pass has 1/N budget).
        XCTAssertEqual(meanB, meanA, accuracy: meanA * 0.05,
            "static box temporal blur should preserve total light (got meanA=\(meanA) meanB=\(meanB))")
    }
}
```

- [ ] **Step 2: Run → fail** (no `render(blendAt:…)`; `ChaosGame.iterate` lacks the new params).

- [ ] **Step 3: Implement** — three small changes:

(a) **`ChaosGame.iterate`** (`ChaosGame.swift:49`): add two defaulted parameters (defaults preserve the existing golden byte-identity):
```swift
public static func iterate(
    flame: Flame, params: RenderParams,
    isaacSeed: String = goldenIsaacSeed,   // per-pass seed salt for temporal motion blur
    colorScalar: Double = 1.0              // flam3 color_scalar (rect.c:757) baked into dmap
) -> Histogram {
    …
    // CHANGED line (~:80-83):
    let colorScalar = colorScalar    // was: `let colorScalar = 1.0`
    let dmap = buildDmap(flame.palette, whiteLevel: whiteLevel, colorScalar: colorScalar)
    let dmapAlpha = [Double](repeating: whiteLevel * colorScalar, count: cmapSize)
    …
    // CHANGED line (~:96): seed the parent ISAAC from the per-pass salt.
    var parent = ISAAC(isaacSeed: isaacSeed)   // was: `goldenIsaacSeed`
    …
}
```
(The rest of `iterate` is unchanged. `count += 1` stays unweighted, matching `rect.c:501-505`.)

(b) **`ToneMapping.render`** (`ToneMapping.swift:32`): add `sumfilt: Double = 1.0` and thread into `k2`:
```swift
public static func render(histogram: Histogram, width: Int, height: Int, oversample: Int,
                          gamma: Double, gammaThreshold: Double, vibrancy: Double,
                          brightness: Double = 4.0,
                          sampleDensity: Double, pixelsPerUnit: Double,
                          sumfilt: Double = 1.0) -> RGBA8Image {
    …
    // CHANGED (~:48): include sumfilt in k2's denominator (rect.c:937).
    let k2 = Double(oversample * oversample * nbatches) /
             (contrast * area * whiteLevel * sampleDensity * sumfilt)
    …
}
```
Callers that don't pass `sumfilt` keep the existing behavior (sumfilt=1.0). Update the single-pass call sites (`ReferenceRenderer.render(flame:params:)`, `MetalRenderer.renderUnfused`, `DisplayPipelineMetal.render`) to keep `sumfilt: 1.0` implicitly via the default — no change needed at those call sites.

(c) **`ReferenceRenderer.render(blendAt:…)`** (`ReferenceRenderer.swift`, new overload):
```swift
/// Temporal motion-blur render: faithful port of flam3's temporal_samples loop
/// (rect.c:754-905). Runs N chaos sub-passes at sub-times across a ±width/2
/// window, each with samplesPerPixel/N budget and `color_scalar = weight` baked
/// into its dmap, then accumulates into one histogram. DE + tone-map run ONCE.
/// Cost-neutral (rect.c:833). For box filter, colorScalar=1.0 per pass →
/// sub-passes are byte-identical to a single-budget iterate modulo the seed.
public static func render(
    blendAt: (Double) -> Flame,
    centerTime: Double,
    temporal: [(delta: Double, weight: Double)],
    sumfilt: Double,
    params: RenderParams
) -> RGBA8Image {
    let center = blendAt(centerTime)
    let N = max(1, temporal.count)
    // Budget split (rect.c:833). Distribute the integer remainder across the
    // first `rem` passes so the total budget is exact (no silent under-sampling).
    let base = params.samplesPerPixel / N
    let rem  = params.samplesPerPixel % N
    var hist = Histogram(gridWidth: params.gridWidth, gridHeight: params.gridHeight)
    for (i, sub) in temporal.enumerated() {
        let perPass = base + (i < rem ? 1 : 0)
        let passParams = params.settingSamplesPerPixel(perPass)
        let g = blendAt(centerTime + sub.delta)
        // Per-pass color_scalar baked into dmap (rect.c:757, 778-782). Per-pass
        // ISAAC seed salt avoids correlated trajectories (the CPU iterate is
        // otherwise pinned to `goldenIsaacSeed`). Count increments UNWEIGHTED
        // (rect.c:501-505) — already true in ChaosGame.iterate; do NOT post-scale.
        let subHist = ChaosGame.iterate(
            flame: g, params: passParams,
            isaacSeed:  "emberweftgoldens-tmp\(i)",
            colorScalar: sub.weight)
        hist.accumulate(subHist)
    }
    var h = hist
    if center.quality.estimatorRadius > 0 {
        h = DensityEstimation.apply(h, radius: center.quality.estimatorRadius,
            minimum: center.quality.estimatorMinimum, curve: center.quality.estimatorCurveRate)
    }
    return ToneMapping.render(histogram: h, width: params.width, height: params.height,
        oversample: params.oversample, gamma: center.quality.gamma,
        gammaThreshold: center.quality.gammaThreshold, vibrancy: center.quality.vibrancy,
        brightness: center.quality.brightness, sampleDensity: Double(params.samplesPerPixel),
        pixelsPerUnit: center.camera.scale * pow(2, center.camera.zoom),
        sumfilt: sumfilt)
}
```
Faithfulness note: `color_scalar` is baked into the dmap → RGB+alpha are weighted automatically by the dmap lookup; **the count increments UNWEIGHTED regardless of filter type** (`rect.c:501-505`). So for box AND gaussian/exp, NO post-pass `Histogram.scale(by:)` is needed — `ChaosGame.iterate(... colorScalar: sub.weight)` already does the right thing. (`Histogram.scale(by:)` and `Histogram.accumulate(_:)` are still added in Task 1 as small Histogram API utilities; `accumulate` is used here, `scale` is reserved for future use cases and is intentionally not on the hot path.)

- [ ] **Step 4: Run → pass.** `swift test --filter TemporalBlurTests`

- [ ] **Step 5: Commit.** `feat(reference): CPU temporal motion blur (faithful color_scalar + sumfilt)`

---

## Task 3: Metal temporal motion blur (N fused chaos passes)

**Goal:** `MetalRenderer` renders a motion-blurred frame by encoding N chaos passes (one per sub-time genome, `threadCount/N` threads each, **per-pass seed regeneration** to avoid correlated streams) into the **same** `atomicBuf`, then a single decode→DE→display. Cost-neutral. Box filter (default) → per-pass `colorScalar=1.0` so the dmap is identical to single-pass. Gaussian/exp supported but rarely used; loud `fatalError` if the kernel-side gaussian path is needed (deferred).

**Files:**
- Modify: `Sources/FlameRenderer/MetalRenderer.swift` (add `render(blendAt:centerTime:temporal:sumfilt:params:)`, modeled on `renderFused`)

**Acceptance Criteria:**
- [ ] `MetalRenderer.render(blendAt:…, temporal: [(0,1)], sumfilt: 1, …)` is byte-identical to `MetalRenderer.render(flame: blendAt(center), params:)` (identity).
- [ ] `FusedUnfusedParityTests` still passes (fused output unchanged at temporalSamples=1).
- [ ] A 2-sheep Metal render with `--temporal-samples 8` (box) completes without error and is non-black.
- [ ] Metal `render(blendAt:…, type: .gaussian, …)` calls `fatalError` with a clear message (gaussian temporal on Metal is structurally supported by the host path but the kernel dmap-update path for non-`1.0` `colorScalar` is not wired through the cached PSO; we fail loudly rather than render wrong output).

**Verify:** `swift test --filter TemporalBlurMetalTests --filter FusedUnfusedParityTests` → pass (**sandbox OFF** — `MTLCreateSystemDefaultDevice()` returns nil under the bash sandbox).

**Steps:**

- [ ] **Step 1: Write failing test** (Metal-gated, `@MainActor` per `CLAUDE.md`'s Swift-6 test rule):
```swift
import XCTest
@testable import FlameRenderer
@testable import FlameReference   // for TemporalFilter
@testable import FlameKit

final class TemporalBlurMetalTests: XCTestCase {
    @MainActor func testMetalTemporalSingleSampleMatchesPlain() throws {
        guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
        let url = URL(fileURLWithPath: "Tests/Goldens/genomes_real/electricsheep.248.00256.flam3")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("fixture missing") }
        let g = try Flam3Parser.parse(Data(contentsOf: url)).first!
        let p = RenderParams(seed: 3, width: 200, height: 150, oversample: 1, samplesPerPixel: 200)
        let plain = MetalRenderer.render(flame: g, params: p)
        let (temporal, sumfilt) = TemporalFilter.samples(1, type: .box, width: 1.0, exp: 0)
        let blurred = MetalRenderer.render(
            blendAt: { _ in g }, centerTime: 0.5,
            temporal: temporal, sumfilt: sumfilt, params: p)
        XCTAssertEqual(blurred.pixels, plain.pixels)
    }
    @MainActor func testMetalTemporalBoxSamplesNonBlack() throws {
        guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
        let url = URL(fileURLWithPath: "Tests/Goldens/genomes_real/electricsheep.248.00256.flam3")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("fixture missing") }
        let g = try Flam3Parser.parse(Data(contentsOf: url)).first!
        let p = RenderParams(seed: 3, width: 200, height: 150, oversample: 1, samplesPerPixel: 200)
        let (temporal, sumfilt) = TemporalFilter.samples(8, type: .box, width: 1.2, exp: 0)
        let img = MetalRenderer.render(
            blendAt: { _ in g }, centerTime: 0.5,
            temporal: temporal, sumfilt: sumfilt, params: p)
        let nonBlack = img.pixels.prefix(3).contains { $0 != 0 }
        XCTAssertTrue(nonBlack, "temporal-samples=8 should produce a non-black image")
    }
}
```

- [ ] **Step 2: Run → fail.**

- [ ] **Step 3: Implement.** Copy `renderFused(flame:params:)` → new `render(blendAt:centerTime:temporal:sumfilt:params:)`. Key differences vs `renderFused`:
  - Build the shared payload (device/library/queue via `fusedPipelines()`; display params with `sumfilt` in `k2`; DE params; `atomicBuf` cleared ONCE; `floatBufA`/`floatBufB`; `accumRGBBuf`/`accumABuf`/`outBuf`) from the **center** flame.
  - Compute per-pass thread budget: `let perPassThreads = max(tpg, (Int(fp.threadCount) / temporal.count) * tpg / tpg)` — keep it a multiple of `threadsPerGroup` (so `groups = perPassThreads / tpg` is exact, no integer remainder at the dispatch level). Concretely:
    ```swift
    let fullThreadCount = Int(fp.threadCount)             // already a multiple of tpg
    let groupsPerPass = max(1, fullThreadCount / temporal.count / MetalHost.threadsPerGroup)
    let perPassThreads = groupsPerPass * MetalHost.threadsPerGroup
    ```
  - Replace the single "Encoder 1: chaosGame" block (`MetalRenderer.swift:251-268`) with a loop over `temporal`. Per pass: re-pack xforms/final/distrib, **rebuild dmap with `colorScalar = sub.weight`** (a one-liner over the existing `buildDmap` call), **regenerate `seedsBuf`** via `MetalHost.buildThreadSeeds(seed: params.seed &+ UInt64(i), threadCount: perPassThreads)`, update `fp.threadCount/iterationsPerThread/remainder/colorScale` for the per-pass budget, encode into the SAME uncleared `atomicBuf`.
  - Keep Encoder 2 (decode) → optional Encoder 3 (DE) → Encoder 4 (logDensity) → Encoder 5 (display) unchanged. The decode's `colorScale = 2^31 / (T·255)` uses the FULL budget T (across all passes), since `atomicBuf` accumulates across passes — do NOT change `colorScale` per pass.
  - Box (default): `sub.weight == 1.0` → per-pass dmap == single-pass dmap. No-op structurally.
  - Gaussian/exp guard: at the top of the function:
    ```swift
    if temporal.contains(where: { $0.weight != 1.0 }) {
        fatalError("MetalRenderer.render(blendAt:…): non-unit temporal weights (gaussian/exp filter) are not yet wired through the cached chaos PSO. All real ES genomes use temporal_filter_type=\"box\" (unit weights); use --backend cpu for gaussian/exp.")
    }
    ```
    (This is a documented limitation, not a silent wrong-output path. CPU honors gaussian/exp via Task 2.)

Schematic of the chaos loop (illustrative — exact buffer plumbing matches `renderFused`):
```swift
for (i, sub) in temporal.enumerated() {
    let g = blendAt(centerTime + sub.delta)
    let passXforms   = MetalHost.packXforms(g)
    let passFinal    = MetalHost.packFinalXform(g)
    let passDistrib  = Flam3XformDistrib.build(g.xforms.map { max(0, $0.weight) })
                      .map { UInt32(min($0, max(0, g.xforms.count - 1))) }
    // PER-PASS dmap with color_scalar baked in (rect.c:757, 778-782). Box → 1.0.
    let passDmapD  = buildDmap(g.palette, whiteLevel: 255.0, colorScalar: sub.weight)
    let passDmap   = passDmapD.map { SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z)) }
    let passDmapA  = [Float](repeating: Float(255.0 * sub.weight), count: 256)
    // PER-PASS seeds — regenerate so passes don't walk the same threads (would
    // produce identical trajectories and a biased accumulator).
    let passSeeds  = MetalHost.buildThreadSeeds(seed: params.seed &+ UInt64(i),
                                                threadCount: perPassThreads)
    var passFp = fp
    let passTotal = params.width * params.height * (params.samplesPerPixel / temporal.count)
                   + (i < (params.samplesPerPixel % temporal.count) ? params.width * params.height : 0)
    passFp.threadCount = UInt32(perPassThreads)
    let ipt = passTotal / perPassThreads
    passFp.iterationsPerThread = UInt32(ipt)
    passFp.remainder = UInt32(passTotal % perPassThreads)
    passFp.colorScale = MetalHost.colorScale(totalSamples: params.width * params.height * params.samplesPerPixel)
    // encode chaosGame into the SAME atomicBuf (NOT cleared between passes).
    …  // setBuffer + dispatchThreadgroups exactly as renderFused's Encoder 1
}
```

- [ ] **Step 4: Run → pass** (sandbox off).

- [ ] **Step 5: Commit.** `feat(renderer): Metal temporal motion blur (N fused chaos passes, per-pass seeds)`

---

## Task 4: `--temporal-samples` in animate + production validation re-render

> **USER-ORDERED GATE — NON-SKIPPABLE.** This task was requested by the user in the current conversation. It MUST NOT be closed by walking around it, by declaring it "verified inline", or by substituting a cheaper check. Close only after every item in `acceptanceCriteria` has been re-validated independently, with output captured.

**Goal:** Wire motion blur into `emberweft animate` (`--temporal-samples N`), re-render a real-genome clip at production settings (high q + blur), and **visually verify** the transition→loop jump is gone, the motion is relaxing/smooth, and it is structurally comparable to the 4 official videos.

**Files:**
- Modify: `Sources/EmberweftCLI/AnimateCommand.swift` (render loop, ~lines 182-222)

**Acceptance Criteria:**
- [ ] `emberweft animate … --temporal-samples N` parses N (default 1 = current no-blur behavior; if absent AND on CPU, use the genome's `quality.temporalSamples`). On Metal, cap N at 64 with a printed warning when the genome asks for more; on CPU, honor the genome value uncapped ("slow meditative production" is acceptable).
- [ ] The render loop builds a `blendAt: (Double) -> Flame` closure (dispatches on `mapping.kind: Segment.Kind` — the real symbol — to `Loop.blend(flames[segment.fromSheep], t:, cycles: loopCycles)` / `Transition.blend(flames[segment.fromSheep], flames[segment.toSheep], t:, stagger:)`), and calls the temporal render path when N>1.
- [ ] `mapping.blend ± delta` is the center time for each sub-pass. `mapping.blend ∈ (0,1]` (Schedule invariant), `delta ∈ [-width/2, +width/2]` so sub-times may slightly exceed 1 or fall slightly below 0. `Loop.blend` handles any real `t` (rotation is periodic; `Transition.blend` extrapolates outside `[0,1]`). Verify both still produce finite Flames; if not, clamp `mapping.blend + delta` to `[0,1]`.
- [ ] A re-rendered short clip (2 of the 4 sheep, e.g. 05739→31943, `--frames 160 --segments 3 --loop-cycles 1 --temporal-samples 32 --quality 500 --size 1280x720`) is produced at `/tmp/m3_mb/` + muxed to `/tmp/m3_mb.mp4`.
- [ ] **Boundary PSNR check:** with `--frames 160 --segments 3`, the transition→loop boundary is at global frame 319→320 (seg 1 = transition A→B, frames 160–319; seg 2 = loop B, frames 320–479). Consecutive-frame PSNR at 319→320 is **no longer the global minimum** — within ~2 dB of within-loop (100→101 in seg 0). Capture both ffmpeg PSNR numbers.
- [ ] **Visual check (user):** the clip plays smoothly/relaxingly and each loop is recognizably the same sheep as its official video in `/tmp/es_official/`.

**Verify:**
```bash
# render (sandbox OFF; Metal only for the realtime-ish validation)
swift run emberweft animate \
  genomes/electric-sheep/sheep/gen-248/electricsheep.248.05739.flam3 \
  genomes/electric-sheep/sheep/gen-248/electricsheep.248.31943.flam3 \
  --frames 160 --segments 3 --loop-cycles 1 --selector sequential --backend metal \
  --size 1280x720 --quality 500 --temporal-samples 32 --seed 42 --out /tmp/m3_mb
ffmpeg -framerate 30 -i /tmp/m3_mb/%06d.png -c:v libx264 -pix_fmt yuv420p /tmp/m3_mb.mp4
# boundary PSNR (seg 0 loop A: 0..159; seg 1 transition: 160..319; seg 2 loop B: 320..479)
cd /tmp/m3_mb && for p in "100 101" "319 320"; do set -- $p; \
  ffmpeg -hide_banner -i $(printf "%06d.png" $1) -i $(printf "%06d.png" $2) \
         -filter_complex psnr -f null - 2>&1 | grep -oE "average:[0-9.]+"; done
open /tmp/m3_mb.mp4 /tmp/es_official/electricsheep.248.05739.official.mp4
```
Expected: the two PSNRs are within ~2 dB (no sharp dip at 319→320), unlike the no-blur preview (was 14.4 at boundary vs 15.7 within). Capture both numbers as evidence tokens (see metadata `requireEvidenceTokens`).

**Steps:**

- [ ] **Step 1: Add the flag.** In `AnimateCommand.animate(_:)` (around the existing `--loop-cycles` case at line 82-84), add:
```swift
case "--temporal-samples":
    guard i + 1 < args.count else { err("error: --temporal-samples requires a value\n"); return 2 }
    temporalSamples = max(1, Int(args[i + 1]) ?? 1); i += 2
```
and declare `var temporalSamples: Int = 1` near the other option vars. After loading genomes, apply defaulting + capping:
```swift
// Default to the genome's value on CPU (offline cost is OK); cap on Metal.
let genomeTemporal = baseFlame.quality.temporalSamples
if temporalSamples == 1 && genomeTemporal > 1 {
    temporalSamples = genomeTemporal
}
let metalTemporalCap = 64
if backend == "metal" && temporalSamples > metalTemporalCap {
    err("note: --temporal-samples \(temporalSamples) capped to \(metalTemporalCap) on Metal (dispatch overhead bound); use --backend cpu for the full genome value\n")
    temporalSamples = metalTemporalCap
}
```

- [ ] **Step 2: Build the blend closure + dispatch.** Inside the existing per-frame loop (after `let segment = schedule.segment(at: mapping.segmentId)`, around line 188), replace the `renderedFlame` + render call block (lines 191-222) with:
```swift
let (temporal, sumfilt): ([(delta: Double, weight: Double)], Double) = temporalSamples > 1
    ? TemporalFilter.samples(
        temporalSamples,
        type: flames[segment.fromSheep].quality.temporalFilterType,
        width: flames[segment.fromSheep].quality.temporalFilterWidth,
        exp:    flames[segment.fromSheep].quality.temporalFilterExp)
    : ([(delta: 0.0, weight: 1.0)], 1.0)

func blendAt(_ t: Double) -> Flame {
    // mapping.kind, segment.fromSheep, segment.toSheep, mapping.blend are the
    // real symbols in AnimateCommand's existing loop (verified at :192-199).
    switch mapping.kind {
    case .loop:
        return Loop.blend(flames[segment.fromSheep], t: t, cycles: loopCycles)
    case .transition:
        return Transition.blend(
            flames[segment.fromSheep], flames[segment.toSheep],
            t: t, stagger: stagger)
    }
}

let params = RenderParams(
    seed: seed, width: width, height: height,
    oversample: 1, samplesPerPixel: renderQuality)

let img: RGBA8Image
if backend == "metal" {
    // The existing render loop already wraps MetalRenderer.render in
    // MainActor.assumeIsolated { autoreleasepool { … } } (line 217). The
    // CLAUDE.md `assumeIsolated` warning is for @MainActor TEST methods that
    // capture `self`; this is a static function with no self capture, so the
    // pattern is safe and matches the existing code.
    img = MainActor.assumeIsolated {
        autoreleasepool {
            temporalSamples > 1
                ? MetalRenderer.render(blendAt: blendAt, centerTime: mapping.blend,
                                       temporal: temporal, sumfilt: sumfilt, params: params)
                : MetalRenderer.render(flame: blendAt(mapping.blend), params: params)
        }
    }
} else {
    img = temporalSamples > 1
        ? ReferenceRenderer.render(blendAt: blendAt, centerTime: mapping.blend,
                                   temporal: temporal, sumfilt: sumfilt, params: params)
        : ReferenceRenderer.render(flame: blendAt(mapping.blend), params: params)
}
```
Sub-times are `mapping.blend + delta`. Since `mapping.blend ∈ (0,1]` and `|delta| ≤ width/2 = 0.6` (real genomes), the sub-time range is `[-0.6, 1.6]`. **Smoke test in Step 3 confirms Loop/Transition produce finite Flames over this range**; if any fixture produces NaN/Inf, clamp `min(1, max(0, mapping.blend + delta))` (faithful flam3 would not clamp, but if the math explodes for an exotic genome we prefer clamp over crash).

- [ ] **Step 3: Build + smoke** (`swift build`; render a tiny `--frames 4 --segments 2 --temporal-samples 4 --quality 50 --size 160x120 --backend cpu` and the same on `--backend metal` to confirm no crash). Confirm with `Transition.blend(a, b, t: 1.6, stagger: 0)` for a real fixture (`xcode` swift snippet or a `Tools/check_t_range.swift`).

- [ ] **Step 4: Render the validation clip + boundary PSNR** (the Verify commands above); capture the numbers as `[boundary-psnr: <val>]` and `[within-loop-psnr: <val>]` evidence tokens.

- [ ] **Step 5: Open the clip + the 2 official videos for the user; record boundary-vs-within PSNR.**

- [ ] **Step 6: Commit.** `feat(animate): --temporal-samples motion blur + production-quality render path`

If official videos are missing from `/tmp/es_official/`, re-download (they survive only in `/tmp`): the 4 are at `https://archive.org/download/electricsheep-flock-248-<range>-<part>/00248=<id>=<id>=<id>.mp4` where range=`floor(id/10000)…` — see Background; or rerun the IA scan in the prior session's transcript.

---

## Task 5: Density-gap diagnostic (localize the ≈20 dB)

**Goal:** Determine WHERE Emberweft's density distribution diverges from flam3 on a real genome, so Task 6 has a concrete target. Hypothesis to confirm/refute: Emberweft's chaos histogram is peakier (more density in the core, less in the periphery) than flam3's, at the same total samples.

**Files:**
- Create: `Tools/density_diff.py`
- Create: `Tools/density_diff.md`

**Acceptance Criteria:**
- [ ] `Tools/density_diff.py` renders `00256` (no blur, matched params: 800×592, oversample=1, `estimator_radius=0`, same `isaac_seed`/`seed`, q=1000) both in Emberweft (`swift run emberweft render <sanitized> --backend cpu --size 800x592 --quality 1000`) and flam3 (`flam3-render` env: `format=png nthreads=1` + stdin genome), and prints: (a) pixel-brightness histogram (≥8 buckets) of each; (b) % of pixels above thresholds {4, 32, 128}; (c) the centroid + active bbox of each.
- [ ] The flam3 side sanitizes the genome to `temporal_samples=1 supersample=1 estimator_radius=0 estimator_minimum=0` (regex-rewrite, mirroring `Flam3Oracle.injectMotionBlurOff` in `Tests/FlameReferenceTests/Flam3Oracle.swift:163`) so the comparison isolates the chaos-game density distribution.
- [ ] A written finding in `Tools/density_diff.md` states: which region (core vs mid vs periphery) differs most, and the ranked candidate causes (chaos sample distribution / DE curve / `k2`-`sampleDensity` / spatial filter).

**Verify:** `python3 Tools/density_diff.py` prints both distributions side-by-side; `Tools/density_diff.md` documents the localization.

**Steps:**

- [ ] **Step 1: Write `Tools/density_diff.py`.** Drive flam3 with the same env-var pattern as `Tools/regen_goldens.sh:84-89`:
```python
env format=png nthreads=1 seed=<seed> isaac_seed=<isaac_seed> \
    in=<sanitized.flam3> out=/tmp/fl.png \
    flam3-render
```
For Emberweft: `swift run emberweft render <sanitized.flam3> --backend cpu --size 800x592 --quality 1000 --seed <seed> --out /tmp/emb.png`. (If `emberweft render` doesn't take `--seed`, fall back to invoking `ReferenceRenderer.render` from a tiny Swift CLI snippet or extend `render` to accept `--seed`; document whichever path is used.) Use PIL to compute the brightness histograms + thresholds + centroid/bbox (the analysis already prototyped in the prior session — reuse it).

- [ ] **Step 2: Run + read the output.** Expect to confirm Emberweft has fewer mid-brightness pixels (the "thinner periphery" seen at 78.5% vs 93.5%).

- [ ] **Step 3: Rank causes.** Inspect, in order: (1) `ChaosGame.iterate` xform-selection distribution vs flam3 (`flam3.c` `flam3_create_xform_table`/weight normalization — Emberweft's `Flam3XformDistrib.build` is the port; verify the table-fill loop matches `flam3.c:165`); (2) `DensityEstimation.apply` curve vs flam3 even with the same radius (re-enable DE in the diff to see if it amplifies or closes the gap); (3) `k2` and `sampleDensity` in `ToneMapping` (rect.c:935-937) — confirm `area`/`pixelsPerUnit` match (especially: `pixelsPerUnit = flame.camera.scale * pow(2, flame.camera.zoom)`, NO oversample factor); (4) the spatial filter (`flam3SpatialFilterWidth`/radius). Write findings to `Tools/density_diff.md`.

- [ ] **Step 4: Commit.** `tools: density-diff diagnostic for real-genome parity (localizes the ≈20 dB gap)`

---

## Task 6: Fix the density gap + gated real-genome vs-flam3 parity test

**Goal:** Close the localized density difference so real-genome PSNR vs flam3 reaches **≥ 38 dB** (the existing Metal↔CPU gate), and lock it in with a gated parity test across the diverse real fixtures.

**Files:**
- Modify: whatever Task 5 localized (likely `Sources/FlameReference/ChaosGame.swift`, `DensityEstimation.swift`, or `ToneMapping.swift`)
- Create: `Tests/FlameReferenceTests/RealGenomeParityTests.swift`

**Acceptance Criteria:**
- [ ] `RealGenomeParityTests` renders each fixture in `Tests/Goldens/genomes_real/` (CPU, no blur, matched params — sanitized to `temporal_samples=1 supersample=1 estimator_radius=0 estimator_minimum=0` so the comparison isolates the chaos density + display pipeline) vs live `flam3-render` and asserts **PSNR ≥ 38 dB, SSIM ≥ 0.95** (XCTSkip if oracle absent — same F10 contract as the existing `AnimationParityTests`).
- [ ] The test is RED before the fix (~20 dB) and GREEN after.
- [ ] GoldenParity (synthetic) still ≥ 30 dB (no regression); `make test-fast` green.

**Verify:** `swift test --filter RealGenomeParityTests` → PSNR ≥ 38 dB on all fixtures; `swift test --filter GoldenParityTests` → unchanged.

**Steps:**

- [ ] **Step 1: Add a `renderStatic` helper to `Flam3Oracle`** (or use `Flam3Oracle.run` directly). `Flam3Oracle` currently wraps `flam3-genome`/`flam3-animate` only; `flam3-render` is the right tool for single-frame stills (its env-var surface: `in`, `out`, `format`, `nthreads`, `seed`, `isaac_seed`, `qs`, `bits`, `transparency`; matches `Tools/regen_goldens.sh:84-89`). Add:
```swift
/// Drive `flam3-render` (single still) env-var-driven. Mirrors `regen_goldens.sh`.
@discardableResult
static func renderStatic(
    genomePath: String, outPath: String,
    seed: UInt64, isaacSeed: String, nthreads: Int = 1
) throws -> URL {
    try require()
    var env = ProcessInfo.processInfo.environment
    env["format"] = "png"
    env["transparency"] = "0"
    env["in"] = genomePath
    env["out"] = outPath
    env["seed"] = String(seed)
    env["isaac_seed"] = isaacSeed
    env["nthreads"] = String(nthreads)
    _ = try run(command: "flam3-render", arguments: [], environment: env, stdin: nil)
    return URL(fileURLWithPath: outPath)
}
```

- [ ] **Step 2: Write the failing parity test** (red — asserts ≥38 dB, currently ~20):
```swift
import XCTest
@testable import FlameReference
@testable import FlameKit

final class RealGenomeParityTests: XCTestCase {
    func testRealGenomesMatchFlam3() throws {
        try Flam3Oracle.require()   // F10 auto-skip if oracle absent
        let fixturesDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Goldens/genomes_real")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("real_parity_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let genomes = try FileManager.default.contentsOfDirectory(atPath: fixturesDir.path)
            .filter { $0.hasSuffix(".flam3") }
        XCTAssertFalse(genomes.isEmpty, "no real fixtures")
        for name in genomes {
            let fixtureURL = fixturesDir.appendingPathComponent(name)
            // Sanitize: disable motion blur + DE to isolate chaos + display parity.
            let xml = try String(contentsOf: fixtureURL, encoding: .utf8)
            let sanitized = Flam3Oracle.injectMotionBlurOff(xml)  // sets passes=1, temporal_samples=1
                .replacingOccurrences(of: "estimator_radius=\"[^\"]*\"",
                                      with: "estimator_radius=\"0\"",
                                      options: .regularExpression)
                .replacingOccurrences(of: "supersample=\"[^\"]*\"",
                                      with: "supersample=\"1\"",
                                      options: .regularExpression)
            let sanPath = tmp.appendingPathComponent(name).path
            try sanitized.write(toFile: sanPath, atomically: true, encoding: .utf8)

            // flam3 oracle.
            let flPath = tmp.appendingPathComponent("fl_\(name).png").path
            _ = try Flam3Oracle.renderStatic(
                genomePath: sanPath, outPath: flPath,
                seed: 0, isaacSeed: "emberweftgoldens")

            // Emberweft CPU.
            let flame = try Flam3Parser.parse(Data(sanitized.utf8)).first!
            // Match flam3's geometry (800×592 is the genome's own size; honor it).
            let params = RenderParams(
                seed: 0, width: flame.size.x, height: flame.size.y,
                oversample: 1, samplesPerPixel: 1000)
            let ours = ReferenceRenderer.render(flame: flame, params: params)
            let oracle = try RGBA8Image.readPNG(from: URL(fileURLWithPath: flPath))

            let p = ImageComparison.psnr(ours, oracle)
            let s = ImageComparison.ssim(ours, oracle)
            print("[RealParity] \(name): PSNR=\(p.isInfinite ? "inf" : String(format: "%.2f", p)) dB, "
                  + "SSIM=\(String(format: "%.4f", s))")
            XCTAssertGreaterThanOrEqual(p, 38.0, "\(name): real-genome PSNR \(p) < 38 dB vs flam3")
            XCTAssertGreaterThanOrEqual(s, 0.95,  "\(name): real-genome SSIM \(s) < 0.95 vs flam3")
        }
    }
}
```

- [ ] **Step 3: Run → red (~20 dB).**

- [ ] **Step 4: Implement the fix** identified by Task 5. (This task's exact code depends on the diagnostic; the candidate ranked #1 in `Tools/density_diff.md` is the target. Do NOT close this task until the parity test goes green AND GoldenParity is unchanged — both must hold.)

- [ ] **Step 5: Run → green (≥38 dB).** Re-run GoldenParity to confirm no regression.

- [ ] **Step 6: Commit.** `fix(renderer): close real-genome density-parity gap (≥38 dB vs flam3) + parity gate`

---

## Verification (whole plan)

```bash
make test-fast                                           # mechanics + units, ~2s, 0 failures
swift test --filter TemporalFilterTests                  # box/gaussian weight + delta math
swift test --filter TemporalBlurTests                    # CPU temporal identity + static-blur
swift test --filter TemporalBlurMetalTests               # Metal temporal identity + non-black (sandbox OFF)
swift test --filter FusedUnfusedParityTests              # Metal fused==unfused (temporal=1 unchanged) (sandbox OFF)
swift test --filter GoldenParityTests                    # synthetic goldens still 51–72 dB
swift test --filter RealGenomeParityTests                # NEW: real genomes ≥38 dB vs flam3
# production-quality motion-blurred clip, jump-free:
swift run emberweft animate <2 real sheep> --frames 160 --segments 3 --temporal-samples 32 \
    --quality 500 --size 1280x720 --backend metal --out /tmp/m3_mb
ffmpeg -framerate 30 -i /tmp/m3_mb/%06d.png -c:v libx264 -pix_fmt yuv420p /tmp/m3_mb.mp4 && open /tmp/m3_mb.mp4
```

## Self-review

- **Spec coverage:** #1 (jump) + #2 (motion blur) → Tasks 1–4 (motion blur hides the noise-driven jump; measured boundary PSNR in Task 4 confirms). #3 (production quality q2000) → Task 4 renders at high q + blur (note: full 4-sheep q2000+blur is a long offline job, appropriate for the deferred #5b cache; Task 4 validates on a short clip). #5a (density gap) → Tasks 5–6. #5b explicitly deferred (Background).
- **Placeholders:** Task 6 Step 4 is intentionally conditional on Task 5's diagnostic output (this is an investigation, not a placeholder) — the acceptance criteria (PSNR ≥38 dB + no GoldenParity regression) are concrete and testable regardless of which fix lands.
- **Faithfulness:** `TemporalFilter.samples` returns UN-NORMALIZED weights exactly as flam3 `filters.c:409-450` does (box=1.0 each, gaussian max-normalized to 1.0) + the `sumfilt` scalar. Per-pass `color_scalar` is baked into the dmap (CPU `ChaosGame.iterate(isaacSeed:colorScalar:)`; Metal host-side `buildDmap(... colorScalar:)`) — matching `rect.c:757, 778-782`. The count bucket increments UNWEIGHTED (`rect.c:501-505`), and `k2` carries `sumfilt` (`rect.c:937`). Box sub-passes are byte-identical to single-pass (colorScalar=1.0); CPU↔Metal use the SAME mechanism (dmap-baked colorScalar + sumfilt in k2) so the existing CPU↔Metal statistical-parity gate still holds.
- **CPU↔Metal consistency:** both backends thread `colorScalar` into `buildDmap`; both thread `sumfilt` into `k2`; both use the same per-pass budget split. Box: both pass `colorScalar=1.0` per pass. The Metal path additionally rebuilds `threadSeeds` per pass to avoid RNG correlation (CPU salts the ISAAC seed string per pass for the same reason).
- **Type consistency:** `render(blendAt:centerTime:temporal:sumfilt:params:)` signature is identical on both `ReferenceRenderer` and `MetalRenderer`; `TemporalFilter.samples` returns `([(delta:Double, weight:Double)], Double)` used everywhere; `Quality.temporalSamples/FilterType/FilterWidth/FilterExp` named consistently. `RenderParams.samplesPerPixel` stays `let` (builder `settingSamplesPerPixel` keeps `Sendable`/`Equatable` sound).
- **Bounds/remainders:** Task 2 distributes the integer `samplesPerPixel % N` remainder across the first `rem` passes (exact total budget). Task 3 keeps `perPassThreads` a multiple of `threadsPerGroup` (no dispatch-level remainder).
- **Guards:** Task 3 `fatalError`s on gaussian/exp temporal on Metal (loud, not silent wrong-output). `Histogram.accumulate` precondition-errors on grid mismatch (explicit invariant).
- **CLAUDE.md compliance:** no new dependencies; CPU + Metal deterministic (no `Dictionary`/`Set` float accumulation); Metal `@MainActor` tests annotated; sandbox-off notes for Metal tests; Conventional Commits per task.

## Notes for execution

- **Disable the bash sandbox** for any Metal test/run (`MTLCreateSystemDefaultDevice()` returns nil under it).
- The flam3 oracle is on `$PATH` (`~/.local/bin`); source at `/tmp/flam3` (volatile — if gone, `make bootstrap-oracle` or `Tools/flam3_oracle.sh` rebuilds it).
- **`flam3-render` is env-var-driven** (no `--` flags): `in=<path> out=<path> format=png nthreads=N seed=S isaac_seed=SS qs=Q`. Quality + size come from the genome attrs themselves.
- **Task 4 boundary PSNR:** with `--frames 160 --segments 3` the schedule emits 480 frames: seg 0 (loop A) = 0..159, seg 1 (transition A→B) = 160..319, seg 2 (loop B) = 320..479. Boundary check is 319→320 (transition→loop); within-loop baseline is 100→101 (seg 0).
- Conventional Commits, branch per feature or on `main` (consistent with this week's merges). Each task = one commit.
