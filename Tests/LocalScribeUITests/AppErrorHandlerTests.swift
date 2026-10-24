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
