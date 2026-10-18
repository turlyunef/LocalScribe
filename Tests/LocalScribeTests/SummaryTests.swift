import XCTest
@testable import LocalScribeCore

private actor SummaryPassLog {
    var passes: [SummaryExtractionPass] = []
    func append(_ pass: SummaryExtractionPass) { passes.append(pass) }
}

final class SummaryTests: XCTestCase {
    private var conversation: [Segment] {
        [Segment(id: "proposal", startMs: 0, endMs: 1000, speakerId: "speaker-1", text: "Предлагаю перенести запуск на пятницу.", language: "ru"),
         Segment(id: "acceptance", startMs: 1000, endMs: 2000, speakerId: "speaker-2", text: "Yes, agreed. I will notify the team.", language: "en"),
         Segment(id: "question", startMs: 2000, endMs: 3000, speakerId: "speaker-1", text: "Бюджет пока не определили, вернёмся к нему позже.", language: "ru", uncertain: true)]
    }

    func testOverviewCoverageStillReviewsEverySectionAndKeepsCrossLanguageContext() async throws {
        let segments = conversation, log = SummaryPassLog()
        let decision = Finding(id: "d", text: "Перенести запуск на пятницу", evidenceSegmentIds: ["proposal", "acceptance"])
        let task = Finding(id: "t", text: "Уведомить команду", evidenceSegmentIds: ["acceptance"], ownerSpeakerId: "speaker-2")
        let question = Finding(id: "q", text: "Определить бюджет", evidenceSegmentIds: ["question"], uncertain: true)
        let result = try await SummaryExtraction.extract(segments, language: "ru") { pass in
            await log.append(pass)
            switch (pass.section, pass.spokenLanguage) {
            case (.overview, "ru"):
                // Overview already cites EVERY source turn. Extraction must still
                // request decisions/tasks/questions rather than treating them as covered.
                return Summary(language: "ru", overview: [Finding(id: "topic", text: "Обсудили запуск и бюджет",
                    evidenceSegmentIds: segments.map(\.id), uncertain: true)])
            case (.decisions, "ru"): return Summary(language: "ru", decisions: [decision])
            case (.tasks, "en"): return Summary(language: "ru", tasks: [task])
            case (.openQuestions, "ru"): return Summary(language: "ru", openQuestions: [question])
            default: return Summary(language: "ru")
            }
        }
        XCTAssertEqual(result.overview.count, 1)
        XCTAssertEqual(result.decisions, [decision])
        XCTAssertEqual(result.tasks, [task])
        XCTAssertEqual(result.openQuestions, [question])
        let passes = await log.passes
        for section in SummarySection.allCases {
            XCTAssertEqual(passes.filter { $0.section == section }.map(\.spokenLanguage), ["ru", "en"])
        }
        XCTAssertTrue(passes.allSatisfy { $0.segments.map(\.id) == segments.map(\.id) })
        XCTAssertEqual(passes.first { $0.spokenLanguage == "en" }?.focusSegmentIds, ["acceptance"])
        try result.validate(against: Transcript(fingerprint: "f", diarized: true, segments: segments))
    }

    func testSectionResponseRequiresRequestedArrayAndCompletesOtherSections() throws {
        let data = Data(#"{"schemaVersion":1,"language":"ru","tasks":[{"id":"t","text":"Отправить план","evidenceSegmentIds":["acceptance"],"uncertain":false}]}"#.utf8)
        let result = try SummarySection.tasks.decodeResponse(data)
        XCTAssertEqual(result.tasks.first?.text, "Отправить план")
        XCTAssertTrue(result.overview.isEmpty)
        XCTAssertTrue(result.decisions.isEmpty)
        XCTAssertTrue(result.openQuestions.isEmpty)
        XCTAssertThrowsError(try SummarySection.overview.decodeResponse(data))
        XCTAssertThrowsError(try SummarySection.tasks.decodeResponse(Data(#"{"schemaVersion":1,"language":"ru","findings":[]}"#.utf8)))
        XCTAssertThrowsError(try SummarySection.tasks.decodeResponse(Data(#"{"schemaVersion":1,"language":"ru","tasks":"нет"}"#.utf8)))
    }

    func testChunkBoundaryKeepsProposalWithAcceptanceInAnotherLanguage() throws {
        let filler = Segment(id: "filler", startMs: 0, endMs: 1000, text: "Перейдём к плану выпуска.", language: "ru")
        let segments = [filler] + conversation
        let groups = try SummarySource.groups(segments, tokenCounts: [7, 3, 3, 4], limit: 10)
        XCTAssertEqual(groups.map { $0.map(\.id) }, [["filler", "proposal"], ["proposal", "acceptance", "question"]])
        XCTAssertEqual(groups[1].map(\.language), ["ru", "en", "ru"])
        XCTAssertEqual(Set(groups.flatMap { $0.map(\.id) }), Set(segments.map(\.id)))
        XCTAssertTrue(try SummarySource.groups([], tokenCounts: []).isEmpty)
        XCTAssertThrowsError(try SummarySource.groups(segments, tokenCounts: [7, 3, 3, 10], limit: 10))
    }

    func testVerificationUsesNeighboursAndPreservesNewEvidenceAndUncertainty() throws {
        var segments = conversation
        segments[0].uncertain = true
        let transcript = Transcript(fingerprint: "f", diarized: true, segments: segments)
        let finding = Finding(id: "d", text: "Перенести запуск на пятницу", evidenceSegmentIds: ["acceptance"], ownerName: "Иван", dueText: "завтра")
        let context = SummarySource.evidenceContext(for: finding, in: transcript)
        XCTAssertEqual(context.map(\.id), ["proposal", "acceptance", "question"])
        let verdict = SummaryEvidenceVerdict(supported: true, sourceSegmentId: "proposal", quote: "перенести запуск на пятницу")
        let result = try XCTUnwrap(verdict.applying(to: finding, context: context))
        XCTAssertEqual(result.evidenceSegmentIds, ["acceptance", "proposal"])
        XCTAssertTrue(result.uncertain)
        XCTAssertNil(result.ownerName)
        XCTAssertNil(result.dueText)
        try Summary(language: "ru", decisions: [result]).validate(against: transcript)
    }

    func testEvidenceRestoresSourceQuoteGlyphsWithoutAcceptingChangedWords() throws {
        let text = "She said: “Yes, let’s do that.”"
        XCTAssertEqual(SummarySource.verbatimQuote("Yes, let's do that.", in: text), "Yes, let’s do that.")
        XCTAssertEqual(SummarySource.verbatimQuote("\"Yes, let's do that.\"", in: text), "“Yes, let’s do that.”")
        XCTAssertNil(SummarySource.verbatimQuote("Yes, let's cancel that.", in: text))
        XCTAssertNil(SummarySource.verbatimQuote(" ", in: text))
        let source = Segment(id: "s", startMs: 0, endMs: 1000, text: text, language: "en")
        let finding = Finding(id: "d", text: "Выпустить обновление", evidenceSegmentIds: ["s"])
        let verdict = SummaryEvidenceVerdict(supported: true, sourceSegmentId: "s", quote: "Yes, let's do that.")
        XCTAssertNotNil(try verdict.applying(to: finding, context: [source]))
    }

    func testVerificationRejectsInventedQuotes() throws {
        let segments = conversation
        let finding = Finding(id: "d", text: "Перенести запуск на пятницу", evidenceSegmentIds: ["acceptance"])
        let accepted = SummaryEvidenceVerdict(supported: true, sourceSegmentId: "proposal", quote: "перенести запуск на пятницу")
        let result = try XCTUnwrap(accepted.applying(to: finding, context: segments))
        XCTAssertEqual(result.evidenceSegmentIds, ["acceptance", "proposal"])
        XCTAssertThrowsError(try accepted.applying(to: finding, context: [segments[1]]))
        let invented = SummaryEvidenceVerdict(supported: true, sourceSegmentId: "proposal", quote: "Запуск отменён")
        XCTAssertThrowsError(try invented.applying(to: finding, context: segments))
        XCTAssertNil(try SummaryEvidenceVerdict(supported: false).applying(to: finding, context: segments))
    }

    func testEmptyExtractionDoesNotInventDecisionsTasksOrQuestions() async throws {
        let segments = [Segment(id: "fact", startMs: 0, endMs: 1000, text: "У меня есть дочь, сейчас я в декрете.", language: "ru")]
        let result = try await SummaryExtraction.extract(segments, language: "ru") { pass in
            if pass.section == .overview {
                return Summary(language: "ru", overview: [Finding(id: "f", text: "У участника есть дочь; сейчас он в декрете.", evidenceSegmentIds: ["fact"])])
            }
            return Summary(language: "ru")
        }
        XCTAssertEqual(result.overview.count, 1)
        XCTAssertTrue(result.decisions.isEmpty)
        XCTAssertTrue(result.tasks.isEmpty)
        XCTAssertTrue(result.openQuestions.isEmpty)
    }
}
