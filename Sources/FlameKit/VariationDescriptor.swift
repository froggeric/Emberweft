import Foundation

/// SINGLE SOURCE OF TRUTH for all variation metadata: the canonical 42-slot
/// order (M1's 19 + the 14 NEW special-sauce + bubble + eyefish + pie +
/// radial_blur + waves/popcorn/power/tangent/cross; spherical/polar counted
/// once), per-variation params/defaults,
/// special-sauce rest values, and the name→(slot, intra-slot-index) maps.
/// Shared by the parser, serializer, CPU `Variations` table, the Metal host
/// packer, and `apply_xform_body` dispatch. `Variations.canonicalOrder` IS a
/// one-line re-export of this array (landed in Task 5, which also grew
/// `GPUXform.varWeights` to `[36]` and the MSL if-chain, so the widening was
/// atomic). `VariationDescriptor.canonicalOrder` is the 37-name authority
/// used by all code paths, and `Variations.canonicalOrder` simply re-exports
/// it. Pinned to the spec's "Param-channel layout" + "Special-sauce padding"
/// tables.
public struct VariationDescriptor: Sendable {
    public let name: String
    public let parameters: [String]                 // ordered (intra-slot order)
    public let defaults: [String: Double]
    public let rest: [String: Double]               // special-sauce rest; key absent => stays at default

    // ---- canonical slot order (the 42-device-slot layout) ----
    /// Fixed 42-name order. First 19 == the M1 set (in its existing order, so the
    /// M1 Metal host `idxMap`/CPU `evaluate` stay slot-stable); then the 14 NEW
    /// special-sauce names in documented order; then `bubble` (var28) and
    /// `eyefish` (var27), both paramless/RNG-free, appended at slots 33/34 to
    /// preserve existing slots 0..32; then `pie` (var37, RNG-consuming, slot 35)
    /// and `radial_blur` (var36, RNG-consuming, slot 36); then the corpus-
    /// variations paramless non-RNG set: `waves` (var15, needs affine c,d,e,f),
    /// `popcorn` (var17, e,f), `power` (var19, precalc sina/cosa), `tangent`
    /// (var42), `cross` (var48) at slots 37..41.
    /// spherical/polar appear ONCE.
    public static let canonicalOrder: [String] = [
        // --- M1's 19 (do not reorder: existing slots 0..18) ---
        "bent","cosine","cylinder","diamond","disc","ex","exponential","fisheye",
        "handkerchief","heart","horseshoe","hyperbolic","julia","linear","polar",
        "sinusoidal","spherical","spiral","swirl",
        // --- 14 NEW special-sauce (slots 19..32) ---
        "rings","fan","blob","fan2","rings2","perspective","julian","juliascope",
        "ngon","curl","rectangles","super_shape","wedge_julia","wedge_sph",
        // --- var28_bubble (slot 33): paramless, RNG-free; unblocks 05739/31943 ---
        "bubble",
        // --- var27_eyefish (slot 34): paramless, RNG-free; NOT a fisheye alias
        //     (un-swapped output). Unblocks 00000 (partially; pie/radial_blur still pending). ---
        "eyefish",
        // --- var37_pie (slot 35): 3 ordered isaac_01 draws (slice, angular,
        //     radial). RNG-consuming → lives in `evaluate`'s switch, NOT the
        //     table. Unblocks 00000 (partially; radial_blur still pending). ---
        "pie",
        // --- var36_radial_blur (slot 36): 4 isaac_01 draws summed left-to-right
        //     into rndG = weight*(d1+d2+d3+d4-2.0). RNG-consuming → lives in
        //     `evaluate`'s switch, NOT the table. Unblocks 00000 (the last
        //     `.knownGap` fixture). ---
        "radial_blur",
        // --- corpus-variations paramless non-RNG set (slots 37..41). Each is
        //     paramless + 0 RNG draws → lives in the table closures, NOT
        //     `evaluate`'s switch. Verified formulas against
        //     /private/tmp/flam3-build/variations.c (Task 1 CV1). ---
        // var15_waves: needs affine c,d,e,f (waves_dx2=1/(e²+EPS), dy2=1/(f²+EPS))
        "waves",
        // var17_popcorn: needs affine e,f
        "popcorn",
        // var19_power: precalc sina/cosa/sqrt
        "power",
        // var42_tangent
        "tangent",
        // var48_cross
        "cross",
    ]
    /// Canonical device-slot index for a variation name (0..<42), or nil if unknown.
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

    /// Resolve a parametric XML attr key against the known tables. Returns nil for
    /// a plain variation-weight attr (e.g. "linear", "curl" with no suffix) or an
    /// unknown param suffix.
    ///
    /// Each param is stored under its FULL XML name (`blob_low`, `fan2_x`,
    /// `super_shape_n3`, …) — NOT the short suffix — so the serializer's
    /// `for p in d.parameters` emit loop produces `blob_low="…"` verbatim and
    /// `evaluate`/`v_blob` read the same key from `parameters`. Therefore the
    /// matcher checks the FULL `key` against `d.parameters` (after a `hasPrefix`
    /// gate as a fast-path intent check). Stripping the prefix and checking the
    /// short suffix would ALWAYS miss (there is no "low" entry, only "blob_low")
    /// — do not revert to that.
    ///
    /// "At most one hit" is guaranteed by param-name UNIQUENESS (no two variations
    /// share a full param key), independent of prefix distinctness; the `hasPrefix`
    /// gate is not load-bearing for uniqueness, only an optimization + clarity guard.
    public static func matchParamAttribute(_ key: String) -> (variation: String, param: String)? {
        for (varName, d) in table where !d.parameters.isEmpty {
            if key.hasPrefix(varName + "_") && d.parameters.contains(key) {
                return (varName, key)   // param == full XML name (e.g. "blob_low")
            }
        }
        return nil
    }

    // name -> (ordered params, defaults, rest-overrides). Covers ALL 35 canonical
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
        d("bubble", [], [:])     // var28_bubble: paramless, RNG-free (slot 33)
        d("eyefish", [], [:])    // var27_eyefish: paramless, RNG-free (slot 34; NOT a fisheye alias)
        // var37_pie (slot 35): 3 ordered isaac_01 draws. RNG-consuming → lives in
        // `evaluate`'s switch (mirrors julian), NOT the closure table.
        d("pie", ["pie_slices","pie_rotation","pie_thickness"],
          ["pie_slices":6,"pie_rotation":0,"pie_thickness":0.5])
        // var36_radial_blur (slot 36): 4 isaac_01 draws summed left-to-right
        // into rndG = weight*(d1+d2+d3+d4-2). RNG-consuming → lives in
        // `evaluate`'s switch, NOT the closure table.
        d("radial_blur", ["radial_blur_angle"], ["radial_blur_angle":0])
        // --- corpus-variations paramless non-RNG set (slots 37..41) ---
        // var15_waves (paramless; needs affine c,d,e,f)
        d("waves", [], [:])
        // var17_popcorn (paramless; needs affine e,f)
        d("popcorn", [], [:])
        // var19_power (paramless; precalc sina/cosa/sqrt)
        d("power", [], [:])
        // var42_tangent (paramless)
        d("tangent", [], [:])
        // var48_cross (paramless)
        d("cross", [], [:])
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
