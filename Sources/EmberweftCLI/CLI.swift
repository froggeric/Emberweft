import Foundation
import FlameKit
import FlameReference
import FlameRenderer

/// Testable `emberweft` CLI engine.
///
/// All side effects (stdout/stderr) are funneled through the `out`/`err`
/// closures so tests can capture or redirect them. `run(_:)` returns a Unix
/// exit code, enabling `exit(...)` in the thin executable wrapper.
public enum EmberweftCLI {
    // IO hooks for test injection. The CLI runs single-threaded; these are
    // mutated only at startup/test setup, so `nonisolated(unsafe)` is the
    // correct escape hatch from Swift 6's global-mutable-state check.
    public nonisolated(unsafe) static var out: (String) -> Void = { Swift.print($0, terminator: "") }
    public nonisolated(unsafe) static var err: (String) -> Void = { FileHandle.standardError.write($0.data(using: .utf8)!) }

    /// `async` (and `@MainActor`) so `emberweft export` can drive the
    /// `ExportCoordinator` — whose Metal path renders via `await MainActor.run`
    /// (the temporal Metal path is MainActor-only; a synchronous export that
    /// blocked the main thread would deadlock that hop). `@MainActor` is
    /// required, not just `async`: the existing sync subcommands
    /// (`listBackends`/`render`/`animate`) reach Metal through
    /// `MainActor.assumeIsolated`, which traps unless the caller is ON the main
    /// actor. Top-level code in `main.swift` is `@MainActor`-isolated, so
    /// `await run(...)` stays on the main actor and those subcommands keep
    /// working unchanged. `export` itself is nonisolated `async` (it hops off
    /// the main actor, freeing it to service the coordinator's Metal hops).
    @MainActor
    @discardableResult
    public static func run(_ argv: [String]) async -> Int32 {
        let args = Array(argv.dropFirst())
        guard let cmd = args.first else { printHelp(); return 0 }
        switch cmd {
        case "--version": out("emberweft \(FlameKit.version)\n"); return 0
        case "-h", "--help": printHelp(); return 0
        case "--list-backends": return listBackends()
        case "info": return info(args.dropFirst().first)
        case "validate": return validate(args.dropFirst().first)
        case "render": return render(Array(args.dropFirst()))
        case "animate": return animate(Array(args.dropFirst()))
        case "export": return await export(Array(args.dropFirst()))   // async dispatch
        case "flock":  return await flock(Array(args.dropFirst()))    // async (drives coordinators)
        case "curate": return curate(Array(args.dropFirst()))
        case "_feature-score": return featureScore(Array(args.dropFirst()))
        default:
            err("unknown command: \(cmd)\n"); printHelp(); return 2
        }
    }

    private static func printHelp() {
        out("""
        emberweft \(FlameKit.version) — fractal-flame renderer (CPU | Metal backend)
        Usage:
          emberweft render   <genome.flam3> [-o out.png] [--size WxH] [--quality N] [--seed N] [--backend cpu|metal]
          emberweft animate  <a.flam3> <b.flam3> … [--frames N] [--segments N] [--selector sequential|similarity] [--seed N] [--stagger F] [--backend cpu|metal] [--out DIR] [--size WxH] [--quality N]
          emberweft export  <a.flam3> <b.flam3> … [--frames N] [--segments N] [--seed N] [--backend cpu|metal] [--codec h264|hevc] [--resolution 720p|1080p|1440p|4k|vertical720|vertical1080|portrait4x5|square1080|WxH] [--fps 24|25|30|48|50|60] [--out FILE.mp4] [--quality genome|N] [--temporal-samples N] [--loop-cycles N] [--stagger F] [--container mp4|mov] [--bitrate auto|N] [--frame N --png FILE.png] [--force] [--strict-backend] [--segment-frames N]
            (--codec hevc on a host without HEVC encode errors exit 1; the default h264 codec is always available)
            (the encoded .mp4 is NOT byte-stable across machines/OS versions; the frame PIXELS are deterministic. Use `emberweft animate` for byte-exact PNG mastering)
          emberweft export --jobs MANIFEST.json [--out DIR/] [--fail-fast] [shared flags: --backend --codec --resolution --fps --quality --temporal-samples --container --bitrate --segment-frames]
            (batch: runs each manifest entry serially; continue-on-failure by default, or abort on first failure with --fail-fast; exit code is 0 only if every job succeeded)
            manifest schema (a JSON array; `genome` and `out` are required, the rest are optional per-job overrides):
              [{"genome":"a.flam3","out":"a.mp4","frames":16,"segments":1,"seed":7,"loopCycles":1,"stagger":0.0,"temporalSamples":1}, …]
            each `out` is sanitized to a bare filename (allowlist [A-Za-z0-9._-]) and resolved under --out (or CWD); `..`, absolute, and hidden names are rejected
          emberweft validate <genome.flam3>
          emberweft flock generate --shard <name> --from <dir|flam3> [--scope edges|loops|both] [--quality genome|N] [--codec h264|hevc] [--temporal-samples N] [--backend cpu|metal] [--flock <dir>]
            (renders loop+edge artifacts into the flock archive; hit-skip + upgrade-overwrite; prints skip/render progress. --from enumerates .flam3 (ES-named pass through their gen/id, others are minted into flock 900000). --shard is WxH_fps[_Lf<loop>-Tf<trans>])
          emberweft flock stitch --shard <name> --sequence <dir|flam3> [--out file.mov] [--quality genome|N] [--codec h264|hevc] [--backend cpu|metal] [--flock <dir>]
            (assembles a long-form video from the archive; prints HIT/will-gen plan, then progress; same-codec passthrough concat, no re-encode)
          emberweft flock browse [--shard <name>] [--flock <dir>]
            (prints shard + artifact counts; with --shard, per-shard detail)
          emberweft flock rebuild [--flock <dir>]
            (rebuilds flock.sqlite from <shard>/mpeg/ filenames + embedded tags)
          emberweft flock export-list --shard <name> [--flock <dir>]
            (writes the ES <list> XML beside the shard dir)
          emberweft curate   [--library DIR] [--out DIR] [--size WxH] [--spp N] [--seed N] [--backend cpu|metal] [--sample N] [--top N] [--no-render]
          emberweft info     <genome.flam3>
          emberweft --list-backends
          emberweft --version | --help
        """)
    }

    private static func listBackends() -> Int32 {
        let metal = MainActor.assumeIsolated { MetalRenderer.isAvailable }
        out("cpu: available\n")
        out("metal: \(metal ? "available" : "unavailable")\n")
        return 0
    }

    private static func load(_ path: String?) -> Flame? {
        guard let path, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            err("error: cannot read \(path ?? "<none>")\n"); return nil
        }
        do { return try Flam3Parser.parse(data).first }
        catch { err("error: \(error)\n"); return nil }
    }

    private static func info(_ path: String?) -> Int32 {
        guard let f = load(path) else { return 1 }
        out("name: \(f.name)\n")
        out("size: \(f.size.x)×\(f.size.y)\n")
        out("xforms: \(f.xforms.count)\(f.finalXform != nil ? " (+ final)" : "")\n")
        let vars = Set(f.xforms.flatMap { $0.variations.map(\.name) })
        out("variations: \(vars.sorted().joined(separator: ", "))\n")
        out("palette: \(f.palette.colors.count) entries\n")
        return 0
    }

    private static func validate(_ path: String?) -> Int32 {
        guard load(path) != nil else { return 1 }
        out("ok\n"); return 0
    }

    private static func render(_ args: [String]) -> Int32 {
        guard let genomePath = args.first, !genomePath.hasPrefix("-") else {
            err("error: render requires a genome path\n"); return 2
        }
        guard let flame = load(genomePath) else { return 1 }
        var output = "out.png"
        var width = flame.size.x
        var height = flame.size.y
        var quality = flame.quality.samplesPerPixel
        var seed: UInt64 = 0
        var backend = "cpu"
        var i = 1
        while i < args.count {
            switch args[i] {
            case "-o":
                guard i + 1 < args.count else { err("error: -o requires a value\n"); return 2 }
                output = args[i + 1]; i += 2
            case "--size":
                guard i + 1 < args.count else { err("error: --size requires a value\n"); return 2 }
                let parts = args[i + 1].split(separator: "x").compactMap { Int($0) }
                if parts.count == 2 { width = parts[0]; height = parts[1] }
                i += 2
            case "--quality":
                guard i + 1 < args.count else { err("error: --quality requires a value\n"); return 2 }
                quality = Int(args[i + 1]) ?? quality; i += 2
            case "--seed":
                guard i + 1 < args.count else { err("error: --seed requires a value\n"); return 2 }
                seed = UInt64(args[i + 1]) ?? seed; i += 2
            case "--backend":
                guard i + 1 < args.count else { err("error: --backend requires a value\n"); return 2 }
                let v = args[i + 1].lowercased()
                guard v == "cpu" || v == "metal" else { err("error: --backend must be cpu|metal\n"); return 2 }
                backend = v; i += 2
            default: i += 1
            }
        }
        let params = RenderParams(
            seed: seed, width: width, height: height, oversample: 1, samplesPerPixel: quality)
        let img: RGBA8Image
        if backend == "metal" {
            let metalOK = MainActor.assumeIsolated { MetalRenderer.isAvailable }
            guard metalOK else {
                err("error: Metal backend unavailable on this machine; use --backend cpu\n")
                return 1
            }
            img = MainActor.assumeIsolated { MetalRenderer.render(flame: flame, params: params) }
        } else {
            img = ReferenceRenderer.render(flame: flame, params: params)
        }
        do { try img.writePNG(to: URL(fileURLWithPath: output)) }
        catch { err("error: cannot write \(output): \(error)\n"); return 1 }
        out("wrote \(output) (\(width)×\(height))\n")
        return 0
    }

    /// Hidden diagnostic subcommand (NOT advertised in `--help`): build
    /// `FeatureVector`s for two genomes and print the similarity score as the
    /// exact bit pattern of the `Double` (hex `%016x`). Used by the F1
    /// cross-process bit-identity acceptance test — each process launch has a
    /// fresh Swift hash seed, so byte-equal output proves no String-keyed
    /// Dict/Set leaks into the FP accumulation path.
    private static func featureScore(_ args: [String]) -> Int32 {
        guard args.count == 2 else {
            err("error: _feature-score requires two genome paths\n"); return 2
        }
        guard let a = load(args[0]), let b = load(args[1]) else { return 1 }
        let score = FeatureVector(for: a).similarity(to: FeatureVector(for: b))
        out(String(format: "%016llx\n", score.bitPattern))
        return 0
    }
}
