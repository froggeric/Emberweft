// Sources/FlameFlock/FlockTypes.swift
import Foundation
import FlameExport   // ExportSettings.Codec (FlameFlock depends on FlameExport)

/// Value types for the flock catalog (spec §6). All are plain immutable structs
/// (`Codable + Sendable + Equatable`); set-like / multi-valued fields are stored
/// SORTED wherever used (rule #2 — no FP accumulation over hashed collections,
/// no order-dependence on `Dictionary`/`Set`). The codec reuses
/// `ExportSettings.Codec` (single source of truth; D12 fixes HEVC archive-wide).

/// A render shard (spec §6 `shards` row). The shard directory name encodes
/// resolution + fps (+ pace iff non-canonical); one shard = one render profile.
public struct ShardSpec: Codable, Sendable, Equatable {
    public var name: String             // dir name, e.g. "1920x1080_30fps"
    public var width: Int
    public var height: Int
    public var fps: Int
    public var loopSeconds: Double
    public var transSeconds: Double
    public var loopFrames: Int
    public var transFrames: Int
    public var isCanonical: Bool        // true iff 15s loops / 12s transitions
    public var codec: ExportSettings.Codec

    public init(name: String, width: Int, height: Int, fps: Int,
                loopSeconds: Double, transSeconds: Double,
                loopFrames: Int, transFrames: Int,
                isCanonical: Bool, codec: ExportSettings.Codec) {
        self.name = name; self.width = width; self.height = height; self.fps = fps
        self.loopSeconds = loopSeconds; self.transSeconds = transSeconds
        self.loopFrames = loopFrames; self.transFrames = transFrames
        self.isCanonical = isCanonical; self.codec = codec
    }
}

/// A sheep identity row (spec §6 `sheep` table). ES-sourced sheep keep their
/// real `(gen,id)`; user/curated/imports get minted ids in reserved flock
/// `900000` (T8). `origin` makes the ES/minted split unambiguous (D7).
public struct Sheep: Codable, Sendable, Equatable {
    public enum Origin: String, Codable, Sendable, Equatable { case es, user }

    public var gen: String              // ES gen ('248') or '900000' (Emberweft)
    public var id: String               // ES id verbatim, or minted 6-digit
    public var origin: Origin
    public var sourceRef: String?       // .flam3 URL/path (nil if unknown)
    public var sourceSha: String?       // SHA-256 of source bytes (re-render identity)
    public var displayName: String?
    public var addedAt: Int             // timeIntervalSince1970

    public init(gen: String, id: String, origin: Origin,
                sourceRef: String?, sourceSha: String?,
                displayName: String?, addedAt: Int) {
        self.gen = gen; self.id = id; self.origin = origin
        self.sourceRef = sourceRef; self.sourceSha = sourceSha
        self.displayName = displayName; self.addedAt = addedAt
    }
}

/// A rendered artifact (spec §6 `artifacts` row). The composite PK
/// `(a_gen,a_id,b_gen,b_id,shard)` IS the cache key (D2). A loop is a self-edge
/// (a==b); an edge has distinct endpoints.
public struct ArtifactRow: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, Equatable { case loop, edge }

    public var aGen: String
    public var aId: String
    public var bGen: String
    public var bId: String
    public var shard: String            // FK shards.name
    public var kind: Kind               // .loop iff a==b
    public var file: String             // path under flock-root
    /// Seam-aware loop geometry (M6.5): a loop unit is TWO files — the CORE
    /// (`file`, phases `[h, L−h)`) and the WRAP (`wrapFile`, the periodic-boundary
    /// frames `[L−h, L) ∪ [0, h)`). Nil for edges and pre-seam-aware rows.
    /// See `ArchiveRenderer.SeamGeometry` for why the split exists.
    public var wrapFile: String?
    /// Seam-geometry version of the artifact's FILE(S) (1 = legacy monolithic
    /// loop/edge, 2 = seam-aware core+wrap / boundary-extended edge). An EXACT
    /// gate (like `codec`): a stitch/generate request only HITs rows whose
    /// geometry matches — mixing geometries in one timeline breaks phase
    /// continuity. Rows written before the fix decode as 1 and re-render.
    public var geom: Int
    /// Framing mode the artifact's files were rendered with (0 = faithful /
    /// legacy pre-M6.6 framing, 1 = normalized M6.6 framing). An EXACT gate
    /// (like `codec`): a generate/stitch request only HITs rows whose framing
    /// matches `request.settings.framing` — mixing framings in one archive
    /// crops differently at the same resolution. Rows written before M6.6
    /// decode as 0 and re-render for normalized requests.
    public var framing: Int
    public var thumb: String?           // relative jpeg path
    public var width: Int
    public var height: Int
    public var fps: Int
    public var loopFrames: Int
    public var transFrames: Int
    public var spp: Int
    public var temporal: Int
    public var smoothing: String        // "off" | "auto"
    public var smoothingHw: Int
    public var qualityRank: Double      // effective sampling (upgrade ordering)
    public var bytes: Int
    public var renderedAt: Int          // timeIntervalSince1970
    public var sourceSha: String?       // SHA of source genome(s) (re-render identity)
    public var seed: Int                // deterministic seed used (§10)
    public var codec: ExportSettings.Codec

    public init(aGen: String, aId: String, bGen: String, bId: String,
                shard: String, kind: Kind, file: String, wrapFile: String? = nil,
                geom: Int = 1, framing: Int = 0, thumb: String?,
                width: Int, height: Int, fps: Int,
                loopFrames: Int, transFrames: Int,
                spp: Int, temporal: Int, smoothing: String, smoothingHw: Int,
                qualityRank: Double, bytes: Int, renderedAt: Int,
                sourceSha: String?, seed: Int, codec: ExportSettings.Codec) {
        self.aGen = aGen; self.aId = aId; self.bGen = bGen; self.bId = bId
        self.shard = shard; self.kind = kind; self.file = file; self.wrapFile = wrapFile
        self.geom = geom; self.framing = framing; self.thumb = thumb
        self.width = width; self.height = height; self.fps = fps
        self.loopFrames = loopFrames; self.transFrames = transFrames
        self.spp = spp; self.temporal = temporal
        self.smoothing = smoothing; self.smoothingHw = smoothingHw
        self.qualityRank = qualityRank; self.bytes = bytes; self.renderedAt = renderedAt
        self.sourceSha = sourceSha; self.seed = seed; self.codec = codec
    }
}

/// Value-type snapshot of catalog counts for GUI reads (`FlockModel.refresh`
/// hops onto the catalog actor and returns this). The GUI never reads SQLite
/// directly (spec §6 concurrency).
public struct FlockSnapshot: Codable, Sendable, Equatable {
    public var shardCount: Int
    public var artifactCount: Int
    public init(shardCount: Int, artifactCount: Int) {
        self.shardCount = shardCount; self.artifactCount = artifactCount
    }
}
