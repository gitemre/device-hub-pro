import AVFoundation
import XCTest
@testable import DeviceHubProApp
import DeviceHubProKit

/// In-app audio (F11): the PCM is converted to the engine's standard float
/// format, the queue is bounded, and stream failures are surfaced instead of
/// swallowed. Engine start and route changes need real audio hardware and
/// are covered by the live check.
@MainActor
final class AudioPlayerTests: XCTestCase {
    func testPCMIsConvertedToDeinterleavedFloat() throws {
        // Two frames, interleaved L/R little-endian S16.
        let samples: [Int16] = [Int16.max, Int16.min, 16384, -16384]
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }

        let buffer = try XCTUnwrap(AudioPlayer.makeBuffer(from: data))

        XCTAssertEqual(buffer.format, AudioPlayer.format)
        XCTAssertEqual(buffer.format.commonFormat, .pcmFormatFloat32)
        XCTAssertFalse(buffer.format.isInterleaved)
        XCTAssertEqual(buffer.frameLength, 2)
        let channels = try XCTUnwrap(buffer.floatChannelData)
        XCTAssertEqual(channels[0][0], Float(Int16.max) / 32768, accuracy: 1e-6)
        XCTAssertEqual(channels[1][0], -1, accuracy: 1e-6)
        XCTAssertEqual(channels[0][1], 0.5, accuracy: 1e-6)
        XCTAssertEqual(channels[1][1], -0.5, accuracy: 1e-6)
    }

    func testUnalignedChunksConvertTheSame() throws {
        // A chunk sliced out of a larger Data can start at an odd address.
        let samples: [Int16] = [1000, -1000, 32767, -32768]
        var bytes = Data([0xAA])
        bytes.append(samples.withUnsafeBufferPointer { Data(buffer: $0) })
        let unaligned = bytes.dropFirst()

        let buffer = try XCTUnwrap(AudioPlayer.makeBuffer(from: unaligned))

        let channels = try XCTUnwrap(buffer.floatChannelData)
        XCTAssertEqual(channels[0][0], 1000 / 32768, accuracy: 1e-6)
        XCTAssertEqual(channels[1][0], -1000 / 32768, accuracy: 1e-6)
        XCTAssertEqual(channels[0][1], 32767 / 32768, accuracy: 1e-6)
        XCTAssertEqual(channels[1][1], -1, accuracy: 1e-6)
    }

    func testOnlyExactZerosCountAsSilence() {
        XCTAssertTrue(AudioPlayer.isSilent(Data(count: 1920)))
        XCTAssertTrue(AudioPlayer.isSilent(Data(count: 13)), "a tail shorter than a word is scanned too")
        var lastByte = Data(count: 1921)
        lastByte[1920] = 1
        XCTAssertFalse(AudioPlayer.isSilent(lastByte))
        var firstWord = Data(count: 64)
        firstWord[3] = 0x80
        XCTAssertFalse(AudioPlayer.isSilent(firstWord))
    }

    func testLessThanOneFrameMakesNoBuffer() {
        XCTAssertNil(AudioPlayer.makeBuffer(from: Data([0x01, 0x02])))
        XCTAssertNil(AudioPlayer.makeBuffer(from: Data()))
    }

    func testTheFormatMatchesTheStream() {
        XCTAssertEqual(AudioPlayer.format.sampleRate, Double(AudioStream.sampleRate))
        XCTAssertEqual(Int(AudioPlayer.format.channelCount), AudioStream.channelCount)
    }

    func testQueueIsBoundedAndReleasedAsBuffersPlay() {
        let queued = QueuedFrames()
        let limit = AudioPlayer.maxQueuedFrames

        XCTAssertTrue(queued.reserve(limit - 100, limit: limit))
        XCTAssertFalse(queued.reserve(200, limit: limit), "past ~200 ms new chunks are dropped")
        queued.release(limit - 100)
        XCTAssertTrue(queued.reserve(200, limit: limit))
        XCTAssertEqual(queued.count, 200)
    }

    func testAnOversizedChunkStillPlaysWhenNothingIsQueued() {
        let queued = QueuedFrames()
        XCTAssertTrue(queued.reserve(AudioPlayer.maxQueuedFrames * 2, limit: AudioPlayer.maxQueuedFrames))
    }

    func testStreamFailureIsReportedOnceAndNotSwallowed() {
        let player = AudioPlayer()
        var reported: [String] = []
        player.onProblem = { reported.append($0) }

        player.noteStreamError("audio: the emulator ended the stream")
        player.noteStreamError("audio: the emulator ended the stream")

        XCTAssertEqual(player.problem, "audio: the emulator ended the stream")
        XCTAssertEqual(reported, ["audio: the emulator ended the stream"])
    }

    func testStoppingClearsTheProblem() {
        let player = AudioPlayer()
        player.noteStreamError("audio: unavailable")

        player.stop()

        XCTAssertNil(player.problem)
        XCTAssertFalse(player.isRunning)
    }
}
