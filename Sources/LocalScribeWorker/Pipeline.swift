import Foundation
import LocalScribeCore
import WhisperKit
import LocalScribeSpeakerKit
import ArgmaxCore

actor Pipeline {
    let command: WorkerCommand
    let emit: @Sendable (String, String, String?) -> Void
    let recording: URL; let run: URL; let models: URL; let tools: URL
    let manifest: Manifest; let info: RunInfo
    let hardware: ModelHardware
    var wave: URL { run.appendingPathComponent("work/audio.wav") }
    private func modelFolder(_ role: ModelRole) throws -> URL { models.appendingPathComponent(try info.modelID(for: role)) }
    init(command: WorkerCommand, hardware: ModelHardware = .current, emit: @escaping @Sendable (String, String, String?) -> Void) throws {
        guard UUID(uuidString: command.jobId) != nil, UUID(uuidString: command.runId) != nil else { throw ScribeError.message("Некорректный идентификатор задания") }
        self.command = command; self.emit = emit; self.hardware = hardware
        recording = URL(fileURLWithPath: command.recordingPath); run = recording.appendingPathComponent("runs/\(command.runId)")
        models = URL(fileURLWithPath: command.modelsPath); tools = URL(fileURLWithPath: command.toolsPath)
        manifest = try Disk.read(Manifest.self, at: recording.appendingPathComponent("manifest.json"))
        info = try Disk.read(RunInfo.self, at: run.appendingPathComponent("run.json"))
        guard manifest.schemaVersion == 1, (0...10_800_000).contains(manifest.durationMs),
              info.schemaVersion == 1, UUID(uuidString: command.jobId) != nil,
              recording.lastPathComponent == command.jobId, command.jobId == manifest.id, command.runId == info.id else {
            throw ScribeError.message("Некорректное задание обработки")
        }
        if command.liveCapture == true {
            let capture = try Disk.read(RunInfo.self, at: run.appendingPathComponent("capture-run.json"))
            guard command.stage == .transcribing, info.liveCapture == true, info.sourceHash == "capture:" + info.id,
                  manifest.pendingRunId == info.id, capture.id == info.id, capture.fingerprint == info.fingerprint,
                  capture.modelIDs == info.modelIDs, info.pipelineVersion == RunInfo(sourceHash: "", profileHash: "").pipelineVersion else { throw ScribeError.message("Некорректное задание фонового распознавания") }
        } else {
            guard info.sourceHash == manifest.sha256, manifest.sourceComplete, manifest.durationMs > 0,
                  try Disk.hash(recording.appendingPathComponent(manifest.originalRelativePath)) == info.sourceHash else { throw ScribeError.message("Исходник изменился или не завершён") }
        }
    }
    func perform() async throws -> String {
        let metrics = command.stage == .transcribing ? ASRMetricsRecorder(run: run, liveCapture: command.liveCapture == true) : nil
        do {
            let artifact = try await performStage(asrMetrics: metrics)
            metrics?.finish(status: "completed")
            return artifact
        } catch {
            metrics?.finish(status: error is CancellationError ? "cancelled" : "failed")
            throw error
        }
    }
    private func performStage(asrMetrics: ASRMetricsRecorder?) async throws -> String {
        let role: ModelRole? = command.stage == .transcribing ? .asr : command.stage == .diarizing ? .diarization : command.stage == .summarizing ? .summary : nil
        if let role {
            let catalog = try Disk.read(ModelCatalog.self, at: tools.deletingLastPathComponent().appendingPathComponent("models.lock.json"))
            let pinned = try catalog.pinned(to: info)
            guard let profile = pinned.models.first(where: { $0.purpose == role }) else { throw ScribeError.message("Модель этапа отсутствует") }
            try hardware.requireCompatibility(for: profile)
        }
        if command.liveCapture == true {
            return try await LiveTranscriber(recording: recording, run: run, info: info, models: models, tools: tools, emit: emit, metrics: asrMetrics).perform()
        }
        switch command.stage {
        case .preparingAudio:
            try Disk.requireSpace(Int64(manifest.durationMs) * 32 + 500_000_000, at: run)
            if let warning = try Media.prepare(recording.appendingPathComponent(manifest.originalRelativePath), to: wave, tools: tools) { emit("warning", warning, nil) }
            try Disk.write(["fingerprint": info.fingerprint], to: run.appendingPathComponent("prepared.json"))
            return "prepared.json"
        case .transcribing: return try await transcribe(metrics: asrMetrics)
        case .diarizing: return try await diarize()
        case .summarizing:
            let transcript = try Disk.read(Transcript.self, at: run.appendingPathComponent("transcript.json"))
            if transcript.segments.isEmpty {
                try Disk.write(Summary(language: info.summaryLanguage ?? "ru"), to: run.appendingPathComponent("summary.json")); return "summary.json"
            }
            try await SummaryEngine(modelFolder: modelFolder(.summary), run: run, emit: emit).summarize(transcript, language: info.summaryLanguage ?? transcript.primaryLanguage)
            return "summary.json"
        }
    }
    func transcribe(metrics: ASRMetricsRecorder? = nil) async throws -> String {
        let recognizer = try await SpeechRecognizer(info: info, models: models, metrics: metrics, warning: { [emit] in emit("warning", $0, nil) })
        let count = max(1, Int(ceil(Double(manifest.durationMs) / 300_000)))
        var parts: [ASRPart] = []
        for index in 0..<count {
            let coreStart = index * 300_000, coreEnd = min(manifest.durationMs, (index + 1) * 300_000)
            let path = run.appendingPathComponent("asr/part-\(index).json")
            if let saved = try? Disk.read(ASRPart.self, at: path), saved.fingerprint == info.fingerprint, saved.index == index, saved.startMs == coreStart, saved.endMs == coreEnd {
                try Transcript(fingerprint: info.fingerprint, diarized: false, segments: saved.segments).validate(durationMs: manifest.durationMs)
                metrics?.checkpoint(milliseconds: coreEnd - coreStart)
                parts.append(saved); continue
            }
            emit("progress", "Распознаём речь — часть \(index + 1) из \(count)", nil)
            var segments = try await recognizer.recognize(wave: wave, coreStart: coreStart, coreEnd: coreEnd, durationMs: manifest.durationMs)
            for i in segments.indices { segments[i].id = "part-\(index)-seg-\(i)" }
            let part = ASRPart(fingerprint: info.fingerprint, index: index, startMs: coreStart, endMs: coreEnd, segments: segments)
            try Disk.write(part, to: path); parts.append(part); emit("checkpoint", "", "asr/part-\(index).json")
        }
        let transcript = Analysis.mergeParts(parts, fingerprint: info.fingerprint)
        try transcript.validate(durationMs: manifest.durationMs)
        try Disk.write(transcript, to: run.appendingPathComponent("asr-transcript.json"))
        return "asr-transcript.json"
    }
    func diarize(
        infer: @Sendable (URL, URL, Int) async throws -> [VoiceInterval] = { folder, wave, duration in
            try await Pipeline.inferSpeakers(modelFolder: folder, wave: wave, durationMs: duration)
        }
    ) async throws -> String {
        let transcript = try Disk.read(Transcript.self, at: run.appendingPathComponent("asr-transcript.json"))
        guard transcript.fingerprint == info.fingerprint, !transcript.diarized else {
            throw ScribeError.message("Некорректная контрольная точка распознавания")
        }
        try transcript.validate(durationMs: manifest.durationMs)
        try Task.checkCancellation()
        if transcript.segments.isEmpty {
            try Disk.write(Transcript(fingerprint: info.fingerprint, diarized: true, segments: []), to: run.appendingPathComponent("transcript.json")); return "transcript.json"
        }
        let intervals: [VoiceInterval]
        do {
            intervals = try await infer(modelFolder(.diarization), wave, manifest.durationMs)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ScribeError.message("Диаризация завершилась ошибкой. Расшифровка сохранена; можно повторить диаризацию.")
        }
        try Task.checkCancellation()
        guard !intervals.isEmpty else { throw ScribeError.message("Участники не определены. Расшифровка сохранена; можно повторить диаризацию.") }
        try Disk.write(DiarizationArtifact(fingerprint: info.fingerprint, intervals: intervals), to: run.appendingPathComponent("diarization.json"))
        let mapped = Analysis.assignSpeakers(transcript, intervals: intervals)
        try mapped.validate(durationMs: manifest.durationMs)
        try Disk.write(mapped, to: run.appendingPathComponent("transcript.json"))
        return "transcript.json"
    }

    nonisolated private static func inferSpeakers(modelFolder: URL, wave: URL, durationMs: Int) async throws -> [VoiceInterval] {
        let config = PyannoteConfig(modelFolder: modelFolder.path, download: false, load: true, verbose: false, logLevel: .none, concurrentSegmenterWorkers: 1, concurrentEmbedderWorkers: 1)
        let kit = try await SpeakerKit(config)
        let samples = try Media.samples(wave)
        let result = try await kit.diarize(audioArray: samples)
        return result.segments.compactMap { s -> VoiceInterval? in
            guard let id = s.speaker.speakerId else { return nil }
            return VoiceInterval.clipped(startSeconds: Double(s.startTime), endSeconds: Double(s.endTime),
                                         speakerId: "raw-\(id)", durationMs: durationMs)
        }
    }
}
