import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
@testable import LocalScribeCore
@testable import LocalScribe

/// The download of work 12 (AC-19, 32, 34, 39, 50): the menu appears with the
/// first published result, the format choice flushes the pending right-panel
/// edits and freezes an `AnonymizationExportSnapshot`, the save panel seam
/// proposes the import-based stem plus the chosen extension and may be
/// cancelled without a file, MARKDOWN keeps its markup in `.md` and degrades
/// to readable text in `.txt`, and every file is UTF-8 without BOM carrying
/// the edits saved before the capture — through the real supervisor and the
/// anonymization process fixture (Анна Петрова → Мария Сидорова).
@MainActor
final class AnonymizationDownloadTests: XCTestCase {

    private struct Fixture {
        let repository: RecordingRepository
        let catalog: ModelCatalog
        let model: AppModel
        let anon: ModelProfile
        let root: URL
        var release: URL { root.appendingPathComponent("release") }
    }

    private func fixture(_ root: URL) throws -> Fixture {
        var repo = try RecordingRepository(root: root)
        let executable = root.appendingPathComponent("worker.py")
        // The anonymization branch of the shared process fixture: reads
        // input.json, performs the deterministic «Анна Петрова» →
        // «Мария Сидорова» replacement with pair ranges, writes a fully valid
        // result.json (the download stem echoes the import name) and echoes
        // the kind in every protocol event.
        let script = #"""
        #!/usr/bin/python3
        import sys, json, pathlib, time, uuid
        c = json.loads(sys.stdin.readline())
        root = pathlib.Path(c['modelsPath']).parent
        def emit(kind, message=''):
            print(json.dumps(dict(version=1, jobId=c['jobId'], runId=c['runId'], kind=c.get('kind'), type=kind, message=message)), flush=True)
        with (root / 'events.jsonl').open('a') as f:
            f.write(json.dumps(c) + '\n')
        run = pathlib.Path(c['anonymizationPath'])
        if (root / 'text-fail').exists():
            emit('failed', 'Тестовая ошибка обезличивания')
            sys.exit(1)
        inp = json.loads((run / 'input.json').read_text())
        emit('progress', 'anon-ready-' + c['jobId'])
        value, substitute = 'Анна Петрова', 'Мария Сидорова'
        source = inp['source']['text']
        text = source.replace(value, substitute)
        pairs = []
        substitutions = list(inp.get('automaticSubstitutions') or [])
        si = ti = 0
        while si < len(source):
            if source.startswith(value, si):
                pairs.append(dict(sourceRange=dict(start=si, end=si + len(value)),
                                  resultRange=dict(start=ti, end=ti + len(substitute))))
                si += len(value); ti += len(substitute)
            else:
                si += 1; ti += 1
        if pairs and not any(s['sourceValue'] == value for s in substitutions):
            substitutions.append(dict(dataType=inp['dataTypes'][0], sourceValue=value, substituteValue=substitute))
        generatedID = str(uuid.uuid4())
        result = dict(schemaVersion=1,
            input=dict(source=inp['source'], profileID=inp['profileID'], packageID=inp['packageID'], dataTypes=inp['dataTypes']),
            generatedText=dict(id=generatedID, text=text),
            text=dict(id=generatedID, text=text),
            downloadNameStem=inp['importedNameStem'],
            bodyReplacementCount=len(pairs),
            pairs=pairs,
            warnings=[])
        (run / 'result.json').write_text(json.dumps(dict(schemaVersion=1, result=result, substitutions=substitutions)))
        while not (root / 'release').exists() or (root / ('hold-' + c['jobId'])).exists():
            time.sleep(0.02)
        emit('completed')
        sys.exit(0)
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        var anon = ModelProfile(id: "anon-llm", repository: "test/anon", revision: "test-revision", license: "test",
                                files: [], role: nil, recommendedMemoryGB: 8, workingMemoryGB: 2,
                                supportedTasks: [.anonymization])
        var anonB = ModelProfile(id: "anon-b", repository: "test/anon-b", revision: "test-revision", license: "test",
                                 files: [], role: nil, recommendedMemoryGB: 8, workingMemoryGB: 2,
                                 supportedTasks: [.anonymization])
        for source in [anon, anonB] {
            let data = Data(source.id.utf8)
            let folder = repo.models.appendingPathComponent(source.id)
            try Disk.directory(folder)
            let file = folder.appendingPathComponent("weights.bin")
            try data.write(to: file)
            let files = [ModelFile(path: "weights.bin", localPath: "weights.bin",
                                   size: Int64(data.count), sha256: try Disk.hash(file))]
            if source.id == anon.id { anon.files = files } else { anonB.files = files }
        }
        let catalog = ModelCatalog(models: [anon, anonB])
        let suite = "LocalScribeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(repository: repo, startServices: false, workerExecutable: executable,
                             userDefaults: defaults, catalog: catalog)
        for profile in [anon, anonB] { model.modelLibrary.installed(profile, catalog: catalog) }
        return Fixture(repository: repo, catalog: catalog, model: model, anon: anon, root: root)
    }

    // MARK: - Helpers

    private func waitUntil(_ predicate: @MainActor @Sendable () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !(try await predicate()) && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let final = try await predicate()
        XCTAssertTrue(final)
    }
    private func waitUntilCard(_ model: AppModel, _ id: String,
                               state: AnonymizationAttemptState) async throws {
        try await waitUntil { [model] in
            guard let archive = model.textArchive else { return false }
            return ((try? await archive.loadCard(id))?.latestAttempt.state) == state
        }
    }
    @discardableResult
    private func loadCard(_ model: AppModel, _ id: String) async throws -> AnonymizationCardDocument {
        try await XCTUnwrap(model.textArchive).loadCard(id)
    }
    /// Import through the archive plus the queue hook of the workspace import
    /// pipeline; the bytes and the import format are caller-defined so
    /// Windows-1251/UTF-16 identities and Markdown cards stay faithful.
    @discardableResult
    private func importCard(_ fixture: Fixture, name: String, text: String,
                            format: AnonymizationSourceFormat = .txt, bytes: Data? = nil) async throws -> String {
        let archive = try XCTUnwrap(fixture.model.textArchive)
        let summary = try await archive.importCard(
            .init(bytes: bytes ?? Data(text.utf8), importedNameStem: name, sourceFormat: format,
                  source: TextRevision(id: UUID().uuidString, text: text)))
        await fixture.model.reloadTexts()
        await fixture.model.enqueueText(summary.id)
        return summary.id
    }
    private func assign(_ fixture: Fixture, profile: ModelProfile) async throws {
        let draft = SettingsDraft(model: fixture.model)
        draft.anonymizationProfileID = profile.id
        try fixture.model.applySettings(draft)
        await fixture.model.reloadAnonymizationState()
    }
    /// One download through the panel seam: the URL is "confirmed" instantly.
    private func download(_ workspace: AnonymizationWorkspaceModel, card: String,
                          format: AnonymizationTextDownloadFormat, to url: URL) async throws {
        workspace.chooseDownloadURL = { _ in url }
        await workspace.performTextDownload(card, format: format)
        try await waitUntil { FileManager.default.fileExists(atPath: url.path) }
    }
    private func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
    /// Appends `addition` to the card's current right version through the
    /// editor's own commit path (work 7 serialization).
    private func appendToResult(_ editor: AnonymizationCardEditor, _ model: AppModel,
                                card id: String, _ addition: String) async throws {
        let loaded = try await loadCard(model, id)
        let text = try XCTUnwrap(loaded.publishedResult?.text.text)
        let end = UInt(text.unicodeScalars.count)
        await editor.applyResultEdit(ScalarEdit(start: end, end: end, replacement: addition))
    }

    // MARK: - Criterion 19: availability, both formats open the panel, cancellation

    func testDownloadHiddenBeforeFirstSuccessBothFormatsOpenPanelAndCancelCreatesNoFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try fixture(root)
        let model = fixture.model
        let id = try await importCard(fixture, name: "Отчёт", text: "Отчёт: Анна Петрова позвонила.")
        let workspace = AnonymizationWorkspaceModel(model: model)
        workspace.selection = id
        try await waitUntil { workspace.cardEditor.sourcePanel != nil }
        // The handler of work 12 is attached, but the menu itself is absent
        // before the first successful result (AC-19: unavailable).
        XCTAssertNotNil(workspace.requestTextDownload)
        let (view, window) = host(AnonymizationDetailColumn(workspace: workspace))
        defer { window.close() }
        try await settle(view)
        XCTAssertNil(findElement("texts.detail.download", in: view))
        // A direct call without a published result opens no panel.
        let downloads = root.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        var suggestions: [String] = []
        workspace.chooseDownloadURL = { snapshot in
            suggestions.append(snapshot.suggestedFilename)
            return nil
        }
        await workspace.performTextDownload(id, format: .markdown)
        XCTAssertTrue(suggestions.isEmpty, "no published result means no panel")

        try await assign(fixture, profile: fixture.anon)
        try Data().write(to: fixture.release)
        try await waitUntilCard(model, id, state: .succeeded)
        try await waitUntil { workspace.cardEditor.hasPublishedResult }
        try await settle(view)
        _ = try element("texts.detail.download", in: view)

        // After the success both formats open the panel with the suggested
        // name of the chosen extension; cancelling each leaves no file.
        workspace.requestTextDownload?(id, .markdown)
        try await waitUntil { suggestions.count == 1 }
        workspace.requestTextDownload?(id, .plainText)
        try await waitUntil { suggestions.count == 2 }
        XCTAssertEqual(suggestions, ["Отчёт.md", "Отчёт.txt"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: downloads.path), [],
                       "отмена панели не создаёт файл")
        await model.shutdown()
    }

    // MARK: - Criterion 19 (freeze): before/after the snapshot capture

    func testEditsBeforeFormatChoiceAreExportedAndPostCaptureEditsWaitForNextExport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try fixture(root)
        let model = fixture.model
        try await assign(fixture, profile: fixture.anon)
        let id = try await importCard(fixture, name: "Отчёт", text: "Отчёт: Анна Петрова позвонила.")
        try Data().write(to: fixture.release)
        try await waitUntilCard(model, id, state: .succeeded)
        let workspace = AnonymizationWorkspaceModel(model: model)
        workspace.selection = id
        try await waitUntil { workspace.cardEditor.hasPublishedResult }
        // An edit saved before the format choice (the editor's commit path).
        try await appendToResult(workspace.cardEditor, model, card: id, " Проверено.")
        // Inside the panel seam the snapshot is already frozen: an edit saved
        // now belongs to the next export only.
        let archive = try XCTUnwrap(model.textArchive)
        let downloads = root.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let first = downloads.appendingPathComponent("first.md")
        workspace.chooseDownloadURL = { _ in
            _ = try? await archive.editResult(id, ScalarEdit(start: 0, end: 0, replacement: "ПОЗДНЯЯ "))
            return first
        }
        await workspace.performTextDownload(id, format: .markdown)
        try await waitUntil { FileManager.default.fileExists(atPath: first.path) }
        let frozen = try read(first)
        XCTAssertTrue(frozen.contains(" Проверено."), "правка до выбора формата входит в файл")
        XCTAssertTrue(frozen.contains("Мария Сидорова"))
        XCTAssertFalse(frozen.contains("ПОЗДНЯЯ"), "правка после захвата снимка в файл не попадает")
        // The next download picks the late edit up.
        let second = downloads.appendingPathComponent("second.md")
        workspace.chooseDownloadURL = { _ in second }
        await workspace.performTextDownload(id, format: .markdown)
        try await waitUntil { FileManager.default.fileExists(atPath: second.path) }
        XCTAssertTrue(try read(second).contains("ПОЗДНЯЯ"))
        await model.shutdown()
    }

    // MARK: - Criterion 32: MARKDOWN markup in .md, readable text in .txt, TXT verbatim

    func testEditedMarkdownKeepsMarkupForMdAndDegradesForTxtAndTxtStaysVerbatim() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try fixture(root)
        let model = fixture.model
        try await assign(fixture, profile: fixture.anon)
        let markdown = "# Заголовок отчёта\n\nСлово о **выделение** и [ссылка](https://example.org).\n\nПодготовила Анна Петрова."
        let mdCard = try await importCard(fixture, name: "Отчёт", text: markdown, format: .markdown)
        let txtCard = try await importCard(fixture, name: "Заметка", text: markdown, format: .txt)
        try Data().write(to: fixture.release)
        try await waitUntilCard(model, mdCard, state: .succeeded)
        try await waitUntilCard(model, txtCard, state: .succeeded)
        let workspace = AnonymizationWorkspaceModel(model: model)
        let downloads = root.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)

        // A manually edited Markdown result (AC-32 speaks of the edited text).
        workspace.selection = mdCard
        try await waitUntil { workspace.cardEditor.hasPublishedResult }
        try await appendToResult(workspace.cardEditor, model, card: mdCard, " Финальная правка.")
        let mdLoaded = try await loadCard(model, mdCard)
        let currentMD = try XCTUnwrap(mdLoaded.publishedResult?.text.text)
        let mdFile = downloads.appendingPathComponent("out.md")
        try await download(workspace, card: mdCard, format: .markdown, to: mdFile)
        XCTAssertEqual(try read(mdFile), currentMD, ".md сохраняет текущую разметку дословно")
        let savedMarkdown = try read(mdFile)
        XCTAssertTrue(savedMarkdown.contains("**выделение**"))
        XCTAssertTrue(savedMarkdown.contains("[ссылка](https://example.org)"))

        let txtFile = downloads.appendingPathComponent("out.txt")
        try await download(workspace, card: mdCard, format: .plainText, to: txtFile)
        let degraded = try read(txtFile)
        XCTAssertTrue(degraded.contains("Заголовок отчёта"))
        XCTAssertFalse(degraded.contains("#"), "заголовок без служебного маркера")
        XCTAssertTrue(degraded.contains("выделение"))
        XCTAssertFalse(degraded.contains("**"), "выделение без служебного маркера")
        XCTAssertTrue(degraded.contains("ссылка (https://example.org)"), "видимая подпись ссылки")
        XCTAssertFalse(degraded.contains("](") || degraded.contains("["), "квадратные скобки ссылки уходят")
        XCTAssertTrue(degraded.contains("Финальная правка"), "ручная правка входит в .txt")
        XCTAssertTrue(degraded.contains("Мария Сидорова"), "замены сохранены")

        // A TXT card keeps its current text in both formats verbatim.
        workspace.selection = txtCard
        try await waitUntil { workspace.cardEditor.hasPublishedResult }
        try await appendToResult(workspace.cardEditor, model, card: txtCard, " Дополнительная строка")
        let txtLoaded = try await loadCard(model, txtCard)
        let currentTXT = try XCTUnwrap(txtLoaded.publishedResult?.text.text)
        let txtAsMd = downloads.appendingPathComponent("note.md")
        let txtAsTxt = downloads.appendingPathComponent("note.txt")
        try await download(workspace, card: txtCard, format: .markdown, to: txtAsMd)
        try await download(workspace, card: txtCard, format: .plainText, to: txtAsTxt)
        XCTAssertEqual(try read(txtAsMd), currentTXT)
        XCTAssertEqual(try read(txtAsTxt), currentTXT)
        await model.shutdown()
    }

    // MARK: - Criteria 34/39: suggested name from the import stem, changeable in the panel

    func testSuggestedNameIsFileComponentFromImportStemAndUserCanChangeIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try fixture(root)
        let model = fixture.model
        try await assign(fixture, profile: fixture.anon)
        let id = try await importCard(fixture, name: "Анна Петрова отчёт", text: "Отчёт: Анна Петрова.")
        try Data().write(to: fixture.release)
        try await waitUntilCard(model, id, state: .succeeded)
        // The archive rename changes the shown title but not the suggested
        // download name (AC-39: the stem follows the imported name).
        await model.renameTextCard(id, to: "Переименованный отчёт")
        let workspace = AnonymizationWorkspaceModel(model: model)
        workspace.selection = id
        try await waitUntil { workspace.cardEditor.hasPublishedResult }
        let downloads = root.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        var suggestions: [String] = []
        workspace.chooseDownloadURL = { snapshot in
            suggestions.append(snapshot.suggestedFilename)
            return nil
        }
        await workspace.performTextDownload(id, format: .markdown)
        await workspace.performTextDownload(id, format: .plainText)
        XCTAssertEqual(suggestions, ["Анна Петрова отчёт.md", "Анна Петрова отчёт.txt"])
        for suggestion in suggestions {
            let stem = String(suggestion.dropLast(4))
            XCTAssertFalse(stem.isEmpty || stem == "." || stem == "..", "допустимый файловый компонент")
            XCTAssertFalse(stem.contains("/"))
        }
        XCTAssertTrue(suggestions[0].hasSuffix(".md") && suggestions[1].hasSuffix(".txt"),
                      "имя содержит выбранное расширение")
        // The user picks another name for this download: the file lands there.
        let changed = downloads.appendingPathComponent("Моё имя.md")
        try await download(workspace, card: id, format: .markdown, to: changed)
        XCTAssertTrue(try read(changed).contains("Мария Сидорова"))
        await model.shutdown()
    }

    // MARK: - Criterion 50: Windows-1251 and UTF-16 imports export as UTF-8 with edits

    func testWindows1251AndUTF16ImportsDownloadAsUTF8WithEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try fixture(root)
        let model = fixture.model
        try await assign(fixture, profile: fixture.anon)
        let source = "Отчёт: Анна Петрова.\nВторая строка."
        let winBytes = try XCTUnwrap(source.data(using: .windowsCP1251))
        let utf16Bytes = try XCTUnwrap(source.data(using: .utf16))
        let winCard = try await importCard(fixture, name: "win1251", text: source, bytes: winBytes)
        let utf16Card = try await importCard(fixture, name: "utf16", text: source, bytes: utf16Bytes)
        try Data().write(to: fixture.release)
        try await waitUntilCard(model, winCard, state: .succeeded)
        try await waitUntilCard(model, utf16Card, state: .succeeded)
        let workspace = AnonymizationWorkspaceModel(model: model)
        let archive = try XCTUnwrap(model.textArchive)
        let downloads = root.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        for (index, card) in [winCard, utf16Card].enumerated() {
            // A manual edit with Russian and English characters (AC-50).
            let loaded = try await loadCard(model, card)
            let text = try XCTUnwrap(loaded.publishedResult?.text.text)
            let end = UInt(text.unicodeScalars.count)
            _ = try await archive.editResult(card, ScalarEdit(start: end, end: end,
                                                              replacement: " Дозапись appendix"))
            for format in [AnonymizationTextDownloadFormat.markdown, .plainText] {
                let url = downloads.appendingPathComponent("file-\(index).\(format.rawValue)")
                try await download(workspace, card: card, format: format, to: url)
                let data = try Data(contentsOf: url)
                XCTAssertFalse(data.starts(with: [0xEF, 0xBB, 0xBF]), "UTF-8 без BOM")
                let downloaded = try XCTUnwrap(String(data: data, encoding: .utf8), "читается как UTF-8")
                XCTAssertTrue(downloaded.contains("Дозапись appendix"), "правка входит в файл")
                XCTAssertTrue(downloaded.contains("Мария Сидорова"))
            }
        }
        await model.shutdown()
    }

    // MARK: - View helpers

    private func descendants(_ element: AnyObject) -> [AnyObject] {
        let children = (element.accessibilityChildren?() ?? []).map { $0 as AnyObject }
        return children + children.flatMap { descendants($0) }
    }
    private func subviews(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap { subviews($0) } }
    private func findElement(_ id: String, in view: NSView) -> AnyObject? {
        if let element = descendants(view).first(where: { $0.accessibilityIdentifier?() == id }) { return element }
        for subview in subviews(view) {
            if let element = descendants(subview).first(where: { $0.accessibilityIdentifier?() == id }) {
                return element
            }
        }
        return nil
    }
    private func element(_ id: String, in view: NSView) throws -> AnyObject {
        try XCTUnwrap(findElement(id, in: view), id)
    }
    private func host<V: View>(_ view: V) -> (NSHostingView<V>, NSWindow) {
        _ = NSApplication.shared
        NSApplication.shared.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting
        window.makeKeyAndOrderFront(nil); hosting.layoutSubtreeIfNeeded()
        return (hosting, window)
    }
    private func settle(_ view: NSView) async throws {
        try await Task.sleep(for: .milliseconds(180)); view.layoutSubtreeIfNeeded()
    }
}
