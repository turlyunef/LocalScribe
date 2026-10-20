import XCTest
import AVFoundation
import WhisperKit
import LocalScribeCore
@testable import LocalScribeWorker

final class SpeechRecognizerTests: XCTestCase {
    private func wave(_ root: URL, milliseconds: Int, amplitude: Float = 0.1, pauses: [Range<Int>] = []) throws -> URL {
        try Disk.directory(root)
        let url = root.appendingPathComponent("fixture.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(milliseconds * 16)))
        buffer.frameLength = buffer.frameCapacity
        buffer.floatChannelData![0].initialize(repeating: amplitude, count: Int(buffer.frameLength))
        for pause in pauses {
            for frame in (pause.lowerBound * 16)..<(pause.upperBound * 16) { buffer.floatChannelData![0][frame] = 0 }
        }
        try autoreleasepool {
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false]
            let file = try AVAudioFile(forWriting: url, settings: settings)
            try file.write(from: buffer)
        }
        return url
    }

    private func result(_ words: [(String, Float, Float)], timings: TranscriptionTimings = .init()) -> [TranscriptionResult] {
        [TranscriptionResult(text: "private fixture text", segments: words.enumerated().map { index, word in
            TranscriptionSegment(id: index, start: word.1, end: word.2, text: word.0,
                words: [WordTiming(word: word.0, tokens: [], start: word.1, end: word.2, probability: 1)])
        }, language: "ru", timings: timings)]
    }

    func testWindowMetricsIncludeContextAndSDKInferenceButNoTranscript() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = try wave(root, milliseconds: 60000)
        let metrics = ASRMetricsRecorder(run: root, liveCapture: false)
        var inputs: [Int] = []
        let recognizer = SpeechRecognizer(metrics: metrics) { samples, options in
            inputs.append(samples.count / 16)
            XCTAssertEqual(options.windowClipTime, 0)
            XCTAssertTrue(options.detectLanguage); XCTAssertNil(options.language)
            return self.result([("Привет", 1.1, 1.2), (" hello", 1.3, Float(samples.count) / 16000 - 1)], timings:
                TranscriptionTimings(logmels: 0.1, encoding: 2, decodingLoop: 20, decodingPredictions: 3,
                                     decodingTimestampAlignment: 0.5, totalEncodingRuns: 1, totalDecodingLoops: 7, totalDecodingFallbacks: 1))
        }
        var segments = try await recognizer.recognize(wave: audio, coreStart: 0, coreEnd: 60000, durationMs: 60000)
        for index in segments.indices { segments[index].id = "fixture-\(index)" }
        try Transcript(fingerprint: "fixture", diarized: false, segments: segments).validate(durationMs: 60000)
        XCTAssertEqual(Set(segments.map(\.language)), ["ru", "en"])
        XCTAssertEqual(inputs, [29000, 30000, 5000])
        metrics.finish(status: "completed")
        let saved = try Disk.read(ASRMetrics.self, at: root.appendingPathComponent("metrics-asr.json"))
        XCTAssertEqual(saved.plannedWindows.count, 3); XCTAssertEqual(saved.plannedWindows.totalMs, 60000)
        XCTAssertEqual(saved.primary.inputs.totalMs, 64000); XCTAssertEqual(saved.primary.inputs.maximumMs, 30000)
        XCTAssertEqual(saved.primary.encoderSeconds, 6); XCTAssertEqual(saved.primary.decoderInferenceSeconds, 9)
        XCTAssertEqual(saved.primary.sdkDecodingLoopSeconds, 60)
        XCTAssertEqual(saved.primary.encoderRuns, 3); XCTAssertEqual(saved.prefixRecovery.inputs.count, 0)
        let json = try String(contentsOf: root.appendingPathComponent("metrics-asr.json"), encoding: .utf8)
        XCTAssertFalse(json.contains("private fixture")); XCTAssertFalse(json.contains("Привет")); XCTAssertFalse(json.contains(root.path))
    }

    func testPrefixRetryKeepsRecoveredAndOriginalWordTimes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = try wave(root, milliseconds: 10000)
        let metrics = ASRMetricsRecorder(run: root, liveCapture: false)
        var calls = 0
        let recognizer = SpeechRecognizer(metrics: metrics) { _, _ in
            calls += 1
            return calls == 1 ? self.result([("later", 3, 10)]) : self.result([("начало", 0.4, 3), ("later", 3, 10)])
        }
        let segments = try await recognizer.recognize(wave: audio, coreStart: 0, coreEnd: 10000, durationMs: 10000)
        XCTAssertEqual(segments.map(\.text), ["начало", "later"])
        XCTAssertEqual(segments.map(\.startMs), [400, 3000])
        XCTAssertEqual(metrics.value.primary.inputs.count, 1); XCTAssertEqual(metrics.value.prefixRecovery.inputs.count, 1)
        XCTAssertEqual(metrics.value.prefixRecovery.completedCalls, 1); XCTAssertEqual(metrics.value.unrecoveredPrefixes, 0)
    }

    func testFirstPauseSplitsActualModelInputsAndKeepsWordTimes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = try wave(root, milliseconds: 28000, pauses: [4000..<5000])
        var inputs: [Int] = []
        let recognizer = SpeechRecognizer { samples, _ in
            inputs.append(samples.count / 16)
            return inputs.count == 1 ? self.result([("первая", 0.2, 3.8)]) : self.result([("second", 1.8, 24)])
        }
        let segments = try await recognizer.recognize(wave: audio, coreStart: 0, coreEnd: 28000, durationMs: 28000)
        XCTAssertEqual(inputs, [5280, 24720])
        XCTAssertEqual(segments.map(\.text), ["первая", "second"])
        XCTAssertEqual(segments.map(\.startMs), [200, 5080])
        XCTAssertEqual(segments.map(\.endMs), [3800, 27280])
    }

    func testInteriorGapKeepsPrimaryWordsWithoutLocalRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = try wave(root, milliseconds: 20000)
        let metrics = ASRMetricsRecorder(run: root, liveCapture: false)
        var calls = 0
        let recognizer = SpeechRecognizer(metrics: metrics) { _, _ in
            calls += 1
            return self.result([("начало", 0.2, 5), ("конец", 15, 20)])
        }
        let segments = try await recognizer.recognize(wave: audio, coreStart: 0, coreEnd: 20000, durationMs: 20000)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(segments.map(\.text), ["начало", "конец"])
        XCTAssertEqual(segments.map(\.startMs), [200, 15000])
        XCTAssertEqual(metrics.value.gapRecovery.inputs.count, 0)
        XCTAssertEqual(metrics.value.prefixRecovery.inputs.count, 0)
        XCTAssertEqual(metrics.value.windowPolicy, "first-pause-prefix-recovery")
    }

    func testUncoveredTailDoesNotTriggerLocalRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = try wave(root, milliseconds: 5000)
        let metrics = ASRMetricsRecorder(run: root, liveCapture: false)
        var calls = 0
        let recognizer = SpeechRecognizer(metrics: metrics) { _, _ in
            calls += 1
            return self.result([("start", 0.2, 1)])
        }
        _ = try await recognizer.recognize(wave: audio, coreStart: 0, coreEnd: 5000, durationMs: 5000)
        XCTAssertEqual(calls, 1); XCTAssertEqual(metrics.value.gapRecovery.inputs.count, 0)
    }

    func testUnrecoveredPrefixAndSilentWindowsAreCounted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = try wave(root, milliseconds: 10000)
        let metrics = ASRMetricsRecorder(run: root, liveCapture: false)
        let recognizer = SpeechRecognizer(metrics: metrics) { _, _ in [] }
        _ = try await recognizer.recognize(wave: audio, coreStart: 0, coreEnd: 10000, durationMs: 10000)
        XCTAssertEqual(metrics.value.unrecoveredPrefixes, 1)
        let silent = try wave(root, milliseconds: 10000, amplitude: 0)
        _ = try await recognizer.recognize(wave: silent, coreStart: 0, coreEnd: 10000, durationMs: 10000)
        XCTAssertEqual(metrics.value.silentWindows, 6); XCTAssertEqual(metrics.value.primary.inputs.count, 1)
        XCTAssertEqual(metrics.value.plannedWindows.totalMs, 20000)
    }

    func testLiveOriginAndShortTailKeepOriginalTimeline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = try wave(root, milliseconds: 1125)
        let recognizer = SpeechRecognizer { samples, _ in
            XCTAssertEqual(samples.count, 18000)
            return self.result([("context", 0.1, 0.5), ("tail", 1.01, 1.1)])
        }
        let segments = try await recognizer.recognize(wave: audio, coreStart: 60000, coreEnd: 60125, durationMs: 60125, originMs: 59000)
        XCTAssertEqual(segments.map(\.text), ["tail"])
        XCTAssertEqual(segments.first?.startMs, 60010); XCTAssertEqual(segments.first?.endMs, 60100)
    }

    func testFailedCallAndResumptionResetDoNotLeakError() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = try wave(root, milliseconds: 1000)
        let metrics = ASRMetricsRecorder(run: root, liveCapture: false)
        let recognizer = SpeechRecognizer(metrics: metrics) { _, _ in throw ScribeError.message("private SDK error") }
        do {
            _ = try await recognizer.recognize(wave: audio, coreStart: 0, coreEnd: 1000, durationMs: 1000)
            XCTFail("Expected failure")
        } catch { metrics.finish(status: "failed") }
        XCTAssertEqual(metrics.value.primary.failedCalls, 1)
        XCTAssertEqual(metrics.value.primary.completedCalls, 0)
        XCTAssertFalse(try String(contentsOf: root.appendingPathComponent("metrics-asr.json"), encoding: .utf8).contains("private SDK error"))
        let resumed = ASRMetricsRecorder(run: root, liveCapture: true)
        resumed.checkpoint(milliseconds: 30000)
        resumed.finish(status: "completed")
        let saved = try Disk.read(ASRMetrics.self, at: root.appendingPathComponent("metrics-asr.json"))
        XCTAssertEqual(saved.checkpointHits, 1); XCTAssertEqual(saved.checkpointAudioMs, 30000)
        XCTAssertEqual(saved.primary.inputs.count, 0); XCTAssertEqual(saved.primary.failedCalls, 0)
    }
}
