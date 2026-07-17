# M3 — Animation & Realtime Pipeline (Design Spec, v4 revised)

> **Status:** design — for owner approval · Emberweft · 2026-07-17 (v4: round-3 Principal-Engineer review + third flam3 source read)
> Companion to [roadmap.md M3](../../engineering/roadmap.md), [development-approach.md S6–S7](../../engineering/development-approach.md), [testing.md](../../engineering/testing.md), [transitions.md](../../rendering/transitions.md), [playback-modes.md](../../playback/playback-modes.md).

## Goal

Make the renderer **move**, faithfully to flam3 and the original Electric Sheep: seamless **loops** of a single still sheep, smooth **transitions** between two sheep, and a **realtime Metal playback engine** that plays an endless, strictly alternating loop→transition→loop sequence with adaptive quality. This is roadmap slices **S6** (CLI animation) and **S7** (realtime engine).

M3 is built on the proven M1/M2 core: per-frame, the renderer still consumes one `Flame` genome and produces one `RGBA8Image` via `ReferenceRenderer` (CPU) or `MetalRenderer` (Metal). **Animation is the layer that decides *which* `Flame` to feed per frame** — it does not change the chaos game, the display pipeline, or the parity model.

> **v2 revision notes.** v1 deferred its load-bearing mechanics into "verified against the oracle." A Principal-Engineer review found 3 blockers; source research against `scottdrakes/flam3` then established ground truth. This revision (a) corrects the loop model — **the palette is static during a loop, not cycled**; (b) scopes the oracle correctly — `flam3-genome` (generate) → `flam3-animate` (render), env-var driven, built from source; (c) adds a **prerequisite slice** (widen the data model + port the special-sauce variations); (d) fixes the manifest schema, the determinism claim, the parity thresholds, and the scheduler split. All flam3 citations below are stable `file:line` refs into the cloned `scottdraves/flam3` master.

> **v3 revision notes.** A second Principal-Engineer review (APPROVE-WITH-CHANGES) confirmed v1's blockers resolved at the CPU/spec level but found new issues; a second source read resolved the flam3-detail gaps. v3: (a) **F1** — the `Schedule` is **not** O(1)-seekable to arbitrary frames under `SimilarityExploration`; seek is O(1) within the materialized prefix, O(segments) to extend (two-level model); G1's purity signature amended; (b) **F2** — S6-pre now ports the 16 variations to **Metal** too (new `GPUXform` param channel + MSL mirror + host packer + stride), and the animated Metal↔CPU ≥38 dB gate is load-bearing in S6 on a mismatched-sheep transition; (c) **F3** — `stagger` added to G1's tuple and the manifest (default 0.0); (d) **F4** — `hueRotation` is a NEW field; existing `hueShift` (flam3 `hue`) is kept; (e) **F5** — feature-vector cache specified; (f) **F6** — temporal oversampling is disabled via **genome attrs** (`passes=1, temporal_samples=1`), not env vars; (g) **F7** — full `sheep_edge` step list + `wind` semantics; the palette-hack fields are **dead metadata and dropped** from the data model; (h) **F8** — M3 transitions use `.log` at the matrix level (the `:740` force-to-linear rule governs only `--animate` dense expansion, which Emberweft does not use); (i) **F9/F10** — edge cases expanded; flam3-build fallback = auto-skip vs-flam3 tests.

> **v4 revision notes.** A third Principal-Engineer review (APPROVE-WITH-CHANGES) confirmed F1–F10 resolved and coherent, but found specification-precision gaps (no rework): (a) **G1 determinism bug** — Swift `Dictionary<String,_>`/`Set<String>` hashing is per-process randomized, so any FP accumulation over variation-name-keyed data is nondeterministic across launches → G1's "byte-reproducible" was literally false; **v4 adds a hard determinism rule** (sorted-order accumulation) + a cross-process bit-identical test; (b) **`GPUXform` param-channel layout** — was an "e.g."; **v4 pins it** to a concrete table (MAX_PARAMS_PER_SLOT=6, device slot width 8, per-variation ordered param table with names/defaults/rest/XML-attrs); (c) **unpinned thresholds** (`X`/`Y`, `τ_g`, S7 fps-floor) — **v4 pins concrete numbers**; (d) minor cleanups — `hueShift` declared round-trip-only, feature-cache rebuild trigger specified, `interpolationType` nulled on loop manifest rows.

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
- **Seamlessness** is the idealization `R(360°)·M = R(0°)·M = M`. In IEEE-754 it holds only approximately (`cos(2π) ≈ 1−5e-16`), and flam3's `flam3_rotate` computes `sin`/`cos` of `DEG2RAD(blend*360°)` directly (it does **not** reduce θ mod 2π), so `frame(blend=1)` differs from `frame(blend=0)` by ~1e-15 per coefficient — the port matches this exactly. The gate is therefore a per-coefficient tolerance (`‖Δ‖ < 1e-12`) plus a rendered visible-seamlessness check (PSNR ≥ 38 dB between frame 0 and frame N), not genome byte-equality. v1's "palette wraps" rationale is dropped.

> **Correction propagated to other docs.** roadmap.md M3, transitions.md, playback-modes.md, and CLAUDE.md all previously said "loop = rotate 360° + circular palette cycle." That is wrong; this revision corrects them to "loop = pure 360° affine rotation; palette static." (Palette motion exists **only in transitions**, via HSV LUT interpolation — see below.)

### Transition — `sheep_edge` (full step list; ports `flam3.c:434-508` + `spin_inter`)
`Transition.blend(A, B, t, stagger)` reproduces `sheep_edge` step-for-step. Ordered contract (every flam3 function named, observable effect stated):

1. **Clone** both parent stills into working genomes (`flam3_copy`, `flam3.c:455`); fold any motion-element offsets at this `t` (`flam3.c:457-460`).
2. **`flam3_align(spun, prealign, 2)`** (`flam3.c:471`, def `interpolation.c:768`) — pad both to equal xform + final-xform count; copy **parametric-variation defaults from the populated side into blank/padded xforms** (`interpolation.c:812-844`); apply the special-sauce rest positions (table below). No-op for `compat`/`older`.
3. **Normalize times** to `{0, 1}` (`flam3.c:473-474`).
4. **`establish_asymmetric_refangles(spun, 2)`** (`flam3.c:477`, def `interpolation.c:710`) — writes **only `xform.wind[col]`** (`interpolation.c:759,761`), not coefs. For an xform symmetric on one side / animated on the other (sym = `animate==0` or padding), it stores the symmetric side's column angle `+2π` into `wind`. This anchors the log-rotation unwrap so an animating xform next to a symmetric/padded one does not spin the wrong way at the ±π seam.
5. **Rotate both endpoints** by `t·360°` via `flam3_rotate` (`flam3.c:480-481`): each animating (`animate!=0`) non-final xform's affine 2×2 left-multiplied by `R(θ)·M`. Padded xforms rotate only under `.log`.
6. **`flam3_interpolate(spun, 2, smoother(t), stagger, result)`** (`flam3.c:486-487`) where `smoother(t)=3t²−2t³` (`interpolation.c:339-341`). **`.log` matrix branch** (`interpolation.c:657-699`, via `convert_linear_to_polar` + `interp_and_convert_back`): polar decomposition — magnitude interpolated linearly, angle interpolated with the **`wind`-anchored unwrap** (`interpolation.c:293-309`). Post-matrix special case: if all parents' post is identity, result post forced identity.
7. **Palette blend** happens inline in `flam3_interpolate_n` (`interpolation.c:377-427`) on the resolved `palette[256]` RGB arrays of the two endpoints (HSV/hsv_circular; see Palette below). **The `palette_index0/1`, `hue_rotation0/1`, `palette_blend` fields are dead metadata** (written once in `spin_inter`, never read) — Emberweft does **not** model them.
8. Strip motion elements; return the interpolated control point.

> **F8 — `.log`, not `.linear`.** The ES generation default is `interpolation_type = log` (`flam3.c:1312`) and `sheep_edge` does not override it. The `flam3-genome.c:740` force-to-linear rule governs **only** the `--animate` dense-expansion tooling (frames neither keyframes nor immediately-before-a-keyframe); a 2-control-point edge has no interior integer frames, so the rule never fires for it. Emberweft does not use dense expansion, so **M3 transitions use `.log` at the matrix level** (polar magnitude + `wind`-anchored angle).

### Interpolation modes & defaults (`flam3.h:67-73`)
- `interpolation` (temporal smoothing of the blend scalar): `linear=0` / `smooth=1`. **Default `linear`** (`flam3.c:1284`). (`sheep_edge` applies `smoother()` regardless, so a 2-keyframe edge is effectively eased.)
- `interpolation_type` (how xform matrices blend): `linear=0` / `log=1` / `compat=2` / `older=3`. **Default `log`** (`flam3.c:1312`). Log path = polar decomposition (`convert_linear_to_polar`: magnitude + angle, with the **`wind`-anchored unwrap** `interpolation.c:293-309`; exponentiate on the way back). Post-matrix special case: if all parents' post is identity, result post forced identity (`interpolation.c:668-679`). *(The `flam3-genome.c:740` force-to-linear rule applies only to `--animate` dense expansion of sparsely-spaced CPs; Emberweft does not use that path — see F8 above — so transitions are `.log`.)*

### Palette in transitions
The render-time palette blend is **inline in `flam3_interpolate_n`** (`interpolation.c:377-427`) on the two endpoints' already-resolved `palette[256]` RGB arrays — governed by `palette_interpolation` (`sweep`/`rgb`/`hsv`/`hsv_circular`, `flam3.h:75-78`; **default `hsv_circular`**) and `hsv_rgb_palette_blend` (`flam3.h:456`, consumed at `interpolation.c:384`). `hue_rotation` is linearly interpolated across keyframes (`INTERP(hue_rotation)`, `interpolation.c:478`); at palette-fetch time it is an HSV hue shift `hsv[0] += hue_rotation*6.0` (`palettes.c:176-178`). *(Note: `interpolate_cmap` `interpolation.c:149` is parse-time only — it resolves old-format `<palette>` gradient-index tags into the 256-LUT; it is NOT part of animate/render. The `palette_index0/1`+`hue_rotation0/1`+`palette_blend` quadruple is dead metadata — see Transition step 7.)*

> **F4 — `hueRotation` vs `hueShift`.** `hueRotation` is a NEW field for flam3's `hue_rotation` (above) — the **live** field consumed by transition palette HSV interpolation. The existing `Flame.hueShift` (flam3's `hue` attribute, `Flam3Parser.swift`) is a **different** field, retained for **round-trip fidelity only** — it is not consumed by the M1/M2/M3 render path (confirmed: neither `ReferenceRenderer` nor the MSL `displayPipeline` reads it). Parser reads both attributes; serializer emits both. Do not wire `hueShift` into the palette path (it would double-apply hue and break the vs-flam3 gate on saturated palettes).

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
Not a genome field — a render/interpolate parameter (`flam3.h:562`, threaded through `flam3_interpolate(... double stagger ...)`); in `flam3-animate` it comes from an env var, **default 0.0** (`flam3-genome.c:289`). Mechanism: `get_stagger_coef` (`interpolation.c:343-367`) gives each xform a staggered sub-interval of [0,1] with `smoother()` inside; applies **only for ncp==2, stagger>0, and not the final xform** (`interpolation.c:522-527`). Transitions only, never loops. **F3: `stagger` is part of the per-frame genome function, so it is recorded in the G1 purity tuple and the manifest top-level (default 0.0) — a run with non-zero `stagger` is reproducible only if `stagger` is replayed.** Modeled as a render/run parameter, not a `Flame` field.

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
- **F6 — temporal oversampling must be DISABLED for clean parity.** `flam3-animate`'s motion blur is always on; it is controlled by **genome attributes**, not env vars: `passes` (default 1) × `temporal_samples` (default **1000** → ~1000 sub-samples/frame across a ±0.5-frame window — substantial blur on fast-moving frames) (`rect.c:645`, `flam3.c:1309-1310`). To render non-motion-blurred frames, set **`passes="1"` and `temporal_samples="1"`** on every control point → `numsteps==1` → single sample at exact time (`filters.c:423-430`). Apply via a flam3 template (`flam3_apply_template`, `flam3.c:1581`). Without this, the ≥30 dB vs-flam3 gate would fail systematically on transition interiors (motion-blur signal, not a port bug).

## Open decisions (remaining; confirm at spec review)

- **A. `emberweft animate` output = a deterministic PNG frame sequence + `manifest.json`**, not a video (encoding is S10/M6). *Alternative:* emit MP4 now — rejected as scope creep.
- **B. S6 ships with the similarity metric from day one**, but behind a `PairSelector` protocol with a trivial `Sequential` impl used first to TDD the scheduler/interpolation in isolation, then `SimilarityExploration`.
- **C. Tier selection is a preset/mode** (realtime→160, screensaver→900, export→chosen), not auto-chosen.
- **D. Similarity feature vector (preliminary, tunable):** variation-set cosine + palette mean-hue/luma distance + xform-count difference + summed affine Frobenius distance, weighted; ε-greedy escape with recency penalty.

## Architecture

```
   PREREQUISITE SLICE (S6-pre): widen data model + port 16 special-sauce variations (CPU + Metal)
   ┌─────────────────────────────────────────────────────────────────────────┐
   │  Flame:  + interpolation, interpolation_type(log), palette_interpolation,│
   │          + hue_rotation   (palette-hack fields are DEAD metadata — skip) │
   │  Xform:  + animate(rotation gate), padding, wind[2]                      │
   │  Variation: + named parameters (curl_c1, blob_low, …) — NOT a var[] array │
   │  Port variations (CPU Variations.swift + Metal Kernels.metal):           │
   │    spherical, polar, ngon, julian, juliascope, wedge_sph, wedge_julia,   │
   │    rectangles, rings2, fan2, blob, perspective, curl, super_shape,       │
   │    fan, rings   (+ linear fallback)                                       │
   │  Metal: GPUXform + param channel + host packer + stride bump (F2)        │
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
   │  Schedule (pure; two-level seek — F1):                                    │
   │     global frame → (segmentId, blend) is O(1) (constant tier lengths);   │
   │     segmentId → (fromSheep, toSheep) needs the selector walk materialized│
   │     → O(segments) to extend forward, reproducible (not O(1))             │
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
| Special-sauce variations (16) — **CPU + Metal** | ❌ none implemented | **Prerequisite:** port the 16 to both backends (F2) |
| `Flame` animation fields | ❌ | **Prerequisite:** add `interpolation`/`interpolation_type`/`palette_interpolation`/`hue_rotation` (palette-hack is dead — skip) |
| `Xform.animate` / `padding` / `wind` | ❌ | **Prerequisite:** add (`wind` is load-bearing for log unwrap) |
| Linear genome interpolation | ✅ `Interpolation.interpolate` | **Rewrite** as type-switched `GenomeInterpolator`; keep `.linear` shim |
| `interpolation_type=log` (polar) | ❌ | **Add** |
| Special-sauce padding (`flam3_align`) | ❌ | **Add** (verified table above) |
| `stagger` (render param) | ❌ | **Add** (render param, in G1 tuple + manifest, not a field) |
| `sheep_loop` (pure rotation) | ❌ | **Add** |
| Transition palette HSV interp | ❌ | **Add** |
| `Schedule` (pure; two-level seek) | ❌ | **Add** |
| `PairSelector` | ❌ | **Add** |
| `emberweft animate` | ❌ | **Add** (S6) |
| Realtime engine / adaptive quality / UI | ❌ (placeholder) | **Add** (S7) |

> **On "reuse Interpolation.swift":** v1 said "promote/reuse as a substrate." That was wrong — `Interpolation.interpolate`'s `mergeVariations` (drops zero-weight vars, re-sorts), xform-count padding (passes extras through unchanged), and one-sided `finalXform` fade are **all incorrect for `log` transitions**. It is a **rewrite** into a `GenomeInterpolator` with an `interpolation_type` switch; a thin `interpolate(a,b,t)` shim delegates to `.linear` so M1/M2 call sites compile and existing tests stay green.

## Prerequisite slice (S6-pre, before S6)

Owner-approved. Scope:

1. **Widen `Variation`** to carry named parameters (a keyed dictionary of `Double`, e.g. `["c1": 0, "c2": 0]` for curl), parsed from the flat `varN="value"` XML attributes (`parser.c`). `var[99]` holds weights only; params are separate.
2. **Add `Flame` fields:** `interpolation` (default `.linear`), `interpolationType` (default `.log`), `paletteInterpolation` (default `.hsvCircular`), `hueRotation` (default 0). **Do NOT** add the palette-hack fields (`paletteIndex0/1`, `hueRotation0/1`, `paletteBlend`) — they are dead metadata (F7). **F4:** `hueRotation` is new; the existing `hueShift` (flam3 `hue`) is kept unchanged. **Add `Xform` fields:** `animate` (default 1.0), `padding`, `wind: SIMD2<Double>` (default 0; load-bearing — anchors `.log` unwrap for asymmetric xform pairs). Extend parser + serializer + round-trip tests.
3. **Port the 16 special-sauce variations** (+ keep `linear`) to **both backends** (F2): spherical, polar, rings, fan, blob, fan2, rings2, perspective, julian, juliascope, ngon, curl, rectangles, super_shape, wedge_julia, wedge_sph — each with its parameter set + faithful formula.
   - **CPU:** add to `Variations.swift`, TDD'd per-variation like the M1 set.
   - **Metal (F2):** `GPUXform` currently has `varWeights` (19-float tuple) and **no parameter channel** (`MetalHost.swift`, `Kernels.metal`). Add the per-slot parameter block + its MSL mirror, the host packer (name→index map), and bump the `GPUXform` stride assertion — **layout fully pinned in the "Param-channel layout" subsection below** (MAX_PARAMS_PER_SLOT=6, device slot width 8, per-variation table). Port the 16 MSL variation functions. This is mandatory here (not S7): S7 renders transitions via Metal, and special-sauce padding instantiates parametric variations in padded xforms — without the Metal port, S7 cannot render any mismatched-sheep transition.

**S6-pre gates:** (a) round-trip parse/serialize of parametric genomes; (b) per-variation CPU unit tests; (c) **the existing M2 Metal↔CPU parity gate stays green** AND a fuzz run that **excludes the 16 new names** (proving the widening is additive, not a regression); (d) per-variation **Metal↔CPU parity** for each of the 16 on a constructed genome. If the flam3 build is unavailable, the vs-flam3 tests auto-skip (F10); Metal↔CPU remains the hard gate.

### Param-channel layout (F2 — pinned, not "e.g.")
The `GPUXform` extension is structurally clean against the real code: today it is `6 (pre-affine) + 6 (post) + 3 (color/colorSpeed/opacity) + 19 (varWeights) = 34` floats, stride 136 B, asserted at `MetalHost.swift:74` and mirrored in `Kernels.metal:128-133`. The selection logic (`distrib[isaac_next & CHAOS_GRAIN_M1]`) is host-precomputed and untouched. **RNG-alignment caveat (verified against `variations.c`):** of the 16 special-sauce variations, **4 consume the ISAAC stream** — `julian` (`var32_juliaN_generic`), `juliascope` (`var33_juliaScope_generic`), `super_shape` (`var50_supershape`, draws **unconditionally** even when `super_shape_rnd==0`), and `wedge_julia` (`var78_wedge_julia`) — each one `flam3_random_isaac_01` draw. They must be threaded with the RNG exactly as the existing `julia` is (CPU `evaluate` special-case + MSL `thread IsaacState&`, one draw in the same order). Additionally `rings` (21) and `fan` (22) are **coefficient-dependent** (they read the affine translation `e`/`f`), so their closures take the xform's `e,f`. RNG alignment therefore holds **only if** the draw order matches CPU genome-order; the canonical-slot if-chain must evaluate each RNG-consuming slot in the same order the CPU does (a multi-RNG-variation parity test gates this). The blast radius is: the struct grows a params block, the host packer gains a name→index map, and the MSL `apply_xform_body` if-chain grows from 19 to **33** guarded lines (the 19 + the **14 NEW** special-sauce — `spherical`/`polar` are already in the 19, so the unique count is 33, not 35).

- **`MAX_PARAMS_PER_SLOT = 6`** (driven by `super_shape`: rnd, m, n1, n2, n3, holes). **Device slot width = 8 floats** (6 params + 2 spare for natural float4 alignment and an optional per-slot weight/index tag without a second bind).
- **Device layout:** append `float varParams[NUM_XFORM_SLOTS][8]` to `GPUXform`; bump the stride assertion on both Swift and MSL sides. `varWeights` (the 99-entry weight array) stays a separate channel.
- **Host packer:** maps each xform's `Variation.parameters: [String:Double]` into positional `varParams[slot][index]` via a **compile-time, fixed name→(slot,index) table per variation** (below). Unused tail slots are zeroed; the shader indexes by the same table, so unused reads are harmless.
- **Parameterless variations** (linear, spherical, polar, rings, fan) consume no param slot — only a weight entry.
- **Precache fields** (e.g. `persp_vsin`, `julian_rN`, `super_shape_pm_4`) are NOT user params — they are host-computed or computed on-device; do not slot them as inputs.
- **Clamp rules** propagate to the right layer: `super_shape_rnd` clamped to [0,1] (`parser.c:1076-1079`) in the packer; flam3 EPS guards (`rings2_val²+EPS`, `fan2_x²+EPS`, curl denominator) in the kernel.

**Per-variation param table** (XML attr == struct field name for all 12; source-cited to `flam3.h` / `parser.c` / `variations.c`). "rest" = special-sauce value from `flam3_align` (`interpolation.c`); "—" = stays at flam3 default (Group A variations get rotated-identity affine only, no param rest):

| variation (idx) | param / XML attr | default | rest | slot index |
|---|---|---|---|---|
| **blob** (23) | `blob_low` | 0.0 | **1.0** | 0 |
| | `blob_high` | 1.0 | **1.0** | 1 |
| | `blob_waves` | 1.0 | **1.0** | 2 |
| **curl** (39) | `curl_c1` | 1.0 | **0.0** | 0 |
| | `curl_c2` | 0.0 | **0.0** | 1 |
| **rectangles** (40) | `rectangles_x` | 1.0 | **0.0** | 0 |
| | `rectangles_y` | 1.0 | **0.0** | 1 |
| **fan2** (25) | `fan2_x` | 0.0 | **0.0** | 0 |
| | `fan2_y` | 0.0 | **0.0** | 1 |
| **rings2** (26) | `rings2_val` | 0.0 | **0.0** | 0 |
| **perspective** (30) | `perspective_angle` | 0.0 | **0.0** | 0 |
| | `perspective_dist` | 0.0 | **kept** | 1 |
| **super_shape** (50) | `super_shape_rnd` | 0.0 | **0.0** | 0 |
| | `super_shape_m` | 0.0 | **kept** | 1 |
| | `super_shape_n1` | 1.0 | **2.0** | 2 |
| | `super_shape_n2` | 1.0 | **2.0** | 3 |
| | `super_shape_n3` | 1.0 | **2.0** | 4 |
| | `super_shape_holes` | 0.0 | **0.0** | 5 |
| **ngon** (38) | `ngon_sides`/`ngon_power`/`ngon_circle`/`ngon_corners` | 5.0/3.0/1.0/2.0 | — | 0–3 |
| **julian** (32) | `julian_power`/`julian_dist` | 1.0/1.0 | — | 0–1 |
| **juliascope** (33) | `juliascope_power`/`juliascope_dist` | 1.0/1.0 | — | 0–1 |
| **wedge_julia** (78) | `wedge_julia_angle`/`_count`/`_power`/`_dist` | 0.0/1.0/1.0/0.0 | — | 0–3 |
| **wedge_sph** (79) | `wedge_sph_angle`/`_count`/`_hole`/`_swirl` | 0.0/1.0/0.0/0.0 | — | 0–3 |

## The math (behavior ported + cited; pinned by the oracle)

- **Loop:** `Loop.blend(sheep, t)` → for each non-final xform with `animate != 0`, set affine = `R(t·360°)·M` on the 2×2 only (translation, post, palette, color, weight, chaos unchanged). Padding xforms rotate only under `.log`. Output genome has `frame(t=1) == frame(t=0)`.
- **Transition:** `Transition.blend(A, B, t, stagger)` → `align(A,B)` (pad to equal count + special-sauce rest positions + copy parametric params from the neighbour that has them) → rotate both by `t·360°` → `interpolate(2cp, smoother(t), stagger)` with `.log` matrix blending and HSV palette interpolation.
- **Schedule (F1 — two-level seek, not O(1)):** segment *lengths* are constant per tier, so global-frame → `segmentId` is O(1) division; `segmentId` → `blend` is O(1). But `segmentId` → `(fromSheep, toSheep)` requires the selector walk, which for `SimilarityExploration` is sequential (ε-greedy consumes the seeded RNG + accumulates recency). So seek is **O(1) within the already-materialized prefix**, **O(segments) to extend the prefix forward** to a target beyond it, and **O(log segments) backward** within the prefix (binary search). The S7 dispatcher keeps a memory-bounded ring of the played prefix; a long forward jump replays the deterministic selector walk up to the target (reproducible, not instant). `Sequential` is O(1) everywhere (no RNG walk).
- **PairSelector:** `Sequential` (test scaffold) and `SimilarityExploration` (ε-greedy: with prob ε pick uniformly-random sheep = escape; else most-similar not-recently-used; recency penalty). `edges.sqlite` is a gold-set validator + optional classic-flock mode, not a render dependency.
- **Determinism rule (F1 — load-bearing):** every feature-vector component that accumulates over variation/parameter **name-keyed** data MUST be stored and summed in a **fixed, total order** — variation names sorted lexicographically into an array; the cache record stores that array, **never** a `Dictionary<String,_>` or `Set<String>`. **No floating-point accumulation may iterate a `Dictionary<String,_>`/`Set<String>`** (Swift's per-process hash seed randomizes their order, so the FP sum — and thus the argmax at near-ties — would differ across process launches, breaking G1). Sheep selection and recency are integer-indexed (`Set<Int>`, deterministic) so the RNG walk itself is fine; only the metric's sum order is constrained. A unit test asserts the metric for a fixed pair is **bit-identical across N separate process launches**.

## Determinism (G1/G2/G3 — split, do not conflate)

- **G1 — Schedule + per-frame genome:** a pure, **reproducible** function of `(library, selectorConfig, seed, tier, stagger, frameIndex)` **and the deterministic selector walk up to `frameIndex`**. Reproducible in **both S6 and S7** — *provided* the F1 determinism rule holds (sorted-order metric accumulation; no String-dict/Set FP sums). `stagger` is in the tuple because it changes the interpolated genome (F3). **Interpolation runs once in FlameKit (CPU, `Double`)** and the resulting `Flame` is handed to both renderers, so the genome is byte-identical across CPU and Metal; the S7 adaptive controller mutates only render params (`samplesPerPixel`), never the genome. (If interpolation ran on-device in FP32, this identity would break — it does not.)
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
| Transition continuity (objective) | consecutive frames A→B | (a) genome-space `‖G(t+δ)−G(t)‖ < 1e-3` on **normalized** coefficients (scale-independent); (b) image-space consecutive-frame **PSNR ≥ 40 dB** (transitions vary slowly) |
| Scheduler alternation | any schedule prefix | invariant: no two consecutive transitions |
| PairSelector exploration | a 50-segment walk over the full library | visits **≥ max(⌈0.5·librarySize⌉, 10)** distinct sheep (proves the ε-greedy escape is not trapped); reproducible under fixed seed (F1) |
| Animated-frame Metal↔CPU parity | per-frame `RGBA8Image`, incl. a **mismatched-sheep transition** (exercises special-sauce padding + the 16 Metal variations — F2 load-bearing) | **PSNR ≥ 38 dB, SSIM ≥ 0.95** (Metal↔CPU gate — distinct from the vs-flam3 30 dB) |
| Determinism (G2) | full S6 PNG sequence across runs | byte-identical |
| Metric determinism (F1) | similarity score for a fixed sheep pair, computed in **N separate process launches** | bit-identical (proves no String-dict/Set FP-sum leakage) |
| Finiteness | every animated frame | no NaN/Inf |
| Near-singular affine during `log` morph | constructed degenerate pair | port flam3's determinant guard → fallback to linear; frames finite |
| CLI snapshot | `emberweft animate` sequence + manifest | byte-stable; manifest schema stable |

> **Threshold correction (v1 error):** v1 applied 38 dB to the flam3 comparison. testing.md sets the **flam3 oracle at ≥ 30 dB** (different RNG/filter) and **Metal↔CPU at ≥ 38 dB**. This revision splits them. Animated Metal↔CPU parity is neither harder nor easier than stills (same per-frame comparison), so 38 dB stands there.
>
> **F6 — oversampling footnote:** the vs-flam3 rows (2–3) compare against `flam3-animate` invoked with **temporal oversampling disabled** (`passes="1"`, `temporal_samples="1"` on every CP — see Oracle pipeline). Without this, motion blur would make the ≥30 dB gate fail systematically on transition interiors.

**S7 performance & adaptive-quality gates (split — gate what is deterministic, defer what is environment-dependent, per testing.md §6 "perf = regression guard, not absolute gate"):**

*Gating in S7 (deterministic, M3 owns these):*
- **Sustained-throughput capability proof** — `FlamePlayer` sustains **≥ 58 fps (0.5× below the 60 target, to absorb transient dips) over a 30 s window at 1080p** under *nominal* thermal state on the dev machine (recorded as a baseline). A capability gate, not a flaky absolute; the hard 60 fps-under-UI-load gate is M4's.
- **Adaptive-quality controller logic** — fed *simulated* fps + thermal signals, the controller steps the iteration budget with the documented hysteresis (pure logic given inputs; deterministic, like the parity tests).

*Non-gating in S7 (regression baselines via `EMBERWEFT_PERF=1`): frame-time p50/p95/p99, per-tier fps curves.*

*Deferred to M4 as the hard gate (best-effort/baseline-only in M3):*
- The absolute "60 fps @ 1080p under real UI load" — depends on M4's compositing/window load (not yet present) and the exact hardware variant; measuring it on the bare engine now is premature.
- Real thermal-throttle behavior — cannot be reliably force-triggered; verify manually, do not gate.

### Edge & degenerate-input handling (added per review)
- Empty/size-1 library → error exit (strict alternation needs ≥ 2 sheep).
- Malformed/unrenderable sheep mid-walk → skip-and-log with bounded retry; ε-greedy escape never hard-fails on one bad sheep.
- Similarity NaN (empty variation set → zero-norm vector) → cosine fallback ε.
- Near-singular affine in `log` interp → port flam3's determinant guard, fall back to linear.
- Realtime frame-budget overrun → display best-available histogram each vsync (accept noise); never hold/duplicate a frame during a transition.
- **Metric NaN beyond the variation-set term (F9):** an all-zero palette makes mean-luma/hue undefined; a zero-norm affine makes the Frobenius term degenerate. The similarity metric guards every term independently (ε fallback per term), so one degenerate sheep cannot NaN the whole score.
- **Segment-boundary frame indexing (F9):** a tier of N frames yields N+1 blend samples (0…N); frame N of a segment is blend=1.0 = the segment's last genome, which for a loop equals the first genome of the *next* loop only by the alternation rule's construction — the manifest records each frame once (no duplicate/drop at boundaries).
- **`manifest.json` versioning (F9):** `manifestVersion: 1`. M6/M7 consumers error on `manifestVersion > known` (no silent migration); the CLI snapshot test asserts the version field is present and stable.

## CLI (S6)

```
emberweft animate <still.flam3...> \
  --library <dir>          # default genomes/electric-sheep/sheep
  --out frames/ \
  --frames 160 \           # per-segment budget (tier)
  --segments 5 \
  --selector sequential \  # sequential | similarity
  --seed 0 \
  --stagger 0.0 \          # per-xform transition desync (default 0; recorded in manifest)
  --backend cpu|metal \
  --rebuild-cache \        # (similarity only) rebuild the feature-vector cache
  --size WxH --quality N
```

Writes `frames/000000.png …` + `frames/manifest.json`:

```json
{
  "manifestVersion": 1,
  "tier": 160, "seed": 0, "selector": "sequential", "stagger": 0.0,
  "frames": [
    { "frame": 0,   "segmentId": 0, "kind": "loop",       "fromSheep": 0, "toSheep": 0, "blend": 0.0,    "interpolationType": null },
    { "frame": 160, "segmentId": 1, "kind": "transition", "fromSheep": 0, "toSheep": 1, "blend": 0.0,    "interpolationType": "log" }
  ]
}
```

(`fromSheep == toSheep` for loops; both populated for transitions; `frame` is the global index; `blend` is the raw `t`; `stagger` is top-level because it is per-run, not per-frame — F3; `interpolationType` is `null` on loop rows — a loop uses pure rotation, no matrix interpolation — F6.) This is the deterministic contract M6's encoder consumes.

### Feature-vector cache (F5)
`SimilarityExploration` over ~47k sheep needs precomputed feature vectors; a 1.6 GB scan per run is impractical. Specified:
- **Location:** `genomes/.feature_cache/` (gitignored derived data, one record per sheep id).
- **Record format:** the variation-set component is stored as a **lexicographically-sorted `(name, weight)` array**, never a dictionary (F1 determinism rule — the metric sums this array in fixed order). Other components (palette mean-hue/luma scalars, xform-count, summed affine Frobenius) are plain scalars.
- **Build:** `emberweft animate --rebuild-cache` or a `make feature-cache` target; computes the feature vector per sheep.
- **Incremental rebuild trigger:** `--selector similarity` **scans the library directory** at start; any `.flam3` with no cache record or a newer mtime triggers an incremental rebuild of that record *before* selection begins. So new gen-248 sheep landed by the daily `com.emberweft.sheep-sync` are picked up automatically on the next similarity run — no manual rebuild needed for incremental growth.
- **Fallback:** `--selector sequential` needs no cache. A **fully-absent** cache still requires explicit `--rebuild-cache` (to avoid a multi-minute stall on first run); `--selector similarity` errors with a clear message in that case. Stated in `--help`.

## S6-pre / S6 / S7 split

- **S6-pre — prerequisite (FlameKit data model + variations, CPU **and Metal**).** Widen `Variation`/`Flame`/`Xform`, extend parser/serializer, port the 16 special-sauce variations to both backends + the `GPUXform` param channel. Verified by round-trip + per-variation tests (CPU + Metal↔CPU) + green M1/M2 gates.
- **S6 — CLI animation (FlameKit math + CLI).** `Loop`, `Transition` (with `log`/polar + special-sauce + stagger + smoother + `wind` unwrap), `GenomeInterpolator` rewrite, `Schedule`, `PairSelector`, the `flam3-genome`/`flam3-animate` oracle, animated-frame parity/continuity/determinism tests (incl. the load-bearing mismatched-sheep Metal↔CPU gate), `emberweft animate`. **Ships a complete, oracle-validated, deterministic offline animation path on both backends.**
- **S7 — Realtime engine (PlaybackDispatcher + FlameUI).** An actor-isolated dispatcher driving the `Schedule` at target fps via `MetalRenderer`; `CAMetalLayer`-backed `FlameUI`; the adaptive-quality controller (iteration-budget feedback, thermal/power-aware, hysteresis per playback-modes.md); triple-buffered pacing; prefetch of the upcoming sheep mid-loop. Reuses S6's `Schedule`/`PairSelector` **and** its Metal variation set verbatim — **no animation- or renderer-math change in S7** (made true by S6-pre's Metal port; F2).

## Docs updated as part of M3

- **[transitions.md](../../rendering/transitions.md)** — promote to implemented reality; **drop the "circular palette cycle" loop claim** and the early draft sections (smooth=0/1/2 table, linear-interp rationale, renormalization, crossfade, quaternion) that contradict the faithful `log`+special-sauce+`sheep_loop` model; document the static-palette loop and HSV-transition palette.
- **[playback-modes.md](../../playback/playback-modes.md)** — correct the loop/palette wording; replace the stateful `SegmentScheduler` sketch (lines ~148-166) with the pure `Schedule` (two-level seek — F1) + S7 `PlaybackDispatcher`; confirm adaptive-quality controller wiring.
- **[roadmap.md](../../engineering/roadmap.md)** M3 — drop "circular palette"; flip M3 to ✅ on completion.
- **[testing.md](../../engineering/testing.md)** — add the animation-parity layer (table above) and the `flam3-genome`/`flam3-animate` oracle; record 30 dB (vs-flam3) vs 38 dB (Metal↔CPU).
- **[architecture.md](../../architecture.md)** — add `FlameUI`; describe the FlameKit animation subsystem + `PlaybackDispatcher`.
- **CLAUDE.md** — correct the M3 bullet's palette wording.
- **CHANGELOG.md** — M3 entry (incl. S6-pre prerequisite).

## Out of scope for M3 (deferred)

- Video muxing/codec/export UI — S10/M6. S6 stops at frame sequence + manifest.
- SwiftUI browser/metadata/import — M4. Screensaver/multi-monitor/power events — M5.
- Audio-reactive — M7. HDR/10-bit/ProRes/AV1 — M8.
- Temporal oversampling / motion blur — Emberweft renders at exact `blend` (no sub-frame sampling); **the oracle is configured to match** (`passes=1, temporal_samples=1`) for parity (F6). Adding Emberweft-side motion blur is a later fidelity refinement; at that point the oracle's oversampling is re-enabled for comparison.
- Variations beyond the M1-19 + the 14 NEW special-sauce = 33 total (spherical/polar are already in the M1-19, so not double-counted) — additive later.
- Faithful (non-approximation) density estimation — unchanged from M1/M2.

## Risks & mitigations

- **flam3 build/oracle availability.** *Mitigation:* S6-pre-adjacent task builds flam3 from source, pins the commit, and runs the literal env-var commands by hand once before any parity test depends on them. **F10 fallback:** if the build is unavailable in the current environment (e.g. an OS/Xcode update breaks autotools/libpng), the vs-flam3 parity tests **auto-skip with a printed warning, not fail**; Metal↔CPU parity (≥38 dB) remains the hard gate. The build is a dev-machine prerequisite documented in `docs/engineering/testing.md`, not a CI step.
- **Metal parity regression from new variations (F2).** Porting 16 variations to Metal could regress the M2 ≥38 dB gate if a fuzz genome uses one. *Mitigation:* S6-pre gates on the existing M2 parity staying green **plus** a fuzz run that excludes the 16 new names (proving additivity), and adds per-variation Metal↔CPU parity for each of the 16.
- **Near-singular affine NaN in `log` morphs.** *Mitigation:* port flam3's determinant guard (fallback to linear); constructed-degenerate-pair test in the frozen set.
- **Similarity traps playback.** *Mitigation:* ε-greedy escape is structural and tested before metric tuning ("visits ≥ max(⌈0.5·librarySize⌉,10) distinct sheep in 50 segments").
- **Special-sauce across structurally different pairs.** *Mitigation:* verified table ported faithfully; mismatched-pair continuity test; if a pair still pops, that's metric tuning (penalize structural distance), not an algorithm failure.
- **Realtime fps at 1080p × 160-frame loops.** *Mitigation:* per-frame cost unchanged from M2 (animation adds a cheap genome interpolation); adaptive quality is the safety net; 160-tier sized to M2's measured single-frame budget.
- **Data-model widening ripple.** *Mitigation:* S6-pre lands first as an isolated, gate-keeping slice; M1/M2 stay green via the `.linear` interpolation shim and additive variation set.
