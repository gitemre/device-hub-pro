import DeviceHubProKit

/// Apply to Selected's targets as pure functions over a snapshot of the
/// lists: each multi-selected sidebar row (`SidebarMultiSelection.rows`)
/// resolved, when an action runs, to the device it names and how ready it is
/// (`BatchTarget`). An AVD row is its running emulator, found through its
/// card's serial; a stopped AVD stays a target and is skipped as not running.
/// Pixel catalog rows are not devices and resolve to nothing; nor do physical
/// Apple devices.
enum BatchTargeting {
    /// What the resolution reads: `AppModel`'s `devices`, `avdCards`,
    /// `startingAvdNames` and `deviceInfos`, and the listed simulators with
    /// their run state, at the moment an action runs.
    struct Snapshot: Sendable {
        /// The adb rows, the synthetic ghost included.
        var devices: [AndroidDevice]
        var avdCards: [AvdCard]
        /// The AVDs an in-app start or restart is booting.
        var startingAvdNames: Set<String>
        /// Device Info per serial: the Android version and API level.
        var deviceInfos: [String: DeviceInfo]
        /// The listed simulators (`SimulatorEntry.summary(runState:)`), their
        /// run state from `SimulatorLifecycleController.runState(for:)`.
        var simulators: [DeviceSummary]
        /// Why an unavailable simulator cannot run, by UDID
        /// (`SimulatorEntry.availabilityError`).
        var unavailableReasons: [String: String]

        init(
            devices: [AndroidDevice] = [],
            avdCards: [AvdCard] = [],
            startingAvdNames: Set<String> = [],
            deviceInfos: [String: DeviceInfo] = [:],
            simulators: [DeviceSummary] = [],
            unavailableReasons: [String: String] = [:]
        ) {
            self.devices = devices
            self.avdCards = avdCards
            self.startingAvdNames = startingAvdNames
            self.deviceInfos = deviceInfos
            self.simulators = simulators
            self.unavailableReasons = unavailableReasons
        }
    }

    /// The row's stable key (`BatchTarget.id`): an AVD by name, another adb
    /// device by serial, a simulator by UDID, each under its own prefix so an
    /// AVD and a serial of the same text never meet.
    static func id(for row: DeviceSelection) -> String {
        switch row {
        case .avd(let name): "avd:\(name)"
        case .device(let serial): "device:\(serial)"
        case .pixel(let skinName): "pixel:\(skinName)"
        case .simulator(let udid): "simulator:\(udid)"
        case .physicalApple(let udid): "physicalApple:\(udid)"
        }
    }

    /// The targets of `rows`, in their order; Pixel rows are left out.
    static func targets(for rows: [DeviceSelection], in snapshot: Snapshot) -> [BatchTarget] {
        rows.compactMap { target(for: $0, in: snapshot) }
    }

    /// The rows batch actions never reach: a Pixel catalog row and a
    /// physical Apple device. They are named in the batch's report instead of
    /// vanishing.
    static func excludedRows(in rows: [DeviceSelection]) -> [DeviceSelection] {
        rows.filter {
            switch $0 {
            case .pixel, .physicalApple: true
            case .avd, .device, .simulator: false
            }
        }
    }

    static func target(for row: DeviceSelection, in snapshot: Snapshot) -> BatchTarget? {
        switch row {
        case .avd(let name):
            return avdTarget(name, row: row, in: snapshot)
        case .device(let serial):
            return deviceTarget(serial, row: row, in: snapshot)
        case .simulator(let udid):
            return simulatorTarget(udid, row: row, in: snapshot)
        case .pixel, .physicalApple:
            // Not devices Apply to Selected acts on: a Pixel row is a
            // catalog entry, a physical Apple device is manage-only and
            // never receives a batch.
            return nil
        }
    }

    private static func avdTarget(_ name: String, row: DeviceSelection, in snapshot: Snapshot) -> BatchTarget {
        guard let card = snapshot.avdCards.first(where: { $0.name == name }) else {
            return BatchTarget(
                id: id(for: row), platform: .android, kind: .emulator, ref: nil, name: name,
                osName: "Android", osVersion: nil, readiness: .notListed
            )
        }
        let device = card.serial.flatMap { serial in snapshot.devices.first(where: { $0.serial == serial }) }
        let routing = SelectionRouting.Snapshot(
            devices: snapshot.devices,
            avdCards: snapshot.avdCards,
            startingAvdNames: snapshot.startingAvdNames
        )
        let readiness: BatchReadiness
        if snapshot.startingAvdNames.contains(name) {
            readiness = .starting
        } else if let device, device.isOnline {
            readiness = .ready
        } else if SelectionRouting.avdIsBooting(name, in: routing) {
            readiness = .starting
        } else if let device {
            readiness = androidReadiness(device)
        } else {
            readiness = .stopped
        }
        let info = device.flatMap { snapshot.deviceInfos[$0.serial] }
        return BatchTarget(
            id: id(for: row),
            platform: .android,
            kind: .emulator,
            ref: device.map { DeviceRef.android($0.serial) },
            name: card.displayName,
            osName: "Android",
            osVersion: info?.androidVersion,
            readiness: readiness,
            apiLevel: info.flatMap { Int($0.apiLevel) }
        )
    }

    private static func deviceTarget(_ serial: String, row: DeviceSelection, in snapshot: Snapshot) -> BatchTarget {
        guard let device = snapshot.devices.first(where: { $0.serial == serial }) else {
            return BatchTarget(
                id: id(for: row),
                platform: .android,
                kind: serial.hasPrefix("emulator-") ? .emulator : .physical,
                ref: nil,
                name: serial,
                osName: "Android",
                osVersion: nil,
                readiness: .notListed
            )
        }
        let info = snapshot.deviceInfos[serial]
        return BatchTarget(
            id: id(for: row),
            platform: .android,
            kind: device.isEmulator ? .emulator : .physical,
            ref: .android(serial),
            name: device.displayName,
            osName: "Android",
            osVersion: info?.androidVersion,
            readiness: device.isOnline ? .ready : androidReadiness(device),
            apiLevel: info.flatMap { Int($0.apiLevel) }
        )
    }

    private static func simulatorTarget(_ udid: String, row: DeviceSelection, in snapshot: Snapshot) -> BatchTarget {
        guard let summary = snapshot.simulators.first(where: { $0.ref.id == udid }) else {
            return BatchTarget(
                id: id(for: row), platform: .apple, kind: .simulator, ref: nil, name: udid,
                osName: nil, osVersion: nil, readiness: .notListed
            )
        }
        let readiness: BatchReadiness
        if !summary.isAvailable {
            readiness = .unavailable(snapshot.unavailableReasons[udid] ?? "")
        } else {
            switch summary.runState {
            case .ready: readiness = .ready
            case .booting: readiness = .starting
            case .stopped, .shuttingDown: readiness = .stopped
            case .reconnecting, .unreachable: readiness = .offline
            case .unauthorized: readiness = .unauthorized
            }
        }
        return BatchTarget(
            id: id(for: row),
            platform: .apple,
            kind: .simulator,
            ref: readiness == .stopped ? nil : summary.ref,
            name: summary.name,
            osName: summary.osName,
            osVersion: summary.osVersion,
            readiness: readiness
        )
    }

    /// An adb row that is not online: adb's own state.
    private static func androidReadiness(_ device: AndroidDevice) -> BatchReadiness {
        switch device.state {
        case "device": .ready
        case "offline": .offline
        case "unauthorized": .unauthorized
        default: .unavailable(device.stateLabel)
        }
    }
}
