import Foundation
import LocalScribeCore
import LocalScribeQwen
import MLX

/// Finite offline requests only. The aligner positions a hypothesis; it does not
/// verify that the hypothesis was spoken. No corrected/interpolated SDK times.
final class QwenASREngine: ASREngine {
    static let policyID = "qwen3-pause28-context250-greedy1024-rawalign-v2"
    let capabilities = ASRCapabilities(inputModes: [.offline], wordTimings: .available)
    struct Hypothesis { let text: String; let language: String? }
    struct AlignedWord { let text: String; let start: Double; let end: Double }
    typealias Recognize = ([Float], String) throws -> Hypothesis
    typealias Align = ([Float], String) throws -> [AlignedWord]
    private let transcribe: Recognize
    private let align: Align
    private let warning: @Sendable (String) -> Void
    private let metrics: ASRMetricsRecorder?
    /// Sanitized hint context passed to every generateSingleChunk call; empty
    /// when the run has no recognition dictionary.
    private let hintContext: String

    init(asr: URL, tokenizer: URL, aligner: URL, terms: [String]? = nil, metrics: ASRMetricsRecorder? = nil, warning: @escaping @Sendable (String) -> Void = { _ in }) throws {
        self.warning = warning; self.metrics = metrics
        self.hintContext = Self.buildContext(for: terms)
        metrics?.backend("qwen3", policy: Self.policyID)
        let started = ProcessInfo.processInfo.systemUptime
        defer { metrics?.modelLoaded(seconds: ProcessInfo.processInfo.systemUptime - started) }
        try Task.checkCancellation()
        let budget = ModelHardware.current.modelBudgetBytes
        guard budget > 0, budget <= UInt64(Int.max) else { throw ScribeError.message("Не подтверждён бюджет памяти Qwen") }
        Memory.cacheLimit = 256 * 1024 * 1024
        Memory.memoryLimit = Int(budget)
        let model = try Qwen3ASRModel.fromModelDirectory(asr, tokenizerDirectory: tokenizer)
        try Task.checkCancellation()
        let alignment = try Qwen3ForcedAlignerModel.fromModelDirectory(aligner)
        try Task.checkCancellation()
        transcribe = { samples, hintContext in
            let result = try model.generateSingleChunk(audio: MLXArray(samples), maxTokens: 1024,
                temperature: 0, context: hintContext, language: nil)
            return Hypothesis(text: result.text, language: result.language)
        }
        align = { samples, text in
            // Russian and English (including code switching) use the same
            // whitespace tokenizer. No whole-recording language is forced on ASR.
            let result = try alignment.generate(audio: MLXArray(samples), text: text, language: "Russian")
            return result.items.map { AlignedWord(text: $0.text, start: $0.startTime, end: $0.endTime) }
        }
    }

    init(warning: @escaping @Sendable (String) -> Void = { _ in }, terms: [String]? = nil, transcribe: @escaping Recognize, align: @escaping Align) {
        self.warning = warning; self.metrics = nil
        self.hintContext = Self.buildContext(for: terms)
        self.transcribe = transcribe; self.align = align
    }

    /// Build the system-level hint context. Terms are spelling hints only: the
    /// wording keeps them applicable where they are actually heard and forbids
    /// inserting them into silence or unrelated speech.
    static func buildContext(for terms: [String]?) -> String {
        let sanitized = (terms ?? []).map(Self.stripServiceMarkers).filter { !$0.isEmpty }
        guard !sanitized.isEmpty else { return "" }
        return "Расшифровка встречи. Если эти термины, названия и имена произносятся в аудио, передавай их написание точно как в списке: "
            + sanitized.joined(separator: ", ")
            + ". Не добавляй слова из списка, если они не произносятся в аудио."
    }

    /// The context is embedded into the Qwen chat template verbatim, so terms
    /// must never be able to forge `<|im_start|>`/`<|im_end|>`/audio markers or
    /// break out of the system message. Every `<|…|>` marker-looking span and
    /// every control character is removed; everything else is kept for spelling.
    static func stripServiceMarkers(_ term: String) -> String {
        let scalars = term.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        var cleaned = String(String.UnicodeScalarView(scalars))
        // Removing one span can expose another across the join.
        while let marker = cleaned.range(of: #"<\|[\s\S]*?\|>"#, options: .regularExpression) {
            cleaned.removeSubrange(marker)
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func recognize(_ request: ASRRequest) async throws -> ASRResult {
        guard request.mode == .offline else {
            throw ScribeError.message("Qwen пока поддерживает только готовые записи")
        }
        try ASRAudioInput.requireFormat(request.audioURL)
        var result: [Segment] = []
        var start = request.coreRange.lowerBound
        while start < request.coreRange.upperBound {
            try Task.checkCancellation()
            let maximumEnd = min(start + 28_000, request.coreRange.upperBound)
            let planning = try Media.samples(request.audioURL, start: Double(start - request.originMs) / 1000,
                                              duration: Double(maximumEnd - start) / 1000)
            let end = min(maximumEnd, start + Self.windowLengthMs(planning))
            let readStart = max(request.originMs, start - 250)
            let readEnd = min(request.availableEndMs, end + 250)
            let samples = try Media.samples(request.audioURL, start: Double(readStart - request.originMs) / 1000,
                                            duration: Double(readEnd - readStart) / 1000)
            guard abs(samples.count - (readEnd - readStart) * 16) <= 16 else {
                throw ScribeError.message("Аудио Qwen короче заявленного доступного диапазона")
            }
            let silent = !samples.contains(where: { $0 != 0 })
            metrics?.window(milliseconds: end - start, silent: silent)
            // Only exact digital silence is bypassed; energy is not a speech detector.
            if !silent {
                let hypothesis: Hypothesis
                let aligned: [AlignedWord]
                do {
                    let asrStarted = ProcessInfo.processInfo.systemUptime
                    hypothesis = try transcribe(samples, hintContext)
                    metrics?.backendCall(seconds: ProcessInfo.processInfo.systemUptime - asrStarted, alignment: false)
                    try Task.checkCancellation()
                    if hypothesis.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        start = end; continue
                    }
                    let alignmentStarted = ProcessInfo.processInfo.systemUptime
                    aligned = try align(samples, hypothesis.text)
                    metrics?.backendCall(seconds: ProcessInfo.processInfo.systemUptime - alignmentStarted, alignment: true)
                    try Task.checkCancellation()
                } catch is CancellationError { throw CancellationError() }
                catch { throw ScribeError.message("Qwen не завершил распознавание или выравнивание. Частичный результат не сохранён.") }
                let mapped = try Self.map(hypothesis: hypothesis, aligned: aligned, readStart: readStart,
                                          readEnd: readEnd, core: start..<end)
                if mapped.contains(where: { $0.words.isEmpty }) {
                    warning("Qwen: в интервале \(start)–\(end) мс выравниватель вернул нулевую длительность слова; сохранён текст с диапазоном сегмента без таймкодов слов.")
                }
                result.append(contentsOf: mapped)
            }
            start = end
        }
        try Task.checkCancellation()
        for i in result.indices { result[i].id = "qwen-\(i)" }
        return ASRResult(segments: result)
    }

    /// A low-energy boundary limits context; it never removes audio or proves
    /// absence of speech. Each following request starts exactly at this cut.
    static func windowLengthMs(_ samples: [Float]) -> Int {
        let maximum = max(1, samples.count / 16)
        var quietStart: Int?
        for frame in stride(from: 0, to: samples.count, by: 160) {
            let end = min(samples.count, frame + 160)
            let energy = samples[frame..<end].reduce(0.0) { $0 + Double($1 * $1) } / Double(end - frame)
            if energy < 0.003 * 0.003 {
                if quietStart == nil { quietStart = frame }
                if let quietStart, frame + 160 - quietStart >= 9600, quietStart >= 32_000 {
                    return min(maximum, (quietStart + 4800) / 16)
                }
            } else { quietStart = nil }
        }
        return maximum
    }

    static func map(hypothesis: Hypothesis, aligned: [AlignedWord], readStart: Int, readEnd: Int,
                    core: Range<Int>) throws -> [Segment] {
        // Match every aligned unit to the original text, retaining its punctuation.
        let pieces = hypothesis.text.split(whereSeparator: \.isWhitespace).map(String.init)
        func clean(_ text: String) -> String { String(text.filter { $0.isLetter || $0.isNumber || $0 == "'" }) }
        var originals: [String] = []
        var prefix = ""
        for piece in pieces {
            if clean(piece).isEmpty {
                if originals.isEmpty { prefix += piece + " " }
                else { originals[originals.count - 1] += " " + piece }
            } else { originals.append(prefix + piece); prefix = "" }
        }
        func invalid(_ reason: String) -> ScribeError {
            ScribeError.message("Некорректное выравнивание Qwen: " + reason + ". Текст части не опубликован; вымышленные таймкоды не создаются.")
        }
        let error = invalid("неполный текст или пустой диапазон")
        guard !originals.isEmpty, originals.count == aligned.count,
              readStart >= 0, readEnd > readStart else { throw error }
        var words: [Word] = []
        var previousStart = -1.0, previousEnd = -1.0
        for (original, item) in zip(originals, aligned) {
            guard clean(original) == item.text else { throw invalid("слова не соответствуют распознанному тексту") }
            guard item.start.isFinite, item.end.isFinite else { throw invalid("нечисловые таймкоды") }
            guard item.start >= 0, item.end * 1000 <= Double(readEnd - readStart) else { throw invalid("таймкоды вне доступного аудио") }
            guard item.end >= item.start else { throw invalid("конец слова раньше начала") }
            guard item.start >= previousStart, item.end >= previousEnd else { throw invalid("нарушена монотонность слов") }
            previousStart = item.start; previousEnd = item.end
            let start = readStart + Int((item.start * 1000).rounded())
            let end = readStart + Int((item.end * 1000).rounded())
            guard end >= start else { throw error }
            if core.contains(start + (end - start) / 2) {
                words.append(Word(text: original, startMs: start, endMs: end))
            }
        }
        if words.contains(where: { $0.endMs == $0.startMs }) {
            guard let first = words.first, let last = words.last, last.endMs > first.startMs else { throw error }
            let text = words.map(\.text).joined(separator: " ")
            // Coarse endpoints are real raw predictions, never interpolated word
            // times. Drop the entire word layer when resolution is insufficient.
            return [Segment(id: "qwen-coarse", startMs: first.startMs, endMs: last.endMs,
                text: text, language: sourceLanguage(text, fallback: hypothesis.language), words: [])]
        }
        // Short source-language segments also let the global SpeakerKit mapper
        // split by words. Model speaker labels are never imported.
        var segments: [Segment] = []
        for word in words {
            let language = sourceLanguage(word.text, fallback: hypothesis.language)
            if let last = segments.last, last.language == language, last.words.count < 12,
               word.endMs - last.startMs <= 6000 {
                let i = segments.count - 1
                segments[i].words.append(word); segments[i].text += " " + word.text
                segments[i].endMs = max(segments[i].endMs, word.endMs)
            } else {
                segments.append(Segment(id: "qwen-\(segments.count)", startMs: word.startMs, endMs: word.endMs,
                    text: word.text, language: language, words: [word]))
            }
        }
        return segments
    }

    static func sourceLanguage(_ text: String, fallback: String?) -> String {
        let cyrillic = text.unicodeScalars.contains { (0x400...0x52f).contains($0.value) }
        let latin = text.unicodeScalars.contains { (65...90).contains($0.value) || (97...122).contains($0.value) }
        if cyrillic && latin { return "mixed" }
        if cyrillic { return "ru" }
        if latin { return "en" }
        return fallback?.lowercased() == "russian" ? "ru" : fallback?.lowercased() == "english" ? "en" : "und"
    }
}
