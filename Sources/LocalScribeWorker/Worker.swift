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
            print("LocalScribeWorker protocol=1 ArgmaxOSS=1.1.1 SpeakerKitPatch=tail-reflection1-inference-errors1 MLXSwiftLM=2.31.3 QwenRuntime=0.1.3-acoustic6fd9386 VibeVoiceRuntime=6fd9386 macOS=\(ProcessInfo.processInfo.operatingSystemVersionString)")
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
        let protocolDescriptor = fcntl(STDOUT_FILENO, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
        guard protocolDescriptor >= 0 else { return 73 }
        let protocolOutput = FileHandle(fileDescriptor: protocolDescriptor, closeOnDealloc: true)
        defer { try? protocolOutput.close() }
        signal(SIGPIPE,SIG_IGN)
        guard dup2(STDERR_FILENO, STDOUT_FILENO) >= 0 else { return 73 }
        guard setpgid(0,0) == 0 || getpgrp() == getpid() else { return 73 }
        guard localscribe_deny_network() == 0 else { fputs("Cannot deny worker network access.\n", stderr); return 70 }
        let control = WorkerControl(parent: getppid())
        let outcome: Outcome
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--probe-diarization" {
            outcome = Outcome(code: await probeDiarization(output: protocolOutput))
        } else if (4...5).contains(CommandLine.arguments.count), CommandLine.arguments[1] == "--probe-diagram" {
            // Developer probe: raw recognizer errors, no user content.
            outcome = Outcome(code: await probeDiagram(output: protocolOutput))
        } else if (4...5).contains(CommandLine.arguments.count), CommandLine.arguments[1] == "--probe-anonymization" {
            // Developer qualification probe: raw pipeline result or error,
            // no neutral wrapper.
            outcome = Outcome(code: await probeAnonymization(output: protocolOutput))
        } else {
            outcome = await runCommand(output: protocolOutput, control: control)
        }
        await control.stop()
        if let event = outcome.event { write(event, to: protocolOutput) }
        return outcome.code
    }

    private static func runCommand(output: FileHandle, control: WorkerControl) async -> Outcome {
        guard let command = readCommand() else { return Outcome(code: 64) }
        // The audio wire format stays kindless; diagram and anonymization
        // commands carry their own discriminator and never mix audio fields.
        guard command.kind == nil || command.isDiagram || command.isAnonymization else { return Outcome(code: 64) }
        if command.isDiagram { return await runDiagram(command: command, output: output, control: control) }
        if command.isAnonymization { return await runAnonymization(command: command, output: output, control: control) }
        guard command.stage != nil, command.recordingPath != nil, command.toolsPath != nil,
              command.diagramPath == nil, command.anonymizationPath == nil else { return Outcome(code: 64) }
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
            // Metrics are diagnostics only; a failed write must not fail a finished stage.
            try? Disk.write(metrics, to: pipeline.run.appendingPathComponent("metrics-\(pipeline.stage.rawValue).json"))
            return Outcome(code: 0, event: WorkerEvent(command: command, type: "completed", artifact: artifact))
        } catch {
            let safe = (error as? ScribeError)?.localizedDescription ?? "Локальный этап завершился ошибкой. Результаты предыдущих этапов сохранены."
            return Outcome(code: 1, event: WorkerEvent(command: command, type: "failed", message: safe))
        }
    }

    /// Diagram recognition runs on the same one-process lifecycle, control and
    /// protocol channel as audio; only the engine differs.
    private static func runDiagram(command: WorkerCommand, output: FileHandle, control: WorkerControl) async -> Outcome {
        guard let diagramPath = command.diagramPath, command.stage == nil, command.recordingPath == nil,
              command.anonymizationPath == nil else { return Outcome(code: 64) }
        let emit: @Sendable (String, String, String?) -> Void = { type, message, artifact in
            write(WorkerEvent(command: command, type: type, message: message, artifact: artifact), to: output)
        }
        await control.watchInput { emit("cancelled", "Обработка отменена", nil); terminateGroup(72) }
        do {
            emit("started", "", nil)
            let started = Date()
            let engine = try DiagramEngine(command: command, diagramPath: diagramPath, emit: emit)
            let artifact = try await engine.recognize()
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            let metrics: [String: Double] = ["seconds": Date().timeIntervalSince(started), "maxResidentBytes": Double(usage.ru_maxrss)]
            // Metrics are diagnostics only; a failed write must not fail a finished stage.
            try? Disk.write(metrics, to: engine.run.appendingPathComponent("metrics-diagram.json"))
            return Outcome(code: 0, event: WorkerEvent(command: command, type: "completed", artifact: artifact))
        } catch {
            let safe = (error as? ScribeError)?.localizedDescription ?? "Локальный этап завершился ошибкой. Результаты предыдущих этапов сохранены."
            return Outcome(code: 1, event: WorkerEvent(command: command, type: "failed", message: safe))
        }
    }

    /// Text anonymization runs on the same one-process lifecycle, control and
    /// protocol channel. The document text and the complete result travel
    /// through the attempt's local working artifacts; the protocol carries
    /// identifiers, progress and safe statuses only.
    private static func runAnonymization(command: WorkerCommand, output: FileHandle, control: WorkerControl) async -> Outcome {
        guard command.anonymizationPath != nil, command.stage == nil, command.recordingPath == nil,
              command.diagramPath == nil else { return Outcome(code: 64) }
        let emit: @Sendable (String, String, String?) -> Void = { type, message, artifact in
            write(WorkerEvent(command: command, type: type, message: message, artifact: artifact), to: output)
        }
        await control.watchInput { emit("cancelled", "Обработка отменена", nil); terminateGroup(72) }
        do {
            emit("started", "", nil)
            // Input validation happens before any progress: a missing or
            // mismatched input keeps the started → failed event contract.
            let input = try AnonymizationEngine.loadInput(command: command)
            try Task.checkCancellation()
            emit("progress", "Проверяем задание обезличивания…", nil)
            let started = Date()
            let engine = try AnonymizationEngine(command: command, input: input, emit: emit)
            let outcome = try await engine.run()
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            var metrics = outcome.metrics
            metrics["seconds"] = Date().timeIntervalSince(started)
            metrics["maxResidentBytes"] = Double(usage.ru_maxrss)
            // Metrics are diagnostics only; a failed write must not fail a finished stage.
            try? Disk.write(metrics, to: engine.attemptURL.appendingPathComponent("metrics-anonymization.json"))
            return Outcome(code: 0, event: WorkerEvent(command: command, type: "completed", artifact: AnonymizationRunArtifact.filename))
        } catch {
            let safe = (error as? ScribeError)?.localizedDescription ?? "Локальный этап завершился ошибкой. Результаты предыдущих этапов сохранены."
            return Outcome(code: 1, event: WorkerEvent(command: command, type: "failed", message: safe))
        }
    }

    /// Developer diagnostic for the diagram recognizer chain: prints the raw
    /// load/generation error without the neutral production wrapper. Arguments:
    /// model folder, image path. Never receives user archive content.
    private static func probeDiagram(output: FileHandle) async -> Int32 {
        do {
            let recognizer = MLXDiagramRecognizer(folder: URL(fileURLWithPath: CommandLine.arguments[2]))
            let started = Date()
            let answer = try await recognizer.generate(prompt: DiagramEngine.systemPrompt,
                image: .original(URL(fileURLWithPath: CommandLine.arguments[3])), maxTokens: DiagramEngine.maxOutputTokens)
            if CommandLine.arguments.count > 4 {
                try answer.output.write(toFile: CommandLine.arguments[4], atomically: true, encoding: .utf8)
            }
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            let metrics: [String: String] = ["status": "ok", "seconds": String(Date().timeIntervalSince(started)),
                "finished": String(answer.finished), "prefix": String(answer.output.prefix(200)),
                "maxResidentBytes": String(usage.ru_maxrss)]
            try output.write(contentsOf: JSONEncoder().encode(metrics) + Data([10]))
            return 0
        } catch {
            let text = ["status": "failed", "error": "\(error)", "type": String(describing: type(of: error))]
            if let data = try? JSONEncoder().encode(text) { try? output.write(contentsOf: data + Data([10])) }
            return 1
        }
    }

    /// Developer qualification probe for the anonymization pipeline
    /// (docs/TextAnonymization/Qualification.md): resolves the profile pinned
    /// in the input artifact from the catalog, verifies package identity,
    /// hardware compatibility and the full size/SHA of the installed files,
    /// then runs the real recognizer pipeline and reports the raw result or
    /// error without the neutral production wrapper. The catalog ANONYMIZATION
    /// gate is bypassed on purpose — the probe qualifies profiles before the
    /// task is stamped. Arguments: models root, input.json path, optional
    /// result.json output path. The worker network denial applies, so the
    /// probe run is offline by construction.
    private static func probeAnonymization(output: FileHandle) async -> Int32 {
        do {
            let started = Date()
            let models = URL(fileURLWithPath: CommandLine.arguments[2])
            let inputURL = URL(fileURLWithPath: CommandLine.arguments[3])
            let input: AnonymizationAttemptInput
            do { input = try Disk.read(AnonymizationAttemptInput.self, at: inputURL) }
            catch { throw ScribeError.message("Не удалось прочитать вход пробы обезличивания") }
            try input.validate()
            guard let profile = try AnonymizationEngine.lookupPinnedProfile(models: models, toolsPath: nil, input: input, task: nil) else {
                throw ScribeError.message("Закреплённая модель обезличивания недоступна в каталоге")
            }
            try AnonymizationEngine.verifyResolved(profile: profile, models: models, input: input)
            let workspace = inputURL.deletingLastPathComponent()
            let command = WorkerCommand(anonymizationJobId: input.fileId, runId: input.attemptId,
                                        anonymizationPath: workspace.path, modelsPath: models.path)
            let engine = try AnonymizationEngine(command: command, input: input, resolvedProfile: profile) { type, message, _ in
                fputs("probe-anonymization \(type): \(message)\n", stderr)
            }
            let outcome = try await engine.run()
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            var metrics: [String: String] = ["status": "ok",
                "seconds": String(Date().timeIntervalSince(started)),
                "maxResidentBytes": String(usage.ru_maxrss)]
            for (key, value) in outcome.metrics { metrics[key] = String(format: "%.0f", value) }
            try output.write(contentsOf: JSONEncoder().encode(metrics) + Data([10]))
            if CommandLine.arguments.count > 4 {
                let resultURL = workspace.appendingPathComponent(AnonymizationRunArtifact.filename)
                let target = URL(fileURLWithPath: CommandLine.arguments[4])
                if target.path != resultURL.path {
                    try Data(contentsOf: resultURL).write(to: target)
                }
            }
            return 0
        } catch {
            let text = ["status": "failed", "error": "\(error)", "type": String(describing: type(of: error))]
            if let data = try? JSONEncoder().encode(text) { try? output.write(contentsOf: data + Data([10])) }
            return 1
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
