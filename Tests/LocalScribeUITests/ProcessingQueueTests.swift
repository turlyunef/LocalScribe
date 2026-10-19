import XCTest
import AVFoundation
import Synchronization
@testable import LocalScribeCore
@testable import LocalScribe

@MainActor
final class ProcessingQueueTests: XCTestCase {
    private func fixture(_ root: URL, observeIO: (@Sendable (RecordingRepository.IOOperation) -> Void)? = nil) throws -> (RecordingRepository, AppModel, URL) {
        var repo = try RecordingRepository(root: root)
        repo.observeIO = observeIO
        let executable = root.appendingPathComponent("worker.py")
        // A process fixture exercises the real supervisor, pipe protocol, stage
        // validation and queue, without models, microphone permission or real audio.
        let script = #"""
        #!/usr/bin/python3
        import sys, json, pathlib, time, hashlib
        c = json.loads(sys.stdin.readline())
        root = pathlib.Path(c['modelsPath']).parent
        run = pathlib.Path(c['recordingPath']) / 'runs' / c['runId']
        def emit(kind, message=''):
            print(json.dumps(dict(version=1, jobId=c['jobId'], runId=c['runId'], type=kind, message=message)), flush=True)
        with (root / 'events.jsonl').open('a') as f:
            f.write(json.dumps(c) + '\n')
        if (root / 'warnings').exists():
            for number in range(12):
                emit('warning', 'Test warning ' + str(number))
        emit('progress', 'fixture-ready-' + c['jobId'])
        while not (root / 'release').exists():
            time.sleep(0.02)
        if c.get('liveCapture'):
            if (root / 'live-success').exists():
                emit('completed')
                sys.exit(0)
            emit('failed', 'Тестовая ошибка модели')
            sys.exit(1)
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
        // Tiny pinned files let the coordinator exercise real SHA checks.
        var profiles = ModelRole.allCases.map { role in
            ModelProfile(id: role.rawValue, repository: "test/model", revision: "test-revision", license: "test", files: [], role: role)
        }
        profiles += [ModelProfile(id: "asr-b", repository: "test/model", revision: "test-revision", license: "test", files: [], role: .asr)]
        for index in profiles.indices {
            let data = Data(profiles[index].id.utf8)
            let folder = repo.models.appendingPathComponent(profiles[index].id)
            try Disk.directory(folder)
            let file = folder.appendingPathComponent("weights.bin")
            try data.write(to: file)
            profiles[index].files = [ModelFile(path: "weights.bin", localPath: "weights.bin", size: Int64(data.count), sha256: try Disk.hash(file))]
        }
        let catalog = ModelCatalog(models: profiles)
        let suite = "LocalScribeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let model = AppModel(repository: repo, startServices: false, workerExecutable: executable, userDefaults: defaults, catalog: catalog)
        for profile in profiles { model.modelLibrary.installed(profile, catalog: catalog) }
        try model.modelLibrary.select(profiles[0], catalog: catalog)
        model.modelsReady = true
        XCTAssertNotNil(model.activeCatalog)
        return (repo, model, root.appendingPathComponent("release"))
    }
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !predicate() && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(predicate())
    }
    private func completed(_ repo: RecordingRepository, title: String) throws -> Manifest {
        var m = Manifest(sourceType: "microphone", title: title, filename: "original.caf")
        m.sourceComplete = true; m.sha256 = String(repeating: "a", count: 64); m.durationMs = 1000
        try repo.save(m); return m
    }
    private func events(_ root: URL) throws -> [WorkerCommand] {
        try String(contentsOf: root.appendingPathComponent("events.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try JSONDecoder().decode(WorkerCommand.self, from: Data($0.utf8)) }
    }
    private func capture(_ repo: RecordingRepository, model: AppModel) throws -> (Manifest, RunInfo) {
        var m = Manifest(sourceType: "microphone", title: "Capture", filename: "original.caf")
        m.state = .recording
        let info = try repo.beginRun(&m, catalog: XCTUnwrap(model.activeCatalog), liveCapture: true)
        let folder = repo.folder(m.id).appendingPathComponent("capture")
        try Disk.directory(folder)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000))
        buffer.frameLength = 16000
        buffer.floatChannelData![0].initialize(repeating: 0.125, count: 16000)
        let file = try AVAudioFile(forWriting: folder.appendingPathComponent("part-000000.caf"), settings: format.settings)
        try file.write(from: buffer)
        return (m, info)
    }
    private func finishLiveWorker(_ root: URL, repo: RecordingRepository, m: Manifest, info: RunInfo) throws {
        let fragments = try CaptureIntegrity.fragments(at: repo.folder(m.id).appendingPathComponent("capture"))
        let part = LiveASRPart(part: ASRPart(fingerprint: info.fingerprint, index: 0, startMs: 0, endMs: 1000, segments: []),
                               readStartMs: 0, readEndMs: 1000, fragments: fragments)
        try Disk.write(part, to: repo.run(m.id, info.id).appendingPathComponent("live/part-0.json"))
        try Data().write(to: root.appendingPathComponent("live-success"))
        try Data().write(to: root.appendingPathComponent("release"))
    }
    private func interrupted(_ repo: RecordingRepository, model: AppModel, legacy: Bool = false) async throws -> (Manifest, RunInfo, Data) {
        var m = try completed(repo, title: "Interrupted A")
        var info = try repo.beginRun(&m, catalog: XCTUnwrap(model.activeCatalog))
        if legacy {
            info.modelIDs = nil
            try Disk.write(info, to: repo.run(m.id, info.id).appendingPathComponent("run.json"))
        }
        let checkpoint = repo.run(m.id, info.id).appendingPathComponent("transcript.json")
        try Disk.write(Transcript(fingerprint: info.fingerprint, diarized: true, segments: [
            Segment(id: "s", startMs: 0, endMs: 1000, text: "Контрольная точка А", language: "ru")
        ]), to: checkpoint)
        m.state = .interrupted; try repo.save(m)
        _ = try await model.archive?.refresh(m.id); await model.reload(); model.selection = m.id
        return (m, info, try Data(contentsOf: checkpoint))
    }
    private func selectB(_ model: AppModel) throws {
        let b = try XCTUnwrap(model.catalog?.models.first { $0.id == "asr-b" })
        model.selectModel(b)
        XCTAssertEqual(model.modelLibrary.selectedByRole["asr"], b.id)
    }
    func testDisabledAutomaticSummariesPublishesTranscriptAndAllowsExplicitSummaryInEitherLanguage() async throws {
        for language in ["ru", "en"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let (repo, model, release) = try fixture(root)
            model.automaticSummaries = false
            var m = try completed(repo, title: "Transcript only")
            m.sourceType = "import"; try repo.save(m)
            try Data().write(to: release)
            await model.completeImport(m)
            try await waitUntil { !model.busy && (try? repo.load(m.id).state) == .completed && model.transcript != nil }

            let completed = try repo.load(m.id)
            let firstRun = try XCTUnwrap(completed.activeRunId)
            let transcriptURL = repo.run(m.id, firstRun).appendingPathComponent("transcript.json")
            let transcriptBytes = try Data(contentsOf: transcriptURL)
            XCTAssertNil(completed.pendingRunId)
            XCTAssertEqual(try events(root).map(\.stage), [.preparingAudio])
            XCTAssertTrue(model.transcript?.diarized == true)
            XCTAssertNil(model.summary)
            XCTAssertNil(try repo.results(completed).1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: repo.run(m.id, firstRun).appendingPathComponent("summary.json").path))

            await model.repeatAnalysis(summaryOnly: true, language: language)
            try await waitUntil { !model.busy && model.summary?.language == language }
            let recreated = try repo.load(m.id)
            XCTAssertEqual(recreated.state, .completed)
            XCTAssertNotEqual(recreated.activeRunId, firstRun)
            XCTAssertNil(recreated.pendingRunId)
            XCTAssertFalse(model.automaticSummaries)
            XCTAssertEqual(try events(root).map(\.stage), [.preparingAudio, .summarizing])
            XCTAssertEqual(try Data(contentsOf: transcriptURL), transcriptBytes)
            let info = try Disk.read(RunInfo.self, at: repo.run(m.id, XCTUnwrap(recreated.activeRunId)).appendingPathComponent("run.json"))
            XCTAssertEqual(info.transcriptSourceRunID, firstRun)
            XCTAssertEqual(info.summaryLanguage, language)
            XCTAssertEqual(try repo.results(recreated).1?.language, language)
            await model.shutdown()
        }
    }
    func testDisablingAutomaticSummariesDuringProcessingSkipsUpcomingSummary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (repo, model, release) = try fixture(root)
        let m = try completed(repo, title: "Disable during ASR")
        XCTAssertTrue(model.automaticSummaries)
        await model.enqueue(m.id)
        try await waitUntil { model.status == "fixture-ready-" + m.id }
        model.automaticSummaries = false
        try Data().write(to: release)
        try await waitUntil { !model.busy && (try? repo.load(m.id).state) == .completed }
        XCTAssertEqual(try events(root).map(\.stage), [.preparingAudio])
        XCTAssertNil(try repo.results(repo.load(m.id)).1)
        await model.shutdown()
    }
    func testExplicitSummaryBeforeFirstSuccessfulRunIgnoresDisabledPreference() async throws {
        for language in [nil, "en"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let (repo, model, release) = try fixture(root)
            let (m, previous, checkpoint) = try await interrupted(repo, model: model)
            try await waitUntil { model.transcript != nil }
            XCTAssertNil(model.selected?.activeRunId)
            model.automaticSummaries = false
            try Data().write(to: release)
            await model.repeatAnalysis(summaryOnly: true, language: language)
            try await waitUntil { !model.busy && model.summary?.language == (language ?? "ru") }
            XCTAssertEqual(try repo.load(m.id).state, .completed)
            XCTAssertEqual(try events(root).map(\.stage), [.preparingAudio, .summarizing])
            XCTAssertEqual(try Data(contentsOf: repo.run(m.id, previous.id).appendingPathComponent("transcript.json")), checkpoint)
            await model.shutdown()
        }
    }
    func testDisabledAutomaticSummariesAlsoSkipsSummaryAfterLiveCaptureAndOnResume() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (repo, model, _) = try fixture(root)
        model.automaticSummaries = false
        let (m, info) = try capture(repo, model: model)
        model.recordingID = m.id; await model.enqueueCapture(m.id)
        try await waitUntil { model.status == "fixture-ready-" + m.id }
        try await model.finalizeCapture(m.id, expectedFrames: 16000)
        model.recordingID = nil; await model.enqueue(m.id)
        try finishLiveWorker(root, repo: repo, m: m, info: info)
        try await waitUntil { !model.busy && (try? repo.load(m.id).state) == .completed }
        XCTAssertEqual(try repo.load(m.id).activeRunId, info.id)
        XCTAssertEqual(try events(root).map(\.stage), [.transcribing, .preparingAudio])
        XCTAssertNil(try repo.results(repo.load(m.id)).1)

        let (pending, pendingInfo, checkpoint) = try await interrupted(repo, model: model)
        model.resume(pending.id)
        try await waitUntil { !model.busy && (try? repo.load(pending.id).state) == .completed }
        XCTAssertEqual(try repo.load(pending.id).activeRunId, pendingInfo.id)
        XCTAssertEqual(try events(root).count, 2)
        XCTAssertEqual(try Data(contentsOf: repo.run(pending.id, pendingInfo.id).appendingPathComponent("transcript.json")), checkpoint)
        await model.shutdown()
    }
    func testDisablingAutomaticSummariesDoesNotPublishCorruptExistingSummary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (repo, model, _) = try fixture(root)
        let (m, info, _) = try await interrupted(repo, model: model)
        let summary = repo.run(m.id, info.id).appendingPathComponent("summary.json")
        let bytes = Data("broken JSON".utf8)
        try bytes.write(to: summary)
        model.automaticSummaries = false
        model.resume(m.id)
        try await waitUntil { !model.busy && (try? repo.load(m.id).state) == .failed }
        XCTAssertNil(try repo.load(m.id).activeRunId)
        XCTAssertEqual(try repo.load(m.id).pendingRunId, info.id)
        XCTAssertEqual(try Data(contentsOf: summary), bytes)
        XCTAssertFalse(model.errorHandler.messages.isEmpty)
        await model.shutdown()
    }
    func testCancelAndPauseInvalidateEnqueueWhileManifestReadIsPending() async throws {
        for cancel in [true, false] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let gate = DispatchSemaphore(value: 0)
            defer { gate.signal() }
            let state = Mutex((enabled: false, blocked: false))
            let (repo, model, _) = try fixture(root, observeIO: { operation in
                guard operation == .manifestRead else { return }
                let block = state.withLock { value in
                    guard value.enabled, !value.blocked else { return false }
                    value.blocked = true; return true
                }
                if block { gate.wait() }
            })
            let m = try completed(repo, title: "Pending enqueue")
            _ = try await model.archive?.refresh(m.id); await model.reload()
            model.selection = m.id
            state.withLock { $0.enabled = true }
            let enqueue = Task { await model.enqueue(m.id) }
            try await waitUntil { state.withLock { $0.blocked } }
            // This task runs when cancel/pause suspends, after invalidating the request.
            let release = Task { @MainActor in gate.signal() }
            if cancel { await model.cancelSelected() }
            else { await model.pause(reason: "Test pause") }
            await release.value; await enqueue.value
            XCTAssertFalse(model.busy)
            XCTAssertFalse(model.supervisor.running)
            XCTAssertEqual(try repo.load(m.id).state, cancel ? .cancelled : m.state)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("events.jsonl").path))
            await model.shutdown()
        }
    }
    func testWorkerWarningsAndRenamePersistBeforeFinalStagePublication() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (repo, model, release) = try fixture(root)
        let manifest = try completed(repo, title: "Before rename")
        try Data().write(to: root.appendingPathComponent("warnings"))
        model.selection = manifest.id
        await model.enqueue(manifest.id)
        try await waitUntil { model.status == "fixture-ready-" + manifest.id }
        await model.renameRecording(manifest.id, title: "After rename")
        XCTAssertEqual(try repo.load(manifest.id).warnings.count, 12)
        try Data().write(to: release)
        try await waitUntil { !model.busy && (try? repo.load(manifest.id).state) == .completedWithWarnings }
        XCTAssertEqual(model.selected?.displayTitle, "After rename")
        XCTAssertEqual(model.selected?.warnings.count, 12)
        XCTAssertEqual(try repo.load(manifest.id).displayTitle, "After rename")
        await model.archive?.flushIndex()
        let index = try Disk.read([Manifest].self, at: root.appendingPathComponent("index.json"))
        XCTAssertEqual(index.first?.state, .completedWithWarnings)
        XCTAssertEqual(index.first?.warnings.count, 12)
        await model.shutdown()
    }
    func testResumeAfterSelectingBPreservesRunAndUsesCheckpointIncludingLegacy() async throws {
        for legacy in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let (repo, model, release) = try fixture(root)
            let (m, info, checkpoint) = try await interrupted(repo, model: model, legacy: legacy)
            let infoPath = repo.run(m.id, info.id).appendingPathComponent("run.json")
            let runBytes = try Data(contentsOf: infoPath)
            try selectB(model)
            XCTAssertNotEqual(model.activeCatalog?.fingerprint, info.profileHash)
            XCTAssertEqual(try repo.load(m.id).pendingRunId, info.id)
            model.resume(m.id)
            try await waitUntil { model.status == "fixture-ready-" + m.id }
            XCTAssertEqual(try repo.load(m.id).pendingRunId, info.id)
            XCTAssertEqual(try events(root).map(\.stage), [.summarizing])
            XCTAssertEqual(try events(root).map(\.runId), [info.id])
            try Data().write(to: release)
            try await waitUntil { !model.busy && (try? repo.load(m.id).state) == .completed }
            let saved = try Disk.read(RunInfo.self, at: infoPath)
            XCTAssertEqual(saved.modelIDs, info.modelIDs)
            XCTAssertEqual(saved.fingerprint, info.fingerprint)
            XCTAssertEqual(try Data(contentsOf: infoPath), runBytes)
            XCTAssertEqual(try Data(contentsOf: repo.run(m.id, info.id).appendingPathComponent("transcript.json")), checkpoint)
            XCTAssertEqual(try repo.load(m.id).activeRunId, info.id)
        }
    }
    func testResumeUsesPinnedAWithoutReadySelectionForNewJobs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (repo, model, release) = try fixture(root)
        let (m, info, _) = try await interrupted(repo, model: model)
        try selectB(model)
        let b = try XCTUnwrap(model.catalog?.models.first { $0.id == "asr-b" })
        try FileManager.default.removeItem(at: repo.models.appendingPathComponent(b.id))
        // Simulate an unavailable new-job selection while all pinned A files exist.
        model.modelLibrary = ModelLibrary()
        model.modelsReady = false
        XCTAssertNil(model.activeCatalog)
        model.resume(m.id)
        try await waitUntil { model.status == "fixture-ready-" + m.id }
        try Data().write(to: release)
        try await waitUntil { !model.busy && (try? repo.load(m.id).state) == .completed }
        XCTAssertEqual(try repo.load(m.id).activeRunId, info.id)
        XCTAssertEqual(try events(root).map(\.stage), [.summarizing])
    }
    func testMissingPinnedABlocksResumeAndExplicitReprocessingCreatesB() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (repo, model, release) = try fixture(root)
        let (m, info, checkpoint) = try await interrupted(repo, model: model)
        let infoPath = repo.run(m.id, info.id).appendingPathComponent("run.json")
        let oldRun = try Data(contentsOf: infoPath)
        try selectB(model)
        try FileManager.default.removeItem(at: repo.models.appendingPathComponent("asr"))
        model.resume(m.id)
        try await waitUntil { !model.busy && !model.finalizingRecording && (try? repo.load(m.id).state) == .failed }
        let failed = try repo.load(m.id)
        XCTAssertEqual(failed.pendingRunId, info.id)
        XCTAssertTrue(failed.lastError?.contains("отсутствует или повреждён") == true)
        XCTAssertTrue(failed.lastError?.contains("Обработать заново") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("events.jsonl").path))
        XCTAssertEqual(try Data(contentsOf: infoPath), oldRun)

        await model.repeatAnalysis(summaryOnly: false)
        try await waitUntil { model.status == "fixture-ready-" + m.id }
        let newID = try XCTUnwrap(repo.load(m.id).pendingRunId)
        XCTAssertNotEqual(newID, info.id)
        let newInfo = try Disk.read(RunInfo.self, at: repo.run(m.id, newID).appendingPathComponent("run.json"))
        XCTAssertEqual(try newInfo.modelID(for: .asr), "asr-b")
        XCTAssertEqual(newInfo.profileHash, model.activeCatalog?.fingerprint)
        XCTAssertNotEqual(newInfo.fingerprint, info.fingerprint)
        XCTAssertEqual(try events(root).map(\.stage), [.preparingAudio])
        try Data().write(to: release)
        try await waitUntil { !model.busy && (try? repo.load(m.id).state) == .completed }
        XCTAssertEqual(try repo.load(m.id).activeRunId, newID)
        XCTAssertEqual(try Data(contentsOf: infoPath), oldRun)
        XCTAssertEqual(try Data(contentsOf: repo.run(m.id, info.id).appendingPathComponent("transcript.json")), checkpoint)
    }
    func testChangedPipelineBlocksResumeWithoutReplacingRun() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (repo, model, _) = try fixture(root)
        let (m, original, _) = try await interrupted(repo, model: model)
        var info = original; info.pipelineVersion = "older-pipeline"
        let infoPath = repo.run(m.id, info.id).appendingPathComponent("run.json")
        try Disk.write(info, to: infoPath)
        let bytes = try Data(contentsOf: infoPath)
        model.resume(m.id)
        try await waitUntil { !model.busy && !model.finalizingRecording && (try? repo.load(m.id).state) == .failed }
        XCTAssertTrue(try repo.load(m.id).lastError?.contains("Версия обработки изменилась") == true)
        XCTAssertEqual(try repo.load(m.id).pendingRunId, info.id)
        XCTAssertEqual(try Data(contentsOf: infoPath), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("events.jsonl").path))
    }
    func testSavingActiveCaptureKeepsProcessingStateAndCompletesWithoutResume() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (repo, model, _) = try fixture(root)
        let (m, info) = try capture(repo, model: model)
        model.recordingID = m.id; await model.enqueueCapture(m.id)
        try await waitUntil { model.status == "fixture-ready-" + m.id }

        // The same stop path used after the microphone closes its last CAF.
        try await model.finalizeCapture(m.id, expectedFrames: 16000)
        model.recordingID = nil; await model.enqueue(m.id)
        let saved = try repo.load(m.id)
        XCTAssertTrue(saved.sourceComplete)
        XCTAssertEqual(saved.state, .transcribing)
        XCTAssertTrue(saved.state.processing) // UI shows progress/cancel, not Resume.
        XCTAssertEqual(saved.pendingRunId, info.id)
        XCTAssertTrue(model.supervisor.running)
        XCTAssertEqual(try events(root).count, 1)
        model.resume(m.id)
        XCTAssertFalse(model.finalizingRecording)

        try finishLiveWorker(root, repo: repo, m: m, info: info)
        try await waitUntil { !model.busy && (try? repo.load(m.id).state) == .completed }
        XCTAssertEqual(try repo.load(m.id).activeRunId, info.id)
        XCTAssertEqual(try events(root).map(\.stage), [.transcribing, .preparingAudio, .summarizing])
    }
    func testSavingQueuedCaptureKeepsFIFOAndStartsAutomatically() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (repo, model, _) = try fixture(root)
        let first = try completed(repo, title: "First")
        await model.enqueue(first.id)
        try await waitUntil { model.status == "fixture-ready-" + first.id }
        let (m, info) = try capture(repo, model: model)
        model.recordingID = m.id; await model.enqueueCapture(m.id)
        try await model.finalizeCapture(m.id, expectedFrames: 16000)
        model.recordingID = nil; await model.enqueue(m.id)
        XCTAssertEqual(try repo.load(m.id).state, .queued)
        XCTAssertEqual(try events(root).map(\.jobId), [first.id])
        try finishLiveWorker(root, repo: repo, m: m, info: info)
        try await waitUntil { !model.busy && (try? repo.load(m.id).state) == .completed }
        XCTAssertEqual(try events(root).map(\.jobId), [first.id, first.id, m.id, m.id, m.id])
        XCTAssertEqual(try repo.load(m.id).activeRunId, info.id)
    }
    func testFailedSavedCaptureCanActuallyResumeItsExistingRun() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (repo, model, release) = try fixture(root)
        let (m, info) = try capture(repo, model: model)
        model.recordingID = m.id; await model.enqueueCapture(m.id)
        try await waitUntil { model.status == "fixture-ready-" + m.id }
        try await model.finalizeCapture(m.id, expectedFrames: 16000)
        model.recordingID = nil; await model.enqueue(m.id)
        try Data().write(to: release)
        try await waitUntil { !model.busy && (try? repo.load(m.id).state) == .failed }
        XCTAssertEqual(try repo.load(m.id).lastError, "Тестовая ошибка модели")
        try finishLiveWorker(root, repo: repo, m: m, info: info)
        model.resume(m.id)
        try await waitUntil { (try? repo.load(m.id).state) == .completed && !model.busy }
        XCTAssertEqual(try repo.load(m.id).activeRunId, info.id)
        XCTAssertEqual(try events(root).filter { $0.liveCapture == true }.count, 2)
    }
    func testOldAnalysisSurvivesNewCaptureAndFinishedRecordingWaitsFIFO() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (repo, model, release) = try fixture(root)
        let first = try completed(repo, title: "First")
        await model.enqueue(first.id)
        try await waitUntil { model.status == "fixture-ready-" + first.id }
        let second = try completed(repo, title: "Second")
        // The recording owner changes while the first worker is alive.
        model.recordingID = second.id; model.supervisor.recordingActive = true
        await model.enqueue(second.id)
        XCTAssertTrue(model.supervisor.running)
        XCTAssertEqual(try repo.load(first.id).state, .preparingAudio)
        XCTAssertEqual(try events(root).map(\.jobId), [first.id])
        try Data().write(to: release)
        try await waitUntil { !model.busy && (try? repo.load(second.id).state) == .completed }
        XCTAssertEqual(try events(root).map(\.jobId), [first.id, first.id, second.id, second.id])
        XCTAssertEqual(try repo.load(first.id).state, .completed)
        model.recordingID = nil
    }
    func testLiveCaptureWaitsBehindOldWorkAndModelFailureKeepsMicrophoneState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (repo, model, release) = try fixture(root)
        let first = try completed(repo, title: "First")
        await model.enqueue(first.id)
        try await waitUntil { model.status == "fixture-ready-" + first.id }
        var capture = Manifest(sourceType: "microphone", title: "Still recording", filename: "original.caf")
        capture.state = .recording
        _ = try repo.beginRun(&capture, catalog: XCTUnwrap(model.activeCatalog), liveCapture: true)
        model.recordingID = capture.id; await model.enqueueCapture(capture.id)
        XCTAssertEqual(try events(root).count, 1)
        try Data().write(to: release)
        try await waitUntil { !model.busy && (try? repo.load(capture.id).captureProcessing) == .failed }
        let commands = try events(root)
        XCTAssertEqual(commands.map(\.jobId), [first.id, first.id, capture.id])
        XCTAssertEqual(commands.last?.liveCapture, true)
        XCTAssertEqual(try repo.load(capture.id).state, .recording)
        XCTAssertEqual(model.recordingID, capture.id)
        XCTAssertEqual(try repo.load(first.id).state, .completed)
        model.recordingID = nil
    }
    func testMemoryPressureReleasesWorkerAndKeepsQueueAndRecording() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (repo, model, release) = try fixture(root)
        let first = try completed(repo, title: "First"), second = try completed(repo, title: "Second")
        await model.enqueue(first.id)
        try await waitUntil { model.status == "fixture-ready-" + first.id }
        await model.enqueue(second.id)
        var capture = Manifest(sourceType: "microphone", title: "Capture", filename: "original.caf")
        capture.state = .recording
        _ = try repo.beginRun(&capture, catalog: XCTUnwrap(model.activeCatalog), liveCapture: true)
        model.recordingID = capture.id; await model.enqueueCapture(capture.id)
        model.pauseForCaptureResources(memoryPressure: true)
        try await waitUntil { !model.busy && !model.supervisor.running }
        XCTAssertEqual(try repo.load(first.id).state, .queued)
        XCTAssertEqual(try repo.load(second.id).state, .queued)
        XCTAssertEqual(try repo.load(capture.id).state, .recording)
        XCTAssertEqual(model.recordingID, capture.id)
        try Data().write(to: release)
        model.resumeAfterMemoryPressure()
        try await waitUntil { !model.busy && (try? repo.load(capture.id).captureProcessing) == .failed }
        XCTAssertEqual(try events(root).map(\.jobId), [first.id, first.id, first.id, second.id, second.id, capture.id])
        XCTAssertEqual(try repo.load(first.id).state, .completed)
        XCTAssertEqual(try repo.load(second.id).state, .completed)
        XCTAssertEqual(model.recordingID, capture.id)
        model.recordingID = nil
    }

}
