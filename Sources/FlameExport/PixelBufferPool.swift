import Foundation
import CoreVideo
import FlameKit

/// IOSurface-backed, Metal-compatible CVPixelBuffer pool (32BGRA, export-sized).
/// `fill` copies RGBA8Image -> BGRA with a per-pixel R<->B swap (top-first, no
/// flip, premultiplied alpha preserved). Cap in-flight to `maxInFlight`.
///
/// Concurrency model: a counting `DispatchSemaphore(value: maxInFlight)` is the
/// sole gate. `acquire` decrements (non-blocking try + 5 ms cooperative
/// `Task.sleep` so the calling `async` frame stays cooperative and never pins a
/// Swift cooperative thread-pool thread on a blocking `wait()` — Swift 6 bans
/// `DispatchSemaphore.wait()` from `async` contexts, so the try lives in a
/// synchronous helper); `release` increments. This is the classic counting-
/// semaphore pattern and is race-free under multiple concurrent producers/
/// consumers (an earlier lock+counter+`wasFull`-signal design had a lost-wakeup
/// race: a third `acquire` could steal the freed slot between the release's
/// signal and the parked acquirer's re-lock, leaving the parked acquirer stuck).
/// `@unchecked Sendable` is the documented escape: the only mutable state
/// (`pool`) is passed by address into `CVPixelBufferPool*` C calls that are
/// themselves thread-safe; the semaphore is internally synchronized.
public final class PixelBufferPool: @unchecked Sendable {
    public let width: Int
    public let height: Int
    private let maxInFlight: Int
    private var pool: CVPixelBufferPool?
    private let slots: DispatchSemaphore

    public init(width: Int, height: Int, maxInFlight: Int = 3) {
        self.width = width; self.height = height; self.maxInFlight = maxInFlight
        self.slots = DispatchSemaphore(value: maxInFlight)
        let attrs: [CFString: Any] = [
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
    }

    deinit { if let pool { CVPixelBufferPoolFlush(pool, .excessBuffers) } }

    /// Acquires a buffer, yielding cooperatively while `maxInFlight` are
    /// outstanding. Polls the semaphore in 5 ms windows so a contended `acquire`
    /// never blocks a Swift cooperative thread-pool thread.
    ///
    /// NB: `DispatchSemaphore.wait(timeout:)` is unavailable from `async`
    /// contexts under Swift 6 strict concurrency (the compiler rejects it
    /// regardless of timeout). The blocking call lives in the synchronous
    /// `tryAcquire()` helper — the restriction is lexical to `async` functions,
    /// so a sync helper is the documented escape. `wait(timeout: .now())` is the
    /// standard non-blocking try (decrements + `.success` if a slot is free,
    /// else `.timedOut` immediately); we back it with a cooperative 5 ms
    /// `Task.sleep` between attempts to avoid a hot spin.
    public func acquire() async -> CVPixelBuffer {
        while !tryAcquire() {
            try? await Task.sleep(nanoseconds: 5_000_000)   // 5 ms cooperative poll
        }
        var pb: CVPixelBuffer?
        // 3-arg form (allocator, pool, out). The 4-arg `...WithAuxAttributes`
        // variant is unneeded — the pool already carries the per-buffer attrs.
        CVPixelBufferPoolCreatePixelBuffer(nil, pool!, &pb)
        return pb!                   // pool-backed; nil only on exhausted memory
    }

    /// Non-blocking slot try (synchronous — escapes the async `wait()` ban).
    private func tryAcquire() -> Bool {
        slots.wait(timeout: .now()) == .success
    }

    public func release(_ pb: CVPixelBuffer) {
        _ = pb                        // CVPixelBuffer is CF-managed; ARC releases it
        slots.signal()                // free one slot
    }

    /// RGBA8Image -> 32BGRA CVPixelBuffer. R<->B swap per pixel; top-first copy
    /// (no flip — RGBA8Image is already top-first, the CVPixelBuffer layout for
    /// video). Premultiplied alpha is preserved: premult is the per-pixel
    /// relation R,G,B <= A; permuting R and B leaves both <= A.
    public func fill(_ pb: CVPixelBuffer, from image: RGBA8Image) {
        precondition(image.width == width && image.height == height, "PixelBufferPool: size mismatch")
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let dst = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(pb)
        image.pixels.withUnsafeBufferPointer { src in
            for y in 0..<height {
                let s = y * width * 4
                let d = y * rowBytes
                for x in 0..<width {
                    let si = s + x * 4, di = d + x * 4
                    dst[di + 0] = src[si + 2]      // B
                    dst[di + 1] = src[si + 1]      // G
                    dst[di + 2] = src[si + 0]      // R
                    dst[di + 3] = src[si + 3]      // A
                }
            }
        }
    }
}
