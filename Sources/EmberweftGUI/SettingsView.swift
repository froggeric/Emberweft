import SwiftUI
import AppKit
import EmberweftUI
import FlameFlock

/// The macOS Settings (⌘,) window. Two distinct quality settings, by purpose:
///   - **Preview quality** (`previewPreset`) — the *realtime* preview in the
///     playback window (`previewParams`): small, fast, tuned for fluid FPS.
///   - **Export quality** (`exportQuality`) — the DEFAULT for the one-shot
///     export sheet: the sheet seeds its Quality picker from this on open, and
///     an in-sheet change affects that run only (Settings is the source of
///     truth). The Flock archive tabs keep their own quality setting.
/// These are intentionally separate so a fast, low-cost preview never forces a
/// slow export, and vice versa. The playback window's quality popover edits the
/// same `previewPreset` (and exposes per-parameter Custom tuning).
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    /// Per-shard `(count, bytes)` for the Flock size readout, name-ordered from
    /// the catalog (rule #2 — key-ordered SQL read). Refreshed on appear and
    /// after a Rebuild.
    @State private var shardSizes: [(name: String, count: Int, bytes: Int)] = []
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

            Section("Export") {
                Picker("Export quality", selection: exportQualityBinding) {
                    ForEach(ExportQualityChoice.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                .help("The default quality for the one-shot export sheet — each sheet opens at this tier and an in-sheet change affects that run only. Does NOT affect the realtime preview (its own Preview quality above) or the Flock archive (its own quality setting).")
            }

            Section("Thumbnails") {
                Picker("Thumbnail backend", selection: $model.prefs.thumbnailBackend) {
                    ForEach(AppPreferences.Backend.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                }
                .help("Metal renders thumbnails off the main thread (fast, and it does not block the UI); CPU is the slower reference renderer, also off the main thread.")
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

                // Default shard for the Flock Generate/Stitch tabs (wired):
                // persisted as `AppPreferences.flockDefaultShard`; the tabs
                // resolve their initial shard from it on appear. The Standard
                // presets are offered here; any other catalog shard can still be
                // picked inside each tab.
                Picker("Default shard", selection: defaultShardBinding) {
                    Section("Standard") {
                        ForEach(ShardPresets.sensible.filter { !ShardPresets.isVertical($0) }, id: \.name) {
                            Text(shardMenuLabel($0)).tag($0.name)
                        }
                    }
                    Section("Vertical") {
                        ForEach(ShardPresets.sensible.filter { ShardPresets.isVertical($0) }, id: \.name) {
                            Text(shardMenuLabel($0)).tag($0.name)
                        }
                    }
                }
                .help("The shard the Flock Generate and Stitch tabs start from (resolution, frame rate, and canonical 15 s / 12 s pace). Unknown shard names fall back to the 1080p default.")

                // Size readout: shard/artifact counts from the latest Browse
                // snapshot + catalog-recorded bytes (total, then per shard).
                flockSizeReadout

                Button("Rebuild catalog") {
                    Task { @MainActor in
                        rebuildError = nil
                        let root = model.flockRoot
                        do {
                            try await FlockCatalog.rebuild(from: root)
                            await model.flockModel.refreshBrowse()
                            shardSizes = await loadShardSizes()
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
            shardSizes = await loadShardSizes()
        }
    }

    /// Two-way binding for the default-shard picker: nil (unset) displays as the
    /// canonical default's name, so the control always shows a selection;
    /// picking stores the shard NAME.
    private var defaultShardBinding: Binding<String> {
        Binding(
            get: { model.prefs.flockDefaultShard ?? ShardPresets.canonicalDefault.name },
            set: { model.prefs.flockDefaultShard = $0 })
    }

    private func shardMenuLabel(_ s: ShardSpec) -> String {
        "\(s.width)×\(s.height) · \(s.fps) fps · \(Int(s.loopSeconds)) s/\(Int(s.transSeconds)) s"
    }

    /// Per-shard `(count, bytes)` from the long-lived catalog — name-ordered
    /// (`listShards()` is `ORDER BY name`) then one `shardStats(_:)` per shard
    /// (deterministic, rule #2; shard counts are tiny, so N+1 reads are fine).
    /// Bytes are the CATALOG-RECORDED artifact file sizes, not a disk scan.
    private func loadShardSizes() async -> [(name: String, count: Int, bytes: Int)] {
        guard let catalog = model.flockCatalog else { return [] }
        let shards = (try? await catalog.listShards()) ?? []
        var out: [(name: String, count: Int, bytes: Int)] = []
        for s in shards {
            let st = (try? await catalog.shardStats(s.name)) ?? (count: 0, bytes: 0)
            out.append((s.name, st.count, st.bytes))
        }
        return out
    }

    /// Browse snapshot readout for the Flock section: shard/artifact counts
    /// from `FlockModel.browseState` PLUS the catalog-recorded bytes (grand
    /// total, then per shard), or a Rebuild error / loading / empty / failed
    /// line.
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
                VStack(alignment: .leading, spacing: 2) {
                    // Integer sum over an ordered array (rule #2).
                    let totalBytes = shardSizes.reduce(0) { $0 + $1.bytes }
                    Text("\(snap.shardCount) shard\(snap.shardCount == 1 ? "" : "s") · "
                         + "\(snap.artifactCount) artifact\(snap.artifactCount == 1 ? "" : "s") · "
                         + Self.bytesLabel(totalBytes))
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(shardSizes, id: \.name) { row in
                        Text("\(row.name) — \(row.count) artifact\(row.count == 1 ? "" : "s") · \(Self.bytesLabel(row.bytes))")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    /// Human-readable byte count (system formatter, file counts = 1024-based —
    /// the same convention Browse's per-artifact readout uses).
    private static func bytesLabel(_ n: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }

    /// Bridge the export-quality Picker to the prefs-backed raw string (an
    /// unknown stored value resolves to the genome-default choice on read).
    private var exportQualityBinding: Binding<ExportQualityChoice> {
        Binding(
            get: { model.prefs.exportQualityChoice },
            set: { model.prefs.exportQuality = $0.rawValue }   // persisted by the Form's `.onChange(of: model.prefs)` save
        )
    }
}
