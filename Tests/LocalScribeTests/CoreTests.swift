import XCTest
import AVFoundation
@testable import LocalScribeCore
final class CoreTests: XCTestCase {
    func testRenamePersistsTitleAndUpdatesArchiveIndex() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root)
        let first = Manifest(sourceType: "microphone", title: "Запись 18.10.2026, 12:00", filename: "original.caf")
        let second = Manifest(sourceType: "import", title: "Другая встреча", filename: "meeting.wav")
        try repo.save(first); try repo.save(second)

        try repo.rename(first.id, title: "  Планирование — команда 🎙️ \n")

        let reopened = try RecordingRepository(root: root)
        XCTAssertEqual(try reopened.load(first.id).displayTitle, "Планирование — команда 🎙️")
        XCTAssertEqual(reopened.list().first { $0.id == first.id }?.displayTitle, "Планирование — команда 🎙️")
        XCTAssertEqual(try reopened.load(second.id).displayTitle, second.displayTitle)
        let index = try Disk.read([Manifest].self, at: root.appendingPathComponent("index.json"))
        XCTAssertEqual(index.first { $0.id == first.id }?.displayTitle, "Планирование — команда 🎙️")
    }

    func testRenamePreservesLatestProcessingStateOriginalAndRuns() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root)
        var manifest = Manifest(sourceType: "import", title: "Встреча", filename: "meeting.wav")
        try repo.save(manifest)
        let source = repo.folder(manifest.id).appendingPathComponent(manifest.originalRelativePath)
        try Disk.directory(source.deletingLastPathComponent())
        try Data("original audio".utf8).write(to: source)
        let run = RunInfo(sourceHash: try Disk.hash(source), profileHash: "profile")
        let runFile = repo.run(manifest.id, run.id).appendingPathComponent("run.json")
        try Disk.write(run, to: runFile)
        let runBefore = try Data(contentsOf: runFile)
        manifest = try repo.load(manifest.id)
        manifest.sha256 = run.sourceHash; manifest.sourceComplete = true
        manifest.durationMs = 123_000; manifest.sampleRate = 16000; manifest.channels = 1
        manifest.activeRunId = UUID().uuidString; manifest.pendingRunId = run.id
        manifest.state = .transcribing; manifest.warnings = ["Предупреждение"]
        try repo.save(manifest)
        var expected = try repo.load(manifest.id)
        expected.displayTitle = "Новое название во время обработки"

        try repo.rename(manifest.id, title: expected.displayTitle)

        let renamed = try repo.load(manifest.id)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(renamed), try encoder.encode(expected))
        XCTAssertEqual(try Disk.hash(source), run.sourceHash)
        XCTAssertEqual(try Data(contentsOf: runFile), runBefore)
        XCTAssertTrue(ExportService.render(manifest: renamed, transcript: nil, summary: nil, markdown: false).contains(expected.displayTitle))
    }

    func testRenameRejectsEmptyTitleWithoutChangingManifest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root)
        let manifest = Manifest(sourceType: "microphone", title: "Автоматическое название", filename: "original.caf")
        try repo.save(manifest)
        let file = repo.folder(manifest.id).appendingPathComponent("manifest.json")
        let before = try Data(contentsOf: file)
        for title in ["", " \t\n ", "\u{00A0}"] {
            XCTAssertThrowsError(try repo.rename(manifest.id, title: title)) { error in
                XCTAssertEqual(error.localizedDescription, "Название записи не может быть пустым")
            }
            XCTAssertEqual(try Data(contentsOf: file), before)
        }
    }

    func testRenameRejectsMissingInvalidAndUnsupportedRecordings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root)
        for id in [UUID().uuidString, "../outside"] {
            XCTAssertThrowsError(try repo.rename(id, title: "Новое название"))
        }
        var manifest = Manifest(sourceType: "import", title: "Будущая версия", filename: "meeting.wav")
        manifest.schemaVersion = 2
        let file = repo.folder(manifest.id).appendingPathComponent("manifest.json")
        try Disk.write(manifest, to: file)
        let before = try Data(contentsOf: file)
        XCTAssertThrowsError(try repo.rename(manifest.id, title: "Новое название"))
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testAudioEngineNotificationDoesNotImplyMicrophoneChange() {
        let input = CaptureInputConfiguration(deviceID:42,sampleRate:48000,channels:1,formatID:1,formatFlags:2)
        XCTAssertEqual(CaptureConfigurationAction.evaluate(expected:input,current:input,engineRunning:true),.keepRecording)
        XCTAssertEqual(CaptureConfigurationAction.evaluate(expected:input,current:input,engineRunning:false),.restartEngine)
        var other = input; other.deviceID = 43
        XCTAssertEqual(CaptureConfigurationAction.evaluate(expected:input,current:other,engineRunning:true),.inputChanged)
        other = input; other.sampleRate = 44100
        XCTAssertEqual(CaptureConfigurationAction.evaluate(expected:input,current:other,engineRunning:false),.inputChanged)
        other = input; other.channels = 2
        XCTAssertEqual(CaptureConfigurationAction.evaluate(expected:input,current:other,engineRunning:false),.inputChanged)
        other = input; other.formatFlags = 3
        XCTAssertEqual(CaptureConfigurationAction.evaluate(expected:input,current:other,engineRunning:true),.inputChanged)
        XCTAssertEqual(CaptureConfigurationAction.evaluate(expected:input,current:nil,engineRunning:false),.inputUnavailable)
    }
    func testMisplacedManifestCannotOverwriteAnotherArchiveEntryDuringRecovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let repo = try RecordingRepository(root:root)
        var good = Manifest(sourceType:"import",title:"Keep this title",filename:"a.wav")
        try repo.save(good)
        let wrongFolder = UUID().uuidString
        good.displayTitle = "Corrupt misplaced entry"; good.state = .transcribing
        try Disk.write(good,to:repo.folder(wrongFolder).appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try repo.load(wrongFolder))
        try repo.recover()
        XCTAssertEqual(repo.list().count,1)
        XCTAssertEqual(try repo.load(good.id).displayTitle,"Keep this title")
        good.id = "../outside"
        XCTAssertThrowsError(try repo.save(good))
    }
    func testRepeatedCommitmentsKeepEvidenceAndDistinctOwnersOrDeadlines() {
        let items = [Finding(id:"a",text:"Проверить импорт.",evidenceSegmentIds:["s1"],ownerSpeakerId:"speaker-1"),
                     Finding(id:"b",text:"Проверить импорт",evidenceSegmentIds:["s2"],ownerSpeakerId:"speaker-1",uncertain:true),
                     Finding(id:"c",text:"Проверить импорт",evidenceSegmentIds:["s3"],ownerSpeakerId:"speaker-2"),
                     Finding(id:"d",text:"Проверить импорт",evidenceSegmentIds:["s4"],ownerSpeakerId:"speaker-1",dueText:"завтра")]
        let result = Summary(language:"ru",tasks:items).coalescingExactRepeats().tasks
        XCTAssertEqual(result.count,3)
        XCTAssertEqual(result[0].evidenceSegmentIds,["s1","s2"])
        XCTAssertTrue(result[0].uncertain)
        XCTAssertEqual(result[1].ownerSpeakerId,"speaker-2")
        XCTAssertEqual(result[2].dueText,"завтра")
    }
    func testImportDuplicateAndDeletionPreserveExternalFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }; try Disk.directory(root)
        let original = root.appendingPathComponent("Встреча ; $символы.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate:16000,channels:1)!
        do { let file = try AVAudioFile(forWriting:original,settings:format.settings); let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:16000)!; buffer.frameLength = 16000; memset(buffer.floatChannelData![0],0,16000*4); try file.write(from:buffer) }
        let before = try Disk.hash(original)
        let export = root.appendingPathComponent("Мой экспорт.txt"); try Data("Результат".utf8).write(to:export)
        let repo = try RecordingRepository(root:root.appendingPathComponent("data"))
        let info = AudioInfo(duration:1,sampleRate:16000,channels:1,codec:"pcm_f32le")
        let first = try repo.importFile(original,info:info)
        XCTAssertEqual(first.displayTitle, original.deletingPathExtension().lastPathComponent)
        XCTAssertEqual(try Disk.hash(repo.folder(first.id).appendingPathComponent(first.originalRelativePath)),before)
        XCTAssertThrowsError(try repo.importFile(original,info:info)) { error in XCTAssertEqual((error as? DuplicateRecording)?.id,first.id) }
        let second = try repo.importFile(original,info:info,allowDuplicate:true)
        try repo.delete(first)
        XCTAssertEqual(try Disk.hash(original),before); XCTAssertTrue(FileManager.default.fileExists(atPath:export.path))
        XCTAssertEqual(repo.list().map(\.id),[second.id])
    }
    func testUnsupportedOptionalFieldsBecomeUnknownWithoutDroppingAction() throws {
        let transcript = Transcript(fingerprint:"f",diarized:true,segments:[Segment(id:"s",startMs:0,endMs:1000,speakerId:"speaker-2",text:"I will check the microphone.",language:"en")])
        let draft = Summary(language:"ru",tasks:[Finding(id:"t",text:"Проверить микрофон",evidenceSegmentIds:["s"],ownerSpeakerId:"speaker-2",ownerName:"Спикер 2",dueText:"завтра")])
        let (grounded,changed) = draft.groundingOptionalFields(against:transcript)
        XCTAssertTrue(changed); XCTAssertEqual(grounded.tasks.count,1)
        XCTAssertNil(grounded.tasks[0].ownerName); XCTAssertNil(grounded.tasks[0].dueText); XCTAssertEqual(grounded.tasks[0].ownerSpeakerId,"speaker-2")
        XCTAssertNoThrow(try grounded.validate(against:transcript))
    }
    func testCaptureRecoveryIgnoresUnfinishedFragment() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let parts = root.appendingPathComponent("capture"); try Disk.directory(parts)
        let format = AVAudioFormat(standardFormatWithSampleRate:16000,channels:1)!
        for name in ["part-000000.caf","part-000001.caf","part-000002.partial.caf"] {
            let file = try AVAudioFile(forWriting:parts.appendingPathComponent(name),settings:format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:16000)!; buffer.frameLength = 16000
            memset(buffer.floatChannelData![0],0,16000*4); try file.write(from:buffer)
        }
        let destination = root.appendingPathComponent("original.caf")
        let (frames,rate) = try Media.assembleCapture(parts,destination:destination)
        XCTAssertEqual(frames,32000); XCTAssertEqual(rate,16000)
        XCTAssertEqual(try AVAudioFile(forReading:destination).length,32000)
        XCTAssertTrue(FileManager.default.fileExists(atPath:parts.appendingPathComponent("part-000002.partial.caf").path))
    }
    func testLocalModelChecksumFailureDoesNotPublishReady() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let source = root.appendingPathComponent("source"), models = root.appendingPathComponent("models")
        try Disk.directory(source); try Disk.directory(models)
        try Data("damaged".utf8).write(to:source.appendingPathComponent("weights.bin"))
        let profile = ModelProfile(id:"test",repository:"invalid/test",revision:"fixed",license:"test",files:[ModelFile(path:"weights.bin",localPath:"weights.bin",size:7,sha256:String(repeating:"0",count:64))])
        do { try await ModelInstaller().install(profile,root:models,localSource:source) { _ in }; XCTFail("Corrupt model accepted") }
        catch { XCTAssertFalse(FileManager.default.fileExists(atPath:models.appendingPathComponent("test").path)) }
    }
    func testPauseSplittingDoesNotShiftTimeline() {
        let rate = 1000
        let samples = [Float](repeating: 0.1,count: 5000) + [Float](repeating:0,count:1000) + [Float](repeating:0.1,count:5000)
        let length = Analysis.nextASRWindowLength(samples,rate:rate)
        XCTAssertGreaterThan(length,5000); XCTAssertLessThan(length,6000)
        XCTAssertEqual(Analysis.nextASRWindowLength([Float](repeating:0.1,count:30000),rate:rate),30000)
    }
    func testOverlapDoesNotEraseLaterRepetition() {
        let a = Segment(id: "a", startMs: 100, endMs: 1000, text: "Да", language: "ru")
        let b = Segment(id: "b", startMs: 800, endMs: 1200, text: "Да", language: "ru")
        let c = Segment(id: "c", startMs: 5000, endMs: 6000, text: "Да", language: "ru")
        let result = Analysis.mergeParts([ASRPart(fingerprint: "f", index: 0, startMs: 0, endMs: 1000, segments: [a]), ASRPart(fingerprint: "f", index: 1, startMs: 800, endMs: 6000, segments: [b,c])], fingerprint: "f")
        XCTAssertEqual(result.segments.count, 2)
    }
    func testEmptyOrLateASRRetriesAudiblePrefix() {
        let samples = [Float](repeating: 0.01, count: 16000 * 15)
        XCTAssertEqual(Analysis.missingASRPrefixEnd(segments: [], samples: samples, readStartMs: 0, coreStartMs: 0, coreEndMs: 13_840), 13_840)
        let late = Segment(id: "late", startMs: 13_380, endMs: 14_500, text: "Речь", language: "ru")
        XCTAssertEqual(Analysis.missingASRPrefixEnd(segments: [late], samples: samples, readStartMs: 0, coreStartMs: 0, coreEndMs: 15_000), 13_380)
        let recovered = Segment(id: "early", startMs: 940, endMs: 3240, text: "Начало", language: "ru")
        XCTAssertNil(Analysis.missingASRPrefixEnd(segments: [recovered, late], samples: samples, readStartMs: 0, coreStartMs: 0, coreEndMs: 15_000))
    }
    func testLeadingSilenceAndBriefNoiseDoNotRequestASRRetry() {
        var samples = [Float](repeating: 0, count: 16000 * 15)
        let speech = Segment(id: "speech", startMs: 13_000, endMs: 14_500, text: "Речь после паузы", language: "ru")
        for i in 13 * 16000..<samples.count { samples[i] = 0.1 }
        XCTAssertNil(Analysis.missingASRPrefixEnd(segments: [speech], samples: samples, readStartMs: 0, coreStartMs: 0, coreEndMs: 15_000))
        for i in 16000..<17600 { samples[i] = 0.1 }
        XCTAssertNil(Analysis.missingASRPrefixEnd(segments: [speech], samples: samples, readStartMs: 0, coreStartMs: 0, coreEndMs: 15_000))
        XCTAssertNil(Analysis.missingASRPrefixEnd(segments: [], samples: [Float](repeating: 0.00001, count: 16000 * 15), readStartMs: 0, coreStartMs: 0, coreEndMs: 15_000))
    }
    func testASRPrefixRetryUsesOriginalTimelineAndExcludesContext() {
        var samples = [Float](repeating: 0, count: 16000 * 5)
        // Sound in the preceding context belongs to the previous window.
        for i in 0..<16000 { samples[i] = 0.1 }
        XCTAssertNil(Analysis.missingASRPrefixEnd(segments: [], samples: samples, readStartMs: 29_000, coreStartMs: 30_000, coreEndMs: 33_000))
        for i in 16000..<32000 { samples[i] = 0.01 }
        XCTAssertEqual(Analysis.missingASRPrefixEnd(segments: [], samples: samples, readStartMs: 29_000, coreStartMs: 30_000, coreEndMs: 33_000), 33_000)
    }
    func testWordSpeakerChangesAndOverlap() {
        let t = Transcript(fingerprint: "f", diarized: false, segments: [Segment(id: "a", startMs: 0, endMs: 3000, text: "one two three", language: "en", words: [Word(text: "one", startMs: 0, endMs: 1000), Word(text: " two", startMs: 1000, endMs: 2000), Word(text: " three", startMs: 2000, endMs: 3000)])])
        let mapped = Analysis.assignSpeakers(t, intervals: [VoiceInterval(startMs: 0, endMs: 1000, speakerId: "x"), VoiceInterval(startMs: 1000, endMs: 3000, speakerId: "y"), VoiceInterval(startMs: 2000, endMs: 3000, speakerId: "x")])
        XCTAssertEqual(mapped.segments.map(\.speakerId), ["speaker-1", "speaker-2", nil]); XCTAssertTrue(mapped.segments[2].overlap)
    }
    func testRejectsInventedEvidenceAndOwner() throws {
        let t = Transcript(fingerprint: "f", diarized: true, segments: [Segment(id: "a", startMs: 0, endMs: 1000, speakerId: "speaker-1", text: "Я проверю завтра", language: "ru")])
        let f = Finding(id: "t", text: "Проверить", evidenceSegmentIds: ["missing"])
        XCTAssertThrowsError(try Summary(language: "ru", tasks: [f]).validate(against: t))
        XCTAssertThrowsError(try Summary(language: "ru", tasks: [Finding(id: "t", text: "Проверить", evidenceSegmentIds: ["a"], ownerName: "Иван")]).validate(against: t))
        XCTAssertNoThrow(try Summary(language: "ru", tasks: [Finding(id: "t", text: "Проверить", evidenceSegmentIds: ["a"], ownerSpeakerId: "speaker-1", dueText: "завтра")]).validate(against: t))
    }
    func testTimeBoundsAndUTF8ExportWithoutModels() throws {
        var m = Manifest(sourceType: "import", title: "Русский [тест]", filename: "a.wav"); m.durationMs = 10_800_000; m.sourceComplete = true
        let t = Transcript(fingerprint: "f", diarized: false, segments: [Segment(id: "last", startMs: 10_799_000, endMs: 10_800_000, text: "Конец встречи", language: "ru")])
        try t.validate(durationMs: m.durationMs)
        let text = ExportService.render(manifest: m, transcript: t, summary: nil, markdown: false)
        XCTAssertTrue(text.contains("03:00:00")); XCTAssertTrue(text.contains("Конец встречи")); XCTAssertFalse(text.contains("##")); XCTAssertTrue(text.contains("Участники не определены"))
    }
    func testFailedRunPreservesActiveAndCorruptArchiveEntry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root)
        var m = Manifest(sourceType: "import", title: "x", filename: "a.wav"); m.activeRunId = "old"; m.pendingRunId = "new"; m.state = .transcribing
        try repo.save(m); try repo.recover()
        let recovered = try repo.load(m.id)
        XCTAssertEqual(recovered.activeRunId, "old"); XCTAssertEqual(recovered.state, .interrupted)
        try Disk.directory(repo.folder("broken")); try Data("bad".utf8).write(to: repo.folder("broken").appendingPathComponent("manifest.json"))
        XCTAssertEqual(repo.list().count, 1)
    }
}
