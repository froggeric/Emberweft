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
///
/// M6.7 adds the orientation-aware `.apply` sibling (portrait branch); `normalize` is unchanged.
public enum Framing {
    public static func normalize(flame: Flame, renderWidth: Int) -> Flame {
        guard flame.size.x > 0, flame.camera.scale > 0, flame.camera.scale.isFinite else {
            return flame
        }
        var out = flame
        out.camera.scale = flame.camera.scale * Double(renderWidth) / Double(flame.size.x)
        return out
    }

    /// Rotation applied when mapping a landscape-authored genome onto a
    /// portrait canvas: +90° turns content CLOCKWISE (y-down grid). Arbitrary
    /// for abstract flames — one named constant, flippable in one line if the
    /// A/B renders read better the other way (spec §3).
    public static let portraitRotationDegrees: Double = 90

    /// M6.7 orientation-aware framing (spec §3 of
    /// `docs/superpowers/specs/2026-08-25-m6.7-vertical-social-presets-design.md`).
    ///
    /// Rotation maps the genome's authored LONG axis onto the canvas long
    /// axis — it fires only on a mismatch (D3, ratified): a landscape-authored
    /// genome (`size.x > size.y`, i.e. all of ES) on a portrait canvas gains
    /// `+90°` (in faithful mode too — the preset's orientation semantic) and,
    /// when normalized, anchors its authored HEIGHT (`scale × canvasW / size.y`
    /// — the authored vertical axis becomes the canvas horizontal axis). A
    /// 1920×1080 genome on 1080×1920 is factor 1.0: pixel-exact sideways.
    ///
    /// Every other cell is the M6.6 code path, byte-identical by construction:
    /// non-portrait canvases and non-landscape-authored genomes never rotate
    /// (a portrait-authored genome is already composed vertically — rotating
    /// it would break the faithful↔animate byte identity and double-distort
    /// it under normalization; a square-authored one has identical anchors).
    ///
    /// PURE + deterministic (rule #2). `normalize` above stays untouched for
    /// the landscape-only preview/thumbnail sites.
    public static func apply(flame: Flame, renderWidth: Int, renderHeight: Int,
                             normalized: Bool) -> Flame {
        // Non-portrait canvas: exactly the M6.6 cells (normalize rescales with
        // its own degenerate guard; faithful is identity).
        guard renderHeight > renderWidth else {
            return normalized ? normalize(flame: flame, renderWidth: renderWidth) : flame
        }
        // Degenerate headers pass through ENTIRELY unchanged on a portrait
        // canvas (D10 — the guard wraps rotation too): unknown size, NaN or
        // non-positive scale (the gen-248 data-integrity class; black on both
        // backends regardless).
        guard flame.size.x > 0, flame.size.y > 0,
              flame.camera.scale > 0, flame.camera.scale.isFinite
        else { return flame }
        // Already composed vertically (portrait- or square-authored): the M6.6
        // width-anchor cell, no rotation.
        guard flame.size.x > flame.size.y else {
            return normalized ? normalize(flame: flame, renderWidth: renderWidth) : flame
        }
        var out = flame
        out.camera.rotation += portraitRotationDegrees
        if normalized {
            out.camera.scale = flame.camera.scale * Double(renderWidth) / Double(flame.size.y)
        }
        return out
    }
}
