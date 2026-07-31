import Foundation

/// Out-of-band per-genome metadata (the `Flame` model has no UI metadata — only a
/// render-relevant `name`). One record per library entry, keyed by
/// `MetadataStore.metadataKey(for:)`. Persisted to `metadata.json`.
///
/// `tags` are kept **sorted + de-duped** (case-insensitive) and `rating` clamped,
/// so two saves of equal state produce a byte-identical JSON file (rule #2). A
/// custom `init(from:)` supplies defaults for any missing key → forward-compatible
/// with older partial files and future fields.
public struct GenomeMetadata: Codable, Sendable, Hashable {

    public var tags: [String]
    public var rating: Int            // clamped to 0...5
    public var favorite: Bool
    public var notes: String
    public var importedAt: Date?      // set once on import; nil for bundle/dir
    public var schemaVersion: Int     // == 1; gates future migration

    public init(tags: [String] = [],
                rating: Int = 0,
                favorite: Bool = false,
                notes: String = "",
                importedAt: Date? = nil,
                schemaVersion: Int = 1) {
        self.tags = GenomeMetadata.normalizeTags(tags)
        self.rating = max(0, min(5, rating))
        self.favorite = favorite
        self.notes = notes
        self.importedAt = importedAt
        self.schemaVersion = schemaVersion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tags = GenomeMetadata.normalizeTags(try c.decodeIfPresent([String].self, forKey: .tags) ?? [])
        rating = max(0, min(5, try c.decodeIfPresent(Int.self, forKey: .rating) ?? 0))
        favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        importedAt = try c.decodeIfPresent(Date.self, forKey: .importedAt)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    }

    /// Empty/default record.
    public static let empty = GenomeMetadata()

    /// Sorted (case-insensitive primary, exact secondary) + de-duped
    /// (case-insensitive). Pure + deterministic (rule #2 — no float sums).
    public static func normalizeTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for t in tags {
            let key = t.lowercased()
            if !seen.contains(key) {
                seen.insert(key)
                out.append(t)
            }
        }
        return out.sorted { a, b in
            let la = a.lowercased(), lb = b.lowercased()
            return la == lb ? a < b : la < lb
        }
    }
}
