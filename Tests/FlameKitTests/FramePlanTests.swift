import XCTest
@testable import FlameKit

final class FramePlanTests: XCTestCase {
    private func twoFlames() throws -> [Flame] {
        // `#file` may be relative or absolute depending on toolchain; resolve
        // the fixture robustly against several candidate bases (mirrors
        // SimilarityTests' proven pattern).
        let candidates: [URL] = [
            // cwd-relative (swift test runs from the package root)
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Tests/Goldens/genomes/sierpinski.flam3"),
            // relative to this source file (absolute-#file toolchains)
            URL(fileURLWithPath: #file)
                .deletingLastPathComponent()
                .appendingPathComponent("../Goldens/genomes/sierpinski.flam3")
                .standardizedFileURL
        ]
        let url = try XCTUnwrap(
            candidates.first { FileManager.default.fileExists(atPath: $0.path) },
            "sierpinski.flam3 fixture not found in any candidate base")
        let data = try Data(contentsOf: url)
        return try Flam3Parser.parse(data)
    }

    func testDescriptorIsPureAndStable() throws {
        let flames = try twoFlames() + twoFlames()
        var schedule = Schedule(librarySize: flames.count, framesPerSegment: 8,
                                selector: Sequential(seed: 0), seed: 0)
        let plan = FramePlan(schedule: &schedule, segmentCount: 3, flames: flames,
                             loopCycles: 1, temporalSamples: 1)
        let a = plan.descriptor(for: 5)
        let b = plan.descriptor(for: 5)
        XCTAssertEqual(a.segmentId, b.segmentId)
        XCTAssertEqual(a.blend, b.blend, accuracy: 0)
        XCTAssertEqual(a.kind, b.kind)
        XCTAssertEqual(a.fromSheep, b.fromSheep)
        // k, k-1, k is stable (no hidden mutation)
        _ = plan.descriptor(for: 4)
        let c = plan.descriptor(for: 5)
        XCTAssertEqual(a.blend, c.blend)
    }

    func testTemporalDeltaScaling() throws {
        let flames = try twoFlames() + twoFlames()
        var schedule = Schedule(librarySize: flames.count, framesPerSegment: 160,
                                selector: Sequential(seed: 0), seed: 0)
        let N = 8
        let plan = FramePlan(schedule: &schedule, segmentCount: 3, flames: flames,
                             loopCycles: 1, temporalSamples: N)
        let d = plan.descriptor(for: 3)
        let q = flames[0].quality
        let (raw, _) = TemporalFilter.samples(N, type: q.temporalFilterType,
                                              width: q.temporalFilterWidth,
                                              exp: q.temporalFilterExp)
        XCTAssertEqual(d.temporal.count, N)
        for i in 0..<N {
            XCTAssertEqual(d.temporal[i].delta, raw[i].delta / 160.0, accuracy: 1e-12)
            XCTAssertEqual(d.temporal[i].weight, raw[i].weight, accuracy: 1e-12)
        }
    }

    func testN1CollapsesToIdentity() throws {
        let flames = try twoFlames() + twoFlames()
        var schedule = Schedule(librarySize: flames.count, framesPerSegment: 8,
                                selector: Sequential(seed: 0), seed: 0)
        let plan = FramePlan(schedule: &schedule, segmentCount: 3, flames: flames, temporalSamples: 1)
        let d = plan.descriptor(for: 2)
        XCTAssertEqual(d.temporal.count, 1)
        XCTAssertEqual(d.temporal[0].delta, 0.0)
        XCTAssertEqual(d.temporal[0].weight, 1.0)
        XCTAssertEqual(d.sumfilt, 1.0)
    }

    func testBoundaryMappingMatchesSchedule() throws {
        let flames = try twoFlames() + twoFlames()
        var schedule = Schedule(librarySize: flames.count, framesPerSegment: 8,
                                selector: Sequential(seed: 0), seed: 0)
        let plan = FramePlan(schedule: &schedule, segmentCount: 3, flames: flames, temporalSamples: 1)
        for gf in 0..<plan.totalFrames {
            let mapping = schedule.frameToBlend(globalFrame: gf)
            let d = plan.descriptor(for: gf)
            XCTAssertEqual(d.segmentId, mapping.segmentId)
            XCTAssertEqual(d.blend, mapping.blend, accuracy: 1e-12)
            XCTAssertEqual(d.kind, mapping.kind)
        }
    }
}
