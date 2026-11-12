import Foundation
import LocalScribeCore
import Darwin

/// Worker process failure carrying the technical facts the error window copies
/// to the clipboard. `userMessage` stays neutral; `context` is diagnostics only
/// and never includes conversation text.
struct WorkerFailureError: LocalizedError, Sendable {
    let userMessage: String
    let context: [(String, String)]
    var errorDescription: String? { userMessage }
}

@MainActor final class WorkerSupervisor {
    private var process: Process?
    private var control: Pipe?
    private var processGroup: pid_t?
    private var cancellation: Task<Void, Never>?
    private var stopReaders: (() async -> Void)?
    var recordingActive = false {
        didSet { applyCapturePriority() }
    }
    private func applyCapturePriority() {
        guard let process, process.isRunning else { return }
        _ = setpriority(PRIO_DARWIN_PROCESS, UInt32(process.processIdentifier), recordingActive ? PRIO_DARWIN_BG : 0)
    }
    var running: Bool { process?.isRunning == true }
    func run(_ command: WorkerCommand, executable: URL, diagnosticURL: URL? = nil, onEvent: @escaping @MainActor (WorkerEvent) async -> Void) async throws {
        guard process == nil else { throw ScribeError.message("Другой этап ещё работает") }
        let p = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        defer {
            for pipe in [input, output, errors] {
                try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close()
            }
        }
        p.qualityOfService = .utility
        p.executableURL = executable; p.standardInput = input; p.standardOutput = output; p.standardError = errors
        p.environment = ProcessInfo.processInfo.environment.merging(["HF_HUB_OFFLINE": "1", "HF_HUB_DISABLE_TELEMETRY": "1", "TOKENIZERS_PARALLELISM": "false"]) { _, value in value }
        let started = Date()
        try p.run(); process = p; control = input; applyCapturePriority()
        // Foundation launches Process in its own group. Never signal a group
        // inherited from the app, or derive a new target after the leader exits.
        let pid = p.processIdentifier
        processGroup = pid > 1 && getpgid(pid) == pid && pid != getpgrp() ? pid : nil
        defer {
            try? input.fileHandleForWriting.close()
            process = nil; control = nil; processGroup = nil; cancellation = nil; stopReaders = nil
        }
        // Discard SDK stderr continuously: it may include decoded text. It never enters persistent logs.
        let drain = Task.detached { () -> Data in
            var diagnostic = Data()
            var bytes = [UInt8](repeating: 0, count: 16_384)
            while let count = try? Self.readPipe(errors.fileHandleForReading.fileDescriptor, into: &bytes), count > 0 {
                let chunk = bytes.prefix(count)
                if diagnosticURL != nil && diagnostic.count < 65536 { diagnostic.append(contentsOf: chunk.prefix(65536-diagnostic.count)) }
            }
            return diagnostic
        }
        let read = Task.detached { () throws -> (last: WorkerEvent?, failure: WorkerEvent?) in
            var buffer = Data(), last: WorkerEvent?, failure: WorkerEvent?
            var bytes = [UInt8](repeating:0,count:16_384)
            while true {
                let count = try Self.readPipe(output.fileHandleForReading.fileDescriptor, into: &bytes)
                if count == 0 { break }
                buffer.append(contentsOf:bytes.prefix(count))
                guard buffer.count < 1_000_000 else { throw ScribeError.message("Нарушен протокол worker: слишком длинное сообщение") }
                while let end = buffer.firstIndex(of: 10) {
                    let line = buffer[..<end]; buffer.removeSubrange(...end)
                    guard let event = try? JSONDecoder().decode(WorkerEvent.self, from: line), event.version == 1, event.jobId == command.jobId, event.runId == command.runId else { throw ScribeError.message("Нарушена версия или формат протокола worker") }
                    last = event
                    if event.type == "failed" { failure = event }
                    await onEvent(event)
                }
            }
            guard buffer.isEmpty else { throw ScribeError.message("Незавершённое сообщение worker") }
            return (last, failure)
        }
        stopReaders = {
            read.cancel(); drain.cancel()
            _ = try? await read.value
            _ = await drain.value
        }
        try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                try input.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(command) + Data([10]))
                let events = try await read.value
                await Task.detached { p.waitUntilExit() }.value
                let diagnostic = await drain.value
                // A concurrent cancel owns this run until escalation and readers
                // finish, even when the leader and its pipes close sooner.
                if let cancellation { await cancellation.value }
                if let diagnosticURL { try? diagnostic.write(to:diagnosticURL,options:.atomic) }
                try Task.checkCancellation()
                if let failure = events.failure {
                    throw WorkerFailureError(userMessage: failure.message,
                                             context: Self.failureContext(command: command, process: p,
                                                                          last: events.last, started: started))
                }
                guard p.terminationStatus == 0, events.last?.type == "completed" else {
                    throw WorkerFailureError(userMessage: "Процесс обработки прерван (код \(p.terminationStatus)). Контрольные точки сохранены.",
                                             context: Self.failureContext(command: command, process: p,
                                                                          last: events.last, started: started))
                }
            } catch {
                await cancel()
                // Detached pipe readers must finish before their descriptors close
                // or another worker starts, including a failed command write.
                _ = try? await read.value
                _ = await drain.value
                throw error
            }
        } onCancel: {
            Task { @MainActor in if self.process === p { await self.cancel() } }
        }
    }
    nonisolated private static func readPipe(_ descriptor: Int32, into bytes: inout [UInt8]) throws -> Int {
        while true {
            try Task.checkCancellation()
            var channel = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&channel, 1, 100)
            if ready == 0 { continue }
            if ready < 0 { if errno == EINTR { continue }; break }
            // One POSIX read returns available bytes, including POLLHUP's tail.
            // Only this task reads the descriptor; its owner closes it after join.
            let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count >= 0 { return count }
            if errno != EINTR { break }
        }
        throw ScribeError.message("Канал worker закрыт с ошибкой")
    }

    /// Technical facts for the error window's clipboard: what ran, how the
    /// process ended and which protocol event was last. Values are neutral
    /// stage/status strings already shown in the UI, never archive content.
    nonisolated private static func failureContext(command: WorkerCommand, process: Process,
                                                   last: WorkerEvent?, started: Date) -> [(String, String)] {
        var context: [(String, String)] = []
        context.append((L10n.text("вид задания"), command.isDiagram ? L10n.text("схема") : L10n.text("запись")))
        if let stage = command.stage {
            context.append((L10n.text("этап"), command.liveCapture == true ? stage.rawValue + " (live)" : stage.rawValue))
        } else if command.isDiagram {
            context.append((L10n.text("этап"), "diagram"))
        }
        context.append((L10n.text("задание"), command.jobId))
        context.append(("run", command.runId))
        context.append((L10n.text("процесс worker"), terminationDescription(process)))
        if let last {
            context.append((L10n.text("последнее событие протокола"),
                            last.type + (last.message.isEmpty ? "" : " «\(L10n.message(last.message))»")))
        } else {
            context.append((L10n.text("последнее событие протокола"), L10n.text("нет (протокольный канал молчал)")))
        }
        context.append((L10n.text("длительность этапа"), L10n.text("%1$@ с", String(format: "%.1f", Date().timeIntervalSince(started)))))
        return context
    }

    nonisolated private static func terminationDescription(_ process: Process) -> String {
        let status = process.terminationStatus
        if process.terminationReason == .uncaughtSignal {
            let name: String, hint: String
            switch status {
            case SIGILL: (name, hint) = ("SIGILL", L10n.text("недопустимая инструкция"))
            case SIGTRAP: (name, hint) = ("SIGTRAP", L10n.text("аварийное прерывание в коде worker (Swift runtime trap: force-unwrap, границы массива, переполнение)"))
            case SIGABRT: (name, hint) = ("SIGABRT", L10n.text("аварийное завершение (abort/assert)"))
            case SIGFPE: (name, hint) = ("SIGFPE", L10n.text("арифметическая ошибка"))
            case SIGKILL: (name, hint) = ("SIGKILL", L10n.text("принудительное завершение системой (например, при нехватке памяти)"))
            case SIGBUS: (name, hint) = ("SIGBUS", L10n.text("ошибка шины (обращение к памяти)"))
            case SIGSEGV: (name, hint) = ("SIGSEGV", L10n.text("нарушение доступа к памяти"))
            case SIGTERM: (name, hint) = ("SIGTERM", L10n.text("завершение по требованию"))
            default: (name, hint) = (L10n.text("сигнал %1$@", String(status)), L10n.text("необработанный сигнал"))
            }
            return L10n.text("завершён по сигналу %1$@ — %2$@", name, hint)
        }
        switch status {
        case 0: return L10n.text("код 0, но событие completed не получено")
        case 1: return L10n.text("код 1 (этап сообщил об ошибке)")
        case 64: return L10n.text("код 64 (нарушение формата команды)")
        case 70: return L10n.text("код 70 (не удалось запретить сеть worker)")
        case 72: return L10n.text("код 72 (отмена)")
        case 73: return L10n.text("код 73 (не удалось создать группу процессов)")
        default: return L10n.text("код %1$@", String(status))
        }
    }
    func cancel() async {
        guard let p = process else { return }
        if let cancellation { await cancellation.value; return }
        let input = control, group = processGroup, stop = stopReaders
        // Share one cleanup across UI cancellation, task cancellation and run's
        // error path. It must not inherit the caller's cancelled sleep deadlines.
        let cleanup = Task { @MainActor in
            try? input?.fileHandleForWriting.close()
            for _ in 0..<30 {
                if !p.isRunning { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            // Group lifetime is independent of the leader: an orphan may retain
            // both pipes and ignore TERM. Stop targeting a group once it is gone.
            let signalledGroup = group.map { kill(-$0, SIGTERM) == 0 } ?? false
            let leaderRunning = p.isRunning
            if leaderRunning { p.terminate() }
            if signalledGroup || leaderRunning { try? await Task.sleep(for: .milliseconds(300)) }
            if signalledGroup, let group { kill(-group, SIGKILL) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            await stop?()
            await Task.detached { p.waitUntilExit() }.value
        }
        cancellation = cleanup
        await cleanup.value
    }
    func terminateNow() {
        try? control?.fileHandleForWriting.close()
        if let group = processGroup { kill(-group, SIGTERM) }
        if let p = process, p.isRunning { p.terminate() }
    }
}
