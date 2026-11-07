import XCTest
@testable import LocalScribeCore
@testable import LocalScribeWorker

@MainActor
final class ModelHardwareWorkerTests: XCTestCase {
    func testSummaryStageRejectsForeignFingerprintEvenForEmptyTranscript() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root)
        var manifest = Manifest(sourceType: "import", title: "Fixture", filename: "audio.wav")
        let source = repo.folder(manifest.id).appendingPathComponent(manifest.originalRelativePath)
        try Disk.directory(source.deletingLastPathComponent()); try Data("audio".utf8).write(to: source)
        manifest.sha256 = try Disk.hash(source); manifest.sourceComplete = true; manifest.durationMs = 1000
        let info = try repo.beginRun(&manifest, catalog: ModelCatalog(models: []))
        let transcriptURL = repo.run(manifest.id, info.id).appendingPathComponent("transcript.json")
        try Disk.write(Transcript(fingerprint: "foreign", diarized: true, segments: []), to: transcriptURL)
        let command = WorkerCommand(jobId: manifest.id, runId: info.id, stage: .summarizing,
            recordingPath: repo.folder(manifest.id).path, modelsPath: repo.models.path, toolsPath: root.path)
        let pipeline = try Pipeline(command: command) { _, _, _ in }
        do { _ = try await pipeline.summaryTranscript(); XCTFail("Foreign fingerprint accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("целостность")) }
        try Disk.write(Transcript(fingerprint: info.fingerprint, diarized: true, segments: []), to: transcriptURL)
        let valid = try await pipeline.summaryTranscript()
        XCTAssertTrue(valid.segments.isEmpty)
    }

    func testWorkerRejectsFrozenHeavyModelBeforeLoadingWithoutChangingRunOrCheckpoints() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root.appendingPathComponent("data"))
        var manifest = Manifest(sourceType: "import", title: "Hardware fixture", filename: "audio.wav")
        let original = repo.folder(manifest.id).appendingPathComponent(manifest.originalRelativePath)
        try Disk.directory(original.deletingLastPathComponent()); try Data("audio".utf8).write(to: original)
        manifest.sha256 = try Disk.hash(original); manifest.sourceComplete = true; manifest.durationMs = 1000
        let profiles = ModelRole.audioRoles.map { role in
            ModelProfile(id: role.rawValue, repository: "fixture/model", revision: "fixed", license: "test", files: [], role: role,
                         recommendedMemoryGB: role == .summary ? 128 : 8, workingMemoryGB: role == .summary ? 88 : 2)
        }
        let catalog = ModelCatalog(models: profiles)
        let info = try repo.beginRun(&manifest, catalog: catalog)
        let resources = root.appendingPathComponent("Resources")
        try Disk.write(catalog, to: resources.appendingPathComponent("models.lock.json"))
        let checkpoint = repo.run(manifest.id, info.id).appendingPathComponent("summary-parts/keep.json")
        try Disk.write(["keep": "checkpoint"], to: checkpoint)
        let runURL = repo.run(manifest.id, info.id).appendingPathComponent("run.json")
        let manifestURL = repo.folder(manifest.id).appendingPathComponent("manifest.json")
        let before = try [runURL, manifestURL, checkpoint].map { try Data(contentsOf: $0) }
        let command = WorkerCommand(jobId: manifest.id, runId: info.id, stage: .summarizing,
            recordingPath: repo.folder(manifest.id).path, modelsPath: repo.models.path, toolsPath: resources.appendingPathComponent("tools").path)
        let hardware = ModelHardware(chip: "Fixture M1", memoryBytes: 16 * 1_073_741_824, cpuCores: 8,
            gpuWorkingSetBytes: 12 * 1_073_741_824, appleSilicon: true, supportsMetal: true)
        let pipeline = try Pipeline(command: command, hardware: hardware) { _, _, _ in }
        do { _ = try await pipeline.perform(); XCTFail("Heavy model must fail before attempting a model or transcript load") }
        catch { XCTAssertTrue(error.localizedDescription.contains("128 ГБ")) }
        XCTAssertEqual(try [runURL, manifestURL, checkpoint].map { try Data(contentsOf: $0) }, before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.run(manifest.id, info.id).appendingPathComponent("summary.json").path))
    }
}
