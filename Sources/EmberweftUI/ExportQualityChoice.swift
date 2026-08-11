import Foundation
import FlameExport
import FlameKit

/// User-facing export-quality choice for the GUI sheet (spec §4.5 / G4 / G5).
///
/// Bridges the dormant `AppPreferences.QualityPreset` to `ExportQuality`,
/// pinning `oversample == 1` for EVERY case (engine spec D6 — export byte-identity
/// with `animate` requires oversample 1, even for `.high` whose preview-side
/// `QualityPreset` uses oversample 2).
///
/// - `.genomeDefault` maps to `.genome` (byte-identical to `emberweft animate`).
/// - `.low/.medium/.high` map to `.spp(8/30/100)` (RETUNED 2026-08-11; was
///   2/8/30). These are now EXPORT-SPECIFIC tiers, decoupled from the preview-
///   side `AppPreferences.QualityPreset.samplesPerPixel` (still 2/8/30): the
///   empirical grain+perf sweep found clean output needs effective spp ~330+
///   (Standard), which temporal smoothing supplies as free supersampling
///   (`smoothingLabel`).
public enum ExportQualityChoice: String, Sendable, CaseIterable, Hashable {
    case genomeDefault
    case low
    case medium
    case high

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

    /// Seed the default sheet choice from the dormant prefs field (the sheet's
    /// Quality picker defaults from `prefs.qualityPreset`). There is no
    /// `.genomeDefault` preset, so callers wanting genome-default must set it
    /// explicitly (the sheet offers it as the first, recommended option).
    public static func defaultChoice(from preset: AppPreferences.QualityPreset) -> ExportQualityChoice {
        switch preset {
        case .low:    return .low
        case .medium: return .medium
        case .high:   return .high
        }
    }
}
