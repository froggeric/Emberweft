// Tests/FlameReferenceTests/Flam3OracleSmoke.swift
//
// Smoke test for the flam3 parity-oracle harness. Confirms:
//   1. F10 auto-skip fires cleanly when the oracle is absent.
//   2. When present, a one-frame render of a frozen genome — with motion blur
//      DISABLED (passes=1 temporal_samples=1, F6) — produces a non-empty PNG
//      (>1 KB). This is the load-bearing check that the env-var invocation and
//      the motion-blur-off injection are correct: any regression in the
//      attribute injection (e.g. temporal_samples still 1000) would still
//      render a PNG, so this gate is on plumbing, not parity.
//
// Run with the bash sandbox DISABLED — the test Process-spawns flam3-animate,
// which may be denied fork/exec under a sandbox.

import XCTest
@testable import FlameReference
import FlameKit

final class Flam3OracleSmoke: XCTestCase {

    func testOracleAvailabilityReporting() throws {
        // isAvailable must agree with `require`'s skip behaviour. This never
        // fails: it either confirms availability or records the F10 skip.
        if Flam3Oracle.isAvailable {
            XCTAssertNoThrow(try Flam3Oracle.require())
        } else {
            XCTAssertThrowsError(try Flam3Oracle.require()) { error in
                // Must be an XCTSkip, not a hard failure — that is the F10 contract.
                guard error is XCTSkip else {
                    XCTFail("require() must throw XCTSkip when absent, got: \(error)")
                    return
                }
            }
        }
    }

    func testMotionBlurOffInjection() {
        // The F6 injection is pure string math — testable without the oracle.
        let genome = """
        <?xml version="1.0"?>
        <flames>
        <flame name="a" size="320 200">
        <xform weight="1" coefs="1 0 0 1 0 0" linear="1"/>
        </flame>
        <flame name="b" size="320 200">
        <xform weight="1" coefs="1 0 0 1 0 0" linear="1"/>
        </flame>
        </flames>
        """
        let injected = Flam3Oracle.injectMotionBlurOff(genome)
        // Both <flame> (not <flames>) opening tags get the two attributes...
        XCTAssertEqual(injected.components(separatedBy: "passes=\"1\" temporal_samples=\"1\"").count - 1, 2,
                       "both control points must carry the motion-blur-off attrs")
        // ...and the root <flames> element must NOT be touched.
        XCTAssertFalse(injected.contains("<flames passes=\"1\""))
    }

    func testOneFrameRenderProducesNonEmptyPNG() throws {
        // F10 auto-skip — the gate contract.
        try Flam3Oracle.require()

        // Frozen genome with an embedded palette (so the missing
        // /usr/local/share/flam3/flam3-palettes.xml warning is cosmetic).
        let genomeURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Goldens/genomes/heart_disc.flam3")
        let genome = try String(contentsOf: genomeURL, encoding: .utf8)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("flam3_oracle_smoke_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let prefix = tmp.appendingPathComponent("out.").path  // -> out.00000.png
        let pngs = try Flam3Oracle.renderFrames(
            genome: genome,
            begin: 0,
            end: 0,            // single still frame
            prefix: prefix)

        XCTAssertFalse(pngs.isEmpty, "flam3-animate wrote no PNGs")
        for png in pngs {
            let size = (try FileManager.default.attributesOfItem(atPath: png.path)[.size] as? Int) ?? 0
            XCTAssertGreaterThan(size, 1024,
                "oracle PNG \(png.lastPathComponent) is only \(size) bytes (<=1 KB); "
                + "expected a real render. Check the motion-blur-off injection (F6) "
                + "and that the genome has an embedded palette.")
            print("[Flam3OracleSmoke] \(png.lastPathComponent): \(size) bytes")
        }
    }
}
