import Foundation

/// A private draft until the user explicitly saves it. Segment metadata and
/// evidence links remain structured rather than being parsed from exported text.
public struct ResultEditDraft: Identifiable, Sendable {
    public var id: String { recordingID + runID }
    public let recordingID: String
    public let runID: String
    public var transcript: Transcript
    public var summary: Summary?

    public init(recordingID: String, runID: String, transcript: Transcript, summary: Summary?) {
        self.recordingID = recordingID; self.runID = runID
        self.transcript = transcript; self.summary = summary
    }

    public func isSegmentUsedAsEvidence(_ id: String) -> Bool {
        guard let summary else { return false }
        return (summary.overview + summary.decisions + summary.tasks + summary.openQuestions)
            .contains { $0.evidenceSegmentIds.contains(id) }
    }

    /// Referenced turns require explicit confirmation. All changes stay in this draft.
    @discardableResult
    public mutating func deleteSegment(_ id: String, removingEvidence: Bool = false) -> Bool {
        guard transcript.segments.contains(where: { $0.id == id }),
              removingEvidence || !isSegmentUsedAsEvidence(id) else { return false }
        transcript.segments.removeAll { $0.id == id }
        func unlink(_ findings: inout [Finding]) {
            for index in findings.indices where findings[index].evidenceSegmentIds.contains(id) {
                findings[index].evidenceSegmentIds.removeAll { $0 == id }
                // With remaining evidence, optional claims must still be grounded in it.
                // Without evidence, keep the manually edited item's fields intact.
                if !findings[index].evidenceSegmentIds.isEmpty {
                    let single = Summary(language: transcript.primaryLanguage, tasks: [findings[index]])
                    findings[index] = single.groundingOptionalFields(against: transcript).0.tasks[0]
                }
            }
        }
        if var updated = summary {
            unlink(&updated.overview); unlink(&updated.decisions)
            unlink(&updated.tasks); unlink(&updated.openQuestions)
            summary = updated
        }
        return true
    }
}

extension RecordingRepository {
    /// Publish a complete revision only after every artifact passes validation.
    /// The previous run and all worker checkpoints remain untouched.
    public func saveResultEdits(_ draft: ResultEditDraft) throws -> Manifest {
        var manifest = try load(draft.recordingID)
        guard manifest.schemaVersion == 1, manifest.activeRunId == draft.runID,
              manifest.pendingRunId == nil, !manifest.state.processing,
              ![JobState.recording, .queued].contains(manifest.state),
              UUID(uuidString: draft.runID) != nil else {
            throw ScribeError.message("Результат изменился или ещё обрабатывается. Откройте редактор заново.")
        }
        let source = run(manifest.id, draft.runID)
        var info = try Disk.read(RunInfo.self, at: source.appendingPathComponent("run.json"))
        guard info.schemaVersion == 1, info.id == draft.runID, info.sourceHash == manifest.sha256 else {
            throw ScribeError.message("Не удалось проверить исходную версию результата")
        }
        guard let original = try results(manifest).0 else {
            throw ScribeError.message("Не удалось прочитать исходную расшифровку")
        }
        try original.validate(durationMs: manifest.durationMs)
        guard original.fingerprint == info.fingerprint,
              draft.transcript.schemaVersion == original.schemaVersion,
              draft.transcript.fingerprint == original.fingerprint,
              draft.transcript.diarized == original.diarized else {
            throw ScribeError.message("Структура расшифровки изменилась. Откройте редактор заново.")
        }
        var transcript = original
        transcript.segments = []
        var sourceIndex = original.segments.startIndex
        for edited in draft.transcript.segments {
            // The draft must be an ordered subset of the original, with unchanged metadata.
            guard let index = original.segments[sourceIndex...].firstIndex(where: { $0.id == edited.id }) else {
                throw ScribeError.message("Редактор может удалять реплики, но не добавлять и не переставлять их")
            }
            sourceIndex = original.segments.index(after: index)
            var expected = original.segments[index]
            expected.text = edited.text
            guard expected == edited else {
                throw ScribeError.message("Редактор должен сохранять таймкоды и участников оставшихся реплик")
            }
            let text = edited.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw ScribeError.message("Текст реплики не может быть пустым") }
            var segment = edited
            segment.text = text
            if text != original.segments[index].text {
                // ASR word timings describe the old wording and must not be reused.
                segment.words = []
            }
            transcript.segments.append(segment)
        }
        try transcript.validate(durationMs: manifest.durationMs)
        try draft.summary?.validate(against: transcript, allowingUnlinkedFindings: true)

        info.id = UUID().uuidString; info.createdAt = Date(); info.manualEdits = true
        info.transcriptSourceRunID = draft.runID
        let destination = run(manifest.id, info.id)
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at: destination) } }
        try Disk.write(info, to: destination.appendingPathComponent("run.json"))
        try Disk.write(transcript, to: destination.appendingPathComponent("transcript.json"))
        if let summary = draft.summary { try Disk.write(summary, to: destination.appendingPathComponent("summary.json")) }
        // Re-read before publishing so a stale editor cannot restore an old run,
        // title, warning, or processing state.
        let current = try load(manifest.id)
        guard current.activeRunId == manifest.activeRunId, current.pendingRunId == nil,
              current.state == manifest.state, current.sha256 == manifest.sha256 else {
            throw ScribeError.message("Запись изменилась во время сохранения. Откройте редактор заново.")
        }
        manifest = current; manifest.activeRunId = info.id
        try save(manifest)
        published = true
        return manifest
    }
}
