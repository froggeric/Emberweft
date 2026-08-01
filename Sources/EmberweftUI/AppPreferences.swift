import Foundation
import FlameKit

/// User-facing app settings, persisted as JSON in the app-support directory
/// (`~/Library/Application Support/Emberweft/preferences.json`). Chosen over
/// `UserDefaults`: typed + `Sendable`, shareable with the M5 screensaver via a
/// known file location, and one app-support dir to own alongside the thumbnail
/// cache. Decode failure is resilient (defaults + quarantine the bad file).
public struct AppPreferences: Codable, Sendable, Equatable {

    public var qualityPreset: QualityPreset
    public var targetFPS: Int
    /// Used only when `qualityPreset` is a future `.custom` (currently unused;
    /// kept so the settings UI can grow without a schema change).
    public var defaultSamplesPerPixel: Int
    public var backend: Backend
    /// Backend used for THUMBNAIL rendering. Defaults to `.metal`: the thumbnail
    /// path uses `MetalRenderer.renderOffMain` (a background-queue render that
    /// never touches the MainActor), so Metal thumbnails are fast AND don't
    /// freeze the UI. `.cpu` is also off-main but much slower per thumbnail.
    public var thumbnailBackend: Backend
    /// Last "Open Directory…" target, remembered across launches. `nil` ⇒ only
    /// the bundled curated set is shown.
    public var defaultLibraryDir: URL?
    /// Thumbnail DISPLAY size (the cell image). The render happens at a higher
    /// resolution (`thumbnailRenderWidth/Height`) and is downscaled for a crisp
    /// thumbnail — better viewpoint than rendering at display size directly.
    public var thumbnailWidth: Int
    public var thumbnailHeight: Int
    /// Thumbnail RENDER resolution (downscaled to `thumbnailWidth/Height`). 480p
    /// is the default: fast enough on CPU (~50 ms) to fill the grid smoothly,
    /// and ~3× supersampled over the display size for a crisp thumbnail.
    public var thumbnailRenderWidth: Int
    public var thumbnailRenderHeight: Int
    /// Low, deterministic thumbnail sample count (GPU/CPU-deterministic, rule #2).
    public var thumbnailSPP: Int
    /// Fast/low sample count for realtime playback preview (keeps frame time
    /// small so playback is closer to real time). Independent of the quality
    /// preset, which governs full-quality / export rendering.
    public var previewSamplesPerPixel: Int
    /// Internal render resolution for the playback preview. The `CAMetalLayer`
    /// scales this to the window (`.resizeAspect`), so a smaller internal buffer
    /// is a cheap speedup with minor softness. 480p default.
    public var previewWidth: Int
    public var previewHeight: Int
    /// Fixed render seed for determinism (rule #2).
    public var seed: UInt64

    /// Library grid density (B11) — drives the adaptive `LazyVGrid` cell minimum
    /// (small/medium/large → 140/180/240 pt). Additive; persisted with the rest of
    /// `AppPreferences` via the `.onChange(of: model.prefs)` save.
    public var density: Density

    public init(
        qualityPreset: QualityPreset = .medium,
        targetFPS: Int = 60,
        defaultSamplesPerPixel: Int = 8,
        backend: Backend = .metal,
        thumbnailBackend: Backend = .metal,
        defaultLibraryDir: URL? = nil,
        thumbnailWidth: Int = 256,
        thumbnailHeight: Int = 144,
        thumbnailRenderWidth: Int = 1280,
        thumbnailRenderHeight: Int = 720,
        thumbnailSPP: Int = 8,
        previewSamplesPerPixel: Int = 2,
        previewWidth: Int = 854,
        previewHeight: Int = 480,
        seed: UInt64 = 1,
        density: Density = .medium
    ) {
        self.qualityPreset = qualityPreset
        self.targetFPS = targetFPS
        self.defaultSamplesPerPixel = defaultSamplesPerPixel
        self.backend = backend
        self.thumbnailBackend = thumbnailBackend
        self.defaultLibraryDir = defaultLibraryDir
        self.thumbnailWidth = thumbnailWidth
        self.thumbnailHeight = thumbnailHeight
        self.thumbnailRenderWidth = thumbnailRenderWidth
        self.thumbnailRenderHeight = thumbnailRenderHeight
        self.thumbnailSPP = thumbnailSPP
        self.previewSamplesPerPixel = previewSamplesPerPixel
        self.previewWidth = previewWidth
        self.previewHeight = previewHeight
        self.seed = seed
        self.density = density
    }

    // MARK: - Codable (additive: `density` defaults when absent)

    /// Explicit CodingKeys so a custom `init(from:)` can decode `density`
    /// additively. `encode(to:)` stays synthesized from these keys.
    private enum CodingKeys: String, CodingKey {
        case qualityPreset, targetFPS, defaultSamplesPerPixel, backend, thumbnailBackend
        case defaultLibraryDir, thumbnailWidth, thumbnailHeight
        case thumbnailRenderWidth, thumbnailRenderHeight, thumbnailSPP
        case previewSamplesPerPixel, previewWidth, previewHeight, seed, density
    }

    /// Decodes all fields; `density` (added in B11) falls back to `.medium` when
    /// absent, so an older `preferences.json` loads without a schema break or
    /// quarantine (rule: density is purely additive). All other fields stay
    /// required exactly as the previous synthesized decoder required them.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.qualityPreset = try c.decode(AppPreferences.QualityPreset.self, forKey: .qualityPreset)
        self.targetFPS = try c.decode(Int.self, forKey: .targetFPS)
        self.defaultSamplesPerPixel = try c.decode(Int.self, forKey: .defaultSamplesPerPixel)
        self.backend = try c.decode(AppPreferences.Backend.self, forKey: .backend)
        self.thumbnailBackend = try c.decode(AppPreferences.Backend.self, forKey: .thumbnailBackend)
        self.defaultLibraryDir = try c.decodeIfPresent(URL.self, forKey: .defaultLibraryDir)
        self.thumbnailWidth = try c.decode(Int.self, forKey: .thumbnailWidth)
        self.thumbnailHeight = try c.decode(Int.self, forKey: .thumbnailHeight)
        self.thumbnailRenderWidth = try c.decode(Int.self, forKey: .thumbnailRenderWidth)
        self.thumbnailRenderHeight = try c.decode(Int.self, forKey: .thumbnailRenderHeight)
        self.thumbnailSPP = try c.decode(Int.self, forKey: .thumbnailSPP)
        self.previewSamplesPerPixel = try c.decode(Int.self, forKey: .previewSamplesPerPixel)
        self.previewWidth = try c.decode(Int.self, forKey: .previewWidth)
        self.previewHeight = try c.decode(Int.self, forKey: .previewHeight)
        self.seed = try c.decode(UInt64.self, forKey: .seed)
        self.density = try c.decodeIfPresent(AppPreferences.Density.self, forKey: .density) ?? .medium
    }

    /// Build full-window `RenderParams` for a given view size, using the preset's
    /// sample budget. `spatialFilterRadius` defaults to 0.5 (flam3 default); the
    /// renderer threads `flame.quality.filterRadius` in regardless.
    public func renderParams(width: Int, height: Int) -> RenderParams {
        RenderParams(
            seed: seed,
            width: max(width, 1),
            height: max(height, 1),
            oversample: qualityPreset.oversample,
            samplesPerPixel: qualityPreset.samplesPerPixel
        )
    }

    /// Thumbnail `RenderParams` at the high render resolution (the result is
    /// downscaled to `thumbnailWidth/Height` by the thumbnail service).
    public func thumbnailRenderParams() -> RenderParams {
        RenderParams(
            seed: seed,
            width: max(thumbnailRenderWidth, 1),
            height: max(thumbnailRenderHeight, 1),
            oversample: 1,
            samplesPerPixel: max(thumbnailSPP, 1)
        )
    }

    /// Fast/low-quality `RenderParams` for realtime playback preview — renders at
    /// `previewWidth × previewHeight` (the layer scales it to the window) with low
    /// spp so each frame is cheap and playback sustains the target fps.
    public func previewParams() -> RenderParams {
        RenderParams(
            seed: seed,
            width: max(previewWidth, 1),
            height: max(previewHeight, 1),
            oversample: 1,
            samplesPerPixel: max(previewSamplesPerPixel, 1)
        )
    }

    // MARK: - Persistence

    /// `~/Library/Application Support/Emberweft/`.
    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Emberweft", isDirectory: true)
    }

    private static var preferencesFileURL: URL {
        defaultDirectory.appendingPathComponent("preferences.json")
    }

    /// Load from `directory` (default: app-support). Missing ⇒ defaults + write.
    /// Corrupt ⇒ defaults + rename the bad file to `preferences.json.corrupt-<ts>`.
    public static func load(directory: URL = defaultDirectory) -> AppPreferences {
        let url = directory.appendingPathComponent("preferences.json")
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let prefs = try? JSONDecoder().decode(AppPreferences.self, from: data)
        else {
            // Missing OR corrupt-but-unreadable → defaults. (An unreadable file
            // is left in place; a *decoded* JSONDecoder failure is quarantined
            // below — handled in `loadResilient`.)
            return AppPreferences()
        }
        return prefs
    }

    /// Load with explicit corrupt-file quarantine (returns defaults + the renamed
    /// file URL when the file exists but won't decode). Use this from the app.
    public static func loadResilient(directory: URL = defaultDirectory) -> (prefs: AppPreferences, quarantined: URL?) {
        let url = directory.appendingPathComponent("preferences.json")
        if !FileManager.default.fileExists(atPath: url.path) {
            return (AppPreferences(), nil)
        }
        guard let data = try? Data(contentsOf: url) else {
            return (AppPreferences(), nil)
        }
        do {
            let prefs = try JSONDecoder().decode(AppPreferences.self, from: data)
            return (prefs, nil)
        } catch {
            let corrupt = directory.appendingPathComponent(
                "preferences.json.corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: url, to: corrupt)
            return (AppPreferences(), corrupt)
        }
    }

    /// Atomically write to `directory/preferences.json` (sorted keys for
    /// byte-stable diffs). Creates the directory if needed.
    public func save(directory: URL = defaultDirectory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(self)
        let url = directory.appendingPathComponent("preferences.json")
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Nested types

    public enum Backend: String, Codable, CaseIterable, Sendable {
        case cpu, metal
    }

    public enum QualityPreset: String, Codable, CaseIterable, Sendable {
        case low, medium, high

        public var samplesPerPixel: Int {
            switch self {
            case .low: return 2
            case .medium: return 8
            case .high: return 30
            }
        }
        public var oversample: Int {
            switch self {
            case .low, .medium: return 1
            case .high: return 2
            }
        }
    }

    /// Library grid density (B11 / spec §5.7). Maps to the adaptive `LazyVGrid`
    /// cell minimum width: small=140, medium=180, large=240 pt.
    public enum Density: String, Codable, CaseIterable, Sendable {
        case small, medium, large

        /// Adaptive grid cell minimum width (points).
        public var gridMinimum: CGFloat {
            switch self {
            case .small: return 140
            case .medium: return 180
            case .large: return 240
            }
        }
        /// One-letter label for the segmented control (S / M / L).
        public var glyph: String {
            switch self {
            case .small: return "S"
            case .medium: return "M"
            case .large: return "L"
            }
        }
    }
}
