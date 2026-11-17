import AppKit
import CoreAudio
import CoreMedia
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

    private func host<V: View>(_ view: V, width: CGFloat, height: CGFloat = 700,
                               styleMask: NSWindow.StyleMask = [.titled]) -> (NSHostingView<V>, NSWindow) {
        _ = NSApplication.shared
        NSApplication.shared.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: styleMask, backing: .buffered, defer: false)
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

    func testPlayerSkipPausesCheckboxPrecedesFollowAndFitsNarrowLayout() async throws {
        let playback = RecordingPlayback()
        for width in [1100.0, 650.0] {
            let (hosting, window) = host(RecordingPlayerView(playback: playback, sourceAvailable: true),
                                         width: width, height: 180)
            defer { window.close() }
            try await settle(hosting)
            let transport = try ["playback.previousSegment", "playback.back", "playback.toggle",
                                 "playback.forward", "playback.nextSegment"].map {
                try XCTUnwrap(element($0, in: hosting).accessibilityFrame?())
            }
            for pair in zip(transport, transport.dropFirst()) {
                XCTAssertLessThanOrEqual(pair.0.maxX, pair.1.minX)
            }
            let checkbox = try element("playback.skipPauses", in: hosting)
            let follow = try element("playback.follow", in: hosting)
            let checkboxFrame = try XCTUnwrap(checkbox.accessibilityFrame?())
            let followFrame = try XCTUnwrap(follow.accessibilityFrame?())
            XCTAssertGreaterThan(checkboxFrame.width, 0)
            XCTAssertGreaterThan(followFrame.width, 0)
            XCTAssertFalse(checkboxFrame.intersects(followFrame))
            XCTAssertLessThanOrEqual(checkboxFrame.maxX, followFrame.minX)
            XCTAssertFalse(playback.skipsPauses)
            XCTAssertTrue(checkbox.accessibilityPerformPress?() ?? false)
            try await settle(hosting)
            XCTAssertTrue(playback.skipsPauses)
            XCTAssertTrue(playback.followsTranscript)
            playback.skipsPauses = false
        }
    }

    func testLiveCaptionsFollowOnlyAtTheBottom() async throws {
        var text = LiveCaptionText()
        let (hosting, window) = host(LiveCaptionTextView(text: text), width: 520, height: 300)
        defer { window.close() }
        try await settle(hosting)
        let scroll = try XCTUnwrap(subviews(hosting).compactMap { $0 as? NSScrollView }.first)
        let clip = scroll.contentView

        func append(_ index: Int) {
            let range = CMTimeRange(start: CMTime(value: Int64(index), timescale: 1), duration: CMTime(value: 1, timescale: 1))
            text.receive(LiveCaptionUpdate(range: range, finalizedThrough: range.end, text: "Реплика \(index)"))
        }
        func distanceFromBottom() -> CGFloat { clip.documentRect.maxY - clip.bounds.maxY }
        func scrollTo(_ y: CGFloat) {
            clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: NSPoint(x: 0, y: y), size: clip.bounds.size)).origin)
            scroll.reflectScrolledClipView(clip)
        }

        for index in 0..<60 { append(index) }
        hosting.rootView = LiveCaptionTextView(text: text)
        try await settle(hosting)
        XCTAssertLessThanOrEqual(distanceFromBottom(), 2)

        scrollTo(100)
        let readerPosition = clip.bounds.origin.y
        append(60)
        hosting.rootView = LiveCaptionTextView(text: text)
        try await settle(hosting)
        XCTAssertEqual(clip.bounds.origin.y, readerPosition, accuracy: 1)

        scrollTo(clip.documentRect.maxY - clip.bounds.height)
        append(61)
        hosting.rootView = LiveCaptionTextView(text: text)
        try await settle(hosting)
        XCTAssertLessThanOrEqual(distanceFromBottom(), 2)
    }

    private func assertActionAlignment(_ primaryID: String, in view: NSView) throws {
        let statusIDs = primaryID == "recording.moveToFront" ? [primaryID, "recording.cancel"] : [primaryID]
        let actionIDs = ["recording.showAudio", "result.edit", "recording.repeatAnalysis",
                         "recording.recreateSummary", "recording.delete"]
        let rows = try [statusIDs, actionIDs].map { identifiers in
            try identifiers.map { try XCTUnwrap(element($0, in: view).accessibilityFrame?()) }
        }
        for frames in rows {
            for frame in frames {
                XCTAssertGreaterThan(frame.width, 0)
                XCTAssertEqual(frame.midY, frames[0].midY, accuracy: 2)
            }
            for (left, right) in zip(frames, frames.dropFirst()) {
                XCTAssertLessThanOrEqual(left.maxX, right.minX)
            }
        }
        XCTAssertGreaterThan(rows[0][0].minY, rows[1][0].maxY)
        XCTAssertEqual(rows[0][0].height, rows[1][0].height, accuracy: 2)
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

    func testRecordingSourceSettingsKeepSelectedMicrophoneVisibleWhenDetached() async throws {
        let suite = "LocalScribeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let builtIn = MicrophoneInputDevice(deviceID: 1, uid: "built-in", name: "MacBook", isBuiltIn: true)
        let usb = MicrophoneInputDevice(deviceID: 2, uid: "usb", name: "USB Mic", isBuiltIn: false)
        var inventory = MicrophoneDevicesSnapshot(devices: [builtIn, usb], defaultDeviceID: 2)
        let builtInRoute = HALInputRoute(uid: builtIn.uid, nominalRate: 48_000, channels: 1, streams: [], controls: [])
        let usbRoute = HALInputRoute(uid: usb.uid, nominalRate: 48_000, channels: 1, streams: [], controls: [])
        var routes = [builtIn.deviceID: builtInRoute, usb.deviceID: usbRoute]
        let devices = MicrophoneDevices(observeChanges: false, loadSnapshot: { inventory }, loadRoute: { routes[$0] })
        let model = AppModel(repository: try RecordingRepository(root: root), startServices: false,
                             userDefaults: defaults, microphoneDevices: devices)
        let draft = SettingsDraft(model: model)
        draft.recordingSources.microphone = usb.selection
        let (hosting, window) = host(ModelSettings(model: model, draft: draft), width: 760, height: 1300)
        defer { window.close() }

        try await settle(hosting)
        XCTAssertNil(findElement("settings.recordingMicrophone.unavailable", in: hosting))
        XCTAssertNil(findElement("settings.recordingMicrophone.fallback", in: hosting))
        XCTAssertEqual(devices.snapshot.device(for: .builtIn), builtIn)
        XCTAssertEqual(devices.snapshot.device(for: .systemDefault), usb)
        let pinned = try devices.resolve(.systemDefault)
        XCTAssertEqual(pinned.uid, usb.uid)

        inventory.defaultDeviceID = 1
        devices.refresh()
        XCTAssertEqual(try devices.resolve(.systemDefault).uid, builtIn.uid)
        XCTAssertNoThrow(try devices.validate(pinned))

        inventory.devices = [builtIn]
        routes.removeValue(forKey: usb.deviceID)
        devices.refresh()
        try await settle(hosting)
        XCTAssertNotNil(findElement("settings.recordingMicrophone.unavailable", in: hosting))
        XCTAssertEqual(text(try element("settings.recordingMicrophone.fallback", in: hosting)),
                       L10n.text("Резервный микрофон: %1$@", L10n.text("Встроенный микрофон")))
        XCTAssertEqual(draft.recordingSources.microphone, usb.selection)
        XCTAssertEqual(devices.snapshot.device(for: .systemDefault), builtIn)
        XCTAssertNil(devices.snapshot.device(for: usb.selection))
        XCTAssertThrowsError(try devices.resolve(usb.selection))
        XCTAssertThrowsError(try devices.validate(pinned))

        let reattached = MicrophoneInputDevice(deviceID: 3, uid: usb.uid, name: usb.name, isBuiltIn: false)
        inventory.devices.append(reattached)
        routes[reattached.deviceID] = usbRoute
        devices.refresh()
        try await settle(hosting)
        XCTAssertNil(findElement("settings.recordingMicrophone.unavailable", in: hosting))
        XCTAssertNil(findElement("settings.recordingMicrophone.fallback", in: hosting))
        XCTAssertEqual(devices.snapshot.device(for: usb.selection), reattached)
        let replacement = try devices.resolve(usb.selection)
        XCTAssertEqual(replacement.deviceID, reattached.deviceID)
        XCTAssertThrowsError(try devices.validate(pinned))
        routes[replacement.deviceID] = HALInputRoute(uid: usb.uid, nominalRate: 44_100, channels: 1, streams: [], controls: [])
        XCTAssertThrowsError(try devices.validate(replacement))
        let negotiated = try devices.refreshFormat(of: replacement)
        XCTAssertEqual(negotiated.uid, replacement.uid)
        XCTAssertNoThrow(try devices.validate(negotiated))
        let jack = HALInput.inputProperty(replacement.deviceID, kAudioDevicePropertyJackIsConnected)
        routes[replacement.deviceID] = HALInputRoute(uid: usb.uid, nominalRate: 44_100, channels: 1, streams: [],
                                                    controls: [HALInput.Control(property: jack, values: [0])])
        XCTAssertThrowsError(try devices.refreshFormat(of: negotiated))
        await model.shutdown()
    }

    func testRecordingSourceDraftCommitsModesAndRestoresDeviceName() async throws {
        let suite = "LocalScribeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(root: root)
        let model = AppModel(repository: repository, startServices: false, userDefaults: defaults)
        let draft = SettingsDraft(model: model)
        XCTAssertEqual(draft.recordingSources, RecordingSourcePreferences())
        draft.recordingSources.microphoneEnabled = false
        draft.recordingSources.microphone = .device(uid: "usb", name: "USB Mic")
        XCTAssertTrue(draft.hasChanges(from: model))
        XCTAssertEqual(SettingsDraft(model: model).recordingSources, RecordingSourcePreferences())
        XCTAssertEqual(RecordingSourcePreferences(defaults: defaults), RecordingSourcePreferences())

        var globalSources = model.recordingSources
        globalSources.systemAudioEnabled = true
        model.setRecordingSources(globalSources)
        XCTAssertEqual(RecordingSourcePreferences(defaults: defaults), globalSources)
        XCTAssertTrue(draft.recordingSources.systemAudioEnabled)
        XCTAssertFalse(draft.recordingSources.microphoneEnabled)
        XCTAssertEqual(draft.recordingSources.microphone, .device(uid: "usb", name: "USB Mic"))

        draft.recordingSources.systemAudioEnabled = false
        try model.applySettings(draft)
        XCTAssertFalse(model.recordingSources.hasEnabledSource)
        XCTAssertEqual(RecordingSourcePreferences(defaults: defaults), draft.recordingSources)
        draft.recordingSources.systemAudioEnabled = true
        try model.applySettings(draft)
        XCTAssertFalse(draft.hasChanges(from: model))
        XCTAssertEqual(RecordingSourcePreferences(defaults: defaults), draft.recordingSources)
        draft.recordingSources.microphoneEnabled = true
        XCTAssertFalse(model.recordingSources.microphoneEnabled)
        try model.applySettings(draft)
        let reopened = AppModel(repository: repository, startServices: false, userDefaults: defaults)
        XCTAssertEqual(SettingsDraft(model: reopened).recordingSources, draft.recordingSources)
        await model.shutdown()
        await reopened.shutdown()
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
        XCTAssertNotNil(findElement("settings.applicationLanguage", in: hosting))
        XCTAssertNotNil(findElement("settings.applicationTheme", in: hosting))
        XCTAssertNil(findElement("settings.diagramModels.status", in: hosting))
        XCTAssertNil(findElement("settings.backgroundRecognition", in: hosting))
        await model.shutdown()
    }

    func testApplicationLanguagePersistsOnlyWhenSettingsAreApplied() async throws {
        let suite = "LocalScribeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root)
        let model = AppModel(repository: repo, startServices: false, userDefaults: defaults)

        let draft = SettingsDraft(model: model)
        XCTAssertEqual(draft.applicationLanguage, .system)
        draft.applicationLanguage = .english
        XCTAssertTrue(draft.hasChanges(from: model))
        XCTAssertNil(defaults.object(forKey: ApplicationLanguage.defaultsKey))
        XCTAssertEqual(SettingsDraft(model: model).applicationLanguage, .system)

        try model.applySettings(draft)
        XCTAssertFalse(draft.hasChanges(from: model))
        let reopenedDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let reopened = AppModel(repository: repo, startServices: false, userDefaults: reopenedDefaults)
        let reopenedDraft = SettingsDraft(model: reopened)
        XCTAssertEqual(reopenedDraft.applicationLanguage, .english)
        reopenedDraft.applicationLanguage = .system
        try reopened.applySettings(reopenedDraft)
        XCTAssertEqual(ApplicationLanguage.selection(in: defaults), .system)
        await model.shutdown()
        await reopened.shutdown()
    }

    func testApplicationThemePersistsOnlyWhenSettingsAreApplied() async throws {
        _ = NSApplication.shared
        let suite = "LocalScribeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            NSApp.appearance = nil
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root)
        let model = AppModel(repository: repo, startServices: false, userDefaults: defaults)

        let draft = SettingsDraft(model: model)
        XCTAssertEqual(draft.applicationTheme, .system)
        draft.applicationTheme = .dark
        XCTAssertTrue(draft.hasChanges(from: model))
        XCTAssertNil(defaults.object(forKey: ApplicationTheme.defaultsKey))
        XCTAssertEqual(NSApp.appearance, nil)
        XCTAssertEqual(SettingsDraft(model: model).applicationTheme, .system)

        try model.applySettings(draft)
        XCTAssertFalse(draft.hasChanges(from: model))
        XCTAssertEqual(NSApp.appearance, NSAppearance(named: .darkAqua))
        let reopenedDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let reopened = AppModel(repository: repo, startServices: false, userDefaults: reopenedDefaults)
        let reopenedDraft = SettingsDraft(model: reopened)
        XCTAssertEqual(reopenedDraft.applicationTheme, .dark)
        reopenedDraft.applicationTheme = .system
        try reopened.applySettings(reopenedDraft)
        XCTAssertEqual(ApplicationTheme.selection(in: defaults), .system)
        XCTAssertEqual(NSApp.appearance, nil)
        await model.shutdown()
        await reopened.shutdown()
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
        for part in [RecordingResultTab.transcript, .summary] {
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

    func testSettingsGearFollowsSidebarVisibility() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(repository: try RecordingRepository(root: root), startServices: false)
        let (hosting, window) = host(ContentView(model: model), width: 850,
                                     styleMask: [.titled, .closable, .miniaturizable, .resizable])
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        try await settle(hosting)

        let toolbar = try XCTUnwrap(window.toolbar)
        let settings = NSToolbarItem.Identifier("workspace.settings")
        let expanded: [NSToolbarItem.Identifier] =
            [.flexibleSpace, settings, .toggleSidebar, .sidebarTrackingSeparator]

        func waitForToolbar(_ items: [NSToolbarItem.Identifier]) async throws {
            for _ in 0..<20 {
                try await settle(hosting)
                if toolbar.itemIdentifiers == items { return }
            }
            XCTFail("Unexpected toolbar items: \(toolbar.itemIdentifiers)")
        }

        func click(_ location: NSPoint) throws {
            let events = try [NSEvent.EventType.leftMouseDown, .leftMouseUp].map { type in
                try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                                timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil,
                                                eventNumber: 0, clickCount: 1, pressure: 1))
            }
            NSApp.postEvent(events[1], atStart: false)
            NSApp.sendEvent(events[0])
            while let event = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }

        XCTAssertEqual(toolbar.itemIdentifiers, expanded)
        XCTAssertTrue(toolbar.visibleItems?.contains { $0.itemIdentifier == settings } == true)
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titlebarSeparatorStyle, .none)
        for edge in [NSRectEdge.minX, .maxX, .minY, .maxY] {
            let toggle = try XCTUnwrap(toolbar.items.first { $0.itemIdentifier == .toggleSidebar })
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(toggle.action), to: toggle.target, from: toggle))
            try await waitForToolbar([])

            let reveal = try XCTUnwrap(window.titlebarAccessoryViewControllers
                .flatMap { subviews($0.view) }
                .first { $0.accessibilityIdentifier() == "workspace.revealSidebar" })
            let bounds = reveal.convert(reveal.bounds.insetBy(dx: 2, dy: 2), to: nil)
            let point: NSPoint
            switch edge {
            case .minX: point = NSPoint(x: bounds.minX, y: bounds.midY)
            case .maxX: point = NSPoint(x: bounds.maxX, y: bounds.midY)
            case .minY: point = NSPoint(x: bounds.midX, y: bounds.minY)
            case .maxY: point = NSPoint(x: bounds.midX, y: bounds.maxY)
            @unknown default: continue
            }
            let titlebarHit = window.contentView?.superview?.hitTest(point)
            XCTAssertTrue(titlebarHit?.isDescendant(of: reveal) == true, "Edge \(edge)")
            try click(point)
            try await waitForToolbar(expanded)
            XCTAssertFalse(window.titlebarAccessoryViewControllers.contains { reveal.isDescendant(of: $0.view) })
        }
        XCTAssertTrue(toolbar.visibleItems?.contains { $0.itemIdentifier == settings } == true)
        let gear = try XCTUnwrap(toolbar.items.first { $0.itemIdentifier == settings })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(gear.action), to: gear.target, from: gear))
        XCTAssertNotNil(model.settingsWindow.window)
        model.settingsWindow.window?.close()
        await model.shutdown()
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
                for part in [RecordingResultTab.transcript, .summary] {
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

    func testRecordingHeaderKeepsControlPositionsWhenSwitchingRecordings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "LocalScribeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repo = try RecordingRepository(root: root)
        var short = Manifest(sourceType: "import", title: "Встреча", filename: "short.wav")
        short.state = .completed
        try repo.save(short)
        var long = Manifest(sourceType: "import",
                            title: String(repeating: "Длинное название записи встречи ", count: 12),
                            filename: "long.wav")
        long.state = .failed
        long.sourceComplete = true
        long.warnings = ["Есть предупреждение об обработке"]
        long.lastError = "Обработка прервана"
        try repo.save(long)
        let model = AppModel(repository: repo, startServices: false, userDefaults: defaults)
        await model.reload()

        let originalLanguage = ApplicationLanguage(rawValue: L10n.locale.identifier) ?? .russian
        defer { L10n.configure(originalLanguage) }
        let controls = ["recording.showAudio", "recording.repeatAnalysis", "recording.recreateSummary",
                        "recording.delete", "result.label", "result.edit", "result.copy", "result.export"]

        for language in [ApplicationLanguage.russian, .english] {
            L10n.configure(language)
            model.selection = long.id
            let (hosting, window) = host(ContentView(model: model), width: 1100)
            defer { window.close() }
            let tabTitles = [ExportPart.transcript.title, ExportPart.summary.title]
            let warningsTitle = ExportPart.warnings.title

            func frames(hasWarnings: Bool) throws -> [String: NSRect] {
                let picker = try element("result.section", in: hosting)
                let tabs = descendants(picker)
                let titles = tabTitles + (hasWarnings ? [warningsTitle] : [])
                XCTAssertEqual(tabs.compactMap(text).filter { (tabTitles + [warningsTitle]).contains($0) }, titles)
                let controlsByID = try controls.map { (name: $0, element: try element($0, in: hosting)) }
                let tabsByTitle = try titles.map { title in
                    (name: title, element: try XCTUnwrap(tabs.first { text($0) == title }, title))
                }
                let frames = try Dictionary(uniqueKeysWithValues: (controlsByID + tabsByTitle).map { entry in
                    (entry.name, try XCTUnwrap(entry.element.accessibilityFrame?(), entry.name))
                })
                let label = try XCTUnwrap(frames["result.label"])
                let finder = try XCTUnwrap(frames["recording.showAudio"])
                let edit = try XCTUnwrap(frames["result.edit"])
                let copy = try XCTUnwrap(frames["result.copy"])
                let export = try XCTUnwrap(frames["result.export"])
                let pickerFrame = try XCTUnwrap(picker.accessibilityFrame?())
                let firstTab = try XCTUnwrap(frames[tabTitles[0]])
                let lastTab = try XCTUnwrap(frames[titles[titles.count - 1]])
                for leadingEdge in [pickerFrame.minX, firstTab.minX] {
                    XCTAssertGreaterThanOrEqual(leadingEdge - label.maxX, 6, "\(language.rawValue), \(hosting.bounds.width)")
                }
                XCTAssertLessThanOrEqual(lastTab.maxX, copy.minX)
                XCTAssertLessThanOrEqual(copy.maxX, export.minX)
                XCTAssertEqual(copy.midY, export.midY, accuracy: 1)
                XCTAssertEqual(edit.midY, finder.midY, accuracy: 2)
                XCTAssertLessThanOrEqual(finder.maxX, edit.minX)
                XCTAssertGreaterThan(edit.minY, copy.maxY)
                XCTAssertEqual(copy.width, export.width, accuracy: 1)
                XCTAssertLessThan(copy.width, 30)
                XCTAssertEqual(try element("result.copy", in: hosting).accessibilityHelp?(), L10n.text("Копировать результат"))
                XCTAssertEqual(try element("result.export", in: hosting).accessibilityHelp?(), L10n.text("Экспорт"))
                return frames
            }

            for width: CGFloat in [1100, 850, 1400] {
                window.setContentSize(NSSize(width: width, height: 700))
                try await settle(hosting)
                let before = try frames(hasWarnings: true)
                model.selection = short.id
                try await settle(hosting)
                let withoutWarnings = try frames(hasWarnings: false)
                model.selection = long.id
                try await settle(hosting)
                let after = try frames(hasWarnings: true)
                XCTAssertEqual(hosting.bounds.width, width, accuracy: 1)
                for (name, first) in before {
                    let context = "\(name), \(language.rawValue), width \(width)"
                    let restored = try XCTUnwrap(after[name], context)
                    let snapshots = name == warningsTitle ? [restored] : [try XCTUnwrap(withoutWarnings[name], context), restored]
                    for frame in snapshots {
                        XCTAssertEqual(first.minX, frame.minX, accuracy: 1, context)
                        XCTAssertEqual(first.midY, frame.midY, accuracy: 1, context)
                        XCTAssertEqual(first.width, frame.width, accuracy: 1, context)
                    }
                }
            }
        }
        await model.shutdown()
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
        try await model.archive?.update(manifest.id) {
            $0.state = .completedWithWarnings
            $0.warnings = [warning]
        }
        await model.reload()
        for width: CGFloat in [1100, 1400] {
            window.setContentSize(NSSize(width: width, height: 700))
            try await settle(hosting)
            XCTAssertEqual(text(try element("recording.status.\(manifest.id)", in: hosting)), "Готово")
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
            let copyFrame = try XCTUnwrap(element("result.copy", in: hosting).accessibilityFrame?())
            XCTAssertLessThanOrEqual(frames[2].maxX, copyFrame.minX)
            // The segmented control may perform the action even when AX returns false.
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
        try await model.archive?.update(manifest.id) {
            $0.state = .completed
            $0.warnings = []
        }
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

/// The mode switcher swaps the sidebar and detail area while the archives keep
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
        let run = DiagramRunInfo(sourceHash: diagram.sha256, modelID: "diagram", profileHash: "test")
        let runFolder = diagramRepository.run(diagram.id, run.id)
        try Disk.write(run, to: runFolder.appendingPathComponent("run.json"))
        let result = DiagramResult(fingerprint: run.fingerprint, nodes: [DiagramNode(id: "1", label: "Начало")], edges: [])
        try Disk.write(result, to: runFolder.appendingPathComponent("result.json"))
        diagram.activeRunId = run.id
        diagram.state = .completed
        try await diagramArchive.save(diagram)
        await model.reloadDiagrams()

        let textArchive = try XCTUnwrap(model.textArchive)
        let source = TextRevision(id: UUID().uuidString, text: "Отчёт")
        let generated = TextRevision(id: UUID().uuidString, text: source.text)
        let card = try await textArchive.importCard(.init(bytes: Data(source.text.utf8), importedNameStem: "Отчёт",
                                                         sourceFormat: .txt, source: source))
        try await textArchive.updateCard(card.id) { card in
            let input = RunInput(source: source, profileID: "anon", packageID: "test", dataTypes: ["ФИО"])
            card.latestAttempt = AnonymizationAttempt(
                state: .failed, expectedResultRevisionID: generated.id, input: input,
                failure: .processing("Обработка прервана.\nСохранён предыдущий результат.\nПопробуйте ещё раз."))
            card.publishedResult = AnonymizationResult(input: input, generatedText: generated, text: generated,
                                                       downloadNameStem: "Отчёт", bodyReplacementCount: 0, pairs: [])
        }
        await model.reloadTexts()

        let (hosting, window) = host(ContentView(model: model), width: 850)
        defer { window.close() }
        try await settle(hosting)

        func frame(_ id: String) throws -> NSRect {
            try XCTUnwrap(findElement(id, in: hosting)?.accessibilityFrame?(), id)
        }
        func assertResultPositions(_ ids: [String], match expected: [NSRect]) throws {
            for (id, reference) in zip(ids, expected) {
                let actual = try frame(id)
                XCTAssertEqual(actual.midX, reference.midX, accuracy: 1, id)
                XCTAssertEqual(actual.midY, reference.midY, accuracy: 1, id)
            }
        }
        func segment(_ title: String) throws -> AnyObject {
            let picker = try XCTUnwrap(findElement("workspace.mode", in: hosting))
            return try XCTUnwrap(descendants(picker).first { element in
                (element as? NSObject).flatMap(labelText) == title
            }, title)
        }

        let switchFrame = try frame("workspace.mode")
        let searchFrame = try frame("recordings.search")
        let titles = ["Записи", "Схемы", "Обезличивание"]
        let segmentFrames = try titles.map { try XCTUnwrap(segment($0).accessibilityFrame?(), $0) }
        let groupButtons = ["collapseAll", "expandAll", "add"]
        let groupFrames = try groupButtons.map { try frame("groups.\($0)") }
        let recordingActions = try ["recordings.sidebar.new", "recordings.sidebar.import"].map(frame)
        for (left, right) in zip(segmentFrames, segmentFrames.dropFirst()) {
            XCTAssertLessThanOrEqual(left.maxX, right.minX + 1)
            XCTAssertEqual(left.midY, right.midY, accuracy: 1)
        }
        let actionFrames = groupFrames + recordingActions
        for (left, right) in zip(actionFrames, actionFrames.dropFirst()) {
            XCTAssertLessThanOrEqual(left.maxX, right.minX)
        }
        for buttonFrame in actionFrames {
            XCTAssertLessThanOrEqual(buttonFrame.maxY, searchFrame.minY)
            XCTAssertEqual(actionFrames[0].midY, buttonFrame.midY, accuracy: 1)
            XCTAssertEqual(buttonFrame.width, 20, accuracy: 1)
            XCTAssertEqual(buttonFrame.height, 24, accuracy: 1)
        }
        XCTAssertLessThan(searchFrame.maxY, switchFrame.minY)
        XCTAssertEqual(groupFrames[0].minX, searchFrame.minX, accuracy: 1)
        XCTAssertGreaterThan(recordingActions[0].minX - groupFrames[2].maxX, 4)
        XCTAssertEqual(recordingActions[1].maxX, searchFrame.maxX, accuracy: 1)
        XCTAssertNotNil(findElement("sidebar.recording.\(recording.id)", in: hosting))
        XCTAssertNil(findElement("diagrams.import", in: hosting))
        let resultIDs = ["result.copy", "result.export"]
        let resultFrames = try resultIDs.map(frame)
        let actionFrame = try frame("recording.showAudio")
        XCTAssertGreaterThan(actionFrame.minY, resultFrames[0].maxY)
        // Accessibility frames reflect the native controls' insets within each row.
        XCTAssertLessThanOrEqual(actionFrame.minY - resultFrames[0].maxY, 14)

        _ = try segment("Схемы").accessibilityPerformPress?()
        try await settle(hosting)
        XCTAssertEqual(try frame("diagrams.search"), searchFrame)
        XCTAssertNotNil(findElement("diagrams.sidebar.diagram.\(diagram.id)", in: hosting))
        XCTAssertNil(findElement("groups.add", in: hosting))
        XCTAssertNil(findElement("recordings.sidebar.new", in: hosting))
        XCTAssertNil(findElement("recordings.sidebar.import", in: hosting))
        XCTAssertEqual(try frame("workspace.mode"), switchFrame)
        XCTAssertEqual(try titles.map { try XCTUnwrap(segment($0).accessibilityFrame?()) }, segmentFrames)
        XCTAssertEqual(try groupButtons.map { try frame("diagrams.groups.\($0)") }, groupFrames)
        let importFrame = try frame("diagrams.import")
        XCTAssertEqual(importFrame, recordingActions[1])
        XCTAssertEqual(model.selection, recording.id)
        let diagramRow = try XCTUnwrap(findElement("diagrams.sidebar.diagram.\(diagram.id)", in: hosting))
        _ = diagramRow.accessibilityPerformPress?()
        try await settle(hosting)
        try assertResultPositions(["diagrams.copy", "diagrams.save"], match: resultFrames)

        _ = try segment("Обезличивание").accessibilityPerformPress?()
        try await settle(hosting)
        XCTAssertEqual(try frame("texts.search"), searchFrame)
        XCTAssertEqual(try frame("texts.import"), importFrame)
        XCTAssertEqual(try groupButtons.map { try frame("texts.groups.\($0)") }, groupFrames)
        let textRow = try XCTUnwrap(findElement("texts.sidebar.card.\(card.id)", in: hosting))
        _ = textRow.accessibilityPerformPress?()
        try await settle(hosting)
        try assertResultPositions(["texts.detail.copy", "texts.detail.download"], match: resultFrames)
        XCTAssertLessThan(try frame("texts.detail.failure").maxY, resultFrames[0].minY)

        let restorationSwitch = try XCTUnwrap(findElement("texts.detail.restorationTab", in: hosting))
        XCTAssertTrue(restorationSwitch.accessibilityPerformPress?() ?? false)
        try await settle(hosting)
        try assertResultPositions(["texts.detail.copy", "texts.detail.download"], match: resultFrames)
        let restorationActions = try ["texts.restoration.import", "texts.restoration.paste",
                                      "texts.detail.restorationTab", "texts.detail.restoration.retry",
                                      "texts.detail.delete"].map(frame)
        for action in restorationActions {
            XCTAssertEqual(action.midY, restorationActions[0].midY, accuracy: 2)
            XCTAssertGreaterThan(action.minY, resultFrames[0].maxY)
        }
        for (left, right) in zip(restorationActions, restorationActions.dropFirst()) {
            XCTAssertLessThanOrEqual(left.maxX, right.minX)
        }
        XCTAssertLessThanOrEqual(try XCTUnwrap(restorationActions.last).maxX, resultFrames[1].maxX + 1)

        _ = try segment("Записи").accessibilityPerformPress?()
        try await settle(hosting)
        XCTAssertNotNil(findElement("sidebar.recording.\(recording.id)", in: hosting))
        XCTAssertNil(findElement("diagrams.import", in: hosting))
        XCTAssertEqual(try frame("workspace.mode"), switchFrame)
        try assertResultPositions(resultIDs, match: resultFrames)
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
