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
///
/// `cancelling` (v0.5.11) is the transient IMMEDIATE-feedback state: set
/// SYNCHRONOUSLY by `FlockModel.cancelGenerate()` the moment Cancel is pressed
/// — BEFORE the async unwind finishes — so the UI shows an indeterminate
/// "Cancelling…" (and disables Cancel) rather than stale render progress. A
/// terminal state (`.cancelled`, or `.completed` if the run raced completion)
/// replaces it. While cancelling, non-terminal progress events are ignored.
public enum GenerateUIState: Sendable, Equatable {
    case idle
    case resolving
    case running(skip: Int, render: Int, total: Int, etaSeconds: Double?)
    case rendering(skip: Int, render: Int, total: Int, frame: Int, frameTotal: Int, etaSeconds: Double?)
    /// Transient cancel-pending state (set synchronously on Cancel press).
    case cancelling
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

/// Stitch state machine: `idle → resolving → plan → running → rendering → concatenating → completed | failed | cancelled`.
/// `plan` carries the UNIQUE-key HIT/MISS tally from the single batched catalog
/// lookup plus the TIMELINE slot total (`segments` — with loop repetitions a
/// repeated loop is one HIT but `r` timeline slots, so hit + miss ≠ segments);
/// `running` carries the per-slot `(hit, generated)` counters (their sum is
/// slots assembled) plus the plan-derived `total` slot count (state-driven —
/// NOT the view's own sequence count, which can go stale mid-run) and a
/// smoothed `etaSeconds` (nil ⇒ cold-start "estimating…"); `rendering` is the
/// per-frame within-MISS progress (v0.5.9 — the blackout fix; `frame == 0` is
/// the pre-render yield); `concatenating` is the remux/copy tail phase
/// (indeterminate). `completed` carries the assembled output URL.
/// `cancelling` (v0.5.11) is the transient immediate-feedback twin of
/// `GenerateUIState.cancelling` (set synchronously by `cancelStitch()`).
public enum StitchUIState: Sendable, Equatable {
    case idle
    case resolving
    case plan(hit: Int, miss: Int, segments: Int)
    case running(hit: Int, generated: Int, total: Int, etaSeconds: Double?)
    case rendering(segment: Int, total: Int, isLoop: Bool, frame: Int, frameTotal: Int, etaSeconds: Double?)
    case concatenating(segments: Int)
    /// Transient cancel-pending state (set synchronously on Cancel press).
    case cancelling
    case completed(URL)
    case failed(String)
    case cancelled
}

/// Compact, view-model-derived "what is the flock doing right now" summary for
/// GLOBAL surfaces (the sidebar Flock row — v0.5.9). Built by `FlockModel.flockActivity`
/// from the generate/stitch states: pure value mapping of scalars (rule #2 — no
/// FP sums over hashed collections). `fraction == nil` ⇒ indeterminate (spinner);
/// `completed`/`total` feed the "3/12" token; `etaSeconds` the "~12:36" token.
public struct FlockActivitySummary: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable { case generate, stitch }

    public let kind: Kind
    /// Overall 0…1 progress when known; nil ⇒ indeterminate (show a spinner).
    public let fraction: Double?
    /// Completed unit count (units rendered-or-reused) when known.
    public let completed: Int?
    /// Total unit count when known.
    public let total: Int?
    /// ETA seconds once the estimator warms past its cold-start floor; nil ⇒ estimating.
    public let etaSeconds: Double?

    public init(kind: Kind, fraction: Double?, completed: Int?, total: Int?, etaSeconds: Double?) {
        self.kind = kind; self.fraction = fraction
        self.completed = completed; self.total = total; self.etaSeconds = etaSeconds
    }

    /// "Generating" / "Stitching" (the verb, for a sentence like "Flock: Stitching").
    public var kindLabel: String { kind == .generate ? "Generating" : "Stitching" }

    /// The compact sidebar token: "~12:36" (or "~1:03:27") when an ETA exists,
    /// else "3/12" when counts exist, else "" (spinner alone). Whole seconds,
    /// monospace-friendly digits.
    public var compactStatus: String {
        if let etaSeconds {
            let t = max(0, Int(etaSeconds.rounded()))
            if t >= 3600 { return String(format: "~%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60) }
            return String(format: "~%d:%02d", t / 60, t % 60)
        }
        if let completed, let total { return "\(completed)/\(total)" }
        return ""
    }
}

// MARK: - Shared duration/ETA formatting (single formatter — do not fork)

/// The ONE user-facing duration/ETA formatter (v0.5.9). Previously
/// `FlockView.etaLabel` and `ExportProgressSurface.etaLabel` were two private
/// copies of the same format; both now call these. Whole-second granularity
/// (avoids a twitching sub-second digit — the FPS-meter throttle philosophy);
/// the `~` prefix signals an estimate, not a countdown.
public enum ProgressFormatting {

    /// ETA as whole seconds / minutes / hours: "~42 s remaining",
    /// "~4 m 12 s remaining", "~1 h 3 m remaining".
    public static func etaLabel(_ eta: TimeInterval) -> String {
        let total = max(0, Int(eta.rounded()))
        if total < 60 { return "~\(total) s remaining" }
        let m = total / 60, r = total % 60
        if m < 60 { return "~\(m) m \(r) s remaining" }
        let h = m / 60, mr = m % 60
        return "~\(h) h \(mr) m remaining"
    }

    /// ETA token for a nullable ETA: nil ⇒ "estimating…" (cold start).
    public static func etaToken(_ eta: Double?) -> String {
        guard let eta else { return "estimating…" }
        return etaLabel(eta)
    }

    /// Elapsed as whole seconds / minutes / hours: "42 s", "4 m 12 s", "1 h 3 m".
    public static func elapsedLabel(_ elapsed: TimeInterval) -> String {
        let s = max(0, Int(elapsed.rounded()))
        if s < 60 { return "\(s) s" }
        let m = s / 60, r = s % 60
        if m < 60 { return "\(m) m \(r) s" }
        let h = m / 60, mr = m % 60
        return "\(h) h \(mr) m"
    }
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
