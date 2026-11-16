import CoreMedia
import SwiftUI
import LocalScribeCore

struct LiveCaptionText {
    struct Phrase {
        var range: CMTimeRange
        var text: String
    }

    private(set) var phrases: [String]
    private(set) var tentative: [Phrase] = []

    init(phrases: [String] = []) { self.phrases = phrases }

    mutating func receive(_ update: LiveCaptionUpdate) {
        // A module can revise a phrase, or finalize its last revision without
        // emitting the same text again.
        tentative.removeAll {
            $0.range.start == update.range.start || $0.range.intersection(update.range).duration > .zero
        }
        let text = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            let index = tentative.firstIndex { $0.range.start > update.range.start } ?? tentative.endIndex
            tentative.insert(Phrase(range: update.range, text: text), at: index)
        }
        if update.finalizedThrough.isValid {
            let count = tentative.prefix { $0.range.end <= update.finalizedThrough }.count
            phrases.append(contentsOf: tentative.prefix(count).map(\.text))
            tentative.removeFirst(count)
        }
    }

    mutating func freeze() {
        phrases.append(contentsOf: tentative.map(\.text))
        tentative.removeAll()
    }
}

@MainActor final class RecordingLiveCaptions: ObservableObject {
    enum Phase: Equatable {
        case preparing, listening, stopped, languageUnavailable, recognitionFailed, saveFailed
    }

    let recordingID: String
    @Published private(set) var text: LiveCaptionText
    @Published private(set) var phase: Phase = .stopped
    var isRunning: Bool { input != nil }

    private let archive: RecordingCoordinator
    private var input: LiveCaptionAudio?
    private var recognitionTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var lastSavedCount: Int?
    private var finishWaiter: CheckedContinuation<Void, Never>?
    private var finishDeadline: Task<Void, Never>?

    init(recordingID: String, archive: RecordingCoordinator, phrases: [String]? = nil) {
        self.recordingID = recordingID
        self.archive = archive
        text = LiveCaptionText(phrases: phrases ?? [])
        lastSavedCount = phrases?.count
    }

    func start(locale: Locale, recognize: @escaping LiveCaptionRecognition.Recognizer) -> LiveCaptionAudio {
        let audio = LiveCaptionAudio()
        input = audio
        phase = .preparing
        save()
        recognitionTask = Task { [weak self] in
            do {
                try await recognize(locale, audio.stream, { [weak self] in
                    await self?.beginListening(on: audio)
                }, { [weak self] update in
                    await self?.receive(update, on: audio)
                })
                self?.end(audio, phase: .stopped)
            } catch LiveCaptionRecognition.Failure.languageUnavailable {
                self?.end(audio, phase: .languageUnavailable)
            } catch is CancellationError where self?.finishWaiter != nil {
                self?.end(audio, phase: .stopped)
            } catch {
                self?.end(audio, phase: .recognitionFailed)
            }
        }
        return audio
    }

    private func beginListening(on audio: LiveCaptionAudio) {
        guard input === audio, phase != .saveFailed else { return }
        phase = .listening
    }

    private func receive(_ update: LiveCaptionUpdate, on audio: LiveCaptionAudio) async {
        guard input === audio else { return }
        text.receive(update)
        save()
        await saveTask?.value
    }

    func freeze() {
        guard let input else { return }
        recognitionTask?.cancel()
        end(input, phase: .stopped)
    }

    /// Let the recognizer flush the last phrase. A slow system download or
    /// analyzer cannot hold up the saved audio or the main transcription.
    func finish() async {
        if let input {
            input.finish()
            await withCheckedContinuation { continuation in
                finishWaiter = continuation
                finishDeadline = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    self?.freeze()
                }
            }
        }
        await saveTask?.value
    }

    private func end(_ audio: LiveCaptionAudio, phase: Phase) {
        guard input === audio else { return }
        input = nil
        recognitionTask = nil
        audio.finish()
        text.freeze()
        if self.phase != .saveFailed { self.phase = phase }
        save()
        finishDeadline?.cancel()
        finishDeadline = nil
        finishWaiter?.resume()
        finishWaiter = nil
    }

    private func save() {
        let phrases = text.phrases
        guard lastSavedCount != phrases.count else { return }
        lastSavedCount = phrases.count
        let previous = saveTask
        saveTask = Task { [weak self, archive, recordingID] in
            await previous?.value
            do {
                try await archive.perform { try $0.saveLiveCaptions(phrases, for: recordingID) }
            } catch {
                guard let self else { return }
                if self.lastSavedCount == phrases.count { self.lastSavedCount = nil }
                self.phase = .saveFailed
            }
        }
    }
}
