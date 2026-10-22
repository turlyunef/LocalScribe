import XCTest
import LocalScribeCore
@testable import LocalScribeWorker

final class ASRWordRepairTests: XCTestCase {
    private func segment(_ entries: [(String, Int, Int)], uncertain: Bool = true, id: String = "fixture") -> Segment {
        let words = entries.map { Word(text: $0.0, startMs: $0.1, endMs: $0.2) }
        return Segment(id: id, startMs: entries.first?.1 ?? 0, endMs: entries.last?.2 ?? 0,
            speakerId: "speaker", text: words.map(\.text).joined(), language: "ru", uncertain: uncertain, words: words)
    }

    private func words(_ texts: [String], uncertain: Bool = true) -> Segment {
        segment(texts.enumerated().map { index, text in
            (index == 0 ? text : " " + text, 1000 + index * 500, 1500 + index * 500)
        }, uncertain: uncertain)
    }

    func testAnchoredSubstitutionKeepsMetadataPunctuationAndClearsChangedWordTimings() {
        let original = words(["мы", "🎓-ошпибка,", "готовы"])
        let candidate = words(["мы", "ошибка", "готовы"], uncertain: false)
        let repaired = ASRWordRepair.propose(original: [original], candidate: [candidate], startMs: 0, endMs: 10000)
        XCTAssertEqual(repaired.edits.count, 1)
        XCTAssertEqual(repaired.proposed.first?.text, "мы 🎓-ошибка, готовы")
        XCTAssertEqual(repaired.proposed.first?.id, original.id)
        XCTAssertEqual(repaired.proposed.first?.speakerId, original.speakerId)
        XCTAssertEqual(repaired.proposed.first?.startMs, original.startMs)
        XCTAssertEqual(repaired.proposed.first?.endMs, original.endMs)
        XCTAssertEqual(repaired.proposed.first?.words, [])
        XCTAssertEqual(repaired.proposed.first?.uncertain, true)
        XCTAssertEqual(original.words[1].text, " 🎓-ошпибка,")
    }

    func testEmptyOrShorterCandidateCannotDeleteOriginalWords() {
        let original = words(["мы", "отправили", "платёжку", "вендору", "доки"])
        for candidate in [[], [segment([("мы", 1000, 1500), (" доки", 3000, 3500)], uncertain: false)]] {
            let result = ASRWordRepair.propose(original: [original], candidate: candidate, startMs: 0, endMs: 10000)
            XCTAssertEqual(result.proposed, [original])
            XCTAssertTrue(result.edits.isEmpty)
        }
    }

    func testLocalSubstitutionPreservesUnmatchedWordsAndOtherSegmentAlignment() {
        let original = words(["мы", "платёжка", "или", "вендору", "доки"])
        let unchanged = segment([(" дальше", 4000, 4500)], uncertain: false, id: "next")
        let candidate = segment([("мы", 1000, 1500), (" платёжку", 1500, 2000),
            (" вендору", 2500, 3000), (" доки", 3000, 3500), (" дальше", 4000, 4500)], uncertain: false)
        let result = ASRWordRepair.propose(original: [original, unchanged], candidate: [candidate], startMs: 0, endMs: 10000)
        XCTAssertEqual(result.proposed.map(\.text), ["мы платёжку или вендору доки", " дальше"])
        XCTAssertEqual(result.proposed[1], unchanged)
        XCTAssertTrue(result.issues.contains(.preservedDeletion))
        XCTAssertEqual(result.edits.count, 1)
    }

    func testNegationNumbersAndAddedWordsAreProtected() {
        for pair in [(["мы", "не", "готовы"], ["мы", "уже", "готовы"]),
                     (["мы", "готовы", "да"], ["мы", "не", "да"]),
                     (["будет", "42", "задачи"], ["будет", "43", "задачи"])] {
            let original = words(pair.0)
            let result = ASRWordRepair.propose(original: [original], candidate: [words(pair.1, uncertain: false)], startMs: 0, endMs: 10000)
            XCTAssertEqual(result.proposed, [original])
            XCTAssertTrue(result.edits.isEmpty)
            XCTAssertTrue(result.issues.contains(.protectedToken))
        }
        let original = words(["мы", "готовы"])
        let candidate = segment([("мы", 1000, 1500), (" не", 1500, 1600), (" готовы", 1600, 2000)], uncertain: false)
        let result = ASRWordRepair.propose(original: [original], candidate: [candidate], startMs: 0, endMs: 10000)
        XCTAssertEqual(result.proposed, [original])
        XCTAssertTrue(result.issues.contains(.ignoredInsertion))
    }

    func testCrossingWordIsMarkedAndNotDeletedAsNoise() {
        let original = segment([(" винт", 19540, 21840)])
        let candidate = segment([(" гендер", 20035, 21915)], uncertain: false)
        let result = ASRWordRepair.propose(original: [original], candidate: [candidate], startMs: 20000, endMs: 21150)
        XCTAssertEqual(result.proposed, [original])
        XCTAssertTrue(result.issues.contains(.boundaryCrossing))
        XCTAssertTrue(result.edits.isEmpty)
    }

    func testUnstableTimingUncertainCandidateAndDifferentScriptDoNotReplaceWords() {
        let original = words(["мы", "ошпибка", "готовы"])
        let variants = [words(["мы", "ошибка", "готовы"], uncertain: true),
            words(["мы", "error", "готовы"], uncertain: false),
            segment([("мы", 1000, 1500), (" ошибка", 1900, 2200), (" готовы", 2200, 2500)], uncertain: false)]
        for candidate in variants {
            let result = ASRWordRepair.propose(original: [original], candidate: [candidate], startMs: 0, endMs: 10000)
            XCTAssertEqual(result.proposed, [original])
            XCTAssertTrue(result.edits.isEmpty)
        }
        let healthy = words(["мы", "ошпибка", "готовы"], uncertain: false)
        let confident = words(["мы", "ошибка", "готовы"], uncertain: false)
        XCTAssertEqual(ASRWordRepair.propose(original: [healthy], candidate: [confident], startMs: 0, endMs: 10000).proposed, [healthy])
    }

    func testTwoCandidateWordsCannotOverwriteOneOriginalSlot() {
        let original = segment([("мы", 1000, 1500), (" слово", 1500, 2500), (" готовы", 2500, 3000)])
        let candidate = segment([("мы", 1000, 1500), (" новое", 1500, 2100),
            (" другое", 1900, 2500), (" готовы", 2500, 3000)], uncertain: false)
        let result = ASRWordRepair.propose(original: [original], candidate: [candidate], startMs: 0, endMs: 10000)
        XCTAssertEqual(result.proposed, [original])
        XCTAssertTrue(result.edits.isEmpty)
        XCTAssertTrue(result.issues.contains(.ambiguousTiming))
    }

    func testEdgeWordsAndBroadDifferencesArePreserved() {
        let original = words(["ошпибка", "раз", "два", "три", "четыре", "пять", "конец", "хвост"])
        let candidate = words(["ошибка", "раз", "a", "b", "c", "d", "конец", "tail"], uncertain: false)
        let result = ASRWordRepair.propose(original: [original], candidate: [candidate], startMs: 0, endMs: 10000)
        XCTAssertEqual(result.proposed, [original])
        XCTAssertTrue(result.issues.contains(.edgeDifference))
        XCTAssertTrue(result.issues.contains(.broadDifference))
    }

    func testMissingTimingsAndOversizedInputAreBounded() {
        let original = words(["мы", "ошпибка", "готовы"])
        var missing = words(["мы", "ошибка", "готовы"], uncertain: false)
        missing.words = []
        XCTAssertEqual(ASRWordRepair.propose(original: [original], candidate: [missing], startMs: 0, endMs: 10000).issues, [.missingWordTimings])
        let large = words(Array(repeating: "word", count: 257))
        let result = ASRWordRepair.propose(original: [large], candidate: [large], startMs: 0, endMs: 200000)
        XCTAssertEqual(result.proposed, [large])
        XCTAssertEqual(result.issues, [.inputTooLarge])
    }

    func testOverlappingDuplicateAndNonMonotonicTimesAreFlagged() {
        let original = segment([("мы", 1000, 1600), (" мы", 1400, 1900), (" готовы", 2000, 2500)])
        let same = ASRWordRepair.propose(original: [original], candidate: [original], startMs: 0, endMs: 10000)
        XCTAssertEqual(same.proposed, [original])
        XCTAssertTrue(same.issues.contains(.overlappingDuplicate))
        var reversed = original
        reversed.words.reverse(); reversed.text = reversed.words.map(\.text).joined()
        let result = ASRWordRepair.propose(original: [original], candidate: [reversed], startMs: 0, endMs: 10000)
        XCTAssertEqual(result.proposed, [original])
        XCTAssertTrue(result.issues.contains(.nonMonotonicTimings))
    }

    func testEnglishRepairAndUnchangedText() {
        let original = words(["please", "chek", "endpoint"])
        let result = ASRWordRepair.propose(original: [original], candidate: [words(["please", "check", "endpoint"], uncertain: false)], startMs: 0, endMs: 10000)
        XCTAssertEqual(result.proposed.first?.text, "please check endpoint")
        let same = ASRWordRepair.propose(original: [original], candidate: [original], startMs: 0, endMs: 10000)
        XCTAssertEqual(same.proposed, [original])
        XCTAssertTrue(same.edits.isEmpty)
    }

    func testRepeatedPhraseAtAnotherTimeCannotSupplyMissingAnchors() {
        let original = segment([("мы", 1000, 1500), (" ошпибка", 1500, 2000), (" готовы", 2000, 2500)])
        let later = segment([("мы", 10000, 10500), (" ошибка", 10500, 11000), (" готовы", 11000, 11500)], uncertain: false)
        let result = ASRWordRepair.propose(original: [original], candidate: [later], startMs: 0, endMs: 12000)
        XCTAssertEqual(result.proposed, [original])
        XCTAssertTrue(result.edits.isEmpty)
        XCTAssertTrue(result.issues.contains(.noAnchors))
    }

    func testCrossingCandidateCannotInsertSecondCopyBeforeRetainedBoundaryWord() {
        // Timing shape reproduced by the disclosed whole-repeat seam regression.
        let retained = segment([("word", 577290, 577890)])
        let candidate = segment([("word", 575430, 577890)], uncertain: false)
        let original = ASRContextReviewPlanner.ownedSegments([retained], startMs: 575290, endMs: 577290)
        XCTAssertTrue(original.isEmpty)
        let repair = ASRWordRepair.propose(original: original, candidate: [candidate], startMs: 575290, endMs: 577290)
        XCTAssertTrue(repair.proposed.isEmpty)
        XCTAssertTrue(repair.edits.isEmpty)
        XCTAssertTrue(repair.issues.contains(.boundaryCrossing))
        XCTAssertEqual(retained.words.count, 1)
    }
}
