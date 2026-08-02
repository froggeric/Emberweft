# M6 — Export Pipeline — Developer-Ready Spec

This is the reviewed, buildable specification for M6 (an adversarial
principal-engineer review of the draft, with every defect resolved in-document).
Every claim was verified against the code on `main`. Read the
"Defects found & overrides" section first — it is what changed and why.

---

## 1. Context

**Why this exists.** M3 shipped `emberweft animate`, a faithful flam3 port that
renders a PNG sequence plus `manifest.json`. PNG sequences are the byte-exact
mastering path, but they are not a deliverable video. M6 adds the missing sink:
drive the existing deterministic renderers through a pure frame-plan and encode
the output to MP4/MOV via `AVAssetWriter`. The renderers, the schedule, the
blend math, and the determinism contract are all reused unchanged. M6 changes
only the sink (PNG writer -> video encoder) and adds one mandated acceleration
(cache the Metal `threadSeeds`).

**Locked scope (owner's decisions — design within these, do not revisit):**
- CLI-first. M6 ships a headless `emberweft export` command. The GUI export
  sheet/progress UI is a follow-up slice, out of scope here, but the engine is
  designed to be GUI-drivable later (progress via `AsyncThrowingStream`).
- Codecs: H.264 + HEVC only. ProRes/AV1/lossless = M8. HDR/10-bit = M8.
  Audio = M7. All out of scope.
- SDR 8-bit, no audio track.
- Export quality: `.genome` (faithful default) or `.spp N` only. Named quality
  tiers are deferred to the GUI export sheet (the DoD's ">=3 presets" are
  resolution tiers, already covered by `Resolution`).
- Engine scope: single continuous export + resolution/codec presets +
  long-form segment+concatenate + batch queue.
- Architecture: "reuse + wrap, copy path". Drive the EXISTING off-main/MainActor
  renderers through a pure frame-plan; copy `RGBA8Image` bytes into a pooled
  `CVPixelBuffer` for `AVAssetWriter`. Zero-copy IOSurface GPU->encoder is
  DEFERRED (see Defect D9 / §15 for why).

**Supersedes the preliminary design note.** `docs/export/export-pipeline.md` is
an aspirational draft that predates the locked scope. It contradicts the codebase
on several points: it seeds from `sheep.hashValue` (rule-#2 violation: Swift
hash seeds are randomized per process), invents a `xoroshiro256plus` RNG (the
engine is ISAAC), proposes ProRes/AV1/HDR/audio/GUI-sheet/`BGProcessingTask`/
MTLTexture pools/EXIF metadata, and uses GUI-only naming (`Sheep`/`ExportSource`).
That doc is NOT a spec. M6 implements this document; the old note is left in
place for the owner to retire or rewrite.

**What's already on `main` (verified — do not rebuild):**
- `EmberweftCLI.animate(_:)` (`Sources/EmberweftCLI/AnimateCommand.swift`) is the
  offline reference loop. It is synchronous `for globalFrame in 0..<totalFrames`,
  builds `TemporalFilter.samples(...)` per frame, scales deltas by
  `1/framesPerSegment` (load-bearing unit fix, AnimateCommand.swift:249-259),
  builds a `@Sendable blendAt: (Double) -> Flame`, dispatches Metal
  (`MainActor.assumeIsolated { autoreleasepool { ... } }`) or CPU, writes PNG,
  appends a `Manifest.FrameEntry`. `--quality` overrides spp only; **oversample
  is hardcoded `1`** (AnimateCommand.swift:328). `--frame N` renders only global
  frame N. `temporalSamples` defaults to the genome's value on CPU, capped 64 on
  Metal. It does NOT short-circuit the loop->transition boundary offline
  (AnimateCommand.swift:299-321).
- `Sources/FlameKit/Schedule.swift`: pure `Sendable` value. `frameToBlend` is
  **non-mutating, O(1)** -> `FrameMapping{segmentId,kind,blend}`, blend in
  `(0,1]`, 1-indexed. `segment(at:)` is **`mutating`** (extends the lazy walk
  cache). `isLoopToTransitionBoundary(globalFrame:)` is pure O(1).
- `Sources/FlameKit/Loop.swift`: `Loop.blend(_ sheep: Flame, t: Double,
  cycles: Int = 1) -> Flame` (sheep_loop, pure).
- `Sources/FlameKit/Transition.swift`: `Transition.blend(_ a: Flame, _ b: Flame,
  t: Double, stagger: Double = 0) -> Flame` (sheep_edge, pure).
- `Sources/FlameKit/PairSelector.swift`: `Sequential` (seed-independent),
  `SimilarityExploration` (seeded PCG32).
- `Sources/FlameKit/RenderTypes.swift`: `RGBA8Image{width,height,pixels:[UInt8]}`
  RGBA, row-major, **top-first**, premultiplied-last. `RenderParams{seed,width,
  height,oversample,samplesPerPixel,spatialFilterRadius=0.5}`;
  `totalSamples = width*height*samplesPerPixel`; builders `settingSamplesPerPixel`
  / `settingSpatialFilterRadius`.
- `Sources/FlameKit/Genome.swift`: `Quality` (genome-side) carries
  `samplesPerPixel`, `oversample`, `filterRadius`, `temporalSamples`,
  `temporalFilterType/Width/Exp`, etc. `Manifest` is in FlameKit
  (`Sources/FlameKit/Manifest.swift`).
- `Sources/FlameReference/TemporalFilter.swift`: `TemporalFilter.samples(_ n,
  type, width, exp) -> (samples:[(delta,weight)], sumfilt:Double)`. **Pure,
  depends only on `FlameKit.FilterShape`** (it `import FlameKit` only).
- `Sources/FlameReference/ReferenceRenderer.swift`: `public enum`,
  **nonisolated** (off-main safe). `render(flame:params:)` + temporal
  `render(blendAt:centerTime:temporal:sumfilt:params:)` (box/gaussian/exp).
  Traps on no-GPU? No: CPU never traps on GPU; it is the oracle.
- `Sources/FlameRenderer/MetalRenderer.swift`: `public enum`.
  `@MainActor render(flame:params:) -> RGBA8Image` (traps if unavailable).
  `@MainActor render(blendAt:centerTime:temporal:sumfilt:params:) -> RGBA8Image`
  (temporal; **MainActor only**; `fatalError` on non-box weights).
  `nonisolated renderOffMain(flame:params:) -> RGBA8Image?` (**single-pass only**;
  byte-identical to the MainActor path; blocks `offMainQueue.sync`; returns nil
  on failure, never traps). `renderFusedCore(...)` is the actor-agnostic core.
  Device/library PSOs are `@MainActor`-cached; `offMainCache` is
  `nonisolated(unsafe)` serialized via `offMainQueue`.
- `Sources/FlameRenderer/MetalHost.swift`: `buildThreadSeeds(seed: UInt64,
  threadCount: Int) -> [UInt64]` (line 146). **Pure function of `(seed,
  threadCount)`**: seeds a parent `ISAAC(isaacSeed: "emberweft-metal-\(seed)")`
  and serial-draws `threadCount * ISAAC.randsizWords` (`==16`) words. Called
  per-frame in `renderFusedCore` (~line 209) with `(params.seed, fp.threadCount)`
  and per sub-pass in `renderTemporalFused` (~line 661) with
  `(params.seed &+ UInt64(i), perPassThreads)`. `pinnedThreadCount` is a pure
  function of `params.totalSamples` (= `width*height*spp`).
- `Sources/EmberweftUI/GenomeHealth.swift`: `Flame.isRenderable` (extension on
  `Flame`). **Lives in EmberweftUI, NOT FlameKit.** Uses only `Flame.camera`
  and `Flame.xforms` (both FlameKit types). `CurateCommand.swift:155` already
  inlines a replica because EmberweftCLI does not depend on EmberweftUI.
- `Sources/EmberweftUI/RGBAImage+CGImage.swift`: `toCGImage()` is **upright,
  no-flip** (premultipliedLast, sRGB). `FlameUI.makeCGImage` (FlamePlayer) FLIPS
  (for `CAMetalLayer` only). The export path uses neither for the pixel copy
  (direct bytes -> CVPixelBuffer); the orientation invariant still applies
  (§4.4).
- `Sources/FlameReference/RGBAImage+PNG.swift`: `writePNG`/`readPNG`
  (top-first). PNG bytes are NOT byte-stable across runs (timestamps).
- `Sources/EmberweftUI/AppPreferences.swift`: `QualityPreset`
  (low=2/medium=8/high=30 spp; oversample low/med=1, high=2). `renderParams()`
  is DORMANT (no callers). `PreviewPreset` is the realtime-preview source of
  truth. Both live in EmberweftUI (GUI).
- `Sources/FlameExport/FlameExport.swift`: 5-line STUB.
- `Package.swift`: `FlameExport` deps = `[FlameRenderer, FlameKit]` (MISSING
  `FlameReference`). `EmberweftCLI` deps = `[FlameKit, FlameReference,
  FlameRenderer]` (MISSING `FlameExport`). No `FlameExportTests` target exists.
- **ZERO-COPY NOT POSSIBLE TODAY:** both renderers' terminal step is `memcpy`
  from a `.storageModeShared` `MTLBuffer` -> `[UInt8]` (MetalRenderer.swift:404,
  773). `RGBA8Image` is bare bytes. No reference to `CVPixelBuffer`,
  `CVPixelBufferPool`, `IOSurface`, or `makeTexture` anywhere in `Sources/`.

**Out of scope (do NOT pull in):**
- GUI export sheet, progress window, in-app preview of the encode (follow-up).
- Zero-copy IOSurface GPU->encoder (§15). Audio muxing (M7). HDR/10-bit,
  ProRes/AV1 (M8).
- Any change to the parity gate beyond what M6.2's threadSeeds pin requires.
- `emberweft animate` continues to exist unchanged in behavior; it is only
  refactored to share `FramePlan` (M6.1, byte-identical, pinned by a snapshot
  test).

---

## 2. Defects found in the proposed plan & overrides

| # | Plan claim / decision | Defect (verified against the code) | Override in this spec |
|---|---|---|---|
| D1 | "Degenerate/NaN genome -> `isRenderable` gate" in the export path | `Flame.isRenderable` is an extension in **EmberweftUI/GenomeHealth.swift**. `FlameExport` and `EmberweftCLI` do NOT depend on EmberweftUI (and must not: it drags in SwiftUI/AppKit). `CurateCommand.swift:155-167` already inlines a copy. | **Move `Flame.isRenderable` down to FlameKit** (`Sources/FlameKit/GenomeHealth.swift`). It touches only FlameKit types. EmberweftUI re-exports it (its file becomes `@_exported import`-free; the extension moves). Delete the CurateCommand inline replica. FlameExport + EmberweftCLI + CurateCommand all call the one FlameKit definition. §3.2. |
| D2 | "FlameExport deps FlameKit+FlameReference+FlameRenderer"; "EmberweftCLI gains FlameExport dep" | `Package.swift` has `FlameExport` deps = `[FlameRenderer, FlameKit]` only. `EmberweftCLI` has no `FlameExport` dep. | Add `FlameReference` to FlameExport deps; add `FlameExport` to EmberweftCLI deps; add a `FlameExportTests` target. §9. |
| D3 | "ExportCoordinator drives render off-main" | **No off-main temporal Metal path exists.** `MetalRenderer.renderOffMain(flame:params:)` is single-pass. The temporal `render(blendAt:...)` is `@MainActor` (MetalRenderer.swift:132). Metal+temporalSamples>1 CANNOT run off-main without adding a new off-main temporal variant (scope creep, parity risk). | The coordinator dispatches per backend exactly as `animate` does today: Metal (single or temporal) via `await MainActor.run { autoreleasepool { MetalRenderer.render(...) } }`; CPU via `Task.detached { ReferenceRenderer.render(...) }` (ReferenceRenderer is nonisolated). The actor never runs blocking render on its own executor. §4.1, §3.5. |
| D4 | "`FramePlan`/`FrameDescriptor` (FlameKit, pure): `descriptor(globalFrame) -> {…, temporal:[(delta,weight)], …, blendAt}`" | `TemporalFilter` lives in **FlameReference**. A FlameKit `FramePlan` that calls `TemporalFilter.samples` would force `FlameKit -> FlameReference` (backwards; FlameReference depends on FlameKit). | **Move `TemporalFilter.swift` from FlameReference to FlameKit.** It is pure, `import FlameKit` only, depends only on `FilterShape` (already FlameKit). FlameReference re-exports (`@_exported import FlameKit`) so existing call sites (`ReferenceRenderer`, `AnimateCommand`) compile unchanged. `TemporalFilterTests` move FlameKitTests-ward (or stay re-exported). Now `FramePlan` (FlameKit) owns the complete per-frame recipe including temporal samples, with no layering break. §3.3. |
| D5 | "`FramePlan.descriptor(globalFrame) -> …` O(1), deterministic, pure" | `Schedule.segment(at:)` is **`mutating`** (extends the lazy walk cache, Schedule.swift:214). A pure `descriptor(globalFrame)` cannot mutate a held `let Schedule`. | `FramePlan` is constructed with `(schedule, segmentCount, flames, …)` and **pre-materializes the whole segment walk once at construction** (`for id in 0..<segmentCount { _ = schedule.segment(at: id) }`), then snapshots the resulting `[Segment]`. `descriptor(globalFrame)` is then pure O(1) array indexing. `segmentCount` is small and bounded (animate default 3). `Schedule` remains usable independently; FramePlan just caches the walk. §3.3. |
| D6 | "ExportQuality: `.genome` (base flame spp) \| `.spp(Int)`"; "frame pixels byte-identical to `animate --frame N`" | `animate` **hardcodes `oversample: 1`** (AnimateCommand.swift:328). Any export quality that resolves `oversample != 1` can NEVER be byte-identical to `animate` (different `oversample` -> different `totalSamples` -> different thread geometry -> different image). | Owner decision: M6 exposes `.genome` and `.spp(Int)` ONLY (named tiers deferred to the GUI sheet). Both resolve `oversample = 1`: `.genome` -> `(flames[0].quality.samplesPerPixel, 1)`; `.spp(N)` -> `(N, 1)`. So every M6 export is byte-identical to `animate` at matching seed/size/temporal. The byte-identity-with-animate pin (§12.1) is unconditional in M6. Documented in §5.2. |
| D7 | "threadSeeds cache key = `(seed, threadCount)`" (implied single key) | The temporal path uses **N distinct per-pass keys**: `(params.seed &+ UInt64(i), perPassThreads)` for `i in 0..<N` (MetalRenderer.swift:660-662, per-pass `perPassThreads = max(tpg, roundUp(tcFull/N))`). A single cache entry does not cover the temporal path; the coordinator must not replicate the `perPassThreads` formula (fragile drift). | The acceleration is a `MetalRenderer.ThreadSeedBudget` value (FlameRenderer) constructed from `(baseSeed, totalSamples, temporalCount)`. It computes `tcFull`, `perPassThreads`, and the 1-or-N precomputed `[UInt64]` arrays using the SAME `MetalHost` formulas (no duplication). The render entry points take `threadSeeds: ThreadSeedBudget?`; nil = today's behavior (realtime). The budget is built once per export and passed to every frame/sub-pass. Byte-identity proof + parity guard in §6. |
| D8 | (Not specified) presentation timing precision | `CMTime(value: frameIndex, timescale: fps)` needs an integer `timescale`. Fractional fps (23.976) yields a non-integer timescale -> float seconds -> VFR or rounding drift. The draft says "fps" generically. | `ExportSettings.fps` is a positive `Int`. Accepted values: 24/25/30/48/50/60. Each frame is presented at `CMTime(value: Int64(frameIndex), timescale: fps)` (exact rational, CFR). Reject fractional/negative/zero fps at parse time (exit 2). §3.4, §10. |
| D9 | "RGBA8Image -> CVPixelBuffer copy (R<->B swap, top-first, premultiplied)" | The premultiplied-alpha invariant under R<->B swap is unstated and unproven; the orientation invariant (top-first) relies on the M4 gotcha but has no pin; zero-copy is "deferred" with no reason recorded. | (a) Byte swap is `dst[0]=src[2]`(B), `dst[1]=src[1]`(G), `dst[2]=src[0]`(R), `dst[3]=src[3]`(A) per pixel. Premultiplication holds: it is a per-pixel relation `R,G,B <= A`; permuting R and B preserves it (both stay <= A). Opaque (A=255) is trivially correct. (b) `RGBA8Image` is top-first; `AVAssetWriterInputPixelBufferAdaptor` expects top-first video frames; direct row-major copy (no flip) yields upright video. Pinned by an orientation test (§12.3). (c) Zero-copy deferred because BOTH renderers terminate in `memcpy` from `.storageModeShared` `MTLBuffer` -> `[UInt8]` (verified); there is no `IOSurface`/`CVPixelBuffer`/`MTLTexture`-from-IOSurface path to hand the encoder. Building one is an engine-layer change (new Metal readback path + parity re-proof) outside M6's scope. §15. |
| D10 | "long-form = segment -> temp .mov -> AVMutableComposition passthrough concat (segment boundaries on Schedule segment edges)" | Passthrough concat requires identical codec/resolution/timescale across all segment files, consistent audio-track absence, and a clean splice at GOP boundaries; empty/single-frame segments, and the final-vs-sum duration invariant, are unspecified. | (a) All temp segments are encoded with the SAME `ExportSettings` (codec/res/fps/bitrate) -> identical codec params + timescale. No audio track in any segment (consistent). (b) Chunk boundaries are ALWAYS on Schedule-segment edges (whole loops/transitions), never mid-segment; chunk size = `max(1, segmentFrameBudget / framesPerSegment)` segments. A segment always has `framesPerSegment >= 1` frames (precondition), so no empty temp file. (c) Concat via `AVMutableComposition` + `AVAssetExportSession(preset: .passthrough)` (no re-encode; keyframes preserved as-is). (d) Pinned: decoded final duration == sum of segment durations; decoded frame at each splice == the corresponding standalone segment boundary frame (§12.6). |
| D11 | "Batch = serial `run(jobs:)`" | Failure semantics (continue vs fail-fast), cancel scope (current job vs whole batch), aggregate progress, and ordering are unspecified. | (a) Default: a failed job is recorded and the batch CONTINUES; exit code is nonzero iff any job failed. `--fail-fast` aborts on first failure. (b) Cancel aborts the CURRENT job (cleanup its partial + temp files) AND stops processing remaining jobs. (c) Aggregate progress: per-job stream wrapped in a batch stream that prefixes `[j/totalJobs]`; jobs run in array order (deterministic). (d) `--jobs manifest.json` (array of per-job arg objects) or repeated `--job` flags; paths resolved/sanitized under the batch base dir (§8.1). §4.3, §7. |
| D12 | "Cancel -> cooperative -> `cancelWriting()` + delete partial" | `AVAssetWriter.finishWriting()` is asynchronous and CANNOT be canceled mid-finalize; the window between "last append" and "finishWriting completes" is uncancellable. Cleanup of temp segment files on a CRASH (not just clean cancel) is unspecified. | Cancel lifecycle: (1) cooperative flag checked BETWEEN frames (never mid-render); (2) if `writer.status == .writing`, call `cancelWriting()` (NOT `finishWriting()`), then delete the partial output; (3) once `finishWriting()` has been invoked, AWAIT it (cannot interrupt); on its failure, delete partial. (4) Temp segment files are registered in a cleanup list at creation and removed in a `defer`/`finally` block that runs on success, cancel, OR thrown error (crash-safe via `try?`). §7. |
| D13 | (Not specified) destination overwrite, disk precheck, path safety | `AVAssetWriter(outputURL:fileType:)` FAILS (`.failed` status) if the output file already exists. The draft says nothing about overwrite, truncation mid-encode, disk-full, or path traversal in `--jobs` manifests. | (a) If `--out` exists: require `--force` to overwrite; without it, error (exit 2) and do NOT touch the existing file. (b) Atomic handoff: encode to `<out>.partial-<pid>.mov`; on success `rename` to `<out>` (atomic on same volume); on any failure/cancel delete the partial (a good existing file is never clobbered by a failed run). (c) Disk-space precheck before the first frame: estimate `ceil(bitrate * durationSeconds / 8 * 1.25)` (25% headroom, plus a per-segment temp allowance for long-form); error early (exit 1) if the volume's free space is below the estimate. (d) Path traversal: `--out` and every manifest `out` are sanitized via `URL.lastPathComponent` + char-class allowlist, resolved under the batch base dir; reject `..`/absolute/hidden. §8. |
| D14 | (Not specified) HEVC encode availability | HEVC encode is hardware/software-gated and may be unavailable on some machines; VideoToolbox may reject the requested settings. The draft assumes HEVC always works. | Before opening the writer, probe the requested codec via `AVAssetWriterInput` settings validation (`assetWriterInput.responds(to:)`/`canPerformMultiplePasses` probes are insufficient; use a `VTCompressionSession`-free probe: attempt `AVAssetWriter` setup in a dry-run that checks `writer.status`/`writer.error` after appending one synthetic frame, OR query `VTCopyVideoToolboxXPCProviderCapabilities`-style APIs where available). If the requested codec is unavailable: (a) if the user explicitly asked for it, error with a clear message + exit 1; (b) if it was a default and H.264 is available, fall back to H.264 with a stderr notice. Pinned by a capability test that skips (not fails) on machines without HEVC. §7, §12.5. |
| D15 | "ExportCoordinator (actor): drives FramePlan -> renderer -> encoder" | An `actor` that calls `MetalRenderer.renderOffMain` (which does `offMainQueue.sync { ... }`) or the temporal `@MainActor render` directly will BLOCK its own executor (and, for MainActor render, must `await MainActor.run` anyway). The draft hand-waves the blocking. | `ExportCoordinator` is a `public actor`. It NEVER runs render on its own executor. Per-frame dispatch: Metal -> `await MainActor.run { autoreleasepool { MetalRenderer.render(...) } }` (single or temporal, exactly as animate); CPU -> `await Task.detached(priority: .userInitiated) { ReferenceRenderer.render(...) }.value`. Encode (`encoder.append`) happens back on the actor between renders. Progress flows out via `AsyncThrowingStream` with a per-frame yield. §3.5, §4.1. |
| D16 | (Not specified) encoder backpressure | `AVAssetWriterInput.isReadyForMoreMediaData` must be polled before `append`; appending when not ready yields black/dropped frames or a writer error. The naive "render, append, repeat" tight loop on the actor can starve the encoder or deadlock if the encoder is slower than the renderer. | The append step is a poll-and-yield loop: before `append(image, at:)`, while `!input.isReadyForMoreMediaData`, `await Task.yield()` (cooperative; bounded by the adaptor's pool). The adaptor is constructed with `sourcePixelBufferAttributes` specifying the pool threshold (cap in-flight to 3). This keeps the producer (render) from running away from the consumer (encode) without blocking the actor. The pull-model alternative (`requestMediaDataWhenReady(on:queue:)`) is noted but not used (it inverts control away from the FramePlan-driven loop). §4.4, §8.3. |
| D17 | (Not specified) pool sizing, 4K memory | At 4K a single `CVPixelBuffer` (32BGRA) is `3840*2160*4 = ~33 MB`. An unbounded pool plus the renderer's own buffers (the threadSeeds array alone can be hundreds of MB at high spp) risks memory exhaustion on long/batch exports. | `PixelBufferPool` is backed by `CVPixelBufferPool` with a max in-flight of 3 (matches the adaptor). `acquire()` blocks/yields until a buffer is recycled (cooperative, not a hard fail). The threadSeeds budget is shared (read-only) across frames, not reallocated. A per-export memory ceiling is computed (`width*height*4 * 3` + segment temp allowance) and reported; if it exceeds a conservative threshold (e.g. 4 GB) the CLI prints a note but proceeds (owner's risk). §3.6, §8.3. |
| D18 | "`docs/export/export-pipeline.md`" referenced as background | That file is an aspirational draft that contradicts the locked scope (ProRes/AV1/HDR/audio/GUI/`sheep.hashValue` seeding/xoroshiro256plus). Treating it as background imports those contradictions. | This spec SUPERSEDES it. §1 notes the divergences; the old file is left for the owner to retire. Do not import its types or its seed model. |
| D19 | "ExportQuality `.genome` (base flame spp, faithful default)" for a multi-genome sequence | "base flame" is ambiguous across a multi-genome timeline (different segments have different `fromSheep`). animate uses `baseFlame = flames[0]` for BOTH `renderQuality` and the temporal defaults (AnimateCommand.swift:134, 147-149). | `ExportQuality.genome` resolves against `flames[0]` (the first listed genome), exactly as animate: `samplesPerPixel = flames[0].quality.samplesPerPixel`, `oversample = 1`. This is the faithful default and is the only quality mode that is byte-identical to `animate`. The temporal filter shape/width/exp remain per-`fromSheep` (read inside `FramePlan.descriptor` per segment, as animate does). §5.2. |
| D20 | (Not specified) empty-genome / single-genome-loop / N<2 guards | The export path must mirror animate's genome-count guards or it can build a degenerate `Schedule` (transitions with one genome). | Mirror `AnimateCommand`: `genomes.count >= 1` required; `segmentCount > 1 && genomes.count < 2` -> error (exit 2) with the same message, suggesting `--segments 1`. A single genome produces a loop-only video. `totalFrames == 0` -> error. These guards live in `ExportCommand` (and a shared helper if animate refactors). §10, §7. |

**Things the plan got right (kept):** reuse-and-wrap (drive existing renderers,
change only the sink); copy path into pooled `CVPixelBuffer`; the `FramePlan` /
`FrameDescriptor` extraction concept; `threadSeeds` pass-in acceleration with
byte-identity + parity guard; honest encoder-byte-instability caveat (frame
PIXELS are byte-deterministic, the encoded `.mp4` is not); `animate` -> PNG stays
the byte-exact mastering alternative; CLI-first with GUI later; slicing M6.1 ->
M6.7; excluding `AdaptiveQualityController`; long-form chunked on Schedule-segment
edges; batch serial.

---

## 3. Architecture & data design

### 3.1 Module / testability boundary (load-bearing)

```
FlameKit  (pure value types; HAS test target FlameKitTests)
   + FramePlan, FrameDescriptor               (NEW)
   + Flame.isRenderable                        (MOVED from EmberweftUI)
   + TemporalFilter                            (MOVED from FlameReference)
        |  (FlameReference re-exports FlameKit unchanged)
        v
FlameReference  (CPU oracle; off-main; HAS test target FlameReferenceTests)
   (TemporalFilter moved out; call sites re-export-compile unchanged)
        |
FlameRenderer  (Metal; HAS test target FlameRendererTests)
   + MetalRenderer.ThreadSeedBudget            (NEW)
   + MetalRenderer.render(..., threadSeeds:)   (MODIFIED, optional)
        |
FlameExport  (NEW bulk; HAS NEW test target FlameExportTests)
   ExportSettings, ExportQuality, Resolution, PixelBufferPool,
   VideoEncoder, ExportCoordinator (actor), ExportProgress
   deps: FlameKit + FlameReference + FlameRenderer
        |
EmberweftCLI  (HAS test target EmberweftCLITests)
   + ExportCommand                             (NEW)
   MODIFIED: AnimateCommand uses FramePlan; CurateCommand uses Flame.isRenderable
   deps: FlameKit + FlameReference + FlameRenderer + FlameExport
```

Rule: all encode/plan/coordinator logic lives in `FlameExport` (or FlameKit for
the pure plan) and is covered by `@testable import FlameExport` /
`FlameKitTests`. `EmberweftGUI` is untouched by M6.

### 3.2 `Flame.isRenderable` (MOVED — `Sources/FlameKit/GenomeHealth.swift`)

Verbatim move of the EmberweftUI extension (GenomeHealth.swift:13-29). It uses
only `Flame.camera.center`, `Flame.camera.scale`, `Flame.xforms` (all FlameKit).
EmberweftUI/GenomeHealth.swift is DELETED (its callers already `import FlameKit`,
which now provides the extension; no re-export needed because Swift extensions
on a public type from an imported module are visible). `CurateCommand`'s inline
replica (CurateCommand.swift:155-167) is DELETED, replaced by `flame.isRenderable`.
Zero behavior change (same logic, same bounds `[1e-3, 4000]`).

### 3.3 `FramePlan` / `FrameDescriptor` (NEW — `Sources/FlameKit/FramePlan.swift`)

Extracts AnimateCommand's per-frame Flame+temporal construction into a pure,
reusable, pre-materialized value. Drives both `AnimateCommand` (M6.1 refactor,
byte-identical) and `ExportCoordinator`.

```swift
/// A complete, pure recipe for rendering one global frame of a Schedule timeline.
/// O(1) to use; constructed once per export/animate run.
public struct FrameDescriptor: Sendable {
    public let globalFrame: Int
    public let segmentId: Int
    public let kind: Segment.Kind
    public let blend: Double                      // (0,1], 1-indexed
    public let fromSheep: Int
    public let toSheep: Int
    /// Temporal sub-samples with deltas already SCALED to blend units
    /// (delta_per_frame / framesPerSegment). N==1 -> [(0,1)] (identity).
    public let temporal: [(delta: Double, weight: Double)]
    public let sumfilt: Double
    /// Builds the Flame at an absolute sub-time (centerTime + sub.delta).
    /// Loop unclamped; Transition clamped to [0,1] internally (AnimateCommand
    /// semantics). The loop->transition boundary is NOT short-circuited here
    /// (offline path relies on temporal blur — see CLAUDE.md gotcha).
    public let blendAt: @Sendable (Double) -> Flame
}

public struct FramePlan: Sendable {
    public let framesPerSegment: Int
    public let totalFrames: Int
    /// Pre-materialized segments (the schedule walk is frozen at construction).
    public let segments: [Segment]
    public let flames: [Flame]                    // indexed by fromSheep/toSheep
    public let loopCycles: Int
    public let stagger: Double
    public let temporalSamples: Int               // resolved (>=1)

    /// Construct from a Schedule. Pre-materializes `segmentCount` segments
    /// (mutating `schedule` here, then freezing the result — descriptor() is
    /// thereafter non-mutating + pure O(1)).
    public init(
        schedule: inout Schedule,
        segmentCount: Int,
        flames: [Flame],
        loopCycles: Int = 1,
        stagger: Double = 0,
        temporalSamples: Int = 1
    )

    /// Pure O(1). Returns the render recipe for `globalFrame`.
    /// `temporalSamples` resolution mirrors AnimateCommand exactly:
    ///   - 1 -> [(0,1)] / sumfilt 1.0 (identity, byte-matches the single path)
    ///   - >1 -> TemporalFilter.samples(N, type/width/exp from flames[fromSheep])
    ///           with deltas divided by framesPerSegment (load-bearing unit fix).
    public func descriptor(for globalFrame: Int) -> FrameDescriptor
}
```

`descriptor` builds `blendAt` to close over `flames`, `segments`, `loopCycles`,
`stagger` (all `Sendable` value types) exactly as AnimateCommand.swift:299-321
does. Because `Segment`/`Flame` are values and the closure captures `let`s, it
is `@Sendable` and rule-#2-safe (no Dict/Set float sums; `Segment.fromSheep` is
an Int index).

### 3.4 `ExportSettings`, `ExportQuality`, `Resolution` (NEW — FlameExport)

```swift
public struct ExportSettings: Codable, Sendable, Equatable {
    public var codec: Codec                  // .h264 | .hevc
    public var resolution: Resolution        // .p720 | .p1080 | .p1440 | .p4k
    public var fps: Int                      // 24/25/30/48/50/60 (integer; CMTime timescale)
    public var quality: ExportQuality        // spp+oversample source
    public var temporalSamples: Int          // motion blur (1 = sharp)
    public var container: Container          // .mp4 | .mov
    public var bitrate: Bitrate              // .auto | .mbps(Int)
    public var segmentFrameBudget: Int       // long-form chunk size in frames (<= totalFrames => single)
    public var metadata: [MetadataItem]      // title/creator/etc (best-effort)

    public enum Codec: String, Codable, Sendable { case h264, hevc }
    public enum Container: String, Codable, Sendable { case mp4, mov }
    public enum Bitrate: Codable, Sendable, Equatable { case auto; case mbps(Int) }
    public struct MetadataItem: Codable, Sendable, Equatable { public var key: String; public var value: String }

    public enum Resolution: String, Codable, Sendable, CaseIterable {
        case p720, p1080, p1440, p4k
        public var width: Int { ... }        // 1280/1920/2560/3840
        public var height: Int { ... }       // 720/1080/1440/2160
    }

    /// Resolves the concrete (spp, oversample) for a given base flame.
    /// `.genome` -> (flames[0].quality.samplesPerPixel, 1)  [byte-matches animate]
    /// `.spp(n)` -> (n, 1)                                   [oversample always 1 in M6]
    public func resolvedSamplesPerPixel(for baseFlame: Flame) -> (spp: Int, oversample: Int)
}

/// M6 quality source. Named quality tiers (low/medium/high) are DEFERRED to the
/// GUI export-sheet slice (owner decision); the roadmap DoD's ">=3 presets" are
/// resolution tiers (covered by `Resolution`), not quality tiers. `.genome` is
/// the faithful default and is byte-identical to `animate`.
public enum ExportQuality: Codable, Sendable, Equatable {
    case genome                              // faithful default; byte-matches animate
    case spp(Int)
}
```

`fps` is `Int` (D8). `ExportQuality` is `.genome` | `.spp(Int)` only (named
tiers deferred — see note above), so FlameExport stays free of any EmberweftUI
dependency. The GUI export sheet (follow-up) may introduce a tier mapping at
that boundary.

### 3.5 `ExportCoordinator` (NEW — actor — `Sources/FlameExport/ExportCoordinator.swift`)

```swift
public actor ExportCoordinator {
    public init(renderer: Backend)            // .metal | .cpu

    /// Single continuous export. Yields progress; returns the final URL on
    /// success. Throws ExportError. Honors Task.isCancelled between frames.
    public func run(_ job: ExportJob) -> AsyncThrowingStream<ExportProgress, Error>

    /// Long-form: chunked on Schedule-segment edges -> temp .mov per chunk ->
    /// passthrough concat -> final. Temps cleaned in all exit paths.
    public func runLongForm(_ job: ExportJob) -> AsyncThrowingStream<ExportProgress, Error>

    /// Batch: serial over jobs. Default continues on failure; --fail-fast via
    /// a flag on the job list. Cancel stops current + remaining.
    public func runBatch(_ jobs: [ExportJob], failFast: Bool) -> AsyncThrowingStream<BatchProgress, Error>

    /// Cooperative cancel of the in-flight run (single/long-form/batch).
    public func cancel() async
}

public struct ExportJob: Sendable {
    public let settings: ExportSettings
    public let genomes: [URL]                 // parsed at run start
    public let out: URL                       // final destination (atomic handoff)
    public let seed: UInt64
    public let framesPerSegment: Int
    public let segmentCount: Int
    public let selector: SelectorSpec         // .sequential | .similarity
    public let loopCycles: Int
    public let stagger: Double
    public let partialURL: URL                // <out>.partial-<pid>.<ext>
}

public struct ExportProgress: Sendable {
    public let phase: Phase                   // .rendering | .encoding | .concatenating | .finalizing
    public let currentFrame: Int
    public let totalFrames: Int
    public let elapsed: Double
    public let eta: Double?
    public let outputFileSize: Int64?
    public let renderFPS: Double              // rolling; diagnostic
    public enum Phase: Sendable { case rendering, encoding, concatenating, finalizing }
}
```

Backend dispatch (D3, D15):
- Metal, single or temporal: `await MainActor.run { autoreleasepool { MetalRenderer.render(blendAt:d.centerTime:temporal:sumfilt:params:threadSeeds:) } }` (temporal) or `... render(flame:params:threadSeeds:)` (single).
- CPU: `await Task.detached(priority: .userInitiated) { ReferenceRenderer.render(blendAt:...) }.value` (off-main; ReferenceRenderer is nonisolated).
- The actor checks `Task.isCancelled` between frames; on cancel it calls `encoder.cancel()` (which calls `writer.cancelWriting()` if `.writing`) and returns/throws `ExportError.cancelled`.

### 3.6 `PixelBufferPool` + `VideoEncoder` (NEW — FlameExport)

```swift
/// IOSurface-backed, Metal-compatible CVPixelBuffer pool (32BGRA, export-sized).
/// Cap in-flight to 3 (D17). acquire() yields while the pool is empty.
public final class PixelBufferPool: @unchecked Sendable {
    public init(width: Int, height: Int, maxInFlight: Int = 3)
    public func acquire() async -> CVPixelBuffer
    /// Copy RGBA8Image -> BGRA CVPixelBuffer (R<->B swap, top-first, premult).
    /// Premultiplied alpha preserved (D9). NO flip.
    public func fill(_ pb: CVPixelBuffer, from image: RGBA8Image)
    public func release(_ pb: CVPixelBuffer)
}

/// AVAssetWriter + Input + PixelBufferAdaptor wrapper. Single serialization
/// queue for status transitions (cancel-safe). Guards isReadyForMoreMediaData.
public final class VideoEncoder: @unchecked Sendable {
    public init(settings: ExportSettings, outputURL: URL) throws
    public func start() throws
    /// Polls isReadyForMoreMediaData (yields while not ready — D16); appends at
    /// CMTime(value: frameIndex, timescale: fps) (D8).
    public func append(_ image: RGBA8Image, atFrame frameIndex: Int) async throws
    public func finish() async throws              // endSession(atSourceTime:); finishWriting()
    public func cancel()                           // cancelWriting() if .writing; no-op otherwise
}
```

`PixelBufferPool` uses `CVPixelBufferPoolCreate` with
`kCVPixelBufferIOSurfacePropertiesKey` + `kCVPixelBufferMetalCompatibilityKey`
(set for the future zero-copy path; harmless today). Format
`kCVPixelFormatType_32BGRA`. The adaptor is constructed with the pool as
`sourcePixelBufferAttributes` (it shares/recycles buffers).

---

## 4. Data flow

### 4.1 Single continuous export

```
ExportCommand.run(args)
 -> parse genomes (Flam3Parser) -> [Flame]; isRenderable gate (FlameKit, D1)
 -> resolve ExportSettings (D6, D19); build ExportJob (atomic partialURL, D13)
 -> disk-space precheck (D13); codec-availability probe (D14)
 -> coordinator.run(job)
      FramePlan(schedule&, segmentCount, flames, …)        // pre-materializes walk (D5)
      MetalRenderer.ThreadSeedBudget(seed, totalSamples, N) // once (D7) — nil for CPU
      encoder.start()
      for globalFrame in 0..<totalFrames:
         if Task.isCancelled { encoder.cancel(); throw .cancelled }
         d = framePlan.descriptor(for: globalFrame)        // pure O(1)
         params = RenderParams(seed, w, h, oversample, spp) // constant
         image = await dispatch(d, params, threadSeeds)     // D3/D15
         await encoder.append(image, atFrame: globalFrame)  // D8/D16 (poll+yield)
         yield ExportProgress(…, currentFrame: globalFrame+1)
      try await encoder.finish()                            // endSession + finishWriting
      rename partialURL -> out                              // atomic handoff (D13)
      return out
```

Per-frame dispatch (`dispatch(d, params, threadSeeds)`):
- Metal + N==1: `await MainActor.run { autoreleasepool { MetalRenderer.render(flame: d.blendAt(d.blend), params: params, threadSeeds: threadSeeds?.single) } }`
- Metal + N>1: `await MainActor.run { autoreleasepool { MetalRenderer.render(blendAt: d.blendAt, centerTime: d.blend, temporal: d.temporal, sumfilt: d.sumfilt, params: params, threadSeeds: threadSeeds?.perPass) } }`
- CPU: `await Task.detached { ReferenceRenderer.render(blendAt: d.blendAt, centerTime: d.blend, temporal: d.temporal, sumfilt: d.sumfilt, params: params) }.value` (CPU ignores threadSeeds; the budget is nil for CPU).

### 4.2 Long-form (segment + concat)

Chunking is on Schedule-segment edges: `chunkSegments = max(1, segmentFrameBudget / framesPerSegment)`. Each chunk renders `chunkSegments` whole segments to a temp `.mov` under the system temp dir (`NSTemporaryDirectory()`), registered in a cleanup list. After all chunks: `AVMutableComposition` + `AVAssetExportSession(preset: .passthrough)` -> final. Temps deleted in a `defer` (crash-safe). Identical codec/timescale/resolution across chunks is guaranteed by construction (same `ExportSettings`). D10.

### 4.3 Batch

`runBatch(jobs, failFast)` iterates `jobs` in order. Each job is a full single/long-form run with its own progress sub-stream. The batch stream yields `BatchProgress(jobIndex, jobProgress, aggregateFraction)`. On job failure (non-fail-fast): record `FailedJob(jobIndex, error)`, continue. On cancel: cancel current job (cleanup), stop. Exit code: `failures.isEmpty ? 0 : 1`. D11.

### 4.4 Timing, pool lifecycle, backpressure

- **Presentation timing (D8):** each frame appended at `CMTime(value: Int64(frameIndex), timescale: fps)`. CFR. `endSession(atSourceTime:)` called with the final frame's time + one frame duration.
- **Pool lifecycle (D17):** pool created at `run` start (export-sized), released at `run` end. `acquire()` yields while at capacity (3); `release()` on append completion.
- **Backpressure (D16):** `encoder.append` polls `input.isReadyForMoreMediaData`; while false, `await Task.yield()`. Because render is the slow producer and encode the fast consumer (usually), this rarely stalls; when it does, the yield keeps the actor responsive to cancel.

---

## 5. Determinism & quality contract

### 5.1 Frame pixels are byte-deterministic (rule #2)

Within a backend, frame pixels are a pure function of `(flames, seed, settings,
globalFrame)`:
- `FramePlan.descriptor(globalFrame)` is pure O(1) (pre-materialized walk, value types, `@Sendable` closure over `let` captures; no Dict/Set float sums).
- `RenderParams` is constant for the whole run (seed/w/h/oversample/spp fixed at start; `AdaptiveQualityController` is NOT in the loop).
- `Loop.blend` / `Transition.blend` are pure FlameKit.
- `MetalRenderer.render` / `ReferenceRenderer.render` are deterministic at fixed `(flame, params)` (verified, rule #2).
- The `threadSeeds` pass-in (§6) is byte-identical to per-frame computation.

Pinned by `testExportFramePixelIdentity` (§12.1): render global frame K twice
from two separate coordinator runs with identical inputs; assert `RGBA8Image`
equality. Pinned across launches by `testExportCrossLaunchDeterminism` (hex of a
downsampled hash, written to a file, compared across two process launches with
different Swift hash seeds).

### 5.2 Byte-identity with `animate` (scoped)

`emberweft export … --quality (genome default) --temporal-samples (genome default)` produces a frame whose pixels are byte-identical to `emberweft animate … --frame N` rendered to PNG, IFF all of: same `flames`, same `seed`, same `width/height`, `ExportQuality.genome` (spp = `flames[0].quality.samplesPerPixel`, oversample = 1), same `temporalSamples`. (Named tiers are deferred; every M6 quality mode uses `oversample = 1`, so this byte-identity is unconditional.) Pinned by `testExportMatchesAnimateFrame` (§12.1): render the same genome+frame both ways, compare `RGBA8Image.pixels`.

### 5.3 The encoded file is NOT byte-stable (honest caveat)

Apple's `AVAssetWriter` VideoToolbox encoder is NOT a documented
deterministic-bytes API. The encoded `.mp4`/`.mov` can differ across machines,
OS versions, or even runs (encoder state, threading, container metadata
timestamps). Byte-exact mastering remains `emberweft animate` -> PNG sequence
(+ an external `ffmpeg` if a stable mp4 is required). This is documented in
`--help` and in the export stderr preamble. The frame PIXELS are
byte-deterministic and verifiable via `export --frame N --png` (M6.1 mirrors
animate's `--frame`).

### 5.4 Motion blur / parity

`--temporal-samples N`: Metal is box-only/cap-64 (fatalError on non-box, as
today); CPU honors box/gaussian/exp uncapped. `--backend` is honored. The
Metal<->CPU statistical parity gate (PSNR >= 38, SSIM >= 0.95) is NOT weakened
by M6 except for the threadSeeds pin (§6), which is byte-identical-by-construction
and adds a dedicated parity test.

---

## 6. The acceleration: `threadSeeds` pass-in

**Where.** `MetalHost.buildThreadSeeds(seed:threadCount:)` (MetalHost.swift:146)
is a pure function: `ISAAC(isaacSeed: "emberweft-metal-\(seed)")` then
`threadCount * 16` serial `parent.next()` draws. It is called per frame in
`renderFusedCore` (~line 209) and per sub-pass in `renderTemporalFused`
(~line 661). At real-genome spp the CPU draw cost is significant (O(totalSamples
/ 64 * 16) ISAAC draws per frame, ~10s of millions of draws).

**Why byte-identical.** `buildThreadSeeds` reads only `(seed, threadCount)`.
For a fixed export, `(seed, width, height, spp)` are constant ->
`pinnedThreadCount(totalSamples)` is constant -> the single-pass seeds are
constant across all frames. For the temporal path, each pass `i` uses
`(params.seed &+ UInt64(i), perPassThreads)`; both are constant across frames.
So the set of seed arrays is identical frame-to-frame; computing once and
reusing yields byte-identical uploads.

**Mechanism (D7).** A `MetalRenderer.ThreadSeedBudget` value (FlameRenderer)
encapsulates the formulas:

```swift
public extension MetalRenderer {
    struct ThreadSeedBudget: Sendable {
        public let baseSeed: UInt64
        public let tcFull: Int                    // pinnedThreadCount(totalSamples)
        public let perPassThreads: Int            // for temporal; == tcFull for single
        public let single: [UInt64]               // tcFull * 16 words
        public let perPass: [[UInt64]]            // N entries; [0] == single when N==1
        public init(baseSeed: UInt64, totalSamples: Int, temporalCount: Int)
    }
}
```

`renderFusedCore` and `renderTemporalFused` gain a `threadSeeds: ThreadSeedBudget?`
parameter (default nil). When non-nil, the per-frame / per-pass `buildThreadSeeds`
call is replaced by `threadSeeds.single` / `threadSeeds.perPass[i]`, with a
`precondition(words.count == threadCount * ISAAC.randsizWords)` guard. When nil,
today's behavior (realtime, compute per frame). The coordinator builds ONE budget
per export and passes it to every frame; CPU runs pass nil.

**Parity guard (rule #2).** `ThreadSeedCacheTests` (FlameRendererTests):
render a real genome frame (a) with `threadSeeds: nil` and (b) with a prebuilt
`ThreadSeedBudget`; assert byte-identical `RGBA8Image`. Also render a temporal
sequence (N>1) both ways; byte-identical per frame. Plus the full parity suite
stays green.

---

## 7. Error / loading / cancel / resilience states

| Surface | Loading | Empty | Error | Cancel |
|---|---|---|---|---|
| Genome parse | (none) | genomes.count < 1 -> exit 2 | unparseable -> exit 1 (batch: record + continue unless `--fail-fast`) | n/a |
| Genome health | (none) | (n/a) | `!isRenderable` -> skip + warn (D1); batch continues | n/a |
| Genome count vs segments | (none) | segments>1 && <2 genomes -> exit 2 (D20) | (n/a) | n/a |
| Backend availability | probe `MetalRenderer.isAvailable` (D14) | (n/a) | Metal unavailable + `--backend metal` -> fall back CPU w/ notice (or exit 1 if `--strict-backend`) | n/a |
| Codec availability (D14) | probe at setup | (n/a) | HEVC unavailable -> explicit-ask exit 1; default -> fall back H.264 w/ notice | n/a |
| Disk space (D13) | precheck before frame 0 | (n/a) | insufficient -> exit 1, no partial | n/a |
| Destination (D13) | precheck `--out` exists | (n/a) | exists + no `--force` -> exit 2; unwritable dir -> exit 1 | n/a |
| Render (per frame) | (per-frame yield) | totalFrames == 0 -> exit 2 | render throws -> exit 1, delete partial | check between frames; cancel -> `encoder.cancel()` + delete partial (D12) |
| Encode append (D16) | poll `isReadyForMoreMediaData` | (n/a) | writer `.failed`/`.error` -> throw, delete partial | (same) |
| finishWriting (D12) | await | (n/a) | failure -> throw, delete partial | mid-finalize NOT interruptible; await then delete partial |
| Long-form concat (D10) | per-chunk progress | chunk has 0 frames -> impossible (fps>=1) | concat throws -> delete temps + partial | cancel before concat -> delete temps + partial |
| Batch (D11) | per-job progress | empty jobs list -> exit 2 | per-job failure recorded; `--fail-fast` aborts | cancel current + remaining |

Cancel is cooperative and frame-granular (never mid-render or
mid-finalize). Temps and partials are registered for cleanup at creation and
removed in a `defer`/finally that runs on every exit path (success, cancel,
error, crash-via-signal best-effort).

---

## 8. Security & scalability

### 8.1 Path safety (D13)

- `--out` and every batch-manifest `out` are sanitized: resolve via
  `URL(fileURLWithPath:).standardizedFileURL`, reject if the path escapes the
  batch base dir (when one is set), reject `..` segments, reject hidden
  (`.foo`) or empty stems, allowlist filename chars `[A-Za-z0-9._-]`.
- Atomic handoff: encode to `<out>.partial-<pid>.<ext>`; `rename` on success;
  `unlink` on any failure. A good existing file is never overwritten by a
  failed run.
- `--force` is required to overwrite an existing `--out`.

### 8.2 Resource bounds

- Pool: 3 in-flight CVPixelBuffers (D17).
- threadSeeds: one shared read-only budget per export (D7).
- Memory ceiling reported (width*height*4*3 + segment allowance); note (not
  error) if it exceeds ~4 GB.
- Temp segments: each deleted after concat; running temp footprint bounded by
  one chunk's file size.

### 8.3 Single-device GPU contention

Metal is single-device (`MTLCreateSystemDefaultDevice`). A batch does not
parallelize Metal across jobs (serial). If the GUI (follow-up) and a CLI export
run concurrently they share the device; the export runs at
`Task.detached(priority: .userInitiated)` which cooperates with the GUI's
MainActor renders. No additional serialization is added in M6 (the realtime path
is unchanged; the off-main Metal cache is independent). Thermal: long 4K exports
will throttle; `renderFPS` is reported as diagnostic, not a guarantee.

---

## 9. File plan

### NEW — `Sources/FlameKit/`
| File | Responsibility |
|---|---|
| `FramePlan.swift` | `FramePlan` + `FrameDescriptor` (§3.3). Pure; pre-materializes schedule walk. |
| `GenomeHealth.swift` | `Flame.isRenderable` MOVED from EmberweftUI (§3.2, D1). |
| `TemporalFilter.swift` | MOVED from FlameReference (§D4). Pure; `FilterShape` already in FlameKit. |

### MODIFIED — `Sources/FlameKit/`
(none beyond the above moves)

### DELETED — `Sources/EmberweftUI/GenomeHealth.swift`
Moved to FlameKit. Callers (`PlaybackView`, `ThumbnailService`, `LibraryIndex`,
`PlaybackViewModel`, `LibraryEntry`, `CollectionPlaybackView`) already
`import FlameKit`; the extension remains visible.

### MODIFIED — `Sources/FlameReference/`
| File | Change |
|---|---|
| `TemporalFilter.swift` | DELETED (moved to FlameKit). `ReferenceRenderer` + `AnimateCommand` get it via FlameKit (`FlameReference` re-exports FlameKit via `@_exported import`). |

### NEW — `Sources/FlameRenderer/`
| File | Responsibility |
|---|---|
| `ThreadSeedBudget.swift` | `MetalRenderer.ThreadSeedBudget` (§6, D7). |

### MODIFIED — `Sources/FlameRenderer/MetalRenderer.swift`
| Change |
|---|
| `renderFusedCore` + `renderTemporalFused` + the `@MainActor render(...)` entry points gain `threadSeeds: ThreadSeedBudget? = nil`; nil = today's behavior. Precondition on length. (§6) |

### NEW — `Sources/FlameExport/` (the bulk)
| File | Responsibility |
|---|---|
| `ExportSettings.swift` | `ExportSettings`, `ExportQuality`, `Resolution`, `Codec`, `Container`, `Bitrate` (§3.4). |
| `PixelBufferPool.swift` | `CVPixelBufferPool`-backed; RGBA->BGRA copy; cap 3 in-flight (§3.6, D9, D17). |
| `VideoEncoder.swift` | `AVAssetWriter`+Input+Adaptor; start/append/finish/cancel; poll isReady (§3.6, D12, D16). |
| `ExportCoordinator.swift` | `public actor`; run/runLongForm/runBatch/cancel; backend dispatch (§3.5, §4, D3, D15). |
| `ExportProgress.swift` | `ExportProgress`, `BatchProgress`, `ExportError` (§3.5). |

### NEW — `Sources/EmberweftCLI/`
| File | Responsibility |
|---|---|
| `ExportCommand.swift` | `emberweft export` (§10); mirrors `animate` args + codec/fps/resolution/bitrate/container/segment-frames/force; stderr progress; exit codes. |

### MODIFIED — `Sources/EmberweftCLI/`
| File | Change |
|---|---|
| `CLI.swift` | Add `case "export": return export(Array(args.dropFirst()))`; update `--help`. |
| `AnimateCommand.swift` | Refactor to build a `FramePlan` and loop `descriptor(for:)` (M6.1). Byte-identical (pinned by snapshot). Remove the now-shared logic (temporal sample build, blendAt). |
| `CurateCommand.swift` | Replace inline isRenderable replica (lines 155-167) with `flame.isRenderable`. |

### MODIFIED — `Package.swift`
| Change |
|---|
| `FlameExport` deps: add `"FlameReference"` (D2). |
| `EmberweftCLI` deps: add `"FlameExport"` (D2). |
| Add `.testTarget(name: "FlameExportTests", dependencies: ["FlameExport", "FlameKit", "FlameReference", "FlameRenderer"], path: "Tests/FlameExportTests")` (D2). |

### NEW — `Tests/`
| File | Coverage |
|---|---|
| `FlameKitTests/FramePlanTests.swift` | descriptor purity/O(1); temporal delta scaling; boundary correctness; animate-parity snapshot. |
| `FlameKitTests/GenomeHealthTests.swift` | isRenderable bounds (NaN center, scale<=0, out-of-band, zero-weight). |
| `FlameRendererTests/ThreadSeedBudgetTests.swift` | byte-identity (nil vs budget); parity suite green. |
| `FlameExportTests/PixelBufferPoolTests.swift` | RGBA->BGRA byte swap; premult; orientation; pool cap. |
| `FlameExportTests/VideoEncoderTests.swift` | synthetic frames -> mp4 -> AVAssetReader decode-back; cancel; overwrite guard. |
| `FlameExportTests/ExportCoordinatorTests.swift` | single/long-form/batch/cancel/determinism (cross-launch). |
| `EmberweftCLITests/ExportCommandTests.swift` | smoke (help, args, exit codes, stderr). |

---

## 10. CLI surface (`emberweft export`)

Mirrors `animate` (positional genomes + `--flag value`) and adds encode controls.

```
emberweft export <a.flam3> [<b.flam3> …] [options]
  --frames N            frames per segment (default 8)
  --segments N          segment count (default 3; 1 = loop-only; >1 needs >=2 genomes)
  --selector sequential|similarity
  --seed N              deterministic seed (default 0)
  --stagger F           transition stagger (default 0)
  --loop-cycles N       loop rotations (default 1)
  --temporal-samples N  motion blur (1 = sharp; default: genome value; Metal cap 64)
  --size WxH            override resolution (mutually exclusive with --resolution)
  --resolution 720p|1080p|1440p|4k
  --fps 24|25|30|48|50|60
  --codec h264|hevc     (default h264)
  --container mp4|mov   (default mp4)
  --bitrate auto|N      (mbps; default auto from codec/res/fps table)
  --quality genome|N                      (default genome; named tiers deferred)
  --segment-frames N    long-form chunk size in frames (default: no chunking)
  --backend cpu|metal   (default cpu; metal falls back to cpu if unavailable)
  --out FILE            destination (default out.mp4)
  --force               overwrite existing --out
  --frame N             render only global frame N (re-render/patch; implies --png)
  --png                 (with --frame N) write a PNG instead of a 1-frame video
  --jobs FILE           batch manifest JSON (array of per-job arg objects)
  --fail-fast           batch: abort on first failure
  --strict-backend      do not fall back to CPU if Metal unavailable
```

**Exit codes:** `0` success; `1` runtime error (parse, render, encode, disk); `2`
usage error (bad args, missing value, genome-count guard, fractional fps,
overwrite without `--force`). Progress to stderr: `[export] frame k/N  fps X  eta
Ys  sizeZMB` per frame (throttled to ~2 Hz like the GUI FPS readout, to avoid
swamping a piped stderr). `--help` notes the encoder-byte-instability caveat.

---

## 11. Slicing / build order (test-first, `main` stays green)

Each slice is shippable on its own branch and merges green. Engine-touching
slices (M6.1, M6.2) carry an explicit parity guard.

### M6.0 — Doc + scope housekeeping (no code)
- Mark `docs/export/export-pipeline.md` as SUPERSEDED by this spec (a one-line
  banner pointing here). Do not delete (owner's call).
- `[manual]` grep shows the banner.

### M6.1 — `FramePlan` + animate refactor + `isRenderable` move + `TemporalFilter` move
- Move `Flame.isRenderable` to FlameKit; delete EmberweftUI copy + CurateCommand replica.
- Move `TemporalFilter` to FlameKit.
- Add `FramePlan`/`FrameDescriptor` (FlameKit).
- Refactor `AnimateCommand` to use `FramePlan` (byte-identical).
- **Parity guards:** (a) `testAnimateFrameSnapshotUnchanged` — render the same
  genome+frame before/after the refactor, assert `RGBA8Image` equality;
  (b) full `FlameKitTests`/`FlameReferenceTests`/parity suite green.

### M6.2 — `threadSeeds` pass-in + `ThreadSeedBudget`
- Add `MetalRenderer.ThreadSeedBudget`; thread `threadSeeds:` through
  `renderFusedCore`/`renderTemporalFused`/the entry points.
- **Parity guards:** `testThreadSeedsNilVsBudgetByteIdentical` (single + temporal);
  full parity suite green.
- Realtime path passes nil (untouched).

### M6.3 — `PixelBufferPool` + `VideoEncoder`
- `PixelBufferPool` (RGBA->BGRA, premult, orientation, cap 3).
- `VideoEncoder` (start/append/finish/cancel; poll isReady; CMTime timing).
- Decode-back test via `AVAssetReader`.

### M6.4 — `ExportCoordinator` single export + `ExportCommand` + core DoD
- `ExportCoordinator.run` (single); `ExportCommand`; backend dispatch (D3).
- Disk precheck, overwrite/atomic-handoff, codec probe (D13, D14).
- The M6 core Definition of Done: `emberweft export a.flam3 --segments 1 --out
  /tmp/x.mp4` produces a playable upright mp4 whose frame K decodes to the same
  pixels as `animate --frame K` (at genome quality).

### M6.5 — Presets + resolutions + H.264/HEVC + bitrate
- `ExportQuality.preset`/`.spp`; `Resolution` tiers; HEVC path; bitrate table + `--bitrate`.
- HEVC availability fallback (D14).

### M6.6 — Long-form concat
- `runLongForm`; segment chunking; `AVMutableComposition` passthrough concat;
  temp cleanup; seam + duration tests (D10, D12).

### M6.7 — Batch
- `runBatch`; `--jobs` manifest; `--fail-fast`; cancel scope; aggregate progress (D11).

(GUI export sheet is a follow-up, NOT in this spec.)

---

## 12. Verification (strictly testable acceptance)

> Sandbox note: run tests with the bash sandbox **disabled**
> (`MTLCreateSystemDefaultDevice()` / AVFoundation return nil under it).
> Read `Executed N tests, with X failures` + exit code; ignore `error:` lines
> from CLI error-path tests.

### 12.1 M6.1 — `[automated]` FramePlan + refactor + moves
- `[automated]` `testFramePlanDescriptorIsPureAndO1`: `descriptor(for: k)` twice
  returns equal `FrameDescriptor` (blend/temporal/fromSheep/toSheep); calling
  with k then k-1 then k again is stable (no mutation of the plan).
- `[automated]` `testFramePlanTemporalDeltaScaling`: for N>1, `descriptor.temporal`
  deltas equal `TemporalFilter.samples(...).delta / framesPerSegment` (the
  load-bearing unit fix).
- `[automated]` `testFramePlanBoundaryMapping`: segmentId/blend/kind match
  `Schedule.frameToBlend` for a sweep of globalFrame across two segments.
- `[automated]` `testAnimateFrameSnapshotUnchanged`: render a fixed genome at
  `--frame 5` before (snapshot committed) and after the refactor; assert
  `RGBA8Image` byte-equal (decode the PNG via `RGBA8Image.readPNG`).
- `[automated]` `testFlameIsRenderableInFlameKit`: a NaN-center / scale<=0 /
  out-of-band / zero-weight flame returns false; a normal flame returns true
  (now callable from FlameKitTests without EmberweftUI).
- `[manual]` `git diff --name-only main` shows the moves + refactor; the parity
  suite (`make test-parity`) is green.

### 12.2 M6.2 — `[automated]` threadSeeds byte-identity + parity
- `[automated]` `testThreadSeedsNilVsBudgetByteIdentical` (single): render a real
  genome with `threadSeeds: nil` and with a `ThreadSeedBudget`; assert the two
  `RGBA8Image`s are byte-equal.
- `[automated]` `testThreadSeedsNilVsBudgetByteIdentical` (temporal, N=8): same,
  via the temporal path; per-frame byte-equal.
- `[automated]` `testThreadSeedBudgetLengthPrecondition`: a budget whose
  `single.count != tcFull * 16` triggers the precondition (does not silently
  mismatch).
- `[automated]` `testRealtimePathUntouched`: a realtime render (no budget arg)
  still matches its pre-M6.2 snapshot.
- `[manual]` full parity suite green.

### 12.3 M6.3 — `[automated]` PixelBufferPool + VideoEncoder
- `[automated]` `testRGBAToBGRASwap`: fill a CVPixelBuffer from a known
  `RGBA8Image` (e.g. R=10,G=20,B=30,A=255); lock the buffer; assert bytes are
  `[30,20,10,255]` (B,G,R,A).
- `[automated]` `testPremultipliedAlphaPreserved`: a pixel `(R=50,G=50,B=50,A=100)`
  (already premultiplied) round-trips to `[50,50,50,100]`; the premult invariant
  `R,G,B <= A` holds after swap.
- `[automated]` `testOrientationUpright`: render an asymmetric marker frame (a
  bright top row, dark bottom row); encode 1 frame; decode via `AVAssetReader`;
  assert the decoded top row is bright (no flip).
- `[automated]` `testPoolCapsInFlight`: acquire 3 buffers without releasing; a
  4th `acquire()` does not return until one is `release()`d (cooperative).
- `[automated]` `testEncoderDecodeBack`: append 10 synthetic gradient frames ->
  mp4 -> `AVAssetReader` decode -> assert 10 frames, correct fps, correct
  resolution.
- `[automated]` `testEncoderCancelDeletesPartial`: start, append 2 frames,
  `cancel()`; the output file does not exist (partial deleted).

### 12.4 M6.4 — `[automated]` ExportCoordinator single + CLI
- `[automated]` `testExportFramePixelIdentity` (rule-#2 pin): two independent
  coordinator runs on identical inputs; assert per-frame `RGBA8Image` equality.
- `[automated]` `testExportCrossLaunchDeterminism`: run the export in-process
  twice (simulating fresh hash seed) writing a downsampled pixel hash to a temp
  file; compare the two files (equal).
- `[automated]` `testExportMatchesAnimateFrame`: `export --frame 5 --png` vs
  `animate --frame 5`; byte-equal `RGBA8Image` (at `ExportQuality.genome`).
- `[automated]` `testExportOverwriteGuard`: `--out` exists, no `--force` -> exit
  2, existing file untouched.
- `[automated]` `testExportAtomicHandoff`: force a mid-encode failure (inject a
  bad writer); the `<out>.partial-*` is deleted and `<out>` is unchanged.
- `[automated]` `testExportMetalFallsBackToCpu`: `--backend metal` on a
  no-Metal box (test env) falls back to CPU with a stderr notice (or exits 1
  with `--strict-backend`).
- `[automated]` `testExportDegenerateGenomeSkipped`: a NaN-center genome is
  skipped with a warning (single: exit 1; batch: recorded).
- `[manual]` `emberweft export genomes/.../244_00788.flam3 --segments 1 --out
  /tmp/m6.mp4` -> plays upright in QuickTime; frame 0 matches the PNG render.

### 12.5 M6.5 — `[automated]` presets + resolutions + HEVC
- `[automated]` `testExportQualityGenomeMatchesAnimate`: at `.genome`, export
  frame K == animate frame K (byte-equal); at `.spp(N)` (any N) the export is
  deterministic and byte-stable across runs (oversample stays 1, so still
  byte-identical to `animate --quality N`).
- `[automated]` `testResolutionTiers`: 720p/1080p/1440p/4k each produce the
  correct decoded dimensions.
- `[automated]` `testHEVCFallbackOrError`: on a machine without HEVC encode,
  `--codec hevc` errors (exit 1) or falls back to H.264 (default-codec case)
  with a notice. (Test SKIPS with a clear message on machines that DO support
  HEVC, so it does not flake.)
- `[manual]` inspect bitrate/quality at each preset on a real loop.

### 12.6 M6.6 — `[automated]` long-form concat
- `[automated]` `testLongFormDuration`: 3 chunks of N segments each; decoded
  final duration == sum of chunk durations (no gap/overlap).
- `[automated]` `testLongFormSeamContinuity`: decoded frame at each splice ==
  the standalone chunk's boundary frame (no dup/drop/black).
- `[automated]` `testLongFormTempsCleaned`: after success AND after cancel AND
  after a forced failure, no `*.mov` remains in the temp dir for the run.
- `[manual]` render a long loop+transition and scrub the splice in QuickTime.

### 12.7 M6.7 — `[automated]` batch
- `[automated]` `testBatchRunsInOrder`: 3 jobs; assert execution order == input
  order; outputs exist for all.
- `[automated]` `testBatchContinuesOnFailure`: job 1 fails (bad genome); jobs
  2,3 still run; exit code 1; failure recorded.
- `[automated]` `testBatchFailFast`: job 1 fails with `--fail-fast`; jobs 2,3
  do NOT run; exit code 1.
- `[automated]` `testBatchCancelStopsRemaining`: cancel during job 1; job 1
  partial deleted; jobs 2,3 do not start.
- `[manual]` `emberweft export --jobs batch.json --out /tmp/batch/` -> all
  outputs present and playable.

### 12.8 M6 Definition of Done
Each `[manual]`, observed in a clean CLI run with the bash sandbox off:
- `emberweft export <one genome> --segments 1 --out x.mp4` produces an upright,
  playable H.264 mp4 whose frame K decodes to the same pixels as
  `animate --frame K` (at `.genome` quality). [core]
- Codecs H.264 + HEVC both selectable; HEVC falls back on unsupported hardware.
- Resolutions 720p/1080p/1440p/4k all produce correct dimensions.
- Long-form: a multi-segment export concatenates cleanly at segment boundaries.
- Batch: `--jobs` runs serially with continue/fail-fast semantics.
- Cancel (Ctrl-C / signal) cleans partials and temps.
- `animate` -> PNG is unchanged and remains the byte-exact mastering path.
- Encoder-byte-instability caveat documented in `--help`.
- All `[automated]` tests green; parity suite green; no unintended engine edit
  (`git diff --name-only main | grep -E 'Sources/(FlameKit|FlameReference|FlameRenderer)/'`
  shows only the M6.1/M6.2 sanctioned changes).

---

## 13. Risks & mitigations

| Risk | Likelihood/Impact | Mitigation |
|---|---|---|
| FramePlan refactor breaks animate byte-identity | Med / High | M6.1 snapshot test (§12.1) red-then-green; full parity suite gate. |
| threadSeeds pass-in breaks Metal determinism | Low / High | byte-identity test nil-vs-budget (§12.2); budget length precondition; parity suite. |
| RGBA->BGRA / orientation bug (flipped or color-swapped video) | Med / High | byte-swap + premult + orientation tests (§12.3); decode-back via AVAssetReader. |
| Encoder backpressure deadlock / black frames | Med / Med | poll isReady + yield; adaptor pool cap 3 (D16); decode-back test. |
| AVAssetWriter fails silently if file exists | High / Med | overwrite guard + atomic partial handoff (D13). |
| HEVC unavailable on target machine | Med / Med | probe + explicit-error/default-fallback (D14). |
| Long-form splice artifact (dup/drop/black frame) | Med / Med | segment-edge chunking + passthrough concat + seam/duration tests (D10, §12.6). |
| Temp segment leak on crash | Low / Med | defer/finally cleanup registered at creation (D12). |
| Memory exhaustion at 4K + high spp | Med / High | pool cap 3; shared threadSeeds budget; memory ceiling note (D17). |
| Batch one bad genome aborts everything | Med / Med | continue-by-default + `--fail-fast` opt-in (D11). |
| Path traversal / clobber via `--jobs` manifest | Low / High | sanitize + base-dir resolution + `--force` (D13). |
| Encoder bytes non-deterministic across machines | Certain / Low | documented caveat; animate->PNG for byte-exact mastering (§5.3). |
| Moving TemporalFilter / isRenderable breaks a call site | Low / Low | moves are pure; FlameReference re-exports FlameKit; tests cover both. |

---

## 14. Constraints honored (CLAUDE.md)

- **Reference-then-Optimize / parity:** CPU is the oracle; M6 reuses
  `ReferenceRenderer`/`MetalRenderer`/`Loop`/`Transition`/`Schedule` verbatim.
  The only engine changes are `FramePlan` (pure extraction), `TemporalFilter` +
  `isRenderable` moves (mechanical), and the `threadSeeds:` optional (byte-
  identical, parity-guarded). M6 does not add Metal behavior unmatched by CPU.
- **Determinism (rule #2):** no float sums over Dict/Set; FramePlan is pure
  value-type + `@Sendable`; threadSeeds is a pure function of `(seed,
  threadCount)`; manifest/keys sorted; tests pin cross-launch determinism.
- **No external deps:** AVFoundation, CoreMedia, CoreVideo, CoreGraphics,
  Foundation, Metal. No new packages.
- **Swift 6 strict concurrency:** `ExportCoordinator` is an actor; blocking
  render offloaded via `MainActor.run`/`Task.detached`; `PixelBufferPool`/
  `VideoEncoder` are `@unchecked Sendable` with a single internal queue (the
  honest escape, used as `MetalOffMainCache` is); `FrameDescriptor.blendAt` is
  `@Sendable`; no `nonisolated(unsafe)` added beyond the documented
  `@unchecked Sendable` + queue-serialized classes.
- **Test-first:** every slice's tests are written red before green (§12).
- **macOS 26 / Apple Silicon / Metal 4; bash sandbox off for tests.**
- **Orientation gotcha:** export uses the top-first `RGBA8Image.pixels` directly
  into a top-first CVPixelBuffer (no flip); `FlameUI.makeCGImage` (the flipping
  path) is never touched. Pinned by the orientation test.
- **Real ES genome data-integrity:** `Flame.isRenderable` (now in FlameKit)
  gates NaN/degenerate genomes in the export path (D1).
- **Metal threadSeeds host-side:** the acceleration caches them, byte-identical
  (§6).

---

## 15. Deferred / out of scope

- **GUI export sheet + progress window** (follow-up slice; the engine is
  GUI-drivable via `AsyncThrowingStream`).
- **Zero-copy IOSurface GPU -> encoder.** Deferred because both renderers
  terminate in `memcpy` from `.storageModeShared` MTLBuffer -> `[UInt8]`
  (verified); there is no IOSurface/CVPixelBuffer/MTLTexture-from-IOSurface path
  to hand the encoder. Building one is an engine-layer change requiring a new
  Metal readback path and a parity re-proof. The `kCVPixelBufferMetalCompatibilityKey`
  is set on the pool today so the future path is unblocked.
- **Audio muxing** (M7).
- **HDR / 10-bit / ProRes / AV1 / lossless** (M8).
- **Realtime capture** (capturing a live playback session to disk).
- **Resume / checkpoint** a canceled long-form export (BGProcessingTask-style).
- **Per-frame PNG sidecar** during video export (use `animate` for that).
