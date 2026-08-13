import Foundation
import FlameExport
import FlameFlock

/// EmberweftUI-side types for the Flock sidebar (Task 15). The request/progress
/// value types live in `FlameFlock` (`GenerateRequest`, `StitchRequest`,
/// `GenerateUIProgress`, `StitchUIProgress`, `FlockSnapshot`) and are reused
/// as-is; this file holds only the UI state machines + the testability seams.
///
/// All set-like / multi-valued fields here are scalars or single values — no FP
/// accumulation over a `Dictionary`/`Set` (rule #2). The state enums carry only
/// counts/URLs/strings; transitions are pure value assignments on `FlockModel`.

// MARK: - UI state machines (spec §13.1)

/// Generate state machine: `idle → resolving → running → completed | failed | cancelled`.
/// The `running` tuple carries the live `(skip, render, total)` counters from
/// `GenerateUIProgress.running` plus a smoothed `etaSeconds` (nil ⇒ cold-start
/// "estimating…"); `rendering` carries the same counters AND the current unit's
/// within-range frame progress (`frame`/`frameTotal`) emitted per-frame by
/// `GenerateCoordinator` (v0.5.8 — the per-video-file progress the owner wants).
/// `completed` carries the final tally. `failed` carries a user-facing message;
/// `cancelled` is terminal.
public enum GenerateUIState: Sendable, Equatable {
    case idle
    case resolving
    case running(skip: Int, render: Int, total: Int, etaSeconds: Double?)
    case rendering(skip: Int, render: Int, total: Int, frame: Int, frameTotal: Int, etaSeconds: Double?)
    case completed(rendered: Int, skipped: Int)
    case failed(String)
    case cancelled
}

// MARK: - ETA estimator (v0.5.8)

/// Pure per-unit EMA ETA estimator for Flock Generate (mirrors `ExportManager`'s
/// per-frame `frameSecondsEMA` at unit granularity — units are the natural ETA
/// grain here since each is a self-contained render). A value type with NO
/// wall-clock state: the VM (`FlockModel`) feeds it real/scripted per-unit
/// durations and the remaining-unit count. Determinism (rule #2): the estimate
/// is a pure function of the fed durations; no hashed-collection float sums.
///
/// Cold start: returns `nil` (⇒ "estimating…") until `completedUnits >=
/// coldStartFloor` real samples have been recorded. A single outlier unit is
/// clamped to 3× the running EMA so one slow/stalled unit can't blow up the ETA
/// (mirrors `ExportManager.applyETA`'s clamp).
public struct GenerateETAEstimator: Equatable, Sendable {
    public private(set) var unitSecondsEMA: Double = 0
    public private(set) var completedUnits: Int = 0
    public let alpha: Double
    public let coldStartFloor: Int

    /// `alpha` = EMA weight on the newest sample (0.4 ⇒ ~last 3–4 units
    /// dominant, `1/alpha ≈ 2.5`); `coldStartFloor` = min samples before an ETA
    /// is shown (3 — at unit granularity each sample is already a substantial
    /// average, unlike export's per-frame floor of 8).
    public init(alpha: Double = 0.4, coldStartFloor: Int = 3) {
        self.alpha = alpha
        self.coldStartFloor = coldStartFloor
    }

    /// Record one completed unit's wall-clock duration (seconds). Seeds the EMA
    /// with the FIRST sample (unlike `ExportManager`'s ramp-from-zero, which at
    /// unit granularity would systematically under-estimate the ETA for the first
    /// few minutes-long units). After seeding, clamps each new sample to 3× the
    /// running EMA so a single slow unit (or a brief stall) can't dominate.
    public mutating func record(unitSeconds: Double) {
        if completedUnits == 0 {
            unitSecondsEMA = unitSeconds
        } else {
            let effective = min(unitSeconds, 3 * unitSecondsEMA)
            unitSecondsEMA = alpha * effective + (1 - alpha) * unitSecondsEMA
        }
        completedUnits += 1
    }

    /// Estimated seconds remaining for `remainingUnits` (may be fractional — the
    /// VM passes a partial count mid-unit so the ETA decreases smoothly within a
    /// unit), or nil during cold start. Pure: a function of the EMA + remaining.
    public func etaSeconds(remainingUnits: Double) -> Double? {
        guard completedUnits >= coldStartFloor else { return nil }
        return max(0, remainingUnits) * unitSecondsEMA
    }

    /// Reset for a fresh run.
    public mutating func reset() {
        unitSecondsEMA = 0
        completedUnits = 0
    }
}

/// Stitch state machine: `idle → resolving → plan → running → completed | failed | cancelled`.
/// `plan` carries the HIT/MISS tally from the single batched catalog lookup;
/// `running` carries the per-segment `(hit, generated)` counters; `completed`
/// carries the assembled output URL.
public enum StitchUIState: Sendable, Equatable {
    case idle
    case resolving
    case plan(hit: Int, miss: Int)
    case running(hit: Int, generated: Int)
    case completed(URL)
    case failed(String)
    case cancelled
}

/// Browse state machine: `loading → loaded | empty | failed`. `loaded` carries
/// the value-type `FlockSnapshot` (a copy of catalog counts — the GUI never
/// reads SQLite directly). `empty` is the zero-shard/zero-artifact case.
public enum BrowseUIState: Sendable, Equatable {
    case loading
    case loaded(FlockSnapshot)
    case empty
    case failed(String)
}

// MARK: - Testability seams (mirror `ExportCoordinating`)

/// Testability seam: `FlockModel` holds its generate coordinator via this
/// protocol so `EmberweftUITests` can inject a spy (no Metal / AVFoundation /
/// SQLite). `GenerateCoordinator` conforms trivially — it already has these
/// signatures (the conformance is declared below).
///
/// `generate(_:coordinator:)` is declared `async` because `GenerateCoordinator`
/// is an `actor` whose `generate` is a non-`async` actor-ISOLATED method. A
/// non-`async` non-isolated protocol requirement CANNOT be satisfied by an
/// actor-isolated witness (Swift compile error). An `async` requirement CAN be
/// satisfied by a non-`async` isolated method — the cross-actor hop makes the
/// call `async` (same trick `ExportCoordinating` uses for `run`). `cancel()` is
/// already `async` on the actor.
public protocol GeneratingCoordinating: Sendable {
    func generate(_ request: GenerateRequest,
                  coordinator: ExportCoordinator) async -> AsyncThrowingStream<GenerateUIProgress, Error>
    func cancel() async
}

/// Testability seam for the stitch coordinator (twin of `GeneratingCoordinating`).
public protocol StitchingCoordinating: Sendable {
    func stitch(_ request: StitchRequest,
                coordinator: ExportCoordinator) async -> AsyncThrowingStream<StitchUIProgress, Error>
    func cancel() async
}

/// `GenerateCoordinator` (FlameFlock) already implements both requirements; the
/// conformance is auto-synthesized. Declared here (in EmberweftUI, the protocol
/// module) so the default+production factory can return the concrete actor.
/// (Retroactive conformance — the type and protocol are in different modules.
/// `@retroactive` is intentionally omitted: it is only needed to silence a
/// diagnostic in strict mode, and the attribute cannot decorate an extension
/// declaration in this compiler version.)
extension GenerateCoordinator: GeneratingCoordinating {}

/// `StitchCoordinator` (FlameFlock) — same as above.
extension StitchCoordinator: StitchingCoordinating {}
