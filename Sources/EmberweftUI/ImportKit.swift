import Foundation

/// Pure, testable helpers for drag-and-drop `.flam3` import. The I/O (parse +
/// copy) lives in `AppModel`; these plan the copy deterministically and defend
/// against path traversal / bad filenames.

/// A planned import: the source file URL + the sanitized, deduped destination stem.
public struct ImportPlan: Equatable, Sendable {
    public let source: URL
    public let destStem: String
    public init(source: URL, destStem: String) { self.source = source; self.destStem = destStem }
}

/// Sanitize a dropped filename to a bare stem (no extension), or `nil` if it must
/// be rejected: path traversal (any `/` or `\`), hidden (leading `.`), empty, or
/// any char outside `[A-Za-z0-9._-]`. A real dropped-file URL's `lastPathComponent`
/// never contains a separator, so the separator check is a paranoid defense against
/// raw pathy input.
public func sanitizeImportStem(_ filename: String) -> String? {
    if filename.contains("/") || filename.contains("\\") { return nil }
    let last = (filename as NSString).lastPathComponent
    guard !last.isEmpty, !last.hasPrefix(".") else { return nil }
    let allowed = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
    guard last.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
    let stem = (last as NSString).deletingPathExtension
    guard !stem.isEmpty, !stem.hasPrefix(".") else { return nil }
    return stem
}

/// Dedup a stem against existing stems: `stem`, then `stem-2`, `stem-3`, … (lowest
/// free n ≥ 2). Deterministic.
public func dedupedStem(_ stem: String, existing: Set<String>) -> String {
    if !existing.contains(stem) { return stem }
    var n = 2
    while existing.contains("\(stem)-\(n)") { n += 1 }
    return "\(stem)-\(n)"
}

/// Build the import plan for a batch of dropped URLs: keep only `.flam3`, sanitize
/// each, and dedup against `existingStems` AND within the batch. Rejected URLs
/// (non-`.flam3` or unsanitary) are silently omitted; the caller counts them.
public func planImports(urls: [URL], existingStems: Set<String>) -> [ImportPlan] {
    var used = existingStems
    var out: [ImportPlan] = []
    for url in urls where url.pathExtension.lowercased() == "flam3" {
        guard let stem = sanitizeImportStem(url.lastPathComponent) else { continue }
        let dest = dedupedStem(stem, existing: used)
        used.insert(dest)
        out.append(ImportPlan(source: url, destStem: dest))
    }
    return out
}
