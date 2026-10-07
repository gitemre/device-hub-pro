import Foundation

/// Sets up, on demand, the interleaving that hung
/// `DeviceLifecycleCoordinator.stop()`: a watcher's stream consumer, waiting
/// in `next()`, has its status-record lock held by another thread, and an
/// emission's `yield` is stalled on that lock (resuming the consumer takes
/// it). A canceller holds the lock while it runs the stream's
/// `onTermination`, which calls the watcher's `stop()`; a `stop()` that
/// waits for the stalled yield (one made under the lock `stop()` takes)
/// therefore never returns, and neither does the cancel.
///
/// A priority-escalation handler holds the lock here instead: the runtime
/// runs it under the task's status-record lock exactly like a cancellation
/// handler, but it does not terminate the stream, so the yield really
/// stalls. `stop` runs on a thread of its own, so a watcher that still waits
/// fails the probe after `timeout` instead of hanging the test process: once
/// the handler returns, the yield completes and so does `stop`.
enum StalledYieldProbe {
    /// Whether `stop` returns while an emission's `yield` to `stream`'s
    /// consumer is stalled on the consumer's status-record lock.
    ///
    /// - Parameters:
    ///   - stream: the watcher's event stream, not iterated yet.
    ///   - emit: makes the watcher emit, on a thread of its own. It returns
    ///     once the emission is under way, or blocks in the stalled yield.
    ///   - stop: the watcher's `stop()`.
    static func stopReturnsWhileAYieldIsStalled<Element: Sendable>(
        consuming stream: AsyncStream<Element>,
        emit: @escaping @Sendable () -> Void,
        stop: @escaping @Sendable () -> Void,
        timeout: TimeInterval = 3
    ) -> Bool {
        let iterating = DispatchSemaphore(value: 0)
        let stopped = DispatchSemaphore(value: 0)
        let ended = DispatchSemaphore(value: 0)
        let stopReturned = Flag()
        let consumer = Task.detached(priority: .low) {
            await withTaskPriorityEscalationHandler {
                iterating.signal()
                for await _ in stream {}
            } onPriorityEscalated: { _, _ in
                // The escalating thread holds the consumer's status-record
                // lock until this returns.
                let emitted = DispatchSemaphore(value: 0)
                Thread.detachNewThread {
                    emit()
                    emitted.signal()
                }
                _ = emitted.wait(timeout: .now() + 1)
                // Lets the emission reach the stalled resume.
                Thread.sleep(forTimeInterval: 0.3)
                Thread.detachNewThread {
                    stop()
                    stopped.signal()
                }
                if stopped.wait(timeout: .now() + timeout) == .success {
                    stopReturned.set()
                }
            }
            ended.signal()
        }
        iterating.wait()
        // Lets the consumer suspend in `next()`, so the emission has to
        // resume it: a yield it buffers would never touch the lock.
        Thread.sleep(forTimeInterval: 0.2)
        consumer.escalatePriority(to: .high)
        let returned = stopReturned.value
        if !returned {
            // The handler let go of the lock, so the stalled yield and the
            // `stop` behind it finish now. Cancelling first would deadlock
            // this very test in `onTermination`, the way the app hung.
            _ = stopped.wait(timeout: .now() + 10)
        }
        consumer.cancel()
        _ = ended.wait(timeout: .now() + timeout)
        return returned
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = false

        func set() {
            lock.lock()
            stored = true
            lock.unlock()
        }

        var value: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }
}
