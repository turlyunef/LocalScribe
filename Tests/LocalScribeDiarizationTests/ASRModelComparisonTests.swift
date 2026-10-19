import XCTest
import AVFoundation
import LocalScribeCore
@testable import LocalScribeWorker

/// Opt-in real-model comparison on an explicitly supplied technical RU/EN fixture.
/// Run the test process with network denied; never enable SDK transcript logging.
final class ASRModelComparisonTests: XCTestCase {
    func testMixedLanguageFixtureWithBothWindowPolicies() async throws {
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
        let baseline = try await measure(wave: wave, models: models, run: root.appendingPathComponent("baseline"), duration: duration, legacy: true)
        let candidate = try await measure(wave: wave, models: models, run: root.appendingPathComponent("candidate"), duration: duration, legacy: false)
        XCTAssertEqual(try Disk.hash(wave), sourceHash)
        for transcript in [baseline.0, candidate.0] {
            try transcript.validate(durationMs: duration)
            XCTAssertTrue(transcript.segments.contains { $0.language == "ru" || $0.language == "mixed" })
            XCTAssertTrue(transcript.segments.contains { $0.language == "en" || $0.language == "mixed" })
        }
        XCTAssertLessThanOrEqual(candidate.0.segments.map(\.startMs).min() ?? duration,
                                 (baseline.0.segments.map(\.startMs).min() ?? 0) + 1500)
        XCTAssertGreaterThanOrEqual(candidate.0.segments.map(\.endMs).max() ?? 0,
                                    (baseline.0.segments.map(\.endMs).max() ?? duration) - 1500)
        XCTAssertLessThanOrEqual(candidate.1.primary.inputs.maximumMs, 30000)
        let baselineCoverage = coverage(baseline.0), candidateCoverage = coverage(candidate.0)
        for key in ["russianCharacters", "englishCharacters"] {
            XCTAssertGreaterThanOrEqual(candidateCoverage[key] ?? 0, (baselineCoverage[key] ?? 0) * 8 / 10,
                                       "Large loss of either script indicates a missed or translated utterance")
        }
        if let output = environment["LOCALSCRIBE_ASR_PROBE_OUTPUT"] {
            let destination = URL(fileURLWithPath: output)
            try Disk.write(baseline.1, to: destination.appendingPathComponent("baseline-metrics.json"))
            try Disk.write(candidate.1, to: destination.appendingPathComponent("candidate-metrics.json"))
            // Numeric coverage only; metrics and diagnostics never persist text.
            let coverage = ["baseline": coverage(baseline.0), "candidate": coverage(candidate.0)]
            try Disk.write(coverage, to: destination.appendingPathComponent("coverage.json"))
            let intervals = ["baseline": baseline.0.segments.map { [$0.startMs, $0.endMs] },
                             "candidate": candidate.0.segments.map { [$0.startMs, $0.endMs] }]
            try Disk.write(intervals, to: destination.appendingPathComponent("intervals.json"))
        }
    }

    private func coverage(_ transcript: Transcript) -> [String: Int] {
        ["segments": transcript.segments.count,
         "russianCharacters": transcript.segments.reduce(0) { $0 + $1.text.unicodeScalars.filter { (0x400...0x52f).contains($0.value) }.count },
         "englishCharacters": transcript.segments.reduce(0) { $0 + $1.text.unicodeScalars.filter { (65...90).contains($0.value) || (97...122).contains($0.value) }.count },
         "firstStartMs": transcript.segments.map(\.startMs).min() ?? 0,
         "lastEndMs": transcript.segments.map(\.endMs).max() ?? 0]
    }

    private func measure(wave: URL, models: URL, run: URL, duration: Int, legacy: Bool) async throws -> (Transcript, ASRMetrics) {
        let metrics = ASRMetricsRecorder(run: run, liveCapture: false, windowPolicy: legacy ? "first-pause-with-gap-recovery" : "late-pause-v2-gap-recovery")
        let info = RunInfo(sourceHash: "technical-fixture", profileHash: "technical-fixture")
        let recognizer = try await SpeechRecognizer(info: info, models: models, metrics: metrics,
            windowLength: { legacy ? Self.legacyWindowLength($0) : Analysis.nextASRWindowLength($0) }, warning: { _ in })
        let segments = try await recognizer.recognize(wave: wave, coreStart: 0, coreEnd: duration, durationMs: duration)
        metrics.finish(status: "completed")
        // Production assigns stable unique IDs at the part boundary.
        var identified = segments
        for index in identified.indices { identified[index].id = "fixture-\(index)" }
        return (Transcript(fingerprint: info.fingerprint, diarized: false, segments: identified), metrics.value)
    }

    private static func legacyWindowLength(_ samples: [Float]) -> Int {
        let block = 320, minimum = 32000, pause = 30
        guard samples.count > minimum else { return samples.count }
        var quiet = 0
        for start in stride(from: 0, to: samples.count, by: block) {
            let end = min(samples.count, start + block)
            var energy: Float = 0
            for index in start..<end { energy += samples[index] * samples[index] }
            quiet = energy / Float(end - start) < 1e-6 ? quiet + 1 : 0
            if quiet >= pause, start >= minimum { return min(samples.count, start - block * pause / 2) }
        }
        return samples.count
    }
}
