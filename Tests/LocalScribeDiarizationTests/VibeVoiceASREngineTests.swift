import XCTest
import AVFoundation
import MLX
@testable import LocalScribeCore
@testable import LocalScribeWorker
import LocalScribeVibeVoice

final class VibeVoiceASREngineTests: XCTestCase {
    func testSegmentTimesAreNotWordTimesOrGlobalSpeakers() throws {
        let text = #"[{"Start time":0.2,"End time":0.9,"Speaker ID":8,"Content":"Hello"},{"Start time":0.8,"End time":1.5,"Speaker ID":1,"Content":"Привет"}]"#
        let result = try VibeVoiceASREngine.parse(text, durationMs: 2000)
        XCTAssertEqual(result.map(\.startMs), [200, 800])
        XCTAssertTrue(result.allSatisfy { $0.words.isEmpty && $0.speakerId == nil })
        XCTAssertEqual(result.map(\.language), ["en", "ru"])
        let aliases = try VibeVoiceASREngine.parse(#"[{"Start":0.2,"End":0.9,"Speaker":9,"Content":"Hello"}]"#, durationMs: 2000)
        XCTAssertEqual(aliases.first?.startMs, 200)
    }
    func testStreamingCheckpointRejectedBeforeWeightAllocation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Disk.directory(root); defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"chunk_frames":22,"lookahead_frames":4}"#.utf8).write(to: root.appendingPathComponent("config.json"))
        XCTAssertThrowsError(try VibeVoiceASRModel.fromModelDirectory(root, tokenizerDirectory: root, weightFiles: ["model.safetensors"])) {
            guard case VibeVoiceError.configuration(let reason) = $0 else { return XCTFail("wrong error") }
            XCTAssertTrue(reason.contains("long-form"))
        }
    }

    func testFactorySelectsPinnedVibeVoiceWithoutWhisperOrQwen() async throws {
        var profiles = ModelRole.audioRoles.map { ModelProfile(id: $0.rawValue, repository: "fixture/local", revision: "r", license: "test", files: [], role: $0) }
        profiles[0].asrBackend = "vibevoice-asr"; profiles[0].asrPolicy = VibeVoiceASREngine.policyID
        profiles[0].tokenizerID = "tokenizer"
        let catalog = ModelCatalog(models: profiles)
        let factory = ASREngineFactory(loadWhisper: { _, _, _, _ in XCTFail("wrong Whisper backend"); throw CancellationError() },
            loadQwen: { _, _, _, _ in XCTFail("wrong Qwen backend"); throw CancellationError() },
            loadVibeVoice: { _, _, _, _ in VibeVoiceASREngine(generate: { _ in "[]" }) })
        let recognizer = try await factory.make(info: RunInfo(sourceHash: "source", profileHash: catalog.fingerprint),
            catalog: catalog, models: URL(fileURLWithPath: "/missing"), metrics: nil, warning: { _ in })
        XCTAssertEqual(recognizer.capabilities.inputModes, [.offline])
        XCTAssertEqual(recognizer.capabilities.wordTimings, .unavailable)
    }

    func testInvalidRowRejectsWholeOutput() {
        for response in [#"[{"Start time":0.2,"Start":0.5,"End":1,"Content":"bad"}]"#,#"[{"Start time":0,"End time":1,"Content":"valid"},{}]"#,
                         #"[{"Start time":1,"End time":0,"Content":"bad"}]"#,
                         #"[{"Start time":0,"End time":3,"Content":"bad"}]"#,
                         #"[{"Start time":0,"End time":1,"Content":""}]"#,
                         #"[{"Start time":true,"End time":1,"Content":"bad"}]"#,
                         #"prefix [{"Start time":0,"End time":1,"Content":"bad"}]"#] {
            XCTAssertThrowsError(try VibeVoiceASREngine.parse(response, durationMs: 2000))
        }
        XCTAssertThrowsError(try VibeVoiceASREngine.requireDuration(300_001))
        XCTAssertNoThrow(try VibeVoiceASREngine.requireDuration(300_000))
    }
    func testLongAudioRejectedBeforeFileReadOrModelCall() async throws {
        let engine = VibeVoiceASREngine(generate: { _ in XCTFail("long audio entered SDK"); return "[]" })
        do {
            _ = try await engine.recognize(ASRRequest(audioURL: URL(fileURLWithPath: "/missing.wav"),
                availableEndMs: 301_000, coreRange: 0..<301_000, mode: .offline))
            XCTFail("recording was silently truncated")
        } catch { XCTAssertTrue(error.localizedDescription.contains("5 минут")) }
    }
    func testResamplingKeepsDurationAndDoesNotShiftImpulse() throws {
        var input = [Float](repeating: 0, count: 16_000)
        input[8000] = 0.8
        let output = try VibeVoiceASREngine.resample(input)
        XCTAssertEqual(output.count, 24_000)
        let peak = try XCTUnwrap(output.indices.max { abs(output[$0]) < abs(output[$1]) })
        XCTAssertLessThanOrEqual(abs(peak - 12_000), 2)
    }
    func testLocalLongFormCheckpoint() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let directory = env["LOCALSCRIBE_VIBEVOICE_MODEL"], let tokenizer = env["LOCALSCRIBE_VIBEVOICE_TOKENIZER"],
              let wave = env["LOCALSCRIBE_VIBEVOICE_WAV"] else {
            throw XCTSkip("Set LOCALSCRIBE_VIBEVOICE_MODEL, LOCALSCRIBE_VIBEVOICE_TOKENIZER and LOCALSCRIBE_VIBEVOICE_WAV to verified local long-form ASR weights, Qwen2.5 tokenizer and mono/16 kHz technical audio; deny network")
        }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: wave))
        XCTAssertEqual(file.processingFormat.sampleRate, 16000); XCTAssertEqual(file.processingFormat.channelCount, 1)
        let duration = Int((Double(file.length) / 16).rounded())
        try VibeVoiceASREngine.requireDuration(duration)
        let started = ProcessInfo.processInfo.systemUptime
        let recognizer: SpeechRecognizer
        if let library = env["LOCALSCRIBE_VIBEVOICE_LIBRARY"] {
            let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let catalog = try Disk.read(ModelCatalog.self, at: sourceRoot.appendingPathComponent("Resources/models.lock.json"))
            let selected = ModelCatalog(models: try ["asr-vibevoice-4bit", "diarization", "summary", "tokenizer-vibevoice"].map { id in
                try XCTUnwrap(catalog.models.first { $0.id == id })
            })
            var info = RunInfo(sourceHash: try Disk.hash(URL(fileURLWithPath: wave)), profileHash: selected.fingerprint)
            info.modelIDs = Dictionary(uniqueKeysWithValues: selected.models.map { ($0.purpose!.rawValue, $0.id) })
            // Technical short fixture exercises the factory on the available Mac.
            // The app's 32 GiB / full-context admission policy is tested separately.
            recognizer = try await ASREngineFactory().make(info: info, catalog: catalog, models: URL(fileURLWithPath: library), metrics: nil, warning: { _ in })
        } else {
            recognizer = SpeechRecognizer(engine: try VibeVoiceASREngine(model: URL(fileURLWithPath: directory), tokenizer: URL(fileURLWithPath: tokenizer),
                weightFiles: ["model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors"]))
        }
        let loaded = ProcessInfo.processInfo.systemUptime
        let result = try await recognizer.recognize(ASRRequest(audioURL: URL(fileURLWithPath: wave), availableEndMs: duration,
            coreRange: 0..<duration, mode: .offline))
        XCTAssertFalse(result.segments.isEmpty)
        try Transcript(fingerprint: "technical", diarized: false, segments: result.segments).validate(durationMs: duration)
        if let path = env["LOCALSCRIBE_VIBEVOICE_OUTPUT"] {
            let output = URL(fileURLWithPath: path)
            try Disk.write(["loadSeconds": loaded-started, "seconds": ProcessInfo.processInfo.systemUptime-loaded,
                            "mlxPeakBytes": Double(Memory.peakMemory), "segments": Double(result.segments.count)], to: output.appendingPathComponent("measurement.json"))
            try Disk.write(Transcript(fingerprint: "technical", diarized: false, segments: result.segments), to: output.appendingPathComponent("transcript.json"))
        }
    }
}
