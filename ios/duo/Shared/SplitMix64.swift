import Foundation

/// SplitMix64 (Steele, Lea and Flood, 2014): tiny, and the same sequence on
/// every platform, so the Mac's tests see the simulator's mountains, and the
/// sky's stars, clouds and ripples are the same on every launch.
struct SplitMix64: Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in 0..<1, from the top 53 bits.
    mutating func unit() -> Double {
        Double(next() >> 11) * 0x1.0p-53
    }
}
