import Foundation
import AVFoundation
import LocalScribeCore

/// Initialized before the tap starts; subsequent access is confined to writerQueue.
final class MicrophoneCaptureWriter {
    static let bufferCapacity: AVAudioFrameCount = 8192
    private let folder: URL
    private let format: AVAudioFormat
    private let scratch: AVAudioPCMBuffer
    private let partFrameLimit: Int64
    let totalFrameLimit: Int64
    private var writer: AVAudioFile?
    private var partFrames: Int64 = 0
    private var partIndex = 0
    private(set) var totalFrames: Int64 = 0

    init(folder: URL, format: AVAudioFormat) throws {
        self.folder = folder; self.format = format
        partFrameLimit = Int64(format.sampleRate * 10)
        totalFrameLimit = Int64(format.sampleRate * 10_800)
        guard let scratch = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.bufferCapacity) else {
            throw ScribeError.message("Не хватает памяти для аудиобуфера")
        }
        self.scratch = scratch
        try openPart()
    }

    func append(_ input: AVAudioPCMBuffer) throws {
        precondition(input.frameLength <= Self.bufferCapacity)
        var position = 0
        while position < Int(input.frameLength) && totalFrames < totalFrameLimit {
            let count = min(Int(input.frameLength) - position, Int(partFrameLimit - partFrames), Int(totalFrameLimit - totalFrames))
            if position == 0 && count == Int(input.frameLength) {
                // write(from:) completes before the recorder returns input to its pool.
                try writer?.write(from: input)
            } else {
                scratch.frameLength = AVAudioFrameCount(count)
                memcpy(scratch.floatChannelData![0], input.floatChannelData![0] + position, count * MemoryLayout<Float>.size)
                try writer?.write(from: scratch)
            }
            partFrames += Int64(count); totalFrames += Int64(count); position += count
            if partFrames == partFrameLimit {
                try close(); partIndex += 1
                try Disk.requireSpace(totalFrames * 4 + 500_000_000, at: folder)
                try openPart()
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

    private func openPart() throws {
        partFrames = 0
        writer = try AVAudioFile(forWriting: folder.appendingPathComponent(String(format: "part-%06d.partial.caf", partIndex)), settings: format.settings)
    }

    func close() throws {
        writer = nil
        let partial = folder.appendingPathComponent(String(format: "part-%06d.partial.caf", partIndex))
        if partFrames > 0 {
            let handle = try FileHandle(forWritingTo: partial); try handle.synchronize(); try handle.close()
            try FileManager.default.moveItem(at: partial, to: folder.appendingPathComponent(String(format: "part-%06d.caf", partIndex)))
        } else { try? FileManager.default.removeItem(at: partial) }
    }
}
