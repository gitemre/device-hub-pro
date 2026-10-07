import CoreVideo
import XCTest
@testable import DeviceHubProKit

/// The decoded-frame hand-off: a scrcpy frame travels through the store as
/// its VideoToolbox buffer (the renderer samples it in place), and the RGBA
/// bytes other consumers read are made once, only when asked for.
final class FramePixelBufferTests: XCTestCase {
    func testADecodedFrameKeepsItsBufferAndConvertsOnlyOnDemand() throws {
        let buffer = try Self.makeBGRAPixelBuffer(width: 2, height: 1, bytes: [10, 20, 30, 255, 40, 50, 60, 128])
        let conversions = Counter()
        let frame = Frame(pixelBuffer: buffer, seq: 3) { pixelBuffer in
            conversions.increment()
            return PhysicalMirrorSession.rgbaFrame(from: pixelBuffer)?.data
        }

        XCTAssertTrue(frame.pixelBuffer === buffer, "the renderer must get the decoded buffer itself")
        XCTAssertEqual(frame.width, 2)
        XCTAssertEqual(frame.height, 1)
        XCTAssertEqual(conversions.value, 0, "storing a decoded frame must not convert it")

        XCTAssertEqual([UInt8](frame.data), [30, 20, 10, 255, 60, 50, 40, 128])
        let copy = frame
        XCTAssertEqual([UInt8](copy.data), [30, 20, 10, 255, 60, 50, 40, 128])
        XCTAssertEqual(conversions.value, 1, "the bytes are made once and shared by every copy")
    }

    func testAByteFrameHasNoPixelBuffer() {
        let frame = Frame(data: Data([1, 2, 3, 4]), width: 1, height: 1, seq: 0)
        XCTAssertNil(frame.pixelBuffer)
        XCTAssertEqual([UInt8](frame.data), [1, 2, 3, 4])
    }

    func testAFailedConversionYieldsEmptyBytesOnce() throws {
        let buffer = try Self.makeBGRAPixelBuffer(width: 1, height: 1, bytes: [0, 0, 0, 255])
        let conversions = Counter()
        let frame = Frame(pixelBuffer: buffer, seq: 0) { _ in
            conversions.increment()
            return nil
        }
        XCTAssertTrue(frame.data.isEmpty)
        XCTAssertTrue(frame.data.isEmpty)
        XCTAssertEqual(conversions.value, 1)
    }

    func testTheStoreKeepsTheDecodedBufferAndStampsAGeneration() throws {
        let buffer = try Self.makeBGRAPixelBuffer(width: 1, height: 1, bytes: [0, 0, 0, 255])
        let store = FrameStore()
        store.put(Frame(pixelBuffer: buffer, seq: 1) { _ in nil })

        let stored = try XCTUnwrap(store.current)
        XCTAssertTrue(stored.pixelBuffer === buffer)
        XCTAssertGreaterThan(stored.generation, 0)
        XCTAssertEqual(store.currentSize?.width, 1)
    }

    // MARK: - Observers

    func testObserversRunAfterEveryStoredFrameUntilCancelled() {
        let store = FrameStore()
        let calls = Counter()
        let observation = store.observe { calls.increment() }

        store.put(Frame(data: Data(count: 4), width: 1, height: 1, seq: 0))
        store.put(Frame(data: Data(count: 4), width: 1, height: 1, seq: 1))
        XCTAssertEqual(calls.value, 2)

        observation.cancel()
        store.put(Frame(data: Data(count: 4), width: 1, height: 1, seq: 2))
        XCTAssertEqual(calls.value, 2)
    }

    func testAnObserverSeesTheFrameItIsCalledFor() {
        // The callback runs after the store's lock is released, so it may
        // read `current` (the renderer's uploader does exactly that).
        let store = FrameStore()
        let seen = Counter()
        let observation = store.observe {
            if store.current?.seq == 9 { seen.increment() }
        }
        store.put(Frame(data: Data(count: 4), width: 1, height: 1, seq: 9))
        XCTAssertEqual(seen.value, 1)
        withExtendedLifetime(observation) {}
    }

    func testARejectedConditionalPutNotifiesNobody() {
        let store = FrameStore()
        store.put(Frame(data: Data(count: 4), width: 1, height: 1, seq: 0))
        let stale = store.currentGeneration
        store.put(Frame(data: Data(count: 4), width: 1, height: 1, seq: 1))

        let calls = Counter()
        let observation = store.observe { calls.increment() }
        XCTAssertFalse(store.put(Frame(data: Data(count: 4), width: 1, height: 1, seq: 2), ifGeneration: stale))
        XCTAssertEqual(calls.value, 0)
        XCTAssertTrue(store.put(Frame(data: Data(count: 4), width: 1, height: 1, seq: 3), ifGeneration: store.currentGeneration))
        XCTAssertEqual(calls.value, 1)
        withExtendedLifetime(observation) {}
    }

    func testReleasingTheObservationRemovesTheObserver() {
        let store = FrameStore()
        let calls = Counter()
        var observation: FrameObservation? = store.observe { calls.increment() }
        store.put(Frame(data: Data(count: 4), width: 1, height: 1, seq: 0))
        observation = nil
        store.put(Frame(data: Data(count: 4), width: 1, height: 1, seq: 1))
        XCTAssertEqual(calls.value, 1)
        XCTAssertNil(observation)
    }

    // MARK: - Fixtures

    static func makeBGRAPixelBuffer(width: Int, height: Int, bytes: [UInt8]) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        XCTAssertEqual(CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &pixelBuffer
        ), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0..<height {
            for column in 0..<(width * 4) {
                base[row * rowBytes + column] = bytes[row * width * 4 + column]
            }
        }
        return buffer
    }
}

/// A thread-safe call counter for observer callbacks.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
