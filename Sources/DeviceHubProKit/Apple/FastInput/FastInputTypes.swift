import CoreGraphics
import Foundation

// The vocabulary of "fast input" on a physical iPhone: the errors, the helper's line protocol and the seam
// the input router sends through. Nothing here starts a process or touches a
// device.

/// Why fast input is unavailable, stopped or failed, in words the app shows.
/// No case carries the phone's identifiers.
public enum FastInputError: Error, Equatable, Sendable, CustomStringConvertible {
    /// `DHP_DISABLE_FAST_INPUT` is set.
    case disabled
    /// The helper's sources (`fastinput/`) are not in this build.
    case sourcesMissing
    /// The helper could not be built; the text is the build's own error.
    case buildFailed(String)
    /// A child process could not be started.
    case launchFailed(String)
    /// The helper says the phone's CoreDevice tunnel is not connected.
    case tunnelNotConnected
    /// The helper could not open its service connections.
    case socketRefused(String)
    /// The helper refused to start for another reason.
    case helperFatal(code: Int, message: String)
    /// The helper's process ended.
    case helperExited
    /// The helper did not become ready in time.
    case startTimedOut
    /// The helper answered a command with an error.
    case commandFailed(code: Int, message: String)
    /// The helper did not answer a command in time.
    case commandTimedOut
    /// The session is not started, or not ready.
    case notReady
    /// The session was stopped.
    case stopped
    /// The tunnel lease could not be held.
    case leaseFailed(String)

    public var description: String {
        switch self {
        case .disabled:
            return "Fast input is switched off (DHP_DISABLE_FAST_INPUT)."
        case .sourcesMissing:
            return "The fast input helper's sources (fastinput) are not part of this build."
        case .buildFailed(let text):
            return "The fast input helper could not be built: \(text)"
        case .launchFailed(let text):
            return "The fast input helper could not be started: \(text)"
        case .tunnelNotConnected:
            return "The iPhone's connection to this Mac is not up. Unlock it and reconnect."
        case .socketRefused(let text):
            return "The iPhone refused the fast input connection" + (text.isEmpty ? "." : ": \(text)")
        case .helperFatal(_, let text):
            return "The fast input helper stopped at start" + (text.isEmpty ? "." : ": \(text)")
        case .helperExited:
            return "The fast input helper stopped."
        case .startTimedOut:
            return "The fast input helper did not start in time."
        case .commandFailed(_, let text):
            return "The iPhone did not take the input" + (text.isEmpty ? "." : ": \(text)")
        case .commandTimedOut:
            return "The fast input helper did not answer in time."
        case .notReady:
            return "Fast input is not ready."
        case .stopped:
            return "Fast input was stopped."
        case .leaseFailed(let text):
            return "The connection to the iPhone could not be held" + (text.isEmpty ? "." : ": \(text)")
        }
    }
}

/// What the input router sends through in fast mode. Points are normalized
/// (0...1), portrait, origin at the top left.
public protocol FastInputSending: Sendable {
    func down(_ point: CGPoint) async throws
    func move(_ point: CGPoint) async throws
    func up(_ point: CGPoint) async throws
    /// One event of a bottom-edge gesture (home swipe, App Switcher hold), sent over the
    /// helper's digitizer connection; throws `commandFailed(code: 7, ...)` when that
    /// connection is unavailable (the session stays usable).
    func edge(_ phase: FastInputEdgePhase, _ point: CGPoint) async throws
    func button(_ button: PhysicalControlButton) async throws
    /// One edge of any HID button (`down` true = pressed): the button stays as the last edge
    /// left it, so a hold or a combination is the caller's own down and up.
    func hid(page: Int, usage: Int, down: Bool) async throws
    /// The App Switcher (the vendor keyboard page's usage, see `fastinput/PROVENANCE.md`).
    func appSwitcher() async throws
    /// One HID keyboard usage (1...0xE7).
    func key(usage: Int, action: FastInputKeyAction) async throws
    /// One keyboard report holding exactly `usages` (HID usages 1...0xE7, modifiers
    /// included; empty = all up): the Mac drives the held set.
    func keys(_ usages: [Int]) async throws
}

public enum FastInputKeyAction: String, Sendable, Equatable {
    case down, up, tap
}

/// The phase of a bottom-edge digitizer event (the helper's `edge` verb).
public enum FastInputEdgePhase: String, Sendable, Equatable {
    case down, move, up
}

/// A fast input session the app owns: it sends, and it can be ended.
public protocol FastInputControlling: FastInputSending {
    func stop() async
    /// Ends the helper and the lease at once, from any thread (the app's quit).
    func terminateNow()
}

/// A command of the helper's line protocol.
enum FastInputCommand: Equatable, Sendable {
    case down(x: Double, y: Double)
    case move(x: Double, y: Double)
    case up(x: Double, y: Double)
    case tap(x: Double, y: Double, holdMs: Int)
    case edge(FastInputEdgePhase, x: Double, y: Double)
    case button(PhysicalControlButton)
    case appSwitcher
    case hid(page: Int, usage: Int, down: Bool)
    case key(usage: Int, action: FastInputKeyAction)
    /// Printable ASCII only (no newline). Not used by the app (US layout).
    case text(String)
    /// One report with exactly these usages held (none: all up).
    case keys([Int])
    case ping
    case quit

    private static func unit(_ value: Double) -> String {
        String(format: "%.5f", min(max(value, 0), 1))
    }

    /// The line sent to the helper (no newline).
    var line: String {
        switch self {
        case .down(let x, let y): "down \(Self.unit(x)) \(Self.unit(y))"
        case .move(let x, let y): "move \(Self.unit(x)) \(Self.unit(y))"
        case .up(let x, let y): "up \(Self.unit(x)) \(Self.unit(y))"
        case .tap(let x, let y, let hold): "tap \(Self.unit(x)) \(Self.unit(y)) \(min(max(hold, 0), 5000))"
        case .edge(let phase, let x, let y): "edge \(phase.rawValue) \(Self.unit(x)) \(Self.unit(y))"
        case .button(let button): "button \(button.rawValue)"
        case .appSwitcher: "button appSwitcher"
        case .hid(let page, let usage, let down):
            "hid \(String(min(max(page, 1), 0xffff), radix: 16)) \(String(min(max(usage, 1), 0xffff), radix: 16)) \(down ? "down" : "up")"
        case .key(let usage, let action): "key \(min(max(usage, 1), 0xe7)) \(action.rawValue)"
        case .text(let text): "text \(text)"
        case .keys(let usages): (["keys"] + usages.map { String(min(max($0, 1), 0xe7)) }).joined(separator: " ")
        case .ping: "ping"
        case .quit: "quit"
        }
    }

    /// How long a command may take: the answer is immediate except a tap's
    /// hold and a button's short press.
    var answerTimeout: Duration {
        switch self {
        case .tap(_, _, let hold): .milliseconds(6000 + hold)
        case .text(let text): .milliseconds(6000 + 60 * text.count)
        default: .seconds(6)
        }
    }
}

/// One line the helper printed.
enum FastInputReply: Equatable, Sendable {
    case ok
    case err(code: Int, message: String)
    case ready(serviceID: String)
    case fatal(code: Int, message: String)

    /// nil for a line that is not part of the protocol.
    static func parse(_ line: String) -> FastInputReply? {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "ok" { return .ok }
        let parts = text.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        guard let head = parts.first else { return nil }
        switch head {
        case "ready":
            return parts.count >= 2 ? .ready(serviceID: parts[1]) : nil
        case "err", "fatal":
            guard parts.count >= 2, let code = Int(parts[1]) else { return nil }
            let message = parts.count == 3 ? parts[2] : ""
            return head == "err" ? .err(code: code, message: message) : .fatal(code: code, message: message)
        default:
            return nil
        }
    }
}

/// A running child process with a line channel, so tests can stand in for the
/// helper and for the `devicectl` child that holds the tunnel.
public protocol FastInputChild: AnyObject, Sendable {
    /// Lines the child prints on standard output; finishes when it closes.
    var lines: AsyncStream<String> { get }
    var isRunning: Bool { get }
    /// Writes `line` and a newline to the child's standard input.
    func write(_ line: String) throws
    func terminate()
    func kill()
}

/// Starts children. The real one is `ProcessFastInputChildLauncher`.
public protocol FastInputChildLauncher: Sendable {
    /// `wantsLines: false` discards standard output.
    func launch(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        wantsLines: Bool
    ) throws -> any FastInputChild
}

/// Something that holds the phone's CoreDevice tunnel open for a session.
public protocol FastInputLease: Sendable {
    func start() async throws
    func stop() async
    /// Ends the lease at once, from any thread (the app's quit).
    func terminateNow()
}

/// The real sleeper the fast input types default to (tests hand in their own).
public enum FastInputClock {
    public static let sleep: @Sendable (Duration) async throws -> Void = { duration in
        try await Task.sleep(for: duration)
    }
}
