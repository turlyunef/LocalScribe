import Foundation
import LocalScribeCore
import CWorkerIsolation
import Darwin
import LocalScribeSpeakerKit

@main struct Worker {
    static func terminateGroup(_ code: Int32) -> Never {
        signal(SIGTERM, SIG_IGN)
        kill(-getpid(), SIGTERM)
        // Inference may still be running on another thread. Skip MLX's global
        // destructors so they cannot race with active CPU/GPU work on forced exit.
        _exit(code)
    }
    static func main() async {
        if CommandLine.arguments.contains("--versions") {
            print("LocalScribeWorker protocol=1 ArgmaxOSS=1.1.1 SpeakerKitPatch=tail-reflection1-inference-errors1 MLXSwiftLM=2.31.3 macOS=\(ProcessInfo.processInfo.operatingSystemVersionString)")
            return
        }
        // run() returns only after its processing context and monitors are gone.
        // exit() itself does not unwind Swift scopes or execute their defers.
        let code = await run()
        exit(code)
    }

    static func readCommand(read: () -> String? = { readLine() }) -> WorkerCommand? {
        autoreleasepool {
            guard let line = read(), let data = line.data(using: .utf8),
                  let command = try? JSONDecoder().decode(WorkerCommand.self, from: data), command.version == 1 else { return nil }
            return command
        }
    }

    private struct Outcome {
        let code: Int32
        var event: WorkerEvent?
    }

    private static func write(_ event: WorkerEvent, to output: FileHandle) {
        if let data = try? JSONEncoder().encode(event) { try? output.write(contentsOf: data + Data([10])) }
    }

    private static func run() async -> Int32 {
        let protocolOutput = FileHandle(fileDescriptor: dup(STDOUT_FILENO), closeOnDealloc: true)
        defer { try? protocolOutput.close() }
        _ = fcntl(protocolOutput.fileDescriptor,F_SETFD,FD_CLOEXEC)
        signal(SIGPIPE,SIG_IGN)
        dup2(STDERR_FILENO, STDOUT_FILENO)
        guard setpgid(0,0) == 0 || getpgrp() == getpid() else { return 73 }
        guard localscribe_deny_network() == 0 else { fputs("Cannot deny worker network access.\n", stderr); return 70 }
        let control = WorkerControl(parent: getppid())
        let outcome: Outcome
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--probe-diarization" {
            outcome = Outcome(code: await probeDiarization(output: protocolOutput))
        } else {
            outcome = await runCommand(output: protocolOutput, control: control)
        }
        await control.stop()
        if let event = outcome.event { write(event, to: protocolOutput) }
        return outcome.code
    }

    private static func runCommand(output: FileHandle, control: WorkerControl) async -> Outcome {
        guard let command = readCommand() else { return Outcome(code: 64) }
        let emit: @Sendable (String, String, String?) -> Void = { type, message, artifact in
            write(WorkerEvent(command: command, type: type, message: message, artifact: artifact), to: output)
        }
        await control.watchInput { emit("cancelled", "Обработка отменена", nil); terminateGroup(72) }
        do {
            emit("started", "", nil)
            let started = Date()
            let pipeline = try Pipeline(command: command, emit: emit)
            let artifact = try await pipeline.perform()
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            let metrics: [String: Double] = ["seconds": Date().timeIntervalSince(started), "maxResidentBytes": Double(usage.ru_maxrss)]
            try Disk.write(metrics, to: pipeline.run.appendingPathComponent("metrics-\(command.stage.rawValue).json"))
            return Outcome(code: 0, event: WorkerEvent(command: command, type: "completed", artifact: artifact))
        } catch {
            let safe = (error as? ScribeError)?.localizedDescription ?? "Локальный этап завершился ошибкой. Результаты предыдущих этапов сохранены."
            return Outcome(code: 1, event: WorkerEvent(command: command, type: "failed", message: safe))
        }
    }

    private static func probeDiarization(output: FileHandle) async -> Int32 {
        do {
            let audio = URL(fileURLWithPath: CommandLine.arguments[2]), folder = CommandLine.arguments[3]
            let started = Date()
            let samples = try Media.samples(audio)
            let kit = try await SpeakerKit(PyannoteConfig(modelFolder: folder, download: false, load: true, verbose: false, logLevel: .none, concurrentSegmenterWorkers: 1, concurrentEmbedderWorkers: 1))
            let result = try await kit.diarize(audioArray: samples)
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            let metrics: [String:Double] = ["audioSeconds":Double(samples.count)/16000,"sourceFrames":Double(samples.count),"seconds":Date().timeIntervalSince(started),"maxResidentBytes":Double(usage.ru_maxrss),"speakers":Double(result.speakerCount),"intervals":Double(result.segments.count),"lastIntervalEndSeconds":Double(result.segments.map(\.endTime).max() ?? 0)]
            try output.write(contentsOf: JSONEncoder().encode(metrics) + Data([10]))
            return 0
        } catch { fputs("Diarization probe failed.\n", stderr); return 1 }
    }
}
