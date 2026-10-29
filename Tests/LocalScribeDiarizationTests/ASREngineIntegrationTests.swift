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
        let catalog = ModelCatalog(models: ModelRole.allCases.map {
            ModelProfile(id: $0.rawValue, repository: "fixture/model", revision: "fixed", license: "test", files: [], role: $0)
        })
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
}
