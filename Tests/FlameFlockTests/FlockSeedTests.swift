// Tests/FlameFlockTests/FlockSeedTests.swift
import XCTest
@testable import FlameFlock

final class FlockSeedTests: XCTestCase {
    func testDeterministicAndCanonicalOrderDependent() {
        let a = FlockSeed.sha256ToUInt64(canonical: "1920x1080_30fps|248|00628|248|03194")
        let b = FlockSeed.sha256ToUInt64(canonical: "1920x1080_30fps|248|00628|248|03194")
        XCTAssertEqual(a, b, "same key ⇒ identical seed (rule #2)")
        let reversed = FlockSeed.sha256ToUInt64(canonical: "248|03194|248|00628|1920x1080_30fps")
        XCTAssertNotEqual(a, reversed, "canonical order is load-bearing")
    }
    func testDistinctForDistinctEndpoints() {
        let loop = FlockSeed.sha256ToUInt64(canonical: "s|248|628|248|628")
        let edge = FlockSeed.sha256ToUInt64(canonical: "s|248|628|248|3194")
        XCTAssertNotEqual(loop, edge)
    }
}
