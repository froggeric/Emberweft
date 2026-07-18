import Foundation

/// SINGLE SOURCE OF TRUTH for all variation metadata: the canonical 33-slot
/// order (M1's 19 + the 14 NEW special-sauce; spherical/polar counted once),
/// per-variation params/defaults, special-sauce rest values, and the
/// name→(slot, intra-slot-index) maps. Shared by the parser, serializer, CPU
/// `Variations` table, the Metal host packer, and `apply_xform_body` dispatch.
/// `Variations.canonicalOrder` IS a one-line re-export of this array (landed
/// in Task 5, which also grew `GPUXform.varWeights` to `[33]` and the MSL
/// if-chain, so the widening was atomic). `VariationDescriptor.canonicalOrder`
/// is the 33-name authority used by all code paths, and
/// `Variations.canonicalOrder` simply re-exports it. Pinned to the spec's
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
