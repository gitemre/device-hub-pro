import DeviceHubProKit
import Darwin
import Foundation
import XCTest

// The same stand-in as the app suite's `LoopbackListener.swift` (a test
// target cannot import another's): a port that reaches only this test.

extension XCTestCase {
    /// A gRPC port that reaches only a listener this test owns until it
    /// ends — never an emulator's or another process's, as a fixed port
    /// could. What connects there fails at once; the teardown drops the
    /// pooled connection.
    func makeOwnedGrpcPort() throws -> Int {
        let listener = try LoopbackListener()
        addTeardownBlock {
            listener.stop()
            await EmulatorControls.closeConnections(port: listener.port)
        }
        return listener.port
    }
}

/// A loopback listener the test owns: it accepts every connection, counts
/// it and closes it at once (a gRPC call to it fails fast, as to a closed
/// door). No other process can listen on 127.0.0.1 at its `port` while it
/// lives, so the port reaches nothing but this listener.
final class LoopbackListener: @unchecked Sendable {
    let port: Int
    private let lock = NSLock()
    private var connections = 0
    private var stopped = false

    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(descriptor, 16) == 0 else {
            let failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            Darwin.close(descriptor)
            throw failure
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        port = Int(UInt16(bigEndian: address.sin_port))
        // The loop owns the socket and closes it once stopped: a close from
        // another thread would not reliably wake a blocked `accept`.
        let thread = Thread { [self] in
            var ready = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            while !lock.withLock({ stopped }) {
                guard poll(&ready, 1, 50) > 0 else { continue }
                let accepted = accept(descriptor, nil, nil)
                guard accepted >= 0 else { continue }
                lock.withLock { connections += 1 }
                Darwin.close(accepted)
            }
            Darwin.close(descriptor)
        }
        thread.start()
    }

    /// Connections accepted so far.
    var connectionCount: Int {
        lock.withLock { connections }
    }

    /// Stops listening: the accept loop closes the socket within 50 ms.
    func stop() {
        lock.withLock { stopped = true }
    }
}
