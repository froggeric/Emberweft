import XCTest
@testable import EmberweftCLI
import FlameKit
import FlameReference
import FlameRenderer

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

    /// AC: A single genome renders a loop-only sequence (--segments 1): exit 0,
    /// `segments*frames` PNGs + manifest. (Transitions need ≥2 genomes; a loop
    /// needs only one.)
    func testSingleSheepLoopSucceeds() throws {
        let a = tmp(genomeA, name: "anim_loop.flam3")
        let out = freshOut("loop")
        let code = EmberweftCLI.run([
            "emberweft", "animate", a.path,
            "--frames", "4", "--segments", "1",
            "--backend", "cpu", "--size", "16x16", "--quality", "10",
            "--out", out.path,
        ])
        XCTAssertEqual(code, 0, "Single genome + --segments 1 (loop) must succeed")
        let pngs = (try? FileManager.default.contentsOfDirectory(atPath: out.path))?
            .filter { $0.hasSuffix(".png") } ?? []
        XCTAssertEqual(pngs.count, 4, "1 segment × 4 frames = 4 PNGs")
    }

    /// AC: A single genome with --segments > 1 (transitions) → non-zero exit
    /// (transitions need ≥2 genomes to morph between).
    func testSize1InputErrors() throws {
        let a = tmp(genomeA, name: "anim_single.flam3")
        let out = freshOut("single")

        let code = EmberweftCLI.run([
            "emberweft", "animate", a.path,
            "--frames", "4", "--segments", "2", "--out", out.path,
        ])
        XCTAssertNotEqual(code, 0, "Single genome + --segments > 1 (transitions) must error")
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

    /// AC (Task 17): `--selector similarity` with a fully-absent cache errors
    /// with a clear message and does NOT silently rebuild (no
    /// `--rebuild-cache`). The library dir is left untouched (no
    /// `.feature_cache/` written).
    func testSimilaritySelectorAbsentCacheErrors() throws {
        let a = tmp(genomeA, name: "anim_sim_a.flam3")
        let b = tmp(genomeB, name: "anim_sim_b.flam3")
        // A library dir containing the genomes but NO `.feature_cache/`.
        let library = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("anim_sim_lib_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try genomeA.data(using: .utf8)!.write(to: library.appendingPathComponent("a.flam3"))
        try genomeB.data(using: .utf8)!.write(to: library.appendingPathComponent("b.flam3"))
        let out = freshOut("sim_absent")

        let code = EmberweftCLI.run([
            "emberweft", "animate", a.path, b.path,
            "--frames", "2", "--segments", "2",
            "--selector", "similarity",
            "--library", library.path,
            "--seed", "0", "--backend", "cpu", "--out", out.path,
            "--size", "8x8", "--quality", "5",
        ])
        XCTAssertNotEqual(code, 0, "similarity selector with absent cache must error (no silent rebuild)")

        // Read-only: NO `.feature_cache/` must have been written into the library.
        let cacheDir = library.appendingPathComponent(".feature_cache")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: cacheDir.path),
            "similarity selector must not write `.feature_cache/` without --rebuild-cache")
    }

    // MARK: - Motion blur (`--temporal-samples`) — Task 4 Phase A

    /// Resolve a real-ES genome fixture under `Tests/Goldens/genomes_real/`.
    /// Tests run with CWD == repo root, so the relative path works. Throws
    /// `XCTSkip` (NOT fail) when the fixture is missing — same convention as
    /// `TemporalBlurMetalTests` and `RealGenomeRenderTests`.
    private func realFixture(_ name: String) throws -> URL {
        let url = URL(fileURLWithPath: "Tests/Goldens/genomes_real/\(name).flam3")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("real-genome fixture missing: \(url.path)")
        }
        return url
    }

    /// Read a PNG and return `(max channel value, fraction of non-black pixels)`.
    /// `nonBlack` counts pixels whose max(R,G,B) > 4 (matches the threshold in
    /// `RealGenomeRenderTests.testRealGenomeRendersNonBlack`).
    private func pngStats(_ url: URL) throws -> (maxChannel: UInt8, nonBlackFrac: Double) {
        let img = try RGBA8Image.readPNG(from: url)
        var maxChannel: UInt8 = 0
        var nonBlack = 0
        let px = img.pixels
        var i = 0
        while i + 3 < px.count {
            let m = max(px[i], px[i + 1], px[i + 2])
            if m > maxChannel { maxChannel = m }
            if m > 4 { nonBlack += 1 }
            i += 4
        }
        let pixels = max(1, px.count / 4)
        return (maxChannel, Double(nonBlack) / Double(pixels))
    }

    /// AC: `--temporal-samples 4 --backend cpu` dispatches the temporal path on
    /// the CPU renderer and produces non-black PNGs. Exercises out-of-range
    /// sub-times (real ES genomes: `temporal_filter_width="1.2"` → sub-times
    /// span `mapping.blend ± 0.6`, e.g. `0.25 ± 0.6 = [-0.35, 0.85]`).
    func testTemporalSamples4CPUIsNonBlack() throws {
        let g0 = try realFixture("electricsheep.248.00256")
        let g1 = try realFixture("electricsheep.248.00000")
        let out = freshOut("temporal_cpu")

        let code = EmberweftCLI.run([
            "emberweft", "animate", g0.path, g1.path,
            "--frames", "2", "--segments", "2",
            "--temporal-samples", "4",
            "--seed", "0", "--backend", "cpu", "--out", out.path,
            "--size", "160x120", "--quality", "50",
        ])
        XCTAssertEqual(code, 0)

        // 2 segments × 2 frames = 4 PNGs.
        for i in 0..<4 {
            let name = String(format: "%06d.png", i)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: out.appendingPathComponent(name).path),
                "Missing frame \(name)")
        }

        // At least one frame must be non-black. (00256 + 00000 are real ES
        // genomes with bright palettes — even with only 4*50 = 200 effective
        // spp per frame, the brightest pixels are well above the >4 threshold.)
        var anyNonBlack = false
        for i in 0..<4 {
            let name = String(format: "%06d.png", i)
            let stats = try pngStats(out.appendingPathComponent(name))
            if stats.maxChannel > 0 { anyNonBlack = true }
        }
        XCTAssertTrue(anyNonBlack, "temporal CPU render produced ALL-black frames")
    }

    /// AC: `--temporal-samples 4 --backend metal` dispatches the Metal temporal
    /// fused path and produces non-black PNGs. Skipped on GPU-less machines /
    /// under the bash sandbox (`MTLCreateSystemDefaultDevice()` returns nil).
    func testTemporalSamples4MetalIsNonBlack() throws {
        let metalOK = MainActor.assumeIsolated { MetalRenderer.isAvailable }
        try XCTSkipUnless(metalOK, "Metal unavailable")
        let g0 = try realFixture("electricsheep.248.00256")
        let g1 = try realFixture("electricsheep.248.00000")
        let out = freshOut("temporal_metal")

        let code = EmberweftCLI.run([
            "emberweft", "animate", g0.path, g1.path,
            "--frames", "4", "--segments", "2",
            "--temporal-samples", "4",
            "--seed", "0", "--backend", "metal", "--out", out.path,
            "--size", "160x120", "--quality", "50",
        ])
        XCTAssertEqual(code, 0)

        // 2 segments × 4 frames = 8 PNGs.
        for i in 0..<8 {
            let name = String(format: "%06d.png", i)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: out.appendingPathComponent(name).path),
                "Missing frame \(name)")
        }
        var anyNonBlack = false
        for i in 0..<8 {
            let name = String(format: "%06d.png", i)
            let stats = try pngStats(out.appendingPathComponent(name))
            if stats.maxChannel > 0 { anyNonBlack = true }
        }
        XCTAssertTrue(anyNonBlack, "temporal Metal render produced ALL-black frames")
    }

    /// AC: `--temporal-samples 1` (explicit) must be BYTE-IDENTICAL to the
    /// no-flag path — the N==1 branch falls through to `render(flame:
    /// blendAt(mapping.blend), params:)`, which equals the pre-blur path's
    /// `render(flame: renderedFlame, params:)`. CPU single-threaded → bit-stable.
    func testTemporalSamples1IsByteIdenticalToNoFlag() throws {
        let a = tmp(genomeA, name: "anim_ts1_a.flam3")
        let b = tmp(genomeB, name: "anim_ts1_b.flam3")
        let out1 = freshOut("ts1_explicit")
        let out2 = freshOut("ts1_noflag")

        let args: [String] = [
            "--frames", "2", "--segments", "2",
            "--seed", "0", "--backend", "cpu",
            "--size", "16x16", "--quality", "10",
        ]
        let code1 = EmberweftCLI.run([
            "emberweft", "animate", a.path, b.path,
        ] + args + ["--temporal-samples", "1", "--out", out1.path])
        let code2 = EmberweftCLI.run([
            "emberweft", "animate", a.path, b.path,
        ] + args + ["--out", out2.path])
        XCTAssertEqual(code1, 0)
        XCTAssertEqual(code2, 0)

        // Manifests identical (no `temporalSamples` field → identical schema).
        let m1 = try Data(contentsOf: out1.appendingPathComponent("manifest.json"))
        let m2 = try Data(contentsOf: out2.appendingPathComponent("manifest.json"))
        XCTAssertEqual(m1, m2, "manifest.json must be byte-identical for N=1 vs no flag")

        // PNGs byte-identical.
        for i in 0..<4 {
            let name = String(format: "%06d.png", i)
            let p1 = try Data(contentsOf: out1.appendingPathComponent(name))
            let p2 = try Data(contentsOf: out2.appendingPathComponent(name))
            XCTAssertEqual(p1, p2, "frame \(name) must be byte-identical for N=1 vs no flag")
        }
    }

    /// AC: `--temporal-samples N` where N > 64 on Metal is capped to 64 with a
    /// printed stderr note (NOT silent). The note is observable via `EmberweftCLI.err`.
    /// Expects 8 PNGs (frames×segments = 4×2) on Metal after capping.
    func testTemporalSamplesCappedTo64OnMetalWithNote() throws {
        let metalOK = MainActor.assumeIsolated { MetalRenderer.isAvailable }
        try XCTSkipUnless(metalOK, "Metal unavailable")
        let g0 = try realFixture("electricsheep.248.00256")
        let g1 = try realFixture("electricsheep.248.00000")
        let out = freshOut("temporal_cap_explicit")

        // Capture stderr (the cap note is printed there).
        var captured = ""
        let originalErr = EmberweftCLI.err
        EmberweftCLI.err = { captured += $0 }
        defer { EmberweftCLI.err = originalErr }

        let code = EmberweftCLI.run([
            "emberweft", "animate", g0.path, g1.path,
            "--frames", "2", "--segments", "2",
            "--temporal-samples", "1000",       // way over the Metal cap of 64
            "--seed", "0", "--backend", "metal", "--out", out.path,
            "--size", "80x60", "--quality", "20",
        ])
        XCTAssertEqual(code, 0)

        // The cap note must mention both the original value (1000) and the cap (64).
        XCTAssertTrue(captured.contains("--temporal-samples 1000 capped to 64"),
                      "expected cap note on stderr; got:\n\(captured)")

        // 2 segments × 2 frames = 4 PNGs after the cap.
        for i in 0..<4 {
            let name = String(format: "%06d.png", i)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: out.appendingPathComponent(name).path),
                "Missing frame \(name) after Metal cap")
        }
    }

    /// AC (defaulting): with NO `--temporal-samples` flag, the effective N
    /// defaults to the genome's `quality.temporalSamples`. Real ES genomes carry
    /// `temporal_samples="1000"` → on Metal this is observable as the cap note
    /// (1000 → capped to 64). On CPU the default is uncapped but only
    /// observable via image (slow), so we only assert the cap-note path here.
    /// `err` capture proves the defaulting kicked in (without it, N would stay
    /// at the parse-time default of 1 and no note would be printed).
    func testTemporalSamplesDefaultsToGenomeValueOnMetal() throws {
        let metalOK = MainActor.assumeIsolated { MetalRenderer.isAvailable }
        try XCTSkipUnless(metalOK, "Metal unavailable")
        let g0 = try realFixture("electricsheep.248.00256")
        let g1 = try realFixture("electricsheep.248.00000")
        let out = freshOut("temporal_default")

        // Genome-default check: the fixture must actually declare temporal_samples=1000
        // (otherwise this test would silently pass for the wrong reason).
        let g0Data = try Data(contentsOf: g0)
        let parsed = try XCTUnwrap(Flam3Parser.parse(g0Data).first)
        XCTAssertEqual(parsed.quality.temporalSamples, 1000,
                       "fixture changed: expected temporal_samples=1000")

        var captured = ""
        let originalErr = EmberweftCLI.err
        EmberweftCLI.err = { captured += $0 }
        defer { EmberweftCLI.err = originalErr }

        // NOTE: no `--temporal-samples` flag — relies on the genome default (1000).
        let code = EmberweftCLI.run([
            "emberweft", "animate", g0.path, g1.path,
            "--frames", "2", "--segments", "2",
            "--seed", "0", "--backend", "metal", "--out", out.path,
            "--size", "80x60", "--quality", "20",
        ])
        XCTAssertEqual(code, 0)

        // The genome value (1000) was picked up and capped to 64 on Metal.
        XCTAssertTrue(captured.contains("--temporal-samples 1000 capped to 64"),
                      "defaulting+capping note missing; got:\n\(captured)")
    }

    /// AC (Loop-unclamped regression): `Loop.blend` is NOT clamped in the CLI's
    /// temporal path. Loop is pure affine rotation (`sheep_loop`: θ = t·360°·cycles
    /// on the pre-affine 2×2 only; palette and `xform.color` are STATIC during a
    /// loop), so out-of-range sub-times are well-defined (R(540°) == R(180°) within
    /// FP residual) and are exactly the continuous-rotation temporal blur we want.
    /// Clamping Loop would freeze boundary frames.
    ///
    /// This test proves the un-clamped behavior three ways:
    ///   (1) Direct render with UN-CLAMPED closure vs FORCE-CLAMPED closure →
    ///       they MUST differ (clamping changes the rotation).
    ///   (2) The un-clamped render is non-black (smoke check).
    ///   (3) The CLI's actual loop-segment render is BYTE-IDENTICAL to the
    ///       direct un-clamped render → proves the CLI uses the un-clamped path
    ///       (not the clamped one).
    ///
    /// Setup: `--frames 1 --segments 1` produces one loop frame at
    /// `centerTime = blend = 1.0`; with `width=1.2, N=4`, sub-times are
    /// `[0.4, 0.8, 1.2, 1.6]` — two of four are > 1 (the boundary case where
    /// clamping vs not-clamping diverges).
    func testLoopBlendUnclampedInTemporalPath() throws {
        let g = try realFixture("electricsheep.248.00256")
        let flame = try XCTUnwrap(Flam3Parser.parse(Data(contentsOf: g)).first,
                                  "fixture parse failed")
        let p = RenderParams(seed: 0, width: 80, height: 60,
                             oversample: 1, samplesPerPixel: 50)
        let (temporal, sumfilt) = TemporalFilter.samples(
            4,
            type:  flame.quality.temporalFilterType,
            width: flame.quality.temporalFilterWidth,
            exp:    flame.quality.temporalFilterExp)

        // (1) Direct renders: un-clamped (faithful) vs force-clamped (counterfactual).
        let unclamped = ReferenceRenderer.render(
            blendAt: { t in Loop.blend(flame, t: t, cycles: 1) },
            centerTime: 1.0,
            temporal: temporal, sumfilt: sumfilt, params: p)
        let forceClamped = ReferenceRenderer.render(
            blendAt: { t in Loop.blend(flame, t: min(max(t, 0.0), 1.0), cycles: 1) },
            centerTime: 1.0,
            temporal: temporal, sumfilt: sumfilt, params: p)
        XCTAssertNotEqual(unclamped.pixels, forceClamped.pixels,
            "Loop un-clamped vs force-clamped must differ at sub-times > 1 — clamping replaces R(576°)≈R(216°) with R(360°)≈R(0°), a real rotation change")

        // (2) Smoke: un-clamped render is non-black.
        let maxChan = unclamped.pixels.max() ?? 0
        XCTAssertGreaterThan(maxChan, 0, "un-clamped loop temporal render is all-black")

        // (3) CLI byte-identity: the CLI's loop-segment render must match the
        // un-clamped direct render exactly (CPU single-threaded → byte-deterministic).
        // Passing the same sheep twice satisfies the ≥2-sheep guard; with
        // `--segments 1` only segment 0 (loop) is emitted.
        let out = freshOut("loop_unclamped_cli")
        let code = EmberweftCLI.run([
            "emberweft", "animate", g.path, g.path,
            "--frames", "1", "--segments", "1",
            "--temporal-samples", "4",
            "--seed", "0", "--backend", "cpu", "--out", out.path,
            "--size", "80x60", "--quality", "50",
        ])
        XCTAssertEqual(code, 0)
        let cliImg = try RGBA8Image.readPNG(from: out.appendingPathComponent("000000.png"))
        XCTAssertEqual(cliImg.pixels, unclamped.pixels,
            "CLI loop-segment temporal render must be byte-identical to the un-clamped direct render — proves the CLI does NOT clamp Loop")
    }

    /// AC (frame→blend delta scaling regression): `temporal_filter_width` is in
    /// FRAME-TIME units (flam3 animation time = frame index), but
    /// `mapping.blend` is normalized [0,1] per segment. The CLI MUST scale each
    /// temporal delta by `1/framesPerSegment` before building the temporal array,
    /// so the blur window is ±width/2 FRAMES (≈±0.15 blend at fps=4, width=1.2),
    /// NOT ±width/2 of the WHOLE SEGMENT (which would average >½ revolution of
    /// rotation for a loop → collapse to the rotationally-averaged static
    /// attractor; observed bug: "loop is static, only noise").
    ///
    /// This test would have caught the bug. Three assertions:
    ///   (1) Unit check on the scaling math: raw deltas are ±width/2 in frame
    ///       units; scaled deltas are ±width/(2·fps). For width=1.2, fps=4:
    ///       raw max |delta| = 0.6, scaled max |delta| = 0.15.
    ///   (2) Scaling MATTERS: rendering the same Loop frame with raw (bug) vs
    ///       scaled (fix) deltas produces DIFFERENT images (the rotational blur
    ///       window differs by 4×).
    ///   (3) CLI byte-identity: the CLI's loop-segment render at frame 2
    ///       (centerTime=0.75) is byte-identical to the direct scaled-delta
    ///       render — proves the CLI applies the 1/fps scaling, not the raw
    ///       frame-unit deltas.
    func testTemporalBlurDeltaScaledToBlendUnits() throws {
        let g = try realFixture("electricsheep.248.00256")
        let flame = try XCTUnwrap(Flam3Parser.parse(Data(contentsOf: g)).first,
                                  "fixture parse failed")
        let p = RenderParams(seed: 0, width: 80, height: 60,
                             oversample: 1, samplesPerPixel: 100)
        let fps: Double = 4   // mirror --frames 4

        // Raw frame-unit deltas (the bug — directly from TemporalFilter, no scaling).
        let (rawTemporal, sumfilt) = TemporalFilter.samples(
            4,
            type:  flame.quality.temporalFilterType,
            width: flame.quality.temporalFilterWidth,
            exp:    flame.quality.temporalFilterExp)
        // FIX: deltas scaled by 1/fps (what the CLI does after the fix).
        let scaledTemporal: [(delta: Double, weight: Double)] = rawTemporal.map {
            (delta: $0.delta / fps, weight: $0.weight)
        }

        // (1) Scaling math.
        let maxRaw = rawTemporal.map { abs($0.delta) }.max() ?? 0
        let maxScaled = scaledTemporal.map { abs($0.delta) }.max() ?? 0
        XCTAssertEqual(maxRaw, 0.6, accuracy: 1e-9,
                       "raw delta max = width/2 = 0.6 for width=1.2")
        XCTAssertEqual(maxScaled, 0.6 / fps, accuracy: 1e-9,
                       "scaled delta max = width/(2·fps) = 0.15 for fps=4")

        // (2) Bug vs fix must produce DIFFERENT images. The bug's blur window
        // is ±0.6 blend = ±216° rotation (more than half a revolution averaged);
        // the fix's is ±0.15 blend = ±54°. Very different blur windows → very
        // different images.
        let bugBlur = ReferenceRenderer.render(
            blendAt: { t in Loop.blend(flame, t: t, cycles: 1) },
            centerTime: 0.75,
            temporal: rawTemporal, sumfilt: sumfilt, params: p)
        let fixBlur = ReferenceRenderer.render(
            blendAt: { t in Loop.blend(flame, t: t, cycles: 1) },
            centerTime: 0.75,
            temporal: scaledTemporal, sumfilt: sumfilt, params: p)
        let bugVsFixPSNR = ImageComparison.psnr(bugBlur, fixBlur)
        XCTAssertLessThan(bugVsFixPSNR, 20.0,
            "Bug (raw frame-unit deltas, ±0.6 blend window = ±216° rotation) vs fix (scaled deltas, ±0.15 blend = ±54°) must produce radically different images (PSNR < 20 dB). Got \(bugVsFixPSNR) dB — if PSNR is high, the scaling is being skipped or applied incorrectly.")

        // (3) CLI byte-identity: the CLI's frame 2 (frames=4 → blend = (2+1)/4 = 0.75)
        // must match the FIX render exactly. If the CLI used raw deltas (bug), it
        // would match bugBlur instead. CPU single-threaded → byte-deterministic.
        let out = freshOut("loop_cli_scaled")
        let code = EmberweftCLI.run([
            "emberweft", "animate", g.path, g.path,
            "--frames", "4", "--segments", "1",
            "--temporal-samples", "4",
            "--seed", "0", "--backend", "cpu", "--out", out.path,
            "--size", "80x60", "--quality", "100",
        ])
        XCTAssertEqual(code, 0)
        let cliImg = try RGBA8Image.readPNG(from: out.appendingPathComponent("000002.png"))
        XCTAssertEqual(cliImg.pixels, fixBlur.pixels,
            "CLI's loop-segment temporal render at frame 2 must match the fix (scaled deltas) render byte-for-byte — proves the CLI applies the 1/fps scaling rather than passing raw frame-unit deltas.")
    }
}
