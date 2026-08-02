import SwiftUI
import EmberweftUI

// MARK: - FPS readout

/// Compact live-framerate readout for the transport bar: `59 fps` (tinted by the
/// target-relative band) while playing, an em dash `—` while paused/loading. The
/// band is anchored to the user's TARGET fps (Weber-Fechner: sensitivity is
/// relative), with one absolute red floor at 24 fps — see `PreviewFPSBand`. Color
/// is the preattentive shortcut; the digits stay authoritative (color-blind safe).
/// Re-evaluates only when the VM publishes `measuredFPS` (~2 Hz, not per frame).
struct FPSReadout: View {
    let measuredFPS: Double
    let targetFPS: Double
    let isPlaying: Bool

    private var band: PreviewFPSBand {
        .band(measuredFPS: measuredFPS, targetFPS: targetFPS, isPlaying: isPlaying)
    }

    private var numberText: String {
        guard band != .idle, measuredFPS.isFinite, measuredFPS > 0 else { return "—" }
        return "\(Int(measuredFPS.rounded()))"
    }

    private var tint: Color {
        switch band {
        case .idle:  return .secondary
        case .green: return .green
        case .amber: return .orange
        case .red:   return .red
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(numberText)
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(tint)
            Text("fps")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .opacity(0.8)
        }
        .frame(minWidth: 52, alignment: .trailing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview framerate")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Live; reflects the current preview quality.")
    }

    private var accessibilityValue: String {
        guard band != .idle, measuredFPS.isFinite, measuredFPS > 0 else {
            return isPlaying ? "Measuring" : "Paused"
        }
        return "\(Int(measuredFPS.rounded())) frames per second, \(band.accessibilityVerdict)"
    }
}

// MARK: - Preview-quality popover

/// Preview-quality popover bound directly to `AppPreferences`: three named presets
/// (primary, one-click snap) + advanced steppers/menus (secondary, deferred). The
/// popover is the single tuning surface; the bar carries only a compact FPS readout
/// + a trigger, so the transport stays scannable (Miller's 7±2). `Custom` is a
/// DERIVED status (shown in the Active line + the trigger's dot), never a clickable
/// segment — editing any advanced value forks to Custom from the current preset.
struct PreviewQualityPopover: View {

    @Binding var prefs: AppPreferences

    private let namedPresets: [AppPreferences.PreviewPreset] = [.draft, .balanced, .quality]

    private var metalAvailable: Bool { MetalFrameRenderer.isMetalAvailable }

    // Effective (displayed) values: the named preset's, or the raw fields when custom.
    private var effResolution: AppPreferences.PreviewResolution {
        prefs.previewPreset == .custom
            ? .nearest(width: prefs.previewWidth, height: prefs.previewHeight)
            : prefs.previewPreset.resolution
    }
    private var effSPP: Int {
        prefs.previewPreset == .custom ? prefs.previewSamplesPerPixel : prefs.previewPreset.samplesPerPixel
    }
    private var effOversample: Int {
        prefs.previewPreset == .custom ? prefs.previewOversample : prefs.previewPreset.oversample
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            statusLine
            presetSegmented
            Divider()
            advancedSection
            Divider()
            helpFooter
            HStack { Spacer(); resetButton }
        }
        .padding(16)
        .frame(width: 320)
    }

    // MARK: Sections

    private var statusLine: some View {
        HStack(spacing: 6) {
            Text("Active")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(prefs.previewPreset.label)
                .font(.callout.weight(.semibold))
            Text(prefs.previewPreset.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
    }

    private var presetSegmented: some View {
        // Selection = prefs.previewPreset directly: when `.custom`, no segment is
        // tagged `.custom`, so none highlights — the visible "you're off-preset" cue.
        Picker("Preset", selection: Binding(
            get: { prefs.previewPreset },
            set: { prefs.previewPreset = $0 })) {
            ForEach(namedPresets, id: \.self) { p in Text(p.label).tag(p) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("Preview preset")
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Advanced")
                .font(.caption)
                .foregroundStyle(.secondary)

            LabeledRow("Resolution") {
                Picker("Resolution", selection: Binding(
                    get: { effResolution },
                    set: { applyResolution($0) })) {
                    ForEach(AppPreferences.PreviewResolution.allCases, id: \.self) { r in
                        Text(r.label).tag(r)
                    }
                }
                .pickerStyle(.menu).labelsHidden().frame(width: 120)
                .help("Internal render size, scaled to fill the window. Larger is sharper up to your display, but lowers FPS, since cost grows with pixel count. Above the window size adds no visible detail.")
            }

            LabeledRow("Samples / pixel") {
                Stepper(value: Binding(get: { effSPP }, set: { applySPP($0) }), in: 1...64) {
                    Text("\(effSPP)").monospacedDigit()
                }
                .help("Chaos-game iterations per pixel: the main quality-versus-cost knob. Higher reduces noise and reveals finer detail at roughly proportional render cost; low values look grainy.")
            }

            LabeledRow("Oversample") {
                Stepper(value: Binding(get: { effOversample }, set: { applyOversample($0) }), in: 1...4) {
                    Text("\(effOversample)×").monospacedDigit()
                }
                .help("Sub-pixel samples averaged per pixel. Smooths aliased edges, but cost scales with the square (2x is about 4x slower). Use 1 for preview, 2 for high quality.")
            }

            Divider()

            LabeledRow("Target frame rate") {
                Picker("Target frame rate", selection: Binding(
                    get: { prefs.targetFPS },
                    set: { prefs.targetFPS = $0 })) {
                    ForEach([24, 30, 60, 90, 120], id: \.self) { fps in
                        Text("\(fps)").tag(fps)
                    }
                }
                .pickerStyle(.menu).labelsHidden().frame(width: 120)
                .help("The framerate the preview paces to and the FPS readout is measured against. It does not change image quality; a lower target lets the loop idle between frames, a higher one is smoother if the GPU can keep up.")
            }

            LabeledRow("Backend") {
                if metalAvailable {
                    Picker("Backend", selection: Binding(
                        get: { prefs.backend },
                        set: { prefs.backend = $0 })) {
                        Text("Metal").tag(AppPreferences.Backend.metal)
                        Text("CPU").tag(AppPreferences.Backend.cpu)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 120)
                    .help("Metal renders on the GPU (fast, recommended); CPU is the slower reference oracle. The image is identical either way.")
                } else {
                    Text("CPU (Metal unavailable)").foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Actionable guidance tying the parameters to the live FPS readout, so users
    /// learn the quality/performance tradeoff by experimenting (no manual needed).
    private var helpFooter: some View {
        Text("Watch the bar's FPS readout as you adjust: green is fluid for your target, amber is playable but juddery, red means the GPU can't keep up. Back off samples/pixel or resolution to recover framerate.")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var resetButton: some View {
        Button { prefs.previewPreset = .draft } label: {
            Label("Reset to Default", systemImage: "arrow.counterclockwise")
        }
        .buttonStyle(.borderless)
        .accessibilityHint("Restore the Draft preview preset")
    }

    // MARK: Fork-to-custom on any advanced edit

    /// Copy the active named preset's values into the raw fields and switch to
    /// `.custom`, so the edit starts from the preset the user was just on. No-op
    /// when already custom. Target FPS / backend are global and never fork.
    private func forkToCustomIfNeeded() {
        guard prefs.previewPreset != .custom else { return }
        let p = prefs.previewPreset
        prefs.previewWidth = p.resolution.width
        prefs.previewHeight = p.resolution.height
        prefs.previewSamplesPerPixel = p.samplesPerPixel
        prefs.previewOversample = p.oversample
        prefs.previewPreset = .custom
    }

    private func applyResolution(_ r: AppPreferences.PreviewResolution) {
        forkToCustomIfNeeded()
        prefs.previewWidth = r.width
        prefs.previewHeight = r.height
    }
    private func applySPP(_ v: Int) {
        forkToCustomIfNeeded()
        prefs.previewSamplesPerPixel = v
    }
    private func applyOversample(_ v: Int) {
        forkToCustomIfNeeded()
        prefs.previewOversample = v
    }
}

private struct LabeledRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        HStack {
            Text(title).font(.callout)
            Spacer()
            content
        }
    }
}

// MARK: - Cluster (dropped into both transport bars)

/// The single control placed in each transport bar: FPS readout + the
/// preview-quality trigger. Insert AFTER the existing numeric readout and BEFORE
/// the `Divider`, in both windows — same slot, same behavior (Gestalt grouping
/// with telemetry). The trigger carries a small yellow dot when the preset is
/// Custom (preattentive "you're off-preset" flag, mirroring `SentimentBadge`).
struct PreviewPerfCluster: View {
    let measuredFPS: Double
    let targetFPS: Double
    let isPlaying: Bool
    @Binding var prefs: AppPreferences
    @Binding var showPopover: Bool

    var body: some View {
        HStack(spacing: 6) {
            FPSReadout(measuredFPS: measuredFPS,
                       targetFPS: targetFPS,
                       isPlaying: isPlaying)
            trigger
        }
    }

    private var trigger: some View {
        Button { showPopover.toggle() } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "slider.horizontal.3")
                if prefs.previewPreset == .custom {
                    Circle().fill(.yellow).frame(width: 6, height: 6).offset(x: 6, y: -4)
                }
            }
            .frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .popover(isPresented: $showPopover) {
            PreviewQualityPopover(prefs: $prefs)
        }
        .accessibilityLabel("Preview quality")
        .accessibilityValue(prefs.previewPreset.label)
        .accessibilityHint("Choose a preset or customize preview parameters")
    }
}
