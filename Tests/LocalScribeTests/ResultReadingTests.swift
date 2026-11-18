import XCTest
@testable import LocalScribeCore

final class ResultReadingTests: XCTestCase {
    /// Live capture requires a closed-fragment (Whisper) ASR profile in the catalog.
    private static let liveCatalog = ModelCatalog(models: [
        ModelProfile(id: "asr", repository: "fixture/whisper", revision: "fixed", license: "test", files: [], role: .asr)
    ])

    func testTranscriptionModelFollowsSourceInsteadOfSummaryModelsAndPendingRun() throws {
        try fixture { repo, original, info, _, _ in
            var source = info
            source.modelIDs = ["asr": "original-asr"]
            try Disk.write(source, to: repo.run(original.id, source.id).appendingPathComponent("run.json"))
            var copied = RunInfo(sourceHash: original.sha256, profileHash: "new-models")
            copied.modelIDs = ["asr": "currently-selected-asr"]
            copied.transcriptSourceRunID = source.id
            try Disk.write(copied, to: repo.run(original.id, copied.id).appendingPathComponent("run.json"))
            var manifest = original
            manifest.activeRunId = copied.id
            manifest.pendingRunId = UUID().uuidString
            XCTAssertEqual(repo.transcriptionModelID(manifest), "original-asr")
            copied.transcriptSourceRunID = copied.id
            try Disk.write(copied, to: repo.run(original.id, copied.id).appendingPathComponent("run.json"))
            XCTAssertNil(repo.transcriptionModelID(manifest))
            copied.transcriptSourceRunID = "../invalid"
            try Disk.write(copied, to: repo.run(original.id, copied.id).appendingPathComponent("run.json"))
            XCTAssertNil(repo.transcriptionModelID(manifest))
            XCTAssertEqual(repo.transcriptionModelID(original), "original-asr")
        }
    }
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

    // MARK: - Incremental checkpoint reading

    /// Pending offline preview with several immutable parts; reading with the
    /// cache must equal the uncached full read, reuse unchanged parts (an old
    /// part made unreadable must not surface), read only the new tail, and
    /// surface a part that actually changed on disk exactly like a full read.
    func testCheckpointCacheReusesImmutablePartsReadsNewTailAndSurfacesChangedParts() throws {
        try fixture { repo, original, info, _, _ in
            var manifest = original
            manifest.activeRunId = nil; manifest.pendingRunId = info.id; manifest.durationMs = 900_000
            let path = repo.run(manifest.id, info.id)
            try FileManager.default.removeItem(at: path.appendingPathComponent("transcript.json"))
            try FileManager.default.removeItem(at: path.appendingPathComponent("summary.json"))
            let parts = path.appendingPathComponent("asr")
            func writePart(_ index: Int, text: String) throws {
                let part = ASRPart(fingerprint: info.fingerprint, index: index,
                                   startMs: index * 300_000, endMs: (index + 1) * 300_000,
                                   segments: [Segment(id: "s\(index)", startMs: index * 300_000,
                                                      endMs: index * 300_000 + 1000, text: text, language: "ru")])
                try Disk.write(part, to: parts.appendingPathComponent("part-\(index).json"))
            }
            try writePart(0, text: "ноль")
            try writePart(1, text: "один")
            let cache = ResultCheckpointCache()
            let expected = try repo.results(manifest).0
            XCTAssertEqual(try repo.results(manifest, reusing: cache).0, expected)
            // An already decoded part is not opened again: making it unreadable
            // must not break the cached read (size/mtime stay unchanged).
            try FileManager.default.setAttributes([.posixPermissions: 0o000],
                                                  ofItemAtPath: parts.appendingPathComponent("part-0.json").path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                           ofItemAtPath: parts.appendingPathComponent("part-0.json").path) }
            XCTAssertEqual(try repo.results(manifest, reusing: cache).0, expected)
            try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                  ofItemAtPath: parts.appendingPathComponent("part-0.json").path)
            // A new checkpoint only reads the new tail and merges everything.
            try writePart(2, text: "два")
            let grown = try repo.results(manifest).0
            XCTAssertEqual(try repo.results(manifest, reusing: cache).0, grown)
            XCTAssertEqual(grown?.segments.map(\.text), ["ноль", "один", "два"])
            // A part that actually changed on disk is re-read and its damage
            // surfaces with the same message as an uncached read.
            try Data("broken JSON".utf8).write(to: parts.appendingPathComponent("part-1.json"))
            XCTAssertThrowsError(try repo.results(manifest, reusing: cache)) { error in
                XCTAssertTrue(error.localizedDescription.contains("Файлы сохранены для восстановления"))
            }
            XCTAssertThrowsError(try repo.results(manifest)) { error in
                XCTAssertTrue(error.localizedDescription.contains("Файлы сохранены для восстановления"))
            }
            try writePart(1, text: "один")
            XCTAssertEqual(try repo.results(manifest, reusing: cache).0, grown)
        }
    }

    /// The cache keeps only the parts of the latest read: after switching to
    /// another run, the previous run's parts are gone and must be read again.
    func testCheckpointCacheDropsPartsOfPreviousRun() throws {
        try fixture { repo, original, info, _, _ in
            var manifest = original
            manifest.activeRunId = nil; manifest.pendingRunId = info.id; manifest.durationMs = 600_000
            let path = repo.run(manifest.id, info.id)
            try FileManager.default.removeItem(at: path.appendingPathComponent("transcript.json"))
            try FileManager.default.removeItem(at: path.appendingPathComponent("summary.json"))
            let part = ASRPart(fingerprint: info.fingerprint, index: 0, startMs: 0, endMs: 300_000,
                               segments: [Segment(id: "s", startMs: 0, endMs: 1000, text: "Фраза", language: "ru")])
            try Disk.write(part, to: path.appendingPathComponent("asr/part-0.json"))
            let other = RunInfo(sourceHash: manifest.sha256, profileHash: "other")
            try Disk.write(other, to: repo.run(manifest.id, other.id).appendingPathComponent("run.json"))
            try Disk.write(ASRPart(fingerprint: other.fingerprint, index: 0, startMs: 0, endMs: 300_000, segments: []),
                           to: repo.run(manifest.id, other.id).appendingPathComponent("asr/part-0.json"))

            let cache = ResultCheckpointCache()
            XCTAssertNotNil(try repo.results(manifest, reusing: cache).0)
            var switched = manifest; switched.pendingRunId = other.id
            XCTAssertEqual(try repo.results(switched, reusing: cache).0?.segments.isEmpty, true)
            // The first run's part was pruned by the switch: reading it again
            // must touch the file and therefore fail on an unreadable part.
            let firstPart = path.appendingPathComponent("asr/part-0.json")
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: firstPart.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: firstPart.path) }
            XCTAssertThrowsError(try repo.results(manifest, reusing: cache))
        }
    }

    /// Live previews use the same incremental path: an immutable live part is
    /// not re-decoded, a new part extends the transcript identically to a
    /// full read.
    func testLivePreviewCheckpointCacheReusesImmutableParts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root)
        var manifest = Manifest(sourceType: "microphone", title: "Live", filename: "original.caf")
        manifest.state = .recording
        let info = try repo.beginRun(&manifest, catalog: Self.liveCatalog, liveCapture: true)
        let path = repo.run(manifest.id, info.id)
        func writeLivePart(_ index: Int) throws -> URL {
            let start = index * 30_000
            let part = ASRPart(fingerprint: info.fingerprint, index: index, startMs: start, endMs: start + 1000,
                               segments: [Segment(id: "l\(index)", startMs: start, endMs: start + 1000,
                                                  text: "фраза \(index)", language: "ru")])
            let saved = LiveASRPart(part: part, readStartMs: max(0, start - 1000), readEndMs: start + 1000,
                                    fragments: [CaptureFragment(index: index, frames: 16000, sampleRate: 16000,
                                                                sha256: String(repeating: index % 2 == 0 ? "a" : "b", count: 64))])
            let url = path.appendingPathComponent("live/part-\(index).json")
            try Disk.write(saved, to: url)
            return url
        }
        let cache = ResultCheckpointCache()
        let zero = try writeLivePart(0)
        XCTAssertEqual(try repo.results(manifest, reusing: cache).0?.segments.map(\.text), ["фраза 0"])
        // The fresh part-1 is read and merged with the cached part-0; the
        // result equals an uncached full read of both parts.
        _ = try writeLivePart(1)
        XCTAssertEqual(try repo.results(manifest, reusing: cache).0?.segments.map(\.text), ["фраза 0", "фраза 1"])
        XCTAssertEqual(try repo.results(manifest).0?.segments.map(\.text), ["фраза 0", "фраза 1"])
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: zero.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: zero.path) }
        // A decoded live part is not opened again.
        XCTAssertEqual(try repo.results(manifest, reusing: cache).0?.segments.map(\.text), ["фраза 0", "фраза 1"])
    }
}
