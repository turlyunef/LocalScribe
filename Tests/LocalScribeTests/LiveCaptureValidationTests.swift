import XCTest
@testable import LocalScribeCore

/// Branch matrix for the in-memory live-capture validators. `validate` is a pure
/// contract check and never touches disk, so every fixture is built directly.
final class LiveCaptureValidationTests: XCTestCase {
    private let hex64 = String(repeating: "a", count: 64)

    private func runInfo() -> RunInfo {
        RunInfo(sourceHash: hex64, profileHash: String(repeating: "b", count: 64))
    }
    private func fragment(_ index: Int, seconds: Double, rate: Double = 16_000, sha256: String? = nil) -> CaptureFragment {
        CaptureFragment(index: index, frames: Int64(rate * seconds), sampleRate: rate, sha256: sha256 ?? hex64)
    }
    /// Closed 10-second fragments plus a short final tail — a valid seal baseline.
    private func validSeal(info: RunInfo) -> CaptureSeal {
        CaptureSeal(info: info, sourceHash: hex64, fragments: [fragment(0, seconds: 10), fragment(1, seconds: 2)])
    }
    /// The window clamps bind from the available side: endMs and readEndMs equal availableMs.
    private func validPart(info: RunInfo) -> LiveASRPart {
        let segment = Segment(id: "seg-000000", startMs: 30_000, endMs: 45_000, text: "Live part", language: "en")
        let part = ASRPart(fingerprint: info.fingerprint, index: 1, startMs: 30_000, endMs: 45_000, segments: [segment])
        return LiveASRPart(part: part, readStartMs: 29_000, readEndMs: 45_000,
                           fragments: [fragment(0, seconds: 10), fragment(1, seconds: 2), fragment(2, seconds: 5)])
    }
    private func check(_ saved: LiveASRPart, info: RunInfo, index: Int = 1, startMs: Int = 30_000,
                       availableMs: Int = 45_000, fragments: [CaptureFragment]? = nil) throws {
        try saved.validate(info: info, index: index, startMs: startMs, availableMs: availableMs,
                           fragments: fragments ?? saved.fragments)
    }

    // MARK: CaptureSeal.validate

    func testValidSealAndCatalogBoundariesAreAccepted() throws {
        let info = runInfo()
        try validSeal(info: info).validate(info: info)
        // 1080 fragments of exactly 10 seconds reach the three-hour duration cap.
        let full = (0..<1080).map { fragment($0, seconds: 10) }
        let capped = CaptureSeal(info: info, sourceHash: hex64, fragments: full)
        XCTAssertEqual(capped.fragments.count, 1080)
        XCTAssertEqual(capped.durationMs, 10_800_000)
        try capped.validate(info: info)
    }

    func testSealRejectsHeaderAndDurationCapViolations() throws {
        let info = runInfo()
        var wrong = validSeal(info: info)
        wrong.schemaVersion = 2
        XCTAssertThrowsError(try wrong.validate(info: info)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Не прошла проверка завершения потока записи"))
        }
        wrong = validSeal(info: info); wrong.captureFingerprint = "foreign"
        XCTAssertThrowsError(try wrong.validate(info: info))
        wrong = validSeal(info: info); wrong.sourceHash = String(repeating: "a", count: 63)
        XCTAssertThrowsError(try wrong.validate(info: info))
        XCTAssertThrowsError(try CaptureSeal(info: info, sourceHash: hex64, fragments: []).validate(info: info))
        // 1081 fragments pass the count cap, but ten seconds each exceed the duration cap.
        let over = CaptureSeal(info: info, sourceHash: hex64, fragments: (0..<1081).map { fragment($0, seconds: 10) })
        XCTAssertEqual(over.durationMs, 10_810_000)
        XCTAssertThrowsError(try over.validate(info: info))
        // 1082 fragments jointly break the count cap and the duration cap.
        XCTAssertThrowsError(try CaptureSeal(info: info, sourceHash: hex64, fragments: (0..<1082).map { fragment($0, seconds: 10) }).validate(info: info))
    }

    func testSealRejectsFragmentGeometryViolations() throws {
        let info = runInfo()
        // The final fragment may be short, but never longer than ten seconds.
        var wrong = validSeal(info: info); wrong.fragments = [fragment(0, seconds: 10), fragment(1, seconds: 12)]
        XCTAssertThrowsError(try wrong.validate(info: info))
        // Every non-final fragment must be exactly ten seconds.
        wrong = validSeal(info: info); wrong.fragments = [fragment(0, seconds: 5), fragment(1, seconds: 2)]
        XCTAssertThrowsError(try wrong.validate(info: info))
        // All fragments share the sample rate of the first one.
        wrong = validSeal(info: info)
        wrong.fragments = [fragment(0, seconds: 10, rate: 16_000), fragment(1, seconds: 2, rate: 44_100)]
        XCTAssertThrowsError(try wrong.validate(info: info))
        wrong = validSeal(info: info); wrong.fragments[0].sha256 = "truncated"
        XCTAssertThrowsError(try wrong.validate(info: info))
    }

    // MARK: LiveASRPart.validate

    func testValidPartAndWindowBoundariesAreAccepted() throws {
        let info = runInfo()
        try check(validPart(info: info), info: info)
        // The context side of the clamps: endMs == startMs + 30s, readEndMs == endMs + 1s.
        var part = validPart(info: info)
        part.part = ASRPart(fingerprint: info.fingerprint, index: 0, startMs: 10_000, endMs: 40_000,
                            segments: [Segment(id: "seg-000000", startMs: 10_000, endMs: 40_000, text: "Live part", language: "en")])
        part.readStartMs = 9_000; part.readEndMs = 41_000
        try check(part, info: info, index: 0, startMs: 10_000, availableMs: 60_000)
        // Index 360 is the last accepted checkpoint number.
        var last = validPart(info: info); last.part.index = 360
        try check(last, info: info, index: 360)
        // A start inside the context window clamps readStartMs to zero.
        var early = validPart(info: info)
        early.part = ASRPart(fingerprint: info.fingerprint, index: 0, startMs: 500, endMs: 30_500,
                             segments: [Segment(id: "seg-000000", startMs: 500, endMs: 30_500, text: "Live part", language: "en")])
        early.readStartMs = 0; early.readEndMs = 31_500
        try check(early, info: info, index: 0, startMs: 500)
        // The maximum recording duration is accepted with all windows clamped to it.
        var edge = validPart(info: info)
        edge.part = ASRPart(fingerprint: info.fingerprint, index: 0, startMs: 10_799_000, endMs: 10_800_000,
                            segments: [Segment(id: "seg-000000", startMs: 10_799_000, endMs: 10_800_000, text: "Live part", language: "en")])
        edge.readStartMs = 10_798_000; edge.readEndMs = 10_800_000
        try check(edge, info: info, index: 0, startMs: 10_799_000, availableMs: 10_800_000)
    }

    func testPartRejectsCallerArgumentViolations() throws {
        let info = runInfo()
        // No audio available rejects the checkpoint (startMs < availableMs cannot hold either).
        XCTAssertThrowsError(try check(validPart(info: info), info: info, availableMs: 0))
        // One millisecond past the three-hour cap; every other condition holds.
        var edge = validPart(info: info)
        edge.part = ASRPart(fingerprint: info.fingerprint, index: 0, startMs: 10_799_000, endMs: 10_800_000,
                            segments: [Segment(id: "seg-000000", startMs: 10_799_000, endMs: 10_800_000, text: "Live part", language: "en")])
        edge.readStartMs = 10_798_000; edge.readEndMs = 10_800_001
        XCTAssertThrowsError(try check(edge, info: info, index: 0, startMs: 10_799_000, availableMs: 10_800_001)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Контрольная точка фонового распознавания не соответствует звуку"))
        }
        // A negative start is rejected on its own; the checkpoint itself stays aligned.
        var before = validPart(info: info)
        before.part = ASRPart(fingerprint: info.fingerprint, index: 0, startMs: -1, endMs: 1_000,
                              segments: [Segment(id: "seg-000000", startMs: 0, endMs: 1_000, text: "Live part", language: "en")])
        before.readStartMs = 0; before.readEndMs = 2_000
        XCTAssertThrowsError(try check(before, info: info, index: 0, startMs: -1))
        // A checkpoint starting at the end of the audio can never satisfy the window clamps.
        var atEnd = validPart(info: info)
        atEnd.part = ASRPart(fingerprint: info.fingerprint, index: 1, startMs: 45_000, endMs: 45_001,
                             segments: [Segment(id: "seg-000000", startMs: 44_000, endMs: 45_000, text: "Live part", language: "en")])
        atEnd.readStartMs = 44_000; atEnd.readEndMs = 45_001
        XCTAssertThrowsError(try check(atEnd, info: info, index: 1, startMs: 45_000))
        var negative = validPart(info: info); negative.part.index = -1
        XCTAssertThrowsError(try check(negative, info: info, index: -1))
        var future = validPart(info: info); future.part.index = 361
        XCTAssertThrowsError(try check(future, info: info, index: 361))
    }

    func testPartRejectsSchemaAndIdentityMismatches() throws {
        let info = runInfo()
        var wrong = validPart(info: info); wrong.schemaVersion = 2
        XCTAssertThrowsError(try check(wrong, info: info))
        wrong = validPart(info: info); wrong.part.schemaVersion = 2
        XCTAssertThrowsError(try check(wrong, info: info))
        wrong = validPart(info: info); wrong.part.index = 2
        XCTAssertThrowsError(try check(wrong, info: info, index: 1))
        wrong = validPart(info: info); wrong.part.startMs = 31_000
        XCTAssertThrowsError(try check(wrong, info: info, startMs: 30_000))
    }

    func testPartRejectsWindowAndClampViolations() throws {
        let info = runInfo()
        // endMs == startMs leaves an empty part window even though readEndMs stays valid.
        var wrong = validPart(info: info); wrong.part.endMs = 30_000; wrong.readEndMs = 31_000
        XCTAssertThrowsError(try check(wrong, info: info))
        // endMs past startMs + 30s; readEndMs is still within its own clamp.
        wrong = validPart(info: info)
        wrong.part = ASRPart(fingerprint: info.fingerprint, index: 0, startMs: 10_000, endMs: 40_001,
                             segments: [Segment(id: "seg-000000", startMs: 10_000, endMs: 40_000, text: "Live part", language: "en")])
        wrong.readStartMs = 9_000; wrong.readEndMs = 41_001
        XCTAssertThrowsError(try check(wrong, info: info, index: 0, startMs: 10_000, availableMs: 60_000))
        // At startMs 0 the read window must clamp to zero, not keep one second of context.
        wrong = validPart(info: info)
        wrong.part = ASRPart(fingerprint: info.fingerprint, index: 0, startMs: 0, endMs: 30_000,
                             segments: [Segment(id: "seg-000000", startMs: 0, endMs: 30_000, text: "Live part", language: "en")])
        wrong.readStartMs = 1_000; wrong.readEndMs = 31_000
        XCTAssertThrowsError(try check(wrong, info: info, index: 0, startMs: 0))
        // Mid-stream the context is exactly one second, not the whole preceding audio.
        wrong = validPart(info: info); wrong.readStartMs = 30_000
        XCTAssertThrowsError(try check(wrong, info: info))
        wrong = validPart(info: info); wrong.readEndMs = 44_999
        XCTAssertThrowsError(try check(wrong, info: info))
        // readEndMs past endMs + 1s with plenty of audio available.
        wrong = validPart(info: info)
        wrong.part = ASRPart(fingerprint: info.fingerprint, index: 0, startMs: 10_000, endMs: 40_000,
                             segments: [Segment(id: "seg-000000", startMs: 10_000, endMs: 40_000, text: "Live part", language: "en")])
        wrong.readStartMs = 9_000; wrong.readEndMs = 41_001
        XCTAssertThrowsError(try check(wrong, info: info, index: 0, startMs: 10_000, availableMs: 60_000))
        // readEndMs may never read past the available audio.
        wrong = validPart(info: info); wrong.readEndMs = 45_500
        XCTAssertThrowsError(try check(wrong, info: info))
    }

    func testPartRejectsFragmentAndSegmentViolations() throws {
        let info = runInfo()
        let saved = validPart(info: info)
        // The checkpoint must carry exactly the fragments the caller computed from the seal.
        XCTAssertThrowsError(try check(saved, info: info, fragments: []))
        XCTAssertThrowsError(try check(saved, info: info,
                                       fragments: [saved.fragments[0], saved.fragments[1], fragment(2, seconds: 5, sha256: String(repeating: "c", count: 64))]))
        // Segment bounds are enforced by the nested transcript validation, not the guard.
        var beyond = saved
        beyond.part.segments = [Segment(id: "seg-000000", startMs: 30_000, endMs: 45_001, text: "Live part", language: "en")]
        XCTAssertThrowsError(try check(beyond, info: info)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Некорректные таймкоды или идентификаторы расшифровки"))
        }
    }
}
