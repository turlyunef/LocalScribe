import XCTest
import LocalScribeCore
@testable import LocalScribeWorker

/// Opt-in end-to-end probe with the real pinned VLM weights: the real worker
/// binary, the real diagram archive layout, the real XPC-free model folder.
/// Requires LOCALSCRIBE_DIAGRAM_FIXTURE_MODELS (model folder whose name matches
/// the lock profile id's last component) and LOCALSCRIBE_DIAGRAM_FIXTURE_IMAGES
/// (labeled PNG set that was NOT used to tune the prompt).
///
/// Reproduction:
///   LOCALSCRIBE_DIAGRAM_FIXTURE_MODELS=TestResults/vlm-spike/model \
///   LOCALSCRIBE_DIAGRAM_FIXTURE_IMAGES=TestResults/diagram-fixtures \
///   swift test -c release --force-resolved-versions --filter DiagramVLMFixtureTests
final class DiagramVLMFixtureTests: XCTestCase {
    private struct Probe {
        let exitCode: Int32
        let events: [WorkerEvent]
        let result: DiagramResult?
    }

    private func runWorker(command: WorkerCommand) throws -> Probe {
        let binary = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/release/LocalScribeWorker")
        let process = Process()
        process.executableURL = binary
        process.arguments = []
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()  // drain without saving: may hold content
        process.environment = ["HF_HUB_OFFLINE": "1", "HF_HUB_DISABLE_TELEMETRY": "1", "TOKENIZERS_PARALLELISM": "false"]
        try process.run()
        let commandData = try JSONEncoder().encode(command) + Data([10])
        try input.fileHandleForWriting.write(contentsOf: commandData)
        // EOF on stdin means cancellation in the real protocol; the parent
        // keeps the write end open until the worker exits on its own.
        let data = try output.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        try? input.fileHandleForWriting.close()
        let events = String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { try? JSONDecoder().decode(WorkerEvent.self, from: Data($0.utf8)) }
        return Probe(exitCode: process.terminationStatus, events: events, result: nil)
    }

    /// Imports the fixture through the real repository (ImageIO checks, SHA),
    /// freezes a run against the lock profile and runs the real worker.
    private func recognize(_ image: URL, archive: URL, models: URL, profile: ModelProfile) throws -> (DiagramManifest, DiagramRunInfo, Probe) {
        let repository = try DiagramRepository(root: archive)
        var manifest = try repository.importImage(at: image)
        let frozen = try repository.beginRun(&manifest, profile: profile)
        let command = WorkerCommand(diagramJobId: manifest.id, runId: frozen.id,
                                    diagramPath: repository.folder(manifest.id).path,
                                    modelsPath: models.path, toolsPath: nil)
        return (manifest, frozen, try runWorker(command: command))
    }

    func testRealWorkerRecognizesIndependentLabeledFixtures() async throws {
        let environment = ProcessInfo.processInfo.environment
        let modelsRoot = environment["LOCALSCRIBE_DIAGRAM_FIXTURE_MODELS"].map { URL(fileURLWithPath: $0) }
        let imagesRoot = environment["LOCALSCRIBE_DIAGRAM_FIXTURE_IMAGES"].map { URL(fileURLWithPath: $0) }
        guard let modelsRoot, let imagesRoot else {
            throw XCTSkip("Set LOCALSCRIBE_DIAGRAM_FIXTURE_MODELS and LOCALSCRIBE_DIAGRAM_FIXTURE_IMAGES")
        }
        // The lock profile resolves the model folder name; weights live beside the test archive.
        let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let catalog = try Disk.read(ModelCatalog.self, at: packageRoot.appendingPathComponent("Resources/models.lock.json"))
        let profile = try XCTUnwrap(catalog.models.first { $0.purpose == .diagram }, "в каталоге нет профиля схем")
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("diagram-vlm-\(UUID().uuidString)")
        let archive = base.appendingPathComponent("diagrams"), models = base.appendingPathComponent("models")
        defer { try? FileManager.default.removeItem(at: base) }
        try Disk.directory(models)
        // Per-file hard links keep the 3 GiB weights un-copied. A symlinked
        // folder breaks the VLM weight loader (keys go missing), and the
        // shipping installer always materializes real files.
        let modelFolder = models.appendingPathComponent(profile.id)
        try Disk.directory(modelFolder)
        for file in profile.files {
            let source = modelsRoot.appendingPathComponent(file.localPath)
            let destination = modelFolder.appendingPathComponent(file.localPath)
            do { try FileManager.default.linkItem(at: source, to: destination) }
            catch { try FileManager.default.copyItem(at: source, to: destination) }
        }
        try FileManager.default.copyItem(at: packageRoot.appendingPathComponent("Resources/models.lock.json"), to: base.appendingPathComponent("models.lock.json"))
        try profile.validate(at: models)

        // A simple Russian flowchart: nodes, labels and directions are asserted.
        let ruStarted = Date()
        let (ruManifest, ruRun, ruProbe) = try recognize(imagesRoot.appendingPathComponent("ru.png"), archive: archive, models: models, profile: profile)
        if ruProbe.exitCode != 0 || !ruProbe.events.contains(where: { $0.type == "completed" }) {
            for event in ruProbe.events { print("DiagramVLMFixtureTests ru event:", event.type, event.message) }
        }
        XCTAssertEqual(ruProbe.exitCode, 0)
        XCTAssertTrue(ruProbe.events.contains { $0.type == "completed" })
        let ruResult = try Disk.read(DiagramResult.self, at: archive.appendingPathComponent("items/\(ruManifest.id)/runs/\(ruRun.id)/result.json"))
        try ruResult.validate(expectedFingerprint: ruRun.fingerprint)
        let ruLabels = Set(ruResult.nodes.map(\.label))
        for expected in ["Подача заявки", "Проверка документов", "Доработка", "Одобрение"] {
            XCTAssertTrue(ruLabels.contains(expected), "нет узла \(expected): \(ruLabels)")
        }
        let ru = DiagramExport.plantuml(ruResult, title: ruManifest.displayTitle)
        XCTAssertTrue(ru.text.hasPrefix("@startuml"))

        // A simple English architecture diagram.
        let (enManifest, enRun, enProbe) = try recognize(imagesRoot.appendingPathComponent("en.png"), archive: archive, models: models, profile: profile)
        XCTAssertEqual(enProbe.exitCode, 0)
        let enResult = try Disk.read(DiagramResult.self, at: archive.appendingPathComponent("items/\(enManifest.id)/runs/\(enRun.id)/result.json"))
        try enResult.validate(expectedFingerprint: enRun.fingerprint)
        let enLabels = Set(enResult.nodes.map(\.label))
        for expected in ["Browser", "Load Balancer", "Web Server", "PostgreSQL"] {
            XCTAssertTrue(enLabels.contains(expected), "нет узла \(expected): \(enLabels)")
        }

        // A denser crossing diagram: structural validity only, edges are
        // recorded numerically instead of a hard quality bar.
        let (crossManifest, crossRun, crossProbe) = try recognize(imagesRoot.appendingPathComponent("cross.png"), archive: archive, models: models, profile: profile)
        XCTAssertEqual(crossProbe.exitCode, 0)
        let crossResult = try Disk.read(DiagramResult.self, at: archive.appendingPathComponent("items/\(crossManifest.id)/runs/\(crossRun.id)/result.json"))
        try crossResult.validate(expectedFingerprint: crossRun.fingerprint)
        XCTAssertFalse(crossResult.edges.isEmpty)

        // A photo without a diagram must fail with the explained refusal.
        let (photoManifest, photoRun, photoProbe) = try recognize(imagesRoot.appendingPathComponent("photo.png"), archive: archive, models: models, profile: profile)
        XCTAssertEqual(photoProbe.exitCode, 1)
        XCTAssertTrue(photoProbe.events.contains { $0.type == "failed" && $0.message.contains("не похоже на схему") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.appendingPathComponent("items/\(photoManifest.id)/runs/\(photoRun.id)/result.json").path))

        // Anonymized timing for the report; no label text leaves the machine here.
        let ruSeconds = Date().timeIntervalSince(ruStarted)
        print("DiagramVLMFixtureTests: ru+en+cross+photo total seconds ≈ \(Int(ruSeconds + 1))")
    }
}
