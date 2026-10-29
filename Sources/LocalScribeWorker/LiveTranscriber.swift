import Foundation
import LocalScribeCore

/// One worker owns the model for the entire capture. Only bounded windows enter RAM;
/// the backlog is closed CAFs and atomic JSON checkpoints on disk.
struct LiveTranscriber {
    let recording: URL
    let run: URL
    let info: RunInfo
    let models: URL
    let tools: URL
    let emit: @Sendable (String, String, String?) -> Void
    var metrics: ASRMetricsRecorder? = nil

    var engineFactory = ASREngineFactory()

    func perform() async throws -> String {
        emit("progress", "Загружаем модель фонового распознавания…", nil)
        let catalog = try Disk.read(ModelCatalog.self, at: tools.deletingLastPathComponent().appendingPathComponent("models.lock.json"))
        let recognizer = try await engineFactory.make(info: info, catalog: catalog, models: models, metrics: metrics, warning: { [emit] in emit("warning", $0, nil) })
        let folder = recording.appendingPathComponent("capture")
        let work = run.appendingPathComponent("work/live")
        try Disk.directory(work)
        var fragments: [CaptureFragment] = [], parts: [ASRPart] = []
        var offset = 0
        while true {
            try Task.checkCancellation()
            while FileManager.default.fileExists(atPath: folder.appendingPathComponent(String(format: "part-%06d.caf", fragments.count)).path) {
                fragments.append(try CaptureFragment.read(index: fragments.count, folder: folder))
                guard fragments.count <= 1081 else { throw ScribeError.message("Слишком много фрагментов записи") }
            }
            let sealURL = run.appendingPathComponent("capture-seal.json")
            let sealed = FileManager.default.fileExists(atPath: sealURL.path)
            let seal = sealed ? try Disk.read(CaptureSeal.self, at: sealURL) : nil
            if let seal {
                try seal.validate(info: info)
                // The seal can appear between scanning the directory and reading it.
                while fragments.count < seal.fragments.count {
                    fragments.append(try CaptureFragment.read(index: fragments.count, folder: folder))
                }
                guard fragments == seal.fragments else { throw ScribeError.message("Состав завершённого потока изменился") }
            }
            let available = Int(Double(fragments.reduce(0) { $0 + $1.frames }) / (fragments.first?.sampleRate ?? 1) * 1000)
            let end = min(offset + ASRCheckpointLayout.livePartMs, available)
            if sealed && offset == available { break }
            // Wait for right context; only a sealed stream may commit a short tail.
            if end <= offset || (!sealed && available < offset + ASRCheckpointLayout.livePartMs + ASRCheckpointLayout.liveContextMs) {
                emit("progress", "Фоновое распознавание: ожидаем закрытые фрагменты", nil)
                try await Task.sleep(for: .seconds(1)); continue
            }
            if ProcessInfo.processInfo.thermalState == .critical || ProcessInfo.processInfo.thermalState == .serious {
                emit("progress", "Распознавание ожидает охлаждения Mac; звук сохраняется", nil)
                try await Task.sleep(for: .seconds(2)); continue
            }
            let readStart = max(0, offset - ASRCheckpointLayout.liveContextMs), readEnd = min(available, end + ASRCheckpointLayout.liveContextMs)
            let inputs = fragments.filter { $0.index * 10_000 < readEnd && $0.index * 10_000 + $0.durationMs > readStart }
            let path = run.appendingPathComponent("live/part-\(parts.count).json")
            if FileManager.default.fileExists(atPath: path.path) {
                let saved = try Disk.read(LiveASRPart.self, at: path)
                try saved.validate(info: info, index: parts.count, startMs: offset, availableMs: available, fragments: inputs)
                guard saved.part.endMs == end, saved.readEndMs == readEnd else { throw ScribeError.message("Изменились границы фоновой контрольной точки") }
                metrics?.checkpoint(milliseconds: end - offset)
                parts.append(saved.part)
            } else {
                emit("progress", "Фоновое распознавание · \(timecode(offset))–\(timecode(end))", nil)
                let audio = work.appendingPathComponent("input.caf"), wave = work.appendingPathComponent("audio.wav")
                _ = try Media.assembleCaptureParts(inputs.map { folder.appendingPathComponent($0.filename) }, destination: audio)
                _ = try Media.prepare(audio, to: wave, tools: tools)
                var segments = try await recognizer.recognize(ASRRequest(audioURL: wave, originMs: inputs[0].index * 10_000,
                    availableEndMs: readEnd, coreRange: offset..<end, mode: .closedFragments)).segments
                for i in segments.indices { segments[i].id = "live-\(parts.count)-seg-\(i)" }
                // Detect a changed input before committing its recognition.
                for fragment in inputs where try Disk.hash(folder.appendingPathComponent(fragment.filename)) != fragment.sha256 {
                    throw ScribeError.message("Фрагмент изменился во время распознавания")
                }
                let part = ASRPart(fingerprint: info.fingerprint, index: parts.count, startMs: offset, endMs: end, segments: segments)
                let checkpoint = LiveASRPart(part: part, readStartMs: readStart, readEndMs: readEnd, fragments: inputs)
                try checkpoint.validate(info: info, index: parts.count, startMs: offset, availableMs: available, fragments: inputs)
                try Disk.write(checkpoint, to: path); parts.append(part)
                try? FileManager.default.removeItem(at: wave); try? FileManager.default.removeItem(at: audio)
                emit("checkpoint", "", "live/part-\(part.index).json")
            }
            offset = end
        }
        let seal = try Disk.read(CaptureSeal.self, at: run.appendingPathComponent("capture-seal.json"))
        let manifest = try Disk.read(Manifest.self, at: recording.appendingPathComponent("manifest.json"))
        guard seal.fragments == fragments, manifest.id == infoJobID, manifest.sourceComplete,
              manifest.sha256 == seal.sourceHash, manifest.durationMs == seal.durationMs else {
            throw ScribeError.message("Завершённый исходник не соответствует потоку записи")
        }
        try CaptureIntegrity.verify(seal, info: info, folder: folder, original: recording.appendingPathComponent(manifest.originalRelativePath))
        let transcript = Analysis.mergeParts(parts, fingerprint: info.fingerprint)
        try transcript.validate(durationMs: manifest.durationMs)
        try Disk.write(transcript, to: run.appendingPathComponent("live-transcript.json"))
        return "live-transcript.json"
    }
    private var infoJobID: String { recording.lastPathComponent }
}
