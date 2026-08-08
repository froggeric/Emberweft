import Foundation
import FlameKit

/// Serializable selector choice for `ExportJob` (M6 wires `.sequential` only).
/// `.similarity` is a placeholder for the GUI export-sheet slice; it requires
/// `FeatureVector`s that the headless CLI does not yet source.
public enum SelectorSpec: String, Codable, Sendable, CaseIterable {
    case sequential
    case similarity
}

public struct ExportProgress: Sendable {
    public enum Phase: Sendable { case rendering, encoding, concatenating, finalizing }
    public let phase: Phase
    public let currentFrame: Int
    public let totalFrames: Int
    public let elapsed: Double
    public let renderFPS: Double
    public init(phase: Phase, currentFrame: Int, totalFrames: Int, elapsed: Double, renderFPS: Double) {
        self.phase = phase; self.currentFrame = currentFrame; self.totalFrames = totalFrames
        self.elapsed = elapsed; self.renderFPS = renderFPS
    }
}

/// Per-job + aggregate progress for a batch run (`ExportCoordinator.runBatch`).
///
/// `jobFrame`/`jobTotalFrames` mirror the inner `ExportProgress` (currentFrame/
/// totalFrames); `aggregateFraction` is a pure function of (jobIndex, per-job
/// frame progress) over `totalJobs` — `(Double(jobIndex) + jobFrame/jobTotalFrames)
/// / totalJobs` — so it is deterministic and rule-#2-safe (no float sum over a
/// hashed collection). `failed` records a per-job failure (continue-by-default):
/// the consumer tallies the failed jobIndexes and computes the batch exit code
/// (`failures.isEmpty ? 0 : 1`). Exactly one `failed: true` event is emitted per
/// failed job; successful jobs emit only `failed: false` events.
public struct BatchProgress: Sendable, Equatable {
    public let jobIndex: Int
    public let totalJobs: Int
    public let jobFrame: Int
    public let jobTotalFrames: Int
    public let aggregateFraction: Double
    public let failed: Bool
    public init(jobIndex: Int, totalJobs: Int, jobFrame: Int, jobTotalFrames: Int,
                aggregateFraction: Double, failed: Bool) {
        self.jobIndex = jobIndex; self.totalJobs = totalJobs
        self.jobFrame = jobFrame; self.jobTotalFrames = jobTotalFrames
        self.aggregateFraction = aggregateFraction; self.failed = failed
    }
}

/// Resolves a manifest `out` name under a batch base dir, rejecting traversal.
/// This is the D13 security gate for `--jobs` manifests: a malicious manifest
/// entry MUST NOT escape the base dir.
///
/// Rule: reject absolute paths and any `..`/`.` segment BEFORE flattening to
/// the leaf (`URL(fileURLWithPath:).lastPathComponent` alone would silently
/// strip `..`, accepting "../../etc/passwd" as "passwd" — a false pass), then
/// allowlist the leaf's characters against `[A-Za-z0-9._-]` and reject hidden
/// (leading `.`) or empty stems. The result is always exactly one clean path
/// component under `base` — it can never escape `base`.
public enum BatchPath {
    public enum BatchPathError: Error, Equatable, Sendable {
        case traversal      // absolute, `..`/`.` segment, hidden stem, or empty
        case illegalCharacters
    }

    public static func resolve(_ raw: String, base: URL) throws -> URL {
        // Absolute paths and any `..`/`.` segment are traversal, rejected up
        // front (before `lastPathComponent` could hide them).
        if raw.hasPrefix("/") { throw BatchPathError.traversal }
        let comps = raw.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if comps.contains("..") || comps.contains(".") { throw BatchPathError.traversal }
        // Flatten declared subdirs to the single leaf (the resolved result is
        // always `<base>/<leaf>` — one component, never nested outside base).
        guard let leaf = comps.last else { throw BatchPathError.traversal }   // empty raw
        if leaf.hasPrefix(".") { throw BatchPathError.traversal }   // hidden stem (.foo)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        if leaf.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            throw BatchPathError.illegalCharacters
        }
        return base.appendingPathComponent(leaf)
    }
}

/// One export. `flames` are pre-parsed; `schedule` is materialized by the coordinator
/// via `FramePlan`. `partialURL` is the atomic-encode target (renamed to `out` on success).
public struct ExportJob: Sendable {
    public let settings: ExportSettings
    public let flames: [Flame]
    public let framesPerSegment: Int
    /// Frames per **transition** segment. Defaults to `framesPerSegment` (uniform
    /// timeline) when omitted — preserves today's behavior for existing callers.
    public let transitionFramesPerSegment: Int
    public let segmentCount: Int
    public let selector: SelectorSpec
    public let seed: UInt64
    public let loopCycles: Int
    public let stagger: Double
    public let out: URL
    public let partialURL: URL
    /// Loop render-once-repeat (v0.5.0). When `> 1`, each **loop** segment is
    /// rendered ONCE into an in-memory cache, then appended `loopRepeatCount`× to
    /// the encoder (a loop is seamless — `R(360°)=R(0°)` — so the repeats are
    /// invisible). Transition segments are never repeated (a morph isn't
    /// seamless). `== 1` is the no-op: the existing per-frame render+append loop
    /// runs byte-for-byte unchanged (every animate↔export byte-identity pin
    /// routes through it). The CLI default is `1` (preserves byte-identity with
    /// current behavior); the GUI default is `2` (the owner's "15 s render → 30 s
    /// perceived loop" optimization). Determinism (rule #2): each loop frame is
    /// rendered exactly once (cached) and the identical bytes are written
    /// `repeatCount`× — no re-render, no reseed.
    public let loopRepeatCount: Int
    public init(settings: ExportSettings, flames: [Flame], framesPerSegment: Int,
                transitionFramesPerSegment: Int? = nil,
                segmentCount: Int, selector: SelectorSpec, seed: UInt64,
                loopCycles: Int, stagger: Double, out: URL, loopRepeatCount: Int = 1) {
        self.settings = settings; self.flames = flames
        self.framesPerSegment = framesPerSegment
        self.transitionFramesPerSegment = transitionFramesPerSegment ?? framesPerSegment
        self.segmentCount = segmentCount
        self.selector = selector; self.seed = seed; self.loopCycles = loopCycles
        self.stagger = stagger; self.out = out
        self.loopRepeatCount = max(1, loopRepeatCount)
        // Atomic-encode target = `<dir>/<stem>.partial-<pid>.<ext>`. Built from
        // `out`'s dir + stem + ext explicitly: the chain
        // `out.deletingPathExtension().appendingPathComponent(…).appendingPathExtension(…)`
        // treats the stem as a DIRECTORY and nests the file inside it
        // (`/tmp/x/x.mp4.partial-1234.mp4`), which is wrong. This form lands
        // the `<pid>`-suffixed partial beside `out` on the same volume (atomic rename).
        let stem = out.deletingPathExtension().lastPathComponent
        let ext = out.pathExtension
        let dir = out.deletingLastPathComponent()
        let partialName = ext.isEmpty
            ? "\(stem).partial-\(getpid())"
            : "\(stem).partial-\(getpid()).\(ext)"
        self.partialURL = dir.appendingPathComponent(partialName)
    }
}
