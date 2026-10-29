import Foundation
import LocalScribeCore

enum WhisperWindowPolicy: String, CaseIterable, Sendable {
    case firstPause
    case latePause
}

enum WhisperASRWindowing {
    // Leave room for a second of context on each side of Whisper's 30 s input.
    static let asrCoreWindowMs = 28_000

    /// Energy is only a reason to retry, never evidence that decoded words exist.
    /// Ignore a short alignment delay and require sustained sound, so leading
    /// silence does not trigger retries or get moved to timestamp zero.
    static func missingASRPrefixEnd(segments: [Segment], samples: [Float], readStartMs: Int, coreStartMs: Int, coreEndMs: Int, rate: Int = 16000) -> Int? {
        let end = min(coreEndMs, segments.map(\.startMs).min() ?? coreEndMs)
        guard end - coreStartMs >= 1500 else { return nil }
        let startFrame = max(0, (coreStartMs - readStartMs) * rate / 1000)
        let endFrame = min(samples.count, (end - readStartMs - 500) * rate / 1000)
        guard startFrame < endFrame else { return nil }
        let block = max(1, rate / 50)
        var audibleFrames = 0
        for start in stride(from: startFrame, to: endFrame, by: block) {
            let stop = min(endFrame, start + block)
            var energy: Float = 0
            for i in start..<stop { energy += samples[i] * samples[i] }
            if energy / Float(stop - start) >= 1e-6 { audibleFrames += stop - start }
        }
        return audibleFrames >= rate * 3 / 5 ? end : nil
    }

    /// Choose a pause boundary without deleting silence or moving the original timeline.
    /// Quietness controls splitting only; it never decides whether to discard speech.
    static func nextASRWindowLength(_ samples: [Float], rate: Int = 16000, policy: WhisperWindowPolicy = .firstPause) -> Int {
        if policy == .latePause { return lateASRWindowLength(samples, rate: rate) }
        let block = rate / 50, minimum = rate * 2, pause = 30 // 600 ms
        guard samples.count > minimum else { return samples.count }
        var quiet = 0
        for start in stride(from: 0, to: samples.count, by: block) {
            let end = min(samples.count, start + block)
            var energy: Float = 0
            for i in start..<end { energy += samples[i] * samples[i] }
            if energy / Float(end-start) < 1e-6 { quiet += 1 } else { quiet = 0 }
            if quiet >= pause, start >= minimum { return min(samples.count, start - block * pause / 2) }
        }
        return samples.count
    }

    /// The asr6 window planner, available to the explicit comparison probe.
    /// The production default above deliberately remains the asr7 first pause.
    private static func lateASRWindowLength(_ samples: [Float], rate: Int) -> Int {
        let limit = min(samples.count, rate * asrCoreWindowMs / 1000)
        let block = max(1, rate / 50), minimum = rate * 14, pause = rate * 3 / 5
        guard limit > minimum else { return limit }
        var quietStart: Int?, boundary: Int?
        for start in stride(from: 0, to: limit, by: block) {
            let end = min(limit, start + block)
            var energy: Float = 0
            for i in start..<end { energy += samples[i] * samples[i] }
            if energy / Float(end - start) < 1e-6 {
                if quietStart == nil { quietStart = start }
            } else if let silenceStart = quietStart {
                let midpoint = (silenceStart + start) / 2
                if start - silenceStart >= pause, midpoint >= minimum, limit - midpoint >= rate {
                    boundary = midpoint
                }
                quietStart = nil
            }
        }
        if let quietStart, limit - quietStart >= pause { return limit }
        return boundary ?? limit
    }

    /// The asr6 bounded gap heuristic. Energy requests a retry; it does not
    /// establish that speech exists or authorize replacing primary words.
    static func missingASRInteriorRanges(segments: [Segment], samples: [Float], readStartMs: Int,
                                               coreStartMs: Int, coreEndMs: Int, rate: Int = 16000) -> [Range<Int>] {
        let ordered = segments.sorted { $0.startMs < $1.startMs }
        guard let first = ordered.first else { return [] }
        var coveredEnd = max(coreStartMs, first.endMs), gaps: [Range<Int>] = []
        for segment in ordered.dropFirst() {
            let gapEnd = min(coreEndMs, segment.startMs)
            if gapEnd > coveredEnd { gaps.append(coveredEnd..<gapEnd) }
            coveredEnd = max(coveredEnd, segment.endMs)
        }
        if coveredEnd < coreEndMs { gaps.append(coveredEnd..<coreEndMs) }
        return gaps.filter { gap in
            guard gap.count >= 1500 else { return false }
            let startFrame = max(0, (gap.lowerBound + 500 - readStartMs) * rate / 1000)
            let endFrame = min(samples.count, (gap.upperBound - 500 - readStartMs) * rate / 1000)
            guard startFrame < endFrame else { return false }
            let block = max(1, rate / 50)
            var audibleFrames = 0
            for start in stride(from: startFrame, to: endFrame, by: block) {
                let end = min(endFrame, start + block)
                var energy: Float = 0
                for index in start..<end { energy += samples[index] * samples[index] }
                if energy / Float(end - start) >= 1e-6 { audibleFrames += end - start }
            }
            return audibleFrames >= rate * 3 / 5
        }
    }
}
