import Foundation

/// Deterministic ridge heights for the mountains (0...1), `count` samples, from a seed (`SplitMix64`).
enum Ridge {
    /// The grid each range is drawn on before `count` samples are read from
    /// it, so a seed draws the same range at any count up to 1025: a wider
    /// window shows the same mountains in more detail, not other mountains.
    private static let gridSegments = 1024

    /// Midpoint displacement: each level splits every segment and moves its
    /// midpoint at random, by `roughness` (0...1) of the coarser level's
    /// amount; about 0.5 draws rolling hills, 0.7 jagged peaks. Normalised
    /// over the whole grid, so the lowest point is 0 and the highest 1.
    static func heights(seed: UInt64, count: Int, roughness: Double) -> [Double] {
        guard count > 0 else { return [] }
        let roughness = roughness.isNaN ? 0.5 : min(max(roughness, 0), 1)
        var segments = gridSegments
        while segments < count - 1 { segments *= 2 }

        var random = SplitMix64(seed: seed)
        var grid = [Double](repeating: 0, count: segments + 1)
        grid[0] = random.unit()
        grid[segments] = random.unit()
        var step = segments
        var amplitude = 1.0
        while step > 1 {
            let half = step / 2
            for start in stride(from: 0, to: segments, by: step) {
                let middle = (grid[start] + grid[start + step]) / 2
                grid[start + half] = middle + (random.unit() - 0.5) * amplitude
            }
            amplitude *= roughness
            step = half
        }

        var low = grid[0]
        var high = grid[0]
        for value in grid {
            low = min(low, value)
            high = max(high, value)
        }
        let span = high - low
        return (0..<count).map { index in
            let position = count == 1 ? Double(segments) / 2 : Double(index) * Double(segments) / Double(count - 1)
            let cell = Int(position)
            let value = cell >= segments
                ? grid[segments]
                : grid[cell] + (grid[cell + 1] - grid[cell]) * (position - Double(cell))
            return span > 0 ? min(max((value - low) / span, 0), 1) : 0.5
        }
    }
}
