# M3 — Animation & Realtime Pipeline (Design Spec)

> **Status:** design — for owner approval · Emberweft · 2026-07-17
> Companion to [roadmap.md M3](../../engineering/roadmap.md), [development-approach.md S6–S7](../../engineering/development-approach.md), [testing.md](../../engineering/testing.md), [transitions.md](../../rendering/transitions.md), [playback-modes.md](../../playback/playback-modes.md).

## Goal

Make the renderer **move**, faithfully to flam3 and the original Electric Sheep: seamless **loops** of a single still sheep, smooth **transitions** between two sheep, and a **realtime Metal playback engine** that plays an endless, strictly alternating loop→transition→loop sequence with adaptive quality. This is roadmap slices **S6** (CLI animation) and **S7** (realtime engine).

M3 is built on the proven M1/M2 core: per-frame, the renderer still consumes one `Flame` genome and produces one `RGBA8Image` via `ReferenceRenderer` (CPU) or `MetalRenderer` (Metal). **Animation is the layer that decides *which* `Flame` to feed per frame** — it does not change the chaos game, the display pipeline, or the parity model. This keeps M3 a clean, low-risk extension of the validated renderer.

## Owner decisions (locked during prior design conversation)

These were settled across the M3 design discussion (captured in [transitions.md](../../rendering/transitions.md) and the `m3-animation-design` memory) and are treated as locked inputs to this spec:

1. **Two segment kinds, faithfully ported from flam3** — `sheep_loop` (loop) and `sheep_edge` (transition), both driven by a single `blend ∈ [0,1]` parameter. *Quotable:* "we need to animate the still frames, using a similar methodology and visual appearance as the one used for edge animations — how does the original project do it?"
2. **Loops and transitions alternate; never two transitions in a row.** Every transition is bracketed by loops. *Quotable:* "we cannot have multiple transitions in a row."
3. **Stills are animated, not filtered/discarded.** Every archived sheep (all are single-frame stills) becomes a moving loop via `sheep_loop`. *Quotable:* "discarded from being used, not deleted from the archive" — and later superseded in favor of animating them.
4. **Transitions generated on the fly** from two still sheep; a stored ES edge carries no render information (it is just its two endpoint stills), so on-the-fly `sheep_edge(A,B)` reproduces the stored edge's frames. *Quotable:* "on-the-fly is definitely much better."
5. **Pair selection = similarity metric + exploration guard.** Pairs chosen for smooth morphs, but with an explicit escape mechanism (ε-greedy / long-range jumps) so playback is not trapped in one small cluster of sheep. *Quotable:* "we need to be careful that this would not restrict us to only a small subset of all the sheeps if we cannot exit the similarity."
6. **Tiered frame budget applied uniformly to all sheep** (loops are generated live, so a sheep's era does not constrain it): **160** (realtime), **320** (standard), **900** (premium). Loops are played **once**, then transitioned. *Quotable:* "We should use the best version of it, no matter if we use older classic sheeps or the latest ones" + "we also need the intermediate model, 320 frames."
7. **Faithful port, no source copy.** The `sheep_loop`/`sheep_edge` logic is ported (read) from `flam3-genome.c`; flam3 is **never** linked into or distributed with the repo. The animation parity oracle is dev-only `flam3-animate`, exactly analogous to the M1 golden harness. (Carries the faithful-port directive from M1/M2.)
8. **CPU and Metal remain statistical twins, not byte-identical** (M2 rule #2). Animated-frame parity inherits this: per-frame, Metal matches CPU within the existing ≥38 dB gate; the *interpolation math* lives in `FlameKit` and is byte-identical across backends.

## Open decisions (resolved with defaults — confirm at spec review)

These are the implementation-level choices the design docs left open. Each is given a reasoned default so the spec is plan-ready; flag any you want changed.

- **A. `emberweft animate` output = a deterministic PNG frame sequence** (`--out dir/`), not a video file. Rationale: video encoding is slice **S10 / M6** (`FlameExport`); S6 should ship the *schedule + frames*, not the muxer. A frame sequence + a `manifest.json` (segment boundaries, blend per frame) is testable, diffable, and directly feeds the future encoder. *Alternative:* also emit an MP4 now via AVFoundation — rejected as scope creep into M6.
- **B. S6 pair selection ships with the similarity metric from day one**, but behind a `PairSelector` protocol with a trivial `Sequential` implementation used first to TDD the *scheduler* and *interpolation* in isolation, then the real `SimilarityExploration` selector. This de-risks: the math is provable before the metric is tuned.
- **C. Palette cycle mechanism = faithful flam3 hue rotation** (the same `hue_rotation` flam3 loops use), **not** an ad-hoc HSV shift. Exact mechanism (hue-rotation matrix vs. index shift) is confirmed from `flam3-genome.c` during implementation and pinned by the `flam3-animate` oracle — both yield a seamless wrap, so the *behavior* (frame N ≈ frame 0) is settled even though the internal formula is a verify-against-oracle item.
- **D. Tier selection is a preset/mode**, not auto-chosen: realtime playback defaults to **160**, screensaver to **900**, export/user to a chosen tier. No magic.
- **E. Similarity feature vector (preliminary, tunable):** variation-set cosine similarity + palette mean-hue/mean-luma distance + xform-count difference + summed affine-matrix Frobenius distance, weighted. Exploration = ε-greedy with a repeat/recency penalty (avoid the last K sheep). Tuning constants are preliminary and marked `(preliminary)` in tests.

## Architecture

```
                       FlameKit (pure, deterministic — the animation brain)
   ┌─────────────────────────────────────────────────────────────────────────┐
   │  Loop.blend(sheep, t)            Transition.blend(A, B, t)               │
   │   = sheep_loop port               = sheep_edge port                      │
   │   (360° affine rotation +          (log/polar coefs, special-sauce       │
   │    palette cycle)                   padding, stagger, smooth)            │
   │                                                                         │
   │  SegmentScheduler  ──►  endless strictly-alternating stream:            │
   │     .loop(s) → .transition(s→s') → .loop(s') → …                        │
   │                                                                         │
   │  PairSelector (protocol): Sequential | SimilarityExploration            │
   │     (similarity metric + ε-greedy exploration guard)                    │
   │                                                                         │
   │  Schedule:  (segment, blend) per output frame, given a frame budget     │
   └─────────────────────────────────────────────────────────────────────────┘
          │  per frame: one interpolated Flame genome
          ├──────────────────────► ReferenceRenderer (CPU)   [parity oracle]
          └──────────────────────► MetalRenderer (Metal)     [production]

   S6:  emberweft animate  ──►  PNG frame sequence + manifest.json  (offline, deterministic)
   S7:  FlamePlayer (actor) + FlameUI (CAMetalLayer)  ──►  realtime @ target fps, adaptive quality
```

**Where things live:**

- **`FlameKit`** — the pure animation math (the whole top box). It is backend-agnostic and `Sendable`. This is the load-bearing, oracle-validated part of M3. New files: `Sources/FlameKit/Loop.swift`, `Transition.swift` (or `Animation.swift` consolidating both + padding), `SegmentScheduler.swift`, `PairSelector.swift`. The existing `Interpolation.swift` is **promoted**: its linear `interpolate` becomes the substrate that `Transition` wraps with log/polar + special-sauce padding; nothing in M1/M2 that calls it breaks.
- **`EmberweftCLI`** — adds `animate` (S6).
- **`FlamePlayer`** (currently a placeholder) — the realtime engine (S7).
- **`FlameUI`** — new (S7): a `CAMetalLayer`-backed view wrapper. (Architecture doc already names it; it does not yet exist as a target.)

### Current FlameKit state vs. what M3 adds (gap analysis)

| Capability | Current state (M2) | M3 work |
|---|---|---|
| Linear genome interpolation | ✅ `Interpolation.interpolate(a,b,t)` — coefs, weights, color, opacity, camera (scale in log-space), palette RGB blend, xform-count padding (extra xform passed through unchanged) | **Reused** as the linear substrate. |
| Interpolation type `log` (polar coefs) | ❌ coefs lerp linearly | **Add** polar/log coefficient interpolation (smooth rotation/scale morphs). |
| Special-sauce variation padding | ❌ missing xforms/vvars dropped or passed through | **Add** variation-specific rest positions (spherical/ngon/julian/juliascope/polar/wedge_* → `linear=-1,(-1 0 0 -1 0 0)`; rect/rings2/fan2/blob/supershape/curl/perspective → identity-with-rest-params; fan/rings kept). |
| `interpolation = smooth` (Catmull-Rom) | ❌ (n/a — single-segment) | **Add** for multi-keyframe sequences; a 2-keyframe A→B edge is effectively linear. |
| `stagger` (per-xform timing desync) | ❌ | **Add**. |
| `sheep_loop` (360° rotation + palette cycle) | ❌ | **Add** — the loop primitive. |
| Palette seamless cycle | ❌ (only flat RGB blend) | **Add** flam3 hue rotation (verify vs oracle). |
| Segment sequencing (alternation) | ❌ | **Add** `SegmentScheduler`. |
| Pair selection (similarity + exploration) | ❌ | **Add** `PairSelector`. |
| `emberweft animate` | ❌ (`render` only) | **Add** (S6). |
| Realtime engine / adaptive quality / Metal-layer UI | ❌ (placeholder) | **Add** (S7). |

## The math (behavior settled; internals verified against the oracle)

> **Faithfulness posture.** The *behavior* of each primitive is settled and grounded in flam3 source + wiki + Draves papers. The *exact per-xform rotation formula and palette mechanism* are faithful-port items — read from `flam3-genome.c`, written in Swift, and **pinned by byte/PSNR comparison against dev-only `flam3-animate` output**, exactly as M1's affine/atan bugs were pinned by the still-frame oracle. The spec asserts behavior; the plan asserts "port + oracle"; neither asserts unverified internals as fact.

### Loop — `sheep_loop`

Animate one still sheep by **rotating the 2×2 linear part of each xform's affine coefficient matrix through a full 360°** across `blend ∈ [0,1]`, while **cycling its palette** (flam3 hue rotation). Because 360° ≡ 0° and the palette wraps, **frame(blend=1) ≈ frame(blend=0)** → a seamless loop. This is the *structural motion of a single genome through the same `blend` pipeline transitions use*; it is what animates every still sheep in the archive.

- Applied to each xform's affine `a,b,c,d` (the linear part; `e,f` translation handled per flam3).
- Post-affine and final-xform handling follow flam3 exactly (verified against the oracle).
- Palette cycle via flam3 hue rotation (seamless by construction).

### Transition — `sheep_edge`

Morph genome A → B over `blend ∈ [0,1]`, following flam3's interpolation rules ([transitions.md §Transition interpolation fidelity](../../rendering/transitions.md)):

- **`interpolation_type = log`** (polar), not linear, so rotations/scaling morph smoothly instead of distorting through the linear path.
- **Special-sauce padding** for xform-count / variation mismatch (the table in the gap analysis above) — essential because our similarity-based pairing may pair structurally different sheep.
- **`stagger`** to desynchronize per-xform timing.
- **`interpolation = smooth`** (Catmull-Rom) for multi-keyframe sequences; a 2-keyframe A→B edge is a single segment, effectively linear.

### Sequencing — `SegmentScheduler`

An endless, **strictly alternating** stream. A transition is always bracketed by loops; the scheduler is a hard state machine, not a suggestion:

```
loop(A) → transition(A→B) → loop(B) → transition(B→C) → … → loop(N) → transition(N→A) → loop(A) → …
```

`blend` advances 0→1 over each segment's frame budget; at blend=1 the segment yields to the next. Loops are played **once**, then transitioned (ES: "a continuously morphing sequence").

### Pair selection — `PairSelector`

Protocol with two implementations:

- **`Sequential`** (test scaffold): round-robin / fixed order. Used first to prove scheduler + interpolation in isolation.
- **`SimilarityExploration`** (production): pick the next sheep by a similarity metric (feature vector, open decision E) **with an exploration guard** — ε-greedy: with probability ε pick a uniformly-random sheep from the whole library (the escape); otherwise pick the most-similar not-recently-used sheep. A recency penalty prevents immediate repeats. The escape probability guarantees the walk is **not trapped** in one cluster regardless of metric tuning.

`edges.sqlite` (the curated ES edge graph) is available as: (a) a **gold set** to validate/seed the similarity metric (do ES-linked pairs score as similar?), and (b) an optional **classic-flock playback mode** that follows the authored graph. It is **not** a render dependency.

### Frame budget

Per-segment frame count, applied uniformly (loops are generated live, so a sheep's era is irrelevant):

| Tier | Frames | ≈ Duration @ 23 fps | Use case |
|---|---|---|---|
| Realtime | 160 | ~5.5–7 s | default playback |
| Standard | 320 | ~11–14 s | intermediate dwell |
| Premium | 900 | ~15–39 s | screensaver / export / "stately" |

Both loops and transitions use the same budget. Configurable; adaptive transitions may run shorter/longer for similar/dissimilar pairs (post-MVP lever).

## Determinism

Animation inherits M1/M2 determinism and adds two guarantees:

1. **Per-frame genome is a pure function of `(schedule, frameIndex)`** — no wall-clock, no scheduling-dependent state. Same schedule + frame index → same `Flame` → same frame, within each backend, machine to machine.
2. **The schedule is a pure function of `(library, selector config, seed, tier)`** — `PairSelector` draws from a seeded RNG (FlameKit's existing `ISAAC`/`RNG`), so the *sequence of sheep* is reproducible. `flam3-animate` parity and `emberweft animate` byte-stable output both rest on this.

The interpolated `Flame` fed to the renderer is **byte-identical across CPU and Metal** (the math lives in `FlameKit`); only the subsequent chaos game differs statistically (M2 parity model).

## Parity & testing (the heart of M3)

The animation oracle is dev-only **`flam3-animate`** (Homebrew), set up exactly like the M1 still-frame golden harness: a checked-in script renders reference frames at frozen `blend`/genome points; `flam3` is never linked or distributed.

New tests (S6 lives mostly in `Tests/FlameKitTests/`; parity in `Tests/FlameReferenceTests/` + `Tests/FlameRendererTests/`):

| Test | Compares | Metric / threshold |
|---|---|---|
| `sheep_loop` seamlessness | frame(blend=0) vs frame(blend=1) of the same sheep | genome equality / near-equality; rendered frames within still-frame parity |
| `sheep_loop` vs `flam3-animate` | our loop frame at `blend=t` vs flam3's | **PSNR ≥ 38 dB** (faithful-port gate) |
| `sheep_edge` vs `flam3-animate` | our transition frame at `blend=t` vs flam3's | **PSNR ≥ 38 dB** |
| Transition continuity | consecutive frames across A→B | no popping; finite everywhere; per-frame Δ bounded |
| `log` interpolation type | rotation/scale morph path | smoothness vs linear (no distortion through origin) |
| Special-sauce padding | mismatched xform-count/variation pairs | morph does not pop; weight fades through the rest position |
| Scheduler alternation | any prefix of the schedule | invariant: no two consecutive `.transition` segments |
| PairSelector exploration | long schedule walk | visits ≥ X distinct sheep within Y segments (not trapped); reproducible under fixed seed |
| Determinism | full PNG frame sequence across runs | byte-identical |
| Animated-frame Metal↔CPU parity | per-frame `RGBA8Image` | **PSNR ≥ 38 dB, SSIM ≥ 0.95** over the frozen animated set |
| Finiteness | every animated frame | no NaN/Inf |
| CLI snapshot | `emberweft animate` frame sequence | byte-stable PNGs committed; manifest schema stable |

The frozen animation set reuses the existing `Tests/Goldens/genomes/` sheep plus a few representative A→B pairs (including a stored ES edge, to validate on-the-fly = stored-frame equivalence).

S7 adds performance/benchmark tests (regression guards, non-gating, `EMBERWEFT_PERF=1`): realtime fps at 1080p per tier, frame-time p50/p95/p99, adaptive-quality step behavior, mode-switch hysteresis.

## CLI (S6)

`emberweft animate <genome.flam3...> [opts]` — produces an alternating loop/transition PNG frame sequence.

```
emberweft animate a.flam3 b.flam3 c.flam3 \
  --out frames/ \
  --frames 160 \                  # per-segment budget (tier)
  --segments 5 \                  # how many segments to render (loop+transition pairs)
  --selector sequential \         # sequential | similarity   (similarity = SimilarityExploration)
  --seed 0 \
  --backend cpu|metal \
  --size WxH --quality N
```

Writes `frames/000000.png …` plus `frames/manifest.json` (`[{frame, segmentKind, sheepIndex, blend}]`) — the deterministic contract the future encoder (M6) consumes. Same exit-code/error conventions as `render`; same per-backend parity expectations.

## S6 vs S7 split

- **S6 — CLI animation (FlameKit + CLI).** The pure animation math (`sheep_loop`, `sheep_edge` with log/polar + special-sauce + stagger + smooth, palette cycle), `SegmentScheduler`, `PairSelector` (Sequential + SimilarityExploration), the `flam3-animate` parity oracle, animated-frame parity/continuity/determinism tests, and `emberweft animate`. **Ships a complete, oracle-validated, deterministic offline animation path.** This is the load-bearing slice.
- **S7 — Realtime engine (FlamePlayer + FlameUI).** An actor-isolated `FlamePlayer` that drives the scheduler at target fps, rendering each interpolated genome via `MetalRenderer`; a `CAMetalLayer`-backed `FlameUI` view; the adaptive-quality controller (iteration-budget feedback, thermal/power-aware, with the hysteresis already drafted in [playback-modes.md](../../playback/playback-modes.md)); triple-buffered frame pacing; prefetch of the upcoming sheep mid-loop. Perf benchmarks as regression guards.

S7 reuses the S6 scheduler/selector verbatim — it only adds the *realtime* rendering loop and quality adaptation. No animation math changes in S7.

## Docs updated as part of M3

- **[transitions.md](../../rendering/transitions.md)** — promote from "preliminary" to the implemented reality; reconcile the early "linear interpolation / smooth=0/1/2 table" draft sections with the faithful `log` + special-sauce + `sheep_loop` model (some early sections predate the flam3 grounding and now contradict the settled design — they are corrected, not kept).
- **[playback-modes.md](../../playback/playback-modes.md)** — confirm `SegmentScheduler`, tier presets, and the S7 adaptive-quality wiring as built.
- **[roadmap.md](../../engineering/roadmap.md)** — flip M3 to ✅ on completion; mark S6/S7 delivered.
- **[testing.md](../../engineering/testing.md)** — add the animation-parity test layer (the table above) and the `flam3-animate` oracle; record the ≥38 dB animated-frame gate.
- **[architecture.md](../architecture.md)** — add `FlameUI` target; describe `FlameKit` animation subsystem and the `FlamePlayer` realtime path as built.
- **`CLAUDE.md`** — already carries the M3 animation bullet; review on completion.
- **`CHANGELOG.md`** — M3 entry.

## Out of scope for M3 (deferred)

- Video muxing / codec / export UI — slice **S10 / M6** (`FlameExport`). S6 stops at the frame sequence + manifest.
- SwiftUI library browser, metadata editor, import — **M4**.
- Screensaver bundle, multi-monitor, power-event handling — **M5** (though S7's adaptive quality is the foundation M5 builds on).
- Audio-reactive parameter modulation — **M7**.
- HDR / 10-bit / ProRes / AV1 — **M8**.
- Faithful (non-approximation) density estimation — separate work (unchanged from M1/M2; radius=0 goldens don't exercise it, and the animation path doesn't depend on it).
- Variations beyond the M1 set of 19 — the special-sauce padding table covers the relevant ones; new variations are additive later.

## Risks & mitigations

- **Unverified flam3 internals (rotation formula, palette mechanism).** *Mitigation:* the `flam3-animate` oracle lands first; `sheep_loop`/`sheep_edge` are not "done" until parity passes. This is the same posture that caught the affine/atan bugs in M1.
- **`flam3-animate` availability/oracle drift.** *Mitigation:* mirror the M1 golden-harness approach — frozen reference frames checked in, dev-only regeneration script, no silent re-goldening.
- **Similarity metric traps playback in a cluster.** *Mitigation:* the ε-greedy escape is structural and tested (the "visits ≥ X distinct sheep in Y segments" test passes *before* metric tuning). Even a degenerate metric cannot trap the walk.
- **Special-sauce padding across mismatched pairs.** Our similarity pairing may pair structurally very different sheep (flam3's authored edges rarely did). *Mitigation:* padding is ported faithfully and exercised by a deliberate mismatched-pair continuity test; if a pair still pops, that is a metric-tuning problem (penalize structural distance more), not an algorithm failure.
- **Realtime fps at 1080p × 160-frame loops (S7).** *Mitigation:* per-frame cost is unchanged from M2 (animation adds only a cheap genome interpolation per frame); the adaptive-quality controller is the safety net. The 160-frame realtime tier is sized to M2's measured single-frame budget.
- **S6 scope creep into encoding.** *Mitigation:* open decision A explicitly bounds S6 at the frame sequence + manifest.
