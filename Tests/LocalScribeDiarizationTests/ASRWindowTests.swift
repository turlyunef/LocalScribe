import XCTest
import LocalScribeCore
@testable import LocalScribeWorker

final class ASRWindowTests: XCTestCase {
    private func samples(seconds: Int, pauses: [Range<Int>]) -> [Float] {
        var samples = [Float](repeating: 0.1, count: seconds * 1000)
        for pause in pauses { samples.replaceSubrange(pause, with: repeatElement(0, count: pause.count)) }
        return samples
    }

    func testChoosesFirstPauseInsteadOfCombiningLaterUtterances() {
        let audio = samples(seconds: 28, pauses: [4000..<5000, 16000..<17000, 25000..<26000])
        XCTAssertEqual(WhisperASRWindowing.nextASRWindowLength(audio, rate: 1000), 4280)
    }

    func testFrequentPausesKeepContinuousCoverageIncludingSilentTail() {
        let audio = samples(seconds: 60, pauses: stride(from: 4000, to: 60000, by: 5000).map { $0..<($0 + 1000) })
        var offset = 0, lengths: [Int] = []
        while offset < audio.count {
            let count = WhisperASRWindowing.nextASRWindowLength(Array(audio[offset..<min(offset + 28000, audio.count)]), rate: 1000)
            XCTAssertGreaterThan(count, 0); XCTAssertLessThanOrEqual(count, 28000)
            lengths.append(count); offset += count
        }
        XCTAssertEqual(lengths.first, 4280)
        XCTAssertGreaterThan(lengths.count, 3)
        XCTAssertEqual(lengths.reduce(0, +), audio.count)
        XCTAssertEqual(lengths.last, 720)
    }

    func testContinuousSpeechKeepsFullWindow() {
        XCTAssertEqual(WhisperASRWindowing.nextASRWindowLength(samples(seconds: 28, pauses: []), rate: 1000), 28000)
    }

    func testQuietInputUsesPauseBoundariesWithoutDiscardingSamples() {
        XCTAssertEqual(WhisperASRWindowing.nextASRWindowLength(samples(seconds: 28, pauses: [16000..<17000, 26000..<28000]), rate: 1000), 16280)
        for amplitude: Float in [0, 0.0005] {
            var remaining = 28000, covered = 0
            while remaining > 0 {
                let count = WhisperASRWindowing.nextASRWindowLength([Float](repeating: amplitude, count: remaining), rate: 1000)
                XCTAssertGreaterThan(count, 0)
                covered += count; remaining -= count
            }
            XCTAssertEqual(covered, 28000)
        }
    }

    func testShortTailsAndSubthresholdPausesRemainWhole() {
        XCTAssertEqual(WhisperASRWindowing.nextASRWindowLength([], rate: 1000), 0)
        XCTAssertEqual(WhisperASRWindowing.nextASRWindowLength([Float](repeating: 0.1, count: 125), rate: 1000), 125)
        XCTAssertEqual(WhisperASRWindowing.nextASRWindowLength(samples(seconds: 28, pauses: [25000..<25580]), rate: 1000), 28000)
        XCTAssertEqual(WhisperASRWindowing.nextASRWindowLength(samples(seconds: 11, pauses: [5000..<6000]), rate: 1000), 5280)
    }

    func testExperimentalLatePausePreservesShortUtterancesInsideWindow() {
        let audio = samples(seconds: 28, pauses: [4000..<5000, 16000..<17000, 25000..<26000])
        XCTAssertEqual(WhisperASRWindowing.nextASRWindowLength(audio, rate: 1000, policy: .firstPause), 4280)
        XCTAssertEqual(WhisperASRWindowing.nextASRWindowLength(audio, rate: 1000, policy: .latePause), 25500)
        XCTAssertEqual(WhisperASRWindowing.nextASRWindowLength(samples(seconds: 28, pauses: [26000..<28000]), rate: 1000, policy: .latePause), 28000)
        XCTAssertEqual(WhisperASRWindowing.nextASRWindowLength(samples(seconds: 60, pauses: []), rate: 1000, policy: .latePause), 28000)
    }

    func testBothPoliciesCoverQuietAudioAndShortTailsWithoutDroppingSamples() {
        for policy in WhisperWindowPolicy.allCases {
            for amplitude: Float in [0, 0.0005, 0.1] {
                let audio = [Float](repeating: amplitude, count: 60125)
                var offset = 0
                while offset < audio.count {
                    let input = Array(audio[offset..<min(offset + 28000, audio.count)])
                    let count = WhisperASRWindowing.nextASRWindowLength(input, rate: 1000, policy: policy)
                    XCTAssertGreaterThan(count, 0); XCTAssertLessThanOrEqual(count, 28000)
                    offset += count
                }
                XCTAssertEqual(offset, audio.count)
            }
        }
    }

    func testInteriorRecoveryDetectsOnlySustainedUncoveredAudio() {
        let segments = [Segment(id: "first", startMs: 0, endMs: 3000, text: "first", language: "en"),
                        Segment(id: "last", startMs: 7000, endMs: 8000, text: "last", language: "en")]
        let voiced = samples(seconds: 10, pauses: [])
        XCTAssertEqual(WhisperASRWindowing.missingASRInteriorRanges(segments: segments, samples: voiced,
            readStartMs: 0, coreStartMs: 0, coreEndMs: 10000, rate: 1000), [3000..<7000, 8000..<10000])
        let quiet = samples(seconds: 10, pauses: [3000..<7000, 8000..<10000])
        XCTAssertTrue(WhisperASRWindowing.missingASRInteriorRanges(segments: segments, samples: quiet,
            readStartMs: 0, coreStartMs: 0, coreEndMs: 10000, rate: 1000).isEmpty)
        XCTAssertTrue(WhisperASRWindowing.missingASRInteriorRanges(segments: [], samples: voiced,
            readStartMs: 0, coreStartMs: 0, coreEndMs: 10000, rate: 1000).isEmpty)
    }

    func testPauseSplittingDoesNotShiftTimeline() {
        let rate = 1000
        let samples = [Float](repeating: 0.1,count: 5000) + [Float](repeating:0,count:1000) + [Float](repeating:0.1,count:5000)
        let length = WhisperASRWindowing.nextASRWindowLength(samples,rate:rate)
        XCTAssertGreaterThan(length,5000); XCTAssertLessThan(length,6000)
        XCTAssertEqual(WhisperASRWindowing.nextASRWindowLength([Float](repeating:0.1,count:30000),rate:rate),30000)
    }
    func testEmptyOrLateASRRetriesAudiblePrefix() {
        let samples = [Float](repeating: 0.01, count: 16000 * 15)
        XCTAssertEqual(WhisperASRWindowing.missingASRPrefixEnd(segments: [], samples: samples, readStartMs: 0, coreStartMs: 0, coreEndMs: 13_840), 13_840)
        let late = Segment(id: "late", startMs: 13_380, endMs: 14_500, text: "Речь", language: "ru")
        XCTAssertEqual(WhisperASRWindowing.missingASRPrefixEnd(segments: [late], samples: samples, readStartMs: 0, coreStartMs: 0, coreEndMs: 15_000), 13_380)
        let recovered = Segment(id: "early", startMs: 940, endMs: 3240, text: "Начало", language: "ru")
        XCTAssertNil(WhisperASRWindowing.missingASRPrefixEnd(segments: [recovered, late], samples: samples, readStartMs: 0, coreStartMs: 0, coreEndMs: 15_000))
    }
    func testLeadingSilenceAndBriefNoiseDoNotRequestASRRetry() {
        var samples = [Float](repeating: 0, count: 16000 * 15)
        let speech = Segment(id: "speech", startMs: 13_000, endMs: 14_500, text: "Речь после паузы", language: "ru")
        for i in 13 * 16000..<samples.count { samples[i] = 0.1 }
        XCTAssertNil(WhisperASRWindowing.missingASRPrefixEnd(segments: [speech], samples: samples, readStartMs: 0, coreStartMs: 0, coreEndMs: 15_000))
        for i in 16000..<17600 { samples[i] = 0.1 }
        XCTAssertNil(WhisperASRWindowing.missingASRPrefixEnd(segments: [speech], samples: samples, readStartMs: 0, coreStartMs: 0, coreEndMs: 15_000))
        XCTAssertNil(WhisperASRWindowing.missingASRPrefixEnd(segments: [], samples: [Float](repeating: 0.00001, count: 16000 * 15), readStartMs: 0, coreStartMs: 0, coreEndMs: 15_000))
    }
    func testASRPrefixRetryUsesOriginalTimelineAndExcludesContext() {
        var samples = [Float](repeating: 0, count: 16000 * 5)
        // Sound in the preceding context belongs to the previous window.
        for i in 0..<16000 { samples[i] = 0.1 }
        XCTAssertNil(WhisperASRWindowing.missingASRPrefixEnd(segments: [], samples: samples, readStartMs: 29_000, coreStartMs: 30_000, coreEndMs: 33_000))
        for i in 16000..<32000 { samples[i] = 0.01 }
        XCTAssertEqual(WhisperASRWindowing.missingASRPrefixEnd(segments: [], samples: samples, readStartMs: 29_000, coreStartMs: 30_000, coreEndMs: 33_000), 33_000)
    }
}
