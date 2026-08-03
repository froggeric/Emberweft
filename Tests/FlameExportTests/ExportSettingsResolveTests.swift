import XCTest
import Foundation
import FlameKit
@testable import FlameExport

/// M6-G.3: pins that `ExportSettings.resolve(…)` (the shared, pure, silent
/// settings resolver extracted from `EmberweftCLI.ExportCommand.resolveExportSettings`)
/// applies the motion-blur genome-default fallback + the Metal temporal cap
/// correctly, and that it performs NO I/O (no stderr) — the caller prints any cap
/// notice. This is the single source of truth the CLI + GUI both call so they
/// build byte-identical jobs (spec §4.2b; plan task M6-G.3).
final class ExportSettingsResolveTests: XCTestCase {

    /// AC: the resolver mirrors `ExportCommand.resolveExportSettings:374-382`
    /// exactly — (1) the motion-blur genome-default fallback (`requestedTS == 1`
    /// and `baseFlame.quality.temporalSamples > 1` ⇒ use the genome value), then
    /// (2) the Metal temporal cap (64) when `backend == .metal`. CPU is never
    /// capped. Each named integer is pinned.
    func testExportSettingsResolveGenomeFallbackAndMetalCap() {
        // A flame whose genome-default temporalSamples == 64. The fallback lands
        // EXACTLY at the cap (64 is NOT > 64, so the cap does NOT fire on Metal).
        // Resolved stays 64 on both backends — pins the fallback-only path.
        let flame64 = Flame(quality: Quality(temporalSamples: 64))

        let rMetal64 = ExportSettings.resolve(
            quality: .genome, temporalSamples: 1, codec: .h264, container: .mp4,
            fps: 30, bitrate: .auto, resolution: .p1080, segmentFrameBudget: 0,
            baseFlame: flame64, backend: .metal)
        XCTAssertEqual(rMetal64.temporalSamples, 64,
                       "genome fallback (ts=64) on Metal: 64 is not > 64, cap does not fire")

        let rCPU64 = ExportSettings.resolve(
            quality: .genome, temporalSamples: 1, codec: .h264, container: .mp4,
            fps: 30, bitrate: .auto, resolution: .p1080, segmentFrameBudget: 0,
            baseFlame: flame64, backend: .cpu)
        XCTAssertEqual(rCPU64.temporalSamples, 64,
                       "genome fallback (ts=64) on CPU: uncapped (CPU never caps)")

        // A flame whose genome-default temporalSamples == 200. The fallback bumps
        // ts to 200; on Metal the cap fires (200 > 64 → 64). On CPU it stays 200.
        let flame200 = Flame(quality: Quality(temporalSamples: 200))

        let rMetal200 = ExportSettings.resolve(
            quality: .genome, temporalSamples: 1, codec: .h264, container: .mp4,
            fps: 30, bitrate: .auto, resolution: .p1080, segmentFrameBudget: 0,
            baseFlame: flame200, backend: .metal)
        XCTAssertEqual(rMetal200.temporalSamples, 64,
                       "genome fallback (ts=200) + Metal cap → 64")

        let rCPU200 = ExportSettings.resolve(
            quality: .genome, temporalSamples: 1, codec: .h264, container: .mp4,
            fps: 30, bitrate: .auto, resolution: .p1080, segmentFrameBudget: 0,
            baseFlame: flame200, backend: .cpu)
        XCTAssertEqual(rCPU200.temporalSamples, 200,
                       "genome fallback (ts=200) on CPU: uncapped → 200")

        // Sanity: an explicit `requestedTS > 1` skips the genome fallback
        // entirely (mirrors `ts == 1` guard at ExportCommand.swift:375). Cap
        // still applies on Metal when the explicit value exceeds 64.
        let rExplicit100 = ExportSettings.resolve(
            quality: .genome, temporalSamples: 100, codec: .h264, container: .mp4,
            fps: 30, bitrate: .auto, resolution: .p1080, segmentFrameBudget: 0,
            baseFlame: flame200, backend: .metal)
        XCTAssertEqual(rExplicit100.temporalSamples, 64,
                       "explicit ts=100 (> 1) skips fallback; Metal caps 100 → 64")

        let rExplicit50 = ExportSettings.resolve(
            quality: .genome, temporalSamples: 50, codec: .h264, container: .mp4,
            fps: 30, bitrate: .auto, resolution: .p1080, segmentFrameBudget: 0,
            baseFlame: flame200, backend: .metal)
        XCTAssertEqual(rExplicit50.temporalSamples, 50,
                       "explicit ts=50 (≤ 64) is not capped on Metal")

        // Sanity: a genome with temporalSamples == 1 (the parser/flam3 default —
        // the common case for synthetic goldens like sierpinski). No fallback
        // fires (1 is not > 1); resolved stays 1 regardless of backend.
        let flame1 = Flame(quality: Quality(temporalSamples: 1))
        let rNoFallback = ExportSettings.resolve(
            quality: .genome, temporalSamples: 1, codec: .h264, container: .mp4,
            fps: 30, bitrate: .auto, resolution: .p1080, segmentFrameBudget: 0,
            baseFlame: flame1, backend: .metal)
        XCTAssertEqual(rNoFallback.temporalSamples, 1,
                       "no fallback when genome ts == 1; resolved stays 1")
    }

    /// AC: the resolver is PURE + SILENT — no I/O, no stderr. It MUST NOT print
    /// the Metal-cap notice (the caller detects the cap and prints its own).
    /// Captures stderr via dup2(2) and asserts it is empty, exercising the cap
    /// path (high temporalSamples + Metal) where the original printed the notice.
    func testExportSettingsResolveIsSilent() {
        let pipe = Pipe()
        let originalStderr = dup(STDERR_FILENO)
        XCTAssertEqual(dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO), STDERR_FILENO,
                       "dup2 must redirect stderr to the pipe")
        defer {
            dup2(originalStderr, STDERR_FILENO)
            close(originalStderr)
        }

        // Exercise the fallback + cap path (the exact case where the original
        // `resolveExportSettings` printed a stderr notice). Silence must hold.
        let flame = Flame(quality: Quality(temporalSamples: 200))
        _ = ExportSettings.resolve(
            quality: .genome, temporalSamples: 1, codec: .h264, container: .mp4,
            fps: 30, bitrate: .auto, resolution: .p1080, segmentFrameBudget: 0,
            baseFlame: flame, backend: .metal)

        // Restore stderr (closes fd 2's pipe-write reference) AND close the
        // pipe's own write fd, so BOTH references to the pipe write end are gone
        // and `readDataToEndOfFile` sees EOF instead of blocking. (The dup2 made
        // fd 2 a SECOND reference; closing only `fileHandleForWriting` leaves fd 2
        // open → the read would deadlock waiting for EOF.)
        dup2(originalStderr, STDERR_FILENO)
        pipe.fileHandleForWriting.closeFile()
        let captured = pipe.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(captured, Data(),
                       "resolve must be silent (no stderr); got: \(String(data: captured, encoding: .utf8) ?? "<non-utf8>")")
    }
}
