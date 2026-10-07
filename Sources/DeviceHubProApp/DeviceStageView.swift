import SwiftUI
import UniformTypeIdentifiers
import DeviceHubProKit

/// The center stage: routes the device selection to a live detail (running),
/// a static detail (stopped AVD), a status panel (booting / unreachable /
/// unauthorized) or a prompt.
struct DeviceStageView: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace

    var body: some View {
        Group {
            switch workspace.deviceSelection {
            case .avd(let name):
                if let serial = workspace.liveSelectionSerial {
                    androidLive(serial: serial)
                } else if let card = model.catalog.avdCards.first(where: { $0.name == name }) {
                    avdStage(card: card)
                } else {
                    NoSelectionView(offersAndroidSetup: true)
                }
            case .device(let serial):
                // The episode comes first: adb lists a half-dead device as
                // `device`, so the health decider would route to the live
                // detail and leave a gray void while the transport is dead
                // (S4). The lifecycle's own episode state is the truth here.
                if let reconnect = workspace.reconnect, reconnect.serial == serial,
                   let device = model.inventory.devices.first(where: { $0.serial == serial }) {
                    ReconnectWaitingPanel(device: device, status: reconnect)
                } else if let live = workspace.liveSelectionSerial {
                    androidLive(serial: live)
                } else if let device = model.inventory.devices.first(where: { $0.serial == serial }),
                          let owner = model.registry.owner(of: .android(serial)), owner !== workspace {
                    // another workspace's session already
                    // shows this device — never a second attach racing it.
                    OwnedElsewherePlaceholder(deviceName: workspace.services.displayName(of: .android(serial)), owner: owner, device: .android(serial))
                } else if let device = model.inventory.devices.first(where: { $0.serial == serial }) {
                    deviceStage(device)
                } else {
                    NoSelectionView(offersAndroidSetup: true)
                }
            case .pixel(let skinName):
                if let live = workspace.liveSelectionSerial {
                    androidLive(serial: live)
                } else {
                    PixelDeviceDetailView(skinName: skinName)
                }
            case .simulator(let udid):
                if let entry = model.simulators.entry(udid: udid) {
                    if let owner = model.registry.owner(of: .apple(udid)), owner !== workspace {
                        OwnedElsewherePlaceholder(deviceName: entry.name, owner: owner, device: .apple(udid))
                    } else {
                        SimulatorStageView(entry: entry)
                    }
                } else {
                    NoSelectionView(offersAndroidSetup: true)
                }
            case .physicalApple(let udid):
                // The live screen (USB capture) or the screenshot preview,
                // view only, while its session runs;
                // otherwise the static panel.
                if let entry = model.physicalInventory.entry(udid: udid) {
                    if workspace.physicalLive.showsSession(for: entry.udid),
                       workspace.context.device == .physicalApple(entry.udid) {
                        LiveDetailView(device: .physicalApple(entry.udid))
                    } else {
                        PhysicalDeviceStageView(entry: entry)
                    }
                } else {
                    NoSelectionView(offersAndroidSetup: true)
                }
            case nil:
                NoSelectionView(offersAndroidSetup: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    /// An online Android device's live stage, or, while another window or tab
    /// holds its session, the "Shown in another window" placeholder: a second
    /// attach would be refused silently (`DeviceWorkspace.mirror(device:)`),
    /// leaving a stage that never connects.
    @ViewBuilder
    private func androidLive(serial: String) -> some View {
        if let owner = model.registry.owner(of: .android(serial)), owner !== workspace,
           let device = model.inventory.devices.first(where: { $0.serial == serial }) {
            OwnedElsewherePlaceholder(deviceName: workspace.services.displayName(of: .android(serial)), owner: owner, device: .android(serial))
        } else {
            LiveDetailView(device: .android(serial))
        }
    }

    /// The AVD panels (spec §6.4): stopped keeps the skin hero + Start,
    /// booting gets the same hero plus progress and the "Starting…" label.
    @ViewBuilder
    private func avdStage(card: AvdCard) -> some View {
        switch CanvasStatus.resolve(
            device: card.serial.flatMap { serial in
                model.inventory.devices.first(where: { $0.serial == serial })
            },
            isEmulator: true,
            booting: model.avdIsBooting(card.name)
        ) {
        case .booting(let label):
            AvdBootingView(avdName: card.name, label: label)
        default:
            AvdDetailView(avdName: card.name)
        }
    }

    /// The physical-device panels: online keeps the detail, adb's offline and
    /// unauthorized states get an explanation and a rescan.
    @ViewBuilder
    private func deviceStage(_ device: AndroidDevice) -> some View {
        switch CanvasStatus.resolve(
            device: device,
            isEmulator: device.isEmulator,
            booting: false
        ) {
        case .unreachable:
            DeviceStatusPanel(
                title: "Device unreachable",
                systemImage: "wifi.exclamationmark",
                message: DeviceStagePanelText.unreachable(name: device.displayName)
            )
        case .unauthorized:
            DeviceStatusPanel(
                title: "Approve USB debugging on the device",
                systemImage: "lock.trianglebadge.exclamationmark",
                message: DeviceStagePanelText.unauthorized(name: device.displayName)
            )
        default:
            PhysicalDeviceDetailView(serial: device.serial)
        }
    }
}

/// What the unreachable and unauthorized panels tell the user to do.
enum DeviceStagePanelText {
    static func unreachable(name: String) -> String {
        "\(name) isn\u{2019}t responding. Unlock it, unplug and replug the cable (try another cable or port if you can), "
            + "then press Rescan."
    }

    static func unauthorized(name: String) -> String {
        "Unlock \(name) and tap Allow on the \u{201C}Allow USB debugging?\u{201D} prompt; tick Always allow from this computer. "
            + "If no prompt appears, unplug and replug the cable, or open Developer options \u{25B8} "
            + "Revoke USB debugging authorizations on the phone and connect again. Then press Rescan."
    }
}

/// Android-designed panels for physical devices adb cannot use. Device Hub
/// had no unhealthy device to reference (spec §6.4), so there is no visual
/// reference to copy.
private struct DeviceStatusPanel: View {
    @Environment(AppModel.self) private var model
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            Button("Rescan") {
                Task { await model.refresh() }
            }
            .glassProminentButton()
            .disabled(model.isBusy)
        }
    }
}

/// "Shown in another window": the stage for a device
/// another workspace's session already owns. Show Window brings that
/// workspace's own window forward (`WorkspaceRegistry.activate`); Move Here
/// tears the owning workspace's session down (`.replaced`) and starts this workspace's
/// own session on the device, the same as picking it fresh once it is free.
private struct OwnedElsewherePlaceholder: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace
    let deviceName: String
    let owner: DeviceWorkspace
    let device: DeviceRef

    var body: some View {
        ContentUnavailableView {
            Label("Shown in another window", systemImage: "macwindow.on.rectangle")
        } description: {
            Text("\(deviceName) is already mirrored in another window.")
        } actions: {
            HStack(spacing: 8) {
                Button("Show Window") {
                    model.registry.activate(owner.id)
                }
                .glassProminentButton()

                Button("Move Here") {
                    moveHere()
                }
                .glassButton()
                .disabled(model.isBusy)
            }
        }
    }

    /// Ends the owning workspace's session (as its own Stop Mirror does — `.replaced`,
    /// which frees the device's claim) and attaches it here, the same path
    /// a fresh selection takes.
    private func moveHere() {
        owner.tearDownMirror(cause: .replaced)
        switch device.platform {
        case .android:
            guard let live = model.inventory.devices.first(where: { $0.serial == device.id }) else { return }
            Task { await workspace.mirror(device: live) }
        case .apple:
            workspace.simulatorCanvas.attach(device.id)
        }
    }
}

/// The stable "waiting to reconnect" stage (S4): same panel family as
/// `DeviceStatusPanel`, but driven by the lifecycle's episode state instead
/// of adb's flapping row state, so it holds still for the whole episode —
/// every machine-driven attempt window included — and only vacates when the
/// episode proves healthy or the selection changes.
///
/// DH's composition for a lost physical device: the device's own body art, "Currently Unavailable"
/// and a secondary line naming the device — never an alert (a device going
/// away is not an error; the alert is suppressed at the source in
/// `TransportErrorPolicy.isDisconnect`). Unlike DH, adb needs a nudge, so
/// this keeps Reconnect/Rescan and our own reconnect-cycle copy below DH's
/// line, as their own addition rather than folded into it.
private struct ReconnectWaitingPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace
    let device: AndroidDevice
    let status: ReconnectStatus
    @State private var showDetails = false

    /// The phone's body (`ConnectingView.phonePlan`, the same art the stage
    /// draws it with once nothing attaches): the displays its model last
    /// reported, upright, with a hole and corner when the shapes carry one.
    /// Nil for a model never mirrored, which falls back to a plain glyph.
    private var plan: DeviceComposition? {
        guard let modelName = device.model, !modelName.isEmpty else { return nil }
        return ConnectingView.phonePlan(shapes: workspace.mirror.displayShapes.shapes(forPhysicalModel: modelName))
    }

    var body: some View {
        StoppedStagePanel {
            Group {
                if let plan {
                    SkinHero(variant: nil, vector: plan)
                } else {
                    Image(systemName: "cable.connector")
                        .font(.system(size: 56))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: SkinHero.height)

            VStack(spacing: 4) {
                Text("Currently Unavailable")
                    .font(.system(size: ParityMetrics.stoppedNameFontSize, weight: ParityMetrics.stoppedNameFontWeight))
                Text(ReconnectWaitingCopy.unavailableLine(deviceName: workspace.services.displayName(of: .android(device.serial))))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 380)
            }
            .padding(.top, ParityMetrics.stoppedHeroToNameGap)

            VStack(spacing: 8) {
                Text(ReconnectWaitingCopy.body(isArmed: status.isArmed))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if status.isArmed, let attempt = status.attempt {
                    Text("Reconnecting… (attempt \(attempt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let error = workspace.mirror.lastTransportError {
                    DisclosureGroup("Details", isExpanded: $showDetails) {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.callout)
                    .disabled(model.isBusy)
                    .frame(maxWidth: 380)
                }
            }
            .padding(.top, 8)

            HStack(spacing: 8) {
                Button("Reconnect") {
                    workspace.requestReconnect(serial: device.serial)
                }
                .glassProminentButton()
                .disabled(model.isBusy)

                Button("Rescan") {
                    Task { await model.refresh() }
                }
                .glassButton()
                .disabled(model.isBusy)
            }
            .padding(.top, ParityMetrics.stoppedSubtitleToButtonGap)
        }
    }
}

/// The waiting panel's body copy, lifted out of the view so every sentence —
/// DH's own headline, the armed cycle's reassurance and the honest
/// exhausted state's instruction — is pinned by tests rather than eyeballed.
enum ReconnectWaitingCopy {
    /// DH's secondary line under "Currently Unavailable"
    /// ("<name> must be nearby or plugged in to connect
    /// with this Mac."), adapted for adb's own transports: a USB cable or
    /// wireless debugging over the LAN, neither of which is "nearby" in
    /// DH's Bluetooth sense.
    static func unavailableLine(deviceName: String) -> String {
        "\(deviceName) must be plugged in or on the same network (wireless debugging) to connect with this Mac."
    }

    static func body(isArmed: Bool) -> String {
        isArmed
            ? "Plug the cable back in. Device Hub Pro reconnects automatically."
            : "Reconnect the device, then press Reconnect or Rescan."
    }
}

/// Booting-AVD panel: Device Hub's booting stage (`BootSpinnerPanel`, a bare
/// spinner: the device and its name are hidden until the display is
/// connected). The stage flips to the live mirror as soon as adb reports the
/// device online (existing routing), so nothing here needs to observe frames.
struct AvdBootingView: View {
    let avdName: String
    let label: String
    /// The AVD home a skinless AVD's config is read from; nil for the
    /// model's (`ActiveDeviceContext.avdHome`). Unused now the device is not
    /// drawn while it boots.
    var avdHome: URL?

    var body: some View {
        BootSpinnerPanel(caption: nil, accessibilityLabel: label)
    }
}

/// Device Hub's "No Selection" (measured on DH 27.0 after the selected
/// simulator was deleted: the window is titled "Devices / No Selection", and
/// the stage and the inspector each show a centred "No Selection", 17 pt
/// secondary, centred under the toolbar band).
struct NoSelectionView: View {
    @Environment(AppModel.self) private var model
    /// The stage offers the guided Android setup on a Mac without the tools;
    /// the inspector's empty page does not.
    var offersAndroidSetup = false

    var body: some View {
        if offersAndroidSetup, AndroidSetupStage.isShown(
            adbAvailable: model.adbIsAvailable,
            dismissed: model.preferences.androidSetupDismissed,
            phase: model.androidSetup.phase
        ) {
            // A Mac with no Android tools: the guided setup instead of an
            // empty page.
            AndroidSetupStage()
        } else if offersAndroidSetup, AndroidReadyStage.isShown(
            adbAvailable: model.adbIsAvailable,
            avdsLoaded: model.catalog.avdsLoaded,
            avdCount: model.catalog.avds.count,
            deviceCount: model.inventory.realDevices.count,
            dismissed: model.preferences.androidReadyCardDismissed,
            phase: model.androidSetup.phase
        ) {
            // Tools installed, nothing to run apps on yet.
            AndroidReadyStage()
        } else {
            VStack(spacing: 4) {
                Text("No Selection")
                    .font(.system(size: ParityMetrics.noSelectionFontSize))
                    .foregroundStyle(.secondary)
                Text("Select a device in the sidebar.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Live detail

/// Running-device detail: live mirror inside the skin frame. Attaches to
/// the device when it appears. Logcat lives in the inspector.
struct LiveDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The device the stage shows live.
    let device: DeviceRef
    /// A simulator still booting whose display already has a frame: Device
    /// Hub's device with a black screen and a small spinner on it, under the
    /// usual pill, and no input to the screen (`SimulatorStageView`).
    var isBooting = false
    /// The device this view's attach task last ran for; until it has run the
    /// stage shows "Attaching…" rather than a Mirror button for a frame.
    @State private var attachAttemptedDevice: DeviceRef?

    var body: some View {
        Group {
            if let session = workspace.mirror.session, workspace.context.device == device {
                ZStack(alignment: .bottom) {
                    // The device runs behind the pill (DH's stage is one
                    // layer under it): the mirror fits above the pill's
                    // band, a zoomed one scrolls under the pill.
                    MirrorContainer(session: session, chrome: chrome, bottomBand: ParityMetrics.mainStagePillBand)
                        .environment(\.blanksMirror, isBooting)
                        .allowsHitTesting(!isBooting)
                        .overlay {
                            if isBooting {
                                // Light on the device's black screen, in the
                                // middle of the fitted device (above the
                                // pill's band).
                                ProgressView()
                                    .controlSize(.mini)
                                    .environment(\.colorScheme, .dark)
                                    .brightness(0.9)
                                    .padding(.bottom, ParityMetrics.mainStagePillBand)
                                    .accessibilityLabel("Starting")
                            }
                        }
                        .modifier(StageRemoteHook())
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .modifier(SimulatorInputNotice(device: device))
                        // The overlays over the mirror come and go like the
                        // status banner (they snapped in and out), and the
                        // display-only ones let clicks through to the
                        // device's top edge, which they cover.
                        .overlay {
                            if workspace.mirror.emulatorScreenStalled,
                               device.platform == .android, workspace.context.port != nil {
                                EmulatorScreenStalledPanel(device: device)
                                    .transition(.opacity)
                            }
                        }
                        // A screen that went off (Power, a timeout, the phone's
                        // own lock) shows black; the stage says why and wakes it.
                        .overlay {
                            if workspace.mirror.screenIsOff, device.platform == .android,
                               !workspace.mirror.emulatorScreenStalled,
                               let serial = workspace.menuTargetSerial {
                                ScreenOffBadge {
                                    Task {
                                        await workspace.mirror.wakeScreen(
                                            serial: serial, isEmulator: workspace.context.port != nil
                                        )
                                    }
                                }
                                .padding(.bottom, ParityMetrics.mainStagePillBand)
                                .transition(overlayTransition)
                            }
                        }
                        .task(id: device.platform == .android ? device.adbSerial : nil) {
                            guard device.platform == .android, let serial = device.adbSerial else { return }
                            await workspace.mirror.watchScreenPower(serial: serial)
                        }
                        .overlay(alignment: .top) {
                            VStack(spacing: 8) {
                                if workspace.media.isRecording {
                                    RecordingIndicator(elapsed: workspace.media.recordingElapsedText)
                                        .allowsHitTesting(false)
                                        .transition(overlayTransition)
                                }
                                // The stalled-screen panel already says the stream is
                                // gone; "reconnecting" over it would contradict it.
                                if let warning = workspace.mirror.mirrorStreamWarning,
                                   !(workspace.mirror.emulatorScreenStalled
                                       && device.platform == .android && workspace.context.port != nil) {
                                    MirrorStreamWarning(message: warning)
                                        .transition(overlayTransition)
                                }
                                if workspace.mirror.inputMonitor.isBlocked,
                                   session is any PhysicalSessionControlling {
                                    XiaomiInputBlockedBanner(monitor: workspace.mirror.inputMonitor)
                                        .transition(overlayTransition)
                                }
                                if let simulator = session as? any SimulatorSessionControlling,
                                   !simulator.isLiveCanvas {
                                    SimulatorViewOnlyBanner(udid: simulator.udid)
                                }
                                if let physical = session as? any PhysicalViewSession {
                                    PhysicalStatusLineView(session: physical)
                                }
                            }
                            .padding(.top, ParityMetrics.recordingIndicatorTopInset)
                            .animation(reduceMotion ? nil : MotionMetrics.banner, value: workspace.media.isRecording)
                            .animation(
                                reduceMotion ? nil : MotionMetrics.banner,
                                value: workspace.mirror.mirrorStreamWarning
                            )
                            .animation(
                                reduceMotion ? nil : MotionMetrics.banner,
                                value: workspace.mirror.inputMonitor.isBlocked
                            )
                        }
                        .overlay(alignment: .topLeading) {
                            if workspace.window.showMirrorStats, !workspace.mirror.statsText.isEmpty {
                                MirrorStatsHUD(text: workspace.mirror.statsText)
                                    .padding(.top, 12)
                                    .padding(.leading, 16)
                                    .allowsHitTesting(false)
                                    .transition(.opacity)
                            }
                        }
                        .animation(reduceMotion ? nil : MotionMetrics.banner, value: workspace.window.showMirrorStats)

                    pillZone
                }
                // "Screenshot Saved" and the zoom hint, over the pill.
                .overlay(alignment: .bottom) { StageBannerHost() }
            } else {
                ConnectingView(device: device, isAttachPending: attachAttemptedDevice != device)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: device) {
            attachAttemptedDevice = device
            await attachIfNeeded()
        }
        // A physical device's Apple chrome, read like a simulator's
        // (`PhysicalDeviceStageView` starts the read; this covers a session
        // that starts before it ran or before the device types were listed).
        .task(id: PhysicalChromeLoadKey(
            productType: model.physicalInventory.entry(udid: device.id)?.device.productType,
            deviceTypeCount: model.simulators.deviceTypes.count
        )) {
            guard workspace.context.isPhysicalView,
                  let phone = model.physicalInventory.entry(udid: device.id)
            else { return }
            await model.simulators.loadDisplayShape(forModelIdentifier: phone.device.productType)
        }
    }

    /// DH floats the pill 8 pt above the window's bottom edge, centered in
    /// the canvas. The band under the fitted mirror is reserved (PL-02, in
    /// `MirrorContainer`) so a device at Fit never overlaps the pill; a
    /// zoomed one scrolls behind it.
    private var pillZone: some View {
        DeviceControlPill()
            .frame(height: ParityMetrics.pillHeight)
            .padding(.bottom, ParityMetrics.pillBottomInset)
    }

    /// What the stage draws around the screen: the AVD's skin, by the adb
    /// serial, else the vector body; a simulator's Apple chrome, else the
    /// vector body around its device type's display, else the thin bezel.
    private var chrome: DeviceChrome {
        DeviceChromeResolver.chrome(
            device: device,
            avdCards: model.catalog.avdCards,
            forceVector: model.launchOptions.forceVectorChrome,
            appleDisplayShapes: device.platform == .apple ? workspace.mirror.liveDisplayShapes : [],
            appleChrome: DeviceChromeResolver.appleChrome(
                for: device,
                simulators: model.simulators,
                physical: model.physicalInventory
            )
        )
    }

    /// The status banner's transition (`StatusBannerHost`): down from the
    /// top with a fade, a plain fade under Reduce Motion.
    private var overlayTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)
    }

    /// Attaches when this device is not the one mirrored: an adb device
    /// through its row, a simulator through the simulator canvas (which
    /// starts nothing for one that is mirrored already). The model makes a
    /// cancelled or superseded attach (the user moved on while the port
    /// resolved) end silently, so nothing needs checking after the await.
    private func attachIfNeeded() async {
        // A simulator that is still booting is followed by the boot page
        // (`SimulatorCanvasController.followBootFrames`).
        if isBooting { return }
        // A physical device's session is the physical view's, driven by
        // `PhysicalLiveViewDriver`; nothing attaches here.
        if workspace.context.isPhysicalView { return }
        if device.platform == .apple {
            workspace.simulatorCanvas.attach(device.id)
            return
        }
        guard workspace.mirror.session == nil || workspace.context.device != device,
              let serial = device.adbSerial,
              let row = model.inventory.devices.first(where: { $0.serial == serial }),
              row.isOnline
        else {
            return
        }
        await workspace.mirror(device: row)
    }
}

/// Over an Android device whose screen is off: what the black screen is, and
/// a click to turn it on (`MirrorController.wakeScreen`). A real device would
/// need its power button; nobody guesses that from a black rectangle.
struct ScreenOffBadge: View {
    let wake: () -> Void

    var body: some View {
        Button(action: wake) {
            VStack(spacing: 6) {
                Image(systemName: "power")
                    .font(.system(size: 22, weight: .medium))
                Text("Screen is off")
                    .font(.headline)
                Text("Click to wake")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .environment(\.colorScheme, .dark)
        .help("Turn the screen on")
        .accessibilityLabel("Screen is off. Wake the screen")
    }
}

/// The emulator's display stream never delivered a frame although adb sees
/// the device (its host screenshot path is wedged; the guest is fine): the
/// stage says so instead of showing a black canvas for good. Restart Emulator
/// is the fix; Retry attaches again.
struct EmulatorScreenStalledPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace
    let device: DeviceRef

    static let title = "The emulator isn't sending its screen"
    static let detail = "Its display stream stopped responding. Restarting the emulator fixes it."

    private var row: AndroidDevice? {
        guard let serial = device.adbSerial else { return nil }
        return model.inventory.devices.first(where: { $0.serial == serial })
    }

    private var avdName: String? {
        guard let serial = device.adbSerial else { return nil }
        return model.catalog.avdCards.first(where: { $0.serial == serial })?.name
            ?? workspace.context.avdName
    }

    var body: some View {
        ContentUnavailableView {
            Label(Self.title, systemImage: "exclamationmark.triangle")
        } description: {
            Text(Self.detail)
        } actions: {
            HStack(spacing: 8) {
                if let avdName {
                    Button("Restart Emulator") {
                        Task { await model.restartEmulator(avd: avdName, workspace: workspace) }
                    }
                    .glassProminentButton()
                    .disabled(model.isBusy)
                }
                if let row {
                    Button("Retry") {
                        Task { await workspace.reattachMirror(device: row) }
                    }
                    .glassButton()
                    .disabled(model.isBusy)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// The live stage before its mirror runs: attaching (a spinner), a failed
/// attach (the reason and Retry), or no mirror at all (Mirror). It routes on
/// the model's attach state for this device — not on whether some other
/// device's session happens to be live, which left a failed second attach
/// spinning forever.
///
/// Once nothing is attaching (after Stop Mirror, or a failed attach) an
/// Android device is drawn above the status, as its stopped page would draw
/// it (`Illustration`). An Apple device keeps the status alone.
struct ConnectingView: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace
    /// The device the stage attaches to, named by its id. The attach state
    /// and the Mirror button are an adb device's, found by its adb serial.
    let device: DeviceRef
    /// The stage's attach task has not run for this device yet.
    let isAttachPending: Bool
    /// The AVD home a skinless AVD's config is read from; nil for the
    /// model's (`ActiveDeviceContext.avdHome`).
    var avdHome: URL?

    /// The device drawn above the status.
    enum Illustration: Equatable {
        /// A running AVD: its stopped page's hero (`AvdHero`), the skin's
        /// preferred variant with the corner the AVD last reported, or a
        /// skinless AVD's body planned from its `config.ini`.
        case avd(AvdCard)
        /// A phone: its body planned from the displays phones of its model
        /// last reported (`phonePlan(shapes:)`).
        case phone(DeviceComposition)
    }

    private var attach: MirrorController.MirrorAttach? {
        guard let serial = device.adbSerial,
              let attach = workspace.mirror.mirrorAttach, attach.serial == serial
        else { return nil }
        return attach
    }

    private var isAttaching: Bool {
        isAttachPending || (attach != nil && attach?.failure == nil)
    }

    /// How long a simulator whose live view just ended is shown as shutting
    /// down before the plain "live view is not running" status takes over.
    static let shutdownGrace: Duration = .seconds(2)
    @State private var graceOver = false

    /// A simulator whose session ended while the listing still says Booted:
    /// the moment a shutdown from outside (Device Hub, `simctl`) takes to
    /// show. Device Hub draws the device black for about 0.6 s and then its
    /// stopped page; this stage went straight to "Connecting / The live view
    /// is not running.", so it now shows the stopped page without its Start
    /// button (`SimulatorStagePhase.stopping`) for the grace period.
    private var simulatorEnding: SimulatorEntry? {
        guard device.platform == .apple, !graceOver, !isAttaching, attach == nil else { return nil }
        return model.simulators.entry(udid: device.id)
    }

    var body: some View {
        if let entry = simulatorEnding {
            SimulatorDetailView(entry: entry, phase: .stopping)
                .task(id: device) {
                    graceOver = false
                    try? await Task.sleep(for: Self.shutdownGrace)
                    graceOver = true
                }
        } else if isAttaching && attach?.failure == nil {
            // Device Hub's caption while the display connects.
            BootSpinnerPanel(caption: SimulatorStagePhase.connectingDisplayLabel, accessibilityLabel: "Connecting")
        } else if let illustration = Self.illustration(
            for: device,
            isAttaching: isAttaching,
            avdCards: model.catalog.avdCards,
            devices: model.inventory.devices,
            phoneShapes: { workspace.mirror.displayShapes.shapes(forPhysicalModel: $0) }
        ) {
            // The stopped page's layout (`AvdDetailView`): the hero above
            // the status, the whole group centred in the stage like DH's.
            StoppedStagePanel {
                hero(illustration)
                    .frame(height: SkinHero.height)
                status
            }
        } else {
            status
        }
    }

    /// What is drawn above the status, if anything:
    /// - nothing while the device attaches, and for an Apple device;
    /// - a running AVD (its card holds the device's serial): its hero;
    /// - a phone (a non-emulator adb device) whose model is known and has
    ///   reported its displays: its body;
    /// - nothing otherwise (a phone of a model never mirrored, an emulator
    ///   with no AVD card). An emulator never borrows a model's shapes, as
    ///   on the live stage (`MirrorController.liveDisplayShapes`): every AVD
    ///   of one system image shares its model name.
    static func illustration(
        for device: DeviceRef,
        isAttaching: Bool,
        avdCards: [AvdCard],
        devices: [AndroidDevice],
        phoneShapes: (String) -> [DisplayShape]
    ) -> Illustration? {
        guard !isAttaching, let serial = device.adbSerial else { return nil }
        if let card = avdCards.first(where: { $0.serial == serial }) {
            return .avd(card)
        }
        guard let row = devices.first(where: { $0.serial == serial }), !row.isEmulator,
              let model = row.model, !model.isEmpty,
              let plan = phonePlan(shapes: phoneShapes(model))
        else { return nil }
        return .phone(plan)
    }

    /// A phone's body at rest: the built-in panel that was lit at the last
    /// read (a foldable's open or folded screen; the first built-in one if
    /// none was), upright in its natural size, with its corner and its hole
    /// where the panel has it. Nil without a built-in panel.
    static func phonePlan(shapes: [DisplayShape]) -> DeviceComposition? {
        let builtIn = shapes.filter(\.isBuiltIn)
        guard let panel = builtIn.first(where: \.isOn) ?? builtIn.first else { return nil }
        return DeviceCompositionPlanner.vector(
            screen: panel.naturalSize,
            displays: shapes,
            fallbackDensityDpi: nil,
            quarterTurns: 0
        )
    }

    @ViewBuilder
    private func hero(_ illustration: Illustration) -> some View {
        switch illustration {
        case let .avd(card):
            AvdHero(
                avdName: card.name,
                variant: card.skin?.preferredVariant,
                hasSkin: card.skin != nil,
                avdHome: avdHome
            )
        case let .phone(plan):
            SkinHero(variant: nil, vector: plan)
        }
    }

    /// The status's line: the attach's failure, the attach in progress, or
    /// nothing running; a simulator's in the live view's words.
    static func statusDescription(for device: DeviceRef, isAttaching: Bool, failure: String?, name: String? = nil) -> String {
        let subject = name ?? "the device"
        if let failure {
            return "Could not connect to \(subject).\n\(failure)"
        }
        if isAttaching {
            return device.platform == .apple ? "Starting the live view…" : "Connecting to \(subject)…"
        }
        return device.platform == .apple ? "The live view is not running." : "Mirror is not running for this device."
    }

    /// Whether the status offers Show Live View: a simulator whose live
    /// view is not starting.
    static func offersShowLiveView(for device: DeviceRef, isAttaching: Bool) -> Bool {
        device.platform == .apple && !isAttaching
    }

    /// Show Live View: the simulator canvas starts the session (nothing for
    /// one mirrored already).
    static func showLiveView(_ device: DeviceRef, workspace: DeviceWorkspace) {
        workspace.simulatorCanvas.attach(device.id)
    }

    /// The device's display name for the status line (never its serial).
    private var deviceName: String? {
        guard let serial = device.adbSerial else { return nil }
        return model.inventory.devices.first(where: { $0.serial == serial })?.displayName
            ?? model.catalog.avdCards.first(where: { $0.serial == serial })?.displayName
    }

    /// The status's title, matching its line: connecting only while an
    /// attach runs.
    static func statusTitle(for device: DeviceRef, isAttaching: Bool, failure: String?) -> String {
        if failure != nil { return "Couldn't Connect" }
        if isAttaching { return "Connecting" }
        return device.platform == .apple ? "Live View Off" : "Mirror Stopped"
    }

    private var status: some View {
        ContentUnavailableView {
            Label(Self.statusTitle(for: device, isAttaching: isAttaching, failure: attach?.failure), systemImage: "rectangle.on.rectangle")
        } description: {
            Text(Self.statusDescription(for: device, isAttaching: isAttaching, failure: attach?.failure, name: deviceName))
        } actions: {
            if isAttaching {
                ProgressView()
                    .accessibilityLabel("Connecting")
            } else if let serial = device.adbSerial,
                      let row = model.inventory.devices.first(where: { $0.serial == serial }) {
                Button(attach?.failure == nil ? "Mirror" : "Retry") {
                    Task { await workspace.mirror(device: row) }
                }
                .glassProminentButton()
                .disabled(!row.isOnline || model.isBusy)
            } else if Self.offersShowLiveView(for: device, isAttaching: isAttaching) {
                Button("Show Live View") {
                    Self.showLiveView(device, workspace: workspace)
                }
                .glassProminentButton()
            }
        }
    }
}

/// The emulator stream failed and its session is reconnecting (it never
/// stops itself): a non-fatal note over the last frame, gone once frames
/// flow again. The failure text is in the tooltip.
private struct MirrorStreamWarning: View {
    let message: String

    var body: some View {
        Label("Video stream interrupted — reconnecting…", systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .liquidGlass()
            .glassHairline(in: Capsule())
            .help(message)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Video stream interrupted, reconnecting")
            .accessibilityValue(message)
    }
}

// MARK: - Mirror stats HUD

/// Our own debug readout over the live mirror (View menu): the same fps /
/// frames / dropped / latency line the perf harness logs.
private struct MirrorStatsHUD: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .liquidGlass()
            .glassHairline(in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Mirror statistics")
            .accessibilityValue(text)
    }
}

// MARK: - Recording indicator

/// Red dot + REC + elapsed time in a glass capsule over the mirror, shown
/// only while the host recorder runs (spec §8.3) — it ends the moment the
/// recorder does. Device Hub's record button has no elapsed readout, so this
/// is our own design.
private struct RecordingIndicator: View {
    let elapsed: String

    var body: some View {
        HStack(spacing: ParityMetrics.recordingIndicatorSpacing) {
            Circle()
                .fill(.red)
                .frame(
                    width: ParityMetrics.recordingIndicatorDotDiameter,
                    height: ParityMetrics.recordingIndicatorDotDiameter
                )
            Text("REC")
                .font(.system(
                    size: ParityMetrics.recordingIndicatorFontSize,
                    weight: .bold
                ))
                .foregroundStyle(.red)
            Text(elapsed)
                .font(.system(size: ParityMetrics.recordingIndicatorFontSize))
                .monospacedDigit()
        }
        .padding(.horizontal, ParityMetrics.recordingIndicatorHorizontalPadding)
        .padding(.vertical, ParityMetrics.recordingIndicatorVerticalPadding)
        .liquidGlass()
        .glassHairline(in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recording, \(elapsed) elapsed")
    }
}

// MARK: - Physical device detail

private struct PhysicalDeviceDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace
    let serial: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let device = model.inventory.devices.first(where: { $0.serial == serial }) {
                    Text(device.displayName)
                        .font(.title.bold())
                    Text(device.stateLabel)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .help("Serial: \(serial)")

                    if let info = model.inventory.deviceInfos[serial] {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                            GridRow {
                                Text("Model").foregroundStyle(.secondary)
                                Text(info.model)
                            }
                            GridRow {
                                Text("Android").foregroundStyle(.secondary)
                                Text("\(info.androidVersion) (API \(info.apiLevel))")
                            }
                            GridRow {
                                Text("ABI").foregroundStyle(.secondary)
                                Text(info.abi)
                            }
                        }
                    }

                    Button("Show Logs") {
                        Task {
                            await workspace.logcat.openLogcat(serial: serial)
                            workspace.window.selectInspectorTab(.diagnostics)
                        }
                    }
                    .glassProminentButton()
                    .disabled(!device.isOnline || model.isBusy)
                } else {
                    DeviceStatusPanel(
                        title: "Device not found",
                        systemImage: "questionmark.circle",
                        message: "This device isn't listed anymore. Rescan to look for it again."
                    )
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: serial) {
            if let device = model.inventory.devices.first(where: { $0.serial == serial }) {
                await model.inventory.loadInfo(for: device)
            }
        }
    }
}

// MARK: - Mirror (moved from ContentView, unchanged)

/// What the live stage accepts a drag of: a simulator also takes links (a
/// web link dragged from a browser); any other device takes files only, so a
/// link over an Android mirror is refused before it is dropped.
enum StageDropTypes {
    static func accepted(by platform: DevicePlatform?) -> [UTType] {
        platform == .apple ? [.fileURL, .url] : [.fileURL]
    }
}

private struct MirrorContainer: View {
    let session: any MirrorSessionProtocol
    let chrome: DeviceChrome
    /// The band at the bottom the pill floats in: the device is fitted above
    /// it and a zoomed one scrolls through it (behind the pill).
    var bottomBand: CGFloat = 0
    /// The stage's padding round the fitted device.
    private static let stagePadding: CGFloat = 10
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace
    /// Asks before a dropped certificate is trusted (the main window's).
    @Environment(SimulatorActionDialogs.self) private var simulatorDialogs: SimulatorActionDialogs?
    /// The fold strip's laid-out height (`FoldStripStage`). Kept here, not
    /// in the stage: `zoomableContent` builds the stage in two branches, so
    /// every fit↔zoom switch makes a new one, and a height kept there would
    /// start over for the first layout after each switch.
    @State private var foldStripHeight = FoldControlStrip.estimatedHeight
    /// The live session the stage has revealed (`revealWhenSettled`): a new
    /// one stays invisible until its first layout has settled.
    @State private var revealedSession: ObjectIdentifier?
    @State private var revealGeneration = 0

    var body: some View {
        GeometryReader { proxy in
            // What Fit fills: the stage less the pill's band. Zoom is
            // relative to it, as it always was.
            let fit = CGSize(width: proxy.size.width, height: max(proxy.size.height - bottomBand, 1))
            zoomableContent(visible: fit, stage: proxy.size, topInset: proxy.safeAreaInsets.top)
                .onAppear { workspace.window.stageViewportSize = fit }
                .onChange(of: fit) { _, newValue in
                    workspace.window.stageViewportSize = newValue
                    workspace.window.noteViewportChanged()
                }
                // Physical Size is a mode, not a scale: whenever the layout
                // moves (a window resize, a rotation, a new stream size),
                // close what is left of the gap to the real size.
                .onChange(of: workspace.mirror.mirrorViewState.videoPointsPerPixel) { _, _ in
                    workspace.window.resolvePendingZoom()
                    workspace.window.reconcileScaleZoom()
                }
                // The density can arrive after the first frame (an AVD's
                // `dumpsys display`): the opening zoom waits for it.
                .onChange(of: workspace.physicalPointsPerPixel()) { _, _ in
                    workspace.window.resolvePendingZoom()
                }
                .onChange(of: workspace.pointAccuratePointsPerPixel()) { _, _ in
                    workspace.window.resolvePendingZoom()
                }
                .onChange(of: workspace.mirror.mirrorViewState.devicePixelSize) { _, _ in
                    workspace.window.resolvePendingZoom()
                }
                .overlay(alignment: .top) {
                    if workspace.isInResizeMode {
                        ResizeModeBar()
                            .padding(.top, 12)
                            .transition(.opacity)
                    }
                }
        }
        // The main stage offers a Pixel skin's side buttons (HW-01); the
        // compact window, which shares `MirrorStageContent`, never does.
        .environment(\.showsHardwareButtons, true)
        .environment(\.reportsStageScale, true)
        .padding(Self.stagePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sendFilesDrop(
            controller: workspace.sendFiles,
            platform: workspace.context.device?.platform,
            confirmCertificates: { certificates in
                if let device = workspace.context.simulatorDevice, let dialogs = simulatorDialogs {
                    let name = model.simulators.entry(udid: device.id)?.name ?? device.id
                    dialogs.requestTrust(certificates: certificates, udid: device.id, simulator: name)
                } else {
                    model.status.flash("Drop certificates on the main window's simulator")
                }
            },
            target: { workspace.stageSendFilesTarget(physical: model.physicalInventory) }
        )
    }

    /// Fit-to-stage by default; a set zoom scales the fitted layout inside
    /// a scroll view. `workspace.window.zoomPresentation` carries the animated visual
    /// scale for a zoom step (see `AppModel.applyZoom`).
    /// A remembered picture is drawn at Fit while the opening zoom is still
    /// pending; the zoom then settles (to Physical Size for a phone that fits)
    /// on the next pass. The stage stays invisible until it has, so the device
    /// appears at its final size instead of shrinking from Fit. (Without a
    /// remembered picture the stage shows the screen placeholder as before.)
    private var hidesUntilZoomSettles: Bool {
        workspace.window.pendingZoom != nil && workspace.mirror.seedPicture != nil
    }

    private func zoomableContent(visible: CGSize, stage: CGSize, topInset: CGFloat) -> some View {
        zoomableStage(visible: visible, stage: stage, topInset: topInset)
            // Not 0: a fully transparent view stops drawing, and the Metal layer
            // would then show its stale contents for a frame or two on reveal.
            .opacity(hidesUntilZoomSettles || isSettlingNewSession ? 0.001 : 1)
            .onChange(of: liveSessionID, initial: true) { _, _ in revealWhenSettled() }
            .onChange(of: stageSettled) { _, _ in revealWhenSettled() }
            .onChange(of: workspace.mirror.mirrorViewState.videoPointsPerPixel) { _, _ in revealWhenSettled() }
            .onChange(of: workspace.window.stageZoom) { _, _ in revealWhenSettled() }
    }

    /// The live mirror session on the stage, if any.
    private var liveSessionID: ObjectIdentifier? {
        workspace.mirror.session.map { ObjectIdentifier($0 as AnyObject) }
    }

    /// A new session lays the stage out in a few passes (measured live at one 60 Hz
    /// frame each on 2026-10-01: a small first pass, then Fit, then the opening zoom).
    private var isSettlingNewSession: Bool {
        liveSessionID != nil && liveSessionID != revealedSession
    }

    /// The new session has drawn and its opening zoom has resolved.
    private var stageSettled: Bool {
        workspace.mirror.mirrorViewState.videoPointsPerPixel != nil && workspace.window.pendingZoom == nil
    }

    /// Shows a new session once its layout has settled and held still for 60 ms
    /// (the opening zoom is corrected once more after it resolves, measured live),
    /// or after a second and a half whatever happens, so a stream that never draws
    /// still shows its placeholder. Every change restarts the wait.
    private func revealWhenSettled() {
        guard let id = liveSessionID, id != revealedSession else { return }
        revealGeneration += 1
        let generation = revealGeneration
        let delay: Duration = stageSettled ? .milliseconds(60) : .milliseconds(1500)
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard generation == revealGeneration, liveSessionID == id else { return }
            revealedSession = id
        }
    }

    @ViewBuilder
    private func zoomableStage(visible: CGSize, stage: CGSize, topInset: CGFloat) -> some View {
        if let zoom = workspace.window.stageZoom {
            ScrollView([.horizontal, .vertical]) {
                content(available: CGSize(
                    width: visible.width * zoom,
                    height: visible.height * zoom
                ))
                .frame(
                    width: max(visible.width * zoom, visible.width),
                    height: max(visible.height * zoom, visible.height)
                )
                .scaleEffect(workspace.window.zoomPresentation)
                // Overlay scrollers and ⌥⌘-drag panning, like Device Hub's.
                .background(StageScrollSupport())
            }
            // A zoomed stage opens on the device's middle, as Device Hub's
            // does, not on the content's top-left corner.
            // (Smaller than the stage it stays at the top of the fit area, above
            // the pill's band.)
            .defaultScrollAnchor(zoom > 1 ? .center : .top)
            // A zoomed device runs to the stage's edges, behind the toolbar
            // band above and the pill below (DH's stage is one layer under
            // both, no hard clip): the scroll view takes the stage's 10 pt
            // padding and the toolbar's band back, and the content keeps
            // them as margins, so it starts where the fitted one does.
            .contentMargins([.horizontal, .bottom], Self.stagePadding, for: .scrollContent)
            .contentMargins(.top, Self.stagePadding + topInset, for: .scrollContent)
            .padding(EdgeInsets(
                top: -(Self.stagePadding + topInset),
                leading: -Self.stagePadding,
                bottom: -Self.stagePadding,
                trailing: -Self.stagePadding
            ))
        } else {
            content(available: visible)
                .scaleEffect(workspace.window.zoomPresentation)
        }
    }

    @ViewBuilder
    private func content(available: CGSize) -> some View {
        MirrorStageContent(
            session: session,
            chrome: chrome,
            available: available,
            showsFoldControls: workspace.hardware.showsFoldControls,
            showsNavigationBar: NavigationBarSpec.isShown(
                preference: model.preferences.showNavigationButtons,
                device: workspace.context.device,
                formFactor: workspace.context.serial.flatMap { model.inventory.deviceInfos[$0] }?.formFactor
            ),
            foldStripHeight: $foldStripHeight
        )
    }

}

/// The mirror surface in the chrome `DeviceChromeResolver` picked: the skin
/// artwork, the vector body, or an Apple device's thin bezel, while Show
/// Device Frame is on; flat when it is off, and for a body that needs the
/// stream's size before the first frame settles. Shared verbatim by the main
/// stage and the compact mirror window so both render the same session the
/// same way; the size comes from the parent.
struct MirrorStageContent: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let session: any MirrorSessionProtocol
    let chrome: DeviceChrome
    let available: CGSize
    /// Main stage only: `CompactMirrorView` keeps the default `false` and
    /// stays flat (spec §13).
    var showsFoldControls = false
    /// Main stage only: the Back / Home / Recents bar under an Android
    /// handheld (`NavigationBarSpec.isShown`).
    var showsNavigationBar = false
    /// The fold strip's laid-out height, owned by the main stage's
    /// container so it outlives this view (see `FoldStripStage`).
    var foldStripHeight: Binding<CGFloat> = .constant(FoldControlStrip.estimatedHeight)

    /// The fold strip, the navigation bar, or both sit under the device.
    private var showsAccessoryStrip: Bool { showsFoldControls || showsNavigationBar }

    var body: some View {
        ZStack {
            if workspace.window.showDeviceFrame {
                switch chrome {
                case .skin(let skin):
                    framedContent(skin: skin)
                case .appleChrome(let frame):
                    AppleChromeDeviceView(session: session, frame: frame, available: available)
                case .vector:
                    if let pixels = Self.vectorPixels(
                        settled: workspace.mirror.mirrorViewState.devicePixelSize,
                        device: workspace.context.device,
                        displays: workspace.mirror.liveDisplayShapes
                    ) {
                        vectorContent(pixels: pixels)
                    } else {
                        flatMirror(margin: 1.0, clearUntilFrame: true)
                    }
                case .thinBezel:
                    if let pixels = workspace.mirror.mirrorViewState.devicePixelSize {
                        screenContent(pixels: pixels, available: available)
                    } else {
                        flatMirror(margin: 1.0, clearUntilFrame: true)
                    }
                }
            } else if showsNavigationBar || showsFoldControls {
                FoldStripStage(available: available, stripHeight: foldStripHeight) { fitted in
                    flatMirror(margin: 1.0).frame(width: fitted.width, height: fitted.height)
                } strip: {
                    StageAccessoryStrip(showsNavigation: showsNavigationBar, showsFold: showsFoldControls)
                }
            } else {
                flatMirror(margin: 1.0)
            }
        }
        .frame(width: available.width, height: available.height)
        .background(Color(nsColor: .textBackgroundColor))
        .clipped()
        // Input is disabled while the rotation wrapper animates: a tap would
        // be mapped against a pose the view is no longer in. A simulator in
        // its Apple chrome turns with its own pose.
        .allowsHitTesting(!workspace.mirror.stagePose.isAnimating && !workspace.simulatorCanvas.devicePose.isAnimating)
        // A simulator's view-only canvas captures only while it is shown
        // (here, in the main stage or the compact window).
        .modifier(ViewOnlyCanvasVisibility(session: session))
    }

    /// The framed branch (spec §9): the flat framed mirror, with the fold
    /// control strip anchored at the bottom while the stage shows a foldable
    /// emulator (spec acceptance #3), and the device fitted above it.
    private func framedContent(skin: ResolvedSkin) -> some View {
        FoldStripStage(
            available: available,
            stripHeight: showsAccessoryStrip ? foldStripHeight : nil
        ) { fitted in
            FramedMirrorView(session: session, skin: skin, available: fitted)
        } strip: {
            StageAccessoryStrip(showsNavigation: showsNavigationBar, showsFold: showsFoldControls)
        }
    }

    /// The stream size the vector body is planned from: the settled stream
    /// once its first frame is in; before it, for an Apple device, the
    /// display its device type declares, upright (the view-only canvas's
    /// first `simctl io screenshot` takes most of a second, and the stage
    /// drew a black box meanwhile). Nil (the flat mirror) for an Android
    /// device before its first frame, whose body needs the stream's size.
    static func vectorPixels(settled: CGSize?, device: DeviceRef?, displays: [DisplayShape]) -> CGSize? {
        if let settled { return settled }
        guard device?.platform == .apple else { return nil }
        return displays.first?.naturalSize
    }

    /// The vector body (`VectorDeviceView`), above the fold control strip
    /// while the main stage shows a foldable emulator, as the framed branch
    /// is: a skinless foldable AVD gets the strip too.
    private func vectorContent(pixels: CGSize) -> some View {
        FoldStripStage(
            available: available,
            stripHeight: showsAccessoryStrip ? foldStripHeight : nil
        ) { fitted in
            VectorDeviceView(session: session, pixels: pixels, available: fitted)
        } strip: {
            StageAccessoryStrip(showsNavigation: showsNavigationBar, showsFold: showsFoldControls)
        }
    }

    /// An Apple device's chrome, unchanged from before the vector body:
    /// Device Manager style, the live screen at its own aspect ratio inside a
    /// thin bezel. The frame's only job is to show the screen, so there is no
    /// artwork, no fold projection and no cutout to align.
    ///
    /// The screen is clipped to the device's own corner radius (the display
    /// it reports for the streamed frame, `MirrorController.liveDisplayShapes`;
    /// none is read for an Apple device) and the bezel is concentric with
    /// it: its outer corner is the screen's plus the bezel width, both
    /// circular. Without device data the outer corner stays 16 pt and the
    /// screen's is 16 pt less the bezel.
    ///
    /// The composition is native (upright): the renderer samples the posed
    /// stream buffer upright and `PosePresentation` turns the whole bezel
    /// with the stage's pose angle, so rotation animates as one piece. It is
    /// laid out at the fit of the pose it rests in, so at rest the video is
    /// not scaled by the wrapper in any pose.
    ///
    /// No drop shadow, as on the skinned stage (P2-FRAME) and in Device Hub's
    /// live stage: inside the pose wrapper a shadow turns with the device
    /// and falls sideways in landscape, and the stage's `.clipped()` cuts it
    /// off in the 8 pt margin.
    @ViewBuilder
    private func screenContent(pixels: CGSize, available: CGSize) -> some View {
        let bezel: CGFloat = workspace.window.showDeviceFrame ? 8 : 0
        // The upright (natural) size comes from the frame being streamed, so a
        // rotation transition can never transpose the bezel for a frame; the
        // settled state is only a fallback.
        let current = session.frames.current
        let posed = current.map { CGSize(width: $0.width, height: $0.height) } ?? pixels
        let rotation = current?.rotation ?? workspace.mirror.mirrorViewState.deviceRotation
        let upright = TextureRotation.uprightSize(
            posedWidth: Int(posed.width.rounded()),
            posedHeight: Int(posed.height.rounded()),
            rotation: rotation
        )
        let uprightSize = CGSize(width: upright.width, height: upright.height)
        let box = CGSize(
            width: max(available.width - bezel * 2 - 16, 1),
            height: max(available.height - bezel * 2 - 16, 1)
        )
        // The natural pose's fit defines the composition: the screen fitted
        // inside the bezel, with the bezel expressed in that fit's space, so
        // the wrapper sees the composition's true bounding box.
        let naturalScale = min(
            max(box.width / max(uprightSize.width, 1), 0.05),
            max(box.height / max(uprightSize.height, 1), 0.05),
            1.0
        )
        let bezelInLayout = bezel * 2 / max(naturalScale, 0.001)
        let pose = PosePresentation(
            angle: workspace.mirror.stagePose.presentedAngle,
            restAngle: workspace.mirror.stagePose.restAngle,
            nativeSize: CGSize(
                width: uprightSize.width + bezelInLayout,
                height: uprightSize.height + bezelInLayout
            ),
            box: CGSize(
                width: max(available.width - 16, 1),
                height: max(available.height - 16, 1)
            ),
            stage: available
        )
        // Laid out at the rest pose's fit. The bezel and its corner grow
        // with the screen (not at all in the natural pose) as much as the
        // wrapper's enlargement of the natural layout used to grow them, so
        // every pose looks as before, only sharper.
        let scale = pose.layoutScale
        let growth = scale / max(naturalScale, 0.001)
        let mirrorSize = CGSize(
            width: uprightSize.width * scale,
            height: uprightSize.height * scale
        )
        let bezelWidth = bezel * growth
        let outerSize = CGSize(
            width: mirrorSize.width + bezelWidth * 2,
            height: mirrorSize.height + bezelWidth * 2
        )
        let corners = ThinBezelCorners(
            device: DisplayShape.matching(frame: uprightSize, in: workspace.mirror.liveDisplayShapes),
            screen: mirrorSize,
            bezel: bezelWidth,
            growth: growth
        )
        let signature = "\(Int(uprightSize.width))x\(Int(uprightSize.height))"

        MirrorView(
            session: session,
            state: workspace.mirror.mirrorViewState,
            margin: 1.0,
            allowsUpscaling: true,
            forwardsKeyboard: model.preferences.keyboardForwardingEnabled,
            cornerRadius: corners.screen,
            uprightsTexture: true
        )
            .frame(width: mirrorSize.width, height: mirrorSize.height)
            .padding(bezelWidth)
            .background(
                RoundedRectangle(cornerRadius: corners.outer, style: .circular)
                    .fill(Color.black)
            )
            .clipShape(RoundedRectangle(cornerRadius: corners.outer, style: .circular))
            .frame(width: outerSize.width, height: outerSize.height)
            .animation(reduceMotion ? nil : MotionMetrics.standard, value: signature)
            .modifier(pose)
    }

    @ViewBuilder
    private func flatMirror(margin: CGFloat, clearUntilFrame: Bool = false) -> some View {
        MirrorView(
            session: session,
            state: workspace.mirror.mirrorViewState,
            margin: margin,
            forwardsKeyboard: model.preferences.keyboardForwardingEnabled,
            // A physical iPhone's chrome that is not read yet, with no
            // picture remembered: the stage's own background shows until
            // the first frame sizes the device, not a stage-sized gray box
            // that is neither the old device nor the new one.
            backgroundIsTransparent: clearUntilFrame && workspace.context.isPhysicalView
        )
    }
}

/// The thin bezel's two corners (an Apple device's chrome, see
/// `MirrorStageContent.screenContent`), concentric: the screen's is the
/// device's reported radius at the screen's size, the outer one that plus
/// the bezel, so the band keeps its width round the corner. Without device
/// data the outer corner is the old 16 pt (grown with the layout like the
/// bezel) and the screen's is 16 pt less the bezel.
struct ThinBezelCorners: Equatable {
    /// The video's clip radius, points.
    let screen: CGFloat
    /// The bezel's outer radius, points.
    let outer: CGFloat

    /// The outer corner without device data, before growth.
    static let fallbackOuter: CGFloat = 16

    /// - Parameters:
    ///   - device: the display the device reports for the streamed frame.
    ///   - screen: the video's laid-out size, points.
    ///   - bezel: the bezel's laid-out width, points (0 draws none).
    ///   - growth: how much the layout grew the 8 pt bezel in this pose.
    init(device: DisplayShape?, screen: CGSize, bezel: CGFloat, growth: CGFloat) {
        let halfShort = max(min(screen.width, screen.height), 0) / 2
        if let device, device.maxCornerRadius > 0 {
            self.screen = min(device.clipCornerRadius(scaledTo: screen), halfShort)
        } else {
            self.screen = bezel > 0 ? max(Self.fallbackOuter * growth - bezel, 0) : 0
        }
        outer = bezel > 0 ? self.screen + bezel : self.screen
    }
}

/// The framed stage around the fold control strip: the strip sits
/// `FoldControlStrip.stageBottomPadding` above the stage's bottom edge, and
/// the device is fitted into the space above it and placed at the top. Laid
/// over the full stage, the strip covered the fold's bottom bezel (~23 pt)
/// and ~11 pt of the screen (`fold-3d-before-after.png`).
///
/// The strip's height is read from its own layout, so a control-size or OS
/// metric change cannot bring the overlap back. It is kept by the caller
/// (`MirrorContainer`), which outlives this view and starts it at
/// `FoldControlStrip.estimatedHeight`, so the device is fitted above the
/// strip from the first layout on: fitted over the whole stage first and
/// re-fitted once the strip reported its height, the device (and the Metal
/// drawable in it) would resize in the middle of a fit↔zoom animation.
struct FoldStripStage<Device: View, Strip: View>: View {
    let available: CGSize
    /// The strip's laid-out height; nil hides the strip and gives the device
    /// the whole stage.
    let stripHeight: Binding<CGFloat>?
    /// The device, fitted into the size it is given.
    @ViewBuilder let device: (CGSize) -> Device
    @ViewBuilder let strip: () -> Strip

    var body: some View {
        ZStack(alignment: .bottom) {
            device(deviceSize)
                .frame(width: available.width, height: available.height, alignment: .top)
            if let stripHeight {
                strip()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        stripHeight.wrappedValue = height
                    }
                    .padding(.bottom, FoldControlStrip.stageBottomPadding)
            }
        }
    }

    /// The whole stage, less the strip and its bottom padding while the
    /// strip shows.
    private var deviceSize: CGSize {
        guard let stripHeight else { return available }
        return CGSize(
            width: available.width,
            height: max(
                available.height - stripHeight.wrappedValue - FoldControlStrip.stageBottomPadding,
                1
            )
        )
    }
}
