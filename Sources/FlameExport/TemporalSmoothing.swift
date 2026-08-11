import Foundation

/// User-facing temporal-smoothing choice (M6.1 slice 2). `.auto` enables a
/// centered box window of uniform half-width `centeredHalfWidth` for every
/// `.spp` quality tier — free supersampling (√(2h+1) grain reduction at one
/// render/frame, since the window averages already-rendered neighbor frames);
/// `.off` forces the byte-identical unsmoothed path. Codable + Sendable; a
/// field on `ExportSettings`, so it rides in the checkpoint via `settings`.
///
/// RETUNED 2026-08-11: the window half-width `h` is now a UNIFORM constant
/// (`centeredHalfWidth = 5`, an 11-frame centered box) for all `.spp` tiers,
/// decoupled from spp. The earlier design derived `h = round(1/α)` from a
/// continuous α ramp, which clamped to OFF (h=0) at spp ≥ 64 — so the new High
/// tier (spp 100) would not have smoothed. α itself is now vestigial (flat 0.2,
/// see `alpha(for:)`); the centered window is the quality signal.
public enum TemporalSmoothing: String, Codable, Sendable, CaseIterable, Equatable {
    case auto, off

    /// Uniform centered-box-window half-width for every `.spp` quality tier
    /// (RETUNED 2026-08-11). An 11-frame centered window (2h+1 = 11): moderate
    /// motion blur + the max free-supersampling grain cut (√11 ≈ 3.3×).
    public static let centeredHalfWidth = 5

    /// Resolved weight α ∈ (0, 1] for a quality. `.off` or `.genome` ⇒ 1.0
    /// (OFF). Otherwise flat `0.2` for every `.spp` tier (RETUNED 2026-08-11:
    /// was the continuous `rampAlpha` ramp). α is now VESTIGIAL — the centered
    /// window uses `halfWidth(for:)` (= `centeredHalfWidth`), not α — but is
    /// kept so `ExportSettings.smoothingAlpha` stays consistent (`< 1.0` = ON)
    /// for the resume-warmup notice check at `ExportManager.swift:519`, and to
    /// avoid a Codable schema change.
    public func alpha(for quality: ExportQuality) -> Double {
        switch (self, quality) {
        case (.off, _), (_, .genome): return 1.0
        case (.auto, .spp):           return 0.2
        }
    }

    /// Centered-box-window half-width `h` for a quality. Returns the uniform
    /// `centeredHalfWidth` (5) for every `.spp` tier — decoupled from α/spp
    /// (RETUNED 2026-08-11; was `round(1/α)` from a ramp, which gave 10/5/3 for
    /// spp 2/8/30 and clamped to OFF (0) at spp ≥ 64). **0 for `.off`/`.genome`**
    /// is the single OFF signal the coordinator routes around (the existing
    /// byte-identical `renderImage` path).
    public func halfWidth(for quality: ExportQuality) -> Int {
        switch (self, quality) {
        case (.off, _), (_, .genome): return 0
        case (.auto, .spp):           return Self.centeredHalfWidth
        }
    }

    /// Canonical centered-box-window half-width from a resolved α. The SINGLE
    /// source of truth for the `α → h` mapping used by `ExportCoordinator`'s
    /// smoothing gate (which decodes `smoothingAlpha` from checkpoint JSON, so
    /// this guard defends against corrupt/hand-edited values). Returns **0**
    /// (OFF) when α is not in the open interval `(0, 1)`: `α ≥ 1.0` (OFF),
    /// `α ≤ 0`, or non-finite (NaN/Inf — defensively OFF rather than trapping
    /// on `Int(1/0)`/`Int(NaN)`). For `α ∈ (0,1)`: `h = max(0, round(1/α))`.
    /// Under the flat α=0.2 this yields h=5 (== `centeredHalfWidth`), so both
    /// `halfWidth(for:)` paths agree.
    public static func halfWidth(forAlpha alpha: Double) -> Int {
        if !alpha.isFinite || alpha >= 1.0 || alpha <= 0 { return 0 }
        return max(0, Int((1.0 / alpha).rounded()))
    }
}
