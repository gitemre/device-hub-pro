import Foundation
import os

// A physical iPhone's Controls: the rows the phone's
// CoreDevice capability list offers, and the backend that runs them through
// `DevicectlPhysicalClient`. The simulator's `AppleControlsBackend` and this
// backend both conform to `AppleControlsBacking`, which is all the app's one
// `AppleControlsController` needs from either.

/// What the app's Controls controller asks of a device's backend: which
/// controls route where, the reads a poll makes, and the writes.
public protocol AppleControlsBacking: Sendable {
    /// The simulator's UDID, or a physical device's upper-cased hardware UDID.
    var deviceIdentifier: String { get }
    /// The beat of the panel's poll: one read per tick.
    var pollInterval: Duration { get }
    func route(_ control: AppleControl) -> AppleControlRoute
    /// What an attach reads once, before the poll starts.
    func initialReads() -> [AppleControlsRead]
    /// The one read of poll tick `tick` (0-based); nil when there is none.
    func pollRead(forTick tick: Int) -> AppleControlsRead?
    func read(_ read: AppleControlsRead) async throws -> AppleControlsReading
    @discardableResult
    func apply(_ change: AppleControlChange) async throws -> AppleControlsReading?
}

/// The CoreDevice features (`capabilities[].featureIdentifier` of
/// `devicectl device info details`) that decide a physical phone's Controls
/// rows. The iPhone 12 on iOS 27.0 lists the first eight and not the last.
public enum ApplePhysicalFeature: String, CaseIterable, Sendable {
    case customizeAppearanceSettings = "com.apple.coredevice.feature.customizeappearancesettings"
    case customizeUIStyle = "com.apple.coredevice.feature.customizeuistyle"
    case customizeLiquidGlass = "com.apple.coredevice.feature.customizeliquidglass"
    case voiceOver = "com.apple.coredevice.feature.voiceover"
    case orientation = "com.apple.coredevice.feature.remote.devicecontrol.orientation"
    case simulateLocation = "com.apple.coredevice.feature.simulatelocation"
    case sendMemoryWarning = "com.apple.coredevice.feature.sendmemorywarningtoprocess"
    case pasteboard = "com.apple.coredevice.feature.pasteboard"
    /// The 1001 of `info audio` on the iPhone 12 (captured): the phone does
    /// not offer audio output selection.
    case audioOutput = "com.apple.coredevice.feature.audiooutput"

    /// CoreDevice's name for the feature, for the reason a row is hidden.
    public var title: String {
        switch self {
        case .customizeAppearanceSettings: "Customize Appearance Settings"
        case .customizeUIStyle: "Customize User Interface Style"
        case .customizeLiquidGlass: "Customize Liquid Glass"
        case .voiceOver: "VoiceOver"
        case .orientation: "Device Orientation"
        case .simulateLocation: "Simulate Location"
        case .sendMemoryWarning: "Send Memory Warning to Process"
        case .pasteboard: "Pasteboard"
        case .audioOutput: "Audio Output Device Selection"
        }
    }
}

/// The CoreDevice features one physical device lists (the backend keeps the
/// ones a call has since answered with error 1001 for).
public struct ApplePhysicalControlsCapabilities: Sendable, Equatable {
    public let identifiers: Set<String>

    public init(identifiers: Set<String>) {
        self.identifiers = identifiers
    }

    public init(details: DevicectlDeviceDetails) {
        self.init(identifiers: Set(details.capabilities.map(\.featureIdentifier)))
    }

    public func lists(_ feature: ApplePhysicalFeature) -> Bool {
        identifiers.contains(feature.rawValue)
    }
}

extension AppleControlsRouting {
    /// Why every simctl-only row is hidden on a physical device.
    public static let physicalSimulatorOnly =
        "Simulator only: it goes through simctl, which cannot reach a physical device."

    /// Measured on the iPhone 12 / iOS 27.0 (CoreDevice 642.16): `orientation
    /// set` does turn the interface of an app that supports the pose (the
    /// all-orientation host app; the portrait-only verifier stays portrait), but
    /// neither its answer nor `orientation get` reports the new pose, so the
    /// picker row has nothing to read back. Rotate (stage pill, Device menu)
    /// uses the command and follows the interface from a screenshot.
    public static let physicalOrientationUnavailable =
        "Use Rotate: devicectl turns the app in front, but the phone does not report the pose back."

    /// Measured on the same phone: `process sendMemoryWarning` fails with
    /// NSPOSIXErrorDomain 2 for a running app.
    public static let physicalMemoryWarningUnavailable =
        "devicectl process sendMemoryWarning fails on this iPhone (NSPOSIXErrorDomain 2) even for a running app."

    public static let physicalBiometricsUnavailable =
        "CoreDevice lists no biometrics feature for this iPhone, and Device Hub Pro never runs devicectl settings or simulate biometrics on a physical device."

    public static let physicalVolumeUnavailable =
        "This iPhone does not offer audio output selection (CoreDevice error 1001), the only volume control devicectl has."

    /// The CoreDevice feature a physical control needs and the mechanism
    /// that runs it; nil for a control that never reaches a physical phone.
    static func physicalMechanism(for control: AppleControl) -> (feature: ApplePhysicalFeature, mechanism: AppleControlMechanism)? {
        func devicectl(_ feature: ApplePhysicalFeature, readsBack: Bool, _ command: String) -> (ApplePhysicalFeature, AppleControlMechanism) {
            (feature, AppleControlMechanism(.devicectl, .live, readsBack: readsBack, command: command))
        }
        switch control {
        case .appearance:
            return devicectl(.customizeUIStyle, readsBack: true, "devicectl device settings appearance --mode")
        case .liquidGlass:
            return devicectl(.customizeLiquidGlass, readsBack: true, "devicectl device settings appearance --liquid-glass-opacity")
        case .textSize:
            return devicectl(.customizeAppearanceSettings, readsBack: true, "devicectl device settings appearance --text-size")
        case .reduceMotion:
            return devicectl(.customizeAppearanceSettings, readsBack: true, "devicectl device settings appearance --reduce-motion")
        case .showBorders:
            return devicectl(.customizeAppearanceSettings, readsBack: true, "devicectl device settings appearance --show-borders")
        case .reduceTransparency:
            return devicectl(.customizeAppearanceSettings, readsBack: true, "devicectl device settings appearance --reduce-transparency")
        case .colorFilter:
            return devicectl(.customizeAppearanceSettings, readsBack: true, "devicectl device settings appearance --color-filter-type")
        case .increaseContrast:
            return devicectl(.customizeAppearanceSettings, readsBack: true, "devicectl device settings appearance --increase-contrast")
        case .voiceOver:
            return devicectl(.voiceOver, readsBack: true, "devicectl device settings voiceover")
        case .location:
            return devicectl(.simulateLocation, readsBack: false, "devicectl device simulate location coordinate|clear")
        case .clipboard:
            return devicectl(.pasteboard, readsBack: true, "devicectl device pasteboard copy|paste")
        case .orientation, .memoryWarning, .volume, .biometrics,
             .push, .permissions, .openURL, .language, .timeFormat24, .timeZone, .statusBar:
            return nil
        }
    }

    /// The route for `control` on a physical phone that lists `capabilities`,
    /// less the features a call has since found unsupported. A row whose
    /// feature the phone does not list is not offered (hidden, never
    /// disabled with an error); a row with a mechanism measured not to work
    /// on the phone says so.
    public static func physicalRoute(
        _ control: AppleControl,
        capabilities: ApplePhysicalControlsCapabilities,
        unsupported: Set<String> = []
    ) -> AppleControlRoute {
        func unavailable(_ reason: String) -> AppleControlRoute {
            AppleControlRoute(control: control, mechanism: nil, support: .unavailable(reason))
        }
        switch control {
        case .orientation:
            return unavailable(physicalOrientationUnavailable)
        case .memoryWarning:
            return unavailable(physicalMemoryWarningUnavailable)
        case .volume:
            return unavailable(physicalVolumeUnavailable)
        case .biometrics:
            return unavailable(physicalBiometricsUnavailable)
        default:
            break
        }
        guard let (feature, mechanism) = physicalMechanism(for: control) else {
            return unavailable(physicalSimulatorOnly)
        }
        guard capabilities.lists(feature), !unsupported.contains(feature.rawValue) else {
            return unavailable("This iPhone does not offer \(feature.title) (\(feature.rawValue)).")
        }
        return AppleControlRoute(control: control, mechanism: mechanism, support: mechanism.support)
    }
}

/// A physical iPhone's Controls: `AppleControlChange`s and the poll's reads,
/// run through one `DevicectlPhysicalClient` (the app makes it only through
/// `ApplePhysicalInventory.client(for:)`). Rows follow the phone's own
/// capability list; a call the phone answers with CoreDevice 1001 takes that
/// feature's rows out for the rest of the run.
public final class ApplePhysicalControlsBackend: AppleControlsBacking {
    public let client: DevicectlPhysicalClient
    public let capabilities: ApplePhysicalControlsCapabilities
    private let unsupported = OSAllocatedUnfairLock(initialState: Set<String>())

    /// A physical phone answers over a wire: slower than the simulator's
    /// beat, one read per tick.
    public static let pollBeat: Duration = .seconds(3)

    public init(client: DevicectlPhysicalClient, capabilities: ApplePhysicalControlsCapabilities) {
        self.client = client
        self.capabilities = capabilities
    }

    public var deviceIdentifier: String { client.device.hardwareUDID.uppercased() }
    public var pollInterval: Duration { Self.pollBeat }

    /// The features a call has answered 1001 for.
    public var unsupportedFeatures: Set<String> { unsupported.withLock { $0 } }

    public func recordUnsupported(_ featureIdentifier: String) {
        unsupported.withLock { _ = $0.insert(featureIdentifier) }
    }

    public func route(_ control: AppleControl) -> AppleControlRoute {
        AppleControlsRouting.physicalRoute(control, capabilities: capabilities, unsupported: unsupportedFeatures)
    }

    // MARK: Reads

    /// The reads the offered rows need: the appearance fields when any
    /// appearance feature is listed, then VoiceOver.
    public func initialReads() -> [AppleControlsRead] {
        var reads: [AppleControlsRead] = []
        let appearanceControls: [AppleControl] = [
            .appearance, .liquidGlass, .textSize, .reduceMotion, .showBorders, .reduceTransparency,
            .colorFilter, .increaseContrast,
        ]
        if appearanceControls.contains(where: { route($0).isOffered }) { reads.append(.devicectlAppearance) }
        if route(.voiceOver).isOffered { reads.append(.devicectlVoiceOver) }
        return reads
    }

    public func pollRead(forTick tick: Int) -> AppleControlsRead? {
        let reads = initialReads()
        guard !reads.isEmpty else { return nil }
        return reads[max(0, tick) % reads.count]
    }

    public func read(_ read: AppleControlsRead) async throws -> AppleControlsReading {
        do {
            switch read {
            case .devicectlAppearance:
                return .appearance(try await client.appearance().value)
            case .devicectlVoiceOver:
                return .voiceOver(try await client.voiceover().value.enabled)
            default:
                throw AppleControlsError.unavailable(.appearance, "A physical iPhone's Controls do not run \(read.rawValue).")
            }
        } catch let error as DevicectlPhysicalError {
            note(error)
            throw error
        }
    }

    // MARK: Writes

    @discardableResult
    public func apply(_ change: AppleControlChange) async throws -> AppleControlsReading? {
        let route = route(change.control)
        guard route.isOffered else {
            throw AppleControlsError.unavailable(change.control, route.support.unavailableReason ?? "Not available.")
        }
        do {
            return try await perform(change)
        } catch let error as DevicectlPhysicalError {
            note(error)
            throw error
        }
    }

    private func perform(_ change: AppleControlChange) async throws -> AppleControlsReading? {
        switch change {
        case .appearance(let dark):
            return .appearance(try await client.setAppearance(.dark(dark)).value)
        case .liquidGlassOpacity(let opacity):
            return .appearance(try await client.setAppearance(.liquidGlassOpacity(opacity)).value)
        case .textSize(let size):
            if size.isAccessibilitySize {
                // devicectl refuses an accessibility size until Larger
                // Accessibility Sizes is on (21063): a second call that
                // changes another setting, so it is made only when needed.
                try await client.setAppearance(.largerAccessibilitySizes(true))
            }
            return .appearance(try await client.setAppearance(.textSize(size)).value)
        case .reduceMotion(let on):
            return .appearance(try await client.setAppearance(.reduceMotion(on)).value)
        case .showBorders(let on):
            return .appearance(try await client.setAppearance(.showBorders(on)).value)
        case .reduceTransparency(let on):
            return .appearance(try await client.setAppearance(.reduceTransparency(on)).value)
        case .increaseContrast(let on):
            return .appearance(try await client.setAppearance(.increaseContrast(on)).value)
        case .colorFilter(let type, let intensity):
            let setting: DevicectlAppearanceSetting = type.map { .colorFilterType($0, intensity: intensity) } ?? .colorFilter(false)
            return .appearance(try await client.setAppearance(setting).value)
        case .voiceOver(let on):
            return .voiceOver(try await client.setVoiceOver(on).value.enabled)
        case .location(let latitude, let longitude):
            try await client.setLocation(latitude: latitude, longitude: longitude)
            return nil
        case .clearLocation:
            try await client.clearLocation()
            return nil
        case .pasteboard(let text):
            try await client.copyToPasteboard(text)
            return nil
        case .locationScenario, .locationRoute:
            throw AppleControlsError.unavailable(.location, "A physical iPhone takes a place or a coordinate, not a scenario or a route.")
        default:
            throw AppleControlsError.unavailable(change.control, AppleControlsRouting.physicalSimulatorOnly)
        }
    }

    /// The phone's pasteboard text (`devicectl device pasteboard paste`).
    public func pasteboardText() async throws -> String {
        guard route(.clipboard).isOffered else {
            throw AppleControlsError.unavailable(.clipboard, route(.clipboard).support.unavailableReason ?? "Not available.")
        }
        do {
            return try await client.pasteboardText().text
        } catch let error as DevicectlPhysicalError {
            note(error)
            throw error
        }
    }

    private func note(_ error: DevicectlPhysicalError) {
        if case .unsupportedCapability(let identifier?, _) = error { recordUnsupported(identifier) }
    }
}
