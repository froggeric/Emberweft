import Foundation

/// Memoized per-thread ISAAC seeds for one export run.
///
/// `MetalHost.buildThreadSeeds(seed:threadCount:)` is a PURE deterministic
/// function of `(seed, threadCount)`. For a fixed export, both `(seed,
/// threadCount)` are constant across frames (constant `RenderParams`), so the
/// memo hits after frame 0 -> the per-frame host-side CPU draw (O(totalSamples)
/// ISAAC draws, the dominant offline cost at high spp) happens ONCE. This is the
/// M6 export acceleration; it is byte-identical to per-frame computation
/// (memoization of a pure function) and parity-guarded by
/// `ThreadSeedBudgetTests`. Realtime passes `nil` (untouched).
///
/// Design: a memo keyed by `(passIndex, threadCount)` wrapping
/// `MetalHost.buildThreadSeeds`. The renderer keeps computing `perPassThreads`
/// itself (no formula duplication); the budget just caches the result. The pass
/// seed for pass `i` is `baseSeed &+ UInt64(i)`, matching `renderTemporalFused`.
///
/// Byte-identity contract: callers MUST set `baseSeed` to the render's
/// `params.seed` for the budget path to match the `nil` (realtime) path, which
/// seeds pass `i` with `params.seed &+ UInt64(i)`. (`ExportCoordinator` does this.)
public extension MetalRenderer {
    final class ThreadSeedBudget: @unchecked Sendable {
        public let baseSeed: UInt64
        private let lock = NSLock()
        private var cache: [Key: [UInt64]] = [:]
        private struct Key: Hashable { let pass: Int; let threadCount: Int }

        public init(baseSeed: UInt64) { self.baseSeed = baseSeed }

        /// Seeds for chaos pass `index` (0 for single-pass) at the given thread count.
        public func seeds(forPass index: Int, threadCount: Int) -> [UInt64] {
            let key = Key(pass: index, threadCount: threadCount)
            lock.lock(); defer { lock.unlock() }
            if let hit = cache[key] { return hit }
            let built = MetalHost.buildThreadSeeds(seed: baseSeed &+ UInt64(index),
                                                    threadCount: threadCount)
            cache[key] = built
            return built
        }
    }
}
