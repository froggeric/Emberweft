import SwiftUI
import EmberweftUI
import FlameKit
import FlameExport

/// What the sheet exports (spec §4.6). Passed in by the source window at
/// `.sheet` presentation time; the sheet reads it (no mutation) and routes to
/// the matching `ExportManager` entry point on Start. Single/sequence supply
/// their flame(s) up front; batch supplies pre-loaded `(flame, name)` pairs.
enum ExportSource {
    case single(flame: Flame, name: String)
    case sequence(flames: [Flame], name: String)
    case batch(items: [(flame: Flame, name: String)])

    /// True iff there is at least one renderable genome in the source.
    var hasRenderable: Bool {
        switch self {
        case .single(let f, _):             return f.isRenderable
        case .sequence(let fs, _):          return fs.contains { $0.isRenderable }
        case .batch(let items):             return items.contains { $0.flame.isRenderable }
        }
    }
}

/// The export config `.sheet`, bound two-way to `model.exportManager` (spec
/// §4.6 / G3 / G7). Shows a read-only source summary + editable controls for
/// resolution/quality/codec/container/fps/backend/loop-duration/temporal-samples/
/// seed.
///
/// On Start: resolves the destination via `NSSavePanel` (single/sequence) or
/// `NSOpenPanel`-dir (batch), calls the matching `exportX(...)` (fire-and-forget
/// — sets `.running` and returns), then dismisses. Progress surfaces in the
/// `ExportProgressSurface` banner (M6-G.7/G.8); the sheet does NOT hold export
/// state (it lives on `AppModel.exportManager` — G9).
struct ExportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let source: ExportSource

    /// Seed is local state (not an `ExportManager` config field — the entry
    /// points take it as a parameter); default 1 (deterministic, reproducible).
    @State private var seed: Int = 1

    /// Custom-resolution dims, used only when the resolution tier is `.custom`.
    /// Seeded from `exportManager.resolution` on appear; synced back via the
    /// tier binding + `.onChange`. (`ExportSettings.Resolution` is NOT
    /// CaseIterable — `.custom` carries dims — so the Picker uses a flat tier
    /// enum and this pair holds the dims.)
    @State private var customWidth = 1920
    @State private var customHeight = 1080

    var body: some View {
        @Bindable var model = model    // two-way bindings to model.exportManager
        @Bindable var em = model.exportManager   // $em.codec etc. (reference type)
        return VStack(spacing: 0) {
            Form {
                Section("Source") {
                    LabeledContent("Source") {
                        Text(sourceSummary)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }

                Section("Video") {
                    Picker("Resolution", selection: resolutionTier) {
                        ForEach(SheetResolutionTier.allCases) { Text($0.label).tag($0) }
                    }
                    .onChange(of: customWidth) { _, _ in syncCustomResolution() }
                    .onChange(of: customHeight) { _, _ in syncCustomResolution() }
                    if resolutionTier.wrappedValue == .custom {
                        Stepper("Width \(customWidth)", value: $customWidth, in: 16...7680, step: 16)
                            .help("Custom export width in pixels.")
                        Stepper("Height \(customHeight)", value: $customHeight, in: 16...4320, step: 16)
                            .help("Custom export height in pixels.")
                    }

                    Picker("Quality", selection: $em.qualityChoice) {
                        ForEach(ExportQualityChoice.allCases, id: \.self) {
                            Text($0.sheetLabel).tag($0)
                        }
                    }
                    .help(qualityHelp)

                    Picker("Codec", selection: $em.codec) {
                        Text("H.264").tag(ExportSettings.Codec.h264)
                        Text("HEVC").tag(ExportSettings.Codec.hevc)
                    }
                    Picker("Container", selection: $em.container) {
                        Text("MP4").tag(ExportSettings.Container.mp4)
                        Text("MOV").tag(ExportSettings.Container.mov)
                    }
                    Stepper("FPS \(em.fps)", value: $em.fps, in: 1...120)
                        .help("Output framerate (also drives frames-per-segment with loop duration).")
                    Picker("Backend", selection: $em.backendChoice) {
                        ForEach(BackendChoice.allCases, id: \.self) {
                            Text($0.sheetLabel).tag($0)
                        }
                    }
                    .help("Auto probes Metal and falls back to CPU. CPU is the slower reference oracle; the image is identical either way.")
                }

                Section("Motion") {
                    Stepper("Loop duration \(String(format: "%.1f", em.loopDurationSeconds)) s",
                            value: $em.loopDurationSeconds, in: 0.1...120, step: 0.5)
                        .help("Loop length in seconds. Frames per segment = round(duration × FPS).")
                    Stepper(temporalLabel, value: $em.temporalSamples, in: 1...64)
                        .help("1 uses the genome default (≈1000 on real ES sheep, motion-blurred). Higher values are sharper but slower. Metal caps at 64.")
                    Stepper("Seed \(seed)", value: $seed, in: 0...1_000_000_000)
                        .help("Deterministic render seed. Same seed + genome + params = identical output.")
                }
            }
            .formStyle(.grouped)

            if let notice = metalNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 20).padding(.bottom, 6)
            }

            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button("Choose Destination & Export") {
                    Task { await startExport() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [])
                .disabled(!canStart)
            }
            .padding(16)
        }
        .frame(width: 500)
        .onAppear { syncResolutionFromManager() }
    }

    // MARK: - Derived

    /// Read-only source summary line.
    private var sourceSummary: String {
        switch source {
        case .single(_, let name):
            return "1 genome — \(name)"
        case .sequence(let flames, let name):
            let n = flames.count
            return "Collection \"\(name)\" (\(n) sheep)"
        case .batch(let items):
            let n = items.count
            return "\(n) selected genome\(n == 1 ? "" : "s")"
        }
    }

    private var temporalLabel: String {
        let ts = model.exportManager.temporalSamples
        return ts == 1 ? "Temporal samples (genome default)" : "Temporal samples \(ts)"
    }

    /// Metal-unavailable notice when the user explicitly picked Metal and it's
    /// not available (probed via the EmberweftUI wrapper — `MetalRenderer.isAvailable`
    /// is `@MainActor`; the sheet body is MainActor so this is safe).
    private var metalNotice: String? {
        guard model.exportManager.backendChoice == .metal,
              !MetalFrameRenderer.isMetalAvailable else { return nil }
        return "Metal is unavailable on this machine — the export will use the CPU backend."
    }

    private var qualityHelp: String {
        "Genome default is byte-identical to `emberweft animate`. Named tiers fix samples-per-pixel (oversample pinned 1)."
    }

    /// Start is disabled unless the manager can start AND the source has at
    /// least one renderable genome (NaN/degenerate excluded — spec §7).
    private var canStart: Bool {
        model.exportManager.canStart && source.hasRenderable
    }

    /// Default file/directory stem for the save panel.
    private var defaultStem: String {
        switch source {
        case .single(_, let name):    return name
        case .sequence(_, let name):  return name
        case .batch:                  return "export"
        }
    }

    /// Bridge the Picker's CaseIterable tier enum <-> `ExportSettings.Resolution`
    /// (NOT CaseIterable — `.custom` carries dims). The Picker needs a flat tag
    /// set; this binding maps the tier to a concrete resolution, seeding custom
    /// dims from the local `@State`.
    private var resolutionTier: Binding<SheetResolutionTier> {
        Binding(
            get: { SheetResolutionTier(model.exportManager.resolution) },
            set: { tier in
                switch tier {
                case .p720:  model.exportManager.resolution = .p720
                case .p1080: model.exportManager.resolution = .p1080
                case .p1440: model.exportManager.resolution = .p1440
                case .p4k:   model.exportManager.resolution = .p4k
                case .custom:
                    model.exportManager.resolution = .custom(width: customWidth, height: customHeight)
                }
            }
        )
    }

    /// Seed the local custom W/H from the manager's current resolution on appear
    /// (so opening the sheet on a `.custom` resolution shows the right dims).
    private func syncResolutionFromManager() {
        if case .custom(let w, let h) = model.exportManager.resolution {
            customWidth = w
            customHeight = h
        }
    }

    /// Push custom-dim stepper changes back to the manager (the tier binding's
    /// setter only fires on tier CHANGE, not on dim change while already custom).
    private func syncCustomResolution() {
        guard resolutionTier.wrappedValue == .custom else { return }
        model.exportManager.resolution = .custom(width: customWidth, height: customHeight)
    }

    /// Resolve the destination via the file panel, then kick off the export
    /// (fire-and-forget) and dismiss. Single/sequence use `NSSavePanel`; batch
    /// uses `NSOpenPanel`-dir.
    private func startExport() async {
        let container = model.exportManager.container
        let url: URL?
        switch source {
        case .single, .sequence:
            let ext = container == .mp4 ? "mp4" : "mov"
            url = chooseSaveURL(defaultName: "\(defaultStem).\(ext)")
        case .batch:
            url = chooseDirectory()
        }
        guard let resolved = url else { return }

        let s = UInt64(max(0, seed))
        switch source {
        case .single(let flame, let name):
            await model.exportManager.exportSingle(flame: flame, displayName: name,
                                                   out: resolved, seed: s)
        case .sequence(let flames, let name):
            await model.exportManager.exportSequence(flames: flames, displayName: name,
                                                    out: resolved, seed: s)
        case .batch(let items):
            await model.exportManager.exportBatch(items: items, baseDir: resolved, seed: s)
        }
        dismiss()
    }
}

// MARK: - Resolution tier (Picker tags)

/// Flat, CaseIterable tier enum for the resolution Picker. The real
/// `ExportSettings.Resolution` is NOT CaseIterable (`.custom` carries associated
/// dims), so the Picker iterates these tiers and the `resolutionTier` binding
/// maps each to a concrete resolution.
private enum SheetResolutionTier: String, CaseIterable, Identifiable {
    case p720, p1080, p1440, p4k, custom

    var id: String { rawValue }
    var label: String {
        switch self {
        case .p720:    "720p"
        case .p1080:   "1080p"
        case .p1440:   "1440p"
        case .p4k:     "4K"
        case .custom:  "Custom"
        }
    }

    init(_ r: ExportSettings.Resolution) {
        switch r {
        case .p720:    self = .p720
        case .p1080:   self = .p1080
        case .p1440:   self = .p1440
        case .p4k:     self = .p4k
        case .custom:  self = .custom
        }
    }
}

// MARK: - Picker label helpers

private extension ExportQualityChoice {
    var sheetLabel: String {
        switch self {
        case .genomeDefault: "Genome default"
        case .low:           "Low"
        case .medium:        "Medium"
        case .high:          "High"
        }
    }
}

private extension BackendChoice {
    var sheetLabel: String {
        switch self {
        case .auto:  "Auto"
        case .cpu:   "CPU"
        case .metal: "Metal"
        }
    }
}
