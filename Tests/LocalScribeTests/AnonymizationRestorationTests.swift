import Foundation
import LocalScribeCore
import XCTest

final class AnonymizationRestorationTests: XCTestCase {
    private typealias TextRange = LocalScribeCore.TextRange

    func testRestoresLiteralLongestStandaloneMatchesWithoutCascading() async throws {
        let (_, archive, card) = try await makeCard([
            ("😀Анна", "Eva"), ("Д. Иванов", "Eva Smith"), ("Eva", "zed"),
            ("Алиса", "Alias"), ("Элис", "Alias"), ("Рене", "Cafe\u{301}"),
            ("person@example.org", "fictional@example.com")
        ])
        let resultID = try XCTUnwrap(card.publishedResult?.text.id)
        let text = "📝 Eva Smith | Eva, zed and Eva | preEva Eva2 eva Eva\u{301} | Alias\n[Cafe\u{301}](mailto:fictional@example.com) | Café"
        let updated = try await archive.restoreText(card.id, text: text, sourceFormat: .markdown,
                                                     expectedResultID: resultID, expectedSourceID: card.source.id)
        let restoration = try XCTUnwrap(updated.restoration)
        XCTAssertEqual(restoration.source.text, text)
        XCTAssertEqual(restoration.sourceFormat, .markdown)
        XCTAssertEqual(restoration.result.text,
                       "📝 Д. Иванов | 😀Анна, Eva and 😀Анна | preEva Eva2 eva Eva\u{301} | Alias\n[Рене](mailto:person@example.org) | Café")
        XCTAssertEqual(slices(restoration.source.text, restoration.pairs.map(\.sourceRange)),
                       ["Eva Smith", "Eva", "zed", "Eva", "Cafe\u{301}", "fictional@example.com"])
        XCTAssertEqual(slices(restoration.result.text, restoration.pairs.map(\.resultRange)),
                       ["Д. Иванов", "😀Анна", "Eva", "😀Анна", "Рене", "person@example.org"])
        XCTAssertEqual(restoration.pairs.first?.sourceRange.start, 2)
    }

    func testPersistenceRerunAndCardDeletion() async throws {
        let (repository, archive, card) = try await makeCard([("Анна", "Eva")])
        let resultID = try XCTUnwrap(card.publishedResult?.text.id)
        // Earlier cards have no restoration field and remain readable.
        let originalJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: repository.cardURL(card.id)))
        XCTAssertNil((originalJSON as? [String: Any])?["restoration"])
        XCTAssertNil(try repository.loadCard(card.id).restoration)

        let updated = try await archive.restoreText(card.id, text: "Eva / Ivy", sourceFormat: .markdown,
                                                     expectedResultID: resultID, expectedSourceID: card.source.id)
        let restoration = try XCTUnwrap(updated.restoration)
        XCTAssertEqual(restoration.result.text, "Анна / Ivy")
        XCTAssertEqual(updated.latestAttempt, card.latestAttempt)
        XCTAssertEqual(updated.publishedResult, card.publishedResult)

        let edited = try await archive.editResult(card.id, ScalarEdit(start: 0, end: 3, replacement: "Ivy"))
        XCTAssertEqual(edited.restoration, restoration)
        let restarted = AnonymizationCoordinator(repository: repository)
        let snapshot = try await restarted.recover()
        XCTAssertEqual(snapshot.cards.first?.restorationResultRevisionID, restoration.result.id)
        XCTAssertEqual(try repository.loadCard(card.id).restoration, restoration)

        let repeated = try await restarted.repeatRestoration(card.id, expectedRestorationID: restoration.result.id)
        let next = try XCTUnwrap(repeated.restoration)
        XCTAssertEqual(next.source, restoration.source)
        XCTAssertEqual(next.sourceFormat, .markdown)
        XCTAssertEqual(next.result.text, "Eva / Анна")
        XCTAssertNotEqual(next.result.id, restoration.result.id)
        XCTAssertEqual(repeated.publishedResult, edited.publishedResult)
        XCTAssertEqual(try repository.loadCard(card.id), repeated)

        try await restarted.prepareCardDeletion([card.id])
        try await restarted.finishCardDeletion()
        XCTAssertEqual(repository.cardFolderStatus(card.id), .absent)
        let finalSnapshot = await restarted.snapshot()
        XCTAssertTrue(finalSnapshot.cards.isEmpty)
    }

    func testStaleResultAndPendingDeletionPreserveSavedRestoration() async throws {
        let (repository, archive, card) = try await makeCard([("Анна", "Eva")])
        let resultID = try XCTUnwrap(card.publishedResult?.text.id)
        let updated = try await archive.restoreText(card.id, text: "No replacements", sourceFormat: .txt,
                                                     expectedResultID: resultID, expectedSourceID: card.source.id)
        let restoration = try XCTUnwrap(updated.restoration)
        XCTAssertEqual(restoration.result.text, "No replacements")
        XCTAssertTrue(restoration.pairs.isEmpty)

        let edited = try await archive.editResult(card.id, ScalarEdit(start: 0, end: 3, replacement: "Ivy"))
        let newResultID = try XCTUnwrap(edited.publishedResult?.text.id)
        let editedSource = try await archive.editSource(card.id, ScalarEdit(start: 0, end: 4, replacement: "Елена"))
        XCTAssertEqual(editedSource.publishedResult?.text.id, newResultID)
        let beforeFailures = await archive.snapshot()
        do {
            try await archive.restoreText(card.id, text: "Eva", sourceFormat: .txt,
                                          expectedResultID: resultID, expectedSourceID: editedSource.source.id)
            XCTFail("A stale anonymized result must not publish a restoration")
        } catch is ScribeError {}
        do {
            try await archive.restoreText(card.id, text: "Ivy", sourceFormat: .txt,
                                          expectedResultID: newResultID, expectedSourceID: card.source.id)
            XCTFail("A changed original must not restore text against a different replacement map")
        } catch is ScribeError {}
        do {
            try await archive.repeatRestoration(card.id, expectedRestorationID: UUID().uuidString)
            XCTFail("A stale reverse result must not publish a restoration")
        } catch is ScribeError {}
        do {
            try await archive.restoreText(card.id, text: " \t\n", sourceFormat: .txt,
                                          expectedResultID: newResultID, expectedSourceID: editedSource.source.id)
            XCTFail("Whitespace-only text must not replace the saved restoration")
        } catch is ScribeError {}
        try await archive.prepareCardDeletion([card.id])
        do {
            try await archive.repeatRestoration(card.id, expectedRestorationID: restoration.result.id)
            XCTFail("A card already pending deletion must not accept a restoration")
        } catch is ScribeError {}
        XCTAssertEqual(try repository.loadCard(card.id), editedSource)
        let afterFailures = await archive.snapshot()
        XCTAssertEqual(afterFailures.revision, beforeFailures.revision)
    }

    func testTamperedRestoredTextFailsWholeCardValidation() async throws {
        let (repository, archive, card) = try await makeCard([("Анна", "Eva")])
        let resultID = try XCTUnwrap(card.publishedResult?.text.id)
        try await archive.restoreText(card.id, text: "Eva suffix", sourceFormat: .txt,
                                      expectedResultID: resultID, expectedSourceID: card.source.id)
        let url = repository.cardURL(card.id)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        var document = try XCTUnwrap(json as? [String: Any])
        var restoration = try XCTUnwrap(document["restoration"] as? [String: Any])
        var result = try XCTUnwrap(restoration["result"] as? [String: Any])
        result["text"] = "Анна prefix"
        restoration["result"] = result
        document["restoration"] = restoration
        try JSONSerialization.data(withJSONObject: document).write(to: url)
        XCTAssertThrowsError(try repository.loadCard(card.id))
    }

    private func makeCard(_ mappings: [(original: String, placeholder: String)]) async throws
        -> (AnonymizationRepository, AnonymizationCoordinator, AnonymizationCardDocument) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let repository = try AnonymizationRepository(root: root)
        let archive = AnonymizationCoordinator(repository: repository)
        let originalFragments = mappings.map(\.original)
        let substituteFragments = mappings.map(\.placeholder)
        let source = TextRevision(id: UUID().uuidString, text: originalFragments.joined(separator: "\n"))
        let published = TextRevision(id: UUID().uuidString, text: substituteFragments.joined(separator: "\n"))
        let summary = try await archive.importCard(.init(bytes: Data(source.text.utf8), importedNameStem: "original",
                                                         sourceFormat: .txt, source: source))
        let input = RunInput(source: source, profileID: "profile", packageID: "package", dataTypes: ["Names"])
        let pairs = zip(ranges(originalFragments), ranges(substituteFragments)).map { sourceRange, resultRange in
            ReplacementPair(sourceRange: sourceRange, resultRange: resultRange)
        }
        let document = try await archive.updateCard(summary.id) { card in
            card.latestAttempt = AnonymizationAttempt(state: .succeeded, input: input)
            card.publishedResult = AnonymizationResult(input: input, generatedText: published, text: published,
                downloadNameStem: "anonymous", bodyReplacementCount: UInt(pairs.count), pairs: pairs)
        }
        return (repository, archive, document)
    }

    private func ranges(_ fragments: [String]) -> [TextRange] {
        var start: UInt = 0
        return fragments.map { fragment in
            let end = start + UInt(fragment.unicodeScalars.count)
            defer { start = end + 1 }
            return TextRange(start: start, end: end)
        }
    }

    private func slices(_ text: String, _ ranges: [TextRange]) -> [String] {
        let scalars = Array(text.unicodeScalars)
        return ranges.map { String(String.UnicodeScalarView(scalars[Int($0.start)..<Int($0.end)])) }
    }
}
