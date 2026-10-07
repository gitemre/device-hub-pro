import Foundation

/// The accelerometer sequence that makes an emulator "shake": a few hard
/// jolts along the x axis, alternating in sign, then the resting reading
/// back. An app that listens for a shake (a threshold on the acceleration
/// magnitude, usually about 2.5 g) sees the spikes; the emulator has no
/// shake command of its own, so the sensor is driven the way Android
/// Studio's virtual sensors do it.
enum ShakeMotion {
    /// m/s² added to the resting x reading at each jolt (about 3 g).
    static let amplitude: Float = 30
    /// Number of jolts (an even count ends the swing on the opposite side).
    static let jolts = 6
    /// Pause between two readings, in milliseconds.
    static let intervalMilliseconds = 70
    /// What a rest reading falls back to when none could be read: gravity on
    /// the y axis, the emulator's upright default.
    static let defaultRest: [Float] = [0, 9.81, 0]

    /// The readings to write, in order, ending with `rest`. `rest` is the
    /// reading to restore (three components; anything else uses
    /// `defaultRest`).
    static func samples(rest: [Float]?) -> [[Float]] {
        let rest = (rest?.count == 3) ? rest! : defaultRest
        var result: [[Float]] = []
        for index in 0..<jolts {
            let sign: Float = index.isMultiple(of: 2) ? 1 : -1
            result.append([rest[0] + sign * amplitude, rest[1], rest[2]])
        }
        result.append(rest)
        return result
    }
}
