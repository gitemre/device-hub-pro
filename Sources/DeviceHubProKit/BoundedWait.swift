import Foundation

/// A wait that gives up. A gRPC call into a wedged emulator can block with no
/// error and no way to cancel it (the call sits in a synchronous server
/// worker), so structured concurrency's own timeout idiom, which awaits the
/// loser of the race, would hang with it. `run` instead returns the moment
/// the first of the body and the clock finishes; the abandoned body is
/// cancelled and left to end on its own, and its late answer is dropped.
public enum BoundedWait {
    /// `body`'s answer, or nil when `timeout` elapsed first or the calling
    /// task was cancelled (the caller tells the two apart with
    /// `Task.isCancelled`).
    public static func run<T: Sendable>(
        _ timeout: Duration,
        _ body: @escaping @Sendable () async -> T
    ) async -> T? {
        let gate = Gate<T>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
                guard gate.install(continuation) else { return }
                let work = Task {
                    let value = await body()
                    gate.finish(value)
                }
                let clock = Task {
                    // Best effort: a cancelled sleep means the answer came first.
                    try? await Task.sleep(for: timeout)
                    gate.finish(nil)
                }
                gate.adopt([work, clock])
            }
        } onCancel: {
            gate.finish(nil)
        }
    }

    /// Resumes the continuation once and cancels the two tasks.
    private final class Gate<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T?, Never>?
        private var tasks: [Task<Void, Never>] = []
        private var done = false

        /// False when the call was cancelled before the continuation existed.
        func install(_ continuation: CheckedContinuation<T?, Never>) -> Bool {
            lock.lock()
            if done {
                lock.unlock()
                continuation.resume(returning: nil)
                return false
            }
            self.continuation = continuation
            lock.unlock()
            return true
        }

        func adopt(_ tasks: [Task<Void, Never>]) {
            lock.lock()
            if done {
                lock.unlock()
                tasks.forEach { $0.cancel() }
                return
            }
            self.tasks = tasks
            lock.unlock()
        }

        func finish(_ value: T?) {
            lock.lock()
            guard !done else {
                lock.unlock()
                return
            }
            done = true
            let continuation = self.continuation
            let tasks = self.tasks
            self.continuation = nil
            self.tasks = []
            lock.unlock()
            tasks.forEach { $0.cancel() }
            continuation?.resume(returning: value)
        }
    }
}
