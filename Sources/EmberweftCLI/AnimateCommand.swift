import Foundation
import FlameKit
import FlameReference
import FlameRenderer

extension EmberweftCLI {

    /// `emberweft animate <a.flam3> <b.flam3> … — flags`.
    ///
    /// Renders a PNG sequence (`frames/000000.png …`) plus `frames/manifest.json`
    /// (F9 schema) by driving a `Schedule` through `Loop`/`Transition` and the
    /// chosen backend.
    ///
    /// # Arg parsing
    /// Variadic positional genome paths plus `--flag value` pairs. Every
    /// non-`-`-prefixed token is collected into `genomes`; flags consume the
    /// following token as their value.
    ///
    /// # F1 — stable emit order
    /// The `frames` array is built by iterating the global frame index
    /// `0..<totalFrames`. NEVER by iterating a Set/Dict of frames.
    ///
    /// # G2 — byte-determinism
    /// CPU is single-threaded → byte-deterministic by construction. The
    /// manifest JSON is encoded from a struct (declaration-order keys) with an
    /// index-ordered array → byte-stable across runs.
    static func animate(_ args: [String]) -> Int32 {
        // --- Parse args: variadic genomes + --flag value pairs ---
        var genomes: [String] = []
        var framesPerSegment = 8
        var segmentCount = 3
        var selectorName = "sequential"
        var seed: UInt64 = 0
        var stagger: Double = 0
        var backend = "cpu"
        var outPath = "frames"
        var libraryPath: String? = nil
        var sizeStr: String? = nil
        var quality: Int? = nil
        var rebuildCache = false
        var loopCycles = 1

        var i = 0
        while i < args.count {
            let tok = args[i]
            if tok.hasPrefix("-") {
                switch tok {
                case "--frames":
                    guard i + 1 < args.count else { err("error: --frames requires a value\n"); return 2 }
                    framesPerSegment = Int(args[i + 1]) ?? framesPerSegment; i += 2
                case "--segments":
                    guard i + 1 < args.count else { err("error: --segments requires a value\n"); return 2 }
                    segmentCount = Int(args[i + 1]) ?? segmentCount; i += 2
                case "--selector":
                    guard i + 1 < args.count else { err("error: --selector requires a value\n"); return 2 }
                    selectorName = args[i + 1].lowercased(); i += 2
                case "--seed":
                    guard i + 1 < args.count else { err("error: --seed requires a value\n"); return 2 }
                    seed = UInt64(args[i + 1]) ?? seed; i += 2
                case "--stagger":
                    guard i + 1 < args.count else { err("error: --stagger requires a value\n"); return 2 }
                    stagger = Double(args[i + 1]) ?? stagger; i += 2
                case "--backend":
                    guard i + 1 < args.count else { err("error: --backend requires a value\n"); return 2 }
                    let v = args[i + 1].lowercased()
                    guard v == "cpu" || v == "metal" else { err("error: --backend must be cpu|metal\n"); return 2 }
                    backend = v; i += 2
                case "--out":
                    guard i + 1 < args.count else { err("error: --out requires a value\n"); return 2 }
                    outPath = args[i + 1]; i += 2
                case "--library":
                    guard i + 1 < args.count else { err("error: --library requires a value\n"); return 2 }
                    libraryPath = args[i + 1]; i += 2
                case "--size":
                    guard i + 1 < args.count else { err("error: --size requires a value\n"); return 2 }
                    sizeStr = args[i + 1]; i += 2
                case "--quality":
                    guard i + 1 < args.count else { err("error: --quality requires a value\n"); return 2 }
                    quality = Int(args[i + 1]); i += 2
                case "--rebuild-cache":
                    rebuildCache = true; i += 1
                case "--loop-cycles":
                    guard i + 1 < args.count else { err("error: --loop-cycles requires a value\n"); return 2 }
                    loopCycles = max(1, Int(args[i + 1]) ?? 1); i += 2
                default:
                    err("error: unknown flag: \(tok)\n"); return 2
                }
            } else {
                genomes.append(tok)
                i += 1
            }
        }

        // --- ≥2-sheep guard ---
        guard genomes.count >= 2 else {
            err("error: animate requires at least 2 genomes (alternation needs ≥2 sheep); got \(genomes.count)\n")
            return 2
        }

        // --- Load genomes ---
        var flames: [Flame] = []
        flames.reserveCapacity(genomes.count)
        for path in genomes {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
                err("error: cannot read \(path)\n"); return 1
            }
            do {
                guard let flame = try Flam3Parser.parse(data).first else {
                    err("error: no <flame> element in \(path)\n"); return 1
                }
                flames.append(flame)
            } catch {
                err("error: failed to parse \(path): \(error)\n"); return 1
            }
        }

        // --- Resolve render dimensions / quality ---
        let baseFlame = flames[0]
        var width = baseFlame.size.x
        var height = baseFlame.size.y
        if let sizeStr {
            let parts = sizeStr.split(separator: "x").compactMap { Int($0) }
            if parts.count == 2 { width = parts[0]; height = parts[1] }
        }
        let renderQuality = quality ?? baseFlame.quality.samplesPerPixel

        // --- Build selector ---
        let selector: any PairSelector
        switch selectorName {
        case "similarity":
            let vectors: [FeatureVector]
            if let libraryPath {
                let cache = FeatureCache(libraryDir: URL(fileURLWithPath: libraryPath))
                do {
                    // --rebuild-cache → full rebuild (writes `.feature_cache/`).
                    // WITHOUT --rebuild-cache → read-only load; throws `.cacheAbsent`
                    // with a clear "run --rebuild-cache" message if absent/empty.
                    // (Task 17 AC: similarity MUST NOT silently rebuild the cache.)
                    vectors = rebuildCache ? try cache.rebuildAll() : try cache.loadForSimilararity()
                } catch {
                    err("error: feature cache failure: \(error)\n"); return 1
                }
            } else {
                // No library dir → compute FeatureVectors directly from loaded genomes.
                vectors = flames.map { FeatureVector(for: $0) }
            }
            selector = SimilarityExploration(seed: seed, featureVectors: vectors)
        default: // "sequential"
            selector = Sequential(seed: seed)
        }

        // --- Build schedule ---
        var schedule = Schedule(
            librarySize: flames.count,
            framesPerSegment: framesPerSegment,
            selector: selector,
            seed: seed
        )
        let totalFrames = schedule.totalFrames(segmentCount: segmentCount)
        guard totalFrames > 0 else {
            err("error: total frame count is 0 (segments=\(segmentCount), frames=\(framesPerSegment))\n")
            return 2
        }

        // --- Create output directory ---
        let outURL = URL(fileURLWithPath: outPath)
        do {
            try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)
        } catch {
            err("error: cannot create output directory \(outPath): \(error)\n"); return 1
        }

        // --- Backend availability check (Metal) ---
        if backend == "metal" {
            let metalOK = MainActor.assumeIsolated { MetalRenderer.isAvailable }
            guard metalOK else {
                err("error: Metal backend unavailable on this machine; use --backend cpu\n")
                return 1
            }
        }

        // --- Render loop: iterate global frame index 0..<totalFrames (F1) ---
        var frameEntries: [Manifest.FrameEntry] = []
        frameEntries.reserveCapacity(totalFrames)

        for globalFrame in 0..<totalFrames {
            let mapping = schedule.frameToBlend(globalFrame: globalFrame)
            let segment = schedule.segment(at: mapping.segmentId)

            // Dispatch Loop or Transition.
            let renderedFlame: Flame
            switch mapping.kind {
            case .loop:
                renderedFlame = Loop.blend(flames[segment.fromSheep], t: mapping.blend, cycles: loopCycles)
            case .transition:
                renderedFlame = Transition.blend(
                    flames[segment.fromSheep], flames[segment.toSheep],
                    t: mapping.blend, stagger: stagger
                )
            }

            // Render on the chosen backend.
            let params = RenderParams(
                seed: seed, width: width, height: height,
                oversample: 1, samplesPerPixel: renderQuality
            )
            let img: RGBA8Image
            if backend == "metal" {
                // Wrap each frame in an autoreleasepool: renderFused creates
                // autoreleased Metal objects (command buffer + compute encoders)
                // each call. This tight @MainActor loop never spins the run loop,
                // so without a per-frame pool those objects accumulate across the
                // whole sequence → driver resource growth → a progressive per-frame
                // slowdown (observed 18→30 s/frame and worsening). The pool drains
                // them at each frame boundary. (CPU path is pure value types — no
                // autorelease needed.)
                img = MainActor.assumeIsolated {
                    autoreleasepool { MetalRenderer.render(flame: renderedFlame, params: params) }
                }
            } else {
                img = ReferenceRenderer.render(flame: renderedFlame, params: params)
            }

            // Write PNG — zero-padded 6-digit filename.
            let pngName = String(format: "%06d.png", globalFrame)
            let pngURL = outURL.appendingPathComponent(pngName)
            do {
                try img.writePNG(to: pngURL)
            } catch {
                err("error: cannot write \(pngURL.path): \(error)\n"); return 1
            }

            // Build manifest entry (index-ordered — F1).
            let interpType: String?
            switch mapping.kind {
            case .loop:
                interpType = nil
            case .transition:
                interpType = flames[segment.fromSheep].interpolationType.rawValue
            }
            frameEntries.append(Manifest.FrameEntry(
                index: globalFrame,
                file: pngName,
                segmentId: mapping.segmentId,
                kind: mapping.kind == .loop ? "loop" : "transition",
                fromSheep: segment.fromSheep,
                toSheep: segment.toSheep,
                blend: mapping.blend,
                interpolationType: interpType
            ))
        }

        // --- Write manifest.json ---
        let manifest = Manifest(
            framesPerSegment: framesPerSegment,
            segmentCount: segmentCount,
            totalFrames: totalFrames,
            selector: selectorName,
            seed: seed,
            backend: backend,
            stagger: stagger,
            width: width,
            height: height,
            quality: renderQuality,
            frames: frameEntries
        )
        let manifestURL = outURL.appendingPathComponent("manifest.json")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(manifest)
            try data.write(to: manifestURL, options: .atomic)
        } catch {
            err("error: cannot write manifest.json: \(error)\n"); return 1
        }

        out("wrote \(totalFrames) frames + manifest.json to \(outPath) (\(width)×\(height))\n")
        return 0
    }
}
