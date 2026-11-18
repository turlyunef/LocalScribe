import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import LocalScribeCore
@testable import LocalScribe

/// Regression tests for the «phantom status» cluster: a failed SECONDARY
/// status save — the failed/interrupted/cancelled/queued transition persisted
/// after the primary outcome — used to be swallowed with `_ = try?`, leaving
/// the row in «Распознаём речь»/«В очереди» with no live worker until a
/// restart. The typical common root (a full disk) is simulated by making an
/// item directory read-only (chmod 555): reads still succeed, so the
/// coordinators reach the save, which then fails. Permissions are always
/// restored before the deferred cleanup.
@MainActor
final class SecondaryStatusSaveTests: XCTestCase {

    private struct Fixture {
        let repository: RecordingRepository
        let model: AppModel
        let diagramProfile: ModelProfile
        let anonProfile: ModelProfile
        let root: URL
        var release: URL { root.appendingPathComponent("release") }
    }

    private func fixture(_ root: URL) async throws -> Fixture {
        var repo = try RecordingRepository(root: root)
        let executable = root.appendingPathComponent("worker.py")
        // The process fixture serves all three job kinds and follows the shared
        // fixtures of the other queue suites; no models, microphone permission
        // or real audio is involved.
        let script = #"""
        #!/usr/bin/python3
        import sys, json, pathlib, time, hashlib, uuid
        c = json.loads(sys.stdin.readline())
        root = pathlib.Path(c['modelsPath']).parent
        def emit(kind, message=''):
            print(json.dumps(dict(version=1, jobId=c['jobId'], runId=c['runId'], kind=c.get('kind'), type=kind, message=message)), flush=True)
        with (root / 'events.jsonl').open('a') as f:
            f.write(json.dumps(c) + '\n')
        if c.get('kind') == 'anonymization':
            run = pathlib.Path(c['anonymizationPath'])
            inp = json.loads((run / 'input.json').read_text())
            emit('progress', 'anon-ready-' + c['jobId'])
            emit('completed')
            sys.exit(0)
        if c.get('kind') == 'diagram':
            run = pathlib.Path(c['diagramPath']) / 'runs' / c['runId']
            emit('progress', 'diagram-ready-' + c['jobId'])
            while not (root / 'release').exists() or (root / ('hold-' + c['jobId'])).exists():
                time.sleep(0.02)
            info = json.loads((run / 'run.json').read_text())
            fingerprint = hashlib.sha256((info['sourceHash'] + info['profileHash'] + info['pipelineVersion'] + info['promptVersion'] + info['preprocessingVersion']).encode()).hexdigest()
            result = dict(schemaVersion=1, fingerprint=fingerprint, language='ru',
                nodes=[dict(id='n1', label='Начало', uncertain=False), dict(id='n2', label='Проверка', uncertain=False)],
                edges=[{'from': 'n1', 'to': 'n2', 'direction': 'forward', 'label': 'да', 'uncertain': False}])
            (run / 'result.json').write_text(json.dumps(result))
            emit('completed')
            sys.exit(0)
        run = pathlib.Path(c['recordingPath']) / 'runs' / c['runId']
        emit('progress', 'fixture-ready-' + c['jobId'])
        while not (root / 'release').exists() or (root / ('hold-' + c['jobId'])).exists():
            time.sleep(0.02)
        info = json.loads((run / 'run.json').read_text())
        fingerprint = hashlib.sha256((info['sourceHash'] + info['profileHash'] + info['pipelineVersion']).encode()).hexdigest()
        if c['stage'] == 'preparingAudio':
            (run / 'transcript.json').write_text(json.dumps(dict(schemaVersion=1, fingerprint=fingerprint, diarized=True, segments=[])))
        elif c['stage'] == 'summarizing':
            (run / 'summary.json').write_text(json.dumps(dict(schemaVersion=1, language=info.get('summaryLanguage') or 'ru', overview=[], decisions=[], tasks=[], openQuestions=[])))
        emit('completed')
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        var profiles = ModelRole.audioRoles.map { role in
            ModelProfile(id: role.rawValue, repository: "test/model", revision: "test-revision", license: "test", files: [], role: role)
        }
        profiles += [ModelProfile(id: "asr-b", repository: "test/model", revision: "test-revision", license: "test", files: [], role: .asr)]
        profiles += [ModelProfile(id: "diagram-vlm", repository: "test/vlm", revision: "test-revision", license: "test", files: [], role: .diagram)]
        profiles += [
            ModelProfile(id: "anon-llm", repository: "test/anon", revision: "test-revision", license: "test", files: [], role: nil,
                         recommendedMemoryGB: 8, workingMemoryGB: 2, supportedTasks: [.anonymization]),
        ]
        for index in profiles.indices {
            let data = Data(profiles[index].id.utf8)
            let folder = repo.models.appendingPathComponent(profiles[index].id)
            try Disk.directory(folder)
            let file = folder.appendingPathComponent("weights.bin")
            try data.write(to: file)
            profiles[index].files = [ModelFile(path: "weights.bin", localPath: "weights.bin", size: Int64(data.count), sha256: try Disk.hash(file))]
        }
        let diagramProfile = profiles.first { $0.purpose == .diagram }!
        let anonProfile = profiles.last!
        let catalog = ModelCatalog(models: profiles)
        let suite = "LocalScribeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(repository: repo, startServices: false, workerExecutable: executable,
                             userDefaults: defaults, catalog: catalog)
        var library = ModelLibrary()
        for profile in profiles { library.installed(profile, catalog: catalog) }
        try library.select(profiles[0], catalog: catalog)
        try library.save(at: repo.models)
        await model.verifyModels()
        XCTAssertTrue(model.modelsReady)
        return Fixture(repository: repo, model: model, diagramProfile: diagramProfile,
                       anonProfile: anonProfile, root: root)
    }

    // MARK: - Helpers

    private func waitUntil(_ predicate: @MainActor @Sendable () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !(try await predicate()) && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let final = try await predicate()
        XCTAssertTrue(final)
    }
    /// Reads keep working, atomic writes (a temp file inside the directory)
    /// fail — the coordinator reaches the save and its failure must surface.
    private func denyWrites(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url.path)
    }
    private func restoreWrites(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
    private func completedRecording(_ repo: RecordingRepository, title: String) throws -> Manifest {
        var m = Manifest(sourceType: "microphone", title: title, filename: "original.caf")
        m.sourceComplete = true; m.sha256 = String(repeating: "a", count: 64); m.durationMs = 1000
        try repo.save(m); return m
    }

    // MARK: - processQueue: failed status after a job failure

    func testProcessQueueFailureStatusSaveIsReported() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await fixture(root)
        let model = fixture.model
        let recording = try completedRecording(fixture.repository, title: "Сбой сохранения статуса")
        let folder = fixture.repository.folder(recording.id)
        try denyWrites(folder)
        defer { try? restoreWrites(folder) }

        await model.enqueue(recording.id)
        try await waitUntil {
            model.errorHandler.messages.contains { $0.contains("Не удалось сохранить статус сбоя обработки записи") }
        }
        try await waitUntil { !model.busy }

        // The enqueue status save has always been reported honestly; the
        // failed-status save after the job crash must surface the same way.
        XCTAssertTrue(model.errorHandler.messages.contains { $0.contains("Не удалось сохранить статус постановки записи в очередь") })
        XCTAssertEqual(model.errorHandler.messages.filter { $0.contains("Не удалось сохранить статус сбоя обработки записи") }.count, 1,
                       "the failed secondary save is reported exactly once")
        // The manifest write really failed: the stale state is now visible
        // to the user instead of a silent phantom «failed» claim.
        XCTAssertNotEqual(try fixture.repository.load(recording.id).state, .failed)
        try restoreWrites(folder)
        await model.shutdown()
    }

    // MARK: - pause(reason:): one aggregated report, no per-job spam

    func testPauseStatusSaveFailureIsAggregatedIntoOneReport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await fixture(root)
        let model = fixture.model
        let recording = try completedRecording(fixture.repository, title: "Пауза")
        await model.enqueue(recording.id)
        try await waitUntil { model.status == "fixture-ready-" + recording.id }
        let folder = fixture.repository.folder(recording.id)
        try denyWrites(folder)
        defer { try? restoreWrites(folder) }

        await model.pause(reason: "Тестовая пауза")

        let aggregated = model.errorHandler.messages.filter { $0.contains("Не удалось сохранить статус приостановленных заданий") }
        XCTAssertEqual(aggregated.count, 1, "a mass pause reports one aggregated message, not N identical ones")
        XCTAssertTrue(aggregated.first?.contains("(записей: 1)") == true)
        // The write really failed; the state stays as it was on disk.
        XCTAssertNotEqual(try fixture.repository.load(recording.id).state, .interrupted)
        try restoreWrites(folder)
        try Data().write(to: fixture.release)
        await model.shutdown()
    }

    // MARK: - cancel(_:)

    func testCancelStatusSaveFailureIsReported() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await fixture(root)
        let model = fixture.model
        let recording = try completedRecording(fixture.repository, title: "Отмена")
        let folder = fixture.repository.folder(recording.id)
        try denyWrites(folder)
        defer { try? restoreWrites(folder) }

        await model.cancel(recording.id)

        XCTAssertEqual(model.errorHandler.messages.filter { $0.contains("Не удалось сохранить статус отменённой записи") }.count, 1)
        XCTAssertNotEqual(try fixture.repository.load(recording.id).state, .cancelled)
        try restoreWrites(folder)
        await model.shutdown()
    }

    // MARK: - enqueueDiagram: the queued branch

    func testDiagramEnqueueQueuedStatusSaveFailureIsReported() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await fixture(root)
        let model = fixture.model
        // Hold one recording inside the worker so the shared FIFO stays busy
        // and the diagram job does not run while its directory is read-only.
        let recording = try completedRecording(fixture.repository, title: "Удержание очереди")
        await model.enqueue(recording.id)
        try await waitUntil { model.status == "fixture-ready-" + recording.id }

        let diagramRepo = try DiagramRepository(root: fixture.repository.root.appendingPathComponent("diagrams"))
        var diagram = DiagramManifest(title: "Схема", filename: "flow.png", ext: "png", uti: UTType.png.identifier)
        diagram.byteSize = 4
        diagram.sha256 = String(repeating: "b", count: 64)
        _ = try diagramRepo.beginRun(&diagram, profile: fixture.diagramProfile)
        try denyWrites(diagramRepo.folder(diagram.id))
        defer { try? restoreWrites(diagramRepo.folder(diagram.id)) }

        await model.enqueueDiagram(diagram.id)

        XCTAssertEqual(model.errorHandler.messages.filter { $0.contains("Не удалось сохранить статус постановки схемы в очередь") }.count, 1)
        XCTAssertEqual(try diagramRepo.load(diagram.id).state, .queued, "the manifest keeps its frozen run state; only the save failure became visible")
        try restoreWrites(diagramRepo.folder(diagram.id))
        try Data().write(to: fixture.release)
        try await waitUntil { !model.busy && model.diagrams.allSatisfy { $0.state == .completed } }
        await model.shutdown()
    }

    // MARK: - enqueueText: the queued admission transition

    func testTextEnqueueQueuedStatusSaveFailureIsReported() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await fixture(root)
        let model = fixture.model
        let archive = try XCTUnwrap(model.textArchive)
        let text = "Отчёт: Анна Петрова позвонила."
        let summary = try await archive.importCard(
            .init(bytes: Data(text.utf8), importedNameStem: "Отчёт", sourceFormat: .txt,
                  source: TextRevision(id: UUID().uuidString, text: text)))
        await model.reloadTexts()
        XCTAssertEqual(model.textCard(summary.id)?.attemptState, .waitingModel)
        let cardFolder = fixture.repository.root.appendingPathComponent("texts")
            .appendingPathComponent("items").appendingPathComponent(summary.id)
        try denyWrites(cardFolder)
        defer { try? restoreWrites(cardFolder) }

        // One readiness wake through the settings path (no extra task wake):
        // the wake admits the waiting card, whose queued transition then
        // fails to persist and must be reported.
        var settings = model.anonymizationSettings
        settings.setProfile(fixture.anonProfile.id, for: .anonymization)
        try AnonymizationSettingsStore(root: fixture.repository.root).save(settings)
        await model.reloadAnonymizationState()

        XCTAssertEqual(model.errorHandler.messages.filter { $0.contains("Не удалось сохранить статус постановки текста в очередь") }.count, 1)
        // The document keeps its honest waiting state; the reserved FIFO slot
        // is released by the admission re-check when the queue reaches the
        // job, so no worker-less «В очереди» row survives.
        let card = try await archive.loadCard(summary.id)
        XCTAssertEqual(card.latestAttempt.state, .waitingModel)
        try await waitUntil { model.textQueuePosition(for: summary.id) == nil }
        try restoreWrites(cardFolder)
        await model.shutdown()
    }
}
