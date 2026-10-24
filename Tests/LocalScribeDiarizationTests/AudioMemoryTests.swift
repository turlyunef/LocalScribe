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
    func testBoundedPCMReadingPreservesSamplesAndSelectedRange() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let expected = (0..<100_003).map { Float($0 % 127) / 127 }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(expected.count))!
            buffer.frameLength = buffer.frameCapacity
            expected.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
            try file.write(from: buffer)
        }
        XCTAssertEqual(try Media.samples(url), expected)
        XCTAssertEqual(try Media.samples(url, start: 1, duration: 2.5), Array(expected[16_000..<56_000]))
        XCTAssertEqual(try Media.samples(url, start: Double(expected.count) / 16_000), [])
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
        let audio = (0..<(10_800 * 16_000)).map { Float($0 % 127) }
        let baseline = audioResidentBytes()
        let peak = Mutex(baseline)
        let model = try await SpeakerSegmenterModel(modelURL: URL(fileURLWithPath: "/unused"), concurrentWorkers: 1)
        try await model.predictChunks(audioArray: audio, sendOutput: { _ in }, chunkStrideOffset: 64_000) { index, waveform in
            peak.withLock { $0 = max($0, audioResidentBytes()) }
            XCTAssertEqual(waveform.first, audio[index * 416_000])
            return SpeakerSegmenterOutput(features: try MLDictionaryFeatureProvider(dictionary: [:]), chunkIndex: index,
                audioChunk: MLMultiArray(), chunkStride: 26, waveformLength: Float(waveform.count) / 16_000,
                modelSampleRate: 1, audioSampleRate: 16_000)
        }
        let observed = peak.withLock { $0 }
        print("AUDIO_MEMORY baseline=\(baseline) peak=\(observed) delta=\(observed - min(observed, baseline))")
        XCTAssertLessThan(observed - min(observed, baseline), 128 * 1_048_576)
    }
}
