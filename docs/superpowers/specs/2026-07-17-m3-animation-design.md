# M3 — Animation & Realtime Pipeline (Design Spec, v2 revised)

> **Status:** design — for owner approval · Emberweft · 2026-07-17 (revised after Principal-Engineer review + flam3 source research)
> Companion to [roadmap.md M3](../../engineering/roadmap.md), [development-approach.md S6–S7](../../engineering/development-approach.md), [testing.md](../../engineering/testing.md), [transitions.md](../../rendering/transitions.md), [playback-modes.md](../../playback/playback-modes.md).

## Goal

Make the renderer **move**, faithfully to flam3 and the original Electric Sheep: seamless **loops** of a single still sheep, smooth **transitions** between two sheep, and a **realtime Metal playback engine** that plays an endless, strictly alternating loop→transition→loop sequence with adaptive quality. This is roadmap slices **S6** (CLI animation) and **S7** (realtime engine).

M3 is built on the proven M1/M2 core: per-frame, the renderer still consumes one `Flame` genome and produces one `RGBA8Image` via `ReferenceRenderer` (CPU) or `MetalRenderer` (Metal). **Animation is the layer that decides *which* `Flame` to feed per frame** — it does not change the chaos game, the display pipeline, or the parity model.

> **v2 revision notes.** v1 deferred its load-bearing mechanics into "verified against the oracle." A Principal-Engineer review found 3 blockers; source research against `scottdraves/flam3` then established ground truth. This revision (a) corrects the loop model — **the palette is static during a loop, not cycled**; (b) scopes the oracle correctly — `flam3-genome` (generate) → `flam3-animate` (render), env-var driven, built from source; (c) adds a **prerequisite slice** (widen the data model + port the special-sauce variations); (d) fixes the manifest schema, the determinism claim, the parity thresholds, and the scheduler split. All flam3 citations below are stable `file:line` refs into the cloned `scottdraves/flam3` master.

## Owner decisions (locked)

1. **Two segment kinds, faithfully ported from flam3** — `sheep_loop` (loop) and `sheep_edge` (transition), both driven by a single `blend ∈ [0,1]`.
2. **Loops and transitions alternate; never two transitions in a row.** Every transition is bracketed by loops.
3. **Stills are animated, not filtered/discarded.** Every archived sheep (all single-frame stills) becomes a moving loop via `sheep_loop`.
4. **Transitions generated on the fly** from two still sheep; a stored ES edge is just its two endpoint stills, so on-the-fly `sheep_edge(A,B)` reproduces the stored edge's frames.
5. **Pair selection = similarity metric + exploration guard** (ε-greedy escape so playback is not trapped in one cluster).
6. **Tiered frame budget applied uniformly** (loops are generated live, so a sheep's era doesn't constrain it): **160 / 320 / 900**. Loops played **once**, then transitioned.
7. **Faithful port, no source copy.** `sheep_loop`/`sheep_edge` logic is ported (read) from `flam3-genome.c`/`flam3.c`; flam3 is **never** linked into or distributed with the repo. The animation oracle is a locally-built `flam3-genome`/`flam3-animate`.
8. **Add a prerequisite slice** (owner decision, this revision): widen `Variation` to carry parameters and add the `Flame`/`Xform` animation fields, and port the **16** special-sauce variations, **before** S6. The data model cannot support faithful transitions without it.

## Research-grounded facts (from `scottdraves/flam3` source) — these replace v1's hedged "to be verified" items

### Loop — `sheep_loop` is a pure affine rotation; the palette is STATIC
- `sheep_loop` (`flam3.c:396-429`) copies the parent, applies motion elements, then calls `flam3_rotate(result, blend*360.0, interpolation_type)` (`flam3.c:426`).
- `flam3_rotate` (`flam3.c:512-557`) touches **only the pre-affine 2×2** `c[0][0], c[0][1], c[1][0], c[1][1]` (XML `a,b,c,d`), via **left-multiplication `R(θ)·M`** (`flam3.c:551` `mult_matrix`, θ = blend·360°). Translation `e,f` (`c[2][*]`) is **never** touched; **post-affine and camera are untouched**; **final xforms are skipped unconditionally** (`flam3.c:540-542`).
- **Per-xform gate:** rotate iff `xform.animate != 0` (`flam3.c:521` — *replicate the code, not the contradictory comment on line 520*). Random xforms default `animate=1.0` (rotate); symmetry xforms `animate=0.0` (skip).
- **Padding xforms** rotate only under `interpolation_type=log` (the `//continue` at `flam3.c:536` is commented out under log; skipped under linear/compat/older).
- **Everything else is constant across loop keyframes:** `weight`, `color`, `color_speed`, `opacity`, `chaos`, `var[]`, **the palette**, and `hue_rotation`. **There is no palette cycling in `sheep_loop`.**
- **Seamlessness** comes purely from `R(360°)·M = R(0°)·M = M` → `frame(blend=1)` genome == `frame(blend=0)` genome. v1's "palette wraps" rationale is dropped.

> **Correction propagated to other docs.** roadmap.md M3, transitions.md, playback-modes.md, and CLAUDE.md all previously said "loop = rotate 360° + circular palette cycle." That is wrong; this revision corrects them to "loop = pure 360° affine rotation; palette static." (Palette motion exists **only in transitions**, via HSV LUT interpolation — see below.)

### Transition — `sheep_edge` (align → rotate both → interpolate)
`sheep_edge` (`flam3.c:434-508`): copies both parents into `prealign[]`, calls `flam3_align` (pads xforms to equal count + applies special-sauce), sets times 0 and 1, calls `establish_asymmetric_refangles`, **rotates both parents by `blend*360°`**, then `flam3_interpolate(spun, 2, smoother(blend), stagger, result)` (`flam3.c:487`) where `smoother(t) = 3t² − 2t³` (`interpolation.c:339-341`). So both endpoints are themselves spinning during the morph — the "continuously morphing" aesthetic.

### Interpolation modes & defaults (`flam3.h:67-73`)
- `interpolation` (temporal smoothing of the blend scalar): `linear=0` / `smooth=1`. **Default `linear`** (`flam3.c:1284`). (`sheep_edge` applies `smoother()` regardless, so a 2-keyframe edge is effectively eased.)
- `interpolation_type` (how xform matrices blend): `linear=0` / `log=1` / `compat=2` / `older=3`. **Default `log`** (`flam3.c:1312`). Log path = polar decomposition (angle + `log(magnitude)`, exponentiate) (`interpolation.c:657-679`). Post-matrix special case: if all parents' post is identity, result post forced identity (`interpolation.c:668-679`). Frames not at an exact control point and not adjacent to one are **forced to `linear` type** (`flam3-genome.c:740`).

### Palette in transitions
The 256-entry LUT is interpolated between the two parents in HSV space (`interpolate_cmap`, `interpolation.c:149-192`); modes `hsv`, `hsv_circular`, `rgb`, `sweep` (`flam3.h:75-78`); **default `hsv_circular`**. `hue_rotation` itself is linearly interpolated across keyframes (`INTERP(hue_rotation)`, `interpolation.c:478`). `hue_rotation` applied at palette-fetch time is an HSV hue shift: `hsv[0] += hue_rotation*6.0` (`palettes.c:176-178`).

### Special-sauce padding — VERIFIED table (`flam3_align`, `interpolation.c:768-1032`)
First, parametric-variation params (variation index ≥ 23) are copied from a neighbour genome that has the variation (`interpolation.c:812-844`). Then a rest position is chosen per padded xform:

| Group | Applies under | Variations (flam3 index) | Rest position |
|---|---|---|---|
| **A** | `log` only | spherical(2), polar(5), ngon(38), julian(32), juliascope(33), wedge_sph(79), wedge_julia(78) | `linear=-1`, coefs `[-1,0;0,-1;0,0]` (180° identity); **not renormalized** |
| **B** | all types | rectangles(40), rings2(26), fan2(25), blob(23), perspective(30), curl(39), super_shape(50) | `var=1.0` with rest params (rectangles `x=y=0`; rings2 `val=0`; fan2 `x=y=0`; blob `low=high=waves=1`; perspective `angle=0`, distance kept; curl `c1=c2=0`; supershape `n1=n2=n3=2, rnd=0, holes=0`, `m` kept); **renormalized** |
| **C** | all types | fan(22), rings(21) | `var=1.0` **AND** coefs `[0,1;1,0;0,0]` (90° swap); **renormalized** |
| **default** | all types | anything else | `linear=1.0` (identity) |

**v1 errors corrected:** Group C is NOT "kept" — it gets `var=1.0` + swap-affine + renormalization. Group B rest values are load-bearing (blob `1,1,1`; supershape `2,2,2`), not generic "0". **The faithful padder must implement exactly these 16 variations** (plus `linear` as fallback): indices 2, 5, 21, 22, 23, 25, 26, 30, 32, 33, 38, 39, 40, 50, 78, 79.

### stagger
Not a genome field — a render/interpolate parameter (`flam3.h:562`, threaded through `flam3_interpolate(... double stagger ...)`); in `flam3-animate` it comes from an env var, **default 0.0** (`flam3-genome.c:289`). Mechanism: `get_stagger_coef` (`interpolation.c:343-367`) gives each xform a staggered sub-interval of [0,1] with `smoother()` inside; applies **only for ncp==2, stagger>0, and not the final xform** (`interpolation.c:522-527`). Transitions only, never loops. **Model `stagger` as a render parameter, not a `Flame` field.**

### Oracle pipeline (the corrected parity backbone)
- **flam3 is not installed and has no Homebrew formula.** Build from source: autotools (`./configure && make`) with deps `zlib`, `libpng`, `libxml2` (`brew install libpng libxml2 zlib automake autoconf libtool`). Pin a repo commit.
- **No CLI flags** — everything is **env vars** (`flam3-genome.c:451-475`). Modes: `sequence` (whole loop+edge chain for N stills), `rotate` (one loop), `inter` (one edge, requires exactly 2 control points).
- Literal commands:
  ```
  # generate a full loop+edge motion genome for a list of stills:
  env sequence=stillA.flam3 nframes=160 flam3-genome > seq.flam3
  # generate one loop / one edge:
  env rotate=stillA.flam3 frame=80 nframes=160 flam3-genome > loop80.flam3
  env inter=pair.flam3    frame=80 nframes=160 flam3-genome > edge80.flam3
  # render the motion genome to a PNG sequence (with temporal oversampling / motion blur):
  env begin=0 end=160 prefix=out. flam3-animate < seq.flam3
  ```
- The harness generates reference motion genomes/frames with `flam3-genome`/`flam3-animate` and compares Emberweft's output. `flam3` is never linked or distributed.

## Open decisions (remaining; confirm at spec review)

- **A. `emberweft animate` output = a deterministic PNG frame sequence + `manifest.json`**, not a video (encoding is S10/M6). *Alternative:* emit MP4 now — rejected as scope creep.
- **B. S6 ships with the similarity metric from day one**, but behind a `PairSelector` protocol with a trivial `Sequential` impl used first to TDD the scheduler/interpolation in isolation, then `SimilarityExploration`.
- **C. Tier selection is a preset/mode** (realtime→160, screensaver→900, export→chosen), not auto-chosen.
- **D. Similarity feature vector (preliminary, tunable):** variation-set cosine + palette mean-hue/luma distance + xform-count difference + summed affine Frobenius distance, weighted; ε-greedy escape with recency penalty.

## Architecture

```
   PREREQUISITE SLICE (S6-pre): widen data model + port 16 special-sauce variations
   ┌─────────────────────────────────────────────────────────────────────────┐
   │  Flame:  + interpolation, interpolation_type(log), palette_interpolation,│
   │          + hue_rotation, palette_index0/1 + hue_rotation0/1 + palette_blend│
   │  Xform:  + animate(rotation gate), padding, wind[2]                      │
   │  Variation: + named parameters (curl_c1, blob_low, …) — NOT a var[] array │
   │  Port variations: spherical, polar, ngon, julian, juliascope, wedge_sph, │
   │    wedge_julia, rectangles, rings2, fan2, blob, perspective, curl,        │
   │    super_shape, fan, rings   (+ linear fallback)                          │
   └─────────────────────────────────────────────────────────────────────────┘
                       FlameKit (pure, deterministic — the animation brain)
   ┌─────────────────────────────────────────────────────────────────────────┐
   │  Loop.blend(sheep, t)            Transition.blend(A, B, t, stagger)       │
   │   = sheep_loop port               = sheep_edge port                       │
   │   (R(θ)·M, θ=t·360°; pre-affine   (align+special-sauce; rotate both;      │
   │    2×2 only; palette STATIC)       log/polar interp; smoother(t))         │
   │                                                                         │
   │  GenomeInterpolator (REWRITE of Interpolation.swift):                    │
   │     switch interpolation_type { .linear | .log(=polar) };                │
   │     thin interpolate(a,b,t) shim delegates to .linear (M1/M2 unbroken)   │
   │                                                                         │
   │  Schedule (pure, materializable, O(1) seekable by global frame):         │
   │     frame → (segmentId, kind, fromSheep, toSheep, blend)                 │
   │  PairSelector (protocol): Sequential | SimilarityExploration            │
   └─────────────────────────────────────────────────────────────────────────┘
          │  per frame: one interpolated Flame genome
          ├──────────────────────► ReferenceRenderer (CPU)   [parity oracle]
          └──────────────────────► MetalRenderer (Metal)     [production]

   S6:  emberweft animate  ──►  PNG frame sequence + manifest.json  (offline, deterministic)
   S7:  PlaybackDispatcher (actor) + FlameUI (CAMetalLayer)  ──►  realtime @ target fps, adaptive quality
```

### Gap analysis (current FlameKit vs. M3 needs) — revised

| Capability | Current (M2) | M3 work |
|---|---|---|
| `Variation` with named parameters | ❌ `{name, weight}` only | **Prerequisite:** add parameters |
| Special-sauce variations (16) | ❌ none implemented | **Prerequisite:** port the 16 |
| `Flame` animation fields | ❌ | **Prerequisite:** add `interpolation`/`interpolation_type`/`palette_interpolation`/`hue_rotation`/palette-hack |
| `Xform.animate` / `padding` / `wind` | ❌ | **Prerequisite:** add |
| Linear genome interpolation | ✅ `Interpolation.interpolate` | **Rewrite** as type-switched `GenomeInterpolator`; keep `.linear` shim |
| `interpolation_type=log` (polar) | ❌ | **Add** |
| Special-sauce padding (`flam3_align`) | ❌ | **Add** (verified table above) |
| `stagger` (render param) | ❌ | **Add** (render param, not a field) |
| `sheep_loop` (pure rotation) | ❌ | **Add** |
| Transition palette HSV interp | ❌ | **Add** |
| `Schedule` (pure, seekable) | ❌ | **Add** |
| `PairSelector` | ❌ | **Add** |
| `emberweft animate` | ❌ | **Add** (S6) |
| Realtime engine / adaptive quality / UI | ❌ (placeholder) | **Add** (S7) |

> **On "reuse Interpolation.swift":** v1 said "promote/reuse as a substrate." That was wrong — `Interpolation.interpolate`'s `mergeVariations` (drops zero-weight vars, re-sorts), xform-count padding (passes extras through unchanged), and one-sided `finalXform` fade are **all incorrect for `log` transitions**. It is a **rewrite** into a `GenomeInterpolator` with an `interpolation_type` switch; a thin `interpolate(a,b,t)` shim delegates to `.linear` so M1/M2 call sites compile and existing tests stay green.

## Prerequisite slice (S6-pre, before S6)

Owner-approved. Scope:

1. **Widen `Variation`** to carry named parameters (a keyed dictionary of `Double`, e.g. `["c1": 0, "c2": 0]` for curl), parsed from the flat `varN="value"` XML attributes (`parser.c`). `var[99]` holds weights only; params are separate.
2. **Add `Flame` fields:** `interpolation` (default `.linear`), `interpolationType` (default `.log`), `paletteInterpolation` (default `.hsvCircular`), `hueRotation` (default 0), and the transition palette-hack (`paletteIndex0/1`, `hueRotation0/1`, `paletteBlend`). **Add `Xform` fields:** `animate` (default 1.0), `padding`, `wind: SIMD2<Double>`. Extend the parser + serializer + round-trip tests.
3. **Port the 16 special-sauce variations** (+ keep `linear`): spherical, polar, rings, fan, blob, fan2, rings2, perspective, julian, juliascope, ngon, curl, rectangles, super_shape, wedge_julia, wedge_sph — each with its parameter set and faithful formula, added to `Variations.swift`/the Metal variation set, TDD'd per-variation like the M1 set.

This slice ships independently (no animation yet) and is verified by: round-trip parse/serialize of parametric genomes, per-variation unit tests, and the existing M1/M2 parity gates staying green.

## The math (behavior ported + cited; pinned by the oracle)

- **Loop:** `Loop.blend(sheep, t)` → for each non-final xform with `animate != 0`, set affine = `R(t·360°)·M` on the 2×2 only (translation, post, palette, color, weight, chaos unchanged). Padding xforms rotate only under `.log`. Output genome has `frame(t=1) == frame(t=0)`.
- **Transition:** `Transition.blend(A, B, t, stagger)` → `align(A,B)` (pad to equal count + special-sauce rest positions + copy parametric params from the neighbour that has them) → rotate both by `t·360°` → `interpolate(2cp, smoother(t), stagger)` with `.log` matrix blending and HSV palette interpolation.
- **Schedule:** a pure value computed from `(library, selectorConfig, seed, tier)`; materialized to a segment list with prefix-summed lengths so any global frame maps to `(segment, blend)` in **O(1)** (seekable, unlike a pull-iterator).
- **PairSelector:** `Sequential` (test scaffold) and `SimilarityExploration` (ε-greedy: with prob ε pick uniformly-random sheep = escape; else most-similar not-recently-used; recency penalty). `edges.sqlite` is a gold-set validator + optional classic-flock mode, not a render dependency.

## Determinism (G1/G2/G3 — split, do not conflate)

- **G1 — Schedule + per-frame genome:** a pure function of `(library, selectorConfig, seed, tier, frameIndex)`. Reproducible in **both S6 and S7**. The interpolated `Flame` is byte-identical across CPU and Metal.
- **G2 — S6 rendered frames:** byte-deterministic given backend + fixed quality (offline path).
- **G3 — S7 rendered frames:** **NOT byte-deterministic.** The adaptive-quality controller varies `samplesPerPixel` per frame from measured fps + `thermalState`, so the *image* depends on runtime state. Only the *genome* is reproducible; realtime↔offline parity is statistical over a fixed quality, not a per-frame identity. (v1 wrongly implied realtime frames were reproducible.)

## Parity & testing

Oracle = locally-built `flam3-genome`/`flam3-animate` (pipeline above), set up like the M1 still-frame harness.

| Test | Compares | Metric / threshold |
|---|---|---|
| `sheep_loop` seamlessness | `frame(t=0)` vs `frame(t=1)`, same sheep, same seed | genome equality; rendered frames within **Metal↔CPU parity** |
| `sheep_loop` vs `flam3-genome rotate` | our loop genome/frame vs flam3's | **PSNR ≥ 30 dB, SSIM ≥ 0.95** (vs-flam3, M1 precedent) |
| `sheep_edge` vs `flam3-genome inter` | our transition vs flam3's | **PSNR ≥ 30 dB, SSIM ≥ 0.95** (vs-flam3) |
| Special-sauce padding | mismatched pairs (incl. a stored ES edge) | morph does not pop; finiteness holds |
| Transition continuity (objective) | consecutive frames A→B | (a) genome-space `‖G(t+δ)−G(t)‖ < τ_g`; (b) image-space consecutive-frame **PSNR ≥ 40 dB** (transitions vary slowly) |
| Scheduler alternation | any schedule prefix | invariant: no two consecutive transitions |
| PairSelector exploration | long walk | visits ≥ X distinct sheep in Y segments; reproducible under fixed seed |
| Animated-frame Metal↔CPU parity | per-frame `RGBA8Image` | **PSNR ≥ 38 dB, SSIM ≥ 0.95** (Metal↔CPU gate — distinct from the vs-flam3 30 dB) |
| Determinism (G2) | full S6 PNG sequence across runs | byte-identical |
| Finiteness | every animated frame | no NaN/Inf |
| Near-singular affine during `log` morph | constructed degenerate pair | port flam3's determinant guard → fallback to linear; frames finite |
| CLI snapshot | `emberweft animate` sequence + manifest | byte-stable; manifest schema stable |

> **Threshold correction (v1 error):** v1 applied 38 dB to the flam3 comparison. testing.md sets the **flam3 oracle at ≥ 30 dB** (different RNG/filter) and **Metal↔CPU at ≥ 38 dB**. This revision splits them. Animated Metal↔CPU parity is neither harder nor easier than stills (same per-frame comparison), so 38 dB stands there.

S7 perf/adaptive tests (regression guards via `EMBERWEFT_PERF=1`): realtime fps at 1080p per tier, frame-time p50/p95/p99, adaptive-quality step + hysteresis. **Per the review, at least one fps gate and one thermal-step test are promoted to gating for S7** (or the roadmap DoD is renegotiated to "perf best-effort in M3, hard-gated in M4") — flagged for owner confirmation.

### Edge & degenerate-input handling (added per review)
- Empty/size-1 library → error exit (strict alternation needs ≥ 2 sheep).
- Malformed/unrenderable sheep mid-walk → skip-and-log with bounded retry; ε-greedy escape never hard-fails on one bad sheep.
- Similarity NaN (empty variation set → zero-norm vector) → cosine fallback ε.
- Near-singular affine in `log` interp → port flam3's determinant guard, fall back to linear.
- Realtime frame-budget overrun → display best-available histogram each vsync (accept noise); never hold/duplicate a frame during a transition.

## CLI (S6)

```
emberweft animate <still.flam3...> \
  --library <dir>          # default genomes/electric-sheep/sheep; precomputed feature-vector cache, not a 1.6 GB scan per run
  --out frames/ \
  --frames 160 \           # per-segment budget (tier)
  --segments 5 \
  --selector sequential \  # sequential | similarity
  --seed 0 \
  --backend cpu|metal \
  --size WxH --quality N
```

Writes `frames/000000.png …` + `frames/manifest.json`:

```json
{
  "manifestVersion": 1,
  "tier": 160, "seed": 0, "selector": "sequential",
  "frames": [
    { "frame": 0,   "segmentId": 0, "kind": "loop",       "fromSheep": 0, "toSheep": 0, "blend": 0.0,    "interpolationType": "log" },
    { "frame": 160, "segmentId": 1, "kind": "transition", "fromSheep": 0, "toSheep": 1, "blend": 0.0,    "interpolationType": "log" }
  ]
}
```

(`fromSheep == toSheep` for loops; both populated for transitions; `frame` is the global index; `blend` is the raw `t`.) This is the deterministic contract M6's encoder consumes.

## S6-pre / S6 / S7 split

- **S6-pre — prerequisite (FlameKit data model + variations).** Widen `Variation`/`Flame`/`Xform`, extend parser/serializer, port the 16 special-sauce variations. Verified by round-trip + per-variation tests + green M1/M2 gates.
- **S6 — CLI animation (FlameKit math + CLI).** `Loop`, `Transition` (with `log`/polar + special-sauce + stagger + smoother), `GenomeInterpolator` rewrite, `Schedule`, `PairSelector`, the `flam3-genome`/`flam3-animate` oracle, animated-frame parity/continuity/determinism tests, `emberweft animate`. **Ships a complete, oracle-validated, deterministic offline animation path.**
- **S7 — Realtime engine (PlaybackDispatcher + FlameUI).** An actor-isolated dispatcher driving the `Schedule` at target fps via `MetalRenderer`; `CAMetalLayer`-backed `FlameUI`; the adaptive-quality controller (iteration-budget feedback, thermal/power-aware, hysteresis per playback-modes.md); triple-buffered pacing; prefetch of the upcoming sheep mid-loop. Reuses S6's `Schedule`/`PairSelector` verbatim — no animation-math change in S7.

## Docs updated as part of M3

- **[transitions.md](../../rendering/transitions.md)** — promote to implemented reality; **drop the "circular palette cycle" loop claim** and the early draft sections (smooth=0/1/2 table, linear-interp rationale, renormalization, crossfade, quaternion) that contradict the faithful `log`+special-sauce+`sheep_loop` model; document the static-palette loop and HSV-transition palette.
- **[playback-modes.md](../../playback/playback-modes.md)** — correct the loop/palette wording; replace the stateful `SegmentScheduler` sketch with the pure `Schedule` (O(1) seekable) + S7 `PlaybackDispatcher`; confirm adaptive-quality controller wiring.
- **[roadmap.md](../../engineering/roadmap.md)** M3 — drop "circular palette"; flip M3 to ✅ on completion.
- **[testing.md](../../engineering/testing.md)** — add the animation-parity layer (table above) and the `flam3-genome`/`flam3-animate` oracle; record 30 dB (vs-flam3) vs 38 dB (Metal↔CPU).
- **[architecture.md](../../architecture.md)** — add `FlameUI`; describe the FlameKit animation subsystem + `PlaybackDispatcher`.
- **CLAUDE.md** — correct the M3 bullet's palette wording.
- **CHANGELOG.md** — M3 entry (incl. S6-pre prerequisite).

## Out of scope for M3 (deferred)

- Video muxing/codec/export UI — S10/M6. S6 stops at frame sequence + manifest.
- SwiftUI browser/metadata/import — M4. Screensaver/multi-monitor/power events — M5.
- Audio-reactive — M7. HDR/10-bit/ProRes/AV1 — M8.
- Temporal oversampling / motion blur (`flam3-animate`'s sub-frame sampling) — a fidelity refinement; S6 renders at exact `blend`. Flagged for a later pass.
- Variations beyond the M1-19 + the 16 special-sauce = 35 total — additive later.
- Faithful (non-approximation) density estimation — unchanged from M1/M2.

## Risks & mitigations

- **flam3 build/oracle availability.** *Mitigation:* S6-pre-adjacent task builds flam3 from source, pins the commit, and runs the literal env-var commands by hand once before any parity test depends on them.
- **Near-singular affine NaN in `log` morphs.** *Mitigation:* port flam3's determinant guard (fallback to linear); constructed-degenerate-pair test in the frozen set.
- **Similarity traps playback.** *Mitigation:* ε-greedy escape is structural and tested before metric tuning ("visits ≥ X distinct in Y segments").
- **Special-sauce across structurally different pairs.** *Mitigation:* verified table ported faithfully; mismatched-pair continuity test; if a pair still pops, that's metric tuning (penalize structural distance), not an algorithm failure.
- **Realtime fps at 1080p × 160-frame loops.** *Mitigation:* per-frame cost unchanged from M2 (animation adds a cheap genome interpolation); adaptive quality is the safety net; 160-tier sized to M2's measured single-frame budget.
- **Data-model widening ripple.** *Mitigation:* S6-pre lands first as an isolated, gate-keeping slice; M1/M2 stay green via the `.linear` interpolation shim and additive variation set.
