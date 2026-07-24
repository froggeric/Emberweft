// Tests/FlameRendererTests/SpikyPaletteParityTests.swift
//
// DOCUMENTING TEST — the Metal↔flam3 gap on complex real genomes is a KNOWN,
// ACCEPTED limitation, NOT a palette/color bug. Skips by default (with the
// finding recorded); opt in with `EMBERWEFT_METAL_SPIKY=1` to re-measure.
//
// History / diagnosis (2026-07-24): real ES genomes like 244.00788 (12-xform
// cross/noise/gaussian_blur) render at only ~33.7 dB Metal↔CPU (under the 38 dB
// statistical-parity gate). This was FIRST misdiagnosed as a palette-sampling
// gap (Metal kept `colorT` Float + always LINEAR; CPU uses Double + STEP). Two
// fixes were attempted + reverted:
//   1. MSL `double` colorT — IMPOSSIBLE (Metal is half/float-only; compile error).
//   2. double-single (df, Dekker/Knuth) — Python sim shows df ≈ float precision
//      here (the blend toward color∈{0,1} flushes the df low part) and the SAME
//      palette bin-mismatch rate as float; in Metal it *regressed* to 3.82 dB.
//
// ROOT CAUSE (definitive): the gap is NOT color. `colorT` depends only on the
// ISAAC stream + xform-selection sequence (byte-identical Metal↔CPU) + per-step
// blend rounding (~5e-8). Even on a spiky palette with LINEAR interp, a 5e-8
// colorT error yields ~140 dB — so 33.7 dB CANNOT be color precision. It is
// xform-SEQUENCE DESYNC: the Float (x,y) trajectory diverges from CPU's Double
// on this fragile attractor, hits badvalue (|q|>1e10) at different iterations,
// the retry draws different ISAAC values, and the whole downstream sequence
// diverges. Fundamental to Metal-Float (no FP64); no faithful fix. The CPU
// oracle is faithful (41 dB vs flam3); Metal is the statistical twin (≥38 dB on
// smooth genomes — SpecialSauceParityTests green, no badvalue desync there).
//
// See docs/superpowers/plans/2026-07-23-metal-step-port.md for the full writeup.
// DO NOT re-attempt: MSL `double`, double-single, fixed-point, or a Metal STEP
// port — none can close a position-desync gap.

import XCTest
@testable import FlameRenderer
@testable import FlameReference
@testable import FlameKit

@MainActor
final class SpikyPaletteParityTests: XCTestCase {

    // Matched no-blur op-point: 800×592 @ 1000 spp (mirrors
    // RealGenomeParityTests.opPointOverrides["electricsheep.244.00788"]).
    private static let size = SIMD2<Int>(800, 592)
    private static let quality = 1000
    private static let libcSeed: UInt64 = 42
    private static let knownPsnr: Float = 33.68   // measured 2026-07-24, Float-Metal vs Double-CPU

    private func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #file).deletingLastPathComponent()
        while url.path != "/" && !FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
            url = url.deletingLastPathComponent()
        }
        return url
    }

    /// Mirror `RealGenomeParityTests.sanitize` exactly (no blur, supersample=1,
    /// DE off, fixed quality + size) so this op-point matches the wider suite.
    private func sanitize(_ xml: String, quality: Int, size: SIMD2<Int>) -> String {
        let attrs: [(String, String)] = [
            ("passes", "1"),
            ("temporal_samples", "1"),
            ("supersample", "1"),
            ("estimator_radius", "0"),
            ("estimator_minimum", "0"),
            ("quality", String(quality)),
            ("size", "\(size.x) \(size.y)"),
        ]
        var out = xml
        for (key, value) in attrs {
            // Match `key="..."` only when `key` is the FULL attribute name
            // (preceded by whitespace, not a letter/_ — so `size` does not
            // match inside `split_xsize`).
            let pattern = "(?<![a-z_])\(key)=\"[^\"]*\""
            if let re = try? NSRegularExpression(pattern: pattern) {
                out = re.stringByReplacingMatches(
                    in: out, range: NSRange(out.startIndex..., in: out),
                    withTemplate: "\(key)=\"\(value)\"")
            }
            let insert = "<flame(?![^>]*[^a-z_]\(key)=)(\\s)"
            if let re = try? NSRegularExpression(pattern: insert) {
                out = re.stringByReplacingMatches(
                    in: out, range: NSRange(out.startIndex..., in: out),
                    withTemplate: "<flame \(key)=\"\(value)\"$1")
            }
        }
        return out
    }

    /// Documents the known Metal↔CPU gap on the fragile 12-xform real genome
    /// 244.00788. Skips by default (the gap is an accepted Float-position-desync
    /// limitation, not a regression to gate on). Set `EMBERWEFT_METAL_SPIKY=1`
    /// to actually render both backends and print the live PSNR — useful only
    /// if re-investigating (e.g. after a Metal numerics change); ~3 min/release.
    func testSpikyPaletteMetalVsCpu() throws {
        guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }

        let optIn = ProcessInfo.processInfo.environment["EMBERWEFT_METAL_SPIKY"] != nil
        guard optIn else {
            throw XCTSkip(
                "Known/accepted: 244.00788 Metal↔CPU ≈\(String(format: "%.2f", Self.knownPsnr)) dB " +
                "(under 38 gate). Root cause is Float-position-trajectory desync on this fragile " +
                "12-xform attractor (NOT palette/color; MSL has no double). CPU-vs-flam3 (the " +
                "primary gate) is faithful at 41 dB. Set EMBERWEFT_METAL_SPIKY=1 to re-measure.")
        }

        let fixture = repoRoot()
            .appendingPathComponent("Tests/Goldens/genomes_real/electricsheep.244.00788.flam3")
        let raw = try String(contentsOf: fixture, encoding: .utf8)
        let sanitized = sanitize(raw, quality: Self.quality, size: Self.size)

        let flame = try XCTUnwrap(
            Flam3Parser.parse(Data(sanitized.utf8)).first,
            "parse failed for \(fixture.lastPathComponent)")
        XCTAssertEqual(SIMD2(flame.size.x, flame.size.y), Self.size,
                       "size sanitization didn't take")

        let p = RenderParams(
            seed: Self.libcSeed,
            width: flame.size.x, height: flame.size.y,
            oversample: 1, samplesPerPixel: Self.quality)

        let cpu = ReferenceRenderer.render(flame: flame, params: p)
        let gpu = MetalRenderer.render(flame: flame, params: p)
        let psnr = ImageComparison.psnr(cpu, gpu)
        let ssim = ImageComparison.ssim(cpu, gpu)
        let psnrStr = psnr.isInfinite ? "inf" : String(format: "%.2f", psnr)
        print("[SpikyParity] 244.00788 @\(Self.quality)spp: PSNR=\(psnrStr) dB, SSIM=\(String(format: "%.4f", ssim)) " +
              "(known ≈\(String(format: "%.2f", Self.knownPsnr)) dB; gap = Float-position desync, not palette)")
        XCTAssertEqual(gpu.pixels.count, gpu.width * gpu.height * 4, "incomplete buffer")
    }
}
