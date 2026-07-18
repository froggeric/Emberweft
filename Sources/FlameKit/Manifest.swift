import Foundation

/// F9 manifest schema: describes a rendered PNG sequence produced by
/// `emberweft animate`.
///
/// The manifest is written as `manifest.json` alongside the frame PNGs and
/// records, for every global frame index, which segment / sheep pair / blend
/// produced it. It is `Codable` so downstream tooling (the player, export
/// pipeline, or external scripts) can parse it directly.
///
/// # G2 byte-determinism
/// `Manifest` is a struct — the compiler-synthesized `Codable` encodes
/// properties in declaration order, and the `frames` array is built by
/// iterating the global frame index `0..<totalFrames` (F1). Two runs with the
/// same parameters therefore produce byte-identical `manifest.json` output.
public struct Manifest: Codable, Sendable, Equatable {
    /// Schema version. Increment on breaking changes.
    public let manifestVersion: Int
    /// Frames per segment (`N` in the blend formula).
    public let framesPerSegment: Int
    /// Number of segments rendered.
    public let segmentCount: Int
    /// Total PNGs emitted = `segmentCount * framesPerSegment`.
    public let totalFrames: Int
    /// Selector strategy used (`"sequential"` or `"similarity"`).
    public let selector: String
    /// Seed recorded for reproducibility.
    public let seed: UInt64
    /// Render backend (`"cpu"` or `"metal"`).
    public let backend: String
    /// Top-level stagger (per-xform transition desync); `0` disables it.
    public let stagger: Double
    /// Frame width in pixels.
    public let width: Int
    /// Frame height in pixels.
    public let height: Int
    /// Render quality (samplesPerPixel).
    public let quality: Int
    /// Ordered frame entries, indexed `0..<totalFrames` (F1 — never Set/Dict iteration).
    public let frames: [FrameEntry]

    public init(
        manifestVersion: Int = 1,
        framesPerSegment: Int,
        segmentCount: Int,
        totalFrames: Int,
        selector: String,
        seed: UInt64,
        backend: String,
        stagger: Double,
        width: Int,
        height: Int,
        quality: Int,
        frames: [FrameEntry]
    ) {
        self.manifestVersion = manifestVersion
        self.framesPerSegment = framesPerSegment
        self.segmentCount = segmentCount
        self.totalFrames = totalFrames
        self.selector = selector
        self.seed = seed
        self.backend = backend
        self.stagger = stagger
        self.width = width
        self.height = height
        self.quality = quality
        self.frames = frames
    }

    /// One row in the manifest's `frames` array.
    ///
    /// `interpolationType` is `nil` (JSON `null`) for **loop** rows and carries
    /// the genome's matrix interpolation type (e.g. `"log"`) for **transition**
    /// rows.
    public struct FrameEntry: Codable, Sendable, Equatable {
        /// Global frame index (`0..<totalFrames`).
        public let index: Int
        /// PNG filename relative to the manifest directory (`"000000.png"`).
        public let file: String
        /// Segment id this frame belongs to.
        public let segmentId: Int
        /// `"loop"` or `"transition"`.
        public let kind: String
        /// Source sheep index in the input genome list.
        public let fromSheep: Int
        /// Destination sheep index (`== fromSheep` for loops).
        public let toSheep: Int
        /// 1-indexed blend `(local + 1) / N` ∈ `(0, 1]`. **Never 0.**
        public let blend: Double
        /// Matrix interpolation type; `nil` for loop rows (JSON `null`), the
        /// type raw value for transition rows (e.g. `"log"`).
        public let interpolationType: String?

        public init(
            index: Int,
            file: String,
            segmentId: Int,
            kind: String,
            fromSheep: Int,
            toSheep: Int,
            blend: Double,
            interpolationType: String?
        ) {
            self.index = index
            self.file = file
            self.segmentId = segmentId
            self.kind = kind
            self.fromSheep = fromSheep
            self.toSheep = toSheep
            self.blend = blend
            self.interpolationType = interpolationType
        }
    }
}
