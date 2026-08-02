import SwiftUI
import EmberweftUI

/// The macOS Settings (⌘,) window. Two distinct quality settings, by purpose:
///   - **Preview quality** (`previewPreset`) — the *realtime* preview in the
///     playback window (`previewParams`): small, fast, tuned for fluid FPS.
///   - **Export quality** (`qualityPreset`) — *maximum* quality for exported /
///     full-quality renders (`renderParams`). The export feature itself is M6
///     (not yet wired); the setting is staged now so it's ready when it lands.
/// These are intentionally separate so a fast, low-cost preview never forces a
/// slow export, and vice versa. The playback window's quality popover edits the
/// same `previewPreset` (and exposes per-parameter Custom tuning).
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Playback (realtime preview)") {
                Picker("Preview quality", selection: $model.prefs.previewPreset) {
                    ForEach(AppPreferences.PreviewPreset.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .help("Realtime preview quality. Higher presets sharpen the image and reduce noise by raising the resolution and samples-per-pixel, at the cost of framerate. Draft/Balanced/Quality are fixed; Custom uses individually-tuned values (adjust in a playback window's quality popover).")

                Picker("Backend", selection: $model.prefs.backend) {
                    ForEach(AppPreferences.Backend.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                }
                .help("Metal renders on the GPU (fast, recommended); CPU is the slower reference oracle. The image is identical either way.")

                Picker("Target FPS", selection: $model.prefs.targetFPS) {
                    Text("24").tag(24); Text("30").tag(30); Text("60").tag(60)
                    Text("90").tag(90); Text("120").tag(120)
                }
                .help("The framerate the realtime preview paces to and the FPS readout is measured against.")
            }

            Section("Export (maximum quality)") {
                Picker("Export quality", selection: $model.prefs.qualityPreset) {
                    ForEach(AppPreferences.QualityPreset.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .help("Quality of exported / full-quality renders (the export feature is coming). This does NOT affect the realtime preview, which has its own Preview quality setting above.")
            }

            Section("Thumbnails") {
                Picker("Thumbnail backend", selection: $model.prefs.thumbnailBackend) {
                    ForEach(AppPreferences.Backend.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                }
                .help("CPU renders thumbnails off the main thread (no UI freeze). Metal is faster but blocks the UI per thumbnail.")
                Stepper("Thumbnail samples: \(model.prefs.thumbnailSPP)",
                        value: $model.prefs.thumbnailSPP, in: 1...64)
                .help("Chaos-game iterations per pixel for grid thumbnails. Higher gives cleaner thumbnails but takes longer to fill the grid.")
            }

            Section("Library folders") {
                let dirs = model.prefs.directorySources.sorted(by: { $0.path < $1.path })
                if dirs.isEmpty {
                    Text("No folders added (curated set only). Use the sidebar to open a folder.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(dirs, id: \.self) { dir in
                        Text(dir.path).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 460)
        .onChange(of: model.prefs) { _, _ in
            try? model.prefs.save()
        }
    }
}
