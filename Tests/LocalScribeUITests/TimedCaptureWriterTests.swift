import AVFoundation
import LocalScribeCore
import XCTest
@testable import LocalScribe

final class TimedCaptureWriterTests: XCTestCase {
    private let origin = AVAudioTime.hostTime(forSeconds: 100)

    private func withFolder(_ body: (URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Disk.directory(folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(folder)
    }

    private func buffer() throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        return try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: MicrophoneCaptureWriter.bufferCapacity))
    }

    private func append(_ writer: TimedCaptureWriter, source: CaptureAudioSource, buffer: AVAudioPCMBuffer,
                        start: Double, count: Int, rate: Double, sample: (Int) -> Float) throws {
        buffer.frameLength = AVAudioFrameCount(count)
        for frame in 0..<count { buffer.floatChannelData![0][frame] = sample(frame) }
        let ticks = AVAudioTime.hostTime(forSeconds: abs(start))
        let hostTime = start < 0 ? origin - ticks : origin + ticks
        try writer.append(buffer, source: source, hostTime: hostTime, sampleRate: rate)
        // The input lease can be recycled as soon as append returns, even with pending filter lookahead.
        buffer.floatChannelData![0].update(repeating: -1, count: count)
    }

    private func parts(_ folder: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func read(_ url: URL) throws -> [Int16] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: false)
        XCTAssertEqual(file.fileFormat.commonFormat, .pcmFormatInt16)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192))
        var result: [Int16] = []
        while file.framePosition < file.length {
            try file.read(into: input)
            result += UnsafeBufferPointer(start: input.int16ChannelData![0], count: Int(input.frameLength))
        }
        return result
    }

    private func value(_ samples: [Int16], at time: Double) -> Double {
        Double(samples[Int((time * 16_000).rounded())]) / 32_768
    }

    func testStaggeredInputsGapAndSourceLossKeepOneTimeline() throws {
        try withFolder { folder in
            let writer = try TimedCaptureWriter(folder: folder, originHostTime: origin, sources: [.microphone, .systemAudio])
            let input = try buffer()
            // Simulate different callback delivery latencies and an explicit microphone gap.
            for index in 0..<24 {
                let time = Double(index) / 20
                if !(10..<13).contains(index) {
                    try append(writer, source: .microphone, buffer: input, start: time, count: 2400, rate: 48_000) { _ in 0.5 }
                }
                if (5..<17).contains(index) {
                    try append(writer, source: .systemAudio, buffer: input, start: time - 0.05, count: 2205, rate: 44_100) { _ in 0.25 }
                }
                if index == 17 { try writer.endSource(.systemAudio) }
            }
            try append(writer, source: .systemAudio, buffer: input, start: 1.2, count: 2205, rate: 44_100) { _ in 1 }
            try writer.close()
            try writer.close()
            let samples = try parts(folder).flatMap { try read($0) }
            XCTAssertEqual(samples.count, 19_200)
            XCTAssertEqual(writer.totalFrames, 19_200)
            XCTAssertEqual(value(samples, at: 0.1), 0.5, accuracy: 0.001)
            XCTAssertEqual(value(samples, at: 0.3), 0.75, accuracy: 0.001)
            XCTAssertEqual(value(samples, at: 0.6), 0.25, accuracy: 0.001)
            XCTAssertEqual(value(samples, at: 0.7), 0.75, accuracy: 0.001)
            XCTAssertEqual(value(samples, at: 0.804), 0.5, accuracy: 0.001)
            XCTAssertEqual(value(samples, at: 0.9), 0.5, accuracy: 0.001)
        }
    }

    func testReplacementMicrophoneSharesSystemTimelineAndLimit() throws {
        try withFolder { folder in
            let writer = try TimedCaptureWriter(folder: folder, originHostTime: origin, sources: [.microphone, .systemAudio],
                                                maximumDuration: 1)
            let input = try buffer()
            for packet in 0..<21 {
                let time = Double(packet) / 20
                try append(writer, source: .systemAudio, buffer: input, start: time, count: 800, rate: 16_000) { _ in 0.25 }
                if packet < 6 {
                    try append(writer, source: .microphone, buffer: input, start: time, count: 2400, rate: 48_000) { _ in 0.5 }
                } else if packet == 6 {
                    try writer.breakSourceSegment(.microphone)
                } else if packet >= 11 {
                    try append(writer, source: .microphone, buffer: input, start: time, count: 1200, rate: 24_000) { _ in -0.125 }
                }
            }
            XCTAssertTrue(writer.reachedLimit)
            try writer.close()
            let samples = try parts(folder).flatMap { try read($0) }
            XCTAssertEqual(samples.count, 16_000)
            XCTAssertEqual(value(samples, at: 0.29), 0.75, accuracy: 0.001)
            XCTAssertEqual(value(samples, at: 0.4), 0.25, accuracy: 0.001)
            XCTAssertEqual(value(samples, at: 0.6), 0.125, accuracy: 0.001)
            XCTAssertEqual(value(samples, at: 0.99), 0.125, accuracy: 0.001)
        }
    }

    func testIndependentDeviceDriftStillMatchesHostTimelineAcrossCAFBoundaries() throws {
        try withFolder { folder in
            let capture = folder.appendingPathComponent("capture")
            try Disk.directory(capture)
            let writer = try TimedCaptureWriter(folder: capture, originHostTime: origin, sources: [.microphone, .systemAudio])
            let input = try buffer()
            let micClock = 48_048.0
            let systemClock = 44_056.0
            let duration = 20.125
            let micEnd = Int(micClock * duration)
            let systemEnd = Int(systemClock * duration)
            var micFrame = 0
            var systemFrame = 0
            while micFrame < micEnd || systemFrame < systemEnd {
                let micTime = Double(micFrame) / micClock
                let systemTime = Double(systemFrame) / systemClock
                if micFrame < micEnd, systemFrame == systemEnd || micTime <= systemTime {
                    let count = min(1024, micEnd - micFrame)
                    try append(writer, source: .microphone, buffer: input, start: micTime, count: count, rate: 48_000) {
                        Float(0.4 * sin(2 * .pi * 500 * Double(micFrame + $0) / micClock))
                    }
                    micFrame += count
                } else {
                    let count = min(777, systemEnd - systemFrame)
                    try append(writer, source: .systemAudio, buffer: input, start: systemTime, count: count, rate: 44_100) {
                        Float(0.4 * sin(2 * .pi * 500 * Double(systemFrame + $0) / systemClock))
                    }
                    systemFrame += count
                }
            }
            try writer.close()
            let files = try parts(capture)
            XCTAssertEqual(try files.map { try AVAudioFile(forReading: $0).length }, [160_000, 160_000, 2000])
            let samples = try files.flatMap { try read($0) }
            for center in [1600, 160_000, 320_000, 321_800] {
                for frame in (center - 40)..<(center + 40) {
                    let target = 0.8 * sin(2 * .pi * 500 * Double(frame) / 16_000)
                    XCTAssertEqual(Double(samples[frame]) / 32_768, target, accuracy: 0.002)
                }
            }
            let original = folder.appendingPathComponent("original.caf")
            let (frames, sampleRate) = try Media.assembleCapture(capture, destination: original)
            XCTAssertEqual(frames, writer.totalFrames)
            XCTAssertEqual(sampleRate, 16_000)
            XCTAssertEqual(try read(original), samples)
            let info = RunInfo(sourceHash: "capture", profileHash: "test")
            let seal = CaptureSeal(info: info, sourceHash: try Disk.hash(original), fragments: try CaptureIntegrity.fragments(at: capture))
            try CaptureIntegrity.verify(seal, info: info, folder: capture, original: original)
        }
    }

    func testMissingPeerCannotDelayCAFOrExtendPastTimelineLimit() throws {
        try withFolder { folder in
            let writer = try TimedCaptureWriter(folder: folder, originHostTime: origin, sources: [.microphone, .systemAudio],
                                                maximumDuration: 13)
            let input = try buffer()
            try append(writer, source: .systemAudio, buffer: input, start: -0.05, count: 4800, rate: 48_000) { _ in 0.5 }
            try append(writer, source: .systemAudio, buffer: input, start: 12.875, count: 8192, rate: 48_000) { _ in -0.5 }
            XCTAssertTrue(writer.reachedLimit)
            XCTAssertTrue(try parts(folder).contains { $0.lastPathComponent == "part-000000.caf" })
            try writer.close()
            let files = try parts(folder)
            XCTAssertEqual(try files.map { try AVAudioFile(forReading: $0).length }, [160_000, 48_000])
            let samples = try files.flatMap { try read($0) }
            XCTAssertEqual(value(samples, at: 0.02), 0.5, accuracy: 0.001)
            XCTAssertEqual(value(samples, at: 0.06), 0)
            XCTAssertEqual(value(samples, at: 12.5), 0)
            XCTAssertEqual(value(samples, at: 12.9), -0.5, accuracy: 0.001)
        }
    }

    func testLongPacketsMixWhenCallbacksArriveAtPacketCompletion() throws {
        try withFolder { folder in
            let writer = try TimedCaptureWriter(folder: folder, originHostTime: origin, sources: [.microphone, .systemAudio])
            let input = try buffer()
            let slowPacketFrames = Int(MicrophoneCaptureWriter.bufferCapacity)
            let fastFramesPerSlowPacket = slowPacketFrames * 6
            let fastPacketFrames = 384
            for packet in 0..<4 {
                let fastStart = packet * fastFramesPerSlowPacket
                // Deliver all fast packets that complete before this slow packet, including ties.
                for start in stride(from: fastStart, to: fastStart + fastFramesPerSlowPacket, by: fastPacketFrames) {
                    try append(writer, source: .systemAudio, buffer: input, start: Double(start) / 48_000,
                               count: fastPacketFrames, rate: 48_000) { _ in 0.5 }
                }
                try append(writer, source: .microphone, buffer: input, start: Double(packet * slowPacketFrames) / 8_000,
                           count: slowPacketFrames, rate: 8_000) { _ in 0.25 }
            }
            try writer.close()
            let samples = try parts(folder).flatMap { try read($0) }
            XCTAssertEqual(samples.count, 4 * slowPacketFrames * 2)
            for packet in 0..<4 {
                let start = Double(packet * slowPacketFrames) / 8_000
                for offset in [0.1, 0.5, 1.0] {
                    XCTAssertEqual(value(samples, at: start + offset), 0.75, accuracy: 0.001)
                }
            }
        }
    }

    func testDownsamplingRejectsAliasingWithTinyPacketsAndRateChange() throws {
        try withFolder { folder in
            let writer = try TimedCaptureWriter(folder: folder, originHostTime: origin, sources: [.systemAudio])
            let input = try buffer()
            for start in stride(from: 0, to: 4800, by: 7) {
                try append(writer, source: .systemAudio, buffer: input, start: Double(start) / 48_000,
                           count: min(7, 4800 - start), rate: 48_000) {
                    Float(0.9 * sin(2 * .pi * 12_000 * Double(start + $0) / 48_000))
                }
            }
            // Same storage lease, different hardware rate. It leaves the actual host-time gap silent.
            try append(writer, source: .systemAudio, buffer: input, start: 0.125, count: 4410, rate: 44_100) { _ in -0.75 }
            try writer.close()
            let samples = try parts(folder).flatMap { try read($0) }
            XCTAssertEqual(samples.count, 3600)
            XCTAssertLessThan(samples[100..<1500].map { abs(Int($0)) }.max() ?? 1, 25)
            XCTAssertEqual(value(samples, at: 0.11), 0)
            XCTAssertEqual(value(samples, at: 0.2), -0.75, accuracy: 0.001)
        }
    }

    func testSilentPeerDoesNotChangeRecordedLevel() throws {
        for source: CaptureAudioSource in [.microphone, .systemAudio] {
            try withFolder { folder in
                let soloFolder = folder.appendingPathComponent("solo")
                let mixedFolder = folder.appendingPathComponent("mixed")
                try Disk.directory(soloFolder)
                try Disk.directory(mixedFolder)
                let solo = try TimedCaptureWriter(folder: soloFolder, originHostTime: origin, sources: [source])
                let peer: CaptureAudioSource = source == .microphone ? .systemAudio : .microphone
                let mixed = try TimedCaptureWriter(folder: mixedFolder, originHostTime: origin, sources: [source, peer])
                let input = try buffer()
                let signalRate = source == .microphone ? 24_000.0 : 48_000.0
                let peerRate = source == .microphone ? 48_000.0 : 24_000.0
                for packet in 0..<4 {
                    let start = Double(packet) / 10
                    let signal: (Int) -> Float = { frame in
                        Float((packet < 2 ? 0.05 : 0.98) * sin(2 * .pi * 500 * Double(frame) / signalRate))
                    }
                    try append(solo, source: source, buffer: input, start: start,
                               count: Int(signalRate / 10), rate: signalRate, sample: signal)
                    try append(mixed, source: source, buffer: input, start: start,
                               count: Int(signalRate / 10), rate: signalRate, sample: signal)
                    try append(mixed, source: peer, buffer: input, start: start,
                               count: Int(peerRate / 10), rate: peerRate) { _ in 0 }
                }
                try solo.close()
                try mixed.close()
                let reference = try parts(soloFolder).flatMap { try read($0) }
                XCTAssertEqual(reference.count, 6400)
                XCTAssertEqual(try parts(mixedFolder).flatMap { try read($0) }, reference)
            }
        }
    }

    func testMixedOverloadHasHeadroomAndLeavesNormalSamplesUnchanged() throws {
        try withFolder { folder in
            let writer = try TimedCaptureWriter(folder: folder, originHostTime: origin, sources: [.microphone, .systemAudio])
            let input = try buffer()
            for (index, pair) in [(1.0, 1.0), (-1.0, -1.0), (0.9, -0.7)].enumerated() {
                let start = Double(index) / 10
                try append(writer, source: .microphone, buffer: input, start: start, count: 1600, rate: 16_000) { _ in Float(pair.0) }
                try append(writer, source: .systemAudio, buffer: input, start: start, count: 1600, rate: 16_000) { _ in Float(pair.1) }
            }
            try writer.close()
            let samples = try parts(folder).flatMap { try read($0) }
            XCTAssertEqual(samples.count, 4800)
            XCTAssertGreaterThan(value(samples, at: 0.05), 0.98)
            XCTAssertLessThanOrEqual(value(samples, at: 0.05), 0.9951)
            XCTAssertEqual(value(samples, at: 0.15), -value(samples, at: 0.05), accuracy: 0.0001)
            XCTAssertEqual(value(samples, at: 0.25), 0.2, accuracy: 0.0001)
            XCTAssertLessThan(samples.max() ?? .max, Int16.max)
            XCTAssertGreaterThan(samples.min() ?? .min, Int16.min)
        }
    }
}
