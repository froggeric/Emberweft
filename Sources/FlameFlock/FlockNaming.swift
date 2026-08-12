// Sources/FlameFlock/FlockNaming.swift
import Foundation

/// Errors thrown by the path-safety-checked URL builders.
public enum FlockNamingError: Error, Equatable {
    case badShardName(String)
    case escapesRoot
}

/// Deterministic ES-inspired naming for the flock archive (spec §5.2, decisions
/// D1/D3/D7). All members are pure string functions (no Swift `Dict`/`Set`
/// iteration ⇒ rule-#2-safe).
public enum FlockNaming {
    private static let shardRegex = try! NSRegularExpression(pattern: "^[A-Za-z0-9_-]+$")
    private static let digitRegex = try! NSRegularExpression(pattern: "^[0-9]+$")

    /// `<aGen>=<aId>=<bGen>=<bId>.<ext>` (ext excludes the dot). Ids are emitted
    /// VERBATIM — no padding, no transformation (D1, §5.2). ES ids (e.g. "00628")
    /// are preserved as-is; minted ids are zero-padded to 6 digits by `IdMinter`
    /// (T8, reserved flock `900000`) BEFORE being handed here, so the caller owns
    /// the id's final string form. Padding inside `fileName` was a defect (it
    /// corrupted 5-digit ES ids like "00628" → "000628"); it stays out.
    public static func fileName(aGen: String, aId: String, bGen: String, bId: String, ext: String) -> String {
        "\(aGen)=\(aId)=\(bGen)=\(bId).\(ext)"
    }

    /// A loop is a self-edge: both (gen,id) endpoints equal.
    public static func isLoop(aGen: String, aId: String, bGen: String, bId: String) -> Bool {
        aGen == bGen && aId == bId
    }

    /// Split the file stem (no extension) on `=`; require exactly 4 numeric
    /// fields. Returns `nil` for 3/5 fields, non-digit contents, `..` or `/` —
    /// callers skip + log un-decodable stems.
    public static func decode(stem: String) -> (aGen: String, aId: String, bGen: String, bId: String)? {
        let parts = stem.split(separator: "=").map(String.init)
        guard parts.count == 4,
              parts.allSatisfy({
                  digitRegex.firstMatch(in: $0, range: NSRange(location: 0, length: $0.utf16.count)) != nil
              }),
              !parts.contains(where: { $0.contains("..") || $0.contains("/") }) else { return nil }
        return (parts[0], parts[1], parts[2], parts[3])
    }

    /// Shard directory name: `WxH_fps` plus `_Lf<loop>-Tf<trans>` iff the pace is
    /// non-canonical (D3). Canonical pace is 15 s loops / 12 s transitions ⇒
    /// `loopFrames == round(15*fps) && transFrames == round(12*fps)`.
    public static func shardDir(width: Int, height: Int, fps: Int,
                                loopFrames: Int, transFrames: Int,
                                canonicalLoopSeconds: Double = 15.0,
                                canonicalTransSeconds: Double = 12.0) throws -> String {
        let base = "\(width)x\(height)_\(fps)fps"
        let canonicalLoop = Int((canonicalLoopSeconds * Double(fps)).rounded())
        let canonicalTrans = Int((canonicalTransSeconds * Double(fps)).rounded())
        return (loopFrames == canonicalLoop && transFrames == canonicalTrans)
            ? base : "\(base)_Lf\(loopFrames)-Tf\(transFrames)"
    }

    /// Path-safety-checked archive (`.mov`/`.hevc`) file URL. The shard is
    /// validated to `^[A-Za-z0-9_-]+$` (the `-` admits non-canonical shard names
    /// like `1920x1080_30fps_Lf495-Tf300`) and the resolved path is checked to
    /// stay inside `flockRoot` (mirrors spec §5.2 BatchPath.resolve — rejects
    /// symlink-redirect + `..` escape). Layout: `<root>/<shard>/mpeg/<file>`.
    public static func archiveFileURL(flockRoot: URL, shardDir: String,
                                      aGen: String, aId: String, bGen: String, bId: String,
                                      ext: String) throws -> URL {
        try validateShard(shardDir)
        let file = fileName(aGen: aGen, aId: aId, bGen: bGen, bId: bId, ext: ext)
        let target = flockRoot.resolvingSymlinksInPath()
            .appendingPathComponent(shardDir)
            .appendingPathComponent("mpeg")
            .appendingPathComponent(file)
        try ensureInside(flockRoot: flockRoot, target: target)
        return target
    }

    /// Path-safety-checked thumbnail URL. Same shard + inside-root guards as
    /// `archiveFileURL`. Layout: `<root>/<shard>/jpeg/<file>.jpg`.
    public static func thumbURL(flockRoot: URL, shardDir: String,
                                aGen: String, aId: String, bGen: String, bId: String) throws -> URL {
        try validateShard(shardDir)
        let file = fileName(aGen: aGen, aId: aId, bGen: bGen, bId: bId, ext: "jpg")
        let target = flockRoot.resolvingSymlinksInPath()
            .appendingPathComponent(shardDir)
            .appendingPathComponent("jpeg")
            .appendingPathComponent(file)
        try ensureInside(flockRoot: flockRoot, target: target)
        return target
    }

    /// Public predicate (used by `FlockCatalog.rebuild` to filter shard dirs on
    /// disk). Accepts `^[A-Za-z0-9_-]+$` (admits the `-` in non-canonical shard
    /// names) — the explicit `/` and `..` checks run before the regex as
    /// defense-in-depth.
    public static func isValidShardName(_ s: String) -> Bool {
        !s.contains("/") && !s.contains("..") &&
            shardRegex.firstMatch(in: s, range: NSRange(location: 0, length: s.utf16.count)) != nil
    }

    // MARK: - Internal helpers

    private static func validateShard(_ s: String) throws {
        guard isValidShardName(s) else { throw FlockNamingError.badShardName(s) }
    }

    private static func ensureInside(flockRoot: URL, target: URL) throws {
        let root = flockRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let tgt = target.resolvingSymlinksInPath().standardizedFileURL.path
        guard tgt.hasPrefix(root + "/") || tgt == root else { throw FlockNamingError.escapesRoot }
    }
}
