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
    }

    func testOfflineInputOnly() async throws {
        let engine = VibeVoiceASREngine(generate: { _ in XCTFail("Unexpected live inference"); return "[]" })
        do {
            _ = try await engine.recognize(ASRRequest(audioURL: URL(fileURLWithPath: "/missing.wav"),
                availableEndMs: 1_000, coreRange: 0..<1_000, mode: .closedFragments))
            XCTFail("Closed fragments accepted")
        } catch { XCTAssertTrue(error.localizedDescription.contains("только готовые записи")) }
    }

    func testTokenLimitSplitsOnlyFailedWindowsAndKeepsSeamOwnership() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let request = try retryRequest(in: root)
        let responses: [String?] = [
            nil,
            nil,
            #"[{"Start":19.5,"End":20.5,"Content":"Inner seam"}]"#,
            #"[{"Start":4.5,"End":5.5,"Content":"Inner seam"},{"Start":19.5,"End":20.5,"Content":"Outer seam"}]"#,
            #"[{"Start":4.5,"End":5.5,"Content":"Outer seam"}]"#
        ]
        var inputFrames: [Int] = []
        let engine = VibeVoiceASREngine { audio in
            let call = inputFrames.count
            inputFrames.append(audio.count)
            guard responses.indices.contains(call) else {
                XCTFail("Unexpected model call")
                return "[]"
            }
            guard let response = responses[call] else { throw VibeVoiceError.incompleteGeneration }
            return response
        }

        let result = try await engine.recognize(request)
        XCTAssertEqual(inputFrames, [70, 40, 25, 25, 40].map { $0 * 24_000 })
        XCTAssertEqual(result.segments.map(\.text), ["Inner seam", "Outer seam"])
        XCTAssertEqual(result.segments.map(\.startMs), [119_500, 134_500])
        XCTAssertEqual(result.segments.map(\.endMs), [120_500, 135_500])
        XCTAssertEqual(result.segments.map(\.id), ["vibe-0", "vibe-1"])
    }

    func testFifteenSecondWindowRetriesWithLessContext() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try retryRequest(in: root)
        let request = try ASRRequest(audioURL: fixture.audioURL, originMs: fixture.originMs,
            availableEndMs: fixture.availableEndMs, coreRange: 105_000..<120_000, mode: .offline)
        var inputFrames: [Int] = []
        let engine = VibeVoiceASREngine { audio in
            inputFrames.append(audio.count)
            switch inputFrames.count {
            case 1: throw VibeVoiceError.incompleteGeneration
            case 2: return #"[{"Start":8,"End":9,"Content":"Seam"}]"#
            case 3: return #"[{"Start":0.5,"End":1.5,"Content":"Seam"}]"#
            default:
                XCTFail("Unexpected model call")
                return "[]"
            }
        }

        let result = try await engine.recognize(request)
        XCTAssertEqual(inputFrames, [600_000, 228_000, 228_000])
        XCTAssertEqual(result.segments.map(\.text), ["Seam"])
        XCTAssertEqual(result.segments.map(\.startMs), [112_000])
        XCTAssertEqual(result.segments.map(\.endMs), [113_000])
    }

    func testPersistentTokenLimitReportsSmallestFailedRangeWithoutReturningPartialResult() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let request = try retryRequest(in: root)
        var inputFrames: [Int] = []
        let engine = VibeVoiceASREngine { audio in
            inputFrames.append(audio.count)
            if inputFrames.count == 2 { return #"[{"Start":6,"End":7,"Content":"Recognized first half"}]"# }
            throw VibeVoiceError.incompleteGeneration
        }

        do {
            _ = try await engine.recognize(request)
            XCTFail("Incomplete recognition returned a result")
        } catch {
            XCTAssertEqual(error.localizedDescription,
                "VibeVoice исчерпал лимит генерации на участке 00:02:15.000–00:02:18.750 (8192 токена). Расшифровка этой части не сохранена.")
        }
        XCTAssertEqual(inputFrames, [1_680_000, 960_000, 960_000, 600_000, 228_000, 138_000])
    }

    private func retryRequest(in root: URL) throws -> ASRRequest {
        try Disk.directory(root)
        let wave = root.appendingPathComponent("retry.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 70 * 16_000))
        buffer.frameLength = buffer.frameCapacity
        try XCTUnwrap(buffer.floatChannelData)[0].initialize(repeating: 0, count: Int(buffer.frameLength))
        do {
            let file = try AVAudioFile(forWriting: wave, settings: format.settings)
            try file.write(from: buffer)
        }
        return try ASRRequest(audioURL: wave, originMs: 100_000, availableEndMs: 170_000,
            coreRange: 105_000..<165_000, mode: .offline)
    }

    func testSpeechAtBothSeamsAndOneMillisecondTailUsesBoundedAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Disk.directory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let wave = root.appendingPathComponent("ranges.wav")
        let origin = 239_000, duration = 300_001
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let frameCount = (duration - origin) * 16
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)))
        buffer.frameLength = buffer.frameCapacity
        let channel = try XCTUnwrap(buffer.floatChannelData)[0]
        for frame in 0..<frameCount {
            switch origin + frame / 16 {
            case ..<294_000: channel[frame] = 0.125
            case ..<295_000: channel[frame] = 0.25
            case ..<300_000: channel[frame] = 0.375
            default: channel[frame] = 0.875
            }
        }
        do {
            let file = try AVAudioFile(forWriting: wave, settings: format.settings)
            try file.write(from: buffer)
        }
        let fakeOutputs = [
            #"[{"Start":59.95,"End":60.1,"Content":"Interior seam"}]"#,
            #"[{"Start":4.95,"End":5.1,"Content":"Interior seam"},{"Start":5.9997,"End":6.0007,"Content":"Checkpoint seam"}]"#,
            #"[{"Start":3.95,"End":4.1,"Content":"Interior seam"},{"Start":4.9997,"End":5.0007,"Content":"Checkpoint seam"},{"Start":5.0008,"End":5.00095,"Content":"Tail"}]"#
        ]
        let expectedDurations = [61_001, 6_001, 5_001]
        let firstLevel: [Float] = [0.125, 0.25, 0.375]
        var call = 0
        let engine = VibeVoiceASREngine { audio in
            guard fakeOutputs.indices.contains(call) else {
                XCTFail("Unexpected model call")
                return "[]"
            }
            XCTAssertEqual(audio.count, expectedDurations[call] * 24)
            XCTAssertEqual(audio[2400], firstLevel[call], accuracy: 0.005)
            XCTAssertGreaterThan(audio.suffix(24).max() ?? 0, 0.8)
            defer { call += 1 }
            return fakeOutputs[call]
        }
        let first = try await engine.recognize(ASRRequest(audioURL: wave, originMs: origin, availableEndMs: duration,
            coreRange: origin..<300_000, mode: .offline))
        let second = try await engine.recognize(ASRRequest(audioURL: wave, originMs: origin, availableEndMs: duration,
            coreRange: 300_000..<duration, mode: .offline))
        XCTAssertEqual(call, 3)
        XCTAssertEqual(first.segments.map(\.text), ["Interior seam"])
        XCTAssertEqual(second.segments.map(\.text), ["Checkpoint seam", "Tail"])
        XCTAssertEqual(first.segments.map(\.startMs), [298_950])
        XCTAssertEqual(first.segments.map(\.endMs), [299_100])
        XCTAssertEqual(second.segments.map(\.startMs), [300_000, 300_001])
        XCTAssertEqual(second.segments.map(\.endMs), [300_001, 300_001])
        XCTAssertTrue((first.segments + second.segments).allSatisfy { $0.speakerId == nil && $0.words.isEmpty })
    }

    func testResamplingKeepsDurationAndDoesNotShiftImpulse() throws {
        var input = [Float](repeating: 0, count: 16_000)
        input[8000] = 0.8
        let output = try VibeVoiceASREngine.resample(input)
        XCTAssertEqual(output.count, 24_000)
        let peak = try XCTUnwrap(output.indices.max { abs(output[$0]) < abs(output[$1]) })
        XCTAssertLessThanOrEqual(abs(peak - 12_000), 2)
    }
    func testLocalOfflinePipeline() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let library = env["LOCALSCRIBE_VIBEVOICE_LIBRARY"], let wavePath = env["LOCALSCRIBE_VIBEVOICE_WAV"] else {
            throw XCTSkip("Set LOCALSCRIBE_VIBEVOICE_LIBRARY to the installed model library and LOCALSCRIBE_VIBEVOICE_WAV to mono PCM16 / 16 kHz technical audio longer than five minutes. Deny network for the test process.")
        }
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let toolsSource = env["LOCALSCRIBE_VIBEVOICE_TOOLS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? sourceRoot.appendingPathComponent("Assets/tools")
        let catalog = try Disk.read(ModelCatalog.self, at: sourceRoot.appendingPathComponent("Resources/models.lock.json"))
        let selected = ModelCatalog(models: try ["asr-vibevoice-4bit", "diarization", "summary", "tokenizer-vibevoice"].map { id in
            try XCTUnwrap(catalog.models.first { $0.id == id })
        })
        let hardware = ModelHardware.current
        for profile in selected.models where profile.purpose == .asr || profile.purpose == .diarization {
            try hardware.requireCompatibility(for: profile)
        }

        let wave = URL(fileURLWithPath: wavePath)
        let file = try AVAudioFile(forReading: wave)
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        XCTAssertEqual(file.fileFormat.commonFormat, .pcmFormatInt16)
        let models = URL(fileURLWithPath: library)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root.appendingPathComponent("archive"))
        let resources = root.appendingPathComponent("Resources")
        let tools = resources.appendingPathComponent("tools")
        try Disk.write(catalog, to: resources.appendingPathComponent("models.lock.json"))
        try FileManager.default.createSymbolicLink(at: tools, withDestinationURL: toolsSource)
        var manifest = try repo.importFile(wave, info: Media.probe(wave, tools: tools),
            verifyAudio: { try Media.probe($0, tools: tools) })
        XCTAssertGreaterThan(manifest.durationMs, 300_000)
        let original = repo.folder(manifest.id).appendingPathComponent(manifest.originalRelativePath)
        let info = try repo.beginRun(&manifest, catalog: selected)
        let run = repo.run(manifest.id, info.id)
        let started = ProcessInfo.processInfo.systemUptime
        var stageSeconds: [String: Double] = [:]
        var asrMLXPeak = 0
        for stage in [Stage.preparingAudio, .transcribing, .diarizing] {
            let command = WorkerCommand(jobId: manifest.id, runId: info.id, stage: stage,
                recordingPath: repo.folder(manifest.id).path, modelsPath: models.path, toolsPath: tools.path)
            let pipeline = try Pipeline(command: command, hardware: hardware) { type, message, _ in
                if type == "progress" { print(message) }
            }
            let stageStart = ProcessInfo.processInfo.systemUptime
            _ = try await pipeline.perform()
            stageSeconds[stage.rawValue] = ProcessInfo.processInfo.systemUptime - stageStart
            if stage == .transcribing { asrMLXPeak = Memory.peakMemory }
        }
        let wall = ProcessInfo.processInfo.systemUptime - started
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let transcript = try Disk.read(Transcript.self, at: run.appendingPathComponent("transcript.json"))
        XCTAssertEqual(transcript.fingerprint, info.fingerprint)
        XCTAssertTrue(transcript.diarized)
        XCTAssertTrue(transcript.segments.contains { $0.speakerId != nil })
        try transcript.validate(durationMs: manifest.durationMs)
        let partMs = ASRCheckpointLayout.offlinePartMs
        let parts = try stride(from: 0, to: manifest.durationMs, by: partMs).enumerated().map { index, start in
            let saved = try Disk.read(ASRPart.self, at: run.appendingPathComponent("asr/part-\(index).json"))
            XCTAssertEqual(saved.fingerprint, info.fingerprint)
            XCTAssertEqual(saved.index, index)
            XCTAssertEqual(saved.startMs, start)
            XCTAssertEqual(saved.endMs, min(start + partMs, manifest.durationMs))
            return saved
        }
        XCTAssertEqual(try Disk.hash(original), manifest.sha256)
        let measurement = ["durationMs": Double(manifest.durationMs), "wallSeconds": wall,
            "preparingAudioSeconds": stageSeconds[Stage.preparingAudio.rawValue] ?? 0,
            "transcribingSeconds": stageSeconds[Stage.transcribing.rawValue] ?? 0,
            "diarizingSeconds": stageSeconds[Stage.diarizing.rawValue] ?? 0,
            "asrMLXPeakBytes": Double(asrMLXPeak), "maxResidentBytes": Double(usage.ru_maxrss),
            "parts": Double(parts.count), "segments": Double(transcript.segments.count)]
        print("asr-vibevoice-4bit · \(hardware.chip) · \(hardware.memoryBytes) bytes RAM · \(measurement)")
        if let path = env["LOCALSCRIBE_VIBEVOICE_OUTPUT"] {
            let output = URL(fileURLWithPath: path)
            try Disk.write(measurement, to: output.appendingPathComponent("measurement.json"))
            try Disk.write(transcript, to: output.appendingPathComponent("transcript.json"))
        }
    }
}
