import Foundation
import AVFoundation
import LocalScribeCore

/// Initialized before the tap starts; subsequent access is confined to writerQueue.
final class MicrophoneCaptureWriter {
    static let bufferCapacity: AVAudioFrameCount = 8192
    static let sampleRate: Double = 16_000
    private let inputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let converted: AVAudioPCMBuffer
    private let inputScratch: AVAudioPCMBuffer
    private let sink: CapturePCM16Sink
    private let inputFrameLimit: Int64
    private var inputFrames: Int64 = 0
    private var finished = false
    private var failure: Error?
    var totalFrames: Int64 { sink.totalFrames }
    var totalFrameLimit: Int64 { sink.totalFrameLimit }
    var reachedLimit: Bool { inputFrames == inputFrameLimit }

    init(folder: URL, format: AVAudioFormat, maximumDuration: Double = 10_800) throws {
        guard format.commonFormat == .pcmFormatFloat32, format.channelCount == 1,
              format.sampleRate.isFinite, (8000...384000).contains(format.sampleRate),
              let storage = CapturePCM16Sink.format,
              let converter = AVAudioConverter(from: format, to: storage),
              let converted = AVAudioPCMBuffer(pcmFormat: storage, frameCapacity: Self.bufferCapacity),
              let inputScratch = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.bufferCapacity) else {
            throw ScribeError.message("Не удалось подготовить преобразование звука микрофона")
        }
        sink = try CapturePCM16Sink(folder: folder, maximumDuration: maximumDuration)
        inputFormat = format; self.converter = converter; self.converted = converted; self.inputScratch = inputScratch
        inputFrameLimit = Int64(format.sampleRate * maximumDuration)
        // Normal priming compensates filter delay. Never reset at buffer/CAF boundaries.
        converter.primeMethod = .normal
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
    }

    func append(_ input: AVAudioPCMBuffer) throws {
        if let failure { throw failure }
        guard !finished, !reachedLimit, input.frameLength > 0 else { return }
        guard input.format == inputFormat, input.frameLength <= Self.bufferCapacity else {
            throw ScribeError.message("Изменился формат буфера микрофона")
        }
        let count = AVAudioFrameCount(min(Int64(input.frameLength), inputFrameLimit - inputFrames))
        let source: AVAudioPCMBuffer
        if count == input.frameLength {
            source = input
        } else {
            inputScratch.frameLength = count
            memcpy(inputScratch.floatChannelData![0], input.floatChannelData![0], Int(count) * MemoryLayout<Float>.size)
            source = inputScratch
        }
        inputFrames += Int64(count)
        do { try convert(source) }
        catch { failure = error; throw error }
    }

    /// Drain each pooled input before returning it; nil means the actual end of the session.
    private func convert(_ input: AVAudioPCMBuffer?) throws {
        var supplied = false
        while true {
            converted.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: converted, error: &error) { _, state in
                if let input, !supplied {
                    supplied = true; state.pointee = .haveData; return input
                }
                state.pointee = input == nil ? .endOfStream : .noDataNow
                return nil
            }
            guard status != .error, error == nil else {
                throw ScribeError.message("Не удалось преобразовать звук микрофона")
            }
            try sink.append(converted)
            switch status {
            case .haveData: continue
            case .inputRanDry, .endOfStream: return
            default: throw ScribeError.message("Не удалось завершить преобразование звука микрофона")
            }
        }
    }

    static func peak(in input: AVAudioPCMBuffer) -> Float {
        let samples = UnsafeBufferPointer(start: input.floatChannelData![0], count: Int(input.frameLength))
        guard let first = samples.first else { return 0 }
        var peak = abs(first)
        for sample in samples.dropFirst() {
            let magnitude = abs(sample)
            if peak < magnitude { peak = magnitude }
        }
        return peak
    }

    func close() throws {
        if let failure { throw failure }
        guard !finished else { return }
        do {
            if inputFrames > 0 { try convert(nil) }
            try sink.close()
            finished = true
        } catch { failure = error; throw error }
    }
}

/// Writes the same PCM16 fragments for both capture paths. Confined to writerQueue.
final class CapturePCM16Sink {
    static let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: MicrophoneCaptureWriter.sampleRate,
                                     channels: 1, interleaved: false)
    private let folder: URL
    private let storageFormat: AVAudioFormat
    private let scratch: AVAudioPCMBuffer
    private let partFrameLimit = Int64(MicrophoneCaptureWriter.sampleRate * 10)
    let totalFrameLimit: Int64
    private var writer: AVAudioFile?
    private var partFrames: Int64 = 0
    private var partIndex = 0
    private(set) var totalFrames: Int64 = 0

    init(folder: URL, maximumDuration: Double) throws {
        guard maximumDuration.isFinite, maximumDuration > 0, maximumDuration <= 10_800,
              let format = Self.format,
              let scratch = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: MicrophoneCaptureWriter.bufferCapacity) else {
            throw ScribeError.message("Не удалось подготовить сохранение звука")
        }
        self.folder = folder
        storageFormat = format
        self.scratch = scratch
        totalFrameLimit = Int64(MicrophoneCaptureWriter.sampleRate * maximumDuration)
    }

    func append(_ input: AVAudioPCMBuffer) throws {
        var position = 0
        while position < Int(input.frameLength) && totalFrames < totalFrameLimit {
            if writer == nil { try openPart() }
            let count = min(Int(input.frameLength) - position, Int(partFrameLimit - partFrames), Int(totalFrameLimit - totalFrames))
            if position == 0 && count == Int(input.frameLength) {
                try writer?.write(from: input)
            } else {
                scratch.frameLength = AVAudioFrameCount(count)
                memcpy(scratch.int16ChannelData![0], input.int16ChannelData![0] + position, count * MemoryLayout<Int16>.size)
                try writer?.write(from: scratch)
            }
            partFrames += Int64(count); totalFrames += Int64(count); position += count
            if partFrames == partFrameLimit {
                try close(); partIndex += 1
                try Disk.requireSpace(totalFrames * 2 + 500_000_000, at: folder)
            }
        }
    }

    private func openPart() throws {
        partFrames = 0
        writer = try AVAudioFile(forWriting: folder.appendingPathComponent(String(format: "part-%06d.partial.caf", partIndex)),
                                 settings: storageFormat.settings, commonFormat: .pcmFormatInt16, interleaved: false)
    }

    func close() throws {
        guard writer != nil else { return }
        writer = nil
        let partial = folder.appendingPathComponent(String(format: "part-%06d.partial.caf", partIndex))
        let handle = try FileHandle(forWritingTo: partial); try handle.synchronize(); try handle.close()
        try FileManager.default.moveItem(at: partial, to: folder.appendingPathComponent(String(format: "part-%06d.caf", partIndex)))
    }
}
