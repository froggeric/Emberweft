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
    /// Opened library folders, in first-added order and deduped by standardized
    /// path. Persisted so the user's chosen folders survive across launches.
    /// Empty ⇒ only the bundled curated set is shown. Replaces the legacy
    /// single-slot `defaultLibraryDir`; an existing single folder is migrated on
    /// decode (see `init(from:)`) so no previously opened folder is lost.
    public var directorySources: [URL]
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
    /// Preview oversample — used ONLY when `previewPreset == .custom`. The named
    /// presets (`draft`/`balanced`/`quality`) carry their own oversample. Default 1.
    public var previewOversample: Int
    /// Realtime-preview quality preset (M4 final). `.custom` falls back to the
    /// individual `previewWidth`/`previewHeight`/`previewSamplesPerPixel`/
    /// `previewOversample` fields; the named presets derive all four from the
    /// preset and ignore those fields. Default `.draft` (854×480, spp=2, os=1),
    /// which is byte-identical to the pre-preset preview, so a legacy
    /// `preferences.json` is behavior-preserving on upgrade. The preset→params
    /// mapping is deterministic (rule #2); live FPS is a separate diagnostic.
    public var previewPreset: PreviewPreset
    /// Fixed render seed for determinism (rule #2).
    public var seed: UInt64

    /// Library grid density (B11) — drives the adaptive `LazyVGrid` cell minimum
    /// (small/medium/large → 140/180/240 pt). Additive; persisted with the rest of
    /// `AppPreferences` via the `.onChange(of: model.prefs)` save.
    public var density: Density

    /// M6.1 D4: the most recent paused-export checkpoint URL, remembered across
    /// relaunches so the banner can re-offer Resume/Discard after a quit/crash.
    /// Additive (decodes as nil for older prefs files without the key — P11).
    /// `ExportManager` owns the runtime mutations via its `writeRememberedCheckpointURL`
    /// hook (which writes back here + saves); this field is the persisted source
    /// AppModel seeds the VM from at launch.
    public var rememberedCheckpointURL: URL?

    /// M6.5 T18: the Flock archive root folder (`<…>/Flock/` holding the
    /// shard `.mov`s + `flock.sqlite`). When nil the default
    /// `<app-support>/Emberweft/Flock` is resolved at use (see `AppModel.flockRoot`).
    /// Additive (decodes as nil for older prefs files without the key — mirrors
    /// `rememberedCheckpointURL`).
    public var flockDir: URL?

    /// M6.5: the shard NAME the Flock Generate/Stitch tabs start from — a
    /// `ShardPresets` name (`"1920x1080_30fps"`, …) or any catalog shard name.
    /// nil ⇒ the canonical default (1080p30) is resolved by the tabs. A stored
    /// name that no longer exists also falls back to the canonical default.
    /// Additive (decodes as nil for older prefs files — mirrors `flockDir`).
    public var flockDefaultShard: String?

    public init(
        qualityPreset: QualityPreset = .medium,
        targetFPS: Int = 60,
        defaultSamplesPerPixel: Int = 8,
        backend: Backend = .metal,
        thumbnailBackend: Backend = .metal,
        directorySources: [URL] = [],
        thumbnailWidth: Int = 256,
        thumbnailHeight: Int = 144,
        thumbnailRenderWidth: Int = 1280,
        thumbnailRenderHeight: Int = 720,
        thumbnailSPP: Int = 8,
        previewSamplesPerPixel: Int = 2,
        previewWidth: Int = 854,
        previewHeight: Int = 480,
        previewOversample: Int = 1,
        previewPreset: PreviewPreset = .draft,
        seed: UInt64 = 1,
        density: Density = .medium,
        rememberedCheckpointURL: URL? = nil,
        flockDir: URL? = nil,
        flockDefaultShard: String? = nil
    ) {
        self.qualityPreset = qualityPreset
        self.targetFPS = targetFPS
        self.defaultSamplesPerPixel = defaultSamplesPerPixel
        self.backend = backend
        self.thumbnailBackend = thumbnailBackend
        self.directorySources = Self.dedupe(directorySources)
        self.thumbnailWidth = thumbnailWidth
        self.thumbnailHeight = thumbnailHeight
        self.thumbnailRenderWidth = thumbnailRenderWidth
        self.thumbnailRenderHeight = thumbnailRenderHeight
        self.thumbnailSPP = thumbnailSPP
        self.previewSamplesPerPixel = previewSamplesPerPixel
        self.previewWidth = previewWidth
        self.previewHeight = previewHeight
        self.previewOversample = previewOversample
        self.previewPreset = previewPreset
        self.seed = seed
        self.density = density
        self.rememberedCheckpointURL = rememberedCheckpointURL
        self.flockDir = flockDir
        self.flockDefaultShard = flockDefaultShard
    }

    // MARK: - Codable (additive: `density` defaults when absent; legacy
    //          `defaultLibraryDir` migrates into `directorySources`)

    /// CodingKeys mirror the stored properties exactly so `encode(to:)` stays
    /// synthesized. The legacy `defaultLibraryDir` field is NOT a stored property
    /// — it lives in `LegacyKey` below and is decoded one-way for migration only
    /// (never re-encoded), so round-trips drop it cleanly.
    private enum CodingKeys: String, CodingKey {
        case qualityPreset, targetFPS, defaultSamplesPerPixel, backend, thumbnailBackend
        case directorySources, thumbnailWidth, thumbnailHeight
        case thumbnailRenderWidth, thumbnailRenderHeight, thumbnailSPP
        case previewSamplesPerPixel, previewWidth, previewHeight
        case previewOversample, previewPreset, seed, density
        case rememberedCheckpointURL
        case flockDir
        case flockDefaultShard
    }

    /// Legacy key kept ONLY for one-way migration from the pre-multi-folder
    /// single-slot `defaultLibraryDir`. Decoded via a second container when
    /// `directorySources` is absent/empty; never encoded.
    private enum LegacyKey: String, CodingKey { case defaultLibraryDir }

    /// Decodes all fields with two additive fallbacks, so any older
    /// `preferences.json` loads without a schema break or quarantine:
    ///   - `density` (added in B11) → `.medium` when absent;
    ///   - `directorySources` (multi-folder) → migrates the legacy
    ///     `defaultLibraryDir` single folder in when absent/empty, so a previously
    ///     opened folder is never lost on upgrade.
    /// `directorySources` is deduped by standardized path (deterministic, rule #2).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.qualityPreset = try c.decode(AppPreferences.QualityPreset.self, forKey: .qualityPreset)
        self.targetFPS = try c.decode(Int.self, forKey: .targetFPS)
        self.defaultSamplesPerPixel = try c.decode(Int.self, forKey: .defaultSamplesPerPixel)
        self.backend = try c.decode(AppPreferences.Backend.self, forKey: .backend)
        self.thumbnailBackend = try c.decode(AppPreferences.Backend.self, forKey: .thumbnailBackend)
        var dirs = try c.decodeIfPresent([URL].self, forKey: .directorySources) ?? []
        if dirs.isEmpty {
            // Migrate the legacy single-slot field rather than lose it.
            let legacy = try decoder.container(keyedBy: LegacyKey.self)
            if let single = try legacy.decodeIfPresent(URL.self, forKey: .defaultLibraryDir) {
                dirs = [single]
            }
        }
        self.directorySources = Self.dedupe(dirs)
        self.thumbnailWidth = try c.decode(Int.self, forKey: .thumbnailWidth)
        self.thumbnailHeight = try c.decode(Int.self, forKey: .thumbnailHeight)
        self.thumbnailRenderWidth = try c.decode(Int.self, forKey: .thumbnailRenderWidth)
        self.thumbnailRenderHeight = try c.decode(Int.self, forKey: .thumbnailRenderHeight)
        self.thumbnailSPP = try c.decode(Int.self, forKey: .thumbnailSPP)
        self.previewSamplesPerPixel = try c.decode(Int.self, forKey: .previewSamplesPerPixel)
        self.previewWidth = try c.decode(Int.self, forKey: .previewWidth)
        self.previewHeight = try c.decode(Int.self, forKey: .previewHeight)
        self.previewOversample = try c.decodeIfPresent(Int.self, forKey: .previewOversample) ?? 1
        self.previewPreset = try c.decodeIfPresent(PreviewPreset.self, forKey: .previewPreset) ?? .draft
        self.seed = try c.decode(UInt64.self, forKey: .seed)
        self.density = try c.decodeIfPresent(AppPreferences.Density.self, forKey: .density) ?? .medium
        // M6.1 D4: additive — older prefs without the key decode to nil (P11).
        self.rememberedCheckpointURL = try c.decodeIfPresent(URL.self, forKey: .rememberedCheckpointURL)
        // M6.5 T18: additive — older prefs without the key decode to nil.
        self.flockDir = try c.decodeIfPresent(URL.self, forKey: .flockDir)
        // M6.5: additive — same pattern as `flockDir` above.
        self.flockDefaultShard = try c.decodeIfPresent(String.self, forKey: .flockDefaultShard)
    }

    // MARK: - Directory sources (multi-folder)

    /// Order-preserving dedup by standardized path (deterministic — rule #2: the
    /// `Set` is membership-only; the result keeps the input's order minus dupes).
    public static func dedupe(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var out: [URL] = []
        for u in urls {
            if seen.insert(u.standardizedFileURL.path).inserted { out.append(u) }
        }
        return out
    }

    /// Append `url` unless an equivalent folder (by standardized path) is already
    /// opened. Idempotent. Callers persist via `save()`.
    public mutating func addDirectorySource(_ url: URL) {
        let key = url.standardizedFileURL.path
        guard !directorySources.contains(where: { $0.standardizedFileURL.path == key }) else { return }
        directorySources.append(url)
    }

    /// Drop the folder matching `url` (by standardized path), if present. Only
    /// mutates this preference list — it does NOT touch any file on disk.
    public mutating func removeDirectorySource(_ url: URL) {
        let key = url.standardizedFileURL.path
        directorySources.removeAll { $0.standardizedFileURL.path == key }
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

    /// Fast/low-quality `RenderParams` for realtime playback preview — the layer
    /// scales the internal buffer to the window, so a smaller buffer + low spp keeps
    /// each frame cheap. The `previewPreset` selects the buffer/spp/oversample:
    /// `.custom` uses the individual `previewWidth/Height/SamplesPerPixel/Oversample`
    /// fields; the named presets derive all four (deterministic, rule #2). Default
    /// `.draft` (854×480 · 2 spp · 1×) is byte-identical to the pre-preset preview.
    public func previewParams() -> RenderParams {
        let w: Int, h: Int, spp: Int, os: Int
        switch previewPreset {
        case .custom:
            w = previewWidth; h = previewHeight
            spp = previewSamplesPerPixel; os = previewOversample
        case .draft, .balanced, .quality:
            // Single source of truth: the preset's computed resolution/spp/os.
            w = previewPreset.resolution.width
            h = previewPreset.resolution.height
            spp = previewPreset.samplesPerPixel
            os = previewPreset.oversample
        }
        return RenderParams(
            seed: seed,
            width: max(w, 1),
            height: max(h, 1),
            oversample: max(os, 1),
            samplesPerPixel: max(spp, 1)
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

    /// Realtime-preview quality preset (M4 final). `.custom` defers to the
    /// individual `previewWidth`/`previewHeight`/`previewSamplesPerPixel`/
    /// `previewOversample` fields; the named presets carry fixed values (the
    /// `resolution`/`samplesPerPixel`/`oversample` computed props below — the
    /// single source of truth `previewParams()` reads). Display helpers
    /// (`label`/`detail`/`symbol`) drive the preset popover in both playback
    /// windows.
    public enum PreviewPreset: String, Codable, CaseIterable, Sendable, Equatable {
        case draft, balanced, quality, custom

        /// Buffer resolution (the `CAMetalLayer` scales it to the window).
        public var resolution: PreviewResolution {
            switch self {
            case .draft: return .p480
            case .balanced: return .p720
            case .quality: return .p1080
            case .custom: return .p480   // unused — `.custom` reads the raw fields
            }
        }
        public var samplesPerPixel: Int {
            switch self {
            case .draft: return 2
            case .balanced: return 8
            case .quality: return 16
            case .custom: return 2       // unused — `.custom` reads the raw fields
            }
        }
        public var oversample: Int {
            switch self {
            case .draft: return 1
            case .balanced: return 1
            case .quality: return 2
            case .custom: return 1       // unused — `.custom` reads the raw fields
            }
        }

        /// Capitalized display label.
        public var label: String {
            switch self {
            case .draft: return "Draft"
            case .balanced: return "Balanced"
            case .quality: return "Quality"
            case .custom: return "Custom"
            }
        }
        /// One-line spec for the popover row (resolution · spp · oversample).
        public var detail: String {
            switch self {
            case .draft: return "854×480 · 2 spp"
            case .balanced: return "1280×720 · 8 spp"
            case .quality: return "1920×1080 · 16 spp · 2×"
            case .custom: return "Custom values"
            }
        }
        /// SF Symbol for the popover row.
        public var symbol: String {
            switch self {
            case .draft: return "speedometer"
            case .balanced: return "sparkle"
            case .quality: return "wand.and.stars"
            case .custom: return "slider.horizontal.3"
            }
        }
    }

    /// Standard preview buffer tiers. The metal layer scales the buffer to the
    /// window (`.resizeAspect`), so users reason in tiers rather than free pixel
    /// sizes; arbitrary widths buy nothing. `nearest(to:)` maps a custom (w,h)
    /// back to the closest tier for the popover's resolution menu.
    public enum PreviewResolution: String, CaseIterable, Sendable, Equatable {
        case p480, p720, p1080, p1440, p4k

        public var width: Int {
            switch self {
            case .p480: return 854
            case .p720: return 1280
            case .p1080: return 1920
            case .p1440: return 2560
            case .p4k: return 3840
            }
        }
        public var height: Int {
            switch self {
            case .p480: return 480
            case .p720: return 720
            case .p1080: return 1080
            case .p1440: return 1440
            case .p4k: return 2160
            }
        }
        public var label: String {
            switch self {
            case .p480: return "480p"
            case .p720: return "720p"
            case .p1080: return "1080p"
            case .p1440: return "1440p"
            case .p4k: return "4K"
            }
        }
        /// Closest tier by pixel count to the given buffer size (deterministic;
        /// iterates the small fixed `allCases` array — rule #2 safe).
        public static func nearest(width w: Int, height h: Int) -> PreviewResolution {
            let target = Double(w) * Double(h)
            var best = PreviewResolution.p480
            var bestErr = Double.infinity
            for r in PreviewResolution.allCases {
                let err = abs(Double(r.width) * Double(r.height) - target)
                if err < bestErr { bestErr = err; best = r }
            }
            return best
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
