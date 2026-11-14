import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import LocalScribeCore
@testable import LocalScribe

/// Text-anonymization jobs in the common typed FIFO (work 9): import-order
/// admission after a readiness change, readiness/size re-checks at the top of
/// the queue, the three job kinds sharing one worker slot, per-attempt
/// cancellation with safe reasons, consent-bound retry and conditional atomic
/// publication — through the real supervisor, pipes and a process fixture
/// that honestly performs the anonymization contract (reads input.json,
/// builds result.json, emits kind-discriminated events).
@MainActor
final class AnonymizationQueueTests: XCTestCase {

    private struct Fixture {
        let repository: RecordingRepository
        let catalog: ModelCatalog
        let model: AppModel
        let anon: ModelProfile
        let anonB: ModelProfile
        let root: URL
        var release: URL { root.appendingPathComponent("release") }
    }

    private func fixture(_ root: URL) async throws -> Fixture {
        var repo = try RecordingRepository(root: root)
        let executable = root.appendingPathComponent("worker.py")
        // The process fixture serves all three job kinds: the audio and
        // diagram branches follow the shared fixtures of the other suites;
        // the anonymization branch reads the attempt's input.json, performs a
        // deterministic replacement, writes a fully valid result.json artifact
        // and echoes the kind in every protocol event.
        let script = #"""
        #!/usr/bin/python3
        import sys, json, pathlib, time, hashlib, uuid
        c = json.loads(sys.stdin.readline())
        root = pathlib.Path(c['modelsPath']).parent
        def emit(kind, message=''):
            print(json.dumps(dict(version=1, jobId=c['jobId'], runId=c['runId'], kind=c.get('kind'), type=kind, message=message)), flush=True)
        with (root / 'events.jsonl').open('a') as f:
            f.write(json.dumps(c) + '\n')
        if c.get('kind') == 'anonymization':
            run = pathlib.Path(c['anonymizationPath'])
            if (root / 'text-fail').exists():
                emit('failed', 'Тестовая ошибка обезличивания')
                sys.exit(1)
            inp = json.loads((run / 'input.json').read_text())
            emit('progress', 'anon-ready-' + c['jobId'])
            value, substitute = 'Анна Петрова', 'Мария Сидорова'
            source = inp['source']['text']
            text = source.replace(value, substitute)
            pairs = []
            substitutions = list(inp.get('automaticSubstitutions') or [])
            si = ti = 0
            while si < len(source):
                if source.startswith(value, si):
                    pairs.append(dict(sourceRange=dict(start=si, end=si + len(value)),
                                      resultRange=dict(start=ti, end=ti + len(substitute))))
                    si += len(value); ti += len(substitute)
                else:
                    si += 1; ti += 1
            if pairs and not any(s['sourceValue'] == value for s in substitutions):
                substitutions.append(dict(dataType=inp['dataTypes'][0], sourceValue=value, substituteValue=substitute))
            generatedID = str(uuid.uuid4())
            result = dict(schemaVersion=1,
                input=dict(source=inp['source'], profileID=inp['profileID'], packageID=inp['packageID'], dataTypes=inp['dataTypes']),
                generatedText=dict(id=generatedID, text=text),
                text=dict(id=generatedID, text=text),
                downloadNameStem=inp['importedNameStem'],
                bodyReplacementCount=len(pairs),
                pairs=pairs,
                warnings=[])
            if (root / 'text-corrupt-result').exists():
                (run / 'result.json').write_text('broken result')
            else:
                (run / 'result.json').write_text(json.dumps(dict(schemaVersion=1, result=result, substitutions=substitutions)))
            while not (root / 'release').exists() or (root / ('hold-' + c['jobId'])).exists():
                time.sleep(0.02)
            emit('completed')
            sys.exit(0)
        if c.get('kind') == 'diagram':
            run = pathlib.Path(c['diagramPath']) / 'runs' / c['runId']
            if (root / 'diagram-fail').exists():
                emit('failed', 'Тестовая ошибка распознавания')
                sys.exit(1)
            emit('progress', 'diagram-ready-' + c['jobId'])
            while not (root / 'release').exists() or (root / ('hold-' + c['jobId'])).exists():
                time.sleep(0.02)
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
        profiles += [
            ModelProfile(id: "anon-llm", repository: "test/anon", revision: "test-revision", license: "test", files: [], role: nil,
                         recommendedMemoryGB: 8, workingMemoryGB: 2, supportedTasks: [.anonymization]),
            ModelProfile(id: "anon-b", repository: "test/anon-b", revision: "test-revision", license: "test", files: [], role: nil,
                         recommendedMemoryGB: 8, workingMemoryGB: 2, supportedTasks: [.anonymization]),
        ]
        for index in profiles.indices {
            let data = Data(profiles[index].id.utf8)
            let folder = repo.models.appendingPathComponent(profiles[index].id)
            try Disk.directory(folder)
            let file = folder.appendingPathComponent("weights.bin")
            try data.write(to: file)
            profiles[index].files = [ModelFile(path: "weights.bin", localPath: "weights.bin", size: Int64(data.count), sha256: try Disk.hash(file))]
        }
        // The anon references carry the filled file lists, so their derived
        // package ids match the catalog copies the registry installs.
        let anon = profiles[profiles.count - 2]
        let anonB = profiles[profiles.count - 1]
        let catalog = ModelCatalog(models: profiles)
        let suite = "LocalScribeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(repository: repo, startServices: false, workerExecutable: executable,
                             userDefaults: defaults, catalog: catalog)
        var library = ModelLibrary()
        for profile in profiles { library.installed(profile, catalog: catalog) }
        try library.select(profiles[0], catalog: catalog)
        try library.save(at: repo.models)
        await model.verifyModels()
        XCTAssertTrue(model.modelsReady)
        XCTAssertNotNil(model.activeCatalog)
        return Fixture(repository: repo, catalog: catalog, model: model, anon: anon, anonB: anonB, root: root)
    }

    // MARK: - Helpers

    private func waitUntil(_ predicate: @MainActor @Sendable () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !(try await predicate()) && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let final = try await predicate()
        XCTAssertTrue(final)
    }
    private func waitUntilCard(_ model: AppModel, _ id: String,
                               state: AnonymizationAttemptState) async throws {
        try await waitUntil { [model] in
            guard let archive = model.textArchive else { return false }
            return ((try? await archive.loadCard(id))?.latestAttempt.state) == state
        }
    }
    @discardableResult
    private func loadCard(_ model: AppModel, _ id: String) async throws -> AnonymizationCardDocument {
        try await XCTUnwrap(model.textArchive).loadCard(id)
    }
    /// Import through the archive plus the queue hook of the workspace import
    /// pipeline (a ready model starts the first attempt at once).
    @discardableResult
    private func importCard(_ fixture: Fixture, name: String, text: String) async throws -> String {
        let archive = try XCTUnwrap(fixture.model.textArchive)
        let summary = try await archive.importCard(
            .init(bytes: Data(text.utf8), importedNameStem: name, sourceFormat: .txt,
                  source: TextRevision(id: UUID().uuidString, text: text)))
        await fixture.model.reloadTexts()
        await fixture.model.enqueueText(summary.id)
        return summary.id
    }
    /// Save the anonymization assignment through the real settings path and
    /// refresh the readiness snapshot (installation scan + wake).
    private func assign(_ fixture: Fixture, profile: ModelProfile) async throws {
        let draft = SettingsDraft(model: fixture.model)
        draft.anonymizationProfileID = profile.id
        try fixture.model.applySettings(draft)
        await fixture.model.reloadAnonymizationState()
    }
    /// Direct saved-record change used while the queue is busy (the settings
    /// window itself is locked then); mirrors an assignment change landing
    /// before an admission re-check.
    private func saveAssignment(_ fixture: Fixture, profile: ModelProfile) async throws {
        var settings = fixture.model.anonymizationSettings
        settings.setProfile(profile.id, for: .anonymization)
        try AnonymizationSettingsStore(root: fixture.repository.root).save(settings)
        await fixture.model.reloadAnonymizationState()
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

    // MARK: - Criterion 30: import order and the waiting state

    func testWaitingCardsEnterFIFOInImportOrderWhenModelBecomesReady() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await fixture(root)
        let model = fixture.model
        let first = try await importCard(fixture, name: "first", text: "Первый отчёт Анна Петрова")
        let second = try await importCard(fixture, name: "second", text: "Второй отчёт")
        let third = try await importCard(fixture, name: "third", text: "Третий отчёт")
        // Without a ready assignment every card waits outside the FIFO.
        for id in [first, second, third] {
            XCTAssertEqual(model.textCard(id)?.attemptState, .waitingModel)
            XCTAssertNil(model.textQueuePosition(for: id))
            let waitingCard = try await loadCard(model, id)
            XCTAssertEqual(waitingCard.latestAttempt.requestedSource, nil)
        }
        try await assign(fixture, profile: fixture.anon)
        // The readiness wake queues all waiting cards in import order; the
        // first is admitted at once, so the FIFO keeps the remaining order.
        try await waitUntil {
            model.textCard(first)?.attemptState == .running
                && model.textQueuePosition(for: second) != nil
                && model.textQueuePosition(for: third) != nil
        }
        XCTAssertEqual(model.textCard(second)?.attemptState, .queued)
        let secondPosition = model.textQueuePosition(for: second)
        let thirdPosition = model.textQueuePosition(for: third)
        XCTAssertNotNil(secondPosition)
        XCTAssertNotNil(thirdPosition)
        if let secondPosition, let thirdPosition {
            XCTAssertLessThan(secondPosition, thirdPosition, "порядок импорта сохраняется")
        }
        try Data().write(to: fixture.release)
        try await waitUntilCard(model, third, state: .succeeded)
        XCTAssertEqual(try events(root).filter { $0.isAnonymization }.map(\.jobId), [first, second, third])
        for id in [first, second, third] {
            let card = try await loadCard(model, id)
            XCTAssertEqual(card.latestAttempt.state, .succeeded)
            XCTAssertNotNil(card.publishedResult)
        }
        await model.shutdown()
    }

    // MARK: - Criterion 8: the three kinds share one sequential slot

    func testRecordingDiagramAndTextRunSequentiallyAndTextPublishesFullResult() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await fixture(root)
        let model = fixture.model
        try await assign(fixture, profile: fixture.anon)
        let recording = try completedRecording(fixture.repository, title: "Запись")
        await model.enqueue(recording.id)
        try await waitUntil { model.status == "fixture-ready-" + recording.id }
        let diagramURL = root.appendingPathComponent("flow.png")
        try imageData().write(to: diagramURL)
        _ = try await model.importDiagramImage(at: diagramURL, groupID: RecordingGroup.ungroupedID)
        let text = try await importCard(fixture, name: "Отчёт", text: "Отчёт: Анна Петрова позвонила.")
        try Data().write(to: fixture.release)
        try await waitUntil { !model.busy && model.diagrams.allSatisfy { $0.state == .completed } }
        let commands = try events(root)
        XCTAssertEqual(commands.map(\.kind), [nil, nil, "diagram", "anonymization"])
        let card = try await loadCard(model, text)
        XCTAssertEqual(card.latestAttempt.state, .succeeded)
        let result = try XCTUnwrap(card.publishedResult)
        XCTAssertEqual(result.text.text, "Отчёт: Мария Сидорова позвонила.")
        XCTAssertEqual(result.bodyReplacementCount, 1)
        XCTAssertEqual(result.pairs.count, 1)
        XCTAssertEqual(card.automaticSubstitutions,
                       [AutomaticSubstitution(dataType: model.anonymizationSettings.dataTypes[0],
                                              sourceValue: "Анна Петрова", substituteValue: "Мария Сидорова")])
        let recordingManifest = try await fixture.repository.load(recording.id)
        XCTAssertEqual(recordingManifest.state, .completed)
        await model.shutdown()
    }

    // MARK: - Criterion 10: statuses, own-attempt cancellation, safe reason, retry

    func testCancelTouchesOnlyItsAttemptAndFailureKeepsSafeReasonAndAllowsRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await fixture(root)
        let model = fixture.model
        try await assign(fixture, profile: fixture.anon)
        let first = try await importCard(fixture, name: "first", text: "Первый отчёт Анна Петрова")
        let second = try await importCard(fixture, name: "second", text: "Второй отчёт")
        try await waitUntilCard(model, first, state: .running)
        // The row and the document show the same actual status.
        XCTAssertEqual(model.textCard(first)?.attemptState, .running)
        XCTAssertEqual(model.textCard(second)?.attemptState, .queued)
        XCTAssertEqual(model.textQueuePosition(for: second), 1)
        // Cancelling the running attempt stops only it; the queued one keeps its place.
        try Data().write(to: root.appendingPathComponent("hold-" + second))
        await model.cancelTextCard(first)
        var card = try await loadCard(model, first)
        XCTAssertEqual(card.latestAttempt.state, .cancelled)
        XCTAssertNil(card.publishedResult)
        try await waitUntilCard(model, second, state: .running)
        try Data().write(to: fixture.release)
        try FileManager.default.removeItem(at: root.appendingPathComponent("hold-" + second))
        try await waitUntilCard(model, second, state: .succeeded)
        // A worker failure records a safe neutral reason on the attempt.
        try Data().write(to: root.appendingPathComponent("text-fail"))
        let failed = try await importCard(fixture, name: "failed", text: "Отчёт с ошибкой")
        try await waitUntilCard(model, failed, state: .failed)
        card = try await loadCard(model, failed)
        XCTAssertEqual(card.latestAttempt.failure?.kind, .processing)
        XCTAssertEqual(card.latestAttempt.failure?.reason, "Тестовая ошибка обезличивания")
        XCTAssertTrue(model.errorHandler.messages.contains { $0.contains("Тестовая ошибка обезличивания") })
        XCTAssertNil(card.publishedResult)
        // With the failure cleared and the model ready, an explicit retry succeeds.
        try FileManager.default.removeItem(at: root.appendingPathComponent("text-fail"))
        await model.retryAnonymization(cardID: failed)
        try await waitUntilCard(model, failed, state: .succeeded)
        card = try await loadCard(model, failed)
        XCTAssertNotNil(card.publishedResult)
        XCTAssertEqual(try events(root).filter { $0.isAnonymization }.map(\.jobId).last, failed)
        await model.shutdown()
    }

    // MARK: - Criterion 18: consent bound to the right version

    func testRetryConsentBoundToVersionAndStaleCompletionKeepsCurrentRightText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await fixture(root)
        let model = fixture.model
        try await assign(fixture, profile: fixture.anon)
        let id = try await importCard(fixture, name: "Отчёт", text: "Отчёт: Анна Петрова позвонила.")
        try Data().write(to: fixture.release)
        try await waitUntilCard(model, id, state: .succeeded)
        var card = try await loadCard(model, id)
        let publishedTextID = try XCTUnwrap(card.publishedResult?.text.id)
        // A manual right-panel edit makes the consent dialog necessary.
        _ = try await model.textArchive?.editResult(id, ScalarEdit(start: 0, end: 1, replacement: "О"))
        card = try await loadCard(model, id)
        let editedID = try XCTUnwrap(card.publishedResult?.text.id)
        XCTAssertNotEqual(editedID, publishedTextID)
        let consent = await model.anonymizationRetryConsent(for: id)
        guard case .needed(let current) = consent else { return XCTFail("Согласие не запрошено") }
        XCTAssertEqual(current, editedID)
        // A retry confirmed for a stale version is refused and changes nothing.
        await model.retryAnonymization(cardID: id, confirmingResultRevisionID: publishedTextID)
        XCTAssertTrue(model.errorHandler.messages.contains { $0.contains("Согласие") })
        let refusedCard = try await loadCard(model, id)
        XCTAssertEqual(refusedCard.latestAttempt.state, .succeeded)
        // A confirmed retry runs; a further edit of the right panel makes the
        // agreed version stale, so the completion must not publish.
        try FileManager.default.removeItem(at: fixture.release)
        try Data().write(to: root.appendingPathComponent("hold-" + id))
        await model.retryAnonymization(cardID: id, confirmingResultRevisionID: editedID)
        try await waitUntilCard(model, id, state: .running)
        let retryAttempt = try await loadCard(model, id).latestAttempt
        XCTAssertEqual(retryAttempt.expectedResultRevisionID, editedID)
        _ = try await model.textArchive?.editResult(id, ScalarEdit(start: 0, end: 1, replacement: "О"))
        let secondEditCard = try await loadCard(model, id)
        let secondEditID = try XCTUnwrap(secondEditCard.publishedResult?.text.id)
        XCTAssertNotEqual(secondEditID, editedID)
        try Data().write(to: fixture.release)
        try FileManager.default.removeItem(at: root.appendingPathComponent("hold-" + id))
        try await waitUntil {
            guard !model.busy else { return false }
            let settled = try await loadCard(model, id)
            return settled.latestAttempt.state == .failed
        }
        // The current right version keeps the manual edit and its identity:
        // the stale completion did not replace it.
        card = try await loadCard(model, id)
        XCTAssertEqual(card.publishedResult?.text.id, secondEditID)
        XCTAssertEqual(card.latestAttempt.failure?.kind, .processing)
        await model.shutdown()
    }

    // MARK: - Criterion 17: a retry that waits takes the last saved source

    func testRetryWaitingForModelDropsSnapshotAndAdmissionTakesLastSavedSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await fixture(root)
        let model = fixture.model
        let original = "Анна Петрова позвонила утром."
        let id = try await importCard(fixture, name: "Отчёт", text: original)
        // No model yet: the explicit retry goes to «Ожидает модель» and drops
        // its command-time snapshot (the waiting source stays editable).
        await model.retryAnonymization(cardID: id)
        var card = try await loadCard(model, id)
        XCTAssertEqual(card.latestAttempt.state, .waitingModel)
        XCTAssertNil(card.latestAttempt.requestedSource)
        // The user removes the phrase while the retry waits for the model.
        let replacement = "Звонок состоялся утром."
        _ = try await model.textArchive?.editSource(id, ScalarEdit(start: 0, end: UInt(original.unicodeScalars.count), replacement: replacement))
        // Readiness wakes the card; the first start takes the last saved source.
        try await assign(fixture, profile: fixture.anon)
        try Data().write(to: fixture.release)
        try await waitUntilCard(model, id, state: .succeeded)
        card = try await loadCard(model, id)
        XCTAssertEqual(card.latestAttempt.input?.source.id, card.source.id)
        XCTAssertEqual(card.latestAttempt.input?.source.text, replacement)
        XCTAssertEqual(card.publishedResult?.input.source.text, replacement)
        XCTAssertFalse(card.publishedResult!.text.text.contains("Анна Петрова"))
        XCTAssertFalse(card.publishedResult!.text.text.contains("Мария Сидорова"), "удалённая фраза не возвращается в результат")
        XCTAssertEqual(card.automaticSubstitutions, [], "подстановок для исчезнувшего значения нет")
        await model.shutdown()
    }

    // MARK: - Criterion 31: the saved data-type list freezes at the actual start

    func testRunUsesLastSavedDataTypesBeforeStartAndFreezesThemForTheRun() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await fixture(root)
        let model = fixture.model
        let waiting = try await importCard(fixture, name: "waiting", text: "Ожидает модель: Анна Петрова")
        // A type list saved while the card waits for the model.
        var settings = model.anonymizationSettings
        try settings.applyDataTypes(["Только телефоны"])
        try AnonymizationSettingsStore(root: fixture.repository.root).save(settings)
        await model.reloadAnonymizationState()
        try await assign(fixture, profile: fixture.anon)
        // The waiting card is admitted and holds the worker (no release yet).
        try await waitUntilCard(model, waiting, state: .running)
        let held = try await importCard(fixture, name: "held", text: "Удержанный отчёт")
        XCTAssertEqual(model.textCard(held)?.attemptState, .queued)
        // A list saved after the start of the running attempt changes nothing
        // for it — the next admitted card takes the last saved list.
        var later = model.anonymizationSettings
        try later.applyDataTypes(["Адреса"])
        try AnonymizationSettingsStore(root: fixture.repository.root).save(later)
        await model.reloadAnonymizationState()
        try Data().write(to: fixture.release)
        try await waitUntilCard(model, held, state: .succeeded)
        var card = try await loadCard(model, waiting)
        XCTAssertEqual(card.latestAttempt.input?.dataTypes, ["Только телефоны"])
        card = try await loadCard(model, held)
        XCTAssertEqual(card.latestAttempt.input?.dataTypes, ["Адреса"])
        await model.shutdown()
    }

    // MARK: - Criterion 38: readability while queued/running, editing after each outcome

    func testSourceStaysReadableInQueueAndRunningAndEditableAfterEachOutcome() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await fixture(root)
        let model = fixture.model
        try await assign(fixture, profile: fixture.anon)
        let running = try await importCard(fixture, name: "running", text: "Обработка: Анна Петрова")
        let queued = try await importCard(fixture, name: "queued", text: "Очередь: Анна Петрова")
        try await waitUntilCard(model, running, state: .running)
        XCTAssertEqual(model.textCard(queued)?.attemptState, .queued)
        // QUEUED and RUNNING keep both panels readable.
        for id in [queued, running] {
            let card = try await loadCard(model, id)
            XCTAssertFalse(card.source.text.isEmpty)
        }
        try Data().write(to: fixture.release)
        try await waitUntilCard(model, queued, state: .succeeded)
        try await waitUntilCard(model, running, state: .succeeded)
        // After success the source is editable again.
        _ = try await model.textArchive?.editSource(queued, ScalarEdit(start: 0, end: 1, replacement: "X"))
        // A failed attempt also frees the editor.
        try Data().write(to: root.appendingPathComponent("text-fail"))
        let failed = try await importCard(fixture, name: "failed", text: "Ошибка: Анна Петрова")
        try await waitUntilCard(model, failed, state: .failed)
        _ = try await model.textArchive?.editSource(failed, ScalarEdit(start: 0, end: 1, replacement: "Y"))
        // A cancelled attempt does too.
        try FileManager.default.removeItem(at: root.appendingPathComponent("text-fail"))
        try Data().write(to: root.appendingPathComponent("hold-cancelled"))
        let cancelled = try await importCard(fixture, name: "cancelled", text: "Отмена: Анна Петрова")
        try await waitUntilCard(model, cancelled, state: .running)
        await model.cancelTextCard(cancelled)
        _ = try await model.textArchive?.editSource(cancelled, ScalarEdit(start: 0, end: 1, replacement: "Z"))
        let card = try await loadCard(model, cancelled)
        XCTAssertEqual(card.latestAttempt.state, .cancelled)
        XCTAssertTrue(card.source.text.hasPrefix("Z"))
        await model.shutdown()
    }

    // MARK: - Criterion 40: restart recovery

    func testRestartInterruptsQueueAndRunKeepsResultsAndWaitingResumes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await fixture(root)
        let model = fixture.model
        try await assign(fixture, profile: fixture.anon)
        let done = try await importCard(fixture, name: "done", text: "Готово: Анна Петрова")
        try Data().write(to: fixture.release)
        try await waitUntilCard(model, done, state: .succeeded)
        let publishedResult = try await loadCard(model, done).publishedResult
        // A crash-like leftover: one attempt RUNNING (worker held), one QUEUED,
        // one WAITING_MODEL (crafted directly, no wake fires for it).
        try FileManager.default.removeItem(at: fixture.release)
        let runningID = try await importCard(fixture, name: "running", text: "В обработке")
        try await waitUntilCard(model, runningID, state: .running)
        let queuedID = try await importCard(fixture, name: "queued", text: "В очереди")
        XCTAssertEqual(model.textCard(queuedID)?.attemptState, .queued)
        let waitingID = try await importCard(fixture, name: "waiting", text: "Ждёт модель")
        try await model.textArchive!.updateCard(waitingID) {
            $0.latestAttempt = AnonymizationAttempt(state: .waitingModel)
        }
        // Simulate a crash: the abandoned worker stays alive holding the slot
        // and model1 keeps waiting on it; nothing records an outcome. A fresh
        // model reopens the same root and recovers the archive.
        let repo2 = try RecordingRepository(root: root)
        let suite = "LocalScribeTests.\(UUID().uuidString)"
        let defaults2 = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults2.removePersistentDomain(forName: suite) }
        let model2 = AppModel(repository: repo2, startServices: false,
                              workerExecutable: root.appendingPathComponent("worker.py"),
                              userDefaults: defaults2, catalog: fixture.catalog)
        for profile in fixture.catalog.models { model2.modelLibrary.installed(profile, catalog: fixture.catalog) }
        _ = try await model2.textArchive?.recover()
        await model2.reloadTexts()
        for id in [queuedID, runningID] {
            XCTAssertEqual(model2.textCard(id)?.attemptState, .interrupted, "очередь и обработка прерываются")
        }
        XCTAssertEqual(model2.textCard(waitingID)?.attemptState, .waitingModel)
        XCTAssertEqual(model2.textCard(done)?.attemptState, .succeeded)
        // Published results stay available after the restart.
        let recovered = try await model2.textArchive!.loadCard(done)
        XCTAssertEqual(recovered.publishedResult, publishedResult)
        // Readiness wakes the still-waiting card; interrupted ones need an explicit retry.
        await model2.reloadAnonymizationState()
        try Data().write(to: fixture.release)
        try await waitUntilCard(model2, waitingID, state: .succeeded)
        XCTAssertEqual(model2.textCard(queuedID)?.attemptState, .interrupted)
        await model2.retryAnonymization(cardID: queuedID)
        try await waitUntilCard(model2, queuedID, state: .succeeded)
        await model.shutdown()
        await model2.shutdown()
    }

    // MARK: - Criterion 42: admission size limit

    func testAdmissionMeasuresRunTextInUTF8AndRecordsBothByteNumbers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await fixture(root)
        let model = fixture.model
        model.inputLimits = AnonymizationInputLimit(overrides: [fixture.anon.id: 100])
        try await assign(fixture, profile: fixture.anon)
        // ASCII keeps bytes equal to scalars: 100 bytes is admitted (equality),
        // 101 bytes fails with both numbers recorded.
        let exact = try await importCard(fixture, name: "exact", text: String(repeating: "a", count: 100))
        try await waitUntilCard(model, exact, state: .running)
        let over = try await importCard(fixture, name: "over", text: String(repeating: "a", count: 101))
        try Data().write(to: fixture.release)
        try await waitUntilCard(model, exact, state: .succeeded)
        try await waitUntilCard(model, over, state: .failed)
        var card = try await loadCard(model, over)
        XCTAssertEqual(card.latestAttempt.failure?.kind, .sizeLimit)
        XCTAssertEqual(card.latestAttempt.failure?.actualBytes, 101)
        XCTAssertEqual(card.latestAttempt.failure?.limitBytes, 100)
        XCTAssertNil(card.publishedResult, "частичный результат не публикуется")
        XCTAssertEqual(model.textCard(over)?.attemptState, .failed)
        // Shrinking the source and retrying explicitly succeeds.
        _ = try await model.textArchive?.editSource(over, ScalarEdit(start: 50, end: 101, replacement: ""))
        await model.retryAnonymization(cardID: over)
        try await waitUntilCard(model, over, state: .succeeded)
        card = try await loadCard(model, over)
        XCTAssertNotNil(card.publishedResult)
        await model.shutdown()
    }

    // MARK: - Criterion 43: assignment change and package removal around admission

    func testQueuedJobUsesCurrentAssignmentAndRemovalMovesWaitingBackAndKeepsActivePinned() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await fixture(root)
        let model = fixture.model
        try await assign(fixture, profile: fixture.anon)
        let active = try await importCard(fixture, name: "active", text: "Активное: Анна Петрова")
        try await waitUntilCard(model, active, state: .running)
        let pending = try await importCard(fixture, name: "pending", text: "Ожидающее: Анна Петрова")
        XCTAssertEqual(model.textCard(pending)?.attemptState, .queued)
        // A waiting (queued, not admitted) job takes the assignment saved
        // before its actual start.
        try await saveAssignment(fixture, profile: fixture.anonB)
        try Data().write(to: fixture.release)
        try await waitUntilCard(model, pending, state: .succeeded)
        var card = try await loadCard(model, pending)
        XCTAssertEqual(card.latestAttempt.input?.profileID, fixture.anonB.id)
        // The started job finished with its pinned package.
        card = try await loadCard(model, active)
        XCTAssertEqual(card.latestAttempt.state, .succeeded)
        XCTAssertEqual(card.latestAttempt.input?.profileID, fixture.anon.id)
        // A confirmed removal of the acting package: an active job keeps the
        // pinned files until its worker exits, a queued card returns to
        // «Ожидает модель» at admission.
        try FileManager.default.removeItem(at: fixture.release)
        let pinned = try await importCard(fixture, name: "pinned", text: "Закреплённое: Анна Петрова")
        try await waitUntilCard(model, pinned, state: .running)
        let mover = try await importCard(fixture, name: "mover", text: "Вернётся в ожидание")
        XCTAssertEqual(model.textCard(mover)?.attemptState, .queued)
        let packageB = fixture.anonB.effectivePackageID
        try await model.packageRegistry.confirmRemoval(packageID: packageB)
        let readyAfterRemoval = await model.packageRegistry.readyPackageIDs()
        XCTAssertFalse(readyAfterRemoval.contains(packageB))
        // The active job's lease keeps the package physically irremovable.
        var canRemove = await model.packageRegistry.canPhysicallyRemove(packageB)
        XCTAssertFalse(canRemove)
        try Data().write(to: fixture.release)
        try await waitUntilCard(model, pinned, state: .succeeded)
        canRemove = await model.packageRegistry.canPhysicallyRemove(packageB)
        XCTAssertTrue(canRemove)
        try await model.packageRegistry.finishPhysicalRemoval(packageID: packageB)
        // The queued card lost readiness at admission and waits outside the FIFO.
        try await waitUntilCard(model, mover, state: .waitingModel)
        XCTAssertNil(model.textQueuePosition(for: mover))
        let moverCard = try await loadCard(model, mover)
        XCTAssertEqual(moverCard.latestAttempt.requestedSource, nil)
        XCTAssertNil(moverCard.latestAttempt.input)
        await model.shutdown()
    }

    // MARK: - Late completion after cancellation is never published

    func testCancelAfterArtifactWrittenKeepsPreviousResultUnpublished() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await fixture(root)
        let model = fixture.model
        try await assign(fixture, profile: fixture.anon)
        // A first successful attempt establishes the published result.
        let id = try await importCard(fixture, name: "Отчёт", text: "Отчёт: Анна Петрова позвонила.")
        try Data().write(to: fixture.release)
        try await waitUntilCard(model, id, state: .succeeded)
        let firstResult = try await loadCard(model, id).publishedResult
        // The retry's fixture worker has already written result.json when the
        // user cancels: the late artifact must never reach the card.
        try FileManager.default.removeItem(at: fixture.release)
        try Data().write(to: root.appendingPathComponent("hold-" + id))
        await model.retryAnonymization(cardID: id)
        try await waitUntilCard(model, id, state: .running)
        let textRepository = try XCTUnwrap(fixture.model.textRepository)
        let attemptURL = textRepository.run(id, (try await loadCard(model, id)).latestAttempt.id)
        try await waitUntil { FileManager.default.fileExists(atPath: attemptURL.appendingPathComponent("result.json").path) }
        await model.cancelTextCard(id)
        var card = try await loadCard(model, id)
        XCTAssertEqual(card.latestAttempt.state, .cancelled)
        XCTAssertEqual(card.publishedResult, firstResult, "позднее завершение не публикуется")
        // The next explicit retry creates a new attempt and publishes fresh.
        try Data().write(to: fixture.release)
        try FileManager.default.removeItem(at: root.appendingPathComponent("hold-" + id))
        await model.retryAnonymization(cardID: id)
        try await waitUntilCard(model, id, state: .succeeded)
        card = try await loadCard(model, id)
        XCTAssertNotEqual(card.publishedResult, firstResult)
        XCTAssertEqual(card.automaticSubstitutions.count, 1, "история подстановок переиспользуется")
        await model.shutdown()
    }

    // MARK: - A damaged artifact is never shown partially

    func testCorruptResultFailsAttemptAndKeepsPreviousResultIntact() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await fixture(root)
        let model = fixture.model
        try await assign(fixture, profile: fixture.anon)
        let id = try await importCard(fixture, name: "Отчёт", text: "Отчёт: Анна Петрова позвонила.")
        try Data().write(to: fixture.release)
        try await waitUntilCard(model, id, state: .succeeded)
        let firstResult = try await loadCard(model, id).publishedResult
        try Data().write(to: root.appendingPathComponent("text-corrupt-result"))
        await model.retryAnonymization(cardID: id)
        try await waitUntilCard(model, id, state: .failed)
        let card = try await loadCard(model, id)
        XCTAssertEqual(card.latestAttempt.failure?.kind, .processing)
        XCTAssertEqual(card.publishedResult, firstResult, "повреждённый результат не заменяет опубликованный")
        XCTAssertFalse(model.errorHandler.messages.isEmpty)
        await model.shutdown()
    }
}
