import AppKit
import SwiftUI
import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// A foldable's 3D model under the stage zoom and across the stage's
/// rebuilds: one layout whatever the zoom (a zoom step used to rebuild the
/// view and the device vanished for half a second), the zoom applied to the
/// model once and not to its view, the scene that survives a rebuilt view,
/// and the compact window that shows the same model.
@MainActor
final class DeviceModelZoomTests: XCTestCase {
    // MARK: - One layout for every zoom

    func testTheModelHasOneLayoutAtEveryZoom() {
        for zoom in [nil, 1.0, 0.5, 0.75, 1.25, 2.5, 8.0] as [Double?] {
            XCTAssertEqual(StageZoomLayout(stageZoom: zoom, drawsDeviceModel: true), .model, "zoom \(String(describing: zoom))")
        }
    }

    func testAnyOtherDeviceKeepsTheScrollViewAndTheFittedLayout() {
        XCTAssertEqual(StageZoomLayout(stageZoom: nil, drawsDeviceModel: false), .fitted)
        XCTAssertEqual(StageZoomLayout(stageZoom: 2, drawsDeviceModel: false), .scrolling(zoom: 2))
    }

    // MARK: - The zoom is the model's height, once

    func testTheFrontModelIsTheFittedHeightTimesTheZoom() throws {
        let frame = try AppleChromeStageTests.iPhone17ProFrame()
        let available = CGSize(width: 900, height: 700)
        let fitted = MirrorStageContent.frontModel(outerFrame: frame, available: available)
        XCTAssertEqual(
            fitted.height, min(700 * MirrorStageContent.frontFitHeight, 900 * MirrorStageContent.frontFitWidth),
            "no zoom is Device Hub's Zoom to Fit"
        )
        let zoomed = MirrorStageContent.frontModel(outerFrame: frame, available: available, zoom: 2.5)
        XCTAssertEqual(zoomed.height, fitted.height * 2.5, accuracy: 1e-9)
        XCTAssertEqual(zoomed.pointsPerPixel, fitted.pointsPerPixel * 2.5, accuracy: 1e-12, "the scale modes count in the zoomed model")
        // The zoom steps by the same factor whatever the stage: a zoom
        // of the stage's size and a zoom of the model are one and the same,
        // so the scale modes converge without a second pass.
        let bigger = MirrorStageContent.frontModel(outerFrame: frame, available: CGSize(width: 900 * 2.5, height: 700 * 2.5))
        XCTAssertEqual(bigger.height, zoomed.height, accuracy: 1e-9)
        XCTAssertEqual(bigger.pointsPerPixel, zoomed.pointsPerPixel, accuracy: 1e-12)
    }

    func testTheCameraDrawsTheModelAtItsZoomedHeight() {
        let fitted = DeviceModelScene.frontFieldOfView(viewHeight: 800, height: 400, zoom: 1)
        let twice = DeviceModelScene.frontFieldOfView(viewHeight: 800, height: 400, zoom: 2)
        let tanFitted = tan(Double(fitted) * .pi / 360), tanTwice = tan(Double(twice) * .pi / 360)
        XCTAssertEqual(tanFitted / tanTwice, 2, accuracy: 1e-4, "twice as tall, half the view")
        XCTAssertEqual(
            DeviceModelScene.frontFieldOfView(viewHeight: 800, height: 800, zoom: 0.5), fitted, accuracy: 1e-4,
            "the zoom and the height are one factor"
        )
        XCTAssertEqual(tanFitted, 800.0 / 400.0 / 2.0 / Double(DeviceModelScene.frontDistance), accuracy: 1e-6)
    }

    // MARK: - Moving a zoomed model

    func testAModelPansOnlyAsFarAsItOverhangsTheView() {
        let view = CGSize(width: 800, height: 900)
        // Taller than the view, narrower than it: only vertically.
        let outline = CGSize(width: 600, height: 1300)
        XCTAssertEqual(
            DeviceModelScene.clampedPan(CGSize(width: 500, height: -900), view: view, outline: outline),
            CGSize(width: 0, height: -200)
        )
        XCTAssertEqual(
            DeviceModelScene.clampedPan(CGSize(width: 0, height: 150), view: view, outline: outline),
            CGSize(width: 0, height: 150)
        )
        XCTAssertEqual(
            DeviceModelScene.clampedPan(CGSize(width: 10, height: 10), view: view, outline: CGSize(width: 300, height: 400)),
            .zero,
            "a model within the view does not move"
        )
    }

    func testOnlyAZoomedFrontOnModelCanBeMoved() {
        let scene = DeviceModelScene()
        XCTAssertFalse(scene.canPan, "turnable (the scene's start)")
        scene.present(.front(height: 400))
        XCTAssertFalse(scene.canPan, "at Zoom to Fit")
        scene.setFrontZoom(1.04, animated: false)
        XCTAssertFalse(scene.canPan, "a zoom just above fit still fits (`WindowState.zoomOverflows`)")
        scene.setFrontZoom(2, animated: false)
        XCTAssertTrue(scene.canPan)
        scene.setFrontZoom(1, animated: false)
        XCTAssertFalse(scene.canPan, "Zoom to Fit puts it back")
        scene.setFrontZoom(2, animated: false)
        scene.present(.free)
        XCTAssertFalse(scene.canPan, "the turnable model turns, it does not pan")
        XCTAssertFalse(WindowState.zoomOverflows(Double(DeviceModelScene.panFromZoom)), "the stage scrolls from the same zoom")
        XCTAssertTrue(WindowState.zoomOverflows(Double(DeviceModelScene.panFromZoom) + 0.001))
    }

    // MARK: - A scene outlives its view

    private static func model(_ name: String = "V68") -> AppleDeviceModel {
        AppleDeviceModel(
            url: URL(fileURLWithPath: "/nonexistent/\(name).usdz"),
            spec: .init(productClass: name, sha256: "00", duration: 37.5, openTime: 5, closedTime: 10),
            isChecked: true
        )
    }

    private func key(_ surface: DeviceModelSurface = .main, color: String = "natural", model: AppleDeviceModel = DeviceModelZoomTests.model()) -> DeviceModelScenes.Key {
        .init(surface: surface, model: model, color: color)
    }

    func testAViewMadeAnewTakesTheLoadedScene() {
        let scenes = DeviceModelScenes()
        let first = DeviceModelLease(), second = DeviceModelLease()
        let scene = scenes.lend(key(), to: first)
        XCTAssertTrue(scenes.lend(key(), to: first) === scene, "a view keeps its scene for as long as it lives")
        XCTAssertTrue(scenes.lend(key(), to: second) === scene, "the view made anew takes the scene the old one loaded")
    }

    func testEachWindowHasASceneOfItsOwn() {
        let scenes = DeviceModelScenes()
        let main = scenes.lend(key(.main), to: DeviceModelLease())
        let compact = scenes.lend(key(.compact), to: DeviceModelLease())
        XCTAssertFalse(main === compact, "an entity tree sits in one renderer only")
    }

    func testANewFinishIsANewScene() {
        let scenes = DeviceModelScenes()
        let old = DeviceModelLease(), new = DeviceModelLease()
        let natural = scenes.lend(key(color: "natural"), to: old)
        let black = scenes.lend(key(color: "black"), to: new)
        XCTAssertFalse(natural === black)
        XCTAssertTrue(scenes.holds(black, on: .main))
        XCTAssertFalse(scenes.holds(natural, on: .main))
        // The old view keeps the scene it was lent for as long as it lives.
        XCTAssertTrue(scenes.lend(key(color: "black"), to: old) === natural)
    }

    func testTheViewThatTookOverIsNotStoppedByTheOneGoingAway() {
        let scenes = DeviceModelScenes()
        let old = DeviceModelLease(), new = DeviceModelLease()
        _ = scenes.lend(key(), to: old)
        scenes.claim(old)
        _ = scenes.lend(key(), to: new)
        // The new view appears before the old one disappears, or after.
        scenes.claim(new)
        XCTAssertFalse(scenes.release(old), "the old view's disappearing must not stop what the new one started")
        XCTAssertTrue(scenes.isShowing)
        XCTAssertTrue(scenes.release(new))
        XCTAssertFalse(scenes.isShowing)
    }

    func testASceneAViewLeftIsStoppedAndKeptForTheNextOne() {
        let scenes = DeviceModelScenes()
        let lease = DeviceModelLease()
        let scene = scenes.lend(key(), to: lease)
        scenes.claim(lease)
        XCTAssertTrue(scenes.release(lease), "the view that owned it stops its feed")
        XCTAssertTrue(scenes.holds(scene, on: .main), "kept for a view made anew")
        let next = DeviceModelLease()
        XCTAssertTrue(scenes.lend(key(), to: next) === scene)
        scenes.claim(next)
        XCTAssertTrue(scenes.isShowing)
    }

    /// Polls `condition` on the main actor for up to two seconds.
    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testASceneNoViewShowsIsDroppedAfterTheRetention() async throws {
        let scenes = DeviceModelScenes(retention: .milliseconds(40))
        let lease = DeviceModelLease()
        let scene = scenes.lend(key(.compact), to: lease)
        scenes.claim(lease)
        XCTAssertTrue(scenes.release(lease), "the compact window closed")
        XCTAssertTrue(scenes.holds(scene, on: .compact), "kept for a window opened again soon")
        try await eventually { !scenes.holds(scene, on: .compact) }
        XCTAssertFalse(scenes.holds(scene, on: .compact), "freed once the device is gone from the stage")
    }

    func testAWindowOpenedAgainWithinTheRetentionShowsTheLoadedScene() async throws {
        let scenes = DeviceModelScenes(retention: .milliseconds(150))
        let closed = DeviceModelLease()
        let scene = scenes.lend(key(.compact), to: closed)
        scenes.claim(closed)
        _ = scenes.release(closed)
        let reopened = DeviceModelLease()
        XCTAssertTrue(scenes.lend(key(.compact), to: reopened) === scene)
        scenes.claim(reopened)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(scenes.holds(scene, on: .compact), "a scene a view showed again is not dropped by the earlier release")
        XCTAssertTrue(scenes.isShowing)
    }

    func testTheLiveHingeReachesEveryShownScene() {
        let scenes = DeviceModelScenes()
        let main = DeviceModelLease(), compact = DeviceModelLease()
        _ = scenes.lend(key(.main), to: main)
        _ = scenes.lend(key(.compact), to: compact)
        XCTAssertFalse(scenes.isShowing)
        scenes.claim(main)
        XCTAssertTrue(scenes.isShowing)
        scenes.claim(compact)
        XCTAssertTrue(scenes.release(main))
        XCTAssertTrue(scenes.isShowing, "the compact window's scene still is")
        scenes.foldLive(toOpening: 120)
    }

    // MARK: - Outline of a zoomed model, frames of a window nobody sees

    func testTheOutlineIsHalfAsWideClosedAndTurnsOnItsSide() {
        let open = DeviceModelScene.frontOutline(height: 400, aspect: 1.4, isClosed: false, roll: 0)
        XCTAssertEqual(open.width, 560, accuracy: 1e-6)
        XCTAssertEqual(open.height, 400, accuracy: 1e-6)
        let closed = DeviceModelScene.frontOutline(height: 400, aspect: 1.4, isClosed: true, roll: 0)
        XCTAssertEqual(closed.width, 280, accuracy: 1e-6, "only the outer panel faces the camera")
        let side = DeviceModelScene.frontOutline(height: 400, aspect: 1.4, isClosed: false, roll: .pi / 2)
        XCTAssertEqual(side.width, 400, accuracy: 1e-3, "held on its side the outline swaps its sides")
        XCTAssertEqual(side.height, 560, accuracy: 1e-3)
        let between = DeviceModelScene.frontOutline(height: 400, aspect: 1, isClosed: false, roll: .pi / 4)
        XCTAssertEqual(between.width, 400 * 2 / 2.0.squareRoot(), accuracy: 1e-3, "turning, the outline is the turned box's")
        XCTAssertEqual(
            DeviceModelScene.frontOutline(height: 400, aspect: 1.4, isClosed: false, roll: -.pi / 2).width, 400, accuracy: 1e-3,
            "either way round"
        )
    }

    func testAClosedDeviceCannotBeMovedAsFarSidewaysAsAnOpenOne() {
        let view = CGSize(width: 800, height: 600)
        let pan = CGSize(width: 900, height: 0)
        func moved(isClosed: Bool) -> CGFloat {
            DeviceModelScene.clampedPan(
                pan, view: view,
                outline: DeviceModelScene.frontOutline(height: 1200, aspect: 1.4, isClosed: isClosed, roll: 0)
            ).width
        }
        XCTAssertEqual(moved(isClosed: false), (1680 - 800) / 2, accuracy: 1e-6)
        XCTAssertEqual(moved(isClosed: true), (840 - 800) / 2, accuracy: 1e-6)
    }

    func testASceneCopiesPicturesUnlessItsWindowIsOffScreen() {
        XCTAssertTrue(DeviceModelScene.copiesFrames(hostWindowVisible: true))
        XCTAssertTrue(DeviceModelScene.copiesFrames(hostWindowVisible: nil), "no view yet (the model is still loading), or none in a window")
        XCTAssertFalse(DeviceModelScene.copiesFrames(hostWindowVisible: false), "the main window ordered out behind the compact one")
    }

    // MARK: - The stage's clip keeps the view's identity

    /// Counted from a `StateObject`'s initial value, which SwiftUI makes on
    /// the main thread.
    private final class Counter: @unchecked Sendable { var made = 0 }

    private final class Token: ObservableObject {
        init(_ counter: Counter) { counter.made += 1 }
    }

    /// Counts how many times SwiftUI makes it: a `StateObject` is made once
    /// for a view's identity.
    private struct Probe: View {
        @StateObject private var token: Token
        init(_ counter: Counter) { _token = StateObject(wrappedValue: Token(counter)) }
        var body: some View { Color.clear }
    }

    /// The modifier the stage had: a different view for each branch.
    private struct ConditionalClip: ViewModifier {
        let bleeds: Bool
        @ViewBuilder
        func body(content: Content) -> some View {
            if bleeds { content } else { content.clipped() }
        }
    }

    private func host<V: View>(_ view: V) -> NSHostingView<V> {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 300)
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        return hosting
    }

    func testTheStageClipDoesNotRebuildItsContentWhenTheBleedChanges() {
        let counter = Counter()
        func stage(_ bleed: CGSize) -> some View {
            Probe(counter).frame(width: 100, height: 100).modifier(StageClip(bleed: bleed))
        }
        let hosting = host(stage(.zero))
        XCTAssertEqual(counter.made, 1)
        for bleed in [CGSize(width: 10, height: 30), .zero, CGSize(width: 10, height: 30)] {
            hosting.rootView = stage(bleed)
            hosting.layoutSubtreeIfNeeded()
        }
        XCTAssertEqual(counter.made, 1, "View ▸ Show 3D Model flips the bleed: the model's view must stay")
    }

    func testAModifierThatChoosesBetweenClippedAndNotDoesRebuildItsContent() {
        // The probe sees what it is meant to: this is the modifier the stage
        // had before `StageClip`.
        let counter = Counter()
        func stage(_ bleeds: Bool) -> some View {
            Probe(counter).frame(width: 100, height: 100).modifier(ConditionalClip(bleeds: bleeds))
        }
        let hosting = host(stage(false))
        hosting.rootView = stage(true)
        hosting.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(counter.made, 1)
    }

    func testTheStageClipTakesTheFramesSizeWhateverItBleeds() {
        for bleed in [CGSize.zero, CGSize(width: 10, height: 30)] {
            let hosting = host(Color.red.frame(width: 100, height: 80).modifier(StageClip(bleed: bleed)))
            XCTAssertEqual(hosting.fittingSize.width, 100, accuracy: 0.5, "\(bleed)")
            XCTAssertEqual(hosting.fittingSize.height, 80, accuracy: 0.5, "\(bleed)")
        }
    }

    // MARK: - The compact window's stage

    private func compactStage(model: Bool) -> MirrorStageContent {
        CompactMirrorView.stageContent(
            session: FakeMirrorSession(), chrome: .vector, available: CGSize(width: 300, height: 400),
            showsFoldableModel: model
        )
    }

    func testTheCompactWindowDrawsAFoldableInTheModelOfItsOwnScene() {
        let stage = compactStage(model: true)
        XCTAssertTrue(stage.showsFoldableModel)
        XCTAssertEqual(stage.modelSurface, .compact, "the main window's scene is another entity tree")
        XCTAssertNil(stage.stageZoom, "the compact window has no zoom")
        XCTAssertEqual(stage.modelBleed, .zero)
        let flat = compactStage(model: false)
        XCTAssertFalse(flat.showsFoldableModel, "any other device stays as it was")
    }

    func testTheModelIsHeldTurnedByTheDevicesQuarterTurns() {
        let workspace = AppModel.testing().workspace
        XCTAssertEqual(workspace.foldModelRoll, 0)
        workspace.simulatorCanvas.devicePose.beginRotation(.left)
        XCTAssertEqual(workspace.foldModelRoll, 1)
        workspace.simulatorCanvas.devicePose.beginRotation(.left)
        XCTAssertEqual(workspace.foldModelRoll, 2)
        workspace.simulatorCanvas.devicePose.beginRotation(.right)
        workspace.simulatorCanvas.devicePose.beginRotation(.right)
        workspace.simulatorCanvas.devicePose.beginRotation(.right)
        XCTAssertEqual(workspace.foldModelRoll, 3, "a quarter turn the other way is three the first way")
    }
}

/// The compact window round a foldable: Device Hub's one frame, whatever the
/// device does, the model fitted as the main stage fits it, and the one size
/// the user gives it kept.
@MainActor
final class CompactDuoLayoutTests: XCTestCase {
    private func window() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 400, y: 300, width: 100, height: 100),
            styleMask: [.titled, .resizable], backing: .buffered, defer: true
        )
        window.isReleasedWhenClosed = false
        return window
    }

    /// Posts the end of a live resize, which the sizer reads on the main
    /// queue after this turn.
    private func dragEnds(_ window: NSWindow, at size: CGSize, sizer: CompactWindowSizer, expecting expected: CGSize?) async throws {
        window.setFrame(NSRect(origin: window.frame.origin, size: size), display: false)
        NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window)
        for _ in 0..<100 where expected != nil && sizer.size(foldable: true, on: nil) != expected {
            try await Task.sleep(for: .milliseconds(20))
        }
        // A drag that is not to be kept: give the observer its turn.
        if expected == nil { try await Task.sleep(for: .milliseconds(100)) }
    }

    func testAFoldablesWindowOpensAtDeviceHubs696By784() {
        XCTAssertEqual(ParityMetrics.compactFoldableWindowSize, CGSize(width: 696, height: 784), "Xcode 27.1 RC, measured")
        XCTAssertEqual(CompactDuoLayout.windowSize(), CGSize(width: 696, height: 784))
        XCTAssertEqual(CompactWindowSizer().size(foldable: true, on: nil), CGSize(width: 696, height: 784))
    }

    func testEveryOtherDeviceKeepsDeviceHubs258By587() {
        XCTAssertEqual(CompactWindowSizer().size(foldable: false, on: nil), CGSize(width: 258, height: 587))
        XCTAssertEqual(CompactMirrorWindow.frameSize, CGSize(width: 258, height: 587))
    }

    func testAWindowTooLargeForTheScreenIsCutDownToIt() {
        XCTAssertEqual(
            CompactDuoLayout.windowSize(limit: CGSize(width: 1000, height: 500)), CGSize(width: 696, height: 500)
        )
        XCTAssertEqual(
            CompactDuoLayout.windowSize(limit: CGSize(width: 600, height: 900)), CGSize(width: 600, height: 784)
        )
        XCTAssertEqual(
            CompactDuoLayout.windowSize(limit: CGSize(width: 100, height: 100)), CompactMirrorWindow.minimumSize,
            "never under the window's minimum"
        )
        XCTAssertEqual(CompactDuoLayout.windowSize(limit: CGSize(width: 1728, height: 1080)), CGSize(width: 696, height: 784))
    }

    func testTheModelIsTheMainStagesFrontFitOnTheCompactStage() throws {
        // The stage is the frame less the toolbar band, plus the overlap
        // under it, less the pill band (`CompactMirrorView`).
        let frame = ParityMetrics.compactFoldableWindowSize
        let stage = CGSize(
            width: frame.width,
            height: frame.height - CompactMirrorWindow.toolbarHeight + ParityMetrics.compactStageTopOverlap
                - ParityMetrics.compactStagePillBand
        )
        XCTAssertEqual(stage.height, 693.5)
        let model = MirrorStageContent.frontModel(outerFrame: try AppleChromeStageTests.iPhone17ProFrame(), available: stage)
        XCTAssertEqual(model.height, min(693.5 * MirrorStageContent.frontFitHeight, 696 * MirrorStageContent.frontFitWidth))
        XCTAssertEqual(model.height, 379, accuracy: 1, "Device Hub draws it about 379 pt tall closed in that window")
        // The stage's width is what bounds it (as in a main window of that
        // shape), which leaves the open device (about 494 x 382 pt in Device
        // Hub) room round it.
        XCTAssertLessThan(stage.width * MirrorStageContent.frontFitWidth, stage.height * MirrorStageContent.frontFitHeight)
        XCTAssertLessThan(494, stage.width - 2 * 100, "room either side of the open device")
    }

    func testTheWindowNeverChangesSizeAsTheDeviceFoldsOrTurns() {
        let sizer = CompactWindowSizer()
        let window = window()
        defer { window.close() }
        let size = sizer.size(foldable: true, on: window.screen)
        window.setFrame(NSRect(origin: window.frame.origin, size: size), display: false)
        sizer.noteInitial(foldable: true, window: window)
        let frame = window.frame
        // Folding, unfolding and turning keep the window a foldable's: the
        // sizer has nothing to do, and a window left alone is not touched.
        for _ in 0..<5 {
            XCTAssertFalse(sizer.needsFit(foldable: true))
            sizer.fit(window, foldable: true)
        }
        XCTAssertEqual(window.frame, frame)
        XCTAssertEqual(window.frame.size, size)
    }

    func testTheSizerKeepsTheOneSizeTheUserGaveAndNothingElse() async throws {
        let sizer = CompactWindowSizer()
        let window = window()
        defer { window.close() }
        window.setFrame(NSRect(origin: window.frame.origin, size: sizer.size(foldable: true, on: window.screen)), display: false)
        sizer.noteInitial(foldable: true, window: window)

        // The user drags the foldable's window to another size.
        let chosen = CGSize(width: 520, height: 640)
        try await dragEnds(window, at: chosen, sizer: sizer, expecting: chosen)
        XCTAssertEqual(sizer.size(foldable: true, on: nil), chosen)

        // The device no longer shows the model: Device Hub's size, keeping
        // the top edge and the middle of the width.
        let top = window.frame.maxY, middle = window.frame.midX
        sizer.fit(window, foldable: false)
        XCTAssertEqual(window.frame.size, CompactMirrorWindow.frameSize)
        XCTAssertEqual(window.frame.maxY, top, accuracy: 0.5)
        XCTAssertEqual(window.frame.midX, middle, accuracy: 0.5)

        // A drag of that window is not the foldable's size.
        try await dragEnds(window, at: CGSize(width: 300, height: 600), sizer: sizer, expecting: nil)
        XCTAssertEqual(sizer.size(foldable: true, on: nil), chosen)
        XCTAssertEqual(sizer.size(foldable: false, on: nil), CompactMirrorWindow.frameSize)

        // The foldable again: the user's size, not a fight over it.
        sizer.fit(window, foldable: true)
        XCTAssertEqual(window.frame.size, chosen)
    }
}
