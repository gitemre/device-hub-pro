import CoreMedia
import CoreVideo
import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// Which devices offer Save Replay, the simulator ring's frame size, the
/// feed's pause, and the one-time tip (`ReplaySupport`,
/// `MediaCaptureController.noteCaptureTaken`).
@MainActor
final class ReplaySupportTests: XCTestCase {
    // MARK: - Visibility per device kind

    func testOnlyAndroidAndTheLiveSimulatorCanvasOfferReplay() {
        for kind in [ReplaySupport.DeviceKind.android, .simulatorLive] {
            XCTAssertTrue(ReplaySupport.isOffered(kind: kind, enabled: true), "\(kind)")
            XCTAssertFalse(ReplaySupport.isOffered(kind: kind, enabled: false), "\(kind) with the switch off")
        }
        for kind in [ReplaySupport.DeviceKind.none, .simulatorViewOnly, .physicalApple] {
            XCTAssertFalse(ReplaySupport.isOffered(kind: kind, enabled: true), "\(kind)")
        }
    }

    private func makeMedia(configure: (ActiveDeviceContext) -> Void) -> MediaCaptureController {
        let status = StatusCenter()
        let picker = TestPicker()
        let context = ActiveDeviceContext()
        configure(context)
        return MediaCaptureController(
            preferences: AppPreferences(defaults: .scratch()),
            status: status,
            context: context,
            finalizer: RecordingFinalizer(status: status, picker: picker),
            picker: picker
        )
    }

    func testTheControllerMapsTheMirroredDeviceToItsKind() {
        XCTAssertEqual(makeMedia { _ in }.replayDeviceKind, .none)
        XCTAssertEqual(makeMedia { $0.serial = "emulator-5554" }.replayDeviceKind, .android)

        let live = makeMedia { $0.device = .apple("UDID-1") }
        XCTAssertEqual(live.replayDeviceKind, .simulatorLive)
        XCTAssertTrue(live.offersReplay)

        let viewOnly = makeMedia { $0.device = .apple("UDID-1") }
        viewOnly.simulatorIsLiveCanvas = { false }
        XCTAssertEqual(viewOnly.replayDeviceKind, .simulatorViewOnly)
        XCTAssertFalse(viewOnly.offersReplay)

        let physical = makeMedia {
            $0.device = .apple("UDID-2")
            $0.isPhysicalView = true
        }
        XCTAssertEqual(physical.replayDeviceKind, .physicalApple)
        XCTAssertFalse(physical.offersReplay)
    }

    func testTheButtonIsDisabledUntilTheRingHasFrames() {
        let media = makeMedia { $0.serial = "emulator-5554" }
        XCTAssertFalse(media.canSaveReplayNow, "no ring yet")
    }

    // MARK: - Encoded size

    func testASimulatorFrameIsScaledToFit1080By1920AndAndroidKeepsItsSize() {
        let big = ReplaySupport.encodedSize(width: 1206, height: 2622, kind: .simulatorLive)
        XCTAssertLessThanOrEqual(max(big.width, big.height), 1920)
        XCTAssertLessThanOrEqual(min(big.width, big.height), 1080)
        XCTAssertEqual(big.width % 2, 0)
        XCTAssertEqual(big.height % 2, 0)
        XCTAssertEqual(Double(big.width) / Double(big.height), 1206.0 / 2622.0, accuracy: 0.01)

        let landscape = ReplaySupport.encodedSize(width: 2622, height: 1206, kind: .simulatorLive)
        XCTAssertEqual(landscape.width, big.height)
        XCTAssertEqual(landscape.height, big.width)

        let small = ReplaySupport.encodedSize(width: 750, height: 1334, kind: .simulatorLive)
        XCTAssertTrue(small.width == 750 && small.height == 1334, "never scaled up")
        let android = ReplaySupport.encodedSize(width: 1440, height: 3120, kind: .android)
        XCTAssertTrue(android.width == 1440 && android.height == 3120)
    }

    func testScaledBGRAProducesTheRequestedSize() throws {
        let source = try XCTUnwrap(BGRAPixelBufferPool.makeUnpooledBuffer(width: 400, height: 800))
        CVPixelBufferLockBaseAddress(source, [])
        if let base = CVPixelBufferGetBaseAddress(source) {
            memset(base, 0x7F, CVPixelBufferGetBytesPerRow(source) * 800)
        }
        CVPixelBufferUnlockBaseAddress(source, [])
        let pool = BGRAPixelBufferPool(width: 200, height: 400)
        let scaled = try XCTUnwrap(MediaCaptureController.scaledBGRA(source, width: 200, height: 400, pool: pool))
        XCTAssertEqual(CVPixelBufferGetWidth(scaled), 200)
        XCTAssertEqual(CVPixelBufferGetHeight(scaled), 400)
        CVPixelBufferLockBaseAddress(scaled, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(scaled, .readOnly) }
        let byte = CVPixelBufferGetBaseAddress(scaled)?.load(fromByteOffset: 4 * 100 + 4 * 200 * 100, as: UInt8.self)
        XCTAssertEqual(byte, 0x7F)
    }

    // MARK: - Feed pause

    func testAHiddenStagePausesTheRingUnlessARecordingNeedsTheFeed() {
        XCTAssertTrue(ReplaySupport.feedsRing(isStageVisible: true, isRecording: false))
        XCTAssertFalse(ReplaySupport.feedsRing(isStageVisible: false, isRecording: false))
        XCTAssertTrue(ReplaySupport.feedsRing(isStageVisible: false, isRecording: true))
    }

    // MARK: - One-time tip

    func testTheTipShowsOnceOnADeviceWithAReplayRingAndIsPersisted() throws {
        let defaults = UserDefaults.scratch()
        let status = StatusCenter()
        let picker = TestPicker()
        let context = ActiveDeviceContext()
        context.serial = "emulator-5554"
        func makeController() -> MediaCaptureController {
            MediaCaptureController(
                preferences: AppPreferences(defaults: defaults),
                status: status,
                context: context,
                finalizer: RecordingFinalizer(status: status, picker: picker),
                picker: picker
            )
        }

        let first = makeController()
        XCTAssertFalse(first.replayHintVisible)
        first.noteCaptureTaken()
        XCTAssertTrue(first.replayHintVisible, "the first capture shows the tip")
        XCTAssertTrue(first.replayHintText.hasPrefix("Missed a bug?"))

        first.replayHintVisible = false
        first.noteCaptureTaken()
        XCTAssertFalse(first.replayHintVisible, "never again")

        let relaunched = makeController()
        relaunched.noteCaptureTaken()
        XCTAssertFalse(relaunched.replayHintVisible, "persisted across launches")
    }

    func testTheTipIsNotUsedUpOnADeviceWithoutAReplayRing() {
        let media = makeMedia { $0.device = .apple("UDID-2"); $0.isPhysicalView = true }
        media.noteCaptureTaken()
        XCTAssertFalse(media.replayHintVisible)
        media.simulatorIsLiveCanvas = { true }
        // Switching to a device that keeps a ring still shows it later.
        let android = makeMedia { $0.serial = "emulator-5554" }
        android.noteCaptureTaken()
        XCTAssertTrue(android.replayHintVisible)
    }

    func testSavedReplayBannerIsTitledReplaySaved() {
        let shot = SavedScreenshot(url: URL(fileURLWithPath: "/tmp/x.mp4"), thumbnail: nil, kind: .replay)
        XCTAssertEqual(shot.title, "Replay Saved")
    }
}
