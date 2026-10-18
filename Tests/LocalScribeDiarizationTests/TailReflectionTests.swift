import XCTest
import AVFoundation
import CoreML
import LocalScribeCore
@testable import LocalScribeSpeakerKit

final class TailReflectionTests: XCTestCase {
    func testReflectionAlternatesWithoutChangingRealSamples() {
        let source: [Float] = [1, 2, 3]
        XCTAssertEqual(SpeakerSegmenterModel.reflectTail(source, toLength: 14),
                       [1, 2, 3, 3, 2, 1, 1, 2, 3, 3, 2, 1, 1, 2])
        XCTAssertEqual(source, [1, 2, 3])
        XCTAssertEqual(SpeakerSegmenterModel.reflectTail([0.25], toLength: 480_000),
                       [Float](repeating: 0.25, count: 480_000))
    }

    func testEmptySilenceAndFullChunks() {
        XCTAssertTrue(SpeakerSegmenterModel.reflectTail([], toLength: 480_000).isEmpty)
        XCTAssertEqual(SpeakerSegmenterModel.reflectTail([0, 0], toLength: 480_000),
                       [Float](repeating: 0, count: 480_000))
        let full = (0..<480_000).map { Float($0) / 480_000 }
        XCTAssertEqual(SpeakerSegmenterModel.reflectTail(full, toLength: full.count), full)
        // Trimming remains AudioProcessor's responsibility.
        XCTAssertEqual(SpeakerSegmenterModel.reflectTail(full, toLength: full.count - 1), full)
    }

    func testLengthsAroundThirtySecondsAndOverlappingStride() {
        // 30 s input and 5 s windows on a 1 s stride: 4 s redundancy,
        // 26 s between chunks. Include tiny tails on both boundaries.
        for count in [1, 15_999, 16_000, 415_999, 416_000, 416_001, 479_999, 480_000] {
            let source = (0..<count).map { Float($0 % 127) / 127 }
            let padded = SpeakerSegmenterModel.reflectTail(source, toLength: 480_000)
            XCTAssertEqual(padded.count, 480_000)
            XCTAssertEqual(Array(padded.prefix(count)), source)
            if count < 480_000 { XCTAssertEqual(padded[count], source.last) }
        }
    }

    func testReflectedContextDoesNotExtendEmbedderBounds() throws {
        let activity = try MLMultiArray(shape: [26, 1], dataType: .float32)
        let ids = try MLMultiArray(shape: [26, 100, 1], dataType: .float32)
        let overlap = try MLMultiArray(shape: [26, 100], dataType: .float32)
        let context = SpeakerEmbedderContext(speakerActivity: activity, speakerIds: ids,
                                            overlappedSpeakerActivity: overlap, windowsCount: 26,
                                            chunkStride: 26, secondsPerWindow: 5, waveformLength: 11.9)
        XCTAssertEqual(context.waveformLength, 11.9)
        XCTAssertEqual(context.chunkOffset(for: 1), 26)
        XCTAssertTrue(context.bounded(windowIdx: 7))
        XCTAssertFalse(context.bounded(windowIdx: 8))
        XCTAssertFalse(context.bounded(windowIdx: 25))
    }

    func testPublishedIntervalsExcludePaddingAndPreserveOverlap() throws {
        let a = try XCTUnwrap(VoiceInterval.clipped(startSeconds: 36.214, endSeconds: 45,
                                                  speakerId: "raw-0", durationMs: 37_900))
        XCTAssertEqual(a.startMs, 36_214)
        XCTAssertEqual(a.endMs, 37_900)
        let b = try XCTUnwrap(VoiceInterval.clipped(startSeconds: 37, endSeconds: 38,
                                                  speakerId: "raw-1", durationMs: 37_900))
        XCTAssertEqual(b.startMs, 37_000)
        XCTAssertEqual(b.endMs, 37_900)
        for (start, end) in [(37.9, 60.0), (45, 60), (2, 1), (-2, -1), (1, 1), (.nan, 2), (1, .infinity)] {
            XCTAssertNil(VoiceInterval.clipped(startSeconds: start, endSeconds: end,
                                              speakerId: "raw-0", durationMs: 37_900))
        }
    }

    func testOldRunKeepsItsFingerprintWhileNewRunInvalidatesCheckpoints() throws {
        let current = RunInfo(sourceHash: "source", profileHash: "legacy-model-profile")
        var previous = current
        previous.pipelineVersion = "1.0.0-audio2-asr5-live1-diarization3-summary11"
        let decoded = try JSONDecoder().decode(RunInfo.self, from: JSONEncoder().encode(previous))
        XCTAssertEqual(decoded.pipelineVersion, previous.pipelineVersion)
        XCTAssertEqual(decoded.fingerprint, Disk.fingerprint(previous.sourceHash + previous.profileHash + previous.pipelineVersion))
        XCTAssertNotEqual(current.fingerprint, decoded.fingerprint)
        XCTAssertNil(decoded.modelIDs)
        XCTAssertEqual(try decoded.modelID(for: .diarization), "diarization")
    }

    @MainActor
    func testSegmenterKeepsRealLengthAtModelStrideBoundaries() async throws {
        guard let folder = ProcessInfo.processInfo.environment["LOCALSCRIBE_DIARIZATION_FIXTURE_MODELS"] else {
            throw XCTSkip("Set the local model path to check actual segmenter stride")
        }
        let url = URL(fileURLWithPath: folder).appendingPathComponent("speaker_segmenter/pyannote-v3/W8A16/SpeakerSegmenter.mlmodelc")
        let segmenter = try await SpeakerSegmenterModel(modelURL: url, concurrentWorkers: 1)
        try await segmenter.loadModel()
        defer { segmenter.unloadModel() }
        let maximum = 480_000, stride = maximum - segmenter.modelChunkStrideOffset
        XCTAssertGreaterThan(stride, 0)
        XCTAssertLessThan(stride, maximum)
        for count in [1, 1600, maximum - 1, maximum, maximum + 1,
                      maximum + stride - 1, maximum + stride, maximum + stride + 1] {
            let audio = (0..<count).map { Float($0 % 127) / 1270 }
            let (stream, continuation) = AsyncStream<SpeakerSegmenterOutput>.makeStream()
            try await segmenter.predict(audioArray: audio, sendOutput: { continuation.yield($0) })
            continuation.finish()
            var outputs: [SpeakerSegmenterOutput] = []
            for await output in stream { outputs.append(output) }
            XCTAssertEqual(outputs.count, segmenter.maxChunks(for: count))
            for output in outputs {
                let start = output.chunkIndex * stride
                let realCount = min(maximum, count - start)
                XCTAssertEqual(output.waveformLength, Float(realCount) / 16_000)
                XCTAssertEqual(output.audioChunk.count, maximum)
                XCTAssertFalse(output.featureNames.isEmpty)
                guard output.audioChunk.count == maximum else { continue }
                XCTAssertEqual(output.audioChunk[0].floatValue, audio[start])
                if realCount < maximum {
                    XCTAssertEqual(output.audioChunk[realCount].floatValue, audio[start + realCount - 1])
                }
            }
        }
    }

    @MainActor
    func testReportedReturningSpeakerWithLocalModels() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let audioPath = environment["LOCALSCRIBE_DIARIZATION_FIXTURE_WAV"],
              let modelPath = environment["LOCALSCRIBE_DIARIZATION_FIXTURE_MODELS"] else {
            throw XCTSkip("Set local regression WAV and model paths; private recordings are never bundled with tests")
        }
        let url = URL(fileURLWithPath: audioPath)
        let hash = try Disk.hash(url)
        let samples = try Media.samples(url)
        XCTAssertEqual(samples.count, 606_400)
        let kit = try await SpeakerKit(PyannoteConfig(modelFolder: modelPath, download: false, load: true,
                                                      verbose: false, logLevel: .none,
                                                      concurrentSegmenterWorkers: 1, concurrentEmbedderWorkers: 1))
        let result = try await kit.diarize(audioArray: samples)
        XCTAssertEqual(result.speakerCount, 2)
        let speakers = [Float(5), 22, 32].map { time in
            result.segments.first { $0.startTime <= time && time < $0.endTime }?.speaker.speakerId
        }
        XCTAssertNotNil(speakers[0])
        XCTAssertNotNil(speakers[1])
        XCTAssertEqual(speakers[0], speakers[2])
        XCTAssertNotEqual(speakers[0], speakers[1])
        XCTAssertTrue(result.segments.allSatisfy { $0.startTime >= 0 && $0.endTime <= 37.9 })
        XCTAssertEqual(try Disk.hash(url), hash)
    }
}
