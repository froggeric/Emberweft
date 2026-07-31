import Foundation
import FlameKit

/// Defensive renderability check for genomes drawn from the wild Electric-Sheep
/// archive.
///
/// ~1.4% of gen-248 sheep carry literal `center="nan nan"` / `scale="nan"` headers
/// and always render solid black on BOTH backends (a data-integrity issue, not a
/// code bug — CLAUDE.md). The archive also holds degenerate `scale` values
/// (negative like `-259`, tiny `6e-05`, huge `5760`). The parser does NOT guard
/// the camera (it only rejects non-finite xform coefs via `.degenerateTransform`),
/// so the GUI layer applies this gate before any render or thumbnail.
public extension Flame {

    /// True iff this genome has a finite, in-band camera and at least one
    /// weighted xform — i.e. it will produce a non-empty image on a backend.
    var isRenderable: Bool {
        let c = camera.center
        guard c.x.isFinite, c.y.isFinite else { return false }
        let s = camera.scale
        guard s.isFinite, s > 0 else { return false }
        // Empirical in-band bounds from the gen-248 archive (CLAUDE.md gotcha).
        // Across ~9.5k finite gen-248 scales: p50≈289, p99≈1396, p999≈3092, max=5760
        // (the degenerate outlier). [1e-3, 4000] admits all real genomes, rejects
        // the huge/tiny/negative data-integrity cases.
        guard s >= 1e-3, s <= 4000 else { return false }
        guard xforms.contains(where: { $0.weight > 0 }) else { return false }
        return true
    }
}
