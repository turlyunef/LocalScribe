import XCTest
import AVFoundation
import CWorkerIsolation
import LocalScribeCore
import WhisperKit
@testable import LocalScribeWorker

/// Session 3 only: explicit artifacts, frozen A windows/call inputs, no archive writes.
final class ASRSettingsProbeTests: XCTestCase {
    struct Source: Codable {
        var id: String
        var wavePath: String
        var waveHash: String
        var durationMs: Int
        var intervals: [Interval]
    }
    struct Interval: Codable { var startMs: Int; var endMs: Int }
    struct Window: Codable, Equatable {
        var sourceID: String
        var startMs: Int
        var endMs: Int
        var readStartMs: Int
        var readEndMs: Int
    }
    struct Input: Codable {
        var sourceType: String
        var modelsPath: String
        var run: RunInfo
        var catalog: ModelCatalog
        var sources: [Source]
        var lexicon: String
    }
    struct Call: Codable {
        var phase: String
        var startMs: Int
        var endMs: Int
        var ownedEndMs: Int
        var results: [TranscriptionResult]
    }
    struct Output: Codable {
        var window: Window
        var calls: [Call]
        var segments: [Segment]
        var preserved: [Segment]
    }
    struct LanguageCheck: Codable {
        var window: Int
        var call: Int
        var language: String
        var seconds: Double
        var fallbackToAutodetect: Bool
    }

    static func options(_ label: String, prompt: [Int]) -> DecodingOptions {
        var options = SpeechRecognizer.decodingOptions
        switch label {
        case "noSpeech": options.noSpeechThreshold = nil
        case "logprob": options.logProbThreshold = -1.5
        case "compression": options.compressionRatioThreshold = 3.0
        case "lexicon": options.promptTokens = prompt
        default: break
        }
        return options
    }

    // Replay only: use the production ownership mapper without allowing global
    // decoding scores to delete text. Restore uncertainty from the original scores.
    static func preserve(_ results: [TranscriptionResult], mapper: SpeechRecognizer,
                         readStart: Int, start: Int, end: Int, duration: Int) -> [Segment] {
        results.flatMap { result in
            result.segments.flatMap { raw -> [Segment] in
                var copy = raw
                copy.avgLogprob = max(-1, copy.avgLogprob)
                copy.noSpeechProb = min(0.6, copy.noSpeechProb)
                copy.compressionRatio = min(2.4, copy.compressionRatio)
                let single = TranscriptionResult(text: raw.text, segments: [copy], language: result.language, timings: .init())
                var mapped = mapper.mappedSegments([single], readStart: readStart, start: start, end: end, durationMs: duration)
                for index in mapped.indices {
                    mapped[index].uncertain = raw.avgLogprob < -1 || raw.noSpeechProb > 0.6 || raw.compressionRatio > 2.4
                }
                return mapped
            }
        }
    }

    func testGlobalConfidenceReplayKeepsOriginalWordsAndUncertainty() throws {
        let mapper = SpeechRecognizer { _, _ in [] }
        let raw = TranscriptionSegment(id: 0, start: 1, end: 2, text: "private test",
            avgLogprob: -1.2, compressionRatio: 3.7, noSpeechProb: 0.8,
            words: [WordTiming(word: "private test", tokens: [], start: 1, end: 2, probability: 0.8)])
        let results = [TranscriptionResult(text: raw.text, segments: [raw], language: "en", timings: .init())]
        XCTAssertTrue(mapper.mappedSegments(results, readStart: 0, start: 0, end: 3000, durationMs: 3000).isEmpty)
        let kept = Self.preserve(results, mapper: mapper, readStart: 0, start: 0, end: 3000, duration: 3000)
        XCTAssertEqual(kept.first?.text, raw.text)
        XCTAssertEqual(kept.first?.uncertain, true)
        XCTAssertEqual(kept.first?.words.first?.startMs, 1000)
        XCTAssertEqual(results.first?.segments.first, raw)
        XCTAssertTrue(Self.preserve(results, mapper: mapper, readStart: 0, start: 2500, end: 3000, duration: 3000).isEmpty)
    }

    func testExplicitSettingsProbe() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["LOCALSCRIBE_ASR_SETTINGS_PROBE"] == "technical-probe",
              let rootPath = env["LOCALSCRIBE_ASR_MATRIX_OUTPUT"],
              let label = env["LOCALSCRIBE_ASR_SETTINGS_VARIANT"],
              ["plan", "baseline", "baseline-repeat", "language", "language-repeat", "noSpeech", "logprob", "compression", "lexicon", "lexicon-repeat", "retry"].contains(label) else {
            throw XCTSkip("Use scripts/probe_asr_settings.py with a fresh technical output directory")
        }
        let root = URL(fileURLWithPath: rootPath)
        do {
            guard localscribe_deny_network() == 0 else { throw ScribeError.message("Не удалось запретить сеть") }
            let input = try Disk.read(Input.self, at: root.appendingPathComponent("settings-input.json"))
            guard input.sourceType == "technical-probe" else { throw ScribeError.message("Нужен технический вход") }
            let models = URL(fileURLWithPath: input.modelsPath)
            let pinned = try input.catalog.pinned(to: input.run)
            for model in pinned.models where model.purpose == .asr || model.purpose == .tokenizer { try model.validate(at: models) }
            var windows: [Window] = []
            for source in input.sources {
                let wave = URL(fileURLWithPath: source.wavePath), file = try AVAudioFile(forReading: wave)
                guard try Disk.hash(wave) == source.waveHash, file.processingFormat.sampleRate == 16000,
                      file.processingFormat.channelCount == 1, Int((Double(file.length) / 16).rounded()) == source.durationMs else {
                    throw ScribeError.message("Изменился вход")
                }
                for partStart in stride(from: 0, to: source.durationMs, by: 300_000) {
                    let partEnd = min(source.durationMs, partStart + 300_000)
                    var offset = partStart
                    while offset < partEnd {
                        let samples = try Media.samples(wave, start: Double(offset) / 1000,
                            duration: Double(min(partEnd - offset, Analysis.asrCoreWindowMs)) / 1000)
                        let end = min(partEnd, offset + max(1, Analysis.nextASRWindowLength(samples, policy: .firstPause) / 16))
                        if source.intervals.contains(where: { $0.startMs < end && offset < $0.endMs }) {
                            windows.append(Window(sourceID: source.id, startMs: offset, endMs: end,
                                readStartMs: max(0, offset - 1000), readEndMs: min(source.durationMs, end + 1000)))
                        }
                        offset = end
                    }
                }
            }
            let planPath = root.appendingPathComponent("settings-plan.json")
            if label == "plan" {
                guard !FileManager.default.fileExists(atPath: planPath.path) else { throw ScribeError.message("План уже существует") }
                try Disk.write(windows, to: planPath)
                return
            }
            guard try Disk.read([Window].self, at: planPath) == windows else { throw ScribeError.message("Изменился план") }
            let destination = root.appendingPathComponent(label)
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw ScribeError.message("Нужен новый результат") }
            try Disk.directory(destination)
            let recorder = ASRMetricsRecorder(run: destination, liveCapture: false, windowPolicy: "frozen-A-settings")
            let thermalBefore = ProcessInfo.processInfo.thermalState.rawValue
            let started = ProcessInfo.processInfo.systemUptime
            let kit = try await WhisperKit(WhisperKitConfig(modelFolder: models.appendingPathComponent(try input.run.modelID(for: .asr)).path,
                tokenizerFolder: models.appendingPathComponent(try input.run.modelID(for: .tokenizer)), verbose: false,
                logLevel: .none, prewarm: true, load: true, download: false))
            recorder.modelLoaded(seconds: ProcessInfo.processInfo.systemUptime - started)
            let tokenizer = try XCTUnwrap(kit.tokenizer)
            // Pinned tokenizer.encode includes BOS/EOS; TextDecoder also removes
            // special tokens from promptTokens. Keep only text and verify round trip.
            let prompt = tokenizer.encode(text: input.lexicon).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            guard !prompt.isEmpty, prompt.count <= 64,
                  tokenizer.decode(tokens: prompt).trimmingCharacters(in: .whitespacesAndNewlines)
                    == input.lexicon.trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw ScribeError.message("Слишком длинная подсказка")
            }
            let factor = label.replacingOccurrences(of: "-repeat", with: "")
            let baseOptions = Self.options(factor, prompt: prompt)
            try Disk.write(baseOptions, to: destination.appendingPathComponent("decoding-options.json"))
            try Disk.write(prompt, to: destination.appendingPathComponent("lexicon-tokens.json"))
            var checks: [LanguageCheck] = []
            let mapper = SpeechRecognizer { _, _ in [] }
            for (index, window) in windows.enumerated() {
                try Task.checkCancellation()
                recorder.window(milliseconds: window.endMs - window.startMs, silent: false)
                let source = try XCTUnwrap(input.sources.first { $0.id == window.sourceID })
                let wave = URL(fileURLWithPath: source.wavePath)
                let baselinePath = root.appendingPathComponent("baseline/windows/\(index).json")
                var calls: [Call]
                if label == "baseline" {
                    calls = [Call(phase: "primary", startMs: window.readStartMs, endMs: window.readEndMs,
                        ownedEndMs: window.endMs, results: [])]
                } else {
                    let baseline = try Disk.read(Output.self, at: baselinePath)
                    guard baseline.window == window else { throw ScribeError.message("Изменился baseline") }
                    calls = baseline.calls.map { Call(phase: $0.phase, startMs: $0.startMs, endMs: $0.endMs, ownedEndMs: $0.ownedEndMs, results: []) }
                    if factor == "retry" {
                        // One extra real-context call only before destructive app filtering.
                        let destructive = baseline.calls.contains { $0.results.contains { $0.segments.contains {
                            ($0.noSpeechProb > 0.6 && $0.avgLogprob < -1) || $0.compressionRatio > 3.5
                        } } }
                        if !destructive { continue }
                        let retryEnd = min(source.durationMs, window.readStartMs + 30_000)
                        let retryStart = max(0, retryEnd - 30_000)
                        if baseline.calls.contains(where: { $0.startMs == retryStart && $0.endMs == retryEnd }) { continue }
                        calls = [Call(phase: "contextReview", startMs: retryStart, endMs: retryEnd, ownedEndMs: window.endMs, results: [])]
                    }
                }
                var segments: [Segment] = [], preserved: [Segment] = []
                var callIndex = 0
                while callIndex < calls.count {
                    var call = calls[callIndex]
                    let samples = try Media.samples(wave, start: Double(call.startMs) / 1000, duration: Double(call.endMs - call.startMs) / 1000)
                    var options = baseOptions
                    if factor == "language" {
                        let lidStart = ProcessInfo.processInfo.systemUptime
                        let detected = try await kit.detectLangauge(audioArray: samples)
                        // Language ID is audio-based. Never infer English from Latin characters.
                        let fallback = detected.language != "ru"
                        if !fallback { options.language = "ru"; options.detectLanguage = false }
                        checks.append(LanguageCheck(window: index, call: callIndex, language: detected.language,
                            seconds: ProcessInfo.processInfo.systemUptime - lidStart, fallbackToAutodetect: fallback))
                    }
                    try Disk.write(options, to: destination.appendingPathComponent("call-options/\(index)-\(callIndex).json"))
                    let phase: ASRCallPhase = call.phase == "primary" ? .primary : call.phase == "prefixRecovery" ? .prefixRecovery : .contextReview
                    recorder.startCall(samples: samples.count, phase: phase)
                    let callStart = ProcessInfo.processInfo.systemUptime
                    do {
                        call.results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
                        recorder.finishCall(seconds: ProcessInfo.processInfo.systemUptime - callStart, phase: phase, results: call.results)
                    } catch {
                        recorder.finishCall(seconds: ProcessInfo.processInfo.systemUptime - callStart, phase: phase, results: nil)
                        recorder.finish(status: "failed")
                        throw error
                    }
                    try Task.checkCancellation()
                    let mapped = mapper.mappedSegments(call.results, readStart: call.startMs, start: window.startMs,
                        end: call.ownedEndMs, durationMs: source.durationMs)
                    let kept = Self.preserve(call.results, mapper: mapper, readStart: call.startMs, start: window.startMs,
                        end: call.ownedEndMs, duration: source.durationMs)
                    if call.phase == "prefixRecovery" { segments = mapped + segments; preserved = kept + preserved }
                    else { segments += mapped; preserved += kept }
                    calls[callIndex] = call
                    if label == "baseline" && callIndex == 0,
                       let missingEnd = Analysis.missingASRPrefixEnd(segments: mapped, samples: samples,
                            readStartMs: call.startMs, coreStartMs: window.startMs, coreEndMs: window.endMs) {
                        let retryEnd = min(source.durationMs, window.readStartMs + 30_000)
                        calls.append(Call(phase: "prefixRecovery", startMs: max(0, retryEnd - 30_000),
                            endMs: retryEnd, ownedEndMs: missingEnd, results: []))
                    }
                    callIndex += 1
                }
                try Disk.write(Output(window: window, calls: calls, segments: segments, preserved: preserved),
                    to: destination.appendingPathComponent("windows/\(index).json"))
                try Disk.write(["completedWindows": index + 1, "plannedWindows": windows.count], to: destination.appendingPathComponent("progress.json"))
            }
            recorder.finish(status: "completed")
            try Disk.write(checks, to: destination.appendingPathComponent("language-checks.json"))
            try Disk.write(["thermalBefore": thermalBefore, "thermalAfter": ProcessInfo.processInfo.thermalState.rawValue,
                "networkDenied": 1], to: destination.appendingPathComponent("validation.json"))
            for source in input.sources { guard try Disk.hash(URL(fileURLWithPath: source.wavePath)) == source.waveHash else { throw ScribeError.message("Изменился PCM") } }
            for model in pinned.models where model.purpose == .asr || model.purpose == .tokenizer { try model.validate(at: models) }
        } catch {
            try? Disk.write(["errorType": String(reflecting: type(of: error)), "errorCode": String((error as NSError).code)],
                to: root.appendingPathComponent("failure-\(label).json"))
            XCTFail("Settings probe failed; SDK output discarded")
        }
    }
}
