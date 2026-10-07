import Foundation
import GRPCCore
import GRPCProtobuf

/// Emulator-only controls exposed through the gRPC channel: battery, location,
/// foldable posture and hinge angle, and display configuration.
public enum EmulatorControls {
    // MARK: - Read

    public static func state(port: Int) async -> DeviceControlsState {
        // Six independent reads; overlapping them keeps the panel's refresh
        // (and every poll) to a single round trip, multiplexed on the port's
        // shared connection.
        async let displays = displays(port: port)
        async let battery = battery(port: port)
        async let location = location(port: port)
        async let posture = posture(port: port)
        async let hingeAngle = hingeAngle(port: port)
        async let isBooted = booted(port: port)

        var state = DeviceControlsState()
        state.displays = await displays
        state.battery = await battery
        state.location = await location
        state.posture = await posture
        state.hingeAngle = await hingeAngle
        state.isBooted = await isBooted
        return state
    }

    /// Closes the shared control connection to `port` (every control call
    /// shares one per emulator). Call it when the emulator goes away; an idle
    /// connection also closes by itself after a few seconds, and the next
    /// call reconnects either way.
    public static func closeConnections(port: Int) async {
        await EmulatorControl.closeSharedConnection(port: port)
    }

    public static func booted(port: Int) async -> Bool? {
        (try? await EmulatorControl.withSharedClient(port: port, retryOnStaleConnection: true) { controller in
            let status: Android_Emulation_Control_EmulatorStatus = try await controller.getStatus(
                .init(),
                options: .controls
            )
            return status.booted
        }) ?? nil
    }

    /// The emulator's battery, or nil for an AVD without one (`hw.battery=no`:
    /// TV, Automotive and desktop images), whose Battery rows then stay hidden.
    public static func battery(port: Int) async -> BatteryInfo? {
        (try? await EmulatorControl.withSharedClient(port: port, retryOnStaleConnection: true) { controller -> BatteryInfo? in
            let battery: Android_Emulation_Control_BatteryState = try await controller.getBattery(
                .init(),
                options: .controls
            )
            guard battery.hasBattery_p else { return nil }
            let charging = battery.status == .charging || battery.status == .full
            return BatteryInfo(
                level: Int(battery.chargeLevel),
                isCharging: charging,
                chargerName: battery.charger.name,
                statusName: battery.status.name
            )
        }) ?? nil
    }

    public static func location(port: Int) async -> GpsFix? {
        try? await EmulatorControl.withSharedClient(port: port, retryOnStaleConnection: true) { controller in
            let gps: Android_Emulation_Control_GpsState = try await controller.getGps(
                .init(),
                options: .controls
            )
            return GpsFix(latitude: gps.latitude, longitude: gps.longitude)
        }
    }

    public static func posture(port: Int) async -> PostureKind? {
        try? await EmulatorControl.withSharedClient(port: port, retryOnStaleConnection: true) { controller in
            let model: Android_Emulation_Control_PhysicalModelValue = try await controller.getPhysicalModel(
                .with { $0.target = .posture },
                options: .controls
            )
            guard model.status == .ok, let value = model.value.data.first else { return nil }
            return PostureKind.from(protobufValue: Int32(value))
        } ?? nil
    }

    public static func hingeAngle(port: Int) async -> Double? {
        try? await EmulatorControl.withSharedClient(port: port, retryOnStaleConnection: true) { controller in
            let model: Android_Emulation_Control_PhysicalModelValue = try await controller.getPhysicalModel(
                .with { $0.target = .hingeAngle0 },
                options: .controls
            )
            guard model.status == .ok, let value = model.value.data.first else { return nil }
            return Double(value)
        } ?? nil
    }

    /// The physical device rotation about the vertical axis, in degrees. This
    /// is the pose Device Manager's rotate buttons change; the stream follows
    /// it directly, so rotating works in every posture and on every panel.
    public static func rotation(port: Int) async -> Float? {
        try? await EmulatorControl.withSharedClient(port: port, retryOnStaleConnection: true) { controller in
            let model: Android_Emulation_Control_PhysicalModelValue = try await controller.getPhysicalModel(
                .with { $0.target = .rotation },
                options: .controls
            )
            guard model.status == .ok, model.value.data.count >= 3 else { return nil }
            return model.value.data[2]
        } ?? nil
    }

    /// Adds `delta` degrees to the pose's vertical rotation, preserving any
    /// tilt on the other axes. Never retried on a stale connection: a rerun
    /// after the write landed would rotate twice.
    @discardableResult
    public static func rotate(port: Int, delta: Float) async -> Bool {
        let success = try? await EmulatorControl.withSharedClient(port: port) { controller in
            let model: Android_Emulation_Control_PhysicalModelValue = try await controller.getPhysicalModel(
                .with { $0.target = .rotation },
                options: .controls
            )
            guard model.status == .ok, model.value.data.count >= 3 else { return false }
            var values = model.value.data
            values[2] += delta
            _ = try await controller.setPhysicalModel(
                .with {
                    $0.target = .rotation
                    $0.value.data = values
                },
                options: .controls
            )
            return true
        }
        return success ?? false
    }

    /// The emulator clipboard. While a keyboard paste borrows it (non-ASCII
    /// typing, `KeyboardCommand.text`) this is the clipboard the paste will
    /// put back — the user's — not the characters being typed.
    public static func clipboard(port: Int) async -> String? {
        if let original = BorrowedClipboards.shared.original(port: port) {
            return original
        }
        let text = try? await EmulatorControl.withSharedClient(port: port, retryOnStaleConnection: true) { controller in
            let clip: Android_Emulation_Control_ClipData = try await controller.getClipboard(
                .init(),
                options: .controls
            )
            return clip.text
        }
        // A paste that started during the read may have been what it saw.
        return BorrowedClipboards.shared.original(port: port) ?? text
    }

    public static func displays(port: Int) async -> [DisplayInfo] {
        (try? await EmulatorControl.withSharedClient(port: port, retryOnStaleConnection: true) { controller in
            let configurations: Android_Emulation_Control_DisplayConfigurations =
                try await controller.getDisplayConfigurations(.init(), options: .controls)
            return configurations.displays.map {
                DisplayInfo(
                    id: $0.display,
                    width: Int($0.width),
                    height: Int($0.height),
                    dpi: Int($0.dpi)
                )
            }
        }) ?? []
    }

    // MARK: - Write

    /// Sets the battery level and plugs or unplugs the charger, keeping the
    /// rest of the emulator's battery state (charger kind, health, presence):
    /// the level slider must not reset a simulated health state or move an AC
    /// charger to USB. Returns false for an emulator without a battery, which
    /// is left untouched rather than handed a fake one. The result depends
    /// only on the arguments, so a rerun on a fresh connection is safe.
    @discardableResult
    public static func setBattery(port: Int, level: Int, charging: Bool) async -> Bool {
        let success = try? await EmulatorControl.withSharedClient(port: port, retryOnStaleConnection: true) { controller in
            let current: Android_Emulation_Control_BatteryState = try await controller.getBattery(
                .init(),
                options: .controls
            )
            guard let next = BatteryUpdate.state(from: current, level: level, charging: charging) else {
                return false
            }
            _ = try await controller.setBattery(next, options: .controls)
            return true
        }
        return success ?? false
    }

    @discardableResult
    public static func setLocation(port: Int, latitude: Double, longitude: Double) async -> Bool {
        await setLocation(port: port, sample: GpsSample(latitude: latitude, longitude: longitude))
    }

    /// One GPS fix with the speed over the ground and the bearing of travel,
    /// what a route player sends every second.
    @discardableResult
    public static func setLocation(port: Int, sample: GpsSample) async -> Bool {
        let success = try? await EmulatorControl.withSharedClient(port: port, retryOnStaleConnection: true) { controller in
            _ = try await controller.setGps(
                .with {
                    $0.latitude = sample.latitude
                    $0.longitude = sample.longitude
                    $0.speed = sample.speed
                    $0.bearing = sample.bearing
                    $0.passiveUpdate = false
                },
                options: .controls
            )
            return true
        }
        return success ?? false
    }

    /// Sets the emulator clipboard. While a keyboard paste borrows it, the
    /// text becomes what the paste puts back instead: writing now would
    /// replace the text being pasted, and the restore would then undo this
    /// write.
    @discardableResult
    public static func setClipboard(port: Int, text: String) async -> Bool {
        if BorrowedClipboards.shared.replaceOriginal(port: port, with: text) {
            return true
        }
        let success = try? await EmulatorControl.withSharedClient(port: port, retryOnStaleConnection: true) { controller in
            _ = try await controller.setClipboard(
                .with { $0.text = text },
                options: .controls
            )
            return true
        }
        guard success == true else { return false }
        // A paste that started during the write would put back what it read
        // before this text landed.
        _ = BorrowedClipboards.shared.replaceOriginal(port: port, with: text)
        return true
    }

    @discardableResult
    public static func setPosture(port: Int, posture: PostureKind) async -> Bool {
        let success = try? await EmulatorControl.withSharedClient(port: port, retryOnStaleConnection: true) { controller in
            _ = try await controller.setPosture(
                .with { $0.value = posture.protobufRawValue },
                options: .controls
            )
            return true
        }
        return success ?? false
    }

    @discardableResult
    public static func setHingeAngle(port: Int, degrees: Double) async -> Bool {
        let success = try? await EmulatorControl.withSharedClient(port: port, retryOnStaleConnection: true) { controller in
            _ = try await controller.setPhysicalModel(
                .with {
                    $0.target = .hingeAngle0
                    $0.value.data = [Float(degrees)]
                },
                options: .controls
            )
            return true
        }
        return success ?? false
    }
}

/// The battery state a level/charger change sends: the emulator's current
/// state with only those fields changed.
enum BatteryUpdate {
    /// nil when the emulator has no battery (`hw.battery=no`).
    static func state(
        from current: Android_Emulation_Control_BatteryState,
        level: Int,
        charging: Bool
    ) -> Android_Emulation_Control_BatteryState? {
        guard current.hasBattery_p else { return nil }
        var next = current
        next.chargeLevel = Int32(max(0, min(100, level)))

        let wasCharging = current.status == .charging || current.status == .full
        if charging {
            // Keep an AC/USB/wireless charger as it is; plugging in from none
            // uses AC, the emulator's own default charger.
            if current.charger == .none {
                next.charger = .ac
            }
            if !wasCharging || (current.status == .full && next.chargeLevel < 100) {
                next.status = .charging
            }
        } else {
            next.charger = .none
            next.status = .discharging
        }
        return next
    }
}

extension PostureKind {
    /// The generated enum value for `Posture.PostureValue`.
    var protobufRawValue: Android_Emulation_Control_Posture.PostureValue {
        switch self {
        case .closed: return .postureClosed
        case .halfOpened: return .postureHalfOpened
        case .opened: return .postureOpened
        }
    }
}

extension CallOptions {
    /// Short timeout for control RPCs so the UI never hangs.
    static var controls: CallOptions {
        var options = CallOptions.defaults
        options.timeout = .seconds(4)
        return options
    }
}

private extension Android_Emulation_Control_BatteryState.BatteryCharger {
    var name: String {
        switch self {
        case .none: return "None"
        case .ac: return "AC"
        case .usb: return "USB"
        case .wireless: return "Wireless"
        default: return "Unknown"
        }
    }
}

private extension Android_Emulation_Control_BatteryState.BatteryStatus {
    var name: String {
        switch self {
        case .unknown: return "Unknown"
        case .charging: return "Charging"
        case .discharging: return "Discharging"
        case .notCharging: return "Not charging"
        case .full: return "Full"
        default: return "Unknown"
        }
    }
}
