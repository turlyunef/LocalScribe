import Combine
import Foundation
import XCTest
import LocalScribeCore
@testable import LocalScribe

@MainActor
final class ResultPresentationTests: XCTestCase {
    private func fixture() -> (Manifest, Transcript, Summary) {
        var manifest = Manifest(sourceType: "import", title: "Длинная встреча 😀", filename: "meeting.wav")
        manifest.durationMs = 10_800_000; manifest.sourceComplete = true
        manifest.activeRunId = UUID().uuidString; manifest.state = .completed; manifest.sha256 = "audio"
        let segments = (0..<10_800).map { index in
            Segment(id: "s\(index)", startMs: index * 1000, endMs: (index + 1) * 1000,
                    text: "Реплика \(index) 😀 [план] " + String(repeating: "обсуждение ", count: 10), language: "ru")
        }
        let findings = (0..<1000).map { index in
            Finding(id: "f\(index)", text: "Вывод \(index) 😀", evidenceSegmentIds: ["s\(index + 1)", "s\(index)"])
        }
        let run = RunInfo(id: manifest.activeRunId!, sourceHash: manifest.sha256, profileHash: "profile")
        return (manifest, Transcript(fingerprint: run.fingerprint, diarized: true, segments: segments), Summary(language: "ru", overview: findings))
    }

    private func ready(_ presentation: ResultPresentation) async throws {
        await presentation.task?.value
        XCTAssertFalse(presentation.isRendering)
    }

    private func save(_ manifest: Manifest, _ transcript: Transcript, _ summary: Summary, to repo: RecordingRepository) throws {
        let run = RunInfo(id: manifest.activeRunId!, sourceHash: manifest.sha256, profileHash: "profile")
        let path = repo.run(manifest.id, run.id)
        try Disk.write(run, to: path.appendingPathComponent("run.json"))
        try Disk.write(transcript, to: path.appendingPathComponent("transcript.json"))
        try Disk.write(summary, to: path.appendingPathComponent("summary.json"))
        try repo.save(manifest)
    }

    private func loaded(_ model: AppModel) async throws {
        let deadline = Date().addingTimeInterval(5)
        while model.transcript == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(model.transcript)
        XCTAssertTrue(model.errorHandler.messages.isEmpty)
        try await ready(model.resultPresentation)
    }

    private func assertLinks(_ rendered: RenderedExport, file: StaticString = #filePath, line: UInt = #line) {
        let text = rendered.text as NSString
        for link in rendered.timestamps {
            let seconds = Int(link.segmentID.dropFirst())! * 1000
            XCTAssertEqual(text.substring(with: link.range), "[\(timecode(seconds))]", file: file, line: line)
        }
    }

    func testLongResultDoesNotRenderOrPublishAppModelOnMeterAndProgressUpdates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root)
        let (manifest, transcript, summary) = fixture()
        try save(manifest, transcript, summary, to: repo)
        let model = AppModel(repository: repo, startServices: false)
        model.selection = manifest.id
        try await loaded(model)
        model.recordingID = UUID().uuidString // Open an old meeting while a new capture is active.
        let baseline = model.resultPresentation.renderCount
        var appChanges = 0
        let observation = model.objectWillChange.sink { appChanges += 1 }
        defer { observation.cancel() }
        for tick in 0..<300 {
            model.level = Double(tick % 10) / 10; model.elapsed = Double(tick) / 10
            model.soundNotice = tick.isMultiple(of: 2) ? "Тихий звук" : nil
            model.status = "Распознаём речь: \(tick)"
            _ = model.renderedResult(.transcript)
        }
        await Task.yield()
        XCTAssertEqual(appChanges, 0)
        XCTAssertEqual(model.resultPresentation.renderCount, baseline)
        XCTAssertTrue(model.resultPresentation.result.text.contains("Реплика 10799"))
        assertLinks(model.resultPresentation.result)
    }

    func testTitleResultTabAndFormatInvalidateOnlyTheirCacheEntries() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root)
        var (manifest, transcript, summary) = fixture()
        try save(manifest, transcript, summary, to: repo)
        let model = AppModel(repository: repo, startServices: false)
        model.selection = manifest.id
        try await loaded(model)
        let baseline = model.resultPresentation.renderCount
        model.tab = .summary; try await ready(model.resultPresentation)
        XCTAssertFalse(model.resultPresentation.result.text.contains("Реплика 10799"))
        XCTAssertEqual(model.resultPresentation.result.timestamps.prefix(2).map(\.segmentID), ["s0", "s1"])
        assertLinks(model.resultPresentation.result)
        model.tab = .transcript
        XCTAssertEqual(model.resultPresentation.renderCount, baseline + 1)
        XCTAssertTrue(model.resultPresentation.result.text.contains("Реплика 10799"))
        await model.renameRecording(manifest.id, title: "Новое имя 🧑🏽‍💻 [проект]")
        try await ready(model.resultPresentation)
        XCTAssertTrue(model.resultPresentation.result.text.hasPrefix("Новое имя 🧑🏽‍💻 [проект]"))
        assertLinks(model.resultPresentation.result)
        let plain = model.renderedResult(.transcript)
        let beforeMarkdown = model.resultPresentation.renderCount
        let markdown = model.renderedResult(.transcript, markdown: true)
        XCTAssertEqual(model.resultPresentation.renderCount, beforeMarkdown + 1)
        XCTAssertTrue(markdown.text.hasPrefix("# Новое имя 🧑🏽‍💻 \\[проект\\]"))
        XCTAssertEqual(model.renderedResult(.transcript, markdown: true), markdown)
        XCTAssertEqual(model.renderedResult(.transcript), plain)
        XCTAssertEqual(model.resultPresentation.renderCount, beforeMarkdown + 1)
        assertLinks(markdown)
        // A fingerprint can stay unchanged after an in-memory content revision.
        transcript.segments[0].text = "Исправлено 😀"
        model.transcript = transcript
        try await ready(model.resultPresentation)
        XCTAssertTrue(model.resultPresentation.result.text.contains("Исправлено 😀"))
        summary.overview[0].text = "Новый вывод"; summary.overview[0].evidenceSegmentIds = ["s9"]
        model.summary = summary; model.tab = .summary
        try await ready(model.resultPresentation)
        XCTAssertTrue(model.resultPresentation.result.text.contains("Новый вывод"))
        XCTAssertEqual(model.resultPresentation.result.timestamps.first?.segmentID, "s9")
        assertLinks(model.resultPresentation.result)
        manifest = try repo.load(manifest.id)
        manifest.warnings = ["Проверить 😀"]; manifest.pendingRunId = "next"
        manifest.durationMs -= 1000; manifest.recordedAt = manifest.createdAt; manifest.sourceComplete = false
        try repo.save(manifest); model.recordings = repo.list()
        try await ready(model.resultPresentation)
        let updated = model.resultPresentation.result.text
        XCTAssertTrue(updated.contains("Готово с предупреждениями"))
        XCTAssertTrue(updated.contains("Дата записи:")); XCTAssertTrue(updated.contains("02:59:59"))
        XCTAssertTrue(updated.contains("Показан предыдущий успешный результат"))
        XCTAssertTrue(updated.contains("Проверить 😀")); XCTAssertTrue(updated.contains("Запись неполная"))
    }

    func testIrrelevantManifestChangesReuseCache() async throws {
        var (manifest, transcript, summary) = fixture()
        let presentation = ResultPresentation()
        presentation.update(manifest: manifest, transcript: transcript, summary: summary, revision: 1, part: .summary)
        try await ready(presentation)
        let baseline = presentation.renderCount
        manifest.lastError = "Сообщение"; manifest.captureProcessing = .transcribing
        manifest.state = .summarizing // An active result still displays “Готово”.
        presentation.update(manifest: manifest, transcript: transcript, summary: summary, revision: 1, part: .summary)
        XCTAssertEqual(presentation.renderCount, baseline)
        XCTAssertFalse(presentation.isRendering)
    }

    func testCancelledBackgroundRenderCannotRestoreOldTextOrLinks() async throws {
        let started = expectation(description: "Background renderer started")
        let release = DispatchSemaphore(value: 0)
        let presentation = ResultPresentation { manifest, transcript, summary, part, markdown in
            XCTAssertFalse(Thread.isMainThread)
            started.fulfill()
            _ = release.wait(timeout: .now() + 5)
            return ExportService.renderResult(manifest: manifest, transcript: transcript, summary: summary, part: part, markdown: markdown)
        }
        let (manifest, transcript, summary) = fixture()
        presentation.update(manifest: manifest, transcript: transcript, summary: summary, revision: 1, part: .summary)
        let oldTask = try XCTUnwrap(presentation.task)
        await fulfillment(of: [started], timeout: 3)
        presentation.update(manifest: nil, transcript: nil, summary: nil, revision: 2, part: .transcript)
        XCTAssertTrue(presentation.result.text.isEmpty); XCTAssertTrue(presentation.result.timestamps.isEmpty)
        release.signal(); await oldTask.value
        XCTAssertTrue(presentation.result.text.isEmpty); XCTAssertTrue(presentation.result.timestamps.isEmpty)
        XCTAssertFalse(presentation.isRendering)
    }

    func testOlderRenderCannotOverwriteNewerTitleAndResult() async throws {
        let started = expectation(description: "Old result renderer started")
        let release = DispatchSemaphore(value: 0)
        let presentation = ResultPresentation { manifest, transcript, summary, part, markdown in
            if manifest.displayTitle == "Старое имя" {
                started.fulfill()
                _ = release.wait(timeout: .now() + 5)
            }
            return ExportService.renderResult(manifest: manifest, transcript: transcript, summary: summary, part: part, markdown: markdown)
        }
        var (manifest, transcript, summary) = fixture()
        manifest.displayTitle = "Старое имя"
        presentation.update(manifest: manifest, transcript: transcript, summary: summary, revision: 1, part: .summary)
        let oldTask = try XCTUnwrap(presentation.task)
        await fulfillment(of: [started], timeout: 3)
        manifest.displayTitle = "Новое имя 😀"
        summary.overview = [Finding(id: "new", text: "Новый вывод", evidenceSegmentIds: ["s99"])]
        presentation.update(manifest: manifest, transcript: transcript, summary: summary, revision: 2, part: .summary)
        try await ready(presentation)
        let current = presentation.result
        XCTAssertTrue(current.text.hasPrefix("Новое имя 😀"))
        XCTAssertEqual(current.timestamps.map(\.segmentID), ["s99"])
        release.signal(); await oldTask.value
        XCTAssertEqual(presentation.result, current)
    }

    func testRapidChangesCoalesceAndSelectionCannotReusePreviousRecordingCache() async throws {
        var (manifest, transcript, summary) = fixture()
        let presentation = ResultPresentation()
        for revision in 0..<20 {
            manifest.displayTitle = "Версия \(revision) 😀"
            presentation.update(manifest: manifest, transcript: transcript, summary: summary, revision: UInt64(revision), part: .summary)
        }
        try await ready(presentation)
        XCTAssertEqual(presentation.renderCount, 1)
        XCTAssertTrue(presentation.result.text.hasPrefix("Версия 19 😀"))
        manifest.id = UUID().uuidString; manifest.displayTitle = "Другая встреча"
        presentation.update(manifest: manifest, transcript: nil, summary: nil, revision: 20, part: .transcript)
        XCTAssertTrue(presentation.result.text.isEmpty); XCTAssertTrue(presentation.result.timestamps.isEmpty)
        try await ready(presentation)
        XCTAssertTrue(presentation.result.text.hasPrefix("Другая встреча"))
        XCTAssertTrue(presentation.result.timestamps.isEmpty)
    }
}
