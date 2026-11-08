import AppKit
import SwiftUI
import UniformTypeIdentifiers
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

    private func findElement(_ id: String, in view: NSView) -> AnyObject? {
        if let element = descendants(view).first(where: { $0.accessibilityIdentifier?() == id }) { return element }
        // Native List cells expose their SwiftUI content through their hosting views.
        for subview in subviews(view) {
            if let element = descendants(subview).first(where: { $0.accessibilityIdentifier?() == id }) { return element }
        }
        return nil
    }

    private func element(_ id: String, in view: NSView) throws -> AnyObject {
        try XCTUnwrap(findElement(id, in: view), id)
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

    private func assertActionAlignment(_ primaryID: String, in view: NSView) throws {
        let queueActions = primaryID == "recording.moveToFront" ? [primaryID, "recording.cancel"] : [primaryID]
        let identifiers = queueActions + ["recording.showAudio", "recording.repeatAnalysis",
                           "recording.recreateSummary", "recording.delete"]
        let frames = try identifiers.map { try XCTUnwrap(element($0, in: view).accessibilityFrame?()) }
        for frame in frames {
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertEqual(frame.midY, frames[0].midY, accuracy: 2)
        }
        for (left, right) in zip(frames, frames.dropFirst()) {
            XCTAssertLessThanOrEqual(left.maxX, right.minX)
        }
        XCTAssertEqual(frames[0].height, frames[1].height, accuracy: 2)
    }

    func testQueueNumbersAndPromotionButtonUpdateWithoutReloadingRecordings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "LocalScribeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repo = try RecordingRepository(root: root)
        let manifests = try (1...3).map { index in
            var m = Manifest(sourceType: "import", title: "Запись \(index)", filename: "meeting.wav")
            m.sourceComplete = true
            try repo.save(m)
            return m
        }
        let model = AppModel(repository: repo, startServices: false, userDefaults: defaults)
        // Hold the worker before it starts; enqueue still uses the real coordinator.
        model.installing = true
        model.modelsReady = true
        for m in manifests { await model.enqueue(m.id) }
        let originalRecordingOrder = model.recordings.map(\.id)
        model.selection = manifests[2].id
        let (hosting, window) = host(ContentView(model: model), width: 1400)
        defer { window.close() }
        try await settle(hosting)

        model.pauseForCaptureResources(memoryPressure: true)
        try await settle(hosting)
        XCTAssertEqual(model.resourcePauseTitle, "Очередь приостановлена: не хватает памяти")
        XCTAssertTrue(text(try element("queue.resourcePause", in: hosting))?.contains("продолжится автоматически") == true)
        XCTAssertEqual(text(try element("recording.status.\(manifests[0].id)", in: hosting)),
                       "Очередь приостановлена: не хватает памяти")
        model.resumeAfterMemoryPressure()
        try await settle(hosting)
        XCTAssertNil(findElement("queue.resourcePause", in: hosting))

        for (index, m) in manifests.enumerated() {
            let number = try element("recording.queuePosition.\(m.id)", in: hosting)
            XCTAssertEqual(text(number), "Место в очереди: \(index + 1)")
            let numberFrame = try XCTUnwrap(number.accessibilityFrame?())
            let statusFrame = try XCTUnwrap(element("recording.status.\(m.id)", in: hosting).accessibilityFrame?())
            XCTAssertLessThan(numberFrame.maxX, statusFrame.minX)
            XCTAssertEqual(numberFrame.midY, statusFrame.midY, accuracy: 2)
            XCTAssertEqual(numberFrame.height, statusFrame.height, accuracy: 2)
        }
        let button = try element("recording.moveToFront", in: hosting)
        XCTAssertEqual(text(button), "Поднять на верх очереди")
        XCTAssertEqual(text(try element("recording.cancel", in: hosting)), "Отменить")
        XCTAssertFalse(descendants(hosting).contains { $0.accessibilityIdentifier?() == "recording.resume" })
        for width: CGFloat in [1100, 1400] {
            window.setContentSize(NSSize(width: width, height: 700))
            try await settle(hosting)
            try assertActionAlignment("recording.moveToFront", in: hosting)
        }
        XCTAssertTrue(button.accessibilityPerformPress?() ?? false)
        try await settle(hosting)
        for (index, m) in manifests.enumerated() {
            XCTAssertEqual(text(try element("recording.queuePosition.\(m.id)", in: hosting)),
                           "Место в очереди: \([2, 3, 1][index])")
        }
        XCTAssertEqual(model.queuePosition(for: manifests[2].id), 1)
        XCTAssertEqual(model.recordings.map(\.id), originalRecordingOrder)

        XCTAssertTrue(try element("recording.cancel", in: hosting).accessibilityPerformPress?() ?? false)
        // The action belongs to the displayed recording even if selection changes
        // before its asynchronous task runs.
        model.selection = manifests[0].id
        try await settle(hosting)
        XCTAssertEqual(try repo.load(manifests[2].id).state, .cancelled)
        XCTAssertEqual(try repo.load(manifests[0].id).state, .queued)
        model.selection = manifests[2].id
        try await settle(hosting)
        XCTAssertNil(findElement("recording.moveToFront", in: hosting))
        XCTAssertNil(findElement("recording.cancel", in: hosting))
        XCTAssertNotNil(findElement("recording.resume", in: hosting))
        XCTAssertNil(findElement("recording.queuePosition.\(manifests[2].id)", in: hosting))
        XCTAssertEqual(text(try element("recording.queuePosition.\(manifests[0].id)", in: hosting)), "Место в очереди: 1")
        XCTAssertEqual(text(try element("recording.queuePosition.\(manifests[1].id)", in: hosting)), "Место в очереди: 2")

        // A microphone waiting for background ASR occupies the same queue.
        try await model.archive?.update(manifests[1].id) { m in
            m.state = .recording; m.sourceComplete = false; m.captureProcessing = .queued
        }
        await model.reload()
        model.recordingID = manifests[1].id
        model.selection = manifests[1].id
        try await settle(hosting)
        let captureNumber = try element("recording.queuePosition.\(manifests[1].id)", in: hosting)
        XCTAssertEqual(text(captureNumber), "Место в очереди: 2")
        let captureFrame = try XCTUnwrap(captureNumber.accessibilityFrame?())
        let captureStatus = try XCTUnwrap(element("recording.captureStatus.\(manifests[1].id)", in: hosting).accessibilityFrame?())
        XCTAssertLessThan(captureFrame.maxX, captureStatus.minX)
        XCTAssertEqual(captureFrame.midY, captureStatus.midY, accuracy: 2)
        XCTAssertTrue(try element("recording.moveToFront", in: hosting).accessibilityPerformPress?() ?? false)
        try await settle(hosting)
        XCTAssertEqual(text(try element("recording.queuePosition.\(manifests[1].id)", in: hosting)), "Место в очереди: 1")
        // Resource pressure can temporarily mark a queued microphone as interrupted.
        try await model.archive?.update(manifests[1].id) { $0.captureProcessing = .interrupted }
        await model.reload()
        try await settle(hosting)
        XCTAssertTrue(try element("recording.cancel", in: hosting).accessibilityPerformPress?() ?? false)
        try await settle(hosting)
        XCTAssertEqual(model.recordingID, manifests[1].id)
        XCTAssertEqual(try repo.load(manifests[1].id).state, .recording)
        XCTAssertEqual(try repo.load(manifests[1].id).captureProcessing, .cancelled)
        XCTAssertNil(model.queuePosition(for: manifests[1].id))
        XCTAssertNil(findElement("recording.cancel", in: hosting))
        model.recordingID = nil
        await model.shutdown()
    }

    func testResumeAlignmentAndPromotionIsHiddenForRecordsOutsideQueue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "LocalScribeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repo = try RecordingRepository(root: root)
        var m = Manifest(sourceType: "import", title: "Встреча", filename: "meeting.wav")
        m.sourceComplete = true
        try repo.save(m)
        let model = AppModel(repository: repo, startServices: false, userDefaults: defaults)
        await model.reload()
        model.selection = m.id
        let (hosting, window) = host(ContentView(model: model), width: 1400)
        defer { window.close() }
        for state in [JobState.recorded, .interrupted, .failed, .cancelled, .waitingForModels,
                      .completed, .completedWithWarnings, .transcribing, .recording, .queued] {
            try await model.archive?.update(m.id) { $0.state = state }
            await model.reload()
            try await settle(hosting)
            XCTAssertNil(findElement("recording.moveToFront", in: hosting), "No queue controls for \(state) without a queued job")
            XCTAssertNil(findElement("recording.queuePosition.\(m.id)", in: hosting))
            XCTAssertEqual(findElement("recording.cancel", in: hosting) != nil, state.processing)
            if [.recorded, .interrupted, .failed, .cancelled, .waitingForModels].contains(state) {
                for width: CGFloat in [1100, 1400] {
                    window.setContentSize(NSSize(width: width, height: 700))
                    try await settle(hosting)
                    try assertActionAlignment("recording.resume", in: hosting)
                }
            }
        }
        await model.shutdown()
    }

    func testBackgroundRecognitionIsStandardCheckboxInRecordingSettings() async throws {
        let suite = "LocalScribeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(repository: try RecordingRepository(root: root), startServices: false,
                             userDefaults: defaults)
        let draft = SettingsDraft(model: model)
        let (hosting, window) = host(ModelSettings(model: model, draft: draft), width: 760, height: 1300)
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
        XCTAssertGreaterThan(frame.width, 0)
        XCTAssertNil(findElement("settings.hardware", in: hosting))
        XCTAssertNil(findElement("settings.diagramModels.status", in: hosting))
        XCTAssertNotNil(try element("settings.backgroundRecognition.modelsRequired", in: hosting))

        XCTAssertTrue(checkbox.accessibilityPerformPress?() ?? false)
        try await settle(hosting)
        XCTAssertFalse(draft.backgroundRecognition)
        XCTAssertTrue(model.backgroundRecognition)
        XCTAssertNil(defaults.object(forKey: "backgroundRecognition"))
        XCTAssertFalse(descendants(hosting).contains {
            $0.accessibilityIdentifier?() == "settings.backgroundRecognition.modelsRequired"
        })
        draft.backgroundRecognition = true
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
        let draft = SettingsDraft(model: model)
        let (hosting, window) = host(ModelSettings(model: model, draft: draft), width: 760, height: 1400)
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
        XCTAssertGreaterThan(frame.width, 0)
        XCTAssertLessThanOrEqual(frame.maxY, background.minY)
        XCTAssertTrue(checkbox.accessibilityPerformPress?() ?? false)
        try await settle(hosting)
        XCTAssertFalse(draft.automaticSummaries)
        XCTAssertTrue(model.automaticSummaries)
        XCTAssertTrue(model.backgroundRecognition)
        XCTAssertNil(defaults.object(forKey: "automaticSummaries"))
        try model.applySettings(draft)
        XCTAssertFalse(model.automaticSummaries)
        XCTAssertEqual(defaults.object(forKey: "automaticSummaries") as? Bool, false)
        model.settingsTab = .diagrams
        try await settle(hosting)
        XCTAssertNotNil(findElement("settings.diagramModels.status", in: hosting))
        XCTAssertNil(findElement("settings.automaticSummaries", in: hosting))
        XCTAssertNil(findElement("settings.hardware", in: hosting))

        model.settingsTab = .general
        try await settle(hosting)
        XCTAssertNotNil(findElement("settings.hardware", in: hosting))
        XCTAssertNotNil(findElement("settings.models.verify", in: hosting))
        XCTAssertNil(findElement("settings.diagramModels.status", in: hosting))
        XCTAssertNil(findElement("settings.backgroundRecognition", in: hosting))
        await model.shutdown()
    }

    func testSettingsWindowKeepsTitleAndSizeAcrossTabsAndReopening() async throws {
        let suite = "LocalScribeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(repository: try RecordingRepository(root: root), startServices: false, userDefaults: defaults)
        _ = NSApplication.shared
        let settings = model.settingsWindow
        defer { settings.window?.close() }
        settings.show(tab: .general)
        let window = try XCTUnwrap(settings.window)
        let view = try XCTUnwrap(window.contentView)
        try await settle(view)
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertTrue(try XCTUnwrap(window.screen).visibleFrame.contains(window.frame))
        XCTAssertEqual(window.title, "Настройки")
        let size = NSSize(width: 620, height: 420)
        window.setContentSize(size)
        settings.show(tab: .diagrams)
        try await settle(view)
        XCTAssertTrue(settings.window === window)
        XCTAssertEqual(window.title, "Настройки")
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size, size)
        XCTAssertNotNil(findElement("settings.ok", in: view))
        XCTAssertNotNil(findElement("settings.cancel", in: view))

        window.performClose(nil)
        XCTAssertNil(settings.window)
        settings.show()
        let reopened = try XCTUnwrap(settings.window)
        XCTAssertEqual(reopened.contentRect(forFrameRect: reopened.frame).size, size)
    }

    func testSettingsWindowCancelsDraftAndConfirmsClosingWithEdits() async throws {
        let suite = "LocalScribeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(repository: try RecordingRepository(root: root), startServices: false, userDefaults: defaults)
        _ = NSApplication.shared
        let settings = model.settingsWindow
        defer { settings.window?.close() }

        func openAndEdit() async throws -> (NSWindow, NSView) {
            settings.show(tab: .recordings)
            let window = try XCTUnwrap(settings.window)
            window.setContentSize(NSSize(width: 760, height: 1400))
            let view = try XCTUnwrap(window.contentView)
            try await settle(view)
            let checkbox = try element("settings.automaticSummaries", in: view)
            XCTAssertTrue(checkbox.accessibilityPerformPress?() ?? false)
            try await settle(view)
            return (window, view)
        }

        let (_, firstView) = try await openAndEdit()
        XCTAssertTrue(try element("settings.cancel", in: firstView).accessibilityPerformPress?() ?? false)
        try await settle(firstView)
        XCTAssertNil(settings.window)
        XCTAssertTrue(model.automaticSummaries)

        let (secondWindow, secondView) = try await openAndEdit()
        secondWindow.performClose(nil)
        let discardSheet = try XCTUnwrap(secondWindow.attachedSheet)
        secondWindow.endSheet(discardSheet, returnCode: .alertSecondButtonReturn)
        try await settle(secondView)
        XCTAssertNil(settings.window)
        XCTAssertTrue(model.automaticSummaries)
        XCTAssertNil(defaults.object(forKey: "automaticSummaries"))

        let (thirdWindow, thirdView) = try await openAndEdit()
        thirdWindow.performClose(nil)
        let saveSheet = try XCTUnwrap(thirdWindow.attachedSheet)
        thirdWindow.endSheet(saveSheet, returnCode: .alertFirstButtonReturn)
        try await settle(thirdView)
        XCTAssertNil(settings.window)
        XCTAssertFalse(model.automaticSummaries)
        XCTAssertEqual(defaults.object(forKey: "automaticSummaries") as? Bool, false)

        let (_, fourthView) = try await openAndEdit()
        XCTAssertTrue(try element("settings.ok", in: fourthView).accessibilityPerformPress?() ?? false)
        try await settle(fourthView)
        XCTAssertNil(settings.window)
        XCTAssertTrue(model.automaticSummaries)
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

    func testWarningsSectionAppearsOnlyWithWarningsAndCanBeSelected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "LocalScribeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repo = try RecordingRepository(root: root)
        let manifest = Manifest(sourceType: "import", title: "Встреча", filename: "meeting.wav")
        let other = Manifest(sourceType: "import", title: "Без предупреждений", filename: "other.wav")
        try repo.save(manifest); try repo.save(other)
        let model = AppModel(repository: repo, startServices: false, userDefaults: defaults)
        await model.reload()
        model.selection = manifest.id
        model.automaticSummaries = false
        let (hosting, window) = host(ContentView(model: model), width: 1400)
        defer { window.close() }
        try await settle(hosting)
        XCTAssertFalse(descendants(try element("result.section", in: hosting)).contains { text($0) == "Предупреждения" })

        let warning = "В интервале 00:02:09–00:02:11 есть звук, но начало речи не распознано."
        try await model.archive?.update(manifest.id) { $0.warnings = [warning] }
        await model.reload()
        for width: CGFloat in [1100, 1400] {
            window.setContentSize(NSSize(width: width, height: 700))
            try await settle(hosting)
            let picker = try element("result.section", in: hosting)
            let buttons = try ["Расшифровка", "Итоги", "Предупреждения"].map { title in
                try XCTUnwrap(descendants(picker).first { text($0) == title }, title)
            }
            let frames = try buttons.map { try XCTUnwrap($0.accessibilityFrame?()) }
            for frame in frames { XCTAssertGreaterThan(frame.width, 0) }
            for (left, right) in zip(frames, frames.dropFirst()) {
                XCTAssertLessThanOrEqual(left.maxX, right.minX)
                XCTAssertEqual(left.midY, right.midY, accuracy: 2)
            }
            let editFrame = try XCTUnwrap(element("result.edit", in: hosting).accessibilityFrame?())
            XCTAssertLessThanOrEqual(frames[2].maxX, editFrame.minX)
            // SwiftUI's segmented item performs the action even when AX returns false.
            _ = buttons[2].accessibilityPerformPress?()
            await model.resultPresentation.task?.value
            try await settle(hosting)
            XCTAssertEqual(model.tab, .warnings)
            let textView = try XCTUnwrap(subviews(hosting).compactMap { $0 as? NSTextView }.first)
            XCTAssertTrue(textView.string.contains("Предупреждение: \(warning)"))
            XCTAssertNil(findElement("result.automaticSummariesDisabled", in: hosting))
            model.tab = .transcript
        }
        model.tab = .warnings
        model.selection = other.id
        try await settle(hosting)
        XCTAssertEqual(model.tab, .transcript)
        XCTAssertFalse(descendants(try element("result.section", in: hosting)).contains { text($0) == "Предупреждения" })
        model.selection = manifest.id; model.tab = .warnings
        try await settle(hosting)
        try await model.archive?.update(manifest.id) { $0.warnings = [] }
        await model.reload()
        try await settle(hosting)
        XCTAssertEqual(model.tab, .transcript)
        XCTAssertFalse(descendants(try element("result.section", in: hosting)).contains { text($0) == "Предупреждения" })
        await model.shutdown()
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

/// The mode switcher swaps the sidebar and detail area while both archives keep
/// their independent selection and search state.
@MainActor
final class DiagramModeSwitchLayoutTests: XCTestCase {
    private func descendants(_ element: AnyObject) -> [AnyObject] {
        let children = (element.accessibilityChildren?() ?? []).map { $0 as AnyObject }
        return children + children.flatMap { descendants($0) }
    }
    private func subviews(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap { subviews($0) } }
    private func findElement(_ id: String, in view: NSView) -> AnyObject? {
        if let element = descendants(view).first(where: { $0.accessibilityIdentifier?() == id }) { return element }
        for subview in subviews(view) {
            if let element = descendants(subview).first(where: { $0.accessibilityIdentifier?() == id }) { return element }
        }
        return nil
    }
    private func host<V: View>(_ view: V, width: CGFloat) -> (NSHostingView<V>, NSWindow) {
        _ = NSApplication.shared
        NSApplication.shared.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 560),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        return (hosting, window)
    }
    private func settle(_ view: NSView) async throws {
        try await Task.sleep(for: .milliseconds(120))
        view.layoutSubtreeIfNeeded()
    }

    @MainActor
    func testEachModeShowsItsOwnSidebarAndDetailWithIndependentState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "LocalScribeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repo = try RecordingRepository(root: root)
        var recording = Manifest(sourceType: "import", title: "Запись режима", filename: "meeting.wav")
        recording.sourceComplete = true
        try repo.save(recording)
        let model = AppModel(repository: repo, startServices: false, userDefaults: defaults)
        await model.reload()
        model.selection = recording.id

        // A diagram item exists in the sibling archive.
        let diagramRepository = try XCTUnwrap(model.diagramRepository)
        let diagramArchive = try XCTUnwrap(model.diagramArchive)
        var diagram = DiagramManifest(title: "Архитектура", filename: "arch.png", ext: "png", uti: "public.png")
        let folder = diagramRepository.folder(diagram.id)
        try Disk.directory(folder)
        let png = NSMutableData()
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        try (png as Data).write(to: folder.appendingPathComponent("original.png"))
        diagram.pixelWidth = 4; diagram.pixelHeight = 4
        diagram.byteSize = Int64(png.length)
        diagram.sha256 = try Disk.hash(folder.appendingPathComponent("original.png"))
        try await diagramArchive.save(diagram)
        await model.reloadDiagrams()

        let (hosting, window) = host(ContentView(model: model), width: 850)
        defer { window.close() }
        try await settle(hosting)

        func frame(_ id: String) throws -> NSRect {
            try XCTUnwrap(findElement(id, in: hosting)?.accessibilityFrame?(), id)
        }
        func segment(_ title: String) throws -> AnyObject {
            let picker = try XCTUnwrap(findElement("workspace.mode", in: hosting))
            return try XCTUnwrap(descendants(picker).first { element in
                (element as? NSObject).flatMap(labelText) == title
            }, title)
        }

        let switchFrame = try frame("workspace.mode")
        let titles = ["Записи", "Схемы"]
        let segmentFrames = try titles.map { try XCTUnwrap(segment($0).accessibilityFrame?()) }
        let groupButtons = ["expandAll", "collapseAll", "add"]
        let groupFrames = try groupButtons.map { try frame("groups.\($0)") }
        let recordingActions = try ["recordings.sidebar.new", "recordings.sidebar.import"].map(frame)
        let headerFrames = [switchFrame] + groupFrames + recordingActions
        for (left, right) in zip(headerFrames, headerFrames.dropFirst()) {
            XCTAssertLessThanOrEqual(left.maxX, right.minX)
        }
        for buttonFrame in groupFrames + recordingActions {
            XCTAssertEqual(switchFrame.midY, buttonFrame.midY, accuracy: 1)
            XCTAssertEqual(buttonFrame.width, 20, accuracy: 1)
            XCTAssertEqual(buttonFrame.height, 24, accuracy: 1)
        }
        XCTAssertNotNil(findElement("sidebar.recording.\(recording.id)", in: hosting))
        XCTAssertNil(findElement("diagrams.import", in: hosting))

        _ = try segment("Схемы").accessibilityPerformPress?()
        try await settle(hosting)
        XCTAssertNotNil(findElement("diagrams.search", in: hosting))
        XCTAssertNotNil(findElement("diagrams.sidebar.diagram.\(diagram.id)", in: hosting))
        XCTAssertNil(findElement("groups.add", in: hosting))
        XCTAssertNil(findElement("recordings.sidebar.new", in: hosting))
        XCTAssertNil(findElement("recordings.sidebar.import", in: hosting))
        XCTAssertEqual(try frame("workspace.mode"), switchFrame)
        XCTAssertEqual(try titles.map { try XCTUnwrap(segment($0).accessibilityFrame?()) }, segmentFrames)
        XCTAssertEqual(try groupButtons.map { try frame("diagrams.groups.\($0)") }, groupFrames)
        let importFrame = try frame("diagrams.import")
        XCTAssertEqual(importFrame, recordingActions[0])
        XCTAssertEqual(model.selection, recording.id)

        _ = try segment("Записи").accessibilityPerformPress?()
        try await settle(hosting)
        XCTAssertNotNil(findElement("sidebar.recording.\(recording.id)", in: hosting))
        XCTAssertNil(findElement("diagrams.import", in: hosting))
        XCTAssertEqual(try frame("workspace.mode"), switchFrame)
        await model.shutdown()
    }
    private func labelText(_ object: NSObject) -> String? {
        for name in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector) else { continue }
            let value = object.perform(selector)?.takeUnretainedValue()
            if let string = value as? String { return string }
            if let attributed = value as? NSAttributedString { return attributed.string }
        }
        return nil
    }
}
