import Foundation
import FlameExport
import FlameKit

/// User-facing export-quality choice for the GUI sheet (spec §4.5 / G4 / G5)
/// and the Settings default that seeds it (`AppPreferences.exportQuality`).
/// Pins `oversample == 1` for EVERY case (engine spec D6 — export byte-identity
/// with `animate` requires oversample 1, even for `.high`).
///
/// - `.genomeDefault` maps to `.genome` (byte-identical to `emberweft animate`).
/// - `.low/.medium/.high` map to `.spp(8/30/100)` (RETUNED 2026-08-11; was
///   2/8/30). These are EXPORT-SPECIFIC tiers: the empirical grain+perf sweep
///   found clean output needs effective spp ~330+ (Standard), which temporal
///   smoothing supplies as free supersampling (`smoothingLabel`).
public enum ExportQualityChoice: String, Sendable, CaseIterable, Hashable {
    case genomeDefault
    case low
    case medium
    case high

    /// Human label shared by the export sheet's picker and Settings' default
    /// picker (one source so the two never disagree).
    public var displayName: String {
        switch self {
        case .genomeDefault: "Genome default"
        case .low:           "Low"
        case .medium:        "Medium"
        case .high:          "High"
        }
    }

    /// The `ExportQuality` consumed by `ExportSettings.resolve(…)`.
    public var exportQuality: ExportQuality {
        switch self {
        case .genomeDefault: return .genome
        case .low:           return .spp(8)
        case .medium:        return .spp(30)
        case .high:          return .spp(100)   // oversample pinned 1 by ExportQuality
        }
    }

    /// v0.5.5: the temporal-samples this tier auto-selects when picked in the
    /// sheet (data-derived: motion blur that's free at the tier's spp). The user
    /// can override the stepper after. `ExportSettings.resolve` treats ts=1 as
    /// "use genome default" ONLY for genome-default quality (v0.5.4 gate); for the
    /// named tiers ts is literal, so these values are the actual sub-pass counts.
    public var recommendedTemporalSamples: Int {
        switch self {
        case .genomeDefault: return 1   // = "use genome default" sentinel (mastering path)
        case .low:           return 1   // Draft: single-pass (ts=4 is +12% at spp 8)
        case .medium:        return 4   // Standard: free mild blur at spp 30
        case .high:          return 16  // High: free moderate blur at spp 100
        }
    }

    /// Effective-spp label for the export sheet (the meaningful quality signal
    /// after smoothing). For `.spp(n)` tiers the centered box window of
    /// half-width `TemporalSmoothing.centeredHalfWidth` is FREE supersampling —
    /// each emitted frame is the average of `2h+1` rendered neighbor frames — so
    /// the effective spp is `n × (2h + 1)` (= `n × 11`), formatted e.g.
    /// `"smoothed, ≈330 spp"`. At `.genomeDefault` smoothing is a no-op, so this
    /// returns `"off"`. RETUNED 2026-08-11 (was an α framing,
    /// `smoothingAlphaLabel`).
    public var smoothingLabel: String {
        switch exportQuality {
        case .genome:
            return "off"
        case .spp(let n):
            let eff = n * (2 * TemporalSmoothing.centeredHalfWidth + 1)
            return "smoothed, ≈\(eff) spp"
        }
    }
}
