import XCTest
@testable import FlameRenderer
import FlameKit

final class MSLIsaacParityTests: XCTestCase {
    func testMSLMatchesSwiftAcrossSeeds() throws {
        try MainActor.assumeIsolated {
            guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
            let seeds = ["emberweftgoldens", "", "a", "0123456789abcdef",
                         "x", "longer-seed-string-for-padding-test-1234567890"]
            for s in seeds {
                let seed16 = Self.seed(from: s)
                var swift = ISAAC(randrsl: seed16)
                let swiftStream = (0..<1024).map { _ in swift.next() }
                let mslStream = try ISAACBridge.stream(seed16: seed16, count: 1024)
                XCTAssertEqual(swiftStream, mslStream, "MSL ISAAC diverged from Swift for seed \(s)")
            }
        }
    }

    // Mirror ISAAC.parseSeedBytes: 128-byte LE buffer of the UTF-8 bytes.
    private static func seed(from str: String) -> [UInt64] {
        var bytes = [UInt8](repeating: 0, count: 128)
        let src = Array(str.utf8)
        for i in 0..<min(src.count, 128) { bytes[i] = src[i] }
        var words = [UInt64](repeating: 0, count: 16)
        for w in 0..<16 {
            var v: UInt64 = 0
            for b in 0..<8 { v |= UInt64(bytes[w*8 + b]) << (b*8) }
            words[w] = v
        }
        return words
    }
}
