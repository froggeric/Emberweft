import Foundation
import CryptoKit       // SHA256 (ES sheep source_sha + IdMinter-style hex)
import FlameKit
import FlameExport
import FlameFlock
import FlameRenderer   // MetalRenderer.isAvailable (probe) — @MainActor

extension EmberweftCLI {

    /// `emberweft flock <subcommand> […]`.
    ///
    /// `nonisolated async` (CLAUDE.md M6 async-CLI rule): `EmberweftCLI.run` is
    /// `@MainActor`, but this entry point hops OFF the MainActor so it is free to
    /// service the coordinators' `await MainActor.run { MetalRenderer.render }`
    /// hops (Metal + temporal is MainActor-only; a synchronous path that blocked
    /// the main thread would deadlock that hop). `MetalRenderer.isAvailable` is
    /// `@MainActor` and traps off-main, so it is probed via
    /// `await MainActor.run { MetalRenderer.isAvailable }` — NEVER
    /// `MainActor.assumeIsolated` (the ExportCommand.export recipe).
    nonisolated static func flock(_ args: [String]) async -> Int32 {
        guard let sub = args.first else {
            err("error: flock requires a subcommand (generate|stitch|browse|rebuild|export-list)\n")
            return 2
        }
        let rest = Array(args.dropFirst())
        switch sub {
        case "generate":    return await generate(rest)
        case "stitch":      return await stitch(rest)
        case "browse":      return await browse(rest)
        case "rebuild":     return await rebuild(rest)
        case "export-list": return await exportList(rest)
        default:
            err("error: unknown flock subcommand: \(sub)\n")
            return 2
        }
    }

    // MARK: - generate (Path A — drive GenerateCoordinator)

    /// `flock generate --shard <name> --from <dir|flam3>`.
    ///
    /// Enumerates loop + edge units from `--from` (each `.flam3` is a loop;
    /// consecutive files form an edge), builds a `ShardSpec` + `ExportSettings`,
    /// and streams the `GenerateCoordinator` progress (skip/render). Hit-skip and
    /// upgrade-overwrite live inside the coordinator (T10).
    private nonisolated static func generate(_ args: [String]) async -> Int32 {
        var shardName: String? = nil
        var from: String? = nil
        var scope = "edges"
        var quality = "genome"
        var codec = "hevc"
        var temporalSamples = 1
        var backend = "cpu"
        var flockRoot = defaultFlockRoot().path
        var i = 0
        while i < args.count {
            let tok = args[i]
            guard tok.hasPrefix("-") else { err("error: unexpected argument: \(tok)\n"); return 2 }
            func value() -> String? { i + 1 < args.count ? args[i + 1] : nil }
            func missing(_ flag: String) -> Int32 { err("error: \(flag) requires a value\n"); return 2 }
            switch tok {
            case "--shard":  guard let v = value() else { return missing("--shard") }; shardName = v; i += 2
            case "--from":   guard let v = value() else { return missing("--from") }; from = v; i += 2
            case "--scope":
                guard let v = value() else { return missing("--scope") }
                let lv = v.lowercased()
                guard lv == "edges" || lv == "loops" || lv == "both"
                else { err("error: --scope must be edges|loops|both\n"); return 2 }
                scope = lv; i += 2
            case "--quality":      guard let v = value() else { return missing("--quality") }; quality = v; i += 2
            case "--codec":
                guard let v = value() else { return missing("--codec") }
                guard Self.normalizeCodec(v) != nil else { err("error: --codec must be h264|hevc|prores-422-hq\n"); return 2 }
                codec = v.lowercased(); i += 2
            case "--temporal-samples":
                guard let v = value() else { return missing("--temporal-samples") }
                temporalSamples = max(1, Int(v) ?? 1); i += 2
            case "--backend":
                guard let v = value() else { return missing("--backend") }
                let lv = v.lowercased()
                guard lv == "cpu" || lv == "metal" else { err("error: --backend must be cpu|metal\n"); return 2 }
                backend = lv; i += 2
            case "--flock":  guard let v = value() else { return missing("--flock") }; flockRoot = v; i += 2
            default: err("error: unknown flag: \(tok)\n"); return 2
            }
        }
        guard let shardName else { err("error: flock generate requires --shard\n"); return 2 }
        guard let from else { err("error: flock generate requires --from\n"); return 2 }

        // Resolve backend (probe Metal via MainActor.run; .isAvailable traps off-main).
        let coordBackend = await Self.resolveBackend(backend)
        guard let coordBackend else { return 1 }   // strict-unavailable surfaced with a notice

        // Parse the shard name → ShardSpec (WxH_fps[_Lf-Tf]); parse codec enum.
        guard let shard = parseShardSpec(name: shardName, codec: codec) else {
            err("error: --shard \(shardName) is not a valid shard name (expected WxH_fps[_Lf<loop>-Tf<trans>])\n")
            return 2
        }

        // Enumerate loop+edge units + the renderable base flame for settings.
        let flockURL = URL(fileURLWithPath: flockRoot)
        let cat: FlockCatalog
        do { cat = try FlockCatalog(root: flockURL) } catch {
            err("error: cannot open flock catalog at \(flockRoot): \(error)\n"); return 1
        }
        try? FileManager.default.createDirectory(at: flockURL, withIntermediateDirectories: true)
        let units: [GenerateUnit]
        do { units = try await enumerateUnits(from: from, catalog: cat) } catch {
            err("error: cannot enumerate --from \(from): \(error)\n"); return 1
        }
        guard !units.isEmpty else { err("error: no .flam3 genomes found under --from \(from)\n"); return 1 }
        let baseFlame = units.first(where: { $0.A.isRenderable })?.A ?? units[0].A

        // Resolve ExportSettings via the shared pure resolver (motion-blur fallback
        // + Metal ts cap + smoothing). Archive path: .mov container, shard WxH,
        // smoothing OFF (byte-sharp mastering — matches the archive tests).
        let settings = Self.resolveArchiveSettings(
            quality: quality, codec: codec, shard: shard,
            temporalSamples: temporalSamples, baseFlame: baseFlame, backend: coordBackend)
        guard let settings else { return 2 }   // parse error already printed

        // HEVC availability probe (mirror ExportCommand: explicit hevc on a host
        // without HEVC encode → exit 1; no silent fallback for the archive).
        if settings.codec == .hevc && !VideoEncoder.canEncode(.hevc) {
            err("error: HEVC (H.265) encode is not available on this host; use --codec h264\n")
            return 1
        }

        // Upsert the shard row (GenerateCoordinator upserts artifacts, not shards).
        do { try await cat.upsertShard(shard) } catch {
            err("error: cannot record shard \(shardName): \(error)\n"); return 1
        }

        let scopeEnum: GenerateScope
        switch scope { case "loops": scopeEnum = .loops; case "both": scopeEnum = .both; default: scopeEnum = .edges }
        let request = GenerateRequest(shard: shard, units: units, scope: scopeEnum,
                                      settings: settings, flockRoot: flockURL)
        let coord = ExportCoordinator(backend: coordBackend)
        let gen = GenerateCoordinator(catalog: cat, renderer: ArchiveRenderer(),
                                      backend: coordBackend, useOffMainMetal: false)

        // SIGINT → cooperative cancel (DispatchSourceSignal — async-signal-safe;
        // the handler runs on a dispatch queue, not the signal context. Mirrors
        // ExportCommand.swift's proven pattern. The cancel flag is checked between
        // units; the plan file persists completions for resume.)
        signal(SIGINT, SIG_IGN)
        let sig = DispatchSource.makeSignalSource(signal: SIGINT)
        sig.setEventHandler { Task { await gen.cancel() } }
        sig.resume()

        out("flock generate: shard=\(shardName) scope=\(scope) units=\(units.count) backend=\(backend)\n")
        do {
            let stream = await gen.generate(request, coordinator: coord)
            for try await p in stream {
                switch p {
                case .resolving: out("flock generate: resolving…\n")
                case .running(let skip, let render, let total):
                    out("flock generate: skip=\(skip) render=\(render) / \(total)\n")
                case .completed(let rendered, let skipped):
                    out("flock generate: complete (rendered=\(rendered), skipped=\(skipped))\n")
                case .failed(let msg):
                    sig.cancel(); err("error: generate failed: \(msg)\n"); return 1
                case .cancelled:
                    out("flock generate: cancelled (plan kept for resume)\n")
                }
            }
            sig.cancel()
            return 0
        } catch {
            sig.cancel()
            err("error: generate failed: \(error)\n")
            return 1
        }
    }

    // MARK: - stitch (Path B — drive StitchCoordinator)

    /// `flock stitch --shard <name> --sequence <dir|flam3>`.
    ///
    /// Assembles a long-form video from the archive: one batched catalog lookup
    /// resolves every segment's HIT/MISS, MISSes are rendered into the archive
    /// first, then same-codec passthrough concat (no re-encode). Prints the
    /// HIT/will-gen plan then per-segment progress (T11).
    private nonisolated static func stitch(_ args: [String]) async -> Int32 {
        var shardName: String? = nil
        var sequence: String? = nil
        var outPath: String? = nil
        var quality = "genome"
        var codec = "hevc"
        var temporalSamples = 1
        var backend = "cpu"
        var flockRoot = defaultFlockRoot().path
        var i = 0
        while i < args.count {
            let tok = args[i]
            guard tok.hasPrefix("-") else { err("error: unexpected argument: \(tok)\n"); return 2 }
            func value() -> String? { i + 1 < args.count ? args[i + 1] : nil }
            func missing(_ flag: String) -> Int32 { err("error: \(flag) requires a value\n"); return 2 }
            switch tok {
            case "--shard":     guard let v = value() else { return missing("--shard") }; shardName = v; i += 2
            case "--sequence":  guard let v = value() else { return missing("--sequence") }; sequence = v; i += 2
            case "--out":       guard let v = value() else { return missing("--out") }; outPath = v; i += 2
            case "--quality":   guard let v = value() else { return missing("--quality") }; quality = v; i += 2
            case "--codec":
                guard let v = value() else { return missing("--codec") }
                guard Self.normalizeCodec(v) != nil else { err("error: --codec must be h264|hevc|prores-422-hq\n"); return 2 }
                codec = v.lowercased(); i += 2
            case "--temporal-samples":
                guard let v = value() else { return missing("--temporal-samples") }
                temporalSamples = max(1, Int(v) ?? 1); i += 2
            case "--backend":
                guard let v = value() else { return missing("--backend") }
                let lv = v.lowercased()
                guard lv == "cpu" || lv == "metal" else { err("error: --backend must be cpu|metal\n"); return 2 }
                backend = lv; i += 2
            case "--flock":  guard let v = value() else { return missing("--flock") }; flockRoot = v; i += 2
            default: err("error: unknown flag: \(tok)\n"); return 2
            }
        }
        guard let shardName else { err("error: flock stitch requires --shard\n"); return 2 }
        guard let sequence else { err("error: flock stitch requires --sequence\n"); return 2 }

        let coordBackend = await Self.resolveBackend(backend)
        guard let coordBackend else { return 1 }
        guard let shard = parseShardSpec(name: shardName, codec: codec) else {
            err("error: --shard \(shardName) is not a valid shard name\n"); return 2
        }
        let flockURL = URL(fileURLWithPath: flockRoot)
        let cat: FlockCatalog
        do { cat = try FlockCatalog(root: flockURL) } catch {
            err("error: cannot open flock catalog at \(flockRoot): \(error)\n"); return 1
        }

        // orderedFlames drives the alternating loop/edge timeline.
        let ordered: [(gen: String, id: String, flame: Flame)]
        do { ordered = try await enumerateFlames(from: sequence, catalog: cat) } catch {
            err("error: cannot enumerate --sequence \(sequence): \(error)\n"); return 1
        }
        guard !ordered.isEmpty else { err("error: no .flam3 genomes found under --sequence \(sequence)\n"); return 1 }
        let baseFlame = ordered.first(where: { $0.flame.isRenderable })?.flame ?? ordered[0].flame
        let settings = Self.resolveArchiveSettings(
            quality: quality, codec: codec, shard: shard,
            temporalSamples: temporalSamples, baseFlame: baseFlame, backend: coordBackend)
        guard let settings else { return 2 }
        if settings.codec == .hevc && !VideoEncoder.canEncode(.hevc) {
            err("error: HEVC (H.265) encode is not available on this host; use --codec h264\n")
            return 1
        }

        let outURL = URL(fileURLWithPath: outPath ?? defaultStitchOut(flockRoot: flockRoot, shard: shardName))
        try? FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let request = StitchRequest(shard: shard, orderedFlames: ordered,
                                    settings: settings, flockRoot: flockURL, out: outURL)
        let coord = ExportCoordinator(backend: coordBackend)
        let stitcher = StitchCoordinator(catalog: cat, renderer: ArchiveRenderer(),
                                         backend: coordBackend, useOffMainMetal: false)

        signal(SIGINT, SIG_IGN)
        let sig = DispatchSource.makeSignalSource(signal: SIGINT)
        sig.setEventHandler { Task { await stitcher.cancel() } }
        sig.resume()

        out("flock stitch: shard=\(shardName) segments=\(max(0, 2*ordered.count-1)) out=\(outURL.path)\n")
        do {
            let stream = await stitcher.stitch(request, coordinator: coord)
            for try await p in stream {
                switch p {
                case .resolving: out("flock stitch: resolving…\n")
                case .plan(let hit, let miss):
                    out("flock stitch: HIT=\(hit) will-gen=\(miss)\n")
                case .running(let hit, let generated):
                    out("flock stitch: hit=\(hit) generated=\(generated)\n")
                case .completed(let url):
                    sig.cancel(); out("flock stitch: complete → \(url.path)\n"); return 0
                case .failed(let msg):
                    sig.cancel(); err("error: stitch failed: \(msg)\n"); return 1
                case .cancelled:
                    out("flock stitch: cancelled\n")
                }
            }
            sig.cancel()
            return 0
        } catch {
            sig.cancel()
            err("error: stitch failed: \(error)\n")
            return 1
        }
    }

    // MARK: - browse

    /// `flock browse [--shard <name>]` — read-only catalog snapshot.
    private nonisolated static func browse(_ args: [String]) async -> Int32 {
        var shardName: String? = nil
        var flockRoot = defaultFlockRoot().path
        var i = 0
        while i < args.count {
            let tok = args[i]
            func value() -> String? { i + 1 < args.count ? args[i + 1] : nil }
            func missing(_ flag: String) -> Int32 { err("error: \(flag) requires a value\n"); return 2 }
            switch tok {
            case "--shard": guard let v = value() else { return missing("--shard") }; shardName = v; i += 2
            case "--flock": guard let v = value() else { return missing("--flock") }; flockRoot = v; i += 2
            default: err("error: unknown flag: \(tok)\n"); return 2
            }
        }
        let cat: FlockCatalog
        do { cat = try FlockCatalog(root: URL(fileURLWithPath: flockRoot)) } catch {
            err("error: cannot open flock catalog at \(flockRoot): \(error)\n"); return 1
        }
        let snap = await cat.snapshot()
        out("flock browse: \(snap.shardCount) \(snap.shardCount == 1 ? "shard" : "shards"), "
            + "\(snap.artifactCount) \(snap.artifactCount == 1 ? "artifact" : "artifacts")"
            + "  (\(flockRoot))\n")
        if let shardName {
            if let rows = try? await cat.artifactsIn(shard: shardName) {
                let bytes = rows.reduce(Int(0)) { $0 + $1.bytes }
                out("  shard \(shardName): \(rows.count) \(rows.count == 1 ? "artifact" : "artifacts"), "
                    + "\(Self.humanBytes(bytes))\n")
            } else {
                out("  shard \(shardName): (not found)\n")
            }
        }
        return 0
    }

    // MARK: - rebuild

    /// `flock rebuild` — reconstruct `flock.sqlite` from `<shard>/mpeg/` + tags.
    private nonisolated static func rebuild(_ args: [String]) async -> Int32 {
        var flockRoot = defaultFlockRoot().path
        var i = 0
        while i < args.count {
            let tok = args[i]
            func value() -> String? { i + 1 < args.count ? args[i + 1] : nil }
            switch tok {
            case "--flock": guard let v = value() else { err("error: --flock requires a value\n"); return 2 }; flockRoot = v; i += 2
            default: err("error: unknown flag: \(tok)\n"); return 2
            }
        }
        do {
            try await FlockCatalog.rebuild(from: URL(fileURLWithPath: flockRoot))
            out("flock rebuild: complete (\(flockRoot))\n")
            return 0
        } catch {
            err("error: rebuild failed: \(error)\n")
            return 1
        }
    }

    // MARK: - export-list

    /// `flock export-list --shard <name>` — write the ES `<list>` XML (T13).
    private nonisolated static func exportList(_ args: [String]) async -> Int32 {
        var shardName: String? = nil
        var flockRoot = defaultFlockRoot().path
        var i = 0
        while i < args.count {
            let tok = args[i]
            func value() -> String? { i + 1 < args.count ? args[i + 1] : nil }
            func missing(_ flag: String) -> Int32 { err("error: \(flag) requires a value\n"); return 2 }
            switch tok {
            case "--shard": guard let v = value() else { return missing("--shard") }; shardName = v; i += 2
            case "--flock": guard let v = value() else { return missing("--flock") }; flockRoot = v; i += 2
            default: err("error: unknown flag: \(tok)\n"); return 2
            }
        }
        guard let shardName else { err("error: flock export-list requires --shard\n"); return 2 }
        do {
            let xmlURL = try await ListXmlExporter().export(
                shard: shardName, flockRoot: URL(fileURLWithPath: flockRoot), edgesDb: nil)
            out("flock export-list: wrote \(xmlURL.path)\n")
            return 0
        } catch let e as ListXmlError {
            err("error: export-list failed: \(e)\n")
            return 1
        } catch {
            err("error: export-list failed: \(error)\n")
            return 1
        }
    }

    // MARK: - shared helpers

    /// Default flock root: `~/Library/Application Support/Emberweft/Flock/`
    /// (mirrors `AppPreferences.defaultDirectory.appendingPathComponent("Flock")`
    /// — `EmberweftCLI` cannot import `EmberweftUI`, so the formula is replicated
    /// here rather than reached across the module boundary).
    private static func defaultFlockRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Emberweft", isDirectory: true)
            .appendingPathComponent("Flock", isDirectory: true)
    }

    /// Default stitch output when `--out` is omitted: a `stitch-<shard>.mov` in
    /// the flock root (keeps the assembled video beside its source archive).
    private static func defaultStitchOut(flockRoot: String, shard: String) -> String {
        URL(fileURLWithPath: flockRoot).appendingPathComponent("stitch-\(shard).mov").path
    }

    /// Resolve + probe the backend. Probes `MetalRenderer.isAvailable` via
    /// `MainActor.run` (it is `@MainActor` and traps off-main —
    /// `MainActor.assumeIsolated` would trap here). Returns nil + prints a notice
    /// when Metal was requested but unavailable (the CLI always falls back to CPU
    /// for the archive, mirroring ExportCommand's non-strict default).
    private static func resolveBackend(_ backend: String) async -> ExportCoordinator.Backend? {
        if backend == "metal" {
            let metalOK = await MainActor.run { MetalRenderer.isAvailable }
            if metalOK { return .metal }
            err("notice: Metal unavailable; using CPU for the archive\n")
            return .cpu
        }
        return .cpu
    }

    /// Build the `ExportSettings` for one archive unit via the shared pure
    /// resolver (motion-blur genome-default fallback + Metal ts cap + smoothing
    /// resolution). Archive profile: `.mov` container, the shard's WxH, smoothing
    /// OFF (byte-sharp mastering path — matches the archive test harness + the
    /// animate↔export byte-identity invariant). Returns nil (+ prints) on a bad
    /// quality/codec string.
    static func resolveArchiveSettings(
        quality: String, codec: String, shard: ShardSpec,
        temporalSamples: Int, baseFlame: Flame, backend: ExportCoordinator.Backend
    ) -> ExportSettings? {
        guard let codecEnum = Self.normalizeCodec(codec) else {
            err("error: --codec must be h264|hevc|prores-422-hq\n"); return nil
        }
        let qualityEnum: ExportQuality = quality == "genome"
            ? .genome
            : .spp(Int(quality) ?? baseFlame.quality.samplesPerPixel)
        return ExportSettings.resolve(
            quality: qualityEnum,
            temporalSamples: temporalSamples,
            codec: codecEnum,
            container: .mov,
            fps: shard.fps,
            bitrate: .auto,
            resolution: .custom(width: shard.width, height: shard.height),
            segmentFrameBudget: 0,
            baseFlame: baseFlame,
            backend: backend,
            temporalSmoothing: .off)
    }

    /// `h264|hevc|prores-422-hq` → `ExportSettings.Codec` (accepts the dashed
    /// `prores-422-hq` and the bare `prores422hq` spellings, like ExportCommand).
    static func normalizeCodec(_ raw: String) -> ExportSettings.Codec? {
        let lv = raw.lowercased()
        switch lv {
        case "h264": return .h264
        case "hevc": return .hevc
        case "prores-422-hq", "prores422hq": return .proRes422HQ
        default: return nil
        }
    }

    /// Parse a shard directory name (`WxH_fps` canonical, or
    /// `WxH_fps_Lf<loop>-Tf<trans>` non-canonical) into a `ShardSpec`. Mirrors
    /// `FlockCatalog.parseShardName` (which is `internal` to FlameFlock and so
    /// unreachable from this module). Canonical pace = 15 s loops / 12 s trans.
    static func parseShardSpec(name: String, codec: String) -> ShardSpec? {
        guard let codecEnum = normalizeCodec(codec) else { return nil }
        let parts = name.split(separator: "_", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return nil }
        let res = parts[0].split(separator: "x", omittingEmptySubsequences: true).map(String.init)
        guard res.count == 2, let w = Int(res[0]), let h = Int(res[1]), w > 0, h > 0 else { return nil }
        let fpsStr = parts[1]
        guard fpsStr.hasSuffix("fps"), let fps = Int(fpsStr.dropLast(3)), fps > 0 else { return nil }
        let canonicalLoop = Int((15.0 * Double(fps)).rounded())
        let canonicalTrans = Int((12.0 * Double(fps)).rounded())
        if parts.count == 2 {
            return ShardSpec(name: name, width: w, height: h, fps: fps,
                             loopSeconds: 15.0, transSeconds: 12.0,
                             loopFrames: canonicalLoop, transFrames: canonicalTrans,
                             isCanonical: true, codec: codecEnum)
        }
        guard parts.count == 3, parts[2].hasPrefix("Lf") else { return nil }
        let body = String(parts[2].dropFirst(2))   // "<loop>-Tf<trans>"
        let chunks = body.split(separator: "-", omittingEmptySubsequences: true).map(String.init)
        guard chunks.count == 2, chunks[1].hasPrefix("Tf"),
              let lf = Int(chunks[0]), let tf = Int(chunks[1].dropFirst(2)),
              lf > 0, tf > 0 else { return nil }
        return ShardSpec(name: name, width: w, height: h, fps: fps,
                         loopSeconds: Double(lf) / Double(fps),
                         transSeconds: Double(tf) / Double(fps),
                         loopFrames: lf, transFrames: tf,
                         isCanonical: false, codec: codecEnum)
    }

    /// Enumerate `(gen, id, flame)` from a `.flam3` path or a directory of them
    /// (sorted by filename — rule #2; no Dict/Set iteration). ES-named files
    /// (`electricsheep.<gen>.<id>.flam3`) pass through their real `(gen,id)`;
    /// everything else is minted into reserved flock `900000` via `IdMinter`
    /// (deduped on SHA-256 of the source bytes — idempotent + deterministic).
    private static func enumerateFlames(
        from path: String, catalog: FlockCatalog
    ) async throws -> [(gen: String, id: String, flame: Flame)] {
        let files = try flam3Files(at: path)
        var out: [(gen: String, id: String, flame: Flame)] = []
        out.reserveCapacity(files.count)
        for url in files {
            guard let flame = try Flam3Parser.parse(Data(contentsOf: url)).first else { continue }
            let (gen, id) = try await resolveIdentity(url: url, bytes: Data(contentsOf: url), catalog: catalog)
            out.append((gen, id, flame))
        }
        return out
    }

    /// Enumerate loop + edge `GenerateUnit`s from `--from` (one loop per flame,
    /// one edge per consecutive pair — the stitch timeline model, §4.2).
    private static func enumerateUnits(
        from path: String, catalog: FlockCatalog
    ) async throws -> [GenerateUnit] {
        let flames = try await enumerateFlames(from: path, catalog: catalog)
        var units: [GenerateUnit] = []
        units.reserveCapacity(max(0, 2 * flames.count - 1))
        for i in 0..<flames.count {
            let a = flames[i]
            units.append(GenerateUnit(aGen: a.gen, aId: a.id, bGen: a.gen, bId: a.id, A: a.flame, B: a.flame))
            if i + 1 < flames.count {
                let b = flames[i + 1]
                units.append(GenerateUnit(aGen: a.gen, aId: a.id, bGen: b.gen, bId: b.id, A: a.flame, B: b.flame))
            }
        }
        return units
    }

    /// Resolve a `.flam3` file to its stable `(gen, id)`. ES filename ⇒ ES
    /// passthrough (+ a sheep row so the catalog has the origin); otherwise mint
    /// via `IdMinter` (dedupes on the source SHA-256).
    private static func resolveIdentity(
        url: URL, bytes: Data, catalog: FlockCatalog
    ) async throws -> (gen: String, id: String) {
        let stem = url.deletingPathExtension().lastPathComponent
        // electricsheep.<gen>.<id>
        let parts = stem.split(separator: ".").map(String.init)
        if parts.count == 3, parts[0] == "electricsheep",
           parts[1].allSatisfy(\.isNumber), parts[2].allSatisfy(\.isNumber) {
            let sha = sha256Hex(bytes)
            try await catalog.upsertSheep(gen: parts[1], id: parts[2], origin: .es,
                                          sourceRef: url, sourceSha: sha, displayName: nil)
            return (parts[1], parts[2])
        }
        return try await IdMinter().resolve(catalog: catalog, esGen: nil, esId: nil,
                                             origin: .user, sourceRef: url, sourceBytes: bytes)
    }

    /// Sorted `.flam3` URLs at `path` (a directory ⇒ recursive enumeration; a
    /// single `.flam3` ⇒ itself). Sorted by absolute path for determinism.
    private static func flam3Files(at path: String) throws -> [URL] {
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            guard let urls = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)?
                .compactMap({ $0 as? URL }) else { return [] }
            return urls.filter { $0.pathExtension.lowercased() == "flam3" }.sorted(by: { $0.path < $1.path })
        }
        return url.pathExtension.lowercased() == "flam3" ? [url] : []
    }

    /// SHA-256 hex of `data` (the ES sheep `source_sha`). Pure bytes→string.
    private static func sha256Hex(_ data: Data) -> String {
        let digest = CryptoKit.SHA256.hash(data: data)
        return digest.map { String(format: "%02x", Int($0)) }.joined()
    }

    /// Human-readable byte count (e.g. "1.2 GB") for browse output.
    private static func humanBytes(_ n: Int) -> String {
        let d = Double(n)
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = d, i = 0
        while v >= 1024, i + 1 < units.count { v /= 1024; i += 1 }
        return i == 0 ? "\(n) B" : String(format: "%.1f %@", v, units[i])
    }
}
