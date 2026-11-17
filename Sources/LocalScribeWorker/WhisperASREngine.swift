import Foundation
import LocalScribeCore
import LocalScribeWhisperHints
import WhisperKit

/// Experimental switches are independent. App/worker callers use `.production`;
/// only the opt-in matrix probe supplies a different policy.
struct WhisperRecognitionPolicy: Sendable {
    var window: WhisperWindowPolicy = .firstPause
    var recoverInteriorGaps = false
    var reviewContext = false
    static let production = WhisperRecognitionPolicy()

    var metricsName: String {
        if reviewContext {
            return (window == .latePause ? "late-pause" : "first-pause")
                + (recoverInteriorGaps ? "-gap-recovery" : "") + "-context-review"
        }
        switch (window, recoverInteriorGaps) {
        case (.firstPause, false): return "first-pause-prefix-recovery"
        case (.firstPause, true): return "first-pause-gap-recovery"
        case (.latePause, false): return "late-pause-prefix-recovery"
        case (.latePause, true): return "late-pause-v2-gap-recovery"
        }
    }
}

final class WhisperASREngine: ASREngine {
    private struct UnreliableDictionaryDecode: Error {}

    let capabilities = ASRCapabilities(inputModes: [.offline, .closedFragments], wordTimings: .available)
    static var decodingOptions: DecodingOptions {
        DecodingOptions(verbose: false, task: .transcribe, language: nil, temperatureFallbackCount: 2,
            detectLanguage: true, skipSpecialTokens: true, wordTimestamps: true, windowClipTime: 0, concurrentWorkerCount: 1)
    }
    private var promptTokens: [Int]?
    /// Start each primary and recovery pass with the same hint.
    private var options: DecodingOptions {
        var options = Self.decodingOptions
        options.promptTokens = promptTokens
        return options
    }
    private let transcribe: ([Float], DecodingOptions) async throws -> [TranscriptionResult]
    private let dictionarySegmentSeeker: WhisperDictionarySegmentSeeker?
    private let policy: WhisperRecognitionPolicy
    private let metrics: ASRMetricsRecorder?
    private let warning: @Sendable (String) -> Void
    private let contextReview: ((ASRContextReviewBatch) throws -> Void)?
    init(info: RunInfo, models: URL, metrics: ASRMetricsRecorder? = nil, policy: WhisperRecognitionPolicy = .production,
         contextReview: ((ASRContextReviewBatch) throws -> Void)? = nil,
         warning: @escaping @Sendable (String) -> Void) async throws {
        self.warning = warning
        self.metrics = metrics
        self.policy = policy
        self.contextReview = contextReview
        let started = ProcessInfo.processInfo.systemUptime
        defer { metrics?.modelLoaded(seconds: ProcessInfo.processInfo.systemUptime - started) }
        let folder = models.appendingPathComponent(try info.modelID(for: .asr)), tokenizer = models.appendingPathComponent(try info.modelID(for: .tokenizer))
        guard FileManager.default.fileExists(atPath: tokenizer.appendingPathComponent("tokenizer.json").path), FileManager.default.fileExists(atPath: tokenizer.appendingPathComponent("tokenizer_config.json").path) else { throw ScribeError.message("Отсутствует локальный токенизатор Whisper") }
        let segmentSeeker = info.recognitionTerms?.isEmpty == false ? WhisperDictionarySegmentSeeker() : nil
        dictionarySegmentSeeker = segmentSeeker
        let kit = try await WhisperKit(WhisperKitConfig(modelFolder: folder.path, tokenizerFolder: tokenizer,
            segmentSeeker: segmentSeeker, verbose: false, logLevel: .none, prewarm: true, load: true, download: false))
        guard let whisperTokenizer = kit.tokenizer else { throw ScribeError.message("Токенизатор Whisper не загружен") }
        // Mirrors the SDK handling: special tokens are filtered, and an empty
        // remainder must not produce a bare <|startofprev|> prefill.
        self.promptTokens = try WhisperDictionary.promptTokens(for: info.recognitionTerms,
            encode: { whisperTokenizer.encode(text: $0) },
            specialTokenBegin: whisperTokenizer.specialTokens.specialTokenBegin)
        transcribe = { samples, options in try await kit.transcribe(audioArray: samples, decodeOptions: options) }
    }

    /// Exercise scheduling, timestamp ownership and recovery without model weights.
    init(metrics: ASRMetricsRecorder? = nil, policy: WhisperRecognitionPolicy = .production,
         contextReview: ((ASRContextReviewBatch) throws -> Void)? = nil,
         warning: @escaping @Sendable (String) -> Void = { _ in },
         promptTokens: [Int]? = nil,
         transcribe: @escaping ([Float], DecodingOptions) async throws -> [TranscriptionResult]) {
        self.metrics = metrics; self.policy = policy; self.warning = warning; self.transcribe = transcribe
        self.contextReview = contextReview
        self.promptTokens = promptTokens
        dictionarySegmentSeeker = nil
    }
    func recognize(_ request: ASRRequest) async throws -> ASRResult {
        do {
            return try await recognize(request, options: options)
        } catch is UnreliableDictionaryDecode {
            // Keep the usual window boundaries and context for the entire
            // part. Hinted and unhinted word ownership cannot be spliced at
            // the shortened windows without risking duplicates or omissions.
            return try await recognize(request, options: Self.decodingOptions)
        }
    }

    private func recognize(_ request: ASRRequest, options: DecodingOptions) async throws -> ASRResult {
        try Task.checkCancellation()
        let wave = request.audioURL, coreStart = request.coreRange.lowerBound, coreEnd = request.coreRange.upperBound
        let durationMs = request.availableEndMs, originMs = request.originMs
        guard !policy.reviewContext || contextReview != nil else {
            throw ScribeError.message("Для технического повтора нужен отдельный приёмник вариантов расшифровки")
        }
        var segments: [Segment] = []
        var offset = coreStart
        // Leave room for the transcript, timestamps and both seconds of PCM
        // overlap. Dense speech can still hit the hard cap and is retried.
        let maximumInputMs = options.promptTokens.map { (Constants.maxTokenContext - 7 - $0.count) * 100 } ?? 30_000
        let maximumCoreMs = maximumInputMs - 2000
        let checkDictionaryQuality = options.promptTokens != nil && !policy.reviewContext
        while offset < coreEnd {
            try Task.checkCancellation()
            let planning = try Media.samples(wave, start: Double(offset-originMs)/1000, duration: Double(min(coreEnd-offset, maximumCoreMs))/1000)
            let length = max(1, WhisperASRWindowing.nextASRWindowLength(planning, policy: policy.window) / 16)
            let end = min(coreEnd, offset + length)
            let readStart = max(originMs, offset - 1000), readEnd = min(durationMs, end + 1000)
            let samples = try Media.samples(wave, start: Double(readStart-originMs)/1000, duration: Double(readEnd-readStart)/1000)
            let energy = samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(max(1, samples.count))
            metrics?.window(milliseconds: end - offset, silent: energy <= 1e-12)
            if energy > 1e-12 {
                // The SDK otherwise skips clips/tails shorter than one second.
                let results = try await decode(samples, options: options, phase: .primary)
                var recoveryContexts: [Range<Int>] = []
                var recognized = mappedSegments(results, readStart: readStart, start: offset, end: end, durationMs: durationMs)
                if let missingEnd = WhisperASRWindowing.missingASRPrefixEnd(segments: recognized, samples: samples, readStartMs: readStart, coreStartMs: offset, coreEndMs: end) {
                    // A pause-sized clip can produce only special tokens (not
                    // necessarily a high noSpeechProb). Retry within the input budget
                    // of real context, retaining ownership of the missing prefix.
                    let retryEnd = min(durationMs, readStart + maximumInputMs)
                    let retryStart = max(originMs, retryEnd - maximumInputMs)
                    let context = try Media.samples(wave, start: Double(retryStart-originMs)/1000, duration: Double(retryEnd-retryStart)/1000)
                    let retried = try await decode(context, options: options, phase: .prefixRecovery)
                    if policy.reviewContext { recoveryContexts.append(retryStart..<retryEnd) }
                    let recovered = mappedSegments(retried, readStart: retryStart, start: offset, end: missingEnd, durationMs: durationMs)
                    recognized = recovered + recognized
                    if WhisperASRWindowing.missingASRPrefixEnd(segments: recognized, samples: samples, readStartMs: readStart, coreStartMs: offset, coreEndMs: end) != nil {
                        if checkDictionaryQuality { throw UnreliableDictionaryDecode() }
                        metrics?.missingPrefix()
                        warning("В интервале \(timecode(offset))–\(timecode(missingEnd)) есть звук, но начало речи не распознано. Прослушайте исходник; можно повторить обработку другой моделью.")
                    }
                }
                if checkDictionaryQuality,
                   (!recognized.isEmpty && recognized.allSatisfy(\.uncertain))
                    || !WhisperASRWindowing.missingASRInteriorRanges(segments: recognized, samples: samples,
                        readStartMs: readStart, coreStartMs: offset, coreEndMs: end).isEmpty {
                    throw UnreliableDictionaryDecode()
                }
                if policy.recoverInteriorGaps {
                    let gaps = WhisperASRWindowing.missingASRInteriorRanges(segments: recognized, samples: samples,
                        readStartMs: readStart, coreStartMs: offset, coreEndMs: end)
                    for gap in gaps {
                        try Task.checkCancellation()
                        // Restore the exact asr6 250 ms context heuristic so the
                        // matrix varies only window planning and gap recovery.
                        let gapStart = max(originMs, gap.lowerBound - 250), gapEnd = min(durationMs, gap.upperBound + 250)
                        let context = try Media.samples(wave, start: Double(gapStart-originMs)/1000, duration: Double(gapEnd-gapStart)/1000)
                        let retried = try await decode(context, options: options, phase: .gapRecovery)
                        if policy.reviewContext { recoveryContexts.append(gapStart..<gapEnd) }
                        let recovered = mappedSegments(retried, readStart: gapStart, start: gap.lowerBound, end: gap.upperBound, durationMs: durationMs)
                        recognized.append(contentsOf: recovered)
                        let remaining = WhisperASRWindowing.missingASRInteriorRanges(segments: recognized, samples: samples,
                            readStartMs: readStart, coreStartMs: offset, coreEndMs: end)
                        if remaining.contains(where: { $0.overlaps(gap) }) {
                            metrics?.missingGap()
                            warning("В интервале \(timecode(gap.lowerBound))–\(timecode(gap.upperBound)) есть звук без расшифровки. Прослушайте исходник; можно повторить обработку другой моделью.")
                        }
                    }
                    recognized.sort { $0.startMs < $1.startMs }
                }
                if policy.reviewContext {
                    let plan = ASRContextReviewPlanner.plan(segments: recognized, samples: samples,
                        readStartMs: readStart, readEndMs: readEnd, coreStartMs: offset, coreEndMs: end,
                        originMs: originMs, durationMs: durationMs, previousContexts: recoveryContexts)
                    var reviews: [ASRContextReview] = []
                    var cachedReview: (range: Range<Int>, results: [TranscriptionResult])?
                    for request in plan.requests {
                        try Task.checkCancellation()
                        let range = request.contextStartMs..<request.contextEndMs
                        let retried: [TranscriptionResult]
                        if let cachedReview, cachedReview.range == range {
                            retried = cachedReview.results
                        } else {
                            let context = try Media.samples(wave, start: Double(request.contextStartMs-originMs)/1000,
                                duration: Double(request.contextEndMs-request.contextStartMs)/1000)
                            retried = try await decode(context, options: options, phase: .contextReview)
                            try Task.checkCancellation()
                            cachedReview = (range, retried)
                        }
                        let candidate = mappedSegments(retried, readStart: request.contextStartMs,
                            start: request.startMs, end: request.endMs, durationMs: durationMs)
                        let original = ASRContextReviewPlanner.ownedSegments(recognized, startMs: request.startMs, endMs: request.endMs)
                        reviews.append(.init(request: request, original: original, candidate: candidate,
                            wordRepair: ASRWordRepair.propose(original: original, candidate: candidate,
                                startMs: request.startMs, endMs: request.endMs)))
                    }
                    try Task.checkCancellation()
                    try contextReview?(.init(coreStartMs: offset, coreEndMs: end, deferredTargets: plan.deferredTargets,
                        unchangedContextTargets: plan.unchangedContextTargets, reviews: reviews))
                }
                segments.append(contentsOf: recognized)
            }
            offset = end
        }
        return ASRResult(segments: segments)
    }

    // Also used by the explicit frozen-baseline probe.
    func decode(_ samples: [Float], options: DecodingOptions, phase: ASRCallPhase) async throws -> [TranscriptionResult] {
        let results = try await decodeOnce(samples, options: options, phase: phase)
        guard dictionarySegmentSeeker?.exhaustedContext == true else { return results }
        var retry = options
        retry.promptTokens = nil
        return try await decodeOnce(samples, options: retry, phase: phase)
    }

    private func decodeOnce(_ samples: [Float], options: DecodingOptions, phase: ASRCallPhase) async throws -> [TranscriptionResult] {
        try Task.checkCancellation()
        dictionarySegmentSeeker?.beginCall()
        metrics?.startCall(samples: samples.count, phase: phase)
        let started = ProcessInfo.processInfo.systemUptime
        do {
            let results = try await transcribe(samples, options)
            // Some SDK paths return normally after cancellation. Never let that
            // result become a successful part or launch another recovery call.
            try Task.checkCancellation()
            metrics?.finishWhisperCall(seconds: ProcessInfo.processInfo.systemUptime - started, phase: phase, results: results)
            return results
        } catch {
            metrics?.finishWhisperCall(seconds: ProcessInfo.processInfo.systemUptime - started, phase: phase, results: nil)
            throw error
        }
    }

    func mappedSegments(_ results: [TranscriptionResult], readStart: Int, start offset: Int, end: Int, durationMs: Int) -> [Segment] {
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
