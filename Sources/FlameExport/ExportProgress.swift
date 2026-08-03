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

/// One export. `flames` are pre-parsed; `schedule` is materialized by the coordinator
/// via `FramePlan`. `partialURL` is the atomic-encode target (renamed to `out` on success).
public struct ExportJob: Sendable {
    public let settings: ExportSettings
    public let flames: [Flame]
    public let framesPerSegment: Int
    public let segmentCount: Int
    public let selector: SelectorSpec
    public let seed: UInt64
    public let loopCycles: Int
    public let stagger: Double
    public let out: URL
    public let partialURL: URL
    public init(settings: ExportSettings, flames: [Flame], framesPerSegment: Int,
                segmentCount: Int, selector: SelectorSpec, seed: UInt64,
                loopCycles: Int, stagger: Double, out: URL) {
        self.settings = settings; self.flames = flames
        self.framesPerSegment = framesPerSegment; self.segmentCount = segmentCount
        self.selector = selector; self.seed = seed; self.loopCycles = loopCycles
        self.stagger = stagger; self.out = out
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
