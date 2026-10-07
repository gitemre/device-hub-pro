import Foundation
import Synchronization

/// Keeps the app's resident fast input children (the tunnel lease's `devicectl`) from
/// outliving the app. A quit ends them through the sessions, but a SIGTERM (`pkill`, a
/// supervisor) kills the app without that path, and the children would run on until their
/// session timeout (300 s, measured 2026-10-01). Children register here when they start;
/// `terminateAll()` ends every one, and `installSignalHandlers()` calls it on SIGTERM,
/// SIGHUP and SIGINT before the signal's default action runs. SIGKILL cannot be handled.
public enum FastInputTermination {
    private static let registry = Mutex<[any FastInputChild]>([])
    private static let sources = Mutex<[any DispatchSourceSignal]>([])

    static func register(_ child: any FastInputChild) {
        registry.withLock { list in
            list.removeAll { !$0.isRunning }
            list.append(child)
        }
    }

    static func unregister(_ child: any FastInputChild) {
        registry.withLock { list in list.removeAll { $0 === child } }
    }

    /// Ends every registered child at once, from any thread.
    public static func terminateAll() {
        let running = registry.withLock { list -> [any FastInputChild] in
            defer { list.removeAll() }
            return list
        }
        for child in running { child.terminate() }
        ChildProcessRegistry.terminateAll()
    }

    /// Number of children that are registered and running (tests).
    static var registeredCount: Int { registry.withLock { $0.filter(\.isRunning).count } }

    /// On SIGTERM, SIGHUP and SIGINT: end the children, restore the default action and
    /// re-raise so the process ends as it would have. Idempotent.
    ///
    /// `reraise` is the final step (tests pass a recorder so the signal does not end the
    /// test process); the default re-raises the signal.
    public static func installSignalHandlers(
        signals: [Int32] = [SIGTERM, SIGHUP, SIGINT],
        reraise: @escaping @Sendable (Int32) -> Void = { raise($0) }
    ) {
        let already = sources.withLock { !$0.isEmpty }
        guard !already else { return }
        let made = signals.map { number -> any DispatchSourceSignal in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .userInitiated))
            source.setEventHandler {
                terminateAll()
                signal(number, SIG_DFL)
                reraise(number)
            }
            source.resume()
            return source
        }
        sources.withLock { $0 = made }
    }
}
