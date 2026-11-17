import CoreML
import WhisperKit

/// WhisperKit strips the previous-text prompt from decoded token IDs, but its
/// cross-attention rows are still indexed by the full decoder position.
final class WhisperDictionarySegmentSeeker: SegmentSeeking {
    private let base = SegmentSeeker()
    private(set) var exhaustedContext = false

    func beginCall() { exhaustedContext = false }

    func findSeekPointAndSegments(decodingResult: DecodingResult, options: DecodingOptions, allSegmentsCount: Int,
                                  currentSeek seek: Int, segmentSize: Int, sampleRate: Int, timeToken: Int,
                                  specialToken: Int, tokenizer: WhisperTokenizer) -> (Int, [TranscriptionSegment]?) {
        if let prompt = options.promptTokens, !prompt.isEmpty,
           (decodingResult.timings?.totalDecodingLoops ?? 0) >= Double(Constants.maxTokenContext - 1) {
            exhaustedContext = true
            return (seek + segmentSize, nil)
        }
        return base.findSeekPointAndSegments(decodingResult: decodingResult, options: options,
            allSegmentsCount: allSegmentsCount, currentSeek: seek, segmentSize: segmentSize, sampleRate: sampleRate,
            timeToken: timeToken, specialToken: specialToken, tokenizer: tokenizer)
    }

    func addWordTimestamps(segments: [TranscriptionSegment], alignmentWeights: MLMultiArray, tokenizer: WhisperTokenizer,
                           seek: Int, segmentSize: Int, prependPunctuations: String, appendPunctuations: String,
                           lastSpeechTimestamp: Float, options: DecodingOptions,
                           timings: TranscriptionTimings) throws -> [TranscriptionSegment]? {
        // The engine discards a capped hinted decode and replays the same PCM.
        if exhaustedContext { return segments }
        let promptCount = options.promptTokens?.count ?? 0
        let skippedRows = promptCount == 0 ? 0 : promptCount + 1 // <|startofprev|>
        let weights = try Self.alignmentRows(alignmentWeights, skipping: skippedRows)
        return try base.addWordTimestamps(segments: segments, alignmentWeights: weights, tokenizer: tokenizer,
            seek: seek, segmentSize: segmentSize, prependPunctuations: prependPunctuations,
            appendPunctuations: appendPunctuations, lastSpeechTimestamp: lastSpeechTimestamp, options: options, timings: timings)
    }

    static func alignmentRows(_ weights: MLMultiArray, skipping rows: Int) throws -> MLMultiArray {
        guard rows > 0 else { return weights }
        let shape = weights.shape.map(\.intValue)
        guard weights.dataType == .float16, shape.count == 2, rows < shape[0] else {
            throw WhisperError.segmentingFailed("Invalid Whisper alignment weights")
        }
        let rowCount = shape[0] - rows
        let result = try MLMultiArray(shape: [NSNumber(value: rowCount), weights.shape[1]], dataType: .float16)
        let elementSize = MemoryLayout<Float16>.stride
        // The SDK allocates an IOSurface whose rows can be padded. Its
        // segment seeker indexes tight rows, so pack them while shifting.
        try weights.withUnsafeMutableBytes { source, sourceStrides in
            try result.withUnsafeMutableBytes { destination, destinationStrides in
                guard let sourceAddress = source.baseAddress, let destinationAddress = destination.baseAddress,
                      sourceStrides[1] == 1, destinationStrides == [shape[1], 1] else {
                    throw WhisperError.segmentingFailed("Unexpected Whisper alignment strides")
                }
                for row in 0..<rowCount {
                    let from = sourceAddress.advanced(by: (row + rows) * sourceStrides[0] * elementSize)
                    let to = destinationAddress.advanced(by: row * destinationStrides[0] * elementSize)
                    to.copyMemory(from: from, byteCount: shape[1] * elementSize)
                }
            }
        }
        return result
    }
}
