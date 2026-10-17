import Foundation

/// AVAudioEngine notifications also describe output changes and delayed startup
/// changes. Only a change to the pinned input invalidates the captured PCM.
public struct CaptureInputConfiguration: Equatable, Sendable {
    public var deviceID: UInt32
    public var sampleRate: Double
    public var channels: UInt32
    public var formatID: UInt32
    public var formatFlags: UInt32
    public init(deviceID: UInt32, sampleRate: Double, channels: UInt32, formatID: UInt32, formatFlags: UInt32) {
        self.deviceID = deviceID; self.sampleRate = sampleRate; self.channels = channels
        self.formatID = formatID; self.formatFlags = formatFlags
    }
}
public enum CaptureConfigurationAction: Equatable, Sendable {
    case keepRecording, restartEngine, inputUnavailable, inputChanged
    public static func evaluate(expected: CaptureInputConfiguration, current: CaptureInputConfiguration?, engineRunning: Bool) -> Self {
        guard let current, current.sampleRate > 0, current.channels > 0 else { return .inputUnavailable }
        guard current == expected else { return .inputChanged }
        return engineRunning ? .keepRecording : .restartEngine
    }
}
