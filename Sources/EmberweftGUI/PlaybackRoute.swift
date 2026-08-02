import Foundation
import EmberweftUI

/// A Codable route value that identifies a genome for the non-modal playback
/// window (`WindowGroup("Playback", for: PlaybackRoute.self)`).
///
/// `LibraryEntry` is not `Codable`, so this carries just the fields needed to
/// (a) route one window per genome (identity = stored fields) and (b) resolve
/// the live `LibraryEntry` from `AppModel` after the window opens. Lives in
/// `EmberweftGUI` (not `EmberweftUI`) because `resolve` reads `AppModel`.
///
/// **Determinism (rule #2):** `Codable` uses the synthesized, key-ordered
/// encoder (stable across launches). Identity (`Hashable`) is derived from the
/// stored fields, so `WindowGroup(for:)` opens exactly one window per genome.
/// No float sums over hashed collections anywhere here.
struct PlaybackRoute: Codable, Hashable, Sendable {
    /// Which `LoadState` the genome lives in: `"bundle"` / `"imported"` /
    /// `"directory"` (mirrors `LibrarySource`, minus the associated URL, which
    /// is carried separately as `rootPath`).
    let source: String
    /// Only set for `.directory` (the scanned root's path); `nil` for bundle and
    /// imported sources. Directory entries' `id` is unique per root, so matching
    /// `(rootPath, id)` is unambiguous.
    let rootPath: String?
    /// `LibraryEntry.id` (unique within `(source, rootPath)`).
    let id: String
    /// Absolute URL of the `.flam3` file.
    let fileURL: URL
    /// File stem — the display label.
    let displayName: String

    /// Build a route from a live entry.
    init(_ entry: LibraryEntry) {
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

    /// Find the live `LibraryEntry` in the matching `LoadState`. Returns `nil`
    /// when the genome is gone (folder removed from the library, rescanned away,
    /// file removed, or the section still loading) — the caller shows a
    /// "no longer available" placeholder.
    ///
    /// For `.directory` the route resolves against the SPECIFIC opened folder
    /// matching `rootPath` (multi-folder: any opened folder, not just a single
    /// primary one), so a stale route into a folder no longer in the library
    /// never resolves.
    @MainActor
    func resolve(model: AppModel) -> LibraryEntry? {
        let entries: [LibraryEntry]
        switch source {
        case "bundle":
            guard case .ready(let e) = model.bundleLoadState else { return nil }
            entries = e
        case "directory":
            guard let state = model.directoryLoadState(forRootPath: rootPath ?? ""),
                  case .ready(let e) = state else { return nil }
            entries = e
        case "imported":
            guard case .ready(let e) = model.importedLoadState else { return nil }
            entries = e
        default:
            return nil
        }
        return entries.first { $0.id == id }
    }
}
