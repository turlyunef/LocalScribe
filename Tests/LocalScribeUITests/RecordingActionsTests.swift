import AppKit
import SwiftUI
import XCTest
@testable import LocalScribe

@MainActor
final class RecordingActionsTests: XCTestCase {
    private let identifiers = [
        "recording.showAudio", "result.edit", "recording.repeatAnalysis",
        "recording.recreateSummary", "recording.delete"
    ]

    private func withActions(
        canEdit: Bool = true,
        canRepeatAnalysis: Bool = true,
        canRecreateSummary: Bool = true,
        canDelete: Bool = true,
        showAudio: @escaping () -> Void = {},
        editResult: @escaping () -> Void = {},
        repeatAnalysis: @escaping () -> Void = {},
        deleteRecording: @escaping () -> Void = {},
        check: (NSHostingView<RecordingActionsView>) throws -> Void
    ) rethrows {
        _ = NSApplication.shared
        // SwiftUI creates its complete accessibility tree on demand in a test host.
        NSApplication.shared.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let view = RecordingActionsView(
            canEdit: canEdit,
            canRepeatAnalysis: canRepeatAnalysis,
            canRecreateSummary: canRecreateSummary,
            canDelete: canDelete,
            showAudio: showAudio,
            editResult: editResult,
            repeatAnalysis: repeatAnalysis,
            recreateSummary: { _ in },
            deleteRecording: deleteRecording
        )
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 80),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(1)
        while descendants(of: hosting).count < identifiers.count && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        try check(hosting)
    }

    // SwiftUI nodes implement the Objective-C accessibility methods without
    // declaring NSAccessibilityProtocol conformance, so use dynamic dispatch.
    private func descendants(of element: AnyObject) -> [AnyObject] {
        let children = (element.accessibilityChildren?() ?? []).map { $0 as AnyObject }
        return children + children.flatMap { descendants(of: $0) }
    }

    private func action(_ identifier: String, in hosting: NSHostingView<RecordingActionsView>) throws -> AnyObject {
        try XCTUnwrap(descendants(of: hosting).first { $0.accessibilityIdentifier?() == identifier },
                      "Действие \(identifier) должно быть доступно без открытия меню")
    }

    private func accessibleName(of element: AnyObject) -> String? {
        // SwiftUI menus can return an attributed title through the AppKit bridge.
        guard let object = element as? NSObject else { return nil }
        for name in ["accessibilityLabel", "accessibilityTitle"] {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector) else { continue }
            let value = object.perform(selector)?.takeUnretainedValue()
            if let text = value as? NSAttributedString { return text.string }
            if let text = value as? String { return text }
        }
        return nil
    }

    func testActionsAreVisibleInOneRowWithAccessibleDeleteIcon() async throws {
        try withActions { hosting in
            let actions = try identifiers.map { try action($0, in: hosting) }
            XCTAssertEqual(actions[0].accessibilityLabel?(), "Показать аудио в Finder")
            XCTAssertEqual(actions[1].accessibilityLabel?(), "Редактировать")
            XCTAssertEqual(actions[2].accessibilityLabel?(), "Обработать заново")
            XCTAssertEqual(accessibleName(of: actions[3]), "Пересоздать итоги")
            XCTAssertEqual(actions[4].accessibilityLabel?(), "Удалить запись")
            let frames = try actions.map { try XCTUnwrap($0.accessibilityFrame?()) }
            for frame in frames {
                XCTAssertGreaterThan(frame.width, 0)
                XCTAssertGreaterThan(frame.height, 0)
                XCTAssertEqual(frame.midY, frames[0].midY, accuracy: 2)
            }
            for (left, right) in zip(frames, frames.dropFirst()) {
                XCTAssertLessThanOrEqual(left.maxX, right.minX)
            }
            // The trash control stays compact instead of displaying a text button.
            XCTAssertLessThan(frames[4].width, 40)
            XCTAssertEqual(actions[4].accessibilityRole?(), .button)
        }
    }

    func testDirectButtonsInvokeTheirOwnActions() async throws {
        var calls: [String] = []
        try withActions(showAudio: { calls.append("audio") },
                        editResult: { calls.append("edit") },
                        repeatAnalysis: { calls.append("analysis") },
                        deleteRecording: { calls.append("delete") }) { hosting in
            for identifier in identifiers where identifier != "recording.recreateSummary" {
                XCTAssertTrue(try action(identifier, in: hosting).accessibilityPerformPress?() ?? false)
            }
            XCTAssertEqual(calls, ["audio", "edit", "analysis", "delete"])
        }
    }

    func testUnavailableActionsRemainVisibleAndDisabled() async throws {
        try withActions(canEdit: false, canRepeatAnalysis: false, canRecreateSummary: false, canDelete: false) { hosting in
            XCTAssertTrue(try action(identifiers[0], in: hosting).isAccessibilityEnabled?() ?? false)
            for identifier in identifiers.dropFirst() {
                XCTAssertFalse(try action(identifier, in: hosting).isAccessibilityEnabled?() ?? false)
            }
        }
    }

    func testDisabledSummaryDoesNotDisableOtherActions() async throws {
        try withActions(canRecreateSummary: false) { hosting in
            XCTAssertFalse(try action("recording.recreateSummary", in: hosting).isAccessibilityEnabled?() ?? false)
            for identifier in identifiers where identifier != "recording.recreateSummary" {
                XCTAssertTrue(try action(identifier, in: hosting).isAccessibilityEnabled?() ?? false)
            }
        }
    }

    func testActionTooltipsAreAvailableWhenEnabledAndDisabled() async throws {
        let expected = [
            "Показать исходный аудиофайл записи в Finder",
            "Изменить текст расшифровки и итогов",
            "Заново распознать речь, определить участников и создать итоги",
            "Создать новые итоги по готовой расшифровке на выбранном языке",
            "Удалить запись"
        ]
        for enabled in [true, false] {
            try withActions(canEdit: enabled, canRepeatAnalysis: enabled, canRecreateSummary: enabled, canDelete: enabled) { hosting in
                for (identifier, help) in zip(identifiers, expected) {
                    XCTAssertEqual(try action(identifier, in: hosting).accessibilityHelp?(), help)
                }
            }
        }
    }
}
