import Foundation
import AVFoundation
import LocalScribeCore
import LocalScribeVibeVoice
import MLX

/// Long-form ASR checkpoint only. SpeakerKit remains the global speaker source.
/// Not advertised in the catalog until a real checkpoint passes the local probe.
final class VibeVoiceASREngine: ASREngine {
    static let maximumRecordingMs = 300_000
    static let policyID = "vibevoice-longform-300s-greedy8192-speakerkit-v1"
    let capabilities = ASRCapabilities(inputModes: [.offline], wordTimings: .unavailable)
    private let generate: ([Float]) throws -> String

    init(model: URL, tokenizer: URL, weightFiles: [String]) throws {
        let budget = ModelHardware.current.modelBudgetBytes
        guard budget > 0, budget <= UInt64(Int.max) else { throw ScribeError.message("Не подтверждён бюджет памяти VibeVoice") }
        Memory.cacheLimit = 256 * 1024 * 1024; Memory.memoryLimit = Int(budget)
        try Task.checkCancellation()
        let runtime = try VibeVoiceASRModel.fromModelDirectory(model, tokenizerDirectory: tokenizer, weightFiles: weightFiles)
        try Task.checkCancellation()
        generate = { samples in try runtime.generate(audio: MLXArray(samples), maxTokens: 8192) }
    }
    init(generate: @escaping ([Float]) throws -> String) { self.generate = generate }

    static func requireDuration(_ milliseconds: Int) throws {
        guard milliseconds > 0, milliseconds <= maximumRecordingMs else {
            throw ScribeError.message("Экспериментальный VibeVoice поддерживает готовые записи до 5 минут. Запись не обрезана; выберите другой профиль.")
        }
    }
    func recognize(_ request: ASRRequest) async throws -> ASRResult {
        try Task.checkCancellation()
        try Self.requireDuration(request.availableEndMs)
        guard request.mode == .offline, request.originMs == 0, request.coreRange == 0..<request.availableEndMs else {
            throw ScribeError.message("VibeVoice требует готовую запись целиком; независимые части и фоновое распознавание пока не поддерживаются")
        }
        try ASRAudioInput.requireFormat(request.audioURL)
        let samples = try Media.samples(request.audioURL, duration: Double(request.availableEndMs) / 1000)
        guard abs(samples.count - request.availableEndMs * 16) <= 16 else {
            throw ScribeError.message("Аудио VibeVoice короче заявленной длительности")
        }
        let audio = try Self.resample(samples)
        try Task.checkCancellation()
        let output: String
        do { output = try generate(audio) }
        catch is CancellationError { throw CancellationError() }
        catch { throw ScribeError.message("VibeVoice не завершил распознавание. Частичный текст не сохранён.") }
        try Task.checkCancellation()
        return ASRResult(segments: try Self.parse(output, durationMs: request.availableEndMs))
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
    static func parse(_ response: String, durationMs: Int) throws -> [Segment] {
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
                  row.end * 1000 <= Double(durationMs), row.start >= previousStart,
                  !row.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw invalid }
            previousStart = row.start
            segments.append(Segment(id: "vibe-\(segments.count)", startMs: Int((row.start * 1000).rounded()),
                endMs: Int((row.end * 1000).rounded()), text: row.text,
                language: QwenASREngine.sourceLanguage(row.text, fallback: nil), words: []))
        }
        return segments
    }

    /// One continuous high-quality Core Audio conversion. No output timeline shift.
    static func resample(_ samples: [Float]) throws -> [Float] {
        guard !samples.isEmpty, samples.count <= maximumRecordingMs * 16,
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
