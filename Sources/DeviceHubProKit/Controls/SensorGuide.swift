import Foundation

// MARK: - Ranges

/// One sensor's official range and step, per axis.
///
/// SOURCE-DERIVED: the emulator's sensor HAL, AOSP
/// `device/generic/goldfish`, file `hals/sensors/sensor_list.cpp`, branch
/// `main` (fetched 2026-10-05; the file is kept as
/// `Tests/DeviceHubProKitTests/Fixtures/goldfish-sensors/sensor_list.cpp`).
/// `maxRange` and `resolution` are the file's values for the sensor's
/// `SensorInfo`. The file gives only a maximum: signed quantities
/// (acceleration, rotation rate, magnetic field) span `-maxRange...maxRange`,
/// unsigned ones (orientation, proximity, light, pressure, humidity, heart
/// rate) `0...maxRange`. Ambient temperature is the one Device Hub Pro choice: the
/// file says 80 and nothing about the low end, so it spans `-40...80`.
public struct SensorRange: Equatable, Sendable {
    public let minimum: Float
    public let maximum: Float
    /// The HAL's resolution (the smallest step it reports).
    public let resolution: Float

    public init(minimum: Float, maximum: Float, resolution: Float) {
        self.minimum = minimum
        self.maximum = maximum
        self.resolution = resolution
    }

    /// `value` pulled into the range.
    public func clamp(_ value: Float) -> Float {
        min(max(value, minimum), maximum)
    }

    /// "0 – 40 000 lux" / "-39.3 – 39.3 m/s²": the range shown beside a field.
    public func caption(unit: String) -> String {
        "\(Self.format(minimum)) – \(Self.format(maximum)) \(unit)"
    }

    static func format(_ value: Float) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = "\u{202F}"
        formatter.usesGroupingSeparator = true
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

/// A one-click value set for a sensor, applied at once.
public struct SensorPreset: Equatable, Identifiable, Sendable {
    public let title: String
    public let values: [Float]
    public var id: String { title }
}

// MARK: - Guide

extension SensorKind {
    /// The official range of every axis of this sensor (one range for all
    /// the axes of a 3-axis sensor).
    public var range: SensorRange {
        switch self {
        case .acceleration: return SensorRange(minimum: -39.3, maximum: 39.3, resolution: 1.0 / 4032.0)
        case .gyroscope: return SensorRange(minimum: -16.46, maximum: 16.46, resolution: 1.0 / 1000.0)
        case .magneticField: return SensorRange(minimum: -2000, maximum: 2000, resolution: 0.5)
        case .orientation: return SensorRange(minimum: 0, maximum: 360, resolution: 1)
        case .temperature: return SensorRange(minimum: -40, maximum: 80, resolution: 1)
        case .proximity: return SensorRange(minimum: 0, maximum: 1, resolution: 1)
        case .light: return SensorRange(minimum: 0, maximum: 40_000, resolution: 1)
        case .pressure: return SensorRange(minimum: 0, maximum: 800, resolution: 1)
        case .humidity: return SensorRange(minimum: 0, maximum: 100, resolution: 1)
        case .heartRate: return SensorRange(minimum: 0, maximum: 500, resolution: 1)
        }
    }

    /// What testing this sensor is good for, in one line.
    public var guideDescription: String {
        switch self {
        case .acceleration: return "Device posture, tilt controls, step counting, shake."
        case .gyroscope: return "Rotation rate: games, camera stabilisation, motion-driven UI."
        case .magneticField: return "Compass and heading, together with the orientation."
        case .orientation: return "The compass heading and the device's attitude in space."
        case .temperature: return "Weather and thermal-aware features reading the ambient temperature."
        case .proximity: return "Screen turning off when the phone is held to the ear."
        case .light: return "Auto-brightness and light/dark switching."
        case .pressure: return "Altitude and weather features that read the air pressure."
        case .humidity: return "Weather and comfort features that read the relative humidity."
        case .heartRate: return "Fitness and health features that read the heart rate."
        }
    }

    /// A caption under the presets, for the sensors with a caveat.
    public var presetCaption: String? {
        switch self {
        case .pressure:
            return "The emulator caps pressure at 800 hPa, below sea level (about 1013 hPa)."
        case .proximity:
            return "Near is 0 cm, far is 1 cm: the emulator's sensor reports only those two."
        case .magneticField:
            return "Earth's field at a mid latitude (about 50 μT, 60° dip), phone flat, top edge toward the direction."
        case .orientation:
            return "Azimuth, with the phone flat (pitch and roll 0)."
        default:
            return nil
        }
    }

    /// The one-click presets, in the order shown.
    ///
    /// Gravity presets use Android's device frame (x right, y up the screen,
    /// z out of the screen): the sensor reads the reaction to gravity, so a
    /// phone flat on its back reads +9.81 on z. The magnetic vectors are one
    /// horizontal component of 25 μT and a vertical one of -43.3 μT (down,
    /// about 50 μT in all at a 60° dip); the phone lies flat with its top
    /// edge (+y) toward the named direction, so for East the field points
    /// to -x: North (0, 25), East (-25, 0), South (0, -25), West (25, 0).
    /// Orientation is azimuth, pitch, roll: 0, 90, 180 and 270 degrees for
    /// North, East, South and West (Android's `SENSOR_TYPE_ORIENTATION`).
    public var presets: [SensorPreset] {
        func p(_ title: String, _ values: Float...) -> SensorPreset { SensorPreset(title: title, values: values) }
        switch self {
        case .acceleration:
            return [
                p("Flat on a table", 0, 0, 9.81),
                p("Held upright", 0, 9.81, 0),
                p("Landscape left", 9.81, 0, 0),
                p("Landscape right", -9.81, 0, 0),
                p("Face down", 0, 0, -9.81),
                p("Free fall", 0, 0, 0),
            ]
        case .gyroscope:
            return [p("Still", 0, 0, 0)]
        case .magneticField:
            return [
                p("North", 0, 25, -43.3),
                p("East", -25, 0, -43.3),
                p("South", 0, -25, -43.3),
                p("West", 25, 0, -43.3),
            ]
        case .orientation:
            return [
                p("North", 0, 0, 0),
                p("East", 90, 0, 0),
                p("South", 180, 0, 0),
                p("West", 270, 0, 0),
            ]
        case .temperature:
            return [p("Cold", 0), p("Room", 22), p("Hot", 40)]
        case .proximity:
            return [p("Near", 0), p("Far", 1)]
        case .light:
            return [p("Dark room", 10), p("Office", 400), p("Daylight", 10_000), p("Direct sun", 40_000)]
        case .pressure:
            return [p("High altitude", 700), p("Maximum", 800)]
        case .humidity:
            return [p("Dry", 20), p("Normal", 50), p("Humid", 90)]
        case .heartRate:
            return [p("Resting", 60), p("Walking", 100), p("Running", 150)]
        }
    }

    /// `values` with every axis pulled into the official range.
    public func clamped(_ values: [Float]) -> [Float] {
        values.map(range.clamp)
    }
}
