import Foundation

/// Closed fragments are finite batch inputs, not a stateful streaming session.
public enum ASRInputMode: Sendable, Hashable { case offline, closedFragments }

public struct ASRCapabilities: Sendable, Equatable {
    public enum WordTimings: Sendable { case available, unavailable }
    public let inputModes: Set<ASRInputMode>
    public let wordTimings: WordTimings
    public init(inputModes: Set<ASRInputMode>, wordTimings: WordTimings) {
        self.inputModes = inputModes; self.wordTimings = wordTimings
    }
}

/// Normalized mono 16 kHz audio. File time zero is originMs on the source timeline.
/// Only [originMs, availableEndMs) may be read, even if the file contains more audio.
/// coreRange owns the returned speech; context may extend beyond it. Engines choose
/// their own windows, context and ownership rule, without shifting source times.
public struct ASRRequest: Sendable {
    public let audioURL: URL
    public let originMs: Int
    public let availableEndMs: Int
    public let coreRange: Range<Int>
    public let mode: ASRInputMode

    public init(audioURL: URL, originMs: Int = 0, availableEndMs: Int,
                coreRange: Range<Int>, mode: ASRInputMode) throws {
        guard audioURL.isFileURL, originMs >= 0, availableEndMs <= Manifest.maximumDurationMs,
              originMs <= coreRange.lowerBound, !coreRange.isEmpty,
              coreRange.upperBound <= availableEndMs else {
            throw ScribeError.message("Некорректные границы входа распознавания")
        }
        self.audioURL = audioURL; self.originMs = originMs; self.availableEndMs = availableEndMs
        self.coreRange = coreRange; self.mode = mode
    }
}

/// Source-time segments and optional word timings. IDs become stable at checkpoint
/// publication. No SDK confidence scores or invented substitutes cross this boundary.
public struct ASRResult: Sendable {
    public var segments: [Segment]
    public init(segments: [Segment]) { self.segments = segments }
}

/// Existing persistence cadence, NOT an engine's maximum inference window.
/// Changing live1 geometry requires versioned checkpoint readers and a pipeline bump.
public enum ASRCheckpointLayout {
    public static let offlinePartMs = 300_000
    public static let livePartMs = 30_000
    public static let liveContextMs = 1000
}
