import XCTest
import AppKit
import Carbon.HIToolbox
import SwiftUI
@testable import LocalScribeCore
@testable import LocalScribe

/// Deletion confirmations, worker shutdown and partial-failure handling of the
/// text archive (work 11): frozen UUID sets from the row menu, ⌘⌫ and the
/// card's trash button (criterion 24); stopping the pending and active
/// attempts of confirmed cards while foreign jobs keep their order and
/// external files survive, with the actual remainder visible after a partial
/// refusal (criterion 25); the group dialog with the full membership count,
/// composition re-confirmation, explicit variant choice, default-group
/// fallback and the protected system group (criterion 26).
@MainActor
final class AnonymizationDeletionTests: XCTestCase {

    private struct Fixture {
        let repository: RecordingRepository
        let catalog: ModelCatalog
        let model: AppModel
        let anon: ModelProfile
        let root: URL
    }

    private func fixture(_ root: URL) throws -> Fixture {
        var repo = try RecordingRepository(root: root)
        let executable = root.appendingPathComponent("worker.py")
        // The process fixture serves the recording and anonymization kinds:
        // every worker waits for the shared `release` marker and its own
        // `hold-<jobId>` marker, so tests control the exact queue moment a
        // deletion arrives. The anonymization branch builds a fully valid
        // result artifact for the attempt (same contract as the queue suite).
        let script = #"""
        #!/usr/bin/python3
        import sys, json, pathlib, time, hashlib, uuid
        c = json.loads(sys.stdin.readline())
        root = pathlib.Path(c['modelsPath']).parent
        def emit(kind, message=''):
            print(json.dumps(dict(version=1, jobId=c['jobId'], runId=c['runId'], kind=c.get('kind'), type=kind, message=message)), flush=True)
        with (root / 'events.jsonl').open('a') as f:
            f.write(json.dumps(c) + '\n')
        if c.get('kind') == 'anonymization':
            run = pathlib.Path(c['anonymizationPath'])
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
        run = pathlib.Path(c['recordingPath']) / 'runs' / c['runId']
        emit('progress', 'fixture-ready-' + c['jobId'])
        while not (root / 'release').exists() or (root / ('hold-' + c['jobId'])).exists():
            time.sleep(0.02)
        info = json.loads((run / 'run.json').read_text())
        fingerprint = hashlib.sha256((info['sourceHash'] + info['profileHash'] + info['pipelineVersion']).encode()).hexdigest()
        if c['stage'] == 'preparingAudio':
            (run / 'transcript.json').write_text(json.dumps(dict(schemaVersion=1, fingerprint=fingerprint, diarized=True, segments=[])))
        elif c['stage'] == 'summarizing':
            (run / 'summary.json').write_text(json.dumps(dict(schemaVersion=1, language=info.get('summaryLanguage') or 'ru', overview=[], decisions=[], tasks=[], openQuestions=[])))
        emit('completed')
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        var profiles = ModelRole.audioRoles.map { role in
            ModelProfile(id: role.rawValue, repository: "test/model", revision: "test-revision", license: "test", files: [], role: role)
        }
        profiles += [ModelProfile(id: "anon-llm", repository: "test/anon", revision: "test-revision", license: "test", files: [], role: nil,
                                  recommendedMemoryGB: 8, workingMemoryGB: 2, supportedTasks: [.anonymization])]
        for index in profiles.indices {
            let data = Data(profiles[index].id.utf8)
            let folder = repo.models.appendingPathComponent(profiles[index].id)
            try Disk.directory(folder)
            let file = folder.appendingPathComponent("weights.bin")
            try data.write(to: file)
            profiles[index].files = [ModelFile(path: "weights.bin", localPath: "weights.bin", size: Int64(data.count), sha256: try Disk.hash(file))]
        }
        let anon = profiles[profiles.count - 1]
        let catalog = ModelCatalog(models: profiles)
        let suite = "LocalScribeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(repository: repo, startServices: false, workerExecutable: executable,
                             userDefaults: defaults, catalog: catalog)
        for profile in profiles { model.modelLibrary.installed(profile, catalog: catalog) }
        try model.modelLibrary.select(profiles[0], catalog: catalog)
        model.modelsReady = true
        XCTAssertNotNil(model.activeCatalog)
        return Fixture(repository: repo, catalog: catalog, model: model, anon: anon, root: root)
    }

    // MARK: - Queue helpers

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
    private func importCard(_ fixture: Fixture, name: String, text: String,
                            groupID: String = AnonymizationGroup.systemID) async throws -> String {
        let archive = try XCTUnwrap(fixture.model.textArchive)
        let summary = try await archive.importCard(
            .init(bytes: Data(text.utf8), importedNameStem: name, sourceFormat: .txt,
                  source: TextRevision(id: UUID().uuidString, text: text)), groupID: groupID)
        await fixture.model.reloadTexts()
        return summary.id
    }
    /// Save the anonymization assignment through the real settings path and
    /// refresh the readiness snapshot (installation scan + wake).
    private func assign(_ fixture: Fixture, profile: ModelProfile) async throws {
        let draft = SettingsDraft(model: fixture.model)
        draft.anonymizationProfileID = profile.id
        try fixture.model.applySettings(draft)
        await fixture.model.reloadAnonymizationState()
    }
    private func events(_ root: URL) throws -> [WorkerCommand] {
        try String(contentsOf: root.appendingPathComponent("events.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try JSONDecoder().decode(WorkerCommand.self, from: Data($0.utf8)) }
    }
    private func completedRecording(_ repo: RecordingRepository, title: String) throws -> Manifest {
        var m = Manifest(sourceType: "microphone", title: title, filename: "original.caf")
        m.sourceComplete = true; m.sha256 = String(repeating: "a", count: 64); m.durationMs = 1000
        try repo.save(m); return m
    }

    // MARK: - UI helpers

    private func descendants(_ element: AnyObject) -> [AnyObject] {
        let children = (element.accessibilityChildren?() ?? []).map { $0 as AnyObject }
        return children + children.flatMap(descendants)
    }
    private func element(_ id: String, in view: NSView?) -> AnyObject? {
        guard let view else { return nil }
        return descendants(view).first { $0.accessibilityIdentifier?() == id }
            ?? view.subviews.lazy.compactMap { self.element(id, in: $0) }.first
    }
    private func host(_ model: AppModel) -> NSWindow {
        NSApplication.shared.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let window = KeyboardDeletionTestWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 560),
                                                styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView(model: model))
        window.makeKeyAndOrderFront(nil)
        return window
    }
    private func settle(_ window: NSWindow) async throws {
        try await Task.sleep(for: .milliseconds(160))
        window.contentView?.layoutSubtreeIfNeeded()
        window.attachedSheet?.contentView?.layoutSubtreeIfNeeded()
    }
    private func press(_ id: String, in window: NSWindow) throws {
        let target = try XCTUnwrap(element(id, in: window.contentView), id)
        XCTAssertTrue(target.accessibilityPerformPress?() ?? false, id)
    }
    private func mode(_ title: String, in window: NSWindow) throws {
        let picker = try XCTUnwrap(element("workspace.mode", in: window.contentView))
        let segment = try XCTUnwrap(descendants(picker).first { $0.accessibilityLabel?() == title }, title)
        _ = segment.accessibilityPerformPress?()
    }
    private func key(_ keyCode: Int, _ characters: String, modifiers: NSEvent.ModifierFlags = [],
                     in window: NSWindow) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(keyCode)))
        NSApplication.shared.sendEvent(event)
    }
    private func escape(_ window: NSWindow) throws { try key(kVK_Escape, "\u{1b}", in: window) }
    private func enter(_ window: NSWindow) throws { try key(kVK_Return, "\r", in: window) }
    private func commandDelete(_ window: NSWindow) throws { try key(kVK_Delete, "\u{7f}", modifiers: .command, in: window) }
    private func click(_ id: String, modifiers: NSEvent.ModifierFlags = [], in window: NSWindow) throws {
        let row = try XCTUnwrap(element(id, in: window.contentView), id)
        let frame = try XCTUnwrap(row.accessibilityFrame?())
        let location = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
        let events = try [NSEvent.EventType.leftMouseDown, .leftMouseUp].map { type in
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        NSApplication.shared.postEvent(events[1], atStart: false)
        NSApplication.shared.sendEvent(events[0])
        while let event = NSApplication.shared.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
            NSApplication.shared.sendEvent(event)
        }
    }
    private func clickTextCard(_ id: String, modifiers: NSEvent.ModifierFlags = [], in window: NSWindow) throws {
        try click("texts.sidebar.card.\(id)", modifiers: modifiers, in: window)
    }
    /// Every accessibility label/title/value string under the view.
    private func texts(in view: NSView) -> [String] {
        descendants(view).compactMap { element in
            guard let object = element as? NSObject else { return nil }
            return ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].compactMap { name in
                let selector = NSSelectorFromString(name)
                guard object.responds(to: selector) else { return nil }
                let value = object.perform(selector)?.takeUnretainedValue()
                return ((value as? String) ?? (value as? NSAttributedString)?.string)
            }.first
        }
    }

    // MARK: - Criterion 24: confirmations from ⌘⌫, the menu and the card

    func testDeletionConfirmationFromShortcutAndCardFreezesTheSetAndUsesEnterEscape() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try fixture(root)
        let model = fixture.model
        let first = try await importCard(fixture, name: "Отчёт команды", text: "Первый текст Анна Петрова")
        let second = try await importCard(fixture, name: "Заметки", text: "Второй текст")
        let third = try await importCard(fixture, name: "Черновик", text: "Третий текст")
        let window = host(model)
        defer { window.close() }
        try await settle(window)
        try mode("Обезличивание", in: window)
        try await settle(window)
        try clickTextCard(first, in: window)
        try await settle(window)
        try clickTextCard(second, modifiers: .command, in: window)
        try await settle(window)

        // ⌘⌫ opens the confirmation for the current selection; Esc closes it
        // without deleting anything.
        try commandDelete(window)
        try await settle(window)
        let bulkSheet = try XCTUnwrap(window.attachedSheet)
        let bulkContent = try XCTUnwrap(bulkSheet.contentView)
        XCTAssertTrue(texts(in: bulkContent).contains("Удалить выбранные тексты (2)?"))
        XCTAssertNotNil(element("texts.sidebar.confirmDelete", in: bulkContent))
        try escape(bulkSheet)
        try await settle(window)
        XCTAssertNil(window.attachedSheet)
        XCTAssertEqual(model.textCards.count, 3)

        // While a text editor has focus ⌘⌫ belongs to the editor, not the
        // archive (the search field is an editable text view here).
        try key(kVK_ANSI_F, "f", modifiers: .command, in: window)
        try await settle(window)
        XCTAssertTrue(window.firstResponder is NSTextView)
        try commandDelete(window)
        try await settle(window)
        XCTAssertNil(window.attachedSheet)
        window.makeFirstResponder(window)

        // The card's trash button concerns only the open card even with a
        // multi-row selection; the single-card dialog shows the name.
        try clickTextCard(first, in: window)
        try await settle(window)
        try press("texts.detail.delete", in: window)
        try await settle(window)
        let cardSheet = try XCTUnwrap(window.attachedSheet)
        XCTAssertTrue(texts(in: try XCTUnwrap(cardSheet.contentView)).contains("Удалить текст «Отчёт команды»?"))
        // The frozen set is captured at open: another window deleting one of
        // the confirmed cards leaves Enter to remove exactly the remainder.
        await model.deleteTextCards([second])
        XCTAssertNil(model.textCard(second))
        // Let the sheet re-enable its confirmation button after the deletion
        // run toggled `deletingTextJobs` before the key event is delivered.
        try await settle(window)
        try enter(cardSheet)
        for _ in 0..<100 where model.textCard(first) != nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNil(model.textCard(first))
        XCTAssertEqual(model.textCards.map(\.id), [third])
        await model.shutdown()
    }

    func testRowMenuOffersSearchNarrowedDeletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try fixture(root)
        let model = fixture.model
        let workspace = AnonymizationWorkspaceModel(model: model)
        let matching = try await importCard(fixture, name: "Отчёт команды", text: "Текст отчёта")
        let hidden = try await importCard(fixture, name: "Личное", text: "Личный текст")
        workspace.selectSidebarTextCard(matching)
        workspace.selectSidebarTextCard(hidden, command: true)
        XCTAssertEqual(workspace.sidebarSelection.ids, [matching, hidden])
        // An active filter narrows every mass action to the current results.
        let search = model.anonymizationSearch
        search.query = "отч"
        await search.waitUntilIdle()
        XCTAssertEqual(search.matchingIDs, [matching])
        XCTAssertEqual(workspace.sidebarActionIDs(for: matching), [matching],
                       "скрытая поиском карточка не входит в набор удаления")

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AnonymizationGroupsSidebar(
            model: model, workspace: workspace, mode: .constant(.anonymization)))
        window.makeKeyAndOrderFront(nil)
        try await settle(window)
        // Two cards are selected, but only one is visible in the filtered
        // issue, so the menu offers a single-card deletion.
        let menu = try textContextMenu(cardID: matching, in: try XCTUnwrap(window.contentView), window: window)
        XCTAssertTrue(menu.items.contains { $0.title == "Удалить текст…" })
        XCTAssertFalse(menu.items.contains { $0.title == "Удалить выбранные тексты…" })
        window.close()
        await model.shutdown()
    }

    private func textContextMenu(cardID: String, in view: NSView, window: NSWindow) throws -> NSMenu {
        let row = try XCTUnwrap(element("texts.sidebar.card.\(cardID)", in: view))
        let frame = try XCTUnwrap(row.accessibilityFrame?())
        let location = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: location,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        var candidate: NSView? = view.hitTest(view.convert(location, from: nil))
        while let current = candidate {
            if let menu = current.menu(for: event) {
                menu.update()
                if menu.items.contains(where: { $0.title.hasPrefix("Удалить текст") || $0.title.hasPrefix("Удалить выбранные тексты") }) { return menu }
            }
            candidate = current.superview
        }
        throw ScribeError.message("Контекстное меню карточки не найдено")
    }

    // MARK: - Criterion 25: pending and active attempts among foreign jobs

    func testDeletingActiveAndQueuedAttemptsStopsOnlyThemAndKeepsForeignOrderAndExternalFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try fixture(root)
        let model = fixture.model
        let workspace = AnonymizationWorkspaceModel(model: model)
        try await assign(fixture, profile: fixture.anon)
        // A foreign recording job owns the slot first; the texts queue behind.
        let recording = try completedRecording(fixture.repository, title: "Запись")
        await model.enqueue(recording.id)
        // Real external files: importing through the workspace pipeline keeps
        // them on disk while only the archived copies belong to LocalScribe.
        let names = ["first", "second", "third"]
        let sources = try names.map { name in
            let url = root.appendingPathComponent("\(name).txt")
            try Data("Текст \(name) Анна Петрова".utf8).write(to: url)
            return url
        }
        try Data().write(to: root.appendingPathComponent("hold-first"))
        workspace.resolveAmbiguousEncoding = { _, _ in .utf8 }
        workspace.importURLs(sources)
        await model.importQueue.waitUntilIdle()
        let first = try XCTUnwrap(model.textCards.first { $0.displayName == "first" }?.id)
        let second = try XCTUnwrap(model.textCards.first { $0.displayName == "second" }?.id)
        let third = try XCTUnwrap(model.textCards.first { $0.displayName == "third" }?.id)
        try await waitUntil { model.textCard(third)?.attemptState == .queued }
        // The recording finishes; the first text starts and holds the worker.
        try Data().write(to: root.appendingPathComponent("release"))
        try await waitUntilCard(model, first, state: .running)
        XCTAssertEqual(model.textCard(second)?.attemptState, .queued)
        XCTAssertEqual(model.textCard(third)?.attemptState, .queued)

        // Confirmed deletion of one active and one queued attempt.
        let textRepository = try XCTUnwrap(model.textRepository)
        await workspace.deleteCards([first, second])
        XCTAssertNil(model.textCard(first))
        XCTAssertNil(model.textCard(second))
        XCTAssertFalse(FileManager.default.fileExists(atPath: textRepository.folder(first).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: textRepository.folder(second).path))
        // The survivor keeps the FIFO order behind the foreign jobs.
        XCTAssertEqual(model.textCard(third)?.attemptState, .queued)
        XCTAssertEqual(model.textQueuePosition(for: third), 1)
        // External originals are untouched.
        for (index, source) in sources.enumerated() {
            XCTAssertEqual(try Data(contentsOf: source), Data("Текст \(names[index]) Анна Петрова".utf8))
        }
        // The remaining attempt proceeds after the deletion and succeeds.
        try FileManager.default.removeItem(at: root.appendingPathComponent("hold-first"))
        try await waitUntilCard(model, third, state: .succeeded)
        XCTAssertEqual(try events(root).filter { $0.isAnonymization }.map(\.jobId), [first, third],
                       "очередь чужих заданий и порядок выжившего сохранены")
        let recordingManifest = try await fixture.repository.load(recording.id)
        XCTAssertEqual(recordingManifest.state, .completed)

        // A restart recovers the same remainder: deleted cards never return.
        let repo2 = try RecordingRepository(root: root)
        let suite = "LocalScribeTests.\(UUID().uuidString)"
        let defaults2 = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults2.removePersistentDomain(forName: suite) }
        let model2 = AppModel(repository: repo2, startServices: false,
                              workerExecutable: root.appendingPathComponent("worker.py"),
                              userDefaults: defaults2, catalog: fixture.catalog)
        _ = try await model2.textArchive?.recover()
        await model2.reloadTexts()
        XCTAssertEqual(model2.textCards.map(\.id), [third])
        XCTAssertEqual(model2.textCard(third)?.attemptState, .succeeded)
        await model.shutdown()
        await model2.shutdown()
    }

    func testPartialCardDeletionFailureShowsReasonAndActualRemainder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try fixture(root)
        let model = fixture.model
        let workspace = AnonymizationWorkspaceModel(model: model)
        let stuck = try await importCard(fixture, name: "stuck", text: "Застрявший текст")
        let gone = try await importCard(fixture, name: "gone", text: "Удаляемый текст")
        let textRepository = try XCTUnwrap(model.textRepository)
        workspace.selection = gone
        // A card folder that cannot be removed (no write permission inside)
        // makes exactly one deletion fail.
        try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                              ofItemAtPath: textRepository.folder(stuck).path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                       ofItemAtPath: textRepository.folder(stuck).path) }
        await workspace.deleteCards([stuck, gone])
        // The refusal is visible with its reason and the actual remainder.
        XCTAssertTrue(model.errorHandler.messages.contains { $0.contains("Не удалось удалить часть карточек. Архив показывает фактический остаток.") })
        XCTAssertEqual(model.textCards.map(\.id), [stuck], "фактический остаток показан")
        XCTAssertTrue(FileManager.default.fileExists(atPath: textRepository.folder(stuck).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: textRepository.folder(gone).path))
        XCTAssertEqual(model.textCard(stuck)?.attemptState, .waitingModel)
        // The selection of the deleted card is reconciled to the remainder.
        XCTAssertNil(workspace.selection)
        XCTAssertEqual(workspace.sidebarSelection.ids, [])
        await model.shutdown()
    }

    // MARK: - Criterion 26: the group dialog

    func testGroupDialogShowsFullCountReconfirmsCompositionAndDeletesByConfirmedSet() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try fixture(root)
        let model = fixture.model
        try await model.changeTextGroups { try $0.create(name: "Работа") }
        let group = try XCTUnwrap(model.textGroups.groups.first { $0.name == "Работа" })
        let report = try await importCard(fixture, name: "report", text: "Отчёт Анна Петрова", groupID: group.id)
        let notes = try await importCard(fixture, name: "notes", text: "Заметки", groupID: group.id)
        let outsider = try await importCard(fixture, name: "outside", text: "Сторонний текст")
        // Part of the group is hidden by the active search filter.
        let search = model.anonymizationSearch
        search.query = "report"
        await search.waitUntilIdle()
        XCTAssertEqual(search.matchingIDs, [report])

        let frozen = Set(model.textCards(in: group.id).map(\.id))
        XCTAssertEqual(frozen, [report, notes])
        var dismissed = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: DeleteTextGroupView(
            model: model, request: TextGroupDeletionRequest(group: group, confirmedIDs: frozen)) { dismissed = true })
        window.makeKeyAndOrderFront(nil)
        try await settle(window)
        // The dialog shows the full count, including the card hidden by the
        // search filter.
        XCTAssertTrue(texts(in: try XCTUnwrap(window.contentView)).contains {
            $0.hasPrefix("Количество текстов в группе — 2.")
        }, "полное число файлов, включая скрытые")

        // Enter never triggers any group deletion (explicit choice only).
        XCTAssertNil(window.defaultButtonCell)
        let enterEvent = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        _ = window.performKeyEquivalent(with: enterEvent)
        try await settle(window)
        XCTAssertFalse(dismissed)
        XCTAssertTrue(model.textGroups.groups.contains { $0.id == group.id })
        XCTAssertEqual(model.textCards.count, 3)

        // A composition change between the open dialog and the destructive
        // click requires a fresh confirmation of the actual set.
        let late = try await importCard(fixture, name: "late", text: "Поздний текст", groupID: group.id)
        try press("texts.groups.confirmDeleteWithTexts", in: window)
        try await settle(window)
        XCTAssertFalse(dismissed, "изменившийся состав не удаляется без повторного подтверждения")
        XCTAssertNotNil(element("texts.groups.delete.changed", in: window.contentView))
        XCTAssertTrue(texts(in: try XCTUnwrap(window.contentView)).contains {
            $0.hasPrefix("Количество текстов в группе — 3.")
        })
        // The confirmed click of the actual set deletes the group with files.
        try press("texts.groups.confirmDeleteWithTexts", in: window)
        try await settle(window)
        XCTAssertTrue(dismissed)
        let textRepository = try XCTUnwrap(model.textRepository)
        for _ in 0..<100 where model.textGroups.groups.contains(where: { $0.id == group.id }) {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(model.textGroups.groups.contains { $0.id == group.id })
        XCTAssertEqual(model.textCards.map(\.id), [outsider], "группа удалена со всем подтверждённым составом")
        for id in [report, notes, late] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: textRepository.folder(id).path))
        }
        XCTAssertTrue(model.errorHandler.messages.isEmpty)
        window.close()
        await model.shutdown()
    }

    func testGroupOnlyDeletionMovesMembersToUngroupedAndDefaultFallsBack() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try fixture(root)
        let model = fixture.model
        try await model.changeTextGroups { try $0.create(name: "Проект") }
        let group = try XCTUnwrap(model.textGroups.groups.first { $0.name == "Проект" })
        XCTAssertEqual(model.textGroups.defaultID, group.id)
        let first = try await importCard(fixture, name: "first", text: "Первый текст", groupID: group.id)
        let second = try await importCard(fixture, name: "second", text: "Второй текст", groupID: group.id)
        let textRepository = try XCTUnwrap(model.textRepository)

        await model.deleteTextGroup(group.id, deleteFiles: false)
        XCTAssertFalse(model.textGroups.groups.contains { $0.id == group.id })
        XCTAssertEqual(model.textGroups.defaultID, AnonymizationGroup.systemID, "после удаления группы по умолчанию — «Без темы»")
        XCTAssertEqual(model.textCards.count, 2, "перенос в «Без темы» сохраняет карточки")
        XCTAssertEqual(model.textGroups.groupID(for: first), AnonymizationGroup.systemID)
        XCTAssertEqual(model.textGroups.groupID(for: second), AnonymizationGroup.systemID)
        for id in [first, second] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: textRepository.folder(id).path), "файлы не удаляются")
        }
        // The system group is protected from both variants.
        await model.deleteTextGroup(AnonymizationGroup.systemID, deleteFiles: false)
        await model.deleteTextGroup(AnonymizationGroup.systemID, deleteFiles: true)
        XCTAssertEqual(model.textCards.count, 2)
        XCTAssertTrue(model.textGroups.groups.contains { $0.id == AnonymizationGroup.systemID })
        await model.shutdown()
    }

    func testGroupWithFilesPartialFailureKeepsGroupAndCancelsStoppedAttempt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try fixture(root)
        let model = fixture.model
        try await assign(fixture, profile: fixture.anon)
        try await model.changeTextGroups { try $0.create(name: "Отчёты") }
        let group = try XCTUnwrap(model.textGroups.groups.first { $0.name == "Отчёты" })
        let stuck = try await importCard(fixture, name: "stuck", text: "Активный текст Анна Петрова", groupID: group.id)
        let gone = try await importCard(fixture, name: "gone", text: "Удаляемый текст", groupID: group.id)
        await model.enqueueText(stuck)
        await model.enqueueText(gone)
        try await waitUntilCard(model, stuck, state: .running)
        XCTAssertEqual(model.textCard(gone)?.attemptState, .queued)
        let textRepository = try XCTUnwrap(model.textRepository)
        // The attempt's run artifacts cannot be removed, but the card document
        // stays writable so the stopped attempt is recorded as cancelled.
        let stuckRuns = textRepository.folder(stuck).appendingPathComponent("runs")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stuckRuns.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: stuckRuns.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stuckRuns.path) }

        await model.deleteTextGroup(group.id, deleteFiles: true)
        // The worker of the stuck card stopped before the file removal: its
        // surviving document shows a cancelled attempt, never a phantom run.
        let survivor = try await XCTUnwrap(model.textArchive).loadCard(stuck)
        XCTAssertEqual(survivor.latestAttempt.state, .cancelled)
        // The partial failure keeps the group with the actual remainder.
        XCTAssertTrue(model.textGroups.groups.contains { $0.id == group.id }, "группа сохранена для остатка")
        XCTAssertTrue(model.errorHandler.messages.contains { $0.contains("Группа сохранена для остатка") })
        XCTAssertEqual(model.textCards.map(\.id), [stuck])
        XCTAssertEqual(model.textGroups.groupID(for: stuck), group.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: textRepository.folder(stuck).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: textRepository.folder(gone).path))
        // The queue resumes for the other jobs after the deletion.
        XCTAssertFalse(model.deletingTextJobs)
        await model.shutdown()
    }
}

/// XCTest may be running in a background process where a plain window never
/// becomes key, so the ⌘⌫/Esc local monitors of the workspace would skip it.
/// Exercise the native event delivery without asking macOS to move keyboard
/// focus away from other apps (same approach as WorkspaceKeyboardTests).
private final class KeyboardDeletionTestWindow: NSWindow {
    override var isKeyWindow: Bool { isVisible }
}
