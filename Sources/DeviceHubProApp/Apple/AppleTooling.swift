import Foundation
import DeviceHubProKit

/// Where the Apple simulator tools come from: the probe of this Mac's Xcode
/// and the device set the app lists.
///
/// Only `AppEnvironment.live()` builds one for the user's Mac (the default
/// device set, the real CoreSimulator logs folder). A test builds one on a
/// stub simctl and a temporary set, and `AppEnvironment` without one has no
/// Apple tooling at all: no simctl is ever located or run (tier T0).
struct AppleTooling: Sendable {
    /// Probes the Mac (`AppleToolchain.probe`): the developer directory, the
    /// real simctl and devicectl, whether Xcode's first launch is complete.
    /// It reads files (and may run `xcode-select -p`) and runs no Xcode tool
    /// (bounded at 15 s), so the simulator provider runs it once, off the
    /// launch path, rather than `live()`.
    var probe: @Sendable () async -> AppleToolchain
    /// simctl's `--set`: nil for the user's default set (the one Xcode and
    /// Device Hub list), a folder for a private set. CoreDevice does not see
    /// a private set, so devicectl is never probed there.
    var deviceSet: URL?
    /// The folder holding the set's devices (`<UDID>/device.plist`) and its
    /// `device_set.plist`: what the watcher watches.
    var devicesDirectory: URL
    /// Where CoreSimulator writes each device's logs (`<folder>/<UDID>`),
    /// even for a private set; the app removes a deleted device's folder,
    /// which `simctl delete` can leave behind.
    var logsDirectory: URL
    /// Where the Mac's crash reporter writes crash reports, a simulator's
    /// processes' included (`~/Library/Logs/DiagnosticReports`; the
    /// `DHP_DIAGNOSTIC_REPORTS_DIR` switch points `live()` elsewhere).
    /// Only read, never changed; nil lists no crash reports, as tests do.
    var diagnosticReportsDirectory: URL? = nil
    /// The private simulator bridge for the live canvas (§7),
    /// made for the Xcode the probe found; nil keeps every simulator on the
    /// view-only canvas. `live()` makes `LiveSimulatorBridge`, which loads
    /// nothing until a session starts; tests pass a `FakeSimulatorBridge` or
    /// nothing.
    var makeBridge: @Sendable (AppleToolchain) -> (any SimulatorBridging)? = { _ in nil }
    /// Whether the bridge may load on this Mac's CoreSimulator
    /// (`BridgeCompatibility`, read from its Info.plist without loading it,
    /// `DHP_DISABLE_SIMBRIDGE` included).
    var bridgeVerdict: @Sendable () -> BridgeCompatibility.Verdict = { .disabled }
    /// Whether the CoreSimulator this process loaded for the live canvas is
    /// no longer the installed one: an Xcode update replaced it while the
    /// app runs (`BridgeCompatibility.isStale`). False before
    /// anything was loaded.
    var bridgeIsStale: @Sendable () -> Bool = { false }
    /// Xcode's DeviceKit, where a simulator's Apple chrome is read from
    /// (`DHP_DEVICEKIT_ROOT` points `live()` elsewhere, an
    /// empty folder showing the vector body a Mac without it gets); nil
    /// draws every simulator in the vector body, as tests do.
    var deviceKit: AppleDeviceKit?

    /// `~/Library/Logs/CoreSimulator`.
    static var userLogsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/CoreSimulator", isDirectory: true)
    }
}

/// What the app can do with Apple simulators on this Mac, for the UI: the
/// tier and, at T0, what the setup card says.
struct AppleToolingStatus: Equatable, Sendable {
    /// Whether the probe has answered; T0 until it has.
    var isProbed: Bool
    var tier: AppleToolchain.Tier
    /// The setup card's text at T0 ("iOS simulators and iPhones need Xcode.",
    /// "Open Xcode, accept the license and let it install its components (a few minutes), then come back."); nil from T1 on.
    var setupAdvice: String?
    /// What the hint's button does (nil at T1 and above, and before the probe).
    var guidance: AppleToolchain.XcodeGuidance? = nil
    /// "27.0".
    var xcodeVersion: String?
    /// "27A266a".
    var xcodeBuild: String?

    /// No Apple tooling in this environment.
    static let unavailable = AppleToolingStatus(
        isProbed: true,
        tier: .t0,
        setupAdvice: AppleToolchain.XcodeGuidance.notInstalled.message,
        guidance: .notInstalled,
        xcodeVersion: nil,
        xcodeBuild: nil
    )

    /// Before the probe answers.
    static let probing = AppleToolingStatus(
        isProbed: false,
        tier: .t0,
        setupAdvice: nil,
        xcodeVersion: nil,
        xcodeBuild: nil
    )

    /// The status `toolchain` gives, with the devicectl probe (T2) and the
    /// canvas's smoke check (T3).
    init(toolchain: AppleToolchain, devicectlProbe: DevicectlInfo?, canvasReady: Bool) {
        isProbed = true
        tier = toolchain.tier(devicectlProbe: devicectlProbe, canvasReady: canvasReady)
        setupAdvice = toolchain.setupAdvice
        guidance = toolchain.guidance
        xcodeVersion = toolchain.xcodeVersion
        xcodeBuild = toolchain.xcodeBuild
    }

    init(
        isProbed: Bool,
        tier: AppleToolchain.Tier,
        setupAdvice: String?,
        guidance: AppleToolchain.XcodeGuidance? = nil,
        xcodeVersion: String?,
        xcodeBuild: String?
    ) {
        self.isProbed = isProbed
        self.tier = tier
        self.setupAdvice = setupAdvice
        self.guidance = guidance
        self.xcodeVersion = xcodeVersion
        self.xcodeBuild = xcodeBuild
    }
}
