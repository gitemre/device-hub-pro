import DeviceHubProKit

/// The stage's selection routing as pure functions over a snapshot of the
/// device list, the AVD cards, the in-app starts and the listed simulators:
/// which serial the stage shows live, which serial the inspector reads, what
/// a stale selection is replaced with, whether an AVD is booting and what
/// Return on a sidebar row starts. A simulator has no adb serial: its
/// selection routes to no serial here, and the simulator stage reads it by
/// UDID. A physical Apple device routes to nothing here either, and is never
/// picked by `ensureTarget`: a physical device is selected only by the user.
///
/// `AppModel` keeps `deviceSelection` and the members under their old names
/// (`liveSelectionSerial`, `inspectorSerial`, `ensureDeviceSelection()` with
/// `select(_:)`, `avdIsBooting(_:)` and `sidebarStartTarget(for:)`): each
/// builds a `Snapshot` from `DeviceInventory`, `AvdCatalogController` and
/// `EmulatorBootController` and calls these statics.
enum SelectionRouting {
    /// What the routing reads: `AppModel`'s `devices`, `avdCards`, `avds`,
    /// `skinCatalog`, `startingAvdNames` and the simulators the sidebar
    /// lists at the moment of the call.
    struct Snapshot: Sendable {
        /// The sidebar's device rows, the synthetic ghost row included.
        var devices: [AndroidDevice]
        /// The installed AVDs with their running state and serial.
        var avdCards: [AvdCard]
        /// The AVD names from the last `emulator -list-avds`.
        var avds: [String]
        /// Every device skin in the SDK (the Pixel rows).
        var skinCatalog: [SkinCatalogEntry]
        /// The AVDs an in-app start or restart is booting.
        var startingAvdNames: Set<String>
        /// The simulators the sidebar lists (`SimulatorInventory
        /// .visibleSimulators`), in its order.
        var simulators: [SimulatorEntry]
        /// The hardware UDIDs of the physical Apple devices the sidebar
        /// lists (`ApplePhysicalInventory.listedUDIDs`).
        var physicalApple: [String]

        init(
            devices: [AndroidDevice] = [],
            avdCards: [AvdCard] = [],
            avds: [String] = [],
            skinCatalog: [SkinCatalogEntry] = [],
            startingAvdNames: Set<String> = [],
            simulators: [SimulatorEntry] = [],
            physicalApple: [String] = []
        ) {
            self.devices = devices
            self.avdCards = avdCards
            self.avds = avds
            self.skinCatalog = skinCatalog
            self.startingAvdNames = startingAvdNames
            self.simulators = simulators
            self.physicalApple = physicalApple
        }
    }

    /// What `ensureDeviceSelection()` does with the current selection.
    enum EnsureTarget: Equatable, Sendable {
        /// The selection is still valid; it is not assigned again.
        case keep
        /// The selection is assigned this value, even when it equals the
        /// current one (nil stays nil): the assignment itself runs
        /// `deviceSelection`'s didSet.
        case assign(DeviceSelection?)
    }

    /// Serial shown live in the stage for `selection`, if any. Single source
    /// of truth for stage routing and toolbar state.
    static func liveSelectionSerial(for selection: DeviceSelection?, in snapshot: Snapshot) -> String? {
        switch selection {
        case .avd(let name):
            // An in-app start keeps its booting panel until the boot is
            // complete and its own session starts (spec §6.4), even though
            // the hot-plug pass may know the new serial earlier.
            guard !snapshot.startingAvdNames.contains(name),
                  let serial = snapshot.avdCards.first(where: { $0.name == name })?.serial
            else {
                return nil
            }
            return snapshot.devices.first(where: { $0.serial == serial })?.isOnline == true ? serial : nil
        case .device(let serial):
            // Physical devices route to the live stage too; their
            // session is the scrcpy transport rather than the emulator gRPC one.
            guard let device = snapshot.devices.first(where: { $0.serial == serial }),
                  device.isOnline
            else {
                return nil
            }
            return serial
        case .pixel(let skinName):
            guard let card = snapshot.avdCards.first(where: { $0.skin?.name == skinName }),
                  !snapshot.startingAvdNames.contains(card.name),
                  let serial = card.serial
            else {
                return nil
            }
            return snapshot.devices.first(where: { $0.serial == serial })?.isOnline == true ? serial : nil
        case .simulator, .physicalApple, nil:
            // A simulator is no adb device: its stage reads it by UDID. A
            // physical Apple device is none either: CoreDevice, not adb.
            return nil
        }
    }

    /// The caption of a panel that has no live device to show, chosen by
    /// the selection's state: a phone that needs unlocking or is offline, a
    /// device still starting, else `stopped` (the "Start the device to ..."
    /// text of the caller).
    static func unavailableCaption(
        for selection: DeviceSelection?,
        in snapshot: Snapshot,
        stopped: String
    ) -> String {
        func caption(forSerial serial: String?) -> String? {
            guard let serial, let device = snapshot.devices.first(where: { $0.serial == serial }) else { return nil }
            switch device.state {
            case "unauthorized": return "Unlock the phone and allow USB debugging."
            case "offline": return "The device is offline."
            // Online but not on the stage: the mirror was stopped (the
            // stage offers Mirror) or is attaching.
            case "device": return "Mirror the device to use its controls."
            default: return nil
            }
        }
        switch selection {
        case .avd(let name):
            if snapshot.startingAvdNames.contains(name) { return "Connecting…" }
            let serial = snapshot.avdCards.first(where: { $0.name == name })?.serial
            if let text = caption(forSerial: serial) { return text }
            // Its emulator is listed by adb but not online yet.
            let listed = serial != nil && snapshot.devices.contains(where: { $0.serial == serial })
            return listed ? "Connecting…" : stopped
        case .pixel(let skinName):
            guard let card = snapshot.avdCards.first(where: { $0.skin?.name == skinName }) else { return stopped }
            if snapshot.startingAvdNames.contains(card.name) { return "Connecting…" }
            return caption(forSerial: card.serial) ?? stopped
        case .device(let serial):
            return caption(forSerial: serial) ?? stopped
        case .simulator, .physicalApple, nil:
            return stopped
        }
    }

    /// Serial for the inspector Info panel: the live device if any, else the
    /// selected AVD's serial when it is known.
    static func inspectorSerial(for selection: DeviceSelection?, in snapshot: Snapshot) -> String? {
        if let live = liveSelectionSerial(for: selection, in: snapshot) { return live }
        switch selection {
        case .avd(let name):
            return snapshot.avdCards.first(where: { $0.name == name })?.serial
        case .device(let serial):
            return serial
        case .pixel(let skinName):
            return snapshot.avdCards.first(where: { $0.skin?.name == skinName })?.serial
        case .simulator, .physicalApple, nil:
            return nil
        }
    }

    /// The selection that shows `device` (`select(_:)`): its AVD card when
    /// the serial belongs to a known AVD, else the device row itself.
    static func selection(for device: AndroidDevice, in snapshot: Snapshot) -> DeviceSelection {
        if let card = snapshot.avdCards.first(where: { $0.serial == device.serial }) {
            return .avd(card.name)
        }
        return .device(device.serial)
    }

    /// Keeps a valid stage selection: a selected device that is no longer
    /// listed clears the selection (Device Hub shows "No Selection" rather
    /// than jumping to another device), and picks the first running device
    /// when nothing was ever selected (`autoSelect`) — an online adb device,
    /// else a booted simulator — then the first AVD, then the first
    /// simulator. A window whose selection was lost keeps showing none
    /// (`autoSelect` false) until the user picks a device.
    static func ensureTarget(
        for selection: DeviceSelection?,
        in snapshot: Snapshot,
        autoSelect: Bool = true
    ) -> EnsureTarget {
        switch selection {
        case .avd(let name):
            if snapshot.avds.contains(name) { return .keep }
        case .device(let serial):
            if snapshot.devices.contains(where: { $0.serial == serial }) { return .keep }
        case .pixel(let skinName):
            if snapshot.skinCatalog.contains(where: { $0.name == skinName }) { return .keep }
        case .simulator(let udid):
            if snapshot.simulators.contains(where: { $0.udid == udid }) { return .keep }
        case .physicalApple(let udid):
            if snapshot.physicalApple.contains(udid) { return .keep }
        case nil:
            if !autoSelect { return .keep }
        }
        // A stale selection ends in No Selection, not in another device.
        if selection != nil { return .assign(nil) }
        if let running = snapshot.devices.first(where: { $0.isOnline }) {
            return .assign(self.selection(for: running, in: snapshot))
        } else if let booted = snapshot.simulators.first(where: { $0.state == .booted }) {
            return .assign(.simulator(booted.udid))
        } else if let first = snapshot.avdCards.first {
            return .assign(.avd(first.name))
        } else if let first = snapshot.simulators.first {
            return .assign(.simulator(first.udid))
        } else {
            return .assign(nil)
        }
    }

    /// Whether `name` is starting: an in-app start/restart is in flight, or
    /// its emulator process is up while adb has not reported it online yet.
    static func avdIsBooting(_ name: String, in snapshot: Snapshot) -> Bool {
        if snapshot.startingAvdNames.contains(name) { return true }
        guard let card = snapshot.avdCards.first(where: { $0.name == name }), card.isRunning else {
            return false
        }
        guard let serial = card.serial else { return true }
        return snapshot.devices.first(where: { $0.serial == serial })?.isOnline != true
    }

    /// The AVD that Return on a sidebar row starts: a stopped AVD, selected
    /// directly or through its Pixel row. nil for anything running, booting
    /// or not installed (a running device is already live on the stage), and
    /// while the app is busy, like the Start buttons: `startAndMirror` marks
    /// the app busy before its first await but only marks the AVD as
    /// starting after one, so a second Return during a boot would launch the
    /// same AVD twice, or boot another one concurrently.
    static func sidebarStartTarget(
        for selection: DeviceSelection?,
        isBusy: Bool,
        in snapshot: Snapshot
    ) -> String? {
        guard !isBusy else { return nil }
        let avdName: String?
        switch selection {
        case .avd(let name):
            avdName = name
        case .pixel(let skinName):
            avdName = snapshot.avdCards.first(where: { $0.skin?.name == skinName })?.name
        case .device, .simulator, .physicalApple, nil:
            avdName = nil
        }
        guard let avdName,
              let card = snapshot.avdCards.first(where: { $0.name == avdName }),
              !card.isRunning,
              !avdIsBooting(avdName, in: snapshot)
        else {
            return nil
        }
        let isOnline = card.serial.flatMap { serial in
            snapshot.devices.first(where: { $0.serial == serial })?.isOnline
        } ?? false
        return isOnline ? nil : avdName
    }
}
