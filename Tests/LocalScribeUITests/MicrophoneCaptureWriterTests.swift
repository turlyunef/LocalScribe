import XCTest
import AVFoundation
@testable import LocalScribe
import LocalScribeCore

final class MicrophoneCaptureWriterTests: XCTestCase {
    private func fixture(sampleRate: Double = 48_000, _ body: (URL, AVAudioFormat) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Disk.directory(folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(folder, XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)))
    }

    private func sample(_ index: Int, rate: Double) -> Float {
        // A continuous quiet tone plus changing speech-band content across CAF boundaries.
        let time = Double(index) / rate
        return Float(0.0005 * sin(2 * .pi * 300 * time) + 0.2 * sin(2 * .pi * 1700 * time))
    }

    private func sample(_ index: Int) -> Float { sample(index, rate: 48_000) }

    private func bytes(_ buffer: AVAudioPCMBuffer) -> Data {
        Data(bytes: buffer.floatChannelData![0], count: Int(buffer.frameLength) * MemoryLayout<Float>.size)
    }

    private func append(frames: Int, chunk: Int, to writer: MicrophoneCaptureWriter, format: AVAudioFormat,
                        signal: ((Int) -> Float)? = nil) throws {
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: MicrophoneCaptureWriter.bufferCapacity))
        var position = 0
        while position < frames {
            let count = min(chunk, frames - position)
            input.frameLength = AVAudioFrameCount(count)
            for i in 0..<count { input.floatChannelData![0][i] = signal?(position + i) ?? sample(position + i, rate: format.sampleRate) }
            let before = bytes(input)
            try writer.append(input)
            XCTAssertEqual(input.frameLength, AVAudioFrameCount(count))
            XCTAssertEqual(bytes(input), before)
            input.floatChannelData![0].update(repeating: 0.875, count: Int(input.frameCapacity))
            position += count
        }
    }

    private func read(_ url: URL) throws -> [Int16] {
        let reader = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: false)
        XCTAssertEqual(reader.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(reader.fileFormat.channelCount, 1)
        XCTAssertEqual(reader.fileFormat.streamDescription.pointee.mBitsPerChannel, 16)
        XCTAssertEqual(reader.fileFormat.commonFormat, .pcmFormatInt16)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 8192))
        var result = [Int16]()
        while reader.framePosition < reader.length {
            try reader.read(into: buffer)
            result += UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength))
        }
        return result
    }

    private func parts(_ folder: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.contains(".partial.") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func testConversionIsContinuousAcrossPooledBuffersAndCAFBoundaries() throws {
        for rate in [8000.0, 16_000.0, 44_100.0, 48_000.0, 96_000.0] {
            try fixture(sampleRate: rate) { folder, format in
                var results = [[Int16]]()
                for chunk in [1024, 8192] {
                    let capture = folder.appendingPathComponent("capture-\(chunk)")
                    try Disk.directory(capture)
                    let writer = try MicrophoneCaptureWriter(folder: capture, format: format)
                    try append(frames: Int(rate * 20.125), chunk: chunk, to: writer, format: format)
                    try writer.close()
                    let files = try parts(capture)
                    XCTAssertEqual(try files.map { try AVAudioFile(forReading: $0).length }, [160_000, 160_000, 2000])
                    let samples = try files.flatMap { try read($0) }
                    XCTAssertEqual(writer.totalFrames, 322_000)
                    XCTAssertEqual(samples.count, 322_000)
                    results.append(samples)
                    let original = folder.appendingPathComponent("original-\(chunk).caf")
                    let (frames, sampleRate) = try Media.assembleCapture(capture, destination: original)
                    XCTAssertEqual(frames, writer.totalFrames); XCTAssertEqual(sampleRate, 16_000)
                    XCTAssertEqual(try read(original), samples)
                    let info = RunInfo(sourceHash: "capture", profileHash: "test")
                    let seal = CaptureSeal(info: info, sourceHash: try Disk.hash(original), fragments: try CaptureIntegrity.fragments(at: capture))
                    try CaptureIntegrity.verify(seal, info: info, folder: capture, original: original)
                    XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: capture.path).contains { $0.contains(".partial.") })
                }
                XCTAssertTrue(results[0] == results[1], "Conversion must not depend on callback boundaries at \(rate) Hz")
            }
        }
    }

    func testQuietToneHasNoShiftOrDropoutsAtFragmentBoundaries() throws {
        for rate in [44_100.0, 48_000.0] {
            try fixture(sampleRate: rate) { folder, format in
                let writer = try MicrophoneCaptureWriter(folder: folder, format: format)
                try append(frames: Int(rate * 20.125), chunk: 1024, to: writer, format: format) {
                    Float(0.0005 * sin(2 * .pi * 400 * Double($0) / rate))
                }
                try writer.close()
                let samples = try parts(folder).flatMap { try read($0) }
                for center in [1600, 160_000, 320_000, 321_900] {
                    for i in (center - 40)..<(center + 40) {
                        let expected = 0.0005 * sin(2 * .pi * 400 * Double(i) / 16_000)
                        XCTAssertEqual(Double(samples[i]) / 32768, expected, accuracy: 2.0 / 32768)
                    }
                }
            }
        }
    }

    func testShortEmptyAndRepeatedClose() throws {
        for frames in [0, 1, 17, 1024, 4800, 480_000] {
            try fixture { folder, format in
                let writer = try MicrophoneCaptureWriter(folder: folder, format: format)
                try append(frames: frames, chunk: 1024, to: writer, format: format)
                try writer.close(); try writer.close()
                let files = try parts(folder)
                let actual = try files.flatMap { try read($0) }
                XCTAssertEqual(actual.count, Int((Double(frames) / 3).rounded()))
                XCTAssertEqual(writer.totalFrames, Int64(actual.count))
                XCTAssertEqual(files.count, actual.isEmpty ? 0 : 1)
            }
        }
    }

    func testDurationLimitClipsInputAndDrainsConverterTail() throws {
        try fixture(sampleRate: 44_100) { folder, format in
            let writer = try MicrophoneCaptureWriter(folder: folder, format: format, maximumDuration: 20)
            XCTAssertEqual(writer.totalFrameLimit, 320_000)
            try append(frames: 900_000, chunk: 8192, to: writer, format: format)
            XCTAssertTrue(writer.reachedLimit)
            try writer.close()
            XCTAssertEqual(writer.totalFrames, 320_000)
            XCTAssertEqual(try parts(folder).map { try AVAudioFile(forReading: $0).length }, [160_000, 160_000])
        }
    }

    func testRecoveryIncludesOnlyClosedPCM16Fragments() throws {
        try fixture { folder, format in
            let capture = folder.appendingPathComponent("capture")
            try Disk.directory(capture)
            let writer = try MicrophoneCaptureWriter(folder: capture, format: format)
            try append(frames: 48_000 * 12, chunk: 1024, to: writer, format: format)
            let original = folder.appendingPathComponent("recovered.caf")
            let (frames, rate) = try Media.assembleCapture(capture, destination: original)
            XCTAssertEqual(frames, 160_000); XCTAssertEqual(rate, 16_000)
            XCTAssertEqual(try read(original), try read(capture.appendingPathComponent("part-000000.caf")))
            try writer.close()
        }
    }

    func testPCM16QuantizationAndClippingAtNative16kHz() throws {
        try fixture(sampleRate: 16_000) { folder, format in
            let writer = try MicrophoneCaptureWriter(folder: folder, format: format)
            let values: [Float] = [-1.5, -1, -0.0005, 0, 0.0005, 0.5, 1, 1.5]
            try append(frames: 1600, chunk: 17, to: writer, format: format) { values[$0 % values.count] }
            try writer.close()
            let samples = try parts(folder).flatMap { try read($0) }
            XCTAssertEqual(samples.count, 1600)
            for (index, value) in samples.enumerated() {
                let expected = min(32767, max(-32768, Double(values[index % values.count]) * 32768))
                XCTAssertEqual(Double(value), expected, accuracy: 1)
            }
        }
    }

    func testAssemblyPreservesLegacyFloat32SamplesAndFiles() throws {
        try fixture { folder, format in
            let capture = folder.appendingPathComponent("capture")
            try Disk.directory(capture)
            let part = capture.appendingPathComponent("part-000000.caf")
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
            buffer.frameLength = 1024
            for i in 0..<1024 { buffer.floatChannelData![0][i] = sample(i) }
            do {
                let file = try AVAudioFile(forWriting: part, settings: format.settings)
                try file.write(from: buffer)
            }
            let hash = try Disk.hash(part)
            let original = folder.appendingPathComponent("original.caf")
            _ = try Media.assembleCapture(capture, destination: original)
            let reader = try AVAudioFile(forReading: original)
            XCTAssertEqual(reader.fileFormat.commonFormat, .pcmFormatFloat32)
            XCTAssertEqual(reader.fileFormat.sampleRate, 48_000)
            let actual = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 1024))
            try reader.read(into: actual)
            XCTAssertEqual(bytes(actual), bytes(buffer))
            XCTAssertEqual(try Disk.hash(part), hash)
        }
    }

    func testPeakMatchesPreviousCalculationWithoutChangingPCM() throws {
        try fixture { _, format in
            let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: MicrophoneCaptureWriter.bufferCapacity))
            for length in [0, 1, 17, 1024, 8192] {
                input.frameLength = AVAudioFrameCount(length)
                for index in 0..<length { input.floatChannelData![0][index] = sample(index) }
                let before = bytes(input)
                let samples = UnsafeBufferPointer(start: input.floatChannelData![0], count: length)
                let expected = samples.map { abs($0) }.max() ?? 0
                XCTAssertEqual(MicrophoneCaptureWriter.peak(in: input).bitPattern, expected.bitPattern)
                XCTAssertEqual(bytes(input), before)
            }
            for values: [Float] in [[0, -0.0], [-1.5, 0.0009, 0.99], [.nan, 1], [1, .nan, 2], [-.infinity, 1]] {
                input.frameLength = AVAudioFrameCount(values.count)
                for (index, value) in values.enumerated() { input.floatChannelData![0][index] = value }
                let expected = values.map { abs($0) }.max() ?? 0
                XCTAssertEqual(MicrophoneCaptureWriter.peak(in: input).bitPattern, expected.bitPattern)
            }
        }
    }
}
