# M6 Export — GUI Slice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers-extended-cc:subagent-driven-development` (recommended) or
> `superpowers-extended-cc:executing-plans` to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the M6 GUI video-export surface (sheet + non-blocking progress +
three sources + presets) and the one parity-neutral engine extraction it needs
(off-main temporal Metal), closing the M6 milestone.

**Architecture:** Three layers — (E1) extract `renderTemporalFusedCore` +
`renderTemporalOffMain` in `FlameRenderer` (byte-identical, mirrors
`renderFusedCore`/`renderOffMain`); (E2) a `useOffMainMetal` flag on
`ExportCoordinator` + a shared `ExportSettings.resolve(…)` in `FlameExport`;
(G) an `ExportManager` `@MainActor @Observable` VM in `EmberweftUI` (testable)
holding an `ExportCoordinator` via an `ExportCoordinating` seam, driven by a
thin `ExportSheet` + `ExportProgressSurface` in `EmberweftGUI` (manual-tested),
wired into the three source windows. The CLI path is untouched (flag defaults
false; resolver is a pure extraction).

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI + AppKit (`NSSavePanel`/
`NSOpenPanel`/`NSWorkspace`), Metal compute, AVFoundation (`AVAssetWriter`),
`ProcessInfo` activity API. Apple SDKs only — no new dependencies.

**User decisions (already made — quotable, do not re-ask):**
- **Off-main temporal Metal = "option (b)"** (resolved 2026-08-03). Add the
  extraction; do NOT propose CPU-only / modal / defer.
- **Non-blocking progress:** sheet dismisses on Start; banner mounted in **all
  three** window types (main window is NOT always open). No floating `NSPanel` (M7).
- **Destination:** `NSSavePanel` (single/sequence) / `NSOpenPanel`-dir (batch,
  reusing `FlameExport.BatchPath.resolve`).
- **Backend picker** Auto/CPU/Metal, default Auto (probe `MetalRenderer.isAvailable`
  on the MainActor inside `ExportManager`).
- **Quality** = Genome default (`.genome`, byte-identical to `animate`) + Low/Med/High
  (`.spp(2/8/30)`, **oversample pinned 1**). Wires the dormant `qualityPreset`.
- **`ExportManager` on `AppModel`** (survives sheet/window teardown).
- **`ProcessInfo.beginActivity`** sleep prevention for the run.
- **Sequence export uses `run`** (`segmentCount = flames.count`), NOT
  `runLongForm`/concat (deferred to a future very-long-form toggle).
- **Single concurrent export** (no queue; `canStart` gates Start).

**Authoritative spec:** [`docs/superpowers/specs/2026-08-03-m6-export-gui-design.md`](../specs/2026-08-03-m6-export-gui-design.md)
(reviewed; 15 defects D-G1…D-G15 resolved; all signatures verified against `main`).
Every signature/field-name/test-name in this plan is taken from that spec — read
its §4 for the design rationale and §9 for the full acceptance matrix.

---

## Global conventions (all tasks)

- **Sandbox OFF** for any `swift test` involving Metal/AVFoundation
  (`MTLCreateSystemDefaultDevice()` returns nil under the bash sandbox — CLAUDE.md).
- Read the `Executed N tests, with X failures` line + exit code; `make test-fast`
  prints `error:` lines that are EXPECTED (CLI error-path test inputs).
- Conventional Commits, branch-per-feature, PRs into `main`.
- A subagent must NOT run `swift` while another is (`.build` lock deadlock — CLAUDE.md).
- The fixture `Tests/Goldens/fixtures/sierpinski_ts4.flam3` must live in `fixtures/`,
  NOT `Tests/Goldens/genomes/` (the exact-6 golden-set guard — CLAUDE.md).

---

## Task M6-G.1: Engine extraction — off-main temporal Metal (E1)

**Goal:** Add the byte-identical off-main temporal Metal path (`renderTemporalFusedCore`
+ `renderTemporalOffMain`), pinned by parity tests. This is the sole renderer edit
and the foundation everything else needs.

**Files:**
- Modify: `Sources/FlameRenderer/MetalRenderer.swift` (extract `renderTemporalFusedCore`
  from `renderTemporalFused:475-785`; `renderTemporalFused` → thin `@MainActor`
  wrapper; add `nonisolate renderTemporalOffMain`).
- Test: `Tests/FlameRendererTests/OffMainTemporalParityTests.swift` (NEW).
- Fixture: `Tests/Goldens/fixtures/sierpinski_ts4.flam3` (NEW — copy
  `Tests/Goldens/genomes/sierpinski.flam3`, set `temporal_samples="4"`).

**Acceptance Criteria:**
- [ ] `renderTemporalFused`'s body is extracted verbatim into `renderTemporalFusedCore(...)`
  taking `device`/`queue`/`psos` as params (mirrors `renderFusedCore:177`); the
      `@MainActor` wrapper fetches those three and delegates.
- [ ] `renderTemporalOffMain` is `nonisolated`, runs on `offMainQueue.sync`, uses
  `offMainCache.handles()`/`pipelines(device:library:)`, returns `nil` on
      Metal-unavailable/failure/non-box, `byte`-identical otherwise.
- [ ] `testRenderTemporalOffMainMatchesMainActorPath`: ts>1 fixture, pixels of
  `renderTemporalOffMain` == the `@MainActor` path (`MetalRenderer.render(blendAt:…)`,
  which delegates to `renderTemporalFused` → `renderTemporalFusedCore`); same
  device + seedBudget (nil).
- [ ] `testRenderTemporalOffMainMatchesMainActorPathOnRealGenome`: same on a
  real `sheep/gen-248/` genome at ts>1 (XCTSkip if the gen-248 archive is absent).
- [ ] `testRenderTemporalOffMainReturnsNilOnNonBox`: a `weight != 1.0` sub-sample ⇒ nil.

**Verify:** `swift test --filter OffMainTemporalParityTests` → `Executed 3 tests, with 0 failures`.

**Steps:**

- [ ] **Step 1: Verify the fixture exists.** `Tests/Goldens/fixtures/sierpinski_ts4.flam3`
  **already exists** on `main` (a copy of `sierpinski.flam3` with
  `temporal_samples="4"` added to the `<flame>` header) and is **already consumed**
  by `testExportGenomeByteMatchesAnimateFrame5MotionBlur`
  (`Tests/FlameExportTests/ExportPresetsTests.swift:80`, via its `sierpinskiTS4()`
  loader at `:24`). Do NOT recreate it. Confirm with `cat
  Tests/Goldens/fixtures/sierpinski_ts4.flam3 | head -4` that the header carries
  `temporal_samples="4"` (it does). (In `fixtures/`, not `genomes/` — the exact-6
  golden-set guard, CLAUDE.md.)

- [ ] **Step 2: Write the failing parity tests** (`Tests/FlameRendererTests/OffMainTemporalParityTests.swift`).
  There is NO reusable "descriptor builder" helper in `TemporalBlurMetalTests` to
  copy — those tests construct the temporal args INLINE via
  `TemporalFilter.samples(_ count, type:width:exp:)` (`Sources/FlameKit/TemporalFilter.swift:14`,
  a `public static func`; `type` is `TemporalFilterType.box`/`.gaussian` from
  `Genome.swift:82-83`). Do the same: 2 lines, no helper. Load genomes with the
  `#filePath`-relative pattern (`TemporalBlurMetalTests.loadFrozen`) or CWD-relative
  pattern (`MetalFrameRendererSmokeTests.realGenome`); both are existing, named
  loaders — copy one.

```swift
import XCTest
import FlameKit
import FlameRenderer
@testable import FlameRenderer

@MainActor
final class OffMainTemporalParityTests: XCTestCase {

    /// #filePath-relative loader (copy of TemporalBlurMetalTests.loadFrozen).
    private func loadFrozen(_ name: String) throws -> Flame {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Goldens/genomes/\(name).flam3")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("fixture missing: \(url.path)")
        }
        return try Flam3Parser.parse(Data(contentsOf: url)).first!
    }
    /// CWD-relative loader for the ts4 fixture (lives in fixtures/, not genomes/).
    private func loadTS4() throws -> Flame {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Goldens/fixtures/sierpinski_ts4.flam3")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("fixture missing: \(url.path)")
        }
        return try Flam3Parser.parse(Data(contentsOf: url)).first!
    }
    /// CWD-relative real gen-248 loader (sheep/gen-248/, NOT `-path '*248*'`).
    private func loadRealGen248(_ id: String) throws -> Flame {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("genomes/electric-sheep/sheep/gen-248/\(id).flam3")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("fixture missing: \(url.path)")
        }
        return try Flam3Parser.parse(Data(contentsOf: url)).first!
    }

    func testRenderTemporalOffMainMatchesMainActorPath() throws {
        guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
        let flame = try loadTS4()
        let (temporal, sumfilt) = TemporalFilter.samples(4, type: .box, width: 1.0, exp: 0)
        let params = RenderParams(seed: 1, width: 200, height: 150, oversample: 1, samplesPerPixel: 200)
        let mainActorImg = MetalRenderer.render(
            blendAt: { _ in flame }, centerTime: 0.5, temporal: temporal,
            sumfilt: sumfilt, params: params, seedBudget: nil)
        let offMainImg = try XCTUnwrap(MetalRenderer.renderTemporalOffMain(
            blendAt: { _ in flame }, centerTime: 0.5, temporal: temporal,
            sumfilt: sumfilt, params: params, seedBudget: nil),
            "off-main temporal must succeed (Metal available, box temporal)")
        XCTAssertEqual(mainActorImg.pixels, offMainImg.pixels,
            "renderTemporalOffMain must be byte-identical to the @MainActor temporal path")
    }

    func testRenderTemporalOffMainMatchesMainActorPathOnRealGenome() throws {
        guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
        let flame = try loadRealGen248("0_05739")   // a known gen-248 sheep; XCTSkip if absent
        let (temporal, sumfilt) = TemporalFilter.samples(8, type: .box, width: 1.2, exp: 0)
        let params = RenderParams(seed: 1, width: 200, height: 150, oversample: 1, samplesPerPixel: 300)
        let a = MetalRenderer.render(blendAt: { _ in flame }, centerTime: 0.5,
            temporal: temporal, sumfilt: sumfilt, params: params)
        let b = try XCTUnwrap(MetalRenderer.renderTemporalOffMain(
            blendAt: { _ in flame }, centerTime: 0.5, temporal: temporal,
            sumfilt: sumfilt, params: params))
        XCTAssertEqual(a.pixels, b.pixels)
    }

    func testRenderTemporalOffMainReturnsNilOnNonBox() throws {
        guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
        let flame = try loadFrozen("sierpinski")
        let nonBox = TemporalFilter.samples(4, type: .gaussian, width: 1.0, exp: 0)
            // force a non-unit weight to trip the box guard (gaussian N>1 has weights < 1.0)
        let tiny = RenderParams(seed: 1, width: 16, height: 16, oversample: 1, samplesPerPixel: 4)
        let res = MetalRenderer.renderTemporalOffMain(
            blendAt: { _ in flame }, centerTime: 0, temporal: nonBox.0,
            sumfilt: nonBox.1, params: tiny)
        XCTAssertNil(res, "non-box temporal must return nil off-main, not trap")
    }
}
```

  **Precondition note (verified, not a fix):** `renderTemporalFused` opens with
  `precondition(!temporal.isEmpty, …)` (`MetalRenderer.swift:484`). The extraction
  moves it into `renderTemporalFusedCore`, and `renderTemporalOffMain`'s `try?`
  does **NOT** catch a precondition trap (it's a trap, not a throw). The box guard
  runs first and does NOT cover the empty case. This is safe because the SOLE
  caller (the coordinator's `renderFrames`) only takes the temporal branch when
  `plan.temporalSamples > 1`, and `FramePlan.descriptor(for:)` builds `temporal`
  via `TemporalFilter.samples(temporalSamples, …)` ⇒ always non-empty. Empty
  temporal is a never-hit caller invariant; the implementer should add a one-line
  `guard !temporal.isEmpty else { return nil }` at the top of
  `renderTemporalOffMain` (before the box guard) as defensive belt-and-suspenders,
  but it is not a correctness bug.

- [ ] **Step 3: Run red.** `swift test --filter OffMainTemporalParityTests` →
  compile error (`renderTemporalOffMain` does not exist) / fail. Expected.

- [ ] **Step 4: Extract `renderTemporalFusedCore` + add `renderTemporalOffMain`**
  in `Sources/FlameRenderer/MetalRenderer.swift`, exactly as specified in spec §4.1(a)/(b)/(c).
  The body of `renderTemporalFused` (current lines 484–785) moves into
  `renderTemporalFusedCore(...)` with `device`/`queue`/`psos` added as params and
  the three inline `guard let`s removed; `renderTemporalFused` becomes the thin
  `@MainActor` wrapper; `renderTemporalOffMain` mirrors `renderOffMain:451`. Use
  the exact code blocks from spec §4.1.

- [ ] **Step 5: Run green.** `swift test --filter OffMainTemporalParityTests` →
  `Executed 3 tests, with 0 failures`. Also re-run the existing single-pass pins
  to confirm no regression: `swift test --filter MetalFrameRendererSmokeTests`.

- [ ] **Step 6: Confirm no engine-math diff.** `git diff --name-only main |
  grep -E 'Sources/(FlameKit|FlameReference)/'` → empty.

- [ ] **Step 7: Commit.** `feat(renderer): off-main temporal Metal path
  (renderTemporalOffMain) for non-freezing GUI export` + the parity tests + fixture.

---

## Task M6-G.2: Coordinator off-main Metal dispatch flag (E2a)

**Goal:** Let `ExportCoordinator` render Metal off-main (GUI) without freezing the
UI, behind a default-off flag so the CLI path is byte-for-byte unchanged.

**Files:**
- Modify: `Sources/FlameExport/ExportCoordinator.swift` (`init(backend:useOffMainMetal:)`;
  off-main branch in the `renderFrames` dispatch loop ~`:168-188`).
- Test: `Tests/FlameExportTests/OffMainDispatchTests.swift` (NEW).

**Acceptance Criteria:**
- [ ] `ExportCoordinator.init(backend:useOffMainMetal:Bool = false)`; flag stored.
  The default `false` keeps all 13 existing call sites byte-identical
  (`ExportCommand.swift:291,518`; `ExportBatchTests`×4; `ExportLongFormTests`×5;
  `ExportCoordinatorTests`×2 — all single-arg `ExportCoordinator(backend:)`).
- [ ] When `backend == .metal && useOffMainMetal`, `renderFrames` dispatches via
  `Task.detached(priority:.userInitiated){ plan.temporalSamples > 1 ?
  renderTemporalOffMain(...) : renderOffMain(...) }` — using the **real**
  `FrameDescriptor` field names (`d.blendAt`, `d.blend`, `d.temporal`, `d.sumfilt`,
  `d.blendAt(d.blend)` — verified at `FramePlan.swift:7-24`, NO `centerTime`/`flame`
  field) and `plan.temporalSamples > 1` (`ExportCoordinator.swift:175`, spec D-G1);
  nil ⇒ `throw ExportError.metalUnavailable`.
- [ ] With `useOffMainMetal == false` the dispatch is unchanged (CLI behavior):
  `await MainActor.run { autoreleasepool { MetalRenderer.render(…) } }`.
- [ ] `testExportCoordinatorOffMainMetalDispatchesOffMain`: a 1-frame Metal job
  with `useOffMainMetal: true` completes and produces a non-empty image whose
  pixels equal the `useOffMainMetal: false` (MainActor) run's pixels at the same
  seed/params (transitively proves the off-main branch is wired AND byte-identical;
  off-main-ness itself is already pinned by `MetalFrameRendererSmokeTests` for
  single-pass + the new M6-G.1 temporal pins, so a fragile `Thread.isMainThread`
  probe inside an injected hook — which does not exist in the coordinator — is
  neither needed nor sound). With `false` it uses the MainActor path.

**Verify:** `swift test --filter OffMainDispatchTests` → 0 failures; existing
`swift test --filter FlameExportTests` still green (CLI path unchanged).

**Steps:**

- [ ] **Step 1: Write the failing test** asserting the off-main path does not run
  on the main thread (probe via a `MainActor` sentinel that must remain responsive
  during the render, or a `Thread.isMainThread` capture inside an injected hook).
  Keep it to a 1-frame job so it's fast.

- [ ] **Step 2: Run red.**

- [ ] **Step 3: Implement.** Add the stored flag + the off-main branch verbatim
  from spec §4.2a (the corrected pseudocode with the real field names). Mirror the
  existing `useMetal`/CPU branches; only the Metal+`useOffMainMetal` case is new.

- [ ] **Step 4: Run green** + re-run the full `FlameExportTests` to confirm the
  CLI/default path is unchanged.

- [ ] **Step 5: Commit.** `feat(export): ExportCoordinator useOffMainMetal flag
  (GUI path); CLI path unchanged`.

---

## Task M6-G.3: Shared settings resolver + CLI refactor (E2b / G5)

**Goal:** Extract the motion-blur genome-default fallback + Metal cap into a pure,
silent `ExportSettings.resolve(…)` in `FlameExport`, shared by CLI and GUI so both
build byte-identical jobs.

**Files:**
- Modify: `Sources/FlameExport/ExportSettings.swift` (add `static func resolve(...)`).
- Modify: `Sources/EmberweftCLI/ExportCommand.swift` (`resolveExportSettings:358`
  → parse strings, call `ExportSettings.resolve(…)`, print the cap notice locally).
- Test: `Tests/FlameExportTests/ExportSettingsResolveTests.swift` (NEW).

**Acceptance Criteria:**
- [ ] `ExportSettings.resolve(quality:temporalSamples:codec:container:fps:bitrate:
  resolution:segmentFrameBudget:baseFlame:backend:)` is pure + silent (no I/O,
  no stderr); applies the genome-default fallback (`requestedTS==1` and
  `baseFlame.quality.temporalSamples>1` ⇒ genome value, mirroring
  `ExportCommand.swift:374-377`) and the Metal cap (64, `:378-382`).
- [ ] `baseFlame` = the first RENDERABLE flame (CLI passes `renderable[0]`).
- [ ] **String→enum parsing STAYS in the CLI** (the resolver takes parsed enums):
  the `quality` string → `ExportQuality` (incl. the
  `Int(quality) ?? fallbackFlame.quality.samplesPerPixel` defensive fallback,
  `ExportCommand.swift:367` — uses `fallbackFlame`, NOT `renderable[0]`); the
  `resolution` string → `Resolution` (incl. the unknown→`.p1080` default,
  `:385-391`); `codec`/`container`/`bitrate` strings → enums. The GUI builds enums
  directly from its pickers (no string parsing). Both call the same silent resolver.
- [ ] CLI refactor is behavior-identical: existing pins
  `testExportGenomeByteMatchesAnimateFrame5`, `…MotionBlur`
  (`Tests/FlameExportTests/ExportPresetsTests.swift:42,72` — `…MotionBlur` already
  uses the `sierpinski_ts4` fixture via `sierpinskiTS4()` at `:24/:80`), and
  `testTemporalSamples1IsByteIdenticalToNoFlag`
  (`Tests/EmberweftCLITests/AnimateCommandTests.swift:411`) still pass.
- [ ] `testExportSettingsResolveGenomeFallbackAndMetalCap` + `…IsSilent` pass.

**Verify:** `swift test --filter ExportSettingsResolveTests &&
swift test --filter ExportPresetsTests && swift test --filter AnimateCommandTests` → 0 failures.

**Steps:**

- [ ] **Step 1: Write the failing resolver tests** (fallback+cap combos for
  `.metal`/`.cpu`, and a silence assertion capturing stderr).

- [ ] **Step 2: Run red.**

- [ ] **Step 3: Implement `ExportSettings.resolve(…)`** per spec §4.2b. Move the
  fallback + cap LOGIC (not the string parsing or the stderr notice) out of
  `ExportCommand.resolveExportSettings:358-394`.

- [ ] **Step 4: Reduce `ExportCommand.resolveExportSettings`** to: parse strings →
  enums (keeping the `quality`/`resolution`/`bitrate` parsing + their defensive
  defaults VERBATIM, including `fallbackFlame` for the quality-number fallback),
  call `ExportSettings.resolve(…)`, detect `requestedTS != resolved.temporalSamples`
  and print the existing cap notice via `EmberweftCLI.err(…)` (`:380`).

- [ ] **Step 5: Run green** + the named existing CLI/export↔animate pins to prove
  behavior-identity.

- [ ] **Step 6: Commit.** `refactor(export): shared ExportSettings.resolve
  (pure, silent); CLI + GUI build byte-identical jobs`.

---

## Task M6-G.4: EmberweftUI links FlameExport + ExportCoordinating seam (G1 / D-G11)

**Goal:** Let `EmberweftUI` use `ExportCoordinator`, and define the test seam so
`ExportManager` unit tests can inject a fake without Metal/AVFoundation.

**Files:**
- Modify: `Package.swift` (`EmberweftUI` `+FlameExport`; `EmberweftUITests` `+FlameExport`).
- Create: `Sources/FlameExport/ExportCoordinating.swift` (`public protocol ExportCoordinating`).
- Modify: `Sources/FlameExport/ExportCoordinator.swift` (conform to `ExportCoordinating`).

**Acceptance Criteria:**
- [ ] `EmberweftUI` depends on `FlameExport`; `EmberweftUITests` depends on `FlameExport`.
  (No cycle: FlameExport deps = FlameRenderer/FlameReference/FlameKit, all already
  EmberweftUI deps — verified `Package.swift:52,60`.)
- [ ] `public protocol ExportCoordinating` declares `run`/`runBatch` as **`async`**
  and `cancel` as `async` (see Step 2 — the actor's non-async isolated `run`/`runBatch`
  cannot satisfy non-async non-isolated requirements; `async` requirements they can).
- [ ] `ExportCoordinator` conforms with NO body change to its methods (they stay
  non-async isolated; `cancel()` is already async). `swift build` is the proof.
- [ ] `swift build` succeeds; `swift test --filter EmberweftUITests` still green.

**Verify:** `swift build && swift test --filter EmberweftUITests` → green.

**Steps:**

- [ ] **Step 1: Add the dep lines** to `Package.swift` (spec §4.3 + §8: EmberweftUI
  and EmberweftUITests each gain `"FlameExport"`).

- [ ] **Step 2: Define the protocol + conformance** (`Sources/FlameExport/ExportCoordinating.swift`):

```swift
import Foundation
/// Testability seam: ExportManager holds its coordinator via this protocol so
/// EmberweftUITests can inject a fake (no Metal/AVFoundation). ExportCoordinator
/// conforms trivially (it already has these signatures).
public protocol ExportCoordinating: Sendable {
    // run/runBatch are `async` because `ExportCoordinator` is an ACTOR and its
    // `run`/`runBatch` are non-async actor-ISOLATED methods. A non-async
    // non-isolated protocol requirement CANNOT be satisfied by an actor-isolated
    // witness (Swift compile error: "actor-isolated instance method cannot
    // satisfy nonisolated protocol requirement"). An `async` requirement CAN be
    // satisfied by a non-async isolated method — the cross-actor hop makes the
    // call async. `ExportManager` already calls these with `await`
    // (`let stream = await coord.run(job)`), so the async signatures match the
    // call sites. The actor's own method declarations stay non-async (the CLI's
    // `await coord.run(job)` is unchanged).
    func run(_ job: ExportJob) async -> AsyncThrowingStream<ExportProgress, Error>
    func runBatch(_ jobs: [ExportJob], failFast: Bool) async -> AsyncThrowingStream<BatchProgress, Error>
    func cancel() async
}
// ExportCoordinator: add `: ExportCoordinating` to its declaration (no body change).
// The actor's non-async isolated `run`/`runBatch` satisfy the async requirements;
// `cancel()` is already `async`. Verify with `swift build` early in this task.
```
  (If `runLongForm` is also part of the seam the VM uses, include it; spec §4.4
  routes single/sequence through `run`, batch through `runBatch`, so `runLongForm`
  is NOT in the seam — the GUI sets `segmentFrameBudget = 0` so `runLongForm` is
  never dispatched.)

- [ ] **Step 3: Build + run EmberweftUITests** (confirm the new dep didn't break links).

- [ ] **Step 4: Commit.** `feat(ui): EmberweftUI links FlameExport + ExportCoordinating seam`.

---

## Task M6-G.5: ExportManager + ExportQualityChoice (G2 / G4)

**Goal:** The testable `@MainActor @Observable` export VM + the quality mapping,
fully unit-tested with an injected fake coordinator.

**Files:**
- Create: `Sources/EmberweftUI/ExportQualityChoice.swift`.
- Create: `Sources/EmberweftUI/ExportManager.swift` (`ExportState`, `ExportProgressSnapshot`,
  `BackendChoice`, `ExportManager`).
- Test: `Tests/EmberweftUITests/ExportQualityChoiceTests.swift`.
- Test: `Tests/EmberweftUITests/ExportManagerTests.swift`.

**Acceptance Criteria (all from spec §9.4):**
- [ ] `ExportQualityChoice` each case → correct `ExportQuality`; `oversample == 1`
  for all (incl. `.high`); `defaultChoice(from:)` correct.
- [ ] `ExportManager` state machine: `.idle`→`.running`→`.completed(url)` on fake
  success; →`.failed("…")` on `.diskFull`/`.metalUnavailable`; →`.cancelled` on cancel.
- [ ] `cancel()` guards nil coordinator, sets `.cancelling`, calls `coordinator?.cancel()`;
  partial cleaned (fake records it).
- [ ] `resolveBackend` maps auto/cpu/metal × isAvailable correctly (probe stubbed).
- [ ] `canStart` false while `.running`/`.cancelling`.
- [ ] Sleep token acquired once at start, released once on success/cancel/failure
  (via `activityAcquired`/`activityReleased` test hooks).
- [ ] Snapshot mapping deterministic (no Dict/Set iteration; rule #2).

**Verify:** `swift test --filter EmberweftUITests` → `ExportQualityChoiceTests` + `ExportManagerTests` green.

**Steps:**

- [ ] **Step 1: Write `ExportQualityChoiceTests` red** (mapping + oversample + defaultChoice).

- [ ] **Step 2: Implement `ExportQualityChoice`** per spec §4.5. Run green.

- [ ] **Step 3: Write `ExportManagerTests` red** — define a `FakeCoordinator:
  ExportCoordinating` (with `run`/`runBatch` declared `async` matching the protocol)
  that yields a scripted `ExportProgress` stream (or throws a chosen `ExportError`)
  and records `cancel()`/partial-deletion. Cover: success, `.diskFull`,
  `.metalUnavailable`, cancel-mid-stream, `canStart` gate, `resolveBackend` (stub
  the `isAvailable` probe), sleep-token acquire/release (3 sub-tests), snapshot
  determinism (rule #2 round-trip), AND the `ExportProgressSnapshot` normalization
  of BOTH `ExportProgress` (single/sequence ⇒ `jobIndex=0,totalJobs=1`) and
  `BatchProgress` (⇒ `jobIndex/totalJobs` from the event).

- [ ] **Step 4: Implement `ExportManager`** per spec §4.4 — including the
  `coordinatorFactory` seam, fire-and-forget entry points, the `consumeTask`
  (with the corrected `[weak self]` + guarded `coordinator` + tail-clearing from
  D-G5), the cancel-teardown ordering (D-G13: do NOT `consumeTask?.cancel()` as
  the cancel path; use `coordinator?.cancel()`), source routing (D-G5: single/sequence
  ⇒ `run`, batch ⇒ `runBatch`), and the `ProcessInfo` activity token.
  **Job-construction details (verified against `ExportJob`'s required init params,
  `ExportProgress.swift:97-103`):** all three entry points build `ExportJob` with
  `loopCycles: 1, stagger: 0.0, selector: .sequential` (v1 defaults — the sheet
  exposes no loop-cycles/stagger controls); `seed` from the sheet's Seed stepper;
  `framesPerSegment = max(1, Int(loopDurationSeconds * Double(fps)))` (single =
  one loop; sequence = per-segment). Single: `segmentCount: 1`. Sequence:
  `segmentCount: flames.count`. Batch: one job per item, `segmentCount: 1`, `out`
  via `BatchPath.resolve(item.name, base: baseDir)` (the D13 gate) with `-2/-3`
  dedup against existing files. `segmentFrameBudget` is left at 0 (no chunking;
  `runLongForm` is never dispatched). **Entry points are `async`** only because
  they may `await` the coordinator construction in future; the completion-await
  lives inside the spawned `consumeTask`, so they return immediately after
  `state = .running` (the sheet dismisses right after).

- [ ] **Step 5: Run green.**

- [ ] **Step 6: Commit.** `feat(ui): ExportManager + ExportQualityChoice (testable VM)`.

---

## Task M6-G.6: SavePanel + ExportSheet (G3 / G7)  *[manual-tested]*

**Goal:** The destination picker (`NSSavePanel`/`NSOpenPanel`) and the config sheet
bound to `model.exportManager`. (EmberweftGUI — no test target.)

**Files:**
- Create: `Sources/EmberweftGUI/SavePanel.swift` (`chooseSaveURL(defaultName:)`,
  `chooseDirectory()`).
- Create: `Sources/EmberweftGUI/ExportSheet.swift` (the `.sheet` view + an
  `ExportSource` enum: `.single(flame:name:)` / `.sequence(flames:name:)` / `.batch(items:)`).

**Acceptance Criteria (manual, spec §4.6 / §9.5):**
- [ ] Sheet shows a read-only source summary; controls bound two-way to
  `model.exportManager` (codec/container/resolution/fps/qualityChoice/backendChoice/
  temporalSamples/loopDurationSeconds + a Seed stepper).
- [ ] Start disabled unless `canStart` + destination chosen; Metal-unavailable notice.
- [ ] Single/sequence → `NSSavePanel` (default `<stem>.mp4`, overwrite is the single
  gate); batch → `NSOpenPanel` directory, files named via `FlameExport.BatchPath.resolve`
  + `-2/-3` dedup.
- [ ] On Start: call the matching `exportManager.exportX(...)` (fire-and-forget),
  then `dismiss()`.
- [ ] `[manual]` launch `emberweft-gui`, open the sheet from a playback window,
  pick a dest, Start → sheet dismisses, banner appears.

**Verify:** `swift build` + manual launch (`cd .build/arm64-apple-macosx/debug && ./emberweft-gui &`).

**Steps:**

- [ ] **Step 1: `SavePanel.swift`** — thin `@MainActor` runners around `NSSavePanel`
  (`allowedContentTypes: [.mpeg4Movie]`/`.quickTimeMovie`; `nameFieldStringValue`)
  and `NSOpenPanel` (`canChooseDirectories = true; canChooseFiles = false`). Return
  `URL?`.

- [ ] **Step 2: `ExportSheet.swift`** — `struct ExportSheet: View` taking
  `@Environment(AppModel.self)` (use `@Bindable var model = model` for two-way
  bindings to `model.exportManager` per the CLAUDE.md `@Observable` gotcha) and a
  `source: ExportSource`. Layout per spec §4.6 mockup. Start button → resolve
  destination via `SavePanel` → call `exportSingle/exportSequence/exportBatch` →
  `dismiss(environment)`. For `.batch`, reuse `FlameExport.BatchPath.resolve` for each name.

- [ ] **Step 3: Build + manual smoke.**

- [ ] **Step 4: Commit.** `feat(gui): ExportSheet + NSSavePanel/NSOpenPanel destination`.

---

## Task M6-G.7: ExportProgressSurface banner (G8 / D-G9)  *[manual-tested]*

**Goal:** The non-blocking progress banner, observing `model.exportManager`, with
Cancel + Show-in-Finder. (Mounting into windows happens in M6-G.8.)

**Files:**
- Create: `Sources/EmberweftGUI/ExportProgressSurface.swift`.

**Acceptance Criteria (manual, spec §4.7 / §9.5):**
- [ ] `ProgressView(value: snapshot.fraction)` + phase/frame/FPS/elapsed + batch
  `jobIndex/totalJobs`; hidden when `state == .idle`.
- [ ] Cancel button → `await model.exportManager.cancel()`.
- [ ] `.completed(url)` → "Saved to … — Show in Finder"
  (`NSWorkspace.shared.activateFileViewerSelecting([url])`) + Dismiss (`reset()`).
- [ ] `.failed`/`.cancelled` → message + Dismiss.

**Verify:** `swift build` + manual (mount temporarily in one window to smoke).

**Steps:**

- [ ] **Step 1: `ExportProgressSurface.swift`** — `struct ExportProgressSurface: View`
  reading `@Environment(AppModel.self)`. Switch on `model.exportManager.state`.
  Use `ProgressView(value:)` bound to `snapshot.fraction`. Cancel button wraps an
  async `Task { await model.exportManager.cancel() }`.

- [ ] **Step 2: Build.**

- [ ] **Step 3: Commit.** `feat(gui): ExportProgressSurface (non-blocking banner)`.

---

## Task M6-G.8: Wire the three sources + mount the banner (G4)  *[manual-tested]*

**Goal:** Add "Export…" to all three sources, expose the flame(s), hold
`ExportManager` on `AppModel`, and mount the banner in all three window types.

**Files:**
- Modify: `Sources/EmberweftGUI/AppModel.swift` (add `let exportManager = ExportManager()`).
- Modify: `Sources/EmberweftGUI/PlaybackView.swift` (`@State loadedFlame: Flame?`
  set in `start()`; Export button disabled while nil → `.sheet { ExportSheet(.single) }`).
- Modify: `Sources/EmberweftUI/SequencePlaybackViewModel.swift` (add
  `public var resolvedFlames: [Flame] { flames }`).
- Modify: `Sources/EmberweftGUI/CollectionPlaybackView.swift` (Export button →
  `.sheet { ExportSheet(.sequence(flames: vm.resolvedFlames, name: collectionName)) }`).
- Modify: `Sources/EmberweftGUI/SentimentBar.swift` (Export bulk action, enabled
  when `!model.selection.isEmpty`; async-loads flames sorted by
  `GenomeCollectionAppOrder.key`, drops unparseable, surfaces skip count).
- Modify: `Sources/EmberweftGUI/LibraryView.swift` (mount `ExportProgressSurface()`
  in `detailChrome` near `SelectionBar`).

**Acceptance Criteria (manual, spec §4.8 / §9.5):**
- [ ] Single: `loadedFlame` set in `start()`; Export disabled until non-nil.
- [ ] Sequence: `resolvedFlames` accessor added; Export disabled while empty.
- [ ] Batch: async load sorted by `GenomeCollectionAppOrder.key` (rule #2 — never
  persist `Set` order); skip count surfaced; loading indicator.
- [ ] Banner mounted in **all three** window types (LibraryView `detailChrome`,
  `PlaybackWindow.bar`, `CollectionPlaybackWindow.bar`).
- [ ] `[manual]` full §9.5 matrix: single/sequence/batch each produce a correct
  `.mp4`; cancel mid-export deletes partial; scrub a loop during export (no freeze);
  Genome-default frame 0 byte-matches `emberweft animate --frame 0 --size <WxH>`.

**Verify:** `swift build` + the full manual §9.5 matrix on a clean `emberweft-gui` launch.

**Steps:**

- [ ] **Step 1: `AppModel`** — add `public let exportManager = ExportManager()`
  (AppModel is the app-lifetime `@State` in `EmberweftApp.swift:19`, so the VM
  survives sheet/window teardown — G9).

- [ ] **Step 2: `SequencePlaybackViewModel.resolvedFlames`** — one-line read-only
  accessor `public var resolvedFlames: [Flame] { flames }` (reads the `private`
  `flames` at `:57` — D-G7; no behavior change).

- [ ] **Step 3: `PlaybackView`** — `@State private var loadedFlame: Flame?`; set it
  in `begin(flame:)` (`PlaybackView.swift:189`, the shared loader called by BOTH
  `start()` and `forceStart()` — covers the "Open anyway" degenerate path too, so
  Export is enabled once a flame is loaded regardless of how); add Export toolbar
  button in `bar` (`:73`, disabled while `loadedFlame == nil`) presenting
  `ExportSheet(source: .single(flame: loadedFlame!, name: entry.displayName))`.

- [ ] **Step 4: `CollectionPlaybackView`** — Export button in `bar` (`:87`) →
  `ExportSheet(.sequence(flames: vm.resolvedFlames, name: collectionName))`
  (disabled while `vm.resolvedFlames.isEmpty`).

- [ ] **Step 5: `SentimentBar.SelectionBar`** (`:64`) — Export bulk action, enabled
  when `!model.selection.isEmpty`. On tap: `Task { let items = await
  loadSelectionSorted(); presentSheet(.batch(items: items)) }` where
  `loadSelectionSorted` mirrors the EXACT pattern in `saveFromSelection()`
  (`:125-132`): `model.selection.sorted { GenomeCollectionAppOrder.key($0) <
  GenomeCollectionAppOrder.key($1) }` (`:150`), then `await
  model.libraryIndex.loadGenome(for:)` each, filter `isRenderable`, count skips
  (surfaced in the sheet summary). Loading indicator while awaiting.

- [ ] **Step 6: Mount the banner** in all three windows. `LibraryView.detailChrome`
  (`:304`) is a `@ViewBuilder func` whose content carries an `.overlay(alignment:
  .bottom)` (`:311`) that shows `SelectionBar()` (`:313`) when there's a selection.
  Add `ExportProgressSurface()` as a SECOND `.overlay(alignment: .top)` on the same
  content (top, so it never collides with the bottom selection bar), gated on
  `model.exportManager.state != .idle`. Also add it to `PlaybackWindow.bar`
  (`:73`) and `CollectionPlaybackWindow.bar` (`:87`) — e.g. an `.overlay` on the
  `VStack` or inline in the bar.

- [ ] **Step 7: Build + run the full manual §9.5 matrix.**

- [ ] **Step 8: Commit.** `feat(gui): wire Export… into playback/sequence/batch +
  non-blocking banner in all windows`.

---

## Task M6-G.9: Close M6 — docs, dist, release

**Goal:** Update docs to M6 ✅ Done, build the distributable, run the full
acceptance matrix, tag v0.5.0.

**Files:**
- Modify: `CHANGELOG.md` (v0.5.0 entry), `README.md` (status + export section),
  `docs/engineering/roadmap.md` (M6 ✅, status line, patch list).
- Modify: `CLAUDE.md` (M6-GUI gotchas via `/claude-md-management:revise-claude-md`).
- Build: `make dist`.

**Acceptance Criteria (spec §9.6):**
- [ ] All `[automated]` tests green (`swift test --filter FlameRendererTests`,
  `--filter FlameExportTests`, `--filter EmberweftUITests`, `--filter EmberweftCLITests`).
- [ ] `git diff --name-only main | grep -E 'Sources/(FlameKit|FlameReference)/'` empty.
- [ ] `make dist` produces a working `dist/emberweft-gui` that exports a real genome.
- [ ] Docs reflect M6 ✅ Done (v0.5.0); roadmap M6 row + status line + patch list updated.
- [ ] CLAUDE.md records the new gotchas (off-main temporal Metal +
  `ExportCoordinator.useOffMainMetal` flag; the `ExportCoordinating` seam; the
  `loadedFlame`/`resolvedFlames` accessors; `NSSavePanel` works on the bundle-less exe).
- [ ] Tag `v0.5.0`; release notes plain/factual, no em dashes, no AI marketing tells
  (CLAUDE.md).

**Verify:** the full `make test-fast` + `swift test --filter FlameExportTests` +
manual §9.5 matrix + `make dist` smoke.

**Steps:**

- [ ] **Step 1: Run the full automated gate** (sandbox off).

- [ ] **Step 2: Update docs** — CHANGELOG v0.5.0 (Added: GUI export sheet + progress
  banner + 3 sources + presets; off-main temporal Metal. Changed: shared
  `ExportSettings.resolve`. Fixed: none), README status + "Exporting video" GUI
  section, roadmap M6 ✅.

- [ ] **Step 3: `make dist`** + smoke: `cd dist && ./emberweft-gui &` → export a genome.

- [ ] **Step 4: CLAUDE.md gotchas** via the revise skill.

- [ ] **Step 5: Commit docs** (`docs(m6): M6 complete — GUI export (v0.5.0)`).

- [ ] **Step 6: Tag + release** (`git tag v0.5.0`; `gh release create v0.5.0 … --notes`
  inline, from the repo dir).

---

## Dependencies (build order)

```
M6-G.1 (engine extraction)
  └─ M6-G.2 (coordinator flag)
       └─ M6-G.3 (shared resolver + CLI refactor)
            └─ M6-G.4 (deps + ExportCoordinating seam)
                 └─ M6-G.5 (ExportManager + Quality)
                      ├─ M6-G.6 (ExportSheet + SavePanel)   ┐ parallelizable
                      └─ M6-G.7 (ProgressSurface)           ┘ (disjoint files)
                            └─ M6-G.8 (wire sources + mount banner)
                                 └─ M6-G.9 (close M6)
```

M6-G.6 and M6-G.7 touch disjoint files and both depend only on M6-G.5 → they may
run in parallel. All other tasks are sequential (shared module/file dependencies).

---

## Self-review (run before handoff)

- **Spec coverage:** every spec §4 design unit → a task? E1→G.1; E2a→G.2; E2b/G5→G.3;
  G1/seam→G.4; G2/G4→G.5; G3/G7→G.6; G8→G.7; G4 wiring→G.8; §9.6 DoD→G.9. ✓
- **Placeholder scan:** NO `fatalError`/TBD/TODO placeholders remain. The
  `OffMainTemporalParityTests` now construct temporal args inline via
  `TemporalFilter.samples` (the same 2-line pattern `TemporalBlurMetalTests` uses —
  there is no reusable "descriptor builder" helper to copy; that earlier claim was
  wrong and has been corrected). Genome loaders copy existing named patterns
  (`TemporalBlurMetalTests.loadFrozen` / `MetalFrameRendererSmokeTests.realGenome`). ✓
- **Type/name consistency:** `renderTemporalOffMain`, `renderTemporalFusedCore`,
  `ExportCoordinating` (`run`/`runBatch` `async`, `cancel` `async`),
  `ExportManager.exportSingle/exportSequence/exportBatch`,
  `ExportQualityChoice`, `resolvedFlames`, `loadedFlame` — identical across tasks. ✓
- **Test names** match spec §9 (the review-corrected real names:
  `testExportGenomeByteMatchesAnimateFrame5` etc.). ✓

---

## Plan-review defects & fixes (audited against `main`)

Every claim below was verified by reading the cited source file on `main`. The
in-place edits above resolve them; this is the changelog.

### Correctness
1. **`ExportCoordinating` protocol would not compile (M6-G.4).** The protocol
   declared `run`/`runBatch` as non-async, but `ExportCoordinator` is an `actor`
   whose `run`/`runBatch` are non-async **actor-isolated** methods. A non-async
   non-isolated protocol requirement cannot be satisfied by an actor-isolated
   witness (Swift: "actor-isolated instance method cannot satisfy nonisolated
   protocol requirement"). **Fix:** declared `run`/`runBatch` `async` in the
   protocol (an async requirement CAN be satisfied by a non-async isolated method
   — the cross-actor hop makes the call async). `ExportManager` already calls them
   with `await`; the actor's own method declarations are unchanged. `cancel()` was
   already `async`. (Highest-severity finding; flagged for early `swift build`.)
2. **`sierpinski_ts4.flam3` fixture already exists (M6-G.1 Step 1).** The plan
   said "create" it, but it is on `main` (with `temporal_samples="4"`) and is
   already consumed by `testExportGenomeByteMatchesAnimateFrame5MotionBlur`
   (`ExportPresetsTests.swift:80`). **Fix:** Step 1 now says "verify exists".
3. **`OffMainTemporalParityTests` helper was a `fatalError` placeholder (M6-G.1
   Step 2).** It claimed to "mirror `TemporalBlurMetalTests`' descriptor builder",
   but no such reusable helper exists — `TemporalBlurMetalTests` builds temporal
   inline via `TemporalFilter.samples(N, type:width:exp:)` (`TemporalFilter.swift:14`,
   `TemporalFilterType` `.box`/`.gaussian` at `Genome.swift:82-83`). The undefined
   `loadFixture`/`loadRealGen248Sheep`/`sierpinskiFlame`/`tinyParams` helpers were
   also pseudo-code. **Fix:** rewrote the tests with real inline construction +
   real `#filePath`/CWD-relative loaders copied from existing tests; made every
   test `@MainActor` + `XCTSkip` on no-Metal (matching `TemporalBlurMetalTests`).
4. **`renderTemporalOffMain`'s `try?` cannot catch the `precondition` trap
   (M6-G.1).** `renderTemporalFused` opens with `precondition(!temporal.isEmpty)`
   (`:484`), which the extraction carries into the core. `try?` catches throws,
   not traps; the box guard runs after and does not cover empty. **Fix:** added a
   note that empty temporal is a never-hit caller invariant (coordinator only
   takes the temporal branch when `plan.temporalSamples > 1` ⇒ `TemporalFilter.samples`
   ⇒ non-empty) and recommended a defensive `guard !temporal.isEmpty` at the top
   of the off-main entry. Not a correctness bug; documented.
5. **M6-G.2 off-main probe was unsound (M6-G.2 AC).** It specified a
   "`Thread.isMainThread` probe inside an injected hook", but the coordinator has
   no injectable render hook, and a MainActor-sentinel race is racy/hard to assert.
   **Fix:** the test now asserts completion + byte-identity of a 1-frame
   `useOffMainMetal:true` job vs the MainActor path (transitively proves the
   branch is wired AND off-main-rendered). Off-main-ness itself is already pinned
   by `MetalFrameRendererSmokeTests` (single-pass) + the new M6-G.1 temporal pins.

### Regressions (verified safe)
6. **`ExportCoordinator.init(backend:)` call sites** — all 13 use the single-arg
   form (`ExportCommand.swift:291,518`; `ExportBatchTests`×4; `ExportLongFormTests`×5;
   `ExportCoordinatorTests`×2). The defaulted `useOffMainMetal: Bool = false`
   preserves every one. ✓
7. **`Package.swift` dep additions** — `EmberweftUI`+`FlameExport` and
   `EmberweftUITests`+`FlameExport` introduce no cycle (FlameExport's deps are
   FlameRenderer/FlameReference/FlameKit, all already EmberweftUI deps). ✓
8. **CLI refactor behavior-identity (M6-G.3)** — made explicit that the resolver
   takes PARSED enums; the CLI keeps ALL string→enum parsing verbatim, including
   the `quality`-number fallback to `fallbackFlame.quality.samplesPerPixel`
   (`:367`, uses `fallbackFlame` not `renderable[0]`) and the `resolution`
   unknown→`.p1080` default (`:390`). The three named existing pins are at the
   cited locations (`ExportPresetsTests.swift:42,72`; `AnimateCommandTests.swift:411`).
9. **Engine extraction disturbs nothing in FlameKit/FlameReference** — the
   `git diff --name-only | grep Sources/(FlameKit|FlameReference)` guard (M6-G.1
   Step 6, M6-G.9 AC) enforces it.

### Completeness / Integration
10. **`ExportJob` requires `loopCycles`+`stagger`** (`ExportProgress.swift:97-103`).
    The plan never stated the GUI values. **Fix:** M6-G.5 Step 4 now specifies
    `loopCycles: 1, stagger: 0.0, selector: .sequential` (v1 defaults; the sheet
    exposes no such controls), `segmentFrameBudget: 0` (no chunking ⇒ `runLongForm`
    never dispatched), and the `framesPerSegment = round(loopDurationSeconds*fps)`
    derivation.
11. **`ExportProgressSnapshot` normalization of BOTH event types** was under-specified.
    **Fix:** M6-G.5 Step 3 now requires the test to cover `ExportProgress`
    (⇒ `jobIndex=0,totalJobs=1`) AND `BatchProgress` (⇒ from-event) normalization.
12. **`LibraryView.detailChrome` banner mount** — `detailChrome` (`:304`) is a
    `@ViewBuilder func` whose content has an `.overlay(alignment: .bottom)` (`:311`)
    holding `SelectionBar()` (`:313`). "Near SelectionBar" was ambiguous.
    **Fix:** M6-G.8 Step 6 now specifies a SECOND `.overlay(alignment: .top)` on
    the same content (top, to avoid colliding with the bottom selection bar),
    gated on `state != .idle`.
13. **`loadedFlame` placement** — set in `begin(flame:)` (`:189`, shared by both
    `start()` and `forceStart()`), not just `start()`, so Export is enabled after
    the "Open anyway" degenerate path too. **Fix** applied to M6-G.8 Step 3.
14. **FramePlan location** — `Sources/FlameKit/FramePlan.swift` (not FlameExport);
    `FrameDescriptor` fields `blend/blendAt/temporal/sumfilt` with NO
    `centerTime`/`flame` field — VERIFIED (`:7-24`). The plan/spec field-name usage
    is correct.

### Verified-claim spot-checks (no fix needed)
- `commandQueue` is `@MainActor` (`MetalQueues.swift:3-5`, a `@MainActor extension`). ✓
- `renderTemporalFused`'s body references exactly `deviceAndLibrary()` (`:493`),
  `commandQueue` (`:496`), `fusedPipelines()` (`:617`) as MainActor state — the
  extraction's three params are correct. ✓
- `offMainCache.handles()`→`(MTLDevice,MTLLibrary,MTLCommandQueue)?` and
  `pipelines(device:library:)`→5-PSO tuple (`MetalOffMainCache.swift:27,45`). ✓
- `MetalRenderer.isAvailable` is `@MainActor` (`:26`); probed on MainActor in
  `ExportManager.resolveBackend()` (EmberweftUI links FlameRenderer). ✓
- `EmberweftApp` sets `.regular` activation policy (`:11`) ⇒ `NSSavePanel`/
  `NSOpenPanel` work on the bundle-less exe. ✓
- `AppModel.selection: Set<LibraryEntry>` (`:42`); `applySentiment` (`:265`) sorts
  before iterating (rule #2) — the batch-Export pattern to mirror. ✓
- `GenomeCollectionAppOrder.key` (`SentimentBar.swift:151`) and the
  `saveFromSelection()` sort pattern (`:125-132`) — verified, mirrored in M6-G.8. ✓
- `BatchPath.resolve(_:base:)` (`ExportProgress.swift:60`, throws `BatchPathError`)
  + `ExportError` cases (`VideoEncoder.swift:186`) — verified. ✓
- `AppPreferences.renderParams(width:height:)` has NO production callers
  (only `AppPreferencesTests.swift:51`) — dormant; `QualityPreset.high` = spp 30 /
  oversample 2 (`:315,322`) ⇒ `.spp(30)` oversample-pinned-1 is faithful (G4). ✓

### Could not verify / owner decision
- **The actor→protocol async conformance (defect #1)** is flagged from Swift 6
  concurrency semantics (high confidence), but the implementer should `swift build`
  M6-G.4 early as the proof. Not an owner decision — a compile-checkable fact.
