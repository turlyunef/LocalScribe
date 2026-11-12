import XCTest
@testable import LocalScribeCore

final class RunResumptionTests: XCTestCase {
    private func fixture(_ root: URL) throws -> (RecordingRepository, ModelCatalog, Manifest, RunInfo) {
        let repo = try RecordingRepository(root: root)
        let profiles = try ModelRole.audioRoles.map { role in
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

    func testExplicitWhisperBackendResumesSameRunWithoutRewritingStoredFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (repo, catalog, manifest, info) = try fixture(root)
        let checkpoint = repo.run(manifest.id, info.id).appendingPathComponent("asr/part-0.json")
        try Disk.write(ASRPart(fingerprint: info.fingerprint, index: 0, startMs: 0, endMs: 1000, segments: []), to: checkpoint)
        let files = [repo.folder(manifest.id).appendingPathComponent("manifest.json"),
                     repo.run(manifest.id, info.id).appendingPathComponent("run.json"), checkpoint]
        let before = try files.map { try Data(contentsOf: $0) }
        var annotated = catalog
        annotated.models[0].asrBackend = "whisper"
        XCTAssertEqual(try repo.resumeRun(manifest.id, catalog: annotated).id, info.id)
        XCTAssertEqual(try files.map { try Data(contentsOf: $0) }, before)
        annotated.models[0].asrBackend = "future-engine"
        XCTAssertThrowsError(try repo.resumeRun(manifest.id, catalog: annotated))
        XCTAssertEqual(try files.map { try Data(contentsOf: $0) }, before)
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

    func testASRVersionChangeRejectsOldCheckpointsWithoutChangingArchivedRun() throws {
        for version in ["asr6", "asr7"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let (repo, catalog, manifest, current) = try fixture(root)
            var previous = current
            previous.pipelineVersion = "1.0.0-audio2-\(version)-live1-diarization4-summary15"
            XCTAssertNotEqual(current.fingerprint, previous.fingerprint)
            let run = repo.run(manifest.id, current.id)
            let runFile = run.appendingPathComponent("run.json")
            try Disk.write(previous, to: runFile)
            let checkpoint = run.appendingPathComponent("asr/part-0.json")
            try Disk.write(ASRPart(fingerprint: previous.fingerprint, index: 0, startMs: 0, endMs: 1000, segments: []), to: checkpoint)
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

    func testRejectedASR7ResumeAndFailedCurrentReprocessingKeepReadableActiveResult() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (repo, catalog, initial, current) = try fixture(root)
        var manifest = initial
        let original = repo.folder(manifest.id).appendingPathComponent(manifest.originalRelativePath)
        try Disk.directory(original.deletingLastPathComponent())
        try Data("technical source".utf8).write(to: original)
        manifest.sha256 = try Disk.hash(original)
        let oldVersion = "1.0.0-audio2-asr7-live1-diarization4-summary15"
        var active = RunInfo(id: try XCTUnwrap(manifest.activeRunId), sourceHash: manifest.sha256,
                             profileHash: catalog.fingerprint)
        active.pipelineVersion = oldVersion
        let transcript = Transcript(fingerprint: active.fingerprint, diarized: true, segments: [
            Segment(id: "stable-id", startMs: 200, endMs: 900, speakerId: "speaker-1",
                    text: "Готовый результат", language: "ru", uncertain: true,
                    words: [Word(text: "Готовый", startMs: 200, endMs: 500),
                            Word(text: " результат", startMs: 500, endMs: 900)])
        ])
        let summary = Summary(language: "ru", overview: [
            Finding(id: "fact", text: "Результат", evidenceSegmentIds: ["stable-id"], uncertain: true)
        ])
        let activePath = repo.run(manifest.id, active.id)
        try Disk.write(active, to: activePath.appendingPathComponent("run.json"))
        try Disk.write(transcript, to: activePath.appendingPathComponent("transcript.json"))
        try Disk.write(summary, to: activePath.appendingPathComponent("summary.json"))
        var pending = current; pending.pipelineVersion = oldVersion; pending.sourceHash = manifest.sha256
        let pendingPath = repo.run(manifest.id, pending.id)
        try Disk.write(pending, to: pendingPath.appendingPathComponent("run.json"))
        try Disk.write(ASRPart(fingerprint: pending.fingerprint, index: 0, startMs: 0, endMs: 1000,
                              segments: transcript.segments), to: pendingPath.appendingPathComponent("asr/part-0.json"))
        try repo.save(manifest)
        let preserved = [original, activePath.appendingPathComponent("run.json"),
                         activePath.appendingPathComponent("transcript.json"), activePath.appendingPathComponent("summary.json"),
                         pendingPath.appendingPathComponent("run.json"), pendingPath.appendingPathComponent("asr/part-0.json")]
        let bytes = try preserved.map { try Data(contentsOf: $0) }
        let manifestURL = repo.folder(manifest.id).appendingPathComponent("manifest.json")
        let oldManifest = try Data(contentsOf: manifestURL)
        XCTAssertThrowsError(try repo.resumeRun(manifest.id, catalog: catalog))
        XCTAssertEqual(try Data(contentsOf: manifestURL), oldManifest)
        XCTAssertEqual(try repo.results(repo.load(manifest.id)).0, transcript)
        XCTAssertEqual(try repo.results(repo.load(manifest.id)).1, summary)

        let fresh = try repo.beginRun(&manifest, catalog: catalog)
        XCTAssertEqual(fresh.pipelineVersion, "1.0.0-audio2-asr12-live1-diarization4-summary17")
        XCTAssertNotEqual(fresh.id, pending.id)
        XCTAssertNotEqual(fresh.fingerprint, pending.fingerprint)
        XCTAssertEqual(fresh.modelIDs, pending.modelIDs)
        // Model/ASR failure changes only the new attempt's status. Even a broken
        // partial artifact must not replace the validated active transcript.
        try Data("incomplete".utf8).write(to: repo.run(manifest.id, fresh.id).appendingPathComponent("transcript.json"))
        for state in [JobState.failed, .cancelled, .interrupted] {
            manifest.state = state; try repo.save(manifest)
            XCTAssertEqual(try repo.resumeRun(manifest.id, catalog: catalog).id, fresh.id)
            XCTAssertEqual(try repo.load(manifest.id).activeRunId, active.id)
            XCTAssertEqual(try repo.load(manifest.id).pendingRunId, fresh.id)
            XCTAssertEqual(try repo.results(repo.load(manifest.id)).0, transcript)
            XCTAssertEqual(try repo.results(repo.load(manifest.id)).1, summary)
            XCTAssertEqual(try preserved.map { try Data(contentsOf: $0) }, bytes)
        }
    }
}
