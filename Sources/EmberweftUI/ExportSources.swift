import Foundation
import FlameKit
import FlameExport

/// Pure construction of `[ExportCheckpoint.Source]` for the GUI export entry
/// points (M6.1, spec §5.2 / D6). Lives in `EmberweftUI` (NOT `EmberweftGUI`) so
/// the `flameIndex` / `serializedText` logic is unit-tested.
///
/// **Why this exists:** a GUI construction bug here previously broke resume —
/// `flameIndex` was set to the sequence *position*, but it must be the index
/// WITHIN each source's parsed content (each source is one flame ⇒ 0).
/// `parse(serializedText)` returns a single flame, so a position-based
/// `flameIndex ≥ 1` was out of bounds ⇒ `ExportError.checkpointSourceChanged`.
/// (EmberweftGUI has no test target, so the bug was invisible to the suite.)
public enum ExportSources {

    /// One source for a single-genome export. File-backed ⇒ SHA-256-gated resume
    /// (the D6-strong path; the coordinator computes the hash at checkpoint-write
    /// time). A nil `fileURL` ⇒ the `serializedText` fallback so resume still works.
    public static func single(flame: Flame, fileURL: URL?, displayName: String) -> [ExportCheckpoint.Source] {
        [ExportCheckpoint.Source(
            fileURL: fileURL, flameIndex: 0, sha256: nil,
            serializedText: fileURL == nil ? Flam3Serializer.serialize([flame]) : nil,
            displayName: displayName)]
    }

    /// One source per flame for a sequence export. `flameIndex` is the index
    /// WITHIN each source's parsed content (0 — each source is ONE flame: the
    /// serialized text is a single-flame document, and a fileURL is the GUI's
    /// single-flame-per-file load), NOT the sequence position. A nil `fileURL`
    /// slot ⇒ the `serializedText` fallback for that flame.
    public static func sequence(flames: [Flame], fileURLs: [URL]?, displayName: String) -> [ExportCheckpoint.Source] {
        flames.enumerated().map { (i, flame) in
            let url = fileURLs?[i]
            return ExportCheckpoint.Source(
                fileURL: url,
                flameIndex: 0,
                sha256: nil,
                serializedText: url == nil ? Flam3Serializer.serialize([flame]) : nil,
                displayName: "\(displayName) #\(i + 1)")
        }
    }
}
