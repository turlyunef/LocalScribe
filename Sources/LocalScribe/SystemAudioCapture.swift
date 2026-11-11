import CoreAudio
import Foundation
import LocalScribeCore
import Synchronization

/// Owns a device-independent process tap. The HAL callback only validates the
/// buffer and forwards it synchronously to the recorder's bounded pool.
final class SystemAudioCapture: @unchecked Sendable {
    typealias AudioCallback = @Sendable (
        UnsafePointer<AudioBufferList>, AudioStreamBasicDescription, UInt64, Double?
    ) -> Void
    typealias LossCallback = @Sendable (String) -> Void

    private final class StartRequest: Sendable {
        private struct State {
            var cancelled = false
            var continuation: CheckedContinuation<Void, Error>?
        }

        private let state = Mutex(State())

        var isCancelled: Bool { state.withLock { $0.cancelled } }

        func install(_ continuation: CheckedContinuation<Void, Error>) -> Bool {
            let installed = state.withLock { state in
                guard !state.cancelled else { return false }
                state.continuation = continuation
                return true
            }
            if !installed { continuation.resume(throwing: CancellationError()) }
            return installed
        }

        func finish(_ result: Result<Void, Error>) -> Bool {
            let continuation = state.withLock { state in
                let continuation = state.continuation
                state.continuation = nil
                return continuation
            }
            continuation?.resume(with: result)
            return continuation != nil
        }

        func cancel() {
            let continuation = state.withLock { state in
                state.cancelled = true
                let continuation = state.continuation
                state.continuation = nil
                return continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    private final class Stream: Sendable {
        let enabled = Atomic(false)
        let buffers = Atomic<UInt64>(0)
    }

    // Apart from the atomic callback state, a session is confined to controlQueue.
    private final class Session: @unchecked Sendable {
        let request: StartRequest
        let onAudio: AudioCallback
        let onLoss: LossCallback
        var tap = AudioObjectID(kAudioObjectUnknown)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var proc: AudioDeviceIOProcID?
        var stream: Stream?
        var format = AudioStreamBasicDescription()
        var formatListener: AudioObjectPropertyListenerBlock?
        var monitor: DispatchSourceTimer?
        var lastBufferCount: UInt64 = 0
        var lastProgress = DispatchTime.now()
        var triedRecovery = false

        init(request: StartRequest, onAudio: @escaping AudioCallback, onLoss: @escaping LossCallback) {
            self.request = request
            self.onAudio = onAudio
            self.onLoss = onLoss
        }
    }

    // A cancelled request can still be waiting inside HAL. Serialize starts
    // across recorder instances until the abandoned request has cleaned up.
    private static let controlQueue = DispatchQueue(label: "LocalScribe.system-audio.hal", qos: .userInitiated)
    private var session: Session?

    func start(onAudio: @escaping AudioCallback, onLoss: @escaping LossCallback) async throws {
        let request = StartRequest()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard request.install(continuation) else { return }
                Self.controlQueue.async {
                    do {
                        let session = try self.begin(request: request, onAudio: onAudio, onLoss: onLoss)
                        if request.finish(.success(())) {
                            session.stream?.enabled.store(true, ordering: .releasing)
                        } else {
                            self.end()
                        }
                    } catch {
                        _ = request.finish(.failure(error))
                    }
                }
            }
        } onCancel: {
            // AudioDeviceStart may wait for the system permission prompt. Let
            // the caller cancel immediately while the HAL queue owns cleanup.
            request.cancel()
            Self.controlQueue.async {
                if self.session?.request === request { self.end() }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            Self.controlQueue.async {
                self.end()
                continuation.resume()
            }
        }
    }

    deinit {
        if let session {
            Self.controlQueue.async {
                session.monitor?.cancel()
                Self.destroyResources(session, listenerQueue: Self.controlQueue)
            }
        }
    }

    private func begin(
        request: StartRequest, onAudio: @escaping AudioCallback, onLoss: @escaping LossCallback
    ) throws -> Session {
        guard !request.isCancelled else { throw CancellationError() }
        guard session == nil else {
            throw ScribeError.message("Захват системного звука уже запущен.")
        }
        let session = Session(request: request, onAudio: onAudio, onLoss: onLoss)
        do {
            try createResources(session)
            guard !request.isCancelled else { throw CancellationError() }
        } catch {
            Self.destroyResources(session, listenerQueue: Self.controlQueue)
            throw error
        }
        self.session = session
        let monitor = DispatchSource.makeTimerSource(queue: Self.controlQueue)
        monitor.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1), leeway: .milliseconds(100))
        monitor.setEventHandler { [weak self, weak session] in
            guard let self, let session, self.session === session else { return }
            self.checkStream(session)
        }
        session.monitor = monitor
        monitor.activate()
        return session
    }

    private func end() {
        guard let session else { return }
        self.session = nil
        session.monitor?.cancel()
        session.monitor = nil
        Self.destroyResources(session, listenerQueue: Self.controlQueue)
    }

    private func createResources(_ session: Session) throws {
        guard !session.request.isCancelled else { throw CancellationError() }
        var address = Self.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = getpid()
        var process = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try Self.check(AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &process
        ))
        guard process != kAudioObjectUnknown else {
            throw ScribeError.message("Не удалось исключить звук LocalScribe из системной записи.")
        }

        let description = CATapDescription(monoGlobalTapButExcludeProcesses: [process])
        description.name = "LocalScribe System Audio"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try Self.check(AudioHardwareCreateProcessTap(description, &session.tap))

        guard let uid = try Self.read(session.tap, kAudioTapPropertyUID, initial: nil as Unmanaged<CFString>?) else {
            throw ScribeError.message("Не удалось запустить захват системного звука.")
        }
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "LocalScribe System Audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: 1,
            // HAL can wait for playback with TapAutoStart. Start in silence too.
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: uid.takeRetainedValue() as String,
                kAudioSubTapDriftCompensationKey: 1
            ]]
        ]
        try Self.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &session.device))
        let format = try Self.inputFormat(session.device)
        try configureStream(session, format: format)
        guard !session.request.isCancelled else { throw CancellationError() }

        var formatAddress = Self.address(kAudioDevicePropertyStreamFormat, scope: kAudioObjectPropertyScopeInput)
        let listener: AudioObjectPropertyListenerBlock = { [weak self, weak session] _, _ in
            guard let self, let session, self.session === session else { return }
            self.checkStream(session)
        }
        if AudioObjectAddPropertyListenerBlock(session.device, &formatAddress, Self.controlQueue, listener) == noErr {
            session.formatListener = listener
        }
    }

    private func configureStream(_ session: Session, format: AudioStreamBasicDescription) throws {
        guard !session.request.isCancelled else { throw CancellationError() }
        guard Self.supports(format) else {
            throw ScribeError.message("Формат системного звука не поддерживается.")
        }
        Self.destroyStream(session)
        let stream = Stream()
        let onAudio = session.onAudio
        try Self.check(AudioDeviceCreateIOProcIDWithBlock(&session.proc, session.device, nil) {
            _, input, inputTime, _, _ in
            guard stream.enabled.load(ordering: .acquiring),
                  input.pointee.mNumberBuffers == 1 else { return }
            let buffer = input.pointee.mBuffers
            guard buffer.mNumberChannels == 1, buffer.mData != nil, buffer.mDataByteSize > 0,
                  buffer.mDataByteSize % format.mBytesPerFrame == 0 else { return }
            let time = inputTime.pointee
            guard time.mFlags.contains(.hostTimeValid), time.mHostTime != 0 else { return }
            let sampleTime = time.mFlags.contains(.sampleTimeValid) && time.mSampleTime.isFinite
                ? time.mSampleTime : nil
            _ = stream.buffers.wrappingAdd(1, ordering: .relaxed)
            onAudio(input, format, time.mHostTime, sampleTime)
        })
        guard let proc = session.proc else {
            throw ScribeError.message("Не удалось запустить захват системного звука.")
        }
        session.stream = stream
        session.format = format
        session.lastBufferCount = 0
        session.lastProgress = .now()
        guard !session.request.isCancelled else { throw CancellationError() }
        try Self.check(AudioDeviceStart(session.device, proc))
    }

    private func checkStream(_ session: Session) {
        let alive = (try? Self.read(session.device, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0))) == 1
        let running = (try? Self.read(session.device, kAudioDevicePropertyDeviceIsRunning, initial: UInt32(0))) == 1
        if alive, running, let stream = session.stream,
           let format = try? Self.inputFormat(session.device), Self.supports(format) {
            if format.mSampleRate != session.format.mSampleRate || format.mFormatFlags != session.format.mFormatFlags {
                do {
                    try configureStream(session, format: format)
                    session.stream?.enabled.store(true, ordering: .releasing)
                } catch {
                    recover(session)
                }
                return
            }
            let count = stream.buffers.load(ordering: .relaxed)
            if count != session.lastBufferCount {
                session.lastBufferCount = count
                session.lastProgress = .now()
                session.triedRecovery = false
                return
            }
        }
        // This measures transport only. An idle or privacy-silenced tap can
        // legitimately supply zero-valued samples with normal callback timing.
        if DispatchTime.now() >= session.lastProgress + .seconds(3) {
            recover(session)
        }
    }

    private func recover(_ session: Session) {
        if !session.triedRecovery {
            session.triedRecovery = true
            Self.destroyResources(session, listenerQueue: Self.controlQueue)
            do {
                try createResources(session)
                session.stream?.enabled.store(true, ordering: .releasing)
                return
            } catch {}
        }
        end()
        session.onLoss("Поток системного звука прервался.")
    }

    private static func destroyResources(_ session: Session, listenerQueue: DispatchQueue) {
        if let listener = session.formatListener {
            var address = address(kAudioDevicePropertyStreamFormat, scope: kAudioObjectPropertyScopeInput)
            _ = AudioObjectRemovePropertyListenerBlock(session.device, &address, listenerQueue, listener)
            session.formatListener = nil
        }
        destroyStream(session)
        if session.device != kAudioObjectUnknown {
            _ = AudioHardwareDestroyAggregateDevice(session.device)
            session.device = kAudioObjectUnknown
        }
        if session.tap != kAudioObjectUnknown {
            _ = AudioHardwareDestroyProcessTap(session.tap)
            session.tap = kAudioObjectUnknown
        }
    }

    private static func destroyStream(_ session: Session) {
        session.stream?.enabled.store(false, ordering: .releasing)
        if let proc = session.proc {
            _ = AudioDeviceStop(session.device, proc)
            _ = AudioDeviceDestroyIOProcID(session.device, proc)
            session.proc = nil
        }
        session.stream = nil
    }

    private static func inputFormat(_ device: AudioDeviceID) throws -> AudioStreamBasicDescription {
        try read(device, kAudioDevicePropertyStreamFormat, scope: kAudioObjectPropertyScopeInput,
                 initial: AudioStreamBasicDescription())
    }

    private static func supports(_ format: AudioStreamBasicDescription) -> Bool {
        let packedFloat = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        return format.mSampleRate.isFinite && format.mSampleRate > 0
            && format.mFormatID == kAudioFormatLinearPCM && format.mChannelsPerFrame == 1
            && format.mBitsPerChannel == 32 && format.mBytesPerFrame == 4
            && format.mFramesPerPacket == 1 && format.mFormatFlags & packedFloat == packedFloat
            && format.mFormatFlags & kAudioFormatFlagIsBigEndian == kAudioFormatFlagsNativeEndian
    }

    private static func address(
        _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func read<Value>(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, initial: Value
    ) throws -> Value {
        var value = initial
        var address = address(selector, scope: scope)
        try withUnsafeMutableBytes(of: &value) { buffer in
            var size = UInt32(buffer.count)
            try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, buffer.baseAddress!))
        }
        return value
    }

    private static func check(_ status: OSStatus) throws {
        guard status != noErr else { return }
        throw ScribeError.message("Не удалось запустить захват системного звука (Core Audio \(status)).")
    }
}
