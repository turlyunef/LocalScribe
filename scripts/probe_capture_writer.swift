// Compile alongside Sources/LocalScribe/MicrophoneCaptureWriter.swift and the built
// LocalScribeCore objects (see docs/CaptureWriterAllocations.md). No microphone,
// models or archive: only synthetic PCM in a temporary UUID directory.
import Foundation
import AVFoundation
import LocalScribeCore

@main
struct CaptureWriterProbe {
    static func main() throws {
        let bufferCount = CommandLine.arguments.dropFirst().first.flatMap(Int.init) ?? 20_000
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Disk.directory(folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: MicrophoneCaptureWriter.bufferCapacity)!
        input.frameLength = 1024
        for index in 0..<Int(input.frameLength) { input.floatChannelData![0][index] = Float(index % 257 - 128) / 256 }
        let queue = DispatchQueue(label: "LocalScribe.capture.writer", qos: .userInitiated)
        try queue.sync {
            let writer = try MicrophoneCaptureWriter(folder: folder, format: format)
            var lastMeter: Int64 = 0
            var peakSum: Float = 0
            for _ in 0..<bufferCount {
                try autoreleasepool {
                    try writer.append(input)
                    if writer.totalFrames - lastMeter >= Int64(MicrophoneCaptureWriter.sampleRate / 10) {
                        lastMeter = writer.totalFrames
                        peakSum += MicrophoneCaptureWriter.peak(in: input)
                    }
                }
            }
            try writer.close()
            print("buffers=\(bufferCount) frames=\(writer.totalFrames) peakSum=\(peakSum)")
        }
    }
}
