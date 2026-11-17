import ArgmaxCore
import Foundation
import LocalScribeCore
import WhisperKit

public struct WhisperDictionaryTokenizer: Sendable {
    private let tokenizer: TokenizerWrapper

    public init(profile: ModelProfile, models: URL) async throws {
        try profile.validate(at: models)
        tokenizer = try await AutoTokenizerWrapper.from(modelFolder: models.appendingPathComponent(profile.id))
    }

    public func promptTokens(for terms: [String]) throws -> [Int]? {
        try WhisperDictionary.promptTokens(for: terms, encode: { tokenizer.encode(text: $0) },
            specialTokenBegin: tokenizer.convertTokenToId("<|endoftext|>") ?? 50257)
    }
}

public enum WhisperDictionary {
    // TextDecoder in the pinned SDK silently trims prompts at this boundary.
    public static let promptTokenBudget = Constants.maxTokenContext / 2 - 1

    public static func promptTokens(for terms: [String]?, encode: (String) -> [Int], specialTokenBegin: Int) throws -> [Int]? {
        guard let terms, !terms.isEmpty else { return nil }
        let tokens = encode(terms.joined(separator: ", ")).filter { $0 < specialTokenBegin }
        guard tokens.count <= promptTokenBudget else {
            throw ScribeError.message("Словарь распознавания не помещается в контекст модели Whisper: \(tokens.count) токенов при лимите \(promptTokenBudget). Сократите список в настройках и выберите «Обработать заново» для существующего задания.")
        }
        return tokens.isEmpty ? nil : tokens
    }
}
