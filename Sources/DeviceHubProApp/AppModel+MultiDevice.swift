import Foundation
import DeviceHubProKit

/// The sidebar's multi-selection and what acts on it:
///the gestures that gather rows, and Apply to Selected and
/// Screenshot All Selected over them (`MultiDeviceController`).
extension AppModel {
    /// Hands `multiDevice` the device work: the Controls rows' mechanisms by
    /// serial or UDID (`BatchPerformer`).
    func wireMultiDevice() {
        // A batch write reaches what every window keeps: each panel notes
        // a simulator's change, and a status bar write on a device goes
        // through the workspace that mirrors it (its write queue and
        // put-back record), else any workspace's controller writes it
        // directly.
        let registry = registry
        let fallback = workspace
        let performer = BatchPerformer(
            adbClient: adbClient,
            grpcPorts: grpcPorts,
            simulators: simulators,
            simulatorApps: { udid in
                (registry.owner(of: .apple(udid)) ?? registry.focused ?? fallback).simulatorApps
            },
            appleDeviceMemory: appleDeviceMemory,
            noteAppleBatchChange: { change, udid in
                for workspace in registry.workspaces {
                    workspace.appleControls.noteBatchChange(change, udid: udid)
                }
            },
            statusBar: { serial in
                (registry.owner(of: .android(serial)) ?? registry.focused ?? fallback).conditions.statusBar
            },
            devices: { [weak self] in self?.inventory.devices ?? [] },
            locationOwner: { serial in registry.owner(of: .android(serial))?.location }
        )
        let multiDevice = multiDevice
        performer.recordProfileNotes = { id, notes in multiDevice.recordProfileNotes(id, notes) }
        multiDevice.perform = { target, operation, context in
            try await performer.perform(target, operation, context)
        }
    }

    // MARK: - Gestures

    /// A plain click or arrow: `row` alone. Every gesture acts on the window
    /// that made it (`target`; the model's own workspace when none is named):
    /// a second window or tab has its own selection, and its sidebar must
    /// never write the first window's.
    func selectOnlyRow(_ row: DeviceSelection, in target: DeviceWorkspace? = nil) {
        let target = target ?? workspace
        var multi = target.multiSelection
        multi.selectOnly(row)
        if multi != target.multiSelection { target.multiSelection = multi }
        if target.deviceSelection != row { target.deviceSelection = row }
    }

    /// ⌘-click: adds `row` (it becomes the primary) or removes it.
    func toggleRow(_ row: DeviceSelection, in target: DeviceWorkspace? = nil) {
        let target = target ?? workspace
        var multi = target.multiSelection
        let primary = multi.toggle(row, primary: target.deviceSelection)
        // The rows first, so the primary's didSet finds itself among them.
        if multi != target.multiSelection { target.multiSelection = multi }
        if target.deviceSelection != primary { target.deviceSelection = primary }
    }

    /// ⇧-click or ⇧-arrow: the rows from the anchor to `row` in the visible
    /// `order`, added to the selection with ⌘ (`adding`).
    func extendRows(to row: DeviceSelection, in order: [DeviceSelection], adding: Bool, in target: DeviceWorkspace? = nil) {
        let target = target ?? workspace
        var multi = target.multiSelection
        let primary = multi.extend(to: row, in: order, adding: adding, primary: target.deviceSelection)
        if multi != target.multiSelection { target.multiSelection = multi }
        if target.deviceSelection != primary { target.deviceSelection = primary }
    }

    /// Select All: every device row of the visible `order`.
    func selectAllRows(_ order: [DeviceSelection], in target: DeviceWorkspace? = nil) {
        let target = target ?? workspace
        var multi = target.multiSelection
        let primary = multi.selectAll(order, primary: target.deviceSelection)
        if multi != target.multiSelection { target.multiSelection = multi }
        if target.deviceSelection != primary { target.deviceSelection = primary }
    }

    // MARK: - Actions

    /// Whether the Selected Devices items act: two rows or more, and no
    /// batch in flight.
    func canActOnSelected(in target: DeviceWorkspace? = nil) -> Bool {
        let ws = target ?? registry.focused ?? workspace
        return ws.multiSelection.isMultiple && !multiDevice.isRunning && !batchTargets(in: ws).isEmpty
    }

    /// The selected rows batch actions cannot reach, by name.
    func batchExcludedNames(in target: DeviceWorkspace? = nil) -> [String] {
        let ws = target ?? registry.focused ?? workspace
        return BatchTargeting.excludedRows(in: ws.multiSelection.rows).map { row in
            switch row {
            case .pixel(let skinName): skinName
            case .physicalApple(let udid): physicalInventory.entry(udid: udid)?.device.name ?? "A physical Apple device"
            default: ""
            }
        }
    }

    /// The multi-selection's rows as devices, resolved now.
    func batchTargets(in target: DeviceWorkspace? = nil) -> [BatchTarget] {
        let ws = target ?? registry.focused ?? workspace
        return BatchTargeting.targets(for: ws.multiSelection.rows, in: batchTargetingSnapshot)
    }

    /// What `BatchTargeting` reads: the adb rows, the AVD cards and starts,
    /// Device Info, and every simulator of the set with its run state (a
    /// selected one Show Unused hid since is still found).
    var batchTargetingSnapshot: BatchTargeting.Snapshot {
        let lifecycle = simulatorLifecycle
        let entries = simulators.simulators
        var reasons: [String: String] = [:]
        for entry in entries {
            if let reason = entry.availabilityError { reasons[entry.udid] = reason }
        }
        return BatchTargeting.Snapshot(
            devices: inventory.devices,
            avdCards: catalog.avdCards,
            startingAvdNames: boot.startingAvdNames,
            deviceInfos: inventory.deviceInfos,
            simulators: entries.map { $0.summary(runState: lifecycle.runState(for: $0)) },
            unavailableReasons: reasons
        )
    }

    /// Apply to Selected: `action` on every selected device.
    func applyToSelected(_ action: BatchAction, in target: DeviceWorkspace? = nil) async {
        await multiDevice.run(action, on: batchTargets(in: target), excluded: batchExcludedNames(in: target))
    }

    /// Screenshot All Selected: one PNG per selected device, in a folder the
    /// save panel names.
    func screenshotAllSelected(in target: DeviceWorkspace? = nil) async {
        await multiDevice.screenshotAll(batchTargets(in: target), excluded: batchExcludedNames(in: target))
    }

    /// Apply to Selected ▸ Open URL…: asks for the link, then opens it on
    /// every selected device.
    func openURLOnSelected(in target: DeviceWorkspace? = nil) async {
        guard let text = BatchInputPanels.askForLink() else { return }
        await applyToSelected(.openURL(text), in: target)
    }

    /// Apply to Selected ▸ Install Build…: asks for the builds (one per
    /// platform), then installs each on the devices that run it.
    func installBuildOnSelected(in target: DeviceWorkspace? = nil) async {
        switch BatchInputPanels.chooseBuilds() {
        case nil:
            return
        case .failure(let problem)?:
            status.errorMessage = problem.description
        case .success(let builds)?:
            await applyToSelected(.install(builds), in: target)
        }
    }
}
