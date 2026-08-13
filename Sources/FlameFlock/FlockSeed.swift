// Sources/FlameFlock/FlockSeed.swift
import Foundation
import CryptoKit

/// Deterministic per-artifact seed (spec §10). SHA-256 over the canonical UTF-8
/// string, first 8 bytes little-endian ⇒ UInt64. Pure string→Int hash (no Swift
/// Dict/Set iteration ⇒ rule-#2-safe). Same artifact + same RenderSpec ⇒ identical
/// bytes, run-to-run and machine-to-machine. Threaded into RenderParams.seed and
/// ThreadSeedBudget(baseSeed:), matching the export invariant.
public enum FlockSeed {
    /// `canonical` = "shard|aGen|aId|bGen|bId" (caller builds in that fixed order).
    public static func sha256ToUInt64(canonical: String) -> UInt64 {
        let digest = SHA256.hash(data: Data(canonical.utf8))
        let bytes = Array(digest)             // 32 bytes
        // First 8 bytes, little-endian.
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(bytes[i]) << (8 * i) }
        return v
    }
    /// Convenience: build the canonical string and hash in one call.
    public static func seed(shard: String, aGen: String, aId: String,
                            bGen: String, bId: String) -> UInt64 {
        sha256ToUInt64(canonical: "\(shard)|\(aGen)|\(aId)|\(bGen)|\(bId)")
    }
}
