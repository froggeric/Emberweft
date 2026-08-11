import SwiftUI
import EmberweftUI
import FlameKit
import FlameExport

/// What the sheet exports (spec §4.6). Passed in by the source window at
/// `.sheet` presentation time; the sheet reads it (no mutation) and routes to
/// the matching `ExportManager` entry point on Start. Single/sequence supply
/// their flame(s) up front; batch supplies pre-loaded `(flame, name)` pairs.
enum ExportSource {
    /// `fileURL` (M6.1 P8): threads the on-disk source location so the VM can
    /// build resumable `[ExportCheckpoint.Source]`s (file-backed ⇒ SHA-256-gated
    /// resume). Nil ⇒ the sheet falls back to `serializedText`.
    case single(flame: Flame, name: String, fileURL: URL?)
    /// `fileURLs` (M6.1 P8): one per flame, position-aligned. Nil (or a nil
    /// slot) ⇒ the sheet serializes that flame via `Flam3Serializer` (the D6
    /// text fallback — resumable, just weaker than URL+hash).
    case sequence(flames: [Flame], name: String, fileURLs: [URL]?)
    case batch(items: [(flame: Flame, name: String)])

    /// True iff there is at least one renderable genome in the source.
    var hasRenderable: Bool {
        switch self {
        case .single(let f, _, _):          return f.isRenderable
        case .sequence(let fs, _, _):       return fs.contains { $0.isRenderable }
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
                    .onChange(of: em.qualityChoice) { _, choice in
                        // v0.5.5: picking a quality tier auto-sets temporal-samples
                        // to its data-derived best value (Draft 1 / Standard 4 / High
                        // 16 / Genome → 1 = genome default). The user can override the
                        // stepper after.
                        em.temporalSamples = choice.recommendedTemporalSamples
                    }

                    Picker("Codec", selection: $em.codec) {
                        Text("ProRes 422 HQ").tag(ExportSettings.Codec.proRes422HQ)
                        Text("H.264").tag(ExportSettings.Codec.h264)
                        Text("HEVC").tag(ExportSettings.Codec.hevc)
                    }
                    .onChange(of: em.codec) { _, newCodec in
                        // ProRes requires .mov; auto-switch + lock when selected.
                        // H.264/HEVC allow either .mp4 or .mov (user's choice).
                        if newCodec.requiresMOVContainer { em.container = .mov }
                    }
                    Picker("Container", selection: $em.container) {
                        Text("MP4").tag(ExportSettings.Container.mp4)
                        Text("MOV").tag(ExportSettings.Container.mov)
                    }
                    .disabled(em.codec.requiresMOVContainer)
                    .help(em.codec.requiresMOVContainer
                          ? "Locked to MOV — ProRes 422 HQ requires a .mov container."
                          : "Output container.")
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
                    Stepper("Transition duration \(String(format: "%.1f", em.transitionDurationSeconds)) s",
                            value: $em.transitionDurationSeconds, in: 0.1...120, step: 0.5)
                        .help("Transition (edge) length in seconds. Shorter than loop keeps edges brief. Transition frames = round(duration × FPS).")
                    Stepper("Loop repeat \(em.loopRepeatCount)×",
                            value: $em.loopRepeatCount, in: 1...10)
                        .disabled(loopRepeatDisabled)
                        .help("Render each loop once, output N×. Seamless (a loop is R(360°)=R(0°)). 2× halves loop render cost (15 s render + 2× = 30 s perceived). Transitions never repeat. Disabled above the safe cache size.")
                    Stepper(temporalLabel, value: $em.temporalSamples, in: 1...64)
                        .help("1 uses the genome default (≈1000 on real ES sheep, motion-blurred). Higher values are sharper but slower. Metal caps at 64.")
                    Toggle("Temporal smoothing", isOn: temporalSmoothingBinding)
                        .disabled(em.qualityChoice == .genomeDefault)
                        .help(smoothingHelp)
                    if em.qualityChoice != .genomeDefault {
                        Text("Resolved \(em.qualityChoice.smoothingLabel)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Stepper("Seed \(seed)", value: $seed, in: 0...1_000_000_000)
                        .help("Deterministic render seed. Same seed + genome + params = identical output.")
                    Stepper("Checkpoint every \(em.checkpointIntervalFrames) frames",
                            value: $em.checkpointIntervalFrames, in: 5...300)
                        .help("Pause/resume granularity. Smaller = finer checkpoints + less re-render on resume, at the cost of more encoder sessions.")
                }
            }
            .formStyle(.grouped)

            if let notice = metalNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 20).padding(.bottom, 6)
            }
            if let notice = codecNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20).padding(.bottom, 6)
            }
            if loopRepeatCacheExceedsThreshold {
                Text("Loop repeat is disabled at this resolution/length: caching one loop (~\(loopRepeatCacheMB) MB) would exceed the safe RAM budget (~\(loopRepeatThresholdMB) MB). Lower the resolution, shorten the loop, or keep repeat at 1×.")
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
        .onAppear {
            syncResolutionFromManager()
            clampLoopRepeatIfNeeded()
        }
        .onChange(of: em.resolution) { _, _ in clampLoopRepeatIfNeeded() }
        .onChange(of: em.loopDurationSeconds) { _, _ in clampLoopRepeatIfNeeded() }
        .onChange(of: em.fps) { _, _ in clampLoopRepeatIfNeeded() }
    }

    /// If the per-loop cache now exceeds the safe RAM budget, force repeat=1
    /// (the coordinator would refuse repeat>1 anyway; this keeps the sheet's
    /// value honest so Start doesn't reach a guaranteed-refusal export).
    private func clampLoopRepeatIfNeeded() {
        if loopRepeatCacheExceedsThreshold && model.exportManager.loopRepeatCount > 1 {
            model.exportManager.loopRepeatCount = 1
        }
    }

    // MARK: - Derived

    /// Read-only source summary line.
    private var sourceSummary: String {
        switch source {
        case .single(_, let name, _):
            return "1 genome — \(name)"
        case .sequence(let flames, let name, _):
            let n = flames.count
            return "Collection \"\(name)\" (\(n) sheep)"
        case .batch(let items):
            let n = items.count
            return "\(n) selected genome\(n == 1 ? "" : "s")"
        }
    }

    private var temporalLabel: String {
        let ts = model.exportManager.temporalSamples
        if ts == 1 {
            // v0.5.4: ts=1 is "genome default" ONLY for genome-default quality;
            // for named tiers it's literal single-pass (sharp, fastest — the
            // genome-default ts was wasteful at low spp for invisible motion blur).
            return model.exportManager.qualityChoice == .genomeDefault
                ? "Temporal samples (genome default)"
                : "Temporal samples (single-pass)"
        }
        return "Temporal samples \(ts)"
    }

    /// M6.1 slice 2 / Task 10: bridges the `TemporalSmoothing` enum (`.auto`/
    /// `.off`) to the `Toggle`'s `Bool` — `.auto` ⇄ `.off`. The toggle is disabled
    /// at `.genomeDefault` (smoothing is a no-op there: α collapses to 1.0
    /// regardless of the toggle position).
    private var temporalSmoothingBinding: Binding<Bool> {
        Binding(
            get: { model.exportManager.temporalSmoothing == .auto },
            set: { isOn in model.exportManager.temporalSmoothing = isOn ? .auto : .off }
        )
    }

    /// Smoothing-toggle tooltip. Explains `.auto` (quality-derived α) vs `.off`
    /// (byte-identical unsmoothed) and why it's disabled at genome-default.
    private var smoothingHelp: String {
        if model.exportManager.qualityChoice == .genomeDefault {
            return "Disabled — genome-default quality already uses α = 1.0 (no smoothing)."
        }
        return "ON: blend each frame with the prior histogram (α ramps with quality) for smoother motion. OFF: α = 1.0, byte-identical to the unsmoothed path."
    }

    /// Estimated per-loop cache size for the loop-repeat memory guard
    /// (`framesPerSegment × W × H × 4` bytes), as whole megabytes. The cache is
    /// the same regardless of `loopRepeatCount` (it holds ONE loop's frames).
    private var loopRepeatCacheMB: Int {
        let em = model.exportManager
        let frames = max(1, Int(em.loopDurationSeconds * Double(em.fps)))
        let bytes = Int64(frames) * Int64(em.resolution.width) * Int64(em.resolution.height) * 4
        return Int(bytes / 1_000_000)
    }

    /// The safe cache threshold the coordinator enforces (~50% of physical RAM,
    /// floored 2 GB, ceiling ~12 GB). Mirrors `ExportCoordinator`'s guard so the
    /// sheet's disable/notice agrees with the actual refusal.
    private var loopRepeatThresholdMB: Int {
        let phys = Int64(ProcessInfo.processInfo.physicalMemory)
        let floor: Int64 = 2_000_000_000
        let ceiling: Int64 = 12_000_000_000
        return Int(min(max(phys / 2, floor), ceiling) / 1_000_000)
    }

    /// True when one loop's cache would exceed the safe threshold → the
    /// coordinator would refuse any repeat>1, so the stepper locks at 1.
    private var loopRepeatCacheExceedsThreshold: Bool {
        loopRepeatCacheMB > loopRepeatThresholdMB
    }

    /// The repeat stepper is disabled above the safe cache size (forced to 1).
    private var loopRepeatDisabled: Bool {
        loopRepeatCacheExceedsThreshold
    }

    /// Metal-unavailable notice when the user explicitly picked Metal and it's
    /// not available (probed via the EmberweftUI wrapper — `MetalRenderer.isAvailable`
    /// is `@MainActor`; the sheet body is MainActor so this is safe).
    private var metalNotice: String? {
        guard model.exportManager.backendChoice == .metal,
              !MetalFrameRenderer.isMetalAvailable else { return nil }
        return "Metal is unavailable on this machine — the export will use the CPU backend."
    }

    /// Codec notice. ProRes 422 HQ is the mastering default — it is a
    /// high-bitrate, visually-lossless codec muxed into `.mov` (large files,
    /// best quality). H.264/HEVC get no notice.
    private var codecNotice: String? {
        guard model.exportManager.codec.isProRes else { return nil }
        return "ProRes 422 HQ is a high-bitrate mastering codec (.mov, ~220 Mbps at 1080p25). Best quality; large files."
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
        case .single(_, let name, _):    return name
        case .sequence(_, let name, _):  return name
        case .batch:                     return "export"
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
        case .single(let flame, let name, let fileURL):
            // P8: ALWAYS thread a source so the VM routes to the pausable
            // `.runResumable` path (not the `.runJob` fallback). File-backed ⇒
            // SHA-256-gated resume (the D6-strong path). Construction is in the
            // tested `ExportSources` helper (flameIndex/serializedText logic).
            let sources = ExportSources.single(flame: flame, fileURL: fileURL, displayName: name)
            await model.exportManager.exportSingle(flame: flame, displayName: name,
                                                   out: resolved, seed: s, sources: sources)
        case .sequence(let flames, let name, let fileURLs):
            // P8: one source per flame via the tested `ExportSources` helper.
            // flameIndex is the within-source parse index (0), NOT the sequence
            // position — see ExportSources.sequence.
            let sources = ExportSources.sequence(flames: flames, fileURLs: fileURLs, displayName: name)
            await model.exportManager.exportSequence(flames: flames, displayName: name,
                                                    out: resolved, seed: s, sources: sources)
        case .batch(let items):
            // Batch is cancel-only this slice (no checkpoint ⇒ no sources).
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
