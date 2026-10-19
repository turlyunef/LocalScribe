import AppKit
import SwiftUI
import XCTest
import LocalScribeCore
@testable import LocalScribe

@MainActor
final class ContentLayoutTests: XCTestCase {
    private func descendants(_ element: AnyObject) -> [AnyObject] {
        let children = (element.accessibilityChildren?() ?? []).map { $0 as AnyObject }
        return children + children.flatMap { descendants($0) }
    }

    private func subviews(_ view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { subviews($0) }
    }

    private func element(_ id: String, in view: NSView) throws -> AnyObject {
        try XCTUnwrap(descendants(view).first { $0.accessibilityIdentifier?() == id }, id)
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

    private func host<V: View>(_ view: V, width: CGFloat, height: CGFloat = 700) -> (NSHostingView<V>, NSWindow) {
        _ = NSApplication.shared
        NSApplication.shared.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        return (hosting, window)
    }

    private func settle(_ view: NSView) async throws {
        // Let SwiftUI update both its layout and accessibility tree.
        try await Task.sleep(for: .milliseconds(100))
        view.layoutSubtreeIfNeeded()
    }

    func testBackgroundRecognitionIsStandardCheckboxAboveHardwareInSettings() async throws {
        let suite = "LocalScribeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(repository: try RecordingRepository(root: root), startServices: false,
                             userDefaults: defaults)
        let (hosting, window) = host(ModelSettings(model: model), width: 760, height: 1300)
        defer { window.close() }
        try await settle(hosting)
        let checkbox = try element("settings.backgroundRecognition", in: hosting)
        XCTAssertEqual(checkbox.accessibilityRole?(), .checkBox)
        XCTAssertEqual(checkbox.accessibilityLabel?(), "Распознавать во время записи")
        let object = try XCTUnwrap(checkbox as? NSObject)
        let value = object.perform(NSSelectorFromString("accessibilityValue"))?.takeUnretainedValue() as? NSNumber
        XCTAssertEqual(value?.boolValue, true)
        XCTAssertTrue(checkbox.isAccessibilityEnabled?() ?? false)
        let frame = try XCTUnwrap(checkbox.accessibilityFrame?())
        let hardware = try XCTUnwrap(element("settings.hardware", in: hosting).accessibilityFrame?())
        XCTAssertGreaterThan(frame.width, 0)
        XCTAssertGreaterThanOrEqual(frame.minY, hardware.maxY)
        XCTAssertNotNil(try element("settings.backgroundRecognition.modelsRequired", in: hosting))

        XCTAssertTrue(checkbox.accessibilityPerformPress?() ?? false)
        try await settle(hosting)
        XCTAssertFalse(model.backgroundRecognition)
        XCTAssertEqual(defaults.object(forKey: "backgroundRecognition") as? Bool, false)
        XCTAssertFalse(descendants(hosting).contains {
            $0.accessibilityIdentifier?() == "settings.backgroundRecognition.modelsRequired"
        })
        model.backgroundRecognition = true
        model.modelsReady = true
        try await settle(hosting)
        XCTAssertFalse(descendants(hosting).contains {
            $0.accessibilityIdentifier?() == "settings.backgroundRecognition.modelsRequired"
        })

        for state in 0..<4 {
            model.recordingID = state == 0 ? UUID().uuidString : nil
            model.startingRecording = state == 1
            model.finalizingRecording = state == 2
            try await settle(hosting)
            XCTAssertEqual(try element("settings.backgroundRecognition", in: hosting).isAccessibilityEnabled?(), state == 3)
        }
    }

    func testMainWindowAndResultEditorHaveNoBackgroundRecognitionControl() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root)
        let manifest = Manifest(sourceType: "import", title: "Встреча", filename: "meeting.wav")
        try repo.save(manifest)
        let model = AppModel(repository: repo, startServices: false)
        let (hosting, window) = host(ContentView(model: model), width: 1200)
        defer { window.close() }
        for selection in [nil, manifest.id] {
            model.selection = selection
            try await settle(hosting)
            XCTAssertFalse(descendants(hosting).contains {
                text($0) == "Распознавать во время записи"
                    || $0.accessibilityIdentifier?() == "recording.backgroundRecognition"
                    || $0.accessibilityIdentifier?() == "settings.backgroundRecognition"
            })
        }
        let draft = ResultEditDraft(recordingID: manifest.id, runID: UUID().uuidString,
            transcript: Transcript(fingerprint: "f", diarized: true, segments: []), summary: nil)
        let (editor, editorWindow) = host(ResultEditorView(initial: draft, save: { _ in }, cancel: {}, reportError: { _ in }), width: 800)
        defer { editorWindow.close() }
        try await settle(editor)
        XCTAssertFalse(descendants(editor).contains { text($0) == "Распознавать во время записи" })
    }

    func testAutomaticSummariesCheckboxIsBelowBackgroundRecognitionAndSavesChoice() async throws {
        let suite = "LocalScribeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(repository: try RecordingRepository(root: root), startServices: false, userDefaults: defaults)
        let (hosting, window) = host(ModelSettings(model: model), width: 760, height: 1400)
        defer { window.close() }
        try await settle(hosting)
        let checkbox = try element("settings.automaticSummaries", in: hosting)
        XCTAssertEqual(checkbox.accessibilityRole?(), .checkBox)
        XCTAssertEqual(checkbox.accessibilityLabel?(), "Создавать автоматически итоги встречи")
        let object = try XCTUnwrap(checkbox as? NSObject)
        let value = object.perform(NSSelectorFromString("accessibilityValue"))?.takeUnretainedValue() as? NSNumber
        XCTAssertEqual(value?.boolValue, true)
        let frame = try XCTUnwrap(checkbox.accessibilityFrame?())
        let background = try XCTUnwrap(element("settings.backgroundRecognition", in: hosting).accessibilityFrame?())
        let hardware = try XCTUnwrap(element("settings.hardware", in: hosting).accessibilityFrame?())
        XCTAssertGreaterThan(frame.width, 0)
        XCTAssertLessThanOrEqual(frame.maxY, background.minY)
        XCTAssertGreaterThanOrEqual(frame.minY, hardware.maxY)
        XCTAssertTrue(checkbox.accessibilityPerformPress?() ?? false)
        try await settle(hosting)
        XCTAssertFalse(model.automaticSummaries)
        XCTAssertTrue(model.backgroundRecognition)
        XCTAssertEqual(defaults.object(forKey: "automaticSummaries") as? Bool, false)
        await model.shutdown()
    }

    func testDisabledAutomaticSummariesNoticeOnlyReplacesMissingSummary() async throws {
        let suite = "LocalScribeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root)
        let manifest = Manifest(sourceType: "import", title: "Встреча", filename: "meeting.wav")
        try repo.save(manifest)
        let model = AppModel(repository: repo, startServices: false, userDefaults: defaults)
        model.selection = manifest.id
        let (hosting, window) = host(ContentView(model: model), width: 1200)
        defer { window.close() }
        try await settle(hosting)
        model.automaticSummaries = false; model.tab = .summary
        try await settle(hosting)
        XCTAssertEqual(text(try element("result.automaticSummariesDisabled", in: hosting)), "Автоматическое создание итогов отключено")
        for part in [ExportPart.transcript, .summary] {
            model.tab = part
            for enabled in [true, false] {
                model.automaticSummaries = enabled
                for summary in [nil, Summary(language: "en")] {
                    model.summary = summary
                    try await settle(hosting)
                    XCTAssertEqual(descendants(hosting).contains {
                        $0.accessibilityIdentifier?() == "result.automaticSummariesDisabled"
                    }, part == .summary && !enabled && summary == nil)
                }
            }
        }
        await model.shutdown()
    }

    func testSidebarStatusIsCenteredAboveModelsForBothStates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(repository: try RecordingRepository(root: root), startServices: false)
        let (hosting, window) = host(ContentView(model: model), width: 1200)
        defer { window.close() }
        for ready in [false, true] {
            model.modelsReady = ready
            try await settle(hosting)
            let label = try XCTUnwrap(element("sidebar.localProcessing", in: hosting).accessibilityFrame?())
            let button = try XCTUnwrap(element("sidebar.models", in: hosting).accessibilityFrame?())
            XCTAssertGreaterThan(label.width, 0)
            XCTAssertGreaterThan(button.width, 0)
            XCTAssertEqual(label.midX, button.midX, accuracy: 1)
            XCTAssertGreaterThanOrEqual(label.minY, button.maxY)
        }
    }

    func testResultHeaderOmitsLanguageForRussianAndEnglishSummaries() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root)
        let manifest = Manifest(sourceType: "import", title: "Встреча", filename: "meeting.wav")
        try repo.save(manifest)
        let model = AppModel(repository: repo, startServices: false)
        model.selection = manifest.id
        let (hosting, window) = host(ContentView(model: model), width: 1200)
        defer { window.close() }
        try await settle(hosting)
        for width: CGFloat in [1000, 1400] {
            window.setContentSize(NSSize(width: width, height: 700))
            for language in ["ru", "en"] {
                model.summary = Summary(language: language)
                for part in [ExportPart.transcript, .summary] {
                    model.tab = part
                    try await settle(hosting)
                    let picker = try element("result.section", in: hosting)
                    XCTAssertGreaterThan(try XCTUnwrap(picker.accessibilityFrame?()).width, 0)
                    let languageLabels = descendants(hosting).filter {
                        let label = text($0)
                        return label == "Русский" || label == "English"
                    }
                    XCTAssertTrue(languageLabels.isEmpty, "Язык не должен отображаться рядом с разделами результата")
                }
            }
        }
    }

    func testTranscriptDeleteButtonsStayOutsideVerticalScrollerAtBothEditorWidths() async throws {
        let segments = (0..<30).map { index in
            Segment(id: "s\(index)", startMs: index * 1000, endMs: (index + 1) * 1000,
                    text: "Реплика \(index)", language: "ru")
        }
        let draft = ResultEditDraft(recordingID: UUID().uuidString, runID: UUID().uuidString,
            transcript: Transcript(fingerprint: "f", diarized: true, segments: segments), summary: nil)
        let (hosting, window) = host(ResultEditorView(initial: draft, save: { _ in }, cancel: {}, reportError: { _ in }),
                                     width: 800)
        defer { window.close() }
        try await settle(hosting)
        // The outer scroll view contains the individual TextEditor scroll views.
        let scroll = try XCTUnwrap(subviews(hosting).compactMap { $0 as? NSScrollView }.first)
        for width: CGFloat in [700, 800] {
            window.setContentSize(NSSize(width: width, height: 550))
            for style in [NSScroller.Style.overlay, .legacy] {
                scroll.scrollerStyle = style
                scroll.hasVerticalScroller = true
                scroll.autohidesScrollers = false
                for offset: CGFloat in [0, 180] {
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    try await settle(hosting)
                    let scroller = try XCTUnwrap(scroll.verticalScroller)
                    let scrollerFrame = window.convertToScreen(scroller.convert(scroller.bounds, to: nil))
                    XCTAssertGreaterThan(scrollerFrame.width, 0)
                    let visibleButtons = descendants(hosting).filter {
                        guard ($0.accessibilityIdentifier?() ?? "").hasPrefix("edit.deleteSegment."),
                              let frame = $0.accessibilityFrame?() else { return false }
                        return frame.intersects(window.convertToScreen(scroll.convert(scroll.bounds, to: nil)))
                    }
                    XCTAssertFalse(visibleButtons.isEmpty)
                    for button in visibleButtons {
                        let frame = try XCTUnwrap(button.accessibilityFrame?())
                        XCTAssertLessThanOrEqual(frame.maxX + 2, scrollerFrame.minX,
                                                 "Кнопка удаления должна оставлять зазор перед скроллбаром")
                    }
                }
            }
        }
    }
}
