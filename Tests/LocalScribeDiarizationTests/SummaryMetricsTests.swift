import XCTest
import LocalScribeCore
import MLXLMCommon
@testable import LocalScribeWorker

/// Counters of `SummaryRequestMetrics` and phase bookkeeping of
/// `SummaryMetrics`. In the worker they are only fed by the real MLX
/// completion wrapper, so the pure aggregation rules — attempt accounting,
/// stop-reason classification, missing completion info, the request maximum
/// and per-phase isolation — are verified here with constructed
/// `GenerateCompletionInfo` values instead of weights.
final class SummaryMetricsTests: XCTestCase {

    func testStartCountsRequestsRetriesAndBudgets() {
        var metrics = SummaryRequestMetrics()
        metrics.start(inputTokens: 1500, outputLimit: 512, attempt: 0, preparationSeconds: 0.25)
        metrics.start(inputTokens: 1200, outputLimit: 256, attempt: 1, preparationSeconds: 0.5)
        metrics.start(inputTokens: 300, outputLimit: 128, attempt: 2, preparationSeconds: 0.125)
        XCTAssertEqual(metrics.requests, 3)
        XCTAssertEqual(metrics.retries, 2, "повтором считается каждый attempt > 0")
        XCTAssertEqual(metrics.inputTokens, 3000)
        XCTAssertEqual(metrics.reservedOutputTokens, 896)
        XCTAssertEqual(metrics.preparationSeconds, 0.875, accuracy: 1e-9)
        XCTAssertEqual(metrics.completedRequests, 0, "один start не завершает запрос")
        XCTAssertEqual(metrics.errors, 0)
    }

    func testFinishWithoutCompletionInfoCountsMissingAndKeepsMaximum() {
        var metrics = SummaryRequestMetrics()
        metrics.finish(seconds: 3.5, info: nil, failed: false)
        metrics.finish(seconds: 2.0, info: nil, failed: true)
        XCTAssertEqual(metrics.completedRequests, 2)
        XCTAssertEqual(metrics.wallSeconds, 5.5, accuracy: 1e-9)
        XCTAssertEqual(metrics.maximumRequestSeconds, 3.5, accuracy: 1e-9,
                       "максимум хранит самый долгий запрос")
        XCTAssertEqual(metrics.missingCompletionInfo, 2)
        XCTAssertEqual(metrics.errors, 1)
        XCTAssertEqual(metrics.outputTokens, 0)
        XCTAssertEqual(metrics.promptSeconds, 0, accuracy: 1e-9)
        XCTAssertEqual(metrics.generationSeconds, 0, accuracy: 1e-9)
        XCTAssertEqual(metrics.stoppedAtEOS + metrics.stoppedAtLimit + metrics.cancelled, 0,
                       "без completion info причины остановки не классифицируются")
    }

    /// Each finish classifies exactly one stop reason and accumulates the
    /// token and timing fields of the completion info.
    func testFinishClassifiesStopReasonAndAccumulatesInfo() {
        var metrics = SummaryRequestMetrics()
        metrics.finish(seconds: 1.0, info: GenerateCompletionInfo(
            promptTokenCount: 1500, generationTokenCount: 40, promptTime: 0.25,
            generationTime: 0.5, stopReason: .stop), failed: false)
        metrics.finish(seconds: 2.0, info: GenerateCompletionInfo(
            promptTokenCount: 1500, generationTokenCount: 60, promptTime: 0.5,
            generationTime: 1.25, stopReason: .length), failed: false)
        metrics.finish(seconds: 3.0, info: GenerateCompletionInfo(
            promptTokenCount: 1500, generationTokenCount: 20, promptTime: 0.25,
            generationTime: 0.25, stopReason: .cancelled), failed: false)
        XCTAssertEqual(metrics.completedRequests, 3)
        XCTAssertEqual(metrics.stoppedAtEOS, 1)
        XCTAssertEqual(metrics.stoppedAtLimit, 1)
        XCTAssertEqual(metrics.cancelled, 1)
        XCTAssertEqual(metrics.missingCompletionInfo, 0)
        XCTAssertEqual(metrics.outputTokens, 120)
        XCTAssertEqual(metrics.promptSeconds, 1.0, accuracy: 1e-9)
        XCTAssertEqual(metrics.generationSeconds, 2.0, accuracy: 1e-9)
        XCTAssertEqual(metrics.wallSeconds, 6.0, accuracy: 1e-9)
        XCTAssertEqual(metrics.maximumRequestSeconds, 3.0, accuracy: 1e-9)
        XCTAssertEqual(metrics.errors, 0)
    }

    /// A failed request may still carry completion info: the error counter
    /// and the stop-reason classification are independent.
    func testFinishFailureAndStopReasonAreIndependent() {
        var metrics = SummaryRequestMetrics()
        metrics.finish(seconds: 4.0, info: GenerateCompletionInfo(
            promptTokenCount: 10, generationTokenCount: 5, promptTime: 0.25,
            generationTime: 0.75, stopReason: .stop), failed: true)
        XCTAssertEqual(metrics.errors, 1)
        XCTAssertEqual(metrics.stoppedAtEOS, 1, "неудача с info всё равно классифицирует причину")
        XCTAssertEqual(metrics.completedRequests, 1)
        XCTAssertEqual(metrics.outputTokens, 5)
    }

    func testExtractionPhaseMapping() {
        XCTAssertEqual(SummaryMetricPhase.extraction(.overview), .overview)
        XCTAssertEqual(SummaryMetricPhase.extraction(.decisions), .decisions)
        XCTAssertEqual(SummaryMetricPhase.extraction(.tasks), .tasks)
        XCTAssertEqual(SummaryMetricPhase.extraction(.openQuestions), .openQuestions)
        XCTAssertEqual(SummaryMetricPhase.extraction(nil), .reduction,
                       "сжатие итогов — фаза без секции")
    }

    /// `update` creates a phase entry on first touch and keeps the counters
    /// of different phases separate; untouched phases stay absent.
    func testPhaseUpdateCreatesAndIsolatesCounters() throws {
        var metrics = SummaryMetrics()
        metrics.update(.tasks) { $0.checkpointHits += 1 }
        metrics.update(.tasks) { $0.checkpointHits += 1 }
        metrics.update(.taskEvidence) { $0.checkpointHits += 1 }
        XCTAssertEqual(metrics.phases.count, 2)
        let tasks = try XCTUnwrap(metrics.phases["tasks"])
        XCTAssertEqual(tasks.checkpointHits, 2)
        let evidence = try XCTUnwrap(metrics.phases["taskEvidence"])
        XCTAssertEqual(evidence.checkpointHits, 1)
        XCTAssertNil(metrics.phases["overview"], "нетронутые фазы отсутствуют")
    }

    /// One phase through the SummaryEngine lifecycle: a first attempt fails
    /// without SDK completion info, the retry finishes at the token limit.
    /// This mirrors completion() in SummaryEngine, where start/finish wrap
    /// every attempt of one phase.
    func testRequestLifecycleWithRetryAggregatesAcrossAttempts() throws {
        var metrics = SummaryMetrics()
        metrics.update(.decisions) { phase in
            phase.start(inputTokens: 2000, outputLimit: 1024, attempt: 0, preparationSeconds: 0.125)
            phase.finish(seconds: 1.0, info: nil, failed: true)
            phase.start(inputTokens: 2000, outputLimit: 1024, attempt: 1, preparationSeconds: 0.25)
            phase.finish(seconds: 4.0, info: GenerateCompletionInfo(
                promptTokenCount: 2000, generationTokenCount: 1024, promptTime: 0.5,
                generationTime: 3.25, stopReason: .length), failed: false)
        }
        let decisions = try XCTUnwrap(metrics.phases["decisions"])
        XCTAssertEqual(decisions.requests, 2)
        XCTAssertEqual(decisions.retries, 1)
        XCTAssertEqual(decisions.completedRequests, 2)
        XCTAssertEqual(decisions.errors, 1)
        XCTAssertEqual(decisions.missingCompletionInfo, 1)
        XCTAssertEqual(decisions.stoppedAtLimit, 1)
        XCTAssertEqual(decisions.stoppedAtEOS, 0)
        XCTAssertEqual(decisions.cancelled, 0)
        XCTAssertEqual(decisions.outputTokens, 1024)
        XCTAssertEqual(decisions.promptSeconds, 0.5, accuracy: 1e-9)
        XCTAssertEqual(decisions.generationSeconds, 3.25, accuracy: 1e-9)
        XCTAssertEqual(decisions.wallSeconds, 5.0, accuracy: 1e-9)
        XCTAssertEqual(decisions.maximumRequestSeconds, 4.0, accuracy: 1e-9)
        XCTAssertEqual(decisions.inputTokens, 4000)
        XCTAssertEqual(decisions.reservedOutputTokens, 2048)
        XCTAssertEqual(decisions.preparationSeconds, 0.375, accuracy: 1e-9)
    }
}
