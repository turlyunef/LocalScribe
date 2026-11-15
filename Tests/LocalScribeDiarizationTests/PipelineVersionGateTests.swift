import XCTest
@testable import LocalScribeCore
@testable import LocalScribeWorker

/// The pipeline-version gate must protect the checkpoints of every stage,
/// not only transcription: summary and diarization checkpoints are keyed by
/// the run fingerprint, which does not move when only a prompt literal
/// changes between builds, so a resumed run saved by an older pipeline has
/// to be rejected before any stage work starts.
final class PipelineVersionGateTests: XCTestCase {
    /// Stage-specific decoy checkpoints that only a started stage would read.
    private let decoysByStage: [Stage: [String]] = [
        .preparingAudio: ["prepared.json"],
        .diarizing: ["asr-transcript.json", "diarization.json"],
        .summarizing: ["transcript.json", "summary-parts/part-0.json"],
    ]

    private func makeFixture(root: URL) throws -> (repo: RecordingRepository, manifest: Manifest, info: RunInfo, run: URL) {
        let repo = try RecordingRepository(root: root)
        var manifest = Manifest(sourceType: "import", title: "Version gate", filename: "audio.wav")
        let original = repo.folder(manifest.id).appendingPathComponent(manifest.originalRelativePath)
        try Disk.directory(original.deletingLastPathComponent())
        try Data("fixture audio".utf8).write(to: original)
        manifest.sha256 = try Disk.hash(original)
        manifest.durationMs = 1000
        manifest.sourceComplete = true
        let info = try repo.beginRun(&manifest, catalog: ModelCatalog(models: []))
        return (repo, manifest, info, repo.run(manifest.id, info.id))
    }

    func testOldPipelineVersionIsRejectedForEveryResumedStage() throws {
        for stage in [Stage.preparingAudio, .diarizing, .summarizing] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let (repo, manifest, info, run) = try makeFixture(root: root)
            var stale = info
            stale.pipelineVersion = "0.0.0-audio1"
            try Disk.write(stale, to: run.appendingPathComponent("run.json"))
            let decoys = (decoysByStage[stage] ?? []).map { run.appendingPathComponent($0) }
            for decoy in decoys {
                try Disk.directory(decoy.deletingLastPathComponent())
                try Disk.write(["stale": true], to: decoy)
            }
            let before = try decoys.map { try Data(contentsOf: $0) }
            let command = WorkerCommand(jobId: manifest.id, runId: info.id, stage: stage,
                recordingPath: repo.folder(manifest.id).path, modelsPath: repo.models.path, toolsPath: root.path)
            do {
                _ = try Pipeline(command: command) { _, _, _ in }
                XCTFail("Старая версия конвейера принята на стадии \(stage.rawValue)")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("Версия обработки изменилась"),
                    "стадия \(stage.rawValue): \(error.localizedDescription)")
            }
            // The rejected command never read or rewrote a checkpoint.
            XCTAssertEqual(try decoys.map { try Data(contentsOf: $0) }, before)
            XCTAssertFalse(FileManager.default.fileExists(atPath: run.appendingPathComponent("summary.json").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: run.appendingPathComponent("metrics-\(stage.rawValue).json").path))
        }
    }

    func testCurrentPipelineVersionStillConstructsForEveryStage() throws {
        // Control: the same fixture without the version mutation must pass
        // init, so the gate rejects only genuinely stale runs.
        for stage in [Stage.preparingAudio, .diarizing, .summarizing] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let (repo, manifest, info, _) = try makeFixture(root: root)
            let command = WorkerCommand(jobId: manifest.id, runId: info.id, stage: stage,
                recordingPath: repo.folder(manifest.id).path, modelsPath: repo.models.path, toolsPath: root.path)
            _ = try Pipeline(command: command) { _, _, _ in }
        }
    }
}
