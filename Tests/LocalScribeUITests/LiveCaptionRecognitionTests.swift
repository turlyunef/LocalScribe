import AVFoundation
import CoreMedia
import Foundation
import Speech
import XCTest
@testable import LocalScribe

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

    private actor Results {
        var finalCount = 0

        func receive(_ update: LiveCaptionUpdate) {
            if !update.text.isEmpty, update.range.end <= update.finalizedThrough { finalCount += 1 }
        }
    }
}
