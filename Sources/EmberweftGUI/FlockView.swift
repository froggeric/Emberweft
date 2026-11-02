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

            // A tab view in the main content area (H12, segmented-controls.md:
            // full panes are views, not attributes of a selection). TabView
            // also keeps each pane's @State alive across switches — the old
            // segmented picker rebuilt the active branch, wiping the
            // Generate/Stitch form mid-run.
            TabView(selection: $tab) {
                GenerateTab()
                    .tabItem { Label("Generate", systemImage: "wand.and.rays") }
                    .tag(FlockTab.generate)
                StitchTab()
                    .tabItem { Label("Stitch", systemImage: "film") }
                    .tag(FlockTab.stitch)
                BrowseTab()
                    .tabItem { Label("Browse", systemImage: "square.grid.2x2") }
                    .tag(FlockTab.browse)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Flock Archive")
        .navigationSubtitle("Render, assemble, and browse the local flock.")
    }
}

private enum FlockTab { case generate, stitch, browse }

/// The canonical default shard (1080p30, 15 s loops / 12 s edges, HEVC) —
/// `ShardPresets.canonicalDefault` (FlameFlock). Used as the fallback when the
/// archive has no shards yet (so Generate/Stitch can always proceed) and as the
/// resolution of an unset/unknown `AppPreferences.flockDefaultShard`.
private let defaultShard = ShardPresets.canonicalDefault

// MARK: - Shared shard menu

/// A shard picker in three sections: **Standard** + **Vertical** (the
/// `ShardPresets.sensible` canonical profiles, split by the shared
/// `ShardPresets.isVertical` predicate — grouping is a view concern, D14, so
/// membership stays flat in FlameFlock; square shards stay in Standard since
/// `isVertical` is false when h == w; always offered, even on a fresh archive
/// with no shard rows) and **In your archive** (the catalog's shards, minus
/// duplicates of the presets matched by name). A `Menu` (not a `Picker`) so the
/// selection does not require `ShardSpec: Hashable` (FlameFlock keeps its value
/// type as-is; only additive readers are added there).
///
/// Selecting a Standard preset that has no catalog row yet just works: the tab
/// upserts the selected `ShardSpec` at the start of generate/stitch (the
/// `artifacts.shard` FK requires the row to pre-exist), so presets create their
/// shard row on demand rather than needing pre-seeding.
private struct ShardMenu: View {
    let catalog: FlockCatalog?
    @Binding var shard: ShardSpec

    @State private var available: [ShardSpec] = []

    var body: some View {
        Menu {
            Section("Standard") {
                ForEach(ShardPresets.sensible.filter { !ShardPresets.isVertical($0) }, id: \.name) { s in
                    Button(shardLabel(s)) { shard = s }
                }
            }
            Section("Vertical") {
                ForEach(ShardPresets.sensible.filter { ShardPresets.isVertical($0) }, id: \.name) { s in
                    Button(shardLabel(s)) { shard = s }
                }
            }
            let archive = archiveShards
            if !archive.isEmpty {
                Section("In your archive") {
                    ForEach(archive, id: \.name) { s in
                        Button(shardLabel(s)) { shard = s }
                    }
                }
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

    /// Catalog shards that are not one of the Standard presets (matched by NAME
    /// — the preset and a catalog row with the same name are the same shard).
    /// Name-ordered from the key-ordered SQL read (rule #2); the `Set` is
    /// membership-only, never iterated.
    private var archiveShards: [ShardSpec] {
        let presetNames = Set(ShardPresets.sensible.map(\.name))
        return available.filter { !presetNames.contains($0.name) }
    }

    private func shardLabel(_ s: ShardSpec) -> String {
        "\(s.name)  ·  \(s.width)×\(s.height)  ·  \(s.fps) fps"
    }
}

// MARK: - Shared pace steppers (Generate + Stitch)

/// Loop/edge pace steppers, shared by BOTH tabs so their ranges/step (1…120 s,
/// 0.5 s) and the recompute stay identical. Editing either value re-derives
/// `loopFrames`/`transFrames`/`isCanonical`/`name` via `ShardSpec.withPace`
/// (which names the shard through `FlockNaming.shardDir`): the canonical
/// 15 s / 12 s pace keeps the bare `WxH_fps` name, any other pace appends
/// `_Lf<loop>-Tf<trans>` — a NEW shard directory, so a custom pace never
/// overwrites canonical-pace material.
private struct ShardPaceSteppers: View {
    @Binding var shard: ShardSpec

    var body: some View {
        HStack {
            Stepper("Loop: \(String(format: "%.1f", shard.loopSeconds)) s",
                    value: $shard.loopSeconds, in: 1...120, step: 0.5)
                .onChange(of: shard.loopSeconds) { _, _ in applyPace() }
            Stepper("Transition: \(String(format: "%.1f", shard.transSeconds)) s",
                    value: $shard.transSeconds, in: 1...120, step: 0.5)
                .onChange(of: shard.transSeconds) { _, _ in applyPace() }
        }
        .help("Pace for this shard's material. 15 s loops / 12 s edges is the canonical pace; any other pace creates a new shard directory (name gets an _Lf…-Tf… suffix) so existing material is never overwritten.")
    }

    /// The steppers write the seconds into the binding first; this then folds
    /// the derived fields (frames / canonical flag / name) back in.
    private func applyPace() {
        shard = shard.withPace(loopSeconds: shard.loopSeconds,
                               transSeconds: shard.transSeconds)
    }
}

// MARK: - Initial shard resolution (AppPreferences.flockDefaultShard)

/// Resolve a tab's initial shard from `AppPreferences.flockDefaultShard`: the
/// named CATALOG row if one exists (the archive is truth — it may carry a
/// re-upserted profile), else the named Standard preset, else the canonical
/// default. One async catalog hop; pure otherwise.
private func resolveInitialShard(pref: String?, catalog: FlockCatalog?) async -> ShardSpec {
    guard let name = pref else { return defaultShard }
    if let catalog, let row = (try? await catalog.shard(named: name)) ?? nil {
        return row
    }
    return ShardPresets.preset(named: name) ?? defaultShard
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


/// `ExportSettings` matched to a shard + a quality choice. Resolution is set to
/// the SHARD's width/height (the encoder sizes its pool + output track from
/// `settings.resolution` — the v0.6.0 crash left it at the 1080p default, so any
/// other shard trapped in `PixelBufferPool.fill`; `ArchiveRenderer` now also
/// enforces this as a belt-and-suspenders override). v0.5.8: the Generate default is now **Standard**
/// (`.medium`, spp 30, the tier's recommended ts, smoothing ON as the tier
/// resolves) — genome-default was impractically slow (~1000 spp ⇒ hours per 1080p
/// edge, which with the old per-unit-only progress read as "0 rendered for
/// hours"). The Flock Generate quality picker lets the owner choose mastering
/// (genome) vs fast (standard/low). v0.5.10: the STITCH tab got the same picker
/// (default `.medium` too — its MISS re-renders pay the same genome-tier cost),
/// replacing the old hardcoded `.genomeDefault`; both tabs share this ONE helper.
/// spp is resolved per-unit against each unit's flame in `ArchiveRenderer` (so a
/// tier like genome uses each genome's own spp), which is why
/// `ExportSettings.resolve` (single-baseFlame) is NOT used here.
private func archiveSettings(for shard: ShardSpec, quality: ExportQualityChoice) -> ExportSettings {
    var s = ExportSettings()
    s.resolution = .custom(width: shard.width, height: shard.height)
    s.codec = shard.codec
    s.fps = shard.fps
    s.container = shard.codec.requiresMOVContainer ? .mov : .mp4
    s.quality = quality.exportQuality
    s.temporalSamples = quality.recommendedTemporalSamples
    s.temporalSmoothing = .auto
    s.smoothingAlpha = TemporalSmoothing.auto.alpha(for: quality.exportQuality)
    // M6.6: the flock archive is ALWAYS normalized framing — resolution-
    // independent framing is the archive's whole point (same composition at
    // every shard size), and the catalog's framing gate keeps mixed-framing
    // archives from stitching with framing jumps. No GUI toggle.
    s.framing = .normalized
    return s
}

// MARK: - Generate tab (Path A)

private struct GenerateTab: View {
    @Environment(AppModel.self) private var appModel
    @Environment(FlockModel.self) private var flockModel

    @State private var shard = defaultShard
    @State private var sources: [LoadedFlame] = []
    /// 3-way scope (the 2-state bool made "Loops only" unreachable): `.edges`
    /// is the default (D10 — transitions are the stitch-critical material),
    /// `.loops` renders each genome self-spun with no transitions, `.both` is
    /// the full timeline.
    @State private var scope: GenerateScope = .edges
    @State private var loadError: String?
    /// v0.5.8: archive render quality. Default **Standard** (spp 30 + the tier's
    /// ts + smoothing ON) — genome-default was hours per 1080p edge. Genome =
    /// mastering (byte-identical to `animate`); Low/High are faster/slower.
    @State private var qualityChoice: ExportQualityChoice = .medium

    private var catalog: FlockCatalog? { appModel.flockCatalog }
    private var flockRoot: URL { appModel.flockRoot }

    var body: some View {
        Form {
            // "Render Format" (not "shard" — the storage-layer term appeared in
            // a section title with no in-UI definition; the help line defines
            // what the control actually picks).
            Section("Render Format") {
                ShardMenu(catalog: catalog, shard: $shard)
                    .help("Resolution, frame rate, and pace for the generated material.")
                    // Mid-run edits silently don't apply (the request captured
                    // the shard at press time) — match the other controls.
                    .disabled(running)
                ShardPaceSteppers(shard: $shard)
                    .disabled(running)
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
                Picker("Scope", selection: $scope) {
                    Text("Edges only").tag(GenerateScope.edges)
                    Text("Loops only").tag(GenerateScope.loops)
                    Text("Edges and loops").tag(GenerateScope.both)
                }
                .pickerStyle(.radioGroup)
                .disabled(running)
                .help(scopeHelp)
                Text(scopeSummary).font(.caption).foregroundStyle(.secondary)
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
                    // Disabled when the SCOPE has no work: a single source yields
                    // one loop unit but zero edges, so "Edges only" needs ≥2.
                    .disabled(scopedUnitCount == 0 || !canRun)
                // Cancel is visible ONLY while work is running (v0.5.9 fix: the
                // old `if canRun` guard showed the button only when NOT running —
                // inverted, so it was never visible-enabled mid-run).
                if running {
                    Button("Cancel") { flockModel.cancelGenerate() }
                        .disabled(cancelling)
                        .help(cancelling
                              ? "Stopping the in-flight render…"
                              : "Stop the in-flight render (takes effect within a frame or two). Completed units stay in the archive (resumable).")
                }
                generateProgress
            }
        }
        .formStyle(.grouped)
        .padding(.top, 6)
        .task {
            // Initial shard from Settings (AppPreferences.flockDefaultShard):
            // the named catalog/preset shard if it exists, else the default.
            shard = await resolveInitialShard(pref: appModel.prefs.flockDefaultShard,
                                              catalog: catalog)
        }
    }

    @ViewBuilder
    private var generateProgress: some View {
        switch flockModel.generateState {
        case .idle:
            EmptyView()
        case .resolving:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking the archive…").font(.caption).foregroundStyle(.secondary)
            }
        case .running(let skip, let render, let total, let eta):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(skip + render), total: Double(max(total, 1)))
                Text("\(render) rendered · \(skip) skipped · \(total) total · \(ProgressFormatting.etaToken(eta))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .rendering(let skip, let render, let total, let frame, let frameTotal, let eta):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(skip + render), total: Double(max(total, 1)))
                // Per-unit sub-bar: the within-edge/loop frame fraction (the
                // per-video-file progress the owner asked for).
                ProgressView(value: Double(frame), total: Double(max(frameTotal, 1)))
                Text("rendering \(skip + render + 1)/\(total) · frame \(frame)/\(frameTotal) · \(ProgressFormatting.etaToken(eta))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .completed(let rendered, let skipped):
            let elapsed = flockModel.generateElapsedSeconds.map { " · \(ProgressFormatting.elapsedLabel($0))" } ?? ""
            Text("Done — \(rendered) rendered, \(skipped) skipped\(elapsed).")
                .font(.caption).foregroundStyle(.green)
        case .cancelling:
            // Set synchronously at Cancel press (v0.5.11) — immediate feedback
            // while the in-flight frame unwinds (≤ a frame or two).
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Cancelling…").font(.caption).foregroundStyle(.secondary)
            }
        case .failed(let msg):
            Text(msg).font(.caption).foregroundStyle(.red)
        case .cancelled:
            Text("Cancelled. Completed units stay in the archive (re-run Generate to resume).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var qualityHelp: String {
        "Standard (spp 30 + smoothing) is ~genome-clean at ~33× the speed — the practical default. " +
        "Genome is mastering (byte-identical to animate, very slow). High/Low trade quality for time."
    }

    /// Scope help (3-way): what each option renders into the archive.
    private var scopeHelp: String {
        "Edges = the transitions between adjacent source genomes (the stitch-critical default). " +
        "Loops = each genome self-spun as its own seamless cycle, with NO transitions. " +
        "Edges and loops = the full stitchable timeline."
    }

    /// Units the current scope would render: `N` loops + `N−1` edges are
    /// enumerated, then filtered by the scope (mirrors the coordinator's
    /// `inScope` filter). Pure integer count (rule #2).
    private var scopedUnitCount: Int {
        let loops = sources.count
        let edges = max(0, sources.count - 1)
        switch scope {
        case .edges: return edges
        case .loops: return loops
        case .both:  return loops + edges
        }
    }

    /// One-line unit count for the current scope + sources (the plan the button
    /// will run), including the pace the units render at.
    private var scopeSummary: String {
        guard !sources.isEmpty else { return "Pick sources to see the unit count." }
        let loops = sources.count
        let edges = max(0, sources.count - 1)
        let planned: String
        switch scope {
        case .edges: planned = "\(edges) edge\(edges == 1 ? "" : "s")"
        case .loops: planned = "\(loops) loop\(loops == 1 ? "" : "s")"
        case .both:  planned = "\(edges) edge\(edges == 1 ? "" : "s") + \(loops) loop\(loops == 1 ? "" : "s")"
        }
        return "Will render \(planned) at \(String(format: "%.0f", shard.loopSeconds)) s / \(String(format: "%.0f", shard.transSeconds)) s."
    }

    private var running: Bool {
        if case .running = flockModel.generateState { return true }
        if case .rendering = flockModel.generateState { return true }
        if case .resolving = flockModel.generateState { return true }
        // The unwind is sub-two-frame, but keep the run marked in-flight until
        // the terminal state lands (Generate disabled, Cancel shown but dimmed).
        if case .cancelling = flockModel.generateState { return true }
        return false
    }
    private var cancelling: Bool {
        if case .cancelling = flockModel.generateState { return true }
        return false
    }
    private var canRun: Bool { !running }

    /// Build loop + edge units from the ordered source list, upsert the shard
    /// (the `artifacts.shard` FK requires the row to pre-exist — this is also
    /// what makes an un-rendered Standard preset work), then drive the
    /// coordinator through `FlockModel.generate` (fire-and-forget).
    private func generate() {
        let units = buildUnits()
        let request = GenerateRequest(shard: shard, units: units, scope: scope,
                                      settings: archiveSettings(for: shard, quality: qualityChoice),
                                      flockRoot: flockRoot)
        Task {
            // FK gate: the shard row must exist before any artifact is inserted.
            // Skipped when there is no in-scope work (FlockModel reports the
            // empty run as a failure — no point creating an empty shard row).
            if let catalog, !units.isEmpty { try? await catalog.upsertShard(shard) }
            await flockModel.generate(request)
        }
    }

    /// Build loop + edge units from the ordered source list. Delegates to
    /// `GenerateUnit.enumerate` so the TIMELINE order (loop(A), edge(A→B),
    /// loop(B), … — the 2026-08-13 owner decision, shared with the CLI) is used
    /// verbatim; the SCOPE filters which of those units render. The unit set is
    /// `N` loops + `N−1` edges regardless of order.
    private func buildUnits() -> [GenerateUnit] {
        GenerateUnit.enumerate(sources.map { (gen: $0.gen, id: $0.id, flame: $0.flame) })
    }
}

// MARK: - Stitch tab (Path B)

private struct StitchTab: View {
    @Environment(AppModel.self) private var appModel
    @Environment(FlockModel.self) private var flockModel

    @State private var shard = defaultShard
    @State private var sequence: [LoadedFlame] = []
    @State private var loadError: String?
    /// v0.5.10: stitch-time render quality for MISS segments — the SAME picker
    /// (and `.medium` default) as the Generate tab, replacing the old hardcoded
    /// `.genomeDefault`. The plan's D4 rank comparison uses it: an existing
    /// archive row only HITs if its quality meets/exceeds this choice, else the
    /// segment is re-rendered (upgrade-overwrite).
    @State private var qualityChoice: ExportQualityChoice = .medium
    /// Loop repetitions (stitch-TIME, default 2): each loop SLOT references its
    /// one canonical archive artifact this many times in the concat list. NOT a
    /// frame repeat (the removed v0.5.7 feature) — full framerate, one archive
    /// file, zero re-render; a loop's last frame equals its first, so back-to-
    /// back plays are seamless. Edges are never repeated.
    @State private var loopReps = 2

    private var catalog: FlockCatalog? { appModel.flockCatalog }
    private var flockRoot: URL { appModel.flockRoot }

    var body: some View {
        Form {
            // Same "Render Format" rename + mid-run lock as the Generate tab.
            Section("Render Format") {
                ShardMenu(catalog: catalog, shard: $shard)
                    .disabled(running)
                // The SAME shared steppers as the Generate tab (one source of
                // truth for ranges/step + the non-canonical-name recompute).
                ShardPaceSteppers(shard: $shard)
                    .disabled(running)
            }
            Section("Timeline") {
                Stepper("Loop repetitions: \(loopReps)", value: $loopReps, in: 1...5)
                    .disabled(running)
                    .help(repsHelp)
                Text(repsSummary).font(.caption).foregroundStyle(.secondary)
            }
            Section("Sequence") {
                HStack {
                    FlockSourceMenu(label: "Choose Sequence…", catalog: catalog) { loaded in
                        sequence = loaded
                        loadError = loaded.isEmpty
                            ? "Pick at least 1 genome." : nil
                    }
                    Text("\(sequence.count) genome\(sequence.count == 1 ? "" : "s")  ·  \(segmentCount) segments  ·  \(timelineDuration)")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                // The list IS the edit surface for order/membership (it used to
                // be display-only — the only way to change order was re-picking
                // the whole source). Caption says why it matters.
                if !sequence.isEmpty {
                    Text("Order determines the video — drag rows, or right-click to move or remove.")
                        .font(.caption).foregroundStyle(.secondary)
                    List {
                        ForEach(Array(sequence.enumerated()), id: \.element.id) { index, f in
                            Text("\(f.displayName)  —  \(f.flameID)").font(.callout)
                                .contextMenu {
                                    Button("Move Up") { moveSequence(at: index, by: -1) }
                                        .disabled(index == 0)
                                    Button("Move Down") { moveSequence(at: index, by: 1) }
                                        .disabled(index == sequence.count - 1)
                                    Divider()
                                    Button("Remove", role: .destructive) { sequence.remove(at: index) }
                                }
                        }
                        .onMove { from, to in sequence.move(fromOffsets: from, toOffset: to) }
                        .onDelete { offsets in sequence.remove(atOffsets: offsets) }
                    }
                    .frame(minHeight: 100, maxHeight: 200)
                }
                // count == 1 is VALID (a lone loop stitches fine) — an
                // informational caption, not a red error next to an enabled
                // button (the old "< 2" message contradicted the action).
                if sequence.count == 1 {
                    Text("1 genome stitches as a lone loop — add a second genome for a transition.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let loadError { Text(loadError).font(.caption).foregroundStyle(.red) }
            }
            Section("Quality") {
                Picker("Quality", selection: $qualityChoice) {
                    Text("Genome (mastering)").tag(ExportQualityChoice.genomeDefault)
                    Text("Standard").tag(ExportQualityChoice.medium)
                    Text("High").tag(ExportQualityChoice.high)
                    Text("Low (draft)").tag(ExportQualityChoice.low)
                }
                .disabled(running)
                .help(stitchQualityHelp)
                if qualityChoice != .genomeDefault {
                    Text(qualityChoice.smoothingLabel).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                stitchPlan
                HStack {
                    Button("Stitch Video…") { stitch() }
                        .buttonStyle(.borderedProminent)
                        .disabled(sequence.count < 1 || !canRun)
                    // Visible ONLY while running (v0.5.9 fix: the old `if canRun`
                    // guard inverted the visibility — Cancel never showed mid-run).
                    // Disabled while `.cancelling` (a second press is a no-op) and
                    // during `.concatenating` (the seconds-bounded remux tail is
                    // not cancellable by design — it completes the stitch).
                    if running {
                        Button("Cancel") { flockModel.cancelStitch() }
                            .disabled(cancelling || concatenating)
                            .help(cancelling
                                  ? "Stopping the in-flight render…"
                                  : (concatenating
                                     ? "Finishing the final remux (a few seconds)…"
                                     : "Stop the in-flight render (takes effect within a frame or two). Rendered segments stay in the archive."))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, 6)
        .task {
            // Initial shard from Settings (AppPreferences.flockDefaultShard):
            // the named catalog/preset shard if it exists, else the default.
            shard = await resolveInitialShard(pref: appModel.prefs.flockDefaultShard,
                                              catalog: catalog)
        }
    }

    /// Move a sequence row by ±1 (the context-menu fallback for pointer users
    /// who don't drag). Bounds-checked; no-op at the edges.
    private func moveSequence(at index: Int, by delta: Int) {
        let to = index + delta
        guard sequence.indices.contains(index), sequence.indices.contains(to) else { return }
        sequence.move(fromOffsets: IndexSet(integer: index), toOffset: to > index ? to + 1 : to)
    }

    /// Timeline slot count (reps-aware): `N·r` loop slots (each flame's loop
    /// referenced `loopReps` times) + `N−1` edge slots (never repeated).
    private var segmentCount: Int {
        sequence.isEmpty ? 0 : sequence.count * loopReps + (sequence.count - 1)
    }

    /// Assembled-timeline duration: `N·r·loopSec + (N−1)·edgeSec`, formatted by
    /// the ONE shared duration formatter (rule: do not fork formatters).
    private var timelineDuration: String {
        guard !sequence.isEmpty else { return "0 s" }
        let seconds = Double(sequence.count) * Double(loopReps) * shard.loopSeconds
            + Double(sequence.count - 1) * shard.transSeconds
        return ProgressFormatting.elapsedLabel(seconds)
    }

    private var repsHelp: String {
        "Each loop plays this many times in the stitched timeline; the archived artifact stays one canonical cycle. "
            + "Not a frame repeat: full framerate, one archive file per loop, edges play once."
    }

    /// One-line summary of what reps does to the timeline (shown under the
    /// stepper): the loop/edge slot split + the total duration.
    private var repsSummary: String {
        let loops = sequence.count * loopReps
        let edges = max(0, sequence.count - 1)
        return "\(loops) loop plays + \(edges) transition\(edges == 1 ? "" : "s") · total \(timelineDuration)"
    }

    private var stitchQualityHelp: String {
        "Quality for segments Stitch must (re)generate. Existing archive material is reused only if it meets or "
            + "exceeds this quality (else it is re-rendered as an upgrade). Standard (spp 30 + smoothing) is the "
            + "practical default; Genome is mastering (byte-identical to animate, very slow)."
    }

    @ViewBuilder
    private var stitchPlan: some View {
        switch flockModel.stitchState {
        case .plan(let hit, let miss, let segments):
            // hit/miss count UNIQUE archive work (a repeated loop that must be
            // generated is ONE will-gen); `segments` is the timeline slot total
            // (duplicates included — the progress denominator).
            Text("Plan: \(hit) reused · \(miss) to render · \(segments) segment\(segments == 1 ? "" : "s").")
                .font(.caption).foregroundStyle(.secondary)
        case .resolving:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking the archive…").font(.caption).foregroundStyle(.secondary)
            }
        case .running(let hit, let generated, let total, let eta):
            // Bar denominator is STATE-driven (hit + miss from the plan), not the
            // view's `segmentCount` (which goes stale if the sequence changes).
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(hit + generated), total: Double(max(total, 1)))
                Text("\(generated) generated · \(hit) reused · \(ProgressFormatting.etaToken(eta))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .rendering(let segment, let total, let isLoop, let frame, let frameTotal, let eta):
            // Per-frame progress during a MISS render (v0.5.9 — the blackout
            // fix): overall bar advances smoothly across segment + frame; the
            // sub-bar is the within-segment frame fraction.
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(segment - 1) + Double(frame) / Double(max(frameTotal, 1)),
                             total: Double(max(total, 1)))
                ProgressView(value: Double(frame), total: Double(max(frameTotal, 1)))
                Text("rendering segment \(segment)/\(total) (\(isLoop ? "loop" : "edge")) · frame \(frame)/\(frameTotal) · \(ProgressFormatting.etaToken(eta))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .concatenating(let segments):
            // The remux/copy tail phase — indeterminate, but LABELED (it takes
            // seconds; silence here reads as a hang).
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(segments > 1 ? "Stitching \(segments) segments…" : "Writing output…")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .cancelling:
            // Set synchronously at Cancel press (v0.5.11) — immediate feedback
            // while the in-flight MISS frame unwinds (≤ a frame or two).
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Cancelling…").font(.caption).foregroundStyle(.secondary)
            }
        case .completed(let out):
            VStack(alignment: .leading, spacing: 4) {
                let elapsed = flockModel.stitchElapsedSeconds.map { " · \(ProgressFormatting.elapsedLabel($0))" } ?? ""
                Text("Assembled\(elapsed)").font(.caption).foregroundStyle(.green)
                HStack(spacing: 8) {
                    Text(out.lastPathComponent)
                        .font(.caption2).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                        .help(out.path)
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([out])
                    }
                    .controlSize(.small)
                }
            }
        case .failed(let msg):
            Text(msg).font(.caption).foregroundStyle(.red)
        case .cancelled:
            Text("Cancelled. Rendered segments stay in the archive (re-run Stitch to finish).")
                .font(.caption).foregroundStyle(.secondary)
        case .idle:
            EmptyView()
        }
    }

    private var running: Bool {
        if case .running = flockModel.stitchState { return true }
        if case .rendering = flockModel.stitchState { return true }
        if case .concatenating = flockModel.stitchState { return true }
        if case .resolving = flockModel.stitchState { return true }
        if case .plan = flockModel.stitchState { return true }
        // Keep the run marked in-flight until the terminal state lands.
        if case .cancelling = flockModel.stitchState { return true }
        return false
    }
    private var cancelling: Bool {
        if case .cancelling = flockModel.stitchState { return true }
        return false
    }
    private var concatenating: Bool {
        if case .concatenating = flockModel.stitchState { return true }
        return false
    }
    private var canRun: Bool { !running }

    // Pace recompute after a stepper edit lives in the shared
    // `ShardPaceSteppers` (→ `ShardSpec.withPace` in FlameFlock), so Generate
    // and Stitch can never drift.

    private func stitch() {
        let ordered = sequence.map { (gen: $0.gen, id: $0.id, flame: $0.flame) }
        guard ordered.count >= 1 else { return }
        let ext = shard.codec.requiresMOVContainer ? "mov" : "mp4"
        // Save-panel Cancel aborts the command (H2): coalescing nil into a
        // FIXED fallback path used to run the multi-minute stitch anyway and
        // silently overwrote the previous result at that same fixed path.
        guard let out = chooseSaveURL(defaultName: "flock-stitch.\(ext)",
                                      suggestedDir: flockRoot) else { return }
        let request = StitchRequest(shard: shard, orderedFlames: ordered,
                                    settings: archiveSettings(for: shard, quality: qualityChoice),
                                    flockRoot: flockRoot, out: out,
                                    loopRepetitions: loopReps)
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
    /// Pending artifact for the delete confirmation (H1): nil ⇒ dialog hidden.
    /// Deleting destroys minutes-to-hours of render output, so it confirms and
    /// moves files to the Trash (recoverable) instead of permanent removal.
    @State private var pendingDelete: ArtifactRow?

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
                // Rebuild feedback (v0.5.9): the scan re-reads the whole archive
                // and takes seconds — previously only the button disabled, with
                // NO running indication (a blackout phase).
                if rebuilding {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text("Rebuilding…").font(.caption).foregroundStyle(.secondary)
                    }
                    .help("Re-scanning the flock archive files into the catalog.")
                }
                browseCounts
                Button("Rebuild catalog") { rebuild() }
                    .disabled(rebuilding || catalog == nil)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)

            Divider()

            // Page-load / rebuild failures were previously written into `error`
            // but never RENDERED (set-and-forgotten) — surface them.
            if let error {
                Text(error)
                    .font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.top, 6)
            }

            browseGrid
        }
        .task { await refresh() }
        .onChange(of: selectedShardName) { _, _ in
            offset = 0
            Task { await loadPage() }
        }
        // Delete confirmation (H1): each artifact is minutes-to-hours of
        // render output — confirm, then Trash (recoverable) instead of
        // permanent removal. Triggered from the AppKit context menu; the
        // bridge's one-runloop-turn deferral lets the dialog present after
        // menu teardown.
        .confirmationDialog(
            Text("Delete this \(pendingDelete?.kind == .loop ? "loop" : "transition")?"),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { row in
            Button("Move to Trash", role: .destructive) { delete(row) }
            Button("Cancel", role: .cancel) {}
        } message: { row in
            Text("It was rendered at \(row.spp) samples per pixel and must be re-rendered to restore.")
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
            Text(msg).font(.caption).foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var browseGrid: some View {
        if shards.isEmpty {
            ContentUnavailableView(
                "Archive is empty",
                systemImage: "bird",
                description: Text("Generate material to fill it, or rebuild from videos already in the archive folder.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if stats.count == 0 {
            ContentUnavailableView(
                "No videos in this format",
                systemImage: "shippingbox",
                description: Text("The format “\(selectedShardName ?? "")” has no rendered material yet.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // H7: the pager stays mounted whenever the shard HAS artifacts —
            // an offset past the last page (deletions, exact-multiple counts)
            // shows an empty grid + a working Previous instead of a false
            // "No artifacts" dead end with no way back.
            if rows.isEmpty {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
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
            }
            HStack {
                Button("Previous") { offset = max(0, offset - pageSize); Task { await loadPage() } }
                    .disabled(offset == 0)
                Text(pageLabel).font(.caption).foregroundStyle(.secondary)
                Button("Next") { offset += pageSize; Task { await loadPage() } }
                    // Last page when the page END reaches the count (an
                    // exact-multiple page used to leave Next enabled into an
                    // empty page).
                    .disabled(offset + rows.count >= stats.count)
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
                    Image(nsImage: img).resizable().scaledToFit()
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
                // caption2 (10 pt, scales with text size) — the old fixed
                // 9 pt system font sat below the macOS minimum and ignored
                // larger-text settings. "samples/px" per the app-wide language
                // pass (no bare "spp").
                Text("\(row.spp) samples/px · \(humanBytes(row.bytes))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        // Double-click previews the video (Quick Look) — a video archive you
        // can't watch forced every "what does this look like?" question out to
        // Finder. Preview + existing actions also surface as context items.
        .onTapGesture(count: 2) { QuickLookPresenter.shared.present(flockRoot.appendingPathComponent(row.file)) }
        .overlay(AppKitContextMenu {
            let menu = NSMenu()
            menu.addItem(NSMenuItem("Preview") {
                QuickLookPresenter.shared.present(flockRoot.appendingPathComponent(row.file))
            })
            menu.addItem(NSMenuItem("Show in Finder") { reveal(row) })
            menu.addItem(NSMenuItem("Move to Trash", destructive: true) {
                pendingDelete = row
            })
            return menu
        })
        // One combined element (a11y finding): the image + captions form one
        // artifact; name it and expose the actions as named accessibility
        // actions instead of an unlabeled image.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(a11yLabel(for: row))
        .accessibilityHint("Double-click to preview")
        .accessibilityAction(named: "Preview") {
            QuickLookPresenter.shared.present(flockRoot.appendingPathComponent(row.file))
        }
        .accessibilityAction(named: "Show in Finder") { reveal(row) }
        .accessibilityAction(named: "Move to Trash") { pendingDelete = row }
    }

    /// Spoken label for one artifact cell (kind + id + quality + size).
    private func a11yLabel(for row: ArtifactRow) -> String {
        let kind = row.kind == .loop ? "Loop" : "Transition"
        let pair = row.kind == .loop ? row.aId : "\(row.aId) to \(row.bId)"
        return "\(kind) \(pair), \(row.spp) samples per pixel, \(humanBytes(row.bytes))"
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
            await MainActor.run {
                self.error = FlockModel.friendlyFailure(error, action: "Loading the archive")
            }
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
                await MainActor.run { self.error = FlockModel.friendlyRebuildFailure(error) }
            }
            await MainActor.run { rebuilding = false }
        }
    }

    private func delete(_ row: ArtifactRow) {
        guard let catalog, let name = selectedShardName else { return }
        Task {
            try? await catalog.removeArtifact(aGen: row.aGen, aId: row.aId,
                                              bGen: row.bGen, bId: row.bId, shard: name)
            // Best-effort file removal (.mov + .jpg) to the TRASH — recoverable
            // (each artifact is minutes-to-hours of render output); the catalog
            // is truth for the archive listing.
            let base = flockRoot.appendingPathComponent(row.file)
            let jpg = base.deletingPathExtension().appendingPathExtension("jpg")
            var thrown: [URL] = []
            if FileManager.default.fileExists(atPath: base.path) { thrown.append(base) }
            if FileManager.default.fileExists(atPath: jpg.path) { thrown.append(jpg) }
            if !thrown.isEmpty {
                NSWorkspace.shared.recycle(thrown) { _, _ in }   // best-effort
            }
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
