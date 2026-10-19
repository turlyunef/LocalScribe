import XCTest
import LocalScribeCore

final class ASRWindowTests: XCTestCase {
    private func samples(seconds: Int, pauses: [Range<Int>]) -> [Float] {
        var samples = [Float](repeating: 0.1, count: seconds * 1000)
        for pause in pauses { samples.replaceSubrange(pause, with: repeatElement(0, count: pause.count)) }
        return samples
    }

    func testChoosesLastCompleteLatePauseAndRetainsEarlierSpeech() {
        let audio = samples(seconds: 28, pauses: [4000..<5000, 16000..<17000, 25000..<26000])
        XCTAssertEqual(Analysis.nextASRWindowLength(audio, rate: 1000), 25500)
    }

    func testFrequentPausesUseThreeWindowsWithoutTimelineGaps() {
        let audio = samples(seconds: 60, pauses: stride(from: 4000, to: 60000, by: 5000).map { $0..<($0 + 1000) })
        var offset = 0, lengths: [Int] = []
        while offset < audio.count {
            let count = Analysis.nextASRWindowLength(Array(audio[offset..<min(offset + 28000, audio.count)]), rate: 1000)
            XCTAssertGreaterThan(count, 0); XCTAssertLessThanOrEqual(count, 28000)
            lengths.append(count); offset += count
        }
        XCTAssertEqual(lengths.count, 3)
        XCTAssertEqual(lengths.reduce(0, +), audio.count)
    }

    func testEarlyPauseDoesNotShortenFullWindow() {
        XCTAssertEqual(Analysis.nextASRWindowLength(samples(seconds: 28, pauses: [4000..<5000]), rate: 1000), 28000)
    }

    func testTrailingSilenceAndQuietSpeechAreNotDiscarded() {
        XCTAssertEqual(Analysis.nextASRWindowLength(samples(seconds: 28, pauses: [16000..<17000, 26000..<28000]), rate: 1000), 28000)
        XCTAssertEqual(Analysis.nextASRWindowLength([Float](repeating: 0.0005, count: 28000), rate: 1000), 28000)
        XCTAssertEqual(Analysis.nextASRWindowLength([Float](repeating: 0, count: 28000), rate: 1000), 28000)
    }

    func testShortTailsAndSubthresholdPausesRemainWhole() {
        XCTAssertEqual(Analysis.nextASRWindowLength([], rate: 1000), 0)
        XCTAssertEqual(Analysis.nextASRWindowLength([Float](repeating: 0.1, count: 125), rate: 1000), 125)
        XCTAssertEqual(Analysis.nextASRWindowLength(samples(seconds: 28, pauses: [25000..<25580]), rate: 1000), 28000)
        XCTAssertEqual(Analysis.nextASRWindowLength(samples(seconds: 11, pauses: [5000..<6000]), rate: 1000), 11000)
    }

    func testInteriorRecoveryRequiresSustainedUncoveredSoundAndKeepsAbsoluteTimes() {
        let segments = [Segment(id: "a", startMs: 30100, endMs: 33000, text: "RU", language: "ru"),
                        Segment(id: "b", startMs: 37000, endMs: 40000, text: "RU", language: "ru")]
        var audio = [Float](repeating: 0, count: 11000)
        audio.replaceSubrange(5000..<7000, with: repeatElement(0.1, count: 2000))
        XCTAssertEqual(Analysis.missingASRInteriorRanges(segments: segments, samples: audio, readStartMs: 29000,
            coreStartMs: 30000, coreEndMs: 40000, rate: 1000), [33000..<37000])
        audio = [Float](repeating: 0, count: 11000)
        audio.replaceSubrange(5000..<5400, with: repeatElement(0.1, count: 400))
        XCTAssertTrue(Analysis.missingASRInteriorRanges(segments: segments, samples: audio, readStartMs: 29000,
            coreStartMs: 30000, coreEndMs: 40000, rate: 1000).isEmpty)
        XCTAssertTrue(Analysis.missingASRInteriorRanges(segments: [], samples: audio, readStartMs: 29000,
            coreStartMs: 30000, coreEndMs: 40000, rate: 1000).isEmpty, "Prefix recovery owns an entirely missing result")
    }
}
