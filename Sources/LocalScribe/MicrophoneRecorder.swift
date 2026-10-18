import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import LocalScribeCore

/// A fixed pool bounds callback memory. All file operations run on writerQueue.
final class MicrophoneRecorder {
    private let engine = AVAudioEngine()
    private let writerQueue = DispatchQueue(label: "LocalScribe.capture.writer", qos: .userInitiated)
    private let poolLock = NSLock()
    private var pool: [AVAudioPCMBuffer] = []
    private var stopped = false
    private var captureWriter: MicrophoneCaptureWriter?
    private var format: AVAudioFormat!
    private var activity: NSObjectProtocol?
    private var changeObserver: NSObjectProtocol?
    @MainActor private var configurationTask: Task<Void, Never>?
    @MainActor private var expectedInput: CaptureInputConfiguration?
    @MainActor private var isCapturing = false
    @MainActor private var restartTimes: [Date] = []
    @MainActor private(set) var configurationEventCount = 0
    @MainActor private(set) var engineRestartCount = 0
    private var tapInstalled = false
    private var lastMeter: Int64 = 0
    private var quietFrames: Int64 = 0
    var onMeter: ((Double, Double, String?) -> Void)?
    var onStopNeeded: ((String) -> Void)?
    var onWarning: ((String) -> Void)?
    var onResourcePressure: (() -> Void)?
    private var resourcePressureReported = false
    private var requestedStop = false
    private var deviceID = AudioDeviceID(0)

    private func builtInInput() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { throw ScribeError.message("Не удалось получить список микрофонов") }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size)/MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { throw ScribeError.message("Не удалось прочитать микрофоны") }
        for device in devices {
            var transport = UInt32(0), n = UInt32(MemoryLayout<UInt32>.size)
            var property = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(device, &property, 0, nil, &n, &transport) == noErr, transport == kAudioDeviceTransportTypeBuiltIn else { continue }
            property.mSelector = kAudioDevicePropertyStreams; property.mScope = kAudioDevicePropertyScopeInput
            n = 0
            if AudioObjectGetPropertyDataSize(device, &property, 0, nil, &n) == noErr, n > 0 { return device }
        }
        throw ScribeError.message("Встроенный микрофон не найден. Внешние устройства автоматически не используются.")
    }
    @MainActor func start(folder: URL) throws {
        try Disk.directory(folder)
        try Disk.requireSpace(5_000_000_000, at: folder)
        deviceID = try builtInInput()
        let input = engine.inputNode
        guard let unit = input.audioUnit, AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else { throw ScribeError.message("Не удалось выбрать встроенный микрофон") }
        let native = input.outputFormat(forBus: 0)
        guard native.sampleRate > 0, native.channelCount > 0 else { throw ScribeError.message("Микрофон недоступен") }
        expectedInput = configuration(device:deviceID,format:native)
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: native.sampleRate, channels: 1, interleaved: false)!
        pool = (0..<32).map { _ in AVAudioPCMBuffer(pcmFormat: format, frameCapacity: MicrophoneCaptureWriter.bufferCapacity)! }
        captureWriter = try MicrophoneCaptureWriter(folder: folder, format: format)
        input.installTap(onBus: 0, bufferSize: 1024, format: native) { [weak self] buffer, _ in self?.enqueue(buffer) }
        tapInstalled = true
        changeObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            // Never inspect or tear down the engine on its internal notification queue.
            Task { @MainActor [weak self] in self?.scheduleConfigurationCheck() }
        }
        do {
            engine.prepare(); try engine.start(); isCapturing = true
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Запись LocalScribe")
        } catch {
            poolLock.withLock { stopped = true }
            if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }; changeObserver = nil
            engine.inputNode.removeTap(onBus:0); tapInstalled = false; engine.stop()
            writerQueue.sync { try? captureWriter?.close() }
            throw error
        }
    }
    @MainActor private func configuration(device: AudioDeviceID, format: AVAudioFormat) -> CaptureInputConfiguration {
        let stream = format.streamDescription.pointee
        return CaptureInputConfiguration(deviceID:device,sampleRate:stream.mSampleRate,channels:stream.mChannelsPerFrame,formatID:stream.mFormatID,formatFlags:stream.mFormatFlags)
    }
    @MainActor private func currentInput() -> CaptureInputConfiguration? {
        guard let unit = engine.inputNode.audioUnit else { return nil }
        var current = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(unit,kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,0,&current,&size) == noErr else { return nil }
        return configuration(device:current,format:engine.inputNode.outputFormat(forBus:0))
    }
    @MainActor private func scheduleConfigurationCheck() {
        guard isCapturing else { return }
        configurationEventCount += 1
        configurationTask?.cancel()
        configurationTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for:.milliseconds(100)) } catch { return }
            guard let self, self.isCapturing, !self.poolLock.withLock({ self.stopped }), let expected = self.expectedInput else { return }
            switch CaptureConfigurationAction.evaluate(expected:expected,current:self.currentInput(),engineRunning:self.engine.isRunning) {
            case .keepRecording: break
            case .inputUnavailable:
                self.requestStop("Встроенный микрофон стал недоступен. Запись остановлена.")
            case .inputChanged:
                self.requestStop("Входное аудиоустройство или его формат изменились. Запись остановлена; автоматического переключения микрофона нет.")
            case .restartEngine:
                let now = Date()
                self.restartTimes.removeAll { now.timeIntervalSince($0) > 5 }
                guard self.restartTimes.count < 3 else { self.requestStop("Аудиодвижок нестабилен. Начните новую запись после проверки микрофона."); return }
                self.restartTimes.append(now)
                do {
                    try self.engine.start(); self.engineRestartCount += 1
                    self.onWarning?("Аудиодвижок перезапущен с прежним встроенным микрофоном; возможен короткий пропуск звука.")
                } catch { self.requestStop("Не удалось возобновить аудиодвижок. Запись остановлена.") }
            }
        }
    }
    @MainActor func simulateConfigurationChangeForDiagnostics(stopEngine: Bool) {
        guard CommandLine.arguments.contains("--self-check-microphone") else { return }
        if stopEngine { engine.stop() }
        NotificationCenter.default.post(name:.AVAudioEngineConfigurationChange,object:engine)
    }
    private func enqueue(_ source: AVAudioPCMBuffer) {
        guard source.frameLength > 0 else { return }
        guard source.format.sampleRate == format.sampleRate else { requestStop("Частота микрофона изменилась. Запись остановлена."); return }
        poolLock.lock()
        if stopped { poolLock.unlock(); return }
        let buffer = pool.popLast()
        let underPressure = pool.count < 24 && !resourcePressureReported
        if underPressure { resourcePressureReported = true }
        poolLock.unlock()
        if underPressure { onResourcePressure?() }
        guard let buffer, source.frameLength <= buffer.frameCapacity, let input = source.floatChannelData, let out = buffer.floatChannelData?[0] else { requestStop("Очередь микрофона переполнена. Сохранённая часть будет восстановлена."); return }
        buffer.frameLength = source.frameLength
        for i in 0..<Int(source.frameLength) {
            var sum: Float = 0
            for ch in 0..<Int(source.format.channelCount) { sum += source.format.isInterleaved ? input[0][i * Int(source.format.channelCount) + ch] : input[ch][i] }
            out[i] = sum / Float(source.format.channelCount)
        }
        writerQueue.async { [weak self] in
            guard let self else { return }
            defer { self.poolLock.lock(); self.pool.append(buffer); self.poolLock.unlock() }
            do { try self.consume(buffer) } catch { self.requestStop("Не удалось сохранить звук. Проверьте свободное место. Завершённые фрагменты сохранены.") }
        }
    }
    private func consume(_ input: AVAudioPCMBuffer) throws {
        guard !requestedStop, let captureWriter else { return }
        try captureWriter.append(input)
        let totalFrames = captureWriter.totalFrames
        if totalFrames - lastMeter >= Int64(format.sampleRate/10) {
            let meterFrames = totalFrames - lastMeter
            lastMeter = totalFrames
            let peak = MicrophoneCaptureWriter.peak(in: input)
            quietFrames = peak < 0.001 ? quietFrames + meterFrames : 0
            let level = min(1, max(0, (20*log10(Double(max(peak, 1e-6))) + 60)/60))
            let message = peak >= 0.99 ? "Слишком громкий звук" : quietFrames >= Int64(format.sampleRate*15) ? "Звук почти не поступает" : nil
            onMeter?(level, Double(totalFrames)/format.sampleRate, message)
        }
        if totalFrames == captureWriter.totalFrameLimit { requestStop("Достигнут предел 3 часа. Запись сохранена.") }
    }
    private func requestStop(_ reason: String) {
        poolLock.lock(); let first = !stopped; stopped = true; poolLock.unlock()
        if first { onStopNeeded?(reason) }
    }
    @MainActor func stop() async throws -> Int64 {
        isCapturing = false; configurationTask?.cancel(); configurationTask = nil
        poolLock.withLock { stopped = true }
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }; changeObserver = nil
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }; engine.stop()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }; activity = nil
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int64, Error>) in
            writerQueue.async {
                do {
                    try self.captureWriter?.close(); self.requestedStop = true
                    continuation.resume(returning: self.captureWriter?.totalFrames ?? 0)
                }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}
