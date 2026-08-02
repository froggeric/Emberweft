import SwiftUI
import EmberweftUI
import FlameKit

/// A Codable route that opens the sequence-playback window for one collection
/// (`WindowGroup("Collection Playback", for: CollectionPlaybackRoute.self)`).
/// Carries only the collection id; the live `GenomeCollection` + its resolved
/// genomes are re-fetched from `CollectionsStore` after the window opens, so a
/// deleted/edited collection is reflected without a stale snapshot. Mirrors
/// `PlaybackRoute`'s value-driven, one-window-per-identity pattern.
struct CollectionPlaybackRoute: Codable, Hashable, Sendable {
    let id: UUID
}

/// Playback window for a collection's "Play as Sequence": resolves the stored
/// entries to live genomes, loads their flames, and drives the
/// `PlaybackDispatcher` (loop + transition segments via a `Sequential` walk)
/// through `SequencePlaybackViewModel`. The multi-genome counterpart of
/// `PlaybackWindow`.
///
/// Reuses unchanged: `FlameUIView`, `AppModel.libraryIndex` (parse), the
/// production `Renderer`/`WallClock`/`FlameUI` sink (inside the VM). The
/// single-genome `PlaybackWindow` is untouched.
struct CollectionPlaybackWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let collectionId: UUID

    @State private var vm = SequencePlaybackViewModel()
    @State private var collectionDeleted = false
    @State private var collectionName = ""

    var body: some View {
        VStack(spacing: 0) {
            if let err = windowError {
                ContentUnavailableView(
                    err.title,
                    systemImage: "list.bullet.rectangle",
                    description: Text(err.message)
                )
                .frame(minWidth: 480, minHeight: 320)
            } else {
                FlameUIView(vm.sinkView)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .contentShape(Rectangle())
                    .onTapGesture { vm.togglePlaying() }
                bar
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .task(id: collectionId) { await load() }
        .onDisappear { vm.beginStop() }
        // Keyboard: Space toggles play/pause, R restarts, Esc closes.
        .background {
            Group {
                Button("Play/Pause") { vm.togglePlaying() }
                    .keyboardShortcut(" ", modifiers: [])
                Button("Restart") { vm.restart() }
                    .keyboardShortcut("r", modifiers: [])
                Button("Close") { close() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .hidden()
        }
    }

    /// The active error (collection gone / no renderable genomes), if any.
    private var windowError: (title: String, message: String)? {
        if collectionDeleted {
            return ("Collection no longer available",
                    "This collection may have been deleted. Close this window and pick another from the sidebar.")
        }
        if let msg = vm.loadError {
            return ("Can't play this collection", msg)
        }
        return nil
    }

    private var bar: some View {
        HStack(spacing: 14) {
            Button { vm.togglePlaying() } label: {
                Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill").font(.title3)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(vm.isPlaying ? "Pause" : "Play")
            .accessibilityHint("Space")

            Button { vm.restart() } label: {
                Image(systemName: "backward.end.fill").font(.title3)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Restart from first genome")
            .accessibilityHint("R")

            // Within-segment progress (loop rotation / transition morph).
            // Non-interactive: scrubbing a multi-genome dispatcher timeline isn't
            // supported without extending the dispatcher (the same reason
            // `PlaybackViewModel` drives its single loop by hand). Shows live
            // motion feedback without implying seek.
            ProgressView(value: vm.position).frame(maxWidth: 220)
                .accessibilityLabel("Segment progress")

            genomeReadout

            Divider().frame(height: 22)

            Text(collectionName).font(.headline).lineLimit(1)
            Spacer(minLength: 0)
            Button("Close") { close() }
        }
        .padding(10)
        .background(.bar)
    }

    /// "genome i / n" readout — 1-indexed current sheep over the resolved count.
    private var genomeReadout: some View {
        Text(vm.sheepCount > 0 ? "genome \(vm.currentSheep + 1)/\(vm.sheepCount)" : "")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(minWidth: 96, alignment: .leading)
            .accessibilityLabel("Playing genome \(vm.currentSheep + 1) of \(vm.sheepCount)")
    }

    /// Stop deterministically, then dismiss.
    private func close() { Task { await vm.stop(); dismiss() } }

    /// Resolve the collection → live entries → loaded flames, then play.
    /// Genomes that no longer resolve (folder removed) or fail to parse are
    /// skipped — a removed folder never crashes playback, it just shortens it.
    private func load() async {
        guard let c = model.collectionsStore.collection(id: collectionId) else {
            collectionDeleted = true
            return
        }
        collectionName = c.name
        // Resolve stored entries to live LibraryEntries (skip unresolvable).
        let resolved = c.entries.compactMap { model.resolve($0) }
        // Parse + filter non-renderable (NaN-camera etc.). Cached by LibraryIndex
        // so repeated plays don't re-parse.
        var loaded: [Flame] = []
        for e in resolved {
            if let f = try? await model.libraryIndex.loadGenome(for: e), f.isRenderable {
                loaded.append(f)
            }
        }
        vm.load(flames: loaded, prefs: model.prefs)
        if vm.loadError == nil { vm.play() }
    }
}
