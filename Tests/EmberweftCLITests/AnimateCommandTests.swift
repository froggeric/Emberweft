import XCTest
@testable import EmberweftCLI
import FlameKit
import FlameReference

final class AnimateCommandTests: XCTestCase {

    // MARK: - Fixtures

    /// Two simple genomes with different affines so transitions are non-trivial.
    private let genomeA = """
    <flames><flame name="A" size="16 16" scale="64" quality="10">
      <xform coefs="1 0 0 1 0 0" linear="1"/>
    </flame></flames>
    """
    private let genomeB = """
    <flames><flame name="B" size="16 16" scale="64" quality="10">
      <xform coefs="0.5 0 0 0.5 0 0" linear="1"/>
    </flame></flames>
    """

    /// Write `xml` to a temp file with the given name; returns its URL.
    private func tmp(_ xml: String, name: String) -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
        try? xml.data(using: .utf8)!.write(to: url)
        return url
    }

    /// Create a fresh temp output directory.
    private func freshOut(_ label: String) -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("animate_\(label)_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Tests

    /// AC: `--frames 8 --segments 3` writes exactly 3*8 = 24 PNGs + manifest.
    func testWritesCorrectPNGCountAndManifest() throws {
        let a = tmp(genomeA, name: "anim_basic_a.flam3")
        let b = tmp(genomeB, name: "anim_basic_b.flam3")
        let out = freshOut("basic")

        let code = EmberweftCLI.run([
            "emberweft", "animate", a.path, b.path,
            "--frames", "8", "--segments", "3",
            "--selector", "sequential", "--seed", "0",
            "--backend", "cpu", "--out", out.path,
            "--size", "16x16", "--quality", "10",
        ])
        XCTAssertEqual(code, 0)

        // Exactly 24 PNGs: 000000.png … 000023.png.
        for i in 0..<24 {
            let name = String(format: "%06d.png", i)
            let path = out.appendingPathComponent(name).path
            XCTAssertTrue(FileManager.default.fileExists(atPath: path),
                          "Missing frame \(name)")
        }
        // No 25th frame.
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: out.appendingPathComponent("000024.png").path),
            "Should NOT emit a 25th frame")

        // manifest.json exists and parses via Manifest Codable.
        let manifestURL = out.appendingPathComponent("manifest.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)

        // Schema fields.
        XCTAssertEqual(manifest.manifestVersion, 1)
        XCTAssertEqual(manifest.framesPerSegment, 8)
        XCTAssertEqual(manifest.segmentCount, 3)
        XCTAssertEqual(manifest.totalFrames, 24)
        XCTAssertEqual(manifest.frames.count, 24)
        XCTAssertEqual(manifest.stagger, 0.0)       // top-level
        XCTAssertEqual(manifest.selector, "sequential")
        XCTAssertEqual(manifest.backend, "cpu")

        // F1: frames array is index-ordered (iterating 0..<totalFrames).
        for (i, entry) in manifest.frames.enumerated() {
            XCTAssertEqual(entry.index, i, "Frame entry \(i) has wrong index")
            XCTAssertEqual(entry.file, String(format: "%06d.png", i))
        }

        // 1-indexed blend ∈ (0,1] — none is 0.
        for entry in manifest.frames {
            XCTAssertGreaterThan(entry.blend, 0.0, "blend must be > 0 (1-indexed convention)")
            XCTAssertLessThanOrEqual(entry.blend, 1.0, "blend must be <= 1")
        }

        // Loop rows have interpolationType: null.
        for entry in manifest.frames where entry.kind == "loop" {
            XCTAssertNil(entry.interpolationType,
                         "loop row interpolationType must be null")
        }
        // Transition rows carry a type.
        for entry in manifest.frames where entry.kind == "transition" {
            XCTAssertNotNil(entry.interpolationType,
                            "transition row should carry interpolationType")
        }

        // Alternation: segments alternate loop / transition by parity.
        // segmentId 0 = loop, 1 = transition, 2 = loop.
        let seg0Frames = manifest.frames.filter { $0.segmentId == 0 }
        XCTAssertTrue(seg0Frames.allSatisfy { $0.kind == "loop" })
        let seg1Frames = manifest.frames.filter { $0.segmentId == 1 }
        XCTAssertTrue(seg1Frames.allSatisfy { $0.kind == "transition" })
        let seg2Frames = manifest.frames.filter { $0.segmentId == 2 }
        XCTAssertTrue(seg2Frames.allSatisfy { $0.kind == "loop" })
    }

    /// AC: Empty/size-1 input → non-zero exit with a clear error.
    func testSize1InputErrors() throws {
        let a = tmp(genomeA, name: "anim_single.flam3")
        let out = freshOut("single")

        let code = EmberweftCLI.run([
            "emberweft", "animate", a.path,
            "--frames", "4", "--segments", "2", "--out", out.path,
        ])
        XCTAssertNotEqual(code, 0, "Single genome must produce a non-zero exit")
    }

    /// AC: Size-0 input → non-zero exit.
    func testSize0InputErrors() throws {
        let out = freshOut("empty")

        let code = EmberweftCLI.run([
            "emberweft", "animate",
            "--frames", "4", "--segments", "2", "--out", out.path,
        ])
        XCTAssertNotEqual(code, 0, "Zero genomes must produce a non-zero exit")
    }

    /// AC: G2 byte-determinism — two runs produce byte-identical manifest.json
    /// and pixel-identical PNGs (CPU single-threaded).
    func testManifestAndPNGsByteStableAcrossRuns() throws {
        let a = tmp(genomeA, name: "anim_stab_a.flam3")
        let b = tmp(genomeB, name: "anim_stab_b.flam3")
        let out1 = freshOut("stab1")
        let out2 = freshOut("stab2")

        let args = [
            "--frames", "4", "--segments", "2",
            "--seed", "0", "--backend", "cpu",
            "--size", "16x16", "--quality", "10",
        ]

        let code1 = EmberweftCLI.run(["emberweft", "animate", a.path, b.path] + args + ["--out", out1.path])
        let code2 = EmberweftCLI.run(["emberweft", "animate", a.path, b.path] + args + ["--out", out2.path])
        XCTAssertEqual(code1, 0)
        XCTAssertEqual(code2, 0)

        // manifest.json byte-identical.
        let m1 = try Data(contentsOf: out1.appendingPathComponent("manifest.json"))
        let m2 = try Data(contentsOf: out2.appendingPathComponent("manifest.json"))
        XCTAssertEqual(m1, m2, "manifest.json must be byte-identical across runs (G2)")

        // PNGs pixel-identical across runs (CPU byte-deterministic by construction).
        let totalFrames = 2 * 4
        for i in 0..<totalFrames {
            let name = String(format: "%06d.png", i)
            let png1 = try RGBA8Image.readPNG(from: out1.appendingPathComponent(name))
            let png2 = try RGBA8Image.readPNG(from: out2.appendingPathComponent(name))
            XCTAssertEqual(png1, png2, "CPU frame \(name) must be pixel-identical across runs (G2)")
        }
    }

    /// AC: No boundary duplicate/drop — total PNG count = segments * framesPerSegment.
    func testNoBoundaryDuplicateOrDrop() throws {
        let a = tmp(genomeA, name: "anim_bound_a.flam3")
        let b = tmp(genomeB, name: "anim_bound_b.flam3")
        let out = freshOut("boundary")

        let segments = 4
        let frames = 5
        let code = EmberweftCLI.run([
            "emberweft", "animate", a.path, b.path,
            "--frames", "\(frames)", "--segments", "\(segments)",
            "--seed", "1", "--backend", "cpu", "--out", out.path,
            "--size", "8x8", "--quality", "5",
        ])
        XCTAssertEqual(code, 0)

        // Count actual PNGs in the directory.
        let allFiles = try FileManager.default.contentsOfDirectory(atPath: out.path)
            .filter { $0.hasSuffix(".png") }
        XCTAssertEqual(allFiles.count, segments * frames,
                       "PNG count must be segments*frames with no boundary dup/drop")

        // Verify manifest total matches.
        let data = try Data(contentsOf: out.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        XCTAssertEqual(manifest.totalFrames, segments * frames)
    }

    /// AC: Sequential selector needs no cache and works with just 2 genomes.
    func testSequentialSelectorNoCache() throws {
        let a = tmp(genomeA, name: "anim_seq_a.flam3")
        let b = tmp(genomeB, name: "anim_seq_b.flam3")
        let out = freshOut("seq")

        let code = EmberweftCLI.run([
            "emberweft", "animate", a.path, b.path,
            "--frames", "2", "--segments", "2",
            "--selector", "sequential",
            "--seed", "0", "--backend", "cpu", "--out", out.path,
            "--size", "8x8", "--quality", "5",
        ])
        XCTAssertEqual(code, 0)

        // Sequential: seg 0 loop(A), seg 1 transition(A→B).
        let data = try Data(contentsOf: out.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        let loopFrames = manifest.frames.filter { $0.kind == "loop" }
        let transFrames = manifest.frames.filter { $0.kind == "transition" }
        XCTAssertEqual(loopFrames.count, 2)  // seg 0: 2 frames
        XCTAssertEqual(transFrames.count, 2) // seg 1: 2 frames

        // Loop frames all have fromSheep == toSheep.
        XCTAssertTrue(loopFrames.allSatisfy { $0.fromSheep == $0.toSheep })
        // Transition frames have fromSheep != toSheep.
        XCTAssertTrue(transFrames.allSatisfy { $0.fromSheep != $0.toSheep })
    }

    /// AC: `--stagger` is recorded as a top-level field in the manifest.
    func testStaggerTopLevel() throws {
        let a = tmp(genomeA, name: "anim_stag_a.flam3")
        let b = tmp(genomeB, name: "anim_stag_b.flam3")
        let out = freshOut("stagger")

        let code = EmberweftCLI.run([
            "emberweft", "animate", a.path, b.path,
            "--frames", "2", "--segments", "2",
            "--stagger", "0.5",
            "--seed", "0", "--backend", "cpu", "--out", out.path,
            "--size", "8x8", "--quality", "5",
        ])
        XCTAssertEqual(code, 0)

        let data = try Data(contentsOf: out.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        XCTAssertEqual(manifest.stagger, 0.5)
    }
}
