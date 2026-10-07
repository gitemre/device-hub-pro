import Foundation
import DeviceHubProKit

/// One simulator of the listing, with the names the app shows for it: its
/// runtime's platform and version and its device type's model, from the
/// runtime and device-type catalogs, and whether CoreSimulator created it by
/// itself.
struct SimulatorEntry: Identifiable, Hashable, Sendable {
    /// The listing's row. Only a listed device can be handed to devicectl.
    let device: SimulatorDevice
    /// "iOS", "tvOS", …: the runtime's platform, else read from its identifier.
    let platform: String?
    /// "27.0".
    let osVersion: String?
    /// "24A434"; nil when the runtime is not installed.
    let osBuild: String?
    /// "iPhone 17 Pro"; nil when the device type is unknown.
    let modelName: String?
    /// "iPhone", "iPad", "Apple TV", …
    let productFamily: String?
    /// "iPhone18,1".
    let modelIdentifier: String?
    /// The device type's bundle (`…/iPhone 17 Pro.simdevicetype`), whose
    /// `capabilities.plist` describes the display; nil when the device type
    /// is unknown.
    let deviceTypeBundlePath: String?
    /// CoreSimulator created it by itself for its runtime (the set's
    /// `device_set.plist` lists it under `DefaultDevices`); a device a user
    /// or a tool created is not one.
    let isDefaultCreated: Bool
    /// Its runtime is installed (in the runtime catalog).
    let hasInstalledRuntime: Bool

    /// When the device's folder was created (a device never booted has no
    /// `lastUsedAt`; the sidebar's Availability sort lists it by this).
    let createdAt: Date?

    var id: String { udid }
    var udid: String { device.udid }
    var name: String { device.name }
    var state: SimulatorState { device.state }
    var isAvailable: Bool { device.isAvailable }
    /// Why it cannot run (its runtime is missing), when it cannot.
    var availabilityError: String? { device.availabilityError }
    /// Absent until the device was first booted.
    var lastUsedAt: Date? { device.lastUsedAt }
    var dataPath: String? { device.dataPath }
    var logPath: String? { device.logPath }
    var runtimeIdentifier: String { device.runtimeIdentifier }
    var deviceTypeIdentifier: String? { device.deviceTypeIdentifier }

    /// Created by CoreSimulator and never booted: Device Hub hides these
    /// ("Hiding default-created device … - never used"), and so does the
    /// sidebar.
    var isUnusedDefault: Bool { isDefaultCreated && lastUsedAt == nil }

    /// Its installed runtime is older than iOS 17 (or that generation on
    /// another platform): Device Hub hides these too ("OS version too old",
    /// `SimulatorOSSupport`). Like Device Hub's check, it needs the runtime:
    /// a device whose runtime is missing is not too old but unavailable.
    var isTooOld: Bool {
        hasInstalledRuntime && SimulatorOSSupport.isTooOld(platform: platform, version: osVersion)
    }

    /// What Device Hub does not list: a never-used default or a too-old OS.
    var isHiddenByDefault: Bool { isUnusedDefault || isTooOld }

    /// "iOS 27.0"; "iPadOS 26.5" for an iPad, as Device Hub names it (the
    /// simulator's runtime is iOS either way, measured on DH 27.0's stopped
    /// iPad: "iPadOS 26.5 Simulator").
    var osLabel: String? {
        let name = (platform == "iOS" && productFamily == "iPad") ? "iPadOS" : platform
        switch (name, osVersion) {
        case let (name?, version?): return "\(name) \(version)"
        case let (name?, nil): return name
        default: return nil
        }
    }

    init(
        device: SimulatorDevice,
        runtimes: [SimulatorRuntime],
        deviceTypes: [SimulatorDeviceType],
        defaultDeviceUDIDs: Set<String>
    ) {
        self.device = device
        let runtime = runtimes.first { $0.identifier == device.runtimeIdentifier }
        let parsed = SimctlParsing.runtimePlatformAndVersion(identifier: device.runtimeIdentifier)
        platform = runtime?.platform ?? parsed?.platform
        osVersion = runtime?.version ?? parsed?.version
        osBuild = runtime.map(\.buildVersion).flatMap { $0.isEmpty ? nil : $0 }
        hasInstalledRuntime = runtime != nil
        let deviceType = device.deviceTypeIdentifier.flatMap { identifier in
            deviceTypes.first { $0.identifier == identifier }
        }
        modelName = deviceType?.name
        productFamily = deviceType?.productFamily
        modelIdentifier = deviceType?.modelIdentifier
        deviceTypeBundlePath = deviceType?.bundlePath
        isDefaultCreated = defaultDeviceUDIDs.contains(device.udid)
        createdAt = device.dataPath.flatMap { path in
            let folder = URL(fileURLWithPath: path).deletingLastPathComponent()
            return (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        }
    }

    /// The platform-neutral row for this simulator in `runState`.
    func summary(runState: DeviceRunState) -> DeviceSummary {
        DeviceSummary(
            ref: .apple(udid),
            kind: .simulator,
            name: name,
            osName: platform,
            osVersion: osVersion,
            model: modelName,
            runState: runState,
            isAvailable: isAvailable
        )
    }

    /// The sidebar row's subtitle, Device Hub's: "Simulator" at rest, the
    /// operation in flight ("Starting", "Stopping", …), else a state that is
    /// not rest (a boot on its way to ready reads "Starting").
    func sidebarSubtitle(runState: DeviceRunState, operation: SimulatorLifecycleController.Operation?) -> String {
        if let operation { return operation.label }
        if !isAvailable { return "Unavailable" }
        switch runState {
        case .stopped, .ready: return "Simulator"
        case .booting: return "Starting"
        case .shuttingDown: return "Stopping"
        case .reconnecting: return "Reconnecting"
        case .unreachable: return "Not Responding"
        case .unauthorized: return "Unauthorized"
        }
    }

    /// The SF Symbol of the row's icon, by product family (device kind) and,
    /// for iPhones, by the model's screen design (SB-02, 2026-09-28). Device
    /// Hub's Apple TV row draws the "tv" screen-and-stand glyph, not the
    /// "appletv" box-and-remote one (measured on DH 27.0's sidebar: the AX
    /// description reads "Tv", and the artwork is a plain screen).
    var symbolName: String {
        switch productFamily {
        case "iPad": "ipad"
        case "Apple TV": "tv"
        case "Apple Watch": "applewatch"
        case "Apple Vision": "visionpro"
        default: Self.iPhoneSymbol(forModelName: modelName)
        }
    }

    /// `iphone.gen3` for a Dynamic-Island iPhone, else the plain `iphone`
    /// frame. Measured on DH 27.0's sidebar (2026-09-28): iPhone 17 / 17 Pro /
    /// 17 Pro Max read "Iphone, Third Generation" (`iphone.gen3`); iPhone 17e
    /// and the physical iPhone 12 read plain "Iphone". Heuristic, since DH
    /// exposes no model-capability flag for this: an "e" variant (16e, 17e,
    /// …) keeps the notch even at a high generation number; otherwise every
    /// variant from generation 15 on has Dynamic Island, and generation 14
    /// only its Pro models (14 Pro / 14 Pro Max) do.
    static func iPhoneSymbol(forModelName modelName: String?) -> String {
        guard let modelName, let generation = generationNumber(in: modelName) else { return "iphone" }
        if modelName.contains("\(generation)e") { return "iphone" }
        if generation >= 15 { return "iphone.gen3" }
        if generation == 14, modelName.contains("Pro") { return "iphone.gen3" }
        return "iphone"
    }

    /// "iPhone 17 Pro Max" → 17; "iPhone SE" → nil (no digits to read).
    private static func generationNumber(in modelName: String) -> Int? {
        guard let range = modelName.range(of: #"\d+"#, options: .regularExpression) else { return nil }
        return Int(modelName[range])
    }

    /// A short line for the stage and the window subtitle: the operation in
    /// flight, else the state.
    ///
    /// DH's stopped simulator reads just "iOS 26.5" — no "· Stopped" suffix, unlike a running one's
    /// plain OS label. Stopped and ready therefore share the OS label.
    func statusLine(runState: DeviceRunState, operation: SimulatorLifecycleController.Operation?) -> String {
        if let operation { return operation.label }
        if !isAvailable { return "Unavailable" }
        switch runState {
        case .stopped:
            return osLabel ?? "Stopped"
        case .booting:
            return "Starting"
        case .ready:
            return osLabel ?? "Running"
        case .shuttingDown:
            return "Stopping"
        case .reconnecting:
            return "Reconnecting"
        case .unreachable:
            return "Not Responding"
        case .unauthorized:
            return "Unauthorized"
        }
    }
}
