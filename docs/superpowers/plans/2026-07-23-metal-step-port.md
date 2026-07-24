# Metal STEP Palette Port — Implementation Plan

> **❌ DEAD 2026-07-24 — the premise was wrong; the gap is NOT palette/color.** Two approaches failed AND the root cause was re-diagnosed:
> 1. **MSL has no `double`** (Metal is half/float-only) — the planned Double-colorT fix is impossible.
> 2. **Double-single doesn't help** — implemented + tested. Python sim (true fma): df gives only ~2.9e-8 vs float's 5.7e-8 (barely 2× better — the colorT blend toward color∈{0,1} flushes the df low part), and the **same** palette bin-mismatch rate as float. In Metal it *regressed* to **3.82 dB** (likely fast-math `fma` breaking the error-free transforms). Reverted.
> 3. **Root-cause re-diagnosis (definitive):** `colorT` depends ONLY on the ISAAC stream + xform-selection sequence (byte-identical Metal↔CPU) + per-step blend rounding (~5e-8). Even on a spiky palette with LINEAR interp, a 5e-8 colorT error yields ~140 dB (5e-8 × max-255 adjacent diff). So the observed **33.68 dB cannot be color precision** — it can only be **xform-selection sequence desync**: the Float `(x,y)` trajectory diverges from CPU's Double on this fragile 12-xform noise/gaussian_blur attractor, hits `badvalue` (|q|>1e10) at different iterations, and the retry draws different ISAAC values → the whole downstream xform/color sequence diverges. **This is fundamental to Metal's Float position path — no FP64, no faithful fix.** df/fixed-point/STEP are all irrelevant.
>
> **Conclusion:** the Metal↔flam3 gap on complex/fragile real genomes is an irreducible Float-position-trajectory desync, NOT a palette/sampling issue. The CPU palette_mode fix (commit 171083515) was correct for CPU-vs-flam3 (the primary gate, both Double). Metal remains the statistical twin (≥38 dB on smooth genomes; SpecialSauce green). **Accept the limitation.** The original premise — that porting STEP to Metal would close this — was a misdiagnosis inherited from the "Metal step-port regressed to 32 dB" note (that 32 dB was this same Float-position floor, misattributed to palette).
>
> DO NOT re-attempt: MSL `double`, double-single colorT, fixed-point colorT, or a Metal STEP port — analysis above shows none can close a position-desync gap. The RED gate `SpikyPaletteParityTests.swift` (33.68 dB) documents the limitation; convert it to a documenting skip or delete (owner decision).

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the STEP palette-sampling mode (flam3's default) to the Metal renderer with a Double-precision color-index accumulator, so Metal achieves ≥38 dB parity vs CPU (and flam3) on real spiky-palette genomes — closing the last ungated Metal↔flam3 gap.

**Architecture:** The palette lookup happens ONCE, in the chaos kernel's `accumulate` (`Kernels.metal:1742`); the display Stage-3 kernel only log-scales + gammas the already-colored histogram (no second lookup). Metal currently (a) keeps the color coordinate `colorT` in Float and (b) always LINEAR-interpolates the 256-entry dmap. CPU (the oracle, faithful to flam3) keeps `colorT` in Double and branches STEP (default) vs LINEAR (`ChaosGame.swift:231-255`). The bin index `binColor·cmapSize` truncation lands on different dmap entries at Float vs Double bin boundaries, and on a spiky palette adjacent entries differ wildly → large pixel divergence (real-genome Metal↔CPU ≈21 dB today).

**Key insight:** `binColor` depends ONLY on `colorT` + the selected xform's `color`/`colorSpeed` (constants) — NOT on the Float `(x,y)` trajectory. ISAAC + xform-selection are byte-identical Metal↔CPU. So making Metal's `colorT` accumulator Double makes the color path match CPU bit-for-bit (modulo badvalue-retry desync, which is 0 on the traced genomes). The variation math stays Float → perf hit is ~1 Double fma/iteration (negligible).

**Tech Stack:** Metal Shading Language (MSL) on Apple Silicon — `double` is supported (FP64 ~1/32 Float32 rate, but used only for the color fma, not the hot variation loop). Swift 6 strict concurrency.

**User decisions (already made):**
- "Pursue Metal step-port now" (2026-07-23) — toward the standing "100% parity with flam3" goal. CPU path is the oracle and stays untouched.
- Metal↔CPU is STATISTICAL by design (CLAUDE.md rule #2: ≥38 dB, not byte-identical). Target: clear 38 dB on real spiky genomes; byte-exact is not required.
- Dispatch subagents SYNCHRONOUSLY (`run_in_background: false`) — a background subagent survived compaction + orphaned swift procs that deadlocked `.build` (Work A lesson).

---

## File structure

**Production (2 files):**
- `Sources/FlameRenderer/Metal/Kernels.metal` — (1) `blend_color` Float→Double; (2) chaos kernel `colorT`/`qColor`/`binColor` Float→Double; (3) `accumulate` `binColor` param Float→Double + Double index + STEP/LINEAR branch on `fp.paletteMode`; (4) `GPUFrameParams` struct: add `uint paletteMode;` (0=step, 1=linear — mirrors `FlameKit.PaletteMode`).
- `Sources/FlameRenderer/MetalHost.swift` — `buildFrameParams`: set `paletteMode` from `flame.paletteMode`; ensure the Swift `GPUFrameParams` mirror struct adds the field in the SAME position/type (Metal struct layout is load-bearing — Swift and MSL must agree byte-for-byte).

**Tests / goldens (3 files):**
- `Tests/FlameRendererTests/SpecialSauceParityTests.swift` (or a new `SpikyPaletteParityTests.swift`) — add the RED→GREEN gate: Metal↔CPU ≥38 dB on a real spiky-palette genome.
- `Tests/Goldens/m2_baseline_hashes.json` — regenerate the 6 frozen-genome hashes from the new STEP Metal output (current baselines are LINEAR; STEP changes Metal output → byte-identity WILL break until regenerated).
- (Verify-only) `EndToEndParityTests` runtime PSNR gates stay green (expect same-or-better with STEP).

---

## Task 1: RED — spiky-palette Metal↔CPU parity gate

**Goal:** A failing test proving Metal diverges from CPU on a real spiky-palette genome (the gap this port closes).

**Files:**
- Create: `Tests/FlameRendererTests/SpikyPaletteParityTests.swift`
- Reference: `Tests/FlameRendererTests/SpecialSauceParityTests.swift` (the `assertParity` + Metal-render pattern), `Tests/FlameReferenceTests/RealGenomeParityTests.swift` (how real fixtures are loaded from `Tests/Goldens/genomes_real/`).

**Acceptance Criteria:**
- [ ] Test loads a real spiky-palette fixture (e.g., `electricsheep.244.00788.flam3` — 12-xform cross/noise/gaussian_blur, the genome whose Metal↔CPU divergence this port targets; OR a smaller spiky fixture if 00788 is too heavy for a unit test).
- [ ] Renders it on BOTH `MetalRenderer` and `ReferenceRenderer` (CPU) at a matched op-point (start 400×296 @ 500 spp; bump if sampling-noise-limited, mirroring `RealGenomeParityTests.opPointOverrides`).
- [ ] Asserts PSNR ≥ 38 dB (Self.gate) — this is the gate the Metal STEP port must clear.
- [ ] RUNS RED before Task 2 (Metal is LINEAR → spiky divergence → <38 dB).
- [ ] Test is `@MainActor` (Metal API); no `MainActor.assumeIsolated` (CLAUDE.md Swift 6 gotcha).

**Verify:** `swift test --filter SpikyPaletteParityTests` (sandbox disabled) → FAIL with PSNR < 38 dB (expected RED).

**Steps:**
- [ ] Read `SpecialSauceParityTests.swift` to mirror its Metal-render + `ImageComparison.psnr` pattern; read `RealGenomeParityTests` for fixture-loading + matched-op-point.
- [ ] Write the test (load `genomes_real/electricsheep.244.00788.flam3`, sanitize to no-blur/single-flame like RealGenomeParityTests if needed, render both backends at 800×592×1000, assert PSNR ≥ 38).
- [ ] Run → confirm RED (<38 dB). Record the baseline dB in the commit message.

---

## Task 2: Implement the Metal STEP port (Double colorT + STEP branch)

**Goal:** Make Metal's color path match CPU: Double `colorT` accumulator + STEP/LINEAR branch matching `ChaosGame.swift:231-255`. Drives Task 1's gate GREEN.

**Files:**
- Modify: `Sources/FlameRenderer/Metal/Kernels.metal` (`blend_color:187`, `GPUFrameParams:150`, chaos kernel `:1763-1842`, `accumulate:1742-1761`).
- Modify: `Sources/FlameRenderer/MetalHost.swift` (`buildFrameParams` + the Swift `GPUFrameParams` mirror struct).

**Acceptance Criteria:**
- [ ] `blend_color` takes/returns `double` (promote the Float `colorSpeed`/`color` fields inside the fma).
- [ ] Chaos kernel `colorT` init + `qColor` + `binColor` are `double` (`isaac_01` returns float — `double(...)` cast is lossless).
- [ ] `accumulate` takes `double binColor`; computes `double dblIndex0 = binColor * double(fp.cmapSize); int ci0 = int(dblIndex0);` and branches on `fp.paletteMode`: `.step` (0) → `dmap[ci0]` clamped to `[0, cmapSizeM1]`; `.linear` (1) → current interpolation.
- [ ] STEP branch matches CPU `ChaosGame.swift:250-255` exactly (clamp bounds, `interp = dmap[ci0]`, `interpA = dmapAlpha[ci0]`).
- [ ] `GPUFrameParams` (MSL struct) gains `uint paletteMode;` at the END (don't shift existing fields). The Swift mirror struct in MetalHost gains the identical field at the identical position.
- [ ] `buildFrameParams` sets `paletteMode = (flame.paletteMode == .linear) ? 1 : 0`.
- [ ] Compiles (`swift build` clean).
- [ ] Task 1 gate now GREEN (≥38 dB). If PSNR is marginal (35–38 dB), the ~1e-8 Float-colorSpeed/color residual is the cause → widen `colorSpeed`+`color` to `double` in `GPUXform` (+ the Swift mirror) for a bit-exact fma; re-measure.

**Verify:**
- `swift build` clean.
- `swift test --filter SpikyPaletteParityTests` (sandbox off) → PASS ≥38 dB.
- `swift test --filter SpecialSauceParityTests` → still GREEN (smooth synthetic palettes; STEP≈LINEAR, Float≈Double — no regression).

**Steps:** (exact code for the kernel edits — the implementer reads MetalHost for the Swift struct mirror)

- [ ] **`blend_color` → Double:**
```c
static inline double blend_color(GPUXform x, double ct) {
    return (1.0 - double(x.colorSpeed)) * ct + double(x.colorSpeed) * double(x.color);
}
```

- [ ] **`accumulate` → Double `binColor` + STEP branch** (replaces `:1742-1761`):
```c
static inline void accumulate(device AtomicBin* hist, int u, int v, GPUFrameParams fp,
                              constant float3* dmap, constant float* dmapAlpha,
                              double binColor) {
    double dblIndex0 = binColor * double(fp.cmapSize);
    int ci0 = int(dblIndex0);
    float3 interp; float interpA;
    if (fp.paletteMode == 1u) {            // .linear
        float frac;
        if (ci0 >= int(fp.cmapSizeM1)) { ci0 = int(fp.cmapSizeM1) - 1; frac = 1.0f; }
        else { frac = float(dblIndex0) - float(ci0); }
        float m0 = 1.0f - frac;
        interp  = dmap[ci0] * m0 + dmap[ci0 + 1] * frac;
        interpA = dmapAlpha[ci0] * m0 + dmapAlpha[ci0 + 1] * frac;
    } else {                               // .step — flam3 DEFAULT (matches ChaosGame.swift:250-255)
        if (ci0 < 0) { ci0 = 0; }
        else if (ci0 >= int(fp.cmapSizeM1)) { ci0 = int(fp.cmapSizeM1); }
        interp  = dmap[ci0];
        interpA = dmapAlpha[ci0];
    }
    float sc = fp.colorScale;
    auto q = [](float v, float s) -> uint { return uint(clamp(v, 0.0f, 255.0f) * s + 0.5f); };
    uint idx = uint(u) + uint(v) * fp.gridWidth;
    atomic_fetch_add_explicit(&hist[idx].count, 1u, memory_order_relaxed);
    atomic_fetch_add_explicit(&hist[idx].r, q(interp.x, sc), memory_order_relaxed);
    atomic_fetch_add_explicit(&hist[idx].g, q(interp.y, sc), memory_order_relaxed);
    atomic_fetch_add_explicit(&hist[idx].b, q(interp.z, sc), memory_order_relaxed);
    atomic_fetch_add_explicit(&hist[idx].a, q(interpA,  sc), memory_order_relaxed);
}
```

- [ ] **`GPUFrameParams` MSL struct** — add `uint paletteMode;` after `hasFinal;`.

- [ ] **Chaos kernel** (`:1781-1841`) — Float→Double for the color path:
  - `:1784` `float colorT = isaac_01(rng);` → `double colorT = double(isaac_01(rng));`
  - `:1803` `float qColor = blend_color(xf, colorT);` → `double qColor = blend_color(xf, colorT);`
  - `:1816` `p = q; colorT = qColor;` (unchanged, now Double)
  - `:1818` `float2 binP = p; float binColor = colorT;` → `float2 binP = p; double binColor = colorT;`
  - `:1824` `binColor = blend_color(fin, colorT);` (now Double — matches)
  - `:1836` `accumulate(hist, u, v, fp[0], dmap, dmapAlpha, binColor);` (unchanged signature call)

- [ ] **MetalHost.swift** — Swift `GPUFrameParams` mirror: add `var paletteMode: UInt32` in the same position; `buildFrameParams`: `paletteMode = (flame.paletteMode == .linear) ? 1 : 0`.

- [ ] Build + run Task 1 gate → GREEN. Record the new PSNR.

---

## Task 3: Regenerate frozen Metal baselines + verify end-to-end parity

**Goal:** `ParamChannelParityTests` hashes Metal output byte-identically to `m2_baseline_hashes.json`; STEP changes Metal output, so regenerate the baselines and confirm the new output is faithful.

**Files:**
- Modify: `Tests/Goldens/m2_baseline_hashes.json` (6 genomes: final_warp, heart_disc, julia_bubbles, rich, sierpinski, swirl_field).

**Acceptance Criteria:**
- [ ] Regenerate each hash from the NEW STEP Metal render (a tiny helper or in-test print of `SHA256(MetalRenderer.render(...).pixels)` — match the exact op-point `ParamChannelParityTests:60` uses).
- [ ] `swift test --filter ParamChannelParityTests` → GREEN (new baselines).
- [ ] `swift test --filter EndToEndParityTests` + `EndToEndParity3bTests` + `AnimatedFrameParityTests` → GREEN (runtime PSNR ≥38 dB; expect same-or-better with STEP).
- [ ] Confirm the NEW Metal hashes DIFFER from the old (sanity: STEP actually changed output) but the parity gates confirm the new output is faithful.

**Verify:** the four tests above all green.

**Steps:**
- [ ] Read `ParamChannelParityTests.swift` to find the exact render op-point + hash computation it uses.
- [ ] Print the 6 new hashes (add a temporary `print(hex)` in the test, or a one-off script mirroring lines 60-62), run, capture.
- [ ] Write the 6 new hashes into `m2_baseline_hashes.json` (sorted keys, 2-space indent — match existing format).
- [ ] Run the 4 parity tests → all GREEN.

---

## Task 4: Perf re-benchmark (realtime gate)

**Goal:** Confirm the Double-colorT change does not regress the M3 ≥58 fps @ 1080p gate.

**Files:** none (verification only).

**Acceptance Criteria:**
- [ ] `EMBERWEFT_PERF=1 swift test -c release --filter RealtimeCapabilityTests` prints 1080p p50 fps ≥ 58 (and 720p ≥ 58), exit 0.
- [ ] If fps dropped noticeably (>1–2 fps), investigate whether the Double fma is the cause; expected impact is <1 fps (1 Double fma among hundreds of Float ops/iteration).

**Verify:** the perf test prints ≥58 fps at both resolutions, exit 0.

**Steps:**
- [ ] Run the perf gate (sandbox off, release). Record before/after fps.
- [ ] If green → proceed. If marginal (the 1080p gate is ~0.3 fps thin, thermal-sensitive per memory) → re-run on a cool machine; confirm not a regression by comparing to the pre-change number.

---

## Task 5: Full regression + commit

**Goal:** All gates green; one focused commit.

**Files:** none.

**Acceptance Criteria:**
- [ ] `make test-fast` green (FlameKitTests + EmberweftCLITests + FlamePlayerTests).
- [ ] `make test-parity` green (FlameReferenceTests + FlameRendererTests — includes the new SpikyPalette gate, ParamChannel with regen'd baselines, EndToEnd parity, SpecialSauce).
- [ ] No orphan swift procs (`pgrep -fl "swift-test|swift-build|xctest|swiftc"` empty) before launching the gate.
- [ ] Commit (Conventional Commits): `perf(renderer): port STEP palette sampling to Metal (Double color-index) — closes Metal↔flam3 spiky-palette gap`.

**Verify:** full suite green; `git status` clean post-commit.

**Steps:**
- [ ] Clear orphan procs check.
- [ ] `make test-fast` then `make test-parity` (sandbox off; release for the parity half — ~15 min).
- [ ] Commit with a message stating: the before/after Metal↔CPU dB on the spiky genome, the perf fps, and that goldens were regenerated (Metal STEP is the faithful flam3 default).

---

## Self-review checks (coordinator, before execution)

- **Spec coverage:** every file in "File structure" is touched by a task; the RED gate (Task 1) precedes the implementation (Task 2) — TDD. ✓
- **Care items:** MSL `double` support (Apple Silicon — yes); Metal struct layout (Swift mirror must match MSL exactly — Task 2 calls it out); `@MainActor` test; sandbox-off for Metal; synchronous subagent dispatch. ✓
- **Fallback:** if Task 2's gate is marginal (35–38 dB), widen `colorSpeed`+`color` to `double` in `GPUXform` (both MSL + Swift mirror) for a bit-exact fma — already noted in Task 2 AC. If STILL marginal, the residual is badvalue-retry ISAAC desync on that specific genome (investigate per systematic-debugging, don't guess).

## Out of scope
- Byte-exact Metal↔CPU (statistical parity is the design; not required).
- CPU path (the oracle — untouched).
- Density-estimation / display-pipeline changes (the palette lookup is chaos-kernel-only).
