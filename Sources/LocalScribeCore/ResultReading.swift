import Foundation

extension RecordingRepository {
    /// Read a run as one transaction: never expose half of a corrupt result or
    /// hide a damaged final artifact by silently falling back to a checkpoint.
    /// Files remain untouched so this run can be recovered independently.
    public func results(_ manifest: Manifest) throws -> (Transcript?, Summary?) {
        do { return try validatedResults(manifest) }
        catch {
            throw ScribeError.message("Не удалось проверить сохранённый результат. Файлы сохранены для восстановления; можно повторить обработку записи.")
        }
    }

    private func validatedResults(_ manifest: Manifest) throws -> (Transcript?, Summary?) {
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
                  manifest.sourceType == "microphone" else { throw invalidResult() }
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
            transcript = try livePreview(path: path, info: info)
        } else {
            let partMs = ASRCheckpointLayout.offlinePartMs
            let parts = try checkpointURLs(path.appendingPathComponent("asr")).map { url in
                let part = try Disk.read(ASRPart.self, at: url)
                // Bound the index and duration before either multiplication/addition.
                guard part.schemaVersion == 1, part.fingerprint == info.fingerprint,
                      part.index >= 0, part.index <= (manifest.durationMs - 1) / partMs else { throw invalidResult() }
                let start = part.index * partMs, end = min(manifest.durationMs, start + partMs)
                guard part.startMs == start, part.endMs == end else { throw invalidResult() }
                try Transcript(fingerprint: info.fingerprint, diarized: false, segments: part.segments).validate(durationMs: manifest.durationMs)
                return part
            }
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

    private func livePreview(path: URL, info: RunInfo) throws -> Transcript? {
        let saved = try checkpointURLs(path.appendingPathComponent("live")).map { url in
            let saved = try Disk.read(LiveASRPart.self, at: url)
            guard (0..<360).contains(saved.part.index), saved.part.startMs == saved.part.index * 30_000,
                  !saved.fragments.isEmpty, saved.fragments.count <= 5,
                  saved.fragments.allSatisfy({ f in
                      (0...1080).contains(f.index) && f.frames > 0 && f.sampleRate.isFinite
                      && (8000...384000).contains(f.sampleRate) && f.frames <= Int64(f.sampleRate * 10)
                      && f.sha256.count == 64
                  }) else { throw invalidResult() }
            try saved.validate(info: info, index: saved.part.index, startMs: saved.part.startMs,
                               availableMs: saved.readEndMs, fragments: saved.fragments)
            return saved
        }
        guard Set(saved.map { $0.part.index }).count == saved.count else { throw invalidResult() }
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
