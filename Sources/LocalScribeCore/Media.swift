import Foundation
import AVFoundation
import Darwin

public struct AudioInfo: Codable, Sendable {
    public var duration: Double; public var sampleRate: Double; public var channels: Int; public var codec: String
}
public enum Media {
    static func requireSupportedDuration(_ duration: Double) throws {
        let maximum = Double(Manifest.maximumDurationMs) / 1000
        guard duration.isFinite, duration > 0, duration <= maximum else {
            throw ScribeError.message(duration > maximum
                ? "Запись длиннее 3 часов. Автоматическое усечение отключено."
                : "Не удалось определить ненулевую длительность")
        }
    }

    public static func execute(_ executable: URL, _ arguments: [String], cancellable: Bool = false) throws -> Data {
        if cancellable { try Task.checkCancellation() }
        // Foundation Process creates a separate process group on macOS. By
        // default, spawn without SETPGROUP to inherit the worker's group.
        let output = Pipe()
        defer { try? output.fileHandleForReading.close(); try? output.fileHandleForWriting.close() }
        for handle in [output.fileHandleForReading, output.fileHandleForWriting] {
            guard fcntl(handle.fileDescriptor, F_SETFD, FD_CLOEXEC) == 0 else { throw ScribeError.message("Не удалось настроить канал аудиоинструмента") }
        }
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw ScribeError.message("Не удалось настроить запуск аудиоинструмента") }
        defer { posix_spawn_file_actions_destroy(&actions) }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw ScribeError.message("Не удалось настроить сигналы аудиоинструмента") }
        defer { posix_spawnattr_destroy(&attributes) }
        // Swift/Dispatch threads may block signals. Media children must still
        // respond to the worker group's SIGTERM, regardless of the calling thread.
        var mask = sigset_t(), defaults = sigset_t()
        sigemptyset(&mask); sigemptyset(&defaults)
        for signal in [SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGPIPE] { sigaddset(&defaults, signal) }
        // GUI import probes own a group so cancellation also stops descendants.
        // Worker tools retain the inherited supervisor group by default.
        if cancellable, posix_spawnattr_setpgroup(&attributes, 0) != 0 { throw ScribeError.message("Не удалось настроить группу аудиоинструмента") }
        let flags = POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | (cancellable ? POSIX_SPAWN_SETPGROUP : 0)
        guard posix_spawnattr_setsigmask(&attributes, &mask) == 0,
              posix_spawnattr_setsigdefault(&attributes, &defaults) == 0,
              posix_spawnattr_setflags(&attributes, Int16(flags)) == 0 else { throw ScribeError.message("Не удалось настроить сигналы аудиоинструмента") }
        // Never persist diagnostic media text or leave an unread stderr pipe.
        let setup = [posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
                     posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0),
                     posix_spawn_file_actions_adddup2(&actions, output.fileHandleForWriting.fileDescriptor, STDOUT_FILENO),
                     posix_spawn_file_actions_addclose(&actions, output.fileHandleForReading.fileDescriptor),
                     posix_spawn_file_actions_addclose(&actions, output.fileHandleForWriting.fileDescriptor)]
        guard setup.allSatisfy({ $0 == 0 }) else { throw ScribeError.message("Не удалось настроить потоки аудиоинструмента") }
        var argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        var environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for pointer in argv + environment { free(pointer) } }
        guard argv.dropLast().allSatisfy({ $0 != nil }), environment.dropLast().allSatisfy({ $0 != nil }) else { throw ScribeError.message("Не хватает памяти для запуска аудиоинструмента") }
        var pid: pid_t = 0
        let launch = argv.withUnsafeMutableBufferPointer { arguments in
            environment.withUnsafeMutableBufferPointer { environment in
                posix_spawn(&pid, executable.path, &actions, &attributes, arguments.baseAddress!, environment.baseAddress!)
            }
        }
        guard launch == 0 else { throw ScribeError.message("Не удалось запустить аудиоинструмент (код \(launch))") }
        try? output.fileHandleForWriting.close()
        if cancellable { return try cancellableOutput(output.fileHandleForReading.fileDescriptor, pid: pid) }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        var status: Int32 = 0, waited: pid_t
        repeat { waited = waitpid(pid, &status, 0) } while waited == -1 && errno == EINTR
        guard waited == pid else { throw ScribeError.message("Не удалось дождаться завершения аудиоинструмента") }
        let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : status & 0x7f
        guard code == 0 else { throw ScribeError.message("Не удалось прочитать аудио (код \(code)). Файл повреждён или кодек не поддерживается.") }
        return data
    }
    private static func cancellableOutput(_ descriptor: Int32, pid: pid_t) throws -> Data {
        var reaped = false
        defer {
            if !reaped {
                // The leader is not reaped until the pipe reaches EOF, preserving
                // group identity even when a descendant still holds stdout open.
                kill(-pid, SIGKILL)
                var status: Int32 = 0
                while waitpid(pid, &status, 0) == -1 && errno == EINTR { }
            }
        }
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { throw POSIXError(.EIO) }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try Task.checkCancellation()
            var item = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
            let ready = poll(&item, 1, 50)
            if ready < 0 {
                if errno == EINTR { continue }
                throw POSIXError(.EIO)
            }
            guard ready > 0 else { continue }
            let count = read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw POSIXError(.EIO)
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        // EOF may precede process exit; don't block cancellation in waitpid.
        var status: Int32 = 0
        while true {
            try Task.checkCancellation()
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid { reaped = true; break }
            if waited < 0, errno != EINTR { throw POSIXError(.ECHILD) }
            _ = poll(nil, 0, 50)
        }
        let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : status & 0x7f
        guard code == 0 else { throw ScribeError.message("Не удалось прочитать аудио (код \(code)). Файл повреждён или кодек не поддерживается.") }
        return data
    }
    public static func probe(_ source: URL, tools: URL, cancellable: Bool = false) throws -> AudioInfo {
        let data = try execute(tools.appendingPathComponent("ffprobe"), ["-v", "error", "-protocol_whitelist", "file,pipe", "-show_streams", "-show_format", "-of", "json", source.path], cancellable: cancellable)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let streams = json["streams"] as? [[String: Any]],
              let audio = streams.first(where: { ($0["codec_type"] as? String) == "audio" }),
              !streams.contains(where: { ($0["codec_type"] as? String) == "video" && (($0["disposition"] as? [String:Any])?["attached_pic"] as? Int) != 1 }),
              let codec = audio["codec_name"] as? String,
              ["aac", "alac", "mp3", "flac", "vorbis", "opus"].contains(codec) || codec.hasPrefix("pcm_") else { throw ScribeError.message("Выберите поддерживаемый аудиофайл без видео") }
        let format = json["format"] as? [String: Any]
        let duration: Double
        if format?["format_name"] as? String == "aac" {
            // ADTS has no container duration. FFprobe's bitrate estimate can
            // differ by seconds on VBR audio, so count actual packet durations.
            duration = try adtsDuration(source, tools: tools, timeBase: audio["time_base"] as? String, cancellable: cancellable)
        } else {
            duration = Double((format?["duration"] as? String) ?? (audio["duration"] as? String) ?? "") ?? 0
        }
        try requireSupportedDuration(duration)
        return AudioInfo(duration: duration, sampleRate: Double(audio["sample_rate"] as? String ?? "") ?? 0, channels: audio["channels"] as? Int ?? 0, codec: codec)
    }
    private static func adtsDuration(_ source: URL, tools: URL, timeBase: String?, cancellable: Bool) throws -> Double {
        let parts = timeBase?.split(separator: "/") ?? []
        guard parts.count == 2, let numerator = Int64(parts[0]), let denominator = Int64(parts[1]),
              numerator > 0, denominator > 0 else { throw ScribeError.message("Не удалось определить длительность AAC") }
        // Stop after the import limit plus one second, bounding work and output
        // for oversized files while still rejecting them without truncation.
        let data = try execute(tools.appendingPathComponent("ffprobe"), ["-v", "error", "-protocol_whitelist", "file,pipe", "-select_streams", "a:0", "-read_intervals", "%10801", "-show_entries", "packet=duration", "-of", "csv=p=0", source.path], cancellable: cancellable)
        var ticks: Int64 = 0
        for line in data.split(separator: 10) {
            if cancellable { try Task.checkCancellation() }
            guard let value = Int64(String(decoding: line, as: UTF8.self)), value > 0 else { throw ScribeError.message("Не удалось определить длительность AAC") }
            let (sum, overflow) = ticks.addingReportingOverflow(value)
            guard !overflow else { throw ScribeError.message("Некорректная длительность AAC") }
            ticks = sum
        }
        return Double(ticks) * Double(numerator) / Double(denominator)
    }
    public static func prepare(_ source: URL, to destination: URL, tools: URL) throws -> String? {
        try Disk.directory(destination.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        let temporary = destination.deletingPathExtension().appendingPathExtension("partial.wav")
        if FileManager.default.fileExists(atPath: temporary.path) { try FileManager.default.removeItem(at: temporary) }
        defer { try? FileManager.default.removeItem(at: temporary) }
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
        // Keep one result array and a bounded decode buffer, even for hours of PCM.
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: min(count, 16_384)) else { throw ScribeError.message("Не хватает памяти для аудиобуфера") }
        var samples: [Float] = []
        samples.reserveCapacity(Int(count))
        while samples.count < Int(count) {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: min(buffer.frameCapacity, count - AVAudioFrameCount(samples.count)))
            guard buffer.frameLength > 0, let ptr = buffer.floatChannelData?[0] else { throw ScribeError.message("Неполный или неподдерживаемый PCM") }
            samples.append(contentsOf: UnsafeBufferPointer(start: ptr, count: Int(buffer.frameLength)))
        }
        return samples
    }
    public static func assembleCapture(_ folder: URL, destination: URL) throws -> (Int64, Double) {
        let parts = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "caf" && !$0.lastPathComponent.contains(".partial.") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try assembleCaptureParts(parts, destination: destination)
    }
    public static func assembleCaptureParts(_ parts: [URL], destination: URL) throws -> (Int64, Double) {
        guard let first = parts.first else { throw ScribeError.message("Нет завершённых фрагментов записи") }
        let firstFile = try AVAudioFile(forReading: first)
        let format = firstFile.processingFormat
        let fileFormat = firstFile.fileFormat
        let temp = destination.appendingPathExtension("assembling.caf")
        if FileManager.default.fileExists(atPath: temp.path) { try FileManager.default.removeItem(at: temp) }
        defer { try? FileManager.default.removeItem(at: temp) }
        var total: Int64 = 0
        do {
            let out = try AVAudioFile(forWriting: temp, settings: fileFormat.settings)
            for part in parts {
                let input = try AVAudioFile(forReading: part)
                guard input.processingFormat == format, input.fileFormat == fileFormat else { throw ScribeError.message("Формат микрофона изменился") }
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
