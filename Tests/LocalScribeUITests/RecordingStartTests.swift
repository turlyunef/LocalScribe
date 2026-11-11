import AVFoundation
import CoreAudio
import Foundation
import XCTest
@testable import LocalScribe
import LocalScribeCore

@MainActor final class RecordingStartTests: XCTestCase {
    private final class Capture: RecordingCapture {
        var onMeter: ((CaptureMeterReading) -> Void)?
        var onStopNeeded: ((String) -> Void)?
        var onWarning: ((String) -> Void)?
        var onResourcePressure: (() -> Void)?
        var onMicrophoneStatus: ((CaptureMicrophoneStatus) -> Void)?
        var startError: Error?
        var startup: (() async throws -> Void)?
        var microphone: PinnedMicrophone?
        var microphoneRequested = false
        var fallbackCalls = 0
        var systemAudio = false
        var startCalls = 0
        var stopCalls = 0

        func start(folder: URL, microphone: MicrophoneCaptureRequest?, systemAudio: Bool) async throws {
            startCalls += 1
            microphoneRequested = microphone != nil
            self.microphone = microphone?.initial
            self.systemAudio = systemAudio
            if let startError { throw startError }
            try await startup?()
            try Disk.directory(folder)
            let format = try XCTUnwrap(CapturePCM16Sink.format)
            let file = try AVAudioFile(forWriting: folder.appendingPathComponent("part-000000.caf"),
                                       settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: false)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600))
            buffer.frameLength = 1600
            buffer.int16ChannelData?[0].initialize(repeating: 0, count: 1600)
            try file.write(from: buffer)
        }

        func enableFallbackMicrophone() { fallbackCalls += 1 }

        func stop() async throws -> Int64 {
            stopCalls += 1
            return 1600
        }
    }

    private func withModel(
        captures: [Capture], authorize: @escaping @MainActor () async -> Bool,
        inputs: (() -> MicrophoneDevicesSnapshot)? = nil,
        run: (AppModel, RecordingRepository, MicrophoneDevices) async throws -> Void
    ) async throws {
        let name = "RecordingStartTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: root)
        }
        let repo = try RecordingRepository(root: root)
        let microphone = MicrophoneInputDevice(deviceID: 10, uid: "built-in", name: "Built-In Mic", isBuiltIn: true)
        let loadSnapshot = inputs ?? {
            MicrophoneDevicesSnapshot(devices: [microphone], defaultDeviceID: microphone.deviceID)
        }
        let devices = MicrophoneDevices(observeChanges: false, loadSnapshot: loadSnapshot, loadRoute: { id in
                guard let input = loadSnapshot().devices.first(where: { $0.deviceID == id }) else { return nil }
                return HALInputRoute(uid: input.uid, nominalRate: 48_000, channels: 1, streams: [], controls: [])
            })
        var remaining = captures
        let model = AppModel(repository: repo, startServices: false, userDefaults: defaults, microphoneDevices: devices,
                             requestMicrophoneAccess: authorize, makeRecordingCapture: { _ in
            XCTAssertFalse(remaining.isEmpty)
            return remaining.isEmpty ? Capture() : remaining.removeFirst()
        })
        model.backgroundRecognition = false
        await model.reload()
        do { try await run(model, repo, devices) }
        catch { await model.shutdown(); throw error }
        await model.shutdown()
    }

    private func configure(_ model: AppModel, microphone: Bool, systemAudio: Bool,
                           selection: MicrophoneSelection = .builtIn) throws {
        let draft = SettingsDraft(model: model)
        draft.recordingSources.microphoneEnabled = microphone
        draft.recordingSources.systemAudioEnabled = systemAudio
        draft.recordingSources.microphone = selection
        try model.applySettings(draft)
    }

    func testMicrophonePermissionIsRequestedOnlyForMicrophoneModes() async throws {
        let microphone = Capture(), system = Capture(), mixed = Capture()
        var grants = 0
        try await withModel(captures: [microphone, system, mixed], authorize: { grants += 1; return true }) { model, repo, _ in
            await model.startRecording()
            XCTAssertEqual(grants, 1)
            XCTAssertEqual(microphone.microphone?.uid, "built-in")
            XCTAssertFalse(microphone.systemAudio)
            await model.stopRecording()

            try configure(model, microphone: false, systemAudio: true)
            await model.startRecording()
            XCTAssertEqual(grants, 1)
            XCTAssertNil(system.microphone)
            XCTAssertTrue(system.systemAudio)
            XCTAssertTrue(model.indicators.waitingForSystemAudio)
            await model.stopRecording()

            try configure(model, microphone: true, systemAudio: true, selection: .systemDefault)
            await model.startRecording()
            XCTAssertEqual(grants, 2)
            XCTAssertEqual(mixed.microphone?.uid, "built-in")
            XCTAssertTrue(mixed.systemAudio)
            await model.stopRecording()
            XCTAssertEqual(repo.list().count, 3)
            XCTAssertTrue(repo.list().allSatisfy { $0.sourceComplete && $0.sampleRate == 16_000 && $0.durationMs == 100 })
        }
    }

    func testDeniedOrFailedStartDoesNotPublishOrQueueRecording() async throws {
        var requests = 0
        var inputConnected = true
        let input = MicrophoneInputDevice(deviceID: 10, uid: "built-in", name: "Built-In Mic", isBuiltIn: true)
        let systemFailure = Capture()
        systemFailure.startError = ScribeError.message("Поток системного звука прервался.")
        try await withModel(captures: [systemFailure], authorize: { requests += 1; return false }, inputs: {
            inputConnected ? .init(devices: [input], defaultDeviceID: input.deviceID) : .init()
        }) { model, repo, _ in
            await model.startRecording()
            try configure(model, microphone: true, systemAudio: true)
            await model.startRecording()
            XCTAssertEqual(requests, 2)
            XCTAssertEqual(model.errorHandler.messages.count, 2)

            try configure(model, microphone: false, systemAudio: true)
            await model.startRecording()
            XCTAssertEqual(requests, 2)
            XCTAssertEqual(systemFailure.startCalls, 1)
            XCTAssertEqual(systemFailure.stopCalls, 1)
            XCTAssertEqual(model.errorHandler.messages.last, "Поток системного звука прервался.")

            try configure(model, microphone: false, systemAudio: false)
            XCTAssertNil(model.requestRecording())
            XCTAssertEqual(model.errorHandler.messages.last, "Включите хотя бы один источник записи.")

            inputConnected = false
            try configure(model, microphone: true, systemAudio: false, selection: .device(uid: "absent", name: "USB Mic"))
            XCTAssertNil(model.requestRecording())
            XCTAssertEqual(requests, 2)
            XCTAssertNil(model.recordingID)
            XCTAssertFalse(model.startingRecording)
            XCTAssertTrue(repo.list().isEmpty)
        }
    }

    func testMissingPreferredInputPinsBuiltInFallbackAndKeepsPreference() async throws {
        let capture = Capture()
        let selected = MicrophoneSelection.device(uid: "absent", name: "USB Mic")
        try await withModel(captures: [capture], authorize: { true }) { model, repo, _ in
            try configure(model, microphone: true, systemAudio: false, selection: selected)
            await model.startRecording()
            XCTAssertNotNil(model.recordingID)
            XCTAssertEqual(capture.microphone?.uid, "built-in")
            XCTAssertEqual(model.recordingSources.microphone, selected)
            await model.stopRecording()
            XCTAssertTrue(repo.list().first?.sourceComplete == true)
        }
    }

    func testMixedStartWithoutInputsRequestsPermissionAndPublishesWarning() async throws {
        let capture = Capture()
        let warning = "Запись началась без микрофона. Системный звук продолжает записываться."
        capture.startup = { [weak capture] in
            capture?.onMicrophoneStatus?(.waiting)
            capture?.onWarning?(warning)
        }
        var permissionRequests = 0
        try await withModel(captures: [capture], authorize: { permissionRequests += 1; return true },
                            inputs: { .init() }) { model, repo, _ in
            try configure(model, microphone: true, systemAudio: true, selection: .device(uid: "absent", name: "USB Mic"))
            await model.startRecording()
            let id = try XCTUnwrap(model.recordingID)
            XCTAssertEqual(permissionRequests, 1)
            XCTAssertTrue(capture.microphoneRequested)
            XCTAssertNil(capture.microphone)
            XCTAssertTrue(capture.systemAudio)
            XCTAssertEqual(model.indicators.microphoneStatus, .waiting)
            XCTAssertEqual(try repo.load(id).warnings, [warning])
            await model.stopRecording()
            XCTAssertNil(model.indicators.microphoneStatus)
        }
    }

    func testFallbackButtonRequiresCurrentRecordingMuteHold() async throws {
        let first = Capture(), second = Capture()
        try await withModel(captures: [first, second], authorize: { true }) { model, _, _ in
            await model.startRecording()
            model.enableFallbackMicrophone()
            XCTAssertEqual(first.fallbackCalls, 0)
            first.onMicrophoneStatus?(.mutedFallback)
            model.enableFallbackMicrophone()
            XCTAssertEqual(first.fallbackCalls, 1)
            await model.stopRecording()
            await model.startRecording()
            first.onMicrophoneStatus?(.mutedFallback)
            model.enableFallbackMicrophone()
            XCTAssertEqual(second.fallbackCalls, 0)
            await model.stopRecording()
        }
    }

    func testStartFreezesSettingsAndDestinationBeforePermission() async throws {
        let capture = Capture()
        var permission: CheckedContinuation<Bool, Never>?
        try await withModel(captures: [capture], authorize: {
            await withCheckedContinuation { permission = $0 }
        }) { model, repo, _ in
            try await model.saveGroupName("Первая")
            try await model.saveGroupName("Вторая")
            let first = try XCTUnwrap(model.recordingGroups.groups.first { $0.name == "Первая" })
            let second = try XCTUnwrap(model.recordingGroups.groups.first { $0.name == "Вторая" })
            await model.changeGroups { try $0.setDefault(first.id) }

            try configure(model, microphone: true, systemAudio: true, selection: .systemDefault)
            let start = try XCTUnwrap(model.requestRecording())
            while permission == nil { await Task.yield() }
            XCTAssertTrue(model.startingRecording)
            await model.changeGroups { try $0.setDefault(second.id) }
            try configure(model, microphone: false, systemAudio: false)
            permission?.resume(returning: true)
            await start.value

            let id = try XCTUnwrap(model.recordingID)
            XCTAssertEqual(model.recordingGroups.groupID(for: id), first.id)
            XCTAssertEqual(capture.microphone?.uid, "built-in")
            XCTAssertTrue(capture.systemAudio)
            XCTAssertEqual(try repo.load(id).state, .recording)
            await model.stopRecording()
        }
    }

    func testSleepInvalidatesPermissionWaitWithoutWaitingForTCC() async throws {
        var permission: CheckedContinuation<Bool, Never>?
        try await withModel(captures: [], authorize: {
            await withCheckedContinuation { permission = $0 }
        }) { model, repo, _ in
            let start = try XCTUnwrap(model.requestRecording())
            while permission == nil { await Task.yield() }
            await model.prepareForSleep()
            XCTAssertFalse(model.startingRecording)
            XCTAssertNil(model.recordingID)
            permission?.resume(returning: true)
            await start.value
            XCTAssertTrue(repo.list().isEmpty)
        }
    }

    func testShutdownCancelsOpeningSystemAudioBeforeArchivePublication() async throws {
        let capture = Capture()
        capture.startup = { try await Task.sleep(for: .seconds(60)) }
        try await withModel(captures: [capture], authorize: {
            XCTFail("System-only mode must not request microphone access")
            return false
        }) { model, repo, _ in
            try configure(model, microphone: false, systemAudio: true)
            let start = try XCTUnwrap(model.requestRecording())
            while capture.startCalls == 0 { await Task.yield() }
            await model.shutdown()
            await start.value
            XCTAssertEqual(capture.stopCalls, 1)
            XCTAssertFalse(model.startingRecording)
            XCTAssertNil(model.recordingID)
            XCTAssertTrue(repo.list().isEmpty)
        }
    }

    func testSourceLossPersistsAndOldCallbacksCannotAffectNextRecording() async throws {
        let first = Capture(), second = Capture()
        try await withModel(captures: [first, second], authorize: { true }) { model, repo, _ in
            try configure(model, microphone: true, systemAudio: true)
            await model.startRecording()
            let firstID = try XCTUnwrap(model.recordingID)
            first.onWarning?("Выбранный микрофон стал недоступен.")
            XCTAssertEqual(model.recordingID, firstID)
            XCTAssertEqual(model.indicators.captureWarnings, ["Выбранный микрофон стал недоступен."])
            first.onStopNeeded?("Поток системного звука прервался.")
            for _ in 0..<100 where model.recordingID != nil || model.finalizingRecording {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertNil(model.recordingID)
            XCTAssertTrue(try repo.load(firstID).sourceComplete)
            XCTAssertEqual(Set(try repo.load(firstID).warnings),
                           ["Выбранный микрофон стал недоступен.", "Поток системного звука прервался."])

            await model.startRecording()
            let secondID = try XCTUnwrap(model.recordingID)
            first.onMeter?(CaptureMeterReading(level: 1, elapsed: 99, soundNotice: "old", waitingForSystemAudio: false))
            first.onWarning?("old warning")
            first.onStopNeeded?("old stop")
            first.onResourcePressure?()
            await Task.yield()
            XCTAssertEqual(model.recordingID, secondID)
            XCTAssertEqual(model.indicators.elapsed, 0)
            XCTAssertTrue(model.indicators.captureWarnings.isEmpty)
            XCTAssertTrue(model.indicators.waitingForSystemAudio)
            XCTAssertNil(model.resourcePauseTitle)
            await model.stopRecording()
        }
    }
}
