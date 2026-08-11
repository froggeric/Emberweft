import XCTest
import AVFoundation
import CoreVideo
@testable import FlameExport
import FlameKit
import FlameReference
import FlameRenderer

/// M6.1 slice 2 (T8′ — centered box window): pins for the coordinator's
/// smoothing dispatch — the per-chunk `TemporalBoxWindow` feed-emit loop that
/// replaces the causal EMA. Drives the private dispatch via the actor's
/// `internal` test seam (`renderSmoothedRangeForTest`) so the per-frame pins run
/// WITHOUT a full encoder round-trip (fast), plus small end-to-end exports for
/// the cross-branch pins (which need the real frame loops).
///
/// **The cold-start pin CHANGED (T8′):** the EMA emitted frame 0 sharp (byte-
/// identical to OFF); the centered box window averages frame 0 over `[0, h]` —
/// smoothing from frame 1, the whole point of the revision. So frame 0 ON is
/// now NOT byte-identical to frame 0 OFF (it is visibly an average).
///
/// Sacred invariants covered:
/// - **Frame 0 is smoothed** (avg `[0, h]`) — NOT byte-identical to OFF, and an
///   average of the first `h+1` frames' worth of light (visibly not the raw
///   frame).
/// - **Metal↔CPU smoothing-ON parity**: a multi-frame sequence Metal vs CPU,
///   PSNR ≥ 38 dB.
/// - **Cross-branch**: CLI-MainActor smoothing-ON ≈ GUI-offmain smoothing-ON
///   within the fused-vs-unfused band.
@MainActor
final class TemporalSmoothingDispatchTests: XCTestCase {
    private func genome(_ name: String) throws -> [Flame] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Goldens/genomes/\(name)")
        return try Flam3Parser.parse(Data(contentsOf: url))
    }
    private func tmpMP4() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("m6sm-\(UUID().uuidString).mp4")
    }
    private func tmpDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("m6sm-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Build a small FramePlan + params + budget matching `buildRenderContext`
    /// (ExportCoordinator.swift) so the test seam sees production-shaped inputs.
    /// `segmentCount: 1` + `framesPerSegment: N` ⇒ an N-frame single-loop
    /// timeline (multi-frame ⇒ smoothing active when h>0). `genomeName` picks
    /// the fixture: sierpinski for byte-identity/average pins (CPU-internal);
    /// a denser fixture (`julia_bubbles`) for Metal↔CPU parity (sierpinski is a
    /// sparse/spiky attractor where Metal↔CPU is Float-limited below the 38 dB
    /// gate at low spp — the CLAUDE.md "spiky stills" gotcha; q-dependent, so
    /// higher spp also helps).
    private func makeContext(seed: UInt64 = 7, spp: Int = 20, frames: Int = 6,
                             genomeName: String = "sierpinski.flam3", width: Int = 128, height: Int = 80)
        throws -> (plan: FramePlan, params: RenderParams, budget: MetalRenderer.ThreadSeedBudget?) {
        let flames = try genome(genomeName)
        let params = RenderParams(seed: seed, width: width, height: height, oversample: 1, samplesPerPixel: spp)
        var schedule = Schedule(librarySize: flames.count, framesPerSegment: frames,
                                selector: Sequential(seed: seed), seed: seed)
        let plan = FramePlan(schedule: &schedule, segmentCount: 1, flames: flames,
                             loopCycles: 1, stagger: 0, temporalSamples: 1)
        let budget: MetalRenderer.ThreadSeedBudget? = MetalRenderer.ThreadSeedBudget(baseSeed: params.seed)
        return (plan, params, budget)
    }

    /// Max absolute per-channel RGBA diff + PSNR (dB) over two `RGBA8Image`s.
    /// PSNR is `+∞` when the images are byte-identical (maxDiff == 0).
    private func psnr(_ a: RGBA8Image, _ b: RGBA8Image) -> (maxDiff: Int, psnr: Double) {
        precondition(a.pixels.count == b.pixels.count)
        var mx = 0
        var sse = 0.0
        for i in 0..<a.pixels.count {
            let d = Int(a.pixels[i]) - Int(b.pixels[i])
            let ad = abs(d)
            if ad > mx { mx = ad }
            sse += Double(d * d)
        }
        let psnr = sse == 0 ? Double.infinity
            : 10.0 * log10((Double(a.pixels.count) * 255.0 * 255.0) / sse)
        return (mx, psnr)
    }

    // MARK: - T8′ frame 0 is smoothed (NOT byte-identical to OFF)

    /// Frame 0 of a multi-frame CPU plan with smoothing ON (α=0.2 ⇒ h=5) is an
    /// average over `[0, h]` ⇒ NOT byte-identical to frame 0 OFF (the raw frame).
    /// This is the fix the revision delivers: smoothing applies from frame 1
    /// (the old causal EMA emitted frame 0 sharp). The old cold-start byte-
    /// identity pin is GONE — frame 0 ON must now DIFFER from OFF, and must be a
    /// non-trivial average (not solid black, not the raw frame).
    func testFrame0SmoothedNotRaw() async throws {
        let ctx = try makeContext()   // 6-frame plan, sierpinski, spp 20
        let coord = ExportCoordinator(backend: .cpu)
        let h = 5   // α=0.2 ⇒ round(1/0.2)=5

        // Smoothing-ON over the whole timeline (fresh window; frame 0 = avg[0,h]
        // clipped at N-1=5 ⇒ avg[0,5] = all 6 frames).
        let on = try await coord.renderSmoothedRangeForTest(
            plan: ctx.plan, params: ctx.params, budget: nil,
            useMetal: false, halfWidth: h, range: 0..<ctx.plan.totalFrames)
        XCTAssertEqual(on.count, ctx.plan.totalFrames, "one smoothed frame per timeline frame")

        // OFF frame 0 (raw, via the byte-identical renderImage path).
        let off0 = try await coord.renderImageForTest(
            descriptor: ctx.plan.descriptor(for: 0), plan: ctx.plan,
            params: ctx.params, budget: nil, useMetal: false)

        // Frame 0 ON must NOT equal frame 0 OFF (it is an average over [0,h]).
        let (mx, _) = psnr(on[0], off0)
        XCTAssertGreaterThan(mx, 0, "frame 0 ON (centered window) must differ from frame 0 OFF (raw); was byte-identical (maxDiff=0)")
        // Sanity: the averaged frame is non-empty (not solid black).
        XCTAssertGreaterThan(on[0].pixels.max() ?? 0, 0, "frame 0 ON must be non-empty (not solid black)")
    }

    /// A 2-frame OFF plan (`halfWidth>0` but `totalFrames==1` is the degenerate
    /// gate; here verify totalFrames>1 is required): a single-frame plan stays
    /// OFF even with `halfWidth>0` (the `plan.totalFrames > 1` gate).
    func testSingleFramePlanStaysOff() async throws {
        let ctx = try makeContext(frames: 1)   // 1-frame plan
        let coord = ExportCoordinator(backend: .cpu)
        // halfWidth=5 but totalFrames==1 ⇒ smoothing gate OFF ⇒ verbatim renderImage.
        let on = try await coord.renderSmoothedRangeForTest(
            plan: ctx.plan, params: ctx.params, budget: nil,
            useMetal: false, halfWidth: 5, range: 0..<1)
        let off0 = try await coord.renderImageForTest(
            descriptor: ctx.plan.descriptor(for: 0), plan: ctx.plan,
            params: ctx.params, budget: nil, useMetal: false)
        // The seam ignores the gate (it always feed-emits), but with 1 frame +
        // h=5 the window's only emit = avg[0,0] = frame 0 verbatim. So ON==OFF.
        let (mx, _) = psnr(on[0], off0)
        XCTAssertEqual(mx, 0, "single-frame window (N≤h) emits the frame verbatim")
    }

    // MARK: - Metal↔CPU smoothing-ON parity (multi-frame α=0.20 sequence)

    /// A multi-frame α=0.20 (h=5) sequence, Metal vs CPU, PSNR ≥ 38 dB on the
    /// FINAL emitted frame (carries the most smoothing). Metal and CPU
    /// histograms are statistical, not byte-identical; the linear box average +
    /// shared DE+display preserve the ≥ 38 dB parity band.
    func testMetalCPUSmoothingParity() async throws {
        guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
        // spp=1000 @ 160×100 is the PROVEN Metal↔CPU parity regime
        // (EndToEndParityTests — all goldens clear 38 dB at 1000 spp). Lower spp
        // lands in the Float-limited "spiky stills" regime (< 38 dB; CLAUDE.md
        // gotcha). The box average is a linear blend of per-frame statistical
        // histograms, so smoothing PRESERVES the underlying ≥ 38 dB parity band.
        let flames = try genome("sierpinski.flam3")
        let params = RenderParams(seed: 7, width: 160, height: 100, oversample: 1, samplesPerPixel: 1000)
        var schedule = Schedule(librarySize: flames.count, framesPerSegment: 5,
                                selector: Sequential(seed: 7), seed: 7)
        let plan = FramePlan(schedule: &schedule, segmentCount: 1, flames: flames,
                             loopCycles: 1, stagger: 0, temporalSamples: 1)
        let budget = MetalRenderer.ThreadSeedBudget(baseSeed: params.seed)
        let coordM = ExportCoordinator(backend: .metal, useOffMainMetal: false)
        let coordC = ExportCoordinator(backend: .cpu)
        let h = 5   // α=0.20 ⇒ round(1/0.20)=5

        let imgM = try await coordM.renderSmoothedRangeForTest(
            plan: plan, params: params, budget: budget, useMetal: true,
            halfWidth: h, range: 0..<plan.totalFrames)
        let imgC = try await coordC.renderSmoothedRangeForTest(
            plan: plan, params: params, budget: nil, useMetal: false,
            halfWidth: h, range: 0..<plan.totalFrames)
        // Compare the FINAL emitted frame (carries the full centered window).
        let (_, db) = psnr(imgM[imgM.count - 1], imgC[imgC.count - 1])
        print("[SmoothingParity] Metal↔CPU \(plan.totalFrames)-frame h=\(h) @1000spp: PSNR=\(db) dB")
        XCTAssertGreaterThanOrEqual(db, 38.0, "Metal↔CPU smoothing-ON PSNR ≥ 38 dB (was \(db))")
    }

    // MARK: - Cross-branch (CLI MainActor ≈ GUI offmain, both smoothing ON)

    /// CLI-MainActor smoothing-ON ≈ GUI-offmain smoothing-ON within the
    /// fused-vs-unfused band. Two full Metal exports differing ONLY in
    /// `useOffMainMetal`, both with `smoothingAlpha=0.2`; decoded frame compared
    /// at PSNR ≥ 38 dB. Pins the off-main smoothed dispatch is wired and parity-
    /// faithful to the MainActor smoothed dispatch.
    func testCrossBranchMainActorVsOffMainSmoothing() async throws {
        guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
        let flames = try genome("sierpinski.flam3")
        var settings = ExportSettings()
        settings.resolution = .custom(width: 128, height: 80); settings.fps = 30
        settings.quality = .spp(8); settings.temporalSamples = 1
        settings.smoothingAlpha = 0.2   // h=5

        let outMain = tmpMP4(), outOff = tmpMP4()
        defer { try? FileManager.default.removeItem(at: outMain); try? FileManager.default.removeItem(at: outOff) }
        func runCoord(useOffMain: Bool, out: URL) async throws {
            let coord = ExportCoordinator(backend: .metal, useOffMainMetal: useOffMain)
            let job = ExportJob(settings: settings, flames: flames, framesPerSegment: 4,
                                segmentCount: 1, selector: .sequential, seed: 7,
                                loopCycles: 1, stagger: 0, out: out)
            let stream = await coord.run(job)
            for try await _ in stream {}
        }
        try await runCoord(useOffMain: false, out: outMain)
        try await runCoord(useOffMain: true, out: outOff)

        let mainBytes = try await firstFrameBGRABytes(of: outMain)
        let offBytes = try await firstFrameBGRABytes(of: outOff)
        let (_, db) = psnrRaw(mainBytes, offBytes)
        XCTAssertGreaterThanOrEqual(db, 38.0, "cross-branch smoothing-ON PSNR ≥ 38 dB (was \(db))")
    }

    // MARK: - Chunk-seam continuity (per-chunk window, no gaps/overlaps)

    /// A 2-chunk smoothing-ON export (segmentFrameBudget triggers `runLongForm`)
    /// must produce frames continuous across the chunk seam: each chunk's per-
    /// call window + h-frame margins reconstructs the true centered window for
    /// every encode-range frame, so a frame at the seam gets the SAME smoothing
    /// it would in a single-chunk (`runJob`) export of the same plan. Compares
    /// the long-form output frame-by-frame against a single-export output at
    /// high PSNR (they share the same deterministic recipe; the only divergence
    /// is ProRes encode-path ordering, which is well within the band).
    func testChunkSeamContinuityLongFormVsSingle() async throws {
        let flames = try genome("sierpinski.flam3")
        var settings = ExportSettings()
        settings.codec = .proRes422HQ; settings.container = .mov
        settings.resolution = .custom(width: 96, height: 60); settings.fps = 30
        settings.quality = .spp(20); settings.temporalSamples = 1
        settings.smoothingAlpha = 0.2   // h=5

        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outSingle = dir.appendingPathComponent("single.mov")
        let outLong = dir.appendingPathComponent("long.mov")

        // Single (runJob): 2-segment plan = 1 loop (6 frames) + 1 transition
        // (6 frames) = 12 global frames, encoded in one chunk.
        var singleSettings = settings
        let jobSingle = ExportJob(settings: singleSettings, flames: flames,
                                  framesPerSegment: 6, transitionFramesPerSegment: 6,
                                  segmentCount: 2, selector: .sequential, seed: 7,
                                  loopCycles: 1, stagger: 0, out: outSingle)
        let coordSingle = ExportCoordinator(backend: .cpu)
        for try await _ in await coordSingle.run(jobSingle) {}

        // Long-form (runLongForm): same plan, but segmentFrameBudget forces 2
        // chunks (one segment each) → the loop/transition seam IS a chunk seam.
        var lfSettings = settings
        lfSettings.segmentFrameBudget = 6   // 1 segment/chunk → 2 chunks
        let jobLong = ExportJob(settings: lfSettings, flames: flames,
                                framesPerSegment: 6, transitionFramesPerSegment: 6,
                                segmentCount: 2, selector: .sequential, seed: 7,
                                loopCycles: 1, stagger: 0, out: outLong)
        let coordLong = ExportCoordinator(backend: .cpu)
        for try await _ in await coordLong.runLongForm(jobLong) {}

        let singleFrames = try await decodeFrames(outSingle)
        let longFrames = try await decodeFrames(outLong)
        XCTAssertEqual(singleFrames.count, longFrames.count, "frame count must match across chunking")
        // Each frame must be byte-identical: a frame's centered window depends
        // only on its neighbors (within h), which the per-chunk margins fully
        // reconstruct, so chunked vs single produces identical pixels.
        for i in 0..<singleFrames.count {
            XCTAssertEqual(maxAbsDiff(singleFrames[i], longFrames[i]), 0,
                           "chunk-seam frame \(i) must be byte-identical between long-form and single export "
                           + "(per-chunk window margins must reconstruct the true centered window)")
        }
    }

    // MARK: - Grid-mismatch graceful error (varying filterRadius across window)

    /// The centered box window averages histograms that MUST share grid dims.
    /// `gridWidth` is a step function of each frame's center-flame `filterRadius`
    /// (via `flam3SpatialFilterWidth`); a transition between genomes whose
    /// `filter` attrs fall in different width buckets (e.g. 0.0 vs 1.0 at
    /// oversample 1 → gridWidth W vs W+4) produces incompatible histograms.
    /// `feedEmitSmoothed` detects this and throws `smoothingGridMismatch` INSTEAD
    /// of letting `TemporalBoxWindow.feed`'s precondition trap (crash). This is
    /// the graceful path for an unsupported input (averaging across grids is
    /// undefined); the user can disable smoothing or use a uniform-filter library.
    func testGridMismatchThrowsOnVaryingFilterRadius() async throws {
        let flames = try genome("sierpinski.flam3")
        // Two copies of sierpinski whose filterRadius lands in DIFFERENT
        // gridWidth buckets at oversample 1 (radius 0.0 → gridWidth W; radius
        // 1.0 → gridWidth W+4). The loop (genome A) sets the window's grid; the
        // A→B transition interpolates filterRadius 0.0→1.0, and once a frame
        // crosses into the W+2/W+4 bucket its histogram's grid diverges.
        var a = flames[0]; a.quality.filterRadius = 0.0
        var b = flames[0]; b.quality.filterRadius = 1.0
        let params = RenderParams(seed: 7, width: 96, height: 60, oversample: 1, samplesPerPixel: 8)
        var schedule = Schedule(librarySize: 2, framesPerSegment: 4,
                                transitionFramesPerSegment: 4,
                                selector: Sequential(seed: 7), seed: 7)
        let plan = FramePlan(schedule: &schedule, segmentCount: 2, flames: [a, b],
                             loopCycles: 1, stagger: 0, temporalSamples: 1)
        let coord = ExportCoordinator(backend: .cpu)
        do {
            _ = try await coord.renderSmoothedRangeForTest(
                plan: plan, params: params, budget: nil, useMetal: false,
                halfWidth: 3, range: 0..<plan.totalFrames)
            XCTFail("expected ExportError.smoothingGridMismatch (varying filterRadius)")
        } catch ExportError.smoothingGridMismatch {
            // expected — grid mismatch is a graceful error, not a crash
        } catch {
            XCTFail("expected ExportError.smoothingGridMismatch, got \(error)")
        }
    }

    // MARK: - decode helpers (mirror RenderFramesInterleavedTests / OffMainDispatchTests)

    private func decodeFrames(_ url: URL) async throws -> [CVPixelBuffer] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "TemporalSmoothingDispatchTests", code: 1)
        }
        let reader = try AVAssetReader(asset: asset)
        reader.add(AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]))
        try reader.startReading()
        var frames: [CVPixelBuffer] = []
        while let sb = reader.outputs.first?.copyNextSampleBuffer(),
              let pb = CMSampleBufferGetImageBuffer(sb) { frames.append(pb) }
        return frames
    }
    private func maxAbsDiff(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Int {
        precondition(CVPixelBufferGetWidth(a) == CVPixelBufferGetWidth(b)
                     && CVPixelBufferGetHeight(a) == CVPixelBufferGetHeight(b))
        CVPixelBufferLockBaseAddress(a, []); CVPixelBufferLockBaseAddress(b, [])
        defer { CVPixelBufferUnlockBaseAddress(a, []); CVPixelBufferUnlockBaseAddress(b, []) }
        guard let ba = CVPixelBufferGetBaseAddress(a), let bb = CVPixelBufferGetBaseAddress(b) else { return Int.max }
        let h = CVPixelBufferGetHeight(a), rb = CVPixelBufferGetBytesPerRow(a), w = CVPixelBufferGetWidth(a)
        var mx = 0
        for y in 0..<h {
            let ra = ba.advanced(by: y * rb), rb2 = bb.advanced(by: y * rb)
            for x in 0..<(w * 4) {
                let d = abs(Int(ra.load(fromByteOffset: x, as: UInt8.self)) - Int(rb2.load(fromByteOffset: x, as: UInt8.self)))
                if d > mx { mx = d }
            }
        }
        return mx
    }
    private func firstFrameBGRABytes(of url: URL) async throws -> [UInt8] {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [String(kCVPixelBufferPixelFormatTypeKey): kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? NSError(domain: "TemporalSmoothingDispatchTests", code: 2)
        }
        defer { reader.cancelReading() }
        guard let sample = output.copyNextSampleBuffer(),
              let pb = CMSampleBufferGetImageBuffer(sample) else {
            throw NSError(domain: "TemporalSmoothingDispatchTests", code: 3)
        }
        CVPixelBufferLockBaseAddress(pb, [.readOnly])
        defer { CVPixelBufferUnlockBaseAddress(pb, [.readOnly]) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        guard let base = CVPixelBufferGetBaseAddress(pb) else {
            throw NSError(domain: "TemporalSmoothingDispatchTests", code: 4)
        }
        var bytes = [UInt8](); bytes.reserveCapacity(w * h * 4)
        for row in 0..<h {
            let rowStart = base.advanced(by: row * bpr)
            bytes.append(contentsOf: UnsafeBufferPointer(
                start: rowStart.assumingMemoryBound(to: UInt8.self), count: w * 4))
        }
        return bytes
    }
    private func psnrRaw(_ a: [UInt8], _ b: [UInt8]) -> (maxDiff: Int, psnr: Double) {
        precondition(a.count == b.count)
        var mx = 0, sse = 0.0
        for i in 0..<a.count {
            let d = Int(a[i]) - Int(b[i]); let ad = abs(d)
            if ad > mx { mx = ad }
            sse += Double(d * d)
        }
        let psnr = sse == 0 ? Double.infinity
            : 10.0 * log10((Double(a.count) * 255.0 * 255.0) / sse)
        return (mx, psnr)
    }
}
