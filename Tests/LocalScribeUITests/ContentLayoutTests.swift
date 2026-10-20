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
