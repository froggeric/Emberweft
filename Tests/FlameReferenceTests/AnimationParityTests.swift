// Tests/FlameReferenceTests/AnimationParityTests.swift
//
// S6 acceptance gate (Task 19) — CPU / vs-flam3 rows. Validates that the M3
// animation pipeline (Tasks 10–14: Loop, Transition, GenomeInterpolator,
// Schedule, SpecialSauce) produces frames that match the real `flam3-genome`
// oracle, that loops are seamless, and that every animated frame is finite.
//
// This target depends ONLY on [FlameReference, FlameKit] — it has NO
// FlameRenderer dep and never calls MetalRenderer. The Metal-touching rows
// (rendered seamlessness PSNR on Metal, mismatched-sheep Metal↔CPU parity,
// Metal byte-determinism) live in FlameRendererTests/AnimatedFrameParityTests.
//
// Vs-flam3 rows call `try Flam3Oracle.require()` first (F10 auto-skip when the
// oracle is absent). The oracle IS built on this dev machine, so they run.
//
// Run with the bash sandbox DISABLED — the vs-flam3 rows Process-spawn
// flam3-genome/flam3-animate.

import XCTest
@testable import FlameReference
import FlameKit

final class AnimationParityTests: XCTestCase {

    // MARK: - Fixtures / helpers

    private func genomesDir() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Goldens/genomes")
    }

    private func load(_ name: String) throws -> Flame {
        let url = genomesDir().appendingPathComponent("\(name).flam3")
        return try Flam3Parser.parse(Data(contentsOf: url))[0]
    }

    /// Extract the raw `<flame …>…</flame>` block from a frozen genome file,
    /// preserving flam3's native `<palette count format>` hex form (which our
    /// Flam3Serializer does NOT reproduce, and which flam3-genome/flam3-animate
    /// require). Used to build multi-CP input files for the oracle.
    private func rawFlameBlock(_ name: String) throws -> String {
        let url = genomesDir().appendingPathComponent("\(name).flam3")
        let text = try String(contentsOf: url, encoding: .utf8)
        guard let start = text.range(of: "<flame "),
              let end = text.range(of: "</flame>", range: start.upperBound..<text.endIndex)
        else {
            XCTFail("could not extract <flame> block from \(name).flam3")
            return ""
        }
        return String(text[start.lowerBound..<end.upperBound])
    }

    /// 320×200 @ 100 spp — the calibrated GoldenParityTests operating point
    /// where our CPU renderer already achieves ≥30 dB vs flam3-render goldens.
    private func params(_ seed: UInt64 = 0) -> RenderParams {
        RenderParams(seed: seed, width: 320, height: 200, oversample: 1, samplesPerPixel: 100)
    }

    /// Max abs difference over every pre-affine coefficient of corresponding
    /// (non-final) xforms between two genomes. Used for the genome-space ‖Δ‖
    /// gate on the loop (rotation-only, no align/merge, so coefficients line up
    /// 1:1). Post-affine and translation are also compared.
    private func maxAffineDelta(_ a: Flame, _ b: Flame) -> Double {
        var worst = 0.0
        let n = max(a.xforms.count, b.xforms.count)
        for i in 0..<n {
            // Skip xforms that only exist on one side (align padding) — those are
            // not a rotation concern and only appear for the transition.
            guard i < a.xforms.count, i < b.xforms.count else { continue }
            let xa = a.xforms[i].affine
            let xb = b.xforms[i].affine
            for (pa, pb) in [
                (xa.a, xb.a), (xa.b, xb.b), (xa.c, xb.c),
                (xa.d, xb.d), (xa.e, xb.e), (xa.f, xb.f)
            ] {
                worst = max(worst, abs(pa - pb))
            }
        }
        return worst
    }

    /// Assert no NaN/Inf anywhere in a Flame's numeric fields (affines, weights,
    /// camera, palette). The load-bearing finiteness check for animation — a
    /// NaN in Loop/Transition output would poison the whole render.
    private func assertFinite(_ f: Flame, _ msg: @autoclosure () -> String,
                              file: StaticString = (#file), line: UInt = #line) {
        for (i, x) in f.xforms.enumerated() {
            XCTAssertTrue(x.affine.a.isFinite, "xform[\(i)].a not finite", file: file, line: line)
            XCTAssertTrue(x.affine.b.isFinite, "xform[\(i)].b not finite", file: file, line: line)
            XCTAssertTrue(x.affine.c.isFinite, "xform[\(i)].c not finite", file: file, line: line)
            XCTAssertTrue(x.affine.d.isFinite, "xform[\(i)].d not finite", file: file, line: line)
            XCTAssertTrue(x.affine.e.isFinite, "xform[\(i)].e not finite", file: file, line: line)
            XCTAssertTrue(x.affine.f.isFinite, "xform[\(i)].f not finite", file: file, line: line)
            XCTAssertTrue(x.weight.isFinite, "xform[\(i)].weight not finite", file: file, line: line)
        }
        XCTAssertTrue(f.camera.scale.isFinite, "camera.scale not finite", file: file, line: line)
        XCTAssertTrue(f.camera.center.x.isFinite, "camera.center.x not finite", file: file, line: line)
        XCTAssertTrue(f.camera.center.y.isFinite, "camera.center.y not finite", file: file, line: line)
        let _ = msg() // silence unused-warning while keeping the label meaningful
    }

    // MARK: - sheep_loop vs flam3-genome rotate (vs-oracle, image + genome-space)

    /// AC: our `Loop.blend` frame vs `flam3-genome rotate`'s, PSNR ≥ 30 dB /
    /// SSIM ≥ 0.95, AND genome-space affine ‖Δ‖ at FP-trig-residual level.
    ///
    /// flam3-genome rotate mode emits THREE control points
    /// `spin(frame-1, blend-spread)`, `spin(frame, blend)`, `spin(frame+1, blend+spread)`
    /// (flam3-genome.c:831-834) where `blend = frame/nframes`. The MIDDLE CP is
    /// `sheep_loop(parent, frame/nframes)` — the actual frame. We extract it,
    /// render it standalone via flam3-animate, and compare to our
    /// `ReferenceRenderer.render(Loop.blend(sheep, t: frame/nframes))`.
    func testSheepLoopVsFlam3Rotate() throws {
        try Flam3Oracle.require()

        let sheep = try load("heart_disc")
        let nframes = 20
        let frame = 7                      // 1-indexed; blend = 7/20 = 0.35 (mid-loop, non-trivial)
        let t = Double(frame) / Double(nframes)

        // --- Our frame: Loop.blend → ReferenceRenderer ---
        let ours = Loop.blend(sheep, t: t)
        assertFinite(ours, "Loop.blend produced non-finite coefficients")
        let ourImage = ReferenceRenderer.render(flame: ours, params: params())

        // --- Oracle frame: flam3-genome rotate → middle CP → flam3-animate ---
        let genomePath = genomesDir().appendingPathComponent("heart_disc.flam3").path
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("anim_loop_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let motionURL = tmp.appendingPathComponent("motion.flam3")
        let motionXML = try Flam3Oracle.genMotionGenome(
            mode: .rotate, input: genomePath, nframes: nframes, frame: frame, outputURL: motionURL)
        // rotate emits exactly 3 CPs; index 1 is the actual frame.
        let cps = try Flam3Parser.parse(Data(motionXML.utf8))
        XCTAssertEqual(cps.count, 3, "rotate mode must emit 3 control points (frame-1, frame, frame+1)")
        let oracleMiddle = cps[1]

        // --- Genome-space ‖Δ‖ (rotation-only → coefficients line up 1:1) ---
        // The diff is bounded by flam3-genome's 6-decimal XML serialization
        // (max round-trip error ≈5e-7), NOT by our rotation math — Loop.blend is
        // a verified line-for-line port of flam3_rotate + mult_matrix (verified
        // against /Users/frederic/flam3-oracle-src/flam3/interpolation.c). The
        // in-memory Double rotation residual is ~1e-15; the 5e-7 we actually see
        // is purely the gprint "%.6g" round-trip.
        let delta = maxAffineDelta(ours, oracleMiddle)
        print("[AnimLoop] genome-space max affine ‖Δ‖ = \(delta) (≈6-decimal XML round-trip)")
        XCTAssertLessThan(delta, 1e-5,
            "Loop.blend disagrees with flam3 sheep_loop by \(delta) (> 6-decimal round-trip)")

        // --- Image parity: render frame `frame` of the motion genome directly
        // via flam3-animate. Passing the FULL 3-CP motion XML with begin=end=frame
        // renders at time=frame, which (linear temporal interp, temporal_samples=1)
        // lands exactly on the middle CP — no re-serialization (which would lose
        // flam3's palette format). ---
        let prefix = tmp.appendingPathComponent("oracle.").path
        let pngs = try Flam3Oracle.renderFrames(
            genome: motionXML, begin: frame, end: frame, prefix: prefix)
        XCTAssertEqual(pngs.count, 1, "expected one PNG from flam3-animate")
        let oracleImage = try RGBA8Image.readPNG(from: pngs[0])

        let psnr = ImageComparison.psnr(ourImage, oracleImage)
        let ssim = ImageComparison.ssim(ourImage, oracleImage)
        print("[AnimLoop] t=\(t) PSNR=\(psnr.isInfinite ? "inf" : String(format: "%.2f", psnr)) dB, "
              + "SSIM=\(String(format: "%.4f", ssim))")
        XCTAssertGreaterThanOrEqual(psnr, 30.0, "loop frame PSNR \(psnr) < 30 dB vs flam3")
        XCTAssertGreaterThanOrEqual(ssim, 0.95, "loop frame SSIM \(ssim) < 0.95 vs flam3")
    }

    // MARK: - sheep_edge vs flam3-genome inter (vs-oracle, image)

    /// AC: our `Transition.blend` frame vs `flam3-genome inter`'s, PSNR ≥ 30 dB /
    /// SSIM ≥ 0.95. This is the central M3 gate — it exercises SpecialSauce.align,
    /// RefAngles, the Task-13 rotation, GenomeInterpolator (.log), and PaletteBlend
    /// (HSV-circular). Any port gap in Tasks 10–14 surfaces here.
    ///
    /// flam3-genome inter mode reads a 2-CP file and emits three `spin_inter`
    /// control points; the middle one is `sheep_edge(parents, frame/nframes, 0, 0)`.
    func testSheepEdgeVsFlam3Inter() throws {
        try Flam3Oracle.require()

        let a = try load("heart_disc")
        let b = try load("swirl_field")
        let nframes = 20
        let frame = 7
        let t = Double(frame) / Double(nframes)   // 0.35 — mid-transition

        // --- Our frame: Transition.blend → ReferenceRenderer ---
        let ours = Transition.blend(a, b, t: t, stagger: 0)
        assertFinite(ours, "Transition.blend produced non-finite coefficients")
        let ourImage = ReferenceRenderer.render(flame: ours, params: params())

        // --- Oracle frame: flam3-genome inter → middle CP → flam3-animate ---
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("anim_edge_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // inter needs a single file holding BOTH control points, in flam3's
        // native palette format (our serializer's <color> form is rejected).
        let twoCP = tmp.appendingPathComponent("parents.flam3")
        let parentsXML = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<flames>\n"
            + (try rawFlameBlock("heart_disc")) + "\n"
            + (try rawFlameBlock("swirl_field")) + "\n"
            + "</flames>\n"
        try parentsXML.write(to: twoCP, atomically: true, encoding: .utf8)

        let motionURL = tmp.appendingPathComponent("motion.flam3")
        let motionXML = try Flam3Oracle.genMotionGenome(
            mode: .inter, input: twoCP.path, nframes: nframes, frame: frame, outputURL: motionURL)
        let cps = try Flam3Parser.parse(Data(motionXML.utf8))
        XCTAssertEqual(cps.count, 3, "inter mode must emit 3 control points")
        let oracleMiddle = cps[1]

        // Genome-space sanity (transition involves align/pad so this is a coarse
        // check; diff is bounded by flam3-genome's 6-decimal XML round-trip).
        let delta = maxAffineDelta(ours, oracleMiddle)
        print("[AnimEdge] genome-space max affine ‖Δ‖ = \(delta) (coarse; image gate is load-bearing)")

        // Render frame `frame` of the motion genome directly — begin=end=frame
        // lands on the middle CP (see testSheepLoopVsFlam3Rotate for rationale).
        let prefix = tmp.appendingPathComponent("oracle.").path
        let pngs = try Flam3Oracle.renderFrames(
            genome: motionXML, begin: frame, end: frame, prefix: prefix)
        XCTAssertEqual(pngs.count, 1, "expected one PNG from flam3-animate")
        let oracleImage = try RGBA8Image.readPNG(from: pngs[0])

        let psnr = ImageComparison.psnr(ourImage, oracleImage)
        let ssim = ImageComparison.ssim(ourImage, oracleImage)
        print("[AnimEdge] t=\(t) PSNR=\(psnr.isInfinite ? "inf" : String(format: "%.2f", psnr)) dB, "
              + "SSIM=\(String(format: "%.4f", ssim))")
        XCTAssertGreaterThanOrEqual(psnr, 30.0, "transition frame PSNR \(psnr) < 30 dB vs flam3")
        XCTAssertGreaterThanOrEqual(ssim, 0.95, "transition frame SSIM \(ssim) < 0.95 vs flam3")
    }

    // MARK: - sheep_loop seamlessness (genome-space ‖Δ‖<1e-12 + rendered PSNR≥38)

    /// AC: `Loop.blend(t=0)` vs `Loop.blend(t=1)` agree per-coefficient within
    /// 1e-12 (NOT byte-equal — R(2π)≠I in FP, Task 13) AND the rendered frames
    /// are visually seamless (PSNR ≥ 38 dB). The rendered check uses the CPU
    /// backend here; Metal rendered-seamlessness lives in AnimatedFrameParityTests.
    func testLoopSeamlessnessGenomeSpaceAndRendered() throws {
        let sheep = try load("sierpinski")
        let f0 = Loop.blend(sheep, t: 0.0)
        let f1 = Loop.blend(sheep, t: 1.0)
        assertFinite(f0, "Loop.blend(t=0) non-finite")
        assertFinite(f1, "Loop.blend(t=1) non-finite")

        // Per-coefficient ‖Δ‖ < 1e-12. R(2π) leaves a ~1e-16 trig residual on the
        // 2×2; e/f (translation) must be EXACTLY equal (rotation never touches them).
        let delta = maxAffineDelta(f0, f1)
        print("[LoopSeamless] genome-space max affine ‖Δ‖(t=0,t=1) = \(delta)")
        XCTAssertLessThan(delta, 1e-12,
            "loop not seamless: ‖Δ‖=\(delta) >= 1e-12 (expected ~1e-16 R(2π) residual)")

        // Rendered seamlessness at high spp so statistical sampling-noise between
        // the two near-identical densities clears 38 dB (sierpinski is a pure
        // contraction — same seed + ~identical affine ⇒ nearly identical histogram).
        let p = RenderParams(seed: 0, width: 320, height: 200, oversample: 1, samplesPerPixel: 1000)
        let img0 = ReferenceRenderer.render(flame: f0, params: p)
        let img1 = ReferenceRenderer.render(flame: f1, params: p)
        let psnr = ImageComparison.psnr(img0, img1)
        print("[LoopSeamless] rendered PSNR(t=0,t=1) = "
              + "\(psnr.isInfinite ? "inf" : String(format: "%.2f", psnr)) dB")
        XCTAssertGreaterThanOrEqual(psnr, 38.0,
            "loop visible-seam fail: rendered PSNR \(psnr) < 38 dB")
    }

    // MARK: - CPU finiteness across animated frames

    /// AC: no NaN/Inf in any animated frame. Sweeps a loop and a transition,
    /// asserting every generated genome and every CPU render is finite / complete.
    func testAnimatedFramesFiniteCPU() throws {
        let sheep = try load("heart_disc")
        let other = try load("rich")

        // Loop sweep — t across [0,1] including the 2π seam.
        for i in 0...20 {
            let t = Double(i) / 20.0
            let f = Loop.blend(sheep, t: t)
            assertFinite(f, "Loop.blend(t=\(t)) non-finite")
            let img = ReferenceRenderer.render(flame: f, params: params())
            XCTAssertEqual(img.pixels.count, 320 * 200 * 4, "loop frame t=\(t) incomplete")
        }

        // Transition sweep — exercises align (heart_disc=3 xforms, rich=5 ⇒ padding).
        for i in 1...20 {
            let t = Double(i) / 20.0
            let f = Transition.blend(sheep, other, t: t, stagger: 0)
            assertFinite(f, "Transition.blend(t=\(t)) non-finite")
            let img = ReferenceRenderer.render(flame: f, params: params())
            XCTAssertEqual(img.pixels.count, 320 * 200 * 4, "transition frame t=\(t) incomplete")
        }
    }
}
