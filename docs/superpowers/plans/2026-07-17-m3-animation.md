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
| `Sources/FlameKit/GenomeInterpolator.swift` | FlameKit | Rewrite of `Interpolation.swift`: `.linear` + `.log` (polar) matrix blend with `wind`-anchored unwrap, determinant guard, post-identity special case, HSV palette blend. Thin `interpolate(a,b,t)` shim. |
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

Modified files: `Sources/FlameKit/Genome.swift` (widen structs), `Sources/FlameKit/Flam3Parser.swift` + `Flam3Serializer.swift` (params + animation fields), `Sources/FlameKit/Interpolation.swift` (becomes the `.linear` shim delegating to `GenomeInterpolator`), `Sources/FlameKit/Variations.swift` (14 new CPU formulas), `Sources/FlameRenderer/MetalHost.swift` (`GPUXform` param channel + packer), `Sources/FlameRenderer/Metal/Kernels.metal` (`GPUXform` mirror + 14 MSL variations + `apply_xform_body`), `Sources/EmberweftCLI/CLI.swift` (wire `animate`), `Package.swift` (new files auto-included by path; `FlamePlayer` already a target). Docs: `transitions.md`, `playback-modes.md`, `roadmap.md`, `testing.md`, `architecture.md`, `CLAUDE.md`, `CHANGELOG.md`.

---

## Phase A — S6-pre: data model + 16 special-sauce variations (CPU + Metal)

The prerequisite slice. It lands first as an isolated, gate-keeping slice; M1/M2 stay green via the additive variation set and the `.linear` interpolation shim.

### Task 1: VariationDescriptor registry

**Goal:** Create the single source of truth for variation parameter metadata — param names, defaults, special-sauce rest values, and the fixed name→(slot,index) map — so the parser, serializer, CPU table, and Metal host packer all share one definition.

**Files:**
- Create: `Sources/FlameKit/VariationDescriptor.swift`
- Test: `Tests/FlameKitTests/VariationDescriptorTests.swift`

**Acceptance Criteria:**
- [ ] `VariationDescriptor` exposes, for each of the 16 special-sauce + `linear`: the canonical name, the ordered param-name list, the default value per param, and the special-sauce rest value per param (or `nil`).
- [ ] `slotIndex(variation:param:)` returns the pinned slot index from the spec's param-channel table (MAX_PARAMS_PER_SLOT = 6; see spec "Param-channel layout").
- [ ] Parameterless variations (`linear`, `spherical`, `polar`, `rings`, `fan`) report an empty param list.
- [ ] A unit test asserts the full table matches the spec's per-variation param table (names, defaults, rest, slot indices).

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
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter VariationDescriptorTests`
Expected: FAIL (cannot find `VariationDescriptor` in scope).

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Single source of truth for variation parameter metadata, shared by the
/// parser, serializer, CPU variation table, and Metal host packer. Pinned to
/// the spec's "Param-channel layout" + "Special-sauce padding" tables.
public struct VariationDescriptor: Sendable {
    public let name: String
    public let parameters: [String]                 // ordered (slot order)
    public let defaults: [String: Double]
    public let rest: [String: Double]               // special-sauce rest value; key absent => stays at default

    /// Fixed (variation,param) -> slot index (0..<MAX_PARAMS_PER_SLOT). Same map
    /// is used by the Metal host packer and mirrored implicitly by the MSL
    /// per-variation functions, which read params positionally.
    public static func slotIndex(variation: String, param: String) -> Int {
        guard let d = descriptor(for: variation) else { return 0 }
        return d.parameters.firstIndex(of: param) ?? 0
    }
    public static let maxParamsPerSlot = 6          // driven by super_shape

    public static func descriptor(for name: String) -> VariationDescriptor? { table[name] }

    // name -> (ordered params, defaults, rest-overrides). Defaults/rest source-
    // cited to flam3.h / parser.c / variations.c in the spec param table.
    private static let table: [String: VariationDescriptor] = {
        var t: [String: VariationDescriptor] = [:]
        func d(_ name: String, _ params: [String], _ defaults: [String: Double],
               _ rest: [String: Double] = [:]) {
            t[name] = VariationDescriptor(name: name, parameters: params, defaults: defaults, rest: rest)
        }
        d("linear", [], [:])
        d("spherical", [], [:])                      // Group A (parameterless)
        d("polar", [], [:])                           // Group A
        d("rings", [], [:])                           // Group C (swap-affine, no params)
        d("fan", [], [:])                             // Group C
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
- [ ] `Flame` has `interpolation: TempInterpolation` (default `.linear`), `interpolationType: MatrixInterpolationType` (default `.log`), `paletteInterpolation: PaletteInterpolation` (default `.hsvCircular`), `hueRotation: Double` (default `0`). Existing `hueShift` is retained unchanged (round-trip only — F4).
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
```
Add to the initializer (after `hueShift`): `interpolation: TempInterpolation = .linear, interpolationType: MatrixInterpolationType = .log, paletteInterpolation: PaletteInterpolation = .hsvCircular, hueRotation: Double = 0`.

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
- [ ] Parser reads `animate` (xform), `interpolation`/`interpolation_type`/`palette_interpolation`/`hue_rotation` (flame); serializer emits them all. `hue` (hueShift) and `hue_rotation` (hueRotation) are both read and both emitted.
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
    if let hit = VariationDescriptor.matchParamAttribute(k) {
        paramsByVariation[hit.variation, default: [:]][hit.param] = val
    } else {
        weights.append((k, val))
    }
}
x.variations = weights.sorted { $0.0 < $1.0 }.map { name, w in
    Variation(name: name, weight: w, parameters: paramsByVariation[name] ?? [:])
}
```

Add to `VariationDescriptor` a helper that returns the `(variation, param)` for an attribute key, preferring a known-variation prefix:

```swift
/// Resolve "<varname>_<paramname>" against the known tables. Returns nil for a
/// plain variation-weight attr (e.g. "linear", "curl" with no suffix).
public static func matchParamAttribute(_ key: String) -> (variation: String, param: String)? {
    for (varName, d) in table where !d.parameters.isEmpty {
        let prefix = varName + "_"
        if key.hasPrefix(prefix) {
            let param = String(key.dropFirst(prefix.count))
            if d.parameters.contains(param) { return (varName, param) }
        }
    }
    return nil
}
```

In `Flam3Serializer.xformString`, emit params after weights and `animate`:

```swift
if x.animate != 1 { a += " animate=\"\(f6(x.animate))\"" }
// ... existing variation-weight emission ...
for v in x.variations.sorted(by: { $0.name < $1.name }) where v.weight != 0 {
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

**Files:**
- Modify: `Sources/FlameKit/Variations.swift`
- Test: `Tests/FlameKitTests/VariationsTests.swift`

**Acceptance Criteria:**
- [ ] `Variations.knownNames` includes all 16 special-sauce names; `evaluate` dispatches each via a `(p, weight, params) -> SIMD2<Double>` closure keyed by name.
- [ ] Each of the 14 new formulas matches a hand-computed expected output on a fixed `(x,y)` input (tests cite the flam3 formula).
- [ ] `evaluate` no longer warns for any of the 16 names.
- [ ] flam3 EPS guards present where the source has them (`rings2_val²+EPS`, `fan2_x²+EPS`, curl denominator, `perspective` distance).

**Verify:** `swift test --filter VariationsTests` → PASS.

**Steps:**

- [ ] **Step 1: Write failing tests** (append to `VariationsTests.swift`; one per variation). Example shapes:

```swift
private func eval(_ name: String, _ p: SIMD2<Double>, _ w: Double, _ params: [String:Double] = [:]) -> SIMD2<Double> {
    Variations.evaluate([Variation(name: name, weight: w, parameters: params)], at: p, rng: &ISAAC(isaacSeed: "t"))
}
func testRings() {            // var21_rings: r = w/(tx²+ty²+EPS); m = 2*PI*r²*(tx²+ty²); (m*tx, m*ty) per flam3
    let out = eval("rings", SIMD2(0.5, 0.0), 1.0)
    let sumsq = 0.25; let eps = 1e-10
    let r = 1.0/(sumsq+eps); let m = 2.0 * .pi * r*r * sumsq
    XCTAssertEqual(out.x, m*0.5, accuracy: 1e-9); XCTAssertEqual(out.y, 0, accuracy: 1e-9)
}
func testFan() {              // var22_fan: fan via atan + rings-style; cite variations.c
    let out = eval("fan", SIMD2(0.3, 0.4), 1.0)
    XCTAssertEqual(out.x.isFinite, true); XCTAssertEqual(out.y.isFinite, true)
    // anchor: fan = rings(r) but angle-quantized; compare to a recomputed expected.
    let a = atan2(0.3,0.4); let r = sqrt(0.09+0.16)+1e-10
    let r2 = 1.0/(0.25+1e-10); let m = 2.0*.pi*r2*r2*0.25
    // (compute the fan-quantized angle per flam3 var22 and assert == out) ...
    _ = (a, r, m)
}
func testBlob() {             // var23_blob: low/high/waves radial modulation
    let out = eval("blob", SIMD2(0.6, 0.0), 1.0, ["blob_low":0.3,"blob_high":1.0,"blob_waves":2.0])
    let r = sqrt(0.36); let a = atan2(0.6,0.0)
    let rad = 0.3 + (1.0-0.3)*(sin(2.0*a*2.0)+1.0)*0.5
    XCTAssertEqual(out.x, 1.0*r*rad*cos(a), accuracy: 1e-9)
}
func testCurl() {
    let out = eval("curl", SIMD2(0.5, 0.2), 1.0, ["curl_c1":0.5,"curl_c2":0.0])
    // var39_curl: denom c1²+c2²+... ; cite variations.c, recompute expected.
    let x=0.5,y=0.2,c1=0.5,c2=0.0
    let t = 1.0 + c1*x + c2*y
    let nx = (x + c1*(x*x - y*y))/t
    XCTAssertEqual(out.x, 1.0*nx, accuracy: 1e-9)
}
func testRectangles() {
    let out = eval("rectangles", SIMD2(1.3, 0.7), 1.0, ["rectangles_x":0.4,"rectangles_y":0.6])
    XCTAssertEqual(out.x, 1.0*(0.4*(2*floor(1.3/(2*0.4))+1) - 1.3), accuracy: 1e-9)
}
func testSuperShapeFinite() {
    let out = eval("super_shape", SIMD2(0.4,0.0), 1.0,
        ["super_shape_rnd":0,"super_shape_m":4,"super_shape_n1":2,"super_shape_n2":2,"super_shape_n3":2,"super_shape_holes":0])
    XCTAssertTrue(out.x.isFinite); XCTAssertTrue(out.y.isFinite)
}
func testJulianFinite() {
    let out = eval("julian", SIMD2(0.3,0.1), 1.0, ["julian_power":2,"julian_dist":1.0])
    XCTAssertTrue(out.x.isFinite)
}
// + juliascope, ngon, fan2, rings2, perspective, wedge_julia, wedge_sph — one finite/anchored test each.
```

(For each variation, complete the expected-value computation in the test body by following the flam3 formula cited in the inline comment. The finite checks are mandatory; the anchored equality checks are mandatory for `rings`/`blob`/`curl`/`rectangles` and any other with a clean closed form.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter VariationsTests`
Expected: FAIL (names warn-unknown / return zero).

- [ ] **Step 3: Write minimal implementation**

Change the table value type to carry params: `(SIMD2<Double>, Double, [String: Double]) -> SIMD2<Double>`, and update `evaluate` to pass `v.parameters`. Then add the 14 closures (port from flam3 `variations.c`; EPS = 1e-10). Representative ports (write all 14):

```swift
let eps = 1e-10
t["rings"] = { p, w, _ in          // var21_rings
    let sumsq = p.x*p.x + p.y*p.y; let r = w / (sumsq + eps)
    let m = 2.0 * .pi * r * r * sumsq
    return SIMD2(m * p.x, m * p.y)
}
t["fan"] = { p, w, _ in            // var22_fan
    let a = atan2(p.x, p.y); let sumsq = p.x*p.x + p.y*p.y
    let r = w / (sumsq + eps); let m = 2.0 * .pi * r * r * sumsq
    let dy = m * p.y; let dx = m * p.x
    let frac = a / .pi            // fan quantization; full flam3 form:
    let n = floor(frac * 2.0)     // (use exact flam3 var22 expression here)
    _ = (dy, dx, n)
    // Replace the placeholder lines above with the exact var22_fan body from
    // variations.c (atan-based two-arm fan). Compute and return (x,y).
    return SIMD2(dx, dy)          // placeholder line removed in real impl
}
t["blob"] = { p, w, par in         // var23_blob
    let low = par["blob_low"] ?? 0; let high = par["blob_high"] ?? 1; let waves = par["blob_waves"] ?? 1
    let r = (p.x*p.x + p.y*p.y).squareRoot(); let a = atan2(p.x, p.y)
    let rad = low + (high - low) * (sin(waves * a * 2.0) + 1.0) * 0.5
    return SIMD2(w * r * rad * cos(a), w * r * rad * sin(a))
}
t["curl"] = { p, w, par in         // var39_curl
    let c1 = par["curl_c1"] ?? 1; let c2 = par["curl_c2"] ?? 0
    let t1 = 1 + c1*p.x + c2*p.y
    let nx = (p.x + c1*(p.x*p.x - p.y*p.y)) / t1
    let ny = (p.y + c2*(p.x*p.x - p.y*p.y)) / t1
    return SIMD2(w * nx, w * ny)
}
t["rectangles"] = { p, w, par in   // var40_rectangles
    let rx = par["rectangles_x"] ?? 1; let ry = par["rectangles_y"] ?? 1
    let nx = rx == 0 ? p.x : (rx * (2 * floor(p.x / (2*rx)) + 1) - p.x)
    let ny = ry == 0 ? p.y : (ry * (2 * floor(p.y / (2*ry)) + 1) - p.y)
    return SIMD2(w * nx, w * ny)
}
// julian / juliascope / ngon / fan2 / rings2 / perspective / super_shape /
// wedge_julia / wedge_sph: port each verbatim from variations.c into a closure
// of the same signature, reading params via `par["..."] ?? default`.
```

> **No placeholder in the final file:** complete every `varN_*` body exactly as flam3 writes it (the engineer reads `variations.c` for the remaining 9). The `fan` body shown with `_ = (...)`/`placeholder` is an outline only — the committed implementation is the real formula. Update `knownNames` to include all 16 names; the existing `evaluate`/`julia`/canonical-order comments stay.

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

**Goal:** Add the per-slot parameter channel to `GPUXform` on both sides of the Swift→MSL boundary, build the host packer from `VariationDescriptor`, bump the stride assertion, and prove the widening is additive (M2 parity stays green and a fuzz run **excluding** the 16 new names shows no regression).

**Files:**
- Modify: `Sources/FlameRenderer/MetalHost.swift` (`GPUXform` + `buildGPUXforms`)
- Modify: `Sources/FlameRenderer/Metal/Kernels.metal` (`struct GPUXform` + param reads)
- Test: `Tests/FlameRendererTests/ParamChannelParityTests.swift` (new)

**Acceptance Criteria:**
- [ ] `GPUXform` (Swift + MSL) gains `varParams[NUM_XFORM_SLOTS][8]` (MAX_PARAMS_PER_SLOT=6, device slot width 8); both `MemoryLayout<GPUXform>.stride` assertions updated to the new byte count and equal on both sides.
- [ ] `buildGPUXforms` packs each variation's `parameters` into positional `varParams[slot][index]` via `VariationDescriptor`; unused tail slots zeroed; `super_shape_rnd` clamped to `[0,1]` in the packer.
- [ ] The existing M2 end-to-end parity suite (`EndToEndParityTests`) stays green at ≥38 dB / 0.95 SSIM.
- [ ] A fuzz run over genomes that use **only the original 19 names** produces byte-identical output to a pre-change baseline (proving additivity).

**Verify:** `swift test --filter EndToEndParityTests --filter ParamChannelParityTests` → PASS.

**Steps:**

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import FlameRenderer
import FlameKit

final class ParamChannelParityTests: XCTestCase {
    @MainActor
    func testStrideMatches() throws {
        // NUM_XFORM_SLOTS (e.g. 8) * 8 floats added to the 34-float base.
        XCTAssertEqual(MemoryLayout<GPUXform>.stride, GPUXform.expectedStride)
    }
    @MainActor
    func testOriginalGenomesUnchanged() throws {
        // A genome using only the 19 original names must render identically.
        let flame = Flame(size: SIMD2(160,100), camera: Camera(scale: 200),
            xforms: [Xform(affine: .identity, color: 0, variations: [Variation(name:"linear",weight:1)])],
            palette: Palette(colors: (0..<256).map { SIMD3<Double>(Double($0)/255,0.5,0.5) }))
        let p = RenderParams(seed: 0, width: 160, height: 100, oversample: 1, samplesPerPixel: 200)
        let img = MetalRenderer.render(flame: flame, params: p)
        XCTAssertEqual(img.pixels.count, 160*100*4)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ParamChannelParityTests`
Expected: FAIL (`expectedStride` / `NUM_XFORM_SLOTS` do not exist).

- [ ] **Step 3: Write minimal implementation**

In `MetalHost.swift`, extend `GPUXform` (append after `varWeights`). Use `NUM_XFORM_SLOTS = 8` (one slot per active variation an xform may carry; pad). Store as a flat `Float` array of count `8*8` for guaranteed contiguous layout, with an accessor:

```swift
public struct GPUXform {
    // ... existing 34-float fields ...
    public static let numXformSlots = 8
    public static let slotWidth = 8
    public static let expectedStride: Int = 136 + numXformSlots * slotWidth * MemoryLayout<Float>.size
    public var varParams: [Float]   // count == numXformSlots * slotWidth
    public init() { varParams = Array(repeating: 0, count: numXformSlots * slotWidth) }
}
```

Update the stride precondition to `MemoryLayout<GPUXform>.stride == GPUXform.expectedStride`.

Rewrite `buildGPUXforms` to also pack params: after the existing `varWeights` packing loop, iterate the xform's variations in canonical order and, for each parametric variation, write its params into `varParams[slot*slotWidth + idx]` using `VariationDescriptor.slotIndex`; clamp `super_shape_rnd` to `[0,1]`.

In `Kernels.metal`, mirror exactly:

```metal
#define NUM_XFORM_SLOTS_MS 8
#define SLOT_WIDTH_MS 8
struct GPUXform {
    float a,b,c,d,e,f;
    float pa,pb,pc,pd,pe,pf;
    float color, colorSpeed, opacity;
    float varWeights[19];
    float varParams[NUM_XFORM_SLOTS_MS * SLOT_WIDTH_MS];
};
```

(Param reads are wired in Task 6; here only the layout lands.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter EndToEndParityTests --filter ParamChannelParityTests`
Expected: PASS (M2 parity unaffected; stride asserts hold).

- [ ] **Step 5: Commit**

```bash
git add Sources/FlameRenderer/MetalHost.swift Sources/FlameRenderer/Metal/Kernels.metal Tests/FlameRendererTests/ParamChannelParityTests.swift
git commit -m "feat(renderer): GPUXform parameter channel + host packer (additive)"
```

---

### Task 6: Port the 14 MSL variation functions + per-variation Metal↔CPU parity

**Goal:** Port the 14 new MSL variation functions, wire them into `apply_xform_body` (which grows from 19 guarded lines to cover all active slots), and prove Metal↔CPU parity (≥38 dB / 0.95 SSIM) for each of the 16 on a constructed single-variation genome.

**Files:**
- Modify: `Sources/FlameRenderer/Metal/Kernels.metal`
- Modify: `Sources/FlameRenderer/MetalHost.swift` (canonical-order/slot wiring if needed)
- Test: `Tests/FlameRendererTests/SpecialSauceParityTests.swift` (new)

**Acceptance Criteria:**
- [ ] All 16 special-sauce variations have MSL `v_<name>` functions; `apply_xform_body` evaluates every active slot with the `w != 0` guard, reading params positionally from `x.varParams`.
- [ ] For each of the 16 names, a constructed single-variation genome renders Metal vs CPU at PSNR ≥ 38 dB / SSIM ≥ 0.95.
- [ ] No NaN/Inf pixels on any of the 16 constructed genomes.
- [ ] The full `EndToEndParityTests` suite stays green.

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

In `Kernels.metal`, add `v_<name>(float2 p, float w, thread const float* params)` for each of the 14, ports of the Task-4 CPU closures (Float math). Examples:

```metal
static inline float2 v_rings(float2 p, float w) {
    float sumsq = p.x*p.x + p.y*p.y; float r = w / (sumsq + EPS_MS);
    float m = 2.0f * M_PI_F * r * r * sumsq;
    return float2(m * p.x, m * p.y);
}
static inline float2 v_blob(float2 p, float w, thread const float* pr) {
    float low = pr[0], high = pr[1], waves = pr[2];
    float r = sqrt(sumsq(p)); float a = atan2(p.x, p.y);
    float rad = low + (high - low) * (sin(waves * a * 2.0f) + 1.0f) * 0.5f;
    return float2(w * r * rad * cos(a), w * r * rad * sin(a));
}
static inline float2 v_curl(float2 p, float w, thread const float* pr) {
    float c1 = pr[0], c2 = pr[1];
    float t = 1.0f + c1*p.x + c2*p.y;
    return float2(w * (p.x + c1*(p.x*p.x - p.y*p.y)) / t,
                  w * (p.y + c2*(p.x*p.x - p.y*p.y)) / t);
}
// ... rectangles, fan, fan2, rings2, perspective, julian, juliascope, ngon,
//     super_shape, wedge_julia, wedge_sph — each reads pr[0..k] positionally ...
```

Extend `apply_xform_body` to dispatch by name: since `varWeights` is canonical-order keyed, add a parallel name-index scheme. The simplest faithful approach mirroring CPU: keep `varWeights[19]` for the original set, and add a small fixed array of `(nameTag, weight)` for the 16 special-sauce slots (tag = the MSL enum index 0..15). The host packer (Task 5) fills `varWeights` for the original-19 and the special-sauce slot array for the 16, with matching `varParams`. `apply_xform_body` then runs both groups with the `w != 0` guard, passing `&x.varParams[slot*SLOT_WIDTH_MS]` as the param pointer. (Concretely: add `float ssWeights[16]; uint8 ssTags[16];` to `GPUXform` if a pure-slot scheme proves cleaner — choose the one that keeps the layout simple and the stride asserted; document the choice in a comment.)

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
- [ ] `testing.md` records the oracle as a dev-machine prerequisite (not CI), the 30 dB (vs-flam3) vs 38 dB (Metal↔CPU) split, and the F10 auto-skip fallback.

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
- [ ] `BlendMath.staggerCoef(ncp:2, xformIndex:i, notFinal:flag, stagger:s, t:)` returns the documented per-xform eased sub-interval; for `stagger<=0` or `ncp!=2` or the final xform it returns `smoother(t)` unchanged (no stagger).
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

**Goal:** Port flam3's transition palette blend: HSV (`hsv_circular`) interpolation of the two endpoints' 256-entry RGB LUTs (`interpolation.c:377-427`), and linear interpolation of `hueRotation` across keyframes (`INTERP(hue_rotation)`, `interpolation.c:478`).

**Files:**
- Create: `Sources/FlameKit/PaletteBlend.swift` (kept in its own file so Task 9 does not depend on the later Task 10)
- Test: `Tests/FlameKitTests/PaletteBlendTests.swift`

**Acceptance Criteria:**
- [ ] `PaletteBlend.hsvCircular(a,b,t)` returns the HSV-circular interpolated 256-LUT; at `t=0==a`, `t=1==b`, midpoint is the shorter-arc hue blend.
- [ ] `hueRotation` interpolates linearly across two genomes.
- [ ] All entries finite; `rgb` fallback (palette_interpolation=rgb) also implemented (linear RGB) so the `paletteInterpolation` switch is exhaustive.

**Verify:** `swift test --filter PaletteBlendTests` → PASS.

**Steps:**

- [ ] **Step 1: Write failing tests** (endpoint equality at t=0/t=1; hsv midpoint on a known red→green pair recomputed by hand; finiteness on a black palette).
- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** RGB→HSV→blend (shortest-arc hue for hsv_circular)→HSV→RGB per flam3 `hsv_rgb_palette_blend`; linear `hueRotation` interp.
- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Commit** `feat(flamekit): HSV/RGB palette blend + hueRotation interpolation`.

---

### Task 10: GenomeInterpolator rewrite (.linear + .log polar)

**Goal:** Replace the M1 `Interpolation.interpolate` body with a `GenomeInterpolator` that switches on `interpolationType`: `.linear` (the existing per-field lerp, now the shim) and `.log` (polar matrix decomposition with `wind`-anchored angle unwrap, determinant guard → linear fallback, post-identity special case). A thin `Interpolation.interpolate(a,b,t)` shim delegates to `.linear` so M1/M2 call sites and tests stay green.

**Files:**
- Create: `Sources/FlameKit/GenomeInterpolator.swift`
- Modify: `Sources/FlameKit/Interpolation.swift` (becomes the shim)
- Test: `Tests/FlameKitTests/InterpolationTests.swift` (extend)

**Acceptance Criteria:**
- [ ] `GenomeInterpolator.interpolate(a, b, t, type:)` switches on `interpolationType`.
- [ ] `.linear` matches the previous `Interpolation.interpolate` output bit-for-bit on the existing test genomes (M1/M2 tests unchanged).
- [ ] `.log` interpolates each xform's 2×2 via polar decomposition (magnitude linear, angle unwrapped by `wind`), guards near-zero determinant (falls back to linear), and forces result post to identity when both parents' post is identity.
- [ ] Near-singular constructed affine does not produce NaN/Inf (determinant-guard fallback exercised by a test).
- [ ] `mergeVariations` no longer drops zero-weight / re-sorts incorrectly for `.log` (variations are unioned by name with per-name parameter carry-over from the side that has them).

**Verify:** `swift test --filter InterpolationTests` → PASS (including the degenerate-affine case).

**Steps:**

- [ ] **Step 1: Write failing tests** — `.linear` parity with old output (snapshot a few coefficients), `.log` midpoint on a rotation pair (recomputed), and a near-singular affine that must stay finite.
- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** `GenomeInterpolator` (port `convert_linear_to_polar` + `interp_and_convert_back` + the `wind` unwrap `interpolation.c:293-309` + the determinant guard + post-identity special case `interpolation.c:668-679`). Rewrite `mergeVariations` to union variations and carry params from whichever side defines them. Make `Interpolation.interpolate` call `GenomeInterpolator.interpolate(a,b,t,type:.linear)`.
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

**Verify:** `swift test --filter RefAnglesTests` → PASS.

**Steps:**

- [ ] **Step 1: Write failing tests** (asymmetric pair → wind set; symmetric pair → unchanged; coefs untouched).
- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** `establish` (port the column-angle computation + the `+2π` store; gate on `animate==0 || padding`).
- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Commit** `feat(flamekit): establish_asymmetric_refangles (wind[col]) port`.

---

### Task 13: `Loop.blend` (sheep_loop port — pure affine rotation)

**Goal:** Port `sheep_loop` (`flam3.c:396-557`): for each non-final xform with `animate != 0`, left-multiply the pre-affine 2×2 by `R(t·360°)`; translation/post/camera/palette/weight/color/opacity/chaos untouched; final xforms skipped; padding xforms rotate only under `.log`. Output genome has `frame(t=1) == frame(t=0)` (seamless).

**Files:**
- Create: `Sources/FlameKit/Loop.swift`
- Test: `Tests/FlameKitTests/LoopTests.swift`

**Acceptance Criteria:**
- [ ] `Loop.blend(sheep, t)` returns a genome equal to the input at `t=0`; equal again at `t=1` (seamlessness — `R(360°)·M == M`).
- [ ] Only the 2×2 pre-affine of animating, non-final xforms changes; translation `e,f` and post-affine and palette are byte-equal to the input.
- [ ] An xform with `animate==0` is untouched; a final xform is untouched; a padding xform rotates only when `interpolationType == .log`.
- [ ] Rotation direction/ULP matches a hand-computed `R(θ)·M` at `t=0.25` (90°).

**Verify:** `swift test --filter LoopTests` → PASS.

**Steps:**

- [ ] **Step 1: Write failing tests** (t=0/t=1 equality across all xforms; e,f/post/palette untouched; animate==0 untouched; 90° hand-check).
- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** `blend` (clone, for each xform with `animate != 0 && !isFinal` and (`padding==0 || type==.log`): `affine.a,b,c,d = R(θ)·M` where θ = t·2π; leave e,f).
- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Commit** `feat(flamekit): Loop.blend sheep_loop port (pure affine rotation, palette static)`.

---

### Task 14: `Transition.blend` (sheep_edge port)

**Goal:** Port `sheep_edge` (`flam3.c:434-508` + `spin_inter`): clone both parents → `align` (Task 11) → normalize times → `establish_asymmetric_refangles` (Task 12) → rotate both by `t·360°` (`Loop` rotation) → `GenomeInterpolator.interpolate(2cp, smoother(t), stagger)` with `.log` + HSV palette blend. Strip motion elements; return the interpolated genome.

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
- [ ] **Step 3: Implement** `blend` orchestrating Tasks 8–12: `align` → normalize times to {0,1} → `establish` → rotate both via the Task-13 rotation → `GenomeInterpolator.interpolate(spun, 2, staggerCoef(...), type:.log)` (palette via Task-9 hsv_circular).
- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Commit** `feat(flamekit): Transition.blend sheep_edge port (align+rotate+log interp+HSV palette)`.

---

### Task 15: `PairSelector` (Sequential) + `Schedule` (two-level seek)

**Goal:** Add the `PairSelector` protocol + `Sequential` impl (TDD scaffold), the `Segment` model, and the pure two-level-seek `Schedule`: global-frame → `(segmentId, blend)` is O(1) (constant tier lengths); `segmentId → (fromSheep, toSheep)` is O(1) within the materialized prefix and O(segments) to extend the `Sequential`/`SimilarityExploration` walk forward. Alternation invariant: no two transitions consecutive.

**Files:**
- Create: `Sources/FlameKit/PairSelector.swift`, `Sources/FlameKit/Schedule.swift`
- Test: `Tests/FlameKitTests/ScheduleTests.swift`

**Acceptance Criteria:**
- [ ] `Schedule(librarySize:, framesPerSegment:, selector:, seed:)` maps any global frame index to `(segmentId, kind, blend)` in O(1).
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
- [ ] The similarity score for a fixed pair is **bit-identical across N separate process launches** (F1 hard rule — the test spawns N processes and compares the printed score).
- [ ] Every term has an independent ε fallback, so an all-zero palette or zero-norm affine cannot NaN the score (F9).
- [ ] A 50-segment `SimilarityExploration` walk over the full library visits **≥ max(⌈0.5·librarySize⌉, 10)** distinct sheep (exploration guard), reproducible under fixed seed.

**Verify:** `swift test --filter SimilarityTests` → PASS (incl. the cross-process bit-identity test).

**Steps:**

- [ ] **Step 1: Write failing tests** — the cross-process bit-identity test (a tiny executable helper or `swift test`-spawned subprocess that prints the score for a fixed pair; the test asserts all N outputs equal), the exploration-count test, and the F9 zero-palette finiteness test.
- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** `FeatureVector` (sorted-array storage; `cosine`/`distance` helpers that iterate the sorted arrays), the guarded metric, and `SimilarityExploration` (ε-greedy using an `ISAAC`/`RNG` seeded walk + an integer `Set<Int>` recency window — integer-indexed, so the walk is deterministic).
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
- [ ] `emberweft animate a.flam3 b.flam3 --frames 8 --segments 3 --selector sequential --seed 0 --backend cpu --out /tmp/frames` writes the PNG sequence + manifest.
- [ ] `manifest.json` parses via `Manifest` Codable; `manifestVersion==1`; loop rows have `interpolationType: null`; `stagger` is top-level.
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

**Acceptance Criteria:**
- [ ] `sheep_loop` vs `flam3-genome rotate`: our loop frame vs flam3's, PSNR ≥ 30 dB / SSIM ≥ 0.95 (skip if oracle absent).
- [ ] `sheep_edge` vs `flam3-genome inter`: our transition vs flam3's, PSNR ≥ 30 dB / SSIM ≥ 0.95 (skip if oracle absent).
- [ ] `sheep_loop` seamlessness: `frame(t=0)` vs `frame(t=1)` genome-equal and rendered within Metal↔CPU parity.
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

**Verify:** `swift test --filter PlaybackDispatcherTests` → PASS.

**Steps:**

- [ ] **Step 1: Write failing tests** (alternation under a fake clock; prefetch invoked once per loop; no duplicate-on-transition using a capturing fake renderer).
- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** the actor (frame-advance loop, triple-buffer texture pool, prefetch task; isolate `MetalRenderer` calls behind a protocol so the test injects a fake).
- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Commit** `feat(player): PlaybackDispatcher actor (Schedule-driven, triple-buffered, prefetch)`.

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

**Goal:** Update the docs the spec lists, correcting the loop/palette wording everywhere, promoting transitions to implemented reality, adding the animation-parity layer + oracle to `testing.md`, adding `FlameUI`/`PlaybackDispatcher` to `architecture.md`, and flipping M3 to ✅ in `roadmap.md` + a `CHANGELOG.md` entry.

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
- **Interpolation runs once in FlameKit (Double).** The resulting `Flame` is handed to both renderers, so the genome is byte-identical CPU↔Metal. Never run interpolation on-device in FP32.
- **flam3 is read, never linked.** Port the logic; cite `file:line`. The oracle is a local build; vs-flam3 tests auto-skip if it's absent (F10), Metal↔CPU ≥38 dB remains the hard gate.
- **Thresholds:** vs-flam3 **≥30 dB**; Metal↔CPU **≥38 dB**; consecutive-frame continuity **≥40 dB**; genome-space `‖Δ‖ < 1e-3`. Do not swap these.
- **The `.linear` interpolation shim must keep M1/M2 green** throughout Phase A — S6-pre is an isolated, gate-keeping slice; do not change existing render behavior until S6.
