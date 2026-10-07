import CoreVideo
import IOSurface
import XCTest
@testable import DeviceHubProKit

/// `SimulatorFrameCopier` and `SimulatorFrameRotation` on synthetic
/// in-memory surfaces (pure pixel math, not device output): every native
/// pixel lands where the rotation says, a touch on any displayed pixel maps
/// back to that native pixel, and a copy the simulator writes over is redone
/// once and then counted as torn.
///
/// Which `uiOrientation` value is which rotation is pinned by the live
/// canary (`SimulatorMirrorSessionLiveTests`) and its capture
/// (`Fixtures/ios27-simulator/bridge/orientation-uiOrientation.txt`).
final class SimulatorFrameCopierTests: XCTestCase {
    /// Deliberately not square, so a swapped axis cannot pass.
    static let nativeWidth = 5
    static let nativeHeight = 3

    /// A BGRA surface whose pixels are unique up to 256×256: blue = x, green = y,
    /// red = 0x80, alpha = 0xFF.
    static func makeSurface(width: Int = nativeWidth, height: Int = nativeHeight) throws -> IOSurface {
        let surface = try XCTUnwrap(IOSurface(properties: [
            .width: width,
            .height: height,
            .bytesPerElement: 4,
            .pixelFormat: 0x4247_5241,
        ]))
        surface.lock(options: [], seed: nil)
        let base = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * surface.bytesPerRow + x * 4
                base[offset] = UInt8(truncatingIfNeeded: x)
                base[offset + 1] = UInt8(truncatingIfNeeded: y)
                base[offset + 2] = 0x80
                base[offset + 3] = 0xFF
            }
        }
        surface.unlock(options: [], seed: nil)
        return surface
    }

    /// The (blue, green) pair at a pixel of a BGRA pixel buffer.
    static func marker(_ buffer: CVPixelBuffer, x: Int, y: Int) -> (x: Int, y: Int) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
        return (Int(base[offset]), Int(base[offset + 1]))
    }

    /// PRIVATE-API CoreSimulator 1171.7. `orientation-uiOrientation.txt` is
    /// the capture `SimulatorMirrorSessionLiveTests` writes (with
    /// `DHP_IOS_CAPTURE_DIR`), byte-exact, from an iPhone 17 Pro on iOS
    /// 27.0 (24A434) in a private set with Safari open: for each request the
    /// GSEvent value sent, the `uiOrientation` the screen then reported, the
    /// size of `simctl io screenshot` right after, and the published frame's
    /// size (the pixels matched: mean difference 0.000). The live test is its
    /// canary.
    func testTheCapturedOrientationsPinTheRotations() throws {
        let text = try String(contentsOf: SimctlFixtureTests.url("bridge", "orientation-uiOrientation.txt"), encoding: .utf8)
        let rows = text.split(separator: "\n").dropFirst().map { $0.split(separator: "\t").map(String.init) }
        XCTAssertEqual(rows.count, 4)
        var seen: [String: UInt32] = [:]
        for row in rows {
            let orientation = try XCTUnwrap(SimulatorOrientation(rawValue: row[0]))
            XCTAssertEqual(UInt32(row[1]), orientation.gsEventValue)
            let uiOrientation = try XCTUnwrap(UInt32(row[2]))
            seen[row[0]] = uiOrientation
            let size = SimulatorFrameRotation(uiOrientation: uiOrientation).displaySize(nativeWidth: 1206, nativeHeight: 2622)
            XCTAssertEqual(row[3], "\(size.width)x\(size.height)", "the screenshot is display-oriented")
            XCTAssertEqual(row[4], row[3], "the published frame has the screenshot's size")
        }
        XCTAssertEqual(seen["portrait"], 1)
        XCTAssertEqual(seen["landscapeLeft"], 4, "island on the left: the buffer turns counter-clockwise")
        XCTAssertEqual(seen["landscapeRight"], 3)
        XCTAssertEqual(seen["portraitUpsideDown"], 3, "a Face ID iPhone keeps the last landscape")
    }

    func testUIOrientationValuesPickTheRotation() {
        XCTAssertEqual(SimulatorFrameRotation(uiOrientation: 1), .upright)
        XCTAssertEqual(SimulatorFrameRotation(uiOrientation: 2), .upsideDown)
        XCTAssertEqual(SimulatorFrameRotation(uiOrientation: 3), .clockwise)
        XCTAssertEqual(SimulatorFrameRotation(uiOrientation: 4), .counterClockwise)
        XCTAssertEqual(SimulatorFrameRotation(uiOrientation: 0), .upright, "an unknown value shows the buffer as it is")
        XCTAssertEqual(SimulatorFrameRotation(uiOrientation: 5), .upright)
    }

    /// The corners pin the direction of each turn independently of
    /// `displayPixel`: a quarter clockwise moves the native top-left corner
    /// to the displayed top-right.
    func testCornersMoveTheWayEachTurnDoes() throws {
        let surface = try Self.makeSurface()
        let copier = SimulatorFrameCopier()
        let w = Self.nativeWidth, h = Self.nativeHeight

        let upright = try copier.copy(surface, rotation: .upright).buffer
        XCTAssertTrue(Self.marker(upright, x: 0, y: 0) == (0, 0))

        let half = try copier.copy(surface, rotation: .upsideDown).buffer
        XCTAssertTrue(Self.marker(half, x: w - 1, y: h - 1) == (0, 0), "top-left goes bottom-right")

        let clockwise = try copier.copy(surface, rotation: .clockwise).buffer
        XCTAssertEqual(CVPixelBufferGetWidth(clockwise), h)
        XCTAssertEqual(CVPixelBufferGetHeight(clockwise), w)
        XCTAssertTrue(Self.marker(clockwise, x: h - 1, y: 0) == (0, 0), "top-left goes top-right")
        XCTAssertTrue(Self.marker(clockwise, x: 0, y: 0) == (0, h - 1), "bottom-left goes top-left")

        let counter = try copier.copy(surface, rotation: .counterClockwise).buffer
        XCTAssertTrue(Self.marker(counter, x: 0, y: w - 1) == (0, 0), "top-left goes bottom-left")
        XCTAssertTrue(Self.marker(counter, x: 0, y: 0) == (w - 1, 0), "top-right goes top-left")
    }

    /// Every native pixel lands at `displayPixel`, in every rotation.
    func testEveryPixelLandsWhereTheRotationSays() throws {
        let surface = try Self.makeSurface()
        let copier = SimulatorFrameCopier()
        for rotation in SimulatorFrameRotation.allCases {
            let outcome = try copier.copy(surface, rotation: rotation)
            let size = rotation.displaySize(nativeWidth: Self.nativeWidth, nativeHeight: Self.nativeHeight)
            XCTAssertEqual(CVPixelBufferGetWidth(outcome.buffer), size.width, "\(rotation)")
            XCTAssertEqual(CVPixelBufferGetHeight(outcome.buffer), size.height, "\(rotation)")
            XCTAssertEqual(CVPixelBufferGetPixelFormatType(outcome.buffer), kCVPixelFormatType_32BGRA)
            XCTAssertNotNil(CVPixelBufferGetIOSurface(outcome.buffer), "IOSurface-backed, for the renderer")
            XCTAssertFalse(outcome.retried)
            XCTAssertFalse(outcome.torn)
            for y in 0..<Self.nativeHeight {
                for x in 0..<Self.nativeWidth {
                    let target = rotation.displayPixel(nativeX: x, nativeY: y, nativeWidth: Self.nativeWidth, nativeHeight: Self.nativeHeight)
                    XCTAssertTrue(Self.marker(outcome.buffer, x: target.x, y: target.y) == (x, y), "\(rotation) native (\(x), \(y))")
                }
            }
        }
    }

    /// A click on any displayed pixel reaches the native pixel shown there.
    func testTouchesMapBackToTheNativePixelInEveryRotation() throws {
        let w = Self.nativeWidth, h = Self.nativeHeight
        for rotation in SimulatorFrameRotation.allCases {
            let size = rotation.displaySize(nativeWidth: w, nativeHeight: h)
            for y in 0..<h {
                for x in 0..<w {
                    let shown = rotation.displayPixel(nativeX: x, nativeY: y, nativeWidth: w, nativeHeight: h)
                    let ratio = rotation.nativeRatio(
                        displayX: Double(shown.x), displayY: Double(shown.y),
                        displayWidth: size.width, displayHeight: size.height
                    )
                    XCTAssertEqual(Int(ratio.x * Double(w)), x, "\(rotation) native (\(x), \(y))")
                    XCTAssertEqual(Int(ratio.y * Double(h)), y, "\(rotation) native (\(x), \(y))")
                }
            }
        }
    }

    /// The full-size panel too, at the corners and centre.
    func testRatiosOnTheRealPanelSize() {
        let w = 1206, h = 2622
        for rotation in SimulatorFrameRotation.allCases {
            let size = rotation.displaySize(nativeWidth: w, nativeHeight: h)
            for (x, y) in [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1), (603, 1311)] {
                let shown = rotation.displayPixel(nativeX: x, nativeY: y, nativeWidth: w, nativeHeight: h)
                let ratio = rotation.nativeRatio(
                    displayX: Double(shown.x), displayY: Double(shown.y),
                    displayWidth: size.width, displayHeight: size.height
                )
                XCTAssertTrue((0...1).contains(ratio.x) && (0...1).contains(ratio.y))
                XCTAssertEqual(Int(ratio.x * Double(w)), x, "\(rotation)")
                XCTAssertEqual(Int(ratio.y * Double(h)), y, "\(rotation)")
            }
        }
    }

    /// A point on a displayed edge is on the native edge `nativeEdge` names.
    func testDisplayedEdgesMapToTheNativeEdgeUnderThem() {
        let w = 1206, h = 2622
        for rotation in SimulatorFrameRotation.allCases {
            let size = rotation.displaySize(nativeWidth: w, nativeHeight: h)
            let middles: [(SimulatorTouchEdge, Double, Double)] = [
                (.top, Double(size.width) / 2, 0),
                (.bottom, Double(size.width) / 2, Double(size.height - 1)),
                (.left, 0, Double(size.height) / 2),
                (.right, Double(size.width - 1), Double(size.height) / 2),
            ]
            for (displayEdge, x, y) in middles {
                let ratio = rotation.nativeRatio(displayX: x, displayY: y, displayWidth: size.width, displayHeight: size.height)
                let nativeEdge: SimulatorTouchEdge
                if ratio.y < 0.01 { nativeEdge = .top }
                else if ratio.y > 0.99 { nativeEdge = .bottom }
                else if ratio.x < 0.01 { nativeEdge = .left }
                else { nativeEdge = .right }
                XCTAssertEqual(rotation.nativeEdge(forDisplayEdge: displayEdge), nativeEdge, "\(rotation) \(displayEdge)")
            }
            XCTAssertEqual(rotation.nativeEdge(forDisplayEdge: .none), .none)
        }
        // The landscape case measured live: the displayed bottom of
        // uiOrientation 4 is the panel's left edge.
        XCTAssertEqual(SimulatorFrameRotation.counterClockwise.nativeEdge(forDisplayEdge: .bottom), .left)
    }

    func testDisplayEdgeZone() {
        XCTAssertEqual(SimulatorFrameRotation.displayEdge(x: 600, y: 2610, width: 1206, height: 2622, zone: 24), .bottom)
        XCTAssertEqual(SimulatorFrameRotation.displayEdge(x: 600, y: 3, width: 1206, height: 2622, zone: 24), .top)
        XCTAssertEqual(SimulatorFrameRotation.displayEdge(x: 2, y: 1000, width: 1206, height: 2622, zone: 24), .left)
        XCTAssertEqual(SimulatorFrameRotation.displayEdge(x: 1200, y: 1000, width: 1206, height: 2622, zone: 24), .right)
        XCTAssertEqual(SimulatorFrameRotation.displayEdge(x: 600, y: 1300, width: 1206, height: 2622, zone: 24), .none)
        XCTAssertEqual(SimulatorFrameRotation.displayEdge(x: 1, y: 2620, width: 1206, height: 2622, zone: 24), .bottom, "a corner goes to the nearer edge")
    }

    /// Rows padded differently on each side still copy row by row.
    func testPaddedRowsCopyIntact() throws {
        let surface = try Self.makeSurface(width: 13, height: 7)
        let copier = SimulatorFrameCopier()
        let buffer = try copier.copy(surface, rotation: .upright).buffer
        for y in 0..<7 {
            for x in 0..<13 {
                XCTAssertTrue(Self.marker(buffer, x: x, y: y) == (x, y))
            }
        }
    }

    // MARK: - Seed

    /// Writes to the surface (a write lock bumps its seed), as the simulator
    /// does when it presents a frame mid-copy.
    static func scribble(_ surface: IOSurface) {
        surface.lock(options: [], seed: nil)
        surface.baseAddress.assumingMemoryBound(to: UInt8.self)[3] &+= 1
        surface.unlock(options: [], seed: nil)
    }

    func testAWriteDuringTheFirstCopyIsRetriedOnce() throws {
        let surface = try Self.makeSurface()
        let copier = SimulatorFrameCopier()
        var attempts: [Int] = []
        copier.afterCopyAttempt = { surface, attempt in
            attempts.append(attempt)
            if attempt == 1 { Self.scribble(surface) }
        }
        let outcome = try copier.copy(surface, rotation: .counterClockwise)
        XCTAssertEqual(attempts, [1, 2])
        XCTAssertTrue(outcome.retried)
        XCTAssertFalse(outcome.torn)
    }

    func testWritesDuringBothCopiesCountAsTorn() throws {
        let surface = try Self.makeSurface()
        let copier = SimulatorFrameCopier()
        var attempts: [Int] = []
        copier.afterCopyAttempt = { surface, attempt in
            attempts.append(attempt)
            Self.scribble(surface)
        }
        let outcome = try copier.copy(surface, rotation: .upright)
        XCTAssertEqual(attempts, [1, 2], "one retry, never more")
        XCTAssertTrue(outcome.retried)
        XCTAssertTrue(outcome.torn)
    }

    func testANonBGRASurfaceIsRefused() throws {
        let surface = try XCTUnwrap(IOSurface(properties: [
            .width: 4, .height: 4, .bytesPerElement: 4, .pixelFormat: 0x5247_4241,  // 'RGBA'
        ]))
        XCTAssertThrowsError(try SimulatorFrameCopier().copy(surface, rotation: .upright)) { error in
            XCTAssertEqual(error as? SimulatorFrameCopier.Failure, .unsupportedPixelFormat(0x5247_4241))
        }
    }
}
