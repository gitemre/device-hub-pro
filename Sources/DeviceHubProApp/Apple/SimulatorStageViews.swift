import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DeviceHubProKit

/// What the stage shows for a selected simulator.
enum SimulatorStagePhase: Equatable {
    /// Shut down: the hero and Start. `activity` is an operation running on
    /// the stopped simulator ("Erasing", "Removing"), shown with a spinner.
    case stopped(activity: String?)
    /// On its way to ready: the hero, a spinner and the boot phase.
    case booting(String)
    /// Shutting down: the stopped page without its Start button.
    case stopping
    /// Ready: the live stage (the canvas).
    case live
    /// Booted, but the boot status, SpringBoard or the home screen never
    /// came: Restart and Shut Down.
    case unresponsive
    /// Its runtime is missing: nothing to start.
    case unavailable(String)

    /// The phase for a simulator of `platform` in `runState` with
    /// `operation` in flight. Ready means the three conditions of
    /// `SimulatorReadiness`, never just "Booted" in the listing.
    static func resolve(
        isAvailable: Bool,
        availabilityError: String?,
        runState: DeviceRunState,
        operation: SimulatorLifecycleController.Operation?,
        platform: String?
    ) -> SimulatorStagePhase {
        guard isAvailable else {
            return .unavailable(availabilityError ?? "The simulator's runtime is not installed.")
        }
        switch runState {
        case .ready:
            // A stop or restart the app started is already under way while
            // the listing still says Booted: the stage leaves the live view
            // at once, as Device Hub's does, instead of showing a live view
            // that has lost its session for the moment it takes to shut down.
            switch operation {
            case .stopping?: return .stopping
            case .restarting?: return .booting(label(for: .launching, platform: platform))
            default: return .live
            }
        case .booting(let phase):
            return .booting(label(for: phase, platform: platform))
        case .shuttingDown:
            return .stopping
        case .unreachable, .reconnecting, .unauthorized:
            return .unresponsive
        case .stopped:
            switch operation {
            case .erasing?, .deleting?, .renaming?, .cloning?:
                return .stopped(activity: operation?.label)
            case .starting?, .restarting?:
                return .booting(label(for: .launching, platform: platform))
            case .stopping?, nil:
                return .stopped(activity: nil)
            }
        }
    }

    /// The boot phase `simctl bootstatus` reported, in the stage's words:
    /// the system app it waits for is the platform's home screen process
    /// (SpringBoard on iOS, PineBoard on tvOS, unnamed elsewhere).
    static func label(for phase: DeviceBootPhase, platform: String?) -> String {
        switch phase {
        case .launching: "Starting…"
        case .waitingOnBackBoard: "Starting system services…"
        case .migratingData: "Migrating data…"
        case .waitingOnSystemApp:
            SimulatorReadiness.homeScreenProcessName(platform: platform)
                .map { "Waiting for \($0)…" } ?? "Waiting for the system app…"
        case .waitingOnHomeScreen: connectingDisplayLabel
        case .other(let text): text
        }
    }

    /// Device Hub's caption once the boot has finished and the display is
    /// being connected (measured on DH 27.0: about eight seconds of a bare
    /// spinner while the system boots, then this caption under it).
    static let connectingDisplayLabel = "Connecting display…"

    /// The caption the booting stage shows under its spinner: only
    /// `connectingDisplayLabel`; the boot phases before it are not shown
    /// (Device Hub shows a spinner alone for them).
    var bootCaption: String? {
        if case .booting(let label) = self, label == Self.connectingDisplayLabel { return label }
        return nil
    }
}

/// The center stage for a simulator (§3.4): the stopped page
/// with its hero and Start, the boot progress with the phase `bootstatus`
/// reports, and once the simulator is ready the live stage, whose canvas
/// the simulator canvas picks (`SimulatorCanvasController`).
struct SimulatorStageView: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace
    let entry: SimulatorEntry

    var body: some View {
        let runState = model.simulatorLifecycle.runState(for: entry)
        let phase = SimulatorStagePhase.resolve(
            isAvailable: entry.isAvailable,
            availabilityError: entry.availabilityError,
            runState: runState,
            operation: model.simulatorLifecycle.operations[entry.udid],
            platform: entry.platform
        )
        Group {
            if phase == .live {
                LiveDetailView(device: .apple(entry.udid))
                    // The live stage draws the device type's chrome or body: read
                    // here too, for a simulator whose stopped page never showed.
                    .task(id: entry.deviceTypeIdentifier) {
                        await model.simulators.loadDisplayShape(for: entry)
                    }
            } else if Self.showsBootingDevice(
                phase: phase, hasFirstFrame: workspace.simulatorCanvas.bootFrameReady.contains(entry.udid)
            ) {
                // Device Hub's warm boot: the device's black screen with a
                // small spinner on it as soon as the display has a frame,
                // and the live picture under it from then on.
                LiveDetailView(device: .apple(entry.udid), isBooting: true)
                    .task(id: entry.deviceTypeIdentifier) {
                        await model.simulators.loadDisplayShape(for: entry)
                    }
            } else {
                SimulatorDetailView(entry: entry, phase: phase)
            }
        }
        // While it boots, the live canvas starts under the booting page as
        // soon as the simulator is listed Booted (`followBootFrames`), so the
        // wait reads its frames instead of taking screenshots, and the stage
        // shows the device the moment its display has a frame.
        .task(id: Self.earlyCanvasKey(entry: entry, runState: runState)) {
            guard Self.earlyCanvasKey(entry: entry, runState: runState) != nil else { return }
            await workspace.simulatorCanvas.followBootFrames(
                entry.udid,
                isFirstBoot: model.simulatorLifecycle.firstBoots.contains(entry.udid),
                isBootFinished: { [model] in
                    if case .booting(.waitingOnHomeScreen) = model.simulatorLifecycle.runState(for: entry) { return true }
                    return false
                }
            )
        }
    }

    /// Whether a booting simulator shows its device (the live stage without
    /// its pill, a spinner on the screen) instead of the bare spinner: its
    /// live canvas has a frame and the boot is not finished.
    static func showsBootingDevice(phase: SimulatorStagePhase, hasFirstFrame: Bool) -> Bool {
        guard hasFirstFrame, case .booting = phase else { return false }
        return true
    }

    /// The simulator whose canvas may start before it is ready: one that is
    /// booting; nil otherwise. The key stays the same through the boot's
    /// phases, so the task that follows the boot's frames runs once.
    static func earlyCanvasKey(entry: SimulatorEntry, runState: DeviceRunState) -> String? {
        guard case .booting = runState else { return nil }
        return entry.udid
    }
}

/// A simulator that is not ready: its body (the device-frame vector body
/// around its device type's display), its name, its state and the action it
/// allows. The layout is the stopped AVD page's (`AvdDetailView`).
struct SimulatorDetailView: View {
    @Environment(AppModel.self) private var model
    let entry: SimulatorEntry
    let phase: SimulatorStagePhase

    var body: some View {
        if case .booting(let label) = phase {
            // Device Hub hides the device and its name once the boot starts:
            // a small spinner in the middle of the stage, and once the
            // display is being connected a caption under it.
            BootSpinnerPanel(caption: phase.bootCaption, accessibilityLabel: label)
        } else {
            StoppedStagePanel {
                SimulatorHero(entry: entry)
                    .frame(height: SkinHero.height)

                VStack(spacing: 4) {
                    Text(entry.name)
                        .font(.system(size: ParityMetrics.stoppedNameFontSize, weight: ParityMetrics.stoppedNameFontWeight))
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, ParityMetrics.stoppedHeroToNameGap)

                status
                    .padding(.top, ParityMetrics.stoppedSubtitleToButtonGap)
            }
        }
    }

    /// "iOS 27.0 Simulator · Starting", like an AVD's "API 36 Emulator ·
    /// Starting" — except stopped, which DH shows with no state suffix at
    /// all ("iOS 26.5 Simulator").
    private var subtitle: String { Self.subtitle(osLabel: entry.osLabel, phase: phase) }

    static func subtitle(osLabel: String?, phase: SimulatorStagePhase) -> String {
        let kind = osLabel.map { "\($0) Simulator" } ?? "Simulator"
        let state: String? = switch phase {
        case .stopped: nil
        case .booting: "Starting"
        case .stopping: nil
        case .live: "Running"
        case .unresponsive: "Not Responding"
        case .unavailable: "Unavailable"
        }
        guard let state else { return kind }
        return "\(kind) · \(state)"
    }

    private var isBusy: Bool {
        model.simulatorLifecycle.operations[entry.udid] != nil
    }

    @ViewBuilder
    private var status: some View {
        switch phase {
        case .stopped(let activity?):
            progress("\(activity)…")
        case .stopped(nil):
            Button {
                Task { await model.simulatorLifecycle.boot(entry.udid) }
            } label: {
                StagePrimaryButtonLabel("Start")
            }
            .stagePrimaryButton()
            .disabled(isBusy)
        case .booting(let label):
            progress(label)
        case .stopping:
            // Device Hub goes straight to the stopped page and shows Start
            // about a second later: the button's place is kept, empty.
            Button {} label: {
                StagePrimaryButtonLabel("Start")
            }
            .stagePrimaryButton()
            .hidden()
            .accessibilityHidden(true)
        case .unresponsive:
            VStack(spacing: 10) {
                Text("\(entry.name) is running but not responding.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button {
                        Task { await model.simulatorLifecycle.restart(entry.udid) }
                    } label: {
                        StagePrimaryButtonLabel("Restart")
                    }
                    .stagePrimaryButton()
                    Button("Shut Down") {
                        Task { await model.simulatorLifecycle.shutDown(entry.udid) }
                    }
                    .glassButton()
                    .controlSize(.large)
                }
                .disabled(isBusy)
            }
        case .unavailable(let reason):
            Text(reason)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        case .live:
            EmptyView()
        }
    }

    private func progress(_ label: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The picture macOS itself keeps for a device model (`NSWorkspace.icon(for:)`
/// on the model's type: `iPhone18,3` is `com.apple.iphone-17-2`): an iPhone
/// or iPad with its silver rim, its Dynamic Island, a blue screen and its
/// own contact shadow, a set-top box for an Apple TV. It is what Device Hub
/// draws as a stopped device's picture (measured on DH 27.0, iPhone 17,
/// iPad (A16) and Apple TV: the same rim, island, shadow and box), so the
/// stopped page reads it from the same place instead of composing a body
/// from Xcode's chrome, whose thick black bezel is the running device's.
/// Read at runtime from the system; nothing of it is copied into the app.
@MainActor
enum SystemDeviceIcon {
    private static var cache: [String: NSImage?] = [:]

    /// The icon for `modelIdentifier`, cropped to what it draws (the system's
    /// icons are square with the device in the middle: an Apple TV is a
    /// quarter of it); nil for an unknown model, a model whose type macOS
    /// does not declare, and nil itself.
    static func image(forModelIdentifier modelIdentifier: String?) -> NSImage? {
        guard let modelIdentifier, !modelIdentifier.isEmpty else { return nil }
        if let cached = cache[modelIdentifier] { return cached }
        let icon = makeImage(forModelIdentifier: modelIdentifier)
        cache[modelIdentifier] = .some(icon)
        return icon
    }

    nonisolated static func makeImage(forModelIdentifier modelIdentifier: String) -> NSImage? {
        guard let type = UTType(
            tag: modelIdentifier,
            tagClass: UTTagClass(rawValue: "com.apple.device-model-code"),
            conformingTo: nil
        ), type.isDeclared else { return nil }
        let icon = NSWorkspace.shared.icon(for: type)
        var rect = NSRect(x: 0, y: 0, width: 1024, height: 1024)
        guard let full = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let box = contentBounds(of: full),
              let cropped = full.cropping(to: box)
        else { return icon }
        // Points at the icon's own 2x-of-512 scale: only the aspect and the
        // resolution matter, the hero fits it to its box.
        return NSImage(cgImage: cropped, size: NSSize(width: cropped.width / 2, height: cropped.height / 2))
    }

    /// The pixels that are not transparent at all, or nil for none: the
    /// icon's soft contact shadow fades to alpha 0 over hundreds of pixels, and
    /// a crop that stops earlier (it stopped at alpha 8) leaves a hard edge
    /// under the picture. Device Hub draws the whole icon: the iPhone's is
    /// 183.5 × 200 pt, this crop at the same height.
    nonisolated static func contentBounds(of image: CGImage) -> CGRect? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var data = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where data[(y * width + x) * 4 + 3] > 0 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        // A bitmap context's first row is the image's top, which is where
        // `cropping(to:)` counts from too.
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}

/// A simulator's picture at rest: the system's device icon
/// (`SystemDeviceIcon`) cropped to its drawing and fitted into 250 x 200 pt,
/// like Device Hub's (an iPhone 194 pt tall from the top of the box, its
/// shadow in the last few points; an Apple TV 250 pt wide, centred); when the
/// system has none for the model, its Apple chrome (`AppleChromeFrameProvider`,
/// read at runtime from the user's Xcode) with the buttons at rest, else the
/// device-frame vector body planned around its display
/// (`SimulatorDisplayProfile`). Nothing while the display is read; the
/// placeholder card when the device type declares none.
struct SimulatorHero: View {
    @Environment(AppModel.self) private var model
    let entry: SimulatorEntry

    var body: some View {
        Group {
            if let icon = SystemDeviceIcon.image(forModelIdentifier: entry.modelIdentifier) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: ParityMetrics.stoppedHeroIconWidth, height: SkinHero.height)
                    .accessibilityHidden(true)
            } else if model.simulators.hasReadDisplayShape(for: entry) {
                SkinHero(variant: nil, vector: Self.plan(
                    model.simulators.displayShape(for: entry),
                    chrome: model.simulators.chromeFrame(for: entry)
                ))
            } else {
                Color.clear
            }
        }
        .task(id: entry.deviceTypeIdentifier) {
            await model.simulators.loadDisplayShape(for: entry)
        }
    }

    /// The Apple chrome, upright, when the device type has one; else the
    /// vector body around `shape`; nil without a display.
    static func plan(_ shape: DisplayShape?, chrome: AppleChromeFrame? = nil) -> DeviceComposition? {
        if let chrome { return DeviceCompositionPlanner.appleChrome(chrome) }
        guard let shape else { return nil }
        return DeviceCompositionPlanner.vector(
            screen: shape.naturalSize,
            displays: [shape],
            fallbackDensityDpi: nil,
            quarterTurns: 0
        )
    }
}

/// Over the view-only canvas: why the picture is a once-a-second screenshot,
/// a retry when the live canvas failed, and the handoff to Apple's app,
/// where the simulator takes input.
struct SimulatorViewOnlyBanner: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace
    let udid: String

    var body: some View {
        let canvas = model.simulators.entry(udid: udid).map(workspace.simulatorCanvas.canvas(for:))
        let reason: String? = if case let .viewOnly(reason)? = canvas { reason } else { nil }
        HStack(spacing: 10) {
            Label("View only", systemImage: "eye")
                .font(.system(size: 11, weight: .medium))
                .help(reason ?? "")
            if workspace.simulatorCanvas.liveCanvasFailures[udid] != nil {
                Button("Try Live View") {
                    workspace.simulatorCanvas.retryLiveCanvas(udid)
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }
            Button(workspace.simulatorCanvas.handoffTitle) {
                workspace.simulatorCanvas.openInAppleApp(udid)
            }
            .buttonStyle(.link)
            .font(.system(size: 11))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .liquidGlass()
        .glassHairline(in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("View only")
        .accessibilityValue(reason ?? "")
    }
}

/// The live canvas's first-input tooltip (
/// `SimulatorCanvasController.inputNotice(for:)`): what the first click or
/// key does to other tools' input on the simulator, while nothing had
/// connected its input in this boot. Otherwise an empty tooltip (none
/// shown), so the canvas under it keeps its identity when the notice comes
/// or goes. An Android device's stage is left as it was.
struct SimulatorInputNotice: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace
    let device: DeviceRef

    func body(content: Content) -> some View {
        if device.platform == .apple {
            content.help(workspace.simulatorCanvas.inputNotice(for: device.id) ?? "")
        } else {
            content
        }
    }
}

/// Tells a view-only canvas (`SimulatorScreenshotSession`, or a physical
/// device's screenshot preview, `PhysicalScreenshotSession`) that it is shown
/// while the view is on screen in a window that is visible, so it captures
/// only then. Other sessions are left alone.
struct ViewOnlyCanvasVisibility: ViewModifier {
    let session: any MirrorSessionProtocol
    @State private var isWindowVisible = true

    private struct Key: Equatable {
        let session: ObjectIdentifier
        let isWindowVisible: Bool
    }

    func body(content: Content) -> some View {
        if let viewOnly = session as? any ShownTrackingSession {
            content
                .background(WindowVisibilityReader(isVisible: $isWindowVisible))
                .task(id: Key(session: ObjectIdentifier(viewOnly), isWindowVisible: isWindowVisible)) {
                    guard isWindowVisible else { return }
                    viewOnly.setShown(true)
                    defer { viewOnly.setShown(false) }
                    while !Task.isCancelled {
                        // Ends early, with the loop, when the task is cancelled.
                        try? await Task.sleep(for: .seconds(3600))
                    }
                }
        } else {
            content
        }
    }
}

/// Tracks the hosting window's visibility into `DeviceWorkspace.window.isWindowVisible`:
/// the Metal stage (`MirrorMetalView`, occlusion-gated via
/// `MirrorView`) and the Controls poll (`ControlsView`) read it to stop
/// per-frame and polling work while the window cannot be seen. Applied once,
/// high in each workspace's own view tree (`ContentView`), so every window —
/// single-window mode's one, or each of several — gets its own signal from
/// its own `NSWindow`.
struct WorkspaceWindowVisibilityTracking: ViewModifier {
    @Environment(DeviceWorkspace.self) private var workspace
    @State private var isVisible = true

    func body(content: Content) -> some View {
        content
            .background(WindowVisibilityReader(isVisible: $isVisible))
            .onChange(of: isVisible, initial: true) { _, newValue in
                workspace.window.isWindowVisible = newValue
            }
    }
}

extension View {
    /// See `WorkspaceWindowVisibilityTracking`.
    func trackingWorkspaceWindowVisibility() -> some View {
        modifier(WorkspaceWindowVisibilityTracking())
    }
}

/// Whether the hosting window is visible on screen (not minimised, hidden,
/// fully covered or on another Space): its occlusion state, followed.
struct WindowVisibilityReader: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.onChange = { visible in
            // Reported outside the view update that caused it.
            DispatchQueue.main.async {
                if isVisible != visible { isVisible = visible }
            }
        }
        return probe
    }

    func updateNSView(_ nsView: Probe, context: Context) {}

    final class Probe: NSView {
        var onChange: ((Bool) -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Leaving the window ends the observation.
            if let observer {
                NotificationCenter.default.removeObserver(observer)
                self.observer = nil
            }
            guard let window else { return }
            onChange?(window.occlusionState.contains(.visible))
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window else { return }
                    self.onChange?(window.occlusionState.contains(.visible))
                }
            }
        }
    }
}
