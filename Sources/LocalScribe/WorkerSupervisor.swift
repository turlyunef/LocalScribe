import Foundation
import LocalScribeCore
import Darwin

@MainActor final class WorkerSupervisor {
    private var process: Process?
    private var control: Pipe?
    var running: Bool { process?.isRunning == true }
    func run(_ command: WorkerCommand, executable: URL, diagnosticURL: URL? = nil, onEvent: @escaping @MainActor (WorkerEvent) -> Void) async throws {
        guard process == nil else { throw ScribeError.message("Другой этап ещё работает") }
        let p = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        p.executableURL = executable; p.standardInput = input; p.standardOutput = output; p.standardError = errors
        p.environment = ProcessInfo.processInfo.environment.merging(["HF_HUB_OFFLINE": "1", "HF_HUB_DISABLE_TELEMETRY": "1", "TOKENIZERS_PARALLELISM": "false"]) { _, value in value }
        try p.run(); process = p; control = input
        defer { try? input.fileHandleForWriting.close(); process = nil; control = nil }
        // Discard SDK stderr continuously: it may include decoded text. It never enters persistent logs.
        let drain = Task.detached { () -> Data in
            var diagnostic = Data()
            while true {
                let chunk = errors.fileHandleForReading.readData(ofLength:16384)
                if chunk.isEmpty { break }
                if diagnosticURL != nil && diagnostic.count < 65536 { diagnostic.append(chunk.prefix(65536-diagnostic.count)) }
            }
            return diagnostic
        }
        let read = Task.detached { () throws -> [WorkerEvent] in
            var buffer = Data(), events: [WorkerEvent] = []
            var bytes = [UInt8](repeating:0,count:16_384)
            while true {
                // One POSIX read returns currently available pipe bytes. Foundation's
                // count-based reads may wait for the requested count and delay progress.
                let count = bytes.withUnsafeMutableBytes { Darwin.read(output.fileHandleForReading.fileDescriptor,$0.baseAddress,$0.count) }
                if count == 0 { break }
                if count < 0 { if errno == EINTR { continue }; throw ScribeError.message("Канал worker закрыт с ошибкой") }
                buffer.append(contentsOf:bytes.prefix(count))
                guard buffer.count < 1_000_000 else { throw ScribeError.message("Нарушен протокол worker: слишком длинное сообщение") }
                while let end = buffer.firstIndex(of: 10) {
                    let line = buffer[..<end]; buffer.removeSubrange(...end)
                    guard let event = try? JSONDecoder().decode(WorkerEvent.self, from: line), event.version == 1, event.jobId == command.jobId, event.runId == command.runId else { throw ScribeError.message("Нарушена версия или формат протокола worker") }
                    events.append(event); await onEvent(event)
                }
            }
            guard buffer.isEmpty else { throw ScribeError.message("Незавершённое сообщение worker") }
            return events
        }
        try input.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(command) + Data([10]))
        do {
            let events = try await read.value
            await Task.detached { p.waitUntilExit() }.value
            let diagnostic = await drain.value
            if let diagnosticURL { try? diagnostic.write(to:diagnosticURL,options:.atomic) }
            if let failure = events.last(where: { $0.type == "failed" }) { throw ScribeError.message(failure.message) }
            guard p.terminationStatus == 0, events.last?.type == "completed" else { throw ScribeError.message("Процесс обработки прерван (код \(p.terminationStatus)). Контрольные точки сохранены.") }
        } catch {
            await cancel()
            throw error
        }
    }
    func cancel() async {
        guard let p = process else { return }
        try? control?.fileHandleForWriting.close()
        for _ in 0..<30 {
            if !p.isRunning { kill(-p.processIdentifier,SIGTERM); return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if p.isRunning { kill(-p.processIdentifier,SIGTERM); p.terminate() }
        try? await Task.sleep(for: .milliseconds(300))
        if p.isRunning { kill(-p.processIdentifier,SIGKILL); kill(p.processIdentifier, SIGKILL) }
        await Task.detached { p.waitUntilExit() }.value
    }
    func terminateNow() { try? control?.fileHandleForWriting.close(); if let p = process, p.isRunning { kill(-p.processIdentifier,SIGTERM); p.terminate() } }
}
