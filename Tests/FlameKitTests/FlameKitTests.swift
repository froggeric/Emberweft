import XCTest
@testable import FlameKit

final class FlameKitTests: XCTestCase {
    func testVersionIsNonEmpty() {
        XCTAssertFalse(FlameKit.version.isEmpty)
    }
}
