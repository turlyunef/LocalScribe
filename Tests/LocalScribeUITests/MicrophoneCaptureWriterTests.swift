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

    // Finite Float32 values including signed zero, subnormals and both signs.
    // Comparing bytes also catches changes which Float equality would hide.
    private func sample(_ index: Int) -> Float {
        let bits: [UInt32] = [0, 0x8000_0000, 1, 0x8000_0001, 0x3f00_0000, 0xbf00_0000, 0x3f7f_ffff, 0xbf7f_ffff]
        if index % 19 < bits.count { return Float(bitPattern: bits[index % 19]) }
        return Float((index * 73) % 65537 - 32768) / 32768
    }

    private func bytes(_ buffer: AVAudioPCMBuffer) -> Data {
        Data(bytes: buffer.floatChannelData![0], count: Int(buffer.frameLength) * MemoryLayout<Float>.size)
    }

    private func append(_ lengths: [Int], to writer: MicrophoneCaptureWriter, format: AVAudioFormat) throws -> Data {
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: MicrophoneCaptureWriter.bufferCapacity))
        var expected = Data(), position = 0
        for length in lengths {
            input.frameLength = AVAudioFrameCount(length)
            for index in 0..<length { input.floatChannelData![0][index] = sample(position + index) }
            let before = bytes(input)
            try writer.append(input)
            XCTAssertEqual(input.frameLength, AVAudioFrameCount(length))
            XCTAssertEqual(bytes(input), before, "The pooled buffer must stay unchanged until it is returned")
            expected.append(before); position += length
            // Simulate the callback reusing the very same pooled buffer.
            input.floatChannelData![0].update(repeating: 0.875, count: Int(input.frameCapacity))
        }
        return expected
    }

    private func verify(_ folder: URL, lengths: [Int64], expected: Data) throws {
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertEqual(files.map(\.lastPathComponent), lengths.indices.map { String(format: "part-%06d.caf", $0) })
        var actual = Data()
        for (file, length) in zip(files, lengths) {
            let reader = try AVAudioFile(forReading: file)
            XCTAssertEqual(reader.length, length)
            XCTAssertEqual(reader.processingFormat.channelCount, 1)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 8192))
            var frames: Int64 = 0
            while frames < reader.length {
                try reader.read(into: buffer)
                XCTAssertGreaterThan(buffer.frameLength, 0)
                if buffer.frameLength == 0 { break }
                actual.append(bytes(buffer)); frames += Int64(buffer.frameLength)
            }
            XCTAssertEqual(frames, length)
        }
        XCTAssertEqual(actual, expected)
    }

    func testPooledBufferReuseAndRepeatedSplitsPreservePCM() throws {
        for rate in [44_100.0, 48_000.0] {
            try fixture(sampleRate: rate) { folder, format in
                let writer = try MicrophoneCaptureWriter(folder: folder, format: format)
                // 8192 does not divide either 10-second boundary; shorter buffers
                // and a zero-length buffer exercise changes in frameLength.
                var lengths = [0, 1, 1024, 8192, 17]
                lengths += Array(repeating: 8192, count: Int(rate * 21) / 8192)
                let expected = try append(lengths, to: writer, format: format)
                let total = Int64(lengths.reduce(0, +)), part = Int64(rate * 10)
                XCTAssertEqual(writer.totalFrames, total)
                try writer.close()
                try verify(folder, lengths: [part, part, total - 2 * part], expected: expected)
            }
        }
    }

    func testExactBoundaryPublishesClosedCAFAndRemovesEmptyTail() throws {
        try fixture { folder, format in
            let writer = try MicrophoneCaptureWriter(folder: folder, format: format)
            let lengths = Array(repeating: 8192, count: 58) + [4864]
            let expected = try append(lengths, to: writer, format: format)
            let closed = folder.appendingPathComponent("part-000000.caf")
            XCTAssertEqual(try AVAudioFile(forReading: closed).length, 480_000)
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("part-000001.partial.caf").path))
            try writer.close()
            try verify(folder, lengths: [480_000], expected: expected)
        }
    }

    func testShortAndEmptyCapture() throws {
        for lengths in [[], [0], [1], [1024, 17]] as [[Int]] {
            try fixture { folder, format in
                let writer = try MicrophoneCaptureWriter(folder: folder, format: format)
                let expected = try append(lengths, to: writer, format: format)
                try writer.close()
                let total = Int64(lengths.reduce(0, +))
                XCTAssertEqual(writer.totalFrames, total)
                try verify(folder, lengths: total == 0 ? [] : [total], expected: expected)
            }
        }
    }

    func testThreeHourLimitClipsFinalBufferAndIgnoresLaterInput() throws {
        // CAF accepts a 1 Hz processing rate: this exercises the real three-hour
        // limit and all 1080 part boundaries without writing gigabytes of PCM.
        try fixture(sampleRate: 1) { folder, format in
            let writer = try MicrophoneCaptureWriter(folder: folder, format: format)
            XCTAssertEqual(writer.totalFrameLimit, 10_800)
            let expected = try append([8192, 8192, 1], to: writer, format: format)
            XCTAssertEqual(writer.totalFrames, 10_800)
            try writer.close()
            try verify(folder, lengths: Array(repeating: 10, count: 1080), expected: Data(expected.prefix(10_800 * MemoryLayout<Float>.size)))
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
