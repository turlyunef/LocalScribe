import AppKit
import SwiftUI
import Synchronization
import XCTest
@testable import LocalScribe
@testable import LocalScribeCore

private actor SearchGate {
    var entered = 0
    var requests: [RecordingSearch.Request] = []
    var blocked: CheckedContinuation<RecordingSearch.Output, Error>?
    var waiter: CheckedContinuation<Void, Never>?
    func run(_ request: RecordingSearch.Request) async throws -> RecordingSearch.Output {
        entered += 1; requests.append(request)
        return try await withCheckedThrowingContinuation { continuation in
            blocked = continuation; waiter?.resume(); waiter = nil
        }
    }
    func waitForEntry() async {
        if blocked != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() throws {
        let request = requests.last!
        // Deliberately ignore cancellation: publication must still check generations.
        let matches = Set(request.titles.filter { request.tokens.isEmpty || $0.title.lowercased().contains(request.tokens[0].text) }.map(\.id))
        var normal: [String: [String]] = [:], filtered: [String: [String]] = [:]
        for row in request.rows {
            normal[row.group, default: []].append(row.id)
            if matches.contains(row.id) { filtered[row.group, default: []].append(row.id) }
        }
        let output = RecordingSearch.Output(stamp: request.stamp, index: request.index, sortedRows: request.rows,
            normal: normal, filtered: filtered, matches: matches)
        let continuation = blocked; blocked = nil; continuation?.resume(returning: output)
    }
}

@MainActor final class RecordingSearchIntegrationTests: XCTestCase {
    private func fixture() async throws -> (RecordingRepository, AppModel) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root)
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let model = AppModel(repository: repo, startServices: false, userDefaults: defaults)
        await model.reload()
        return (repo, model)
    }
    private func add(_ titles: [String], repo: RecordingRepository, model: AppModel) async throws -> [Manifest] {
        let rows = try titles.enumerated().map { i, title in
            var m = Manifest(sourceType: "import", title: title, filename: "a.wav")
            m.createdAt = Date(timeIntervalSince1970: Double(100 - i)); try repo.save(m); return m
        }
        for row in rows { _ = try await model.archive?.refresh(row.id) }
        await model.reload(); return rows
    }
    func testSingleExecutorLatestPendingAndABAGenerations() async throws {
        let gate = SearchGate(), search = RecordingSearch(executor: { try await gate.run($0) })
        let row = Manifest(sourceType: "import", title: "alpha", filename: "a.wav")
        search.update([row], groups: RecordingGroups())
        await gate.waitForEntry()
        search.query = "a"; search.query = "b"; search.query = "a"
        let beforeRelease = await gate.entered
        XCTAssertEqual(beforeRelease, 1)
        try await gate.release()
        await gate.waitForEntry()
        XCTAssertFalse(search.completed)
        let entered = await gate.entered
        XCTAssertEqual(entered, 2)
        let requests = await gate.requests
        XCTAssertNotEqual(requests[0].stamp.query, requests[1].stamp.query)
        try await gate.release(); await search.waitUntilIdle()
        XCTAssertEqual(search.matchingIDs, [row.id])
        let old = RecordingSearch.Output(stamp: requests[0].stamp, index: .init(), sortedRows: [], normal: [:], filtered: [:], matches: [])
        search.accept(old)
        XCTAssertEqual(search.matchingIDs, [row.id])
        search.shutdown()
    }
    func testChangedCorpusAndMembershipRejectOldAnswer() async throws {
        let gate = SearchGate(), search = RecordingSearch(executor: { try await gate.run($0) })
        let a = Manifest(sourceType: "import", title: "alpha", filename: "a.wav")
        let b = Manifest(sourceType: "import", title: "beta", filename: "b.wav")
        var groups = RecordingGroups()
        let target = try groups.create(name: "Target")
        search.query = "alpha"
        await gate.waitForEntry()
        search.update([a, b], groups: groups)
        try groups.assign(a.id, to: target.id)
        search.update([a, b], groups: groups)
        search.update([b], groups: groups)
        try await gate.release(); await gate.waitForEntry()
        XCTAssertFalse(search.completed)
        try await gate.release(); await search.waitUntilIdle()
        XCTAssertTrue(search.matchingIDs.isEmpty)
        XCTAssertEqual(search.normal[RecordingGroup.ungroupedID], [b.id])
        XCTAssertNil(search.normal[target.id])
        search.shutdown()
    }
    func testClearDuringWorkAndShutdownRejectLatePublication() async throws {
        let gate = SearchGate(), search = RecordingSearch(executor: { try await gate.run($0) })
        let row = Manifest(sourceType: "import", title: "alpha", filename: "a.wav")
        search.update([row], groups: RecordingGroups()); await gate.waitForEntry()
        try await gate.release(); await search.waitUntilIdle()
        search.query = "b"; await gate.waitForEntry()
        search.query = ""
        XCTAssertFalse(search.active)
        XCTAssertEqual(search.visible[RecordingGroup.ungroupedID], [row.id])
        try await gate.release(); await search.waitUntilIdle()
        XCTAssertFalse(search.active)
        search.query = "a"; await gate.waitForEntry()
        search.shutdown(); try await gate.release(); await search.waitUntilIdle()
        XCTAssertFalse(search.completed)
    }
    func testGroupsSelectionMembershipAndNoQueryIO() async throws {
        let (repo, model) = try await fixture()
        let rows = try await add(["Встреча первая", "Отпуск", "Встреча вторая"], repo: repo, model: model)
        try await model.saveGroupName("Работа")
        let group = model.defaultGroup.id
        await model.moveRecordings([rows[0].id, rows[1].id], to: group)
        await model.changeGroups { try $0.setExpanded(group, false) }
        model.selection = rows[1].id
        let bytes = try Data(contentsOf: repo.root.appendingPathComponent("groups.json"))
        await model.archive?.flushIndex()
        let io = Mutex(0)
        var observed = repo
        observed.observeIO = { _ in io.withLock { $0 += 1 } }
        // A separate model shares the instrumented repository, not the user's archive.
        let probe = AppModel(repository: observed, startServices: false)
        await probe.reload(); let baseline = io.withLock { $0 }
        model.recordingSearch.query = "встеча"
        await model.recordingSearch.waitUntilIdle()
        XCTAssertEqual(model.recordingSearch.matchingIDs, [rows[0].id, rows[2].id])
        XCTAssertEqual(model.selection, rows[1].id)
        XCTAssertTrue(model.sidebarSelection.ids.isEmpty)
        XCTAssertEqual(model.sidebarActionIDs(for: rows[0].id), [rows[0].id])
        XCTAssertEqual(model.sidebarRecordingOrder, [rows[0].id, rows[2].id])
        XCTAssertEqual(model.sidebarGroupCount(group), "1 / 2")
        await model.setAllSidebarExpanded(false)
        XCTAssertTrue(model.sidebarRecordingOrder.isEmpty)
        model.recordingSearch.query = "ВСТЕЧА"
        XCTAssertTrue(model.sidebarRecordingOrder.isEmpty)
        model.recordingSearch.query = "встреч"
        await model.recordingSearch.waitUntilIdle()
        XCTAssertEqual(model.sidebarRecordingOrder, [rows[0].id, rows[2].id])
        model.selectSidebarRecording(rows[0].id)
        model.selectSidebarRecording(rows[2].id, shift: true)
        XCTAssertEqual(model.sidebarSelection.ids, [rows[0].id, rows[2].id])
        await model.moveRecording(rows[0].id, to: RecordingGroup.ungroupedID)
        XCTAssertEqual(model.sidebarGroups(editing: nil).map(\.id), [RecordingGroup.ungroupedID])
        XCTAssertEqual(model.recordings(in: group).map(\.id), [rows[1].id])
        for query in ["в", "вс", "вст", "встеч", "встеча", "---", ""] {
            probe.recordingSearch.query = query; await probe.recordingSearch.waitUntilIdle()
        }
        XCTAssertEqual(io.withLock { $0 }, baseline)
        model.recordingSearch.query = ""
        XCTAssertFalse(model.recordingSearch.expanded(model.recordingGroups.groups.first { $0.id == group }!))
        // Only the explicit move writes membership. Search/expansion leave current bytes intact.
        let afterMove = try Data(contentsOf: repo.root.appendingPathComponent("groups.json"))
        XCTAssertNotEqual(bytes, afterMove)
        model.recordingSearch.query = "встреча"; await model.recordingSearch.waitUntilIdle()
        await model.setAllSidebarExpanded(false); model.recordingSearch.query = ""
        XCTAssertEqual(try Data(contentsOf: repo.root.appendingPathComponent("groups.json")), afterMove)
        await probe.shutdown(); await model.shutdown()
    }
    func testCorpusChangesStatusReuseAndImmediateRemoval() async throws {
        let (repo, model) = try await fixture()
        let rows = try await add(["alpha", "beta"], repo: repo, model: model)
        model.recordingSearch.query = "alpha"; await model.recordingSearch.waitUntilIdle()
        let revision = model.recordingSearch.corpusRevision
        var changed = model.recordings
        changed[0].state = .transcribing; model.recordings = changed
        XCTAssertEqual(model.recordingSearch.corpusRevision, revision)
        XCTAssertFalse(model.recordingSearch.isRunning)
        await model.renameRecording(rows[0].id, title: "gamma")
        await model.recordingSearch.waitUntilIdle()
        XCTAssertTrue(model.recordingSearch.matchingIDs.isEmpty)
        model.recordings = [rows[1]]
        XCTAssertFalse(model.visibleRecordings(in: RecordingGroup.ungroupedID).contains { $0.id == rows[0].id })
        await model.recordingSearch.waitUntilIdle()
        var addition = rows[0]; addition.displayTitle = "alpha new"
        model.recordings.append(addition); await model.recordingSearch.waitUntilIdle()
        XCTAssertEqual(model.recordingSearch.matchingIDs, [addition.id])
        await model.shutdown()
    }

    func testLargeGroupMaterializesViewportAndFindsOffscreenRecording() async throws {
        let (_, model) = try await fixture()
        let rows = (0..<1000).map { number in
            Manifest(sourceType: "import", title: "Запись \(number)", filename: "a.wav")
        }
        model.recordings = rows
        await model.recordingSearch.waitUntilIdle()
        _ = NSApplication.shared
        NSApplication.shared.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let view = NSHostingView(rootView: RecordingGroupsSidebar(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150)); view.layoutSubtreeIfNeeded()
        func nativeViews(_ node: NSView) -> Int { 1 + node.subviews.reduce(0) { $0 + nativeViews($1) } }
        // Every instantiated row owns a native mouse monitor view. An eager group
        // exceeds a thousand native views before the first query can be typed.
        XCTAssertLessThan(nativeViews(view), 200)
        model.recordingSearch.query = "500"
        await model.recordingSearch.waitUntilIdle()
        try await Task.sleep(for: .milliseconds(150)); view.layoutSubtreeIfNeeded()
        XCTAssertEqual(model.recordingSearch.matchingIDs, [rows[500].id])
        XCTAssertNotNil(element("sidebar.recording.\(rows[500].id)", view))
        XCTAssertLessThan(nativeViews(view), 200)
        await model.shutdown()
    }

    private func descendants(_ object: AnyObject) -> [AnyObject] {
        let children = (object.accessibilityChildren?() ?? []).map { $0 as AnyObject }
        return children + children.flatMap { descendants($0) }
    }
    private func element(_ id: String, _ view: NSView) -> AnyObject? {
        descendants(view).first { $0.accessibilityIdentifier?() == id }
            ?? view.subviews.lazy.compactMap { self.element(id, $0) }.first
    }
    func testNativeFieldFocusClearEscapeAndAppearance() async throws {
        let (repo, model) = try await fixture()
        _ = try await add(["Встреча с командой", "Отчёт по проекту"], repo: repo, model: model)
        _ = NSApplication.shared
        NSApplication.shared.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let view = NSHostingView(rootView: RecordingGroupsSidebar(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func settle() async throws { try await Task.sleep(for: .milliseconds(100)); view.layoutSubtreeIfNeeded() }
        try await settle()
        let field = try XCTUnwrap(element("recordings.search", view))
        XCTAssertEqual(field.accessibilityLabel?(), "Поиск по названиям записей")
        window.makeFirstResponder(view)
        let find = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3))
        NSApplication.shared.sendEvent(find)
        try await settle()
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        for value in ["в", "вс", "вст", "встеч", "встеча", "обс бюджет", "встреча", "", " "] {
            editor.selectAll(nil); editor.insertText(value, replacementRange: editor.selectedRange())
            await model.recordingSearch.waitUntilIdle(); try await settle()
            XCTAssertTrue(window.firstResponder === editor)
            XCTAssertEqual(model.recordingSearch.query, value)
            XCTAssertEqual(element("recordings.search.clear", view) != nil, !value.isEmpty)
        }
        NSApplication.shared.sendEvent(find)
        try await settle()
        XCTAssertEqual(editor.selectedRange().length, 1)
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertNil(model.selection)
        let clear = try XCTUnwrap(element("recordings.search.clear", view))
        XCTAssertTrue(clear.accessibilityPerformPress?() ?? false)
        try await settle()
        XCTAssertEqual(model.recordingSearch.query, "")
        XCTAssertTrue(window.firstResponder === editor)
        editor.insertText("встеча", replacementRange: editor.selectedRange())
        await model.recordingSearch.waitUntilIdle(); try await settle()
        XCTAssertNotNil(element("recordings.search.count", view))
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        try await settle(); XCTAssertEqual(model.recordingSearch.query, "")
        XCTAssertTrue(window.firstResponder === editor)
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        try await settle(); XCTAssertFalse(window.firstResponder === editor)
        model.recordingSearch.query = "zzzzzzzz"
        await model.recordingSearch.waitUntilIdle(); try await settle()
        XCTAssertNotNil(element("recordings.search.empty", view))
        XCTAssertNil(element("groups.empty.\(RecordingGroup.ungroupedID)", view))
        model.recordingSearch.query = ""
        try await settle()
        for (name, width) in [(NSAppearance.Name.aqua, 240.0), (.darkAqua, 360.0)] {
            window.appearance = NSAppearance(named: name)
            window.setContentSize(NSSize(width: width, height: 600)); try await settle()
            XCTAssertNotNil(element("recordings.search", view))
        }
        await model.shutdown()
    }
}
