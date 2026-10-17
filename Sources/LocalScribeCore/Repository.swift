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
    public func importFile(_ source: URL, info: AudioInfo, allowDuplicate: Bool = false) throws -> Manifest {
        let fm = FileManager.default
        let digest = try Disk.hash(source)
        if !allowDuplicate, let duplicate = list().first(where: { $0.sha256 == digest }) { throw DuplicateRecording(id: duplicate.id) }
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        try Disk.requireSpace(Int64(size) + Int64(info.duration * 32_000) + 500_000_000, at: root)
        var manifest = Manifest(sourceType: "import", title: source.deletingPathExtension().lastPathComponent, filename: source.lastPathComponent)
        let folder = folder(manifest.id); try Disk.directory(folder.appendingPathComponent("source"))
        let original = folder.appendingPathComponent(manifest.originalRelativePath)
        let partial = original.appendingPathExtension("partial")
        try fm.copyItem(at: source, to: partial)
        guard try Disk.hash(partial) == digest else { throw ScribeError.message("Не удалось проверить сохранённый оригинал") }
        try fm.moveItem(at: partial, to: original)
        manifest.sha256 = digest; manifest.durationMs = Int((info.duration * 1000).rounded()); manifest.sampleRate = info.sampleRate; manifest.channels = info.channels; manifest.sourceComplete = true; manifest.state = .queued
        try save(manifest)
        return manifest
    }
    public func beginRun(_ manifest: inout Manifest, catalog: ModelCatalog, summaryLanguage: String? = nil, summaryOnly: Bool = false) throws -> RunInfo {
        var info = RunInfo(sourceHash: manifest.sha256, profileHash: catalog.fingerprint, summaryLanguage: summaryLanguage)
        var modelIDs: [String: String] = [:]
        for profile in catalog.models {
            guard let role = profile.purpose else { continue }
            guard modelIDs[role.rawValue] == nil else { throw ScribeError.message("Выберите одну модель для каждого этапа обработки") }
            modelIDs[role.rawValue] = profile.id
        }
        info.modelIDs = modelIDs
        info.transcriptSourceRunID = summaryOnly ? manifest.activeRunId : nil
        let path = run(manifest.id, info.id); try Disk.directory(path)
        try Disk.write(info, to: path.appendingPathComponent("run.json"))
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
        manifest.pendingRunId = info.id; manifest.state = .queued; manifest.lastError = nil; try save(manifest)
        return info
    }
    public func results(_ manifest: Manifest) -> (Transcript?, Summary?) {
        let selected = manifest.activeRunId ?? manifest.pendingRunId
        guard let selected else { return (nil, nil) }
        let path = run(manifest.id, selected)
        var t = (try? Disk.read(Transcript.self, at: path.appendingPathComponent("transcript.json"))) ?? (try? Disk.read(Transcript.self, at: path.appendingPathComponent("asr-transcript.json")))
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
    }
    public func recover() throws {
        for var m in list() {
            guard m.schemaVersion == 1 else { continue }
            if m.state.processing || m.state == .queued { m.state = .interrupted; try save(m) }
            if m.state == .recording {
                m.state = .interrupted; m.warnings.append("Запись была прервана. Завершённые фрагменты сохранены; последний фрагмент мог быть утрачен.")
                try save(m)
            }
        }
    }
}
public struct DuplicateRecording: Error { public let id: String }
