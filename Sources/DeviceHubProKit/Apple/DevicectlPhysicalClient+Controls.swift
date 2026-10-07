import Foundation

// The Controls commands of a physical iPhone: the
// shapes of `DevicectlPhysicalControl`, their tails checked before devicectl
// runs, and the typed calls the app's `ApplePhysicalControlsBackend` makes.
// The simulator client (`DevicectlClient`) runs the same appearance, VoiceOver
// and orientation commands with the same argument spelling; this client adds
// the location, memory-warning and pasteboard commands and the strict tail
// check. Nothing here changes a setting the phone did not list a CoreDevice
// feature for: the backend gates every call on the capability list.

extension DevicectlPhysicalClient {
    /// The largest text `copyToPasteboard` sends (1 MiB of UTF-8).
    public static let maximumPasteboardBytes = 1 << 20

    // MARK: The tails

    /// Whether `tail` (the words after a Controls command's subcommand) is
    /// exactly one of the shapes that command may have.
    static func isValidControlTail(_ tail: [String], for control: DevicectlPhysicalControl) -> Bool {
        switch control {
        case .settingsAppearance:
            return isValidAppearanceTail(tail)
        case .settingsVoiceOver:
            return tail == ["--enable"] || tail == ["--disable"]
        case .orientationGet, .simulateLocationClear, .pasteboardPaste:
            return tail.isEmpty
        case .orientationSet:
            return tail.count == 1 && SimulatorDevicePose(rawValue: tail[0]) != nil
        case .simulateLocationCoordinate:
            return tail.count == 4 && tail[0] == "--latitude" && tail[2] == "--longitude"
                && isCoordinate(tail[1], within: -90...90) && isCoordinate(tail[3], within: -180...180)
        case .sendMemoryWarning:
            return tail.count == 2 && tail[0] == "--pid" && (Int(tail[1]).map { $0 > 0 } ?? false)
        case .pasteboardCopy:
            return tail.count == 2 && tail[0] == "--file" && isPlainPath(tail[1])
        }
    }

    /// One `settings appearance` change: a single flag and its value, or a
    /// colour filter's type with its optional intensity (the shapes
    /// `DevicectlAppearanceSetting.arguments` writes).
    private static func isValidAppearanceTail(_ tail: [String]) -> Bool {
        guard let flag = tail.first else { return false }
        let toggles: Set<String> = [
            "--reduce-motion", "--reduce-transparency", "--increase-contrast", "--show-borders",
            "--color-filter", "--larger-accessibility-sizes",
        ]
        switch flag {
        case "--mode":
            return tail.count == 2 && ["light", "dark"].contains(tail[1])
        case "--text-size":
            return tail.count == 2 && (SimulatorContentSize(rawValue: tail[1]).map(SimulatorContentSize.settable.contains) ?? false)
        case "--liquid-glass-opacity":
            return tail.count == 2 && isCoordinate(tail[1], within: 0...1)
        case "--color-filter-type":
            guard tail.count >= 2, let type = SimulatorColorFilterType(rawValue: tail[1]) else { return false }
            if tail.count == 2 { return true }
            return tail.count == 4 && tail[2] == "--color-filter-intensity" && type.hasIntensity
                && isCoordinate(tail[3], within: SimulatorColorFilterType.intensityRange)
        default:
            return toggles.contains(flag) && tail.count == 2 && ["on", "off"].contains(tail[1])
        }
    }

    /// A finite decimal number inside `range` (plain digits: no exponent, no
    /// leading `-` that could read as an option except a genuine sign).
    private static func isCoordinate(_ text: String, within range: ClosedRange<Double>) -> Bool {
        guard let value = Double(text), value.isFinite, range.contains(value) else { return false }
        return text.allSatisfy { $0.isNumber || $0 == "." || $0 == "-" } && !text.hasSuffix("-")
    }

    // MARK: Commands

    /// `device settings appearance` with exactly one setting (the type holds
    /// one, so a call never combines flags). The answer carries what the call
    /// touched.
    @discardableResult
    public func setAppearance(_ setting: DevicectlAppearanceSetting) async throws -> DevicectlResult<DevicectlAppearance> {
        try setting.validate()
        return try await run(
            DevicectlPhysicalControl.settingsAppearance.words + setting.arguments,
            as: DevicectlAppearance.self
        )
    }

    /// `device settings voiceover --enable|--disable`. VoiceOver changes how
    /// the phone answers touches: a caller turns it off again.
    @discardableResult
    public func setVoiceOver(_ enabled: Bool) async throws -> DevicectlResult<DevicectlVoiceOver> {
        try await run(
            DevicectlPhysicalControl.settingsVoiceOver.words + [enabled ? "--enable" : "--disable"],
            as: DevicectlVoiceOver.self
        )
    }

    /// `device orientation get`.
    public func orientation() async throws -> DevicectlResult<DevicectlOrientation> {
        try await run(DevicectlPhysicalControl.orientationGet.words, as: DevicectlOrientation.self)
    }

    /// `device orientation set <pose>`. On the iPhone 12 / iOS 27.0 it turns the
    /// interface of the app in front when that app supports the pose (Rotate uses it)
    /// but the answer and `orientation get` keep saying portrait, so no Controls
    /// picker row reads it back; the live test pins the turn by screenshot aspect.
    @discardableResult
    public func setOrientation(_ pose: SimulatorDevicePose) async throws -> DevicectlResult<DevicectlOrientation> {
        try await run(DevicectlPhysicalControl.orientationSet.words + [pose.rawValue], as: DevicectlOrientation.self)
    }

    /// `device simulate location coordinate`: the phone reports this
    /// coordinate to every app until `clearLocation()` (CoreDevice: "the
    /// simulation will continue until cleared").
    @discardableResult
    public func setLocation(latitude: Double, longitude: Double) async throws -> DevicectlResult<DevicectlLocationSimulation> {
        guard latitude.isFinite, (-90.0...90.0).contains(latitude) else {
            throw DevicectlClientError.invalidValue("latitude \(latitude) is outside -90–90")
        }
        guard longitude.isFinite, (-180.0...180.0).contains(longitude) else {
            throw DevicectlClientError.invalidValue("longitude \(longitude) is outside -180–180")
        }
        return try await run(
            DevicectlPhysicalControl.simulateLocationCoordinate.words
                + ["--latitude", Self.coordinateText(latitude), "--longitude", Self.coordinateText(longitude)],
            as: DevicectlLocationSimulation.self
        )
    }

    /// `device simulate location clear`: the phone uses its real location again.
    @discardableResult
    public func clearLocation() async throws -> DevicectlResult<DevicectlLocationCleared> {
        try await run(DevicectlPhysicalControl.simulateLocationClear.words, as: DevicectlLocationCleared.self)
    }

    /// `device process sendMemoryWarning --pid <pid>`. On the iPhone 12 /
    /// iOS 27.0 it fails with `NSPOSIXErrorDomain` 2 for a running app, so no
    /// Controls row offers it; the live test keeps it as a canary.
    @discardableResult
    public func sendMemoryWarning(pid: Int) async throws -> DevicectlResult<DevicectlMemoryWarning> {
        guard pid > 0 else { throw DevicectlClientError.invalidValue("pid \(pid)") }
        return try await run(
            DevicectlPhysicalControl.sendMemoryWarning.words + ["--pid", String(pid)],
            as: DevicectlMemoryWarning.self
        )
    }

    /// `device pasteboard copy --file <temporary file>`: replaces the phone's
    /// general pasteboard with `text`, as three text types. The text goes
    /// through a temporary file (removed afterwards), never through the
    /// command line.
    @discardableResult
    public func copyToPasteboard(_ text: String) async throws -> DevicectlResult<DevicectlPasteboardCopy> {
        let bytes = Data(text.utf8)
        guard !bytes.isEmpty else { throw DevicectlClientError.invalidValue("the pasteboard text is empty") }
        guard bytes.count <= Self.maximumPasteboardBytes else {
            throw DevicectlClientError.invalidValue("the pasteboard text is \(bytes.count) bytes; the limit is \(Self.maximumPasteboardBytes)")
        }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("devicehubpro-pasteboard-\(UUID().uuidString).txt")
        try bytes.write(to: file, options: .atomic)
        defer { try? FileManager.default.removeItem(at: file) }
        return try await run(
            DevicectlPhysicalControl.pasteboardCopy.words + ["--file", file.path],
            as: DevicectlPasteboardCopy.self
        )
    }

    /// `device pasteboard paste`: the phone's pasteboard text (the first text
    /// type devicectl finds), read from the command's standard output.
    public func pasteboardText() async throws -> (text: String, info: DevicectlPasteboardPaste) {
        let ran = try await runCapturingOutput(
            DevicectlPhysicalControl.pasteboardPaste.words,
            as: DevicectlPasteboardPaste.self
        )
        return (String(decoding: ran.standardOutput, as: UTF8.self), ran.result.value)
    }

    /// A coordinate with a point and six decimals, whatever the Mac's locale.
    static func coordinateText(_ value: Double) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
