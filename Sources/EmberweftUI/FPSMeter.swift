import Foundation

/// Rolling-average framerate meter with a ~2 Hz publish throttle. **Diagnostic
/// only** (wall-clock timing) — it never touches render output, so it does not
/// affect determinism (rule #2). Shared by both playback view-models.
///
/// Why a throttle: the transport bar already re-evaluates each frame (the
/// position slider), but a digit twitching at 60 Hz in the periphery is itself a
/// distraction and reads as noise. Publishing a rolling average at ~2 Hz makes
/// the digit *settle* onto the steady-state band (Weber-Fechner: you perceive
/// the band, not frame-to-frame jitter).
///
/// Value type — the view-models own one as `var` and read the returned FPS on
/// each presented frame; tests drive it with synthetic monotonic timestamps.
public struct FPSMeter: Sendable {

    /// Number of recent frame-to-frame intervals to average (≈0.5 s at 60 fps).
    private let window: Int
    /// Minimum seconds between published updates (2 Hz).
    private let publishInterval: Double

    private var intervals: [Double] = []
    private var lastInstant: Double?
    private var lastPublish: Double = 0

    public init(window: Int = 30, publishInterval: Double = 0.5) {
        self.window = max(window, 2)
        self.publishInterval = max(publishInterval, 0)
    }

    /// Record one presented frame at monotonic instant `now` (seconds). Returns
    /// the updated measured FPS when the throttle window elapses (and at least
    /// one interval exists), otherwise `nil` — the caller keeps the prior value.
    /// Call exactly once per displayed frame.
    public mutating func record(now: Double) -> Double? {
        guard let prev = lastInstant else {
            // First frame: seed the throttle clock; no interval to average yet.
            lastInstant = now
            lastPublish = now
            return nil
        }
        let dt = now - prev
        lastInstant = now
        if dt > 0 {
            intervals.append(dt)
            if intervals.count > window { intervals.removeFirst() }
        }
        guard now - lastPublish >= publishInterval, !intervals.isEmpty else { return nil }
        lastPublish = now
        let mean = intervals.reduce(0, +) / Double(intervals.count)
        return mean > 0 ? 1.0 / mean : 0
    }

    /// Clear history (paused / stopped / reloaded). The next `record` restarts
    /// fresh so a stale pre-pause FPS can't bleed into the next play session.
    public mutating func reset() {
        intervals.removeAll(keepingCapacity: true)
        lastInstant = nil
        lastPublish = 0
    }
}
