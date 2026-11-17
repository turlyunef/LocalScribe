import LocalScribeCore

enum WorkerDiagnostics {
    typealias PhaseReporter = @Sendable (DiagnosticPhase) -> Void

    static func loadModel<T>(report: PhaseReporter?, isolation: isolated (any Actor)? = #isolation,
                             load: () async throws -> T) async throws -> T {
        guard let report else { return try await load() }
        report(.modelLoad)
        do {
            let value = try await load()
            report(.processing)
            return value
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ClassifiedDiagnosticError(error, code: .modelLoad, phase: .modelLoad,
                                             fallback: "Не удалось загрузить модель.")
        }
    }
}
