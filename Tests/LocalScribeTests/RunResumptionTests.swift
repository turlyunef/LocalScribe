import XCTest
@testable import LocalScribeCore

final class RunResumptionTests: XCTestCase {
    private func fixture(_ root: URL) throws -> (RecordingRepository, ModelCatalog, Manifest, RunInfo) {
        let repo = try RecordingRepository(root: root)
        let profiles = try ModelRole.allCases.map { role in
            let id = role == .asr ? "asr-a" : role.rawValue
            let data = Data(id.utf8), folder = repo.models.appendingPathComponent(id)
            try Disk.directory(folder)
            let file = folder.appendingPathComponent("weights.bin")
            try data.write(to: file)
            return ModelProfile(id: id, repository: "test/model", revision: "revision-a", license: "test",
                                files: [ModelFile(path: "weights.bin", localPath: "weights.bin", size: Int64(data.count), sha256: try Disk.hash(file))], role: role)
        }
        let catalog = ModelCatalog(models: profiles)
        var manifest = Manifest(sourceType: "import", title: "Resume", filename: "original.wav")
        manifest.sourceComplete = true; manifest.sha256 = "source"; manifest.durationMs = 1000
        // A failed resume must also preserve the previous successful result.
        manifest.activeRunId = UUID().uuidString
        let info = try repo.beginRun(&manifest, catalog: catalog)
        manifest.state = .interrupted; try repo.save(manifest)
        return (repo, catalog, manifest, info)
    }

    func testPinnedRevisionAndSHAChangesAreRejectedWithoutReplacingPendingOrActiveRun() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (repo, original, manifest, info) = try fixture(root)
        let runFile = repo.run(manifest.id, info.id).appendingPathComponent("run.json")
        let runBytes = try Data(contentsOf: runFile)
        let manifestBytes = try Data(contentsOf: repo.folder(manifest.id).appendingPathComponent("manifest.json"))
        for changeSHA in [false, true] {
            var changed = original
            if changeSHA { changed.models[0].files[0].sha256 = String(repeating: "b", count: 64) }
            else { changed.models[0].revision = "revision-b" }
            XCTAssertThrowsError(try repo.resumeRun(manifest.id, catalog: changed)) {
                XCTAssertTrue($0.localizedDescription.contains("Ревизии или SHA-256"))
            }
            XCTAssertEqual(try Data(contentsOf: runFile), runBytes)
            XCTAssertEqual(try Data(contentsOf: repo.folder(manifest.id).appendingPathComponent("manifest.json")), manifestBytes)
        }
    }

    func testMissingProfileAndSameSizeCorruptionAreRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (repo, catalog, manifest, info) = try fixture(root)
        var removed = catalog; removed.models.removeFirst()
        XCTAssertThrowsError(try repo.resumeRun(manifest.id, catalog: removed)) {
            XCTAssertTrue($0.localizedDescription.contains("asr-a недоступна"))
        }
        let file = repo.models.appendingPathComponent("asr-a/weights.bin")
        try Data("other".utf8).write(to: file) // Same size as asr-a; only SHA catches this.
        XCTAssertThrowsError(try repo.resumeRun(manifest.id, catalog: catalog)) {
            XCTAssertTrue($0.localizedDescription.contains("отсутствует или повреждён"))
        }
        XCTAssertEqual(try repo.load(manifest.id).pendingRunId, info.id)
        XCTAssertEqual(try repo.load(manifest.id).activeRunId, manifest.activeRunId)
    }

    func testUnreadableAndMismatchedPendingRunAreRejectedWithoutCreatingRun() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (repo, catalog, manifest, original) = try fixture(root)
        let path = repo.run(manifest.id, original.id).appendingPathComponent("run.json")
        try Data("broken".utf8).write(to: path)
        XCTAssertThrowsError(try repo.resumeRun(manifest.id, catalog: catalog)) {
            XCTAssertTrue($0.localizedDescription.contains("прочитать незавершённое задание"))
        }
        var wrongID = original; wrongID.id = UUID().uuidString
        try Disk.write(wrongID, to: path)
        XCTAssertThrowsError(try repo.resumeRun(manifest.id, catalog: catalog))
        var wrongSource = original; wrongSource.sourceHash = "changed-source"
        try Disk.write(wrongSource, to: path)
        XCTAssertThrowsError(try repo.resumeRun(manifest.id, catalog: catalog)) {
            XCTAssertTrue($0.localizedDescription.contains("Исходник не совпадает"))
        }
        XCTAssertEqual(try repo.load(manifest.id).pendingRunId, original.id)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: repo.folder(manifest.id).appendingPathComponent("runs").path), [original.id])
    }

    func testLegacyCatalogRetainsRevisionOnlyFingerprintAndValidatesFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (repo, catalog, _, _) = try fixture(root)
        var legacy = catalog
        legacy.models[0].id = "asr"
        try FileManager.default.moveItem(at: repo.models.appendingPathComponent("asr-a"), to: repo.models.appendingPathComponent("asr"))
        let hash = Disk.fingerprint(legacy.models.map(\.revision).joined(separator: ":"))
        XCTAssertEqual(legacy.fingerprint, hash)
        let info = RunInfo(sourceHash: "source", profileHash: hash)
        XCTAssertNil(info.modelIDs)
        let resolved = try legacy.pinned(to: info)
        XCTAssertEqual(resolved.fingerprint, hash)
        try resolved.validate(at: repo.models)
    }

    func testASRRollbackRejectsOptimizedCheckpointsWithoutChangingArchivedRun() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (repo, catalog, manifest, current) = try fixture(root)
        var optimized = current
        optimized.pipelineVersion = "1.0.0-audio2-asr6-live1-diarization4-summary15"
        XCTAssertNotEqual(current.fingerprint, optimized.fingerprint)
        let run = repo.run(manifest.id, current.id)
        let runFile = run.appendingPathComponent("run.json")
        try Disk.write(optimized, to: runFile)
        let checkpoint = run.appendingPathComponent("asr/part-0.json")
        try Disk.write(ASRPart(fingerprint: optimized.fingerprint, index: 0, startMs: 0, endMs: 1000, segments: []), to: checkpoint)
        let files = [repo.folder(manifest.id).appendingPathComponent("manifest.json"), runFile, checkpoint]
        let before = try files.map { try Data(contentsOf: $0) }
        XCTAssertThrowsError(try repo.resumeRun(manifest.id, catalog: catalog)) {
            XCTAssertTrue($0.localizedDescription.contains("Версия обработки изменилась"))
        }
        XCTAssertEqual(try files.map { try Data(contentsOf: $0) }, before)
        XCTAssertEqual(try repo.load(manifest.id).activeRunId, manifest.activeRunId)
        XCTAssertEqual(try repo.load(manifest.id).pendingRunId, current.id)
    }
}
