import XCTest
@testable import EmberweftUI

final class WallClockTests: XCTestCase {

    func testOverrunReturnsImmediately() async {
        let clock = WallClock()
        let pastDeadline = clock.now() - 10  // already 10 s ago
        let start = clock.now()
        await clock.sleep(until: pastDeadline)
        let elapsed = clock.now() - start
        XCTAssertLessThan(elapsed, 0.001, "overrun sleep must return in < 1 ms")
    }

    func testNowIsMonotonic() {
        let clock = WallClock()
        var prev = clock.now()
        for _ in 0..<1000 {
            let n = clock.now()
            XCTAssertGreaterThanOrEqual(n, prev, "now() must be monotonic")
            prev = n
        }
    }
}
