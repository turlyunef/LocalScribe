import AppKit
import Carbon.HIToolbox
import SwiftUI
import XCTest
import LocalScribeCore
@testable import LocalScribe

@MainActor
final class WorkspaceKeyboardTests: XCTestCase {
    private let confirmDelete = "sidebar.confirmDeleteRecordings"
    private let startRecording = "recordings.start.new"
    private let sidebarRecording = "recordings.sidebar.new"

    private func fixture() async throws -> (AppModel, [Manifest]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(root: root)
        let suite = "LocalScribeTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let rows = try ["Alpha", "Beta", "Gamma"].enumerated().map { index, title in
            var row = Manifest(sourceType: "import", title: title, filename: "test.wav")
            row.createdAt = Date(timeIntervalSince1970: Double(30 - index))
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
            return row
        }
        let model = AppModel(repository: repository, startServices: false, userDefaults: defaults)
        await model.reload()
        await model.recordingSearch.waitUntilIdle()
        return (model, rows)
    }

    private func host(_ model: AppModel) -> NSWindow {
        NSApplication.shared.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let window = KeyboardTestWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 560),
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
                     repeatKey: Bool = false, in window: NSWindow) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: repeatKey, keyCode: UInt16(keyCode)))
        NSApplication.shared.sendEvent(event)
    }

    private func escape(_ window: NSWindow) throws { try key(kVK_Escape, "\u{1b}", in: window) }

    private func commandDelete(_ window: NSWindow, modifiers: NSEvent.ModifierFlags = .command,
                               repeatKey: Bool = false) throws {
        try key(kVK_Delete, "\u{7f}", modifiers: modifiers, repeatKey: repeatKey, in: window)
    }

    private func click(_ id: String, modifiers: NSEvent.ModifierFlags = [], in window: NSWindow) throws {
        let row = try XCTUnwrap(element(id, in: window.contentView))
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

    private func clickRecording(_ row: Manifest, modifiers: NSEvent.ModifierFlags = [],
                                in window: NSWindow) throws {
        try click("sidebar.recording.\(row.id)", modifiers: modifiers, in: window)
    }

    func testEscapeKeepsSearchLocalAndClosesEitherWorkspaceSelection() async throws {
        let (model, rows) = try await fixture()
        let diagram = DiagramManifest(title: "Architecture", filename: "a.png", ext: "png", uti: "public.png")
        let diagramArchive = try XCTUnwrap(model.diagramArchive)
        try await diagramArchive.save(diagram)
        await model.reloadDiagrams()
        let window = host(model)
        defer { window.close() }
        try await settle(window)

        try clickRecording(rows[0], in: window)
        try key(kVK_ANSI_F, "f", modifiers: .command, in: window)
        try await settle(window)
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.insertText("Alpha", replacementRange: editor.selectedRange())
        XCTAssertEqual(model.recordingSearch.query, "Alpha")
        try escape(window)
        try await settle(window)
        XCTAssertEqual(model.recordingSearch.query, "")
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertEqual(model.selection, rows[0].id)
        try escape(window)
        try await settle(window)
        XCTAssertFalse(window.firstResponder === editor)
        XCTAssertEqual(model.selection, rows[0].id)

        let resultView = try XCTUnwrap(window.contentView?.descendants(of: NSTextView.self).first { !$0.isEditable })
        XCTAssertTrue(window.makeFirstResponder(resultView))
        try escape(window)
        try await settle(window)
        XCTAssertNil(model.selection)
        XCTAssertTrue(model.sidebarSelection.ids.isEmpty)
        XCTAssertNotNil(element(startRecording, in: window.contentView))

        // Clear the selection before the reopened recording's load can publish.
        try clickRecording(rows[0], in: window)
        try escape(window)
        try await settle(window)
        XCTAssertNil(model.transcript)
        XCTAssertNil(model.selection)
        XCTAssertTrue(model.sidebarSelection.ids.isEmpty)
        XCTAssertNotNil(element(startRecording, in: window.contentView))

        try clickRecording(rows[0], in: window)
        try mode("Схемы", in: window)
        try await settle(window)
        try escape(window)
        XCTAssertEqual(model.selection, rows[0].id)
        XCTAssertNotNil(element("diagrams.search", in: window.contentView))
        try click("diagrams.sidebar.diagram.\(diagram.id)", in: window)
        try escape(window)
        try await settle(window)
        XCTAssertNil(model.selection)
        XCTAssertTrue(model.sidebarSelection.ids.isEmpty)
        XCTAssertNotNil(element(startRecording, in: window.contentView))
        XCTAssertNil(element("diagrams.search", in: window.contentView))
        XCTAssertNil(model.transcript)
        XCTAssertNil(model.summary)
        await model.shutdown()
    }

    func testCommandDeleteAfterNativeSelectionUsesCancelableSheetAndProtectsSelection() async throws {
        let (model, rows) = try await fixture()
        let window = host(model)
        defer { window.close() }
        try await settle(window)
        try clickRecording(rows[0], in: window)
        try await settle(window)
        try clickRecording(rows[2], modifiers: .command, in: window)
        XCTAssertEqual(model.sidebarSelection.ids, [rows[0].id, rows[2].id])
        try await settle(window)
        try clickRecording(rows[0], modifiers: .shift, in: window)
        XCTAssertEqual(model.sidebarSelection.ids, Set(rows.map(\.id)))

        for modifiers: NSEvent.ModifierFlags in [[], [.command, .shift], [.command, .control], [.command, .option]] {
            try commandDelete(window, modifiers: modifiers)
        }
        try commandDelete(window, repeatKey: true)
        model.recordingID = rows[0].id
        try commandDelete(window)
        try await settle(window)
        XCTAssertNil(window.attachedSheet)
        model.recordingID = nil

        try commandDelete(window, modifiers: [.command, .capsLock])
        try await settle(window)
        let sheet = try XCTUnwrap(window.attachedSheet)
        XCTAssertNotNil(element(confirmDelete, in: sheet.contentView))
        try commandDelete(window)
        try escape(window) // A parent-targeted event must also leave the selection intact.
        XCTAssertEqual(model.selection, rows[0].id)
        XCTAssertTrue(window.attachedSheet === sheet)
        try escape(sheet)
        try await settle(window)
        XCTAssertNil(window.attachedSheet)
        XCTAssertEqual(model.selection, rows[0].id)
        XCTAssertEqual(Set(model.recordings.map(\.id)), Set(rows.map(\.id)))
        XCTAssertEqual(model.sidebarSelection.ids, Set(rows.map(\.id)))
        await model.shutdown()
    }

    func testCommandDeleteUsesCurrentSearchRowsAndFreezesConfirmation() async throws {
        let (model, rows) = try await fixture()
        let window = host(model)
        defer { window.close() }
        try await settle(window)
        try clickRecording(rows[0], in: window)
        try await settle(window)
        try clickRecording(rows[1], modifiers: .command, in: window)
        window.makeFirstResponder(window)

        model.recordingSearch.query = "Alpha"
        XCTAssertFalse(model.recordingSearch.hasCurrentQueryResults)
        try commandDelete(window)
        await model.recordingSearch.waitUntilIdle()
        try await settle(window)
        XCTAssertNil(window.attachedSheet)
        XCTAssertEqual(model.recordingSearch.matchingIDs, [rows[0].id])

        model.recordingSearch.query = "Beta"
        XCTAssertTrue(model.recordingSearch.completed)
        XCTAssertFalse(model.recordingSearch.hasCurrentQueryResults)
        try commandDelete(window)
        await model.recordingSearch.waitUntilIdle()
        try await settle(window)
        XCTAssertNil(window.attachedSheet)
        XCTAssertEqual(model.recordingSearch.matchingIDs, [rows[1].id])

        try clickRecording(rows[1], in: window)
        try key(kVK_ANSI_F, "f", modifiers: .command, in: window)
        try await settle(window)
        XCTAssertTrue(window.firstResponder is NSTextView)
        try commandDelete(window)
        try await settle(window)
        XCTAssertNil(window.attachedSheet)
        window.makeFirstResponder(window)

        model.recordingSearch.query = "Beta"
        await model.recordingSearch.waitUntilIdle()
        model.recordingSearch.setExpanded(RecordingGroup.ungroupedID, false)
        try commandDelete(window)
        try await settle(window)
        XCTAssertNil(window.attachedSheet)
        model.recordingSearch.setExpanded(RecordingGroup.ungroupedID, true)
        try commandDelete(window)
        try await settle(window)
        let sheet = try XCTUnwrap(window.attachedSheet)
        model.recordingSearch.query = ""
        model.selection = rows[2].id
        try press(confirmDelete, in: sheet)
        for _ in 0..<20 where model.recordings.contains(where: { $0.id == rows[1].id }) {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(Set(model.recordings.map(\.id)), [rows[0].id, rows[2].id])
        await model.shutdown()
    }

    func testBothNewRecordingButtonsShowSameSheetAndShareAvailability() async throws {
        let (model, rows) = try await fixture()
        let window = host(model)
        defer { window.close() }
        try await settle(window)
        for id in [sidebarRecording, startRecording] {
            try press(id, in: window)
            try await settle(window)
            let sheet = try XCTUnwrap(window.attachedSheet)
            XCTAssertNotNil(element("recording.destination", in: sheet.contentView))
            try escape(sheet)
            try await settle(window)
            XCTAssertNil(window.attachedSheet)
        }
        for state in [\.startingRecording, \.finalizingRecording, \.installing] as [ReferenceWritableKeyPath<AppModel, Bool>] {
            model[keyPath: state] = true
            try await settle(window)
            for id in [sidebarRecording, startRecording] {
                let button = try XCTUnwrap(element(id, in: window.contentView))
                XCTAssertEqual(button.isAccessibilityEnabled?(), false, id)
            }
            model[keyPath: state] = false
        }
        model.recordingID = rows[0].id
        model.selection = rows[1].id
        try await settle(window)
        window.makeFirstResponder(window)
        try escape(window)
        try await settle(window)
        XCTAssertNil(model.selection)
        XCTAssertEqual(model.recordingID, rows[0].id)
        for id in [sidebarRecording, startRecording] {
            let button = try XCTUnwrap(element(id, in: window.contentView))
            XCTAssertEqual(button.isAccessibilityEnabled?(), false, id)
        }
        model.recordingID = nil
        await model.shutdown()
    }
}

/// XCTest may be running in a background process. Exercise the native event
/// delivery without asking macOS to move keyboard focus away from other apps.
private final class KeyboardTestWindow: NSWindow {
    override var isKeyWindow: Bool { isVisible }
}

private extension NSView {
    func descendants<T: NSView>(of type: T.Type) -> [T] {
        subviews.compactMap { $0 as? T } + subviews.flatMap { $0.descendants(of: type) }
    }
}
