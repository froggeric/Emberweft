# Roadmap

*Development milestones from initial documentation through post-MVP features and enhancements.*

> **Status:** preliminary, for review · Emberweft

## Current Status

**Current milestone:** M5, macOS Screensaver Bundle · **M0, M1, M2, M3, and M4 complete; M6 complete (v0.5.0); M6.1 pause/resume (v0.5.1); M6.1 slice 2 temporal smoothing (v0.5.2–v0.5.7); M6.5 flock archive + stitching (v0.6.0); M6.6 resolution-independent framing (v0.6.1); M6.7 vertical/social presets (complete, unreleased)** (see [CHANGELOG.md](../../CHANGELOG.md)). M4 shipped in two slices: **v0.2.0** (the SwiftUI app first slice: library browser + click-to-play, off-main Metal thumbnails, the `curate` CLI) and **v0.3.0** (M4 complete: a `NavigationSplitView` sidebar browser, multi-select, tri-state sentiment, search/filter, drag-drop import, collections/playlists with drag reorder, and a non-modal playback window). Post-M3 patches on `main`: **v0.1.0** (real-genome faithfulness `highlight_power`/spatial-filter, motion blur, +4 variations), **v0.1.1** (corpus-variation coverage → 57/99), **v0.1.2** (the remaining 42 variations → **99/99 flam3 variation coverage**), **v0.1.3** (fix: the Metal empty-frame regression, `GPUXform` by const-ref in the Metal kernels), **v0.1.4** (fix: Metal Float-overflow collapses in 15 hyperbolic/trig/exp variations, clamp args to ±88), **v0.1.5** (fix: transition endpoint faithfulness, `Transition(A,B,1.0)` now reaches B), **v0.1.6** (fix: transition smoothness, Quality field interpolation + `.log` det guard + endpoint padding-final drop), **v0.1.7** (transition-faithfulness audit + Camera.scale log-space divergence formalized), **v0.1.8–v0.1.9** (loop→transition boundary: port flam3's seqflag shortcut, then revert the offline sharp-frame regression), **v0.1.10** (fix: clip one-sided variation leaks for seamless boundaries), **v0.3.1** (M4 polish: configurable preview presets + live FPS readout in both playback windows; `testFiniteDeterministicRenders` crash fix via a nontrapping `intTrunc` guard on `Int(Double)`), **v0.3.2** (M4 polish: distinct preview vs. export quality in Settings, per-parameter help tooltips, `⌘,` shortcut-collision fix, `make dist` target), **v0.4.0** (M6 engine + CLI: `emberweft export` to MP4/MOV, `FramePlan`, `ThreadSeedBudget`). **v0.5.0** (M6 GUI export: export sheet + non-blocking progress/ETA/cancel, ProRes 422 HQ mastering default, off-main temporal Metal, separate loop/transition durations + rotation easing). **v0.5.1** (M6.1 pause/resume: Pause/Resume/Discard + crash recovery, interleaved byte-identical render loop, CLI `--checkpoint-frames`/`--resume`/`--discard`). M6.1 slice 2 (temporal smoothing: centered box window + retuned quality tiers + tier-aware temporal samples; export-only; animate/export byte-identity preserved) shipped v0.5.2–v0.5.7 (v0.5.7 removed loop-repeat, whose render-once-repeat caused half-speed motion) (see [CHANGELOG.md](../../CHANGELOG.md)). **M6.5, flock archive + stitching** (standalone milestone between M6 and M7; complete in v0.6.0): a local archive of pre-rendered loop/edge videos (HEVC Main10 `.mov`, ES-inspired 4-field naming) plus Path A (Generate) to pre-bake material and Path B (Stitch) to compose a long video from the archive (cached segments stitch in seconds via passthrough concat; misses render into the archive first), a `flock.sqlite` catalog (rebuildable from files + tags), the `emberweft flock generate|stitch|browse|rebuild|export-list` CLI, a Flock GUI area, a decoupled one-shot export (moved off the playback windows to a library-selection action), and a new `FlameFlock` module. Engine parity is unchanged (no edit under `Sources/FlameKit|FlameReference|FlameRenderer`) and animate-to-export byte-identity is preserved. **M6.6, resolution-independent framing** (standalone; complete in v0.6.1): a pure width normalization (`effectiveScale = scale × renderWidth / authoredWidth`) so every genome keeps its authored composition at every output resolution — flock archive, one-shot export, thumbnails, and previews; catalog schema v3 + `emberweft.framing` tag keep stitching from mixing framing modes; `animate` and the engines stay faithful. **M6.7, vertical/social presets** (standalone; complete, unreleased): the four social formats (720×1280, 1080×1920, 1080×1350, 1080×1080) across one-shot export and the flock archive via rotated swap-anchor framing — a portrait canvas rotates a landscape-authored genome +90° and anchors its authored height, so the authored composition carries sideways at exact scale (orientation derived from the canvas dims; portrait- and square-authored genomes never rotate); CLI `--resolution` social tokens + validated `WxH` (no silent 1080p fallback); flock framing gate 0/1/2 with catalog schema v4. M5 next.

> **How we build:** milestones describe *what* ships; the slice-by-slice build order, TDD methodology, GPU strategy, and oracle validation live in [development-approach.md](development-approach.md), and the test gates in [testing.md](testing.md). Milestones map to development slices as **M0→S0, M1→S1–S4, M2→S5, M3→S6–S7, M4→S8, M5→S9, M6→S10, M6.5→S10.5, M6.6→S10.6, M6.7→S10.7, M7→S11, M8→S12.**

## Milestones

### M0: Docs + Repo Scaffold ✅

**Goal:** Establish project foundation with comprehensive documentation and repository structure. (Slice S0.)

**Key deliverables:**
- Complete documentation set (all docs/*.md files)
- `git init` + repository structure (Sources, Tests, Resources)
- `Package.swift` with module targets: FlameKit, FlameReference, FlameRenderer, FlamePlayer, FlameExport + `emberweft` executable
- `LICENSE` (PolyForm-Noncommercial-1.0.0) + `LICENSE-SEEDS` (CC-BY-NC-4.0)
- `CONTRIBUTING.md` (CLA-before-external-PR note), `CLAUDE.md`, `.gitignore`
- CI workflow (GitHub Actions macOS runner): build + test + lint
- `swift-format` config + pre-commit hook
- README updated to "source-available" wording with build instructions

**Dependencies:** None (starting point)

**Definition of done:**
- All documentation files are substantive (no stubs or TODOs)
- Repository can be cloned and `swift build` succeeds
- CI runs green on an empty-but-compiling package
- README provides clear build/run instructions
- Documentation cross-references are complete and accurate

### M1: CPU Reference Renderer + CLI ✅

**Goal:** A correct, usable CPU renderer and CLI that produces a single still image from a `.flam3` file, validated against `flam3`. (Slices S1–S4.) This is a complete, shippable product slice on its own.

**Key deliverables:**
- **FlameKit**: genome model, `.flam3` parse/serialize, validation, temporal interpolation (S1)
- **FlameReference**: CPU renderer: chaos game → histogram → log-density → density-estimation filter → palette/gamma (S2)
- **Golden oracle harness**: dev-only `flam3` (built from source, no Homebrew formula); frozen genome set; PSNR/SSIM comparison (S3)
- **`emberweft` CLI**: `render` / `validate` / `info`, CPU backend (S4)

**Dependencies:** M0 complete

**Definition of done:**
- Parses `.flam3` files; rejects malformed input
- CPU renderer matches `flam3` goldens within thresholds (PSNR/SSIM: see [testing.md](testing.md))
- `emberweft render` works end-to-end on the CPU backend
- Same seed → identical frame (determinism)
- Single-frame CPU performance baseline recorded

### M2: Metal Renderer + Parity ✅

**Goal:** Port the renderer to Metal compute and prove it matches the CPU reference. (Slice S5.)

**Key deliverables:**
- **FlameRenderer (Metal compute)**: chaos-game/histogram kernel, density-estimation filter, palette/gamma
- `--backend cpu|metal` switch in the CLI
- **Parity tests**: Metal output vs FlameReference (statistical + PSNR)

**Dependencies:** M1 complete

**Definition of done:**
- Metal renderer matches the CPU renderer within parity thresholds (see [testing.md](testing.md))
- `--backend metal` produces correct stills
- Same seed → identical frame on Metal
- Metal single-frame performance baseline recorded; Metal-vs-CPU speedup measured

### M3: Animation and Realtime Pipeline ✅

**Goal:** Seamless looping sheep, smooth transitions between them, and realtime Metal playback with adaptive quality. (Slices S6–S7.)

**Two segment kinds (mirrors the original Electric Sheep):**
- **Loop**: animate a single sheep by **purely rotating the 2×2 linear part of each xform's pre-affine matrix through a full 360°** as a left-multiply `R(θ)·M`, θ = `blend·360°` (flam3 `sheep_loop`). The **palette is static** during a loop, seamless because `R(360°)·M = R(0°)·M` (not because of a palette wrap; palette motion exists only in transitions). Translation, post-affine, and camera are untouched; final xforms are skipped; non-final xforms rotate iff `animate ≠ 0`. This is structural motion of one genome via the same blend pipeline transitions use, and it animates still (single-keyframe) sheep. Frame budget (applied uniformly to all sheep since loops are generated live): **160 (~5.5–7 s) realtime**, **320 (~11–14 s) standard**, **900 (~15–39 s) premium**, following the ES evolution 128→160→320→900; played once then transitioned.
- **Transition**: a morph from genome A's parameters to genome B's over a short segment.

**Sequencing rule:** loops and transitions **alternate**: `loop(A) → transition(A→B) → loop(B) → transition(B→C) → …`. Transitions are always bracketed by loops; **never two transitions in a row**. This matches how the original Electric Sheep sequences its videos.

**Key deliverables:**
- **Loop playback**: animate each (still) sheep via flam3 `sheep_loop`: **purely rotate** each xform's pre-affine 2×2 0→360° (`R(θ)·M`) over `nframes` (seamless; palette static). Same blend pipeline as transitions.
- Genome interpolation for smooth **transitions** between genomes, **generated on the fly** from two still sheep (`sheep_edge(A, B)`); a similarity metric picks coherent pairs (stored ES edges are an optional curation oracle / classic-flock mode, not a render requirement: an edge is just its two endpoint stills) ([transitions.md](../rendering/transitions.md))
- `emberweft animate` (CLI) producing alternating loop/transition segments (S6)
- **FlamePlayer** realtime adaptive engine (S7)
- **FlameUI** Metal-layer wrapper (`CAMetalLayer`)
- Adaptive quality controller based on performance/thermal state
- Genome sequencing logic that alternates loop and transition segments per the rule above

**Dependencies:** M2 complete

**Definition of done:**
- A sheep's `sheep_loop` (pure 360° affine rotation; palette static) plays seamlessly (frame N = frame 0)
- Can play a sequence of genomes where loops and transitions alternate, with no two transitions consecutive
- Realtime **engine capability**: `FlamePlayer` sustains ≥ target fps for a bounded window under nominal thermal state (capability gate, baseline-recorded); absolute fps under real UI load is deferred to M4
- Adaptive-quality **controller logic** verified against simulated fps/thermal signals (deterministic gate); real thermal-throttle behavior verified manually (deferred to M4 as a hard gate)
- Transitions are visually smooth (no popping or discontinuities): objective continuity gate: genome-space `‖Δ‖` bounded + consecutive-frame PSNR ≥ 40 dB
- Unit tests for interpolation math (both within-genome loops and between-genome transitions); animated-frame parity (vs-flam3 ≥ 30 dB; Metal↔CPU ≥ 38 dB)

#### Post-M3 (v0.1.0): real-genome parity + motion blur
A post-M3 patch on `main` (not a new milestone: no new slices): closed the
real-genome vs-`flam3` density gap by parsing `highlight_power` and the spatial
filter radius from the genome (real still PSNR ~20 dB → **49–52 dB**), ported
motion blur as a faithful `temporal_samples` port on both backends
(`--temporal-samples N`), and added four more variations (`bubble`, `eyefish`,
`pie`, `radial_blur`). M3's synthetic goldens stay byte-identical and the
animation parity band (43–58 dB) is unchanged; see [CHANGELOG.md](../../CHANGELOG.md).

### M4: SwiftUI App and Library Browser ✅

**Goal:** Build the main application UI with library browsing, search, and playback controls. (Slice S8.)

> **Complete (v0.2.0 + v0.3.0).** v0.2.0 shipped the first slice: a SwiftUI app
> (`emberweft-gui`) with a thumbnail library browser (curated bundle + arbitrary
> folder), click-to-play realtime preview, persisted settings, an off-main Metal
> thumbnail render path (no UI freeze), and the `emberweft curate` offline ranking
> pipeline. v0.3.0 completed M4: a `NavigationSplitView` sidebar browser
> (All / Library / Liked / Imported / Folders), multi-select with bulk actions,
> tri-state sentiment (replacing rating + favorite + tags + notes), search + filter
> (sentiment / category / palette), drag-and-drop import, collections/playlists
> with drag reorder, Play as Sequence, and a non-modal playback window. All testable
> logic lives in the `EmberweftUI` library; `EmberweftGUI` is a thin SwiftUI shell.
> The M1–M3 engine is unchanged. See [CHANGELOG.md](../../CHANGELOG.md) for the full
> v0.3.0 entry.

**Key deliverables:**
- SwiftUI app structure (EmberweftApp target)
- Library browser with grid/list views
- Thumbnail generation for library entries
- Search and filter UI (tags, rating, palette)
- Playback view with transport controls
- Settings view (quality preferences, feature toggles)
- Metadata editor (edit genome title, tags, rating)
- Seed library with at least 20 curated genomes
- Drag-and-drop import of .flam3 files
- Bookmark/favorite system

**Dependencies:** M3 complete

**Definition of done:**
- App launches and displays seed library
- Can browse, search, and filter genomes
- Click-to-play from library
- Can import new genomes via drag-and-drop
- Settings are persisted and respected
- Thumbnails are generated and cached
- Basic accessibility support (VoiceOver labels)
- **Hard realtime gate (inherited from M3):** playback sustains target fps *(preliminary: 60 fps @ 1080p on M2 Max)* under real app UI/compositing load, and real thermal-throttle behavior is verified (the absolute-fps-under-UI-load and real-thermal items deferred from M3)

### M5: macOS Screensaver Bundle

**Goal:** Complete the screensaver bundle with settings and performance optimization. (Slice S9.)

**Key deliverables:**
- Complete ScreenSaver.framework integration
- Screensaver preferences panel
- Quality settings specific to screensaver
- App-group container sharing for seed library access
- Energy-efficient defaults (lower FPS, adaptive quality)
- Screen-sleep detection and respect
- Multi-monitor support (render on each display)
- Installation and testing on real screensaver

**Dependencies:** M4 complete

**Definition of done:**
- Screensaver installs and activates correctly
- Reads seed library from app-group container
- Plays smoothly *(preliminary: 30 fps on 1080p displays)*
- Settings panel works and persists preferences
- Respects screen sleep and system power events
- Tested on at least two displays (if available)

### M6: Export Pipeline ✅

> **Complete (v0.5.0).** v0.4.0 shipped the export **engine + `emberweft export`
> CLI** (H.264 + HEVC to MP4/MOV, long-form segment+concat, batch; frames
> byte-identical to `animate`; engine parity unchanged). v0.5.0 completes the
> milestone: the **GUI export studio** (sheet + non-blocking progress/ETA/cancel,
> three sources), **ProRes 422 HQ** mastering default, **off-main temporal Metal**
> (`renderTemporalOffMain`), **separate loop/transition durations + rotation
> velocity-matched easing**. Engine parity is
> unchanged (no renderer math touched; the export↔animate byte-identity pins
> hold). The vs-flam3 transition parity pin is `XCTSkip`'d: the owner decided
> the animation may improve on flam3's motion (renderer/determinism/Metal↔CPU
> parity unchanged). **M6.1 slice 1 (pause/resume) shipped v0.5.1:** export
> pause/resume + crash recovery (frame-count checkpointing + chunked-encode +
> concat; the interleaved per-frame render loop; GUI Pause/Resume/Discard; CLI
> `--checkpoint-frames`/`--resume`/`--discard`). Engine parity unchanged. See
> [CHANGELOG.md](../../CHANGELOG.md) and the spec/plan under
> `docs/superpowers/specs|plans/2026-08-08-m6.1-export-pause-resume*`. **M6.1
> slice 2 (temporal smoothing) shipped v0.5.2–v0.5.5:** export-only across-frame
> smoothing before the display pipeline kills the low-spp "tiny dots" flicker.
> v0.5.2: a CENTERED BOX window (revised from the original causal EMA: smooth
> from frame 1, no startup ramp, no lag), Metal via fused-chaos + atomicBuf
> readback (no new shader; existing fused cores byte-unchanged), per-chunk window
> + trivial resume (early-pause checkpoint fix). v0.5.3: quality tiers retuned
> (Draft/Standard/High = spp 8/30/100; uniform window h=5: free supersampling;
> Standard ≈ genome-default clean at ~33× the speed). v0.5.4–v0.5.5: temporal-
> samples defaults (named tiers default to single-pass; the quality tier auto-sets
> ts to 1/4/16/genome-default). OFF at genome-default + the mastering path.
> Engine parity + animate/export byte-identity unchanged. See the spec/plan
> (§Revision 2026-08-10) under `docs/superpowers/specs|plans/2026-08-09-m6.1-temporal-smoothing*`.

**Goal:** Implement video export with codec support and progress tracking. (Slice S10.)

**Key deliverables:**
- FlameExport module with AVFoundation integration
- Export pipeline coordinator
- Codec support (H.264 baseline, HEVC optional)
- Resolution and quality presets
- Export progress UI with cancellation
- Batch export (multiple genomes)
- Export settings (duration, resolution, codec, quality)
- Export validation (compare output to realtime rendering)

**Dependencies:** M4 complete (can proceed in parallel with M5)

**Definition of done:**
- Can export a single genome to MP4 (H.264)
- Can export a sequence with transitions
- Progress bar updates accurately
- Can cancel export mid-stream
- Exported video matches realtime rendering quality (determinism)
- At least 3 export presets (720p/1080p/4K)

### M6.5: Flock Archive + Stitching

> **Complete (v0.6.0, 2026-08-16).** A local archive of pre-rendered loop/edge
> videos plus Path A (Generate) and Path B (Stitch), so a long video composes in
> seconds once material is cached instead of the hours a one-shot export took.
> Engine parity is unchanged (no renderer math touched); animate-to-export
> byte-identity is preserved. Spec:
> [`docs/superpowers/specs/2026-08-12-m6.5-flock-archive-design.md`](../superpowers/specs/2026-08-12-m6.5-flock-archive-design.md);
> plan:
> [`docs/superpowers/plans/2026-08-12-m6.5-flock-archive.md`](../superpowers/plans/2026-08-12-m6.5-flock-archive.md).
> See [CHANGELOG.md](../../CHANGELOG.md) for the `[Unreleased]` entry. M5 (the
> screensaver) consumes this archive later (play pre-rendered loops/edges instead
> of live-rendering).

**Goal:** A local "flock archive" of pre-rendered loop and edge videos, with two
paths: **Generate** pre-bakes material into the archive, and **Stitch** composes a
long video from the archive (per-segment HIT uses the cached file; MISS renders
into the archive first), then a no-reencode `AVMutableComposition` passthrough
concat. Once a segment is rendered it is reused forever, so the "5-genome export
took 3 hours" problem collapses to seconds for cached material. (Slice S10.5,
standalone between M6 and M7.)

**Key deliverables:**
- The flock archive: ES-inspired 4-field naming
  (`<a_gen>=<a_id>=<b_gen>=<b_id>.<ext>`, loop = self-edge, no `edge_id`, cross-gen
  native), shard layout by resolution/fps/pace, per-artifact thumbnails, video
  metadata tags, and a user-configurable location (`AppPreferences.flockDir`).
- `flock.sqlite` catalog (`FlockCatalog`, a serialized-writer actor; source of
  truth, rebuildable from `mpeg/` filenames + embedded tags; one round-trip
  batched `IN(...)` lookup, no N+1).
- Id model: ES-sourced sheep keep their real `(gen,id)`; user/curated genomes get
  stable ids minted in reserved flock `900000`, deduped on source SHA-256.
- **Archive codec = HEVC (H.265) Main10, `.mov`** (~40% smaller than H.264, 10-bit,
  hardware encode/decode; decided empirically). Each segment is a fresh independent
  encode (IDR at frame 0); segments are never sliced from a longer render (slicing
  breaks HEVC POC/RPS at the cut).
- **Path A, Generate** (GUI + `emberweft flock generate`): pre-bake loops/edges
  into a shard, with the upgrade-overwrite rule (higher `quality_rank` overwrites;
  equal-or-lower is a hit/skip).
- **Path B, Stitch** (GUI + `emberweft flock stitch`): batch-lookup, miss-render-
  into-archive, passthrough concat; codec-uniformity and single-shard gates.
- `emberweft flock generate | stitch | browse | rebuild | export-list` CLI (the
  last writes the ES `<list>` XML interchange, recovering real `edge_id`s from
  `edges.sqlite`).
- Flock sidebar area (Generate / Stitch / Browse tabs) + a Settings, Flock panel.
- **Decouple one-shot export from the playback windows** (they become play-only;
  export becomes a library-selection action).
- New `FlameFlock` module (system `sqlite3`-linked; Apple SDKs only).

**Dependencies:** M4 complete (GUI) and M6 complete (the export render/encode
primitives, reused additively). Can proceed in parallel with M5; M5 consumes the
archive.

**Definition of done:**
- The Flock area (Generate / Stitch / Browse) is present and usable; Path A
  pre-bakes a collection's edges and Path B stitches a long video (fully cached
  stitches in seconds; uncached self-builds and is fast next time).
- Browse shows per-shard counts/size/thumbnails (paged), with delete and "Rebuild
  catalog".
- One-shot export is reachable from a library selection; the two playback windows
  have no Export button.
- `flockDir` is configurable and the archive survives relaunch.
- `emberweft flock generate | stitch | browse | rebuild | export-list` all work.
- Determinism + byte-identity pins green: per-artifact determinism (same
  `(shard,key,RenderSpec)` re-renders identical frames, SHA-256 seed via
  `Int(truncatingIfNeeded:)`); stitch byte-stability (same sequence + shard
  re-stitches identical output); a pair rendered twice yields one file.
- **Parity gate untouched:** no edit under `Sources/FlameKit|FlameReference|
  FlameRenderer` (`git diff --name-only main` empty for those dirs). The
  animate-to-export byte-identity pin stays green. The archive's smoothing-OFF
  path matches the export smoothing-OFF path frame-for-frame at the same
  `RenderSpec`.

### M6.6: Resolution-Independent Framing (Scale Normalization)

> **Complete (v0.6.1, 2026-08-18).** Engine parity unchanged (one pure
> `FlameKit.Framing` file; renderers byte-identical); animate↔export
> byte-identity preserved. Spec:
> [`docs/superpowers/specs/2026-08-17-m6.6-framing-normalization-design.md`](../superpowers/specs/2026-08-17-m6.6-framing-normalization-design.md);
> plan:
> [`docs/superpowers/plans/2026-08-17-m6.6-framing-normalization.md`](../superpowers/plans/2026-08-17-m6.6-framing-normalization.md).
> v0.6.1 also normalized framing in library thumbnails and both playback
> previews (follow-up folded into the release).

**Goal:** Render ES genomes at the same *authored framing* regardless of output resolution. A `.flam3` genome's `scale` is absolute pixels-per-unit, tuned for its authored `size` (gen-248: 800×592 / 1280×720 / 1920×1080 populations), so today the shard resolution *is* a 3× zoom — 720p reads "zoomed in", 4K "zoomed out". Data analysis of all 9,463 gen-248 sheep shows the authoring anchor is **width**: median `scale/width` is 0.326/0.333/0.330 across the three populations (2% spread) while `scale/height` differs 34%. M6.6 adds a pure width normalization (`effectiveScale = scale × renderWidth / authoredWidth`) applied to the flock archive and one-shot export (default on; `faithful` opt-out; `animate` and the engine stay untouched — parity gates and animate↔export byte-identity preserved via an explicit `framing` mode on `ExportSettings`). A `framing` exact-gate column + `emberweft.framing` tag keep normalized and legacy artifacts from mixing in stitches. (Slice S10.6, standalone between M6.5 and M7.)

**Key deliverables:**
- `FlameKit.Framing` — pure, deterministic width normalization helper (no renderer change; parity gate untouched).
- `ExportSettings.FramingMode` (`faithful` type-default / `normalized` product-default) threaded through one-shot export (`buildRenderContext`) and the flock archive (`ArchiveRenderer`), GUI + CLI.
- Catalog schema v3: `artifacts.framing` exact hit-gate + `emberweft.framing` mdta tag + rebuild parsing; legacy rows MISS and re-render.
- GUI: export sheet framing picker (Normalized default / Authored); Flock tabs always normalized.

**Dependencies:** M6.5 complete.

**Definition of done:**
- Same genome rendered at 720p/1080p/1440p/4K shows the same framing (identical subject fraction of frame)
- `animate` ↔ `export --framing faithful` byte-identity pins stay green; engine dirs (`FlameKit` renderer math, `FlameReference`, `FlameRenderer`) behaviorally unchanged
- Stitch never mixes framing generations (gate enforced, migration-tested)

### M6.7: Vertical / Social Presets

> **Complete (vNEXT, 2026-08-26).** Social formats (720×1280, 1080×1920,
> 1080×1350, 1080×1080) across one-shot export and the flock archive, with rotated
> swap-anchor framing: a portrait canvas rotates a landscape-authored genome
> +90° and anchors its authored height, so the authored composition carries
> sideways at exact scale (a 1920×1080 genome on 1080×1920 is factor 1.0).
> Portrait- and square-authored genomes are never rotated. Engine parity
> unchanged (`FlameKit.Framing.swift` only); animate↔export byte-identity
> preserved. Spec:
> [`docs/superpowers/specs/2026-08-25-m6.7-vertical-social-presets-design.md`](../superpowers/specs/2026-08-25-m6.7-vertical-social-presets-design.md);
> plan:
> [`docs/superpowers/plans/2026-08-25-m6.7-vertical-social-presets.md`](../superpowers/plans/2026-08-25-m6.7-vertical-social-presets.md).

**Goal:** Social video is 9:16 — TikTok, Instagram Reels, and YouTube Shorts want 1080×1920, and Instagram's feed portrait wants 4:5 (1080×1350) — but every resolution surface in Emberweft was landscape, and `.custom(w, h)` framed portrait as an unrotated width-anchored canvas: the authored composition in a horizontal band with empty field above and below. M6.7 adds the four social presets with **rotated swap-anchor framing**, extending M6.6's normalization semantics so the authored composition is preserved exactly with the authored aspect ratio becoming irrelevant to framing. Orientation is derived from the final canvas dims (never stored; `.custom` inherits it), and camera rotation is exactly the right transform: it is applied identically on both backends, pivots on `camera.center` (always the canvas midpoint), interpolates linearly through transitions, and is untouched during loops. A portrait canvas rotates a landscape-authored genome **+90°** and anchors its authored **height** (`effectiveScale = scale × canvasW / authoredH` — plain width-anchor would be a 1.78× zoom-out); portrait- and square-authored genomes are never rotated (identity / width anchor). (Slice S10.7, standalone, pulled forward from M8's "Vertical/social media presets" deliverable.)

**Key deliverables:**
- `FlameKit.Framing.apply(flame:renderWidth:renderHeight:normalized:)` — the orientation-aware sibling of `normalize`, taking a `normalized: Bool` flag (conditional rotation + swapped anchor behind the degenerate-header guard); `normalize` and the renderers untouched.
- Portrait `ExportSettings.Resolution` cases (720×1280, 1080×1920, 1080×1350, 1080×1080) with derived orientation, and **one shared pixel-band bitrate source** (`VideoEncoder.autoBitrate` + `ExportCoordinator.autoBitrateMbps` both delegate; `.custom` dims now match their named-preset tiers).
- CLI `--resolution` social tokens (`vertical720|vertical1080|portrait4x5|square1080`) + validated `WxH` (positive even integers, 16…7680 × 16…4320 — odd dims are silently cropped by VideoToolbox); unknown/invalid values exit 2 instead of silently rendering at 1080p; portrait `--frame --png` mastering.
- GUI: export-sheet tier entries (Vertical 720p/1080p, Portrait 4:5, Square 1080), Standard/Vertical shard-menu sections derived by orientation predicate, grouped Settings default-shard picker, letterboxed portrait browse thumbnails.
- Flock: the four portrait presets join `ShardPresets.sensible` (8 members); per-key framing gate **0/1/2** (legacy/faithful · normalized unrotated · normalized rotated) derived by one shared `FlockFramingGate` (canvas dims from the shard/row, never `settings.resolution`); catalog schema **v4** (a version re-stamp — old binaries are refused the whole archive; transactional migration steps); `rebuild` cross-checks each file's track `naturalSize` against its shard dims; `emberweft.framing` mdta carries the gate value.

**Dependencies:** M6.5/M6.6 complete.

**Definition of done:**
- FlameKit framing pins hold the whole orientation matrix: 16:9→9:16 normalized = factor 1.0 + rotation 90 (exact fit, zero bands); 4:3→9:16 anchor math; faithful portrait = rotation only; portrait-authored on portrait = identity/width anchor; square = no rotation; degenerate headers skip rotation too; landscape outputs identical to the M6.6 helper
- CLI parse tests (every token, malformed `WxH`, batch inheritance) + an end-to-end portrait PNG mastering test (exit 0, PNG 1080×1920)
- `Resolution` Codable round-trip; encoder ≡ precheck bitrate agreement incl. `.custom` twins (`720x1280` ≡ `vertical720`); VideoEncoder round-trip at the four dims × {h264, hevc} asserting track `naturalSize`
- Flock tests: v3→v4 migration (version re-stamp, no ALTER, rows unchanged; cascading v1→v4); gate HIT/MISS matrix (legacy landscape still HITs post-v4; portrait gate < 2 MISSes normalized portrait; square = gate 1) with four-site gate agreement; `naturalSize`-mismatch files are never cataloged; ShardPresets membership pins
- Engine parity untouched: `git diff main -- Sources/FlameKit Sources/FlameReference Sources/FlameRenderer` lists `Sources/FlameKit/Framing.swift` only; animate↔export byte-identity pins green
- Manual: a real A/B social render (rotation-direction taste check) before release

### M7: Music Video and Audio-Reactive Features

**Goal:** Add audio analysis and audio-reactive parameter modulation for music-video generation. (Slice S11.)

**Key deliverables:**
- Audio analysis module (beat detection, BPM, onsets)
- Audio-reactive renderer (modulate parameters based on audio)
- Real-time VJ mode (live audio input)
- Offline music-video export (audio file → synchronized video)
- Audio visualization modes (beat-sync, spectrum-based)
- Audio file import UI
- Parameter mapping UI (which genome parameters respond to which audio features)

**Dependencies:** M6 complete

**Definition of done:**
- Can import audio files and analyze them
- Beat detection accuracy >80% on test tracks *(preliminary)*
- Offline export produces synchronized music videos
- Real-time VJ mode responds to live audio within *(preliminary: 50 ms)*
- UI for customizing parameter mapping
- Example music-video exports for demo

### M8: Advanced Features

**Goal:** Add polish, advanced formats, and exploratory features. (Slice S12.)

**Key deliverables:**
- 4K and HDR support (10-bit color, HDR displays)
- Vertical/social presets — shipped in M6.7
- Local genetics/breeding system (if not completed earlier)
- Advanced export codecs (ProRes, AV1)
- Custom palette editor
- Genome comparison/diff view
- Performance optimization pass

**Dependencies:** M7 complete

**Definition of done:**
- 4K export at target fps on M2 Max
- HDR output validates on HDR display
- Vertical presets render at 1080×1920
- Genetics system allows mutation and breeding
- Custom palette can be created and saved
- Performance benchmarks meet targets
- Documentation is complete and up-to-date

## Milestone Dependencies

```
M0 (Foundation)
  ↓
M1 (CPU reference + CLI)
  ↓
M2 (Metal renderer + parity)
  ↓
M3 (Animation + realtime)
  ↓
M4 (SwiftUI app) ←───→ M5 (Screensaver)
  ↓
M6 (Export)
  ↓
M6.5 (Flock archive + stitching)
  ↓
M6.6 (Resolution-independent framing)
  ↓
M6.7 (Vertical/social presets)
  ↓
M7 (Audio-reactive)
  ↓
M8 (Advanced features)
```

**Parallel development:**
- M4 (app) and M5 (screensaver) can be developed in parallel after M3
- M6 (export) can proceed in parallel with M5
- M6.5 (flock archive) builds on M6 and can proceed in parallel with M5; M5 later consumes the archive
- M6.6 (framing normalization) builds on M6.5; the screensaver (M5) inherits normalized framing through the archive
- M6.7 (vertical/social presets) builds on M6.6; portrait shards extend the flock archive (new cache identities, fresh seeds)
- M7 and M8 are sequential and depend on all previous milestones

## Timeline and Prioritization

**No timeline commitment:** This roadmap defines milestone order and dependencies, but not specific dates or durations. Each milestone will be estimated based on progress and resources available.

**Prioritization principles:**
1. **Core rendering first:** M1 (CPU reference) and M2 (Metal) are the foundation: proven correct before anything else
2. **Realtime next:** M3 makes it move
3. **App before screensaver:** M4 before M5 for easier debugging
4. **Export before audio:** M6 before M7 for a simpler dependency chain
5. **Polish last:** M8 features can be deferred if needed

**Milestone completion criteria:**
- All key deliverables are implemented
- Definition of done checklist is satisfied
- Documentation is updated for the milestone
- No known regressions from previous milestones
- Basic performance targets are met

## Future / Exploratory

Features that may be explored after the core product is complete. These are **not committed** and may never be implemented: they represent potential directions if there is user interest and developer capacity.

**Community and sharing:**
- Import/export of curated genome packs
- Genome sharing via file or URL
- Collaborative breeding challenges

**Advanced rendering:**
- Stereoscopic 3D rendering
- VR headset support (visionOS)
- Multi-screen gallery installations
- Projection mapping support

**Generative / exploratory:** *(non-neural: these are search, curation, and heuristic tools, not AI models)*
- Assisted genome generation and curation tools
- Style transfer / palette matching between genomes
- Fitness heuristics for the local genetics system
- Quality prediction for batch rendering

**Platform expansion:**
- iOS/iPadOS app (with Metal rendering)
- Web version (WebGPU port)

**Creative tools:**
- Keyframe animation editor
- Custom variation editor (create new variations)
- Shader graph editor for advanced users

## Related Documentation

- [`development-approach.md`](development-approach.md): Methodology, build order (S0–S12), GPU strategy
- [`testing.md`](testing.md): Test methodology, oracles, CI gates
- [`../architecture.md`](../architecture.md): System architecture and module organization
- [`tech-stack.md`](tech-stack.md): Technology choices supporting the roadmap
- [`project-layout.md`](project-layout.md): Repository structure for milestone work
- [`performance.md`](performance.md): Performance targets for each milestone

---

**Credit**: fractal flame algorithm © Scott Draves (1992). Electric Sheep™ and Infinidream™ are trademarks of Scott Draves / e-dream, inc.
