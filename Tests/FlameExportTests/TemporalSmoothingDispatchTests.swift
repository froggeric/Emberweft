import XCTest
import AVFoundation
import CoreVideo
@testable import FlameExport
import FlameKit
import FlameReference
import FlameRenderer

/// M6.1 slice 2 (Task 8): pins for the coordinator's smoothing dispatch — the
/// run-scoped histogram accumulator + the inlined smoothing-ON frame dispatch
/// (CPU + Metal) across all four `renderImage` sites. Drives the private dispatch
/// via the actor's `internal` test seams (`renderSmoothedFrameForTest`,
/// `resetSmoothingAccumulator`) so the pins run WITHOUT a full encoder round-trip
/// (fast), plus small end-to-end exports for the loop-repeat + cross-branch pins
/// (which need the real frame loops).
///
/// Sacred invariants covered:
/// - **S11 cold-start byte-identity**: frame 0 ON (α<1) == frame 0 OFF (α=1),
///   byte-identical on CPU (the cold-start EMA copies the histogram verbatim,
///   then the same DE+ToneMapping runs).
/// - **Metal cold-start parity**: frame 0 Metal ON vs OFF within the
///   fused-vs-unfused band (host-decode vs fused GPU; not byte-identical).
/// - **Metal↔CPU smoothing-ON parity**: a 3-frame α=0.20 sequence Metal vs CPU,
///   PSNR ≥ 38 dB.
/// - **S5 loop-repeat + smoothing**: under loopRepeatCount=2 + smoothing ON the
///   accumulator feeds once per rendered global frame; repeated copies are
///   byte-identical (no inter-copy flicker).
/// - **R10/S14 cross-branch**: CLI-MainActor smoothing-ON ≈ GUI-offmain
///   smoothing-ON within the fused-vs-unfused band.
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
    /// (ExportCoordinator.swift:199) so the test seam sees production-shaped inputs.
    /// `segmentCount: 1` + `framesPerSegment: 6` ⇒ a 6-frame single-loop timeline
    /// (multi-frame ⇒ smoothing active when α<1). `genomeName` picks the fixture:
    /// sierpinski for byte-identity pins (CPU-internal); a denser fixture
    /// (`julia_bubbles`) for Metal↔CPU parity (sierpinski is a sparse/spiky
    /// attractor where Metal↔CPU is Float-limited below the 38 dB gate at low spp —
    /// the CLAUDE.md "spiky stills" gotcha; q-dependent, so higher spp also helps).
    private func makeContext(seed: UInt64 = 7, spp: Int = 20, genomeName: String = "sierpinski.flam3")
        throws -> (plan: FramePlan, params: RenderParams, budget: MetalRenderer.ThreadSeedBudget?) {
        let flames = try genome(genomeName)
        let params = RenderParams(seed: seed, width: 128, height: 80, oversample: 1, samplesPerPixel: spp)
        var schedule = Schedule(librarySize: flames.count, framesPerSegment: 6,
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

    // MARK: - S11 cold-start CPU byte-identity

    /// Frame 0 of a multi-frame CPU plan with α=0.2 == frame 0 with α=1.0 (OFF),
    /// byte-identical. The cold-start EMA copies frame 0's Double histogram
    /// verbatim; both paths then run DE+ToneMapping on identical Double data.
    func testColdStartCPUByteIdentity() async throws {
        let ctx = try makeContext()
        let coord = ExportCoordinator(backend: .cpu)
        let d0 = ctx.plan.descriptor(for: 0)

        let onCold = try await coord.renderSmoothedFrameForTest(
            descriptor: d0, plan: ctx.plan, params: ctx.params, budget: nil,
            useMetal: false, alpha: 0.2, resetAccumulator: true)
        let offCold = try await coord.renderSmoothedFrameForTest(
            descriptor: d0, plan: ctx.plan, params: ctx.params, budget: nil,
            useMetal: false, alpha: 1.0, resetAccumulator: true)
        // α=1.0 through the smoothing path IS the OFF path (EMA cold-start copies
        // verbatim, then DE+ToneMapping = renderImage's operations), so this pins
        // ON-cold-start == OFF byte-for-byte.
        let (mx, _) = psnr(onCold, offCold)
        XCTAssertEqual(mx, 0, "cold-start frame 0 must be byte-identical (α=0.2 vs α=1.0 OFF)")
        XCTAssertGreaterThan(onCold.pixels.max() ?? 0, 0, "frame must be non-empty (not solid black)")
    }

    // MARK: - S11 Metal cold-start parity

    /// Frame 0 Metal ON (α=0.2) vs OFF (α=1.0) within the fused-vs-unfused band
    /// (NOT byte-identical — host-decode histogram→DE→display vs the fused GPU
    /// path; pinned at PSNR ≥ 38 dB).
    func testMetalColdStartParity() async throws {
        guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
        let ctx = try makeContext()
        let coord = ExportCoordinator(backend: .metal, useOffMainMetal: false)
        let d0 = ctx.plan.descriptor(for: 0)

        let onCold = try await coord.renderSmoothedFrameForTest(
            descriptor: d0, plan: ctx.plan, params: ctx.params, budget: ctx.budget,
            useMetal: true, alpha: 0.2, resetAccumulator: true)
        let offCold = try await coord.renderSmoothedFrameForTest(
            descriptor: d0, plan: ctx.plan, params: ctx.params, budget: ctx.budget,
            useMetal: true, alpha: 1.0, resetAccumulator: true)
        let (_, db) = psnr(onCold, offCold)
        XCTAssertGreaterThanOrEqual(db, 38.0, "Metal cold-start ON vs OFF must be ≥ 38 dB (was \(db))")
    }

    // MARK: - Metal↔CPU smoothing-ON parity (3-frame α=0.20 sequence)

    /// A 3-frame α=0.20 sequence, Metal vs CPU, PSNR ≥ 38 dB. Feeds both
    /// accumulators in render order; compares the FINAL frame (carries the most
    /// smoothing). Metal and CPU histograms are statistical, not byte-identical;
    /// the linear EMA + shared DE+display preserve the ≥ 38 dB parity band.
    func testMetalCPUSmoothingParity() async throws {
        guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
        // spp=1000 @ 320×200 is the PROVEN Metal↔CPU parity regime
        // (EndToEndParityTests.testMetalCPU_Parity_PSNR38_SSIM095 — all goldens
        // clear 38 dB at 1000 spp; julia_bubbles explicitly needed 1000). Lower
        // spp lands in the Float-limited "spiky stills" regime (< 38 dB; CLAUDE.md
        // gotcha). The EMA is a linear blend of per-frame statistical histograms,
        // so smoothing PRESERVES the underlying ≥ 38 dB parity band.
        let flames = try genome("sierpinski.flam3")
        let params = RenderParams(seed: 7, width: 160, height: 100, oversample: 1, samplesPerPixel: 1000)
        var schedule = Schedule(librarySize: flames.count, framesPerSegment: 3,
                                selector: Sequential(seed: 7), seed: 7)
        let plan = FramePlan(schedule: &schedule, segmentCount: 1, flames: flames,
                             loopCycles: 1, stagger: 0, temporalSamples: 1)
        let budget = MetalRenderer.ThreadSeedBudget(baseSeed: params.seed)
        let ctx: (plan: FramePlan, params: RenderParams, budget: MetalRenderer.ThreadSeedBudget?) = (plan, params, budget)
        let coordM = ExportCoordinator(backend: .metal, useOffMainMetal: false)
        let coordC = ExportCoordinator(backend: .cpu)
        await coordM.resetSmoothingAccumulator()
        await coordC.resetSmoothingAccumulator()

        var imgM = RGBA8Image(width: 1, height: 1, pixels: [0,0,0,0])
        var imgC = imgM
        for gf in 0..<3 {
            let d = ctx.plan.descriptor(for: gf)
            imgM = try await coordM.renderSmoothedFrameForTest(
                descriptor: d, plan: ctx.plan, params: ctx.params, budget: ctx.budget,
                useMetal: true, alpha: 0.20, resetAccumulator: false)
            imgC = try await coordC.renderSmoothedFrameForTest(
                descriptor: d, plan: ctx.plan, params: ctx.params, budget: nil,
                useMetal: false, alpha: 0.20, resetAccumulator: false)
        }
        let (_, db) = psnr(imgM, imgC)
        print("[SmoothingParity] Metal↔CPU 3-frame α=0.20 @1000spp: PSNR=\(db) dB")
        XCTAssertGreaterThanOrEqual(db, 38.0, "Metal↔CPU smoothing-ON (3-frame α=0.20) PSNR ≥ 38 dB (was \(db))")
    }

    // MARK: - S5 loop-repeat + smoothing (end-to-end)

    /// Under loopRepeatCount=2 + smoothing ON, the accumulator feeds once per
    /// rendered global frame and the repeated (cached) copies are byte-identical.
    /// Drives the REAL `runJob` → `renderFrames` repeat>1 cache+replay path with
    /// `smoothingAlpha=0.2`; decodes the output and asserts (a) the coordinator
    /// rendered exactly the global-frame count once (renderCallCount) and appended
    /// 2× (appendedFrameCount), and (b) the first loop's frames equal their
    /// immediate replay (no inter-copy flicker).
    func testLoopRepeatAndSmoothing() async throws {
        let flames = try genome("sierpinski.flam3")
        var settings = ExportSettings()
        settings.codec = .proRes422HQ; settings.container = .mov
        settings.resolution = .custom(width: 96, height: 60); settings.fps = 30
        settings.quality = .spp(20); settings.temporalSamples = 1
        settings.smoothingAlpha = 0.2   // smoothing ON for a multi-frame run

        let dir = tmpDir()
        let out = dir.appendingPathComponent("lr.mov")
        defer { try? FileManager.default.removeItem(at: dir) }
        let job = ExportJob(settings: settings, flames: flames, framesPerSegment: 4,
                            segmentCount: 1, selector: .sequential, seed: 7,
                            loopCycles: 1, stagger: 0, out: out, loopRepeatCount: 2)
        let coord = ExportCoordinator(backend: .cpu)
        let stream = await coord.run(job)
        for try await _ in stream {}

        // renderCallCount counts each RENDERED (cached) frame once; appendedFrameCount
        // counts encoder appends (2× per loop frame under loopRepeatCount=2).
        let rendered = await coord.renderCallCount
        let appended = await coord.appendedFrameCount
        XCTAssertEqual(rendered, 4, "loop rendered once (4 global frames) under loopRepeatCount=2")
        XCTAssertEqual(appended, 8, "each loop frame appended 2× (4 frames × loopRepeatCount=2)")

        // Decode and assert each cached frame equals its immediate replay. The
        // replay order is PER-FRAME (f0,f0,f1,f1,f2,f2,f3,f3 — see `renderFrames`
        // repeat>1 cache loop: outer over cache, inner over loopRepeatCount), so
        // pair (2i, 2i+1) compares a frame and its replay — byte-identical cached
        // bytes encoded through the same ProRes session (no inter-copy flicker).
        let frames = try await decodeFrames(out)
        XCTAssertEqual(frames.count, 8)
        for i in 0..<4 {
            XCTAssertEqual(maxAbsDiff(frames[2 * i], frames[2 * i + 1]), 0,
                           "loop-repeat copy \(i) must be byte-identical to its replay (no inter-copy flicker)")
        }
    }

    // MARK: - R10/S14 cross-branch (CLI MainActor ≈ GUI offmain, both smoothing ON)

    /// CLI-MainActor smoothing-ON ≈ GUI-offmain smoothing-ON within the
    /// fused-vs-unfused band. Two full Metal exports differing ONLY in
    /// `useOffMainMetal`, both with `smoothingAlpha=0.2`; decoded frame compared
    /// at PSNR ≥ 38 dB. Pins the off-main smoothed dispatch (T5+T6 off-main) is
    /// wired and parity-faithful to the MainActor smoothed dispatch.
    func testCrossBranchMainActorVsOffMainSmoothing() async throws {
        guard MetalRenderer.isAvailable else { throw XCTSkip("Metal unavailable") }
        let flames = try genome("sierpinski.flam3")
        var settings = ExportSettings()
        settings.resolution = .custom(width: 128, height: 80); settings.fps = 30
        settings.quality = .spp(8); settings.temporalSamples = 1
        settings.smoothingAlpha = 0.2

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
