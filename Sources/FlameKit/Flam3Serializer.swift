import Foundation

/// Serializes `[Flame]` genomes back to canonical `.flam3` XML.
///
/// The output is stable: attributes are emitted in a fixed order and
/// coefficients are formatted to 6 decimals, so
/// `parse(serialize(parse(x))) == parse(x)` holds for any genome whose
/// fields survive the parser's default-filling normalization.
public enum Flam3Serializer {
    public static func serialize(_ flames: [Flame]) -> String {
        var s = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<flames>\n"
        for f in flames { s += flameString(f) }
        s += "</flames>\n"
        return s
    }

    private static func flameString(_ f: Flame) -> String {
        var a = "  <flame"
        a += " name=\"\(escape(f.name))\""
        a += " version=\"3.0\""
        a += " size=\"\(f.size.x) \(f.size.y)\""
        a += " center=\"\(f6(f.camera.center.x)) \(f6(f.camera.center.y))\""
        a += " scale=\"\(f6(f.camera.scale))\""
        a += " zoom=\"\(f6(f.camera.zoom))\""
        a += " rotate=\"\(f6(f.camera.rotation))\""
        a += " oversample=\"\(f.quality.oversample)\""
        a += " quality=\"\(f.quality.samplesPerPixel)\""
        a += " gamma=\"\(f6(f.quality.gamma))\""
        a += " gamma_threshold=\"\(f6(f.quality.gammaThreshold))\""
        a += " vibrancy=\"\(f6(f.quality.vibrancy))\""
        a += " hue=\"\(f6(f.hueShift))\""
        a += " time=\"\(f.time)\""
        if f.quality.estimatorRadius > 0 {
            a += " estimator_radius=\"\(f6(f.quality.estimatorRadius))\""
            a += " estimator_minimum=\"\(f6(f.quality.estimatorMinimum))\""
            a += " estimator_curve=\"\(f6(f.quality.estimatorCurveRate))\""
        }
        a += ">\n"
        for x in f.xforms { a += xformString(x, tag: "xform") }
        if let fin = f.finalXform { a += xformString(fin, tag: "finalxform") }
        a += paletteString(f.palette)
        a += "  </flame>\n"
        return a
    }

    private static func xformString(_ x: Xform, tag: String) -> String {
        // flam3 form: variation weights are xform ATTRIBUTES (e.g. linear="1"),
        // NOT <var> children — flam3-render ignores <var> children and would
        // render a blank image, breaking the golden oracle. Emitted sorted by
        // name so parse(serialize(x)) round-trips with deterministic ordering.
        var a = "    <\(tag)"
        a += " weight=\"\(f6(x.weight))\""
        a += " color=\"\(f6(x.color))\""
        a += " color_speed=\"\(f6(x.colorSpeed))\""
        a += " coefs=\"\(af(x.affine))\""
        if x.postAffine != .identity { a += " post=\"\(af(x.postAffine))\"" }
        if let chaos = x.chaos { a += " chaos=\"\(chaos.map(f6).joined(separator: " "))\"" }
        if x.opacity != 1 { a += " opacity=\"\(f6(x.opacity))\"" }
        for v in x.variations.sorted(by: { $0.name < $1.name }) where v.weight != 0 {
            a += " \(v.name)=\"\(f6(v.weight))\""
        }
        a += "/>\n"
        return a
    }

    private static func paletteString(_ p: Palette) -> String {
        var s = "    <palette>\n"
        for (i, c) in p.colors.enumerated() where c != .zero {
            let hex = String(format: "%02X%02X%02X", Int(c.x*255), Int(c.y*255), Int(c.z*255))
            s += "      <color index=\"\(i)\" rgb=\"\(hex)\"/>\n"
        }
        s += "    </palette>\n"
        return s
    }

    private static func af(_ t: AffineTransform) -> String {
        "\(f6(t.a)) \(f6(t.b)) \(f6(t.c)) \(f6(t.d)) \(f6(t.e)) \(f6(t.f))"
    }

    private static func f6(_ x: Float) -> String { String(format: "%.6f", x) }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
