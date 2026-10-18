import AppKit
import Synchronization

/// One slot shared by drops, the open panel and duplicate retries. A slot covers
/// provider loading, security scope, probe, hash/copy and publication in the UI.
@MainActor final class ImportQueue {
    private var pending: [@MainActor () async -> Void] = []
    private var task: Task<Void, Never>?

    func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        guard task?.isCancelled != true else { return }
        pending.append(operation)
        guard task == nil else { return }
        task = Task {
            defer { task = nil }
            while !Task.isCancelled, !pending.isEmpty {
                let next = pending.removeFirst()
                await next()
            }
        }
    }

    func cancel() {
        pending.removeAll()
        task?.cancel()
    }

    /// Cancellation does not release the slot until the active operation exits.
    func waitUntilIdle() async { await task?.value }
}

/// Some providers never call back after Progress.cancel(). Resume our waiter on
/// cancellation too, and ignore late callbacks without retaining an open scope.
private final class DroppedFileRequest: Sendable {
    private struct State {
        var continuation: CheckedContinuation<URL?, Error>?
        var progress: Progress?
        var finished = false
        var cancelled = false
    }
    private let state = Mutex(State())

    func start(_ continuation: CheckedContinuation<URL?, Error>) -> Bool {
        let cancelled = state.withLock { state in
            if state.cancelled { return true }
            state.continuation = continuation
            return false
        }
        if cancelled { continuation.resume(throwing: CancellationError()) }
        return !cancelled
    }

    func setProgress(_ progress: Progress) {
        let cancelled = state.withLock { state in
            if !state.finished { state.progress = progress }
            return state.cancelled
        }
        if cancelled { progress.cancel() }
    }

    func finish(_ result: Result<URL?, Error>) {
        let continuation = state.withLock { state in
            guard !state.finished else { return Optional<CheckedContinuation<URL?, Error>>.none }
            state.finished = true
            let continuation = state.continuation
            state.continuation = nil; state.progress = nil
            return continuation
        }
        continuation?.resume(with: result)
    }

    func cancel() {
        let (continuation, progress) = state.withLock { state in
            state.cancelled = true; state.finished = true
            let values = (state.continuation, state.progress)
            state.continuation = nil; state.progress = nil
            return values
        }
        progress?.cancel()
        continuation?.resume(throwing: CancellationError())
    }
}

enum DroppedFileURL {
    @MainActor static func load(_ provider: NSItemProvider) async throws -> URL? {
        let request = DroppedFileRequest()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard request.start(continuation) else { return }
                let progress = provider.loadObject(ofClass: URL.self) { url, error in
                    if let error { request.finish(.failure(error)) }
                    else { request.finish(.success(url)) }
                }
                request.setProgress(progress)
            }
        } onCancel: {
            request.cancel()
        }
    }
}
