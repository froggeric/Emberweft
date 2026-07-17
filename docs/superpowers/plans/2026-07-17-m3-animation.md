# M3 — Animation & Realtime Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the renderer move — seamless flam3-faithful **loops** of a single still sheep, smooth **transitions** between two sheep, and a **realtime Metal playback engine** — while keeping the proven M1/M2 per-frame render path and the parity model unchanged.

**Architecture:** Animation is a pure FlameKit layer that decides *which* `Flame` to feed the existing renderers per frame. S6-pre widens the data model (`Variation` parameters, `Flame`/`Xform` animation fields) and ports the 16 special-sauce variations to CPU **and** Metal (so transitions render on Metal). S6 ports `sheep_loop`/`sheep_edge` into pure `Loop`/`Transition` types, adds a `GenomeInterpolator` rewrite (linear + log/polar), a two-level-seek `Schedule`, and `PairSelector` (Sequential + SimilarityExploration), and ships `emberweft animate` → PNG sequence + `manifest.json`. S7 wraps it in an actor-isolated `PlaybackDispatcher` + `CAMetalLayer` `FlameUI` with an adaptive-quality controller. Interpolation runs once in FlameKit (Double) and the resulting `Flame` is handed to both renderers, so the genome is byte-identical CPU↔Metal; only the image differs under adaptive quality.

**Tech Stack:** Swift 6 (strict concurrency), Metal 4 / MSL, Foundation, AppKit (`CAMetalLayer`), XCTest. The parity oracle is a locally-built `scottdraves/flam3` (`flam3-genome`/`flam3-animate`), env-var driven — never linked into the repo.

**User decisions (already made):**
- Two segment kinds faithfully ported from flam3: `sheep_loop` (loop), `sheep_edge` (transition); both driven by `blend ∈ [0,1]`.
- Loops = **pure affine rotation `R(θ)·M`** (θ=blend·360°) on each xform's pre-affine 2×2 only; **palette is static** during a loop (seamless because `R(360°)=R(0°)`).
- Transitions generated on the fly from two still sheep; a stored ES edge is just its two endpoint stills.
- Pair selection = similarity metric + ε-greedy exploration guard.
- Tiered frame budget applied uniformly: **160 / 320 / 900**; loops played once then transitioned.
- Faithful port, no source copy: flam3 logic is read and ported; flam3 is never linked/distributed.
- Add a **prerequisite slice S6-pre** (widen data model + port the 16 variations to CPU **and Metal**) before S6.
- `emberweft animate` output = a deterministic PNG frame sequence + `manifest.json`, **not** video (encoding is M6).
- S6 ships with similarity behind a `PairSelector` protocol, `Sequential` impl first for isolated TDD, then `SimilarityExploration`.
- Tier selection is a preset/mode (realtime→160, screensaver→900, export→chosen), not auto-chosen.

> **Spec:** every load-bearing mechanic below is grounded in `scottdraves/flam3` source with stable `file:line` refs in the design spec at `docs/superpowers/specs/2026-07-17-m3-animation-design.md`. Read it before starting any task in Phases B/C — it is the source of truth for the loop/transition/special-sauce/palette/oracle details this plan summarizes.

---

## File Structure

New files (all under existing targets — no new targets except where noted):

| File | Target | Responsibility |
|---|---|---|
| `Sources/FlameKit/VariationDescriptor.swift` | FlameKit | Canonical variation→param registry: names, param tables, defaults, special-sauce rest values, name→(slot,index) map. Single source of truth for parser, serializer, CPU table, and Metal host packer. |
| `Sources/FlameKit/AnimationTypes.swift` | FlameKit | `TempInterpolation`, `MatrixInterpolationType`, `PaletteInterpolation` enums; widening of `Variation`/`Xform`/`Flame` lives in `Genome.swift`. |
| `Sources/FlameKit/GenomeInterpolator.swift` | FlameKit | Rewrite of `Interpolation.swift`: `.linear` + `.log` (polar) matrix blend with `wind`-anchored unwrap, per-column magnitude guard, post-identity special case, HSV palette blend. Thin `interpolate(a,b,t)` shim. |
| `Sources/FlameKit/SpecialSauce.swift` | FlameKit | `flam3_align` port: pad to equal xform/final count, copy parametric params from neighbour, apply per-variation rest positions. |
| `Sources/FlameKit/RefAngles.swift` | FlameKit | `establish_asymmetric_refangles` — writes `xform.wind[col]` to anchor the log unwrap. |
| `Sources/FlameKit/Loop.swift` | FlameKit | `Loop.blend(sheep, t)` = `sheep_loop` port (pure `R(θ)·M` rotation). |
| `Sources/FlameKit/Transition.swift` | FlameKit | `Transition.blend(A, B, t, stagger)` = `sheep_edge` port (orchestrates align → refangles → rotate both → interpolate). |
| `Sources/FlameKit/Schedule.swift` | FlameKit | `Segment`/`Schedule` — pure two-level seek (O(1) global-frame→segmentId; O(segments) to extend the selector walk). |
| `Sources/FlameKit/PairSelector.swift` | FlameKit | `PairSelector` protocol, `Sequential`, `SimilarityExploration` (ε-greedy). |
| `Sources/FlameKit/FeatureVector.swift` | FlameKit | Per-sheep feature vector (sorted-array storage — F1 determinism rule) + cache record type. |
| `Sources/FlameKit/FeatureCache.swift` | FlameKit | Incremental read/scan/rebuild of `genomes/.feature_cache/`. |
| `Sources/FlameKit/Manifest.swift` | FlameKit | `manifest.json` Codable model (F9 schema: `manifestVersion`, top-level `stagger`, `interpolationType: null` on loop rows). |
| `Sources/EmberweftCLI/AnimateCommand.swift` | EmberweftCLI | `emberweft animate` subcommand → PNG sequence + manifest. |
| `Sources/FlamePlayer/PlaybackDispatcher.swift` | FlamePlayer | Actor-isolated realtime driver: feeds `Schedule` frames to `MetalRenderer` at target fps, triple-buffered, prefetches next sheep. |
| `Sources/FlamePlayer/AdaptiveQualityController.swift` | FlamePlayer | Pure controller: (measured fps, thermalState) → iteration budget with hysteresis. |
| `Sources/FlamePlayer/FlameUI.swift` | FlamePlayer | `@MainActor` `NSView` subclass wrapping `CAMetalLayer`. |

Modified files: `Sources/FlameKit/Genome.swift` (widen structs), `Sources/FlameKit/Flam3Parser.swift` + `Flam3Serializer.swift` (params + animation fields), `Sources/FlameKit/Interpolation.swift` (becomes the `.linear` shim delegating to `GenomeInterpolator`), `Sources/FlameKit/Variations.swift` (14 new CPU formulas **and** `canonicalOrder` grown 19 → 33), `Sources/FlameRenderer/MetalHost.swift` (`GPUXform` flat packer + `packXforms`), `Sources/FlameRenderer/ChaosGameMetal.swift` (xform buffer now built from the flat packed `[Float]`, not `[GPUXform]`), `Sources/FlameRenderer/Metal/Kernels.metal` (`GPUXform` mirror: `varWeights[33]` + `varParams[264]`, 14 MSL variations, `apply_xform_body` grown to a 33-line chain), `Sources/EmberweftCLI/CLI.swift` (wire `animate` + hidden `_feature-score`), `Package.swift` (new files auto-included by path; **add the `FlamePlayerTests` target** in Task 20 — `FlamePlayer` is a product/target but has NO test target today). New test artifacts: `Tests/Goldens/m2_baseline_hashes.json` (Task 5 additivity oracle), `Tests/FlameKitTests/Fixtures/similarity_pair/` (Task 16 cross-process determinism pair). Docs: `transitions.md`, `playback-modes.md`, `roadmap.md`, `testing.md`, `architecture.md`, `CLAUDE.md`, `CHANGELOG.md`.

---

## Phase A — S6-pre: data model + 16 special-sauce variations (CPU + Metal)

The prerequisite slice. It lands first as an isolated, gate-keeping slice; M1/M2 stay green via the additive variation set and the `.linear` interpolation shim.

### Task 1: VariationDescriptor registry

**Goal:** Create the **single source of truth** for all variation metadata: the canonical **33-slot order** (M1's 19 + the 14 NEW special-sauce; `spherical`/`polar` counted once), the per-variation param names/defaults, the special-sauce rest values, and the fixed name→(slot,index) maps — so the parser, serializer, CPU table, Metal host packer, and `apply_xform_body` dispatch all share one definition. `Variations.canonicalOrder` becomes a thin re-export of `VariationDescriptor.canonicalOrder`.

**Files:**
- Create: `Sources/FlameKit/VariationDescriptor.swift`
- Test: `Tests/FlameKitTests/VariationDescriptorTests.swift`

**Acceptance Criteria:**
- [ ] `VariationDescriptor` has an entry for **every one of the 33 canonical names** (M1's 19 + the 14 new special-sauce; `spherical`/`polar` counted once, NOT duplicated). Each entry carries the canonical name, the ordered param-name list, defaults, and rest (empty params for the parameterless M1 set + `linear`/`rings`/`fan`).
- [ ] `VariationDescriptor.canonicalOrder` is the fixed 33-name array; `canonicalSlot(for:)` returns its index; `slotIndex(variation:param:)` returns the intra-slot index (MAX_PARAMS_PER_SLOT = 6). `Variations.canonicalOrder` is `public static let canonicalOrder = VariationDescriptor.canonicalOrder` (one-liner re-export) so `MetalHost` call sites are unchanged.
- [ ] Parameterless variations (`linear`, `spherical`, `polar`, `rings`, `fan`, and the 14 M1 ones) report an empty param list.
- [ ] A unit test asserts: `canonicalOrder.count == 33`; no duplicates; `spherical`/`polar` appear exactly once; every name in `canonicalOrder` has a descriptor; and the parametric entries match the spec's per-variation param table (names, defaults, rest, intra-slot indices).

**Verify:** `swift test --filter VariationDescriptorTests` → all assertions pass.

**Steps:**

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import FlameKit

final class VariationDescriptorTests: XCTestCase {
    func testBlobParams() {
        let d = VariationDescriptor.descriptor(for: "blob")!
        XCTAssertEqual(d.parameters, ["blob_low", "blob_high", "blob_waves"])
        XCTAssertEqual(d.defaults, ["blob_low": 0.0, "blob_high": 1.0, "blob_waves": 1.0])
        XCTAssertEqual(d.rest, ["blob_low": 1.0, "blob_high": 1.0, "blob_waves": 1.0]) // Group B
    }
    func testSuperShapeSlots() {
        let d = VariationDescriptor.descriptor(for: "super_shape")!
        XCTAssertEqual(d.parameters,
            ["super_shape_rnd", "super_shape_m", "super_shape_n1", "super_shape_n2", "super_shape_n3", "super_shape_holes"])
        XCTAssertEqual(VariationDescriptor.slotIndex(variation: "super_shape", param: "super_shape_n3"), 4)
        XCTAssertEqual(d.parameters.count, 6)  // MAX_PARAMS_PER_SLOT driver
    }
    func testParameterless() {
        for name in ["linear", "spherical", "polar", "rings", "fan"] {
            XCTAssertTrue(VariationDescriptor.descriptor(for: name)!.parameters.isEmpty, name)
        }
    }
    func testGroupCRestUsesSwapAffineNotParams() {
        // fan/rings (Group C): var=1 + swap-affine [0,1;1,0;0,0]; NO param rest.
        XCTAssertTrue(VariationDescriptor.descriptor(for: "fan")!.parameters.isEmpty)
        XCTAssertTrue(VariationDescriptor.descriptor(for: "rings")!.parameters.isEmpty)
    }
    func testAllSixteenPresent() {
        let names = ["spherical","polar","rings","fan","blob","fan2","rings2","perspective",
                     "julian","juliascope","ngon","curl","rectangles","super_shape","wedge_julia","wedge_sph"]
        for n in names { XCTAssertNotNil(VariationDescriptor.descriptor(for: n), n) }
    }
    func testCanonicalOrderIsSingleAuthority() {
        XCTAssertEqual(VariationDescriptor.canonicalOrder.count, 33)
        XCTAssertEqual(Set(VariationDescriptor.canonicalOrder).count, 33, "duplicate canonical name")
        // spherical/polar counted ONCE (spec's "35" double-counted them; faithful = 33).
        XCTAssertEqual(VariationDescriptor.canonicalOrder.filter { $0 == "spherical" }.count, 1)
        XCTAssertEqual(VariationDescriptor.canonicalOrder.filter { $0 == "polar" }.count, 1)
        // Every canonical name resolves to a descriptor + a slot index.
        for n in VariationDescriptor.canonicalOrder {
            XCTAssertNotNil(VariationDescriptor.descriptor(for: n), n)
            XCTAssertNotNil(VariationDescriptor.canonicalSlot(for: n), n)
        }
        // The 14 NEW special-sauce names are all present (the 16 minus spherical/polar).
        let newOnes = ["rings","fan","blob","fan2","rings2","perspective","julian","juliascope",
                       "ngon","curl","rectangles","super_shape","wedge_julia","wedge_sph"]
        for n in newOnes { XCTAssertNotNil(VariationDescriptor.canonicalSlot(for: n), n) }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter VariationDescriptorTests`
Expected: FAIL (cannot find `VariationDescriptor` in scope).

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// SINGLE SOURCE OF TRUTH for all variation metadata: the canonical 33-slot
/// order (M1's 19 + the 14 NEW special-sauce; spherical/polar counted once),
/// per-variation params/defaults, special-sauce rest values, and the
/// name→(slot, intra-slot-index) maps. Shared by the parser, serializer, CPU
/// `Variations` table, the Metal host packer, and `apply_xform_body` dispatch.
/// `Variations.canonicalOrder` is a one-line re-export of `canonicalOrder` so
/// existing `MetalHost` call sites are unchanged. Pinned to the spec's
/// "Param-channel layout" + "Special-sauce padding" tables.
public struct VariationDescriptor: Sendable {
    public let name: String
    public let parameters: [String]                 // ordered (intra-slot order)
    public let defaults: [String: Double]
    public let rest: [String: Double]               // special-sauce rest; key absent => stays at default

    // ---- canonical slot order (the 33-device-slot layout) ----
    /// Fixed 33-name order. First 19 == the M1 set (in its existing order, so the
    /// M1 Metal host `idxMap`/CPU `evaluate` stay slot-stable); then the 14 NEW
    /// special-sauce names in documented order. spherical/polar appear ONCE.
    public static let canonicalOrder: [String] = [
        // --- M1's 19 (do not reorder: existing slots 0..18) ---
        "bent","cosine","cylinder","diamond","disc","ex","exponential","fisheye",
        "handkerchief","heart","horseshoe","hyperbolic","julia","linear","polar",
        "sinusoidal","spherical","spiral","swirl",
        // --- 14 NEW special-sauce (slots 19..32) ---
        "rings","fan","blob","fan2","rings2","perspective","julian","juliascope",
        "ngon","curl","rectangles","super_shape","wedge_julia","wedge_sph",
    ]
    /// Canonical device-slot index for a variation name (0..<33), or nil if unknown.
    public static func canonicalSlot(for name: String) -> Int? {
        canonicalOrder.firstIndex(of: name)
    }
    /// Intra-slot param index (0..<MAX_PARAMS_PER_SLOT). Used by the Metal host
    /// packer and mirrored implicitly by the MSL per-variation functions.
    public static func slotIndex(variation: String, param: String) -> Int {
        guard let d = descriptor(for: variation) else { return 0 }
        return d.parameters.firstIndex(of: param) ?? 0
    }
    public static let maxParamsPerSlot = 6          // driven by super_shape

    public static func descriptor(for name: String) -> VariationDescriptor? { table[name] }

    // name -> (ordered params, defaults, rest-overrides). Covers ALL 33 canonical
    // names so canonicalOrder and the descriptor table cannot drift. Defaults/rest
    // source-cited to flam3.h / parser.c / variations.c in the spec param table.
    private static let table: [String: VariationDescriptor] = {
        var t: [String: VariationDescriptor] = [:]
        func d(_ name: String, _ params: [String], _ defaults: [String: Double],
               _ rest: [String: Double] = [:]) {
            t[name] = VariationDescriptor(name: name, parameters: params, defaults: defaults, rest: rest)
        }
        // --- M1's 19 (all parameterless; every canonicalOrder name must be
        //     registered so the order table and descriptor table cannot drift) ---
        d("bent", [], [:]); d("cosine", [], [:]); d("cylinder", [], [:]); d("diamond", [], [:])
        d("disc", [], [:]); d("ex", [], [:]); d("exponential", [], [:]); d("fisheye", [], [:])
        d("handkerchief", [], [:]); d("heart", [], [:]); d("horseshoe", [], [:]); d("hyperbolic", [], [:])
        d("julia", [], [:]); d("linear", [], [:]); d("polar", [], [:])        // Group A
        d("sinusoidal", [], [:]); d("spherical", [], [:])                     // Group A
        d("spiral", [], [:]); d("swirl", [], [:])
        // --- 14 NEW special-sauce ---
        d("rings", [], [:])                            // Group C (swap-affine, no params)
        d("fan", [], [:])                              // Group C
        d("blob", ["blob_low","blob_high","blob_waves"],
          ["blob_low":0,"blob_high":1,"blob_waves":1],
          ["blob_low":1,"blob_high":1,"blob_waves":1])
        d("curl", ["curl_c1","curl_c2"], ["curl_c1":1,"curl_c2":0], ["curl_c1":0,"curl_c2":0])
        d("rectangles", ["rectangles_x","rectangles_y"], ["rectangles_x":1,"rectangles_y":1], ["rectangles_x":0,"rectangles_y":0])
        d("fan2", ["fan2_x","fan2_y"], ["fan2_x":0,"fan2_y":0], ["fan2_x":0,"fan2_y":0])
        d("rings2", ["rings2_val"], ["rings2_val":0], ["rings2_val":0])
        d("perspective", ["perspective_angle","perspective_dist"],
          ["perspective_angle":0,"perspective_dist":0], ["perspective_angle":0])  // dist KEPT
        d("super_shape", ["super_shape_rnd","super_shape_m","super_shape_n1","super_shape_n2","super_shape_n3","super_shape_holes"],
          ["super_shape_rnd":0,"super_shape_m":0,"super_shape_n1":1,"super_shape_n2":1,"super_shape_n3":1,"super_shape_holes":0],
          ["super_shape_rnd":0,"super_shape_n1":2,"super_shape_n2":2,"super_shape_n3":2,"super_shape_holes":0])  // m KEPT
        d("ngon", ["ngon_sides","ngon_power","ngon_circle","ngon_corners"],
          ["ngon_sides":5,"ngon_power":3,"ngon_circle":1,"ngon_corners":2])
        d("julian", ["julian_power","julian_dist"], ["julian_power":1,"julian_dist":1])
        d("juliascope", ["juliascope_power","juliascope_dist"], ["juliascope_power":1,"juliascope_dist":1])
        d("wedge_julia", ["wedge_julia_angle","wedge_julia_count","wedge_julia_power","wedge_julia_dist"],
          ["wedge_julia_angle":0,"wedge_julia_count":1,"wedge_julia_power":1,"wedge_julia_dist":0])
        d("wedge_sph", ["wedge_sph_angle","wedge_sph_count","wedge_sph_hole","wedge_sph_swirl"],
          ["wedge_sph_angle":0,"wedge_sph_count":1,"wedge_sph_hole":0,"wedge_sph_swirl":0])
        return t
    }()
}
```

> **Re-export:** in `Sources/FlameKit/Variations.swift`, replace the existing 19-element `canonicalOrder` literal with `public static let canonicalOrder: [String] = VariationDescriptor.canonicalOrder` (Task 5 does this as part of growing to 33; Task 1 defines the authority here).

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter VariationDescriptorTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlameKit/VariationDescriptor.swift Tests/FlameKitTests/VariationDescriptorTests.swift
git commit -m "feat(flamekit): VariationDescriptor registry for variation params + special-sauce rest"
```

---

### Task 2: Widen the genome model

**Goal:** Widen `Variation` to carry named parameters, add the `Flame`/`Xform` animation fields, and introduce the interpolation/palette enums. Pure value-type changes; build stays green and existing tests unchanged.

**Files:**
- Modify: `Sources/FlameKit/Genome.swift` (add fields to `Variation`/`Xform`/`Flame`)
- Create: `Sources/FlameKit/AnimationTypes.swift`
- Test: `Tests/FlameKitTests/GenomeTests.swift` (append cases)

**Acceptance Criteria:**
- [ ] `Variation` has `parameters: [String: Double]` (default `[:]`); existing `Variation(name:weight:)` call sites compile unchanged.
- [ ] `Xform` has `animate: Double` (default `1.0`), `padding: Int` (default `0`), `wind: SIMD2<Double>` (default `.zero`).
- [ ] `Flame` has `interpolation: TempInterpolation` (default `.linear`), `interpolationType: MatrixInterpolationType` (default `.log`), `paletteInterpolation: PaletteInterpolation` (default `.hsvCircular`), `hueRotation: Double` (default `0`), and `hsvRgbPaletteBlend: Double` (default `0`). Existing `hueShift` is retained unchanged (round-trip only — F4). `hsvRgbPaletteBlend` models flam3's `hsv_rgb_palette_blend` — the live rgb↔hsv mix fraction consumed by the hsv_circular/rgb palette blend (`interpolation.c:383-384,432-433`); it is NOT one of the dead palette-hack fields and MUST be modeled (default 0 = pure HSV shorter-arc, the ES norm).
- [ ] The palette-hack fields (`paletteIndex0/1`, `hueRotation0/1`, `paletteBlend`) are NOT added (dead metadata — F7).
- [ ] `swift build` + the existing `swift test` suite are green.

**Verify:** `swift build && swift test --filter GenomeTests` → build succeeds, tests pass.

**Steps:**

- [ ] **Step 1: Write the failing test** (append to `GenomeTests.swift`)

```swift
func testVariationCarriesParameters() {
    var v = Variation(name: "curl", weight: 1)
    v.parameters = ["curl_c1": 0.5, "curl_c2": -0.2]
    XCTAssertEqual(v.parameters["curl_c1"], 0.5)
    // default-init path still works (existing call sites)
    let bare = Variation(name: "linear", weight: 1)
    XCTAssertEqual(bare.parameters, [:])
}
func testXformAnimationFields() {
    let x = Xform()
    XCTAssertEqual(x.animate, 1.0)        // random xforms default to rotating
    XCTAssertEqual(x.padding, 0)
    XCTAssertEqual(x.wind, SIMD2<Double>.zero)
}
func testFlameAnimationFields() {
    let f = Flame()
    XCTAssertEqual(f.interpolation, .linear)
    XCTAssertEqual(f.interpolationType, .log)        // ES default
    XCTAssertEqual(f.paletteInterpolation, .hsvCircular)
    XCTAssertEqual(f.hueRotation, 0)
    XCTAssertEqual(f.hsvRgbPaletteBlend, 0)          // live rgb↔hsv mix fraction (default 0 = pure HSV)
    XCTAssertEqual(f.hueShift, 0)                    // retained, round-trip only (F4)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter GenomeTests`
Expected: FAIL (no `parameters` on `Variation`; no enum cases / fields).

- [ ] **Step 3: Write minimal implementation**

Create `Sources/FlameKit/AnimationTypes.swift`:

```swift
import Foundation

/// flam3 `interpolation` (temporal smoothing of the blend scalar). flam3.c:1284.
public enum TempInterpolation: String, Sendable, Codable {
    case linear, smooth
}

/// flam3 `interpolation_type` (how xform matrices blend). flam3.c:1312 default log.
public enum MatrixInterpolationType: String, Sendable, Codable {
    case linear, log, compat, older
}

/// flam3 `palette_interpolation`. flam3.h:75-78; default hsv_circular.
public enum PaletteInterpolation: String, Sendable, Codable {
    case sweep, rgb, hsv, hsvCircular     // "hsv_circular"
}
```

In `Genome.swift`, widen `Variation` (note: it becomes mutable-on-params; keep `let name/weight` — params are the only added stored property):

```swift
public struct Variation: Sendable, Equatable {
    public let name: String
    public let weight: Double
    public var parameters: [String: Double]
    public init(name: String, weight: Double, parameters: [String: Double] = [:]) {
        (self.name, self.weight, self.parameters) = (name, weight, parameters)
    }
}
```

Widen `Xform` (add stored properties + init params with defaults, preserving existing argument order/defaults):

```swift
public var animate: Double       // 0 => skip rotation (symmetry xforms); default 1.0
public var padding: Int          // nonzero => this xform is a flam3_align pad slot
public var wind: SIMD2<Double>   // refangle anchors for log unwrap (interpolation.c:759)
```
Add to the initializer: `animate: Double = 1.0, padding: Int = 0, wind: SIMD2<Double> = .zero` and assign them.

Widen `Flame` (add stored properties + init params with defaults):

```swift
public var interpolation: TempInterpolation
public var interpolationType: MatrixInterpolationType
public var paletteInterpolation: PaletteInterpolation
public var hueRotation: Double
public var hsvRgbPaletteBlend: Double   // flam3 hsv_rgb_palette_blend (LIVE palette mix fraction)
```
Add to the initializer (after `hueShift`): `interpolation: TempInterpolation = .linear, interpolationType: MatrixInterpolationType = .log, paletteInterpolation: PaletteInterpolation = .hsvCircular, hueRotation: Double = 0, hsvRgbPaletteBlend: Double = 0`.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift build && swift test --filter GenomeTests`
Expected: PASS (and the full suite stays green — additive fields with defaults).

- [ ] **Step 5: Commit**

```bash
git add Sources/FlameKit/Genome.swift Sources/FlameKit/AnimationTypes.swift Tests/FlameKitTests/GenomeTests.swift
git commit -m "feat(flamekit): widen Variation/Flame/Xform for animation + params"
```

---

### Task 3: Parser + serializer extensions for params & animation fields

**Goal:** Parse `<var>_<param>` attributes into `Variation.parameters`, parse/emit the new `Flame`/`Xform` animation attributes, and prove round-trip fidelity on a parametric genome.

**Files:**
- Modify: `Sources/FlameKit/Flam3Parser.swift`
- Modify: `Sources/FlameKit/Flam3Serializer.swift`
- Test: `Tests/FlameKitTests/ParserTests.swift`, `Tests/FlameKitTests/SerializerTests.swift`

**Acceptance Criteria:**
- [ ] A `<xform curl="1" curl_c1="0.5" curl_c2="-0.2" .../>` parses to a `Variation(name:"curl", weight:1)` with `parameters == ["curl_c1":0.5, "curl_c2":-0.2]`.
- [ ] Variation-weight attrs are recognized by name; a `<varname>_<paramname>` attr is routed to that variation's `parameters` (validated against `VariationDescriptor`); unknown attrs still round-trip as zero-contribution weights (existing behavior preserved).
- [ ] **Param-without-weight edge case (pinned):** a parametric attr whose base weight attr is absent (e.g. `<xform blob_low="0.2"/>` with no `blob="…"`) is attached to a synthesized `Variation(name:"blob", weight:0, parameters:["blob_low":0.2])` so the params survive a round-trip; the serializer emits params for any variation whose `parameters` is non-empty **regardless of weight** (override the `where v.weight != 0` weight-only filter for the param-emission loop). This matches flam3, which identifies the variation from the weight attr but still stores whatever params the file carries. Add a dedicated round-trip test for this case.
- [ ] **No param-prefix collisions:** the 12 parametric variation names have pairwise-distinct `<name>_` prefixes (`blob_`, `curl_`, `rectangles_`, `fan2_`, `rings2_`, `perspective_`, `super_shape_`, `ngon_`, `julian_`, `juliascope_`, `wedge_julia_`, `wedge_sph_`); in particular `"fan2_…".hasPrefix("fan_") == false` and `"rings2_…".hasPrefix("rings_") == false`. A test asserts `matchParamAttribute` resolves every parametric attr to exactly one variation.
- [ ] Parser reads `animate` (xform), `interpolation`/`interpolation_type`/`palette_interpolation`/`hue_rotation`/`hsv_rgb_palette_blend` (flame); serializer emits them all. `hue` (hueShift) and `hue_rotation` (hueRotation) are both read and both emitted; `hsv_rgb_palette_blend` (hsvRgbPaletteBlend) is read and emitted (non-default only, to keep typical genomes compact).
- [ ] `parse(serialize(parse(x)))` round-trips a parametric genome with `super_shape`/`blob`/`curl` params and `animate`/`interpolation_type=log` set.

**Verify:** `swift test --filter ParserTests --filter SerializerTests` → PASS.

**Steps:**

- [ ] **Step 1: Write the failing test** (append to `ParserTests.swift`)

```swift
func testParsesVariationParameters() {
    let xml = """
    <?xml version="1.0"?>
    <flames><flame><xform weight="1" coefs="1 0 0 1 0 0" curl="1" curl_c1="0.5" curl_c2="-0.2"/></flame></flames>
    """
    let f = try! Flam3Parser.parse(xml.data(using: .utf8)!)[0]
    let curl = f.xforms[0].variations.first { $0.name == "curl" }!
    XCTAssertEqual(curl.weight, 1)
    XCTAssertEqual(curl.parameters["curl_c1"]!, 0.5, accuracy: 1e-9)
    XCTAssertEqual(curl.parameters["curl_c2"]!, -0.2, accuracy: 1e-9)
}
func testParsesAnimationAttributes() {
    let xml = """
    <?xml version="1.0"?>
    <flames><flame interpolation_type="log" palette_interpolation="hsv_circular" hue_rotation="0.25">
      <xform weight="1" coefs="1 0 0 1 0 0" animate="0" linear="1"/></flame></flames>
    """
    let f = try! Flam3Parser.parse(xml.data(using: .utf8)!)[0]
    XCTAssertEqual(f.interpolationType, .log)
    XCTAssertEqual(f.paletteInterpolation, .hsvCircular)
    XCTAssertEqual(f.hueRotation, 0.25, accuracy: 1e-9)
    XCTAssertEqual(f.xforms[0].animate, 0)
}
```

Append to `SerializerTests.swift`:

```swift
func testRoundTripsParametricGenome() {
    let xml = """
    <?xml version="1.0"?>
    <flames><flame interpolation_type="log" hue_rotation="0.1">
      <xform weight="1" coefs="1 0 0 1 0 0" animate="1" blob="1" blob_low="0.2" blob_high="0.8" blob_waves="3"/>
      <xform weight="1" coefs="1 0 0 1 0 0" super_shape="1" super_shape_n1="2" super_shape_n2="2" super_shape_n3="2"/>
    </flame></flames>
    """
    let f1 = try! Flam3Parser.parse(xml.data(using: .utf8)!)[0]
    let re = Flam3Serializer.serialize([f1])
    let f2 = try! Flam3Parser.parse(re.data(using: .utf8)!)[0]
    XCTAssertEqual(f1.interpolationType, f2.interpolationType)
    XCTAssertEqual(f1.hueRotation, f2.hueRotation, accuracy: 1e-9)
    let blob1 = f1.xforms[0].variations.first { $0.name == "blob" }!
    let blob2 = f2.xforms[0].variations.first { $0.name == "blob" }!
    XCTAssertEqual(blob1.parameters, blob2.parameters)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ParserTests --filter SerializerTests`
Expected: FAIL (params/attrs not parsed).

- [ ] **Step 3: Write minimal implementation**

In `Flam3Parser.makeFlame`, read the new flame attributes (defaults already match the struct defaults):

```swift
f.interpolation = attr["interpolation"].flatMap { TempInterpolation(rawValue: $0) } ?? .linear
f.interpolationType = attr["interpolation_type"].flatMap { MatrixInterpolationType(rawValue: $0) } ?? .log
f.paletteInterpolation = attr["palette_interpolation"].flatMap { PaletteInterpolation(rawValue: $0) } ?? .hsvCircular
f.hueRotation = attr["hue_rotation"].flatMap { Double($0) } ?? 0
f.hsvRgbPaletteBlend = attr["hsv_rgb_palette_blend"].flatMap { Double($0) } ?? 0
```

In `Flam3Parser.makeXform`, replace the variation-attribute scan so parametric attrs route to `parameters`. Add `animate` reading and reserve the parametric attr prefixes:

```swift
x.animate = attr["animate"].flatMap { Double($0) } ?? 1.0   // random default rotates
let reserved: Set<String> = [
    "weight","color","color_speed","symmetry","coefs","post","chaos","opacity","animate","name",
    "interpolation","interpolation_type","palette_interpolation","hue_rotation","hue",
]
var weights: [(String, Double)] = []
var paramsByVariation: [String: [String: Double]] = [:]
for (k, v) in attr where !reserved.contains(k) {
    guard let val = Double(v) else { continue }
    // A parametric attr is "<varname>_<paramname>" where <varname> is a known
    // descriptor whose parameter list contains the full attr. Try the longest
    // matching known variation prefix.
    // The matcher returns the FULL xml name as `hit.param` (e.g. "blob_low"),
    // matching the descriptor's full-name storage, so the dict key is what
    // `evaluate`/`v_blob` will read back. Try the unique matching variation.
    if let hit = VariationDescriptor.matchParamAttribute(k) {
        paramsByVariation[hit.variation, default: [:]][hit.param] = val
    } else {
        weights.append((k, val))
    }
}
// Param-without-weight edge case (pinned): a parametric attr whose base weight
// attr is absent (e.g. <xform blob_low="0.2"/> with no blob="…") must still
// round-trip. Synthesize a weight-0 entry for any variation that appears ONLY
// in paramsByVariation so the map below creates a Variation for it (the
// serializer's separate param-emission loop then emits its params regardless
// of weight).
let weightedNames = Set(weights.map { $0.0 })
for (varName, _) in paramsByVariation where !weightedNames.contains(varName) {
    weights.append((varName, 0))
}
x.variations = weights.sorted { $0.0 < $1.0 }.map { name, w in
    Variation(name: name, weight: w, parameters: paramsByVariation[name] ?? [:])
}
```

Add to `VariationDescriptor` a helper that returns the `(variation, param)` for an attribute key, preferring a known-variation prefix:

```swift
/// Resolve a parametric XML attr key against the known tables. Returns nil for
/// a plain variation-weight attr (e.g. "linear", "curl" with no suffix).
///
/// The descriptor stores each param under its FULL XML name (`blob_low`,
/// `fan2_x`, `super_shape_n3`, …) — NOT the short suffix — so that the
/// serializer's `for p in d.parameters` emit loop produces `blob_low="…"`
/// verbatim and `evaluate`/`v_blob` read the same key from `params`. Therefore
/// the matcher checks the FULL `key` against `d.parameters` (after the
/// `<varname>_` prefix gate rules out plain weight attrs). Stripping the prefix
/// and checking the short suffix would ALWAYS miss (there is no "low" entry,
/// only "blob_low") — do not revert to that. The 12 parametric prefixes are
/// pairwise-distinct once the parameterless `fan`/`rings`/`julia` are excluded
/// (empty `parameters`), so iteration order is irrelevant: at most one hit.
public static func matchParamAttribute(_ key: String) -> (variation: String, param: String)? {
    for (varName, d) in table where !d.parameters.isEmpty {
        if key.hasPrefix(varName + "_") && d.parameters.contains(key) {
            return (varName, key)   // param == full XML name (e.g. "blob_low")
        }
    }
    return nil
}
```

In `Flam3Serializer.xformString`, emit params for every variation that carries them (weight-zero included, so the param-without-weight round-trip holds), in addition to the existing weight emission:

```swift
if x.animate != 1 { a += " animate=\"\(f6(x.animate))\"" }
// ... existing variation-weight emission (`where v.weight != 0`, unchanged) ...
// param emission is a SEPARATE loop so weight-0 parametric variations survive:
for v in x.variations.sorted(by: { $0.name < $1.name }) where !v.parameters.isEmpty {
    let d = VariationDescriptor.descriptor(for: v.name)
    for p in d?.parameters ?? [] {
        if let val = v.parameters[p] { a += " \(p)=\"\(f6(val))\"" }
    }
}
```

In `Flam3Serializer.flameString`, emit the new flame attrs near `hue`/`time`:

```swift
a += " interpolation_type=\"\(f.interpolationType.rawValue)\""
a += " palette_interpolation=\"\(f.paletteInterpolation.rawValue)\""
a += " hue_rotation=\"\(f6(f.hueRotation))\""
if f.hsvRgbPaletteBlend != 0 { a += " hsv_rgb_palette_blend=\"\(f6(f.hsvRgbPaletteBlend))\"" }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ParserTests --filter SerializerTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlameKit/Flam3Parser.swift Sources/FlameKit/Flam3Serializer.swift Sources/FlameKit/VariationDescriptor.swift Tests/FlameKitTests/ParserTests.swift Tests/FlameKitTests/SerializerTests.swift
git commit -m "feat(flamekit): parse/serialize variation params + animation attributes"
```

---

### Task 4: Port the 14 special-sauce variation formulas to CPU

**Goal:** Implement the 14 new special-sauce variation formulas (spherical/polar already exist) in the CPU `Variations` table, faithful to flam3 `variations.c`, each TDD'd with a known-input check. `knownNames` grows; unknown-name warnings for these names stop.

> **VERIFIED GROUND TRUTH (read before implementing).** A direct read of `scottdrakes/flam3` `variations.c` settles two facts the spec's prose gets wrong, and both are load-bearing for the M1 RNG-alignment + parity model:
>
> 1. **Four of the 16 ARE RNG-consuming** — `var32_juliaN_generic` (1 `flam3_random_isaac_01` draw), `var33_juliaScope_generic` (1 draw), `var50_supershape` (1 draw, **unconditional** — `myrnd*random(...)` is evaluated even when `super_shape_rnd==0`), `var78_wedge_julia` (1 draw). The spec line "none of the 16 variations consumes the ISAAC stream, so RNG alignment holds" is **FALSE**; treat the flam3 source as authoritative. These four MUST be special-cased in `evaluate` exactly as `julia` is, consuming the ISAAC stream in genome-order when reached, or CPU↔Metal RNG alignment (the core M1 invariant) silently breaks.
> 2. **`rings`(21) and `fan`(22) are COEFFICIENT-DEPENDENT** — they read the xform's affine translation `c[2][0]` (= `e`) and `fan` also reads `c[2][1]` (= `f`). They are NOT pure `(p, w)` closures. (This is why the M1 `Variations.swift` header comment defers them to "M2".) The closure signature must carry `(e, f)`; the Metal side already has `x.e, x.f` in the struct.
>
> Consequently the table closure signature is `(SIMD2<Double>, Double, [String:Double], SIMD2<Double>) -> SIMD2<Double>` — `(p, weight, params, ef)` where `ef = SIMD2(x.affine.e, x.affine.f)` — and `evaluate` gains an `ef:` parameter. The four RNG-consuming variations are special-cased in `evaluate` (not in the table) following the existing `julia` pattern, because `inout ISAAC` cannot escape a stored closure.

**Files:**
- Modify: `Sources/FlameKit/Variations.swift`
- Modify: `Sources/FlameReference/ChaosGame.swift` (the single CPU call site `Variations.evaluate(x.variations, at: pre, rng: &rng)` gains `ef: SIMD2(x.affine.e, x.affine.f)`)
- Test: `Tests/FlameKitTests/VariationsTests.swift`

**Acceptance Criteria:**
- [ ] `Variations.knownNames` includes all 16 special-sauce names; `evaluate` dispatches each via a `(p, weight, params, ef) -> SIMD2<Double>` closure keyed by name, PLUS in-function special cases for the RNG-consuming `julia` (existing), `julian`, `juliascope`, `super_shape`, `wedge_julia` (each consumes the ISAAC stream once per reached variation, in genome order).
- [ ] **RNG alignment pin:** a unit test constructs an xform with `[julia, julian]` (both weight 1) and asserts CPU `evaluate` consumes exactly the same ISAAC words as a port of flam3's variation loop. Order basis (VERIFIED vs variations.c): flam3 dispatches in **ascending numeric variation-index order** (varFunc built via `for j if var[j]!=0`); the parser sorts `x.variations` **alphabetically**, so CPU `evaluate` draws in alphabetical name order. For `[julia, julian]` both orders agree → `julia` (13 / "julia") draws before `julian` (32 / "julian"). The four RNG-consuming special-sauce each draw exactly 1 word.
- [ ] `evaluate` signature is `evaluate(_ variations:, at:, ef: SIMD2<Double>, rng: inout ISAAC)`; the ChaosGame call site passes `ef: SIMD2(x.affine.e, x.affine.f)`.
- [ ] Each of the 14 new formulas matches the expected output recomputed from the **actual flam3 `varN_*` body** (cite the C line-by-line in the test comment). Self-invented formulas and self-consistent-but-unfaithful tests are forbidden (the round-2 review caught a 2×-frequency blob, a fabricated curl, a 2×-denominator rectangles, and a fabricated rings this way).
- [ ] `evaluate` no longer warns for any of the 16 names.
- [ ] flam3 EPS guards present where the source has them (`rings` `dx=e²+EPS`; `fan` `dx=π·(e²+EPS)`; `rings2_val²+EPS`; `fan2_x²+EPS`; curl `re²+im²` denominator; `perspective` distance).

**Verify:** `swift test --filter VariationsTests` → PASS.

**Steps:**

- [ ] **Step 1: Write failing tests** (append to `VariationsTests.swift`; one per variation). **Recompute every expected value from the real flam3 `varN_*` body** (the C is quoted inline). Do NOT write the test from the implementation — that is how round 1 shipped a 2×-frequency blob and a fabricated curl.

```swift
private func eval(_ name: String, _ p: SIMD2<Double>, _ w: Double,
                  _ params: [String:Double] = [:], _ ef: SIMD2<Double> = .zero) -> SIMD2<Double> {
    Variations.evaluate([Variation(name: name, weight: w, parameters: params)],
                        at: p, ef: ef, rng: &ISAAC(isaacSeed: "t"))
}
// var21_rings (variations.c): dx = e*e + EPS; r = sqrt(x²+y²);
//   r = w*( fmod(r+dx, 2*dx) - dx + r*(1-dx) ); (r*cos(a), r*sin(a)) where a=atan2(x,y).
func testRings() {
    let p = SIMD2<Double>(0.5, 0.0); let e = 0.7; let eps = 1e-10
    let out = eval("rings", p, 1.0, [:], SIMD2(e, 0.0))
    let dx = e*e + eps; let r = sqrt(p.x*p.x + p.y*p.y); let a = atan2(p.x, p.y)
    let rr = 1.0 * (fmod(r+dx, 2*dx) - dx + r*(1-dx))
    XCTAssertEqual(out.x, rr*cos(a), accuracy: 1e-9)
    XCTAssertEqual(out.y, rr*sin(a), accuracy: 1e-9)
}
// var22_fan (variations.c): dx = π*(e*e+EPS); dy = f; dx2 = dx/2; a = atan2(x,y);
//   a += (fmod(a+dy,dx) > dx2) ? -dx2 : dx2; r = w*sqrt(x²+y²); (r*cos a, r*sin a).
func testFan() {
    let p = SIMD2<Double>(0.3, 0.4); let e = 0.5; let f = 0.2
    let out = eval("fan", p, 1.0, [:], SIMD2(e, f))
    let dx = .pi*(e*e + 1e-10); let dy = f; let dx2 = 0.5*dx
    var a = atan2(p.x, p.y); let r = 1.0*sqrt(p.x*p.x+p.y*p.y)
    a += (fmod(a+dy, dx) > dx2) ? -dx2 : dx2
    XCTAssertEqual(out.x, r*cos(a), accuracy: 1e-9)
    XCTAssertEqual(out.y, r*sin(a), accuracy: 1e-9)
}
// var23_blob: r = sqrt(x²+y²); a = atan2(x,y);
//   r *= low + (high-low)*(0.5 + 0.5*sin(waves*a));  (w*sin(a)*r, w*cos(a)*r).
func testBlob() {
    let p = SIMD2<Double>(0.6, 0.0)
    let out = eval("blob", p, 1.0, ["blob_low":0.3,"blob_high":1.0,"blob_waves":2.0])
    var r = sqrt(p.x*p.x+p.y*p.y); let a = atan2(p.x, p.y)
    r *= 0.3 + (1.0-0.3)*(0.5 + 0.5*sin(2.0*a))      // NOTE: waves*a, NOT 2*waves*a
    XCTAssertEqual(out.x, 1.0*sin(a)*r, accuracy: 1e-9)  // NOTE: sin on x, cos on y
    XCTAssertEqual(out.y, 1.0*cos(a)*r, accuracy: 1e-9)
}
// var39_curl: complex reciprocal. re = 1 + c1*x + c2*(x²-y²); im = c1*y + 2*c2*x*y;
//   r = w/(re²+im²); ( (x*re + y*im)*r, (y*re - x*im)*r ).
func testCurl() {
    let p = SIMD2<Double>(0.5, 0.2)
    let out = eval("curl", p, 1.0, ["curl_c1":0.5,"curl_c2":0.1])
    let (x,y,c1,c2) = (p.x,p.y,0.5,0.1)
    let re = 1.0 + c1*x + c2*(x*x - y*y)
    let im = c1*y + 2.0*c2*x*y
    let r = 1.0/(re*re + im*im)
    XCTAssertEqual(out.x, (x*re + y*im)*r, accuracy: 1e-9)
    XCTAssertEqual(out.y, (y*re - x*im)*r, accuracy: 1e-9)
}
// var40_rectangles: if x==0: w*x  else  w*((2*floor(x/rx)+1)*rx - x).  NOTE: floor(x/rx), not floor(x/(2*rx)).
func testRectangles() {
    let p = SIMD2<Double>(1.3, 0.7)
    let out = eval("rectangles", p, 1.0, ["rectangles_x":0.4,"rectangles_y":0.6])
    XCTAssertEqual(out.x, 1.0*((2*floor(1.3/0.4)+1)*0.4 - 1.3), accuracy: 1e-9)
    XCTAssertEqual(out.y, 1.0*((2*floor(0.7/0.6)+1)*0.6 - 0.7), accuracy: 1e-9)
}
// RNG-consuming: draw exactly 1 ISAAC word, finite output, matches a re-derived expectation.
func testSuperShapeDrawsOneAndFinite() {
    var rng1 = ISAAC(isaacSeed: "t"); var rng2 = ISAAC(isaacSeed: "t")
    _ = rng1.next()   // baseline
    let out = eval("super_shape", SIMD2(0.4,0.0), 1.0,
        ["super_shape_rnd":0,"super_shape_m":4,"super_shape_n1":2,"super_shape_n2":2,"super_shape_n3":2,"super_shape_holes":0])
    _ = rng2.next()   // super_shape consumed one word
    XCTAssertTrue(out.x.isFinite); XCTAssertTrue(out.y.isFinite)
    XCTAssertEqual(rng1.next(), rng2.next())   // stream offset by exactly 1
}
func testJulianDrawsOneAndFinite() {
    let out = eval("julian", SIMD2(0.3,0.1), 1.0, ["julian_power":2,"julian_dist":1.0])
    XCTAssertTrue(out.x.isFinite)
}
// + juliascope, ngon, fan2, rings2, perspective, wedge_julia, wedge_sph — one finite/anchored test each,
//   each recomputed from the variations.c body. wedge_julia/juliascope assert the 1-word RNG draw.
```

(The finite checks are mandatory for ALL 14; the anchored equality checks are mandatory for `rings`, `fan`, `blob`, `curl`, `rectangles`, `rings2`, `fan2`, `ngon`, `perspective` — the ones with a clean closed form.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter VariationsTests`
Expected: FAIL (names warn-unknown / return zero).

- [ ] **Step 3: Write minimal implementation**

(a) Change `evaluate` to `evaluate(_ variations:, at:, ef: SIMD2<Double>, rng: inout ISAAC)`. Special-case `julian`, `juliascope`, `super_shape`, `wedge_julia` in the function body (each draws one ISAAC word via `rng.isaac01()` in the flam3-documented position) BEFORE the table lookup, exactly as `julia` already is. RNG order: `x.variations` is sorted alphabetically by the parser, and flam3 dispatches in ascending numeric variation-index order — these agree on the RNG-consuming subset, so walking `variations` in array (alphabetical) order reproduces flam3's RNG stream (see the Task-6 RNG-order invariant). Do NOT re-sort `variations` here.

(b) Table closure type: `(SIMD2<Double>, Double, [String:Double], SIMD2<Double>) -> SIMD2<Double>` — `(p, w, params, ef)`. Port each formula line-for-line from `variations.c` (EPS = 1e-10). The faithful rings/fan/blob/curl/rectangles bodies (quoted so the implementer cannot get them wrong):

```swift
let eps = 1e-10
t["rings"] = { p, w, _, ef in       // var21_rings — COEFFICIENT-DEPENDENT (ef.x = e)
    let dx = ef.x*ef.x + eps
    var r = (p.x*p.x + p.y*p.y).squareRoot()        // precalc_sqrt
    let a = atan2(p.x, p.y)                          // precalc_atan
    r = w * (fmod(r+dx, 2*dx) - dx + r*(1 - dx))
    return SIMD2(r * cos(a), r * sin(a))
}
t["fan"] = { p, w, _, ef in         // var22_fan — COEFFICIENT-DEPENDENT (ef.x=e, ef.y=f)
    let dx = .pi * (ef.x*ef.x + eps); let dy = ef.y; let dx2 = 0.5*dx
    var a = atan2(p.x, p.y)
    let r = w * (p.x*p.x + p.y*p.y).squareRoot()
    a += (fmod(a+dy, dx) > dx2) ? -dx2 : dx2
    return SIMD2(r * cos(a), r * sin(a))
}
t["blob"] = { p, w, par, _ in       // var23_blob
    let low = par["blob_low"] ?? 0; let high = par["blob_high"] ?? 1; let waves = par["blob_waves"] ?? 1
    var r = (p.x*p.x + p.y*p.y).squareRoot()
    let a = atan2(p.x, p.y)
    r *= low + (high - low) * (0.5 + 0.5*sin(waves*a))   // 0.5+0.5*sin(waves*a), NOT (sin(2*waves*a)+1)*0.5
    return SIMD2(w * sin(a) * r, w * cos(a) * r)         // sin on x, cos on y
}
t["curl"] = { p, w, par, _ in       // var39_curl — complex reciprocal
    let c1 = par["curl_c1"] ?? 1; let c2 = par["curl_c2"] ?? 0
    let re = 1.0 + c1*p.x + c2*(p.x*p.x - p.y*p.y)
    let im = c1*p.y + 2.0*c2*p.x*p.y
    let r = w / (re*re + im*im)
    return SIMD2((p.x*re + p.y*im)*r, (p.y*re - p.x*im)*r)
}
t["rectangles"] = { p, w, par, _ in // var40_rectangles
    let rx = par["rectangles_x"] ?? 1; let ry = par["rectangles_y"] ?? 1
    let nx = rx == 0 ? p.x : ((2*floor(p.x/rx) + 1)*rx - p.x)   // floor(p.x/rx), NOT floor(p.x/(2*rx))
    let ny = ry == 0 ? p.y : ((2*floor(p.y/ry) + 1)*ry - p.y)
    return SIMD2(w * nx, w * ny)
}
// ngon, fan2, rings2, perspective: port verbatim from variations.c (all param-driven, no RNG, no coefs).
// julian / juliascope / super_shape / wedge_julia: implemented as in-function special cases in `evaluate`
//   (they draw 1 ISAAC word each — see (a)). Their formulas also port verbatim from variations.c.
```

(c) Update `knownNames` to include all 16 names. The existing `julia` in-function special case stays; the canonical-order/ASSUMPTIONS comment is updated in Task 5.

> **No placeholder in the final file:** complete every `varN_*` body exactly as flam3 writes it. The four RNG-consuming special cases must each consume exactly one `isaac01()` draw at the point flam3 does (e.g. `super_shape` draws BEFORE using `precalc_sqrt`, even when `rnd==0`).

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter VariationsTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlameKit/Variations.swift Tests/FlameKitTests/VariationsTests.swift
git commit -m "feat(flamekit): port 14 special-sauce variation formulas to CPU"
```

---

### Task 5: GPUXform parameter channel (Swift + MSL) + host packer

**Goal:** Grow the canonical variation table from 19 to 33 slots, add the per-slot parameter channel to `GPUXform` on both sides of the Swift→MSL boundary, build the host packer from `VariationDescriptor`, bump the device-buffer size guard, and prove the widening is additive (M2 parity stays green and the 6 frozen genomes render **byte-identically** to a captured pre-change baseline).

> **Spec count (resolved).** The faithful unique canonical count is **19 + 14 = 33**: `spherical` and `polar` belong to BOTH the M1-19 and the 16 special-sauce, so they are counted once. (The spec previously wrote "35"; it has been amended to 33 to match.) The 14 NEW special-sauce names are `rings, fan, blob, fan2, rings2, perspective, julian, juliascope, ngon, curl, rectangles, super_shape, wedge_julia, wedge_sph`; `spherical`/`polar` already exist as MSL `v_spherical`/`v_polar` at slots 14/16 and are NOT re-implemented.

> **Layout scheme — read first (the single biggest correctness risk in M3).**
> The current `apply_xform_body` (Kernels.metal:258) dispatches by **canonical slot index**, NOT by name: it copies `varWeights[19]` into `w[19]` and runs a fixed 19-line if-chain (`bent`=0 … `swirl`=18). The host packer (`MetalHost.buildGPUXforms`) maps `name → slot` via `idxMap[name]` over `Variations.canonicalOrder`. Therefore the faithful, minimal-surprise scheme is:
>
> 1. **`VariationDescriptor.canonicalOrder` (defined in Task 1) is the authority** — it already lists all 33 names (M1's 19 + the 14 NEW special-sauce; `spherical`/`polar` once). In Task 5, `Variations.canonicalOrder` becomes a one-line re-export: `public static let canonicalOrder: [String] = VariationDescriptor.canonicalOrder`. `NUM_XFORM_SLOTS = VariationDescriptor.canonicalOrder.count == 33`. The 14 new names occupy slots 19..32 in the documented order: `rings, fan, blob, fan2, rings2, perspective, julian, juliascope, ngon, curl, rectangles, super_shape, wedge_julia, wedge_sph`.
> 2. **`varWeights` grows 19 → 33** (one weight per canonical slot). The host packer's existing `idxMap[name]` then maps every one of the 33 names to its slot unchanged.
> 3. **Add `varParams[33][8]`** (MAX_PARAMS_PER_SLOT=6, device slot width 8; 33×8 = 264 floats). Slot index = canonical index; intra-slot param index from `VariationDescriptor.slotIndex`. Parameterless variations leave their slot zeroed.
>
> The alternative `ssWeights[16]/ssTags[16]` side-channel idea is REJECTED: it diverges from the spec's "grow the if-chain" prescription, doubles the dispatch mechanism, and (with `uint8_t` inside a `float` struct) breaks the homogeneous-float layout contract that the existing `buf([GPUXform])` byte-copy depends on.

**Files:**
- Modify: `Sources/FlameKit/Variations.swift` (`canonicalOrder` becomes the `VariationDescriptor.canonicalOrder` re-export)
- Modify: `Sources/FlameRenderer/MetalHost.swift` (`GPUXform` + packer)
- Modify: `Sources/FlameRenderer/ChaosGameMetal.swift` (xform buffer now built from the flat packed array)
- Modify: `Sources/FlameRenderer/Metal/Kernels.metal` (`struct GPUXform` mirror — `varWeights[33]` + `varParams[264]`)
- Test: `Tests/FlameRendererTests/ParamChannelParityTests.swift` (new)

**Acceptance Criteria:**
- [ ] `VariationDescriptor.canonicalOrder.count == 33` (original 19 + the 14 new special-sauce names; `spherical`/`polar` counted once, NOT duplicated). `Variations.canonicalOrder` is its re-export and also `.count == 33`. A test asserts no duplicates and that every `VariationDescriptor` parametric name resolves to a canonical slot.
- [ ] The Swift→MSL device layout is: `6 (pre) + 6 (post) + 3 (color/cs/opacity) + 33 (varWeights) + 33*8 (varParams) = 15 + 33 + 264 = 312 floats = 1248 bytes` per xform. The size guard on the device buffer (`xforms.count * GPUXform.bytesPerXform`, `bytesPerXform == 1248`) holds on both sides.
- [ ] The packer writes each variation's `parameters` into `varParams[slot*8 + idx]` (slot = `idxMap[name]`, idx = `VariationDescriptor.slotIndex`); unused tail slots zeroed; `super_shape_rnd` clamped to `[0,1]` in the packer; EPS guards stay in the kernel (Task 6).
- [ ] The existing M2 end-to-end parity suite (`EndToEndParityTests`) stays green at ≥38 dB / 0.95 SSIM.
- [ ] **Additivity proof (concrete):** a SHA-256 of the Metal-rendered pixels of each of the 6 frozen genomes, captured into `Tests/Goldens/m2_baseline_hashes.json` **before** any Task-5 edit, matches the post-change SHA-256 byte-for-byte (the frozen genomes use none of the 14 new names, so `varParams` is all-zero and unread — output is unchanged).

**Verify:** `swift test --filter EndToEndParityTests --filter ParamChannelParityTests` → PASS.

**Steps:**

- [ ] **Step 0: Capture the additivity baseline (BEFORE editing any source).** Add a one-shot helper (or a temporary test) that renders each of the 6 frozen genomes on Metal at the `EndToEndParityTests` sample count and writes `Tests/Goldens/m2_baseline_hashes.json` (`{ "genome_name": "<sha256 of RGBA8 pixels>", ... }`). Commit this file on its own:

```bash
git add Tests/Goldens/m2_baseline_hashes.json
git commit -m "test(renderer): capture pre-S6-pre M2 Metal baseline hashes (additivity oracle)"
```

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import FlameRenderer
@testable import FlameReference
import FlameKit

final class ParamChannelParityTests: XCTestCase {
    @MainActor
    func testCanonicalOrderGrewTo33NoDupes() throws {
        XCTAssertEqual(Variations.canonicalOrder.count, 33)
        XCTAssertEqual(Set(Variations.canonicalOrder).count, 33, "duplicate canonical name")
        // spherical/polar must NOT be duplicated (they stay at their original M1 slots)
        XCTAssertEqual(Variations.canonicalOrder.filter { $0 == "spherical" }.count, 1)
        XCTAssertEqual(Variations.canonicalOrder.filter { $0 == "polar" }.count, 1)
        // every descriptor parametric name resolves to a slot
        for name in ["blob","curl","super_shape","ngon","julian","juliascope",
                     "wedge_julia","wedge_sph","perspective","fan2","rings2","rectangles"] {
            XCTAssertNotNil(Variations.canonicalOrder.firstIndex(of: name), name)
        }
        XCTAssertNotNil(Variations.canonicalOrder.firstIndex(of: "rings"))
        XCTAssertNotNil(Variations.canonicalOrder.firstIndex(of: "fan"))
    }
    @MainActor
    func testBytesPerXform() throws {
        XCTAssertEqual(GPUXform.bytesPerXform, 1248)   // 312 floats = 6+6+3+33+264
    }
    @MainActor
    func testFrozenGenomesByteIdenticalToBaseline() throws {
        // Additivity gate: frozen genomes use only the 19 original names, so the
        // new varParams channel (all-zero, unread) MUST NOT change Metal output.
        guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Goldens/genomes")
        let urls = (try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))
            .filter { $0.pathExtension == "flam3" }
        let baselines = try JSONDecoder().decode([String: String].self,
            from: Data(contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Goldens/m2_baseline_hashes.json")))
        for url in urls {
            let name = url.deletingPathExtension().lastPathComponent
            let flame = try Flam3Parser.parse(Data(contentsOf: url))[0]
            let p = RenderParams(seed: 0, width: 320, height: 200, oversample: 1, samplesPerPixel: 1000)
            let gpu = MetalRenderer.render(flame: flame, params: p)
            let hash = sha256(gpu.pixels)   // helper over the raw RGBA8 byte buffer
            XCTAssertEqual(hash, baselines[name], "\(name): Metal output drifted from pre-S6-pre baseline")
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ParamChannelParityTests`
Expected: FAIL (`bytesPerXform` / 33-slot order absent).

- [ ] **Step 3: Write minimal implementation**

**(a) `Variations.canonicalOrder`** — replace the 19-element literal with `public static let canonicalOrder: [String] = VariationDescriptor.canonicalOrder` (the authority, already 33, from Task 1). Update the `ASSUMPTIONS` doc comment: assumption (2) (≤2 active variations → FP-associativity safe) is unchanged; add a note that slots 19..32 are the special-sauce set and are read positionally by `apply_xform_body` (Task 6).

**(b) Swift side — flat pack (NOT a `[Float]` struct field).** The xform buffer today is created by `buf(xforms)` in `ChaosGameMetal.swift:64`, which does `values.withUnsafeBytes` over `[GPUXform]` and byte-copies the struct. A Swift `Array<Float>` field is heap-allocated and would NOT be inlined into the struct, so the byte-copy would send garbage to the GPU. Therefore the struct-copy route is abandoned for the variable-size tail: replace it with a **flat packed array**.

- Keep `GPUXform` for its 15 scalar header floats (a..f, pa..pf, color/colorSpeed/opacity) — these stay a trivial inline struct.
- Add `MetalHost.packXforms(_ flame: Flame) -> [Float]` returning a flat array of length `flame.xforms.count * GPUXform.floatsPerXform`. Per xform, emit in order: the 15 header floats, then 33 weight floats (via the existing `idxMap`), then 264 param floats (`varParams[slot*8 + idx]`; clamp `super_shape_rnd`; zero the rest). Add `GPUXform.floatsPerXform = 312` and `GPUXform.bytesPerXform = 312 * 4` and offset constants.
- In `ChaosGameMetal.swift`, replace `let xforms = MetalHost.buildGPUXforms(flame)` + `let xformsBuf = buf(xforms)` with `let flat = MetalHost.packXforms(flame); let xformsBuf = buf(flat)`. The final-xform buffer is packed the same way from a synthetic single-xform flame (`packXforms` over a Flame whose `xforms == [flame.finalXform!]`, length `1 * floatsPerXform` floats). The zeroed fallback buffer (`device.makeBuffer(length: MemoryLayout<GPUXform>.stride, …)`) becomes `length: GPUXform.bytesPerXform`.
- The old `MemoryLayout<GPUXform>.stride == 136` precondition moves into `packXforms` as a per-xform float-count assertion: `precondition(flat.count % GPUXform.floatsPerXform == 0)` where `floatsPerXform == 312`.

**(c) MSL side** — mirror exactly (MSL arrays ARE inline, so no issue):

```metal
constant int NUM_XFORM_SLOTS_MS = 33;   // == canonicalOrder.count
constant int SLOT_WIDTH_MS = 8;
struct GPUXform {
    float a,b,c,d,e,f;
    float pa,pb,pc,pd,pe,pf;
    float color, colorSpeed, opacity;
    float varWeights[33];
    float varParams[NUM_XFORM_SLOTS_MS * SLOT_WIDTH_MS];   // 33*8 = 264
};
```

(Param reads + the 14 new `v_<name>` functions + the grown if-chain land in Task 6. Here only the layout + the flat pack + the weight channel widening land, and `apply_xform_body` keeps reading `varWeights[i]` for `i in 0..<19` — the new slots 19..32 stay weight-zero on the frozen genomes, so M2 is unaffected.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter EndToEndParityTests --filter ParamChannelParityTests`
Expected: PASS — frozen genomes byte-identical to baseline; M2 parity unaffected.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlameKit/Variations.swift Sources/FlameRenderer/MetalHost.swift Sources/FlameRenderer/ChaosGameMetal.swift Sources/FlameRenderer/Metal/Kernels.metal Tests/FlameRendererTests/ParamChannelParityTests.swift
git commit -m "feat(renderer): GPUXform 33-slot canonical table + param channel (flat-packed, additive)"
```

---

### Task 6: Port the 14 MSL variation functions + per-variation Metal↔CPU parity

**Goal:** Port the 14 new MSL variation functions, wire them into `apply_xform_body` (which grows from 19 guarded lines to cover all active slots), and prove Metal↔CPU parity (≥38 dB / 0.95 SSIM) for each of the 16 on a constructed single-variation genome.

**Files:**
- Modify: `Sources/FlameRenderer/Metal/Kernels.metal`
- Modify: `Sources/FlameRenderer/MetalHost.swift` (canonical-order/slot wiring if needed)
- Test: `Tests/FlameRendererTests/SpecialSauceParityTests.swift` (new)

**Acceptance Criteria:**
- [ ] 14 NEW MSL `v_<name>` functions land (`rings`, `fan`, `blob`, `fan2`, `rings2`, `perspective`, `julian`, `juliascope`, `ngon`, `curl`, `rectangles`, `super_shape`, `wedge_julia`, `wedge_sph`); the pre-existing `v_spherical`/`v_polar` cover the remaining two of the 16 special-sauce names. `apply_xform_body` reads `varWeights[0..<33]` and runs a 33-line guarded chain, passing `&x.varParams[slot*8]` positionally to each parametric call.
- [ ] **RNG-consuming MSL variations take `thread IsaacState& rng` and draw exactly one word each** — `v_julian`, `v_juliascope`, `v_super_shape`, `v_wedge_julia` (mirroring the existing `v_julia(pre, w, rng)` pattern). This is mandatory: the spec line "none of the 16 variations consumes the ISAAC stream" is wrong (verified in Task 4), and Metal RNG alignment is the core M1 invariant. The if-chain evaluates RNG-consuming slots in canonical-slot order; this matches CPU (alphabetical eval order) AND flam3 (ascending numeric variation-index order) for the RNG-consuming subset {julia, julian, juliascope, super_shape, wedge_julia} — pinned by an explicit invariant test (below).
- [ ] **Coefficient-dependent MSL variations take `x.e, x.f`** — `v_rings(pre, w, x.e)` and `v_fan(pre, w, x.e, x.f)` (both already live in the `GPUXform` 15-float header; no layout change).
- [ ] For each of the 16 names, a constructed single-variation genome renders Metal vs CPU at PSNR ≥ 38 dB / SSIM ≥ 0.95. **Plus one multi-variation genome** with `[linear, julian, julia]` on one xform (exercises RNG draw ORDER across julia + an RNG-consuming special-sauce) at ≥ 38 dB — this is the RNG-alignment gate the spec's wrong claim would have skipped. (The RNG stream matches: both CPU-alphabetical and Metal-slot order draw julia before julian. The non-RNG `linear` term sits at a different summation position CPU-vs-Metal, so this also exercises the ≥3-active FP-associativity regime — covered by the statistical ≥38 dB gate, not a byte-equality claim.)
- [ ] **RNG-order invariant test (pinned):** asserts the canonical-slot indices of `{julia, julian, juliascope, super_shape, wedge_julia}` are strictly ascending AND equal to their alphabetical-name order AND equal to flam3's numeric variation order (13, 32, 33, 50, 78). This makes the RNG-alignment coincidence a tested invariant; a canonical-tail reorder or a new RNG-consuming variation that violates it fails here, not in a render.
- [ ] No NaN/Inf pixels on any of the 16 constructed genomes.
- [ ] The full `EndToEndParityTests` suite stays green (the frozen genomes don't use the new names, so slots 19..32 stay weight-zero).

**Verify:** `swift test --filter SpecialSauceParityTests --filter EndToEndParityTests` → PASS.

**Steps:**

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import FlameRenderer
@testable import FlameReference
import FlameKit

final class SpecialSauceParityTests: XCTestCase {
    /// Build a one-xform genome exercising a single special-sauce variation with
    /// representative params, render on both backends, assert ≥38 dB / 0.95 SSIM.
    @MainActor
    func assertParity(_ name: String, _ params: [String:Double], file: StaticString = #filePath, line: UInt = #line) throws {
        guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
        let flame = Flame(size: SIMD2(320,200), camera: Camera(scale: 200),
            xforms: [Xform(affine: AffineTransform(a:0.6,b:0.2,c:-0.3,d:0.5,e:0.5,f:0.3), color:0, colorSpeed:0.5,
                           variations: [Variation(name:name, weight:1, parameters: params)])],
            palette: Palette(colors: (0..<256).map { SIMD3<Double>(Double($0)/255, sin(Double($0)/40)*0.5+0.5, 1-Double($0)/255) }))
        let p = RenderParams(seed: 7, width: 320, height: 200, oversample: 1, samplesPerPixel: 1000)
        let cpu = ReferenceRenderer.render(flame: flame, params: p)
        let gpu = MetalRenderer.render(flame: flame, params: p)
        XCTAssertGreaterThanOrEqual(ImageComparison.psnr(cpu,gpu), 38.0, "\(name): <38 dB", file:file, line:line)
        XCTAssertGreaterThanOrEqual(ImageComparison.ssim(cpu,gpu), 0.95, "\(name): SSIM<0.95", file:file, line:line)
    }
    @MainActor func testBlob() throws { try assertParity("blob", ["blob_low":0.3,"blob_high":1.0,"blob_waves":2.0]) }
    @MainActor func testCurl() throws { try assertParity("curl", ["curl_c1":0.5,"curl_c2":0.1]) }
    @MainActor func testSuperShape() throws { try assertParity("super_shape", ["super_shape_rnd":0.1,"super_shape_m":5,"super_shape_n1":2,"super_shape_n2":2,"super_shape_n3":2,"super_shape_holes":0]) }
    @MainActor func testJulian() throws { try assertParity("julian", ["julian_power":3,"julian_dist":1.0]) }
    // ... one test per remaining name, params from the defaults table ...
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SpecialSauceParityTests`
Expected: FAIL (Metal warns / returns near-blank for the new names).

- [ ] **Step 3: Write minimal implementation**

In `Kernels.metal`, add the 14 MSL functions. Signatures follow the Task-4 CPU ports (Float math); the coef-dependent ones take `x.e`/`x.f`, the RNG-consuming ones take `thread IsaacState& rng` and draw exactly one word via `isaac_01(rng)` at the flam3-documented position. Faithful examples:

```metal
// coef-dependent (ef.x = x.e)
static inline float2 v_rings(float2 p, float w, float e) {
    float dx = e*e + EPS_MS;
    float r = sqrt(p.x*p.x + p.y*p.y);
    float a = atan2(p.x, p.y);
    r = w * (fmod(r+dx, 2.0f*dx) - dx + r*(1.0f - dx));
    return float2(r*cos(a), r*sin(a));
}
// param-driven, faithful (sin on x, cos on y; 0.5+0.5*sin(waves*a))
static inline float2 v_blob(float2 p, float w, thread const float* pr) {
    float low = pr[0], high = pr[1], waves = pr[2];
    float r = sqrt(p.x*p.x + p.y*p.y); float a = atan2(p.x, p.y);
    r *= low + (high - low) * (0.5f + 0.5f*sin(waves*a));
    return float2(w * sin(a) * r, w * cos(a) * r);
}
// complex reciprocal (NOT the made-up version)
static inline float2 v_curl(float2 p, float w, thread const float* pr) {
    float c1 = pr[0], c2 = pr[1];
    float re = 1.0f + c1*p.x + c2*(p.x*p.x - p.y*p.y);
    float im = c1*p.y + 2.0f*c2*p.x*p.y;
    float r = w / (re*re + im*im);
    return float2((p.x*re + p.y*im)*r, (p.y*re - p.x*im)*r);
}
// RNG-consuming: one isaac_01 draw, UNCONDITIONALLY (even when super_shape_rnd==0)
static inline float2 v_super_shape(float2 p, float w, thread const float* pr, thread IsaacState& rng) {
    float rnd = pr[0], m = pr[1], n1 = pr[2], n2 = pr[3], n3 = pr[4], holes = pr[5];
    float atanyx = atan2(p.x, p.y);     // flam3 precalc_atanyx
    float theta = m*atanyx + M_PI_4_F;  // super_shape_pm_4 precomputed on host? NO — port verbatim
    float st = sin(theta), ct = cos(theta);
    float t1 = pow(fabs(ct), n2), t2 = pow(fabs(st), n3);
    float ps = sqrt(p.x*p.x + p.y*p.y);
    float rand = isaac_01(rng);         // drawn before the rnd multiply, always
    float r = w * ((rnd*rand + (1.0f-rnd)*ps) - holes) * pow(t1+t2, -1.0f/n1) / ps;
    return float2(r*p.x, r*p.y);
}
// ... fan (coef e,f), rectangles, fan2, rings2, perspective, julian(rng), juliascope(rng),
//     ngon, wedge_julia(rng), wedge_sph — each a verbatim Float port of variations.c ...
```

Extend `apply_xform_body` to cover all 33 canonical slots — NO new dispatch mechanism, NO side-channel. Task 5 already grew `varWeights` from 19 → 33 and made `Variations.canonicalOrder` a re-export of `VariationDescriptor.canonicalOrder` (33 entries), so the existing `idxMap[name]` host packer already routes every special-sauce name to its slot. The MSL change is purely mechanical:

- Change `float w[19]; for (int i=0;i<19;i++) w[i]=x.varWeights[i];` → `float w[33]; for (int i=0;i<33;i++) w[i]=x.varWeights[i];`
- Append one guarded line per new slot, in canonical-slot order (slots 19..32). Each parametric line passes a pointer into the param channel at the slot's offset; parameterless lines (`rings`, `fan`) take no param pointer. Concretely:

```metal
if (w[19] != 0.0f) acc += v_rings(pre, w[19], x.e);                                   // Group C, coef-dependent (e)
if (w[20] != 0.0f) acc += v_fan(pre, w[20], x.e, x.f);                                // Group C, coef-dependent (e,f)
if (w[21] != 0.0f) acc += v_blob(pre, w[21], &x.varParams[21*SLOT_WIDTH_MS]);
if (w[22] != 0.0f) acc += v_fan2(pre, w[22], &x.varParams[22*SLOT_WIDTH_MS]);
if (w[23] != 0.0f) acc += v_rings2(pre, w[23], &x.varParams[23*SLOT_WIDTH_MS]);
if (w[24] != 0.0f) acc += v_perspective(pre, w[24], &x.varParams[24*SLOT_WIDTH_MS]);
if (w[25] != 0.0f) acc += v_julian(pre, w[25], &x.varParams[25*SLOT_WIDTH_MS], rng);   // RNG-consuming (1 draw)
if (w[26] != 0.0f) acc += v_juliascope(pre, w[26], &x.varParams[26*SLOT_WIDTH_MS], rng); // RNG-consuming (1 draw)
if (w[27] != 0.0f) acc += v_ngon(pre, w[27], &x.varParams[27*SLOT_WIDTH_MS]);
if (w[28] != 0.0f) acc += v_curl(pre, w[28], &x.varParams[28*SLOT_WIDTH_MS]);
if (w[29] != 0.0f) acc += v_rectangles(pre, w[29], &x.varParams[29*SLOT_WIDTH_MS]);
if (w[30] != 0.0f) acc += v_super_shape(pre, w[30], &x.varParams[30*SLOT_WIDTH_MS], rng); // RNG-consuming (1 draw, UNCONDITIONAL)
if (w[31] != 0.0f) acc += v_wedge_julia(pre, w[31], &x.varParams[31*SLOT_WIDTH_MS], rng); // RNG-consuming (1 draw)
if (w[32] != 0.0f) acc += v_wedge_sph(pre, w[32], &x.varParams[32*SLOT_WIDTH_MS]);
// (slot index literal == position in the Task-5 appended canonicalOrder tail; the
//  testCanonicalOrderGrewTo33NoDupes assertion pins the order, so a slot/func
//  mismatch fails loudly at test time, not silently at render time.)
//
// RNG DRAW ORDER — VERIFIED vs variations.c (the plan's earlier "match ONLY
// because each hit at most once" reasoning was WRONG). flam3 builds varFunc[] by
// scanning `for j=0..flam3_nvariations if var[j]!=0` → variations execute in
// ASCENDING NUMERIC variation-index order (julia=13, julian=32, juliascope=33,
// super_shape=50, wedge_julia=78), regardless of XML/genome order. Emberweft's
// CPU `evaluate` iterates `x.variations`, which the parser sorts ALPHABETICALLY
// (Flam3Parser.swift), so CPU draws RNG in alphabetical name order. The Metal
// if-chain above draws in canonical-slot order. These three sequences AGREE on
// the RNG-consuming subset ONLY because {julia, julian, juliascope, super_shape,
// wedge_julia} are in the SAME relative order alphabetically, numerically, and
// by canonical slot — a coincidence the plan now PINS as a tested invariant:
// the unit test asserts the canonical-slot indices of these five names are
// strictly ascending, so any future canonical-tail reorder or new RNG-consuming
// variation whose name doesn't sort to match its slot FAILS the test instead of
// silently diverging the ISAAC stream. (Non-RNG terms: CPU sums alphabetically,
// Metal by slot, flam3 numerically — these differ by FP-associativity ULPs only,
// already covered by M1 assumption (2) ≤2 active → bit-identical, and by the
// ≥38 dB statistical gate for ≥3.)
```

(The exact slot numbers above depend on the appended order chosen in Task 5; pin them together — the `SpecialSauceParityTests` per-name run + the multi-RNG-variation run are the correctness oracle. `spherical`(16) and `polar`(14) already exist as `v_spherical`/`v_polar` and need no new function.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SpecialSauceParityTests --filter EndToEndParityTests`
Expected: PASS for all 16; M2 suite green.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlameRenderer/Metal/Kernels.metal Sources/FlameRenderer/MetalHost.swift Tests/FlameRendererTests/SpecialSauceParityTests.swift
git commit -m "feat(renderer): port 16 special-sauce variations to Metal + per-variation parity"
```

---

## Phase B — S6: FlameKit animation math + `emberweft animate` CLI

Pure FlameKit math first (TDD'd in isolation), then the CLI and the animated-frame parity suite. Interpolation runs once here (Double) and the result is handed to both renderers.

### Task 7: flam3 parity-oracle harness (build-from-source + auto-skip helper)

**USER-ORDERED GATE — NON-SKIPPABLE.** This task was requested by the user (the spec's parity backbone depends on a locally-built flam3). It MUST NOT be closed by walking around it, by declaring it "verified inline", or by substituting a cheaper check. Close only after every item in `acceptanceCriteria` has been re-validated independently, with output captured.

**Goal:** Stand up the locally-built `flam3-genome`/`flam3-animate` oracle (built from `scottdraves/flam3` source, autotools + zlib/libpng/libxml2), document it in `testing.md`, and add the test helper that runs the literal env-var commands and **auto-skips with a printed warning** if the binaries are absent (F10) — so vs-flam3 tests are no-ops on machines without the build, never failures.

**Files:**
- Create: `Tools/flam3_oracle.sh` (build instructions + the literal `env sequence=/rotate=/inter=` + `flam3-animate` commands, commented)
- Modify: `docs/engineering/testing.md` (oracle section: build-from-source, env vars, `passes=1 temporal_samples=1` to disable motion blur)
- Create: `Tests/FlameReferenceTests/Flam3Oracle.swift` (helper: `isAvailable`, `genMotionGenome(...)`, `renderFrames(...)`, all env-var driven)

**Acceptance Criteria:**
- [ ] `Tools/flam3_oracle.sh` documents the pinned flam3 repo commit, the `brew install` deps, the `./configure && make` build, and the exact env-var invocations (sequence / rotate / inter for `flam3-genome`; `begin/end/prefix` for `flam3-animate`).
- [ ] `Flam3Oracle.isAvailable` returns true iff `flam3-genome` and `flam3-animate` resolve on `$PATH`; every vs-flam3 test calls `try Flam3Oracle.require()` which `XCTSkip`s with a clear warning when absent.
- [ ] The helper renders a single still with `passes=1 temporal_samples=1` set on every control point (motion blur off — F6), confirmed by a one-frame smoke render that produces a non-empty PNG.
- [ ] `testing.md` records the oracle as a dev-machine prerequisite (not CI), the 30 dB (vs-flam3) vs 38 dB (Metal↔CPU) split, and the F10 auto-skip fallback. **Also fix the stale "flam3 (Homebrew)" claims** at `testing.md:31` and `roadmap.md:45` — flam3 has NO Homebrew formula; replace with "built from `scottdraves/flam3` source (autotools + zlib/libpng/libxml2)" per Task 7.

**Verify:** `which flam3-genome flam3-animate` resolves on the dev machine; `swift test --filter Flam3OracleSmoke` either runs the smoke render or skips with the documented warning.

```json:metadata
{"files": ["Tools/flam3_oracle.sh", "Tests/FlameReferenceTests/Flam3Oracle.swift", "docs/engineering/testing.md"], "verifyCommand": "which flam3-genome && swift test --filter Flam3OracleSmoke", "acceptanceCriteria": ["flam3-genome + flam3-animate resolve on PATH", "Flam3Oracle.require() XCTSkip's when absent", "motion blur off via passes=1 temporal_samples=1 verified by non-empty smoke PNG", "testing.md documents build + 30/38 dB split + F10 skip"], "userGate": true, "tags": ["user-gate"], "modelTier": "standard"}
```

**Steps:**

- [ ] **Step 1: Build flam3 from source (dev machine, by hand).** `brew install libpng libxml2 zlib automake autoconf libtool`; clone `scottdraves/flam3` at the pinned commit; `./configure && make`; add the build dir to `$PATH`. Record the pinned commit in `Tools/flam3_oracle.sh`. Run the three literal env-var commands from the spec's "Oracle pipeline" section by hand once to confirm they emit genomes/PNGs.
- [ ] **Step 2: Write `Flam3Oracle.swift`** with `isAvailable`, `require()`, `genMotionGenome(mode:input:nframes:frame:)`, and `renderFrames(genome:begin:end:prefix:)`, all env-var driven. `require()` does `guard isAvailable else { throw XCTSkip("flam3 oracle not built — see Tools/flam3_oracle.sh (F10)") }`.
- [ ] **Step 3: Write a smoke test** (`Flam3OracleSmoke`) that, if available, renders one frame of a frozen genome with `passes=1 temporal_samples=1` and asserts the output PNG is non-empty (>1 KB); if absent, skips.
- [ ] **Step 4: Update `testing.md`** with the build-from-source instructions, the env-var modes, the `passes=1 temporal_samples=1` motion-blur-off note, the 30 dB vs 38 dB split, and the F10 auto-skip.
- [ ] **Step 5: Re-validate** all four acceptance criteria with captured output (`which` output, the smoke PNG byte count, the testing.md diff). Commit:

```bash
git add Tools/flam3_oracle.sh Tests/FlameReferenceTests/Flam3Oracle.swift Tests/FlameReferenceTests/Flam3OracleSmoke.swift docs/engineering/testing.md
git commit -m "test: flam3 parity-oracle harness (build-from-source, env-var driven, F10 auto-skip)"
```

---

### Task 8: smoother(t) + stagger coefficient

**Goal:** Port `smoother(t)=3t²−2t³` and `get_stagger_coef` (per-xform staggered sub-interval of [0,1], applies only for ncp==2, stagger>0, non-final xform).

**Files:**
- Create: `Sources/FlameKit/BlendMath.swift`
- Test: `Tests/FlameKitTests/BlendMathTests.swift`

**Acceptance Criteria:**
- [ ] `BlendMath.smoother(0)==0`, `smoother(1)==1`, `smoother(0.5)==0.5`, monotone on [0,1].
- [ ] `BlendMath.staggerCoef(numXforms:nx, xformIndex:i, isFinal:flag, stagger:s, t:)` ports `get_stagger_coef` (interpolation.c:343-367) exactly: `max_stag=(nx-1)/nx; stag_scaled=stagger*max_stag; st=stag_scaled*(nx-1-i)/(nx-1); et=st+(1-stag_scaled)`; returns 0 if `t<=st`, 1 if `t>=et`, else `smoother((t-st)/(1-stag_scaled))`. Here `nx` = the **standard** xform count (excludes the final xform — `interpolation.c:524` computes `nx = num_xforms - (final_xform_enable)`); `i` is the 0-based xform index into the standard set. For `stagger<=0` or `ncp!=2` or the final xform it returns `smoother(t)` unchanged (no stagger). NOTE (verified): the active formula makes the **last** standard xform interpolate first (`i=nx-1 ⇒ st=0`); the flam3 comment claiming "first xform first" describes the commented-out alternative line — port the active line, not the comment.
- [ ] A unit test pins the staggered values at a known `(s, i, n)`.

**Verify:** `swift test --filter BlendMathTests` → PASS.

**Steps:**

- [ ] **Step 1: Write the failing test** (endpoints + a staggered case recomputed from `get_stagger_coef` interpolation.c:343-367).
- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** `smoother` and `staggerCoef` (port `get_stagger_coef` exactly: the sub-interval boundaries, `smoother` applied inside the staggered window).
- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Commit** `feat(flamekit): smoother(t) + stagger coefficient port`.

---

### Task 9: HSV (hsv_circular) palette blend + hueRotation interpolation

**Goal:** Port flam3's transition palette blend faithfully: the per-entry blend of the two endpoints' 256-entry RGB LUTs governed by `palette_interpolation` (`interpolation.c:386-443`), and linear interpolation of `hueRotation` across keyframes (`INTERP(hue_rotation)`, `interpolation.c:478`).

> **VERIFIED GROUND TRUTH (read before implementing).** A direct read of `interpolation.c:383-384,403-413,432-433` settles two things the round-2 spec got loose:
> 1. **`hsv_circular` and `rgb` are MIXED by `hsv_rgb_palette_blend`, not pure HSV.** `rgb_fraction = (mode==rgb) ? 1.0 : (mode==hsv_circular) ? cpi[0].hsv_rgb_palette_blend : 0.0`. The result entry = `rgb_fraction*new_rgb + (1−rgb_fraction)*new_hsv_rgb`, where `new_rgb` is the linear-RGB blend and `new_hsv_rgb = hsv2rgb(linear-HSV blend)`. Pure-`hsv` mode ⇒ `rgb_fraction=0` (HSV only). The plan's earlier "shorter-arc hue blend" described only the HSV half and ignored `hsvRgbPaletteBlend`; that fails vs-flam3 on any genome with non-zero `hsv_rgb_palette_blend`. `hsvRgbPaletteBlend` is added to the `Flame` model in Task 2.
> 2. **HSV hue is on a 0–6 scale; the shorter-arc adjustment is `±3.0` / shift `±6.0`, applied ONLY to the first control point's hue (ncp==2, k==0) based on the second's hue** (`interpolation.c:409-413`). No 8-bit rounding anywhere in the blend — all `Double`, channels clipped to `[0,1]` at the end (`interpolation.c:437-442`); `hsv2rgb` reduces hue mod 6. The 256-loop has no off-by-one.

**Files:**
- Create: `Sources/FlameKit/PaletteBlend.swift` (kept in its own file so Task 9 does not depend on the later Task 10)
- Test: `Tests/FlameKitTests/PaletteBlendTests.swift`

**Acceptance Criteria:**
- [ ] `PaletteBlend.blend(a, b, t, mode: PaletteInterpolation, hsvMix: Double)` returns the 256-LUT per `interpolation.c:386-443`: `rgb_fraction` per mode above; for hsv_circular/hsv, convert each entry RGB→HSV (hue 0–6), shorter-arc-adjust the cp0 hue against cp1 (±6.0 when the raw Δ exceeds ±3.0), linear-blend both the HSV and RGB triples by `(1−t),t`, `hsv2rgb` the blended HSV, mix by `rgb_fraction`. Clip all channels to `[0,1]`. At `t=0==a`, `t=1==b`.
- [ ] `hueRotation` interpolates linearly across two genomes (`INTERP(hue_rotation)`).
- [ ] All entries finite on a black palette and on a saturated palette; the `rgb` and `hsv` (plain) modes are implemented so the `paletteInterpolation` switch is exhaustive (`rgb`⇒rgb_fraction=1; `hsv`⇒rgb_fraction=0; `sweep`⇒the hard-cut branch at `interpolation.c:445-451`).

**Verify:** `swift test --filter PaletteBlendTests` → PASS.

**Steps:**

- [ ] **Step 1: Write failing tests** (endpoint equality at t=0/t=1; hsv_circular midpoint on a known red→green pair recomputed by hand against the `±6.0` shorter-arc rule on the 0–6 hue scale; a non-zero `hsvMix` case proving the rgb/hsv mix is applied; finiteness on a black palette).
- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** the blend verbatim per `interpolation.c:386-443` (rgb_fraction, the 0–6-hue shorter-arc adjust on cp0, double RGB+HSV accumulation, hsv2rgb, mix, clip); linear `hueRotation` interp.
- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Commit** `feat(flamekit): HSV/RGB palette blend (hsv_rgb_palette_blend mix) + hueRotation interpolation`.

---

### Task 10: GenomeInterpolator rewrite (.linear + .log polar)

**Goal:** Replace the M1 `Interpolation.interpolate` body with a `GenomeInterpolator` that switches on `interpolationType`: `.linear` (the existing per-field lerp, now the shim) and `.log` (polar matrix decomposition with `wind`-anchored angle unwrap, per-column magnitude guard, post-identity special case). A thin `Interpolation.interpolate(a,b,t)` shim delegates to `.linear` so M1/M2 call sites and tests stay green.

**Files:**
- Create: `Sources/FlameKit/GenomeInterpolator.swift`
- Modify: `Sources/FlameKit/Interpolation.swift` (becomes the shim)
- Test: `Tests/FlameKitTests/InterpolationTests.swift` (extend)

**Acceptance Criteria:**
- [ ] `GenomeInterpolator.interpolate(a, b, t, type:)` switches on `interpolationType`.
- [ ] `.linear` matches the previous `Interpolation.interpolate` output bit-for-bit on the existing test genomes (M1/M2 `InterpolationTests` unchanged and green). This requires the `.linear` path to REUSE the legacy `mergeVariations` verbatim (drop-zero-weight + sort-by-name) — do NOT route `.linear` through the new `.log` merge.
- [ ] `.log` interpolates each xform's 2×2 via the polar decomposition ported **verbatim from flam3** (`convert_linear_to_polar` + `interp_and_convert_back`, interpolation.c:207-227,283-318): per column `col∈{0,1}`, magnitude `cxmag=sqrt(c[col][0]²+c[col][1]²)` interpolates **log-linearly** (`accmag += c[i]*log(cxmag)`) and angle `cxang=atan2(c[col][1],c[col][0])` interpolates with the `wind`-anchored unwrap; translation `e,f` interpolates linearly. Result column = `(exp(accmag)*cos(accang), exp(accmag)*sin(accang))`. Post is forced to identity when both parents' post is identity.
- [ ] **Near-degenerate guard is PER-COLUMN magnitude, NOT a determinant guard (VERIFIED vs interpolation.c:213-215 — the plan's earlier "det<1e-12 → whole-xform .linear fallback" was WRONG; there is no determinant, no NaN guard, no COMPAT fallback in flam3).** Port `interp_and_convert_back` exactly: for each column, if `log(cxmag[i][col]) < -10` (i.e. `cxmag < e^-10 ≈ 4.54e-5`) for ANY control point `i`, set `accmode[col]=1` and accumulate that column's magnitude **linearly** (`accmag += c[i]*cxmag[i][col]`; reconvert uses `expmag = accmag` instead of `exp(accmag)`). The angle still polar-interpolates; the OTHER column and the translation are unaffected; the xform does NOT fall back to `.linear`. Additionally port the zero-column-magnitude rule in `convert_linear_to_polar`: if `cxmag[k][col]==0` set `zlm[col]=1`, and if exactly one column is zero, copy the angle from the non-zero column (`cxang[k][zero]=cxang[k][nonzero]`).
- [ ] Near-singular constructed affine does not produce NaN/Inf (determinant-guard fallback exercised by a test).
- [ ] `mergeVariations` is split: the `.log` branch unions variations by name (preserving zero-weight padding slots that `align` created) and carries per-name `parameters` from whichever side defines them; the `.linear` branch is the legacy behavior.

**Verify:** `swift test --filter InterpolationTests` → PASS (including the degenerate-affine case).

**Steps:**

- [ ] **Step 1: Write failing tests** — `.linear` parity with old output (snapshot a few coefficients), `.log` midpoint on a rotation pair (recomputed), and a near-degenerate (tiny column-magnitude) affine that must stay finite AND must match the per-column linear-magnitude fallback (port `interp_and_convert_back`'s `accmode[col]` rule, NOT a determinant test).
- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** `GenomeInterpolator` (port `convert_linear_to_polar` + `interp_and_convert_back` + the `wind` unwrap `interpolation.c:293-309` + the **per-column magnitude fallback** (`log(cxmag)<-10` → linear magnitude for that column) + the zero-column angle-copy + post-identity special case `interpolation.c:668-679`). Implement TWO merge functions: `mergeLinear` (moved from the current `Interpolation.mergeVariations`, byte-identical) and `mergeLog` (union + param carry-over, preserves zero-weight slots). `GenomeInterpolator` picks one by `type`. Make `Interpolation.interpolate(a,b,at:)` a thin delegate to `GenomeInterpolator.interpolate(a,b,t,type:.linear)` using `mergeLinear`, so every existing call site (`InterpolationTests`, any CLI/CLI-test caller) is bit-identical.
- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Commit** `feat(flamekit): GenomeInterpolator (.linear + .log polar) with wind unwrap + det guard`.

---

### Task 11: Special-sauce padding (`flam3_align` port)

**Goal:** Port `flam3_align` (`interpolation.c:768-1032`): pad both genomes to equal regular-xform and final-xform count, copy parametric-variation params from the neighbour that has them, and apply the per-variation rest positions from the `VariationDescriptor`/spec table (Group A/B/C + linear fallback), including the Group-C swap-affine.

**Files:**
- Create: `Sources/FlameKit/SpecialSauce.swift`
- Test: `Tests/FlameKitTests/SpecialSauceTests.swift`

**Acceptance Criteria:**
- [ ] `SpecialSauce.align(A, B, interpolationType:)` returns two genomes with equal regular-xform and final-xform counts.
- [ ] A padded xform whose neighbour has `blob`/`curl`/etc. receives that variation's param defaults copied from the neighbour (`interpolation.c:812-844`).
- [ ] Group A → `linear=-1`, coefs `[-1,0;0,-1;0,0]`, not renormalized (log only).
- [ ] Group B → `var=1` with rest params (blob `1,1,1`; supershape `n1=n2=n3=2`; etc.), renormalized.
- [ ] Group C (`fan`,`rings`) → `var=1` **and** swap-affine `[0,1;1,0;0,0]`, renormalized.
- [ ] default → `linear=1.0` (identity).

**Verify:** `swift test --filter SpecialSauceTests` → PASS.

**Steps:**

- [ ] **Step 1: Write failing tests** — one per group asserting the rest variation + coefs + renormalization flag, using `VariationDescriptor.rest` for the param values.
- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** `align` exactly as `flam3_align` (pad loop, parametric-param copy, rest-position switch keyed on `VariationDescriptor` group; renormalize = divide each weight by the sum so the padded xform's total weight is 1 for Groups B/C).
- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Commit** `feat(flamekit): flam3_align special-sauce padding port`.

---

### Task 12: `establish_asymmetric_refangles` (writes `wind[col]`)

**Goal:** Port `establish_asymmetric_refangles` (`interpolation.c:710-762`): for an xform symmetric on one side / animated on the other (sym = `animate==0` or padding), store the symmetric side's column angle `+2π` into `xform.wind`. This anchors the `.log` unwrap so an animating xform next to a symmetric/padded one does not spin the wrong way at the ±π seam.

**Files:**
- Create: `Sources/FlameKit/RefAngles.swift`
- Test: `Tests/FlameKitTests/RefAnglesTests.swift`

**Acceptance Criteria:**
- [ ] `RefAngles.establish(spun, ncp:)` writes **only** `xform.wind[col]` (never coefs).
- [ ] A symmetric/animated xform pair gets the symmetric side's column angle +2π in `wind`.
- [ ] An already-symmetric-on-both-sides pair leaves `wind` at its default (no-op).
- [ ] **Symmetry gate is `animate==0` ONLY (VERIFIED vs interpolation.c:753-756):** flam3's `padsymflag` is hardcoded `0` inside the loop, so the `(padding==1 && padsymflag)` branch is DEAD — padding does NOT trigger the asymmetric-refangle path. Gate on `animate==0` (the effective behavior); do not treat padding as symmetry.

**Verify:** `swift test --filter RefAnglesTests` → PASS.

**Steps:**

- [ ] **Step 1: Write failing tests** (asymmetric pair → wind set; symmetric pair → unchanged; coefs untouched).
- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** `establish` (port the column-angle computation + the `+2π` store; gate on `animate==0 || padding`).
- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Commit** `feat(flamekit): establish_asymmetric_refangles (wind[col]) port`.

---

### Task 13: `Loop.blend` (sheep_loop port — pure affine rotation)

**Goal:** Port `sheep_loop` (`flam3.c:396-557`): for each non-final xform with `animate != 0`, left-multiply the pre-affine 2×2 by `R(t·360°)`; translation/post/camera/palette/weight/color/opacity/chaos untouched; final xforms skipped; padding xforms rotate only under `.log`. Output genome is **seamless** (frame(t=1) ≈ frame(t=0) within FP tolerance).

> **θ handling (verified, load-bearing).** `flam3_rotate` (flam3.c:512-557) does NOT reduce θ modulo 2π; it computes `degrees = blend*360.0` then `theta = DEG2RAD(degrees)` and calls `sin`/`cos` directly. So at `t=1`, `theta = 2π` computed with FP error (`cos(2π) ≈ 1 − 5e-16`, `sin(2π) ≈ −2.5e-16` in Double), and `R(2π)·M ≠ M` bit-for-bit. flam3's `frame(t=1)` likewise differs from `frame(t=0)` by a few ULPs. The faithful port MUST compute θ the same way (`t * 2π` via `t * 360 * .pi/180` or `t * 2*.pi` — match flam3's exact multiply order, whichever the source uses; pin it in a test against the oracle). Therefore:
> - The seamless gate is NOT genome byte-equality. It is (a) genome-space `‖frame(0) − frame(1)‖ < 1e-12` per coefficient (rotation-matrix ULP residual), AND (b) the rendered `frame(t=0)` vs `frame(t=1)` Metal↔CPU-style PSNR ≥ 38 dB (the visible-seamlessness gate; a few-ULP affine difference is invisible after the chaos game + density estimation + display).
> - The spec's prose "`R(360°)·M = R(0°)·M = M` → `frame(blend=1) genome == frame(blend=0) genome`" is the mathematical idealization, not the bit-exact gate. Do not assert `==`.

**Files:**
- Create: `Sources/FlameKit/Loop.swift`
- Test: `Tests/FlameKitTests/LoopTests.swift`

**Acceptance Criteria:**
- [ ] `Loop.blend(sheep, t)` returns a genome equal to the input at `t=0` (R(0) is exactly identity); at `t=1` every pre-affine 2×2 coefficient is within `1e-12` of the input (seamless within rotation-matrix ULP residual — NOT bit-equal).
- [ ] Only the 2×2 pre-affine of animating, non-final xforms changes; translation `e,f` and post-affine and palette are byte-equal to the input.
- [ ] An xform with `animate==0` is untouched; a final xform is untouched; a padding xform rotates only when `interpolationType == .log`.
- [ ] Rotation direction/ULP matches a hand-computed `R(θ)·M` at `t=0.25` (90°), where θ is computed via the SAME multiply order as `flam3_rotate` (pinned by the Task-19 vs-flam3 ≥30 dB gate).

**Verify:** `swift test --filter LoopTests` → PASS.

**Steps:**

- [ ] **Step 1: Write failing tests** (t=0/t=1 equality across all xforms; e,f/post/palette untouched; animate==0 untouched; 90° hand-check).
- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** `blend` (clone, for each xform with `animate != 0 && !isFinal` and (`padding==0 || type==.log`): `affine.a,b,c,d = R(θ)·M` where θ = t·2π; leave e,f).
- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Commit** `feat(flamekit): Loop.blend sheep_loop port (pure affine rotation, palette static)`.

---

### Task 14: `Transition.blend` (sheep_edge port)

**Goal:** Port `sheep_edge` (`flam3.c:436-491`; VERIFIED: there is NO separate `spin_inter` helper in master — `sheep_edge` calls the helpers inline): clone both parents → fold motion → `align` (Task 11) → normalize times to {0,1} → `establish_asymmetric_refangles` (Task 12) → **rotate BOTH endpoints by `t·360°`** via `flam3_rotate` (Task-13 rotation; same `animate!=0`/final-skip/padding-under-log gates apply to both) → `flam3_interpolate(2cp, smoother(t), stagger)` with `.log` + HSV palette blend. Strip motion elements; return the interpolated genome.

**Files:**
- Create: `Sources/FlameKit/Transition.swift`
- Test: `Tests/FlameKitTests/TransitionTests.swift`

**Acceptance Criteria:**
- [ ] `Transition.blend(A, B, t, stagger:)` follows the 8-step contract; `blend(A,B,0)==A`, `blend(A,B,1)==B` (after align).
- [ ] Consecutive-frame genome-space `‖Δ‖ < 1e-3` on normalized coefficients (continuity, objective gate (a)).
- [ ] Finiteness on a constructed mismatched pair (different xform counts → exercises special-sauce padding).
- [ ] `stagger>0` desyncs non-final xforms (Task 8 wired); `stagger<=0` leaves all xforms on the same eased curve.

**Verify:** `swift test --filter TransitionTests` → PASS.

**Steps:**

- [ ] **Step 1: Write failing tests** (endpoint equality; continuity ‖Δ‖<1e-3 over t∈{0,0.1,…,1}; finiteness on mismatched pair; stagger-vs-no-stagger genome differs at interior t).
- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** `blend` orchestrating Tasks 8–12: `align` → normalize times to {0,1} → `establish` → rotate BOTH endpoints via the Task-13 rotation (gate on `animate!=0`, skip final, padding only under `.log`) → `GenomeInterpolator.interpolate(spun, 2, smoother(t)` with stagger applied per-xform inside the interp loop, `type:.log)` (palette via Task-9 `hsv_circular` with `hsvRgbPaletteBlend`).
- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Commit** `feat(flamekit): Transition.blend sheep_edge port (align+rotate+log interp+HSV palette)`.

---

### Task 15: `PairSelector` (Sequential) + `Schedule` (two-level seek)

**Goal:** Add the `PairSelector` protocol + `Sequential` impl (TDD scaffold), the `Segment` model, and the pure two-level-seek `Schedule`: global-frame → `(segmentId, blend)` is O(1) (constant tier lengths); `segmentId → (fromSheep, toSheep)` is O(1) within the materialized prefix and O(segments) to extend the `Sequential`/`SimilarityExploration` walk forward. Alternation invariant: no two transitions consecutive.

> **Frame-counting convention (pinned — off-by-one hazard).** flam3 emits `nframes` frames per segment at blend `= frame/nframes` for `frame = 1..nframes` (1-indexed; see `flam3-genome.c` rotate/inter modes). So blend ∈ {1/N, 2/N, …, 1.0}; blend=0 is NEVER emitted. This is what makes consecutive segments tile without a duplicate frame: segment k's last frame is blend=1.0 (≈ identity for a loop; = endpoint B for a transition), and segment k+1's first frame is blend=1/N of the next segment (a small step away) — NOT a re-emit of the boundary genome. The spec F9 note "N+1 blend samples (0…N)" is loose phrasing for "N intervals"; the pinned rule for THIS plan is:
> - **`Schedule.frameToBlend(globalFrame)`:** `segmentId = globalFrame / N`; `local = globalFrame % N`; `blend = Double(local + 1) / Double(N)`. Blend is in `(0, 1]`, never 0.
> - **Total PNGs emitted by `emberweft animate` = `segments * N`** (exactly N per segment; no duplicate/drop at boundaries). The boundary genome is NOT double-emitted.
> - This matches the oracle: `flam3-animate begin=0 end=N` over one segment yields N frames.

**Files:**
- Create: `Sources/FlameKit/PairSelector.swift`, `Sources/FlameKit/Schedule.swift`
- Test: `Tests/FlameKitTests/ScheduleTests.swift`

**Acceptance Criteria:**
- [ ] `Schedule(librarySize:, framesPerSegment:, selector:, seed:)` maps any global frame index to `(segmentId, kind, blend)` in O(1) using the pinned 1-indexed blend formula above: `blend = (local + 1) / N` ∈ `(0, 1]`, never 0.
- [ ] A test pins: for `N=8`, segment 0 emits blends `{1/8, 2/8, …, 8/8=1.0}` over global frames 0..7; segment 1 emits the same ladder over frames 8..15; blend=0 never appears; total frames for 3 segments = 24 (= 3*8, NOT 25 or 17).
- [ ] `segment(at:)` materializes/extends the selector walk forward as needed; `Sequential` is O(1) everywhere.
- [ ] Over any prefix, the invariant holds: segments strictly alternate loop/transition; never two transitions adjacent.
- [ ] A 50-segment `Sequential` walk over a library visits sheep in a fixed, seed-reproducible order.

**Verify:** `swift test --filter ScheduleTests` → PASS.

**Steps:**

- [ ] **Step 1: Write failing tests** (frame→segment math for tiers 160/320/900; alternation over 50 segments; reproducibility of `Sequential` under fixed seed).
- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** `PairSelector` protocol (`next(from:) -> Int`, escapes built in for SimilarityExploration), `Sequential` (deterministic increment with wraparound), and `Schedule` (two-level: frame→segmentId via division by `framesPerSegment`; segmentId→pair via the lazily-grown `selector` walk array).
- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Commit** `feat(flamekit): PairSelector (Sequential) + Schedule (two-level seek)`.

---

### Task 16: Feature vector + `SimilarityExploration` (ε-greedy, F1 determinism)

**Goal:** Implement the per-sheep feature vector (variation-set cosine + palette mean-hue/luma + xform-count + summed affine Frobenius, each guarded with an ε fallback — F9) stored as **sorted arrays** (F1 determinism rule: no FP sum over a String-keyed Dict/Set), and `SimilarityExploration` ε-greedy selector (escape = uniform-random sheep; else most-similar not-recently-used; recency penalty).

**Files:**
- Create: `Sources/FlameKit/FeatureVector.swift`, extend `Sources/FlameKit/PairSelector.swift`
- Test: `Tests/FlameKitTests/SimilarityTests.swift`

**Acceptance Criteria:**
- [ ] `FeatureVector(for: flame)` stores the variation-set component as a lexicographically-sorted `(name, weight)` array; the metric sums it in fixed order.
- [ ] **`SimilarityExploration` accepts in-memory `FeatureVector`s directly** — it does NOT require the Task-17 `FeatureCache` to exist. (The cache is an optimization for the 47k-sheep production case; the unit test builds a small synthetic library of `FeatureVector`s by hand. This keeps Task 16 independent of Task 17.)
- [ ] The similarity score for a fixed pair is **bit-identical across N separate process launches** (F1 hard rule — the test spawns N processes and compares the printed score).
- [ ] Every term has an independent ε fallback, so an all-zero palette or zero-norm affine cannot NaN the score (F9).
- [ ] **Exploration guard runs over a small SYNTHETIC library (20 hand-built feature vectors), NOT the real 47k-sheep / 1.6 GB archive** (a full-archive scan is not viable as a unit test): a 50-segment walk visits **≥ max(⌈0.5·20⌉, 10) = 10** distinct sheep, reproducible under fixed seed. (The production-scale exploration is exercised manually/by-baseline only, not gated in CI.)

**Verify:** `swift test --filter SimilarityTests` → PASS (incl. the cross-process bit-identity test).

**Steps:**

- [ ] **Step 1: Write failing tests** — the cross-process bit-identity test (concrete mechanism below), the exploration-count test, and the F9 zero-palette finiteness test.

> **Cross-process bit-identity mechanism (pinned, not left to the implementer).** Spawning processes from inside `swift test` is environment-fragile, so the determinism check runs against a stable in-repo entry point: add a hidden `emberweft _feature-score` subcommand to `EmberweftCLI` (parsed by `CLI.run`, not advertised in `--help`) that loads two frozen genomes by index from a tiny fixture directory committed under `Tests/FlameKitTests/Fixtures/similarity_pair/` (two `.flam3` files), builds their `FeatureVector`s, and prints the similarity score as a bare `%0.6x`-hex (exact-bit) line on stdout. The test spawns the built `emberweft` executable N=4 times via `Process` (`swift run emberweft _feature-score` or the test-runner-resolved product path), captures stdout, and asserts all N hex strings are byte-equal. `Process` is used (not an in-process call) precisely so each launch has a fresh Swift hash seed — that is what makes the F1 rule load-bearing rather than vacuous. If the product path can't be resolved in the test environment, `XCTSkip` with a clear message (the test is a guardrail, not a build gate).

- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** `FeatureVector` (sorted-array storage; `cosine`/`distance` helpers that iterate the sorted arrays), the guarded metric, the hidden `_feature-score` subcommand, and `SimilarityExploration` (ε-greedy using an `ISAAC`/`RNG` seeded walk + an integer `Set<Int>` recency window — integer-indexed, so the walk is deterministic).
- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Commit** `feat(flamekit): FeatureVector (sorted-array) + SimilarityExploration ε-greedy (F1 deterministic)`.

---

### Task 17: Feature-vector cache (F5)

**Goal:** Implement the `genomes/.feature_cache/` cache (one sorted-array record per sheep id), with incremental rebuild on library scan (new/changed `.flam3` triggers a record rebuild before selection), explicit `--rebuild-cache`, and the clear error when similarity is requested with a fully-absent cache.

**Files:**
- Create: `Sources/FlameKit/FeatureCache.swift`
- Test: `Tests/FlameKitTests/FeatureCacheTests.swift`

**Acceptance Criteria:**
- [ ] `FeatureCache.scan(libraryDir:)` lists `.flam3` files; any with no record or newer mtime triggers an incremental rebuild of that record before selection.
- [ ] Records are sorted-array (F1), gitignored under `genomes/.feature_cache/`.
- [ ] `--rebuild-cache` rebuilds the whole cache; `--selector similarity` with a fully-absent cache errors with a clear message; `--selector sequential` needs no cache.
- [ ] A `make feature-cache` target wraps `--rebuild-cache`.

**Verify:** `swift test --filter FeatureCacheTests` → PASS.

**Steps:**

- [ ] **Step 1: Write failing tests** (incremental rebuild picks up a new file by mtime; absent-cache + similarity → throws; sequential → no read).
- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** the cache (Codable sorted-array record, mtime check, incremental + full rebuild, error type for absent cache). Add `make feature-cache` to the Makefile and the `genomes/.feature_cache/` gitignore entry.
- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Commit** `feat(flamekit): feature-vector cache (incremental rebuild, F1 records)`.

---

### Task 18: `emberweft animate` CLI + `manifest.json`

**Goal:** Add the `emberweft animate` subcommand producing `frames/000000.png …` + `frames/manifest.json` (F9 schema: `manifestVersion`, top-level `stagger`, per-frame `fromSheep/toSheep/segmentId/kind/blend` with `interpolationType: null` on loop rows), wired through `Schedule` + `Loop`/`Transition` + the chosen backend.

**Files:**
- Create: `Sources/FlameKit/Manifest.swift`
- Create: `Sources/EmberweftCLI/AnimateCommand.swift`
- Modify: `Sources/EmberweftCLI/CLI.swift` (dispatch `animate`)
- Test: `Tests/EmberweftCLITests/AnimateCommandTests.swift`

**Acceptance Criteria:**
- [ ] `emberweft animate a.flam3 b.flam3 --frames 8 --segments 3 --selector sequential --seed 0 --backend cpu --out /tmp/frames` writes exactly `3*8 = 24` PNGs (`000000.png … 000023.png`) + `manifest.json`. The count is `segments * framesPerSegment` — NO duplicate/drop at segment boundaries (Task-15 blend convention).
- [ ] `manifest.json` parses via `Manifest` Codable; `manifestVersion==1`; loop rows have `interpolationType: null`; `stagger` is top-level; `blend` follows the 1-indexed `(local+1)/N` convention (every row's blend ∈ (0,1], none is 0).
- [ ] **Stable emit order + determinism:** the `frames` array is built by iterating the global frame index `0..<(segments*N)` — NEVER by iterating a `Set`/`Dictionary` of frames (F1). G2 byte-determinism: two runs of the same `(input, seed, backend, quality)` produce byte-identical PNGs AND byte-identical `manifest.json`. CPU is single-threaded → byte-deterministic by construction; Metal is byte-deterministic per the existing `EndToEndParityTests` repeat-run behavior (the per-frame packer walks `flame.xforms` and the canonical-order array — fixed order, no Set/Dict iteration; no hidden nondeterminism) — the snapshot test re-runs and diffs to prove it.
- [ ] **CLI arg parsing (VERIFIED feasible vs the existing `CLI.swift` pattern):** `animate` takes **variadic positional genome paths PLUS flags**. The existing `render` uses `args.first` (single positional); `animate` must instead loop once over `args`: collect every non-`-`-prefixed token into `var genomes: [String]`, and handle `--flag value` pairs (`--frames`, `--segments`, `--selector`, `--seed`, `--stagger`, `--backend`, `--out`, `--library`, `--size`, `--quality`, `--rebuild-cache`) by consuming `args[i+1]`. Dispatch is a new `case "animate": return animate(args)` in `CLI.run`; it does NOT collide with `render`/`info`/`validate`/`--version`/`_feature-score` (distinct first-token switch arms). Metal frames render via `MainActor.assumeIsolated { MetalRenderer.render(...) }` exactly as the existing `render` path does (the CLI runs single-threaded; this is the established pattern).
- [ ] Empty/size-1 input → non-zero exit with a clear error (alternation needs ≥ 2 sheep).
- [ ] CLI snapshot test: the manifest for a fixed tiny input is byte-stable across runs.

**Verify:** `swift test --filter AnimateCommandTests` → PASS.

**Steps:**

- [ ] **Step 1: Write failing tests** (writes frames+manifest; manifest schema; ≥2-sheep guard; snapshot stability).
- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** `Manifest` (Codable, null-on-loop via custom encode), `AnimateCommand.run` (build `Schedule`, loop over global frames, dispatch `Loop.blend`/`Transition.blend`, render on the chosen backend, write PNGs + manifest). Wire into `CLI.run` (`case "animate": return animate(...)`).
- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Commit** `feat(cli): emberweft animate → PNG sequence + manifest.json`.

---

### Task 19: Animated-frame parity / continuity / determinism / finiteness suite

**Goal:** The S6 acceptance test suite: vs-flam3 ≥30 dB (skip-or-pass via Task 7), Metal↔CPU ≥38 dB **including a mismatched-sheep transition** (exercises special-sauce padding + the 16 Metal variations — F2 load-bearing), consecutive-frame continuity ≥40 dB, G2 byte-determinism of the full PNG sequence, and finiteness on every frame.

**Files:**
- Create: `Tests/FlameReferenceTests/AnimationParityTests.swift`
- Create: `Tests/FlameRendererTests/AnimatedFrameParityTests.swift`

> **Test-target split (compile-critical).** `FlameReferenceTests` depends only on `[FlameReference, FlameKit]` (see `Package.swift`) — it has NO `FlameRenderer` dep and cannot call `MetalRenderer.render`. Put every **CPU-only / vs-flam3** row (loop+transition vs the oracle, genome-space `‖Δ‖`, CPU finiteness) in `AnimationParityTests.swift`. Put every **Metal-touching** row (rendered seamlessness PSNR, mismatched-sheep Metal↔CPU parity, consecutive-frame image PSNR, G2 Metal byte-determinism) in `AnimatedFrameParityTests.swift` (`FlameRendererTests`, which already deps `FlameRenderer`). Do NOT add `FlameRenderer` to `FlameReferenceTests`'s dependency list — that would let reference tests reach Metal and defeat the point of the CPU oracle living in a pure target.

**Acceptance Criteria:**
- [ ] `sheep_loop` vs `flam3-genome rotate`: our loop frame vs flam3's, PSNR ≥ 30 dB / SSIM ≥ 0.95 (skip if oracle absent).
- [ ] `sheep_edge` vs `flam3-genome inter`: our transition vs flam3's, PSNR ≥ 30 dB / SSIM ≥ 0.95 (skip if oracle absent).
- [ ] `sheep_loop` seamlessness: `frame(t=0)` vs `frame(t=1)` per-coefficient `‖Δ‖ < 1e-12` (NOT byte-equal — `R(2π)≠I` in FP; see Task 13) AND rendered-frame PSNR ≥ 38 dB (the visible-seamlessness gate).
- [ ] Animated-frame Metal↔CPU parity on a mismatched-sheep transition ≥ 38 dB / 0.95 SSIM (F2).
- [ ] Consecutive-frame image PSNR ≥ 40 dB on a transition (continuity).
- [ ] G2: the full S6 PNG sequence is byte-identical across two runs (same backend, fixed quality).
- [ ] Finiteness: no NaN/Inf in any animated frame.

**Verify:** `swift test --filter AnimationParityTests --filter AnimatedFrameParityTests` → PASS (or skip on the vs-flam3 rows if the oracle is absent).

**Steps:**

- [ ] **Step 1: Write the failing tests** using the existing `ImageComparison.psnr/ssim`, `ReferenceRenderer`/`MetalRenderer`, and the Task-7 oracle helper.
- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Fix** any port gap the suite exposes (return to Tasks 10–14); the suite itself is the gate, not new production code.
- [ ] **Step 4: Run → PASS** (or documented skip).
- [ ] **Step 5: Commit** `test: animated-frame parity/continuity/determinism/finiteness suite (S6 gate)`.

---

## Phase C — S7: realtime engine

S7 reuses S6's `Schedule`/`PairSelector`/Metal variation set **verbatim** — no animation- or renderer-math change (made true by S6-pre's Metal port). The new work is the realtime driver, adaptive quality, and the Metal-layer UI.

### Task 20: `PlaybackDispatcher` actor

**Goal:** An actor-isolated dispatcher that advances the `Schedule` one global frame at a time, hands the interpolated `Flame` to `MetalRenderer`, and paces output to the target fps via the `CAMetalLayer` vsync with triple-buffered `MTLTexture` rotation, prefetching the next sheep mid-loop.

**Files:**
- Create: `Sources/FlamePlayer/PlaybackDispatcher.swift`
- Test: `Tests/FlamePlayerTests/PlaybackDispatcherTests.swift` (new test target — add to Package.swift)

**Acceptance Criteria:**
- [ ] `PlaybackDispatcher` is an `actor`, `Sendable`; it owns the `Schedule` and a bounded ring of recently-played segments.
- [ ] Given a synthetic render closure and a fixed clock, it produces a strictly alternating loop/transition frame stream matching `Schedule`.
- [ ] Mid-loop it prefetches the upcoming sheep's `Flame` so the transition's first frame is ready.
- [ ] No frame is held/duplicated during a transition (realtime overrun → display best-available, never freeze).
- [ ] **Swift 6 actor↔MainActor crossing is sound:** `MetalRenderer.render` is `@MainActor`, so the dispatcher `await`s across the actor boundary explicitly (`await MainActor.run { MetalRenderer.render(...) }`); the frame-ready callback into `@MainActor FlameUI` is likewise `await`ed. NO `nonisolated(unsafe)` escape hatches snuck in for the render target / texture / schedule (the existing CLI `nonisolated(unsafe)` IO hooks in `EmberweftCLI` are single-threaded test injection and are NOT a precedent for the realtime path). The dispatcher's `MetalRenderer` dependency is isolated behind an injected `protocol Renderer` (the test injects a fake; the production wiring hands the actor a `@MainActor`-isolated closure).
- [ ] **Prefetch + teardown lifecycle (Swift 6):** the in-flight prefetch is held as an `actor`-isolated `Task<Flame, Never>?`. A `func stop() async` cancels it (`prefetchTask?.cancel()`) and awaits it settled before return; `FlameUI` teardown calls `await dispatcher.stop()`. (Swift 6 disallows async work in `deinit`, so teardown is an explicit `stop()` the owner calls, not a `deinit` side-effect.) On cancellation the prefetch task returns the partially-built genome is discarded (never fed to the renderer). No dangling/orphaned task after teardown.

**Verify:** `swift test --filter PlaybackDispatcherTests` → PASS.

**Steps:**

- [ ] **Step 0: Add the `FlamePlayerTests` target to `Package.swift` (it does not exist yet — `Package.swift` currently has no test target for `FlamePlayer`; Tasks 20–23 all assume it).** Append a new `.testTarget`:

```swift
.testTarget(
    name: "FlamePlayerTests",
    dependencies: ["FlamePlayer", "FlameRenderer", "FlameReference", "FlameKit"],
    path: "Tests/FlamePlayerTests"
),
```

Create the empty dir `Tests/FlamePlayerTests/`. Verify `swift build` resolves the new target before writing any test. This is a Phase-C prerequisite; commit it with Step 5.

- [ ] **Step 1: Write failing tests** (alternation under a fake clock; prefetch invoked once per loop; no duplicate-on-transition using a capturing fake renderer).
- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** the actor (frame-advance loop, triple-buffer texture pool, prefetch task; isolate `MetalRenderer` calls behind a protocol so the test injects a fake).
- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Commit** `feat(player): PlaybackDispatcher actor + FlamePlayerTests target (Schedule-driven, triple-buffered, prefetch)`.

---

### Task 21: Adaptive-quality controller (deterministic-logic gate)

**Goal:** A pure controller: `(measuredFps, thermalState, currentBudget) -> newBudget` with the documented hysteresis (step the iteration budget up/down with a deadband so it doesn't oscillate). Fed **simulated** fps/thermal signals, the controller is deterministic — this is the M3 gate; real thermal-throttle behavior is verified manually and deferred to M4.

**Files:**
- Create: `Sources/FlamePlayer/AdaptiveQualityController.swift`
- Test: `Tests/FlamePlayerTests/AdaptiveQualityControllerTests.swift`

**Acceptance Criteria:**
- [ ] Pure value type; given the same `(fps, thermalState, budget)` it always returns the same new budget.
- [ ] Hysteresis: small fps jitter inside the deadband leaves the budget unchanged; sustained below-threshold fps steps the budget down; sustained above-threshold steps it up.
- [ ] `thermalState == .critical` forces a floor budget regardless of fps.
- [ ] Budget stays within `[minSamplesPerPixel, maxSamplesPerPixel]`.

**Verify:** `swift test --filter AdaptiveQualityControllerTests` → PASS.

**Steps:**

- [ ] **Step 1: Write failing tests** (deterministic mapping table; deadband stability; critical-thermal floor; clamps).
- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** the controller (a pure `step` function with explicit up/down thresholds and a floor/ceil).
- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Commit** `feat(player): AdaptiveQualityController (hysteretic iteration-budget feedback)`.

---

### Task 22: `FlameUI` (CAMetalLayer wrapper)

**Goal:** A `@MainActor` `NSView` subclass backed by `CAMetalLayer` that hosts the `PlaybackDispatcher`'s output textures and drives the vsync-paced frame loop.

**Files:**
- Create: `Sources/FlamePlayer/FlameUI.swift`
- Test: `Tests/FlamePlayerTests/FlameUITests.swift`

**Acceptance Criteria:**
- [ ] `FlameUI` is `@MainActor`, `CAMetalLayer`-backed; `isAvailable` mirrors `MetalRenderer.isAvailable`.
- [ ] It wires the dispatcher's frame-ready callback to `CAMetalLayer` drawable presentation; the layer resizes with the view.
- [ ] A smoke test (skip if Metal unavailable) constructs the view headless and confirms it accepts at least one frame without faulting.

> **Headless-test feasibility (VERIFIED).** A `@MainActor` `NSView` + `CAMetalLayer` CAN be constructed and driven in an XCTest without a window or graphics context on the macOS test host: `NSView` requires no window to instantiate, and `CAMetalLayer` can be created and fed an offscreen `MTLTexture` without being attached to a backing window (presentation via `nextDrawable` is only needed for on-screen vsync, not for accepting a frame). `MTLCreateSystemDefaultDevice()` already works in the existing `EndToEndParityTests` under the same regime the gate already requires — bash sandbox DISABLED (testing.md "Local pre-merge gate"). So: the smoke test builds `FlameUI()` headless on `@MainActor`, renders a frame to an offscreen texture via the existing offscreen `MetalRenderer.render` path, hands it to the layer, and asserts no fault. `XCTSkip` when `MetalRenderer.isAvailable` is false OR when the sandbox blocks device creation (detect by catching the nil device).

**Verify:** `swift test --filter FlameUITests` → PASS (or skip).

**Steps:**

- [ ] **Step 1: Write failing tests** (headless construction + one-frame acceptance; skip on no-Metal).
- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** `FlameUI` (`wantsLayer = true`, `CAMetalLayer` configuration, frame callback → drawable).
- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Commit** `feat(player): FlameUI CAMetalLayer wrapper`.

---

### Task 23: Realtime capability proof (≥58 fps / 30 s @ 1080p)

**USER-ORDERED GATE — NON-SKIPPABLE.** This task was requested by the user (the spec's M3 realtime capability gate). It MUST NOT be closed by walking around it, by declaring it "verified inline", or by substituting a cheaper check. Close only after every item in `acceptanceCriteria` has been re-validated independently, with output captured.

**Goal:** Prove the realtime engine sustains ≥ 58 fps over a 30 s window at 1080p under nominal thermal state (0.5× below the 60 target, to absorb transient dips), recorded as a baseline. This is a **capability gate**, not a flaky absolute; the hard 60 fps-under-real-UI-load gate is M4's (depends on M4's compositing/window load, not yet present).

**Files:**
- Create: `Tests/FlamePlayerTests/RealtimeCapabilityTests.swift`
- Modify: `docs/engineering/testing.md` (record the baseline + the split: deterministic capability gate here; absolute-fps-under-UI-load + real-thermal deferred to M4).

**Acceptance Criteria:**
- [ ] An `EMBERWEFT_PERF=1`-gated test runs the dispatcher for 30 s at 1080p on the dev machine under nominal thermal state and prints sustained p50/p95 fps; the **median sustained fps is ≥ 58**.

> **30s-in-`swift-test` feasibility (VERIFIED).** The test does NOT drive `CAMetalLayer` vsync presentation — it runs the `PlaybackDispatcher` against a synthetic clock (the Task-20 fake-clock pattern) rendering to **offscreen `MTLTexture`s** (the existing `MetalRenderer.render` path is already offscreen; no window/drawable needed), sampling frame timestamps from the dispatcher. `xctest` (the `swift test` harness) has NO default per-test timeout; the 30 s run is well inside the gate. Add `executionTimeAllowance = 60` (in case Xcode-style plans are ever used) and `XCTSkipUnless(EMBERWEFT_PERF == "1")` + `XCTSkip` when Metal is unavailable or the sandbox blocks device creation. Run only with the bash sandbox DISABLED (already required by the gate).
- [ ] The adaptive controller kept the frame budget within bounds and never froze a transition frame.
- [ ] `testing.md` records the baseline number + the M3-owns / M4-deferred split.
- [ ] If Metal is unavailable, the test `XCTSkip`s.

**Verify:** `EMBERWEFT_PERF=1 swift test --filter RealtimeCapabilityTests` → prints sustained fps ≥ 58 (or skips).

```json:metadata
{"files": ["Tests/FlamePlayerTests/RealtimeCapabilityTests.swift", "docs/engineering/testing.md"], "verifyCommand": "EMBERWEFT_PERF=1 swift test --filter RealtimeCapabilityTests", "acceptanceCriteria": ["30s @1080p sustained median fps >= 58 under nominal thermal", "no transition-frame freeze during the run", "testing.md records baseline + M3-owns/M4-deferred split", "XCTSkip when Metal unavailable"], "userGate": true, "tags": ["user-gate"], "modelTier": "standard"}
```

**Steps:**

- [ ] **Step 1: Write the perf test** (gated on `EMBERWEFT_PERF=1` and Metal availability; drives the dispatcher for 30 s at 1920×1080; samples frame timestamps; computes p50/p95; asserts p50 ≥ 58).
- [ ] **Step 2: Run it** on the dev machine; capture the printed p50/p95.
- [ ] **Step 3: If p50 < 58**, tune the adaptive controller's nominal budget (the lever is iteration budget, not algorithm) until the capability holds; do **not** lower the 58 floor.
- [ ] **Step 4: Record the baseline + split** in `testing.md`.
- [ ] **Step 5: Re-validate** all four criteria with captured output; commit `test: realtime capability proof (>=58fps/30s@1080p) + perf split`.

---

### Task 24: Documentation sweep + flip M3 to complete

**Goal:** Update the docs the spec lists. NOTE (round-3 VERIFIED): `transitions.md`, `roadmap.md`, and `CLAUDE.md` already carry the corrected "pure rotation, palette static" wording — `grep -rn "circular palette" docs/` returns NO content-doc hits today, only plan/spec references. So Task 24 is primarily **verify-already-correct + add new content** (CHANGELOG M3 entry; `FlameUI`/`PlaybackDispatcher` in `architecture.md`; the animation-parity layer + oracle + `hsv_rgb_palette_blend` in `testing.md`; flip roadmap M3 to ✅), NOT a wording-correction sweep.

**Files:**
- Modify: `docs/rendering/transitions.md` (drop the "circular palette cycle" claim + early-draft sections that contradict `log`+special-sauce+`sheep_loop`; document the static-palette loop and HSV-transition palette).
- Modify: `docs/playback/playback-modes.md` (replace the stateful `SegmentScheduler` sketch with the pure `Schedule` + S7 `PlaybackDispatcher`).
- Modify: `docs/engineering/roadmap.md` (flip M3 to ✅).
- Modify: `docs/architecture.md` (add `FlameUI`; describe the FlameKit animation subsystem + `PlaybackDispatcher`).
- Modify: `CLAUDE.md` (already has the corrected M3 bullet; verify, no change unless needed).
- Modify: `CHANGELOG.md` (M3 entry incl. S6-pre prerequisite).

**Acceptance Criteria:**
- [ ] No doc says "loop = rotate 360° + circular palette cycle"; all say "pure rotation, palette static".
- [ ] `transitions.md` documents `log` + special-sauce + `sheep_loop`/`sheep_edge`; `playback-modes.md` documents the pure `Schedule` + `PlaybackDispatcher`.
- [ ] `roadmap.md` M3 is ✅; `CHANGELOG.md` has the M3 entry.

**Verify:** `grep -rn "circular palette" docs/` → no loop-related hits; `CHANGELOG.md` grep shows the M3 entry.

**Steps:**

- [ ] **Step 1: Sweep** each doc per the file list (mechanical edits; the corrected wording is already in the spec).
- [ ] **Step 2: Grep-verify** no stale loop/palette claims remain.
- [ ] **Step 3: Commit** `docs: M3 complete — transitions/playback/architecture/testing/roadmap/CHANGELOG`.

---

## Notes for implementers

- **Determinism is rule #2.** Any FP accumulation over variation/parameter-name-keyed data MUST use sorted arrays (F1 — Swift `Dictionary`/`Set` hash seeds are per-process randomized). Integer-indexed `Set<Int>` and arrays are fine. The cross-process bit-identity test (Task 16) is the guardrail.
- **SPEC DISCREPANCY (flagged, do not re-litigate):** the spec's "Param-channel layout" note says "none of the 16 variations consumes the ISAAC stream, so RNG alignment holds." Verified against `scottdraves/flam3` `variations.c`: this is FALSE. Four of the 16 draw the ISAAC stream (`julian`, `juliascope`, `super_shape` [unconditionally, even at `rnd=0`], `wedge_julia`), and `rings`/`fan` are coefficient-dependent (read affine `c[2][0]`/`c[2][1]` = `e`/`f`). Tasks 4 and 6 are written to the flam3 source (the authority the spec itself defers to), not to that note. When you reach Phase A, treat the flam3 source as ground truth; the human will reconcile the spec prose separately.
- **ROUND-3 MATH CORRECTIONS (flagged, load-bearing — port the source, not earlier plan prose):**
  - **`.log` near-degenerate guard is PER-COLUMN MAGNITUDE, NOT a determinant guard** (`interpolation.c:213-215`). For each column, if `log(cxmag[i][col]) < -10` for any cp, that column's magnitude switches to linear accumulation; the angle still polar-interpolates; the xform does NOT fall back to `.linear`; there is NO NaN guard and NO COMPAT fallback. Also port the zero-column angle-copy (`convert_linear_to_polar`). Task 10 is rewritten to this.
  - **`hsv_circular`/`rgb` palette blend is MIXED by `hsv_rgb_palette_blend`** (`interpolation.c:383-384,432-433`): result = `rgb_fraction·new_rgb + (1−rgb_fraction)·new_hsv_rgb`, `rgb_fraction = hsv_rgb_palette_blend` (hsv_circular) / 1.0 (rgb) / 0.0 (hsv). `hsvRgbPaletteBlend` is added to the `Flame` model (Task 2) and the blend (Task 9). HSV hue is 0–6; shorter-arc adjust is ±3 / shift ±6 on cp0 only; no 8-bit rounding.
  - **RNG draw order is ascending NUMERIC variation-index in flam3** (varFunc via `for j if var[j]!=0`); CPU is alphabetical (parser-sorted); Metal is canonical-slot. They agree on the RNG-consuming subset by coincidence — pinned as a tested invariant (Task 6). Do NOT attribute RNG alignment to "each hit at most once"; that is not the reason.
- **No self-invented variation formulas.** Every special-sauce body is a line-for-line port of `varN_*` in `variations.c`. The round-2 review caught four unfaithful example formulas (blob, curl, rectangles, rings) whose tests were self-consistent with the wrong implementation — so tests MUST be derived from the C source independently, not from the Swift implementation under test.
- **`.metal` files are NOT compiled by the Swift toolchain.** `Package.swift` lists them under `resources: [.copy("Metal")]` in the `FlameRenderer` target; `Kernels.metal` is compiled to a `.metallib` at runtime by `MetalRenderer`. Consequence for Tasks 5/6: `swift build` will NOT catch an MSL syntax error or a Swift↔MSL layout mismatch — only `swift test --filter EndToEndParityTests` (or any Metal render) will. After every `Kernels.metal` edit, run a Metal test before committing; the `GPUXform` byte-layout guard (`bytesPerXform == 1248`, asserted in `packXforms`) is the only compile-time-adjacent check you get, and it only validates the Swift side.
- **The Swift `GPUXform` struct may NOT gain a `[Float]` field.** The xform buffer is created by byte-copying a `[GPUXform]` via `withUnsafeBytes` (`ChaosGameMetal.buf`). A Swift `Array` field stores a heap pointer, not inline floats, so it would send garbage to the GPU. This is why Task 5 switches the xform path to a flat-packed `[Float]` produced by `MetalHost.packXforms`. The 15-float scalar header may stay a struct; only the variable-size tail (`varWeights` + `varParams`) moves to the flat array. Do not "simplify" this back to a struct-with-array-field.
- **Interpolation runs once in FlameKit (Double).** The resulting `Flame` is handed to both renderers, so the genome is byte-identical CPU↔Metal. Never run interpolation on-device in FP32.
- **flam3 is read, never linked.** Port the logic; cite `file:line`. The oracle is a local build; vs-flam3 tests auto-skip if it's absent (F10), Metal↔CPU ≥38 dB remains the hard gate.
- **Thresholds:** vs-flam3 **≥30 dB**; Metal↔CPU **≥38 dB**; consecutive-frame continuity **≥40 dB**; genome-space `‖Δ‖ < 1e-3`. Do not swap these.
- **The `.linear` interpolation shim must keep M1/M2 green** throughout Phase A — S6-pre is an isolated, gate-keeping slice; do not change existing render behavior until S6. The `.linear` path reuses the legacy `mergeVariations` byte-for-byte (Task 10); only `.log` gets the union+carry merge.
