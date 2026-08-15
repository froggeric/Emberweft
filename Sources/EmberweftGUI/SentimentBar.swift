import SwiftUI
import EmberweftUI
import FlameKit

/// Tri-state sentiment control (−1 dislike / 0 neutral / +1 like), direct-set.
/// Redundant color + glyph + left→right mapping onto the negative→positive
/// spectrum (preattentive; color-blind safe). Used both as a full-width hover bar
/// on cards and (compact) in the playback transport.
struct SentimentBar: View {
    @Environment(AppModel.self) private var model
    let entry: LibraryEntry

    private var sentiment: Int { model.metadataStore.metadata(for: entry).sentiment }

    var body: some View {
        HStack(spacing: 0) {
            segment(-1, "hand.thumbsdown", .red, "Dislike")
            segment(0, "circle", .secondary, "Neutral")
            segment(1, "hand.thumbsup", .green, "Like")
        }
        .frame(maxWidth: .infinity, minHeight: 30)
        .background(.ultraThinMaterial.opacity(0.92), in: RoundedRectangle(cornerRadius: 6))
    }

    private func segment(_ value: Int, _ icon: String, _ tint: Color, _ label: String) -> some View {
        let active = sentiment == value
        return Button {
            model.metadataStore.setSentiment(value, for: entry)
        } label: {
            Image(systemName: active ? "\(icon).fill" : icon)
                .foregroundStyle(active ? tint : Color.secondary.opacity(0.7))
                .frame(maxWidth: .infinity, minHeight: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .symbolEffect(.bounce, value: active)
        .accessibilityLabel(label)
    }
}

/// Compact always-on badge for *marked* (non-neutral) cells — preattentive scan
/// without hover. Hidden when neutral (the common case keeps the grid calm).
struct SentimentBadge: View {
    @Environment(AppModel.self) private var model
    let entry: LibraryEntry
    private var sentiment: Int { model.metadataStore.metadata(for: entry).sentiment }

    var body: some View {
        if sentiment != 0 {
            let liked = sentiment == 1
            Image(systemName: liked ? "hand.thumbsup.fill" : "hand.thumbsdown.fill")
                .foregroundStyle(liked ? Color.green : Color.red)
                .font(.caption)
                .padding(5)
                .background(.ultraThinMaterial, in: Circle())
                .accessibilityLabel(liked ? "Liked" : "Disliked")
        }
    }
}

/// Bottom-floating selection bar with bulk actions (Mail/Files pattern). Appears
/// the instant a selection exists; carries the count + the payoff. Adds collection
/// actions: "Save as Collection…" (creates a new playlist from the selection) and
/// "Add to ▾" (appends the selection to an existing collection).
struct SelectionBar: View {
    @Environment(AppModel.self) private var model

    /// Presents the "Save as Collection…" name sheet.
    @State private var showCreateSheet = false
    @State private var newName = ""

    /// Export state (spec §4.8, extended Task 16). The selection is async-loaded
    /// into `exportItems` deterministically (sorted by `GenomeCollectionAppOrder.key`
    /// — rule #2: never persist `Set` iteration order), dropping unparseable /
    /// non-renderable genomes; skips are surfaced via an alert before the sheet.
    /// `singleFileURL` is the first loaded entry's URL, used ONLY when exactly one
    /// genome is loaded — it routes the sheet to `.single` (file-URL-backed ⇒
    /// SHA-256-gated resume); a multi-selection stays on the `.batch` path.
    @State private var isLoadingExport = false
    @State private var exportItems: [(flame: Flame, name: String)] = []
    @State private var singleFileURL: URL?
    @State private var exportSkipCount = 0
    @State private var showExportSheet = false
    @State private var showExportSkipAlert = false

    var body: some View {
        HStack(spacing: 12) {
            Text("\(model.selection.count) selected").font(.body).monospacedDigit()
            Divider().frame(height: 18)
            Button { model.applySentiment(1, to: model.selection) } label: {
                Label("Like", systemImage: "hand.thumbsup")
            }
            Button { model.applySentiment(-1, to: model.selection) } label: {
                Label("Dislike", systemImage: "hand.thumbsdown")
            }
            Divider().frame(height: 18)
            Button { showCreateSheet = true } label: {
                Label("Save as Collection…", systemImage: "list.bullet.rectangle")
            }
            addToSelectionMenu
            Divider().frame(height: 18)
            Button {
                Task { await loadSelectionForExport() }
            } label: {
                if isLoadingExport {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Loading…")
                    }
                } else {
                    Label("Export…", systemImage: "square.and.arrow.up")
                }
            }
            .disabled(model.selection.isEmpty)
            .help("Export the selection as video (one selection → one video; multiple → one video each). Skips unrenderable genomes.")
            // The Export sheet is attached to THIS button (not the root HStack)
            // so it coexists with the root's "Save as Collection…" sheet — SwiftUI
            // does not reliably present two `.sheet(isPresented:)` on one view, but
            // two sheets on two DIFFERENT views do. The button is always in the
            // hierarchy while the sheet could present (`disabled`, not hidden,
            // while loading), so presentation is reliable.
            .sheet(isPresented: $showExportSheet) {
                // Count-routed (Task 16 decouple): a single selected genome exports
                // via `.single` (one video, file-URL-backed for SHA-256 resume — the
                // P8 strong path); a multi-selection stays on `.batch` (one video per
                // genome, the proven SelectionBar path). `singleFileURL` is captured
                // in `loadSelectionForExport` for the first loaded entry.
                if exportItems.count == 1 {
                    ExportSheet(source: .single(flame: exportItems[0].flame,
                                                name: exportItems[0].name,
                                                fileURL: singleFileURL))
                } else {
                    ExportSheet(source: .batch(items: exportItems))
                }
            }
            Divider().frame(height: 18)
            Button { model.clearSelection() } label: {
                Label("Clear", systemImage: "xmark").labelStyle(.titleAndIcon)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 6, y: 2)
        .sheet(isPresented: $showCreateSheet) {
            NameCollectionSheet(title: "New Collection",
                                 confirmLabel: "Create",
                                 name: $newName) {
                saveFromSelection()
            } onCancel: {
                newName = ""
            }
        }
        .alert("Export selected genomes", isPresented: $showExportSkipAlert) {
            if exportItems.isEmpty {
                // Nothing renderable — no sheet to follow.
                Button("OK", role: .cancel) {}
            } else {
                Button("Export \(exportItems.count)") { showExportSheet = true }
                Button("Cancel", role: .cancel) {}
            }
        } message: {
            if exportItems.isEmpty {
                Text("None of the \(exportSkipCount) selected genome\(exportSkipCount == 1 ? "" : "s") could be loaded for export (unparseable or degenerate).")
            } else {
                Text("Skipped \(exportSkipCount) genome\(exportSkipCount == 1 ? "" : "s") that could not be loaded or rendered. \(exportItems.count) will be exported.")
            }
        }
    }

    /// Async-load the selection into `exportItems` for the Export sheet
    /// (spec §4.8). Mirrors `saveFromSelection()`'s deterministic sort
    /// (`GenomeCollectionAppOrder.key` — rule #2: never persist `Set` order): loads
    /// each genome via `libraryIndex.loadGenome(for:)`, drops unparseable /
    /// non-renderable ones, and surfaces the skip count via an alert (confirm-to-
    /// proceed when partial; an "all skipped" notice when nothing is exportable).
    /// `singleFileURL` captures the first loaded entry's URL so a one-genome
    /// selection routes to `.single` (file-URL-backed resume).
    private func loadSelectionForExport() async {
        isLoadingExport = true
        defer { isLoadingExport = false }
        let sorted = model.selection
            .sorted { GenomeCollectionAppOrder.key($0) < GenomeCollectionAppOrder.key($1) }
        var items: [(flame: Flame, name: String)] = []
        var skips = 0
        var firstURL: URL?
        for entry in sorted {
            if let flame = try? await model.libraryIndex.loadGenome(for: entry), flame.isRenderable {
                if items.isEmpty { firstURL = entry.fileURL }
                items.append((flame: flame, name: entry.displayName))
            } else {
                skips += 1
            }
        }
        exportItems = items
        singleFileURL = firstURL
        exportSkipCount = skips
        if items.isEmpty || skips > 0 {
            showExportSkipAlert = true
        } else {
            showExportSheet = true
        }
    }

    /// "Add to ▾" submenu — leads with "New Collection…" (the same create-from-
    /// selection sheet the standalone button opens — create AND add in one step,
    /// so the menu is never a dead end on an empty store), then appends the
    /// whole selection (deterministically ordered by identity — rule #2: never
    /// persist Set iteration order) to an existing collection.
    private var addToSelectionMenu: some View {
        Menu {
            Button {
                showCreateSheet = true
            } label: {
                Label("New Collection…", systemImage: "plus")
            }
            ForEach(model.collectionsStore.collections) { c in
                Button(c.name) { addToSelection(c.id, named: c.name) }
            }
        } label: {
            Label("Add to", systemImage: "plus.rectangle.on.rectangle")
        }
        .help("Add the selection to an existing collection, or create a new one for it")
    }

    /// Create a new collection from the current selection (deterministic order:
    /// sorted by `(source, rootPath, id)` — rule #2), then clear the selection.
    private func saveFromSelection() {
        let entries = model.selection
            .sorted { GenomeCollectionAppOrder.key($0) < GenomeCollectionAppOrder.key($1) }
            .map(CollectionEntry.init)
        model.collectionsStore.create(name: newName, from: entries)
        newName = ""
        model.clearSelection()
    }

    /// Append the selection to an existing collection (deterministic order).
    private func addToSelection(_ id: UUID, named name: String) {
        let entries = model.selection
            .sorted { GenomeCollectionAppOrder.key($0) < GenomeCollectionAppOrder.key($1) }
            .map(CollectionEntry.init)
        model.collectionsStore.addEntries(entries, to: id)
        // The "Added N to X" toast lives in LibraryView; SelectionBar has none.
        model.clearSelection()
    }
}

/// Deterministic sort key for selection → collection ordering. Selection is a
/// `Set` (hash-randomized per process — rule #2), so persisting its iteration
/// order would be non-reproducible. This key sorts by `(source, rootPath, id)`,
/// the same triple `PlaybackRoute`/`CollectionEntry` resolve on, so the order is
/// stable across launches and machines.
enum GenomeCollectionAppOrder {
    static func key(_ e: LibraryEntry) -> String {
        CollectionEntry(e).identity
    }
}

/// Small sheet with a name `TextField` + Create/Rename + Cancel. Used for both
/// "Save as Collection…" and "Rename…". A `.sheet` (rather than `.alert` +
/// `TextField`) for reliable macOS behavior. Return confirms, Esc cancels.
struct NameCollectionSheet: View {
    let title: String
    let confirmLabel: String
    @Binding var name: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        VStack(spacing: 14) {
            Text(title).font(.headline)
            TextField("Collection name", text: $name)
                .focused($nameFieldFocused)
                .onSubmit(onConfirm)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel", action: onCancel).keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button(confirmLabel, action: onConfirm)
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                              && confirmLabel == "Create")
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear { nameFieldFocused = true }
    }
}
