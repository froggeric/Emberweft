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
/// `GenerateUIProgress.running`; `completed` carries the final tally. `failed`
/// carries a user-facing message; `cancelled` is terminal.
public enum GenerateUIState: Sendable, Equatable {
    case idle
    case resolving
    case running(skip: Int, render: Int, total: Int)
    case completed(rendered: Int, skipped: Int)
    case failed(String)
    case cancelled
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
