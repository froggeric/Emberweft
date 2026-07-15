import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public extension RGBA8Image {
    /// Encode this image as an 8-bit RGBA PNG at `url`.
    ///
    /// The PNG encoder is not byte-stable across runs (timestamps); round-trip
    /// equality is on decoded pixels, not file bytes. Byte-stable encoding is a
    /// Task 15 concern. All source pixels are treated as premultiplied alpha.
    func writePNG(to url: URL) throws {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cgImage = CGImage(
                width: width, height: height,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: cs,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw NSError(domain: "RGBA8Image", code: 1) }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw NSError(domain: "RGBA8Image", code: 2) }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "RGBA8Image", code: 3) }
    }

    /// Decode a PNG at `url` into a top-row-first `RGBA8Image`.
    ///
    /// A bitmap `CGContext` has a y-up origin while a CGImage's row 0 is its
    /// top; drawing directly would vertically flip the bytes. A CTM flip is
    /// applied so `pixels` ends up top-row-first (matching `writePNG`).
    static func readPNG(from url: URL) throws -> RGBA8Image {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw NSError(domain: "RGBA8Image", code: 4)
        }
        let w = cg.width, h = cg.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: &pixels, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw NSError(domain: "RGBA8Image", code: 5) }
        // A bitmap CGContext's data pointer starts at the row the image's row 0
        // maps to under the default y-up CTM when drawing a CGImage upright, so
        // `pixels` already ends up top-row-first (matching `writePNG`). Do NOT
        // apply a CTM flip — doing so double-flips and vertically mirrors the
        // decoded bytes (verified empirically on macOS 26 / Swift 6.2).
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return RGBA8Image(width: w, height: h, pixels: pixels)
    }
}
