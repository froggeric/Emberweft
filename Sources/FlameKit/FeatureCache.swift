import Foundation

/// Disk-backed feature-vector cache for similarity-based sheep selection (Task 17).
///
/// The production Electric-Sheep archive contains tens of thousands of `.flam3`
/// genomes. Rebuilding every `FeatureVector` on each run is too slow, so this
/// cache persists one record per sheep id under
/// `<libraryDir>/.feature_cache/`. On a library scan, only records whose source
/// `.flam3` is missing or newer than the cached mtime are rebuilt incrementally;
/// `rebuildAll()` does a full rebuild (the `--rebuild-cache` CLI path).
///
/// # F1 DETERMINISM (load-bearing)
/// Cache records serialize as **sorted arrays**, never a `String`-keyed `Dict`
/// whose iteration order could reorder across encoders / process launches:
///   - `FeatureCacheRecord.variations` is a `[VariationEntry]` sorted by `name`,
///   - the record is encoded with `JSONEncoder.OutputFormatting.sortedKeys`, so
///     the on-disk JSON is byte-stable (a record re-encoded decodes identically).
/// Reading the cache back therefore yields bit-identical `FeatureVector`
/// components regardless of which process wrote it.
///
/// # Index-alignment contract
/// `flam3Files()`, `scan()`, `rebuildAll()`, and `loadForSimilararity()` all
/// return vectors / files in the SAME deterministic order: source `.flam3`
/// relative paths sorted lexicographically. Sheep index `i` in the returned
/// array corresponds to the i-th sorted source file, matching how
/// `SimilarityExploration` consumes `[FeatureVector]`.
public struct FeatureCache: Sendable {
    /// The library root scanned for `.flam3` genomes.
    public let libraryDir: URL
    /// Per-record cache directory: `<libraryDir>/.feature_cache/`.
    public let cacheDir: URL

    /// - Parameter libraryDir: Root of the `.flam3` library (e.g. `genomes/`).
    public init(libraryDir: URL) {
        self.libraryDir = libraryDir
        self.cacheDir = libraryDir.appendingPathComponent(".feature_cache", isDirectory: true)
    }

    // MARK: - Public API

    /// All `.flam3` files under `libraryDir` (recursive), sorted by their
    /// relative path so the ordering is deterministic and aligned with the
    /// vector arrays returned by `scan()` / `loadForSimilararity()`.
    public func flam3Files() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: libraryDir.path) else {
            throw FeatureCacheError.libraryNotFound(libraryDir.path)
        }
        var urls: [URL] = []
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: libraryDir,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        // Skip the cache dir itself (it is hidden via leading '.', but be safe).
        for case let url as URL in enumerator {
            // Never descend into / emit our own cache directory.
            if url.resolvingSymlinksInPath().path == cacheDir.resolvingSymlinksInPath().path {
                enumerator.skipDescendants()
                continue
            }
            guard url.pathExtension == "flam3" else { continue }
            urls.append(url)
        }
        // Sort by relative path → stable sheep-index ordering.
        return urls.sorted { relativePath(of: $0) < relativePath(of: $1) }
    }

    /// Incremental rebuild: for every source `.flam3`, rebuild its record iff the
    /// record is absent OR the source mtime is newer than the cached mtime.
    /// Orphan records (no matching source) are pruned. Returns the full
    /// `[FeatureVector]` aligned with `flam3Files()` order.
    @discardableResult
    public func scan() throws -> [FeatureVector] {
        try ensureCacheDir()
        let files = try flam3Files()
        let liveIDs = Set(files.map { sheepID(for: $0) })

        // Prune orphan records (sources removed/moved).
        for existing in existingRecordIDs() where !liveIDs.contains(existing) {
            try? FileManager.default.removeItem(at: cacheFile(forID: existing))
        }

        var vectors: [FeatureVector] = []
        vectors.reserveCapacity(files.count)
        for url in files {
            let id = sheepID(for: url)
            let srcMtime = try mtime(of: url)
            if let rec = try? record(forID: id), !isStale(sourceMtime: srcMtime, record: rec) {
                vectors.append(rec.featureVector)
            } else {
                let fv = try buildFeatureVector(from: url)
                let rec = FeatureCacheRecord(
                    from: fv,
                    id: id,
                    sourcePath: relativePath(of: url),
                    sourceMtime: srcMtime
                )
                try writeRecord(rec)
                vectors.append(fv)
            }
        }
        return vectors
    }

    /// Full rebuild: wipes the cache directory and rebuilds every record from
    /// scratch. This is the `--rebuild-cache` path. Returns vectors aligned with
    /// `flam3Files()` order.
    @discardableResult
    public func rebuildAll() throws -> [FeatureVector] {
        if FileManager.default.fileExists(atPath: cacheDir.path) {
            try FileManager.default.removeItem(at: cacheDir)
        }
        try ensureCacheDir()
        let files = try flam3Files()
        var vectors: [FeatureVector] = []
        vectors.reserveCapacity(files.count)
        for url in files {
            let id = sheepID(for: url)
            let srcMtime = try mtime(of: url)
            let fv = try buildFeatureVector(from: url)
            let rec = FeatureCacheRecord(
                from: fv,
                id: id,
                sourcePath: relativePath(of: url),
                sourceMtime: srcMtime
            )
            try writeRecord(rec)
            vectors.append(fv)
        }
        return vectors
    }

    /// Read-only load of the cache for `--selector similarity`. Throws
    /// `.cacheAbsent` when the cache directory is missing or holds no records —
    /// the clear, user-actionable error telling the user to run
    /// `--rebuild-cache`. `--selector sequential` never calls this.
    public func loadForSimilararity() throws -> [FeatureVector] {
        guard FileManager.default.fileExists(atPath: cacheDir.path) else {
            throw FeatureCacheError.cacheAbsent(
                "feature cache not found at \(cacheDir.path). Run `emberweft --rebuild-cache <library>` to build it.")
        }
        let ids = existingRecordIDs()
        if ids.isEmpty {
            throw FeatureCacheError.cacheAbsent(
                "feature cache is empty at \(cacheDir.path). Run `emberweft --rebuild-cache <library>` to build it.")
        }
        // Return in id-sorted order to match flam3Files() / scan() alignment.
        var vectors: [FeatureVector] = []
        vectors.reserveCapacity(ids.count)
        for id in ids.sorted() {
            vectors.append(try record(forID: id).featureVector)
        }
        return vectors
    }

    // MARK: - Record access (test-visible)

    /// The on-disk JSON file for a given sheep id.
    public func cacheFile(forID id: String) -> URL {
        cacheDir.appendingPathComponent("\(id).json")
    }

    /// Read a single record by sheep id. Throws `.recordMissing` if absent.
    public func record(forID id: String) throws -> FeatureCacheRecord {
        let url = cacheFile(forID: id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FeatureCacheError.recordMissing(id)
        }
        let data = try Data(contentsOf: url)
        do {
            return try FeatureCacheRecord.decoder.decode(FeatureCacheRecord.self, from: data)
        } catch {
            throw FeatureCacheError.recordCorrupt(id: id, underlying: "\(error)")
        }
    }

    // MARK: - Internals

    private func ensureCacheDir() throws {
        try FileManager.default.createDirectory(
            at: cacheDir, withIntermediateDirectories: true)
    }

    /// IDs of all records currently on disk (unsorted).
    private func existingRecordIDs() -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: cacheDir.path) else {
            return []
        }
        return names.compactMap { name -> String? in
            guard name.hasSuffix(".json") else { return nil }
            return String(name.dropLast(".json".count))
        }
    }

    private func writeRecord(_ rec: FeatureCacheRecord) throws {
        let data = try FeatureCacheRecord.encoded(rec)
        try data.write(to: cacheFile(forID: rec.id), options: .atomic)
    }

    /// Rebuild iff cached record absent OR source `.flam3` mtime > stored mtime.
    private func isStale(sourceMtime: Double, record: FeatureCacheRecord) -> Bool {
        sourceMtime > record.sourceMtime
    }

    private func buildFeatureVector(from url: URL) throws -> FeatureVector {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw FeatureCacheError.parseFailed(path: url.path, underlying: "unreadable: \(error)")
        }
        let flames: [Flame]
        do {
            flames = try Flam3Parser.parse(data)
        } catch {
            throw FeatureCacheError.parseFailed(path: url.path, underlying: "\(error)")
        }
        guard let first = flames.first else {
            throw FeatureCacheError.parseFailed(path: url.path, underlying: "no <flame> element")
        }
        return FeatureVector(for: first)
    }

    private func mtime(of url: URL) throws -> Double {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let date = (attrs[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
        return date.timeIntervalSince1970
    }

    /// Stable sheep id: the source path relative to `libraryDir`, `.flam3`
    /// stripped, path separators collapsed to `__`. Collision-free and reversible
    /// per-library, and safe as a filename.
    private func sheepID(for url: URL) -> String {
        var rel = relativePath(of: url)
        if rel.hasSuffix(".flam3") { rel.removeLast(".flam3".count) }
        return rel.split(separator: "/").joined(separator: "__")
    }

    /// Path of `url` relative to `libraryDir`, using POSIX `/` separators.
    private func relativePath(of url: URL) -> String {
        let base = libraryDir.standardizedFileURL.path
        let full = url.standardizedFileURL.path
        if full == base { return "" }
        if full.hasPrefix(base + "/") {
            return String(full.dropFirst(base.count + 1))
        }
        return url.lastPathComponent
    }
}

/// One cache record per sheep. Fields mirror `FeatureVector`'s stored
/// properties; `variations` is a **sorted array** (F1), never a String-keyed
/// dict. `Codable` + `sortedKeys` encoding makes the on-disk form byte-stable.
public struct FeatureCacheRecord: Codable, Sendable, Equatable {
    public let id: String
    /// Source `.flam3` path relative to the library root.
    public let sourcePath: String
    /// Source `.flam3` modification time (`Date.timeIntervalSince1970`) captured
    /// at build time. Drives incremental rebuild (stale iff source newer).
    public let sourceMtime: Double
    /// Variation-set fingerprint, sorted by `name` (F1-critical: array, not dict).
    public let variations: [VariationEntry]
    public let paletteMeanHue: Double
    public let paletteMeanLuma: Double
    public let xformCount: Int
    public let summedAffineFrobenius: Double

    public struct VariationEntry: Codable, Sendable, Equatable {
        public let name: String
        public let weight: Double
    }

    public init(
        from fv: FeatureVector,
        id: String,
        sourcePath: String,
        sourceMtime: Double
    ) {
        self.id = id
        self.sourcePath = sourcePath
        self.sourceMtime = sourceMtime
        // Sort defensively on write — fv.variations is already sorted by name,
        // but enforcing here keeps the on-disk invariant load-bearing (F1).
        self.variations = fv.variations
            .sorted { $0.name < $1.name }
            .map { VariationEntry(name: $0.name, weight: $0.weight) }
        self.paletteMeanHue = fv.paletteMeanHue
        self.paletteMeanLuma = fv.paletteMeanLuma
        self.xformCount = fv.xformCount
        self.summedAffineFrobenius = fv.summedAffineFrobenius
    }

    /// Reconstruct the in-memory `FeatureVector` (variations pre-sorted by name).
    public var featureVector: FeatureVector {
        FeatureVector(
            variations: variations
                .sorted { $0.name < $1.name }
                .map { (name: $0.name, weight: $0.weight) },
            paletteMeanHue: paletteMeanHue,
            paletteMeanLuma: paletteMeanLuma,
            xformCount: xformCount,
            summedAffineFrobenius: summedAffineFrobenius
        )
    }

    // MARK: - Deterministic codec (F1)

    /// Shared encoder: `sortedKeys` → byte-stable on-disk JSON.
    fileprivate static let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return enc
    }()

    /// Shared decoder.
    fileprivate static let decoder: JSONDecoder = JSONDecoder()

    /// Byte-stable encoding of a record (F1: re-encoding is idempotent).
    public static func encoded(_ rec: FeatureCacheRecord) throws -> Data {
        try encoder.encode(rec)
    }
}

/// Errors raised by `FeatureCache`.
public enum FeatureCacheError: Error, Equatable, Sendable {
    /// Library root directory does not exist.
    case libraryNotFound(String)
    /// Similarity requested with no usable cache (user must `--rebuild-cache`).
    case cacheAbsent(String)
    /// A specific record is not present on disk.
    case recordMissing(String)
    /// A record file exists but could not be decoded.
    case recordCorrupt(id: String, underlying: String)
    /// A source `.flam3` could not be parsed.
    case parseFailed(path: String, underlying: String)
}
