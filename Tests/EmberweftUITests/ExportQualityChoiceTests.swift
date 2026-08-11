import XCTest
@testable import EmberweftUI
import FlameExport
import FlameKit

@MainActor
final class ExportQualityChoiceTests: XCTestCase {

    // MARK: - Mapping to ExportQuality (spec §9.4 testExportQualityChoiceMapping)

    func testMappingGenomeDefaultIsGenome() {
        XCTAssertEqual(ExportQualityChoice.genomeDefault.exportQuality, .genome)
    }

    func testMappingLowIsSpp8() {
        XCTAssertEqual(ExportQualityChoice.low.exportQuality, .spp(8))
    }

    func testMappingMediumIsSpp30() {
        XCTAssertEqual(ExportQualityChoice.medium.exportQuality, .spp(30))
    }

    func testMappingHighIsSpp100() {
        XCTAssertEqual(ExportQualityChoice.high.exportQuality, .spp(100))
    }

    func testAllChoicesPinOversampleToOne() {
        // Engine spec D6: export byte-identity with `animate` requires oversample 1
        // for ALL quality choices, including .high (whose preview-side
        // QualityPreset uses oversample 2).
        let baseFlame = Flame(
            quality: Quality(oversample: 1, samplesPerPixel: 100)
        )
        for choice in ExportQualityChoice.allCases {
            let resolved = choice.exportQuality.resolvedSamplesPerPixel(for: baseFlame)
            XCTAssertEqual(resolved.oversample, 1,
                "\(choice.rawValue) must resolve oversample == 1 (export byte-identity)")
        }
    }

    func testSppChoicesResolveExactSamplesPerPixel() {
        // The named tiers' spp are EXPORT-SPECIFIC (RETUNED 2026-08-11:
        // low=8, medium=30, high=100; was 2/8/30), decoupled from the preview-side
        // AppPreferences.QualityPreset.samplesPerPixel (still 2/8/30). The
        // empirical sweep found clean output needs effective spp ~330+ (Standard),
        // which temporal smoothing supplies as free supersampling.
        let baseFlame = Flame()
        XCTAssertEqual(ExportQualityChoice.low.exportQuality.resolvedSamplesPerPixel(for: baseFlame).spp, 8)
        XCTAssertEqual(ExportQualityChoice.medium.exportQuality.resolvedSamplesPerPixel(for: baseFlame).spp, 30)
        XCTAssertEqual(ExportQualityChoice.high.exportQuality.resolvedSamplesPerPixel(for: baseFlame).spp, 100)
    }

    func testGenomeDefaultResolvesFromBaseFlame() {
        // .genomeDefault defers to baseFlame.quality.samplesPerPixel (byte-identical
        // to `animate`, which uses the genome's own quality).
        let baseFlame = Flame(quality: Quality(oversample: 1, samplesPerPixel: 247))
        let resolved = ExportQualityChoice.genomeDefault.exportQuality
            .resolvedSamplesPerPixel(for: baseFlame)
        XCTAssertEqual(resolved.spp, 247)
        XCTAssertEqual(resolved.oversample, 1)
    }

    // MARK: - defaultChoice(from:) (spec §9.4 testExportQualityChoiceDefaultFromPreset)

    func testDefaultChoiceFromLowPreset() {
        XCTAssertEqual(ExportQualityChoice.defaultChoice(from: .low), .low)
    }

    func testDefaultChoiceFromMediumPreset() {
        XCTAssertEqual(ExportQualityChoice.defaultChoice(from: .medium), .medium)
    }

    func testDefaultChoiceFromHighPreset() {
        XCTAssertEqual(ExportQualityChoice.defaultChoice(from: .high), .high)
    }

    func testAllCasesAreTheFourDocumentedChoices() {
        // Pin the public case set: the sheet picker iterates `allCases`.
        XCTAssertEqual(ExportQualityChoice.allCases,
                       [.genomeDefault, .low, .medium, .high])
    }
}
