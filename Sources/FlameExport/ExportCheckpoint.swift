import Foundation

/// Serializable resume state for `ExportCoordinator.runResumable` (M6.1). `Flame`
/// is not Codable, so this stores the job recipe + per-flame source locators (URL +
/// flame index + SHA-256) and the set of completed chunks. See spec §3.1.
public struct ExportCheckpoint: Codable, Sendable, Equatable {
    public let schemaVersion: Int                  // == 1
    public let settings: ExportSettings
    public let framesPerSegment: Int
    public let transitionFramesPerSegment: Int
    public let segmentCount: Int
    public let selector: SelectorSpec
    public let seed: UInt64
    public let loopCycles: Int
    public let stagger: Double
    public let out: URL
    public let loopRepeatCount: Int
    public let checkpointIntervalFrames: Int
    public let totalGlobalFrames: Int
    public var completedChunkIndexes: Set<Int>
    public let sources: [Source]

    public var chunkCount: Int {
        max(1, (totalGlobalFrames + checkpointIntervalFrames - 1) / checkpointIntervalFrames)
    }

    public init(settings: ExportSettings, framesPerSegment: Int,
                transitionFramesPerSegment: Int, segmentCount: Int, selector: SelectorSpec,
                seed: UInt64, loopCycles: Int, stagger: Double, out: URL,
                loopRepeatCount: Int, checkpointIntervalFrames: Int, totalGlobalFrames: Int,
                completedChunkIndexes: Set<Int>, sources: [Source]) {
        self.schemaVersion = 1
        self.settings = settings; self.framesPerSegment = framesPerSegment
        self.transitionFramesPerSegment = transitionFramesPerSegment
        self.segmentCount = segmentCount; self.selector = selector; self.seed = seed
        self.loopCycles = loopCycles; self.stagger = stagger; self.out = out
        self.loopRepeatCount = loopRepeatCount
        self.checkpointIntervalFrames = checkpointIntervalFrames
        self.totalGlobalFrames = totalGlobalFrames
        self.completedChunkIndexes = completedChunkIndexes
        self.sources = sources
    }

    /// Force-sorted encode of `completedChunkIndexes` so the file is byte-stable
    /// across writes (rule #2 — Swift's Set ordering is per-process-randomized).
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, settings, framesPerSegment, transitionFramesPerSegment
        case segmentCount, selector, seed, loopCycles, stagger, out, loopRepeatCount
        case checkpointIntervalFrames, totalGlobalFrames, completedChunkIndexes, sources
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        settings = try c.decode(ExportSettings.self, forKey: .settings)
        framesPerSegment = try c.decode(Int.self, forKey: .framesPerSegment)
        transitionFramesPerSegment = try c.decode(Int.self, forKey: .transitionFramesPerSegment)
        segmentCount = try c.decode(Int.self, forKey: .segmentCount)
        selector = try c.decode(SelectorSpec.self, forKey: .selector)
        seed = try c.decode(UInt64.self, forKey: .seed)
        loopCycles = try c.decode(Int.self, forKey: .loopCycles)
        stagger = try c.decode(Double.self, forKey: .stagger)
        out = try c.decode(URL.self, forKey: .out)
        loopRepeatCount = try c.decode(Int.self, forKey: .loopRepeatCount)
        checkpointIntervalFrames = try c.decode(Int.self, forKey: .checkpointIntervalFrames)
        totalGlobalFrames = try c.decode(Int.self, forKey: .totalGlobalFrames)
        completedChunkIndexes = Set(try c.decode([Int].self, forKey: .completedChunkIndexes))
        sources = try c.decode([Source].self, forKey: .sources)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(settings, forKey: .settings)
        try c.encode(framesPerSegment, forKey: .framesPerSegment)
        try c.encode(transitionFramesPerSegment, forKey: .transitionFramesPerSegment)
        try c.encode(segmentCount, forKey: .segmentCount)
        try c.encode(selector, forKey: .selector)
        try c.encode(seed, forKey: .seed)
        try c.encode(loopCycles, forKey: .loopCycles)
        try c.encode(stagger, forKey: .stagger)
        try c.encode(out, forKey: .out)
        try c.encode(loopRepeatCount, forKey: .loopRepeatCount)
        try c.encode(checkpointIntervalFrames, forKey: .checkpointIntervalFrames)
        try c.encode(totalGlobalFrames, forKey: .totalGlobalFrames)
        try c.encode(completedChunkIndexes.sorted(), forKey: .completedChunkIndexes)
        try c.encode(sources, forKey: .sources)
    }

    public struct Source: Codable, Sendable, Equatable {
        public let fileURL: URL?
        public let flameIndex: Int
        public let sha256: String?
        public let serializedText: String?
        public let displayName: String
        public init(fileURL: URL?, flameIndex: Int, sha256: String?, serializedText: String?, displayName: String) {
            self.fileURL = fileURL; self.flameIndex = flameIndex
            self.sha256 = sha256; self.serializedText = serializedText; self.displayName = displayName
        }
    }

    // MARK: - URL helpers (spec §3.3)

    /// Returns the leaf stem of `out`, substituting "output" when the leaf is
    /// ".."/"."/empty (P6: Foundation does NOT resolve ".." in fileURLWithPath:,
    /// so only a literal ".."/"." LEAF is neutralized here; mid-path ".." is left
    /// literal and chunks land beside `out` in the user-declared dir).
    public static func sanitizedStem(_ out: URL) -> String {
        var stem = out.deletingPathExtension().lastPathComponent
        if stem == ".." || stem == "." || stem.isEmpty { stem = "output" }
        if stem.contains("/") { stem = stem.replacingOccurrences(of: "/", with: "_") }
        return stem
    }
    public static func chunkURL(out: URL, index: Int, container: ExportSettings.Container) -> URL {
        let stem = sanitizedStem(out)
        let ext = container == .mov ? "mov" : "mp4"
        let dir = out.deletingLastPathComponent()
        return dir.appendingPathComponent("\(stem).emberweft-chunk-\(String(format: "%04d", index)).\(ext)")
    }
    public static func checkpointURL(out: URL) -> URL {
        let stem = sanitizedStem(out)
        let dir = out.deletingLastPathComponent()
        return dir.appendingPathComponent("\(stem).emberweft-export.json")
    }
}
