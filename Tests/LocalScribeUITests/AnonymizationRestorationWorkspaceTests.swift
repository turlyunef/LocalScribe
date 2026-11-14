import AppKit
import XCTest
@testable import LocalScribe
@testable import LocalScribeCore

@MainActor
final class AnonymizationRestorationWorkspaceTests: XCTestCase {
    private let original = "Анна Петрова"
    private let substitute = "Мария Сидорова"

    func testCopyAnonymizedMarkdownThenPasteRestoresNameAndPreservesMarkup() async throws {
        let (workspace, cardID, _) = try await makeWorkspace(format: .markdown)
        let archive = try XCTUnwrap(workspace.model.textArchive)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        workspace.copyText(cardID, to: pasteboard)
        try await waitUntil { pasteboard.string(forType: .string) != nil }
        let copied = try XCTUnwrap(pasteboard.string(forType: .string))
        XCTAssertEqual(copied, "**\(substitute)**")

        pasteboard.clearContents()
        pasteboard.setString("# Отчёт\n\nПодготовила \(copied).", forType: .string)
        await workspace.pasteRestoration(cardID, pasteboard: pasteboard)

        let document = try await archive.loadCard(cardID)
        XCTAssertEqual(document.restoration?.result.text, "# Отчёт\n\nПодготовила **\(original)**.")
        await workspace.model.shutdown()
    }

    func testPasteHighlightsBothPanelsAndRerunKeepsAnonymizationAndCardIdentity() async throws {
        let (workspace, cardID, root) = try await makeWorkspace()
        let archive = try XCTUnwrap(workspace.model.textArchive)
        let before = try await archive.loadCard(cardID)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let prefix = "🧩 "
        let input = "\(prefix)\(substitute) готовит отчёт. \(substitute) проверяет текст."
        let restored = "\(prefix)\(original) готовит отчёт. \(original) проверяет текст."
        pasteboard.setString(input, forType: .string)

        await workspace.pasteRestoration(cardID, pasteboard: pasteboard)

        let afterPaste = try await archive.loadCard(cardID)
        let first = try XCTUnwrap(afterPaste.restoration)
        XCTAssertEqual(first.source.text, input)
        XCTAssertEqual(first.result.text, restored)
        XCTAssertEqual(afterPaste.publishedResult, before.publishedResult)
        XCTAssertEqual(afterPaste.latestAttempt, before.latestAttempt)
        XCTAssertEqual(workspace.model.textCards.map(\.id), [cardID])
        try await waitUntil { workspace.cardEditor.restorationPanels?.result.revisionID == first.result.id }
        let panels = try XCTUnwrap(workspace.cardEditor.restorationPanels)
        XCTAssertEqual(panels.source.highlightSlices, [substitute, substitute])
        XCTAssertEqual(panels.result.highlightSlices, [original, original])
        XCTAssertEqual(panels.source.highlights.first?.nsRange,
                       NSRange(location: prefix.utf16.count, length: substitute.utf16.count))

        await workspace.repeatRestoration(cardID)

        let afterRepeat = try await archive.loadCard(cardID)
        let repeated = try XCTUnwrap(afterRepeat.restoration)
        XCTAssertNotEqual(repeated.result.id, first.result.id)
        XCTAssertEqual(repeated.source, first.source)
        XCTAssertEqual(repeated.result.text, first.result.text)
        XCTAssertEqual(afterRepeat.publishedResult, before.publishedResult)
        await workspace.model.shutdown()

        let reopened = try makeModel(at: root)
        await reopened.reloadTexts()
        let reopenedWorkspace = await openCard(cardID, in: reopened)
        try await waitUntil { reopenedWorkspace.cardEditor.restorationPanels?.result.revisionID == repeated.result.id }
        let repository = try XCTUnwrap(reopened.textRepository)
        await reopenedWorkspace.deleteCards([cardID])
        XCTAssertNil(reopenedWorkspace.selection)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.folder(cardID).path))
        await reopened.shutdown()
    }

    func testImportRestoresMarkdownAndDownloadFreezesRestoredVersion() async throws {
        let (workspace, cardID, root) = try await makeWorkspace()
        let archive = try XCTUnwrap(workspace.model.textArchive)
        let file = root.appendingPathComponent("processed.markdown")
        let input = "# Отчёт\n\n**\(substitute)** подготовила отчёт."
        let expected = "# Отчёт\n\n**\(original)** подготовила отчёт."
        try XCTUnwrap(input.data(using: .utf16)).write(to: file)
        workspace.chooseImportFiles = { request in
            XCTAssertFalse(request.allowsMultipleSelection)
            return [file]
        }

        await workspace.importRestoration(cardID)

        let document = try await archive.loadCard(cardID)
        let imported = try XCTUnwrap(document.restoration)
        XCTAssertEqual(imported.sourceFormat, .markdown)
        XCTAssertEqual(imported.source.text, input)
        XCTAssertEqual(imported.result.text, expected)
        let destination = root.appendingPathComponent("download.md")
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        workspace.copyRestoration(cardID, to: pasteboard)
        try await waitUntil { pasteboard.string(forType: .string) == expected }

        pasteboard.setString("Новый текст: \(substitute)", forType: .string)
        workspace.chooseDownloadURL = { [weak workspace] snapshot in
            XCTAssertEqual(snapshot.suggestedFilename, "Отчёт.md")
            await workspace?.pasteRestoration(cardID, pasteboard: pasteboard)
            return destination
        }

        await workspace.performRestorationDownload(cardID, format: .markdown)

        try await waitUntil { FileManager.default.fileExists(atPath: destination.path) }
        XCTAssertEqual(try Data(contentsOf: destination), Data(expected.utf8))
        let afterExport = try await archive.loadCard(cardID)
        XCTAssertEqual(afterExport.restoration?.result.text, "Новый текст: \(original)")
        await workspace.model.shutdown()
    }

    func testCancelledAndRejectedInputsKeepPreviousResult() async throws {
        let (workspace, cardID, root) = try await makeWorkspace()
        let archive = try XCTUnwrap(workspace.model.textArchive)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString(substitute, forType: .string)
        await workspace.pasteRestoration(cardID, pasteboard: pasteboard)
        let previous = try await archive.loadCard(cardID)

        let file = root.appendingPathComponent("ambiguous.txt")
        try Data("Правка".utf8).write(to: file)
        workspace.chooseImportFiles = { _ in [file] }
        var sawEncodingChoice = false
        workspace.resolveAmbiguousEncoding = { options, filename in
            sawEncodingChoice = true
            XCTAssertEqual(filename, file.lastPathComponent)
            XCTAssertEqual(options.map(\.encoding), [.utf8, .windows1251])
            return nil
        }
        await workspace.importRestoration(cardID)
        XCTAssertTrue(sawEncodingChoice)

        let oversized = root.appendingPathComponent("oversized.txt")
        try Data().write(to: oversized)
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(AnonymizationRestoration.maximumImportFileBytes + 1))
        try handle.close()
        workspace.chooseImportFiles = { _ in [oversized] }
        await workspace.importRestoration(cardID)
        XCTAssertEqual(workspace.model.errorHandler.messages.last,
                       L10n.message("Текст для обратного преобразования слишком большой для карточки"))

        pasteboard.clearContents()
        await workspace.pasteRestoration(cardID, pasteboard: pasteboard)
        XCTAssertEqual(workspace.model.errorHandler.messages.last, L10n.message("В буфере обмена нет текста."))
        let afterFailures = try await archive.loadCard(cardID)
        XCTAssertEqual(afterFailures.restoration, previous.restoration)
        XCTAssertNil(workspace.restorationBusyCardID)
        await workspace.model.shutdown()
    }

    func testImportKeepsMappingRevisionFromBeforeFilePanel() async throws {
        let (workspace, cardID, root) = try await makeWorkspace()
        let archive = try XCTUnwrap(workspace.model.textArchive)
        let file = root.appendingPathComponent("processed.txt")
        try (Data(TextImportDecoder.utf8BOM) + Data(substitute.utf8)).write(to: file)
        let before = try await archive.loadCard(cardID)
        workspace.chooseImportFiles = { [weak workspace] _ in
            await workspace?.cardEditor.applySourceEdit(.init(start: 0, end: 1, replacement: "A"))
            return [file]
        }

        await workspace.importRestoration(cardID)

        let after = try await archive.loadCard(cardID)
        XCTAssertNotEqual(after.source.id, before.source.id)
        XCTAssertEqual(after.publishedResult?.text.id, before.publishedResult?.text.id)
        XCTAssertNil(after.restoration)
        XCTAssertFalse(workspace.model.errorHandler.messages.isEmpty)
        await workspace.model.shutdown()
    }

    private func makeWorkspace(format: AnonymizationSourceFormat = .txt) async throws
        -> (AnonymizationWorkspaceModel, String, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let model = try makeModel(at: root)
        let archive = try XCTUnwrap(model.textArchive)
        let emphasis = format == .markdown ? "**" : ""
        let source = TextRevision(id: UUID().uuidString, text: emphasis + original + emphasis)
        let generated = TextRevision(id: UUID().uuidString, text: emphasis + substitute + emphasis)
        let offset = UInt(emphasis.unicodeScalars.count)
        let summary = try await archive.importCard(.init(bytes: Data(source.text.utf8), importedNameStem: "Отчёт",
                                                         sourceFormat: format, source: source))
        try await archive.updateCard(summary.id) { card in
            let input = RunInput(source: source, profileID: "anon", packageID: "package", dataTypes: ["ФИО"])
            let pair = ReplacementPair(sourceRange: .init(start: offset, end: UInt(source.text.unicodeScalars.count) - offset),
                                       resultRange: .init(start: offset, end: UInt(generated.text.unicodeScalars.count) - offset))
            card.latestAttempt = AnonymizationAttempt(state: .succeeded, input: input)
            card.publishedResult = AnonymizationResult(input: input, generatedText: generated, text: generated,
                                                       downloadNameStem: "Обезличенный отчёт", bodyReplacementCount: 1,
                                                       pairs: [pair])
        }
        await model.reloadTexts()
        return (await openCard(summary.id, in: model), summary.id, root)
    }

    private func makeModel(at root: URL) throws -> AppModel {
        let suite = "LocalScribeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return AppModel(repository: try RecordingRepository(root: root), startServices: false,
                        userDefaults: defaults, catalog: ModelCatalog(models: []))
    }

    private func openCard(_ cardID: String, in model: AppModel) async -> AnonymizationWorkspaceModel {
        let workspace = AnonymizationWorkspaceModel(model: model)
        workspace.selection = cardID
        await workspace.cardEditor.activate(cardID)
        return workspace
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition())
    }
}
