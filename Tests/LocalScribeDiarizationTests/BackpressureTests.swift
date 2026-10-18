import XCTest
import CoreML
import Synchronization
import Darwin
@testable import LocalScribeSpeakerKit

private enum BackpressureError: Error { case predictor, embedder, timeout }

private func residentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.resident_size : 0
}

private final class OutputLifetimes: Sendable {
    struct Stats {
        var live = 0
        var peak = 0
        var peakRSS: UInt64 = 0
        var produced: [Int] = []
    }
    private let state = Mutex(Stats())
    var snapshot: Stats { state.withLock { $0 } }
    func created(_ index: Int) {
        let rss = residentBytes()
        state.withLock {
            $0.live += 1
            $0.peak = max($0.peak, $0.live)
            $0.peakRSS = max($0.peakRSS, rss)
            $0.produced.append(index)
        }
    }
    func released() { state.withLock { $0.live -= 1 } }
}

// The provider has exactly the same lifetime as its SpeakerSegmenterOutput.
// Touch a 1 MiB ML array per block so RSS measures resident payload, not just
// lazily allocated virtual pages. No output/array is retained by the test log.
private final class TrackedFeatures: NSObject, MLFeatureProvider {
    let tracker: OutputLifetimes
    var featureNames: Set<String> { [] }
    func featureValue(for featureName: String) -> MLFeatureValue? { nil }
    init(index: Int, tracker: OutputLifetimes) {
        self.tracker = tracker
        super.init()
        tracker.created(index)
    }
    deinit { tracker.released() }
}

private func trackedOutput(_ index: Int, tracker: OutputLifetimes) throws -> SpeakerSegmenterOutput {
    let waveform = try MLMultiArray(shape: [262_144], dataType: .float32)
    waveform.dataPointer.assumingMemoryBound(to: Float.self).update(repeating: Float(index), count: waveform.count)
    return SpeakerSegmenterOutput(features: TrackedFeatures(index: index, tracker: tracker),
                                  chunkIndex: index, audioChunk: waveform, chunkStride: 26,
                                  waveformLength: index == 511 ? 7 : 30,
                                  modelSampleRate: 1, audioSampleRate: 1)
}

private actor EmbeddedIndices {
    var values: [Int] = []
    func add(_ embeddings: [SpeakerEmbedding]) { values += embeddings.map(\.windowIndex) }
}

@MainActor
final class BackpressureTests: XCTestCase {
    private func withinDeadline(_ operation: @escaping @MainActor () async throws -> Void) async throws {
        let ended = expectation(description: "All pipeline tasks joined")
        var finished = false
        let task = Task {
            defer { finished = true; ended.fulfill() }
            try await operation()
        }
        await fulfillment(of: [ended], timeout: 15)
        guard finished else { task.cancel(); throw BackpressureError.timeout }
        try await task.value
    }

    func testFastSegmenterSlowEmbedderBoundsLiveOutputsWithoutDroppingIndices() async throws {
        for (segmenters, embedders, capacity) in [(1, 1, 1), (4, 2, 3)] {
            let tracker = OutputLifetimes(), consumed = EmbeddedIndices()
            let segmenter = try await SpeakerSegmenterModel(modelURL: URL(fileURLWithPath: "/unused"),
                sampleRate: 1, concurrentWorkers: segmenters, useFullRedundancy: false)
            let start = ContinuousClock.now
            try await withinDeadline {
                let snapshot = try await PyannoteDiarizerActor.processClip(expectedChunks: 512,
                    workerCount: embedders, bufferCapacity: capacity, produce: { send in
                        try await segmenter.predictChunks(audioArray: [Float](repeating: 0, count: 30 * 512),
                            sendOutput: send, chunkStrideOffset: 0) { index, _ in
                                try trackedOutput(index, tracker: tracker)
                            }
                    }, embed: { output in
                        try await Task.sleep(for: .milliseconds(2))
                        XCTAssertEqual(output.audioChunk[0].intValue, output.chunkIndex)
                        XCTAssertEqual(output.chunkStride, 26)
                        XCTAssertEqual(output.waveformLength, output.chunkIndex == 511 ? 7 : 30)
                        return [SpeakerEmbedding(embedding: [1, 0], activeFrames: [1], windowIndex: output.chunkIndex,
                                                 speakerIndex: 0, nonOverlappedFrameRatio: 1)]
                    }, consume: { await consumed.add($0) })
                XCTAssertEqual(snapshot.count, 512)
            }
            let stats = tracker.snapshot
            let indices = await consumed.values
            XCTAssertEqual(indices.sorted(), Array(0..<512))
            XCTAssertEqual(stats.produced.sorted(), Array(0..<512))
            XCTAssertLessThanOrEqual(stats.peak, capacity + segmenters + embedders)
            XCTAssertEqual(stats.live, 0)
            print("R05 segmenters=\(segmenters) embedders=\(embedders) capacity=\(capacity) blocks=512 peakLive=\(stats.peak) peakRSSBytes=\(stats.peakRSS) elapsed=\(start.duration(to: .now))")
        }
    }

    func testEmbedderFailureWithFullBufferJoinsBlockedProducerAndReleasesOutputs() async throws {
        let tracker = OutputLifetimes()
        let producerExited = expectation(description: "Blocked producer exited")
        try await withinDeadline {
            do {
                _ = try await PyannoteDiarizerActor.processClip(expectedChunks: 512, workerCount: 1,
                    produce: { send in
                        defer { producerExited.fulfill() }
                        for index in 0..<512 { try await send(try trackedOutput(index, tracker: tracker)) }
                    }, embed: { _ in
                        // Wait until one output is buffered and one sender is blocked.
                        while tracker.snapshot.produced.count < 3 {
                            try Task.checkCancellation()
                            await Task.yield()
                        }
                        throw BackpressureError.embedder
                    }, consume: { _ in })
                XCTFail("Embedding failure must propagate")
            } catch BackpressureError.embedder { /* preserve the original error */ }
        }
        await fulfillment(of: [producerExited], timeout: 1)
        XCTAssertEqual(tracker.snapshot.produced, [0, 1, 2])
        XCTAssertEqual(tracker.snapshot.live, 0)
    }

    func testParentCancellationWithFullBufferJoinsBothSidesAndReleasesOutputs() async throws {
        let tracker = OutputLifetimes()
        try await withinDeadline {
            let task = Task {
                try await PyannoteDiarizerActor.processClip(expectedChunks: 512, workerCount: 1,
                    produce: { send in
                        for index in 0..<512 { try await send(try trackedOutput(index, tracker: tracker)) }
                    }, embed: { _ in
                        try await Task.sleep(for: .seconds(30))
                        return []
                    }, consume: { _ in })
            }
            while tracker.snapshot.produced.count < 3 {
                try Task.checkCancellation()
                await Task.yield()
            }
            task.cancel()
            do { _ = try await task.value; XCTFail("Cancellation must throw") }
            catch is CancellationError { /* expected */ }
        }
        XCTAssertEqual(tracker.snapshot.produced, [0, 1, 2])
        XCTAssertEqual(tracker.snapshot.live, 0)
    }

    func testNestedPredictorFailureCancelsBlockedSiblingSendersWithoutMaskingError() async throws {
        let tracker = OutputLifetimes()
        let segmenter = try await SpeakerSegmenterModel(modelURL: URL(fileURLWithPath: "/unused"),
            sampleRate: 1, concurrentWorkers: 4, useFullRedundancy: false)
        try await withinDeadline {
            do {
                _ = try await PyannoteDiarizerActor.processClip(expectedChunks: 512, workerCount: 1,
                    produce: { send in
                        try await segmenter.predictChunks(audioArray: [Float](repeating: 0, count: 30 * 512),
                            sendOutput: send, chunkStrideOffset: 0) { index, _ in
                                if index == 0 {
                                    // Other workers fill the queue and suspend in send().
                                    while tracker.snapshot.produced.count < 5 {
                                        try Task.checkCancellation()
                                        await Task.yield()
                                    }
                                    throw BackpressureError.predictor
                                }
                                return try trackedOutput(index, tracker: tracker)
                            }
                    }, embed: { _ in
                        try await Task.sleep(for: .seconds(30))
                        return []
                    }, consume: { _ in })
                XCTFail("Prediction failure must propagate")
            } catch BackpressureError.predictor { /* cancellation must not mask this */ }
        }
        XCTAssertEqual(tracker.snapshot.live, 0)
        XCTAssertLessThanOrEqual(tracker.snapshot.peak, 5)
    }

    func testSuccessfulFinishDrainsBufferAndCancellationRejectsFutureOperations() async throws {
        let channel = DiarizationChannel<Int>(capacity: 3)
        for index in 0..<3 { try await channel.send(index) }
        channel.finish()
        channel.finish()
        for index in 0..<3 {
            let received = try await channel.next()
            XCTAssertEqual(received, index)
        }
        let end = try await channel.next()
        XCTAssertNil(end)
        channel.cancel()
        channel.cancel()
        do { try await channel.send(3); XCTFail("Closed channel must reject send") }
        catch is CancellationError { /* expected */ }
        do { _ = try await channel.next(); XCTFail("Aborted channel must reject receive") }
        catch is CancellationError { /* expected */ }
    }

    func testCancellationBeforeWaiterRegistrationAndIdleReceiveDoNotHang() async throws {
        try await withinDeadline {
            for preCancelled in [true, false] {
                let channel = DiarizationChannel<Int>(capacity: 1)
                let entered = self.expectation(description: "Receiver entered")
                let task = Task {
                    if preCancelled { withUnsafeCurrentTask { $0?.cancel() } }
                    entered.fulfill()
                    return try await channel.next()
                }
                await self.fulfillment(of: [entered], timeout: 1)
                task.cancel()
                do { _ = try await task.value; XCTFail("Cancelled receive must throw") }
                catch is CancellationError { /* expected */ }
                channel.finish()
            }
        }
    }

    func testCancelledSendIsRemovedAndDoesNotReplaceBufferedOutput() async throws {
        try await withinDeadline {
            for preCancelled in [true, false] {
                for _ in 0..<100 {
                    let channel = DiarizationChannel<Int>(capacity: 1)
                    try await channel.send(0)
                    let task = Task {
                        if preCancelled { withUnsafeCurrentTask { $0?.cancel() } }
                        try await channel.send(1)
                    }
                    // Exercise cancellation before registration and racing with it.
                    if !preCancelled { await Task.yield(); task.cancel() }
                    do { try await task.value; XCTFail("Cancelled send must throw") }
                    catch is CancellationError { /* expected */ }
                    channel.finish()
                    let buffered = try await channel.next()
                    let end = try await channel.next()
                    XCTAssertEqual(buffered, 0)
                    XCTAssertNil(end)
                }
            }
        }
    }
}
