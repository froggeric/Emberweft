import XCTest
@testable import FlameRenderer
@testable import FlameReference
import FlameKit
import CryptoKit

/// Task 5 gate: proves the GPUXform layout widening (19→33 canonical slots +
/// per-slot param channel) is ADDITIVE — M2 parity stays green and the 6 frozen
/// genomes render byte-identically to the pre-change baseline captured in
/// `Tests/Goldens/m2_baseline_hashes.json`. The frozen genomes use none of the
/// 14 new names, so `varParams` is all-zero and unread → output unchanged.
final class ParamChannelParityTests: XCTestCase {

    @MainActor
    func testCanonicalOrderGrewTo33NoDupes() throws {
        XCTAssertEqual(Variations.canonicalOrder.count, 99)
        XCTAssertEqual(Set(Variations.canonicalOrder).count, 99, "duplicate canonical name")
        XCTAssertEqual(Variations.canonicalOrder.filter { $0 == "spherical" }.count, 1)
        XCTAssertEqual(Variations.canonicalOrder.filter { $0 == "polar" }.count, 1)
        for name in ["blob", "curl", "super_shape", "ngon", "julian", "juliascope",
                     "wedge_julia", "wedge_sph", "perspective", "fan2", "rings2", "rectangles"] {
            XCTAssertNotNil(Variations.canonicalOrder.firstIndex(of: name), name)
        }
        XCTAssertNotNil(Variations.canonicalOrder.firstIndex(of: "rings"))
        XCTAssertNotNil(Variations.canonicalOrder.firstIndex(of: "fan"))
    }

    @MainActor
    func testBytesPerXform() throws {
        XCTAssertEqual(GPUXform.floatsPerXform, 906)
        XCTAssertEqual(GPUXform.bytesPerXform, 3624)
        // Lock the layout relationship so numSlots and floatsPerXform can't
        // silently desync (the constants are derived on the host, but this
        // guards against a future hand-edit that breaks the derivation).
        XCTAssertEqual(GPUXform.headerFloats + GPUXform.numSlots + GPUXform.numSlots * GPUXform.slotWidth,
                       GPUXform.floatsPerXform)
        XCTAssertEqual(GPUXform.numSlots, VariationDescriptor.canonicalOrder.count)
    }

    /// The additivity oracle: post-change Metal output must hash identically to
    /// the pre-change capture for every frozen genome. A mismatch means the
    /// layout widening was NOT additive (struct/pack stride drift, field-order
    /// change, or the kernel reading a shifted offset).
    @MainActor
    func testFrozenGenomesByteIdenticalToBaseline() throws {
        guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Goldens/genomes")
        let urls = (try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))
            .filter { $0.pathExtension == "flam3" }
        let baselinesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Goldens/m2_baseline_hashes.json")
        let baselines = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: baselinesURL))
        for url in urls {
            let name = url.deletingPathExtension().lastPathComponent
            let flame = try Flam3Parser.parse(Data(contentsOf: url))[0]
            // Match EndToEndParityTests exactly (seed/width/height/oversample/spp).
            let p = RenderParams(seed: 0, width: 320, height: 200,
                                 oversample: 1, samplesPerPixel: 1000)
            let gpu = MetalRenderer.render(flame: flame, params: p)
            let hash = SHA256.hash(data: Data(gpu.pixels))
            let hex = hash.map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(hex, baselines[name] ?? "",
                           "\(name): Metal output drifted from pre-Task-5 baseline")
        }
    }
}
