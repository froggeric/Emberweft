import XCTest
@testable import EmberweftUI
import FlameKit
import FlameExport

/// Pins the GUI export source-construction logic (M6.1). The original bug: the
/// sequence path set `flameIndex` to the sequence POSITION, but each source is a
/// single-flame document, so resume's `parse(serializedText)[flameIndex]` was
/// out of bounds ⇒ `ExportError.checkpointSourceChanged`. Construction now lives
/// in the tested `ExportSources` helper (EmberweftGUI has no test target).
final class ExportSourcesTests: XCTestCase {
    private func flame() throws -> Flame {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Goldens/genomes/sierpinski.flam3")
        return try Flam3Parser.parse(Data(contentsOf: url))[0]
    }

    func testSingleFileBackedHasNoSerializedText() throws {
        let f = try flame()
        let url = URL(fileURLWithPath: "/tmp/g.flam3")
        let sources = ExportSources.single(flame: f, fileURL: url, displayName: "g")
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources[0].fileURL, url)
        XCTAssertEqual(sources[0].flameIndex, 0)
        XCTAssertNil(sources[0].serializedText)   // file-backed ⇒ hash path; no text needed
        XCTAssertEqual(sources[0].displayName, "g")
    }

    func testSingleURLLessFallsBackToSerializedText() throws {
        let f = try flame()
        let sources = ExportSources.single(flame: f, fileURL: nil, displayName: "g")
        XCTAssertEqual(sources.count, 1)
        XCTAssertNil(sources[0].fileURL)
        XCTAssertEqual(sources[0].flameIndex, 0)
        XCTAssertNotNil(sources[0].serializedText)  // URL-less ⇒ text fallback so resume works
    }

    func testSequenceSerializedTextAllFlameIndexZero() throws {
        // The regression: flameIndex must be 0 for EVERY source (each serialized
        // text is one flame), NOT the sequence position 0,1,2.
        let flames = [Flame](repeating: try flame(), count: 3)
        let sources = ExportSources.sequence(flames: flames, fileURLs: nil, displayName: "seq")
        XCTAssertEqual(sources.count, 3)
        for (i, s) in sources.enumerated() {
            XCTAssertEqual(s.flameIndex, 0, "source[\(i)] flameIndex must be 0, not the sequence position")
            XCTAssertNil(s.fileURL)
            XCTAssertNotNil(s.serializedText)
            XCTAssertEqual(s.displayName, "seq #\(i + 1)")
        }
    }

    func testSequenceFileBackedArray() throws {
        // `fileURLs` is `[URL]?` (whole-array optional) — every slot is file-backed.
        let f = try flame()
        let urls = [URL(fileURLWithPath: "/tmp/a.flam3"), URL(fileURLWithPath: "/tmp/b.flam3")]
        let sources = ExportSources.sequence(flames: [f, f], fileURLs: urls, displayName: "seq")
        XCTAssertEqual(sources.count, 2)
        for (i, s) in sources.enumerated() {
            XCTAssertEqual(s.fileURL, urls[i])
            XCTAssertNil(s.serializedText)     // file-backed ⇒ hash path
            XCTAssertEqual(s.flameIndex, 0)
            XCTAssertEqual(s.displayName, "seq #\(i + 1)")
        }
    }
}
