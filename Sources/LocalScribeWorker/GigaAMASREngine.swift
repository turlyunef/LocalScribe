import CGigaAM
import Foundation
import LocalScribeCore

final class GigaAMASREngine: ASREngine {
    static let policyID = "gigaam-v3-rnnt-int8-sherpa1.13-core23s-context1s-v1"
    static let weights: Set<String> = ["encoder.int8.onnx", "decoder.onnx", "joiner.onnx"]

    struct Hypothesis: Decodable {
        let tokens: [String]
        let timestamps: [Double]
    }

    let capabilities = ASRCapabilities(inputModes: [.offline], wordTimings: .available)
    private let decode: ([Float]) throws -> Hypothesis
    private let metrics: ASRMetricsRecorder?

    init(model: URL, tokenizer: URL, metrics: ASRMetricsRecorder?) throws {
        guard localscribe_gigaam_available() else {
            throw ScribeError.message("Библиотека GigaAM отсутствует. Соберите или переустановите LocalScribe.")
        }
        let started = ProcessInfo.processInfo.systemUptime
        defer { metrics?.modelLoaded(seconds: ProcessInfo.processInfo.systemUptime - started) }
        let runtime = try GigaAMRuntime(model: model, tokenizer: tokenizer)
        self.decode = runtime.recognize
        self.metrics = metrics
    }

    init(decode: @escaping ([Float]) throws -> Hypothesis) {
        self.decode = decode
        self.metrics = nil
    }

    func recognize(_ request: ASRRequest) async throws -> ASRResult {
        guard request.mode == .offline else {
            throw ScribeError.message("Выбранная модель поддерживает только обработку готовой записи")
        }
        try Task.checkCancellation()
        let pcm = try Media.PCMFrameReader(request.audioURL)
        let finalFrame = min(pcm.frameCount, (request.availableEndMs - request.originMs) * 16)
        var start = request.coreRange.lowerBound
        var segments: [Segment] = []
        while start < request.coreRange.upperBound {
            try Task.checkCancellation()
            let limit = min(start + 23_000, request.coreRange.upperBound)
            let frame = (start - request.originMs) * 16
            guard frame < finalFrame else { break }
            let planningEnd = min(finalFrame, (limit - request.originMs) * 16)
            let planning = try pcm.read(frame..<planningEnd)
            let boundary = WhisperASRWindowing.nextASRWindowLength(planning)
            let end = boundary < planning.count ? min(limit, start + max(1, boundary / 16)) : limit
            let readStart = max(request.originMs, start - 1000)
            let readEndFrame = min(finalFrame, (end + 1000 - request.originMs) * 16)
            let readStartFrame = (readStart - request.originMs) * 16
            let samples = try pcm.read(readStartFrame..<readEndFrame)
            let silent = samples.allSatisfy { $0 == 0 }
            metrics?.window(milliseconds: end - start, silent: silent)
            if !silent {
                let clock = ProcessInfo.processInfo.systemUptime
                let hypothesis = try decode(samples)
                try Task.checkCancellation()
                metrics?.backendCall(seconds: ProcessInfo.processInfo.systemUptime - clock, alignment: false)
                let readEnd = readStart + (samples.count + 15) / 16
                let words = try Self.words(hypothesis, readStart: readStart, readEnd: readEnd, core: start..<end)
                segments.append(contentsOf: Self.segments(words, startingAt: segments.count))
            }
            start = end
        }
        try Task.checkCancellation()
        return ASRResult(segments: segments)
    }

    static func words(_ hypothesis: Hypothesis, readStart: Int, readEnd: Int, core: Range<Int>) throws -> [Word] {
        let invalid = ScribeError.message("GigaAM вернула некорректные токены или таймкоды.")
        guard hypothesis.tokens.count == hypothesis.timestamps.count else { throw invalid }
        var result: [Word] = []
        var text = ""
        var first: Int?
        var last = readStart
        var previous = -1.0
        let encoderFrameMs = 40
        func flush() {
            if let first, first < readEnd, core.contains(first + (last - first) / 2) {
                result.append(Word(text: " " + text, startMs: first, endMs: min(readEnd, last + encoderFrameMs)))
            }
            text = ""
            first = nil
        }
        for (token, seconds) in zip(hypothesis.tokens, hypothesis.timestamps) {
            guard seconds.isFinite, seconds >= 0, seconds >= previous,
                  seconds * 1000 <= Double(readEnd - readStart + encoderFrameMs),
                  token.count == 1 else { throw invalid }
            previous = seconds
            if token == " " {
                flush()
            } else {
                let stamp = min(readEnd, readStart + Int((seconds * 1000).rounded()))
                if first == nil { first = stamp }
                text += token
                last = stamp
            }
        }
        flush()
        return result
    }

    private static func segments(_ words: [Word], startingAt index: Int) -> [Segment] {
        var result: [Segment] = []
        for word in words {
            if let last = result.last, last.words.count < 12,
               word.startMs - last.endMs < 700, word.endMs - last.startMs <= 6000 {
                result[result.count - 1].text += word.text
                result[result.count - 1].endMs = max(last.endMs, word.endMs)
                result[result.count - 1].words.append(word)
            } else {
                result.append(Segment(id: "gigaam-\(index + result.count)", startMs: word.startMs, endMs: word.endMs,
                    text: String(word.text.dropFirst()), language: "ru", words: [word]))
            }
        }
        return result
    }
}

private final class GigaAMRuntime {
    private let handle: OpaquePointer

    init(model: URL, tokenizer: URL) throws {
        let encoder = model.appendingPathComponent("encoder.int8.onnx").path
        let decoder = model.appendingPathComponent("decoder.onnx").path
        let joiner = model.appendingPathComponent("joiner.onnx").path
        let tokens = tokenizer.appendingPathComponent("tokens.txt").path
        guard let handle = localscribe_gigaam_create(encoder, decoder, joiner, tokens) else {
            throw ScribeError.message("Не удалось запустить локальный движок GigaAM.")
        }
        self.handle = handle
    }

    deinit { localscribe_gigaam_destroy(handle) }

    func recognize(_ samples: [Float]) throws -> GigaAMASREngine.Hypothesis {
        // The front end needs at least one complete analysis frame. Ownership
        // and timestamps are still bounded by the unpadded source in the mapper.
        let input = samples.count < 400 ? samples + Array(repeating: 0, count: 400 - samples.count) : samples
        let json = input.withUnsafeBufferPointer { buffer in
            localscribe_gigaam_recognize(handle, buffer.baseAddress, Int32(buffer.count))
        }
        guard let json else { throw ScribeError.message("GigaAM не смогла обработать фрагмент аудио.") }
        defer { localscribe_gigaam_free_result(json) }
        let data = Data(bytes: json, count: strlen(json))
        return try JSONDecoder().decode(GigaAMASREngine.Hypothesis.self, from: data)
    }
}
