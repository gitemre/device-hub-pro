import XCTest
@testable import DeviceHubProApp
import DeviceHubProKit

/// When a physical mirror's clean stats polls end its reconnect episode.
final class MirrorHealthGateTests: XCTestCase {
    private let framed = MirrorStats(fps: 0, totalFrames: 12, dropped: 0, averageLatencyMs: 0)
    private let flowing = MirrorStats(fps: 30, totalFrames: 0, dropped: 0, averageLatencyMs: 0)
    private let silent = MirrorStats(fps: 0, totalFrames: 0, dropped: 0, averageLatencyMs: 0)

    func testAFrameEndsTheEpisodeOnTheFirstPoll() {
        var gate = MirrorHealthGate()
        XCTAssertTrue(gate.noteCleanPoll(framed))
        XCTAssertTrue(gate.reported)
        XCTAssertEqual(gate.cleanPolls, 1)

        var fpsOnly = MirrorHealthGate()
        XCTAssertTrue(fpsOnly.noteCleanPoll(flowing), "a frame rate is frame evidence too")
    }

    func testWithoutFramesTheSecondCleanPollEndsIt() {
        var gate = MirrorHealthGate()
        XCTAssertFalse(gate.noteCleanPoll(silent))
        XCTAssertFalse(gate.reported)
        XCTAssertTrue(gate.noteCleanPoll(silent))
        XCTAssertTrue(gate.reported)
        XCTAssertEqual(gate.cleanPolls, 2)
    }

    func testTheEpisodeEndsExactlyOnce() {
        var gate = MirrorHealthGate()
        XCTAssertTrue(gate.noteCleanPoll(framed))
        XCTAssertFalse(gate.noteCleanPoll(framed))
        XCTAssertFalse(gate.noteCleanPoll(silent))
        XCTAssertEqual(gate.cleanPolls, 1, "it stops counting once health is reported")
    }

    func testAResetStartsTheNextSessionOver() {
        var gate = MirrorHealthGate()
        XCTAssertFalse(gate.noteCleanPoll(silent))
        XCTAssertTrue(gate.noteCleanPoll(silent))
        gate.reset()
        XCTAssertEqual(gate, MirrorHealthGate())
        XCTAssertFalse(gate.noteCleanPoll(silent), "a new session needs its own two polls")
        XCTAssertTrue(gate.noteCleanPoll(silent))
    }

    func testTheSignalRule() {
        XCTAssertTrue(MirrorHealthGate.signalReached(stats: framed, cleanPolls: 1))
        XCTAssertFalse(MirrorHealthGate.signalReached(stats: silent, cleanPolls: 1))
        XCTAssertTrue(MirrorHealthGate.signalReached(stats: silent, cleanPolls: 2))
        XCTAssertTrue(MirrorHealthGate.signalReached(stats: silent, cleanPolls: 6))
    }

    // MARK: - Parity with today's AppModel

    /// Pins the model's names for the gate (`noteCleanStatsPoll`,
    /// `mirrorHealthyPolls`, `mirrorHealthReported`, `healthSignalReached`)
    /// to the core the stats loop runs through.
    @MainActor
    func testTheGateCountsLikeTheModel() {
        for polls in [[silent, silent, silent], [framed, silent], [silent, framed, framed], [flowing]] {
            let model = AppModel.testing()
            var gate = MirrorHealthGate()
            for stats in polls {
                model.workspace.mirror.noteCleanStatsPoll(serial: "HT4CWJT01234", stats: stats)
                _ = gate.noteCleanPoll(stats)
                XCTAssertEqual(model.workspace.mirror.healthGate.cleanPolls, gate.cleanPolls)
                XCTAssertEqual(model.workspace.mirror.healthGate.reported, gate.reported)
            }
        }
        for stats in [framed, flowing, silent] {
            for polls in 0...3 {
                XCTAssertEqual(
                    MirrorHealthGate.signalReached(stats: stats, cleanPolls: polls),
                    MirrorHealthGate.signalReached(stats: stats, cleanPolls: polls)
                )
            }
        }
    }
}
