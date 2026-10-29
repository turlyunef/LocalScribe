import XCTest
import Foundation
import MLX
@testable import LocalScribeQwen
import LocalScribeCore
import CWorkerIsolation
@testable import LocalScribeWorker

final class QwenRuntimeTests: XCTestCase {
    func testFrontendFrameCountSilenceAndAudioTokenLengthsOnCPU() {
        Stream.withNewDefaultStream(device: .cpu) {
            let mel = computeMelSpectrogram(audio: MLXArray([Float](repeating: 0, count: 1600)), sampleRate: 16000,
                nFft: 400, hopLength: 160, nMels: 128, melScale: .slaney, hannPeriodic: true, dropLastFrame: true)
            XCTAssertEqual(mel.shape, [10, 128])
            XCTAssertTrue(mel.asArray(Float.self).allSatisfy { abs($0 + 1.5) < 0.00001 })
            let lengths: [Int32] = [1, 99, 100, 101, 124, 125, 2800]
            let result = getFeatExtractOutputLengths(MLXArray(lengths)).asArray(Int32.self)
            func floorHalf(_ value: Int) -> Int { Int(floor(Double(value) / 2)) }
            let expected = lengths.map { value -> Int32 in
                let n = Int(value), feature = floorHalf(n % 100 - 1) + 1
                return Int32(floorHalf(floorHalf(feature - 1) + 1 - 1) + 1 + (n / 100) * 13)
            }
            XCTAssertEqual(result, expected)
        }
    }

    func testRawAlignmentDoesNotRepairInvalidPredictions() throws {
        let processor = ForceAlignProcessor()
        let items = try processor.parseTimestamp(wordList: ["Привет", "world"], timestamp: [500, 400, 300, 700])
        XCTAssertEqual(items.map(\.startTime), [0.5, 0.3])
        XCTAssertEqual(items.map(\.endTime), [0.4, 0.7])
        XCTAssertThrowsError(try processor.parseTimestamp(wordList: ["word"], timestamp: [100]))
    }

    func testRussianEnglishAndMixedAlignmentTokens() {
        let processor = ForceAlignProcessor()
        for text in ["Привет, мир!", "Hello, world!", "Обсудим Java backend завтра."] {
            let tokens = processor.encodeTimestamp(text: text, language: "Russian").0
            XCTAssertEqual(tokens, processor.encodeTimestamp(text: text, language: "English").0)
            XCTAssertFalse(tokens.isEmpty)
        }
    }

    /// Explicit technical fixture only. No network, downloads or transcript logging.
    func testLocalQwenFixture() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let asr = env["LOCALSCRIBE_QWEN_ASR"], let aligner = env["LOCALSCRIBE_QWEN_ALIGNER"],
              let wave = env["LOCALSCRIBE_QWEN_WAV"] else {
            throw XCTSkip("Set LOCALSCRIBE_QWEN_ASR, LOCALSCRIBE_QWEN_ALIGNER and LOCALSCRIBE_QWEN_WAV to verified local models and mono 16 kHz technical audio; network must be denied")
        }
        let samples = try Media.samples(URL(fileURLWithPath: wave), start: 0, duration: 28)
        XCTAssertFalse(samples.isEmpty)
        let start = ProcessInfo.processInfo.systemUptime
        var model: Qwen3ASRModel? = try Qwen3ASRModel.fromModelDirectory(URL(fileURLWithPath: asr), tokenizerDirectory: URL(fileURLWithPath: asr))
        let loaded = ProcessInfo.processInfo.systemUptime
        let result = try model!.generateSingleChunk(audio: MLXArray(samples), maxTokens: 1024, temperature: 0, context: "", language: nil)
        let recognized = ProcessInfo.processInfo.systemUptime
        XCTAssertFalse(result.text.isEmpty)
        model = nil; Memory.clearCache()
        let alignment = try Qwen3ForcedAlignerModel.fromModelDirectory(URL(fileURLWithPath: aligner))
        let alignmentLoaded = ProcessInfo.processInfo.systemUptime
        let aligned = try alignment.generate(audio: MLXArray(samples), text: result.text, language: "Russian")
        XCTAssertFalse(aligned.items.isEmpty)
        // This raw single-call probe measures the checkpoint independently of
        // the production scheduler. Invalid alignment is recorded, never repaired.
        let mapped = try? QwenASREngine.map(hypothesis: .init(text: result.text, language: result.language),
            aligned: aligned.items.map { .init(text: $0.text, start: $0.startTime, end: $0.endTime) },
            readStart: 0, readEnd: Int((Double(samples.count) / 16).rounded()), core: 0..<Int((Double(samples.count) / 16).rounded()))
        let ended = ProcessInfo.processInfo.systemUptime
        if let path = env["LOCALSCRIBE_QWEN_OUTPUT"] {
            let output = URL(fileURLWithPath: path)
            try Disk.write(["loadSeconds": loaded-start, "asrSeconds": recognized-loaded,
                "alignerLoadSeconds": alignmentLoaded-recognized, "alignmentSeconds": ended-alignmentLoaded,
                "mlxPeakBytes": Double(Memory.peakMemory), "audioSeconds": Double(samples.count)/16000,
                "words": Double(aligned.items.count), "alignmentAccepted": mapped == nil ? 0 : 1], to: output.appendingPathComponent("measurement.json"))
            // Explicit probe artifacts, never production diagnostics.
            try Disk.write(["text": result.text, "language": result.language ?? "unknown"], to: output.appendingPathComponent("hypothesis.json"))
            try Disk.write(aligned.items.map { [$0.startTime, $0.endTime] }, to: output.appendingPathComponent("raw-timings.json"))
        }
    }
}
