import Foundation
import DeviceHubProKit

/// What a problem report needs from the running app: the inputs the Kit reads
/// the Mac with (the adb and emulator this app uses) and a snapshot of what
/// only the app knows (its inventory, windows, preferences and Apple tooling).
///
/// Both are read when the Report a Problem sheet opens. The snapshot is held
/// in memory for that report and never written anywhere; the Kit copies from
/// it what a report carries and never asks a device for it again.
extension AppModel {
    /// The environment's inputs with the adb and emulator this model uses
    /// now (Settings' custom emulator binary included).
    func problemReportInputs() -> ProblemReportInputs {
        var inputs = services.environment.problemReportInputs()
        if let adbClient, adbClient.isResolved {
            inputs.adbURL = adbClient.adbURL
        } else {
            inputs.adbURL = nil
        }
        inputs.emulatorURL = emulatorManager?.emulatorURL
        return inputs
    }

    /// The serials and names to keep beside an error recorded now
    /// (`RecentProblemStore`): the phones the inventory lists (each one's
    /// serials, its other transports' and its hardware serial) and the Apple
    /// devices it lists (their UDIDs and the names their owners gave them). An
    /// error names them, and the report is made after the phone was unplugged.
    nonisolated static func recentProblemIdentifiers(
        devices: [AndroidDevice],
        appleDevices: [ApplePhysicalDevice]
    ) -> RecentProblemIdentifiers {
        var identifiers = RecentProblemIdentifiers()
        for device in devices where !device.isEmulator {
            let group = [device.serial] + device.alternateSerials + [device.hardwareSerial].compactMap { $0 }
            identifiers.phones.append(group.filter { !$0.isEmpty })
        }
        for device in appleDevices {
            identifiers.secrets.append(device.hardwareUDID)
            identifiers.secrets.append(device.coreDeviceIdentifier)
            if let name = device.name, !isGenericDeviceName(name, of: device) { identifiers.secrets.append(name) }
        }
        identifiers.secrets = identifiers.secrets.filter { !$0.isEmpty }
        return identifiers
    }

    /// The app's own view of the problem: devices as the inventory holds them,
    /// the adb health, one entry per window, the preferences as yes/no and
    /// the Apple tooling already probed.
    func problemReportState() -> ProblemReportAppState {
        let devices = inventory.realDevices
        var androidVersions: [String: String] = [:]
        for device in devices where !device.isEmulator {
            if let version = inventory.deviceInfos[device.serial]?.androidVersion, !version.isEmpty {
                androidVersions[device.serial] = version
            }
        }
        var consoleNames: [String: String] = [:]
        for (serial, entry) in inventory.avdNamesBySerial { consoleNames[serial] = entry.avd }

        return ProblemReportAppState(
            devices: devices,
            androidVersions: androidVersions,
            consoleNames: consoleNames,
            emulatorListAvds: catalog.avdsLoaded ? catalog.avds : nil,
            adbAvailable: adbIsAvailable,
            adbServerProblem: adbServerProblem,
            watcherDegraded: inventory.watcherDegraded,
            localNetworkAccess: Self.describe(adbRecovery.localNetworkAccess),
            adbRestarts: adbRecovery.restartCount,
            startingAvds: boot.startingAvdNames.sorted(),
            windows: registry.workspaces.map { problemReportWindow(of: $0) },
            preferences: problemReportPreferences(),
            apple: problemReportAppleState(),
            secrets: problemReportSecrets(),
            simulatorUDIDs: simulators.simulators.map(\.udid)
        )
    }

    // MARK: - Parts

    private func problemReportWindow(of workspace: DeviceWorkspace) -> ProblemReport.WindowInfo {
        let selection = Self.problemReportSelection(workspace.deviceSelection)
        var avd = selection.avd
        if avd == nil, case .device(let serial)? = workspace.deviceSelection {
            avd = inventory.avdNamesBySerial[serial]?.avd
        }
        return ProblemReport.WindowInfo(
            selection: selection.kind,
            avd: avd,
            screenStalled: workspace.mirror.emulatorScreenStalled,
            streamWarning: workspace.mirror.mirrorStreamWarning,
            unresponsivePolls: workspace.controlsPanel.emulatorUnresponsivePolls,
            recoveryCard: workspace.controlsPanel.recoveryReason?.title,
            foldable: problemReportFoldable(of: workspace)
        )
    }

    /// The foldable simulator the window shows, as the app holds it (no
    /// simulator is asked); nil for any other selection.
    private func problemReportFoldable(of workspace: DeviceWorkspace) -> ProblemReport.FoldableInfo? {
        let fold = workspace.simulatorFold
        guard fold.showsFoldControls, let device = workspace.context.device, device.platform == .apple,
              let entry = simulators.entry(udid: device.id)
        else { return nil }
        let canvas = workspace.simulatorCanvas
        let view: ProblemReport.FoldView = fold.deviceModel == nil || !workspace.window.showDeviceFrame
            ? .flat2D
            : (preferences.showDeviceModel ? .turnable3D : .front3D)
        return Self.problemReportFoldable(
            model: entry.modelName ?? "foldable simulator",
            record: simulators.folds.record(of: entry.udid),
            posture: fold.postureChoice,
            shownPanel: canvas.shownPanel(of: entry.udid),
            lastRead: canvas.lastLitReadings[entry.udid],
            screensStuck: canvas.stuckScreens == entry.udid,
            view: view,
            now: Date()
        )
    }

    /// `problemReportFoldable` from what the app holds.
    nonisolated static func problemReportFoldable(
        model: String,
        record: SimulatorFoldRecord,
        posture: SimulatorFoldPostureChoice?,
        shownPanel: SimulatorFoldPanel?,
        lastRead: SimulatorCanvasController.LitPanelReading?,
        screensStuck: Bool,
        view: ProblemReport.FoldView,
        now: Date
    ) -> ProblemReport.FoldableInfo {
        func panel(_ panel: SimulatorFoldPanel) -> ProblemReport.FoldPanel { panel == .inner ? .inner : .outer }
        func reading(_ reading: SimulatorReadiness.ScreenReading?) -> ProblemReport.PanelReading? {
            guard let reading else { return nil }
            let content: ProblemReport.PanelContent = switch reading.content {
            case .dark: .dark
            case .homeScreen: .screen
            case .bootScreen: .bootLogo
            }
            return ProblemReport.PanelReading(content: content, grey: Int((reading.luminance * 255).rounded()))
        }
        let shownPosture: ProblemReport.FoldPosture = switch posture {
        case .preset(.closed)?: .closed
        case .preset(.halfOpened)?: .partiallyOpen
        case .preset(.opened)?: .open
        case .held(.laptop)?: .laptop
        case .held(.tent)?: .tent
        case nil: .other
        }
        let held: ProblemReport.FoldHold = switch record.pose ?? .portrait {
        case .portrait: .portrait
        case .portraitUpsideDown: .upsideDown
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        case .faceUp: .faceUp
        case .faceDown: .faceDown
        }
        return ProblemReport.FoldableInfo(
            model: model,
            hingeAngle: record.angle,
            posture: shownPosture,
            held: held,
            litPanel: panel(record.panel),
            shownPanel: shownPanel.map(panel),
            lastRead: lastRead.map {
                ProblemReport.PanelRead(
                    secondsAgo: max(0, Int(now.timeIntervalSince($0.at).rounded())),
                    outer: reading($0.outer),
                    inner: reading($0.inner),
                    lit: $0.lit.map(panel)
                )
            },
            screensStuck: screensStuck,
            view: view
        )
    }

    /// What the window shows, never a serial or a UDID: "emulator", "phone",
    /// "simulator", "iPhone or iPad", "Pixel catalog" or "none", with the AVD
    /// name when the selection is an AVD.
    nonisolated static func problemReportSelection(_ selection: DeviceSelection?) -> (kind: String, avd: String?) {
        switch selection {
        case .avd(let name)?: ("emulator", name)
        case .device(let serial)?: (serial.hasPrefix("emulator-") ? "emulator" : "phone", nil)
        case .pixel?: ("Pixel catalog", nil)
        case .simulator?: ("simulator", nil)
        case .physicalApple?: ("iPhone or iPad", nil)
        case nil: ("none", nil)
        }
    }

    /// Yes/no and counts only: no path, no team and no device identifier.
    private func problemReportPreferences() -> ProblemReport.Preferences {
        ProblemReport.Preferences(
            customEmulatorBinary: !preferences.emulatorBinaryPath.isEmpty,
            customSDKFolder: !preferences.androidSDKPath.isEmpty,
            emulatorAudio: preferences.emulatorAudioMode.rawValue,
            autoRepairAvdDisplay: preferences.autoRepairAvdDisplay,
            localNetworkInUse: preferences.localNetworkInUse,
            showPhysicalAppleDevices: preferences.showPhysicalAppleDevices,
            enabledPhysicalDeviceCount: preferences.enabledPhysicalAppleDevices.count,
            physicalFastInput: preferences.physicalFastInput,
            physicalNativeLiveView: preferences.physicalNativeLiveView,
            developmentTeamSet: !preferences.physicalControlTeamID.isEmpty
        )
    }

    /// The Apple tooling as the sidebar already knows it: no probe, no simctl
    /// and no devicectl runs for a report.
    private func problemReportAppleState() -> ProblemReportAppState.AppleState {
        let tooling = simulators.tooling
        return ProblemReportAppState.AppleState(
            tier: tooling.tier.description,
            isProbed: tooling.isProbed,
            xcodeVersion: tooling.xcodeVersion,
            xcodeBuild: tooling.xcodeBuild,
            setupAdvice: tooling.setupAdvice,
            toolchain: simulators.toolchain,
            simulatorsListed: simulators.hasListed,
            simulatorCount: simulators.simulators.count,
            bootedCount: simulators.simulators.filter { $0.device.isBooted }.count,
            runtimeCount: simulators.runtimesRead ? simulators.runtimes.count : nil,
            watcherHealth: simulators.watcherHealth.map(Self.describe),
            bridge: Self.describe(simulators.bridgeVerdict()),
            canvasReadyCount: simulators.canvasReadyUDIDs.count
        )
    }

    /// Values the report must never show, handed to its scrubber as literals:
    /// the signing team, the enabled devices' hardware UDIDs, every physical
    /// device the inventory lists (identifiers and the names their owners
    /// gave them) and the `DHP_IPHONE_UDID` value.
    private func problemReportSecrets() -> [String] {
        var secrets: [String] = []
        secrets.append(preferences.physicalControlTeamID)
        secrets.append(contentsOf: preferences.enabledPhysicalAppleDevices)
        if let udid = launchOptions.iphoneUDID { secrets.append(udid) }
        if let udid = physicalInventory.restrictedUDID { secrets.append(udid) }
        for entry in physicalInventory.entries {
            secrets.append(entry.device.hardwareUDID)
            secrets.append(entry.device.coreDeviceIdentifier)
            // A name the owner chose can hold their own; one that is only the
            // model's ("iPhone", "iPhone 12") says nothing and would blank
            // every mention of the model.
            if let name = entry.device.name, !Self.isGenericDeviceName(name, of: entry.device) {
                secrets.append(name)
            }
        }
        var seen = Set<String>()
        return secrets.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    nonisolated static func isGenericDeviceName(_ name: String, of device: ApplePhysicalDevice) -> Bool {
        let generic: Set<String> = ["iphone", "ipad"]
        let lowered = name.lowercased()
        return generic.contains(lowered)
            || lowered == device.marketingName?.lowercased()
            || lowered == device.productType?.lowercased()
    }

    // MARK: - Wording

    nonisolated static func describe(_ access: LocalNetworkAccess) -> String {
        switch access {
        case .unknown: "unknown"
        case .allowed: "allowed"
        case .denied: "denied"
        }
    }

    nonisolated static func describe(_ health: SimulatorWatcherHealth) -> String {
        switch health {
        case .listFailing(let attempt): "simctl list failing (\(attempt) in a row)"
        case .degraded: "file watcher off, polling"
        }
    }

    nonisolated static func describe(_ verdict: BridgeCompatibility.Verdict) -> String {
        switch verdict {
        case .allowlisted(let version): "allowed (CoreSimulator \(version))"
        case .untestedAllowed(let version): "untested build, opted in (CoreSimulator \(version))"
        case .untested(let version): "untested build, off (CoreSimulator \(version))"
        case .tooOld(let version): "too old (CoreSimulator \(version))"
        case .unknownVersion: "version unknown"
        case .disabled: "off"
        }
    }
}

extension AppServices {
    /// What `StatusCenter` keeps beside an error recorded now, and what a
    /// report adds to what was kept: the rows adb lists and the merged rows
    /// (which also hold a phone that is gone but whose window waits for it).
    func recentProblemIdentifiers() -> RecentProblemIdentifiers {
        var seen = Set<String>()
        let rows = (inventory.realDevices + inventory.devices).filter { seen.insert($0.serial).inserted }
        return AppModel.recentProblemIdentifiers(
            devices: rows,
            appleDevices: physicalInventory.entries.map(\.device)
        )
    }
}
