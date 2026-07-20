# Real-Genome Motion Blur + Density-Gap Parity — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Emberweft's offline render of real Electric Sheep genomes production-quality and relaxing (motion blur, fixing the transition→loop "jump") and close the real-genome vs-flam3 density-parity gap (≈20 dB → ≥38 dB).

**Architecture:** Motion blur is added as **density-domain temporal accumulation** (porting flam3's `temporal_samples` from `rect.c:754/833`): for each output frame, run `N` chaos sub-passes at sub-times across a ±`temporal_filter_width/2` frame window, each with `samplesPerPixel/N` samples, **accumulate into one histogram** (CPU: sum `Histogram`; Metal: encode N chaos passes into the same `atomicBuf`), then density-estimate + tone-map **once**. This is **cost-neutral** (total samples unchanged) and correct (pre-tone-map accumulation, matching flam3). The density gap is fixed by diagnosing the chaos-game density distribution vs flam3 and correcting it, gated by a real-genome PSNR test.

**Tech Stack:** Swift 6 (Apple Silicon, Metal 4), SwiftPM, XCTest; the flam3 oracle (`flam3-render`/`flam3-genome`/`flam3-animate` on `$PATH` at `~/.local/bin`, source at `/tmp/flam3`/`/tmp/flam3-build`); ffmpeg for muxing.

**User decisions (already made):**
- "Motion blur is necessary to make it more relaxing" — implement it (render-time `temporal_samples`, NOT a video post-process).
- Scope = items #1–#3 (motion blur + production quality) and #5a (density gap). **#5b (pre-rendered video cache + realtime player) is deferred to a later plan.**
- Visual comparison uses the 4 real gen-248 genomes that have working IA official videos: **05739, 31943, 16636, 17549** (official loops in `/tmp/es_official/electricsheep.248.<id>.official.mp4`).

---

## Background (read this first — the plan assumes it)

Emberweft now **renders real ES genomes** after two fixes this week (both committed on `main`):
- **Palette parser** (`22efae49d`): real genomes use `<color index="i" rgb="r g b"/>` (DECIMAL, direct `<flame>` children); the parser had only read `<color>` inside `<palette>` as hex. Fixed + regression tests (`Tests/FlameKitTests/RealGenomePaletteTests.swift`, `Tests/FlameReferenceTests/RealGenomeRenderTests.swift`) + 5 real-genome fixtures at `Tests/Goldens/genomes_real/`.
- **Brightness** (`8a7fa2e9b`): `Quality.brightness` was hardcoded to 4.0; real genomes carry up to ~81. Now parsed + wired into CPU `ToneMapping` + Metal `renderFused` + unfused display. Goldens unchanged (GoldenParity 51–72 dB).

**Current state on real genomes (measured 2026-07-19/20):**
- Real gen-248 genomes render non-black across a diverse survey (60–99% coverage).
- vs-flam3 parity on `00256` (matched params, q500): **PSNR ≈ 20 dB**. Structure/framing are **correct** (identical full-frame bbox; centroids flam3 395,304 vs Emberweft 370,329; mean channel matches 114 vs 108). Gap is the **density tail**: Emberweft is peakier (78.5% vs 93.5% pixels above threshold, same total light).
- **Ruled out as the density cause:** density estimation (`estimator_radius=0` → still 20 dB); `PREFILTER_WHITE` (`#define PREFILTER_WHITE 255` in flam3 `private.h:46` — a constant, so Emberweft's hardcoded 255 is correct); brightness (fixed).
- **The transition→loop "jump"** is NOT a structural bug — consecutive-frame PSNR at the boundary is 14.4 dB vs 15.7 dB within-loop (only ~1 dB worse). The perceived jump is the **uncorrelated Monte-Carlo noise changing abruptly at the genome switch**, which motion blur hides. Confirmed by measuring boundary PSNR with ffmpeg.

**Key flam3 references (motion blur):**
- `rect.c:754` `for (temporal_sample_num = 0; temporal_sample_num < ntemporal_samples; …)` — the temporal loop.
- `rect.c:719` `de_time = spec->time + temporal_deltas[…]` — each sub-pass renders at a sub-time.
- `rect.c:757` `color_scalar = temporal_filter[…]` — each sub-pass weighted by the temporal filter.
- `rect.c:833` `batch_size = nsamples / (nbatches * ntemporal_samples)` — **budget split** (cost-neutral).
- `rect.c:645` `flam3_create_temporal_filter(nbatches*ntemporal_samples, type, exp, width, …)` — builds weights + deltas. Genomes use `temporal_filter_type="box"`, `temporal_filter_width="1.2"`.

**Emberweft render path (both backends):** `emberweft animate` → per frame, `Loop.blend`/`Transition.blend` produce a `Flame` → `MetalRenderer.render` / `ReferenceRenderer.render` (chaos → density-estimation → tone-map). `RenderParams = (seed, width, height, oversample, samplesPerPixel)` (`Sources/FlameKit/RenderTypes.swift:20`). CPU `ChaosGame.iterate(flame:params:) -> Histogram` builds a fresh `Histogram`, accumulating via `hist.colors[idx] += …`, `hist.alpha[idx] += …`, `hist.counts[idx] += 1` (`Sources/FlameReference/ChaosGame.swift:49,242-244`) — so summing M histograms is trivial. Metal chaos dispatches `fp.threadCount` threads using **atomic adds** into `atomicBuf` (`Sources/FlameRenderer/Metal/Kernels.metal:516`; `threadCount` from `MetalHost.buildFrameParams`) — so encoding N chaos passes into the same uncleared `atomicBuf` accumulates correctly.

**Comparison set for final validation:** 4 real gen-248 sheep with official videos —
`genomes/electric-sheep/sheep/gen-248/electricsheep.248.{05739,31943,16636,17549}.flam3`
↔ `/tmp/es_official/electricsheep.248.{05739,31943,16636,17549}.official.mp4` (each ~5.3 s, 648×480, motion-blurred, production quality). Re-download if missing (see Task 4).

---

## File Structure

**Create:**
- `Sources/FlameReference/TemporalFilter.swift` — port of `flam3_create_temporal_filter`: returns `[(delta: Double, weight: Double)]` for N sub-samples across the window. Box (default) + gaussian.
- `Tests/FlameReferenceTests/RealGenomeParityTests.swift` — real-genome vs-flam3 PSNR gate (Task 6; currently ~20 dB, target ≥38).
- `Tools/density_diff.py` — diagnostic: pixel-intensity/alpha density histograms of Emberweft vs flam3 renders (Task 5).

**Modify:**
- `Sources/FlameKit/Genome.swift` — add `temporalSamples`, `temporalFilterType`, `temporalFilterWidth` to `Quality`.
- `Sources/FlameKit/Flam3Parser.swift` — parse `temporal_samples`, `temporal_filter_type`, `temporal_filter_width`.
- `Sources/FlameKit/Flam3Serializer.swift` — emit them (round-trip).
- `Sources/FlameKit/RenderTypes.swift` — add `temporalSamples: Int = 1` to `RenderParams`.
- `Sources/FlameReference/ReferenceRenderer.swift` — add `render(blendAt:centerTime:temporalFilter:params:)`.
- `Sources/FlameReference/ToneMapping.swift` — accept the already-accumulated histogram (no change to its math; called once after temporal accumulation).
- `Sources/FlameRenderer/MetalRenderer.swift` — add `render(blendAt:centerTime:temporalFilter:params:)` (N fused chaos passes → single decode/DE/display).
- `Sources/EmberweftCLI/AnimateCommand.swift` — `--temporal-samples N` flag; build the `blendAt` closure; call the temporal render path when N>1.

---

## Task 1: Parse temporal params + temporal-filter helper + RenderParams

**Goal:** Make the genome's `temporal_samples` / `temporal_filter_type` / `temporal_filter_width` first-class (parsed, modeled, round-tripped) and provide a faithful `temporalFilter(samples:type:width:)` helper.

**Files:**
- Modify: `Sources/FlameKit/Genome.swift` (the `Quality` struct, ~line 111)
- Modify: `Sources/FlameKit/Flam3Parser.swift` (`makeFlame`, ~line 140) + serializer `Sources/FlameKit/Flam3Serializer.swift` (~line 30)
- Modify: `Sources/FlameKit/RenderTypes.swift` (`RenderParams`, line 20)
- Create: `Sources/FlameReference/TemporalFilter.swift`
- Test: `Tests/FlameKitTests/RealGenomePaletteTests.swift` (extend) + `Tests/FlameReferenceTests/TemporalFilterTests.swift` (create)

**Acceptance Criteria:**
- [ ] A real genome with `temporal_samples="1000" temporal_filter_type="box" temporal_filter_width="1.2"` parses to `quality.temporalSamples == 1000`, `.temporalFilterType == .box`, `.temporalFilterWidth == 1.2`.
- [ ] `TemporalFilter.samples(N:type:width:)` for box returns N entries whose weights sum to 1.0 and whose deltas are evenly spaced across `[-width/2, +width/2]` frames.
- [ ] Serializer round-trips the three attrs (`testRoundTripFullFeatures` extended and green).
- [ ] `RenderParams` gains `temporalSamples: Int = 1` (default preserves existing behavior).

**Verify:** `swift test --filter TemporalFilterTests --filter RealGenomePaletteTests --filter SerializerTests` → all pass.

**Steps:**

- [ ] **Step 1: Write the failing tests.**

`Tests/FlameReferenceTests/TemporalFilterTests.swift`:
```swift
import XCTest
@testable import FlameReference
@testable import FlameKit

final class TemporalFilterTests: XCTestCase {
    func testBoxFilterUniformWeightsEvenDeltas() {
        let f = TemporalFilter.samples(4, type: .box, width: 1.2)
        XCTAssertEqual(f.count, 4)
        XCTAssertEqual(f.map(\.weight).reduce(0, +), 1.0, accuracy: 1e-12)          // weights sum to 1
        XCTAssertEqual(f[0].weight, f[1].weight, accuracy: 1e-12)                    // uniform (box)
        // deltas evenly spaced across [-0.6, +0.6], centered (mean ≈ 0)
        let mean = f.map(\.delta).reduce(0, +) / Double(f.count)
        XCTAssertEqual(mean, 0.0, accuracy: 1e-12)
        XCTAssertEqual(f.last!.delta - f.first!.delta, 1.2, accuracy: 1e-12)         // span == width
    }
    func testSingleSampleIsNoBlur() {
        let f = TemporalFilter.samples(1, type: .box, width: 1.0)
        XCTAssertEqual(f.count, 1)
        XCTAssertEqual(f[0].weight, 1.0)
        XCTAssertEqual(f[0].delta, 0.0, accuracy: 1e-12)
    }
}
```

Extend `RealGenomePaletteTests`'s `cases` tuple with an expected `temporalSamples` and assert `flame.quality.temporalSamples` for `00000` (=1000) and `00256` (=1000).

- [ ] **Step 2: Run → fail (TemporalFilter undefined; temporalSamples unset).**

- [ ] **Step 3: Implement.**

`Sources/FlameReference/TemporalFilter.swift`:
```swift
import Foundation

/// Port of flam3's `flam3_create_temporal_filter` (rect.c:645). Produces N
/// (delta, weight) sub-samples across a ±width/2 frame window. delta is in
/// frames (added to the frame's center time); weight scales the sub-pass's
/// histogram contribution. Box = uniform; sum of weights == 1.
public enum TemporalFilter {
    public static func samples(_ n: Int, type: FilterShape, width: Double) -> [(delta: Double, weight: Double)] {
        let n = max(1, n)
        let w = width > 0 ? width : 1.0
        var out: [(delta: Double, weight: Double)] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            // flam3 evenly spaces sub-times across the window, centered: (i+0.5)/n - 0.5
            let delta = ((Double(i) + 0.5) / Double(n) - 0.5) * w
            let weight: Double
            switch type {
            case .gaussian:
                // flam3 gaussian temporal filter (exp); sigma so the window ±w/2 ≈ ±3σ
                let sigma = w / 6.0
                weight = exp(-(delta * delta) / (2 * sigma * sigma))
            case .box:
                weight = 1.0
            }
            out.append((delta: delta, weight: weight))
        }
        let sum = out.map(\.weight).reduce(0, +)
        return out.map { ($0.delta, $0.weight / sum) }   // normalize weights to sum 1
    }
}
```

Add to `Quality` (`Genome.swift`), after `brightness`:
```swift
public var temporalSamples: Int
public var temporalFilterType: FilterShape
public var temporalFilterWidth: Double
```
+ init params `temporalSamples: Int = 1, temporalFilterType: FilterShape = .box, temporalFilterWidth: Double = 1.0` and assignments.

Parse in `Flam3Parser.makeFlame`:
```swift
f.quality.temporalSamples = attr["temporal_samples"].flatMap { Int($0) } ?? 1
f.quality.temporalFilterType = attr["temporal_filter_type"].flatMap { FilterShape(rawValue: $0) } ?? .box
f.quality.temporalFilterWidth = attr["temporal_filter_width"].flatMap { Double($0) } ?? 1.0
```
(FilterShape already exists for the spatial filter; reuse it. If `gaussian`/`box` raw values differ from flam3's `temporal_filter_type` strings, map them.)

Emit in `Flam3Serializer` (only when non-default, to keep genomes compact):
```swift
if f.quality.temporalSamples != 1 { a += " temporal_samples=\"\(f.quality.temporalSamples)\"" }
if f.quality.temporalFilterWidth != 1.0 { a += " temporal_filter_width=\"\(f6(f.quality.temporalFilterWidth))\"" }
```

Add to `RenderParams` (`RenderTypes.swift`): `public let temporalSamples: Int` with init default `temporalSamples: Int = 1`.

- [ ] **Step 4: Run → pass.** `swift test --filter TemporalFilterTests --filter RealGenomePaletteTests --filter SerializerTests`

- [ ] **Step 5: Commit.** `feat(flamekit): parse temporal_samples/filter + TemporalFilter helper (motion-blur prep)`

---

## Task 2: CPU temporal motion blur (density accumulation)

**Goal:** `ReferenceRenderer` can render a motion-blurred frame by accumulating N reduced-sample chaos histograms (one per sub-time) into one histogram, then DE + tone-map once — cost-neutral vs a single-frame render.

**Files:**
- Modify: `Sources/FlameReference/ReferenceRenderer.swift`
- Test: `Tests/FlameReferenceTests/TemporalBlurTests.swift` (create)

**Acceptance Criteria:**
- [ ] `render(blendAt: …, centerTime: t, …, temporalSamples: 1, …)` is byte-identical to `render(flame: blendAt(t), params:)` (no-blur identity).
- [ ] When `blendAt` is constant (returns the same `Flame` G for every sub-time), `render(…, temporalSamples: N, …)` is statistically equivalent to `render(G, params)` — i.e. temporal blur of a static genome == static (verifies budget-split + accumulation; allow Monte-Carlo tolerance).
- [ ] `make test-fast` still green.

**Verify:** `swift test --filter TemporalBlurTests` → pass; `make test-fast` → 0 failures.

**Steps:**

- [ ] **Step 1: Write failing tests.**

```swift
import XCTest
@testable import FlameReference
@testable import FlameKit

final class TemporalBlurTests: XCTestCase {
    func testSingleTemporalSampleMatchesPlainRender() throws {
        let url = URL(fileURLWithPath: "Tests/Goldens/genomes_real/electricsheep.248.00256.flam3")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("fixture missing") }
        let g = try Flam3Parser.parse(Data(contentsOf: url)).first!
        let p = RenderParams(seed: 7, width: 240, height: 180, oversample: 1, samplesPerPixel: 200)
        let plain = ReferenceRenderer.render(flame: g, params: p)
        let blurred = ReferenceRenderer.render(
            blendAt: { _ in g }, centerTime: 0.5,
            temporal: TemporalFilter.samples(1, type: .box, width: 1.0), params: p)
        XCTAssertEqual(blurred.pixels, plain.pixels, "temporalSamples=1 must equal plain render")
    }
    func testStaticBlurEqualsStatic() throws {
        let url = URL(fileURLWithPath: "Tests/Goldens/genomes_real/electricsheep.248.00256.flam3")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("fixture missing") }
        let g = try Flam3Parser.parse(Data(contentsOf: url)).first!
        let p = RenderParams(seed: 7, width: 200, height: 150, oversample: 1, samplesPerPixel: 300)
        let plain = ReferenceRenderer.render(flame: g, params: p)
        // constant blendAt → blur of a static genome == static (same seed, same total samples)
        let blurred = ReferenceRenderer.render(
            blendAt: { _ in g }, centerTime: 0.3,
            temporal: TemporalFilter.samples(8, type: .box, width: 1.2), params: p)
        // compare mean brightness (Monte-Carlo noise differs, but totals match → means ≈)
        let meanA = meanChannel(plain), meanB = meanChannel(blurred)
        XCTAssertEqual(meanB, meanA, accuracy: meanA * 0.05, "static temporal blur should preserve total light")
    }
    private func meanChannel(_ img: RGBA8Image) -> Double {
        var s = 0.0
        for i in stride(from: 0, to: img.pixels.count, by: 4) { s += Double(img.pixels[i] + img.pixels[i+1] + img.pixels[i+2]) }
        return s / Double(img.pixels.count / 4) / 3.0
    }
}
```

- [ ] **Step 2: Run → fail (no `render(blendAt:…)`).**

- [ ] **Step 3: Implement** in `ReferenceRenderer.swift`:
```swift
public static func render(blendAt: (Double) -> Flame, centerTime: Double,
                          temporal: [(delta: Double, weight: Double)], params: RenderParams) -> RGBA8Image {
    let center = blendAt(centerTime)
    // total samples split across temporal sub-passes (cost-neutral, rect.c:833)
    let perPass = max(1, params.samplesPerPixel / max(1, temporal.count))
    var passParams = params
    passParams.samplesPerPixel = perPass   // note: RenderParams.samplesPerPixel is `let`; change to `var`
    var hist: Histogram? = nil
    for (delta, weight) in temporal {
        let g = blendAt(centerTime + delta)
        var sub = ChaosGame.iterate(flame: g, params: passParams)
        sub.scale(by: weight)              // weight this sub-pass (flam3 color_scalar, rect.c:757)
        if hist == nil { hist = sub } else { hist!.accumulate(sub) }
    }
    var h = hist ?? Histogram(gridWidth: 0, gridHeight: 0)
    if center.quality.estimatorRadius > 0 {
        h = DensityEstimation.apply(h, radius: center.quality.estimatorRadius,
            minimum: center.quality.estimatorMinimum, curve: center.quality.estimatorCurveRate)
    }
    return ToneMapping.render(histogram: h, width: params.width, height: params.height,
        oversample: params.oversample, gamma: center.quality.gamma,
        gammaThreshold: center.quality.gammaThreshold, vibrancy: center.quality.vibrancy,
        brightness: center.quality.brightness, sampleDensity: Double(params.samplesPerPixel),
        pixelsPerUnit: center.camera.scale * pow(2, center.camera.zoom))
}
```
Add to `Histogram` (`Sources/FlameKit/RenderTypes.swift`): `mutating func scale(by w: Double)` (multiply colors/alpha/counts elementwise) and `mutating func accumulate(_ other: Histogram)` (elementwise +=). Change `RenderParams.samplesPerPixel` from `let` to `var` (or pass `perPass` via a new internal init — `var` is simplest).

- [ ] **Step 4: Run → pass.** `swift test --filter TemporalBlurTests`

- [ ] **Step 5: Commit.** `feat(reference): CPU temporal motion blur (density accumulation, cost-neutral)`

---

## Task 3: Metal temporal motion blur

**Goal:** `MetalRenderer` renders a motion-blurred frame by encoding N fused chaos passes (one per sub-time genome, `threadCount/N` threads each) into the **same** `atomicBuf`, then a single decode→DE→log→display. Cost-neutral; box filter (uniform weights) so no per-pass weighting needed at the atomic level.

**Files:**
- Modify: `Sources/FlameRenderer/MetalRenderer.swift` (add `render(blendAt:…)`, modeled on `renderFused`)
- Test: `Tests/FlameRendererTests/TemporalBlurMetalTests.swift` (create)

**Acceptance Criteria:**
- [ ] `MetalRenderer.render(blendAt:…, temporal: 1 sample)` == `MetalRenderer.render(flame: blendAt(center), params:)` (identity).
- [ ] `FusedUnfusedParityTests` still passes (fused output unchanged at temporalSamples=1).
- [ ] A 2-sheep Metal render with `--temporal-samples 8` completes without error and is non-black.

**Verify:** `swift test --filter TemporalBlurMetalTests --filter FusedUnfusedParityTests` → pass (sandbox off).

**Steps:**

- [ ] **Step 1: Write failing test** (Metal-gated, `@MainActor`):
```swift
@MainActor func testMetalTemporalSingleSampleMatchesPlain() throws {
    guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
    let url = URL(fileURLWithPath: "Tests/Goldens/genomes_real/electricsheep.248.00256.flam3")
    guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("fixture missing") }
    let g = try Flam3Parser.parse(Data(contentsOf: url)).first!
    let p = RenderParams(seed: 3, width: 200, height: 150, oversample: 1, samplesPerPixel: 200)
    let plain = MetalRenderer.render(flame: g, params: p)
    let blurred = MetalRenderer.render(blendAt: { _ in g }, centerTime: 0.5,
        temporal: TemporalFilter.samples(1, type: .box, width: 1.0), params: p)
    XCTAssertEqual(blurred.pixels, plain.pixels)
}
```

- [ ] **Step 2: Run → fail.**

- [ ] **Step 3: Implement.** Copy `renderFused(flame:params:)` → new `render(blendAt:centerTime:temporal:params:)`. Key changes vs `renderFused`:
  - Build the shared payload (device/library/queue via `fusedPipelines()`; display params; DE params; **`atomicBuf` cleared ONCE**) from the **center** flame.
  - Replace the single chaos encoder (the "Encoder 1: chaosGame" block, ~lines 216-233) with a loop:
```swift
let perPassThreads = max(1, Int(fp.threadCount) / temporal.count)
for (delta, _) in temporal {
    let g = blendAt(centerTime + delta)
    // re-pack g's xforms/final/distrib into buffers (reuse the buf() helper)
    let passXforms = MetalHost.packXforms(g); let passFinal = MetalHost.packFinalXform(g)
    let passDistrib = Flam3XformDistrib.build(g.xforms.map { max(0, $0.weight) })
        .map { UInt32(min($0, max(0, g.xforms.count - 1))) }
    var passFp = fp; passFp.threadCount = UInt32(perPassThreads)
    // encode one chaosGame pass into the SAME atomicBuf (accumulate; do NOT clear between passes)
    guard let enc = cb.makeComputeCommandEncoder() else { throw NSError(domain: "MetalRenderer", code: 13) }
    enc.setComputePipelineState(psos.chaos)
    enc.setBuffer(buf(passXforms), offset: 0, index: 0)       // xforms
    enc.setBuffer(passFinal.map(buf) ?? finalBuf, offset: 0, index: 1)
    enc.setBuffer(buf(passDistrib), offset: 0, index: 2)
    enc.setBuffer(dmapBuf, offset: 0, index: 3); enc.setBuffer(dmapAlphaBuf, offset: 0, index: 4)
    enc.setBuffer(device.makeBuffer(bytes:&passFp, length: MemoryLayout<GPUFrameParams>.stride, options:.storageModeShared)!, offset:0, index:5)
    enc.setBuffer(seedsBuf, offset: 0, index: 6); enc.setBuffer(atomicBuf, offset: 0, index: 7)
    let groups = (perPassThreads + tpg - 1) / tpg
    enc.dispatchThreadgroups(MTLSize(width: groups, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: tpg, height: 1, depth: 1))
    enc.endEncoding()
}
```
  - For the **box** filter (uniform weights) no per-pass scaling is needed (all passes contribute equally; the count is later normalized by `sampleDensity` in tone-mapping). For **gaussian**, scale each pass's `dmapBuf`/`dmapAlphaBuf` by the weight (pre-multiply the palette table) — document this as a follow-up; box is the default and covers these genomes.
  - Keep decode (Encoder 2) → optional DE (Encoder 3) → logDensity → display unchanged, using the center flame's display/DE params. Single commit + waitUntilCompleted + readback.

- [ ] **Step 4: Run → pass** (sandbox off).

- [ ] **Step 5: Commit.** `feat(renderer): Metal temporal motion blur (N fused chaos passes, single tonemap)`

---

## Task 4: `--temporal-samples` in animate + production validation re-render

**USER-ORDERED GATE — NON-SKIPPABLE.** This task was requested by the user in the current conversation. It MUST NOT be closed by walking around it, by declaring it "verified inline", or by substituting a cheaper check. Close only after every item in `acceptanceCriteria` has been re-validated independently, with output captured.

**Goal:** Wire motion blur into `emberweft animate` (`--temporal-samples N`), re-render a real-genome clip at production settings (high q + blur), and **visually verify** the transition→loop jump is gone, the motion is relaxing/smooth, and it is structurally comparable to the 4 official videos.

**Files:**
- Modify: `Sources/EmberweftCLI/AnimateCommand.swift` (render loop, ~lines 182-237)

**Acceptance Criteria:**
- [ ] `emberweft animate … --temporal-samples N` parses N (default 1 = current no-blur behavior; if absent, use the genome's `quality.temporalSamples`).
- [ ] The render loop builds a `blendAt: (Double) -> Flame` closure (Loop/Transition by `mapping.kind`, using `loopCycles`) and calls the temporal render path when N>1.
- [ ] A re-rendered short clip (2 of the 4 sheep, e.g. 05739→31943, `--frames 160 --segments 3 --loop-cycles 1 --temporal-samples 32 --quality 500 --size 1280x720`) is produced at `/tmp/m3_mb.mp4`.
- [ ] **Boundary PSNR check:** consecutive-frame PSNR at the transition→loop boundary is **no longer the global minimum** (i.e. the jump is gone — within ~1 dB of within-loop). Capture the ffmpeg PSNR numbers at the boundary vs within-loop.
- [ ] **Visual check (user):** the clip plays smoothly/relaxingly and each loop is recognizably the same sheep as its official video in `/tmp/es_official/`.

**Verify:** 
```bash
# render
swift run emberweft animate genomes/electric-sheep/sheep/gen-248/electricsheep.248.05739.flam3 \
  genomes/electric-sheep/sheep/gen-248/electricsheep.248.31943.flam3 \
  --frames 160 --segments 3 --loop-cycles 1 --selector sequential --backend metal \
  --size 1280x720 --quality 500 --temporal-samples 32 --seed 42 --out /tmp/m3_mb
ffmpeg -framerate 30 -i /tmp/m3_mb/%06d.png -c:v libx264 -pix_fmt yuv420p /tmp/m3_mb.mp4
# boundary PSNR (seg=160 frames; transition→loop boundary at 320)
cd /tmp/m3_mb && for p in "100 101" "319 320"; do set -- $p; \
  ffmpeg -hide_banner -i $(printf "%06d.png" $1) -i $(printf "%06d.png" $2) -filter_complex psnr -f null - 2>&1 | grep -oE "average:[0-9.]+"; done
```
Expected: the two PSNRs are within ~2 dB (no sharp dip at 319→320), unlike the no-blur preview (was 14.4 at boundary vs 15.7 within). Then `open /tmp/m3_mb.mp4 /tmp/es_official/electricsheep.248.05739.official.mp4` for the user's visual comparison.

**Steps:**

- [ ] **Step 1: Add the flag.** In `AnimateCommand.animate`: add `var temporalSamples = 1`; case `"--temporal-samples"` (parse N; `i += 2`). After loading genomes, if `temporalSamples == 1` default it to `flames[0].quality.temporalSamples` (so a genome with `temporal_samples="1000"` blurs unless overridden) — cap to a sane max (e.g. 64) to bound per-pass overhead.
- [ ] **Step 2: Build the blend closure + branch.** In the render loop, construct:
```swift
let temporal = (temporalSamples > 1)
  ? TemporalFilter.samples(temporalSamples, type: flames[segment.fromSheep].quality.temporalFilterType,
                            width: flames[segment.fromSheep].quality.temporalFilterWidth)
  : [(delta: 0, weight: 1.0)]
func blendAt(_ t: Double) -> Flame {
    switch mapping.kind {
    case .loop:  return Loop.blend(flames[segment.fromSheep], t: t, cycles: loopCycles)
    case .transition: return Transition.blend(flames[segment.fromSheep], flames[segment.toSheep], t: t, stagger: stagger)
    }
}
```
Then render:
```swift
let img: RGBA8Image
if backend == "metal" && temporalSamples > 1 {
    img = MainActor.assumeIsolated { autoreleasepool {
        MetalRenderer.render(blendAt: blendAt, centerTime: mapping.blend, temporal: temporal, params: params) } }
} else if backend == "metal" {
    img = MainActor.assumeIsolated { autoreleasepool { MetalRenderer.render(flame: blendAt(mapping.blend), params: params) } }
} else if temporalSamples > 1 {
    img = ReferenceRenderer.render(blendAt: blendAt, centerTime: mapping.blend, temporal: temporal, params: params)
} else {
    img = ReferenceRenderer.render(flame: blendAt(mapping.blend), params: params)
}
```
(Sub-times are clamped within-segment by `mapping.blend ± delta` staying in [0,1]; `Loop.blend`/`Transition.blend` already clamp/handle t outside [0,1] gracefully — verify they don't crash for t slightly <0 or >1; if they do, clamp `mapping.blend + delta` to [0,1].)

- [ ] **Step 3: Build + smoke** (`swift build`; render a tiny `--frames 4 --segments 2 --temporal-samples 4` to confirm no crash).
- [ ] **Step 4: Render the validation clip + boundary PSNR** (the Verify commands above); capture the numbers.
- [ ] **Step 5: Open the clip + the 2 official videos for the user; record the boundary-vs-within PSNR.**
- [ ] **Step 6: Commit.** `feat(animate): --temporal-samples motion blur + production-quality render path`

If official videos are missing from `/tmp/es_official/`, re-download (they survive only in `/tmp`): the 4 are at `https://archive.org/download/electricsheep-flock-248-<range>-<part>/00248=<id>=<id>=<id>.mp4` where range=`floor(id/10000)…` — see the Background; or rerun the IA scan in the prior session's transcript.

---

## Task 5: Density-gap diagnostic (localize the ≈20 dB)

**Goal:** Determine WHERE Emberweft's density distribution diverges from flam3 on a real genome, so Task 6 has a concrete target. Hypothesis to confirm/refute: Emberweft's chaos histogram is peakier (more density in the core, less in the periphery) than flam3's, at the same total samples.

**Files:**
- Create: `Tools/density_diff.py`

**Acceptance Criteria:**
- [ ] `Tools/density_diff.py` renders `00256` (no blur, matched params: 800×592, oversample=1, `estimator_radius=0`, same seed) both in Emberweft (`emberweft render --backend cpu`) and flam3 (`flam3-render` with `temporal_samples=1`), and prints: (a) pixel-brightness histogram (≥8 buckets) of each, (b) the % of pixels above thresholds {4, 32, 128}, (c) the centroid + active bbox of each.
- [ ] A written finding in the commit message / a `Tools/density_diff.md` note stating: which region (core vs mid vs periphery) differs most, and the ranked candidate causes (chaos sample distribution / DE curve revisit / log-density `k2`-`sampleDensity` normalization / spatial filter).

**Verify:** `python3 Tools/density_diff.py` prints both distributions side-by-side; the note documents the localization.

**Steps:**

- [ ] **Step 1: Write `Tools/density_diff.py`.** Use `flam3-render` (env `format=png w=800 h=592 ncpu=1 quality=1000`, stdin = a sanitized genome with `temporal_samples=1 supersample=1 estimator_radius=0`) for the flam3 side; `swift run emberweft render <sanitized> --backend cpu --size 800x592 --quality 1000` for Emberweft. Use PIL to compute the brightness histograms + thresholds + centroid/bbox (the analysis already prototyped in the prior session — reuse it).
- [ ] **Step 2: Run + read the output.** Expect to confirm Emberweft has fewer mid-brightness pixels (the "thinner periphery" seen at 78.5% vs 93.5%).
- [ ] **Step 3: Rank causes.** Inspect, in order: (1) `ChaosGame.iterate` xform-selection distribution vs flam3 (`flam3.c` `flam3_create_xform_table`/weight normalization); (2) `DensityEstimation.apply` curve vs flam3 even with the same radius (re-enable DE in the diff to see if it amplifies or closes the gap); (3) `k2` and `sampleDensity` in `ToneMapping` (rect.c:935-937) — confirm `area`/`pixelsPerUnit` match; (4) the spatial filter (`flam3SpatialFilterWidth`/radius). Write findings to `Tools/density_diff.md`.
- [ ] **Step 4: Commit.** `tools: density-diff diagnostic for real-genome parity (localizes the ≈20 dB gap)`

---

## Task 6: Fix the density gap + gated real-genome vs-flam3 parity test

**Goal:** Close the localized density difference so real-genome PSNR vs flam3 reaches **≥ 38 dB** (the existing Metal↔CPU gate), and lock it in with a gated parity test across the diverse real fixtures.

**Files:**
- Modify: whatever Task 5 localized (likely `Sources/FlameReference/ChaosGame.swift`, `DensityEstimation.swift`, or `ToneMapping.swift`)
- Create: `Tests/FlameReferenceTests/RealGenomeParityTests.swift`

**Acceptance Criteria:**
- [ ] `RealGenomeParityTests` renders each fixture in `Tests/Goldens/genomes_real/` (CPU, no blur, matched params) vs live `flam3-render` and asserts **PSNR ≥ 38 dB, SSIM ≥ 0.95** (XCTSkip if oracle absent — same F10 contract as the existing animation-parity tests).
- [ ] The test is RED before the fix (~20 dB) and GREEN after.
- [ ] GoldenParity (synthetic) still ≥ 30 dB (no regression); `make test-fast` green.

**Verify:** `swift test --filter RealGenomeParityTests` → PSNR ≥ 38 dB on all fixtures; `swift test --filter GoldenParityTests` → unchanged.

**Steps:**

- [ ] **Step 1: Write the failing parity test** (red — asserts ≥38 dB, currently ~20):
```swift
final class RealGenomeParityTests: XCTestCase {
    func testRealGenomesMatchFlam3() throws {
        try Flam3Oracle.require()   // XCTSkip if oracle absent
        for name in ["electricsheep.248.00038","electricsheep.248.00256","electricsheep.248.00268","electricsheep.248.00084"] {
            // sanitize: temporal_samples=1 supersample=1 estimator_radius=0 → write /tmp/<name>_san.flam3
            // render flam3: flam3-render → /tmp/fl.png ; render Emberweft CPU → /tmp/emb.png (matched 800×592 q1000)
            // compute PSNR/SSIM (reuse the helper in AnimationParityTests / GoldenParityTests)
            XCTAssertGreaterThanOrEqual(psnr, 38.0, "\(name): real-genome vs-flam3 parity")
        }
    }
}
```
(Reuse the PSNR/SSIM helper already in `Tests/FlameReferenceTests/` — see `GoldenParityTests`/`AnimationParityTests`.)
- [ ] **Step 2: Run → red (~20 dB).**
- [ ] **Step 3: Implement the fix** identified by Task 5. (This task's exact code depends on the diagnostic; the candidate ranked #1 in `Tools/density_diff.md` is the target. Do NOT close this task until the parity test goes green AND GoldenParity is unchanged — both must hold.)
- [ ] **Step 4: Run → green (≥38 dB).** Re-run GoldenParity to confirm no regression.
- [ ] **Step 5: Commit.** `fix(renderer): close real-genome density-parity gap (≥38 dB vs flam3) + parity gate`

---

## Verification (whole plan)

```bash
make test-fast                                           # mechanics + units, ~2s, 0 failures
swift test --filter FusedUnfusedParityTests              # Metal fused==unfused (temporal=1 unchanged)
swift test --filter GoldenParityTests                    # synthetic goldens still 51–72 dB
swift test --filter RealGenomeParityTests                # NEW: real genomes ≥38 dB vs flam3
# production-quality motion-blurred clip, jump-free:
swift run emberweft animate <2 real sheep> --frames 160 --segments 3 --temporal-samples 32 --quality 500 --size 1280x720 --backend metal --out /tmp/m3_mb
ffmpeg -framerate 30 -i /tmp/m3_mb/%06d.png -c:v libx264 -pix_fmt yuv420p /tmp/m3_mb.mp4 && open /tmp/m3_mb.mp4
```

## Self-review

- **Spec coverage:** #1 (jump) + #2 (motion blur) → Tasks 1–4 (motion blur hides the noise-driven jump; measured boundary PSNR in Task 4 confirms). #3 (production quality q2000) → Task 4 renders at high q + blur (note: full 4-sheep q2000+blur is a long offline job, appropriate for the deferred #5b cache; Task 4 validates on a short clip). #5a (density gap) → Tasks 5–6. #5b explicitly deferred (Background).
- **Placeholders:** Task 6 Step 3 is intentionally conditional on Task 5's diagnostic output (this is an investigation, not a placeholder) — the acceptance criteria (PSNR ≥38 dB + no GoldenParity regression) are concrete and testable regardless of which fix lands.
- **Type consistency:** `render(blendAt:centerTime:temporal:params:)` signature is identical on both `ReferenceRenderer` and `MetalRenderer`; `TemporalFilter.samples` returns `[(delta:Double, weight:Double)]` used everywhere; `RenderParams.temporalSamples` + `Quality.temporalSamples/FilterType/FilterWidth` named consistently.

## Notes for execution

- Disable the bash sandbox for any Metal test/run (`MTLCreateSystemDefaultDevice()` returns nil under it).
- The flam3 oracle is on `$PATH` (`~/.local/bin`); source at `/tmp/flam3` (volatile — if gone, `make bootstrap-oracle` or `Tools/flam3_oracle.sh` rebuilds it).
- Conventional Commits, branch per feature or on `main` (consistent with this week's merges). Each task = one commit.
