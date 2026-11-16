import AVFoundation
import CoreAudio
import CoreMedia
import os
import Speech

/// A private copy transferred once from the writer to the analyzer.
struct LiveCaptionPCM: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

/// A bounded tap of the same PCM that is written to the recording.
/// The capture writer copies only frames at or after the user's start action.
final class LiveCaptionAudio: Sendable {
    let stream: AsyncStream<LiveCaptionPCM>
    private let continuation: AsyncStream<LiveCaptionPCM>.Continuation
    private let closed = OSAllocatedUnfairLock(initialState: false)
    private let startHostTime: UInt64

    init(startHostTime: UInt64 = AudioGetCurrentHostTime()) {
        self.startHostTime = startHostTime
        (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(192))
    }

    func append(_ buffer: AVAudioPCMBuffer, startingAt frame: Int64, originHostTime: UInt64) {
        guard !closed.withLock({ $0 }) else { return }
        let minimumFrame = startHostTime > originHostTime
            ? Int64(ceil(AVAudioTime.seconds(forHostTime: startHostTime - originHostTime) * buffer.format.sampleRate))
            : 0
        let offset = Int(max(0, minimumFrame - frame))
        let count = Int(buffer.frameLength) - offset
        guard count > 0, let samples = buffer.int16ChannelData?[0],
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(count)),
              let target = copy.int16ChannelData?[0] else { return }
        copy.frameLength = AVAudioFrameCount(count)
        target.update(from: samples.advanced(by: offset), count: count)
        continuation.yield(LiveCaptionPCM(buffer: copy))
    }

    func finish() {
        closed.withLock { $0 = true }
        continuation.finish()
    }
}

struct LiveCaptionUpdate: Sendable {
    let range: CMTimeRange
    let finalizedThrough: CMTime
    let text: String
}

enum LiveCaptionRecognition {
    enum Failure: Error { case languageUnavailable }
    typealias Recognizer = @Sendable (
        Locale, AsyncStream<LiveCaptionPCM>, @Sendable () async -> Void,
        @escaping @Sendable (LiveCaptionUpdate) async -> Void
    ) async throws -> Void

    static let recognize: Recognizer = { locale, input, ready, receive in
        if SpeechTranscriber.isAvailable,
           let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            let transcriber = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
            try await analyze(with: transcriber, text: { $0.text }, input: input, ready: ready, receive: receive)
        } else if let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            let transcriber = DictationTranscriber(locale: supported, contentHints: [], transcriptionOptions: [.punctuation],
                                                   reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: [])
            try await analyze(with: transcriber, text: { $0.text }, input: input, ready: ready, receive: receive)
        } else {
            throw Failure.languageUnavailable
        }
    }

    private static func analyze<Module: SpeechModule>(
        with module: Module, text: @escaping @Sendable (Module.Result) -> AttributedString,
        input: AsyncStream<LiveCaptionPCM>, ready: @Sendable () async -> Void,
        receive: @escaping @Sendable (LiveCaptionUpdate) async -> Void
    ) async throws {
        let modules: [any SpeechModule] = [module]
        if await AssetInventory.status(forModules: modules) != .installed,
           let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
            try await request.downloadAndInstall()
        }
        try Task.checkCancellation()
        guard let natural = CapturePCM16Sink.format,
              let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules, considering: natural)
        else { throw Failure.languageUnavailable }
        let analyzer = SpeechAnalyzer(modules: modules, options: .init(priority: .utility, modelRetention: .whileInUse))
        try await withTaskCancellationHandler {
            do {
                try await analyzer.prepareToAnalyze(in: format)
                try Task.checkCancellation()
                await ready()
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        let last: CMTime?
                        if format == natural {
                            last = try await analyzer.analyzeSequence(input.map { AnalyzerInput(buffer: $0.buffer) })
                        } else {
                            let converter = try LiveCaptionAudioConverter(from: natural, to: format)
                            last = try await analyzer.analyzeSequence(input.map { try converter.convert($0.buffer) })
                        }
                        if let last { try await analyzer.finalizeAndFinish(through: last) }
                        else { await analyzer.cancelAndFinishNow() }
                    }
                    group.addTask {
                        for try await result in module.results {
                            try Task.checkCancellation()
                            await receive(LiveCaptionUpdate(range: result.range, finalizedThrough: result.resultsFinalizationTime,
                                                            text: String(text(result).characters)))
                        }
                    }
                    do {
                        while try await group.next() != nil {}
                    } catch {
                        group.cancelAll()
                        await analyzer.cancelAndFinishNow()
                        throw error
                    }
                }
            } catch {
                await analyzer.cancelAndFinishNow()
                throw error
            }
        } onCancel: {
            Task { await analyzer.cancelAndFinishNow() }
        }
    }
}

/// Used on the analyzer's single input consumer when the system model needs
/// a format other than the capture writer's mono 16 kHz PCM.
private final class LiveCaptionAudioConverter: @unchecked Sendable {
    private let converter: AVAudioConverter

    init(from: AVAudioFormat, to: AVAudioFormat) throws {
        guard let converter = AVAudioConverter(from: from, to: to) else {
            throw LiveCaptionRecognition.Failure.languageUnavailable
        }
        converter.primeMethod = .none
        self.converter = converter
    }

    func convert(_ source: AVAudioPCMBuffer) throws -> AnalyzerInput {
        let ratio = converter.outputFormat.sampleRate / source.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(source.frameLength) * ratio) + 32)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            throw LiveCaptionRecognition.Failure.languageUnavailable
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: buffer, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return source
        }
        guard status != .error, buffer.frameLength > 0 else {
            if let error { throw error }
            throw LiveCaptionRecognition.Failure.languageUnavailable
        }
        return AnalyzerInput(buffer: buffer)
    }
}
