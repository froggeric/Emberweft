import Testing
import Foundation
@testable import FlameKit

/// Byte-exact parity tests for the Swift ISAAC port against flam3's ISAAC
/// (isaac.c / isaac.h / isaacs.h), captured via the C harness
/// `~/flam3-oracle-src/isaac_check`.
///
/// These streams are the foundation of julia / noise / blur / fan variation
/// parity; they MUST be byte-exact.
@Suite("ISAAC RNG parity (flam3)")
struct ISAACTests {

    // MARK: - "emberweftgoldens" seed (the golden-regen seed)

    /// First 64 irand() outputs from `isaac_check "emberweftgoldens" 64`.
    /// Captured from flam3's isaac.c compiled on macOS LP64 (ub4 = unsigned
    /// long = 8 bytes, RANDSIZ=16, RANDSIZL=4).
    static let emberweftGoldens: [UInt32] = [
        2104938556, 141617964, 2171984326, 554036049,
        90353297, 2307306157, 360054563, 3595815713,
        2728451567, 2097735981, 2949388653, 3245310352,
        2449790726, 3298581635, 3990951425, 3905406747,
        2444515116, 1296933756, 3271119329, 751628489,
        1830733073, 3533309555, 1415676886, 2234282414,
        1940174694, 1940690239, 647324199, 3349651519,
        1692769897, 4152695062, 4111417679, 3118200621,
        2352615763, 3570604903, 3439135474, 3887508234,
        1427079089, 77064996, 3610880450, 1524887975,
        1448688793, 3836997041, 302114020, 113832696,
        751041512, 2080127659, 675883388, 270816221,
        3655036317, 1519741055, 280051382, 510352887,
        4012477878, 1740243263, 1051367366, 459895198,
        2996707316, 1936033257, 1383074454, 1255802800,
        4231621683, 4018240748, 974416360, 457423749,
    ]

    @Test("ISAAC stream matches flam3 for isaac_seed='emberweftgoldens'")
    func emberweftGoldensStream() {
        var rng = ISAAC(isaacSeed: "emberweftgoldens")
        for (i, expected) in Self.emberweftGoldens.enumerated() {
            let got = rng.next()
            #expect(got == expected, "output[\(i)]: got \(got), expected \(expected)")
        }
    }

    // MARK: - empty-string seed

    /// `isaac_check "" 16`
    static let emptySeed: [UInt32] = [
        2452851915, 1340468986, 3346877890, 3366115673,
        61449112, 1440946401, 2756852084, 2590902875,
        2470738293, 4046114694, 451422264, 2321663415,
        1600675869, 2404596021, 2400344141, 3305951656,
    ]

    @Test("ISAAC stream matches flam3 for empty-string seed")
    func emptySeedStream() {
        var rng = ISAAC(isaacSeed: "")
        for (i, expected) in Self.emptySeed.enumerated() {
            #expect(rng.next() == expected, "output[\(i)] mismatch")
        }
    }

    // MARK: - short seed

    /// `isaac_check "abc" 16`
    static let abcSeed: [UInt32] = [
        299511230, 2843102378, 1714401400, 2906366244,
        1516264830, 1777995226, 1917148691, 3129429815,
        1757092365, 1895449622, 3599275331, 1510405828,
        627922724, 1883430190, 3927826725, 1287895041,
    ]

    @Test("ISAAC stream matches flam3 for isaac_seed='abc'")
    func abcSeedStream() {
        var rng = ISAAC(isaacSeed: "abc")
        for (i, expected) in Self.abcSeed.enumerated() {
            #expect(rng.next() == expected, "output[\(i)] mismatch")
        }
    }

    // MARK: - determinism

    @Test("Same seed produces identical streams; different seeds differ")
    func determinism() {
        var a = ISAAC(isaacSeed: "emberweftgoldens")
        var b = ISAAC(isaacSeed: "emberweftgoldens")
        for _ in 0..<32 {
            #expect(a.next() == b.next())
        }

        // A different seed should produce a different first value.
        var c = ISAAC(isaacSeed: "different-seed")
        #expect(c.next() != a.next())
    }
}
