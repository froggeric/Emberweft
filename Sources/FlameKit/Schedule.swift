import Foundation

/// One rendered segment of an animation timeline.
///
/// A `Segment` describes a contiguous run of `framesPerSegment` PNGs that all
/// interpolate between two sheep (a *loop* interpolates a sheep with itself).
/// `Schedule` materializes segments lazily as the timeline is walked forward.
public struct Segment: Sendable, Equatable {
    /// Whether this segment holds on one sheep (`loop`) or morphs between two
    /// (`transition`).
    public enum Kind: Sendable, Equatable {
        /// `fromSheep == toSheep`: the segment renders one genome at varying blend.
        case loop
        /// `fromSheep != toSheep`: the segment morphs `fromSheep` → `toSheep`.
        case transition
    }

    /// 0-based position of this segment in the timeline.
    public let id: Int
    /// `.loop` or `.transition`.
    public let kind: Kind
    /// Index of the source sheep in the library.
    public let fromSheep: Int
    /// Index of the destination sheep (`== fromSheep` for loops).
    public let toSheep: Int
    /// Frames emitted for this segment (`N` in the blend formula).
    public let framesPerSegment: Int

    public init(id: Int, kind: Kind, fromSheep: Int, toSheep: Int, framesPerSegment: Int) {
        self.id = id
        self.kind = kind
        self.fromSheep = fromSheep
        self.toSheep = toSheep
        self.framesPerSegment = framesPerSegment
    }
}

/// The result of mapping one global frame to its segment + blend.
///
/// Returned by `Schedule.frameToBlend(globalFrame:)` in O(1).
public struct FrameMapping: Sendable, Equatable {
    /// The segment this global frame belongs to (`globalFrame / N`).
    public let segmentId: Int
    /// The kind of that segment (derivable from `segmentId` parity in O(1)).
    public let kind: Segment.Kind
    /// 1-indexed blend in `(0, 1]`: `(local + 1) / N`. NEVER 0.
    public let blend: Double
}

/// Two-level-seek animation schedule: a pure value-type timeline that maps any
/// global frame to `(segmentId, kind, blend)` in **O(1)**, and any `segmentId`
/// to a `Segment` in **O(1)** within the materialized prefix (and O(segments)
/// amortized to extend the selector walk forward).
///
/// # Frame-counting convention (pinned — off-by-one hazard)
///
/// flam3 emits `N = framesPerSegment` frames per segment at blend = frame/N for
/// frame = 1...N (1-indexed). So blend ∈ {1/N, 2/N, …, 1.0}; **blend = 0 is
/// never emitted**. Consecutive segments therefore tile with no duplicate
/// boundary frame: segment k's last frame is blend = 1.0, segment k+1's first
/// frame is blend = 1/N.
///
///     segmentId = globalFrame / N
///     local     = globalFrame % N
///     blend     = Double(local + 1) / Double(N)        // ∈ (0, 1]
///
/// Total PNGs emitted over k segments = `k * N` (no boundary duplicate/drop).
///
/// # Alternation scheme
///
/// Segments strictly alternate loop / transition by `segmentId` parity:
///
///     seg 0 = loop(A)          // even → loop, holds on A
///     seg 1 = transition(A→B)  // odd  → transition, advances selector A→B
///     seg 2 = loop(B)          // even → loop, holds on B
///     seg 3 = transition(B→C)  // odd  → transition, B→C
///     seg 4 = loop(C)          // …
///
/// The invariant "no two transitions consecutive" holds for every prefix by
/// construction (transitions only occupy odd ids).
///
/// - `loop` segment: `fromSheep == toSheep == currentSheep`; `currentSheep`
///   unchanged.
/// - `transition` segment: `fromSheep == currentSheep`, `toSheep` = selector's
///   pick; `currentSheep` advances to that pick.
///
/// # Seeded-RNG choice
///
/// `Sequential`'s walk is a pure modular increment and needs no RNG. The
/// `seed` parameter is stored for API uniformity and for Task 16's
/// `SimilarityExploration`, which will use Emberweft's `PCG32` (already in
/// FlameKit) for reproducible, per-process-stable selection. No per-process
/// hash randomization enters the walk.
///
/// # Sendable / mutability
///
/// `Schedule` is a `Sendable` value type. `segment(at:)` is `mutating` because
/// it extends the lazy walk cache (`segments`, `selector`, `currentSheep`).
/// `frameToBlend(globalFrame:)` is non-mutating and pure O(1). Copying a
/// `Schedule` forks the walk cache, which is the intended value semantics.
public struct Schedule: Sendable {
    /// Number of genomes in the library.
    public let librarySize: Int
    /// Frames per segment (`N`).
    public let framesPerSegment: Int
    /// Seed reserved for selectors that consume one (recorded for reproducibility).
    public let seed: UInt64

    // MARK: - Lazy walk cache (mutated only by `segment(at:)`)

    /// Materialized prefix of the timeline, indexed by `Segment.id`.
    public private(set) var segments: [Segment] = []
    /// The selector, advanced once per transition segment.
    public private(set) var selector: any PairSelector
    /// Sheep index that the next segment will start from.
    public private(set) var currentSheep: Int = 0

    /// Construct a schedule. The selector should already be seeded if it
    /// consumes a seed; `seed` is stored for diagnostics/reconstruction.
    ///
    /// - Parameters:
    ///   - librarySize: Number of genomes. Must be > 0. Must be > 1 for
    ///     non-degenerate transitions.
    ///   - framesPerSegment: Frames per segment (`N`). Must be > 0.
    ///   - selector: The pair-selection strategy (e.g. `Sequential`).
    ///   - seed: Seed recorded for reproducibility (see class doc).
    public init(librarySize: Int, framesPerSegment: Int,
                selector: any PairSelector, seed: UInt64) {
        precondition(librarySize > 0, "librarySize must be > 0")
        precondition(framesPerSegment > 0, "framesPerSegment must be > 0")
        self.librarySize = librarySize
        self.framesPerSegment = framesPerSegment
        self.selector = selector
        self.seed = seed
    }

    // MARK: - Level 1: global frame → (segmentId, kind, blend) — O(1), pure

    /// Map a global frame index to its segment id, kind, and blend.
    ///
    /// Pure and O(1): does not consult the lazy walk cache (kind is derived
    /// from `segmentId` parity). `blend ∈ (0, 1]`; **never 0**.
    public func frameToBlend(globalFrame: Int) -> FrameMapping {
        precondition(globalFrame >= 0, "globalFrame must be >= 0")
        let N = framesPerSegment
        let segmentId = globalFrame / N
        let local = globalFrame % N
        let blend = Double(local + 1) / Double(N)
        let kind: Segment.Kind = segmentId.isMultiple(of: 2) ? .loop : .transition
        return FrameMapping(segmentId: segmentId, kind: kind, blend: blend)
    }

    /// Total PNGs emitted over `segmentCount` segments = `segmentCount * N`.
    public func totalFrames(segmentCount: Int) -> Int {
        precondition(segmentCount >= 0, "segmentCount must be >= 0")
        return segmentCount * framesPerSegment
    }

    /// True iff `globalFrame` is the **first frame of a transition segment** — the
    /// loop→transition boundary.
    ///
    /// flam3 fires a `seqflag && blend==0` shortcut here (flam3.c:476-477:
    /// `flam3_copy(result, &prealign[0])`) that returns A un-aligned, SKIPPING the
    /// align+establish+rotate+interpolate chain. Emberweft's 1-indexed schedule
    /// emits `blend = 1/N` at this frame (not 0) — already morphed ~1/N toward B —
    /// so without routing, the boundary frame is a discontinuity vs the preceding
    /// loop's pure-A endpoint (and the `.log` polar round-trip residual
    /// decorrelates spiky attractors; ~21 MAD measured on 09557→21924, dropping to
    /// the ~5 MAD rotation seam once callers render A directly here). Callers
    /// (`AnimateCommand.blendAt`, `PlaybackDispatcher.renderOneFrame`) render the
    /// fromSheep genome directly when this returns true, matching flam3's shortcut.
    ///
    /// Pure + O(1) (uses `frameToBlend`, not the lazy segment walk). `globalFrame %
    /// N == 0` iff it is the first frame of some segment; with `kind ==
    /// .transition` this isolates the loop→transition start. For `N == 1` every
    /// frame is a segment start, so a transition's single frame returns A —
    /// matching flam3's `nframes==1` `frame==0 → blend==0 → seqflag` path.
    public func isLoopToTransitionBoundary(globalFrame: Int) -> Bool {
        precondition(globalFrame >= 0, "globalFrame must be >= 0")
        let m = frameToBlend(globalFrame: globalFrame)
        return m.kind == .transition && globalFrame % framesPerSegment == 0
    }

    // MARK: - Level 2: segmentId → Segment — O(1) prefix, amortized O(1) extend

    /// Return the `Segment` at `id`, materializing/extension the selector walk
    /// forward as needed. After this call, `segments.count > id`.
    public mutating func segment(at id: Int) -> Segment {
        precondition(id >= 0, "segment id must be >= 0")
        while segments.count <= id {
            appendNextSegment()
        }
        return segments[id]
    }

    /// Append the next segment per the alternation scheme:
    /// even id → loop(currentSheep); odd id → transition(currentSheep → next),
    /// advancing `currentSheep` and the selector.
    private mutating func appendNextSegment() {
        let id = segments.count
        let kind: Segment.Kind = id.isMultiple(of: 2) ? .loop : .transition
        switch kind {
        case .loop:
            segments.append(Segment(id: id, kind: .loop,
                                    fromSheep: currentSheep, toSheep: currentSheep,
                                    framesPerSegment: framesPerSegment))
        case .transition:
            let nxt = selector.next(from: currentSheep, librarySize: librarySize)
            segments.append(Segment(id: id, kind: .transition,
                                    fromSheep: currentSheep, toSheep: nxt,
                                    framesPerSegment: framesPerSegment))
            currentSheep = nxt
        }
    }
}
