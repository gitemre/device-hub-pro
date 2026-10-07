import XCTest
@testable import DeviceHubProKit

/// The tc shaping against a live emulator: a download through the shaped
/// path takes longer, measured on the host clock (the guest clock jumps).
///
/// Opt-in: `DHP_SHAPING_SERIAL=emulator-NNNN` names an emulator made
/// for the run (a google_apis, non-Play image: `adb root` must work). The
/// test boots nothing, never looks at other devices, and leaves the device
/// as found: rules cleared, and adbd unrooted when the test rooted it.
/// The guest reaches a loopback server of the host at 10.0.2.2.
final class ShapingLiveTests: XCTestCase {
    func testASlowSpeedAndALatencySlowADownload() async throws {
        guard let serial = ProcessInfo.processInfo.environment["DHP_SHAPING_SERIAL"],
              NetworkShaper.isSupportedSerial(serial)
        else { throw XCTSkip("DHP_SHAPING_SERIAL names no emulator") }
        guard let adb = AdbClient.locate() else { throw XCTSkip("adb not found") }
        let shaper = NetworkShaper(adb: adb)

        let reading = try await shaper.read(serial: serial)
        guard reading.debuggable == true else { throw XCTSkip("not a debuggable build: adb root is refused") }
        guard reading.routeInterface != nil else { throw XCTSkip("the emulator has no network route") }

        let payload = 128 * 1024
        let server = try LoopbackServer(payloadBytes: payload)
        addTeardownBlock { server.stop() }

        let outcome = try await shaper.ensureRoot(serial: serial)
        addTeardownBlock {
            try? await shaper.clear(serial: serial)
            if outcome == .restartedAsRoot { try? await shaper.dropRoot(serial: serial) }
        }

        func download() async throws -> (bytes: Int, seconds: Double) {
            let start = ContinuousClock.now
            let output = try await adb.shell(
                serial: serial,
                ["printf 'GET / HTTP/1.0\\r\\n\\r\\n' | nc 10.0.2.2 \(server.port) | wc -c"],
                timeout: .seconds(120)
            )
            let elapsed = ContinuousClock.now - start
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            return (Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1, seconds)
        }

        let baseline = try await download()
        XCTAssertGreaterThanOrEqual(baseline.bytes, payload, "the baseline download")

        // UMTS: 384 kbit/s down, so 128 KiB takes about 2.7 s.
        let umts = ShapingProfile(speed: .umts)
        let applied = try await shaper.apply(umts, serial: serial)
        XCTAssertTrue(applied.matches(umts), "the device reports what was asked: \(applied)")
        let slow = try await download()
        XCTAssertGreaterThanOrEqual(slow.bytes, payload)
        XCTAssertGreaterThan(slow.seconds, 2.0, "UMTS download took \(slow.seconds) s (baseline \(baseline.seconds) s)")
        XCTAssertGreaterThan(slow.seconds, baseline.seconds * 3)

        // 600 ms of round trip: the connect alone takes about that.
        let latent = ShapingProfile(latency: ConnectionLatency(minimumMs: 600, maximumMs: 600))
        _ = try await shaper.apply(latent, serial: serial)
        let delayed = try await download()
        XCTAssertGreaterThan(delayed.seconds, 1.0, "latency run took \(delayed.seconds) s (baseline \(baseline.seconds) s)")

        try await shaper.clear(serial: serial)
        let cleared = try await shaper.read(serial: serial)
        XCTAssertFalse(cleared.isShaping)
        let after = try await download()
        XCTAssertLessThan(after.seconds, slow.seconds / 2, "cleared download \(after.seconds) s")
    }
}

/// A one-shot HTTP-ish server on 127.0.0.1: every connection receives
/// `payloadBytes` of zeros after its first read, then closes.
private final class LoopbackServer: @unchecked Sendable {
    let port: UInt16
    private let descriptor: Int32
    private let payloadBytes: Int

    init(payloadBytes: Int) throws {
        self.payloadBytes = payloadBytes
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        self.descriptor = descriptor
        var yes: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(descriptor, 8) == 0 else { throw POSIXError(.EADDRINUSE) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        port = UInt16(bigEndian: address.sin_port)
        let listener = descriptor
        let size = payloadBytes
        DispatchQueue.global().async {
            while true {
                let client = accept(listener, nil, nil)
                if client < 0 { return }
                var request = [UInt8](repeating: 0, count: 512)
                _ = read(client, &request, request.count)
                let chunk = [UInt8](repeating: 0, count: 16 * 1024)
                var sent = 0
                while sent < size {
                    let count = min(chunk.count, size - sent)
                    let written = chunk.withUnsafeBytes { write(client, $0.baseAddress, count) }
                    if written <= 0 { break }
                    sent += written
                }
                close(client)
            }
        }
    }

    func stop() {
        close(descriptor)
    }
}
