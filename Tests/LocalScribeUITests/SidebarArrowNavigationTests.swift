import AppKit
import Carbon.HIToolbox
import SwiftUI
import XCTest
import LocalScribeCore
@testable import LocalScribe
@testable import LocalScribeCore

/// Up/Down arrow navigation over the sidebar lists of all three sections:
/// the movement is continuous across groups in their current order, skips
/// collapsed groups, follows group reordering and an active search filter,
/// and clamps at the ends. Text responders (search field, read-only
/// transcript) and native controls keep their own arrow behavior.
@MainActor
final class SidebarArrowNavigationTests: XCTestCase {
    private typealias Groups = (first: RecordingGroup, second: RecordingGroup)

    private func makeDefaults() throws -> UserDefaults {
        let suite = "LocalScribeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
    private func makeRepository() throws -> RecordingRepository {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try RecordingRepository(root: root)
    }
    private func makeModel(_ repo: RecordingRepository, defaults: UserDefaults) -> AppModel {
        AppModel(repository: repo, startServices: false, userDefaults: defaults, requestMicrophoneAccess: { false })
    }

    // MARK: - Fixtures

    /// Five recordings in three groups displayed as [One, Two | Three | Four, Five]:
    /// rows 0–1 in the first group, row 2 in the second, rows 3–4 in «Без темы».
    /// Row 0 carries a readable transcript for the detail column.
    private func recordingFixture() async throws -> (model: AppModel, rows: [Manifest], groups: Groups) {
        let repository = try makeRepository()
        var rows: [Manifest] = []
        for (index, title) in ["One", "Two", "Three", "Four", "Five"].enumerated() {
            var row = Manifest(sourceType: "import", title: title, filename: "test.wav")
            row.createdAt = Date(timeIntervalSince1970: Double(100 - index * 10))
            if index == 0 {
                let run = RunInfo(sourceHash: "fixture", profileHash: "fixture")
                row.sourceComplete = true
                row.sha256 = run.sourceHash
                row.durationMs = 1000
                row.state = .completed
                row.activeRunId = run.id
                let folder = repository.run(row.id, run.id)
                try Disk.write(run, to: folder.appendingPathComponent("run.json"))
                let segment = Segment(id: "s1", startMs: 0, endMs: 1000, text: "Fixture transcript", language: "en")
                try Disk.write(Transcript(fingerprint: run.fingerprint, diarized: false, segments: [segment]),
                               to: folder.appendingPathComponent("transcript.json"))
            }
            try repository.save(row)
            rows.append(row)
        }
        let model = makeModel(repository, defaults: try makeDefaults())
        await model.reload()
        // New groups are inserted at the top of the catalog; create in reverse.
        await model.changeGroups { try $0.create(name: "Вторая") }
        await model.changeGroups { try $0.create(name: "Первая") }
        let groups: Groups = (
            try XCTUnwrap(model.recordingGroups.groups.first { $0.name == "Первая" }),
            try XCTUnwrap(model.recordingGroups.groups.first { $0.name == "Вторая" }))
        await model.moveRecordings([rows[0].id, rows[1].id], to: groups.first.id)
        await model.moveRecordings([rows[2].id], to: groups.second.id)
        await model.reload()
        await model.recordingSearch.waitUntilIdle()
        XCTAssertEqual(model.sidebarRecordingOrder, rows.map(\.id))
        return (model, rows, groups)
    }

    /// Four diagrams in three groups displayed as [Alpha, Beta | Gamma | Delta].
    private func diagramFixture() async throws -> (model: AppModel, diagrams: [DiagramManifest], groups: Groups) {
        let model = makeModel(try makeRepository(), defaults: try makeDefaults())
        let archive = try XCTUnwrap(model.diagramArchive)
        await model.changeDiagramGroups { try $0.create(name: "Схемы Б") }
        await model.changeDiagramGroups { try $0.create(name: "Схемы А") }
        let groups: Groups = (
            try XCTUnwrap(model.diagramGroups.groups.first { $0.name == "Схемы А" }),
            try XCTUnwrap(model.diagramGroups.groups.first { $0.name == "Схемы Б" }))
        var diagrams: [DiagramManifest] = []
        for (index, title) in ["Alpha", "Beta", "Gamma", "Delta"].enumerated() {
            var diagram = DiagramManifest(title: title, filename: "\(title).png", ext: "png", uti: "public.png")
            diagram.createdAt = Date(timeIntervalSince1970: Double(400 - index * 10))
            try await archive.save(diagram)
            diagrams.append(diagram)
        }
        await model.moveDiagrams([diagrams[0].id, diagrams[1].id], to: groups.first.id)
        await model.moveDiagrams([diagrams[2].id], to: groups.second.id)
        await model.reloadDiagrams()
        await model.diagramSearch.waitUntilIdle()
        return (model, diagrams, groups)
    }

    /// Four text cards in three groups displayed as [Zwei, Eins | Drei | Vier]:
    /// the import position orders each group, newest import first.
    private func textFixture() async throws -> (model: AppModel, cards: [AnonymizationCardSummary], groups: Groups) {
        let model = makeModel(try makeRepository(), defaults: try makeDefaults())
        let archive = try XCTUnwrap(model.textArchive)
        await model.changeTextGroups { try $0.create(name: "Тексты Б") }
        await model.changeTextGroups { try $0.create(name: "Тексты А") }
        let groups: Groups = (
            try XCTUnwrap(model.textGroups.groups.first { $0.name == "Тексты А" }),
            try XCTUnwrap(model.textGroups.groups.first { $0.name == "Тексты Б" }))
        func draft(_ name: String) -> AnonymizationCoordinator.ImportDraft {
            let text = "Отчёт команды \(name)"
            return .init(bytes: Data(text.utf8), importedNameStem: name, sourceFormat: .txt,
                         source: TextRevision(id: UUID().uuidString, text: text))
        }
        var cards: [AnonymizationCardSummary] = []
        for (name, groupID) in [("Eins", groups.first.id), ("Zwei", groups.first.id),
                                ("Drei", groups.second.id), ("Vier", AnonymizationGroup.systemID)] {
            cards.append(try await archive.importCard(draft(name), groupID: groupID))
        }
        await model.reloadTexts()
        await model.anonymizationSearch.waitUntilIdle()
        return (model, cards, groups)
    }

    // MARK: - Window and event helpers

    private func host(_ model: AppModel) -> NSWindow {
        NSApplication.shared.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let window = ArrowTestWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 560),
                                      styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView(model: model))
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func settle(_ window: NSWindow) async throws {
        try await Task.sleep(for: .milliseconds(120))
        window.contentView?.layoutSubtreeIfNeeded()
        window.attachedSheet?.contentView?.layoutSubtreeIfNeeded()
    }

    private func descendants(_ element: AnyObject) -> [AnyObject] {
        let children = (element.accessibilityChildren?() ?? []).map { $0 as AnyObject }
        return children + children.flatMap(descendants)
    }

    private func element(_ id: String, in view: NSView?) -> AnyObject? {
        guard let view else { return nil }
        return descendants(view).first { $0.accessibilityIdentifier?() == id }
            ?? view.subviews.lazy.compactMap { self.element(id, in: $0) }.first
    }

    private func element(labeled label: String, in view: NSView?) -> AnyObject? {
        guard let view else { return nil }
        return descendants(view).first { $0.accessibilityLabel?() == label }
            ?? view.subviews.lazy.compactMap { self.element(labeled: label, in: $0) }.first
    }

    /// Title button of the open detail item («Изменить название …: <title>»).
    private func detailTitle(_ title: String, itemName: String, in window: NSWindow) -> AnyObject? {
        element(labeled: L10n.text("Изменить название %1$@: %2$@", itemName, title), in: window.contentView)
    }

    private func mode(_ title: String, in window: NSWindow) throws {
        let picker = try XCTUnwrap(element("workspace.mode", in: window.contentView))
        let segment = try XCTUnwrap(descendants(picker).first { $0.accessibilityLabel?() == title }, title)
        _ = segment.accessibilityPerformPress?()
    }

    private func key(_ keyCode: Int, _ characters: String, modifiers: NSEvent.ModifierFlags = [],
                     repeatKey: Bool = false, in window: NSWindow) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: repeatKey, keyCode: UInt16(keyCode)))
        NSApplication.shared.sendEvent(event)
    }

    private func arrowDown(_ window: NSWindow, modifiers: NSEvent.ModifierFlags = [],
                           repeatKey: Bool = false) throws {
        try key(kVK_DownArrow, "\u{F701}", modifiers: modifiers, repeatKey: repeatKey, in: window)
    }
    private func arrowUp(_ window: NSWindow, modifiers: NSEvent.ModifierFlags = [],
                         repeatKey: Bool = false) throws {
        try key(kVK_UpArrow, "\u{F700}", modifiers: modifiers, repeatKey: repeatKey, in: window)
    }

    // MARK: - Recordings

    func testArrowsNavigateRecordingsThroughGroupsCollapseAndReorder() async throws {
        let (model, rows, groups) = try await recordingFixture()
        let window = host(model)
        defer { window.close() }
        try await settle(window)

        // No selection: Down enters from the first visible row, Up would enter from the last.
        XCTAssertNil(model.selection)
        try arrowDown(window)
        XCTAssertEqual(model.selection, rows[0].id)
        // A held-down key keeps navigating.
        try arrowDown(window, repeatKey: true)
        XCTAssertEqual(model.selection, rows[1].id)
        try arrowDown(window)
        XCTAssertEqual(model.selection, rows[2].id) // crossed the first group into the second
        try arrowDown(window)
        XCTAssertEqual(model.selection, rows[3].id) // second group into «Без темы»
        try arrowDown(window)
        XCTAssertEqual(model.selection, rows[4].id)
        XCTAssertEqual(model.sidebarSelection.ids, [rows[4].id])
        XCTAssertEqual(model.sidebarRevealID, rows[4].id)
        try arrowDown(window) // last visible row clamps without wrapping
        XCTAssertEqual(model.selection, rows[4].id)

        for expected in [rows[3].id, rows[2].id, rows[1].id, rows[0].id] {
            try arrowUp(window)
            XCTAssertEqual(model.selection, expected)
        }
        try arrowUp(window) // first visible row clamps
        XCTAssertEqual(model.selection, rows[0].id)

        // A collapsed group leaves its rows out of the traversal; a selection
        // hidden by the collapse counts as no selection for the next move.
        await model.changeGroups { try $0.setExpanded(groups.first.id, false) }
        await model.recordingSearch.waitUntilIdle()
        try await settle(window)
        XCTAssertEqual(model.sidebarRecordingOrder, [rows[2].id, rows[3].id, rows[4].id])
        try arrowDown(window)
        XCTAssertEqual(model.selection, rows[2].id)
        try arrowUp(window) // nothing visible above
        XCTAssertEqual(model.selection, rows[2].id)

        // Reordered groups immediately define the new traversal order.
        await model.changeGroups { try $0.setExpanded(groups.first.id, true) }
        await model.changeGroups { try $0.move(groups.second.id, before: groups.first.id) }
        await model.recordingSearch.waitUntilIdle()
        try await settle(window)
        XCTAssertEqual(model.sidebarRecordingOrder, [rows[2].id, rows[0].id, rows[1].id, rows[3].id, rows[4].id])
        try arrowDown(window)
        XCTAssertEqual(model.selection, rows[0].id)

        // An active search narrows the traversal to the matching rows. Leave the
        // search field first: with a query its arrows keep editing the text.
        model.recordingSearch.query = "Four"
        await model.recordingSearch.waitUntilIdle()
        try await settle(window)
        XCTAssertEqual(model.recordingSearch.matchingIDs, [rows[3].id])
        window.makeFirstResponder(window)
        try arrowDown(window) // rows[0] is outside the filtered order: treated as no selection
        XCTAssertEqual(model.selection, rows[3].id)
        try arrowDown(window) // single-match order clamps
        XCTAssertEqual(model.selection, rows[3].id)
        model.recordingSearch.query = ""
        await model.recordingSearch.waitUntilIdle()
        await model.shutdown()
    }

    func testArrowsStayWithTextRespondersAndModifiedKeys() async throws {
        let (model, rows, _) = try await recordingFixture()
        let window = host(model)
        defer { window.close() }
        try await settle(window)

        // Search field focus with a query: arrows keep editing the query, not the list.
        try key(kVK_ANSI_F, "f", modifiers: .command, in: window)
        try await settle(window)
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.insertText("One", replacementRange: editor.selectedRange())
        try await settle(window)
        XCTAssertEqual(model.recordingSearch.query, "One")
        try arrowDown(window)
        try arrowUp(window)
        XCTAssertNil(model.selection)

        // An empty search field — the window's initial focus — hands the arrows to the list.
        model.recordingSearch.query = ""
        await model.recordingSearch.waitUntilIdle()
        try await settle(window)
        try arrowDown(window)
        XCTAssertEqual(model.selection, rows[0].id)
        try arrowUp(window) // first row clamps even while the field keeps focus
        XCTAssertEqual(model.selection, rows[0].id)

        // Modified arrows never navigate.
        window.makeFirstResponder(window)
        try arrowDown(window, modifiers: .command)
        try arrowDown(window, modifiers: .shift)
        XCTAssertEqual(model.selection, rows[0].id)

        // Read-only transcript text scrolls with its own arrows.
        model.selection = rows[0].id
        try await settle(window)
        let transcript = try XCTUnwrap(window.contentView?.descendants(of: NSTextView.self).first { !$0.isEditable })
        XCTAssertTrue(window.makeFirstResponder(transcript))
        try arrowDown(window)
        XCTAssertEqual(model.selection, rows[0].id)

        // With the plain responder chain the arrows navigate again.
        window.makeFirstResponder(window)
        try arrowDown(window)
        XCTAssertEqual(model.selection, rows[1].id)
        await model.shutdown()
    }

    // MARK: - Diagrams

    func testArrowsNavigateDiagramsThroughGroupsCollapseAndReorder() async throws {
        let (model, diagrams, groups) = try await diagramFixture()
        let window = host(model)
        defer { window.close() }
        try await settle(window)
        try mode("Схемы", in: window)
        try await settle(window)
        let itemName = L10n.text("схемы")

        try arrowDown(window)
        try await settle(window)
        XCTAssertNotNil(detailTitle("Alpha", itemName: itemName, in: window))
        try arrowDown(window)
        try await settle(window)
        XCTAssertNotNil(detailTitle("Beta", itemName: itemName, in: window))
        try arrowDown(window)
        try await settle(window)
        XCTAssertNotNil(detailTitle("Gamma", itemName: itemName, in: window)) // crossed into the second group
        try arrowDown(window)
        try await settle(window)
        XCTAssertNotNil(detailTitle("Delta", itemName: itemName, in: window))
        try arrowDown(window) // clamps at the last visible diagram
        try await settle(window)
        XCTAssertNotNil(detailTitle("Delta", itemName: itemName, in: window))
        try arrowUp(window)
        try await settle(window)
        XCTAssertNotNil(detailTitle("Gamma", itemName: itemName, in: window))
        try arrowUp(window)
        try await settle(window)
        XCTAssertNotNil(detailTitle("Beta", itemName: itemName, in: window))

        // The open diagram sits inside the collapsed group: its hidden
        // selection counts as none, and Down picks the first visible row.
        await model.changeDiagramGroups { try $0.setExpanded(groups.first.id, false) }
        await model.diagramSearch.waitUntilIdle()
        try await settle(window)
        try arrowDown(window)
        try await settle(window)
        XCTAssertNotNil(detailTitle("Gamma", itemName: itemName, in: window))
        try arrowUp(window) // Beta/Alpha are hidden above: no wrapping into them
        try await settle(window)
        XCTAssertNotNil(detailTitle("Gamma", itemName: itemName, in: window))

        // Moving the second group first reorders the traversal.
        await model.changeDiagramGroups { try $0.setExpanded(groups.first.id, true) }
        await model.changeDiagramGroups { try $0.move(groups.second.id, before: groups.first.id) }
        await model.diagramSearch.waitUntilIdle()
        try await settle(window)
        try arrowDown(window)
        try await settle(window)
        XCTAssertNotNil(detailTitle("Alpha", itemName: itemName, in: window))
        await model.shutdown()
    }

    // MARK: - Anonymization

    func testArrowsNavigateTextCardsThroughGroupsCollapseAndReorder() async throws {
        let (model, _, groups) = try await textFixture()
        let window = host(model)
        defer { window.close() }
        try await settle(window)
        try mode("Обезличивание", in: window)
        try await settle(window)
        let itemName = L10n.text("текста")
        func openCard(_ name: String) {
            XCTAssertNotNil(detailTitle(name, itemName: itemName, in: window), name)
        }

        // The visible flat order is [Zwei, Eins | Drei | Vier] (import position, newest first).
        try arrowDown(window)
        try await settle(window)
        openCard("Zwei")
        try arrowDown(window)
        try await settle(window)
        openCard("Eins")
        try arrowDown(window)
        try await settle(window)
        openCard("Drei")
        try arrowDown(window)
        try await settle(window)
        openCard("Vier")
        try arrowDown(window) // clamps at the last visible card
        try await settle(window)
        openCard("Vier")
        try arrowUp(window)
        try await settle(window)
        openCard("Drei")

        // Collapse the first group: Up from its former rows must not wrap
        // into the hidden Zwei/Eins, and a hidden selection counts as none.
        await model.changeTextGroups { try $0.setExpanded(groups.first.id, false) }
        await model.anonymizationSearch.waitUntilIdle()
        try await settle(window)
        try arrowUp(window) // nothing visible above Drei
        try await settle(window)
        openCard("Drei")
        try arrowUp(window)
        try await settle(window)
        openCard("Drei")

        await model.changeTextGroups { try $0.setExpanded(groups.first.id, true) }
        await model.changeTextGroups { try $0.move(groups.second.id, before: groups.first.id) }
        await model.anonymizationSearch.waitUntilIdle()
        try await settle(window)
        try arrowDown(window)
        try await settle(window)
        openCard("Zwei")
        await model.shutdown()
    }

    // MARK: - Neighbor lookup

    func testSidebarNeighborClampsWithoutWrapping() {
        let order = ["a", "b", "c"]
        XCTAssertNil(SidebarNeighbor.next(current: nil, in: [], down: true))
        XCTAssertNil(SidebarNeighbor.next(current: "a", in: [], down: false))
        XCTAssertEqual(SidebarNeighbor.next(current: nil, in: order, down: true), "a")
        XCTAssertEqual(SidebarNeighbor.next(current: nil, in: order, down: false), "c")
        // A row outside the order (collapsed group, search filter) reads as none.
        XCTAssertEqual(SidebarNeighbor.next(current: "z", in: order, down: true), "a")
        XCTAssertEqual(SidebarNeighbor.next(current: "z", in: order, down: false), "c")
        XCTAssertEqual(SidebarNeighbor.next(current: "b", in: order, down: false), "a")
        XCTAssertEqual(SidebarNeighbor.next(current: "b", in: order, down: true), "c")
        XCTAssertNil(SidebarNeighbor.next(current: "c", in: order, down: true))
        XCTAssertNil(SidebarNeighbor.next(current: "a", in: order, down: false))
    }
}

/// XCTest may be running in a background process. Exercise the native event
/// delivery without asking macOS to move keyboard focus away from other apps.
private final class ArrowTestWindow: NSWindow {
    override var isKeyWindow: Bool { isVisible }
}

private extension NSView {
    func descendants<T: NSView>(of type: T.Type) -> [T] {
        subviews.compactMap { $0 as? T } + subviews.flatMap { $0.descendants(of: type) }
    }
}
