import AVFoundation
import CoreAudio
import CoreMedia
import LocalScribeCore
import os
import Speech

enum LiveCaptionLanguage: String, CaseIterable {
    case russian, english, mixed

    static var interfaceLanguage: Self { L10n.locale.identifier == "en" ? .english : .russian }

    var locale: Locale? {
        switch self {
        case .russian: return Locale(identifier: "ru-RU")
        case .english: return Locale(identifier: "en-US")
        case .mixed: return nil
        }
    }

    var title: String {
        switch self {
        case .russian: return L10n.text("Русский")
        case .english: return L10n.text("Английский")
        case .mixed: return L10n.text("Русский + английский")
        }
    }
}

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

/// Dictation can revoke its last hypothesis and fail with RecogFailed when
/// finalized without a replacement. Accept that empty result only at EOF.
final class DictationCaptionFinalization: Sendable {
    private struct State {
        var finishing = false
        var draftRange: CMTimeRange?
        var hasPendingText = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func observe(range: CMTimeRange, hasText: Bool, isFinal: Bool) {
        state.withLock { state in
            if !isFinal {
                state.draftRange = range
                state.hasPendingText = hasText
            } else if let draft = state.draftRange, draft.end <= range.end {
                state.draftRange = nil
                state.hasPendingText = false
            }
        }
    }

    func allowsEmptyResult(_ error: Error) -> Bool {
        let failure = error as NSError
        return failure.domain == SFSpeechErrorDomain
            && failure.code == SFSpeechError.Code.internalServiceError.rawValue
            && failure.localizedDescription == "RecogFailed"
            && state.withLock { $0.finishing && !$0.hasPendingText }
    }

    func finish(_ finalize: @Sendable () async throws -> Void) async throws {
        state.withLock { $0.finishing = true }
        do { try await finalize() }
        catch { if !allowsEmptyResult(error) { throw error } }
    }
}

enum LiveCaptionRecognition {
    enum Failure: Error { case languageUnavailable }
    typealias Session = @Sendable (
        AsyncStream<LiveCaptionPCM>, @escaping @Sendable () async -> Void,
        @escaping @Sendable (LiveCaptionUpdate) async -> Void
    ) async throws -> Void
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
            try await analyze(with: transcriber, text: { $0.text }, input: input, ready: ready,
                              dictationFinalization: DictationCaptionFinalization(), receive: receive)
        } else {
            throw Failure.languageUnavailable
        }
    }

    static let recognizeMixed: Session = { input, ready, receive in
        guard let ru = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: "ru-RU")),
              SpeechTranscriber.isAvailable,
              let en = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
        else { throw Failure.languageUnavailable }
        let russian = DictationTranscriber(locale: ru, contentHints: [], transcriptionOptions: [.punctuation],
            reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        let english = SpeechTranscriber(locale: en, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        let preferred: BilingualCaptionLanguage = LiveCaptionLanguage.interfaceLanguage == .english ? .english : .russian
        let dictationFinalization = DictationCaptionFinalization()
        try await analyze(modules: [russian, english], input: input, ready: ready, finalizeAtPauses: true,
                          dictationFinalization: dictationFinalization) {
            try await BilingualCaptionResults.collect(russian: russian, english: english, preferred: preferred,
                                                      dictationFinalization: dictationFinalization, receive: receive)
        }
    }

    private static func analyze<Module: SpeechModule>(
        with module: Module, text: @escaping @Sendable (Module.Result) -> AttributedString,
        input: AsyncStream<LiveCaptionPCM>, ready: @Sendable () async -> Void,
        dictationFinalization: DictationCaptionFinalization? = nil,
        receive: @escaping @Sendable (LiveCaptionUpdate) async -> Void
    ) async throws {
        try await analyze(modules: [module], input: input, ready: ready, dictationFinalization: dictationFinalization) {
            do {
                for try await result in module.results {
                    try Task.checkCancellation()
                    let recognized = text(result)
                    dictationFinalization?.observe(range: result.range, hasText: !recognized.characters.isEmpty,
                                                    isFinal: result.isFinal)
                    await receive(LiveCaptionUpdate(range: result.range, finalizedThrough: result.resultsFinalizationTime,
                                                    text: String(recognized.characters)))
                }
            } catch {
                if dictationFinalization?.allowsEmptyResult(error) != true { throw error }
            }
        }
    }

    private static func analyze(
        modules: [any SpeechModule], input: AsyncStream<LiveCaptionPCM>, ready: @Sendable () async -> Void,
        finalizeAtPauses: Bool = false,
        dictationFinalization: DictationCaptionFinalization? = nil,
        collect: @Sendable @escaping () async throws -> Void
    ) async throws {
        if await AssetInventory.status(forModules: modules) != .installed,
           let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
            try await request.downloadAndInstall()
        }
        try Task.checkCancellation()
        guard let natural = CapturePCM16Sink.format,
              let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules, considering: natural)
        else { throw Failure.languageUnavailable }
        // Keep explicit pause finalization on SpeechTranscriber. Dictation can
        // abort after an empty hypothesis, so give each its own session.
        let analyzers = modules.map {
            SpeechAnalyzer(modules: [$0], options: .init(priority: .utility, modelRetention: .whileInUse))
        }
        try await withTaskCancellationHandler {
            do {
                for analyzer in analyzers { try await analyzer.prepareToAnalyze(in: format) }
                try Task.checkCancellation()
                await ready()
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        let last = try await feed(input, to: analyzers, natural: natural, format: format,
                                                  finalizeAtPauses: finalizeAtPauses)
                        try Task.checkCancellation()
                        if let last {
                            for (index, analyzer) in analyzers.enumerated() {
                                if index == 0, let dictationFinalization {
                                    try await dictationFinalization.finish {
                                        try await analyzer.finalizeAndFinish(through: last)
                                    }
                                } else {
                                    try await analyzer.finalizeAndFinish(through: last)
                                }
                            }
                        } else {
                            await cancel(analyzers)
                        }
                    }
                    group.addTask(operation: collect)
                    do {
                        while try await group.next() != nil {}
                    } catch {
                        group.cancelAll()
                        await cancel(analyzers)
                        // Speech can cancel one task while another reports the underlying failure.
                        if error is CancellationError, !Task.isCancelled {
                            while let result = await group.nextResult() {
                                if case .failure(let cause) = result, !(cause is CancellationError) { throw cause }
                            }
                        }
                        throw error
                    }
                }
            } catch {
                await cancel(analyzers)
                throw error
            }
        } onCancel: {
            Task { await cancel(analyzers) }
        }
    }

    private static func feed(
        _ input: AsyncStream<LiveCaptionPCM>, to analyzers: [SpeechAnalyzer], natural: AVAudioFormat,
        format: AVAudioFormat, finalizeAtPauses: Bool
    ) async throws -> CMTime? {
        let converter = format == natural ? nil : try LiveCaptionAudioConverter(from: natural, to: format)
        let pauses = finalizeAtPauses ? LiveCaptionPauses() : nil
        // In mixed mode the last analyzer owns English. Russian Dictation
        // controls its own utterance boundaries throughout the live stream.
        async let finalized: Void = finalizePauses(pauses?.times, using: analyzers[analyzers.count - 1])
        do {
            var last: CMTime?
            if analyzers.count == 1 {
                last = try await analyzers[0].analyzeSequence(input.map { pcm in
                    try converter?.convert(pcm.buffer) ?? AnalyzerInput(buffer: pcm.buffer)
                })
            } else {
                for await pcm in input {
                    try Task.checkCancellation()
                    pauses?.consume(pcm.buffer)
                    let converted = try converter?.convert(pcm.buffer) ?? AnalyzerInput(buffer: pcm.buffer)
                    last = try await feedBuffer(converted, to: analyzers)
                }
            }
            pauses?.finish()
            try await finalized
            return last
        } catch {
            pauses?.finish()
            throw error
        }
    }

    /// Both analyzers consume each buffer before pulling another from the
    /// bounded capture stream. Neither language can drop a different interval.
    private static func feedBuffer(_ input: AnalyzerInput, to analyzers: [SpeechAnalyzer]) async throws -> CMTime? {
        try await withThrowingTaskGroup(of: CMTime?.self) { group in
            for analyzer in analyzers {
                group.addTask {
                    let chunk = AsyncStream<AnalyzerInput> { output in
                        output.yield(input)
                        output.finish()
                    }
                    return try await analyzer.analyzeSequence(chunk)
                }
            }
            var last: CMTime?
            for try await time in group { last = time }
            return last
        }
    }

    private static func cancel(_ analyzers: [SpeechAnalyzer]) async {
        for analyzer in analyzers { await analyzer.cancelAndFinishNow() }
    }

    private static func finalizePauses(_ times: AsyncStream<CMTime>?, using analyzer: SpeechAnalyzer) async throws {
        guard let times else { return }
        for await time in times { try await analyzer.finalize(through: time) }
    }
}

/// The input iterator is the only caller of consume. Only the async stream
/// crosses over to the task that asks the analyzer to finalize at a pause.
private final class LiveCaptionPauses: @unchecked Sendable {
    let times: AsyncStream<CMTime>
    private let output: AsyncStream<CMTime>.Continuation
    private let blockFrames = 320
    private let pauseBlocks = 20
    private let sampleRate: CMTimeScale = 16_000
    private var frames: Int64 = 0
    private var energy = 0.0
    private var quietBlocks = 0
    private var heardSpeech = false

    init() {
        (times, output) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    func consume(_ buffer: AVAudioPCMBuffer) {
        guard let pcm = buffer.int16ChannelData?[0] else { return }
        let quietEnergy = Double(blockFrames) * pow(0.003 * 32_768, 2)
        for index in 0..<Int(buffer.frameLength) {
            let sample = Double(pcm[index])
            energy += sample * sample
            frames += 1
            guard frames.isMultiple(of: Int64(blockFrames)) else { continue }
            if energy >= quietEnergy {
                quietBlocks = 0
                heardSpeech = true
            } else if heardSpeech {
                quietBlocks += 1
                if quietBlocks >= pauseBlocks {
                    output.yield(CMTime(value: frames - 1, timescale: sampleRate))
                    heardSpeech = false
                }
            }
            energy = 0
        }
    }

    func finish() { output.finish() }
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
