import XCTest
import AVFoundation
@testable import FlameExport
import FlameKit

final class VideoEncoderMetadataTests: XCTestCase {
    func tmpURL(_ name: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
    }

    /// One black frame sized to the encoder's resolution. `AVAssetWriter` rejects
    /// `finishWriting()` on a session with zero samples ("media may be damaged",
    /// `-11829`), so each test appends a single filler frame before `finish()`;
    /// metadata is container-level (independent of frame count).
    private func blackFrame(matching settings: ExportSettings) -> RGBA8Image {
        let w = settings.resolution.width, h = settings.resolution.height
        return RGBA8Image(width: w, height: h, pixels: [UInt8](repeating: 0, count: w * h * 4))
    }

    /// Default `[]` ⇒ writer.metadata stays empty (byte-identical regression pin).
    func testDefaultMetadataIsEmpty() async throws {
        let out = tmpURL("meta-empty.mov")
        try? FileManager.default.removeItem(at: out)
        var settings = ExportSettings()
        settings.codec = .hevc; settings.container = .mov
        settings.resolution = .p720; settings.fps = 30
        let enc = try VideoEncoder(settings: settings, outputURL: out)   // default metadata: []
        try await enc.start()
        try await enc.append(blackFrame(matching: settings), atFrame: 0)
        try await enc.finish()
        let asset = AVURLAsset(url: out)
        let common = try await asset.load(.commonMetadata)
        XCTAssertTrue(common.isEmpty, "default render must carry no metadata")
        try? FileManager.default.removeItem(at: out)
    }

    /// Write common-key + custom-keyspace tags; read back via AVURLAsset.
    func testRoundTripCommonAndCustomKeyspace() async throws {
        let out = tmpURL("meta-tagged.mov")
        try? FileManager.default.removeItem(at: out)
        var settings = ExportSettings()
        settings.codec = .hevc; settings.container = .mov
        settings.resolution = .p720; settings.fps = 30

        // `AVMutableMetadataItem.commonKey` is get-only on the macOS 26 SDK, so a
        // common-key item is built via `key` + `keySpace = .common` (AVFoundation
        // resolves `commonKey` from that pair). `value`/`key` are typed
        // `(any NSCopying & NSObjectProtocol)?`, hence the `NSString` casts.
        let title = AVMutableMetadataItem()
        title.keySpace = .common
        title.key = AVMetadataKey.commonKeyTitle.rawValue as NSString
        title.value = "248=00628=248=00628" as NSString
        title.extendedLanguageTag = "und"
        // AVAssetWriter persists custom tags into a `.mov` ONLY via the `mdta`
        // keyspace (rawValue "mdta" — there is no `AVMetadataKeySpace.metadata`
        // constant on this SDK). A custom-named keyspace (e.g. rawValue
        // "emberweft") is silently dropped by the writer. So the `emberweft.*`
        // namespace is encoded as the mdta KEY (Apple's own convention:
        // "com.apple.quicktime.*"), not as a separate keyspace.
        let spp = AVMutableMetadataItem()
        spp.keySpace = AVMetadataKeySpace(rawValue: "mdta")
        spp.key = "emberweft.spp" as NSString
        spp.value = "30" as NSString

        let enc = try VideoEncoder(settings: settings, outputURL: out, metadata: [title, spp])
        try await enc.start()
        try await enc.append(blackFrame(matching: settings), atFrame: 0)
        try await enc.finish()

        let asset = AVURLAsset(url: out)
        let common = try await asset.load(.commonMetadata)
        XCTAssertEqual(common.first(where: { $0.commonKey == .commonKeyTitle })?.value as? String,
                       "248=00628=248=00628")
        // Non-common items (the mdta `emberweft.spp` tag) do NOT surface in
        // `.commonMetadata` (that property only carries common-key equivalents);
        // read them via `.metadata`, which returns items across all keyspaces.
        let all = try await asset.load(.metadata)
        let sppBack = all.first {
            $0.keySpace == AVMetadataKeySpace(rawValue: "mdta")
                && ($0.key as? String) == "emberweft.spp"
        }
        XCTAssertEqual(sppBack?.value as? String, "30")
        try? FileManager.default.removeItem(at: out)
    }
}
