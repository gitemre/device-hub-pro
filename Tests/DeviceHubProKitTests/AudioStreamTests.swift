import XCTest
@testable import DeviceHubProKit

/// The stream's port is `EmulatorManager.unreachableGrpcPort` (0): nothing
/// can listen on it, so the audio stream fails at once and keeps
/// reconnecting, and no process on the Mac receives its requests.
final class AudioStreamTests: XCTestCase {
    private static let port = EmulatorManager.unreachableGrpcPort

    private func waitUntil(timeout: TimeInterval = 4, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    func testAFailedStreamIsRetriedAndReported() async {
        let stream = AudioStream(port: Self.port)
        stream.start { _ in }
        defer { stream.stop() }

        let retried = await waitUntil { stream.attempts >= 2 }
        XCTAssertTrue(retried, "a dropped audio stream must reconnect, not stay silent")
        XCTAssertNotNil(stream.lastError)
    }

    func testStopEndsTheReconnectLoop() async throws {
        let stream = AudioStream(port: Self.port)
        stream.start { _ in }
        _ = await waitUntil { stream.attempts >= 1 }
        stream.stop()
        try await Task.sleep(for: .milliseconds(100))
        let attempts = stream.attempts
        try await Task.sleep(for: .seconds(1.2))
        XCTAssertEqual(stream.attempts, attempts)
    }

    func testDroppingTheStreamEndsItsTask() async {
        weak var weakStream: AudioStream?
        do {
            let stream = AudioStream(port: Self.port)
            stream.start { _ in }
            weakStream = stream
        }
        let released = await waitUntil { weakStream == nil }
        XCTAssertTrue(released, "the streaming task must not keep the stream alive")
    }

    func testOnlyTheRequestedPCMFormatIsPlayed() {
        XCTAssertTrue(AudioStream.matchesRequestedFormat(AudioStream.requestedFormat))
        XCTAssertTrue(
            AudioStream.matchesRequestedFormat(.init()),
            "a packet without format information is the requested format"
        )

        var slower = AudioStream.requestedFormat
        slower.samplingRate = 44_100
        XCTAssertFalse(AudioStream.matchesRequestedFormat(slower))

        var mono = AudioStream.requestedFormat
        mono.channels = .mono
        XCTAssertFalse(AudioStream.matchesRequestedFormat(mono))

        var eightBit = AudioStream.requestedFormat
        eightBit.format = .audFmtU8
        XCTAssertFalse(AudioStream.matchesRequestedFormat(eightBit))
    }
}
