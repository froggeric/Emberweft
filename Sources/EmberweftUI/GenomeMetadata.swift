import Foundation

/// Out-of-band per-genome metadata. Reduced (per owner direction) to a single
/// **tri-state sentiment** — the only per-genome signal that earns its keep for a
/// visual browser. Drives filtering ("Liked"), and will drive live-playback
/// weighting + on-the-fly adjustment (+/- keys) in the preview and future live mode.
///
/// `sentiment`: −1 = dislike/skip, 0 = neutral (default), +1 = like/favourite.
/// Persisted to `metadata.json`; schema v2. A custom `init(from:)` migrates v1
/// records (which had a boolean `favorite`) by mapping `favorite == true` →
/// `sentiment = +1`, and supplies defaults for any missing key.
public struct GenomeMetadata: Codable, Sendable, Hashable {

    public var sentiment: Int            // clamped to [-1, 1]
    public var importedAt: Date?         // set once on import; nil otherwise
    public var schemaVersion: Int        // == 2

    public init(sentiment: Int = 0,
                importedAt: Date? = nil,
                schemaVersion: Int = 2) {
        self.sentiment = min(max(sentiment, -1), 1)
        self.importedAt = importedAt
        self.schemaVersion = schemaVersion
    }

    private enum CodingKeys: String, CodingKey {
        case sentiment, importedAt, schemaVersion
        case favorite   // v1 migration only (decoded, never encoded)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let s = try c.decodeIfPresent(Int.self, forKey: .sentiment) ?? 0
        self.sentiment = min(max(s, -1), 1)
        self.importedAt = try c.decodeIfPresent(Date.self, forKey: .importedAt)
        self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 2
        // v1 migration: a previously-favourited genome becomes "liked".
        if self.sentiment == 0,
           try c.decodeIfPresent(Bool.self, forKey: .favorite) == true {
            self.sentiment = 1
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sentiment, forKey: .sentiment)
        try c.encodeIfPresent(importedAt, forKey: .importedAt)
        try c.encode(schemaVersion, forKey: .schemaVersion)
    }

    /// Neutral/default record.
    public static let empty = GenomeMetadata()

    /// Clamp helper for in-place mutations.
    public static func clamp(_ sentiment: Int) -> Int { min(max(sentiment, -1), 1) }
}
