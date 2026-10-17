import Foundation
import LocalScribeCore
import CWorkerIsolation
import Darwin
import SpeakerKit

@main struct Worker {
    static func terminateGroup(_ code: Int32) -> Never {
        signal(SIGTERM,SIG_IGN); kill(-getpid(),SIGTERM); exit(code)
    }
    static func main() async {
        if CommandLine.arguments.contains("--versions") {
            print("LocalScribeWorker protocol=1 ArgmaxOSS=1.1.1 MLXSwiftLM=2.31.3 macOS=\(ProcessInfo.processInfo.operatingSystemVersionString)")
            return
        }
        let protocolOutput = FileHandle(fileDescriptor: dup(STDOUT_FILENO), closeOnDealloc: true)
        _ = fcntl(protocolOutput.fileDescriptor,F_SETFD,FD_CLOEXEC)
        signal(SIGPIPE,SIG_IGN)
        dup2(STDERR_FILENO, STDOUT_FILENO)
        guard setpgid(0,0) == 0 || getpgrp() == getpid() else { exit(73) }
        guard localscribe_deny_network() == 0 else { fputs("Cannot deny worker network access.\n", stderr); exit(70) }
        let parent = getppid()
        let watchdog = DispatchSource.makeTimerSource(queue: .global())
        watchdog.schedule(deadline: .now() + 1, repeating: 1)
        watchdog.setEventHandler { if getppid() != parent { terminateGroup(71) } }
        watchdog.resume()
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--probe-diarization" {
            do {
                let audio = URL(fileURLWithPath: CommandLine.arguments[2]), folder = CommandLine.arguments[3]
                let started = Date()
                let samples = try Media.samples(audio)
                let kit = try await SpeakerKit(PyannoteConfig(modelFolder: folder, download: false, load: true, verbose: false, logLevel: .none, concurrentSegmenterWorkers: 1, concurrentEmbedderWorkers: 1))
                let result = try await kit.diarize(audioArray: samples)
                var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
                let metrics: [String:Double] = ["audioSeconds":Double(samples.count)/16000,"sourceFrames":Double(samples.count),"seconds":Date().timeIntervalSince(started),"maxResidentBytes":Double(usage.ru_maxrss),"speakers":Double(result.speakerCount),"intervals":Double(result.segments.count),"lastIntervalEndSeconds":Double(result.segments.map(\.endTime).max() ?? 0)]
                try protocolOutput.write(contentsOf: JSONEncoder().encode(metrics) + Data([10])); exit(0)
            } catch { fputs("Diarization probe failed.\n",stderr); exit(1) }
        }
        guard let line = readLine(), let data = line.data(using: .utf8),
              let command = try? JSONDecoder().decode(WorkerCommand.self, from: data), command.version == 1 else { exit(64) }
        let emit: @Sendable (String, String, String?) -> Void = { type, message, artifact in
            let event = WorkerEvent(command: command, type: type, message: message, artifact: artifact)
            if let data = try? JSONEncoder().encode(event) { try? protocolOutput.write(contentsOf: data + Data([10])) }
        }
        DispatchQueue.global().async { _ = FileHandle.standardInput.readDataToEndOfFile(); emit("cancelled","Обработка отменена",nil); terminateGroup(72) }
        do {
            emit("started", "", nil)
            let started = Date()
            let pipeline = try Pipeline(command: command, emit: emit)
            let artifact = try await pipeline.perform()
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            let metrics: [String: Double] = ["seconds": Date().timeIntervalSince(started), "maxResidentBytes": Double(usage.ru_maxrss)]
            try Disk.write(metrics, to: pipeline.run.appendingPathComponent("metrics-\(command.stage.rawValue).json"))
            emit("completed", "", artifact)
            exit(0)
        } catch {
            let safe = (error as? ScribeError)?.localizedDescription ?? "Локальный этап завершился ошибкой. Результаты предыдущих этапов сохранены."
            emit("failed", safe, nil); exit(1)
        }
    }
}
