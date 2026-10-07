import AVFoundation
import CoreMedia
import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// The simulator's replay ring against a real simulator, behind
/// `DHP_IOS_LIVE=1`:
///
///     DHP_IOS_LIVE=1 swift test --filter SimulatorReplayLiveTests
///
/// It creates its own iPhone in a private device set (`LiveTestSimulators`),
/// boots it, runs the live canvas (`SimulatorMirrorSession`) for a few
/// seconds, feeds its frames to a `ReplayBuffer` the way the frame feed does
/// (scaled to fit 1080 x 1920, 15 fps), saves the replay and checks that the
/// .mp4 plays for more than a second. The device, its set and its log folder
/// are deleted afterwards.
final class SimulatorReplayLiveTests: XCTestCase {
    func testTheLiveCanvasFillsAReplayRingThatSavesAPlayableClip() async throws {
        let toolchain = try await LiveTestSimulators.toolchain()
        let installed = BridgeCompatibility.installedCoreSimulatorVersion()
        guard BridgeCompatibility.verdict(coreSimulatorVersion: installed).allowsBridge else {
            throw XCTSkip("the bridge is off on CoreSimulator \(installed ?? "?")")
        }
        let simulators = try LiveTestSimulators.Session(toolchain: toolchain)
        do {
            try await exercise(simulators)
        } catch {
            let leftovers = await simulators.tearDown()
            XCTAssertEqual(leftovers, [])
            throw error
        }
        let leftovers = await simulators.tearDown()
        XCTAssertEqual(leftovers, [])
    }

    private func exercise(_ simulators: LiveTestSimulators.Session) async throws {
        let device = try await simulators.createDevice(name: "DeviceHubPro-ReplayLive")
        let udid = device.udid
        try await simulators.simctl.bootStatus(udid: udid, bootIfNeeded: true)
        try await Task.sleep(for: .seconds(10))

        let session = SimulatorMirrorSession(
            udid: udid,
            deviceSet: simulators.setDirectory,
            bridge: LiveSimulatorBridge(),
            simctl: simulators.simctl
        )
        defer { session.stopAndWait() }
        session.start()
        var waited = 0
        while session.frames.current == nil, waited < 100 {
            try await Task.sleep(for: .milliseconds(50))
            waited += 1
        }
        let first = try XCTUnwrap(session.frames.current, "a frame after start: \(session.lastError ?? "")")

        let size = ReplaySupport.encodedSize(width: first.width, height: first.height, kind: .simulatorLive)
        let buffer = ReplayBuffer(windowSeconds: 30, targetFPS: 15, width: size.width, height: size.height)
        let pool = BGRAPixelBufferPool(width: size.width, height: size.height)
        let cpuStart = ProcessInfo.processInfo.systemUptime
        let started = Date()
        // About 4 s at the feed's 66 ms cadence; the screen is mostly
        // static, so frames are offered again (the encoder keeps its pace).
        var offered = 0
        while Date().timeIntervalSince(started) < 4.5 {
            if let frame = session.frames.current,
               let source = frame.pixelBuffer,
               let scaled = MediaCaptureController.scaledBGRA(source, width: size.width, height: size.height, pool: pool) {
                buffer.ingest(scaled, at: CMTime(seconds: ProcessInfo.processInfo.systemUptime, preferredTimescale: 600))
                offered += 1
            }
            try await Task.sleep(for: .milliseconds(66))
        }
        print("REPLAY-LIVE offered \(offered) frames at \(size.width)x\(size.height) over \(ProcessInfo.processInfo.systemUptime - cpuStart) s; retained \(buffer.retainedFrameCount) frames, \(buffer.retainedByteCount) bytes")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devicehubpro-replay-live-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clip = try await buffer.saveClip(to: directory)
        let duration = try await AVURLAsset(url: clip).load(.duration).seconds
        print("REPLAY-LIVE clip duration \(duration) s")
        XCTAssertGreaterThan(duration, 1.0)
    }
}
