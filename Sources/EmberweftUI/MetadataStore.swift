import Foundation

/// Per-genome metadata store, persisted as `metadata.json` in the app-support
/// directory. `@MainActor @Observable` (NOT an `actor`) so SwiftUI can read
/// `metadata(for:)` synchronously in cell bodies; a coalesced, off-main `Task`
/// handles writes so edits never block the UI and rapid edits collapse into one
/// atomic write.
///
/// The store keys records by `metadataKey(for:)` — a **source-qualified** string
/// that encodes the entry's source + (for directories) the root path, so metadata
/// never collides across the curated bundle, an opened folder, or the Imported
/// folder (even when two folders contain a same-stemmed file at their root).
@MainActor
@Observable
public final class MetadataStore {

    /// Keyed by `metadataKey(for:)`. `@Observable` tracks the whole dictionary.
    public private(set) var entries: [String: GenomeMetadata]

    public init(entries: [String: GenomeMetadata] = [:]) { self.entries = entries }

    // MARK: - Access

    public func metadata(for entry: LibraryEntry) -> GenomeMetadata {
        entries[Self.metadataKey(for: entry)] ?? .empty
    }

    public func set(_ md: GenomeMetadata, for entry: LibraryEntry) {
        entries[Self.metadataKey(for: entry)] = Self.normalize(md)
        scheduleSave()
    }

    public func update(for entry: LibraryEntry, _ mutate: (inout GenomeMetadata) -> Void) {
        var md = metadata(for: entry)
        mutate(&md)
        set(md, for: entry)
    }

    /// Adjust a genome's sentiment by a delta (e.g. ±1), clamped to [-1, 1].
    public func adjustSentiment(for entry: LibraryEntry, by delta: Int) {
        update(for: entry) { $0.sentiment = GenomeMetadata.clamp($0.sentiment + delta) }
    }

    /// Set the sentiment directly (clamped).
    public func setSentiment(_ value: Int, for entry: LibraryEntry) {
        update(for: entry) { $0.sentiment = GenomeMetadata.clamp(value) }
    }

    // MARK: - Source-qualified key

    /// Stable, collision-free per-entry key. Encodes source + directory root + id.
    public static func metadataKey(for entry: LibraryEntry) -> String {
        switch entry.source {
        case .bundle:
            return "bundle::\(entry.id)"
        case .directory(let root):
            return "dir::\(root.standardizedFileURL.path)::\(entry.id)"
        case .imported:
            return "imported::\(entry.id)"
        }
    }

    private static func normalize(_ md: GenomeMetadata) -> GenomeMetadata {
        var m = md
        m.sentiment = GenomeMetadata.clamp(m.sentiment)
        return m
    }

    // MARK: - Persistence (clones AppPreferences' resilient pattern)

    /// Missing ⇒ empty store. Present-but-undecodable ⇒ empty store + the bad file
    /// renamed to `metadata.json.corrupt-<ts>` (never deleted; recoverable).
    public static func loadResilient(directory: URL = AppPreferences.defaultDirectory)
        -> (store: MetadataStore, quarantined: URL?) {
        let url = directory.appendingPathComponent("metadata.json")
        if !FileManager.default.fileExists(atPath: url.path) {
            return (MetadataStore(), nil)
        }
        guard let data = try? Data(contentsOf: url) else { return (MetadataStore(), nil) }
        do {
            let entries = try JSONDecoder().decode([String: GenomeMetadata].self, from: data)
            return (MetadataStore(entries: entries), nil)
        } catch {
            let corrupt = directory.appendingPathComponent(
                "metadata.json.corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: url, to: corrupt)
            return (MetadataStore(), corrupt)
        }
    }

    private var dirty = false
    private var saveTask: Task<Void, Never>?
    private var saveDirectory: URL = AppPreferences.defaultDirectory

    /// Coalesced, off-main atomic write. Sets a dirty flag; if no save `Task` is
    /// in flight, launches one that snapshots `entries` on the MainActor, encodes
    /// + writes on a detached utility task, then re-checks dirty (so rapid edits
    /// collapse into one write). No overlapping writes.
    public func scheduleSave(directory: URL = AppPreferences.defaultDirectory) {
        saveDirectory = directory
        dirty = true
        if saveTask != nil { return }
        saveTask = Task { [weak self] in
            while let self {
                if !self.dirty { break }
                self.dirty = false
                let snapshot = self.entries          // value copy on MainActor
                let dir = self.saveDirectory
                await Self.write(snapshot, to: dir)   // detached encode + atomic write
            }
            self?.saveTask = nil
        }
    }

    private static func write(_ entries: [String: GenomeMetadata], to dir: URL) async {
        await Task.detached(priority: .utility) {
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys, .prettyPrinted]
            guard let data = try? enc.encode(entries) else { return }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: dir.appendingPathComponent("metadata.json"), options: .atomic)
        }.value
    }

    /// Test hook: await the in-flight coalesced save (if any) to land.
    internal func flushSaved() async {
        if let t = saveTask { await t.value }
    }
}
