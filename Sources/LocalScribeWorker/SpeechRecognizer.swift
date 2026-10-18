import Foundation
import LocalScribeCore
import WhisperKit

final class SpeechRecognizer {
    private let kit: WhisperKit
    private let warning: @Sendable (String) -> Void
    init(info: RunInfo, models: URL, warning: @escaping @Sendable (String) -> Void) async throws {
        self.warning = warning
        let folder = models.appendingPathComponent(try info.modelID(for: .asr)), tokenizer = models.appendingPathComponent(try info.modelID(for: .tokenizer))
        guard FileManager.default.fileExists(atPath: tokenizer.appendingPathComponent("tokenizer.json").path), FileManager.default.fileExists(atPath: tokenizer.appendingPathComponent("tokenizer_config.json").path) else { throw ScribeError.message("Отсутствует локальный токенизатор Whisper") }
        kit = try await WhisperKit(WhisperKitConfig(modelFolder: folder.path, tokenizerFolder: tokenizer, verbose: false, logLevel: .none, prewarm: true, load: true, download: false))
    }
    func recognize(wave: URL, coreStart: Int, coreEnd: Int, durationMs: Int, originMs: Int = 0) async throws -> [Segment] {
        var segments: [Segment] = []
        var offset = coreStart
        while offset < coreEnd {
            try Task.checkCancellation()
            let planning = try Media.samples(wave, start: Double(offset-originMs)/1000, duration: Double(min(coreEnd-offset, Analysis.asrCoreWindowMs))/1000)
            let length = max(1, Analysis.nextASRWindowLength(planning) / 16)
            let end = min(coreEnd, offset + length)
            let readStart = max(0, offset - 1000), readEnd = min(durationMs, end + 1000)
            let samples = try Media.samples(wave, start: Double(readStart-originMs)/1000, duration: Double(readEnd-readStart)/1000)
            let energy = samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(max(1, samples.count))
            if energy > 1e-12 {
                // The SDK otherwise skips clips/tails shorter than one second.
                let options = DecodingOptions(verbose: false, task: .transcribe, language: nil, temperatureFallbackCount: 2, detectLanguage: true, skipSpecialTokens: true, wordTimestamps: true, windowClipTime: 0, concurrentWorkerCount: 1)
                let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
                var recognized = mappedSegments(results, readStart: readStart, start: offset, end: end, durationMs: durationMs)
                if let missingEnd = Analysis.missingASRPrefixEnd(segments: recognized, samples: samples, readStartMs: readStart, coreStartMs: offset, coreEndMs: end) {
                    // A pause-sized clip can produce only special tokens (not
                    // necessarily a high noSpeechProb). Retry with up to 30 s
                    // of real context, retaining ownership of the missing prefix.
                    let retryEnd = min(durationMs, readStart + 30_000)
                    let retryStart = max(originMs, retryEnd - 30_000)
                    let context = try Media.samples(wave, start: Double(retryStart-originMs)/1000, duration: Double(retryEnd-retryStart)/1000)
                    let retried = try await kit.transcribe(audioArray: context, decodeOptions: options)
                    let recovered = mappedSegments(retried, readStart: retryStart, start: offset, end: missingEnd, durationMs: durationMs)
                    recognized = recovered + recognized
                    if Analysis.missingASRPrefixEnd(segments: recognized, samples: samples, readStartMs: readStart, coreStartMs: offset, coreEndMs: end) != nil {
                        warning("В интервале \(timecode(offset))–\(timecode(missingEnd)) есть звук, но начало речи не распознано. Прослушайте исходник; можно повторить обработку другой моделью.")
                    }
                }
                segments.append(contentsOf: recognized)
            }
            offset = end
        }
        return segments
    }

    private func mappedSegments(_ results: [TranscriptionResult], readStart: Int, start offset: Int, end: Int, durationMs: Int) -> [Segment] {
        var segments: [Segment] = []
        for result in results {
            for s in result.segments {
                if s.noSpeechProb > 0.6 && s.avgLogprob < -1 { continue }
                let uncertain = s.avgLogprob < -1 || s.compressionRatio > 2.4 || s.noSpeechProb > 0.6
                let hadWords = !(s.words ?? []).isEmpty
                var words = (s.words ?? []).map { Word(text: $0.word, startMs: max(0, min(durationMs, readStart + Int($0.start * 1000))), endMs: max(0, min(durationMs, readStart + Int($0.end * 1000)))) }
                words = words.filter { let mid = ($0.startMs + $0.endMs) / 2; return mid >= offset && mid < end }
                if hadWords && words.isEmpty { continue }
                if !hadWords {
                    let midpoint = readStart + Int((s.start + s.end) * 500)
                    if midpoint < offset || midpoint >= end { continue }
                }
                let start = words.first?.startMs ?? max(offset, readStart + Int(s.start * 1000))
                let segmentEnd = words.last?.endMs ?? min(end, readStart + Int(s.end * 1000))
                let text = words.isEmpty ? s.text : words.map(\.text).joined()
                guard start < end, segmentEnd >= start, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                if s.compressionRatio > 3.5 { segments.append(Segment(id: "tmp", startMs: start, endMs: segmentEnd, text: "[неразборчиво]", language: result.language, uncertain: true)); continue }
                segments.append(Segment(id: "tmp", startMs: start, endMs: segmentEnd, text: text, language: Analysis.language(text, fallback: result.language), uncertain: uncertain, words: words))
            }
        }
        return segments
    }
}
