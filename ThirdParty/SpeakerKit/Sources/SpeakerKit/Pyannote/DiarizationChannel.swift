// LocalScribe addition to the SpeakerKit snapshot. See accompanying LICENSE.

import Foundation
import Synchronization

// LocalScribe: a lossless, bounded channel for one clip. The buffer holds at
// most capacity outputs; each segmenter worker may additionally hold one output
// in send(), and each embedder worker one in inference. No task is spawned per
// output. Waiter cancellation also works in the segmenter's nested task group,
// without aborting consumers before the original prediction error propagates.
final class DiarizationChannel<Element: Sendable>: Sendable {
    private enum Status { case open, finished, cancelled }
    private struct State {
        var status = Status.open
        var buffer: [Element] = []
        var senders: [(id: UUID, element: Element, continuation: CheckedContinuation<Void, any Error>)] = []
        var receivers: [(id: UUID, continuation: CheckedContinuation<Element?, any Error>)] = []
    }

    private let capacity: Int
    private let state = Mutex(State())

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    func send(_ element: Element) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                state.withLock { state in
                    guard !Task.isCancelled, state.status == .open else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    if !state.receivers.isEmpty {
                        state.receivers.removeFirst().continuation.resume(returning: element)
                        continuation.resume()
                    } else if state.buffer.count < capacity {
                        state.buffer.append(element)
                        continuation.resume()
                    } else {
                        state.senders.append((id, element, continuation))
                    }
                }
            }
            try Task.checkCancellation()
        } onCancel: {
            self.cancelWaiter(id)
        }
    }

    func next() async throws -> Element? {
        let id = UUID()
        return try await withTaskCancellationHandler {
            let element = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Element?, any Error>) in
                state.withLock { state in
                    guard !Task.isCancelled, state.status != .cancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    if !state.buffer.isEmpty {
                        let element = state.buffer.removeFirst()
                        if !state.senders.isEmpty {
                            let sender = state.senders.removeFirst()
                            state.buffer.append(sender.element)
                            sender.continuation.resume()
                        }
                        continuation.resume(returning: element)
                    } else if state.status == .finished {
                        continuation.resume(returning: nil)
                    } else {
                        state.receivers.append((id, continuation))
                    }
                }
            }
            try Task.checkCancellation()
            return element
        } onCancel: {
            self.cancelWaiter(id)
        }
    }

    // Successful production drains buffered outputs before returning EOF.
    // The owner calls this only after all producer workers have joined.
    func finish() {
        state.withLock { state in
            guard state.status == .open else { return }
            state.status = .finished
            for receiver in state.receivers { receiver.continuation.resume(returning: nil) }
            state.receivers.removeAll()
        }
    }

    // Error/cancellation discards pending outputs and wakes both sides before
    // the owner waits for the structured tasks to exit. Safe to call repeatedly.
    func cancel() {
        state.withLock { state in
            state.status = .cancelled
            state.buffer.removeAll()
            for sender in state.senders { sender.continuation.resume(throwing: CancellationError()) }
            state.senders.removeAll()
            for receiver in state.receivers { receiver.continuation.resume(throwing: CancellationError()) }
            state.receivers.removeAll()
        }
    }

    private func cancelWaiter(_ id: UUID) {
        state.withLock { state in
            if let index = state.senders.firstIndex(where: { $0.id == id }) {
                state.senders.remove(at: index).continuation.resume(throwing: CancellationError())
            }
            if let index = state.receivers.firstIndex(where: { $0.id == id }) {
                state.receivers.remove(at: index).continuation.resume(throwing: CancellationError())
            }
        }
    }
}
