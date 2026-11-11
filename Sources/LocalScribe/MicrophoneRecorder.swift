import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import Combine
import LocalScribeCore

struct CaptureMeterReading: Sendable {
    let level: Double
    let elapsed: Double
    let soundNotice: String?
    let waitingForSystemAudio: Bool
}

struct MicrophoneCaptureRequest {
    let selection: MicrophoneSelection
    let initial: PinnedMicrophone?

    @MainActor func candidates(in devices: MicrophoneDevices, keeping currentUID: String? = nil) -> [PinnedMicrophone] {
        if !selection.allowsAutomaticFallback, let initial {
            return (try? devices.refreshFormat(of: initial)).map { [$0] } ?? []
        }
        return devices.candidates(for: selection, keeping: currentUID)
    }
}

enum CaptureMicrophoneStatus: Equatable {
    case active(String)
    case waiting
    case mutedFallback
}

@MainActor protocol RecordingCapture: AnyObject {
    var onMeter: ((CaptureMeterReading) -> Void)? { get set }
    var onStopNeeded: ((String) -> Void)? { get set }
    var onWarning: ((String) -> Void)? { get set }
    var onResourcePressure: (() -> Void)? { get set }
    var onMicrophoneStatus: ((CaptureMicrophoneStatus) -> Void)? { get set }

    func start(folder: URL, microphone: MicrophoneCaptureRequest?, systemAudio: Bool) async throws
    func enableFallbackMicrophone()
    func stop() async throws -> Int64
}

@MainActor final class MicrophoneRecorder: RecordingCapture {
    private struct FailedInput {
        let deviceID: AudioDeviceID
        var physicalRouteChanged = false
    }

    private let devices: MicrophoneDevices
    private var engine: AVAudioEngine?
    private var bluetoothMicrophone: BluetoothMicrophoneCapture?
    private var systemCapture: SystemAudioCapture?
    private var ingress: CaptureIngress?
    private var sources: Set<CaptureAudioSource> = []
    private var starting = false
    private var startupFailure: String?
    private var activity: NSObjectProtocol?
    private var changeObserver: NSObjectProtocol?
    private var inputObserver: HALPropertyObservation?
    private var configurationTask: Task<Void, Never>?
    private var microphoneMonitor: Task<Void, Never>?
    private var inventoryObservation: AnyCancellable?
    private var routingTask: Task<Void, Never>?
    private var routingRequested = false
    private var recoveryDeadline: ContinuousClock.Instant?
    private var recoveryTimeout: Task<Void, Never>?
    private var recoveryRetry: Task<Void, Never>?
    private var failedInputs: [String: FailedInput] = [:]
    private var durationLimit: Task<Void, Never>?
    private var microphoneRequest: MicrophoneCaptureRequest?
    private var microphone: PinnedMicrophone?
    private var microphoneToken: UUID?
    private var microphoneWasMuted = false
    private var awaitingFallbackConsent = false
    private var microphoneStatus: CaptureMicrophoneStatus? {
        didSet {
            if let microphoneStatus, microphoneStatus != oldValue { onMicrophoneStatus?(microphoneStatus) }
        }
    }
    private var expectedInput: CaptureInputConfiguration?
    private var restartTimes: [Date] = []
    private var tapInstalled = false
    private(set) var configurationEventCount = 0
    private(set) var engineRestartCount = 0

    var onMeter: ((CaptureMeterReading) -> Void)?
    var onStopNeeded: ((String) -> Void)?
    var onWarning: ((String) -> Void)?
    var onResourcePressure: (() -> Void)?
    var onMicrophoneStatus: ((CaptureMicrophoneStatus) -> Void)?

    init(devices: MicrophoneDevices) {
        self.devices = devices
    }

    func start(folder: URL, microphone: MicrophoneCaptureRequest?, systemAudio: Bool) async throws {
        starting = true
        defer { starting = false }
        microphoneRequest = microphone
        if microphone != nil { sources.insert(.microphone) }
        if systemAudio { sources.insert(.systemAudio) }
        let ingress = CaptureIngress(
            meter: { [weak self] reading in Task { @MainActor in self?.onMeter?(reading) } },
            failure: { [weak self] reason in Task { @MainActor in self?.onStopNeeded?(reason) } },
            pressure: { [weak self] in Task { @MainActor in self?.onResourcePressure?() } }
        )
        self.ingress = ingress
        do {
            // The tap can trigger a permission prompt. Start it before opening
            // the microphone and before admitting PCM to the shared timeline.
            if systemAudio {
                let capture = SystemAudioCapture()
                systemCapture = capture
                do {
                    try await capture.start(onAudio: { list, format, hostTime, _ in
                        ingress.submitSystemAudio(list, format: format, hostTime: hostTime)
                    }, onLoss: { [weak self] reason in
                        Task { @MainActor in await self?.loseSystemAudio(warning: reason) }
                    })
                } catch is CancellationError {
                    // HAL owns cleanup if the permission dialog is still pending.
                    systemCapture = nil
                    throw CancellationError()
                }
            }
            try Task.checkCancellation()
            if let microphone { try await openInitialMicrophone(microphone, systemAudio: systemAudio) }
            if let startupFailure { throw ScribeError.message(startupFailure) }
            try await ingress.start(folder: folder, sources: sources)
            try Task.checkCancellation()
            if let startupFailure { throw ScribeError.message(startupFailure) }
            if self.microphone == nil, !sources.contains(.systemAudio) {
                throw ScribeError.message("Микрофон стал недоступен при запуске записи.")
            }
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled], reason: L10n.text("Запись LocalScribe")
            )
            durationLimit = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(10_800)) } catch { return }
                if ingress.closeAdmission() { self?.onStopNeeded?("Достигнут предел 3 часа. Запись сохранена.") }
            }
            if let microphoneRequest, microphoneRequest.selection.allowsAutomaticFallback || self.microphone == nil {
                // The publisher emits before storing its snapshot; the routing task
                // reads fresh HAL state after this turn of MainActor.
                inventoryObservation = devices.$snapshot.dropFirst().sink { [weak self] snapshot in
                    self?.inventoryChanged(snapshot)
                }
                scheduleRouting()
            }
        } catch {
            _ = try? await stop()
            throw error
        }
    }

    private func openInitialMicrophone(_ request: MicrophoneCaptureRequest, systemAudio: Bool) async throws {
        var candidates = request.candidates(in: devices)
        if let initial = request.initial, let pinned = try? devices.refreshFormat(of: initial) {
            candidates.removeAll { $0.uid == pinned.uid }
            candidates.insert(pinned, at: 0)
        }
        var lastError: Error?
        for candidate in candidates {
            do {
                try await startMicrophone(candidate, deadline: .now + .seconds(4))
                return
            } catch {
                stopMicrophone()
                try Task.checkCancellation()
                if (try? devices.refreshFormat(of: candidate)) != nil {
                    failedInputs[candidate.uid] = FailedInput(deviceID: candidate.deviceID)
                    lastError = error
                }
            }
        }
        if let lastError { throw lastError }
        guard systemAudio else { throw ScribeError.message(request.selection.unavailableMessage) }
        microphoneStatus = .waiting
        onWarning?("Запись началась без микрофона. Системный звук продолжает записываться.")
    }

    private func startMicrophone(_ microphone: PinnedMicrophone, deadline: ContinuousClock.Instant) async throws {
        try Task.checkCancellation()
        let microphone = try devices.refreshFormat(of: microphone)
        guard let ingress, let token = ingress.beginMicrophoneAttempt() else { throw CancellationError() }
        microphoneToken = token
        if BluetoothMicrophoneCapture.supports(deviceID: microphone.deviceID) {
            // AirPods can expose 24 kHz through HAL while the engine input
            // bus still reports 48 kHz, even after the engine starts.
            let capture = BluetoothMicrophoneCapture(deviceID: microphone.deviceID)
            bluetoothMicrophone = capture
            try capture.start { list, rate, time in
                ingress.submitMono(.microphone, list: list, sampleRate: rate, hostTime: time, microphoneToken: token)
            }
        } else {
            try startEngineMicrophone(microphone, ingress: ingress, token: token)
        }

        // In mixed mode, system audio can otherwise mask an input that opened
        // successfully but never sends a packet. Silence is valid PCM.
        while ingress.lastMicrophoneCallbackHostTime(for: token) == nil {
            guard ContinuousClock.now < deadline else {
                throw ScribeError.message("Выбранный микрофон не передал аудиоданные при запуске.")
            }
            try await Task.sleep(for: .milliseconds(40))
        }
        try Task.checkCancellation()
        guard microphoneToken == token else { throw CancellationError() }
        guard ContinuousClock.now < deadline else {
            throw ScribeError.message("Выбранный микрофон не передал аудиоданные при запуске.")
        }
        let negotiated = try devices.refreshFormat(of: microphone)
        if let engine {
            guard let current = currentInput(), current.deviceID == negotiated.deviceID,
                  supportsMicrophone(current) else {
                throw ScribeError.message("Вход или формат выбранного микрофона изменился.")
            }
            expectedInput = current
            changeObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.scheduleConfigurationCheck(token) }
            }
        } else {
            try bluetoothMicrophone?.updateFormat()
        }
        guard ingress.activateMicrophone(token) else { throw CancellationError() }
        self.microphone = negotiated
        if let request = microphoneRequest, !request.selection.allowsAutomaticFallback, request.initial == nil {
            microphoneRequest = MicrophoneCaptureRequest(selection: request.selection, initial: negotiated)
        }
        updateMute(negotiated, token: token)
        observeInput(negotiated, token: token)
        microphoneStatus = .active(negotiated.name)
        microphoneMonitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, let last = ingress.lastMicrophoneCallbackHostTime(for: token) else { return }
                let now = AudioGetCurrentHostTime()
                if now > last, AVAudioTime.seconds(forHostTime: now - last) >= 3 {
                    self.microphoneLost(token, warning: "Микрофон перестал передавать аудиоданные.")
                    return
                }
            }
        }
        if engine?.isRunning == false { scheduleConfigurationCheck(token) }
    }

    private func startEngineMicrophone(_ microphone: PinnedMicrophone, ingress: CaptureIngress, token: UUID) throws {
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        var deviceID = microphone.deviceID
        guard let unit = input.audioUnit,
              AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                   &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
            throw ScribeError.message("Не удалось закрепить выбранный микрофон.")
        }
        let hardware = input.inputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0,
              let configuration = currentInput(), configuration.deviceID == microphone.deviceID,
              supportsMicrophone(configuration) else {
            throw ScribeError.message("Выбранный микрофон недоступен или имеет неподдерживаемый формат.")
        }
        try installMicrophoneTap(input, sampleRate: configuration.sampleRate, ingress: ingress, token: token)
        engine.prepare()
        try engine.start()
    }

    private func installMicrophoneTap(_ input: AVAudioInputNode, sampleRate: Double, ingress: CaptureIngress, token: UUID) throws {
        // Passing a preflight format to the tap can throw an Objective-C
        // exception if Bluetooth changes rate during device activation.
        if #available(macOS 27.0, *) {
            let frames = AVAudioFrameCount((sampleRate / 5).rounded(.up))
            try input.installAudioTap(onBus: 0, bufferSize: frames, format: nil) { buffer, time in
                guard time.isHostTimeValid else { return }
                buffer.withUnsafeAudioBufferList { list in
                    ingress.submitMicrophone(list, format: buffer.format, frameCount: buffer.frameLength, hostTime: time.hostTime, token: token)
                }
            }
        } else {
            input.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, time in
                guard time.isHostTimeValid else { return }
                ingress.submitMicrophone(buffer.audioBufferList, format: buffer.format,
                                         frameCount: Int(buffer.frameLength), hostTime: time.hostTime, token: token)
            }
        }
        tapInstalled = true
    }

    private func observeInput(_ microphone: PinnedMicrophone, token: UUID) {
        inputObserver?.stop()
        inputObserver = devices.observe(microphone) { [weak self] in
            // Sample mute before the debounced route check while the old UID is readable.
            guard let self, self.microphoneToken == token else { return }
            self.updateMute(microphone, token: token)
            self.scheduleConfigurationCheck(token)
        }
    }

    private func updateMute(_ microphone: PinnedMicrophone, token: UUID) {
        guard microphoneToken == token, let muted = devices.microphoneMuteState(microphone) else { return }
        if !muted, microphoneWasMuted, (try? devices.refreshFormat(of: microphone)) == nil { return }
        microphoneWasMuted = muted
        ingress?.setMicrophoneMuted(muted, token: token)
    }

    private func supportsMicrophone(_ configuration: CaptureInputConfiguration) -> Bool {
        (8_000...384_000).contains(configuration.sampleRate) && configuration.channels > 0
            && configuration.formatID == kAudioFormatLinearPCM && configuration.formatFlags & kAudioFormatFlagIsFloat != 0
    }

    private func configuration(device: AudioDeviceID, format: AVAudioFormat) -> CaptureInputConfiguration {
        let stream = format.streamDescription.pointee
        return CaptureInputConfiguration(deviceID: device, sampleRate: stream.mSampleRate,
                                         channels: stream.mChannelsPerFrame, formatID: stream.mFormatID,
                                         formatFlags: stream.mFormatFlags)
    }

    private func currentInput() -> CaptureInputConfiguration? {
        guard let engine, let unit = engine.inputNode.audioUnit else { return nil }
        var current = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                   &current, &size) == noErr else { return nil }
        return configuration(device: current, format: engine.inputNode.outputFormat(forBus: 0))
    }

    private func scheduleConfigurationCheck(_ token: UUID) {
        guard microphoneToken == token else { return }
        configurationEventCount += 1
        configurationTask?.cancel()
        configurationTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            self?.checkConfiguration(token)
        }
    }

    private func checkConfiguration(_ token: UUID) {
        guard microphoneToken == token, let microphone else { return }
        let negotiated: PinnedMicrophone
        do {
            negotiated = try devices.refreshFormat(of: microphone)
            try bluetoothMicrophone?.updateFormat()
        } catch {
            microphoneLost(token, warning: error.localizedDescription)
            return
        }
        if negotiated != microphone { observeInput(negotiated, token: token) }
        self.microphone = negotiated
        updateMute(negotiated, token: token)
        if !microphoneWasMuted { scheduleRouting() }
        guard let expectedInput, let engine, let ingress else { return }
        guard let current = currentInput(), supportsMicrophone(current) else {
            microphoneLost(token, warning: "Выбранный микрофон стал недоступен.")
            return
        }
        guard current.deviceID == negotiated.deviceID else {
            microphoneLost(token, warning: "Вход или формат выбранного микрофона изменился.")
            return
        }
        self.expectedInput = current
        guard !engine.isRunning else { return }

        let now = Date()
        restartTimes.removeAll { now.timeIntervalSince($0) > 5 }
        guard restartTimes.count < 3 else {
            microphoneLost(token, warning: "Аудиодвижок микрофона нестабилен.")
            return
        }
        restartTimes.append(now)
        do {
            if current != expectedInput {
                engine.inputNode.removeTap(onBus: 0)
                tapInstalled = false
                try installMicrophoneTap(engine.inputNode, sampleRate: current.sampleRate, ingress: ingress, token: token)
            }
            try engine.start()
            let updated = try devices.refreshFormat(of: negotiated)
            guard let restarted = currentInput(), restarted.deviceID == updated.deviceID, supportsMicrophone(restarted) else {
                microphoneLost(token, warning: "Вход или формат выбранного микрофона изменился.")
                return
            }
            if updated != negotiated { observeInput(updated, token: token) }
            self.microphone = updated
            self.expectedInput = restarted
            engineRestartCount += 1
            onWarning?("Аудиодвижок перезапущен с прежним микрофоном; возможен короткий пропуск звука.")
        } catch {
            microphoneLost(token, warning: "Не удалось возобновить аудиодвижок микрофона.")
        }
    }

    private func loseSystemAudio(warning: String) async {
        guard sources.remove(.systemAudio) != nil else { return }
        if starting { startupFailure = startupFailure ?? warning }
        ingress?.endSource(.systemAudio)
        if !starting {
            if sources.isEmpty { onStopNeeded?(warning) }
            else {
                onWarning?(warning)
                if microphone == nil { beginMicrophoneRecovery() }
            }
        }
        recoveryRetry?.cancel()
        recoveryRetry = nil
        if let systemCapture { await systemCapture.stop() }
    }

    private func microphoneLost(_ token: UUID, warning: String) {
        guard microphoneToken == token, let microphone else { return }
        let routeStillAvailable = (try? devices.refreshFormat(of: microphone)) != nil
        updateMute(microphone, token: token)
        let allowsFallback = microphoneRequest?.selection.allowsAutomaticFallback == true
        awaitingFallbackConsent = allowsFallback && microphoneWasMuted
        if routeStillAvailable {
            failedInputs[microphone.uid] = FailedInput(deviceID: microphone.deviceID)
        } else if (try? devices.resolve(.device(uid: microphone.uid, name: microphone.name)))?.deviceID == microphone.deviceID {
            // A surviving UID may now expose another physical input. Treat
            // it as a different route until HAL reports a genuine reattach.
            failedInputs[microphone.uid] = FailedInput(deviceID: microphone.deviceID, physicalRouteChanged: true)
        }
        stopMicrophone()
        microphoneStatus = awaitingFallbackConsent ? .mutedFallback : .waiting
        if !allowsFallback {
            sources.remove(.microphone)
            ingress?.endSource(.microphone)
        }
        if starting {
            if sources.isEmpty { startupFailure = warning }
            else { onWarning?(warning) }
        } else if sources.isEmpty {
            onStopNeeded?(warning)
        } else {
            onWarning?(warning)
            if allowsFallback, !awaitingFallbackConsent {
                beginMicrophoneRecovery()
            }
        }
        if awaitingFallbackConsent {
            onWarning?("Микрофон был выключен при отключении. Захват голоса приостановлен.")
        }
    }

    func enableFallbackMicrophone() {
        guard awaitingFallbackConsent, sources.contains(.microphone) else { return }
        awaitingFallbackConsent = false
        clearRetryableInputs()
        microphoneStatus = .waiting
        beginMicrophoneRecovery()
    }

    private func inventoryChanged(_ snapshot: MicrophoneDevicesSnapshot) {
        failedInputs = failedInputs.filter { uid, failure in
            snapshot.devices.contains { $0.uid == uid && $0.deviceID == failure.deviceID }
        }
        scheduleRouting()
    }

    private func beginMicrophoneRecovery(timeout: Duration = .seconds(5)) {
        guard sources.contains(.microphone), !awaitingFallbackConsent else { return }
        if !sources.contains(.systemAudio), recoveryDeadline == nil {
            let deadline = ContinuousClock.now + timeout
            recoveryDeadline = deadline
            recoveryTimeout = Task { [weak self] in
                do { try await Task.sleep(until: deadline) } catch { return }
                guard let self, self.microphone == nil, self.sources.contains(.microphone) else { return }
                self.routingTask?.cancel()
                self.ingress?.closeAdmission()
                self.onStopNeeded?("Не удалось восстановить микрофон. Записанный звук будет сохранён.")
            }
        }
        scheduleRouting()
    }

    private func scheduleRouting() {
        guard inventoryObservation != nil, sources.contains(.microphone), !awaitingFallbackConsent else { return }
        routingRequested = true
        guard routingTask == nil else { return }
        routingTask = Task { [weak self] in
            guard let self else { return }
            defer { self.routingTask = nil }
            while self.routingRequested, !Task.isCancelled {
                self.routingRequested = false
                await self.routeMicrophone()
            }
        }
    }

    private func routeMicrophone() async {
        guard let request = microphoneRequest, sources.contains(.microphone), !awaitingFallbackConsent else { return }
        let current = microphone
        if let current, let token = microphoneToken {
            do { _ = try devices.refreshFormat(of: current) }
            catch {
                microphoneLost(token, warning: error.localizedDescription)
                return
            }
        }
        guard current == nil || request.selection.allowsAutomaticFallback else { return }
        if let current, let token = microphoneToken {
            updateMute(current, token: token)
            // A priority promotion should not start recording voice while the
            // microphone the user is using is muted.
            if microphoneWasMuted { return }
        }
        var candidates = request.candidates(in: devices, keeping: current?.uid).filter {
            failedInputs[$0.uid]?.deviceID != $0.deviceID
        }
        guard let first = candidates.first else {
            scheduleRecoveryRetryIfNeeded(request)
            return
        }
        guard first.uid != current?.uid else { return }
        if let current {
            // If a priority upgrade fails, try the known working route next.
            if let index = candidates.firstIndex(where: { $0.uid == current.uid }) {
                candidates.insert(candidates.remove(at: index), at: 1)
            }
            stopMicrophone()
            microphoneStatus = .waiting
            beginMicrophoneRecovery(timeout: .seconds(9))
        }
        for candidate in candidates {
            let attemptDeadline = ContinuousClock.now + .seconds(4)
            let deadline = min(attemptDeadline, recoveryDeadline ?? attemptDeadline)
            guard !Task.isCancelled, ContinuousClock.now < deadline else { return }
            do {
                try await startMicrophone(candidate, deadline: deadline)
                recoveryDeadline = nil
                recoveryTimeout?.cancel()
                recoveryTimeout = nil
                recoveryRetry?.cancel()
                recoveryRetry = nil
                onWarning?("Запись продолжилась с микрофоном «\(candidate.name)». Возможен короткий пропуск голоса.")
                return
            } catch {
                stopMicrophone()
                if Task.isCancelled { return }
                if devices.snapshot.devices.contains(where: { $0.uid == candidate.uid && $0.deviceID == candidate.deviceID }) {
                    failedInputs[candidate.uid] = FailedInput(deviceID: candidate.deviceID)
                }
            }
        }
        scheduleRecoveryRetryIfNeeded(request)
    }

    private func scheduleRecoveryRetryIfNeeded(_ request: MicrophoneCaptureRequest) {
        // A device can remain enumerated while its input initializes. Retry
        // only while system audio is carrying the recording by itself.
        guard microphone == nil, sources.contains(.systemAudio), recoveryRetry == nil,
              !Task.isCancelled,
              devices.snapshot.candidates(for: request.selection).contains(where: {
                  failedInputs[$0.uid]?.physicalRouteChanged != true
              }) else { return }
        recoveryRetry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self else { return }
            self.recoveryRetry = nil
            guard self.microphone == nil, !self.awaitingFallbackConsent else { return }
            self.clearRetryableInputs()
            self.scheduleRouting()
        }
    }

    private func clearRetryableInputs() {
        failedInputs = failedInputs.filter { $0.value.physicalRouteChanged }
    }

    private func stopMicrophone() {
        if let microphoneToken { ingress?.suspendMicrophone(microphoneToken) }
        microphoneToken = nil
        microphoneMonitor?.cancel()
        microphoneMonitor = nil
        configurationTask?.cancel()
        configurationTask = nil
        inputObserver?.stop()
        inputObserver = nil
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        changeObserver = nil
        bluetoothMicrophone?.stop()
        bluetoothMicrophone = nil
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0) }
        tapInstalled = false
        engine?.stop()
        engine = nil
        microphone = nil
        expectedInput = nil
        restartTimes.removeAll()
        microphoneWasMuted = false
    }

    func stop() async throws -> Int64 {
        sources.removeAll()
        inventoryObservation?.cancel()
        inventoryObservation = nil
        routingRequested = false
        routingTask?.cancel()
        recoveryTimeout?.cancel()
        recoveryTimeout = nil
        recoveryRetry?.cancel()
        recoveryRetry = nil
        durationLimit?.cancel()
        durationLimit = nil
        ingress?.closeAdmission()
        stopMicrophone()
        await routingTask?.value
        if let systemCapture { await systemCapture.stop() }
        systemCapture = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        return try await ingress?.finish() ?? 0
    }

    func simulateConfigurationChangeForDiagnostics(stopEngine: Bool) {
        guard CommandLine.arguments.contains("--self-check-microphone"), let engine else { return }
        if stopEngine { engine.stop() }
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
    }
}

/// Callbacks borrow one of a fixed set of buffers. Admission and submission
/// share a lock with retirement, so accepted PCM is ahead of the close barrier.
final class CaptureIngress: @unchecked Sendable {
    private static let inputRates = 8_000.0...384_000.0
    private let queue = DispatchQueue(label: "LocalScribe.capture.writer", qos: .userInitiated)
    private let gate = NSLock()
    private var configuredSources: Set<CaptureAudioSource>?
    private var admitted: Set<CaptureAudioSource> = []
    private var retired: Set<CaptureAudioSource> = []
    private var admissionClosed = false
    private var microphoneToken: UUID?
    private var microphoneReady = false
    private var microphoneCallbackHostTime: UInt64?
    private var pressureReported = false
    private var pool: [AVAudioPCMBuffer] = []
    private var writer: TimedCaptureWriter?
    private var writerFailed = false
    private var writerSources: Set<CaptureAudioSource> = []
    private var microphoneMuted = false
    private var lastMeterUpdate: DispatchTime?
    private var meterPeak: Float = 0
    private var inputClipped = false
    private var lastSystemSignal: DispatchTime?
    private var lastLoudSignal = DispatchTime.now()
    private let meter: @Sendable (CaptureMeterReading) -> Void
    private let failure: @Sendable (String) -> Void
    private let pressure: @Sendable () -> Void

    init(meter: @escaping @Sendable (CaptureMeterReading) -> Void,
         failure: @escaping @Sendable (String) -> Void, pressure: @escaping @Sendable () -> Void) {
        self.meter = meter
        self.failure = failure
        self.pressure = pressure
    }

    func beginMicrophoneAttempt() -> UUID? {
        gate.withLock {
            guard !admissionClosed, !retired.contains(.microphone), microphoneToken == nil,
                  configuredSources?.contains(.microphone) != false else { return nil }
            let token = UUID()
            microphoneToken = token
            return token
        }
    }

    func lastMicrophoneCallbackHostTime(for token: UUID) -> UInt64? {
        gate.withLock { microphoneToken == token ? microphoneCallbackHostTime : nil }
    }

    func activateMicrophone(_ token: UUID) -> Bool {
        gate.withLock {
            guard !admissionClosed, microphoneToken == token, microphoneCallbackHostTime != nil,
                  configuredSources?.contains(.microphone) != false else { return false }
            microphoneReady = true
            if configuredSources != nil { admitted.insert(.microphone) }
            return true
        }
    }

    func suspendMicrophone(_ token: UUID) {
        gate.withLock {
            guard microphoneToken == token else { return }
            invalidateMicrophone()
            let wasAdmitted = admitted.remove(.microphone) != nil
            queue.async {
                do {
                    if wasAdmitted { try self.writer?.breakSourceSegment(.microphone) }
                    if self.microphoneMuted {
                        self.microphoneMuted = false
                        self.updateMeter(at: .now(), force: true)
                    }
                } catch { self.failWriter() }
            }
        }
    }

    func start(folder: URL, sources: Set<CaptureAudioSource>) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try Disk.directory(folder)
                    try Disk.requireSpace(1_200_000_000, at: folder)
                    // The format describes storage only. Each packet carries its actual rate.
                    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
                    let buffers = (0..<48).map { _ in
                        AVAudioPCMBuffer(pcmFormat: format, frameCapacity: MicrophoneCaptureWriter.bufferCapacity)!
                    }
                    self.writer = try TimedCaptureWriter(folder: folder, originHostTime: AudioGetCurrentHostTime(), sources: sources)
                    self.writerSources = sources
                    self.lastLoudSignal = .now()
                    self.gate.withLock {
                        self.configuredSources = sources
                        self.pool = buffers
                        if !self.admissionClosed {
                            self.admitted = sources.subtracting(self.retired)
                            if !self.microphoneReady { self.admitted.remove(.microphone) }
                        }
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func submitMicrophone(_ list: UnsafePointer<AudioBufferList>, format: AVAudioFormat, frameCount: Int, hostTime: UInt64, token: UUID) {
        let channelCount = Int(format.channelCount)
        let interleaved = format.isInterleaved
        let stream = format.streamDescription.pointee
        let floatSize = MemoryLayout<Float>.stride
        let channelsPerBuffer = interleaved ? channelCount : 1
        let frameStride = channelsPerBuffer * floatSize
        let (requiredBytes, overflow) = frameCount.multipliedReportingOverflow(by: frameStride)
        guard format.commonFormat == .pcmFormatFloat32, frameCount > 0, channelCount > 0, !overflow,
              stream.mFormatFlags & kAudioFormatFlagIsBigEndian == kAudioFormatFlagsNativeEndian,
              Int(stream.mBytesPerFrame) == frameStride else { return }

        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard buffers.count == (interleaved ? 1 : channelCount), buffers.allSatisfy({
            $0.mNumberChannels == channelsPerBuffer && $0.mData != nil && Int($0.mDataByteSize) >= requiredBytes
        }) else { return }

        submit(.microphone, count: frameCount, sampleRate: format.sampleRate, hostTime: hostTime, microphoneToken: token) { out, offset, frames in
            if channelCount == 1 {
                let samples = buffers[0].mData!.assumingMemoryBound(to: Float.self)
                out.update(from: samples + offset, count: frames)
                return
            }
            if interleaved {
                let samples = buffers[0].mData!.assumingMemoryBound(to: Float.self) + offset * channelCount
                for frame in 0..<frames {
                    var sum: Float = 0
                    for channel in 0..<channelCount { sum += samples[frame * channelCount + channel] }
                    out[frame] = sum / Float(channelCount)
                }
            } else {
                out.update(repeating: 0, count: frames)
                for channel in buffers {
                    let samples = channel.mData!.assumingMemoryBound(to: Float.self) + offset
                    for frame in 0..<frames { out[frame] += samples[frame] }
                }
                for frame in 0..<frames { out[frame] /= Float(channelCount) }
            }
        }
    }

    func submitSystemAudio(_ list: UnsafePointer<AudioBufferList>, format: AudioStreamBasicDescription, hostTime: UInt64) {
        guard format.mBytesPerFrame == MemoryLayout<Float>.stride else { return }
        submitMono(.systemAudio, list: list, sampleRate: format.mSampleRate, hostTime: hostTime)
    }

    func submitMono(_ source: CaptureAudioSource, list: UnsafePointer<AudioBufferList>, sampleRate: Double, hostTime: UInt64,
                    microphoneToken: UUID? = nil) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        let floatSize = MemoryLayout<Float>.stride
        guard buffers.count == 1, let buffer = buffers.first, buffer.mNumberChannels == 1,
              let data = buffer.mData,
              Int(buffer.mDataByteSize) % floatSize == 0 else { return }
        let samples = data.assumingMemoryBound(to: Float.self)
        submit(source, count: Int(buffer.mDataByteSize) / floatSize,
               sampleRate: sampleRate, hostTime: hostTime, microphoneToken: microphoneToken) { out, offset, frames in
            out.update(from: samples + offset, count: frames)
        }
    }

    private func submit(_ source: CaptureAudioSource, count: Int, sampleRate: Double, hostTime: UInt64,
                        microphoneToken: UUID?,
                        copy: (UnsafeMutablePointer<Float>, Int, Int) -> Void) {
        guard count > 0, hostTime != 0, Self.inputRates.contains(sampleRate) else { return }
        let capacity = Int(MicrophoneCaptureWriter.bufferCapacity)
        if count > capacity {
            let duration = AVAudioTime.hostTime(forSeconds: Double(count) / sampleRate)
            guard duration <= UInt64.max - hostTime else { return }
        }
        gate.lock()
        guard !admissionClosed else { gate.unlock(); return }
        if source == .microphone {
            guard let microphoneToken, self.microphoneToken == microphoneToken else { gate.unlock(); return }
            microphoneCallbackHostTime = AudioGetCurrentHostTime()
        }
        guard admitted.contains(source) else { gate.unlock(); return }
        for offset in stride(from: 0, to: count, by: capacity) {
            guard let buffer = pool.popLast() else {
                closeAdmissionLocked()
                gate.unlock()
                failure("Очередь записи переполнена. Завершённые фрагменты сохранены.")
                return
            }
            let frames = min(count - offset, capacity)
            let timestamp = offset == 0 ? hostTime : hostTime + AVAudioTime.hostTime(forSeconds: Double(offset) / sampleRate)
            buffer.frameLength = AVAudioFrameCount(frames)
            copy(buffer.floatChannelData![0], offset, frames)
            queue.async {
                defer { self.gate.withLock { self.pool.append(buffer) } }
                self.consume(buffer, source: source, sampleRate: sampleRate, hostTime: timestamp)
            }
        }
        let underPressure = pool.count < 36 && !pressureReported
        if underPressure { pressureReported = true }
        gate.unlock()
        if underPressure { pressure() }
    }

    private func consume(_ buffer: AVAudioPCMBuffer, source: CaptureAudioSource, sampleRate: Double, hostTime: UInt64) {
        guard let writer, !writerFailed else { return }
        do {
            try writer.append(buffer, source: source, hostTime: hostTime, sampleRate: sampleRate)
            let sourcePeak = MicrophoneCaptureWriter.peak(in: buffer)
            let now = DispatchTime.now()
            if sourcePeak.isFinite {
                meterPeak = max(meterPeak, sourcePeak)
                inputClipped = inputClipped || sourcePeak >= 0.99
                if sourcePeak >= 0.001 { lastLoudSignal = now }
                if source == .systemAudio, sourcePeak > 0 { lastSystemSignal = now }
            }
            updateMeter(at: now)
            if writer.reachedLimit, closeAdmission() {
                failure("Достигнут предел 3 часа. Запись сохранена.")
            }
        } catch { failWriter() }
    }

    private func updateMeter(at now: DispatchTime, force: Bool = false) {
        guard let writer else { return }
        if let lastMeterUpdate, !force, now < lastMeterUpdate + .milliseconds(100) { return }
        lastMeterUpdate = now
        let peak = meterPeak
        let clipped = inputClipped
        meterPeak = 0
        inputClipped = false
        let level = min(1, max(0, (20 * log10(Double(max(peak, 1e-6))) + 60) / 60))
        let notice: String?
        if writerSources.contains(.microphone), microphoneMuted { notice = "Микрофон выключен в macOS." }
        else if clipped { notice = "Слишком громкий звук" }
        else if writerSources.contains(.microphone), now >= lastLoudSignal + .seconds(15) {
            notice = "Звук почти не поступает"
        } else { notice = nil }
        let waiting = writerSources.contains(.systemAudio) && lastSystemSignal.map { now >= $0 + .seconds(2) } != false
        meter(CaptureMeterReading(level: level, elapsed: Double(writer.totalFrames) / MicrophoneCaptureWriter.sampleRate,
                                  soundNotice: notice, waitingForSystemAudio: waiting))
    }

    func setMicrophoneMuted(_ muted: Bool, token: UUID) {
        gate.withLock {
            guard microphoneToken == token else { return }
            queue.async {
                guard self.microphoneMuted != muted else { return }
                self.microphoneMuted = muted
                self.updateMeter(at: .now(), force: true)
            }
        }
    }

    func endSource(_ source: CaptureAudioSource) {
        gate.withLock {
            guard !admissionClosed, retired.insert(source).inserted else { return }
            if source == .microphone { invalidateMicrophone() }
            admitted.remove(source)
            queue.async {
                self.writerSources.remove(source)
                do {
                    try self.writer?.endSource(source)
                    self.updateMeter(at: .now(), force: true)
                } catch { self.failWriter() }
            }
        }
    }

    private func failWriter() {
        writerFailed = true
        if closeAdmission() {
            failure("Не удалось сохранить звук. Проверьте свободное место. Завершённые фрагменты сохранены.")
        }
    }

    @discardableResult func closeAdmission() -> Bool {
        gate.withLock { closeAdmissionLocked() }
    }

    // These helpers are called with gate held.
    private func invalidateMicrophone() {
        microphoneToken = nil
        microphoneReady = false
        microphoneCallbackHostTime = nil
    }

    @discardableResult private func closeAdmissionLocked() -> Bool {
        guard !admissionClosed else { return false }
        admissionClosed = true
        admitted.removeAll()
        invalidateMicrophone()
        return true
    }

    func finish() async throws -> Int64 {
        closeAdmission()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try self.writer?.close()
                    continuation.resume(returning: self.writer?.totalFrames ?? 0)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
