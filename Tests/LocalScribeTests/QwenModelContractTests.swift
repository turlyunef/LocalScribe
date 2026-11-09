import XCTest
@testable import LocalScribeCore

final class QwenModelContractTests: XCTestCase {
    private func catalog() -> ModelCatalog {
        var models = ModelRole.audioRoles.map {
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
        // The audio complect stays exactly four roles; diagram is a separate,
        // optional readiness that pinned audio runs must reject.
        XCTAssertEqual(ModelRole.audioRoles.count, 4)
        XCTAssertEqual(ModelRole.allCases.count, 5)
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
    func testDiagramRoleIsOptionalAndNeverCompletesAudio() throws {
        let catalog = catalog()
        var info = info(catalog)
        // A diagram key must not leak into a pinned audio complect.
        info.modelIDs?["diagram"] = "diagram-qwen3-vl-4b"
        XCTAssertThrowsError(try catalog.pinned(to: info))
        // Installing and selecting the diagram model leaves audio readiness untouched.
        let diagram = ModelProfile(id: "diagram-qwen3-vl-4b", repository: "fixture/vlm", revision: "fixed", license: "test",
            files: [.init(path: "config", localPath: "config", size: 3, sha256: Disk.fingerprint("vlm"))], role: .diagram)
        var withDiagram = catalog
        withDiagram.models.append(diagram)
        var library = ModelLibrary()
        for profile in catalog.models.dropLast() { library.installed(profile, catalog: withDiagram) }
        XCTAssertNil(library.activeCatalog(from: withDiagram))
        XCTAssertNil(library.diagramProfile(from: withDiagram).map(\.id), "до установки модели схем готовность схем отсутствует")
        library.installed(diagram, catalog: withDiagram)
        XCTAssertEqual(library.selectedByRole[ModelRole.diagram.rawValue], diagram.id)
        XCTAssertNil(library.activeCatalog(from: withDiagram), "диаграммная модель не завершает аудиокомплект")
        let aligner = catalog.models[4]
        library.installed(aligner, catalog: withDiagram)
        let audio = try XCTUnwrap(library.activeCatalog(from: withDiagram))
        XCTAssertEqual(audio.models.count, 5)
        XCTAssertFalse(audio.models.contains { $0.purpose == .diagram }, "аудиокомплект не включает модель схем")
        // Audio checkpoints keep their fingerprint when the diagram profile appears.
        XCTAssertEqual(audio.fingerprint, catalog.fingerprint)
        let selected = try XCTUnwrap(library.diagramProfile(from: withDiagram))
        XCTAssertEqual(selected.id, diagram.id)
        // Without the diagram model the separate readiness is nil while audio keeps working.
        var audioOnly = ModelLibrary()
        for profile in withDiagram.models where profile.purpose != .diagram { audioOnly.installed(profile, catalog: withDiagram) }
        XCTAssertNil(audioOnly.diagramProfile(from: withDiagram))
        XCTAssertEqual(audioOnly.activeCatalog(from: withDiagram)?.models.count, 5)
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
