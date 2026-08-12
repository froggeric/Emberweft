// Tests/FlameFlockTests/FlockNamingTests.swift
import XCTest
@testable import FlameFlock

/// Task 6 — `FlockNaming` encode/decode + shard dir + path safety.
///
/// NOTE on id emission: `fileName` emits ids VERBATIM (no padding). ES ids
/// (e.g. "00628") are preserved as-is; minted ids are zero-padded to 6 digits
/// by `IdMinter` (T8) BEFORE being handed to `fileName`. The plan's original
/// `pad` closure inside `fileName` was a defect (it would corrupt ES ids like
/// "00628" → "000628"); these tests pin the corrected verbatim behavior.
final class FlockNamingTests: XCTestCase {

    // MARK: - fileName (verbatim id emission)

    func testFileNamePreservesESIdsVerbatim() {
        // The plan's pad closure would have left "00628" alone (already 5 digits
        // < 6 ⇒ padded to "000628"), corrupting the sheep's identity. Verbatim
        // emission keeps it as-is.
        XCTAssertEqual(
            FlockNaming.fileName(aGen: "248", aId: "00628", bGen: "248", bId: "00628", ext: "mov"),
            "248=00628=248=00628.mov"
        )
    }

    func testFileNameMintedIdAlreadyPaddedPassesThrough() {
        // IdMinter (T8) zero-pads to 6 digits and passes the final string here;
        // fileName emits it verbatim. The caller owns the final id form.
        XCTAssertEqual(
            FlockNaming.fileName(aGen: "900000", aId: "000042", bGen: "900000", bId: "000042", ext: "mov"),
            "900000=000042=900000=000042.mov"
        )
    }

    func testFileNameDoesNotPadUnpaddedInput() {
        // Direct pin against the plan's defective pad closure: an unpadded id
        // MUST stay unpadded (padding is NOT fileName's job).
        XCTAssertEqual(
            FlockNaming.fileName(aGen: "900000", aId: "42", bGen: "900000", bId: "42", ext: "mov"),
            "900000=42=900000=42.mov"
        )
    }

    func testFileNameEdgesAndExtensions() {
        // ES edge (cross-sheep, same gen)
        XCTAssertEqual(
            FlockNaming.fileName(aGen: "248", aId: "00628", bGen: "248", bId: "03194", ext: "mov"),
            "248=00628=248=03194.mov"
        )
        // cross-gen edge
        XCTAssertEqual(
            FlockNaming.fileName(aGen: "247", aId: "00100", bGen: "248", bId: "00628", ext: "mov"),
            "247=00100=248=00628.mov"
        )
        // non-mov ext (thumbnails are .jpg)
        XCTAssertEqual(
            FlockNaming.fileName(aGen: "248", aId: "00628", bGen: "248", bId: "00628", ext: "jpg"),
            "248=00628=248=00628.jpg"
        )
    }

    // MARK: - decode

    // Tuples cannot conform to Equatable in Swift, so assert field-by-field.
    private func assertDecoded(_ d: (aGen: String, aId: String, bGen: String, bId: String),
                               _ expected: (String, String, String, String),
                               _ message: String = "",
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(d.aGen, expected.0, "aGen — \(message)", file: file, line: line)
        XCTAssertEqual(d.aId, expected.1, "aId — \(message)", file: file, line: line)
        XCTAssertEqual(d.bGen, expected.2, "bGen — \(message)", file: file, line: line)
        XCTAssertEqual(d.bId, expected.3, "bId — \(message)", file: file, line: line)
    }

    func testDecodeRoundTripsLoopEdgeCrossGenMinted() {
        assertDecoded(FlockNaming.decode(stem: "248=00628=248=00628")!,
                      ("248", "00628", "248", "00628"), "loop")
        assertDecoded(FlockNaming.decode(stem: "248=00628=248=03194")!,
                      ("248", "00628", "248", "03194"), "ES edge")
        assertDecoded(FlockNaming.decode(stem: "247=00100=248=00628")!,
                      ("247", "00100", "248", "00628"), "cross-gen edge")
        assertDecoded(FlockNaming.decode(stem: "900000=000042=900000=000042")!,
                      ("900000", "000042", "900000", "000042"), "minted")
    }

    func testDecodeStrictnessRejectsBadStems() {
        // 3 fields
        XCTAssertNil(FlockNaming.decode(stem: "248=00628=248"))
        // 5 fields
        XCTAssertNil(FlockNaming.decode(stem: "248=00628=248=00628=extra"))
        // non-digit field
        XCTAssertNil(FlockNaming.decode(stem: "248=abc=248=248"))
        // path-traversal token
        XCTAssertNil(FlockNaming.decode(stem: "248=00628=248=.."))
        // path separator
        XCTAssertNil(FlockNaming.decode(stem: "248=00628=248=a/b"))
        // empty stem
        XCTAssertNil(FlockNaming.decode(stem: ""))
    }

    // MARK: - isLoop

    func testIsLoopIffBothPairsEqual() {
        XCTAssertTrue(FlockNaming.isLoop(aGen: "248", aId: "628", bGen: "248", bId: "628"))
        XCTAssertFalse(FlockNaming.isLoop(aGen: "248", aId: "628", bGen: "248", bId: "3194"),
                       "different id ⇒ not a loop")
        XCTAssertFalse(FlockNaming.isLoop(aGen: "248", aId: "628", bGen: "247", bId: "628"),
                       "different gen ⇒ not a loop")
    }

    // MARK: - shardDir

    func testShardDirCanonicalVsNonCanonicalAt30fps() throws {
        // 30 fps ⇒ canonical loopFrames=450 (round(15·30)), transFrames=360 (round(12·30)).
        XCTAssertEqual(try FlockNaming.shardDir(width: 1920, height: 1080, fps: 30,
                                               loopFrames: 450, transFrames: 360),
                       "1920x1080_30fps")
        XCTAssertEqual(try FlockNaming.shardDir(width: 1920, height: 1080, fps: 30,
                                               loopFrames: 495, transFrames: 300),
                       "1920x1080_30fps_Lf495-Tf300")
    }

    func testShardDirCanonicalVsNonCanonicalAt24fps() throws {
        // 24 fps ⇒ canonical loopFrames=round(15·24)=360, transFrames=round(12·24)=288.
        XCTAssertEqual(try FlockNaming.shardDir(width: 1280, height: 720, fps: 24,
                                               loopFrames: 360, transFrames: 288),
                       "1280x720_24fps")
        XCTAssertEqual(try FlockNaming.shardDir(width: 1280, height: 720, fps: 24,
                                               loopFrames: 400, transFrames: 288),
                       "1280x720_24fps_Lf400-Tf288")
    }

    // MARK: - isValidShardName

    func testIsValidShardName() {
        // canonical shard dirs: only [A-Za-z0-9_]
        XCTAssertTrue(FlockNaming.isValidShardName("1920x1080_30fps"))
        XCTAssertTrue(FlockNaming.isValidShardName("name_with_underscores123"))

        // rejections
        XCTAssertFalse(FlockNaming.isValidShardName("../evil"))
        XCTAssertFalse(FlockNaming.isValidShardName("1920x1080_30fps/.."))
        XCTAssertFalse(FlockNaming.isValidShardName("with/slash"))
        XCTAssertFalse(FlockNaming.isValidShardName("has space"))
        // Hyphen IS admitted: non-canonical shard names produced by shardDir()
        // contain `-` (e.g. `1920x1080_30fps_Lf495-Tf300`); rebuild must NOT
        // skip them, so the regex class is [A-Za-z0-9_-].
        XCTAssertTrue(FlockNaming.isValidShardName("has-dash"))
        XCTAssertTrue(FlockNaming.isValidShardName("1920x1080_30fps_Lf495-Tf300"))
        XCTAssertFalse(FlockNaming.isValidShardName(""))
    }

    /// A non-canonical shard name (with `-`, as `shardDir` emits) must round-trip
    /// through `archiveFileURL` — the regex admits `-` so rebuild + the URL
    /// builders accept non-canonical shards. (Regression: the regex once rejected
    /// `-`, which would have silently dropped every non-canonical shard on rebuild.)
    func testArchiveURLAcceptsNonCanonicalShard() throws {
        let root = tempRoot
        let url = try FlockNaming.archiveFileURL(flockRoot: root, shardDir: "1920x1080_30fps_Lf495-Tf300",
                                                  aGen: "248", aId: "00628", bGen: "248", bId: "00628", ext: "mov")
        XCTAssertEqual(url.lastPathComponent, "248=00628=248=00628.mov")
        // <root>/<shard>/mpeg/<file> ⇒ shard sits two levels above the file.
        XCTAssertEqual(url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent,
                       "1920x1080_30fps_Lf495-Tf300")
    }

    // MARK: - archiveFileURL / thumbURL path safety

    private var tempRoot: URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("emberweft-flock-test-\(UUID().uuidString)")
    }

    func testArchiveURLRejectsBadShards() throws {
        let root = tempRoot
        // `..` traversal
        XCTAssertThrowsError(
            try FlockNaming.archiveFileURL(flockRoot: root, shardDir: "../evil",
                                           aGen: "248", aId: "628", bGen: "248", bId: "628", ext: "mov"))
        // embedded `..` after a slash (bad shard: contains `/` + `..`)
        XCTAssertThrowsError(
            try FlockNaming.archiveFileURL(flockRoot: root, shardDir: "1920x1080_30fps/..",
                                           aGen: "248", aId: "628", bGen: "248", bId: "628", ext: "mov"))
        // shard containing `/`
        XCTAssertThrowsError(
            try FlockNaming.archiveFileURL(flockRoot: root, shardDir: "has/slash",
                                           aGen: "248", aId: "628", bGen: "248", bId: "628", ext: "mov"))
        // shard with space (regex reject)
        XCTAssertThrowsError(
            try FlockNaming.archiveFileURL(flockRoot: root, shardDir: "has space",
                                           aGen: "248", aId: "628", bGen: "248", bId: "628", ext: "mov"))
    }

    func testArchiveURLBuildsExpectedPathInsideRoot() throws {
        let root = tempRoot
        let url = try FlockNaming.archiveFileURL(
            flockRoot: root, shardDir: "1920x1080_30fps",
            aGen: "248", aId: "00628", bGen: "248", bId: "00628", ext: "mov")
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        XCTAssertTrue(url.path.hasPrefix(resolvedRoot + "/"),
                      "archive URL must resolve inside flockRoot (got \(url.path))")
        XCTAssertTrue(url.path.hasSuffix("/1920x1080_30fps/mpeg/248=00628=248=00628.mov"),
                      "archive URL path mismatch: \(url.path)")
    }

    func testThumbURLRejectsBadShards() throws {
        let root = tempRoot
        XCTAssertThrowsError(
            try FlockNaming.thumbURL(flockRoot: root, shardDir: "../evil",
                                     aGen: "248", aId: "628", bGen: "248", bId: "628"))
        XCTAssertThrowsError(
            try FlockNaming.thumbURL(flockRoot: root, shardDir: "1920x1080_30fps/..",
                                     aGen: "248", aId: "628", bGen: "248", bId: "628"))
        XCTAssertThrowsError(
            try FlockNaming.thumbURL(flockRoot: root, shardDir: "has/slash",
                                     aGen: "248", aId: "628", bGen: "248", bId: "628"))
    }

    func testThumbURLBuildsExpectedPathInsideRoot() throws {
        let root = tempRoot
        let url = try FlockNaming.thumbURL(
            flockRoot: root, shardDir: "1920x1080_30fps",
            aGen: "248", aId: "00628", bGen: "248", bId: "00628")
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        XCTAssertTrue(url.path.hasPrefix(resolvedRoot + "/"),
                      "thumb URL must resolve inside flockRoot (got \(url.path))")
        XCTAssertTrue(url.path.hasSuffix("/1920x1080_30fps/jpeg/248=00628=248=00628.jpg"),
                      "thumb URL path mismatch: \(url.path)")
    }
}
