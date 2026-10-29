import XCTest
@testable import LocalScribeCore

final class QwenModelContractTests: XCTestCase {
    private func catalog() -> ModelCatalog {
        var models = ModelRole.allCases.map {
            ModelProfile(id: $0.rawValue, repository: "fixture/local", revision: "fixed", license: "test",
                files: [.init(path: "config", localPath: "config", size: 3, sha256: Disk.fingerprint("abc"))], role: $0)
        }
        models[0].id = "qwen"; models[0].asrBackend = "qwen3"; models[0].asrPolicy = "policy1"
        models[0].alignerID = "aligner"; models[0].tokenizerID = "tokenizer"
        models.append(ModelProfile(id: "aligner", repository: "fixture/aligner", revision: "fixed", license: "test",
            files: [.init(path: "config", localPath: "config", size: 3, sha256: Disk.fingerprint("abc"))]))
        return ModelCatalog(models: models)
    }
    private func info(_ catalog: ModelCatalog) -> RunInfo {
        var value = RunInfo(sourceHash: "source", profileHash: catalog.fingerprint)
        value.modelIDs = Dictionary(uniqueKeysWithValues: catalog.models.compactMap { p in p.purpose.map { ($0.rawValue, p.id) } })
        value.auxiliaryModelIDs = ["aligner": "aligner"]
        return value
    }
    func testCompleteDependencyPinnedWithoutAddingLegacyRole() throws {
        let catalog = catalog(), info = info(catalog)
        XCTAssertEqual(ModelRole.allCases.count, 4)
        XCTAssertEqual(try catalog.pinned(to: info).models.count, 5)
        for change in 0..<7 {
            var changed = catalog
            switch change {
            case 0: changed.models[4].files[0].sha256 = String(repeating: "a", count: 64)
            case 1: changed.models[4].revision = "other"
            case 2: changed.models[0].asrPolicy = "policy2"
            case 3: changed.models[0].asrBackend = "other"
            case 4: changed.models[0].alignerID = "other"
            case 5: changed.models[0].tokenizerID = "other"
            default: changed.models.removeLast()
            }
            XCTAssertThrowsError(try changed.pinned(to: info))
        }
        var missing = info; missing.auxiliaryModelIDs = nil
        XCTAssertThrowsError(try catalog.pinned(to: missing))
        missing = info; missing.auxiliaryModelIDs?["extra"] = "unexpected"
        XCTAssertThrowsError(try catalog.pinned(to: missing))
    }
    func testDependencyInstallationSelectionAndRemoval() async throws {
        let catalog = catalog(), root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Disk.directory(root); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"); try Disk.directory(source)
        try Data("abc".utf8).write(to: source.appendingPathComponent("config"))
        let installer = ModelInstaller()
        var library = ModelLibrary()
        for profile in catalog.models.dropLast() {
            try await installer.install(profile, root: root, localSource: source, progress: { _ in })
            library.installed(profile, catalog: catalog)
        }
        XCTAssertNil(library.activeCatalog(from: catalog))
        XCTAssertThrowsError(try library.select(catalog.models[0], catalog: catalog))
        let aligner = catalog.models[4]
        try await installer.install(aligner, root: root, localSource: source, progress: { _ in })
        library.installed(aligner, catalog: catalog)
        try library.select(catalog.models[0], catalog: catalog)
        XCTAssertEqual(library.activeCatalog(from: catalog)?.fingerprint, catalog.fingerprint)
        try catalog.validate(at: root)
        try Data("bad".utf8).write(to: root.appendingPathComponent("aligner/config"))
        XCTAssertThrowsError(try catalog.validate(at: root))
        try library.remove(aligner, at: root, catalog: catalog)
        XCTAssertNil(library.activeCatalog(from: catalog))
    }
    func testLimitedProfileRejectsLongRecordingBeforeCreatingRun() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(root: root)
        var catalog = catalog(); catalog.models[0].maximumRecordingMs = 300_000
        var manifest = Manifest(sourceType: "import", title: "long", filename: "a.wav")
        manifest.sourceComplete = true; manifest.durationMs = 300_001
        try repository.save(manifest)
        let path = repository.folder(manifest.id).appendingPathComponent("manifest.json")
        let before = try Data(contentsOf: path)
        XCTAssertThrowsError(try repository.beginRun(&manifest, catalog: catalog))
        XCTAssertNil(manifest.pendingRunId)
        XCTAssertEqual(try Data(contentsOf: path), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.folder(manifest.id).appendingPathComponent("runs").path))
    }

    func testNewRunFreezesDependencyAndOfflineMode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(root: root), catalog = catalog()
        var manifest = Manifest(sourceType: "import", title: "fixture", filename: "a.wav")
        manifest.sourceComplete = true; manifest.sha256 = "source"; manifest.durationMs = 1000
        let run = try repository.beginRun(&manifest, catalog: catalog)
        XCTAssertEqual(run.auxiliaryModelIDs, ["aligner": "aligner"])
        XCTAssertEqual(run.modelIDs?.count, 4)
        XCTAssertEqual(try catalog.pinned(to: run).fingerprint, catalog.fingerprint)
        var microphone = Manifest(sourceType: "microphone", title: "mic", filename: "a.caf")
        microphone.state = .recording
        XCTAssertThrowsError(try repository.beginRun(&microphone, catalog: catalog, liveCapture: true))
        XCTAssertNil(microphone.pendingRunId)
    }
}
