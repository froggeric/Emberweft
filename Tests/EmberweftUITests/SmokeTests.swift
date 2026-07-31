import XCTest
@testable import EmberweftUI

final class SmokeTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertNotNil(EmberweftUI.self as Any?)
    }
}
