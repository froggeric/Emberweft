import SwiftUI
import AppKit
import EmberweftUI
import FlameKit
import FlameFlock
import FlameExport

/// The dedicated Flock archive area (M6.5 / D9, spec §13). A thin SwiftUI shell
/// over `FlockModel` (T15) — three tabs (Generate / Stitch / Browse), each bound
/// to the corresponding state machine. The FlameFlock coordinator actors live
/// BEHIND `FlockModel`'s factory seams (installed by `AppModel`); they are NOT
/// `@State` view-models, so dismissing this area mid-run cannot orphan a
/// GPU-running coordinator (the M4 §13.2 invariant — `FlockModel.cancelGenerate`
/// /`cancelStitch` keep them alive via strong-self until they acknowledge stop).
///
/// Build-verified (EmberweftGUI has no test target); confirmed manually.
struct FlockView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(FlockModel.self) private var flockModel
    @State private var tab: FlockTab = .generate

    var body: some View {
        // `@Environment` properties have no `$` projection; introduce a
        // `@Bindable` shadow so the backend picker can bind two-way.
        @Bindable var flock = flockModel
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Flock tab", selection: $tab) {
                    Text("Generate").tag(FlockTab.generate)
                    Text("Stitch").tag(FlockTab.stitch)
                    Text("Browse").tag(FlockTab.browse)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 300)
                Spacer(minLength: 0)
                Picker("Backend", selection: $flock.backendChoice) {
                    ForEach(BackendChoice.allCases, id: \.self) { b in
                        Text(b.rawValue.uppercased()).tag(b)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                .padding(.trailing, 8)
                .help("Render backend. Auto falls back to CPU if Metal is unavailable.")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)

            Divider()

            Group {
                switch tab {
                case .generate: GenerateTab()
                case .stitch:   StitchTab()
                case .browse:   BrowseTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Flock Archive")
        .navigationSubtitle("Render, assemble, and browse the local flock.")
    }
}

private enum FlockTab { case generate, stitch, browse }

/// The canonical default shard (1080p30, 15 s loops / 12 s edges, HEVC). Used as
/// the fallback when the archive has no shards yet (so Generate/Stitch can always
/// proceed), and offered alongside `FlockCatalog.listShards()` in the pickers.
private let defaultShard = ShardSpec(
    name: "1920x1080_30fps", width: 1920, height: 1080, fps: 30,
    loopSeconds: 15, transSeconds: 12,
    loopFrames: 450, transFrames: 360,        // round(15·30), round(12·30)
    isCanonical: true, codec: .hevc)

// MARK: - Shared shard menu

/// A shard picker listing the archive's shards (plus the canonical default),
/// loaded lazily from the catalog. A `Menu` (not a `Picker`) so the selection
/// does not require `ShardSpec: Hashable` (FlameFlock keeps its value type as-is;
/// only additive readers are added there).
private struct ShardMenu: View {
    let catalog: FlockCatalog?
    @Binding var shard: ShardSpec

    @State private var available: [ShardSpec] = []

    var body: some View {
        Menu {
            ForEach(allShards, id: \.name) { s in
                Button(shardLabel(s)) { shard = s }
            }
        } label: {
            HStack(spacing: 6) {
                Text("Shard").foregroundStyle(.secondary)
                Text(shard.name)
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
        }
        .task(id: catalog != nil) {
            guard let catalog else { return }
            available = (try? await catalog.listShards()) ?? []
        }
    }

    /// Default first, then existing shards (minus a duplicate of the default),
    /// ordered by name (rule #2 — key-ordered SQL read).
    private var allShards: [ShardSpec] {
        var out = [defaultShard]
        for s in available where s.name != defaultShard.name { out.append(s) }
        return out
    }

    private func shardLabel(_ s: ShardSpec) -> String {
        "\(s.name)  ·  \(s.width)×\(s.height)  ·  \(s.fps) fps"
    }
}

// MARK: - Source loading (shared by Generate + Stitch)

/// A loaded source genome with its resolved flock identity (T8 `IdMinter`):
/// stable `(gen,id)` deduped on the source SHA, minted into reserved flock
/// `900000` for user-loaded files. `Identifiable` for `ForEach`.
private struct LoadedFlame: Identifiable {
    let gen: String
    let id: String
    let flame: Flame
    let displayName: String
    var flameID: String { "\(gen)/\(id)" }
}

/// Resolve library entries → `[LoadedFlame]`, preserving the INPUT order.
/// Reuses the library's cached parse (`LibraryIndex.loadGenome`) rather than
/// re-reading + re-parsing disk; reads the file bytes once only for the
/// `IdMinter` SHA (dedup so the same genome picked twice mints one flock id).
/// Skips entries whose genome can't be parsed.
///
/// Order is the caller's responsibility: Favorites / the multi-selection are
/// pre-sorted via `flockSortedSources` (rule #2 — unordered inputs); a
/// collection's stored order is preserved verbatim (it IS the sequence).
/// Nonisolated: the file reads + actor hops run off the MainActor.
private func loadLibrarySources(_ entries: [LibraryEntry], catalog: FlockCatalog?,
                                libraryIndex: LibraryIndex) async -> [LoadedFlame] {
    guard let catalog else { return [] }
    let minter = IdMinter()
    var out: [LoadedFlame] = []
    for entry in entries {
        guard let flame = try? await libraryIndex.loadGenome(for: entry) else { continue }
        let data = try? Data(contentsOf: entry.fileURL)
        // D7: ES-sourced genomes keep their real `(gen,id)` (parsed from the
        // ES-archive filename) via IdMinter's ES passthrough; user imports and
        // bundled/curated genomes with arbitrary names get minted into 900000.
        let es = esIdentity(for: entry)
        let (gen, id) = (try? await minter.resolve(
            catalog: catalog,
            esGen: es?.gen, esId: es?.id,
            origin: es == nil ? .user : .es,
            sourceRef: entry.fileURL, sourceBytes: data)) ?? ("900000", "000000")
        out.append(LoadedFlame(gen: gen, id: id, flame: flame,
                               displayName: entry.displayName))
    }
    return out
}

// MARK: - Library source menu (shared by Generate + Stitch)

/// A `Menu` that sources Flock genomes from the in-app library — Favorites
/// (Liked), each collection (playlist, in stored order), or the genomes
/// currently selected in the library grid — instead of an `NSOpenPanel` file
/// pick. Selecting an option resolves the entries to `[LoadedFlame]`
/// (`LibraryIndex.loadGenome` + `IdMinter`) and invokes `onLoaded` on the
/// MainActor. Mirrors the `ShardMenu` pattern (a `Menu`, not a `Picker`, so no
/// `Hashable` requirement is imposed on the source set).
///
/// - Favorites: `AppModel.likedEntries()` (sentiment == +1), sorted via
///   `flockSortedSources` for a rule-#2-stable order.
/// - Each collection: its `resolvedPairs` entries in STORED order (the order IS
///   the sequence — never re-sorted).
/// - Selection: `AppModel.selection` (the active multi-select), sorted via
///   `flockSortedSources`; shown only when non-empty.
private struct FlockSourceMenu: View {
    @Environment(AppModel.self) private var appModel
    let label: String
    let catalog: FlockCatalog?
    /// Invoked on the MainActor with the resolved, ordered sources after a pick.
    let onLoaded: @MainActor ([LoadedFlame]) -> Void

    private var favorites: [LibraryEntry] { flockSortedSources(appModel.likedEntries()) }
    private var selection: [LibraryEntry] { flockSortedSources(Array(appModel.selection)) }

    var body: some View {
        Menu(label) {
            Button("Favorites — \(favorites.count)") { load(favorites) }
                .disabled(favorites.isEmpty)

            let collections = appModel.collectionsStore.collections
            if !collections.isEmpty {
                Divider()
                ForEach(collections) { c in
                    let entries = appModel.resolvedPairs(for: c).map(\.entry)
                    Button("Collection: \(c.name) — \(entries.count)") { load(entries) }
                        .disabled(entries.isEmpty)
                }
            }

            if !selection.isEmpty {
                Divider()
                Button("Selected in Library — \(selection.count)") { load(selection) }
            }
        }
        .disabled(catalog == nil)
        .help("Source genomes from the library: Favorites, a collection, or the current selection.")
    }

    /// Kick off the async resolution off the MainActor, then deliver the loaded
    /// sources on the MainActor. No-op for an empty pick (Favorites/selection
    /// surface their counts but the buttons stay disabled when empty).
    private func load(_ entries: [LibraryEntry]) {
        guard !entries.isEmpty, let catalog else { return }
        let libraryIndex = appModel.libraryIndex
        Task {
            let loaded = await loadLibrarySources(entries, catalog: catalog,
                                                  libraryIndex: libraryIndex)
            await MainActor.run { onLoaded(loaded) }
        }
    }
}


/// `ExportSettings` matched to a shard + a quality choice. The archive path
/// renders at the SHARD's width/height (not `settings.resolution`), so resolution
/// is left at default. v0.5.8: the Generate default is now **Standard**
/// (`.medium`, spp 30, the tier's recommended ts, smoothing ON as the tier
/// resolves) — genome-default was impractically slow (~1000 spp ⇒ hours per 1080p
/// edge, which with the old per-unit-only progress read as "0 rendered for
/// hours"). The Flock Generate quality picker lets the owner choose mastering
/// (genome) vs fast (standard/low); Stitch stays genome-default (its current
/// setting) by passing `.genomeDefault` here. spp is resolved per-unit against
/// each unit's flame in `ArchiveRenderer` (so a tier like genome uses each
/// genome's own spp), which is why `ExportSettings.resolve` (single-baseFlame)
/// is NOT used here.
private func archiveSettings(for shard: ShardSpec, quality: ExportQualityChoice) -> ExportSettings {
    var s = ExportSettings()
    s.codec = shard.codec
    s.fps = shard.fps
    s.container = shard.codec.requiresMOVContainer ? .mov : .mp4
    s.quality = quality.exportQuality
    s.temporalSamples = quality.recommendedTemporalSamples
    s.temporalSmoothing = .auto
    s.smoothingAlpha = TemporalSmoothing.auto.alpha(for: quality.exportQuality)
    return s
}

// MARK: - Generate tab (Path A)

private struct GenerateTab: View {
    @Environment(AppModel.self) private var appModel
    @Environment(FlockModel.self) private var flockModel

    @State private var shard = defaultShard
    @State private var sources: [LoadedFlame] = []
    @State private var includeLoops = false
    @State private var loadError: String?
    /// v0.5.8: archive render quality. Default **Standard** (spp 30 + the tier's
    /// ts + smoothing ON) — genome-default was hours per 1080p edge. Genome =
    /// mastering (byte-identical to `animate`); Low/High are faster/slower.
    @State private var qualityChoice: ExportQualityChoice = .medium

    private var catalog: FlockCatalog? { appModel.flockCatalog }
    private var flockRoot: URL { appModel.flockRoot }

    var body: some View {
        Form {
            Section("Render shard") {
                ShardMenu(catalog: catalog, shard: $shard)
                    .help("Resolution + frame rate + pace for the generated material.")
            }
            Section("Source genomes") {
                HStack {
                    FlockSourceMenu(label: "Choose Source…", catalog: catalog) { loaded in
                        sources = loaded
                        loadError = loaded.isEmpty
                            ? "No readable genomes in that selection." : nil
                    }
                    Text("\(sources.count) genome\(sources.count == 1 ? "" : "s")")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                if !sources.isEmpty {
                    List(sources) { f in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.displayName).font(.callout)
                            Text("\(f.flameID)  ·  \(f.flame.isRenderable ? "renderable" : "unrenderable")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(minHeight: 120, maxHeight: 220)
                }
                if let loadError { Text(loadError).font(.caption).foregroundStyle(.red) }
            }
            Section("Scope") {
                Picker("Scope", selection: $includeLoops) {
                    Text("Edges only").tag(false)
                    Text("Edges + Loops").tag(true)
                }
                .pickerStyle(.radioGroup)
                .help("Edges = transitions between adjacent source genomes. Loops = each genome self-spun (opt-in).")
            }
            Section("Quality") {
                Picker("Quality", selection: $qualityChoice) {
                    Text("Genome (mastering)").tag(ExportQualityChoice.genomeDefault)
                    Text("Standard").tag(ExportQualityChoice.medium)
                    Text("High").tag(ExportQualityChoice.high)
                    Text("Low (draft)").tag(ExportQualityChoice.low)
                }
                .disabled(running)
                .help(qualityHelp)
                if qualityChoice != .genomeDefault {
                    Text(qualityChoice.smoothingLabel).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Button("Generate material") { generate() }
                    .buttonStyle(.borderedProminent)
                    .disabled(sources.count < 1 || !canRun)
                if canRun {
                    Button("Cancel") { flockModel.cancelGenerate() }
                        .disabled(!running)
                }
                generateProgress
            }
        }
        .formStyle(.grouped)
        .padding(.top, 6)
    }

    @ViewBuilder
    private var generateProgress: some View {
        switch flockModel.generateState {
        case .idle:
            EmptyView()
        case .resolving:
            Text("Resolving…").font(.caption).foregroundStyle(.secondary)
        case .running(let skip, let render, let total, let eta):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(skip + render), total: Double(max(total, 1)))
                Text("\(render) rendered · \(skip) skipped · \(total) total\(etaText(eta))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .rendering(let skip, let render, let total, let frame, let frameTotal, let eta):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(skip + render), total: Double(max(total, 1)))
                // Per-unit sub-bar: the within-edge/loop frame fraction (the
                // per-video-file progress the owner asked for).
                ProgressView(value: Double(frame), total: Double(max(frameTotal, 1)))
                Text("rendering \(skip + render + 1)/\(total) · frame \(frame)/\(frameTotal)\(etaText(eta))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .completed(let rendered, let skipped):
            Text("Done — \(rendered) rendered, \(skipped) skipped.")
                .font(.caption).foregroundStyle(.green)
        case .failed(let msg):
            Text("Failed: \(msg)").font(.caption).foregroundStyle(.red)
        case .cancelled:
            Text("Cancelled.").font(.caption).foregroundStyle(.secondary)
        }
    }

    /// ETA token appended to the status line. nil ⇒ cold-start "estimating…".
    private func etaText(_ eta: Double?) -> String {
        guard let eta else { return " · estimating…" }
        return " · \(etaLabel(eta))"
    }

    /// ETA as whole seconds / minutes / hours (mirrors ExportProgressSurface's
    /// `etaLabel` style; the `~` prefix signals an estimate).
    private func etaLabel(_ eta: TimeInterval) -> String {
        let total = max(0, Int(eta.rounded()))
        if total < 60 { return "~\(total) s remaining" }
        let m = total / 60, r = total % 60
        if m < 60 { return "~\(m) m \(r) s remaining" }
        let h = m / 60, mr = m % 60
        return "~\(h) h \(mr) m remaining"
    }

    private var qualityHelp: String {
        "Standard (spp 30 + smoothing) is ~genome-clean at ~33× the speed — the practical default. " +
        "Genome is mastering (byte-identical to animate, very slow). High/Low trade quality for time."
    }

    private var running: Bool {
        if case .running = flockModel.generateState { return true }
        if case .rendering = flockModel.generateState { return true }
        if case .resolving = flockModel.generateState { return true }
        return false
    }
    private var canRun: Bool { !running }

    /// Build loop + edge units from the ordered source list, upsert the shard
    /// (the `artifacts.shard` FK requires the row to pre-exist), then drive the
    /// coordinator through `FlockModel.generate` (fire-and-forget).
    private func generate() {
        let units = buildUnits()
        guard !units.isEmpty else { return }
        let scope: GenerateScope = includeLoops ? .both : .edges
        let request = GenerateRequest(shard: shard, units: units, scope: scope,
                                      settings: archiveSettings(for: shard, quality: qualityChoice),
                                      flockRoot: flockRoot)
        Task {
            // FK gate: the shard row must exist before any artifact is inserted.
            if let catalog { try? await catalog.upsertShard(shard) }
            await flockModel.generate(request)
        }
    }

    /// Loops = one self-edge per source; edges = each adjacent pair (mirrors
    /// `StitchCoordinator.buildSegmentKeys`).
    private func buildUnits() -> [GenerateUnit] {
        var units: [GenerateUnit] = []
        for f in sources {
            units.append(GenerateUnit(aGen: f.gen, aId: f.id, bGen: f.gen, bId: f.id, A: f.flame))
        }
        for i in 0..<(sources.count - 1) {
            let a = sources[i], b = sources[i + 1]
            units.append(GenerateUnit(aGen: a.gen, aId: a.id, bGen: b.gen, bId: b.id,
                                      A: a.flame, B: b.flame))
        }
        return units
    }
}

// MARK: - Stitch tab (Path B)

private struct StitchTab: View {
    @Environment(AppModel.self) private var appModel
    @Environment(FlockModel.self) private var flockModel

    @State private var shard = defaultShard
    @State private var sequence: [LoadedFlame] = []
    @State private var loadError: String?

    private var catalog: FlockCatalog? { appModel.flockCatalog }
    private var flockRoot: URL { appModel.flockRoot }

    var body: some View {
        Form {
            Section("Render shard") {
                ShardMenu(catalog: catalog, shard: $shard)
                HStack {
                    Stepper("Loop: \(String(format: "%.1f", shard.loopSeconds)) s",
                            value: $shard.loopSeconds, in: 1...120, step: 0.5)
                        .onChange(of: shard.loopSeconds) { _, _ in recomputePace() }
                    Stepper("Edge: \(String(format: "%.1f", shard.transSeconds)) s",
                            value: $shard.transSeconds, in: 1...120, step: 0.5)
                        .onChange(of: shard.transSeconds) { _, _ in recomputePace() }
                }
            }
            Section("Sequence") {
                HStack {
                    FlockSourceMenu(label: "Choose Sequence…", catalog: catalog) { loaded in
                        sequence = loaded
                        loadError = loaded.count < 2
                            ? "Pick at least 2 genomes for a transition." : nil
                    }
                    Text("\(sequence.count) genome\(sequence.count == 1 ? "" : "s")  ·  \(segmentCount) segments")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                if !sequence.isEmpty {
                    List(sequence) { f in
                        Text("\(f.displayName)  —  \(f.flameID)").font(.callout)
                    }
                    .frame(minHeight: 100, maxHeight: 200)
                }
                if let loadError { Text(loadError).font(.caption).foregroundStyle(.red) }
            }
            Section {
                stitchPlan
                HStack {
                    Button("Stitch → Video…") { stitch() }
                        .buttonStyle(.borderedProminent)
                        .disabled(sequence.count < 1 || !canRun)
                    if canRun {
                        Button("Cancel") { flockModel.cancelStitch() }
                            .disabled(!running)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, 6)
    }

    /// Alternating loop/edge count: one loop per flame plus one edge per pair.
    private var segmentCount: Int {
        sequence.isEmpty ? 0 : (2 * sequence.count - 1)
    }

    @ViewBuilder
    private var stitchPlan: some View {
        switch flockModel.stitchState {
        case .plan(let hit, let miss):
            Text("Plan: \(hit) HIT, \(miss) will-gen.")
                .font(.caption).foregroundStyle(.secondary)
        case .running(let hit, let generated):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(hit + generated),
                             total: Double(max(segmentCount, 1)))
                Text("\(generated) generated · \(hit) reused")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .resolving:
            Text("Resolving…").font(.caption).foregroundStyle(.secondary)
        case .completed(let out):
            Text("Assembled: \(out.lastPathComponent)").font(.caption).foregroundStyle(.green)
        case .failed(let msg):
            Text("Failed: \(msg)").font(.caption).foregroundStyle(.red)
        case .cancelled:
            Text("Cancelled.").font(.caption).foregroundStyle(.secondary)
        case .idle:
            EmptyView()
        }
    }

    private var running: Bool {
        if case .running = flockModel.stitchState { return true }
        if case .resolving = flockModel.stitchState { return true }
        return false
    }
    private var canRun: Bool { !running }

    /// Rebuild `loopFrames`/`transFrames`/`isCanonical`/`name` after a pace edit
    /// (mirrors `FlockNaming.shardDir` — canonical iff 15 s / 12 s).
    private func recomputePace() {
        let lf = Int((shard.loopSeconds * Double(shard.fps)).rounded())
        let tf = Int((shard.transSeconds * Double(shard.fps)).rounded())
        shard.loopFrames = lf
        shard.transFrames = tf
        let canonicalLoop = Int((15.0 * Double(shard.fps)).rounded())
        let canonicalTrans = Int((12.0 * Double(shard.fps)).rounded())
        shard.isCanonical = (lf == canonicalLoop && tf == canonicalTrans)
        shard.name = shard.isCanonical
            ? "\(shard.width)x\(shard.height)_\(shard.fps)fps"
            : "\(shard.width)x\(shard.height)_\(shard.fps)fps_Lf\(lf)-Tf\(tf)"
    }

    private func stitch() {
        let ordered = sequence.map { (gen: $0.gen, id: $0.id, flame: $0.flame) }
        guard ordered.count >= 1 else { return }
        let ext = shard.codec.requiresMOVContainer ? "mov" : "mp4"
        let out = chooseSaveURL(defaultName: "flock-stitch.\(ext)", suggestedDir: flockRoot)
            ?? flockRoot.appendingPathComponent("flock-stitch.\(ext)")
        let request = StitchRequest(shard: shard, orderedFlames: ordered,
                                    settings: archiveSettings(for: shard, quality: .genomeDefault),
                                    flockRoot: flockRoot, out: out)
        Task {
            if let catalog { try? await catalog.upsertShard(shard) }
            await flockModel.stitch(request)
        }
    }
}

// MARK: - Browse tab

private struct BrowseTab: View {
    @Environment(AppModel.self) private var appModel
    @Environment(FlockModel.self) private var flockModel

    @State private var shards: [ShardSpec] = []
    @State private var selectedShardName: String?
    @State private var rows: [ArtifactRow] = []
    @State private var stats: (count: Int, bytes: Int) = (0, 0)
    @State private var thumbs: [String: NSImage] = [:]   // keyed by row.file
    @State private var offset = 0
    @State private var rebuilding = false
    @State private var error: String?

    private let pageSize = 60

    private var catalog: FlockCatalog? { appModel.flockCatalog }
    private var flockRoot: URL { appModel.flockRoot }
    private var selectedShard: ShardSpec? { shards.first { $0.name == selectedShardName } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Picker("Shard", selection: $selectedShardName) {
                    ForEach(shards, id: \.name) { Text($0.name).tag(Optional($0.name)) }
                }
                .pickerStyle(.menu)
                Spacer()
                browseCounts
                Button("Rebuild catalog") { rebuild() }
                    .disabled(rebuilding || catalog == nil)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)

            Divider()

            browseGrid
        }
        .task { await refresh() }
        .onChange(of: selectedShardName) { _, _ in
            offset = 0
            Task { await loadPage() }
        }
    }

    @ViewBuilder
    private var browseCounts: some View {
        switch flockModel.browseState {
        case .loaded(let snap):
            Text("\(snap.shardCount) shard\(snap.shardCount == 1 ? "" : "s")  ·  \(snap.artifactCount) artifact\(snap.artifactCount == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary)
        case .empty:
            Text("Archive empty").font(.caption).foregroundStyle(.secondary)
        case .loading:
            Text("Loading…").font(.caption).foregroundStyle(.secondary)
        case .failed(let msg):
            Text("Catalog: \(msg)").font(.caption).foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var browseGrid: some View {
        if shards.isEmpty {
            ContentUnavailableView(
                "No shards yet",
                systemImage: "bird",
                description: Text("Generate material to populate the archive, or Rebuild from existing \(flockRoot.path) files.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if rows.isEmpty {
            ContentUnavailableView(
                "No artifacts in \(selectedShardName ?? "shard")",
                systemImage: "shippingbox",
                description: Text("This shard has no rendered material.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.adaptive(minimum: 180), spacing: 12),
                                          count: 4),
                          spacing: 12) {
                    ForEach(rows, id: \.file) { row in
                        artifactCell(row)
                    }
                }
                .padding(14)
            }
            HStack {
                Button("← Prev") { offset = max(0, offset - pageSize); Task { await loadPage() } }
                    .disabled(offset == 0)
                Text(pageLabel).font(.caption).foregroundStyle(.secondary)
                Button("Next →") { offset += pageSize; Task { await loadPage() } }
                    .disabled(rows.count < pageSize)
                Spacer()
                Text(humanBytes(stats.bytes))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
    }

    private var pageLabel: String {
        let from = offset + 1
        let to = offset + rows.count
        return "\(from)–\(to) of \(stats.count)"
    }

    @ViewBuilder
    private func artifactCell(_ row: ArtifactRow) -> some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                if let img = thumbs[row.file] {
                    Image(nsImage: img).resizable().scaledToFill()
                        .frame(height: 100).clipped().cornerRadius(6)
                } else {
                    Image(systemName: row.kind == .loop ? "arrow.triangle.2.circlepath" : "arrow.right.square")
                        .imageScale(.large).foregroundStyle(.secondary)
                }
            }
            .frame(height: 100)
            VStack(spacing: 1) {
                Text(row.kind == .loop ? "loop \(row.aId)" : "\(row.aId)→\(row.bId)")
                    .font(.caption2).lineLimit(1)
                Text("\(row.spp) spp · \(humanBytes(row.bytes))")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .contextMenu {
            Button("Show in Finder") { reveal(row) }
            Button("Delete", role: .destructive) { delete(row) }
        }
    }

    /// Refresh snapshot + shard list (catalog reads). Deterministic SQL order.
    private func refresh() async {
        await flockModel.refreshBrowse()
        guard let catalog else { return }
        let list = (try? await catalog.listShards()) ?? []
        await MainActor.run {
            shards = list
            if selectedShardName == nil { selectedShardName = list.first?.name ?? defaultShard.name }
        }
        await loadPage()
    }

    /// Load one indexed page (LIMIT/OFFSET) + the shard stats + thumbnails.
    /// Never mass-parses the archive (spec §13.3 / T17 step 4).
    private func loadPage() async {
        guard let catalog, let name = selectedShardName else { return }
        do {
            let page = try await catalog.artifactPage(shard: name, offset: offset, limit: pageSize)
            let st = try await catalog.shardStats(name)
            // Load thumbnails (the pre-rendered `.jpg` beside each artifact).
            var newThumbs: [String: NSImage] = [:]
            for row in page {
                guard let rel = row.thumb else { continue }
                let url = flockRoot.appendingPathComponent(rel)
                if let data = try? Data(contentsOf: url),
                   let img = NSImage(data: data) {
                    newThumbs[row.file] = img
                }
            }
            await MainActor.run {
                rows = page
                stats = st
                thumbs = newThumbs
                error = nil
            }
        } catch {
            await MainActor.run { self.error = String(describing: error) }
        }
    }

    private func rebuild() {
        guard let catalog else { return }
        rebuilding = true
        Task {
            do {
                try await FlockCatalog.rebuild(from: flockRoot)
                await refresh()
            } catch {
                await MainActor.run { self.error = "Rebuild failed: \(error)" }
            }
            await MainActor.run { rebuilding = false }
        }
    }

    private func delete(_ row: ArtifactRow) {
        guard let catalog, let name = selectedShardName else { return }
        Task {
            try? await catalog.removeArtifact(aGen: row.aGen, aId: row.aId,
                                              bGen: row.bGen, bId: row.bId, shard: name)
            // Best-effort file removal (the .mov + .jpg); the catalog is truth.
            let base = flockRoot.appendingPathComponent(row.file)
            try? FileManager.default.removeItem(at: base)
            try? FileManager.default.removeItem(at: base.deletingPathExtension().appendingPathExtension("jpg"))
            await loadPage()
            await flockModel.refreshBrowse()
        }
    }

    private func reveal(_ row: ArtifactRow) {
        let url = flockRoot.appendingPathComponent(row.file)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - Bytes formatting (Int arithmetic — rule-#2-safe)

private func humanBytes(_ n: Int) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var v = Double(n)
    var i = 0
    while v >= 1024, i < units.count - 1 { v /= 1024; i += 1 }
    return i == 0 ? "\(n) B" : String(format: "%.1f %@", v, units[i])
}
