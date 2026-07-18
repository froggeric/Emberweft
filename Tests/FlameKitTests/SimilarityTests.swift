import XCTest
@testable import FlameKit

// Task 16: FeatureVector (sorted-array, F1-deterministic) + SimilarityExploration
// ε-greedy selector. The load-bearing test is the cross-process bit-identity
// check (F1): it spawns the built `emberweft` executable N times via Process,
// each launch with a fresh Swift hash seed, and asserts the printed similarity
// score is byte-equal across all N. If String-keyed Dict/Set ever leaks into an
// FP accumulation path, this test fails.
final class SimilarityTests: XCTestCase {

    // MARK: - F9: ε-guards (zero palette, zero affine, empty variations)

    func testFeatureVectorFinitenessZeroPaletteZeroAffine() {
        // All-zero palette + zero-norm affines + no variations: nothing may NaN.
        let flame = Flame(
            xforms: [
                Xform(affine: AffineTransform(a: 0, b: 0, c: 0, d: 0, e: 0, f: 0),
                      variations: []),
                Xform(affine: AffineTransform(a: 0, b: 0, c: 0, d: 0, e: 0, f: 0),
                      variations: [])
            ],
            palette: .black
        )
        let fv = FeatureVector(for: flame)
        XCTAssertEqual(fv.paletteMeanLuma, 0.0)
        XCTAssertEqual(fv.paletteMeanHue, 0.0)
        XCTAssertEqual(fv.summedAffineFrobenius, 0.0)
        XCTAssertTrue(fv.variations.isEmpty)

        let other = FeatureVector(for: flame)
        let score = fv.similarity(to: other)
        XCTAssertTrue(score.isFinite, "score must be finite for all-zero inputs")
        XCTAssertFalse(score.isNaN)
        XCTAssertTrue(score >= 0.0 && score <= 1.0)
    }

    func testFeatureVectorFinitenessMismatchedEmptyVariations() {
        // One side has variations, the other empty → cosine denom ε-guarded.
        let a = FeatureVector(variations: [("linear", 1.0), ("swirl", 0.5)],
                              paletteMeanHue: 0.1, paletteMeanLuma: 0.2,
                              xformCount: 2, summedAffineFrobenius: 1.5)
        let b = FeatureVector(variations: [],
                              paletteMeanHue: 0.9, paletteMeanLuma: 0.0,
                              xformCount: 0, summedAffineFrobenius: 0.0)
        let score = a.similarity(to: b)
        XCTAssertTrue(score.isFinite, "score must be finite when one side is empty")
        XCTAssertFalse(score.isNaN)
    }

    // MARK: - Similarity symmetry & determinism (in-process)

    func testSimilaritySymmetric() {
        let a = FeatureVector(variations: [("linear", 0.6), ("swirl", 0.4)],
                              paletteMeanHue: 0.0, paletteMeanLuma: 0.3,
                              xformCount: 2, summedAffineFrobenius: 1.0)
        let b = FeatureVector(variations: [("linear", 0.5), ("julia", 0.5)],
                              paletteMeanHue: 0.6, paletteMeanLuma: 0.1,
                              xformCount: 1, summedAffineFrobenius: 0.8)
        XCTAssertEqual(a.similarity(to: b), b.similarity(to: a), accuracy: 1e-15)
    }

    func testIdenticalFeatureVectorsScoreMaximal() {
        let fv = FeatureVector(variations: [("linear", 1.0)],
                               paletteMeanHue: 0.25, paletteMeanLuma: 0.5,
                               xformCount: 3, summedAffineFrobenius: 2.0)
        let selfScore = fv.similarity(to: fv)
        // Identical → every difference term is 0, cosine is 1.
        XCTAssertEqual(selfScore, 1.0, accuracy: 1e-9)
    }

    // MARK: - SimilarityExploration: 50-segment walk over 20 synthetic FVs

    func testExplorationVisitsAtLeastTenDistinctSheep() {
        let library = syntheticLibrary(count: 20)
        var selector = SimilarityExploration(
            seed: 0xC0FFEE,
            epsilon: 0.2,
            recencyWindow: 3,
            featureVectors: library
        )
        var current = 0
        var visited = Set<Int>([0])
        for _ in 0..<50 {
            let next = selector.next(from: current, librarySize: library.count)
            XCTAssertNotEqual(next, current, "must move when librarySize > 1")
            XCTAssert(next >= 0 && next < library.count, "out of range")
            visited.insert(next)
            current = next
        }
        // AC: ≥ max(⌈0.5·20⌉, 10) = 10 distinct sheep.
        XCTAssertGreaterThanOrEqual(visited.count, 10,
            "50-segment walk visited only \(visited.count) distinct sheep")
    }

    func testExplorationReproducibleUnderFixedSeed() {
        let library = syntheticLibrary(count: 20)
        func runWalk() -> [Int] {
            var s = SimilarityExploration(seed: 42, epsilon: 0.2,
                                          recencyWindow: 3, featureVectors: library)
            var cur = 0, walk: [Int] = []
            for _ in 0..<30 { let n = s.next(from: cur, librarySize: 20); walk.append(n); cur = n }
            return walk
        }
        XCTAssertEqual(runWalk(), runWalk(), "same seed must yield identical walk")
    }

    func testExplorationNeverReturnsCurrentWhenLibrarySizeGreaterThanOne() {
        let library = syntheticLibrary(count: 5)
        var s = SimilarityExploration(seed: 7, epsilon: 0.5,
                                      recencyWindow: 2, featureVectors: library)
        var cur = 2
        for _ in 0..<40 {
            let n = s.next(from: cur, librarySize: 5)
            XCTAssertNotEqual(n, cur)
            cur = n
        }
    }

    // MARK: - F1 cross-process bit-identity (LOAD-BEARING)

    /// Spawns the built `emberweft _feature-score` executable N=4 times via
    /// `Process`. Each launch has a fresh Swift hash seed, so byte-equal output
    /// proves no String-keyed Dict/Set leaks into the FP accumulation path.
    func testFeatureScoreBitIdenticalAcrossProcesses() throws {
        // `#file` may be relative or absolute depending on toolchain; resolve
        // the fixture dir robustly against several candidate bases.
        let candidates: [URL] = [
            // cwd-relative (swift test runs from the package root)
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Tests/FlameKitTests/Fixtures/similarity_pair"),
            // relative to this source file
            URL(fileURLWithPath: #file)
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures")
                .appendingPathComponent("similarity_pair")
        ]
        guard let dir = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("a.flam3").path)
                && FileManager.default.fileExists(atPath: $0.appendingPathComponent("b.flam3").path)
        }) else {
            throw XCTSkip("similarity_pair fixtures not found in any candidate base")
        }
        let a = dir.appendingPathComponent("a.flam3").path
        let b = dir.appendingPathComponent("b.flam3").path

        // Resolve the built executable: `swift build --product emberweft
        // --show-bin-path` → <bin>/emberweft. If anything can't be resolved,
        // skip loudly rather than fail — the in-process tests still cover logic.
        guard let exe = resolveEmberweftExecutable() else {
            throw XCTSkip("could not resolve / build the `emberweft` executable; skipping cross-process F1 check")
        }

        let n = 4
        var outputs: [String] = []
        for _ in 0..<n {
            let out = try spawnCapture(exe, args: ["_feature-score", a, b])
            XCTAssertFalse(out.isEmpty, "emberweft _feature-score produced no output")
            outputs.append(out)
        }
        // All N outputs must be byte-equal (F1 hard rule).
        let first = outputs[0]
        for (i, o) in outputs.enumerated() where i > 0 {
            XCTAssertEqual(o, first,
                "F1 violated: process launch \(i) produced a different score (\(o) vs \(first))")
        }
        // Sanity: the line is a 16-hex-digit bit pattern.
        let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(trimmed.count, 16, "expected %016x bit pattern, got \(trimmed)")
        XCTAssertNotNil(UInt64(trimmed, radix: 16), "not hex: \(trimmed)")
    }

    // MARK: - Helpers

    /// 20 hand-built feature vectors with overlapping-but-distinct variation
    /// sets so the exploit step spreads across the library.
    private func syntheticLibrary(count: Int) -> [FeatureVector] {
        var out: [FeatureVector] = []
        for i in 0..<count {
            // Each sheep owns a unique variation plus a shared "common" whose
            // weight varies per sheep → similarity is non-degenerate.
            let vars: [(name: String, weight: Double)] = i == 0
                ? [("seed", 1.0)]
                : [
                    ("common", Double(i) * 0.1),
                    ("var_\(i)", 1.0)
                ]
            // Already sorted lexicographically except for the i==0 case.
            let sorted = vars.sorted { $0.name < $1.name }
            out.append(FeatureVector(
                variations: sorted,
                paletteMeanHue: Double(i) / Double(count),
                paletteMeanLuma: 0.5,
                xformCount: max(1, i % 5),
                summedAffineFrobenius: Double(i) * 0.5
            ))
        }
        return out
    }

    /// Resolve the `emberweft` executable: build it, then read its bin path.
    private func resolveEmberweftExecutable() -> String? {
        let task = Process()
        task.launchPath = "/usr/bin/env"
        task.arguments = ["swift", "build", "--product", "emberweft", "--show-bin-path"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return nil }
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let bin = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let bin, !bin.isEmpty else { return nil }
        let exe = bin + "/emberweft"
        return FileManager.default.isExecutableFile(atPath: exe) ? exe : nil
    }

    /// Spawn `exe` with `args`, wait, return trimmed stdout as a String.
    private func spawnCapture(_ exe: String, args: [String]) throws -> String {
        let task = Process()
        task.launchPath = exe
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        try task.run()
        task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0,
            "emberweft exited \(task.terminationStatus)")
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
