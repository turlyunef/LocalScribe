import XCTest
@testable import LocalScribeCore

private actor SummaryPassLog {
    var passes: [SummaryExtractionPass] = []
    func append(_ pass: SummaryExtractionPass) { passes.append(pass) }
}

private actor QuestionPassLog {
    var passes: [SummaryQuestionPass] = []
    func append(_ pass: SummaryQuestionPass) { passes.append(pass) }
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

    private func questionFixture(ending: String) async throws -> (Transcript, Summary) {
        let segments = [
            Segment(id: "budget-question", startMs: 0, endMs: 1000, text: "Какой бюджет запуска? Пока не определили.", language: "ru"),
            Segment(id: "other-topic", startMs: 1000, endMs: 2000, text: "Теперь обсудим дизайн.", language: "ru"),
            Segment(id: "more-context", startMs: 2000, endMs: 3000, text: "С макетами разберёмся отдельно.", language: "ru"),
            Segment(id: "ending", startMs: 3000, endMs: 4000, text: ending, language: "ru")
        ]
        let groups = try SummarySource.groups(segments, tokenCounts: [4, 4, 4, 4], limit: 10)
        XCTAssertEqual(groups.map { $0.map(\.id) }, [
            ["budget-question", "other-topic"], ["other-topic", "more-context"], ["more-context", "ending"]
        ])
        var ledger = Summary(language: "ru")
        for group in groups {
            let extracted = try await SummaryExtraction.extract(group, language: "ru") { pass in
                guard pass.section == .openQuestions, pass.focusSegmentIds.contains("budget-question") else { return Summary(language: "ru") }
                return Summary(language: "ru", openQuestions: [Finding(id: "q", text: "Какой бюджет запуска?", evidenceSegmentIds: ["budget-question"])])
            }
            ledger.openQuestions += extracted.openQuestions
        }
        XCTAssertEqual(ledger.openQuestions.count, 1)
        return (Transcript(fingerprint: "fixture", diarized: false, segments: segments), ledger)
    }

    func testQuestionFromFirstExtractionGroupIsClosedByAnswerInThirdGroupOutsideOverlap() async throws {
        let (transcript, extracted) = try await questionFixture(ending: "Бюджет запуска утверждён: сто тысяч рублей.")
        let log = QuestionPassLog()
        var final = extracted
        final.openQuestions = try await SummaryQuestionResolution.unresolved(extracted.openQuestions, transcript: transcript,
            tokenCounts: [4, 4, 4, 4], limit: 10) { pass in
            await log.append(pass)
            if let answer = pass.later.first(where: { $0.id == "ending" }) {
                return SummaryQuestionVerdict(effect: .resolved, sourceSegmentId: answer.id, quote: answer.text)
            }
            return SummaryQuestionVerdict(effect: .none)
        }
        XCTAssertTrue(final.openQuestions.isEmpty)
        let passes = await log.passes
        XCTAssertEqual(passes.map { $0.later.map(\.id) }, [["other-topic", "more-context"], ["more-context", "ending"]])
        XCTAssertTrue(passes.allSatisfy { $0.question == extracted.openQuestions[0] })
        XCTAssertFalse(passes[0].original.contains { $0.id == "ending" })
        try final.validate(against: transcript)
    }

    func testQuestionRemainsWithoutAnswerOrWithAnswerToDifferentQuestion() async throws {
        for ending in ["На этом закончим встречу.", "Бюджет дизайна утверждён: пять тысяч рублей."] {
            let (transcript, extracted) = try await questionFixture(ending: ending)
            let log = QuestionPassLog()
            let unresolved = try await SummaryQuestionResolution.unresolved(extracted.openQuestions, transcript: transcript,
                tokenCounts: [4, 4, 4, 4], limit: 10) { pass in
                await log.append(pass)
                // Deterministic semantic fixture: neither speech settles the launch budget.
                return SummaryQuestionVerdict(effect: .none)
            }
            XCTAssertEqual(unresolved, extracted.openQuestions)
            let passes = await log.passes
            XCTAssertEqual(Set(passes.flatMap { $0.later.map(\.id) }), Set(transcript.segments.dropFirst().map(\.id)))
        }
    }

    func testAmbiguousLateAnswerKeepsQuestionAndItsUncertaintyEvidence() async throws {
        let (transcript, extracted) = try await questionFixture(ending: "Возможно, на запуск выделим сто тысяч, но это ещё не точно.")
        let unresolved = try await SummaryQuestionResolution.unresolved(extracted.openQuestions, transcript: transcript,
            tokenCounts: [4, 4, 4, 4], limit: 10) { pass in
            guard let answer = pass.later.first(where: { $0.id == "ending" }) else { return SummaryQuestionVerdict(effect: .none) }
            return SummaryQuestionVerdict(effect: .uncertain, sourceSegmentId: answer.id, quote: answer.text)
        }
        XCTAssertEqual(unresolved.count, 1)
        XCTAssertEqual(unresolved.first?.text, extracted.openQuestions.first?.text)
        XCTAssertEqual(unresolved.first?.evidenceSegmentIds, ["budget-question", "ending"])
        XCTAssertEqual(unresolved.first?.uncertain, true)
        try Summary(language: "ru", openQuestions: unresolved).validate(against: transcript)
    }

    func testQuestionVerdictsRequireExactLaterQuoteIncludingAfterCheckpointRoundTrip() throws {
        let later = [Segment(id: "answer", startMs: 1000, endMs: 2000, text: "He said: “The budget is approved.”", language: "en")]
        let valid = SummaryQuestionVerdict(effect: .resolved, sourceSegmentId: "answer", quote: "\"The budget is approved.\"")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("verdict.json")
        try Disk.write(valid.validated(later: later), to: path)
        let resumed = try Disk.read(SummaryQuestionVerdict.self, at: path).validated(later: later)
        XCTAssertEqual(resumed.effect, .resolved)
        XCTAssertEqual(resumed.sourceSegmentId, "answer")
        XCTAssertEqual(resumed.quote, "“The budget is approved.”")
        for invalid in [
            SummaryQuestionVerdict(effect: .resolved, sourceSegmentId: "original-question", quote: "The budget is approved."),
            SummaryQuestionVerdict(effect: .resolved, sourceSegmentId: "answer", quote: "The launch is cancelled."),
            SummaryQuestionVerdict(effect: .resolved, sourceSegmentId: "answer", quote: " "),
            SummaryQuestionVerdict(effect: .resolved),
            SummaryQuestionVerdict(effect: .uncertain, sourceSegmentId: "answer", quote: "invented"),
            SummaryQuestionVerdict(effect: .none, sourceSegmentId: "answer", quote: "The budget is approved.")
        ] {
            try Disk.write(invalid, to: path)
            XCTAssertThrowsError(try Disk.read(SummaryQuestionVerdict.self, at: path).validated(later: later))
        }
        XCTAssertThrowsError(try resumed.validated(later: []))
    }

    func testUncertainSourceCannotCloseQuestionAndLastTurnQuestionNeedsNoReview() async throws {
        let (source, extracted) = try await questionFixture(ending: "Бюджет запуска утверждён: сто тысяч рублей.")
        var transcript = source
        transcript.segments[3].uncertain = true
        let unresolved = try await SummaryQuestionResolution.unresolved(extracted.openQuestions, transcript: transcript,
            tokenCounts: [4, 4, 4, 4], limit: 10) { pass in
            guard let answer = pass.later.first(where: { $0.id == "ending" }) else { return SummaryQuestionVerdict(effect: .none) }
            return SummaryQuestionVerdict(effect: .resolved, sourceSegmentId: answer.id, quote: answer.text)
        }
        XCTAssertEqual(unresolved.count, 1)
        XCTAssertEqual(unresolved.first?.uncertain, true)
        let lastQuestion = Finding(id: "last", text: "Остался вопрос", evidenceSegmentIds: ["ending"], uncertain: true)
        let last = try await SummaryQuestionResolution.unresolved([lastQuestion], transcript: transcript, tokenCounts: [4, 4, 4, 4], limit: 10) { _ in
            XCTFail("There is no later speech to review")
            return SummaryQuestionVerdict(effect: .none)
        }
        XCTAssertEqual(last, [lastQuestion])
    }
}
