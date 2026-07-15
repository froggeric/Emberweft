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
    private var inPalette = false
    private var paletteColors: [SIMD3<Float>] = Array(repeating: .zero, count: 256)
    private var hexAccumulator = ""

    func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attr: [String: String]) {
        switch name {
        case "flame": flame = makeFlame(attr: attr)
        case "xform", "finalxform": xform = makeXform(attr: attr)
        case "var":
            if let n = attr["name"], let w = attr["weight"], xform != nil {
                xform!.variations.append(Variation(name: n, weight: Float(w) ?? 1))
            }
        case "palette":
            inPalette = true; hexAccumulator = ""
            // Reset per flame so entries from a sibling <flame> don't leak in.
            paletteColors = Array(repeating: .zero, count: 256)
        case "color":
            if inPalette, let idxStr = attr["index"], let rgb = attr["rgb"] {
                let idx = Int(idxStr) ?? 0
                if (0..<256).contains(idx) { paletteColors[idx] = parseHex(rgb) }
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
        case "finalxform":
            if let xf = xform { flame?.finalXform = xf }; xform = nil
        case "flame":
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
        f.camera.scale = attr["scale"].flatMap { Float($0) } ?? 250
        f.camera.zoom = attr["zoom"].flatMap { Float($0) } ?? 0
        f.camera.rotation = attr["rotate"].flatMap { Float($0) } ?? 0
        f.quality.oversample = attr["oversample"].flatMap { Int($0) } ?? 1
        f.quality.samplesPerPixel = attr["quality"].flatMap { Int($0) } ?? 100
        f.quality.gamma = attr["gamma"].flatMap { Float($0) } ?? 2.2
        f.quality.gammaThreshold = attr["gamma_threshold"].flatMap { Float($0) } ?? 0.01
        f.quality.vibrancy = attr["vibrancy"].flatMap { Float($0) } ?? 1.0
        f.quality.estimatorRadius = attr["estimator_radius"].flatMap { Float($0) } ?? 0
        f.quality.estimatorMinimum = attr["estimator_minimum"].flatMap { Float($0) } ?? 0
        f.quality.estimatorCurveRate = attr["estimator_curve"].flatMap { Float($0) } ?? 0.6
        f.hueShift = attr["hue"].flatMap { Float($0) } ?? 0
        f.time = attr["time"].flatMap { Double($0) } ?? 0
        return f
    }

    private func makeXform(attr: [String: String]) -> Xform {
        var x = Xform()
        x.weight = attr["weight"].flatMap { Float($0) } ?? 1
        x.color = attr["color"].flatMap { Float($0) } ?? 0
        // Prefer the explicit `color_speed` attribute (what we serialize); fall
        // back to legacy `symmetry` (flam3/Apophysis) for imported genomes.
        if let cs = attr["color_speed"].flatMap({ Float($0) }) { x.colorSpeed = cs }
        else if let sym = attr["symmetry"].flatMap({ Float($0) }) { x.colorSpeed = 1 - sym }
        else { x.colorSpeed = 0.5 }
        x.opacity = attr["opacity"].flatMap { Float($0) } ?? 1
        if let cf = attr["coefs"] { x.affine = parseAffine(cf) ?? .identity }
        if let pf = attr["post"] { x.postAffine = parseAffine(pf) ?? .identity }
        if let ch = attr["chaos"] { x.chaos = floats(ch) }
        // flam3/Apophysis convention: variation weights are xform ATTRIBUTES
        // (e.g. `<xform linear="1" sinusoidal="0.5" .../>`). This is the ONLY
        // form flam3-render reads, so the frozen golden genomes (Task 12) MUST
        // use it — a `<var>` child element is ignored by flam3 and yields a
        // blank render. Any attribute that is not a reserved keyword is a
        // variation weight. Sort by name so round-trip order is deterministic
        // regardless of XMLParser's dictionary iteration order.
        let reserved: Set<String> = [
            "weight", "color", "color_speed", "symmetry", "coefs", "post",
            "chaos", "opacity", "animate", "name",
        ]
        let attrVars = attr
            .filter { !reserved.contains($0.key) }
            .compactMap { (k, v) -> Variation? in Float(v).map { Variation(name: k, weight: $0) } }
            .sorted { $0.name < $1.name }
        x.variations = attrVars
        return x
    }

    private func parseAffine(_ s: String) -> AffineTransform? {
        let p = floats(s)
        guard p.count == 6 else { error = .invalidAttribute("coefs", value: s); return nil }
        guard p.allSatisfy({ $0.isFinite }) else { error = .degenerateTransform("non-finite coefs"); return nil }
        return AffineTransform(a: p[0], b: p[1], c: p[2], d: p[3], e: p[4], f: p[5])
    }

    private func floats(_ s: String) -> [Float] {
        s.split(whereSeparator: { $0.isWhitespace }).compactMap { Float($0) }
    }

    private func parseHex(_ rgb: String) -> SIMD3<Float> {
        var hex = rgb; if hex.hasPrefix("#") { hex.removeFirst() }
        guard let v = UInt32(hex, radix: 16) else { return .zero }
        let r = Float((v >> 16) & 0xff) / 255
        let g = Float((v >> 8) & 0xff) / 255
        let b = Float(v & 0xff) / 255
        return SIMD3(r, g, b)
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
