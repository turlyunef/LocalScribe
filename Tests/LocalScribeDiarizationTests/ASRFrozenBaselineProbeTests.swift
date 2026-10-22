import XCTest
import AVFoundation
import LocalScribeCore
import CWorkerIsolation
import WhisperKit
@testable import LocalScribeWorker

/// Explicit probe artifacts only. Never reads or publishes application checkpoints.
final class ASRFrozenBaselineProbeTests: XCTestCase {
    struct Interval: Codable, Equatable {
        var id: String
        var startMs: Int
        var endMs: Int
    }
    struct Window: Codable, Equatable {
        var partIndex: Int
        var coreStartMs: Int
        var coreEndMs: Int
        var readStartMs: Int
        var readEndMs: Int
        var silent: Bool
        var selected: Bool
        var requests: [ASRContextReviewRequest]
        var deferredTargets: Int
        var unchangedContextTargets: Int
    }
    private struct Input: Codable {
        var schemaVersion: Int
        var sourceType: String
        var sourceHash: String
        var waveHash: String
        var wavePath: String
        var modelsPath: String
        var run: RunInfo
        var catalog: ModelCatalog
    }
    private struct Plan: Codable, Equatable {
        var schemaVersion = 1
        var sourceHash: String
        var waveHash: String
        var durationMs: Int
        var intervals: [Interval]
        // C has no per-window prefix-call history. Exclude every possible prefix
        // input conservatively, rather than claiming to reconstruct that history.
        var prefixContextPolicy = "exclude-all-possible-prefix-inputs-history-unavailable"
        var windows: [Window]
    }
    private struct Info: Codable {
        var schemaVersion = 1
        var mode = "selective-context-from-frozen-C"
        var algorithmVersion = ASRWordRepair.version
        var sourceHash: String
        var waveHash: String
        var baselineReuse = true
        var newPrimaryCalls = 0
        var newPrefixCalls = 0
        var newModelCalls: Int
        var proposedEdits: Int
        var reviewedWindows: Int
        var thermalStateBefore: Int
        var thermalStateAfter: Int
        var networkDenied = true
    }

    static func windows(wave: URL, duration: Int, intervals: [Interval], parts: [ASRPart]) throws -> [Window] {
        var windows: [Window] = []
        for part in parts {
            var offset = part.startMs
            while offset < part.endMs {
                try Task.checkCancellation()
                let planning = try Media.samples(wave, start: Double(offset) / 1000,
                    duration: Double(min(part.endMs - offset, Analysis.asrCoreWindowMs)) / 1000)
                let end = min(part.endMs, offset + max(1, Analysis.nextASRWindowLength(planning, policy: .latePause) / 16))
                let readStart = max(0, offset - 1000), readEnd = min(duration, end + 1000)
                let samples = try Media.samples(wave, start: Double(readStart) / 1000, duration: Double(readEnd - readStart) / 1000)
                let silent = samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(max(1, samples.count)) <= 1e-12
                let selected = intervals.contains { $0.startMs < end && offset < $0.endMs }
                let recognized = ASRContextReviewPlanner.ownedSegments(part.segments, startMs: offset, endMs: end)
                let prefixEnd = min(duration, readStart + 30_000)
                let prefixStart = max(0, prefixEnd - 30_000)
                let reviewPlan = ASRContextReviewPlanner.plan(segments: recognized, samples: samples,
                    readStartMs: readStart, readEndMs: readEnd, coreStartMs: offset, coreEndMs: end,
                    originMs: 0, durationMs: duration, previousContexts: [prefixStart..<prefixEnd])
                let requests = selected && !silent ? reviewPlan.requests.filter { request in
                    intervals.contains { $0.startMs < request.endMs && request.startMs < $0.endMs }
                } : []
                windows.append(Window(partIndex: part.index, coreStartMs: offset, coreEndMs: end,
                    readStartMs: readStart, readEndMs: readEnd, silent: silent, selected: selected,
                    requests: requests, deferredTargets: selected ? reviewPlan.deferredTargets : 0,
                    unchangedContextTargets: selected ? reviewPlan.unchangedContextTargets : 0))
                offset = end
            }
        }
        return windows
    }

    func testReconstructionStartsAtRealPartOriginsAndKeepsShortTail() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let wave = root.appendingPathComponent("fixture.wav")
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000))
        for index in 0..<16000 { buffer.floatChannelData![0][index] = 0.1 }
        try autoreleasepool {
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false]
            let file = try AVAudioFile(forWriting: wave, settings: settings)
            buffer.frameLength = 16000
            for _ in 0..<605 { try file.write(from: buffer) }
            buffer.frameLength = 4800
            try file.write(from: buffer)
        }
        let parts = [0, 300_000, 600_000].enumerated().map { index, start in
            ASRPart(fingerprint: "fixture", index: index, startMs: start,
                endMs: min(605_300, start + 300_000), segments: [])
        }
        let windows = try Self.windows(wave: wave, duration: 605_300,
            intervals: [Interval(id: "control", startMs: 158_000, endMs: 179_000)], parts: parts)
        XCTAssertEqual(windows.first?.coreStartMs, 0)
        XCTAssertEqual(windows.last?.coreEndMs, 605_300)
        XCTAssertEqual(windows.last?.coreStartMs, 600_000)
        XCTAssertEqual(windows.filter { $0.partIndex == 1 }.first?.coreStartMs, 300_000)
        XCTAssertEqual(windows.filter(\.selected).map(\.coreStartMs), [140_000, 168_000])
        for (left, right) in zip(windows, windows.dropFirst()) { XCTAssertEqual(left.coreEndMs, right.coreStartMs) }
        for window in windows {
            XCTAssertLessThanOrEqual(window.readEndMs - window.readStartMs, 30_000)
            XCTAssertEqual(window.readStartMs, max(0, window.coreStartMs - 1000))
            for request in window.requests {
                XCTAssertLessThanOrEqual(request.contextEndMs, 605_300)
                XCTAssertGreaterThanOrEqual(request.contextStartMs, 0)
            }
        }
    }

    func testExplicitFrozenBaselineContext() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["LOCALSCRIBE_ASR_FROZEN_PROBE"] == "technical-probe",
              let outputPath = env["LOCALSCRIBE_ASR_MATRIX_OUTPUT"],
              let phase = env["LOCALSCRIBE_ASR_FROZEN_PHASE"], ["plan", "recognize"].contains(phase) else {
            throw XCTSkip("Use --context-from-baseline with a fresh technical output directory")
        }
        let output = URL(fileURLWithPath: outputPath), destination = output.appendingPathComponent("E")
        var metrics: ASRMetricsRecorder?
        do {
            guard localscribe_deny_network() == 0 else { throw ScribeError.message("Не удалось запретить сеть") }
            try Disk.write(["stage": "validating-frozen-baseline"], to: output.appendingPathComponent("frozen-state.json"))
            let input = try Disk.read(Input.self, at: output.appendingPathComponent("input.json"))
            let baseline = try Disk.read(Input.self, at: output.appendingPathComponent("baseline-input.json"))
            let wave = URL(fileURLWithPath: input.wavePath), models = URL(fileURLWithPath: input.modelsPath)
            let file = try AVAudioFile(forReading: wave)
            let duration = Int((Double(file.length) / 16).rounded())
            guard input.schemaVersion == 1, input.sourceType == "technical-probe",
                  input.sourceHash == input.run.sourceHash, input.sourceHash == baseline.sourceHash,
                  input.waveHash == baseline.waveHash, try Disk.hash(wave) == input.waveHash,
                  input.run.id == baseline.run.id, input.run.profileHash == baseline.run.profileHash,
                  input.run.pipelineVersion == baseline.run.pipelineVersion, input.run.modelIDs == baseline.run.modelIDs,
                  duration > 0, duration <= 10_800_000,
                  file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1 else {
                throw ScribeError.message("Несовместимый вход замороженного сравнения")
            }
            let pinned = try input.catalog.pinned(to: input.run)
            for model in pinned.models where model.purpose == .asr || model.purpose == .tokenizer { try model.validate(at: models) }
            let intervals = try Disk.read([Interval].self, at: output.appendingPathComponent("control-intervals.json"))
            var previousEnd = 0
            for interval in intervals {
                guard previousEnd <= interval.startMs, interval.startMs < interval.endMs, interval.endMs <= duration else {
                    throw ScribeError.message("Некорректные контрольные интервалы")
                }
                previousEnd = interval.endMs
            }
            var parts: [ASRPart] = []
            for start in stride(from: 0, to: duration, by: 300_000) {
                let index = parts.count
                let part = try Disk.read(ASRPart.self, at: output.appendingPathComponent("C/parts/part-\(index).json"))
                guard part.index == index, part.startMs == start, part.endMs == min(duration, start + 300_000) else {
                    throw ScribeError.message("Изменились внешние границы C")
                }
                parts.append(part)
            }
            let transcript = try Disk.read(Transcript.self, at: output.appendingPathComponent("C/transcript.json"))
            try transcript.validate(durationMs: duration)
            guard Analysis.mergeParts(parts, fingerprint: transcript.fingerprint) == transcript else {
                throw ScribeError.message("Части C не соответствуют итоговой гипотезе")
            }
            let plan = Plan(sourceHash: input.sourceHash, waveHash: input.waveHash, durationMs: duration,
                intervals: intervals, windows: try Self.windows(wave: wave, duration: duration, intervals: intervals, parts: parts))
            let baselineMetrics = try Disk.read(ASRMetrics.self, at: output.appendingPathComponent("C/metrics-asr.json"))
            var lengths = ASRWindowLengths(), primaryInputs = ASRWindowLengths()
            for window in plan.windows {
                lengths.add(window.coreEndMs - window.coreStartMs)
                if !window.silent { primaryInputs.add(window.readEndMs - window.readStartMs) }
            }
            func sameLengths(_ a: ASRWindowLengths, _ b: ASRWindowLengths) -> Bool {
                a.count == b.count && a.totalMs == b.totalMs && a.minimumMs == b.minimumMs
                    && a.maximumMs == b.maximumMs && a.histogram == b.histogram
            }
            guard baselineMetrics.status == "completed", baselineMetrics.checkpointHits == 0,
                  sameLengths(lengths, baselineMetrics.plannedWindows), sameLengths(primaryInputs, baselineMetrics.primary.inputs),
                  plan.windows.filter(\.silent).count == baselineMetrics.silentWindows,
                  try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("C/decoding-options.json"))) as? NSDictionary
                    == JSONSerialization.jsonObject(with: JSONEncoder().encode(SpeechRecognizer.decodingOptions)) as? NSDictionary else {
                throw ScribeError.message("План или декодер не соответствует C")
            }
            let planPath = output.appendingPathComponent("frozen-plan.json")
            if phase == "plan" {
                guard !FileManager.default.fileExists(atPath: planPath.path) else { throw ScribeError.message("План уже существует") }
                try Disk.write(plan, to: planPath)
                try Disk.write(["stage": "planned"], to: output.appendingPathComponent("frozen-state.json"))
                return
            }
            guard try Disk.read(Plan.self, at: planPath) == plan,
                  !FileManager.default.fileExists(atPath: destination.path) else { throw ScribeError.message("Нужен неизменный план и новый результат") }
            let before = ProcessInfo.processInfo.thermalState.rawValue
            let recorder = ASRMetricsRecorder(run: destination, liveCapture: false, windowPolicy: "frozen-C-selective-context")
            metrics = recorder
            try Disk.write(SpeechRecognizer.decodingOptions, to: destination.appendingPathComponent("decoding-options.json"))
            let recognizer = try await SpeechRecognizer(info: input.run, models: models, metrics: recorder, warning: { _ in })
            var reviewedWindows = 0, edits = 0
            for window in plan.windows where window.selected {
                try Task.checkCancellation()
                recorder.window(milliseconds: window.coreEndMs - window.coreStartMs, silent: window.silent)
                let recognized = ASRContextReviewPlanner.ownedSegments(parts[window.partIndex].segments,
                    startMs: window.coreStartMs, endMs: window.coreEndMs)
                var reviews: [ASRContextReview] = []
                var cached: (request: ASRContextReviewRequest, results: [TranscriptionResult])?
                for request in window.requests {
                    try Task.checkCancellation()
                    let results: [TranscriptionResult]
                    if let cached, cached.request.contextStartMs == request.contextStartMs, cached.request.contextEndMs == request.contextEndMs {
                        results = cached.results
                    } else {
                        let samples = try Media.samples(wave, start: Double(request.contextStartMs) / 1000,
                            duration: Double(request.contextEndMs - request.contextStartMs) / 1000)
                        results = try await recognizer.decode(samples, options: SpeechRecognizer.decodingOptions, phase: .contextReview)
                        try Task.checkCancellation()
                        cached = (request, results)
                    }
                    let candidate = recognizer.mappedSegments(results, readStart: request.contextStartMs,
                        start: request.startMs, end: request.endMs, durationMs: duration)
                    let original = ASRContextReviewPlanner.ownedSegments(recognized, startMs: request.startMs, endMs: request.endMs)
                    let repair = ASRWordRepair.propose(original: original, candidate: candidate, startMs: request.startMs, endMs: request.endMs)
                    edits += repair.edits.count
                    reviews.append(ASRContextReview(request: request, original: original, candidate: candidate, wordRepair: repair))
                }
                try Disk.write(ASRContextReviewBatch(coreStartMs: window.coreStartMs, coreEndMs: window.coreEndMs,
                    deferredTargets: window.deferredTargets, unchangedContextTargets: window.unchangedContextTargets, reviews: reviews),
                    to: destination.appendingPathComponent("context-reviews/window-\(window.coreStartMs).json"))
                reviewedWindows += 1
            }
            for model in pinned.models where model.purpose == .asr || model.purpose == .tokenizer { try model.validate(at: models) }
            guard try Disk.hash(wave) == input.waveHash else { throw ScribeError.message("Изменился PCM") }
            try Disk.write(Info(sourceHash: input.sourceHash, waveHash: input.waveHash,
                newModelCalls: recorder.value.contextReview?.inputs.count ?? 0, proposedEdits: edits, reviewedWindows: reviewedWindows,
                thermalStateBefore: before, thermalStateAfter: ProcessInfo.processInfo.thermalState.rawValue),
                to: destination.appendingPathComponent("selective-info.json"))
            recorder.finish(status: "completed")
            try Disk.write(["stage": "completed"], to: output.appendingPathComponent("frozen-state.json"))
        } catch {
            metrics?.finish(status: error is CancellationError ? "cancelled" : "failed")
            try? Disk.write(["stage": "failed", "errorType": String(reflecting: type(of: error)), "errorCode": String((error as NSError).code)],
                to: output.appendingPathComponent("frozen-state.json"))
            XCTFail("Frozen baseline probe failed; SDK output is discarded")
        }
    }
}
