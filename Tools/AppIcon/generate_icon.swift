#!/usr/bin/env swift
//
//  generate_icon.swift — Emberweft app icon generator.
//
//  Deterministic (seeded SplitMix64; no wall-clock, no Dictionary/Set iteration
//  order in any accumulation), pure CoreGraphics + CoreText, no AppKit windows.
//  Renders the icon concepts, the master, and the size contact sheet.
//
//  Usage:
//    swift Tools/AppIcon/generate_icon.swift --concept ring --out master.png [--size 1024]
//    swift Tools/AppIcon/generate_icon.swift --contact master-1024.png --out contact-sheet.png
//    swift Tools/AppIcon/generate_icon.swift --alternates --out alternates.png
//
//  Ring-concept knobs (for variants):
//    --radius 280 --amp 52 --width 26 --strands 5 --lobes 7
//    --heat-angle 45 (degrees, hottest arc) --glow 1.0 (multiplier) --seed 7
//
//  All drawing happens in a 1024x1024 user space (y-up), supersampled 2x,
//  then box-halved down to the requested size.

import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

// MARK: - Deterministic RNG (SplitMix64)

struct SeededRNG {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func range(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * unit() }
}

// MARK: - Color helpers

typealias RGB = (r: Double, g: Double, b: Double)

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func cgcol(_ c: RGB, _ a: Double = 1.0) -> CGColor {
    CGColor(colorSpace: sRGB, components: [CGFloat(c.r), CGFloat(c.g), CGFloat(c.b), CGFloat(a)])!
}

func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
    (r: a.r + (b.r - a.r) * t, g: a.g + (b.g - a.g) * t, b: a.b + (b.b - a.b) * t)
}

/// Ember ramp: 0 = deep maroon coal, 1 = pale-gold white-hot.
/// Top end deliberately stops short of white so the hot arc keeps thread detail.
let emberStops: [(Double, RGB)] = [
    (0.00, (r: 0.46, g: 0.11, b: 0.09)),
    (0.26, (r: 0.64, g: 0.16, b: 0.08)),
    (0.50, (r: 0.88, g: 0.34, b: 0.09)),
    (0.70, (r: 0.99, g: 0.54, b: 0.13)),
    (0.87, (r: 1.00, g: 0.70, b: 0.26)),
    (1.00, (r: 1.00, g: 0.83, b: 0.48)),
]

func ember(_ h0: Double) -> RGB {
    let h = min(max(h0, 0), 1)
    for k in 0..<(emberStops.count - 1) {
        let (t0, c0) = emberStops[k]
        let (t1, c1) = emberStops[k + 1]
        if h <= t1 { return mix(c0, c1, (h - t0) / (t1 - t0)) }
    }
    return emberStops.last!.1
}

func lighten(_ c: RGB, _ t: Double) -> RGB { mix(c, (r: 1.0, g: 0.95, b: 0.80), t) }
func darken(_ c: RGB, _ t: Double) -> RGB { mix(c, (r: 0.24, g: 0.07, b: 0.06), t) }

// MARK: - Geometry helpers

func P(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }

/// Full-bleed superellipse squircle (Apple-ish continuous corner), |x/a|^n + |y/b|^n = 1.
func squircle(_ size: Double, n: Double = 5.0) -> CGPath {
    let c = size / 2, a = size / 2
    var pts: [CGPoint] = []
    pts.reserveCapacity(257)
    for i in 0...256 {
        let t = Double(i) / 256.0 * 2.0 * .pi
        let ct = cos(t), st = sin(t)
        let x = c + a * (ct < 0 ? -1.0 : 1.0) * pow(abs(ct), 2.0 / n)
        let y = c + a * (st < 0 ? -1.0 : 1.0) * pow(abs(st), 2.0 / n)
        pts.append(P(x, y))
    }
    let path = CGMutablePath()
    path.addLines(between: pts)
    path.closeSubpath()
    return path
}

func lerp(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
    P(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
}

// MARK: - Context / image plumbing

func makeContext(px: Int) -> CGContext {
    guard let ctx = CGContext(
        data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("cannot create context") }
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    return ctx
}

/// Make a context of `px` size that draws in 1024-unit user space (y-up).
func makeUnitContext(px: Int) -> CGContext {
    let ctx = makeContext(px: px)
    ctx.scaleBy(x: CGFloat(px) / 1024.0, y: CGFloat(px) / 1024.0)
    return ctx
}

func linearGradient(_ stops: [(Double, CGColor)]) -> CGGradient {
    CGGradient(
        colorsSpace: sRGB,
        colors: stops.map { $0.1 } as CFArray,
        locations: stops.map { CGFloat($0.0) }
    )!
}

/// Quality downscale by iterative box halving (deterministic).
func downscale(_ image: CGImage, to target: Int) -> CGImage {
    var current = image
    var w = image.width
    while w / 2 >= target {
        let ctx = makeContext(px: w / 2)
        ctx.interpolationQuality = .medium
        ctx.draw(current, in: CGRect(x: 0, y: 0, width: w / 2, height: w / 2))
        current = ctx.makeImage()!
        w /= 2
    }
    if w != target {
        let ctx = makeContext(px: target)
        ctx.interpolationQuality = .high
        ctx.draw(current, in: CGRect(x: 0, y: 0, width: target, height: target))
        current = ctx.makeImage()!
    }
    return current
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else { fatalError("cannot create image destination \(url)") }
    CGImageDestinationAddImage(dest, image, nil)
    if !CGImageDestinationFinalize(dest) { fatalError("failed to write \(url)") }
}

func drawLabel(_ ctx: CGContext, _ text: String, centeredAt p: CGPoint, size: CGFloat, color: CGColor) {
    let font = CTFontCreateWithName("HelveticaNeue" as CFString, size, nil)
    guard
        let attr = CFAttributedStringCreate(
            nil, text as CFString,
            [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color] as CFDictionary
        )
    else { return }
    let line = CTLineCreateWithAttributedString(attr)
    let w = CTLineGetTypographicBounds(line, nil, nil, nil)
    ctx.textPosition = CGPoint(x: p.x - CGFloat(w) / 2, y: p.y)
    CTLineDraw(line, ctx)
}

// MARK: - Shared chrome (ground, loom, finishing)

func drawGround(_ ctx: CGContext) {
    // Deep indigo ground, faintly warm at the middle (the hearth's ambient).
    let g = linearGradient([
        (0.0, cgcol((r: 0.145, g: 0.092, b: 0.205))),
        (0.55, cgcol((r: 0.082, g: 0.055, b: 0.133))),
        (1.0, cgcol((r: 0.038, g: 0.028, b: 0.066))),
    ])
    ctx.saveGState()
    let c0 = CGPoint(x: 512 - 40, y: 512 + 60)
    ctx.drawRadialGradient(
        g, startCenter: c0, startRadius: 0, endCenter: c0, endRadius: 780, options: []
    )
    ctx.restoreGState()
    ditherGround(ctx)
}

/// Very low-amplitude overlay noise: breaks gradient banding on the dark ground
/// and adds a whisper of textile grain. Deterministic (seeded). The noise tile
/// is built OPAQUE (mid-gray +- a few steps) and drawn at low alpha, so the
/// premultiplied bitmap needs no unmultiplication games.
func ditherGround(_ ctx: CGContext) {
    let px = 512
    guard let noise = CGContext(
        data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return }
    guard let data = noise.data else { return }
    let buf = data.bindMemory(to: UInt8.self, capacity: px * px * 4)
    var rng = SeededRNG(seed: 0xD17E)
    for k in 0..<(px * px) {
        let n = Int(rng.next() & 0xF) - 8  // -8..7
        let v = 128 + n
        let o = k * 4
        buf[o] = UInt8(v); buf[o + 1] = UInt8(v); buf[o + 2] = UInt8(v + 3)
        buf[o + 3] = 255
    }
    guard let img = noise.makeImage() else { return }
    ctx.saveGState()
    ctx.setBlendMode(.overlay)
    ctx.setAlpha(0.45)
    ctx.interpolationQuality = .medium
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
    ctx.restoreGState()
}

/// The dim loom behind the subject: two faint counter-diagonal thread fields.
func drawLoom(_ ctx: CGContext, rng: inout SeededRNG) {
    let warp = (r: 0.21, g: 0.175, b: 0.315)
    ctx.saveGState()
    for (angleDeg, alpha) in [(24.0, 0.10), (-24.0, 0.07)] {
        let ang = angleDeg * .pi / 180
        let dir = (x: cos(ang), y: sin(ang))
        let nrm = (x: -dir.y, y: dir.x)
        let spacing = 104.0
        let k0 = -6
        let k1 = 6
        for k in k0...k1 {
            // slight, seeded bow so the threads feel hand-woven, not ruled
            let bow = rng.range(-10, 10)
            let off = Double(k) * spacing + bow
            let a = P(512 + nrm.x * off - dir.x * 1400, 512 + nrm.y * off - dir.y * 1400)
            let b = P(512 + nrm.x * off + dir.x * 1400, 512 + nrm.y * off + dir.y * 1400)
            let mid = P((a.x + b.x) / 2 + nrm.x * bow, (a.y + b.y) / 2 + nrm.y * bow)
            let p = CGMutablePath()
            p.move(to: a)
            p.addQuadCurve(to: b, control: mid)
            ctx.addPath(p)
            ctx.setStrokeColor(cgcol(warp, alpha))
            ctx.setLineWidth(7)
            ctx.setLineCap(.round)
            ctx.strokePath()
        }
    }
    ctx.restoreGState()
}

/// Modern flat-with-subtle-depth finishing: top sheen, bottom shade, hairline rim.
func drawChrome(_ ctx: CGContext) {
    // top sheen
    ctx.saveGState()
    ctx.setBlendMode(.screen)
    let sheen = linearGradient([
        (0.0, cgcol((r: 1.0, g: 0.95, b: 1.0), 0.0)),
        (1.0, cgcol((r: 1.0, g: 0.95, b: 1.0), 0.065)),
    ])
    // linear space runs 0 at the start point -> draw top-down
    ctx.drawLinearGradient(
        sheen,
        start: P(0, 460), end: P(0, 1024),
        options: []
    )
    ctx.restoreGState()

    // bottom shade for depth
    let shade = linearGradient([
        (0.0, cgcol((r: 0, g: 0, b: 0), 0.0)),
        (1.0, cgcol((r: 0, g: 0, b: 0), 0.14)),
    ])
    ctx.drawLinearGradient(shade, start: P(0, 640), end: P(0, 1024), options: [])

    // hairline rim so the dark icon never melts into a dark Dock
    ctx.saveGState()
    let rimOuter = squircle(1018)
    ctx.addPath(rimOuter)
    ctx.setStrokeColor(cgcol((r: 0.62, g: 0.56, b: 0.85), 0.16))
    ctx.setLineWidth(2.5)
    ctx.strokePath()
    let rimInner = squircle(1012)
    ctx.addPath(rimInner)
    ctx.setStrokeColor(cgcol((r: 1.0, g: 0.9, b: 0.7), 0.07))
    ctx.setLineWidth(1.5)
    ctx.strokePath()
    ctx.restoreGState()
}

// MARK: - Strand layer compositing (glow)

/// Composite the opaque strand layer onto the ground with a two-tier warm bloom
/// plus a wide screen halo. `deviceScale` converts user-space blur to device px.
func compositeStrandLayer(_ ctx: CGContext, layer: CGContext, deviceScale: Double, glow: Double) {
    guard let img = layer.makeImage() else { return }
    let rect = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    ctx.saveGState()
    // tier 1: broad, soft ambient bloom — kept LOW because a fat blurred
    // silhouette of the band fills the gaps between strands (mush).
    ctx.setShadow(
        offset: .zero,
        blur: CGFloat(130 * deviceScale),
        color: cgcol((r: 1.0, g: 0.50, b: 0.18), 0.16 * glow)
    )
    ctx.draw(img, in: rect)
    // tier 2: tighter halo, the "thread is emitting light" layer
    ctx.setShadow(
        offset: .zero,
        blur: CGFloat(40 * deviceScale),
        color: cgcol((r: 1.0, g: 0.62, b: 0.25), 0.22 * glow)
    )
    ctx.draw(img, in: rect)
    ctx.restoreGState()
}

/// One shaded thread segment (edge / core / highlight passes), drawn OPAQUE so
/// overlapping round caps in the interlace never band.
func strokeThreadSegment(
    _ ctx: CGContext, a: CGPoint, b: CGPoint, width: Double, base: RGB,
    highlightOffset: CGPoint
) {
    let p = CGMutablePath()
    p.move(to: a)
    p.addLine(to: b)
    // edge
    ctx.addPath(p)
    ctx.setStrokeColor(cgcol(darken(base, 0.45)))
    ctx.setLineWidth(CGFloat(width))
    ctx.setLineCap(.round)
    ctx.strokePath()
    // core
    ctx.addPath(p)
    ctx.setStrokeColor(cgcol(base))
    ctx.setLineWidth(CGFloat(width * 0.62))
    ctx.strokePath()
    // specular thread highlight
    let hp = CGMutablePath()
    hp.move(to: P(a.x + highlightOffset.x, a.y + highlightOffset.y))
    hp.addLine(to: P(b.x + highlightOffset.x, b.y + highlightOffset.y))
    ctx.addPath(hp)
    ctx.setStrokeColor(cgcol(lighten(base, 0.30)))
    ctx.setLineWidth(CGFloat(width * 0.22))
    ctx.strokePath()
}

func glowBlob(_ ctx: CGContext, at c: CGPoint, radius: Double, inner: RGB, innerA: Double, mid: RGB, midA: Double) {
    let g = CGGradient(
        colorsSpace: sRGB,
        colors: [cgcol(inner, innerA), cgcol(mid, midA), cgcol(mid, 0)] as CFArray,
        locations: [0, 0.45, 1]
    )!
    ctx.saveGState()
    ctx.setBlendMode(.plusLighter)
    ctx.drawRadialGradient(
        g, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(radius), options: []
    )
    ctx.restoreGState()
}

// MARK: - Concept A: the Ember Loop (braided ring)

struct RingConfig {
    var strands = 3
    var lobes = 7
    var radius = 292.0
    var amp = 66.0
    var width = 40.0
    var heatAngleDeg = 45.0
    var glow = 1.0
    /// Per-strand dye step along the ember ramp — this is what makes the
    /// over-under interlace legible (threads differ in color everywhere,
    /// including where they cross).
    var dyeSpread = 0.13
    /// Global tonal window into the ember ramp: keeps the hot arc off white
    /// and the cool arc off black.
    var heatFloor = 0.14
    var heatCeil = 0.90
    /// Pixel-dedicated small-size rendition (16/32): no loom, no sparks,
    /// chunkier threads, brighter floor, less bloom, darker hole — the braid
    /// stays but everything that would dither into noise at 16 px is gone.
    var simplified = false

    static func small() -> RingConfig {
        var c = RingConfig()
        c.radius = 292
        c.amp = 62
        c.width = 46
        c.lobes = 6
        c.heatFloor = 0.30
        c.heatCeil = 0.95
        c.glow = 0.72
        c.simplified = true
        return c
    }
}

func renderRing(_ ctx: CGContext, cfg: RingConfig, rng: inout SeededRNG, deviceScale: Double) {
    let center = P(512, 512)
    let heatAngle = cfg.heatAngleDeg * .pi / 180

    // angle -> base heat, then remapped into [floor, ceil]
    func heatOf(_ angle: Double) -> Double {
        let h = (1 - cos(angle - heatAngle)) / 2
        return cfg.heatFloor + (cfg.heatCeil - cfg.heatFloor) * h
    }

    func dyeOffset(_ strand: Int) -> Double {
        (Double(strand) - Double(cfg.strands - 1) / 2) * cfg.dyeSpread
    }

    // hearth glow inside the loop (drawn under the strands)
    if cfg.simplified {
        glowBlob(
            ctx, at: center, radius: 150,
            inner: (r: 1.0, g: 0.42, b: 0.14), innerA: 0.32,
            mid: (r: 1.0, g: 0.35, b: 0.1), midA: 0.08
        )
    } else {
        glowBlob(
            ctx, at: center, radius: 218,
            inner: (r: 1.0, g: 0.42, b: 0.14), innerA: 0.44,
            mid: (r: 1.0, g: 0.35, b: 0.1), midA: 0.11
        )
    }

    // ---- build the interlace: z-ordered segments across all strands ----
    struct Seg {
        let a: CGPoint; let b: CGPoint
        let depth: Double; let heat: Double; let strand: Int; let idx: Int
        let radial: CGPoint  // outward unit direction at the segment midpoint
    }
    var segs: [Seg] = []
    segs.reserveCapacity(cfg.strands * 300)
    let N = 288
    let step = 2.0 * Double.pi / Double(N)
    for i in 0..<cfg.strands {
        let phase = 2.0 * Double.pi * Double(i) / Double(cfg.strands)
        for j in 0..<N {
            let u0 = Double(j) * step
            let u1 = u0 + step
            let um = u0 + step / 2
            func pt(_ u: Double) -> CGPoint {
                let r = cfg.radius + cfg.amp * cos(Double(cfg.lobes) * u + phase)
                return P(center.x + r * cos(u), center.y + r * sin(u))
            }
            segs.append(
                Seg(
                    a: pt(u0), b: pt(u1), depth: cfg.amp * cos(Double(cfg.lobes) * um + phase),
                    heat: heatOf(um), strand: i, idx: j,
                    radial: P(cos(um), sin(um))
                )
            )
        }
    }
    // deterministic total order (Swift's sort is not stable): depth, then strand, then index
    segs.sort {
        if $0.depth != $1.depth { return $0.depth < $1.depth }
        if $0.strand != $1.strand { return $0.strand < $1.strand }
        return $0.idx < $1.idx
    }

    // ---- draw the interlace into an opaque offscreen layer ----
    // Contact shadows: each segment (drawn bottom-up in z) casts a small soft
    // shadow on the strands beneath it — with the per-strand dye offsets this
    // is what makes the over-under interlace of the braid legible.
    let layer = makeUnitContext(px: Int(1024 * deviceScale))
    layer.setShadow(
        offset: CGSize(width: 0, height: -7),
        blur: CGFloat(9 * deviceScale),
        color: cgcol((r: 0, g: 0, b: 0), 0.55)
    )
    for seg in segs {
        let base = ember(seg.heat + dyeOffset(seg.strand))
        // threads are lit from the hearth at the center AND from above
        let hx = -seg.radial.x * 0.7
        let hy = 0.7 - seg.radial.y * 0.49
        let hl = P(hx * cfg.width * 0.16, hy * cfg.width * 0.16)
        strokeThreadSegment(layer, a: seg.a, b: seg.b, width: cfg.width, base: base, highlightOffset: hl)
    }

    compositeStrandLayer(ctx, layer: layer, deviceScale: deviceScale, glow: cfg.glow)

    // ---- coal nodes on the outer lobes of the hot arc ----
    var coalRng = SeededRNG(seed: 0xE473)
    var candidates: [(Double, Int)] = []  // (angle, strand)
    for i in 0..<cfg.strands {
        let phase = 2.0 * Double.pi * Double(i) / Double(cfg.strands)
        for k in 0..<cfg.lobes {
            let u = (2.0 * Double.pi * Double(k) - phase) / Double(cfg.lobes)
            candidates.append((u, i))
        }
    }
    // prefer coals near the hot arc, keep determinism: sort by heat then strand
    candidates.sort {
        let ha = heatOf($0.0), hb = heatOf($1.0)
        if ha != hb { return ha > hb }
        if $0.1 != $1.1 { return $0.1 < $1.1 }
        return $0.0 < $1.0
    }
    let coalCount = cfg.simplified ? 2 : 3
    for n in 0..<coalCount {
        let (u, i) = candidates[(n * 5 + 2) % candidates.count]
        let jitter = coalRng.range(-0.05, 0.05)
        let uu = u + jitter
        let phase = 2.0 * Double.pi * Double(i) / Double(cfg.strands)
        let r = cfg.radius + cfg.amp * cos(Double(cfg.lobes) * uu + phase) + 4
        let c = P(center.x + r * cos(uu), center.y + r * sin(uu))
        let h = heatOf(uu)
        glowBlob(
            ctx, at: c, radius: 15 + 15 * h,
            inner: (r: 1.0, g: 0.88, b: 0.6), innerA: 0.55,
            mid: (r: 1.0, g: 0.5, b: 0.15), midA: 0.2
        )
    }

    // ---- sparks drifting off the hot side ----
    let sparkCount = cfg.simplified ? 0 : 4
    for _ in 0..<sparkCount {
        let bias = coalRng.range(0, 1)
        let ang = heatAngle + coalRng.range(-1.5, 1.5) + (bias < 0.4 ? .pi : 0)
        let dist = cfg.radius + cfg.amp + coalRng.range(55, 140)
        let c = P(center.x + dist * cos(ang), center.y + dist * sin(ang))
        // keep sparks clear of the squircle edge
        let dc = hypot(c.x - center.x, c.y - center.y)
        if dc > 470 { continue }
        let rad = coalRng.range(3, 7)
        glowBlob(
            ctx, at: c, radius: rad * 3.2,
            inner: (r: 1.0, g: 0.92, b: 0.7), innerA: 0.8,
            mid: (r: 1.0, g: 0.6, b: 0.2), midA: 0.2
        )
    }

    // deep core of the hearth, over the strands
    if cfg.simplified {
        glowBlob(
            ctx, at: center, radius: 34,
            inner: (r: 1.0, g: 0.92, b: 0.72), innerA: 0.4,
            mid: (r: 1.0, g: 0.6, b: 0.25), midA: 0.12
        )
    } else {
        glowBlob(
            ctx, at: center, radius: 88,
            inner: (r: 1.0, g: 0.78, b: 0.44), innerA: 0.38,
            mid: (r: 1.0, g: 0.45, b: 0.15), midA: 0.10
        )
        // white-hot kernel deep inside
        glowBlob(
            ctx, at: P(center.x, center.y - 8), radius: 34,
            inner: (r: 1.0, g: 0.92, b: 0.72), innerA: 0.40,
            mid: (r: 1.0, g: 0.6, b: 0.25), midA: 0.12
        )
    }
}

// MARK: - Concept B: Rising Weft (diagonal braid)

func renderBraid(_ ctx: CGContext, rng: inout SeededRNG, deviceScale: Double) {
    let p0 = P(150, 660), p1 = P(420, 900), p2 = P(700, 130), p3 = P(890, 330)

    func bez(_ t: Double) -> (pt: CGPoint, tan: CGPoint) {
        let q0 = lerp(p0, p1, t), q1 = lerp(p1, p2, t), q2 = lerp(p2, p3, t)
        let r0 = lerp(q0, q1, t), r1 = lerp(q1, q2, t)
        let s = lerp(r0, r1, t)
        var d = P(r1.x - r0.x, r1.y - r0.y)
        let len = max(hypot(d.x, d.y), 1e-6)
        d = P(d.x / len, d.y / len)
        return (s, d)
    }

    struct BSeg {
        let a: CGPoint; let b: CGPoint
        let depth: Double; let heat: Double; let width: Double
        let normal: CGPoint
    }
    var segs: [BSeg] = []
    let strands = 3
    let waves = 3.0
    let N = 220
    for i in 0..<strands {
        for j in 0..<N {
            let t0 = Double(j) / Double(N), t1 = Double(j + 1) / Double(N)
            func strandPoint(_ t: Double) -> (CGPoint, Double, CGPoint) {
                let (c, tan) = bez(t)
                let nrm = P(-tan.y, tan.x)
                let amp = 26 + 62 * (1 - t)
                let off = amp * sin(2 * .pi * waves * t + 2 * .pi * Double(i) / Double(strands))
                return (P(c.x + nrm.x * off, c.y + nrm.y * off), off, nrm)
            }
            let (a, off0, nrm) = strandPoint(t0)
            let (b, _, _) = strandPoint(t1)
            let width = 64 * pow(1 - t0, 0.8) + 22
            segs.append(
                BSeg(a: a, b: b, depth: off0, heat: pow(t0, 0.85), width: width, normal: nrm)
            )
        }
    }
    segs.sort {
        if $0.depth != $1.depth { return $0.depth < $1.depth }
        return $0.a.x < $1.a.x
    }

    let layer = makeUnitContext(px: Int(1024 * deviceScale))
    for seg in segs {
        let base = ember(seg.heat)
        let hl = P(seg.normal.x * seg.width * 0.16, seg.normal.y * seg.width * 0.16)
        strokeThreadSegment(layer, a: seg.a, b: seg.b, width: seg.width, base: base, highlightOffset: hl)
    }
    compositeStrandLayer(ctx, layer: layer, deviceScale: deviceScale, glow: 1.0)

    // sparks off the tip
    var srng = SeededRNG(seed: 0x5D17)
    for _ in 0..<6 {
        let t = srng.range(0.97, 1.12)
        let (c, tan) = bez(min(t, 1))
        let nrm = P(-tan.y, tan.x)
        let off = srng.range(-70, 70)
        let p = P(c.x + nrm.x * off + tan.x * (t > 1 ? 60 * (t - 1) : 0), c.y + nrm.y * off)
        let rad = srng.range(3, 7)
        glowBlob(
            ctx, at: p, radius: rad * 4,
            inner: (r: 1.0, g: 0.92, b: 0.7), innerA: 0.9,
            mid: (r: 1.0, g: 0.6, b: 0.2), midA: 0.25
        )
    }
}

// MARK: - Concept C: Loom Plaque (woven diamond)

func renderWeave(_ ctx: CGContext, rng: inout SeededRNG, deviceScale: Double) {
    let side = 640.0
    let plaque = CGPath(
        roundedRect: CGRect(x: 512 - side / 2, y: 512 - side / 2, width: side, height: side),
        cornerWidth: 92, cornerHeight: 92, transform: nil
    )
    // rotate 45 degrees about center
    var xform = CGAffineTransform(translationX: 512, y: 512).rotated(by: .pi / 4)
        .translatedBy(x: -512, y: -512)
    let diamond = plaque.copy(using: &xform)!

    ctx.saveGState()
    ctx.addPath(diamond)
    ctx.clip()

    // plaque base
    let base = linearGradient([
        (0.0, cgcol((r: 0.16, g: 0.11, b: 0.24))),
        (1.0, cgcol((r: 0.09, g: 0.06, b: 0.15))),
    ])
    ctx.drawLinearGradient(base, start: P(0, 900), end: P(0, 120), options: [])

    let n = 12
    let spacing = side / Double(n + 1)
    let w = 30.0
    let origin = 512 - side / 2

    // horizontal weft strands (ember, hottest at top)
    for r in 0..<n {
        let y = origin + spacing * Double(r + 1)
        let heat = 1 - Double(r) / Double(n - 1)
        let base = ember(heat * 0.95)
        strokeThreadSegment(ctx, a: P(origin, y), b: P(origin + side, y), width: w, base: base, highlightOffset: P(0, w * 0.16))
    }

    // vertical warp strands, drawn over alternating cells for the basketweave interlace
    let violet = (r: 0.30, g: 0.25, b: 0.46)
    for c in 0..<n {
        let x = origin + spacing * Double(c + 1)
        for r in 0..<n {
            guard (c + r) % 2 == 0 else { continue }
            let ya = origin + spacing * Double(r) - spacing * 0.35
            let yb = origin + spacing * Double(r + 1) + spacing * 0.35
            // brighten warp toward the hot center
            let dCenter = hypot(x - 512, (ya + yb) / 2 - 512) / (side * 0.72)
            let b = mix(violet, (r: 0.55, g: 0.42, b: 0.80), max(0, 1 - dCenter))
            strokeThreadSegment(ctx, a: P(x, ya), b: P(x, yb), width: w, base: b, highlightOffset: P(w * 0.16, 0))
        }
    }

    // ember heat behind the weave, at the center
    glowBlob(
        ctx, at: P(512, 512), radius: 260,
        inner: (r: 1.0, g: 0.5, b: 0.16), innerA: 0.28,
        mid: (r: 1.0, g: 0.35, b: 0.1), midA: 0.08
    )

    ctx.restoreGState()

    // a couple of coals glowing through the weave
    var crng = SeededRNG(seed: 0xC0A1)
    for _ in 0..<3 {
        let c = Int(crng.range(3, 8))
        let r = Int(crng.range(3, 8))
        let p = P(origin + spacing * Double(c + 1), origin + spacing * Double(r + 1))
        glowBlob(
            ctx, at: p, radius: 34,
            inner: (r: 1.0, g: 0.85, b: 0.55), innerA: 0.75,
            mid: (r: 1.0, g: 0.5, b: 0.15), midA: 0.22
        )
    }
}

// MARK: - Concept rendering

enum Concept: String {
    case ring, braid, weave
}

func renderConcept(
    _ concept: Concept, size: Int, cfg: RingConfig, seed: UInt64
) -> CGImage {
    let ss = 2
    let px = size * ss
    let deviceScale = Double(px) / 1024.0
    let ctx = makeUnitContext(px: px)
    ctx.saveGState()
    ctx.addPath(squircle(1024))
    ctx.clip()

    drawGround(ctx)
    var rng = SeededRNG(seed: seed)
    if !(concept == .ring && cfg.simplified) {
        drawLoom(ctx, rng: &rng)
    }

    switch concept {
    case .ring: renderRing(ctx, cfg: cfg, rng: &rng, deviceScale: deviceScale)
    case .braid: renderBraid(ctx, rng: &rng, deviceScale: deviceScale)
    case .weave: renderWeave(ctx, rng: &rng, deviceScale: deviceScale)
    }

    drawChrome(ctx)
    ctx.restoreGState()
    let full = ctx.makeImage()!
    return downscale(full, to: size)
}

// MARK: - Sheets

func loadPNG(_ url: URL) -> CGImage {
    guard
        let src = CGImageSourceCreateWithURL(url as CFURL, nil),
        let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
    else { fatalError("cannot load \(url)") }
    return img
}

/// Contact sheet: master at 16..512 on dark, master at 16..256 on light, and
/// the shipped pixel-dedicated small sizes (16/32/64) on dark.
func makeContactSheet(master: CGImage, small: CGImage?, out: URL) throws {
    let sizesDark = [16, 32, 64, 128, 256, 512]
    let sizesLight = [16, 32, 64, 128, 256]
    let sizesSmall = [16, 32, 64]
    let gap = 34
    let margin = 40
    let labelH = 36

    let width = margin * 2 + sizesDark.reduce(0) { $0 + $1 + gap } - gap
    let rowDarkH = 512 + labelH
    let rowLightH = 256 + labelH
    let rowSmallH = 64 + labelH + 26
    let titleH = 66
    let stripPad = 20
    let height = titleH + rowDarkH + stripPad * 2 + rowLightH + rowSmallH + margin

    let ctx = makeContext(px: width)
    ctx.setFillColor(cgcol((r: 0.086, g: 0.075, b: 0.118)))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    // title
    drawLabel(
        ctx, "Emberweft — icon size legibility",
        centeredAt: CGPoint(x: CGFloat(width) / 2, y: CGFloat(height - 40)),
        size: 26, color: cgcol((r: 0.72, g: 0.66, b: 0.85))
    )

    // row layout, bottom-up: [small-row][light-row][dark-row][title]
    let darkRowTop = CGFloat(height - titleH - 512)
    let lightRowTop = darkRowTop - CGFloat(stripPad * 2 + rowLightH - stripPad)
    let smallRowTop = lightRowTop - CGFloat(rowSmallH + stripPad)

    func placeRow(
        sizes: [Int], rowHeight: Int, bandTop: CGFloat, image: CGImage,
        light: Bool, caption: String
    ) {
        if light {
            let strip = CGRect(
                x: CGFloat(margin - 24), y: bandTop - 12,
                width: CGFloat(width - (margin - 24) * 2),
                height: CGFloat(rowHeight + stripPad + 14)
            )
            let path = CGPath(
                roundedRect: strip, cornerWidth: 18, cornerHeight: 18, transform: nil
            )
            ctx.addPath(path)
            ctx.setFillColor(cgcol((r: 0.905, g: 0.895, b: 0.925)))
            ctx.fillPath()
        }
        var x = CGFloat(margin)
        let labelColor = light
            ? cgcol((r: 0.35, g: 0.32, b: 0.42))
            : cgcol((r: 0.60, g: 0.55, b: 0.75))
        drawLabel(
            ctx, caption, centeredAt: CGPoint(x: x + 90, y: bandTop + CGFloat(rowHeight) + 6),
            size: 18, color: cgcol((r: 0.48, g: 0.44, b: 0.62))
        )
        for s in sizes {
            let icon = downscale(image, to: s)
            let y = bandTop + (CGFloat(rowHeight) - CGFloat(s)) / 2
            ctx.draw(icon, in: CGRect(x: x, y: y, width: CGFloat(s), height: CGFloat(s)))
            drawLabel(
                ctx, "\(s)", centeredAt: CGPoint(x: x + CGFloat(s) / 2, y: bandTop - 34),
                size: 20, color: labelColor
            )
            x += CGFloat(s + gap)
        }
    }

    placeRow(
        sizes: sizesDark, rowHeight: 512, bandTop: darkRowTop, image: master,
        light: false, caption: "master, downscaled")
    placeRow(
        sizes: sizesLight, rowHeight: 256, bandTop: lightRowTop + 10, image: master,
        light: true, caption: "master on light")
    if let small = small {
        placeRow(
            sizes: sizesSmall, rowHeight: 64, bandTop: smallRowTop + 30, image: small,
            light: false, caption: "shipped 16/32/64 (pixel-dedicated)")
    }

    guard let img = ctx.makeImage() else { fatalError("sheet render failed") }
    try writePNG(img, to: out)
}

/// Alternates sheet: the three concepts at 384 px for side-by-side judgement.
func makeAlternatesSheet(out: URL, cfg: RingConfig, seed: UInt64) throws {
    let tile = 384
    let gap = 36
    let margin = 40
    let labelH = 44
    let width = margin * 2 + tile * 3 + gap * 2
    let height = margin + tile + labelH + 30

    let ctx = makeContext(px: width)
    ctx.setFillColor(cgcol((r: 0.086, g: 0.075, b: 0.118)))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    let concepts: [(Concept, String)] = [
        (.ring, "A — Ember Loop (braided ring)"),
        (.braid, "B — Rising Weft (diagonal braid)"),
        (.weave, "C — Loom Plaque (woven diamond)"),
    ]
    for (k, (concept, label)) in concepts.enumerated() {
        let icon = renderConcept(concept, size: tile, cfg: cfg, seed: seed)
        let x = CGFloat(margin + k * (tile + gap))
        ctx.draw(icon, in: CGRect(x: x, y: 30, width: CGFloat(tile), height: CGFloat(tile)))
        drawLabel(
            ctx, label, centeredAt: CGPoint(x: x + CGFloat(tile) / 2, y: 6),
            size: 20, color: cgcol((r: 0.72, g: 0.66, b: 0.85))
        )
    }
    guard let img = ctx.makeImage() else { fatalError("sheet render failed") }
    try writePNG(img, to: out)
}

// MARK: - CLI

var concept = Concept.ring
var outPath: String?
var size = 1024
var seed: UInt64 = 7
var contactMaster: String?
var contactSmall: String?
var alternates = false
var smallRendition = false
var cfg = RingConfig()

let args = CommandLine.arguments
var i = 1
while i < args.count {
    let a = args[i]
    func value() -> String {
        i += 1
        guard i < args.count else { fatalError("missing value for \(a)") }
        return args[i]
    }
    switch a {
    case "--concept": concept = Concept(rawValue: value()) ?? .ring
    case "--out": outPath = value()
    case "--size": size = Int(value()) ?? 1024
    case "--seed": seed = UInt64(value()) ?? 7
    case "--contact": contactMaster = value()
    case "--contact-small": contactSmall = value()
    case "--alternates": alternates = true
    case "--small": smallRendition = true
    case "--radius": cfg.radius = Double(value()) ?? cfg.radius
    case "--amp": cfg.amp = Double(value()) ?? cfg.amp
    case "--width": cfg.width = Double(value()) ?? cfg.width
    case "--strands": cfg.strands = Int(value()) ?? cfg.strands
    case "--lobes": cfg.lobes = Int(value()) ?? cfg.lobes
    case "--heat-angle": cfg.heatAngleDeg = Double(value()) ?? cfg.heatAngleDeg
    case "--glow": cfg.glow = Double(value()) ?? cfg.glow
    default:
        FileHandle.standardError.write("unknown argument \(a)\n".data(using: .utf8)!)
        exit(2)
    }
    i += 1
}

do {
    if alternates {
        guard let out = outPath else { fatalError("--alternates needs --out") }
        try makeAlternatesSheet(
            out: URL(fileURLWithPath: out), cfg: cfg, seed: seed)
        print("wrote \(out)")
    } else if let masterPath = contactMaster {
        guard let out = outPath else { fatalError("--contact needs --out") }
        try makeContactSheet(
            master: loadPNG(URL(fileURLWithPath: masterPath)),
            small: contactSmall.map { loadPNG(URL(fileURLWithPath: $0)) },
            out: URL(fileURLWithPath: out))
        print("wrote \(out)")
    } else {
        guard let out = outPath else { fatalError("need --out") }
        if smallRendition { cfg = RingConfig.small() }
        let img = renderConcept(concept, size: size, cfg: cfg, seed: seed)
        try writePNG(img, to: URL(fileURLWithPath: out))
        print("wrote \(out) (\(size)x\(size))\(smallRendition ? " [small rendition]" : "")")
    }
} catch {
    FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
    exit(1)
}
