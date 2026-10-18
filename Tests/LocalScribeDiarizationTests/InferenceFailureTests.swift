import XCTest
import CoreML
import LocalScribeCore
@testable import LocalScribeSpeakerKit
@testable import LocalScribeWorker

private enum FakeInferenceError: Error { case predictor, embedder, timeout }

private actor InferenceLog {
    var consumed: [Int] = []
    var progress: [Int] = []
    var producerCancelled = false
    func consume(_ embeddings: [SpeakerEmbedding]) { consumed += embeddings.map(\.windowIndex) }
    func report(_ count: Int) { progress.append(count) }
    func cancelled() { producerCancelled = true }
}

// Valid-shaped segmenter features. Silence is represented by zero activity,
// never by missing features or a substituted provider after a thrown prediction.
private func fakeOutput(_ index: Int, silent: Bool = false) throws -> SpeakerSegmenterOutput {
    let activity = try MLMultiArray(shape: [2, 1], dataType: .float32)
    let ids = try MLMultiArray(shape: [2, 5, 1], dataType: .float32)
    let overlap = try MLMultiArray(shape: [2, 5], dataType: .float32)
    let waveform = try MLMultiArray(shape: [2, 1, 5], dataType: .float32)
    for i in 0..<activity.count { activity[i] = silent ? 0 : 5 }
    for i in 0..<ids.count { ids[i] = silent ? 0 : 1 }
    for i in 0..<overlap.count { overlap[i] = 0 }
    let features = try MLDictionaryFeatureProvider(dictionary: [
        "speaker_activity": activity, "speaker_ids": ids,
        "overlapped_speaker_activity": overlap, "sliding_window_waveform": waveform
    ])
    return SpeakerSegmenterOutput(features: features, chunkIndex: index, audioChunk: waveform,
                                  chunkStride: 30, waveformLength: 30, modelSampleRate: 1, audioSampleRate: 1)
}

private func fakeEmbeddings(_ output: SpeakerSegmenterOutput) -> [SpeakerEmbedding] {
    guard let activity = output.speakerActivity, activity[0].intValue > 0 else { return [] }
    return [SpeakerEmbedding(embedding: [1, 0], activeFrames: [1], windowIndex: output.chunkIndex,
                             speakerIndex: 0, nonOverlappedFrameRatio: 1)]
}

@MainActor
final class InferenceFailureTests: XCTestCase {
    // Do not await a hung task after the deadline: a regression must fail the
    // test instead of hanging XCTest itself. All successful paths join the task.
    private func withinDeadline(_ operation: @escaping @MainActor () async throws -> Void) async throws {
        let ended = expectation(description: "Producer and consumers exited")
        var finished = false
        let task = Task {
            defer { finished = true; ended.fulfill() }
            try await operation()
        }
        await fulfillment(of: [ended], timeout: 5)
        guard finished else { task.cancel(); throw FakeInferenceError.timeout }
        try await task.value
    }

    private func segmenter(workers: Int = 1) async throws -> SpeakerSegmenterModel {
        try await SpeakerSegmenterModel(modelURL: URL(fileURLWithPath: "/unused"), sampleRate: 1,
                                        concurrentWorkers: workers, useFullRedundancy: false)
    }

    func testMiddlePredictorFailureClosesConsumersAndThrowsOriginalError() async throws {
        let segmenter = try await segmenter()
        let log = InferenceLog()
        let (firstConsumed, signal) = AsyncStream<Void>.makeStream()
        try await withinDeadline {
            do {
                _ = try await PyannoteDiarizerActor.processClip(expectedChunks: 3, workerCount: 4, produce: { continuation in
                    try await segmenter.predictChunks(audioArray: [Float](repeating: 0.1, count: 90),
                                                       outputContinuation: continuation, chunkStrideOffset: 0) { index, _ in
                        if index == 1 {
                            for await _ in firstConsumed { break }
                            throw FakeInferenceError.predictor
                        }
                        return try fakeOutput(index)
                    }
                }, embed: { fakeEmbeddings($0) }, consume: { embeddings in
                    await log.consume(embeddings)
                    signal.yield(())
                })
                XCTFail("Partial segmentation must not succeed")
            } catch FakeInferenceError.predictor { /* expected, including the original error type */ }
        }
        let consumed = await log.consumed
        XCTAssertEqual(consumed, [0])
    }

    func testMiddleEmbedderFailureCancelsProducerAndWakesIdleConsumers() async throws {
        let log = InferenceLog()
        let (firstConsumed, signal) = AsyncStream<Void>.makeStream()
        try await withinDeadline {
            do {
                _ = try await PyannoteDiarizerActor.processClip(expectedChunks: 3, workerCount: 4, produce: { continuation in
                    // Deliberately leave the stream open and producer suspended.
                    // Only cancellation/teardown by processClip can stop it.
                    continuation.yield(try fakeOutput(0))
                    for await _ in firstConsumed { break }
                    continuation.yield(try fakeOutput(1))
                    do { try await Task.sleep(for: .seconds(30)) }
                    catch { await log.cancelled(); throw error }
                }, embed: { output in
                    if output.chunkIndex == 1 { throw FakeInferenceError.embedder }
                    return fakeEmbeddings(output)
                }, consume: { embeddings in
                    await log.consume(embeddings)
                    signal.yield(())
                })
                XCTFail("Partial embedding must not succeed")
            } catch FakeInferenceError.embedder { /* expected */ }
        }
        let consumed = await log.consumed, cancelled = await log.producerCancelled
        XCTAssertEqual(consumed, [0])
        XCTAssertTrue(cancelled)
    }

    func testThrowingProducerThatNeverFinishesStreamDoesNotHang() async throws {
        try await withinDeadline {
            do {
                _ = try await PyannoteDiarizerActor.processClip(expectedChunks: 3, workerCount: 4,
                    produce: { _ in throw FakeInferenceError.predictor },
                    embed: { fakeEmbeddings($0) }, consume: { _ in })
                XCTFail("Producer failure must propagate")
            } catch FakeInferenceError.predictor { /* expected */ }
        }
    }

    func testMissingDuplicateAndOutOfRangeBlocksCannotSucceed() async throws {
        for indices in [[0, 2], [0, 0, 2], [0, 1, 3]] {
            try await withinDeadline {
                do {
                    _ = try await PyannoteDiarizerActor.processClip(expectedChunks: 3, workerCount: 3,
                        produce: { continuation in
                            for index in indices { continuation.yield(try fakeOutput(index)) }
                        }, embed: { fakeEmbeddings($0) }, consume: { _ in })
                    XCTFail("Incomplete/invalid block coverage must fail: \(indices)")
                } catch is SpeakerKitError { /* expected */ }
            }
        }
    }

    func testValidSilentMiddleBlockAndEntirelySilentClipComplete() async throws {
        let segmenter = try await segmenter(workers: 3)
        for silentIndices: Set<Int> in [[1], [0, 1, 2]] {
            let log = InferenceLog()
            try await withinDeadline {
                let snapshot = try await PyannoteDiarizerActor.processClip(expectedChunks: 3, workerCount: 3,
                    produce: { continuation in
                        try await segmenter.predictChunks(audioArray: [Float](repeating: 0, count: 90),
                                                           outputContinuation: continuation, chunkStrideOffset: 0) { index, _ in
                            try fakeOutput(index, silent: silentIndices.contains(index))
                        }
                    }, embed: { fakeEmbeddings($0) }, consume: { await log.consume($0) },
                    progress: { await log.report($0) })
                XCTAssertEqual(snapshot.count, 3)
            }
            let consumed = await log.consumed, progress = await log.progress
            XCTAssertEqual(consumed.sorted(), [0, 1, 2].filter { !silentIndices.contains($0) })
            XCTAssertEqual(progress.sorted(), [1, 2, 3])
        }
    }

    func testEmptyClipCompletesWithoutInventingABlock() async throws {
        let segmenter = try await segmenter()
        XCTAssertEqual(segmenter.maxChunks(for: 0), 0)
        try await withinDeadline {
            let snapshot = try await PyannoteDiarizerActor.processClip(expectedChunks: 0, workerCount: 4,
                produce: { continuation in
                    try await segmenter.predictChunks(audioArray: [], outputContinuation: continuation,
                                                       chunkStrideOffset: 0) { _, _ in
                        XCTFail("Empty audio has no inference blocks")
                        throw FakeInferenceError.predictor
                    }
                }, embed: { _ in XCTFail("Empty audio has no embeddings"); return [] }, consume: { _ in })
            XCTAssertEqual(snapshot.count, 0)
        }
    }

    func testParentCancellationJoinsProducerAndConsumers() async throws {
        let log = InferenceLog()
        let ready = expectation(description: "Producer started")
        try await withinDeadline {
            let task = Task {
                try await PyannoteDiarizerActor.processClip(expectedChunks: 1, workerCount: 4, produce: { _ in
                    ready.fulfill()
                    do { try await Task.sleep(for: .seconds(30)) }
                    catch { await log.cancelled(); throw error }
                }, embed: { fakeEmbeddings($0) }, consume: { _ in })
            }
            await self.fulfillment(of: [ready], timeout: 2)
            task.cancel()
            do { _ = try await task.value; XCTFail("Cancellation must throw") }
            catch is CancellationError { /* expected */ }
        }
        let cancelled = await log.producerCancelled
        XCTAssertTrue(cancelled)
    }

    func testParallelPredictorFailureCancelsSiblingPredictions() async throws {
        let segmenter = try await segmenter(workers: 3)
        let (started, signal) = AsyncStream<Void>.makeStream()
        let siblingExited = expectation(description: "Sibling prediction cancelled")
        siblingExited.assertForOverFulfill = false
        try await withinDeadline {
            let (stream, continuation) = AsyncStream<SpeakerSegmenterOutput>.makeStream()
            do {
                try await segmenter.predictChunks(audioArray: [Float](repeating: 0, count: 90),
                                                   outputContinuation: continuation, chunkStrideOffset: 0) { index, _ in
                    if index == 1 {
                        for await _ in started { break }
                        throw FakeInferenceError.predictor
                    }
                    signal.yield(())
                    defer { siblingExited.fulfill() }
                    try await Task.sleep(for: .seconds(30))
                    return try fakeOutput(index)
                }
                XCTFail("Prediction failure must propagate")
            } catch FakeInferenceError.predictor { /* expected */ }
            // The continuation was finished even on error.
            for await _ in stream {}
        }
        await fulfillment(of: [siblingExited], timeout: 1)
    }

    private func pipelineFixture(_ root: URL, silent: Bool = false) throws -> (Pipeline, RecordingRepository, Manifest, URL, URL) {
        let repo = try RecordingRepository(root: root)
        var manifest = Manifest(sourceType: "import", title: "Technical fixture", filename: "original.wav")
        let original = repo.folder(manifest.id).appendingPathComponent(manifest.originalRelativePath)
        try Disk.directory(original.deletingLastPathComponent())
        try Data("synthetic audio placeholder; inference is injected".utf8).write(to: original)
        manifest.sha256 = try Disk.hash(original); manifest.durationMs = 90_000; manifest.sourceComplete = true
        let oldInfo = RunInfo(sourceHash: manifest.sha256, profileHash: "old")
        let oldRun = repo.run(manifest.id, oldInfo.id)
        try Disk.write(oldInfo, to: oldRun.appendingPathComponent("run.json"))
        try Disk.write(Transcript(fingerprint: oldInfo.fingerprint, diarized: true, segments: [
            Segment(id: "old", startMs: 0, endMs: 1000, speakerId: "speaker-1", text: "Old result", language: "en")
        ]), to: oldRun.appendingPathComponent("transcript.json"))
        manifest.activeRunId = oldInfo.id
        let info = try repo.beginRun(&manifest, catalog: ModelCatalog(models: []))
        let run = repo.run(manifest.id, info.id)
        let asr = Transcript(fingerprint: info.fingerprint, diarized: false, segments: silent ? [] : [
            Segment(id: "first", startMs: 1000, endMs: 2000, text: "First", language: "en"),
            Segment(id: "middle", startMs: 31_000, endMs: 32_000, text: "Middle", language: "en"),
            Segment(id: "last", startMs: 61_000, endMs: 62_000, text: "Last", language: "en")
        ])
        try Disk.write(asr, to: run.appendingPathComponent("asr-transcript.json"))
        let command = WorkerCommand(jobId: manifest.id, runId: info.id, stage: .diarizing,
                                    recordingPath: repo.folder(manifest.id).path, modelsPath: repo.models.path, toolsPath: root.path)
        return (try Pipeline(command: command, emit: { _, _, _ in }), repo, manifest, run, oldRun)
    }

    func testMiddleInferenceFailuresKeepASRAndOldActiveRunWithoutPublishing() async throws {
        for failPredictor in [true, false] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let (pipeline, repo, manifest, run, oldRun) = try pipelineFixture(root)
            let asrURL = run.appendingPathComponent("asr-transcript.json")
            let asrBefore = try Data(contentsOf: asrURL)
            let manifestBefore = try Data(contentsOf: repo.folder(manifest.id).appendingPathComponent("manifest.json"))
            let activeBefore = try Data(contentsOf: oldRun.appendingPathComponent("transcript.json"))
            let segmenter = try await segmenter()
            try await withinDeadline {
                do {
                    _ = try await pipeline.diarize { _, _, _ in
                        _ = try await PyannoteDiarizerActor.processClip(expectedChunks: 3, workerCount: 1,
                            produce: { continuation in
                                try await segmenter.predictChunks(audioArray: [Float](repeating: 0, count: 90),
                                                                   outputContinuation: continuation, chunkStrideOffset: 0) { index, _ in
                                    if failPredictor && index == 1 { throw FakeInferenceError.predictor }
                                    return try fakeOutput(index)
                                }
                            }, embed: { output in
                                if !failPredictor && output.chunkIndex == 1 { throw FakeInferenceError.embedder }
                                return fakeEmbeddings(output)
                            }, consume: { _ in })
                        return [VoiceInterval(startMs: 0, endMs: 90_000, speakerId: "raw-0")]
                    }
                    XCTFail("Failed diarization must not publish a transcript")
                } catch let error as ScribeError {
                    XCTAssertTrue(error.localizedDescription.contains("Расшифровка сохранена"))
                }
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: run.appendingPathComponent("transcript.json").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: run.appendingPathComponent("diarization.json").path))
            XCTAssertEqual(try Data(contentsOf: asrURL), asrBefore)
            XCTAssertEqual(try Data(contentsOf: oldRun.appendingPathComponent("transcript.json")), activeBefore)
            XCTAssertEqual(try Data(contentsOf: repo.folder(manifest.id).appendingPathComponent("manifest.json")), manifestBefore)
            XCTAssertEqual(try repo.load(manifest.id).activeRunId, manifest.activeRunId)
            XCTAssertEqual(try repo.load(manifest.id).pendingRunId, manifest.pendingRunId)
            XCTAssertEqual(repo.results(manifest).0?.segments.first?.text, "Old result")
        }
    }

    func testSuccessfulInferencePublishesOnlyAfterAllBlocks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (pipeline, repo, manifest, run, _) = try pipelineFixture(root)
        let log = InferenceLog()
        let name = try await pipeline.diarize { _, _, _ in
            _ = try await PyannoteDiarizerActor.processClip(expectedChunks: 3, workerCount: 3,
                produce: { continuation in
                    for index in [2, 0, 1] { continuation.yield(try fakeOutput(index, silent: index == 1)) }
                }, embed: { fakeEmbeddings($0) }, consume: { await log.consume($0) })
            return [VoiceInterval(startMs: 0, endMs: 30_000, speakerId: "raw-0"),
                    VoiceInterval(startMs: 60_000, endMs: 90_000, speakerId: "raw-0")]
        }
        let result = try Disk.read(Transcript.self, at: run.appendingPathComponent(name))
        let asr = try Disk.read(Transcript.self, at: run.appendingPathComponent("asr-transcript.json"))
        let artifact = try Disk.read(DiarizationArtifact.self, at: run.appendingPathComponent("diarization.json"))
        XCTAssertTrue(result.diarized)
        XCTAssertEqual(result.fingerprint, asr.fingerprint)
        XCTAssertEqual(artifact.intervals.count, 2)
        XCTAssertEqual(result.segments.map(\.speakerId), ["speaker-1", nil, "speaker-1"])
        XCTAssertFalse(asr.diarized)
        // Only the GUI can promote pendingRunId after all later stages finish.
        XCTAssertEqual(try repo.load(manifest.id).activeRunId, manifest.activeRunId)
    }

    func testCancellationAfterInferenceCannotPublishReadyTranscript() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (pipeline, _, _, run, _) = try pipelineFixture(root)
        try await withinDeadline {
            let task = Task {
                try await pipeline.diarize { _, _, _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return [VoiceInterval(startMs: 0, endMs: 90_000, speakerId: "raw-0")]
                }
            }
            do { _ = try await task.value; XCTFail("Cancelled inference must not publish") }
            catch is CancellationError { /* expected */ }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.appendingPathComponent("transcript.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.appendingPathComponent("diarization.json").path))
    }

    func testEmptyASRIsSuccessfulSilenceWithoutInference() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (pipeline, _, _, run, _) = try pipelineFixture(root, silent: true)
        let name = try await pipeline.diarize { _, _, _ in
            XCTFail("No inference is needed for empty ASR")
            throw FakeInferenceError.predictor
        }
        XCTAssertEqual(name, "transcript.json")
        let result = try Disk.read(Transcript.self, at: run.appendingPathComponent(name))
        XCTAssertTrue(result.diarized)
        XCTAssertTrue(result.segments.isEmpty)
    }
}
