// Tests/FlameReferenceTests/Genome+Gen.swift
// Test-only helper. Lives in the test target so it never ships in FlameKit.
import Foundation
import FlameKit

enum GenomeGen {
    /// Generates a small, deterministic, well-formed flame.
    /// Affines are kept modest (diagonal-dominant) so the chaos game is
    /// contractive and the safety cap never trips. Variation names within an
    /// xform are DISTINCT so serialization never emits duplicate XML attributes
    /// (which would also trap the order-insensitive comparison in the test).
    static func make(rng: inout PCG32) -> Flame {
        let names = Array(Variations.knownNames).sorted()
        let nx = Int(rng.nextIndex(3)) + 1
        let xforms = (0..<nx).map { _ in
            let s = 0.3 + rng.nextFloat() * 0.4      // scale in [0.3, 0.7] -> contractive
            // pick 1-2 DISTINCT variation names (duplicate names would serialize
            // as duplicate XML attributes and trap the comparison helper). Draw
            // indices directly from the RNG; PCG32 is not a Swift
            // RandomNumberGenerator so shuffled(using:) cannot be used here.
            let k = Int(rng.nextIndex(2)) + 1        // 1 or 2
            var picked: [Int] = []
            while picked.count < k {
                let idx = rng.nextIndex(names.count)
                if !picked.contains(idx) { picked.append(idx) }
            }
            let vars = picked.map { Variation(name: names[$0], weight: rng.nextFloat()) }
            return Xform(affine: AffineTransform(a: s, b: rng.nextFloat()*0.2 - 0.1,
                                          c: rng.nextFloat() - 0.5, d: rng.nextFloat()*0.2 - 0.1,
                                          e: s, f: rng.nextFloat() - 0.5),
                  color: rng.nextFloat(), colorSpeed: 0.5,
                  variations: vars)
        }
        let palette = Palette(colors: (0..<256).map { _ in
            SIMD3<Float>(rng.nextFloat(), rng.nextFloat(), rng.nextFloat())
        })
        return Flame(name: "gen", size: SIMD2(16, 16), camera: Camera(scale: 64),
                     xforms: xforms, palette: palette)
    }
}
