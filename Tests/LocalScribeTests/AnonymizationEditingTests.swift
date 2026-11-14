import Foundation
import XCTest
import LocalScribeCore

/// The text-edit engine of the anonymization card (plan item 7): editing one
/// panel produces the next versioned document with transformed pairs and
/// warning review positions; the UTF-16 bridge serves the editor boundary.
/// Covers acceptance-criteria rules 29 and 46 and the document consistency
/// after reopening.
final class AnonymizationEditingTests: XCTestCase {

    /// A C constant of the same name in the AE headers competes for bare
    /// `TextRange` lookups in the test module; the typealias pins the domain
    /// type for the whole file.
    private typealias TextRange = LocalScribeCore.TextRange

    // MARK: - Fixtures

    private let source = "Анна позвонила Ивану по номеру +7 999 000-00-00."
    private let substitutes = ["Мария", "Олегу", "+1 555 111-11-11"]
    private let originals = ["Анна", "Ивану", "+7 999 000-00-00"]

    /// Scalar offsets of every occurrence of `fragment` in `text`.
    private func offsets(of fragment: String, in text: String) -> [UInt] {
        let scalars = Array(text.unicodeScalars)
        let needle = Array(fragment.unicodeScalars)
        guard !needle.isEmpty else { return [] }
        var found: [UInt] = []
        var index = 0
        while index + needle.count <= scalars.count {
            if scalars[index..<index + needle.count].elementsEqual(needle) {
                found.append(UInt(index))
                index += needle.count
            } else {
                index += 1
            }
        }
        return found
    }

    private func range(of fragment: String, in text: String, occurrence: Int = 0) throws -> TextRange {
        let found = offsets(of: fragment, in: text)
        return try XCTUnwrap(found.indices.contains(occurrence)
            ? TextRange(start: found[occurrence], end: found[occurrence] + UInt(fragment.unicodeScalars.count))
            : nil, "фрагмент «\(fragment)» не найден в «\(text)»")
    }

    private func replacingScalars(_ text: String, _ fragment: String, _ substitute: String) -> String {
        let scalars = Array(text.unicodeScalars)
        let found = offsets(of: fragment, in: text)
        precondition(found.count == 1)
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars[..<Int(found[0])])
        view.append(contentsOf: substitute.unicodeScalars)
        view.append(contentsOf: scalars[(Int(found[0]) + fragment.unicodeScalars.count)...])
        return String(view)
    }

    /// A freshly published card: source with three replaced fragments plus an
    /// optional doubtful fragment that stays original on both sides.
    private func makeCard(doubtful: String? = nil,
                          extraWarnings: [AnonymizationWarning] = []) throws -> AnonymizationCardDocument {
        var sourceText = source
        var resultText = source
        if let doubtful {
            sourceText = sourceText.replacingOccurrences(of: ".", with: ", возможно \(doubtful).")
            resultText = sourceText
        }
        for (original, substitute) in zip(originals, substitutes) {
            resultText = replacingScalars(resultText, original, substitute)
        }
        var pairs: [ReplacementPair] = []
        for (original, substitute) in zip(originals, substitutes) {
            pairs.append(ReplacementPair(sourceRange: try range(of: original, in: sourceText),
                                         resultRange: try range(of: substitute, in: resultText)))
        }
        var warnings: [AnonymizationWarning] = []
        if let doubtful {
            let inputRange = try range(of: doubtful, in: sourceText)
            let generatedRange = try range(of: doubtful, in: resultText)
            warnings.append(AnonymizationWarning(kind: .doubtfulFragment, target: .body,
                                                 inputRange: inputRange, generatedRange: generatedRange,
                                                 reviewRange: generatedRange))
        }
        warnings.append(contentsOf: extraWarnings)
        let sourceRevision = TextRevision(id: UUID().uuidString, text: sourceText)
        let generated = TextRevision(id: UUID().uuidString, text: resultText)
        let input = RunInput(source: sourceRevision, profileID: "shared-profile",
                             packageID: "shared-package", dataTypes: ["Имена и фамилии", "Телефоны"])
        let result = AnonymizationResult(input: input, generatedText: generated, text: generated,
                                         downloadNameStem: "отчёт", bodyReplacementCount: UInt(pairs.count),
                                         pairs: pairs, warnings: warnings)
        let card = AnonymizationCardDocument(
            id: UUID().uuidString, importOrder: 1,
            importContentIdentity: ByteContentIdentity(bytes: Data(sourceText.utf8)),
            importedNameStem: "отчёт", sourceFormat: .markdown, displayName: "отчёт",
            source: sourceRevision,
            latestAttempt: AnonymizationAttempt(state: .succeeded, expectedResultRevisionID: generated.id, input: input),
            publishedResult: result)
        try card.validate()
        return card
    }

    // MARK: - Criterion 29: single-fragment edits

    func testPartialEditInsideFragmentKeepsPairInBothPanels() throws {
        let card = try makeCard()
        // Left panel: «нн» inside «Анна» shortened to «н».
        let left = try AnonymizationEditing.editSource(card, ScalarEdit(start: 1, end: 3, replacement: "н"))
        let leftText = "Ана позвонила Ивану по номеру +7 999 000-00-00."
        XCTAssertEqual(left.source.text, leftText)
        XCTAssertEqual(left.publishedResult?.pairs.map(\.sourceRange), [
            try range(of: "Ана", in: leftText),
            try range(of: "Ивану", in: leftText),
            try range(of: "+7 999 000-00-00", in: leftText)])
        // The result side of the kept pairs is untouched.
        XCTAssertEqual(left.publishedResult?.pairs.map(\.resultRange), card.publishedResult?.pairs.map(\.resultRange))
        XCTAssertTrue(left.resultBuiltFromEarlierSource)
        XCTAssertFalse(left.resultManuallyEdited)
        // Right panel: the same shape of edit inside «Мария».
        let right = try AnonymizationEditing.editResult(card, ScalarEdit(start: 1, end: 3, replacement: "a"))
        let rightText = "Мaия позвонила Олегу по номеру +1 555 111-11-11."
        XCTAssertEqual(right.publishedResult?.text.text, rightText)
        XCTAssertEqual(right.publishedResult?.pairs.map(\.resultRange), [
            try range(of: "Мaия", in: rightText),
            try range(of: "Олегу", in: rightText),
            try range(of: "+1 555 111-11-11", in: rightText)])
        XCTAssertEqual(right.publishedResult?.pairs.map(\.sourceRange), card.publishedResult?.pairs.map(\.sourceRange))
        XCTAssertTrue(right.resultManuallyEdited)
    }

    func testExactFullReplacementWithNonEmptyTextKeepsPair() throws {
        let card = try makeCard()
        let range = try self.range(of: "Анна", in: card.source.text)
        let edited = try AnonymizationEditing.editSource(card, ScalarEdit(start: range.start, end: range.end, replacement: "Ольга Петрова"))
        XCTAssertEqual(edited.source.text, "Ольга Петрова позвонила Ивану по номеру +7 999 000-00-00.")
        XCTAssertEqual(edited.publishedResult?.pairs.first?.sourceRange,
                       TextRange(start: 0, end: UInt("Ольга Петрова".unicodeScalars.count)))
        XCTAssertEqual(edited.publishedResult?.pairs.count, 3)
    }

    func testWiderSingleFragmentCaptureKeepsPairOnReplacementText() throws {
        let card = try makeCard()
        // The edit covers «Анна» plus the plain words after it — one fragment captured.
        let edited = try AnonymizationEditing.editSource(card, ScalarEdit(start: 0, end: 14, replacement: "Ольга"))
        XCTAssertEqual(edited.source.text, "Ольга Ивану по номеру +7 999 000-00-00.")
        XCTAssertEqual(edited.publishedResult?.pairs.first?.sourceRange, TextRange(start: 0, end: 5))
        XCTAssertEqual(edited.publishedResult?.pairs.count, 3)
    }

    func testFullDeletionRemovesPairFromBothSides() throws {
        let card = try makeCard()
        // Exact deletion of the fragment.
        let exact = try self.range(of: "Анна", in: card.source.text)
        let editedExact = try AnonymizationEditing.editSource(card, ScalarEdit(start: exact.start, end: exact.end, replacement: ""))
        XCTAssertEqual(editedExact.publishedResult?.pairs.count, 2)
        XCTAssertFalse(editedExact.publishedResult!.pairs.contains { $0.resultRange == card.publishedResult!.pairs[0].resultRange })
        // A wider deletion covering the same single fragment removes it too.
        let editedWide = try AnonymizationEditing.editSource(card, ScalarEdit(start: 0, end: 14, replacement: ""))
        XCTAssertEqual(editedWide.source.text, " Ивану по номеру +7 999 000-00-00.")
        XCTAssertEqual(editedWide.publishedResult?.pairs.map(\.sourceRange), [
            try range(of: "Ивану", in: editedWide.source.text),
            try range(of: "+7 999 000-00-00", in: editedWide.source.text)])
        // Deletion through the right panel removes the pair as well.
        let resultRange = try self.range(of: "Мария", in: card.publishedResult!.text.text)
        let editedRight = try AnonymizationEditing.editResult(card, ScalarEdit(start: resultRange.start, end: resultRange.end, replacement: ""))
        XCTAssertEqual(editedRight.publishedResult?.pairs.count, 2)
    }

    func testPartialDeletionKeepsRemainingFragmentText() throws {
        let card = try makeCard()
        // Delete the head of «Анна» — the remainder «на» keeps the link.
        let head = try AnonymizationEditing.editSource(card, ScalarEdit(start: 0, end: 2, replacement: ""))
        XCTAssertEqual(head.source.text, "на позвонила Ивану по номеру +7 999 000-00-00.")
        XCTAssertEqual(head.publishedResult?.pairs.first?.sourceRange, TextRange(start: 0, end: 2))
        // Delete the tail of «Анна» — the remainder «Ан» keeps the link.
        let tail = try AnonymizationEditing.editSource(card, ScalarEdit(start: 2, end: 4, replacement: ""))
        XCTAssertEqual(tail.publishedResult?.pairs.first?.sourceRange, TextRange(start: 0, end: 2))
        XCTAssertEqual(tail.publishedResult?.pairs.count, 3)
    }

    func testInsertionAtOuterBoundariesActsOutsidePair() throws {
        let card = try makeCard()
        let anna = try range(of: "Анна", in: card.source.text)
        // Insertion at the left outer boundary shifts the pair.
        let before = try AnonymizationEditing.editSource(card, ScalarEdit(start: anna.start, end: anna.start, replacement: "…"))
        XCTAssertEqual(before.publishedResult?.pairs.first?.sourceRange,
                       TextRange(start: anna.start + 1, end: anna.end + 1))
        // Insertion at the right outer boundary leaves the pair in place.
        let after = try AnonymizationEditing.editSource(card, ScalarEdit(start: anna.end, end: anna.end, replacement: "…"))
        XCTAssertEqual(after.publishedResult?.pairs.first?.sourceRange, anna)
        // An insertion strictly inside expands the pair.
        let inside = try AnonymizationEditing.editSource(card, ScalarEdit(start: 2, end: 2, replacement: "12345"))
        XCTAssertEqual(inside.publishedResult?.pairs.first?.sourceRange, TextRange(start: 0, end: 9))
    }

    func testEditsOutsidePairsShiftOnlyTrailingPairs() throws {
        let card = try makeCard()
        // Replace plain text between «Ивану» and the phone number.
        let gap = try range(of: "по номеру", in: card.source.text)
        let edited = try AnonymizationEditing.editSource(card, ScalarEdit(start: gap.start, end: gap.end, replacement: "на номер"))
        XCTAssertEqual(edited.publishedResult?.pairs.map(\.sourceRange), [
            card.publishedResult!.pairs[0].sourceRange,
            card.publishedResult!.pairs[1].sourceRange,
            TextRange(start: card.publishedResult!.pairs[2].sourceRange.start - 1,
                      end: card.publishedResult!.pairs[2].sourceRange.end - 1)])
        // An edit after the last pair changes nothing.
        let last = card.publishedResult!.pairs[2].sourceRange
        let tail = try AnonymizationEditing.editSource(card, ScalarEdit(start: last.end, end: last.end + 1, replacement: "!"))
        XCTAssertEqual(tail.publishedResult?.pairs, card.publishedResult?.pairs)
    }

    // MARK: - Criterion 29: multi-fragment edits

    func testMultiFragmentEditDropsFullyCapturedPairsInSourcePanel() throws {
        let card = try makeCard()
        let ivan = try range(of: "Ивану", in: card.source.text)
        let phone = try range(of: "+7 999 000-00-00", in: card.source.text)
        // One edit covering both fragments entirely removes both pairs.
        let edited = try AnonymizationEditing.editSource(card, ScalarEdit(start: ivan.start, end: phone.end, replacement: "Олегу"))
        XCTAssertEqual(edited.source.text, "Анна позвонила Олегу.")
        XCTAssertEqual(edited.publishedResult?.pairs.map(\.sourceRange), [
            try range(of: "Анна", in: edited.source.text)])
        XCTAssertEqual(edited.publishedResult?.pairs.first?.resultRange,
                       card.publishedResult?.pairs.first?.resultRange)
        // The same edit with an empty replacement removes them as well.
        let deleted = try AnonymizationEditing.editSource(card, ScalarEdit(start: ivan.start, end: phone.end, replacement: ""))
        XCTAssertEqual(deleted.publishedResult?.pairs.count, 1)
    }

    func testMultiFragmentEditKeepsPartiallyCapturedPairs() throws {
        let card = try makeCard()
        let ivan = try range(of: "Ивану", in: card.source.text)
        let phone = try range(of: "+7 999 000-00-00", in: card.source.text)
        // The edit cuts the tail of «Ивану» and the head of the number; both
        // keep the link with their surviving text, the inserted text joins neither.
        let replacement = "Х"
        let edited = try AnonymizationEditing.editSource(card,
            ScalarEdit(start: ivan.start + 2, end: phone.start + 3, replacement: replacement))
        let text = "Анна позвонила ИвХ999 000-00-00."
        XCTAssertEqual(edited.source.text, text)
        let expectedIvan = TextRange(start: ivan.start, end: ivan.start + 2)
        let replacementLength = UInt(replacement.unicodeScalars.count)
        let expectedPhone = TextRange(start: ivan.start + 2 + replacementLength,
                                      end: ivan.start + 2 + replacementLength + (phone.end - phone.start - 3))
        XCTAssertEqual(edited.publishedResult?.pairs.map(\.sourceRange), [
            card.publishedResult!.pairs[0].sourceRange, expectedIvan, expectedPhone])
        // The visible ranges stay inside the new version and disjoint (validate re-checks).
        try edited.validate()
    }

    func testMultiFragmentEditDropsFullyCapturedPairsInResultPanel() throws {
        let card = try makeCard()
        let oleg = try range(of: "Олегу", in: card.publishedResult!.text.text)
        let phone = try range(of: "+1 555 111-11-11", in: card.publishedResult!.text.text)
        let edited = try AnonymizationEditing.editResult(card, ScalarEdit(start: oleg.start, end: phone.end, replacement: "Олегу"))
        XCTAssertEqual(edited.publishedResult?.text.text, "Мария позвонила Олегу.")
        XCTAssertEqual(edited.publishedResult?.pairs.map(\.resultRange), [
            try range(of: "Мария", in: edited.publishedResult!.text.text)])
        // The source side of the removed pairs disappears together with them.
        XCTAssertEqual(edited.publishedResult?.pairs.first?.sourceRange,
                       card.publishedResult?.pairs.first?.sourceRange)
        XCTAssertTrue(edited.resultManuallyEdited)
    }

    // MARK: - Criterion 29: emoji and composed characters

    func testEmojiAndComposedCharactersKeepRangesInBoundsAndDisjoint() throws {
        let emojiSource = "Анна 👩‍💻 написала Стёпе про созвон +7 999 000-00-00 🇫🇷, café ouvert."
        var pairs: [ReplacementPair] = []
        var resultText = replacingScalars(emojiSource, "Анна", "Мария")
        resultText = replacingScalars(resultText, "+7 999 000-00-00", "+1 555 111-11-11")
        pairs.append(ReplacementPair(sourceRange: try range(of: "Анна", in: emojiSource),
                                     resultRange: try range(of: "Мария", in: resultText)))
        pairs.append(ReplacementPair(sourceRange: try range(of: "+7 999 000-00-00", in: emojiSource),
                                     resultRange: try range(of: "+1 555 111-11-11", in: resultText)))
        let sourceRevision = TextRevision(id: UUID().uuidString, text: emojiSource)
        let generated = TextRevision(id: UUID().uuidString, text: resultText)
        let input = RunInput(source: sourceRevision, profileID: "p", packageID: "pk", dataTypes: ["Имена и фамилии"])
        let card = AnonymizationCardDocument(
            id: UUID().uuidString, importOrder: 1,
            importContentIdentity: ByteContentIdentity(bytes: Data(emojiSource.utf8)),
            importedNameStem: "отчёт", sourceFormat: .markdown, displayName: "отчёт",
            source: sourceRevision,
            latestAttempt: AnonymizationAttempt(state: .succeeded, expectedResultRevisionID: generated.id, input: input),
            publishedResult: AnonymizationResult(input: input, generatedText: generated, text: generated,
                                                 downloadNameStem: "отчёт", bodyReplacementCount: 2,
                                                 pairs: pairs,
                                                 warnings: [AnonymizationWarning(
                                                    kind: .doubtfulFragment, target: .body,
                                                    inputRange: try range(of: "Стёпе", in: emojiSource),
                                                    generatedRange: try range(of: "Стёпе", in: resultText),
                                                    reviewRange: try range(of: "Стёпе", in: resultText))]))
        try card.validate()

        // Edit inside the ZWJ emoji sequence and around the flag and café.
        let woman = try range(of: "👩‍💻", in: emojiSource)
        var edited = try AnonymizationEditing.editSource(card, ScalarEdit(start: woman.start + 1, end: woman.end, replacement: "🙂"))
        try edited.validate()
        // Delete the flag emoji entirely — the pair before it keeps its place.
        let flag = try range(of: "🇫🇷", in: edited.source.text)
        edited = try AnonymizationEditing.editSource(edited, ScalarEdit(start: flag.start, end: flag.end, replacement: ""))
        try edited.validate()
        // Split the composed é of café through the result panel.
        let cafe = try range(of: "café", in: edited.publishedResult!.text.text)
        edited = try AnonymizationEditing.editResult(edited, ScalarEdit(start: cafe.start, end: cafe.end, replacement: "CAFE"))
        try edited.validate()
        XCTAssertEqual(edited.publishedResult?.text.text.contains("CAFE"), true)
        // Every visible UTF-16 range stays exact and inside the version.
        let bridge = TextUTF16Bridge(text: edited.publishedResult!.text.text)
        for pair in edited.publishedResult!.pairs {
            let ns = try XCTUnwrap(bridge.nsRange(from: pair.resultRange))
            XCTAssertEqual(bridge.textRange(from: ns), pair.resultRange)
        }
    }

    func testRandomEditSequencesKeepDocumentValid() throws {
        struct SplitMix64 {
            var state: UInt64
            mutating func next() -> UInt64 {
                state &+= 0x9E3779B97F4A7C15
                var z = state
                z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
                z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
                return z ^ (z >> 31)
            }
        }
        let alphabet = ["А", "н", " ", "👩‍💻", "е", "\n", "+7"]
        for seed: UInt64 in [1, 2, 3] {
            var random = SplitMix64(state: seed)
            var card = try makeCard(doubtful: "Стёпе")
            var pairCount = card.publishedResult!.pairs.count
            for _ in 0..<160 {
                let editingSource = random.next() % 2 == 0
                let text = editingSource ? card.source.text : card.publishedResult!.text.text
                let count = UInt(text.unicodeScalars.count)
                var start = UInt(random.next() % UInt64(max(count, 1)))
                var end = UInt(random.next() % UInt64(max(count, 1)))
                if start > end { swap(&start, &end) }
                if count == 0 { start = 0; end = 0 }
                var replacement = ""
                let length = Int(random.next() % 5)
                for _ in 0..<length { replacement += alphabet.randomElement()! }
                let edit = ScalarEdit(start: start, end: end, replacement: replacement)
                guard (start != end) || !replacement.isEmpty else { continue }
                card = try editingSource
                    ? AnonymizationEditing.editSource(card, edit)
                    : AnonymizationEditing.editResult(card, edit)
                try card.validate()
                XCTAssertLessThanOrEqual(card.publishedResult!.pairs.count, pairCount,
                                         "правки не могут добавлять пары (seed \(seed))")
                pairCount = card.publishedResult!.pairs.count
            }
        }
    }

    // MARK: - Criterion 46: warnings under edits

    func testResultEditRecalculatesReviewRangeAndKeepsHistoryCoordinates() throws {
        let card = try makeCard(doubtful: "Стёпе")
        let warning = try XCTUnwrap(card.publishedResult?.warnings.first)
        let review = try XCTUnwrap(warning.reviewRange)
        // An interior edit of the doubtful fragment moves the review position…
        let edited = try AnonymizationEditing.editResult(card, ScalarEdit(start: review.start + 1, end: review.end - 1, replacement: "ианн"))
        let expected = try range(of: "Сианне", in: edited.publishedResult!.text.text)
        XCTAssertEqual(edited.publishedResult?.warnings.first?.reviewRange, expected)
        // …while the historical run coordinates never change.
        XCTAssertEqual(edited.publishedResult?.warnings.first?.inputRange, warning.inputRange)
        XCTAssertEqual(edited.publishedResult?.warnings.first?.generatedRange, warning.generatedRange)
        XCTAssertTrue(edited.resultManuallyEdited)
        // A full non-empty replacement keeps the traceable position on the new text.
        let replaced = try AnonymizationEditing.editResult(card, ScalarEdit(start: review.start, end: review.end, replacement: "Иван"))
        XCTAssertEqual(replaced.publishedResult?.warnings.first?.reviewRange,
                       TextRange(start: review.start, end: review.start + 4))
    }

    func testReviewRangeLostOnFullDeletionButLeftEditsDoNotTouchWarnings() throws {
        let card = try makeCard(doubtful: "Стёпе")
        let warning = try XCTUnwrap(card.publishedResult?.warnings.first)
        let review = try XCTUnwrap(warning.reviewRange)
        // Deleting the doubtful place from the right panel loses the trace; the
        // position in the automatic version stays available.
        let edited = try AnonymizationEditing.editResult(card, ScalarEdit(start: review.start, end: review.end, replacement: ""))
        let lost = try XCTUnwrap(edited.publishedResult?.warnings.first)
        XCTAssertNil(lost.reviewRange)
        XCTAssertEqual(lost.inputRange, warning.inputRange)
        XCTAssertEqual(lost.generatedRange, warning.generatedRange)
        try edited.validate()
        // Editing the left panel leaves the warnings untouched: review positions
        // refer to the right text only.
        let left = try AnonymizationEditing.editSource(card, ScalarEdit(start: 0, end: 4, replacement: ""))
        XCTAssertEqual(left.publishedResult?.warnings, card.publishedResult?.warnings)
    }

    func testNameAndUninterpretedWarningsPassThrough() throws {
        let card = try makeCard(doubtful: "Стёпе", extraWarnings: [
            AnonymizationWarning(kind: .uninterpretedType, dataType: "Телефоны"),
            AnonymizationWarning(kind: .doubtfulFragment, target: .importedName,
                                 inputRange: TextRange(start: 0, end: 3),
                                 generatedRange: TextRange(start: 0, end: 3)),
        ])
        let review = try XCTUnwrap(card.publishedResult?.warnings.first?.reviewRange)
        let edited = try AnonymizationEditing.editResult(card, ScalarEdit(start: review.start, end: review.end, replacement: ""))
        XCTAssertEqual(edited.publishedResult?.warnings.dropFirst().map { $0 },
                       card.publishedResult?.warnings.dropFirst().map { $0 })
    }

    // MARK: - Retry semantics and document consistency

    func testSuccessfulRetryReplacesPairsAndWarningsAndResetsFlags() throws {
        var card = try makeCard(doubtful: "Стёпе")
        // Manual edits transform the old pairs and lose a review position.
        let review = try XCTUnwrap(card.publishedResult?.warnings.first?.reviewRange)
        card = try AnonymizationEditing.editResult(card, ScalarEdit(start: review.start, end: review.end, replacement: ""))
        XCTAssertTrue(card.resultManuallyEdited)
        // A new successful run publishes its own result wholesale.
        let newSource = card.source
        let newText = TextRevision(id: UUID().uuidString, text: "Мария позвонила Олегу по номеру +1 555 111-11-11.")
        let newInput = RunInput(source: newSource, profileID: "p", packageID: "pk", dataTypes: ["Имена и фамилии"])
        let newPairs = [ReplacementPair(sourceRange: try range(of: "Анна", in: newSource.text),
                                        resultRange: try range(of: "Мария", in: newText.text))]
        let newResult = AnonymizationResult(input: newInput, generatedText: newText, text: newText,
                                            downloadNameStem: "отчёт", bodyReplacementCount: 1,
                                            pairs: newPairs, warnings: [])
        card.publishedResult = newResult
        card.latestAttempt = AnonymizationAttempt(state: .succeeded, expectedResultRevisionID: newText.id, input: newInput)
        try card.validate()
        XCTAssertEqual(card.publishedResult?.pairs, newPairs)
        XCTAssertFalse(card.resultManuallyEdited)
        XCTAssertFalse(card.resultBuiltFromEarlierSource)
    }

    func testSameIdentityResultMustMatchGeneratedText() throws {
        let card = try makeCard()
        var tampered = card
        tampered.publishedResult!.text = TextRevision(id: card.publishedResult!.generatedText.id,
                                                      text: "изменённый текст")
        XCTAssertThrowsError(try tampered.validate())
        XCTAssertNoThrow(try card.validate())
    }

    func testEditValidationRejectsInvalidOperations() throws {
        let card = try makeCard()
        let count = UInt(card.source.text.unicodeScalars.count)
        XCTAssertThrowsError(try AnonymizationEditing.editSource(card, ScalarEdit(start: 0, end: count + 1, replacement: "x")))
        XCTAssertThrowsError(try AnonymizationEditing.editSource(card, ScalarEdit(start: 3, end: 3, replacement: "")))
        var fresh = try makeCard()
        fresh.publishedResult = nil
        fresh.latestAttempt = AnonymizationAttempt(state: .waitingModel)
        XCTAssertThrowsError(try AnonymizationEditing.editResult(fresh, ScalarEdit(start: 0, end: 1, replacement: "x")))
        // Before the first result the source stays editable.
        let edited = try AnonymizationEditing.editSource(fresh, ScalarEdit(start: 0, end: 4, replacement: "Ольга"))
        XCTAssertNil(edited.publishedResult)
        XCTAssertFalse(edited.resultBuiltFromEarlierSource)
        XCTAssertFalse(edited.resultManuallyEdited)
    }

    // MARK: - UTF-16 bridge

    func testUTF16BridgeHandlesSurrogatePairsAndBoundaries() throws {
        // a 👩 ZWJ 💻 b 🇫🇷 e + combining acute (decomposed explicitly).
        let text = "a👩‍💻b🇫🇷e\u{0301}"
        let bridge = TextUTF16Bridge(text: text)
        XCTAssertEqual(bridge.scalarCount, 9)
        XCTAssertEqual(bridge.utf16Length, 13)
        // Forward: exact boundaries, never inside a surrogate pair.
        XCTAssertEqual(bridge.utf16Offset(ofScalarBoundary: 0), 0)
        XCTAssertEqual(bridge.utf16Offset(ofScalarBoundary: 1), 1)
        XCTAssertEqual(bridge.utf16Offset(ofScalarBoundary: 2), 3)
        XCTAssertEqual(bridge.utf16Offset(ofScalarBoundary: 4), 6)
        XCTAssertEqual(bridge.utf16Offset(ofScalarBoundary: 5), 7)
        XCTAssertEqual(bridge.utf16Offset(ofScalarBoundary: 7), 11)
        XCTAssertEqual(bridge.utf16Offset(ofScalarBoundary: 9), 13)
        XCTAssertNil(bridge.utf16Offset(ofScalarBoundary: 10))
        // Backward: astral scalars take two units, odd offsets are inside pairs.
        XCTAssertEqual(bridge.scalarBoundary(atUTF16Offset: 0), 0)
        XCTAssertEqual(bridge.scalarBoundary(atUTF16Offset: 3), 2)
        XCTAssertEqual(bridge.scalarBoundary(atUTF16Offset: 6), 4)
        XCTAssertEqual(bridge.scalarBoundary(atUTF16Offset: 11), 7)
        XCTAssertEqual(bridge.scalarBoundary(atUTF16Offset: 13), 9)
        XCTAssertNil(bridge.scalarBoundary(atUTF16Offset: 2), "внутрь суррогатной пары нельзя")
        XCTAssertNil(bridge.scalarBoundary(atUTF16Offset: 8))
        XCTAssertNil(bridge.scalarBoundary(atUTF16Offset: -1))
        XCTAssertNil(bridge.scalarBoundary(atUTF16Offset: 14))
        // The whole emoji sequence converts exactly in both directions.
        let emoji = TextRange(start: 1, end: 4)
        let ns = try XCTUnwrap(bridge.nsRange(from: emoji))
        XCTAssertEqual(ns, NSRange(location: 1, length: 5))
        XCTAssertEqual(bridge.textRange(from: ns), emoji)
        XCTAssertNil(bridge.textRange(from: NSRange(location: 2, length: 1)))
        XCTAssertNil(bridge.textRange(from: NSRange(location: 0, length: 0)))
        XCTAssertNil(bridge.nsRange(from: TextRange(start: 3, end: 3)))
        XCTAssertNil(bridge.nsRange(from: TextRange(start: 8, end: 12)))
        // Editor operations: replacement of a selection, deletion and insertion.
        let replacement = bridge.edit(fromSelectedRange: NSRange(location: 7, length: 4), replacement: "")
        XCTAssertEqual(replacement, ScalarEdit(start: 5, end: 7, replacement: ""))
        let insertion = bridge.edit(fromSelectedRange: NSRange(location: 6, length: 0), replacement: "X")
        XCTAssertEqual(insertion, ScalarEdit(start: 4, end: 4, replacement: "X"))
        XCTAssertNil(bridge.edit(fromSelectedRange: NSRange(location: 2, length: 0), replacement: "X"))
        XCTAssertNil(bridge.edit(fromSelectedRange: NSRange(location: 6, length: 0), replacement: ""))
    }

    func testBridgeMatchesEngineOnPlainText() throws {
        let text = "Отчёт: Анна позвонила."
        let bridge = TextUTF16Bridge(text: text)
        XCTAssertEqual(bridge.scalarCount, bridge.utf16Length, "BMP-текст имеет равные длины")
        let fragment = try range(of: "Анна", in: text)
        let ns = try XCTUnwrap(bridge.nsRange(from: fragment))
        XCTAssertEqual(ns, NSRange(location: Int(fragment.start), length: Int(fragment.end - fragment.start)))
    }

    // MARK: - Coordinator transaction and reopening

    func testCoordinatorCommitsEditsAndReopenKeepsConsistency() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let repository = try AnonymizationRepository(root: root)
        let coordinator = AnonymizationCoordinator(repository: repository)
        let imported = try await coordinator.importCard(.init(
            bytes: Data(source.utf8), importedNameStem: "отчёт", sourceFormat: .markdown,
            source: TextRevision(id: UUID().uuidString, text: source)))
        // Publish a result for the imported card (identical source content).
        let published = try makeCard()
        _ = try await coordinator.updateCard(imported.id) {
            $0.publishedResult = published.publishedResult
            $0.latestAttempt = published.latestAttempt
        }

        let anna = try range(of: "Анна", in: source)
        var snapshot = await coordinator.snapshot()
        let revisionBefore = snapshot.revision
        // A left edit and a right edit commit as two document transactions.
        let leftEdited = try await coordinator.editSource(imported.id, ScalarEdit(start: anna.start, end: anna.end, replacement: "Ольга"))
        XCTAssertTrue(leftEdited.resultBuiltFromEarlierSource)
        XCTAssertFalse(leftEdited.resultManuallyEdited)
        let maria = try range(of: "Мария", in: leftEdited.publishedResult!.text.text)
        let rightEdited = try await coordinator.editResult(imported.id, ScalarEdit(start: maria.start, end: maria.end, replacement: "Марья"))
        XCTAssertTrue(rightEdited.resultManuallyEdited)
        snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot.revision, revisionBefore + 2)
        // Invalid edits are rejected without any write.
        let count = UInt(rightEdited.source.text.unicodeScalars.count)
        do {
            _ = try await coordinator.editSource(imported.id, ScalarEdit(start: 0, end: count + 1, replacement: "x"))
            XCTFail("Правка за границами текста должна отклоняться")
        } catch {}
        let awaitRejected = await coordinator.snapshot()
        XCTAssertEqual(awaitRejected.revision, revisionBefore + 2)
        // A fresh coordinator over the same root reads the same consistent document.
        let reopened = AnonymizationCoordinator(repository: try AnonymizationRepository(root: root))
        let reloaded = try await reopened.loadCard(imported.id)
        XCTAssertEqual(reloaded, rightEdited)
        XCTAssertNoThrow(try reloaded.validate())
        XCTAssertEqual(reloaded.publishedResult?.pairs.count, 3)
        XCTAssertEqual(reloaded.source.text, "Ольга позвонила Ивану по номеру +7 999 000-00-00.")
        XCTAssertEqual(reloaded.publishedResult?.text.text, "Марья позвонила Олегу по номеру +1 555 111-11-11.")
        XCTAssertEqual(reloaded.automaticSubstitutions, [])
    }
}
