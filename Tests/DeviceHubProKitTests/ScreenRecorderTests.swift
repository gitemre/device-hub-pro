import AVFoundation
import CoreMedia
import CoreVideo
import XCTest
@testable import DeviceHubProKit

final class ScreenRecorderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenRecorderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var outputURL: URL { directory.appendingPathComponent("recording.mp4") }

    // MARK: - Recording

    func testRecordsAPlayableMP4OnDisk() async throws {
        let recorder = try ScreenRecorder(outputURL: outputURL, targetFPS: 30)
        try await feed(recorder, frames: 0..<90, timescale: 30)

        let url = try await recorder.finalize()

        XCTAssertEqual(url, outputURL)
        XCTAssertEqual(recorder.canvasSize, CGSize(width: 320, height: 240))
        XCTAssertEqual(recorder.encodedFrameCount, 90)
        XCTAssertEqual(recorder.droppedFrameCount, 0)
        let asset = AVURLAsset(url: url)
        let isPlayable = try await asset.load(.isPlayable)
        XCTAssertTrue(isPlayable)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 3.0, accuracy: 0.05)
        let track = try await firstVideoTrack(of: asset)
        let formats = try await track.load(.formatDescriptions)
        let format = try XCTUnwrap(formats.first)
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        XCTAssertEqual(dimensions.width, 320)
        XCTAssertEqual(dimensions.height, 240)
        let cursor = try XCTUnwrap(track.makeSampleCursorAtFirstSampleInDecodeOrder())
        XCTAssertTrue(cursor.currentSampleSyncInfo.sampleIsFullSync.boolValue)
    }

    /// The device-side `screenrecord` stops at 180 s. The host recorder has
    /// no limit, writes as it goes (bounded memory) and flushes movie
    /// fragments, so even an unfinished file is readable.
    func testRecordingHasNoLengthLimitAndIsWrittenAsItGoes() async throws {
        let recorder = try ScreenRecorder(outputURL: outputURL, targetFPS: 30)
        // One frame a second (a mostly static screen) for 200 s.
        try await feed(recorder, frames: 0..<200, timescale: 1)
        try await waitUntil { recorder.pendingSampleCount == 0 }

        XCTAssertLessThanOrEqual(recorder.pendingSampleCount, recorder.maxPendingSamples)
        let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        XCTAssertGreaterThan((attributes[.size] as? NSNumber)?.intValue ?? 0, 10_000)
        // A copy of the unfinished file (as a crash would leave it) opens.
        let snapshot = directory.appendingPathComponent("unfinished.mp4")
        try FileManager.default.copyItem(at: outputURL, to: snapshot)
        let unfinished = CMTimeGetSeconds(try await AVURLAsset(url: snapshot).load(.duration))
        XCTAssertGreaterThan(unfinished, 100, "movie fragments must be flushed while recording")

        let url = try await recorder.finalize()

        XCTAssertEqual(recorder.recordedSeconds, 199, accuracy: 0.001)
        let duration = CMTimeGetSeconds(try await AVURLAsset(url: url).load(.duration))
        XCTAssertEqual(duration, 199 + 1.0 / 30, accuracy: 0.05)
    }

    /// A rotation mid-recording keeps the first frame's canvas: the landscape
    /// picture is scaled to fit and centered on black bars.
    func testARotationIsLetterboxedIntoTheFirstFramesCanvas() async throws {
        let recorder = try ScreenRecorder(outputURL: outputURL, targetFPS: 30)
        let red = (red: UInt8(220), green: UInt8(30), blue: UInt8(30))
        let green = (red: UInt8(30), green: UInt8(200), blue: UInt8(40))
        try await feed(recorder, frames: 0..<30, timescale: 30) { _ in
            try self.makeSolidFrame(width: 240, height: 320, color: red)
        }
        try await feed(recorder, frames: 30..<60, timescale: 30) { _ in
            try self.makeSolidFrame(width: 320, height: 240, color: green)
        }

        let url = try await recorder.finalize()

        XCTAssertEqual(recorder.canvasSize, CGSize(width: 240, height: 320))
        let asset = AVURLAsset(url: url)
        let formats = try await firstVideoTrack(of: asset).load(.formatDescriptions)
        let format = try XCTUnwrap(formats.first)
        XCTAssertEqual(CMVideoFormatDescriptionGetDimensions(format).width, 240)
        XCTAssertEqual(CMVideoFormatDescriptionGetDimensions(format).height, 320)

        let portrait = try await frame(of: asset, at: 0.5)
        assertDominant(\.red, portrait.pixel(120, 160))
        assertDominant(\.red, portrait.pixel(120, 10))

        // 320×240 fits a 240×320 canvas at 240×180, rows 70…249.
        let landscape = try await frame(of: asset, at: 1.5)
        assertDominant(\.green, landscape.pixel(120, 160))
        assertDominant(\.green, landscape.pixel(120, 80))
        assertDominant(\.green, landscape.pixel(120, 240))
        assertDominant(\.green, landscape.pixel(5, 160))
        assertNearBlack(landscape.pixel(120, 20))
        assertNearBlack(landscape.pixel(120, 300))
        assertNearBlack(landscape.pixel(5, 5))
    }

    func testAnOddSizedFirstFrameGetsAnEvenCanvas() async throws {
        let recorder = try ScreenRecorder(outputURL: outputURL, targetFPS: 30)
        try await feed(recorder, frames: 0..<10, timescale: 30) { _ in
            try self.makeSolidFrame(width: 321, height: 241, color: (10, 20, 30))
        }

        _ = try await recorder.finalize()

        XCTAssertEqual(recorder.canvasSize, CGSize(width: 320, height: 240))
        XCTAssertEqual(recorder.encodedFrameCount, 10)
    }

    /// Stopping on a static screen: the last frame is held until the stop.
    func testFinalizeHoldsTheLastFrameUntilTheRequestedEnd() async throws {
        let recorder = try ScreenRecorder(outputURL: outputURL, targetFPS: 30)
        try await feed(recorder, frames: 0..<30, timescale: 30)

        let url = try await recorder.finalize(endingAt: CMTime(seconds: 4, preferredTimescale: 600))

        let duration = try await AVURLAsset(url: url).load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 4, accuracy: 0.05)
    }

    // MARK: - Ending

    func testCancelDeletesTheFileAndEndsTheRecording() async throws {
        let recorder = try ScreenRecorder(outputURL: outputURL, targetFPS: 30)
        try await feed(recorder, frames: 0..<30, timescale: 30)
        try await waitUntil { FileManager.default.fileExists(atPath: self.outputURL.path) }

        await recorder.cancel()

        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        let encoded = recorder.encodedFrameCount
        recorder.ingest(try makeFrame(index: 99), at: CMTime(value: 99, timescale: 30))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(recorder.encodedFrameCount, encoded)
        do {
            _ = try await recorder.finalize()
            XCTFail("expected alreadyFinished")
        } catch let error as ScreenRecorderError {
            XCTAssertEqual(error, .alreadyFinished)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }

    /// The actor is reentrant: a cancel racing a finalize must win without
    /// touching the writer mid-finish — the finalize throws and no file is
    /// left, whichever of the two ran first.
    func testCancelRacingFinalizeLeavesNoFile() async throws {
        for _ in 0..<5 {
            try? FileManager.default.removeItem(at: outputURL)
            let recorder = try ScreenRecorder(outputURL: outputURL, targetFPS: 30)
            try await feed(recorder, frames: 0..<60, timescale: 30)

            let finalize = Task { try await recorder.finalize() }
            await Task.yield()
            await recorder.cancel()

            do {
                _ = try await finalize.value
                XCTFail("a cancelled recording must not finalize")
            } catch is CancellationError {
            } catch let error as ScreenRecorderError {
                XCTAssertEqual(error, .alreadyFinished)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        }
    }

    /// A finalized file belongs to the caller: a late cancel keeps it.
    func testCancelAfterFinalizeKeepsTheFile() async throws {
        let recorder = try ScreenRecorder(outputURL: outputURL, targetFPS: 30)
        try await feed(recorder, frames: 0..<10, timescale: 30)
        let url = try await recorder.finalize()

        await recorder.cancel()

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testFinalizeWithoutFramesThrowsAndLeavesNoFile() async throws {
        let recorder = try ScreenRecorder(outputURL: outputURL, targetFPS: 30)

        do {
            _ = try await recorder.finalize()
            XCTFail("expected noFrames")
        } catch let error as ScreenRecorderError {
            XCTAssertEqual(error, .noFrames)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }

    func testRefusesToOverwriteAnExistingFile() throws {
        try Data("keep me".utf8).write(to: outputURL)

        XCTAssertThrowsError(try ScreenRecorder(outputURL: outputURL)) { error in
            XCTAssertEqual(error as? ScreenRecorderError, .outputExists(outputURL.path))
        }
        XCTAssertEqual(try Data(contentsOf: outputURL), Data("keep me".utf8))
    }

    // MARK: - Backpressure

    /// A burst far faster than the encoder drops frames instead of queueing
    /// them, and the recording still finishes.
    func testABurstIsDroppedInsteadOfQueued() async throws {
        let recorder = try ScreenRecorder(outputURL: outputURL, targetFPS: 30)
        let frames = 2000
        var peakPending = 0
        for index in 0..<frames {
            recorder.ingest(try makeFrame(index: index), at: CMTime(value: CMTimeValue(index), timescale: 30))
            peakPending = max(peakPending, recorder.pendingSampleCount)
        }
        try await waitUntil { recorder.encodedFrameCount + recorder.droppedFrameCount >= frames }

        XCTAssertGreaterThan(recorder.droppedFrameCount, 0, "a 2000-frame burst must outpace the encoder")
        XCTAssertLessThanOrEqual(peakPending, recorder.maxPendingSamples)
        _ = try await recorder.finalize()
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
    }

    func testAStalledEncoderTimesOutAndLeavesNoFile() async throws {
        let recorder = try ScreenRecorder(
            outputURL: outputURL,
            targetFPS: 30,
            idleTimeout: .milliseconds(100),
            frameEncoder: { _, _, _, _ in noErr }
        )
        recorder.ingest(try makeFrame(index: 0), at: .zero)

        let started = ContinuousClock.now
        do {
            _ = try await recorder.finalize()
            XCTFail("expected encoderTimeout")
        } catch let error as ScreenRecorderError {
            XCTAssertEqual(error, .encoderTimeout)
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }

    // MARK: - Helpers

    private enum FixtureError: Error {
        case pixelBufferCreationFailed
        case noVideoTrack
        case decodeFailed
    }

    /// Feeds frames in chunks, waiting for the encoder after each so the
    /// tests measure the recording rather than backpressure.
    private func feed(
        _ recorder: ScreenRecorder,
        frames: Range<Int>,
        timescale: CMTimeScale,
        chunkSize: Int = 8,
        make: ((Int) throws -> CVPixelBuffer)? = nil
    ) async throws {
        let base = recorder.encodedFrameCount + recorder.droppedFrameCount
        var fed = 0
        for index in frames {
            let pixelBuffer = try make?(index) ?? makeFrame(index: index)
            recorder.ingest(pixelBuffer, at: CMTime(value: CMTimeValue(index), timescale: timescale))
            fed += 1
            if fed % chunkSize == 0 {
                try await waitUntil { recorder.encodedFrameCount + recorder.droppedFrameCount >= base + fed }
            }
        }
        try await waitUntil { recorder.encodedFrameCount + recorder.droppedFrameCount >= base + frames.count }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("condition not met in time")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private func firstVideoTrack(of asset: AVURLAsset) async throws -> AVAssetTrack {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw FixtureError.noVideoTrack
        }
        return track
    }

    private struct DecodedFrame {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        /// RGB at (x, y), top-left origin.
        func pixel(_ x: Int, _ y: Int) -> (red: UInt8, green: UInt8, blue: UInt8) {
            let offset = (y * width + x) * 4
            return (bytes[offset], bytes[offset + 1], bytes[offset + 2])
        }
    }

    private func frame(of asset: AVURLAsset, at seconds: Double) async throws -> DecodedFrame {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let data = context.data else {
            throw FixtureError.decodeFailed
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let count = image.width * image.height * 4
        return DecodedFrame(
            width: image.width,
            height: image.height,
            bytes: Array(UnsafeBufferPointer(start: data.bindMemory(to: UInt8.self, capacity: count), count: count))
        )
    }

    private typealias RGB = (red: UInt8, green: UInt8, blue: UInt8)

    /// H.264 is lossy and the decode applies color management, so a frame's
    /// color is checked by its dominant channel rather than exact values.
    private func assertDominant(
        _ channel: KeyPath<DominantProbe, UInt8>,
        _ actual: RGB,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let probe = DominantProbe(actual)
        let others = [probe.red, probe.green, probe.blue].sorted()
        let value = probe[keyPath: channel]
        XCTAssertEqual(value, others[2], "\(actual) is not dominated by the expected channel", file: file, line: line)
        XCTAssertGreaterThan(Int(value) - Int(others[1]), 80, "\(actual)", file: file, line: line)
    }

    private func assertNearBlack(_ actual: RGB, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(
            max(actual.red, actual.green, actual.blue),
            24,
            "\(actual) is not a black bar",
            file: file,
            line: line
        )
    }

    private struct DominantProbe {
        let red: UInt8
        let green: UInt8
        let blue: UInt8

        init(_ rgb: RGB) {
            red = rgb.red
            green = rgb.green
            blue = rgb.blue
        }
    }

    private func makeSolidFrame(
        width: Int,
        height: Int,
        color: (red: UInt8, green: UInt8, blue: UInt8)
    ) throws -> CVPixelBuffer {
        let pixelBuffer = try makePixelBuffer(width: width, height: height)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw FixtureError.pixelBufferCreationFailed
        }
        let pattern: [UInt8] = [color.blue, color.green, color.red, 255]
        pattern.withUnsafeBytes { pointer in
            memset_pattern4(base, pointer.baseAddress!, CVPixelBufferGetBytesPerRow(pixelBuffer) * height)
        }
        return pixelBuffer
    }

    /// A flat frame whose color changes per index plus a moving marker, so
    /// consecutive frames differ like a live screen.
    private func makeFrame(index: Int, width: Int = 320, height: Int = 240) throws -> CVPixelBuffer {
        let pixelBuffer = try makeSolidFrame(
            width: width,
            height: height,
            color: (UInt8((index * 17) % 256), UInt8((index * 53) % 256), UInt8((index * 97) % 256))
        )
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw FixtureError.pixelBufferCreationFailed
        }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let markerX = (index * 7) % max(1, width - 24)
        let markerY = (index * 5) % max(1, height - 24)
        for y in markerY..<min(markerY + 24, height) {
            let row = bytes + y * bytesPerRow
            for x in markerX..<min(markerX + 24, width) {
                row[x * 4] = 255
                row[x * 4 + 1] = 255
                row[x * 4 + 2] = 255
                row[x * 4 + 3] = 255
            }
        }
        return pixelBuffer
    }

    private func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw FixtureError.pixelBufferCreationFailed
        }
        return pixelBuffer
    }
}
