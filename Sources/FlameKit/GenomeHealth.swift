import Foundation

/// Defensive renderability check for genomes drawn from the wild Electric-Sheep
/// archive (~1.4% of gen-248 sheep carry literal NaN camera headers; the archive
/// also holds degenerate scale values). The parser does NOT guard the camera, so
/// callers apply this gate before any render. Lives in FlameKit so the CLI,
/// FlameExport, and the GUI all share one definition.
public extension Flame {
    var isRenderable: Bool {
        let c = camera.center
        guard c.x.isFinite, c.y.isFinite else { return false }
        let s = camera.scale
        guard s.isFinite, s > 0 else { return false }
        guard s >= 1e-3, s <= 4000 else { return false }
        guard xforms.contains(where: { $0.weight > 0 }) else { return false }
        return true
    }
}
