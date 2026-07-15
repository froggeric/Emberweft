import Foundation
import FlameKit
import FlameReference

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
        case "info": return info(args.dropFirst().first)
        case "validate": return validate(args.dropFirst().first)
        case "render": return render(Array(args.dropFirst()))
        default:
            err("unknown command: \(cmd)\n"); printHelp(); return 2
        }
    }

    private static func printHelp() {
        out("""
        emberweft \(FlameKit.version) — fractal-flame renderer (CPU backend)
        Usage:
          emberweft render   <genome.flam3> [-o out.png] [--size WxH] [--quality N] [--seed N]
          emberweft validate <genome.flam3>
          emberweft info     <genome.flam3>
          emberweft --version | --help
        """)
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
            default: i += 1
            }
        }
        let params = RenderParams(
            seed: seed, width: width, height: height, oversample: 1, samplesPerPixel: quality)
        let img = ReferenceRenderer.render(flame: flame, params: params)
        do { try img.writePNG(to: URL(fileURLWithPath: output)) }
        catch { err("error: cannot write \(output): \(error)\n"); return 1 }
        out("wrote \(output) (\(width)×\(height))\n")
        return 0
    }
}
