import AVFoundation
import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// How the phone's audio is adapted to the engine: any linear PCM format the
/// capture delivers becomes the standard Float32 format at the same rate. No
/// engine and no audio device is touched.
final class PhysicalAudioAdapterTests: XCTestCase {
    private func int16Chunk(
        _ samples: [Int16], channels: AVAudioChannelCount, rate: Double = 48_000, interleaved: Bool = true
    ) throws -> PhysicalAudioChunk {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: rate, channels: channels, interleaved: interleaved
        ))
        let frames = samples.count / Int(channels)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = try XCTUnwrap(buffer.int16ChannelData)
        if interleaved {
            for (index, sample) in samples.enumerated() { data[0][index] = sample }
        } else {
            for frame in 0..<frames {
                for channel in 0..<Int(channels) { data[channel][frame] = samples[frame * Int(channels) + channel] }
            }
        }
        return PhysicalAudioChunk(buffer: buffer)
    }

    func testInterleavedInt16StereoBecomesDeinterleavedFloat() throws {
        let adapter = PhysicalAudioAdapter()
        let out = try XCTUnwrap(adapter.adapt(try int16Chunk([16384, -16384, 8192, -8192], channels: 2)))
        XCTAssertEqual(out.format.commonFormat, .pcmFormatFloat32)
        XCTAssertFalse(out.format.isInterleaved)
        XCTAssertEqual(out.format.channelCount, 2)
        XCTAssertEqual(out.format.sampleRate, 48_000, "the mixer resamples; the adapter keeps the rate")
        XCTAssertEqual(out.frameLength, 2)
        let left = try XCTUnwrap(out.floatChannelData)[0]
        let right = try XCTUnwrap(out.floatChannelData)[1]
        XCTAssertEqual(left[0], 0.5, accuracy: 0.001)
        XCTAssertEqual(right[0], -0.5, accuracy: 0.001)
        XCTAssertEqual(left[1], 0.25, accuracy: 0.001)
        XCTAssertEqual(right[1], -0.25, accuracy: 0.001)
    }

    func testMonoAt44100StaysMonoAt44100() throws {
        let adapter = PhysicalAudioAdapter()
        let out = try XCTUnwrap(adapter.adapt(try int16Chunk([32767, 0, -32768], channels: 1, rate: 44_100)))
        XCTAssertEqual(out.format.channelCount, 1)
        XCTAssertEqual(out.format.sampleRate, 44_100)
        XCTAssertEqual(out.frameLength, 3)
    }

    func testAChunkAlreadyInTheStandardFormatPassesThroughUntouched() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        let adapter = PhysicalAudioAdapter()
        let out = try XCTUnwrap(adapter.adapt(PhysicalAudioChunk(buffer: buffer)))
        XCTAssertTrue(out === buffer)
    }

    /// The phone changes its rate (a call, another route): the adapter builds
    /// a new converter and the playback format follows.
    func testAFormatChangeIsFollowed() throws {
        let adapter = PhysicalAudioAdapter()
        let first = try XCTUnwrap(adapter.adapt(try int16Chunk([1, 2, 3, 4], channels: 2, rate: 48_000)))
        let second = try XCTUnwrap(adapter.adapt(try int16Chunk([1, 2, 3, 4], channels: 2, rate: 44_100)))
        let third = try XCTUnwrap(adapter.adapt(try int16Chunk([1, 2, 3, 4], channels: 2, rate: 44_100)))
        XCTAssertEqual(first.format.sampleRate, 48_000)
        XCTAssertEqual(second.format.sampleRate, 44_100)
        XCTAssertEqual(third.format, second.format)
    }

    func testAnEmptyChunkIsDropped() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 2, interleaved: true))
        let empty = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        XCTAssertNil(PhysicalAudioAdapter().adapt(PhysicalAudioChunk(buffer: empty)), "zero frames")
    }

    func testThePlaybackFormatCapsAtStereo() throws {
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Quadraphonic))
        let surround = AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: layout)
        XCTAssertEqual(PhysicalAudioAdapter.playbackFormat(for: surround)?.channelCount, 2)
    }
}

/// The player's own contract, without an engine: chunks and switches on a
/// player that is not playing touch nothing, and every method is safe from
/// any thread and in any order.
final class PhysicalAudioPlayerTests: XCTestCase {
    private func chunk() throws -> PhysicalAudioChunk {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        buffer.frameLength = 480
        return PhysicalAudioChunk(buffer: buffer)
    }

    /// A player that was never switched on drops chunks before the engine:
    /// nothing here would reach an audio device (the engine is made lazily,
    /// on the first chunk of a playing player).
    func testAPlayerThatIsNotPlayingDropsChunksAndStopsCleanly() throws {
        let player = PhysicalAudioPlayer()
        for _ in 0..<50 { player.play(try chunk()) }
        player.setPlaying(false)
        player.stop()
        player.stop()
        // Drained: a barrier on the player's own queue.
        let done = expectation(description: "queue drained")
        DispatchQueue.global().async {
            player.setPlaying(false)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testTheQueueBoundIsTwoHundredMilliseconds() {
        XCTAssertEqual(PhysicalAudioPlayer.maxQueuedSeconds, 0.2)
        let queued = QueuedFrames()
        let limit = Int(48_000 * PhysicalAudioPlayer.maxQueuedSeconds)
        XCTAssertTrue(queued.reserve(limit, limit: limit))
        XCTAssertFalse(queued.reserve(480, limit: limit), "a stalled output drops chunks instead of building a delay")
        queued.release(limit)
        XCTAssertTrue(queued.reserve(480, limit: limit))
    }

    @MainActor
    func testTheRealPlayerIsTheDefaultSink() {
        let controller = PhysicalLiveViewController(provider: InertScreenCaptureProvider())
        XCTAssertTrue(controller.makeAudioSink() is PhysicalAudioPlayer)
    }
}
