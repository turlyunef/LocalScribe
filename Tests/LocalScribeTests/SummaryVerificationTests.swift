import XCTest
@testable import LocalScribeCore

/// Deliberately non-additive: includes chat framing, system/candidate text and an
/// expensive correction suffix. Counting source strings alone cannot pass these tests.
private func reviewTokens(_ request: SummaryReviewRequest) -> Int {
    113 + request.system.count / 4 + request.user.count
        + (request.user.contains("Return only") ? 811 : 0)
}

private actor ReviewMock {
    var requests: [SummaryReviewRequest] = []
    let respond: @Sendable (SummaryReviewRequest) -> String?
    init(_ respond: @escaping @Sendable (SummaryReviewRequest) -> String?) { self.respond = respond }
    func complete(_ request: SummaryReviewRequest) -> String? {
        requests.append(request)
        return respond(request)
    }
    nonisolated var model: SummaryReviewModel {
        SummaryReviewModel(tokenCount: { reviewTokens($0) }, complete: { await self.complete($0) })
    }
}

final class SummaryVerificationTests: XCTestCase {
    private func sources(count: Int, length: Int = 2000) -> [Segment] {
        (0..<count).map { index in
            Segment(id: "s\(index)", startMs: index * 1000, endMs: (index + 1) * 1000,
                    speakerId: "speaker-\(index % 2)", text: "source\(index) " + String(repeating: "x", count: length), language: "en")
        }
    }

    private func assertBudget(_ requests: [SummaryReviewRequest], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(requests.isEmpty, file: file, line: line)
        for request in requests {
            XCTAssertEqual(request.outputTokens, 512, file: file, line: line)
            XCTAssertLessThanOrEqual(reviewTokens(request) + request.outputTokens, 8192, file: file, line: line)
        }
    }

    func testSummaryCompletesWithLongNeighboursDistantEvidenceAndCorrection() async throws {
        var segments = sources(count: 10)
        segments[1].text = "Ship the release on Friday. " + segments[1].text
        segments[2].text = "Yes, agreed. " + segments[2].text
        segments[8].text = "I will notify the team. " + segments[8].text
        let transcript = Transcript(fingerprint: "fixture", diarized: true, segments: segments)
        let finding = Finding(id: "d", text: "Ship the release and notify the team", evidenceSegmentIds: ["s2", "s8"])
        let evidence = SummarySource.evidenceContext(for: finding, in: transcript)
        XCTAssertGreaterThan(evidence.reduce(0) { $0 + $1.text.count }, 8192)
        let mock = ReviewMock { request in
            // Every page needs the correction, including pages near the context limit.
            guard request.user.contains("Return only") else { return "invalid JSON" }
            if request.user.contains("Ship the release on Friday."), request.user.contains("Yes, agreed.") {
                return #"{"supported":true,"sourceSegmentId":"s1","quote":"Ship the release on Friday.","ownerSupported":false,"deadlineSupported":false}"#
            }
            return #"{"supported":false,"sourceSegmentId":null,"quote":null,"ownerSupported":false,"deadlineSupported":false}"#
        }
        // Exercise extraction -> verification -> final Summary validation without weights.
        let extracted = try await SummaryExtraction.extract(segments, language: "en") { pass in
            pass.section == .decisions ? Summary(language: "en", decisions: [finding]) : Summary(language: "en")
        }
        var summary = extracted
        summary.decisions = []
        for candidate in extracted.decisions {
            if let verified = try await SummaryVerification.checkEvidence(candidate, kind: "decision", evidence: evidence, model: mock.model) {
                summary.decisions.append(verified)
            }
        }
        XCTAssertEqual(summary.decisions.count, 1)
        XCTAssertEqual(summary.decisions[0].evidenceSegmentIds, ["s2", "s8", "s1"])
        XCTAssertTrue(summary.decisions[0].uncertain)
        try summary.validate(against: transcript)
        let requests = await mock.requests
        assertBudget(requests)
        XCTAssertGreaterThan(requests.count, 2)
        XCTAssertEqual(requests.count % 2, 0)
        for segment in evidence {
            XCTAssertTrue(requests.contains { $0.user.contains(segment.text) }, "Omitted \(segment.id)")
        }
        XCTAssertTrue(requests.contains { $0.user.contains("previous=s1 next=s3") })
    }

    func testDistributedEvidenceDoesNotTurnMissingContextIntoRejection() async throws {
        let evidence = sources(count: 5)
        let finding = Finding(id: "t", text: "Ship the release", evidenceSegmentIds: evidence.map(\.id))
        let mock = ReviewMock { _ in
            #"{"supported":false,"sourceSegmentId":null,"quote":null,"ownerSupported":false,"deadlineSupported":false}"#
        }
        let checked = try await SummaryVerification.checkEvidence(finding, kind: "task", evidence: evidence, model: mock.model)
        let result = try XCTUnwrap(checked)
        XCTAssertEqual(result.evidenceSegmentIds, finding.evidenceSegmentIds)
        XCTAssertTrue(result.uncertain)
        let requests = await mock.requests
        assertBudget(requests)
        for pair in zip(evidence, evidence.dropFirst()) {
            XCTAssertTrue(requests.contains { $0.user.contains(pair.0.text) && $0.user.contains(pair.1.text) }, "Adjacent turns must overlap")
        }
        // With the entire source visible a negative verdict still rejects the candidate.
        let rejected = try await SummaryVerification.checkEvidence(findingWithEvidence("s0"), kind: "task", evidence: [evidence[0]], model: mock.model)
        XCTAssertNil(rejected)
    }

    private func findingWithEvidence(_ id: String) -> Finding {
        Finding(id: "t", text: "Ship the release", evidenceSegmentIds: [id])
    }

    func testOversizedEditedTurnIsFullyAddressedWithoutTruncation() async throws {
        let evidence = sources(count: 1, length: 22_000)
        let mock = ReviewMock { _ in
            #"{"supported":false,"sourceSegmentId":null,"quote":null,"ownerSupported":false,"deadlineSupported":false}"#
        }
        let result = try await SummaryVerification.checkEvidence(findingWithEvidence("s0"), kind: "task", evidence: evidence, model: mock.model)
        XCTAssertEqual(result?.uncertain, true)
        let requests = await mock.requests
        assertBudget(requests)
        // Reassemble using the advertised character addresses, excluding page overlap.
        let regex = try NSRegularExpression(pattern: #"chars=(\d+)\.\.<(\d+)/(\d+) previous=outside next=outside\] ([\s\S]*)"#)
        var covered = Set<Int>()
        for request in requests {
            let text = request.user as NSString
            let match = try XCTUnwrap(regex.firstMatch(in: request.user, range: NSRange(location: 0, length: text.length)))
            let start = try XCTUnwrap(Int(text.substring(with: match.range(at: 1))))
            let end = try XCTUnwrap(Int(text.substring(with: match.range(at: 2))))
            XCTAssertEqual(Int(text.substring(with: match.range(at: 3))), evidence[0].text.count)
            XCTAssertEqual(text.substring(with: match.range(at: 4)), String(Array(evidence[0].text)[start..<end]))
            covered.formUnion(start..<end)
        }
        XCTAssertEqual(covered, Set(0..<evidence[0].text.count))
    }

    func testAmendmentPlansBothSourcesAndRetryAndMergesNoneAsNeutral() async throws {
        let original = sources(count: 5)
        var later = sources(count: 4).map { segment in
            var value = segment; value.id = "later-" + segment.id; return value
        }
        later[3].text = "Cancel shipping the release. " + later[3].text
        let mock = ReviewMock { request in
            guard request.user.contains("Return only") else { return nil } // Simulated non-EOS response.
            if request.user.contains("Cancel shipping the release.") {
                return #"{"effect":"cancelled","sourceSegmentId":"later-s3","quote":"Cancel shipping the release."}"#
            }
            return #"{"effect":"none","sourceSegmentId":null,"quote":null}"#
        }
        let candidate = String(decoding: try JSONEncoder().encode(findingWithEvidence("s0")), as: UTF8.self)
        let verdict = try await SummaryVerification.checkAmendment(candidate: candidate, original: original, later: later, model: mock.model)
        XCTAssertEqual(verdict.effect, "cancelled")
        XCTAssertEqual(verdict.sourceSegmentId, "later-s3")
        let requests = await mock.requests
        assertBudget(requests)
        XCTAssertGreaterThan(requests.count, 2)
        for source in original {
            for change in later {
                XCTAssertTrue(requests.contains { $0.user.contains(source.text) && $0.user.contains(change.text) }, "Unreviewed pair \(source.id)/\(change.id)")
            }
        }
    }

    func testAmendmentConflictingPagesOrUncertainSourcesCannotCancel() async throws {
        let original = sources(count: 5)
        var later = sources(count: 2)
        later[0].text = "Cancel shipping the release."
        later[1].text = "Ship the release on Monday."
        let mock = ReviewMock { request in
            if request.user.contains("source0") {
                return #"{"effect":"cancelled","sourceSegmentId":"s0","quote":"Cancel shipping the release."}"#
            }
            return #"{"effect":"amended","sourceSegmentId":"s1","quote":"Ship the release on Monday."}"#
        }
        let conflict = try await SummaryVerification.checkAmendment(candidate: "Ship the release", original: original, later: later, model: mock.model)
        XCTAssertEqual(conflict.effect, "uncertain")
        later[0].uncertain = true
        let uncertain = try await SummaryVerification.checkAmendment(candidate: "Ship the release", original: [original[0]], later: [later[0]], model: mock.model)
        XCTAssertEqual(uncertain.effect, "uncertain")
        assertBudget(await mock.requests)
    }

    func testVerifierRejectsQuoteFromOmittedPageEvenIfItExistsElsewhere() async throws {
        let evidence = sources(count: 5)
        let mock = ReviewMock { _ in
            #"{"supported":true,"sourceSegmentId":"s4","quote":"source4","ownerSupported":false,"deadlineSupported":false}"#
        }
        do {
            _ = try await SummaryVerification.checkEvidence(findingWithEvidence("s0"), kind: "task", evidence: evidence, model: mock.model)
            XCTFail("A quote outside the current page must be retried and then rejected")
        } catch {}
        let requests = await mock.requests
        XCTAssertEqual(requests.count, 2)
        assertBudget(requests)
    }
}

