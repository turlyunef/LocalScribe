import Foundation
import LocalScribeCore
import MLXLMCommon

// Fixed categories keep diagnostics bounded even for a multi-hour meeting. Never
// store prompts, output, source IDs, model paths or SDK error descriptions here.
enum SummaryMetricPhase: String, Codable, Sendable {
    case overview, decisions, tasks, openQuestions, reduction
    case decisionEvidence, taskEvidence, decisionAmendment, taskAmendment
    case applyAmendment, questionResolution

    static func extraction(_ section: SummarySection?) -> Self {
        switch section {
        case .overview: return .overview
        case .decisions: return .decisions
        case .tasks: return .tasks
        case .openQuestions: return .openQuestions
        case nil: return .reduction
        }
    }
}

struct SummaryRequestMetrics: Codable {
    var requests = 0
    var completedRequests = 0
    var retries = 0
    var validationFailures = 0
    var checkpointHits = 0
    var inputTokens = 0
    var reservedOutputTokens = 0
    var outputTokens = 0
    var missingCompletionInfo = 0
    var stoppedAtEOS = 0
    var stoppedAtLimit = 0
    var cancelled = 0
    var errors = 0
    var preparationSeconds = 0.0
    var wallSeconds = 0.0
    var promptSeconds = 0.0
    var generationSeconds = 0.0
    var maximumRequestSeconds = 0.0

    mutating func start(inputTokens: Int, outputLimit: Int, attempt: Int, preparationSeconds: Double) {
        requests += 1
        if attempt > 0 { retries += 1 }
        self.inputTokens += inputTokens
        reservedOutputTokens += outputLimit
        self.preparationSeconds += preparationSeconds
    }

    mutating func finish(seconds: Double, info: GenerateCompletionInfo?, failed: Bool) {
        completedRequests += 1
        wallSeconds += seconds
        maximumRequestSeconds = max(maximumRequestSeconds, seconds)
        if failed { errors += 1 }
        guard let info else { missingCompletionInfo += 1; return }
        outputTokens += info.generationTokenCount
        promptSeconds += info.promptTime
        generationSeconds += info.generateTime
        switch info.stopReason {
        case .stop: stoppedAtEOS += 1
        case .length: stoppedAtLimit += 1
        case .cancelled: cancelled += 1
        }
    }
}

struct SummaryMetrics: Codable {
    var schemaVersion = 1
    var startedAt = Date()
    var status = "running"
    var elapsedSeconds = 0.0
    var modelLoadSeconds = 0.0
    var sourcePreparationSeconds = 0.0
    var planningTokenizations = 0
    var planningSeconds = 0.0
    var groupCheckpointHits = 0
    var phases: [String: SummaryRequestMetrics] = [:]

    mutating func update(_ phase: SummaryMetricPhase, _ body: (inout SummaryRequestMetrics) -> Void) {
        body(&phases[phase.rawValue, default: SummaryRequestMetrics()])
    }
}
