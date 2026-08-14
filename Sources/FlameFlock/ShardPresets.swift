// Sources/FlameFlock/ShardPresets.swift
import Foundation
import FlameExport   // ExportSettings.Codec

/// The canonical shard catalog the GUI offers when an archive is empty (or
/// lacks a wanted profile). Pure data — no I/O, no actor — so the pickers can
/// always present a sensible set even before any shard row exists in
/// `flock.sqlite` (a fresh archive has exactly one: the default 1080p30).
///
/// The shard ROW is created on demand: the GUI upserts the selected
/// `ShardSpec` at the start of generate/stitch (the `artifacts.shard` FK
/// requires the row to pre-exist), so selecting a preset that has never been
/// rendered just works — no pre-seeding of the catalog.
///
/// Determinism (rule #2): `sensible` is a fixed, ascending-pixels array (ordered
/// data, not a hash collection). Every name is derived through
/// `FlockNaming.shardDir` — the single source of truth for shard naming — so a
/// preset name and an archive directory name can never disagree.
public enum ShardPresets {

    /// The canonical pace (D3): 15 s loops / 12 s transitions. Mirrors
    /// `FlockNaming.shardDir`'s defaults and the GUI's pace steppers.
    public static let fps = 30
    public static let loopSeconds = 15.0
    public static let transSeconds = 12.0

    /// Build one canonical-pace shard for a resolution. Names come from
    /// `FlockNaming.shardDir` (pure arithmetic — the `try?` fallback is
    /// unreachable, kept so the helper stays total).
    private static func make(width: Int, height: Int) -> ShardSpec {
        let lf = Int((loopSeconds * Double(fps)).rounded())
        let tf = Int((transSeconds * Double(fps)).rounded())
        let name = (try? FlockNaming.shardDir(
            width: width, height: height, fps: fps,
            loopFrames: lf, transFrames: tf)) ?? "\(width)x\(height)_\(fps)fps"
        return ShardSpec(
            name: name, width: width, height: height, fps: fps,
            loopSeconds: loopSeconds, transSeconds: transSeconds,
            loopFrames: lf, transFrames: tf,
            isCanonical: true, codec: .hevc)
    }

    /// The sensible canonical shards — 720p / 1080p / 1440p / 4K at 30 fps, all
    /// at the canonical pace (15 s loops / 12 s edges ⇒ names `1280x720_30fps`,
    /// `1920x1080_30fps`, `2560x1440_30fps`, `3840x2160_30fps`). Ascending
    /// pixels (deterministic order); HEVC per the archive-wide codec decision
    /// (D12).
    public static let sensible: [ShardSpec] = [
        make(width: 1280, height: 720),
        make(width: 1920, height: 1080),
        make(width: 2560, height: 1440),
        make(width: 3840, height: 2160),
    ]

    /// The canonical default: 1080p30 at the canonical pace. Used as the
    /// fallback when a preferred shard name is unset or unknown (it is also
    /// `AppPreferences.flockDefaultShard`'s nil-default resolution).
    public static let canonicalDefault: ShardSpec = make(width: 1920, height: 1080)

    /// Look a preset up by shard name (nil for a non-preset name). Linear over
    /// the small fixed array (rule #2 — no hashed collection).
    public static func preset(named name: String) -> ShardSpec? {
        sensible.first { $0.name == name }
    }
}

// MARK: - Pace editing (shared by the GUI's Generate + Stitch steppers)

extension ShardSpec {

    /// Re-derive `loopFrames` / `transFrames` / `isCanonical` / `name` after a
    /// pace edit, leaving resolution, fps, and codec untouched. The name comes
    /// from `FlockNaming.shardDir`, so a NON-canonical pace yields the
    /// `_Lf<loop>-Tf<trans>` suffix (a new shard directory) while the canonical
    /// 15 s / 12 s pace keeps the bare `WxH_fps` name. Pure (rule #2).
    public func withPace(loopSeconds: Double, transSeconds: Double) -> ShardSpec {
        let lf = Int((loopSeconds * Double(fps)).rounded())
        let tf = Int((transSeconds * Double(fps)).rounded())
        let base = "\(width)x\(height)_\(fps)fps"
        let name = (try? FlockNaming.shardDir(
            width: width, height: height, fps: fps,
            loopFrames: lf, transFrames: tf)) ?? base
        var out = self
        out.loopSeconds = loopSeconds
        out.transSeconds = transSeconds
        out.loopFrames = lf
        out.transFrames = tf
        out.isCanonical = (name == base)
        out.name = name
        return out
    }
}
