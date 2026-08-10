import Foundation

/// User-facing temporal-smoothing choice (M6.1 slice 2). `.auto` derives α from
/// the export quality (the continuous ramp); `.off` forces α = 1.0 (byte-
/// identical to the unsmoothed path). Codable + Sendable; a field on
/// `ExportSettings`, so it rides in the checkpoint via `settings`.
public enum TemporalSmoothing: String, Codable, Sendable, CaseIterable, Equatable {
    case auto, off

    /// Resolved EMA weight α ∈ (0, 1] for a quality. `.off` or `.genome` ⇒ 1.0
    /// (OFF). Otherwise the continuous ramp (owner choice 2026-08-09).
    public func alpha(for quality: ExportQuality) -> Double {
        switch (self, quality) {
        case (.off, _), (_, .genome): return 1.0
        case (.auto, .spp(let n)):    return Self.rampAlpha(spp: n)
        }
    }

    /// Centered-box-window half-width `h` for a quality (REVISED 2026-08-10:
    /// replaces the causal EMA). `h = round(1/α)`, but **0 when smoothing is OFF**
    /// (`α ≥ 1.0`), so `h == 0` is the single OFF signal T8′ routes around (the
    /// existing byte-identical `renderImage`). Thus `.off`/`.genome` → 0;
    /// `.spp(2)` → 10; `.spp(8)` → 5; `.spp(30)` → 3; `.spp(≥64)` → 0 (the ramp
    /// clamps α to 1.0 at spp ≥ 64, i.e. OFF).
    public func halfWidth(for quality: ExportQuality) -> Int {
        let a = alpha(for: quality)
        if a >= 1.0 { return 0 }
        return max(0, Int((1.0 / a).rounded()))
    }

    /// Continuous log-linear ramp through anchors `(spp, α) = (2,0.10),
    /// (8,0.20), (30,0.35), (64,1.0)`, clamped to `[0.10, 1.0]`. Monotone,
    /// deterministic (rule #2). The anchors match the GUI named tiers exactly
    /// (Low/Med/High at spp 2/8/30), so GUI and CLI agree there; smoothing
    /// ramps to OFF (1.0) by spp=64.
    public static func rampAlpha(spp n: Int) -> Double {
        let anchors: [(spp: Int, alpha: Double)] = [(2, 0.10), (8, 0.20), (30, 0.35), (64, 1.0)]
        if n <= 2 { return 0.10 }
        if n >= 64 { return 1.0 }
        for i in 0..<(anchors.count - 1) {
            let (s1, a1) = anchors[i]
            let (s2, a2) = anchors[i + 1]
            if n <= s2 {
                let t = (log2(Double(n)) - log2(Double(s1))) / (log2(Double(s2)) - log2(Double(s1)))
                return a1 + (a2 - a1) * t
            }
        }
        return 1.0   // unreachable: n >= 64 handled above
    }
}
