import Foundation

/// M6.7 D13: the ONE bitrate source. A pure pixel-band classifier so a named
/// preset and its `.custom` WxH twin encode identically (the pre-M6.7
/// hand-mirrored dictionaries keyed on named cases gave `.custom(720,1280)`
/// the 1080p-tier flat fallback — 2× `vertical720`'s bitrate for the same
/// pixels). Landscape named values are UNCHANGED. `VideoEncoder.autoBitrate`
/// and `ExportCoordinator.autoBitrateMbps` both delegate here.
///
/// Band boundaries (pixel count): ≤ 1,050,000 → 720p tier (1280×720 = 921,600);
/// ≤ 2,500,000 → 1080p tier (1080×1080 = 1,166,400 … 1920×1080 = 2,073,600);
/// ≤ 6,000,000 → 1440p tier (2560×1440 = 3,686,400); else 4K (8,294,400).
/// The 1.05 Mpx boundary sits between the 720p and square-1080 pixel counts so
/// every named case lands on its intended tier. ProRes returns 0 (sentinel:
/// fixed data-rate codec — the call site omits the bitrate key).
// internal (consumed only inside FlameExport + via @testable tests — the
// ExportManager.resolveSettings visibility precedent).
enum ExportBitrate {
    static func mbps(codec: ExportSettings.Codec, width: Int, height: Int, fps: Int) -> Int {
        if codec.isProRes { return 0 }
        let pixels = width * height
        let base: Int
        switch pixels {
        case ...1_050_000:  base = codec == .hevc ? 25 : 40
        case ...2_500_000:  base = codec == .hevc ? 50 : 80
        case ...6_000_000:  base = codec == .hevc ? 80 : 130
        default:            base = codec == .hevc ? 150 : 240
        }
        let fpsMult = fps >= 60 ? 1.5 : 1.0
        return Int(Double(base) * fpsMult)
    }
}
