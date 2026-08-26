# Changelog

All notable changes to Emberweft are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Emberweft is **source-available** (PolyForm Noncommercial). The CPU renderer is a
faithful Swift port of the flam3 algorithm; the final license (including any GPL
implications of porting flam3) is the owner's decision and under review.

## [Unreleased]

### Added
- Orientation-aware framing (`FlameKit.Framing.apply`): portrait canvases rotate landscape-authored genomes +90° and anchor the authored height, so every genome keeps its authored composition sideways; portrait- and square-authored genomes are never rotated.

## [0.6.1] - 2026-08-18

Framing at last: every genome now keeps its authored composition at every
output resolution, from the archive to the export sheet to the library
thumbnail and the playback preview. This release also fixes the GUI crash
when generating into any non-1080p shard, and rebuilds the context menus on
a native AppKit bridge so they no longer vanish mid-use.

### Added
- **Resolution-independent framing (M6.6).** A genome's `scale` is absolute
  pixels-per-unit authored for its own canvas, so changing the output
  resolution used to change the composition (720p "zoomed in", 4K "zoomed
  out"). Framing now re-anchors `scale` to the output WIDTH (the ES gen-248
  authoring anchor: scale/width agrees to 2% across the archive's three
  authored-size populations, while scale/height differs by 34%) via a
  multiplicative correction, the perceptually correct (log-scale) form. New
  `--framing faithful|normalized` on `export` (including the batch
  `--jobs` path) and `flock generate|stitch` (default `normalized`;
  `--framing faithful` restores the raw scale), a Framing picker
  (Normalized default / Authored) in the GUI export sheet, and an
  `emberweft.framing` video tag + exact catalog hit-gate so a stitched
  archive can never mix framing modes (legacy v0.6.0 artifacts re-render on
  the next generate/stitch). `animate` and the renderers are unchanged
  (always faithful); animate-to-export byte-identity pins stay green.
- **Normalized framing in the library and previews.** Thumbnails and both
  playback windows (single-genome and collection sequence) now frame exactly
  like an export at any resolution; the thumbnail cache carries a generation
  marker so pre-0.6.1 caches re-render once.

### Fixed
- **GUI crash when generating into a non-1080p shard** (v0.6.0): the encoder
  sized its pixel-buffer pool from the export settings' default resolution
  while frames rendered at the shard's dimensions, trapping on any shard
  other than 1080p. The archive render path now force-aligns the encoder
  resolution to the shard (and the encoded dimensions were wrong-by-luck for
  1080p before).
- **Context menus vanishing before a click landed.** The grid/list context
  menus (library cells, collection cells, folder and collection rows, flock
  browse rows) moved from SwiftUI `.contextMenu` to a native AppKit
  responder-chain menu: SwiftUI tore the old sessions down on cell
  re-renders (a thumbnail finishing its load, a facet or badge publish),
  worst on the multi-level Add to Collection submenu. Menus are now built as
  a snapshot at right-click time and cannot dismiss or mutate mid-session;
  destructive items are styled in the system red, and left-click behavior
  (taps, buttons, drag-reorder) is unchanged.

## [0.6.0] - 2026-08-16

The flock archive: pre-render your loops and edges once, then compose long
videos from them in seconds. This release solves the long-export problem (a
5-genome sequence at genome-default quality took over 3 hours as a one-shot
export; the same sequence stitched from cached material is a lossless remux).
It also ships the app as a proper double-clickable macOS app bundle with an
icon, and moves one-shot export out of the playback windows.

### Added
- **The flock archive** (new `FlameFlock` module). A user-configurable directory
  (default `<app-support>/Flock/`, set in Settings) holding pre-rendered loop
  and edge videos, organized into shards by resolution, frame rate, and pace.
  Standard shards (720p / 1080p / 1440p / 4K, 30 fps, 15 s loops, 12 s edges)
  are one click away; custom paces create their own shard. Naming is
  ES-inspired: `<a_gen>=<a_id>=<b_gen>=<b_id>.mov`, where a loop is the
  self-edge, the ordered pair is the key, and cross-generation edges are
  first-class. ES-sourced sheep keep their real generation and id; user genomes
  get stable ids in a reserved flock. The archive self-improves: re-rendering a
  segment at higher quality overwrites the lower one, never duplicates it.
- **Two paths.** *Generate* pre-bakes loops and/or edges into a shard (edges
  only by default; loops plus edges or loops only via the scope picker), in
  timeline order matching your collection. *Stitch* composes a long video from
  the archive: cached segments are reused as files, missing ones are rendered
  into the archive first, then everything is concatenated with a no-reencode
  passthrough remux. Stitch picks its quality (a stored lower-quality segment
  is upgraded, not treated as a hit) and how many times each loop plays
  (default 2, a stitch-time timeline choice that costs no extra rendering).
- **The Flock workspace in the app** (Generate / Stitch / Browse tabs), sourced
  from your library: Favorites, any collection, or the current selection. No
  file pickers. Live progress everywhere: per-video frame counters, ETA, a
  concatenating phase, a running indicator in the sidebar visible from any
  pane, and a Cancel that takes effect within about two frames and shows a
  Cancelling state while it lands. Browse shows per-shard counts, sizes, and
  thumbnails; the catalog rebuilds from files plus embedded tags if lost.
- **A real Mac app.** `make dist` now produces `Emberweft.app`: double-click it
  (or `open dist/Emberweft.app`) and it launches directly, with no Terminal
  window hosting it. It carries a designed app icon (a ring braided from three
  ember threads; deterministic generator and rationale under `Tools/AppIcon/`).
- **The `emberweft flock` CLI:** `generate | stitch | browse | rebuild |
  export-list`, including the ES `<list>` XML interchange export for ES-sourced
  pairs (real edge ids recovered from the genome archive's pair database).
- **Collection creation.** New Collection in the Add-to-Collection menu, the
  sidebar, and the selection bar: create a collection and add the selection in
  one step, or start an empty one.
- **Export quality default in Settings** (Genome default / Low / Medium /
  High). The export sheet opens at the configured tier; an in-sheet change
  affects that run only.

### Changed
- One-shot export is a library-selection action. The playback windows are
  play-only.
- Archive renders default to Standard quality (samples-per-pixel 30 with the
  tier's temporal samples and smoothing), with a picker for genome-default
  mastering.
- Generation runs in timeline order (loop, edge, loop), matching the collection,
  so a partial generate covers the earliest part of the timeline first.

### Fixed
- **Stitch seams.** Segment boundaries could jump (measured up to 36x the
  normal frame-to-frame difference; the smoothing window clipped at each
  file's edges). Artifact geometry now keeps every boundary frame's window
  inside its own unit: loops ship a core plus a wrap file (a loop's neighbor is
  itself), edges render with neighbor context baked in. Seams now measure at
  the inline one-shot reference (1 to 3x).
- **Generation speed.** Archive renders were using the genome's temporal
  samples (~1000) instead of the chosen tier's, wasting the bulk of the
  compute. Fixed; generation at Standard is dramatically faster.
- **ES identity.** ES-sourced genomes were being minted into the reserved
  flock (wrong filenames); they now keep their real generation and id.
- **Cancel.** Cancelling waited for the current unit to finish (minutes at
  high quality), and could leave the UI stuck on Cancelling. Cancel now
  propagates to the in-flight render (about two frames) and the terminal
  state always lands. No leftover processes, temp files, or catalog rows.
- **Progress.** Generate showed nothing during a long first unit and Stitch
  showed nothing during regeneration; both now report per-frame progress,
  ETA, and every phase. The Cancel button was not visible while running.

### Notes
- Archive codec: HEVC Main10 in `.mov`, chosen empirically (about 40% smaller
  than H.264 at equal quality, 10-bit, hardware encode). Each segment is a
  fresh independent encode; never slice segments from a longer render.
- Engine parity is untouched (no renderer math changed), and the
  animate-to-export byte-identity pins stay green. The archive's determinism
  is frame/seed-level: same shard, key, and settings produce the same frames;
  the `.mov` container itself is not byte-stable run to run.
- The M5 screensaver (next) consumes this archive: play pre-rendered loops
  and edges instead of live-rendering.

## [v0.5.7] — remove loop-repeat (fix jerky half-speed motion)

Removes the loop render-once-repeat feature (v0.5.0) entirely. The feature
rendered each loop frame once and appended it multiple times as identical bytes
(the default repeat count was 2), which caused the loop's motion to play at half
speed: a 30 fps container showed 15 fps of real motion. Every frame is now
rendered and appended exactly once.

### Removed
- **`loopRepeatCount`** field from `ExportJob`, `ExportCheckpoint`, and
  `ExportManager`. The GUI "Loop repeat" stepper, the CLI `--loop-repeat` flag,
  and the `loopRepeatMemoryExceeded` RAM guard are all gone.
- The repeat-greater-than-one cache-and-replay branch in
  `ExportCoordinator.renderFrames` is deleted. Each loop and transition frame is
  rendered once and appended once.

### Backward compatibility
- A v0.5.6 export checkpoint (which carries a `loopRepeatCount` key) still
  decodes on v0.5.7. Swift keyed decoding ignores unknown keys, so resume works
  across the version boundary.
- Determinism (rule #2), Metal-to-CPU parity, and animate-to-export
  byte-identity are all preserved. Loop-repeat was an output-stage optimization;
  removing it does not touch the renderer math. The mastering path
  (`--frame N --png`, `animate`) never used loop-repeat.

## [v0.5.5] — quality tier auto-sets temporal samples

Picking a quality tier in the export sheet now automatically sets temporal-samples
to its most-appropriate value (data-derived: motion blur that's free at the tier's
spp). The user can still override the stepper after.

### Added
- **Quality tier → temporal-samples auto-set.** Draft → 1 (single-pass, fastest),
  Standard → 4 (free mild blur at spp 30), High → 16 (free moderate blur at
  spp 100), Genome-default → 1 (= "use genome default", the mastering path).
  Picking a tier sets the ts stepper via `ExportQualityChoice.recommendedTemporalSamples`;
  the user can override.

### Notes
- Complements v0.5.4 (named tiers default to single-pass at ts=1) by making each
  tier proactively set its best ts. ts is motion blur, not grain (grain scales with
  samples-per-pixel). Genome-default is unchanged (byte-identical to `animate`).

## [v0.5.4] — temporal-samples default fix (faster low-quality exports)

Fixes a temporal-samples default that made the named quality tiers slower than
necessary. Draft/Standard/High now default to single-pass rendering instead of
inheriting the genome's temporal-samples (up to 1000, Metal-capped 64), which was
wasteful at low samples-per-pixel.

### Changed
- **Named tiers default to single-pass temporal samples.** The "use genome default"
  fallback for temporal-samples=1 now applies only to genome-default quality (the
  mastering path, byte-identical to `animate`). For the named tiers (`.spp`),
  temporal-samples=1 is literal single-pass. This eliminates the dispatch overhead
  of ~64 sub-passes at low spp (measured +136% at spp 8, +35% at spp 30) for
  within-frame motion blur that's invisible on slow ambient loops. Users can still
  raise temporal-samples explicitly for motion blur.
- The export sheet's temporal-samples label now reflects this ("single-pass" for
  named tiers at ts=1, "genome default" for genome-default).

### Notes
- Genome-default quality is unchanged (temporal-samples resolves to the genome's
  value; byte-identical to `animate`). animate/export byte-identity and Metal/CPU
  parity are preserved.
- Temporal samples is motion blur, not grain; it doesn't affect the noise level
  (grain scales with samples-per-pixel, not temporal-samples).

## [v0.5.3] — export quality-tier retune (cleaner low/mid/high)

Retunes the export quality tiers and makes the temporal-smoothing window uniform,
based on an empirical grain + performance sweep. Low/Medium/High exports are now
substantially cleaner for modest extra render time; the Standard tier reaches
~genome-default cleanliness at ~33× the speed.

### Changed
- **Quality tiers raised:** Draft/Standard/High now map to **spp 8 / 30 / 100**
  (was 2 / 8 / 30). The old values were inherited from the realtime preview
  presets and under-sampled for export (grainy). Effective spp (after smoothing):
  Draft ≈ 88, Standard ≈ 330 (≈ genome-default clean), High ≈ 1100 (cleaner than
  genome-default).
- **Uniform smoothing window:** the centered-box-window half-width is now **h = 5**
  (an 11-frame window) for all smoothing-on tiers — the α that derives h is flat
  (0.2 ⇒ round(1/0.2)=5), replacing the continuous ramp that gave tier-dependent
  h (10/5/3) and clamped to OFF at spp ≥ 64 (which would have disabled smoothing
  for the new High, spp 100). Temporal smoothing is free supersampling (one render
  per frame regardless of h), so uniform h=5 gives the max grain reduction within
  moderate motion blur.
- The export sheet label now shows the **effective spp** (the quality after
  smoothing), not the vestigial α.

### Notes
- Genome-default quality is unchanged (smoothing OFF; byte-identical to `animate`).
  animate↔export byte-identity and Metal↔CPU parity are preserved.

## [v0.5.2] — M6.1 slice 2: temporal smoothing

Low-spp exports (Low / Medium / High quality) no longer flicker — the "tiny dots
moving around" trajectory-divergence flicker is gone, smoothed from the very first
frame. A centered (non-causal) box window is applied over per-frame histograms
before the display pipeline. Engine parity and the animate/export mastering path
are unchanged (byte-identical); the feature is export-only.

### Added
- **Temporal smoothing (export) — centered box window.** Per output frame, the
  histogram is the average over a centered window `[m−h, m+h]` (half-width
  `h = round(1/α)`: Low→10 / Med→5 / High→3), then density-estimation + log-density
  + tone-map run once. Centered (not a causal EMA) so it smooths from frame 1 with
  no startup ramp and no temporal lag; box weights give the minimum-variance
  estimate for the per-frame Monte-Carlo noise (max flicker kill). Genome-default,
  spp ≥ 64, and the single-frame mastering path are untouched (`h == 0` ⇒ OFF), so
  every animate/export byte-identity pin stays green. Export-only.
- **Metal via fused-chaos + atomicBuf readback** — the smoothing path reuses the
  fused chaos pass, reads the atomic histogram buffer back, host-decodes it, windows
  it, and runs DE + display off-main. No new Metal shader; the existing fused cores
  and the realtime/thumbnail paths are byte-unchanged (additive variants only).
- **Per-chunk window with h-frame margins** — each export chunk uses a fresh window
  fed an extended range (lookback + lookahead), so chunks are self-contained. Resume
  is trivial (re-render the chunk + margins); resumed exports are byte-identical to
  never-paused ones.
- **GUI toggle + CLI flag** — a "Temporal smoothing" checkbox in the export sheet
  (auto on at the named tiers, off at genome-default) with a resolved-α label, and
  a `--temporal-smoothing on|off` CLI recipe flag.

### Changed
- `ExportSettings` gains `temporalSmoothing` + a resolved `smoothingAlpha` (rides
  in the checkpoint via `settings`; v0.5.1 checkpoints decode via `decodeIfPresent`).
- `ReferenceRenderer` is split to expose a pre-DE `histogram(...)`; `render(...)`
  is byte-identical.
- `DensityEstimationMetal` / `DisplayPipelineMetal` gain `nonisolated *Core`
  functions so DE + display run off-main for the smoothing display step.

### Fixed
- **Early-pause resume** — pausing before the first checkpoint interval completed
  left no checkpoint on disk (the per-chunk write fires only after a chunk
  completes), so resume failed with "checkpoint unreadable". An initial checkpoint
  is now written at the start of the run, so an early pause (e.g. mid-first-chunk)
  is always resumable (resume re-renders the partial first chunk).

### Known limitations
- Smoothing-ON peak memory is `2h+1` Double histograms (~1.7 GB at 1080p for h=10,
  ~7 GB at 4K); a RAM guard is pending. A transition between genomes with different
  spatial-filter radii (different grid dimensions) throws a graceful
  `ExportError.smoothingGridMismatch` (uniform-filter genomes are unaffected).

## [v0.5.1] — M6.1 export pause/resume

Long GUI exports (a multi-day, genome-default sequence) are now pausable and
resumable without losing rendered work, plus crash recovery. Engine parity is
unchanged (no renderer math touched; the resume pixel-identity pins hold).

### Added
- **Export pause/resume + crash recovery** — `ExportCoordinator.runResumable`
  chunks the timeline at frame-count edges (default 30), encodes each chunk via
  a new `renderFramesInterleaved` loop, writes an `ExportCheckpoint` after each
  chunk, and passthrough-concats on completion. Pause keeps the checkpoint +
  completed chunks; Resume rebuilds the identical plan + budget and re-parses
  SHA-256-verified source bytes, so resumed frames are byte-identical (rule #2).
  A checkpoint left by a quit/crash is resumable at the next launch (a
  remembered-checkpoint URL in `AppPreferences` synthesizes a `.paused` card).
- **`renderFramesInterleaved`** — a per-global-frame render loop for the
  resumable path, byte-identical to the existing `renderFrames` (decides
  repeat-count per frame, so frame-count chunks can span a loop→transition
  boundary). Renders each frame once (loop-repeat speedup preserved), O(1)
  memory. The existing `renderFrames` is unchanged.
- **GUI Pause/Resume/Discard** — the progress banner gains a Pause button
  (gated on an `isPausable` flag) and a paused card (Resume/Discard).
  Recoverable failures (disk-full) surface as `.paused(reason:)` with a Resume
  offer rather than a terminal failure.
- **CLI `--checkpoint-frames` / `--resume` / `--discard`** — checkpointed CLI
  runs; SIGINT keeps the checkpoint (the existing `DispatchSourceSignal`
  pattern) so `--resume` is real crash recovery. `--resume` enforces the
  checkpoint recipe as authoritative (conflicting flags error).

### Changed
- `runResumable(_:sources:checkpointIntervalFrames:resumeFrom:)` takes
  file-backed `sources` so the checkpoint uses the URL+SHA-256 primary path
  (re-reads exact source bytes on resume); the serialized-text fallback covers
  URL-less flames.

### Deferred to M6.1 slice 2
- **Temporal smoothing** (across-frame histogram EMA for low-spp quality).

## [v0.5.0] — M6 GUI export (the video-export studio)

The export feature is complete: a full GUI export studio plus mastering-quality
encoding and a refined, calmer animation pacing. The headless `emberweft
export` CLI gains the same settings. Engine parity is unchanged (no renderer
math changed; the export↔animate byte-identity pins hold).

### Added
- **GUI export studio** — an `ExportManager` (`@MainActor @Observable` VM in
  `EmberweftUI`, held by `AppModel`) drives `ExportCoordinator` off-main (Metal
  via a new byte-identical `renderTemporalOffMain`, so motion-blurred exports
  never freeze the UI). Three sources: single genome, collection-as-sequence,
  multi-select batch. `NSSavePanel`/`NSOpenPanel` destination; a non-blocking
  progress banner in all window types (Cancel + Show-in-Finder); `ProcessInfo`
  sleep prevention; and an ETA (EMA-smoothed, "estimating…" cold-start).
- **ProRes 422 HQ mastering default** — intra-frame, so no smearing on busy
  fractal content; visually lossless; `.mov` (guarded). H.264/HEVC tiers raised
  (~5× bitrate, High/Main10 profile, 1-sec GOP) for the `.mp4` alternatives.
- **Off-main temporal Metal** — `renderTemporalOffMain` (the temporal twin of
  `renderOffMain`), byte-identical to the `@MainActor` path; the coordinator's
  `useOffMainMetal` flag (CLI path unchanged). Pinned by `OffMainTemporalParityTests`.
- **Separate loop/transition durations** — `Schedule` carries
  `transitionFramesPerSegment` (O(1) pair-math `frameToBlend`); loops and edges
  can differ. Defaults 15 s loop / 12 s edge (the ES gen-248 edge mode +
  motion-perception research).
- **Loop render-once-repeat** — each loop renders once and outputs N× (default
  2 → 30 s perceived at 15 s render cost; seamless); a RAM guard refuses
  oversized caches (a disk-cache follow-up for 4K). Transitions never repeat.
- **Transition rotation velocity-matched easing** — the transition's rotation
  eases so its velocity matches the adjacent loops at the boundaries (no
  boundary jerk), enabling short edges with smooth joins. The realtime preview
  matches the export.
- **Shared `ExportSettings.resolve(…)`** — pure + silent; CLI and GUI build
  byte-identical jobs. The `ExportCoordinating` protocol seam (testability);
  `ExportQualityChoice` (Genome default + Low/Med/High, oversample pinned 1).

### Changed
- **Animation is no longer flam3-parity-bound** (owner decision): Emberweft may
  improve on flam3's motion (the rotation easing, the pacing). The vs-flam3
  transition parity pin is `XCTSkip`'d (loop parity still in force). Renderer
  faithfulness, determinism (rule #2), and Metal↔CPU parity are unchanged.
- CLI `export` adds `--codec prores-422-hq`, `--loop-repeat`, `--transition-frames`.

### Fixed
- Sequence export no longer truncates the timeline (`segmentCount` was
  `flames.count`; now `2N−1` to cover every genome's loop + the transitions).
- Batch output now carries the container extension (`<stem>.mp4`).
- Silent `isRenderable` skips are surfaced in the banner.

### Deferred to M6.1
- **Pause/resume** (frame-count checkpointing + chunked-encode + concat) and
  **temporal smoothing** (across-frame histogram EMA for low-spp quality).

## [v0.4.0] — M6 export pipeline (video export)

The `emberweft export` command: render flame animations directly to MP4/MOV
(H.264 + HEVC) via AVFoundation, with progress, cancellation, long-form
segment+concat, and batch. It reuses the proven CPU/Metal renderers through a
pure `FramePlan`; only the sink changes (PNG writer -> AVAssetWriter). Frame
pixels are byte-identical to `animate` (pinned for sharp and motion-blurred
genomes); the encoded file is not byte-stable across machines, so `animate` to
PNG remains the byte-exact mastering path. Engine parity is unchanged. **The GUI
export sheet + progress UI (the roadmap M6 DoD's progress-UI items) is a
follow-up slice, not in this release.**

### Added
- **`emberweft export`** — drives the deterministic renderers through a pure
  `FramePlan` and encodes to video via `AVAssetWriter`: `--codec h264|hevc`,
  `--resolution 720p|1080p|1440p|4k`, `--fps`, `--quality genome|N`,
  `--temporal-samples`, `--bitrate`, `--container`, `--segment-frames`
  (long-form), `--jobs` (batch) + `--fail-fast`, `--frame N --png`
  (byte-exact single-frame mastering), `--force`, `--strict-backend`.
- **`FramePlan` / `FrameDescriptor` (FlameKit)** — pure extraction of
  `animate`'s per-frame recipe; `animate` refactored to use it (byte-identical).
- **`MetalRenderer.ThreadSeedBudget`** — memoizes the Metal per-thread ISAAC
  seeds so an export computes them once instead of per frame (byte-identical;
  realtime untouched).
- **`ExportCoordinator` (FlameExport, actor)** — off-main render + encode with
  progress, cooperative cancel, atomic partial-to-final handoff, disk precheck,
  HEVC-availability fallback, and a degenerate-genome gate.
- **Long-form** segment+concat (`AVMutableComposition` passthrough; temps
  cleaned on every exit path) and **batch** (serial; continue or `--fail-fast`;
  path-sanitized manifest).

### Changed
- `Flame.isRenderable` and `TemporalFilter` moved down to FlameKit (pure; one
  shared definition for CLI, export, and GUI).
- `EmberweftCLI.run` is now `@MainActor async` (and `main.swift` awaits it) so
  `export` can drive the coordinator without blocking the main actor.

### Fixed
- Export frames are byte-identical to `animate --frame N` for motion-blurred
  (`temporal_samples` > 1) genomes, not just sharp ones: `export` now honors the
  genome's default `temporal_samples`, matching `animate`.

## [v0.3.2] — Settings clarity, per-parameter help, and a `dist` target

Post-v0.3.1 polish on the GUI studio and build. The engine is unchanged.

### Added
- **Distinct preview vs. export quality in Settings.** The macOS Settings window
  now separates the two quality notions, which serve different purposes:
  **Preview quality** (`PreviewPreset`, realtime, tuned for fluid FPS) and
  **Export quality** (`QualityPreset`, maximum quality for exported renders,
  staged for the upcoming export feature). Grouped into Playback / Export /
  Thumbnails / Library sections. Target FPS in Settings now offers
  24/30/60/90/120 to match the playback popover (it previously offered only
  24/30/60, so 90/120 set via the popover showed no selection).
- **Per-parameter help.** Every quality/performance control in the playback
  popover and Settings has a tooltip explaining what it does and its
  performance/quality tradeoff (samples/pixel scales cost roughly linearly,
  oversample scales with the square, resolution scales with pixel count), plus an
  actionable footer tying the knobs to the live FPS readout.
- **`make dist` target.** Builds a release (optimized) product into `./dist`
  (the GUI + CLI + their two resource bundles) and prints the run command.
  `dist/` is gitignored; it is reproducible from source via this target.

### Changed
- **Preview-quality picker trimmed.** Settings offers Draft/Balanced/Quality
  only; "Custom" is no longer a selectable entry (it has no defined values and
  is reached by tuning in the playback popover). When the live preset is Custom,
  Settings shows the actual values read-only (e.g. "Custom — 1080p · 12 spp ·
  2×").

### Fixed
- **`⌘,` shortcut collision.** The preview-quality popover was bound to `⌘,`,
  the macOS Settings shortcut (auto-bound by the `Settings` scene), so `⌘,` did
  different things depending on which window was key. Removed; the popover is
  reachable via its toolbar button.

## [v0.3.1] — M4 polish: preview presets + live FPS, and a determinism-gate fix

Two follow-ups to the v0.3.0 GUI studio.

### Added
- **Configurable preview presets + live FPS readout.** Both playback windows
  (single-genome and collection sequence) now show a live FPS readout in the
  transport bar and a preview-quality popover (`⌘,`). Three named presets —
  **Draft** (480p · 2 spp), **Balanced** (720p · 8 spp), **Quality**
  (1080p · 16 spp · 2×) — snap quality in one click; advanced steppers/menus
  (resolution tier, samples/pixel, oversample, target frame rate, backend) tune
  further, forking to a **Custom** preset that's flagged with a dot on the
  trigger. The FPS readout is target-relative (green/amber/red vs your chosen
  target, with an absolute 24 fps cinematic floor) and throttle-smoothed (~2 Hz)
  so the digit settles rather than twitches; it shows an em dash while paused or
  loading, never a misleading "0 fps". `Reset to Default` recalls Draft. Default
  Draft is byte-identical to the pre-preset preview, so existing preferences are
  unchanged on upgrade.

### Fixed
- **`testFiniteDeterministicRenders` crash** (pre-existing on `main`, now green).
  The `cell` variation computed `Int(1.0/cell_size)` and `GenomeGen` generates
  `cell` with the default `cell_size=0`, so `Int(Inf)` trapped in Swift (flam3's
  C `(int)floor(Inf)` is UB but nontrapping). Added a nontrapping `intTrunc`
  guard (NaN→0, out-of-range→±`Int.max/2`, else `Int(d)`) at `cell`, `rings2`,
  and the chaos-game palette index. For normal genomes the guard is bit-identical
  to `Int(d)` (zero parity impact); only degenerate `cell_size≈0` saturates,
  where flam3 is UB and the output is unchanged. The ±`Int.max/2` target (not
  ±`Int.max`) is required because `cell`'s downstream `y *= 2` overflows
  otherwise.

## [v0.3.0] — M4 complete: native GUI studio

The M4 GUI is complete. `emberweft-gui` grows from the v0.2.0 first slice (library
browser + click-to-play) into a full genome-library studio: a sidebar-driven
browser, multi-select, tri-state sentiment, search and filter, drag-and-drop
import, collections/playlists with drag reorder, and a non-modal playback window.
All testable logic lives in the `EmberweftUI` library; `EmberweftGUI` stays a thin
SwiftUI shell. The M1–M3 engine is unchanged.

### Added
- **NavigationSplitView sidebar:** destinations are **All** (unified, deterministically
  sorted), **Library** (curated 24-genome bundle), **★ Liked** (live count),
  **Imported** (drag-dropped), and **Folders** (one row per opened directory).
  `⌘1–4` jumps to the built-in destinations. One detail grid shows a single
  section at a time (calmer than the v0.2.0 stacked sections).
- **Multi-folder library:** open several folders at once; remove any from the
  library via a per-row control with a confirmation dialog (files stay on disk).
  Legacy single-folder preferences migrate to the multi-folder list.
- **Tri-state sentiment:** a per-genome `−1` dislike / `0` neutral / `+1` like
  signal replaces rating + favorite + tags + notes. Persisted to `metadata.json`
  as schema v2; old v1 `favorite == true` migrates to `sentiment = +1`. Set via the
  card's hover-revealed bar (direct-set), the always-on badge for marked cells, the
  context menu, and `+`/`0`/`−` keys.
- **Multi-select:** click opens the preview; `⌘`/ctrl toggles, shift range-selects,
  `⌘A` selects all (post-filter), `Esc` clears. A hover tick is the per-card
  affordance. A bottom-floating selection bar carries bulk Like / Dislike / Clear
  plus Save as Collection and Add to. `AppModel.applySentiment` iterates a sorted
  sequence (rule #2: never accumulate over the hashed selection `Set`).
- **Search & filter:** `.searchable` text plus a filter popover (sentiment /
  category / palette) with an active-count badge and removable active-filter chips.
  Category is the curated rank OR a heuristic facet, so every genome is
  categorizeable. Palette hue derives from the rendered thumbnail's dominant pixels
  (refined after render), not just the palette mean.
- **Drag-and-drop import:** pure `ImportKit` (path-traversal-safe sanitize, dedup,
  parse-before-copy) into an `Imported/` folder. Per-section rendered-id sets mean
  an import only rescans the Imported section, never the whole grid.
- **Collections / playlists:** create from selection, rename, delete, add, and
  remove entries; drag-and-drop reorder; and Play as Sequence. Entries store their
  source + id, so a removed folder or file is skipped cleanly rather than crashing.
- **Non-modal playback window:** clicking a card opens a dedicated window (not a
  blocking sheet) via a value-driven `WindowGroup(for: PlaybackRoute.self)`, so you
  can browse and rate while a loop plays; one window per genome (identity = stored
  fields). Transport: play/pause, scrub, `←`/`→` frame-step, frame and time
  readouts, and a sentiment bar. A second value-driven window plays a collection as
  a sequence, reusing the M3 multi-genome `PlaybackDispatcher` over a
  `Schedule(librarySize:, selector: Sequential)` (loop + transition segments).
- **Grid browser polish:** skeleton loading cells, `ContentUnavailableView`
  empty/error states (destination-aware), a hover-revealed selection tick, a
  category pill, and S/M/L density (persisted). Off-main Metal thumbnails (from
  v0.2.0) keep the UI from freezing and stay byte-identical to the MainActor path.
- **Keyboard:** Space (play/pause), Esc (close/clear), `+`/`0`/`−` (sentiment),
  `⌘A` (select all), `⌘1–4` (sidebar destinations), `⌘?`/`?` (cheat-sheet).
- Tests: `EmberweftUITests` grew to cover `CollectionsStore` (create/add/remove/
  move/reorder), `ImportKit` (sanitize/dedup/plan), `LibraryFilter`, metadata
  migration, multi-select invariants, and the off-main parity pins.

### Fixed
- **App activation:** a bare-executable SwiftUI app now sets
  `NSApp.activationPolicy = .regular` and activates on launch, so it becomes the
  key app (keyboard was reaching the launching shell). `AppDelegate` via
  `@NSApplicationDelegateAdaptor` in `EmberweftApp.swift`.
- **Thumbnail vs playback orientation** and a **playback GPU leak after close**
  (carried from v0.2.0 and verified under the new non-modal window): the sheet-owned
  view-model was released before `stop()` could run; `beginStop()` now captures self
  strongly and Close awaits `stop()` before dismissing.
- **Collection drag-reorder:** the system `.draggable`/`.dropDestination` (custom
  `Transferable`) and `List.onMove` approaches were unreliable on this bundle-less
  SwiftPM executable (the drop action did not fire; `onMove` replaced the grid with
  a list). Replaced with a custom in-app `DragGesture` (lift + cell-frame
  `PreferenceKey` hit-test + `CollectionsStore.moveEntries`, which delegates to
  `Array.move`). See the new CLAUDE.md gotcha.

### Changed
- The library surface moved from a single stacked grid (v0.2.0) to a
  `NavigationSplitView`: a sidebar of destinations drives one detail grid.
- Per-genome metadata reduced to sentiment only; schema bumped to v2 with a
  `favorite → sentiment = +1` migration.
- The playback surface is non-modal (a value-driven `WindowGroup`) instead of a
  blocking `.sheet`.

### Removed
- Per-genome rating, favorite, tags, and notes (replaced by tri-state sentiment).
- The blocking playback `.sheet` (replaced by the non-modal playback window).

### Known, separate (not part of M4)
A pre-existing, reproducible `testFiniteDeterministicRenders` crash in the FlameKit
`cell` variation (`Int(Inf)` from `cell_size=0`) exists on `main` independent of
M4: the GUI layer does not touch the oracle. A faithful fix is ready but lands
separately.

## [v0.2.0] — M4: SwiftUI App + Library Browser

> _M4 part 1 (first vertical slice). Search/filter, list view, drag-drop import,
> metadata editor, favorites, transport controls, and formal a11y are tracked in
> the M4 completion plan and land in later slices (→ v0.3.0)._

The first GUI. A native macOS app (`emberweft-gui`) that browses a curated genome
library and plays sheep in realtime, reusing the M1–M3 engine verbatim. Adds two
new SwiftPM targets and an off-main Metal render path.

### Added
- **`EmberweftUI`** (new library) + **`EmberweftGUI`** (new executable) SwiftPM
  targets. The existing `emberweft` CLI target is untouched. The library holds the
  SwiftUI↔AppKit bridge, production playback conformers, thumbnail service, and
  library/settings models — a library (not the executable) so the M5 screensaver
  can reuse the playback hosting.
- **Library browser** — a grid of thumbnails over a curated bundle + any
  user-opened directory. Thumbnails render off-main (see below), downscale from a
  higher render resolution for a crisp cell, and are cached (bounded `NSCache` +
  disk). Degenerate / all-black / NaN-camera genomes are excluded from the grid.
  A progress indicator tracks thumbnail rendering.
- **Click-to-play** — opens a realtime playback window hosting the existing
  `PlaybackDispatcher` + `FlameUI` (`CAMetalLayer`). Preview uses fast/low-spp
  params so playback stays close to real time; settings persist to
  `~/Library/Application Support/Emberweft/preferences.json` (resilient to
  corruption).
- **`emberweft curate`** CLI subcommand — the offline curation pipeline (parse
  filter → thumbnail → deterministic heuristic score → emit `ranking.json`).
  Curated the ~9.5k gen-248 flock into a diverse, ranked 24-genome seed bundle
  (spiral / radial / filament / dense; 142 NaN/degenerate rejected).
- **Off-main Metal render path** — `MetalRenderer.renderOffMain` renders on a
  dedicated background serial queue with its own device/library/queue/PSO cache,
  so thumbnails are fast AND never touch the MainActor (no UI freeze). The
  realtime `@MainActor` path is unchanged.
- 34 new `EmberweftUITests` (library scan, cache-key determinism, settings
  round-trip + corrupt-file quarantine, genome health, playback teardown
  invariant, and Metal parity incl. **off-main == MainActor byte-identical** on a
  real complex genome).

### Changed
- `MetalRenderer.renderFused` extracted into an actor-agnostic `renderFusedCore`
  (takes device/queue/PSOs as params); the `@MainActor` wrapper and the off-main
  path both call it. Output is byte-identical.
- De-isolated the pure Metal host helpers (`MetalHost`,
  `DisplayPipelineMetal.makeSpatialKernelMetal` / `DisplayParams`) — their
  `@MainActor` was purely conservative; they're pure compute, now callable
  off-main. `FlameUI.makeCGImage` is now `public nonisolated`.

### Fixed
- **Thumbnail vs playback orientation mismatch.** The thumbnail path applied the
  `CAMetalLayer`-oriented row-flip (`FlameUI.makeCGImage`) inside the downscale
  step, then again at display — a double flip vs playback's single flip.
  `RGBA8Image.toCGImage()` now builds an upright (no-flip) CGImage matching the
  `writePNG`/flam3-oracle orientation, used for `NSImage`/SwiftUI and processing.
- **Playback kept using the GPU after its window closed.** `beginStop()` captured
  `[weak self]`, but the view-model is `@State` owned by the sheet — SwiftUI
  released it before `stop()` could run, leaking the dispatcher's infinite run
  loop. `beginStop()` now captures self strongly; the Close button awaits
  `stop()` before dismissing.

### Lesson
The ~36 ms thumbnail "freeze" was per-render host overhead (buffer alloc + commit
+ `waitUntilCompleted`), largely resolution-independent — so lowering the
thumbnail size didn't help. The only fix is off-main rendering. And: a CGImage
built for `CAMetalLayer.contents` is NOT the same orientation as one built for
`NSImage` — keep the two flip paths separate.

## [v0.1.10] — Seamless Transition Boundaries: Clip One-Sided Variation Leaks

A frame-by-frame review of the 12-gen-247 overnight render (v0.1.9) found a "complexity jump" at loop→transition boundaries — elements appearing that weren't in the loop, persisting through the transition. After ruling out 4 wrong hypotheses (sharp-frame v0.1.8/v0.1.9, `.log` polar residual, align padding, padding-pick-rate), an **instrumented** dump + per-slot/per-component bisect found the true cause: at any t>0, `mergeVariations` (faithfully porting flam3's `INTERP(xform[i].var[j])`) emits tiny nonzero weights (~t·B.weight) for one-sided variations (B has, A lacks). On spiky attractors these chaotic "leaks" redecorate the canvas — e.g. 05915→37205 slot-2 (horseshoe/fan2/mobius/cot/lazysusan) fills ~30% more histogram bins at the boundary → +38% luma, **blur-invariant** (the loop, which doesn't interpolate, is clean). Confirmed FAITHFUL (flam3's oracle does the same; q-dependent — worse at low q where the background isn't filled).

### Fix (seamless divergence, per owner's "fix-for-seamless where flam3 does it")
`GenomeInterpolator.mergeVariations` clips one-sided leaks: drops any variation whose raw weight is 0 on **exactly one** side (absent, or a weight-0 `align` parametric-copy slot) AND whose merged weight is below ε=1e-3. Both-zero slots preserved (flam3's full `var[]` array); two-sided kept; leaks fade in once weight ≥ ε (~frame 7 at N=240). Name-presence alone is defeated by `align`'s parametric-param copy (adds B's parametric variations to A at weight 0) — the per-side RAW weight is the test.

### Verified
- Both boundaries seamless: loop→trans **start** luma 84→60 (matching the loop's 61); trans→loop **end** 34.1→34.8 (matching the next loop). The morph is intact (61→23→34 mid-transition, continuous, no spike).
- `make test-fast`: **325/0** (+1 `testMergeClipsOneSidedLeaksBelowEps`).
- AnimationParity (vs flam3) shift: the clip diverges from flam3 on boundary frames (expected — it's a documented divergence); re-baseline pending the parity-gate run.

### Lesson (5 wrong turns to the cause)
The over-bright survived 4 misdiagnoses because it's blur-invariant + lives at the variation-list level (not the matrix or the padding). The decisive move was **instrumenting** — dumping the actual merged genome, bisecting per-slot and per-component (affine / scalars / variations) — rather than reasoning. Always dump + measure a render-brightness bug before theorizing a fix.

## [v0.1.9] — Revert v0.1.8 Offline Boundary Short-Circuit (sharp-frame regression)

A frame-by-frame review of the v0.1.8 overnight render (12 gen-247 genomes, 720p/q1000/ts32) found visible "complexity jumps" at loop→transition boundaries (e.g. frame 240→241: ~30 MAD). **Root cause: v0.1.8's own short-circuit.** The per-frame `isLoopToTransitionBoundary` check in `AnimateCommand.blendAt` returned `pure-A` for ALL 32 temporal sub-frames of the boundary frame, so it rendered **sharp** while its neighbors were motion-blurred — the sharp↔blurred delta was the jump (boundary-frame sharpness 129.9, +33% above the ~97 loop baseline, vs ~71 for blurred neighbors). flam3's `seqflag` shortcut fires PER SUB-FRAME (only the exact blend=0 one), so its blur survives and averages out the faithful `.log` polar residual (flam3 ts=32 = 6.25 MAD). v0.1.8 fixed the segment-boundary frame but relocated the jump to boundary+1, and at the wrong layer.

### Fix
- **Removed** the offline short-circuit from `AnimateCommand.blendAt` — the offline path's temporal blur now smooths the boundary (matching flam3).
- **Kept** the realtime short-circuit in `PlaybackDispatcher.renderOneFrame` (no temporal blur there; faithful to flam3's `seqflag` for single-frame rendering).
- `Schedule.isLoopToTransitionBoundary` + `testLoopToTransitionBoundary` retained (the realtime path uses them).

### Verified
- Boundary-frame sharpness spike gone (was 129.9; now matches the blurred transition neighbors).
- MAD(boundary → first-transition-frame): **29.83 → 5.93** (now below the 8.0 within-loop baseline). Re-rendered 05915→37205 at ts=32.
- `make test-fast`: 325/0.

### Not a defect (confirmed)
The other flagged spot (959→960) is NOT a discrete jump — it's the top of a smooth ramp (within-segment MAD climbs 3→22 through the transition) into genome 03400's uniformly-rough loop (12–16 MAD/frame). A busy dissimilar morph into a spiky attractor; faithful.

### Lesson
v0.1.8 was verified with a single-frame MAD measurement that I misread as "the morph starting" — it was the same sharp-frame defect. Verify boundary fixes at the actual render settings (ts>1) and inspect sharpness/blur asymmetry, not just blend-level endpoint MAD.

## [v0.1.8] — Fix Loop→Transition Boundary Discontinuity (port flam3's seqflag shortcut)

The loop→transition handoff (`loop(A) → transition(A→B)`) had a ~21 MAD-per-pixel discontinuity on spiky attractors (e.g. 09557→21924) — the largest of 10 segment boundaries in the v0.1.7 coverage sweep. Root cause: Emberweft was missing flam3's `seqflag && blend==0` shortcut (flam3.c:476-477: `flam3_copy(result, &prealign[0])`), which returns A directly at the boundary, SKIPPING the align+establish+rotate+interpolate chain. Emberweft ran that full chain at the boundary, where (a) the 1-indexed schedule emits `blend=1/N` (already morphed ~1/N toward B, not pure A) and (b) the `.log` polar round-trip drops ~1e-15 affine residual that the chaos game amplifies (Lyapunov instability) into a decorrelated sample distribution. (`SpecialSauce.align` itself is faithful — it does not touch A's existing xforms, only invisible padding slots.)

### Fix (faithful correction — ports the missing shortcut, at the caller layer)
- `Schedule.isLoopToTransitionBoundary(globalFrame:)` — pure O(1) predicate identifying the boundary frame (first frame of a transition segment). Unit-tested (`testLoopToTransitionBoundary`).
- `AnimateCommand.blendAt` + `PlaybackDispatcher.renderOneFrame` — at that one boundary frame per transition, render the fromSheep genome directly (pure A, un-aligned) instead of `Transition.blend(..., t: 1/N)`. Covers both the offline video path and the realtime screensaver path. `Transition.blend`'s contract is unchanged (its endpoint tests pass unmodified — they use matching-xform-count genomes where `alignedA == A`).

### Verified
- Boundary MAD (09557→21924, 480×360/q150/ts4/metal): **21.0 → 5.2** — now at the within-loop rotation-seam level (~5.6), i.e. the cross-segment handoff is seamless; the morph then proceeds normally within the transition.
- `make test-fast`: **325/0** (was 324; +1 `testLoopToTransitionBoundary`), 1 skipped perf gate. Single-frame goldens unchanged (the fix is one transition-boundary frame only; no schedule-grid or `Transition.blend` change).

### Note (separate, not addressed here)
Emberweft's whole schedule is 1-indexed (`blend=(local+1)/N`, never 0) vs flam3's 0-indexed (`blend=local/N`) — which is why the shortcut ports at the caller layer rather than as `if t==0` inside `Transition.blend` (the schedule never reaches t=0). A residual side-effect: the transition's first morph step is ~2/N (the boundary frame is pure A, then frame 1 jumps to `blend=2/N`), slightly larger than flam3's ~1/N steps. Full 0-indexed schedule alignment is a larger, riskier change (shifts every frame's blend) and is left as a separate item.

## [v0.1.7] — Transition-Faithfulness Audit + Camera.scale Divergence Formalized

A field-by-field audit of `GenomeInterpolator.blend` / `Transition.blend` / `Loop.blend` vs flam3 `interpolation.c:464-708` (the `INTERP` block), looking for any remaining gap in the v0.1.5/v0.1.6 class (missing/dropped/hard-cut INTERP field, param handling, endpoint issue) across all 99 variations and real gen-248 genomes. An independent fresh-context subagent re-ran the audit and confirmed the conclusion.

### Audit result: no rendering-affecting gap remains for real genomes
Every field in flam3's `INTERP` block is handled. The candidates that looked like gaps are all faithful-by-default or have zero observable effect on gen-248 explicit-palette genomes (the live flock):
- `contrast` (INTERP :474) — Emberweft hardcodes 1.0; **0/300** gen-248 genomes set it (flam3 default 1.0). Moot.
- `background` (INTERP :486-488) — hardcoded 0; always `"0 0 0"`. Moot.
- `rot_center` (INTERP :484-485) — not modeled; never set. Moot.
- `hue_rotation` (INTERP :478) — `Transition.blend` interpolates it correctly; inert for gen-248 (explicit palettes never carry `hue`, and `flam3_get_palette` — the sole `hue_rotation` consumer — only runs for `palette_index != -1` index palettes, which gen-248 never uses). Moot.
- `size` w/h (INTERI :479-480) — hard-cut at 0.5; same-size pairs + `--size` CLI override → no render effect. Cosmetic.
- chaos/weight/color/colorSpeed defensive clamps (interpolation.c:508,532,534-535,538-539) — omitted; lerp stays in-range for t∈[0,1] → no effect. Cosmetic.

The v0.1.5 (mergeLog params, padding-final, paletteMode propagation) + v0.1.6 (Quality interp, det guard, endpoint padding-final) fixes closed the actual gaps. Stagger, chaos-matrix sizing, and endpoint faithfulness across all four final-xform pair-types were independently verified.

### One divergence formalized: Camera.scale log-space
The audit surfaced that `Camera.scale` (= flam3 `pixels_per_unit`) is interpolated in **log-space** (geometric mean) where flam3 uses **linear** `INTERP` (interpolation.c:489) — universal on real transitions (every gen-248 edge has differing scale), up to ~21% framing difference at high-ratio midpoints (e.g. 400→110). A/B-rendered the same 3.6× transition both ways and reviewed: **log kept as an intentional seamless divergence.** Magnification is perceived logarithmically (Weber-Fechner), so log-space gives constant *perceived* zoom velocity and a perceptually-symmetric midpoint (linear perceptually accelerates on zoom-out). `zoom`/`rotation` stay linear — `zoom` is already log-coded in the projection (`pixelsPerUnit = scale·2^zoom`, so linear-in-zoom is geometric-in-magnification), and angle is perceived linearly. **No behavior change** (log-space has been the implementation since `179c21b5a`); this entry makes it permanent, documented, and regression-pinned.

### Changed
- `GenomeInterpolator.swift`: removed the temporary `EMBERWEFT_SCALE_INTERP` A/B switch; permanent log-space `Camera.scale` with a rationale comment.
- `InterpolationTests.swift`: strengthened `testScaleLogSpace` docstring — pins the divergence with a "don't revert to linear in a flam3-parity pass" guard.
- `CLAUDE.md`: new gotcha documenting the `Camera.scale` log-space intentional divergence (parallel to the `.log` det guard).

### Verified
- `make test-fast`: **324/0** (1 skipped perf gate), incl. the strengthened `testScaleLogSpace`, InterpolationTests, TransitionTests, SpecialSauceTests, VariationsTests (110). No frozen-golden shift (transition-only; single-frame rendering unchanged).
- A/B render confirmed the (now-removed) switch took effect during the comparison: transition frames differ log↔linear, loop frames byte-identical.

## [v0.1.6] — Transition Smoothness: Quality Interpolation + Singularity Guard + Endpoint Final

Three fixes for mid-transition and endpoint discontinuities found in the 8-sheep coverage video. One is a strict faithfulness fix; two are intentional seamless divergences from flam3 (per the owner's directive: "fix for seamless even where flam3 does the same").

- **Quality hard-cut at blend 0.5** (faithful fix — `GenomeInterpolator.swift`): `f.quality = t < 0.5 ? a.quality : b.quality` hard-cut the entire display pipeline (brightness, gamma, vibrancy, highlight_power, etc.) at the transition midpoint, causing a brightness/colour pop when adjacent sheep had different display params. flam3 `INTERP`s all 12 Quality scalars linearly (interpolation.c:473-501). Replaced with `interpolateQuality(a,b,t)` — linear blend of numeric fields, enum/int fields copied from `cpi[0]`. Verified: midpoint Δlum −42→−0.13.
- **`.log` midpoint matrix singularity** (seamless divergence — `GenomeInterpolator.swift`): opposite-handedness xform pairs (det −1↔+1) cross det=0 at the polar-log midpoint → columns coincide → rank-1 density spike → uniform brightening. flam3 has no determinant guard (verbatim port, same singularity). Added a `det(A)·det(B) < 0` check: opposite-handedness pairs fall back to `.linear` matrix interp (`lerpAffine`) which avoids the coincident-column collapse. Same-handedness pairs are byte-identical to flam3 (unaffected). Verified: worst coverage Δlum +58→−1.2 at the coverage's exact settings.
- **Padding-final at endpoint** (seamless divergence — `Transition.swift`): when A has a final xform and B doesn't, `align` synthesizes a padding final (rest-positioned to e.g. `rings2=1`), creating a discontinuity at `Transition(A,B,1.0)` vs `Loop(B)` (no final). flam3's `align` does the same (faithful). Added: if B had no native final, drop the padding final at `t=1.0` so the endpoint matches the loop. Diverges from flam3 only at the exact endpoint. Verified: boundary Δlum −23→+0.17.

### Verified
- All four problem regions smooth (midpoint + endpoint, before/after measured).
- Gates: InterpolationTests + TransitionTests 32/32 (incl. 4 new regression tests), SpecialSauceParityTests 84/84, ParamChannel + GoldenParity frozen goldens **byte-identical** (no shift — fixes are transition-only, don't affect single-frame rendering), AnimationParityTests 4/4 (vs flam3), AnimatedFrameParityTests 4/4, RealGenomeParityTests pass, test-fast 324/0.
- The A2/B1 divergences are scoped tightly (A2: only opposite-handedness pairs; B1: only the t=1.0 endpoint where B had no native final) — they don't fire on the parity fixtures.

## [v0.1.5] — Fix Transition Endpoint Faithfulness (`Transition(A,B,1.0)` now = B)

The end of a `sheep_edge` transition did not reach the destination genome: `Transition(A,B,t=1.0)` rendered at only **16.8 dB** vs `Loop(B)` (and vs `flam3`'s 49.77 dB) — an Emberweft-only faithfulness bug, not flam3 behavior. It caused an abrupt "missing transition" jump at edge→loop boundaries for pairs where A has a final xform and B doesn't (e.g. 16636→17491). Three independent deviations from flam3's interpolation source, all fixed:

- **`mergeLog` parameter bleed** (`GenomeInterpolator.swift`): used "A's params win, B fills gaps" — but flam3 `INTERP`s each parametric field linearly (`result.p = (1−t)·A.p + t·B.p`). At t=1.0 A's `curl_c1` bled into a padding-final xform instead of B's `0`. Rewritten to per-param linear interp (descriptor defaults when a side lacks the param). The old "matches flam3's `merge_log`" comment was wrong — flam3 has no such function.
- **Padding-final fields** (`SpecialSauce.swift`): `makePaddingXform` left `colorSpeed=0.5`, but flam3's `flam3_copyx` forces `colorSpeed=0, animate=0` for padding-finals — so Emberweft's padding-final halved every bin's color. New `makePaddingFinalXform` mirrors flam3.c:1262-1266; regular padding unchanged.
- **Dropped scalar fields** (`GenomeInterpolator.swift`): `blend` started from `Flame()` defaults, never copying `paletteMode`/`interpolationType`/`paletteInterpolation`/`hsvRgbPaletteBlend` from `cpi[0]` (flam3 interpolation.c:466-468) — silently reverting `.linear` inputs to `.step`. Now propagated from `a`.
- **`animate` interpolation**: added `x.animate = (1−t)·a.animate + t·b.animate` (flam3 interpolation.c:542) to both xform callbacks — closes a faithfulness gap (no render effect today).

### Verified
- Endpoint `Transition(16636,17491,1.0)` vs `Loop(17491)`: **7.7 dB → ∞ dB (byte-identical, MD5 match)** at q1000/1080p/Metal.
- All gates green: `AnimationParityTests.testSheepEdgeVsFlam3Inter` (`.log` transition vs flam3) **improved to 59.04 dB**; `AnimatedFrameParityTests` 4/4; `SpecialSauceParityTests` 84/84; `ParamChannelParityTests` + `GoldenParityTests` frozen goldens **byte-identical** (frozen genomes are param-free/final-free → don't exercise the fixes); `make test-fast` 320/0. New regression test `testLogMergeAtOneReturnsBParams`.

## [v0.1.4] — Fix Metal Float-Overflow Collapses in Hyperbolic/Trig/Exp Variations

Metal kernels use `float`; `flam3` and the CPU reference use `double`. For variations that compute `cosh`/`sinh`/`exp` on a potentially-large argument, Metal overflows to `+Inf` (Float `cosh` overflows at arg ≈ 89, `exp` at ≈ 88.7) where `double` is finite, producing `0.0f * Inf == NaN` that contaminates the chaos-game accumulator, trips `badvalue_ms`, and **collapses the rendered trajectory to near-black + desyncs from CPU**. This was the root cause of the abrupt "missing transition" seam at the 16636→17491 edge (frame lum 3.6, collapsed; `flam3` renders it bright at ~95 → Emberweft-Metal bug, not faithful): 16636's huge xform-0 affine (`a=34.67`) pushes `pre.x` past 44, and a tiny interpolated `coth` weight (from 17491) triggers the overflow.

### Fix
Clamp the overflow-prone argument to `[-88, 88]` before each `cosh`/`sinh`/`exp` call across **all 15 affected variations**: `coth cot sinh cosh tanh sech csch csc sec exponential cosine exp sin cos tan`. **Faithful:** bit-identical for normal-magnitude args (parity tests unchanged); for large args it captures exactly the saturated `±w` / `0` limit that CPU `double` produces. CPU formulae untouched (no overflow in `double`). 15 small clamp edits in `Sources/FlameRenderer/Metal/Kernels.metal`, no logic change.

### Verified
- Per-variation `SpecialSauceParityTests` (Metal↔CPU, 1000spp, normal affine): all ≥38 dB / **inf** — the clamp never fires for normal args.
- Stress check (large pre-affine `a=34`/`b=60` + small weight): `exp`/`sin`/`cos`/`exponential`/`cosine`/`sinh`/`cosh`/`coth` collapses **fixed** (Metal lum 0 → matching CPU). The ratio-family (`cot`/`csc`/`sec`/`csch`/`sech`/`tanh`) saturate to ~0 on both backends by analysis — correct by direct analogy to the real-world `coth` case.
- The real 16636→17491 edge at 1080p/q1000/temporal-32: the `coth` frame lum **3.6 → 66.4** (bright; collapse gone), boundaries smooth.
- Broad gate: `SpecialSauceParityTests` **84/84**, `ParamChannelParityTests` frozen-goldens **byte-identical**, `make test-fast` **317/0**. (Investigation + hardening by subagent; root cause confirmed via `git bisect`-style isolation + a `flam3` oracle comparison.)

## [v0.1.3] — Fix Metal Empty-Frame Regression on Fragile Animations

Fixes a regression **introduced by v0.1.2's batch-4 variation port (`b707a0429`)**: growing `GPUXform` to 906 floats (3624 B) and passing it **by value** to four inline Metal helpers (`apply_affine`, `apply_post`, `blend_color`, `apply_xform_body`) destabilized the Metal compiler's FP instruction scheduling for the chaos-game kernel. On fragile multi-xform real attractors (e.g. `248.05739`, `248.31943`, `244.00788`) at certain rotations, the re-scheduled Float trajectory diverged past the out-of-bounds/NaN tipping point → zero in-bounds samples → empty histograms → `RGBA(0,0,0,0)` frames (white in a PNG viewer, black in an alpha-flattened video). It also broke run-to-run determinism (rule #2) — which frames tipped varied per Metal-library compilation. Stable single-variation genomes and stills (rotation 0) were unaffected, which is why `SpecialSauceParityTests` stayed green but real multi-xform animations broke, and the regression escaped the v0.1.2 gate.

Root cause verified by `git bisect` (`b707a0429` is the first-bad commit) and ruled out: Swift↔MSL struct-layout mismatch (they match; `ParamChannelParityTests` green), the `pre_blur` PRE-step (disabled — empty frames persisted), and fast-math (`mathMode = .safe` didn't help). It is a compiler-codegen-stability issue from oversized by-value struct passing.

### Fix
Pass `GPUXform` by **const-reference** (`thread const GPUXform&`) to the four helpers — idiomatic for a large read-only struct; the call sites (`xf`, `fin` — thread-local lvalues) bind unchanged. 4 signature lines in `Sources/FlameRenderer/Metal/Kernels.metal`, no logic change, no features disabled.

### Verified
- Empty frames on a `248.05739` single-loop (Metal): **0 / 40** (was ~13, nondeterministic across runs).
- Run-to-run determinism restored — frames are byte-identical across Metal-library compilations (rule #2).
- `SpecialSauceParityTests` **84/84** (Metal↔CPU ≥38 dB); `ParamChannelParityTests` **3/3** incl. `testFrozenGenomesByteIdenticalToBaseline` (stable genomes byte-unchanged); `make test-fast` **317/0** (+1 skipped).
- m3_mb recipe (`05739→31943`, `--temporal-samples 32`, `--backend metal`) re-rendered: **0 empty frames**, seamless loop↔edge boundaries (previously full of empty frames / broken transitions).

### Note on the separate Metal Float gap (unchanged)
The **`244.00788` still** Metal↔CPU gap (~33.68 dB, under the 38 gate) is a *genuine* Float-vs-Double limitation on spiky stills — **not** this regression (stills at rotation 0 were never affected, and the figure is unchanged by this fix). It remains a documented Metal-Float floor; the CPU oracle is faithful (41 dB vs flam3). See `docs/superpowers/plans/2026-07-23-metal-step-port.md`.

## [v0.1.2] — Full flam3 Variation Coverage (99/99)

Completes the faithful flam3 variation set: ports the remaining **42 variations** that v0.1.0/v0.1.1 lacked, taking Emberweft from **57 → 99 of 99** flam3 variations — every variation in `scottdraves/flam3`. All 42 are validated against the live flam3 oracle at **≥38 dB PSNR** (the vs-flam3 gate, now *enforced* per-variation in `VariationFlam3ParityTests`) and at **≥38 dB Metal↔CPU** (`SpecialSauceParityTests`); frozen goldens stay byte-identical (new slots appended at the end of `canonicalOrder`, so existing slots 0..56 are untouched). Lowest vs-flam3 PSNR across all 42: `exp` at 41.34 dB (the rest 52–75 dB).

### Variations ported (CPU + Metal, Reference-then-Optimize)
- **Trig family (14, var82–95):** `exp log sin cos tan sec csc cot sinh cosh tanh sech csch coth` — paramless.
- **Paramless non-trig (7):** `butterfly edisc elliptic foci loonie polar2 scry`.
- **Parametric (18):** `bent2 bipolar cell escher flux modulus splits stripes whorl` (≤2 params) + `auger curve lazysusan mobius popcorn2 separation waves2 wedge oscilloscope` (3+ params; `mobius` uses all 8 slot params — `slotWidth=8`).
- **RNG-consuming (3):** `boarders` (1 draw), `cpow` (1 draw + `cpow_r/i/power`), `pre_blur` (**5 draws — a PRE-transform**: applied after the affine, before precalcs + the variation loop, mutating the input point; new `applyXformBody` pre-step on CPU + a matching pre-step in the Metal chaos kernel, skipped in `Variations.evaluate` and the dispatch chain).

### Faithful-port care (parity-critical disambiguations)
- `log` uses `precalc_atanyx = atan2(ty,tx)`; `polar2` uses the swapped `atan2(tx,ty)`.
- `EPS = 1e-10` (`private.h:47`), not 1e-6; `curve` uniquely uses `1e-20` (matched verbatim).
- `cell`/`modulus`/`mobius`/`cpow` are singular at their default-0 params (division by zero / `Int(inf)`) — faithful to flam3 (no explicit guard in source); real genomes set nonzero params. Excluded from the finiteness smoke test alongside the pre-existing `perspective` precedent.
- `lazysusan` has an asymmetric `+lazysusan_y` on input / `−lazysusan_y` on output (load-bearing).
- `oscilloscope` exposes its 3 documented params (`separation/frequency/amplitude`); the 4th (`damping`, defaults 0) is intentionally not exposed — the damping=0 branch is ported verbatim.
- New **Work A enforcement**: each newly-ported variation must clear ≥38 dB vs-flam3 (asserted, not diagnostic) before it ships.

### Tooling
- `VariationFlam3ParityTests` enforces ≥38 dB per Work-A variation (was diagnostic-only).
- Slot budget: `NUM_XFORM_SLOTS_MS` 57→99; `GPUXform` now 906 floats (3624 B) per xform.
- Per-variation vs-flam3 harness (`VariationFlam3ParityTests`) added — the test gap that hid variation-integration bugs through M2/M3/CV.

### Known gaps (unchanged from v0.1.1, documented in `docs/superpowers/plans/2026-07-22-remaining-work.md`)
- 2 edge-genome `.knownGap` fixtures (244.00788 sampling-noise at the fast op-point — passes at stress; 244.28122 marginal 37.65 dB) — not variation bugs.
- Metal renderer still uses LINEAR palette sampling (Float can't match CPU-Double STEP on spiky real palettes — a pre-existing Metal-Float limitation, not a regression). CPU-vs-flam3 (the primary gate) uses STEP and is correct.

## [v0.1.1] — Corpus-Variation Coverage (100% of ES-corpus-used variations)

Ports the 20 flam3 variations the archived Electric Sheep corpus uses that v0.1.0 lacked — **100% coverage of every variation appearing in a 23k-genome corpus survey** (Emberweft now **57 of 99** flam3 variations). Real-genome parity holds (49–52 dB on the original 7 fixtures; 5 new `.gate` fixtures at 38–52 dB). Two pre-existing parse bugs found + fixed.

### Variations ported (CPU + Metal, Reference-then-Optimize)
- **Paramless non-RNG**: `waves` (the big gap — 12,889 corpus occurrences, a top-8 variation), `popcorn`, `power`, `tangent`, `cross`, `secant2`.
- **Parametric non-RNG**: `pdj`, `split`, `disc2` (with its `disc2_precalc`).
- **RNG-consuming**: `noise`, `blur`, `gaussian_blur` (5 draws), `arch`, `square`, `rays`, `blade`, `twintrian` (badvalue guard `→ -30.0`), `flower`, `conic`, `parabola`.
- The CPU variation table's affine plumbing was widened (`ef` → `affine: SIMD4` c,d,e,f) so `waves`/`popcorn` can read the pre-affine coefficients — behavior-neutral (`rings`/`fan` byte-identical; goldens unchanged).
- **Corpus survey**: only `secant2` (0.7%) + `disc2` (0.6%) remained beyond the v0.1.0 set — both now ported. The other 42 of the 99 flam3 variations are **unused by any corpus genome** (deferred — see `docs/superpowers/plans/2026-07-22-remaining-work.md`).

### Fixed
- **Sanitize regex** in `RealGenomeParityTests` clobbered `split_xsize`/`split_ysize` (the `size="…"` pattern matched as a substring) — fixed with a word-boundary lookbehind.
- **Legacy `symmetry=` attr mapping**: `color_speed = (1-sym)/2` (was `1-sym`, 2× off) + derive `animate = sym>0 ? 0 : 1` (was missing) — cost ~40 dB on affected genomes. Pinned by a regression test.

### Known gap (separate, documented)
4 edge-genome fixtures render at 28–34 dB (`.knownGap`) — **not variation bugs** (Metal↔CPU parity passes at 45–inf dB); a residual display/parsing gap on default-`highlight_power` genomes (flam3's default hp −1.0 matches Emberweft's; the gap is another mishandled attr of the `symmetry`/`sanitize` class). Investigation/fix plan in the remaining-work doc.

## [v0.1.0] — Real-Genome Parity + Motion Blur

The first versioned release, landing **post-M3** on `main`. Closes the
real-genome faithfulness gap against `flam3` and ports motion blur, so offline
renders of real Electric Sheep genomes are production-quality. Synthetic goldens
remain byte-identical; M3 animation parity (43–58 dB) is unchanged.

### Motion blur — faithful `temporal_samples` port
`temporal_samples` motion blur on **both** backends
(`ReferenceRenderer.render(blendAt:…)` / `MetalRenderer.render(blendAt:…)`):
`N` chaos sub-passes per frame across a ±`temporal_filter_width/2` window, with
`color_scalar` baked into the dmap, counts unweighted, and `sumfilt` threaded
into `k2` — a faithful port of `flam3_create_temporal_filter` + `rect.c`'s
temporal loop. **Cost-neutral** (total samples unchanged). Box / gaussian / exp
filters via the new `TemporalFilter` helper.

- `emberweft animate --temporal-samples N` — CPU defaults to the genome's value
  (uncapped); Metal caps at 64 to bound dispatch overhead.
- `emberweft animate` now renders a **single-sheep loop directly** (`--segments 1`);
  transitions (`--segments > 1`) need ≥2 genomes. See the README and
  [docs/rendering/animation.md](docs/rendering/animation.md) for sheep-loop and
  edge/transition video recipes (`animate` PNG sequence + `ffmpeg` mux to MP4).
- Production clip verified end-to-end: loops rotate, transitions morph, and the
  transition→loop boundary is smooth. The gate uncovered two real-genome bugs
  (see Fixed).

### Real-genome density-parity gap closed
`highlight_power` (was hardcoded −1.0; real genomes carry `"1"`) and
`spatial_filter_radius` / `filter` (was hardcoded 0.5; genomes carry `"1"`) are
now parsed from the genome and wired into CPU `ToneMapping` and the Metal display
pipeline (including the saturated-highlight HSV branch added to the Metal
kernel). Result: real-genome still PSNR vs `flam3` went **~20 dB → 49–52 dB**
across the fixture corpus.

### Missing variations (Reference-then-Optimize)
Four variations used by real gen-248 genomes but absent from Emberweft are ported
to **both** CPU (`Variations.swift`) and Metal (`Kernels.metal`):

- **`bubble`** — paramless, 0 RNG draws.
- **`eyefish`** — paramless; **not** a `fisheye` alias (output un-swapped).
- **`pie`** — 3 ordered `isaac_01` draws; params `pie_slices` / `pie_rotation` /
  `pie_thickness`.
- **`radial_blur`** — 4 summed `isaac_01` draws; param `radial_blur_angle`.

`VariationDescriptor.canonicalOrder` grew 33 → 37.

### Fixed — gate-uncovered real-genome bugs
Two bugs that synthetic-golden parity never exercised (real-genome-only):

- **Temporal-filter delta units** — the filter delta was in frame-time but added
  to per-segment blend, producing ±216° over-blur on static loops. Fixed by
  scaling by `1/framesPerSegment`.
- **Padding-xform weight** — `SpecialSauce.makePaddingXform` used weight 1.0, but
  flam3 padding xforms are `density=0` (invisible); mismatched xform counts broke
  the real-genome transition→loop seam. Fixed (weight 0).

### Real-genome parity gate
`RealGenomeParityTests` — all 7 real gen-248 fixtures now `.gate` at **49–52 dB**
(≥ 38 gate) vs `flam3`; `Tools/density_diff.py` localizes any remaining density
delta. Synthetic goldens remain byte-identical; M3 animation parity (43–58 dB) is
unchanged.

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
