import Foundation

public struct VoiceInterval: Codable, Sendable {
    public var startMs: Int; public var endMs: Int; public var speakerId: String
    public init(startMs: Int, endMs: Int, speakerId: String) { self.startMs = startMs; self.endMs = endMs; self.speakerId = speakerId }
    /// Model padding is context, never part of the published recording timeline.
    public static func clipped(startSeconds: Double, endSeconds: Double, speakerId: String, durationMs: Int) -> VoiceInterval? {
        guard durationMs > 0, startSeconds.isFinite, endSeconds.isFinite else { return nil }
        let duration = Double(durationMs) / 1000
        let start = min(durationMs, Int(max(0, min(duration, startSeconds)) * 1000))
        let end = min(durationMs, Int(max(0, min(duration, endSeconds)) * 1000))
        guard start < end else { return nil }
        return VoiceInterval(startMs: start, endMs: end, speakerId: speakerId)
    }
}
public struct DiarizationArtifact: Codable, Sendable {
    public var schemaVersion = 1; public var fingerprint: String; public var intervals: [VoiceInterval]
    public init(fingerprint: String, intervals: [VoiceInterval]) { self.fingerprint = fingerprint; self.intervals = intervals }
}
public struct ASRPart: Codable, Sendable {
    public var schemaVersion = 1; public var fingerprint: String; public var index: Int
    public var startMs: Int; public var endMs: Int; public var segments: [Segment]
    public init(fingerprint: String, index: Int, startMs: Int, endMs: Int, segments: [Segment]) { self.fingerprint = fingerprint; self.index = index; self.startMs = startMs; self.endMs = endMs; self.segments = segments }
}
public enum Analysis {
    // Leave room for a second of context on each side of Whisper's 30 s input.
    public static let asrCoreWindowMs = 28_000

    /// Energy is only a reason to retry, never evidence that decoded words exist.
    /// Ignore a short alignment delay and require sustained sound, so leading
    /// silence does not trigger retries or get moved to timestamp zero.
    public static func missingASRPrefixEnd(segments: [Segment], samples: [Float], readStartMs: Int, coreStartMs: Int, coreEndMs: Int, rate: Int = 16000) -> Int? {
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

    /// Longer inputs can omit an internal utterance, notably a language switch.
    /// Retry only uncovered gaps between/after segments. Energy is a retry hint,
    /// never permission to invent words or discard quiet input. Prefix recovery
    /// remains separate because it needs the wider real context from asr5.
    public static func missingASRInteriorRanges(segments: [Segment], samples: [Float], readStartMs: Int,
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
            // Exclude alignment uncertainty at both boundaries.
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

    /// Prefer the last complete pause in the second half of a 28 s window.
    /// Short pauses remain inside the input; quietness never discards speech.
    public static func nextASRWindowLength(_ samples: [Float], rate: Int = 16000) -> Int {
        let limit = min(samples.count, rate * asrCoreWindowMs / 1000)
        let block = max(1, rate / 50), minimum = rate * 14, pause = rate * 3 / 5
        guard limit > minimum else { return limit }
        var quietStart: Int?, boundary: Int?
        for start in stride(from: 0, to: limit, by: block) {
            let end = min(limit, start + block)
            var energy: Float = 0
            for i in start..<end { energy += samples[i] * samples[i] }
            if energy / Float(end-start) < 1e-6 {
                if quietStart == nil { quietStart = start }
            } else if let silenceStart = quietStart {
                let midpoint = (silenceStart + start) / 2
                if start - silenceStart >= pause, midpoint >= minimum, limit - midpoint >= rate {
                    boundary = midpoint
                }
                quietStart = nil
            }
        }
        // An already quiet end is a safe boundary and avoids a tiny silent tail.
        if let quietStart, limit - quietStart >= pause { return limit }
        return boundary ?? limit
    }
    public static func language(_ text: String, fallback: String) -> String {
        let ru = text.unicodeScalars.contains { (0x400...0x52f).contains($0.value) }
        let en = text.unicodeScalars.contains { (65...90).contains($0.value) || (97...122).contains($0.value) }
        return ru && en ? "mixed" : ru ? "ru" : en ? "en" : fallback
    }
    public static func assignSpeakers(_ transcript: Transcript, intervals: [VoiceInterval]) -> Transcript {
        let sorted = intervals.sorted { $0.startMs < $1.startMs }
        var remap: [String: String] = [:]
        for interval in sorted where remap[interval.speakerId] == nil { remap[interval.speakerId] = "speaker-\(remap.count + 1)" }
        var output: [Segment] = [], cursor = 0, active: [VoiceInterval] = []
        for original in transcript.segments.sorted(by: { $0.startMs < $1.startMs }) {
            let words = original.words.isEmpty ? [Word(text: original.text, startMs: original.startMs, endMs: original.endMs)] : original.words
            for word in words {
                while cursor < sorted.count && sorted[cursor].startMs < word.endMs { active.append(sorted[cursor]); cursor += 1 }
                active.removeAll { $0.endMs <= word.startMs }
                let duration = max(1, word.endMs - word.startMs)
                var coverage: [String: Int] = [:]
                for v in active {
                    let overlap = max(0, min(v.endMs, word.endMs) - max(v.startMs, word.startMs))
                    coverage[v.speakerId, default: 0] += overlap
                }
                let candidates = coverage.filter { Double($0.value) / Double(duration) >= 0.25 }.sorted { $0.value > $1.value }
                let overlap = candidates.count > 1
                let speaker = overlap ? nil : candidates.first.flatMap { remap[$0.key] }
                let language = language(word.text, fallback: original.language)
                if let last = output.last, last.speakerId == speaker, last.overlap == overlap,
                   last.uncertain == original.uncertain, word.startMs - last.endMs < 1500, word.endMs - last.startMs < 20_000 {
                    output[output.count-1].text += word.text
                    output[output.count-1].endMs = max(last.endMs, word.endMs)
                    output[output.count-1].words.append(word)
                    output[output.count-1].language = self.language(output[output.count-1].text, fallback: language)
                } else {
                    output.append(Segment(id: "seg-\(String(format: "%06d", output.count))", startMs: word.startMs, endMs: word.endMs, speakerId: speaker, text: word.text, language: language, overlap: overlap, uncertain: original.uncertain, words: original.words.isEmpty ? [] : [word]))
                }
            }
        }
        return Transcript(fingerprint: transcript.fingerprint, diarized: true, segments: output)
    }
    /// Only overlap duplicates are eligible; repeated phrases elsewhere are preserved.
    public static func mergeParts(_ parts: [ASRPart], fingerprint: String) -> Transcript {
        var segments: [Segment] = []
        for part in parts.sorted(by: { $0.index < $1.index }) {
            for var s in part.segments {
                if segments.suffix(8).contains(where: { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == s.text.trimmingCharacters(in: .whitespacesAndNewlines) && min($0.endMs, s.endMs) > max($0.startMs, s.startMs) }) { continue }
                s.id = "seg-\(String(format: "%06d", segments.count))"; segments.append(s)
            }
        }
        return Transcript(fingerprint: fingerprint, diarized: false, segments: segments)
    }
}
