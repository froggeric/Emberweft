import XCTest
@testable import FlameRenderer

final class MetalAvailabilityTests: XCTestCase {
    func testMetalBackendAvailableOnDevMachine() {
        // The dev machine is Apple Silicon with a usable Metal device.
        XCTAssertTrue(
            MetalRenderer.isAvailable, "Metal backend unavailable — cannot run M2 parity tests")
    }
}
