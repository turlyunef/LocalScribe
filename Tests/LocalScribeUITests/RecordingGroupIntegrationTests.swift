import AppKit
import SwiftUI
import XCTest
@testable import LocalScribe
@testable import LocalScribeCore

@MainActor
final class RecordingGroupIntegrationTests: XCTestCase {
    private func fixture() throws -> (RecordingRepository, AppModel) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let model = AppModel(repository: repo, startServices: false, userDefaults: defaults, importProbe: { _, _ in
            AudioInfo(duration: 1, sampleRate: 16000, channels: 1, codec: "pcm_s16le")
        })
        return (repo, model)
    }
    private func descendants(_ element: AnyObject) -> [AnyObject] {
        let children = (element.accessibilityChildren?() ?? []).map { $0 as AnyObject }
        return children + children.flatMap { descendants($0) }
    }
    private func element(_ id: String, in view: NSView) -> AnyObject? {
        if let found = descendants(view).first(where: { $0.accessibilityIdentifier?() == id }) { return found }
        return view.subviews.lazy.compactMap { self.element(id, in: $0) }.first
    }
    private func host<V: View>(_ view: V) -> (NSHostingView<V>, NSWindow) {
        _ = NSApplication.shared
        NSApplication.shared.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let hosting = NSHostingView(rootView: view)
        let window = SidebarTestWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting
        window.makeKeyAndOrderFront(nil); hosting.layoutSubtreeIfNeeded()
        return (hosting, window)
    }
    private func settle(_ view: NSView) async throws {
        try await Task.sleep(for: .milliseconds(180)); view.layoutSubtreeIfNeeded()
    }

    private func clickRecording(_ id: String, modifiers: NSEvent.ModifierFlags = [], context: Bool = false,
                                view: NSView, window: NSWindow) async throws {
        let row = try XCTUnwrap(element("sidebar.recording.\(id)", in: view))
        let frame = try XCTUnwrap(row.accessibilityFrame?())
        let location = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
        // Deliver through NSApplication so local monitors see the actual event, then
        // suppress the blocking system menu loop. Menu contents/actions are tested below.
        (window as? SidebarTestWindow)?.suppressContextMenus = context
        defer { (window as? SidebarTestWindow)?.suppressContextMenus = false }
        let types: [NSEvent.EventType] = context ? [.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp]
        let events = try types.map { type in
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        NSApplication.shared.postEvent(events[1], atStart: false)
        NSApplication.shared.sendEvent(events[0])
        while let event = NSApplication.shared.nextEvent(matching: [.leftMouseUp, .rightMouseUp],
            until: Date(), inMode: .default, dequeue: true) {
            NSApplication.shared.sendEvent(event)
        }
        try await settle(view)
    }

    func testNativeCommandShiftAndPlainClicksAcrossGroupsAndContextMenu() async throws {
        let (repo, model) = try fixture()
        let rows = try (0..<4).map { index in
            var m = Manifest(sourceType: "import", title: "Row \(index)", filename: "a.wav")
            m.createdAt = Date(timeIntervalSince1970: Double(10 - index))
            try repo.save(m); return m
        }
        for row in rows { _ = try await model.archive?.refresh(row.id) }
        try await model.saveGroupName("First")
        let first = model.defaultGroup.id
        await model.moveRecordings(Set(rows.prefix(2).map(\.id)), to: first)
        let (view, window) = host(RecordingGroupsSidebar(model: model))
        defer { window.close() }
        try await settle(view)
        XCTAssertEqual(model.sidebarRecordingOrder, rows.map(\.id))
        try await clickRecording(rows[0].id, view: view, window: window)
        try await clickRecording(rows[2].id, modifiers: .command, view: view, window: window)
        XCTAssertEqual(model.sidebarSelection.ids, [rows[0].id, rows[2].id])
        // The menu must offer both existing source groups for a mixed selection.
        XCTAssertEqual(try moveMenuTitles(recordingID: rows[0].id, in: view, window: window), ["First", "Без темы"])
        try await clickRecording(rows[0].id, context: true, view: view, window: window)
        XCTAssertEqual(model.sidebarSelection.ids, [rows[0].id, rows[2].id])
        XCTAssertEqual(try recordingMenu(recordingID: rows[0].id, in: view, window: window).items.last?.title,
                       "Удалить выбранные записи…")
        let menu = try moveMenu(recordingID: rows[0].id, in: view, window: window)
        menu.performActionForItem(at: 0)
        try await settle(view)
        XCTAssertEqual(model.recordingGroups.groupID(for: rows[2].id), first)
        XCTAssertEqual(model.sidebarSelection.ids, [rows[0].id, rows[2].id])
        await model.moveRecording(rows[2].id, to: RecordingGroup.ungroupedID)
        try await settle(view)
        try await clickRecording(rows[0].id, view: view, window: window)
        XCTAssertEqual(model.sidebarSelection.ids, [rows[0].id])
        XCTAssertEqual(try recordingMenu(recordingID: rows[0].id, in: view, window: window).items.last?.title,
                       "Удалить запись…")
        try await clickRecording(rows[3].id, modifiers: .shift, view: view, window: window)
        XCTAssertEqual(model.sidebarSelection.ids, Set(rows.map(\.id)))
        try await clickRecording(rows[1].id, modifiers: .shift, view: view, window: window)
        XCTAssertEqual(model.sidebarSelection.ids, Set(rows.prefix(2).map(\.id)))
        try await clickRecording(rows[3].id, context: true, view: view, window: window)
        XCTAssertEqual(model.sidebarSelection.ids, [rows[3].id])
        await model.shutdown()
    }

    func testNativeFilteredRangeAndMenuExcludeHiddenSelection() async throws {
        let (repo, model) = try fixture()
        let titles = ["Встреча первая", "Отпуск", "Встреча вторая"]
        let rows = try titles.enumerated().map { index, title in
            var m = Manifest(sourceType: "import", title: title, filename: "a.wav")
            m.createdAt = Date(timeIntervalSince1970: Double(10 - index)); try repo.save(m); return m
        }
        for row in rows { _ = try await model.archive?.refresh(row.id) }
        try await model.saveGroupName("Target")
        let target = model.defaultGroup.id
        let (view, window) = host(RecordingGroupsSidebar(model: model))
        defer { window.close() }
        try await settle(view)
        try await clickRecording(rows[0].id, view: view, window: window)
        try await clickRecording(rows[1].id, modifiers: .command, view: view, window: window)
        model.recordingSearch.query = "встеча"
        await model.recordingSearch.waitUntilIdle(); try await settle(view)
        XCTAssertEqual(model.selection, rows[1].id)
        XCTAssertEqual(model.sidebarSelection.ids, [rows[0].id])
        XCTAssertNil(element("sidebar.recording.\(rows[1].id)", in: view))
        try await clickRecording(rows[2].id, modifiers: .shift, view: view, window: window)
        // Filtering reset the hidden anchor, so Shift makes a single selection.
        XCTAssertEqual(model.sidebarSelection.ids, [rows[2].id])
        try await clickRecording(rows[0].id, view: view, window: window)
        try await clickRecording(rows[2].id, modifiers: .shift, view: view, window: window)
        XCTAssertEqual(model.sidebarSelection.ids, [rows[0].id, rows[2].id])
        try await clickRecording(rows[0].id, context: true, view: view, window: window)
        XCTAssertEqual(try recordingMenu(recordingID: rows[0].id, in: view, window: window).items.last?.title,
                       "Удалить выбранные записи…")
        let menu = try moveMenu(recordingID: rows[0].id, in: view, window: window)
        menu.performActionForItem(at: 0); try await settle(view)
        XCTAssertEqual(model.recordingGroups.groupID(for: rows[0].id), target)
        XCTAssertEqual(model.recordingGroups.groupID(for: rows[2].id), target)
        XCTAssertEqual(model.recordingGroups.groupID(for: rows[1].id), RecordingGroup.ungroupedID)
        XCTAssertEqual(model.sidebarGroups(editing: nil).map(\.id), [target])
        XCTAssertEqual(model.sidebarGroupCount(target), "2 / 2")
        XCTAssertEqual(try moveMenuTitles(recordingID: rows[0].id, in: view, window: window), ["Без темы"])
        await model.shutdown()
    }

    func testRangeUsesExpandedGroupsAndBatchMovePreservesSelection() async throws {
        let (repo, model) = try fixture()
        let rows = try (0..<4).map { index in
            var m = Manifest(sourceType: "import", title: "Row \(index)", filename: "a.wav")
            m.createdAt = Date(timeIntervalSince1970: Double(index)); try repo.save(m); return m
        }
        for row in rows { _ = try await model.archive?.refresh(row.id) }
        try await model.saveGroupName("First")
        let first = model.defaultGroup.id
        await model.moveRecordings([rows[0].id, rows[1].id], to: first)
        try await model.saveGroupName("Hidden")
        let hidden = model.defaultGroup.id
        await model.moveRecording(rows[2].id, to: hidden)
        await model.changeGroups { try $0.setExpanded(hidden, false) }
        model.selectSidebarRecording(rows[1].id)
        model.selectSidebarRecording(rows[3].id, shift: true)
        let ids: Set<String> = [rows[0].id, rows[1].id, rows[3].id]
        XCTAssertEqual(model.sidebarSelection.ids, ids)
        await model.moveRecordings(ids, to: hidden)
        XCTAssertEqual(model.sidebarSelection.ids, ids)
        XCTAssertEqual(model.selection, rows[3].id)
        XCTAssertTrue(ids.allSatisfy { model.recordingGroups.groupID(for: $0) == hidden })
        XCTAssertEqual(model.recordingGroups.groups.first { $0.id == hidden }?.expanded, false)
        model.selection = rows[2].id
        XCTAssertEqual(model.sidebarSelection.ids, [rows[2].id])
        await model.shutdown()
    }

    func testBatchDeletionProtectsMicrophoneAndConfirmationHasNoReturnShortcut() async throws {
        let (repo, model) = try fixture()
        let a = Manifest(sourceType: "microphone", title: "Capture", filename: "a.caf")
        let b = Manifest(sourceType: "import", title: "Keep", filename: "b.wav")
        for row in [a, b] { try repo.save(row); _ = try await model.archive?.refresh(row.id) }
        await model.reload()
        let ids: Set<String> = [a.id, b.id]
        model.recordingID = a.id
        await model.deleteSidebarRecordings(ids)
        XCTAssertEqual(model.recordings.count, 2)
        let (view, window) = host(DeleteSidebarRecordingsView(model: model, ids: ids, dismiss: {}))
        defer { window.close() }
        try await settle(view)
        XCTAssertEqual(element("sidebar.confirmDeleteRecordings", in: view)?.isAccessibilityEnabled?(), false)
        XCTAssertNil(window.defaultButtonCell)
        model.recordingID = nil
        try await settle(view)
        XCTAssertEqual(element("sidebar.confirmDeleteRecordings", in: view)?.isAccessibilityEnabled?(), true)
        await model.shutdown()
    }

    func testBatchDeletionUsesConfirmedIDsAndPreservesExternalFilesAndOtherSelection() async throws {
        let (repo, model) = try fixture()
        let sources = try (0..<3).map { index in
            let url = repo.root.appendingPathComponent("external-\(index).wav")
            try Data("audio \(index)".utf8).write(to: url)
            return url
        }
        let export = repo.root.appendingPathComponent("export.txt")
        try Data("export".utf8).write(to: export)
        model.importURLs(sources)
        await model.importQueue.waitUntilIdle()
        let rows = model.recordings
        XCTAssertEqual(rows.count, 3)
        try await model.saveGroupName("Keep group")
        let group = model.defaultGroup.id
        await model.moveRecording(rows[0].id, to: group)
        let confirmed: Set<String> = [rows[0].id, rows[1].id]
        model.selectSidebarRecording(rows[2].id)
        await model.deleteSidebarRecordings(confirmed)
        XCTAssertEqual(model.recordings.map(\.id), [rows[2].id])
        XCTAssertEqual(model.sidebarSelection.ids, [rows[2].id])
        XCTAssertEqual(model.selection, rows[2].id)
        XCTAssertTrue(model.recordingGroups.groups.contains { $0.id == group })
        for id in confirmed { XCTAssertFalse(FileManager.default.fileExists(atPath: repo.folder(id).path)) }
        for (index, source) in sources.enumerated() {
            XCTAssertEqual(try Data(contentsOf: source), Data("audio \(index)".utf8))
        }
        XCTAssertEqual(try Data(contentsOf: export), Data("export".utf8))
        XCTAssertTrue(model.errorHandler.messages.isEmpty)
        await model.shutdown()
    }

    func testImportBatchAndDelayedProvidersKeepDestinationAcrossDefaultChangesAndDuplicates() async throws {
        let (repo, model) = try fixture()
        try await model.saveGroupName("First")
        let first = model.defaultGroup.id
        let urls = try (1...3).map { i in
            let url = repo.root.appendingPathComponent("input-\(i).wav")
            try Data("audio \(i)".utf8).write(to: url); return url
        }
        // Block the import slot before the batch is added, then change the default.
        var release = false
        model.importQueue.enqueue { while !release { try? await Task.sleep(for: .milliseconds(10)) } }
        model.importURLs(Array(urls.prefix(2)))
        let provider = NSItemProvider(object: urls[2] as NSURL)
        model.importProviders([provider])
        try await model.saveGroupName("Second")
        let second = model.defaultGroup.id
        release = true
        await model.importQueue.waitUntilIdle()
        XCTAssertEqual(model.recordings.count, 3)
        XCTAssertTrue(model.recordings.allSatisfy { model.recordingGroups.groupID(for: $0.id) == first })
        XCTAssertEqual(model.defaultGroup.id, second)
        model.resolveDuplicateImport = { _ in .importAgain }
        model.importURLs([urls[0]], groupID: first)
        await model.importQueue.waitUntilIdle()
        XCTAssertEqual(model.recordings.count, 4)
        XCTAssertTrue(model.recordings.allSatisfy { model.recordingGroups.groupID(for: $0.id) == first })
        XCTAssertEqual(model.defaultGroup.id, second)
        XCTAssertTrue(model.errorHandler.messages.isEmpty)
        await model.shutdown()
    }

    func testMovePreservesSelectionQueueExpansionAndDateOrder() async throws {
        let (repo, model) = try fixture()
        let manifests = try (1...3).map { i in
            var m = Manifest(sourceType: "import", title: "Meeting \(i)", filename: "a.wav")
            m.createdAt = Date(timeIntervalSince1970: Double(i)); m.sourceComplete = true
            try repo.save(m); return m
        }
        model.installing = true; model.modelsReady = true
        for m in manifests { await model.enqueue(m.id) }
        try await model.saveGroupName("First")
        let first = model.defaultGroup.id
        try await model.saveGroupName("Second")
        let second = model.defaultGroup.id
        await model.changeGroups { try $0.setExpanded(second, false) }
        model.selection = manifests[0].id
        for m in manifests.reversed() { await model.moveRecording(m.id, to: first) }
        await model.moveRecording(manifests[0].id, to: second)
        XCTAssertEqual(model.selection, manifests[0].id)
        XCTAssertEqual(model.recordings(in: first).map(\.id), [manifests[2].id, manifests[1].id])
        XCTAssertEqual(model.recordingGroups.groups.first { $0.id == second }?.expanded, false)
        for (index, m) in manifests.enumerated() { XCTAssertEqual(model.queuePosition(for: m.id), index + 1) }
        await model.changeGroups { try $0.move(first, before: second) }
        XCTAssertEqual(model.defaultGroup.id, second)
        await model.revealRecording(manifests[0].id)
        XCTAssertEqual(model.recordingGroups.groups.first { $0.id == second }?.expanded, true)
        XCTAssertEqual(model.sidebarRevealID, manifests[0].id)
        XCTAssertEqual(model.selection, manifests[0].id)
        await model.deleteGroup(first, deleteRecordings: false)
        for (index, m) in manifests.enumerated() { XCTAssertEqual(model.queuePosition(for: m.id), index + 1) }
        XCTAssertEqual(model.selection, manifests[0].id)
        await model.shutdown()
    }

    func testSidebarBulkExpansionButtonsHandleMixedGroupsAndPreserveSelectionAndQueue() async throws {
        let (repo, model) = try fixture()
        var m = Manifest(sourceType: "import", title: "Open", filename: "a.wav")
        m.sourceComplete = true
        try repo.save(m)
        model.installing = true; model.modelsReady = true
        await model.enqueue(m.id)
        try await model.saveGroupName("First")
        let first = model.defaultGroup.id
        try await model.saveGroupName("Second")
        let second = model.defaultGroup.id
        await model.moveRecording(m.id, to: first)
        model.selection = m.id
        let (view, window) = host(RecordingGroupsSidebar(model: model))
        defer { window.close() }
        try await settle(view)
        let addFrame = try XCTUnwrap(element("groups.add", in: view)?.accessibilityFrame?())
        for (expanded, buttonID) in [(false, "groups.collapseAll"), (true, "groups.expandAll")] {
            await model.changeGroups { groups in
                try groups.setExpanded(first, !expanded)
                try groups.setExpanded(second, expanded)
                try groups.setExpanded(RecordingGroup.ungroupedID, !expanded)
            }
            try await settle(view)
            let button = try XCTUnwrap(element(buttonID, in: view))
            let frame = try XCTUnwrap(button.accessibilityFrame?())
            XCTAssertEqual(frame.midY, addFrame.midY, accuracy: 1)
            XCTAssertLessThan(frame.maxX, addFrame.minX)
            XCTAssertTrue(button.accessibilityPerformPress?() ?? false)
            try await settle(view)
            XCTAssertTrue(model.recordingGroups.groups.allSatisfy { $0.expanded == expanded })
            XCTAssertEqual(try repo.loadGroups(), model.recordingGroups)
            XCTAssertEqual(model.selection, m.id)
            XCTAssertEqual(model.defaultGroup.id, second)
            XCTAssertEqual(model.recordingGroups.groupID(for: m.id), first)
            XCTAssertEqual(model.queuePosition(for: m.id), 1)
            XCTAssertEqual(element("sidebar.recording.\(m.id)", in: view) != nil, expanded)
            XCTAssertEqual(element("groups.empty.\(second)", in: view) != nil, expanded)
            let before = await model.archive?.snapshot()
            XCTAssertTrue(button.accessibilityPerformPress?() ?? false)
            try await settle(view)
            let after = await model.archive?.snapshot()
            XCTAssertEqual(after?.revision, before?.revision)
        }
        XCTAssertTrue(model.errorHandler.messages.isEmpty)
        await model.shutdown()
    }

    func testSidebarCollapseKeepsOpenRecordingAndDefault() async throws {
        let (repo, model) = try fixture()
        let m = Manifest(sourceType: "import", title: "Open", filename: "a.wav")
        try repo.save(m)
        _ = try await model.archive?.refresh(m.id)
        try await model.saveGroupName("Group")
        let group = model.defaultGroup.id
        await model.moveRecording(m.id, to: group)
        model.selection = m.id
        let (view, window) = host(RecordingGroupsSidebar(model: model))
        defer { window.close() }
        try await settle(view)
        let header = try XCTUnwrap(element("groups.header.\(group)", in: view))
        XCTAssertTrue(header.accessibilityPerformPress?() ?? false)
        try await settle(view)
        XCTAssertEqual(model.recordingGroups.groups.first?.expanded, false)
        XCTAssertEqual(model.selection, m.id)
        XCTAssertEqual(model.defaultGroup.id, group)
        XCTAssertNil(element("sidebar.recording.\(m.id)", in: view))
        await model.shutdown()
    }

    func testAddFocusTypingInvalidNameAndEscapePreserveDefaultUntilCommit() async throws {
        let (_, model) = try fixture()
        await model.reload()
        let old = model.defaultGroup.id
        let (view, window) = host(RecordingGroupsSidebar(model: model))
        defer { window.close() }
        try await settle(view)
        XCTAssertTrue(try XCTUnwrap(element("groups.add", in: view)).accessibilityPerformPress?() ?? false)
        try await settle(view)
        let field = try XCTUnwrap(window.firstResponder as? NSTextView, "New group must focus its field immediately")
        XCTAssertEqual(field.string, "")
        field.insertText("БЕЗ ТЕМЫ", replacementRange: field.selectedRange())
        field.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try await settle(view)
        XCTAssertNotNil(element("groups.name.error", in: view))
        XCTAssertEqual(model.defaultGroup.id, old)
        let retry = try XCTUnwrap(window.firstResponder as? NSTextView)
        retry.selectAll(nil); retry.insertText("  Работа  ", replacementRange: retry.selectedRange())
        retry.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try await settle(view)
        XCTAssertEqual(model.defaultGroup.name, "Работа")
        XCTAssertEqual(model.recordingGroups.groups.first?.expanded, true)
        let saved = model.defaultGroup.id
        XCTAssertTrue(try XCTUnwrap(element("groups.add", in: view)).accessibilityPerformPress?() ?? false)
        try await settle(view)
        let cancelled = try XCTUnwrap(window.firstResponder as? NSTextView)
        cancelled.insertText("Cancelled", replacementRange: cancelled.selectedRange())
        cancelled.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        try await settle(view)
        XCTAssertNil(element("groups.name", in: view))
        XCTAssertEqual(model.defaultGroup.id, saved)
        XCTAssertEqual(model.recordingGroups.groups.count, 2)
        await model.shutdown()
    }

    func testInternalTransferTypesAreDistinctFromEachOtherAndFileURLs() {
        let id = UUID().uuidString
        let recording = SidebarTransfer.provider(id, type: SidebarTransfer.recording)
        let group = SidebarTransfer.provider(id, type: SidebarTransfer.group)
        XCTAssertFalse(recording.hasItemConformingToTypeIdentifier(SidebarTransfer.group.identifier))
        XCTAssertFalse(group.hasItemConformingToTypeIdentifier(SidebarTransfer.recording.identifier))
        XCTAssertFalse(recording.hasItemConformingToTypeIdentifier("public.file-url"))
        XCTAssertFalse(group.hasItemConformingToTypeIdentifier("public.file-url"))
        XCTAssertEqual(SidebarTransfer.identifier(Data(id.utf8)), id)
        XCTAssertNil(SidebarTransfer.identifier(Data("../../outside".utf8)))
    }

    func testInternalDragProvidersLoadTheirUUIDAsData() async throws {
        let id = UUID().uuidString
        for type in [SidebarTransfer.recording, SidebarTransfer.group] {
            let provider = SidebarTransfer.provider(id, type: type)
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: data ?? Data()) }
                }
            }
            XCTAssertEqual(SidebarTransfer.identifier(data), id)
        }
    }

    func testRecordingDragSourceAllowsMove() async throws {
        let (repo, model) = try fixture()
        let recording = Manifest(sourceType: "import", title: "Drag me", filename: "a.wav")
        try repo.save(recording)
        _ = try await model.archive?.refresh(recording.id)
        await model.reload()
        let (view, window) = host(ContentView(model: model))
        defer { window.close() }
        try await settle(view)
        let row = try XCTUnwrap(element("sidebar.recording.\(recording.id)", in: view))
        let operations = try await dragOperations(on: row, in: view, window: window)
        XCTAssertTrue(operations.contains(.move))
        XCTAssertEqual(model.sidebarSelection.ids, [recording.id])
        XCTAssertEqual(model.selection, recording.id)
        await model.shutdown()
    }

    func testLoadedRecordingTransferMovesToCollapsedGroupAndBackWithoutChangingSelectionOrDefault() async throws {
        let (repo, model) = try fixture()
        let recording = Manifest(sourceType: "import", title: "Transfer", filename: "a.wav")
        try repo.save(recording)
        _ = try await model.archive?.refresh(recording.id)
        try await model.saveGroupName("Destination")
        let destination = model.defaultGroup.id
        await model.changeGroups { try $0.setExpanded(destination, false) }
        model.selection = recording.id
        for group in [destination, RecordingGroup.ungroupedID] {
            let moved = expectation(description: "Loaded drag UUID is moved")
            let provider = SidebarTransfer.provider(recording.id, type: SidebarTransfer.recording)
            SidebarTransfer.load(provider, type: SidebarTransfer.recording) { id in
                Task {
                    await model.moveRecording(id, to: group)
                    moved.fulfill()
                }
            }
            await fulfillment(of: [moved], timeout: 2)
            XCTAssertEqual(model.recordingGroups.groupID(for: recording.id), group)
            XCTAssertEqual(try RecordingRepository(root: repo.root).loadGroups().groupID(for: recording.id), group)
            XCTAssertEqual(model.selection, recording.id)
            XCTAssertEqual(model.defaultGroup.id, destination)
            XCTAssertEqual(model.recordingGroups.groups.first { $0.id == destination }?.expanded, false)
            XCTAssertEqual(model.recordings.count, 1)
        }
        XCTAssertTrue(model.errorHandler.messages.isEmpty)
        await model.shutdown()
    }

    func testInternalDragTypesAreExportedByApplicationBundle() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let declarations = try XCTUnwrap(info["UTExportedTypeDeclarations"] as? [[String: Any]])
        for type in [SidebarTransfer.recording, SidebarTransfer.group] {
            let declaration = try XCTUnwrap(declarations.first { $0["UTTypeIdentifier"] as? String == type.identifier })
            XCTAssertTrue((declaration["UTTypeConformsTo"] as? [String] ?? []).contains("public.data"))
        }
    }

    func testNativeRecordingDropOnGroupHeader() async throws {
        try requireRegisteredDragTypes()
        let (repo, model) = try fixture()
        let recording = Manifest(sourceType: "import", title: "Drop me", filename: "a.wav")
        try repo.save(recording)
        _ = try await model.archive?.refresh(recording.id)
        try await model.saveGroupName("Destination")
        let group = model.defaultGroup.id
        await model.changeGroups { try $0.setExpanded(group, false) }
        let (view, window) = host(ContentView(model: model))
        defer { window.close() }
        try await settle(view)
        let header = try XCTUnwrap(element("groups.header.\(group)", in: view))
        let frame = try XCTUnwrap(header.accessibilityFrame?())
        let point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
        let target = try nativeDropTarget(at: point, in: view)
        let drag = SidebarDropInfo(window: window, point: point, data: Data(recording.id.utf8), type: SidebarTransfer.recording.identifier)
        XCTAssertNotNil(drag.draggingPasteboard.availableType(from: target.registeredDraggedTypes),
            "AppKit must accept the pasteboard before delivering dragEntered; calling the delegate directly bypasses this check")
        defer { drag.draggingPasteboard.releaseGlobally() }
        XCTAssertFalse(target.draggingEntered(drag).isEmpty)
        try await settle(view)
        XCTAssertEqual(accessibilityValue("groups.header.\(group)", in: view),
                       "Отпустите для добавления в группу")
        XCTAssertTrue(target.prepareForDragOperation(drag))
        XCTAssertTrue(target.performDragOperation(drag))
        try await settle(view)
        XCTAssertEqual(model.recordingGroups.groupID(for: recording.id), group)
        XCTAssertEqual(try repo.loadGroups().groupID(for: recording.id), group)
        XCTAssertEqual(accessibilityValue("groups.header.\(group)", in: view), "")
        XCTAssertEqual(model.recordingGroups.groups.first { $0.id == group }?.expanded, false)
        await model.shutdown()
    }

    func testNativeDropOverEmptyGroupShowsFeedbackClearsOnExitAndMovesOnRelease() async throws {
        try requireRegisteredDragTypes()
        let (repo, model) = try fixture()
        let recording = Manifest(sourceType: "import", title: "Drop on empty space", filename: "a.wav")
        try repo.save(recording)
        _ = try await model.archive?.refresh(recording.id)
        try await model.saveGroupName("Empty")
        let group = model.defaultGroup.id
        model.selection = recording.id
        let (view, window) = host(ContentView(model: model))
        defer { window.close() }
        try await settle(view)
        let empty = try XCTUnwrap(element("groups.empty.\(group)", in: view))
        let frame = try XCTUnwrap(empty.accessibilityFrame?())
        let point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
        let target = try nativeDropTarget(at: point, in: view)
        let drag = SidebarDropInfo(window: window, point: point, data: Data(recording.id.utf8), type: SidebarTransfer.recording.identifier)
        defer { drag.draggingPasteboard.releaseGlobally() }
        XCTAssertNotNil(drag.draggingPasteboard.availableType(from: target.registeredDraggedTypes))
        XCTAssertFalse(target.draggingEntered(drag).isEmpty)
        try await settle(view)
        XCTAssertEqual(accessibilityValue("groups.header.\(group)", in: view),
                       "Отпустите для добавления в группу")
        target.draggingExited(drag)
        try await settle(view)
        XCTAssertEqual(accessibilityValue("groups.header.\(group)", in: view), "")
        XCTAssertEqual(model.recordingGroups.groupID(for: recording.id), RecordingGroup.ungroupedID)
        XCTAssertFalse(target.draggingEntered(drag).isEmpty)
        XCTAssertTrue(target.prepareForDragOperation(drag))
        XCTAssertTrue(target.performDragOperation(drag))
        try await settle(view)
        XCTAssertEqual(model.recordingGroups.groupID(for: recording.id), group)
        XCTAssertEqual(try repo.loadGroups().groupID(for: recording.id), group)
        XCTAssertEqual(model.selection, recording.id)
        XCTAssertEqual(model.defaultGroup.id, group)
        XCTAssertEqual(model.recordingGroups.groups.first { $0.id == group }?.expanded, true)

        // Group payloads belong to insertion lines, not the group's content area.
        let currentTarget = try nativeDropTarget(at: point, in: view)
        let groupDrag = SidebarDropInfo(window: window, point: point, data: Data(group.utf8), type: SidebarTransfer.group.identifier)
        defer { groupDrag.draggingPasteboard.releaseGlobally() }
        XCTAssertTrue(currentTarget.draggingEntered(groupDrag).isEmpty)
        XCTAssertFalse(currentTarget.performDragOperation(groupDrag))
        XCTAssertEqual(model.recordingGroups.groupID(for: recording.id), group)
        XCTAssertTrue(model.errorHandler.messages.isEmpty)
        await model.shutdown()
    }

    private func accessibilityValue(_ id: String, in view: NSView) -> String? {
        // SwiftUI nodes implement the public selector without declaring NSAccessibilityProtocol conformance.
        guard let object = element(id, in: view) as? NSObject else { return nil }
        let selector = NSSelectorFromString("accessibilityValue")
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }

    private func nativeDropTarget(at point: NSPoint, in view: NSView) throws -> NSView {
        func targets(_ v: NSView) -> [NSView] {
            let own = !v.registeredDraggedTypes.isEmpty && v.bounds.contains(v.convert(point, from: nil)) ? [v] : []
            return own + v.subviews.flatMap { targets($0) }
        }
        let candidates = targets(view)
        XCTAssertEqual(candidates.count, 1, "The global file-import destination must not overlap the sidebar group destination")
        return try XCTUnwrap(candidates.first)
    }

    private func requireRegisteredDragTypes() throws {
        guard let path = ProcessInfo.processInfo.environment["LOCALSCRIBE_DND_APP"] else {
            throw XCTSkip("Requires a registered .app; set LOCALSCRIBE_DND_APP to its path")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + "/Contents/Info.plist"))
    }

    private func dragOperations(on row: AnyObject, in view: NSView, window: NSWindow) async throws -> NSDragOperation {
        let frame = try XCTUnwrap(row.accessibilityFrame?())
        let start = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
        let inspection = DragSourceInspection()
        defer { inspection.restore() }
        var events: [NSEvent] = []
        for (index, type) in [NSEvent.EventType.leftMouseDown, .leftMouseDragged, .leftMouseDragged, .leftMouseUp].enumerated() {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type,
                location: NSPoint(x: start.x + CGFloat(index * 15), y: start.y), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime + Double(index) * 0.1, windowNumber: window.windowNumber,
                context: nil, eventNumber: index, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
            events.append(event)
        }
        // Context-menu tracking can consume the drag/up events inside mouseDown.
        for event in events.dropFirst() { NSApplication.shared.postEvent(event, atStart: false) }
        NSApplication.shared.sendEvent(events[0])
        while let event = NSApplication.shared.nextEvent(matching: [.leftMouseDragged, .leftMouseUp],
            until: Date(), inMode: .default, dequeue: true) {
            NSApplication.shared.sendEvent(event)
        }
        try await settle(view)
        return try XCTUnwrap(inspection.sourceOperations, "The gesture must reach the native drag source")
    }

    func testEditorCommitsOnBlurAndEmptyDraftOrRenameEscapeCancels() async throws {
        let (_, model) = try fixture()
        await model.reload()
        let (view, window) = host(RecordingGroupsSidebar(model: model))
        defer { window.close() }
        try await settle(view)
        XCTAssertTrue(try XCTUnwrap(element("groups.add", in: view)).accessibilityPerformPress?() ?? false)
        try await settle(view)
        let field = try XCTUnwrap(window.firstResponder as? NSTextView)
        field.insertText("Blur saved", replacementRange: field.selectedRange())
        window.makeFirstResponder(view)
        try await settle(view)
        XCTAssertEqual(model.defaultGroup.name, "Blur saved")
        let saved = model.defaultGroup.id
        XCTAssertTrue(try XCTUnwrap(element("groups.add", in: view)).accessibilityPerformPress?() ?? false)
        try await settle(view)
        window.makeFirstResponder(view)
        try await settle(view)
        XCTAssertNil(element("groups.name", in: view))
        XCTAssertEqual(model.defaultGroup.id, saved)

        var cancelled = false
        let (renameView, renameWindow) = host(GroupNameEditor(
            draft: GroupNameDraft(groupID: saved, name: "Blur saved"),
            save: { try await model.saveGroupName($0, id: saved) }, cancel: { cancelled = true }))
        defer { renameWindow.close() }
        try await settle(renameView)
        let renameField = try XCTUnwrap(renameWindow.firstResponder as? NSTextView)
        renameField.selectAll(nil); renameField.insertText("Discard", replacementRange: renameField.selectedRange())
        renameField.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        try await settle(renameView)
        XCTAssertTrue(cancelled)
        XCTAssertEqual(model.defaultGroup.name, "Blur saved")
        await model.shutdown()
    }

    func testEditorPersistenceFailureRetainsTextFocusAndDefault() async throws {
        let (repo, model) = try fixture()
        await model.reload()
        try Disk.directory(repo.root.appendingPathComponent("groups.json"))
        let (view, window) = host(RecordingGroupsSidebar(model: model))
        defer { window.close() }
        try await settle(view)
        XCTAssertTrue(try XCTUnwrap(element("groups.add", in: view)).accessibilityPerformPress?() ?? false)
        try await settle(view)
        let field = try XCTUnwrap(window.firstResponder as? NSTextView)
        field.insertText("Retry me", replacementRange: field.selectedRange())
        field.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try await settle(view)
        XCTAssertEqual(model.defaultGroup.id, RecordingGroup.ungroupedID)
        XCTAssertEqual((window.firstResponder as? NSTextView)?.string, "Retry me")
        XCTAssertNotNil(element("groups.name.error", in: view))
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent("groups.json"))
        (window.firstResponder as? NSTextView)?.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try await settle(view)
        XCTAssertEqual(model.defaultGroup.name, "Retry me")
        await model.shutdown()
    }

    func testDeletionConfirmationHasNoDestructiveReturnShortcutAndProtectsCapture() async throws {
        let (repo, model) = try fixture()
        var m = Manifest(sourceType: "microphone", title: "Capture", filename: "original.caf")
        m.state = .recording; try repo.save(m)
        _ = try await model.archive?.refresh(m.id)
        try await model.saveGroupName("Capture")
        let group = model.defaultGroup
        await model.moveRecording(m.id, to: group.id)
        model.recordingID = m.id
        var dismissed = false
        let (view, window) = host(DeleteRecordingGroupView(model: model, group: group, dismiss: { dismissed = true }))
        defer { window.close() }
        try await settle(view)
        let destructive = try XCTUnwrap(element("groups.confirmDeleteRecordings", in: view))
        XCTAssertEqual(destructive.isAccessibilityEnabled?(), false)
        XCTAssertNil(window.defaultButtonCell)
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        _ = window.performKeyEquivalent(with: enter)
        XCTAssertFalse(dismissed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.folder(m.id).path))
        model.recordingID = nil
        try await settle(view)
        XCTAssertEqual(destructive.isAccessibilityEnabled?(), true)
        XCTAssertNil(window.defaultButtonCell)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        _ = window.performKeyEquivalent(with: escape)
        try await settle(view)
        XCTAssertTrue(dismissed)
        XCTAssertTrue(model.recordingGroups.groups.contains { $0.id == group.id })
        await model.shutdown()
    }

    private func moveMenuTitles(recordingID: String, in view: NSView, window: NSWindow) throws -> [String] {
        try moveMenu(recordingID: recordingID, in: view, window: window).items.map(\.title)
    }

    private func moveMenu(recordingID: String, in view: NSView, window: NSWindow) throws -> NSMenu {
        let menu = try recordingMenu(recordingID: recordingID, in: view, window: window)
        let submenu = try XCTUnwrap(menu.items.first(where: { $0.title == "Переместить в" })?.submenu)
        submenu.update()
        return submenu
    }

    private func recordingMenu(recordingID: String, in view: NSView, window: NSWindow) throws -> NSMenu {
        let row = try XCTUnwrap(element("sidebar.recording.\(recordingID)", in: view))
        let frame = try XCTUnwrap(row.accessibilityFrame?())
        let location = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: location,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        var candidate = view.hitTest(view.convert(location, from: nil))
        while let current = candidate {
            if let menu = current.menu(for: event) {
                menu.update()
                if menu.items.contains(where: { $0.title == "Переместить в" }) { return menu }
            }
            candidate = current.superview
        }
        throw ScribeError.message("Контекстное меню записи не найдено")
    }

    func testContextMenuFollowsRecordingMembershipAcrossMovesIncludingUngrouped() async throws {
        let (repo, model) = try fixture()
        let m = Manifest(sourceType: "import", title: "Move me", filename: "a.wav")
        try repo.save(m)
        _ = try await model.archive?.refresh(m.id)
        try await model.saveGroupName("Работа")
        let work = model.defaultGroup.id
        try await model.saveGroupName("Учёба")
        let study = model.defaultGroup.id
        let (view, window) = host(RecordingGroupsSidebar(model: model))
        defer { window.close() }
        try await settle(view)
        XCTAssertEqual(try moveMenuTitles(recordingID: m.id, in: view, window: window), ["Учёба", "Работа"])
        for (destination, expected) in [(work, ["Учёба", "Без темы"]),
                                        (study, ["Работа", "Без темы"]),
                                        (RecordingGroup.ungroupedID, ["Учёба", "Работа"])] {
            await model.moveRecording(m.id, to: destination)
            try await settle(view)
            XCTAssertEqual(try moveMenuTitles(recordingID: m.id, in: view, window: window), expected)
        }
        await model.shutdown()
    }

    func testContextMenuUsesClickedRecordingAndUpdatesAfterRenameReorderAndGroupRemoval() async throws {
        let (repo, model) = try fixture()
        let clicked = Manifest(sourceType: "import", title: "Clicked", filename: "a.wav")
        let selected = Manifest(sourceType: "import", title: "Selected", filename: "b.wav")
        for m in [clicked, selected] {
            try repo.save(m)
            _ = try await model.archive?.refresh(m.id)
        }
        try await model.saveGroupName("Работа")
        let work = model.defaultGroup.id
        try await model.saveGroupName("Учёба")
        let study = model.defaultGroup.id
        await model.moveRecording(clicked.id, to: work)
        model.selection = selected.id
        let (view, window) = host(RecordingGroupsSidebar(model: model))
        defer { window.close() }
        try await settle(view)
        XCTAssertEqual(try moveMenuTitles(recordingID: clicked.id, in: view, window: window), ["Учёба", "Без темы"])
        XCTAssertEqual(try moveMenuTitles(recordingID: selected.id, in: view, window: window), ["Учёба", "Работа"])
        try await model.saveGroupName("Проекты", id: work)
        await model.changeGroups { try $0.move(work, before: study) }
        try await settle(view)
        XCTAssertEqual(try moveMenuTitles(recordingID: clicked.id, in: view, window: window), ["Учёба", "Без темы"])
        XCTAssertEqual(try moveMenuTitles(recordingID: selected.id, in: view, window: window), ["Проекты", "Учёба"])
        await model.deleteGroup(work, deleteRecordings: false)
        try await settle(view)
        XCTAssertEqual(try moveMenuTitles(recordingID: clicked.id, in: view, window: window), ["Учёба"])
        XCTAssertEqual(model.selection, selected.id)
        XCTAssertEqual(model.defaultGroup.id, study)
        await model.shutdown()
    }

}

/// Intercepts the public NSView entry point, including nested hosting views in ScrollView.
/// No system drag loop is started; the original implementation is restored after each test.
@MainActor
private final class DragSourceInspection {
    var sourceOperations: NSDragOperation?
    private var methods: [(Method, IMP, IMP)] = []

    init() {
        let capture: @convention(block) (NSView, NSArray, AnyObject, AnyObject) -> NSDraggingSession = { [weak self] _, _, _, source in
            let session = NSDraggingSession()
            MainActor.assumeIsolated {
                self?.sourceOperations = (source as? NSDraggingSource)?.draggingSession(session, sourceOperationMaskFor: .withinApplication)
            }
            return session
        }
        var selectors = [#selector(NSView.beginDraggingSession(with:event:source:))]
        if #available(macOS 27.0, *) {
            selectors.append(#selector(NSView.beginDraggingSession(items:gesture:source:)))
        }
        for selector in selectors {
            guard let method = class_getInstanceMethod(NSView.self, selector) else { continue }
            let replacement = imp_implementationWithBlock(capture)
            methods.append((method, method_setImplementation(method, replacement), replacement))
        }
    }
    func restore() {
        for (method, original, replacement) in methods {
            method_setImplementation(method, original)
            imp_removeBlock(replacement)
        }
        methods.removeAll()
    }
}

@MainActor
private final class SidebarDropInfo: NSObject, NSDraggingInfo {
    let draggingDestinationWindow: NSWindow?
    let draggingLocation: NSPoint
    let draggingPasteboard = NSPasteboard.withUniqueName()
    var draggingSourceOperationMask: NSDragOperation { [.copy, .move] }
    var draggedImageLocation: NSPoint { draggingLocation }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    init(window: NSWindow, point: NSPoint, data: Data, type: String) {
        draggingDestinationWindow = window; draggingLocation = point
        super.init()
        draggingPasteboard.setData(data, forType: .init(type))
    }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

/// Avoid an interactive menu event loop in automated mouse-selection tests.
@MainActor
private final class SidebarTestWindow: NSWindow {
    var suppressContextMenus = false
    override func sendEvent(_ event: NSEvent) {
        if suppressContextMenus && (event.type == .rightMouseDown || event.type == .rightMouseUp) { return }
        super.sendEvent(event)
    }
}
