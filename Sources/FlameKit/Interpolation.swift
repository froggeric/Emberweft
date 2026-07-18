import Foundation

/// Legacy entry point for two-keyframe genome interpolation.
///
/// This thin shim delegates to `GenomeInterpolator.interpolate(..., type: .linear)`
/// so that every existing M1/M2 call site stays byte-identical with the previous
/// implementation. The full engine — including the `.log` polar matrix path
/// ported from flam3 `interpolation.c` — lives in `GenomeInterpolator`.
public enum Interpolation {
    /// Interpolate two keyframe genomes at parameter `t ∈ [0,1]` (`.linear` mode).
    public static func interpolate(_ a: Flame, _ b: Flame, at t: Double) -> Flame {
        GenomeInterpolator.interpolate(a, b, t: t, type: .linear)
    }
}
