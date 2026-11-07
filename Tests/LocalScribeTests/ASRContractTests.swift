import XCTest
@testable import LocalScribeCore

final class ASRContractTests: XCTestCase {
    func testRequestHasNoWhisperWindowLimitAndKeepsSourceCoordinates() throws {
        for mode in [ASRInputMode.offline, .closedFragments] {
            let request = try ASRRequest(audioURL: URL(fileURLWithPath: "/fixture.wav"), originMs: 60000,
                availableEndMs: 240000, coreRange: 61000..<239000, mode: mode)
            XCTAssertEqual(request.coreRange.count, 178000)
            XCTAssertEqual(request.originMs, 60000)
            XCTAssertEqual(request.availableEndMs, 240000)
        }
    }

    func testInvalidAudioRangesFailBeforeReadingAFile() {
        let file = URL(fileURLWithPath: "/missing.wav")
        for (origin, end, range) in [(1000, 5000, 0..<5000), (0, 4000, 0..<5000),
                                     (-1, 5000, 0..<5000), (0, 0, 0..<0), (0, Int.max, 0..<Int.max)] {
            XCTAssertThrowsError(try ASRRequest(audioURL: file, originMs: origin, availableEndMs: end,
                coreRange: range, mode: .closedFragments))
        }
        XCTAssertThrowsError(try ASRRequest(audioURL: URL(string: "https://invalid.example/audio.wav")!,
            availableEndMs: 1000, coreRange: 0..<1000, mode: .offline))
    }

    func testExistingCatalogFingerprintsAndTokenizerSelectionsRemainExact() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let catalog = try Disk.read(ModelCatalog.self, at: root.appendingPathComponent("Resources/models.lock.json"))
        for asr in catalog.models where asr.purpose == .asr && asr.resolvedASRBackend == "whisper" {
            let selected = try ModelRole.audioRoles.map { role in
                try XCTUnwrap(role == .asr ? asr : catalog.models.first { $0.id == (role == .tokenizer ? asr.tokenizerID ?? "tokenizer" : role.rawValue) })
            }
            let legacy = selected.allSatisfy { $0.id == $0.purpose?.rawValue }
            let expected = Disk.fingerprint(selected.map { legacy ? $0.revision : "\($0.id):\($0.revision):\($0.files.map(\.sha256).joined())" }.joined(separator: ":"))
            let pinned = ModelCatalog(models: selected)
            XCTAssertEqual(pinned.fingerprint, expected)
            var info = RunInfo(sourceHash: "source", profileHash: expected)
            info.modelIDs = Dictionary(uniqueKeysWithValues: selected.map { ($0.purpose!.rawValue, $0.id) })
            XCTAssertEqual(try catalog.pinned(to: info).fingerprint, expected)
            XCTAssertEqual(try info.modelID(for: .tokenizer), asr.tokenizerID ?? "tokenizer")
            var annotated = pinned
            annotated.models[0].asrBackend = "whisper"
            XCTAssertEqual(annotated.fingerprint, expected)
            XCTAssertEqual(try annotated.pinned(to: info).fingerprint, expected)
            annotated.models[0].asrBackend = "future-engine"
            XCTAssertNotEqual(annotated.fingerprint, expected)
            XCTAssertThrowsError(try annotated.pinned(to: info))
            XCTAssertEqual(info.pipelineVersion, "1.0.0-audio2-asr9-live1-diarization4-summary16")
        }
        let legacyProfile = Data(#"{"id":"asr","repository":"fixture","revision":"r","license":"test","files":[]}"#.utf8)
        let profile = try JSONDecoder().decode(ModelProfile.self, from: legacyProfile)
        XCTAssertNil(profile.asrBackend)
        XCTAssertEqual(profile.resolvedASRBackend, "whisper")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(profile), as: UTF8.self).contains("asrBackend"))
    }
}
