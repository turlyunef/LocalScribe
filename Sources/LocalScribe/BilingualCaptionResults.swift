import CoreMedia
import Foundation
import Speech

enum BilingualCaptionLanguage: Hashable, Sendable {
    case russian, english

    func matches(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        if letters.isEmpty { return text.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) } }
        return letters.allSatisfy { scalar in
            let isLatin = (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value)
                || (0x00C0...0x024F).contains(scalar.value)
            switch self {
            // Dictation recognizes Latin names inside otherwise Russian speech.
            case .russian: return (0x0400...0x052F).contains(scalar.value) || isLatin
            case .english: return isLatin
            }
        }
    }
}

struct BilingualCaptionWord: Sendable {
    let language: BilingualCaptionLanguage
    let range: CMTimeRange
    let text: String
    let confidence: Double
}

/// Apple only supplies word timing and confidence for finalized results.
/// Keep one rolling preview until both modules have passed a commit point.
struct BilingualCaptionResults {
    enum Event: Sendable {
        case update(BilingualCaptionLanguage, LiveCaptionUpdate, words: [BilingualCaptionWord], isFinal: Bool)
        case finished(BilingualCaptionLanguage)
    }

    private struct Track {
        var finalThrough = CMTime.zero
        var draft: LiveCaptionUpdate?
        var finished = false
    }

    let preferred: BilingualCaptionLanguage
    private var tracks: [BilingualCaptionLanguage: Track] = [.russian: Track(), .english: Track()]
    private var pending: [BilingualCaptionWord] = []
    private var publishedThrough = CMTime.zero
    private var currentPreview = ""

    init(preferred: BilingualCaptionLanguage) { self.preferred = preferred }

    var isFinished: Bool { tracks.values.allSatisfy(\.finished) }

    mutating func consume(_ event: Event) -> [LiveCaptionUpdate] {
        switch event {
        case let .update(language, update, words, isFinal):
            if update.finalizedThrough.isNumeric, update.finalizedThrough > tracks[language, default: Track()].finalThrough {
                tracks[language, default: Track()].finalThrough = update.finalizedThrough
            }
            if isFinal {
                pending.append(contentsOf: words.filter { $0.range.start >= publishedThrough })
                if let draft = tracks[language]?.draft, draft.range.end <= update.range.end {
                    tracks[language, default: Track()].draft = nil
                }
            } else if update.range.start.isNumeric, update.range.end.isNumeric, update.range.start >= publishedThrough {
                tracks[language, default: Track()].draft = update
            }
        case let .finished(language):
            tracks[language, default: Track()].finished = true
            tracks[language, default: Track()].draft = nil
        }

        let activeWatermarks = tracks.values.filter { !$0.finished }.map(\.finalThrough)
        let boundary = activeWatermarks.min() ?? pending.map(\.range.end).max() ?? publishedThrough
        let settled = Self.merge(pending, preferred: preferred)
        // A word crossing the common range belongs to a later update.
        var end = boundary
        for word in settled.reversed() where word.range.end > end && word.range.start < end {
            end = word.range.start
        }
        var updates: [LiveCaptionUpdate] = []
        if end > publishedThrough {
            let committed = settled.filter { $0.range.end <= end }
            let text = committed.map(\.text).joined(separator: " ")
            let range = CMTimeRange(start: publishedThrough, end: end)
            updates.append(.init(range: range, finalizedThrough: end, text: text))
            pending.removeAll { $0.range.start < end }
            publishedThrough = end
            currentPreview = ""
        }

        let words = settled.filter { $0.range.start >= publishedThrough }
        let draft = [preferred, preferred == .russian ? .english : .russian].compactMap { tracks[$0]?.draft }
            .first { $0.range.start >= publishedThrough }
        let preview = words.isEmpty ? (draft?.text ?? "") : words.map(\.text).joined(separator: " ")
        if preview != currentPreview {
            currentPreview = preview
            let previewEnd = max(publishedThrough, words.last?.range.end ?? draft?.range.end ?? publishedThrough)
            let range = CMTimeRange(start: publishedThrough, end: previewEnd)
            updates.append(.init(range: range, finalizedThrough: publishedThrough, text: preview))
        }
        return updates
    }

    static func merge(_ words: [BilingualCaptionWord], preferred: BilingualCaptionLanguage) -> [BilingualCaptionWord] {
        let candidates = words.filter { $0.confidence.isFinite && $0.confidence >= 0.24 && $0.language.matches($0.text) }
            .sorted { $0.range.start < $1.range.start }
        let scored = candidates.indices.map { index in
            let word = candidates[index]
            // An adjacent high-confidence word from the same recognizer
            // supports a weaker word. A weak isolated guess gets no such support.
            let nearby = candidates[max(0, index - 4)..<min(index + 5, candidates.count)].filter {
                $0.language == word.language && ($0.range.start - word.range.end).seconds <= 0.12 &&
                    (word.range.start - $0.range.end).seconds <= 0.12
            }
            let context = nearby.map(\.confidence).max() ?? word.confidence
            return (word: word, score: (word.confidence + context) / 2)
        }.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.word.language != rhs.word.language { return lhs.word.language == preferred }
            return lhs.word.range.start < rhs.word.range.start
        }

        var chosen: [BilingualCaptionWord] = []
        for candidate in scored where !chosen.contains(where: { other in
            guard other.language != candidate.word.language else { return false }
            let overlap = other.range.intersection(candidate.word.range)
            let shorter = min(other.range.duration.seconds, candidate.word.range.duration.seconds)
            let longer = max(other.range.duration.seconds, candidate.word.range.duration.seconds)
            guard overlap.isValid else { return false }
            let shared = overlap.duration.seconds
            // A short word wholly within another is a competing hypothesis.
            // A small timing overlap at the edge may be two adjacent words.
            return shared >= 0.9 * shorter || shared >= max(0.35 * shorter, 0.25 * longer)
        }) {
            chosen.append(candidate.word)
        }
        return chosen.sorted { $0.range.start < $1.range.start }
    }

    static func collect(
        russian: DictationTranscriber, english: SpeechTranscriber, preferred: BilingualCaptionLanguage,
        dictationFinalization: DictationCaptionFinalization,
        receive: @Sendable @escaping (LiveCaptionUpdate) async -> Void
    ) async throws {
        let (events, output) = AsyncStream.makeStream(of: Event.self)
        defer { output.finish() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await collect(russian, language: .russian, text: { $0.text },
                                  dictationFinalization: dictationFinalization, output: output)
            }
            group.addTask { try await collect(english, language: .english, text: { $0.text }, output: output) }
            group.addTask {
                var merger = BilingualCaptionResults(preferred: preferred)
                for await event in events {
                    try Task.checkCancellation()
                    for update in merger.consume(event) { await receive(update) }
                    if merger.isFinished { return }
                }
            }
            while try await group.next() != nil {}
        }
    }

    private static func collect<Module: SpeechModule>(
        _ module: Module, language: BilingualCaptionLanguage, text: @Sendable (Module.Result) -> AttributedString,
        dictationFinalization: DictationCaptionFinalization? = nil,
        output: AsyncStream<Event>.Continuation
    ) async throws {
        do {
            for try await result in module.results {
                try Task.checkCancellation()
                let attributed = text(result)
                dictationFinalization?.observe(range: result.range, hasText: !attributed.characters.isEmpty,
                                                isFinal: result.isFinal)
                let words: [BilingualCaptionWord] = result.isFinal ? attributed.runs.compactMap { run in
                    guard let range = run.audioTimeRange, range.start.isNumeric, range.duration.isNumeric,
                          range.duration > .zero, let confidence = run.transcriptionConfidence else { return nil }
                    let text = String(attributed[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    return BilingualCaptionWord(language: language, range: range, text: text, confidence: confidence)
                } : []
                let update = LiveCaptionUpdate(range: result.range, finalizedThrough: result.resultsFinalizationTime,
                                               text: String(attributed.characters))
                output.yield(.update(language, update, words: words, isFinal: result.isFinal))
            }
        } catch {
            if dictationFinalization?.allowsEmptyResult(error) != true { throw error }
        }
        output.yield(.finished(language))
    }
}
