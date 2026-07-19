import Foundation

/// Parses `.flam3` XML documents into `[Flame]` genomes.
///
/// A document is `<flames><flame>…</flame>…</flames>`. A single `<flame>`
/// describes one genome (one animation keyframe when several share a document).
/// Both the flam3/Apophysis hex-block `<palette>` form and the Apophysis
/// `<color index rgb>` child form are accepted.
///
/// Variation weights are read from xform **attributes**
/// (e.g. `<xform linear="1" sinusoidal="0.5" …/>`) — the form `flam3-render`
/// reads — as well as the `<var name weight>` child-element form (merged after
/// attribute variations). Unknown variation names parse through (stored) so
/// imported genomes round-trip without error.
public enum Flam3Parser {
    public static func parse(_ data: Data) throws -> [Flame] {
        let builder = Flam3Builder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        parser.shouldProcessNamespaces = false
        guard parser.parse() else {
            throw builder.error ?? .malformedXML(parser.parserError?.localizedDescription ?? "parse failed")
        }
        if let e = builder.error { throw e }
        guard !builder.flames.isEmpty else { throw FlameKitError.missingElement("flame") }
        return builder.flames
    }
}

private final class Flam3Builder: NSObject, XMLParserDelegate {
    var flames: [Flame] = []
    var error: FlameKitError?

    private var flame: Flame?
    private var xform: Xform?
    /// Running xform-array index (flam3 stores the final xform at the tail of
    /// the same array, so the final's index = count of regular xforms).
    /// Used for the flam3 `initialize_xforms` color default (`xform[i].color
    /// = i & 1`, flam3.c:3139) when the `color` attribute is absent.
    private var xformIndex = 0
    private var inPalette = false
    private var paletteColors: [SIMD3<Double>] = Array(repeating: .zero, count: 256)
    private var hexAccumulator = ""

    func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attr: [String: String]) {
        switch name {
        case "flame":
            flame = makeFlame(attr: attr)
            xformIndex = 0
            // Reset the palette accumulator per flame so a sibling <flame>'s
            // colors don't leak in (and a flame with no palette resolves to
            // all-zero, matching flam3).
            paletteColors = Array(repeating: .zero, count: 256)
        case "xform", "finalxform":
            // flam3 indexes the final xform at the tail of the xform array
            // (its index = number of regular xforms parsed so far). Pass the
            // current index so the color default matches initialize_xforms.
            xform = makeXform(attr: attr, index: xformIndex)
        case "var":
            if let n = attr["name"], let w = attr["weight"], xform != nil {
                xform!.variations.append(Variation(name: n, weight: Double(w) ?? 1))
            }
        case "palette":
            inPalette = true; hexAccumulator = ""
            // Reset per flame so entries from a sibling <flame> don't leak in.
            paletteColors = Array(repeating: .zero, count: 256)
        case "color":
            // flam3 `<color>` elements are DIRECT children of `<flame>` in real
            // genomes (`rgb="r g b"`, decimal 0–255), and only rarely inside a
            // `<palette>`. Handle both — do NOT gate on `inPalette`, or every
            // real-genome palette is silently dropped to zero (black render).
            // `rgb` is a decimal triple, not hex — parseDecimalRGB, not parseHex.
            if let idxStr = attr["index"], let rgb = attr["rgb"] {
                let idx = Int(idxStr) ?? 0
                if (0..<256).contains(idx) { paletteColors[idx] = parseColorRGB(rgb) }
            }
        default: break
        }
    }

    func parser(_ p: XMLParser, foundCharacters s: String) {
        if inPalette { hexAccumulator += s }
    }

    func parser(_ p: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch name {
        case "palette":
            inPalette = false
            if !hexAccumulator.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                applyHexBlock(hexAccumulator)   // flam3 native hex palette
            }
            flame?.palette = Palette(colors: paletteColors)
        case "xform":
            if let xf = xform { flame?.xforms.append(xf) }; xform = nil
            xformIndex += 1
        case "finalxform":
            if let xf = xform { flame?.finalXform = xf }; xform = nil
        case "flame":
            // Apply the accumulated palette (from direct `<color>` children OR a
            // `<palette>` hex block). Without this, real genomes (no `<palette>`
            // element) never assign their palette → all-zero → black render.
            flame?.palette = Palette(colors: paletteColors)
            if let f = flame { flames.append(f) }
            flame = nil
        default: break
        }
    }

    func parser(_ p: XMLParser, parseErrorOccurred err: Error) {
        if error == nil { error = .malformedXML(err.localizedDescription) }
    }

    // ---- helpers ----
    private func makeFlame(attr: [String: String]) -> Flame {
        var f = Flame()
        f.name = attr["name"] ?? ""
        if let s = attr["size"] { let p = floats(s); if p.count == 2 { f.size = SIMD2(Int(p[0]), Int(p[1])) } }
        if let c = attr["center"] { let p = floats(c); if p.count == 2 { f.camera.center = SIMD2(p[0], p[1]) } }
        f.camera.scale = attr["scale"].flatMap { Double($0) } ?? 250
        f.camera.zoom = attr["zoom"].flatMap { Double($0) } ?? 0
        f.camera.rotation = attr["rotate"].flatMap { Double($0) } ?? 0
        f.quality.oversample = attr["oversample"].flatMap { Int($0) } ?? 1
        f.quality.samplesPerPixel = attr["quality"].flatMap { Int($0) } ?? 100
        f.quality.gamma = attr["gamma"].flatMap { Double($0) } ?? 2.2
        f.quality.gammaThreshold = attr["gamma_threshold"].flatMap { Double($0) } ?? 0.01
        f.quality.vibrancy = attr["vibrancy"].flatMap { Double($0) } ?? 1.0
        f.quality.brightness = attr["brightness"].flatMap { Double($0) } ?? 4.0
        f.quality.estimatorRadius = attr["estimator_radius"].flatMap { Double($0) } ?? 0
        f.quality.estimatorMinimum = attr["estimator_minimum"].flatMap { Double($0) } ?? 0
        f.quality.estimatorCurveRate = attr["estimator_curve"].flatMap { Double($0) } ?? 0.6
        f.hueShift = attr["hue"].flatMap { Double($0) } ?? 0
        f.time = attr["time"].flatMap { Double($0) } ?? 0
        // Animation attributes (flam3 interpolation pipeline). Defaults mirror
        // flam3: temporal=linear, matrix=log, palette=hsv_circular, hue=0.
        f.interpolation = attr["interpolation"].flatMap { TempInterpolation(rawValue: $0) } ?? .linear
        f.interpolationType = attr["interpolation_type"].flatMap { MatrixInterpolationType(rawValue: $0) } ?? .log
        f.paletteInterpolation = attr["palette_interpolation"].flatMap { PaletteInterpolation(rawValue: $0) } ?? .hsvCircular
        f.hueRotation = attr["hue_rotation"].flatMap { Double($0) } ?? 0
        f.hsvRgbPaletteBlend = attr["hsv_rgb_palette_blend"].flatMap { Double($0) } ?? 0
        return f
    }

    private func makeXform(attr: [String: String], index: Int) -> Xform {
        var x = Xform()
        x.weight = attr["weight"].flatMap { Double($0) } ?? 1
        // flam3 `initialize_xforms` (flam3.c:3139): when the `color` attribute
        // is absent, default to `i & 1` (0.0 for even-index, 1.0 for odd). This
        // applies to BOTH regular xforms and the finalxform (which sits at the
        // tail of flam3's xform array), matching flam3's exact default.
        x.color = attr["color"].flatMap { Double($0) } ?? Double(index & 1)
        // Prefer the explicit `color_speed` attribute (what we serialize); fall
        // back to legacy `symmetry` (flam3/Apophysis) for imported genomes.
        if let cs = attr["color_speed"].flatMap({ Double($0) }) { x.colorSpeed = cs }
        else if let sym = attr["symmetry"].flatMap({ Double($0) }) { x.colorSpeed = 1 - sym }
        else { x.colorSpeed = 0.5 }
        x.opacity = attr["opacity"].flatMap { Double($0) } ?? 1
        if let cf = attr["coefs"] { x.affine = parseAffine(cf) ?? .identity }
        if let pf = attr["post"] { x.postAffine = parseAffine(pf) ?? .identity }
        if let ch = attr["chaos"] { x.chaos = floats(ch) }
        // flam3 convention: `animate` is an xform attribute (0 => symmetry xform,
        // rotation skipped). Absent => 1.0 (random default rotates).
        x.animate = attr["animate"].flatMap { Double($0) } ?? 1.0
        // flam3/Apophysis convention: variation weights are xform ATTRIBUTES
        // (e.g. `<xform linear="1" sinusoidal="0.5" .../>`). This is the ONLY
        // form flam3-render reads, so the frozen golden genomes (Task 12) MUST
        // use it — a `<var>` child element is ignored by flam3 and yields a
        // blank render. Any attribute that is not a reserved keyword is either a
        // variation weight (plain `<name>="…"`) or a parametric attribute
        // (`<varname>_<paramname>="…"`, routed to that variation's `parameters`
        // via `VariationDescriptor.matchParamAttribute`). Unknown attrs still
        // parse through as zero-contribution weights so imported genomes
        // round-trip without error. Sort by name so round-trip order is
        // deterministic regardless of XMLParser's dictionary iteration order.
        let reserved: Set<String> = [
            "weight", "color", "color_speed", "symmetry", "coefs", "post",
            "chaos", "opacity", "animate", "name",
            "interpolation", "interpolation_type", "palette_interpolation",
            "hue_rotation", "hue",
        ]
        var weights: [(String, Double)] = []
        var paramsByVariation: [String: [String: Double]] = [:]
        for (k, v) in attr where !reserved.contains(k) {
            guard let val = Double(v) else { continue }
            if let hit = VariationDescriptor.matchParamAttribute(k) {
                paramsByVariation[hit.variation, default: [:]][hit.param] = val
            } else {
                // Unknown attr (incl. malformed "<knownvar>_<unknownparam>",
                // e.g. blob_foo) falls through as a zero-contribution weight
                // Variation — existing behavior. It round-trips but creates a
                // phantom variation; left as-is for compat.
                weights.append((k, val))
            }
        }
        // Param-without-weight edge case: a parametric attr whose base weight
        // attr is absent (e.g. `<xform blob_low="0.2"/>` with no `blob="…"`)
        // must still round-trip. Synthesize a weight-0 variation to carry the
        // params so the serializer (which emits params regardless of weight)
        // preserves them.
        let weightedNames = Set(weights.map { $0.0 })
        for (varName, _) in paramsByVariation where !weightedNames.contains(varName) {
            weights.append((varName, 0))
        }
        x.variations = weights.sorted { $0.0 < $1.0 }.map { name, w in
            Variation(name: name, weight: w, parameters: paramsByVariation[name] ?? [:])
        }
        return x
    }

    private func parseAffine(_ s: String) -> AffineTransform? {
        let p = floats(s)
        guard p.count == 6 else { error = .invalidAttribute("coefs", value: s); return nil }
        guard p.allSatisfy({ $0.isFinite }) else { error = .degenerateTransform("non-finite coefs"); return nil }
        return AffineTransform(a: p[0], b: p[1], c: p[2], d: p[3], e: p[4], f: p[5])
    }

    private func floats(_ s: String) -> [Double] {
        s.split(whereSeparator: { $0.isWhitespace }).compactMap { Double($0) }
    }

    private func parseHex(_ rgb: String) -> SIMD3<Double> {
        var hex = rgb; if hex.hasPrefix("#") { hex.removeFirst() }
        guard let v = UInt32(hex, radix: 16) else { return .zero }
        let r = Double((v >> 16) & 0xff) / 255
        let g = Double((v >> 8) & 0xff) / 255
        let b = Double(v & 0xff) / 255
        return SIMD3(r, g, b)
    }

    /// flam3 `<color rgb="…"/>`. The real Electric Sheep form is a decimal
    /// 0–255 triple ("168 168 0"); some tooling/tests emit hex ("FF0000"). The
    /// discriminator is clean: a decimal triple has whitespace-separated tokens,
    /// hex is a single token. Accept both → [0,1] (matches `parseHex`'s scale).
    private func parseColorRGB(_ s: String) -> SIMD3<Double> {
        let p = floats(s)
        if p.count >= 3 {
            func n(_ x: Double) -> Double { min(max(x, 0), 255) / 255 }
            return SIMD3(n(p[0]), n(p[1]), n(p[2]))
        }
        return parseHex(s)   // hex fallback (single token, no spaces)
    }

    /// flam3 native: hex digits, 2 per channel, 3 channels per color (0-255).
    private func applyHexBlock(_ text: String) {
        let digits = text.unicodeScalars.filter { $0.value < 128 && Character($0).isHexDigit }.map { Character($0) }
        var chars = Array(String(digits))
        var idx = 0
        while chars.count >= 6 && idx < 256 {
            let pair = String(chars.prefix(6)); chars.removeFirst(6)
            paletteColors[idx] = parseHex(pair)
            idx += 1
        }
    }
}
