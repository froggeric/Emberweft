# Remaining Work — flam3 Variation Completion + knownGap Fixture Investigation

> **Purpose:** survive context compaction. After CV7 (secant2+disc2) lands, this doc captures the two remaining work-streams so a fresh session/subagent can resume. Self-contained — read the referenced files for detail.

## STATUS / RESUME (updated 2026-07-23 — POST PALETTE_MODE FIX, post-compaction entry point)

**Emberweft:** `main` @ `f907f150d` (synced to origin). Still **57/99** variations. Build green, `make test-fast` 271/271, goldens byte-identical. Oracle (`~/.local/bin/flam3-*`) symlinks repoint at `~/flam3-oracle-src/flam3/` (the `/tmp` build evicted; symlinks MUST be re-created if they dangle). flam3 source survives at `~/flam3-oracle-src/flam3/` (note: `flam3.c` + `rect.c` carry gated `FLAM3_TRACE` debug prints — harmless w/o the env var).

**Work B (knownGap) — ROOT CAUSE FOUND + FIXED + MERGED (commit `171083515`).** The 4 knownGap were NOT a display-pipeline/hp/camera/iteration gap (all ruled out via a two-sided point trace that PROVED the chaos game is bit-faithful). The cause was **palette_mode**: Emberweft used LINEAR dmap interpolation; flam3's DEFAULT is STEP (nearest). Fix: `PaletteMode` enum (default `.step`) in FlameKit, parse `palette_mode`, branch in `ChaosGame`. **Result: 2/4 knownGap CLOSED → `.gate`** — `242.00099` (waves) 28.7→53.9, `242.00261` (split/cross) 30.7→52.4; gate fixtures improved. The per-variation vs-flam3 harness (`Tests/FlameReferenceTests/VariationFlam3ParityTests.swift`, commit `c5fb0389b`) now passes ALL single variations at 52-69 dB and is the validation tool for Work A. See memory `workb-knowngap-iteration-divergence`.

**Work B REMAINING (small, NOT real faithfulness bugs):**
1. `244.00788` (cross/noise, 12-xform) — PASSES at the stress op-point (`python3 Tools/density_diff.py --genome Tests/Goldens/genomes_real/electricsheep.244.00788.flam3` → 39.85 dB, centroids identical). Fails only at the test's fast 500spp op-point = **sampling noise**. Close by bumping `RealGenomeParityTests.quality` 500→1000 (costs ~2× gate runtime) → flip to `.gate`.
2. `244.28122` (flower, rotate=-178) — genuine MARGINAL residual (37.65 dB at stress; centroids/light match → subtle density diff; all pipeline proven correct). Hard to close the last 0.35 dB. Keep `.knownGap` or accept.
3. **Metal renderer still uses LINEAR palette** — the Metal step-port regressed to 32 dB vs CPU's 54 on spiky palettes (likely Float-precision or `GPUFrameParams` struct-packing: I added `paletteMode` to the Swift+MSL structs but Metal still diverged — needs debugging). SpecialSauce stays green (smooth palettes). The CPU (`ChaosGame.swift`) is correct; mirror the step branch into `Kernels.metal:932-940` + `MetalHost.buildFrameParams` + `GPUFrameParams` once the 32 dB is debugged.

**Work A (42 variations → 99/99) — NOT STARTED, now DE-RISKED.** Same plan as below (4 batches). Each port is validated by the harness (`VariationFlam3ParityTests`) vs-flam3, AND by `SpecialSauceParityTests` (Metal↔CPU). Use subagent-driven-development, sequential (shared files).

---

## ORIGINAL PLAN (pre-palette_mode; background still accurate)

**Branch:** `feat/corpus-variations` (will merge to `main` as v0.1.1 after CV7). **flam3 source:** `/private/tmp/flam3-build/variations.c` (also `/Users/frederic/flam3-oracle-src/flam3/variations.c`). **Emberweft state after CV7:** implements **57 of 99** flam3 variations; all 20 corpus-used variations ported (100% corpus coverage).

---

## Work A — Port the 42 remaining flam3 variations (full 99-variation completion)

**Why:** these 42 are NOT used by the archived Electric Sheep corpus (a 30k-genome survey confirmed zero occurrences for 40 of them; the other 2 — `secant2`/`disc2` — are ported in CV7). Porting them completes the faithful flam3 variation set for **non-ES / hand-authored genomes** + flam3 completeness. **Priority: low** (corpus is already 100% covered) but the user has requested the full port.

**The 42 (flam3 99 − Emberweft 57):**
```
auger bent2 bipolar boarders butterfly cell cos cosh cot coth cpow csc csch
curve edisc elliptic escher exp flux foci lazysusan log loonie mobius modulus
oscilloscope polar2 popcorn2 pre_blur scry sec sech separation sin sinh splits
stripes tan tanh waves2 wedge whorl
```

### Approach (per variation — same Reference-then-Optimize as CV1-CV7)
1. **Read the formula** from `/private/tmp/flam3-build/variations.c` (`void varNN_<name>`). Note the var# for the slot comment.
2. **Classify**: paramless-non-RNG / parametric-non-RNG / RNG-consuming. (Quick inference: `pre_blur` is RNG-consuming; the trig family `cos/cosh/cot/coth/csc/csch/sec/sech/sin/sinh/tan/tanh/exp/log` are paramless non-RNG; `cpow/modulus/mobius` likely parametric; `butterfly/cell/escher/flux/foci/loonie/twintrian...` need source read.) Confirm params + RNG draw count/order from source + `parser.c` (param attrs) + `clear_cp` (defaults = 0 via memset; non-zero values in `initialize_xforms` are for RANDOM genome generation, NOT parse defaults — so all param defaults are 0).
3. **Port**: CPU (`Variations.table` closure for paramless/parametric; `evaluate` switch + `private static func` w/ `rng: inout ISAAC` for RNG-consuming) + Metal (`v_<name>` + guarded dispatch line `if (w[N] != 0.0f)`) + descriptor (`d(...)`) + append to `canonicalOrder`. Bump `NUM_XFORM_SLOTS_MS` + the two slot-count test literals (`VariationDescriptorTests`, `ParamChannelParityTests`) + derived floats/bytes.
4. **Test**: `VariationsTests` closed-form (hand-traced) + draw-count (for RNG); `SpecialSauceParityTests.assertParity` (Metal↔CPU ≥38 dB). Goldens must stay byte-identical (`GoldenParityTests` + `testFrozenGenomesByteIdenticalToBaseline`).

### Care items (hazards, from the CV1-CV7 experience)
- **RNG draw order is load-bearing** — issue each `rng.isaac01()` as a SEPARATE statement (MSL/C++ arg-eval order unspecified; `Kernels.metal:594-599`).
- **badvalue guards**: any variation with `log`/`log10`/`1/cos`/`tan` Inf sources — replicate flam3's exact guard (e.g. twintrian's `diff=-30.0`; arch/rays un-guarded). `badvalue(x) = x!=x || x>1e10 || x<-1e10`.
- **/sqrt with NO EPS**: some variations (flower/conic style) divide by `precalc_sqrt` ungarded — match flam3.
- **Pole-chaos at weight=1**: several variations (radial_blur/tangent/gaussian_blur/secant2's 1/cos) amplify Float-vs-Double ULP noise → Metal↔CPU PSNR drops below 38 at w=1. Precedent: `assertParity(..., weight: 0.4)` for the parity test; CPU closed-form/draw-count tests stay at weight=1.
- **Affine access**: variations needing c,d,e,f use the widened `affine: SIMD4<Double>` (CV1's precursor) on CPU; Metal reads `x.c..x.f`.
- **Param defaults = 0** for all (verify via `clear_cp`, not `initialize_xforms`).

### Batching suggestion (mirror CV1-CV7: by type, sequential — shared files)
- Batch 1: paramless trig family (`cos cosh cot coth csc csch sec sech sin sinh tan tanh exp log`) — ~13, mechanical.
- Batch 2: paramless non-trig (`bent2 boarders butterfly curve escher flux foci lazysusan loonie modulus scry separation splits stripes waves2 whorl cell`) — ~16.
- Batch 3: parametric (`cpow mobius elliptic edisc polar2 popcorn2 oscilloscope auger bipolar`) — ~8.
- Batch 4: RNG (`pre_blur` + any others found RNG-consuming on source read) + `wedge` (paramless?).
- Final: slot count 57→99; flip any new fixtures; full regression; release (v0.1.2 or fold into v0.1.1).

### Slot budget
57 → 99 (+42). `NUM_XFORM_SLOTS_MS` 57→99. `GPUXform.varWeights[99]` + `varParams[99*8=792]`. `floatsPerXform`/`bytesPerXform` grow accordingly (derived from `canonicalOrder.count`). The Metal dispatch becomes a 99-line if-chain (fine — flat, guarded).

### Reference commits (the established pattern)
`404a37b9d` (bubble), `68f33c943` (eyefish), `0c1f722d0` (pie — RNG), `aeed7f205` (radial_blur — RNG+badvalue), `3ac31b531` (CV1 — affine widening + paramless), `f54d17696` (CV2 — parametric), `7b6a8a016` (CV3 — RNG simple), `48170e81f` (CV4 — RNG+Inf/badvalue), `3041c1382` (CV5 — parametric+RNG), CV7 (secant2+disc2).

---

## Work B — Investigate + fix the 4 `.knownGap` fixtures (residual display/parsing gap)

**Why:** 4 real-genome fixtures added in CV6 render at 28-34 dB vs flam3 (below the 38 dB gate). They are **NOT variation bugs** — the variations they use (waves/popcorn/split/cross/noise/flower) all pass Metal↔CPU parity at 45-inf dB (`SpecialSauceParityTests`). The gap is a residual **display-pipeline / parsing** difference, of the same class as two bugs CV6 already found+fixed (a sanitize regex clobbering `split_xsize`/`split_ysize`, and a wrong legacy `symmetry=` → `color_speed`/`animate` mapping costing ~40 dB). There is likely **one more mishandled attr or display param** to find.

### The 4 fixtures (`Tests/Goldens/genomes_real/`, in `RealGenomeParityTests.swift` ~line 139-148)
| Fixture | Variations | PSNR / SSIM | Reason logged |
|---|---|---|---|
| `electricsheep.242.00099` | waves, popcorn | 28.76 / 0.9172 | residual hp/filter display gap; no highlight_power attr; Emberweft peakier |
| `electricsheep.242.00261` | split, cross | 30.67 / 0.8715 | same |
| `electricsheep.244.00788` | cross, noise, gaussian_blur | 32.76 / 0.8438 | same |
| `electricsheep.244.28122` | flower | 34.27 / 0.9526 | same |

All 4 are **single-flame edge genomes** (from `genomes/electric-sheep/edges/`) with `filter="1"` and **no `highlight_power` attr** (default). For contrast: the 12 passing `.gate` fixtures (7 original + 5 CV6) all have `highlight_power="1"`.

### Ruled OUT (don't re-investigate)
- **Variation math**: correct — `SpecialSauceParityTests` passes (45-inf dB) for waves/popcorn/split/cross/noise/flower; closed-form tests pin the formulas.
- **Default highlight_power**: flam3's `clear_cp` (`flam3.c:1293,1320`) sets default `highlight_power = -1.0` — **matches Emberweft's default** (`Genome.swift:151`, `ToneMapping.swift:36`). So a missing hp attr is NOT the cause.
- **`filter`**: wired (`filter="1"` → spatialFilterRadius, the Task-6 density-gap fix).
- **Synthetic goldens + M3 animation parity**: unchanged (51-72 dB / 43-58 dB).

### Investigation plan (systematic-debugging — root cause before fix)
1. **`Tools/density_diff.py`** on each of the 4 fixtures (it renders Emberweft-CPU vs flam3 + prints brightness histogram / thresholds / centroid / bbox). It already flagged "Emberweft peakier" — confirm WHERE (core/mid/periphery) + whether it's density-distribution or tone.
2. **Attr-by-attr diff**: parse each fixture in Emberweft (`Flam3Parser`) AND flam3, dump every parsed attr/value, diff. Look for an attr Emberweft drops or mis-maps (the symmetry bug was exactly this — `symmetry=` → wrong `color_speed` factor + missing `animate` derivation). Suspects to check on these edge genomes: `symmetry` (re-verify the fix covers all cases), `chaos`, `animate`, `opacity`, `color_speed`, `post` affine, `chaos_order`, density-estimation attrs (`estimator_radius/minimum/curve`), camera (`scale/zoom/center/rotate`), `gamma`/`vibrancy`/`gamma_threshold`, `quality`/`samples`.
3. **Density estimation**: re-enable DE in density_diff (estimator_radius from the genome) — does it amplify or close the gap? (The Task-5 diagnostic ruled DE out for 00256 at estimator_radius=0, but these edge genomes may carry non-zero estimator_radius that Emberweft mishandles.)
4. **The 2 precedent bugs** (fixed in CV6 commit `99d01f86d`): the sanitize regex (word-boundary lookbehind for `size=` not matching inside `split_xsize=`) + the `symmetry` mapping (`color_speed=(1-sym)/2`, `animate = sym>0 ? 0 : 1`). Use these as the template — the 4th bug is likely the same shape (a parsed attr mis-mapped or mis-defaulted).
5. Once the root cause is found, fix it (parser or display pipeline), add a regression test (hand-traced parse or parity), flip the 4 fixtures `.knownGap` → `.gate` (≥38 dB), confirm goldens unchanged.

### Why it matters
These 4 are edge genomes; in practice edges render via `Transition.blend` (interpolating two hp="1" sheep → hp≈1, faithful — the clip the user approved is fine). But the gap indicates a real display/parsing difference that could affect other genomes. Fixing it makes the ≥38 dB gate pass on all fixtures (clean v0.1.1) + closes the last known faithfulness gap.

---

## Execution notes (post-compaction resume)
- **Use subagents** (subagent-driven-development): research subagent for the 42 formulas / density_diff investigation; implementer subagents per batch; spec+quality review between.
- **Sequential** for variation ports (shared files: `VariationDescriptor.canonicalOrder`, `Variations.swift`, `Kernels.metal`, slot-count tests).
- **Disable the bash sandbox** for Metal/flam3 runs.
- **flam3 source** is volatile (`/tmp/flam3-build`); the oracle binaries survive on `$PATH` (`~/.local/bin`). Rebuild via `make bootstrap-oracle` if `/tmp` is gone.
- The pattern is mature (CV1-CV7); each variation is mechanical once its formula/classification is read from source.
