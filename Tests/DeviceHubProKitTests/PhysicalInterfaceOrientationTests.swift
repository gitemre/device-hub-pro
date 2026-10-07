import CoreImage
import CoreVideo
import Foundation
import XCTest
@testable import DeviceHubProKit

/// The interface orientation without XCTest: the
/// tracker's state machine on scripted reads, the stage rotation that turns the
/// portrait panel upright, the native session that applies it, and the lazy
/// control proxy. Nothing here reaches a device.
final class PhysicalInterfaceOrientationTests: XCTestCase {
    // MARK: Tracker

    private final class World: @unchecked Sendable {
        private let lock = NSLock()
        private var _device = PhysicalControlOrientation.portrait
        private var _shot: CGSize? = CGSize(width: 1170, height: 2532)
        private var _shots = 0
        var device: PhysicalControlOrientation { get { lock.withLock { _device } } set { lock.withLock { _device = newValue } } }
        var shot: CGSize? { get { lock.withLock { _shot } } set { lock.withLock { _shot = newValue } } }
        var shots: Int { lock.withLock { _shots } }
        func screenshot() throws -> CGSize {
            lock.withLock { _shots += 1 }
            guard let shot else { throw NSError(domain: "test", code: 1) }
            return shot
        }
        static let portraitShot = CGSize(width: 1170, height: 2532)
        static let landscapeShot = CGSize(width: 2532, height: 1170)
    }

    private final class TurnBox: @unchecked Sendable {
        private let lock = NSLock()
        private var action: (@Sendable () async -> Void)?
        func set(_ action: @escaping @Sendable () async -> Void) { lock.withLock { self.action = action } }
        func take() -> (@Sendable () async -> Void)? { lock.withLock { let a = action; action = nil; return a } }
    }

    private final class Changes: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.withLock { _count } }
        func bump() { lock.withLock { _count += 1 } }
    }

    private func tracker(_ world: World, sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }) -> (PhysicalInterfaceOrientationTracker, Changes) {
        let tracker = PhysicalInterfaceOrientationTracker(
            reads: .init(deviceOrientation: { world.device }, screenshotSize: { try world.screenshot() }),
            sleep: sleep
        )
        let changes = Changes()
        tracker.observe { changes.bump() }
        return (tracker, changes)
    }

    func testItStartsUnknownAndReadsPortraitFromThePhone() async {
        let world = World()
        let (tracker, changes) = tracker(world)
        XCTAssertNil(tracker.stagePose)
        XCTAssertNil(tracker.interfaceOrientation)
        await tracker.poll()
        XCTAssertEqual(tracker.stagePose, .portrait)
        XCTAssertEqual(tracker.interfaceOrientation, .portrait)
        XCTAssertFalse(tracker.interfaceIsLandscape)
        XCTAssertEqual(changes.count, 2, "stage and interface are each published")
    }

    /// Device Hub 27.0: the stage follows the DEVICE pose in every pose, and the
    /// interface only says where the home indicator is.
    func testTheStageFollowsTheDevicePoseWhateverTheInterfaceDoes() async {
        let poses: [PhysicalControlOrientation] = [.portrait, .landscapeLeft, .landscapeRight, .portraitUpsideDown]
        for pose in poses {
            for shot in [World.portraitShot, World.landscapeShot] {
                let world = World()
                world.device = pose
                world.shot = shot
                let (tracker, _) = tracker(world)
                await tracker.poll()
                XCTAssertEqual(tracker.stagePose, pose, "\(pose.rawValue) with shot \(shot)")
                XCTAssertEqual(tracker.interfaceIsLandscape, shot == World.landscapeShot, "\(pose.rawValue) with shot \(shot)")
            }
        }
    }

    func testAPortraitOnlyInterfaceStillTurnsTheStageWithTheDevice() async {
        let world = World()
        let (tracker, _) = tracker(world)
        await tracker.poll()
        world.device = .landscapeLeft
        world.shot = World.portraitShot   // the home screen did not turn
        await tracker.poll()
        XCTAssertEqual(tracker.stagePose, .landscapeLeft)
        XCTAssertEqual(tracker.interfaceOrientation, .portrait)
        XCTAssertFalse(tracker.interfaceIsLandscape)
        world.device = .landscapeRight
        await tracker.poll()
        XCTAssertEqual(tracker.stagePose, .landscapeRight)
        world.device = .portraitUpsideDown
        await tracker.poll()
        XCTAssertEqual(tracker.stagePose, .portraitUpsideDown)
        XCTAssertEqual(tracker.interfaceOrientation, .portrait)
    }

    func testALandscapeInterfaceFollowsTheDeviceSide() async {
        let world = World()
        let (tracker, _) = tracker(world)
        await tracker.poll()
        world.device = .landscapeLeft
        world.shot = World.landscapeShot
        await tracker.poll()
        XCTAssertEqual(tracker.interfaceOrientation, .landscapeLeft)
        XCTAssertTrue(tracker.interfaceIsLandscape)
        world.device = .landscapeRight
        await tracker.poll()
        XCTAssertEqual(tracker.interfaceOrientation, .landscapeRight)
        world.device = .portrait
        world.shot = World.portraitShot
        await tracker.poll()
        XCTAssertEqual(tracker.stagePose, .portrait)
        XCTAssertEqual(tracker.interfaceOrientation, .portrait)
    }

    func testNoteTurnTurnsTheStageAtOnceAndAStaleReadDoesNotUndoIt() async {
        let world = World()
        let (tracker, changes) = tracker(world)
        await tracker.poll()
        let count = changes.count
        // `orientation get` does not follow `set` (measured): it keeps saying portrait.
        world.shot = World.portraitShot
        await tracker.noteTurn(to: .landscapeLeft)
        XCTAssertEqual(tracker.stagePose, .landscapeLeft)
        XCTAssertEqual(tracker.interfaceOrientation, .portrait, "a portrait-only app keeps its interface")
        XCTAssertGreaterThan(changes.count, count)
        for _ in 0..<3 { await tracker.poll() }
        XCTAssertEqual(tracker.stagePose, .landscapeLeft, "an unchanged read leaves the pose we set")
        // An interface that turned is decided from the screenshot.
        world.shot = World.landscapeShot
        await tracker.noteTurn(to: .landscapeRight)
        XCTAssertEqual(tracker.stagePose, .landscapeRight)
        XCTAssertEqual(tracker.interfaceOrientation, .landscapeRight)
        // An external change (the read changes) is followed once it persists past the
        // turn the app just made.
        world.device = .landscapeLeft
        for _ in 0..<6 { await tracker.poll() }
        XCTAssertEqual(tracker.stagePose, .landscapeLeft)
        // Upside down: the stage turns, an interface that stays landscape keeps its side.
        await tracker.noteTurn(to: .portraitUpsideDown)
        XCTAssertEqual(tracker.stagePose, .portraitUpsideDown)
        XCTAssertEqual(tracker.interfaceOrientation, .landscapeLeft)
        // Flat is not something to ask for.
        let flatCount = changes.count
        await tracker.noteTurn(to: .faceUp)
        XCTAssertEqual(changes.count, flatCount)
        XCTAssertEqual(tracker.stagePose, .portraitUpsideDown)
    }

    /// Reproduced live 2026-10-01 (iPhone 12, home screen): portrait to landscape left was
    /// right, but landscape left to upside down left the stage upright. The phone reports
    /// another pose for a moment after `set` (it passes through portrait), and a poll that
    /// took that read put the stage back. A read that disagrees with the pose the app just
    /// set is the phone still turning, not an external turn.
    func testAPoseTheAppSetSurvivesTheTransientReadsWhileThePhoneTurns() async {
        let world = World()
        let (tracker, _) = tracker(world)
        await tracker.poll()
        world.shot = World.portraitShot
        await tracker.noteTurn(to: .landscapeLeft)
        world.device = .landscapeLeft
        await tracker.poll()
        XCTAssertEqual(tracker.stagePose, .landscapeLeft)

        await tracker.noteTurn(to: .portraitUpsideDown)
        world.device = .portrait
        for _ in 0..<3 {
            await tracker.poll()
            XCTAssertEqual(tracker.stagePose, .portraitUpsideDown, "a transient portrait read is not a turn")
        }
        world.device = .portraitUpsideDown
        await tracker.poll()
        XCTAssertEqual(tracker.stagePose, .portraitUpsideDown)

        // The wait ended: an external turn is followed again.
        world.device = .portrait
        await tracker.poll()
        XCTAssertEqual(tracker.stagePose, .portrait)
    }

    func testAnExternalTurnIsFollowedOnceTheReadsKeepDisagreeing() async {
        let world = World()
        let (tracker, _) = tracker(world)
        await tracker.poll()
        await tracker.noteTurn(to: .landscapeLeft)
        world.device = .landscapeRight
        for _ in 0..<10 { await tracker.poll() }
        XCTAssertEqual(tracker.stagePose, .landscapeRight, "someone turned the phone by hand")
    }

    /// A poll that was waiting (its settle delay) when Rotate turned the phone must not
    /// publish what it read before the turn.
    func testAPollThatWasWaitingWhenTheAppTurnedThePhoneDoesNotUndoTheTurn() async throws {
        let world = World()
        let box = TurnBox()
        let (tracker, _) = tracker(world) { _ in
            if let pending = box.take() { await pending() }
        }
        await tracker.poll()
        world.shot = World.portraitShot
        await tracker.noteTurn(to: .landscapeLeft)
        world.device = .landscapeLeft
        await tracker.poll()
        XCTAssertEqual(tracker.stagePose, .landscapeLeft)
        // A poll reads landscape right, waits, and in the wait the app turns to upside
        // down; the poll's later read is still landscape right.
        world.device = .landscapeRight
        box.set { await tracker.noteTurn(to: .portraitUpsideDown) }
        await tracker.poll()
        XCTAssertEqual(tracker.stagePose, .portraitUpsideDown)
    }

    /// Landscape left, upside down, landscape right, portrait and back, each settling.
    func testEveryPoseOfARotateWalkSettles() async throws {
        let world = World()
        let (tracker, _) = tracker(world)
        await tracker.poll()
        world.shot = World.portraitShot
        let walk: [PhysicalControlOrientation] = [.landscapeLeft, .portraitUpsideDown, .landscapeRight, .portrait,
                                                  .landscapeRight, .portraitUpsideDown, .landscapeLeft, .portrait]
        for pose in walk {
            await tracker.noteTurn(to: pose)
            XCTAssertEqual(tracker.stagePose, pose)
            world.device = pose
            await tracker.poll()
            XCTAssertEqual(tracker.stagePose, pose, "\(pose.rawValue) after the read")
        }
    }

    func testAnUnchangedPoseCostsNoScreenshot() async {
        let world = World()
        let (tracker, _) = tracker(world)
        await tracker.poll()
        let before = world.shots
        for _ in 0..<5 { await tracker.poll() }
        XCTAssertEqual(world.shots, before)
    }

    func testFlatAndUnknownChangeNothing() async {
        let world = World()
        let (tracker, changes) = tracker(world)
        world.device = .landscapeRight
        world.shot = World.landscapeShot
        await tracker.poll()
        let shots = world.shots, count = changes.count
        for pose in [PhysicalControlOrientation.faceUp, .faceDown, .unknown] {
            world.device = pose
            await tracker.poll()
            XCTAssertEqual(tracker.stagePose, .landscapeRight, pose.rawValue)
        }
        XCTAssertEqual(world.shots, shots, "no screenshot for a pose that says nothing")
        XCTAssertEqual(changes.count, count)
        // Back to the same landscape after being flat: nothing to redo.
        world.device = .landscapeRight
        await tracker.poll()
        XCTAssertEqual(world.shots, shots)
    }

    func testALandscapeOnlyAppOnAPortraitDeviceKeepsTheLastLandscapeSide() async {
        let world = World()
        let (tracker, _) = tracker(world)
        world.device = .landscapeRight
        world.shot = World.landscapeShot
        await tracker.poll()
        world.device = .portrait
        await tracker.poll()   // landscape aspect with the device upright
        XCTAssertEqual(tracker.stagePose, .portrait)
        XCTAssertEqual(tracker.interfaceOrientation, .landscapeRight)
        let (fresh, _) = self.tracker(world)
        await fresh.poll()
        XCTAssertEqual(fresh.interfaceOrientation, .landscapeLeft, "no side known: landscapeLeft")
    }

    func testAFailedScreenshotFollowsTheDevice() async {
        let world = World()
        let (tracker, _) = tracker(world)
        world.device = .landscapeRight
        world.shot = nil
        await tracker.poll()
        XCTAssertEqual(tracker.stagePose, .landscapeRight)
        XCTAssertEqual(tracker.interfaceOrientation, .landscapeRight)
    }

    func testASecondTurnDuringTheSettleIsTheOneAnswered() async {
        let world = World()
        world.shot = World.landscapeShot
        let (tracker, _) = tracker(world) { _ in world.device = .landscapeRight }   // the settle wait: it turned again
        world.device = .landscapeLeft
        await tracker.poll()
        XCTAssertEqual(tracker.stagePose, .landscapeRight)
        XCTAssertEqual(world.shots, 1, "one screenshot for the two turns")
        await tracker.poll()
        XCTAssertEqual(world.shots, 1, "and the answered pose is not read twice")
    }

    func testTheSettleWaitIsAppliedBeforeTheScreenshot() async {
        let world = World()
        let waits = Changes()
        let (tracker, _) = tracker(world) { _ in
            XCTAssertEqual(world.shots, 0, "the screenshot comes after the wait")
            waits.bump()
        }
        await tracker.poll()
        XCTAssertEqual(waits.count, 1)
    }

    func testStartPollsUntilStopped() async throws {
        let world = World()
        world.device = .landscapeLeft
        world.shot = World.landscapeShot
        let tracker = PhysicalInterfaceOrientationTracker(
            reads: .init(deviceOrientation: { world.device }, screenshotSize: { try world.screenshot() }),
            interval: .milliseconds(5), settle: .milliseconds(1)
        )
        tracker.start()
        tracker.start()   // a second start is one loop
        for _ in 0..<200 where tracker.stagePose == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(tracker.stagePose, .landscapeLeft)
        tracker.stop()
        world.device = .landscapeRight
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(tracker.stagePose, .landscapeLeft, "stopped: it no longer reads")
    }

    // MARK: Stage rotation

    func testTheStageRotationIsThePanelMappingAndSwapsTheSize() {
        XCTAssertEqual(PhysicalStageRotation.rotation(for: .portrait), .identity)
        XCTAssertEqual(PhysicalStageRotation.rotation(for: nil), .identity)
        XCTAssertEqual(PhysicalStageRotation.rotation(for: .portraitUpsideDown), .turn180, "the stage turns half a turn")
        XCTAssertEqual(PhysicalStageRotation.rotation(for: .faceUp), .identity)
        XCTAssertEqual(PhysicalStageRotation.stageSize(panel: CGSize(width: 1170, height: 2532), pose: .portraitUpsideDown), CGSize(width: 1170, height: 2532), "no swap")
        XCTAssertEqual(PhysicalStageRotation.rotation(for: .landscapeLeft), FastInputPanelMapping.rotation(for: .landscapeLeft))
        XCTAssertEqual(PhysicalStageRotation.rotation(for: .landscapeRight), FastInputPanelMapping.rotation(for: .landscapeRight))
        let panel = CGSize(width: 1170, height: 2532)
        XCTAssertEqual(PhysicalStageRotation.stageSize(panel: panel, pose: .portrait), panel)
        XCTAssertEqual(PhysicalStageRotation.stageSize(panel: panel, pose: .landscapeLeft), CGSize(width: 2532, height: 1170))
        XCTAssertEqual(PhysicalStageRotation.stageSize(panel: panel, pose: .landscapeRight), CGSize(width: 2532, height: 1170))
    }

    /// A BGRA panel picture whose pixel (x, y) is coloured by its own position.
    private func codedPanel(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]]
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer), kCVReturnSuccess)
        let panel = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(panel, [])
        defer { CVPixelBufferUnlockBaseAddress(panel, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(panel)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(panel)
        for y in 0..<height {
            for x in 0..<width {
                let p = base + y * stride + x * 4
                p[0] = UInt8(x * 20 + 10); p[1] = UInt8(y * 20 + 10); p[2] = 0; p[3] = 255
            }
        }
        return panel
    }

    /// The stage picture of `panel` must be explained by `rotation.apply` for every pixel:
    /// the stage pixel's normalized centre maps to the panel pixel with that colour.
    func testTheCropperTurnsThePanelSoTheStageMapsBackThroughThePanelMapping() throws {
        let panelW = 6, panelH = 10
        let panel = try codedPanel(width: panelW, height: panelH)
        let cropper = NativeMirrorFrameCropper()
        let rect = CGRect(x: 0, y: 0, width: panelW, height: panelH)
        for rotation in [FastInputPanelMapping.Rotation.identity, .clockwise90, .counterClockwise90, .turn180] {
            let out = try XCTUnwrap(cropper.crop(panel, to: rect, stage: rotation), "\(rotation)")
            let w = CVPixelBufferGetWidth(out), h = CVPixelBufferGetHeight(out)
            let swapped = rotation == .clockwise90 || rotation == .counterClockwise90
            XCTAssertEqual(w, swapped ? panelH : panelW, "\(rotation)")
            XCTAssertEqual(h, swapped ? panelW : panelH, "\(rotation)")
            CVPixelBufferLockBaseAddress(out, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(out, .readOnly) }
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(out)).assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(out)
            for sy in 0..<h {
                for sx in 0..<w {
                    let normal = CGPoint(x: (Double(sx) + 0.5) / Double(w), y: (Double(sy) + 0.5) / Double(h))
                    let mapped = rotation.apply(normal)
                    let px = Int(mapped.x * Double(panelW)), py = Int(mapped.y * Double(panelH))
                    let p = base + sy * stride + sx * 4
                    XCTAssertEqual(Int(p[0]), px * 20 + 10, accuracy: 2, "\(rotation) stage (\(sx),\(sy)) blue")
                    XCTAssertEqual(Int(p[1]), py * 20 + 10, accuracy: 2, "\(rotation) stage (\(sx),\(sy)) green")
                }
            }
        }
    }

    // MARK: The native session

    private final class FakeLease: FastInputLease, @unchecked Sendable {
        func start() async throws {}
        func stop() async {}
        func terminateNow() {}
    }

    private final class FakeStream: NativeMirroring, @unchecked Sendable {
        let onFrame: @Sendable (CVPixelBuffer, CGRect) -> Void
        init(onFrame: @escaping @Sendable (CVPixelBuffer, CGRect) -> Void) { self.onFrame = onFrame }
        func start() async throws {}
        func stop() {}
    }

    private final class Streams: @unchecked Sendable {
        private let lock = NSLock()
        private var _made: [FakeStream] = []
        var made: [FakeStream] { lock.withLock { _made } }
        var factory: NativeMirrorStreamFactory {
            { [self] _, onFrame, _ in
                let stream = FakeStream(onFrame: onFrame)
                lock.withLock { _made.append(stream) }
                return stream
            }
        }
    }

    func testTheNativeSessionTurnsThePortraitPanelWithTheDevicePose() async throws {
        let world = World()
        // The session's loop sleeps its real interval (the settle wait is skipped), so only
        // the test's own polls move the tracker after its first read.
        let (tracker, changes) = tracker(world) { duration in
            if duration >= .seconds(1) { try await Task.sleep(for: duration) }
        }
        let streams = Streams()
        let endpoint = NativeMirrorEndpoint(coreDeviceIdentifier: "00000000-0000-4000-8000-000000000001", interface: "utun4",
                                            hostAddress: "fd00::2", deviceAddress: "fd00::1", productType: "iPhone13,2")
        let session = PhysicalNativeMirrorSession(
            hardwareUDID: "00000000-0000000000000000", endpointProvider: { endpoint }, lease: FakeLease(),
            makeStream: streams.factory, orientationTracker: tracker, sleep: { _ in }
        )
        let seen = Changes()
        session.observeStagePose { seen.bump() }
        XCTAssertNil(session.stagePose)
        session.start()
        for _ in 0..<200 where streams.made.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let stream = try XCTUnwrap(streams.made.first)
        // Starting the session starts the tracker: its first read is portrait.
        for _ in 0..<200 where session.stagePose == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(session.stagePose, .portrait)
        func panelFrame() throws -> CVPixelBuffer {
            var buffer: CVPixelBuffer?
            let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]]
            CVPixelBufferCreate(nil, 1184, 2576, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
            return try XCTUnwrap(buffer)
        }
        let crop = CGRect(x: 0, y: 0, width: 1170, height: 2532)

        // Portrait interface: as the panel.
        stream.onFrame(try panelFrame(), crop)
        XCTAssertEqual(session.frames.currentSize?.width, 1170)
        XCTAssertEqual(session.frames.currentSize?.height, 2532)

        // The phone turned to landscape: the stream is still the panel, the stage is wide.
        world.device = .landscapeLeft
        world.shot = World.landscapeShot
        await tracker.poll()
        XCTAssertEqual(session.stagePose, .landscapeLeft)
        XCTAssertTrue(session.interfaceIsLandscape)
        XCTAssertEqual(seen.count, changes.count, "the session passes the tracker's changes on")
        XCTAssertEqual(seen.count, 4, "stage and interface portrait at the start, then landscapeLeft for both")
        stream.onFrame(try panelFrame(), crop)
        XCTAssertEqual(session.frames.currentSize?.width, 2532)
        XCTAssertEqual(session.frames.currentSize?.height, 1170)
        world.device = .landscapeRight
        await tracker.poll()
        stream.onFrame(try panelFrame(), crop)
        XCTAssertEqual(session.frames.currentSize?.width, 2532)

        // A portrait-only app (the home screen) in a landscape device: the frame still turns
        // (Device Hub 27.0), the picture with it.
        world.device = .landscapeLeft
        world.shot = World.portraitShot
        await tracker.poll()
        XCTAssertFalse(session.interfaceIsLandscape)
        stream.onFrame(try panelFrame(), crop)
        XCTAssertEqual(session.frames.currentSize?.width, 2532)
        XCTAssertEqual(session.frames.currentSize?.height, 1170)

        // Upside down: the half turn keeps the panel's size.
        world.device = .portraitUpsideDown
        await tracker.poll()
        XCTAssertEqual(session.stagePose, .portraitUpsideDown)
        stream.onFrame(try panelFrame(), crop)
        XCTAssertEqual(session.frames.currentSize?.height, 2532)

        // `noteTurn` (Rotate) turns the picture at once.
        await session.noteTurn(to: .landscapeRight)
        XCTAssertEqual(session.stagePose, .landscapeRight)
        stream.onFrame(try panelFrame(), crop)
        XCTAssertEqual(session.frames.currentSize?.width, 2532)

        // A stream that ever delivers a landscape rect is already upright: left alone.
        world.device = .landscapeRight
        world.shot = World.landscapeShot
        await tracker.poll()
        var wide: CVPixelBuffer?
        CVPixelBufferCreate(nil, 2576, 1184, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]] as CFDictionary, &wide)
        stream.onFrame(try XCTUnwrap(wide), CGRect(x: 0, y: 0, width: 2532, height: 1170))
        XCTAssertEqual(session.frames.currentSize?.width, 2532)
        session.stop()
    }

    func testASessionWithoutATrackerKeepsTheFramesAsTheyAre() async throws {
        let streams = Streams()
        let endpoint = NativeMirrorEndpoint(coreDeviceIdentifier: "00000000-0000-4000-8000-000000000001", interface: "utun4",
                                            hostAddress: "fd00::2", deviceAddress: "fd00::1", productType: "iPhone13,2")
        let session = PhysicalNativeMirrorSession(
            hardwareUDID: "00000000-0000000000000000", endpointProvider: { endpoint }, lease: FakeLease(),
            makeStream: streams.factory, sleep: { _ in }
        )
        XCTAssertNil(session.stagePose)
        XCTAssertFalse(session.interfaceIsLandscape)
        session.start()
        for _ in 0..<200 where streams.made.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 1184, 2576, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]] as CFDictionary, &buffer)
        try XCTUnwrap(streams.made.first).onFrame(try XCTUnwrap(buffer), CGRect(x: 0, y: 0, width: 1170, height: 2532))
        XCTAssertEqual(session.frames.currentSize?.height, 2532)
        session.stop()
    }

    // MARK: Lazy control

    private final class Resolver: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.withLock { _count } }
        var failure: PhysicalControlError?
        let control = FakeControl()
        func resolve() throws -> any PhysicalControlling {
            lock.withLock { _count += 1 }
            if let failure { throw failure }
            return control
        }
    }

    func testTheLazyControlResolvesOnlyWhenUsedAndForwards() async throws {
        let resolver = Resolver()
        let lazy = LazyPhysicalControl { try resolver.resolve() }
        try await lazy.start()
        await lazy.stop()
        lazy.terminateNow()
        _ = await lazy.snapshot()
        XCTAssertEqual(resolver.count, 0, "lifecycle calls never start the runner")
        try await lazy.tap(CGPoint(x: 1, y: 2))
        try await lazy.press(.home)
        try await lazy.showAppSwitcher()
        XCTAssertEqual(resolver.count, 3)
        XCTAssertEqual(resolver.control.calls.count, 3)
    }

    func testTheLazyControlPassesTheStartFailureOn() async {
        let resolver = Resolver()
        resolver.failure = .launchFailed("scripted")
        let lazy = LazyPhysicalControl { try resolver.resolve() }
        do {
            try await lazy.tap(.zero)
            XCTFail("should have thrown")
        } catch {
            XCTAssertEqual(error as? PhysicalControlError, .launchFailed("scripted"))
        }
        let size = await lazy.portraitSize()
        XCTAssertNil(size)
    }
}
