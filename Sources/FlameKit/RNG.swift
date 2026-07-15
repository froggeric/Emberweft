import Foundation

/// PCG32 — fast, statistically excellent, fully deterministic.
///
/// 32-bit output, 64-bit state. Same `(seed, stream)` always yields the
/// identical sequence, offline and realtime, independent of thread or
/// process. This is the foundation of Emberweft's mandatory determinism.
///
/// Reference: Melissa E. O'Neill, "PCG, A Family of Simple Fast Space-Efficient
/// Statistically Good Algorithms for Random Number Generation" (2014).
public struct PCG32: Sendable {
    public private(set) var state: UInt64
    public private(set) var inc: UInt64

    /// Seed the generator. `stream` selects one of 2^63 independent streams;
    /// it is shifted left and forced odd internally per the PCG spec.
    public init(seed: UInt64, stream: UInt64) {
        state = 0
        inc = (stream << 1) | 1   // must be odd
        _ = next()
        state = state &+ seed
        _ = next()
    }

    /// Advance the state and return the next 32-bit pseudo-random value.
    @discardableResult
    public mutating func next() -> UInt32 {
        let oldstate = state
        state = oldstate &* 6_364_136_223_846_793_005 &+ inc
        let xorshifted = UInt32(truncatingIfNeeded: ((oldstate >> 18) ^ oldstate) >> 27)
        let rot = UInt32(truncatingIfNeeded: oldstate >> 59)
        return (xorshifted >> rot) | (xorshifted << ((~rot &+ 1) & 31))
    }

    /// Uniform float in [0, 1) using the top 24 bits (24-bit mantissa).
    public mutating func nextFloat() -> Float {
        Float(next() >> 8) * (1.0 / 16_777_216.0)
    }

    /// Uniform index in `0..<n` (unbiased via rejection when `n` is not a
    /// power of two).
    public mutating func nextIndex(_ n: Int) -> Int {
        precondition(n > 0)
        let mask = UInt32(n - 1)
        if n & (n - 1) == 0 { return Int(next() & mask) }
        let limit = UInt32.max - (UInt32.max % UInt32(n))
        while true {
            let r = next()
            if r < limit {
                return Int(r % UInt32(n))
            }
        }
    }
}
