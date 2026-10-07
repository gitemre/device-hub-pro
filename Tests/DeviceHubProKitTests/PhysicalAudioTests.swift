import AVFoundation
import CoreMedia
import Synchronization
import XCTest
@testable import DeviceHubProKit

/// Builds the sample buffers an `AVCaptureAudioDataOutput` delivers, from
/// plain sample arrays: never a capture device.
enum AudioSampleBuffers {
    /// Interleaved linear PCM sample buffer of `bytes` in `format`.
    static func make(format: AVAudioFormat, frames: Int, bytes: [UInt8]) -> CMSampleBuffer {
        var stream = format.streamDescription.pointee
        var description: CMAudioFormatDescription?
        precondition(CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &stream, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description
        ) == noErr)
        var block: CMBlockBuffer?
        precondition(CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: bytes.count, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: bytes.count,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        ) == noErr)
        precondition(CMBlockBufferReplaceDataBytes(
            with: bytes, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes.count
        ) == noErr)
        var sample: CMSampleBuffer?
        precondition(CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block!, formatDescription: description!,
            sampleCount: frames, presentationTimeStamp: .zero, packetDescriptions: nil,
            sampleBufferOut: &sample
        ) == noErr)
        return sample!
    }

    /// Interleaved Int16 stereo at `sampleRate`.
    static func int16Stereo(_ samples: [Int16], sampleRate: Double = 48_000) -> CMSampleBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 2, interleaved: true)!
        let bytes = samples.flatMap { sample in withUnsafeBytes(of: sample.littleEndian) { Array($0) } }
        return make(format: format, frames: samples.count / 2, bytes: bytes)
    }

    /// Interleaved Float32 mono at `sampleRate`.
    static func floatMono(_ samples: [Float], sampleRate: Double = 44_100) -> CMSampleBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: true)!
        let bytes = samples.flatMap { sample in withUnsafeBytes(of: sample) { Array($0) } }
        return make(format: format, frames: samples.count, bytes: bytes)
    }
}

/// A sink that records what it was told.
final class FakeAudioSink: PhysicalAudioSink, @unchecked Sendable {
    private let state = Mutex((played: 0, stops: 0, playing: [Bool]()))
    var playedCount: Int { state.withLock { $0.played } }
    var stopCount: Int { state.withLock { $0.stops } }
    var playingCalls: [Bool] { state.withLock { $0.playing } }
    func play(_ chunk: PhysicalAudioChunk) { state.withLock { $0.played += 1 } }
    func setPlaying(_ playing: Bool) { state.withLock { $0.playing.append(playing) } }
    func stop() { state.withLock { $0.stops += 1 } }
}

/// What the capture's audio output hands the app: the sample buffer's linear
/// PCM, in the device's own format, as an `AVAudioPCMBuffer`.
final class PhysicalAudioChunkTests: XCTestCase {
    func testAnInt16StereoSampleBufferKeepsItsFormatAndSamples() throws {
        let samples: [Int16] = [100, -100, 200, -200, 300, -300]
        let chunk = try XCTUnwrap(PhysicalAudioChunk(sampleBuffer: AudioSampleBuffers.int16Stereo(samples)))
        let buffer = chunk.buffer
        XCTAssertEqual(buffer.format.commonFormat, .pcmFormatInt16)
        XCTAssertEqual(buffer.format.channelCount, 2)
        XCTAssertEqual(buffer.format.sampleRate, 48_000)
        XCTAssertTrue(buffer.format.isInterleaved)
        XCTAssertEqual(buffer.frameLength, 3)
        let data = try XCTUnwrap(buffer.int16ChannelData)[0]
        XCTAssertEqual(Array(UnsafeBufferPointer(start: data, count: 6)), samples)
    }

    func testAFloatMonoSampleBufferKeepsItsRateAndSamples() throws {
        let samples: [Float] = [0.25, -0.5, 0.75, 0]
        let chunk = try XCTUnwrap(PhysicalAudioChunk(sampleBuffer: AudioSampleBuffers.floatMono(samples)))
        XCTAssertEqual(chunk.buffer.format.commonFormat, .pcmFormatFloat32)
        XCTAssertEqual(chunk.buffer.format.channelCount, 1)
        XCTAssertEqual(chunk.buffer.format.sampleRate, 44_100)
        XCTAssertEqual(chunk.buffer.frameLength, 4)
        let data = try XCTUnwrap(chunk.buffer.floatChannelData)[0]
        XCTAssertEqual(Array(UnsafeBufferPointer(start: data, count: 4)), samples)
    }
}

/// Whether a capture device asks for audio at all.
final class PhysicalCaptureDeviceAudioTests: XCTestCase {
    func testADeviceCarriesNoAudioUnlessItSaysSo() {
        XCTAssertFalse(PhysicalCaptureDevice(uniqueID: "a", localizedName: "n", modelID: "m").hasAudio)
        XCTAssertTrue(PhysicalCaptureDevice(uniqueID: "a", localizedName: "n", modelID: "m", hasAudio: true).hasAudio)
        XCTAssertNotEqual(
            PhysicalCaptureDevice(uniqueID: "a", localizedName: "n", modelID: "m", hasAudio: true),
            PhysicalCaptureDevice(uniqueID: "a", localizedName: "n", modelID: "m")
        )
    }
}

/// `PhysicalScreenCaptureSession`'s audio: asked for only with a sink, sent
/// to the sink while the session runs, and stopped with the session.
final class PhysicalScreenCaptureSessionAudioTests: XCTestCase {
    private let udid = "00000000-0000000000000000"
    private let captureID = "capture-device-1"

    private func makeSession(
        _ provider: FakeScreenCaptureProvider,
        sink: FakeAudioSink?
    ) -> PhysicalScreenCaptureSession {
        let session = PhysicalScreenCaptureSession(
            hardwareUDID: udid, captureDeviceID: captureID, provider: provider, audioSink: sink
        )
        addTeardownBlock { session.stop() }
        return session
    }

    @discardableResult
    private func eventually(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }

    private func chunk() throws -> PhysicalAudioChunk {
        try XCTUnwrap(PhysicalAudioChunk(sampleBuffer: AudioSampleBuffers.int16Stereo([1, -1, 2, -2])))
    }

    func testASessionWithoutASinkAsksTheCaptureForNoAudio() {
        let provider = FakeScreenCaptureProvider()
        let session = makeSession(provider, sink: nil)
        session.start()
        XCTAssertTrue(eventually { provider.captures.first?.startCount == 1 })
        XCTAssertNil(provider.captures.first?.onAudio, "no audio output is added")
        XCTAssertNil(session.audioSink)
    }

    func testASessionWithASinkAsksForAudioAndPlaysWhatArrives() throws {
        let provider = FakeScreenCaptureProvider()
        let sink = FakeAudioSink()
        let session = makeSession(provider, sink: sink)
        session.start()
        XCTAssertTrue(eventually { provider.captures.first?.startCount == 1 })
        let onAudio = try XCTUnwrap(provider.captures.first?.onAudio)
        onAudio(try chunk())
        onAudio(try chunk())
        XCTAssertEqual(sink.playedCount, 2)
        XCTAssertTrue(session.audioSink === sink)
    }

    func testAudioAfterTheSessionStoppedIsDropped() throws {
        let provider = FakeScreenCaptureProvider()
        let sink = FakeAudioSink()
        let session = makeSession(provider, sink: sink)
        session.start()
        XCTAssertTrue(eventually { provider.captures.first?.startCount == 1 })
        let onAudio = try XCTUnwrap(provider.captures.first?.onAudio)
        let stopsBefore = sink.stopCount

        session.stop()
        XCTAssertGreaterThan(sink.stopCount, stopsBefore, "the sink stops with the session")
        onAudio(try chunk())
        XCTAssertEqual(sink.playedCount, 0, "a late chunk of a stopped capture is never played")
    }

    func testAQuitStopsTheSinkToo() throws {
        let provider = FakeScreenCaptureProvider()
        let sink = FakeAudioSink()
        let session = makeSession(provider, sink: sink)
        session.start()
        XCTAssertTrue(eventually { provider.captures.first?.startCount == 1 })
        let stopsBefore = sink.stopCount
        session.stopAndWait(timeout: 2)
        XCTAssertGreaterThan(sink.stopCount, stopsBefore)
    }

    func testACaptureThatEndsStopsTheSink() throws {
        let provider = FakeScreenCaptureProvider()
        let sink = FakeAudioSink()
        let session = makeSession(provider, sink: sink)
        session.start()
        XCTAssertTrue(eventually { provider.captures.first?.startCount == 1 })
        let capture = try XCTUnwrap(provider.captures.first)
        let onAudio = try XCTUnwrap(capture.onAudio)
        let stopsBefore = sink.stopCount
        capture.onEnd(.disconnected)
        XCTAssertFalse(session.isRunning)
        XCTAssertGreaterThan(sink.stopCount, stopsBefore, "an unplugged phone stops its audio")
        onAudio(try chunk())
        XCTAssertEqual(sink.playedCount, 0)
    }

    func testAStartFailureStopsNothingBeyondTheSessionAndPlaysNothing() {
        let provider = FakeScreenCaptureProvider()
        provider.failMake(with: PhysicalScreenCaptureError.deviceNotFound)
        let sink = FakeAudioSink()
        let session = makeSession(provider, sink: sink)
        session.start()
        XCTAssertTrue(eventually { !session.isRunning })
        XCTAssertEqual(sink.playedCount, 0)
        XCTAssertGreaterThan(sink.stopCount, 0)
    }

    func testARestartedSessionPlaysAgain() throws {
        let provider = FakeScreenCaptureProvider()
        let sink = FakeAudioSink()
        let session = makeSession(provider, sink: sink)
        session.start()
        XCTAssertTrue(eventually { provider.captures.count == 1 && provider.captures[0].startCount == 1 })
        session.start()
        XCTAssertTrue(eventually { provider.captures.count == 2 && provider.captures[1].startCount == 1 })
        try XCTUnwrap(provider.captures[1].onAudio)(try chunk())
        XCTAssertEqual(sink.playedCount, 1)
        try XCTUnwrap(provider.captures[0].onAudio)(try chunk())
        XCTAssertEqual(sink.playedCount, 1, "the first capture's late chunk belongs to an older run")
    }
}
