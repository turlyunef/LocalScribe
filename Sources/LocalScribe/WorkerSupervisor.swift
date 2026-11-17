import Foundation
import LocalScribeCore
import Darwin

struct WorkerFailureError: LocalizedError, Sendable {
    let userMessage: String
    let diagnostic: DiagnosticFailure
    var exit: DiagnosticWorkerExit? = nil
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
        let started = ContinuousClock.now
        do { try p.run() }
        catch {
            throw WorkerFailureError(userMessage: "Не удалось запустить процесс обработки.",
                                     diagnostic: DiagnosticFailure(.workerLaunch, phase: .launch, error: error))
        }
        process = p; control = input; applyCapturePriority()
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
        var lastDelivered: WorkerEvent?
        let deliver: @MainActor @Sendable (WorkerEvent) async -> Void = { event in
            lastDelivered = event
            await onEvent(event)
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
                    guard let event = try? JSONDecoder().decode(WorkerEvent.self, from: line), event.version == 1, event.jobId == command.jobId, event.runId == command.runId, event.kind == command.kind else { throw ScribeError.message("Нарушена версия или формат протокола worker") }
                    last = event
                    if event.type == "failed" { failure = event }
                    await deliver(event)
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
            var phase = DiagnosticPhase.commandWrite
            do {
                try Task.checkCancellation()
                try input.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(command) + Data([10]))
                phase = .protocolRead
                let events = try await read.value
                await Task.detached { p.waitUntilExit() }.value
                let diagnostic = await drain.value
                // A concurrent cancel owns this run until escalation and readers
                // finish, even when the leader and its pipes close sooner.
                if let cancellation { await cancellation.value }
                if let diagnosticURL { try? diagnostic.write(to:diagnosticURL,options:.atomic) }
                try Task.checkCancellation()
                let exit = Self.workerExit(p, last: events.last, started: started)
                if let failure = events.failure {
                    throw WorkerFailureError(userMessage: failure.message,
                                             diagnostic: failure.diagnosticFailure ?? DiagnosticFailure(.processingFailed, phase: .processing),
                                             exit: exit)
                }
                guard p.terminationStatus == 0, events.last?.type == "completed" else {
                    let code: DiagnosticFailure.Code
                    switch (exit.reason, exit.status) {
                    case (.signal, _): code = .workerSignal
                    case (.exit, 0): code = .workerMissingCompletion
                    case (.exit, 64): code = .workerInvalidCommand
                    case (.exit, 70): code = .workerIsolation
                    case (.exit, 73): code = .workerSetup
                    default: code = .workerExit
                    }
                    throw WorkerFailureError(userMessage: "Процесс обработки прерван (код \(p.terminationStatus)). Контрольные точки сохранены.",
                                             diagnostic: DiagnosticFailure(code), exit: exit)
                }
            } catch {
                let exit = p.isRunning ? nil : Self.workerExit(p, last: lastDelivered, started: started)
                await cancel()
                // Detached pipe readers must finish before their descriptors close
                // or another worker starts, including a failed command write.
                _ = try? await read.value
                _ = await drain.value
                if error is CancellationError || error is WorkerFailureError { throw error }
                try Task.checkCancellation()
                let code: DiagnosticFailure.Code = phase == .commandWrite ? .workerCommandWrite : .workerProtocol
                let message = (error as? ScribeError)?.localizedDescription ?? "Сбой обмена данными с процессом обработки."
                throw WorkerFailureError(userMessage: message, diagnostic: DiagnosticFailure(code, phase: phase, error: error), exit: exit)
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
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    nonisolated private static func workerExit(_ process: Process, last: WorkerEvent?, started: ContinuousClock.Instant) -> DiagnosticWorkerExit {
        let elapsed = started.duration(to: .now).components
        return DiagnosticWorkerExit(reason: process.terminationReason == .uncaughtSignal ? .signal : .exit,
                                    status: process.terminationStatus,
                                    lastEvent: last.flatMap { .init(rawValue: $0.type) },
                                    elapsedMs: Int(elapsed.seconds) * 1_000 + Int(elapsed.attoseconds / 1_000_000_000_000_000))
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
