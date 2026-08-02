import Foundation

/// A complete, pure recipe for rendering one global frame of a Schedule timeline.
/// Constructed once per `animate`/`export` run; `descriptor(for:)` is O(1) and
/// non-mutating. Drives both `AnimateCommand` (byte-identical) and the export
/// coordinator. All captures are Sendable value types -> rule-#2-safe.
public struct FrameDescriptor: Sendable {
    public let globalFrame: Int
    public let segmentId: Int
    public let kind: Segment.Kind
    public let blend: Double                      // (0,1], 1-indexed (Schedule convention)
    public let fromSheep: Int
    public let toSheep: Int
    /// Temporal sub-samples with deltas already scaled to blend units
    /// (`raw.delta / framesPerSegment` — the load-bearing frame->blend fix).
    /// N==1 -> [(0,1)] (identity; byte-matches the single-pass path).
    public let temporal: [(delta: Double, weight: Double)]
    public let sumfilt: Double
    /// Builds the Flame at sub-time `centerTime + delta`. Loop unclamped
    /// (periodic rotation); Transition clamped to [0,1] (AnimateCommand semantics).
    /// The loop->transition boundary is NOT short-circuited here — the offline
    /// path relies on temporal blur to average the residual (CLAUDE.md gotcha).
    public let blendAt: @Sendable (Double) -> Flame
}

/// Pre-materialized, pure timeline over a `Schedule`. Freezes the (mutating)
/// segment walk at construction so `descriptor(for:)` is pure O(1).
public struct FramePlan: Sendable {
    public let framesPerSegment: Int
    public let totalFrames: Int
    public let temporalSamples: Int
    private let schedule: Schedule          // walk materialized in init
    public let flames: [Flame]
    public let loopCycles: Int
    public let stagger: Double

    public init(schedule: inout Schedule, segmentCount: Int, flames: [Flame],
                loopCycles: Int = 1, stagger: Double = 0, temporalSamples: Int = 1) {
        precondition(segmentCount >= 1, "FramePlan: segmentCount must be >= 1")
        var s = schedule
        for id in 0..<segmentCount { _ = s.segment(at: id) }   // populate the walk cache
        self.schedule = s
        self.framesPerSegment = s.framesPerSegment
        self.totalFrames = s.totalFrames(segmentCount: segmentCount)
        self.temporalSamples = max(1, temporalSamples)
        self.flames = flames
        self.loopCycles = loopCycles
        self.stagger = stagger
    }

    /// Pure O(1). Mirrors AnimateCommand's per-frame construction exactly.
    public func descriptor(for globalFrame: Int) -> FrameDescriptor {
        let mapping = schedule.frameToBlend(globalFrame: globalFrame)
        let segment = schedule.segments[mapping.segmentId]
        let fps = Double(segment.framesPerSegment)
        let (raw, sumfilt): ([(delta: Double, weight: Double)], Double) = temporalSamples > 1
            ? TemporalFilter.samples(
                temporalSamples,
                type: flames[segment.fromSheep].quality.temporalFilterType,
                width: flames[segment.fromSheep].quality.temporalFilterWidth,
                exp:    flames[segment.fromSheep].quality.temporalFilterExp)
            : ([(delta: 0.0, weight: 1.0)], 1.0)
        let temporal = raw.map { (delta: $0.delta / fps, weight: $0.weight) }

        let flames = self.flames
        let cycles = loopCycles
        let stag = stagger
        let kind = segment.kind
        let from = segment.fromSheep
        let to = segment.toSheep
        let blendAt: @Sendable (Double) -> Flame = { t in
            switch kind {
            case .loop:
                return Loop.blend(flames[from], t: t, cycles: cycles)
            case .transition:
                return Transition.blend(flames[from], flames[to],
                                        t: min(max(t, 0.0), 1.0), stagger: stag)
            }
        }
        return FrameDescriptor(
            globalFrame: globalFrame, segmentId: mapping.segmentId, kind: mapping.kind,
            blend: mapping.blend, fromSheep: from, toSheep: to,
            temporal: temporal, sumfilt: sumfilt, blendAt: blendAt)
    }
}
