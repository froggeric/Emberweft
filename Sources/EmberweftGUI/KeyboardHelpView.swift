import SwiftUI

/// A compact cheat-sheet of the app's keyboard shortcuts, presented as a
/// `.popover` from the `?` button in the library toolbar and both playback
/// transport bars (P6 — recognition over recall: shortcuts are invisible by
/// default; this makes them discoverable on intent).
///
/// Data-driven from ONE table (`allShortcuts`): each row carries the window
/// scope it belongs to, and the presented groups are filtered by `context` —
/// so the sheet can't drift out of sync with itself across windows the way
/// three hand-maintained tables could. Key glyphs are the REAL bindings
/// (e.g. "=" not "+": the sentiment keys are the bare =/- keys — a user
/// pressing shift-= per a "+" row got nothing). Mouse rows are grouped under
/// a distinct "Pointer" heading so the keyboard claims stay honest.
///
/// Plain SwiftUI only (no external deps). Static text — rule #2
/// (determinism) is n/a; no float sums over hashed collections anywhere.
struct KeyboardHelpView: View {
    /// Which window's sheet is showing — drives the groups presented.
    enum Context { case library, playback, sequence }

    var context: Context = .library

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            group("General", rows(.app))
            switch context {
            case .library:
                group("Library", rows(.library))
                pointerGroup(rows(.pointerLibrary))
            case .playback:
                group("Preview", rows(.playback))
                pointerGroup(rows(.pointerVideo))
            case .sequence:
                group("Sequence", rows(.sequence))
                pointerGroup(rows(.pointerVideo))
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    // MARK: - Rows

    @ViewBuilder
    private func group(_ title: String, _ shortcuts: [Shortcut]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            shortcutGrid(shortcuts)
        }
    }

    /// Same grid as `group`, but under a secondary "Pointer" header — these
    /// are mouse actions, not keyboard shortcuts, and the sheet shouldn't
    /// claim them as keyboard paths.
    @ViewBuilder
    private func pointerGroup(_ shortcuts: [Shortcut]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pointer")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            shortcutGrid(shortcuts)
        }
    }

    @ViewBuilder
    private func shortcutGrid(_ shortcuts: [Shortcut]) -> some View {
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

    private func rows(_ scope: Shortcut.Scope) -> [Shortcut] {
        allShortcuts.filter { $0.scope == scope }
    }

    // MARK: - The one source of truth (static, deterministic)

    private let allShortcuts: [Shortcut] = [
        // App-wide (menu-bar-backed, C2).
        .init(key: "⌘O", action: "Open a directory of genomes", scope: .app),
        .init(key: "⇧⌘I", action: "Import genome files", scope: .app),
        .init(key: "⌘F", action: "Search", scope: .app),
        .init(key: "⇧⌘F", action: "Filter", scope: .app),
        .init(key: "⌃⌘S", action: "Toggle sidebar", scope: .app),
        .init(key: "⌘?", action: "This shortcut list", scope: .app),

        // Library grid (C1 keyboard navigation).
        .init(key: "↑ ← ↓ →", action: "Move focus and select", scope: .library),
        .init(key: "⇧-arrows", action: "Extend the selection", scope: .library),
        .init(key: "Return / ⌘↓", action: "Open the focused or selected genome", scope: .library),
        .init(key: "⌘A", action: "Select all (filtered)", scope: .library),
        .init(key: "Esc", action: "Clear selection", scope: .library),
        .init(key: "⇧⌘E", action: "Export the selection", scope: .library),
        .init(key: "⌘1…⌘4", action: "Sidebar: All / Library / Liked / Imported", scope: .library),

        // Single-genome preview window. "=" / "-" are the literal bindings
        // (bare keys, no shift) — never dress them up as "+" / "−".
        .init(key: "Space", action: "Play / pause", scope: .playback),
        .init(key: "← / →", action: "Scrub one frame", scope: .playback),
        .init(key: "=", action: "Like", scope: .playback),
        .init(key: "0", action: "Neutral", scope: .playback),
        .init(key: "-", action: "Dislike", scope: .playback),
        .init(key: "Esc", action: "Close window", scope: .playback),

        // Collection sequence window.
        .init(key: "Space", action: "Play / pause", scope: .sequence),
        .init(key: "R", action: "Restart from the first genome", scope: .sequence),
        .init(key: "Esc", action: "Close window", scope: .sequence),

        // Pointer actions (library grid).
        .init(key: "Click", action: "Select a card", scope: .pointerLibrary),
        .init(key: "Double-click", action: "Open preview", scope: .pointerLibrary),
        .init(key: "⌘ / Ctrl-click", action: "Toggle selection", scope: .pointerLibrary),
        .init(key: "⇧-click", action: "Extend the selection", scope: .pointerLibrary),
        .init(key: "Drag .flam3", action: "Import files", scope: .pointerLibrary),

        // Pointer actions (playback surfaces).
        .init(key: "Click video", action: "Play / pause", scope: .pointerVideo),
    ]
}

/// One row of the cheat-sheet: a key glyph, the action it performs, and the
/// window scope it belongs to. `id` derives from `key`+`scope` (unique within
/// a presented group) so `ForEach` identity is stable across body evaluations
/// (no per-init `UUID()` churn).
private struct Shortcut: Identifiable {
    enum Scope { case app, library, playback, sequence, pointerLibrary, pointerVideo }
    let key: String
    let action: String
    let scope: Scope
    var id: String { "\(scope)|\(key)" }
}
