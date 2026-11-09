import AppKit
import XCTest
import LocalScribeCore
@testable import LocalScribe

@MainActor
final class AppErrorHandlerTests: XCTestCase {
    func testUnreadableArchiveItemsAreReportedOnceAcrossReloads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root)
        let item = Manifest(sourceType: "import", title: "Damaged", filename: "audio.wav")
        try repo.save(item)
        let file = repo.folder(item.id).appendingPathComponent("manifest.json")
        try Data("broken".utf8).write(to: file)
        let suite = "ArchiveDiagnostics." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(repository: repo, startServices: false, userDefaults: defaults)
        await model.reload(); await model.reload()
        XCTAssertEqual(model.errorHandler.messages.count, 1)
        XCTAssertTrue(model.errorHandler.messages[0].contains(item.id))
        XCTAssertTrue(model.errorHandler.messages[0].contains("Файлы сохранены"))
        XCTAssertTrue(model.recordings.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), Data("broken".utf8))
        await model.shutdown()
    }

    func testStartupErrorsWaitForPresentationAndReuseOneWindowWithoutLosingMessages() throws {
        _ = NSApplication.shared
        let handler = AppErrorHandler()
        handler.report(ScribeError.message("Первая ошибка"))
        XCTAssertNil(handler.window)
        handler.startPresenting()
        let window = try XCTUnwrap(handler.window)
        defer { while !handler.messages.isEmpty { handler.dismissCurrent() } }
        XCTAssertTrue(window.isVisible)
        handler.report(message: "Вторая ошибка")
        XCTAssertTrue(handler.window === window)
        XCTAssertEqual(handler.messages, ["Первая ошибка", "Вторая ошибка"])
        // The title-bar close button acknowledges one message, just like Next.
        window.performClose(nil)
        XCTAssertEqual(handler.messages, ["Вторая ошибка"])
        XCTAssertTrue(handler.window === window)
        XCTAssertTrue(window.isVisible)
        window.performClose(nil)
        XCTAssertTrue(handler.messages.isEmpty)
        XCTAssertNil(handler.window)
        XCTAssertFalse(window.isVisible)
        handler.report(message: "Новая ошибка")
        XCTAssertTrue(handler.window?.isVisible == true)
        XCTAssertFalse(handler.window === window)
    }

    func testCancellationAndEmptyMessagesDoNotOpenAnErrorWindow() {
        let handler = AppErrorHandler()
        handler.startPresenting()
        handler.report(CancellationError())
        handler.report(message: nil)
        handler.report(message: "")
        XCTAssertTrue(handler.messages.isEmpty)
        XCTAssertNil(handler.window)
    }

    func testCopyWritesFullDiagnosticsAndKeepsWindowOpen() throws {
        _ = NSApplication.shared
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let handler = AppErrorHandler(pasteboard: pasteboard)
        handler.startPresenting()
        handler.report(message: "Не удалось сохранить правки")
        let panel = try XCTUnwrap(handler.window)
        XCTAssertTrue(panel.isVisible)
        let text = try XCTUnwrap(handler.copyCurrent())
        for needle in ["LocalScribe", AppInfo.version, AppInfo.build, "macOS", "Время ошибки:",
                       "Не удалось сохранить правки"] {
            XCTAssertTrue(text.contains(needle), "Копия ошибки должна содержать: \(needle)")
        }
        XCTAssertNotNil(text.range(of: #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}"#, options: .regularExpression),
                        "Время ошибки должно быть в формате ISO 8601")
        XCTAssertEqual(pasteboard.string(forType: .string), text)
        // Копирование не закрывает окно и не забирает сообщение из очереди.
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(handler.messages, ["Не удалось сохранить правки"])
        XCTAssertEqual(handler.reports.count, 1)
    }

    func testCopyButtonCopiesShownMessageWithoutDismissingWindow() throws {
        _ = NSApplication.shared
        NSApplication.shared.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let handler = AppErrorHandler(pasteboard: pasteboard)
        handler.startPresenting()
        handler.report(message: "Ошибка архива")
        handler.report(message: "Вторая")
        let panel = try XCTUnwrap(handler.window)
        let hosting = try XCTUnwrap(panel.contentView)
        let deadline = Date().addingTimeInterval(1)
        var copyButton: AnyObject?
        while Date() < deadline {
            copyButton = descendants(of: hosting).first { $0.accessibilityIdentifier?() == "error.copy" }
            if copyButton != nil { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        let button = try XCTUnwrap(copyButton, "Кнопка копирования должна быть в окне ошибки")
        XCTAssertEqual(button.accessibilityLabel?(), "Копировать ошибку")
        XCTAssertTrue(button.accessibilityPerformPress?() ?? false)
        XCTAssertEqual(pasteboard.string(forType: .string), handler.reports.first?.clipboardText)
        XCTAssertTrue(pasteboard.string(forType: .string)?.contains("Ошибка архива") == true)
        // Копирование не подтверждает сообщение: окно и очередь без изменений.
        XCTAssertEqual(handler.messages, ["Ошибка архива", "Вторая"])
        XCTAssertTrue(panel.isVisible)
        handler.dismissCurrent()
        XCTAssertEqual(handler.messages, ["Вторая"])
        XCTAssertTrue(panel.isVisible)
    }

    // SwiftUI nodes implement the Objective-C accessibility methods without
    // declaring NSAccessibilityProtocol conformance, so use dynamic dispatch.
    private func descendants(of element: AnyObject) -> [AnyObject] {
        let children = (element.accessibilityChildren?() ?? []).map { $0 as AnyObject }
        return children + children.flatMap { descendants(of: $0) }
    }

    func testErrorsCanBeAcknowledgedWhileEditorSheetStaysOpen() async throws {
        _ = NSApplication.shared
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                             styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        sheet.isReleasedWhenClosed = false
        parent.orderFront(nil)
        parent.beginSheet(sheet, completionHandler: nil)
        let handler = AppErrorHandler()
        defer {
            while !handler.messages.isEmpty { handler.dismissCurrent() }
            parent.endSheet(sheet)
            sheet.close()
            parent.close()
        }
        handler.startPresenting()
        handler.report(message: "Не удалось сохранить правки")
        let panel = try XCTUnwrap(handler.window)
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(panel.worksWhenModal)
        XCTAssertGreaterThanOrEqual(panel.level.rawValue, sheet.level.rawValue)
        panel.performClose(nil)
        XCTAssertNil(handler.window)
        XCTAssertTrue(parent.attachedSheet === sheet)
    }
}
