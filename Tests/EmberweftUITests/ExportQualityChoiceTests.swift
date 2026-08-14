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

    // MARK: - displayName (the shared sheet/Settings label)

    func testDisplayNameMatchesSheetLabels() {
        // One label source for the export sheet's picker and Settings' default
        // picker, so the two surfaces can never disagree.
        XCTAssertEqual(ExportQualityChoice.genomeDefault.displayName, "Genome default")
        XCTAssertEqual(ExportQualityChoice.low.displayName, "Low")
        XCTAssertEqual(ExportQualityChoice.medium.displayName, "Medium")
        XCTAssertEqual(ExportQualityChoice.high.displayName, "High")
    }

    func testAllCasesAreTheFourDocumentedChoices() {
        // Pin the public case set: the sheet picker iterates `allCases`.
        XCTAssertEqual(ExportQualityChoice.allCases,
                       [.genomeDefault, .low, .medium, .high])
    }

    /// v0.5.5: each quality tier auto-selects a data-derived temporal-samples
    /// value when picked (the sheet's quality-picker onChange sets the stepper).
    /// Draft=1 (single-pass, fastest), Standard=4 (free at spp 30), High=16 (free
    /// at spp 100), Genome=1 (= "use genome default" sentinel via the v0.5.4 gate).
    func testRecommendedTemporalSamplesPerTier() {
        XCTAssertEqual(ExportQualityChoice.genomeDefault.recommendedTemporalSamples, 1)
        XCTAssertEqual(ExportQualityChoice.low.recommendedTemporalSamples, 1)
        XCTAssertEqual(ExportQualityChoice.medium.recommendedTemporalSamples, 4)
        XCTAssertEqual(ExportQualityChoice.high.recommendedTemporalSamples, 16)
    }
}
