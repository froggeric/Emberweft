# Missing flam3 Variations — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the 4 missing flam3 variations (`bubble`, `eyefish`, `pie`, `radial_blur`) into Emberweft (CPU + Metal) so all 7 real-genome fixtures pass the ≥38 dB vs-flam3 parity gate — in particular making the motion-blur clip genomes (05739, 31943) render faithfully.

**Architecture:** Reference-then-Optimize per variation: CPU `Variations.swift` first (faithful to `/Users/frederic/flam3-oracle-src/flam3/variations.c`), validate vs flam3, then Metal `Kernels.metal`, validate CPU↔Metal. Paramless variations go in the CPU `table`; RNG-consuming ones go in the `evaluate` switch (mirroring `julian`). Each variation appends to `VariationDescriptor.canonicalOrder` (growing the slot count 33→37) and adds one MSL `v_<name>` + one dispatch line.

**Tech Stack:** Swift 6 (Apple Silicon, Metal 4), SwiftPM, XCTest; the flam3 oracle (`flam3-render` on `$PATH`; source at `/Users/frederic/flam3-oracle-src/flam3` + build at `/private/tmp/flam3-build`; the `/tmp/flam3` checkout is an empty skeleton — use the oracle-src path).

**User decisions (already made):**
- "Implement missing variations" — port `bubble`, `eyefish`, `pie`, `radial_blur` (the ones used by the 7 real fixtures) to achieve full real-genome parity.

---

## Background (read this first — verified by research, 2026-07-22)

### Why (from Task 6 of the motion-blur plan)
The density gap (highlightPower + spatialFilterRadius) is closed (00256: 21→51 dB; 4/7 fixtures ≥49 dB). The remaining 3 fixtures (00000, 05739, 31943) fail at 10–33 dB because they use **unimplemented variations**. Emberweft implements 30 variations; missing: `bubble`, `eyefish`, `pie`, `radial_blur`.

### Per-fixture usage (which variation unblocks which fixture)
| Fixture | bubble | eyefish | pie | radial_blur |
|---|---|---|---|---|
| 00000 | xform | xform | xform | xform |
| 05739 | **finalxform** (negative weight −0.714) | — | — | — |
| 31943 | **finalxform** | — | — | — |
| 00038/00084/00256/00268 | — | — | — | — (already `.gate`, passing) |

→ **`bubble` unblocks 3 fixtures (incl. both clip genomes).** `eyefish`/`pie`/`radial_blur` each unblock only 00000. All 4 are needed to flip 00000 to `.gate`.

### flam3 formulas (verbatim from `variations.c`) + RNG draw counts
- **`bubble`** (var28, `variations.c:671-678`): `r = weight / (0.25 * precalc_sumsq + 1); p0 += r*tx; p1 += r*ty`. **0 RNG draws. Paramless.** Port: `r = weight / (0.25*(p.x*p.x+p.y*p.y) + 1); return SIMD2(r*p.x, r*p.y)`.
- **`eyefish`** (var27, `variations.c:659-669`): `r = (weight*2) / (precalc_sqrt + 1); p0 += r*tx; p1 += r*ty`. **0 RNG draws. Paramless. NOT an alias of `fisheye`** — output is `(r*tx, r*ty)` (un-swapped); `fisheye` swaps to `(r*ty, r*tx)`. (The `RealGenomeParityTests.swift:77` "(alias of fisheye)" parenthetical is WRONG — correct it.)
- **`pie`** (var37, `variations.c:795-809`): **3 `isaac_01` draws in this exact order**: (1) `sl = (int)(isaac_01*pie_slices + 0.5)`; (2) `isaac_01*pie_thickness` (angular offset inside slice); (3) `weight*isaac_01` (radial). `a = pie_rotation + 2π*(sl + draw2*pie_thickness)/pie_slices; r = weight*draw3; p0 += r*cos(a); p1 += r*sin(a)`. **Params (3):** `pie_slices=6.0`, `pie_rotation=0.0`, `pie_thickness=0.5`.
- **`radial_blur`** (var36, `variations.c:775-793`): **4 `isaac_01` draws summed left-to-right**: `rndG = weight*(d + d + d + d - 2.0)`. `ra = precalc_sqrt; tmpa = precalc_atanyx + spinvar*rndG; rz = zoomvar*rndG - 1; p0 += ra*cos(tmpa) + rz*tx; p1 += ra*sin(tmpa) + rz*ty`, where `spinvar = sin(radial_blur_angle*π/2)`, `zoomvar = cos(radial_blur_angle*π/2)` (from `radial_blur_precalc`, `variations.c:1964-1967`). **Params (1):** `radial_blur_angle=0.0`. Uses `precalc_atanyx = atan2(ty,tx)`.

### CPU porting pattern (`Sources/FlameKit/Variations.swift` + `VariationDescriptor.swift`)
- Closure signature (table): `(p: SIMD2<Double>, weight: Double, params: [String:Double], ef: SIMD2<Double>) -> SIMD2<Double>`. Paramless non-RNG variations live in the `table` (static dict, `Variations.swift:231+`).
- Parametric resolve: `resolve(_:_:_:)` (`Variations.swift:209-212`) — `par[key] ?? descriptor.defaults[key] ?? 0`. Keys are FULL XML names.
- **RNG-consuming variations are NOT in the table** — they're in the `switch` in `evaluate` (`Variations.swift:51-79`) and take `rng: inout ISAAC`. Template: `julia` (`Variations.swift:92-100`), `julian` (`:108-120`).
- RNG helpers: `ISAAC.isaac01()` (1 word, [0,1)), `ISAAC.bit()` (1 word, lowest bit), `ISAAC.isaac11()` (1 word, [−1,1)).
- **Draw ORDER is load-bearing**: `evaluate` walks variations in alphabetical array order (parser sorts at `Flam3Parser.swift:223`). The plan's RNG-consuming variations (`pie`, `radial_blur`) must consume their draws in the exact flam3 order above.
- **No alias registry exists** — each name must be added explicitly to `VariationDescriptor.canonicalOrder` + the descriptor table + (paramless) the `table` / (RNG) the `switch`.

### Metal porting pattern (`Sources/FlameRenderer/Metal/Kernels.metal` + `MetalHost.swift`)
- `#define NUM_XFORM_SLOTS_MS 33` (`Kernels.metal:139`) — bump as variations are added. `GPUXform.varWeights[33]` + `varParams[33*8]`.
- Dispatch: `apply_xform_body` (`Kernels.metal:442-484`) has one `if (w[i] != 0.0f) acc += v_<name>(...)` per slot. The `w[i] != 0` guard is load-bearing (avoids `0*Inf=NaN`).
- Paramless MSL template: `v_fisheye` (`:219-222`). Parametric: `v_blob` (`:293-299`, params via `thread const float* pr`). RNG: `v_julian` (`:331-342`, `thread IsaacState& rng`, draw via `isaac_01(rng)`).
- Slot index = position in `VariationDescriptor.canonicalOrder`. `MetalHost.packXforms` (`MetalHost.swift:84-131`) iterates `canonicalOrder` generically → NO host source change needed when appending a variation (numSlots/floatsPerXform derive from `canonicalOrder.count`).
- **Two tests hardcode `33`** — bump as the count grows: `VariationDescriptorTests.swift:37-39`, `ParamChannelParityTests.swift:16-17,30`.

### Pre-wired test infra
- `RealGenomeParityTests.swift` fixture table (`:66-82`): 4 `.gate` + 3 `.knownGap`. Flip `.knownGap` → `.gate` as variations land (asserts PSNR≥38 / SSIM≥0.95 at `:187`).
- `VariationsTests.swift`: closed-form tests + draw-count tests (template `testJulianDrawsOneAndFinite` `:185-195`).
- `SpecialSauceParityTests.swift`: per-variation Metal↔CPU parity one-liners (`assertParity(name, params)`).

---

## File Structure

**Modify:**
- `Sources/FlameKit/VariationDescriptor.swift` — append `"bubble"`,`"eyefish"`,`"pie"`,`"radial_blur"` to `canonicalOrder`; register 4 descriptors.
- `Sources/FlameKit/Variations.swift` — `bubble`/`eyefish` → `table`; `pie`/`radial_blur` → `evaluate` switch + static funcs.
- `Sources/FlameRenderer/Metal/Kernels.metal` — bump `NUM_XFORM_SLOTS_MS`; add 4 `v_<name>` MSL + 4 dispatch lines.
- `Tests/FlameKitTests/VariationsTests.swift` — closed-form + draw-count tests.
- `Tests/FlameKitTests/VariationDescriptorTests.swift` + `Tests/FlameRendererTests/ParamChannelParityTests.swift` — bump `33`→`37`.
- `Tests/FlameRendererTests/SpecialSauceParityTests.swift` — 4 parity one-liners.
- `Tests/FlameReferenceTests/RealGenomeParityTests.swift` — flip `.knownGap`→`.gate` as variations land; correct the eyefish "(alias)" comment.

(Per task: each variation appends its own descriptor + slot + impl + tests + fixture flip — incremental, 33→34→35→36→37.)

---

## Task 1: `bubble` (paramless, RNG-free; unblocks 05739 + 31943 + 00000)

**Goal:** Port `bubble` to CPU + Metal; flip 05739 + 31943 to `.gate` (they use only bubble). This alone makes the motion-blur clip genomes faithful.

**Files:** `VariationDescriptor.swift`, `Variations.swift`, `Kernels.metal`, `VariationsTests.swift`, `VariationDescriptorTests.swift`, `ParamChannelParityTests.swift`, `SpecialSauceParityTests.swift`, `RealGenomeParityTests.swift`.

**Acceptance Criteria:**
- [ ] `bubble` parses + serializes round-trips (no params).
- [ ] CPU closed-form test passes (hand-traced from `var28_bubble`).
- [ ] Metal↔CPU parity `testBubble` ≥38 dB (`SpecialSauceParityTests`).
- [ ] `Variations.canonicalOrder` / `VariationDescriptor` include `bubble`; the two `33`-literal tests bumped to `34`.
- [ ] `RealGenomeParityTests`: 05739 + 31943 flipped to `.gate`, both ≥38 dB / ≥0.95 SSIM. 00000 stays `.knownGap` (needs eyefish/pie/radial_blur) but its reason updated (bubble now implemented).
- [ ] `make test-fast` green; existing goldens/parity unchanged (bubble is additive — genomes without it are byte-identical).

**Verify:** `swift test --filter VariationsTests --filter VariationDescriptorTests --filter ParamChannelParityTests --filter SpecialSauceParityTests --filter RealGenomeParityTests` (sandbox OFF).

**Steps:**
- [ ] **Step 1: Write failing tests** — `testBubble` (closed-form, hand-traced: e.g. `bubble(SIMD2(0.6,0.8), w=1.0)` → `r = 1/(0.25*(0.36+0.64)+1) = 1/1.25 = 0.8` → `(0.48, 0.64)`); `testBubble` Metal↔CPU parity; bump the two `33`→`34` literals (test will fail until count grows).
- [ ] **Step 2: Run → fail.**
- [ ] **Step 3: Implement** — append `"bubble"` to `VariationDescriptor.canonicalOrder` + `d("bubble", [], [:])`; add `t["bubble"] = { p, w, _, _ in let r = w / (0.25*(p.x*p.x+p.y*p.y) + 1); return SIMD2(r*p.x, r*p.y) }`; bump `NUM_XFORM_SLOTS_MS` to 34; add `v_bubble` MSL (`float r = w / (0.25f*(p.x*p.x+p.y*p.y) + 1.0f); return float2(w*r... wait — r already includes w — return float2(r*p.x, r*p.y)`) + dispatch line `if (w[33] != 0.0f) acc += v_bubble(pre, w[33]);`. Flip 05739/31943 to `.gate` in RealGenomeParityTests; update 00000's reason to remove bubble.
- [ ] **Step 4: Run → pass.** Confirm 05739/31943 ≥38 dB.
- [ ] **Step 5: Commit.** `feat(variations): port bubble (CPU + Metal) — flips 05739/31943 to real-genome parity gate`

---

## Task 2: `eyefish` (paramless, RNG-free; NOT a fisheye alias)

**Goal:** Port `eyefish` (un-swapped output, distinct from `fisheye`). Unblocks 00000 (partially).

**Acceptance Criteria:**
- [ ] CPU closed-form test passes — **assert eyefish ≠ fisheye** for a non-axis-symmetric input (e.g. `eyefish(SIMD2(0.3,0.7))` ≠ `fisheye(SIMD2(0.3,0.7))`), confirming the un-swapped output.
- [ ] Metal↔CPU parity `testEyefish` ≥38 dB.
- [ ] canonicalOrder includes `eyefish`; count → 35; the two `33`-literal tests bumped.
- [ ] `make test-fast` green; goldens unchanged.
- [ ] Correct the `RealGenomeParityTests.swift:77` "(alias of fisheye)" comment (eyefish is its own variation).

**Verify:** `swift test --filter VariationsTests --filter SpecialSauceParityTests --filter VariationDescriptorTests --filter ParamChannelParityTests`.

**Steps:** Append `"eyefish"` + descriptor; add `t["eyefish"] = { p, w, _, _ in let r = (w*2)/(sqrt(p.x*p.x+p.y*p.y) + 1); return SIMD2(r*p.x, r*p.y) }` (note: NO axis swap — `(r*p.x, r*p.y)`, vs fisheye's `(r*p.y, r*p.x)`); MSL `v_eyefish` + dispatch; bump count to 35; tests. Commit `feat(variations): port eyefish (CPU + Metal; not a fisheye alias — un-swapped output)`.

---

## Task 3: `pie` (3 params, 3 RNG draws — order-critical)

**Goal:** Port `pie` to CPU + Metal with the exact 3-draw order. Unblocks 00000 (partially).

**Acceptance Criteria:**
- [ ] CPU `pie` draws exactly 3 `isaac_01` words in flam3 order (slice → angular → radial) — draw-count test (template `testJulianDrawsOneAndFinite`) passes.
- [ ] CPU closed-form test passes for a fixed RNG stream (seed ISAAC, assert the output matches a hand-traced value).
- [ ] Metal↔CPU parity `testPie` ≥38 dB (params `pie_slices:6, pie_rotation:0, pie_thickness:0.5`).
- [ ] `pie` registered in the `evaluate` switch (RNG-consuming), NOT the table.
- [ ] canonicalOrder includes `pie`; count → 36; the two `33`-literal tests bumped.
- [ ] `make test-fast` green; goldens unchanged.

**Verify:** `swift test --filter VariationsTests --filter SpecialSauceParityTests --filter VariationDescriptorTests --filter ParamChannelParityTests`.

**Steps:** Append `"pie"` + `d("pie", ["pie_slices","pie_rotation","pie_thickness"], ["pie_slices":6,"pie_rotation":0,"pie_thickness":0.5])`; add `pie` to the `evaluate` switch + static func `pie(_:weight:params:rng:)` mirroring `julian` (3 `rng.isaac01()` calls in order: `sl=(Int)(d1*slices+0.5)`, `a = rotation + 2π*(Double(sl) + d2*thickness)/slices`, `r = weight*d3`, return `(r*cos(a), r*sin(a))`); MSL `v_pie(p, w, pr, rng)` with 3 `isaac_01(rng)` in the same order + dispatch `if (w[35] != 0.0f) acc += v_pie(pre, w[35], &x.varParams[35*8], rng);`; bump count to 36; tests. Commit `feat(variations): port pie (CPU + Metal; 3 ordered isaac_01 draws)`.

---

## Task 4: `radial_blur` (1 param, 4 RNG draws — summed left-to-right)

**Goal:** Port `radial_blur` to CPU + Metal with the exact 4-draw sum. Unblocks 00000 (partially).

**Acceptance Criteria:**
- [ ] CPU `radial_blur` draws exactly 4 `isaac_01` words summed as `weight*(d+d+d+d−2)` — draw-count test passes.
- [ ] CPU closed-form test passes for a fixed RNG stream.
- [ ] Metal↔CPU parity `testRadialBlur` ≥38 dB (param `radial_blur_angle:0`).
- [ ] `radial_blur` registered in the `evaluate` switch (RNG-consuming); `spinvar`/`zoomvar` computed inline as `sin(angle*π/2)`/`cos(angle*π/2)`.
- [ ] canonicalOrder includes `radial_blur`; count → 37; the two `33`-literal tests bumped.
- [ ] `make test-fast` green; goldens unchanged.

**Verify:** `swift test --filter VariationsTests --filter SpecialSauceParityTests --filter VariationDescriptorTests --filter ParamChannelParityTests`.

**Steps:** Append `"radial_blur"` + `d("radial_blur", ["radial_blur_angle"], ["radial_blur_angle":0])`; add to `evaluate` switch + static func `radialBlur(_:weight:params:rng:)`: `let angle = resolve("radial_blur","radial_blur_angle",params); let spinvar = sin(angle*π/2); let zoomvar = cos(angle*π/2); let d1=rng.isaac01(), d2=rng.isaac01(), d3=rng.isaac01(), d4=rng.isaac01(); let rndG = weight*(d1+d2+d3+d4−2); let ra = sqrt(p.x²+p.y²); let tmpa = atan2(p.y,p.x) + spinvar*rndG; let rz = zoomvar*rndG − 1; return SIMD2(ra*cos(tmpa) + rz*p.x, ra*sin(tmpa) + rz*p.y)`; MSL `v_radial_blur` (4 `isaac_01(rng)` summed in order) + dispatch; bump count to 37; tests. Commit `feat(variations): port radial_blur (CPU + Metal; 4 ordered isaac_01 draws)`.

---

## Task 5: Flip 00000 to `.gate` + final verification + re-render the clip

**Goal:** With all 4 variations in, 00000 passes the gate; run the full parity verification and re-render the now-faithful motion-blur clip.

**Acceptance Criteria:**
- [ ] `RealGenomeParityTests`: all 7 fixtures `.gate`, all ≥38 dB / ≥0.95 SSIM.
- [ ] `GoldenParityTests` unchanged (51–72 dB); `make test-fast` green; full `AnimationParityTests` (M3 vs flam3) unchanged.
- [ ] Re-render the Task-4 clip (05739→31943, q500, ts32, 720p, release) — now with `bubble` faithful — and confirm boundary PSNR still smooth (≤ within-loop + ~1 dB) + visually faithful to the official 05739/31943 videos.

**Verify:** `swift test --filter RealGenomeParityTests` (all 7 ≥38) + `swift test --filter GoldenParityTests` + `make test-fast`; then `swift run -c release emberweft animate …05739… …31943… --frames 160 --segments 3 --loop-cycles 1 --temporal-samples 32 --quality 500 --size 1280x720 --backend metal --out /tmp/m3_mb` + boundary PSNR.

**Steps:**
- [ ] **Step 1:** Flip 00000 to `.gate` in `RealGenomeParityTests`. Run → all 7 ≥38 dB (if 00000 < 38, debug — re-check pie/radial_blur draw order vs flam3).
- [ ] **Step 2:** Full verification (GoldenParity + make test-fast + AnimationParity).
- [ ] **Step 3:** Re-render the clip (release); measure boundary PSNR.
- [ ] **Step 4:** Present the faithful clip to the user for visual confirmation (open + official videos).
- [ ] **Step 5:** Commit `feat(variations): all 7 real-genome fixtures pass ≥38 dB parity; re-render faithful clip`.

---

## Verification (whole plan)
```bash
swift test --filter VariationsTests --filter VariationDescriptorTests --filter ParamChannelParityTests   # variation unit + slot-count
swift test --filter SpecialSauceParityTests            # per-variation CPU↔Metal ≥38 dB
swift test --filter RealGenomeParityTests              # all 7 real genomes ≥38 dB vs flam3 (sandbox OFF)
swift test --filter GoldenParityTests                  # synthetic goldens unchanged
make test-fast                                         # full fast suite green
```

## Self-review
- **Spec coverage:** 4 variations × (CPU + Metal + tests) = Tasks 1-4; 00000 flip + clip = Task 5. bubble alone (Task 1) unblocks the clip genomes (highest leverage first).
- **RNG parity:** pie (3 draws) + radial_blur (4 draws) are the hazards — draw order pinned to flam3 verbatim; draw-count tests guard it. bubble/eyefish are RNG-free (mechanically additive).
- **No alias shortcut:** eyefish ≠ fisheye (un-swapped) — implemented as its own variation, comment corrected.
- **Slot-count stability:** each task appends to canonicalOrder (33→34→35→36→37); CPU descriptor + Metal dispatch + host packer all derive from canonicalOrder, so they stay in sync.
- **Synthetic goldens:** additive only (goldens don't use these variations) → byte-identical, guarded by GoldenParityTests.

## Notes for execution
- Disable the bash sandbox for Metal/flam3 runs.
- flam3 source: `/Users/frederic/flam3-oracle-src/flam3` (the `/tmp/flam3` checkout is an empty skeleton).
- Conventional Commits, one per task. Branch: continue on `feat/motion-blur-density-parity` (or a new `feat/missing-variations` branched from it — coordinator's call).
