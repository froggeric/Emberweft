import XCTest
@testable import FlameExport
import FlameKit
import FlameReference

final class ExportCoordinatorTests: XCTestCase {
    private func genome(_ name: String) throws -> [Flame] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Goldens/genomes/\(name)")
        return try Flam3Parser.parse(Data(contentsOf: url))
    }

    private func tmpMP4() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("m6-\(UUID().uuidString).mp4")
    }

    /// Rule-#2 pin (in-process): rendering global frame K through the SAME
    /// `FramePlan` + `ReferenceRenderer` path the coordinator drives, twice with
    /// independent `FramePlan` instances, yields byte-identical pixels. This
    /// avoids the non-determinism of encoded video bytes (§5.3) while still
    /// exercising the frame-recipe extraction. The cross-COMMAND byte-identity
    /// vs `animate` is `testExportMatchesAnimateFrame` (Task 5, via PNG).
    func testExportFramePixelIdentity() async throws {
        let flames = try genome("sierpinski.flam3")
        var settings = ExportSettings()
        settings.resolution = .custom(width: 128, height: 80); settings.fps = 30
        settings.temporalSamples = 1
        let base = flames[0]
        let (spp, os) = settings.quality.resolvedSamplesPerPixel(for: base)
        let params = RenderParams(seed: 7, width: 128, height: 80, oversample: os, samplesPerPixel: spp)

        // Two independent FramePlans (independent Schedule walks) over the same
        // deterministic inputs -> identical descriptors -> identical pixels.
        func renderFrame5() -> RGBA8Image {
            var schedule = Schedule(librarySize: flames.count, framesPerSegment: 8,
                                    selector: Sequential(seed: 7), seed: 7)
            let plan = FramePlan(schedule: &schedule, segmentCount: 1, flames: flames,
                                 loopCycles: 1, stagger: 0, temporalSamples: 1)
            let d = plan.descriptor(for: 5)
            return ReferenceRenderer.render(flame: d.blendAt(d.blend), params: params)
        }
        let a = renderFrame5()
        let b = renderFrame5()
        XCTAssertEqual(a, b)   // byte-identical across independent plans (rule #2)

        // Also pin the coordinator end-to-end runs twice without error (the
        // encoded .mp4 bytes are NOT asserted — §5.3; both files exist).
        let outA = tmpMP4(), outB = tmpMP4()
        let coord = ExportCoordinator(backend: .cpu)
        for url in [outA, outB] {
            let job = ExportJob(settings: settings, flames: flames, framesPerSegment: 8,
                                segmentCount: 1, selector: .sequential, seed: 7,
                                loopCycles: 1, stagger: 0, out: url)
            let stream = await coord.run(job)
            for try await _ in stream {}
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outA.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outB.path))
        try? FileManager.default.removeItem(at: outA); try? FileManager.default.removeItem(at: outB)
    }

    /// Atomic-handoff AC: a mid-encode failure (here: pre-cancelled run) deletes
    /// the `<out>.partial-*` file and leaves any pre-existing `<out>` untouched.
    /// The coordinator creates+starts the encoder (writing the partial), then
    /// the per-frame `cancelled` guard fires `encoder.cancel()` + removes the
    /// partial and throws BEFORE the atomic rename — so `out` is never reached.
    func testAtomicHandoffOnFailure() async throws {
        let flames = try genome("sierpinski.flam3")
        var settings = ExportSettings()
        settings.resolution = .custom(width: 32, height: 32); settings.fps = 30
        settings.temporalSamples = 1
        let out = tmpMP4()
        let existing = Data("keep".utf8)
        try existing.write(to: out)
        let job = ExportJob(settings: settings, flames: flames, framesPerSegment: 8,
                            segmentCount: 1, selector: .sequential, seed: 7,
                            loopCycles: 1, stagger: 0, out: out)
        let coord = ExportCoordinator(backend: .cpu)
        await coord.cancel()   // pre-cancel: the loop's first iteration throws
        var threw = false
        do {
            let stream = await coord.run(job)
            for try await _ in stream {}
        } catch {
            threw = true
        }
        XCTAssertTrue(threw, "a cancelled run must throw")
        // `out` untouched (existing content preserved); partial deleted.
        XCTAssertEqual(try Data(contentsOf: out), existing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.partialURL.path),
                       "the partial file must be deleted on failure")
        try? FileManager.default.removeItem(at: out)
    }
}
