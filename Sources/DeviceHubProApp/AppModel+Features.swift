import AppKit
import Foundation
import DeviceHubProKit

// MARK: - AVD names

/// Live validation of a new AVD name, shared by the create and rename sheets
/// and re-checked by `AppModel.createAvd`. Names are compared ignoring case:
/// macOS volumes are case-insensitive by default, so `Pixel_9` and `pixel_9`
/// are the same `.avd` folder (see `AvdHome`).
enum AvdNameValidation: Equatable {
    case valid
    case empty
    /// The name holds characters avdmanager rejects; `suggestion` is the
    /// sanitized form. The name is never rewritten silently.
    case invalidCharacters(suggestion: String)
    /// An AVD (or an orphaned `.ini`/`.avd` entry) already uses the name.
    case taken(existing: String)

    /// Validates `draft` against `existing` names. `ignoring` is the AVD
    /// being renamed: its own name (in any case) does not count as taken.
    static func validate(
        _ draft: String,
        existing: some Sequence<String>,
        ignoring: String? = nil
    ) -> AvdNameValidation {
        guard !draft.isEmpty else { return .empty }
        let sanitized = AvdmanagerClient.sanitizedAvdName(draft)
        guard sanitized == draft else { return .invalidCharacters(suggestion: sanitized) }
        let wanted = draft.lowercased()
        let ignored = ignoring?.lowercased()
        if let clash = existing.first(where: {
            let name = $0.lowercased()
            return name == wanted && name != ignored
        }) {
            return .taken(existing: clash)
        }
        return .valid
    }

    var isValid: Bool { self == .valid }

    /// The inline message for an invalid name; nil when the name is valid.
    var message: String? {
        switch self {
        case .valid:
            return nil
        case .empty:
            return "Enter a name."
        case .invalidCharacters(let suggestion):
            return "Names may use letters, digits, \".\", \"_\" and \"-\". Suggestion: \"\(suggestion)\"."
        case .taken(let existing):
            return "An AVD named \"\(existing)\" already exists. Choose a different name."
        }
    }
}

// MARK: - Wireless pairing

/// What the Pair Device sheet does after `AppModel.pairWirelessDevice`.
/// Pairing and connecting fail separately: once `adb pair` succeeded the
/// code is spent, so a failed connect must never read as a failed pair.
enum PairingAttemptResult: Equatable {
    /// Paired and connected: the sheet closes.
    case connected
    /// The attempt was abandoned with the sheet: nothing to show.
    case cancelled
    /// Nothing was paired (invalid input, wrong or expired code,
    /// unreachable phone): shown as an error, and Pair can be retried.
    case failed(String)
    /// Paired, but not connected (yet): the sheet switches to connecting to
    /// `host` and shows `message`, which says how.
    case paired(host: String, message: String)

    init(_ outcome: WirelessPairing.Outcome, host: String) {
        switch outcome {
        case .connected:
            self = .connected
        case .pairedAwaitingConnection:
            self = .paired(
                host: host,
                message: "Paired. The phone should appear in the device list shortly; if it doesn't, enter the port shown under Wireless debugging ▸ IP address & Port and press Connect."
            )
        case .pairedConnectFailed(let address, let message):
            self = .paired(
                host: host,
                message: "Paired, but could not connect on \(address): \(message)\nEnter the port shown under Wireless debugging ▸ IP address & Port and press Connect."
            )
        case .pairingFailed(let message):
            self = .failed(message)
        }
    }
}

/// What the Pair Nearby Device sheet does after a QR attempt.
enum QRPairingResult: Equatable {
    /// The sheet or the tab went away: nothing to show.
    case cancelled
    /// The code was not scanned in time: a new code is offered.
    case notScanned
    /// The phone scanned: paired and connected, paired only, or failed.
    case attempt(PairingAttemptResult)
}

// MARK: - Location

/// A latitude/longitude pair typed into the Location sheet. `Double(_:)`
/// alone accepts "nan", "inf" and "1e9": a non-finite preset then made
/// every later preset save fail silently (JSONEncoder throws on it), and an
/// out-of-range fix reached the emulator unchecked. Commas count as decimal
/// points. The one check for every coordinate `LocationController` applies
/// or saves.
enum CoordinateInput: Equatable {
    case valid(latitude: Double, longitude: Double)
    /// A field is still empty: nothing to report yet.
    case incomplete
    case invalid(String)

    init(latitude: String, longitude: String) {
        let latText = Self.normalized(latitude)
        let lngText = Self.normalized(longitude)
        guard !latText.isEmpty, !lngText.isEmpty else {
            self = .incomplete
            return
        }
        guard let lat = Double(latText), lat.isFinite, (-90...90).contains(lat) else {
            self = .invalid("Latitude must be a number from -90 to 90.")
            return
        }
        guard let lng = Double(lngText), lng.isFinite, (-180...180).contains(lng) else {
            self = .invalid("Longitude must be a number from -180 to 180.")
            return
        }
        self = .valid(latitude: lat, longitude: lng)
    }

    var isValid: Bool {
        if case .valid = self { return true }
        return false
    }

    private static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
    }
}
