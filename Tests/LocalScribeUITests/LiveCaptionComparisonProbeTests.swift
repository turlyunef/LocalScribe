import AVFoundation
import CoreMedia
import Foundation
import LocalScribeCore
import Speech
import XCTest
@testable import LocalScribe

/// Explicit, read-only replay. Never enters AppModel, the archive, or the worker queue.
@MainActor final class LiveCaptionComparisonProbeTests: XCTestCase {
    struct Input: Codable {
        var schemaVersion: Int
        var speed: Double
        var sources: [Source]
    }

    struct Source: Codable {
        var id: String
        var audioPath: String
        var audioSHA256: String
        var transcriptPath: String
        var transcriptSHA256: String
        var durationMs: Int
        var language: String
    }

    struct Phrase: Codable, Sendable {
        var startMs: Int
        var endMs: Int
        var text: String
    }

    struct Output: Codable {
        var schemaVersion = 1
        var source: Source
        var speed: Double
        var consumedFrames: Int64
        var droppedBuffers: Int
        var elapsedSeconds: Double
        var readyAfterSeconds: Double?
        var unfinishedPhrases: Int
        var segments: [Phrase]
    }

    actor Collector {
        private var pending: [LiveCaptionUpdate] = []
        private var committed: [Phrase] = []

        func receive(_ update: LiveCaptionUpdate) {
            pending.removeAll {
                $0.range.start == update.range.start || $0.range.intersection(update.range).duration > .zero
            }
            if !update.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pending.append(update)
                pending.sort { $0.range.start < $1.range.start }
            }
            guard update.finalizedThrough.isNumeric else { return }
            let count = pending.prefix { $0.range.end <= update.finalizedThrough }.count
            for phrase in pending.prefix(count) {
                guard phrase.range.start.isNumeric, phrase.range.end.isNumeric else { continue }
                committed.append(Phrase(startMs: Int((phrase.range.start.seconds * 1000).rounded()),
                                        endMs: Int((phrase.range.end.seconds * 1000).rounded()), text: phrase.text))
            }
            pending.removeFirst(count)
        }

        func snapshot() -> ([Phrase], Int) { (committed, pending.count) }
    }

    func testCollectorKeepsRevisionsAndExcludesAnUnfinishedTail() async {
        let collector = Collector()
        let first = CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1))
        await collector.receive(.init(range: first, finalizedThrough: .zero, text: "draft"))
        await collector.receive(.init(range: first, finalizedThrough: first.end, text: "final"))
        let tail = CMTimeRange(start: first.end, duration: first.duration)
        await collector.receive(.init(range: tail, finalizedThrough: first.end, text: "unfinished"))
        let (phrases, unfinished) = await collector.snapshot()
        XCTAssertEqual(phrases.map(\.text), ["final"])
        XCTAssertEqual(phrases.first?.endMs, 1000)
        XCTAssertEqual(unfinished, 1)
    }

    func testExplicitLiveCaptionComparisonProbe() async throws {
        guard let folder = ProcessInfo.processInfo.environment["LOCALSCRIBE_CAPTION_COMPARISON"] else {
            throw XCTSkip("Opt-in: use scripts/probe_live_caption_comparison.py")
        }
        let root = URL(fileURLWithPath: folder).resolvingSymlinksInPath()
        let allowed = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("TestResults").resolvingSymlinksInPath()
        guard root.path.hasPrefix(allowed.path + "/") else { throw ScribeError.message("Probe output must be in TestResults") }
        let input = try Disk.read(Input.self, at: root.appendingPathComponent("input.json"))
        guard input.schemaVersion == 1, (1...8).contains(input.speed), !input.sources.isEmpty,
              input.sources.count <= 20, Set(input.sources.map(\.id)).count == input.sources.count else {
            throw ScribeError.message("Invalid caption comparison input")
        }
        for source in input.sources {
            guard source.id.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) != nil,
                  (1...180_000).contains(source.durationMs),
                  ["russian", "english", "mixed"].contains(source.language) else {
                throw ScribeError.message("Invalid caption comparison source")
            }
            let audio = URL(fileURLWithPath: source.audioPath)
            let transcript = URL(fileURLWithPath: source.transcriptPath)
            guard try Disk.hash(audio) == source.audioSHA256, try Disk.hash(transcript) == source.transcriptSHA256 else {
                throw ScribeError.message("Comparison input changed")
            }
            // Do not download packages as a side effect of a technical experiment.
            try await requireInstalledModels(language: source.language)
            let result = try await replay(source: source, audio: audio, speed: input.speed)
            guard result.droppedBuffers == 0, result.consumedFrames > 0,
                  try Disk.hash(audio) == source.audioSHA256, try Disk.hash(transcript) == source.transcriptSHA256 else {
                throw ScribeError.message("Incomplete or changed caption comparison input")
            }
            let output = root.appendingPathComponent("captions/\(source.id).json")
            guard !FileManager.default.fileExists(atPath: output.path) else {
                throw ScribeError.message("Caption output already exists; use a fresh experiment directory")
            }
            try Disk.write(result, to: output)
        }
    }

    private func requireInstalledModels(language: String) async throws {
        var modules: [any SpeechModule] = []
        if language == "mixed" {
            guard let ru = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: "ru-RU")),
                  let en = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else {
                throw ScribeError.message("Required Speech languages unavailable")
            }
            modules = [DictationTranscriber(locale: ru, contentHints: [], transcriptionOptions: [.punctuation],
                                            reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: []),
                       SpeechTranscriber(locale: en, preset: .progressiveTranscription)]
        } else {
            let locale = Locale(identifier: language == "russian" ? "ru-RU" : "en-US")
            if SpeechTranscriber.isAvailable, let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
                modules = [SpeechTranscriber(locale: supported, preset: .progressiveTranscription)]
            } else if let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
                modules = [DictationTranscriber(locale: supported, contentHints: [], transcriptionOptions: [.punctuation],
                                                reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: [])]
            }
        }
        guard !modules.isEmpty, await AssetInventory.status(forModules: modules) == .installed else {
            throw ScribeError.message("Install the selected language through live captions before running this probe")
        }
    }

    private func replay(source: Source, audio: URL, speed: Double) async throws -> Output {
        let file = try AVAudioFile(forReading: audio, commonFormat: .pcmFormatInt16, interleaved: false)
        guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1,
              abs(Double(file.length) / 16 - Double(source.durationMs)) <= 1 else {
            throw ScribeError.message("Probe requires complete mono 16 kHz audio with matching duration")
        }
        let (input, output) = AsyncStream.makeStream(of: LiveCaptionPCM.self, bufferingPolicy: .bufferingNewest(192))
        let (ready, signal) = AsyncStream.makeStream(of: Void.self)
        let collector = Collector()
        let start = ContinuousClock.now
        let producer = Task { () throws -> (Int64, Int, Double) in
            defer { output.finish() }
            for await _ in ready { break }
            try Task.checkCancellation()
            let feedingStart = ContinuousClock.now
            var frames: Int64 = 0, dropped = 0
            while frames < file.length {
                try Task.checkCancellation()
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 320) else {
                    throw ScribeError.message("Cannot allocate probe audio buffer")
                }
                try file.read(into: buffer)
                guard buffer.frameLength > 0 else { throw ScribeError.message("Unexpected end of probe audio") }
                frames += Int64(buffer.frameLength)
                if case .dropped = output.yield(.init(buffer: buffer)) { dropped += 1 }
                try await Task.sleep(until: feedingStart + .seconds(Double(frames) / 16_000 / speed), clock: .continuous)
            }
            return (frames, dropped, Self.seconds(start.duration(to: feedingStart)))
        }
        let onReady: @Sendable () async -> Void = {
            signal.yield(())
            signal.finish()
        }
        do {
            if source.language == "mixed" {
                try await LiveCaptionRecognition.recognizeMixed(input, onReady, { await collector.receive($0) })
            } else {
                try await LiveCaptionRecognition.recognize(Locale(identifier: source.language == "russian" ? "ru-RU" : "en-US"),
                                                           input, onReady, { await collector.receive($0) })
            }
            let (frames, dropped, readyAfter) = try await producer.value
            guard frames == file.length else { throw ScribeError.message("Incomplete replay") }
            let (phrases, unfinished) = await collector.snapshot()
            return Output(source: source, speed: speed, consumedFrames: frames, droppedBuffers: dropped,
                          elapsedSeconds: Self.seconds(start.duration(to: .now)), readyAfterSeconds: readyAfter,
                          unfinishedPhrases: unfinished, segments: phrases)
        } catch {
            producer.cancel()
            signal.finish()
            _ = try? await producer.value
            throw error
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
