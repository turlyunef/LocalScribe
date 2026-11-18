import XCTest
import AVFoundation
@testable import LocalScribeCore

final class LiveCaptureTests: XCTestCase {
    /// Live capture requires a closed-fragment (Whisper) ASR profile in the catalog.
    private static let liveCatalog = ModelCatalog(models: [
        ModelProfile(id: "asr", repository: "fixture/whisper", revision: "fixed", license: "test", files: [], role: .asr)
    ])
    private func writeAudio(_ url: URL, seconds: Double, value: Float = 0.125, pcm16: Bool = false) throws {
        try Disk.directory(url.deletingLastPathComponent())
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * 16000))!
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = value }
        let storage = pcm16 ? AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)! : format
        let file = try AVAudioFile(forWriting: url, settings: storage.settings)
        try file.write(from: buffer)
    }
    private func fixture(_ root: URL, seconds: Double = 30.125, pcm16: Bool = false) throws -> (RecordingRepository, Manifest, RunInfo, CaptureSeal) {
        let repo = try RecordingRepository(root: root)
        var m = Manifest(sourceType: "microphone", title: "Live", filename: "original.caf")
        m.state = .recording
        let info = try repo.beginRun(&m, catalog: Self.liveCatalog, liveCapture: true)
        let folder = repo.folder(m.id).appendingPathComponent("capture")
        var offset = 0.0, index = 0
        while offset < seconds {
            let length = min(10, seconds - offset)
            try writeAudio(folder.appendingPathComponent(String(format: "part-%06d.caf", index)), seconds: length, pcm16: pcm16)
            offset += length; index += 1
        }
        // An unfinished writer file must never enter the seal or original.
        try writeAudio(folder.appendingPathComponent("part-999999.partial.caf"), seconds: 1)
        let original = repo.folder(m.id).appendingPathComponent(m.originalRelativePath)
        try Disk.directory(original.deletingLastPathComponent())
        let (frames, rate) = try Media.assembleCapture(folder, destination: original)
        m.sourceComplete = true; m.sha256 = try Disk.hash(original); m.durationMs = Int(Double(frames) / rate * 1000)
        m.sampleRate = rate; m.channels = 1; m.state = .recorded; try repo.save(m)
        let seal = CaptureSeal(info: info, sourceHash: m.sha256, fragments: try CaptureIntegrity.fragments(at: folder))
        try Disk.write(seal, to: repo.run(m.id, info.id).appendingPathComponent("capture-seal.json"))
        return (repo, m, info, seal)
    }
    private func writeParts(repo: RecordingRepository, m: Manifest, info: RunInfo, seal: CaptureSeal) throws {
        var offset = 0, index = 0
        while offset < seal.durationMs {
            let end = min(offset + 30_000, seal.durationMs), readEnd = min(end + 1000, seal.durationMs)
            let inputs = seal.fragments.filter { $0.index * 10_000 < readEnd && $0.index * 10_000 + $0.durationMs > max(0, offset - 1000) }
            let segment = Segment(id: "part-\(index)", startMs: offset, endMs: end, text: "Part \(index)", language: "en")
            let checkpoint = LiveASRPart(part: ASRPart(fingerprint: info.fingerprint, index: index, startMs: offset, endMs: end, segments: [segment]), readStartMs: max(0, offset - 1000), readEndMs: readEnd, fragments: inputs)
            try Disk.write(checkpoint, to: repo.run(m.id, info.id).appendingPathComponent("live/part-\(index).json"))
            offset = end; index += 1
        }
    }
    func testSealExcludesOpenFragmentAndBindsShortTailWithoutChangingOldResult() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (repo, original, info, seal) = try fixture(root)
        var m = original; m.activeRunId = UUID().uuidString; try repo.save(m)
        XCTAssertEqual(seal.fragments.count, 4); XCTAssertEqual(seal.durationMs, 30_125)
        XCTAssertEqual(seal.fragments.last?.frames, 2000)
        try writeParts(repo: repo, m: m, info: info, seal: seal)
        let before = try Data(contentsOf: repo.run(m.id, info.id).appendingPathComponent("live/part-0.json"))
        let final = try repo.bindLiveTranscript(m.id, info: info)
        XCTAssertNotEqual(final.fingerprint, info.fingerprint); XCTAssertEqual(final.sourceHash, m.sha256)
        let transcript = try Disk.read(Transcript.self, at: repo.run(m.id, info.id).appendingPathComponent("asr-transcript.json"))
        XCTAssertEqual(transcript.segments.map(\.startMs), [0, 30_000]); XCTAssertEqual(transcript.segments.last?.endMs, 30_125)
        XCTAssertEqual(transcript.fingerprint, final.fingerprint)
        XCTAssertEqual(try Data(contentsOf: repo.run(m.id, info.id).appendingPathComponent("live/part-0.json")), before)
        XCTAssertEqual(try repo.load(m.id).activeRunId, m.activeRunId)
        XCTAssertEqual(try repo.bindLiveTranscript(m.id, info: info).fingerprint, final.fingerprint)
    }
    func testPCM16LiveCaptureBindsAndResumesWithoutChangingCheckpoint() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (repo, m, info, seal) = try fixture(root, pcm16: true)
        let original = repo.folder(m.id).appendingPathComponent(m.originalRelativePath)
        XCTAssertEqual(try AVAudioFile(forReading: original).fileFormat.commonFormat, .pcmFormatInt16)
        try writeParts(repo: repo, m: m, info: info, seal: seal)
        let checkpoint = repo.run(m.id, info.id).appendingPathComponent("live/part-0.json")
        let hash = try Disk.hash(checkpoint)
        let final = try repo.bindLiveTranscript(m.id, info: info)
        XCTAssertEqual(try repo.bindLiveTranscript(m.id, info: info).fingerprint, final.fingerprint)
        XCTAssertEqual(try Disk.hash(checkpoint), hash)
        XCTAssertEqual(try Disk.hash(original), seal.sourceHash)
        let transcript = try Disk.read(Transcript.self, at: repo.run(m.id, info.id).appendingPathComponent("asr-transcript.json"))
        XCTAssertEqual(transcript.segments.last?.endMs, 30_125)
    }

    func testChangedFragmentOrOriginalCannotBeBound() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (repo, m, info, seal) = try fixture(root, seconds: 1)
        try writeParts(repo: repo, m: m, info: info, seal: seal)
        let fragment = repo.folder(m.id).appendingPathComponent("capture/part-000000.caf")
        try writeAudio(fragment, seconds: 1, value: 0.5)
        XCTAssertThrowsError(try repo.bindLiveTranscript(m.id, info: info))
        XCTAssertEqual(try Disk.read(RunInfo.self, at: repo.run(m.id, info.id).appendingPathComponent("run.json")).sourceHash, info.sourceHash)
        // Even a seal carrying the new fragment SHA cannot attach different PCM to the original.
        let changed = CaptureSeal(info: info, sourceHash: m.sha256, fragments: try CaptureIntegrity.fragments(at: fragment.deletingLastPathComponent()))
        XCTAssertThrowsError(try CaptureIntegrity.verify(changed, info: info, folder: fragment.deletingLastPathComponent(), original: repo.folder(m.id).appendingPathComponent(m.originalRelativePath)))
    }
    func testMissingTailOrWrongCheckpointFingerprintCannotPublishTranscript() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (repo, m, info, seal) = try fixture(root)
        try writeParts(repo: repo, m: m, info: info, seal: seal)
        let tail = repo.run(m.id, info.id).appendingPathComponent("live/part-1.json")
        try FileManager.default.removeItem(at: tail)
        XCTAssertThrowsError(try repo.bindLiveTranscript(m.id, info: info))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.run(m.id, info.id).appendingPathComponent("asr-transcript.json").path))
        try writeParts(repo: repo, m: m, info: info, seal: seal)
        var part = try Disk.read(LiveASRPart.self, at: tail); part.part.fingerprint = "wrong"; try Disk.write(part, to: tail)
        XCTAssertThrowsError(try repo.bindLiveTranscript(m.id, info: info))
    }
    func testForgedRunIDIsRejectedBeforeAnyPathUse() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (repo, m, info, seal) = try fixture(root, seconds: 1)
        try writeParts(repo: repo, m: m, info: info, seal: seal)
        var forged = info; forged.id = "../../outside"
        XCTAssertThrowsError(try repo.bindLiveTranscript(m.id, info: forged)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Некорректное незавершённое задание"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("recordings").appendingPathComponent("outside").path))
    }
    func testRecoveryRetainsLiveInputsUntilVerifiedBinding() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (repo, original, info, seal) = try fixture(root, seconds: 1)
        var m = original; m.state = .queued; try repo.save(m)
        try writeParts(repo: repo, m: m, info: info, seal: seal)
        let capture = repo.folder(m.id).appendingPathComponent("capture")
        try repo.recover(); XCTAssertTrue(FileManager.default.fileExists(atPath: capture.path))
        _ = try repo.bindLiveTranscript(m.id, info: info)
        try repo.cleanupTemporaryFiles(m.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: capture.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.run(m.id, info.id).appendingPathComponent("live/part-0.json").path))
    }
    func testMalformedSealAndDifferentSessionAreRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, _, info, seal) = try fixture(root, seconds: 1)
        var wrong = seal; wrong.fragments[0].index = 1
        XCTAssertThrowsError(try wrong.validate(info: info))
        wrong = seal; wrong.fragments[0].sampleRate = .infinity
        XCTAssertThrowsError(try wrong.validate(info: info))
        wrong = seal; wrong.fragments[0].sampleRate = .greatestFiniteMagnitude
        XCTAssertThrowsError(try wrong.validate(info: info))
        wrong = seal; wrong.fragments[0].frames = 0
        XCTAssertThrowsError(try wrong.validate(info: info))
        var other = info; other.id = UUID().uuidString
        XCTAssertThrowsError(try seal.validate(info: other))
    }
    func testLiveRunDoesNotReplaceRecordingStateAndLegacyJSONStillDecodes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root)
        var m = Manifest(sourceType: "microphone", title: "Capture", filename: "original.caf"); m.state = .recording
        let info = try repo.beginRun(&m, catalog: Self.liveCatalog, liveCapture: true)
        XCTAssertEqual(m.state, .recording); XCTAssertEqual(m.captureProcessing, .queued)
        XCTAssertEqual(info.sourceHash, "capture:" + info.id)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(info)) as! [String: Any]
        json.removeValue(forKey: "liveCapture")
        XCTAssertNil(try JSONDecoder().decode(RunInfo.self, from: JSONSerialization.data(withJSONObject: json)).liveCapture)
    }
}
