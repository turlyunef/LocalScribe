import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
@testable import LocalScribeCore
@testable import LocalScribe

/// SwiftUI of this SDK also exports a `TextRange`; the archive scalar range is
/// always the LocalScribeCore one.
private typealias TextRange = LocalScribeCore.TextRange

/// The anonymization card editor of work 10: two panels reading and editing
/// through AnonymizationCardEditor (work 7 commits, work 9 queue), pair
/// highlighting prepared off the main actor, warnings with review jumps,
/// status/failure notices and consent-bound retry — through the real
/// supervisor and a process fixture that honestly performs the anonymization
/// contract. Acceptance criteria 14–18, 28, 38–39, 42 (display), 44, 46–47.
@MainActor
final class AnonymizationCardEditorTests: XCTestCase {

    private struct Fixture {
        let repository: RecordingRepository
        let catalog: ModelCatalog
        let model: AppModel
        let anon: ModelProfile
        let anonB: ModelProfile
        let root: URL
        var release: URL { root.appendingPathComponent("release") }
    }

    private func fixture(_ root: URL) throws -> Fixture {
        var repo = try RecordingRepository(root: root)
        let executable = root.appendingPathComponent("worker.py")
        // The anonymization branch of the shared process fixture: reads
        // input.json, performs the deterministic «Анна Петрова» →
        // «Мария Сидорова» replacement with pair ranges, writes a fully valid
        // result.json and echoes the kind in every protocol event.
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
        if (root / 'text-corrupt-result').exists():
            (run / 'result.json').write_text('broken result')
        else:
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
        return Fixture(repository: repo, catalog: catalog, model: model, anon: anon, anonB: anonB, root: root)
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
    @discardableResult
    private func importCard(_ fixture: Fixture, name: String, text: String) async throws -> String {
        let archive = try XCTUnwrap(fixture.model.textArchive)
        let summary = try await archive.importCard(
            .init(bytes: Data(text.utf8), importedNameStem: name, sourceFormat: .txt,
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
    /// Direct saved-record change used to drop readiness (uninstalled profile)
    /// while the queue is idle.
    private func saveAssignment(_ fixture: Fixture, profile: ModelProfile) async throws {
        var settings = fixture.model.anonymizationSettings
        settings.setProfile(profile.id, for: .anonymization)
        try AnonymizationSettingsStore(root: fixture.repository.root).save(settings)
        await fixture.model.reloadAnonymizationState()
    }
    /// Scalar range of `needle` in `haystack` (counted in Unicode scalars).
    private func scalarRange(of needle: String, in haystack: String) -> TextRange? {
        let scalars = Array(haystack.unicodeScalars)
        let needle = Array(needle.unicodeScalars)
        guard scalars.count >= needle.count, !needle.isEmpty else { return nil }
        for start in 0...(scalars.count - needle.count) where scalars[start..<(start + needle.count)].elementsEqual(needle) {
            return TextRange(start: UInt(start), end: UInt(start + needle.count))
        }
        return nil
    }
    private func makeDefaults() throws -> UserDefaults {
        let suite = "LocalScribeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    // MARK: - Criterion 14/15: reading, the no-result state, the no-matches message

    func testSourceReadsBeforeSuccessRightShowsPlaceholderAndNoMatchesMessage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try fixture(root)
        let model = fixture.model
        let original = "Обычный отчёт без совпадений."
        let id = try await importCard(fixture, name: "Пустой отчёт", text: original)
        let workspace = AnonymizationWorkspaceModel(model: model)
        let editor = workspace.cardEditor
        workspace.selection = id
        try await waitUntil { editor.sourcePanel != nil }
        // Left panel reads the saved source; the right panel has no result yet.
        let saved = try await loadCard(model, id)
        XCTAssertEqual(editor.sourcePanel?.text, original)
        XCTAssertEqual(editor.sourcePanel?.revisionID, saved.source.id)
        XCTAssertNil(editor.resultPanel)
        XCTAssertFalse(editor.hasPublishedResult)
        XCTAssertTrue(editor.sourceEditable, "waiting for the model keeps the source editable")
        XCTAssertFalse(editor.resultEditable)
        // Hosted card: the right panel shows its pre-result state (AC-15).
        let (view, window) = host(AnonymizationDetailColumn(workspace: workspace))
        defer { window.close() }
        try await settle(view)
        _ = try element("texts.detail.resultPlaceholder", in: view)
        _ = try element("texts.detail.source", in: view)
        _ = try element("texts.detail.result", in: view)
        // A successful run without matches shows the full text plus the
        // message; the name-only case behaves the same (AC-14).
        try await assign(fixture, profile: fixture.anon)
        try Data().write(to: fixture.release)
        try await waitUntilCard(model, id, state: .succeeded)
        try await waitUntil { editor.resultPanel != nil }
        XCTAssertEqual(editor.resultPanel?.text, original)
        XCTAssertTrue(editor.showsNoMatchesMessage)
        XCTAssertEqual(editor.resultPanel?.highlights, [])
        // Only the imported name was anonymized here: still the same message.
        _ = try await model.textArchive!.updateCard(id) { card in
            guard var result = card.publishedResult else { return }
            result.downloadNameStem = "Обезличенное имя"
            result.bodyReplacementCount = 0
            result.pairs = []
            card.publishedResult = result
        }
        await model.reloadTexts()
        try await waitUntil { editor.showsNoMatchesMessage }
        await model.shutdown()
    }

    // MARK: - Criterion 15/16: edits survive card switching and a restart

    func testEditsOfBothPanelsSurviveSwitchAndRestartAndOriginalBytesStay() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try fixture(root)
        let model = fixture.model
        try await assign(fixture, profile: fixture.anon)
        let original = "Отчёт: Анна Петрова позвонила."
        let id = try await importCard(fixture, name: "Отчёт", text: original)
        let other = try await importCard(fixture, name: "Другой", text: "Другой отчёт Анна Петрова")
        try Data().write(to: fixture.release)
        try await waitUntilCard(model, id, state: .succeeded)
        try await waitUntilCard(model, other, state: .succeeded)
        let workspace = AnonymizationWorkspaceModel(model: model)
        let editor = workspace.cardEditor
        workspace.selection = id
        try await waitUntil { editor.resultPanel != nil }
        // Edits of both panels commit through the editor (AC-16).
        await editor.applySourceEdit(ScalarEdit(start: 0, end: 0, replacement: "Правка. "))
        await editor.applyResultEdit(ScalarEdit(start: 0, end: 0, replacement: "Итог. "))
        XCTAssertTrue(editor.document!.source.text.hasPrefix("Правка. "))
        XCTAssertTrue(editor.document!.publishedResult!.text.text.hasPrefix("Итог. "))
        XCTAssertTrue(editor.resultManuallyEdited)
        XCTAssertTrue(editor.resultBuiltFromEarlierSource)
        // The archived import bytes never change — the Finder original of the
        // import identity stays byte-identical.
        var card = try await loadCard(model, id)
        XCTAssertEqual(card.importContentIdentity.bytes, Data(original.utf8))
        // Switching cards and coming back keeps the saved edits.
        workspace.selection = other
        try await waitUntil { editor.sourcePanel?.text.hasPrefix("Другой") == true }
        workspace.selection = id
        try await waitUntil { editor.sourcePanel?.text.hasPrefix("Правка. ") == true }
        XCTAssertEqual(editor.resultPanel?.text, "Итог. Отчёт: Мария Сидорова позвонила.")
        // A fresh model over the same root (restart) shows the same versions.
        card = try await loadCard(model, id)
        let defaults2 = try makeDefaults()
        let model2 = AppModel(repository: try RecordingRepository(root: root), startServices: false,
                              workerExecutable: root.appendingPathComponent("worker.py"),
                              userDefaults: defaults2, catalog: fixture.catalog)
        for profile in fixture.catalog.models { model2.modelLibrary.installed(profile, catalog: fixture.catalog) }
        _ = try await model2.textArchive?.recover()
        await model2.reloadTexts()
        let editor2 = AnonymizationCardEditor(model: model2)
        await editor2.activate(id)
        try await waitUntil { editor2.resultPanel != nil }
        XCTAssertEqual(editor2.sourcePanel?.text, card.source.text)
        XCTAssertEqual(editor2.resultPanel?.text, "Итог. Отчёт: Мария Сидорова позвонила.")
        XCTAssertTrue(editor2.resultManuallyEdited)
        await model.shutdown()
        await model2.shutdown()
    }

    // MARK: - Criterion 17: the earlier-source notice; the retry takes the version at command

    func testEarlierSourceNoticeAndRetryTakesVersionAtCommandOnly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try fixture(root)
        let model = fixture.model
        try await assign(fixture, profile: fixture.anon)
        let id = try await importCard(fixture, name: "Отчёт", text: "Отчёт: Анна Петрова позвонила.")
        try Data().write(to: fixture.release)
        try await waitUntilCard(model, id, state: .succeeded)
        let workspace = AnonymizationWorkspaceModel(model: model)
        let editor = workspace.cardEditor
        workspace.selection = id
        try await waitUntil { editor.resultPanel != nil }
        XCTAssertFalse(editor.resultBuiltFromEarlierSource)
        // A left edit never starts a job by itself; the result is only marked
        // as built from an earlier source (AC-17).
        let attemptID = editor.document?.latestAttempt.id
        await editor.applySourceEdit(ScalarEdit(start: 0, end: 0, replacement: "Правка. "))
        XCTAssertTrue(editor.resultBuiltFromEarlierSource)
        XCTAssertEqual(editor.document?.latestAttempt.id, attemptID)
        XCTAssertEqual(model.textCard(id)?.attemptState, .succeeded)
        XCTAssertNil(model.textQueuePosition(for: id))
        // The explicit retry freezes the edited version at the command.
        editor.confirmReplaceEditedResult = { _ in false } // unedited right side: no dialog expected
        try FileManager.default.removeItem(at: fixture.release)
        try Data().write(to: root.appendingPathComponent("hold-" + id))
        await editor.retry()
        try await waitUntilCard(model, id, state: .running)
        let attempt = try await loadCard(model, id).latestAttempt
        XCTAssertEqual(attempt.input?.source.text, "Правка. Отчёт: Анна Петрова позвонила.")
        try Data().write(to: fixture.release)
        try FileManager.default.removeItem(at: root.appendingPathComponent("hold-" + id))
        try await waitUntilCard(model, id, state: .succeeded)
        try await waitUntil { !editor.resultBuiltFromEarlierSource }
        XCTAssertEqual(editor.document?.publishedResult?.input.source.text, "Правка. Отчёт: Анна Петрова позвонила.")
        await model.shutdown()
    }

    // MARK: - Criterion 18: consent for the edited result; stale completion keeps the current text

    func testConsentFlowForEditedResultAndStaleCompletionKeepsCurrentRightText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try fixture(root)
        let model = fixture.model
        try await assign(fixture, profile: fixture.anon)
        let id = try await importCard(fixture, name: "Отчёт", text: "Отчёт: Анна Петрова позвонила.")
        try Data().write(to: fixture.release)
        try await waitUntilCard(model, id, state: .succeeded)
        let workspace = AnonymizationWorkspaceModel(model: model)
        let editor = workspace.cardEditor
        workspace.selection = id
        try await waitUntil { editor.resultPanel != nil }
        // A manual right edit makes the consent dialog necessary; a refusal
        // keeps the text and starts nothing (AC-18).
        await editor.applyResultEdit(ScalarEdit(start: 0, end: 1, replacement: "Ё"))
        let editedText = editor.document?.publishedResult?.text.text
        let attemptID = editor.document?.latestAttempt.id
        editor.confirmReplaceEditedResult = { _ in false }
        await editor.retry()
        XCTAssertEqual(editor.document?.latestAttempt.id, attemptID)
        XCTAssertEqual(editor.document?.latestAttempt.state, .succeeded)
        XCTAssertEqual(editor.resultPanel?.text, editedText)
        // The agreement asks for the current revision id and the retry runs.
        var agreedRevision: String?
        editor.confirmReplaceEditedResult = { revision in agreedRevision = revision; return true }
        try FileManager.default.removeItem(at: fixture.release)
        try Data().write(to: root.appendingPathComponent("hold-" + id))
        await editor.retry()
        try await waitUntilCard(model, id, state: .running)
        XCTAssertEqual(agreedRevision, editor.document?.publishedResult?.text.id)
        // A further right edit makes the agreed version stale: the completion
        // for that attempt must fail and keep the current right text.
        _ = try await model.textArchive?.editResult(id, ScalarEdit(start: 0, end: 1, replacement: "Э"))
        try Data().write(to: fixture.release)
        try FileManager.default.removeItem(at: root.appendingPathComponent("hold-" + id))
        try await waitUntilCard(model, id, state: .failed)
        try await waitUntil { editor.failureText != nil }
        XCTAssertEqual(editor.failureIsSizeLimit, false)
        XCTAssertTrue(editor.resultPanel?.text.hasPrefix("Э") == true, "the newest right version stays")
        XCTAssertTrue(editor.hasPublishedResult)
        await model.shutdown()
    }

    // MARK: - Criterion 38: read-only while queued/running, editable after every outcome

    func testPanelsLockedWhileQueuedAndRunningAndEditableAfterEachOutcome() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try fixture(root)
        let model = fixture.model
        try await assign(fixture, profile: fixture.anon)
        let running = try await importCard(fixture, name: "running", text: "Обработка: Анна Петрова")
        try await waitUntilCard(model, running, state: .running)
        let queued = try await importCard(fixture, name: "queued", text: "Очередь: Анна Петрова")
        XCTAssertEqual(model.textCard(queued)?.attemptState, .queued)
        let workspace = AnonymizationWorkspaceModel(model: model)
        let editor = workspace.cardEditor
        workspace.selection = queued
        try await waitUntil { editor.sourcePanel != nil }
        // QUEUED and RUNNING lock both panels to reading and copying.
        XCTAssertTrue(editor.panelsLocked)
        XCTAssertFalse(editor.sourceEditable)
        XCTAssertFalse(editor.resultEditable)
        try Data().write(to: fixture.release)
        try await waitUntilCard(model, queued, state: .succeeded)
        try await waitUntil { editor.sourceEditable && editor.resultEditable }
        // A failed attempt also frees the editor.
        try Data().write(to: root.appendingPathComponent("text-fail"))
        let failed = try await importCard(fixture, name: "failed", text: "Ошибка: Анна Петрова")
        try await waitUntilCard(model, failed, state: .failed)
        workspace.selection = failed
        try await waitUntil { editor.sourcePanel?.text.hasPrefix("Ошибка") == true }
        XCTAssertTrue(editor.sourceEditable)
        XCTAssertNotNil(editor.failureText)
        // A cancelled attempt does too.
        try FileManager.default.removeItem(at: root.appendingPathComponent("text-fail"))
        try Data().write(to: root.appendingPathComponent("hold-cancelled"))
        let cancelled = try await importCard(fixture, name: "cancelled", text: "Отмена: Анна Петрова")
        try await waitUntilCard(model, cancelled, state: .running)
        await model.cancelTextCard(cancelled)
        try await waitUntilCard(model, cancelled, state: .cancelled)
        workspace.selection = cancelled
        try await waitUntil { editor.sourcePanel?.text.hasPrefix("Отмена") == true }
        XCTAssertTrue(editor.sourceEditable)
        // A retry of a succeeded card that returns to «Ожидает модель» keeps
        // the source editable while the right panel stays read-only until the
        // retry resolves (AC-17/38).
        try await saveAssignment(fixture, profile: fixture.anonB)
        workspace.selection = queued
        try await waitUntil { editor.resultPanel != nil }
        await editor.retry()
        try await waitUntil { editor.pendingRetryWaitsForModel }
        XCTAssertTrue(editor.sourceEditable)
        XCTAssertFalse(editor.resultEditable)
        XCTAssertTrue(editor.showsPreviousResultDuringRun)
        await model.shutdown()
    }

    // MARK: - Criterion 28: paired highlights in both versions

    func testPairedHighlightsInBothVersionsWithMatchingSlices() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try fixture(root)
        let model = fixture.model
        try await assign(fixture, profile: fixture.anon)
        let text = "Анна Петрова начала. В конце снова Анна Петрова."
        let id = try await importCard(fixture, name: "Отчёт", text: text)
        try Data().write(to: fixture.release)
        try await waitUntilCard(model, id, state: .succeeded)
        let workspace = AnonymizationWorkspaceModel(model: model)
        let editor = workspace.cardEditor
        workspace.selection = id
        try await waitUntil { editor.resultPanel != nil }
        XCTAssertEqual(editor.sourcePanel?.highlightSlices, ["Анна Петрова", "Анна Петрова"])
        XCTAssertEqual(editor.resultPanel?.highlightSlices, ["Мария Сидорова", "Мария Сидорова"])
        // The visible UTF-16 ranges resolve to exactly the replaced fragments.
        for highlight in editor.sourcePanel!.highlights {
            XCTAssertEqual((editor.sourcePanel!.text as NSString).substring(with: highlight.nsRange), "Анна Петрова")
        }
        for highlight in editor.resultPanel!.highlights {
            XCTAssertEqual((editor.resultPanel!.text as NSString).substring(with: highlight.nsRange), "Мария Сидорова")
        }
        // The hosted editor carries the tint as a background attribute on the
        // pair ranges (the shade itself is verified in the finished .app).
        let (view, window) = host(AnonymizationDetailColumn(workspace: workspace))
        defer { window.close() }
        try await settle(view)
        let resultView = try XCTUnwrap(textViews(in: view).first { $0.string == editor.resultPanel?.text })
        let first = try XCTUnwrap(editor.resultPanel?.highlights.first)
        XCTAssertNotNil(resultView.textStorage?.attribute(.backgroundColor, at: first.nsRange.location, effectiveRange: nil),
                        "the blue-accent background is applied to the pair range")
        // A fresh editor (reopen) shows the same pairs; a right edit keeps them.
        let reopened = AnonymizationCardEditor(model: model)
        await reopened.activate(id)
        try await waitUntil { reopened.resultPanel != nil }
        XCTAssertEqual(reopened.resultPanel?.highlightSlices, ["Мария Сидорова", "Мария Сидорова"])
        await editor.applyResultEdit(ScalarEdit(start: 0, end: 0, replacement: "Итог. "))
        try await waitUntil { editor.resultPanel?.highlightSlices.count == 2 }
        XCTAssertEqual(editor.resultPanel?.highlightSlices, ["Мария Сидорова", "Мария Сидорова"])
        await model.shutdown()
    }

    // MARK: - Criterion 44: a confirmed retry replaces the pairs with its own

    func testRetryReplacesPairsWithNewRunAndReusesSubstitutionHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try fixture(root)
        let model = fixture.model
        try await assign(fixture, profile: fixture.anon)
        let id = try await importCard(fixture, name: "Отчёт", text: "Отчёт: Анна Петрова")
        try Data().write(to: fixture.release)
        try await waitUntilCard(model, id, state: .succeeded)
        let workspace = AnonymizationWorkspaceModel(model: model)
        let editor = workspace.cardEditor
        workspace.selection = id
        try await waitUntil { editor.resultPanel?.highlightSlices.count == 1 }
        // The source gains a second occurrence; the retry pairs follow the new
        // run, while the automatic substitution history is reused.
        let original = "Отчёт: Анна Петрова"
        await editor.applySourceEdit(ScalarEdit(start: UInt(original.unicodeScalars.count),
                                                end: UInt(original.unicodeScalars.count),
                                                replacement: " и ещё Анна Петрова в конце."))
        XCTAssertTrue(editor.resultBuiltFromEarlierSource)
        editor.confirmReplaceEditedResult = { _ in false }
        await editor.retry()
        try await waitUntil { editor.document?.latestAttempt.state == .succeeded && !editor.resultBuiltFromEarlierSource }
        try await waitUntil { editor.resultPanel?.highlightSlices.count == 2 }
        XCTAssertEqual(editor.resultPanel?.highlightSlices, ["Мария Сидорова", "Мария Сидорова"])
        XCTAssertEqual(editor.sourcePanel?.highlightSlices, ["Анна Петрова", "Анна Петрова"])
        XCTAssertEqual(editor.document?.publishedResult?.bodyReplacementCount, 2)
        XCTAssertEqual(editor.document?.automaticSubstitutions.count, 1, "the returning value reuses its substitution")
        await model.shutdown()
    }

    // MARK: - Criterion 46: warnings with review places survive a failed retry

    func testWarningsShownWithJumpAndKeptAfterFailedRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try fixture(root)
        let model = fixture.model
        try await assign(fixture, profile: fixture.anon)
        let original = "Отчёт: Анна Петрова позвонила."
        let id = try await importCard(fixture, name: "Отчёт", text: original)
        try Data().write(to: fixture.release)
        try await waitUntilCard(model, id, state: .succeeded)
        // Publish warnings through the real card transaction: a doubtful body
        // fragment with a traceable review place, and a doubtful name place.
        let card = try await loadCard(model, id)
        let result = try XCTUnwrap(card.publishedResult)
        let inputRange = try XCTUnwrap(scalarRange(of: "позвонила", in: result.input.source.text))
        let generatedRange = try XCTUnwrap(scalarRange(of: "позвонила", in: result.generatedText.text))
        _ = try await model.textArchive!.updateCard(id) { card in
            guard var result = card.publishedResult else { return }
            result.warnings = [
                AnonymizationWarning(kind: .doubtfulFragment, target: .body,
                                     inputRange: inputRange, generatedRange: generatedRange,
                                     reviewRange: generatedRange),
                AnonymizationWarning(kind: .doubtfulFragment, target: .importedName,
                                     inputRange: TextRange(start: 0, end: 2),
                                     generatedRange: TextRange(start: 0, end: 2)),
            ]
            card.publishedResult = result
        }
        await model.reloadTexts()
        // The row shows «Готово с предупреждениями» (criterion 46 status).
        XCTAssertEqual(model.textCard(id)?.statusTitle, L10n.text("Готово с предупреждениями"))
        let workspace = AnonymizationWorkspaceModel(model: model)
        let editor = workspace.cardEditor
        workspace.selection = id
        try await waitUntil { editor.warnings.count == 2 }
        let body = try XCTUnwrap(editor.warnings.first { $0.jump != nil })
        XCTAssertEqual(body.fragment, "позвонила")
        XCTAssertNil(editor.warnings.first { $0.uninterpretedType != nil })
        var requestedDeletion: String?
        let (view, window) = host(AnonymizationDetailColumn(workspace: workspace) { requestedDeletion = $0 })
        defer { window.close() }
        try await settle(view)
        XCTAssertNil(findElement("texts.detail.warning.\(body.id)", in: view))
        let status = try element("texts.detail.status", in: view)
        let warningsTab = try element("texts.detail.warningsTab", in: view)
        let statusFrame = try XCTUnwrap(status.accessibilityFrame?())
        let warningsFrame = try XCTUnwrap(warningsTab.accessibilityFrame?())
        XCTAssertGreaterThanOrEqual(warningsFrame.minX, statusFrame.maxX)
        try press("texts.detail.warningsTab", in: view)
        try await settle(view)
        _ = try element("texts.detail.warning.\(body.id)", in: view)
        XCTAssertTrue(textViews(in: view).isEmpty)
        // Opening a warning location returns to the right text and selects it.
        try press("texts.detail.warning.jump.\(body.id)", in: view)
        try await settle(view)
        let resultView = try XCTUnwrap(textViews(in: view).first { $0.string == editor.resultPanel?.text })
        XCTAssertEqual(resultView.selectedRange(), body.jump?.nsRange)
        _ = try element("texts.detail.syncScrolling", in: view)
        try press("texts.detail.restorationTab", in: view)
        try await settle(view)
        _ = try element("texts.detail.syncScrolling", in: view)
        _ = try element("texts.detail.restoration.retry", in: view)
        XCTAssertNil(findElement("texts.detail.retry", in: view))
        try press("texts.detail.delete", in: view)
        XCTAssertEqual(requestedDeletion, id)
        try press("texts.detail.restorationTab", in: view)
        try await settle(view)
        _ = try element("texts.detail.retry", in: view)
        // A failed retry keeps the previous result and its warnings; the card
        // shows the error of the new attempt (AC-46).
        try FileManager.default.removeItem(at: fixture.release)
        try Data().write(to: root.appendingPathComponent("text-fail"))
        editor.confirmReplaceEditedResult = { _ in false } // unedited right side
        await editor.retry()
        try await waitUntilCard(model, id, state: .failed)
        try await waitUntil { editor.failureText != nil }
        XCTAssertEqual(model.textCard(id)?.statusTitle, L10n.text("Ошибка"))
        try await waitUntil { editor.warnings.count == 2 }
        XCTAssertEqual(editor.warnings.first { $0.jump != nil }?.fragment, "позвонила")
        XCTAssertEqual(editor.resultPanel?.text, "Отчёт: Мария Сидорова позвонила.")
        XCTAssertTrue(editor.resultEditable, "the editor stays available with warnings")
        await model.shutdown()
    }

    // MARK: - Criterion 47: uninterpreted types verbatim, settings link, available actions

    func testUninterpretedTypeQuotedVerbatimWithSettingsLinkAndActionsAvailable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try fixture(root)
        let model = fixture.model
        try await assign(fixture, profile: fixture.anon)
        let id = try await importCard(fixture, name: "Отчёт", text: "Отчёт: Анна Петрова позвонила.")
        try Data().write(to: fixture.release)
        try await waitUntilCard(model, id, state: .succeeded)
        let card = try await loadCard(model, id)
        let wording = try XCTUnwrap(card.publishedResult?.input.dataTypes.last)
        _ = try await model.textArchive!.updateCard(id) { card in
            guard var result = card.publishedResult else { return }
            result.warnings = [AnonymizationWarning(kind: .uninterpretedType, dataType: wording)]
            card.publishedResult = result
        }
        await model.reloadTexts()
        let workspace = AnonymizationWorkspaceModel(model: model)
        let editor = workspace.cardEditor
        workspace.selection = id
        try await waitUntil { editor.warnings.count == 1 }
        // The exact saved wording is shown verbatim.
        XCTAssertEqual(editor.warnings.first?.uninterpretedType, wording)
        XCTAssertNil(editor.warnings.first?.jump)
        // Editing and the download mount point stay available; the warning
        // links into the anonymization settings tab (the download itself is
        // attached by work 12).
        var download: (String, AnonymizationTextDownloadFormat)?
        workspace.requestTextDownload = { cardID, format in download = (cardID, format) }
        let (view, window) = host(AnonymizationDetailColumn(workspace: workspace))
        defer { window.close() }
        try await settle(view)
        try press("texts.detail.warningsTab", in: view)
        try await settle(view)
        _ = try element("texts.detail.warning.settings.0", in: view)
        // The download menu exists exactly when a result is published (the
        // hook makes its items actionable); the retry action stays offered.
        let export = try XCTUnwrap(element("texts.detail.download", in: view).accessibilityFrame?())
        let copy = try XCTUnwrap(element("texts.detail.copy", in: view).accessibilityFrame?())
        let retry = try XCTUnwrap(element("texts.detail.retry", in: view).accessibilityFrame?())
        let restoration = try XCTUnwrap(element("texts.detail.restorationTab", in: view).accessibilityFrame?())
        XCTAssertEqual(retry.midY, restoration.midY, accuracy: 1)
        XCTAssertEqual(copy.midY, export.midY, accuracy: 1)
        XCTAssertGreaterThan(retry.minY, export.maxY)
        XCTAssertTrue(model.anonymizationModelsReady)
        try press("texts.detail.warningsTab", in: view)
        try await settle(view)
        XCTAssertFalse(textViews(in: view).isEmpty)
        await model.shutdown()
    }

    // MARK: - Criterion 42 (display): the size-limit failure shows both sizes

    func testSizeLimitFailureShowsSizesAndKeepsEditingAvailable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try fixture(root)
        let model = fixture.model
        model.inputLimits = AnonymizationInputLimit(overrides: [fixture.anon.id: 100])
        try await assign(fixture, profile: fixture.anon)
        let id = try await importCard(fixture, name: "over", text: String(repeating: "a", count: 101))
        try await waitUntilCard(model, id, state: .failed)
        let workspace = AnonymizationWorkspaceModel(model: model)
        let editor = workspace.cardEditor
        workspace.selection = id
        try await waitUntil { editor.failureText != nil }
        XCTAssertTrue(editor.failureIsSizeLimit)
        XCTAssertEqual(editor.failureText,
                       L10n.text("Размер текста %1$@ превышает предел %2$@ для выбранной модели",
                                 AnonymizationCardEditor.sizeText(101), AnonymizationCardEditor.sizeText(100)))
        XCTAssertTrue(editor.sourceEditable, "the left editor stays available for shortening")
        XCTAssertNil(editor.resultPanel)
        await model.shutdown()
    }

    // MARK: - Criterion 39: the header rename updates the title and the search corpus

    func testHeaderRenameUpdatesShownTitleAndSearchFindsNewName() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try fixture(root)
        let model = fixture.model
        let id = try await importCard(fixture, name: "Отчёт команды", text: "Отчёт команды")
        let workspace = AnonymizationWorkspaceModel(model: model)
        workspace.selection = id
        let editor = workspace.cardEditor
        try await waitUntil { editor.sourcePanel != nil }
        let (view, window) = host(AnonymizationDetailColumn(workspace: workspace))
        defer { window.close() }
        try await settle(view)
        let title = try element("texts.detail.title", in: view)
        let initialLabel = try XCTUnwrap(text(title))
        XCTAssertTrue(initialLabel.contains("Отчёт команды"), "header title shows the card name: \(initialLabel)")
        // The same save path the header title field uses.
        await model.renameTextCard(id, to: "Протокол заседания")
        try await settle(view)
        let renamedLabel = try XCTUnwrap(text(try element("texts.detail.title", in: view)))
        XCTAssertTrue(renamedLabel.contains("Протокол заседания"), "header title shows the new name: \(renamedLabel)")
        model.anonymizationSearch.query = "протокол"
        try await waitUntil { model.anonymizationSearch.hasCurrentQueryResults }
        XCTAssertTrue(model.anonymizationSearch.matchingIDs.contains(id), "the new name participates in search")
        await model.shutdown()
    }

    // MARK: - View helpers

    private func descendants(_ element: AnyObject) -> [AnyObject] {
        let children = (element.accessibilityChildren?() ?? []).map { $0 as AnyObject }
        return children + children.flatMap { descendants($0) }
    }
    private func subviews(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap { subviews($0) } }
    private func textViews(in view: NSView) -> [NSTextView] { subviews(view).compactMap { $0 as? NSTextView } }
    private func findElement(_ id: String, in view: NSView) -> AnyObject? {
        if let element = descendants(view).first(where: { $0.accessibilityIdentifier?() == id }) { return element }
        for subview in subviews(view) {
            if let element = descendants(subview).first(where: { $0.accessibilityIdentifier?() == id }) { return element }
        }
        return nil
    }
    private func element(_ id: String, in view: NSView) throws -> AnyObject {
        try XCTUnwrap(findElement(id, in: view), id)
    }
    private func press(_ id: String, in view: NSView) throws {
        XCTAssertEqual(try element(id, in: view).accessibilityPerformPress?(), true, id)
    }
    private func text(_ element: AnyObject) -> String? {
        guard let object = element as? NSObject else { return nil }
        for name in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector) else { continue }
            let value = object.perform(selector)?.takeUnretainedValue()
            if let string = value as? String { return string }
            if let string = value as? NSAttributedString { return string.string }
        }
        return nil
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
