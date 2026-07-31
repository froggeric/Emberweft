import Foundation
import FlameKit

/// Scans genome sources into `[LibraryEntry]` and parses genomes lazily on
/// demand (never on scan — a directory may hold tens of thousands of `.flam3`
/// files; parsing them upfront would block for minutes).
///
/// Two sources:
/// - `scanBundle(rootURL:)` — the app's curated bundle dir (`<root>/genomes/*.flam3`
///   plus a `<root>/ranking.json` sidecar). The GUI passes the resource URL.
/// - `scanDirectory(_:)` — any user-chosen folder; reuses `FeatureCache.flam3Files()`
///   (a pure recursive walk + sort, no parse) for deterministic ordering.
///
/// Parsed genomes are cached by `entry.id` so repeated clicks / thumbnail requests
/// never re-parse (no N+1). An actor so the cache + state are serialized.
public actor LibraryIndex {

    private var genomeCache: [String: Flame] = [:]

    public init() {}

    // MARK: - Bundle

    /// Scan the curated bundle: enumerate `<root>/genomes/*.flam3` (sorted by
    /// filename for determinism) and attach ranks from `<root>/ranking.json`.
    public func scanBundle(rootURL: URL) -> [LibraryEntry] {
        let genomesDir = rootURL.appendingPathComponent("genomes", isDirectory: true)
        let ranking = readRanking(at: rootURL.appendingPathComponent("ranking.json"))

        let urls = (try? FileManager.default.contentsOfDirectory(
            at: genomesDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])) ?? []
        // Sort by filename → deterministic grid order (rule #2).
        let sorted = urls.filter { $0.pathExtension == "flam3" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        return sorted.map { url in
            let stem = url.deletingPathExtension().lastPathComponent
            return LibraryEntry(
                id: stem,
                source: .bundle,
                fileURL: url,
                displayName: stem,
                rank: ranking[stem])
        }
    }

    // MARK: - Directory

    /// Scan a user-chosen directory recursively for `.flam3` files. Reuses
    /// `FeatureCache.flam3Files()` (pure walk + lexicographic sort, no parse).
    /// Throws `.libraryNotFound` if the directory does not exist.
    public func scanDirectory(_ rootURL: URL) throws -> [LibraryEntry] {
        let cache = FeatureCache(libraryDir: rootURL)
        let files = try cache.flam3Files()
        return files.map { url in
            LibraryEntry(
                id: Self.directoryID(for: url, relativeTo: rootURL),
                source: .directory(rootURL),
                fileURL: url,
                displayName: url.deletingPathExtension().lastPathComponent,
                rank: nil)
        }
    }

    // MARK: - Imported (drag-and-drop folder)

    /// Scan the flat `Imported/` folder (top-level only) for `.flam3` files, sorted
    /// by filename. `id` is the bare stem (the folder is flat ⇒ unique). Mirrors
    /// `scanBundle` but over the Imported directory.
    public func scanImported(rootURL: URL) -> [LibraryEntry] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])) ?? []
        return urls.filter { $0.pathExtension == "flam3" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { url in
                let stem = url.deletingPathExtension().lastPathComponent
                return LibraryEntry(id: stem, source: .imported,
                                    fileURL: url, displayName: stem, rank: nil)
            }
    }

    // MARK: - Lazy parse (cached)

    /// Parse a genome on demand, cache it by `entry.id`, and record its
    /// `isRenderable` health. Subsequent calls for the same id hit the cache.
    public func loadGenome(for entry: LibraryEntry) throws -> Flame {
        if let cached = genomeCache[entry.id] { return cached }
        let data = try Data(contentsOf: entry.fileURL)
        let flames = try Flam3Parser.parse(data)
        guard let first = flames.first else {
            throw LibraryIndexError.noFlameElement(entry.fileURL.path)
        }
        genomeCache[entry.id] = first
        return first
    }

    // MARK: - Internals

    /// Stable id mirroring `FeatureCache.sheepID`: relative path, `.flam3`
    /// stripped, separators collapsed to `__`.
    private static func directoryID(for url: URL, relativeTo root: URL) -> String {
        let base = root.standardizedFileURL.path
        let full = url.standardizedFileURL.path
        var rel = full == base ? "" :
            (full.hasPrefix(base + "/") ? String(full.dropFirst(base.count + 1)) : url.lastPathComponent)
        if rel.hasSuffix(".flam3") { rel.removeLast(".flam3".count) }
        return rel.split(separator: "/").joined(separator: "__")
    }

    private func readRanking(at url: URL) -> [String: CuratorRank] {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(RankingFile.self, from: data)
        else { return [:] }
        return file.entries
    }
}

enum LibraryIndexError: Error, Equatable, Sendable {
    case noFlameElement(String)
}
