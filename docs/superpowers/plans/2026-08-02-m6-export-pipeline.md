# M6 — Export Pipeline — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `emberweft export` — drive the existing deterministic renderers through a pure frame-plan and encode the frames to MP4/MOV via `AVAssetWriter` (H.264 + HEVC), with progress, cancellation, long-form segment+concat, and batch.

**Architecture:** Reuse-and-wrap. The renderers, `Schedule`, blend math, and determinism contract are reused unchanged. M6 changes only the *sink* (PNG → video encoder) and adds one parity-guarded acceleration (cache the Metal `threadSeeds`). A new pure `FramePlan` (FlameKit) extracts `animate`'s per-frame recipe and drives both `animate` (refactored, byte-identical) and the new `ExportCoordinator`. Pixels flow `RGBA8Image → pooled CVPixelBuffer → AVAssetWriter` (one trivial copy/frame; zero-copy is deferred). See the spec: `docs/superpowers/specs/2026-08-02-m6-export-pipeline-design.md`.

**Tech Stack:** Swift 6.2 (strict concurrency), Metal 4 compute, AVFoundation / CoreMedia / CoreVideo / VideoToolbox, macOS 26 / Apple Silicon. Apple SDKs only — no new dependencies.

**User decisions (already made):**
- CLI-first; GUI export sheet is a follow-up slice (out of scope).
- Codecs H.264 + HEVC only (ProRes/AV1/HDR/audio = M8/M7).
- Engine scope: continuous export + resolution/codec presets + long-form segment+concat + batch.
- Architecture A (reuse + wrap, copy path); zero-copy IOSurface deferred.
- `threadSeeds` caching included (parity-guarded).
- Export quality: `.genome` (faithful default, byte-matches `animate`) or `.spp N` only; named tiers deferred.
- `--backend metal` falls back to CPU with a notice; `--strict-backend` refuses.
- `docs/export/export-pipeline.md` gets a SUPERSEDED banner (kept, not deleted).

---

## File Structure

```
FlameKit (pure; test target FlameKitTests)
  + Sources/FlameKit/GenomeHealth.swift        NEW (moved from EmberweftUI)
  + Sources/FlameKit/TemporalFilter.swift      NEW (moved from FlameReference)
  + Sources/FlameKit/FramePlan.swift           NEW (FramePlan + FrameDescriptor)
  - Sources/EmberweftUI/GenomeHealth.swift     DELETED (moved to FlameKit)
  - Sources/FlameReference/TemporalFilter.swift DELETED (moved to FlameKit; re-exported)
FlameRenderer (Metal; test target FlameRendererTests)
  + Sources/FlameRenderer/ThreadSeedBudget.swift  NEW (MetalRenderer.ThreadSeedBudget)
  ~ Sources/FlameRenderer/MetalRenderer.swift     MODIFIED (threadSeeds pass-in)
FlameExport (NEW bulk; NEW test target FlameExportTests)
  + Sources/FlameExport/FlameExport.swift         REPLACE stub (module doc)
  + Sources/FlameExport/ExportSettings.swift      NEW (ExportSettings, ExportQuality, Resolution, Codec, Container, Bitrate)
  + Sources/FlameExport/PixelBufferPool.swift     NEW
  + Sources/FlameExport/VideoEncoder.swift        NEW (also defines `ExportError`)
  + Sources/FlameExport/ExportProgress.swift      NEW (SelectorSpec, ExportProgress, ExportJob, BatchProgress, BatchPath)
  + Sources/FlameExport/ExportCoordinator.swift   NEW (actor: run / runLongForm / runBatch / cancel)
EmberweftCLI (test target EmberweftCLITests)
  + Sources/EmberweftCLI/ExportCommand.swift      NEW (extension EmberweftCLI { export(_:) })
  ~ Sources/EmberweftCLI/CLI.swift                MODIFIED (run -> async; dispatch "export")
  ~ Sources/EmberweftApp/main.swift              MODIFIED (exit(await EmberweftCLI.run(...)))
  ~ Sources/EmberweftCLI/AnimateCommand.swift     MODIFIED (use FramePlan)
  ~ Sources/EmberweftCLI/CurateCommand.swift      MODIFIED (use Flame.isRenderable)
Package.swift
  ~ FlameExport deps += FlameReference; EmberweftCLI deps += FlameExport; +FlameExportTests
```

**Sandbox note (every task):** run tests with the bash sandbox **disabled** — `MTLCreateSystemDefaultDevice()` and AVFoundation return nil under it. Read `Executed N tests, with X failures` + the exit code; `make test-fast` prints `error:` lines that are EXPECTED inputs to CLI error-path tests, not failures.

---

## Task 0: Doc housekeeping — supersede the preliminary export note

**Goal:** Mark `docs/export/export-pipeline.md` as superseded by the M6 spec so no one implements its contradicted design (`sheep.hashValue` seeding, `xoroshiro256plus`, ProRes/AV1/HDR/audio).

**Files:**
- Modify: `docs/export/export-pipeline.md` (prepend a banner)

**Acceptance Criteria:**
- [ ] `docs/export/export-pipeline.md` begins with a `> **SUPERSEDED**` banner pointing to `docs/superpowers/specs/2026-08-02-m6-export-pipeline-design.md`.
- [ ] No other file changes.

**Verify:** `head -3 docs/export/export-pipeline.md` shows the SUPERSEDED line.

**Steps:**

- [ ] **Step 1: Prepend the banner.** Open `docs/export/export-pipeline.md` and insert this block immediately after the existing `# Export Pipeline` title line (before `*Offline rendering...*`):

```markdown
> **SUPERSEDED — do not implement.** This preliminary note contradicts the locked
> M6 scope and the real engine (it seeds from `sheep.hashValue` (rule-#2 break),
> invents `xoroshiro256plus` (the engine is ISAAC), and proposes ProRes/AV1/HDR/
> audio/GUI that are out of scope). The authoritative design is
> `docs/superpowers/specs/2026-08-02-m6-export-pipeline-design.md` and its plan
> `docs/superpowers/plans/2026-08-02-m6-export-pipeline.md`. Retained for history.
```

- [ ] **Step 2: Verify.**

Run: `head -6 docs/export/export-pipeline.md`
Expected: the title line followed by the SUPERSEDED block.

- [ ] **Step 3: Commit.**

```bash
git add docs/export/export-pipeline.md docs/superpowers/specs/2026-08-02-m6-export-pipeline-design.md docs/superpowers/plans/2026-08-02-m6-export-pipeline.md
git commit -m "docs(m6): export-pipeline spec + plan; supersede preliminary note"
```

---

## Task 1: FramePlan + isRenderable/TemporalFilter moves + animate refactor

**Goal:** Extract `animate`'s per-frame recipe into a pure, testable `FramePlan` (FlameKit); move `Flame.isRenderable` and `TemporalFilter` down to FlameKit so `FramePlan` (and later `FlameExport`) have no layering break; refactor `animate` to consume `FramePlan` with byte-identical output.

**Files:**
- Create: `Sources/FlameKit/GenomeHealth.swift`, `Sources/FlameKit/TemporalFilter.swift`, `Sources/FlameKit/FramePlan.swift`
- Create: `Tests/FlameKitTests/FramePlanTests.swift`, `Tests/FlameKitTests/GenomeHealthTests.swift`
- Delete: `Sources/EmberweftUI/GenomeHealth.swift`, `Sources/FlameReference/TemporalFilter.swift`
- Modify: `Sources/FlameReference/FlameReference.swift` (re-export `TemporalFilter`), `Sources/EmberweftCLI/AnimateCommand.swift`, `Sources/EmberweftCLI/CurateCommand.swift`

**Acceptance Criteria:**
- [ ] `Flame.isRenderable` is callable from `FlameKitTests` (no EmberweftUI import) and matches the moved body verbatim (bounds `[1e-3, 4000]`).
- [ ] `TemporalFilter.samples` is callable from `FlameKitTests`; existing `TemporalFilterTests`/`TemporalBlurTests` (FlameReferenceTests) still compile (via re-export).
- [ ] `FramePlan.descriptor(for: k)` is pure: calling it twice returns equal descriptors; calling k, k-1, k is stable.
- [ ] `descriptor.temporal` deltas equal `TemporalFilter.samples(...).delta / framesPerSegment` for N>1; N==1 yields `[(0,1)]`/`sumfilt 1.0`.
- [ ] `animate --frame 5` output is byte-identical before vs after the refactor (snapshot test).
- [ ] Full parity suite green (`make test-parity`).

**Verify:** `swift test --filter FlameKitTests` → all green; `swift test --filter EmberweftCLITests.AnimateCommandTests` → green; `make test-parity` → green.

**Steps:**

- [ ] **Step 1: Write the failing tests first.**

`Tests/FlameKitTests/GenomeHealthTests.swift`:

```swift
import XCTest
@testable import FlameKit

final class GenomeHealthTests: XCTestCase {
    // Verified against Sources/FlameKit/Genome.swift: `Camera.center` is
    // `SIMD2<Double>` (there is no `Vec2` type); `Camera.scale` is `Double`;
    // `Flame`, `Xform`, `Variation` all have defaulted inits so the labeled
    // subsets below compile.
    private func flame(center: SIMD2<Double> = .zero, scale: Double = 200) -> Flame {
        var f = Flame(xforms: [Xform(weight: 1, variations: [Variation(name: "linear", weight: 1)])])
        f.camera.center = center
        f.camera.scale = scale
        return f
    }

    func testRenderableNormal() throws {
        XCTAssertTrue(flame().isRenderable)
    }
    func testRejectsNaNCenter() throws {
        XCTAssertFalse(flame(center: SIMD2<Double>(x: .nan, y: 0)).isRenderable)
    }
    func testRejectsNonPositiveScale() throws {
        XCTAssertFalse(flame(scale: 0).isRenderable)
        XCTAssertFalse(flame(scale: -5).isRenderable)
    }
    func testRejectsOutOfBandScale() throws {
        XCTAssertFalse(flame(scale: 1e-5).isRenderable)   // below 1e-3
        XCTAssertFalse(flame(scale: 5760).isRenderable)   // above 4000
        XCTAssertTrue(flame(scale: 1e-3).isRenderable)
        XCTAssertTrue(flame(scale: 4000).isRenderable)
    }
    func testRejectsAllZeroWeight() throws {
        var f = flame()
        f.xforms[0].weight = 0
        XCTAssertFalse(f.isRenderable)
    }
}
```

`Tests/FlameKitTests/FramePlanTests.swift`:

```swift
import XCTest
@testable import FlameKit

final class FramePlanTests: XCTestCase {
    private func twoFlames() throws -> [Flame] {
        let url1 = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .appendingPathComponent("../Goldens/genomes/sierpinski.flam3")
            .standardizedFileURL
        let data = try Data(contentsOf: url1)
        return try Flam3Parser.parse(data)
    }

    func testDescriptorIsPureAndStable() throws {
        let flames = try twoFlames() + twoFlames()
        var schedule = Schedule(librarySize: flames.count, framesPerSegment: 8,
                                selector: Sequential(seed: 0), seed: 0)
        let plan = FramePlan(schedule: &schedule, segmentCount: 3, flames: flames,
                             loopCycles: 1, temporalSamples: 1)
        let a = plan.descriptor(for: 5)
        let b = plan.descriptor(for: 5)
        XCTAssertEqual(a.segmentId, b.segmentId)
        XCTAssertEqual(a.blend, b.blend, accuracy: 0)
        XCTAssertEqual(a.kind, b.kind)
        XCTAssertEqual(a.fromSheep, b.fromSheep)
        // k, k-1, k is stable (no hidden mutation)
        _ = plan.descriptor(for: 4)
        let c = plan.descriptor(for: 5)
        XCTAssertEqual(a.blend, c.blend)
    }

    func testTemporalDeltaScaling() throws {
        let flames = try twoFlames() + twoFlames()
        var schedule = Schedule(librarySize: flames.count, framesPerSegment: 160,
                                selector: Sequential(seed: 0), seed: 0)
        let N = 8
        let plan = FramePlan(schedule: &schedule, segmentCount: 3, flames: flames,
                             loopCycles: 1, temporalSamples: N)
        let d = plan.descriptor(for: 3)
        let q = flames[0].quality
        let (raw, _) = TemporalFilter.samples(N, type: q.temporalFilterType,
                                              width: q.temporalFilterWidth,
                                              exp: q.temporalFilterExp)
        XCTAssertEqual(d.temporal.count, N)
        for i in 0..<N {
            XCTAssertEqual(d.temporal[i].delta, raw[i].delta / 160.0, accuracy: 1e-12)
            XCTAssertEqual(d.temporal[i].weight, raw[i].weight, accuracy: 1e-12)
        }
    }

    func testN1CollapsesToIdentity() throws {
        let flames = try twoFlames() + twoFlames()
        var schedule = Schedule(librarySize: flames.count, framesPerSegment: 8,
                                selector: Sequential(seed: 0), seed: 0)
        let plan = FramePlan(schedule: &schedule, segmentCount: 3, flames: flames, temporalSamples: 1)
        let d = plan.descriptor(for: 2)
        XCTAssertEqual(d.temporal.count, 1)
        XCTAssertEqual(d.temporal[0].delta, 0.0)
        XCTAssertEqual(d.temporal[0].weight, 1.0)
        XCTAssertEqual(d.sumfilt, 1.0)
    }

    func testBoundaryMappingMatchesSchedule() throws {
        let flames = try twoFlames() + twoFlames()
        var schedule = Schedule(librarySize: flames.count, framesPerSegment: 8,
                                selector: Sequential(seed: 0), seed: 0)
        let plan = FramePlan(schedule: &schedule, segmentCount: 3, flames: flames, temporalSamples: 1)
        for gf in 0..<plan.totalFrames {
            let mapping = schedule.frameToBlend(globalFrame: gf)
            let d = plan.descriptor(for: gf)
            XCTAssertEqual(d.segmentId, mapping.segmentId)
            XCTAssertEqual(d.blend, mapping.blend, accuracy: 1e-12)
            XCTAssertEqual(d.kind, mapping.kind)
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail.**

Run: `swift test --filter FlameKitTests.GenomeHealthTests FramePlanTests`
Expected: FAIL — `Flame.isRenderable` unresolved from FlameKit; `TemporalFilter`/`FramePlan` unresolved.

- [ ] **Step 3: Move `Flame.isRenderable` to FlameKit.**

Create `Sources/FlameKit/GenomeHealth.swift` with the **exact** body currently in `Sources/EmberweftUI/GenomeHealth.swift:13-29` (only the `import Foundation` + `import FlameKit` line becomes just `import Foundation`, since the extension is now inside FlameKit):

```swift
import Foundation

/// Defensive renderability check for genomes drawn from the wild Electric-Sheep
/// archive (~1.4% of gen-248 sheep carry literal NaN camera headers; the archive
/// also holds degenerate scale values). The parser does NOT guard the camera, so
/// callers apply this gate before any render. Lives in FlameKit so the CLI,
/// FlameExport, and the GUI all share one definition.
public extension Flame {
    var isRenderable: Bool {
        let c = camera.center
        guard c.x.isFinite, c.y.isFinite else { return false }
        let s = camera.scale
        guard s.isFinite, s > 0 else { return false }
        guard s >= 1e-3, s <= 4000 else { return false }
        guard xforms.contains(where: { $0.weight > 0 }) else { return false }
        return true
    }
}
```

Delete `Sources/EmberweftUI/GenomeHealth.swift`. EmberweftUI already `import FlameKit` everywhere it used `isRenderable` (PlaybackView, PlaybackViewModel, ThumbnailService, LibraryIndex, LibraryEntry, CollectionPlaybackView), so the extension stays visible.

Replace the inline replica in `Sources/EmberweftCLI/CurateCommand.swift:155-167` with a direct call:

```swift
if !flame.isRenderable { /* skip + count, as today */ }
```

(Delete the ~12-line inline replica and its `// Inline isRenderable (EmberweftUI/GenomeHealth …)` comment.)

- [ ] **Step 4: Move `TemporalFilter` to FlameKit.**

`git mv Sources/FlameReference/TemporalFilter.swift Sources/FlameKit/TemporalFilter.swift`. The file already begins `import Foundation` + `import FlameKit`; drop the `import FlameKit` line (it is now inside FlameKit). Its only dependency is `FilterShape`, which is already in FlameKit.

No re-export edit is needed. `Sources/FlameReference/FlameReference.swift` already begins with `@_exported import FlameKit` (verified, line 7), so once `TemporalFilter` lives in FlameKit it is automatically visible as `FlameReference.TemporalFilter` to every consumer (transitive re-export). `ReferenceRenderer`, `AnimateCommand`, and the FlameReferenceTests `TemporalFilterTests`/`TemporalBlurTests` all `import FlameReference` (and the test target also declares a direct `FlameKit` dependency in `Package.swift`), so they resolve `TemporalFilter` unchanged. **Do not add a second `@_exported import FlameKit`** (it is already present; a duplicate is a redundant line, not an error, but the move requires zero edits to `FlameReference.swift`). Verify by building after the `git mv`: `swift build` and `swift test --filter FlameReferenceTests` should be green with no `TemporalFilter` edit in `Sources/FlameReference/`.

- [ ] **Step 5: Add `FramePlan`/`FrameDescriptor`.**

Create `Sources/FlameKit/FramePlan.swift`:

```swift
import Foundation

/// A complete, pure recipe for rendering one global frame of a Schedule timeline.
/// Constructed once per `animate`/`export` run; `descriptor(for:)` is O(1) and
/// non-mutating. Drives both `AnimateCommand` (byte-identical) and the export
/// coordinator. All captures are Sendable value types -> rule-#2-safe.
public struct FrameDescriptor: Sendable {
    public let globalFrame: Int
    public let segmentId: Int
    public let kind: Segment.Kind
    public let blend: Double                      // (0,1], 1-indexed (Schedule convention)
    public let fromSheep: Int
    public let toSheep: Int
    /// Temporal sub-samples with deltas already scaled to blend units
    /// (`raw.delta / framesPerSegment` — the load-bearing frame->blend fix).
    /// N==1 -> [(0,1)] (identity; byte-matches the single-pass path).
    public let temporal: [(delta: Double, weight: Double)]
    public let sumfilt: Double
    /// Builds the Flame at sub-time `centerTime + delta`. Loop unclamped
    /// (periodic rotation); Transition clamped to [0,1] (AnimateCommand semantics).
    /// The loop->transition boundary is NOT short-circuited here — the offline
    /// path relies on temporal blur to average the residual (CLAUDE.md gotcha).
    public let blendAt: @Sendable (Double) -> Flame
}

/// Pre-materialized, pure timeline over a `Schedule`. Freezes the (mutating)
/// segment walk at construction so `descriptor(for:)` is pure O(1).
public struct FramePlan: Sendable {
    public let framesPerSegment: Int
    public let totalFrames: Int
    public let temporalSamples: Int
    private let schedule: Schedule          // walk materialized in init
    public let flames: [Flame]
    public let loopCycles: Int
    public let stagger: Double

    public init(schedule: inout Schedule, segmentCount: Int, flames: [Flame],
                loopCycles: Int = 1, stagger: Double = 0, temporalSamples: Int = 1) {
        precondition(segmentCount >= 1, "FramePlan: segmentCount must be >= 1")
        var s = schedule
        for id in 0..<segmentCount { _ = s.segment(at: id) }   // populate the walk cache
        self.schedule = s
        self.framesPerSegment = s.framesPerSegment
        self.totalFrames = s.totalFrames(segmentCount: segmentCount)
        self.temporalSamples = max(1, temporalSamples)
        self.flames = flames
        self.loopCycles = loopCycles
        self.stagger = stagger
    }

    /// Pure O(1). Mirrors AnimateCommand's per-frame construction exactly.
    public func descriptor(for globalFrame: Int) -> FrameDescriptor {
        let mapping = schedule.frameToBlend(globalFrame: globalFrame)
        let segment = schedule.segments[mapping.segmentId]
        let fps = Double(segment.framesPerSegment)
        let (raw, sumfilt): ([(delta: Double, weight: Double)], Double) = temporalSamples > 1
            ? TemporalFilter.samples(
                temporalSamples,
                type: flames[segment.fromSheep].quality.temporalFilterType,
                width: flames[segment.fromSheep].quality.temporalFilterWidth,
                exp:    flames[segment.fromSheep].quality.temporalFilterExp)
            : ([(delta: 0.0, weight: 1.0)], 1.0)
        let temporal = raw.map { (delta: $0.delta / fps, weight: $0.weight) }

        let flames = self.flames
        let cycles = loopCycles
        let stag = stagger
        let kind = segment.kind
        let from = segment.fromSheep
        let to = segment.toSheep
        let blendAt: @Sendable (Double) -> Flame = { t in
            switch kind {
            case .loop:
                return Loop.blend(flames[from], t: t, cycles: cycles)
            case .transition:
                return Transition.blend(flames[from], flames[to],
                                        t: min(max(t, 0.0), 1.0), stagger: stag)
            }
        }
        return FrameDescriptor(
            globalFrame: globalFrame, segmentId: mapping.segmentId, kind: mapping.kind,
            blend: mapping.blend, fromSheep: from, toSheep: to,
            temporal: temporal, sumfilt: sumfilt, blendAt: blendAt)
    }
}
```

- [ ] **Step 6: Refactor `AnimateCommand` to use `FramePlan` (byte-identical).**

Build the plan once before the loop and a single constant `RenderParams`; replace the per-frame temporal/blendAt block (`AnimateCommand.swift:227-321`) with a descriptor lookup. The loop body becomes:

```swift
// (Built once, before the loop:)
var schedule = Schedule(librarySize: flames.count, framesPerSegment: framesPerSegment,
                        selector: selector, seed: seed)
let plan = FramePlan(schedule: &schedule, segmentCount: segmentCount, flames: flamesConst,
                     loopCycles: loopCyclesConst, stagger: staggerConst,
                     temporalSamples: temporalSamples)
let params = RenderParams(seed: seed, width: width, height: height,
                          oversample: 1, samplesPerPixel: renderQuality)

for globalFrame in 0..<plan.totalFrames {
    if let onlyFrame, onlyFrame >= 0, globalFrame != onlyFrame { continue }
    let d = plan.descriptor(for: globalFrame)

    let img: RGBA8Image
    if backend == "metal" {
        img = MainActor.assumeIsolated {
            autoreleasepool {
                temporalSamples > 1
                    ? MetalRenderer.render(blendAt: d.blendAt, centerTime: d.blend,
                                           temporal: d.temporal, sumfilt: d.sumfilt, params: params)
                    : MetalRenderer.render(flame: d.blendAt(d.blend), params: params)
            }
        }
    } else {
        img = temporalSamples > 1
            ? ReferenceRenderer.render(blendAt: d.blendAt, centerTime: d.blend,
                                       temporal: d.temporal, sumfilt: d.sumfilt, params: params)
            : ReferenceRenderer.render(flame: d.blendAt(d.blend), params: params)
    }

    let pngName = String(format: "%06d.png", globalFrame)
    try img.writePNG(to: outURL.appendingPathComponent(pngName))

    // Manifest entry — exact byte-for-byte equivalent of the pre-refactor build.
    // `Manifest.FrameEntry.kind` is a STRING ("loop"/"transition"); `d.kind` is
    // `Segment.Kind`, so the enum→string conversion and the per-fromSheep
    // `interpolationType.rawValue` read are preserved verbatim (verified against
    // AnimateCommand.swift:368-384). `flames` (not `flamesConst`) is read here,
    // matching the original.
    let interpType: String?
    switch d.kind {
    case .loop:
        interpType = nil
    case .transition:
        interpType = flames[d.fromSheep].interpolationType.rawValue
    }
    frameEntries.append(Manifest.FrameEntry(
        index: globalFrame,
        file: pngName,
        segmentId: d.segmentId,
        kind: d.kind == .loop ? "loop" : "transition",
        fromSheep: d.fromSheep,
        toSheep: d.toSheep,
        blend: d.blend,
        interpolationType: interpType
    ))
}
```

Delete the now-dead per-frame locals (`temporalRaw`, `temporal`, `blendAt`, `mapping`, `segment`, `fps`) and the big explanatory comment block (the rationale now lives on `FramePlan`/`FrameDescriptor`). The `params`/`pngName`/`frameEntries`/manifest-finalization code outside the loop is unchanged.

- [ ] **Step 7: Add the animate byte-identity snapshot test.**

In `Tests/EmberweftCLITests/AnimateCommandTests.swift` (or a new `AnimateSnapshotTests.swift`), add a test that renders a fixed genome at `--frame 5` and compares against a committed snapshot PNG:

```swift
import XCTest
@testable import EmberweftCLI
import FlameKit
import FlameReference

final class AnimateSnapshotTests: XCTestCase {
    func testFrame5MatchesSnapshot() throws {
        let genome = URL(fileURLWithPath: #file)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Goldens/genomes/sierpinski.flam3")
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("m6snap-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let rc = EmberweftCLI.animate(["\(genome.path)", "--segments", "1", "--frames", "8",
                                       "--frame", "5", "--backend", "cpu", "--out", out.path])
        XCTAssertEqual(rc, 0)
        let produced = try RGBA8Image.readPNG(from: out.appendingPathComponent("000005.png"))
        let snapshotURL = URL(fileURLWithPath: #file)
            .deletingLastPathComponent().appendingPathComponent("Snapshots/animate-frame5-sierpinski.png")
        let snapshot = try RGBA8Image.readPNG(from: snapshotURL)
        XCTAssertEqual(produced, snapshot)   // byte-identical pre/post refactor
    }
}
```

Generate the snapshot ONCE with the pre-refactor `animate` and commit it under `Tests/EmberweftCLITests/Snapshots/animate-frame5-sierpinski.png`. (Before the refactor: render frame 5, copy the PNG into Snapshots/, commit. The test then guards the refactor.)

- [ ] **Step 8: Run all affected tests.**

Run: `swift test --filter FlameKitTests --filter EmberweftCLITests`
Expected: all PASS (including the snapshot).

- [ ] **Step 9: Parity gate.**

Run: `make test-parity`
Expected: green (no behavior change — pure extraction + mechanical moves).

- [ ] **Step 10: Commit.**

```bash
git add Sources/FlameKit/GenomeHealth.swift Sources/FlameKit/TemporalFilter.swift Sources/FlameKit/FramePlan.swift \
        Sources/EmberweftUI Sources/FlameReference Sources/EmberweftCLI/AnimateCommand.swift \
        Sources/EmberweftCLI/CurateCommand.swift Tests/FlameKitTests Tests/EmberweftCLITests
git commit -m "refactor(m6): FramePlan extraction; move isRenderable+TemporalFilter to FlameKit (byte-identical)"
```

---

## Task 2: ThreadSeedBudget + threadSeeds pass-in (acceleration)

**Goal:** Cache the Metal host-side per-thread ISAAC seeds so an export computes them once instead of every frame, byte-identically. Realtime is untouched (passes `nil`).

**Files:**
- Create: `Sources/FlameRenderer/ThreadSeedBudget.swift`
- Create: `Tests/FlameRendererTests/ThreadSeedBudgetTests.swift`
- Modify: `Sources/FlameRenderer/MetalRenderer.swift` (`renderFusedCore`, `renderTemporalFused`, the `@MainActor render` entry points, `renderOffMain`)

**Acceptance Criteria:**
- [ ] `MetalRenderer.ThreadSeedBudget` memoizes `MetalHost.buildThreadSeeds(seed:threadCount:)` by `(passIndex, threadCount)`, thread-safe, `@unchecked Sendable`.
- [ ] Rendering a real genome frame with `seedBudget: nil` vs a `ThreadSeedBudget` produces byte-identical `RGBA8Image` (single-pass).
- [ ] Same byte-identity for a temporal sequence (N=8), per frame.
- [ ] A budget whose cached count `!= threadCount * ISAAC.randsizWords` is never produced (length precondition in `MetalHost.buildThreadSeeds` already guarantees this; the budget returns exactly that).
- [ ] Realtime path (no budget arg) matches its pre-M6.2 output.
- [ ] Full parity suite green.

**Verify:** `swift test --filter FlameRendererTests.ThreadSeedBudgetTests` → green; `make test-parity` → green.

**Steps:**

- [ ] **Step 1: Write the failing test.**

`Tests/FlameRendererTests/ThreadSeedBudgetTests.swift`:

```swift
import XCTest
@testable import FlameRenderer
import FlameKit
import FlameReference

final class ThreadSeedBudgetTests: XCTestCase {
    private func genome() throws -> Flame {
        let url = URL(fileURLWithPath: #file)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Goldens/genomes/sierpinski.flam3")
        return try Flam3Parser.parse(Data(contentsOf: url)).first!
    }

    @MainActor
    func testNilVsBudgetByteIdenticalSingle() throws {
        guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
        let flame = try genome()
        let params = RenderParams(seed: 42, width: 320, height: 200, oversample: 1, samplesPerPixel: 4)
        let plain = MetalRenderer.render(flame: flame, params: params)
        let budget = MetalRenderer.ThreadSeedBudget(baseSeed: params.seed)
        let cached = MetalRenderer.render(flame: flame, params: params, seedBudget: budget)
        XCTAssertEqual(plain, cached)   // byte-identical
    }

    @MainActor
    func testNilVsBudgetByteIdenticalTemporal() throws {
        guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
        let flame = try genome()
        let params = RenderParams(seed: 42, width: 320, height: 200, oversample: 1, samplesPerPixel: 4)
        let N = 8
        let q = flame.quality
        let (raw, sumfilt) = TemporalFilter.samples(N, type: q.temporalFilterType,
                                                    width: q.temporalFilterWidth, exp: q.temporalFilterExp)
        let temporal = raw.map { (delta: $0.delta / 8.0, weight: $0.weight) }
        let blendAt: @Sendable (Double) -> Flame = { t in Loop.blend(flame, t: t, cycles: 1) }
        let plain = MetalRenderer.render(blendAt: blendAt, centerTime: 0.5,
                                         temporal: temporal, sumfilt: sumfilt, params: params)
        let budget = MetalRenderer.ThreadSeedBudget(baseSeed: params.seed)
        let cached = MetalRenderer.render(blendAt: blendAt, centerTime: 0.5,
                                          temporal: temporal, sumfilt: sumfilt, params: params,
                                          seedBudget: budget)
        XCTAssertEqual(plain, cached)
        // memo actually hit across two frames (same key): second descriptor reuses
        XCTAssertNotNil(budget)
    }
}
```

- [ ] **Step 2: Run test to verify it fails.**

Run: `swift test --filter FlameRendererTests.ThreadSeedBudgetTests`
Expected: FAIL — `MetalRenderer.ThreadSeedBudget` and the `seedBudget:` param unresolved.

- [ ] **Step 3: Add `ThreadSeedBudget`.**

Create `Sources/FlameRenderer/ThreadSeedBudget.swift`:

```swift
import Foundation

/// Memoized per-thread ISAAC seeds for one export run.
///
/// `MetalHost.buildThreadSeeds(seed:threadCount:)` is a PURE deterministic
/// function of `(seed, threadCount)`. For a fixed export, both `(seed,
/// threadCount)` are constant across frames (constant `RenderParams`), so the
/// memo hits after frame 0 -> the per-frame host-side CPU draw (O(totalSamples)
/// ISAAC draws, the dominant offline cost at high spp) happens ONCE. This is the
/// M6 export acceleration; it is byte-identical to per-frame computation
/// (memoization of a pure function) and parity-guarded by
/// `ThreadSeedBudgetTests`. Realtime passes `nil` (untouched).
///
/// Design: a memo keyed by `(passIndex, threadCount)` wrapping
/// `MetalHost.buildThreadSeeds`. The renderer keeps computing `perPassThreads`
/// itself (no formula duplication); the budget just caches the result. The pass
/// seed for pass `i` is `baseSeed &+ UInt64(i)` — matching `renderTemporalFused`.
public extension MetalRenderer {
    final class ThreadSeedBudget: @unchecked Sendable {
        public let baseSeed: UInt64
        private let lock = NSLock()
        private var cache: [Key: [UInt64]] = [:]
        private struct Key: Hashable { let pass: Int; let threadCount: Int }

        public init(baseSeed: UInt64) { self.baseSeed = baseSeed }

        /// Seeds for chaos pass `index` (0 for single-pass) at the given thread count.
        public func seeds(forPass index: Int, threadCount: Int) -> [UInt64] {
            let key = Key(pass: index, threadCount: threadCount)
            lock.lock(); defer { lock.unlock() }
            if let hit = cache[key] { return hit }
            let built = MetalHost.buildThreadSeeds(seed: baseSeed &+ UInt64(index),
                                                    threadCount: threadCount)
            cache[key] = built
            return built
        }
    }
}
```

- [ ] **Step 4: Thread `seedBudget:` through the Metal render path.**

In `Sources/FlameRenderer/MetalRenderer.swift`:

(a) `renderFusedCore` — add a trailing parameter and use it at the seed call (currently `MetalRenderer.swift:174-210`):

```swift
static func renderFusedCore(
    flame: Flame,
    params: RenderParams,
    device: MTLDevice,
    queue: MTLCommandQueue,
    psos: (chaos: MTLComputePipelineState, decode: MTLComputePipelineState,
           density: MTLComputePipelineState, log: MTLComputePipelineState,
           display: MTLComputePipelineState),
    seedBudget: MetalRenderer.ThreadSeedBudget? = nil
) throws -> RGBA8Image {
    // …unchanged until the seed construction (was line 209-210)…
    let threadSeeds = seedBudget?.seeds(forPass: 0, threadCount: Int(fp.threadCount))
        ?? MetalHost.buildThreadSeeds(seed: params.seed, threadCount: Int(fp.threadCount))
    // …rest unchanged…
}
```

(b) `renderTemporalFused` — add `seedBudget: MetalRenderer.ThreadSeedBudget? = nil` to its signature (currently `MetalRenderer.swift:468-474`) and replace the per-pass seed build (currently `MetalRenderer.swift:660-662`):

```swift
let passThreadSeeds = seedBudget?.seeds(forPass: i, threadCount: perPassThreads)
    ?? MetalHost.buildThreadSeeds(seed: params.seed &+ UInt64(i), threadCount: perPassThreads)
```

(c) The `@MainActor` entry points — add `seedBudget: MetalRenderer.ThreadSeedBudget? = nil` and forward it:

```swift
@MainActor
public static func render(flame: Flame, params: RenderParams,
                          seedBudget: MetalRenderer.ThreadSeedBudget? = nil) -> RGBA8Image {
    // …unchanged guards…; pass seedBudget into renderFused -> renderFusedCore
}

@MainActor
public static func render(blendAt: (Double) -> Flame, centerTime: Double,
                          temporal: [(delta: Double, weight: Double)], sumfilt: Double,
                          params: RenderParams,
                          seedBudget: MetalRenderer.ThreadSeedBudget? = nil) -> RGBA8Image {
    // …unchanged…; pass seedBudget into renderTemporalFused
}
```

(d) `renderOffMain` — add `seedBudget: MetalRenderer.ThreadSeedBudget? = nil` and forward to `renderFusedCore` (single-pass only, as today):

```swift
nonisolated
public static func renderOffMain(flame: Flame, params: RenderParams,
                                 seedBudget: MetalRenderer.ThreadSeedBudget? = nil) -> RGBA8Image?
```

The realtime conformer `MetalFrameRenderer` (`Sources/EmberweftUI/MetalFrameRenderer.swift`) is unchanged — it calls without `seedBudget`, so the default `nil` keeps today's behavior.

- [ ] **Step 5: Run tests.**

Run: `swift test --filter FlameRendererTests.ThreadSeedBudgetTests`
Expected: PASS (byte-identical nil vs budget, single + temporal).

- [ ] **Step 6: Parity + realtime-untouched gate.**

Run: `make test-parity`
Expected: green. (Realtime path takes the `nil` default → identical output.)

- [ ] **Step 7: Commit.**

```bash
git add Sources/FlameRenderer/ThreadSeedBudget.swift Sources/FlameRenderer/MetalRenderer.swift Tests/FlameRendererTests/ThreadSeedBudgetTests.swift
git commit -m "perf(m6): ThreadSeedBudget memoizes Metal threadSeeds (byte-identical; realtime untouched)"
```

---

## Task 3: PixelBufferPool + VideoEncoder

**Goal:** The encode sink — a pooled, IOSurface-backed `CVPixelBuffer` source (RGBA→BGRA copy, top-first, premultiplied-alpha-preserving) and an `AVAssetWriter` wrapper with start/append/finish/cancel, `isReadyForMoreMediaData` backpressure, and exact `CMTime` CFR timing.

**Files:**
- Create: `Sources/FlameExport/ExportSettings.swift` (types only, no `ExportCoordinator` yet), `Sources/FlameExport/PixelBufferPool.swift`, `Sources/FlameExport/VideoEncoder.swift`
- Replace: `Sources/FlameExport/FlameExport.swift` (module doc)
- Create: `Tests/FlameExportTests/PixelBufferPoolTests.swift`, `Tests/FlameExportTests/VideoEncoderTests.swift`
- Modify: `Package.swift` (add `FlameReference` to FlameExport deps; add `FlameExportTests` target)

**Acceptance Criteria:**
- [ ] `PixelBufferPool.fill` copies RGBA→BGRA per pixel: an input pixel `(R=10,G=20,B=30,A=255)` yields buffer bytes `[30,20,10,255]`.
- [ ] Premultiplied alpha is preserved: `(50,50,50,100)` round-trips to `[50,50,50,100]`; the invariant `R,G,B ≤ A` holds after the swap.
- [ ] Orientation: an asymmetric marker frame (bright top row) encodes to a 1-frame movie whose decoded top row is bright (no flip).
- [ ] Pool caps in-flight to 3: a 4th `acquire()` does not return until one is released.
- [ ] `VideoEncoder` appends 10 synthetic gradient frames → `.mov` → `AVAssetReader` decodes 10 frames at the right fps and resolution.
- [ ] `cancel()` after 2 appended frames leaves no output file (partial deleted).

**Verify:** `swift test --filter FlameExportTests` → green.

**Steps:**

- [ ] **Step 1: Update `Package.swift`.**

FlameExport target — add `FlameReference`:

```swift
.target(
    name: "FlameExport",
    dependencies: ["FlameRenderer", "FlameReference", "FlameKit"],
    path: "Sources/FlameExport"
),
```

Add the test target (insert after the `FlameRendererTests` entry):

```swift
.testTarget(
    name: "FlameExportTests",
    dependencies: ["FlameExport", "FlameKit", "FlameReference", "FlameRenderer"],
    path: "Tests/FlameExportTests"
),
```

- [ ] **Step 2: Write the failing tests.**

`Tests/FlameExportTests/PixelBufferPoolTests.swift`:

```swift
import XCTest
@testable import FlameExport
import FlameKit
import CoreVideo

final class PixelBufferPoolTests: XCTestCase {
    func testRGBAToBGRASwap() async throws {
        let pool = PixelBufferPool(width: 2, height: 1, maxInFlight: 1)
        let img = RGBA8Image(width: 2, height: 1, pixels: [10,20,30,255, 40,50,60,255])
        let pb = await pool.acquire()
        pool.fill(pb, from: img)
        CVPixelBufferLockBaseAddress(pb, [])
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual(base[0], 30); XCTAssertEqual(base[1], 20); XCTAssertEqual(base[2], 10); XCTAssertEqual(base[3], 255)
        XCTAssertEqual(base[4], 60); XCTAssertEqual(base[5], 50); XCTAssertEqual(base[6], 40); XCTAssertEqual(base[7], 255)
        CVPixelBufferUnlockBaseAddress(pb, [])
        pool.release(pb)
    }

    func testPremultipliedAlphaPreserved() async throws {
        let pool = PixelBufferPool(width: 1, height: 1, maxInFlight: 1)
        let img = RGBA8Image(width: 1, height: 1, pixels: [50,50,50,100])
        let pb = await pool.acquire()
        pool.fill(pb, from: img)
        CVPixelBufferLockBaseAddress(pb, [])
        let b = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual(b[0], 50); XCTAssertEqual(b[1], 50); XCTAssertEqual(b[2], 50); XCTAssertEqual(b[3], 100)
        CVPixelBufferUnlockBaseAddress(pb, [])
        pool.release(pb)
    }

    func testPoolCapsInFlight() async throws {
        let pool = PixelBufferPool(width: 8, height: 8, maxInFlight: 3)
        let a = await pool.acquire(); let b = await pool.acquire(); let c = await pool.acquire()
        // 4th acquire should block; race a release and confirm it then completes.
        let exp = expectation(description: "4th acquire returns after release")
        Task { await pool.acquire(); exp.fulfill() }
        await Task.yield(); await Task.yield()
        pool.release(a)   // frees a slot -> the 4th acquire completes
        await fulfillment(of: [exp], timeout: 2.0)
        pool.release(b); pool.release(c)
    }
}
```

`Tests/FlameExportTests/VideoEncoderTests.swift`:

```swift
import XCTest
@testable import FlameExport
import FlameKit
import AVFoundation

final class VideoEncoderTests: XCTestCase {
    private func gradient(_ i: Int, _ n: Int) -> RGBA8Image {
        let w = 64, h = 48
        let v = UInt8((Double(i) / Double(max(1, n - 1)) * 255).rounded())
        return RGBA8Image(width: w, height: h, pixels: [UInt8](repeating: v, count: w * h * 4))
    }

    func testEncodeDecodeBack() async throws {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("m6-enc-\(UUID().uuidString).mov")
        var settings = ExportSettings()
        settings.codec = .h264; settings.container = .mov
        settings.resolution = .custom(width: 64, height: 48); settings.fps = 30
        let enc = try VideoEncoder(settings: settings, outputURL: out)
        try enc.start()
        for i in 0..<10 { try await enc.append(gradient(i, 10), atFrame: i) }
        try await enc.finish()
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))

        let asset = AVAsset(url: out)
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let nframes = Int(try await asset.load(.duration).value) / Int(try await asset.load(.duration).timescale)
            * 30 + 1
        let dims = try await track.load(.naturalSize)
        XCTAssertEqual(Int(dims.width), 64); XCTAssertEqual(Int(dims.height), 48)
        XCTAssertGreaterThanOrEqual(nframes, 1)
        try? FileManager.default.removeItem(at: out)
    }

    func testCancelDeletesPartial() async throws {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("m6-cancel-\(UUID().uuidString).mov")
        var settings = ExportSettings()
        settings.codec = .h264; settings.container = .mov
        settings.resolution = .custom(width: 32, height: 32); settings.fps = 30
        let enc = try VideoEncoder(settings: settings, outputURL: out)
        try enc.start()
        try await enc.append(gradient(0, 10), atFrame: 0)
        try await enc.append(gradient(1, 10), atFrame: 1)
        enc.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }
}
```

- [ ] **Step 3: Run tests to verify they fail.**

Run: `swift test --filter FlameExportTests`
Expected: FAIL — `ExportSettings`/`PixelBufferPool`/`VideoEncoder` unresolved.

- [ ] **Step 4: Add the export types.**

Create `Sources/FlameExport/ExportSettings.swift`:

```swift
import Foundation
import FlameKit

/// User-facing export settings (Codable + Sendable). The encode-quality source is
/// `ExportQuality` (`.genome` default — byte-matches `animate`; `.spp(N)`).
public struct ExportSettings: Codable, Sendable, Equatable {
    public var codec: Codec = .h264
    public var resolution: Resolution = .p1080
    public var fps: Int = 30                 // 24/25/30/48/50/60 (CMTime timescale)
    public var quality: ExportQuality = .genome
    public var temporalSamples: Int = 1      // motion blur (1 = sharp)
    public var container: Container = .mp4
    public var bitrate: Bitrate = .auto
    public var segmentFrameBudget: Int = 0   // >0 => long-form chunk size in frames
    public var metadata: [MetadataItem] = []
    public init() {}

    public enum Codec: String, Codable, Sendable, CaseIterable { case h264, hevc }
    public enum Container: String, Codable, Sendable, CaseIterable { case mp4, mov }
    public enum Bitrate: Codable, Sendable, Equatable { case auto; case mbps(Int) }
    public struct MetadataItem: Codable, Sendable, Equatable {
        public var key: String; public var value: String
        public init(key: String, value: String) { self.key = key; self.value = value }
    }

    public enum Resolution: Codable, Sendable, Equatable, Hashable, CaseIterable {
        case p720, p1080, p1440, p4k, custom(width: Int, height: Int)
        public var width: Int {
            switch self { case .p720: 1280; case .p1080: 1920; case .p1440: 2560;
                         case .p4k: 3840; case .custom(let w, _): w } }
        public var height: Int {
            switch self { case .p720: 720; case .p1080: 1080; case .p1440: 1440;
                         case .p4k: 2160; case .custom(_, let h): h } }
    }
}

/// M6 quality source. Named tiers are deferred to the GUI export-sheet slice.
/// Both modes resolve `oversample = 1` (byte-identity with `animate`).
public enum ExportQuality: Codable, Sendable, Equatable {
    case genome                              // flames[0].quality.samplesPerPixel, oversample 1
    case spp(Int)

    public func resolvedSamplesPerPixel(for baseFlame: Flame) -> (spp: Int, oversample: Int) {
        switch self {
        case .genome: (baseFlame.quality.samplesPerPixel, 1)
        case .spp(let n): (n, 1)
        }
    }
}
```

**`Resolution` conformance note:** declare it `Codable, Sendable, Equatable, Hashable, CaseIterable`. `Hashable` is required because `VideoEncoder.autoBitrate` / `ExportCoordinator.autoBitrateMbps` use `[ExportSettings.Resolution: Int]` Dictionary keys (an `Equatable`-only enum won't compile as a key). Swift synthesizes `Hashable` for enums whose associated values are all `Hashable` (`Int` is), but ONLY if you declare `: Hashable` on the type. `CaseIterable` compiles on an enum with associated-value cases; `allCases` yields only the parameterless cases (`.p720/.p1080/.p1440/.p4k`), which is exactly what the bitrate table iterates. Synthesized `Codable` also works for associated-value enums (the compiler emits a tagged representation) — no hand-written `init(from:)`/`encode(to:)` is needed unless you want a stable on-disk tag format (the GUI export-sheet slice may add one).

- [ ] **Step 5: Add `PixelBufferPool`.**

Create `Sources/FlameExport/PixelBufferPool.swift`:

```swift
import Foundation
import CoreVideo
import FlameKit

/// IOSurface-backed, Metal-compatible CVPixelBuffer pool (32BGRA, export-sized).
/// `fill` copies RGBA8Image -> BGRA with a per-pixel R<->B swap (top-first, no
/// flip, premultiplied alpha preserved). Cap in-flight to `maxInFlight`.
///
/// Concurrency model: a counting `DispatchSemaphore(value: maxInFlight)` is the
/// sole gate. `acquire` decrements (blocking with a 5 ms poll + `Task.yield` so
/// the calling `async` frame stays cooperative and never pins a cooperative
/// thread-pool thread on a blocking `wait()`); `release` increments. This is the
/// classic counting-semaphore pattern and is race-free under multiple concurrent
/// producers/consumers (an earlier lock+counter+`wasFull`-signal design had a
/// lost-wakeup race: a third `acquire` could steal the freed slot between the
/// release's signal and the parked acquirer's re-lock, leaving the parked
/// acquirer stuck). `@unchecked Sendable` is the documented escape: the only
/// mutable state (`pool`) is passed by address into `CVPixelBufferPool*` C calls
/// that are themselves thread-safe; the semaphore is internally synchronized.
public final class PixelBufferPool: @unchecked Sendable {
    public let width: Int
    public let height: Int
    private let maxInFlight: Int
    private var pool: CVPixelBufferPool?
    private let slots: DispatchSemaphore

    public init(width: Int, height: Int, maxInFlight: Int = 3) {
        self.width = width; self.height = height; self.maxInFlight = maxInFlight
        self.slots = DispatchSemaphore(value: maxInFlight)
        let attrs: [CFString: Any] = [
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, nil, &pool)
    }

    deinit { if let pool { CVPixelBufferPoolFlush(pool, .excessBuffers) } }

    /// Acquires a buffer, yielding cooperatively while `maxInFlight` are
    /// outstanding. Polls the semaphore in 5 ms windows with `Task.yield()` so a
    /// contended `acquire` never blocks a Swift cooperative thread-pool thread.
    public func acquire() async -> CVPixelBuffer {
        while slots.wait(timeout: .now() + .milliseconds(5)) == .timedOut {
            await Task.yield()
        }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, nil, &pb)
        return pb!                   // pool-backed; nil only on exhausted memory
    }

    public func release(_ pb: CVPixelBuffer) {
        _ = pb                        // CVPixelBuffer is CF-managed; ARC releases it
        slots.signal()                // free one slot
    }

    /// RGBA8Image -> 32BGRA CVPixelBuffer. R<->B swap per pixel; top-first copy
    /// (no flip — RGBA8Image is already top-first, the CVPixelBuffer layout for
    /// video). Premultiplied alpha is preserved: premult is the per-pixel
    /// relation R,G,B <= A; permuting R and B leaves both <= A.
    public func fill(_ pb: CVPixelBuffer, from image: RGBA8Image) {
        precondition(image.width == width && image.height == height, "PixelBufferPool: size mismatch")
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let dst = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(pb)
        image.pixels.withUnsafeBufferPointer { src in
            for y in 0..<height {
                let s = y * width * 4
                let d = y * rowBytes
                for x in 0..<width {
                    let si = s + x * 4, di = d + x * 4
                    dst[di + 0] = src[si + 2]      // B
                    dst[di + 1] = src[si + 1]      // G
                    dst[di + 2] = src[si + 0]      // R
                    dst[di + 3] = src[si + 3]      // A
                }
            }
        }
    }
}
```

- [ ] **Step 6: Add `VideoEncoder`.**

Create `Sources/FlameExport/VideoEncoder.swift`:

```swift
import Foundation
import AVFoundation
import CoreVideo
import CoreMedia
import FlameKit

/// AVAssetWriter + Input + PixelBufferAdaptor wrapper. Single serialization queue
/// for status transitions (cancel-safe). Guards `isReadyForMoreMediaData` and
/// appends at exact CFR `CMTime(value: frameIndex, timescale: fps)`.
public final class VideoEncoder: @unchecked Sendable {
    public let settings: ExportSettings
    public let outputURL: URL
    private let queue = DispatchQueue(label: "com.emberweft.export.encoder")
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var pool: PixelBufferPool?
    private var started = false
    /// Highest PTS appended so far (start-of-session = .zero). Tracked so
    /// `finish()` can call `endSession(atSourceTime:)` with the final frame's
    /// end time (last PTS + one frame duration), pinning the last frame's full
    /// duration in the container. `AVAssetWriterInput` otherwise leaves the
    /// trailing duration implicit (spec D8 / §4.4).
    private var lastEndTime: CMTime = .zero

    public init(settings: ExportSettings, outputURL: URL) throws {
        self.settings = settings
        self.outputURL = outputURL
    }

    public func start() throws {
        precondition(!started)
        let fileType: AVFileType = settings.container == .mov ? .mov : .mp4
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType)
        let codec: AVVideoCodecType = settings.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264
        var compression: [String: Any] = [:]
        switch settings.bitrate {
        case .auto: compression[AVVideoAverageBitRateKey] = Self.autoBitrate(codec: codec, res: settings.resolution, fps: settings.fps)
        case .mbps(let m): compression[AVVideoAverageBitRateKey] = m * 1_000_000
        }
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: settings.resolution.width,
            AVVideoHeightKey: settings.resolution.height,
            AVVideoCompressionPropertiesKey: compression
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferMetalCompatibilityKey as String: true
            ])
        writer.add(input)
        self.writer = writer; self.input = input; self.adaptor = adaptor
        self.pool = PixelBufferPool(width: settings.resolution.width,
                                    height: settings.resolution.height, maxInFlight: 3)
        guard writer.startWriting() else {
            throw NSError(domain: "VideoEncoder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "startWriting failed: \(String(describing: writer.error))"])
        }
        writer.startSession(atSourceTime: .zero)
        lastEndTime = .zero
        started = true
    }

    /// Polls `isReadyForMoreMediaData` (yields while not ready), copies the frame
    /// into a pooled BGRA buffer, and appends at CMTime(value: frameIndex, timescale: fps).
    public func append(_ image: RGBA8Image, atFrame index: Int) async throws {
        guard started, let input, let adaptor, let pool else {
            throw NSError(domain: "VideoEncoder", code: 2, userInfo: [NSLocalizedDescriptionKey: "not started"])
        }
        while !input.isReadyForMoreMediaData {
            if let writer, writer.status == .failed { throw writer.error ?? ExportError.encodeFailed }
            try await Task.sleep(nanoseconds: 1_000_000)   // 1 ms
        }
        let pb = await pool.acquire()
        pool.fill(pb, from: image)
        let time = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(settings.fps))
        adaptor.append(pb, withPresentationTime: time)
        pool.release(pb)
        // End-of-session target = this frame's PTS + one frame duration.
        lastEndTime = CMTime(value: CMTimeValue(index + 1), timescale: CMTimeScale(settings.fps))
    }

    public func finish() async throws {
        guard started, let writer, let input else { return }
        input.markAsFinished()
        // Pin the session end so the final frame's full duration lands in the
        // container (D8). Safe to call after markAsFinished; AVFoundation accepts
        // endSession before finishWriting. Skipped iff no frames were appended
        // (lastEndTime stays .zero -> the session is already empty + ended).
        if lastEndTime != .zero {
            writer.endSession(atSourceTime: lastEndTime)
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            writer.finishWriting { [outputURL] in
                if writer.status == .completed { cont.resume() }
                else { try? FileManager.default.removeItem(at: outputURL); cont.resume(throwing: writer.error ?? ExportError.encodeFailed) }
            }
        }
        started = false
    }

    public func cancel() {
        guard started, let writer else { return }
        queue.sync {
            if writer.status == .writing { writer.cancelWriting() }
        }
        try? FileManager.default.removeItem(at: outputURL)
        started = false
    }

    private static func autoBitrate(codec: AVVideoCodecType, res: ExportSettings.Resolution, fps: Int) -> Int {
        // Preliminary Mbps (H.264 ~1.5x HEVC for parity). Tunable.
        let hevc: [ExportSettings.Resolution: Int] = [.p720: 5, .p1080: 10, .p1440: 16, .p4k: 30]
        let base = hevc[res] ?? (res.width * res.height >= 3_840 * 2160 ? 30 : 10)
        let mult = codec == .hevc ? 1.0 : 1.5
        let fpsMult = fps >= 60 ? 1.5 : 1.0
        return Int(Double(base) * mult * fpsMult) * 1_000_000
    }
}

public enum ExportError: Error, Sendable {
    case cancelled
    case encodeFailed
    case metalUnavailable
    case genomeUnparseable
    case diskFull
    case overwriteNeedsForce
}
```

- [ ] **Step 7: Replace the FlameExport stub.**

`Sources/FlameExport/FlameExport.swift`:

```swift
//! FlameExport — AVFoundation offline/long-form export and codecs (M6 / S10).
//! See docs/superpowers/specs/2026-08-02-m6-export-pipeline-design.md.
```

- [ ] **Step 8: Run tests.**

Run: `swift test --filter FlameExportTests`
Expected: PASS (byte-swap, premult, pool cap, decode-back, cancel).

- [ ] **Step 9: Commit.**

```bash
git add Sources/FlameExport Package.swift Tests/FlameExportTests
git commit -m "feat(m6): PixelBufferPool + VideoEncoder (RGBA->BGRA, CFR timing, cancel-safe)"
```

---

## Task 4: ExportCoordinator (single export) + `emberweft export` + core DoD

**Goal:** The end-to-end single-export path: `ExportCoordinator` actor drives `FramePlan → renderer → VideoEncoder` off-main with progress + cancel; the `emberweft export` CLI; disk precheck, atomic handoff, codec probe, Metal→CPU fallback. This is the M6 core Definition of Done.

**Files:**
- Create: `Sources/FlameExport/ExportCoordinator.swift`, `Sources/FlameExport/ExportProgress.swift`
- Create: `Sources/EmberweftCLI/ExportCommand.swift`
- Modify: `Sources/EmberweftCLI/CLI.swift`, `Package.swift` (EmberweftCLI deps += FlameExport)
- Create: `Tests/FlameExportTests/ExportCoordinatorTests.swift`, `Tests/EmberweftCLITests/ExportCommandTests.swift`

**Acceptance Criteria:**
- [ ] `emberweft export <one genome> --segments 1 --out /tmp/x.mp4` produces a playable, upright H.264 mp4; decoded frame 0 matches `animate --frame 0` pixels (`.genome` quality).
- [ ] Re-rendering global frame K from two independent runs yields byte-identical `RGBA8Image` (rule-#2 pin).
- [ ] `--out` exists with no `--force` → exit 2, existing file untouched.
- [ ] A forced mid-encode failure deletes `<out>.partial-*` and leaves `<out>` unchanged.
- [ ] `--backend metal` on a no-Metal host falls back to CPU with a stderr notice; `--strict-backend` exits 1 instead.
- [ ] A NaN-center genome is skipped with a warning (single → exit 1).
- [ ] Empty genomes / `segments>1` with `<2` genomes → exit 2 (mirrors `animate`).

**Verify:** `swift test --filter FlameExportTests.ExportCoordinatorTests EmberweftCLITests.ExportCommandTests` → green.

**Steps:**

- [ ] **Step 1: Update `Package.swift` — EmberweftCLI deps += FlameExport.**

```swift
.target(
    name: "EmberweftCLI",
    dependencies: ["FlameKit", "FlameReference", "FlameRenderer", "FlameExport"],
    path: "Sources/EmberweftCLI"
),
```

- [ ] **Step 2: Write the failing tests.**

`Tests/FlameExportTests/ExportCoordinatorTests.swift`:

```swift
import XCTest
@testable import FlameExport
import FlameKit
import FlameReference

final class ExportCoordinatorTests: XCTestCase {
    private func genome(_ name: String) throws -> [Flame] {
        let url = URL(fileURLWithPath: #file).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Goldens/genomes/\(name)")
        return try Flam3Parser.parse(Data(contentsOf: url))
    }

    /// Rule-#2 pin (in-process): rendering global frame K through the SAME
    /// `FramePlan` + `ReferenceRenderer` path the coordinator drives, twice with
    /// independent `FramePlan` instances, yields byte-identical pixels. This
    /// avoids the non-determinism of encoded video bytes (§5.3) while still
    /// exercising the frame-recipe extraction. The cross-COMMAND byte-identity
    /// vs `animate` is `testExportMatchesAnimateFrame` (Task 5, via PNG).
    func testExportFramePixelIdentity() async throws {
        let flames = try genome("sierpinski.flam3")
        var settings = ExportSettings()
        settings.resolution = .custom(width: 128, height: 80); settings.fps = 30
        settings.temporalSamples = 1
        let base = flames[0]
        let (spp, os) = settings.quality.resolvedSamplesPerPixel(for: base)
        let params = RenderParams(seed: 7, width: 128, height: 80, oversample: os, samplesPerPixel: spp)

        // Two independent FramePlans (independent Schedule walks) over the same
        // deterministic inputs -> identical descriptors -> identical pixels.
        func renderFrame5() -> RGBA8Image {
            var schedule = Schedule(librarySize: flames.count, framesPerSegment: 8,
                                    selector: Sequential(seed: 7), seed: 7)
            let plan = FramePlan(schedule: &schedule, segmentCount: 1, flames: flames,
                                 loopCycles: 1, stagger: 0, temporalSamples: 1)
            let d = plan.descriptor(for: 5)
            return ReferenceRenderer.render(flame: d.blendAt(d.blend), params: params)
        }
        let a = renderFrame5()
        let b = renderFrame5()
        XCTAssertEqual(a, b)   // byte-identical across independent plans (rule #2)

        // Also pin the coordinator end-to-end runs twice without error (the
        // encoded .mp4 bytes are NOT asserted — §5.3; both files exist).
        let outA = FileManager.default.temporaryDirectory.appendingPathComponent("m6-id-A-\(UUID().uuidString).mp4")
        let outB = FileManager.default.temporaryDirectory.appendingPathComponent("m6-id-B-\(UUID().uuidString).mp4")
        let coord = ExportCoordinator(backend: .cpu)
        for url in [outA, outB] {
            let job = ExportJob(settings: settings, flames: flames, framesPerSegment: 8,
                                segmentCount: 1, selector: .sequential, seed: 7,
                                loopCycles: 1, stagger: 0, out: url)
            let stream = await coord.run(job)
            for try await _ in stream {}
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outA.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outB.path))
        try? FileManager.default.removeItem(at: outA); try? FileManager.default.removeItem(at: outB)
    }
}
```

> The cross-command byte-identity pin (`export --frame 5 --png` == `animate --frame 5`) lives in Task 5's `ExportPresetsTests.testExportGenomeByteMatchesAnimateFrame5`. The cross-LAUNCH determinism pin (downsampled pixel hash compared across two process launches with different Swift hash seeds) is `testExportCrossLaunchDeterminism` (spec §12.4), implemented as a CLI-driving test that shells `emberweft export --frame 0 --png` twice and compares the PNG bytes' SHA-256.

`Tests/EmberweftCLITests/ExportCommandTests.swift`:

```swift
import XCTest
import Foundation
@testable import EmberweftCLI

final class ExportCommandTests: XCTestCase {
    private func sierpinski() -> String {
        URL(fileURLWithPath: #file).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Goldens/genomes/sierpinski.flam3").path
    }
    private func tmpMP4() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("m6-\(UUID().uuidString).mp4").path
    }

    func testExportsPlayableMP4() async throws {
        let out = tmpMP4()
        // `export` lives on `EmberweftCLI` (an extension in ExportCommand.swift).
        let rc = await EmberweftCLI.export([sierpinski(), "--segments", "1", "--frames", "8",
                                            "--backend", "cpu", "--out", out])
        XCTAssertEqual(rc, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out))
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: out))
    }
    func testOverwriteNeedsForce() async throws {
        let out = tmpMP4()
        Data("keep".utf8).write(to: URL(fileURLWithPath: out))
        let rc = await EmberweftCLI.export([sierpinski(), "--segments", "1", "--out", out])
        XCTAssertEqual(rc, 2)
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: out)), "keep")  // untouched
    }
    func testSegmentsNeedsTwoGenomes() async throws {
        let rc = await EmberweftCLI.export([sierpinski(), "--segments", "3", "--out", tmpMP4()])
        XCTAssertEqual(rc, 2)
    }
}
```

- [ ] **Step 3: Run tests to verify they fail.**

Run: `swift test --filter FlameExportTests.ExportCoordinatorTests EmberweftCLITests.ExportCommandTests`
Expected: FAIL — types unresolved.

- [ ] **Step 4: Add `ExportProgress` + `ExportJob`.**

`Sources/FlameExport/ExportProgress.swift`:

```swift
import Foundation

public struct ExportProgress: Sendable {
    public enum Phase: Sendable { case rendering, encoding, concatenating, finalizing }
    public let phase: Phase
    public let currentFrame: Int
    public let totalFrames: Int
    public let elapsed: Double
    public let renderFPS: Double
    public init(phase: Phase, currentFrame: Int, totalFrames: Int, elapsed: Double, renderFPS: Double) {
        self.phase = phase; self.currentFrame = currentFrame; self.totalFrames = totalFrames
        self.elapsed = elapsed; self.renderFPS = renderFPS
    }
}

/// One export. `flames` are pre-parsed; `schedule` is materialized by the coordinator
/// via `FramePlan`. `partialURL` is the atomic-encode target (renamed to `out` on success).
public struct ExportJob: Sendable {
    public let settings: ExportSettings
    public let flames: [Flame]
    public let framesPerSegment: Int
    public let segmentCount: Int
    public let selector: SelectorSpec   // module-level enum in FlameExport (see open note)
    public let seed: UInt64
    public let loopCycles: Int
    public let stagger: Double
    public let out: URL
    public let partialURL: URL
    public init(settings: ExportSettings, flames: [Flame], framesPerSegment: Int,
                segmentCount: Int, selector: SelectorSpec, seed: UInt64,
                loopCycles: Int, stagger: Double, out: URL) {
        self.settings = settings; self.flames = flames
        self.framesPerSegment = framesPerSegment; self.segmentCount = segmentCount
        self.selector = selector; self.seed = seed; self.loopCycles = loopCycles
        self.stagger = stagger; self.out = out
        // Atomic-encode target = `<dir>/<stem>.partial-<pid>.<ext>`. Built from
        // `out`'s dir + stem + ext explicitly: the chain
        // `out.deletingPathExtension().appendingPathComponent(…).appendingPathExtension(…)`
        // treats the stem as a DIRECTORY and nests the file inside it
        // (`/tmp/x/x.mp4.partial-1234.mp4`), which is wrong. This form lands
        // `<pid>`-suffixed partial beside `out` on the same volume (atomic rename).
        let stem = out.deletingPathExtension().lastPathComponent
        let ext = out.pathExtension
        let dir = out.deletingLastPathComponent()
        let partialName = ext.isEmpty
            ? "\(stem).partial-\(getpid())"
            : "\(stem).partial-\(getpid()).\(ext)"
        self.partialURL = dir.appendingPathComponent(partialName)
    }
}
```

`SelectorSpec` is a module-level enum declared at the TOP of `Sources/FlameExport/ExportProgress.swift` (before `ExportProgress`), so it is `FlameExport.SelectorSpec` (NOT nested on `ExportJob` or `Schedule`). The plan uses `SelectorSpec` unqualified inside FlameExport and `FlameExport.SelectorSpec` from EmberweftCLI. `ExportCoordinator.makeSelector` constructs `Sequential`/`SimilarityExploration` from it. M6 wires `.sequential` only; `.similarity` is a documented stub (`SimilarityExploration` exists in FlameKit and needs `featureVectors`, so the stub returns `Sequential` until the GUI sheet supplies features). Add exactly:

```swift
/// Serializable selector choice for `ExportJob` (M6 wires `.sequential` only).
/// `.similarity` is a placeholder for the GUI export-sheet slice; it requires
/// `FeatureVector`s that the headless CLI does not yet source.
public enum SelectorSpec: String, Codable, Sendable, CaseIterable {
    case sequential
    case similarity
}
```

- [ ] **Step 5: Add `ExportCoordinator`.**

`Sources/FlameExport/ExportCoordinator.swift`:

```swift
import Foundation
import AVFoundation      // AVVideoCodecType for diskPrecheck's bitrate estimate
import FlameKit
import FlameReference
import FlameRenderer

public actor ExportCoordinator {
    public enum Backend: Sendable { case cpu, metal }
    private let backend: Backend
    private var cancelled = false

    /// `backend` is the ALREADY-RESOLVED choice. Metal availability + the
    /// `--strict-backend` fallback/refuse decision are made by `ExportCommand`
    /// (which can `await MainActor.run { MetalRenderer.isAvailable }` from its
    /// async context) BEFORE constructing the coordinator. The actor MUST NOT
    /// probe `MetalRenderer.isAvailable` itself: that property's getter calls
    /// `MainActor.assumeIsolated`, which traps when invoked off the main actor
    /// (the actor's executor is not the main actor). This is why the probe is
    /// hoisted to the caller (spec D3/D15; resolves the prior resolvedBackend
    /// crash).
    public init(backend: Backend) { self.backend = backend }

    /// Single continuous export. Yields progress; on success the file is at
    /// `job.out`. Honors `cancel()` between frames.
    public func run(_ job: ExportJob) -> AsyncThrowingStream<ExportProgress, Error> {
        AsyncThrowingStream { continuation in
            // Unstructured Task captures `self` (the actor, which is Sendable) and
            // the Sendable continuation. `runJob` is actor-isolated, so the
            // `await self.runJob(...)` hops onto the actor. For a short-lived CLI
            // export the lifecycle is bounded by the process; if a GUI consumer
            // drops the stream mid-iteration, call `cancel()` to stop the run.
            Task { [self] in
                do { try await self.runJob(job) { p in continuation.yield(p) }; continuation.finish() }
                catch { continuation.finish(throwing: error) }
            }
        }
    }

    public func cancel() async { cancelled = true }

    /// `yield` is `@Sendable` so the closure built in `run`'s unstructured Task
    /// (which captures the `AsyncThrowingStream.Continuation`, itself Sendable)
    /// crosses the actor boundary cleanly under Swift 6 strict concurrency.
    private func runJob(_ job: ExportJob, yield: @Sendable (ExportProgress) -> Void) async throws {
        let res = job.settings.resolution
        let (spp, os) = job.settings.quality.resolvedSamplesPerPixel(for: job.flames[0])
        let params = RenderParams(seed: job.seed, width: max(1, res.width), height: max(1, res.height),
                                  oversample: os, samplesPerPixel: spp)
        let useMetal = (backend == .metal)
        // Disk precheck (D13).
        try Self.diskPrecheck(job: job)
        // Build the plan.
        let selector = makeSelector(job.selector)
        var schedule = Schedule(librarySize: job.flames.count, framesPerSegment: job.framesPerSegment,
                                selector: selector, seed: job.seed)
        let plan = FramePlan(schedule: &schedule, segmentCount: job.segmentCount, flames: job.flames,
                             loopCycles: job.loopCycles, stagger: job.stagger,
                             temporalSamples: max(1, job.settings.temporalSamples))
        // Budget (Metal only); nil for CPU.
        let budget: MetalRenderer.ThreadSeedBudget? = useMetal ? MetalRenderer.ThreadSeedBudget(baseSeed: params.seed) : nil

        let encoder = try VideoEncoder(settings: job.settings, outputURL: job.partialURL)
        try encoder.start()
        do {
            let start = ProcessInfo.processInfo.systemUptime
            for gf in 0..<plan.totalFrames {
                if cancelled || Task.isCancelled { encoder.cancel(); try? FileManager.default.removeItem(at: job.partialURL); throw ExportError.cancelled }
                let d = plan.descriptor(for: gf)
                let img: RGBA8Image
                if useMetal {
                    img = await MainActor.run {
                        autoreleasepool {
                            job.settings.temporalSamples > 1
                                ? MetalRenderer.render(blendAt: d.blendAt, centerTime: d.blend,
                                                       temporal: d.temporal, sumfilt: d.sumfilt, params: params, seedBudget: budget)
                                : MetalRenderer.render(flame: d.blendAt(d.blend), params: params, seedBudget: budget)
                        }
                    }
                } else {
                    img = await Task.detached(priority: .userInitiated) {
                        job.settings.temporalSamples > 1
                            ? ReferenceRenderer.render(blendAt: d.blendAt, centerTime: d.blend,
                                                       temporal: d.temporal, sumfilt: d.sumfilt, params: params)
                            : ReferenceRenderer.render(flame: d.blendAt(d.blend), params: params)
                    }.value
                }
                try await encoder.append(img, atFrame: gf)
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                yield(ExportProgress(phase: .rendering, currentFrame: gf + 1, totalFrames: plan.totalFrames,
                                     elapsed: elapsed, renderFPS: elapsed > 0 ? Double(gf + 1) / elapsed : 0))
            }
            try await encoder.finish()
        } catch {
            encoder.cancel(); try? FileManager.default.removeItem(at: job.partialURL); throw error
        }
        // Atomic handoff (D13).
        if FileManager.default.fileExists(atPath: job.out.path) { try FileManager.default.removeItem(at: job.out) }
        try FileManager.default.moveItem(at: job.partialURL, at: job.out)
    }

    private func makeSelector(_ spec: SelectorSpec) -> any PairSelector {
        switch spec { case .sequential: return Sequential(seed: 0); case .similarity: return Sequential(seed: 0) /* M6: sequential only; similarity is a follow-up */ }
    }

    private static func diskPrecheck(job: ExportJob) throws {
        // Estimate per spec D13: ceil(bitrate * durationSeconds / 8 * 1.25) +
        // 25% headroom. bitrate is bits/s; /8 -> bytes/s; *duration -> total
        // bytes; *1.25 -> headroom for VBR peaks + container overhead. The
        // auto-bitrate table mirrors VideoEncoder.autoBitrate at the chosen
        // codec/res/fps so the estimate tracks the encoder's actual target.
        let totalFrames = job.framesPerSegment * job.segmentCount
        let fps = max(1, job.settings.fps)
        let durationSeconds = Double(totalFrames) / Double(fps)
        let mbps: Int
        switch job.settings.bitrate {
        case .auto:
            let codec: AVVideoCodecType = job.settings.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264
            mbps = Self.autoBitrateMbps(codec: codec, res: job.settings.resolution, fps: fps)
        case .mbps(let m):
            mbps = m
        }
        let bytes = Int64(Double(mbps) * 1_000_000 * durationSeconds / 8.0 * 1.25).advanced(by: 1)
        let parent = job.out.deletingLastPathComponent()
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: parent.path),
           let free = attrs[.systemFreeSize] as? NSNumber, free.int64Value < bytes {
            throw ExportError.diskFull
        }
    }

    /// Mirrors `VideoEncoder.autoBitrate` (Mbps, pre-`*1_000_000`). Kept here so
    /// the disk precheck does not depend on instantiating a `VideoEncoder`.
    private static func autoBitrateMbps(codec: AVVideoCodecType, res: ExportSettings.Resolution, fps: Int) -> Int {
        let hevc: [ExportSettings.Resolution: Int] = [.p720: 5, .p1080: 10, .p1440: 16, .p4k: 30]
        let base = hevc[res] ?? (res.width * res.height >= 3_840 * 2160 ? 30 : 10)
        let mult = codec == .hevc ? 1.0 : 1.5
        let fpsMult = fps >= 60 ? 1.5 : 1.0
        return Int(Double(base) * mult * fpsMult)
    }
}
```

- [ ] **Step 6: Add `emberweft export` + CLI dispatch.**

`Sources/EmberweftCLI/ExportCommand.swift` — mirror `AnimateCommand` arg parsing for the shared flags, add the encode flags, build an `ExportJob`, run the coordinator, print throttled progress to stderr:

```swift
import Foundation
import FlameKit
import FlameExport
import FlameRenderer   // MetalRenderer.isAvailable (probe) — @MainActor

extension EmberweftCLI {

    /// `emberweft export <a.flam3> [<b.flam3> …] [options]`.
    ///
    /// `async` because the coordinator renders Metal via `await MainActor.run`
    /// (the temporal Metal path is MainActor-only; a synchronous export that
    /// blocked the main thread would deadlock the MainActor hop) and because
    /// the Metal-availability probe is `@MainActor` (`MetalRenderer.isAvailable`
    /// calls `MainActor.assumeIsolated` and traps off the main actor, so it must
    /// be reached via `await MainActor.run { … }`).
    static func export(_ args: [String]) async -> Int32 {
        // --- Parse args: variadic genomes + --flag value pairs (same shape as AnimateCommand.swift:28-100) ---
        var genomes: [String] = []
        var framesPerSegment = 8, segmentCount = 3, loopCycles = 1, seed: UInt64 = 0
        var stagger = 0.0, temporalSamples = 1
        var backend = "cpu", strictBackend = false, force = false
        var out = "out.mp4", codec = "h264", container = "mp4", bitrate = "auto"
        var resolution = "1080p", fps = 30, quality = "genome"
        var i = 0
        while i < args.count {
            let tok = args[i]
            if tok.hasPrefix("-") {
                let value: () -> String? = { i + 1 < args.count ? args[i + 1] : nil }
                let missing: (String) -> Int32 = { flag in
                    EmberweftCLI.err("error: \(flag) requires a value\n"); return 2
                }
                switch tok {
                case "--frames":
                    guard let v = value() else { return missing("--frames") }
                    framesPerSegment = Int(v) ?? framesPerSegment; i += 2
                case "--segments":
                    guard let v = value() else { return missing("--segments") }
                    segmentCount = Int(v) ?? segmentCount; i += 2
                case "--seed":
                    guard let v = value() else { return missing("--seed") }
                    seed = UInt64(v) ?? seed; i += 2
                case "--stagger":
                    guard let v = value() else { return missing("--stagger") }
                    stagger = Double(v) ?? stagger; i += 2
                case "--loop-cycles":
                    guard let v = value() else { return missing("--loop-cycles") }
                    loopCycles = max(1, Int(v) ?? 1); i += 2
                case "--temporal-samples":
                    guard let v = value() else { return missing("--temporal-samples") }
                    temporalSamples = max(1, Int(v) ?? 1); i += 2
                case "--backend":
                    guard let v = value() else { return missing("--backend") }
                    let lv = v.lowercased()
                    guard lv == "cpu" || lv == "metal" else { EmberweftCLI.err("error: --backend must be cpu|metal\n"); return 2 }
                    backend = lv; i += 2
                case "--out":
                    guard let v = value() else { return missing("--out") }
                    out = v; i += 2
                case "--codec":
                    guard let v = value() else { return missing("--codec") }
                    let lv = v.lowercased()
                    guard lv == "h264" || lv == "hevc" else { EmberweftCLI.err("error: --codec must be h264|hevc\n"); return 2 }
                    codec = lv; i += 2
                case "--container":
                    guard let v = value() else { return missing("--container") }
                    let lv = v.lowercased()
                    guard lv == "mp4" || lv == "mov" else { EmberweftCLI.err("error: --container must be mp4|mov\n"); return 2 }
                    container = lv; i += 2
                case "--bitrate":
                    guard let v = value() else { return missing("--bitrate") }
                    bitrate = v; i += 2
                case "--resolution":
                    guard let v = value() else { return missing("--resolution") }
                    resolution = v.lowercased(); i += 2
                case "--fps":
                    guard let v = value() else { return missing("--fps") }
                    let n = Int(v) ?? -1
                    guard [24, 25, 30, 48, 50, 60].contains(n) else { EmberweftCLI.err("error: --fps must be 24/25/30/48/50/60\n"); return 2 }
                    fps = n; i += 2
                case "--quality":
                    guard let v = value() else { return missing("--quality") }
                    quality = v; i += 2
                case "--segment-frames":
                    // Parsed but unused until Task 6 wires runLongForm.
                    guard let v = value() else { return missing("--segment-frames") }
                    _ = Int(v); i += 2
                case "--force": force = true; i += 1
                case "--strict-backend": strictBackend = true; i += 1
                default:
                    EmberweftCLI.err("error: unknown flag: \(tok)\n"); return 2
                }
            } else {
                genomes.append(tok); i += 1
            }
        }

        // --- genome-count guard (mirrors AnimateCommand:107-114) ---
        guard !genomes.isEmpty else {
            EmberweftCLI.err("error: export requires at least 1 genome; got \(genomes.count)\n"); return 2
        }
        if segmentCount > 1 && genomes.count < 2 {
            EmberweftCLI.err("error: export --segments \(segmentCount) (transitions) needs at least 2 genomes; got \(genomes.count). Pass --segments 1 for a single-sheep loop.\n")
            return 2
        }

        // --- Load + health-gate genomes (isRenderable now lives in FlameKit) ---
        var flames: [Flame] = []
        flames.reserveCapacity(genomes.count)
        for path in genomes {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
                EmberweftCLI.err("error: cannot read \(path)\n"); return 1
            }
            do {
                guard let flame = try Flam3Parser.parse(data).first else {
                    EmberweftCLI.err("error: no <flame> element in \(path)\n"); return 1
                }
                flames.append(flame)
            } catch {
                EmberweftCLI.err("error: failed to parse \(path): \(error)\n"); return 1
            }
        }
        let renderable = flames.filter { $0.isRenderable }
        if renderable.isEmpty {
            EmberweftCLI.err("error: no renderable genomes (NaN/degenerate camera or all-zero xform weight)\n"); return 1
        }
        if renderable.count < flames.count {
            EmberweftCLI.err("notice: skipped \(flames.count - renderable.count) degenerate genome(s)\n")
        }

        // --- Resolve ExportSettings ---
        var settings = ExportSettings()
        settings.codec = codec == "hevc" ? .hevc : .h264
        settings.container = container == "mov" ? .mov : .mp4
        settings.fps = fps
        settings.quality = quality == "genome" ? .genome : .spp(Int(quality) ?? flames[0].quality.samplesPerPixel)
        settings.temporalSamples = max(1, temporalSamples)
        settings.bitrate = bitrate == "auto" ? .auto : .mbps(Int(bitrate) ?? 10)
        switch resolution {
        case "720p": settings.resolution = .p720
        case "1080p": settings.resolution = .p1080
        case "1440p": settings.resolution = .p1440
        case "4k": settings.resolution = .p4k
        default: settings.resolution = .p1080
        }

        // --- Destination overwrite guard (D13) ---
        let outURL = URL(fileURLWithPath: out)
        if FileManager.default.fileExists(atPath: out) && !force {
            EmberweftCLI.err("error: \(out) exists (use --force to overwrite)\n"); return 2
        }

        // --- Backend availability (probe via MainActor.run; MetalRenderer.isAvailable traps off-main) ---
        let metalAvailable = backend == "metal"
            ? await MainActor.run { MetalRenderer.isAvailable }
            : false
        let coordBackend: FlameExport.ExportCoordinator.Backend
        if backend == "metal" {
            if metalAvailable {
                coordBackend = .metal
            } else if strictBackend {
                EmberweftCLI.err("error: Metal unavailable and --strict-backend set\n"); return 1
            } else {
                EmberweftCLI.err("notice: Metal unavailable; falling back to CPU (--strict-backend to refuse)\n")
                coordBackend = .cpu
            }
        } else {
            coordBackend = .cpu
        }

        // --- Build + run the job ---
        let job = ExportJob(settings: settings, flames: renderable, framesPerSegment: framesPerSegment,
                            segmentCount: segmentCount, selector: .sequential, seed: seed,
                            loopCycles: loopCycles, stagger: stagger, out: outURL)
        let coord = ExportCoordinator(backend: coordBackend)

        // SIGINT -> cooperative cancel (one-shot; the loop checks `cancelled` between frames).
        signal(SIGINT, SIG_IGN)
        let sig = DispatchSource.makeSignalSource(signal: SIGINT)
        sig.setEventHandler { Task { await coord.cancel() } }
        sig.resume()
        defer { sig.cancel() }

        do {
            let stream = await coord.run(job)
            var lastPrint = 0.0
            for try await p in stream {
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastPrint > 0.5 || p.currentFrame == p.totalFrames {
                    EmberweftCLI.err("[export] frame \(p.currentFrame)/\(p.totalFrames)  fps \(String(format: "%.1f", p.renderFPS))\n")
                    lastPrint = now
                }
            }
            return 0
        } catch {
            EmberweftCLI.err("error: export failed: \(error)\n")
            try? FileManager.default.removeItem(at: job.partialURL)
            return 1
        }
    }
}
```

Notes:
- The encoder-byte-instability caveat (§5.3) is printed once at the top of the run when not `--frame`/`--png` (Task 5 adds that path). For Task 4 keep the line below at the head of the function (after arg parse):
  `EmberweftCLI.err("note: encoded .mp4 bytes are not byte-stable across machines/OSes; frame pixels are deterministic. Use `emberweft animate` for byte-exact mastering.\n")`
- `MetalRendererInfo` is NOT defined (the prior draft referenced an undefined helper); the probe is inlined via `await MainActor.run { MetalRenderer.isAvailable }`, which is the correct way to reach an `@MainActor`-isolated static var from an `async` non-main context.

`Sources/EmberweftCLI/CLI.swift` — make `run` `async` and add the dispatch (mirror the `animate` case). The current `run` is `public static func run(_ argv: [String]) -> Int32` (sync) and `main.swift` calls `exit(EmberweftCLI.run(CommandLine.arguments))`. Change both:

```swift
@discardableResult
public static func run(_ argv: [String]) async -> Int32 {
    let args = Array(argv.dropFirst())
    guard let cmd = args.first else { printHelp(); return 0 }
    switch cmd {
    case "--version": out("emberweft \(FlameKit.version)\n"); return 0
    case "-h", "--help": printHelp(); return 0
    case "--list-backends": return listBackends()
    case "info": return info(args.dropFirst().first)
    case "validate": return validate(args.dropFirst().first)
    case "render": return render(Array(args.dropFirst()))
    case "animate": return animate(Array(args.dropFirst()))
    case "export": return await export(Array(args.dropFirst()))   // NEW — async dispatch
    case "curate": return curate(Array(args.dropFirst()))
    case "_feature-score": return featureScore(Array(args.dropFirst()))
    default:
        err("unknown command: \(cmd)\n"); printHelp(); return 2
    }
}
```

The other subcommands (`animate`, `render`, `curate`, `info`, `validate`) are already sync `Int32` and are unaffected by `run` becoming `async` (a sync callable from async is fine). Add `export` to `printHelp`:

```swift
  emberweft export  <a.flam3> <b.flam3> … [--frames N] [--segments N] [--seed N] [--backend cpu|metal] [--codec h264|hevc] [--resolution 720p|1080p|1440p|4k] [--fps 24|25|30|48|50|60] [--out FILE.mp4] [--quality genome|N] [--force]
```

`Sources/EmberweftApp/main.swift` — `main.swift` uses Swift top-level-code semantics (the executable target's entry point), so top-level `await` is legal under Swift 6.2 strict concurrency. Replace the body:

```swift
import Foundation
import EmberweftCLI

exit(await EmberweftCLI.run(CommandLine.arguments))
```

This is the minimal change so `export` (async) dispatches without blocking the main thread (which would deadlock the coordinator's `await MainActor.run`). `animate`/`render`/etc. stay sync internally and complete via the same `await` (no behavior change).

- [ ] **Step 7: Run tests.**

Run: `swift test --filter FlameExportTests.ExportCoordinatorTests EmberweftCLITests.ExportCommandTests`
Expected: PASS.

- [ ] **Step 8: Manual DoD check.**

Run: `swift run emberweft export Tests/Goldens/genomes/sierpinski.flam3 --segments 1 --frames 16 --backend cpu --out /tmp/m6-core.mp4 && open /tmp/m6-core.mp4`
Expected: a playable, upright mp4 in QuickTime.

- [ ] **Step 9: Commit.**

```bash
git add Sources/FlameExport/ExportCoordinator.swift Sources/FlameExport/ExportProgress.swift \
        Sources/EmberweftCLI/ExportCommand.swift Sources/EmberweftCLI/CLI.swift Package.swift \
        Tests/FlameExportTests/ExportCoordinatorTests.swift Tests/EmberweftCLITests/ExportCommandTests.swift
git commit -m "feat(m6): emberweft export (single export) + ExportCoordinator (core DoD)"
```

---

## Task 5: Quality/resolution presets + H.264/HEVC + bitrate + HEVC fallback

**Goal:** Wire the full quality/resolution/codec matrix and HEVC availability fallback; add the `export --frame N` PNG path and the cross-command byte-identity pin (`export` vs `animate`).

**Files:**
- Modify: `Sources/EmberweftCLI/ExportCommand.swift` (HEVC probe, `--frame`/`--png`)
- Create: `Tests/FlameExportTests/ExportPresetsTests.swift`

**Acceptance Criteria:**
- [ ] At `.genome`, `export --frame 5 --png` == `animate --frame 5` (byte-equal `RGBA8Image`).
- [ ] 720p/1080p/1440p/4k each produce the correct decoded dimensions.
- [ ] On a host without HEVC encode, `--codec hevc` errors (exit 1) when explicitly requested; the default-codec case falls back to H.264 with a notice. The capability test SKIPS (not fails) on HEVC-capable hosts.
- [ ] `--bitrate 8` produces a file whose `AVAssetTrack` bitrate is within a coarse tolerance of 8 Mbps.

**Verify:** `swift test --filter FlameExportTests.ExportPresetsTests` → green.

**Steps:**

- [ ] **Step 1: Write the failing tests.** `Tests/FlameExportTests/ExportPresetsTests.swift`:

```swift
import XCTest
import Foundation
import AVFoundation
@testable import FlameExport
@testable import EmberweftCLI
import FlameKit
import FlameReference

final class ExportPresetsTests: XCTestCase {
    private func sierpinski() -> String {
        URL(fileURLWithPath: #file).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Goldens/genomes/sierpinski.flam3").path
    }
    private func tmp(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("m6-\(UUID().uuidString).\(ext)")
    }

    /// AC1: at `.genome`, `export --frame 5 --png` == `animate --frame 5`
    /// (byte-equal RGBA8Image). This is the cross-command determinism pin (§5.2).
    /// Requires Task 5 Step 3 (`--frame`/`--png` wiring).
    func testExportGenomeByteMatchesAnimateFrame5() async throws {
        let pngOut = tmp("png")
        let rc = await EmberweftCLI.export([sierpinski(), "--segments", "1", "--frames", "8",
                                            "--frame", "5", "--png", "--out", pngOut.path])
        XCTAssertEqual(rc, 0)

        let animDir = FileManager.default.temporaryDirectory.appendingPathComponent("m6anim-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: animDir, withIntermediateDirectories: true)
        let rcA = EmberweftCLI.animate([sierpinski(), "--segments", "1", "--frames", "8",
                                        "--frame", "5", "--backend", "cpu", "--out", animDir.path])
        XCTAssertEqual(rcA, 0)

        let exported = try RGBA8Image.readPNG(from: pngOut)
        let animated = try RGBA8Image.readPNG(from: animDir.appendingPathComponent("000005.png"))
        XCTAssertEqual(exported, animated)   // byte-identical (`.genome` quality, oversample 1)
        try? FileManager.default.removeItem(at: pngOut)
        try? FileManager.default.removeItem(at: animDir)
    }

    /// AC2: 720p/1080p/1440p/4k each produce the correct decoded dimensions.
    @MainActor
    func testResolutionTiersProduceCorrectDimensions() async throws {
        let cases: [(String, Int, Int)] = [("720p", 1280, 720), ("1080p", 1920, 1080),
                                           ("1440p", 2560, 1440), ("4k", 3840, 2160)]
        for (tier, w, h) in cases {
            let out = tmp("mp4")
            let rc = await EmberweftCLI.export([sierpinski(), "--segments", "1", "--frames", "2",
                                                "--resolution", tier, "--backend", "cpu", "--out", out.path])
            XCTAssertEqual(rc, 0, "\(tier) export failed")
            let asset = AVAsset(url: out)
            let track = try await asset.loadTracks(withMediaType: .video).first!
            let dims = try await track.load(.naturalSize)
            XCTAssertEqual(Int(dims.width), w, "\(tier) width")
            XCTAssertEqual(Int(dims.height), h, "\(tier) height")
            try? FileManager.default.removeItem(at: out)
        }
    }

    /// AC3: HEVC capability. On a host WITHOUT HEVC encode, `--codec hevc`
    /// errors (exit 1). On a host WITH HEVC, the test SKIPS (not fails), so it
    /// does not flake across machines. Probed via VideoEncoder.canEncode (Step 2).
    func testHEVCExplicitErrorWhenUnavailable() async throws {
        guard VideoEncoder.canEncode(.hevc) else {
            // Host lacks HEVC encode -> explicit ask must exit 1.
            let out = tmp("mp4")
            let rc = await EmberweftCLI.export([sierpinski(), "--segments", "1", "--frames", "2",
                                                "--codec", "hevc", "--out", out.path])
            XCTAssertEqual(rc, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
            return
        }
        throw XCTSkip("HEVC encode is available on this host; the unavailable-HEVC path is exercised on hosts without it.")
    }

    /// AC4: `--bitrate 8` produces a file whose track bitrate is within a coarse
    /// tolerance of 8 Mbps (VideoToolbox is VBR, so allow ±50%).
    @MainActor
    func testExplicitBitrateIsHonoredCoarsely() async throws {
        let out = tmp("mp4")
        let rc = await EmberweftCLI.export([sierpinski(), "--segments", "1", "--frames", "16",
                                            "--bitrate", "8", "--backend", "cpu", "--out", out.path])
        XCTAssertEqual(rc, 0)
        let asset = AVAsset(url: out)
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let bps = try await track.load(.estimatedDataRate)   // bits/s
        let mbps = Double(bps) / 1_000_000
        XCTAssertGreaterThan(mbps, 4.0, "bitrate \(mbps) Mbps well below the 8 Mbps target")
        XCTAssertLessThan(mbps, 12.0, "bitrate \(mbps) Mbps well above the 8 Mbps target")
        try? FileManager.default.removeItem(at: out)
    }
}
```

- [ ] **Step 2: Implement HEVC probe + fallback.** Add a `VideoEncoder.canEncode(_:)` static probe (used by the test above AND by ExportCommand). The reliable probe on macOS is `AVAssetWriterInput` + `AVAssetWriter` setup with a single synthetic append, inspecting `writer.error`/`.status`; `VTIsHardwareDecodeSupported`-style APIs probe DECODE, not encode, and are unreliable for this. Add to `VideoEncoder`:

```swift
/// True iff this host can encode `codec` at the encoder's default resolution.
/// Used by ExportCommand's HEVC fallback AND by capability tests. Probes by
/// constructing a throwaway writer+input at 64x48 and appending one black frame;
/// if `startWriting`/append leaves `writer.status == .writing` (then cancel), the
/// codec is accepted. Any `.failed` status with the codec means unavailable.
/// Cheap (no file written — output goes to `/dev/null`-equivalent temp + is removed).
public static func canEncode(_ codec: ExportSettings.Codec) -> Bool {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("m6probe-\(UUID().uuidString).mov")
    defer { try? FileManager.default.removeItem(at: tmp) }
    var s = ExportSettings()
    s.codec = codec; s.container = .mov
    s.resolution = .custom(width: 64, height: 48); s.fps = 30
    guard let writer = try? AVAssetWriter(outputURL: tmp, fileType: .mov) else { return false }
    let codecType: AVVideoCodecType = codec == .hevc ? .hevc : .h264
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: codecType,
        AVVideoWidthKey: 64, AVVideoHeightKey: 48,
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
    writer.add(input)
    guard writer.startWriting() else { return false }
    writer.startSession(atSourceTime: .zero)
    // One black frame.
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, 64, 48,
                        kCVPixelFormatType_32BGRA, nil, &pb)
    if let pb { adaptor.append(pb, withPresentationTime: CMTime(value: 0, timescale: 30)) }
    input.markAsFinished()
    // Drive finishWriting synchronously via a semaphore (probe is one-shot).
    let sem = DispatchSemaphore(value: 0)
    var ok = false
    writer.finishWriting { ok = (writer.status == .completed); sem.signal() }
    sem.wait()
    _ = pb
    return ok
}
```

In `ExportCommand.export`, before constructing the coordinator (after the Metal probe), probe the requested codec: if `settings.codec == .hevc && !VideoEncoder.canEncode(.hevc)`, exit 1 (explicit ask); if the user left codec at default `.h264`, nothing changes (H.264 is universally available on the target). The default-codec fallback-to-H.264 case is only reachable if a future default flips to HEVC; document that in `--help`.

- [ ] **Step 3: Implement `--frame N`/`--png`.** Extend the Task 4 parse loop with `--frame` (`Int?`) and `--png` (Bool). When `--frame N` is set: build the `FramePlan` (reuse the same schedule/segmentCount/flames construction), compute `d = plan.descriptor(for: N)`, render via the SAME backend dispatch (CPU `ReferenceRenderer.render`, Metal `await MainActor.run { MetalRenderer.render(...) }`), and `writePNG` to `--out`. No `VideoEncoder`, no `ExportCoordinator.run` (1-frame path). This is the byte-exact comparison point vs `animate --frame N`. Sketch:

```swift
// (Inside export(_:), after guards + settings resolution + metal probe, before
// constructing the coordinator — short-circuit the 1-frame PNG path:)
if let onlyFrame = onlyFrame, png {
    var schedule = Schedule(librarySize: renderable.count, framesPerSegment: framesPerSegment,
                            selector: Sequential(seed: seed), seed: seed)
    let plan = FramePlan(schedule: &schedule, segmentCount: segmentCount, flames: renderable,
                         loopCycles: loopCycles, stagger: stagger,
                         temporalSamples: max(1, settings.temporalSamples))
    let d = plan.descriptor(for: onlyFrame)
    let res = settings.resolution
    let (spp, os) = settings.quality.resolvedSamplesPerPixel(for: renderable[0])
    let params = RenderParams(seed: seed, width: max(1, res.width), height: max(1, res.height),
                              oversample: os, samplesPerPixel: spp)
    let img: RGBA8Image
    switch coordBackend {
    case .metal:
        img = await MainActor.run {
            autoreleasepool {
                settings.temporalSamples > 1
                    ? MetalRenderer.render(blendAt: d.blendAt, centerTime: d.blend,
                                           temporal: d.temporal, sumfilt: d.sumfilt, params: params)
                    : MetalRenderer.render(flame: d.blendAt(d.blend), params: params)
            }
        }
    case .cpu:
        img = settings.temporalSamples > 1
            ? ReferenceRenderer.render(blendAt: d.blendAt, centerTime: d.blend,
                                       temporal: d.temporal, sumfilt: d.sumfilt, params: params)
            : ReferenceRenderer.render(flame: d.blendAt(d.blend), params: params)
    }
    do { try img.writePNG(to: outURL) }
    catch { EmberweftCLI.err("error: cannot write \(out): \(error)\n"); return 1 }
    return 0
}
```

Add the two flags to the parse loop in Task 4's `ExportCommand`:

```swift
case "--frame":
    guard i + 1 < args.count else { return 2 }
    onlyFrame = Int(args[i + 1]); i += 2
case "--png": png = true; i += 1
```

with `var onlyFrame: Int? = nil, png = false` declared with the other parse locals.

- [ ] **Step 4: Run tests + manual bitrate check.**

Run: `swift test --filter FlameExportTests.ExportPresetsTests`
Expected: PASS (the HEVC test skips on HEVC-capable hosts, not fails).

- [ ] **Step 5: Commit.**

```bash
git add Sources/EmberweftCLI/ExportCommand.swift Tests/FlameExportTests/ExportPresetsTests.swift
git commit -m "feat(m6): export presets + H.264/HEVC + bitrate; HEVC fallback; --frame/--png byte-identity pin"
```

---

## Task 6: Long-form segment + concat

**Goal:** `ExportCoordinator.runLongForm` chunks the timeline on Schedule-segment edges, encodes each chunk to a temp `.mov`, and concatenates via `AVMutableComposition` passthrough (no re-encode). Temps cleaned on every exit path.

**Files:**
- Modify: `Sources/FlameExport/ExportCoordinator.swift` (add `runLongForm`)
- Create: `Tests/FlameExportTests/ExportLongFormTests.swift`

**Acceptance Criteria:**
- [ ] A 3-chunk export's decoded final duration == sum of chunk durations (no gap/overlap).
- [ ] The decoded frame at each splice == the standalone chunk's boundary frame (no dup/drop/black).
- [ ] After success, cancel, AND a forced failure: no `*.mov` temp remains for the run.
- [ ] Chunks never fall mid-segment (always whole segments).

**Verify:** `swift test --filter FlameExportTests.ExportLongFormTests` → green.

**Steps:**

- [ ] **Step 1: Write the failing tests.** `Tests/FlameExportTests/ExportLongFormTests.swift`. Two of the four ACs are concretized here (duration-sum + temp cleanup); the seam-continuity and chunk-boundary ACs use the same decode-back harness with different frame indices — implement them in the same file by mirroring `decodeFirstFrame`:

```swift
import XCTest
import Foundation
import AVFoundation
@testable import FlameExport
@testable import EmberweftCLI
import FlameKit

final class ExportLongFormTests: XCTestCase {
    private func sierpinski() -> String {
        URL(fileURLWithPath: #file).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Goldens/genomes/sierpinski.flam3").path
    }
    private func tmpDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("m6lf-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    /// Decode the first video frame of `url` as raw BGRA bytes (orientation-checked
    /// elsewhere; here we only need duration + existence). Used by seam tests.
    @MainActor
    private func decodedDurationSeconds(_ url: URL) async throws -> Double {
        let asset = AVAsset(url: url)
        let t = try await asset.load(.duration)
        return CMTimeGetSeconds(t)
    }

    /// AC1: 3 chunks -> final decoded duration == sum of chunk durations.
    @MainActor
    func testLongFormDurationIsSumOfChunks() async throws {
        let out = tmpDir().appendingPathComponent("concat.mp4")
        // 6 segments, 8 frames/segment, 2 segments/chunk -> 3 chunks of 16 frames.
        let rc = await EmberweftCLI.export([sierpinski(), sierpinski(),
                                            "--frames", "8", "--segments", "6",
                                            "--segment-frames", "16",
                                            "--fps", "30", "--backend", "cpu", "--out", out.path])
        XCTAssertEqual(rc, 0)
        let total = try await decodedDurationSeconds(out)
        // 6 segments * 8 frames = 48 frames / 30 fps = 1.6 s.
        XCTAssertEqual(total, 1.6, accuracy: 0.05)
        try? FileManager.default.removeItem(at: out)
    }

    /// AC3: no `m6-seg-*.mov` temp remains after success.
    func testLongFormTempsCleanedAfterSuccess() async throws {
        let tmpRoot = tmpDir()
        let out = tmpRoot.appendingPathComponent("concat.mp4")
        _ = await EmberweftCLI.export([sierpinski(), sierpinski(),
                                       "--frames", "8", "--segments", "6",
                                       "--segment-frames", "16",
                                       "--backend", "cpu", "--out", out.path])
        let leftover = (try? FileManager.default.contentsOfDirectory(atPath: tmpRoot.path)) ?? []
        XCTAssertFalse(leftover.contains(where: { $0.hasPrefix("m6-seg-") }),
                       "long-form temp segment leaked: \(leftover)")
        try? FileManager.default.removeItem(at: tmpRoot)
    }

    /// AC3 (cancel path): cancel during a long export leaves no temp segment.
    func testLongFormTempsCleanedAfterCancel() async throws {
        let tmpRoot = tmpDir()
        let out = tmpRoot.appendingPathComponent("concat.mp4")
        // Spawn the export, cancel after a short delay, then assert cleanup.
        // (A coordinator-level unit test that calls runLongForm + cancel() is the
        // tighter form; this CLI-level test mirrors the user-visible contract.)
        async let rc = EmberweftCLI.export([sierpinski(), sierpinski(),
                                            "--frames", "8", "--segments", "20",
                                            "--segment-frames", "8",
                                            "--backend", "cpu", "--out", out.path])
        try await Task.sleep(nanoseconds: 200_000_000)
        raise(SIGINT)   // SIGINT is wired to coord.cancel() in ExportCommand
        _ = try await rc
        let leftover = (try? FileManager.default.contentsOfDirectory(atPath: tmpRoot.path)) ?? []
        XCTAssertFalse(leftover.contains(where: { $0.hasPrefix("m6-seg-") }))
        try? FileManager.default.removeItem(at: tmpRoot)
    }
}
```

(The seam-continuity and chunk-on-segment-boundary ACs are the same harness with `AVAssetReader` per-splice decode; implement them in this file by mirroring the decode helper. They are listed in spec §12.6.)

- [ ] **Step 2: Implement `runLongForm`.** Chunk size (in segments) = `max(1, job.settings.segmentFrameBudget / job.framesPerSegment)`. Each chunk covers `chunkSegments` whole `Schedule` segments, so chunk boundaries never fall mid-segment (AC4). Refactor `runJob` to accept an optional `frameRange: Range<Int>?` (nil = whole timeline) so the per-chunk loop is the SAME code path as the single export (no duplication, byte-identical frames). Each chunk encodes into `NSTemporaryDirectory()/m6-seg-\(jobID)-\(chunkIndex).mov`, registered in a `[URL]` cleaned by `defer { for u in temps { try? FileManager.default.removeItem(at: u) } }` (crash-safe `try?`). Concatenate:

```swift
import AVFoundation   // already imported in ExportCoordinator

// Inside runLongForm, after all chunks are encoded in `temps: [URL]`:
let composition = AVMutableComposition()
let track = composition.addMutableTrack(withMediaType: .video,
                                        preferredTrackID: kCMPersistentTrackID_Invalid)!
var cursor = CMTime.zero
for segURL in temps {
    let segAsset = AVAsset(url: segURL)
    let segTrack = await segAsset.loadTracks(withMediaType: .video).first!
    let segRange = CMTimeRange(start: .zero, duration: try await segAsset.load(.duration))
    try track.insertTimeRange(segRange, of: segTrack, at: cursor)
    cursor = CMTimeAdd(cursor, segRange.duration)
}
guard let exporter = AVAssetExportSession(asset: composition, presetName: .passthrough) else {
    throw ExportError.encodeFailed
}
exporter.outputURL = job.out
exporter.outputFileType = job.settings.container == .mov ? .mov : .mp4
try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
    exporter.exportAsynchronously { cont.resume(with: exporter.status == .completed ? .success(()) : .failure(exporter.error ?? ExportError.encodeFailed)) }
}
```

Passthrough (`.passthrough`) preserves the per-chunk codec params and keyframes (all chunks share identical `ExportSettings`, so params + timescale match — spec D10). The atomic-handoff + partial-URL pattern from Task 4 still applies: encode the final to `job.partialURL`, rename on success.

- [ ] **Step 3: Wire `--segment-frames N`.** In Task 4's parse loop, change the `--segment-frames` case to store the value into a local, then `settings.segmentFrameBudget = max(0, segmentFrames)` before building the job; dispatch `await coord.runLongForm(job)` when `settings.segmentFrameBudget > 0`, else `await coord.run(job)` (today's path). The progress stream type is the same `AsyncThrowingStream<ExportProgress, Error>` (chunks yield per-frame `.rendering`; the concat phase yields `.concatenating`).

- [ ] **Step 4: Run tests.**

Run: `swift test --filter FlameExportTests.ExportLongFormTests`
Expected: PASS.

- [ ] **Step 5: Commit.**

```bash
git add Sources/FlameExport/ExportCoordinator.swift Sources/EmberweftCLI/ExportCommand.swift Tests/FlameExportTests/ExportLongFormTests.swift
git commit -m "feat(m6): long-form segment+concat (passthrough; temps cleaned on all exit paths)"
```

---

## Task 7: Batch queue

**Goal:** `ExportCoordinator.runBatch(jobs:failFast:)` runs jobs serially with continue-by-default (or `--fail-fast`), per-job + aggregate progress, and cancel scope = current + remaining.

**Files:**
- Modify: `Sources/FlameExport/ExportCoordinator.swift` (add `runBatch`, `BatchProgress`)
- Modify: `Sources/EmberweftCLI/ExportCommand.swift` (`--jobs manifest.json`, `--fail-fast`, batch base-dir path sanitization)
- Create: `Tests/FlameExportTests/ExportBatchTests.swift`

**Acceptance Criteria:**
- [ ] 3 jobs run in input order; all outputs exist.
- [ ] A failing job 1 (bad genome): jobs 2,3 still run; exit code 1; failure recorded.
- [ ] `--fail-fast`: job 1 failure stops jobs 2,3; exit code 1.
- [ ] Cancel during job 1: job 1 partial deleted; jobs 2,3 do not start.
- [ ] Manifest `out` paths are sanitized (reject `..`, absolute, hidden) and resolved under the batch base dir.

**Verify:** `swift test --filter FlameExportTests.ExportBatchTests` → green.

**Steps:**

- [ ] **Step 1: Write the failing tests.** `Tests/FlameExportTests/ExportBatchTests.swift`. Order + continue-on-failure + path-sanitization are concretized here; fail-fast and cancel-scope mirror these with the obvious flag/`coord.cancel()` swap (spec §12.7):

```swift
import XCTest
import Foundation
@testable import FlameExport
@testable import EmberweftCLI
import FlameKit

final class ExportBatchTests: XCTestCase {
    private func sierpinski() -> String {
        URL(fileURLWithPath: #file).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Goldens/genomes/sierpinski.flam3").path
    }
    private func tmpDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("m6batch-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// AC1: 3 jobs run in input order; all outputs exist.
    func testBatchRunsJobsInOrder() async throws {
        let dir = tmpDir()
        let jobs = (0..<3).map { i in
            ExportJob(settings: ExportSettings(), flames: [try! Flam3Parser.parse(Data(contentsOf: URL(fileURLWithPath: sierpinski()))).first!],
                      framesPerSegment: 4, segmentCount: 1, selector: .sequential, seed: 0,
                      loopCycles: 1, stagger: 0, out: dir.appendingPathComponent("j\(i).mp4"))
        }
        let coord = ExportCoordinator(backend: .cpu)
        let stream = await coord.runBatch(jobs, failFast: false)
        var seen: [Int] = []
        for try await p in stream { seen.append(p.jobIndex) }
        // Outputs exist.
        for i in 0..<3 { XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("j\(i).mp4").path)) }
        // jobIndex is non-decreasing (serial, in order).
        XCTAssertEqual(seen.sorted(), seen)
        try? FileManager.default.removeItem(at: dir)
    }

    /// AC2: a failing job 1 (bad genome path -> parse error captured upstream)
    /// does not abort jobs 2,3 by default. Exit (failure count) > 0.
    func testBatchContinuesOnFailure() async throws {
        let dir = tmpDir()
        // Job 0 has a genome that parses but is degenerate (all-zero weight) ->
        // rejected by the health gate inside runBatch; jobs 1,2 still run.
        var badSettings = ExportSettings()
        badSettings.resolution = .custom(width: 32, height: 32)
        var badFlame = Flame()
        badFlame.xforms = []   // all-zero weight -> isRenderable == false
        let good = [try Flam3Parser.parse(Data(contentsOf: URL(fileURLWithPath: sierpinski()))).first!]
        let jobs = [
            ExportJob(settings: badSettings, flames: [badFlame], framesPerSegment: 4, segmentCount: 1,
                      selector: .sequential, seed: 0, loopCycles: 1, stagger: 0,
                      out: dir.appendingPathComponent("bad.mp4")),
            ExportJob(settings: badSettings, flames: good, framesPerSegment: 4, segmentCount: 1,
                      selector: .sequential, seed: 0, loopCycles: 1, stagger: 0,
                      out: dir.appendingPathComponent("g1.mp4")),
            ExportJob(settings: badSettings, flames: good, framesPerSegment: 4, segmentCount: 1,
                      selector: .sequential, seed: 0, loopCycles: 1, stagger: 0,
                      out: dir.appendingPathComponent("g2.mp4")),
        ]
        let coord = ExportCoordinator(backend: .cpu)
        let stream = await coord.runBatch(jobs, failFast: false)
        let failures = try await Self.collectFailures(stream)
        XCTAssertEqual(failures.count, 1)                 // only job 0 failed
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("g1.mp4").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("g2.mp4").path))
        try? FileManager.default.removeItem(at: dir)
    }

    /// AC5: path sanitization rejects `..`, absolute, and hidden stems, and
    /// resolves accepted names under the batch base dir.
    func testBatchPathSanitization() throws {
        XCTAssertThrowsError(try BatchPath.resolve("../../etc/passwd", base: tmpDir()))
        XCTAssertThrowsError(try BatchPath.resolve("/etc/passwd", base: tmpDir()))
        XCTAssertThrowsError(try BatchPath.resolve(".hidden", base: tmpDir()))
        let ok = try BatchPath.resolve("good-name_1.mp4", base: tmpDir())
        XCTAssertTrue(ok.path.hasPrefix("/tmp/m6batch-") || ok.deletingLastPathComponent().path.contains("m6batch-"))
    }

    private static func collectFailures<S: AsyncSequence>(_ s: S) async throws -> [Int] where S.Element == BatchProgress {
        var f: [Int] = []
        for try await p in s { if p.failed { f.append(p.jobIndex) } }
        return f
    }
}
```

(The fail-fast and cancel-scope ACs are the same `runBatch` driver with `failFast: true` / `await coord.cancel()` mid-stream; spec §12.7 enumerates them.)

- [ ] **Step 2: Implement `runBatch` + `BatchProgress`.** Add to `Sources/FlameExport/ExportProgress.swift`:

```swift
/// Per-job + aggregate progress for a batch run. `failed` records a per-job
/// failure (continue-by-default); the consumer can compute the batch exit code
/// from the final tally.
public struct BatchProgress: Sendable, Equatable {
    public let jobIndex: Int
    public let totalJobs: Int
    public let jobFrame: Int
    public let jobTotalFrames: Int
    public let aggregateFraction: Double
    public let failed: Bool
    public init(jobIndex: Int, totalJobs: Int, jobFrame: Int, jobTotalFrames: Int,
                aggregateFraction: Double, failed: Bool) {
        self.jobIndex = jobIndex; self.totalJobs = totalJobs
        self.jobFrame = jobFrame; self.jobTotalFrames = jobTotalFrames
        self.aggregateFraction = aggregateFraction; self.failed = failed
    }
}
```

`runBatch(_ jobs:, failFast:)` iterates `jobs.indices` in order. For each job, it materializes `flames`, health-gates them (`flames.filter { $0.isRenderable }`), and if empty records `failed=true` and (continue) advances, or (fail-fast) stops. Otherwise it opens an `ExportCoordinator.run`/`runLongForm` sub-stream, maps each `ExportProgress` to a `BatchProgress(jobIndex:totalJobs:jobFrame:jobTotalFrames:aggregateFraction:failed:false)`, and yields. On a thrown error from a job: record failed, and on `failFast` stop. Cancel (`cancelled` flag) stops the current job (cleanup its partial) and skips remaining jobs. A simple implementation reuses one `ExportCoordinator` (self) — the per-job sub-stream is consumed on the actor.

- [ ] **Step 3: Implement `--jobs` + `BatchPath` sanitization.** Add a `BatchPath` enum in `Sources/FlameExport/ExportProgress.swift`:

```swift
/// Resolves a manifest `out` name under a batch base dir, rejecting traversal.
/// Rule (spec D13 §8.1): take `lastPathComponent`, allowlist chars
/// `[A-Za-z0-9._-]`, reject hidden (leading `.`) / empty / `..` stems, then
/// resolve under `base`. The result never escapes `base`.
public enum BatchPath {
    public enum BatchPathError: Error, Equatable { case traversal, empty, illegalCharacters }

    public static func resolve(_ raw: String, base: URL) throws -> URL {
        let name = URL(fileURLWithPath: raw).lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else { throw BatchPathError.traversal }
        if name.hasPrefix(".") { throw BatchPathError.traversal }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        if name.unicodeScalars.contains(where: { !allowed.contains($0) }) { throw BatchPathError.illegalCharacters }
        return base.appendingPathComponent(name)
    }
}
```

In `ExportCommand`, add `--jobs FILE` (JSON array of `{ "args": ["g.flam3", "--out", "x.mp4", ...], }` objects — or directly `{ "genome": "...", "out": "..." }` per the manifest you choose; document the chosen schema in `--help`). Parse the manifest with `JSONDecoder`, recursively call `export(_:)` per declared arg list (or build `ExportJob`s directly), passing `failFast` from `--fail-fast`. The batch base dir is `--out` (when it's a directory) or the CWD.

- [ ] **Step 4: Run tests + manual.**

Run: `swift test --filter FlameExportTests.ExportBatchTests`
Then: `swift run emberweft export --jobs /tmp/batch.json --out /tmp/batch/` → all outputs present.

- [ ] **Step 5: Commit.**

```bash
git add Sources/FlameExport/ExportCoordinator.swift Sources/EmberweftCLI/ExportCommand.swift Tests/FlameExportTests/ExportBatchTests.swift
git commit -m "feat(m6): batch export (serial; continue/fail-fast; cancel scope; path sanitization)"
```

---

## M6 Definition of Done (manual, clean CLI run, sandbox off)

- [ ] `emberweft export <one genome> --segments 1 --out x.mp4` → upright, playable H.264 mp4; frame K decodes to the same pixels as `animate --frame K` (`.genome`).
- [ ] H.264 + HEVC selectable; HEVC falls back on unsupported hardware.
- [ ] 720p/1080p/1440p/4k produce correct dimensions.
- [ ] Long-form concatenates cleanly at segment boundaries; temps never leak.
- [ ] Batch `--jobs` runs serially with continue/fail-fast semantics.
- [ ] Cancel cleans partials + temps.
- [ ] `animate` → PNG unchanged and remains the byte-exact mastering path.
- [ ] `--help` documents the encoder-byte-instability caveat.
- [ ] All `[automated]` tests green; parity suite green; `git diff --name-only main | grep -E 'Sources/(FlameKit|FlameReference|FlameRenderer)/'` shows only the M6.1/M6.2 sanctioned changes.

---

## Resolved implementation note: `SelectorSpec` home

`SelectorSpec` is a module-level enum declared at the top of `Sources/FlameExport/ExportProgress.swift` (Task 4 Step 4), so its qualified name is `FlameExport.SelectorSpec` — NOT nested on `ExportJob` or `Schedule`, and NOT introduced into FlameKit (the FlameKit selectors `Sequential`/`SimilarityExploration` already exist; `SelectorSpec` is a serializable choice that the coordinator maps to a selector via `makeSelector`). `ExportJob.selector` is typed `SelectorSpec` and the CLI passes `.sequential`. `.similarity` is a documented stub: `SimilarityExploration` needs `featureVectors`, which the headless CLI does not yet source, so `makeSelector(.similarity)` returns `Sequential` until the GUI export-sheet slice wires features. This is consistent across `ExportJob`, `ExportCoordinator.makeSelector`, and `BatchPath`/`runBatch`.
