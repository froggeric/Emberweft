// Tests/FlameReferenceTests/Flam3Oracle.swift
//
// The flam3 parity-oracle harness. Spawns the locally-built `flam3-genome` and
// `flam3-animate` binaries (env-var driven — NO CLI flags) to generate reference
// motion genomes and rendered PNG sequences for vs-flam3 parity tests.
//
// flam3 is NEVER linked into or distributed with Emberweft; it is a dev-machine
// prerequisite built from source (see `Tools/flam3_oracle.sh`). When the
// binaries are absent from $PATH, `isAvailable` returns false and every
// vs-flam3 test must call `require()`, which `XCTSkip`s with a clear warning
// rather than failing — the F10 auto-skip fallback. Metal<->CPU parity (>=38 dB)
// remains the hard gate; vs-flam3 (>=30 dB) is the secondary, dev-only oracle.
//
// NOTE: this test Process-spawns external binaries. Like the Metal tests it may
// need the bash sandbox DISABLED when run from Claude Code (the spawned process
// inherits the sandbox and can be denied fork/exec). Run via
// `swift test --filter Flam3OracleSmoke` with the sandbox off.

import Foundation
import XCTest

/// Env-var-driven wrapper around the locally-built `flam3-genome` /
/// `flam3-animate` / `flam3-render` binaries. All vs-flam3 tests go through
/// this helper so the F10 auto-skip is applied uniformly.
enum Flam3Oracle {
    /// True iff BOTH `flam3-genome` and `flam3-animate` resolve on `$PATH`.
    /// Uses `/usr/bin/which` (not the shell builtin) so it works regardless of
    /// the user's login shell.
    static var isAvailable: Bool {
        which("flam3-genome") != nil && which("flam3-animate") != nil
    }

    /// True iff `flam3-render` (the static-frame oracle, env-var driven like the
    /// others) resolves on `$PATH`. Separate from `isAvailable` because static
    /// parity on a single genome needs only `flam3-render` — not the animation
    /// pair. The real-genome density-parity gate (`RealGenomeParityTests`) uses
    /// this; `Tools/density_diff.py` uses the same binary.
    static var isRenderAvailable: Bool {
        which("flam3-render") != nil
    }

    /// Like `require()` but for the static-render oracle (`flam3-render`).
    /// XCTSkips (never fails) when `flam3-render` is absent — same F10 fallback.
    static func requireRender(file: StaticString = #file, line: UInt = #line) throws {
        guard isRenderAvailable else {
            throw XCTSkip(
                "flam3-render oracle not built — see Tools/flam3_oracle.sh (F10 auto-skip). "
                + "Build flam3 from source (scottdraves/flam3) and put flam3-render on "
                + "$PATH to enable real-genome parity.")
        }
    }

    /// Resolve a binary name to its absolute path via `/usr/bin/which`, or nil.
    private static func which(_ command: String) -> String? {
        let p = Process()
        p.launchPath = "/usr/bin/which"
        p.arguments = [command]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return nil
        }
        guard p.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (path?.isEmpty == false) ? path : nil
    }

    /// Every vs-flam3 test calls this first. XCTSkips (never fails) when the
    /// oracle is absent — the F10 fallback.
    static func require(file: StaticString = #file, line: UInt = #line) throws {
        guard isAvailable else {
            throw XCTSkip(
                "flam3 oracle not built — see Tools/flam3_oracle.sh (F10 auto-skip). "
                + "Build flam3 from source (scottdraves/flam3) and put flam3-genome/"
                + "flam3-animate on $PATH to enable vs-flam3 parity.")
        }
    }

    // MARK: - flam3-genome (motion-genome generation)

    /// flam3-genome modes (flam3-genome.c:451-475). The mode name IS the env
    /// var name; its value is the input genome path.
    enum GenomeMode: String {
        case sequence   // whole loop+edge chain for N stills
        case rotate     // one loop
        case inter      // one edge (requires exactly 2 control points)
    }

    /// Runs `flam3-genome` env-var driven and captures stdout (the generated
    /// motion genome XML) to `outputURL`.
    ///
    /// - Parameters:
    ///   - mode: `sequence` / `rotate` / `inter` (becomes the env var name).
    ///   - input: path to the input `.flam3` genome (the env var's value).
    ///   - nframes: total frame count for the animation (`nframes` env var).
    ///   - frame: 1-indexed frame to emit for `rotate`/`inter` (`frame` env var;
    ///     ignored by flam3 in `sequence` mode).
    ///   - outputURL: where to write the generated motion-genome XML.
    @discardableResult
    static func genMotionGenome(
        mode: GenomeMode,
        input: String,
        nframes: Int,
        frame: Int? = nil,
        outputURL: URL
    ) throws -> String {
        try require()
        let env: [String: String] = {
            var e = ProcessInfo.processInfo.environment
            e[mode.rawValue] = input
            e["nframes"] = String(nframes)
            if let frame { e["frame"] = String(frame) }
            return e
        }()
        let stdout = try run(command: "flam3-genome", arguments: [], environment: env, stdin: nil)
        try stdout.write(to: outputURL, atomically: true, encoding: .utf8)
        return stdout
    }

    // MARK: - flam3-animate (PNG-sequence rendering)

    /// Renders a motion genome to a PNG sequence with `flam3-animate`, env-var
    /// driven (`begin`/`end`/`prefix`). MOTION BLUR IS DISABLED (F6): before
    /// spawning flam3-animate, `passes="1"` and `temporal_samples="1"` are
    /// injected onto every `<flame>` control point in `genome` (these are genome
    /// ATTRIBUTES, not env vars — default temporal_samples=1000 would otherwise
    /// blur transition interiors and make the >=30 dB gate fail systematically).
    ///
    /// - Parameters:
    ///   - genome: the motion-genome XML (as written by `genMotionGenome` or
    ///     loaded from a frozen `.flam3`).
    ///   - begin: first frame index (`begin` env var).
    ///   - end: last frame index (`end` env var).
    ///   - prefix: output filename prefix including dir + trailing dot, e.g.
    ///     `/tmp/out.` -> `/tmp/out.00000.png` (`prefix` env var).
    /// - Returns: Paths of all PNG files flam3-animate actually wrote.
    @discardableResult
    static func renderFrames(
        genome: String,
        begin: Int,
        end: Int,
        prefix: String
    ) throws -> [URL] {
        try require()
        let motionBlurOff = Self.injectMotionBlurOff(genome)
        let env: [String: String] = {
            var e = ProcessInfo.processInfo.environment
            e["begin"] = String(begin)
            e["end"] = String(end)
            e["prefix"] = prefix
            return e
        }()
        // Record which PNGs exist before/after so we return only new files.
        let prefixURL = URL(fileURLWithPath: prefix)
        let dir = prefixURL.deletingLastPathComponent().path
        let fm = FileManager.default
        let before = Set((try? fm.contentsOfDirectory(atPath: dir)) ?? [])
        _ = try run(
            command: "flam3-animate",
            arguments: [],
            environment: env,
            stdin: motionBlurOff)
        let after = Set((try? fm.contentsOfDirectory(atPath: dir)) ?? [])
        let newFiles = after.subtracting(before)
        return newFiles
            .filter { $0.hasSuffix(".png") }
            .map { URL(fileURLWithPath: dir).appendingPathComponent($0) }
            .sorted(by: { $0.path < $1.path })
    }

    // MARK: - flam3-render (static-frame oracle)

    /// Renders a single static frame from a `.flam3` genome via env-var-driven
    /// `flam3-render` (no flags — same contract as `regen_goldens.sh:84-89` and
    /// `Tools/density_diff.py:121-137`). The genome's own `size`, `quality`,
    /// `oversample`, `filter`, `brightness`, etc. drive the render; the only
    /// env vars set here are the reproducibility pins (seed/isaac_seed/nthreads)
    /// and the I/O paths (`in`/`out`/`format`).
    ///
    /// Used by `RealGenomeParityTests` for the real-genome density-parity gate.
    /// Callers pre-sanitize the genome (motion-blur off, supersample=1, DE off)
    /// before passing it in — `Tools/density_diff.py:74-96` is the reference
    /// sanitization. `Tools/density_diff.py` and this helper share one proven
    /// flam3-render invocation so their PSNR numbers are directly comparable.
    ///
    /// - Parameters:
    ///   - genomeXML: the (typically sanitized) `.flam3` genome XML, fed via
    ///     stdin. (Passing a path via `in=` would also work; stdin avoids
    ///     writing a temp file and matches `renderFrames`'s pattern.)
    ///   - outPath: absolute path the PNG is written to (`out` env var).
    ///   - seed: libc `srandom` seed (env `seed`); default matches
    ///     `Tools/density_diff.py`'s `LIBC_SEED = "42"` (aux RNG only — ISAAC
    ///     drives the chaos game).
    ///   - isaacSeed: ISAAC chaos-game seed (env `isaac_seed`); default matches
    ///     `ChaosGame.goldenIsaacSeed` ("emberweftgoldens") so flam3's sample
    ///     stream matches Emberweft CPU's exactly.
    ///   - nthreads: thread count (env `nthreads`); default 1 (Emberweft's CPU
    ///     reference is single-threaded — `regen_goldens.sh` documents why this
    ///     pin is critical for parity).
    /// - Returns: `outPath` on success (throws on non-zero exit).
    @discardableResult
    static func renderStatic(
        genomeXML: String,
        outPath: String,
        seed: String = "42",
        isaacSeed: String = "emberweftgoldens",
        nthreads: Int = 1
    ) throws -> String {
        try requireRender()
        let env: [String: String] = {
            var e = ProcessInfo.processInfo.environment
            e["format"] = "png"
            e["transparency"] = "0"
            e["seed"] = seed
            e["isaac_seed"] = isaacSeed
            e["nthreads"] = String(nthreads)
            // `in` defaults to the literal string "stdin" inside flam3-render
            // (see `flam3-render -h`); leaving it unset makes it read the genome
            // from stdin, which `run(stdin:)` pipes in. Setting `in=/dev/stdin`
            // does NOT work (flam3 looks for the magic string "stdin").
            e["out"] = outPath
            e["earlyclip"] = "0"     // default; Emberweft assumes the !earlyclip tone-map path
            return e
        }()
        // Pipe the genome in via stdin so we never write a temp file. The `in=`
        // env var points at /dev/stdin; flam3-render opens it like any input.
        _ = try run(command: "flam3-render",
                    arguments: [],
                    environment: env,
                    stdin: genomeXML)
        return outPath
    }

    // MARK: - Internals

    /// Forces `passes="1" temporal_samples="1"` onto every `<flame>` opening
    /// tag, disabling temporal oversampling / motion blur (F6). Existing values
    /// are OVERWRITTEN (flam3-genome emits `temporal_samples="1000"` by default,
    /// which would blur transition interiors and make the ≥30 dB gate fail
    /// systematically); attrs absent on a tag are inserted. Idempotent.
    static func injectMotionBlurOff(_ genome: String) -> String {
        var out = genome
        // 1. Overwrite any existing passes="…" / temporal_samples="…" values.
        if let re = try? NSRegularExpression(pattern: "passes=\"[^\"]*\"") {
            out = re.stringByReplacingMatches(
                in: out, range: NSRange(out.startIndex..., in: out),
                withTemplate: "passes=\"1\"")
        }
        if let re = try? NSRegularExpression(pattern: "temporal_samples=\"[^\"]*\"") {
            out = re.stringByReplacingMatches(
                in: out, range: NSRange(out.startIndex..., in: out),
                withTemplate: "temporal_samples=\"1\"")
        }
        // 2. Insert the attrs on <flame> tags still missing them (negative
        //    lookaheads skip tags that already carry the attr — including those
        //    just overwritten above — and the root <flames> via required whitespace).
        let pattern = "<flame(?![^>]*passes=)(?![^>]*temporal_samples=)(\\s)"
        if let re = try? NSRegularExpression(pattern: pattern) {
            out = re.stringByReplacingMatches(
                in: out, range: NSRange(out.startIndex..., in: out),
                withTemplate: "<flame passes=\"1\" temporal_samples=\"1\"$1")
        }
        return out
    }

    /// Spawns a command env-var driven with optional stdin; returns stdout.
    @discardableResult
    static func run(
        command: String,
        arguments: [String],
        environment: [String: String],
        stdin: String?
    ) throws -> String {
        let resolved = which(command) ?? command
        let p = Process()
        p.launchPath = resolved
        p.arguments = arguments
        p.environment = environment
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        // Stdin: pipe the genome XML in if provided.
        if let stdin {
            let inPipe = Pipe()
            p.standardInput = inPipe
            try p.run()
            inPipe.fileHandleForWriting.write(Data(stdin.utf8))
            try? inPipe.fileHandleForWriting.close()
        } else {
            // No stdin: attach /dev/null so flam3 doesn't block on a tty.
            try p.run()
        }

        p.waitUntilExit()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: outData, encoding: .utf8) ?? ""
        if p.terminationStatus != 0 {
            throw Flam3OracleError.commandFailed(
                command: command,
                status: p.terminationStatus,
                stderr: stderr)
        }
        return stdout
    }
}

enum Flam3OracleError: Error, CustomStringConvertible {
    case commandFailed(command: String, status: Int32, stderr: String)

    var description: String {
        switch self {
        case let .commandFailed(command, status, stderr):
            return "\(command) exited \(status): \(stderr)"
        }
    }
}
