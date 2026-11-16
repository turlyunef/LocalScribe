import Foundation
import LocalScribeCore
import LocalScribeSpeakerKit
import ArgmaxCore

actor Pipeline {
    let command: WorkerCommand
    let emit: @Sendable (String, String, String?) -> Void
    let recording: URL; let run: URL; let models: URL; let tools: URL
    let manifest: Manifest; let info: RunInfo
    let stage: Stage
    let engineFactory: ASREngineFactory
    let hardware: ModelHardware
    var wave: URL { run.appendingPathComponent("work/audio.wav") }
    private func modelFolder(_ role: ModelRole) throws -> URL { models.appendingPathComponent(try info.modelID(for: role)) }
    init(command: WorkerCommand, hardware: ModelHardware = .current, engineFactory: ASREngineFactory = .init(), emit: @escaping @Sendable (String, String, String?) -> Void) throws {
        guard UUID(uuidString: command.jobId) != nil, UUID(uuidString: command.runId) != nil,
              let stage = command.stage, let recordingPath = command.recordingPath, let toolsPath = command.toolsPath else { throw ScribeError.message("Некорректный идентификатор задания") }
        self.engineFactory = engineFactory; self.command = command; self.emit = emit; self.hardware = hardware; self.stage = stage
        recording = URL(fileURLWithPath: recordingPath); run = recording.appendingPathComponent("runs/\(command.runId)")
        models = URL(fileURLWithPath: command.modelsPath); tools = URL(fileURLWithPath: toolsPath)
        manifest = try Disk.read(Manifest.self, at: recording.appendingPathComponent("manifest.json"))
        info = try Disk.read(RunInfo.self, at: run.appendingPathComponent("run.json"))
        guard manifest.schemaVersion == 1, (0...Manifest.maximumDurationMs).contains(manifest.durationMs),
              info.schemaVersion == 1,
              recording.lastPathComponent == command.jobId, command.jobId == manifest.id, command.runId == info.id else {
            throw ScribeError.message("Некорректное задание обработки")
        }
        // The version gate is stage-independent: summary and diarization
        // checkpoints are keyed by the run fingerprint, which does not change
        // when only a prompt literal is bumped between builds, so a run saved
        // by an older pipeline must be rejected on every resumed stage, not
        // only .transcribing. RecordingRepository.resumeRun verifies the
        // version before a job is enqueued; this is the worker-side second
        // line of defense. New runs always carry the current version, and the
        // --probe-* entry points never construct a Pipeline.
        if info.pipelineVersion != RunInfo.currentPipelineVersion {
            throw ScribeError.message("Версия обработки изменилась; контрольные точки этого задания несовместимы")
        }
        if command.liveCapture == true {
            let capture = try Disk.read(RunInfo.self, at: run.appendingPathComponent("capture-run.json"))
            guard stage == .transcribing, info.liveCapture == true, info.sourceHash == "capture:" + info.id,
                  manifest.pendingRunId == info.id, capture.schemaVersion == 1, capture.id == info.id, capture.fingerprint == info.fingerprint,
                  capture.modelIDs == info.modelIDs, capture.auxiliaryModelIDs == info.auxiliaryModelIDs,
                  capture.recognitionTerms == info.recognitionTerms else { throw ScribeError.message("Некорректное задание фонового распознавания") }
        } else {
            guard info.sourceHash == manifest.sha256, manifest.sourceComplete, manifest.durationMs > 0,
                  try Disk.hash(recording.appendingPathComponent(manifest.originalRelativePath)) == info.sourceHash else { throw ScribeError.message("Исходник изменился или не завершён") }
        }
    }
    func perform() async throws -> String {
        let metrics = stage == .transcribing ? ASRMetricsRecorder(run: run, liveCapture: command.liveCapture == true) : nil
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
        let catalog = try Disk.read(ModelCatalog.self, at: tools.deletingLastPathComponent().appendingPathComponent("models.lock.json"))
        let pinned = try catalog.pinned(to: info)
        let role: ModelRole? = stage == .transcribing ? .asr : stage == .diarizing ? .diarization : stage == .summarizing ? .summary : nil
        let summaryFolder: URL?
        if let role {
            guard let profile = pinned.models.first(where: { $0.purpose == role }) else { throw ScribeError.message("Модель этапа отсутствует") }
            try hardware.requireCompatibility(for: profile)
            summaryFolder = role == .summary ? try catalog.verifiedModelFolder(for: profile, at: models) : nil
            if role == .diarization { try profile.validate(at: models) }
        } else {
            summaryFolder = nil
        }
        if command.liveCapture == true {
            guard pinned.models.first(where: { $0.purpose == .asr })?.supportsClosedFragments == true else {
                throw ScribeError.message("Выбранная модель поддерживает только обработку готовой записи")
            }
            return try await LiveTranscriber(recording: recording, run: run, info: info, models: models, tools: tools, emit: emit, metrics: asrMetrics, engineFactory: engineFactory).perform()
        }
        switch stage {
        case .preparingAudio:
            try Disk.requireSpace(Int64(manifest.durationMs) * 32 + 500_000_000, at: run)
            if let warning = try Media.prepare(recording.appendingPathComponent(manifest.originalRelativePath), to: wave, tools: tools) { emit("warning", warning, nil) }
            let frames = try ASRAudioInput.requireFormat(wave)
            try Disk.write(["fingerprint": info.fingerprint, "pcmFrames": String(frames)], to: run.appendingPathComponent("prepared.json"))
            return "prepared.json"
        case .transcribing: return try await transcribe(catalog: catalog, metrics: asrMetrics)
        case .diarizing: return try await diarize()
        case .summarizing:
            guard let summaryFolder else { throw ScribeError.message("Модель этапа отсутствует") }
            let transcript = try summaryTranscript()
            if transcript.segments.isEmpty {
                try Disk.write(Summary(language: info.summaryLanguage ?? "ru"), to: run.appendingPathComponent("summary.json")); return "summary.json"
            }
            try await SummaryEngine(modelFolder: summaryFolder, run: run, emit: emit).summarize(transcript, language: info.summaryLanguage ?? transcript.primaryLanguage)
            return "summary.json"
        }
    }
    func summaryTranscript() throws -> Transcript {
        let transcript = try Disk.read(Transcript.self, at: run.appendingPathComponent("transcript.json"))
        guard transcript.fingerprint == info.fingerprint else {
            throw ScribeError.message("Нарушена целостность расшифровки для итогов")
        }
        try transcript.validate(durationMs: manifest.durationMs)
        return transcript
    }
    private func transcribe(catalog: ModelCatalog, metrics: ASRMetricsRecorder?) async throws -> String {
        let availableEndMs = try preparedAudioEndMs()
        let recognizer = try await engineFactory.make(info: info, catalog: catalog, models: models, metrics: metrics, warning: { [emit] in emit("warning", $0, nil) })
        let partMs = ASRCheckpointLayout.offlinePartMs
        let count = (manifest.durationMs - 1) / partMs + 1
        var parts: [ASRPart] = []
        for index in 0..<count {
            try Task.checkCancellation()
            let coreStart = index * partMs, coreEnd = min(manifest.durationMs, (index + 1) * partMs)
            let path = run.appendingPathComponent("asr/part-\(index).json")
            if let saved = try? Disk.read(ASRPart.self, at: path), saved.schemaVersion == 1,
               saved.fingerprint == info.fingerprint, saved.index == index, saved.startMs == coreStart, saved.endMs == coreEnd {
                try Transcript(fingerprint: info.fingerprint, diarized: false, segments: saved.segments).validate(durationMs: manifest.durationMs)
                metrics?.checkpoint(milliseconds: coreEnd - coreStart)
                parts.append(saved); continue
            }
            emit("progress", "Распознаём речь — часть \(index + 1) из \(count)", nil)
            var segments: [Segment] = []
            let audioEnd = min(coreEnd, availableEndMs)
            if coreStart < audioEnd {
                segments = try await recognizer.recognize(ASRRequest(audioURL: wave, availableEndMs: availableEndMs,
                    coreRange: coreStart..<audioEnd, mode: .offline)).segments
            }
            for i in segments.indices { segments[i].id = "part-\(index)-seg-\(i)" }
            try Transcript(fingerprint: info.fingerprint, diarized: false, segments: segments).validate(durationMs: manifest.durationMs)
            let part = ASRPart(fingerprint: info.fingerprint, index: index, startMs: coreStart, endMs: coreEnd, segments: segments)
            try Task.checkCancellation()
            try Disk.write(part, to: path); parts.append(part); emit("checkpoint", "", "asr/part-\(index).json")
        }
        let transcript = Analysis.mergeParts(parts, fingerprint: info.fingerprint)
        try transcript.validate(durationMs: manifest.durationMs)
        try Task.checkCancellation()
        try Disk.write(transcript, to: run.appendingPathComponent("asr-transcript.json"))
        return "asr-transcript.json"
    }

    private func preparedAudioEndMs() throws -> Int {
        let marker = run.appendingPathComponent("prepared.json")
        guard let prepared = try? Disk.read([String: String].self, at: marker),
              prepared["fingerprint"] == info.fingerprint else { return manifest.durationMs }
        let frames = try ASRAudioInput.requireFormat(wave)
        guard frames > 0, abs(Double(frames) / 16 - Double(manifest.durationMs)) < 150,
              prepared["pcmFrames"].map({ Int64($0) == frames }) ?? true else {
            throw ScribeError.message("Длительность подготовленного аудио не совпала с заданием")
        }
        // Container timestamps can include a small trailing interval with no
        // decoded PCM. Preserve the recording/checkpoint timeline and read only
        // the available frames, rounding up to retain a fractional millisecond.
        return min(manifest.durationMs, Int((frames + 15) / 16))
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
        let pcm = try Media.PCMFrameReader(wave)
        let result = try await kit.diarize(frameCount: pcm.frameCount) { try pcm.read($0) }
        return result.segments.compactMap { s -> VoiceInterval? in
            guard let id = s.speaker.speakerId else { return nil }
            return VoiceInterval.clipped(startSeconds: Double(s.startTime), endSeconds: Double(s.endTime),
                                         speakerId: "raw-\(id)", durationMs: durationMs)
        }
    }
}
