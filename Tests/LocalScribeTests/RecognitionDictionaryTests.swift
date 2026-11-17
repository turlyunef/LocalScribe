import XCTest
import AVFoundation
@testable import LocalScribeCore

final class RecognitionDictionaryTests: XCTestCase {
    func testSanitizeTrimsDropsEmptyLinesAndExactDuplicates() throws {
        let terms = try RecognitionDictionary.normalize([
            "  LocalScribe  ", "", "   ", "КамАЗ", "LocalScribe", "КамАЗ", "Qwen3-ASR",
            "\tЕвгений\t", "LocalScribe "
        ])
        XCTAssertEqual(terms, ["LocalScribe", "КамАЗ", "Qwen3-ASR", "Евгений"])
    }

    func testCaseScriptAndOrderArePreservedAndNearDuplicatesKept() throws {
        let terms = try RecognitionDictionary.normalize(["локалскрайб", "ЛокалСкрайб", "LocalScribe", "localScribe"])
        XCTAssertEqual(terms, ["локалскрайб", "ЛокалСкрайб", "LocalScribe", "localScribe"])
    }

    func testStructuralCapsRejectInsteadOfTrimming() {
        XCTAssertNoThrow(try RecognitionDictionary.normalize([]))
        // Exact duplicates collapse first; the count cap applies to distinct terms.
        XCTAssertNoThrow(try RecognitionDictionary.normalize(Array(repeating: "термин", count: RecognitionDictionary.maximumTerms + 1)))
        XCTAssertThrowsError(try RecognitionDictionary.normalize((0...RecognitionDictionary.maximumTerms).map { "термин\($0)" }))
        XCTAssertThrowsError(try RecognitionDictionary.normalize([String(repeating: "д", count: RecognitionDictionary.maximumTermCharacters + 1)]))
        let long = (0..<RecognitionDictionary.maximumTerms).map { "термин\($0)" }
        XCTAssertThrowsError(try RecognitionDictionary.normalize(long + ["ещё один термин"]))
        XCTAssertNoThrow(try RecognitionDictionary.normalize(long))
    }

    func testOnlyWhisperAndQwenBackendsConsumeTheHint() {
        XCTAssertTrue(RecognitionDictionary.supportsHint(backend: "whisper"))
        XCTAssertTrue(RecognitionDictionary.supportsHint(backend: "qwen3"))
        XCTAssertFalse(RecognitionDictionary.supportsHint(backend: "gigaam"))
        XCTAssertFalse(RecognitionDictionary.supportsHint(backend: "vibevoice-asr"))
        XCTAssertFalse(RecognitionDictionary.supportsHint(backend: nil))
    }

    func testFingerprintFormulaKeepsLegacyRunsAndIncludesDictionary() {
        var info = RunInfo(sourceHash: "source", profileHash: "profile")
        XCTAssertEqual(info.fingerprint, Disk.fingerprint(info.sourceHash + info.profileHash + info.pipelineVersion))
        info.recognitionTerms = []
        XCTAssertEqual(info.fingerprint, Disk.fingerprint(info.sourceHash + info.profileHash + info.pipelineVersion))
        info.recognitionTerms = ["LocalScribe", "КамАЗ"]
        XCTAssertEqual(info.fingerprint,
            Disk.fingerprint(info.sourceHash + info.profileHash + info.pipelineVersion + "recognition:LocalScribe\nКамАЗ"))
        var reordered = info; reordered.recognitionTerms = ["КамАЗ", "LocalScribe"]
        XCTAssertNotEqual(info.fingerprint, reordered.fingerprint)
    }

    func testLegacyRunJSONWithoutDictionaryDecodesWithNilTerms() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root)
        var m = Manifest(sourceType: "microphone", title: "Legacy", filename: "original.caf")
        m.sourceComplete = true; m.sha256 = String(repeating: "a", count: 64); m.durationMs = 1000
        try repo.save(m)
        let catalog = ModelCatalog(models: ModelRole.audioRoles.map {
            ModelProfile(id: $0.rawValue, repository: "fixture/local", revision: "r", license: "test", files: [], role: $0)
        })
        let info = try repo.beginRun(&m, catalog: catalog)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(info)) as! [String: Any]
        // Older builds wrote no dictionary key at all.
        let legacy = try JSONDecoder().decode(RunInfo.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.recognitionTerms)
        XCTAssertEqual(legacy.fingerprint, Disk.fingerprint(legacy.sourceHash + legacy.profileHash + legacy.pipelineVersion))
        json.removeValue(forKey: "recognitionTerms")
        XCTAssertNil(try JSONDecoder().decode(RunInfo.self, from: JSONSerialization.data(withJSONObject: json)).recognitionTerms)
    }

    func testBeginRunPinsNormalizedSnapshotAndRejectsUnnormalizedInput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root)
        var m = Manifest(sourceType: "microphone", title: "Dict", filename: "original.caf")
        m.sourceComplete = true; m.sha256 = String(repeating: "b", count: 64); m.durationMs = 1000
        try repo.save(m)
        let catalog = ModelCatalog(models: ModelRole.audioRoles.map {
            ModelProfile(id: $0.rawValue, repository: "fixture/local", revision: "r", license: "test", files: [], role: $0)
        })
        let terms = ["LocalScribe", "КамАЗ"]
        let info = try repo.beginRun(&m, catalog: catalog, recognitionTerms: terms)
        XCTAssertEqual(info.recognitionTerms, terms)
        let saved = try Disk.read(RunInfo.self, at: repo.run(m.id, info.id).appendingPathComponent("run.json"))
        XCTAssertEqual(saved.recognitionTerms, terms)
        XCTAssertThrowsError(try repo.beginRun(&m, catalog: catalog, recognitionTerms: [" ", "термин", "термин"]))
        XCTAssertThrowsError(try repo.beginRun(&m, catalog: catalog, recognitionTerms: [String(repeating: "д", count: 200)]))
        XCTAssertThrowsError(try repo.beginRun(&m, catalog: catalog, recognitionTerms: ["LocalScribe\nКамАЗ"]))
        XCTAssertEqual(m.pendingRunId, info.id)
        var damaged = info
        damaged.recognitionTerms = ["LocalScribe\nКамАЗ"]
        XCTAssertEqual(damaged.fingerprint, info.fingerprint)
        XCTAssertThrowsError(try JSONDecoder().decode(RunInfo.self, from: JSONEncoder().encode(damaged)))
        // An empty list never pins a dictionary.
        let empty = try repo.beginRun(&m, catalog: catalog, recognitionTerms: [])
        XCTAssertNil(empty.recognitionTerms)
        XCTAssertEqual(empty.fingerprint, Disk.fingerprint(empty.sourceHash + empty.profileHash + empty.pipelineVersion))
    }

    /// Live capture requires a closed-fragment (Whisper) ASR profile.
    private static let liveCatalog = ModelCatalog(models: [
        ModelProfile(id: "asr", repository: "fixture/whisper", revision: "fixed", license: "test", files: [], role: .asr)
    ])
    private func writeAudio(_ url: URL, seconds: Double, value: Float = 0.125) throws {
        try Disk.directory(url.deletingLastPathComponent())
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * 16000))!
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = value }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    /// A dictionary-pinned live capture binds to the original, and checkpoints
    /// of a run with a different dictionary cannot be replayed: the snapshot is
    /// part of the checkpoint fingerprint.
    func testLiveCaptureWithDictionaryBindsAndRejectsForeignCheckpoints() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root)
        var m = Manifest(sourceType: "microphone", title: "Live dict", filename: "original.caf")
        m.state = .recording
        let terms = ["LocalScribe", "Евгений"]
        var info = try repo.beginRun(&m, catalog: Self.liveCatalog, liveCapture: true, recognitionTerms: terms)
        XCTAssertEqual(info.recognitionTerms, terms)
        let captureRun = try Disk.read(RunInfo.self, at: repo.run(m.id, info.id).appendingPathComponent("capture-run.json"))
        XCTAssertEqual(captureRun.recognitionTerms, terms)
        let folder = repo.folder(m.id).appendingPathComponent("capture")
        try writeAudio(folder.appendingPathComponent("part-000000.caf"), seconds: 1)
        let original = repo.folder(m.id).appendingPathComponent(m.originalRelativePath)
        try Disk.directory(original.deletingLastPathComponent())
        let (frames, rate) = try Media.assembleCapture(folder, destination: original)
        m.sourceComplete = true; m.sha256 = try Disk.hash(original); m.durationMs = Int(Double(frames) / rate * 1000)
        m.sampleRate = rate; m.channels = 1; m.state = .recorded; try repo.save(m)
        let fragments = try CaptureIntegrity.fragments(at: folder)
        let seal = CaptureSeal(info: info, sourceHash: m.sha256, fragments: fragments)
        try Disk.write(seal, to: repo.run(m.id, info.id).appendingPathComponent("capture-seal.json"))

        // A checkpoint written by a dictionary-less run has a foreign fingerprint.
        var withoutDictionary = info
        withoutDictionary.recognitionTerms = nil
        XCTAssertNotEqual(withoutDictionary.fingerprint, info.fingerprint)
        let foreign = LiveASRPart(part: ASRPart(fingerprint: withoutDictionary.fingerprint, index: 0, startMs: 0, endMs: 1000, segments: []),
                                  readStartMs: 0, readEndMs: 1000, fragments: fragments)
        try Disk.write(foreign, to: repo.run(m.id, info.id).appendingPathComponent("live/part-0.json"))
        XCTAssertThrowsError(try repo.bindLiveTranscript(m.id, info: info))

        let own = LiveASRPart(part: ASRPart(fingerprint: info.fingerprint, index: 0, startMs: 0, endMs: 1000, segments: []),
                              readStartMs: 0, readEndMs: 1000, fragments: fragments)
        try Disk.write(own, to: repo.run(m.id, info.id).appendingPathComponent("live/part-0.json"))
        info = try repo.bindLiveTranscript(m.id, info: info)
        XCTAssertEqual(info.recognitionTerms, terms)
        let transcript = try Disk.read(Transcript.self, at: repo.run(m.id, info.id).appendingPathComponent("asr-transcript.json"))
        XCTAssertEqual(transcript.fingerprint, info.fingerprint)
    }
}
