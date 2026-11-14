import XCTest
import AppKit
import Synchronization
import UniformTypeIdentifiers
@testable import LocalScribeCore
@testable import LocalScribe

/// Diagram jobs share the single typed FIFO and worker slot with recordings.
/// A process fixture exercises the real supervisor, diagram command routing
/// and result validation without models or a real VLM.
@MainActor
final class DiagramWorkspaceTests: XCTestCase {
    private func fixture(_ root: URL, installDiagram: Bool = true) throws -> (RecordingRepository, AppModel, URL) {
        var repo = try RecordingRepository(root: root)
        let executable = root.appendingPathComponent("worker.py")
        let script = #"""
        #!/usr/bin/python3
        import sys, json, pathlib, time, hashlib
        c = json.loads(sys.stdin.readline())
        root = pathlib.Path(c['modelsPath']).parent
        def emit(kind, message=''):
            print(json.dumps(dict(version=1, jobId=c['jobId'], runId=c['runId'], kind=c.get('kind'), type=kind, message=message)), flush=True)
        with (root / 'events.jsonl').open('a') as f:
            f.write(json.dumps(c) + '\n')
        if c.get('kind') == 'diagram':
            run = pathlib.Path(c['diagramPath']) / 'runs' / c['runId']
            if (root / 'diagram-fail').exists():
                emit('failed', 'Тестовая ошибка распознавания')
                sys.exit(1)
            emit('progress', 'diagram-ready-' + c['jobId'])
            while not (root / 'release').exists() or (root / ('hold-' + c['jobId'])).exists():
                time.sleep(0.02)
            if (root / 'diagram-warning').exists():
                warning = (root / 'diagram-warning').read_text()
                emit('warning', warning)
                emit('warning', warning)
            info = json.loads((run / 'run.json').read_text())
            fingerprint = hashlib.sha256((info['sourceHash'] + info['profileHash'] + info['pipelineVersion'] + info['promptVersion'] + info['preprocessingVersion']).encode()).hexdigest()
            label = (root / 'diagram-label').read_text() if (root / 'diagram-label').exists() else 'Проверка'
            result = dict(schemaVersion=1, fingerprint=fingerprint, language='ru',
                nodes=[dict(id='n1', label='Начало', uncertain=False), dict(id='n2', label=label, uncertain=False)],
                edges=[{'from': 'n1', 'to': 'n2', 'direction': 'forward', 'label': 'да', 'uncertain': False}])
            (run / 'result.json').write_text(json.dumps(result))
            emit('completed')
            sys.exit(0)
        run = pathlib.Path(c['recordingPath']) / 'runs' / c['runId']
        if (root / 'warnings').exists():
            for number in range(12):
                emit('warning', 'Test warning ' + str(number))
        emit('progress', 'fixture-ready-' + c['jobId'])
        while not (root / 'release').exists() or (root / ('hold-' + c['jobId'])).exists():
            time.sleep(0.02)
        if c.get('liveCapture'):
            if (root / 'live-success').exists():
                emit('completed')
                sys.exit(0)
            emit('failed', 'Тестовая ошибка модели')
            sys.exit(1)
        info = json.loads((run / 'run.json').read_text())
        fingerprint = hashlib.sha256((info['sourceHash'] + info['profileHash'] + info['pipelineVersion']).encode()).hexdigest()
        if c['stage'] == 'preparingAudio':
            (run / 'transcript.json').write_text(json.dumps(dict(schemaVersion=1, fingerprint=fingerprint, diarized=True, segments=[])))
        elif c['stage'] == 'summarizing':
            (run / 'summary.json').write_text(json.dumps(dict(schemaVersion=1, language=info.get('summaryLanguage') or 'ru', overview=[], decisions=[], tasks=[], openQuestions=[])))
        emit('completed')
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        var profiles = ModelRole.audioRoles.map { role in
            ModelProfile(id: role.rawValue, repository: "test/model", revision: "test-revision", license: "test", files: [], role: role)
        }
        profiles += [ModelProfile(id: "asr-b", repository: "test/model", revision: "test-revision", license: "test", files: [], role: .asr)]
        profiles += [ModelProfile(id: "diagram-vlm", repository: "test/vlm", revision: "test-revision", license: "test", files: [], role: .diagram)]
        for index in profiles.indices {
            let data = Data(profiles[index].id.utf8)
            let folder = repo.models.appendingPathComponent(profiles[index].id)
            try Disk.directory(folder)
            let file = folder.appendingPathComponent("weights.bin")
            try data.write(to: file)
            profiles[index].files = [ModelFile(path: "weights.bin", localPath: "weights.bin", size: Int64(data.count), sha256: try Disk.hash(file))]
        }
        let catalog = ModelCatalog(models: profiles)
        let suite = "LocalScribeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let model = AppModel(repository: repo, startServices: false, workerExecutable: executable, userDefaults: defaults, catalog: catalog)
        for profile in profiles where profile.purpose != .diagram || installDiagram {
            model.modelLibrary.installed(profile, catalog: catalog)
        }
        try model.modelLibrary.select(profiles[0], catalog: catalog)
        model.modelsReady = true
        XCTAssertNotNil(model.activeCatalog)
        XCTAssertEqual(model.diagramModelsReady, installDiagram)
        return (repo, model, root.appendingPathComponent("release"))
    }
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !predicate() && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(predicate())
    }
    private func imageData(width: Int = 4, height: Int = 4, type: UTType = .png) throws -> Data {
        let output = NSMutableData()
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
            throw ScribeError.message("Не удалось создать тестовое изображение")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ScribeError.message("Не удалось записать тестовое изображение") }
        return output as Data
    }
    private func importPNG(_ model: AppModel, groupID: String = RecordingGroup.ungroupedID) async throws -> DiagramManifest {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("diagram-\(UUID().uuidString).png")
        try imageData().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try await model.importDiagramImage(at: url, groupID: groupID, allowDuplicate: true)
    }
    private func events(_ root: URL) throws -> [WorkerCommand] {
        try String(contentsOf: root.appendingPathComponent("events.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try JSONDecoder().decode(WorkerCommand.self, from: Data($0.utf8)) }
    }
    private func completedRecording(_ repo: RecordingRepository, title: String) throws -> Manifest {
        var m = Manifest(sourceType: "microphone", title: title, filename: "original.caf")
        m.sourceComplete = true; m.sha256 = String(repeating: "a", count: 64); m.durationMs = 1000
        try repo.save(m); return m
    }

    func testBatchContinuesAfterInvalidImageAndResolvesDuplicatesAcrossGroupsInImportOrder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, model, release) = try fixture(root)
        let workspace = DiagramWorkspaceModel(model: model)
        await model.changeDiagramGroups { try $0.create(name: "Исходные") }
        let originalGroup = model.diagramGroups.defaultID
        let first = root.appendingPathComponent("first.png")
        try imageData().write(to: first)
        workspace.importURLs([first])
        await model.importQueue.waitUntilIdle()
        let original = try XCTUnwrap(model.diagrams.first)
        try await waitUntil { model.diagram(original.id)?.state == .recognizing }

        await model.changeDiagramGroups { try $0.create(name: "Партия") }
        let batchGroup = model.diagramGroups.defaultID
        let second = root.appendingPathComponent("second.png")
        let invalid = root.appendingPathComponent("invalid.png")
        let duplicate = root.appendingPathComponent("same-bytes.png")
        let third = root.appendingPathComponent("third.jpeg")
        let data = try imageData(width: 5)
        try data.write(to: second)
        try Data("invalid".utf8).write(to: invalid)
        try data.write(to: duplicate)
        try imageData(type: .jpeg).write(to: third)

        var duplicateIDs: [String] = []
        workspace.resolveDuplicateImport = { item in duplicateIDs.append(item.id); return .cancel }
        workspace.importURLs([second, invalid, duplicate, third])
        await model.importQueue.waitUntilIdle()
        let importedSecond = try XCTUnwrap(model.diagrams.first { $0.originalFilename == "second.png" })
        let importedThird = try XCTUnwrap(model.diagrams.first { $0.originalFilename == "third.jpeg" })
        XCTAssertEqual(duplicateIDs, [importedSecond.id])
        XCTAssertEqual(model.diagrams.count, 3)
        XCTAssertEqual(model.errorHandler.messages.count, 1)
        XCTAssertEqual(model.diagramQueuePosition(for: importedSecond.id), 1)
        XCTAssertEqual(model.diagramQueuePosition(for: importedThird.id), 2)
        XCTAssertEqual(model.diagramGroups.groupID(for: importedSecond.id), batchGroup)
        XCTAssertEqual(model.diagramGroups.groupID(for: importedThird.id), batchGroup)

        await model.changeDiagramGroups { try $0.setExpanded(originalGroup, false) }
        workspace.search.query = "third"
        await workspace.search.waitUntilIdle()
        workspace.resolveDuplicateImport = { item in duplicateIDs.append(item.id); return .openExisting }
        workspace.importURLs([first])
        await model.importQueue.waitUntilIdle()
        XCTAssertEqual(workspace.selection, original.id)
        XCTAssertEqual(workspace.sidebarRevealID, original.id)
        XCTAssertTrue(workspace.sidebarDiagramOrder.contains(original.id))
        XCTAssertEqual(model.diagramGroups.groupID(for: original.id), originalGroup)
        XCTAssertEqual(model.diagrams.count, 3)
        XCTAssertNil(model.diagramQueuePosition(for: original.id))

        workspace.resolveDuplicateImport = { item in duplicateIDs.append(item.id); return .importAgain }
        workspace.importURLs([first])
        await model.importQueue.waitUntilIdle()
        let retry = try XCTUnwrap(model.diagrams.first { $0.originalFilename == "first.png" && $0.id != original.id })
        XCTAssertEqual(duplicateIDs, [importedSecond.id, original.id, original.id])
        XCTAssertEqual(model.diagramGroups.groupID(for: retry.id), batchGroup)
        XCTAssertEqual(retry.sha256, original.sha256)
        XCTAssertEqual(model.diagramQueuePosition(for: retry.id), 3)
        let archive = try XCTUnwrap(model.diagramRepository)
        for item in model.diagrams {
            XCTAssertEqual(try Disk.hash(archive.originalURL(item)), item.sha256)
        }

        try Data().write(to: release)
        try await waitUntil { model.diagrams.allSatisfy { $0.state == .completed } }
        XCTAssertEqual(try events(root).map(\.jobId), [original.id, importedSecond.id, importedThird.id, retry.id])
        await model.shutdown()
    }

    func testDroppedBatchKeepsDeletedDestinationThroughDelayedProvidersAndDuplicateRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, model, _) = try fixture(root, installDiagram: false)
        let workspace = DiagramWorkspaceModel(model: model)
        await model.changeDiagramGroups { try $0.create(name: "Удаляемая") }
        let destination = model.diagramGroups.defaultID
        let first = root.appendingPathComponent("first.png")
        let duplicate = root.appendingPathComponent("duplicate.png")
        let data = try imageData()
        try data.write(to: first)
        try data.write(to: duplicate)
        let callbacks = Mutex<[Int: @Sendable (URL) -> Void]>([:])
        let providers = [0, 1].map { index in
            let provider = NSItemProvider()
            provider.registerObject(ofClass: NSURL.self, visibility: .all) { completion in
                callbacks.withLock { $0[index] = { completion($0 as NSURL, nil) } }
                return Progress(totalUnitCount: 1)
            }
            return provider
        }
        var duplicateID: String?
        workspace.resolveDuplicateImport = { duplicateID = $0.id; return .importAgain }

        XCTAssertTrue(workspace.importProviders(providers))
        try await waitUntil { callbacks.withLock { $0.count == 2 } }
        // Even if Finder's second provider responds first, the first file owns
        // the queue slot and the duplicate is checked only after it publishes.
        callbacks.withLock { $0.removeValue(forKey: 1) }?(duplicate)
        await model.deleteDiagramGroup(destination, deleteDiagrams: false)
        await model.changeDiagramGroups { try $0.create(name: "Новая по умолчанию") }
        XCTAssertNotEqual(model.diagramGroups.defaultID, destination)
        XCTAssertTrue(model.diagrams.isEmpty)
        callbacks.withLock { $0.removeValue(forKey: 0) }?(first)
        await model.importQueue.waitUntilIdle()

        let importedFirst = try XCTUnwrap(model.diagrams.first { $0.originalFilename == "first.png" })
        XCTAssertEqual(duplicateID, importedFirst.id)
        XCTAssertEqual(model.diagrams.count, 2)
        for item in model.diagrams {
            XCTAssertEqual(model.diagramGroups.groupID(for: item.id), RecordingGroup.ungroupedID)
            XCTAssertEqual(item.state, .waitingForModels)
            XCTAssertNil(model.diagramQueuePosition(for: item.id))
        }
        XCTAssertTrue(model.errorHandler.messages.isEmpty)
        await model.shutdown()
    }

    func testImportQueuesAndCompletesDiagramWithValidatedResult() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (repo, model, release) = try fixture(root)
        let workspace = DiagramWorkspaceModel(model: model)
        let diagram = try await importPNG(model)
        try await waitUntil { model.diagram(diagram.id)?.state == .recognizing }
        // Keep the diagram open while recognition completes, as in the UI.
        workspace.selection = diagram.id
        XCTAssertNil(workspace.result)
        try Data().write(to: release)
        try await waitUntil { model.diagram(diagram.id)?.state == .completed }
        let finished = try XCTUnwrap(model.diagram(diagram.id))
        XCTAssertEqual(finished.warnings, [])
        XCTAssertNotNil(finished.activeRunId)
        let commands = try events(root)
        XCTAssertEqual(commands.count, 1)
        XCTAssertTrue(commands[0].isDiagram)
        XCTAssertNil(commands[0].stage)
        XCTAssertNil(commands[0].recordingPath)
        XCTAssertEqual(commands[0].diagramPath, model.diagramRepository?.folder(diagram.id).path)
        XCTAssertEqual(commands[0].modelsPath, repo.models.path)
        // Completion must load the result without reselecting the diagram.
        try await waitUntil { workspace.result != nil }
        XCTAssertEqual(workspace.result?.nodes.map(\.label), ["Начало", "Проверка"])
        XCTAssertEqual(workspace.result?.edges.first?.label, "да")
        // The recording archive is untouched by diagram processing.
        XCTAssertTrue(model.recordings.isEmpty)
        await model.shutdown()
    }

    func testImportWithoutDiagramModelWaitsOutsideFIFOUntilExplicitStart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (repo, model, release) = try fixture(root, installDiagram: false)
        XCTAssertFalse(model.diagramModelsReady)
        let diagram = try await importPNG(model)
        await model.reloadDiagrams()
        XCTAssertEqual(model.diagram(diagram.id)?.state, .waitingForModels)
        XCTAssertNil(model.diagramQueuePosition(for: diagram.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("events.jsonl").path))
        // Installing the model does not queue anything on its own.
        let profile = try XCTUnwrap(model.catalog?.models.first { $0.purpose == .diagram })
        model.modelLibrary.installed(profile, catalog: try XCTUnwrap(model.catalog))
        XCTAssertTrue(model.diagramModelsReady)
        XCTAssertEqual(model.diagram(diagram.id)?.state, .waitingForModels)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("events.jsonl").path))
        await model.recognizeDiagram(diagram.id)
        try await waitUntil { model.diagram(diagram.id)?.state == .queued }
        try Data().write(to: release)
        try await waitUntil { model.diagram(diagram.id)?.state == .completed }
        await model.shutdown()
    }

    func testPromotingDiagramPreservesMixedFIFOWithMatchingUUIDAndActiveWorker() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (repo, model, release) = try fixture(root)
        // A recording whose UUID matches a manually created diagram item.
        let recording = try completedRecording(repo, title: "Recording X")
        let otherRecording = try completedRecording(repo, title: "Recording Y")
        let active = try await importPNG(model)
        try await waitUntil { model.status == "diagram-ready-" + active.id }
        await model.reload()
        await model.enqueue(recording.id)
        let otherDiagram = try await importPNG(model)
        await model.enqueue(otherRecording.id)
        let diagramRepository = try XCTUnwrap(model.diagramRepository)
        var diagram = DiagramManifest(title: "Diagram X", filename: "x.png", ext: "png", uti: "public.png")
        diagram.id = recording.id
        let folder = diagramRepository.folder(diagram.id)
        try Disk.directory(folder)
        let data = try imageData()
        try data.write(to: folder.appendingPathComponent("original.png"))
        diagram.byteSize = Int64(data.count)
        diagram.pixelWidth = 4; diagram.pixelHeight = 4
        diagram.sha256 = try Disk.hash(folder.appendingPathComponent("original.png"))
        try diagramRepository.save(diagram)
        let profile = try XCTUnwrap(model.diagramProfile)
        _ = try await model.diagramArchive?.beginRun(diagram.id, profile: profile)
        await model.reloadDiagrams()
        await model.enqueueDiagram(diagram.id)
        XCTAssertEqual(model.queuePosition(for: recording.id), 1)
        XCTAssertEqual(model.diagramQueuePosition(for: otherDiagram.id), 2)
        XCTAssertEqual(model.queuePosition(for: otherRecording.id), 3)
        XCTAssertEqual(model.diagramQueuePosition(for: diagram.id), 4)

        model.moveToFrontOfQueue(.diagram(diagram.id))
        model.moveToFrontOfQueue(.diagram(active.id))
        XCTAssertEqual(model.diagramQueuePosition(for: diagram.id), 1)
        XCTAssertEqual(model.queuePosition(for: recording.id), 2)
        XCTAssertEqual(model.diagramQueuePosition(for: otherDiagram.id), 3)
        XCTAssertEqual(model.queuePosition(for: otherRecording.id), 4)
        XCTAssertNil(model.diagramQueuePosition(for: active.id))
        XCTAssertEqual(model.diagram(active.id)?.state, .recognizing)
        XCTAssertEqual(try events(root).map(\.jobId), [active.id])

        try Data().write(to: release)
        try await waitUntil { model.diagram(diagram.id)?.state == .completed }
        try await waitUntil { (try? repo.load(otherRecording.id).state) == .completed }
        let commands = try events(root)
        XCTAssertEqual(commands.map { $0.isDiagram ? QueueJobID.diagram($0.jobId) : .recording($0.jobId) }, [
            .diagram(active.id), .diagram(diagram.id), .recording(recording.id), .recording(recording.id),
            .diagram(otherDiagram.id), .recording(otherRecording.id), .recording(otherRecording.id),
        ])
        XCTAssertEqual(model.diagram(active.id)?.state, .completed)
        // Cancelling the recording UUID never touches the diagram and vice versa.
        await model.cancel(recording.id)
        XCTAssertEqual(model.diagram(diagram.id)?.state, .completed)
        await model.shutdown()
    }

    func testWarningsTabFallsBackAndFrozenExportSurvivesSelectionAndRerun() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, model, release) = try fixture(root)
        let archive = try XCTUnwrap(model.diagramArchive)
        let workspace = DiagramWorkspaceModel(model: model)
        let warningFile = root.appendingPathComponent("diagram-warning")
        try "Первое предупреждение".write(to: warningFile, atomically: true, encoding: .utf8)
        try Data().write(to: release)
        let first = try await importPNG(model)
        try await waitUntil { model.diagram(first.id)?.state == .completedWithWarnings }
        let firstRun = try XCTUnwrap(model.diagram(first.id)?.activeRunId)
        XCTAssertEqual(model.diagram(first.id)?.warnings, ["Первое предупреждение"])
        try FileManager.default.removeItem(at: warningFile)
        let second = try await importPNG(model)
        try await waitUntil { model.diagram(second.id)?.state == .completed }
        try await archive.rename(first.id, title: "Первая/схема")
        await model.reloadDiagrams()
        workspace.selection = first.id
        try await waitUntil { workspace.result != nil }
        workspace.selectResultTab(.warnings)
        XCTAssertEqual(workspace.resultTabs, [.nodes, .edges, .warnings])
        XCTAssertEqual(workspace.resultTab, .warnings)
        let frozen = try XCTUnwrap(workspace.exportRequest(part: workspace.resultTab, format: .markdown))
        let frozenAll = try XCTUnwrap(workspace.exportRequest(part: .all, format: .plainText))

        workspace.selection = second.id
        XCTAssertEqual(workspace.resultTab, .nodes)
        try await waitUntil { workspace.result != nil }
        workspace.selectResultTab(.edges)
        workspace.selection = first.id
        XCTAssertEqual(workspace.resultTab, .edges)
        workspace.selectResultTab(.warnings)

        let hold = root.appendingPathComponent("hold-" + first.id)
        try Data().write(to: hold)
        try "Обновлённый узел".write(to: root.appendingPathComponent("diagram-label"), atomically: true, encoding: .utf8)
        await model.recognizeDiagram(first.id)
        try await waitUntil { model.status == "diagram-ready-" + first.id }
        XCTAssertEqual(model.diagram(first.id)?.activeRunId, firstRun)
        XCTAssertEqual(model.diagram(first.id)?.warnings, ["Первое предупреждение"])
        XCTAssertEqual(workspace.resultTab, .warnings)
        try FileManager.default.removeItem(at: hold)
        try await waitUntil { model.diagram(first.id)?.state == .completed && model.diagram(first.id)?.activeRunId != firstRun }
        try await waitUntil { workspace.result?.nodes.last?.label == "Обновлённый узел" }
        XCTAssertEqual(workspace.resultTab, .nodes)
        XCTAssertNil(workspace.exportRequest(part: .warnings, format: .markdown))

        XCTAssertEqual(frozen.diagram.id, first.id)
        XCTAssertEqual(frozen.filename, "Первая-схема.md")
        let output = root.appendingPathComponent(frozen.filename)
        await workspace.saveExport(frozen, to: output).value
        let exported = try String(contentsOf: output, encoding: .utf8)
        XCTAssertEqual(exported, "# Первая/схема\n\n## Предупреждения\n\n- Первое предупреждение\n")
        let allText = await frozenAll.render()
        XCTAssertTrue(allText.contains("Проверка"))
        XCTAssertTrue(allText.contains("Первое предупреждение"))
        XCTAssertFalse(allText.contains("Обновлённый узел"))
        await model.shutdown()
    }

    func testCancelActiveDiagramKeepsPreviousResultAndLateCompletedCannotPublish() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (repo, model, release) = try fixture(root)
        let diagram = try await importPNG(model)
        try Data().write(to: release)
        try await waitUntil { model.diagram(diagram.id)?.state == .completed }
        let firstRun = try XCTUnwrap(model.diagram(diagram.id)?.activeRunId)
        // A retry is held inside the worker; cancelling must stop it and keep
        // the previous active result even if the process is about to finish.
        try Data().write(to: root.appendingPathComponent("hold-\(diagram.id)"))
        try FileManager.default.removeItem(at: release)
        await model.recognizeDiagram(diagram.id)
        try await waitUntil { model.diagram(diagram.id)?.state == .recognizing }
        await model.cancelDiagram(diagram.id)
        try await waitUntil { !model.busy && !model.supervisor.running }
        let cancelled = try XCTUnwrap(model.diagram(diagram.id))
        XCTAssertEqual(cancelled.state, .cancelled)
        XCTAssertEqual(cancelled.activeRunId, firstRun)
        // The late worker result for the cancelled attempt stays unreadable for
        // the active run: the pending run was never published.
        XCTAssertNotEqual(cancelled.pendingRunId, firstRun)
        let result = try await model.diagramArchive?.perform { try $0.results(diagram.id, runId: firstRun) }
        XCTAssertEqual(result?.nodes.count, 2)
        // The queue keeps working for other jobs afterwards.
        let recording = try completedRecording(repo, title: "After cancel")
        await model.enqueue(recording.id)
        try Data().write(to: release)
        try await waitUntil { (try? repo.load(recording.id).state) == .completed }
        await model.shutdown()
    }

    func testFailedRetryKeepsPreviousActiveResultAndCreatesNewRunOnRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, model, release) = try fixture(root)
        let workspace = DiagramWorkspaceModel(model: model)
        let diagram = try await importPNG(model)
        try Data().write(to: release)
        try await waitUntil { model.diagram(diagram.id)?.state == .completed }
        let firstRun = try XCTUnwrap(model.diagram(diagram.id)?.activeRunId)
        workspace.selection = diagram.id
        try await waitUntil { workspace.result != nil }
        // A failing retry preserves the previous active result.
        try Data().write(to: root.appendingPathComponent("diagram-fail"))
        await model.recognizeDiagram(diagram.id)
        try await waitUntil { model.diagram(diagram.id)?.state == .failed }
        let failed = try XCTUnwrap(model.diagram(diagram.id))
        XCTAssertEqual(failed.activeRunId, firstRun)
        XCTAssertNotNil(failed.pendingRunId)
        XCTAssertTrue(workspace.showsPreviousVersion)
        try await waitUntil { workspace.result != nil }
        XCTAssertEqual(workspace.result?.nodes.count, 2, "предыдущий результат остаётся прочитанным")
        // A successful retry publishes a new run.
        try FileManager.default.removeItem(at: root.appendingPathComponent("diagram-fail"))
        try "Новая версия".write(to: root.appendingPathComponent("diagram-label"), atomically: true, encoding: .utf8)
        await model.recognizeDiagram(diagram.id)
        try await waitUntil { model.diagram(diagram.id)?.state == .completed }
        let done = try XCTUnwrap(model.diagram(diagram.id))
        XCTAssertNotEqual(done.activeRunId, firstRun)
        XCTAssertNil(done.pendingRunId)
        try await waitUntil { workspace.result?.nodes.last?.label == "Новая версия" }
        XCTAssertNil(workspace.resultError)
        await model.shutdown()
    }

    func testSleepPauseInterruptsDiagramAndLateEnqueueIsRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, model, release) = try fixture(root)
        let diagram = try await importPNG(model)
        try await waitUntil { model.diagram(diagram.id)?.state == .queued }
        await model.pause(reason: "Обработка прервана перед сном. Нажмите «Продолжить» после пробуждения.")
        let interrupted = try XCTUnwrap(model.diagram(diagram.id))
        XCTAssertEqual(interrupted.state, .interrupted)
        XCTAssertNil(model.diagramQueuePosition(for: diagram.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("events.jsonl").path),
                       "worker не запускался до паузы")
        // After the pause an explicit retry completes a fresh run.
        await model.recognizeDiagram(diagram.id)
        try await waitUntil { model.diagram(diagram.id)?.state == .queued }
        try Data().write(to: release)
        try await waitUntil { model.diagram(diagram.id)?.state == .completed }
        let commands = try events(root)
        XCTAssertEqual(commands.count, 1, "worker запускается ровно один раз после паузы")
        await model.shutdown()
    }

    func testMemoryPauseReturnsActiveDiagramToQueueHeadOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (repo, model, release) = try fixture(root)
        let diagram = try await importPNG(model)
        try Data().write(to: root.appendingPathComponent("hold-\(diagram.id)"))
        try await waitUntil { model.diagram(diagram.id)?.state == .recognizing }
        model.pauseForCaptureResources(memoryPressure: true)
        try? FileManager.default.removeItem(at: root.appendingPathComponent("hold-\(diagram.id)"))
        try await waitUntil { !model.busy && !model.supervisor.running }
        XCTAssertEqual(model.diagram(diagram.id)?.state, .queued)
        XCTAssertEqual(model.diagramQueuePosition(for: diagram.id), 1)
        model.resumeAfterMemoryPressure()
        try Data().write(to: release)
        try await waitUntil { model.diagram(diagram.id)?.state == .completed }
        // The paused attempt was killed and requeued exactly once; the resumed
        // attempt is the second and final worker command.
        let commands = try events(root).filter { $0.isDiagram }
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(Set(commands.map(\.runId)).count, 1, "ресурс-пауза переочередивает тот же закреплённый run")
        _ = repo
        await model.shutdown()
    }

    func testDeleteDuringRecognitionWaitsForItsWorkerAndCleansArchive() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (repo, model, release) = try fixture(root)
        let diagram = try await importPNG(model)
        try Data().write(to: root.appendingPathComponent("hold-\(diagram.id)"))
        try await waitUntil { model.diagram(diagram.id)?.state == .recognizing }
        let folder = try XCTUnwrap(model.diagramRepository?.folder(diagram.id))
        let recording = try completedRecording(repo, title: "Unrelated")
        await model.enqueue(recording.id)
        await model.deleteDiagrams([diagram.id])
        try await waitUntil { !FileManager.default.fileExists(atPath: folder.path) }
        XCTAssertNil(model.diagram(diagram.id))
        // The unrelated queued recording still runs after the deletion barrier.
        try Data().write(to: release)
        try await waitUntil { (try? repo.load(recording.id).state) == .completed }
        await model.shutdown()
    }

    func testDiagramGroupDeletionCanKeepDiagramsOrCancelAndRemoveTheirJobs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (repo, model, release) = try fixture(root)
        let workspace = DiagramWorkspaceModel(model: model)
        let diagramRepo = try XCTUnwrap(model.diagramRepository)
        await model.changeDiagramGroups { try $0.create(name: "Проект") }
        let transferGroup = model.diagramGroups.defaultID
        let active = try await importPNG(model, groupID: transferGroup)
        try await waitUntil { model.status == "diagram-ready-" + active.id }
        workspace.selectSidebarDiagram(active.id)

        await workspace.deleteGroup(transferGroup, deleteDiagrams: false)
        XCTAssertEqual(model.diagramGroups.groupID(for: active.id), RecordingGroup.ungroupedID)
        XCTAssertFalse(model.diagramGroups.groups.contains { $0.id == transferGroup })
        XCTAssertEqual(model.status, "diagram-ready-" + active.id)
        XCTAssertEqual(workspace.selection, active.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: diagramRepo.originalURL(active).path))

        await model.changeDiagramGroups { try $0.create(name: "Удалить") }
        let deletingGroup = model.diagramGroups.defaultID
        await model.moveDiagrams([active.id], to: deletingGroup)
        let recording = try completedRecording(repo, title: "Unrelated")
        await model.enqueue(recording.id)
        let queuedMember = try await importPNG(model, groupID: deletingGroup)
        let outside = try await importPNG(model)
        XCTAssertEqual(model.diagramQueuePosition(for: queuedMember.id), 2)
        await workspace.deleteGroup(deletingGroup, deleteDiagrams: true)
        XCTAssertFalse(model.diagramGroups.groups.contains { $0.id == deletingGroup })
        XCTAssertNil(workspace.selection)
        for member in [active, queuedMember] {
            await model.enqueueDiagram(member.id)
            XCTAssertNil(model.diagramQueuePosition(for: member.id))
            XCTAssertFalse(FileManager.default.fileExists(atPath: diagramRepo.folder(member.id).path))
        }
        try Data().write(to: release)
        try await waitUntil { model.diagram(outside.id)?.state == .completed }
        XCTAssertEqual(try repo.load(recording.id).state, .completed)
        let commands = try events(root)
        XCTAssertEqual(commands.filter(\.isDiagram).map(\.jobId), [active.id, outside.id])
        XCTAssertEqual(commands.dropFirst().first?.jobId, recording.id)
        await model.shutdown()
    }

    func testRecordingGroupDeletionDoesNotStopActiveDiagram() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, model, release) = try fixture(root)
        let diagram = try await importPNG(model)
        try Data().write(to: root.appendingPathComponent("hold-\(diagram.id)"))
        try await waitUntil { model.diagram(diagram.id)?.state == .recognizing }
        // Deleting a recording group has nothing to do with the diagram job.
        await model.changeGroups { try $0.create(name: "Группа записей") }
        let groupID = try XCTUnwrap(model.recordingGroups.groups.first { !$0.isSystem }?.id)
        await model.deleteGroup(groupID, deleteRecordings: false)
        XCTAssertEqual(model.diagram(diagram.id)?.state, .recognizing)
        try? FileManager.default.removeItem(at: root.appendingPathComponent("hold-\(diagram.id)"))
        try Data().write(to: release)
        try await waitUntil { model.diagram(diagram.id)?.state == .completed }
        await model.shutdown()
    }

    func testCorruptedActiveResultBlocksReadingButArchiveKeepsWorking() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, model, release) = try fixture(root)
        let workspace = DiagramWorkspaceModel(model: model)
        let diagram = try await importPNG(model)
        try Data().write(to: release)
        try await waitUntil { model.diagram(diagram.id)?.state == .completed }
        let runID = try XCTUnwrap(model.diagram(diagram.id)?.activeRunId)
        workspace.selection = diagram.id
        try await waitUntil { workspace.result != nil }
        // A damaged artifact fails to read and never silently falls back.
        let resultPath = try XCTUnwrap(model.diagramRepository?.run(diagram.id, runID).appendingPathComponent("result.json"))
        try Data("broken".utf8).write(to: resultPath)
        workspace.selection = nil
        workspace.selection = diagram.id
        try await waitUntil { workspace.resultError != nil }
        XCTAssertNil(workspace.result)
        // A retry with a fresh run restores a readable result.
        await model.recognizeDiagram(diagram.id)
        try await waitUntil { model.diagram(diagram.id)?.state == .completed }
        try await waitUntil { workspace.result != nil }
        XCTAssertNil(workspace.resultError)
        await model.shutdown()
    }
}
