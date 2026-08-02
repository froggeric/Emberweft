import Foundation

/// Perceptual band for the live-FPS readout, anchored to the user's **target**
/// FPS (not absolute) — human framerate sensitivity is relative (Weber-Fechner),
/// so a user who chose 30 and sustains 30 should read "fluid", not "caution".
/// One absolute floor: `red` below 24 fps, the cinematic-motion threshold under
/// which a morph reads as a slideshow rather than continuous motion. Below that
/// the realtime preview's lack of motion blur can't mask the judder.
///
/// `idle` covers paused / loading / no-measurement so the readout shows an em
/// dash instead of a misleading "0 fps". Pure + testable (no SwiftUI here).
public enum PreviewFPSBand: Sendable, Equatable {
    case idle
    case green   // ≥ 0.9·target — at/near target, fluid
    case amber   // 0.5·target ..< 0.9·target — visible judder, playable
    case red     // < max(24, 0.5·target) — slideshow / severe judder

    public static func band(measuredFPS: Double, targetFPS: Double, isPlaying: Bool) -> PreviewFPSBand {
        guard isPlaying, measuredFPS.isFinite, measuredFPS > 0, targetFPS > 0 else { return .idle }
        if measuredFPS >= 0.9 * targetFPS { return .green }
        if measuredFPS < max(24.0, 0.5 * targetFPS) { return .red }
        return .amber
    }

    /// One-word VoiceOver verdict so the band is legible without the color.
    public var accessibilityVerdict: String {
        switch self {
        case .idle: return "Measuring"
        case .green: return "at target"
        case .amber: return "below target"
        case .red: return "well below target"
        }
    }
}
