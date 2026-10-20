import XCTest
import AVFoundation
import LocalScribeCore
@testable import LocalScribeWorker

/// Opt-in restored-policy check on an explicitly supplied technical RU/EN fixture.
/// Run the test process with network denied; never enable SDK transcript logging.
final class ASRModelFixtureTests: XCTestCase {
    func testMixedLanguageFixtureWithRestoredWindowPolicy() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelsPath = environment["LOCALSCRIBE_ASR_FIXTURE_MODELS"],
              let wavePath = environment["LOCALSCRIBE_ASR_FIXTURE_WAV"] else {
            throw XCTSkip("Set LOCALSCRIBE_ASR_FIXTURE_MODELS and LOCALSCRIBE_ASR_FIXTURE_WAV to local technical fixtures")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let wave = URL(fileURLWithPath: wavePath), models = URL(fileURLWithPath: modelsPath)
        let file = try AVAudioFile(forReading: wave)
        XCTAssertEqual(file.processingFormat.sampleRate, 16000)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        let duration = Int((Double(file.length) / 16).rounded())
        let sourceHash = try Disk.hash(wave)
        let (transcript, metrics) = try await measure(wave: wave, models: models, run: root, duration: duration)
        XCTAssertEqual(try Disk.hash(wave), sourceHash)
        try transcript.validate(durationMs: duration)
        XCTAssertTrue(transcript.segments.contains { $0.language == "ru" || $0.language == "mixed" })
        XCTAssertTrue(transcript.segments.contains { $0.language == "en" || $0.language == "mixed" })
        XCTAssertLessThanOrEqual(metrics.primary.inputs.maximumMs, 30000)
        XCTAssertEqual(metrics.gapRecovery.inputs.count, 0)
        XCTAssertEqual(metrics.windowPolicy, "first-pause-prefix-recovery")
        if let output = environment["LOCALSCRIBE_ASR_PROBE_OUTPUT"] {
            let destination = URL(fileURLWithPath: output)
            try Disk.write(metrics, to: destination.appendingPathComponent("metrics.json"))
            // Numeric coverage only; metrics and diagnostics never persist text.
            try Disk.write(coverage(transcript), to: destination.appendingPathComponent("coverage.json"))
            try Disk.write(transcript.segments.map { [$0.startMs, $0.endMs] }, to: destination.appendingPathComponent("intervals.json"))
        }
    }

    private func coverage(_ transcript: Transcript) -> [String: Int] {
        ["segments": transcript.segments.count,
         "russianCharacters": transcript.segments.reduce(0) { $0 + $1.text.unicodeScalars.filter { (0x400...0x52f).contains($0.value) }.count },
         "englishCharacters": transcript.segments.reduce(0) { $0 + $1.text.unicodeScalars.filter { (65...90).contains($0.value) || (97...122).contains($0.value) }.count },
         "firstStartMs": transcript.segments.map(\.startMs).min() ?? 0,
         "lastEndMs": transcript.segments.map(\.endMs).max() ?? 0]
    }

    private func measure(wave: URL, models: URL, run: URL, duration: Int) async throws -> (Transcript, ASRMetrics) {
        let metrics = ASRMetricsRecorder(run: run, liveCapture: false)
        let info = RunInfo(sourceHash: "technical-fixture", profileHash: "technical-fixture")
        let recognizer = try await SpeechRecognizer(info: info, models: models, metrics: metrics, warning: { _ in })
        let segments = try await recognizer.recognize(wave: wave, coreStart: 0, coreEnd: duration, durationMs: duration)
        metrics.finish(status: "completed")
        // Production assigns stable unique IDs at the part boundary.
        var identified = segments
        for index in identified.indices { identified[index].id = "fixture-\(index)" }
        return (Transcript(fingerprint: info.fingerprint, diarized: false, segments: identified), metrics.value)
    }
}
