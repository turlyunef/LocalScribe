import Foundation
import Synchronization

/// Reader-side cache of decoded checkpoint parts for periodic checkpoint
/// reloads. The worker writes each `part-N.json` exactly once, so a hit keyed
/// by (URL, file size, modification date) means the file still holds exactly
/// the bytes that were decoded before; every semantic check (fingerprint,
/// bounds, merge, transcript validation) still runs on every call, and final
/// artifacts (`transcript.json`/`summary.json`) are never cached. A changed
/// or unreadable stamp falls back to a full read, so a damaged part surfaces
/// exactly as it would without the cache.
public final class ResultCheckpointCache: @unchecked Sendable {
    private struct Entry { var size: Int?; var modified: Date?; var asr: ASRPart?; var live: LiveASRPart? }
    private let entries = Mutex<[URL: Entry]>([:])

    public init() {}

    static func stamp(_ url: URL) -> (Int?, Date?) {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return (values?.fileSize, values?.contentModificationDate)
    }

    fileprivate func asrPart(at url: URL) -> ASRPart? {
        let (size, modified) = Self.stamp(url)
        return entries.withLock { entries in
            guard let entry = entries[url], entry.asr != nil,
                  entry.size == size, entry.modified == modified else { return nil }
            return entry.asr
        }
    }

    fileprivate func livePart(at url: URL) -> LiveASRPart? {
        let (size, modified) = Self.stamp(url)
        return entries.withLock { entries in
            guard let entry = entries[url], entry.live != nil,
                  entry.size == size, entry.modified == modified else { return nil }
            return entry.live
        }
    }

    /// The stamp is taken before the read: if the file is replaced while it is
    /// being decoded, the stored stamp no longer matches the file and the next
    /// call re-reads it.
    fileprivate func store(_ part: ASRPart, at url: URL, stamp: (Int?, Date?)) {
        entries.withLock { entries in
            entries[url] = Entry(size: stamp.0, modified: stamp.1, asr: part, live: nil)
        }
    }

    fileprivate func store(_ part: LiveASRPart, at url: URL, stamp: (Int?, Date?)) {
        entries.withLock { entries in
            entries[url] = Entry(size: stamp.0, modified: stamp.1, asr: nil, live: part)
        }
    }

    /// Keeps only the parts of the latest read so the cache stays bounded to
    /// the currently open run even when the selection moves between records.
    fileprivate func retain(_ urls: Set<URL>) {
        entries.withLock { entries in
            for url in entries.keys where !urls.contains(url) { entries.removeValue(forKey: url) }
        }
    }
}

extension RecordingRepository {
    /// Follow copied transcripts through summary-only and manual revisions.
    /// Missing provenance must not substitute the user's current ASR choice.
    public func transcriptionModelID(_ manifest: Manifest) -> String? {
        guard UUID(uuidString: manifest.id) != nil else { return nil }
        var selected = manifest.activeRunId ?? manifest.pendingRunId
        var visited: Set<String> = []
        while let id = selected {
            guard UUID(uuidString: id) != nil, visited.insert(id).inserted,
                  let info = try? Disk.read(RunInfo.self, at: run(manifest.id, id).appendingPathComponent("run.json")),
                  (try? validateResultRun(info, id: id)) != nil,
                  info.sourceHash == manifest.sha256 || (info.liveCapture == true && info.sourceHash == "capture:" + id) else { return nil }
            if let source = info.transcriptSourceRunID {
                selected = source
            } else {
                return try? info.modelID(for: .asr)
            }
        }
        return nil
    }

    /// Read a run as one transaction: never expose half of a corrupt result or
    /// hide a damaged final artifact by silently falling back to a checkpoint.
    /// Files remain untouched so this run can be recovered independently.
    public func results(_ manifest: Manifest) throws -> (Transcript?, Summary?) {
        try results(manifest, reusing: nil)
    }

    /// Checkpoint previews arrive with every periodic worker checkpoint, and
    /// parts are immutable once written. `reusing` skips re-decoding unchanged
    /// part files; merge, validation and final artifacts behave identically to
    /// the uncached read.
    public func results(_ manifest: Manifest, reusing cache: ResultCheckpointCache?) throws -> (Transcript?, Summary?) {
        do { return try validatedResults(manifest, cache: cache) }
        catch {
            throw ScribeError.message("Не удалось проверить сохранённый результат. Файлы сохранены для восстановления; можно повторить обработку записи.")
        }
    }

    private func validatedResults(_ manifest: Manifest, cache: ResultCheckpointCache? = nil) throws -> (Transcript?, Summary?) {
        guard manifest.schemaVersion == 1, UUID(uuidString: manifest.id) != nil,
              (0...Manifest.maximumDurationMs).contains(manifest.durationMs) else { throw invalidResult() }
        guard let selected = manifest.activeRunId ?? manifest.pendingRunId else { return (nil, nil) }
        // Check before constructing a path from the persisted identifier.
        guard UUID(uuidString: selected) != nil else { throw invalidResult() }
        let path = run(manifest.id, selected)
        let info = try Disk.read(RunInfo.self, at: path.appendingPathComponent("run.json"))
        try validateResultRun(info, id: selected)
        let live = info.liveCapture == true && info.sourceHash == "capture:" + selected
        if live {
            guard manifest.activeRunId == nil, manifest.pendingRunId == selected,
                  manifest.isCaptureRecording else { throw invalidResult() }
            let capture = try Disk.read(RunInfo.self, at: path.appendingPathComponent("capture-run.json"))
            try validateResultRun(capture, id: selected)
            guard capture.liveCapture == true, capture.sourceHash == info.sourceHash,
                  capture.fingerprint == info.fingerprint, capture.modelIDs == info.modelIDs, capture.auxiliaryModelIDs == info.auxiliaryModelIDs else { throw invalidResult() }
        } else {
            guard manifest.sourceComplete, manifest.durationMs > 0,
                  !manifest.sha256.isEmpty, info.sourceHash == manifest.sha256 else { throw invalidResult() }
        }

        if manifest.activeRunId != nil, !exists(path, "transcript.json") { throw invalidResult() }
        let transcript: Transcript?
        if exists(path, "transcript.json") || exists(path, "asr-transcript.json") {
            // Live output belongs to its capture timeline until explicit binding.
            guard !live else { throw invalidResult() }
            let name = exists(path, "transcript.json") ? "transcript.json" : "asr-transcript.json"
            let saved = try Disk.read(Transcript.self, at: path.appendingPathComponent(name))
            guard saved.fingerprint == info.fingerprint else { throw invalidResult() }
            try saved.validate(durationMs: manifest.durationMs)
            transcript = saved
        } else if live {
            transcript = try livePreview(path: path, info: info, cache: cache)
        } else {
            let partMs = ASRCheckpointLayout.offlinePartMs
            let urls = try checkpointURLs(path.appendingPathComponent("asr"))
            let parts = try urls.map { url -> ASRPart in
                let part: ASRPart
                if let cache, let cached = cache.asrPart(at: url) {
                    part = cached
                } else {
                    // Pre-read stamp: a file replaced during decoding misses on
                    // the next call and is read again.
                    let stamp = ResultCheckpointCache.stamp(url)
                    part = try Disk.read(ASRPart.self, at: url)
                    cache?.store(part, at: url, stamp: stamp)
                }
                // Bound the index and duration before either multiplication/addition.
                guard part.schemaVersion == 1, part.fingerprint == info.fingerprint,
                      part.index >= 0, part.index <= (manifest.durationMs - 1) / partMs else { throw invalidResult() }
                let start = part.index * partMs, end = min(manifest.durationMs, start + partMs)
                guard part.startMs == start, part.endMs == end else { throw invalidResult() }
                try Transcript(fingerprint: info.fingerprint, diarized: false, segments: part.segments).validate(durationMs: manifest.durationMs)
                return part
            }
            cache?.retain(Set(urls))
            guard parts.map(\.index).sorted() == Array(0..<parts.count) else { throw invalidResult() }
            let merged = Analysis.mergeParts(parts, fingerprint: info.fingerprint)
            try merged.validate(durationMs: manifest.durationMs)
            transcript = parts.isEmpty ? nil : merged
        }
        var summary: Summary?
        if exists(path, "summary.json") {
            guard !live, let transcript else { throw invalidResult() }
            let saved = try Disk.read(Summary.self, at: path.appendingPathComponent("summary.json"))
            try saved.validate(against: transcript, allowingUnlinkedFindings: allowsManualFindings(info, path: path, manifest: manifest))
            summary = saved
        }
        return (transcript, summary)
    }

    func validateResultRun(_ info: RunInfo, id: String) throws {
        guard info.schemaVersion == 1, info.id == id, !info.pipelineVersion.isEmpty,
              !info.profileHash.isEmpty, !info.sourceHash.isEmpty,
              info.summaryLanguage == nil || ["ru", "en"].contains(info.summaryLanguage!),
              info.transcriptSourceRunID == nil || UUID(uuidString: info.transcriptSourceRunID!) != nil else { throw invalidResult() }
    }

    private func livePreview(path: URL, info: RunInfo, cache: ResultCheckpointCache? = nil) throws -> Transcript? {
        let urls = try checkpointURLs(path.appendingPathComponent("live"))
        let saved = try urls.map { url -> LiveASRPart in
            let part: LiveASRPart
            if let cache, let cached = cache.livePart(at: url) {
                part = cached
            } else {
                let stamp = ResultCheckpointCache.stamp(url)
                part = try Disk.read(LiveASRPart.self, at: url)
                cache?.store(part, at: url, stamp: stamp)
            }
            guard (0..<360).contains(part.part.index), part.part.startMs == part.part.index * 30_000,
                  !part.fragments.isEmpty, part.fragments.count <= 5,
                  part.fragments.allSatisfy({ f in
                      (0...1080).contains(f.index) && f.frames > 0 && f.sampleRate.isFinite
                      && (8000...384000).contains(f.sampleRate) && f.frames <= Int64(f.sampleRate * 10)
                      && f.sha256.count == 64
                  }) else { throw invalidResult() }
            try part.validate(info: info, index: part.part.index, startMs: part.part.startMs,
                              availableMs: part.readEndMs, fragments: part.fragments)
            return part
        }
        cache?.retain(Set(urls))
        guard saved.map({ $0.part.index }).sorted() == Array(0..<saved.count) else { throw invalidResult() }
        guard let duration = saved.map(\.readEndMs).max() else { return nil }
        let transcript = Analysis.mergeParts(saved.map(\.part), fingerprint: info.fingerprint)
        try transcript.validate(durationMs: duration)
        return transcript
    }

    private func allowsManualFindings(_ info: RunInfo, path: URL, manifest: Manifest) -> Bool {
        if let manual = info.manualEdits { return manual }
        // Legacy manual revisions copied run metadata and only wrote the final
        // transcript/summary. Generated runs retained ASR or summary checkpoints.
        // Never infer manual provenance from transcriptSourceRunID alone.
        guard let sourceID = info.transcriptSourceRunID, sourceID != info.id,
              !["asr-transcript.json", "diarization.json", "summary-parts", "llm-audit.json", "metrics-summary.json"].contains(where: { exists(path, $0) }),
              let source = try? Disk.read(RunInfo.self, at: run(manifest.id, sourceID).appendingPathComponent("run.json")),
              source.schemaVersion == 1, source.id == sourceID,
              source.sourceHash == manifest.sha256, source.fingerprint == info.fingerprint else { return false }
        return true
    }

    private func exists(_ path: URL, _ name: String) -> Bool {
        FileManager.default.fileExists(atPath: path.appendingPathComponent(name).path)
    }

    private func checkpointURLs(_ path: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
    }

    private func invalidResult() -> ScribeError { .message("Нарушена целостность результата") }
}
