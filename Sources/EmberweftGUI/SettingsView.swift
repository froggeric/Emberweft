import SwiftUI
import AppKit
import EmberweftUI
import FlameFlock

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

    /// Staged (T18): default shard resolution for Flock generation driven from
    /// this panel. Local state — no consumer yet (generate/stitch are launched
    /// from FlockView); it will persist as an `AppPreferences` field when the
    /// generate-from-Settings path lands. Kept local to avoid schema bloat now.
    @State private var defaultShardResolution: AppPreferences.PreviewResolution = .p1080
    /// Last Rebuild error (nil unless `FlockCatalog.rebuild(from:)` threw).
    @State private var rebuildError: String?

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Playback (realtime preview)") {
                Picker("Preview quality", selection: $model.prefs.previewPreset) {
                    ForEach([AppPreferences.PreviewPreset.draft, .balanced, .quality], id: \.self) { Text($0.label).tag($0) }
                }
                .help("Realtime preview quality. Higher presets sharpen the image and reduce noise by raising the resolution and samples-per-pixel, at the cost of framerate. For per-parameter tuning, use a playback window's quality popover — it can switch to a Custom preset, shown read-only below.")
                if model.prefs.previewPreset == .custom {
                    let r = AppPreferences.PreviewResolution.nearest(
                        width: model.prefs.previewWidth, height: model.prefs.previewHeight)
                    Text("Custom — \(r.label) · \(model.prefs.previewSamplesPerPixel) spp · \(model.prefs.previewOversample)× (set via the playback popover)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

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

            Section("Flock archive") {
                // Archive folder (flockDir). "Choose…" opens a folder picker
                // (NSOpenPanel); the path field is also hand-editable. Empty ⇒
                // the default <app-support>/Emberweft/Flock. Persisted via the
                // Form's `.onChange(of: model.prefs)` save (same path as the
                // other pickers).
                HStack {
                    TextField(
                        "Archive folder",
                        text: Binding(
                            get: { model.prefs.flockDir?.path ?? "" },
                            set: { newValue in
                                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                                model.prefs.flockDir = trimmed.isEmpty
                                    ? nil
                                    : URL(fileURLWithPath: trimmed)
                            }))
                        .font(.caption)
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        panel.prompt = "Choose"
                        if panel.runModal() == .OK, let url = panel.url {
                            model.prefs.flockDir = url
                        }
                    }
                }
                .help("Where the Flock archive lives (shard .mov files + flock.sqlite). Leave empty for the default (Application Support/Emberweft/Flock). A change takes effect for the catalog on the next launch; Rebuild repopulates the chosen folder immediately.")

                // Default shard resolution for new shards (staged — see @State).
                Picker("Default shard", selection: $defaultShardResolution) {
                    ForEach(
                        [AppPreferences.PreviewResolution.p720, .p1080, .p4k], id: \.self
                    ) { Text($0.label).tag($0) }
                }
                .help("Resolution tier for shards generated into the archive (staged — not yet wired to generation).")

                // Size readout from the latest Browse snapshot (FlockSnapshot
                // carries shard/artifact counts — the catalog's content view).
                flockSizeReadout

                Button("Rebuild catalog") {
                    Task { @MainActor in
                        rebuildError = nil
                        let root = model.flockRoot
                        do {
                            try await FlockCatalog.rebuild(from: root)
                            await model.flockModel.refreshBrowse()
                        } catch {
                            rebuildError = String(describing: error)
                        }
                    }
                }
                .help("Re-scan the archive folder and rebuild flock.sqlite (the on-disk catalog Browse reads). Use after manually copying or moving .mov files into the folder, or if the catalog is corrupt.")
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 460)
        .onChange(of: model.prefs) { _, _ in
            try? model.prefs.save()
        }
        .task {
            // Seed the size readout from the long-lived catalog (T18).
            await model.flockModel.refreshBrowse()
        }
    }

    /// Browse snapshot readout for the Flock section. Shows shard/artifact
    /// counts from `FlockModel.browseState`, or a Rebuild error / loading /
    /// empty / failed line. `FlockSnapshot` carries counts (not bytes), so the
    /// readout reflects catalog content rather than on-disk size.
    @ViewBuilder private var flockSizeReadout: some View {
        if let err = rebuildError {
            Text("Rebuild failed: \(err)")
                .font(.caption).foregroundStyle(.red).lineLimit(2)
        } else {
            switch model.flockModel.browseState {
            case .loading:
                Text("Loading catalog…").font(.caption).foregroundStyle(.secondary)
            case .empty:
                Text("Archive empty — 0 shards · 0 artifacts.")
                    .font(.caption).foregroundStyle(.secondary)
            case .failed(let msg):
                Text("Catalog error: \(msg)").font(.caption).foregroundStyle(.red).lineLimit(2)
            case .loaded(let snap):
                Text("\(snap.shardCount) shards · \(snap.artifactCount) artifacts")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
