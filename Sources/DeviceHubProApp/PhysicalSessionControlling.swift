import Foundation
import DeviceHubProKit

/// What the app does with a physical device's scrcpy session beyond the
/// shared `MirrorSessionProtocol` surface: its clipboard over the control
/// socket, Back over the same socket, and the synchronous stop at quit.
///
/// `PhysicalMirrorSession` is the only production conformer. The protocol
/// lets the clipboard sync and the mirror (Back, the stats poll's fatal
/// path, the teardown's stop) run against a test fake, so no test needs a
/// phone for the physical paths.
protocol PhysicalSessionControlling: AnyObject, Sendable {
    /// The device's adb serial.
    var serial: String { get }
    /// Whether input currently travels over scrcpy's control socket (false
    /// before the connection is up, and on the `adb shell input` fallback).
    var usesControlSocket: Bool { get }
    /// Receives the device clipboard whenever it changes on the device; runs
    /// on the control channel's delivery queue.
    var onDeviceClipboard: (@Sendable (String) -> Void)? { get set }
    /// The last stream error, or nil.
    var lastError: String? { get }
    /// Whether the session is live.
    var isRunning: Bool { get }

    /// Whether the device server reported refusing injected input.
    var inputInjectionDenied: Bool { get }
    /// Forgets a seen refusal.
    func clearInputInjectionDenied()

    /// Sets the device clipboard, pasting it into the focused field when
    /// `paste` is true. Control socket only.
    func setDeviceClipboard(_ text: String, paste: Bool)
    /// BACK, or POWER when the device screen is off.
    func sendBackOrScreenOn()
    /// Back, Home or Recents, over the control socket (adb fallback).
    func sendNavigationKey(_ key: NavigationKey)
    /// Stops the stream. Idempotent.
    func stop()
    /// Stops the session and completes its teardown before returning,
    /// waiting at most `timeout`.
    func stopAndWait(timeout: TimeInterval)
}

extension PhysicalSessionControlling {
    var inputInjectionDenied: Bool { false }
    func clearInputInjectionDenied() {}
    func sendNavigationKey(_ key: NavigationKey) {}
}

extension PhysicalMirrorSession: PhysicalSessionControlling {}
