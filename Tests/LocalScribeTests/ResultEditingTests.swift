import XCTest
@testable import LocalScribeCore

final class ResultEditingTests: XCTestCase {
    private func withResult(_ check: (RecordingRepository, Manifest, ResultEditDraft, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root)
        var manifest = Manifest(sourceType: "import", title: "Встреча", filename: "meeting.wav")
        let original = repo.folder(manifest.id).appendingPathComponent(manifest.originalRelativePath)
        try Disk.directory(original.deletingLastPathComponent())
        try Data("original audio".utf8).write(to: original)
        manifest.sha256 = try Disk.hash(original); manifest.durationMs = 5000
        manifest.sourceComplete = true; manifest.state = .completedWithWarnings
        manifest.warnings = ["Проверьте имена"]
        var info = RunInfo(sourceHash: manifest.sha256, profileHash: "profile", summaryLanguage: "ru")
        info.modelIDs = ["asr": "whisper", "summary": "qwen"]
        let transcript = Transcript(fingerprint: info.fingerprint, diarized: true, segments: [
            Segment(id: "s1", startMs: 0, endMs: 2000, speakerId: "speaker-1", text: "Анна сделает отчёт завтра", language: "ru",
                    words: [Word(text: "Анна", startMs: 0, endMs: 400)]),
            Segment(id: "s2", startMs: 2500, endMs: 5000, text: "Проверим план", language: "ru", uncertain: true,
                    words: [Word(text: "Проверим", startMs: 2500, endMs: 3000)])
        ])
        let summary = Summary(language: "ru", tasks: [Finding(id: "task", text: "Подготовить отчёт", evidenceSegmentIds: ["s1"],
                              ownerSpeakerId: "speaker-1", ownerName: "Анна", dueText: "завтра")])
        let path = repo.run(manifest.id, info.id)
        try Disk.write(info, to: path.appendingPathComponent("run.json"))
        try Disk.write(transcript, to: path.appendingPathComponent("transcript.json"))
        try Disk.write(summary, to: path.appendingPathComponent("summary.json"))
        try Disk.write(["checkpoint": "untouched"], to: path.appendingPathComponent("asr/part.json"))
        manifest.activeRunId = info.id; try repo.save(manifest)
        try check(repo, manifest, ResultEditDraft(recordingID: manifest.id, runID: info.id, transcript: transcript, summary: summary), original)
    }

    func testSavePublishesRevisionPreservingOriginalRunAudioAndExternalFiles() throws {
        try withResult { repo, manifest, initial, original in
            let old = repo.run(manifest.id, initial.runID)
            let files = ["run.json", "transcript.json", "summary.json", "asr/part.json"]
            let before = try files.map { try Data(contentsOf: old.appendingPathComponent($0)) }
            let external = repo.root.appendingPathComponent("external.wav")
            let exported = repo.root.appendingPathComponent("export.md")
            try Data("external".utf8).write(to: external); try Data("export".utf8).write(to: exported)
            var draft = initial
            draft.transcript.segments[0].text = "  Анна подготовит отчёт завтра 😀\n"
            draft.summary?.tasks[0].text = "Подготовить подробный отчёт 😀"
            let saved = try repo.saveResultEdits(draft)
            XCTAssertNotEqual(saved.activeRunId, manifest.activeRunId)
            XCTAssertNil(saved.pendingRunId)
            XCTAssertEqual(saved.warnings, manifest.warnings); XCTAssertEqual(saved.state, manifest.state)
            XCTAssertEqual(try Disk.hash(original), manifest.sha256)
            XCTAssertEqual(try Data(contentsOf: external), Data("external".utf8))
            XCTAssertEqual(try Data(contentsOf: exported), Data("export".utf8))
            for (file, bytes) in zip(files, before) { XCTAssertEqual(try Data(contentsOf: old.appendingPathComponent(file)), bytes) }
            let reopened = try RecordingRepository(root: repo.root)
            let result = try reopened.results(try reopened.load(manifest.id))
            XCTAssertEqual(result.0?.segments[0].text, "Анна подготовит отчёт завтра 😀")
            XCTAssertEqual(result.0?.segments[0].words, [])
            XCTAssertEqual(result.0?.segments[1], initial.transcript.segments[1])
            XCTAssertEqual(result.0?.segments[0].id, "s1")
            XCTAssertEqual(result.0?.segments[0].startMs, 0); XCTAssertEqual(result.0?.segments[0].endMs, 2000)
            XCTAssertEqual(result.1, draft.summary)
            let info = try Disk.read(RunInfo.self, at: repo.run(saved.id, saved.activeRunId!).appendingPathComponent("run.json"))
            XCTAssertEqual(info.transcriptSourceRunID, initial.runID)
            XCTAssertEqual(info.modelIDs, ["asr": "whisper", "summary": "qwen"])
            XCTAssertEqual(info.fingerprint, initial.transcript.fingerprint)
            for markdown in [false, true] {
                let export = ExportService.renderResult(manifest: saved, transcript: result.0, summary: result.1, part: .all, markdown: markdown)
                XCTAssertTrue(export.text.contains("Анна подготовит отчёт завтра 😀"))
                XCTAssertTrue(export.text.contains("Подготовить подробный отчёт 😀"))
                XCTAssertEqual(export.timestamps.map(\.segmentID), ["s1", "s1", "s2"])
            }
        }
    }

    func testSummaryOnlyEditPreservesWordsAndLinksAndCanAddOrDeleteItems() throws {
        try withResult { repo, _, initial, _ in
            var draft = initial
            draft.summary?.tasks = []
            draft.summary?.overview = [Finding(id: "new", text: "Проверка плана", evidenceSegmentIds: ["s2"], uncertain: true)]
            let saved = try repo.saveResultEdits(draft)
            XCTAssertEqual(try repo.results(saved).0, initial.transcript)
            XCTAssertEqual(try repo.results(saved).1, draft.summary)
        }
    }

    func testTranscriptOnlyAndMissingSummaryAreSupported() throws {
        try withResult { repo, manifest, initial, _ in
            try FileManager.default.removeItem(at: repo.run(manifest.id, initial.runID).appendingPathComponent("summary.json"))
            var draft = initial; draft.summary = nil; draft.transcript.segments[1].text = "Исправлено"
            let saved = try repo.saveResultEdits(draft)
            XCTAssertEqual(try repo.results(saved).0?.segments[1].text, "Исправлено")
            XCTAssertNil(try repo.results(saved).1)
        }
    }

    func testRecreatingSummaryUsesEditedTranscriptWithoutChangingRevision() throws {
        try withResult { repo, _, initial, _ in
            var draft = initial; draft.transcript.segments[0].text = "Анна проверит отчёт завтра"
            var saved = try repo.saveResultEdits(draft)
            let active = try XCTUnwrap(saved.activeRunId)
            let info = try repo.beginRun(&saved, catalog: ModelCatalog(models: []), summaryOnly: true)
            let copied = try Disk.read(Transcript.self, at: repo.run(saved.id, info.id).appendingPathComponent("transcript.json"))
            XCTAssertEqual(copied.segments[0].text, draft.transcript.segments[0].text)
            XCTAssertEqual(copied.fingerprint, info.fingerprint)
            XCTAssertEqual(saved.activeRunId, active)
            XCTAssertEqual(info.transcriptSourceRunID, active)
        }
    }

    func testDiscardingDraftDoesNotWriteAnything() throws {
        try withResult { repo, manifest, initial, _ in
            var draft = initial; draft.transcript.segments[0].text = "Черновик"; draft.summary?.tasks = []
            XCTAssertNotEqual(draft.transcript, initial.transcript)
            XCTAssertEqual(try repo.results(manifest).0, initial.transcript)
            XCTAssertEqual(try repo.results(manifest).1, initial.summary)
            XCTAssertEqual(try repo.load(manifest.id).activeRunId, initial.runID)
        }
    }

    func testInvalidEditsDoNotPublishOrChangeOldResult() throws {
        try withResult { repo, manifest, initial, _ in
            var invalid: [ResultEditDraft] = []
            var draft = initial; draft.transcript.segments[0].text = " \n\t"; invalid.append(draft)
            draft = initial; draft.transcript.segments[0].startMs = 1; invalid.append(draft)
            draft = initial; draft.transcript.segments[0].speakerId = nil; invalid.append(draft)
            draft = initial; draft.transcript.segments.reverse(); invalid.append(draft)
            draft = initial; draft.transcript.segments.append(initial.transcript.segments[0]); invalid.append(draft)
            draft = initial; draft.transcript.segments[1].id = "new"; invalid.append(draft)
            draft = initial; draft.transcript.segments[1].words = []; invalid.append(draft)
            draft = initial; draft.transcript.segments.removeFirst(); invalid.append(draft)
            draft = initial; draft.transcript.fingerprint = "wrong"; invalid.append(draft)
            draft = initial; draft.summary?.tasks[0].text = ""; invalid.append(draft)
            draft = initial; draft.summary?.tasks[0].text = String(repeating: "a", count: 3001); invalid.append(draft)
            draft = initial; draft.summary?.tasks[0].evidenceSegmentIds = ["missing"]; invalid.append(draft)
            draft = initial; draft.summary?.tasks[0].ownerName = "Борис"; invalid.append(draft)
            draft = initial; draft.summary?.tasks[0].dueText = "сегодня"; invalid.append(draft)
            draft = initial; draft.transcript.segments[0].text = "Отчёт"; invalid.append(draft)
            draft = initial; draft.summary?.overview = [Finding(id: "new", text: "План", evidenceSegmentIds: ["s2"])]; invalid.append(draft)
            for edit in invalid {
                XCTAssertThrowsError(try repo.saveResultEdits(edit))
                XCTAssertEqual(try repo.load(manifest.id).activeRunId, initial.runID)
                XCTAssertEqual(try repo.results(manifest).0, initial.transcript)
                XCTAssertEqual(try repo.results(manifest).1, initial.summary)
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: repo.folder(manifest.id).appendingPathComponent("runs").path), [initial.runID])
        }
    }

    func testUnreferencedDeletionNeedsNoConfirmationAndPreservesRemainingMetadata() throws {
        try withResult { repo, manifest, initial, _ in
            var draft = initial
            XCTAssertFalse(draft.isSegmentUsedAsEvidence("s2"))
            XCTAssertTrue(draft.deleteSegment("s2"))
            XCTAssertEqual(draft.transcript.segments, [initial.transcript.segments[0]])
            XCTAssertEqual(draft.summary, initial.summary)
            XCTAssertFalse(draft.deleteSegment("missing"))
            let saved = try repo.saveResultEdits(draft)
            XCTAssertEqual(try repo.results(saved).0, draft.transcript)
            XCTAssertEqual(try repo.results(saved).1, initial.summary)
            XCTAssertEqual(try repo.results(manifest).0, initial.transcript)
        }
    }

    func testReferencedDeletionRequiresConfirmationAndCanBeCancelledWithoutChanges() throws {
        try withResult { repo, manifest, initial, _ in
            var draft = initial
            XCTAssertTrue(draft.isSegmentUsedAsEvidence("s1"))
            XCTAssertFalse(draft.deleteSegment("s1"))
            XCTAssertEqual(draft.transcript, initial.transcript)
            XCTAssertEqual(draft.summary, initial.summary)
            XCTAssertEqual(try repo.results(manifest).0, initial.transcript)
        }
    }

    func testConfirmedDeletionUnlinksEverySummarySectionAndRetainsUnrelatedFindings() throws {
        try withResult { repo, manifest, initial, _ in
            var draft = initial
            let linked = Finding(id: "linked", text: "Вывод", evidenceSegmentIds: ["s1", "s2"],
                                 ownerSpeakerId: "speaker-1", ownerName: "Анна", dueText: "завтра", uncertain: true)
            let unrelated = Finding(id: "unrelated", text: "Без изменений", evidenceSegmentIds: ["s2"], uncertain: true)
            draft.summary?.overview = [linked, unrelated]
            draft.summary?.decisions = [linked]
            draft.summary?.openQuestions = [linked]
            XCTAssertTrue(draft.deleteSegment("s1", removingEvidence: true))
            let summary = try XCTUnwrap(draft.summary)
            for finding in summary.overview.prefix(1) + summary.decisions + summary.openQuestions {
                XCTAssertEqual(finding.evidenceSegmentIds, ["s2"])
                XCTAssertNil(finding.ownerSpeakerId); XCTAssertNil(finding.ownerName); XCTAssertNil(finding.dueText)
                XCTAssertTrue(finding.uncertain)
                XCTAssertEqual(finding.text, linked.text)
            }
            XCTAssertEqual(summary.overview[1], unrelated)
            var task = try XCTUnwrap(initial.summary?.tasks.first)
            task.evidenceSegmentIds = []
            XCTAssertEqual(summary.tasks, [task])
            let saved = try repo.saveResultEdits(draft)
            XCTAssertEqual(try repo.results(saved).0?.segments, [initial.transcript.segments[1]])
            XCTAssertEqual(try repo.results(saved).1, summary)
            XCTAssertEqual(try repo.results(manifest).1, initial.summary)
            for markdown in [false, true] {
                let export = ExportService.renderResult(manifest: saved, transcript: draft.transcript,
                                                        summary: summary, markdown: markdown)
                XCTAssertFalse(export.timestamps.contains { $0.segmentID == "s1" })
                XCTAssertTrue(export.text.contains(task.text))
            }
            // A second revision must accept a previously unlinked finding as well.
            var reopened = ResultEditDraft(recordingID: saved.id, runID: saved.activeRunId!,
                                           transcript: draft.transcript, summary: summary)
            reopened.summary?.tasks[0].text = "Уточнённая задача"
            XCTAssertNoThrow(try repo.saveResultEdits(reopened))
        }
    }

    func testDeletingAllSegmentsPreservesSummaryAndCanBeUsedToRegenerateIt() throws {
        try withResult { repo, _, initial, _ in
            var draft = initial
            XCTAssertTrue(draft.deleteSegment("s1", removingEvidence: true))
            XCTAssertTrue(draft.deleteSegment("s2"))
            var saved = try repo.saveResultEdits(draft)
            XCTAssertEqual(try repo.results(saved).0?.segments, [])
            XCTAssertEqual(try repo.results(saved).1?.tasks[0].evidenceSegmentIds, [])
            let info = try repo.beginRun(&saved, catalog: ModelCatalog(models: []), summaryOnly: true)
            let copy = try Disk.read(Transcript.self, at: repo.run(saved.id, info.id).appendingPathComponent("transcript.json"))
            XCTAssertEqual(copy.segments, [])
            XCTAssertEqual(copy.fingerprint, info.fingerprint)
        }
    }

    func testDeletionWithoutSummaryAndDeletionCombinedWithTextEdit() throws {
        try withResult { repo, _, initial, _ in
            var draft = initial
            draft.summary = nil
            XCTAssertTrue(draft.deleteSegment("s1"))
            draft.transcript.segments[0].text = "Исправленный план"
            let saved = try repo.saveResultEdits(draft)
            XCTAssertEqual(try repo.results(saved).0?.segments[0].id, "s2")
            XCTAssertEqual(try repo.results(saved).0?.segments[0].startMs, 2500)
            XCTAssertEqual(try repo.results(saved).0?.segments[0].words, [])
            XCTAssertNil(try repo.results(saved).1)
        }
    }

    func testEvidenceIsOptionalOnlyForManualFindingsAndInvalidFieldsStillFail() throws {
        try withResult { repo, _, initial, _ in
            var draft = initial
            draft.summary?.tasks[0].evidenceSegmentIds = []
            let summary = try XCTUnwrap(draft.summary)
            XCTAssertThrowsError(try summary.validate(against: draft.transcript))
            XCTAssertNoThrow(try summary.validate(against: draft.transcript, allowingUnlinkedFindings: true))
            XCTAssertNoThrow(try repo.saveResultEdits(draft))
            for field in [\Finding.ownerName, \Finding.dueText] {
                var invalid = summary
                invalid.tasks[0][keyPath: field] = "  "
                XCTAssertThrowsError(try invalid.validate(against: draft.transcript, allowingUnlinkedFindings: true))
            }
            var invalid = summary
            invalid.tasks[0].evidenceSegmentIds = ["missing"]
            XCTAssertThrowsError(try invalid.validate(against: draft.transcript, allowingUnlinkedFindings: true))
        }
    }

    func testStaleAndProcessingEditorsAreRejected() throws {
        try withResult { repo, manifest, initial, _ in
            for state in [JobState.queued, .recording, .transcribing, .summarizing] {
                var current = manifest; current.state = state; try repo.save(current)
                XCTAssertThrowsError(try repo.saveResultEdits(initial))
            }
            var current = manifest; current.pendingRunId = UUID().uuidString; try repo.save(current)
            XCTAssertThrowsError(try repo.saveResultEdits(initial))
            current = manifest; current.activeRunId = UUID().uuidString; try repo.save(current)
            XCTAssertThrowsError(try repo.saveResultEdits(initial))
            try repo.save(manifest)
            _ = try repo.saveResultEdits(initial)
            XCTAssertThrowsError(try repo.saveResultEdits(initial))
        }
    }

    func testInvalidRunIdentitySourceAndFingerprintAreRejected() throws {
        try withResult { repo, manifest, initial, _ in
            let infoURL = repo.run(manifest.id, initial.runID).appendingPathComponent("run.json")
            let info = try Disk.read(RunInfo.self, at: infoURL)
            var bad = info; bad.id = UUID().uuidString; try Disk.write(bad, to: infoURL)
            XCTAssertThrowsError(try repo.saveResultEdits(initial))
            bad = info; bad.sourceHash = "wrong"; try Disk.write(bad, to: infoURL)
            XCTAssertThrowsError(try repo.saveResultEdits(initial))
            bad = info; bad.schemaVersion = 2; try Disk.write(bad, to: infoURL)
            XCTAssertThrowsError(try repo.saveResultEdits(initial))
            bad = info; bad.profileHash = "wrong"; try Disk.write(bad, to: infoURL)
            XCTAssertThrowsError(try repo.saveResultEdits(initial))
            XCTAssertEqual(try repo.load(manifest.id).activeRunId, initial.runID)
        }
    }
}
