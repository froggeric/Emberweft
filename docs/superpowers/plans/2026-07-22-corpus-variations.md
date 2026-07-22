# Corpus-Coverage Variations (18) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development. Steps use checkbox (`- [ ]`] syntax. **Sequential** (all 18 touch the same shared files: `VariationDescriptor.canonicalOrder`, `Variations.swift`, `Kernels.metal`, slot-count tests; the slot index increments each batch — no parallel implementers).

**Goal:** Port the 18 flam3 variations the ES corpus actually uses (found by a 23k-genome survey) but Emberweft lacks, so corpus-wide real-genome parity is near-complete. Same Reference-then-Optimize pattern as the prior 4 (`bubble`/`eyefish`/`pie`/`radial_blur`).

**Architecture:** CPU `Variations.swift` first (faithful to `/private/tmp/flam3-build/variations.c`), then Metal `Kernels.metal`, validated CPU↔Metal + vs-flam3. `VariationDescriptor.canonicalOrder` grows 37→55. Append order (slots 37..54): `waves, popcorn, power, tangent, cross` (paramless) → `pdj, split` (parametric) → `noise, blur, gaussian_blur, arch, square` (RNG simple) → `rays, blade, twintrian` (RNG + Inf/badvalue care) → `flower, conic, parabola` (parametric + RNG).

**Tech Stack:** Swift 6 (Apple Silicon, Metal 4), SwiftPM, XCTest; flam3 oracle on `$PATH` (source `/private/tmp/flam3-build/variations.c`).

**User decisions:** port all 18 corpus-used variations. The 44 unused flam3 variations stay deferred.

## Background (verified by research, 2026-07-22)

flam3 has 99 variations; Emberweft implements 37; **18 of the 62 missing ones appear in a 23k-genome corpus sample** (the other 44 are unused). Ranked by corpus frequency: waves (12,889 — a top-~8 variation!), popcorn (5,820), gaussian_blur (1,626), blur (955), power (584), noise (298), flower (253), cross (215), parabola (137), arch (120), pdj (107), tangent (99), blade (89), conic (61), twintrian (39), rays (24), square (14), split (8). v0.1.0's 7-fixture gate missed these (those fixtures used bubble/eyefish/pie/radial_blur).

### Classification + formulas (verbatim C in `/private/tmp/flam3-build/variations.c`; draw order load-bearing)
- **Paramless non-RNG**: `waves`(:396, **needs affine c,d,e,f** — design wrinkle), `popcorn`(:433, needs e,f), `power`(:472, precalc), `tangent`(:885), `cross`(:1033).
- **Parametric non-RNG**: `pdj`(:579; `pdj_a/b/c/d`, default **0**), `split`(:1603; `split_xsize/ysize`, default 0; note p1 branch is FIRST in source).
- **RNG simple**: `noise`(:696, 2 draws, **input-scaled**), `blur`(:746, 2 draws, NOT input-scaled), `gaussian_blur`(:760, **5 draws**: angle then 4-sum `w*(Σ-2)`), `arch`(:857, 1 draw, `sinr²/cosr` un-guarded), `square`(:900, 2 draws, RNG not paramless).
- **RNG + Inf/badvalue care**: `rays`(:915, 1 draw, `tan(ang)` un-guarded), `blade`(:946, 1 draw), `twintrian`(:998, 1 draw, **`log10(sinr²)` badvalue guard → -30.0**).
- **Parametric + RNG**: `flower`(:1118; `flower_holes/flower_petals` [NOT flower_freq!], 1 draw), `conic`(:1133; `conic_eccentricity/conic_holes`, 1 draw, divides by sqrt no EPS), `parabola`(:1148; `parabola_height/width`, 2 per-axis draws).

### Care items (the hazards)
1. **`waves` needs affine c,d** (not just e,f). The CPU table closure currently receives `ef=(e,f)` only. **Widen the affine plumbing** (Task 1 precursor): pass the full affine (c,d,e,f) to the table closure + evaluate; rings/fan already use e,f; verify they stay byte-identical.
2. **`gaussian_blur` = 5 draws** (angle + 4-sum), NOT 4. Pin order.
3. **`twintrian` badvalue**: `if badvalue(log10(sinr²)+cosr) { = -30.0 }` — both CPU + Metal.
4. **`arch`/`rays` un-guarded Inf** — match flam3 (no per-term guard); keep the `w[N] != 0.0f` dispatch guard.
5. **`flower`/`conic` divide by `precalc_sqrt` with NO +EPS** — match (0/0 at origin).
6. **`square` is RNG** (2 draws), despite the name.
7. **`flower_petals`** (not `flower_freq`).
8. **Draw order**: issue each `rng.isaac01()` as a SEPARATE statement (C++/MSL arg-eval order is unspecified — see `Kernels.metal:594-599`).

### Pattern (unchanged from `404a37b9d`/`68f33c943`/`0c1f722d0`/`aeed7f205`)
- Paramless → CPU `table["<name>"]` closure + Metal `v_<name>` + `if (w[N]!=0.0f) acc += v_<name>(pre, w[N]);`.
- Parametric → same, using `resolve("<name>","<param>",par)`; dispatch `&x.varParams[N*SLOT_WIDTH_MS]`.
- RNG → CPU `evaluate` switch + `private static func` w/ `rng: inout ISAAC`; Metal `v_<name>(p,w,[pr,]rng)`.
- Each appends `d(...)` descriptor + bumps `NUM_XFORM_SLOTS_MS` + the two slot-count test literals (`VariationDescriptorTests`, `ParamChannelParityTests`) + derived floats/bytes.
- Per-variation parity: `SpecialSauceParityTests.assertParity` + `VariationsTests` closed-form/draw-count.

### Fixture genomes (for RealGenomeParityTests, flip to `.gate` per batch)
waves/popcorn: `gen-169/sheep/169.07346`, `gen-169/edges/169.21351`. pdj: `gen-244/edges/244.00178` (+blade), `gen-248/edges/248.12894`. RNG cluster (arch/blur/gaussian_blur): `gen-248/edges/248.39733`. split: `gen-242/edges/242.00825`. twintrian: `gen-243/sheep/243.06390`. flower/conic/parabola/pdj: scan gen-244/gen-248 edges.

---

## Task 1: Affine-widening precursor + paramless non-RNG (waves, popcorn, power, tangent, cross)
**Goal:** Widen the table-closure/evaluate affine arg from `ef=(e,f)` to carry `c,d,e,f` (verify rings/fan byte-identical), then port the 5 paramless non-RNG variations. Slot 37→42.
**Care:** `waves` uses c,d (waves_dx2=1/(e²+EPS), waves_dy2=1/(f²+EPS), nx=tx+c·sin(ty·dx2), ny=ty+d·sin(tx·dy2)); `popcorn` uses e,f; `power` uses precalc sina/cosa/sqrt; `tangent` sin(tx)/cos(ty), tan(ty); `cross` (tx²-ty², r=w·sqrt(1/(s²+EPS))).
**AC:** rings/fan byte-identical (GoldenParity unchanged); 5 new variations CPU closed-form + Metal↔CPU ≥38 dB; slot 37→42; make test-fast green.
**Commit:** `feat(variations): widen affine plumbing + port waves/popcorn/power/tangent/cross`

## Task 2: Parametric non-RNG (pdj, split)
**Goal:** Port `pdj` (4 params, all default 0) + `split` (2 params, default 0; p1 branch FIRST). Slot 42→44.
**AC:** closed-form (hand-traced, incl. split's branch order); Metal↔CPU ≥38 dB; default-0 params preserve goldens; slot 42→44; make test-fast green.
**Commit:** `feat(variations): port pdj + split (parametric non-RNG)`

## Task 3: RNG simple (noise, blur, gaussian_blur, arch, square)
**Goal:** Port 5 RNG-consuming variations. Slot 44→49.
**Care:** noise=input-scaled (tx·r·cosr), blur=NOT input-scaled; gaussian_blur=**5 draws** (angle then 4-sum); arch `sinr²/cosr` un-guarded; square=2 draws (RNG, not paramless).
**AC:** draw-count tests (noise/blur=2, gaussian_blur=5, arch=1, square=2) + closed-form; Metal↔CPU ≥38 dB each; slot 44→49; make test-fast green.
**Commit:** `feat(variations): port noise/blur/gaussian_blur/arch/square (RNG)`

## Task 4: RNG + Inf/badvalue care (rays, blade, twintrian)
**Goal:** Port 3 RNG variations with Inf/badvalue hazards. Slot 49→52.
**Care:** rays `tan(ang)` un-guarded + `r=w/(sumsq+EPS)`; blade 1 draw; twintrian `log10(sinr²)` **badvalue guard → -30.0** (both CPU + Metal).
**AC:** draw-count (rays=1, blade=1, twintrian=1) + closed-form; twintrian badvalue-replacement test; Metal↔CPU ≥38 dB; slot 49→52; make test-fast green.
**Commit:** `feat(variations): port rays/blade/twintrian (RNG + badvalue care)`

## Task 5: Parametric + RNG (flower, conic, parabola)
**Goal:** Port 3 hybrid variations. Slot 52→55.
**Care:** flower `flower_holes/flower_petals` (NOT freq) 1 draw, /sqrt no EPS; conic `conic_eccentricity/holes` 1 draw, /sqrt no EPS; parabola `parabola_height/width` 2 per-axis draws.
**AC:** param defaults 0; draw-count (flower=1, conic=1, parabola=2) + closed-form; Metal↔CPU ≥38 dB; slot 52→55; make test-fast green.
**Commit:** `feat(variations): port flower/conic/parabola (parametric + RNG)`

## Task 6: Flip fixtures + corpus-coverage verify + release v0.1.1
**Goal:** Add the new fixture genomes to `RealGenomeParityTests` as `.gate` (≥38 dB); re-survey the corpus to confirm coverage; release v0.1.1.
**AC:** all new fixture genomes `.gate` ≥38 dB; corpus re-survey shows the 18 variations now render (no remaining high-frequency gaps); GoldenParity + AnimationParity unchanged; tag v0.1.1 + release.
**Commit:** `feat(variations): all 18 corpus variations gated; v0.1.1`

## Verification (whole plan)
`swift test --filter VariationsTests --filter VariationDescriptorTests --filter ParamChannelParityTests --filter SpecialSauceParityTests --filter RealGenomeParityTests` + `make test-fast` + `GoldenParityTests` (byte-identical throughout).

## Notes
- Sequential (shared files). Disable bash sandbox for Metal/flam3. flam3 source: `/private/tmp/flam3-build/variations.c`. Branch: `feat/corpus-variations` from `main` (or continue on main).
