import Foundation
import GRPCCore
import GRPCProtobuf

// MARK: - Sensors

/// The device sensors that can be read and spoofed through the emulator.
public enum SensorKind: String, CaseIterable, Identifiable, Sendable {
    case acceleration
    case gyroscope
    case magneticField
    case orientation
    case temperature
    case proximity
    case light
    case pressure
    case humidity
    case heartRate

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .acceleration: return "Acceleration"
        case .gyroscope: return "Gyroscope"
        case .magneticField: return "Magnetic field"
        case .orientation: return "Orientation"
        case .temperature: return "Temperature"
        case .proximity: return "Proximity"
        case .light: return "Light"
        case .pressure: return "Pressure"
        case .humidity: return "Humidity"
        case .heartRate: return "Heart rate"
        }
    }

    public var unit: String {
        switch self {
        case .acceleration: return "m/s²"
        case .gyroscope: return "rad/s"
        case .magneticField: return "μT"
        case .orientation: return "°"
        case .temperature: return "°C"
        case .proximity: return "cm"
        case .light: return "lx"
        case .pressure: return "hPa"
        case .humidity: return "%"
        case .heartRate: return "bpm"
        }
    }

    public var axisLabels: [String] {
        switch self {
        case .acceleration, .gyroscope, .magneticField:
            return ["x", "y", "z"]
        case .orientation:
            return ["azimuth", "pitch", "roll"]
        default:
            return ["value"]
        }
    }

    var protobufValue: Android_Emulation_Control_SensorValue.SensorType {
        switch self {
        case .acceleration: return .acceleration
        case .gyroscope: return .gyroscope
        case .magneticField: return .magneticField
        case .orientation: return .orientation
        case .temperature: return .temperature
        case .proximity: return .proximity
        case .light: return .light
        case .pressure: return .pressure
        case .humidity: return .humidity
        case .heartRate: return .heartRate
        }
    }
}

public enum EmulatorSensors {
    public static func reading(port: Int, kind: SensorKind) async -> [Float]? {
        try? await EmulatorControl.withSharedClient(port: port, retryOnStaleConnection: true) { controller in
            let value: Android_Emulation_Control_SensorValue = try await controller.getSensor(
                .with { $0.target = kind.protobufValue },
                options: .controls
            )
            guard value.status == .ok else { return nil }
            return Array(value.value.data)
        }
    }

    @discardableResult
    public static func set(port: Int, kind: SensorKind, values: [Float]) async -> Bool {
        let success = try? await EmulatorControl.withSharedClient(port: port, retryOnStaleConnection: true) { controller in
            _ = try await controller.setSensor(
                .with {
                    $0.target = kind.protobufValue
                    $0.value.data = values
                },
                options: .controls
            )
            return true
        }
        return success ?? false
    }
}

// MARK: - Telephony

public enum EmulatorTelephony {
    /// Simulates an incoming call from `number`.
    @discardableResult
    public static func placeCall(port: Int, number: String) async -> Bool {
        await phone(port: port, operation: .initCall, number: number)
    }

    @discardableResult
    public static func sendSMS(port: Int, from address: String, text: String) async -> Bool {
        let success = try? await EmulatorControl.withSharedClient(port: port) { controller in
            let response: Android_Emulation_Control_PhoneResponse = try await controller.sendSms(
                .with {
                    $0.srcAddress = address
                    $0.text = text
                },
                options: .controls
            )
            return response.response == .ok
        }
        return success ?? false
    }

    @discardableResult
    public static func setPhoneNumber(port: Int, number: String) async -> Bool {
        let success = try? await EmulatorControl.withSharedClient(port: port, retryOnStaleConnection: true) { controller in
            let response: Android_Emulation_Control_PhoneResponse = try await controller.setPhoneNumber(
                .with { $0.number = number },
                options: .controls
            )
            return response.response == .ok
        }
        return success ?? false
    }

    private static func phone(
        port: Int,
        operation: Android_Emulation_Control_PhoneCall.Operation,
        number: String
    ) async -> Bool {
        let success = try? await EmulatorControl.withSharedClient(port: port) { controller in
            let response: Android_Emulation_Control_PhoneResponse = try await controller.sendPhone(
                .with {
                    $0.operation = operation
                    $0.number = number
                },
                options: .controls
            )
            return response.response == .ok
        }
        return success ?? false
    }
}

// MARK: - Brightness, VM state, fingerprint

public enum EmulatorDeviceControls {
    public static func brightness(port: Int) async -> UInt32? {
        try? await EmulatorControl.withSharedClient(port: port, retryOnStaleConnection: true) { controller in
            let value: Android_Emulation_Control_BrightnessValue = try await controller.getBrightness(
                .with { $0.target = .lcd },
                options: .controls
            )
            return value.value
        }
    }

    @discardableResult
    public static func setBrightness(port: Int, value: UInt32) async -> Bool {
        let success = try? await EmulatorControl.withSharedClient(port: port, retryOnStaleConnection: true) { controller in
            _ = try await controller.setBrightness(
                .with {
                    $0.target = .lcd
                    $0.value = min(255, value)
                },
                options: .controls
            )
            return true
        }
        return success ?? false
    }

    /// Pauses or resumes the guest without shutting it down.
    @discardableResult
    public static func setRunning(port: Int, _ running: Bool) async -> Bool {
        let success = try? await EmulatorControl.withSharedClient(port: port, retryOnStaleConnection: true) { controller in
            _ = try await controller.setVmState(
                .with { $0.state = running ? .running : .paused },
                options: .controls
            )
            return true
        }
        return success ?? false
    }

    @discardableResult
    public static func sendFingerprint(port: Int, touching: Bool, touchId: Int32) async -> Bool {
        let success = try? await EmulatorControl.withSharedClient(port: port) { controller in
            _ = try await controller.sendFingerprint(
                .with {
                    $0.isTouching = touching
                    $0.touchID = touchId
                },
                options: .controls
            )
            return true
        }
        return success ?? false
    }
}
