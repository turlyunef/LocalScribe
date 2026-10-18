import Foundation

public struct RecordingRepository: Sendable {
    public let root: URL
    public init(root: URL? = nil) throws {
        self.root = try root ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("LocalScribe", isDirectory: true)
        try Disk.directory(self.root.appendingPathComponent("recordings")); try Disk.directory(self.root.appendingPathComponent("models"))
    }
    public var models: URL { root.appendingPathComponent("models") }
    public func folder(_ id: String) -> URL { root.appendingPathComponent("recordings").appendingPathComponent(id) }
    public func run(_ id: String, _ runId: String) -> URL { folder(id).appendingPathComponent("runs").appendingPathComponent(runId) }
    public func save(_ manifest: Manifest) throws {
        guard manifest.schemaVersion == 1 else { throw ScribeError.message("Эта версия записи создана другим выпуском. Исходные файлы сохранены; обновите приложение.") }
        guard UUID(uuidString:manifest.id) != nil else { throw ScribeError.message("Недопустимый идентификатор записи") }
        try Disk.write(manifest, to: folder(manifest.id).appendingPathComponent("manifest.json"))
        // This index is only a convenience; manifests remain the source of truth.
        try? Disk.write(list(), to: root.appendingPathComponent("index.json"))
    }
    public func load(_ id: String) throws -> Manifest {
        guard UUID(uuidString:id) != nil else { throw ScribeError.message("Недопустимый идентификатор записи") }
        let manifest = try Disk.read(Manifest.self,at:folder(id).appendingPathComponent("manifest.json"))
        guard manifest.id == id else { throw ScribeError.message("Идентификатор записи не совпадает с её каталогом") }
        return manifest
    }
    public func list() -> [Manifest] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("recordings"), includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { try? load($0.lastPathComponent) }.sorted { $0.createdAt > $1.createdAt }
    }
    public func rename(_ id: String, title: String) throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ScribeError.message("Название записи не может быть пустым") }
        // Read the current manifest so renaming cannot restore stale processing state.
        var manifest = try load(id)
        manifest.displayTitle = title
        try save(manifest)
    }
    public func importFile(_ source: URL, info: AudioInfo, allowDuplicate: Bool = false) throws -> Manifest {
        let fm = FileManager.default
        let digest = try Disk.hash(source)
        if !allowDuplicate, let duplicate = list().first(where: { $0.sha256 == digest }) { throw DuplicateRecording(id: duplicate.id) }
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        try Disk.requireSpace(Int64(size) + Int64(info.duration * 32_000) + 500_000_000, at: root)
        var manifest = Manifest(sourceType: "import", title: source.deletingPathExtension().lastPathComponent, filename: source.lastPathComponent)
        let folder = folder(manifest.id)
        var published = false
        defer { if !published { try? fm.removeItem(at: folder) } }
        try Disk.directory(folder.appendingPathComponent("source"))
        let original = folder.appendingPathComponent(manifest.originalRelativePath)
        let partial = original.appendingPathExtension("partial")
        try fm.copyItem(at: source, to: partial)
        guard try Disk.hash(partial) == digest else { throw ScribeError.message("Не удалось проверить сохранённый оригинал") }
        try fm.moveItem(at: partial, to: original)
        manifest.sha256 = digest; manifest.durationMs = Int((info.duration * 1000).rounded()); manifest.sampleRate = info.sampleRate; manifest.channels = info.channels; manifest.sourceComplete = true; manifest.state = .queued
        try save(manifest)
        published = true
        return manifest
    }
    public func beginRun(_ manifest: inout Manifest, catalog: ModelCatalog, summaryLanguage: String? = nil, summaryOnly: Bool = false, liveCapture: Bool = false) throws -> RunInfo {
        if liveCapture {
            guard !summaryOnly, !manifest.sourceComplete, manifest.state == .recording, manifest.sourceType == "microphone" else {
                throw ScribeError.message("Фоновое распознавание требует незавершённой записи микрофона")
            }
        }
        var info = RunInfo(sourceHash: manifest.sha256, profileHash: catalog.fingerprint, summaryLanguage: summaryLanguage)
        var modelIDs: [String: String] = [:]
        for profile in catalog.models {
            guard let role = profile.purpose else { continue }
            guard modelIDs[role.rawValue] == nil else { throw ScribeError.message("Выберите одну модель для каждого этапа обработки") }
            modelIDs[role.rawValue] = profile.id
        }
        info.modelIDs = modelIDs
        if liveCapture { info.liveCapture = true; info.sourceHash = "capture:" + info.id }
        info.transcriptSourceRunID = summaryOnly ? manifest.activeRunId : nil
        let path = run(manifest.id, info.id)
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at: path) } }
        try Disk.directory(path)
        try Disk.write(info, to: path.appendingPathComponent("run.json"))
        if liveCapture { try Disk.write(info, to: path.appendingPathComponent("capture-run.json")) }
        if summaryOnly, let active = manifest.activeRunId {
            for name in ["asr-transcript.json", "transcript.json", "diarization.json"] {
                let source = run(manifest.id, active).appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: source.path) {
                    if name != "diarization.json" {
                        var transcript = try Disk.read(Transcript.self, at: source)
                        try transcript.validate(durationMs: manifest.durationMs)
                        transcript.fingerprint = info.fingerprint
                        try Disk.write(transcript, to: path.appendingPathComponent(name))
                    } else { try FileManager.default.copyItem(at: source, to: path.appendingPathComponent(name)) }
                }
            }
        }
        var updated = manifest
        updated.pendingRunId = info.id; updated.state = liveCapture ? .recording : .queued; updated.captureProcessing = liveCapture ? .queued : nil; updated.lastError = nil; try save(updated)
        manifest = updated; published = true
        return info
    }
    /// Publish a final fingerprint only after proving the streamed PCM belongs to
    /// the completed, hashed original. Re-running this transaction is safe after a crash.
    public func bindLiveTranscript(_ id: String, info: RunInfo) throws -> RunInfo {
        let manifest = try load(id), path = run(id, info.id)
        let captureInfo = try Disk.read(RunInfo.self, at: path.appendingPathComponent("capture-run.json"))
        let seal = try Disk.read(CaptureSeal.self, at: path.appendingPathComponent("capture-seal.json"))
        guard manifest.sourceComplete, manifest.pendingRunId == info.id,
              captureInfo.id == info.id, captureInfo.liveCapture == true,
              captureInfo.sourceHash == "capture:" + info.id, seal.sourceHash == manifest.sha256,
              seal.durationMs == manifest.durationMs else { throw ScribeError.message("Нельзя присоединить фоновую расшифровку к оригиналу") }
        try CaptureIntegrity.verify(seal, info: captureInfo, folder: folder(id).appendingPathComponent("capture"), original: folder(id).appendingPathComponent(manifest.originalRelativePath))
        var parts: [ASRPart] = [], offset = 0
        while offset < seal.durationMs {
            let end = min(offset + 30_000, seal.durationMs), readEnd = min(end + 1000, seal.durationMs)
            let fragments = seal.fragments.filter { $0.index * 10_000 < readEnd && $0.index * 10_000 + $0.durationMs > max(0, offset - 1000) }
            let saved = try Disk.read(LiveASRPart.self, at: path.appendingPathComponent("live/part-\(parts.count).json"))
            try saved.validate(info: captureInfo, index: parts.count, startMs: offset, availableMs: seal.durationMs, fragments: fragments)
            guard saved.part.endMs == end, saved.readEndMs == readEnd else { throw ScribeError.message("Неполная фоновая расшифровка") }
            parts.append(saved.part); offset = end
        }
        var final = captureInfo; final.sourceHash = seal.sourceHash
        let transcript = Analysis.mergeParts(parts, fingerprint: final.fingerprint)
        try transcript.validate(durationMs: manifest.durationMs)
        try Disk.write(transcript, to: path.appendingPathComponent("asr-transcript.json"))
        try Disk.write(final, to: path.appendingPathComponent("run.json"))
        return final
    }
    public func results(_ manifest: Manifest) -> (Transcript?, Summary?) {
        let selected = manifest.activeRunId ?? manifest.pendingRunId
        guard let selected else { return (nil, nil) }
        let path = run(manifest.id, selected)
        var t = (try? Disk.read(Transcript.self, at: path.appendingPathComponent("transcript.json"))) ?? (try? Disk.read(Transcript.self, at: path.appendingPathComponent("asr-transcript.json")))
        if t == nil, let info = try? Disk.read(RunInfo.self, at: path.appendingPathComponent("capture-run.json")), info.liveCapture == true {
            let urls = (try? FileManager.default.contentsOfDirectory(at: path.appendingPathComponent("live"), includingPropertiesForKeys: nil)) ?? []
            let parts = urls.compactMap { try? Disk.read(LiveASRPart.self, at: $0) }.filter { saved in
                guard info.schemaVersion == 1, info.id == selected, info.sourceHash == "capture:" + info.id,
                      (0...360).contains(saved.part.index), saved.part.startMs == saved.part.index * 30_000,
                      !saved.fragments.isEmpty, saved.fragments.count <= 5 else { return false }
                return (try? saved.validate(info: info, index: saved.part.index, startMs: saved.part.startMs,
                                            availableMs: saved.readEndMs, fragments: saved.fragments)) != nil
            }.map(\.part)
            if !parts.isEmpty { t = Analysis.mergeParts(parts, fingerprint: info.fingerprint) }
        }
        if t == nil, let info = try? Disk.read(RunInfo.self, at: path.appendingPathComponent("run.json")), info.sourceHash == manifest.sha256 {
            let urls = (try? FileManager.default.contentsOfDirectory(at: path.appendingPathComponent("asr"), includingPropertiesForKeys: nil)) ?? []
            let parts = urls.compactMap { try? Disk.read(ASRPart.self, at: $0) }.filter { part in
                part.schemaVersion == 1 && part.fingerprint == info.fingerprint && part.index >= 0 && part.startMs == part.index * 300_000 && part.endMs == min(manifest.durationMs,(part.index+1)*300_000) && (try? Transcript(fingerprint:info.fingerprint,diarized:false,segments:part.segments).validate(durationMs:manifest.durationMs)) != nil
            }
            if !parts.isEmpty { t = Analysis.mergeParts(parts, fingerprint: info.fingerprint) }
        }
        return (t, try? Disk.read(Summary.self, at: path.appendingPathComponent("summary.json")))
    }
    public func delete(_ manifest: Manifest) throws {
        guard UUID(uuidString: manifest.id) != nil else { throw ScribeError.message("Недопустимый идентификатор записи") }
        try FileManager.default.removeItem(at: folder(manifest.id))
        try? Disk.write(list(), to: root.appendingPathComponent("index.json"))
    }
    /// Call only after capture/worker exit. Audio caches are reproducible; JSON
    /// checkpoints and unfinished capture fragments remain available for recovery.
    public func cleanupTemporaryFiles(_ id: String) throws {
        let manifest = try load(id)
        guard manifest.schemaVersion == 1, manifest.sourceComplete,
              !manifest.state.processing, manifest.state != .recording else { return }
        let fm = FileManager.default, recording = folder(id)
        func ownedDirectory(_ url: URL) -> Bool {
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
            return values.isDirectory == true && values.isSymbolicLink != true
        }
        guard ownedDirectory(recording) else { return }
        let components = manifest.originalRelativePath.split(separator: "/")
        guard components.count == 2, components[0] == "source", components[1].hasPrefix("original."),
              ownedDirectory(recording.appendingPathComponent("source")) else { return }
        let original = recording.appendingPathComponent(manifest.originalRelativePath)
        // Live fragments are the verifiable input of unfinished checkpoints. A crash,
        // failure or cancellation must not remove them before the final ASR is bound.
        let pending = manifest.pendingRunId.flatMap { try? Disk.read(RunInfo.self, at: run(id, $0).appendingPathComponent("run.json")) }
        var needsCapture = manifest.pendingRunId != nil && pending == nil
        if let pending, pending.liveCapture == true {
            let transcript = try? Disk.read(Transcript.self, at: run(id, pending.id).appendingPathComponent("asr-transcript.json"))
            needsCapture = pending.sourceHash != manifest.sha256 || transcript?.fingerprint != pending.fingerprint
                || transcript.map { (try? $0.validate(durationMs: manifest.durationMs)) == nil } != false
        }
        var disposable = [original.appendingPathExtension("assembling.caf")]
        if !needsCapture { disposable.append(recording.appendingPathComponent("capture")) }
        let runs = recording.appendingPathComponent("runs")
        if ownedDirectory(runs) {
            for run in (try? fm.contentsOfDirectory(at: runs, includingPropertiesForKeys: nil)) ?? [] {
                guard UUID(uuidString: run.lastPathComponent) != nil, ownedDirectory(run),
                      let info = try? Disk.read(RunInfo.self, at: run.appendingPathComponent("run.json")),
                      info.schemaVersion == 1, info.id == run.lastPathComponent, info.sourceHash == manifest.sha256 else { continue }
                disposable.append(run.appendingPathComponent("work"))
            }
        }
        disposable = disposable.filter { fm.fileExists(atPath: $0.path) }
        guard !disposable.isEmpty else { return }
        // Never discard the last usable copy if an original was lost or changed.
        guard try Disk.hash(original) == manifest.sha256 else { return }
        for url in disposable { try fm.removeItem(at: url) }
    }
    public func recover() throws {
        for var m in list() {
            guard m.schemaVersion == 1 else { continue }
            if m.state.processing || m.state == .queued { m.state = .interrupted; try save(m) }
            if m.captureProcessing != nil { m.captureProcessing = .interrupted; try save(m) }
            if m.state == .recording {
                m.state = .interrupted; m.warnings.append("Запись была прервана. Завершённые фрагменты сохранены; последний фрагмент мог быть утрачен.")
                try save(m)
            }
            // Best effort: a cleanup failure must not make the archive unavailable.
            try? cleanupTemporaryFiles(m.id)
        }
    }
}
public struct DuplicateRecording: Error { public let id: String }
