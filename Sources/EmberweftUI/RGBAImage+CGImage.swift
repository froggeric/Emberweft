import AppKit
import FlameKit
import FlamePlayer

/// GUI-side image bridging for `RGBA8Image`.
///
/// `FlameKit` deliberately has no CoreGraphics/AppKit dependency, so the
/// `RGBA8Image → CGImage/NSImage` conversion lives here in the GUI layer.
///
/// ## Orientation (load-bearing — two different flips)
/// There are TWO distinct CGImage orientations in this app, and mixing them up
/// flips images (the thumbnail-vs-playback mismatch):
///
/// - **`FlameUI.makeCGImage`** (in FlamePlayer) **flips** the rows. It is built
///   specifically for `CAMetalLayer.contents`, which the M3 playback path proved
///   displays the renderer's data bottom-up — so the flip restores upright.
/// - **`toCGImage()`** here is **upright (no flip)** — the renderer's `pixels`
///   are already top-first (row 0 = top), which is a CGImage's native data
///   layout. This matches `RGBA8Image.writePNG`/`readPNG`, whose orientation is
///   verified against the `flam3` goldens (the parity oracle). Use this for
///   `NSImage`/SwiftUI `Image` and for any pixel processing (downscale, etc.) —
///   i.e. anywhere EXCEPT handing bytes directly to `CAMetalLayer`.
public extension RGBA8Image {

    /// An **upright** premultiplied-alpha `CGImage` whose data is the renderer's
    /// `pixels` unchanged (row 0 = top). Use for `NSImage`/SwiftUI and pixel
    /// processing — NOT for `CAMetalLayer.contents` (use `FlameUI.makeCGImage`
    /// for the layer). Returns `nil` for empty images.
    func toCGImage() -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(pixels) as CFData)
        else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent)
    }

    /// Convenience `NSImage` (upright) wrapper around `toCGImage()`.
    func toNSImage() -> NSImage? {
        guard let cg = toCGImage() else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: width, height: height))
    }

    /// True iff every pixel channel is zero (an all-black / degenerate render).
    /// Used by the thumbnail service to detect NaN-camera genomes that render
    /// solid black on both backends (CLAUDE.md data-integrity gotcha).
    var isAllZero: Bool {
        pixels.allSatisfy { $0 == 0 }
    }

    /// High-quality downscale to `width`×`height`, **orientation-preserving**.
    /// Draws the upright `CGImage` into a premultipliedLast context (same rule as
    /// `RGBA8Image.readPNG` — no CTM flip on macOS 26), so row 0 of the result is
    /// still the visual top. Returns `nil` on failure.
    func scaled(toWidth width: Int, toHeight height: Int) -> RGBA8Image? {
        guard width > 0, height > 0, let cg = toCGImage() else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &pixels, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: cs,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return RGBA8Image(width: width, height: height, pixels: pixels)
    }
}
