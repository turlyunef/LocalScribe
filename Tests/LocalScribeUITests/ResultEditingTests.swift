import AppKit
import SwiftUI
import XCTest
import LocalScribeCore
@testable import LocalScribe

@MainActor
final class ResultEditingModelTests: XCTestCase {
    private func fixture() throws -> (URL, RecordingRepository, Manifest) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repo = try RecordingRepository(root: root)
        var manifest = Manifest(sourceType: "import", title: "Встреча", filename: "meeting.wav")
        manifest.sha256 = "audio"; manifest.durationMs = 1000; manifest.state = .completed
        let run = RunInfo(sourceHash: manifest.sha256, profileHash: "profile")
        let path = repo.run(manifest.id, run.id)
        try Disk.write(run, to: path.appendingPathComponent("run.json"))
        try Disk.write(Transcript(fingerprint: run.fingerprint, diarized: true,
                                 segments: [Segment(id: "s", startMs: 0, endMs: 1000, text: "Фраза", language: "ru")]),
                       to: path.appendingPathComponent("transcript.json"))
        try Disk.write(Summary(language: "ru", overview: [Finding(id: "f", text: "Обзор", evidenceSegmentIds: ["s"])]),
                       to: path.appendingPathComponent("summary.json"))
        manifest.activeRunId = run.id; try repo.save(manifest)
        return (root, repo, manifest)
    }

    private func waitForResult(_ model: AppModel) async throws {
        let deadline = Date().addingTimeInterval(3)
        while model.transcript == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(model.transcript)
    }

    func testSaveRefreshesDisplayCopyAndExportData() async throws {
        let (root, repo, manifest) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(repository: repo, startServices: false)
        model.selection = manifest.id; try await waitForResult(model)
        XCTAssertTrue(model.canEditResult)
        model.beginResultEditing()
        var draft = try XCTUnwrap(model.resultEdit)
        draft.transcript.segments[0].text = "Исправленная фраза 😀"
        draft.summary?.overview[0].text = "Исправленный обзор"
        try await model.saveResultEdits(draft)
        try await waitForResult(model)
        XCTAssertNil(model.resultEdit); XCTAssertFalse(model.savingResult)
        XCTAssertTrue(model.rendered(.transcript).contains("Исправленная фраза 😀"))
        XCTAssertTrue(model.rendered(.summary, markdown: true).contains("Исправленный обзор"))
        XCTAssertNotEqual(model.selected?.activeRunId, manifest.activeRunId)
    }

    func testCancelAndSelectionChangeDiscardDraftWithoutChangingSavedResult() async throws {
        let (root, repo, manifest) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(repository: repo, startServices: false)
        model.selection = manifest.id; try await waitForResult(model)
        model.beginResultEditing(); model.resultEdit?.transcript.segments[0].text = "Черновик"
        model.resultEdit = nil
        XCTAssertEqual(model.transcript?.segments[0].text, "Фраза")
        model.beginResultEditing()
        model.selection = nil
        XCTAssertNil(model.resultEdit); XCTAssertNil(model.transcript); XCTAssertNil(model.summary)
        XCTAssertFalse(model.canEditResult)
        XCTAssertEqual(try repo.load(manifest.id).activeRunId, manifest.activeRunId)
    }

    func testFailedSaveKeepsDraftAndPreviouslyPublishedResult() async throws {
        let (root, repo, manifest) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(repository: repo, startServices: false)
        model.selection = manifest.id; try await waitForResult(model)
        model.beginResultEditing()
        var draft = try XCTUnwrap(model.resultEdit); draft.summary?.overview[0].text = ""
        do { try await model.saveResultEdits(draft); XCTFail("Invalid summary saved") } catch { }
        XCTAssertNotNil(model.resultEdit); XCTAssertFalse(model.savingResult)
        XCTAssertEqual(model.summary?.overview[0].text, "Обзор")
        XCTAssertEqual(try repo.load(manifest.id).activeRunId, manifest.activeRunId)
        draft.summary?.overview[0].text = "Исправлено"
        try await model.saveResultEdits(draft)
        try await waitForResult(model)
        XCTAssertEqual(model.summary?.overview[0].text, "Исправлено")
    }

    func testEditingUnavailableDuringProcessingAndForPartialResults() async throws {
        let (root, repo, manifest) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(repository: repo, startServices: false)
        model.selection = manifest.id; try await waitForResult(model)
        model.busy = true; XCTAssertFalse(model.canEditResult)
        model.beginResultEditing(); XCTAssertNil(model.resultEdit)
        model.busy = false
        var current = manifest; current.pendingRunId = UUID().uuidString
        try repo.save(current); model.reload(); try await waitForResult(model)
        XCTAssertFalse(model.canEditResult)
        current = manifest; current.activeRunId = nil; current.pendingRunId = manifest.activeRunId
        current.state = .interrupted; try repo.save(current); model.reload(); try await waitForResult(model)
        XCTAssertFalse(model.canEditResult)
    }

    func testImportCompletionPreservesOpenDraftAndSelection() async throws {
        let (root, repo, manifest) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(repository: repo, startServices: false)
        model.selection = manifest.id; try await waitForResult(model)
        model.beginResultEditing()
        model.resultEdit?.transcript.segments[0].text = "Несохранённый черновик"
        var imported = Manifest(sourceType: "import", title: "Новый импорт", filename: "new.wav")
        imported.sourceComplete = true; try repo.save(imported)
        model.completeImport(imported)
        XCTAssertEqual(model.selection, manifest.id)
        XCTAssertEqual(model.resultEdit?.transcript.segments[0].text, "Несохранённый черновик")
        XCTAssertEqual(model.transcript?.segments[0].text, "Фраза")
        XCTAssertEqual(try repo.load(imported.id).state, .waitingForModels)
        model.resultEdit = nil
        model.completeImport(imported)
        XCTAssertEqual(model.selection, imported.id)
    }

    func testRecordingTransitionsPreventOpeningEditor() async throws {
        let (root, repo, manifest) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(repository: repo, startServices: false)
        model.selection = manifest.id; try await waitForResult(model)
        model.startingRecording = true; XCTAssertFalse(model.canEditResult)
        model.startingRecording = false; model.finalizingRecording = true
        XCTAssertFalse(model.canEditResult)
        model.finalizingRecording = false; model.recordingID = UUID().uuidString
        XCTAssertFalse(model.canEditResult)
    }

    func testSummaryRegenerationAfterEditingSkipsAllAudioStages() async throws {
        let (root, repo, manifest) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(repository: repo, startServices: false)
        model.selection = manifest.id; try await waitForResult(model)
        model.beginResultEditing()
        var draft = try XCTUnwrap(model.resultEdit)
        draft.transcript.segments[0].text = "Исправленная фраза"
        try await model.saveResultEdits(draft)
        var saved = try repo.load(manifest.id)
        let info = try repo.beginRun(&saved, catalog: ModelCatalog(models: []), summaryOnly: true)
        let run = repo.run(saved.id, info.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.appendingPathComponent("work/audio.wav").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.appendingPathComponent("asr-transcript.json").path))
        for stage in [Stage.preparingAudio, .transcribing, .diarizing] {
            XCTAssertTrue(try model.stageComplete(stage, run: run, manifest: saved, info: info))
        }
        XCTAssertFalse(try model.stageComplete(.summarizing, run: run, manifest: saved, info: info))
        var bad = try Disk.read(Transcript.self, at: run.appendingPathComponent("transcript.json"))
        bad.fingerprint = "wrong"; try Disk.write(bad, to: run.appendingPathComponent("transcript.json"))
        XCTAssertFalse(try model.stageComplete(.transcribing, run: run, manifest: saved, info: info))
        bad.fingerprint = info.fingerprint; bad.segments[0].endMs = saved.durationMs + 1
        try Disk.write(bad, to: run.appendingPathComponent("transcript.json"))
        XCTAssertThrowsError(try model.stageComplete(.transcribing, run: run, manifest: saved, info: info))
    }

    func testStaleEditorCannotOverwriteNewActiveRun() async throws {
        let (root, repo, manifest) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(repository: repo, startServices: false)
        model.selection = manifest.id; try await waitForResult(model)
        model.beginResultEditing()
        let draft = try XCTUnwrap(model.resultEdit)
        var newer = draft; newer.transcript.segments[0].text = "Другая версия"
        let saved = try repo.saveResultEdits(newer)
        do { try await model.saveResultEdits(draft); XCTFail("Stale editor saved") } catch { }
        XCTAssertNotNil(model.resultEdit)
        XCTAssertEqual(try repo.load(manifest.id).activeRunId, saved.activeRunId)
    }
}

@MainActor
final class ResultEditorViewTests: XCTestCase {
    private func descendants(_ element: AnyObject) -> [AnyObject] {
        let children = (element.accessibilityChildren?() ?? []).map { $0 as AnyObject }
        return children + children.flatMap { descendants($0) }
    }

    private func checkDeletion(referenced: Bool, confirm: Bool = true) async throws {
        _ = NSApplication.shared
        NSApplication.shared.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let initial = ResultEditDraft(recordingID: UUID().uuidString, runID: UUID().uuidString,
            transcript: Transcript(fingerprint: "f", diarized: true, segments: [
                Segment(id: "s", startMs: 0, endMs: 1000, text: "Удаляемая фраза", language: "ru"),
                Segment(id: "keep", startMs: 1000, endMs: 2000, text: "Оставшаяся фраза", language: "ru")]),
            summary: Summary(language: "ru", tasks: [Finding(id: "f", text: "Задача",
                evidenceSegmentIds: [referenced ? "s" : "keep"])]))
        var saved: ResultEditDraft?
        var errors: [String] = []
        let hosting = NSHostingView(rootView: ResultEditorView(initial: initial, save: { saved = $0 },
            cancel: {}, reportError: { errors.append($0.localizedDescription) }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderFront(nil)
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        func button(_ id: String) -> AnyObject? {
            descendants(hosting).first { $0.accessibilityIdentifier?() == id }
        }
        func waitUntil(_ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(3)
            while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(condition())
        }
        func alertWindow() -> NSWindow? {
            NSApp.windows.first { candidate in
                candidate !== window && candidate.isVisible && descendants(candidate).contains {
                    $0.accessibilityLabel?() == "Удалить связь и реплику"
                }
            }
        }
        try await waitUntil { button("edit.deleteSegment.s") != nil }
        XCTAssertTrue(try XCTUnwrap(button("edit.deleteSegment.s")).accessibilityPerformPress?() ?? false)
        if referenced {
            try await waitUntil { alertWindow() != nil }
            // Opening and cancelling the warning must not change the draft.
            XCTAssertFalse(button("edit.save")?.isAccessibilityEnabled?() ?? true)
            let alert = try XCTUnwrap(alertWindow())
            let title = confirm ? "Удалить связь и реплику" : "Отмена"
            let action = try XCTUnwrap(descendants(alert).first {
                ($0.accessibilityTitle?() == title || $0.accessibilityLabel?() == title)
                    && $0.accessibilityRole?() == .button
            })
            // Native alert buttons can return false even when their action runs.
            // Verify dismissal and the resulting draft instead.
            _ = action.accessibilityPerformPress?()
            try await waitUntil { alertWindow() == nil }
        } else {
            XCTAssertNil(alertWindow())
        }
        if !referenced || confirm {
            try await waitUntil { button("edit.deleteSegment.s") == nil }
            XCTAssertNotNil(button("edit.deleteSegment.keep"))
            XCTAssertTrue(try XCTUnwrap(button("edit.save")).accessibilityPerformPress?() ?? false)
            try await waitUntil { saved != nil }
            XCTAssertEqual(saved?.transcript.segments.map(\.id), ["keep"])
            XCTAssertEqual(saved?.summary?.tasks[0].evidenceSegmentIds, referenced ? [] : ["keep"])
            XCTAssertEqual(saved?.summary?.tasks[0].text, "Задача")
        } else {
            XCTAssertNotNil(button("edit.deleteSegment.s"))
            XCTAssertFalse(button("edit.save")?.isAccessibilityEnabled?() ?? true)
            XCTAssertNil(saved)
        }
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(initial.transcript.segments.count, 2)
    }

    func testUnreferencedTurnDeletesWithoutWarning() async throws {
        try await checkDeletion(referenced: false)
    }

    func testReferencedTurnConfirmationDeletesTurnAndEvidence() async throws {
        try await checkDeletion(referenced: true)
    }

    func testReferencedTurnCancellationKeepsDraftUnchanged() async throws {
        try await checkDeletion(referenced: true, confirm: false)
    }

    func testFailedSaveReportsThroughHandlerAndRetryKeepsDraft() async throws {
        _ = NSApplication.shared
        NSApplication.shared.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let initial = ResultEditDraft(recordingID: UUID().uuidString, runID: UUID().uuidString,
            transcript: Transcript(fingerprint: "f", diarized: true,
                segments: [Segment(id: "s", startMs: 0, endMs: 1000, text: "Исходная фраза", language: "ru")]), summary: nil)
        var saved: ResultEditDraft?
        var cancelled = false
        var attempts = 0
        let errors = AppErrorHandler()
        let hosting = NSHostingView(rootView: ResultEditorView(initial: initial,
            save: {
                attempts += 1
                if attempts == 1 { throw ScribeError.message("Не удалось сохранить правки") }
                saved = $0
            }, cancel: { cancelled = true }, reportError: errors.report))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderFront(nil)
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        func button(_ id: String) throws -> AnyObject {
            try XCTUnwrap(descendants(hosting).first { $0.accessibilityIdentifier?() == id })
        }
        let deadline = Date().addingTimeInterval(3)
        while descendants(hosting).first(where: { $0.accessibilityIdentifier?() == "edit.save" }) == nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(try button("edit.save").isAccessibilityEnabled?() ?? true)
        func textView(_ view: NSView) -> NSTextView? {
            if let text = view as? NSTextView { return text }
            return view.subviews.lazy.compactMap { textView($0) }.first
        }
        let editor = try XCTUnwrap(textView(hosting))
        editor.selectAll(nil); editor.insertText("Исправлено 😀", replacementRange: editor.selectedRange())
        // Let SwiftUI propagate the NSTextView binding to the Save button.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(try button("edit.save").isAccessibilityEnabled?() ?? false)
        XCTAssertTrue(try button("edit.save").accessibilityPerformPress?() ?? false)
        let errorDeadline = Date().addingTimeInterval(3)
        while errors.messages.isEmpty && Date() < errorDeadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(errors.messages, ["Не удалось сохранить правки"])
        XCTAssertNil(saved)
        XCTAssertFalse(cancelled)
        XCTAssertEqual(editor.string, "Исправлено 😀")
        errors.dismissCurrent()
        let retryDeadline = Date().addingTimeInterval(3)
        while !(try button("edit.save").isAccessibilityEnabled?() ?? false) && Date() < retryDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(try button("edit.save").isAccessibilityEnabled?() ?? false)
        XCTAssertTrue(try button("edit.save").accessibilityPerformPress?() ?? false)
        let saveDeadline = Date().addingTimeInterval(3)
        while saved == nil && Date() < saveDeadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(saved?.transcript.segments[0].text, "Исправлено 😀")
        XCTAssertEqual(initial.transcript.segments[0].text, "Исходная фраза")
        XCTAssertFalse(cancelled)
        XCTAssertTrue(try button("edit.cancel").accessibilityPerformPress?() ?? false)
        XCTAssertTrue(cancelled)
    }
}
