import Foundation
import FlamePlayer

/// Wall-clock conformer for `PlaybackClock` — the production pacing clock.
///
/// A plain `Sendable` value type. `now()` reads `DispatchTime.uptimeNanoseconds`
/// (monotonic, unaffected by wall-clock jumps / NTP). `sleep(until:)` sleeps to
/// the deadline, returning immediately if the deadline is already past (renderer
/// overran its frame budget — never hold/duplicate a frame to pad).
///
/// Mirrors the proven `PacedWallClock` recipe from `RealtimeCapabilityTests`.
public struct WallClock: PlaybackClock {

    public init() {}

    public func now() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1e9
    }

    public func sleep(until deadline: Double) async {
        let delta = deadline - now()
        guard delta > 0 else { return }
        // `Task.sleep` accepts nanoseconds; clamp to Int64 max to be safe.
        let ns = min(UInt64(delta * 1e9), UInt64(Int64.max))
        try? await Task.sleep(nanoseconds: ns)
    }
}
