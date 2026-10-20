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
}
