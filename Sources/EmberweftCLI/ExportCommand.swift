import Foundation
import FlameKit
import FlameExport
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
        var out = "out.mp4", codec = "h264", container = "mp4", bitrate = "auto"
        var resolution = "1080p", fps = 30, quality = "genome"
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
                    codec = lv; i += 2
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
                    resolution = v.lowercased(); i += 2
                case "--fps":
                    guard let v = value() else { return missing("--fps") }
                    let n = Int(v) ?? -1
                    guard [24, 25, 30, 48, 50, 60].contains(n) else { EmberweftCLI.err("error: --fps must be 24/25/30/48/50/60\n"); return 2 }
                    fps = n; i += 2
                case "--quality":
                    guard let v = value() else { return missing("--quality") }
                    quality = v; i += 2
                case "--segment-frames":
                    // Parsed but unused until Task 6 wires runLongForm.
                    guard let v = value() else { return missing("--segment-frames") }
                    _ = Int(v); i += 2
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
        settings.temporalSamples = max(1, temporalSamples)
        settings.bitrate = bitrate == "auto" ? .auto : .mbps(Int(bitrate) ?? 10)
        switch resolution {
        case "720p": settings.resolution = .p720
        case "1080p": settings.resolution = .p1080
        case "1440p": settings.resolution = .p1440
        case "4k": settings.resolution = .p4k
        default: settings.resolution = .p1080
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

        // --- Build + run the job ---
        let job = ExportJob(settings: settings, flames: renderable, framesPerSegment: framesPerSegment,
                            segmentCount: segmentCount, selector: .sequential, seed: seed,
                            loopCycles: loopCycles, stagger: stagger, out: outURL)
        let coord = ExportCoordinator(backend: coordBackend)

        // SIGINT -> cooperative cancel (one-shot; the loop checks `cancelled` between frames).
        signal(SIGINT, SIG_IGN)
        let sig = DispatchSource.makeSignalSource(signal: SIGINT)
        sig.setEventHandler { Task { await coord.cancel() } }
        sig.resume()
        defer { sig.cancel() }

        do {
            let stream = await coord.run(job)
            var lastPrint = 0.0
            for try await p in stream {
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastPrint > 0.5 || p.currentFrame == p.totalFrames {
                    EmberweftCLI.err("[export] frame \(p.currentFrame)/\(p.totalFrames)  fps \(String(format: "%.1f", p.renderFPS))\n")
                    lastPrint = now
                }
            }
            return 0
        } catch {
            EmberweftCLI.err("error: export failed: \(error)\n")
            try? FileManager.default.removeItem(at: job.partialURL)
            return 1
        }
    }
}
