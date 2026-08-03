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
    @State private var showKeyboardHelp = false
    @State private var showPreviewQuality = false
    /// The genome loaded for playback (nil while loading / on failure). Set in
    /// `begin(flame:)` — the shared loader called by BOTH `start()` and the "Open
    /// anyway" degenerate path — so Export is enabled as soon as a flame is live,
    /// regardless of how. Drives the Export sheet's `.single` source (spec §4.8).
    @State private var loadedFlame: Flame?
    @State private var showExportSheet = false

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
        .overlay(alignment: .top) {
            // Non-blocking export-progress banner (spec §4.7). Mounted in all
            // three window types — the main window is NOT always open, and an
            // export is most often started from a playback window. Self-hides
            // (returns EmptyView) when `exportManager.state == .idle`.
            ExportProgressSurface()
        }
        .task(id: entry.id) { await start() }
        .onChange(of: previewKey) {
            // Live re-apply: the single-genome loop picks up new params next frame
            // (position + play state preserved) so the FPS readout responds live.
            vm.updateParams(model.prefs.previewParams(),
                            backend: model.prefs.backend,
                            targetFPS: Double(model.prefs.targetFPS))
        }
        .onChange(of: model.exportManager.state) { _, newState in
            // Pause the realtime preview when an export starts (frees the GPU for
            // the export and avoids a janky preview during the encode). No
            // auto-resume — the owner restarts playback manually.
            if newState == .running { vm.pause() }
        }
        .onDisappear { vm.beginStop() }
        // Keyboard: Space toggles play/pause, Esc closes.
        .background {
            // Hidden buttons carry the keyboard shortcuts: Space/Esc + set-semantics
            // sentiment (+ = like, - = dislike, 0 = neutral) for the playing genome,
            // and ←/→ to scrub one frame.
            Group {
                Button("Play/Pause") { vm.togglePlaying() }
                    .keyboardShortcut(" ", modifiers: [])
                Button("Close") { close() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Like") { model.metadataStore.setSentiment(1, for: entry) }
                    .keyboardShortcut("=", modifiers: [])
                Button("Dislike") { model.metadataStore.setSentiment(-1, for: entry) }
                    .keyboardShortcut("-", modifiers: [])
                Button("Neutral") { model.metadataStore.setSentiment(0, for: entry) }
                    .keyboardShortcut("0", modifiers: [])
                Button("Scrub back one frame") { Task { await vm.nudgeFrame(-1) } }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button("Scrub forward one frame") { Task { await vm.nudgeFrame(1) } }
                    .keyboardShortcut(.rightArrow, modifiers: [])
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
        @Bindable var model = model
        return HStack(spacing: 14) {
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
            .accessibilityHint("Scrub the loop; ←/→ step one frame")

            frameReadout

            PreviewPerfCluster(measuredFPS: vm.measuredFPS,
                               targetFPS: vm.targetFPS,
                               isPlaying: vm.isPlaying,
                               prefs: $model.prefs,
                               showPopover: $showPreviewQuality)

            Divider().frame(height: 22)

            Text(entry.displayName).font(.headline).lineLimit(1)
            SentimentBar(entry: entry).frame(width: 160)
            Divider().frame(height: 22)
            Button {
                showExportSheet = true
            } label: {
                Label("Export…", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
            .disabled(loadedFlame == nil)
            .help("Export this genome as a video")
            keyboardHelpButton
            Button("Close") { close() }
        }
        .padding(10)
        .background(.bar)
        .sheet(isPresented: $showExportSheet) {
            if let flame = loadedFlame {
                ExportSheet(source: .single(flame: flame, name: entry.displayName))
            }
        }
    }

    private var keyboardHelpButton: some View {
        Button {
            showKeyboardHelp.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
        }
        .buttonStyle(.borderless)
        .popover(isPresented: $showKeyboardHelp) {
            KeyboardHelpView(includesLibrary: false)
        }
        .accessibilityLabel("Keyboard shortcuts")
    }

    /// Frame + time readout for the transport (P8 mapping, P6 visible state).
    /// `frame N/total` derives from `position * framesPerSegment`; `M:SS / M:SS`
    /// elapsed/total derives from `targetFPS`. Monospaced digits so the readout
    /// doesn't jitter as `position` changes per frame.
    private var frameReadout: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("frame \(currentFrame)/\(vm.framesPerSegment)")
            Text("\(timeString(elapsedSeconds)) / \(timeString(totalSeconds))")
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(minWidth: 108)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Frame \(currentFrame) of \(vm.framesPerSegment), \(timeString(elapsedSeconds)) of \(timeString(totalSeconds))")
    }

    /// Current loop frame index, clamped to `[0, framesPerSegment]`.
    private var currentFrame: Int {
        let f = Int((vm.position * Double(vm.framesPerSegment)).rounded())
        return min(max(f, 0), vm.framesPerSegment)
    }

    /// A stable key over the preview-affecting prefs; a change re-applies params
    /// live via `onChange` so the FPS readout reflects the new quality/settings.
    private var previewKey: String {
        let p = model.prefs
        return "\(p.previewPreset.rawValue)|\(p.previewWidth)x\(p.previewHeight)|" +
               "spp\(p.previewSamplesPerPixel)|os\(p.previewOversample)|" +
               "be\(p.backend.rawValue)|fps\(p.targetFPS)"
    }

    /// Total loop duration in seconds (`framesPerSegment / targetFPS`).
    private var totalSeconds: Double {
        vm.targetFPS > 0 ? Double(vm.framesPerSegment) / vm.targetFPS : 0
    }

    /// Elapsed seconds within the loop (`position * total`).
    private var elapsedSeconds: Double {
        vm.position * totalSeconds
    }

    /// `M:SS` formatting (clamps negatives/non-finite to `0:00`).
    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
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
        loadedFlame = flame
        let params = model.prefs.previewParams()
        vm.load(flame: flame, params: params,
                backend: model.prefs.backend,
                targetFPS: Double(model.prefs.targetFPS))
        vm.play()
    }
}
