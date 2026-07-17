import Foundation

/// Strategy for choosing the next sheep to transition into, given the current
/// sheep index and the size of the genome library.
///
/// A `PairSelector` owns whatever state it needs (e.g. a seeded RNG) and is
/// advanced exactly once per **transition** segment by `Schedule`. The protocol
/// is a value type with a `mutating` step so a `Schedule` can drive the walk
/// forward while preserving value semantics on copy.
///
/// Implementations:
/// - `Sequential`: deterministic `(current + 1) % librarySize` cycle (Task 15).
/// - `SimilarityExploration`: similarity-biased jumps with escapes (Task 16).
///
/// The shape intentionally accommodates Task 16's needs: the selector receives
/// `librarySize` so it can pick a valid target, and returns the chosen target
/// index. Escapes / similarity scoring live inside the implementer, not here.
public protocol PairSelector: Sendable {
    /// Return the sheep index to transition into next, given the current index.
    ///
    /// - Parameters:
///   - current: The current sheep index (`0 ..< librarySize`).
///   - librarySize: Number of genomes in the library.
    /// - Returns: The next sheep index (`0 ..< librarySize`). Must differ from
    ///   `current` when `librarySize > 1`.
    mutating func next(from current: Int, librarySize: Int) -> Int
}

/// The simplest `PairSelector`: a fixed, library-cyclic walk.
///
/// `Sequential` always returns `(current + 1) % librarySize`. The walk is fully
/// determined by `librarySize` and the starting index, so it is reproducible
/// across processes and threads with no RNG dependence — the `seed` is stored
/// for uniformity with the `PairSelector`/`Schedule` API and for forward-compat
/// with selectors that do consume it (Task 16's `SimilarityExploration`), but
/// `Sequential` itself is seed-independent. This is documented, not a bug: a
/// cyclic increment has no degrees of freedom for a seed to perturb.
///
/// `Sendable` value type. Reproducibility (F1 determinism spirit) holds by
/// construction: integer arithmetic, no per-process hash randomization.
public struct Sequential: PairSelector {
    /// Stored for API uniformity and diagnostics; not consumed by the walk.
    public let seed: UInt64

    /// - Parameter seed: Reserved for selectors that consume a seed. `Sequential`
    ///   ignores it (its walk is fixed by `librarySize`), but stores it so two
    ///   `Sequential` instances compare equal when constructed identically.
    public init(seed: UInt64) {
        self.seed = seed
    }

    public mutating func next(from current: Int, librarySize: Int) -> Int {
        precondition(librarySize > 0, "librarySize must be > 0")
        precondition(current >= 0 && current < librarySize,
                     "current (\(current)) out of range 0..<\(librarySize)")
        // librarySize == 1 => no transition is meaningful; return current so the
        // (degenerate) transition segment is a no-op. Schedule callers normally
        // require librarySize >= 2 for real transitions.
        if librarySize == 1 { return 0 }
        return (current + 1) % librarySize
    }
}
