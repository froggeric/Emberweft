import Foundation
import FlameKit
import FlameReference
import FlameRenderer

extension EmberweftCLI {

    /// `emberweft curate [--library DIR] [--out DIR] [--size WxH] [--spp N]
    ///                     [--seed N] [--backend cpu|metal] [--sample N]
    ///                     [--top N] [--no-render]`
    ///
    /// Offline batch curation of a genome library (default: the live gen-248
    /// flock). For every `.flam3`:
    ///   1. Parse (cheap). Reject parse errors.
    ///   2. Inline renderability gate (replicates `Flame.isRenderable` from
    ///      EmberweftUI — EmberweftCLI does NOT depend on EmberweftUI): reject
    ///      non-finite camera center, non-finite / <=0 / out-of-[1e-3,4000]
    ///      scale, and zero total xform weight.
    ///   3. Render a small thumbnail (Metal preferred, CPU fallback).
    ///   4. Score the thumbnail pixels with a deterministic pleasantness
    ///      heuristic over ARRAYS (rule #2 — no float sums over Dict/Set).
    ///
    /// Emits:
    ///   - `{out}/curation-rejects.jsonl`  — one `{id,path,reason}` per reject.
    ///   - `{out}/thumbs/<id>.png`         — one thumbnail per scored genome.
    ///   - `{out}/curation-scores.json`    — sorted-desc score array.
    ///   - `{out}/top/<id>.png`            — copies of the top-N thumbnails.
    static func curate(_ args: [String]) -> Int32 {
        // --- Parse flags ---
        var libraryPath = "genomes/electric-sheep/sheep/gen-248"
        var outPath = "curation"
        var sizeStr = "256x144"
        var spp = 8
        var seed: UInt64 = 1
        var backend = "metal"
        var sampleStride: Int? = nil
        var topN = 200
        var noRender = false
        var i = 0
        while i < args.count {
            let tok = args[i]
            // Shared string-flag consume: `--flag value`, returns new index or
            // signals a missing value by clearing `i` to -1.
            func consume(_ target: inout String) -> Int {
                guard i + 1 < args.count else { err("error: \(tok) requires a value\n"); return -1 }
                target = args[i + 1]
                return i + 2
            }
            switch tok {
            case "--library": i = consume(&libraryPath); if i < 0 { return 2 }
            case "--out": i = consume(&outPath); if i < 0 { return 2 }
            case "--size": i = consume(&sizeStr); if i < 0 { return 2 }
            case "--spp":
                guard i + 1 < args.count else { err("error: --spp requires a value\n"); return 2 }
                spp = Int(args[i + 1]) ?? spp; i += 2
            case "--seed":
                guard i + 1 < args.count else { err("error: --seed requires a value\n"); return 2 }
                seed = UInt64(args[i + 1]) ?? seed; i += 2
            case "--backend":
                guard i + 1 < args.count else { err("error: --backend requires a value\n"); return 2 }
                let v = args[i + 1].lowercased()
                guard v == "cpu" || v == "metal" else { err("error: --backend must be cpu|metal\n"); return 2 }
                backend = v; i += 2
            case "--sample":
                guard i + 1 < args.count else { err("error: --sample requires a value\n"); return 2 }
                sampleStride = Int(args[i + 1]); i += 2
            case "--top":
                guard i + 1 < args.count else { err("error: --top requires a value\n"); return 2 }
                topN = Int(args[i + 1]) ?? topN; i += 2
            case "--no-render": noRender = true; i += 1
            default: err("error: unknown flag: \(tok)\n"); return 2
            }
        }

        // --- Parse size ---
        let parts = sizeStr.split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else {
            err("error: --size must be WxH\n"); return 2
        }
        let width = parts[0], height = parts[1]

        // --- Backend availability ---
        let metalOK = backend == "metal" && MainActor.assumeIsolated { MetalRenderer.isAvailable }
        let useMetal = metalOK
        if backend == "metal" && !metalOK {
            err("warning: Metal unavailable; falling back to CPU\n")
        }

        // --- Prepare output dirs ---
        let fm = FileManager.default
        let outURL = URL(fileURLWithPath: outPath)
        let thumbsDir = outURL.appendingPathComponent("thumbs", isDirectory: true)
        let topDir = outURL.appendingPathComponent("top", isDirectory: true)
        for d in [outURL, thumbsDir, topDir] {
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        let rejectsURL = outURL.appendingPathComponent("curation-rejects.jsonl")
        // Truncate any prior rejects log.
        try? Data().write(to: rejectsURL)

        // --- Enumerate .flam3 files (recursive, sorted by relative path) ---
        let libURL = URL(fileURLWithPath: libraryPath)
        guard fm.fileExists(atPath: libURL.path) else {
            err("error: library not found: \(libraryPath)\n"); return 1
        }
        let allFiles = enumerateFlam3(in: libURL)
        err("curate: \(allFiles.count) .flam3 files under \(libraryPath)\n")

        // --- Optional stride sampling by sorted-id (deterministic) ---
        let sampled: [URL]
        if let stride = sampleStride, stride > 1, stride < allFiles.count {
            sampled = Swift.stride(from: 0, to: allFiles.count, by: stride).map { allFiles[$0] }
            err("curate: --sample \(stride) → \(sampled.count) genomes\n")
        } else {
            sampled = allFiles
        }

        // --- Scan: parse + renderability gate ---
        struct Reject: Codable {
            let id: String
            let path: String
            let reason: String
        }
        struct Survivor {
            let id: String
            let path: String
            let flame: Flame
        }
        var rejects: [Reject] = []
        var survivors: [Survivor] = []
        rejects.reserveCapacity(sampled.count / 20)
        survivors.reserveCapacity(sampled.count)

        for (idx, url) in sampled.enumerated() {
            if idx % 500 == 0 { err("curate: scan \(idx)/\(sampled.count)\n") }
            let id = url.deletingPathExtension().lastPathComponent
            let rel = url.path
            let data: Data
            do { data = try Data(contentsOf: url) }
            catch {
                rejects.append(Reject(id: id, path: rel, reason: "unreadable: \(error)"))
                continue
            }
            let flame: Flame
            do {
                guard let first = try Flam3Parser.parse(data).first else {
                    rejects.append(Reject(id: id, path: rel, reason: "no <flame> element"))
                    continue
                }
                flame = first
            } catch {
                rejects.append(Reject(id: id, path: rel, reason: "parse: \(error)"))
                continue
            }
            // `Flame.isRenderable` now lives in FlameKit (moved from EmberweftUI
            // for M6) — single shared definition across CLI / FlameExport / GUI.
            guard flame.isRenderable else {
                rejects.append(Reject(id: id, path: rel,
                                      reason: "not renderable (non-finite/out-of-band camera or zero xform weight)"))
                continue
            }
            survivors.append(Survivor(id: id, path: rel, flame: flame))
        }
        err("curate: \(survivors.count) survivors, \(rejects.count) rejected\n")

        // --- Write rejects JSONL (sorted by id for byte-stability) ---
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var rejectsBytes = Data()
        for r in rejects.sorted(by: { $0.id < $1.id }) {
            if let line = try? encoder.encode(r) {
                rejectsBytes.append(line)
                rejectsBytes.append(0x0A) // \n
            }
        }
        try? rejectsBytes.write(to: rejectsURL)

        // --- Render + score ---
        struct ScoreRow: Codable {
            let id: String
            let path: String
            let score: Double
            let brightness: Double
            let contrast: Double
            let coverage: Double
            let colorVariety: Double
        }
        var rows: [ScoreRow] = []
        rows.reserveCapacity(survivors.count)

        if noRender {
            err("curate: --no-render; skipping thumbnails + scoring\n")
        }

        let total = survivors.count
        for (idx, sv) in survivors.enumerated() {
            if idx % 100 == 0 { err("curate: render \(idx)/\(total)\n") }
            let params = RenderParams(
                seed: seed, width: width, height: height,
                oversample: 1, samplesPerPixel: spp,
                spatialFilterRadius: sv.flame.quality.filterRadius)
            let img: RGBA8Image
            if useMetal {
                img = MainActor.assumeIsolated { MetalRenderer.render(flame: sv.flame, params: params) }
            } else {
                img = ReferenceRenderer.render(flame: sv.flame, params: params)
            }
            let thumbURL = thumbsDir.appendingPathComponent("\(sv.id).png")
            try? img.writePNG(to: thumbURL)
            let m = scorePixels(img)
            rows.append(ScoreRow(
                id: sv.id, path: sv.path, score: m.score,
                brightness: m.brightness, contrast: m.contrast,
                coverage: m.coverage, colorVariety: m.colorVariety))
        }

        // --- Sort by score desc (tiebreak by id asc) → curation-scores.json ---
        rows.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.id < $1.id
        }
        let scoresEncoder = JSONEncoder()
        scoresEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let blob = try? scoresEncoder.encode(rows) {
            try? blob.write(to: outURL.appendingPathComponent("curation-scores.json"))
        }

        // --- Copy top-N thumbnails into {out}/top/ ---
        let limit = min(topN, rows.count)
        for r in rows.prefix(limit) {
            let src = thumbsDir.appendingPathComponent("\(r.id).png")
            let dst = topDir.appendingPathComponent("\(r.id).png")
            try? fm.removeItem(at: dst)
            try? fm.copyItem(at: src, to: dst)
        }

        err("curate: done — \(rows.count) scored, top \(limit) thumbnails in \(topDir.path)\n")
        return 0
    }

    // MARK: - helpers

    /// Recursive `.flam3` walk sorted by path (deterministic; rule #2).
    private static func enumerateFlam3(in root: URL) -> [URL] {
        var urls: [URL] = []
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        for case let url as URL in enumerator {
            if url.pathExtension == "flam3" { urls.append(url) }
        }
        return urls.sorted { $0.path < $1.path }
    }

    /// Deterministic pleasantness metrics over the RGBA8 pixels.
    /// All accumulations are over the flat pixel ARRAY (no Dict/Set) →
    /// byte-identical across process launches (rule #2).
    private struct Metrics {
        let brightness: Double
        let contrast: Double
        let coverage: Double
        let colorVariety: Double
        let score: Double
    }
    private static func scorePixels(_ img: RGBA8Image) -> Metrics {
        let n = img.width * img.height
        if n == 0 {
            return Metrics(brightness: 0, contrast: 0, coverage: 0, colorVariety: 0, score: 0)
        }
        let px = img.pixels
        // Pass 1: per-pixel luma (BT.601). Sum + sum-of-squares over the array.
        var sumL = 0.0
        var sumLL = 0.0
        var covered = 0
        // 36 hue bins (10° each) — fixed-size Bool array, NOT a Set.
        var hueBins = [Bool](repeating: false, count: 36)
        let bgThreshold = 0.01  // luma below this counts as background
        for p in 0..<n {
            let r = Double(px[p * 4]) / 255.0
            let g = Double(px[p * 4 + 1]) / 255.0
            let b = Double(px[p * 4 + 2]) / 255.0
            let l = 0.299 * r + 0.587 * g + 0.114 * b
            sumL += l
            sumLL += l * l
            if l > bgThreshold {
                covered += 1
                // Hue bin (only for non-bg pixels).
                let mx = max(r, max(g, b))
                let mn = min(r, min(g, b))
                let delta = mx - mn
                if delta > 1.0 / 255.0 {
                    var h: Double
                    if mx == r {
                        h = (g - b) / delta
                    } else if mx == g {
                        h = 2.0 + (b - r) / delta
                    } else {
                        h = 4.0 + (r - g) / delta
                    }
                    h *= 60.0
                    if h < 0 { h += 360.0 }
                    var bin = Int(h / 10.0)
                    if bin < 0 { bin = 0 }
                    if bin >= 36 { bin = 35 }
                    hueBins[bin] = true
                }
            }
        }
        let brightness = sumL / Double(n)
        let mean = brightness
        let variance = max(0.0, sumLL / Double(n) - mean * mean)
        let contrast = sqrt(variance)
        let coverage = Double(covered) / Double(n)
        var hueCount = 0
        for b in hueBins where b { hueCount += 1 }
        let colorVariety = Double(hueCount) / 36.0

        // Sub-scores in [0,1] with FIXED scaling, then FIXED weights.
        // Brightness: flames are mostly dark; reward mid-bright up to a soft
        // cap at 0.5 mean luma, then gently penalize blown-out frames.
        let brightRaw = min(brightness, 0.5) / 0.5
        let brightScore = brightRaw * (1.0 - max(0.0, brightness - 0.5) * 0.5)
        let contrastScore = min(contrast / 0.15, 1.0)
        // Coverage peaks around 0.3-0.7; too full = muddy, too empty = sparse.
        let covScore = 1.0 - min(abs(coverage - 0.4) / 0.4, 1.0)
        let varietyScore = min(colorVariety, 1.0)

        let wB = 0.20
        let wC = 0.30
        let wCov = 0.30
        let wV = 0.20
        let score = wB * brightScore + wC * contrastScore + wCov * covScore + wV * varietyScore
        let clamped = max(0.0, min(1.0, score))
        return Metrics(
            brightness: brightness, contrast: contrast,
            coverage: coverage, colorVariety: colorVariety, score: clamped)
    }
}
