import XCTest
@testable import LocalScribeCore

final class ResultReadingTests: XCTestCase {
    private func fixture(_ check: (RecordingRepository, Manifest, RunInfo, Transcript, Summary) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root)
        var manifest = Manifest(sourceType: "import", title: "Archive", filename: "original.wav")
        manifest.sha256 = String(repeating: "a", count: 64); manifest.durationMs = 1000
        manifest.sourceComplete = true; manifest.state = .completed
        let info = RunInfo(sourceHash: manifest.sha256, profileHash: "legacy-profile")
        let transcript = Transcript(fingerprint: info.fingerprint, diarized: true,
                                    segments: [Segment(id: "s", startMs: 0, endMs: 1000, text: "Фраза", language: "ru")])
        let summary = Summary(language: "ru", overview: [Finding(id: "f", text: "Обзор", evidenceSegmentIds: ["s"])])
        let path = repo.run(manifest.id, info.id)
        try Disk.write(info, to: path.appendingPathComponent("run.json"))
        try Disk.write(transcript, to: path.appendingPathComponent("transcript.json"))
        try Disk.write(summary, to: path.appendingPathComponent("summary.json"))
        manifest.activeRunId = info.id; try repo.save(manifest)
        try check(repo, manifest, info, transcript, summary)
    }

    func testCorruptTranscriptIsRejectedWithoutFallbackOrFileChanges() throws {
        try fixture { repo, manifest, info, transcript, _ in
            let path = repo.run(manifest.id, info.id), url = path.appendingPathComponent("transcript.json")
            try Disk.write(transcript, to: path.appendingPathComponent("asr-transcript.json"))
            var variants: [Transcript] = []
            var bad = transcript; bad.fingerprint = "foreign"; variants.append(bad)
            bad = transcript; bad.schemaVersion = 2; variants.append(bad)
            bad = transcript; bad.segments[0].startMs = -100; bad.segments[0].endMs = 2000; variants.append(bad)
            bad = transcript; bad.segments[0].endMs = Int.max; variants.append(bad)
            bad = transcript; bad.segments.append(bad.segments[0]); variants.append(bad)
            bad = transcript; bad.segments[0].words = [Word(text: "bad", startMs: -1, endMs: 1)]; variants.append(bad)
            for bad in variants {
                try Disk.write(bad, to: url)
                let before = try Data(contentsOf: url)
                XCTAssertThrowsError(try repo.results(manifest)) { error in
                    XCTAssertTrue(error.localizedDescription.contains("Файлы сохранены для восстановления"))
                }
                XCTAssertEqual(try Data(contentsOf: url), before)
                XCTAssertEqual(try repo.load(manifest.id).activeRunId, info.id)
                XCTAssertEqual(repo.list().count, 1)
            }
            try Data("broken JSON".utf8).write(to: url)
            XCTAssertThrowsError(try repo.results(manifest))
        }
    }

    func testRunAndManifestIdentityVersionSourceAndDurationAreChecked() throws {
        try fixture { repo, manifest, info, _, _ in
            let url = repo.run(manifest.id, info.id).appendingPathComponent("run.json")
            var variants: [RunInfo] = []
            var bad = info; bad.id = UUID().uuidString; variants.append(bad)
            bad = info; bad.schemaVersion = 2; variants.append(bad)
            bad = info; bad.sourceHash = "foreign"; variants.append(bad)
            bad = info; bad.pipelineVersion = ""; variants.append(bad)
            bad = info; bad.transcriptSourceRunID = "../../bad"; variants.append(bad)
            for bad in variants {
                try Disk.write(bad, to: url)
                XCTAssertThrowsError(try repo.results(manifest))
            }
            try Disk.write(info, to: url)
            for duration in [-1, 10_800_001, Int.max] {
                var bad = manifest; bad.durationMs = duration
                XCTAssertThrowsError(try repo.results(bad))
            }
            for id in ["broken", "../" + info.id] {
                var bad = manifest; bad.activeRunId = id
                XCTAssertThrowsError(try repo.results(bad))
            }
            var badManifest = manifest; badManifest.schemaVersion = 2
            XCTAssertThrowsError(try repo.results(badManifest))
            badManifest = manifest; badManifest.sourceComplete = false
            XCTAssertThrowsError(try repo.results(badManifest))
        }
    }

    func testSummaryVersionLanguageReferencesAndGeneratedEvidenceAreChecked() throws {
        try fixture { repo, manifest, info, _, summary in
            let url = repo.run(manifest.id, info.id).appendingPathComponent("summary.json")
            var variants: [Summary] = []
            var bad = summary; bad.schemaVersion = 2; variants.append(bad)
            bad = summary; bad.language = "xx"; variants.append(bad)
            bad = summary; bad.overview[0].evidenceSegmentIds = ["missing"]; variants.append(bad)
            bad = summary; bad.overview[0].evidenceSegmentIds = []; variants.append(bad)
            bad = summary; bad.overview[0].ownerSpeakerId = "missing"; variants.append(bad)
            for bad in variants {
                try Disk.write(bad, to: url)
                XCTAssertThrowsError(try repo.results(manifest))
            }
            try Data("broken JSON".utf8).write(to: url)
            XCTAssertThrowsError(try repo.results(manifest))
        }
    }

    func testASRCheckpointBoundsBeforeArithmeticAndValidPreview() throws {
        try fixture { repo, original, info, transcript, _ in
            var manifest = original; manifest.activeRunId = nil; manifest.pendingRunId = info.id
            let path = repo.run(manifest.id, info.id)
            try FileManager.default.removeItem(at: path.appendingPathComponent("transcript.json"))
            try FileManager.default.removeItem(at: path.appendingPathComponent("summary.json"))
            let url = path.appendingPathComponent("asr/part-0.json")
            let part = ASRPart(fingerprint: info.fingerprint, index: 0, startMs: 0, endMs: 1000, segments: transcript.segments)
            try Disk.write(part, to: url)
            XCTAssertThrowsError(try repo.results(original)) // a published run cannot become a checkpoint preview
            XCTAssertEqual(try repo.results(manifest).0?.segments, transcript.segments.map { segment in
                var segment = segment; segment.id = "seg-000000"; return segment
            })
            for index in [-1, 1, Int.max] {
                var bad = part; bad.index = index; try Disk.write(bad, to: url)
                XCTAssertThrowsError(try repo.results(manifest))
            }
            var bad = part; bad.schemaVersion = 2; try Disk.write(bad, to: url)
            XCTAssertThrowsError(try repo.results(manifest))
            bad = part; bad.fingerprint = "foreign"; try Disk.write(bad, to: url)
            XCTAssertThrowsError(try repo.results(manifest))
            bad = part; bad.segments[0].startMs = -1; try Disk.write(bad, to: url)
            XCTAssertThrowsError(try repo.results(manifest))
        }
    }

    func testLegacyRunAndManualRevisionRemainReadableButGeneratedRevisionRequiresEvidence() throws {
        try fixture { repo, manifest, original, transcript, summary in
            var legacy = original; legacy.manualEdits = nil; legacy.modelIDs = nil
            legacy.pipelineVersion = "1.0.0-legacy"
            var legacyTranscript = transcript; legacyTranscript.fingerprint = legacy.fingerprint
            let path = repo.run(manifest.id, legacy.id)
            try Disk.write(legacy, to: path.appendingPathComponent("run.json"))
            try Disk.write(legacyTranscript, to: path.appendingPathComponent("transcript.json"))
            XCTAssertEqual(try repo.results(manifest).0, legacyTranscript)
            var draft = ResultEditDraft(recordingID: manifest.id, runID: legacy.id, transcript: legacyTranscript, summary: summary)
            draft.summary?.overview[0].evidenceSegmentIds = []
            let edited = try repo.saveResultEdits(draft)
            XCTAssertEqual(try repo.results(edited).1, draft.summary)
            let editURL = repo.run(edited.id, edited.activeRunId!).appendingPathComponent("run.json")
            var edit = try Disk.read(RunInfo.self, at: editURL)
            XCTAssertEqual(edit.manualEdits, true)
            edit.manualEdits = nil; try Disk.write(edit, to: editURL)
            XCTAssertEqual(try repo.results(edited).1, draft.summary) // pre-marker manual revision
            edit.manualEdits = false; try Disk.write(edit, to: editURL)
            XCTAssertThrowsError(try repo.results(edited)) // summary-only runs also have a source run
            edit.manualEdits = nil; try Disk.write(edit, to: editURL)
            try Disk.write(["generated": true], to: editURL.deletingLastPathComponent().appendingPathComponent("llm-audit.json"))
            XCTAssertThrowsError(try repo.results(edited))
        }
    }

    func testLivePreviewUsesCaptureTimelineAndRejectsMalformedCheckpoints() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root)
        var manifest = Manifest(sourceType: "microphone", title: "Live", filename: "original.caf")
        manifest.state = .recording // duration/hash are not known yet
        let info = try repo.beginRun(&manifest, catalog: ModelCatalog(models: []), liveCapture: true)
        let part = ASRPart(fingerprint: info.fingerprint, index: 0, startMs: 0, endMs: 1000,
                          segments: [Segment(id: "live", startMs: 0, endMs: 1000, text: "Фраза", language: "ru")])
        let saved = LiveASRPart(part: part, readStartMs: 0, readEndMs: 1000,
                               fragments: [CaptureFragment(index: 0, frames: 16000, sampleRate: 16000, sha256: String(repeating: "a", count: 64))])
        let path = repo.run(manifest.id, info.id), url = path.appendingPathComponent("live/part-0.json")
        XCTAssertNil(try repo.results(manifest).0)
        try Disk.write(saved, to: url)
        XCTAssertEqual(try repo.results(manifest).0?.segments.first?.text, "Фраза")
        XCTAssertNil(try repo.results(manifest).1)
        var variants: [LiveASRPart] = []
        var bad = saved; bad.part.index = Int.max; variants.append(bad)
        bad = saved; bad.readEndMs = Int.max; variants.append(bad)
        bad = saved; bad.part.fingerprint = "foreign"; variants.append(bad)
        bad = saved; bad.part.segments[0].startMs = -1; variants.append(bad)
        bad = saved; bad.fragments[0].frames = Int64.max; variants.append(bad)
        for bad in variants {
            try Disk.write(bad, to: url)
            XCTAssertThrowsError(try repo.results(manifest))
        }
        try Disk.write(saved, to: url)
        // After capture stops, previews remain available until the PCM is bound.
        manifest.sourceComplete = true; manifest.sha256 = "final"; manifest.durationMs = 1000; manifest.state = .interrupted
        XCTAssertNotNil(try repo.results(manifest).0)
        // A final artifact cannot bypass binding or be used with the capture fingerprint.
        try Disk.write(Transcript(fingerprint: info.fingerprint, diarized: false, segments: part.segments),
                       to: path.appendingPathComponent("asr-transcript.json"))
        XCTAssertThrowsError(try repo.results(manifest))
    }

    func testActiveResultIsIndependentOfCorruptPendingRunAndOtherArchiveItems() throws {
        try fixture { repo, manifest, _, transcript, _ in
            var current = manifest; current.pendingRunId = "broken"
            XCTAssertEqual(try repo.results(current).0, transcript)
            var damaged = manifest; damaged.id = UUID().uuidString; damaged.activeRunId = "broken"
            try repo.save(damaged)
            XCTAssertThrowsError(try repo.results(damaged))
            XCTAssertEqual(try repo.results(current).0, transcript)
            XCTAssertEqual(repo.list().count, 2)
        }
    }
}
