import DeviceHubProKit
import Foundation

/// Runs a read-back until the device has applied a write, or the budget runs
/// out. Several Android commands settle asynchronously (Wi-Fi, Bluetooth,
/// airplane mode, `cmd uimode night`), so a write path reads once, checks, and
/// retries briefly instead of sleeping a fixed amount. Pure control flow: the
/// caller supplies the read/apply step and the settled condition, which keeps
/// the retry behaviour unit-testable. `isCurrent` ends the loop when the
/// device is no longer the one written to; `attemptTimeout` bounds each
/// read's adb calls.
@MainActor
@discardableResult
func settleSetting(
    attempts: Int = 5,
    delay: Duration = .milliseconds(80),
    attemptTimeout: Duration? = nil,
    isCurrent: () -> Bool = { true },
    attempt: () async -> Void,
    settled: () -> Bool
) async -> Bool {
    guard attempts > 0 else { return settled() }
    for index in 0..<attempts {
        // The device the write went to left (or the write was cancelled):
        // nothing more to wait for, and the fence is released at once.
        guard isCurrent(), !Task.isCancelled else { return false }
        if let attemptTimeout {
            await AdbCallTimeout.$override.withValue(attemptTimeout) { await attempt() }
        } else {
            await attempt()
        }
        if settled() { return true }
        if index < attempts - 1, delay > .zero {
            try? await Task.sleep(for: delay)
        }
    }
    return false
}

/// The volume-key events that move the media volume from `from` to `to`
/// (Android's `KEYCODE_VOLUME_UP` = 24, `KEYCODE_VOLUME_DOWN` = 25).
///
/// Current images deny absolute volume writes — `cmd media_session volume
/// --stream 3 --set N` reports success but keeps the old index — while the
/// volume keys still work, so the Sound row steps to the target with them.
/// Capped so a volume policy that blocks the change cannot loop forever.
func volumeKeyEvents(from: Int, to: Int, limit: Int = 32) -> [String] {
    let delta = to - from
    let count = min(abs(delta), max(limit, 0))
    let key = delta > 0 ? "24" : "25"
    return Array(repeating: key, count: count)
}
