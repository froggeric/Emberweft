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
    /// The segment this global frame belongs to (derived from the pair structure).
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
/// Emberweft emits `N` frames per segment at `blend = (local + 1) / N` for
/// `local = 0...N-1` (**1-indexed**): blend ∈ {1/N, 2/N, …, 1.0}; **blend = 0 is
/// never emitted**. Consecutive segments tile with no duplicate boundary frame:
/// segment k's last frame is blend = 1.0, segment k+1's first is blend = 1/N.
/// `N` is **per-kind**: `framesPerSegment` for loops, `transitionFramesPerSegment`
/// for transitions (loops can be longer than transitions so edges stay brief).
///
/// Segments alternate loop,transition by id parity, so a loop+transition pair is a
/// fixed block of `pairFrames = framesPerSegment + transitionFramesPerSegment`:
///
///     pairIndex = globalFrame / pairFrames
///     within    = globalFrame % pairFrames
///     if within < framesPerSegment → loop seg id = 2*pairIndex,      N = framesPerSegment
///     else                         → transition seg id = 2*pairIndex+1, N = transitionFramesPerSegment
///     blend = Double(local + 1) / Double(N)        // ∈ (0, 1]
///
/// Total PNGs emitted over k segments = `loops*framesPerSegment +
/// transitions*transitionFramesPerSegment` (loops = `ceil(k/2)`, trans =
/// `floor(k/2)`; no boundary duplicate/drop).
///
/// ## Deliberate divergence from flam3 (NOT a match)
///
/// flam3 is **0-indexed**: `blend = frame/nframes` for `frame = 0...N-1`, i.e.
/// blend ∈ {0, 1/N, …, (N-1)/N} (starts at 0, stops one step short of 1.0). An
/// earlier version of this comment mis-claimed flam3 was 1-indexed — it is not.
/// Emberweft's 1-indexing is a deliberate choice, kept because landing the last
/// frame at exactly `blend = 1.0` makes both segment boundaries endpoint-exact:
/// - **Loop** last frame reaches `θ = 360°` → `R(360°) = R(0°)` within FP, so the
///   loop→transition handoff is seamless (a 0-indexed loop stops at 356.4°, a
///   3.6° gap to the boundary's pure-A 0°).
/// - **Transition** last frame reaches exactly B (100%), matching the next
///   loop's B start (a 0-indexed transition stops at 99% B).
///
/// Tradeoffs (all sub-perceptual):
/// - **1/N phase offset from flam3** — every Emberweft frame is one step offset
///   from flam3's grid; AnimationParity tests still pass (43–58 dB).
/// - **blend = 0 is never emitted** → the loop→transition `seqflag` shortcut
///   (`flam3.c:476-477`) ports at the CALLER layer
///   (`isLoopToTransitionBoundary`) rather than as `if t == 0` inside
///   `Transition.blend` (whose `t == 0` is therefore never reached in playback).
/// - **First transition morph step is ~2/N** (the boundary frame is pure A, the
///   next is blend = 2/N) vs flam3's uniform ~1/N steps.
///
/// Switching to 0-indexed would regress both boundaries (3.6° start gap +
/// 99%-B end) for no perceptual gain and shift every frame's blend — don't.
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
    /// Frames per **loop** segment (`N` for loops).
    public let framesPerSegment: Int
    /// Frames per **transition** segment (`N` for transitions). Defaults to
    /// `framesPerSegment` (uniform timeline = today's behavior) when the caller
    /// omits it. Lets transitions ("edges") be shorter than loops so loops can
    /// breathe while transitions stay brief.
    public let transitionFramesPerSegment: Int
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
    ///   - framesPerSegment: Frames per **loop** segment (`N` for loops). Must be > 0.
    ///   - transitionFramesPerSegment: Frames per **transition** segment. Pass
    ///     `nil` (default) for a uniform timeline (== `framesPerSegment`,
    ///     today's behavior); pass a smaller value for shorter transitions/edges.
    ///     Must be > 0 when non-nil.
    ///   - selector: The pair-selection strategy (e.g. `Sequential`).
    ///   - seed: Seed recorded for reproducibility (see class doc).
    public init(librarySize: Int, framesPerSegment: Int,
                transitionFramesPerSegment: Int? = nil,
                selector: any PairSelector, seed: UInt64) {
        precondition(librarySize > 0, "librarySize must be > 0")
        precondition(framesPerSegment > 0, "framesPerSegment must be > 0")
        let t = transitionFramesPerSegment ?? framesPerSegment
        precondition(t > 0, "transitionFramesPerSegment must be > 0")
        self.librarySize = librarySize
        self.framesPerSegment = framesPerSegment
        self.transitionFramesPerSegment = t
        self.selector = selector
        self.seed = seed
    }

    // MARK: - Level 1: global frame → (segmentId, kind, blend) — O(1), pure

    /// Map a global frame index to its segment id, kind, and blend.
    ///
    /// Pure and O(1): does not consult the lazy walk cache (kind is derived
    /// from the pair structure). `blend ∈ (0, 1]`; **never 0**.
    ///
    /// Segments strictly alternate loop,transition,loop,transition,…, so a
    /// loop+transition pair is a fixed block of `pairFrames = framesPerSegment +
    /// transitionFramesPerSegment`. For a global frame `g`:
    ///
    ///     pairIndex = g / pairFrames
    ///     within    = g % pairFrames
    ///     if within < framesPerSegment → loop seg id = 2*pairIndex, local = within
    ///     else                        → transition seg id = 2*pairIndex + 1,
    ///                                    local = within - framesPerSegment
    ///     N (denominator) = the segment's own framesPerSegment (loop or transition)
    ///
    /// When the timeline ends on a loop (odd `segmentCount`, e.g. `2N−1` for an
    /// N-genome pass), the final loop's frames fall in the loop slot of the last
    /// pair (`within < framesPerSegment`), so they map to `id = 2*pairIndex`
    /// (loop) — they never spill into a non-existent transition. Callers only
    /// request frames in `[0, totalFrames)`, so the (non-existent) transition slot
    /// of a trailing-only pair is never reached.
    public func frameToBlend(globalFrame: Int) -> FrameMapping {
        precondition(globalFrame >= 0, "globalFrame must be >= 0")
        let L = framesPerSegment
        let T = transitionFramesPerSegment
        let pairFrames = L + T
        let pairIndex = globalFrame / pairFrames
        let within = globalFrame % pairFrames
        if within < L {
            // Loop slot of this pair.
            let segmentId = 2 * pairIndex
            let local = within
            let blend = Double(local + 1) / Double(L)
            return FrameMapping(segmentId: segmentId, kind: .loop, blend: blend)
        } else {
            // Transition slot of this pair.
            let segmentId = 2 * pairIndex + 1
            let local = within - L
            let blend = Double(local + 1) / Double(T)
            return FrameMapping(segmentId: segmentId, kind: .transition, blend: blend)
        }
    }

    /// Cumulative frame offset of the START of segment `s` (i.e. frames emitted
    /// by segments `[0, s)`). Loops (even ids) contribute `framesPerSegment`;
    /// transitions (odd ids) contribute `transitionFramesPerSegment`. O(1), pure.
    public func frameOffset(ofSegment s: Int) -> Int {
        precondition(s >= 0, "segment index must be >= 0")
        let loops = (s + 1) / 2       // even ids in [0, s): 0,2,…
        let trans = s / 2             // odd ids in [0, s): 1,3,…
        return loops * framesPerSegment + trans * transitionFramesPerSegment
    }

    /// Total PNGs emitted over `segmentCount` segments. Loops = `ceil(s/2)`,
    /// transitions = `floor(s/2)` (segmentCount for a full N-genome pass is `2N−1`).
    public func totalFrames(segmentCount: Int) -> Int {
        precondition(segmentCount >= 0, "segmentCount must be >= 0")
        return frameOffset(ofSegment: segmentCount)
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
    /// Pure + O(1). Uses the pair structure: a boundary is the first frame of a
    /// transition slot, i.e. `within == framesPerSegment` (the slot's local 0).
    /// For `transitionFramesPerSegment == 1` the single transition frame returns A
    /// — matching flam3's `nframes==1` `frame==0 → blend==0 → seqflag` path.
    public func isLoopToTransitionBoundary(globalFrame: Int) -> Bool {
        precondition(globalFrame >= 0, "globalFrame must be >= 0")
        let pairFrames = framesPerSegment + transitionFramesPerSegment
        let within = globalFrame % pairFrames
        // Transition slot starts at `framesPerSegment`; its local 0 == a boundary.
        return within == framesPerSegment
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
    /// advancing `currentSheep` and the selector. Loop segments use
    /// `framesPerSegment`; transition segments use `transitionFramesPerSegment`
    /// (which may be shorter for brief edges).
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
                                    framesPerSegment: transitionFramesPerSegment))
            currentSheep = nxt
        }
    }
}
