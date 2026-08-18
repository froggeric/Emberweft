// Sources/FlameKit/Framing.swift
import Foundation

/// M6.6 resolution-independent framing (spec
/// `docs/superpowers/specs/2026-08-17-m6.6-framing-normalization-design.md`).
///
/// A `.flam3` genome's `camera.scale` is ABSOLUTE pixels-per-unit, authored for
/// the genome's `size` canvas. The renderers use it verbatim (no output-size
/// normalization), so the fractal occupies the same PIXEL count at every output
/// resolution — the resolution picker doubles as a 3× zoom (720p "zoomed in",
/// 4K "zoomed out"). The gen-248 data shows the ES authoring anchor is WIDTH
/// (scale/width agrees to 2% across the 800×592 / 1280×720 / 1920×1080
/// populations; scale/height differs 34%), and a multiplicative correction is
/// the perceptually correct (Weber-Fechner, log-space) fix.
///
/// PURE + deterministic (rule #2): scalar arithmetic only. The identity case
/// (`renderWidth == size.x`) returns an equal genome, so callers whose render
/// width already matches the authored canvas are byte-identical to faithful
/// rendering. Degenerate inputs (unknown `size.x`, NaN/non-positive `scale` —
/// the gen-248 data-integrity class) are returned UNCHANGED; `isRenderable`
/// filters most of them upstream anyway.
public enum Framing {
    public static func normalize(flame: Flame, renderWidth: Int) -> Flame {
        guard flame.size.x > 0, flame.camera.scale > 0, flame.camera.scale.isFinite else {
            return flame
        }
        var out = flame
        out.camera.scale = flame.camera.scale * Double(renderWidth) / Double(flame.size.x)
        return out
    }
}
