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
        var temporalSamples = 1

        var onlyFrame: Int? = nil   // --frame N: render only global frame N (re-render specific frames; skips all others)
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
                case "--temporal-samples":
                    guard i + 1 < args.count else { err("error: --temporal-samples requires a value\n"); return 2 }
                    temporalSamples = max(1, Int(args[i + 1]) ?? 1); i += 2
                case "--frame":
                    guard i + 1 < args.count else { err("error: --frame requires a value\n"); return 2 }
                    onlyFrame = Int(args[i + 1]); i += 2
                default:
                    err("error: unknown flag: \(tok)\n"); return 2
                }
            } else {
                genomes.append(tok)
                i += 1
            }
        }

        // --- genome-count guard ---
        // A single genome renders a loop-only sequence (--segments 1, a `sheep_loop`
        // rotation). Transitions (--segments > 1) morph between two genomes, so they
        // need ≥2. This lets `emberweft animate one-sheep.flam3 --segments 1` produce
        // a single-sheep loop video directly.
        guard genomes.count >= 1 else {
            err("error: animate requires at least 1 genome; got \(genomes.count)\n")
            return 2
        }
        if segmentCount > 1 && genomes.count < 2 {
            err("error: animate --segments \(segmentCount) (transitions) needs at least 2 genomes; got \(genomes.count). Pass --segments 1 for a single-sheep loop.\n")
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

        // --- Temporal samples (motion blur): default to the genome's value on CPU
        // (offline cost is OK — "slow meditative production"); cap on Metal to
        // bound dispatch overhead. All real ES genomes share the same temporal
        // params, so `baseFlame` (= flames[0]) is representative.
        if temporalSamples == 1 && baseFlame.quality.temporalSamples > 1 {
            temporalSamples = baseFlame.quality.temporalSamples
        }
        let metalTemporalCap = 64
        if backend == "metal" && temporalSamples > metalTemporalCap {
            err("note: --temporal-samples \(temporalSamples) capped to \(metalTemporalCap) on Metal (dispatch-overhead bound); use --backend cpu for the full genome value\n")
            temporalSamples = metalTemporalCap
        }

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

        // Freeze parsed options as `let`s for @Sendable closure capture inside
        // the per-frame `blendAt` (the originals stay `var` for parse-time /
        // load-time mutation; they are never mutated past this point).
        let flamesConst = flames
        let staggerConst = stagger
        let loopCyclesConst = loopCycles

        // Build the frame plan + render params once (outside the loop). The plan
        // pre-materializes the segment walk and exposes a pure O(1) `descriptor`
        // per frame — byte-identical to the prior per-frame construction (same
        // Schedule arithmetic, same TemporalFilter samples with the load-bearing
        // frame→blend delta scaling, same Loop/Transition blend semantics
        // including the loop-unclamped / transition-clamped boundary handling and
        // the no-offline-short-circuit rule; see FramePlan.swift for the rationale
        // comments that previously lived here).
        let plan = FramePlan(schedule: &schedule, segmentCount: segmentCount, flames: flamesConst,
                             loopCycles: loopCyclesConst, stagger: staggerConst,
                             temporalSamples: temporalSamples)
        let params = RenderParams(
            seed: seed, width: width, height: height,
            oversample: 1, samplesPerPixel: renderQuality
        )

        for globalFrame in 0..<totalFrames {
            // --frame N: render only the requested global frame (re-render specific
            // frames after a fix — e.g. to patch a corrected boundary frame into an
            // existing sequence). Skip everything else: no render, no PNG, no manifest row.
            if let onlyFrame, onlyFrame >= 0, globalFrame != onlyFrame { continue }
            let d = plan.descriptor(for: globalFrame)

            // Render on the chosen backend. N==1 takes the single-path branch
            // (byte-identical to the pre-blur path: `d.blendAt(d.blend)` is
            // exactly the old `renderedFlame`).
            let img: RGBA8Image
            if backend == "metal" {
                // Per-frame autoreleasepool: renderFused / renderTemporalFused
                // create autoreleased Metal objects (command buffer + compute
                // encoders) each call. This tight @MainActor loop never spins the
                // run loop, so without a per-frame pool those objects accumulate
                // across the whole sequence → driver resource growth → a
                // progressive per-frame slowdown (observed 18→30 s/frame and
                // worsening). The pool drains them at each frame boundary. (CPU
                // path is pure value types — no autorelease needed.) `animate(_:)`
                // is a static function with no `self` capture, so the
                // MainActor.assumeIsolated wrap is safe (CLAUDE.md's warning is
                // about @MainActor TEST methods capturing self).
                img = MainActor.assumeIsolated {
                    autoreleasepool {
                        temporalSamples > 1
                            ? MetalRenderer.render(blendAt: d.blendAt, centerTime: d.blend,
                                                   temporal: d.temporal, sumfilt: d.sumfilt, params: params)
                            : MetalRenderer.render(flame: d.blendAt(d.blend), params: params)
                    }
                }
            } else {
                img = temporalSamples > 1
                    ? ReferenceRenderer.render(blendAt: d.blendAt, centerTime: d.blend,
                                               temporal: d.temporal, sumfilt: d.sumfilt, params: params)
                    : ReferenceRenderer.render(flame: d.blendAt(d.blend), params: params)
            }

            // Write PNG — zero-padded 6-digit filename.
            let pngName = String(format: "%06d.png", globalFrame)
            let pngURL = outURL.appendingPathComponent(pngName)
            do {
                try img.writePNG(to: pngURL)
            } catch {
                err("error: cannot write \(pngURL.path): \(error)\n"); return 1
            }

            // Build manifest entry (index-ordered — F1). `Manifest.FrameEntry.kind`
            // is a STRING ("loop"/"transition"); `d.kind` is `Segment.Kind`, so the
            // enum→string conversion + the per-fromSheep `interpolationType.rawValue`
            // read are preserved verbatim. `flames` (not `flamesConst`) is read
            // here, matching the original.
            let interpType: String?
            switch d.kind {
            case .loop:
                interpType = nil
            case .transition:
                interpType = flames[d.fromSheep].interpolationType.rawValue
            }
            frameEntries.append(Manifest.FrameEntry(
                index: globalFrame,
                file: pngName,
                segmentId: d.segmentId,
                kind: d.kind == .loop ? "loop" : "transition",
                fromSheep: d.fromSheep,
                toSheep: d.toSheep,
                blend: d.blend,
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

        let writtenDesc = onlyFrame.map { "frame \($0)" } ?? "\(totalFrames) frames"
        out("wrote \(writtenDesc) + manifest.json to \(outPath) (\(width)×\(height))\n")
        return 0
    }
}
