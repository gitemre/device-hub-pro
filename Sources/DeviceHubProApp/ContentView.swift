import AppKit
import SwiftUI
import DeviceHubProKit

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace
    @Environment(AvdActionDialogs.self) private var avdDialogs
    @Environment(AppActionDialogs.self) private var appDialogs
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var pixelCatalog = PixelCatalogModel()
    /// This view's window, for the compact switch (the app may be inactive,
    /// so `NSApp.keyWindow` cannot name it).
    @State private var windowBox = WindowCapture.Box()
    @Environment(SimulatorActionDialogs.self) private var simulatorDialogs

    var body: some View {
        @Bindable var capture = workspace.capture
        @Bindable var window = workspace.window

        NavigationSplitView(columnVisibility: $window.columnVisibility) {
            DeviceSidebarView()
                .environment(pixelCatalog)
                .environment(simulatorDialogs)
                // The leading cluster lives in a titlebar accessory; the
                // column contributes no toolbar items of its own.
                .toolbar(removing: .sidebarToggle)
                // Must stay outermost: applied under `.toolbar(removing:)`
                // the column width is lost and a first launch opens the
                // sidebar at 144 pt (below the 272 pt minimum), with the
                // leading cluster over the traffic lights (macOS 27, also
                // in a bare NavigationSplitView).
                .navigationSplitViewColumnWidth(min: 272, ideal: 300, max: 320)
        } detail: {
            LogFocusSplit(isFocus: window.isLogFocus) {
                DeviceStageView()
                    .environment(pixelCatalog)
                    .frame(minWidth: 1, maxWidth: .infinity, minHeight: 1, maxHeight: .infinity)
            } log: {
                LogFocusView()
            }
            .background(
                Button("") { workspace.window.exitLogFocus() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .disabled(!window.isLogFocus)
                    .opacity(0)
                    .accessibilityHidden(true)
            )
            .background(Color(nsColor: .textBackgroundColor), ignoresSafeAreaEdges: .top)
            .modifier(StageWindowTitle())
            .inspector(isPresented: $window.showInspector) {
                InspectorView()
                    .inspectorColumnWidth(min: 260, ideal: 280, max: 360)
            }
        }
        .toolbar {
            trailingToolbar
        }
        .toolbar(removing: .sidebarToggle)
        .trackingWorkspaceWindowVisibility()
        .background(MainWindowLevelApplier(workspace: workspace))
        .drivingPhysicalLiveView()
        .alert(
            "Several Devices Are Mirroring",
            isPresented: Binding(
                get: { window.sessionCapWarning != nil },
                set: { if !$0 { workspace.resolveSessionCapWarning(stop: false) } }
            ),
            presenting: window.sessionCapWarning
        ) { warning in
            Button("Stop \(warning.leastRecentlyFocusedName) & Continue") {
                workspace.resolveSessionCapWarning(stop: true)
            }
            Button("Continue Anyway", role: .cancel) {
                workspace.resolveSessionCapWarning(stop: false)
            }
        } message: { warning in
            Text("4 devices are already mirroring in other windows. \(warning.leastRecentlyFocusedName) was focused longest ago.")
        }
        .task {
            await model.refreshForNewWindow()
        }
        .background(WindowCapture(box: windowBox).frame(width: 0, height: 0))
        .background {
            LeadingToolbarAccessoryInstaller()
                .frame(width: 0, height: 0)
        }
        .overlay(alignment: .topLeading) {
            PixelCatalogRefreshHost()
                .environment(pixelCatalog)
        }
        .overlay(alignment: .top) {
            // Display only: it floats over the device's top edge, where it
            // swallowed clicks and notification-shade drags while it showed.
            StatusBannerHost()
                .allowsHitTesting(false)
        }
        .alert(
            "Device Hub Pro",
            isPresented: Binding(
                get: { activeErrorCenter.errorMessage != nil && activeErrorCenter.errorDetails == nil },
                set: { if !$0 { activeErrorCenter.errorMessage = nil } }
            )
        ) {
            if UserFacingText.offersAndroidSetup(activeErrorCenter.errorMessage) {
                Button("Set Up Android Tools\u{2026}") {
                    activeErrorCenter.errorMessage = nil
                    workspace.window.isAndroidSetupPresented = true
                }
            }
            Button("OK") { activeErrorCenter.errorMessage = nil }
        } message: {
            Text(UserFacingText.plain(activeErrorCenter.errorMessage ?? ""))
        }
        .modifier(ErrorDetailsAlertHost(center: activeErrorCenter))
        .modifier(AvdActionDialogsHost(dialogs: avdDialogs))
        .dhAlert(
            item: appDialogs.confirmation,
            spec: { confirmation in
                switch confirmation {
                case .clearData(let package, let name):
                    DHAlertSpec(
                        title: "Clear data for \(dhQuoted(name))?",
                        message: "All of \(dhQuoted(name))\u{2019}s on-device data (\(package)) is erased. You can\u{2019}t undo this action.",
                        confirmTitle: "Clear Data",
                        style: .destructive
                    )
                case .uninstall(let package, let name):
                    DHAlertSpec(
                        title: "Uninstall \(dhQuoted(name))?",
                        message: "\(dhQuoted(name)) (\(package)) and its data are removed from the device.",
                        confirmTitle: "Uninstall",
                        style: .destructive
                    )
                }
            },
            resolve: { confirmation, confirmed in
                appDialogs.confirmation = nil
                guard confirmed else { return }
                switch confirmation {
                case .clearData(let package, _):
                    Task { await workspace.apps.clearAppData(package: package) }
                case .uninstall(let package, _):
                    Task { await workspace.apps.uninstallApp(package: package) }
                }
            }
        )
        .modifier(SimulatorActionDialogsHost(dialogs: simulatorDialogs))
        .deviceExtrasSheets()
        .background {
            // ⌘R re-scans the devices (there is no View item for it, as in
            // Device Hub): a hidden shortcut.
            Button("") { Task { await model.refresh() } }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isBusy)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .modifier(PhysicalDeviceEnableDialogHost())
        .modifier(PhysicalDeviceActionsDialogHost())
        // On the window, not the inspector: Device ▸ Show Logs… opens it
        // with the inspector hidden too.
        .sheet(isPresented: $window.isLogsSheetPresented) {
            LogsSheet()
                .environment(model)
                .environment(workspace)
        }
        .sheet(isPresented: $window.isAndroidSetupPresented) {
            AndroidSetupSheet()
                .environment(model)
                .environment(workspace)
        }
        .sheet(item: Binding(
            get: { window.teamPickerRequest },
            set: { newValue in
                if newValue == nil { window.teamPickerRequest?.answer(nil) }
                window.teamPickerRequest = newValue
            }
        )) { request in
            TeamPickerSheet(request: request)
        }
        .sheet(isPresented: $window.isConnectPhonePresented) {
            ConnectAndroidPhoneSheet()
                .environment(model)
                .environment(workspace)
        }
        .sheet(isPresented: $window.isPairSheetPresented) {
            PairNearbySheet()
                .environment(model)
                .environment(workspace)
        }
        .sheet(item: $capture.annotationEditRequest) { request in
            AnnotationEditorView(basePNG: request.png)
                .environment(model)
                .environment(workspace)
        }
        // A background job's license question: the create sheet is gone by
        // then, so the window asks (the download sheet asks for its own).
        .sheet(item: Binding(
            get: { model.avdCreation.jobs.contains { $0.phase == .downloading } ? model.avdCreation.sdk.licensePrompt : nil },
            set: { _ in }
        )) { prompt in
            SDKLicenseSheet(
                prompt: prompt,
                onAccept: { model.avdCreation.sdk.acceptLicense() },
                onDecline: { model.avdCreation.sdk.declineLicense() }
            )
        }
        .sheet(item: $window.createFormFactor) { factor in
            AvdCreateSheet(formFactor: factor)
                .environment(model)
                .environment(workspace)
        }
        .sheet(isPresented: $window.isCatalogPresented) {
            CatalogView()
                .environment(model)
                .environment(workspace)
        }
        .focusedSceneValue(\.appModel, model)
        .focusedSceneValue(\.deviceWorkspace, workspace)
    }

    // MARK: - Status

    /// The error alert's center: whichever of the app-global center and this
    /// window's own workspace wrote `errorMessage` most recently
    /// (`StatusCenter.active(error:_:)`). With one workspace this always
    /// resolves to whichever one the failing flow actually wrote, so the
    /// alert reads exactly as it did with the one shared center.
    private var activeErrorCenter: StatusCenter {
        StatusCenter.active(error: model.status, workspace.status)
    }

    // MARK: - Toolbar

    /// The compact mirror window's state, shared by the Device menu and the
    /// toolbar overflow's item.
    private var compactMirrorState: CompactMirrorMenuState {
        compactMirrorMenuState(
            // Only the selected row's device: a stopped AVD selected after a
            // live one must not open the earlier device's compact window.
            isLive: workspace.contextIsSelection && compactMirrorIsLive(
                activeSerial: workspace.context.serial,
                device: workspace.context.device,
                hasSession: workspace.mirror.session != nil
            ),
            isCompactOpen: workspace.window.isCompactMirrorPresented
        )
    }

    /// The compress button: the compact window replaces this window (Device
    /// Hub's "Switch to compact window"). The compact window centres on it
    /// and hides it; expanding brings it back.
    private func toggleCompactMirror() {
        switch compactMirrorState {
        case .open:
            // The compact scene is `WindowGroup(id:for: WorkspaceID.self)`:
            // opening or dismissing it by id alone would
            // not name a window.
            workspace.window.beginCompactSwitch(from: windowBox.window)
            openWindow(id: CompactMirrorWindow.id, value: workspace.id)
        case .close:
            workspace.window.restoreMainWindowAfterCompact()
            dismissWindow(id: CompactMirrorWindow.id, value: workspace.id)
        case .unavailable:
            break
        }
    }

    /// Hides the system's shared toolbar-item background (the new design
    /// draws a glass rim around grouped controls; DH's capsules are flat, so
    /// our own surface must be the only chrome).
    @ToolbarContentBuilder
    private func plainToolbarItem<T: ToolbarContent>(_ item: T) -> some ToolbarContent {
        #if swift(>=6.2)
        item.sharedBackgroundVisibility(.hidden)
        #else
        item
        #endif
    }


    /// Device Hub's trailing clusters (TB-03, TB-04).
    @ToolbarContentBuilder
    private var trailingToolbar: some ToolbarContent {
        // Push the device controls to the trailing edge, Device Hub style.
        #if swift(>=6.2)
        ToolbarSpacer(.flexible, placement: .primaryAction)
        #endif

        // Background downloads (system images, the emulators waiting on
        // them): progress without a modal sheet.
        if model.avdCreation.hasActivity {
            plainToolbarItem(ToolbarItem(id: "downloads", placement: .primaryAction) {
                SelfObservingToolbarItemContent { DownloadsToolbarButton(queue: model.avdCreation) }
            })
        }

        plainToolbarItem(ToolbarItem(id: "keyboard-capsule", placement: .primaryAction) {
            SelfObservingToolbarItemContent { keyboardLayoutCapsule }
        })

        plainToolbarItem(ToolbarItem(id: "zoom-capsule", placement: .primaryAction) {
            SelfObservingToolbarItemContent { zoomCapsule }
        })

        plainToolbarItem(ToolbarItem(id: "rotate-capsule", placement: .primaryAction) {
            SelfObservingToolbarItemContent { rotateMoreCapsule }
        })

        // The signal of missing Android tools: `refresh()` raises no alert
        // for it. The button opens the guided setup.
        if !model.adbIsAvailable {
            plainToolbarItem(ToolbarItem(id: "adb-warning", placement: .primaryAction) {
                Button {
                    workspace.window.isAndroidSetupPresented = true
                } label: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Android tools not set up")
                .help("Android tools are not set up yet. Click to install or locate them.")
            })
        }

        // Device Hub's inspector controls: sit at the very trailing edge,
        // above the inspector pane.
        plainToolbarItem(ToolbarItem(id: "log-focus-capsule", placement: .primaryAction) {
            SelfObservingToolbarItemContent { logFocusCapsule }
        })

        plainToolbarItem(ToolbarItem(id: "inspector-capsule", placement: .primaryAction) {
            SelfObservingToolbarItemContent { inspectorCapsule }
        })
    }


    /// TB-03: DH's 83×36 pt keyboard + device-frame capsule.
    private var keyboardLayoutCapsule: some View {
        toolbarCapsule(
            spacing: ParityMetrics.toolbarKeyboardButtonSpacing,
            padding: ParityMetrics.toolbarKeyboardCapsulePadding,
            platter: .capsule(ParityMetrics.toolbarTogglePlatterSize)
        ) {
            toolbarIconButton(
                toggleState: model.preferences.keyboardForwardingEnabled,
                help: SoftKeyboardHint.tooltip(
                    base: "Capture Keyboard",
                    captureEnabled: model.preferences.keyboardForwardingEnabled,
                    serial: workspace.liveSelectionSerial
                ),
                accessibilityLabel: "Capture Keyboard",
                action: { model.setKeyboardCapture(!model.preferences.keyboardForwardingEnabled) }
            ) {
                Image(systemName: "keyboard")
                    .foregroundStyle(model.preferences.keyboardForwardingEnabled ? ToolbarInk.label : Color.secondary)
            }
            // Device Hub's keyboard toggle is dimmed while the device is off.
            .disabled(!stageZoomIsAvailable(
                liveSelectionSerial: workspace.liveSelectionSerial,
                hasSession: workspace.selectedDeviceHasSession
            ))
            .popover(
                isPresented: Binding(
                    get: { model.softKeyboardHintVisible },
                    set: { model.softKeyboardHintVisible = $0 }
                ),
                arrowEdge: .bottom
            ) {
                Text(SoftKeyboardHint.text)
                    .font(.callout)
                    .frame(width: 280, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }

            // DH's second button is "Enter resize mode" (an aspect-ratio
            // toggle, disabled on every simulator); Show Device Frame lives
            // in the View menu.
            // Listed only for a device whose display can be resized (a resizable
            // AVD); a stopped one keeps it dimmed.
            if workspace.offersResizeMode {
                let canResize = workspace.canEnterResizeMode
                let isResizing = workspace.isInResizeMode
                toolbarIconButton(
                    toggleState: isResizing,
                    help: isResizing ? "Exit resize mode" : "Enter resize mode",
                    accessibilityLabel: "Resize mode",
                    action: { workspace.window.toggleResizeMode() }
                ) {
                    Image(systemName: "aspectratio")
                        .foregroundStyle(isResizing ? Color.accentColor : (canResize ? ToolbarInk.label : Color.secondary))
                }
                .disabled(!canResize)
            }
        }
    }

    /// TB-03: DH's 151×36 pt zoom capsule (− │ fit 1 +).
    private var zoomCapsule: some View {
        // A simulator's canvas session is live without a serial.
        let isDisabled = !stageZoomIsAvailable(
            liveSelectionSerial: workspace.liveSelectionSerial,
            hasSession: workspace.selectedDeviceHasSession
        )
        return ToolbarSegmentedCapsule(
            segments: [
                ToolbarSegment(
                    id: "zoom-out",
                    isDisabled: isDisabled || workspace.window.isAtMinZoom,
                    help: "Zoom Out",
                    action: { workspace.window.zoomOut() }
                ) {
                    Image(systemName: "minus.magnifyingglass")
                },
                ToolbarSegment(
                    id: "zoom-fit",
                    isActive: workspace.window.zoomIsFit,
                    isDisabled: isDisabled,
                    help: "Zoom to Fit",
                    label: "Zoom to Fit",
                    action: { workspace.window.resetZoom() }
                ) {
                    fitZoomIcon
                },
                ToolbarSegment(
                    id: "zoom-physical",
                    isActive: workspace.window.zoomIsPhysicalSize,
                    isDisabled: isDisabled || !workspace.window.canShowPhysicalSize,
                    help: "Physical Size",
                    label: "Physical Size",
                    action: { workspace.window.physicalSizeZoom() }
                ) {
                    Image(systemName: "1.magnifyingglass")
                },
                ToolbarSegment(
                    id: "zoom-in",
                    isDisabled: isDisabled || workspace.window.isAtMaxZoom,
                    help: "Zoom In",
                    action: { workspace.window.zoomIn() }
                ) {
                    Image(systemName: "plus.magnifyingglass")
                },
            ],
            padding: ParityMetrics.toolbarZoomCapsulePadding,
            groupLabel: "Zoom"
        )
    }

    /// TB-03: DH's 74×36 pt compact-window + overflow capsule. DH's
    /// compress-arrows button switches to the compact window ("Open in New
    /// Window" to assistive tech); its "..." holds the device's own actions
    /// (`ToolbarMoreCapsule`).
    private var rotateMoreCapsule: some View {
        ToolbarMoreCapsule(
            leadingSymbol: "arrow.up.right.and.arrow.down.left",
            leadingHelp: "Switch to compact window",
            leadingAccessibilityLabel: "Open in New Window",
            leadingAction: { toggleCompactMirror() }
        )
    }

    /// TB-04: DH's 112×36 pt [sliders │ doc │ i] capsule. Like DH, the
    /// sliders button opens the device-settings panel (our Controls
    /// inspector); the app's own Settings scene stays on the standard app
    /// menu and View ▸ Inspectors ▸ Settings. Each button lights only while
    /// the inspector shows its surface, and i is the way back to Info/Apps
    /// from Controls or Diagnostics (which hide the segmented control).
    /// Log focus: the window shows only the phone and the live log.
    private var logFocusCapsule: some View {
        ToolbarSegmentedCapsule(
            segments: [
                ToolbarSegment(
                    id: "log-focus",
                    isActive: workspace.window.isLogFocus,
                    help: workspace.window.isLogFocus ? "Exit Log Focus" : "Log Focus",
                    label: "Log Focus",
                    action: { workspace.window.toggleLogFocus() }
                ) {
                    Image(systemName: "text.alignleft")
                },
            ],
            padding: ParityMetrics.toolbarInspectorCapsulePadding,
            groupLabel: "Log Focus"
        )
    }

    private var inspectorCapsule: some View {
        // A family with no Controls panel (an Apple Watch or Vision simulator) has no
        // Settings segment: it would open an empty panel.
        let hasControlsPanel = workspace.deviceFamily?.hasControlsPanel ?? true
        let settingsSegments: [ToolbarSegment] = hasControlsPanel ? [
            ToolbarSegment(
                id: "inspector-controls",
                isActive: workspace.window.isInspectorToolbarButtonActive(.controls),
                help: "Settings",
                label: "Edit",
                action: { workspace.window.selectInspectorTab(.controls) }
            ) {
                Image(systemName: "slider.horizontal.3")
            },
        ] : []
        return ToolbarSegmentedCapsule(
            segments: settingsSegments + [
                ToolbarSegment(
                    id: "inspector-diagnostics",
                    isActive: workspace.window.isInspectorToolbarButtonActive(.diagnostics),
                    help: "Reports",
                    label: "Text Document",
                    action: { workspace.window.selectInspectorTab(.diagnostics) }
                ) {
                    // DH's own glyph (its AX identifier): not `doc.text`.
                    Image(systemName: "text.document")
                },
                // DH's Info segment is the plain `info` glyph, not the
                // circled one.
                ToolbarSegment(
                    id: "inspector-info",
                    isActive: workspace.window.isInspectorToolbarButtonActive(.deviceInfo),
                    help: "Info",
                    action: { workspace.window.toggleDeviceInfoInspector() }
                ) {
                    Image(systemName: "info")
                },
            ],
            padding: ParityMetrics.toolbarInspectorCapsulePadding,
            groupLabel: "Inspector Category"
        )
        // Re-measured 2026-09-29 (DH 27.0): the pill ends 8 pt from the window's
        // edge; the earlier pull-out left it 3 pt from it.
        .padding(.trailing, -ParityMetrics.toolbarTrailingInset + 5)
    }

    /// One Device Hub toolbar capsule: one flat surface around controls at the
    /// audited 36 pt height, each button with DH's hover/press `platter`. No
    /// `GlassEffectContainer` here — under the new design the container
    /// draws a glass ring around every child button, which DH's capsules do
    /// not have.
    private func toolbarCapsule<Content: View>(
        spacing: CGFloat = 0,
        padding: CGFloat,
        platter: PlatterShape,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        HStack(spacing: spacing) {
            content()
        }
        .buttonStyle(ChromeButtonStyle(platter: platter))
        .frame(height: ParityMetrics.toolbarButtonHeight)
        .padding(.horizontal, padding)
        .toolbarControlSurface()
        .padding(.horizontal, -ParityMetrics.toolbarClusterInset)
        // Each button keeps its own name: without a container the toolbar
        // gave every button the first one's name once the sidebar was hidden.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("")
    }

    /// Device Hub toolbar icon button: a 36 pt hit target. Assistive tech
    /// hears a button that flips a setting (`toggleState`) as a toggle with
    /// an on/off value — its drawing is left to the caller (DH shows those
    /// states by glyph, not platter).
    private func toolbarIconButton<Label: View>(
        toggleState: Bool? = nil,
        help: String,
        accessibilityLabel: String? = nil,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action) {
            label()
                .font(.system(size: ParityMetrics.toolbarIconSize, weight: ParityMetrics.toolbarIconWeight))
                .frame(
                    width: ParityMetrics.toolbarButtonWidth,
                    height: ParityMetrics.toolbarButtonHeight
                )
                .contentShape(Rectangle())
        }
        .accessibilityLabel(accessibilityLabel ?? help)
        .toolbarButtonAccessibilityState(active: false, toggleState: toggleState)
        .help(help)
    }

    /// DH's overflow glyph: three 3 pt dots at a 3 pt gap (15 pt total).
    /// Drawn by hand because the borderless menu label ignores the symbol's
    /// font size (verified: 30 pt renders the same 12 pt ink).
    private var moreDotsIcon: some View {
        HStack(spacing: ParityMetrics.toolbarMoreDotSpacing) {
            ForEach(0..<3, id: \.self) { _ in
                Circle()
                    .fill(ToolbarInk.label)
                    .frame(
                        width: ParityMetrics.toolbarMoreDotDiameter,
                        height: ParityMetrics.toolbarMoreDotDiameter
                    )
            }
        }
        .frame(
            width: ParityMetrics.toolbarButtonWidth,
            height: ParityMetrics.toolbarButtonHeight
        )
        .contentShape(Rectangle())
    }

    /// Device Hub's "Zoom to Fit" glyph: a 4-way triangle compass in the
    /// magnifier's lens, drawn by ``FourTriangleCompassShape`` (TB-06). DH's
    /// own AX identifier for this button
    /// (`arrowtriangles.up.right.down.left.magnifyingglass`, from an
    /// axframes dump) is not in the public SF Symbols catalog — `sym`
    /// (parity audit, TB-06) confirms `NSImage(systemSymbolName:)`
    /// returns nil for it on this SDK, so `Image(systemName:)` renders
    /// nothing for it, and the closest public glyph, `dpad.fill`, turned out
    /// to draw four rounded lobes rather than DH's sharp triangles once a 2x
    /// crop of DH's own icon was magnified — so this hand-traces DH's shape
    /// instead of substituting a different public symbol.
    private var fitZoomIcon: some View {
        ZStack {
            Image(systemName: "magnifyingglass")
                .font(.system(size: ParityMetrics.toolbarIconSize, weight: ParityMetrics.toolbarIconWeight))
            FourTriangleCompassShape()
                .fill(ToolbarInk.solid)
                .frame(width: ParityMetrics.toolbarFitLensGlyphSize, height: ParityMetrics.toolbarFitLensGlyphSize)
                .offset(ParityMetrics.toolbarFitLensGlyphOffset)
        }
    }

}

/// What assistive tech hears about a toolbar button's state: an active
/// mode (fit, physical size, the open inspector surface) is selected; a
/// button that flips a setting is a toggle whose value is on or off.
struct ToolbarButtonAccessibility: Equatable {
    let isSelected: Bool
    let isToggle: Bool
    let value: String?

    init(active: Bool, toggleState: Bool?) {
        isSelected = active
        isToggle = toggleState != nil
        value = toggleState.map { $0 ? "on" : "off" }
    }
}

extension View {
    func toolbarButtonAccessibilityState(active: Bool, toggleState: Bool?) -> some View {
        let state = ToolbarButtonAccessibility(active: active, toggleState: toggleState)
        var traits: AccessibilityTraits = []
        if state.isSelected { traits.formUnion(.isSelected) }
        if state.isToggle { traits.formUnion(.isToggle) }
        return accessibilityAddTraits(traits)
            .accessibilityValue(state.value.map { Text($0) } ?? Text(""))
    }
}

/// Toolbar item content must not read observable model state while
/// `ContentView.body` evaluates: SwiftUI evaluates `ToolbarItem` content
/// within the body's update scope, so a read there (the zoom capsule's
/// `liveSelectionSerial`, the rotate menu's `replayBuffer`-derived labels, …)
/// re-ran the body — and with it the window toolbar — on every device switch
/// or replay-buffer tick. Storing the content as a closure and evaluating it
/// inside this view keeps those reads in this view's own update scope.
private struct SelfObservingToolbarItemContent<Content: View>: View {
    private let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        content()
    }
}

/// Runs the pixel-catalog refresh off `ContentView.body`'s update scope:
/// reading `avdCards`/`avdDevices` there re-applied the window toolbar on
/// every gallery refresh. One task, keyed on the refresh's real inputs: the
/// old pair keyed on AVD and profile *counts* ran twice on appear (before
/// the skin catalog had loaded), never again for a user with no AVDs — so
/// Pixel Devices never appeared — and missed renames.
private struct PixelCatalogRefreshHost: View {
    @Environment(AppModel.self) private var model
    @Environment(PixelCatalogModel.self) private var pixelCatalog

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task(id: model.catalog.pixelCatalogInputs) {
                await pixelCatalog.refresh(from: model)
            }
    }
}

/// Self-observing status banner: reading `statusMessage` at the ContentView
/// body level would re-evaluate the toolbar content (and rebuild the window
/// toolbar) whenever a status appears or clears.
private struct StatusBannerHost: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Whichever of the app-global center and this window's own workspace
    /// wrote `statusMessage` most recently (`StatusCenter.active(status:_:)`,
    /// ) — the same merge the error alert uses
    /// (`ContentView.activeErrorCenter`), so a single window's banner reads
    /// exactly as the one shared center used to.
    private var activeCenter: StatusCenter {
        StatusCenter.active(status: model.status, workspace.status)
    }

    private var message: String? { activeCenter.statusMessage }

    var body: some View {
        Group {
            if let message {
                StatusBanner(
                    text: UserFacingText.plain(message),
                    kind: activeCenter.statusKind,
                    onCancel: message == model.multiDevice.progressMessage
                        ? { model.multiDevice.cancel() } : nil
                )
                    .padding(.top, ParityMetrics.statusBannerTopInset)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .top).combined(with: .opacity)
                    )
            }
        }
        .animation(reduceMotion ? nil : MotionMetrics.banner, value: message)
        // The banner is visual only; VoiceOver users hear each new status
        // ("Installing app.apk…", "Text size set to 115 %").
        .onChange(of: message) { _, message in
            if let message {
                AccessibilityNotification.Announcement(message).post()
            }
        }
    }
}

/// Device Hub's stage title (ST-01): the device name and its state as the
/// window's own title and subtitle, which the system draws in the detail
/// column's toolbar band from the sidebar divider — DH's is the window title
/// too (x = 304 pt beside a 300 pt sidebar). A modifier, not a toolbar item,
/// and self-observing: reading the model in `ContentView.body` re-applied
/// the window toolbar on every selection (TB-05).
private struct StageWindowTitle: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace

    func body(content: Content) -> some View {
        let stage = StageTitle(model: model, workspace: workspace)
        content
            .navigationTitle(stage.title)
            .navigationSubtitle(stage.subtitle ?? "")
    }
}

/// The stage's title and subtitle for the current selection.
@MainActor
struct StageTitle {
    let model: AppModel
    /// The window whose stage this titles (each window has its own).
    let workspace: DeviceWorkspace

    /// Two-line window title for the current stage, Device Hub style.
    var title: String {
        switch workspace.deviceSelection {
        case .avd(let name):
            model.catalog.avdCards.first(where: { $0.name == name })?.displayName ?? name
        case .device(let serial):
            model.inventory.devices.first(where: { $0.serial == serial })?.displayName ?? serial
        case .pixel(let skinName):
            model.catalog.skinCatalog.first(where: { $0.name == skinName })?.displayName ?? skinName
        case .simulator(let udid):
            model.simulators.entry(udid: udid)?.name ?? udid
        case .physicalApple(let udid):
            model.physicalInventory.entry(udid: udid)?.name ?? "Apple Device"
        case nil:
            "Devices"
        }
    }

    var subtitle: String? {
        switch workspace.deviceSelection {
        case .avd(let name):
            guard let card = model.catalog.avdCards.first(where: { $0.name == name }) else {
                return nil
            }
            if let serial = card.serial,
               model.inventory.devices.first(where: { $0.serial == serial })?.isOnline == true
            {
                return model.inventory.deviceInfos[serial]
                    .map { "Android \($0.androidVersion)" } ?? "Android"
            }
            if model.avdIsBooting(name) { return "Booting" }
            // DH names no state for a stopped device, just its OS.
            return card.osTitle ?? "Android"
        case .device(let serial):
            guard let device = model.inventory.devices.first(where: { $0.serial == serial }) else {
                return nil
            }
            if device.isOnline {
                return model.inventory.deviceInfos[serial]
                    .map { "Android \($0.androidVersion)" }
                    ?? (device.isEmulator ? "Emulator" : "Physical")
            }
            return device.stateLabel
        case .pixel(let skinName):
            guard let card = model.catalog.avdCards.first(where: { $0.skin?.name == skinName }) else {
                return "Requires download"
            }
            if let serial = card.serial,
               model.inventory.devices.first(where: { $0.serial == serial })?.isOnline == true
            {
                return model.inventory.deviceInfos[serial]
                    .map { "Android \($0.androidVersion)" } ?? "Running"
            }
            return card.targetLabel.map { "Installed · \($0)" } ?? "Installed"
        case .simulator(let udid):
            guard let entry = model.simulators.entry(udid: udid) else { return nil }
            return entry.statusLine(
                runState: model.simulatorLifecycle.runState(for: entry),
                operation: model.simulatorLifecycle.operations[udid]
            )
        case .physicalApple(let udid):
            guard let entry = model.physicalInventory.entry(udid: udid) else { return nil }
            return [entry.osLabel, entry.stateLabel].compactMap { $0 }.joined(separator: " · ")
        case nil:
            // DH's window subtitle with nothing selected.
            return "No Selection"
        }
    }
}

// MARK: - Status banner

private struct StatusBanner: View {
    let text: String
    /// Stored by the line's writer (`StatusCenter.statusKind`), never read
    /// from the text.
    let kind: StatusBannerKind
    /// A batch's Cancel, beside its progress line.
    var onCancel: (() -> Void)?

    var body: some View {
        HStack(spacing: ParityMetrics.statusBannerSpacing) {
            // A spinner only while something runs; an outcome is text alone.
            if kind == .progress {
                ProgressView()
                    .controlSize(.small)
            }
            Text(text)
            if let onCancel {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.link)
            }
        }
        .padding(.horizontal, ParityMetrics.statusBannerHorizontalPadding)
        .padding(.vertical, ParityMetrics.statusBannerVerticalPadding)
        .liquidGlass()
        .glassHairline(in: Capsule())
    }
}
