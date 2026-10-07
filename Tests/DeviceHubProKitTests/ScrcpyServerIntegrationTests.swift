import XCTest
@testable import DeviceHubProKit

/// Launches the vendored scrcpy server on a real adb target (the emulator
/// stands in for a phone). Skipped when no device accepts it — the ATD image's
/// `app_process` aborts in ART startup, so the test tries each device and only
/// fails as a skip when none work.
final class ScrcpyServerIntegrationTests: XCTestCase {
    func testVendoredServerLaunchesAndAcceptsTheVideoSocket() async throws {
        guard let adb = AdbClient.locate() else {
            throw XCTSkip("adb not found")
        }
        let devices = LiveTestDevices.allowed(try await adb.listDevices())
        guard !devices.isEmpty else {
            throw XCTSkip("no online emulator (a phone runs this only when DHP_SCRCPY_SERIAL names it)")
        }

        var failures: [String] = []
        for device in devices {
            let launcher = ScrcpyServerLauncher(
                serial: device.serial,
                adb: adb,
                handshakeTimeout: .seconds(4)
            )
            do {
                let connection = try await launcher.start()
                // The launcher consumed the dummy byte; the first bytes on the
                // socket are the 64-byte device-name field followed by the
                // codec/size metadata. Reading one byte here would assert
                // nothing, so parse the handshake instead.
                let bytes = try Self.readHandshake(from: connection.videoHandle)
                await connection.stop()

                let header = try XCTUnwrap(
                    try ScrcpyFraming.parseHandshake(bytes),
                    "the handshake was truncated: \(bytes.count) of "
                        + "\(ScrcpyFraming.handshakeByteCount) bytes"
                )
                let nameField = bytes.prefix(ScrcpyFraming.deviceNameFieldSize)
                XCTAssertEqual(nameField.count, ScrcpyFraming.deviceNameFieldSize)
                XCTAssertTrue(
                    nameField.contains(0),
                    "the device-name field is NUL-terminated/padded"
                )
                XCTAssertFalse(header.deviceName.isEmpty, "the server must name the device")
                XCTAssertGreaterThan(header.width, 0)
                XCTAssertGreaterThan(header.height, 0)
                let forwards = try await adb.run(["-s", device.serial, "forward", "--list"])
                XCTAssertFalse(
                    forwards.contains("tcp:\(connection.port)"),
                    "stop() must remove the tunnel: \(forwards)"
                )
                print(
                    "scrcpy server accepted the video socket on \(device.serial) "
                        + "(port \(connection.port), name \"\(header.deviceName)\", "
                        + "\(header.width)x\(header.height))"
                )
                return
            } catch {
                failures.append("\(device.serial): \(error)")
            }
        }

        throw XCTSkip("no device accepted the scrcpy server: \(failures.joined(separator: "; "))")
    }

    /// Accumulates the handshake bytes: `FileHandle.read(upToCount:)` may
    /// return fewer bytes than requested, so a single read is not enough.
    private static func readHandshake(from handle: FileHandle) throws -> Data {
        var data = Data()
        while data.count < ScrcpyFraming.handshakeByteCount {
            guard let chunk = try handle.read(
                upToCount: ScrcpyFraming.handshakeByteCount - data.count
            ), !chunk.isEmpty else {
                break
            }
            data.append(chunk)
        }
        return data
    }
}
