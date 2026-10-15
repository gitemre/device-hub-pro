import Foundation
import XCTest

/// The mountains (Shared/Ridge.swift): the same seed always draws the same
/// range, inside 0...1, whatever the count asks for.
final class RidgeTests: XCTestCase {
    func testDeterministicAndInRange() {
        let a = Ridge.heights(seed: 42, count: 200, roughness: 0.55)
        XCTAssertEqual(a, Ridge.heights(seed: 42, count: 200, roughness: 0.55))
        XCTAssertNotEqual(a, Ridge.heights(seed: 43, count: 200, roughness: 0.55))
        XCTAssertEqual(a.count, 200)
        XCTAssertTrue(a.allSatisfy { (0...1).contains($0) })
    }

    func testTheWholeGridSpansZeroToOne() {
        let grid = Ridge.heights(seed: 7, count: 1025, roughness: 0.6)
        XCTAssertEqual(grid.min(), 0)
        XCTAssertEqual(grid.max(), 1)
    }

    /// A wider window reads more samples of the same range.
    func testTheRangeIsTheSameAtAnyCount() {
        let fine = Ridge.heights(seed: 7, count: 1025, roughness: 0.6)
        let coarse = Ridge.heights(seed: 7, count: 257, roughness: 0.6)
        for (index, height) in coarse.enumerated() {
            XCTAssertEqual(height, fine[index * 4], "sample \(index)")
        }
    }

    func testRoughnessMakesItJaggeder() {
        func travel(_ heights: [Double]) -> Double {
            zip(heights, heights.dropFirst()).reduce(0) { $0 + abs($1.1 - $1.0) }
        }
        XCTAssertGreaterThan(
            travel(Ridge.heights(seed: 3, count: 257, roughness: 0.75)),
            travel(Ridge.heights(seed: 3, count: 257, roughness: 0.35))
        )
        XCTAssertEqual(Ridge.heights(seed: 3, count: 50, roughness: 4), Ridge.heights(seed: 3, count: 50, roughness: 1))
    }

    func testDegenerateCounts() {
        XCTAssertEqual(Ridge.heights(seed: 1, count: 0, roughness: 0.5), [])
        XCTAssertEqual(Ridge.heights(seed: 1, count: -3, roughness: 0.5), [])
        let one = Ridge.heights(seed: 1, count: 1, roughness: 0.5)
        XCTAssertEqual(one.count, 1)
        XCTAssertTrue((0...1).contains(one[0]))
        XCTAssertEqual(Ridge.heights(seed: 1, count: 2050, roughness: 0.5).count, 2050)
    }
}

/// The generator behind the mountains and the sky's stars, clouds and
/// ripples (Shared/SplitMix64.swift).
final class SplitMix64Tests: XCTestCase {
    /// The first outputs for seed 0 in the reference implementation
    /// (Vigna's splitmix64.c).
    func testMatchesTheReferenceSequence() {
        var random = SplitMix64(seed: 0)
        XCTAssertEqual(random.next(), 0xE220_A839_7B1D_CDAF)
        XCTAssertEqual(random.next(), 0x6E78_9E6A_A1B9_65F4)
        XCTAssertEqual(random.next(), 0x06C4_5D18_8009_454F)
    }

    func testUnitIsInRange() {
        var random = SplitMix64(seed: 0x0DA7_B4EA_C057_A125)
        for _ in 0..<1000 {
            XCTAssertTrue((0..<1).contains(random.unit()))
        }
    }
}
