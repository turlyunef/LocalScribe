import XCTest
import CoreML
@testable import LocalScribeSpeakerKit

final class ModelGeometryTests: XCTestCase {
    func testSeekClipsAreExplicitlyUnsupportedBeforeTimelineConversion() throws {
        try PyannoteDiarizationOptions().validateSupportedOptions()
        for timestamps: [Float] in [[0, 1, 2, 3], [1, 2], [0], [.nan], [.infinity], [-1, 2]] {
            XCTAssertThrowsError(try PyannoteDiarizationOptions(clipTimestamps: timestamps).validateSupportedOptions()) {
                XCTAssertTrue($0.localizedDescription.contains("clipTimestamps"))
            }
        }
    }

    func testSegmenterRejectsZeroSingleWindowAndInconsistentDescriptions() throws {
        try SpeakerSegmenterModel.validateGeometry(waveform: [480_000], sliding: [26, 1, 80_000], speakerIDs: [26, 100, 3], sampleRate: 16_000)
        for sliding in [[26, 1, 0], [1, 1, 80_000], [0, 1, 80_000], [26, 1, Int.max], [], [26, 0, 80_000]] {
            XCTAssertThrowsError(try SpeakerSegmenterModel.validateGeometry(waveform: [480_000], sliding: sliding, speakerIDs: [26, 100, 3], sampleRate: 16_000))
        }
        for waveform in [[], [0], [Int.max], [480_000, 1]] {
            XCTAssertThrowsError(try SpeakerSegmenterModel.validateGeometry(waveform: waveform, sliding: [26, 1, 80_000], speakerIDs: [26, 100, 3], sampleRate: 16_000))
        }
        XCTAssertThrowsError(try SpeakerSegmenterModel.validateGeometry(waveform: [480_000], sliding: [26, 1, 80_000], speakerIDs: [25, 100, 3], sampleRate: 16_000))
    }

    func testEmbedderRejectsSingleWindowAndNonfiniteLengthsBeforeIndexConstruction() throws {
        let activity = try MLMultiArray(shape: [26, 1], dataType: .float32)
        let ids = try MLMultiArray(shape: [26, 100, 1], dataType: .float32)
        let overlap = try MLMultiArray(shape: [26, 100], dataType: .float32)
        for windows in [0, 1, 25, Int.max] {
            XCTAssertThrowsError(try SpeakerEmbedderContext(speakerActivity: activity, speakerIds: ids, overlappedSpeakerActivity: overlap,
                windowsCount: windows, chunkStride: 26, secondsPerWindow: 5, waveformLength: 30))
        }
        for length: Float in [0, -1, 30, .infinity, .nan, .leastNonzeroMagnitude] {
            XCTAssertThrowsError(try SpeakerEmbedderContext(speakerActivity: activity, speakerIds: ids, overlappedSpeakerActivity: overlap,
                windowsCount: 26, chunkStride: 26, secondsPerWindow: length, waveformLength: 30))
        }
        let valid = try SpeakerEmbedderContext(speakerActivity: activity, speakerIds: ids, overlappedSpeakerActivity: overlap,
            windowsCount: 26, chunkStride: 26, secondsPerWindow: 5, waveformLength: 30)
        XCTAssertEqual(valid.chunkIndices.count, 26)
        for (index, frames) in valid.chunkIndices.enumerated() {
            XCTAssertEqual(frames, Array((index * 20)..<(index * 20 + 100)))
        }
    }

    func testPostprocessingRejectsZeroNonfiniteAndOverflowingFrameCounts() throws {
        XCTAssertEqual(try PyannoteDiarizerActor.frameCount(framesPerWindow: 100, windowLength: 5, maxChunks: 3), 1800)
        for length: Float in [0, -1, .infinity, .nan, .leastNonzeroMagnitude] {
            XCTAssertThrowsError(try PyannoteDiarizerActor.frameCount(framesPerWindow: 100, windowLength: length, maxChunks: 3))
        }
        XCTAssertThrowsError(try PyannoteDiarizerActor.frameCount(framesPerWindow: Int.max, windowLength: 5, maxChunks: 3))
        XCTAssertThrowsError(try PyannoteDiarizerActor.frameCount(framesPerWindow: 100, windowLength: 5, maxChunks: Int.max))
    }
}
