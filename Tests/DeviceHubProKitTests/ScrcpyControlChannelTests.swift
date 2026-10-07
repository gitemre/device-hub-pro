import Darwin
import Foundation
import XCTest
@testable import DeviceHubProKit

/// `ScrcpyControlChannel` against a socketpair standing in for the server's
/// control socket: clipboard acknowledgements, and the descriptor's
/// ownership while device messages are being delivered.
final class ScrcpyControlChannelTests: XCTestCase {
    // MARK: - Clipboard acknowledgements

    func testSetClipboardSendsASequenceAndReturnsOnItsAcknowledgement() async throws {
        let (channel, peer) = try Self.channel()
        defer { channel.close() }
        channel.startReading { _ in }

        async let first = channel.setClipboard("ı", paste: true, timeout: .seconds(30))
        let request = try Self.read(peer, count: 16)
        XCTAssertEqual(
            request,
            [UInt8](ScrcpyControlMessage.setClipboard(sequence: 1, paste: true, text: "ı").serialized)
        )
        try peer.write(contentsOf: Self.acknowledgement(sequence: 1))
        let acknowledged = await first
        XCTAssertTrue(acknowledged)

        // The next request gets the next sequence (0 would ask for no ACK).
        async let second = channel.setClipboard("ş", paste: false, timeout: .seconds(30))
        let next = try Self.read(peer, count: 16)
        XCTAssertEqual(
            next,
            [UInt8](ScrcpyControlMessage.setClipboard(sequence: 2, paste: false, text: "ş").serialized)
        )
        try peer.write(contentsOf: Self.acknowledgement(sequence: 2))
        let secondAcknowledged = await second
        XCTAssertTrue(secondAcknowledged)
    }

    func testSetClipboardGivesUpAfterItsTimeout() async throws {
        let (channel, peer) = try Self.channel()
        defer { channel.close() }
        channel.startReading { _ in }

        let started = Date()
        let acknowledged = await channel.setClipboard("ğ", paste: true, timeout: .milliseconds(200))
        XCTAssertFalse(acknowledged)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        _ = peer
    }

    /// A waiting paste must not outlive its channel: closing it (or the
    /// server going away) ends the wait at once.
    func testClosingOrLosingTheSocketEndsAPendingWait() async throws {
        let (channel, peer) = try Self.channel()
        channel.startReading { _ in }

        let started = Date()
        async let waiting = channel.setClipboard("ç", paste: true, timeout: .seconds(30))
        _ = try Self.read(peer, count: 16)
        channel.close()
        let acknowledged = await waiting
        XCTAssertFalse(acknowledged)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)

        let (lost, lostPeer) = try Self.channel()
        defer { lost.close() }
        lost.startReading { _ in }
        async let orphaned = lost.setClipboard("ö", paste: true, timeout: .seconds(30))
        _ = try Self.read(lostPeer, count: 16)
        try lostPeer.close()
        let orphanedAcknowledged = await orphaned
        XCTAssertFalse(orphanedAcknowledged)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    /// A malformed device message loses the framing, so no ACK can be
    /// recognised after it: a pending wait ends, and later ones do not start.
    func testLosingTheDeviceMessageFramingEndsTheWaits() async throws {
        let (channel, peer) = try Self.channel()
        defer { channel.close() }
        channel.startReading { _ in }

        let started = Date()
        async let pending = channel.setClipboard("ü", paste: true, timeout: .seconds(30))
        _ = try Self.read(peer, count: 16)
        try peer.write(contentsOf: Data([0x7F]))
        let pendingAcknowledged = await pending
        XCTAssertFalse(pendingAcknowledged)

        let later = await channel.setClipboard("ü", paste: true, timeout: .seconds(30))
        XCTAssertFalse(later)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(
            try Self.read(peer, count: 16),
            [UInt8](ScrcpyControlMessage.setClipboard(sequence: 2, paste: true, text: "ü").serialized),
            "the request itself still goes out"
        )
    }

    // MARK: - Descriptor ownership

    /// The device-message callback used to run on the thread reading the
    /// socket. A callback that blocked (an app hook waiting on the main
    /// thread while the main thread tears the session down) kept the reader
    /// from exiting, so `close()` gave up after 2 s and closed the descriptor
    /// under a reader that would read it again. Callbacks now run on their
    /// own queue: the reader exits as soon as the socket is shut down.
    func testABlockedCallbackNeitherDelaysCloseNorHoldsTheDescriptor() async throws {
        let (channel, peer) = try Self.channel()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        channel.startReading { message in
            guard case .clipboard = message else { return }
            entered.signal()
            release.wait()
        }

        try peer.write(contentsOf: Data([0x00, 0x00, 0x00, 0x00, 0x02]) + Data("ok".utf8))
        XCTAssertEqual(entered.wait(timeout: .now() + 3), .success, "the callback never ran")

        let started = Date()
        channel.close()
        XCTAssertLessThan(
            Date().timeIntervalSince(started),
            1,
            "close() must not wait out its bound behind a blocked callback"
        )
        XCTAssertFalse(channel.isUsable)
        release.signal()
        _ = peer
    }

    // MARK: - Helpers

    private static func channel() throws -> (ScrcpyControlChannel, FileHandle) {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let channel = ScrcpyControlChannel(
            handle: FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true)
        )
        return (channel, FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true))
    }

    private static func acknowledgement(sequence: UInt64) -> Data {
        var bytes = Data([ScrcpyControl.deviceTypeAckClipboard])
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: sequence >> UInt64(shift)))
        }
        return bytes
    }

    /// Reads exactly `count` bytes from `handle`, or fails after `timeout`.
    private static func read(
        _ handle: FileHandle,
        count: Int,
        timeout: TimeInterval = 3
    ) throws -> [UInt8] {
        let descriptor = handle.fileDescriptor
        let deadline = Date().addingTimeInterval(timeout)
        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while bytes.count < count {
            let remaining = Int32(max(0, deadline.timeIntervalSinceNow) * 1000)
            var descriptorState = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard remaining > 0, poll(&descriptorState, 1, remaining) > 0 else {
                XCTFail("timed out with \(bytes.count) of \(count) bytes: \(bytes)")
                return bytes
            }
            let wanted = min(buffer.count, count - bytes.count)
            let received = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(descriptor, raw.baseAddress, wanted)
            }
            guard received > 0 else {
                XCTFail("the socket closed after \(bytes.count) of \(count) bytes")
                return bytes
            }
            bytes.append(contentsOf: buffer[0..<received])
        }
        return bytes
    }
}
