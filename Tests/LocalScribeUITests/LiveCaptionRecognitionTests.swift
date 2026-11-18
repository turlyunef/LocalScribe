import AVFoundation
import CoreMedia
import Foundation
import Speech
import Synchronization
import XCTest
@testable import LocalScribe
@testable import LocalScribeCore

/// A minimal valid analyzer input for channel-level tests (self-contained so
/// @Sendable closures can use it without capturing the test case). The
/// capture writer produces mono 16 kHz int16 PCM.
private func liveCaptionTestInput() throws -> AnalyzerInput {
    guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160),
          let channel = buffer.int16ChannelData?[0] else {
        throw NSError(domain: "LiveCaptionRecognitionTests", code: 1)
    }
    buffer.frameLength = 160
    channel.update(from: Array(repeating: Int16(0), count: 160), count: 160)
    return AnalyzerInput(buffer: buffer)
}

@MainActor final class LiveCaptionRecognitionTests: XCTestCase {
    private var noRecognition: NSError {
        NSError(domain: SFSpeechErrorDomain, code: SFSpeechError.Code.internalServiceError.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "RecogFailed"])
    }

    func testRevokedDictationHypothesisCanFinishEmptyOnlyAtEndOfInput() async throws {
        let finalization = DictationCaptionFinalization()
        let range = CMTimeRange(start: .zero, duration: CMTime(value: 3, timescale: 1))
        finalization.observe(range: range, hasText: true, isFinal: false)
        finalization.observe(range: range, hasText: false, isFinal: false)
        XCTAssertFalse(finalization.allowsEmptyResult(noRecognition))
        let failure = noRecognition
        try await finalization.finish { throw failure }
        XCTAssertTrue(finalization.allowsEmptyResult(noRecognition))
    }

    func testPendingDictationHypothesisPreservesFinalizationFailure() async {
        let finalization = DictationCaptionFinalization()
        let range = CMTimeRange(start: .zero, duration: CMTime(value: 3, timescale: 1))
        finalization.observe(range: range, hasText: true, isFinal: false)
        let failure = noRecognition
        do {
            try await finalization.finish { throw failure }
            XCTFail("A pending hypothesis must retain its failure")
        } catch {
            XCTAssertEqual((error as NSError).code, noRecognition.code)
        }
        XCTAssertFalse(finalization.allowsEmptyResult(noRecognition))
    }

    func testFinalizingAnEarlierPhraseDoesNotClearALaterDictationHypothesis() async {
        let finalization = DictationCaptionFinalization()
        finalization.observe(range: CMTimeRange(start: CMTime(value: 3, timescale: 1),
                                               duration: CMTime(value: 3, timescale: 1)),
                             hasText: true, isFinal: false)
        finalization.observe(range: CMTimeRange(start: .zero, duration: CMTime(value: 2, timescale: 1)),
                             hasText: true, isFinal: true)
        let failure = noRecognition
        do {
            try await finalization.finish { throw failure }
            XCTFail("An earlier final result must not clear a later draft")
        } catch {
            XCTAssertFalse(finalization.allowsEmptyResult(error))
        }
    }

    func testEmptyDictationStillPropagatesOtherErrorsAndCancellation() async {
        let errors: [Error] = [
            NSError(domain: SFSpeechErrorDomain, code: SFSpeechError.Code.internalServiceError.rawValue),
            NSError(domain: NSCocoaErrorDomain, code: 1, userInfo: [NSLocalizedDescriptionKey: "RecogFailed"]),
            CancellationError()
        ]
        for failure in errors {
            let finalization = DictationCaptionFinalization()
            do {
                try await finalization.finish { throw failure }
                XCTFail("Only an empty dictation result at EOF may be accepted")
            } catch {
                XCTAssertFalse(finalization.allowsEmptyResult(error))
            }
        }
    }

    /// Opt-in local regression audio. The file and its transcript stay outside the repository.
    func testMixedRecognitionHandlesTheRevokedDictationFixtureWithoutRestart() async throws {
        guard let path = ProcessInfo.processInfo.environment["LOCALSCRIBE_LIVE_CAPTION_FIXTURE"] else {
            throw XCTSkip("Set LOCALSCRIBE_LIVE_CAPTION_FIXTURE to a local mono 16 kHz regression clip")
        }
        let (input, output) = AsyncStream.makeStream(of: LiveCaptionPCM.self, bufferingPolicy: .bufferingNewest(192))
        let (ready, signal) = AsyncStream.makeStream(of: Void.self)
        let results = Results()
        let producer = Task {
            defer { output.finish() }
            for await _ in ready { break }
            try Task.checkCancellation()
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: path),
                                       commonFormat: .pcmFormatInt16, interleaved: false)
            XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
            XCTAssertEqual(file.processingFormat.channelCount, 1)
            let start = ContinuousClock.now
            var frames: Int64 = 0
            var dropped = 0
            while frames < file.length {
                try Task.checkCancellation()
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 320))
                try file.read(into: buffer)
                frames += Int64(buffer.frameLength)
                if case .dropped = output.yield(.init(buffer: buffer)) { dropped += 1 }
                try await Task.sleep(until: start + .seconds(Double(frames) / 16_000 / 4), clock: .continuous)
            }
            return dropped
        }
        do {
            try await LiveCaptionRecognition.recognizeMixed(input, {
                signal.yield(())
                signal.finish()
            }, { await results.receive($0) })
        } catch {
            producer.cancel()
            _ = try? await producer.value
            throw error
        }
        let dropped = try await producer.value
        let finalCount = await results.finalCount
        XCTAssertEqual(dropped, 0)
        XCTAssertGreaterThan(finalCount, 0)
    }

    // MARK: - Rendezvous analyzer channels

    func testChannelSendParksUntilPulledAndFinishEndsTheSequence() async throws {
        let channel = AnalyzerInputChannel()
        let value = try liveCaptionTestInput()
        let returned = Mutex(false)
        let sender = Task { try await channel.send(value); returned.withLock { $0 = true } }
        // The send must not return before a consumer pulled the element.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(returned.withLock { $0 })
        let received = await channel.pull()
        XCTAssertNotNil(received)
        try await sender.value
        XCTAssertTrue(returned.withLock { $0 })
        channel.finish()
        let ended = await channel.pull()
        XCTAssertNil(ended)
        for try await _ in channel.sequence { XCTFail("finished channel must not deliver") }
    }

    func testChannelTerminateFailsParkedSendAndEndsParkedPull() async throws {
        let channel = AnalyzerInputChannel()
        let value = try liveCaptionTestInput()
        let sender = Task { try await channel.send(value) }
        try await Task.sleep(for: .milliseconds(50))
        channel.terminate()
        do {
            try await sender.value
            XCTFail("A parked send must fail when the session terminates")
        } catch { XCTAssertTrue(error is CancellationError) }
        let ended = await channel.pull()
        XCTAssertNil(ended)
    }

    /// The mixed feeder hands each buffer to both analyzers strictly before
    /// pulling the next one from the capture stream: with a slow second
    /// consumer, no consumer may see buffer N+1 before both consumed N.
    func testMixedFeederDoesNotAdvanceUntilBothChannelsConsumed() async throws {
        let (stream, continuation) = AsyncStream.makeStream(of: LiveCaptionPCM.self, bufferingPolicy: .bufferingNewest(16))
        let channels = [AnalyzerInputChannel(), AnalyzerInputChannel()]
        let log = Mutex<[(consumer: Int, index: Int)]>([])
        let tasks = channels.enumerated().map { offset, channel -> Task<Void, Error> in
            Task {
                var count = 0
                for try await _ in channel.sequence {
                    log.withLock { $0.append((offset, count)) }
                    count += 1
                    // The second analyzer is deliberately slower.
                    if offset == 1 { try await Task.sleep(for: .milliseconds(20)) }
                }
            }
        }
        let feeder = Task {
            try await LiveCaptionRecognition.feedMixed(stream, to: channels,
                                                       convert: { _ in try liveCaptionTestInput() })
        }
        let pcm = try XCTUnwrap(liveCaptionTestInput().buffer)
        for _ in 0..<4 { continuation.yield(LiveCaptionPCM(buffer: pcm)) }
        continuation.finish()
        // The feeder drains the capture stream, then the finished channels
        // release the consumers.
        try await feeder.value
        channels.forEach { $0.finish() }
        for task in tasks { try await task.value }
        let ordered = log.withLock { $0 }
        XCTAssertEqual(ordered.count, 8)
        var completed = Set<Int>()
        for event in ordered {
            // Every earlier buffer must already be consumed by both channels.
            for index in 0..<event.index {
                XCTAssertTrue(completed.contains(index * 2), "buffer \(index) not fully consumed before \(event.consumer):\(event.index)")
                XCTAssertTrue(completed.contains(index * 2 + 1), "buffer \(index) not fully consumed before \(event.consumer):\(event.index)")
            }
            completed.insert(event.index * 2 + event.consumer)
        }
        XCTAssertEqual(completed, Set(0..<8))
    }

    /// A conversion failure propagates out of the feeder without deadlock.
    func testMixedFeederPropagatesConversionFailure() async throws {
        let (stream, continuation) = AsyncStream.makeStream(of: LiveCaptionPCM.self, bufferingPolicy: .bufferingNewest(16))
        let channels = [AnalyzerInputChannel(), AnalyzerInputChannel()]
        // The feeder hands every buffer to both channels, so both need a
        // consumer exactly like the two analyzer sessions do.
        let consumers = channels.map { channel in Task { [channel] in for try await _ in channel.sequence {} } }
        let failure = ScribeError.message("тестовая ошибка конвертации")
        let produced = Mutex(0)
        let feeder = Task {
            try await LiveCaptionRecognition.feedMixed(stream, to: channels, convert: { _ in
                if produced.withLock({ $0 += 1; return $0 }) > 1 { throw failure }
                return try liveCaptionTestInput()
            })
        }
        let pcm = try XCTUnwrap(liveCaptionTestInput().buffer)
        continuation.yield(LiveCaptionPCM(buffer: pcm))
        continuation.yield(LiveCaptionPCM(buffer: pcm))
        do {
            try await feeder.value
            XCTFail("A conversion failure must propagate")
        } catch let error as ScribeError { XCTAssertEqual(error.localizedDescription, failure.localizedDescription) }
        channels.forEach { $0.finish() }
        for consumer in consumers { _ = try await consumer.value }
    }

    private actor Results {
        var finalCount = 0

        func receive(_ update: LiveCaptionUpdate) {
            if !update.text.isEmpty, update.range.end <= update.finalizedThrough { finalCount += 1 }
        }
    }
}
