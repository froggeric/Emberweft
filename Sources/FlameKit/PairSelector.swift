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

/// ε-greedy similarity-biased `PairSelector` (Task 16).
///
/// With probability `epsilon` it **escapes** to a uniform-random sheep index
/// (drawn from the seeded `PCG32`). Otherwise it **exploits**: picks the most
/// similar (highest `FeatureVector.similarity`) sheep that is not in the
/// recency window. Ties break to the lowest index (deterministic). When the
/// recency window starves the candidate set, recent sheep are re-admitted
/// (current is always excluded when `librarySize > 1`).
///
/// # F1 DETERMINISM
/// The walk is driven by a seeded `PCG32` and integer-indexed structures only:
///   - escapes use `PCG32.nextIndex(_:)` (integer),
///   - the recency window is an integer `[Int]` (FIFO of sheep indices),
///   - the exploit scan iterates `0..<n` in index order (not a String-keyed
///     Dict/Set).
/// `FeatureVector.similarity(to:)` itself iterates sorted arrays (see F1 note
/// on `FeatureVector`). The whole selector is therefore bit-reproducible across
/// process launches.
///
/// `Sendable` value type. Accepts in-memory `FeatureVector`s directly — does
/// NOT require a Task-17 cache.
public struct SimilarityExploration: PairSelector {
    /// Stored for API uniformity / diagnostics; the RNG is seeded from this.
    public let seed: UInt64
    /// Escape probability in [0,1].
    public let epsilon: Double
    /// Maximum number of recently-visited sheep held in the recency window.
    public let recencyWindow: Int
    /// Per-sheep feature vectors, indexed by sheep index. The effective library
    /// size is `min(librarySize, featureVectors.count)` at each step.
    public let featureVectors: [FeatureVector]

    // Mutable walk state (value type — copied on assignment).
    private var rng: PCG32
    private var recentOrder: [Int] = []

    public init(
        seed: UInt64,
        epsilon: Double = 0.15,
        recencyWindow: Int = 4,
        featureVectors: [FeatureVector]
    ) {
        self.seed = seed
        self.epsilon = epsilon
        self.recencyWindow = max(0, recencyWindow)
        self.featureVectors = featureVectors
        self.rng = PCG32(seed: seed, stream: 0)
    }

    public mutating func next(from current: Int, librarySize: Int) -> Int {
        precondition(librarySize > 0, "librarySize must be > 0")
        let n = min(librarySize, featureVectors.count)
        if n <= 1 { return max(0, min(current, librarySize - 1)) }
        let cur = min(max(0, current), n - 1)

        let pick: Int
        // ε-greedy escape: uniform-random sheep via seeded PCG32 (deterministic).
        if Double(rng.nextFloat()) < epsilon {
            var p = rng.nextIndex(n)
            if p == cur { p = (p + 1) % n }
            pick = p
        } else {
            pick = mostSimilar(from: cur, n: n)
        }

        touchRecent(pick)
        return pick
    }

    /// Most-similar sheep to `cur` not in the recency window (lowest index
    /// breaks ties). Falls back to admitting recent sheep if starved.
    private func mostSimilar(from cur: Int, n: Int) -> Int {
        let curFV = featureVectors[cur]
        var best = -1
        var bestScore = -Double.infinity
        // Pass 1: exclude recent (integer-indexed scan — F1-safe).
        for cand in 0..<n where cand != cur && !isRecent(cand) {
            let s = curFV.similarity(to: featureVectors[cand])
            if s > bestScore { bestScore = s; best = cand }
        }
        // Pass 2: recency starved — re-admit recent (never current).
        if best < 0 {
            for cand in 0..<n where cand != cur {
                let s = curFV.similarity(to: featureVectors[cand])
                if s > bestScore { bestScore = s; best = cand }
            }
        }
        return best >= 0 ? best : (cur + 1) % n
    }

    private mutating func touchRecent(_ idx: Int) {
        guard recencyWindow > 0 else { return }
        recentOrder.removeAll { $0 == idx }
        recentOrder.append(idx)
        while recentOrder.count > recencyWindow { recentOrder.removeFirst() }
    }

    private func isRecent(_ idx: Int) -> Bool { recentOrder.contains(idx) }
}
