import CryptoKit
import XCTest
@testable import DeviceHubProKit

/// `AppleDeviceModel`: finding a device's 3D model in an Xcode, checking it
/// against the pinned files, and the fold's animation times.
///
/// Apple's model is never copied into the repository: the lookup runs on a
/// temporary Xcode layout holding a stand-in file whose digest the test pins
/// itself. The real file's numbers (`known`) were measured on Xcode 27.1 RC
/// (27A9275); `AppleDeviceModelLiveTests` loads the installed file when the
/// Mac has it.
final class AppleDeviceModelTests: XCTestCase {
    private func makeXcode(model: Data?, productClass: String = "V68", plugIn: String = "Fold.devicekitplugin") throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppleDeviceModelTests-\(UUID().uuidString)/Xcode.app/Contents", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root.deletingLastPathComponent().deletingLastPathComponent()) }
        let developer = root.appendingPathComponent("Developer", isDirectory: true)
        try FileManager.default.createDirectory(at: developer, withIntermediateDirectories: true)
        let resources = root.appendingPathComponent(
            "SharedFrameworks/DeviceKit.framework/Versions/A/PlugIns/\(plugIn)/Contents/Resources", isDirectory: true
        )
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        if let model { try model.write(to: resources.appendingPathComponent("\(productClass).usdz")) }
        return developer
    }

    private static func spec(for data: Data, productClass: String = "V68") -> AppleDeviceModel.Spec {
        AppleDeviceModel.Spec(
            productClass: productClass,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            duration: 20, openTime: 10, closedTime: 15
        )
    }

    func testAKnownFileIsFound() throws {
        let data = Data("stand-in model".utf8)
        let developer = try makeXcode(model: data)
        let model = try XCTUnwrap(AppleDeviceModel.locate(
            productClass: "V68", developerDir: developer, environment: [:], known: [Self.spec(for: data)]
        ))
        XCTAssertEqual(model.url.lastPathComponent, "V68.usdz")
        XCTAssertEqual(model.spec.openTime, 10)
        XCTAssertTrue(model.isChecked)
        XCTAssertTrue(model.fits(animationDuration: 30), "a checked file is shown whatever its length")
    }

    /// Another build's file (a later Xcode) is found unchecked, on the
    /// numbers of the known file of its product class, and is shown only if
    /// its animation runs as long as that file's.
    func testAnotherBuildsFileIsFoundUncheckedAndMustRunAsLong() throws {
        let data = Data("stand-in model".utf8)
        let other = Data("another build's model".utf8)
        let model = try XCTUnwrap(AppleDeviceModel.locate(
            productClass: "V68", developerDir: try makeXcode(model: other), environment: [:], known: [Self.spec(for: data)]
        ))
        XCTAssertFalse(model.isChecked)
        XCTAssertEqual(model.spec, Self.spec(for: data))
        XCTAssertTrue(model.fits(animationDuration: 20))
        XCTAssertFalse(model.fits(animationDuration: 20.5), "an animation of another length may fold elsewhere")
        XCTAssertNil(AppleDeviceModel.locate(
            productClass: "V68", developerDir: try makeXcode(model: other), environment: [:],
            known: [Self.spec(for: data, productClass: "V70")]
        ), "no known file of its product class")
    }

    func testAMissingFileAnotherProductClassOrTheKillSwitchIsNoModel() throws {
        let data = Data("stand-in model".utf8)
        XCTAssertNil(AppleDeviceModel.locate(
            productClass: "V68", developerDir: try makeXcode(model: nil), environment: [:], known: [Self.spec(for: data)]
        ))
        XCTAssertNil(AppleDeviceModel.locate(
            productClass: "V69", developerDir: try makeXcode(model: data), environment: [:], known: [Self.spec(for: data)]
        ))
        XCTAssertNil(AppleDeviceModel.locate(
            productClass: "V68", developerDir: try makeXcode(model: data),
            environment: [AppleDeviceModel.disableVariable: "1"], known: [Self.spec(for: data)]
        ))
        XCTAssertNil(AppleDeviceModel.locate(
            productClass: "../V68", developerDir: try makeXcode(model: data), environment: [:], known: [Self.spec(for: data)]
        ))
    }

    /// Flat at the stretch's start, closed at its end, linear between, clamped.
    func testTheFoldMapsLinearlyOntoItsStretch() {
        let spec = AppleDeviceModel.Spec(productClass: "V68", sha256: "", duration: 20, openTime: 10, closedTime: 15)
        XCTAssertEqual(spec.animationTime(forOpening: 180), 10)
        XCTAssertEqual(spec.animationTime(forOpening: 0), 15)
        XCTAssertEqual(spec.animationTime(forOpening: 90), 12.5)
        XCTAssertEqual(spec.animationTime(forOpening: 200), 10)
        XCTAssertEqual(spec.animationTime(forOpening: -10), 15)
        XCTAssertEqual(spec.animationTime(forOpening: .nan), 15)
    }

    /// Xcode 27.1 RC's file: 36° a second from 5.4167 s to 10.4167 s (8 s
    /// read 87°, 10.25 s read 6° on the measured joint).
    func testTheKnownFileTurns36DegreesASecond() throws {
        let duo = try XCTUnwrap(AppleDeviceModel.known.first)
        XCTAssertEqual(duo.animationTime(forOpening: 87), 8, accuracy: 0.01)
        XCTAssertEqual(duo.animationTime(forOpening: 6), 10.25, accuracy: 0.01)
        XCTAssertEqual(duo.closedTime - duo.openTime, 5, accuracy: 1e-9)
    }

    /// The parts that matter in Xcode 27.1 RC's iPhone Duo, as RealityKit
    /// loaded them (bounds in the model's units, measured 2026-10-09; the
    /// material numbers change from load to load, so these are arbitrary):
    /// the inner panel and the glass under it on the face, the outer panel
    /// and its glass on the back of the half that folds over, the other
    /// half's curved back, and a thin edge strip. Only the panels are flat.
    static let duoParts: [AppleDeviceModel.Part] = [
        .init(material: 7, lower: [-7.898555, 0.24936424, -5.541209], upper: [7.898555, 0.2493647, 5.541209]),
        .init(material: 3, lower: [-8.010373, 0.24440831, -5.6527634], upper: [8.010373, 0.24936463, 5.6527634]),
        .init(material: 12, lower: [-7.972508, -0.2753721, -5.6149645], upper: [-0.23393707, -0.27536923, 5.614964]),
        .init(material: 3, lower: [-8.111143, -0.27537048, -5.7532587], upper: [-0.095728375, -0.23534918, 5.7532725]),
        .init(material: 20, lower: [0.09572838, -0.6397745, -5.7532587], upper: [8.111143, -0.2353406, 5.7532735]),
        .init(material: 3, lower: [1.5329525, -0.07725072, 5.825349], upper: [6.6693225, 0.061273247, 5.8255982]),
    ]

    /// The key parts of the same file (measured 2026-10-10, same units; the
    /// materials again arbitrary): on the right edge, the side button's body
    /// and its two finishes, then the lower key's; on the top edge, the two
    /// volume keys.
    static let duoKeyParts: [AppleDeviceModel.Part] = [
        .init(material: 9, lower: [5.0632024, -0.12569553, -5.931292], upper: [6.154453, 0.10966066, -5.826269]),
        .init(material: 9, lower: [3.7214358, -0.12569553, -5.931292], upper: [4.812686, 0.10966066, -5.826269]),
        .init(material: 25, lower: [8.225973, -0.11242536, 1.779989], upper: [8.252043, 0.09638606, 3.4452567]),
        .init(material: 25, lower: [8.2635765, -0.13871315, -2.5095003], upper: [8.28965, 0.12267832, -0.6869396]),
        .init(material: 9, lower: [8.184357, -0.16124693, -2.531995], upper: [8.28965, 0.14521207, -0.6644448]),
        .init(material: 9, lower: [8.132927, -0.13491654, 1.757612], upper: [8.252042, 0.11887722, 3.4676335]),
        .init(material: 31, lower: [8.2635765, -0.13871315, -2.5095003], upper: [8.28965, 0.12267832, -0.6869396]),
        .init(material: 31, lower: [8.225972, -0.11242536, 1.779989], upper: [8.252042, 0.09638606, 3.4452567]),
    ]

    /// The side button is the upper key on the right edge (its body and
    /// finishes as one box); volume down is the top key nearer the hinge.
    func testTheKeysAreFoundOnTheEdges() throws {
        let keys = try XCTUnwrap(AppleDeviceModel.keys(in: Self.duoParts + Self.duoKeyParts))
        XCTAssertEqual(keys.keys.map(\.button), [.side, .volumeDown, .volumeUp])
        XCTAssertEqual(keys.keys[0].lower, [8.184357, -0.16124693, -2.531995])
        XCTAssertEqual(keys.keys[0].upper, [8.28965, 0.14521207, -0.6644448])
        XCTAssertEqual(keys.keys[1].lower.x, 3.7214358)
        XCTAssertEqual(keys.keys[2].lower.x, 5.0632024)
        XCTAssertNil(AppleDeviceModel.keys(in: Self.duoParts))
        XCTAssertNil(AppleDeviceModel.keys(in: Self.duoParts + Self.duoKeyParts.dropFirst()))
    }

    /// Each key is drawn from its own parts (moved as one when it is
    /// pressed); the body's parts belong to none. A side key moves out along
    /// +x, a top key along -z.
    func testEachPartBelongsToItsKey() throws {
        let keys = try XCTUnwrap(AppleDeviceModel.keys(in: Self.duoParts + Self.duoKeyParts))
        let owners = Self.duoKeyParts.map { keys.keyIndex(ofPartFrom: $0.lower, to: $0.upper) }
        XCTAssertEqual(owners, [2, 1, nil, 0, 0, nil, 0, nil], "volume up, volume down, the lower side key, the side button's three")
        for part in Self.duoParts {
            XCTAssertNil(keys.keyIndex(ofPartFrom: part.lower, to: part.upper))
        }
        XCTAssertEqual(keys.keys.map(\.outward), [[1, 0, 0], [0, 0, -1], [0, 0, -1]])
    }

    /// A click presses the key it lands on or just beside, from the front or
    /// from its own side; not through the device, nor on the panel.
    func testAKeyIsPressedWhereItShows() throws {
        let keys = try XCTUnwrap(AppleDeviceModel.keys(in: Self.duoParts + Self.duoKeyParts))
        func key(_ origin: SIMD3<Float>, _ direction: SIMD3<Float>) -> SimulatorHardwareButton? {
            keys.key(alongRayFrom: origin, direction: direction)?.button
        }
        XCTAssertEqual(key([8.25, 10, -1.6], [0, -1, 0]), .side)
        XCTAssertEqual(key([8.38, 10, -1.6], [0, -1, 0]), .side, "beside it")
        XCTAssertEqual(key([20, 0, -1.6], [-1, 0, 0]), .side)
        XCTAssertEqual(key([8.25, -10, -1.6], [0, 1, 0]), .side, "from the back")
        XCTAssertEqual(key([4.2, 10, -5.9], [0, -1, 0]), .volumeDown)
        XCTAssertEqual(key([5.6, 0, -20], [0, 0, 1]), .volumeUp)
        XCTAssertNil(key([-20, 0, -1.6], [1, 0, 0]), "through the device")
        XCTAssertNil(key([4.2, 0, 20], [0, 0, -1]), "through the device")
        XCTAssertNil(key([8.25, 10, 2.6], [0, -1, 0]), "the lower key has no input")
        XCTAssertNil(key([4, 10, 0], [0, -1, 0]), "the panel")
    }

    /// Closed, the other half lies over the keys' half: a ray from the far
    /// side that reaches the side button over the open device's face meets
    /// that half first. Straight on, the keys stand clear of it.
    func testTheHalfFoldedOverHidesAKeyBehindIt() throws {
        let keys = try XCTUnwrap(AppleDeviceModel.keys(in: Self.duoParts + Self.duoKeyParts))
        let origin: SIMD3<Float> = [-5, 10, -1.6]
        let toward = SIMD3<Float>(8.25, 0.1, -1.6) - origin
        let direction = toward / (toward * toward).sum().squareRoot()
        let pivot: Float = 0.2493647
        XCTAssertEqual(keys.key(alongRayFrom: origin, direction: direction, opening: 180, pivotY: pivot)?.button, .side)
        XCTAssertNil(keys.key(alongRayFrom: origin, direction: direction, opening: 0, pivotY: pivot))
        XCTAssertEqual(keys.key(alongRayFrom: [8.25, 10, -1.6], direction: [0, -1, 0], opening: 0, pivotY: pivot)?.button, .side)
        XCTAssertEqual(keys.key(alongRayFrom: [4.2, 10, -5.9], direction: [0, -1, 0], opening: 0, pivotY: pivot)?.button, .volumeDown)
    }

    func testThePanelsAreFoundByTheirShape() throws {
        let panels = try XCTUnwrap(AppleDeviceModel.panels(in: Self.duoParts))
        XCTAssertEqual(panels.inner, 7)
        XCTAssertEqual(panels.outer, 12)
    }

    /// Closed, the device is the half that stays (a quarter of the open
    /// width right of the hinge) facing the camera; flat, it is centred on
    /// the hinge; half open (110° here), it is turned 35°
    /// so both halves face the camera alike, its box reaching forward.
    func testTheFramingFollowsTheFold() {
        let width: Float = 0.5, height: Float = 0.36, thickness: Float = 0.02
        let closed = AppleDeviceModel.framing(opening: 0, width: width, height: height, thickness: thickness)
        XCTAssertEqual(closed.bookTurn, 0)
        XCTAssertEqual(closed.center.x, 0.125, accuracy: 1e-6)
        XCTAssertEqual(closed.center.y, 0, accuracy: 1e-6)
        XCTAssertEqual(closed.radius, (0.125 * 0.125 + 0.18 * 0.18).squareRoot() + 0.01, accuracy: 1e-5)

        let flat = AppleDeviceModel.framing(opening: 180, width: width, height: height, thickness: thickness)
        XCTAssertEqual(flat.bookTurn, 0, accuracy: 1e-6)
        XCTAssertEqual(flat.center, [0, 0])
        XCTAssertEqual(flat.radius, (0.25 * 0.25 + 0.18 * 0.18).squareRoot() + 0.01, accuracy: 1e-5)

        let half = AppleDeviceModel.framing(opening: 110, width: width, height: height, thickness: thickness)
        XCTAssertEqual(half.bookTurn * 180 / .pi, -35, accuracy: 1e-3)
        let folded = SIMD2<Float>(-0.25 * cos(70 * .pi / 180), 0.25 * sin(70 * .pi / 180))
        XCTAssertEqual(half.center.x, (folded.x + 0.25) / 2, accuracy: 1e-6)
        XCTAssertEqual(half.center.y, folded.y / 2, accuracy: 1e-6)
    }

    /// Nearly closed, the book turn eases in rather than snapping the device
    /// edge-on; past `bookTurnFullAt` it is half the fold.
    func testTheBookTurnEasesInFromClosed() {
        func turn(_ opening: Double) -> Float {
            AppleDeviceModel.framing(opening: opening, width: 0.5, height: 0.36, thickness: 0.02).bookTurn * 180 / .pi
        }
        XCTAssertEqual(turn(5), -87.5 * Float(pow(5.0 / 45, 2) * (3 - 2 * 5.0 / 45)), accuracy: 1e-3)
        XCTAssertEqual(turn(45), -67.5, accuracy: 1e-3)
        XCTAssertEqual(turn(90), -45, accuracy: 1e-3)
        XCTAssertEqual(turn(-20), 0)
        XCTAssertEqual(turn(.nan), 0)
    }

    /// Another load of the same file (material numbers differ each time,
    /// and each half's metal band, the half's whole thickness, covers the
    /// outer panel): the same two panels, by shape.
    static let secondLoad: [AppleDeviceModel.Part] = [
        .init(material: 31, lower: [-7.898555, 0.24936424, -5.541209], upper: [7.898555, 0.2493647, 5.541209]),
        .init(material: 20, lower: [-8.01, 0.244, -5.65], upper: [8.01, 0.249, 5.65]),
        .init(material: 1, lower: [-7.972508, -0.2753721, -5.6149645], upper: [-0.23393707, -0.27536923, 5.614964]),
        .init(material: 20, lower: [-8.11, -0.275, -5.75], upper: [-0.10, -0.235, 5.75]),
        .init(material: 15, lower: [-8.24, -0.275, -5.89], upper: [0.00, 0.228, 5.89]),
        .init(material: 15, lower: [0.00, -0.275, -5.89], upper: [8.24, 0.228, 5.89]),
        .init(material: 15, lower: [8.13, -0.135, 1.76], upper: [8.25, 0.119, 3.47]),
    ]

    func testAnotherLoadFindsTheSamePanels() throws {
        let panels = try XCTUnwrap(AppleDeviceModel.panels(in: Self.secondLoad))
        XCTAssertEqual(panels.inner, 31)
        XCTAssertEqual(panels.outer, 1)
    }

    // MARK: - Where the pointer lands

    private typealias Hit = AppleDeviceModel.PanelHit
    /// The flat panels' bounds measured on Xcode 27.1 RC's iPhone Duo.
    private static let inner = (lower: SIMD3<Float>(-7.898555, 0.24936424, -5.541209), upper: SIMD3<Float>(7.898555, 0.2493647, 5.541209))
    private static let outer = (lower: SIMD3<Float>(-7.972508, -0.2753721, -5.6149645), upper: SIMD3<Float>(-0.23393707, -0.27536923, 5.614964))

    /// Flat, the inner panel is two stretches meeting at the hinge (u at the
    /// hinge is where x = 0 falls across the panel); closed, the folding
    /// half lies face down on the other, mirrored about the hinge.
    func testTheInnerPanelsStretchesFollowTheFold() throws {
        let flat = Hit.regions(of: .inner, inner: Self.inner, outer: Self.outer, opening: 180)
        XCTAssertEqual(flat.count, 2)
        XCTAssertEqual(flat[0].u1, 0.5, accuracy: 1e-6)
        XCTAssertEqual(flat[1].u0, 0.5, accuracy: 1e-6)
        XCTAssertEqual(flat[0].origin.x, Self.inner.lower.x, accuracy: 1e-5)
        XCTAssertEqual(flat[0].origin.y, Self.inner.upper.y, accuracy: 1e-5)

        let closed = Hit.regions(of: .inner, inner: Self.inner, outer: Self.outer, opening: 0)
        XCTAssertEqual(closed[0].origin.x, -Self.inner.lower.x, accuracy: 1e-4, "the outer edge folds over to the other side")
        XCTAssertEqual(closed[0].origin.y, Self.inner.upper.y, accuracy: 1e-4)
        XCTAssertEqual(closed[1], flat[1], "the half that stays does not move")

        let half = Hit.regions(of: .inner, inner: Self.inner, outer: Self.outer, opening: 90)
        XCTAssertEqual(half[0].origin.x, 0, accuracy: 1e-4)
        XCTAssertEqual(half[0].origin.y, Self.inner.upper.y - Self.inner.lower.x, accuracy: 1e-4, "upright at 90°")
    }

    /// Closed, the outer panel faces the other way (y up) on the stack, its
    /// hinge side at the left of what the camera sees.
    func testTheOuterPanelFacesOutClosed() {
        let closed = Hit.regions(of: .outer, inner: Self.inner, outer: Self.outer, opening: 0)
        XCTAssertEqual(closed.count, 1)
        let region = closed[0]
        XCTAssertLessThan(region.origin.x, region.alongU.x, "u runs from the hinge side across")
        XCTAssertGreaterThan(region.origin.y, Self.inner.upper.y, "above the inner face once folded over")
    }

    func testARayMeetsAStretchFromItsFace() throws {
        // A unit square in z = 0 whose face looks towards +z (edges x then -y).
        let corner = SIMD3<Float>(0, 1, 0), edgeU = SIMD3<Float>(1, 0, 0), edgeV = SIMD3<Float>(0, -1, 0)
        let hit = try XCTUnwrap(Hit.intersect(origin: [0.25, 0.75, 2], direction: [0, 0, -1], corner: corner, edgeU: edgeU, edgeV: edgeV))
        XCTAssertEqual(hit.distance, 2, accuracy: 1e-6)
        XCTAssertEqual(hit.a, 0.25, accuracy: 1e-6)
        XCTAssertEqual(hit.b, 0.25, accuracy: 1e-6)
        XCTAssertNil(Hit.intersect(origin: [0.25, 0.75, -2], direction: [0, 0, 1], corner: corner, edgeU: edgeU, edgeV: edgeV), "from behind")
        XCTAssertNil(Hit.intersect(origin: [2, 0.75, 2], direction: [0, 0, -1], corner: corner, edgeU: edgeU, edgeV: edgeV), "beside it")
        XCTAssertNil(Hit.intersect(origin: [0.25, 0.75, 2], direction: [1, 0, 0], corner: corner, edgeU: edgeU, edgeV: edgeV), "parallel")
        XCTAssertNil(Hit.intersect(origin: [0.25, 0.75, 2], direction: [0, 0, 1], corner: corner, edgeU: edgeU, edgeV: edgeV), "pointing away")
    }

    /// The texture shows the frame turned clockwise; the pixel comes back
    /// through the same sampling (a quarter turn clockwise maps the frame's
    /// left edge to the texture's top).
    func testATexturePointMapsBackToTheFrame() {
        let width = 200, height = 100
        func pixel(_ u: Float, _ v: Float, _ turns: Int) -> [Int32] {
            let point = Hit.framePixel(u: u, v: v, turns: turns, width: width, height: height)
            return [point.x, point.y]
        }
        XCTAssertEqual(pixel(0.25, 0.5, 0), [50, 50])
        XCTAssertEqual(pixel(0.25, 0.5, 1), [100, 75])
        XCTAssertEqual(pixel(0.25, 0.5, 2), [150, 50])
        XCTAssertEqual(pixel(0.25, 0.5, 3), [100, 25])
        XCTAssertEqual(pixel(0.25, 0.5, -1), pixel(0.25, 0.5, 3))
        XCTAssertEqual(pixel(1, 1, 0), [199, 99], "clamped inside the frame")
    }

    func testWithoutAFlatPanelOnEitherSideThereIsNoLayout() {
        XCTAssertNil(AppleDeviceModel.panels(in: Self.duoParts.filter { $0.material != 12 }))
        XCTAssertNil(AppleDeviceModel.panels(in: Self.duoParts.filter { $0.material != 7 }))
        XCTAssertNil(AppleDeviceModel.panels(in: []))
    }

    /// A panel's picture sits inside Device Hub's black border: the long
    /// and short sides each take their own, whichever way the texture lies,
    /// and a point on the border reaches no pixel.
    func testThePictureSitsInsideThePanelsBorder() throws {
        let inner = AppleDeviceModel.PanelScreen.inner
        let landscape = inner.geometry(width: 2853, height: 2007)
        XCTAssertEqual(landscape.inset.x, 14.5 / 914, accuracy: 1e-6)
        XCTAssertEqual(landscape.inset.y, 14.5 / 648, accuracy: 1e-6)
        XCTAssertEqual(landscape.radius, 52 / 648 * 2007, accuracy: 0.01)
        let portrait = inner.geometry(width: 2007, height: 2853)
        XCTAssertEqual(portrait.inset.x, landscape.inset.y)
        XCTAssertEqual(portrait.inset.y, landscape.inset.x)

        XCTAssertNil(inner.content(u: 0.005, v: 0.5, width: 2853, height: 2007), "on the border")
        let middle = try XCTUnwrap(inner.content(u: 0.5, v: 0.5, width: 2853, height: 2007))
        XCTAssertEqual(middle.u, 0.5, accuracy: 1e-6)
        XCTAssertEqual(middle.v, 0.5, accuracy: 1e-6)
        let corner = try XCTUnwrap(inner.content(u: landscape.inset.x, v: landscape.inset.y, width: 2853, height: 2007))
        XCTAssertEqual(corner.u, 0, accuracy: 1e-6)
        XCTAssertEqual(corner.v, 0, accuracy: 1e-6)
        XCTAssertEqual(AppleDeviceModel.PanelScreen.of(.outer), .outer)
    }

    /// Device Hub's colour comes from a layer over the file, which it
    /// references where it is and does not retype.
    func testTheColourLayerReferencesTheFile() {
        let url = URL(fileURLWithPath: "/Applications/Xcode.app/Contents/SharedFrameworks/DeviceKit.framework/V68.usdz")
        let layer = AppleDeviceModel.colorVariantLayer(referencing: url, color: AppleDeviceModel.deviceHubColor)
        XCTAssertTrue(layer.hasPrefix("#usda 1.0"))
        XCTAssertTrue(layer.contains("prepend references = @\(url.path)@"))
        XCTAssertTrue(layer.contains("string color = \"Dark\""))
        XCTAssertTrue(layer.contains("def \"root\" ("), "typeless: the file's SkelRoot stands")
    }
}
