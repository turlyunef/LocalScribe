import XCTest
import AVFoundation
import LocalScribeCore
@testable import LocalScribe

@MainActor
final class ProcessingQueueTests: XCTestCase {
    private func fixture(_ root: URL) throws -> (RecordingRepository, AppModel, URL) {
        let repo = try RecordingRepository(root: root)
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
            (run / 'summary.json').write_text(json.dumps(dict(schemaVersion=1, language='ru', overview=[], decisions=[], tasks=[], openQuestions=[])))
        emit('completed')
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let model = AppModel(repository: repo, startServices: false, workerExecutable: executable)
        let catalog = try XCTUnwrap(model.catalog)
        for profile in catalog.models where ModelRole(rawValue: profile.id) != nil { model.modelLibrary.installed(profile, catalog: catalog) }
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
    func testSavingActiveCaptureKeepsProcessingStateAndCompletesWithoutResume() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (repo, model, _) = try fixture(root)
        let (m, info) = try capture(repo, model: model)
        model.recordingID = m.id; model.enqueueCapture(m.id)
        try await waitUntil { model.status == "fixture-ready-" + m.id }

        // The same stop path used after the microphone closes its last CAF.
        try await model.finalizeCapture(m.id, expectedFrames: 16000)
        model.recordingID = nil; model.enqueue(m.id)
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
        model.enqueue(first.id)
        try await waitUntil { model.status == "fixture-ready-" + first.id }
        let (m, info) = try capture(repo, model: model)
        model.recordingID = m.id; model.enqueueCapture(m.id)
        try await model.finalizeCapture(m.id, expectedFrames: 16000)
        model.recordingID = nil; model.enqueue(m.id)
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
        model.recordingID = m.id; model.enqueueCapture(m.id)
        try await waitUntil { model.status == "fixture-ready-" + m.id }
        try await model.finalizeCapture(m.id, expectedFrames: 16000)
        model.recordingID = nil; model.enqueue(m.id)
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
        model.enqueue(first.id)
        try await waitUntil { model.status == "fixture-ready-" + first.id }
        let second = try completed(repo, title: "Second")
        // The recording owner changes while the first worker is alive.
        model.recordingID = second.id; model.supervisor.recordingActive = true
        model.enqueue(second.id)
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
        model.enqueue(first.id)
        try await waitUntil { model.status == "fixture-ready-" + first.id }
        var capture = Manifest(sourceType: "microphone", title: "Still recording", filename: "original.caf")
        capture.state = .recording
        _ = try repo.beginRun(&capture, catalog: XCTUnwrap(model.activeCatalog), liveCapture: true)
        model.recordingID = capture.id; model.enqueueCapture(capture.id)
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
        model.enqueue(first.id)
        try await waitUntil { model.status == "fixture-ready-" + first.id }
        model.enqueue(second.id)
        var capture = Manifest(sourceType: "microphone", title: "Capture", filename: "original.caf")
        capture.state = .recording
        _ = try repo.beginRun(&capture, catalog: XCTUnwrap(model.activeCatalog), liveCapture: true)
        model.recordingID = capture.id; model.enqueueCapture(capture.id)
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
