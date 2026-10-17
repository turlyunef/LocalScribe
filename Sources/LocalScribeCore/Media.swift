import Foundation
import AVFoundation

public struct AudioInfo: Codable, Sendable {
    public var duration: Double; public var sampleRate: Double; public var channels: Int; public var codec: String
}
public enum Media {
    public static func execute(_ executable: URL, _ arguments: [String]) throws -> Data {
        let p = Process(); p.executableURL = executable; p.arguments = arguments
        let output = Pipe(); p.standardOutput = output
        // Diagnostic media text is not logged. Direct stderr to /dev/null; never leave an unread pipe.
        p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        try p.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw ScribeError.message("Не удалось прочитать аудио (код \(p.terminationStatus)). Файл повреждён или кодек не поддерживается.") }
        return data
    }
    public static func probe(_ source: URL, tools: URL) throws -> AudioInfo {
        let data = try execute(tools.appendingPathComponent("ffprobe"), ["-v", "error", "-protocol_whitelist", "file,pipe", "-show_streams", "-show_format", "-of", "json", source.path])
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let streams = json["streams"] as? [[String: Any]],
              let audio = streams.first(where: { ($0["codec_type"] as? String) == "audio" }),
              !streams.contains(where: { ($0["codec_type"] as? String) == "video" && (($0["disposition"] as? [String:Any])?["attached_pic"] as? Int) != 1 }),
              let codec = audio["codec_name"] as? String,
              ["aac", "alac", "mp3", "flac", "vorbis", "opus"].contains(codec) || codec.hasPrefix("pcm_") else { throw ScribeError.message("Выберите поддерживаемый аудиофайл без видео") }
        let format = json["format"] as? [String: Any]
        let duration = Double((format?["duration"] as? String) ?? (audio["duration"] as? String) ?? "") ?? 0
        guard duration.isFinite, duration > 0, duration <= 10_800.0005 else { throw ScribeError.message(duration > 10_800 ? "Запись длиннее 3 часов. Автоматическое усечение отключено." : "Не удалось определить ненулевую длительность") }
        return AudioInfo(duration: duration, sampleRate: Double(audio["sample_rate"] as? String ?? "") ?? 0, channels: audio["channels"] as? Int ?? 0, codec: codec)
    }
    public static func prepare(_ source: URL, to destination: URL, tools: URL) throws -> String? {
        try Disk.directory(destination.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        let temporary = destination.deletingPathExtension().appendingPathExtension("partial.wav")
        if FileManager.default.fileExists(atPath: temporary.path) { try FileManager.default.removeItem(at: temporary) }
        // Detect gross phase cancellation from a bounded sample. Full QA remains necessary for varied stereo material.
        let info = try probe(source, tools: tools)
        var warning: String?
        var filter: [String] = []
        if info.channels == 2 {
            let stereo = try execute(tools.appendingPathComponent("ffmpeg"), ["-nostdin", "-v", "error", "-protocol_whitelist", "file,pipe", "-i", source.path, "-t", "60", "-ar", "16000", "-ac", "2", "-f", "f32le", "pipe:1"])
            let stats = stereo.withUnsafeBytes { bytes -> (Double, Double, Double) in
                let samples = bytes.bindMemory(to: Float.self); var left = 0.0, right = 0.0, mix = 0.0
                for i in stride(from: 0, to: samples.count - 1, by: 2) { let l = Double(samples[i]), r = Double(samples[i+1]); left += l*l; right += r*r; mix += (l+r)*(l+r)/4 }
                return (left, right, mix)
            }
            if max(stats.0, stats.1) > 0.001 && stats.2 < max(stats.0, stats.1) * 0.025 {
                filter = ["-af", "pan=mono|c0=c\(stats.0 >= stats.1 ? 0 : 1)"]
                warning = "Обнаружена противофаза стереоканалов. Выбран один канал; часть разговора в другом канале могла быть потеряна."
            }
        }
        _ = try execute(tools.appendingPathComponent("ffmpeg"), ["-nostdin", "-n", "-v", "error", "-protocol_whitelist", "file,pipe", "-i", source.path, "-map", "0:a:0", "-vn"] + filter + ["-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", temporary.path])
        let file = try AVAudioFile(forReading: temporary)
        guard file.length > 0, abs(Double(file.length) / file.processingFormat.sampleRate - info.duration) < 0.15 else { throw ScribeError.message("Декодированный звук неполный") }
        try FileManager.default.moveItem(at: temporary, to: destination)
        return warning
    }
    public static func samples(_ url: URL, start: Double = 0, duration: Double? = nil) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        file.framePosition = AVAudioFramePosition((start * rate).rounded())
        let remaining = max(0, file.length - file.framePosition)
        let count = AVAudioFrameCount(min(remaining, AVAudioFramePosition(((duration ?? (Double(remaining) / rate)) * rate).rounded())))
        guard count > 0 else { return [] }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else { throw ScribeError.message("Не хватает памяти для аудиобуфера") }
        try file.read(into: buffer, frameCount: count)
        guard let ptr = buffer.floatChannelData?[0] else { throw ScribeError.message("Неподдерживаемый PCM") }
        return Array(UnsafeBufferPointer(start: ptr, count: Int(buffer.frameLength)))
    }
    public static func assembleCapture(_ folder: URL, destination: URL) throws -> (Int64, Double) {
        let parts = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "caf" && !$0.lastPathComponent.contains(".partial.") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard let first = parts.first else { throw ScribeError.message("Нет завершённых фрагментов записи") }
        let format = try AVAudioFile(forReading: first).processingFormat
        let temp = destination.appendingPathExtension("assembling.caf")
        if FileManager.default.fileExists(atPath: temp.path) { try FileManager.default.removeItem(at: temp) }
        var total: Int64 = 0
        do {
            let out = try AVAudioFile(forWriting: temp, settings: format.settings)
            for part in parts {
                let input = try AVAudioFile(forReading: part)
                guard input.processingFormat == format else { throw ScribeError.message("Формат микрофона изменился") }
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)!
                while input.framePosition < input.length { try input.read(into: buffer); try out.write(from: buffer); total += Int64(buffer.frameLength) }
            }
        }
        guard try AVAudioFile(forReading: temp).length == total else { throw ScribeError.message("Не совпало число сэмплов записи") }
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: temp, to: destination)
        return (total, format.sampleRate)
    }
}
