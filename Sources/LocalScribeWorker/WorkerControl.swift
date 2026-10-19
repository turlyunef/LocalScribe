import Foundation
import Darwin

/// Owns the worker's monitors until their cancellation handlers have finished.
actor WorkerControl {
    private let queue = DispatchQueue(label: "LocalScribe.worker.control")
    private let stopped = DispatchGroup()
    private var watchdog: DispatchSourceTimer?
    private var input: DispatchSourceRead?
    private var stopping = false

    init(parent: pid_t, onParentExit: @escaping @Sendable () -> Void = { Worker.terminateGroup(71) }) {
        let source = DispatchSource.makeTimerSource(queue: queue)
        let stopped = self.stopped
        stopped.enter()
        source.setCancelHandler { stopped.leave() }
        source.schedule(deadline: .now() + 1, repeating: 1)
        source.setEventHandler { if getppid() != parent { onParentExit() } }
        source.resume()
        watchdog = source
    }

    func watchInput(descriptor: Int32 = STDIN_FILENO, onEOF: @escaping @Sendable () -> Void) {
        precondition(!stopping && input == nil)
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        let stopped = self.stopped
        stopped.enter()
        // The descriptor is borrowed. Its owner can close it after stop() joins.
        source.setCancelHandler { stopped.leave() }
        source.setEventHandler {
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count == 0 || (count < 0 && errno != EINTR && errno != EAGAIN) { onEOF() }
        }
        source.resume()
        input = source
    }

    func stop() async {
        stopping = true
        watchdog?.cancel(); input?.cancel()
        watchdog = nil; input = nil
        // cancel() is asynchronous. Join on the same serial queue after both
        // cancellation handlers, so no callback still retains the command/emitter.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            stopped.notify(queue: queue) { continuation.resume() }
        }
    }
}
