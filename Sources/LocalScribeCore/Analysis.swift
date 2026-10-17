import Foundation

public struct VoiceInterval: Codable, Sendable {
    public var startMs: Int; public var endMs: Int; public var speakerId: String
    public init(startMs: Int, endMs: Int, speakerId: String) { self.startMs = startMs; self.endMs = endMs; self.speakerId = speakerId }
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
    /// Choose a pause boundary without deleting silence or moving the original timeline.
    /// Quietness controls splitting only; it never decides whether to discard speech.
    public static func nextASRWindowLength(_ samples: [Float], rate: Int = 16000) -> Int {
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
