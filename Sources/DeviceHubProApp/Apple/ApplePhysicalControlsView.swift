import SwiftUI
import DeviceHubProKit

/// The Controls inspector for a physical iPhone or iPad, in Device Hub's
/// look: the simulator panel's rows
/// (`AppleControlsRowView`) in Device Hub's unheaded cards
/// (`applePhysicalCards`), read and changed through
/// `AppleControlsController.attachPhysical` and
/// `ApplePhysicalControlsBackend`. The rows are the ones the phone's own
/// CoreDevice capability list offers; a row it does not offer is simply not
/// there (no headings, no "Not offered here" notes). A device that is not
/// enabled, paired and connected gets a card saying what to do, and nothing
/// is sent to it.
struct ApplePhysicalControlsView: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace
    let entry: ApplePhysicalEntry

    @State private var isLocationSheetPresented = false

    private var controls: AppleControlsController { workspace.appleControls }

    var body: some View {
        let usable = entry.canUseClient
        let attached = controls.udid == entry.udid && controls.isPhysical && controls.isLoaded
        Group {
            if !usable {
                DHControlsEmptyState(
                    glyph: "slider.horizontal.3",
                    caption: entry.hint ?? "Connect and unlock the device to customize it."
                )
            } else {
                DHSettingsPanel {
                    if !attached {
                        AppleControlsLoadingCard()
                    } else if let failure = controls.physicalFailure {
                        DHCard {
                            DHCaptionRow(failure)
                        }
                    } else {
                        ForEach(Array(applePhysicalCards(offered: Set(controls.groups.flatMap(\.rows))).enumerated()), id: \.offset) { _, rows in
                            DHCard {
                                ForEach(Array(rows.enumerated()), id: \.element) { index, row in
                                    AppleControlsRowView(row: row, udid: entry.udid) { isLocationSheetPresented = true }
                                    if index != rows.count - 1 {
                                        DHHairline()
                                    }
                                }
                            }
                        }
                        AppleGroupsView(groups: applePhysicalGroupRows, udid: entry.udid, isPhysical: true)
                        DHCard {
                            ForEach(Array(applePhysicalPlainRows.enumerated()), id: \.element) { index, row in
                                AppleGroupRowView(row: row, udid: entry.udid, isPhysical: true)
                                if index != applePhysicalPlainRows.count - 1 {
                                    DHHairline()
                                }
                            }
                        }
                        .environment(\.dhRowTooltips, true)
                    }
                }
            }
        }
        // DH's rows carry no tooltip.
        .environment(\.dhRowTooltips, false)
        .sheet(isPresented: $isLocationSheetPresented) {
            AppleLocationSheet(isPhysical: true)
        }
        .task(id: PhysicalControlsAttachment(udid: entry.udid, usable: usable)) {
            guard usable else { return }
            let token = await controls.attachPhysical(entry.udid)
            await ControlsPoll.run(every: ApplePhysicalControlsBackend.pollBeat) { await controls.pollTick() }
            controls.detach(token)
        }
    }
}

/// The poll's task identity: a new attach when the device becomes usable or
/// another device is selected.
private struct PhysicalControlsAttachment: Hashable {
    let udid: String
    let usable: Bool
}

/// The rows of a physical iPhone's cards, in Device Hub's order (measured on
/// Device Hub 27.0 with the test iPhone, 2026-09-29): the appearance and
/// accessibility card (Appearance, Liquid Glass, Text Size, Reduce Motion,
/// Increase Contrast, Show Borders, Reduce Transparency, VoiceOver), then
/// Location. Device Hub Pro's own two rows follow: Color Filter after Liquid Glass
/// (as on a simulator's card).
let applePhysicalCardRows: [[ControlsRow]] = [
    [
        .appearance, .liquidGlass, .colorFilter, .textSize, .reduceMotion, .increaseContrast,
        .showBorders, .reduceTransparency, .talkBack,
    ],
    [.location],
]

/// The physical panel's cards: the rows of `applePhysicalCardRows` that
/// `offered` names (the phone's capability list and the calls that failed
/// decide), a card without rows dropped.
func applePhysicalCards(offered: Set<ControlsRow>) -> [[ControlsRow]] {
    applePhysicalCardRows.compactMap { card in
        let rows = card.filter(offered.contains)
        return rows.isEmpty ? nil : rows
    }
}
