import Foundation
import AVFoundation
import LocalScribeCore
import LocalScribeVibeVoice
import MLX

/// Finite calls to the long-form checkpoint. SpeakerKit supplies global speakers.
final class VibeVoiceASREngine: ASREngine {
    static let policyID = "vibevoice-core60s-context5s-greedy8192-speakerkit-v4"
    private static let maximumCoreMs = 60_000
    private static let shortRetryThresholdMs = 15_000
    private static let splitThresholdMs = 3_750
    private static let contextMs = 5_000
    private static let shortRetryContextMs = 1_000
    private static let maximumInputFrames = 300 * 16_000
    private static let maximumTokens = 8192
    let capabilities = ASRCapabilities(inputModes: [.offline], wordTimings: .unavailable)
    private let generate: ([Float]) throws -> String

    init(model: URL, tokenizer: URL, weightFiles: [String]) throws {
        let budget = ModelHardware.current.modelBudgetBytes
        guard budget > 0, budget <= UInt64(Int.max) else { throw ScribeError.message("Не подтверждён бюджет памяти VibeVoice") }
        Memory.cacheLimit = 256 * 1024 * 1024; Memory.memoryLimit = Int(budget)
        try Task.checkCancellation()
        let runtime = try VibeVoiceASRModel.fromModelDirectory(model, tokenizerDirectory: tokenizer, weightFiles: weightFiles)
        try Task.checkCancellation()
        generate = { samples in try runtime.generate(audio: MLXArray(samples), maxTokens: Self.maximumTokens) }
    }
    init(generate: @escaping ([Float]) throws -> String) { self.generate = generate }

    func recognize(_ request: ASRRequest) async throws -> ASRResult {
        try Task.checkCancellation()
        guard request.mode == .offline else {
            throw ScribeError.message("VibeVoice поддерживает только готовые записи")
        }
        try ASRAudioInput.requireFormat(request.audioURL)
        var segments: [Segment] = []
        var start = request.coreRange.lowerBound
        while start < request.coreRange.upperBound {
            let end = min(start + Self.maximumCoreMs, request.coreRange.upperBound)
            segments.append(contentsOf: try recognizeWindow(start..<end, in: request, contextMs: Self.contextMs))
            start = end
        }
        try Task.checkCancellation()
        for index in segments.indices { segments[index].id = "vibe-\(index)" }
        return ASRResult(segments: segments)
    }

    private func recognizeWindow(_ core: Range<Int>, in request: ASRRequest, contextMs: Int) throws -> [Segment] {
        try Task.checkCancellation()
        let readStart = max(request.originMs, core.lowerBound - contextMs)
        let readEnd = min(request.availableEndMs, core.upperBound + contextMs)
        let samples = try Media.samples(request.audioURL, start: Double(readStart - request.originMs) / 1000,
                                        duration: Double(readEnd - readStart) / 1000)
        // Allow up to one millisecond of PCM rounding, with real audio in
        // the owned range even when that range is itself one millisecond.
        guard samples.count >= (readEnd - readStart) * 16 - 16, samples.count > (core.lowerBound - readStart) * 16 else {
            throw ScribeError.message("Аудио VibeVoice короче заявленного диапазона")
        }
        let audio = try Self.resample(samples)
        try Task.checkCancellation()
        let output: String
        do {
            output = try generate(audio)
        } catch VibeVoiceError.incompleteGeneration {
            try Task.checkCancellation()
            guard core.count > Self.splitThresholdMs else {
                let range = [core.lowerBound, core.upperBound]
                    .map { timecode($0) + String(format: ".%03d", $0 % 1000) }.joined(separator: "–")
                throw ScribeError.message("VibeVoice исчерпал лимит генерации на участке \(range) (\(Self.maximumTokens) токена). Расшифровка этой части не сохранена.")
            }
            let midpoint = core.lowerBound + core.count / 2
            let retryContext = core.count <= Self.shortRetryThresholdMs ? Self.shortRetryContextMs : contextMs
            let first = try recognizeWindow(core.lowerBound..<midpoint, in: request, contextMs: retryContext)
            let second = try recognizeWindow(midpoint..<core.upperBound, in: request, contextMs: retryContext)
            return first + second
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ScribeError.message("VibeVoice не завершил распознавание. Частичный текст не сохранён.")
        }
        try Task.checkCancellation()
        return try Self.parse(output, durationMs: Double(samples.count) / 16, readStartMs: readStart, core: core)
    }

    private struct Row: Decodable {
        let start: Double
        let end: Double
        let text: String
        enum CodingKeys: String, CodingKey {
            case start = "Start time", end = "End time", shortStart = "Start", shortEnd = "End", text = "Content"
        }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let longStart = try values.decodeIfPresent(Double.self, forKey: .start)
            let shortStart = try values.decodeIfPresent(Double.self, forKey: .shortStart)
            let longEnd = try values.decodeIfPresent(Double.self, forKey: .end)
            let shortEnd = try values.decodeIfPresent(Double.self, forKey: .shortEnd)
            guard let start = longStart ?? shortStart, let end = longEnd ?? shortEnd,
                  longStart == nil || shortStart == nil || longStart == shortStart,
                  longEnd == nil || shortEnd == nil || longEnd == shortEnd else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid segment times"))
            }
            self.start = start; self.end = end
            text = try values.decode(String.self, forKey: .text)
        }
    }
    static func parse(_ response: String, durationMs: Double, readStartMs: Int = 0, core: Range<Int>? = nil) throws -> [Segment] {
        let invalid = ScribeError.message("VibeVoice вернул некорректную структуру текста или таймкоды. Частичный результат не сохранён.")
        guard response.utf8.count <= 4_000_000 else { throw invalid }
        var text = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```json\n"), text.hasSuffix("```") {
            text = String(text.dropFirst(8).dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let decoder = JSONDecoder(), data = Data(text.utf8)
        let rows: [Row]
        do {
            if text.hasPrefix("[") { rows = try decoder.decode([Row].self, from: data) }
            else { rows = [try decoder.decode(Row.self, from: data)] }
        } catch { throw invalid }
        var segments: [Segment] = [], previousStart = -1.0
        for row in rows {
            guard row.start.isFinite, row.end.isFinite, row.start >= 0, row.end > row.start,
                  row.end <= durationMs / 1000, row.start >= previousStart,
                  !row.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw invalid }
            previousStart = row.start
            // Own a whole segment by its unrounded midpoint on the source timeline.
            let midpoint = Double(readStartMs) + (row.start + row.end) * 500
            if let core, midpoint < Double(core.lowerBound) || midpoint >= Double(core.upperBound) { continue }
            segments.append(Segment(id: "vibe-\(segments.count)", startMs: readStartMs + Int((row.start * 1000).rounded()),
                endMs: readStartMs + Int((row.end * 1000).rounded()), text: row.text,
                language: QwenASREngine.sourceLanguage(row.text, fallback: nil), words: []))
        }
        return segments
    }

    /// One continuous high-quality Core Audio conversion. No output timeline shift.
    static func resample(_ samples: [Float]) throws -> [Float] {
        guard !samples.isEmpty, samples.count <= maximumInputFrames,
              let inputFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1),
              let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 8192) else {
            throw ScribeError.message("Не удалось подготовить звук VibeVoice")
        }
        input.frameLength = input.frameCapacity
        samples.withUnsafeBufferPointer { source in input.floatChannelData![0].update(from: source.baseAddress!, count: samples.count) }
        converter.primeMethod = .normal; converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        var supplied = false, result: [Float] = []
        result.reserveCapacity(samples.count * 3 / 2)
        while true {
            try Task.checkCancellation()
            output.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                if !supplied { supplied = true; state.pointee = .haveData; return input }
                state.pointee = .endOfStream; return nil
            }
            guard error == nil, status != .error else { throw ScribeError.message("Не удалось преобразовать звук VibeVoice") }
            result.append(contentsOf: UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
            guard result.count <= samples.count * 3 / 2 + 8192 else { throw ScribeError.message("Некорректная длина звука VibeVoice") }
            if status == .endOfStream { break }
            guard status == .haveData else { throw ScribeError.message("Преобразование VibeVoice завершилось до конца записи") }
        }
        guard abs(result.count - samples.count * 3 / 2) <= 2 else { throw ScribeError.message("Длительность звука VibeVoice изменилась при преобразовании") }
        return result
    }
}
