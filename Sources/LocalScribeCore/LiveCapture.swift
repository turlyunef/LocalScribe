import Foundation
import AVFoundation

/// Small disk-backed descriptors; audio is never queued in memory.
public struct CaptureFragment: Codable, Sendable, Equatable {
    public var index: Int
    public var frames: Int64
    public var sampleRate: Double
    public var sha256: String
    public var filename: String { String(format: "part-%06d.caf", index) }
    public var durationMs: Int { Int(Double(frames) / sampleRate * 1000) }
    public static func read(index: Int, folder: URL) throws -> CaptureFragment {
        guard (0...1080).contains(index) else { throw ScribeError.message("Недопустимый номер фрагмента") }
        let name = String(format: "part-%06d.caf", index)
        let url = folder.appendingPathComponent(name)
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0, file.processingFormat.channelCount == 1,
              file.processingFormat.sampleRate.isFinite, (8000...384000).contains(file.processingFormat.sampleRate),
              file.length <= Int64(file.processingFormat.sampleRate * 10) else {
            throw ScribeError.message("Некорректный закрытый фрагмент микрофона")
        }
        return CaptureFragment(index: index, frames: file.length, sampleRate: file.processingFormat.sampleRate, sha256: try Disk.hash(url))
    }
}

public struct CaptureSeal: Codable, Sendable {
    public var schemaVersion = 1
    public var runID: String
    public var captureFingerprint: String
    public var sourceHash: String
    public var fragments: [CaptureFragment]
    public var durationMs: Int { Int(Double(fragments.reduce(0) { $0 + $1.frames }) / (fragments.first?.sampleRate ?? 1) * 1000) }
    public init(info: RunInfo, sourceHash: String, fragments: [CaptureFragment]) {
        runID = info.id; captureFingerprint = info.fingerprint; self.sourceHash = sourceHash; self.fragments = fragments
    }
    public func validate(info: RunInfo) throws {
        guard schemaVersion == 1, runID == info.id, captureFingerprint == info.fingerprint,
              !fragments.isEmpty, fragments.count <= 1081, sourceHash.count == 64,
              fragments.enumerated().allSatisfy({ index, f in
                  f.index == index && f.frames > 0 && f.sampleRate.isFinite && (8000...384000).contains(f.sampleRate)
                  && f.sampleRate == fragments[0].sampleRate && f.frames <= Int64(f.sampleRate * 10)
                  && (index == fragments.count - 1 || f.frames == Int64(f.sampleRate * 10)) && f.sha256.count == 64
              }), durationMs > 0, durationMs <= 10_800_000 else {
            throw ScribeError.message("Не прошла проверка завершения потока записи")
        }
    }
}

public struct LiveASRPart: Codable, Sendable {
    public var schemaVersion = 1
    public var part: ASRPart
    public var readStartMs: Int
    public var readEndMs: Int
    public var fragments: [CaptureFragment]
    public init(part: ASRPart, readStartMs: Int, readEndMs: Int, fragments: [CaptureFragment]) {
        self.part = part; self.readStartMs = readStartMs; self.readEndMs = readEndMs; self.fragments = fragments
    }
    public func validate(info: RunInfo, index: Int, startMs: Int, availableMs: Int, fragments current: [CaptureFragment]) throws {
        guard availableMs > 0, availableMs <= 10_800_000, startMs >= 0, startMs < availableMs,
              index >= 0, index <= 360, schemaVersion == 1, part.schemaVersion == 1, part.fingerprint == info.fingerprint,
              part.index == index, part.startMs == startMs, part.endMs > startMs,
              part.endMs <= min(startMs + ASRCheckpointLayout.livePartMs, availableMs), readStartMs == max(0, startMs - ASRCheckpointLayout.liveContextMs),
              readEndMs >= part.endMs, readEndMs <= min(part.endMs + ASRCheckpointLayout.liveContextMs, availableMs),
              fragments == current else { throw ScribeError.message("Контрольная точка фонового распознавания не соответствует звуку") }
        try Transcript(fingerprint: info.fingerprint, diarized: false, segments: part.segments).validate(durationMs: availableMs)
    }
}

public enum CaptureIntegrity {
    /// Compare decoded PCM, not container headers. Both reads are bounded to 8192 frames.
    /// The final SHA is checked independently, including when resuming after a crash.
    public static func verify(_ seal: CaptureSeal, info: RunInfo, folder: URL, original: URL) throws {
        try seal.validate(info: info)
        guard try Disk.hash(original) == seal.sourceHash else { throw ScribeError.message("Изменился оригинал записи") }
        let source = try AVAudioFile(forReading: original)
        guard source.length == seal.fragments.reduce(0, { $0 + $1.frames }),
              source.processingFormat.channelCount == 1, source.processingFormat.sampleRate == seal.fragments[0].sampleRate else {
            throw ScribeError.message("Оригинал не соответствует фрагментам записи")
        }
        for fragment in seal.fragments {
            let url = folder.appendingPathComponent(fragment.filename)
            guard try Disk.hash(url) == fragment.sha256 else { throw ScribeError.message("Изменился фрагмент записи") }
            let input = try AVAudioFile(forReading: url)
            guard input.length == fragment.frames, input.processingFormat == source.processingFormat,
                  let left = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 8192),
                  let right = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 8192) else {
                throw ScribeError.message("Изменился формат фрагмента записи")
            }
            while input.framePosition < input.length {
                let count = AVAudioFrameCount(min(8192, input.length - input.framePosition))
                try input.read(into: left, frameCount: count); try source.read(into: right, frameCount: count)
                guard left.frameLength == count, right.frameLength == count,
                      let l = left.floatChannelData?[0], let r = right.floatChannelData?[0],
                      memcmp(l, r, Int(count) * MemoryLayout<Float>.size) == 0 else {
                    throw ScribeError.message("Сэмплы оригинала не соответствуют распознанным фрагментам")
                }
            }
        }
    }
    public static func fragments(at folder: URL) throws -> [CaptureFragment] {
        try fragmentURLs(at: folder).indices.map { try CaptureFragment.read(index: $0, folder: folder) }
    }

    static func fragmentURLs(at folder: URL) throws -> [URL] {
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "caf" && !$0.lastPathComponent.contains(".partial.") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for (index, url) in urls.enumerated() {
            guard url.lastPathComponent == String(format: "part-%06d.caf", index) else {
                throw ScribeError.message("Нарушен порядок фрагментов записи")
            }
        }
        return urls
    }
}
