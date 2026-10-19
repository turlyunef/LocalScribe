import XCTest
import LocalScribeCore
@testable import LocalScribeWorker

private actor SourceTokenLog {
    var lines: [String] = []
    let counts: [String: Int]
    init(segments: [Segment], counts: [Int]) {
        self.counts = Dictionary(uniqueKeysWithValues: zip(segments.map(legacySourceLine), counts))
    }
    func count(_ line: String) -> Int {
        lines.append(line)
        return counts[line] ?? 0
    }
}

private func legacySourceLine(_ s: Segment) -> String {
    "[\(s.id) \(timecode(s.startMs)) \(s.speakerId ?? "unknown") uncertain=\(s.uncertain)] \(s.text)"
}

private actor EngineReviewLog {
    var requests: [SummaryReviewRequest] = []
    let response: @Sendable (SummaryReviewRequest) throws -> String
    init(_ response: @escaping @Sendable (SummaryReviewRequest) throws -> String) { self.response = response }
    func complete(_ request: SummaryReviewRequest) throws -> String {
        requests.append(request)
        return try response(request)
    }
    nonisolated var model: SummaryReviewModel {
        SummaryReviewModel(tokenCount: { _ in 1000 }, complete: { try await self.complete($0) })
    }
}

private struct SavedAmendment: Decodable {
    let fingerprint: String
    let result: SummaryAmendmentVerdict
}
private struct SavedSummary: Decodable {
    let fingerprint: String
    let summary: Summary
}

private enum UnexpectedSummaryCall: Error { case review, amendment }

@MainActor
final class SummaryEngineTests: XCTestCase {
    func testModelLoadFailureResetsMetricsWithoutPublishingSummaryOrSDKError() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var oldMetrics = SummaryMetrics()
        oldMetrics.status = "completed"
        oldMetrics.update(.tasks) { $0.requests = 99; $0.outputTokens = 9000 }
        try Disk.write(oldMetrics, to: root.appendingPathComponent("metrics-summary.json"))
        let modelFolder = root.appendingPathComponent("private-model-path-must-not-be-logged")
        let engine = SummaryEngine(modelFolder: modelFolder, run: root) { _, _, _ in }
        do {
            try await engine.summarize(transcript(), language: "en")
            XCTFail("Missing local model must fail")
        } catch { }
        let metrics = try Disk.read(SummaryMetrics.self, at: root.appendingPathComponent("metrics-summary.json"))
        XCTAssertEqual(metrics.status, "failed")
        XCTAssertTrue(metrics.phases.isEmpty, "A new invocation must not accumulate previous requests")
        XCTAssertGreaterThanOrEqual(metrics.elapsedSeconds, metrics.modelLoadSeconds)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("summary.json").path))
        let json = try String(contentsOf: root.appendingPathComponent("metrics-summary.json"), encoding: .utf8)
        XCTAssertFalse(json.contains("private-model-path"))
        XCTAssertFalse(json.contains("I will check item"))
    }

    private func transcript(count: Int = 8) -> Transcript {
        Transcript(fingerprint: "fixture", diarized: true, segments: (0..<count).map { index in
            Segment(id: "s\(index)", startMs: index * 1000, endMs: (index + 1) * 1000,
                    speakerId: index % 2 == 0 ? "speaker-1" : nil,
                    text: "I will check item \(index).", language: "en")
        })
    }

    private func supported(_ id: Int) -> String {
        "{\"supported\":true,\"sourceSegmentId\":\"s\(id)\",\"quote\":\"I will check item \(id).\",\"ownerSupported\":false,\"deadlineSupported\":false}"
    }

    private func verify(_ engine: SummaryEngine, _ findings: [Finding], kind: String = "task", source: SummarySourceIndex,
                        model: SummaryReviewModel) async throws -> [Finding] {
        return try await engine.verify(findings, kind: kind, source: source, model: model, language: "en", sourceHash: "source-hash") { _ in
            throw UnexpectedSummaryCall.amendment
        }
    }

    func testPreparedLinesCountsIndexesAndLegacyBoundaries() async throws {
        var transcript = transcript(count: 11)
        transcript.segments[3].uncertain = true
        transcript.segments[3].text = "Да, проверю.\nKeep Unicode: ’ 👩🏽‍💻"
        transcript.segments[10].startMs = 3_661_999
        transcript.segments[10].endMs = 3_662_000
        let counts = [350, 500, 700, 1, 1199, 1200, 1201, 20, 100, 100, 100]
        let log = SourceTokenLog(segments: transcript.segments, counts: counts)
        let source = await SummarySourceIndex(transcript) { await log.count($0) }
        XCTAssertEqual(source.lines, transcript.segments.map(legacySourceLine))
        XCTAssertEqual(source.tokenCounts, counts)
        XCTAssertEqual(source.indexByID["s10"], 10)
        XCTAssertEqual(source.lines[10], "[s10 01:01:01 speaker-1 uncertain=false] I will check item 10.")
        let finding = Finding(id: "t", text: "Check items", evidenceSegmentIds: ["s0"])
        XCTAssertEqual(source.laterGroups(after: finding).map { $0.map(\.id) },
                       [["s1", "s2"], ["s3", "s4"], ["s5"], ["s6"], ["s7", "s8", "s9", "s10"]])
        // Multiple distant IDs, repeated IDs and input order must retain the old
        // chronological two-neighbour context and start after the LAST evidence.
        let distant = Finding(id: "d", text: "Check items", evidenceSegmentIds: ["s7", "s1", "s7"])
        let oldEvidence = SummarySource.evidenceContext(for: distant, in: transcript)
        XCTAssertEqual(source.evidenceContext(for: distant), oldEvidence)
        XCTAssertEqual(source.context(oldEvidence), oldEvidence.map(legacySourceLine).joined(separator: "\n"))
        XCTAssertEqual(source.laterGroups(after: distant).map { $0.map(\.id) }, [["s8", "s9", "s10"]])
        let last = Finding(id: "last", text: "Check items", evidenceSegmentIds: ["s10"])
        XCTAssertTrue(source.laterGroups(after: last).isEmpty)
        XCTAssertEqual(try SummarySource.groups(transcript.segments, tokenCounts: source.tokenCounts),
                       try SummarySource.groups(transcript.segments, tokenCounts: counts))
        let calls = await log.lines
        XCTAssertEqual(calls, source.lines, "Grouping and context rendering must never retokenize a source line")
        let empty = await SummarySourceIndex(Transcript(fingerprint: "empty", diarized: false, segments: [])) { _ in
            XCTFail("Empty source must not invoke the tokenizer"); return 1
        }
        XCTAssertTrue(empty.lines.isEmpty)
        XCTAssertTrue(empty.laterGroups(after: finding).isEmpty)
    }

    func testDefaultEncoderWritesCanonicalCheckpointsAndReusesThem() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = await SummarySourceIndex(transcript(count: 2)) { _ in 100 }
        let finding = Finding(id: "t", text: "Check item 0", evidenceSegmentIds: ["s0"])
        let positive = supported(0)
        let model = EngineReviewLog { request in
            request.purpose == .evidence ? positive : #"{"effect":"none","sourceSegmentId":null,"quote":null}"#
        }
        let first = SummaryEngine(modelFolder: root, run: root) { _, _, _ in }
        _ = try await first.verify([finding], kind: "task", source: source, model: model.model, language: "en", sourceHash: "fixture") { _ in
            throw UnexpectedSummaryCall.amendment
        }
        // Repeating within one process can hide process-seeded JSON key ordering.
        // Require canonical fingerprints as well as reuse within this process.
        let canonical = JSONEncoder(); canonical.outputFormatting = [.sortedKeys]
        let encoded = String(decoding: try canonical.encode(finding), as: UTF8.self)
        let context = source.context(source.evidenceContext(for: finding))
        let saved = try Disk.read(SavedSummary.self, at: root.appendingPathComponent("summary-parts/verify-task-0.json"))
        XCTAssertEqual(saved.fingerprint, Disk.fingerprint("fixture" + encoded + context + "task"))
        let candidate = String(decoding: try canonical.encode([finding]), as: UTF8.self)
        let later = source.context(source.laterGroups(after: finding)[0])
        let amendment = try Disk.read(SavedAmendment.self, at: root.appendingPathComponent("summary-parts/amend-task-0-0.json"))
        XCTAssertEqual(amendment.fingerprint, Disk.fingerprint("fixture" + candidate + context + later + "task"))
        let paths = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("summary-parts"), includingPropertiesForKeys: nil)
        let original = try paths.map { try Data(contentsOf: $0) }
        let noReviews = EngineReviewLog { _ in throw UnexpectedSummaryCall.review }
        for _ in 0..<5 {
            let resumed = SummaryEngine(modelFolder: root, run: root) { _, _, _ in }
            let result = try await resumed.verify([finding], kind: "task", source: source, model: noReviews.model, language: "en", sourceHash: "fixture") { _ in
                throw UnexpectedSummaryCall.amendment
            }
            XCTAssertEqual(result, [finding])
        }
        let requests = await noReviews.requests
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(try paths.map { try Data(contentsOf: $0) }, original)
    }

    func testRejectedFindingSkipsLaterReviewsAndContinuesToNextFinding() async throws {
        let transcript = transcript()
        let tokens = SourceTokenLog(segments: transcript.segments, counts: Array(repeating: 600, count: 8))
        let source = await SummarySourceIndex(transcript) { await tokens.count($0) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = SummaryEngine(modelFolder: root, run: root) { _, _, _ in }
        let positive = supported(7)
        let mock = EngineReviewLog { request in
            guard request.user.hasPrefix("CANDIDATE:") else { throw UnexpectedSummaryCall.review }
            if request.user.contains("Reject this item") {
                return #"{"supported":false,"sourceSegmentId":null,"quote":null,"ownerSupported":false,"deadlineSupported":false}"#
            }
            return positive
        }
        let accepted = Finding(id: "accepted", text: "Check item 7", evidenceSegmentIds: ["s7"])
        let result = try await verify(engine, [Finding(id: "rejected", text: "Reject this item", evidenceSegmentIds: ["s0"]), accepted],
                                      source: source, model: mock.model)
        XCTAssertEqual(result, [accepted])
        let requests = await mock.requests
        XCTAssertEqual(requests.count, 2)
        let calls = await tokens.lines
        XCTAssertEqual(calls, source.lines)
        let paths = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("summary-parts").path)
        XCTAssertEqual(paths.sorted(), ["verify-task-0.json", "verify-task-1.json"])
        let noReviews = EngineReviewLog { _ in throw UnexpectedSummaryCall.review }
        let resumed = try await verify(engine, [Finding(id: "rejected", text: "Reject this item", evidenceSegmentIds: ["s0"]), accepted],
                                       source: source, model: noReviews.model)
        XCTAssertEqual(resumed, [accepted])
        let resumedCalls = await tokens.lines
        XCTAssertEqual(resumedCalls, source.lines)
    }

    func testAddedEvidenceMovesTailStartAndCancellationStopsRemainingChecks() async throws {
        var transcript = transcript()
        transcript.segments[3].text = "Cancel checking item 0."
        let tokens = SourceTokenLog(segments: transcript.segments, counts: Array(repeating: 600, count: 8))
        let source = await SummarySourceIndex(transcript) { await tokens.count($0) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = SummaryEngine(modelFolder: root, run: root) { _, _, _ in }
        let positive = supported(2)
        let mock = EngineReviewLog { request in
            request.user.hasPrefix("CANDIDATE:") ? positive
                : #"{"effect":"cancelled","sourceSegmentId":"s3","quote":"Cancel checking item 0."}"#
        }
        let finding = Finding(id: "t", text: "Check item 0", evidenceSegmentIds: ["s0"])
        let result = try await verify(engine, [finding], source: source, model: mock.model)
        XCTAssertTrue(result.isEmpty)
        let requests = await mock.requests
        XCTAssertEqual(requests.count, 2)
        let later = try XCTUnwrap(requests.last?.user.components(separatedBy: "LATER SOURCE:\n").last)
        XCTAssertTrue(later.hasPrefix("[s3 "))
        XCTAssertTrue(later.contains("[s4 "))
        XCTAssertFalse(later.contains("[s2 "))
        XCTAssertFalse(later.contains("[s5 "))
        let paths = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("summary-parts").path)
        XCTAssertEqual(paths.sorted(), ["amend-task-0-0.json", "verify-task-0.json"])
        let calls = await tokens.lines
        XCTAssertEqual(calls, source.lines)
    }

    func testMultipleFindingsReuseCountsAndResumeAmendmentCheckpoints() async throws {
        let transcript = transcript()
        let tokens = SourceTokenLog(segments: transcript.segments, counts: Array(repeating: 600, count: 8))
        let source = await SummarySourceIndex(transcript) { await tokens.count($0) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = SummaryEngine(modelFolder: root, run: root) { _, _, _ in }
        let positive = supported(0)
        let mock = EngineReviewLog { request in
            request.user.hasPrefix("CANDIDATE:") ? positive : #"{"effect":"none","sourceSegmentId":null,"quote":null}"#
        }
        let findings = [Finding(id: "a", text: "Check first item", evidenceSegmentIds: ["s0"]),
                        Finding(id: "b", text: "Review first item", evidenceSegmentIds: ["s0"])]
        let tasks = try await verify(engine, findings, source: source, model: mock.model)
        let decisions = try await verify(engine, [findings[0]], kind: "decision", source: source, model: mock.model)
        XCTAssertEqual(tasks, findings)
        XCTAssertEqual(decisions, [findings[0]])
        let requests = await mock.requests
        XCTAssertEqual(requests.count, 15, "Each accepted finding still needs evidence plus all four amendment checks")
        let amendments = requests.filter { $0.user.hasPrefix("VERIFIED COMMITMENT:") }
        XCTAssertEqual(amendments.count, 12)
        let legacyGroups = [[1, 2], [3, 4], [5, 6], [7]]
        let legacyEvidence = SummarySource.evidenceContext(for: findings[0], in: transcript)
        for (index, request) in amendments.enumerated() {
            let groupIndex = index % 4
            let group = legacyGroups[groupIndex].map { transcript.segments[$0] }
            let candidateText = try XCTUnwrap(request.user.components(separatedBy: "VERIFIED COMMITMENT:\n").last?
                .components(separatedBy: "\nORIGINAL EVIDENCE:").first)
            let kind = index < 8 ? "task" : "decision"
            let findingIndex = index < 8 ? index / 4 : 0
            let saved = try Disk.read(SavedAmendment.self, at: root.appendingPathComponent("summary-parts/amend-\(kind)-\(findingIndex)-\(groupIndex).json"))
            let legacyContext = legacyEvidence.map(legacySourceLine).joined(separator: "\n")
            let legacyLater = group.map(legacySourceLine).joined(separator: "\n")
            XCTAssertEqual(saved.fingerprint, Disk.fingerprint("source-hash" + candidateText + legacyContext + legacyLater + kind))
            XCTAssertEqual(saved.result.effect, "none")
            // The old source slices must produce byte-identical model prompts.
            let baseline = EngineReviewLog { _ in #"{"effect":"none","sourceSegmentId":null,"quote":null}"# }
            _ = try await SummaryVerification.checkAmendment(candidate: candidateText, original: legacyEvidence, later: group, model: baseline.model)
            let expected = await baseline.requests
            XCTAssertEqual(expected.count, 1)
            XCTAssertEqual(request.system, expected[0].system)
            XCTAssertEqual(request.user, expected[0].user)
            XCTAssertEqual(request.outputTokens, expected[0].outputTokens)
        }
        let firstCalls = await tokens.lines
        XCTAssertEqual(firstCalls, source.lines)
        let parts = root.appendingPathComponent("summary-parts")
        let paths = try FileManager.default.contentsOfDirectory(at: parts, includingPropertiesForKeys: nil)
        let originalJSON = try Dictionary(uniqueKeysWithValues: paths.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
        // A new invocation prepares each line once, then reads existing reviews without
        // tokenizer work on any finding's suffix or any model completions.
        let resumedSource = await SummarySourceIndex(transcript) { await tokens.count($0) }
        let resumedEngine = SummaryEngine(modelFolder: root, run: root) { _, _, _ in }
        let noReviews = EngineReviewLog { _ in throw UnexpectedSummaryCall.review }
        let resumedTasks = try await verify(resumedEngine, findings, source: resumedSource, model: noReviews.model)
        let resumedDecisions = try await verify(resumedEngine, [findings[0]], kind: "decision", source: resumedSource, model: noReviews.model)
        XCTAssertEqual(resumedTasks, tasks)
        XCTAssertEqual(resumedDecisions, decisions)
        let resumedCalls = await tokens.lines
        XCTAssertEqual(resumedCalls, source.lines + source.lines)
        let unexpected = await noReviews.requests
        XCTAssertTrue(unexpected.isEmpty)
        let resumedJSON = try Dictionary(uniqueKeysWithValues: paths.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
        XCTAssertEqual(resumedJSON, originalJSON)
    }
}
