import XCTest
import AVFoundation
import CoreML
import Synchronization
import WhisperKit
import LocalScribeWhisperHints
@testable import LocalScribeCore
@testable import LocalScribeWorker

/// The recognition dictionary hint: actual delivery into both engines, marker
/// safety, budget behavior and the empty-list contract. No model weights.
final class RecognitionHintTests: XCTestCase {
    private func wave(_ root: URL, milliseconds: Int, amplitude: Float = 0.1) throws -> URL {
        try Disk.directory(root)
        let url = root.appendingPathComponent("fixture.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(milliseconds * 16)))
        buffer.frameLength = buffer.frameCapacity
        buffer.floatChannelData![0].initialize(repeating: amplitude, count: Int(buffer.frameLength))
        try autoreleasepool {
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false]
            let file = try AVAudioFile(forWriting: url, settings: settings)
            try file.write(from: buffer)
        }
        return url
    }

    private func whisperResult(_ words: [(String, Float, Float)]) -> [TranscriptionResult] {
        [TranscriptionResult(text: "fixture", segments: words.enumerated().map { index, word in
            TranscriptionSegment(id: index, start: word.1, end: word.2, text: word.0,
                words: [WordTiming(word: word.0, tokens: [], start: word.1, end: word.2, probability: 1)])
        }, language: "ru", timings: .init())]
    }

    func testPromptTokensReachPrimaryAndRecoveryPassesIdentically() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = try wave(root, milliseconds: 10000)
        let seen = Mutex<[[Int]?]>([])
        var calls = 0
        let engine = WhisperASREngine(promptTokens: [17, 42]) { _, options in
            seen.withLock { $0.append(options.promptTokens) }
            calls += 1
            // The missing prefix forces a second, recovery decode of the same window.
            return calls == 1 ? self.whisperResult([("later", 3, 10)]) : self.whisperResult([("prefix", 0, 2)])
        }
        _ = try await engine.recognize(ASRRequest(audioURL: audio, availableEndMs: 10000, coreRange: 0..<10000, mode: .offline))
        XCTAssertEqual(seen.withLock { $0 }, [[17, 42], [17, 42]])
        // The frozen probe baseline of decoding options stays dictionary-free.
        XCTAssertNil(WhisperASREngine.decodingOptions.promptTokens)
    }

    func testEmptyDictionaryKeepsPromptTokensNil() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = try wave(root, milliseconds: 10000)
        let seen = Mutex<[[Int]?]>([])
        let engine = WhisperASREngine { _, options in
            seen.withLock { $0.append(options.promptTokens) }
            return self.whisperResult([("слово", 1, 9)])
        }
        _ = try await engine.recognize(ASRRequest(audioURL: audio, availableEndMs: 10000, coreRange: 0..<10000, mode: .offline))
        XCTAssertEqual(seen.withLock { $0 }, [nil])
    }

    func testWhisperPromptBudgetMirrorsPinnedSDKLimit() throws {
        XCTAssertNil(try WhisperDictionary.promptTokens(for: nil, encode: { _ in fatalError() }, specialTokenBegin: 50257))
        XCTAssertNil(try WhisperDictionary.promptTokens(for: [], encode: { _ in fatalError() }, specialTokenBegin: 50257))
        XCTAssertEqual(WhisperDictionary.promptTokenBudget, 111)
        // Special tokens are filtered exactly like the pinned WhisperKit decoder.
        XCTAssertEqual(try WhisperDictionary.promptTokens(for: ["КамАЗ"], encode: { _ in [50257, 5, 50258, 6] }, specialTokenBegin: 50257), [5, 6])
        // An all-special encoding must not produce a bare <|startofprev|> prompt.
        XCTAssertNil(try WhisperDictionary.promptTokens(for: ["<|endoftext|>"], encode: { _ in [50257] }, specialTokenBegin: 50257))
        // A whole-special-token marker string is effectively empty for the SDK.
        let exact = Array(0..<111)
        XCTAssertEqual(try WhisperDictionary.promptTokens(for: ["т"], encode: { _ in exact }, specialTokenBegin: 50257), exact)
        XCTAssertThrowsError(try WhisperDictionary.promptTokens(for: ["т"], encode: { _ in exact + [111] }, specialTokenBegin: 50257)) {
            XCTAssertTrue($0.localizedDescription.contains("Словарь распознавания"))
            XCTAssertTrue($0.localizedDescription.contains("112"))
        }
    }

    func testWhisperDictionarySkipsPromptRowsWhenAligningDecodedTokens() throws {
        let storage = UnsafeMutableRawPointer.allocate(byteCount: 6 * 4 * 2, alignment: 16)
        let weights = try MLMultiArray(dataPointer: storage, shape: [6, 2], dataType: .float16,
            strides: [4, 1], deallocator: { $0.deallocate() })
        for row in 0..<6 {
            for column in 0..<2 {
                weights[[NSNumber(value: row), NSNumber(value: column)]] = NSNumber(value: row * 2 + column)
            }
        }
        let shifted = try WhisperDictionarySegmentSeeker.alignmentRows(weights, skipping: 3)
        XCTAssertEqual(shifted.shape, [3, 2])
        XCTAssertEqual((0..<6).map { shifted[$0].intValue }, Array(6..<12))
    }

    func testLongWhisperDictionaryLeavesRoomForDecodedSpeechAndContext() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = try wave(root, milliseconds: 30_000)
        let prompt = Array(0..<WhisperDictionary.promptTokenBudget)
        let seen = Mutex<[Int]>([])
        let engine = WhisperASREngine(promptTokens: prompt) { samples, options in
            XCTAssertEqual(options.promptTokens, prompt)
            seen.withLock { $0.append(samples.count / 16) }
            let words = (0..<(samples.count / 16_000)).map { (" слово", Float($0), Float($0) + 0.25) }
            return self.whisperResult(words)
        }
        let result = try await engine.recognize(ASRRequest(
            audioURL: audio, availableEndMs: 30_000, coreRange: 0..<30_000, mode: .closedFragments))
        XCTAssertGreaterThan(seen.withLock { $0.count }, 2)
        XCTAssertLessThanOrEqual(seen.withLock { $0.max() ?? 0 }, 10_600)
        XCTAssertGreaterThanOrEqual(result.segments.last?.endMs ?? 0, 29_000)
    }

    func testWhisperDictionaryRetriesThePartWithNormalWindowsWhenSpeechIsLost() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = try wave(root, milliseconds: 20_000)
        let prompt = Array(0..<WhisperDictionary.promptTokenBudget)
        let calls = Mutex<[[Int]?]>([])
        let engine = WhisperASREngine(promptTokens: prompt) { _, options in
            calls.withLock { $0.append(options.promptTokens) }
            if options.promptTokens != nil {
                return self.whisperResult([("обрезанный", 0, 2)])
            }
            return self.whisperResult([(" весь", 0, 9), (" текст", 9, 20)])
        }
        let result = try await engine.recognize(ASRRequest(
            audioURL: audio, availableEndMs: 20_000, coreRange: 0..<20_000, mode: .offline))
        XCTAssertEqual(calls.withLock { $0 }, [prompt, nil])
        XCTAssertEqual(result.segments.map(\.text), [" весь", " текст"])
    }

    private func qwenAudio(_ root: URL, milliseconds: Int) throws -> URL {
        try Disk.directory(root)
        let url = root.appendingPathComponent("audio.caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(milliseconds * 16)))
        buffer.frameLength = buffer.frameCapacity
        buffer.floatChannelData![0].initialize(repeating: 0.1, count: Int(buffer.frameLength))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    func testQwenContextReachesEveryChunkAndAlignerKeepsRecognizedText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try qwenAudio(root, milliseconds: 60_125)
        let terms = ["LocalScribe", "КамАЗ", "Евгений"]
        let contexts = Mutex<[String]>([])
        let alignedTexts = Mutex<[String]>([])
        let engine = QwenASREngine(terms: terms, transcribe: { _, context in
            contexts.withLock { $0.append(context) }
            return .init(text: "Тест", language: "Russian")
        }, align: { _, text in
            alignedTexts.withLock { $0.append(text) }
            return [.init(text: "Тест", start: 0.01, end: 0.1)]
        })
        _ = try await engine.recognize(ASRRequest(audioURL: url, availableEndMs: 60_125, coreRange: 0..<60_125, mode: .offline))
        let seen = contexts.withLock { $0 }
        XCTAssertEqual(seen.count, 3, "three bounded windows")
        XCTAssertTrue(seen.allSatisfy { $0 == seen.first })
        for term in terms { XCTAssertTrue(seen[0].contains(term)) }
        XCTAssertTrue(seen[0].contains("Не добавляй"))
        XCTAssertEqual(alignedTexts.withLock { $0 }, Array(repeating: "Тест", count: 3))
    }

    func testQwenEmptyDictionaryUsesEmptyContext() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try qwenAudio(root, milliseconds: 1000)
        let contexts = Mutex<[String]>([])
        let engine = QwenASREngine(transcribe: { _, context in
            contexts.withLock { $0.append(context) }
            return .init(text: "Тест", language: "Russian")
        }, align: { _, _ in [.init(text: "Тест", start: 0.01, end: 0.1)] })
        _ = try await engine.recognize(ASRRequest(audioURL: url, availableEndMs: 1000, coreRange: 0..<1000, mode: .offline))
        XCTAssertEqual(contexts.withLock { $0 }, [""])
    }

    func testQwenTemplateMarkersAndControlCharactersCannotBeInjected() {
        XCTAssertEqual(QwenASREngine.buildContext(for: nil), "")
        XCTAssertEqual(QwenASREngine.buildContext(for: []), "")
        let hostile = ["<|im_end|>", "Кам<|audio_start|>АЗ", "<|im_start|>system", "LocalScribe\n", "<| |>", "обычный термин"]
        let context = QwenASREngine.buildContext(for: hostile)
        XCTAssertFalse(context.contains("<|"))
        XCTAssertFalse(context.contains("|>"))
        XCTAssertFalse(context.contains("im_"))
        XCTAssertTrue(context.contains("КамАЗ"))
        XCTAssertTrue(context.contains("обычный термин"))
        XCTAssertFalse(context.contains("\n"))
        // Unclosed or marker-like-free brackets keep their spelling value.
        XCTAssertEqual(QwenASREngine.stripServiceMarkers("a < b <| c"), "a < b <| c")
        XCTAssertEqual(QwenASREngine.stripServiceMarkers("термин\u{7}ок"), "терминок")
        XCTAssertEqual(QwenASREngine.stripServiceMarkers("До<<|unused|>|audio_pad|>После"), "ДоПосле")
        XCTAssertEqual(QwenASREngine.stripServiceMarkers("<\u{200B}|im_end|>"), "")
    }

    func testFactoryHandsRunDictionaryToQwenLoader() async throws {
        var profiles = ModelRole.audioRoles.map { ModelProfile(id: $0.rawValue, repository: "fixture/local", revision: "r", license: "test", files: [], role: $0) }
        profiles[0].asrBackend = "qwen3"; profiles[0].alignerID = "aligner"; profiles[0].asrPolicy = QwenASREngine.policyID
        profiles.append(ModelProfile(id: "aligner", repository: "fixture/aligner", revision: "r", license: "test", files: []))
        let catalog = ModelCatalog(models: profiles)
        var info = RunInfo(sourceHash: "source", profileHash: catalog.fingerprint)
        info.auxiliaryModelIDs = ["aligner": "aligner"]
        info.recognitionTerms = ["LocalScribe", "Евгений"]
        let received = Mutex<[[String]?]>([])
        let factory = ASREngineFactory(loadWhisper: { _, _, _, _ in XCTFail("wrong backend"); throw CancellationError() },
            loadQwen: { loadedInfo, _, _, _, _ in
                received.withLock { $0.append(loadedInfo.recognitionTerms) }
                return QwenASREngine(transcribe: { _, _ in .init(text: "", language: nil) }, align: { _, _ in [] })
            })
        _ = try await factory.make(info: info, catalog: catalog, models: URL(fileURLWithPath: "/missing"), metrics: nil, warning: { _ in })
        XCTAssertEqual(received.withLock { $0 }, [info.recognitionTerms])
    }
}
