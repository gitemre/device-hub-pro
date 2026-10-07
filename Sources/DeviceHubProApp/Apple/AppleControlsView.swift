import SwiftUI
import DeviceHubProKit

/// The Settings inspector for a simulator: Device Hub's own panel, three
/// unlabelled cards (`AppleControlsController.simulatorCards`: appearance and
/// the accessibility switches, Location, Sound with its Output and Input),
/// read while the simulator is ready and shown (`ControlsPoll`, one spawn per
/// tick). A simulator that is off gets DH's placeholder. Everything else the
/// panel used to hold (Face ID, push, permissions, language, time zone, the
/// status bar, Open URL) is in the Device menu, and again, below the cards, in
/// collapsed groups in the Android panel's wording (`AppleGroupsView`).
struct AppleControlsView: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace
    let udid: String

    @State private var isLocationSheetPresented = false

    private var controls: AppleControlsController { workspace.appleControls }

    var body: some View {
        let entry = model.simulators.entry(udid: udid)
        let platform = entry?.platform
        let offered = appleControlsOffered(platform: platform)
        let isReady = model.simulatorLifecycle.isReady(udid)
        let ready = offered && isReady
        let attached = controls.udid == udid
        Group {
            if !isReady {
                // DH's empty state fills the whole panel (CT-10); it is
                // never inside the card scroll below. A simulator of any
                // platform that is off gets it (an Apple TV's included).
                notReadyCard
            } else if !offered {
                DHControlsEmptyState(
                    glyph: "slider.horizontal.3",
                    caption: "Behavior and appearance controls are not available for this simulator."
                )
            } else {
                DHSettingsPanel {
                    if !attached || !controls.isLoaded {
                        loadingCard
                    } else {
                        ForEach(Array(controls.simulatorCards(osVersion: entry?.osVersion).enumerated()), id: \.offset) { _, rows in
                            DHCard {
                                ForEach(Array(rows.enumerated()), id: \.element) { index, row in
                                    AppleControlsRowView(row: row, udid: udid) { isLocationSheetPresented = true }
                                    if index != rows.count - 1 {
                                        DHHairline()
                                    }
                                }
                            }
                        }
                        AppleGroupsView(groups: controls.simulatorGroups(), udid: udid, isPhysical: false)
                        // Plain rows after the groups: Clean status bar, just above Reset to Defaults.
                        let plainRows = controls.simulatorPlainRows()
                        if !plainRows.isEmpty {
                            DHCard {
                                ForEach(Array(plainRows.enumerated()), id: \.element) { index, row in
                                    AppleGroupRowView(row: row, udid: udid, isPhysical: false)
                                    if index != plainRows.count - 1 {
                                        DHHairline()
                                    }
                                }
                            }
                        }
                        // Reset to Defaults ends the panel, in a card of its own (Android's Reset conditions).
                        DHCard {
                            AppleGroupRowView(row: .resetDefaults, udid: udid, isPhysical: false)
                        }
                        .environment(\.dhRowTooltips, true)
                    }
                }
            }
        }
        // DH's rows carry no tooltip.
        .environment(\.dhRowTooltips, false)
        .sheet(isPresented: $isLocationSheetPresented) {
            AppleLocationSheet()
        }
        .task(id: AppleControlsAttachment(udid: udid, ready: ready)) {
            guard ready else { return }
            let token = await controls.attach(udid)
            await ControlsPoll.run(every: AppleControlsPollPlan.interval) { await controls.pollTick() }
            controls.detach(token)
        }
    }

    /// DH's own wording (CT-10, measured on Device Hub 27.0's settings
    /// panel for a stopped simulator): a centered glyph and caption filling
    /// the whole panel, naming no simulator — DH's message does not either.
    private var notReadyCard: some View {
        DHControlsEmptyState(
            glyph: "slider.horizontal.3",
            caption: "Start the simulator to customize behavior and appearance."
        )
    }

    private var loadingCard: some View {
        AppleControlsLoadingCard()
    }
}

/// The card a panel shows while its first reads run.
struct AppleControlsLoadingCard: View {
    var body: some View {
        DHCard {
            DHControlRow {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Loading controls")
                    Text("Loading controls")
                        .font(.system(size: ParityMetrics.controlsLabelFontSize))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// The note at the end of a panel naming the rows it leaves out, grouped by
/// the reason (hidden rows are never silent).
struct AppleControlsHiddenNote: View {
    let hidden: [(title: String, reason: String)]

    var body: some View {
        if !hidden.isEmpty {
            let grouped = Dictionary(grouping: hidden, by: \.reason)
            DHCard {
                ForEach(Array(grouped.keys.sorted().enumerated()), id: \.element) { index, reason in
                    let titles = (grouped[reason] ?? []).map(\.title).joined(separator: ", ")
                    DHCaptionRow("Not offered here: \(titles). \(reason)")
                    if index != grouped.count - 1 {
                        DHHairline()
                    }
                }
            }
        }
    }
}

/// The poll's task identity: a new attach when the simulator or its
/// readiness changes (a restart ends the reads and starts them again).
private struct AppleControlsAttachment: Hashable {
    let udid: String
    let ready: Bool
}

/// The simulator's Custom Location… sheet: the shared sheet
/// (`CustomLocationSheet`), a coordinate or a route between two points
/// (`AppleLocationChoice.route`, simctl `location start`). A physical iPhone's
/// is the coordinate only and keeps its Device Hub title.
struct AppleLocationSheet: View {
    @Environment(DeviceWorkspace.self) private var workspace
    var isPhysical = false

    var body: some View {
        CustomLocationSheet(
            title: isPhysical ? "Custom Coordinates" : "Custom Location",
            allowsRoute: !isPhysical,
            onCoordinate: { latitude, longitude in
                await workspace.appleControls.setLocation(.coordinate(name: nil, latitude: latitude, longitude: longitude))
                return nil
            },
            onRoute: { from, to, speed in
                await workspace.appleControls.setLocation(.route(
                    [SimulatorWaypoint(latitude: from.latitude, longitude: from.longitude),
                     SimulatorWaypoint(latitude: to.latitude, longitude: to.longitude)],
                    speed: speed
                ))
                return nil
            }
        )
    }
}
