import Foundation
import Security

// The vocabulary of "Control this iPhone": the errors,
// the tunnel endpoint and its token, the phone's screen and the mapping from a
// point of the live picture to a point of the phone. Nothing here touches a
// device, the network or a process.

/// Why the control of a physical iPhone is unavailable, stopped or failed, in
/// words the banner shows. No case carries the phone's UDID, its tunnel
/// address, the token or the signing team: what is kept or shown never
/// names them.
public enum PhysicalControlError: Error, Equatable, Sendable, CustomStringConvertible {
    /// No Apple development team was found for the input runner (no valid
    /// Apple Development certificate in the keychain).
    case noTeam
    /// The device's `details` carry no tunnel address (the phone is not
    /// connected through the CoreDevice tunnel).
    case noTunnelAddress
    /// The address is not the device end of a CoreDevice tunnel (`fd00::/8`):
    /// the Mac never talks to, and never asks the runner to bind, anything
    /// else.
    case notATunnelAddress
    /// A token shorter than 128 bits.
    case tokenTooShort
    /// The Mac could not make a token.
    case tokenUnavailable
    /// The runner's sources (`ios/agent`) are not in this build.
    case runnerSourcesMissing
    /// The runner could not be built and signed; the text is the build's
    /// own error, with the team, the UDID and any address left out.
    case buildFailed(String)
    /// `xcodebuild` could not be started.
    case launchFailed(String)
    /// The runner's process ended (`String` is its last output, redacted).
    case runnerExited(String)
    /// The runner did not answer in time.
    case startTimedOut(seconds: Int)
    /// The session is not started, or not ready.
    case notReady
    /// One action runs and one waits; this would be a third.
    case busy
    /// The runner refused the token (401).
    case unauthorized
    /// The runner answered an action with an error.
    case actionFailed(status: Int, message: String)
    /// Typing was refused: the app shows no keyboard.
    case keyboardNotShowing
    /// No app of the candidate list is in the foreground.
    case noForegroundApp
    /// The connection to the runner failed.
    case transportFailed(String)
    /// The runner answered with something the client cannot read.
    case badResponse(String)
    /// The session was stopped.
    case stopped
    /// The runner ended and was started again; the action that met it was
    /// not repeated.
    case runnerRestarted
    /// The phone or the runner cannot do this action (Siri is not there, no
    /// public route on this model); the runner is fine. The text is what the
    /// user reads.
    case unsupported(String)

    public var description: String {
        switch self {
        case .noTeam:
            return "The standard input runner (Siri and some typing) is unavailable: it needs an Apple Development certificate. Install Xcode and sign in with your Apple ID in Xcode ▸ Settings ▸ Accounts."
        case .noTunnelAddress:
            return "The iPhone's connection has no tunnel address. Reconnect it and try again."
        case .notATunnelAddress:
            return "The iPhone's address is not a CoreDevice tunnel address; control refused."
        case .tokenTooShort, .tokenUnavailable:
            return "The Mac could not make a secure token for the control session."
        case .runnerSourcesMissing:
            return "The iPhone input runner's sources (ios/agent) are not part of this build."
        case .buildFailed(let text):
            return "The input runner could not be built and signed: \(text)"
        case .launchFailed(let text):
            return "The input runner could not be started: \(text)"
        case .runnerExited(let text):
            return "The input runner stopped" + (text.isEmpty ? "." : ": \(text)")
        case .startTimedOut(let seconds):
            return "The input runner did not answer within \(seconds) s. Is the iPhone unlocked?"
        case .notReady:
            return "The iPhone control is not ready."
        case .busy:
            return "The iPhone is still busy with the last action."
        case .unauthorized:
            return "The input runner refused the control token."
        case .actionFailed(_, let message):
            return message.isEmpty ? "The iPhone did not do that." : "The iPhone did not do that: \(message)"
        case .keyboardNotShowing:
            return "No keyboard is showing on the iPhone. Tap a text field first."
        case .noForegroundApp:
            return "Tap a text field first"
        case .transportFailed(let text):
            return "The connection to the input runner failed: \(text)"
        case .badResponse(let text):
            return "The input runner sent an answer Device Hub Pro cannot read: \(text)"
        case .stopped:
            return "The iPhone control was stopped."
        case .runnerRestarted:
            return "The input runner had stopped and was started again. Try again."
        case .unsupported(let text):
            return text
        }
    }

    /// A message for the user that does not end Control: the action was
    /// refused or could not run, but the runner is fine.
    public var isSoft: Bool {
        switch self {
        case .busy, .noForegroundApp, .keyboardNotShowing, .runnerRestarted, .unsupported: true
        default: false
        }
    }
}

/// Text that names the phone, the tunnel or the signing team never reaches a
/// message the app keeps or shows.
enum PhysicalControlRedactor {
    /// `text` with every secret replaced, and cut to the last `limit`
    /// characters.
    static func redact(_ text: String, secrets: [String], limit: Int = 400) -> String {
        var result = text
        for secret in secrets where secret.count >= 4 {
            result = result.replacingOccurrences(of: secret, with: "‹redacted›")
            result = result.replacingOccurrences(of: secret.lowercased(), with: "‹redacted›")
            result = result.replacingOccurrences(of: secret.uppercased(), with: "‹redacted›")
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.count > limit { result = "…" + result.suffix(limit) }
        return result
    }
}

/// The per-launch secret of a control session: at least 128 bits, hex. It
/// travels only in the runner's environment and in the request header; it is
/// never logged, stored or printed (its description is redacted).
public struct PhysicalControlToken: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    /// 32 hex characters are 128 bits.
    public static let minimumLength = 32
    /// Random bytes of a made token (256 bit).
    public static let generatedByteCount = 32

    let value: String

    /// nil for a value that is not at least `minimumLength` hex characters.
    public init?(_ value: String) {
        guard value.count >= Self.minimumLength,
              value.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) || ($0 >= 0x41 && $0 <= 0x46) })
        else { return nil }
        self.value = value
    }

    /// A fresh token from the system's secure random source.
    public static func generate() throws -> PhysicalControlToken {
        var bytes = [UInt8](repeating: 0, count: generatedByteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw PhysicalControlError.tokenUnavailable
        }
        guard let token = PhysicalControlToken(bytes.map { String(format: "%02x", $0) }.joined()) else {
            throw PhysicalControlError.tokenUnavailable
        }
        return token
    }

    public var description: String { "‹token›" }
    public var debugDescription: String { "‹token›" }
}

/// Where the runner listens and what it wants to hear: the device end of the
/// CoreDevice tunnel, on a fixed port, with the launch's token.
///
/// The address must be a unique-local IPv6 address (`fd00::/8`), the family
/// CoreDevice gives its tunnel. Anything else (a Wi-Fi or USB IPv4 address, a
/// link-local or global IPv6 address, a hostname) is refused: there is no
/// fallback to a wider interface, on the Mac's side or in what it asks the
/// runner to bind.
public struct PhysicalControlEndpoint: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public static let defaultPort: UInt16 = 8765

    public let address: String
    public let port: UInt16
    let token: PhysicalControlToken

    public init(
        tunnelAddress: String,
        token: PhysicalControlToken,
        port: UInt16 = PhysicalControlEndpoint.defaultPort
    ) throws {
        guard let canonical = Self.canonicalTunnelAddress(tunnelAddress) else {
            throw PhysicalControlError.notATunnelAddress
        }
        address = canonical
        self.port = port
        self.token = token
    }

    /// The address in its canonical text form when it is a valid IPv6
    /// address whose first byte is 0xFD (`fd00::/8`); nil otherwise.
    public static func canonicalTunnelAddress(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // No brackets, no zone, no prefix: exactly one address.
        guard !trimmed.isEmpty, !trimmed.contains("%"), !trimmed.contains("["), !trimmed.contains("/") else { return nil }
        var address = in6_addr()
        guard inet_pton(AF_INET6, trimmed, &address) == 1 else { return nil }
        let first = withUnsafeBytes(of: &address) { $0[0] }
        guard first == 0xFD else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// `http://[address]:port`
    public var baseURL: URL {
        URL(string: "http://[\(address)]:\(port)")!
    }

    /// The request header that carries the token.
    public static let tokenHeader = "X-DeviceHubPro-Token"

    public var description: String { "PhysicalControlEndpoint(‹tunnel›)" }
    public var debugDescription: String { description }
}

/// The phone's buttons the public XCTest API can press.
public enum PhysicalControlButton: String, Sendable, Equatable, CaseIterable {
    case home
    case volumeUp
    case volumeDown
}

/// A quarter turn of the phone.
public enum PhysicalControlTurn: Sendable, Equatable {
    case left, right
}

/// The runner's orientation values (`UIDeviceOrientation`).
public enum PhysicalControlOrientation: String, Sendable, Equatable, CaseIterable {
    case portrait, portraitUpsideDown, landscapeLeft, landscapeRight, faceUp, faceDown, unknown

    /// Counter-clockwise quarter turns of the Apple chrome for this
    /// orientation, in `AppleChromePose`'s count (landscape left, the top on
    /// the left, is 1); nil where the orientation says nothing about the
    /// screen (flat or unknown).
    public var chromeTurns: Int? {
        switch self {
        case .portrait: 0
        case .landscapeLeft: 1
        case .portraitUpsideDown: 2
        case .landscapeRight: 3
        case .faceUp, .faceDown, .unknown: nil
        }
    }

    /// The orientation a quarter turn from this one reaches: all four poses in
    /// turn, upside down included for every device (Device Hub's Rotate; a
    /// Face ID iPhone keeps its interface at upside down, but the frame and
    /// screen turn). From a flat or unknown pose a turn starts from portrait.
    public func turned(_ direction: PhysicalControlTurn) -> PhysicalControlOrientation {
        let leftTurns: [PhysicalControlOrientation] = [.portrait, .landscapeLeft, .portraitUpsideDown, .landscapeRight]
        let step = direction == .left ? 1 : leftTurns.count - 1
        return leftTurns[((leftTurns.firstIndex(of: self) ?? 0) + step) % leftTurns.count]
    }
}

/// What `GET /screen` says about the phone's screen. The runner's own
/// `UIScreen` bounds are a 320×480 compatibility space and are not used; the
/// portrait size in points is Springboard's frame (390×844 on an iPhone 12),
/// whichever way the phone is held.
public struct PhysicalControlScreen: Sendable, Equatable {
    /// The portrait size in points (width ≤ height).
    public let portraitSize: CGSize
    /// Pixels per point.
    public let scale: Double

    public init(portraitSize: CGSize, scale: Double) {
        self.portraitSize = CGSize(
            width: min(portraitSize.width, portraitSize.height),
            height: max(portraitSize.width, portraitSize.height)
        )
        self.scale = scale
    }

    /// nil when the answer names no usable size.
    init?(json: [String: Any]) {
        func number(_ key: String) -> Double? { (json[key] as? NSNumber)?.doubleValue }
        let width = number("springboardFrameWidth") ?? number("screenshotWidthPoints")
        let height = number("springboardFrameHeight") ?? number("screenshotHeightPoints")
        guard let width, let height, width > 0, height > 0 else { return nil }
        self.init(portraitSize: CGSize(width: width, height: height), scale: number("scale") ?? 1)
    }
}

/// Maps a point of the picture the stage shows to a point of the phone.
///
/// The live capture and the preview deliver the screen as the phone shows it,
/// so a phone held on its side gives a landscape frame. The runner takes
/// coordinates in points, in the interface of the app it resolves them
/// against (the current orientation, origin at the top left), so the
/// interface is the portrait size, swapped when the frame is wider than tall.
public enum PhysicalControlGeometry {
    /// The interface size in points for a frame of `frame` pixels.
    public static func interfaceSize(portrait: CGSize, frame: CGSize) -> CGSize {
        frame.width > frame.height
            ? CGSize(width: portrait.height, height: portrait.width)
            : portrait
    }

    /// The phone point under `framePoint` (pixels of a `frame`-sized
    /// picture); nil for an empty frame. The result is kept inside the
    /// screen.
    public static func point(forFramePoint framePoint: CGPoint, frame: CGSize, portrait: CGSize) -> CGPoint? {
        guard frame.width > 0, frame.height > 0, portrait.width > 0, portrait.height > 0 else { return nil }
        let size = interfaceSize(portrait: portrait, frame: frame)
        let x = framePoint.x / frame.width * size.width
        let y = framePoint.y / frame.height * size.height
        return CGPoint(
            x: min(max(x, 0), size.width - 1),
            y: min(max(y, 0), size.height - 1)
        )
    }
}
