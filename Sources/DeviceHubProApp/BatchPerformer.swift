import Foundation
import DeviceHubProKit

/// A device's part of Apply to Selected that failed in Device Hub Pro's own words
/// (a missing tool, an emulator that did not take a location).
struct BatchPerformerError: Error, Equatable, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

/// Runs one planned operation (`BatchOperation`) on one device of Apply to
/// Selected, through the mechanisms the Controls rows use, by serial or
/// UDID rather than through the mirrored device's context:
///
/// - Android: adb for the appearance, text size, language, link, install,
///   demo mode and screenshot; the emulator's gRPC for the location (its
///   port resolved like the mirror's, `GrpcPortService`).
/// - Simulators: `AppleControlsBackend` over simctl for the appearance, text
///   size, language, location and status bar (devicectl is not asked: its
///   first call on a simulator takes seconds); simctl for the link and the
///   screenshot; the Apps inspector's install checks for a build.
///
/// What a panel keeps for a device follows a batch write: the status bar's
/// put-back record (`StatusBarDemoController.setDemoModeForBatch`, on the
/// controller of the workspace that mirrors the device) and a simulator's
/// respring, location and status bar (`AppleControlsController.noteBatchChange`,
/// on every workspace's panel).
@MainActor
final class BatchPerformer {
    private let adbClient: AdbClient?
    private let grpcPorts: GrpcPortService
    private let simulators: SimulatorInventory
    /// The simulator's install path: the owning workspace's inspector
    /// install-check state when one mirrors it, else the focused
    /// workspace's — never a fixed workspace's (a batch install must land
    /// in the window actually showing that simulator's Apps tab).
    private let simulatorApps: @MainActor (_ udid: String) -> SimulatorAppsController
    /// What Device Hub Pro keeps per simulator: the status bar model a clean
    /// status bar starts from.
    private let appleDeviceMemory: AppleDeviceMemory
    /// Tells the Controls panels about a simulator change.
    private let noteAppleBatchChange: @MainActor (_ change: AppleControlChange, _ udid: String) -> Void
    /// The status bar controller a device's write goes through.
    private let statusBar: @MainActor (_ serial: String) -> StatusBarDemoController
    /// The adb rows now: the emulator a location goes to.
    private let devices: @MainActor () -> [AndroidDevice]
    /// The location controller of the window that mirrors a serial, when
    /// one does: a batch location goes through it, so a playing route is
    /// stopped and the row shows the new fix.
    private let locationOwner: @MainActor (_ serial: String) -> LocationController?

    /// How long a simulator screenshot may take: simctl waits 61 s on a
    /// screen that is off (the canvas's bound).
    static let simulatorScreenshotTimeout: Duration = .seconds(20)

    init(
        adbClient: AdbClient?,
        grpcPorts: GrpcPortService,
        simulators: SimulatorInventory,
        simulatorApps: @escaping @MainActor (_ udid: String) -> SimulatorAppsController,
        appleDeviceMemory: AppleDeviceMemory,
        noteAppleBatchChange: @escaping @MainActor (_ change: AppleControlChange, _ udid: String) -> Void,
        statusBar: @escaping @MainActor (_ serial: String) -> StatusBarDemoController,
        devices: @escaping @MainActor () -> [AndroidDevice],
        locationOwner: @escaping @MainActor (_ serial: String) -> LocationController? = { _ in nil }
    ) {
        self.adbClient = adbClient
        self.grpcPorts = grpcPorts
        self.simulators = simulators
        self.simulatorApps = simulatorApps
        self.appleDeviceMemory = appleDeviceMemory
        self.noteAppleBatchChange = noteAppleBatchChange
        self.statusBar = statusBar
        self.devices = devices
        self.locationOwner = locationOwner
    }

    /// Where a profile's skipped and failed settings are reported
    /// (`MultiDeviceController.recordProfileNotes`).
    var recordProfileNotes: @MainActor (_ targetID: String, _ notes: [String]) -> Void = { _, _ in }

    /// A profile's operations on one device, one after the other: a setting
    /// the device turns out not to take is noted and the rest go on; any
    /// failure is thrown at the end, naming each setting.
    private func performProfile(_ plan: ProfilePlan, target: BatchTarget, context: BatchRunContext) async throws {
        var skips: [ProfileSkip] = []
        var failures: [String] = []
        var applied = 0
        for operation in plan.operations {
            do {
                try await perform(target, operation, context)
                applied += 1
            } catch let skip as BatchSkip {
                skips.append(ProfileSkip(field: operation.profileField, reason: skip.reason))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append("\(operation.profileField): \(MultiDeviceController.describe(error))")
            }
        }
        if let line = ProfileSkip.summary(skips, on: target.name) {
            recordProfileNotes(target.id, [line])
        }
        if !failures.isEmpty {
            throw BatchPerformerError(failures.joined(separator: "; "))
        }
        if applied == 0 {
            throw BatchSkip(skips.map(\.text).joined(separator: ", "))
        }
    }

    func perform(_ target: BatchTarget, _ operation: BatchOperation, _ context: BatchRunContext) async throws {
        guard let ref = target.ref else { throw BatchSkip("Not running") }
        switch ref.platform {
        case .android:
            try await performAndroid(serial: ref.id, target, operation, context)
        case .apple:
            try await performApple(udid: ref.id, target, operation, context)
        }
    }

    // MARK: - Android

    private func performAndroid(
        serial: String,
        _ target: BatchTarget,
        _ operation: BatchOperation,
        _ context: BatchRunContext
    ) async throws {
        guard let adbClient else { throw BatchPerformerError("The Android tools weren't found.") }
        switch operation {
        case .appearance(let dark):
            try await adbClient.setAppearanceMode(serial: serial, dark ? .dark : .light)
        case .androidTextSize(let step):
            try await adbClient.setFontScale(serial: serial, scale: step.rawValue)
        case .language(let locale):
            let support = try await adbClient.languageTimeSupport(serial: serial)
            guard support.canSetDeviceLanguage else {
                throw BatchSkip("The system language cannot be changed before Android 8.0")
            }
            _ = try await adbClient.setDeviceLocales(serial: serial, [locale], support: support)
        case .location(let latitude, let longitude):
            try await setEmulatorLocation(serial: serial, latitude: latitude, longitude: longitude)
        case .openAndroidLink(let request):
            let result = try await adbClient.openLink(serial: serial, request, apiLevel: target.apiLevel)
            switch result.outcome {
            case .started, .deliveredToTop, .broughtToFront, .otherWarning:
                break
            case .notResolved:
                throw BatchPerformerError("No app on the device opens this link.")
            case .refused(let reason):
                throw BatchPerformerError(reason)
            }
        case .install(let build):
            try await adbClient.install(serial: serial, apkURL: build.url)
        case .statusBar(let clean):
            try await statusBar(serial).setDemoModeForBatch(clean, serial: serial)
        case .screenshot:
            let destination = try screenshotDestination(target, context)
            let png = try await adbClient.screenshot(serial: serial)
            try png.write(to: destination, options: .atomic)
        case .reduceMotion(let on):
            try await adbClient.setReduceMotion(serial: serial, enabled: on)
        case .increaseContrast(let on):
            try await adbClient.setHighTextContrast(serial: serial, enabled: on)
        case .showBorders(let on):
            try await adbClient.setDebugLayout(serial: serial, enabled: on)
        case .screenReader(let on):
            let packages = try await adbClient.listPackages(serial: serial, thirdPartyOnly: false)
            if let package = DeviceSettingsParsing.talkBackPackage(fromPackages: packages) {
                try await adbClient.setTalkBack(serial: serial, enabled: on, packageID: package)
            } else if on {
                throw BatchSkip("TalkBack is not installed")
            }
        case .timeFormat(let format):
            try await adbClient.setTimeFormat(serial: serial, format)
        case .clearLocation:
            throw BatchSkip("an emulator has no way to clear its simulated location")
        case .profile(let plan):
            try await performProfile(plan, target: target, context: context)
        case .simulatorTextSize, .openSimulatorURL:
            throw BatchSkip("Not an Android operation")
        }
    }

    /// The emulator's gRPC `setGps`, on the port the mirror would use.
    private func setEmulatorLocation(serial: String, latitude: Double, longitude: Double) async throws {
        guard let device = devices().first(where: { $0.serial == serial }) else {
            throw BatchSkip("No longer listed")
        }
        if let owner = locationOwner(serial) {
            if let failure = await owner.choose(.coordinate(latitude: latitude, longitude: longitude)) {
                throw BatchPerformerError(failure)
            }
            return
        }
        switch await grpcPorts.resolveGrpcPort(for: device) {
        case .success(let port):
            guard await EmulatorControls.setLocation(port: port, latitude: latitude, longitude: longitude) else {
                throw BatchPerformerError("The emulator did not take the location.")
            }
        case .failure(let failure):
            throw BatchPerformerError(failure.reason ?? "The emulator's control port could not be found.")
        }
    }

    // MARK: - Simulators

    private func performApple(
        udid: String,
        _ target: BatchTarget,
        _ operation: BatchOperation,
        _ context: BatchRunContext
    ) async throws {
        guard let simctl = simulators.simctl else {
            throw BatchPerformerError("Xcode's simulator tools were not found.")
        }
        switch operation {
        case .appearance(let dark):
            try await apply(.appearance(dark: dark), udid: udid, simctl: simctl)
        case .simulatorTextSize(let size):
            try await apply(.textSize(size), udid: udid, simctl: simctl)
        case .language(let locale):
            try await apply(.language(locale), udid: udid, simctl: simctl)
        case .location(let latitude, let longitude):
            try await apply(.location(latitude: latitude, longitude: longitude), udid: udid, simctl: simctl)
        case .openSimulatorURL(let url):
            try await simctl.openURL(udid: udid, url: url)
        case .install(let build):
            try await simulatorApps(udid).installForBatch(build.url, udid: udid)
        case .statusBar(let clean):
            // The Screenshot preset over the model the panel keeps, as its
            // preset menu applies it.
            let model = clean
                ? SimulatorStatusBarPreset.screenshot.applied(to: appleDeviceMemory.statusBars[udid] ?? SimulatorStatusBarState())
                : nil
            try await apply(.statusBar(model), udid: udid, simctl: simctl)
        case .screenshot:
            let destination = try screenshotDestination(target, context)
            try await simctl.screenshot(udid: udid, to: destination, timeout: Self.simulatorScreenshotTimeout)
        case .reduceMotion(let on):
            try await apply(.reduceMotion(on), udid: udid, simctl: simctl, usesDevicectl: true)
        case .increaseContrast(let on):
            try await apply(.increaseContrast(on), udid: udid, simctl: simctl, usesDevicectl: true)
        case .showBorders(let on):
            try await apply(.showBorders(on), udid: udid, simctl: simctl, usesDevicectl: true)
        case .screenReader(let on):
            try await apply(.voiceOver(on), udid: udid, simctl: simctl, usesDevicectl: true)
        case .timeFormat(let format):
            try await apply(.timeFormat(format), udid: udid, simctl: simctl)
        case .clearLocation:
            try await apply(.clearLocation, udid: udid, simctl: simctl)
        case .profile(let plan):
            try await performProfile(plan, target: target, context: context)
        case .androidTextSize, .openAndroidLink:
            throw BatchSkip("Not a simulator operation")
        }
    }

    /// `usesDevicectl`: the settings only CoreDevice reaches (Reduce Motion,
    /// Show Borders, VoiceOver): asked once for this simulator, never for a
    /// private set. A setting its route does not offer is a skip, not a
    /// failure.
    private func apply(
        _ change: AppleControlChange, udid: String, simctl: SimctlClient, usesDevicectl: Bool = false
    ) async throws {
        var devicectl: DevicectlClient?
        var dataDirectory: URL?
        if usesDevicectl {
            if !simulators.devicectlReady { _ = await simulators.probeDevicectlIfNeeded(udid: udid) }
            if simulators.devicectlReady, let toolchain = simulators.toolchain,
               let entry = simulators.entry(udid: udid) {
                devicectl = try? toolchain.makeDevicectlClient(for: entry.device)
                dataDirectory = entry.device.dataPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            }
        }
        let backend = try AppleControlsBackend(udid: udid, simctl: simctl, devicectl: devicectl, dataDirectory: dataDirectory)
        do {
            try await backend.apply(change)
        } catch let error as AppleControlsError {
            throw BatchSkip(error.description)
        }
        noteAppleBatchChange(change, udid)
    }

    private func screenshotDestination(_ target: BatchTarget, _ context: BatchRunContext) throws -> URL {
        guard let destination = context.screenshotDestinations[target.id] else {
            throw BatchPerformerError("No file was named for its screenshot.")
        }
        return destination
    }
}
