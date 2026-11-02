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
///
/// Organized as panes (the macOS Settings contract): a TabView inside the
/// Settings scene renders as the pane-switching toolbar with per-pane window
/// titles, replacing the old single scrolling Form that mixed five domains.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    /// Per-shard `(count, bytes)` for the Flock size readout, name-ordered from
    /// the catalog (rule #2 — key-ordered SQL read). Refreshed on appear and
    /// after a Rebuild.
    @State private var shardSizes: [(name: String, count: Int, bytes: Int)] = []
    /// Last Rebuild error (nil unless `FlockCatalog.rebuild(from:)` threw).
    @State private var rebuildError: String?
    /// Thumbnail disk-cache size for the Library pane's storage row.
    @State private var thumbCacheBytes: Int64 = 0

    var body: some View {
        TabView {
            playbackExportPane
                .tabItem { Label("Playback & Export", systemImage: "speedometer") }
            libraryPane
                .tabItem { Label("Library", systemImage: "square.grid.2x2") }
            flockPane
                .tabItem { Label("Flock", systemImage: "bird") }
        }
        .frame(width: 460)
        .onChange(of: model.prefs) { _, _ in
            try? model.prefs.save()
        }
        .task {
            // Seed the size readout from the long-lived catalog (T18).
            await model.flockModel.refreshBrowse()
            shardSizes = await loadShardSizes()
            thumbCacheBytes = await model.thumbnailService.diskCacheSize()
        }
    }

    // MARK: - Pane: Playback & Export

    private var playbackExportPane: some View {
        @Bindable var model = model
        return Form {
            Section("Playback (realtime preview)") {
                Picker("Preview quality", selection: previewPresetBinding) {
                    ForEach([AppPreferences.PreviewPreset.draft, .balanced, .quality], id: \.self) {
                        Text($0.label).tag($0)
                    }
                    // Custom is a DERIVED status (set only by the playback
                    // popover's advanced controls), never a pickable segment —
                    // but a pop-up with no matching tag renders BLANK, which
                    // reads as "no value set". List it, disabled.
                    Text("Custom (set in the playback window)")
                        .tag(AppPreferences.PreviewPreset.custom)
                        .disabled(true)
                }
                .help("Realtime preview quality. Higher presets sharpen the image and reduce noise by raising the resolution and samples-per-pixel, at the cost of framerate. For per-parameter tuning, use a playback window's quality popover — it can switch to a Custom preset, shown read-only below.")
                if model.prefs.previewPreset == .custom {
                    let r = AppPreferences.PreviewResolution.nearest(
                        width: model.prefs.previewWidth, height: model.prefs.previewHeight)
                    Text("Custom — \(r.label) · \(model.prefs.previewSamplesPerPixel) samples/pixel · \(model.prefs.previewOversample)× (set via the playback popover)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Picker("Backend", selection: $model.prefs.backend) {
                    ForEach(AppPreferences.Backend.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .help("Metal renders on the GPU (fast, recommended); CPU is slower. The image is identical either way.")

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
        }
        .formStyle(.grouped)
        .padding(20)
    }

    // MARK: - Pane: Library

    private var libraryPane: some View {
        @Bindable var model = model
        return Form {
            Section("Thumbnails") {
                Picker("Thumbnail backend", selection: $model.prefs.thumbnailBackend) {
                    ForEach(AppPreferences.Backend.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .help("Metal renders thumbnails off the main thread (fast, and it does not block the UI); CPU is slower, also off the main thread.")
                Stepper("Thumbnail samples: \(model.prefs.thumbnailSPP)",
                        value: $model.prefs.thumbnailSPP, in: 1...64)
                    .help("Samples per pixel for grid thumbnails. Higher gives cleaner thumbnails but takes longer to fill the grid.")
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

            Section("Thumbnail cache") {
                // Visibility + control (the storage-management gap): the disk
                // cache is derivable but bounded only at 1 GB and was invisible.
                HStack {
                    Text("Cache size")
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: thumbCacheBytes, countStyle: .file))
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                Text("Bounded at 1 GB (oldest thumbnails are pruned at launch). Thumbnails are re-rendered on demand.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Clear Thumbnail Cache") {
                    Task { @MainActor in
                        _ = await model.thumbnailService.clearDiskCache()
                        thumbCacheBytes = await model.thumbnailService.diskCacheSize()
                    }
                }
                .disabled(thumbCacheBytes == 0)
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }

    // MARK: - Pane: Flock

    private var flockPane: some View {
        @Bindable var model = model
        return Form {
            Section("Flock archive") {
                // Archive folder (flockDir). "Choose…" opens a folder picker
                // (NSOpenPanel); the path field is also hand-editable. Empty ⇒
                // the default <app-support>/Emberweft/Flock. Persisted via the
                // `.onChange(of: model.prefs)` save (same path as the pickers).
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
                .help("Where the Flock archive lives (shard .mov files + flock.sqlite). Leave empty for the default (Application Support/Emberweft/Flock).")
                // The relaunch caveat used to live only in a hover tooltip —
                // every OTHER setting in this window applies immediately, so
                // the deferred behavior must be visible where the edit happens.
                Text("Folder changes take effect the next time Emberweft opens; Rebuild repopulates the chosen folder immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // Inline validation (entering-data): the TextField accepts any
                // text, so a path that isn't an existing folder is called out
                // at the field instead of silently not working.
                if let badPath = invalidArchivePath {
                    Text("“\(badPath)” doesn't exist as a folder — check the path or use Choose…")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

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
                            rebuildError = FlockModel.friendlyRebuildFailure(error)
                        }
                    }
                }
                .help("Re-scan the archive folder and rebuild flock.sqlite (the on-disk catalog Browse reads). Use after manually copying or moving .mov files into the folder, or if the catalog is corrupt.")
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }

    /// Non-nil (carrying the offending path) when the stored archive folder
    /// exists in prefs but not on disk.
    private var invalidArchivePath: String? {
        guard let dir = model.prefs.flockDir else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            return dir.path
        }
        return nil
    }

    /// Preview-quality picker binding that mirrors the pref but refuses
    /// selection of `.custom` (Custom is derived — set only by the playback
    /// popover's forkToCustomIfNeeded; the row is disabled, this is the belt to
    /// its suspenders).
    private var previewPresetBinding: Binding<AppPreferences.PreviewPreset> {
        @Bindable var model = model
        return Binding(
            get: { model.prefs.previewPreset },
            set: { if $0 != .custom { model.prefs.previewPreset = $0 } })
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
            Text(err)
                .font(.caption).foregroundStyle(.red).lineLimit(2)
        } else {
            switch model.flockModel.browseState {
            case .loading:
                Text("Loading catalog…").font(.caption).foregroundStyle(.secondary)
            case .empty:
                Text("Archive empty — 0 shards · 0 artifacts.")
                    .font(.caption).foregroundStyle(.secondary)
            case .failed(let msg):
                Text(msg).font(.caption).foregroundStyle(.red).lineLimit(2)
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
            set: { model.prefs.exportQuality = $0.rawValue }   // persisted by the `.onChange(of: model.prefs)` save
        )
    }
}
