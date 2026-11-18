import AVFoundation
import CoreMedia
import XCTest
@testable import LocalScribe

/// Energy VAD of the mixed-language live captions. Pauses are detected on the
/// same mono 16 kHz PCM16 stream the capture writer records: sample energy is
/// summed into 320-frame blocks and twenty quiet blocks after speech emit a
/// CMTime at the block's last consumed sample.
@MainActor final class LiveCaptionPausesTests: XCTestCase {
    private var format: AVAudioFormat!

    override func setUpWithError() throws {
        format = try XCTUnwrap(CapturePCM16Sink.format, "Mono 16 kHz PCM16 capture format must exist")
        XCTAssertEqual(format.commonFormat, .pcmFormatInt16)
        XCTAssertEqual(format.sampleRate, 16_000)
        XCTAssertEqual(format.channelCount, 1)
    }

    private func buffer(_ values: [Int16]) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(values.count)))
        buffer.frameLength = AVAudioFrameCount(values.count)
        for index in values.indices { buffer.int16ChannelData![0][index] = values[index] }
        return buffer
    }

    private func blocks(_ count: Int, amplitude: Int16) throws -> [AVAudioPCMBuffer] {
        try (0..<count).map { _ in try buffer(Array(repeating: amplitude, count: 320)) }
    }

    private func feed(_ pauses: LiveCaptionPauses, _ buffers: [AVAudioPCMBuffer]) throws {
        for chunk in buffers { pauses.consume(chunk) }
    }

    /// The times stream buffers only its newest value, so the retained pauses
    /// are read deterministically after the stream has been finished.
    private func finishAndCollect(_ pauses: LiveCaptionPauses) async -> [CMTime] {
        pauses.finish()
        var times: [CMTime] = []
        for await time in pauses.times { times.append(time) }
        return times
    }

    /// A pause fires after `blocks` blocks of 320 frames, at the last consumed
    /// sample, on the capture timescale of 16 kHz.
    private func pauseTime(afterBlocks blocks: Int) -> CMTime {
        CMTime(value: CMTimeValue(blocks) * 320 - 1, timescale: CMTimeScale(MicrophoneCaptureWriter.sampleRate))
    }

    func testSilenceBeforeAnySpeechNeverEmitsAPause() async throws {
        let pauses = LiveCaptionPauses()
        try feed(pauses, blocks(25, amplitude: 0))
        let collected = await finishAndCollect(pauses)
        XCTAssertTrue(collected.isEmpty)
    }

    func testPauseIsEmittedOnlyAtTheTwentiethQuietBlockAfterSpeech() async throws {
        let almost = LiveCaptionPauses()
        try feed(almost, blocks(1, amplitude: 32767))
        try feed(almost, blocks(19, amplitude: 0))
        let almostTimes = await finishAndCollect(almost)
        XCTAssertTrue(almostTimes.isEmpty, "Nineteen quiet blocks must not finalize yet")

        let pauses = LiveCaptionPauses()
        try feed(pauses, blocks(1, amplitude: 32767))
        try feed(pauses, blocks(20, amplitude: 0))
        // One loud plus twenty quiet blocks: 21 blocks, time at the final sample.
        let collected = await finishAndCollect(pauses)
        XCTAssertEqual(collected, [pauseTime(afterBlocks: 21)])
    }

    func testBlocksJustBelowAndJustAboveQuietEnergyThreshold() async throws {
        // quietEnergy = 320 * (0.003 * 32768)^2 ≈ 3_092_376.5. A full block of
        // amplitude-98 samples sums to 3_073_280 (quiet), amplitude 99 to 3_136_320 (speech).
        let quiet = LiveCaptionPauses()
        try feed(quiet, blocks(26, amplitude: 98))
        let quietTimes = await finishAndCollect(quiet)
        XCTAssertTrue(quietTimes.isEmpty, "Amplitude 98 must stay below the quiet-energy threshold")

        let speech = LiveCaptionPauses()
        try feed(speech, blocks(1, amplitude: 99))
        try feed(speech, blocks(20, amplitude: 0))
        let speechTimes = await finishAndCollect(speech)
        XCTAssertEqual(speechTimes, [pauseTime(afterBlocks: 21)],
                       "Amplitude 99 must cross the quiet-energy threshold")
    }

    func testEnergyAccumulatesAcrossBuffersWithinABlock() async throws {
        // Half a block of amplitude 100 sums to 1_600_000 (quiet); only the full
        // 320-frame block reaches 3_200_000 ≥ quietEnergy. The forty loud halves
        // make twenty speech blocks, the forty silent halves — the twenty quiet
        // blocks that finalize at the fortieth block's last sample.
        let pauses = LiveCaptionPauses()
        try feed(pauses, (0..<40).map { _ in try buffer(Array(repeating: 100, count: 160)) })
        try feed(pauses, (0..<40).map { _ in try buffer(Array(repeating: 0, count: 160)) })
        let collected = await finishAndCollect(pauses)
        XCTAssertEqual(collected, [pauseTime(afterBlocks: 40)])
    }

    func testSpeechBetweenQuietBlocksResetsThePauseCounter() async throws {
        let pauses = LiveCaptionPauses()
        try feed(pauses, blocks(1, amplitude: 32767))
        try feed(pauses, blocks(10, amplitude: 0))
        try feed(pauses, blocks(1, amplitude: 32767))
        try feed(pauses, blocks(10, amplitude: 0))
        let collected = await finishAndCollect(pauses)
        XCTAssertTrue(collected.isEmpty,
                      "Ten quiet blocks after a speech block reset must not finalize")
    }

    func testPauseRearmsAfterSpeechResumesAndDoesNotRepeatInSilence() async throws {
        let pauses = LiveCaptionPauses()
        try feed(pauses, blocks(1, amplitude: 32767))
        try feed(pauses, blocks(20, amplitude: 0))  // first pause at sample 6719
        try feed(pauses, blocks(1, amplitude: 32767))
        try feed(pauses, blocks(20, amplitude: 0))  // re-armed pause at sample 13439
        try feed(pauses, blocks(5, amplitude: 0))   // continued silence must not repeat it
        // bufferingNewest(1) retains exactly the latest pause time.
        let collected = await finishAndCollect(pauses)
        XCTAssertEqual(collected, [pauseTime(afterBlocks: 42)])
    }

    func testPartialBlocksCarryFramesToTheNextBuffer() async throws {
        let pauses = LiveCaptionPauses()
        try feed(pauses, blocks(1, amplitude: 32767))
        try feed(pauses, [buffer(Array(repeating: 0, count: 319))])  // block stays open
        try feed(pauses, [buffer([0])])                               // closes the first quiet block
        try feed(pauses, blocks(19, amplitude: 0))
        let collected = await finishAndCollect(pauses)
        XCTAssertEqual(collected, [pauseTime(afterBlocks: 21)])
    }

    func testNonPCM16BuffersAreIgnoredWithoutAdvancingTheFrameCounter() async throws {
        let floatFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1))
        let noise = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: 320))
        noise.frameLength = 320
        for index in 0..<320 { noise.floatChannelData![0][index] = 0.9 }

        let pauses = LiveCaptionPauses()
        for _ in 0..<25 { pauses.consume(noise) }
        try feed(pauses, blocks(1, amplitude: 32767))
        try feed(pauses, blocks(20, amplitude: 0))
        // Had the float frames been counted, the pause would land 8000 samples later.
        let collected = await finishAndCollect(pauses)
        XCTAssertEqual(collected, [pauseTime(afterBlocks: 21)])
    }
}
