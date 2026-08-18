import Foundation
import FlameKit

/// User-facing export settings (Codable + Sendable). The encode-quality source is
/// `ExportQuality` (`.genome` default — byte-matches `animate`; `.spp(N)`).
public struct ExportSettings: Codable, Sendable, Equatable {
    public var codec: Codec = .h264
    public var resolution: Resolution = .p1080
    public var fps: Int = 30                 // 24/25/30/48/50/60 (CMTime timescale)
    public var quality: ExportQuality = .genome
    public var temporalSamples: Int = 1      // motion blur (1 = sharp)
    public var container: Container = .mp4
    public var bitrate: Bitrate = .auto
    public var segmentFrameBudget: Int = 0   // >0 => long-form chunk size in frames
    public var metadata: [MetadataItem] = []
    /// User-facing temporal-smoothing choice (M6.1 slice 2). `.auto` ⇒ derive α
    /// from `quality` via `TemporalSmoothing.alpha(for:)`; `.off` ⇒ α = 1.0 (OFF).
    /// Rides in the resume checkpoint via `settings` (this whole struct encodes),
    /// so α reproduces on resume for free — no schema bump.
    public var temporalSmoothing: TemporalSmoothing = .auto
    /// Resolved EMA weight α ∈ (0, 1] (1.0 = OFF / byte-identical unsmoothed).
    /// Resolved ONCE at `resolve(…)`-build time from the quality tier (R3), so the
    /// renderers read a single concrete number with no inverse-tier lookup or
    /// `EmberweftUI` dependency from `FlameExport`.
    public var smoothingAlpha: Double = 1.0
    /// M6.6 framing: `.faithful` uses `camera.scale` verbatim (today's bytes,
    /// `animate` behavior); `.normalized` rescales to the render width via
    /// `FlameKit.Framing` (authored framing at any resolution). TYPE default is
    /// `.faithful` so raw settings + legacy checkpoints keep their bytes; the
    /// product entry points (GUI sheet, GUI flock, CLI export/flock) default
    /// `.normalized`. `animate` has no framing — always faithful.
    public var framing: FramingMode = .faithful
    public init() {}

    /// P1.1 backward-compat: a v0.5.1 checkpoint blob (no `temporalSmoothing` /
    /// `smoothingAlpha` keys) MUST decode without throwing. We decode the two new
    /// fields via `decodeIfPresent` and default them to `.auto` and the
    /// `.auto`-tier α recomputed from the DECODED quality (so a stripped v0.5.1
    /// blob lands in the right tier, not a stale 1.0).
    ///
    /// NOTE: this is the ONLY custom Codable requirement — `CodingKeys` and
    /// `encode(to:)` stay SYNTHESIZED (the new fields are plain `var … = default`,
    /// so they encode normally). Defining an explicit `CodingKeys` here would
    /// force a hand-written `encode(to:)` for every field — avoided (round-trip is
    /// pinned by `testRoundTripPreservesSmoothingFields`).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        codec = try c.decode(ExportSettings.Codec.self, forKey: .codec)
        resolution = try c.decode(ExportSettings.Resolution.self, forKey: .resolution)
        fps = try c.decode(Int.self, forKey: .fps)
        quality = try c.decode(ExportQuality.self, forKey: .quality)
        temporalSamples = try c.decode(Int.self, forKey: .temporalSamples)
        container = try c.decode(ExportSettings.Container.self, forKey: .container)
        bitrate = try c.decode(ExportSettings.Bitrate.self, forKey: .bitrate)
        segmentFrameBudget = try c.decode(Int.self, forKey: .segmentFrameBudget)
        metadata = try c.decode([MetadataItem].self, forKey: .metadata)
        temporalSmoothing = try c.decodeIfPresent(TemporalSmoothing.self, forKey: .temporalSmoothing) ?? .auto
        smoothingAlpha = try c.decodeIfPresent(Double.self, forKey: .smoothingAlpha)
            ?? TemporalSmoothing.auto.alpha(for: quality)
        framing = try c.decodeIfPresent(FramingMode.self, forKey: .framing) ?? .faithful
    }

    public enum Codec: String, Codable, Sendable, CaseIterable { case h264, hevc, proRes422HQ }
    public enum Container: String, Codable, Sendable, CaseIterable { case mp4, mov }
    public enum FramingMode: String, Codable, Sendable, Equatable, CaseIterable { case faithful, normalized }
    public enum Bitrate: Codable, Sendable, Equatable { case auto; case mbps(Int) }
    public struct MetadataItem: Codable, Sendable, Equatable {
        public var key: String; public var value: String
        public init(key: String, value: String) { self.key = key; self.value = value }
    }

    public enum Resolution: Codable, Sendable, Equatable, Hashable {
        case p720, p1080, p1440, p4k, custom(width: Int, height: Int)
        public var width: Int {
            switch self { case .p720: 1280; case .p1080: 1920; case .p1440: 2560;
                         case .p4k: 3840; case .custom(let w, _): w } }
        public var height: Int {
            switch self { case .p720: 720; case .p1080: 1080; case .p1440: 1440;
                         case .p4k: 2160; case .custom(_, let h): h } }
    }
}

/// M6 quality source. Named tiers are deferred to the GUI export-sheet slice.
/// Both modes resolve `oversample = 1` (byte-identity with `animate`).
public enum ExportQuality: Codable, Sendable, Equatable {
    case genome                              // flames[0].quality.samplesPerPixel, oversample 1
    case spp(Int)

    public func resolvedSamplesPerPixel(for baseFlame: Flame) -> (spp: Int, oversample: Int) {
        switch self {
        case .genome: (baseFlame.quality.samplesPerPixel, 1)
        case .spp(let n): (n, 1)
        }
    }
}

public extension ExportSettings.Codec {
    /// True for ProRes variants (the mastering codec). ProRes is a fixed
    /// data-rate codec: it does NOT use the bitrate table and its `.mov`
    /// container is mandatory (AVAssetWriter rejects ProRes in `.mp4`).
    public var isProRes: Bool { self == .proRes422HQ }

    /// True iff this codec can ONLY be muxed into a `.mov` container.
    /// ProRes 422 HQ requires `.mov` (AVAssetWriter fails ProRes in `.mp4`).
    public var requiresMOVContainer: Bool { isProRes }
}

public extension ExportSettings {
    /// Metal temporal-samples cap (dispatch-overhead bound). The single source of
    /// truth: `resolve` applies it and the CLI/GUI cap-notice logic reads it, so
    /// the two cannot drift apart.
    public static let metalTemporalCap = 64

    /// Resolve a concrete `ExportSettings` from PARSED CLI/GUI inputs, applying:
    ///  - the motion-blur genome-default fallback: `requestedTS == 1` and
    ///    `baseFlame.quality.temporalSamples > 1` ⇒ use the genome value (mirrors
    ///    `AnimateCommand.swift:147-149` and `ExportCommand.swift:374-377` exactly);
    ///  - the Metal temporal cap (64) when `backend == .metal`
    ///    (`ExportCommand.swift:378-382`) to bound dispatch overhead.
    ///
    /// `baseFlame` MUST be the first RENDERABLE flame (the CLI passes
    /// `renderable[0]`, ExportCommand.swift:375; the GUI pre-filters, so its
    /// `flames[0]` is already renderable). Using the unfiltered `flames[0]` here
    /// would diverge from the CLI when `flames[0]` is degenerate — byte-identity
    /// requires the renderable first flame.
    ///
    /// PURE + SILENT: no I/O, no stderr. The caller detects the Metal cap by
    /// comparing `requestedTS` against the returned `temporalSamples` and prints
    /// its own notice (CLI: `EmberweftCLI.err(…)`; GUI: a sheet notice). This is
    /// the single source of truth so the CLI and GUI build byte-identical jobs
    /// (spec §4.2b / plan task M6-G.3 / defect D-G2).
    ///
    /// String→enum parsing STAYS in the callers: the CLI parses strings (incl.
    /// the `quality`-number → `fallbackFlame.quality.samplesPerPixel` defensive
    /// fallback and the `resolution` unknown → `.p1080` default), and the GUI
    /// builds enums directly from its pickers. Neither can live here because
    /// `FlameExport` does not depend on `EmberweftCLI` (and the GUI has no
    /// strings to parse).
    static func resolve(
        quality: ExportQuality,
        temporalSamples requestedTS: Int,
        codec: ExportSettings.Codec,
        container: ExportSettings.Container,
        fps: Int,
        bitrate: ExportSettings.Bitrate,
        resolution: ExportSettings.Resolution,
        segmentFrameBudget: Int,
        baseFlame: Flame,
        backend: ExportCoordinator.Backend,
        temporalSmoothing: TemporalSmoothing = .auto
    ) -> ExportSettings {
        var settings = ExportSettings()
        settings.codec = codec
        settings.container = container
        settings.fps = fps
        settings.quality = quality
        // M6.1 slice 2: carry the smoothing decision + resolve α ONCE here from
        // the quality tier (R3 — α for ANY spp via the ramp; no inverse-tier
        // lookup). The default `.auto` keeps the ~8 test + 2 production
        // `resolve(…)` call sites compiling unchanged; threading the user's
        // actual toggle is T10 (GUI) / T11 (CLI).
        settings.temporalSmoothing = temporalSmoothing
        settings.smoothingAlpha = temporalSmoothing.alpha(for: quality)
        // Motion-blur default: the "use genome default" sentinel (ts=1) applies
        // ONLY to genome-default quality (the mastering path — mirrors `animate`,
        // byte-identical). For the NAMED tiers (.spp), ts=1 is LITERAL single-pass
        // (v0.5.4: the genome's ~1000→Metal-capped-64 ts was wasteful at low spp —
        // +136% at spp 8, +35% at spp 30 — for within-frame motion blur that's
        // invisible on slow ambient loops). The user can still raise ts explicitly
        // for motion blur. Genome-default + ts=1 still resolves to the genome's ts.
        var ts = max(1, requestedTS)
        if quality == .genome, ts == 1, baseFlame.quality.temporalSamples > 1 {
            ts = baseFlame.quality.temporalSamples
        }
        if backend == .metal, ts > Self.metalTemporalCap {
            ts = Self.metalTemporalCap
        }
        settings.temporalSamples = ts
        settings.bitrate = bitrate
        settings.resolution = resolution
        settings.segmentFrameBudget = max(0, segmentFrameBudget)
        return settings
    }
}
