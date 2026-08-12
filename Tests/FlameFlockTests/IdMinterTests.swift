// Tests/FlameFlockTests/IdMinterTests.swift
import XCTest
@testable import FlameFlock

/// Task 8 — `IdMinter`: reserved-flock `900000` minting for non-ES genomes
/// (stable identity, deduped on `sourceSha`), with ES `(gen,id)` passthrough.
final class IdMinterTests: XCTestCase {

    private func makeRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flock-idminter-\(UUID().uuidString)")
    }

    // (a) Mint a non-ES source twice (same bytes ⇒ same sha) ⇒ same minted id,
    //     in reserved flock 900000. Stable identity — no regeneration.
    func testMintNonEsTwiceSameBytesReturnsSameId() async throws {
        let cat = try FlockCatalog(root: makeRoot())
        let minter = IdMinter()
        let bytes = Data("<flame><xform coefs=\"1 0 0 1 0 0\"/></flame>".utf8)

        let r1 = try await minter.resolve(catalog: cat, esGen: nil, esId: nil,
                                          origin: .user, sourceRef: nil, sourceBytes: bytes)
        let r2 = try await minter.resolve(catalog: cat, esGen: nil, esId: nil,
                                          origin: .user, sourceRef: nil, sourceBytes: bytes)

        XCTAssertEqual(r1.gen, "900000")
        XCTAssertEqual(r1.id, "000001")
        XCTAssertEqual(r2.gen, r1.gen, "same source sha must dedupe to the same gen")
        XCTAssertEqual(r2.id, r1.id, "same source sha must dedupe to the same id")
    }

    // (b) ES-sourced (gen,id) passes through unchanged; the minted-id counter
    //     is NOT consumed (the next non-ES mint still starts at 000001).
    func testEsSourcePassthroughDoesNotMint() async throws {
        let cat = try FlockCatalog(root: makeRoot())
        let minter = IdMinter()

        let r = try await minter.resolve(catalog: cat, esGen: "248", esId: "00628",
                                         origin: .es, sourceRef: nil,
                                         sourceBytes: Data("irrelevant".utf8))
        XCTAssertEqual(r.gen, "248")
        XCTAssertEqual(r.id, "00628")

        // Counter unchanged: first real mint is still 000001.
        let bytes = Data("<flame/>".utf8)
        let m = try await minter.resolve(catalog: cat, esGen: nil, esId: nil,
                                         origin: .user, sourceRef: nil, sourceBytes: bytes)
        XCTAssertEqual(m.id, "000001")
    }

    // (c) A DIFFERENT non-ES source (different bytes ⇒ different sha) ⇒ a new,
    //     distinct minted id (000002).
    func testDifferentSourceBytesYieldsNewMintedId() async throws {
        let cat = try FlockCatalog(root: makeRoot())
        let minter = IdMinter()

        let r1 = try await minter.resolve(catalog: cat, esGen: nil, esId: nil,
                                          origin: .user, sourceRef: nil, sourceBytes: Data("aaa".utf8))
        let r2 = try await minter.resolve(catalog: cat, esGen: nil, esId: nil,
                                          origin: .user, sourceRef: nil, sourceBytes: Data("bbb".utf8))

        XCTAssertEqual(r1.gen, "900000")
        XCTAssertEqual(r1.id, "000001")
        XCTAssertEqual(r2.gen, "900000")
        XCTAssertEqual(r2.id, "000002")
        XCTAssertNotEqual(r1.id, r2.id)
    }

    // (d) Re-open the catalog on the same root: the minted id is stable (both
    //     the sheep row dedup AND the counter are persisted across reopen).
    func testMintedIdPersistsAcrossCatalogReopen() async throws {
        let root = makeRoot()
        let cat = try FlockCatalog(root: root)
        let minter = IdMinter()
        let bytes = Data("<flame>reopen</flame>".utf8)

        let r1 = try await minter.resolve(catalog: cat, esGen: nil, esId: nil,
                                          origin: .user, sourceRef: nil, sourceBytes: bytes)
        XCTAssertEqual(r1.id, "000001")

        // Re-open the catalog on the same root — the prior sheep row + counter
        // were persisted to flock.sqlite.
        let cat2 = try FlockCatalog(root: root)

        // Same bytes ⇒ dedup returns the SAME (gen,id) (row persisted).
        let r2 = try await minter.resolve(catalog: cat2, esGen: nil, esId: nil,
                                          origin: .user, sourceRef: nil, sourceBytes: bytes)
        XCTAssertEqual(r2.gen, r1.gen, "dedup row must survive reopen")
        XCTAssertEqual(r2.id, r1.id, "dedup id must survive reopen")

        // A NEW source continues the counter from 000002 (counter persisted).
        let r3 = try await minter.resolve(catalog: cat2, esGen: nil, esId: nil,
                                          origin: .user, sourceRef: nil,
                                          sourceBytes: Data("different".utf8))
        XCTAssertEqual(r3.id, "000002")
    }
}
