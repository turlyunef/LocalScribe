import XCTest
import AVFoundation
import CWorkerIsolation
import LocalScribeCore
import WhisperKit
@testable import LocalScribeWorker

/// Session 4: disclosed PCM only, real outer boundaries and bounded closed-CAF replay.
/// This exercises SpeechRecognizer, not microphone capture or production checkpoints.
final class ASRBoundaryProbeTests: XCTestCase {
    private final class WarningCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }
    typealias Input = ASRSettingsProbeTests.Input
    struct Window: Codable, Equatable {
        var sourceID: String
        var startMs: Int; var endMs: Int
        var outerStartMs: Int; var outerEndMs: Int
        var originMs: Int; var availableEndMs: Int
    }
    struct Retry: Codable {
        var id: String; var sourceID: String
        var startMs: Int; var endMs: Int
        var targetStartMs: Int; var targetEndMs: Int
    }
    struct Call: Codable {
        var startMs: Int; var endMs: Int
        var options: DecodingOptions
        var results: [TranscriptionResult]
    }
    struct Output: Codable {
        var window: Window
        var calls: [Call]
        var segments: [Segment]
        var warnings: Int
    }

    private func plan(_ input: Input, live: Bool) throws -> [Window] {
        var windows: [Window] = []
        for source in input.sources {
            let wave = URL(fileURLWithPath: source.wavePath)
            for outer in stride(from: 0, to: source.durationMs, by: live ? 30000 : 300000) {
                let outerEnd = min(source.durationMs, outer + (live ? 30000 : 300000))
                var start = outer
                while start < outerEnd {
                    let samples = try Media.samples(wave, start: Double(start) / 1000,
                        duration: Double(min(outerEnd - start, Analysis.asrCoreWindowMs)) / 1000)
                    let end = min(outerEnd, start + max(1, Analysis.nextASRWindowLength(samples) / 16))
                    if source.intervals.contains(where: { $0.startMs < end && start < $0.endMs }) {
                        windows.append(Window(sourceID: source.id, startMs: start, endMs: end,
                            outerStartMs: outer, outerEndMs: outerEnd,
                            originMs: live ? max(0, outer - 1000) / 10000 * 10000 : 0,
                            availableEndMs: live ? min(source.durationMs, outerEnd + 1000) : source.durationMs))
                    }
                    start = end
                }
            }
        }
        return windows
    }

    private func validate(_ input: Input) throws {
        for source in input.sources {
            let url = URL(fileURLWithPath: source.wavePath)
            let file = try AVAudioFile(forReading: url)
            guard try Disk.hash(url) == source.waveHash, file.processingFormat.sampleRate == 16000,
                  file.processingFormat.channelCount == 1, file.length == source.durationMs * 16 else {
                throw ScribeError.message("Изменился исходный PCM")
            }
        }
        let pinned = try input.catalog.pinned(to: input.run)
        for model in pinned.models where model.purpose == .asr || model.purpose == .tokenizer {
            try model.validate(at: URL(fileURLWithPath: input.modelsPath))
        }
    }

    func testExplicitBoundaryProbe() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["LOCALSCRIBE_ASR_BOUNDARY_PROBE"] == "technical-probe",
              let path = env["LOCALSCRIBE_ASR_MATRIX_OUTPUT"],
              let label = env["LOCALSCRIBE_ASR_BOUNDARY_VARIANT"],
              ["plan", "offline", "live", "retries"].contains(label) else {
            throw XCTSkip("Use scripts/probe_asr_boundaries.py in an explicit technical directory")
        }
        let root = URL(fileURLWithPath: path)
        do {
            guard localscribe_deny_network() == 0 else { throw ScribeError.message("Не удалось запретить сеть") }
            let input = try Disk.read(Input.self, at: root.appendingPathComponent("boundary-input.json"))
            guard input.sourceType == "technical-probe" else { throw ScribeError.message("Нужен технический вход") }
            try validate(input)
            if label == "plan" {
                guard ["offline-plan.json", "live-plan.json", "capture"].allSatisfy({
                    !FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
                }) else { throw ScribeError.message("Нужен новый каталог плана") }
                for live in [false, true] {
                    try Disk.write(plan(input, live: live), to: root.appendingPathComponent(live ? "live-plan.json" : "offline-plan.json"))
                }
                // Write and close each ten-second CAF before publishing its name.
                for source in input.sources {
                    let folder = root.appendingPathComponent("capture/\(source.id)")
                    try Disk.directory(folder)
                    let file = try AVAudioFile(forReading: URL(fileURLWithPath: source.wavePath))
                    for index in 0..<Int((file.length + 159999) / 160000) {
                        let count = AVAudioFrameCount(min(160000, file.length - file.framePosition))
                        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count))
                        try file.read(into: buffer, frameCount: count)
                        let partial = folder.appendingPathComponent(String(format: "part-%06d.partial.caf", index))
                        try autoreleasepool {
                            let output = try AVAudioFile(forWriting: partial, settings: file.fileFormat.settings)
                            try output.write(from: buffer)
                        }
                        try FileManager.default.moveItem(at: partial,
                            to: folder.appendingPathComponent(String(format: "part-%06d.caf", index)))
                    }
                    let fragments = try CaptureIntegrity.fragments(at: folder)
                    let seal = CaptureSeal(info: input.run, sourceHash: try Disk.hash(URL(fileURLWithPath: source.wavePath)), fragments: fragments)
                    try CaptureIntegrity.verify(seal, info: input.run, folder: folder, original: URL(fileURLWithPath: source.wavePath))
                    try Disk.write(seal, to: folder.appendingPathComponent("replay-seal.json"))
                }
                return
            }
            let destination = root.appendingPathComponent(label)
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw ScribeError.message("Нужен новый результат") }
            try Disk.directory(destination)
            let recorder = ASRMetricsRecorder(run: destination, liveCapture: label == "live")
            let thermal = ProcessInfo.processInfo.thermalState.rawValue
            let load = ProcessInfo.processInfo.systemUptime
            let models = URL(fileURLWithPath: input.modelsPath)
            let kit = try await WhisperKit(WhisperKitConfig(modelFolder: models.appendingPathComponent(try input.run.modelID(for: .asr)).path,
                tokenizerFolder: models.appendingPathComponent(try input.run.modelID(for: .tokenizer)),
                verbose: false, logLevel: .none, prewarm: true, load: true, download: false))
            recorder.modelLoaded(seconds: ProcessInfo.processInfo.systemUptime - load)
            if label == "retries" {
                let retries = try Disk.read([Retry].self, at: root.appendingPathComponent("retry-plan.json"))
                let mapper = SpeechRecognizer { _, _ in [] }
                for retry in retries {
                    let source = try XCTUnwrap(input.sources.first { $0.id == retry.sourceID })
                    guard retry.startMs >= 0, retry.endMs <= source.durationMs,
                          retry.endMs - retry.startMs <= 30000 else { throw ScribeError.message("Неверный контекст повтора") }
                    let samples = try Media.samples(URL(fileURLWithPath: source.wavePath), start: Double(retry.startMs) / 1000,
                        duration: Double(retry.endMs - retry.startMs) / 1000)
                    let recognizer = SpeechRecognizer(metrics: recorder) { audio, options in
                        try await kit.transcribe(audioArray: audio, decodeOptions: options)
                    }
                    let raw = try await recognizer.decode(samples, options: SpeechRecognizer.decodingOptions, phase: .contextReview)
                    let segments = mapper.mappedSegments(raw, readStart: retry.startMs, start: retry.targetStartMs,
                        end: retry.targetEndMs, durationMs: source.durationMs)
                    try Disk.write(Call(startMs: retry.startMs, endMs: retry.endMs, options: SpeechRecognizer.decodingOptions, results: raw),
                        to: destination.appendingPathComponent("raw/\(retry.id).json"))
                    try Disk.write(segments, to: destination.appendingPathComponent("mapped/\(retry.id).json"))
                }
            } else {
                let live = label == "live"
                let windows = try plan(input, live: live)
                guard windows == (try Disk.read([Window].self, at: root.appendingPathComponent("\(label)-plan.json"))) else {
                    throw ScribeError.message("Изменился план")
                }
                for (index, window) in windows.enumerated() {
                    let source = try XCTUnwrap(input.sources.first { $0.id == window.sourceID })
                    let original = URL(fileURLWithPath: source.wavePath)
                    var wave = original
                    if live {
                        let folder = root.appendingPathComponent("capture/\(source.id)")
                        let seal = try Disk.read(CaptureSeal.self, at: folder.appendingPathComponent("replay-seal.json"))
                        let fragments = seal.fragments.filter { $0.index * 10000 >= window.originMs && $0.index * 10000 < window.availableEndMs }
                        for fragment in fragments { guard try CaptureFragment.read(index: fragment.index, folder: folder) == fragment else { throw ScribeError.message("Изменился CAF") } }
                        wave = destination.appendingPathComponent("input.caf")
                        if FileManager.default.fileExists(atPath: wave.path) { try FileManager.default.removeItem(at: wave) }
                        _ = try Media.assembleCaptureParts(fragments.map { folder.appendingPathComponent($0.filename) }, destination: wave)
                        try Disk.write(fragments, to: destination.appendingPathComponent("fragments/\(index).json"))
                    }
                    var calls: [Call] = []
                    let warnings = WarningCounter()
                    let primaryStart = max(window.originMs, window.startMs - 1000)
                    let primaryEnd = min(window.availableEndMs, window.endMs + 1000)
                    let recognizer = SpeechRecognizer(metrics: recorder, warning: { _ in warnings.increment() }) { samples, options in
                        // One primary plus at most one prefix. No recursive retries.
                        XCTAssertLessThan(calls.count, 2)
                        let end = calls.isEmpty ? primaryEnd : min(window.availableEndMs, primaryStart + 30000)
                        let start = calls.isEmpty ? primaryStart : max(window.originMs, end - 30000)
                        XCTAssertEqual(samples.count, (end - start) * 16)
                        let expected = try Media.samples(original, start: Double(start) / 1000, duration: Double(end - start) / 1000)
                        XCTAssertEqual(samples, expected) // Actual CAF slice, no future or padding.
                        let raw = try await kit.transcribe(audioArray: samples, decodeOptions: options)
                        calls.append(Call(startMs: start, endMs: end, options: options, results: raw))
                        return raw
                    }
                    let segments = try await recognizer.recognize(wave: wave, coreStart: window.startMs,
                        coreEnd: window.endMs, durationMs: window.availableEndMs, originMs: window.originMs)
                    try Disk.write(Output(window: window, calls: calls, segments: segments, warnings: warnings.value),
                        to: destination.appendingPathComponent("windows/\(index).json"))
                    try Disk.write(["completedWindows": index + 1, "plannedWindows": windows.count], to: destination.appendingPathComponent("progress.json"))
                }
            }
            recorder.finish(status: "completed")
            try validate(input)
            try Disk.write(["networkDenied": 1, "thermalBefore": thermal,
                "thermalAfter": ProcessInfo.processInfo.thermalState.rawValue], to: destination.appendingPathComponent("validation.json"))
        } catch {
            try? Disk.write(["errorType": String(reflecting: type(of: error)), "errorCode": String((error as NSError).code)],
                to: root.appendingPathComponent("failure-\(label).json"))
            XCTFail("Boundary probe failed; SDK output discarded")
        }
    }
}
