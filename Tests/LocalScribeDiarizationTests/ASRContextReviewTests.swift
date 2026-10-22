import XCTest
import LocalScribeCore
@testable import LocalScribeWorker

final class ASRContextReviewTests: XCTestCase {
    private func segment(_ start: Int, _ end: Int, uncertain: Bool) -> Segment {
        Segment(id: "fixture", startMs: start, endMs: end, text: "fixture", language: "ru", uncertain: uncertain)
    }

    func testHealthyTextDoesNotScheduleReviewAndUncertaintyDoes() {
        for uncertain in [false, true] {
            let plan = ASRContextReviewPlanner.plan(segments: [segment(10200, 20000, uncertain: uncertain)],
                samples: [Float](repeating: 0.1, count: 12000 * 16), readStartMs: 9000, readEndMs: 21000,
                coreStartMs: 10000, coreEndMs: 20000, originMs: 0, durationMs: 60000)
            XCTAssertEqual(plan.requests.count, uncertain ? 1 : 0)
            if let request = plan.requests.first {
                XCTAssertEqual(request.reasons, [.uncertainText])
                XCTAssertEqual(request.contextStartMs, 100)
                XCTAssertEqual(request.contextEndMs, 30100)
            }
        }
    }

    func testShortInputIsNotRetriedWithIdenticalContext() {
        let plan = ASRContextReviewPlanner.plan(segments: [segment(200, 10000, uncertain: true)],
            samples: [Float](repeating: 0.1, count: 10000 * 16), readStartMs: 0, readEndMs: 10000,
            coreStartMs: 0, coreEndMs: 10000, originMs: 0, durationMs: 10000)
        XCTAssertTrue(plan.requests.isEmpty)
        XCTAssertEqual(plan.unchangedContextTargets, 1)
    }

    func testContextAlreadyUsedByPrefixRecoveryIsNotDecodedAgain() {
        let plan = ASRContextReviewPlanner.plan(segments: [segment(200, 28000, uncertain: true)],
            samples: [Float](repeating: 0.1, count: 29000 * 16), readStartMs: 0, readEndMs: 29000,
            coreStartMs: 0, coreEndMs: 28000, originMs: 0, durationMs: 60000, previousContexts: [0..<30000])
        XCTAssertEqual(plan.unchangedContextTargets, 1)
        XCTAssertEqual(plan.requests.count, 1)
        XCTAssertNotEqual(plan.requests.first?.contextStartMs, 0)
    }

    func testLiveContextUsesOnlyAvailableSamplesAndLongTargetIsSplit() {
        let plan = ASRContextReviewPlanner.plan(segments: [segment(60200, 88000, uncertain: true)],
            samples: [Float](repeating: 0.1, count: 29000 * 16), readStartMs: 60000, readEndMs: 89000,
            coreStartMs: 60000, coreEndMs: 88000, originMs: 60000, durationMs: 90200)
        XCTAssertEqual(plan.requests.map(\.startMs), [60200, 80200])
        XCTAssertEqual(plan.requests.map(\.endMs), [80200, 88000])
        for request in plan.requests {
            XCTAssertGreaterThanOrEqual(request.contextStartMs, 60000)
            XCTAssertLessThanOrEqual(request.contextStartMs, request.startMs)
            XCTAssertGreaterThanOrEqual(request.contextEndMs, request.endMs)
            XCTAssertLessThanOrEqual(request.contextEndMs, 90200)
            XCTAssertLessThanOrEqual(request.contextEndMs - request.contextStartMs, 30000)
        }
    }

    func testCallBudgetIsBoundedAndDeferredTargetsAreReported() {
        let segments = (0..<14).map { segment(30000 + $0 * 2000, 30500 + $0 * 2000, uncertain: true) }
        let plan = ASRContextReviewPlanner.plan(segments: segments, samples: [Float](repeating: 0, count: 30000 * 16),
            readStartMs: 29000, readEndMs: 59000, coreStartMs: 30000, coreEndMs: 58000, originMs: 0, durationMs: 120000)
        XCTAssertEqual(plan.requests.count, 3)
        XCTAssertEqual(plan.deferredTargets, 11)
        XCTAssertEqual(plan.requests.map(\.startMs), [30000, 32000, 34000])
    }

    func testShortNoiseDoesNotCreateSpeechCandidate() {
        var samples = [Float](repeating: 0, count: 12000 * 16)
        for index in (6000 * 16)..<(6200 * 16) { samples[index] = 0.1 }
        let plan = ASRContextReviewPlanner.plan(segments: [segment(10200, 12000, uncertain: false), segment(18000, 20000, uncertain: false)],
            samples: samples, readStartMs: 9000, readEndMs: 21000,
            coreStartMs: 10000, coreEndMs: 20000, originMs: 0, durationMs: 60000)
        XCTAssertTrue(plan.requests.isEmpty)
    }

    func testReviewOriginalUsesWordMidpointsAndPreservesPlaceholder() {
        let segment = Segment(id: "worded", startMs: 0, endMs: 3000, text: "one two three", language: "en", words: [
            Word(text: "one", startMs: 0, endMs: 1000), Word(text: " two", startMs: 1000, endMs: 2000),
            Word(text: " three", startMs: 2000, endMs: 3000)])
        let owned = ASRContextReviewPlanner.ownedSegments([segment], startMs: 1500, endMs: 2500)
        XCTAssertEqual(owned.map(\.text), [" two"])
        XCTAssertEqual(owned.first?.startMs, 1000)
        XCTAssertEqual(owned.first?.endMs, 2000)
        let placeholder = Segment(id: "empty", startMs: 1000, endMs: 2000, text: "[неразборчиво]", language: "ru", uncertain: true)
        XCTAssertEqual(ASRContextReviewPlanner.ownedSegments([placeholder], startMs: 1500, endMs: 2500), [placeholder])
    }
}
