import Foundation
import LocalScribeCore
@testable import LocalScribeWorker

extension WhisperASREngine {
    /// Run all existing fixed-response adapter regressions through the shared boundary.
    func recognize(wave: URL, coreStart: Int, coreEnd: Int, durationMs: Int, originMs: Int = 0) async throws -> [Segment] {
        try await SpeechRecognizer(engine: self).recognize(ASRRequest(audioURL: wave, originMs: originMs,
            availableEndMs: durationMs, coreRange: coreStart..<coreEnd,
            mode: originMs == 0 ? .offline : .closedFragments)).segments
    }
}
