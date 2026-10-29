import Foundation
import LocalScribeCore

enum ASRCallPhase { case primary, prefixRecovery, gapRecovery, contextReview }

/// Bounded numeric diagnostics. No text, tokens, source IDs, paths or SDK errors.
struct ASRWindowLengths: Codable {
    var count = 0
    var totalMs = 0
    var minimumMs = 0
    var maximumMs = 0
    var meanMs = 0.0
    // [0,5), [5,10), [10,20), [20,28), [28,30], >30 seconds.
    var histogram = [Int](repeating: 0, count: 6)

    mutating func add(_ milliseconds: Int) {
        minimumMs = count == 0 ? milliseconds : min(minimumMs, milliseconds)
        maximumMs = max(maximumMs, milliseconds)
        count += 1; totalMs += milliseconds
        meanMs = Double(totalMs) / Double(count)
        let bucket = milliseconds < 5000 ? 0 : milliseconds < 10000 ? 1 : milliseconds < 20000 ? 2 : milliseconds < 28000 ? 3 : milliseconds <= 30000 ? 4 : 5
        histogram[bucket] += 1
    }
}

/// Historical Whisper diagnostics, not mandatory metrics for other ASR engines.
struct ASRCallMetrics: Codable {
    var inputs = ASRWindowLengths()
    var completedCalls = 0
    var failedCalls = 0
    var wallSeconds = 0.0
    var encoderSeconds = 0.0
    var encoderRuns = 0.0
    var decoderInferenceSeconds = 0.0
    var decoderTokenLoops = 0.0
    var wordAlignmentSeconds = 0.0
    var logMelSeconds = 0.0
    // SDK decodingLoop includes encoder and alignment; it is NOT decoder time.
    var sdkDecodingLoopSeconds = 0.0
    // WhisperKit 1.1.1 assigns a zero-based attempt index, not a total count.
    // Preserve the raw value without presenting it as an exact retry count.
    var sdkReportedFallbacks = 0.0
}

struct ASRMetrics: Codable {
    var schemaVersion = 1
    var backend: String?
    var backendASRSeconds: Double?
    var backendAlignmentSeconds: Double?
    var status = "running"
    var startedAt = Date()
    var elapsedSeconds = 0.0
    var modelLoadSeconds = 0.0
    var liveCapture: Bool
    var windowPolicy = "first-pause-prefix-recovery"
    var plannedWindows = ASRWindowLengths()
    var silentWindows = 0
    var checkpointHits = 0
    var checkpointAudioMs = 0
    var unrecoveredPrefixes = 0
    // Retained for numeric diagnostic compatibility; asr7 does not retry gaps.
    var unrecoveredGaps = 0
    var primary = ASRCallMetrics()
    var prefixRecovery = ASRCallMetrics()
    var gapRecovery = ASRCallMetrics()
    // Optional: historical metrics remain readable; shipping ASR leaves it absent.
    var contextReview: ASRCallMetrics?

    mutating func update(_ phase: ASRCallPhase, _ body: (inout ASRCallMetrics) -> Void) {
        switch phase {
        case .primary: body(&primary)
        case .prefixRecovery: body(&prefixRecovery)
        case .gapRecovery: body(&gapRecovery)
        case .contextReview:
            var call = contextReview ?? ASRCallMetrics()
            body(&call)
            contextReview = call
        }
    }
}

/// Owned by one sequential ASR invocation; never accessed from SDK callbacks.
/// Resumption starts fresh counters and records cached parts separately.
final class ASRMetricsRecorder {
    private let destination: URL
    private let started = ProcessInfo.processInfo.systemUptime
    private(set) var value: ASRMetrics

    init(run: URL, liveCapture: Bool, windowPolicy: String = "first-pause-prefix-recovery") {
        destination = run.appendingPathComponent("metrics-asr.json")
        value = ASRMetrics(liveCapture: liveCapture)
        value.windowPolicy = windowPolicy
        save()
    }

    func backend(_ id: String, policy: String) {
        value.backend = id; value.windowPolicy = policy; save()
    }
    func backendCall(seconds: Double, alignment: Bool) {
        if alignment { value.backendAlignmentSeconds = (value.backendAlignmentSeconds ?? 0) + seconds }
        else { value.backendASRSeconds = (value.backendASRSeconds ?? 0) + seconds }
        save()
    }
    func modelLoaded(seconds: Double) {
        value.modelLoadSeconds += seconds
        save()
    }

    func window(milliseconds: Int, silent: Bool) {
        value.plannedWindows.add(milliseconds)
        if silent { value.silentWindows += 1 }
        save()
    }

    func startCall(samples: Int, phase: ASRCallPhase) {
        value.update(phase) { $0.inputs.add(samples / 16) }
        save()
    }

    func finishCall(seconds: Double, phase: ASRCallPhase, measurements: ASRCallMetrics?) {
        value.update(phase) { call in
            call.wallSeconds += seconds
            guard let measurements else { call.failedCalls += 1; return }
            call.completedCalls += 1
            call.encoderSeconds += measurements.encoderSeconds
            call.encoderRuns += measurements.encoderRuns
            call.decoderInferenceSeconds += measurements.decoderInferenceSeconds
            call.decoderTokenLoops += measurements.decoderTokenLoops
            call.wordAlignmentSeconds += measurements.wordAlignmentSeconds
            call.logMelSeconds += measurements.logMelSeconds
            call.sdkDecodingLoopSeconds += measurements.sdkDecodingLoopSeconds
            call.sdkReportedFallbacks += measurements.sdkReportedFallbacks
        }
        save()
    }

    func missingPrefix() { value.unrecoveredPrefixes += 1; save() }
    func missingGap() { value.unrecoveredGaps += 1; save() }

    func checkpoint(milliseconds: Int) {
        value.checkpointHits += 1
        value.checkpointAudioMs += milliseconds
        save()
    }

    func finish(status: String) { value.status = status; save() }

    private func save() {
        value.elapsedSeconds = ProcessInfo.processInfo.systemUptime - started
        // Diagnostics must not invalidate a valid recognition/checkpoint.
        try? Disk.write(value, to: destination)
    }
}
