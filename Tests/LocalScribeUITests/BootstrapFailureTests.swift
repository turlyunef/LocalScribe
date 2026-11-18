import AVFoundation
import CoreAudio
import XCTest
@testable import LocalScribeCore
@testable import LocalScribe

/// Regression tests for the «silent bootstrap paralysis» cluster at the
/// AppModel level: an unreadable pinned model catalog, an unreadable
/// recordings directory and an unreadable capture fragment directory must all
/// reach the user through the error handler instead of leaving the app inert.
/// Unreadability is simulated with chmod 000 and always restored in defer.
@MainActor
final class BootstrapFailureTests: XCTestCase {
    private enum StopError: Error { case failed }

    private func makeDefaults() throws -> UserDefaults {
        let name = "BootstrapFailureTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return defaults
    }
    private func deny(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
    }
    private func allow(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !predicate() && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(predicate())
    }
    private static func writeCapturePart(to folder: URL) throws {
        try Disk.directory(folder)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        buffer.floatChannelData![0].initialize(repeating: 0.125, count: 16_000)
        let file = try AVAudioFile(forWriting: folder.appendingPathComponent("part-000000.caf"), settings: format.settings)
        try file.write(from: buffer)
    }

    // MARK: - Point A: pinned model catalog

    func testUnreadableModelCatalogIsReportedOnceWithVisibleStatus() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root)
        let model = AppModel(repository: repo, startServices: false, userDefaults: try makeDefaults(),
                             catalog: nil, loadCatalog: { _ in throw CocoaError(.fileReadNoPermission) })
        XCTAssertEqual(model.errorHandler.messages.count, 1)
        XCTAssertTrue(model.errorHandler.messages[0].contains("Закреплённый каталог моделей не читается"))
        XCTAssertNil(model.catalog)
        XCTAssertFalse(model.modelsReady)
        // The status explains the paralysis instead of eternal «Проверяем модели…».
        XCTAssertTrue(model.modelsStatus.contains("Закреплённый каталог моделей не читается"))
        XCTAssertFalse(model.modelsStatus.contains("Проверяем модели"))
        // Verification with no catalog stays silent and never resets the status.
        await model.verifyModels()
        XCTAssertEqual(model.errorHandler.messages.count, 1)
        XCTAssertTrue(model.modelsStatus.contains("Закреплённый каталог моделей не читается"))
        await model.reload()
        XCTAssertEqual(model.errorHandler.messages.count, 1, "the catalog failure is reported exactly once")
        await model.shutdown()
    }

    func testProvidedCatalogKeepsBootstrapSilent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root)
        let model = AppModel(repository: repo, startServices: false, userDefaults: try makeDefaults(),
                             catalog: ModelCatalog(models: []),
                             loadCatalog: { _ in throw CocoaError(.fileReadNoPermission) })
        XCTAssertTrue(model.errorHandler.messages.isEmpty, "an explicitly provided catalog never reports load failures")
        XCTAssertNotNil(model.catalog)
        XCTAssertFalse(model.modelsStatus.contains("не читается"))
        await model.shutdown()
    }

    // MARK: - Point B: unreadable recordings root

    func testUnreadableRecordingsRootIsReportedOnceAndKeepsPreviousIndex() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root)
        var manifest = Manifest(sourceType: "microphone", title: "Existing", filename: "original.caf")
        manifest.sourceComplete = true; manifest.sha256 = String(repeating: "a", count: 64); manifest.durationMs = 1000
        try repo.save(manifest)
        try repo.writeIndex([manifest])
        try deny(root.appendingPathComponent("recordings"))
        defer { try? allow(root.appendingPathComponent("recordings")) }

        let model = AppModel(repository: repo, startServices: false, userDefaults: try makeDefaults(),
                             catalog: ModelCatalog(models: []))
        try await waitUntil { model.errorHandler.messages.contains { $0.contains("Не удалось прочитать каталог записей") } }
        XCTAssertEqual(model.errorHandler.messages.filter { $0.contains("Не удалось прочитать каталог записей") }.count, 1)
        XCTAssertTrue(model.recordings.isEmpty, "the unreadable archive does not masquerade as content")
        // The derived index is never replaced with the unreadable archive's empty listing.
        XCTAssertEqual(try Disk.read([Manifest].self, at: root.appendingPathComponent("index.json")).map(\.id), [manifest.id])
        await model.reload()
        XCTAssertEqual(model.errorHandler.messages.filter { $0.contains("Не удалось прочитать каталог записей") }.count, 1,
                       "repeated reloads never spam the archive error")
        await model.shutdown()
        XCTAssertEqual(try Disk.read([Manifest].self, at: root.appendingPathComponent("index.json")).map(\.id), [manifest.id])
    }

    // MARK: - Point C: unreadable capture fragment directory

    private func makeModel(root: URL, capture: (any RecordingCapture)? = nil, devices: MicrophoneDevices? = nil) throws -> AppModel {
        AppModel(repository: try RecordingRepository(root: root), startServices: false, userDefaults: try makeDefaults(),
                 catalog: ModelCatalog(models: []), microphoneDevices: devices,
                 requestMicrophoneAccess: { true }, makeRecordingCapture: { capture ?? MicrophoneRecorder(devices: $0) },
                 recognizeLiveCaptions: { _, stream, ready, _ in
            await ready()
            for await _ in stream {}
        }, recognizeMixedLiveCaptions: { stream, ready, _ in
            await ready()
            for await _ in stream {}
        })
    }

    private final class Capture: RecordingCapture {
        var onMeter: ((CaptureMeterReading) -> Void)?
        var onStopNeeded: ((String) -> Void)?
        var onWarning: ((String) -> Void)?
        var onResourcePressure: (() -> Void)?
        var onMicrophoneStatus: ((CaptureMicrophoneStatus) -> Void)?
        var writesFragment = true
        var stopFails = false

        func start(folder: URL, microphone: MicrophoneCaptureRequest?, systemAudio: Bool) async throws {
            guard writesFragment else { try Disk.directory(folder); return }
            try BootstrapFailureTests.writeCapturePart(to: folder)
        }
        func enableFallbackMicrophone() {}
        func stop() async throws -> Int64 {
            if stopFails { throw StopError.failed }
            return 16_000
        }
    }

    private func microphoneDevices() -> MicrophoneDevices {
        let microphone = MicrophoneInputDevice(deviceID: 10, uid: "built-in", name: "Built-In Mic", isBuiltIn: true)
        return MicrophoneDevices(observeChanges: false, loadSnapshot: {
            MicrophoneDevicesSnapshot(devices: [microphone], defaultDeviceID: microphone.deviceID)
        }, loadRoute: { id in
            guard let input = microphone.deviceID == id ? microphone : nil else { return nil }
            return HALInputRoute(uid: input.uid, nominalRate: 48_000, channels: 1, streams: [], controls: [])
        })
    }

    func testStopRecordingWithUnreadableCaptureKeepsInterruptedState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = Capture()
        capture.stopFails = true
        let model = try makeModel(root: root, capture: capture, devices: microphoneDevices())
        model.backgroundRecognition = false
        try await model.startRecording()
        let id = try XCTUnwrap(model.recordingID)
        let captureFolder = try RecordingRepository(root: root).folder(id).appendingPathComponent("capture")
        XCTAssertTrue(FileManager.default.fileExists(atPath: captureFolder.appendingPathComponent("part-000000.caf").path))
        try deny(captureFolder)

        await model.stopRecording()

        let saved = try RecordingRepository(root: root).load(id)
        XCTAssertEqual(saved.state, .interrupted, "an unreadable fragment directory is not «no saved audio»")
        XCTAssertEqual(saved.lastError, "Каталог фрагментов записи не читается. Фрагменты могут быть целы; проверьте доступ и повторите остановку.")
        XCTAssertTrue(model.errorHandler.messages.contains { $0.contains("Каталог фрагментов записи не читается") })
        XCTAssertFalse(model.errorHandler.messages.contains { $0.contains("Нет сохранённого звука") })
        await model.shutdown()
        try allow(captureFolder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: captureFolder.appendingPathComponent("part-000000.caf").path),
                      "the fragments are kept for recovery")
    }

    func testStopRecordingWithoutFragmentsStillFailsHonestly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = Capture()
        capture.stopFails = true
        capture.writesFragment = false
        let model = try makeModel(root: root, capture: capture, devices: microphoneDevices())
        model.backgroundRecognition = false
        try await model.startRecording()
        let id = try XCTUnwrap(model.recordingID)

        await model.stopRecording()

        let saved = try RecordingRepository(root: root).load(id)
        XCTAssertEqual(saved.state, .failed)
        XCTAssertEqual(saved.lastError, "Нет сохранённого звука. Начните новую запись.")
        await model.shutdown()
    }

    func testResumeWithUnreadableCaptureKeepsInterruptedState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root)
        let model = try makeModel(root: root)
        var manifest = Manifest(sourceType: "microphone", title: "Interrupted capture", filename: "original.caf")
        manifest.state = .interrupted
        try repo.save(manifest)
        let captureFolder = repo.folder(manifest.id).appendingPathComponent("capture")
        try Self.writeCapturePart(to: captureFolder)
        try deny(captureFolder)
        defer { try? allow(captureFolder) }

        let resume = model.resume(manifest.id)
        await resume?.value

        let saved = try repo.load(manifest.id)
        XCTAssertEqual(saved.state, .interrupted, "an unreadable fragment directory is not «no saved audio»")
        XCTAssertEqual(saved.lastError, "Каталог фрагментов записи не читается. Фрагменты могут быть целы; проверьте доступ и повторите.")
        XCTAssertTrue(model.errorHandler.messages.contains { $0.contains("Каталог фрагментов записи не читается") })
        XCTAssertNil(model.queuePosition(for: manifest.id))
        await model.shutdown()
    }

    func testResumeWithoutCaptureDirectoryStillFailsHonestly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root)
        let model = try makeModel(root: root)
        var manifest = Manifest(sourceType: "microphone", title: "No audio", filename: "original.caf")
        manifest.state = .interrupted
        try repo.save(manifest)

        let resume = model.resume(manifest.id)
        await resume?.value

        let saved = try repo.load(manifest.id)
        XCTAssertEqual(saved.state, .failed)
        XCTAssertEqual(saved.lastError, "В этой записи нет сохранённого звука. Начните новую запись.")
        await model.shutdown()
    }
}
