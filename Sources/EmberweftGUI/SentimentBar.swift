import SwiftUI
import EmberweftUI

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
    }

    /// "Add to ▾" submenu — appends the whole selection (deterministically
    /// ordered by identity — rule #2: never persist Set iteration order) to an
    /// existing collection. Disabled when there are no collections.
    private var addToSelectionMenu: some View {
        Menu {
            if model.collectionsStore.collections.isEmpty {
                Button("No collections yet") {}.disabled(true)
            } else {
                ForEach(model.collectionsStore.collections) { c in
                    Button(c.name) { addToSelection(c.id, named: c.name) }
                }
            }
        } label: {
            Label("Add to", systemImage: "plus.rectangle.on.rectangle")
        }
        .help("Add the selection to an existing collection")
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
