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

    func testMappingLowIsSpp2() {
        XCTAssertEqual(ExportQualityChoice.low.exportQuality, .spp(2))
    }

    func testMappingMediumIsSpp8() {
        XCTAssertEqual(ExportQualityChoice.medium.exportQuality, .spp(8))
    }

    func testMappingHighIsSpp30() {
        XCTAssertEqual(ExportQualityChoice.high.exportQuality, .spp(30))
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
        // The named tiers' spp must match AppPreferences.QualityPreset.samplesPerPixel
        // (low=2, medium=8, high=30) so the sheet's Quality picker and the dormant
        // prefs field agree.
        let baseFlame = Flame()
        XCTAssertEqual(ExportQualityChoice.low.exportQuality.resolvedSamplesPerPixel(for: baseFlame).spp, 2)
        XCTAssertEqual(ExportQualityChoice.medium.exportQuality.resolvedSamplesPerPixel(for: baseFlame).spp, 8)
        XCTAssertEqual(ExportQualityChoice.high.exportQuality.resolvedSamplesPerPixel(for: baseFlame).spp, 30)
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
