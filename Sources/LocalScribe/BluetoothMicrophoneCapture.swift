import CoreAudio
import LocalScribeCore
import Synchronization

/// Reads input-only Bluetooth devices directly from HAL. Their negotiated input
/// rate can differ from the client format held by AVAudioEngine's input node.
@MainActor final class BluetoothMicrophoneCapture {
    private final class CallbackState: Sendable {
        // A zero rate keeps the callback closed before negotiation and during teardown.
        let rate = Atomic<UInt64>(0)
    }

    private struct Session {
        let proc: AudioDeviceIOProcID
        let callback: CallbackState
    }

    private let deviceID: AudioDeviceID
    private var session: Session?

    init(deviceID: AudioDeviceID) {
        self.deviceID = deviceID
    }

    isolated deinit { stop() }

    static func supports(deviceID: AudioDeviceID) -> Bool {
        inputStream(for: deviceID) != nil
    }

    func start(deliver: @escaping @Sendable (UnsafePointer<AudioBufferList>, Double, UInt64) -> Void) throws {
        guard session == nil else { return }
        guard Self.supports(deviceID: deviceID) else {
            throw ScribeError.message("Выбранный микрофон недоступен или имеет неподдерживаемый формат.")
        }
        let callback = CallbackState()
        let deviceID = self.deviceID
        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, deviceID, nil) { @Sendable _, input, inputTime, _, _ in
            let rate = Double(bitPattern: callback.rate.load(ordering: .acquiring))
            guard rate > 0, input.pointee.mNumberBuffers == 1 else { return }
            let buffer = input.pointee.mBuffers
            let time = inputTime.pointee
            guard buffer.mNumberChannels == 1, buffer.mData != nil, buffer.mDataByteSize > 0,
                  buffer.mDataByteSize % UInt32(MemoryLayout<Float>.stride) == 0,
                  time.mFlags.contains(.hostTimeValid), time.mHostTime != 0 else { return }
            deliver(input, rate, time.mHostTime)
        }
        if status != noErr, let proc { _ = AudioDeviceDestroyIOProcID(deviceID, proc) }
        try Self.check(status)
        guard let proc else { throw ScribeError.message("Не удалось запустить микрофон Bluetooth.") }

        var didStart = false
        defer {
            if session == nil {
                if didStart { _ = AudioDeviceStop(deviceID, proc) }
                _ = AudioDeviceDestroyIOProcID(deviceID, proc)
            }
        }
        try Self.check(AudioDeviceStart(deviceID, proc))
        didStart = true
        let rate = try sampleRate()
        session = Session(proc: proc, callback: callback)
        callback.rate.store(rate.bitPattern, ordering: .releasing)
    }

    func updateFormat() throws {
        guard let session else { return }
        do {
            let rate = try sampleRate()
            session.callback.rate.store(rate.bitPattern, ordering: .releasing)
        } catch {
            session.callback.rate.store(0, ordering: .releasing)
            throw error
        }
    }

    func stop() {
        guard let session else { return }
        self.session = nil
        session.callback.rate.store(0, ordering: .releasing)
        _ = AudioDeviceStop(deviceID, session.proc)
        _ = AudioDeviceDestroyIOProcID(deviceID, session.proc)
    }

    private func sampleRate() throws -> Double {
        let packedFloat = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        let floatSize = UInt32(MemoryLayout<Float>.stride)
        guard let stream = Self.inputStream(for: deviceID),
              let format = HALInput.format(HALInput.globalProperty(stream, kAudioStreamPropertyVirtualFormat)),
              (8_000...384_000).contains(format.rate), format.id == kAudioFormatLinearPCM,
              format.flags & packedFloat == packedFloat,
              format.flags & kAudioFormatFlagIsBigEndian == kAudioFormatFlagsNativeEndian,
              format.channels == 1, format.bitsPerChannel == 32, format.framesPerPacket == 1,
              format.bytesPerFrame == floatSize, format.bytesPerPacket == floatSize else {
            throw ScribeError.message("Выбранный микрофон недоступен или имеет неподдерживаемый формат.")
        }
        return format.rate
    }

    private static func inputStream(for device: AudioDeviceID) -> AudioStreamID? {
        let transport = HALInput.scalar(HALInput.globalProperty(device, kAudioDevicePropertyTransportType), initial: UInt32(0))
        guard transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE,
              let inputs = HALInput.uint32Values(HALInput.inputProperty(device, kAudioDevicePropertyStreams)),
              inputs.count == 1 else { return nil }
        let output = HALInput.Property(object: device, selector: kAudioDevicePropertyStreams,
                                       scope: kAudioObjectPropertyScopeOutput, element: kAudioObjectPropertyElementMain)
        guard HALInput.uint32Values(output)?.isEmpty == true else { return nil }
        return inputs[0]
    }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else {
            throw ScribeError.message("Не удалось запустить микрофон Bluetooth (Core Audio \(status)).")
        }
    }
}
