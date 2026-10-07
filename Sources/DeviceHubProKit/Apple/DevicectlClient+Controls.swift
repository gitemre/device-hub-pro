import Foundation

// The devicectl commands behind a simulator's Controls rows:
// VoiceOver, audio volume, biometrics, the six device poses, a colour filter
// with its type and intensity, the Liquid Glass opacity and the memory
// warning. Every answer below was captured from CoreDevice 642.16 (JSON
// version 5, Xcode 27.0 27A266a) against an iOS 27.0 simulator
// (`Fixtures/ios27-simulator/devicectl/`, `DevicectlControlsTests`).

/// iOS's colour filters, as `settings appearance --color-filter-type` takes
/// them and `info appearance` names them.
public enum SimulatorColorFilterType: String, Sendable, CaseIterable, Identifiable {
    case grayscale
    case protanopia
    case deuteranopia
    case tritanopia

    public var id: String { rawValue }

    /// The name `info appearance` reports ("Deuteranopia").
    public var devicectlName: String {
        switch self {
        case .grayscale: "Grayscale"
        case .protanopia: "Protanopia"
        case .deuteranopia: "Deuteranopia"
        case .tritanopia: "Tritanopia"
        }
    }

    public init?(devicectlName: String) {
        guard let match = Self.allCases.first(where: {
            $0.devicectlName.caseInsensitiveCompare(devicectlName) == .orderedSame
        }) else { return nil }
        self = match
    }

    /// Grayscale has no intensity (devicectl: "does not apply to grayscale").
    public var hasIntensity: Bool { self != .grayscale }

    /// The intensity range devicectl accepts (a value outside it is a usage
    /// error, exit 64: "--color-filter-intensity must be between 0.25 and 1.0").
    public static let intensityRange: ClosedRange<Double> = 0.25...1.0
}

/// The six physical poses `devicectl device orientation set` takes; the four
/// upright ones are also `SimulatorOrientation`s.
public enum SimulatorDevicePose: String, Sendable, CaseIterable, Identifiable {
    case portrait
    case portraitUpsideDown
    case landscapeLeft
    case landscapeRight
    case faceUp
    case faceDown

    public var id: String { rawValue }

    public init?(devicectlName: String) {
        self.init(rawValue: devicectlName)
    }
}

extension SimulatorContentSize {
    /// devicectl's display name for a size ("Accessibility Extra Large").
    public init?(devicectlName: String) {
        let token = devicectlName.lowercased().replacingOccurrences(of: " ", with: "-")
        guard let size = SimulatorContentSize(rawValue: token), SimulatorContentSize.settable.contains(size) else {
            return nil
        }
        self = size
    }
}

/// `devicectl device info voiceover` and `settings voiceover --enable|--disable`.
public struct DevicectlVoiceOver: Decodable, Sendable, Equatable {
    public let deviceIdentifier: String?
    public let enabled: Bool
    /// "query", "enable" or "disable".
    public let operation: String?
}

/// An audio device a simulator is pinned to: `{"systemDefault": {}}` follows
/// the Mac's default device, `{"device": {"_0": "<id>"}}` is one Mac device
/// by its CoreAudio UID (`BuiltInSpeakerDevice`; measured on CoreDevice
/// 642.16, iOS 26.5 simulator).
public enum DevicectlAudioDevice: Sendable, Equatable {
    case systemDefault
    case device(String)

    /// devicectl's `--output-device` / `--input-device` value.
    public var argument: String {
        switch self {
        case .systemDefault: "systemDefault"
        case .device(let identifier): identifier
        }
    }

    fileprivate struct Shape: Decodable {
        struct Empty: Decodable {}
        struct Pinned: Decodable {
            let _0: String?
        }

        let systemDefault: Empty?
        let device: Pinned?

        var value: DevicectlAudioDevice? {
            if systemDefault != nil { return .systemDefault }
            return device?._0.map(DevicectlAudioDevice.device)
        }
    }
}

/// `devicectl device info audio` and `settings audio --volume`: the volume
/// (0–100) and the output and input devices (`DevicectlAudioDevice`).
public struct DevicectlAudio: Decodable, Sendable, Equatable {
    public let deviceIdentifier: String?
    public let volume: Int?
    /// The output and input the simulator is pinned to; nil when the answer
    /// did not say (a `settings audio --volume` answer carries only the volume).
    public let outputDevice: DevicectlAudioDevice?
    public let inputDevice: DevicectlAudioDevice?

    /// Whether the output follows the Mac's default device; nil when the
    /// answer did not say.
    public var outputIsSystemDefault: Bool? { outputDevice.map { $0 == .systemDefault } }
    public var inputIsSystemDefault: Bool? { inputDevice.map { $0 == .systemDefault } }

    private enum CodingKeys: String, CodingKey {
        case deviceIdentifier, volume, audioOutputDevice, audioInputDevice
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceIdentifier = try container.decodeIfPresent(String.self, forKey: .deviceIdentifier)
        volume = try container.decodeIfPresent(Int.self, forKey: .volume)
        // Decoded leniently: a shape not captured yet reads as unknown.
        outputDevice = (try? container.decodeIfPresent(DevicectlAudioDevice.Shape.self, forKey: .audioOutputDevice))
            .flatMap { $0 }?.value
        inputDevice = (try? container.decodeIfPresent(DevicectlAudioDevice.Shape.self, forKey: .audioInputDevice))
            .flatMap { $0 }?.value
    }
}

/// `devicectl device settings biometrics` (with no flag, a query; with
/// `--enable` / `--disable`, the change): each supported biometric type and
/// whether it is enrolled.
public struct DevicectlBiometrics: Decodable, Sendable, Equatable {
    public struct Kind: Decodable, Sendable, Equatable {
        /// "Face ID", "Touch ID" or "Optic ID".
        public let type: String
        public let enabled: Bool
    }

    public let deviceIdentifier: String?
    public let biometrics: [Kind]
    /// "query", "enable" or "disable".
    public let operation: String?

    /// The first supported type ("Face ID" on an iPhone 17 Pro); nil when
    /// the device supports none.
    public var primaryType: String? { biometrics.first?.type }
    public var isEnrolled: Bool { biometrics.contains { $0.enabled } }
}

/// `devicectl device simulate biometrics --success|--failure`:
/// `simulateSuccessfulMatch` or `simulateFailedMatch`. It answers the same
/// whether or not biometrics are enrolled (measured: a match simulated with
/// enrolment off still reports success).
public struct DevicectlBiometricMatch: Decodable, Sendable, Equatable {
    public let deviceIdentifier: String?
    public let operation: String
}

/// `devicectl device process sendMemoryWarning --pid`.
public struct DevicectlMemoryWarning: Decodable, Sendable, Equatable {
    public struct Process: Decodable, Sendable, Equatable {
        public let processIdentifier: Int
    }

    public let deviceIdentifier: String?
    public let process: Process?
}

extension DevicectlAppearance {
    /// The look this reading shows (iOS 26: "Clear Liquid Glass"); nil on a
    /// runtime whose one look is plain "Liquid Glass".
    public var lookSelection: DevicectlLookAndFeel? {
        lookAndFeel.flatMap(DevicectlLookAndFeel.init(devicectlName:))
    }

    /// The looks the runtime offers: two on iOS 26, none of ours on iOS 27
    /// (its one look is "Liquid Glass", set by opacity).
    public var supportedLooks: [DevicectlLookAndFeel] {
        (supportedLooksAndFeels ?? []).compactMap(DevicectlLookAndFeel.init(devicectlName:))
    }

    /// The colour filter this reading shows: nil while off (or unnamed).
    public var colorFilterSelection: SimulatorColorFilterType? {
        guard colorFilter == true, let name = colorFilterType else { return nil }
        return SimulatorColorFilterType(devicectlName: name)
    }

    /// The text size as simctl names it.
    public var contentSize: SimulatorContentSize? {
        textSize.flatMap(SimulatorContentSize.init(devicectlName:))
    }
}

extension DevicectlClient {
    /// `device info voiceover`.
    public func voiceOver() async throws -> DevicectlResult<DevicectlVoiceOver> {
        try await run(["device", "info", "voiceover"], as: DevicectlVoiceOver.self)
    }

    /// `device settings voiceover --enable|--disable` (0.1 s warm; the
    /// verifier saw VoiceOver 1.46 s after the command started).
    @discardableResult
    public func setVoiceOver(_ enabled: Bool) async throws -> DevicectlResult<DevicectlVoiceOver> {
        try await run(["device", "settings", "voiceover", enabled ? "--enable" : "--disable"], as: DevicectlVoiceOver.self)
    }

    /// `device info audio`.
    public func audio() async throws -> DevicectlResult<DevicectlAudio> {
        try await run(["device", "info", "audio"], as: DevicectlAudio.self)
    }

    /// `device settings audio --volume <0–100>`; devicectl refuses anything
    /// else as a usage error, so it is checked first.
    @discardableResult
    public func setVolume(_ volume: Int) async throws -> DevicectlResult<DevicectlAudio> {
        guard (0...100).contains(volume) else {
            throw DevicectlClientError.invalidValue("volume \(volume) is outside 0–100")
        }
        return try await run(["device", "settings", "audio", "--volume", String(volume)], as: DevicectlAudio.self)
    }

    /// `device settings audio --output-device <id>` and/or `--input-device <id>`;
    /// `systemDefault` follows the Mac's default device. The answer carries
    /// the device that changed.
    @discardableResult
    public func setAudioDevices(
        output: DevicectlAudioDevice? = nil,
        input: DevicectlAudioDevice? = nil
    ) async throws -> DevicectlResult<DevicectlAudio> {
        var arguments = ["device", "settings", "audio"]
        if let output { arguments += ["--output-device", output.argument] }
        if let input { arguments += ["--input-device", input.argument] }
        guard arguments.count > 3 else {
            throw DevicectlClientError.invalidValue("no audio device to set")
        }
        return try await run(arguments, as: DevicectlAudio.self)
    }

    /// `device settings biometrics` with no flag: reads each type's enrolment.
    public func biometrics() async throws -> DevicectlResult<DevicectlBiometrics> {
        try await run(["device", "settings", "biometrics"], as: DevicectlBiometrics.self)
    }

    /// `device settings biometrics --enable|--disable` (every supported type).
    @discardableResult
    public func setBiometricsEnrolled(_ enrolled: Bool) async throws -> DevicectlResult<DevicectlBiometrics> {
        try await run(["device", "settings", "biometrics", enrolled ? "--enable" : "--disable"], as: DevicectlBiometrics.self)
    }

    /// `device simulate biometrics --success|--failure`: a matching or a
    /// non-matching face (or finger) for the prompt on screen.
    @discardableResult
    public func simulateBiometricMatch(success: Bool) async throws -> DevicectlResult<DevicectlBiometricMatch> {
        try await run(
            ["device", "simulate", "biometrics", success ? "--success" : "--failure"],
            as: DevicectlBiometricMatch.self
        )
    }

    /// `device orientation set <pose>`, face up and face down included.
    @discardableResult
    public func setPose(_ pose: SimulatorDevicePose) async throws -> DevicectlResult<DevicectlOrientation> {
        try await run(["device", "orientation", "set", pose.rawValue], as: DevicectlOrientation.self)
    }

    /// `device process sendMemoryWarning --pid <pid>`. On CoreDevice 642.16 it
    /// answers success for a simulator's app, but the app receives no memory
    /// warning (measured twice on iOS 27.0 with the pid `simctl launch`
    /// printed), so no Controls row offers it; `IOSVerifierLiveTests` keeps it
    /// as a canary.
    @discardableResult
    public func sendMemoryWarning(pid: Int) async throws -> DevicectlResult<DevicectlMemoryWarning> {
        guard pid > 0 else { throw DevicectlClientError.invalidValue("pid \(pid)") }
        return try await run(
            ["device", "process", "sendMemoryWarning", "--pid", String(pid)],
            as: DevicectlMemoryWarning.self
        )
    }
}
