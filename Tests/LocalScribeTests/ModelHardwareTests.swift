import XCTest
@testable import LocalScribeCore

final class ModelHardwareTests: XCTestCase {
    private let gib: UInt64 = 1_073_741_824
    private func machine(_ ram: UInt64, gpu: UInt64? = nil, apple: Bool = true, metal: Bool = true) -> ModelHardware {
        ModelHardware(chip: "Fixture", memoryBytes: ram * gib, cpuCores: 8,
                      gpuWorkingSetBytes: (gpu ?? ram * 3 / 4) * gib, appleSilicon: apple, supportsMetal: metal)
    }
    private func catalog() throws -> ModelCatalog {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try Disk.read(ModelCatalog.self, at: root.appendingPathComponent("Resources/models.lock.json"))
    }
    func testRecommendationsAcrossMacBookMemoryConfigurations() throws {
        let catalog = try catalog()
        let cases: [(UInt64, String)] = [(8,"summary-4b"),(16,"summary"),(18,"summary"),(24,"summary-9b-8bit"),
            (32,"summary-27b"),(36,"summary-27b"),(48,"summary-27b-6bit"),(64,"summary-27b-8bit"),
            (96,"summary-27b-8bit"),(128,"summary-122b")]
        for (ram, expected) in cases {
            let hardware = machine(ram)
            XCTAssertEqual(hardware.recommendedProfile(for: .summary, in: catalog)?.id, expected, "RAM \(ram)")
            XCTAssertEqual(hardware.recommendedProfile(for: .asr, in: catalog)?.id, ram == 8 ? "asr-turbo" : "asr")
            let reversed = ModelCatalog(models: catalog.models.reversed())
            XCTAssertEqual(hardware.recommendedProfile(for: .summary, in: reversed)?.id, expected)
            for profile in catalog.models where hardware.compatibility(for: profile).isCompatible {
                XCTAssertLessThanOrEqual(UInt64(profile.workingMemoryGB ?? 0) * gib, hardware.modelBudgetBytes)
            }
        }
        XCTAssertNil(machine(128).recommendedProfile(for: .diarization, in: catalog))
    }
    func testBoundariesUnknownBudgetsAndPlatform() throws {
        let catalog = try catalog(), large = try XCTUnwrap(catalog.models.first { $0.id == "summary-27b" })
        XCTAssertTrue(machine(32, gpu: 24).compatibility(for: large).isCompatible)
        XCTAssertFalse(machine(32, gpu: 23).compatibility(for: large).isCompatible)
        XCTAssertFalse(machine(31, gpu: 30).compatibility(for: large).isCompatible)
        for hardware in [machine(128, gpu: 0), machine(0), machine(128, apple: false), machine(128, metal: false)] {
            XCTAssertThrowsError(try hardware.requireCompatibility(for: large))
            XCTAssertNil(hardware.recommendedProfile(for: .summary, in: catalog))
        }
        XCTAssertEqual(machine(8).reservedMemoryBytes, 3 * gib)
        XCTAssertEqual(machine(8).modelBudgetBytes, 5 * gib)
        XCTAssertEqual(machine(32).modelBudgetBytes, 24 * gib)
        // With a 3 GiB GPU budget even the 8 GiB machine must step down.
        XCTAssertEqual(machine(8, gpu: 3).recommendedProfile(for: .summary, in: catalog)?.id, "summary-2b")
        XCTAssertEqual(machine(8, gpu: 1).recommendedProfile(for: .asr, in: catalog)?.id, "asr-base")
        var invalid = large; invalid.workingMemoryGB = -1
        XCTAssertFalse(machine(128).compatibility(for: invalid).isCompatible)
    }
    func testCatalogRequirementsTokenizerAndMetadataDoNotChangeFingerprint() throws {
        let catalog = try catalog()
        XCTAssertEqual(catalog.models.count, 16)
        XCTAssertEqual(Set(catalog.models.map(\.id)).count, 16)
        for profile in catalog.models {
            try profile.validatePaths()
            XCTAssertEqual(profile.revision.count, 40)
            XCTAssertTrue(profile.files.allSatisfy { $0.sha256.count == 64 && $0.size >= 0 })
            if profile.purpose == .asr || profile.purpose == .summary {
                XCTAssertGreaterThan(profile.recommendationRank ?? 0, 0)
                XCTAssertGreaterThan(profile.recommendedMemoryGB ?? 0, 0)
                XCTAssertGreaterThan(profile.workingMemoryGB ?? 0, 0)
            }
        }
        let base = try XCTUnwrap(catalog.models.first { $0.id == "asr-base" })
        XCTAssertEqual(base.tokenizerID, "tokenizer-multilingual")
        var changed = catalog
        for index in changed.models.indices {
            changed.models[index].recommendationRank = nil
            changed.models[index].recommendedMemoryGB = 999
        }
        XCTAssertEqual(changed.fingerprint, catalog.fingerprint)
        let legacy = ModelCatalog(models: ModelRole.allCases.compactMap { role in catalog.models.first { $0.id == role.rawValue } })
        XCTAssertEqual(legacy.fingerprint, Disk.fingerprint(legacy.models.map(\.revision).joined(separator: ":")))
        var info = RunInfo(sourceHash: "source", profileHash: legacy.fingerprint)
        info.modelIDs = Dictionary(uniqueKeysWithValues: legacy.models.map { ($0.purpose!.rawValue, $0.id) })
        XCTAssertEqual(try changed.pinned(to: info).fingerprint, legacy.fingerprint)
    }
    func testLegacyMetadataDecodesWithoutRecommendationRank() throws {
        let profile = try XCTUnwrap(catalog().models.first)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        json.removeValue(forKey: "recommendationRank")
        let decoded = try JSONDecoder().decode(ModelProfile.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.recommendationRank)
        XCTAssertEqual(decoded.id, profile.id)
    }
}
