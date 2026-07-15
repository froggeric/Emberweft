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

    /// Reads a PNG into an `RGBA8Image` whose `pixels` row 0 is the PNG's visual top row.
    ///
    /// On macOS 26, drawing a `CGImage` upright into a `premultipliedLast` bitmap
    /// `CGContext` of matching size already produces top-row-first output in the
    /// data buffer, so NO CTM flip is applied. Applying the textbook
    /// `translateBy(0, h) + scaleBy(1, -1)` flip here would DOUBLE-flip and
    /// vertically mirror the bytes. (Verified empirically by decoding the written
    /// PNG bytes with an independent zlib path.)
    static func readPNG(from url: URL) throws -> RGBA8Image {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw NSError(domain: "RGBA8Image", code: 4)
        }
        let w = cg.width, h = cg.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        // See header doc: NO CTM flip — drawing upright into this premultipliedLast
        // context already yields top-row-first output on macOS 26.
        guard let ctx = CGContext(data: &pixels, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: cs,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
        else { throw NSError(domain: "RGBA8Image", code: 5) }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return RGBA8Image(width: w, height: h, pixels: pixels)
    }
}
