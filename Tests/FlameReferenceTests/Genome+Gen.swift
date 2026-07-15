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
            let s = 0.3 + Double(rng.nextFloat()) * 0.4      // scale in [0.3, 0.7] -> contractive
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
            let vars = picked.map { Variation(name: names[$0], weight: Double(rng.nextFloat())) }
            // Diagonal-dominant contractive affine under the flam3 convention
            // (matrix | a c e | / | b d f |): a and d are the diagonal scales (= s),
            // b,c are small off-diagonals, e,f are translations. Draw into locals so
            // the RNG sequence is order-independent and stays deterministic.
            let offB = Double(rng.nextFloat())*0.2 - 0.1
            let offC = Double(rng.nextFloat())*0.2 - 0.1
            let tx = Double(rng.nextFloat()) - 0.5
            let ty = Double(rng.nextFloat()) - 0.5
            return Xform(affine: AffineTransform(a: s, b: offB, c: offC, d: s, e: tx, f: ty),
                  color: Double(rng.nextFloat()), colorSpeed: 0.5,
                  variations: vars)
        }
        let palette = Palette(colors: (0..<256).map { _ in
            SIMD3<Double>(Double(rng.nextFloat()), Double(rng.nextFloat()), Double(rng.nextFloat()))
        })
        return Flame(name: "gen", size: SIMD2(16, 16), camera: Camera(scale: 64),
                     xforms: xforms, palette: palette)
    }
}
