import Foundation
import XCTest

/// The day as the hinge draws it (Shared/DayCycle.swift, SkyPalette.swift).
/// The angles are the ones apps read on the iOS 27.1 iPhone Duo simulator at
/// Device Hub Pro's postures: closed 0°, tent 71.1°, laptop 104.2°, book
/// 127.8°, open 180°.
final class DayCycleTests: XCTestCase {
    func testPhasesAtTheDeviceHubProPostures() {
        let phases = [0, 71.1, 104.2, 127.8, 180].map { DayCycle.phase(progress: DayCycle.progress(angleDegrees: $0)) }
        XCTAssertEqual(phases, [.night, .blueHour, .sunrise, .goldenHour, .noon])
    }

    func testPhaseBoundsFallOn45_90_116And155Degrees() {
        func phase(_ degrees: Double) -> DayPhase { DayCycle.phase(progress: DayCycle.progress(angleDegrees: degrees)) }
        XCTAssertEqual(phase(44.9), .night)
        XCTAssertEqual(phase(45), .blueHour)
        XCTAssertEqual(phase(89.9), .blueHour)
        XCTAssertEqual(phase(90), .sunrise)
        XCTAssertEqual(phase(115.9), .sunrise)
        XCTAssertEqual(phase(116), .goldenHour)
        XCTAssertEqual(phase(154.9), .goldenHour)
        XCTAssertEqual(phase(155), .noon)
    }

    func testProgressIsClamped() {
        XCTAssertEqual(DayCycle.progress(angleDegrees: 0), 0)
        XCTAssertEqual(DayCycle.progress(angleDegrees: 90), 0.5)
        XCTAssertEqual(DayCycle.progress(angleDegrees: 180), 1)
        XCTAssertEqual(DayCycle.progress(angleDegrees: -12), 0)
        XCTAssertEqual(DayCycle.progress(angleDegrees: 190), 1)
        XCTAssertEqual(DayCycle.progress(angleDegrees: .nan), 0)
    }

    func testPhaseNamesAndSymbols() {
        XCTAssertEqual(DayPhase.allCases.map(\.title), ["Night", "Blue Hour", "Sunrise", "Golden Hour", "Noon"])
        XCTAssertEqual(
            DayPhase.allCases.map(\.symbolName),
            ["moon.stars.fill", "sun.haze.fill", "sunrise.fill", "sun.horizon.fill", "sun.max.fill"]
        )
    }

    func testPaletteHasNoJumps() {
        for step in 0..<100 {
            let a = Self.channels(DayCycle.palette(progress: Double(step) / 100))
            let b = Self.channels(DayCycle.palette(progress: Double(step + 1) / 100))
            for (x, y) in zip(a, b) {
                XCTAssertLessThanOrEqual(abs(x - y), 0.08, "step \(step)")
                XCTAssertTrue((0...1).contains(y), "step \(step + 1): \(y)")
            }
        }
    }

    func testNightIsDarkAndNoonIsBright() {
        XCTAssertLessThan(DayCycle.palette(progress: 0).zenith.luminance, 0.1)
        XCTAssertGreaterThan(DayCycle.palette(progress: 1).horizon.luminance, 0.6)
    }

    func testPaletteHitsItsKeyframes() {
        let sunrise = DayCycle.palette(progress: 0.58)
        XCTAssertEqual(sunrise.zenith, RGB(hex: 0x2E4F9C))
        XCTAssertEqual(sunrise.horizon, RGB(hex: 0xF4A582))
        XCTAssertEqual(sunrise.sun, RGB(hex: 0xFFB347))
        let noon = DayCycle.palette(progress: 1)
        XCTAssertEqual(noon.glow, RGB(hex: 0xE8F4FF))
        Self.assertClose(noon.ridgeNear, RGB(hex: 0x3E5872))
        XCTAssertEqual(DayCycle.palette(progress: 7), noon)
        XCTAssertEqual(DayCycle.palette(progress: -1), DayCycle.palette(progress: 0))
    }

    /// The ridges and the lake only brighten from night to noon (noon's sky
    /// is a deeper blue than golden hour's, so this needs the noon lift), and
    /// the far ridge stays lighter than the near one, as haze makes it.
    func testRidgesAndLakeBrightenAllDayWithTheFarRidgeLighter() {
        var last = DayCycle.palette(progress: 0)
        for step in 0...100 {
            let palette = DayCycle.palette(progress: Double(step) / 100)
            XCTAssertGreaterThanOrEqual(palette.ridgeFar.luminance, last.ridgeFar.luminance - 1e-12, "step \(step)")
            XCTAssertGreaterThanOrEqual(palette.ridgeNear.luminance, last.ridgeNear.luminance - 1e-12, "step \(step)")
            XCTAssertGreaterThanOrEqual(palette.water.luminance, last.water.luminance - 1e-12, "step \(step)")
            XCTAssertGreaterThan(palette.ridgeFar.luminance, palette.ridgeNear.luminance, "step \(step)")
            last = palette
        }
    }

    func testSunRisesFromHiddenToHigh() {
        XCTAssertLessThan(DayCycle.sunElevation(progress: 0), -0.3)
        XCTAssertEqual(DayCycle.sunElevation(progress: 0.395), -0.12, accuracy: 1e-9)
        XCTAssertLessThan(abs(DayCycle.sunElevation(progress: 0.58)), 0.02)
        XCTAssertEqual(DayCycle.sunElevation(progress: 0.71), 0.22, accuracy: 1e-9)
        XCTAssertGreaterThan(DayCycle.sunElevation(progress: 1), 0.7)
        var last = DayCycle.sunElevation(progress: 0)
        for step in 1...180 {
            let elevation = DayCycle.sunElevation(progress: Double(step) / 180)
            XCTAssertGreaterThanOrEqual(elevation, last - 1e-12, "step \(step)")
            XCTAssertLessThan(elevation - last, 0.02, "step \(step)")
            last = elevation
        }
    }

    func testStarsMoonAndCloudsFollowTheirKeyframes() {
        XCTAssertEqual(DayCycle.starOpacity(progress: 0), 1)
        XCTAssertEqual(DayCycle.starOpacity(progress: 0.22), 0.5, accuracy: 1e-9)
        XCTAssertEqual(DayCycle.starOpacity(progress: 0.395), 0.08, accuracy: 1e-9)
        XCTAssertEqual(DayCycle.starOpacity(progress: 0.5), 0)
        XCTAssertEqual(DayCycle.starOpacity(progress: 0.8), 0)
        XCTAssertEqual(DayCycle.moonOpacity(progress: 0.1), 1, accuracy: 1e-9)
        XCTAssertEqual(DayCycle.moonOpacity(progress: 0.15), 1)
        XCTAssertEqual(DayCycle.moonOpacity(progress: 0.4), 0)
        XCTAssertEqual(DayCycle.moonOpacity(progress: 0.7), 0)
        XCTAssertEqual(DayCycle.cloudOpacity(progress: 0.3), 0)
        XCTAssertEqual(DayCycle.cloudOpacity(progress: 0.5), 0)
        XCTAssertEqual(DayCycle.cloudOpacity(progress: 0.71), 0.35, accuracy: 1e-9)
        XCTAssertEqual(DayCycle.cloudOpacity(progress: 1), 0.8, accuracy: 1e-9)
        for step in 0...100 {
            let progress = Double(step) / 100
            for opacity in [DayCycle.starOpacity, DayCycle.moonOpacity, DayCycle.cloudOpacity].map({ $0(progress) }) {
                XCTAssertTrue((0...1).contains(opacity), "step \(step): \(opacity)")
            }
        }
    }

    func testCreaseGlowsInLaptopAndBookOnly() {
        XCTAssertEqual(DayCycle.creaseGlow(angleDegrees: 0), 0)
        XCTAssertEqual(DayCycle.creaseGlow(angleDegrees: 14.9), 0)
        XCTAssertEqual(DayCycle.creaseGlow(angleDegrees: 180), 0)
        XCTAssertGreaterThanOrEqual(DayCycle.creaseGlow(angleDegrees: 120), 0.9)
        XCTAssertEqual(DayCycle.creaseGlow(angleDegrees: 104.2), 1, accuracy: 1e-9)
        XCTAssertEqual(DayCycle.creaseGlow(angleDegrees: 127.8), 1, accuracy: 1e-9)
        var last = DayCycle.creaseGlow(angleDegrees: 0)
        for degrees in 1...180 {
            let glow = DayCycle.creaseGlow(angleDegrees: Double(degrees))
            XCTAssertTrue((0...1).contains(glow), "\(degrees)°: \(glow)")
            XCTAssertLessThan(abs(glow - last), 0.05, "\(degrees)°")
            last = glow
        }
    }

    /// The cover's veil: none at night, where the white text is the
    /// brightest thing on the panel, and strongest around golden hour.
    func testTextScrimFollowsTheLight() {
        XCTAssertEqual(DayCycle.textScrim(progress: 0), 0)
        XCTAssertEqual(DayCycle.textScrim(progress: 0.2), 0)
        XCTAssertEqual(DayCycle.textScrim(progress: 0.71), 0.4, accuracy: 1e-9)
        var last = DayCycle.textScrim(progress: 0)
        for step in 1...100 {
            let scrim = DayCycle.textScrim(progress: Double(step) / 100)
            XCTAssertTrue((0...0.45).contains(scrim), "step \(step): \(scrim)")
            XCTAssertLessThan(abs(scrim - last), 0.03, "step \(step)")
            last = scrim
        }
    }

    func testRGB() {
        XCTAssertEqual(RGB(hex: 0xFF8000), RGB(r: 1, g: 128.0 / 255, b: 0))
        let black = RGB(hex: 0x000000)
        let white = RGB(hex: 0xFFFFFF)
        XCTAssertEqual(black.mixed(with: white, 0.25), RGB(r: 0.25, g: 0.25, b: 0.25))
        XCTAssertEqual(black.mixed(with: white, -1), black)
        XCTAssertEqual(black.mixed(with: white, 2), white)
        XCTAssertEqual(white.luminance, 1, accuracy: 1e-12)
        XCTAssertEqual(black.luminance, 0)
        XCTAssertGreaterThan(RGB(hex: 0x00FF00).luminance, RGB(hex: 0xFF0000).luminance)
    }

    private static func assertClose(_ a: RGB, _ b: RGB, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.r, b.r, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(a.g, b.g, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(a.b, b.b, accuracy: 1e-9, file: file, line: line)
    }

    private static func channels(_ palette: SkyPalette) -> [Double] {
        [palette.zenith, palette.upper, palette.horizon, palette.glow,
         palette.ridgeFar, palette.ridgeNear, palette.water, palette.sun].flatMap { [$0.r, $0.g, $0.b] }
    }
}
