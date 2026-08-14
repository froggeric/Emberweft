// Tests/FlameFlockTests/ShardPresetsTests.swift
import XCTest
@testable import FlameFlock

/// The GUI's preset shard catalog: names, dimensions, canonical pace flags, and
/// agreement with `FlockNaming.shardDir` for every entry (a preset name and an
/// archive directory name must be the same string). Plus the pace-edit helper
/// the Generate/Stitch steppers share.
final class ShardPresetsTests: XCTestCase {

    // MARK: - sensible (the preset list)

    /// Exactly the four sensible resolutions, at 30 fps, all canonical pace.
    func testSensibleCoversTheFourResolutionsAt30fpsCanonicalPace() {
        XCTAssertEqual(ShardPresets.sensible.map { "\($0.width)x\($0.height)" },
                       ["1280x720", "1920x1080", "2560x1440", "3840x2160"])
        XCTAssertTrue(ShardPresets.sensible.allSatisfy { $0.fps == 30 },
                      "all presets are 30 fps")
        XCTAssertTrue(ShardPresets.sensible.allSatisfy { $0.isCanonical },
                      "all presets carry the canonical pace flag")
        XCTAssertTrue(ShardPresets.sensible.allSatisfy { $0.codec == .hevc },
                      "archive codec is HEVC (D12)")
    }

    /// Deterministic order: ascending pixels, unique names (rule #2 — the list
    /// is ordered data the pickers render verbatim).
    func testSensibleIsAscendingPixelsWithUniqueNames() {
        let pixels = ShardPresets.sensible.map { $0.width * $0.height }
        XCTAssertEqual(pixels, pixels.sorted(), "ascending pixel order")
        let names = ShardPresets.sensible.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "names are unique")
    }

    /// Canonical pace = 15 s loops / 12 s transitions ⇒ at 30 fps, 450/360
    /// frames (the values the GUI's `defaultShard` has always carried).
    func testSensiblePaceIsFifteenTwelveSeconds() {
        for s in ShardPresets.sensible {
            XCTAssertEqual(s.loopSeconds, 15.0)
            XCTAssertEqual(s.transSeconds, 12.0)
            XCTAssertEqual(s.loopFrames, 450)
            XCTAssertEqual(s.transFrames, 360)
        }
    }

    /// Every preset name is exactly what `FlockNaming.shardDir` derives from the
    /// preset's own fields — selecting a preset lands material in the directory
    /// the rest of the archive machinery would compute for it.
    func testSensibleNamesAgreeWithFlockNamingShardDir() throws {
        for s in ShardPresets.sensible {
            XCTAssertEqual(s.name, try FlockNaming.shardDir(
                width: s.width, height: s.height, fps: s.fps,
                loopFrames: s.loopFrames, transFrames: s.transFrames))
        }
    }

    func testSensibleNames() {
        XCTAssertEqual(ShardPresets.sensible.map(\.name),
                       ["1280x720_30fps", "1920x1080_30fps",
                        "2560x1440_30fps", "3840x2160_30fps"])
    }

    // MARK: - canonicalDefault

    /// The default is the 1080p30 canonical preset, and IS a member of the list
    /// (so a picker dedupe by name never hides the default).
    func testCanonicalDefaultIsThe1080p30Preset() {
        XCTAssertEqual(ShardPresets.canonicalDefault.name, "1920x1080_30fps")
        XCTAssertEqual(ShardPresets.canonicalDefault.width, 1920)
        XCTAssertEqual(ShardPresets.canonicalDefault.height, 1080)
        XCTAssertTrue(ShardPresets.canonicalDefault.isCanonical)
        XCTAssertEqual(ShardPresets.canonicalDefault, ShardPresets.sensible[1])
        XCTAssertTrue(ShardPresets.sensible.contains(ShardPresets.canonicalDefault))
    }

    // MARK: - preset(named:)

    func testPresetNamedFindsPresetAndReturnsNilForUnknown() {
        XCTAssertEqual(ShardPresets.preset(named: "1280x720_30fps")?.width, 1280)
        XCTAssertEqual(ShardPresets.preset(named: "3840x2160_30fps")?.height, 2160)
        XCTAssertNil(ShardPresets.preset(named: "1920x1080_30fps_Lf600-Tf300"),
                     "a non-canonical archive shard is not a preset")
        XCTAssertNil(ShardPresets.preset(named: ""))
    }

    // MARK: - withPace (the shared pace-edit recompute)

    /// Editing to the canonical pace keeps the bare name and the canonical flag
    /// (identity for an already-canonical shard).
    func testWithPaceCanonicalKeepsBareName() {
        let base = ShardPresets.canonicalDefault
        let paced = base.withPace(loopSeconds: 15, transSeconds: 12)
        XCTAssertEqual(paced.name, "1920x1080_30fps")
        XCTAssertTrue(paced.isCanonical)
        XCTAssertEqual(paced, base)
    }

    /// A non-canonical pace re-derives frames, flips the flag, and appends the
    /// `_Lf<T>-Tf<T>` suffix (mirroring `FlockNaming.shardDir`).
    func testWithPaceNonCanonicalRenamesAndRecomputesFrames() throws {
        let base = ShardPresets.canonicalDefault
        let paced = base.withPace(loopSeconds: 20, transSeconds: 10)
        XCTAssertEqual(paced.loopSeconds, 20)
        XCTAssertEqual(paced.transSeconds, 10)
        XCTAssertEqual(paced.loopFrames, 600)      // round(20·30)
        XCTAssertEqual(paced.transFrames, 300)     // round(10·30)
        XCTAssertFalse(paced.isCanonical)
        XCTAssertEqual(paced.name, "1920x1080_30fps_Lf600-Tf300")
        // The name is exactly what shardDir derives for the same inputs.
        XCTAssertEqual(paced.name, try FlockNaming.shardDir(
            width: paced.width, height: paced.height, fps: paced.fps,
            loopFrames: paced.loopFrames, transFrames: paced.transFrames))
        // Resolution / fps / codec are untouched by a pace edit.
        XCTAssertEqual(paced.width, base.width)
        XCTAssertEqual(paced.height, base.height)
        XCTAssertEqual(paced.fps, base.fps)
        XCTAssertEqual(paced.codec, base.codec)
    }

    /// Half-second steps land on whole frames at 30 fps (round, not truncate) —
    /// the stepper's step value stays in the naming round trip.
    func testWithPaceRoundsHalfSecondSteps() {
        let paced = ShardPresets.canonicalDefault.withPace(loopSeconds: 15.5, transSeconds: 11.5)
        XCTAssertEqual(paced.loopFrames, 465)      // round(15.5·30)
        XCTAssertEqual(paced.transFrames, 345)     // round(11.5·30)
        XCTAssertEqual(paced.name, "1920x1080_30fps_Lf465-Tf345")
    }
}
