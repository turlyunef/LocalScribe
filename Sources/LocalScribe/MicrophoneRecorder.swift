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
    func setLiveCaptionAudio(_ input: LiveCaptionAudio?)
    func enableFallbackMicrophone()
    func stop() async throws -> Int64
}

extension RecordingCapture {
    func setLiveCaptionAudio(_ input: LiveCaptionAudio?) {}
}

@MainActor final class MicrophoneRecorder: RecordingCapture {
    private struct FailedInput {
        let deviceID: AudioDeviceID
        var physicalRouteChanged = false
    }

    @MainActor private final class InputSession {
        let token: UUID
        var engine: AVAudioEngine?
        var bluetooth: BluetoothMicrophoneCapture?
        var tapInstalled = false
        var restartTimes: [Date] = []

        init(token: UUID) { self.token = token }

        func stop() {
            bluetooth?.stop()
            if tapInstalled { engine?.inputNode.removeTap(onBus: 0) }
            engine?.stop()
        }
    }

    private let devices: MicrophoneDevices
    private var activeInput: InputSession?
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
    private var microphoneToken: UUID? { activeInput?.token }
    private var microphoneWasMuted = false
    private var awaitingFallbackConsent = false
    private var microphoneStatus: CaptureMicrophoneStatus? {
        didSet {
            if let microphoneStatus, microphoneStatus != oldValue { onMicrophoneStatus?(microphoneStatus) }
        }
    }
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

    isolated deinit {
        inventoryObservation?.cancel()
        routingTask?.cancel()
        recoveryTimeout?.cancel()
        recoveryRetry?.cancel()
        durationLimit?.cancel()
        ingress?.closeAdmission()
        stopMicrophone()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
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
            // Prepare admission before HAL can deliver the first system packet.
            // The first packet sets the origin, excluding time in the permission dialog.
            if systemAudio {
                try await ingress.start(folder: folder, sources: sources, originAtFirstPacket: true)
                try Task.checkCancellation()
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
            if let microphone { try await openInitialMicrophone(microphone) }
            if let startupFailure { throw ScribeError.message(startupFailure) }
            if !systemAudio { try await ingress.start(folder: folder, sources: sources) }
            try Task.checkCancellation()
            if let startupFailure { throw ScribeError.message(startupFailure) }
            if self.microphone == nil, !sources.contains(.systemAudio) {
                throw ScribeError.message("Микрофон стал недоступен при запуске записи.")
            }
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled], reason: L10n.text("Запись LocalScribe")
            )
            durationLimit = Task { [weak self] in
                // A packet-based limit also applies during mixed-source startup.
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

    private func openInitialMicrophone(_ request: MicrophoneCaptureRequest) async throws {
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
                try Task.checkCancellation()
                if (try? devices.refreshFormat(of: candidate)) != nil {
                    failedInputs[candidate.uid] = FailedInput(deviceID: candidate.deviceID)
                    lastError = error
                }
            }
        }
        guard sources.contains(.systemAudio) else {
            throw startupFailure.map(ScribeError.message) ?? lastError ?? ScribeError.message(request.selection.unavailableMessage)
        }
        microphoneStatus = .waiting
        onWarning?("Запись началась без микрофона. Системный звук продолжает записываться.")
    }

    private func startMicrophone(_ microphone: PinnedMicrophone, deadline: ContinuousClock.Instant) async throws {
        try Task.checkCancellation()
        let microphone = try devices.refreshFormat(of: microphone)
        guard let ingress, let token = ingress.beginMicrophoneAttempt(whileActive: activeInput != nil) else {
            throw CancellationError()
        }
        let session = InputSession(token: token)
        var promoted = false
        defer {
            if !promoted {
                ingress.suspendMicrophone(token)
                session.stop()
            }
        }
        if BluetoothMicrophoneCapture.supports(deviceID: microphone.deviceID) {
            // AirPods can expose 24 kHz through HAL while the engine input
            // bus still reports 48 kHz, even after the engine starts.
            let capture = BluetoothMicrophoneCapture(deviceID: microphone.deviceID)
            session.bluetooth = capture
            try capture.start { list, rate, time in
                ingress.submitMono(.microphone, list: list, sampleRate: rate, hostTime: time, microphoneToken: token)
            }
        } else {
            try startEngineMicrophone(microphone, ingress: ingress, session: session)
        }

        try await Self.waitForFirstMicrophonePacket(until: deadline, ingress: ingress, token: token) {
            session.engine?.isRunning != false
        } restart: {
            guard let engine = session.engine else { throw CancellationError() }
            let pinned = try self.devices.refreshFormat(of: microphone)
            _ = try self.restartEngineMicrophone(engine, microphone: pinned, ingress: ingress, session: session)
        }
        try Task.checkCancellation()
        guard sources.contains(.microphone), !awaitingFallbackConsent, !microphoneWasMuted else { throw CancellationError() }
        let negotiated = try devices.refreshFormat(of: microphone)
        if let engine = session.engine {
            _ = try validateEngineInput(for: negotiated, engine: engine)
        } else {
            try session.bluetooth?.updateFormat()
        }
        guard ingress.activateMicrophone(token) else { throw CancellationError() }
        stopMicrophone()
        activeInput = session
        promoted = true
        if let engine = session.engine {
            changeObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.scheduleConfigurationCheck(token) }
            }
        }
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
        if session.engine?.isRunning == false { scheduleConfigurationCheck(token) }
    }

    static func waitForFirstMicrophonePacket(
        until deadline: ContinuousClock.Instant,
        ingress: CaptureIngress, token: UUID,
        isEngineRunning: () throws -> Bool,
        restart: () throws -> Void
    ) async throws {
        var stoppedSince: ContinuousClock.Instant?
        while true {
            try Task.checkCancellation()
            let now = ContinuousClock.now
            guard now < deadline else {
                throw ScribeError.message("Выбранный микрофон не передал аудиоданные при запуске.")
            }
            if try isEngineRunning() {
                if ingress.lastMicrophoneCallbackHostTime(for: token) != nil { return } // Silence is valid PCM.
                stoppedSince = nil
            } else if let since = stoppedSince {
                if since.duration(to: now) >= .milliseconds(100) {
                    try restart()
                    stoppedSince = nil
                }
            } else {
                // Core Audio can stop the engine during startup, before the
                // active-route observer is installed. Let HAL settle first.
                stoppedSince = now
            }
            try await Task.sleep(until: min(deadline, now + .milliseconds(40)))
        }
    }

    private func startEngineMicrophone(_ microphone: PinnedMicrophone, ingress: CaptureIngress, session: InputSession) throws {
        let engine = AVAudioEngine()
        session.engine = engine
        let input = engine.inputNode
        var deviceID = microphone.deviceID
        guard let unit = input.audioUnit,
              AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                   &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
            throw ScribeError.message("Не удалось закрепить выбранный микрофон.")
        }
        let hardware = input.inputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0,
              let configuration = currentInput(engine), configuration.deviceID == microphone.deviceID,
              supportsMicrophone(configuration) else {
            throw ScribeError.message("Выбранный микрофон недоступен или имеет неподдерживаемый формат.")
        }
        try installMicrophoneTap(input, sampleRate: configuration.sampleRate, ingress: ingress, session: session)
        engine.prepare()
        try engine.start()
    }

    private func installMicrophoneTap(_ input: AVAudioInputNode, sampleRate: Double, ingress: CaptureIngress, session: InputSession) throws {
        let token = session.token
        guard let tap = ingress.replaceMicrophoneTap(token) else { throw CancellationError() }
        // Passing a preflight format to the tap can throw an Objective-C
        // exception if Bluetooth changes rate during device activation.
        if #available(macOS 27.0, *) {
            let frames = AVAudioFrameCount(min(8192, max(512, (sampleRate / 5).rounded(.up))))
            try input.installAudioTap(onBus: 0, bufferSize: frames, format: nil) { buffer, time in
                guard time.isHostTimeValid else { return }
                buffer.withUnsafeAudioBufferList { list in
                    ingress.submitMicrophone(list, format: buffer.format, frameCount: buffer.frameLength, hostTime: time.hostTime, token: token, tap: tap)
                }
            }
        } else {
            input.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, time in
                guard time.isHostTimeValid else { return }
                ingress.submitMicrophone(buffer.audioBufferList, format: buffer.format,
                                         frameCount: Int(buffer.frameLength), hostTime: time.hostTime, token: token, tap: tap)
            }
        }
        session.tapInstalled = true
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

    private func currentInput(_ engine: AVAudioEngine) -> CaptureInputConfiguration? {
        guard let unit = engine.inputNode.audioUnit else { return nil }
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
        guard let session = activeInput, session.token == token, let microphone else { return }
        let negotiated: PinnedMicrophone
        do {
            negotiated = try devices.refreshFormat(of: microphone)
            try session.bluetooth?.updateFormat()
        } catch {
            microphoneLost(token, warning: error.localizedDescription)
            return
        }
        if negotiated != microphone { observeInput(negotiated, token: token) }
        self.microphone = negotiated
        updateMute(negotiated, token: token)
        if !microphoneWasMuted { scheduleRouting() }
        guard let engine = session.engine, let ingress else { return }
        guard let current = currentInput(engine), supportsMicrophone(current) else {
            microphoneLost(token, warning: "Выбранный микрофон стал недоступен.")
            return
        }
        guard current.deviceID == negotiated.deviceID else {
            microphoneLost(token, warning: "Вход или формат выбранного микрофона изменился.")
            return
        }
        guard !engine.isRunning else { return }

        do {
            let updated = try restartEngineMicrophone(engine, microphone: negotiated, ingress: ingress, session: session)
            if updated != negotiated { observeInput(updated, token: token) }
            self.microphone = updated
            onWarning?("Аудиодвижок перезапущен с прежним микрофоном; возможен короткий пропуск звука.")
        } catch {
            microphoneLost(token, warning: error.localizedDescription)
        }
    }

    private func validateEngineInput(for microphone: PinnedMicrophone, engine: AVAudioEngine) throws -> CaptureInputConfiguration {
        guard let current = currentInput(engine), current.deviceID == microphone.deviceID,
              supportsMicrophone(current) else {
            throw ScribeError.message("Вход или формат выбранного микрофона изменился.")
        }
        return current
    }

    private func restartEngineMicrophone(_ engine: AVAudioEngine, microphone: PinnedMicrophone,
                                         ingress: CaptureIngress, session: InputSession) throws -> PinnedMicrophone {
        let now = Date()
        session.restartTimes.removeAll { now.timeIntervalSince($0) > 5 }
        guard session.restartTimes.count < 3 else {
            throw ScribeError.message("Аудиодвижок микрофона нестабилен.")
        }
        session.restartTimes.append(now)
        let current = try validateEngineInput(for: microphone, engine: engine)
        do {
            // Reinstall even with the same format. A callback already in
            // flight belongs to the old tap and cannot confirm this restart.
            if session.tapInstalled { engine.inputNode.removeTap(onBus: 0) }
            session.tapInstalled = false
            try installMicrophoneTap(engine.inputNode, sampleRate: current.sampleRate, ingress: ingress, session: session)
            try engine.start()
        } catch {
            throw ScribeError.message("Не удалось возобновить аудиодвижок микрофона.")
        }
        let updated = try devices.refreshFormat(of: microphone)
        _ = try validateEngineInput(for: updated, engine: engine)
        engineRestartCount += 1
        return updated
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
        let candidates = request.candidates(in: devices, keeping: current?.uid).filter {
            failedInputs[$0.uid]?.deviceID != $0.deviceID
        }
        guard let first = candidates.first else {
            scheduleRecoveryRetryIfNeeded(request)
            return
        }
        guard first.uid != current?.uid else { return }
        for candidate in candidates {
            // The current input continues to supply PCM until a higher-priority
            // input has opened, supplied a packet and been atomically admitted.
            if candidate.uid == microphone?.uid { return }
            if awaitingFallbackConsent || microphoneWasMuted { return }
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
                if Task.isCancelled || error is CancellationError { return }
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
        microphoneMonitor?.cancel()
        microphoneMonitor = nil
        configurationTask?.cancel()
        configurationTask = nil
        inputObserver?.stop()
        inputObserver = nil
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        changeObserver = nil
        activeInput?.stop()
        activeInput = nil
        microphone = nil
        microphoneWasMuted = false
    }

    func setLiveCaptionAudio(_ input: LiveCaptionAudio?) {
        ingress?.setLiveCaptionAudio(input)
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
        guard CommandLine.arguments.contains("--self-check-microphone"), let engine = activeInput?.engine else { return }
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
    private struct MicrophoneStream {
        let token = UUID()
        var tap: UUID?
        var lastCallback: UInt64?
    }
    private var pendingMicrophone: MicrophoneStream?
    private var activeMicrophone: MicrophoneStream?
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

    func beginMicrophoneAttempt(whileActive: Bool = false) -> UUID? {
        gate.withLock {
            guard !admissionClosed, !retired.contains(.microphone), pendingMicrophone == nil,
                  whileActive || activeMicrophone == nil,
                  configuredSources?.contains(.microphone) != false else { return nil }
            let stream = MicrophoneStream()
            pendingMicrophone = stream
            return stream.token
        }
    }

    func lastMicrophoneCallbackHostTime(for token: UUID) -> UInt64? {
        gate.withLock {
            if activeMicrophone?.token == token { return activeMicrophone?.lastCallback }
            if pendingMicrophone?.token == token { return pendingMicrophone?.lastCallback }
            return nil
        }
    }

    func replaceMicrophoneTap(_ token: UUID) -> UUID? {
        gate.withLock {
            let tap = UUID()
            if pendingMicrophone?.token == token {
                pendingMicrophone?.tap = tap
                pendingMicrophone?.lastCallback = nil
            } else if activeMicrophone?.token == token {
                activeMicrophone?.tap = tap
                endMicrophoneSegment()
            } else {
                return nil
            }
            return tap
        }
    }

    func activateMicrophone(_ token: UUID) -> Bool {
        gate.withLock {
            guard !admissionClosed, let pendingMicrophone, pendingMicrophone.token == token,
                  pendingMicrophone.lastCallback != nil,
                  configuredSources?.contains(.microphone) != false else { return false }
            if activeMicrophone != nil { endMicrophoneSegment() }
            activeMicrophone = pendingMicrophone
            self.pendingMicrophone = nil
            if configuredSources != nil { admitted.insert(.microphone) }
            return true
        }
    }

    func suspendMicrophone(_ token: UUID) {
        gate.withLock {
            if pendingMicrophone?.token == token {
                pendingMicrophone = nil
                if activeMicrophone == nil { endMicrophoneSegment() }
            }
            if activeMicrophone?.token == token {
                activeMicrophone = nil
                admitted.remove(.microphone)
                endMicrophoneSegment()
            }
        }
    }

    // Caller holds the gate so this barrier runs between old and new PCM.
    private func endMicrophoneSegment() {
        queue.async {
            do {
                try self.writer?.breakSourceSegment(.microphone)
                if self.microphoneMuted {
                    self.microphoneMuted = false
                    self.updateMeter(at: .now(), force: true)
                }
            } catch { self.failWriter() }
        }
    }

    func start(folder: URL, sources: Set<CaptureAudioSource>, originAtFirstPacket: Bool = false) async throws {
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
                    self.writer = try TimedCaptureWriter(folder: folder,
                                                        originHostTime: originAtFirstPacket ? nil : AudioGetCurrentHostTime(),
                                                        sources: sources)
                    self.writerSources = sources
                    self.lastLoudSignal = .now()
                    self.gate.withLock {
                        self.configuredSources = sources
                        self.pool = buffers
                        if !self.admissionClosed {
                            self.admitted = sources.subtracting(self.retired)
                            if self.activeMicrophone == nil { self.admitted.remove(.microphone) }
                        }
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func submitMicrophone(_ list: UnsafePointer<AudioBufferList>, format: AVAudioFormat, frameCount: Int,
                          hostTime: UInt64, token: UUID, tap: UUID? = nil) {
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

        submit(.microphone, count: frameCount, sampleRate: format.sampleRate, hostTime: hostTime, microphoneToken: token, tap: tap) { out, offset, frames in
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
                        microphoneToken: UUID?, tap: UUID? = nil,
                        copy: (UnsafeMutablePointer<Float>, Int, Int) -> Void) {
        guard count > 0, hostTime != 0, Self.inputRates.contains(sampleRate) else { return }
        let capacity = Int(MicrophoneCaptureWriter.bufferCapacity)
        let received = AudioGetCurrentHostTime()
        let duration = AVAudioTime.hostTime(forSeconds: Double(count) / sampleRate)
        // A driver timestamp far ahead of the host clock must not make the
        // writer materialize the difference as silence.
        guard hostTime <= received || hostTime - received <= AVAudioTime.hostTime(forSeconds: 2),
              duration <= UInt64.max - hostTime else { return }
        gate.lock()
        guard !admissionClosed else { gate.unlock(); return }
        if source == .microphone {
            guard let microphoneToken else { gate.unlock(); return }
            if pendingMicrophone?.token == microphoneToken, pendingMicrophone?.tap == tap {
                pendingMicrophone?.lastCallback = received
                gate.unlock()
                return
            }
            guard activeMicrophone?.token == microphoneToken, activeMicrophone?.tap == tap else { gate.unlock(); return }
            activeMicrophone?.lastCallback = received
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
            guard activeMicrophone?.token == token ||
                    (activeMicrophone == nil && pendingMicrophone?.token == token) else { return }
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
        activeMicrophone = nil
        pendingMicrophone = nil
    }

    @discardableResult private func closeAdmissionLocked() -> Bool {
        guard !admissionClosed else { return false }
        admissionClosed = true
        admitted.removeAll()
        invalidateMicrophone()
        return true
    }

    func setLiveCaptionAudio(_ input: LiveCaptionAudio?) {
        queue.async { self.writer?.liveCaptionAudio = input }
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
