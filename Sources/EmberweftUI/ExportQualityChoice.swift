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
/// - `.low/.medium/.high` map to `.spp(2/8/30)` (same spp values as
///   `AppPreferences.QualityPreset.samplesPerPixel`).
public enum ExportQualityChoice: String, Sendable, CaseIterable, Hashable {
    case genomeDefault
    case low
    case medium
    case high

    /// The `ExportQuality` consumed by `ExportSettings.resolve(…)`.
    public var exportQuality: ExportQuality {
        switch self {
        case .genomeDefault: return .genome
        case .low:           return .spp(2)
        case .medium:        return .spp(8)
        case .high:          return .spp(30)   // oversample pinned 1 by ExportQuality
        }
    }

    /// M6.1 slice 2 / Task 10: resolved-α read-only label for the export sheet.
    /// Computes `TemporalSmoothing.auto.alpha(for: exportQuality)` (the value the
    /// sheet shows as a hint when smoothing is ON at this quality tier) and
    /// formats it as e.g. "α = 0.20, ≈5-frame blend". At `.genomeDefault` (or any
    /// tier where α ≥ 1.0) smoothing is a no-op, so this returns "off".
    ///
    /// The "≈N-frame blend" is `1/α` rounded (the EMA's effective window: α = 0.20
    /// ⇒ ~5-frame blend). The label reflects the `.auto` (ON) α; the `.off` toggle
    /// position is surfaced separately by the sheet (the toggle itself).
    public var smoothingAlphaLabel: String {
        let alpha = TemporalSmoothing.auto.alpha(for: exportQuality)
        if alpha >= 1.0 {
            return "off"
        }
        let frames = Int((1.0 / alpha).rounded())
        return String(format: "α = %.2f, ≈%d-frame blend", alpha, frames)
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
