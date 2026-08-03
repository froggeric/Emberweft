import XCTest
@testable import FlameExport
import FlameKit
import CoreVideo

final class PixelBufferPoolTests: XCTestCase {
    func testRGBAToBGRASwap() async throws {
        let pool = PixelBufferPool(width: 2, height: 1, maxInFlight: 1)
        let img = RGBA8Image(width: 2, height: 1, pixels: [10,20,30,255, 40,50,60,255])
        let pb = await pool.acquire()
        pool.fill(pb, from: img)
        CVPixelBufferLockBaseAddress(pb, [])
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual(base[0], 30); XCTAssertEqual(base[1], 20); XCTAssertEqual(base[2], 10); XCTAssertEqual(base[3], 255)
        XCTAssertEqual(base[4], 60); XCTAssertEqual(base[5], 50); XCTAssertEqual(base[6], 40); XCTAssertEqual(base[7], 255)
        CVPixelBufferUnlockBaseAddress(pb, [])
        pool.release(pb)
    }

    func testPremultipliedAlphaPreserved() async throws {
        let pool = PixelBufferPool(width: 1, height: 1, maxInFlight: 1)
        let img = RGBA8Image(width: 1, height: 1, pixels: [50,50,50,100])
        let pb = await pool.acquire()
        pool.fill(pb, from: img)
        CVPixelBufferLockBaseAddress(pb, [])
        let b = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual(b[0], 50); XCTAssertEqual(b[1], 50); XCTAssertEqual(b[2], 50); XCTAssertEqual(b[3], 100)
        CVPixelBufferUnlockBaseAddress(pb, [])
        pool.release(pb)
    }

    func testPoolCapsInFlight() async throws {
        let pool = PixelBufferPool(width: 8, height: 8, maxInFlight: 3)
        let a = await pool.acquire(); let b = await pool.acquire(); let c = await pool.acquire()
        // 4th acquire should block; race a release and confirm it then completes.
        // The child must release its buffer — a leaked IOSurface-backed
        // CVPixelBuffer traps (SIGTRAP) during async teardown.
        let exp = expectation(description: "4th acquire returns after release")
        Task { let d = await pool.acquire(); pool.release(d); exp.fulfill() }
        await Task.yield(); await Task.yield()
        pool.release(a)   // frees a slot -> the 4th acquire completes
        await fulfillment(of: [exp], timeout: 2.0)
        pool.release(b); pool.release(c)
    }
}
