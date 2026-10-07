import AVFoundation
import CoreMedia
import CoreVideo
import XCTest
@testable import DeviceHubProKit

final class ReplayBufferTests: XCTestCase {
    func testSaveClipOnEmptyBufferThrowsTypedError() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let buffer = ReplayBuffer(windowSeconds: 30, targetFPS: 15, width: 320, height: 240)

        do {
            _ = try await buffer.saveClip(to: directory)
            XCTFail("expected an empty-buffer error")
        } catch let error as ReplayBufferError {
            XCTAssertEqual(error, .emptyBuffer)
        }

        XCTAssertEqual(buffer.retainedSeconds, 0)
        XCTAssertEqual(buffer.retainedFrameCount, 0)
        XCTAssertEqual(buffer.retainedByteCount, 0)
        XCTAssertEqual(buffer.droppedFrameCount, 0)
    }

    func testFramesFasterThanTargetArePacedOut() async throws {
        let buffer = ReplayBuffer(windowSeconds: 30, targetFPS: 15, width: 320, height: 240)

        try await feed(buffer, frames: 0..<600, timescale: 60)

        XCTAssertTrue(
            (148...152).contains(buffer.retainedFrameCount),
            "expected ~150 retained frames for 10 s at 15 fps, got \(buffer.retainedFrameCount)"
        )
        XCTAssertEqual(buffer.retainedSeconds, 10, accuracy: 0.25)
        XCTAssertEqual(buffer.encodedFrameCount, buffer.retainedFrameCount)
    }

    func testRetainsOnlyTheWindowAndEvictsOlderFrames() async throws {
        let buffer = ReplayBuffer(windowSeconds: 30, targetFPS: 15, width: 320, height: 240)

        try await feed(buffer, frames: 0..<150, timescale: 15)
        XCTAssertEqual(buffer.retainedSeconds, 10, accuracy: 0.15)
        XCTAssertEqual(buffer.retainedFrameCount, 150)

        try await feed(buffer, frames: 150..<675, timescale: 15)

        XCTAssertGreaterThanOrEqual(buffer.retainedSeconds, 29.0)
        XCTAssertLessThanOrEqual(buffer.retainedSeconds, 30.001)
        XCTAssertEqual(buffer.retainedFrameCount, 450)
        XCTAssertGreaterThan(buffer.retainedByteCount, 0)
        XCTAssertEqual(buffer.droppedFrameCount, 0)
    }

    func testSavedClipReadsBackAsPlayableMP4() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let buffer = ReplayBuffer(windowSeconds: 30, targetFPS: 15, width: 320, height: 240)
        try await feed(buffer, frames: 0..<675, timescale: 15)

        let url = try await buffer.saveClip(to: directory)

        XCTAssertEqual(url.pathExtension, "mp4")
        XCTAssertTrue(url.path.hasPrefix(directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let asset = AVURLAsset(url: url)
        let isPlayable = try await asset.load(.isPlayable)
        XCTAssertTrue(isPlayable)

        let seconds = CMTimeGetSeconds(try await asset.load(.duration))
        XCTAssertGreaterThanOrEqual(seconds, buffer.retainedSeconds - 0.1)
        XCTAssertLessThanOrEqual(seconds, buffer.retainedSeconds + 0.25)
        XCTAssertEqual(seconds, 30, accuracy: 0.15)

        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
        guard let format = try await tracks[0].load(.formatDescriptions).first else {
            XCTFail("saved clip has no video format description")
            return
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        XCTAssertEqual(dimensions.width, 320)
        XCTAssertEqual(dimensions.height, 240)

        // Eviction trims to a keyframe, so the clip plays from its first frame.
        guard let cursor = tracks[0].makeSampleCursorAtFirstSampleInDecodeOrder() else {
            XCTFail("could not position a sample cursor in the saved clip")
            return
        }
        XCTAssertTrue(
            cursor.currentSampleSyncInfo.sampleIsFullSync.boolValue,
            "the saved clip must start on a keyframe"
        )

        let second = try await buffer.saveClip(to: directory)
        XCTAssertNotEqual(second, url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    func testDropsFramesWhenTheEncoderIsSaturated() async throws {
        let buffer = ReplayBuffer(windowSeconds: 30, targetFPS: 15, width: 320, height: 240)
        let frames = 3000

        for frame in 0..<frames {
            let pixelBuffer = try makeFrame(index: frame)
            buffer.ingest(pixelBuffer, at: CMTime(value: CMTimeValue(frame), timescale: 15))
        }
        try await settle(buffer, encodedOrDroppedAtLeast: frames)

        XCTAssertGreaterThan(
            buffer.droppedFrameCount,
            0,
            "feeding 200 s of frames in a burst must outpace the encoder"
        )
        XCTAssertEqual(buffer.encodedFrameCount + buffer.droppedFrameCount, frames)
        XCTAssertGreaterThan(buffer.retainedByteCount, 0)
        XCTAssertLessThanOrEqual(buffer.retainedByteCount, buffer.memoryBoundBytes)
        XCTAssertGreaterThan(buffer.memoryBoundBytes, 0)
        XCTAssertLessThanOrEqual(buffer.retainedSeconds, 30.001)
    }

    func testCallerSuppliedMemoryBoundCapsRetainedBytes() async throws {
        let bound = 500_000
        let buffer = ReplayBuffer(
            windowSeconds: 30,
            targetFPS: 15,
            width: 320,
            height: 240,
            memoryBoundBytes: bound
        )
        XCTAssertEqual(buffer.memoryBoundBytes, bound)

        try await feed(buffer, frames: 0..<300, timescale: 15, incompressible: true)

        XCTAssertGreaterThan(buffer.retainedByteCount, 0)
        XCTAssertLessThanOrEqual(buffer.retainedByteCount, bound)
        XCTAssertLessThan(
            buffer.retainedFrameCount,
            buffer.encodedFrameCount,
            "an incompressible burst must trigger byte-budget eviction before the 30 s window is full"
        )
    }

    func testMemoryBoundEvictsOldestSegmentsAndKeepsTheNewestSamples() async throws {
        let bound = 500_000
        let state = ReplayState(
            windowSeconds: 30,
            targetFPS: 15,
            width: 320,
            height: 240,
            memoryBoundBytes: bound
        )
        try await feed(state, frames: 0..<300, timescale: 15, incompressible: true)

        XCTAssertGreaterThan(state.retainedByteCount, 0)
        XCTAssertLessThanOrEqual(state.retainedByteCount, bound)

        let samples = state.snapshotSamples()
        guard let first = samples.first, let last = samples.last else {
            XCTFail("expected retained samples")
            return
        }
        XCTAssertGreaterThan(
            CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(first)),
            0,
            "byte-budget eviction must drop the oldest frames first"
        )
        XCTAssertEqual(
            CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(last)),
            299.0 / 15.0,
            accuracy: 0.001,
            "the newest frame must survive eviction"
        )
    }

    func testMemoryBoundEvictionStartsWithAKeyframe() async throws {
        // Tighter than one ~2 s segment (≈290 KB of noise at this rate) so the
        // enforcement trims inside the surviving segment, not just whole segments.
        let bound = 250_000
        let state = ReplayState(
            windowSeconds: 30,
            targetFPS: 15,
            width: 320,
            height: 240,
            memoryBoundBytes: bound
        )
        try await feed(state, frames: 0..<300, timescale: 15, incompressible: true)

        guard let first = state.snapshotSamples().first else {
            XCTFail("expected retained samples")
            return
        }
        XCTAssertLessThanOrEqual(state.retainedByteCount, bound)
        XCTAssertTrue(
            isSyncSample(first),
            "the oldest retained sample must be a keyframe so the clip still decodes"
        )
    }

    func testSaveClipThrowsEncoderTimeoutWhenTheEncoderStalls() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let buffer = ReplayBuffer(
            windowSeconds: 30,
            targetFPS: 15,
            width: 320,
            height: 240,
            memoryBoundBytes: nil,
            idleTimeout: .milliseconds(100),
            frameEncoder: { _, _, _, _ in noErr }
        )
        buffer.ingest(try makeFrame(index: 0), at: CMTime(value: 0, timescale: 15))

        let started = ContinuousClock.now
        do {
            _ = try await buffer.saveClip(to: directory)
            XCTFail("expected the stalled encoder to time out")
        } catch let error as ReplayBufferError {
            XCTAssertEqual(error, .encoderTimeout)
        }
        XCTAssertLessThan(
            ContinuousClock.now - started,
            .seconds(2),
            "saveClip must not hang on a stalled encoder"
        )
    }

    func testResetClearsRetainedState() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let buffer = ReplayBuffer(windowSeconds: 30, targetFPS: 15, width: 320, height: 240)
        try await feed(buffer, frames: 0..<150, timescale: 15)
        XCTAssertGreaterThan(buffer.retainedSeconds, 9)

        await buffer.reset()

        XCTAssertEqual(buffer.retainedSeconds, 0)
        XCTAssertEqual(buffer.retainedFrameCount, 0)
        XCTAssertEqual(buffer.retainedByteCount, 0)
        XCTAssertEqual(buffer.droppedFrameCount, 0)
        XCTAssertEqual(buffer.encodedFrameCount, 0)

        // A burst submitted just before the reset must not repopulate the ring.
        for frame in 150..<158 {
            let pixelBuffer = try makeFrame(index: frame)
            buffer.ingest(pixelBuffer, at: CMTime(value: CMTimeValue(frame), timescale: 15))
        }
        await buffer.reset()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(buffer.retainedFrameCount, 0)
        XCTAssertEqual(buffer.retainedSeconds, 0)

        do {
            _ = try await buffer.saveClip(to: directory)
            XCTFail("expected an empty-buffer error after reset")
        } catch let error as ReplayBufferError {
            XCTAssertEqual(error, .emptyBuffer)
        }

        try await feed(buffer, frames: 158..<308, timescale: 15)
        XCTAssertEqual(buffer.retainedFrameCount, 150)
        XCTAssertGreaterThan(buffer.retainedByteCount, 0)
    }

    // MARK: - Helpers

    private enum FixtureError: Error {
        case pixelBufferCreationFailed
        case timeout
    }

    /// Feeds frames in chunks, waiting for the encoder after each chunk so
    /// retention tests measure the ring rather than backpressure. The saturation
    /// test feeds its burst directly instead.
    private func feed(
        _ buffer: ReplayBuffer,
        frames: Range<Int>,
        timescale: CMTimeScale,
        chunkSize: Int = 8,
        incompressible: Bool = false
    ) async throws {
        let base = buffer.encodedFrameCount + buffer.droppedFrameCount
        var fed = 0
        for frame in frames {
            let pixelBuffer =
                incompressible ? try makeNoiseFrame(index: frame) : try makeFrame(index: frame)
            buffer.ingest(pixelBuffer, at: CMTime(value: CMTimeValue(frame), timescale: timescale))
            fed += 1
            if chunkSize > 0, fed % chunkSize == 0 {
                try await settle(buffer, encodedOrDroppedAtLeast: base + fed)
            }
        }
        try await settle(buffer, encodedOrDroppedAtLeast: base + frames.count)
    }

    private func feed(
        _ state: ReplayState,
        frames: Range<Int>,
        timescale: CMTimeScale,
        chunkSize: Int = 8,
        incompressible: Bool = false
    ) async throws {
        let base = state.encodedFrameCount + state.droppedFrameCount
        var fed = 0
        for frame in frames {
            let pixelBuffer =
                incompressible ? try makeNoiseFrame(index: frame) : try makeFrame(index: frame)
            state.ingest(pixelBuffer, at: CMTime(value: CMTimeValue(frame), timescale: timescale))
            fed += 1
            if chunkSize > 0, fed % chunkSize == 0 {
                try await settle(state, encodedOrDroppedAtLeast: base + fed)
            }
        }
        try await settle(state, encodedOrDroppedAtLeast: base + frames.count)
    }

    private func settle(_ buffer: ReplayBuffer, encodedOrDroppedAtLeast expected: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while buffer.encodedFrameCount + buffer.droppedFrameCount < expected {
            guard ContinuousClock.now < deadline else { throw FixtureError.timeout }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private func settle(_ state: ReplayState, encodedOrDroppedAtLeast expected: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while state.encodedFrameCount + state.droppedFrameCount < expected {
            guard ContinuousClock.now < deadline else { throw FixtureError.timeout }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private func makeFrame(index: Int, width: Int = 320, height: Int = 240) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw FixtureError.pixelBufferCreationFailed
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw FixtureError.pixelBufferCreationFailed
        }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let red = UInt8((index * 17) % 256)
        let green = UInt8((index * 53) % 256)
        let blue = UInt8((index * 97) % 256)
        let pattern: [UInt8] = [blue, green, red, 255]
        pattern.withUnsafeBytes { pointer in
            memset_pattern4(bytes, pointer.baseAddress!, height * bytesPerRow)
        }

        let markerX = (index * 7) % max(1, width - 24)
        let markerY = (index * 5) % max(1, height - 24)
        for y in markerY..<min(markerY + 24, height) {
            let row = bytes + y * bytesPerRow
            for x in markerX..<min(markerX + 24, width) {
                let pixel = row + x * 4
                pixel[0] = 255
                pixel[1] = 255
                pixel[2] = 255
                pixel[3] = 255
            }
        }
        return pixelBuffer
    }

    /// A deterministic LCG-noise frame: high entropy so the encoder cannot
    /// compress it much, which drives the ring against its byte budget fast.
    private func makeNoiseFrame(index: Int, width: Int = 320, height: Int = 240) throws
        -> CVPixelBuffer
    {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw FixtureError.pixelBufferCreationFailed
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw FixtureError.pixelBufferCreationFailed
        }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        var generator = UInt64(truncatingIfNeeded: index) &* 0x9E37_79B9_7F4A_7C15 &+ 1
        for y in 0..<height {
            let row = bytes + y * bytesPerRow
            for x in 0..<(width * 4) {
                generator = generator &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                row[x] = UInt8(truncatingIfNeeded: generator >> 33)
            }
        }
        return pixelBuffer
    }

    private func isSyncSample(_ sample: CMSampleBuffer) -> Bool {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sample,
                createIfNecessary: false
            ) as? [[CFString: Any]],
            let first = attachments.first
        else { return true }
        if let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            return !notSync
        }
        return true
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReplayBufferTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
