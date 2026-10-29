import XCTest
import AVFoundation
import MLX
@testable import LocalScribeCore
@testable import LocalScribeWorker

final class QwenPipelineFixtureTests: XCTestCase {
    func testPinnedLocalQwenOfflineCheckpointAndResume() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["LOCALSCRIBE_QWEN_LIBRARY"], let wavePath = env["LOCALSCRIBE_QWEN_WAV"] else {
            throw XCTSkip("Set LOCALSCRIBE_QWEN_LIBRARY to a fully verified pinned model library and LOCALSCRIBE_QWEN_WAV to mono/16 kHz technical audio. Deny network for the test process.")
        }
        let variant = env["LOCALSCRIBE_QWEN_VARIANT"] ?? "bf16"
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let catalog = try Disk.read(ModelCatalog.self, at: sourceRoot.appendingPathComponent("Resources/models.lock.json"))
        let asr = try XCTUnwrap(catalog.models.first { $0.id == "asr-qwen3-1.7b-" + variant })
        let selected = ModelCatalog(models: try [asr.id, "diarization", "summary", "tokenizer-qwen3", try XCTUnwrap(asr.alignerID)].map { id in
            try XCTUnwrap(catalog.models.first { $0.id == id })
        })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(root: root.appendingPathComponent("archive"))
        let wave = URL(fileURLWithPath: wavePath), file = try AVAudioFile(forReading: wave)
        let duration = Int((Double(file.length) / 16).rounded())
        var manifest = Manifest(sourceType: "import", title: "Technical Qwen fixture", filename: "audio.wav")
        manifest.durationMs = duration; manifest.sha256 = try Disk.hash(wave); manifest.sourceComplete = true
        let original = repository.folder(manifest.id).appendingPathComponent(manifest.originalRelativePath)
        try Disk.directory(original.deletingLastPathComponent()); try FileManager.default.copyItem(at: wave, to: original)
        let info = try repository.beginRun(&manifest, catalog: selected)
        let run = repository.run(manifest.id, info.id)
        try Disk.directory(run.appendingPathComponent("work")); try FileManager.default.copyItem(at: wave, to: run.appendingPathComponent("work/audio.wav"))
        let resources = root.appendingPathComponent("Resources")
        try Disk.write(catalog, to: resources.appendingPathComponent("models.lock.json"))
        let command = WorkerCommand(jobId: manifest.id, runId: info.id, stage: .transcribing,
            recordingPath: repository.folder(manifest.id).path, modelsPath: path, toolsPath: resources.appendingPathComponent("tools").path)
        let start = ProcessInfo.processInfo.systemUptime
        let pipeline = try Pipeline(command: command, emit: { _, _, _ in })
        do { _ = try await pipeline.perform() }
        catch {
            if let destination = env["LOCALSCRIBE_QWEN_OUTPUT"] {
                let output = URL(fileURLWithPath: destination)
                let safe = (error as? ScribeError)?.localizedDescription ?? "SDK stage failed (details discarded)"
                try Disk.write(["reason": safe, "status": "failed"], to: output.appendingPathComponent("failure.json"))
                if let metrics = try? Data(contentsOf: run.appendingPathComponent("metrics-asr.json")) {
                    try Disk.directory(output); try metrics.write(to: output.appendingPathComponent("metrics-asr.json"))
                }
            }
            throw error
        }
        let ended = ProcessInfo.processInfo.systemUptime
        let inferenceMetrics = try Data(contentsOf: run.appendingPathComponent("metrics-asr.json"))
        let transcript = try Disk.read(Transcript.self, at: run.appendingPathComponent("asr-transcript.json"))
        XCTAssertFalse(transcript.segments.isEmpty)
        try transcript.validate(durationMs: duration)
        let checkpoint = run.appendingPathComponent("asr/part-0.json"), hash = try Disk.hash(checkpoint)
        let failLoading = ASREngineFactory(loadWhisper: { _, _, _, _ in XCTFail("Whisper selected for Qwen"); throw CancellationError() },
            loadQwen: { _, _, _, _ in QwenASREngine(transcribe: { _ in XCTFail("checkpoint was not reused"); throw CancellationError() }, align: { _, _ in [] }) })
        let resumed = try Pipeline(command: command, engineFactory: failLoading, emit: { _, _, _ in })
        _ = try await resumed.perform()
        XCTAssertEqual(try Disk.hash(checkpoint), hash)
        XCTAssertEqual(try Disk.hash(original), manifest.sha256)
        if let destination = env["LOCALSCRIBE_QWEN_OUTPUT"] {
            let output = URL(fileURLWithPath: destination)
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            try Disk.directory(output)
            try inferenceMetrics.write(to: output.appendingPathComponent("metrics-asr.json"))
            try Disk.write(["seconds": ended-start, "mlxPeakBytes": Double(Memory.peakMemory), "maxResidentBytes": Double(usage.ru_maxrss),
                            "segments": Double(transcript.segments.count), "wordTimings": Double(transcript.segments.flatMap(\.words).count)], to: output.appendingPathComponent("pipeline-measurement.json"))
            try Disk.write(transcript, to: output.appendingPathComponent("pipeline-transcript.json"))
            // The second invocation above checks checkpoint reuse; retain its
            // counters separately from the original inference measurement.
            let metrics = try Data(contentsOf: run.appendingPathComponent("metrics-asr.json"))
            try metrics.write(to: output.appendingPathComponent("resume-metrics-asr.json"))
        }
    }
}
