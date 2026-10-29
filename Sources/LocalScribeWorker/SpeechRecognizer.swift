import Foundation
import LocalScribeCore

/// SDK-independent boundary used by both pipeline paths. Cancellation is checked
/// again here so even an engine returning normally after cancellation cannot commit.
final class SpeechRecognizer {
    private let engine: any ASREngine
    var capabilities: ASRCapabilities { engine.capabilities }
    init(engine: any ASREngine) { self.engine = engine }

    func recognize(_ request: ASRRequest) async throws -> ASRResult {
        try Task.checkCancellation()
        guard capabilities.inputModes.contains(request.mode) else {
            throw ScribeError.message("Движок не поддерживает этот режим распознавания")
        }
        let result = try await engine.recognize(request)
        try Task.checkCancellation()
        return result
    }
}
