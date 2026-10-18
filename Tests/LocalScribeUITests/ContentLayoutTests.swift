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
