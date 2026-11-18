import XCTest
import CoreML
import Darwin
import Synchronization
import AVFoundation
import LocalScribeCore
@testable import LocalScribeSpeakerKit

private func audioResidentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.resident_size : 0
}

final class AudioMemoryTests: XCTestCase {
    private func writeSampleFixture(_ expected: [Float]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(expected.count))!
        buffer.frameLength = buffer.frameCapacity
        expected.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        try file.write(from: buffer)
        return url
    }

    func testBoundedPCMReadingPreservesSamplesAndSelectedRange() throws {
        let expected = (0..<100_003).map { Float($0 % 127) / 127 }
        let url = try writeSampleFixture(expected)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try Media.samples(url), expected)
        XCTAssertEqual(try Media.samples(url, start: 1, duration: 2.5), Array(expected[16_000..<56_000]))
        XCTAssertEqual(try Media.samples(url, start: Double(expected.count) / 16_000), [])
        let reader = try Media.PCMFrameReader(url)
        XCTAssertEqual(reader.frameCount, expected.count)
        XCTAssertEqual(try reader.read(16_000..<56_000), Array(expected[16_000..<56_000]))
        XCTAssertEqual(try reader.read(56_000..<expected.count), Array(expected[56_000...]))
        XCTAssertThrowsError(try reader.read(0..<(expected.count + 1)))
    }

    /// The ASR engines convert millisecond windows to exact 16 kHz frame ranges and
    /// clamp the tail to the available frames. Both readers must return identical
    /// samples for every such range, including empty and end-of-file clamped ones.
    func testEngineWindowFrameRangesMatchMediaSamplesClamping() throws {
        let expected = (0..<100_003).map { Float($0 % 127) / 127 }
        let url = try writeSampleFixture(expected)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try Media.PCMFrameReader(url)
        let finalFrame = reader.frameCount
        for (startMs, endMs) in [(0, 0), (0, 1_000), (250, 28_250), (6_000, 6_001),
                                 (6_000, 90_000), (6_250, 6_250), (6_251, 6_251), (0, 6_250)] {
            let lower = startMs * 16
            let upper = min(finalFrame, endMs * 16)
            let clamped: [Float] = lower < upper ? Array(expected[lower..<upper]) : []
            XCTAssertEqual(try Media.samples(url, start: Double(startMs) / 1000,
                                             duration: Double(endMs - startMs) / 1000), clamped)
            XCTAssertEqual(lower < upper ? try reader.read(lower..<upper) : [Float](), clamped)
        }
    }

    @MainActor
    func testRangeSchedulingMatchesOriginalEagerChunksAtEveryBoundary() async throws {
        let maximum = 480_000, offset = 64_000, stride = maximum - offset
        for workers in [1, 3] {
            let model = try await SpeakerSegmenterModel(modelURL: URL(fileURLWithPath: "/unused"), concurrentWorkers: workers)
            for count in [1, maximum - 1, maximum, maximum + 1, maximum + stride - 1, maximum + stride, maximum + stride + 1] {
                let audio = (0..<(count + 34)).map { Float($0 % 127) }
                let start = 17, end = 17 + count
                let seen = Mutex(Set<Int>())
                try await model.predictChunks(audioArray: audio, sendOutput: { output in
                    seen.withLock { XCTAssertTrue($0.insert(output.chunkIndex).inserted) }
                }, chunkStrideOffset: offset, audioRange: start..<end) { index, waveform in
                    let lower = start + index * stride, upper = min(lower + maximum, end)
                    XCTAssertEqual(waveform, Array(audio[lower..<upper]))
                    return SpeakerSegmenterOutput(features: try MLDictionaryFeatureProvider(dictionary: [:]), chunkIndex: index,
                        audioChunk: MLMultiArray(), chunkStride: 26, waveformLength: Float(waveform.count) / 16_000,
                        modelSampleRate: 1, audioSampleRate: 16_000)
                }
                let expectedCount = max(0, Int(ceil(Double(count - maximum) / Double(stride)))) + 1
                XCTAssertEqual(seen.withLock { $0 }, Set(0..<expectedCount))
            }
        }
    }

    @MainActor
    func testThreeHourChunkSchedulingMemory() async throws {
        guard ProcessInfo.processInfo.environment["LOCALSCRIBE_AUDIO_MEMORY_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt in to allocating a three-hour synthetic PCM input")
        }
        let frameCount = 10_800 * 16_000
        let baseline = audioResidentBytes()
        let peak = Mutex(baseline)
        let model = try await SpeakerSegmenterModel(modelURL: URL(fileURLWithPath: "/unused"), concurrentWorkers: 1)
        try await model.predictChunks(audioRange: 0..<frameCount, readFrames: { range in
            XCTAssertLessThanOrEqual(range.count, 480_000)
            return Array(repeating: Float(range.lowerBound % 127), count: range.count)
        }, sendOutput: { _ in }, chunkStrideOffset: 64_000) { index, waveform in
            peak.withLock { $0 = max($0, audioResidentBytes()) }
            XCTAssertEqual(waveform.first, Float((index * 416_000) % 127))
            return SpeakerSegmenterOutput(features: try MLDictionaryFeatureProvider(dictionary: [:]), chunkIndex: index,
                audioChunk: MLMultiArray(), chunkStride: 26, waveformLength: Float(waveform.count) / 16_000,
                modelSampleRate: 1, audioSampleRate: 16_000)
        }
        let observed = peak.withLock { $0 }
        print("AUDIO_MEMORY baseline=\(baseline) peak=\(observed) delta=\(observed - min(observed, baseline))")
        XCTAssertLessThan(observed - min(observed, baseline), 128 * 1_048_576)
    }
}
