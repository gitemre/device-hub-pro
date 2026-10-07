import Foundation

// The simctl commands behind a simulator's Controls rows:
// the status bar, location scenarios and routes, privacy, push, the global
// preferences a language or clock change writes, the respring that shows it
// on the home screen, and the boot environment the time zone lives in. The
// answers were captured from CoreSimulator 1171.7 (Xcode 27.0 27A266a) on an
// iOS 27.0 simulator (`Fixtures/ios27-simulator/controls/`,
// `SimctlControlsTests`).

/// A permission `simctl privacy` changes (its help's list; `all` is not
/// offered: `SimctlClient` refuses the word, so a reset goes service by
/// service). simctl validates nothing: an unknown bundle gets a TCC row,
/// an unknown service is refused with "Failed to create TCC authorization
/// record" (exit 1).
public enum SimulatorPrivacyService: String, Sendable, CaseIterable, Identifiable {
    case calendar
    case contactsLimited = "contacts-limited"
    case contacts
    case location
    case locationAlways = "location-always"
    case photosAdd = "photos-add"
    case photos
    case mediaLibrary = "media-library"
    case microphone
    case motion
    case reminders
    case siri

    public var id: String { rawValue }

    /// The name iOS's Settings uses.
    public var title: String {
        switch self {
        case .calendar: "Calendars"
        case .contactsLimited: "Contacts (limited)"
        case .contacts: "Contacts"
        case .location: "Location (while using)"
        case .locationAlways: "Location (always)"
        case .photosAdd: "Photos (add only)"
        case .photos: "Photos"
        case .mediaLibrary: "Media & Apple Music"
        case .microphone: "Microphone"
        case .motion: "Motion & Fitness"
        case .reminders: "Reminders"
        case .siri: "Siri"
        }
    }
}

/// What `simctl privacy` does to a permission.
public enum SimulatorPrivacyAction: String, Sendable, CaseIterable {
    /// Allowed without asking.
    case grant
    /// Denied.
    case revoke
    /// Undecided again: the app asks on its next use.
    case reset
}

/// A value `defaults write -g` stores inside the simulator.
public enum SimulatorDefaultsValue: Sendable, Equatable {
    case bool(Bool)
    case string(String)
    case stringArray([String])

    var arguments: [String] {
        switch self {
        case .bool(let value): return ["-bool", value ? "true" : "false"]
        case .string(let value): return ["-string", value]
        case .stringArray(let values): return ["-array"] + values
        }
    }
}

extension SimctlClient {
    // MARK: status_bar

    /// Overrides the status bar with every field of `state` in one call.
    /// simctl applies its flags per field group and one group can reset
    /// another (`--wifiMode` alone put the bars back to 3), so Device Hub Pro
    /// always sends the whole set and keeps the state itself: `list` answers
    /// in numeric codes that cannot tell every value apart.
    public func overrideStatusBar(udid: String, _ state: SimulatorStatusBarState) async throws {
        try Self.validateUDID(udid)
        try state.validate()
        let arguments = ["status_bar", udid, "override"] + state.overrideArguments
        // The operator name is free text (a carrier may be called "All").
        let operatorIndex = arguments.firstIndex(of: "--operatorName").map { $0 + 1 }
        try await checked(arguments, freeText: operatorIndex.map { [$0] } ?? [])
    }

    // MARK: location

    /// Runs one of `location list`'s scenarios ("City Run", "Freeway Drive"…).
    /// An unknown name exits 1.
    public func runLocationScenario(udid: String, name: String) async throws {
        try Self.validateUDID(udid)
        guard !name.isEmpty, !name.hasPrefix("-") else {
            throw SimctlClientError.invalidValue("location scenario '\(name)'")
        }
        try await checked(["location", udid, "run", name], freeText: [3])
    }

    /// Moves along `waypoints` at `speed` m/s with an update every
    /// `interval` s (`location start`; simctl wants at least two waypoints,
    /// exit 22 otherwise, and prints "Parsed N waypoints" on stderr).
    public func startLocationRoute(
        udid: String,
        waypoints: [(latitude: Double, longitude: Double)],
        speed: Double = 20,
        interval: Double = 1
    ) async throws {
        try Self.validateUDID(udid)
        guard waypoints.count >= 2 else {
            throw SimctlClientError.invalidValue("a route needs at least two waypoints")
        }
        guard speed > 0, interval > 0 else {
            throw SimctlClientError.invalidValue("route speed \(speed), interval \(interval)")
        }
        var pairs: [String] = []
        for point in waypoints {
            guard (-90...90).contains(point.latitude), (-180...180).contains(point.longitude) else {
                throw SimctlClientError.invalidValue("waypoint \(point.latitude),\(point.longitude) is out of range")
            }
            pairs.append(Self.coordinate(point.latitude, point.longitude))
        }
        let arguments = ["location", udid, "start", "--speed=\(Self.number(speed))", "--interval=\(Self.number(interval))"]
        try await checked(arguments + pairs)
    }

    /// Stops any scenario or route and clears the simulated location.
    public func clearLocation(udid: String) async throws {
        try Self.validateUDID(udid)
        try await checked(["location", udid, "clear"])
    }

    // MARK: privacy

    /// `privacy <udid> <action> <service> <bundle>`. simctl's help warns that
    /// some changes end the app if it runs (measured: granting photos ends it).
    public func setPrivacy(
        udid: String,
        _ action: SimulatorPrivacyAction,
        service: SimulatorPrivacyService,
        bundleIdentifier: String
    ) async throws {
        try Self.validateUDID(udid)
        try Self.validateBundleIdentifier(bundleIdentifier)
        try await checked(["privacy", udid, action.rawValue, service.rawValue, bundleIdentifier])
    }

    // MARK: push

    /// Sends `payload` (a checked `SimulatorPushPayload`) to the app, on
    /// standard input. simctl answers "Notification sent to '<bundle>'";
    /// an app that never asked to post notifications gets `UNErrorDomain`
    /// 2003 ("Source is not authorized", exit 211), although the app in
    /// front still receives it.
    @discardableResult
    public func push(udid: String, bundleIdentifier: String, payload: SimulatorPushPayload) async throws -> String {
        try Self.validateUDID(udid)
        try Self.validateBundleIdentifier(bundleIdentifier)
        let output = try await checked(["push", udid, bundleIdentifier, "-"], standardInput: payload.data)
        return output.standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: global preferences

    /// `spawn <udid> defaults write -g <key> <value>`: what a language or
    /// clock change writes, inside the simulator (its `cfprefsd` writes the
    /// host's `.GlobalPreferences.plist` at once, which is where the Controls
    /// read it back without a spawn).
    public func writeGlobalDefault(udid: String, key: String, _ value: SimulatorDefaultsValue) async throws {
        try Self.validateUDID(udid)
        try Self.validateDefaultsKey(key)
        let arguments = ["spawn", udid, "defaults", "write", "-g", key] + value.arguments
        // The values are data (a language list, a locale), never selectors.
        try await checked(arguments, freeText: Set(6..<arguments.count))
    }

    /// `spawn <udid> defaults delete -g <key>`; a key that is not there
    /// counts as deleted.
    public func deleteGlobalDefault(udid: String, key: String) async throws {
        try Self.validateUDID(udid)
        try Self.validateDefaultsKey(key)
        let arguments = ["spawn", udid, "defaults", "delete", "-g", key]
        let output = try await run(arguments)
        guard output.exitCode != 0 else { return }
        // `defaults` exits 1 when the key (or the domain) is missing.
        let message = output.standardErrorText
        if output.exitCode == 1, message.contains("not found") || message.contains("Could not find") {
            return
        }
        throw SimctlErrors.failure(arguments: arguments, exitCode: output.exitCode, standardError: message)
    }

    /// The label a respring restarts: SpringBoard's job in the simulator's
    /// foreground user domain (the `system/` label works too but warns
    /// "Please switch to user/foreground/com.apple.SpringBoard").
    public static let springBoardService = "user/foreground/com.apple.SpringBoard"

    /// Restarts SpringBoard (`spawn <udid> launchctl kickstart -k …`): the
    /// home screen, the status bar and alerts pick up a new language. The
    /// home screen is back about 7 s later; apps keep running.
    public func respring(udid: String) async throws {
        try Self.validateUDID(udid)
        try await checked(["spawn", udid, "launchctl", "kickstart", "-k", Self.springBoardService])
    }

    // MARK: boot environment

    /// A variable of the running boot's environment (`getenv <udid> <name>`),
    /// nil when it is not set: simctl prints "'<name>' not found" on stderr
    /// and still exits 0. The time zone a boot took from `SIMCTL_CHILD_TZ`
    /// reads back as `TZ`.
    public func environmentVariable(udid: String, name: String) async throws -> String? {
        try Self.validateUDID(udid)
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
            throw SimctlClientError.invalidValue("environment variable '\(name)'")
        }
        let output = try await checked(["getenv", udid, name])
        let value = output.standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    // MARK: Checks

    static func validateDefaultsKey(_ key: String) throws {
        guard !key.isEmpty, !key.hasPrefix("-"), key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." })
        else {
            throw SimctlClientError.invalidValue("defaults key '\(key)'")
        }
    }

    /// `lat,lon` with a point, six decimals, as `location set` takes it.
    static func coordinate(_ latitude: Double, _ longitude: Double) -> String {
        String(format: "%.6f,%.6f", locale: Locale(identifier: "en_US_POSIX"), latitude, longitude)
    }

    static func number(_ value: Double) -> String {
        if value == value.rounded() { return String(Int(value)) }
        return String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

extension SimctlFailure {
    /// `simctl push` to an app that never asked to post notifications:
    /// `UNErrorDomain` 2003, "Source is not authorized" (exit 211). The app
    /// in front still receives the push (measured with the verifier).
    public var isPushNotAuthorized: Bool {
        error == SimctlErrorReference(domain: "UNErrorDomain", code: 2003)
            || underlying.contains(SimctlErrorReference(domain: "UNErrorDomain", code: 2003))
    }
}
