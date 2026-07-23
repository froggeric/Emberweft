// Tests/FlameReferenceTests/VariationFlam3ParityTests.swift
//
// Per-variation Emberweft-CPU-vs-flam3 parity harness. Renders a synthetic
// single-variation genome in BOTH backends with matched params and reports
// PSNR/SSIM. This is the test that was MISSING for CV1-CV5 (which validated
// Metal↔CPU only, via SpecialSauceParityTests) — the hole that let variation-
// integration bugs hide until real-genome parity exposed them.
//
// Two uses:
//   1. Work B diagnosis: probe the 6 suspect variations {waves, split, cross,
//      noise, gaussian_blur, flower}. Low PSNR ⇒ the variation (or its chaos-
//      game integration) diverges from flam3 ⇒ investigate there.
//   2. Work A validation: each newly-ported variation must clear the ≥38 dB
//      gate here (vs-flam3, not just Metal↔CPU) before it ships.
//
// The harness validates ITSELF on PROVEN controls (linear/spherical/julia) —
// if those don't clear ~40 dB the synthetic template is pathological and must
// be fixed before trusting any suspect number.
//
// F10 auto-skip when flam3-render is absent. Run with the bash sandbox DISABLED
// (the test Process-spawns flam3-render).

import XCTest
@testable import FlameReference
@testable import FlameKit

final class VariationFlam3ParityTests: XCTestCase {

    // Operating point: matches RealGenomeParityTests (400×296 @ 500 spp) so the
    // numbers are directly comparable to the real-genome gate. ~2 min/case in
    // debug; run in background or use `swift test -c release` for ~14× speedup.
    private static let width = 400
    private static let height = 296
    private static let quality = 500
    private static let libcSeed = "42"                 // flam3 aux RNG (env `seed`)
    private static let isaacSeed = "emberweftgoldens"  // matches ChaosGame.goldenIsaacSeed
    private static let gate: Float = 38.0

    /// 256-entry rainbow palette as decimal `<color rgb>` children (the real-ES
    /// form). flam3 needs a full palette; a smooth gradient keeps tone-mapping
    /// well-conditioned.
    private static func paletteXML() -> String {
        (0..<256).map { i in
            let r = Int(Double(i) / 255.0 * 255)
            let g = Int(Double((i + 85) % 256) / 255.0 * 255)
            let b = Int(Double((i + 170) % 256) / 255.0 * 255)
            return "  <color index=\"\(i)\" rgb=\"\(r) \(g) \(b)\"/>"
        }.joined(separator: "\n")
    }

    /// Synthetic 2-xform genome: xform0 = linear stabilizer pulling toward one
    /// corner; xform1 = contracting linear + the target variation pulling toward
    /// the opposite corner. The two opposing contractions yield a SPREAD
    /// attractor that exercises the variation (not a point-collapse). `xform1`
    /// carries the target variation attrs verbatim.
    private static func genome(xform1: String, name: String) -> String {
        """
        <flam3>
        <flame name="\(name)" size="\(width) \(height)" center="0 0" scale="150" rotate="0"
          oversample="1" supersample="1" filter="1" filter_shape="gaussian"
          quality="\(quality)" passes="1" temporal_samples="1" background="0 0 0"
          brightness="4" gamma="4" vibrancy="1" estimator_radius="0" estimator_minimum="0"
          highlight_power="-1" gamma_threshold="0.01">
        <xform weight="0.5" color="0.2" symmetry="0" linear="1" coefs="0.5 0 0 0.5 -0.4 0.4"/>
        <xform weight="0.5" color="0.8" symmetry="0" \(xform1)/>
        \(paletteXML())
        </flame>
        </flam3>
        """
    }

    /// Render `genome` in flam3 + Emberweft CPU at matched params; return
    /// (psnr, ssim, emberweftActive%). Throws on flam3 failure; XCTSkips on
    /// size mismatch.
    private func parity(xform1: String, name: String) throws -> (psnr: Float, ssim: Float, active: Double) {
        try Flam3Oracle.requireRender()
        let xml = Self.genome(xform1: xform1, name: name)

        // flam3 render.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("varparity_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let flam3PNG = tmp.appendingPathComponent("flam3.png").path
        try Flam3Oracle.renderStatic(
            genomeXML: xml, outPath: flam3PNG,
            seed: Self.libcSeed, isaacSeed: Self.isaacSeed, nthreads: 1)
        let flam3Img = try RGBA8Image.readPNG(from: URL(fileURLWithPath: flam3PNG))

        // Emberweft CPU render (the deterministic oracle-quality backend).
        let flame = try XCTUnwrap(
            try Flam3Parser.parse(Data(xml.utf8)).first,
            "parse failed for \(name)")
        let p = RenderParams(
            seed: UInt64(Self.libcSeed) ?? 42,
            width: flame.size.x, height: flame.size.y,
            oversample: 1, samplesPerPixel: Self.quality)
        let ours = ReferenceRenderer.render(flame: flame, params: p)

        guard ours.width == flam3Img.width && ours.height == flam3Img.height else {
            throw XCTSkip("size mismatch on \(name): emberweft=\(ours.width)x\(ours.height) flam3=\(flam3Img.width)x\(flam3Img.height)")
        }
        var active = 0
        for i in 0..<(ours.width * ours.height) {
            let b = i * 4
            let lum = (Int(ours.pixels[b]) + Int(ours.pixels[b+1]) + Int(ours.pixels[b+2])) / 3
            if lum > 8 { active += 1 }
        }
        let activePct = Double(active) / Double(ours.width * ours.height) * 100
        return (ImageComparison.psnr(ours, flam3Img), ImageComparison.ssim(ours, flam3Img), activePct)
    }

    /// Controls (proven correct) + Work-B suspects. The shared affine
    /// `0.5 0.18 -0.18 0.5 0.4 -0.4` keeps every xform1 contracting + mildly
    /// rotated, with nonzero c,d,e,f so coefficient-dependent variations
    /// (waves) are active.
    func testVariationFlam3Parity() throws {
        try Flam3Oracle.requireRender()
        let aff = "coefs=\"0.5 0.18 -0.18 0.5 0.4 -0.4\""
        let cases: [(String, String)] = [
            // --- controls (validate the harness; must clear ~40 dB) ---
            ("linear",    "linear=\"1\" \(aff)"),
            ("spherical", "linear=\"0.6\" spherical=\"0.5\" \(aff)"),
            ("julia",     "linear=\"0.6\" julia=\"0.5\" \(aff)"),
            // --- Work-B suspects (appear only in knownGap fixtures) ---
            ("waves",          "linear=\"0.6\" waves=\"0.5\" \(aff)"),
            ("cross",          "linear=\"0.6\" cross=\"0.5\" \(aff)"),
            ("split",          "linear=\"0.6\" split=\"0.5\" split_xsize=\"0.5\" split_ysize=\"0.5\" \(aff)"),
            ("noise",          "linear=\"0.6\" noise=\"0.5\" \(aff)"),
            ("gaussian_blur",  "linear=\"0.6\" gaussian_blur=\"0.5\" \(aff)"),
            ("flower",         "linear=\"0.6\" flower=\"0.5\" flower_holes=\"0.3\" flower_petals=\"3\" \(aff)"),
            // --- Work A batch 1: trig family (var82–var95), paramless. Each MUST
            // clear the ≥38 dB gate (enforced below), not diagnostic. ---
            ("exp",  "linear=\"0.6\" exp=\"0.5\" \(aff)"),
            ("log",  "linear=\"0.6\" log=\"0.5\" \(aff)"),
            ("sin",  "linear=\"0.6\" sin=\"0.5\" \(aff)"),
            ("cos",  "linear=\"0.6\" cos=\"0.5\" \(aff)"),
            ("tan",  "linear=\"0.6\" tan=\"0.5\" \(aff)"),
            ("sec",  "linear=\"0.6\" sec=\"0.5\" \(aff)"),
            ("csc",  "linear=\"0.6\" csc=\"0.5\" \(aff)"),
            ("cot",  "linear=\"0.6\" cot=\"0.5\" \(aff)"),
            ("sinh", "linear=\"0.6\" sinh=\"0.5\" \(aff)"),
            ("cosh", "linear=\"0.6\" cosh=\"0.5\" \(aff)"),
            ("tanh", "linear=\"0.6\" tanh=\"0.5\" \(aff)"),
            ("sech", "linear=\"0.6\" sech=\"0.5\" \(aff)"),
            ("csch", "linear=\"0.6\" csch=\"0.5\" \(aff)"),
            ("coth", "linear=\"0.6\" coth=\"0.5\" \(aff)"),
            // --- Work A batch 2: paramless non-trig (var57/61/62/64/66/70/72).
            // Each MUST clear the ≥38 dB gate (enforced below), not diagnostic. ---
            ("butterfly", "linear=\"0.6\" butterfly=\"0.5\" \(aff)"),
            ("edisc",     "linear=\"0.6\" edisc=\"0.5\" \(aff)"),
            ("elliptic",  "linear=\"0.6\" elliptic=\"0.5\" \(aff)"),
            ("foci",      "linear=\"0.6\" foci=\"0.5\" \(aff)"),
            ("loonie",    "linear=\"0.6\" loonie=\"0.5\" \(aff)"),
            ("polar2",    "linear=\"0.6\" polar2=\"0.5\" \(aff)"),
            ("scry",      "linear=\"0.6\" scry=\"0.5\" \(aff)"),
            // --- large/non-contracting affine probe (242.00099's waves-xform
            // coefs). If linear_LRG diverges but small-affine linear passed,
            // the trigger is large-affine iteration handling (badvalue
            // recovery), NOT any variation. ---
            ("linear_LRG", "linear=\"1\" coefs=\"-0.499835 0.936973 1.05709 -0.02298 0.427067 -2.0474\""),
            ("waves_LRG",  "linear=\"0.6\" waves=\"0.5\" coefs=\"-0.499835 0.936973 1.05709 -0.02298 0.427067 -2.0474\""),
        ]

        var report: [String] = []
        var controlFailures: [String] = []
        var results: [String: Float] = [:]
        for (label, xform1) in cases {
            let r = try parity(xform1: xform1, name: label)
            results[label] = r.psnr
            let psnrStr = r.psnr.isInfinite ? "inf" : String(format: "%.2f", r.psnr)
            let isControl = ["linear", "spherical", "julia"].contains(label)
            let tag = isControl ? "[CONTROL]" : (r.psnr >= Self.gate ? "[ok]" : "[DIVERGES]")
            report.append("[VarParity] \(label.padding(toLength: 14, withPad: " ", startingAt: 0)) "
                + "PSNR=\(psnrStr) dB  SSIM=\(String(format: "%.4f", r.ssim))  "
                + "active=\(String(format: "%5.1f", r.active))%  \(tag)")
            if isControl && r.psnr < 40 { controlFailures.append("\(label): \(psnrStr) dB") }
        }
        // Print the full report (captured in test output).
        for line in report { print(line) }
        // Sanity gate: if a CONTROL fails, the synthetic template is broken and
        // no suspect number can be trusted.
        if !controlFailures.isEmpty {
            XCTFail("Harness self-check failed — a PROVEN control diverged, so the "
                + "synthetic template is pathological; fix it before trusting suspect "
                + "results:\n  " + controlFailures.joined(separator: "\n  "))
        }
        // No assertion on suspects — this run is diagnostic.
        //
        // Work A enforcement: each newly-ported variation MUST clear the ≥38 dB
        // gate vs flam3 (not diagnostic — a real faithfulness gate). Controls
        // already enforce ≥40 above; the Work B suspects stay diagnostic.
        let workA: Set<String> = [
            "exp", "log", "sin", "cos", "tan", "sec", "csc", "cot",
            "sinh", "cosh", "tanh", "sech", "csch", "coth",
            // Work A batch 2: paramless non-trig.
            "butterfly", "edisc", "elliptic", "foci", "loonie", "polar2", "scry",
        ]
        var gateFailures: [String] = []
        for label in cases.map({ $0.0 }) where workA.contains(label) {
            let p = results[label] ?? -1
            if p < Self.gate {
                gateFailures.append("\(label): \(p.isInfinite ? "inf" : String(format: "%.2f", p)) dB < \(Self.gate)")
            }
        }
        if !gateFailures.isEmpty {
            XCTFail("Work A variation failed the vs-flam3 ≥\(Int(Self.gate)) dB gate "
                + "(formula/affine/RNG-order divergence from flam3):\n  "
                + gateFailures.joined(separator: "\n  "))
        }
    }
}
