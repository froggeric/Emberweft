import Foundation

// Collections / playlists — ordered, named groups of genomes (the owner's
// headline missing feature). A `GenomeCollection` is a playlist: an ordered
// array of `CollectionEntry` references. Reuses `MetadataStore`'s resilient-JSON
// persistence pattern (coalesced off-main save, corrupt ⇒ quarantine) and
// `PlaybackRoute`'s stable-reference shape so resolution is consistent with the
// single-genome playback window.
//
// **Determinism (rule #2):** `collections` and each `entries` array are stored
// as stable arrays (creation / user order). The store never iterates a
// `Set`/`Dictionary` to build a display list. `Codable` uses the synthesized,
// key-ordered encoder (stable across launches and machines).

/// A stable reference to a genome inside a `GenomeCollection`. Mirrors
/// `PlaybackRoute`'s stored fields (`source`/`rootPath`/`id`/`fileURL`/
/// `displayName`) so a collection entry resolves to a live `LibraryEntry` by the
/// same lookup the playback window uses, and a removed folder / rescanned-away
/// file simply makes an entry unresolvable (the grid skips it) — never a crash.
///
/// Lives in `EmberweftUI` (with the store); the GUI's resolver
/// (`AppModel.resolve(_:)`) reads `AppModel` without the model needing the GUI
/// module, exactly like `PlaybackRoute`.
public struct CollectionEntry: Codable, Sendable, Hashable {
    /// `"bundle"` / `"directory"` / `"imported"` (mirrors `LibrarySource`,
    /// minus the associated URL which is carried separately as `rootPath`).
    public let source: String
    /// Only set for `.directory` (the scanned root's path); `nil` for bundle and
    /// imported sources. Directory entries' `id` is unique per root, so matching
    /// `(rootPath, id)` is unambiguous.
    public let rootPath: String?
    /// `LibraryEntry.id` (unique within `(source, rootPath)`).
    public let id: String
    /// Absolute URL of the `.flam3` file.
    public let fileURL: URL
    /// File stem — the display label.
    public let displayName: String

    public init(source: String, rootPath: String?, id: String,
                fileURL: URL, displayName: String) {
        self.source = source
        self.rootPath = rootPath
        self.id = id
        self.fileURL = fileURL
        self.displayName = displayName
    }

    /// Build from a live entry (mirrors `PlaybackRoute.init(_:)`).
    public init(_ entry: LibraryEntry) {
        switch entry.source {
        case .bundle:
            self.source = "bundle"; self.rootPath = nil
        case .directory(let url):
            self.source = "directory"; self.rootPath = url.path
        case .imported:
            self.source = "imported"; self.rootPath = nil
        }
        self.id = entry.id
        self.fileURL = entry.fileURL
        self.displayName = entry.displayName
    }

    /// Stable identity for dedupe / matching against a resolved live entry.
    /// Encodes the same `(source, rootPath, id)` triple the resolver keys on.
    public var identity: String { "\(source)|\(rootPath ?? "")|\(id)" }
}

/// A named, **ordered** list of genomes (a playlist). `entries` is an array —
/// its order is both the display order and the playback order, and is stable
/// (rule #2: never accumulate over a hashed collection).
public struct GenomeCollection: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public var name: String
    public var entries: [CollectionEntry]

    public init(id: UUID = UUID(), name: String, entries: [CollectionEntry] = []) {
        self.id = id
        self.name = name
        self.entries = entries
    }
}

/// Persisted, ordered set of `GenomeCollection`s. Clones `MetadataStore`'s
/// resilient-JSON pattern: `@MainActor @Observable` (SwiftUI reads
/// `collections` synchronously in sidebar/grid bodies), a coalesced off-main
/// `Task` writes `collections.json` atomically (rapid edits collapse into one
/// write), and a present-but-undecodable file is quarantined to
/// `collections.json.corrupt-<ts>` (never deleted; recoverable).
@MainActor
@Observable
public final class CollectionsStore {

    /// All collections, in user/creation order. `@Observable` tracks the whole
    /// array; mutations replace it so SwiftUI re-renders the sidebar + grids.
    public private(set) var collections: [GenomeCollection]

    public init(collections: [GenomeCollection] = []) {
        self.collections = collections
    }

    // MARK: - Read

    public func collection(id: UUID) -> GenomeCollection? {
        collections.first { $0.id == id }
    }

    // MARK: - Mutations (each schedules a coalesced save)

    /// Create a new collection from an ordered list of entries. Returns the new
    /// collection so the caller can navigate to it. An empty name becomes
    /// `"Untitled"`.
    @discardableResult
    public func create(name: String, from entries: [CollectionEntry]) -> GenomeCollection {
        let c = GenomeCollection(name: name.trimmingCharacters(in: .whitespaces).isEmpty
                                 ? "Untitled" : name,
                                 entries: entries)
        collections.append(c)
        scheduleSave()
        return c
    }

    /// Rename a collection by id. No-op when the id is unknown.
    public func rename(_ id: UUID, to name: String) {
        guard let i = index(of: id) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        collections[i].name = trimmed.isEmpty ? "Untitled" : trimmed
        scheduleSave()
    }

    /// Delete a collection by id. No-op when unknown.
    public func delete(_ id: UUID) {
        collections.removeAll { $0.id == id }
        scheduleSave()
    }

    /// Append entries to a collection, **deduped by identity** — an entry already
    /// present (same `source`/`rootPath`/`id`) is not added twice. New entries
    /// are appended in the given order. Returns the count actually added.
    @discardableResult
    public func addEntries(_ entries: [CollectionEntry], to id: UUID) -> Int {
        guard let i = index(of: id) else { return 0 }
        let existing = Set(collections[i].entries.map(\.identity))
        var added = 0
        for e in entries where !existing.contains(e.identity) {
            collections[i].entries.append(e)
            added += 1
        }
        if added > 0 { scheduleSave() }
        return added
    }

    /// Remove the entry at `storedIndex` from a collection (clamped; no-op when
    /// out of range). `storedIndex` is the position in `collection.entries`
    /// (the stored array, NOT the resolved-view index — see the collection grid).
    public func removeEntry(at storedIndex: Int, from id: UUID) {
        guard let i = index(of: id),
              collections[i].entries.indices.contains(storedIndex) else { return }
        collections[i].entries.remove(at: storedIndex)
        scheduleSave()
    }

    /// Move the entry at `from` to `to` within a collection's stored `entries`
    /// (drag-reorder / Move Up-Down). Semantics mirror `Array.move`: the element
    /// at `from` is removed then inserted at `to`. Clamped; no-op when `from` is
    /// out of range or the collection is unknown.
    public func moveEntry(in id: UUID, from: Int, to: Int) {
        guard let i = index(of: id),
              collections[i].entries.indices.contains(from) else { return }
        var entries = collections[i].entries
        let clampedTo = min(max(to, entries.startIndex), entries.endIndex - 1)
        let e = entries.remove(at: from)
        entries.insert(e, at: min(clampedTo, entries.count))
        collections[i].entries = entries
        scheduleSave()
    }

    // MARK: - Internals

    private func index(of id: UUID) -> Int? {
        collections.firstIndex { $0.id == id }
    }

    // MARK: - Persistence (clones MetadataStore's resilient pattern)

    /// Missing ⇒ empty store. Present-but-undecodable ⇒ empty store + the bad
    /// file renamed to `collections.json.corrupt-<ts>` (recoverable, never
    /// deleted).
    public static func loadResilient(directory: URL = AppPreferences.defaultDirectory)
        -> (store: CollectionsStore, quarantined: URL?) {
        let url = directory.appendingPathComponent("collections.json")
        if !FileManager.default.fileExists(atPath: url.path) {
            return (CollectionsStore(), nil)
        }
        guard let data = try? Data(contentsOf: url) else { return (CollectionsStore(), nil) }
        do {
            let collections = try JSONDecoder().decode([GenomeCollection].self, from: data)
            return (CollectionsStore(collections: collections), nil)
        } catch {
            let corrupt = directory.appendingPathComponent(
                "collections.json.corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: url, to: corrupt)
            return (CollectionsStore(), corrupt)
        }
    }

    private var dirty = false
    private var saveTask: Task<Void, Never>?
    private var saveDirectory: URL = AppPreferences.defaultDirectory

    /// Coalesced, off-main atomic write. Sets a dirty flag; if no save `Task` is
    /// in flight, launches one that snapshots `collections` on the MainActor,
    /// encodes + writes on a detached utility task, then re-checks dirty (so
    /// rapid edits collapse into one write). No overlapping writes.
    public func scheduleSave(directory: URL = AppPreferences.defaultDirectory) {
        saveDirectory = directory
        dirty = true
        if saveTask != nil { return }
        saveTask = Task { [weak self] in
            while let self {
                if !self.dirty { break }
                self.dirty = false
                let snapshot = self.collections       // value copy on MainActor
                let dir = self.saveDirectory
                await Self.write(snapshot, to: dir)    // detached encode + atomic write
            }
            self?.saveTask = nil
        }
    }

    private static func write(_ collections: [GenomeCollection], to dir: URL) async {
        await Task.detached(priority: .utility) {
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys, .prettyPrinted]
            guard let data = try? enc.encode(collections) else { return }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: dir.appendingPathComponent("collections.json"), options: .atomic)
        }.value
    }

    /// Test hook: await the in-flight coalesced save (if any) to land.
    internal func flushSaved() async {
        if let t = saveTask { await t.value }
    }
}
