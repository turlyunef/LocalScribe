import XCTest
import AVFoundation
import Synchronization
@testable import LocalScribeCore
@testable import LocalScribeWorker

private final class FixtureASREngine: ASREngine {
    let capabilities: ASRCapabilities
    let body: (ASRRequest) async throws -> ASRResult
    init(modes: Set<ASRInputMode> = [.offline, .closedFragments], body: @escaping (ASRRequest) async throws -> ASRResult) {
        capabilities = ASRCapabilities(inputModes: modes, wordTimings: .unavailable)
        self.body = body
    }
    func recognize(_ request: ASRRequest) async throws -> ASRResult { try await body(request) }
}

final class ASREngineIntegrationTests: XCTestCase {
    private struct Fixture: Sendable {
        let repo: RecordingRepository
        let manifest: Manifest
        let info: RunInfo
        let catalog: ModelCatalog
        let command: WorkerCommand
        var run: URL { repo.run(manifest.id, info.id) }
    }

    private func fixture(_ root: URL, live: Bool) throws -> Fixture {
        let repo = try RecordingRepository(root: root.appendingPathComponent("archive"))
        // Real per-profile files with matching sizes and SHA-256: the factory
        // validates pinned Whisper weights before loading, like the diagram engine.
        let bytes = Data("whisper fixture weights".utf8)
        let file = ModelFile(path: "weights", localPath: "weights", size: Int64(bytes.count),
                             sha256: Disk.fingerprint("whisper fixture weights"))
        let catalog = ModelCatalog(models: ModelRole.audioRoles.map {
            ModelProfile(id: $0.rawValue, repository: "fixture/model", revision: "fixed", license: "test", files: [file], role: $0)
        })
        for profile in catalog.models {
            let folder = repo.models.appendingPathComponent(profile.id)
            try Disk.directory(folder)
            try bytes.write(to: folder.appendingPathComponent(file.localPath))
        }
        var manifest = Manifest(sourceType: live ? "microphone" : "import", title: "ASR contract", filename: "original.caf")
        let recording = repo.folder(manifest.id), original = recording.appendingPathComponent(manifest.originalRelativePath)
        try Disk.directory(original.deletingLastPathComponent())
        if live {
            let folder = recording.appendingPathComponent("capture")
            try Disk.directory(folder)
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
            for index in 0..<7 {
                let frames = index == 6 ? 2000 : 160000
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
                buffer.frameLength = buffer.frameCapacity
                buffer.floatChannelData![0].initialize(repeating: 0.125, count: frames)
                try autoreleasepool {
                    let file = try AVAudioFile(forWriting: folder.appendingPathComponent(String(format: "part-%06d.caf", index)), settings: format.settings)
                    try file.write(from: buffer)
                }
            }
            // Invalid open audio would fail if the reader ever included it.
            try Data("open writer".utf8).write(to: folder.appendingPathComponent("part-000007.partial.caf"))
            _ = try Media.assembleCapture(folder, destination: original)
            manifest.state = .recording
        } else {
            try Data("source hash fixture".utf8).write(to: original)
            manifest.sourceComplete = true
        }
        manifest.durationMs = live ? 60_125 : 300_125
        manifest.sha256 = try Disk.hash(original)
        let info = try repo.beginRun(&manifest, catalog: catalog, liveCapture: live)
        if live {
            manifest.sourceComplete = true; manifest.state = .recorded
            try repo.save(manifest)
            let seal = CaptureSeal(info: info, sourceHash: manifest.sha256,
                fragments: try CaptureIntegrity.fragments(at: recording.appendingPathComponent("capture")))
            try Disk.write(seal, to: repo.run(manifest.id, info.id).appendingPathComponent("capture-seal.json"))
        }
        let resources = root.appendingPathComponent("Resources"), tools = resources.appendingPathComponent("tools")
        try Disk.write(catalog, to: resources.appendingPathComponent("models.lock.json"))
        if live {
            let bundledTools = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Assets/tools")
            guard FileManager.default.fileExists(atPath: bundledTools.appendingPathComponent("ffmpeg").path) else {
                throw XCTSkip("Closed-fragment integration requires local Assets/tools")
            }
            try FileManager.default.createSymbolicLink(at: tools, withDestinationURL: bundledTools)
        }
        var command = WorkerCommand(jobId: manifest.id, runId: info.id, stage: .transcribing,
            recordingPath: recording.path, modelsPath: repo.models.path, toolsPath: tools.path)
        command.liveCapture = live
        return Fixture(repo: repo, manifest: manifest, info: info, catalog: catalog, command: command)
    }

    private var hardware: ModelHardware {
        ModelHardware(chip: "Fixture M1", memoryBytes: 16 * 1_073_741_824, cpuCores: 8,
            gpuWorkingSetBytes: 12 * 1_073_741_824, appleSilicon: true, supportsMetal: true)
    }

    private func offlineVibeVoice(_ root: URL, duration: Int, sourceType: String) throws -> Fixture {
        let repo = try RecordingRepository(root: root.appendingPathComponent("archive"))
        let bytes = Data("pinned fake weights".utf8)
        let file = ModelFile(path: "weights", localPath: "weights", size: Int64(bytes.count),
                             sha256: Disk.fingerprint("pinned fake weights"))
        var profiles = ModelRole.audioRoles.map { role in
            ModelProfile(id: role == .asr ? "asr-vibevoice-4bit" : role.rawValue,
                repository: "fixture/model", revision: "fixed", license: "test", files: [file], role: role)
        }
        profiles[0].asrBackend = "vibevoice-asr"
        profiles[0].asrPolicy = VibeVoiceASREngine.policyID
        profiles[0].tokenizerID = "tokenizer"
        profiles[0].recommendedMemoryGB = 32
        profiles[0].workingMemoryGB = 20
        let catalog = ModelCatalog(models: profiles)
        for profile in profiles {
            let folder = repo.models.appendingPathComponent(profile.id)
            try Disk.directory(folder)
            try bytes.write(to: folder.appendingPathComponent(file.localPath))
        }
        var manifest = Manifest(sourceType: sourceType, title: "Offline VibeVoice contract", filename: "original.caf")
        let recording = repo.folder(manifest.id)
        let original = recording.appendingPathComponent(manifest.originalRelativePath)
        try Disk.directory(original.deletingLastPathComponent())
        try Data("source hash fixture".utf8).write(to: original)
        manifest.sourceComplete = true
        manifest.durationMs = duration
        manifest.sha256 = try Disk.hash(original)
        // A completed run remains readable even after the pipeline version changes.
        var previous = RunInfo(sourceHash: manifest.sha256, profileHash: catalog.fingerprint)
        previous.pipelineVersion = "1.0.0-audio2-asr9-live1-diarization4-summary16"
        let active = repo.run(manifest.id, previous.id)
        try Disk.write(previous, to: active.appendingPathComponent("run.json"))
        try Disk.write(Transcript(fingerprint: previous.fingerprint, diarized: true, segments: [
            Segment(id: "saved", startMs: 0, endMs: 1000, text: "Previous result", language: "en")
        ]), to: active.appendingPathComponent("transcript.json"))
        manifest.activeRunId = previous.id
        let info = try repo.beginRun(&manifest, catalog: catalog)
        let resources = root.appendingPathComponent("Resources")
        try Disk.write(catalog, to: resources.appendingPathComponent("models.lock.json"))
        let command = WorkerCommand(jobId: manifest.id, runId: info.id, stage: .transcribing,
            recordingPath: recording.path, modelsPath: repo.models.path, toolsPath: resources.appendingPathComponent("tools").path)
        return Fixture(repo: repo, manifest: manifest, info: info, catalog: catalog, command: command)
    }

    private var vibeVoiceHardware: ModelHardware {
        ModelHardware(chip: "Compatible fixture", memoryBytes: 36 * 1_073_741_824, cpuCores: 12,
            gpuWorkingSetBytes: 27 * 1_073_741_824, appleSilicon: true, supportsMetal: true)
    }

    func testOfflineVibeVoiceCoversEveryPartAndShortTailThroughThreeHours() async throws {
        for (duration, sourceType) in [(300_001, "import"), (600_007, "microphone"), (10_800_000, "import")] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let f = try offlineVibeVoice(root, duration: duration, sourceType: sourceType)
            let requests = Mutex<[ASRRequest]>([])
            let loads = Mutex(0)
            let factory = ASREngineFactory(loadWhisper: { _, _, _, _ in
                XCTFail("Must keep the pinned VibeVoice backend"); throw CancellationError()
            }, loadVibeVoice: { pinned, _, _, _ in
                XCTAssertEqual(pinned.fingerprint, f.info.profileHash)
                loads.withLock { $0 += 1 }
                return FixtureASREngine(modes: [.offline]) { request in
                    requests.withLock { $0.append(request) }
                    return ASRResult(segments: [Segment(id: "fake", startMs: request.coreRange.lowerBound,
                        endMs: request.coreRange.upperBound, text: "fixture \(request.coreRange.lowerBound)", language: "en")])
                }
            })
            let pipeline = try Pipeline(command: f.command, hardware: vibeVoiceHardware, engineFactory: factory) { _, _, _ in }
            let artifact = try await pipeline.perform()
            let ranges = stride(from: 0, to: duration, by: 300_000).map { $0..<min($0 + 300_000, duration) }
            let captured = requests.withLock { $0 }
            XCTAssertEqual(captured.map(\.coreRange), ranges)
            XCTAssertTrue(captured.allSatisfy { $0.availableEndMs == duration && $0.originMs == 0 && $0.mode == .offline })
            XCTAssertEqual(loads.withLock { $0 }, 1)
            let result = try Disk.read(Transcript.self, at: f.run.appendingPathComponent(artifact))
            XCTAssertEqual(result.segments.map { $0.startMs..<$0.endMs }, ranges)
            XCTAssertEqual(try f.repo.load(f.manifest.id).activeRunId, f.manifest.activeRunId)
            if duration == 10_800_000 {
                var bad = f.manifest
                bad.durationMs += 1
                try f.repo.save(bad)
                XCTAssertThrowsError(try Pipeline(command: f.command, hardware: vibeVoiceHardware, engineFactory: factory) { _, _, _ in })
                XCTAssertEqual(loads.withLock { $0 }, 1)
            }
        }
    }

    func testPreparedPCMDurationBoundsRequestsWithoutChangingCheckpointTimeline() async throws {
        for duration in [300_025, 300_125] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let f = try offlineVibeVoice(root, duration: duration, sourceType: "import")
            let audioEndMs = duration - 48
            let frames = Int64(audioEndMs * 16 - 1)
            let marker = f.run.appendingPathComponent("prepared.json")
            let wave = f.run.appendingPathComponent("work/audio.wav")
            try Disk.directory(wave.deletingLastPathComponent())
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
            buffer.frameLength = buffer.frameCapacity
            try XCTUnwrap(buffer.floatChannelData)[0].initialize(repeating: 0, count: Int(frames))
            do {
                let file = try AVAudioFile(forWriting: wave, settings: format.settings)
                try file.write(from: buffer)
            }
            let requests = Mutex<[ASRRequest]>([])
            let factory = ASREngineFactory(loadVibeVoice: { _, _, _, _ in
                FixtureASREngine(modes: [.offline]) { request in
                    requests.withLock { $0.append(request) }
                    return ASRResult(segments: [])
                }
            })
            let pipeline = try Pipeline(command: f.command, hardware: vibeVoiceHardware, engineFactory: factory) { _, _, _ in }
            try Disk.write(["fingerprint": f.info.fingerprint, "pcmFrames": String(frames + 1)], to: marker)
            do { _ = try await pipeline.perform(); XCTFail("Changed prepared frame count was accepted") }
            catch { XCTAssertTrue(error.localizedDescription.contains("Длительность подготовленного аудио")) }
            XCTAssertTrue(requests.withLock { $0.isEmpty })

            try Disk.write(["fingerprint": f.info.fingerprint, "pcmFrames": String(frames)], to: marker)
            _ = try await pipeline.perform()
            let captured = requests.withLock { $0 }
            let expected = audioEndMs < 300_000 ? [0..<audioEndMs] : [0..<300_000, 300_000..<audioEndMs]
            XCTAssertEqual(captured.map(\.coreRange), expected)
            XCTAssertTrue(captured.allSatisfy { $0.availableEndMs == audioEndMs })
            let tail = try Disk.read(ASRPart.self, at: f.run.appendingPathComponent("asr/part-1.json"))
            XCTAssertEqual(tail.startMs, 300_000)
            XCTAssertEqual(tail.endMs, duration)
            XCTAssertTrue(tail.segments.isEmpty)
        }
    }

    func testVibeVoiceResumesVerifiedPartAfterFailureOrCancellation() async throws {
        for cancel in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let f = try offlineVibeVoice(root, duration: 300_001, sourceType: "import")
            let original = f.repo.folder(f.manifest.id).appendingPathComponent(f.manifest.originalRelativePath)
            let part0 = f.run.appendingPathComponent("asr/part-0.json")
            let part1 = f.run.appendingPathComponent("asr/part-1.json")
            let transcript = f.run.appendingPathComponent("asr-transcript.json")
            let requests = Mutex<[Range<Int>]>([])
            let failing = ASREngineFactory(loadVibeVoice: { _, _, _, _ in
                FixtureASREngine(modes: [.offline]) { request in
                    if request.coreRange.lowerBound > 0 {
                        if cancel { withUnsafeCurrentTask { $0?.cancel() } }
                        else { throw ScribeError.message("Fixture generation failure") }
                    }
                    return ASRResult(segments: [])
                }
            })
            let pipeline = try Pipeline(command: f.command, hardware: vibeVoiceHardware, engineFactory: failing) { _, _, _ in }
            let task = Task { try await pipeline.perform() }
            do { _ = try await task.value; XCTFail("Expected failure") }
            catch { XCTAssertEqual(error is CancellationError, cancel) }
            let checkpoint = try Data(contentsOf: part0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: part1.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: transcript.path))
            XCTAssertEqual(try f.repo.resumeRun(f.manifest.id, catalog: f.catalog).id, f.info.id)
            let resuming = ASREngineFactory(loadVibeVoice: { _, _, _, _ in
                FixtureASREngine(modes: [.offline]) { request in
                    requests.withLock { $0.append(request.coreRange) }
                    return ASRResult(segments: [])
                }
            })
            let resumed = try Pipeline(command: f.command, hardware: vibeVoiceHardware, engineFactory: resuming) { _, _, _ in }
            _ = try await resumed.perform()
            XCTAssertEqual(requests.withLock { $0 }, [300_000..<300_001])
            XCTAssertEqual(try Data(contentsOf: part0), checkpoint)
            XCTAssertTrue(FileManager.default.fileExists(atPath: part1.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: transcript.path))
            let manifest = try f.repo.load(f.manifest.id)
            XCTAssertEqual(manifest.pendingRunId, f.info.id)
            XCTAssertEqual(manifest.activeRunId, f.manifest.activeRunId)
            XCTAssertEqual(try f.repo.results(manifest).0?.segments.map(\.text), ["Previous result"])
            XCTAssertEqual(try Disk.hash(original), f.manifest.sha256)
        }
    }

    func testOfflineAndClosedFragmentsUseSameFactoryAndResumeWithoutRewritingCheckpoints() async throws {
        for live in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let f = try fixture(root, live: live)
            let requests = Mutex<[ASRRequest]>([])
            let factory = ASREngineFactory(loadWhisper: { info, _, _, _ in
                XCTAssertEqual(info.modelIDs, f.info.modelIDs)
                return FixtureASREngine { request in
                    requests.withLock { $0.append(request) }
                    let start = request.coreRange.lowerBound + 10
                    return ASRResult(segments: [Segment(id: "temporary", startMs: start, endMs: start + 90,
                        text: "part \(request.coreRange.lowerBound)", language: "en")])
                }
            })
            let pipeline = try Pipeline(command: f.command, hardware: hardware, engineFactory: factory) { _, _, _ in }
            let artifact = try await pipeline.perform()
            let captured = requests.withLock { $0 }
            XCTAssertEqual(captured.map(\.mode), Array(repeating: live ? .closedFragments : .offline, count: live ? 3 : 2))
            XCTAssertEqual(captured.map(\.coreRange), live ? [0..<30000, 30000..<60000, 60000..<60125] : [0..<300000, 300000..<300125])
            XCTAssertEqual(captured.map(\.originMs), live ? [0, 20000, 50000] : [0, 0])
            XCTAssertEqual(captured.map(\.availableEndMs), live ? [31000, 60125, 60125] : [300125, 300125])
            let transcript = try Disk.read(Transcript.self, at: f.run.appendingPathComponent(artifact))
            XCTAssertEqual(transcript.segments.map(\.startMs), live ? [10, 30010, 60010] : [10, 300010])
            XCTAssertEqual(transcript.segments.map(\.text), live ? ["part 0", "part 30000", "part 60000"] : ["part 0", "part 300000"])
            XCTAssertTrue(transcript.segments.allSatisfy { $0.words.isEmpty })
            let checkpoints = captured.indices.map { f.run.appendingPathComponent("\(live ? "live" : "asr")/part-\($0).json") }
            let before = try checkpoints.map { try Data(contentsOf: $0) }
            requests.withLock { $0.removeAll() }
            _ = try await pipeline.perform()
            XCTAssertTrue(requests.withLock { $0.isEmpty })
            XCTAssertEqual(try checkpoints.map { try Data(contentsOf: $0) }, before)
            let metrics = try Disk.read(ASRMetrics.self, at: f.run.appendingPathComponent("metrics-asr.json"))
            XCTAssertEqual(metrics.checkpointHits, live ? 3 : 2)
            XCTAssertEqual(metrics.checkpointAudioMs, f.manifest.durationMs)
        }
    }

    func testFailureOrNormalReturnAfterCancellationCannotCommitNextPartInEitherPath() async throws {
        for live in [false, true] {
            for cancel in [false, true] {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: root) }
                let f = try fixture(root, live: live)
                let factory = ASREngineFactory(loadWhisper: { _, _, _, _ in
                    FixtureASREngine { request in
                        if request.coreRange.lowerBound > 0 {
                            if cancel { withUnsafeCurrentTask { $0?.cancel() } }
                            else { throw ScribeError.message("fixture model failure") }
                        }
                        return ASRResult(segments: [])
                    }
                })
                let pipeline = try Pipeline(command: f.command, hardware: hardware, engineFactory: factory) { _, _, _ in }
                let task = Task { try await pipeline.perform() }
                do { _ = try await task.value; XCTFail("Expected failure") }
                catch { XCTAssertEqual(error is CancellationError, cancel) }
                let prefix = live ? "live" : "asr"
                XCTAssertTrue(FileManager.default.fileExists(atPath: f.run.appendingPathComponent("\(prefix)/part-0.json").path))
                XCTAssertFalse(FileManager.default.fileExists(atPath: f.run.appendingPathComponent("\(prefix)/part-1.json").path))
                XCTAssertFalse(FileManager.default.fileExists(atPath: f.run.appendingPathComponent("\(prefix)-transcript.json").path))
                XCTAssertEqual(try f.repo.load(f.manifest.id).pendingRunId, f.info.id)
            }
        }
    }

    func testUnsupportedModeAndCancellationBeforeCallDoNotEnterEngine() async throws {
        let request = try ASRRequest(audioURL: URL(fileURLWithPath: "/unused.wav"), availableEndMs: 90000,
            coreRange: 0..<90000, mode: .closedFragments)
        let engine = FixtureASREngine(modes: [.offline]) { _ in XCTFail("Unexpected inference"); return ASRResult(segments: []) }
        do { _ = try await SpeechRecognizer(engine: engine).recognize(request); XCTFail("Unsupported mode") }
        catch { XCTAssertTrue(error is ScribeError) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SpeechRecognizer(engine: FixtureASREngine { _ in
                XCTFail("Cancelled before call"); return ASRResult(segments: [])
            }).recognize(request)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
    }

    func testFactoryRejectsUnknownBackendAndChangedPinnedIdentityBeforeLoading() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let f = try fixture(root, live: false)
        let factory = ASREngineFactory(loadWhisper: { _, _, _, _ in XCTFail("Must not load Whisper"); throw CancellationError() })
        var catalog = f.catalog
        catalog.models[0].asrBackend = "future-engine"
        for matchedHash in [false, true] {
            var info = f.info
            if matchedHash { info.profileHash = catalog.fingerprint }
            do {
                _ = try await factory.make(info: info, catalog: catalog, models: f.repo.models, metrics: nil, warning: { _ in })
                XCTFail("Unsupported or changed backend accepted")
            } catch { XCTAssertTrue(error is ScribeError) }
        }
    }

    func testFactoryRejectsSubstitutedWhisperWeightsBeforeLoading() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let f = try fixture(root, live: false)
        // Same length, one substituted byte: only the SHA-256 check can catch it.
        try Data("whisper fixture weightT".utf8).write(to: f.repo.models.appendingPathComponent("asr/weights"))
        let factory = ASREngineFactory(loadWhisper: { _, _, _, _ in
            XCTFail("Substituted weights must fail validation before loading"); throw CancellationError()
        })
        do {
            _ = try await factory.make(info: f.info, catalog: f.catalog, models: f.repo.models, metrics: nil, warning: { _ in })
            XCTFail("Substituted Whisper weights accepted")
        } catch { XCTAssertTrue(error is ScribeError) }
    }

    func testPipelineValidatesDiarizationWeightsBeforeSpeakerKit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let f = try fixture(root, live: false)
        try Data("whisper fixture weightT".utf8).write(to: f.repo.models.appendingPathComponent("diarization/weights"))
        var command = f.command
        command.stage = .diarizing
        let pipeline = try Pipeline(command: command, hardware: hardware) { _, _, _ in }
        // The fixture has no transcript checkpoint: validation must fail first.
        do {
            _ = try await pipeline.perform()
            XCTFail("Substituted diarization weights accepted")
        } catch { XCTAssertTrue(error is ScribeError) }
    }
}
