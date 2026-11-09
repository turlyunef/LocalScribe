import AppKit
import Synchronization
import LocalScribeCore

/// One slot shared by drops, the open panel and duplicate retries. A slot covers
/// provider loading, security scope, probe, hash/copy and publication in the UI.
@MainActor final class ImportQueue {
    private struct Entry {
        let onDiscard: @MainActor () -> Void
        let run: @MainActor () async -> Void
    }
    private var pending: [Entry] = []
    private var task: Task<Void, Never>?

    func enqueue(onDiscard: @escaping @MainActor () -> Void = {},
                 _ operation: @escaping @MainActor () async -> Void) throws {
        guard task?.isCancelled != true else {
            throw ScribeError.message("Импорт отменяется. Дождитесь завершения и повторите добавление файлов.")
        }
        pending.append(Entry(onDiscard: onDiscard, run: operation))
        guard task == nil else { return }
        task = Task {
            defer { task = nil }
            while !Task.isCancelled, !pending.isEmpty {
                let next = pending.removeFirst()
                await next.run()
            }
        }
    }

    func cancel() {
        for entry in pending { entry.onDiscard() }
        pending.removeAll()
        task?.cancel()
    }

    /// Cancellation does not release the slot until the active operation exits.
    func waitUntilIdle() async { await task?.value }
}

/// Some providers never call back after Progress.cancel(). Resume our waiter on
/// cancellation too, and ignore late callbacks without retaining an open scope.
final class DroppedFileURL: Sendable {
    private struct State {
        var continuation: CheckedContinuation<URL?, Error>?
        var progress: Progress?
        var result: Result<URL?, Error>?
        var cancelled = false
    }
    private let state = Mutex(State())

    private func wait(_ continuation: CheckedContinuation<URL?, Error>) {
        let result = state.withLock { state in
            if let result = state.result { return Optional(result) }
            state.continuation = continuation
            return nil
        }
        if let result { continuation.resume(with: result) }
    }

    private func setProgress(_ progress: Progress) {
        let cancelled = state.withLock { state in
            if state.result == nil { state.progress = progress }
            return state.cancelled
        }
        if cancelled { progress.cancel() }
    }

    private func finish(_ result: Result<URL?, Error>) {
        let continuation = state.withLock { state in
            guard state.result == nil else { return Optional<CheckedContinuation<URL?, Error>>.none }
            state.result = result
            let continuation = state.continuation
            state.continuation = nil; state.progress = nil
            return continuation
        }
        continuation?.resume(with: result)
    }

    func cancel() {
        let (continuation, progress) = state.withLock { state in
            state.cancelled = true
            state.result = .failure(CancellationError())
            let values = (state.continuation, state.progress)
            state.continuation = nil; state.progress = nil
            return values
        }
        progress?.cancel()
        continuation?.resume(throwing: CancellationError())
    }

    /// SwiftUI requires loading to start inside the synchronous drop callback.
    /// The queue can still await and import the resulting URLs in source order.
    @MainActor static func start(_ provider: NSItemProvider) -> DroppedFileURL {
        let request = DroppedFileURL()
        let progress = provider.loadObject(ofClass: URL.self) { url, error in
            if let error { request.finish(.failure(error)) }
            else { request.finish(.success(url)) }
        }
        request.setProgress(progress)
        return request
    }

    @MainActor func value() async throws -> URL? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { wait($0) }
        } onCancel: {
            self.cancel()
        }
    }

    @MainActor static func load(_ provider: NSItemProvider) async throws -> URL? {
        try Task.checkCancellation()
        return try await start(provider).value()
    }
}
