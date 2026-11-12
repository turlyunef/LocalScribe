// Copyright (c) 2025, Prince Canuma and contributors (https://github.com/Blaizzy/mlx-audio)

import Foundation
import MLX
import MLXLMCommon
import MLXNN
import Tokenizers
import Hub

final class VibeVoiceConnector: Module {
    @ModuleInfo var fc1: Linear
    let norm: RMSNorm
    @ModuleInfo var fc2: Linear
    init(_ input: Int, _ output: Int) {
        _fc1.wrappedValue = Linear(input, output)
        norm = RMSNorm(dimensions: output, eps: 1e-6)
        _fc2.wrappedValue = Linear(output, output)
    }
    func callAsFunction(_ x: MLXArray) -> MLXArray { fc2(norm(fc1(x))) }
}

/// VibeVoice long-form and streaming speech recognition.
public final class VibeVoiceASRModel: Module {
    public let config: VibeVoiceConfig
    @ModuleInfo(key: "acoustic_tokenizer") var acousticTokenizer: VibeVoiceTokenizerEncoder
    @ModuleInfo(key: "semantic_tokenizer") var semanticTokenizer: VibeVoiceTokenizerEncoder
    @ModuleInfo(key: "acoustic_connector") var acousticConnector: VibeVoiceConnector
    @ModuleInfo(key: "semantic_connector") var semanticConnector: VibeVoiceConnector
    @ModuleInfo(key: "language_model") public var languageModel: Qwen2Model
    var tokenizer: Tokenizer?
    var speechStartId = 151646
    var speechEndId = 151647
    var speechPadId = 151648
    public var sampleRate: Int { config.sampleRate }
    public init(_ config: VibeVoiceConfig) {
        self.config = config
        _acousticTokenizer.wrappedValue = VibeVoiceTokenizerEncoder(config.acousticTokenizerConfig)
        _semanticTokenizer.wrappedValue = VibeVoiceTokenizerEncoder(config.semanticTokenizerConfig)
        _acousticConnector.wrappedValue = VibeVoiceConnector(
            config.acousticVaeDim, config.decoderConfig.hiddenSize)
        _semanticConnector.wrappedValue = VibeVoiceConnector(
            config.semanticVaeDim, config.decoderConfig.hiddenSize)
        _languageModel.wrappedValue = Qwen2Model(config.decoderConfig)
    }
    func prepareAudio(_ audio: MLXArray) throws -> MLXArray {
        guard audio.size <= 300 * sampleRate else { throw VibeVoiceError.contextLimit }
        guard audio.size > 0, audio.ndim == 1 || (audio.ndim == 2 && audio.dim(0) > 1) else {
            throw VibeVoiceError.configuration("Expected nonempty mono or time-major audio")
        }
        var mono = (audio.ndim == 2 ? audio.mean(axis: -1) : audio).asType(.float32)
        if config.normalizeAudio {
            mono = mono * (pow(Float(10), -25 / 20) / (sqrt(mean(mono * mono)) + 1e-6))
            mono = mono / maximum(abs(mono).max() + 1e-6, MLXArray(Float(1)))
        }
        return mono.expandedDimensions(axis: 0)
    }
    /// Encode mono 24 kHz audio, shaped [samples] or [1, samples], without loudness normalization.
    public func encodeSpeech(_ audio: MLXArray) -> MLXArray {
        let waveform = (audio.ndim == 1 ? audio.expandedDimensions(axis: 0) : audio).asType(
            .float32)
        precondition(waveform.ndim == 2 && waveform.dim(0) == 1 && waveform.dim(1) > 0)
        let acoustic = acousticConnector(acousticTokenizer(waveform))
        eval(acoustic)
        let semantic = semanticConnector(semanticTokenizer(waveform))
        let features = acoustic + semantic
        eval(features)
        return features
    }
    static func context(_ context: String?, hotwords: [String]) -> String? {
        let terms = hotwords.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter {
            !$0.isEmpty
        }
        guard !terms.isEmpty else { return context }
        let joined = terms.joined(separator: ", ")
        return context.flatMap { $0.isEmpty ? nil : $0 }.map { $0 + "\n" + joined } ?? joined
    }
    func buildPrompt(frames: Int, duration: Double, context: String?) -> MLXArray {
        guard let tokenizer else { preconditionFailure("VibeVoice tokenizer is not loaded") }
        let system =
            "You are a helpful assistant that transcribes audio input into text output in JSON format."
        let keys = "Start time, End time, Speaker ID, Content"
        let length = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), duration)
        let info = context?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let suffix =
            info.isEmpty
            ? "This is a \(length) seconds audio, please transcribe it with these keys: " + keys
            : "This is a \(length) seconds audio, with extra info: \(info)\n\nPlease transcribe it with these keys: "
                + keys
        let prefix =
            "<|im_start|>system\n" + system + "<|im_end|>\n<|im_start|>user\n<|object_ref_start|>"
        let end = "<|object_ref_end|>\n" + suffix + "<|im_end|>\n<|im_start|>assistant\n"
        let tokens =
            tokenizer.encode(text: prefix, addSpecialTokens: false)
            + Array(repeating: speechPadId, count: frames)
            + tokenizer.encode(text: end, addSpecialTokens: false)
        return MLXArray(tokens.map(Int32.init)).expandedDimensions(axis: 0)
    }
    func mergeEmbeddings(_ ids: MLXArray, features: MLXArray) -> MLXArray {
        let text = languageModel.embedTokens(ids)
        let mask = ids .== speechPadId
        let indices = clip(
            cumsum(mask.asType(.int32), axis: 1) - 1, min: 0, max: features.dim(1) - 1)
        let speech = features.asType(text.dtype)[0][indices]
        return MLX.where(mask.expandedDimensions(axis: -1), speech, text)
    }
    /// One finite long-form checkpoint request. Failure to reach EOS is an error.
    public func generate(audio: MLXArray, maxTokens: Int = 8192) throws -> String {
        try Task.checkCancellation()
        guard let tokenizer, maxTokens > 0 else { throw VibeVoiceError.configuration("Missing tokenizer") }
        let waveform = try prepareAudio(audio)
        let features = encodeSpeech(waveform)
        try Task.checkCancellation()
        let ids = buildPrompt(frames: features.dim(1), duration: Double(waveform.dim(1)) / Double(sampleRate), context: nil)
        let embeddings = mergeEmbeddings(ids, features: features)
        let cache: [KVCache] = (0..<config.decoderConfig.hiddenLayers).map { _ in KVCacheSimple() }
        var offset = 0
        while embeddings.dim(1) - offset > 256 {
            try Task.checkCancellation()
            eval(languageModel(inputEmbeddings: embeddings[0..., offset..<(offset + 256), 0...], cache: cache), cache)
            offset += 256
        }
        var logits = languageModel(inputEmbeddings: embeddings[0..., offset..., 0...], cache: cache)
        eval(logits, cache)
        var stop: Set<Int> = [151643, 151645]
        if let eos = tokenizer.eosTokenId { stop.insert(eos) }
        var tokens: [Int] = []
        for _ in 0..<maxTokens {
            try Task.checkCancellation()
            let token = logits[0, -1, 0...].argMax().item(Int.self)
            if stop.contains(token) {
                try Task.checkCancellation()
                return tokenizer.decode(tokens: tokens, skipSpecialTokens: true)
            }
            tokens.append(token)
            logits = languageModel(MLXArray([Int32(token)]).reshaped(1, 1), cache: cache)
            eval(logits, cache)
        }
        throw VibeVoiceError.incompleteGeneration
    }

    public static func sanitize(weights: [String: MLXArray]) -> [String: MLXArray] {
        let original = weights.keys.contains { $0.hasPrefix("model.") }
        var result: [String: MLXArray] = [:]
        for (key, var value) in weights {
            let path = canonicalVibeVoicePath(key)
            if path.contains("acoustic_tokenizer.decoder") || path.contains("position_ids")
                || path.contains("fix_std") || path.contains("rotary_emb.inv_freq")
            {
                continue
            }
            if original && path.contains("conv") && path.hasSuffix("weight") && value.ndim == 3 {
                value = value.transposed(0, 2, 1)
            }
            result[path] = value
        }
        return result
    }
    public static func fromModelDirectory(_ directory: URL, tokenizerDirectory: URL, weightFiles: [String])
        throws -> VibeVoiceASRModel
    {
        let config = try JSONDecoder().decode(
            VibeVoiceConfig.self,
            from: Data(contentsOf: directory.appendingPathComponent("config.json")))
        try config.validate()
        guard config.chunkFrames == nil, config.lookaheadFrames == nil, config.sampleRate == 24000 else {
            throw VibeVoiceError.configuration("Only the long-form ASR checkpoint is supported")
        }
        let model = VibeVoiceASRModel(config)
        guard !weightFiles.isEmpty, weightFiles.allSatisfy({ !$0.contains("/") && !$0.contains("\\") && $0.hasSuffix(".safetensors") }) else { throw VibeVoiceError.configuration("Invalid weight names") }
        let files = weightFiles.map { directory.appendingPathComponent($0) }
        guard !files.isEmpty else {
            throw VibeVoiceError.configuration("No VibeVoice safetensors found")
        }
        var weights: [String: MLXArray] = [:]
        for file in files { weights.merge(try MLX.loadArrays(url: file)) { _, new in new } }
        weights = sanitize(weights: weights)
        if config.decoderConfig.tieWordEmbeddings {
            weights = weights.filter { !$0.key.hasPrefix("language_model.lm_head.") }
        }
        if let q = config.perLayerQuantization {
            quantize(model: model) { path, _ in
                weights[path + ".scales"] != nil ? q.quantization(layer: path)?.asTuple : nil
            }
        }
        try model.update(parameters: ModuleParameters.unflattened(weights), verify: .all)
        // LocalScribe: loading malformed tokenizer JSON must not crash the worker.
        guard let tokenizerConfig = try JSONSerialization.jsonObject(with: Data(contentsOf: tokenizerDirectory.appendingPathComponent("tokenizer_config.json"))) as? [NSString: Any],
              let tokenizerData = try JSONSerialization.jsonObject(with: Data(contentsOf: tokenizerDirectory.appendingPathComponent("tokenizer.json"))) as? [NSString: Any] else {
            throw VibeVoiceError.configuration("Invalid tokenizer JSON")
        }
        model.tokenizer = try AutoTokenizer.from(tokenizerConfig: Config(tokenizerConfig), tokenizerData: Config(tokenizerData))
        try model.prepareTokenizer()
        model.train(false)
        eval(model)
        return model
    }
    func prepareTokenizer() throws {
        guard let tokenizer,
            let start = tokenizer.convertTokenToId("<|object_ref_start|>"),
            let end = tokenizer.convertTokenToId("<|object_ref_end|>"),
            let pad = tokenizer.convertTokenToId("<|box_start|>")
        else { throw VibeVoiceError.configuration("VibeVoice speech tokens are missing") }
        speechStartId = start
        speechEndId = end
        speechPadId = pad
        guard config.chunkFrames == nil, config.lookaheadFrames == nil, config.sampleRate == 24000 else {
            throw VibeVoiceError.configuration("Only the long-form ASR checkpoint is supported")
        }
    }
}
