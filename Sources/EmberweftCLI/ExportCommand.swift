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
        var stagger = 0.0, temporalSamples = 1
        var backend = "cpu", strictBackend = false, force = false
        var segmentFrames = 0
        var out = "out.mp4", codec = "h264", container = "mp4", bitrate = "auto"
        var resolution = "1080p", fps = 30, quality = "genome"
        // Task 5: 1-frame PNG mastering path (`export ... --frame N --png`) and
        // explicit-only-flag tracking (so the PNG path can default to the
        // genome's native size when --resolution is not passed — the
        // byte-identity-with-animate pin, AC1).
        var onlyFrame: Int? = nil
        var png = false
        var resolutionExplicit = false
        var codecExplicit = false
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
                    framesPerSegment = Int(v) ?? framesPerSegment; i += 2
                case "--segments":
                    guard let v = value() else { return missing("--segments") }
                    segmentCount = Int(v) ?? segmentCount; i += 2
                case "--seed":
                    guard let v = value() else { return missing("--seed") }
                    seed = UInt64(v) ?? seed; i += 2
                case "--stagger":
                    guard let v = value() else { return missing("--stagger") }
                    stagger = Double(v) ?? stagger; i += 2
                case "--loop-cycles":
                    guard let v = value() else { return missing("--loop-cycles") }
                    loopCycles = max(1, Int(v) ?? 1); i += 2
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
                    guard lv == "h264" || lv == "hevc" else { EmberweftCLI.err("error: --codec must be h264|hevc\n"); return 2 }
                    codec = lv; codecExplicit = true; i += 2
                case "--container":
                    guard let v = value() else { return missing("--container") }
                    let lv = v.lowercased()
                    guard lv == "mp4" || lv == "mov" else { EmberweftCLI.err("error: --container must be mp4|mov\n"); return 2 }
                    container = lv; i += 2
                case "--bitrate":
                    guard let v = value() else { return missing("--bitrate") }
                    bitrate = v; i += 2
                case "--resolution":
                    guard let v = value() else { return missing("--resolution") }
                    resolution = v.lowercased(); resolutionExplicit = true; i += 2
                case "--fps":
                    guard let v = value() else { return missing("--fps") }
                    let n = Int(v) ?? -1
                    guard [24, 25, 30, 48, 50, 60].contains(n) else { EmberweftCLI.err("error: --fps must be 24/25/30/48/50/60\n"); return 2 }
                    fps = n; i += 2
                case "--quality":
                    guard let v = value() else { return missing("--quality") }
                    quality = v; i += 2
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
                default:
                    EmberweftCLI.err("error: unknown flag: \(tok)\n"); return 2
                }
            } else {
                genomes.append(tok); i += 1
            }
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
        var flames: [Flame] = []
        flames.reserveCapacity(genomes.count)
        for path in genomes {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
                EmberweftCLI.err("error: cannot read \(path)\n"); return 1
            }
            do {
                guard let flame = try Flam3Parser.parse(data).first else {
                    EmberweftCLI.err("error: no <flame> element in \(path)\n"); return 1
                }
                flames.append(flame)
            } catch {
                EmberweftCLI.err("error: failed to parse \(path): \(error)\n"); return 1
            }
        }
        let renderable = flames.filter { $0.isRenderable }
        if renderable.isEmpty {
            EmberweftCLI.err("error: no renderable genomes (NaN/degenerate camera or all-zero xform weight)\n"); return 1
        }
        if renderable.count < flames.count {
            EmberweftCLI.err("notice: skipped \(flames.count - renderable.count) degenerate genome(s)\n")
        }

        // --- Resolve ExportSettings ---
        var settings = ExportSettings()
        settings.codec = codec == "hevc" ? .hevc : .h264
        settings.container = container == "mov" ? .mov : .mp4
        settings.fps = fps
        settings.quality = quality == "genome" ? .genome : .spp(Int(quality) ?? flames[0].quality.samplesPerPixel)
        // Motion-blur default: mirror AnimateCommand exactly. When
        // `--temporal-samples` is omitted (== 1) and the genome carries a
        // temporal_samples > 1, use the genome's value; cap on Metal to bound
        // dispatch overhead. WITHOUT this, `export --frame N --png` renders
        // SHARP (ts=1) while `animate --frame N` renders MOTION-BLURRED (ts≈100
        // on real ES genomes) → the cross-command byte-identity pin (AC1) only
        // holds for sierpinski (which has temporal_samples=1 by parser default),
        // not for the real flock. Using `renderable[0]` (not `flames[0]`)
        // because export filters to renderable genomes; all real ES genomes
        // share the same temporal params, so [0] is representative.
        var ts = max(1, temporalSamples)
        if ts == 1, !renderable.isEmpty, renderable[0].quality.temporalSamples > 1 {
            ts = renderable[0].quality.temporalSamples
        }
        let metalTemporalCap = 64
        if backend == "metal" && ts > metalTemporalCap {
            EmberweftCLI.err("note: --temporal-samples \(ts) capped to \(metalTemporalCap) on Metal (dispatch-overhead bound); use --backend cpu for the full genome value\n")
            ts = metalTemporalCap
        }
        settings.temporalSamples = ts
        settings.bitrate = bitrate == "auto" ? .auto : .mbps(Int(bitrate) ?? 10)
        switch resolution {
        case "720p": settings.resolution = .p720
        case "1080p": settings.resolution = .p1080
        case "1440p": settings.resolution = .p1440
        case "4k": settings.resolution = .p4k
        default: settings.resolution = .p1080
        }

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
            var schedule = Schedule(librarySize: renderable.count, framesPerSegment: framesPerSegment,
                                    selector: Sequential(seed: seed), seed: seed)
            let plan = FramePlan(schedule: &schedule, segmentCount: segmentCount, flames: renderable,
                                 loopCycles: loopCycles, stagger: stagger,
                                 temporalSamples: max(1, settings.temporalSamples))
            guard onlyFrame >= 0, onlyFrame < plan.totalFrames else {
                EmberweftCLI.err("error: --frame \(onlyFrame) out of range (0..\(plan.totalFrames - 1))\n")
                return 2
            }
            let d = plan.descriptor(for: onlyFrame)
            // Genome-native size unless --resolution was explicit (byte-identity
            // with `animate`, which has no resolution tiers).
            let pw: Int, ph: Int
            if resolutionExplicit {
                pw = settings.resolution.width; ph = settings.resolution.height
            } else {
                pw = max(1, renderable[0].size.x); ph = max(1, renderable[0].size.y)
            }
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
        // Task 6: `--segment-frames N > 0` selects the long-form (chunked) path;
        // else the single-export path (today's behavior).
        settings.segmentFrameBudget = max(0, segmentFrames)
        let job = ExportJob(settings: settings, flames: renderable, framesPerSegment: framesPerSegment,
                            segmentCount: segmentCount, selector: .sequential, seed: seed,
                            loopCycles: loopCycles, stagger: stagger, out: outURL)
        let coord = ExportCoordinator(backend: coordBackend)
        let longForm = settings.segmentFrameBudget > 0

        // SIGINT -> cooperative cancel (one-shot; the loop checks `cancelled` between frames).
        signal(SIGINT, SIG_IGN)
        let sig = DispatchSource.makeSignalSource(signal: SIGINT)
        sig.setEventHandler { Task { await coord.cancel() } }
        sig.resume()
        defer { sig.cancel() }

        do {
            let stream = longForm ? await coord.runLongForm(job) : await coord.run(job)
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
}
