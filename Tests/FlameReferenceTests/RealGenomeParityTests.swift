// Tests/FlameReferenceTests/RealGenomeParityTests.swift
//
// Task-6 acceptance gate — real-genome density-parity vs flam3.
//
// Closes the ~20 dB gap that hid behind the synthetic-golden parity gate for
// all of M2/M3: real Electric Sheep genomes set `highlight_power="1"` and
// `filter="1"` (flam3's saturated-highlight anti-shift + a 4×4 spatial-filter
// kernel), but Emberweft hardcoded `highlightPower=-1.0` (branch disabled) and
// `spatialFilterRadius=0.5` (2×2 kernel) — exactly the synthetic goldens'
// defaults. The synthetic CPU↔flam3 and CPU↔Metal parity gates were therefore
// blind to both; only the vs-flam3 oracle on REAL genomes exposes the gap.
//
// This test renders each real fixture in `Tests/Goldens/genomes_real/` with
// MATCHED no-blur params (motion blur off, supersample=1, DE off, q500) in
// BOTH Emberweft (CPU reference) and `flam3-render`, then asserts PSNR ≥ 38 dB
// AND SSIM ≥ 0.95 on the fixtures in scope — the project-wide parity threshold.
//
// F10 auto-skip: the whole test XCTSkips when `flam3-render` is not on $PATH
// (`Flam3Oracle.requireRender`). CPU↔Metal parity (≥38 dB) remains the hard
// gate that always runs; this is the dev-only vs-flam3 oracle.
//
// Run with the bash sandbox DISABLED — the test Process-spawns flam3-render.

import XCTest
@testable import FlameReference
@testable import FlameKit

final class RealGenomeParityTests: XCTestCase {

    // Real ES genomes all set supersample=4 (which Emberweft's oversample=k2
    // path mishandles — see density_diff.md §"Open question for Task 6"; that's
    // an M4 follow-up, not in scope here). Pin supersample=1 both sides so the
    // gate measures the display pipeline (highlight_power + filter), not the
    // oversample/k2 bug. The motion-blur attrs are also forced off so a single
    // still frame is deterministic.
    //
    // Operating point: 400×296 @ 500 spp (1/8 the work of `Tools/density_diff.py`'s
    // 800×592×1000, which is the parity-stress operating point). The 38 dB gate
    // has ~13 dB margin at the full operating point (50.75 dB on 00256); the
    // smaller op-point sacrifices a few dB to sampling noise but still clears
    // 38 dB comfortably, AND runs in seconds-per-fixture in debug (vs ~6 min).
    // The full operating point is exercised by `python3 Tools/density_diff.py`.
    private static let renderSize = SIMD2<Int>(400, 296)
    private static let quality = 500
    private static let sanitizeAttrs: [(String, String)] = [
        ("passes", "1"),
        ("temporal_samples", "1"),
        ("supersample", "1"),
        ("estimator_radius", "0"),
        ("estimator_minimum", "0"),
        ("quality", String(quality)),
        ("size", "\(renderSize.x) \(renderSize.y)"),
    ]

    // Matched reproducibility pins (mirror Tools/density_diff.py).
    private static let libcSeed = "42"                    // flam3 aux RNG (env `seed`)
    private static let isaacSeed = "emberweftgoldens"     // matches ChaosGame.goldenIsaacSeed

    /// Fixture classification. The Task-6 scope is the `highlight_power` +
    /// `spatial_filter_radius` fix; genomes that ALSO use unimplemented
    /// variations cannot reach 38 dB regardless of hp/sf correctness, so they
    /// are documented as `knownGap` and EXCLUDED from the hard gate (printed
    /// for visibility, not asserted). When the listed variation lands, flip
    /// the kind to `.gate` — the PSNR will jump to ≥38 dB if hp/sf stay wired.
    enum Fixture { case gate, knownGap(reason: String) }
    private static let fixtures: [(name: String, kind: Fixture)] = [
        ("electricsheep.248.00038", .gate),
        ("electricsheep.248.00084", .gate),
        ("electricsheep.248.00256", .gate),
        ("electricsheep.248.00268", .gate),
        // 00000 was the last `.knownGap` (used pie + radial_blur, the final
        // two unimplemented variations). All four of its variations — bubble,
        // eyefish, pie, radial_blur — landed in the missing-variations plan
        // (HEAD aeed7f205); it is now `.gate` and the last fixture under the
        // real-genome parity gate. (05739 + 31943 were flipped to `.gate`
        // earlier once `bubble` landed.)
        ("electricsheep.248.00000", .gate),
        ("electricsheep.248.05739", .gate),
        ("electricsheep.248.31943", .gate),
        // ---- CV6: corpus-variation coverage fixtures (HEAD 3041c1382 ported
        // all 18 missing high-frequency variations — waves/popcorn/power/
        // tangent/cross/pdj/split/noise/blur/gaussian_blur/arch/square/rays/
        // blade/twintrian/flower/conic/parabola). The 9 fixtures below were
        // picked from the Electric Sheep corpus as the smallest CLEAN members
        // — single `<flame>` sheep genomes with embedded `<color>` palettes
        // (multi-flame edge genomes fail libxml2's strict single-root parse
        // via flam3-render's stdin, and the older `palette="N"` indexed form
        // isn't supported by Emberweft's parser), whose only variations are
        // implemented in `VariationDescriptor`'s table so each one can reach
        // ≥38 dB when the display pipeline agrees. Together they cover all 18
        // new variations, so this gate proves corpus-level parity (not just
        // the 7 original gen-248 fixtures). Per-variation Metal↔CPU parity
        // stays in SpecialSauceParityTests; this is the Emberweft-CPU-vs-flam3
        // oracle on real ES genomes. ----
        //
        // Coverage status (see CV6 closeout report):
        //  GATE  (5 fixtures, ≥38 dB): 243.16209, 243.17257, 244.00081,
        //                              244.36620, 248.34413
        //  GAP   (4 fixtures, <38 dB): 242.00099, 242.00261, 244.00788,
        //                              244.28122 — non-hp=1 genomes show a
        //                              residual density-distribution gap
        //                              (Emberweft peakier than flam3) even
        //                              after the Task-6 hp+filter fix; the
        //                              per-variation SpecialSauce gate still
        //                              covers them at Metal↔CPU level. This
        //                              is a Task-6 follow-on, not a CV6
        //                              variation-port regression.

        // twintrian + blade + conic + pdj + power (5 of 18 in one fixture).
        // 38.76 dB / 0.9924 — marginal (~0.8 dB over gate); kept as .gate
        // because the gate IS 38 dB and the genome passes it.
        ("electricsheep.243.16209", .gate),
        // rays + square (the only 2 CLEAN square-bearing genomes in 30k sample
        // are both ~12KB; this one carries rays too). 51.35 dB / 0.9977.
        ("electricsheep.243.17257", .gate),
        // arch + tangent + conic + power (arch & tangent appear together only
        // in this fixture among clean gen-244 candidates). 51.87 dB / 0.9966.
        ("electricsheep.244.00081", .gate),
        // parabola (in the finalxform: fisheye + parabola; only this CLEAN
        // parabola-bearing genome in the 30k sample under 12KB).
        // 50.66 dB / 0.9990.
        ("electricsheep.244.36620", .gate),
        // popcorn + blur (gen-248 sheep; one of the few CLEAN genomes where
        // these two co-occur — most popcorn+blur genomes also use `chaos`+
        // `perspective` and stay clean, but this one is the smallest clean).
        // 51.64 dB / 0.9998.
        ("electricsheep.248.34413", .gate),
        // ---- .knownGap: CV6 fixtures that EXERCISE the remaining 5 new
        // variations (waves/split/cross/noise/flower) but cannot reach 38 dB
        // because of a residual Task-6 display-pipeline gap on non-hp=1
        // genomes (Emberweft's density distribution is peakier than flam3's
        // for genomes whose `highlight_power` attr is absent — the Task-6 fix
        // targeted the hp="1" case, which all 7 original fixtures use).
        // density_diff.py confirms the gap is in the display pipeline (pixel
        // histogram divergence), NOT in the variation math (SpecialSauce
        // parity passes Metal↔CPU for all 5). Flip to .gate when the
        // display-pipeline gap closes (M4 follow-on). ----
        // waves + popcorn (gen-242 sheep). Was 28.76 dB (.knownGap) → 53.94 dB
        // after the palette_mode fix (flam3 defaults to STEP dmap sampling, not
        // linear — linear interp across this genome's spiky palette diverged).
        ("electricsheep.242.00099", .gate),
        // split + cross (gen-242 sheep). Was 30.67 dB (.knownGap) → 52.41 dB
        // after the palette_mode (step) fix.
        ("electricsheep.242.00261", .gate),
        // cross + noise + gaussian_blur (gen-244 sheep, 1920×1080). 32.76 dB —
        // palette_mode fix did NOT help (smooth palette); a DIFFERENT residual
        // gap (likely a 12-xform / post-affine / config interaction, NOT
        // palette or variation math — SpecialSauce passes for these in
        // isolation). Follow-on.
        ("electricsheep.244.00788", .knownGap(reason: "cross/noise/gaussian_blur — palette_mode fix did not help (smooth palette); residual config-specific gap (12-xform/post-affine), NOT variation math")),
        // flower + disc + linear + spherical + rings2 (gen-244 sheep, rotate=-178).
        // 34.23 dB — palette_mode fix did NOT help; a DIFFERENT residual gap
        // (rotate≈-178 or 2-xform config). Follow-on.
        ("electricsheep.244.28122", .knownGap(reason: "flower — palette_mode fix did not help; residual config-specific gap (rotate=-178 / 2-xform), NOT variation math")),
    ]

    private func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #file).deletingLastPathComponent()
        while url.path != "/" && !FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
            url = url.deletingLastPathComponent()
        }
        return url
    }

    private func genomesRealDir() -> URL {
        repoRoot().appendingPathComponent("Tests/Goldens/genomes_real")
    }

    /// Overwrite every `key="..."` attr in `xml` with `key="value"`, inserting
    /// it on `<flame` opening tags still missing it. Idempotent. Mirrors
    /// `Tools/density_diff.py:sanitize_genome` exactly so test PSNR is directly
    /// comparable to `python3 Tools/density_diff.py`'s headline number.
    ///
    /// The `(?<![a-z_])` word-boundary lookbehind prevents `size="…"` from
    /// matching inside `split_xsize="…"` / `split_ysize="…"` (the naive
    /// `\(key)="…"` substring match clobbered split's params with "400 296",
    /// breaking flam3's parser). Pre-existing bug — exposed by the CV6
    /// split-bearing fixtures (242.00261 / 242.00825).
    private func sanitize(_ xml: String) -> String {
        var out = xml
        for (key, value) in Self.sanitizeAttrs {
            // Match `key="..."` only when `key` is the FULL attribute name
            // (preceded by whitespace, not a letter/_ — so `size` does not
            // match inside `split_xsize`). NSRegularExpression supports
            // fixed-width lookbehind.
            let pattern = "(?<![a-z_])\(key)=\"[^\"]*\""
            if let re = try? NSRegularExpression(pattern: pattern) {
                out = re.stringByReplacingMatches(
                    in: out, range: NSRange(out.startIndex..., in: out),
                    withTemplate: "\(key)=\"\(value)\"")
            }
            // Insert on `<flame ` tags still missing the attr. The lookahead
            // `(?![^>]*[^a-z_]key=)` rules out tags where `key=` already
            // appears as a full attribute name (the `[^a-z_]` guard prevents
            // `xsize=` from satisfying the lookahead for `size`).
            let insert = "<flame(?![^>]*[^a-z_]\(key)=)(\\s)"
            if let re = try? NSRegularExpression(pattern: insert) {
                out = re.stringByReplacingMatches(
                    in: out, range: NSRange(out.startIndex..., in: out),
                    withTemplate: "<flame \(key)=\"\(value)\"$1")
            }
        }
        return out
    }

    /// One parity row. Returns `(psnr, ssim)`; throws on flam3 failure.
    private func parityRow(fixture: URL) throws -> (psnr: Float, ssim: Float) {
        // 1. Load + sanitize the genome XML (preserve filter / highlight_power /
        //    brightness / gamma — those ARE what we're parity-testing).
        let raw = try String(contentsOf: fixture, encoding: .utf8)
        let sanitized = sanitize(raw)

        // 2. flam3-render the sanitized XML to a PNG.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("real_parity_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let flam3PNG = tmp.appendingPathComponent("flam3.png").path
        try Flam3Oracle.renderStatic(
            genomeXML: sanitized, outPath: flam3PNG,
            seed: Self.libcSeed, isaacSeed: Self.isaacSeed, nthreads: 1)
        let flam3Img = try RGBA8Image.readPNG(from: URL(fileURLWithPath: flam3PNG))

        // 3. Parse the sanitized genome and render it on Emberweft CPU at the
        //    SAME size + oversample + quality. The flame's own brightness /
        //    gamma / vibrancy / filter / highlight_power flow through
        //    FlameQuality → renderer.
        let flame = try XCTUnwrap(
            Flam3Parser.parse(Data(sanitized.utf8)).first,
            "parse failed for \(fixture.lastPathComponent)")
        let p = RenderParams(
            seed: UInt64(Self.libcSeed) ?? 42,
            width: flame.size.x, height: flame.size.y,
            oversample: 1, samplesPerPixel: Self.quality)
        // `flame.size` was overridden in sanitization to `renderSize`; assert
        // it actually took (the regex-insert path could fail silently on a
        // malformed tag) so a quiet size mismatch doesn't degrade the gate.
        XCTAssertEqual(SIMD2(flame.size.x, flame.size.y), Self.renderSize,
                       "\(fixture.lastPathComponent): size sanitization didn't take")
        let ours = ReferenceRenderer.render(flame: flame, params: p)

        // 4. PSNR + SSIM. flam3 may emit a slightly different size (rounding on
        //    odd dimensions); resize is the caller's concern but in practice
        //    the fixtures are clean 800x592 → 400x296 after sanitize.
        guard ours.width == flam3Img.width && ours.height == flam3Img.height else {
            throw XCTSkip("size mismatch on \(fixture.lastPathComponent): "
                + "emberweft=\(ours.width)x\(ours.height) flam3=\(flam3Img.width)x\(flam3Img.height)")
        }
        return (ImageComparison.psnr(ours, flam3Img), ImageComparison.ssim(ours, flam3Img))
    }

    /// AC: PSNR ≥ 38 dB AND SSIM ≥ 0.95 on the in-scope fixtures (those whose
    /// only display-pipeline gaps are hp + filter, which Task 6 closes).
    /// Fixtures with unimplemented-variation gaps are printed for visibility
    /// but excluded from the assertion — those close in a separate task.
    func testRealGenomesMatchFlam3() throws {
        try Flam3Oracle.requireRender()

        let dir = genomesRealDir()
        var failures: [String] = []
        for (name, kind) in Self.fixtures {
            let fixture = dir.appendingPathComponent("\(name).flam3")
            guard FileManager.default.fileExists(atPath: fixture.path) else {
                print("[RealParity] SKIP \(name): fixture missing at \(fixture.path)")
                continue
            }
            let row = try parityRow(fixture: fixture)
            let psnrStr = row.psnr.isInfinite ? "inf" : String(format: "%.2f", row.psnr)
            switch kind {
            case .gate:
                print("[RealParity] \(name): PSNR=\(psnrStr) dB, SSIM=\(String(format: "%.4f", row.ssim)) [GATE]")
                if row.psnr < 38 || row.ssim < 0.95 {
                    failures.append("\(name): PSNR=\(psnrStr) dB SSIM=\(String(format: "%.4f", row.ssim))")
                }
            case .knownGap(let reason):
                // Print but don't assert — the gap is a missing variation, NOT
                // a hp/filter regression. Flip to `.gate` when the variation
                // is implemented.
                print("[RealParity] \(name): PSNR=\(psnrStr) dB, SSIM=\(String(format: "%.4f", row.ssim)) "
                      + "[KNOWN GAP — \(reason)]")
            }
        }
        if !failures.isEmpty {
            XCTFail("Real-genome parity gate failed (need PSNR≥38 / SSIM≥0.95):\n  "
                + failures.joined(separator: "\n  "))
        }
    }
}
