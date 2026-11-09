import XCTest
@testable import LocalScribeCore

final class ResultReadingTests: XCTestCase {
    /// Live capture requires a closed-fragment (Whisper) ASR profile in the catalog.
    private static let liveCatalog = ModelCatalog(models: [
        ModelProfile(id: "asr", repository: "fixture/whisper", revision: "fixed", license: "test", files: [], role: .asr)
    ])
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

    func testExplicitSummaryWithoutActiveRunStartsFullAnalysisWithoutTrustingPendingPreview() throws {
        try fixture { repo, original, previous, _, _ in
            var manifest = original
            manifest.activeRunId = nil; manifest.pendingRunId = previous.id
            let oldTranscript = repo.run(manifest.id, previous.id).appendingPathComponent("transcript.json")
            let bytes = try Data(contentsOf: oldTranscript)
            let fresh = try repo.beginRun(&manifest, catalog: ModelCatalog(models: []), summaryLanguage: "en", summaryOnly: true)
            XCTAssertEqual(fresh.summaryLanguage, "en")
            XCTAssertNil(fresh.transcriptSourceRunID)
            XCTAssertEqual(manifest.pendingRunId, fresh.id)
            XCTAssertFalse(FileManager.default.fileExists(atPath: repo.run(manifest.id, fresh.id).appendingPathComponent("transcript.json").path))
            XCTAssertEqual(try Data(contentsOf: oldTranscript), bytes)
        }
    }

    func testSummaryOnlyRejectsForeignTranscriptAndSourceWithoutCreatingRun() throws {
        try fixture { repo, original, info, transcript, _ in
            let path = repo.run(original.id, info.id)
            for changeSource in [false, true] {
                var saved = transcript, source = info, manifest = original
                if changeSource { source.sourceHash = "foreign" } else { saved.fingerprint = "foreign" }
                try Disk.write(source, to: path.appendingPathComponent("run.json"))
                try Disk.write(saved, to: path.appendingPathComponent("transcript.json"))
                XCTAssertThrowsError(try repo.beginRun(&manifest, catalog: ModelCatalog(models: []), summaryOnly: true))
                XCTAssertEqual(manifest.pendingRunId, original.pendingRunId)
                XCTAssertEqual(try repo.load(original.id).pendingRunId, original.pendingRunId)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: path.deletingLastPathComponent().path), [info.id])
            }
        }
    }

    func testSummaryOnlyAcceptsLegacyManualAndSummaryOnlyTranscripts() throws {
        try fixture { repo, original, info, transcript, summary in
            var legacy = info; legacy.pipelineVersion = "legacy"; legacy.modelIDs = nil
            var saved = transcript; saved.fingerprint = legacy.fingerprint
            let path = repo.run(original.id, info.id)
            try Disk.write(legacy, to: path.appendingPathComponent("run.json"))
            try Disk.write(saved, to: path.appendingPathComponent("transcript.json"))
            let draft = ResultEditDraft(recordingID: original.id, runID: legacy.id, transcript: saved, summary: summary)
            let edited = try repo.saveResultEdits(draft)
            for source in [original, edited] {
                var manifest = source
                for _ in 0..<2 {
                    let fresh = try repo.beginRun(&manifest, catalog: ModelCatalog(models: []), summaryOnly: true)
                    let copied = try Disk.read(Transcript.self, at: repo.run(manifest.id, fresh.id).appendingPathComponent("transcript.json"))
                    XCTAssertEqual(copied.segments, saved.segments)
                    XCTAssertEqual(copied.fingerprint, fresh.fingerprint)
                    manifest.activeRunId = fresh.id; try repo.save(manifest)
                }
            }
        }
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

    func testPendingASRPreviewRejectsMissingFirstMiddleAndDuplicateParts() throws {
        try fixture { repo, original, info, _, _ in
            var manifest = original
            manifest.activeRunId = nil; manifest.pendingRunId = info.id; manifest.durationMs = 900_000
            let path = repo.run(manifest.id, info.id)
            try FileManager.default.removeItem(at: path.appendingPathComponent("transcript.json"))
            try FileManager.default.removeItem(at: path.appendingPathComponent("summary.json"))
            let parts = path.appendingPathComponent("asr")
            for indices in [[1], [0, 2], [0, 1, 1], [0, 1], [0, 1, 2]] {
                try? FileManager.default.removeItem(at: parts)
                for (fileIndex, index) in indices.enumerated() {
                    let part = ASRPart(fingerprint: info.fingerprint, index: index,
                        startMs: index * 300_000, endMs: (index + 1) * 300_000, segments: [])
                    try Disk.write(part, to: parts.appendingPathComponent("part-\(fileIndex).json"))
                }
                if indices == [0, 1] || indices == [0, 1, 2] { XCTAssertNotNil(try repo.results(manifest).0) }
                else { XCTAssertThrowsError(try repo.results(manifest)) }
            }
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
            for name in ["llm-audit.json", "metrics-summary.json"] {
                let marker = editURL.deletingLastPathComponent().appendingPathComponent(name)
                try Disk.write(["generated": true], to: marker)
                XCTAssertThrowsError(try repo.results(edited))
                try FileManager.default.removeItem(at: marker)
            }
        }
    }

    func testLivePreviewUsesCaptureTimelineAndRejectsMalformedCheckpoints() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root)
        var manifest = Manifest(sourceType: "microphone", title: "Live", filename: "original.caf")
        manifest.state = .recording // duration/hash are not known yet
        let info = try repo.beginRun(&manifest, catalog: Self.liveCatalog, liveCapture: true)
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
