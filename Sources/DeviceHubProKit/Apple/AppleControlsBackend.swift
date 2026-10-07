import Foundation

/// One change a simulator's Controls make.
public enum AppleControlChange: Sendable, Equatable {
    case appearance(dark: Bool)
    case liquidGlassOpacity(Double)
    /// Clear or Tinted (an iOS 26 simulator).
    case lookAndFeel(DevicectlLookAndFeel)
    case textSize(SimulatorContentSize)
    /// Larger Accessibility Sizes alone (devicectl only); a text size from the
    /// accessibility range turns it on, and nothing turns it off again but this.
    case largerAccessibilitySizes(Bool)
    case reduceMotion(Bool)
    case showBorders(Bool)
    case reduceTransparency(Bool)
    case volume(Int)
    /// The Sound card's Output and Input popups (`--output-device`,
    /// `--input-device`); they share the volume's control.
    case audioOutput(DevicectlAudioDevice)
    case audioInput(DevicectlAudioDevice)
    case voiceOver(Bool)
    /// nil turns the filter off; the intensity applies to every type but Grayscale.
    case colorFilter(SimulatorColorFilterType?, intensity: Double?)
    case increaseContrast(Bool)
    case location(latitude: Double, longitude: Double)
    case locationScenario(String)
    case locationRoute([SimulatorWaypoint], speed: Double)
    case clearLocation
    case orientation(SimulatorDevicePose)
    case biometricsEnrolled(Bool)
    case biometricMatch(success: Bool)
    case push(bundleIdentifier: String, payload: SimulatorPushPayload)
    case privacy(SimulatorPrivacyAction, SimulatorPrivacyService, bundleIdentifier: String)
    case openURL(URL)
    case pasteboard(String)
    /// The language and the region that goes with it (`AppleLanguages`, `AppleLocale`).
    case language(DeviceLocale)
    case timeFormat(TimeFormatSetting)
    /// nil clears the override.
    case statusBar(SimulatorStatusBarState?)
    /// Restarts SpringBoard (the language's home screen part).
    case respring

    /// The control whose route the change takes.
    public var control: AppleControl {
        switch self {
        case .appearance: .appearance
        case .liquidGlassOpacity, .lookAndFeel: .liquidGlass
        case .textSize, .largerAccessibilitySizes: .textSize
        case .reduceMotion: .reduceMotion
        case .showBorders: .showBorders
        case .reduceTransparency: .reduceTransparency
        case .volume, .audioOutput, .audioInput: .volume
        case .voiceOver: .voiceOver
        case .colorFilter: .colorFilter
        case .increaseContrast: .increaseContrast
        case .location, .locationScenario, .locationRoute, .clearLocation: .location
        case .orientation: .orientation
        case .biometricsEnrolled, .biometricMatch: .biometrics
        case .push: .push
        case .privacy: .permissions
        case .openURL: .openURL
        case .pasteboard: .clipboard
        case .language, .respring: .language
        case .timeFormat: .timeFormat24
        case .statusBar: .statusBar
        }
    }
}

/// A point of a location route.
public struct SimulatorWaypoint: Sendable, Equatable, Codable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// What one read (a poll tick's spawn, or a write's own answer) said.
public enum AppleControlsReading: Sendable, Equatable {
    /// devicectl's appearance, whole (`info appearance`) or the fields a
    /// `settings appearance` call touched.
    case appearance(DevicectlAppearance)
    case simctlAppearance(SimulatorAppearance)
    case contentSize(SimulatorContentSize)
    case increaseContrast(SimulatorIncreaseContrast)
    case voiceOver(Bool)
    case volume(Int)
    /// The whole audio answer: volume and the pinned devices.
    case audio(DevicectlAudio)
    case biometrics(DevicectlBiometrics)
    case orientation(DevicectlOrientation)
}

public enum AppleControlsError: Error, Equatable, CustomStringConvertible {
    case unavailable(AppleControl, String)

    public var description: String {
        switch self {
        case .unavailable(_, let reason): reason
        }
    }
}

/// Everything the Controls know about one simulator, merged from readings.
/// nil is "not read yet" (a row shows no value and stays disabled).
public struct AppleControlsState: Sendable, Equatable {
    public var dark: Bool?
    public var textSize: SimulatorContentSize?
    public var increaseContrast: Bool?
    public var reduceMotion: Bool?
    public var reduceTransparency: Bool?
    public var showBorders: Bool?
    /// `.some(nil)` is a filter that is off.
    public var colorFilter: SimulatorColorFilterType??
    public var colorFilterIntensity: Double?
    public var largerAccessibilitySizes: Bool?
    public var liquidGlassOpacity: Double?
    /// The look on an iOS 26 simulator; nil where the runtime lists none of ours.
    public var lookAndFeel: DevicectlLookAndFeel?
    public var supportedLooks: [DevicectlLookAndFeel] = []
    public var volume: Int?
    /// The Mac devices the simulator's sound goes out to and comes in from.
    public var audioOutput: DevicectlAudioDevice?
    public var audioInput: DevicectlAudioDevice?
    public var voiceOver: Bool?
    /// "Face ID", "Touch ID", "Optic ID"; nil until read.
    public var biometricType: String?
    public var biometricsEnrolled: Bool?
    /// Whether the device supports any biometrics (false: an answer with none).
    public var supportsBiometrics: Bool?
    public var pose: SimulatorDevicePose?
    public var preferences: SimulatorGlobalPreferences?

    public init() {}

    /// Merges a reading: a partial devicectl answer changes only the fields
    /// it carries.
    public mutating func apply(_ reading: AppleControlsReading) {
        switch reading {
        case .appearance(let answer):
            if let style = answer.userInterfaceStyle { dark = style == "dark" }
            if let size = answer.contentSize { textSize = size }
            if let value = answer.increaseContrast { increaseContrast = value }
            if let value = answer.reduceMotion { reduceMotion = value }
            if let value = answer.reduceTransparency { reduceTransparency = value }
            if let value = answer.showBorders { showBorders = value }
            if let value = answer.largerAccessibilitySizesEnabled { largerAccessibilitySizes = value }
            if let value = answer.liquidGlassOpacity { liquidGlassOpacity = value }
            if let look = answer.lookSelection { lookAndFeel = look }
            if !answer.supportedLooks.isEmpty { supportedLooks = answer.supportedLooks }
            if let enabled = answer.colorFilter {
                colorFilter = .some(enabled ? answer.colorFilterSelection : nil)
                if let intensity = answer.colorFilterIntensity { colorFilterIntensity = intensity }
            }
        case .simctlAppearance(let appearance):
            switch appearance {
            case .dark: dark = true
            case .light: dark = false
            case .unsupported, .unknown: dark = nil
            }
        case .contentSize(let size):
            textSize = SimulatorContentSize.settable.contains(size) ? size : nil
        case .increaseContrast(let value):
            switch value {
            case .enabled: increaseContrast = true
            case .disabled: increaseContrast = false
            case .unsupported, .unknown: increaseContrast = nil
            }
        case .voiceOver(let enabled):
            voiceOver = enabled
        case .volume(let level):
            volume = level
        case .audio(let answer):
            if let level = answer.volume { volume = level }
            if let output = answer.outputDevice { audioOutput = output }
            if let input = answer.inputDevice { audioInput = input }
        case .biometrics(let answer):
            biometricType = answer.primaryType
            supportsBiometrics = answer.primaryType != nil
            biometricsEnrolled = answer.isEnrolled
        case .orientation(let answer):
            if let name = answer.deviceOrientation, let pose = SimulatorDevicePose(devicectlName: name) {
                self.pose = pose
            } else if answer.deviceOrientation == "unknown" {
                // An iPhone that never rotated reports unknown: upright.
                self.pose = .portrait
            }
        }
    }
}

/// Runs a simulator's Controls: routes each change through the mechanism
/// `AppleControlsRouting` picks for it (devicectl at T2, else simctl) and
/// makes the poll's reads. Every call names the simulator's UDID; devicectl
/// is only ever the client `AppleToolchain.makeDevicectlClient(for:)` made
/// for this listed simulator.
public final class AppleControlsBackend: AppleControlsBacking {
    public let udid: String
    public let simctl: SimctlClient
    public let devicectl: DevicectlClient?
    /// The device's data folder on the Mac (`SimulatorDevice.dataPath`), for
    /// the global preferences; nil reads none.
    public let dataDirectory: URL?

    public init(udid: String, simctl: SimctlClient, devicectl: DevicectlClient?, dataDirectory: URL?) throws {
        try SimctlClient.validateUDID(udid)
        if let devicectl, devicectl.udid != udid {
            throw DevicectlClientError.notASimulator(devicectl.udid)
        }
        self.udid = udid
        self.simctl = simctl
        self.devicectl = devicectl
        self.dataDirectory = dataDirectory
    }

    public var hasDevicectl: Bool { devicectl != nil }

    public var available: Set<ControlMechanismKind> {
        AppleControlsRouting.available(devicectl: hasDevicectl)
    }

    public func route(_ control: AppleControl) -> AppleControlRoute {
        AppleControlsRouting.route(control, available: available)
    }

    // MARK: AppleControlsBacking

    public var deviceIdentifier: String { udid }
    public var pollInterval: Duration { AppleControlsPollPlan.interval }

    public func initialReads() -> [AppleControlsRead] {
        AppleControlsPollPlan.initialReads(devicectl: hasDevicectl)
    }

    public func pollRead(forTick tick: Int) -> AppleControlsRead? {
        AppleControlsPollPlan.read(forTick: tick, devicectl: hasDevicectl)
    }

    // MARK: Reads

    public func read(_ read: AppleControlsRead) async throws -> AppleControlsReading {
        switch read {
        case .devicectlAppearance:
            return .appearance(try await requireDevicectl().appearance().value)
        case .devicectlVoiceOver:
            return .voiceOver(try await requireDevicectl().voiceOver().value.enabled)
        case .devicectlAudio:
            let audio = try await requireDevicectl().audio().value
            guard audio.volume != nil else {
                throw SimctlClientError.unexpectedOutput(command: "devicectl device info audio", detail: "no volume")
            }
            return .audio(audio)
        case .devicectlBiometrics:
            return .biometrics(try await requireDevicectl().biometrics().value)
        case .devicectlOrientation:
            return .orientation(try await requireDevicectl().orientation().value)
        case .simctlAppearance:
            return .simctlAppearance(try await simctl.appearance(udid: udid))
        case .simctlContentSize:
            return .contentSize(try await simctl.contentSize(udid: udid))
        case .simctlIncreaseContrast:
            return .increaseContrast(try await simctl.increaseContrast(udid: udid))
        }
    }

    /// The global preferences, from the host file (no spawn).
    public func readGlobalPreferences() throws -> SimulatorGlobalPreferences? {
        guard let dataDirectory else { return nil }
        return try SimulatorGlobalPreferences.read(dataDirectory: dataDirectory)
    }

    /// The time zone the running boot took (`SIMCTL_CHILD_TZ` → `TZ`), nil
    /// when it took the Mac's.
    public func readBootTimeZone() async throws -> String? {
        try await simctl.environmentVariable(udid: udid, name: "TZ")
    }

    /// The status bar override now in place, nil when there is none.
    public func readStatusBar(over base: SimulatorStatusBarState) async throws -> SimulatorStatusBarState? {
        SimulatorStatusBarState.fromList(try await simctl.statusBarOverrides(udid: udid), over: base)
    }

    // MARK: Writes

    /// Applies `change` through its route and returns what the mechanism's
    /// own answer read back (devicectl answers with the new state), or nil.
    @discardableResult
    public func apply(_ change: AppleControlChange) async throws -> AppleControlsReading? {
        let route = route(change.control)
        guard let mechanism = route.mechanism else {
            throw AppleControlsError.unavailable(change.control, route.support.unavailableReason ?? "Not available.")
        }
        let viaDevicectl = mechanism.kind == .devicectl
        switch change {
        case .appearance(let dark):
            if viaDevicectl { return .appearance(try await requireDevicectl().setAppearance(.dark(dark)).value) }
            try await simctl.setAppearance(udid: udid, dark ? .dark : .light)
            return .simctlAppearance(dark ? .dark : .light)
        case .liquidGlassOpacity(let opacity):
            return .appearance(try await requireDevicectl().setAppearance(.liquidGlassOpacity(opacity)).value)
        case .lookAndFeel(let look):
            return .appearance(try await requireDevicectl().setAppearance(.lookAndFeel(look)).value)
        case .textSize(let size):
            if viaDevicectl {
                let devicectl = try requireDevicectl()
                if size.isAccessibilitySize {
                    try await devicectl.setAppearance(.largerAccessibilitySizes(true))
                }
                return .appearance(try await devicectl.setAppearance(.textSize(size)).value)
            }
            try await simctl.setContentSize(udid: udid, size)
            return nil
        case .largerAccessibilitySizes(let on):
            return .appearance(try await requireDevicectl().setAppearance(.largerAccessibilitySizes(on)).value)
        case .reduceMotion(let on):
            return .appearance(try await requireDevicectl().setAppearance(.reduceMotion(on)).value)
        case .showBorders(let on):
            return .appearance(try await requireDevicectl().setAppearance(.showBorders(on)).value)
        case .reduceTransparency(let on):
            return .appearance(try await requireDevicectl().setAppearance(.reduceTransparency(on)).value)
        case .volume(let level):
            let answer = try await requireDevicectl().setVolume(level).value
            return answer.volume.map(AppleControlsReading.volume)
        case .audioOutput(let device):
            return .audio(try await requireDevicectl().setAudioDevices(output: device).value)
        case .audioInput(let device):
            return .audio(try await requireDevicectl().setAudioDevices(input: device).value)
        case .voiceOver(let on):
            return .voiceOver(try await requireDevicectl().setVoiceOver(on).value.enabled)
        case .colorFilter(let type, let intensity):
            let setting: DevicectlAppearanceSetting = type.map { .colorFilterType($0, intensity: intensity) } ?? .colorFilter(false)
            return .appearance(try await requireDevicectl().setAppearance(setting).value)
        case .increaseContrast(let on):
            if viaDevicectl { return .appearance(try await requireDevicectl().setAppearance(.increaseContrast(on)).value) }
            try await simctl.setIncreaseContrast(udid: udid, enabled: on)
            return nil
        case .location(let latitude, let longitude):
            try await simctl.setLocation(udid: udid, latitude: latitude, longitude: longitude)
            return nil
        case .locationScenario(let name):
            try await simctl.runLocationScenario(udid: udid, name: name)
            return nil
        case .locationRoute(let waypoints, let speed):
            try await simctl.startLocationRoute(
                udid: udid,
                waypoints: waypoints.map { ($0.latitude, $0.longitude) },
                speed: speed
            )
            return nil
        case .clearLocation:
            try await simctl.clearLocation(udid: udid)
            return nil
        case .orientation(let pose):
            return .orientation(try await requireDevicectl().setPose(pose).value)
        case .biometricsEnrolled(let enrolled):
            return .biometrics(try await requireDevicectl().setBiometricsEnrolled(enrolled).value)
        case .biometricMatch(let success):
            try await requireDevicectl().simulateBiometricMatch(success: success)
            return nil
        case .push(let bundle, let payload):
            try await simctl.push(udid: udid, bundleIdentifier: bundle, payload: payload)
            return nil
        case .privacy(let action, let service, let bundle):
            try await simctl.setPrivacy(udid: udid, action, service: service, bundleIdentifier: bundle)
            return nil
        case .openURL(let url):
            try await simctl.openURL(udid: udid, url: url)
            return nil
        case .pasteboard(let text):
            try await simctl.setPasteboard(udid: udid, text: text)
            return nil
        case .language(let locale):
            try await simctl.writeGlobalDefault(udid: udid, key: "AppleLanguages", .stringArray([locale.tag]))
            if let region = SimulatorGlobalPreferences.localeIdentifier(for: locale) {
                try await simctl.writeGlobalDefault(udid: udid, key: "AppleLocale", .string(region))
            }
            return nil
        case .timeFormat(let setting):
            for (key, value) in SimulatorGlobalPreferences.timeFormatWrites(setting) {
                if let value {
                    try await simctl.writeGlobalDefault(udid: udid, key: key, .bool(value))
                } else {
                    try await simctl.deleteGlobalDefault(udid: udid, key: key)
                }
            }
            try await simctl.postDarwinNotification(udid: udid, name: SimulatorGlobalPreferences.timeFormatChangedNotification)
            return nil
        case .statusBar(let state):
            if let state {
                try await simctl.overrideStatusBar(udid: udid, state)
            } else {
                try await simctl.clearStatusBar(udid: udid)
            }
            return nil
        case .respring:
            try await simctl.respring(udid: udid)
            return nil
        }
    }

    private func requireDevicectl() throws -> DevicectlClient {
        guard let devicectl else {
            throw AppleControlsError.unavailable(.appearance, AppleControlsRouting.devicectlUnavailable)
        }
        return devicectl
    }
}
