import AppKit
import UniformTypeIdentifiers

// Standard AppKit file-panel runners for the export destination picker (spec
// §4.6 / G7). These work on the bundle-less SwiftPM executable because
// `EmberweftApp` sets the `.regular` activation policy (EmberweftApp.swift:11 —
// CLAUDE.md). This path is UNRELATED to the broken in-app `.draggable`/
// `.dropDestination` reorder gotcha (which is about pasteboard `Transferable`
// in-grid reorder, not system file panels).

/// Present an `NSSavePanel` for choosing a single output file URL (single /
/// sequence export). Returns nil if the user cancels.
///
/// `defaultName` carries the container-derived extension (the caller passes
/// `<stem>.mp4` or `<stem>.mov`). The panel accepts both `.mpeg4Movie` and
/// `.quickTimeMovie` so the user can override the extension in the name field
/// either way. `NSSavePanel`'s overwrite confirmation is the SINGLE overwrite
/// gate; the coordinator's atomic `<out>.partial-<pid>` -> rename (engine D13)
/// never clobbers a good file on a failed run.
@MainActor
func chooseSaveURL(defaultName: String, suggestedDir: URL? = nil) -> URL? {
    let panel = NSSavePanel()
    panel.title = "Export Video"
    panel.prompt = "Export"
    panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
    panel.nameFieldStringValue = defaultName
    if let dir = suggestedDir { panel.directoryURL = dir }
    guard panel.runModal() == .OK else { return nil }
    return panel.url
}

/// Present an `NSOpenPanel` for choosing a directory (batch export base dir).
/// Returns nil if the user cancels. Each entry's filename is resolved by
/// `ExportManager.exportBatch` via `FlameExport.BatchPath.resolve` (the D13
/// gate) with `-2/-3` dedup — the caller just passes `items` + `baseDir`.
@MainActor
func chooseDirectory(suggestedDir: URL? = nil) -> URL? {
    let panel = NSOpenPanel()
    panel.title = "Choose Export Directory"
    panel.prompt = "Export Here"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    if let dir = suggestedDir { panel.directoryURL = dir }
    guard panel.runModal() == .OK else { return nil }
    return panel.url
}
