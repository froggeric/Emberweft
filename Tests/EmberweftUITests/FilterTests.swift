import XCTest
@testable import EmberweftUI
import FlameKit

final class FilterTests: XCTestCase {

    private func makeEntry(_ id: String, display: String, rank: CuratorRank? = nil,
                           source: LibrarySource = .bundle) -> LibraryEntry {
        LibraryEntry(id: id, source: source,
                     fileURL: URL(fileURLWithPath: "/tmp/\(id).flam3"),
                     displayName: display, rank: rank)
    }
    private func md(_ sentiment: Int = 0) -> GenomeMetadata { GenomeMetadata(sentiment: sentiment) }

    // MARK: - passes

    func testEmptyFilterPassesAll() {
        let f = LibraryFilter()
        XCTAssertTrue(passes(f, entry: makeEntry("a", display: "anything"), metadata: md(), facet: nil))
    }

    func testSearchTextCaseInsensitive() {
        var f = LibraryFilter(); f.searchText = "RED"
        XCTAssertTrue(passes(f, entry: makeEntry("a", display: "Red Spider"), metadata: md(), facet: nil))
        XCTAssertFalse(passes(f, entry: makeEntry("b", display: "Blue Whale"), metadata: md(), facet: nil))
    }

    func testSentimentFilter() {
        var f = LibraryFilter(); f.sentiment = 1
        XCTAssertTrue(passes(f, entry: makeEntry("a", display: "x"), metadata: md(1), facet: nil))
        XCTAssertFalse(passes(f, entry: makeEntry("b", display: "x"), metadata: md(0), facet: nil))
        XCTAssertFalse(passes(f, entry: makeEntry("c", display: "x"), metadata: md(-1), facet: nil))

        f.sentiment = -1
        XCTAssertTrue(passes(f, entry: makeEntry("d", display: "x"), metadata: md(-1), facet: nil))
    }

    func testCategoryMatchesBundleOrHeuristic() {
        var f = LibraryFilter(); f.category = "spiral"
        let bundleRank = CuratorRank(category: "spiral", score: 0.8, visionShortlist: true)
        XCTAssertTrue(passes(f, entry: makeEntry("a", display: "x", rank: bundleRank),
                             metadata: md(), facet: nil))
        // No rank but a heuristic facet category matches:
        XCTAssertTrue(passes(f, entry: makeEntry("b", display: "x", rank: nil),
                             metadata: md(),
                             facet: GenomeFacet(hue: 0, luma: 0, category: "spiral")))
        // No rank, facet mismatch ⇒ excluded:
        XCTAssertFalse(passes(f, entry: makeEntry("c", display: "x", rank: nil),
                              metadata: md(),
                              facet: GenomeFacet(hue: 0, luma: 0, category: "radial")))
    }

    func testHueBucketRequiresMatchingFacet() {
        var f = LibraryFilter(); f.hueBucket = 3
        let matching = GenomeFacet(hue: 3.0 / 12.0 + 0.001, luma: 0.5, category: "other")
        let other    = GenomeFacet(hue: 0.0, luma: 0.5, category: "other")
        XCTAssertTrue(passes(f, entry: makeEntry("a", display: "x"), metadata: md(), facet: matching))
        XCTAssertFalse(passes(f, entry: makeEntry("b", display: "x"), metadata: md(), facet: other))
        XCTAssertFalse(passes(f, entry: makeEntry("c", display: "x"), metadata: md(), facet: nil))
    }

    func testCombinedFilters() {
        var f = LibraryFilter()
        f.searchText = "red"; f.sentiment = 1
        let e = makeEntry("a", display: "Red One")
        XCTAssertTrue(passes(f, entry: e, metadata: md(1), facet: nil))
        XCTAssertFalse(passes(f, entry: e, metadata: md(0), facet: nil))
    }

    // MARK: - applyFilter (ordering / determinism)

    func testApplyFilterPreservesSourceOrder() {
        let entries = [
            makeEntry("a", display: "Apple"),
            makeEntry("b", display: "Banana"),
            makeEntry("c", display: "Apple Pie")
        ]
        var f = LibraryFilter(); f.searchText = "apple"
        let out = applyFilter(f, to: entries, metadata: { _ in md() }, facet: { _ in nil })
        XCTAssertEqual(out.map(\.id), ["a", "c"])
    }

    func testIsEmptyPredicate() {
        XCTAssertTrue(LibraryFilter().isEmpty)
        var f = LibraryFilter(); f.sentiment = 1
        XCTAssertFalse(f.isEmpty)
    }
}

@MainActor
final class FacetCacheTests: XCTestCase {

    private func makeEntry(_ id: String, _ source: LibrarySource = .bundle) -> LibraryEntry {
        LibraryEntry(id: id, source: source,
                     fileURL: URL(fileURLWithPath: "/tmp/\(id).flam3"),
                     displayName: id, rank: nil)
    }
    private func solidPalette(_ rgb: SIMD3<Double>) -> Palette {
        Palette(colors: [SIMD3<Double>](repeating: rgb, count: 256))
    }
    private func flame(palette: Palette) -> Flame {
        Flame(xforms: [Xform(weight: 1, variations: [Variation(name: "linear", weight: 1)])],
              palette: palette)
    }

    func testPutIfAbsentIsIdempotentAndStable() {
        let cache = FacetCache()
        let e = makeEntry("a")
        let f = flame(palette: solidPalette(SIMD3<Double>(1, 0, 0)))
        cache.putIfAbsent(for: e, flame: f)
        let first = cache.facet(for: e)
        cache.putIfAbsent(for: e, flame: f)
        XCTAssertEqual(cache.facet(for: e), first)
        XCTAssertNotNil(first)
    }

    func testGenomeFacetHueBucketMath() {
        XCTAssertEqual(GenomeFacet(hue: 0.0, luma: 0, category: "other").hueBucket, 0)
        XCTAssertEqual(GenomeFacet(hue: 0.5, luma: 0, category: "other").hueBucket, 6)
        XCTAssertEqual(GenomeFacet(hue: 0.99, luma: 0, category: "other").hueBucket, 11)
        XCTAssertEqual(GenomeFacet(hue: 1.0 / 12.0, luma: 0, category: "other").hueBucket, 1)
    }

    func testCategoryHeuristicFromVariations() {
        func cat(_ vname: String) -> String {
            GenomeFacet.category(for: Flame(
                xforms: [Xform(weight: 1, variations: [Variation(name: vname, weight: 1)])],
                palette: solidPalette(SIMD3<Double>(1, 0, 0))))
        }
        XCTAssertEqual(cat("spiral"), "spiral")
        XCTAssertEqual(cat("gaussian_blur"), "dense")
        XCTAssertEqual(cat("radial_blur"), "radial")
        XCTAssertEqual(cat("fisheye"), "filament")
        XCTAssertEqual(cat("linear"), "other")
    }

    func testRefineKeepsCategoryUpdatesHueFromImage() {
        let cache = FacetCache()
        let e = makeEntry("a")
        let flame = Flame(
            xforms: [Xform(weight: 1, variations: [Variation(name: "spiral", weight: 1)])],
            palette: solidPalette(SIMD3<Double>(0, 0, 1)))
        cache.putIfAbsent(for: e, flame: flame)
        XCTAssertEqual(cache.facet(for: e)?.category, "spiral")
        var red = [UInt8]()
        for _ in 0..<(4 * 4) { red += [255, 0, 0, 255] }
        cache.refine(for: e, image: RGBA8Image(width: 4, height: 4, pixels: red))
        XCTAssertEqual(cache.facet(for: e)?.category, "spiral")
        XCTAssertEqual(cache.facet(for: e)?.hueBucket, 0)
    }

    func testKeyIsSourceQualified() {
        let cache = FacetCache()
        let flame = flame(palette: solidPalette(SIMD3<Double>(0, 1, 0)))
        let bundle = makeEntry("0242", .bundle)
        let dir = makeEntry("0242", .directory(URL(fileURLWithPath: "/tmp/root")))
        cache.putIfAbsent(for: bundle, flame: flame)
        XCTAssertNotNil(cache.facet(for: bundle))
        XCTAssertNil(cache.facet(for: dir), "same stem, different source ⇒ no facet (distinct key)")
    }
}
