import XCTest
@testable import LocalScribeCore
@testable import LocalScribeWorker

final class ASRMetricsTests: XCTestCase {
    func testContextReviewMetricsAreOptionalForHistoricalAndProductionDiagnostics() throws {
        let metrics = ASRMetrics(liveCapture: false)
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let legacy = try encoder.encode(metrics)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: legacy) as? [String: Any])
        XCTAssertNil(json["contextReview"])
        XCTAssertNil(try decoder.decode(ASRMetrics.self, from: legacy).contextReview)
        var reviewed = try decoder.decode(ASRMetrics.self, from: legacy)
        reviewed.update(.contextReview) { $0.inputs.add(30000) }
        let saved = try decoder.decode(ASRMetrics.self, from: encoder.encode(reviewed))
        XCTAssertEqual(saved.contextReview?.inputs.count, 1)
        XCTAssertEqual(saved.primary.inputs.count, 0)
    }

    func testPipelineModelLoadFailureFinishesMetricsWithoutChangingRunOrManifest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordingRepository(root: root.appendingPathComponent("archive"))
        var manifest = Manifest(sourceType: "import", title: "ASR metrics fixture", filename: "source.wav")
        let original = repository.folder(manifest.id).appendingPathComponent(manifest.originalRelativePath)
        try Disk.directory(original.deletingLastPathComponent())
        try Data("fixture".utf8).write(to: original)
        manifest.sha256 = try Disk.hash(original); manifest.sourceComplete = true; manifest.durationMs = 1000
        let catalog = ModelCatalog(models: ModelRole.allCases.map {
            ModelProfile(id: $0.rawValue, repository: "fixture/model", revision: "fixture", license: "test", files: [], role: $0)
        })
        let info = try repository.beginRun(&manifest, catalog: catalog)
        let run = repository.run(manifest.id, info.id), resources = root.appendingPathComponent("Resources")
        try Disk.write(catalog, to: resources.appendingPathComponent("models.lock.json"))
        let manifestURL = repository.folder(manifest.id).appendingPathComponent("manifest.json")
        let before = try [manifestURL, run.appendingPathComponent("run.json")].map { try Data(contentsOf: $0) }
        let command = WorkerCommand(jobId: manifest.id, runId: info.id, stage: .transcribing,
            recordingPath: repository.folder(manifest.id).path, modelsPath: repository.models.path,
            toolsPath: resources.appendingPathComponent("tools").path)
        let hardware = ModelHardware(chip: "Fixture M1", memoryBytes: 16 * 1_073_741_824, cpuCores: 8,
            gpuWorkingSetBytes: 12 * 1_073_741_824, appleSilicon: true, supportsMetal: true)
        let pipeline = try Pipeline(command: command, hardware: hardware) { _, _, _ in }
        do { _ = try await pipeline.perform(); XCTFail("Missing tokenizer must fail") } catch { }
        let metrics = try Disk.read(ASRMetrics.self, at: run.appendingPathComponent("metrics-asr.json"))
        XCTAssertEqual(metrics.status, "failed")
        XCTAssertGreaterThan(metrics.modelLoadSeconds, 0)
        XCTAssertEqual(metrics.primary.inputs.count, 0)
        XCTAssertEqual(try [manifestURL, run.appendingPathComponent("run.json")].map { try Data(contentsOf: $0) }, before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.appendingPathComponent("asr-transcript.json").path))
    }

    func testUnwritableDiagnosticsDoNotFailRecognitionAccounting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not a directory".utf8).write(to: root)
        let metrics = ASRMetricsRecorder(run: root, liveCapture: false)
        metrics.window(milliseconds: 28000, silent: true)
        metrics.finish(status: "completed")
        XCTAssertEqual(metrics.value.status, "completed")
        XCTAssertEqual(metrics.value.silentWindows, 1)
        XCTAssertEqual(try Data(contentsOf: root), Data("not a directory".utf8))
    }
}
