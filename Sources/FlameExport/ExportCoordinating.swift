import Foundation

/// Testability seam: `ExportManager` holds its coordinator via this protocol so
/// `EmberweftUITests` can inject a fake (no Metal/AVFoundation).
/// `ExportCoordinator` conforms trivially (it already has these signatures).
///
/// `run`/`runBatch` are declared `async` because `ExportCoordinator` is an
/// `actor` whose `run`/`runBatch` are non-async actor-ISOLATED methods. A
/// non-async non-isolated protocol requirement CANNOT be satisfied by an
/// actor-isolated witness (Swift compile error: "actor-isolated instance
/// method cannot satisfy nonisolated protocol requirement"). An `async`
/// requirement CAN be satisfied by a non-async isolated method — the
/// cross-actor hop makes the call async. `ExportManager` already calls these
/// with `await` (`let stream = await coord.run(job)`), so the async signatures
/// match the call sites. The actor's own method declarations stay non-async
/// (the CLI's `await coord.run(job)` is unchanged). `cancel()` is already
/// `async` on the actor.
///
/// `runLongForm` is intentionally NOT in the seam: the GUI sets
/// `segmentFrameBudget = 0`, so `runLongForm` is never dispatched (single/
/// sequence route through `run`, batch through `runBatch`).
public protocol ExportCoordinating: Sendable {
    func run(_ job: ExportJob) async -> AsyncThrowingStream<ExportProgress, Error>
    func runBatch(_ jobs: [ExportJob], failFast: Bool) async -> AsyncThrowingStream<BatchProgress, Error>
    /// M6.1: resumable dispatch — chunks the timeline at frame-count edges,
    /// writes a checkpoint after each chunk, concats on completion. `resumeFrom`
    /// is a checkpoint URL to resume from (nil = fresh run). Satisfies the seam
    /// the same way `run` does (the actor's non-async isolated witness meets the
    /// `async` requirement via a cross-actor hop).
    func runResumable(_ job: ExportJob, checkpointIntervalFrames: Int,
                      resumeFrom checkpointURL: URL?) async -> AsyncThrowingStream<ExportProgress, Error>
    func cancel() async
    /// M6.1: cooperative pause — sets the `paused` flag, checked at each chunk
    /// top in `runResumableBody`. The in-flight chunk is abandoned (NOT
    /// checkpointed); the checkpoint + completed chunks survive for resume.
    func pause() async
}
