import XCTest
@testable import EmberweftCLI
import FlameKit
import FlameRenderer

final class CLITests: XCTestCase {
    private func tmp(_ xml: String) -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("c.flam3")
        try? xml.data(using: .utf8)!.write(to: url)
        return url
    }
    private let goodXml = """
    <flames><flame name="G" size="16 16" scale="64" quality="10">
      <xform coefs="1 0 0 1 0 0" linear="1"/>
    </flame></flames>
    """

    func testVersion() async {
        let code = await EmberweftCLI.run(["emberweft", "--version"])
        XCTAssertEqual(code, 0)
    }
    func testValidateGood() async throws {
        let url = tmp(goodXml)
        let code = await EmberweftCLI.run(["emberweft", "validate", url.path])
        XCTAssertEqual(code, 0)
    }
    func testValidateBad() async throws {
        let url = tmp("<flames><flame>")
        let code = await EmberweftCLI.run(["emberweft", "validate", url.path])
        XCTAssertNotEqual(code, 0)
    }
    func testRenderWritesPNG() async throws {
        let url = tmp(goodXml)
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("o.png")
        try? FileManager.default.removeItem(at: out)
        let code = await EmberweftCLI.run(["emberweft", "render", url.path, "-o", out.path,
                                     "--size", "16x16", "--quality", "20"])
        XCTAssertEqual(code, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
    }

    func testListBackends() async {
        let code = await EmberweftCLI.run(["emberweft", "--list-backends"])
        XCTAssertEqual(code, 0)
    }

    func testRenderMetalBackendWhenAvailable() async throws {
        let metalAvailable = await MainActor.run { MetalRenderer.isAvailable }
        guard metalAvailable else { return }   // skip on GPU-less machines
        let url = tmp(goodXml)
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("m.png")
        try? FileManager.default.removeItem(at: out)
        let code = await EmberweftCLI.run(["emberweft", "render", url.path, "-o", out.path,
                                     "--size", "16x16", "--quality", "20", "--backend", "metal"])
        XCTAssertEqual(code, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
    }
}
