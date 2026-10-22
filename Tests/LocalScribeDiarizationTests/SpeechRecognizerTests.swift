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

    func testMatrixSwitchesRecoverOnlyMissingWordsAndKeepPrimaryTimeline() async throws {
        for window in ASRWindowPolicy.allCases {
            for recover in [false, true] {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: root) }
                let audio = try wave(root, milliseconds: 20000)
                let policy = ASRRecognitionPolicy(window: window, recoverInteriorGaps: recover)
                let metrics = ASRMetricsRecorder(run: root, liveCapture: false, windowPolicy: policy.metricsName)
                var inputs: [Int] = []
                let recognizer = SpeechRecognizer(metrics: metrics, policy: policy) { samples, options in
                    inputs.append(samples.count / 16)
                    XCTAssertEqual(options.language, nil); XCTAssertTrue(options.detectLanguage)
                    XCTAssertEqual(options.temperatureFallbackCount, 2); XCTAssertEqual(options.windowClipTime, 0)
                    return inputs.count == 1 ? self.result([("начало", 0.2, 5), ("конец", 15, 20)])
                        : self.result([("context", 0, 0.2), (" missing", 0.5, 9.5), ("context", 10.3, 10.5)])
                }
                let segments = try await recognizer.recognize(wave: audio, coreStart: 0, coreEnd: 20000, durationMs: 20000)
                XCTAssertEqual(inputs, recover ? [20000, 10500] : [20000])
                XCTAssertEqual(segments.map(\.text), recover ? ["начало", " missing", "конец"] : ["начало", "конец"])
                XCTAssertEqual(segments.first?.startMs, 200); XCTAssertEqual(segments.last?.startMs, 15000)
                XCTAssertEqual(segments.last?.endMs, 20000)
                XCTAssertEqual(metrics.value.gapRecovery.inputs.count, recover ? 1 : 0)
                XCTAssertEqual(metrics.value.prefixRecovery.inputs.count, 0)
                XCTAssertEqual(metrics.value.unrecoveredGaps, 0)
            }
        }
    }

    func testLatePauseChangesModelInputsWithoutChangingDefaultFirstPause() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = try wave(root, milliseconds: 28000, pauses: [4000..<5000, 16000..<17000, 25000..<26000])
        var inputs: [Int] = []
        let recognizer = SpeechRecognizer(policy: .init(window: .latePause)) { samples, _ in
            inputs.append(samples.count / 16)
            return self.result([("speech", 0.2, Float(samples.count) / 16000)])
        }
        _ = try await recognizer.recognize(wave: audio, coreStart: 0, coreEnd: 28000, durationMs: 28000)
        XCTAssertEqual(inputs, [26500, 3500])
        XCTAssertEqual(ASRRecognitionPolicy.production.window, .firstPause)
        XCTAssertFalse(ASRRecognitionPolicy.production.recoverInteriorGaps)
    }

    func testExperimentalGapRetryIsBoundedAndFailurePropagates() async throws {
        for fail in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let audio = try wave(root, milliseconds: 5000)
            let policy = ASRRecognitionPolicy(recoverInteriorGaps: true)
            let metrics = ASRMetricsRecorder(run: root, liveCapture: false, windowPolicy: policy.metricsName)
            var calls = 0
            let recognizer = SpeechRecognizer(metrics: metrics, policy: policy) { _, _ in
                calls += 1
                if calls == 2 && fail { throw CancellationError() }
                return calls == 1 ? self.result([("start", 0.2, 1)]) : []
            }
            do {
                _ = try await recognizer.recognize(wave: audio, coreStart: 0, coreEnd: 5000, durationMs: 5000)
                XCTAssertFalse(fail)
                XCTAssertEqual(metrics.value.unrecoveredGaps, 1)
            } catch is CancellationError { XCTAssertTrue(fail) }
            XCTAssertEqual(calls, 2)
            XCTAssertEqual(metrics.value.gapRecovery.inputs.count, 1)
            XCTAssertEqual(metrics.value.gapRecovery.failedCalls, fail ? 1 : 0)
        }
    }

    func testContextReviewRetriesNonemptyUncertainTextWithoutReplacingPrimaryWords() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = try wave(root, milliseconds: 60000)
        let metrics = ASRMetricsRecorder(run: root, liveCapture: false)
        var inputs: [Int] = [], batches: [ASRContextReviewBatch] = []
        let recognizer = SpeechRecognizer(metrics: metrics, policy: .init(window: .latePause, reviewContext: true),
            contextReview: { batches.append($0) }) { samples, options in
                inputs.append(samples.count / 16)
                XCTAssertNil(options.language); XCTAssertTrue(options.detectLanguage)
                XCTAssertEqual(options.temperatureFallbackCount, 2)
                if inputs.count == 1 {
                    let original = self.result([("original", 1.2, 10.5)])
                    original[0].segments[0].avgLogprob = -1.2
                    return original
                }
                return self.result([("outside", 0, 1), ("alternative", 10.3, 19.4), ("outside", 21, 22)])
            }
        let segments = try await recognizer.recognize(wave: audio, coreStart: 10000, coreEnd: 20000, durationMs: 60000)
        XCTAssertEqual(inputs, [12000, 30000])
        XCTAssertEqual(segments.map(\.text), ["original"])
        XCTAssertEqual(segments.map(\.startMs), [10200]); XCTAssertEqual(segments.map(\.endMs), [19500])
        let review = try XCTUnwrap(batches.first?.reviews.first)
        XCTAssertEqual(review.original, segments)
        XCTAssertEqual(review.wordRepair?.proposed, segments)
        XCTAssertEqual(review.candidate.map(\.text), ["alternative"])
        XCTAssertEqual(review.candidate.map(\.startMs), [10300])
        XCTAssertEqual(review.request.reasons, [.uncertainText])
        XCTAssertEqual(metrics.value.contextReview?.completedCalls, 1)
        let saved = try String(contentsOf: root.appendingPathComponent("metrics-asr.json"), encoding: .utf8)
        XCTAssertFalse(saved.contains("original")); XCTAssertFalse(saved.contains("alternative"))
    }

    func testContextReviewFindsGapWithWideContextButKeepsPrimaryTranscript() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = try wave(root, milliseconds: 60000)
        var inputs: [Int] = [], batches: [ASRContextReviewBatch] = []
        let recognizer = SpeechRecognizer(policy: .init(window: .latePause, reviewContext: true),
            contextReview: { batches.append($0) }) { samples, _ in
                inputs.append(samples.count / 16)
                return inputs.count == 1 ? self.result([("start", 1.2, 3), ("end", 9, 11)])
                    : self.result([("missing", 13, 17)])
            }
        let segments = try await recognizer.recognize(wave: audio, coreStart: 10000, coreEnd: 20000, durationMs: 60000)
        XCTAssertEqual(inputs, [12000, 30000])
        XCTAssertEqual(segments.map(\.text), ["start", "end"])
        let review = try XCTUnwrap(batches.first?.reviews.first)
        XCTAssertEqual(review.request.reasons, [.uncoveredSignal])
        XCTAssertEqual(review.request.startMs, 12000); XCTAssertEqual(review.request.endMs, 18000)
        XCTAssertTrue(review.original.isEmpty)
        XCTAssertEqual(review.candidate.map(\.text), ["missing"])
    }

    func testContextReviewCancellationPropagatesWithBoundedLiveContext() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = try wave(root, milliseconds: 21200)
        let metrics = ASRMetricsRecorder(run: root, liveCapture: true)
        var inputs: [Int] = []
        let recognizer = SpeechRecognizer(metrics: metrics, policy: .init(window: .latePause, reviewContext: true),
            contextReview: { _ in XCTFail("Cancelled batch must not be published") }) { samples, _ in
                inputs.append(samples.count / 16)
                if inputs.count == 2 { throw CancellationError() }
                let original = self.result([("original", 1.2, 10.5)])
                original[0].segments[0].avgLogprob = -1.2
                return original
            }
        do {
            _ = try await recognizer.recognize(wave: audio, coreStart: 70000, coreEnd: 80000, durationMs: 81200, originMs: 60000)
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
        XCTAssertEqual(inputs, [12000, 21200])
        XCTAssertEqual(metrics.value.contextReview?.failedCalls, 1)
    }

    func testContextReviewRequiresExplicitArtifactSinkAndIsDisabledInProduction() async throws {
        let recognizer = SpeechRecognizer(policy: .init(reviewContext: true)) { _, _ in
            XCTFail("Missing sink must fail before inference"); return []
        }
        do {
            _ = try await recognizer.recognize(wave: URL(fileURLWithPath: "/missing.wav"), coreStart: 0, coreEnd: 10000, durationMs: 10000)
            XCTFail("Expected missing sink error")
        } catch { XCTAssertTrue(error is ScribeError) }
        XCTAssertFalse(ASRRecognitionPolicy.production.reviewContext)
    }

    func testContextReviewReusesOneDecodeForTargetsWithTheSameContext() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = try wave(root, milliseconds: 30000)
        let metrics = ASRMetricsRecorder(run: root, liveCapture: false)
        var inputs: [Int] = [], batches: [ASRContextReviewBatch] = []
        let recognizer = SpeechRecognizer(metrics: metrics, policy: .init(window: .latePause, reviewContext: true),
            contextReview: { batches.append($0) }) { samples, _ in
                inputs.append(samples.count / 16)
                let original = self.result([("original", 0.2, 28)])
                if inputs.count == 1 { original[0].segments[0].avgLogprob = -1.2 }
                return original
            }
        _ = try await recognizer.recognize(wave: audio, coreStart: 0, coreEnd: 28000, durationMs: 30000)
        XCTAssertEqual(inputs, [29000, 30000])
        XCTAssertEqual(batches.first?.reviews.count, 2)
        XCTAssertEqual(metrics.value.contextReview?.inputs.count, 1)
    }

    func testContextReviewChecksTaskCancellationWhenSDKReturnsWithoutThrowing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = try wave(root, milliseconds: 60000)
        let job = Task {
            var calls = 0
            let recognizer = SpeechRecognizer(policy: .init(window: .latePause, reviewContext: true),
                contextReview: { _ in XCTFail("Cancelled result must not be published") }) { _, _ in
                    calls += 1
                    if calls == 2 { withUnsafeCurrentTask { $0?.cancel() } }
                    return [TranscriptionResult(text: "fixture", segments: [
                        TranscriptionSegment(id: 0, start: 1.2, end: 10.5, text: "fixture", avgLogprob: -1.2,
                            words: [WordTiming(word: "fixture", tokens: [], start: 1.2, end: 10.5, probability: 0.3)])
                    ], language: "ru", timings: .init())]
                }
            return try await recognizer.recognize(wave: audio, coreStart: 10000, coreEnd: 20000, durationMs: 60000)
        }
        do { _ = try await job.value; XCTFail("Expected task cancellation") }
        catch is CancellationError { }
    }

    func testPrimaryAndPrefixCancellationCannotReturnSuccessfulTranscript() async throws {
        for cancelledCall in [1, 2] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let audio = try wave(root, milliseconds: 10000)
            let job = Task {
                var calls = 0
                let recognizer = SpeechRecognizer { _, _ in
                    calls += 1
                    if calls == cancelledCall { withUnsafeCurrentTask { $0?.cancel() } }
                    return [TranscriptionResult(text: "later", segments: [
                        TranscriptionSegment(id: 0, start: 3, end: 10, text: "later",
                            words: [WordTiming(word: "later", tokens: [], start: 3, end: 10, probability: 1)])
                    ], language: "en", timings: .init())]
                }
                return try await recognizer.recognize(wave: audio, coreStart: 0, coreEnd: 10000, durationMs: 10000)
            }
            do { _ = try await job.value; XCTFail("Cancelled decode must not publish a successful part") }
            catch is CancellationError { }
        }
    }

    func testNoLeftContextAtNonzeroOriginKeepsShortSealedTail() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = try wave(root, milliseconds: 125)
        var calls = 0
        let recognizer = SpeechRecognizer { samples, _ in
            calls += 1
            XCTAssertEqual(samples.count, 2000)
            return self.result([("tail", 0.01, 0.10)])
        }
        let segments = try await recognizer.recognize(wave: audio, coreStart: 60000, coreEnd: 60125,
            durationMs: 60125, originMs: 60000)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(segments.first?.startMs, 60010)
        XCTAssertEqual(segments.first?.endMs, 60100)
    }

    func testCrossingWordOwnershipAndGenuineRepetitionAtSeam() {
        let mapper = SpeechRecognizer { _, _ in [] }
        let raw = result([("да", 27.7, 28.3), (" да", 28.4, 28.6)])
        let left = mapper.mappedSegments(raw, readStart: 0, start: 0, end: 28000, durationMs: 30000)
        let right = mapper.mappedSegments(raw, readStart: 0, start: 28000, end: 30000, durationMs: 30000)
        XCTAssertTrue(left.isEmpty) // Exact boundary midpoint belongs to the right.
        XCTAssertEqual(right.map(\.text), ["да", " да"])
        let joined = Analysis.mergeParts([
            ASRPart(fingerprint: "fixture", index: 0, startMs: 0, endMs: 28000, segments: left),
            ASRPart(fingerprint: "fixture", index: 1, startMs: 28000, endMs: 30000, segments: right)
        ], fingerprint: "fixture")
        XCTAssertEqual(joined.segments.map(\.text), ["да", " да"])
        XCTAssertEqual(joined.segments.first?.startMs, 27700)
    }

    func testLiveThirtySecondPartKeepsTwoSecondRemainderAndOnlyRealRightContext() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = try wave(root, milliseconds: 40000)
        var inputs: [Int] = []
        let recognizer = SpeechRecognizer { samples, _ in
            inputs.append(samples.count / 16)
            return inputs.count == 1 ? self.result([("first", 0.2, 27.7)])
                : self.result([("left-context", 0.1, 0.6), ("remainder", 1.1, 2.8), ("future", 3.2, 3.5)])
        }
        let segments = try await recognizer.recognize(wave: audio, coreStart: 0, coreEnd: 30000, durationMs: 31000)
        XCTAssertEqual(inputs, [29000, 4000])
        XCTAssertEqual(segments.map(\.text), ["first", "remainder"])
        XCTAssertEqual(segments.last?.startMs, 28100)
        XCTAssertEqual(segments.last?.endMs, 29800)
    }

    func testProductionPreservesUncertainSegmentsAndWordTimingsOfflineAndLive() async throws {
        for origin in [0, 60000] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let audio = try wave(root, milliseconds: 30000)
            let metrics = ASRMetricsRecorder(run: root, liveCapture: origin != 0)
            var calls = 0
            let recognizer = SpeechRecognizer(metrics: metrics,
                contextReview: { _ in XCTFail("Production must not publish technical hypotheses") }) { _, options in
                    calls += 1
                    XCTAssertNil(options.promptTokens)
                    let raw = self.result([("начало", 0.2, 3), (" hello", 20, 25)])
                    for index in raw[0].segments.indices { raw[0].segments[index].avgLogprob = -1.2 }
                    return raw
                }
            let segments = try await recognizer.recognize(wave: audio, coreStart: origin,
                coreEnd: origin + 28000, durationMs: origin + 30000, originMs: origin)
            // The mapper deliberately shares tmp IDs. No production edit may use
            // them as keys, replace uncertain text, or lose the original words.
            XCTAssertEqual(segments, [
                Segment(id: "tmp", startMs: origin + 200, endMs: origin + 3000, text: "начало",
                    language: "ru", uncertain: true,
                    words: [Word(text: "начало", startMs: origin + 200, endMs: origin + 3000)]),
                Segment(id: "tmp", startMs: origin + 20000, endMs: origin + 25000, text: " hello",
                    language: "en", uncertain: true,
                    words: [Word(text: " hello", startMs: origin + 20000, endMs: origin + 25000)])
            ])
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(metrics.value.prefixRecovery.inputs.count, 0)
            XCTAssertEqual(metrics.value.gapRecovery.inputs.count, 0)
            XCTAssertNil(metrics.value.contextReview)
        }
    }

    func testProductionPrefixFailureCannotReturnPartialTranscriptOfflineOrLive() async throws {
        for origin in [0, 60000] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let audio = try wave(root, milliseconds: 11000)
            let metrics = ASRMetricsRecorder(run: root, liveCapture: origin != 0)
            var calls = 0
            let recognizer = SpeechRecognizer(metrics: metrics) { _, _ in
                calls += 1
                if calls == 2 { throw ScribeError.message("private retry SDK error") }
                return self.result([("later", 3, 10)])
            }
            do {
                _ = try await recognizer.recognize(wave: audio, coreStart: origin,
                    coreEnd: origin + 10000, durationMs: origin + 11000, originMs: origin)
                XCTFail("A failed prefix retry must not publish the primary as a complete part")
            } catch { XCTAssertTrue(error is ScribeError) }
            metrics.finish(status: "failed")
            XCTAssertEqual(calls, 2)
            XCTAssertEqual(metrics.value.primary.completedCalls, 1)
            XCTAssertEqual(metrics.value.prefixRecovery.failedCalls, 1)
            XCTAssertEqual(metrics.value.prefixRecovery.completedCalls, 0)
            let json = try String(contentsOf: root.appendingPathComponent("metrics-asr.json"), encoding: .utf8)
            XCTAssertFalse(json.contains("private retry")); XCTAssertFalse(json.contains("later"))
        }
    }
}
