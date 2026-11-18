import XCTest
@testable import LocalScribeCore
@testable import LocalScribe

/// Regression tests for the silent model-state/disk mismatch: «Проверить
/// модели» must surface a present but damaged model folder through the error
/// handler (model name, file, and the consequence for the selection and the
/// queue), while profiles without a folder stay silent. The exclusion of the
/// damaged profile itself does not change.
@MainActor
final class ModelIntegrityReportTests: XCTestCase {
    private func makeDefaults() throws -> UserDefaults {
        let name = "ModelIntegrityReportTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return defaults
    }

    /// A catalog with one damaged-on-disk profile (right size, wrong SHA-256)
    /// and one never-installed profile.
    private func makeCatalog(root: URL) throws -> (catalog: ModelCatalog, damaged: ModelProfile) {
        let modelsRoot = root.appendingPathComponent("models")
        try Disk.directory(modelsRoot.appendingPathComponent("summary"))
        try Data("Weights".utf8).write(to: modelsRoot.appendingPathComponent("summary/file-0.bin"))
        let pinned = Data("weights".utf8)
        let damaged = ModelProfile(id: "summary", repository: "test/summary", revision: "rev-1", license: "test",
                                   files: [ModelFile(path: "file-0.bin", localPath: "file-0.bin",
                                                     size: Int64(pinned.count),
                                                     sha256: ByteContentIdentity.sha256Hex(pinned))],
                                   role: .summary)
        let absent = ModelProfile(id: "asr", repository: "test/asr", revision: "rev-1", license: "test",
                                  files: [ModelFile(path: "file-0.bin", localPath: "file-0.bin",
                                                    size: Int64(pinned.count),
                                                    sha256: ByteContentIdentity.sha256Hex(pinned))],
                                  role: .asr)
        return (ModelCatalog(models: [damaged, absent]), damaged)
    }

    func testVerifyModelsReportsDamagedProfileThroughErrorHandler() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root)
        let (catalog, damaged) = try makeCatalog(root: root)
        let model = AppModel(repository: repo, startServices: false, userDefaults: try makeDefaults(), catalog: catalog)

        await model.verifyModels()

        let matches = model.errorHandler.messages.filter { $0.contains("Не удалось проверить установленные модели") }
        XCTAssertEqual(matches.count, 1, "one aggregated report for the damaged profile")
        XCTAssertTrue(matches[0].contains("Модель summary: отсутствует или повреждён file-0.bin"),
                      "the report names the model and the damaged file: \(matches.first ?? "<none>")")
        XCTAssertTrue(matches[0].contains("задания будут ждать модель"), "the report explains the consequence")
        // The behaviour itself is unchanged: the profile is excluded from the
        // selection while its folder stays on disk.
        XCTAssertFalse(model.modelLibrary.isInstalled(damaged))
        XCTAssertFalse(try Disk.read(ModelLibrary.self,
                                     at: repo.models.appendingPathComponent("selection.json")).isInstalled(damaged))
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.models.appendingPathComponent("summary/file-0.bin").path))
        await model.shutdown()
    }

    func testVerifyModelsStaysSilentWhenNothingIsInstalled() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root)
        // Catalog profiles without folders are simply not installed: no report.
        let (catalog, _) = try makeCatalog(root: root)
        try FileManager.default.removeItem(at: repo.models.appendingPathComponent("summary"))
        let model = AppModel(repository: repo, startServices: false, userDefaults: try makeDefaults(), catalog: catalog)

        await model.verifyModels()

        XCTAssertTrue(model.errorHandler.messages.isEmpty, "absent profiles never produce reports")
        await model.shutdown()
    }
}
