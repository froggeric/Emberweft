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

    @discardableResult
    public static func run(_ argv: [String]) -> Int32 {
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
          emberweft validate <genome.flam3>
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
