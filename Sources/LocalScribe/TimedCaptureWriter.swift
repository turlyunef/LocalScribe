import Accelerate
import AVFoundation
import Foundation
import LocalScribeCore

enum CaptureAudioSource: Hashable {
    case microphone
    case systemAudio
}

/// Mixes capture packets on the host clock and writes the ordinary PCM16 fragment stream.
/// After initialization, all calls and property reads belong to the serial writer queue.
final class TimedCaptureWriter {
    private static let sampleRate = MicrophoneCaptureWriter.sampleRate
    private static let minimumInputRate: Double = 8_000
    private static let maximumPacketDuration = Double(MicrophoneCaptureWriter.bufferCapacity) / minimumInputRate
    // Resolving a packet can require the next callback and filter lookahead.
    private static let peerWaitFrames = Int64(ceil((2 * maximumPacketDuration + 0.25) * sampleRate))
    // Hold the waiting interval plus a full packet being rendered before the next drain.
    private static let mixCapacity = 65_536
    private static let peakKnee: Float = 0.90
    private static let peakCeiling: Float = 0.995

    private struct MixFrame {
        var microphone: Float = 0
        var systemAudio: Float = 0
    }

    private var originHostTime: UInt64?
    private let sources: Set<CaptureAudioSource>
    private let sink: CapturePCM16Sink
    private let output: AVAudioPCMBuffer
    private var mix = Array(repeating: MixFrame(), count: mixCapacity)
    private var tracks: [CaptureAudioSource: TimedCaptureTrack] = [:]
    private var ended: Set<CaptureAudioSource> = []
    private var finished = false
    private var failure: Error?

    var totalFrames: Int64 { sink.totalFrames }
    var reachedLimit: Bool { tracks.values.contains { $0.acceptedThrough >= sink.totalFrameLimit } }

    init(folder: URL, originHostTime: UInt64?, sources: Set<CaptureAudioSource>, maximumDuration: Double = 10_800) throws {
        guard !sources.isEmpty, let format = CapturePCM16Sink.format,
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: MicrophoneCaptureWriter.bufferCapacity) else {
            throw ScribeError.message("Не удалось подготовить сохранение звука")
        }
        self.originHostTime = originHostTime
        self.sources = sources
        self.output = output
        sink = try CapturePCM16Sink(folder: folder, maximumDuration: maximumDuration)
    }

    /// hostTime describes the first input frame, using the same host clock as originHostTime.
    func append(_ input: AVAudioPCMBuffer, source: CaptureAudioSource, hostTime: UInt64,
                sampleRate: Double? = nil) throws {
        if let failure { throw failure }
        guard !finished, sources.contains(source), !ended.contains(source), input.frameLength > 0 else { return }
        let rate = sampleRate ?? input.format.sampleRate
        guard rate.isFinite, (Self.minimumInputRate...384_000).contains(rate),
              input.format.channelCount == 1, let samples = input.floatChannelData?[0],
              input.frameLength <= MicrophoneCaptureWriter.bufferCapacity else {
            throw ScribeError.message("Не удалось прочитать звуковой буфер")
        }
        let originHostTime = self.originHostTime ?? hostTime
        self.originHostTime = originHostTime
        let elapsed = hostTime >= originHostTime ? AVAudioTime.seconds(forHostTime: hostTime - originHostTime)
            : -AVAudioTime.seconds(forHostTime: originHostTime - hostTime)
        let start = elapsed * Self.sampleRate
        do {
            let track: TimedCaptureTrack
            if let existing = tracks[source], existing.inputRate == rate {
                track = existing
            } else {
                if let existing = tracks[source] { try finish(existing, source: source) }
                track = TimedCaptureTrack(inputRate: rate, outputRate: Self.sampleRate,
                                          resolvedThrough: tracks[source]?.resolvedThrough ?? 0)
                tracks[source] = track
            }
            try track.append(UnsafeBufferPointer(start: samples, count: Int(input.frameLength)), start: start) { range, sample in
                try render(range, source: source, sample: sample)
            }
            try drainAvailable()
        } catch { failure = error; throw error }
    }

    /// A failed or stopped source may have already submitted its last packet.
    func endSource(_ source: CaptureAudioSource) throws {
        try finishSourceSegment(source, endingSource: true)
    }

    /// A replacement input starts a fresh resampling segment on the same clock.
    func breakSourceSegment(_ source: CaptureAudioSource) throws {
        try finishSourceSegment(source, endingSource: false)
    }

    private func finishSourceSegment(_ source: CaptureAudioSource, endingSource: Bool) throws {
        if let failure { throw failure }
        guard !finished, sources.contains(source), !ended.contains(source) else { return }
        do {
            if let track = tracks[source] { try finish(track, source: source) }
            if endingSource { ended.insert(source) }
            try drainAvailable()
        } catch { failure = error; throw error }
    }

    func close() throws {
        if let failure { throw failure }
        guard !finished else { return }
        do {
            for (source, track) in tracks { try finish(track, source: source) }
            try drain(through: tracks.values.lazy.map(\.resolvedThrough).max() ?? 0)
            try sink.close()
            finished = true
        } catch { failure = error; throw error }
    }

    private func finish(_ track: TimedCaptureTrack, source: CaptureAudioSource) throws {
        try track.finish { range, sample in try render(range, source: source, sample: sample) }
    }

    private func render(_ range: Range<Int64>, source: CaptureAudioSource, sample: (Int64) -> Float) throws {
        let end = min(range.upperBound, sink.totalFrameLimit)
        // A timestamp jump can span much more time than the ring. Commit its earlier portion before wrapping.
        try drain(through: end - Int64(Self.mixCapacity))
        let start = max(range.lowerBound, totalFrames)
        guard start < end else { return }
        for frame in start..<end {
            let index = Int(frame) & (Self.mixCapacity - 1)
            let value = max(-1, min(1, sample(frame)))
            switch source {
            case .microphone:
                mix[index].microphone = value
            case .systemAudio:
                mix[index].systemAudio = value
            }
        }
    }

    private static func mixedSample(_ frame: MixFrame) -> Float {
        let sum = frame.microphone + frame.systemAudio
        let louderInput = max(abs(frame.microphone), abs(frame.systemAudio))
        // Leave either input's level intact below the ceiling. Smoothly
        // compress only a constructive sum near full scale.
        let knee = min(peakCeiling, max(peakKnee, louderInput))
        let excess = abs(sum) - knee
        guard excess > 0 else { return sum }
        let room = peakCeiling - knee
        let limited = knee + room * (excess / (room + excess))
        return sum < 0 ? -limited : limited
    }

    private func drainAvailable() throws {
        let latest = tracks.values.lazy.map(\.resolvedThrough).max() ?? 0
        var common = latest
        for source in sources where !ended.contains(source) {
            common = min(common, tracks[source]?.resolvedThrough ?? 0)
        }
        // A late or missing peer cannot block the surviving stream or grow the ring indefinitely.
        try drain(through: max(common, latest - Self.peerWaitFrames))
    }

    private func drain(through frame: Int64) throws {
        let end = min(frame, sink.totalFrameLimit)
        let pcm = output.int16ChannelData![0]
        while totalFrames < end {
            let start = totalFrames
            let count = Int(min(end - start, Int64(output.frameCapacity)))
            for offset in 0..<count {
                let index = (Int(start) + offset) & (Self.mixCapacity - 1)
                let sample = mix[index]
                mix[index] = MixFrame()
                let value = sources.count > 1 ? Self.mixedSample(sample) : sample.microphone + sample.systemAudio
                pcm[offset] = Int16(clamping: Int((value * 32_768).rounded()))
            }
            output.frameLength = AVAudioFrameCount(count)
            try sink.append(output)
        }
    }
}

/// One continuous source segment at a time, with bounded filter history and lookahead.
private final class TimedCaptureTrack {
    private struct Packet {
        let start: Double
        var end: Double?
        let offset: Int
        let count: Int
    }

    typealias Render = (Range<Int64>, (Int64) -> Float) throws -> Void
    private static let phaseCount = 64
    let inputRate: Double
    private let nominalScale: Double
    private let radius: Int
    private let weights: [Float]
    private var samples: [Float]
    private var sampleBase = 0
    private var sampleCount = 0
    private var packets: [Packet] = []
    private var head = 0
    private var clockScale: Double
    private(set) var resolvedThrough: Int64
    private(set) var acceptedThrough: Int64

    init(inputRate: Double, outputRate: Double, resolvedThrough: Int64) {
        self.inputRate = inputRate
        nominalScale = outputRate / inputRate
        clockScale = nominalScale
        self.resolvedThrough = resolvedThrough
        acceptedThrough = resolvedThrough
        // Leave a transition band below the output Nyquist frequency when decimating.
        let cutoff = inputRate > outputRate ? 0.92 * nominalScale : 1
        radius = Int(ceil(16 / cutoff))
        weights = Self.filter(radius: radius, cutoff: cutoff)
        samples = Array(repeating: 0, count: 2 * Int(MicrophoneCaptureWriter.bufferCapacity) + 3 * radius)
        packets.reserveCapacity(64 + radius)
    }

    func append(_ input: UnsafeBufferPointer<Float>, start: Double, render: Render) throws {
        if let previous = packets.last {
            guard start >= previous.start else { return }
            let span = start - previous.start
            let nominalSpan = Double(previous.count) * nominalScale
            let tolerance = max(nominalSpan * 0.005, min(4, nominalSpan * 0.125))
            if span > 0, abs(span - nominalSpan) <= tolerance {
                packets[packets.count - 1].end = start
                let observed = span / Double(previous.count)
                clockScale += 0.2 * (observed - clockScale)
            } else {
                try finish(render: render)
            }
        }

        if head > 64 {
            packets.removeFirst(head)
            head = 0
        }
        if samples.count - sampleCount < input.count { compactSamples() }
        let offset = sampleBase + sampleCount
        samples.withUnsafeMutableBufferPointer { destination in
            for index in input.indices {
                let value = input[index]
                destination[sampleCount + index] = value.isFinite ? value : 0
            }
        }
        sampleCount += input.count
        if packets.isEmpty { resolvedThrough = max(resolvedThrough, Int64(start.rounded())) }
        packets.append(Packet(start: start, offset: offset, count: input.count))
        acceptedThrough = max(resolvedThrough, Int64((start + Double(input.count) * clockScale).rounded()))
        try resolve(flushing: false, render: render)
    }

    func finish(render: Render) throws {
        guard let previous = packets.last else { return }
        packets[packets.count - 1].end = previous.start + Double(previous.count) * clockScale
        try resolve(flushing: true, render: render)
        packets.removeAll(keepingCapacity: true)
        head = 0
        sampleCount = 0
        sampleBase = 0
        acceptedThrough = resolvedThrough
        clockScale = nominalScale
    }

    private func compactSamples() {
        let discard = max(0, packets[head].offset - radius - sampleBase)
        samples.withUnsafeMutableBufferPointer { buffer in
            _ = memmove(buffer.baseAddress!, buffer.baseAddress! + discard, (sampleCount - discard) * MemoryLayout<Float>.stride)
        }
        sampleCount -= discard
        sampleBase += discard
    }

    private func resolve(flushing: Bool, render: Render) throws {
        while head < packets.count {
            let packet = packets[head]
            guard let end = packet.end,
                  flushing || packet.offset + packet.count + radius <= sampleBase + sampleCount else { return }
            let firstFrame = max(resolvedThrough, Int64(packet.start.rounded()))
            let nextFrame = max(firstFrame, Int64(end.rounded()))
            let inverseScale = Double(packet.count) / (end - packet.start)
            // Keep one sample grid across packets, anchored to the timestamps of the first input frames.
            try samples.withUnsafeBufferPointer { input in
                try weights.withUnsafeBufferPointer { filter in
                    try render(firstFrame..<nextFrame) { frame in
                        let position = (Double(frame) - packet.start) * inverseScale
                        return interpolate(input, filter: filter, position: position + Double(packet.offset - sampleBase))
                    }
                }
            }
            resolvedThrough = nextFrame
            head += 1
        }
    }

    private func interpolate(_ input: UnsafeBufferPointer<Float>, filter: UnsafeBufferPointer<Float>, position: Double) -> Float {
        let integral = floor(position)
        let phase = Int(((position - integral) * Double(Self.phaseCount)).rounded())
        let tapStart = Int(integral) - radius + 1
        let first = max(0, tapStart)
        let count = min(sampleCount, tapStart + 2 * radius) - first
        guard count > 0 else { return 0 }
        var result: Float = 0
        vDSP_dotpr(input.baseAddress! + first, 1, filter.baseAddress! + phase * 2 * radius + first - tapStart, 1,
                   &result, vDSP_Length(count))
        return result.isFinite ? result : 0
    }

    private static func filter(radius: Int, cutoff: Double) -> [Float] {
        var table: [Float] = []
        table.reserveCapacity((phaseCount + 1) * 2 * radius)
        for phase in 0...phaseCount {
            let start = table.count
            let fraction = Double(phase) / Double(phaseCount)
            var sum: Float = 0
            for tap in (1 - radius)...radius {
                let distance = Double(tap) - fraction
                let angle = Double.pi * distance / Double(radius)
                let window = 0.42 + 0.5 * cos(angle) + 0.08 * cos(2 * angle)
                let sinc = distance == 0 ? cutoff : sin(.pi * cutoff * distance) / (.pi * distance)
                let weight = Float(window * sinc)
                table.append(weight)
                sum += weight
            }
            for index in start..<table.count { table[index] /= sum }
        }
        return table
    }
}
