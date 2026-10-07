import Foundation

// A simulator's Controls: what each row changes, through which
// mechanism, how the change reaches the simulator (`RowSupport`), and the
// poll's budget of one spawn per tick. UI-free; the app's
// `AppleControlsController` drives it and `AppleControlsBackend` runs it.

/// How a Controls row's change reaches the device.
public enum RowSupport: Equatable, Sendable {
    /// At once, for the system and the apps.
    case live
    /// Apps use it when they relaunch.
    case relaunchApp
    /// Apps when they relaunch; the home screen and the status bar after a
    /// respring (SpringBoard restarted).
    case respring
    /// When the device boots: the simulators Device Hub Pro starts or restarts.
    case reboot
    /// Drawn only (the status bar): apps keep reading the real values.
    case cosmetic
    /// Not offered; the reason says why. Rows that are unavailable are hidden.
    case unavailable(String)

    public var isOffered: Bool {
        if case .unavailable = self { return false }
        return true
    }

    public var unavailableReason: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}

/// The kinds of mechanism a Controls row can go through. The
/// Android rows use `adb` and `emulatorGrpc` (their own controllers); a
/// simulator's use the other three.
public enum ControlMechanismKind: String, Sendable, CaseIterable {
    case adb
    case emulatorGrpc
    /// A documented simctl command.
    case simctl
    /// CoreDevice's versioned JSON interface (T2: devicectl answered for a
    /// default-set simulator).
    case devicectl
    /// simctl running a tool inside the simulator (`spawn defaults`,
    /// `notifyutil`, `launchctl`) for behaviour Apple does not document;
    /// the manifest marks such rows `privateApi`.
    case simUndocumented
}

/// One way to change a row: what runs it, whether it can read the value back
/// and how the change lands.
public protocol ControlMechanism: Sendable {
    var kind: ControlMechanismKind { get }
    var support: RowSupport { get }
    var readsBack: Bool { get }
}

public struct AppleControlMechanism: ControlMechanism, Equatable {
    public let kind: ControlMechanismKind
    public let support: RowSupport
    public let readsBack: Bool
    /// What it runs, for the row's help.
    public let command: String

    public init(_ kind: ControlMechanismKind, _ support: RowSupport, readsBack: Bool, command: String) {
        self.kind = kind
        self.support = support
        self.readsBack = readsBack
        self.command = command
    }
}

/// A simulator control, one per iOS Controls row that changes something
/// (the app maps each to its `ControlsRow`s).
public enum AppleControl: String, Sendable, CaseIterable {
    case appearance
    case liquidGlass
    case textSize
    case reduceMotion
    case showBorders
    case reduceTransparency
    case volume
    case voiceOver
    case colorFilter
    case increaseContrast
    case location
    case orientation
    case biometrics
    case memoryWarning
    case push
    case permissions
    case openURL
    case clipboard
    case language
    case timeFormat24
    case timeZone
    case statusBar
}

/// Where a control goes: the mechanism chosen for this simulator and how
/// its change lands, or why it is not offered.
public struct AppleControlRoute: Equatable, Sendable {
    public let control: AppleControl
    public let mechanism: AppleControlMechanism?
    public let support: RowSupport

    public var isOffered: Bool { mechanism != nil && support.isOffered }

    public init(control: AppleControl, mechanism: AppleControlMechanism?, support: RowSupport) {
        self.control = control
        self.mechanism = mechanism
        self.support = support
    }
}

/// Each control's mechanisms in order of preference, and the choice for a
/// simulator. A mechanism that can read the value back is preferred over one
/// that cannot; among equals the list's order decides.
public enum AppleControlsRouting {
    /// Why a devicectl-only row is hidden without T2.
    public static let devicectlUnavailable =
        "Needs devicectl (Xcode 27's CoreDevice), which has not answered for this simulator; a simulator in a private device set is never reachable."

    /// Measured on CoreDevice 642.16 with iOS 27.0 (twice in,
    /// again in step 2 with the pid `simctl launch` printed): devicectl
    /// answers success and the app receives nothing.
    public static let memoryWarningUnavailable =
        "devicectl process sendMemoryWarning answers success on a simulator, but the app receives no memory warning (CoreDevice 642.16)."

    public static func mechanisms(for control: AppleControl) -> [AppleControlMechanism] {
        switch control {
        case .appearance:
            return [
                .init(.devicectl, .live, readsBack: true, command: "devicectl device settings appearance --mode"),
                .init(.simctl, .live, readsBack: true, command: "simctl ui appearance"),
            ]
        case .liquidGlass:
            return [.init(.devicectl, .live, readsBack: true, command: "devicectl device settings appearance --liquid-glass-opacity")]
        case .textSize:
            // One simctl call sets any of the twelve sizes (and turns Larger
            // Accessibility Sizes on for an accessibility size, measured);
            // devicectl refuses those until Larger Accessibility Sizes is on
            // (21063), a second call that changes another setting.
            return [
                .init(.simctl, .live, readsBack: true, command: "simctl ui content_size"),
                .init(.devicectl, .live, readsBack: true, command: "devicectl device settings appearance --text-size"),
            ]
        case .reduceMotion:
            return [.init(.devicectl, .live, readsBack: true, command: "devicectl device settings appearance --reduce-motion")]
        case .showBorders:
            return [.init(.devicectl, .live, readsBack: true, command: "devicectl device settings appearance --show-borders")]
        case .reduceTransparency:
            return [.init(.devicectl, .live, readsBack: true, command: "devicectl device settings appearance --reduce-transparency")]
        case .volume:
            return [.init(.devicectl, .live, readsBack: true, command: "devicectl device settings audio --volume")]
        case .voiceOver:
            return [.init(.devicectl, .live, readsBack: true, command: "devicectl device settings voiceover")]
        case .colorFilter:
            return [.init(.devicectl, .live, readsBack: true, command: "devicectl device settings appearance --color-filter-type")]
        case .increaseContrast:
            return [
                .init(.simctl, .live, readsBack: true, command: "simctl ui increase_contrast"),
                .init(.devicectl, .live, readsBack: true, command: "devicectl device settings appearance --increase-contrast"),
            ]
        case .location:
            return [.init(.simctl, .live, readsBack: false, command: "simctl location set|run|start|clear")]
        case .orientation:
            return [.init(.devicectl, .live, readsBack: true, command: "devicectl device orientation set")]
        case .biometrics:
            return [.init(.devicectl, .live, readsBack: true, command: "devicectl device settings|simulate biometrics")]
        case .memoryWarning:
            return [.init(.devicectl, .unavailable(memoryWarningUnavailable), readsBack: false, command: "devicectl device process sendMemoryWarning --pid")]
        case .push:
            return [.init(.simctl, .live, readsBack: false, command: "simctl push")]
        case .permissions:
            return [.init(.simctl, .relaunchApp, readsBack: false, command: "simctl privacy")]
        case .openURL:
            return [.init(.simctl, .live, readsBack: false, command: "simctl openurl")]
        case .clipboard:
            return [.init(.simctl, .live, readsBack: true, command: "simctl pbcopy|pbpaste")]
        case .language:
            return [.init(.simUndocumented, .respring, readsBack: true, command: "simctl spawn defaults write -g AppleLanguages/AppleLocale")]
        case .timeFormat24:
            return [.init(.simUndocumented, .live, readsBack: true, command: "simctl spawn defaults write -g AppleICUForce24HourTime + notifyutil")]
        case .timeZone:
            return [.init(.simctl, .reboot, readsBack: true, command: "SIMCTL_CHILD_TZ at simctl boot")]
        case .statusBar:
            return [.init(.simctl, .cosmetic, readsBack: true, command: "simctl status_bar override")]
        }
    }

    /// The route for `control` given the mechanism kinds this simulator
    /// offers (simctl and simUndocumented at T1, devicectl too at T2).
    public static func route(_ control: AppleControl, available: Set<ControlMechanismKind>) -> AppleControlRoute {
        let candidates = mechanisms(for: control)
        let offered = candidates.filter { available.contains($0.kind) && $0.support.isOffered }
        if let chosen = offered.first(where: \.readsBack) ?? offered.first {
            return AppleControlRoute(control: control, mechanism: chosen, support: chosen.support)
        }
        // A mechanism that is itself unavailable (the memory warning) says
        // the truer reason than "not reachable".
        if let declared = candidates.first(where: { !$0.support.isOffered }) {
            return AppleControlRoute(control: control, mechanism: nil, support: declared.support)
        }
        let needsDevicectl = candidates.contains { $0.kind == .devicectl }
        return AppleControlRoute(
            control: control,
            mechanism: nil,
            support: .unavailable(needsDevicectl ? devicectlUnavailable : "No mechanism reaches this simulator.")
        )
    }

    /// The mechanism kinds a simulator offers.
    public static func available(devicectl: Bool) -> Set<ControlMechanismKind> {
        devicectl ? [.simctl, .simUndocumented, .devicectl] : [.simctl, .simUndocumented]
    }
}

/// What one poll tick may read with a spawn. The Controls poll every 2 s
/// and spend at most one process per tick; host-file reads
/// (the global preferences) cost none and run every tick.
public enum AppleControlsRead: String, Sendable, Equatable, CaseIterable {
    /// `devicectl device info appearance`: every appearance field in one read.
    case devicectlAppearance
    case devicectlVoiceOver
    case devicectlAudio
    case devicectlBiometrics
    case devicectlOrientation
    /// T1 (no devicectl): `simctl ui` one option per read.
    case simctlAppearance
    case simctlContentSize
    case simctlIncreaseContrast
}

public enum AppleControlsPollPlan {
    /// The poll's beat, the Android panel's.
    public static let interval: Duration = .seconds(2)

    /// The reads devicectl's secondary rows take, one per odd tick in turn.
    public static let devicectlSecondary: [AppleControlsRead] = [
        .devicectlVoiceOver, .devicectlAudio, .devicectlBiometrics, .devicectlOrientation,
    ]

    public static let simctlReads: [AppleControlsRead] = [
        .simctlAppearance, .simctlContentSize, .simctlIncreaseContrast,
    ]

    /// The one spawn of tick `tick` (0-based). With devicectl, the even
    /// ticks read every appearance field (`info appearance`), and the odd
    /// ones VoiceOver, the audio, biometrics and the orientation in turn;
    /// without it, simctl's three `ui` reads take turns.
    public static func read(forTick tick: Int, devicectl: Bool) -> AppleControlsRead {
        let tick = max(0, tick)
        if devicectl {
            if tick % 2 == 0 { return .devicectlAppearance }
            return devicectlSecondary[(tick / 2) % devicectlSecondary.count]
        }
        return simctlReads[tick % simctlReads.count]
    }

    /// The reads an attach makes before the poll starts (each row gets a
    /// value at once; this is the one burst above the budget).
    public static func initialReads(devicectl: Bool) -> [AppleControlsRead] {
        devicectl ? [.devicectlAppearance] + devicectlSecondary : simctlReads
    }
}

/// A push payload checked the way simctl checks it: a JSON object with an
/// `aps` key, at most 4096 bytes (simctl: exit 22 "missing the aps key",
/// exit 28 "Payload too large").
public struct SimulatorPushPayload: Sendable, Equatable {
    public static let maximumBytes = 4096

    public let data: Data

    public enum Problem: Error, Equatable, CustomStringConvertible {
        case empty
        case notJSON(String)
        case notAnObject
        case missingAPS
        case tooLarge(bytes: Int)

        public var description: String {
            switch self {
            case .empty: "Write a JSON payload first."
            case .notJSON(let detail): "The payload is not JSON: \(detail)"
            case .notAnObject: "The payload must be a JSON object ({…})."
            case .missingAPS: "The payload needs an \"aps\" object, as Apple's push service expects."
            case .tooLarge(let bytes): "The payload is \(bytes) bytes; a push takes at most \(SimulatorPushPayload.maximumBytes)."
            }
        }
    }

    /// Checks `text` (sent as typed, UTF-8).
    public init(_ text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Problem.empty }
        let data = Data(trimmed.utf8)
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw Problem.notJSON((error as NSError).userInfo["NSDebugDescription"] as? String ?? "\(error)")
        }
        guard let dictionary = object as? [String: Any] else { throw Problem.notAnObject }
        guard dictionary["aps"] is [String: Any] else { throw Problem.missingAPS }
        guard data.count <= Self.maximumBytes else { throw Problem.tooLarge(bytes: data.count) }
        self.data = data
    }

    /// The composer's starting text.
    public static let template = """
    {
      "aps": {
        "alert": {
          "title": "Device Hub Pro",
          "body": "A test notification"
        },
        "badge": 1,
        "sound": "default"
      }
    }
    """
}

/// The simulator's global preferences as its `.GlobalPreferences.plist`
/// holds them on the Mac (`<data>/Library/Preferences/`): read without a
/// spawn. The simulator's `cfprefsd` writes the file as soon as a `defaults
/// write` inside it returns (measured on iOS 27.0).
public struct SimulatorGlobalPreferences: Sendable, Equatable {
    /// `AppleLanguages`, most preferred first ("tr-TR").
    public var languages: [String]
    /// `AppleLocale` ("tr_TR").
    public var locale: String?
    public var force24Hour: Bool
    public var force12Hour: Bool

    public init(languages: [String] = [], locale: String? = nil, force24Hour: Bool = false, force12Hour: Bool = false) {
        self.languages = languages
        self.locale = locale
        self.force24Hour = force24Hour
        self.force12Hour = force12Hour
    }

    /// The clock setting: 24 wins when both keys are set, as iOS's own
    /// switch never leaves both on.
    public var timeFormat: TimeFormatSetting {
        if force24Hour { return .twentyFourHour }
        if force12Hour { return .twelveHour }
        return .localeDefault
    }

    /// Whether the simulator's clock shows 24-hour time: the explicit
    /// override when there is one, else the clock of its locale (`AppleLocale`;
    /// a simulator without the key inherits the Mac's region, `fallback`).
    public func uses24HourClock(fallback: Locale = .current) -> Bool {
        switch timeFormat {
        case .twentyFourHour: return true
        case .twelveHour: return false
        case .localeDefault:
            let resolved = locale.map { Locale(identifier: $0) } ?? fallback
            let pattern = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: resolved) ?? ""
            var inQuote = false
            for character in pattern {
                if character == "'" { inQuote.toggle(); continue }
                if !inQuote, character == "H" || character == "k" { return true }
            }
            return false
        }
    }

    /// The file inside a device's data folder.
    public static func fileURL(dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent("Library/Preferences/.GlobalPreferences.plist")
    }

    public static func parse(_ data: Data) throws -> SimulatorGlobalPreferences {
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw SimctlParsing.ParseError.notAPropertyList("the global preferences are not a dictionary")
        }
        return SimulatorGlobalPreferences(
            languages: plist["AppleLanguages"] as? [String] ?? [],
            locale: plist["AppleLocale"] as? String,
            force24Hour: (plist["AppleICUForce24HourTime"] as? Bool) ?? false,
            force12Hour: (plist["AppleICUForce12HourTime"] as? Bool) ?? false
        )
    }

    /// Reads the file; nil when it is not there yet (a device that never booted).
    public static func read(dataDirectory: URL) throws -> SimulatorGlobalPreferences? {
        let url = fileURL(dataDirectory: dataDirectory)
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        return try parse(data)
    }

    /// The keys a clock change writes (`true`) and deletes (`nil`).
    public static func timeFormatWrites(_ setting: TimeFormatSetting) -> [(key: String, value: Bool?)] {
        switch setting {
        case .localeDefault: [("AppleICUForce24HourTime", nil), ("AppleICUForce12HourTime", nil)]
        case .twelveHour: [("AppleICUForce24HourTime", nil), ("AppleICUForce12HourTime", true)]
        case .twentyFourHour: [("AppleICUForce12HourTime", nil), ("AppleICUForce24HourTime", true)]
        }
    }

    /// The notification that makes running processes (the status bar
    /// included) read the clock keys again: the change is live with it,
    /// and waits for a relaunch or respring without it (measured).
    public static let timeFormatChangedNotification = "AppleTimePreferencesChangedNotification"

    /// `AppleLocale` for a language tag: "tr-TR" → "tr_TR", "zh-Hans-CN" → "zh_CN"
    /// (the region form iOS writes); nil for a tag without a region.
    public static func localeIdentifier(for locale: DeviceLocale) -> String? {
        guard let region = locale.region else { return nil }
        return "\(locale.language)_\(region)"
    }
}
