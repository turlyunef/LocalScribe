import Foundation
import LocalScribeCore
import WhisperKit
import SpeakerKit
import ArgmaxCore

actor Pipeline {
    let command: WorkerCommand
    let emit: @Sendable (String, String, String?) -> Void
    let recording: URL; let run: URL; let models: URL; let tools: URL
    let manifest: Manifest; let info: RunInfo
    var wave: URL { run.appendingPathComponent("work/audio.wav") }
    init(command: WorkerCommand, emit: @escaping @Sendable (String, String, String?) -> Void) throws {
        self.command = command; self.emit = emit
        recording = URL(fileURLWithPath: command.recordingPath); run = recording.appendingPathComponent("runs/\(command.runId)")
        models = URL(fileURLWithPath: command.modelsPath); tools = URL(fileURLWithPath: command.toolsPath)
        manifest = try Disk.read(Manifest.self, at: recording.appendingPathComponent("manifest.json"))
        info = try Disk.read(RunInfo.self, at: run.appendingPathComponent("run.json"))
        guard command.jobId == manifest.id, command.runId == info.id, info.sourceHash == manifest.sha256,
              manifest.sourceComplete, try Disk.hash(recording.appendingPathComponent(manifest.originalRelativePath)) == info.sourceHash else { throw ScribeError.message("Исходник изменился или не завершён") }
    }
    func perform() async throws -> String {
        switch command.stage {
        case .preparingAudio:
            try Disk.requireSpace(Int64(manifest.durationMs) * 32 + 500_000_000, at: run)
            if let warning = try Media.prepare(recording.appendingPathComponent(manifest.originalRelativePath), to: wave, tools: tools) { emit("warning", warning, nil) }
            try Disk.write(["fingerprint": info.fingerprint], to: run.appendingPathComponent("prepared.json"))
            return "prepared.json"
        case .transcribing: return try await transcribe()
        case .diarizing: return try await diarize()
        case .summarizing:
            let transcript = try Disk.read(Transcript.self, at: run.appendingPathComponent("transcript.json"))
            if transcript.segments.isEmpty {
                try Disk.write(Summary(language: info.summaryLanguage ?? "ru"), to: run.appendingPathComponent("summary.json")); return "summary.json"
            }
            try await SummaryEngine(modelFolder: models.appendingPathComponent("summary"), run: run, emit: emit).summarize(transcript, language: info.summaryLanguage ?? transcript.primaryLanguage)
            return "summary.json"
        }
    }
    func transcribe() async throws -> String {
        let folder = models.appendingPathComponent("asr"), tokenizer = models.appendingPathComponent("tokenizer")
        guard FileManager.default.fileExists(atPath: tokenizer.appendingPathComponent("tokenizer.json").path), FileManager.default.fileExists(atPath: tokenizer.appendingPathComponent("tokenizer_config.json").path) else { throw ScribeError.message("Отсутствует локальный токенизатор Whisper") }
        let kit = try await WhisperKit(WhisperKitConfig(modelFolder: folder.path, tokenizerFolder: tokenizer, verbose: false, logLevel: .none, prewarm: true, load: true, download: false))
        let count = max(1, Int(ceil(Double(manifest.durationMs) / 300_000)))
        var parts: [ASRPart] = []
        for index in 0..<count {
            let coreStart = index * 300_000, coreEnd = min(manifest.durationMs, (index + 1) * 300_000)
            let path = run.appendingPathComponent("asr/part-\(index).json")
            if let saved = try? Disk.read(ASRPart.self, at: path), saved.fingerprint == info.fingerprint, saved.index == index, saved.startMs == coreStart, saved.endMs == coreEnd {
                try Transcript(fingerprint: info.fingerprint, diarized: false, segments: saved.segments).validate(durationMs: manifest.durationMs)
                parts.append(saved); continue
            }
            emit("progress", "Распознаём речь — часть \(index + 1) из \(count)", nil)
            var segments: [Segment] = []
            var offset = coreStart
            while offset < coreEnd {
                let planning = try Media.samples(wave, start: Double(offset)/1000, duration: Double(min(coreEnd-offset,30_000))/1000)
                let length = max(1, Analysis.nextASRWindowLength(planning) / 16)
                let end = min(coreEnd, offset + length)
                let readStart = max(0, offset - 1000), readEnd = min(manifest.durationMs, end + 1000)
                let samples = try Media.samples(wave, start: Double(readStart)/1000, duration: Double(readEnd-readStart)/1000)
                let energy = samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(max(1, samples.count))
                if energy > 1e-12 {
                    let options = DecodingOptions(verbose: false, task: .transcribe, language: nil, temperatureFallbackCount: 2, detectLanguage: true, skipSpecialTokens: true, wordTimestamps: true, concurrentWorkerCount: 1)
                    let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
                    for result in results {
                        for s in result.segments {
                            if s.noSpeechProb > 0.6 && s.avgLogprob < -1 { continue }
                            let uncertain = s.avgLogprob < -1 || s.compressionRatio > 2.4 || s.noSpeechProb > 0.6
                            let hadWords = !(s.words ?? []).isEmpty
                            var words = (s.words ?? []).map { Word(text: $0.word, startMs: max(0, min(manifest.durationMs, readStart + Int($0.start * 1000))), endMs: max(0, min(manifest.durationMs, readStart + Int($0.end * 1000)))) }
                            words = words.filter { let mid = ($0.startMs + $0.endMs) / 2; return mid >= offset && mid < end }
                            if hadWords && words.isEmpty { continue }
                            let start = words.first?.startMs ?? max(offset, readStart + Int(s.start * 1000))
                            let segmentEnd = words.last?.endMs ?? min(end, readStart + Int(s.end * 1000))
                            let text = words.isEmpty ? s.text : words.map(\.text).joined()
                            guard start < coreEnd, segmentEnd >= start, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                            if s.compressionRatio > 3.5 { segments.append(Segment(id: "tmp", startMs: start, endMs: segmentEnd, text: "[неразборчиво]", language: result.language, uncertain: true)); continue }
                            segments.append(Segment(id: "tmp", startMs: start, endMs: segmentEnd, text: text, language: Analysis.language(text, fallback: result.language), uncertain: uncertain, words: words))
                        }
                    }
                }
                offset = end
            }
            for i in segments.indices { segments[i].id = "part-\(index)-seg-\(i)" }
            let part = ASRPart(fingerprint: info.fingerprint, index: index, startMs: coreStart, endMs: coreEnd, segments: segments)
            try Disk.write(part, to: path); parts.append(part); emit("checkpoint", "", "asr/part-\(index).json")
        }
        let transcript = Analysis.mergeParts(parts, fingerprint: info.fingerprint)
        try transcript.validate(durationMs: manifest.durationMs)
        try Disk.write(transcript, to: run.appendingPathComponent("asr-transcript.json"))
        return "asr-transcript.json"
    }
    func diarize() async throws -> String {
        let transcript = try Disk.read(Transcript.self, at: run.appendingPathComponent("asr-transcript.json"))
        if transcript.segments.isEmpty {
            try Disk.write(Transcript(fingerprint: info.fingerprint, diarized: true, segments: []), to: run.appendingPathComponent("transcript.json")); return "transcript.json"
        }
        let config = PyannoteConfig(modelFolder: models.appendingPathComponent("diarization").path, download: false, load: true, verbose: false, logLevel: .none, concurrentSegmenterWorkers: 1, concurrentEmbedderWorkers: 1)
        let kit = try await SpeakerKit(config)
        let samples = try Media.samples(wave)
        let result = try await kit.diarize(audioArray: samples)
        let intervals = result.segments.compactMap { s -> VoiceInterval? in
            guard let id = s.speaker.speakerId else { return nil }
            return VoiceInterval(startMs: max(0, Int(s.startTime * 1000)), endMs: min(manifest.durationMs, Int(s.endTime * 1000)), speakerId: "raw-\(id)")
        }
        guard !intervals.isEmpty else { throw ScribeError.message("Участники не определены. Расшифровка сохранена; можно повторить диаризацию.") }
        try Disk.write(DiarizationArtifact(fingerprint: info.fingerprint, intervals: intervals), to: run.appendingPathComponent("diarization.json"))
        let mapped = Analysis.assignSpeakers(transcript, intervals: intervals)
        try mapped.validate(durationMs: manifest.durationMs)
        try Disk.write(mapped, to: run.appendingPathComponent("transcript.json"))
        return "transcript.json"
    }
}
