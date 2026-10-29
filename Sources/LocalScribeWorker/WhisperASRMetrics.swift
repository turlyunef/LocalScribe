import WhisperKit

// SDK field interpretation stays with the adapter. The persisted numeric schema
// remains compatible with existing metrics-asr.json diagnostics.
extension ASRCallMetrics {
    mutating func addWhisperTimings(_ results: [TranscriptionResult]) {
        for result in results {
            let timing = result.timings
            encoderSeconds += finite(timing.encoding)
            encoderRuns += finite(timing.totalEncodingRuns)
            decoderInferenceSeconds += finite(timing.decodingPredictions)
            decoderTokenLoops += finite(timing.totalDecodingLoops)
            wordAlignmentSeconds += finite(timing.decodingWordTimestamps)
            logMelSeconds += finite(timing.logmels)
            sdkDecodingLoopSeconds += finite(timing.decodingLoop)
            sdkReportedFallbacks += finite(timing.totalDecodingFallbacks)
        }
    }

    private func finite(_ value: Double) -> Double { value.isFinite && value >= 0 ? value : 0 }
}

extension ASRMetricsRecorder {
    func finishWhisperCall(seconds: Double, phase: ASRCallPhase, results: [TranscriptionResult]?) {
        let measurements = results.map { results in
            var value = ASRCallMetrics()
            value.addWhisperTimings(results)
            return value
        }
        finishCall(seconds: seconds, phase: phase, measurements: measurements)
    }
}
