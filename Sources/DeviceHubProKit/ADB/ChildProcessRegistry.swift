import Foundation
import Synchronization

/// Remembers the app's long-lived helper children (`adb track-devices`, `adb logcat`,
/// `log stream`, `simctl spawn ... notifyutil -w`, scrcpy's server) by process id so a
/// SIGTERM/SIGHUP/SIGINT can end them: without it they are re-parented to launchd and run
/// on after the app is gone (measured: 8 orphans after several restarts). Emulator VMs
/// are started through `ProcessRunner.launchDetached` and are never registered: they are
/// meant to outlive the app.
///
/// The signal path only reads a pid set under a lock and calls `kill(2)`.
public enum ChildProcessRegistry {
    private static let pids = Mutex<Set<pid_t>>([])

    /// Adds a launched child.
    static func register(_ process: Process) {
        guard process.isRunning, process.processIdentifier > 0 else { return }
        let pid = process.processIdentifier
        pids.withLock { _ = $0.insert(pid) }
    }

    /// Drops a child that exited (call from its termination handler).
    static func unregister(_ process: Process) {
        let pid = process.processIdentifier
        pids.withLock { _ = $0.remove(pid) }
    }

    /// Sends SIGTERM to every registered child, then forgets them. Any thread.
    public static func terminateAll() {
        let all = pids.withLock { set -> [pid_t] in
            defer { set.removeAll() }
            return Array(set)
        }
        for pid in all { kill(pid, SIGTERM) }
    }

    /// Number of registered children (tests).
    static var registeredCount: Int { pids.withLock { $0.count } }
}
