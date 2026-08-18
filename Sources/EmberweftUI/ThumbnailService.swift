import Foundation
import AppKit
import FlameKit
import FlameReference
import FlameRenderer
import FlamePlayer

/// Renders and caches small genome thumbnails.
///
/// **Poster frame.** A loop is seamless (t=0 ≡ t=1) and the midpoint (180°) is
/// maximally rotated, so the most *representative* frame is the as-authored
/// still — `Loop.blend(flame, t: 0)`, i.e. identity rotation. Rendering the raw
/// `flame` produces exactly that still, so the service renders the flame directly.
///
/// **Quality.** The poster is rendered at a higher resolution (e.g. 720p) and
/// downscaled to the display size with high-quality interpolation — a crisper,
/// more representative thumbnail than rendering at display size directly.
///
/// **Main-thread cost.** `MetalRenderer.render` is `@MainActor` and synchronous,
/// so Metal thumbnails block the main thread while they run. This service keeps
/// that bounded: requests run on the actor and hop to the MainActor; because
/// `MetalFrameRenderer.render` is synchronous on the MainActor, concurrent
/// requests serialize (≤1 in flight). Cells request on `.utility`-priority tasks
/// (`.task(priority: .utility)`) so the system deprioritizes thumbnail work vs.
/// the UI and playback.
///
/// Two cache layers: a bounded `NSCache` (hot) + PNG files on disk (cold), keyed
/// by a deterministic string of `(id, renderW, renderH, displayW, displayH, spp,
/// backend, seed)` — string/int components only (rule #2). Degenerate / all-black
/// output is reported as a sentinel, never cached as a misleading black PNG.
public actor ThumbnailService {

    /// Thumbnail render outcome. `image` carries the DISPLAY-sized RGBA8 pixels
    /// (the cell builds the `NSImage` on the MainActor). `degenerate` = NaN-camera
    /// / all-black genome (data-integrity issue, not a code bug — CLAUDE.md).
    public enum Outcome: Sendable {
        case image(RGBA8Image)
        case degenerate
        case failed
    }

    private let cacheDir: URL
    private let memory: NSCache<NSString, ThumbnailBox> = {
        let c = NSCache<NSString, ThumbnailBox>()
        c.countLimit = 400
        c.totalCostLimit = 64 * 1024 * 1024  // 64 MB
        return c
    }()

    /// - Parameter cacheDirectory: Where cold-cache PNGs live. The caller (app)
    ///   passes `<app-support>/thumbs`; tests pass a temp dir.
    public init(cacheDirectory: URL) {
        self.cacheDir = cacheDirectory
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    /// Render (or fetch from cache) a display-sized thumbnail for `entry`'s genome
    /// `flame`. Renders at `renderParams` resolution, downscales to
    /// `displayWidth`×`displayHeight`.
    public func thumbnail(for entry: LibraryEntry,
                          flame: Flame,
                          renderParams: RenderParams,
                          displayWidth: Int,
                          displayHeight: Int,
                          backend: AppPreferences.Backend) async -> Outcome {
        // Cheap rejection first — never render a NaN/degenerate genome.
        guard flame.isRenderable else { return .degenerate }

        let key = Self.cacheKey(
            id: entry.id,
            renderW: renderParams.width, renderH: renderParams.height,
            displayW: displayWidth, displayH: displayHeight,
            spp: renderParams.samplesPerPixel,
            backend: backend.rawValue,
            seed: renderParams.seed)

        if let box = memory.object(forKey: key as NSString) {
            return .image(box.image)
        }
        if let cached = readDisk(key: key) {
            storeMemory(key: key, image: cached)
            return .image(cached)
        }

        // Render the poster frame (the loop's t=0 identity-rotation still),
        // FRAMING-NORMALIZED to the render width (M6.6): `camera.scale` is
        // absolute pixels-per-unit authored for the genome's `size`, so a raw
        // render at the (small) thumbnail width zooms the subject INTO the
        // frame. Normalizing keeps the thumbnail's framing identical to what
        // export/flock produce at any resolution.
        let normalized = Framing.normalize(flame: flame, renderWidth: renderParams.width)
        let fullSize = await render(flame: normalized, params: renderParams, backend: backend)
        // All-black ⇒ degenerate sentinel (never cache as a black PNG).
        if fullSize.isAllZero { return .degenerate }

        // Downscale to the display size; fall back to the full render on failure.
        guard let display = fullSize.scaled(toWidth: displayWidth, toHeight: displayHeight) else {
            return .failed
        }

        writeDisk(key: key, image: display)
        storeMemory(key: key, image: display)
        return .image(display)
    }

    // MARK: - Cache key (pure, deterministic — rule #2)

    /// Deterministic cache key from string/int components only. Same inputs ⇒
    /// same key across runs and machines. Includes both render and display sizes
    /// so changing either invalidates the cache. The `frn1` suffix is the M6.6
    /// framing-generation marker — normalized thumbnails must not be served from
    /// pre-M6.6 faithful caches (or vice versa on a hypothetical rollback).
    public static func cacheKey(id: String,
                                renderW: Int, renderH: Int,
                                displayW: Int, displayH: Int,
                                spp: Int, backend: String, seed: UInt64) -> String {
        let safeID = id.replacingOccurrences(of: "/", with: "__")
        return "\(safeID)__rw\(renderW)x\(renderH)__dw\(displayW)x\(displayH)__spp\(spp)__\(backend)__seed\(seed)__frn1"
    }

    // MARK: - Internals

    private func render(flame: Flame, params: RenderParams,
                        backend: AppPreferences.Backend) async -> RGBA8Image {
        if backend == .metal {
            // Off-main Metal: encodes + waits on a background queue, NEVER touching
            // the MainActor → no UI freeze. Falls back to CPU (also off-main) if
            // Metal is unavailable, so the thumbnail still appears.
            if let img = MetalRenderer.renderOffMain(flame: flame, params: params) {
                return img
            }
            return await CPUFrameRenderer().render(flame: flame, params: params)
        } else {
            return await CPUFrameRenderer().render(flame: flame, params: params)
        }
    }

    private func storeMemory(key: String, image: RGBA8Image) {
        let cost = image.pixels.count
        memory.setObject(ThumbnailBox(image), forKey: key as NSString, cost: cost)
    }

    private func diskURL(key: String) -> URL {
        cacheDir.appendingPathComponent("\(key).png")
    }

    private func writeDisk(key: String, image: RGBA8Image) {
        try? image.writePNG(to: diskURL(key: key))
    }

    private func readDisk(key: String) -> RGBA8Image? {
        let url = diskURL(key: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? RGBA8Image.readPNG(from: url)
    }
}

/// `NSObject` box so an `RGBA8Image` can live in `NSCache`.
final class ThumbnailBox: NSObject {
    let image: RGBA8Image
    init(_ image: RGBA8Image) { self.image = image }
}
