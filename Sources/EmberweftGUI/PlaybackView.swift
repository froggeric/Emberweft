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
            bar
        }
        .frame(minWidth: 640, minHeight: 420)
        .task(id: entry.id) {
            await start()
        }
        .onDisappear { vm.beginStop() }
        .alert("Could not open genome", isPresented: Binding(
            get: { loadError != nil }, set: { if !$0 { loadError = nil } })) {
            Button("Close") { dismiss() }
        } message: {
            Text(loadError ?? "")
        }
        .alert("Degenerate genome", isPresented: $degenerate) {
            Button("Open anyway", role: .destructive) { Task { await forceStart() } }
            Button("Cancel", role: .cancel) { dismiss() }
        } message: {
            Text("\"\(entry.displayName)\" has a NaN/degenerate camera and will render solid black.")
        }
    }

    private var bar: some View {
        HStack {
            Text(entry.displayName).font(.headline)
            Spacer()
            if vm.isPlaying {
                Label("Playing", systemImage: "play.fill").foregroundStyle(.green)
            }
            Button("Close") { close() }
        }
        .padding(10)
        .background(.bar)
    }

    /// Stop playback deterministically, then dismiss. Awaiting `stop()` before
    /// `dismiss()` guarantees the dispatcher is quiesced (no orphaned GPU work)
    /// even though the view-model is `@State` that SwiftUI tears down on dismiss.
    private func close() {
        Task { await vm.stop(); dismiss() }
    }

    private func start() async {
        do {
            let flame = try await model.libraryIndex.loadGenome(for: entry)
            if !flame.isRenderable {
                degenerate = true
                return
            }
            await begin(flame: flame)
        } catch {
            loadError = "\(error.localizedDescription)"
        }
    }

    private func forceStart() async {
        if let flame = try? await model.libraryIndex.loadGenome(for: entry) {
            await begin(flame: flame)
        }
    }

    private func begin(flame: Flame) async {
        // Preview renders at a small internal resolution (previewWidth×Height)
        // with low spp; the CAMetalLayer scales it up to the window. Fast, with
        // minor softness — independent of the (full-quality) preset.
        let params = model.prefs.previewParams()
        await vm.start(flame: flame, params: params,
                       backend: model.prefs.backend,
                       targetFPS: Double(model.prefs.targetFPS))
    }
}
