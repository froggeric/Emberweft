import SwiftUI
import EmberweftUI
import FlameKit

/// A playback window hosting `FlameUIView` for one clicked genome.
struct PlaybackWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let entry: LibraryEntry

    @State private var vm = PlaybackViewModel()
    @State private var loadError: String?
    @State private var degenerate = false

    var body: some View {
        VStack(spacing: 0) {
            FlameUIView(vm.sinkView)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .contentShape(Rectangle())
                .onTapGesture { vm.togglePlaying() }
                .accessibilityAdjustableAction { _ in vm.togglePlaying() }
            bar
        }
        .frame(minWidth: 640, minHeight: 420)
        .task(id: entry.id) { await start() }
        .onDisappear { vm.beginStop() }
        // Keyboard: Space toggles play/pause, Esc closes.
        .background {
            // Hidden buttons carry the keyboard shortcuts (Space/Esc) + on-the-fly
            // sentiment adjustment (+/-) for the playing genome.
            Group {
                Button("Play/Pause") { vm.togglePlaying() }
                    .keyboardShortcut(" ", modifiers: [])
                Button("Close") { close() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Like") { model.metadataStore.adjustSentiment(for: entry, by: 1) }
                    .keyboardShortcut("=", modifiers: [])
                Button("Dislike") { model.metadataStore.adjustSentiment(for: entry, by: -1) }
                    .keyboardShortcut("-", modifiers: [])
            }
            .hidden()
        }
        .alert("Could not open genome", isPresented: Binding(
            get: { loadError != nil }, set: { if !$0 { loadError = nil } })) {
            Button("Close") { dismiss() }
        } message: { Text(loadError ?? "") }
        .alert("Degenerate genome", isPresented: $degenerate) {
            Button("Open anyway", role: .destructive) { Task { await forceStart() } }
            Button("Cancel", role: .cancel) { dismiss() }
        } message: {
            Text("\"\(entry.displayName)\" has a NaN/degenerate camera and will render solid black.")
        }
    }

    private var bar: some View {
        HStack(spacing: 14) {
            Button { vm.togglePlaying() } label: {
                Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill").font(.title3)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(vm.isPlaying ? "Pause" : "Play")
            .accessibilityHint("Space")

            Slider(value: Binding(get: { vm.position },
                                  set: { p in Task { await vm.scrub(to: p) } }),
                   in: 0...1)
            .accessibilityLabel("Loop position")
            .accessibilityValue("\(Int(vm.position * 100)) percent")
            .accessibilityHint("Scrub the loop")

            Text(entry.displayName).font(.headline).lineLimit(1)
            Button("Close") { close() }
        }
        .padding(10)
        .background(.bar)
    }

    /// Stop deterministically, then dismiss.
    private func close() { Task { await vm.stop(); dismiss() } }

    private func start() async {
        do {
            let flame = try await model.libraryIndex.loadGenome(for: entry)
            if !flame.isRenderable { degenerate = true; return }
            begin(flame: flame)
        } catch {
            loadError = "\(error.localizedDescription)"
        }
    }

    private func forceStart() async {
        if let flame = try? await model.libraryIndex.loadGenome(for: entry) {
            begin(flame: flame)
        }
    }

    private func begin(flame: Flame) {
        let params = model.prefs.previewParams()
        vm.load(flame: flame, params: params,
                backend: model.prefs.backend,
                targetFPS: Double(model.prefs.targetFPS))
        vm.play()
    }
}
