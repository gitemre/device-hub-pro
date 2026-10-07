import AppKit
import SwiftUI
import DeviceHubProKit

/// Identity of the compact mirror `Window` scene and its frame autosave.
enum CompactMirrorWindow {
    static let id = "compact"
    static let frameAutosaveName = NSWindow.FrameAutosaveName("CompactMirror")
    /// Device Hub's compact window (measured on DH 27.0): 258 × 587 pt with
    /// its 52 pt toolbar.
    static let frameSize = CGSize(width: 258, height: 587)
    static let toolbarHeight: CGFloat = 52
    /// The title block's widest: what is left of 258 pt beside the traffic
    /// lights and the pill.
    static let titleMaxWidth: CGFloat = 62
    static let defaultSize = CGSize(width: frameSize.width, height: frameSize.height - toolbarHeight)
    static let minimumSize = CGSize(width: 180, height: 320)
}

/// What the toolbar's compact button offers right now.
enum CompactMirrorMenuState: Equatable {
    /// No mirror is live: the button does nothing.
    case unavailable
    /// A mirror is live and the window is closed.
    case open
    /// A mirror is live and the window is on screen.
    case close

    var title: String {
        switch self {
        case .unavailable, .open: "Switch to compact window"
        case .close: "Show in Main Window"
        }
    }

    var isEnabled: Bool { self != .unavailable }
}

/// The menu decision, kept pure for tests: enabled while a mirror is live,
/// flipping to Close exactly while the compact window is on screen.
func compactMirrorMenuState(isLive: Bool, isCompactOpen: Bool) -> CompactMirrorMenuState {
    guard isLive else { return .unavailable }
    return isCompactOpen ? .close : .open
}

/// Whether a mirror is live for the compact window, kept pure for tests: an
/// adb device's (its serial), or a simulator's session, which the compact
/// window draws in its Apple chrome as the main stage does.
func compactMirrorIsLive(activeSerial: String?, device: DeviceRef?, hasSession: Bool) -> Bool {
    activeSerial != nil || (device?.platform == .apple && hasSession)
}

/// The lifecycle decision, kept pure for tests: the compact window closes
/// when the mirrored device goes away, which `stopMirror()` clears — for
/// the user-initiated stop and, via `shouldStopMirror(after:isRunning:)`, a
/// fatal physical-transport error.
func compactMirrorShouldClose(activeDevice: DeviceRef?) -> Bool {
    activeDevice == nil
}

/// The fatal-error decision, kept pure for tests: a session that reports an
/// error *and* is no longer running stopped itself on a fatal video or
/// transport failure, so polling must tear the mirror down. Input errors
/// land in `lastError` while the session keeps running and never stop it.
func shouldStopMirror(after error: String?, isRunning: Bool) -> Bool {
    error != nil && !isRunning
}

/// The stats-poll resume decision, kept pure for tests: a `stats()` result
/// whose task was cancelled or whose session was replaced while the await
/// was in flight must be discarded — a stale physical session's leftover
/// error (and its stale stats/alert) must never touch the new mirror.
func shouldApplyStatsResult(isCancelled: Bool, isCurrentSession: Bool) -> Bool {
    !isCancelled && isCurrentSession
}

/// Device Hub's compact window: the live session's mirror and the control pill
/// under a toolbar with the device's name and OS and a glass pill holding the
/// expand button and the "..." menu. It replaces the main window while it
/// shows (the toolbar's compress button hides the main window; expand, or
/// closing this window, brings it back) and renders the same
/// `AppModel`/`FrameStore` the main stage uses; it never attaches or stops a
/// session itself.
struct CompactMirrorView: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace
    @Environment(SimulatorActionDialogs.self) private var simulatorDialogs
    @Environment(AvdActionDialogs.self) private var avdDialogs
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let stage = StageTitle(model: model, workspace: workspace)
        VStack(spacing: 0) {
            if let session = workspace.mirror.session, let device = workspace.context.device {
                GeometryReader { proxy in
                    Self.stageContent(
                        session: session,
                        chrome: DeviceChromeResolver.chrome(
                            device: device,
                            avdCards: model.catalog.avdCards,
                            forceVector: model.launchOptions.forceVectorChrome,
                            appleDisplayShapes: device.platform == .apple ? workspace.mirror.liveDisplayShapes : [],
                            appleChrome: DeviceChromeResolver.appleChrome(
                                for: device,
                                simulators: model.simulators,
                                physical: model.physicalInventory
                            )
                        ),
                        available: proxy.size
                    )
                }
                // DH's phone fills the compact width and starts at the
                // toolbar's edge: the stage has no padding of its own (the
                // device's 8 pt margin is the only air) and reaches up under
                // the toolbar band by `compactStageTopOverlap` (measured
                // 2026-09-29: DH 480 pt tall in the 258 x 587 window, ours
                // was 436, then 474).
                .padding(.top, -ParityMetrics.compactStageTopOverlap)
            } else {
                ContentUnavailableView {
                    Label("Mirror stopped", systemImage: "iphone.slash")
                } actions: {
                    // The device is still selected: the same way back the
                    // main stage offers.
                    if let device = workspace.context.device {
                        reattachButton(for: device)
                    }
                }
            }

            pillZone
        }
        .frame(
            minWidth: CompactMirrorWindow.minimumSize.width,
            minHeight: CompactMirrorWindow.minimumSize.height
        )
        .background(Color(nsColor: .textBackgroundColor), ignoresSafeAreaEdges: .top)
        .background(CompactWindowConfigurator(workspace: workspace))
        .navigationTitle(stage.title)
        .navigationSubtitle(stage.subtitle ?? "")
        // The title is drawn by hand: the system's would not shrink for the
        // pill, which then folded into the » overflow. Device Hub's is cut to
        // "AQA pr…" beside it.
        .toolbar(removing: .title)
        .toolbar {
            #if swift(>=6.2)
            ToolbarItem(placement: .navigation) {
                titleBlock(stage)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .primaryAction) {
                capsule
            }
            .sharedBackgroundVisibility(.hidden)
            #else
            ToolbarItem(placement: .navigation) {
                titleBlock(stage)
            }
            ToolbarItem(placement: .primaryAction) {
                capsule
            }
            #endif
        }
        .modifier(SimulatorActionDialogsHost(dialogs: simulatorDialogs))
        .modifier(AvdActionDialogsHost(dialogs: avdDialogs))
        // The Device menu still works from this window: its sheets show here.
        .deviceExtrasSheets()
        .sheet(isPresented: Binding(
            get: { workspace.window.isLogsSheetPresented },
            set: { workspace.window.isLogsSheetPresented = $0 }
        )) {
            LogsSheet()
                .environment(model)
                .environment(workspace)
        }
        .focusedSceneValue(\.appModel, model)
        .focusedSceneValue(\.deviceWorkspace, workspace)
        .onAppear {
            workspace.window.isCompactMirrorPresented = true
            if compactMirrorShouldClose(activeDevice: workspace.context.device) {
                dismiss()
            }
        }
        .onDisappear {
            workspace.window.isCompactMirrorPresented = false
            workspace.window.restoreMainWindowAfterCompact()
        }
        .onChange(of: workspace.window.compactStaysOnTop) { _, onTop in
            WindowLevel.apply(onTop: onTop, to: workspace.window.compactNSWindow)
        }
        .onChange(of: workspace.context.device) { _, device in
            if compactMirrorShouldClose(activeDevice: device) {
                dismiss()
            }
        }
    }

    @ViewBuilder
    private func reattachButton(for device: DeviceRef) -> some View {
        if let serial = device.adbSerial,
           let row = model.inventory.devices.first(where: { $0.serial == serial }) {
            Button("Retry") {
                Task { await workspace.mirror(device: row) }
            }
            .glassProminentButton()
            .disabled(!row.isOnline || model.isBusy)
        } else if ConnectingView.offersShowLiveView(for: device, isAttaching: false) {
            Button("Show Live View") {
                ConnectingView.showLiveView(device, workspace: workspace)
            }
            .glassProminentButton()
        }
    }

    /// Device Hub's two-line title: the name (13 pt bold) over the OS (11 pt).
    private func titleBlock(_ stage: StageTitle) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(stage.title)
                .font(.system(size: 13, weight: .bold))
                .lineLimit(1)
                // A phone's window is narrow: "iPhone 17 Pro" read "iPhone…".
                // Shrink a little before truncating, and keep the whole name
                // in the tooltip.
                .minimumScaleFactor(0.8)
                .truncationMode(.tail)
                .help(stage.title)
            if let subtitle = stage.subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: CompactMirrorWindow.titleMaxWidth, alignment: .leading)
        // Device Hub's title starts 108 pt from the window's edge.
        .padding(.leading, 12)
    }

    /// Device Hub's pill: Expand ("Show in Main Window" to assistive tech,
    /// "Expand to view all controls" as its tooltip) and the "..." menu.
    private var capsule: some View {
        // The pill ends 4 pt from the window's edge in Device Hub.
        capsuleContent.padding(.trailing, -11)
    }

    private var capsuleContent: some View {
        ToolbarMoreCapsule(
            leadingSymbol: "arrow.up.left.and.arrow.down.right",
            leadingHelp: "Expand to view all controls",
            leadingAccessibilityLabel: "Show in Main Window",
            leadingAction: {
                workspace.window.restoreMainWindowAfterCompact()
                dismiss()
            },
            beforeRename: { workspace.window.restoreMainWindowAfterCompact() }
        )
    }

    /// DH's pill band, same metrics as the main stage (PL-02).
    private var pillZone: some View {
        DeviceControlPill()
            // Under "Mirror stopped" the buttons have no session to act on.
            .disabled(workspace.mirror.session == nil || workspace.context.device == nil)
            .frame(height: ParityMetrics.pillHeight)
            .padding(
                .top,
                ParityMetrics.compactStagePillBand
                    - ParityMetrics.pillBottomInset
                    - ParityMetrics.pillHeight
            )
            .padding(.bottom, ParityMetrics.pillBottomInset)
    }

    /// The compact window's stage: the main stage's content in the same
    /// chrome (`DeviceChromeResolver`), without the fold control strip — the
    /// compact window stays flat (spec §13), a foldable included.
    static func stageContent(
        session: any MirrorSessionProtocol,
        chrome: DeviceChrome,
        available: CGSize
    ) -> MirrorStageContent {
        MirrorStageContent(session: session, chrome: chrome, available: available)
    }
}

/// The main windows the compact windows replaced, so quitting from a compact
/// window leaves the main one to be saved (and shown at the next launch).
@MainActor
enum CompactSwitch {
    static var hiddenMainWindows: [WeakWindow] = []

    static func restoreAll() {
        for weak in hiddenMainWindows { weak.window?.orderFront(nil) }
        hiddenMainWindows.removeAll()
    }

    final class WeakWindow {
        weak var window: NSWindow?
        init(_ window: NSWindow) { self.window = window }
    }
}

typealias WeakWindow = CompactSwitch.WeakWindow

extension WindowState {
    /// Brings back the main window the compact window replaced, once.
    func restoreMainWindowAfterCompact() {
        guard let window = mainWindowHiddenForCompact else { return }
        mainWindowHiddenForCompact = nil
        window.makeKeyAndOrderFront(nil)
    }

    /// Replaces the main window with the compact one: remembers `window`
    /// (the compact window centres on it and hides it once it exists).
    func beginCompactSwitch(from window: NSWindow?) {
        mainWindowHiddenForCompact = window
        if let window { CompactSwitch.hiddenMainWindows.append(WeakWindow(window)) }
    }
}

/// Applies the compact window's AppKit behavior once its view is in a window:
/// Device Hub's 258 × 587 frame centred on the main window it replaces, which
/// it then hides.
struct CompactWindowConfigurator: NSViewRepresentable {
    let workspace: DeviceWorkspace

    func makeNSView(context: Context) -> NSView {
        let view = ConfiguringView()
        view.workspace = workspace
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ConfiguringView: NSView {
        var workspace: DeviceWorkspace?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            let workspace = workspace
            MainActor.assumeIsolated {
                // A compact window is never restored at launch: the main
                // window it replaced is what comes back.
                window.isRestorable = false
                // Stay on Top: the compact mirror floats above other
                // windows when the user chose so.
                if let workspace {
                    workspace.window.compactNSWindow = window
                    WindowLevel.apply(onTop: workspace.window.compactStaysOnTop, to: window)
                }
                window.minSize = NSSize(
                    width: CompactMirrorWindow.minimumSize.width,
                    height: CompactMirrorWindow.minimumSize.height
                )
                let size = CompactMirrorWindow.frameSize
                if let main = workspace?.window.mainWindowHiddenForCompact {
                    let center = NSPoint(x: main.frame.midX, y: main.frame.midY)
                    window.setFrame(
                        NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height),
                        display: true
                    )
                    // The compact window replaces the main window: it goes
                    // out of sight (not closed: its workspace lives on).
                    main.orderOut(nil)
                } else {
                    // A compact window nobody switched to (macOS restoring
                    // one from the last run): the main window is already
                    // showing, so this one goes.
                    DispatchQueue.main.async { window.close() }
                }
            }
        }
    }
}
