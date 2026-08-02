import XCTest
@testable import EmberweftUI

final class FPSMeterTests: XCTestCase {

    /// No publish until the throttle window elapses (the digit settles, not twitches).
    func testNoPublishBeforeThrottleWindow() {
        var m = FPSMeter(window: 30, publishInterval: 0.5)
        var t = 0.0
        XCTAssertNil(m.record(now: t), "first frame seeds the clock, no publish")
        for _ in 0..<10 {
            t += 1.0 / 60.0
            XCTAssertNil(m.record(now: t), "must not publish before 0.5s throttle window")
        }
    }

    func testPublishesRollingAverage60fps() {
        var m = FPSMeter(window: 30, publishInterval: 0.5)
        var t = 0.0
        _ = m.record(now: t)
        var published: Double?
        for _ in 0..<33 {
            t += 1.0 / 60.0
            if let v = m.record(now: t) { published = v }
        }
        XCTAssertNotNil(published, "must publish once past the throttle window")
        XCTAssertEqual(published!, 60, accuracy: 2.0)
    }

    func testSlowFramesYieldLowerFPS() {
        var m = FPSMeter(window: 30, publishInterval: 0.4)
        var t = 0.0
        _ = m.record(now: t)
        var published: Double?
        for _ in 0..<25 {
            t += 1.0 / 20.0          // 20 fps
            if let v = m.record(now: t) { published = v }
        }
        XCTAssertEqual(published!, 20, accuracy: 1.5)
    }

    func testResetClearsHistory() {
        var m = FPSMeter(window: 30, publishInterval: 0.5)
        var t = 0.0
        _ = m.record(now: t)
        for _ in 0..<33 {
            t += 1.0 / 60.0
            _ = m.record(now: t)
        }
        m.reset()
        // After reset, the next record re-seeds (no interval, no publish).
        XCTAssertNil(m.record(now: t + 1.0))
    }

    /// Zero / negative intervals (e.g. two frames at the same clock tick) are
    /// skipped, never producing a divide-by-zero.
    func testZeroIntervalIsIgnored() {
        var m = FPSMeter(window: 10, publishInterval: 0.0)
        _ = m.record(now: 5.0)
        _ = m.record(now: 5.0)          // dt = 0 → skipped, no publish (no valid interval)
        // publishInterval 0 ⇒ publishes on the first valid interval.
        let v = m.record(now: 5.0167)   // ~60fps after a real gap
        XCTAssertNotNil(v)
        XCTAssertEqual(v!, 60, accuracy: 3.0)
    }
}

final class PreviewFPSBandTests: XCTestCase {

    func testBandsAtTarget60() {
        XCTAssertEqual(PreviewFPSBand.band(measuredFPS: 60, targetFPS: 60, isPlaying: true), .green)
        XCTAssertEqual(PreviewFPSBand.band(measuredFPS: 55, targetFPS: 60, isPlaying: true), .green)  // ≥ 0.9·60=54
        XCTAssertEqual(PreviewFPSBand.band(measuredFPS: 40, targetFPS: 60, isPlaying: true), .amber)  // 30 ≤ 40 < 54
        XCTAssertEqual(PreviewFPSBand.band(measuredFPS: 28, targetFPS: 60, isPlaying: true), .red)    // < max(24,30)=30
    }

    /// Absolute 24 fps floor engages only at low targets (cinematic threshold).
    func testAbsoluteFloorAtLowTarget() {
        // target 30: floor = max(24, 0.5·30=15) = 24.
        XCTAssertEqual(PreviewFPSBand.band(measuredFPS: 30, targetFPS: 30, isPlaying: true), .green)  // ≥ 27
        XCTAssertEqual(PreviewFPSBand.band(measuredFPS: 25, targetFPS: 30, isPlaying: true), .amber)  // 24 ≤ 25 < 27
        XCTAssertEqual(PreviewFPSBand.band(measuredFPS: 20, targetFPS: 30, isPlaying: true), .red)    // < 24
    }

    func testIdleWhenNotPlayingOrNonFinite() {
        XCTAssertEqual(PreviewFPSBand.band(measuredFPS: 60, targetFPS: 60, isPlaying: false), .idle)
        XCTAssertEqual(PreviewFPSBand.band(measuredFPS: 0, targetFPS: 60, isPlaying: true), .idle)
        XCTAssertEqual(PreviewFPSBand.band(measuredFPS: .nan, targetFPS: 60, isPlaying: true), .idle)
        XCTAssertEqual(PreviewFPSBand.band(measuredFPS: 60, targetFPS: 0, isPlaying: true), .idle)
    }

    func testAccessibilityVerdictsAreDistinct() {
        let bands: [PreviewFPSBand] = [.green, .amber, .red, .idle]
        let verdicts = Set(bands.map(\.accessibilityVerdict))
        XCTAssertEqual(verdicts.count, bands.count, "each band needs a distinct VoiceOver verdict")
        XCTAssertFalse(PreviewFPSBand.green.accessibilityVerdict.isEmpty)
    }
}
