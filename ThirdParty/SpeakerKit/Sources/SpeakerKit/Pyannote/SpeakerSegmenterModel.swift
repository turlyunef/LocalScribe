//  For licensing see accompanying LICENSE.md file.
//  Copyright © 2026 Argmax, Inc. All rights reserved.

@preconcurrency import CoreML
import ArgmaxCore
import WhisperKit

@available(macOS 13, iOS 16, watchOS 10, visionOS 1, *)
public class SpeakerSegmenterModel: @unchecked Sendable {
    public private(set) var modelURL: URL
    public private(set) var computeUnits: MLComputeUnits
    @Protected public private(set) var model: MLModel?
    public private(set) var modelState: ModelState = .unloaded
    public let sampleRate: Int

    let concurrentWorkers: Int

    private let useFullRedundancy: Bool

    static let chunkLengthInSeconds: Float = 30.0

    init(
        modelURL: URL,
        sampleRate: Int = 16000,
        concurrentWorkers: Int = 1,
        useFullRedundancy: Bool = true,
        computeUnits: MLComputeUnits = .cpuOnly
    ) async throws {
        self.computeUnits = computeUnits
        self.modelURL = modelURL
        self.concurrentWorkers = concurrentWorkers
        self.useFullRedundancy = useFullRedundancy
        self.sampleRate = sampleRate

        Logging.info("[SpeakerSegmenter] initialized with \(modelURL.lastPathComponent) model")
    }

    // MARK: - Model Loading

    public func loadModel(prewarmMode: Bool = false) async throws {
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        let loadedModel = try await MLModel.load(contentsOf: modelURL, configuration: config)
        let description = loadedModel.modelDescription
        try Self.validateGeometry(
            waveform: description.inputDescriptionsByName["waveform"]?.multiArrayConstraint?.shape.map(\.intValue) ?? [],
            sliding: description.outputDescriptionsByName["sliding_window_waveform"]?.multiArrayConstraint?.shape.map(\.intValue) ?? [],
            speakerIDs: description.outputDescriptionsByName["speaker_ids"]?.multiArrayConstraint?.shape.map(\.intValue) ?? [], sampleRate: sampleRate)
        model = prewarmMode ? nil : loadedModel
        modelState = prewarmMode ? .prewarmed : .loaded
    }

    static func validateGeometry(waveform: [Int], sliding: [Int], speakerIDs: [Int], sampleRate: Int) throws {
        guard (1...384_000).contains(sampleRate), waveform.count == 1,
              waveform[0] == 30 * sampleRate, sliding.count == 3, speakerIDs.count == 3,
              sliding[0] > 1, sliding[0] <= waveform[0], sliding[1] > 0,
              sliding[2] > 0, sliding[2] < waveform[0],
              speakerIDs[0] == sliding[0], speakerIDs[1] > 0, speakerIDs[1] <= waveform[0], speakerIDs[2] > 0 else {
            throw SpeakerKitError.invalidModelOutput("Invalid segmenter model geometry")
        }
        let stride = Float(waveform[0] - sliding[2]) / Float(sliding[0] - 1)
        let offset = Float(sliding[2]) - stride
        guard stride.isFinite, stride > 0, offset.isFinite, offset >= 0, offset < Float(waveform[0]) else {
            throw SpeakerKitError.invalidModelOutput("Invalid segmenter window stride")
        }
    }

    public func unloadModel() {
        model = nil
        modelState = .unloaded
    }

    // MARK: - Model Properties

    var windowsLength: Float {
        guard let model else { return 0.0 }
        if let outputDescription = model.modelDescription.outputDescriptionsByName["sliding_window_waveform"],
           outputDescription.type == .multiArray,
           let shape = outputDescription.multiArrayConstraint?.shape,
           shape.count == 3 {
            return shape[2].floatValue / Float(sampleRate)
        }
        return 0.0
    }

    var modelSampleRate: Float {
        guard let model else { return 0.0 }

        var framesPerWindow: Float {
            if let outputDescription = model.modelDescription.outputDescriptionsByName["speaker_ids"],
               outputDescription.type == .multiArray,
               let shape = outputDescription.multiArrayConstraint?.shape,
               shape.count == 3 {
                return shape[1].floatValue
            }
            return 0.0
        }

        guard windowsLength > 0.0 else { return 0.0 }
        return framesPerWindow / windowsLength
    }

    var modelChunkStrideOffset: Int {
        guard let model else { return 0 }

        var slidingWindowShape: [Float] {
            if let outputDescription = model.modelDescription.outputDescriptionsByName["sliding_window_waveform"],
               outputDescription.type == .multiArray,
               let shape = outputDescription.multiArrayConstraint?.shape,
               shape.count == 3 {
                return shape.map { $0.floatValue }
            }
            return []
        }

        var waveformShape: [Float] {
            if let inputDescription = model.modelDescription.inputDescriptionsByName["waveform"],
               inputDescription.type == .multiArray,
               let shape = inputDescription.multiArrayConstraint?.shape,
               shape.count == 1 {
                return shape.map { $0.floatValue }
            }
            return []
        }

        guard !waveformShape.isEmpty, !slidingWindowShape.isEmpty else {
            return 0
        }

        // Window stride = (chunk length - window length) / (windows count - 1)
        let windowLength = slidingWindowShape[2]
        let windowStride = (waveformShape[0] - windowLength) / (slidingWindowShape[0] - 1.0)

        // Stride offset = window length - window stride
        let chunkStrideOffset = windowLength - windowStride
        guard chunkStrideOffset.isFinite, chunkStrideOffset >= 0, chunkStrideOffset < Float(Int.max) else { return 0 }
        return Int(chunkStrideOffset)
    }

    // MARK: - Prediction

    public func predict(
        audioArray: [Float],
        sendOutput: @escaping @Sendable (SpeakerSegmenterOutput) async throws -> Void,
        windowPadding: Int = 0,
        audioRange: Range<Int>? = nil
    ) async throws {
        let bounds = audioRange ?? audioArray.indices
        guard bounds.lowerBound >= 0, bounds.upperBound <= audioArray.count else {
            throw SpeakerKitError.invalidModelOutput("Invalid segmenter chunk bounds")
        }
        try await predict(audioRange: bounds, readFrames: { Array(audioArray[$0]) },
                          sendOutput: sendOutput, windowPadding: windowPadding)
    }

    // LocalScribe: the same global chunk indices and overlap are used for
    // in-memory samples and PCM read on demand from disk.
    func predict(
        audioRange: Range<Int>,
        readFrames: @escaping @Sendable (Range<Int>) throws -> [Float],
        sendOutput: @escaping @Sendable (SpeakerSegmenterOutput) async throws -> Void,
        windowPadding: Int = 0
    ) async throws {
        guard let model else {
            throw SpeakerKitError.modelUnavailable("Speaker segmenter model is unavailable")
        }

        let startTime = CFAbsoluteTimeGetCurrent()
        defer {
            let totalTime = (CFAbsoluteTimeGetCurrent() - startTime) * 1_000
            Logging.debug(String(format: "[SpeakerKit] Total segmenter model inference time: %.2f ms", totalTime))
        }

        let sampleRateFloat = Float(sampleRate)
        let modelSampleRate = modelSampleRate
        let chunkStrideOffset = useFullRedundancy ? modelChunkStrideOffset : 0
        let maxChunkLength = Int(Self.chunkLengthInSeconds) * sampleRate
        let chunkStride = Int(Float(maxChunkLength - chunkStrideOffset) / sampleRateFloat)
        try await predictChunks(audioRange: audioRange, readFrames: readFrames, sendOutput: sendOutput,
                                windowPadding: windowPadding, chunkStrideOffset: chunkStrideOffset) { index, waveform in
            guard let audioSamples = AudioProcessor.padOrTrimAudio(
                fromArray: Self.reflectTail(waveform, toLength: maxChunkLength),
                startAt: 0, toLength: maxChunkLength
            ) else {
                throw SpeakerKitError.generic("Segmentation Failed: Audio samples are nil")
            }
            let modelInputs = SpeakerSegmenterInput(waveform: audioSamples)
            let features = try await model.asyncPrediction(from: modelInputs, options: MLPredictionOptions())
            return SpeakerSegmenterOutput(
                features: features, chunkIndex: index, audioChunk: audioSamples,
                chunkStride: chunkStride, waveformLength: Float(waveform.count) / sampleRateFloat,
                modelSampleRate: modelSampleRate, audioSampleRate: sampleRateFloat
            )
        }
    }

    // LocalScribe: the same scheduling path is used with Core ML and fake predictors.
    // A failed prediction must never become a silent/empty feature provider.
    func predictChunks(
        audioArray: [Float],
        sendOutput: @escaping @Sendable (SpeakerSegmenterOutput) async throws -> Void,
        windowPadding: Int = 0,
        chunkStrideOffset: Int,
        audioRange: Range<Int>? = nil,
        predictChunk: @escaping @Sendable (Int, [Float]) async throws -> SpeakerSegmenterOutput
    ) async throws {
        let bounds = audioRange ?? audioArray.indices
        guard bounds.lowerBound >= 0, bounds.upperBound <= audioArray.count else {
            throw SpeakerKitError.invalidModelOutput("Invalid segmenter chunk bounds")
        }
        try await predictChunks(audioRange: bounds, readFrames: { Array(audioArray[$0]) }, sendOutput: sendOutput,
                                windowPadding: windowPadding, chunkStrideOffset: chunkStrideOffset, predictChunk: predictChunk)
    }

    func predictChunks(
        audioRange bounds: Range<Int>,
        readFrames: @escaping @Sendable (Range<Int>) throws -> [Float],
        sendOutput: @escaping @Sendable (SpeakerSegmenterOutput) async throws -> Void,
        windowPadding: Int = 0,
        chunkStrideOffset: Int,
        predictChunk: @escaping @Sendable (Int, [Float]) async throws -> SpeakerSegmenterOutput
    ) async throws {
        guard (1...384_000).contains(sampleRate) else { throw SpeakerKitError.invalidModelOutput("Invalid audio sample rate") }
        let maxChunkLength = Int(Self.chunkLengthInSeconds) * sampleRate
        guard bounds.lowerBound >= 0,
              chunkStrideOffset >= 0, chunkStrideOffset < maxChunkLength,
              windowPadding >= 0, windowPadding <= bounds.count else {
            throw SpeakerKitError.invalidModelOutput("Invalid segmenter chunk bounds")
        }
        // Queue only ranges. PCM is materialized by the worker immediately
        // before inference, so overlapping blocks do not accumulate in memory.
        var chunkEndIndex = bounds.lowerBound
        var chunks: [(index: Int, range: Range<Int>)] = []
        while chunkEndIndex < bounds.upperBound - windowPadding {
            let chunkStartIndex = max(chunkEndIndex - chunkStrideOffset, bounds.lowerBound)
            chunkEndIndex = min(chunkStartIndex + maxChunkLength, bounds.upperBound)
            chunks.append((index: chunks.count, range: chunkStartIndex..<chunkEndIndex))
        }
        let chunkStream = AsyncStream<(index: Int, range: Range<Int>)> { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }

        try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<max(1, concurrentWorkers) {
                group.addTask {
                    var completed = 0
                    for await chunk in chunkStream {
                        try Task.checkCancellation()
                        let waveform = try readFrames(chunk.range)
                        guard waveform.count == chunk.range.count else {
                            throw SpeakerKitError.invalidModelOutput("Incomplete diarization audio")
                        }
                        let output = try await predictChunk(chunk.index, waveform)
                        try Task.checkCancellation()
                        guard output.chunkIndex == chunk.index else {
                            throw SpeakerKitError.invalidModelOutput("Segmenter returned the wrong chunk index")
                        }
                        // Keep this worker occupied until the bounded downstream
                        // channel accepts the output; never drop an audio block.
                        try await sendOutput(output)
                        completed += 1
                    }
                    try Task.checkCancellation()
                    return completed
                }
            }
            var completed = 0
            for try await count in group { completed += count }
            try Task.checkCancellation()
            guard completed == chunks.count else {
                throw SpeakerKitError.invalidModelOutput("Incomplete segmentation")
            }
        }
    }

    // LocalScribe: keep real-speech statistics in the embedder frontend instead
    // of zero-padding a short final chunk. waveformLength above stays REAL;
    // reflected samples are inference context only. See Argmax OSS issue #485.
    static func reflectTail(_ waveform: [Float], toLength length: Int) -> [Float] {
        guard !waveform.isEmpty, waveform.count < length else { return waveform }
        var reflected = waveform
        reflected.reserveCapacity(length)
        var forward = false
        while reflected.count < length {
            let remaining = length - reflected.count
            if forward {
                reflected.append(contentsOf: waveform.prefix(remaining))
            } else {
                reflected.append(contentsOf: waveform.reversed().prefix(remaining))
            }
            forward.toggle()
        }
        return reflected
    }

    func maxChunks(for audioLength: Int) -> Int {
        guard audioLength > 0 else { return 0 }
        let chunkLength = Double(Self.chunkLengthInSeconds) * Double(sampleRate)
        if useFullRedundancy {
            let offset = modelChunkStrideOffset
            let stride = chunkLength - Double(offset)
            return max(0, Int(ceil((Double(audioLength) - chunkLength) / stride))) + 1
        } else {
            return Int(ceil(Double(audioLength) / chunkLength))
        }
    }
}

// MARK: - Model Input / Output

class SpeakerSegmenterInput: MLFeatureProvider {
    var waveform: MLMultiArray

    var featureNames: Set<String> { ["waveform"] }

    func featureValue(for featureName: String) -> MLFeatureValue? {
        if featureName == "waveform" {
            return MLFeatureValue(multiArray: self.waveform)
        }
        return nil
    }

    init(waveform: MLMultiArray) {
        self.waveform = waveform
    }
}

public class SpeakerSegmenterOutput: MLFeatureProvider, CustomDebugStringConvertible, @unchecked Sendable {
    private let provider: MLFeatureProvider

    public private(set) var chunkIndex: Int
    public let audioChunk: MLMultiArray
    public let chunkStride: Int
    public let waveformLength: Float
    public let modelSampleRate: Float
    public let audioSampleRate: Float

    public var featureNames: Set<String> { provider.featureNames }

    public var debugDescription: String {
        let features = featureNames.compactMap { featureName -> String? in
            guard let multiArray = provider.featureValue(for: featureName)?.multiArrayValue else {
                return nil
            }
            return "\(featureName): \(multiArray.shape)"
        }.joined(separator: ", ")
        return "[\(type(of: self)): chunkIndex=\(chunkIndex), features=\(features)]"
    }

    var speakerActivity: MLMultiArray? {
        provider.featureValue(for: "speaker_activity")?.multiArrayValue
    }

    var overlappingSpeakerActivity: MLMultiArray? {
        provider.featureValue(for: "overlapped_speaker_activity")?.multiArrayValue
    }

    var speakerIDs: MLMultiArray? {
        provider.featureValue(for: "speaker_ids")?.multiArrayValue
    }

    var slidingWindowWaveform: MLMultiArray? {
        provider.featureValue(for: "sliding_window_waveform")?.multiArrayValue
    }

    var windowsCount: Int {
        guard let slidingWindowWaveform, slidingWindowWaveform.shape.count > 0 else { return 0 }
        return slidingWindowWaveform.shape[0].intValue
    }

    var secondsPerWindow: Float {
        guard let slidingWindowWaveform, slidingWindowWaveform.shape.count > 2 else { return 0 }
        return slidingWindowWaveform.shape[2].floatValue / audioSampleRate
    }

    public init(features: MLFeatureProvider, chunkIndex: Int, audioChunk: MLMultiArray, chunkStride: Int, waveformLength: Float, modelSampleRate: Float, audioSampleRate: Float) {
        self.provider = features
        self.chunkIndex = chunkIndex
        self.audioChunk = audioChunk
        self.chunkStride = chunkStride
        self.waveformLength = waveformLength
        self.modelSampleRate = modelSampleRate
        self.audioSampleRate = audioSampleRate
    }

    public convenience init() {
        self.init(features: NoOpMLFeatureProvider(), chunkIndex: -1, audioChunk: MLMultiArray(), chunkStride: 0, waveformLength: 0, modelSampleRate: 0, audioSampleRate: 0)
    }

    public func featureValue(for featureName: String) -> MLFeatureValue? {
        provider.featureValue(for: featureName)
    }

}

fileprivate class NoOpMLFeatureProvider: MLFeatureProvider {
    var featureNames: Set<String> { [] }

    func featureValue(for name: String) -> MLFeatureValue? {
        nil
    }
}

