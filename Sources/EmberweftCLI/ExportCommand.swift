import Foundation
import FlameKit
import FlameExport
import FlameReference   // ReferenceRenderer (1-frame PNG mastering path)
import FlameRenderer   // MetalRenderer.isAvailable (probe) — @MainActor

extension EmberweftCLI {

    /// `emberweft export <a.flam3> [<b.flam3> …] [options]`.
    ///
    /// `async` because the coordinator renders Metal via `await MainActor.run`
    /// (the temporal Metal path is MainActor-only; a synchronous export that
    /// blocked the main thread would deadlock the MainActor hop) and because
    /// the Metal-availability probe is `@MainActor` (`MetalRenderer.isAvailable`
    /// calls `MainActor.assumeIsolated` and traps off the main actor, so it must
    /// be reached via `await MainActor.run { … }`).
    static func export(_ args: [String]) async -> Int32 {
        EmberweftCLI.err("note: encoded .mp4 bytes are not byte-stable across machines/OSes; frame pixels are deterministic. Use `emberweft animate` for byte-exact mastering.\n")

        // --- Parse args: variadic genomes + --flag value pairs (same shape as AnimateCommand) ---
        var genomes: [String] = []
        var framesPerSegment = 8, segmentCount = 3, loopCycles = 1, seed: UInt64 = 0
        var transitionFramesPerSegment: Int? = nil   // --transition-frames (default = framesPerSegment → uniform)
        var stagger = 0.0, temporalSamples = 1
        var backend = "cpu", strictBackend = false, force = false
        var segmentFrames = 0
        var out = "out.mp4", codec = "h264", container = "mp4", bitrate = "auto"
        var resolution = "1080p", fps = 30, quality = "genome"
        // Task 7: batch queue (`--jobs manifest.json` + `--fail-fast`).
        var jobsPath: String? = nil
        var failFast = false
        // Task 5: 1-frame PNG mastering path (`export ... --frame N --png`) and
        // explicit-only-flag tracking (so the PNG path can default to the
        // genome's native size when --resolution is not passed — the
        // byte-identity-with-animate pin, AC1).
        var onlyFrame: Int? = nil
        var png = false
        var resolutionExplicit = false
        var codecExplicit = false
        // Task 9 (M6.1): resumable-export CLI surface.
        // `--checkpoint-frames N` (0 = off → existing byte-identity run/runLongForm
        // path; >0 routes to `runResumable`, which does its own frame-count chunking
        // via `renderFramesInterleaved` and ignores `segmentFrameBudget`). When both
        // `--checkpoint-frames > 0` and `--segment-frames > 0` are passed,
        // `--checkpoint-frames` wins (see the dispatch below).
        var checkpointFrames = 0
        // Task 11 (M6.1 slice 2): `--temporal-smoothing on|off` (RECIPE flag R7).
        // `on` → `.auto` (derive α from quality via the ramp); `off` → `.off`
        // (α=1.0, byte-identical to the unsmoothed path). Default `.auto`. Like
        // the other recipe flags, it sets `anyRecipeFlagExplicit = true` so the D11
        // resume gate rejects `--resume --temporal-smoothing …` (the checkpoint's
        // stored `settings.smoothingAlpha` is authoritative on resume).
        var temporalSmoothing: TemporalSmoothing = .auto
        // M6.6 (T4): `--framing faithful|normalized`. CLI default `normalized`
        // (the product default; the TYPE default on ExportSettings stays
        // `.faithful` so animate/GUI are unchanged). RECIPE flag → sets
        // `anyRecipeFlagExplicit` so `--resume` rejects it (D11; the
        // checkpoint's stored framing is authoritative on resume).
        var framing = "normalized"
        // `--resume <out>`: read the checkpoint beside `<out>` and complete the run.
        // `--discard <out>`: delete the checkpoint + chunk temps beside `<out>`.
        // Both are standalone MODE flags (handled before genome loading); exactly
        // one of them is mutually exclusive with a normal export.
        var resumeOut: String? = nil
        var discardOut: String? = nil
        // D11: on `--resume` the checkpoint recipe is AUTHORITATIVE — passing any
        // recipe flag alongside `--resume` is an error. This flips true the first
        // time any of the 12 recipe flags is parsed, so the resume path can reject
        // the combination up front. (`--backend`, `--bitrate`, `--temporal-samples`
        // are intentionally NOT recipe flags — they don't travel in the checkpoint's
        // recipe identity the way the 12 below do, and `--backend` is meaningful on
        // resume.)
        var anyRecipeFlagExplicit = false
        var i = 0
        while i < args.count {
            let tok = args[i]
            if tok.hasPrefix("-") {
                let value: () -> String? = { i + 1 < args.count ? args[i + 1] : nil }
                let missing: (String) -> Int32 = { flag in
                    EmberweftCLI.err("error: \(flag) requires a value\n"); return 2
                }
                switch tok {
                case "--frames":
                    guard let v = value() else { return missing("--frames") }
                    framesPerSegment = Int(v) ?? framesPerSegment; anyRecipeFlagExplicit = true; i += 2
                case "--transition-frames":
                    guard let v = value() else { return missing("--transition-frames") }
                    transitionFramesPerSegment = Int(v); anyRecipeFlagExplicit = true; i += 2
                case "--segments":
                    guard let v = value() else { return missing("--segments") }
                    segmentCount = Int(v) ?? segmentCount; anyRecipeFlagExplicit = true; i += 2
                case "--seed":
                    guard let v = value() else { return missing("--seed") }
                    seed = UInt64(v) ?? seed; anyRecipeFlagExplicit = true; i += 2
                case "--stagger":
                    guard let v = value() else { return missing("--stagger") }
                    stagger = Double(v) ?? stagger; anyRecipeFlagExplicit = true; i += 2
                case "--loop-cycles":
                    guard let v = value() else { return missing("--loop-cycles") }
                    loopCycles = max(1, Int(v) ?? 1); anyRecipeFlagExplicit = true; i += 2
                case "--temporal-samples":
                    guard let v = value() else { return missing("--temporal-samples") }
                    temporalSamples = max(1, Int(v) ?? 1); i += 2
                case "--backend":
                    guard let v = value() else { return missing("--backend") }
                    let lv = v.lowercased()
                    guard lv == "cpu" || lv == "metal" else { EmberweftCLI.err("error: --backend must be cpu|metal\n"); return 2 }
                    backend = lv; i += 2
                case "--out":
                    guard let v = value() else { return missing("--out") }
                    out = v; i += 2
                case "--codec":
                    guard let v = value() else { return missing("--codec") }
                    let lv = v.lowercased()
                    // Accept both `prores-422-hq` and `prores422hq` spellings.
                    let normalized = lv == "prores-422-hq" || lv == "prores422hq" ? "prores422hq" : lv
                    guard normalized == "h264" || normalized == "hevc" || normalized == "prores422hq"
                    else { EmberweftCLI.err("error: --codec must be h264|hevc|prores-422-hq\n"); return 2 }
                    codec = normalized; codecExplicit = true; anyRecipeFlagExplicit = true; i += 2
                case "--container":
                    guard let v = value() else { return missing("--container") }
                    let lv = v.lowercased()
                    guard lv == "mp4" || lv == "mov" else { EmberweftCLI.err("error: --container must be mp4|mov\n"); return 2 }
                    container = lv; anyRecipeFlagExplicit = true; i += 2
                case "--bitrate":
                    guard let v = value() else { return missing("--bitrate") }
                    bitrate = v; i += 2
                case "--resolution":
                    guard let v = value() else { return missing("--resolution") }
                    resolution = v.lowercased(); resolutionExplicit = true; anyRecipeFlagExplicit = true; i += 2
                case "--fps":
                    guard let v = value() else { return missing("--fps") }
                    let n = Int(v) ?? -1
                    guard [24, 25, 30, 48, 50, 60].contains(n) else { EmberweftCLI.err("error: --fps must be 24/25/30/48/50/60\n"); return 2 }
                    fps = n; anyRecipeFlagExplicit = true; i += 2
                case "--quality":
                    guard let v = value() else { return missing("--quality") }
                    quality = v; anyRecipeFlagExplicit = true; i += 2
                case "--segment-frames":
                    // Task 6: chunk size in frames → settings.segmentFrameBudget.
                    // `runLongForm` dispatches when this is > 0 (else single export).
                    guard let v = value() else { return missing("--segment-frames") }
                    segmentFrames = max(0, Int(v) ?? 0); i += 2
                case "--frame":
                    // 1-frame PNG mastering path (mirrors `animate --frame N`).
                    guard let v = value() else { return missing("--frame") }
                    onlyFrame = Int(v); i += 2
                case "--png": png = true; i += 1
                case "--force": force = true; i += 1
                case "--strict-backend": strictBackend = true; i += 1
                case "--fail-fast": failFast = true; i += 1   // Task 7: batch abort-on-first-failure
                case "--jobs":
                    // Task 7: JSON manifest of per-job entries (see `--help` for
                    // the schema). Dispatches `ExportCoordinator.runBatch`.
                    guard let v = value() else { return missing("--jobs") }
                    jobsPath = v; i += 2
                case "--checkpoint-frames":
                    // Task 9 (M6.1): enable resumable chunked export. 0 = off
                    // (default; the existing `run`/`runLongForm` byte-identity
                    // path). >0 = chunk the timeline every N frames, write a
                    // checkpoint after each chunk → SIGINT keeps the checkpoint +
                    // completed chunks for `--resume`. When both this and
                    // `--segment-frames` are >0, this wins (`runResumable` does
                    // its own frame-count chunking and ignores segmentFrameBudget).
                    guard let v = value() else { return missing("--checkpoint-frames") }
                    checkpointFrames = max(0, Int(v) ?? 0); i += 2
                case "--temporal-smoothing":
                    // Task 11 (M6.1 slice 2): `on` (default) → `.auto` (α from the
                    // quality ramp); `off` → `.off` (α=1.0). RECIPE flag R7 → sets
                    // `anyRecipeFlagExplicit` so `--resume` rejects it (D11).
                    guard let v = value() else { return missing("--temporal-smoothing") }
                    temporalSmoothing = (v.lowercased() == "off") ? .off : .auto
                    anyRecipeFlagExplicit = true; i += 2
                case "--framing":
                    guard let v = value() else { return missing("--framing") }
                    guard v == "faithful" || v == "normalized" else {
                        EmberweftCLI.err("error: --framing must be faithful|normalized\n"); return 2
                    }
                    framing = v
                    anyRecipeFlagExplicit = true; i += 2
                case "--resume":
                    // Task 9 (M6.1): complete a previously-checkpointed run beside
                    // `<out>`. The checkpoint's recipe is AUTHORITATIVE (D11) — no
                    // recipe flags may accompany this. Handled as a standalone mode
                    // below (before genome loading). `--backend` IS allowed (it is
                    // not a recipe flag and the checkpoint does not record it).
                    guard let v = value() else { return missing("--resume") }
                    resumeOut = v; i += 2
                case "--discard":
                    // Task 9 (M6.1): delete the checkpoint + chunk temps beside
                    // `<out>` (idempotent; exit 0). Use to clear a paused/abandoned
                    // resumable run without completing it.
                    guard let v = value() else { return missing("--discard") }
                    discardOut = v; i += 2
                default:
                    EmberweftCLI.err("error: unknown flag: \(tok)\n"); return 2
                }
            } else {
                genomes.append(tok); i += 1
            }
        }

        // --- Task 9 (M6.1): `--discard <out>` standalone mode ---
        // Idempotent: delete the checkpoint + ALL chunk temps beside `<out>`. The
        // container is read from the checkpoint if present (so the chunk-prefix
        // sweep matches what was actually written); else inferred from `<out>`'s
        // extension. Exit 0 whether or not anything was present. Handled before
        // genome loading — `--discard` takes no genomes.
        if let discardOut {
            let outURL = URL(fileURLWithPath: discardOut)
            let cpURL = ExportCheckpoint.checkpointURL(out: outURL)
            var container: ExportSettings.Container
            if let cpData = try? Data(contentsOf: cpURL),
               let decoded = try? JSONDecoder().decode(ExportCheckpoint.self, from: cpData) {
                container = decoded.settings.container
            } else {
                container = outURL.pathExtension.lowercased() == "mov" ? .mov : .mp4
            }
            ExportCoordinator.discardCheckpointAndChunks(out: outURL, container: container)
            EmberweftCLI.out("discarded checkpoint + chunks for \(discardOut)\n")
            return 0
        }

        // --- Task 9 (M6.1): `--resume <out>` standalone mode ---
        // Read the checkpoint beside `<out>` and complete the run. The checkpoint
        // recipe is AUTHORITATIVE (D11): no recipe flags may accompany `--resume`.
        // The coordinator rebuilds the ExportJob from the decoded checkpoint
        // (`runResumableBody` shadows the passed `job` from `decoded` before any
        // flame access), so the passed job's flames are never read — `[Flame()]`
        // is a type-system placeholder. SIGINT keeps the checkpoint (P2/P3: the
        // catch below removes only `partialURL`, never the checkpoint or chunks).
        if let resumeOut {
            // D11: reject any recipe flag alongside --resume.
            if anyRecipeFlagExplicit {
                EmberweftCLI.err("error: do not combine --resume with recipe flags; the checkpoint is authoritative\n")
                return 2
            }
            let outURL = URL(fileURLWithPath: resumeOut)
            let cpURL = ExportCheckpoint.checkpointURL(out: outURL)
            let cpData: Data
            do {
                cpData = try Data(contentsOf: cpURL)
            } catch {
                EmberweftCLI.err("error: no checkpoint beside \(resumeOut) (looked for \(cpURL.lastPathComponent)). Start a resumable run with `emberweft export <genome>… --checkpoint-frames N --out <out>`, or clear with `--discard \(resumeOut)`.\n")
                return 2
            }
            let decoded: ExportCheckpoint
            do {
                decoded = try JSONDecoder().decode(ExportCheckpoint.self, from: cpData)
            } catch {
                EmberweftCLI.err("error: checkpoint beside \(resumeOut) is unreadable (\(error)). Clear with `emberweft export --discard \(resumeOut)` and start fresh.\n")
                return 2
            }
            // The checkpoint's stored `out` must match the --resume arg. Compare
            // standardized absolute paths (a relative `--resume ./x.mov` resolves
            // to the same absolute path as the stored `out`).
            guard outURL.standardizedFileURL.path == decoded.out.standardizedFileURL.path else {
                EmberweftCLI.err("error: checkpoint's stored out (\(decoded.out.path)) does not match --resume \(resumeOut)\n")
                return 2
            }
            // Backend is NOT a recipe flag (the checkpoint does not record it);
            // `--backend` is honored on resume, defaulting to cpu.
            let metalAvailable = backend == "metal"
                ? await MainActor.run { MetalRenderer.isAvailable }
                : false
            let coordBackend: FlameExport.ExportCoordinator.Backend
            if backend == "metal" {
                if metalAvailable {
                    coordBackend = .metal
                } else if strictBackend {
                    EmberweftCLI.err("error: Metal unavailable and --strict-backend set\n"); return 1
                } else {
                    EmberweftCLI.err("notice: Metal unavailable; resuming on CPU (--strict-backend to refuse)\n")
                    coordBackend = .cpu
                }
            } else {
                coordBackend = .cpu
            }
            // Placeholder job: the coordinator rebuilds this from `decoded` on
            // resume (sources are re-parsed + SHA-256-verified from the
            // checkpoint). `out`/recipe come from the checkpoint; flames are not
            // read by the resume path.
            let placeholderJob = ExportJob(
                settings: decoded.settings, flames: [Flame()],
                framesPerSegment: decoded.framesPerSegment,
                transitionFramesPerSegment: decoded.transitionFramesPerSegment,
                segmentCount: decoded.segmentCount, selector: decoded.selector,
                seed: decoded.seed, loopCycles: decoded.loopCycles, stagger: decoded.stagger,
                out: decoded.out)
            let coord = ExportCoordinator(backend: coordBackend)

            // P2: SIGINT → cooperative cancel (reuse the proven DispatchSource
            // pattern VERBATIM; the handler runs on a dispatch queue, NOT in the
            // signal context — async-signal-safe). The handler's `coord.cancel()`
            // flips the actor flag; `runResumableBody` throws `.cancelled` at the
            // next chunk-top check.
            signal(SIGINT, SIG_IGN)
            let sig = DispatchSource.makeSignalSource(signal: SIGINT)
            sig.setEventHandler { Task { await coord.cancel() } }
            sig.resume()
            defer { sig.cancel() }

            do {
                let stream = await coord.runResumable(placeholderJob, sources: [],
                                                      checkpointIntervalFrames: decoded.checkpointIntervalFrames,
                                                      resumeFrom: cpURL)
                var lastPrint = 0.0
                for try await p in stream {
                    let now = ProcessInfo.processInfo.systemUptime
                    if now - lastPrint > 0.5 || p.currentFrame == p.totalFrames {
                        if p.phase == .concatenating {
                            EmberweftCLI.err("[resume] concatenating chunks…\n")
                        } else {
                            EmberweftCLI.err("[resume] frame \(p.currentFrame)/\(p.totalFrames)  fps \(String(format: "%.1f", p.renderFPS))\n")
                        }
                        lastPrint = now
                    }
                }
                EmberweftCLI.out("resume complete: \(resumeOut)\n")
                return 0
            } catch ExportError.cancelled {
                // P3: keep the checkpoint + completed chunks for `--resume`. Remove
                // only the concat partial (harmless if absent). The coordinator has
                // already removed the in-flight chunk temp.
                EmberweftCLI.err("cancelled (checkpoint + completed chunks kept for --resume)\n")
                try? FileManager.default.removeItem(at: placeholderJob.partialURL)
                return 1
            } catch ExportError.paused {
                // No CLI pause trigger exists, but guard anyway: keep the checkpoint.
                EmberweftCLI.err("paused (checkpoint kept for --resume)\n")
                return 1
            } catch {
                EmberweftCLI.err("error: resume failed: \(error)\n")
                try? FileManager.default.removeItem(at: placeholderJob.partialURL)
                return 1
            }
        }

        // --- Task 7: batch dispatch (`--jobs manifest.json`) ---
        // Branch BEFORE the single-path genome guard: a batch manifest carries
        // its own per-job genomes, so the top-level genome list is typically
        // empty. Encoder settings (codec/res/fps/quality/container/bitrate) are
        // resolved once from the top-level flags and applied batch-wide; each
        // manifest entry supplies its own genome + sanitized `out` + optional
        // render-identity overrides. Exit code: `failures.isEmpty ? 0 : 1`.
        if let jobsPath {
            return await runBatchExport(
                manifestPath: jobsPath, baseOut: out, codec: codec, container: container,
                fps: fps, quality: quality, temporalSamples: temporalSamples, bitrate: bitrate,
                resolution: resolution, segmentFrames: segmentFrames, framesPerSegment: framesPerSegment,
                transitionFramesPerSegment: transitionFramesPerSegment,
                segmentCount: segmentCount, seed: seed, loopCycles: loopCycles, stagger: stagger,
                backend: backend, strictBackend: strictBackend, force: force, failFast: failFast,
                framing: framing)
        }

        // --- genome-count guard (mirrors AnimateCommand) ---
        guard !genomes.isEmpty else {
            EmberweftCLI.err("error: export requires at least 1 genome; got \(genomes.count)\n"); return 2
        }
        if segmentCount > 1 && genomes.count < 2 {
            EmberweftCLI.err("error: export --segments \(segmentCount) (transitions) needs at least 2 genomes; got \(genomes.count). Pass --segments 1 for a single-sheep loop.\n")
            return 2
        }

        // --- Load + health-gate genomes (isRenderable lives in FlameKit) ---
        // `flamePaths` is kept aligned with `flames` (one appended per successful
        // parse; a parse failure returns early) so the resumable path can build
        // file-backed checkpoint `Source`s whose `fileURL` matches each renderable
        // flame's origin (the URL+SHA-256 path mirrors the GUI; the coordinator's
        // `finalizeFreshSources` fills the hash).
        var flames: [Flame] = []
        var flamePaths: [String] = []
        flames.reserveCapacity(genomes.count)
        for path in genomes {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
                EmberweftCLI.err("error: cannot read \(path)\n"); return 1
            }
            do {
                guard let flame = try Flam3Parser.parse(data).first else {
                    EmberweftCLI.err("error: no <flame> element in \(path)\n"); return 1
                }
                flames.append(flame); flamePaths.append(path)
            } catch {
                EmberweftCLI.err("error: failed to parse \(path): \(error)\n"); return 1
            }
        }
        var renderable: [Flame] = []
        var renderablePaths: [String] = []
        for (f, p) in zip(flames, flamePaths) where f.isRenderable {
            renderable.append(f); renderablePaths.append(p)
        }
        if renderable.isEmpty {
            EmberweftCLI.err("error: no renderable genomes (NaN/degenerate camera or all-zero xform weight)\n"); return 1
        }
        if renderable.count < flames.count {
            EmberweftCLI.err("notice: skipped \(flames.count - renderable.count) degenerate genome(s)\n")
        }

        // --- Resolve ExportSettings ---
        var settings = Self.resolveExportSettings(
            codec: codec, container: container, fps: fps, quality: quality,
            temporalSamples: temporalSamples, bitrate: bitrate, resolution: resolution,
            segmentFrames: segmentFrames, renderable: renderable, fallbackFlame: flames[0], backend: backend,
            temporalSmoothing: temporalSmoothing,
            framing: framing)

        // --- HEVC availability probe + fallback (Task 5 AC3) ---
        // H.264 is universally available on the target, so we only probe when
        // the resolved codec is HEVC. If the host can't encode HEVC:
        //   - explicit `--codec hevc` → exit 1 (the user asked for it by name)
        //   - default codec (only reachable if a future default flips to HEVC)
        //     → fall back to H.264 with a stderr notice
        if settings.codec == .hevc && !VideoEncoder.canEncode(.hevc) {
            if codecExplicit {
                EmberweftCLI.err("error: HEVC (H.265) encode is not available on this host; use --codec h264\n")
                return 1
            }
            EmberweftCLI.err("notice: HEVC encode unavailable on this host; falling back to H.264\n")
            settings.codec = .h264
        }

        // --- ProRes: .mov container requirement + availability probe ---
        // ProRes 422 HQ requires a `.mov` container (AVAssetWriter rejects it in
        // `.mp4`). Validate up front with a clear error rather than failing deep
        // in the encoder. ProRes is reached only via explicit `--codec prores-422-hq`
        // (the GUI defaults to it, but the CLI default is h264), so an encode
        // failure is a hard exit 1 (no fallback) — the user asked for it by name.
        if settings.codec == .proRes422HQ {
            if settings.container != .mov {
                EmberweftCLI.err("error: ProRes 422 HQ requires --container mov (AVAssetWriter rejects ProRes in .mp4)\n")
                return 2
            }
            if !VideoEncoder.canEncode(.proRes422HQ) {
                EmberweftCLI.err("error: ProRes 422 HQ encode is not available on this host; use --codec h264 or --codec hevc\n")
                return 1
            }
        }

        // --- Destination overwrite guard (D13) ---
        let outURL = URL(fileURLWithPath: out)
        if FileManager.default.fileExists(atPath: out) && !force {
            EmberweftCLI.err("error: \(out) exists (use --force to overwrite)\n"); return 2
        }

        // --- Backend availability (probe via MainActor.run; MetalRenderer.isAvailable traps off-main) ---
        let metalAvailable = backend == "metal"
            ? await MainActor.run { MetalRenderer.isAvailable }
            : false
        let coordBackend: FlameExport.ExportCoordinator.Backend
        if backend == "metal" {
            if metalAvailable {
                coordBackend = .metal
            } else if strictBackend {
                EmberweftCLI.err("error: Metal unavailable and --strict-backend set\n"); return 1
            } else {
                EmberweftCLI.err("notice: Metal unavailable; falling back to CPU (--strict-backend to refuse)\n")
                coordBackend = .cpu
            }
        } else {
            coordBackend = .cpu
        }

        // --- 1-frame PNG mastering path (Task 5 AC1) ---
        // `export ... --frame N --png` renders only global frame N to a PNG via
        // the SAME FramePlan + backend dispatch as `animate --frame N` (no
        // VideoEncoder, no coordinator). This is the cross-command byte-identity
        // pin: same genome/seed/size/temporal → byte-identical PNG. To honor
        // that pin at default settings, the PNG path uses the genome's native
        // size when --resolution is NOT explicitly passed (animate has no
        // --resolution flag and defaults to the genome's `size` attr). An
        // explicit --resolution still wins and overrides the genome size.
        //
        // `--frame` without `--png` is an error (the 1-frame path produces a
        // PNG by definition; a single-frame .mp4 is not a useful target and
        // would be silently ignored otherwise — minor #2 from the Task 5
        // review).
        if onlyFrame != nil && !png {
            EmberweftCLI.err("error: --frame requires --png (1-frame PNG mastering path)\n")
            return 2
        }
        if let onlyFrame, png {
            // Task 11 (M6.1 slice 2): the 1-frame PNG mastering path bypasses the
            // coordinator (no multi-frame EMA), so temporal smoothing can't apply.
            // Force `.off` defensively — guards against future refactors and makes
            // the intent explicit (P2.2). The params built below carry no smoothing
            // state either way; this is belt-and-suspenders.
            temporalSmoothing = .off
            // Genome-native size unless --resolution was explicit (byte-identity
            // with `animate`, which has no resolution tiers).
            let pw: Int, ph: Int
            if resolutionExplicit {
                pw = settings.resolution.width; ph = settings.resolution.height
            } else {
                pw = max(1, renderable[0].size.x); ph = max(1, renderable[0].size.y)
            }
            // M6.6: this path bypasses buildRenderContext, so it applies the
            // framing normalization itself. At the default (no --resolution)
            // pw == renderable[0].size.x, so the first genome's factor is 1
            // (identity) — the single-genome animate byte-identity pins hold.
            // With an explicit --resolution the factors are non-identity,
            // matching the coordinator paths exactly.
            let planFlames = settings.framing == .normalized
                ? renderable.map { Framing.normalize(flame: $0, renderWidth: pw) }
                : renderable
            var schedule = Schedule(librarySize: renderable.count, framesPerSegment: framesPerSegment,
                                    transitionFramesPerSegment: transitionFramesPerSegment,
                                    selector: Sequential(seed: seed), seed: seed)
            let plan = FramePlan(schedule: &schedule, segmentCount: segmentCount, flames: planFlames,
                                 loopCycles: loopCycles, stagger: stagger,
                                 temporalSamples: max(1, settings.temporalSamples))
            guard onlyFrame >= 0, onlyFrame < plan.totalFrames else {
                EmberweftCLI.err("error: --frame \(onlyFrame) out of range (0..\(plan.totalFrames - 1))\n")
                return 2
            }
            let d = plan.descriptor(for: onlyFrame)
            let (spp, os) = settings.quality.resolvedSamplesPerPixel(for: renderable[0])
            let params = RenderParams(seed: seed, width: pw, height: ph,
                                      oversample: os, samplesPerPixel: spp)
            let img: RGBA8Image
            switch coordBackend {
            case .metal:
                img = await MainActor.run {
                    autoreleasepool {
                        settings.temporalSamples > 1
                            ? MetalRenderer.render(blendAt: d.blendAt, centerTime: d.blend,
                                                   temporal: d.temporal, sumfilt: d.sumfilt, params: params)
                            : MetalRenderer.render(flame: d.blendAt(d.blend), params: params)
                    }
                }
            case .cpu:
                img = settings.temporalSamples > 1
                    ? ReferenceRenderer.render(blendAt: d.blendAt, centerTime: d.blend,
                                               temporal: d.temporal, sumfilt: d.sumfilt, params: params)
                    : ReferenceRenderer.render(flame: d.blendAt(d.blend), params: params)
            }
            // Ensure the parent directory exists (mirrors animate's createDirectory).
            let parent = outURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            do { try img.writePNG(to: outURL) }
            catch { EmberweftCLI.err("error: cannot write \(out): \(error)\n"); return 1 }
            EmberweftCLI.out("wrote frame \(onlyFrame) (\(pw)×\(ph)) to \(out)\n")
            return 0
        }

        // --- Build + run the job ---
        // Dispatch (priority high → low):
        //   1. `--checkpoint-frames N > 0` → resumable chunked path (Task 9,
        //      `runResumable`). When both this and `--segment-frames > 0` are
        //      passed, `--checkpoint-frames` WINS (`runResumable` does its own
        //      frame-count chunking via `renderFramesInterleaved` and ignores
        //      `segmentFrameBudget`).
        //   2. `--segment-frames N > 0` → long-form chunked path (Task 6,
        //      `runLongForm`).
        //   3. else → single-export path (`run`, today's byte-identity default).
        let job = ExportJob(settings: settings, flames: renderable, framesPerSegment: framesPerSegment,
                            transitionFramesPerSegment: transitionFramesPerSegment,
                            segmentCount: segmentCount, selector: .sequential, seed: seed,
                            loopCycles: loopCycles, stagger: stagger, out: outURL)
        let coord = ExportCoordinator(backend: coordBackend)
        let longForm = settings.segmentFrameBudget > 0
        let resumable = checkpointFrames > 0
        if resumable && longForm {
            EmberweftCLI.err("note: --checkpoint-frames \(checkpointFrames) overrides --segment-frames \(segmentFrames) (resumable chunked path)\n")
        }

        // SIGINT -> cooperative cancel (one-shot; the loop checks `cancelled` between frames).
        // P2: reused VERBATIM for the resumable path — the handler's `coord.cancel()`
        // flips the actor flag; `runResumableBody` throws `.cancelled` at the next
        // chunk-top. The `catch ExportError.cancelled` below keeps the checkpoint +
        // completed chunks (P3) for `--resume`.
        signal(SIGINT, SIG_IGN)
        let sig = DispatchSource.makeSignalSource(signal: SIGINT)
        sig.setEventHandler { Task { await coord.cancel() } }
        sig.resume()
        defer { sig.cancel() }

        do {
            let stream: AsyncThrowingStream<ExportProgress, Error>
            if resumable {
                // File-backed sources from the input genome paths (the URL+SHA-256
                // path; the coordinator's `finalizeFreshSources` fills the hash).
                // `flameIndex: 0` — the CLI takes the first `<flame>` from each
                // file. Aligned with `renderable` via `renderablePaths`.
                let sources = zip(renderable, renderablePaths).map { (_, path) in
                    ExportCheckpoint.Source(fileURL: URL(fileURLWithPath: path), flameIndex: 0,
                                            sha256: nil, serializedText: nil, displayName: path)
                }
                stream = await coord.runResumable(job, sources: sources,
                                                  checkpointIntervalFrames: checkpointFrames,
                                                  resumeFrom: nil)
            } else if longForm {
                stream = await coord.runLongForm(job)
            } else {
                stream = await coord.run(job)
            }
            var lastPrint = 0.0
            for try await p in stream {
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastPrint > 0.5 || p.currentFrame == p.totalFrames {
                    if p.phase == .concatenating {
                        EmberweftCLI.err("[export] concatenating \(segmentCount) segments…\n")
                    } else {
                        EmberweftCLI.err("[export] frame \(p.currentFrame)/\(p.totalFrames)  fps \(String(format: "%.1f", p.renderFPS))\n")
                    }
                    lastPrint = now
                }
            }
            return 0
        } catch ExportError.cancelled {
            // P3: keep the checkpoint + completed chunks for `--resume`. Remove
            // only the concat partial (harmless if absent — the resumable path
            // uses a chunk temp, cleaned by the coordinator). Long-form seg temps
            // are not checkpoint artifacts and are cleaned defensively.
            EmberweftCLI.err("cancelled\n")
            try? FileManager.default.removeItem(at: job.partialURL)
            if longForm {
                let outDir = outURL.deletingLastPathComponent()
                if let entries = try? FileManager.default.contentsOfDirectory(atPath: outDir.path) {
                    for e in entries where e.hasPrefix("m6-seg-") {
                        try? FileManager.default.removeItem(at: outDir.appendingPathComponent(e))
                    }
                }
            }
            return 1
        } catch {
            EmberweftCLI.err("error: export failed: \(error)\n")
            try? FileManager.default.removeItem(at: job.partialURL)
            // Long-form temps are cleaned by the coordinator's `defer`; the
            // partialURL (concat target) is the only stray an exception can leave.
            if longForm {
                let outDir = outURL.deletingLastPathComponent()
                if let entries = try? FileManager.default.contentsOfDirectory(atPath: outDir.path) {
                    for e in entries where e.hasPrefix("m6-seg-") {
                        try? FileManager.default.removeItem(at: outDir.appendingPathComponent(e))
                    }
                }
            }
            return 1
        }
    }

    // MARK: - Task 7 batch helpers

    /// One entry in a `--jobs` manifest JSON array. `genome` and `out` are
    /// required; the rest are optional per-job render-identity overrides (when
    /// absent, the top-level CLI value is inherited). Encoder settings
    /// (codec/res/fps/quality/container/bitrate) are batch-wide from top-level
    /// flags — keeping a batch codec-coherent is the common case, and it lets
    /// the HEVC probe + Metal probe run exactly once.
    fileprivate struct ManifestEntry: Codable {
        let genome: String
        let out: String
        let frames: Int?
        let segments: Int?
        let seed: UInt64?
        let loopCycles: Int?
        let stagger: Double?
        let temporalSamples: Int?
    }

    /// Shared `ExportSettings` resolution for the single and batch paths (Task 7
    /// extraction: the batch path needs the same codec/quality/temporal cap logic
    /// as the single path, so the two cannot drift). `renderable`/`fallbackFlame`
    /// drive the motion-blur default (genome `temporal_samples` when `--temporal-
    /// samples` is omitted) and the `--quality` fallback; for a batch with no
    /// top-level genomes, the caller passes the first manifest entry's flames.
    ///
    /// Thin caller of the shared `ExportSettings.resolve(…)` (M6-G.3): ALL
    /// string→enum parsing STAYS HERE (FlameExport cannot call
    /// `EmberweftCLI.err`, and the GUI builds enums directly from its pickers —
    /// no strings to parse). The shared resolver owns the motion-blur genome-
    /// default fallback + the Metal temporal cap (pure + silent); this wrapper
    /// detects the cap (requested vs resolved) and prints the stderr notice the
    /// original emitted. Behavior is byte-for-byte identical to the pre-refactor
    /// implementation (the 3 named existing pins — `testExportGenomeByteMatches
    /// AnimateFrame5`, `…MotionBlur`, `testTemporalSamples1IsByteIdenticalToNoFlag`
    /// — are the proof).
    static func resolveExportSettings(
        codec: String, container: String, fps: Int, quality: String,
        temporalSamples: Int, bitrate: String, resolution: String,
        segmentFrames: Int, renderable: [Flame], fallbackFlame: Flame, backend: String,
        temporalSmoothing: TemporalSmoothing = .auto,
        framing: String = "normalized"
    ) -> ExportSettings {
        // --- String → enum parsing (VERBATIM from the original; the resolver
        // takes parsed enums so this is the ONLY place strings are interpreted) ---
        let codecEnum: ExportSettings.Codec
        switch codec {
        case "hevc": codecEnum = .hevc
        case "prores422hq": codecEnum = .proRes422HQ
        default: codecEnum = .h264
        }
        let containerEnum: ExportSettings.Container = container == "mov" ? .mov : .mp4
        // The quality-number defensive fallback uses `fallbackFlame` (NOT
        // renderable[0]), matching the original line 367 verbatim.
        let qualityEnum: ExportQuality = quality == "genome"
            ? .genome
            : .spp(Int(quality) ?? fallbackFlame.quality.samplesPerPixel)
        let bitrateEnum: ExportSettings.Bitrate = bitrate == "auto" ? .auto : .mbps(Int(bitrate) ?? 10)
        let resolutionEnum: ExportSettings.Resolution
        switch resolution {
        case "720p": resolutionEnum = .p720
        case "1080p": resolutionEnum = .p1080
        case "1440p": resolutionEnum = .p1440
        case "4k": resolutionEnum = .p4k
        default: resolutionEnum = .p1080     // unknown → .p1080 (original line 390)
        }
        let backendEnum: ExportCoordinator.Backend = backend == "metal" ? .metal : .cpu

        // `baseFlame` for the motion-blur fallback = the first RENDERABLE flame
        // (the original used `renderable[0]` guarded by `!renderable.isEmpty`,
        // ExportCommand.swift:375). When `renderable` is empty (only the batch
        // path with a degenerate first entry), `Flame()` carries the Quality
        // default `temporalSamples == 1`, so the resolver's fallback condition
        // (`> 1`) fails — matching the original's `!renderable.isEmpty` guard
        // byte-for-byte.
        let baseFlame = renderable.first ?? Flame()

        // Delegate the motion-blur fallback + Metal cap to the shared pure+silent
        // resolver (single source of truth for CLI + GUI; spec §4.2b).
        var settings = ExportSettings.resolve(
            quality: qualityEnum,
            temporalSamples: temporalSamples,
            codec: codecEnum, container: containerEnum, fps: fps, bitrate: bitrateEnum,
            resolution: resolutionEnum, segmentFrameBudget: segmentFrames,
            baseFlame: baseFlame, backend: backendEnum,
            temporalSmoothing: temporalSmoothing)

        // M6.6 (T4/R1): framing is a CLI-level concern (the shared resolver has
        // no framing parameter by design — the GUI builds it from its own
        // pickers; keeping `ExportSettings.resolve`'s signature stable avoids
        // drift). The TYPE default is `.faithful`; the CLI default is
        // `normalized` (both the one-shot and batch paths route through THIS
        // wrapper, so the two can't diverge).
        settings.framing = framing == "normalized" ? .normalized : .faithful

        // --- Metal temporal cap notice (the resolver is SILENT; the CLI prints) ---
        // Mirrors the original (ExportCommand.swift:378-382) EXACTLY: the notice
        // fires iff the post-fallback, pre-cap ts > 64 on Metal. We detect the cap
        // by comparing the requested against the resolved `temporalSamples`, then
        // reconstruct the pre-cap value for the message (the value that was about
        // to be capped — what the original's `ts` variable held at line 380). The
        // `precap > metalTemporalCap` guard covers the edge case where the genome
        // fallback lands EXACTLY at the cap (e.g. genome ts == 64): the resolver
        // does NOT cap (64 is not > 64), but `requestedTS != resolved` is still
        // true (the fallback bumped it) — so we re-check the original condition
        // before printing, avoiding a spurious "capped to 64" when ts is already 64.
        if backendEnum == .metal && temporalSamples != settings.temporalSamples {
            let precap = temporalSamples > 1
                ? temporalSamples
                : baseFlame.quality.temporalSamples
            if precap > ExportSettings.metalTemporalCap {
                EmberweftCLI.err("note: --temporal-samples \(precap) capped to \(ExportSettings.metalTemporalCap) on Metal (dispatch-overhead bound); use --backend cpu for the full genome value\n")
            }
        }
        return settings
    }

    /// Resolves the batch base dir from `--out`. Per the plan: `--out` when it
    /// IS a directory (existing, or declared with a trailing `/` — created if
    /// needed); else the CWD. Manifest `out` names resolve strictly under it.
    private static func batchBaseDir(out: String) -> URL {
        let outURL = URL(fileURLWithPath: out)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: outURL.path, isDirectory: &isDir), isDir.boolValue {
            return outURL
        }
        if out.hasSuffix("/") {
            try? FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)
            return outURL
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    /// `--jobs manifest.json` dispatch. Parses the manifest, resolves batch-wide
    /// `ExportSettings` once (top-level flags + the first entry's genome for the
    /// temporal default), sanitizes each entry's `out` via `BatchPath.resolve`
    /// under the base dir, builds `[ExportJob]`, and runs them serially via
    /// `ExportCoordinator.runBatch`. Exit code: `failures.isEmpty ? 0 : 1`.
    static func runBatchExport(
        manifestPath: String, baseOut: String, codec: String, container: String,
        fps: Int, quality: String, temporalSamples: Int, bitrate: String,
        resolution: String, segmentFrames: Int, framesPerSegment: Int,
        transitionFramesPerSegment: Int?,
        segmentCount: Int, seed: UInt64, loopCycles: Int, stagger: Double,
        backend: String, strictBackend: Bool, force: Bool, failFast: Bool,
        framing: String = "normalized"
    ) async -> Int32 {
        // Load + decode the manifest.
        let manifestURL = URL(fileURLWithPath: manifestPath)
        guard let data = try? Data(contentsOf: manifestURL) else {
            EmberweftCLI.err("error: cannot read manifest \(manifestPath)\n"); return 2
        }
        let entries: [ManifestEntry]
        do {
            entries = try JSONDecoder().decode([ManifestEntry].self, from: data)
        } catch {
            EmberweftCLI.err("error: invalid manifest \(manifestPath): \(error)\n"); return 2
        }
        guard !entries.isEmpty else {
            EmberweftCLI.err("error: --jobs manifest is empty\n"); return 2
        }

        // Resolve encoder settings ONCE (batch-wide), using the first entry's
        // genome for the motion-blur default + quality fallback. Per-entry
        // `temporalSamples` overrides are applied per-job below.
        guard let firstFlame = loadFirstFlame(entries[0].genome) else { return 1 }
        let renderable0 = firstFlame.isRenderable ? [firstFlame] : []
        let settings = resolveExportSettings(
            codec: codec, container: container, fps: fps, quality: quality,
            temporalSamples: temporalSamples, bitrate: bitrate, resolution: resolution,
            segmentFrames: segmentFrames, renderable: renderable0, fallbackFlame: firstFlame, backend: backend,
            temporalSmoothing: .auto,   // batch: smoothing is batch-wide from quality; no per-entry override
            framing: framing)   // M6.6 R1: batch framing == one-shot framing (default normalized, explicit flag honored)

        // HEVC availability (probe once — codec is batch-wide).
        if settings.codec == .hevc && !VideoEncoder.canEncode(.hevc) {
            // Mirror the single path's contract: explicit `--codec hevc` on a
            // host without HEVC → exit 1. (`codec` reached here only via an
            // explicit `--codec hevc`; the default is h264.)
            EmberweftCLI.err("error: HEVC (H.265) encode is not available on this host; use --codec h264\n")
            return 1
        }

        // ProRes: .mov container + availability (probe once — codec is batch-wide).
        // Mirrors the single path's contract (clear error over a deep encoder fail).
        if settings.codec == .proRes422HQ {
            if settings.container != .mov {
                EmberweftCLI.err("error: ProRes 422 HQ requires --container mov (AVAssetWriter rejects ProRes in .mp4)\n")
                return 2
            }
            if !VideoEncoder.canEncode(.proRes422HQ) {
                EmberweftCLI.err("error: ProRes 422 HQ encode is not available on this host; use --codec h264 or --codec hevc\n")
                return 1
            }
        }

        // Backend availability (probe once via MainActor.run).
        let metalAvailable = backend == "metal"
            ? await MainActor.run { MetalRenderer.isAvailable }
            : false
        let coordBackend: FlameExport.ExportCoordinator.Backend
        if backend == "metal" {
            if metalAvailable {
                coordBackend = .metal
            } else if strictBackend {
                EmberweftCLI.err("error: Metal unavailable and --strict-backend set\n"); return 1
            } else {
                EmberweftCLI.err("notice: Metal unavailable; falling back to CPU (--strict-backend to refuse)\n")
                coordBackend = .cpu
            }
        } else {
            coordBackend = .cpu
        }

        let baseURL = batchBaseDir(out: baseOut)

        // Build per-entry jobs. Genome load + health-gate + `out` sanitization
        // happen per entry; a bad entry (unparseable genome, or an `out` that
        // fails `BatchPath.resolve`) aborts the whole batch up front (exit 2) —
        // manifest validation is a gate, not a per-job runtime failure.
        var jobs: [ExportJob] = []
        jobs.reserveCapacity(entries.count)
        for (i, e) in entries.enumerated() {
            // Per-entry genome (load + take first + health-gate inline; the
            // batch coordinator re-checks `isRenderable`, but loading +
            // surfacing a parse error here gives a precise manifest error).
            guard let flame = loadFirstFlame(e.genome) else { return 1 }
            // Sanitize `out` under the base dir (D13).
            let outURL: URL
            do {
                outURL = try BatchPath.resolve(e.out, base: baseURL)
            } catch {
                EmberweftCLI.err("error: manifest entry \(i) has illegal `out` \"\(e.out)\" (\(error)); use a bare filename matching [A-Za-z0-9._-]\n")
                return 2
            }
            // Destination overwrite guard (mirrors the single path; `--force`
            // skips it). A pre-existing `out` is a fail-stop, not a runtime skip.
            if FileManager.default.fileExists(atPath: outURL.path) && !force {
                EmberweftCLI.err("error: \(outURL.path) exists (use --force to overwrite)\n"); return 2
            }
            // Per-entry render-identity overrides; inherit the top-level value
            // when the manifest entry omits the field.
            var jobSettings = settings
            if let ts = e.temporalSamples { jobSettings.temporalSamples = max(1, ts) }
            let jobFrames = e.frames ?? framesPerSegment
            let jobSegments = e.segments ?? segmentCount
            let jobSeed = e.seed ?? seed
            let jobLoop = e.loopCycles ?? loopCycles
            let jobStagger = e.stagger ?? stagger
            jobs.append(ExportJob(settings: jobSettings, flames: [flame], framesPerSegment: jobFrames,
                                  transitionFramesPerSegment: transitionFramesPerSegment,
                                  segmentCount: jobSegments, selector: .sequential, seed: jobSeed,
                                  loopCycles: jobLoop, stagger: jobStagger, out: outURL))
        }

        EmberweftCLI.err("note: batch of \(jobs.count) job(s) → \(baseURL.path) (fail-fast=\(failFast))\n")

        let coord = ExportCoordinator(backend: coordBackend)

        // SIGINT → cooperative cancel (whole batch). The coordinator's cancel
        // stops the in-flight job (partial cleaned) AND remaining jobs.
        signal(SIGINT, SIG_IGN)
        let sig = DispatchSource.makeSignalSource(signal: SIGINT)
        sig.setEventHandler { Task { await coord.cancel() } }
        sig.resume()
        defer { sig.cancel() }

        var failures: [Int] = []
        do {
            let stream = await coord.runBatch(jobs, failFast: failFast)
            var lastPrint = 0.0
            for try await p in stream {
                if p.failed {
                    failures.append(p.jobIndex)
                    EmberweftCLI.err("[batch] job \(p.jobIndex + 1)/\(p.totalJobs) FAILED\n")
                    continue
                }
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastPrint > 0.5
                    || p.jobFrame == p.jobTotalFrames {
                    let pct = String(format: "%.0f", p.aggregateFraction * 100)
                    EmberweftCLI.err("[batch] job \(p.jobIndex + 1)/\(p.totalJobs)  frame \(p.jobFrame)/\(p.jobTotalFrames)  total \(pct)%\n")
                    lastPrint = now
                }
            }
        } catch {
            // Cancel surfaces as a thrown error (cancel scope = stop batch); a
            // mid-batch cancel is not a per-job failure, it is an out-of-band stop.
            // The in-flight job's partial was already cleaned by the coordinator;
            // exit nonzero to signal an incomplete batch.
            EmberweftCLI.err("error: batch stopped: \(error)\n")
            return 1
        }
        if failures.isEmpty {
            EmberweftCLI.out("batch complete: \(jobs.count) job(s)\n")
            return 0
        }
        EmberweftCLI.err("error: batch finished with \(failures.count) failed job(s): \(failures.map { $0 + 1 })\n")
        return 1
    }

    /// Loads the FIRST `<flame>` from a genome file (manifest entries are
    /// single-genome). Returns nil on read/parse failure (after printing the
    /// error); callers map that to the appropriate exit code.
    private static func loadFirstFlame(_ path: String) -> Flame? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            EmberweftCLI.err("error: cannot read \(path)\n"); return nil
        }
        do {
            guard let flame = try Flam3Parser.parse(data).first else {
                EmberweftCLI.err("error: no <flame> element in \(path)\n"); return nil
            }
            return flame
        } catch {
            EmberweftCLI.err("error: failed to parse \(path): \(error)\n"); return nil
        }
    }
}
