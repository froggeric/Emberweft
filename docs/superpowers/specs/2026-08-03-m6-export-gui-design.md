# M6 Export — GUI Slice (Developer-Ready Specification)

> **Status:** developer-ready spec · supersedes nothing (builds on
> [`2026-08-02-m6-export-pipeline-design.md`](./2026-08-02-m6-export-pipeline-design.md),
> the M6 engine+CLI spec). **No implementation in this document.**
>
> **Scope:** the remaining M6 slice — the GUI video-export surface that closes
> the milestone's "Export progress UI with cancellation" / "progress bar" / "≥3
> presets" Definition-of-Done items. The engine + `emberweft export` CLI shipped
> in v0.4.0; this spec adds the app-side UI and **one parity-neutral engine
> extraction** the GUI requires (off-main temporal Metal).

---

## 1. Context

**Why this exists.** v0.4.0 shipped the export *engine* (`FlameExport`:
`ExportCoordinator`, `VideoEncoder`, `PixelBufferPool`, `FramePlan`,
`ThreadSeedBudget`) and the headless `emberweft export` CLI. Frames are
byte-identical to `emberweft animate`. The roadmap M6 DoD, however, also lists
"Export progress UI with cancellation," "progress bar," and "≥3 export
presets" — none of which the CLI satisfies. This slice closes M6 by adding the
app-side export UI.

**The one owner decision (resolved 2026-08-03).** The GUI cannot render Metal
via the CLI's `await MainActor.run { MetalRenderer.render(…) }` — that freezes
the UI for the full GPU wait each frame (~25–36 ms/frame at 1080p).
`MetalRenderer.renderOffMain` is off-main but **single-pass only**; the temporal
(motion-blur) path `renderTemporalFused` is `@MainActor`-only. Real ES genomes
default to `temporal_samples ≈ 1000`, and motion blur is what makes transitions
seamless (the "brutal mid-transition morph" gotcha). The owner chose **option
(b): add an off-main temporal Metal path** — a parity-neutral, mechanical
extraction mirroring the proven `renderFusedCore` / `renderOffMain` split. This
slice therefore includes that engine extraction; the CLI path is untouched.

**What's already on `main` (verified — do not rebuild):**
- `ExportCoordinator` (`Sources/FlameExport/ExportCoordinator.swift:16`) is a
  `public actor` with `init(backend:)`, `run(_:)`, `runLongForm(_:)`,
  `runBatch(_:failFast:)`, `cancel()`, all returning / driving
  `AsyncThrowingStream<ExportProgress, Error>` (or `BatchProgress`). Its private
  `renderFrames` dispatches Metal via `await MainActor.run { autoreleasepool {
  MetalRenderer.render(…) } }` and CPU via `await Task.detached {
  ReferenceRenderer.render(…) }.value` (`ExportCoordinator.swift:172–188`). It
  checks `Task.isCancelled` between frames and throws `ExportError.cancelled`.
- `ExportSettings` (`ExportSettings.swift:6`): `codec (.h264/.hevc)`,
  `resolution (.p720/.p1080/.p1440/.p4k/.custom(w:h))`, `fps`, `quality
  (ExportQuality)`, `temporalSamples`, `container (.mp4/.mov)`, `bitrate
  (.auto/.mbps(Int))`, `segmentFrameBudget` (>0 ⇒ long-form), `metadata`. Public
  `init() {}`.
- `ExportQuality` (`ExportSettings.swift:39`): `.genome` (byte-identical to
  `animate`) | `.spp(Int)`; `resolvedSamplesPerPixel(for:)` always returns
  `oversample = 1` (M6 engine spec **D6**).
- `ExportProgress` (`ExportProgress.swift:12`): `phase (.rendering/.encoding/
  .concatenating/.finalizing)`, `currentFrame`, `totalFrames`, `elapsed`,
  `renderFPS`. `BatchProgress`: `jobIndex`, `totalJobs`, `jobFrame`,
  `jobTotalFrames`, `aggregateFraction`, `failed`. `ExportJob`: `settings`,
  `flames`, `framesPerSegment`, `segmentCount`, `selector`, `seed`,
  `loopCycles`, `stagger`, `out`, `partialURL` (derived).
- `ExportError` (`VideoEncoder.swift:186`): `cancelled`, `encodeFailed`,
  `metalUnavailable`, `genomeUnparseable`, `diskFull`.
- `MetalRenderer.renderOffMain(flame:params:seedBudget:) -> RGBA8Image?`
  (`MetalRenderer.swift:451`): `nonisolated`, single-pass, delegates to
  `renderFusedCore`, runs on `offMainQueue.sync`, returns nil on failure.
  Byte-identical to the MainActor path (pinned by `testRenderOffMainMatches…`).
- `MetalRenderer.renderFusedCore(flame:params:device:queue:psos:seedBudget:)`
  (`MetalRenderer.swift:177`): the actor-agnostic **single-pass** core — the
  extraction pattern this slice replicates for the temporal path.
- `MetalRenderer.renderTemporalFused(blendAt:centerTime:temporal:sumfilt:
  params:seedBudget:)` (`MetalRenderer.swift:475`): `@MainActor`, the temporal
  motion-blur path (N chaos passes into one `atomicBuf`). Its body references no
  MainActor state except `deviceAndLibrary()`, `commandQueue`, `fusedPipelines()`
  — exactly the three handles `renderFusedCore` takes as parameters.
- `MetalRenderer.isAvailable` (`MetalRenderer.swift:26`): `@MainActor` (calls
  `MainActor.assumeIsolated`) — **traps if called off-main**.
- `AppPreferences.qualityPreset: QualityPreset` (`AppPreferences.swift:11`,
  default `.medium`); `QualityPreset` cases `low/medium/high` (`:313`), spp
  `2/8/30` (`:315`), `oversample` `1/1/2` (`:322`). `renderParams(width:height:)`
  (`:196`) has **no production callers** (only a test) — the dormant export-quality
  field, ready to wire.
- `AppModel` (`Sources/EmberweftGUI/AppModel.swift:9`): `@MainActor @Observable`,
  owns `prefs`, `libraryIndex`, `thumbnailService`, `metadataStore`,
  `collectionsStore`, `facets`, load-states, and `selection: Set<LibraryEntry>`
  (`:42`). It has **no** window-opening methods; views use
  `@Environment(\.openWindow)`.
- `PlaybackWindow` (`PlaybackView.swift:6`): holds `entry: LibraryEntry` +
  `@State vm = PlaybackViewModel()`; loads the flame in `start()` (`:173`); the
  transport is the private `bar` (`:73`, a play/pause + scrubber + cluster +
  Close). **Single-genome source.**
- `CollectionPlaybackWindow` (`CollectionPlaybackView.swift:24`): holds
  `collectionId: UUID` + `@State vm = SequencePlaybackViewModel()`; loads the
  collection's `[Flame]` in `load()` (`:154`). **Sequence source.**
- `SequencePlaybackViewModel` (`Sources/EmberweftUI/SequencePlaybackViewModel.swift:38`):
  `@MainActor @Observable`; `load(flames:prefs:)`, play/pause/stop, publishes
  `currentSheep`, `position`, `measuredFPS`. Already holds the resolved `[Flame]`
  the sequence export needs.
- `LibraryView` multi-select lives on `AppModel.selection`; the bulk-action bar
  is `SelectionBar` (`SentimentBar.swift:64`) with `applySentiment(_:to:)`
  (`AppModel.swift:265`) as the pattern to mirror. **Batch source.**
- `Package.swift`: `EmberweftUI` deps `FlameKit, FlameReference, FlameRenderer,
  FlamePlayer` (`:60`) — **not** `FlameExport`. `EmberweftGUI` deps
  `EmberweftUI, FlameKit` (`:66`). `FlameExport` deps `FlameRenderer,
  FlameReference, FlameKit` (`:52`); only `EmberweftCLI` links it. No `NSSavePanel`
  / `NSOpenPanel` / `.fileExporter` anywhere in the app today.

**Out of scope (deferred — do NOT pull in):**
- An export *queue* / concurrent multi-job rendering (batch stays **sequential** —
  one Metal render at a time, avoids GPU contention). Single concurrent export.
- ProRes / AV1 / HDR / 10-bit / alpha video, audio tracks, `BGProcessingTask`
  (finish-after-quit). All M7/M8.
- A floating non-modal progress *panel* (v1 uses a main-window banner; §4.7).
- Changes to the parity gate or any renderer math other than the §4.1 extraction.

---

## 2. Defects found in the naive "just build a sheet" approach & overrides

| # | Naive approach | Defect | Override in this spec |
|---|---|---|---|
| **G1** | "Put `ExportViewModel` in `EmberweftGUI`" | `EmberweftGUI` has **no test target** (CLAUDE.md); all testable GUI logic must live in `EmberweftUI`. | `ExportManager` (testable `@MainActor @Observable`) in `EmberweftUI`; `ExportSheet`/views (thin SwiftUI) in `EmberweftGUI`. Add `FlameExport` to `EmberweftUI` deps. §3, §4.3. |
| **G2** | "Metal export via `MainActor.run` like the CLI" | Freezes the UI ~25–36 ms/frame at 1080p (`waitUntilCompleted` on main). | Off-main temporal Metal extraction (§4.1) + coordinator `useOffMainMetal` flag (§4.2). GUI off-main; CLI unchanged (flag default false). |
| **G3** | "No off-main temporal path ⇒ motion-blur exports are sharp or freeze" | Real ES genomes default ts≈1000; sharp looks "brutal"; CPU fallback is slow (~6–17 s/frame). | `renderTemporalOffMain` (§4.1) — byte-identical off-main temporal. |
| **G4** | "Wire `qualityPreset.oversample` to export" | `QualityPreset.high` is `oversample=2`; export byte-identity with `animate` requires `oversample=1` (engine spec **D6**). | Map `QualityPreset → ExportQuality.spp(spp)` with **oversample pinned 1**; offer `.genome` (byte-identical) as the default choice. §4.5. |
| **G5** | "Duplicate `ExportCommand`'s settings-resolution in the GUI" | Drift ⇒ GUI builds jobs differently from CLI ⇒ silently breaks the export↔animate byte-identity pin. | Extract `ExportSettings.resolve(…)` into `FlameExport`, shared by CLI + GUI. DRY; single source of truth for the motion-blur fallback + Metal cap. §4.5. |
| **G6** | "Probe `MetalRenderer.isAvailable` from the coordinator" | It is `@MainActor` (`MainActor.assumeIsolated`) — **traps off-main**. | Probe in `ExportManager` (`@MainActor`; `EmberweftUI` links `FlameRenderer`) and pass the resolved `Backend` to the coordinator. The coordinator never probes. §4.4. |
| **G7** | "`.fileExporter` for the destination" | Video needs a raw file URL for `AVAssetWriter` / `ExportJob.out`; `.fileExporter` is `Transferable`/`FileDocument`-based. | `NSSavePanel` (single/sequence) and `NSOpenPanel`-dir (batch). §4.6. |
| **G8** | "Modal sheet stays open for the whole export" | Blocks the app for seconds-to-minutes. | Non-blocking: sheet dismisses on Start; `ExportProgressSurface` banner in the main window (always visible). §4.7. |
| **G9** | "`@State var vm` on the sheet / source window" | Dismissal or window-close releases the VM mid-export (the M4 sheet-teardown leak). | `ExportManager` held on `AppModel` (persists across sheets/windows). §4.4. |
| **G10** | "Ignore system/display sleep" | `AVAssetWriter` stalls when the display sleeps (the FCPx / Adobe export-pause problem). | `ProcessInfo.beginActivity([.userInitiated, .idleDisplaySleepDisabled, .idleSystemSleepDisabled])` held for the run; `endActivity` in `defer`. §4.9. |
| **G11** | "Pin GUI↔animate byte-identity with sierpinski (ts=1) only" | Hides the motion-blur divergence (the v0.4.0 Task-5 bug class). | Shared resolver (G5) + off-main byte-identical path; regression pin uses a **ts>1** fixture (`sierpinski_ts4`, `Tests/Goldens/fixtures/`). §9. |

**Kept from the engine spec:** the engine's cancel lifecycle (**D12** — cooperative
between frames, `cancelWriting()` not `finishWriting()`, temp cleanup in `defer`),
atomic partial→final handoff + disk precheck + path safety (**D13**), batch
semantics (**D11**), and the byte-identity-with-animate contract (**§12.1 of the
engine spec**) are inherited unchanged. This slice does not re-litigate them.

---

### 2b. Review defects & overrides (adversarial principal-engineer pass)

Every claim below was verified against `main` by reading the cited file. The
in-place fixes above resolve them; this table is the audit trail.

| # | Spec section | Defect (verified against the code) | Resolution applied |
|---|---|---|---|
| **D-G1** | §4.2a pseudocode | Used `descriptor.centerTime` and `descriptor.flame` — **neither field exists**. `FrameDescriptor` (`FramePlan.swift:7-24`) has `blend` (the center time) and `blendAt` (a closure); the flame is `d.blendAt(d.blend)`. Single-vs-temporal is decided by `plan.temporalSamples > 1` (`ExportCoordinator.swift:175`), not `descriptor.temporal.count`. | Pseudocode rewritten with the verbatim field names + decision variable; cites the exact source lines. |
| **D-G2** | §4.2b resolver | Proposed `ExportSettings.resolve(quality:temporalSamples:…:baseFlame:backend:)` but the real `resolveExportSettings` (`ExportCommand.swift:358`) takes STRING args and does the parsing, AND prints a stderr cap-notice (`:380`). A FlameExport resolver cannot call `EmberweftCLI.err` (wrong layer). Also `baseFlame` conflated the CLI's `renderable[0]` (temporal) vs `fallbackFlame` (quality). | Resolver takes parsed enums (string-parsing stays in CLI); is PURE + SILENT; `baseFlame` = first RENDERABLE flame; the CLI/GUI detect the cap (requested vs resolved) and print their own notice. §4.2b rewritten. |
| **D-G3** | §4.4 entry points | Marked `exportSingle/exportSequence/exportBatch async` but didn't say they're fire-and-forget (the §4.6 "On Start: call exportX(), then dismiss()" implied it). | Explicit: entry points set `state=.running`, spawn `consumeTask`, RETURN; the sheet dismisses immediately. |
| **D-G4** | §4.4 source routing | `exportSequence ⇒ runLongForm` but `segmentFrameBudget` was unspecified → undefined chunking, and the concat/temp machinery is needless for v1. | Sequence uses `run` (single encode, `segmentCount=flames.count`); `runLongForm`/concat deferred. `run` iterates `[0,totalFrames)` over all segments in one `AVAssetWriter` session — simpler, correct, no temps. |
| **D-G5** | §4.4 consumeTask | `self.coordinator!` force-unwrap + `coordinator = nil` at tail races with `cancel()` referencing `coordinator`; no note on why `[weak self]` is safe here (unlike the M4 sheet-VM case). | `guard let coord = self.coordinator else { return }`; `cancel()` guards nil; `consumeTask` cleared at tail to break the cycle; added the weak-self rationale (AppModel-owned ⇒ not sheet-released). |
| **D-G6** | §4.8 single source | "PlaybackWindow exposes the loaded Flame" — **FALSE**. The flame is a local in `start()` (`PlaybackView.swift:175`); `PlaybackViewModel.flame` is `private` (`:37`). | `PlaybackWindow` adds `@State private var loadedFlame: Flame?` set in `start()`; Export button disabled until non-nil. |
| **D-G7** | §4.8 sequence source | "SequencePlaybackViewModel exposes its resolved `[Flame]`" — **FALSE**. `flames` is `private` (`SequencePlaybackViewModel.swift:57`). | Add `public var resolvedFlames: [Flame] { flames }` (read-only; no behavior change). |
| **D-G8** | §4.8 batch source | Implied `libraryIndex.loadGenome` is sync/cheap; it's `async` and a large selection is slow. The `Set` order must not be persisted (rule #2). | Batch Export… action loads flames async (sorted by `GenomeCollectionAppOrder.key`, rule #2), drops unparseable, surfaces a skip count; brief loading indicator. |
| **D-G9** | §4.7 banner visibility | "Main `LibraryView` window (always open)" — **FALSE**. Each `WindowGroup` window is closable via ⌘W (`EmberweftApp.swift:22,37,61`). Closing it hides a LibraryView-only banner. | Banner mounted in all three window types (`detailChrome` + both playback bars); degraded-when-all-closed documented (export continues on AppModel; no visible Cancel). |
| **D-G10** | §7 / §12 contention | `renderTemporalOffMain` and `ThumbnailService.renderOffMain` (`:121`) both `offMainQueue.sync` on the SAME serial queue (`MetalRenderer.swift:439`) ⇒ they serialize. Not flagged. | Documented as a bounded (~25–50 ms) non-deadlock stall; added to §7 + §12. Realtime MainActor playback is unaffected (different queue). |
| **D-G11** | §8 test deps | `EmberweftUITests` deps (`Package.swift:119`) lack `FlameExport`; the new `ExportManagerTests` integration cases can't link the coordinator. | Add `"FlameExport"` to `EmberweftUITests` deps; logic tests use an `ExportCoordinating` protocol fake (sandbox-independent). |
| **D-G12** | §9.2/§9.3 test names | Cited `testRenderOffMainMatchesMainActorPath` (correct name, wrong location — it's in `EmberweftUITests/MetalFrameRendererSmokeTests.swift:55`, not FlameRendererTests) and `testExportMatchesAnimateFrame` (doesn't exist — the real pin is `testExportGenomeByteMatchesAnimateFrame5`, `ExportPresetsTests.swift:42`). | Real names + file locations cited; new temporal pins go in FlameRendererTests. |
| **D-G13** | §9.4 ACs | Several ACs were vague ("assert via a test hook", "code review + deterministic round-trip"). | Each AC now names an observable + a pass/fail value; the protocol fake + test hooks (`activityAcquired/Released`) are concretely specified. |
| **D-G14** | §6 byte-identity | Overclaimed "GUI export is byte-identical to `animate --frame N`" without the resolution caveat — `animate` defaults to genome-native size (`AnimateCommand.swift:135`), the GUI to a tier. | Qualified: byte-identity holds only at matching `width/height`; the GUI AC compares against `animate --size WxH`. |
| **D-G15** | §4.6 batch naming | "mirror the CLI's `BatchPath.resolve`" — vague. The real gate is `FlameExport.BatchPath.resolve(_:base:)` (`ExportProgress.swift:60`); dedup suffix wasn't specified. | GUI reuses `BatchPath.resolve` verbatim (the D13 gate) + `-2/-3` dedup; documented in §4.6. |

**What the review CONFIRMED (no fix needed):** the §4.1 extraction is sound —
`renderTemporalFused`'s body (`MetalRenderer.swift:484-785`) references exactly
three MainActor handles (`deviceAndLibrary()` `:493`, `commandQueue` `:496`
[defined `MetalQueues.swift:5`, a `@MainActor extension`], `fusedPipelines()`
`:617`), matching `renderFusedCore`'s param set; all other helpers
(`MetalHost.*`, `DisplayPipelineMetal.*`, `buildDmap`, `Flam3XformDistrib`) are
already nonisolated (the CLAUDE.md de-isolation gotcha). `offMainCache.handles()`
returns `(MTLDevice, MTLLibrary, MTLCommandQueue)?` and `pipelines(device:library:)`
returns the 5-PSO tuple (`MetalOffMainCache.swift:27,45`). `ThreadSeedBudget` is
`final class: @unchecked Sendable` (`ThreadSeedBudget.swift:23`) with
`NSLock`-guarded `seeds(forPass:threadCount:)` — passing it wholesale is
byte-identical and race-free. `MetalRenderer.isAvailable` is `@MainActor`
(`:26`), probeable from `ExportManager` (`@MainActor`, EmberweftUI links
FlameRenderer). `ExportError` cases match (`VideoEncoder.swift:186`). The
box-guard nil-vs-fatalError choice is sound. `Flame.isRenderable` is in FlameKit
(`GenomeHealth.swift:9`). `AppPreferences.renderParams(width:height:)` has NO
production callers (dormant). `QualityPreset.high` = spp 30 / oversample 2
(`AppPreferences.swift:315,322`), so `.spp(30)` with oversample pinned 1 is
faithful (G4). `ExportCoordinator.init(backend:)` (`:30`) takes the flag cleanly.
`EmberweftApp` sets `.regular` activation policy (`:11`) so `NSSavePanel`/
`NSOpenPanel` work on the bundle-less executable.

---

## 3. Architecture & module boundary

```
FlameKit      (unchanged)
  ├─ FlameReference  (unchanged — CPU oracle)
  ├─ FlameRenderer   (E1: renderTemporalFusedCore extraction + renderTemporalOffMain)
  │    └─ FlameExport (E2: ExportSettings.resolve(…) shared; ExportCoordinator useOffMainMetal flag)
  └─ FlamePlayer     (unchanged — realtime)
EmberweftUI   (G1: +FlameExport dep;  G2: ExportManager, ExportQualityChoice, ExportProgressSnapshot)
  ▲ held by
EmberweftGUI  (G3: ExportSheet, SavePanel, ExportProgressSurface;  G4: wire PlaybackWindow /
               CollectionPlaybackWindow / SelectionBar;  AppModel holds ExportManager)
```

**Testability rule (load-bearing, G1):** every predicate / state-machine /
mapping / VM lives in `EmberweftUI` and is covered by `@testable import
EmberweftUI` tests. `EmberweftGUI` files only wire logic to SwiftUI and are
verified manually (EmberweftGUI has no test target).

---

## 4. Design

### 4.1 E1 — Off-main temporal Metal extraction (the only engine-code touch)

Mechanical, byte-identical, mirrors `renderFusedCore` / `renderOffMain`.

**(a) Extract the core.** Move the body of `renderTemporalFused`
(`MetalRenderer.swift:483–785`) verbatim into an actor-agnostic core that takes
the three MainActor handles as parameters — exactly as `renderFusedCore`
(`:177`) already does for the single-pass path:

```swift
// Sources/FlameRenderer/MetalRenderer.swift  (NEW — actor-agnostic temporal core)
/// Actor-agnostic temporal motion-blur core — the temporal twin of
/// `renderFusedCore`. Identical body to `renderTemporalFused`; the three
/// MainActor handles (device/queue/psos) are passed in so it runs identically
/// on the MainActor (via `renderTemporalFused`) OR off-main (via
/// `renderTemporalOffMain`). Output is byte-identical either way — the GPU
/// computation is independent of the encoding thread; only the thread that
/// blocks on `waitUntilCompleted` differs (main vs `offMainQueue`).
static func renderTemporalFusedCore(
    blendAt: (Double) -> Flame,
    centerTime: Double,
    temporal: [(delta: Double, weight: Double)],
    sumfilt: Double,
    params: RenderParams,
    device: MTLDevice,
    queue: MTLCommandQueue,
    psos: (chaos: MTLComputePipelineState, decode: MTLComputePipelineState,
           density: MTLComputePipelineState, log: MTLComputePipelineState,
           display: MTLComputePipelineState),
    seedBudget: MetalRenderer.ThreadSeedBudget? = nil
) throws -> RGBA8Image
```

The body is unchanged; the only edits are: delete the inline
`guard let (device,_) = deviceAndLibrary()` / `guard let queue = commandQueue` /
`guard let psos = fusedPipelines()` (these move to the wrapper) and use the
parameters instead. Everything else (the N-pass chaos loop, the per-pass
`seedBudget.seeds(forPass:threadCount:)`, the decode/DE/log/display stages,
single commit + `waitUntilCompleted`) is identical.

**(b) `renderTemporalFused` becomes a thin `@MainActor` wrapper** (the realtime
path is unchanged):

```swift
@MainActor
static func renderTemporalFused(blendAt:centerTime:temporal:sumfilt:params:seedBudget:) throws -> RGBA8Image {
    guard let (device, _) = deviceAndLibrary() else { throw NSError(domain: "MetalRenderer", code: 10) }
    guard let queue = commandQueue else { throw NSError(domain: "MetalRenderer", code: 11) }
    guard let psos = fusedPipelines() else { throw NSError(domain: "MetalRenderer", code: 27) }
    return try renderTemporalFusedCore(blendAt: blendAt, centerTime: centerTime,
                                       temporal: temporal, sumfilt: sumfilt,
                                       params: params, device: device, queue: queue,
                                       psos: psos, seedBudget: seedBudget)
}
```

**(c) Add the off-main temporal entry** — the twin of `renderOffMain` (`:451`):

```swift
// Sources/FlameRenderer/MetalRenderer.swift  (NEW)
/// Off-main temporal motion-blur render — the temporal twin of `renderOffMain`.
/// Runs on `offMainQueue`, never touches the MainActor, so it cannot freeze the
/// UI. Used by the GUI export path (motion-blurred exports, zero UI freeze).
/// Returns nil iff Metal is unavailable, the render fails, OR `temporal` carries
/// a non-box weight (defensive — callers throw on nil; real ES genomes are box).
/// Byte-identical to the MainActor `render(blendAt:…)` path.
nonisolated
public static func renderTemporalOffMain(
    blendAt: (Double) -> Flame,
    centerTime: Double,
    temporal: [(delta: Double, weight: Double)],
    sumfilt: Double,
    params: RenderParams,
    seedBudget: MetalRenderer.ThreadSeedBudget? = nil
) -> RGBA8Image? {
    // Box guard (defensive). The @MainActor public entry `render(blendAt:)`
    // fatalErrors on non-box; the off-main path returns nil instead (a background
    // thread fatalError is undesirable; nil ⇒ coordinator throws .metalUnavailable).
    for sub in temporal where sub.weight != 1.0 { return nil }
    return offMainQueue.sync {
        guard let (device, library, queue) = offMainCache.handles() else { return nil }
        guard let psos = offMainCache.pipelines(device: device, library: library) else { return nil }
        return try? renderTemporalFusedCore(blendAt: blendAt, centerTime: centerTime,
                                            temporal: temporal, sumfilt: sumfilt,
                                            params: params, device: device, queue: queue,
                                            psos: psos, seedBudget: seedBudget)
    }
}
```

**Why this is parity-neutral (rule #1/#2):** the GPU computation (kernel
dispatch, atomic accumulation, thread seeds) is thread-independent — this is the
*already-pinned* invariant of `renderOffMain` (`testRenderOffMainMatchesMainActorPath`
/ `…OnRealGenome`). The temporal core is the same code, so the same proof applies.
No renderer math changes; no new collection iteration; `seedBudget` flows
identically. **Parity gate impact: none** (the new path is byte-identical to the
existing temporal path by construction; §9 pins it).

### 4.2 E2 — `ExportCoordinator` off-main dispatch + shared settings resolver

**(a) Off-main dispatch flag.** Add a stored flag, default `false` (CLI path
byte-for-byte unchanged):

```swift
// Sources/FlameExport/ExportCoordinator.swift  (MOD)
public actor ExportCoordinator {
    public enum Backend: Sendable { case cpu, metal }
    private let backend: Backend
    private let useOffMainMetal: Bool          // NEW

    public init(backend: Backend, useOffMainMetal: Bool = false) {
        self.backend = backend; self.useOffMainMetal = useOffMainMetal
    }
    // run/runLongForm/runBatch/cancel: unchanged signatures.
}
```

`renderFrames`' dispatch (the real loop is `ExportCoordinator.swift:158–201`)
gains an off-main Metal branch that mirrors the existing `MainActor.run` branch
*exactly*, swapping only the render call. The decision variable, field names, and
`threadSeeds` argument are taken **verbatim** from the real `renderFrames` — do
not re-derive them:

```swift
// The off-main branch added inside renderFrames (ExportCoordinator.swift:168-188).
// `plan`, `d` (FrameDescriptor), `params`, `budget` are the real locals; field
// names match FramePlan.swift:7-24 EXACTLY (there is NO `descriptor.flame` and NO
// `descriptor.centerTime` — the flame is `d.blendAt(d.blend)` and the center time
// is `d.blend`; single-vs-temporal is decided by `plan.temporalSamples > 1`, the
// same variable the MainActor branch uses at line 175).
if useMetal && useOffMainMetal {
    let img: RGBA8Image? = await Task.detached(priority: .userInitiated) {
        plan.temporalSamples > 1
            ? MetalRenderer.renderTemporalOffMain(
                blendAt: d.blendAt, centerTime: d.blend,
                temporal: d.temporal, sumfilt: d.sumfilt,
                params: params, seedBudget: budget)      // whole budget; selects per-pass internally
            : MetalRenderer.renderOffMain(
                flame: d.blendAt(d.blend), params: params, seedBudget: budget)
    }.value
    guard let img else { throw ExportError.metalUnavailable }   // nil ⇒ unavailable/failed/non-box
    // img assigned to the loop's `img`; encode + yield proceed unchanged
} else if useMetal {
    // UNCHANGED CLI path: await MainActor.run { autoreleasepool { MetalRenderer.render(…) } }
} else { /* CPU: UNCHANGED — await Task.detached { ReferenceRenderer.render(…) }.value */ }
```

`budget` is the `MetalRenderer.ThreadSeedBudget?` built once per export at
`ExportCoordinator.swift:129` (`ThreadSeedBudget(baseSeed: params.seed)`). It is a
`final class: @unchecked Sendable` (`ThreadSeedBudget.swift:23`) whose
`seeds(forPass:threadCount:)` is `NSLock`-guarded memoization of the pure
`MetalHost.buildThreadSeeds` — so handing the *whole* budget to
`renderOffMain`/`renderTemporalOffMain` (which call `seeds(forPass:threadCount:)`
internally, `MetalRenderer.swift:213,669`) is byte-identical to the MainActor path
receiving the same budget. Crossing the `Task.detached` boundary is safe
(`@unchecked Sendable`) and introduces no nondeterminism (the memo is a pure
function of `(pass, threadCount)`).

**(b) Shared settings resolver (G5).** Extract the motion-blur genome-default
fallback and the Metal temporal cap out of `ExportCommand.resolveExportSettings`
(`ExportCommand.swift:358`) into `FlameExport`, so the CLI and GUI build
byte-identical jobs. The shared core takes **already-parsed enums** (the CLI's
string→enum parsing — `"h264"`→`.h264`, `"genome"`→`.genome`, `"1080p"`→`.p1080`
— stays in `ExportCommand`; the GUI builds enums directly from its pickers, so it
does no string parsing). It is **pure and silent** (it cannot call
`EmberweftCLI.err` — FlameExport does not depend on the CLI); the Metal-cap
*notice* is printed by the caller, which compares the requested vs the resolved
`temporalSamples`:

```swift
// Sources/FlameExport/ExportSettings.swift  (NEW static method)
public extension ExportSettings {
    /// Resolve a concrete ExportSettings from parsed GUI/CLI inputs, applying:
    ///  - the motion-blur genome-default fallback: `requestedTS == 1` and
    ///    `baseFlame.quality.temporalSamples > 1` ⇒ use the genome value (mirrors
    ///    AnimateCommand.swift:147-149 and ExportCommand.swift:374-377 EXACTLY);
    ///  - the Metal temporal cap (64) when `backend == .metal`
    ///    (ExportCommand.swift:378-382).
    /// `baseFlame` MUST be the first RENDERABLE flame (the CLI passes
    /// `renderable[0]`, ExportCommand.swift:375; the GUI pre-filters, so its
    /// `flames[0]` is already renderable). Using the unfiltered `flames[0]` here
    /// would diverge from the CLI when flames[0] is degenerate — byte-identity
    /// requires the renderable first flame.
    /// PURE + SILENT: no I/O, no stderr. The caller detects the Metal cap by
    /// comparing `requestedTS` against the returned `temporalSamples` and prints
    /// its own notice (CLI: `err(…)`; GUI: a sheet notice).
    static func resolve(
        quality: ExportQuality,
        temporalSamples requestedTS: Int,
        codec: Codec, container: Container, fps: Int, bitrate: Bitrate,
        resolution: Resolution, segmentFrameBudget: Int,
        baseFlame: Flame, backend: ExportCoordinator.Backend
    ) -> ExportSettings
}
```

`EmberweftCLI.ExportCommand.resolveExportSettings` is then reduced to: (1) parse
the strings into enums, (2) call `ExportSettings.resolve(…)`, (3) if
`backend == "metal"` and `requestedTS != resolved.temporalSamples`, print the
existing cap notice (behavior-identical; covered by the existing CLI tests). The
GUI's `ExportManager` calls `ExportSettings.resolve(…)` directly and surfaces the
cap as a sheet notice the same way. Both paths produce byte-identical jobs.

### 4.3 G1 — `EmberweftUI` links `FlameExport`

```swift
// Package.swift  (MOD — one line)
.target(name: "EmberweftUI",
        dependencies: ["FlameKit", "FlameReference", "FlameRenderer",
                       "FlamePlayer", "FlameExport"],   // +FlameExport
        ...)
```

No cycle: `FlameExport` depends on `FlameRenderer/FlameReference/FlameKit`, all
already `EmberweftUI` deps. This lets `ExportManager` (EmberweftUI) own an
`ExportCoordinator` and reach `MetalRenderer.isAvailable` (EmberweftUI already
links `FlameRenderer`).

### 4.4 G2 — `ExportManager` (EmberweftUI, the testable VM)

`@MainActor @Observable`, held by `AppModel` (survives sheet/window teardown — G9).
Wraps one `ExportCoordinator` at a time (single concurrent export).

```swift
// Sources/EmberweftUI/ExportManager.swift  (NEW)
public enum ExportState: Sendable, Equatable {
    case idle
    case running
    case cancelling
    case completed(URL)
    case failed(String)     // localized message
    case cancelled
}

public struct ExportProgressSnapshot: Sendable, Equatable {
    public var phase: ExportProgress.Phase
    public var currentFrame: Int
    public var totalFrames: Int
    public var elapsed: TimeInterval
    public var renderFPS: Double
    public var jobIndex: Int      // 0 for single/sequence
    public var totalJobs: Int     // 1 for single/sequence
    public var fraction: Double { totalFrames > 0 ? Double(currentFrame)/Double(totalFrames) : 0 }
    public static let empty = ExportProgressSnapshot(phase: .rendering, currentFrame: 0,
        totalFrames: 0, elapsed: 0, renderFPS: 0, jobIndex: 0, totalJobs: 1)
}

public enum BackendChoice: String, Sendable, CaseIterable { case auto, cpu, metal }

@MainActor
@Observable
public final class ExportManager {
    public private(set) var state: ExportState = .idle
    public private(set) var snapshot: ExportProgressSnapshot = .empty

    // The editable config (bound two-way by the sheet):
    public var codec: ExportSettings.Codec = .h264
    public var container: ExportSettings.Container = .mp4
    public var resolution: ExportSettings.Resolution = .p1080
    public var fps: Int = 30
    public var qualityChoice: ExportQualityChoice = .genomeDefault
    public var backendChoice: BackendChoice = .auto
    public var temporalSamples: Int = 1            // 1 ⇒ genome default (resolved)
    public var loopDurationSeconds: Double = 6.0   // ⇒ framesPerSegment = round(duration*fps)

    private var coordinator: (any ExportCoordinating)?
    private var consumeTask: Task<Void, Never>?
    private var activityToken: NSObjectProtocol?   // ProcessInfo sleep token (G10)

    /// Test seam: inject a fake coordinator (no Metal/AVFoundation) for unit
    /// tests; the production path constructs `ExportCoordinator(backend:useOffMainMetal:)`.
    internal var coordinatorFactory:
        (ExportCoordinator.Backend, Bool) -> any ExportCoordinating = { backend, off in
            ExportCoordinator(backend: backend, useOffMainMetal: off)
        }

    public init() {}

    /// True iff an export can start now (not running/cancelling).
    public var canStart: Bool {
        switch state { case .running, .cancelling: return false; default: return true }
    }

    // --- Source entry points (build jobs via the SHARED resolver, drive coordinator) ---
    public func exportSingle(flame: Flame, displayName: String, out: URL, seed: UInt64) async
    public func exportSequence(flames: [Flame], out: URL, seed: UInt64) async
    public func exportBatch(items: [(flame: Flame, name: String)], baseDir: URL, seed: UInt64) async

    public func cancel() async        // → coord?.cancel() (guarded); state = .cancelling
    public func reset()               // → .idle (clears snapshot/result so the banner dismisses)

    // Resolve the concrete backend (G6): probe isAvailable ON the MainActor.
    internal func resolveBackend() -> ExportCoordinator.Backend {
        let metal = MetalRenderer.isAvailable           // @MainActor — safe here
        switch backendChoice {
        case .auto:  return metal ? .metal : .cpu
        case .cpu:   return .cpu
        case .metal: return metal ? .metal : .cpu       // GUI falls back; sheet shows a notice
        }
    }
}
```

(`ExportCoordinating` is the `internal` testability protocol from §8 —
`run`/`runBatch`/`cancel`; `ExportCoordinator` conforms trivially. The factory
seam lets `ExportManagerTests` inject a fake without Metal/AVFoundation; the
production path is unchanged.)

**Entry points are fire-and-forget.** Each `exportX(…)` (a) validates the source
(`flame.isRenderable` — NaN/degenerate excluded, §7; for batch, filters the
list), (b) resolves settings via `ExportSettings.resolve(…)` and builds the
`ExportJob(s)`, (c) sets `state = .running` + acquires the `ProcessInfo` activity
token (G10), (d) creates the coordinator via `coordinatorFactory(resolveBackend(),
true)` (production: `ExportCoordinator(backend:useOffMainMetal:)`; tests inject a
fake), (e) spawns `consumeTask` and **returns immediately**
(the sheet dismisses right after — §4.6; the export runs on `consumeTask`). They
are `async` only because constructing + first-`await`-ing the coordinator stream
is an actor hop; they do NOT await completion.

```swift
consumeTask = Task { [weak self] in
    // [weak self] is SAFE here, unlike the M4 sheet-VM teardown case:
    // ExportManager is held by AppModel (app-lifetime @State in EmberweftApp),
    // so it is never released mid-export. Weak still guards the theoretical
    // app-teardown path. (Contrast: PlaybackViewModel.beginStop captures self
    // STRONGLY because it IS sheet-owned — that gotcha does not apply here.)
    guard let self else { return }
    guard let coord = self.coordinator else { return }   // no force-unwrap
    do {
        let stream = await coord.run(job)        // or runBatch — see "Source routing" below
        for try await event in stream {          // ExportProgress | BatchProgress
            if Task.isCancelled { break }
            self.snapshot = Self.snapshot(from: event)   // MainActor — @Observable update
        }
        self.state = .completed(job.out)
    } catch is CancellationError, ExportError.cancelled {
        self.state = .cancelled
    } catch ExportError.diskFull {
        self.state = .failed("Not enough free disk space.")
    } catch ExportError.metalUnavailable {
        self.state = .failed("Metal is unavailable. Try the CPU backend.")
    } catch {
        self.state = .failed(error.localizedDescription)
    }
    self.endActivity()        // G10 — always release the sleep token
    self.coordinator = nil
    self.consumeTask = nil    // break the self→consumeTask→task→self reference cycle
}
```

- **Cancel teardown ordering (D-G13).** `cancel()` does, in order: (1) set
  `state = .cancelling`; (2) `await coordinator?.cancel()` (the coordinator's
  `cancelled` flag is the authoritative stop — checked between frames in
  `renderFrames`, `ExportCoordinator.swift:169`); (3) the in-flight frame finishes,
  the next iteration throws `.cancelled`, the stream finishes, and `consumeTask`'s
  catch sets `.cancelled` + clears `coordinator`/`consumeTask`. `cancel()` MUST
  guard `coordinator != nil` (it may have already been cleared by a concurrently
  completing consumeTask). Do NOT `consumeTask?.cancel()` as the cancel path —
  the coordinator's inner unstructured `Task` (`ExportCoordinator.swift:41`) is not
  a child of `consumeTask`, so `Task.cancel()` does not reach it; only
  `coordinator.cancel()` (the flag) does.
- **Source routing (D-G5).** `exportSingle` ⇒ `coordinator.run(job)` with
  `segmentCount = 1`, `framesPerSegment = max(1, round(loopDurationSeconds*fps))`
  (a single continuous encode of one loop — no concat/temp in v1).
  `exportSequence` ⇒ `coordinator.run(job)` with `segmentCount = flames.count`
  (one continuous encode over the whole loop+transition timeline — `run` iterates
  `[0, totalFrames)` over all segments; a single `AVAssetWriter` session handles
  arbitrary length, so the chunked `runLongForm`/concat path is NOT needed for v1
  and is deferred to a future "very-long-form" toggle). `exportBatch` ⇒
  `coordinator.runBatch(jobs, failFast: false)` (one `run` per entry).
  `segmentFrameBudget` is left at 0 for single/sequence (no chunking).
- **`run` vs `runBatch` return different event types** — `snapshot(from:)`
  normalizes both `ExportProgress` and `BatchProgress` into the single
  `ExportProgressSnapshot` (batch sets `jobIndex/totalJobs/aggregate`).
- **Determinism (rule #2):** `snapshot(from:)` is a pure mapping; no float sums
  over hashed collections. `seed` is caller-supplied (default 1 in the sheet) →
  reproducible. The VM introduces no nondeterminism.
- **Throttle:** the stream yields per-frame (≤ fps/s). `@Observable` writes are
  cheap; ProgressView re-renders only the banner. No throttle needed for
  correctness; an optional ~20 Hz cap is noted in the plan if profiling demands.

### 4.5 G4/G5 — Quality + settings mapping

`ExportQualityChoice` bridges the dormant `QualityPreset` to `ExportQuality`,
pinning `oversample = 1` (G4):

```swift
// Sources/EmberweftUI/ExportQualityChoice.swift  (NEW)
public enum ExportQualityChoice: String, Sendable, CaseIterable, Hashable {
    case genomeDefault          // .genome — byte-identical to `emberweft animate`
    case low, medium, high
    public var exportQuality: ExportQuality {
        switch self {
        case .genomeDefault: return .genome
        case .low:           return .spp(2)
        case .medium:        return .spp(8)
        case .high:          return .spp(30)   // oversample pinned 1 by ExportQuality
        }
    }
    /// Seed the default choice from the dormant prefs field.
    public static func defaultChoice(from preset: AppPreferences.QualityPreset) -> ExportQualityChoice {
        switch preset { case .low: return .low; case .medium: return .medium; case .high: return .high }
    }
}
```

The sheet's Quality picker is `Genome default | Low | Medium | High`, defaulting
from `prefs.qualityPreset` (wires the dormant field). Job-building composes
`ExportSettings.resolve(quality: qualityChoice.exportQuality, …)` (§4.2b) — so
`.genomeDefault` is byte-identical to `animate`, and the named tiers are
`.spp(N)` with `oversample = 1` (faithful to engine spec D6).

### 4.6 G3/G7 — `ExportSheet` + destination picker (EmberweftGUI)

`Sources/EmberweftGUI/ExportSheet.swift` (NEW): a `.sheet` with a read-only
source summary and editable controls bound to `model.exportManager`:

```
┌─ Export ──────────────────────────────────────┐
│ Source:  Collection "Sunsets" (12 sheep)       │  ← read-only summary
│                                                │
│ Resolution: [ 1080p ▾ ]   (720/1080/1440/4K/custom)
│ Quality:    [ Genome default ▾ ]  (Genome/Low/Med/High)
│ Codec:      [ H.264 ▾ ]   Container: [ MP4 ▾ ]
│ FPS:        [ 30 ⯄ ]      Backend:  [ Auto ▾ ]
│ Loop dur.:  [ 6.0 s ⯄ ]   (framesPerSegment = round(dur*fps))
│ Temporal:   [ Genome default ⯄ ]  (1 ⇒ genome; motion blur)
│ Seed:       [ 1 ⯄ ]
│                                                │
│             [ Choose Destination & Export ]    │  ← NSSavePanel / NSOpenPanel
│                         [ Cancel ]             │
└────────────────────────────────────────────────┘
```

- **Start button** disabled unless `model.exportManager.canStart` and a destination
  is chosen. If `backendChoice == .metal` but `MetalRenderer.isAvailable == false`,
  show a notice ("Metal unavailable — will use CPU").
- **Destination (G7):**
  - single / sequence ⇒ `NSSavePanel` (allowed content types `[.mpeg4Movie]`/
    `.quickTimeMovie`; default name `<stem>.mp4`). `NSSavePanel`'s overwrite
    confirmation is the SINGLE overwrite gate; the coordinator's atomic
    `<out>.partial-<pid>` → rename (engine D13) never clobbers a good file on a
    failed run. Returns a file URL → `exportSingle/exportSequence(..., out: url)`.
  - batch ⇒ `NSOpenPanel` (`.canChooseDirectories = true`,
    `.canChooseFiles = false`) → a directory; each entry's output is named
    `<stem>.mp4` where `<stem>` is sanitized by the **existing**
    `FlameExport.BatchPath.resolve(_:base:)` (`ExportProgress.swift:60`) — the
    SAME D13 security gate the CLI's `--jobs` manifest uses (rejects absolute,
    `..`/`.`, hidden, non-`[A-Za-z0-9._-]`). Dedup against existing files in the
    dir with a `-2`/`-3` suffix (mirror the CLI's batch naming). →
    `exportBatch(..., baseDir: dir)`.
- **On Start:** call the matching `exportManager.exportX(...)` (fire-and-forget,
  §4.4 — it sets `state = .running`, spawns `consumeTask`, and returns), then
  `dismiss()` the sheet (non-blocking — G8). Progress appears in the
  `ExportProgressSurface` banner (§4.7). The sheet does **not** hold the export
  state (it lives on `AppModel.exportManager` — G9).

`Sources/EmberweftGUI/SavePanel.swift` (NEW): thin `NSSavePanel`/`NSOpenPanel`
runners (`@MainActor func chooseSaveURL(defaultName:suggestedDir:) -> URL?`
and `chooseDirectory() -> URL?`). Standard AppKit; no `Transferable`/`UTType`
pasteboard (unaffected by the bundle-less SwiftPM-executable drag-drop gotcha,
which is about in-app reorder, not system file panels).

### 4.7 G8 — `ExportProgressSurface` (non-blocking banner, EmberweftGUI)

`Sources/EmberweftGUI/ExportProgressSurface.swift` (NEW): a compact view
observing `model.exportManager`. It is **mounted in all three window types** —
the main `LibraryView` (in `detailChrome`'s overlay, `LibraryView.swift:309`,
alongside `SelectionBar`) AND both playback windows (`PlaybackWindow.bar`,
`CollectionPlaybackWindow.bar`) — because the "main window is always open"
assumption is **false**: each `WindowGroup` window is individually closable via ⌘W
(`EmberweftApp.swift:22,37,61`), and an export is most often started from a
playback window. Mounting in all three guarantees the banner is observable from
wherever the user is, without a floating `NSPanel` (out of scope, §1). Each
instance is a thin overlay on the same `model.exportManager` — cheap (one
`@Observable` read per snapshot). Hidden when `state == .idle`:

```
┌──────────────────────────────────────────────────────────┐
│ ▰▰▰▰▰▰▱▱▱▱  Rendering — frame 142 / 320  (3.1 fps, 42 s)  [ Cancel ]
│ Collection "Sunsets" — job 2 of 12                        │
└──────────────────────────────────────────────────────────┘
```

- `ProgressView(value: snapshot.fraction)`; phase label; frame count; FPS;
  elapsed; batch `jobIndex/totalJobs` when `totalJobs > 1`.
- **Cancel** button ⇒ `await model.exportManager.cancel()` (cooperative —
  finishes the in-flight frame, then `cancelWriting()` + deletes the partial;
  engine D12).
- **On `.completed(url)`:** banner switches to "Saved to `<name>` —
  **Show in Finder**" (`NSWorkspace.shared.activateFileViewerSelecting([url])`)
  + a **Dismiss** (→ `exportManager.reset()`).
- **On `.failed(msg)`/`.cancelled`:** banner shows the message + Dismiss.
- **Degraded behavior (all windows closed):** if the user closes EVERY window
  mid-export, the banner disappears but the export continues (the coordinator is
  owned by `consumeTask` on `ExportManager`, which is on `AppModel` — app-lifetime).
  There is no visible Cancel in that state; the export completes/fails/cleans up
  on its own (engine D12/D13), and the result surfaces in the next opened window's
  banner (`state` is terminal until `reset()`). Documented v1 limitation; the
  floating `NSPanel` (§1, out of scope) is the M7 fix.
- A future floating `NSPanel` is noted (out of scope; §1).

### 4.8 G4 (cont.) — The three source integrations

| Source | "Export…" attach point | How the flame(s) are obtained (verified) | Routed to |
|---|---|---|---|
| **Single genome** | `PlaybackWindow.bar` (`PlaybackView.swift:73`) — new toolbar button | **NOT exposed today** — the flame is a local in `start()` (`PlaybackView.swift:175`) and `PlaybackViewModel.flame` is `private`. ADD `@State private var loadedFlame: Flame?` on `PlaybackWindow`, set it in `start()` right after the `isRenderable` check. The Export button is disabled while `loadedFlame == nil` (still loading / failed / degenerate). Source = `.single(flame: loadedFlame!, name: entry.displayName)`. | `exportSingle` (`run`, segmentCount=1) |
| **Collection as sequence** | `CollectionPlaybackWindow` `bar` (`CollectionPlaybackView.swift:87`) — new button | **NOT exposed today** — `SequencePlaybackViewModel.flames` is `private` (`SequencePlaybackViewModel.swift:57`). ADD `public var resolvedFlames: [Flame] { flames }` (read-only accessor — no behavior change). Source = `.sequence(flames: vm.resolvedFlames, name: collectionName)`. | `exportSequence` (`run`, segmentCount=flames.count) |
| **Multi-select batch** | `SelectionBar` (`SentimentBar.swift:64`) — new bulk action, enabled when `!model.selection.isEmpty` | `model.selection` is a `Set<LibraryEntry>`. The Export… action loads flames **async** before opening the sheet: iterate `selection.sorted { GenomeCollectionAppOrder.key($0) < … }` (rule #2 — never persist `Set` order), `await libraryIndex.loadGenome(for:)` each, drop unparseable/unrenderable entries, surface a count ("skipped N"). A short loading indicator covers large selections. Source = `.batch(items: [(flame, name)])`. | `exportBatch` (`runBatch`, failFast: false) |

Each opens the shared `ExportSheet` with a source-specific read-only summary.
The sheet reads/writes only `model.exportManager`'s config fields — the source
supplies the genomes at open time (single/sequence) or at Start (batch, after the
async load). A single `ExportSheet(source: .single(flame:name:) |
.sequence(flames:name:) | .batch(items:))` enum parameterizes it.

**Race guard (Export… clicked before the flame is loaded):** the single-source
Export button is bound to `loadedFlame != nil` (disabled otherwise); the sequence
button to `!vm.resolvedFlames.isEmpty` (the window already gates on
`vm.loadError == nil` before `play()`, `CollectionPlaybackView.swift:171`); the
batch button to a non-empty `items` list after the load step. No silent dead-ends.

### 4.9 G10 — Sleep prevention, "Show in Finder", cleanup

- **Sleep token (G10):** at run start,
  `activityToken = ProcessInfo.processInfo.beginActivity(options:
  [.userInitiated, .idleDisplaySleepDisabled, .idleSystemSleepDisabled],
  reason: "Emberweft video export")`; released in `endActivity()` called from the
  run loop's normal exit, cancel, **and** error paths (via the `consumeTask`'s
  tail + a `cancel()`-safe guard). Token is `nil` while idle.
- **Show in Finder:** §4.7 (`NSWorkspace.shared.activateFileViewerSelecting`).
- **Cleanup:** partial/temp files are owned by the coordinator (engine D12/D13:
  `<out>.partial-<pid>.mov`, atomic rename on success, deleted on cancel/failure).
  The GUI adds nothing here — the coordinator's `defer` already handles it,
  including app-quit-mid-export (the partial is orphaned but harmless; a future
  launch could sweep `.partial-*` files — noted, out of scope).

---

## 5. Data flow

```
 Export… button (PlaybackWindow / CollectionPlaybackWindow / SelectionBar)
   │  .sheet { ExportSheet(source:) }   ← binds model.exportManager config
   ▼
 Choose Destination & Export  ──▶ NSSavePanel / NSOpenPanel  ──▶ out URL
   │  dismiss sheet
   ▼
 ExportManager.exportX(flames, settings, out)           (@MainActor @Observable, on AppModel)
   │  • validate flame.isRenderable
   │  • ExportSettings.resolve(quality:temporalSamples:…:baseFlame:backend:)   (shared, §4.2b)
   │  • build ExportJob(s)
   │  • ProcessInfo.beginActivity(…)                           (G10 sleep token)
   │  • coordinatorFactory(resolveBackend(), true) → ExportCoordinator(backend:useOffMainMetal:)
   ▼
 ExportCoordinator ──off-main──▶ Metal renderTemporalOffMain / renderOffMain   (E1, E2)
   │                            ── or CPU ──▶ ReferenceRenderer (Task.detached)
   │                            ──▶ VideoEncoder ──▶ AVAssetWriter ──▶ file
   │  AsyncThrowingStream<ExportProgress | BatchProgress>  (per frame; cancel between frames)
   ▼
 ExportManager.consumeTask (MainActor) ──▶ snapshot ──▶ @Observable
   ▼
 ExportProgressSurface (banner in all 3 window types): ProgressView + Cancel + Show-in-Finder
```

---

## 6. Determinism & parity (rules #1, #2)

- **Reference-then-Optimize / parity (rule #1):** the **only** renderer edit is
  the §4.1 extraction — `renderTemporalFusedCore` is the *same code* as
  `renderTemporalFused`, and `renderTemporalOffMain` is the *same code path* as
  `renderOffMain` (single→temporal). Both are byte-identical to the existing
  `@MainActor` paths by construction. No renderer math, no kernel, no
  thread-seed formula changes. The parity gate is **not** regressed (§9 re-runs
  the off-main identity pins; the full `make test-parity` is unchanged in
  pass/fail — the 2 known-genuine Float-limit stills are pre-existing, M6-untouched).
- **Determinism (rule #2):** `ExportManager`/`ExportQualityChoice`/resolver are
  pure value transformations; no `Dictionary`/`Set` float sums; settings JSON is
  `.sortedKeys`-stable where persisted; `seed` is explicit (default 1).
- **GUI↔CLI parity (G5/G11):** both call `ExportSettings.resolve(…)`, so a GUI
  export and `emberweft export` at matching `flames`/`seed`/`resolution`/
  `quality`/`temporalSamples` produce byte-identical frames. The GUI export is
  byte-identical to `emberweft animate --frame N` **only at matching
  `width`/`height`** — note `animate` defaults to the genome's native `size`
  (`AnimateCommand.swift:135-136`) and has no `--resolution` flag, while the GUI
  export defaults to a resolution tier (1080p). So byte-identity with default
  `animate` holds only when the GUI picks a resolution equal to the genome's
  native size (or the comparison runs `animate --size WxH` at the GUI's tier).
  This is the engine spec's §5.2 caveat (byte-identity is conditional on
  matching `width`/`height`), restated here so the GUI AC (§9.5) doesn't
  over-claim. Pinned by a ts>1 fixture (§9).
- **Swift 6:** `ExportManager` is `@MainActor @Observable`; `consumeTask`
  inherits MainActor isolation; the coordinator is an actor; `ExportJob`/
  `ExportSettings`/`ExportProgress`/`Backend` are `Sendable`; the `ThreadSeedBudget`
  is `@unchecked Sendable` and crosses the `Task.detached` boundary unchanged. No
  `nonisolated(unsafe)` added (the existing `offMainCache` escape is untouched).
  XCTest methods are `@MainActor`.

---

## 7. Edge cases & resilience

| Case | Handling |
|---|---|
| Metal unavailable at start | `resolveBackend()` falls back to CPU; sheet shows a notice if the user picked Metal. |
| Metal fails mid-run (off-main returns nil) | `renderFrames` throws `.metalUnavailable`; VM → `.failed("Metal is unavailable…")`; partial deleted (D13). |
| Non-box temporal on Metal | `renderTemporalOffMain` returns nil (defensive) → `.metalUnavailable`. Real ES genomes are box; never hit. |
| Destination file exists | `NSSavePanel` prompts overwrite; coordinator's atomic partial→final never clobbers a good file (D13). |
| Disk full | Engine precheck (D13) errors before frame 1; VM → `.failed("Not enough free disk space.")`. |
| Degenerate / NaN-header genome | `flame.isRenderable` gate (bounds [1e-3, 4000]); excluded with a notice before Start. |
| Batch: one job fails | Engine D11 — recorded, batch continues; exit nonzero iff any failed; VM surfaces per-job failures in the banner. |
| Export started, then source window closed | VM lives on `AppModel` (G9) — export continues; banner in the main window. |
| Two exports started | `canStart` is false while running; Start button disabled + notice. |
| Cancel during `finishWriting()` | Engine D12 — that window is uncancellable; the flag is honored between frames; partial deleted afterward. |
| App quit mid-export | Coordinator's `defer` deletes the active partial; orphaned `.partial-*` are harmless (future sweep noted). |
| Collection with < 2 genomes | Degrade: 1 genome ⇒ `exportSingle`; 0 ⇒ Start disabled. |
| HEVC unsupported on the machine | Engine probes (`VideoEncoder.canEncode`); auto-fallback to H.264 with a notice. |
| Display would sleep | `ProcessInfo` activity token held (G10). |
| Custom resolution with a zero/negative dim | Clamp to ≥1 in the resolver (mirror `renderParams`'s `max(width,1)`). |
| **GUI export vs thumbnail render on `offMainQueue` (D-G12)** | Both `MetalRenderer.renderOffMain` (thumbnails, `ThumbnailService.swift:121`) and the new `renderTemporalOffMain` do `offMainQueue.sync { … }` on the SAME serial `DispatchQueue` (`MetalRenderer.swift:439`). They serialize: a thumbnail in flight blocks the export's off-main frame (and vice-versa) for the frame's duration (~25–50 ms). NOT a deadlock (serial, cooperative, both `sync`). Bounded latency; acceptable for v1. (The MainActor realtime playback path is unaffected — different queue.) |
| **All windows closed mid-export (D-G11)** | Banner disappears; export continues on `ExportManager` (AppModel-owned). No visible Cancel until a window reopens; the run self-completes/cleans (D12/D13). §4.7 degraded behavior. |
| **Export… clicked before the flame is loaded (D-G15)** | Single: button disabled while `loadedFlame == nil`. Sequence: button disabled while `vm.resolvedFlames.isEmpty`. Batch: sheet opens after the async load completes. No silent dead-end. |
| **Metal cap on temporal (GUI)** | `ExportSettings.resolve` returns the capped value silently; the GUI detects `requestedTS != resolved.temporalSamples` and shows a sheet notice (mirrors the CLI's stderr note). |

Every new surface has an explicit loading/empty/error state. No silent dead-ends.

---

## 8. File plan

### NEW — engine (FlameRenderer / FlameExport)
| File | Responsibility |
|---|---|
| *(in `MetalRenderer.swift`)* | `renderTemporalFusedCore` (extracted) + `renderTemporalOffMain` (§4.1). |
| *(in `ExportSettings.swift`)* | `ExportSettings.resolve(…)` shared resolver (§4.2b). |

### MOD — engine
| File | Change |
|---|---|
| `Sources/FlameExport/ExportCoordinator.swift` | `init(backend:useOffMainMetal:)`; off-main Metal branch in `dispatch` (§4.2a). |
| `Sources/EmberweftCLI/ExportCommand.swift` | `resolveExportSettings` → thin caller of `ExportSettings.resolve(…)` (behavior identical; CLI tests unchanged). |

### NEW — `Sources/EmberweftUI/` (all unit-tested via `EmberweftUITests`)
| File | Responsibility |
|---|---|
| `ExportManager.swift` | `ExportManager`, `ExportState`, `ExportProgressSnapshot`, `BackendChoice` (§4.4). |
| `ExportQualityChoice.swift` | Quality preset → `ExportQuality` mapping, `oversample` pinned 1 (§4.5). |

### MOD — `Sources/EmberweftUI/`
| File | Change |
|---|---|
| `AppPreferences.swift` | (Optional) expose `qualityPreset` cleanly as the export-quality default; no behavior change to preview. |

### NEW — `Sources/EmberweftGUI/` (thin, manual-test only)
| File | Responsibility |
|---|---|
| `ExportSheet.swift` | Config sheet + source summary + Start (§4.6). |
| `SavePanel.swift` | `NSSavePanel` / `NSOpenPanel` runners (§4.6). |
| `ExportProgressSurface.swift` | Non-blocking progress banner + Cancel + Show-in-Finder (§4.7). |

### MOD — `Sources/EmberweftGUI/`
| File | Change |
|---|---|
| `AppModel.swift` | Hold `let exportManager = ExportManager()`. |
| `PlaybackView.swift` | "Export…" toolbar button → `.sheet { ExportSheet(source: .single(…)) }`. |
| `CollectionPlaybackView.swift` | "Export…" toolbar button → `.sheet { ExportSheet(source: .sequence(…)) }`. |
| `SentimentBar.swift` (SelectionBar) | "Export…" bulk action (enabled when `!selection.isEmpty`) → `.sheet { ExportSheet(source: .batch(…)) }`. |
| `LibraryView.swift` | Mount `ExportProgressSurface()` in the main window chrome. |

`Package.swift`: `EmberweftUI` `+FlameExport` (§4.3) AND `EmberweftUITests`
`+FlameExport` (so `ExportManagerTests` can construct a real `ExportCoordinator`
for the end-to-end cancel/pathological-input cases — the state-machine unit tests
use an injected `ExportCoordinating` protocol, but the integration tests link the
real coordinator). Current `EmberweftUITests` deps
(`Package.swift:119`) = `[EmberweftUI, FlameKit, FlameReference, FlameRenderer,
FlamePlayer]`; add `"FlameExport"`. No other module change.

### Testability — `ExportCoordinating` protocol (D-G16)
`ExportManager` holds its coordinator via a minimal `internal protocol
ExportCoordinating { func run(...) -> AsyncThrowingStream<...>; func runBatch(...)
-> AsyncThrowingStream<...>; func cancel() async }` so the state-machine unit
tests (§9.4) inject a fake (no Metal, no AVFoundation, no sandbox-off
requirement). The real `ExportCoordinator` trivially conforms (it already has
exactly these signatures). The production path constructs
`ExportCoordinator(backend:useOffMainMetal:)`; tests inject the fake. This keeps
`EmberweftUITests` fast and sandbox-independent for the logic gate, while the
engine's own `FlameExportTests` cover the real coordinator end-to-end (already on
`main`).

### TESTS
| File | Coverage |
|---|---|
| `Tests/FlameRendererTests/…` (MOD/NEW) | `testRenderTemporalOffMainMatchesMainActorPath` + `…OnRealGenome` (ts>1 fixture); re-confirm `testRenderOffMainMatchesMainActorPath` family + the export↔animate byte-identity pin. |
| `Tests/EmberweftUITests/ExportManagerTests.swift` (NEW) | State machine (idle→running→done/failed/cancelled); `ExportQualityChoice→ExportQuality`; `ExportSettings.resolve` fallback/cap; `resolveBackend` (avail/unavail); cancel cleans partial; snapshot mapping; sleep-token acquire/release; rule #2 (no float sums over hashed collections). |
| `Tests/EmberweftUITests/ExportQualityChoiceTests.swift` (NEW) | Each choice → correct `ExportQuality`; oversample pinned 1; `defaultChoice(from:)`. |

---

## 9. Verification (strictly testable acceptance)

> Sandbox note: run tests with the bash sandbox **disabled**
> (`MTLCreateSystemDefaultDevice()` returns nil under it — CLAUDE.md). Read the
> `Executed N tests, with X failures` line + exit code; ignore `error:` lines
> from CLI error-path tests.

### 9.1 Per-slice gate
```
swift build
swift test --filter FlameRendererTests -- -- Off-main temporal parity only (the 3 new §9.2 tests)
swift test --filter EmberweftUITests          # GUI-layer logic, fast (ExportManager/Quality/state machine)
swift test --filter FlameExportTests          # confirm the CLI refactor didn't regress export↔animate
git diff --name-only main | grep -E 'Sources/(FlameKit|FlameReference)/'   # empty (no engine-MATH change)
```
(The full `make test-parity` is **not** required — no renderer math changed, only
a byte-identical extraction. Re-run the 3 new off-main temporal identity pins +
the export↔animate pins named in §9.3 to confirm; the 2 known Float-limit stills
are pre-existing.)

### 9.2 E1 — `[automated]` off-main temporal parity
- `[automated]` `testRenderTemporalOffMainMatchesMainActorPath`: for a ts>1
  fixture (`Tests/Goldens/fixtures/sierpinski_ts4.flam3` — NOT in
  `Tests/Goldens/genomes/`, per the CLAUDE.md fixture-rule), the bytes of
  `renderTemporalOffMain(…)` equal `renderTemporalFused(…)` (same device, same
  seedBudget). **Pass = `RGBA8Image.pixels` element-wise equal; fail = any
  differing byte.** (The existing single-pass pins live in
  `Tests/EmberweftUITests/MetalFrameRendererSmokeTests.swift:55,72` —
  `testRenderOffMainMatchesMainActorPath` / `…OnRealGenome`; the NEW temporal
  pins go in `Tests/FlameRendererTests/` alongside `ThreadSeedBudgetTests` /
  `TemporalBlurMetalTests`, the natural home for rigorous FlameRenderer parity.)
- `[automated]` `testRenderTemporalOffMainMatchesMainActorPathOnRealGenome`:
  same on a real gen-248 sheep (`sheep/gen-248/`, NOT `find … -path '*248*'`
  which matches sheep IDs — CLAUDE.md gotcha) at the engine spec's stress
  op-point, ts>1, box filter. **Pass = byte-equal `pixels`.**
- `[automated]` `testRenderTemporalOffMainReturnsNilOnNonBox`: a temporal with a
  `weight != 1.0` sub-sample ⇒ `renderTemporalOffMain` returns nil (no trap).
  **Pass = return value == nil.**

### 9.3 E2/G5 — `[automated]` shared resolver + coordinator
- `[automated]` `testExportSettingsResolveGenomeFallbackAndMetalCap`:
  `ExportSettings.resolve(quality: .genome, temporalSamples: 1, baseFlame:
  <flame whose quality.temporalSamples==64>, backend: .metal)` ⇒
  `resolved.temporalSamples == 64` (genome fallback + Metal cap); same call with
  `backend: .cpu` ⇒ `resolved.temporalSamples == 64` (fallback, uncapped); a
  `<flame whose quality.temporalSamples==200>` + `.metal` ⇒ `== 64` (cap only).
  **Pass = each `temporalSamples` equals the named integer.**
- `[automated]` `testExportSettingsResolveIsSilent`: the resolver performs no
  I/O and writes nothing to stderr (it is pure; the caller prints any cap
  notice). **Pass = no stderr output captured during the call.**
- `[automated]` CLI regression: `emberweft export … --frame 5 --png` output is
  byte-identical before/after the `resolveExportSettings` → thin-caller refactor,
  re-running the EXISTING real pins: `testExportGenomeByteMatchesAnimateFrame5`
  and `testExportGenomeByteMatchesAnimateFrame5MotionBlur`
  (`Tests/FlameExportTests/ExportPresetsTests.swift:42,72`) +
  `testTemporalSamples1IsByteIdenticalToNoFlag`
  (`Tests/EmberweftCLITests/AnimateCommandTests.swift:411`). **Pass = those tests
  still pass (frame pixels byte-equal to their committed baselines).**
- `[automated]` `testExportCoordinatorOffMainMetalDispatchesOffMain`:
  `ExportCoordinator(backend: .metal, useOffMainMetal: true)` with Metal available
  renders a 1-frame job WITHOUT a MainActor hop (assert via a
  `Thread.isMainThread` probe inside an injected test render hook, OR by
  confirming the main actor is not blocked — e.g., a `MainActor.run` sentinel
  races the render and completes during it); with `useOffMainMetal: false` it
  uses the MainActor path (the sentinel blocks). **Pass = probe observes
  off-main execution iff `useOffMainMetal == true`.**

### 9.4 G2/G4 — `[automated]` ExportManager / ExportQualityChoice
- `[automated]` `testExportQualityChoiceMapping`: each case → correct
  `ExportQuality` — `.genomeDefault`⇒`.genome`, `.low`⇒`.spp(2)`,
  `.medium`⇒`.spp(8)`, `.high`⇒`.spp(30)`; and
  `.resolvedSamplesPerPixel(for:).oversample == 1` for ALL (incl. `.high`).
  **Pass = each equality holds.**
- `[automated]` `testExportQualityChoiceDefaultFromPreset`:
  `ExportQualityChoice.defaultChoice(from: .low/.medium/.high)` ⇒
  `.low/.medium/.high`. **Pass = each equality holds.**
- `[automated]` `testExportManagerStateMachine`: inject a FAKE coordinator (a
  protocol `ExportCoordinating` with `run`/`runBatch`/`cancel` stubbed) so the
  state machine is testable without Metal/AVFoundation. `exportSingle` drives
  `state` `.idle`→`.running`→`.completed(url)` on the fake's success stream;
  →`.failed("…")` on a thrown `.diskFull` / `.metalUnavailable`; →`.cancelled` on
  `cancel()`. **Pass = `state` equals the named case after each scenario.**
- `[automated]` `testExportManagerCancelCleansPartial`: the fake coordinator
  records that its cancel path deleted `job.partialURL`; after `cancel()` +
  drain, `ExportManager.state == .cancelled` AND the partial file does not exist.
  **Pass = both conditions.** (For a REAL end-to-end cancel, rely on the engine's
  `ExportCoordinatorTests` — already on `main`.)
- `[automated]` `testResolveBackend`: `.auto`+`isAvailable==true`⇒`.metal`,
  `.auto`+`isAvailable==false`⇒`.cpu`, `.cpu`⇒`.cpu`,
  `.metal`+`isAvailable==false`⇒`.cpu` (graceful fallback). `isAvailable` is
  stubbed via a test-injectable probe (the real `MetalRenderer.isAvailable` is
  `@MainActor` and sandbox-sensitive). **Pass = each mapping.**
- `[automated]` `testCanStartGate`: `canStart == false` while `state == .running`
  or `.cancelling`; `true` otherwise. **Pass = each boolean.**
- `[automated]` `testSleepTokenAcquiredAndReleased`: a test hook
  (`internal var activityAcquired: () -> Bool` / `activityReleased: () -> Bool`
  backed by a counter) asserts the token is acquired exactly once at run start
  and released exactly once on success, on cancel, AND on failure (three
  sub-tests). **Pass = acquireCount==1 && releaseCount==1 in each sub-test.**
- `[automated]` `testSnapshotMappingIsDeterministic`: feeding a fixed sequence of
  `ExportProgress`/`BatchProgress` events produces a fixed sequence of
  `ExportProgressSnapshot` (no `Dictionary`/`Set` iteration; pure value mapping).
  Re-run with a fresh `ExportManager` → identical snapshots. **Pass = the two
  snapshot sequences are element-wise equal (pins rule #2).**

### 9.5 `[manual]` GUI acceptance (clean `emberweft-gui` launch)
- Single: open a genome → playback window → Export… → choose dest → Start →
  banner shows progress in the **main** window while the playback window stays
  responsive (scrub the loop during export — no freeze) → completed → Show in
  Finder opens the `.mp4`.
- Sequence: a collection → Play as Sequence window → Export… → long-form
  `.mp4` (loop+transition segments) plays back correctly.
- Batch: select ≥3 genomes → SelectionBar → Export… → choose a directory →
  one `.mp4` per genome, named by stem, in order.
- Cancel mid-export ⇒ partial deleted, banner shows "Cancelled."
- Quality = Genome default ⇒ the `.mp4`'s frame 0 matches `emberweft animate
  --frame 0 --size <WxH>` (byte-identical) at the same seed AND the same
  width/height as the GUI's chosen resolution tier (animate defaults to the
  genome's native size; the GUI uses a tier — match them via `--size`).
- Backend = Metal, then unplug/disable GPU edge case is simulated by forcing CPU
  ⇒ export still completes.

### 9.6 Honest M6 Definition of Done (closes the milestone)
- Can export a single genome to MP4 (H.264) ✓ (CLI had it; now GUI).
- Can export a sequence with transitions ✓ (GUI `run`, `segmentCount=flames.count`).
- **Progress bar updates accurately** ✓ (§4.7 banner).
- **Can cancel mid-stream** ✓ (cooperative; partial cleaned).
- Exported video matches realtime rendering quality (determinism) ✓ (shared
  resolver; byte-identity pin).
- **≥3 export presets** ✓ (720p/1080p/1440p/4K resolution + Genome/Low/Med/High
  quality tiers).
- All `[automated]` tests green; no engine-math change (parity unaffected);
  `CHANGELOG`/`README`/`roadmap` updated to **M6 ✅ Done (v0.5.0)**; tagged + pushed.

---

## 10. Out of scope / deferred (explicit)

Export queue + concurrent jobs; ProRes/AV1/HDR/10-bit/alpha; audio; `BGProcessingTask`
(finish-after-quit); floating non-modal progress `NSPanel`; orphaned-`.partial-*`
sweep on launch; a per-genome estimated-duration/size display. All noted for M7/M8
or a later polish slice.

---

## 11. Constraints honored (CLAUDE.md)

- **Reference-then-Optimize / parity:** the sole renderer edit is a
  byte-identical extraction (§4.1); no engine-math change; `git diff` shows no
  `Sources/FlameKit`/`FlameReference` change. The parity gate is not regressed.
- **Determinism (rule #2):** pure value transformations; no hashed-collection
  float sums; explicit seed; pinned tests.
- **No external deps:** Apple SDKs only (Foundation, SwiftUI, AppKit,
  AVFoundation, Metal). No new packages.
- **Swift 6 strict concurrency:** `@MainActor @Observable` VM; actor coordinator;
  `Sendable` job/settings/progress; MainActor-isolated consume loop; `isAvailable`
  probed only on MainActor (G6); no new `nonisolated(unsafe)`.
- **Test-first:** each slice's `FlameRendererTests`/`EmberweftUITests` file is
  written red before green.
- **Faithful flam3 port:** untouched — this slice changes no flam3 algorithm.
- **Reuse over reinvent:** the engine (coordinator, encoder, `FramePlan`,
  `ThreadSeedBudget`, D11/D12/D13) is reused as-is; the CLI's settings-resolution
  is *extracted* (shared), not duplicated (G5); `SequencePlaybackViewModel`'s
  resolved `[Flame]` is reused for sequence export.

---

## 12. Risks & mitigations

| Risk | L/I | Mitigation |
|---|---|---|
| Off-main temporal extraction introduces a subtle divergence | Low / High | Byte-identical by construction (same code, thread-independent GPU compute); pinned by ts>1 parity tests (§9.2). |
| `ExportCommand` refactor breaks CLI byte-identity | Low / High | `resolveExportSettings` → thin caller of shared `resolve`; re-run existing CLI/export↔animate pins (§9.3). |
| `@Observable` progress churn at high fps | Low / Low | Banner-only re-render (cheap); optional ~20 Hz cap if profiling demands. |
| Export outlives the source window / sheet | Med / Med | `ExportManager` on `AppModel` (G9); banner mounted in all three window types (§4.7); degraded-when-all-closed documented. |
| `NSSavePanel`/`NSOpenPanel` quirk on bundle-less SwiftPM exe | Low / Med | Standard AppKit panels (not the broken in-app drag-drop path); the app already sets `.regular` activation policy (`EmberweftApp.swift:11`); manual acceptance (§9.5). |
| Display sleep stalls a long export | Med / Med | `ProcessInfo` activity token (G10). |
| Determinism break from new collections | — | Pure mappings; no Dict/Set float sums; pinned (§9.4). |
| **offMainQueue contention: GUI export vs thumbnail render (D-G12)** | Med / Low | Both serialize on `MetalRenderer.offMainQueue`; bounded ~25–50 ms stall, no deadlock. Documented (§7); realtime MainActor playback is unaffected (different queue). |
| **CLI refactor breaks export↔animate byte-identity** | Low / High | `resolveExportSettings` → thin caller of shared silent `resolve`; re-run the named existing pins (§9.3); behavior-identical by construction. |

---

**Credit:** fractal flame algorithm © Scott Draves (1992). Electric Sheep™ and
Infinidream™ are trademarks of Scott Draves / e-dream, inc.
