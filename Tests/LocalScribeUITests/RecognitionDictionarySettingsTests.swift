import AppKit
import AVFoundation
import SwiftUI
import XCTest
import Synchronization
@testable import LocalScribeCore
@testable import LocalScribe

/// The global recognition dictionary: settings lifecycle, per-backend
/// applicability, visibility of the settings field, and run snapshots.
@MainActor
final class RecognitionDictionarySettingsTests: XCTestCase {
    private var suiteName = "LocalScribeTests.\(UUID().uuidString)"

    private func makeDefaults() throws -> UserDefaults {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { [suiteName] in UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    /// A worker fixture with the run-fingerprint formula of the current
    /// pipeline, including the recognition dictionary snapshot from run.json.
    private func writeWorker(_ root: URL) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("worker.py")
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
        base = info['sourceHash'] + info['profileHash'] + info['pipelineVersion']
        if info.get('recognitionTerms'):
            base += 'recognition:' + '\n'.join(info['recognitionTerms'])
        fingerprint = hashlib.sha256(base.encode()).hexdigest()
        if c['stage'] == 'preparingAudio':
            (run / 'transcript.json').write_text(json.dumps(dict(schemaVersion=1, fingerprint=fingerprint, diarized=True, segments=[])))
        elif c['stage'] == 'summarizing':
            (run / 'summary.json').write_text(json.dumps(dict(schemaVersion=1, language=info.get('summaryLanguage') or 'ru', overview=[], decisions=[], tasks=[], openQuestions=[])))
        emit('completed')
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }

    private func makeModel(root: URL, defaults: UserDefaults, worker: URL? = nil,
                           asrBackend: String? = nil, recommendWhisper: Bool = true) throws -> (RecordingRepository, AppModel, ModelCatalog) {
        let repo = try RecordingRepository(root: root)
        var profiles = ModelRole.audioRoles.map { role in
            ModelProfile(id: role.rawValue, repository: "test/model", revision: "test-revision", license: "test", files: [], role: role)
        }
        profiles[0].asrBackend = asrBackend
        if recommendWhisper { profiles[0].recommendationRank = 1 }
        if asrBackend != nil { profiles[0].tokenizerID = "tokenizer" }
        for index in profiles.indices {
            let data = Data(profiles[index].id.utf8)
            let folder = repo.models.appendingPathComponent(profiles[index].id)
            try Disk.directory(folder)
            let file = folder.appendingPathComponent("weights.bin")
            try data.write(to: file)
            profiles[index].files = [ModelFile(path: "weights.bin", localPath: "weights.bin", size: Int64(data.count), sha256: try Disk.hash(file))]
        }
        let catalog = ModelCatalog(models: profiles)
        let model = AppModel(repository: repo, startServices: false, workerExecutable: worker, userDefaults: defaults, catalog: catalog,
                             requestMicrophoneAccess: { true }, makeRecordingCapture: { MicrophoneRecorder(devices: $0) },
                             recognizeLiveCaptions: { _, stream, ready, _ in
            await ready()
            for await _ in stream {}
        })
        for profile in profiles { model.modelLibrary.installed(profile, catalog: catalog) }
        try model.modelLibrary.select(profiles[0], catalog: catalog)
        model.modelsReady = true
        return (repo, model, catalog)
    }

    private func completed(_ repo: RecordingRepository, title: String) throws -> Manifest {
        var m = Manifest(sourceType: "microphone", title: title, filename: "original.caf")
        m.sourceComplete = true; m.sha256 = String(repeating: "a", count: 64); m.durationMs = 1000
        try repo.save(m); return m
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !predicate() && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(predicate())
    }

    // MARK: - Settings draft: save, cancel, clear, caps

    func testDraftSaveNormalizeCancelClearAndPersist() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try makeDefaults()
        let (repo, model, _) = try makeModel(root: root, defaults: defaults)
        let catalog = try XCTUnwrap(model.activeCatalog)
        XCTAssertTrue(model.recognitionDictionary.isEmpty)
        XCTAssertNil(model.recognitionTerms(for: catalog))

        // A fresh draft mirrors the saved record and reports no changes.
        let untouched = SettingsDraft(model: model)
        XCTAssertEqual(untouched.recognitionDictionaryLines, [""])
        XCTAssertFalse(untouched.hasChanges(from: model))

        // Cancel: edits in an unapplied draft never reach the model.
        let cancelled = SettingsDraft(model: model)
        cancelled.recognitionDictionaryText = "  LocalScribe \n\n\nКамАЗ\nLocalScribe\n  Евгений  "
        XCTAssertTrue(cancelled.hasChanges(from: model))
        XCTAssertEqual(model.recognitionDictionary, [])

        // Save normalizes: trims, drops empty lines and exact duplicates, keeps order.
        let draft = SettingsDraft(model: model)
        draft.recognitionDictionaryText = "  LocalScribe \n\n\nКамАЗ\nLocalScribe\n  Евгений  "
        try model.applySettings(draft)
        XCTAssertEqual(model.recognitionDictionary, ["LocalScribe", "КамАЗ", "Евгений"])
        XCTAssertEqual(defaults.stringArray(forKey: "recognitionDictionary"), ["LocalScribe", "КамАЗ", "Евгений"])
        XCTAssertEqual(model.recognitionTerms(for: catalog), ["LocalScribe", "КамАЗ", "Евгений"])

        // Saving the dictionary alone starts no processing.
        XCTAssertFalse(model.busy)
        XCTAssertFalse(model.supervisor.running)

        // Relaunch reads the same list back.
        let reopened = AppModel(repository: repo, startServices: false, userDefaults: defaults)
        XCTAssertEqual(reopened.recognitionDictionary, ["LocalScribe", "КамАЗ", "Евгений"])

        // A structural cap violation is reported and keeps the previous record.
        let oversized = SettingsDraft(model: model)
        oversized.recognitionDictionaryText = String(repeating: "д", count: RecognitionDictionary.maximumTermCharacters + 1)
        XCTAssertThrowsError(try model.applySettings(oversized)) {
            XCTAssertTrue($0.localizedDescription.contains("распознавания"))
        }
        XCTAssertEqual(model.recognitionDictionary, ["LocalScribe", "КамАЗ", "Евгений"])

        // Clearing the field with save disables the hint.
        let cleared = SettingsDraft(model: model)
        cleared.recognitionDictionaryText = "   \n \n"
        try model.applySettings(cleared)
        XCTAssertEqual(model.recognitionDictionary, [])
        XCTAssertNil(model.recognitionTerms(for: catalog))
        XCTAssertEqual(defaults.stringArray(forKey: "recognitionDictionary"), [])
        await model.shutdown()
    }

    func testHintAppliesOnlyToWhisperAndQwenBackends() async throws {
        for backend in ["gigaam", "vibevoice-asr"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let (repo, model, _) = try makeModel(root: root, defaults: try makeDefaults(), asrBackend: backend)
            let active = try XCTUnwrap(model.activeCatalog)
            let draft = SettingsDraft(model: model)
            draft.recognitionDictionaryText = "LocalScribe"
            try model.applySettings(draft)
            XCTAssertEqual(model.recognitionDictionary, ["LocalScribe"])
            XCTAssertNil(model.recognitionTerms(for: active),
                "backend \(backend) must not pin the dictionary")
            await model.shutdown()
        }
    }

    // MARK: - Visibility of the settings field

    private func hostSettings(_ model: AppModel, draft: SettingsDraft) throws -> (NSHostingView<ModelSettings>, NSWindow) {
        _ = NSApplication.shared
        NSApplication.shared.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let hosting = NSHostingView(rootView: ModelSettings(model: model, draft: draft))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        return (hosting, window)
    }

    private func findElement(_ id: String, in view: NSView) -> AnyObject? {
        func descendants(_ element: AnyObject) -> [AnyObject] {
            let children = (element.accessibilityChildren?() ?? []).map { $0 as AnyObject }
            return children + children.flatMap { descendants($0) }
        }
        func subviews(_ view: NSView) -> [NSView] {
            view.subviews + view.subviews.flatMap { subviews($0) }
        }
        if let element = descendants(view).first(where: { $0.accessibilityIdentifier?() == id }) { return element }
        for subview in subviews(view) {
            if let element = descendants(subview).first(where: { $0.accessibilityIdentifier?() == id }) { return element }
        }
        return nil
    }

    private func fieldPresent(_ model: AppModel, draft: SettingsDraft) async throws -> Bool {
        let (hosting, window) = try hostSettings(model, draft: draft)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        hosting.layoutSubtreeIfNeeded()
        hosting.rootView = ModelSettings(model: model, draft: draft)
        try await Task.sleep(for: .milliseconds(150))
        hosting.layoutSubtreeIfNeeded()
        return findElement("settings.recognitionDictionary", in: hosting) != nil
    }

    /// The field follows the profile picked in the settings window, including a
    /// not-yet-downloaded recommended profile.
    func testVisibilityOfSettingsFieldBySelectedProfile() async throws {
        let cases: [(backend: String?, expected: Bool, install: Bool)] = [
            (nil, true, false),          // WhisperKit recommended but not downloaded
            ("qwen3", true, false),      // Qwen3-ASR recommended but not downloaded
            ("gigaam", false, false),    // other backend
        ]
        for testCase in cases {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let defaults = try makeDefaults()
            let (repo, model, _) = try makeModel(root: root, defaults: defaults,
                                                 asrBackend: testCase.backend, recommendWhisper: true)
            if !testCase.install {
                // Leave only the catalog recommendation: nothing selected or installed.
                model.modelLibrary = ModelLibrary()
                model.modelsReady = false
            }
            let present = try await fieldPresent(model, draft: SettingsDraft(model: model))
            XCTAssertEqual(present, testCase.expected, "backend \(testCase.backend ?? "whisper")")
            await model.shutdown()
        }
    }

    // MARK: - Run creation points pin the snapshot

    func testRunsPinSnapshotForProcessingReprocessAndSummaryRecreation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try makeDefaults()
        let worker = try writeWorker(root)
        let (repo, model, _) = try makeModel(root: root, defaults: defaults, worker: worker)
        let terms = ["LocalScribe", "КамАЗ"]
        let draft = SettingsDraft(model: model)
        draft.recognitionDictionaryText = terms.joined(separator: "\n")
        try model.applySettings(draft)

        // Import/after-record processing: the queue creates the run.
        let m = try completed(repo, title: "Snapshots")
        await model.reload()
        model.selection = m.id
        await model.enqueue(m.id)
        try Data().write(to: root.appendingPathComponent("release"))
        try await waitUntil { (try? repo.load(m.id).state) == .completed && !model.busy }
        let firstRun = try XCTUnwrap(try repo.load(m.id).activeRunId)
        let firstInfo = try Disk.read(RunInfo.self, at: repo.run(m.id, firstRun).appendingPathComponent("run.json"))
        XCTAssertEqual(firstInfo.recognitionTerms, terms)

        // Editing settings later never rewrites the pinned snapshot.
        let edited = SettingsDraft(model: model)
        edited.recognitionDictionaryText = "Другой список"
        try model.applySettings(edited)
        XCTAssertEqual(try Disk.read(RunInfo.self, at: repo.run(m.id, firstRun).appendingPathComponent("run.json")).recognitionTerms, terms)

        // «Обработать заново» takes the current setting.
        await model.repeatAnalysis(summaryOnly: false)
        try await waitUntil { (try? repo.load(m.id).state) == .completed && !model.busy }
        let secondRun = try XCTUnwrap(try repo.load(m.id).activeRunId)
        XCTAssertNotEqual(secondRun, firstRun)
        XCTAssertEqual(try Disk.read(RunInfo.self, at: repo.run(m.id, secondRun).appendingPathComponent("run.json")).recognitionTerms, ["Другой список"])

        // «Пересоздать итоги» reuses the saved transcript and pins no dictionary.
        await model.repeatAnalysis(summaryOnly: true, language: "ru")
        try await waitUntil { (try? repo.load(m.id).state) == .completed && !model.busy }
        let summaryRun = try XCTUnwrap(try repo.load(m.id).activeRunId)
        XCTAssertNil(try Disk.read(RunInfo.self, at: repo.run(m.id, summaryRun).appendingPathComponent("run.json")).recognitionTerms)
        await model.shutdown()
    }

    func testResumeUsesSavedSnapshotAfterSettingsChanged() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try makeDefaults()
        let worker = try writeWorker(root)
        let (repo, model, catalog) = try makeModel(root: root, defaults: defaults, worker: worker)
        let draft = SettingsDraft(model: model)
        draft.recognitionDictionaryText = "LocalScribe\nЕвгений"
        try model.applySettings(draft)
        let m = try completed(repo, title: "Resume")
        await model.reload()
        await model.enqueue(m.id)
        try await waitUntil { model.status == "fixture-ready-" + m.id }
        await model.shutdown()

        // A fresh launch with a changed dictionary resumes the interrupted run.
        let reopened = AppModel(repository: repo, startServices: false, workerExecutable: worker, userDefaults: defaults, catalog: catalog)
        for profile in ModelRole.audioRoles {
            if let profile = catalog.models.first(where: { $0.id == profile.rawValue }) {
                reopened.modelLibrary.installed(profile, catalog: catalog)
            }
        }
        try reopened.modelLibrary.select(XCTUnwrap(catalog.models.first { $0.id == "asr" }), catalog: catalog)
        reopened.modelsReady = true
        await reopened.reload()
        let changed = SettingsDraft(model: reopened)
        changed.recognitionDictionaryText = "Новый список"
        try reopened.applySettings(changed)
        let resume = try XCTUnwrap(reopened.resume(m.id))
        try Data().write(to: root.appendingPathComponent("release"))
        await resume.value
        try await waitUntil { (try? repo.load(m.id).state) == .completed && !reopened.busy }
        let runID = try XCTUnwrap(try repo.load(m.id).activeRunId)
        XCTAssertEqual(try Disk.read(RunInfo.self, at: repo.run(m.id, runID).appendingPathComponent("run.json")).recognitionTerms,
            ["LocalScribe", "Евгений"])
        await reopened.shutdown()
    }

    // MARK: - Background recognition pins the snapshot

    private final class DictionaryCapture: RecordingCapture {
        var onMeter: ((CaptureMeterReading) -> Void)?
        var onStopNeeded: ((String) -> Void)?
        var onWarning: ((String) -> Void)?
        var onResourcePressure: (() -> Void)?
        var onMicrophoneStatus: ((CaptureMicrophoneStatus) -> Void)?
        func start(folder: URL, microphone: MicrophoneCaptureRequest?, systemAudio: Bool) async throws {
            try Disk.directory(folder)
            let format = try XCTUnwrap(CapturePCM16Sink.format)
            let file = try AVAudioFile(forWriting: folder.appendingPathComponent("part-000000.caf"),
                                       settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: false)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600))
            buffer.frameLength = 1600
            buffer.int16ChannelData?[0].initialize(repeating: 0, count: 1600)
            try file.write(from: buffer)
        }
        func enableFallbackMicrophone() {}
        func stop() async throws -> Int64 { 1600 }
    }

    func testBackgroundRecognitionRunPinsSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try makeDefaults()
        let worker = try writeWorker(root)
        let microphone = MicrophoneInputDevice(deviceID: 10, uid: "built-in", name: "Built-In Mic", isBuiltIn: true)
        let devices = MicrophoneDevices(observeChanges: false, loadSnapshot: {
            MicrophoneDevicesSnapshot(devices: [microphone], defaultDeviceID: microphone.deviceID)
        }, loadRoute: { id in
            guard let input = microphone.deviceID == id ? microphone : nil else { return nil }
            return HALInputRoute(uid: input.uid, nominalRate: 48_000, channels: 1, streams: [], controls: [])
        })
        let repo = try RecordingRepository(root: root)
        var profiles = ModelRole.audioRoles.map { role in
            ModelProfile(id: role.rawValue, repository: "test/model", revision: "test-revision", license: "test", files: [], role: role)
        }
        for index in profiles.indices {
            let data = Data(profiles[index].id.utf8)
            let folder = repo.models.appendingPathComponent(profiles[index].id)
            try Disk.directory(folder)
            let file = folder.appendingPathComponent("weights.bin")
            try data.write(to: file)
            profiles[index].files = [ModelFile(path: "weights.bin", localPath: "weights.bin", size: Int64(data.count), sha256: try Disk.hash(file))]
        }
        let catalog = ModelCatalog(models: profiles)
        let model = AppModel(repository: repo, startServices: false, workerExecutable: worker, userDefaults: defaults,
                             catalog: catalog, microphoneDevices: devices, requestMicrophoneAccess: { true },
                             makeRecordingCapture: { _ in DictionaryCapture() },
                             recognizeLiveCaptions: { _, stream, ready, _ in
            await ready()
            for await _ in stream {}
        })
        for profile in profiles { model.modelLibrary.installed(profile, catalog: catalog) }
        try model.modelLibrary.select(profiles[0], catalog: catalog)
        model.modelsReady = true
        model.backgroundRecognition = true
        let draft = SettingsDraft(model: model)
        draft.recognitionDictionaryText = "LocalScribe\nКамАЗ"
        try model.applySettings(draft)

        try await model.startRecording()
        let id = try XCTUnwrap(model.recordingID)
        let captureRun = repo.run(id, try XCTUnwrap(try repo.load(id).pendingRunId))
        try await waitUntil { FileManager.default.fileExists(atPath: captureRun.appendingPathComponent("capture-run.json").path) }
        let info = try Disk.read(RunInfo.self, at: captureRun.appendingPathComponent("run.json"))
        XCTAssertEqual(info.recognitionTerms, ["LocalScribe", "КамАЗ"])
        XCTAssertEqual(try Disk.read(RunInfo.self, at: captureRun.appendingPathComponent("capture-run.json")).recognitionTerms,
            ["LocalScribe", "КамАЗ"])
        try Data().write(to: root.appendingPathComponent("release"))
        await model.stopRecording()
        await model.shutdown()
    }
}
