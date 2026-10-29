import Foundation
import AVFoundation
import LocalScribeCore

/// Owned and called sequentially by the worker, never shared across actors/tasks.
/// Implementations check cancellation around each SDK call and between windows.
/// A streaming engine will need a separate session protocol (push/flush/finalize).
protocol ASREngine: AnyObject {
    var capabilities: ASRCapabilities { get }
    func recognize(_ request: ASRRequest) async throws -> ASRResult
}

/// Both offline and closed-fragment paths resolve the run's pinned profile here.
/// Injection replaces only model loading in tests; selection/compatibility stay real.
struct ASREngineFactory: Sendable {
    typealias Loader = @Sendable (RunInfo, URL, ASRMetricsRecorder?, @escaping @Sendable (String) -> Void) async throws -> any ASREngine
    var loadWhisper: Loader = { info, models, metrics, warning in
        try await WhisperASREngine(info: info, models: models, metrics: metrics, warning: warning)
    }

    typealias PinnedLoader = @Sendable (ModelCatalog, URL, ASRMetricsRecorder?, @escaping @Sendable (String) -> Void) async throws -> any ASREngine
    var loadQwen: PinnedLoader = { pinned, root, metrics, warning in
        guard let profile = pinned.models.first(where: { $0.purpose == .asr }),
              let tokenizer = pinned.models.first(where: { $0.purpose == .tokenizer }),
              let aligner = pinned.models.first(where: { $0.id == profile.alignerID }),
              profile.asrPolicy == QwenASREngine.policyID, profile.tokenizerID == tokenizer.id else {
            throw ScribeError.message("Несовместимый комплект или настройки Qwen")
        }
        let tokenizerFiles: Set<String> = ["vocab.json", "merges.txt", "tokenizer_config.json"]
        try PinnedASRFiles.validate(profile, at: root, requiring: ["config.json", "model.safetensors"])
        try PinnedASRFiles.validate(tokenizer, at: root, requiring: tokenizerFiles)
        try PinnedASRFiles.validate(aligner, at: root, requiring: tokenizerFiles.union(["config.json", "model.safetensors"]))
        return try QwenASREngine(asr: root.appendingPathComponent(profile.id),
            tokenizer: root.appendingPathComponent(tokenizer.id), aligner: root.appendingPathComponent(aligner.id), metrics: metrics, warning: warning)
    }

    var loadVibeVoice: PinnedLoader = { pinned, root, metrics, _ in
        guard let profile = pinned.models.first(where: { $0.purpose == .asr }),
              let tokenizer = pinned.models.first(where: { $0.purpose == .tokenizer }),
              profile.asrPolicy == VibeVoiceASREngine.policyID, profile.tokenizerID == tokenizer.id, profile.alignerID == nil else {
            throw ScribeError.message("Несовместимый комплект VibeVoice-ASR")
        }
        let weights = profile.files.filter { $0.localPath.hasSuffix(".safetensors") }.map(\.localPath)
        guard !weights.isEmpty else { throw ScribeError.message("Отсутствуют закреплённые веса VibeVoice") }
        try PinnedASRFiles.validate(profile, at: root, requiring: Set(weights).union(["config.json"]))
        try PinnedASRFiles.validate(tokenizer, at: root, requiring: ["tokenizer.json", "tokenizer_config.json"])
        let started = ProcessInfo.processInfo.systemUptime
        defer { metrics?.modelLoaded(seconds: ProcessInfo.processInfo.systemUptime - started) }
        metrics?.backend("vibevoice-asr", policy: VibeVoiceASREngine.policyID)
        return try VibeVoiceASREngine(model: root.appendingPathComponent(profile.id),
            tokenizer: root.appendingPathComponent(tokenizer.id), weightFiles: weights)
    }

    func make(info: RunInfo, catalog: ModelCatalog, models: URL, metrics: ASRMetricsRecorder?,
              warning: @escaping @Sendable (String) -> Void) async throws -> SpeechRecognizer {
        try Task.checkCancellation()
        let pinned = try catalog.pinned(to: info)
        guard let profile = pinned.models.first(where: { $0.purpose == .asr }) else {
            throw ScribeError.message("Модель распознавания отсутствует в задании")
        }
        let engine: any ASREngine
        switch profile.resolvedASRBackend {
        case "whisper": engine = try await loadWhisper(info, models, metrics, warning)
        case "qwen3": engine = try await loadQwen(pinned, models, metrics, warning)
        case "vibevoice-asr": engine = try await loadVibeVoice(pinned, models, metrics, warning)
        default: throw ScribeError.message("Движок выбранной модели распознавания не поддерживается")
        }
        try Task.checkCancellation()
        return SpeechRecognizer(engine: engine)
    }
}

/// Both native adapters consume only the normalized pipeline audio contract.
enum ASRAudioInput {
    static func requireFormat(_ url: URL) throws {
        let audio = try AVAudioFile(forReading: url)
        guard audio.processingFormat.sampleRate == 16000, audio.processingFormat.channelCount == 1 else {
            throw ScribeError.message("Распознавание требует нормализованный mono PCM 16 кГц")
        }
    }
}

/// Every path read by a native SDK must itself be present in the frozen catalog.
/// Extra undeclared files on disk cannot fill a missing required component.
enum PinnedASRFiles {
    static func validate(_ profile: ModelProfile, at root: URL, requiring names: Set<String>) throws {
        guard names.isSubset(of: Set(profile.files.map(\.localPath))) else {
            throw ScribeError.message("Закреплённый комплект ASR не содержит обязательные конфигурации, веса или токенизатор")
        }
        try Task.checkCancellation()
        try profile.validate(at: root)
    }
}
