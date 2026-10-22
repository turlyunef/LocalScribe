import XCTest
import LocalScribeCore

final class ASRWindowTests: XCTestCase {
    private func samples(seconds: Int, pauses: [Range<Int>]) -> [Float] {
        var samples = [Float](repeating: 0.1, count: seconds * 1000)
        for pause in pauses { samples.replaceSubrange(pause, with: repeatElement(0, count: pause.count)) }
        return samples
    }

    func testChoosesFirstPauseInsteadOfCombiningLaterUtterances() {
        let audio = samples(seconds: 28, pauses: [4000..<5000, 16000..<17000, 25000..<26000])
        XCTAssertEqual(Analysis.nextASRWindowLength(audio, rate: 1000), 4280)
    }

    func testFrequentPausesKeepContinuousCoverageIncludingSilentTail() {
        let audio = samples(seconds: 60, pauses: stride(from: 4000, to: 60000, by: 5000).map { $0..<($0 + 1000) })
        var offset = 0, lengths: [Int] = []
        while offset < audio.count {
            let count = Analysis.nextASRWindowLength(Array(audio[offset..<min(offset + 28000, audio.count)]), rate: 1000)
            XCTAssertGreaterThan(count, 0); XCTAssertLessThanOrEqual(count, 28000)
            lengths.append(count); offset += count
        }
        XCTAssertEqual(lengths.first, 4280)
        XCTAssertGreaterThan(lengths.count, 3)
        XCTAssertEqual(lengths.reduce(0, +), audio.count)
        XCTAssertEqual(lengths.last, 720)
    }

    func testContinuousSpeechKeepsFullWindow() {
        XCTAssertEqual(Analysis.nextASRWindowLength(samples(seconds: 28, pauses: []), rate: 1000), 28000)
    }

    func testQuietInputUsesPauseBoundariesWithoutDiscardingSamples() {
        XCTAssertEqual(Analysis.nextASRWindowLength(samples(seconds: 28, pauses: [16000..<17000, 26000..<28000]), rate: 1000), 16280)
        for amplitude: Float in [0, 0.0005] {
            var remaining = 28000, covered = 0
            while remaining > 0 {
                let count = Analysis.nextASRWindowLength([Float](repeating: amplitude, count: remaining), rate: 1000)
                XCTAssertGreaterThan(count, 0)
                covered += count; remaining -= count
            }
            XCTAssertEqual(covered, 28000)
        }
    }

    func testShortTailsAndSubthresholdPausesRemainWhole() {
        XCTAssertEqual(Analysis.nextASRWindowLength([], rate: 1000), 0)
        XCTAssertEqual(Analysis.nextASRWindowLength([Float](repeating: 0.1, count: 125), rate: 1000), 125)
        XCTAssertEqual(Analysis.nextASRWindowLength(samples(seconds: 28, pauses: [25000..<25580]), rate: 1000), 28000)
        XCTAssertEqual(Analysis.nextASRWindowLength(samples(seconds: 11, pauses: [5000..<6000]), rate: 1000), 5280)
    }

    func testExperimentalLatePausePreservesShortUtterancesInsideWindow() {
        let audio = samples(seconds: 28, pauses: [4000..<5000, 16000..<17000, 25000..<26000])
        XCTAssertEqual(Analysis.nextASRWindowLength(audio, rate: 1000, policy: .firstPause), 4280)
        XCTAssertEqual(Analysis.nextASRWindowLength(audio, rate: 1000, policy: .latePause), 25500)
        XCTAssertEqual(Analysis.nextASRWindowLength(samples(seconds: 28, pauses: [26000..<28000]), rate: 1000, policy: .latePause), 28000)
        XCTAssertEqual(Analysis.nextASRWindowLength(samples(seconds: 60, pauses: []), rate: 1000, policy: .latePause), 28000)
    }

    func testBothPoliciesCoverQuietAudioAndShortTailsWithoutDroppingSamples() {
        for policy in ASRWindowPolicy.allCases {
            for amplitude: Float in [0, 0.0005, 0.1] {
                let audio = [Float](repeating: amplitude, count: 60125)
                var offset = 0
                while offset < audio.count {
                    let input = Array(audio[offset..<min(offset + 28000, audio.count)])
                    let count = Analysis.nextASRWindowLength(input, rate: 1000, policy: policy)
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
        XCTAssertEqual(Analysis.missingASRInteriorRanges(segments: segments, samples: voiced,
            readStartMs: 0, coreStartMs: 0, coreEndMs: 10000, rate: 1000), [3000..<7000, 8000..<10000])
        let quiet = samples(seconds: 10, pauses: [3000..<7000, 8000..<10000])
        XCTAssertTrue(Analysis.missingASRInteriorRanges(segments: segments, samples: quiet,
            readStartMs: 0, coreStartMs: 0, coreEndMs: 10000, rate: 1000).isEmpty)
        XCTAssertTrue(Analysis.missingASRInteriorRanges(segments: [], samples: voiced,
            readStartMs: 0, coreStartMs: 0, coreEndMs: 10000, rate: 1000).isEmpty)
    }
}
