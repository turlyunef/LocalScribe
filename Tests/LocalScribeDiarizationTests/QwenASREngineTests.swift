import XCTest
import AVFoundation
@testable import LocalScribeCore
@testable import LocalScribeWorker

final class QwenASREngineTests: XCTestCase {
    func testAlignmentRetainsTextLanguagesAndOriginalTime() throws {
        let result = try QwenASREngine.map(hypothesis: .init(text: "Привет, Java!", language: "Russian"),
            aligned: [.init(text: "Привет", start: 0.2, end: 0.6), .init(text: "Java", start: 0.7, end: 1)],
            readStart: 60_000, readEnd: 62_000, core: 60_000..<62_000)
        XCTAssertEqual(result.map(\.text), ["Привет,", "Java!"])
        XCTAssertEqual(result.map(\.language), ["ru", "en"])
        XCTAssertEqual(result.flatMap(\.words).map(\.startMs), [60_200, 60_700])
        XCTAssertTrue(result.allSatisfy { $0.speakerId == nil })
    }

    func testInvalidAlignmentIsNeverRepairedOrPublished() {
        for values: [(Double, Double)] in [[(.nan, 0.5)], [(0, .infinity)], [(-0.1, 0.5)],
                                          [(0.5, 0.2)], [(0.2, 0.2)], [(0, 2.1)]] {
            XCTAssertThrowsError(try QwenASREngine.map(hypothesis: .init(text: "word", language: "English"),
                aligned: values.map { .init(text: "word", start: $0.0, end: $0.1) },
                readStart: 1000, readEnd: 3000, core: 1000..<3000))
        }
        for aligned: [QwenASREngine.AlignedWord] in [[], [.init(text: "wrong", start: 0, end: 0.5)],
                [.init(text: "one", start: 0.7, end: 1), .init(text: "two", start: 0.2, end: 0.5)]] {
            XCTAssertThrowsError(try QwenASREngine.map(hypothesis: .init(text: "one two", language: nil),
                aligned: aligned, readStart: 0, readEnd: 2000, core: 0..<2000))
        }
    }

    func testQuantizedZeroDurationDropsWordLayerWithoutInventingTimes() throws {
        let result = try QwenASREngine.map(hypothesis: .init(text: "one a word", language: "English"),
            aligned: [.init(text: "one", start: 0.1, end: 0.4), .init(text: "a", start: 0.4, end: 0.4),
                      .init(text: "word", start: 0.5, end: 0.9)], readStart: 1000, readEnd: 2000, core: 1000..<2000)
        XCTAssertEqual(result.first?.text, "one a word")
        XCTAssertEqual(result.first?.startMs, 1100)
        XCTAssertEqual(result.first?.endMs, 1900)
        XCTAssertEqual(result.first?.words, [])
    }

    func testAdjacentOwnershipKeepsCrossingWordExactlyOnce() throws {
        let hypothesis = QwenASREngine.Hypothesis(text: "one two three", language: "English")
        let aligned: [QwenASREngine.AlignedWord] = [.init(text: "one", start: 0, end: 0.4),
            .init(text: "two", start: 0.8, end: 1.2), .init(text: "three", start: 1.5, end: 1.9)]
        let first = try QwenASREngine.map(hypothesis: hypothesis, aligned: aligned, readStart: 0, readEnd: 2000, core: 0..<1000)
        let second = try QwenASREngine.map(hypothesis: hypothesis, aligned: aligned, readStart: 0, readEnd: 2000, core: 1000..<2000)
        XCTAssertEqual((first+second).flatMap(\.words).map(\.text), ["one", "two", "three"])
        XCTAssertEqual(second.flatMap(\.words).first?.startMs, 800)
    }

    func testPausePlannerPreservesTailAndDoesNotCutAtInitialSilence() {
        let samples = [Float](repeating: 0.1, count: 3 * 16000)
            + [Float](repeating: 0, count: 16000)
            + [Float](repeating: 0.1, count: 2 * 16000)
        XCTAssertEqual(QwenASREngine.windowLengthMs(samples), 3300)
        XCTAssertEqual(QwenASREngine.windowLengthMs([Float](repeating: 0.1, count: 2000)), 125)
        XCTAssertEqual(QwenASREngine.windowLengthMs([Float](repeating: 0, count: 16000)), 1000)
    }

    func testUndeclaredTokenizerFileCannotBeReadFromDisk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Disk.directory(root); defer { try? FileManager.default.removeItem(at: root) }
        let profile = ModelProfile(id: "tokenizer", repository: "fixture/local", revision: "r", license: "test",
            files: [.init(path: "vocab.json", localPath: "vocab.json", size: 2, sha256: Disk.fingerprint("{}"))])
        try Disk.directory(root.appendingPathComponent("tokenizer"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("tokenizer/vocab.json"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("tokenizer/tokenizer_config.json"))
        XCTAssertThrowsError(try PinnedASRFiles.validate(profile, at: root, requiring: ["vocab.json", "tokenizer_config.json"]))
    }

    func testFactoryUsesFrozenBackendAndRejectsMissingAlignerBeforeLoading() async throws {
        var profiles = ModelRole.allCases.map { ModelProfile(id: $0.rawValue, repository: "fixture/local", revision: "r", license: "test", files: [], role: $0) }
        profiles[0].asrBackend = "qwen3"; profiles[0].alignerID = "aligner"; profiles[0].asrPolicy = QwenASREngine.policyID
        profiles.append(ModelProfile(id: "aligner", repository: "fixture/aligner", revision: "r", license: "test", files: []))
        let catalog = ModelCatalog(models: profiles)
        var info = RunInfo(sourceHash: "source", profileHash: catalog.fingerprint)
        info.auxiliaryModelIDs = ["aligner": "aligner"]
        let factory = ASREngineFactory(loadWhisper: { _, _, _, _ in XCTFail("wrong backend"); throw CancellationError() },
            loadQwen: { pinned, _, _, _ in
                XCTAssertEqual(pinned.models.last?.id, "aligner")
                return QwenASREngine(transcribe: { _ in .init(text: "", language: nil) }, align: { _, _ in [] })
            })
        let recognizer = try await factory.make(info: info, catalog: catalog, models: URL(fileURLWithPath: "/missing"), metrics: nil, warning: { _ in })
        XCTAssertEqual(recognizer.capabilities.inputModes, [.offline])
        var incomplete = catalog; incomplete.models.removeLast()
        do { _ = try await factory.make(info: info, catalog: incomplete, models: URL(fileURLWithPath: "/missing"), metrics: nil, warning: { _ in }); XCTFail("missing aligner accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("выравнивания")) }
    }

    private func audio(_ root: URL, milliseconds: Int) throws -> URL {
        let url = root.appendingPathComponent("audio.caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(milliseconds * 16)))
        buffer.frameLength = buffer.frameCapacity
        buffer.floatChannelData![0].initialize(repeating: 0.1, count: Int(buffer.frameLength))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    func testBoundedWindowsOriginAndShortTail() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Disk.directory(root); defer { try? FileManager.default.removeItem(at: root) }
        let url = try audio(root, milliseconds: 60_125)
        var lengths: [Int] = []
        let engine = QwenASREngine(transcribe: { samples in
            lengths.append(samples.count / 16)
            return .init(text: "Тест", language: "Russian")
        }, align: { samples, _ in
            [.init(text: "Тест", start: 0.01, end: min(0.1, Double(samples.count)/16000))]
        })
        let result = try await engine.recognize(ASRRequest(audioURL: url, originMs: 40_000,
            availableEndMs: 100_125, coreRange: 40_000..<100_125, mode: .offline))
        XCTAssertEqual(lengths, [28_250, 28_500, 4_375])
        XCTAssertEqual(result.segments.first?.startMs, 40_010)
        XCTAssertTrue(result.segments.allSatisfy { $0.endMs <= 100_125 })
        do {
            _ = try await engine.recognize(ASRRequest(audioURL: url, availableEndMs: 1000, coreRange: 0..<1000, mode: .closedFragments))
            XCTFail("live must be gated")
        } catch { }
    }

    func testCancellationAfterNonCooperatingModelDoesNotAlign() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Disk.directory(root); defer { try? FileManager.default.removeItem(at: root) }
        let url = try audio(root, milliseconds: 1000)
        let task = Task {
            let engine = QwenASREngine(transcribe: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return .init(text: "Text", language: "English")
            }, align: { _, _ in XCTFail("alignment after cancellation"); return [] })
            return try await engine.recognize(ASRRequest(audioURL: url, availableEndMs: 1000, coreRange: 0..<1000, mode: .offline))
        }
        do { _ = try await task.value; XCTFail("cancelled output") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
