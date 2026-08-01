import SwiftUI

/// A compact cheat-sheet of the app's keyboard shortcuts, presented as a
/// `.popover` from the `?` button in the library toolbar and the playback
/// transport bar (P6 — recognition over recall: shortcuts are invisible by
/// default; this makes them discoverable on intent).
///
/// Plain SwiftUI only (no external deps). Static text — rule #2 (determinism)
/// is n/a; no float sums over hashed collections anywhere.
struct KeyboardHelpView: View {
    /// When false, the Library group is hidden (used by the playback window,
    /// where only the Preview shortcuts apply). Defaults to true so the
    /// library popover shows both groups.
    var includesLibrary: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if includesLibrary {
                group("Library", shortcuts: libraryShortcuts)
            }
            group("Preview", shortcuts: previewShortcuts)
        }
        .padding(16)
        .frame(width: 300)
    }

    // MARK: - Rows

    @ViewBuilder
    private func group(_ title: String, shortcuts: [Shortcut]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(shortcuts) { s in
                    GridRow {
                        Text(s.key)
                            .font(.system(.callout, design: .monospaced).weight(.medium))
                            .foregroundStyle(.secondary)
                            .gridCellAnchor(.leading)
                        Text(s.action)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                            .gridCellAnchor(.leading)
                    }
                }
            }
        }
    }

    // MARK: - Shortcut tables (static, deterministic)

    private let libraryShortcuts: [Shortcut] = [
        .init(key: "⌘A", action: "Select all (filtered)"),
        .init(key: "Esc", action: "Clear selection"),
        .init(key: "Click", action: "Open preview"),
        .init(key: "⌘ / Ctrl-click", action: "Toggle selection"),
        .init(key: "Shift-click", action: "Range select"),
        .init(key: "Drag .flam3", action: "Import files"),
        .init(key: "⌘1…⌘5", action: "Sidebar: All / Library / Liked / Imported / Dir"),
        .init(key: "⌘\\", action: "Toggle inspector"),
    ]

    private let previewShortcuts: [Shortcut] = [
        .init(key: "Space", action: "Play / pause"),
        .init(key: "Esc", action: "Close window"),
        .init(key: "+", action: "Like"),
        .init(key: "0", action: "Neutral"),
        .init(key: "−", action: "Dislike"),
        .init(key: "Click video", action: "Play / pause"),
    ]
}

/// One row of the cheat-sheet: a key glyph and the action it performs.
/// `id` derives from `key` (unique within a group) so `ForEach` identity is
/// stable across body evaluations (no per-init `UUID()` churn).
private struct Shortcut: Identifiable {
    let key: String
    let action: String
    var id: String { key }
}
