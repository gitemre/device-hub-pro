import CryptoKit
import XCTest
@testable import DeviceHubProKit

final class ScrcpyServerTests: XCTestCase {
    func testVendoredConstantsMatchThePinnedScrcpyRelease() {
        XCTAssertEqual(ScrcpyServer.version, "3.1")
        XCTAssertEqual(ScrcpyServer.devicePath, "/data/local/tmp/scrcpy-server")
        XCTAssertEqual(ScrcpyServer.socketName, "scrcpy")
        XCTAssertEqual(ScrcpyServer.mainClass, "com.genymobile.scrcpy.Server")
    }

    /// scrcpy 3.1 scopes the abstract socket to the session:
    /// `SC_SOCKET_NAME_PREFIX "scrcpy_"` + `%08x` (`app/src/server.c`).
    func testSessionIDsFormatAs8HexDigitsAndNameTheSessionSocket() {
        XCTAssertEqual(ScrcpyServer.sessionIDString(0), "00000000")
        XCTAssertEqual(ScrcpyServer.sessionIDString(0x1234_ABCD), "1234abcd")
        XCTAssertEqual(ScrcpyServer.socketName(for: 0x1234_ABCD), "scrcpy_1234abcd")
    }

    /// scrcpy parses `scid` as a non-negative 31-bit value (`Options.java`).
    func testRandomSessionIDsStayInThe31BitRange() {
        for _ in 0..<100 {
            XCTAssertLessThanOrEqual(ScrcpyServer.randomSessionID(), 0x7FFF_FFFF)
        }
    }

    func testPushArguments() {
        let serverURL = URL(fileURLWithPath: "/tmp/scrcpy-server")

        XCTAssertEqual(
            ScrcpyServer.pushArguments(serial: "R58M12345", serverURL: serverURL),
            [
                "-s", "R58M12345", "push",
                "/tmp/scrcpy-server",
                "/data/local/tmp/scrcpy-server",
            ]
        )
    }

    func testPushArgumentsHonorACustomDestination() {
        let serverURL = URL(fileURLWithPath: "/tmp/scrcpy-server")

        XCTAssertEqual(
            ScrcpyServer.pushArguments(
                serial: "R58M12345",
                serverURL: serverURL,
                destination: "/data/local/tmp/other-server"
            ),
            ["-s", "R58M12345", "push", "/tmp/scrcpy-server", "/data/local/tmp/other-server"]
        )
    }

    /// The shape scrcpy 3.1 itself runs (server.c `execute_server`): the class
    /// path is passed to `app_process` and every option is a `key=value` pair
    /// after the version, in the order the client emits them.
    func testLaunchArgumentsMatchTheScrcpyInvocationForDefaults() {
        XCTAssertEqual(
            ScrcpyServer.launchArguments(
                serial: "R58M12345",
                scid: 0x1234_ABCD,
                options: .init()
            ),
            [
                "-s", "R58M12345", "shell",
                "CLASSPATH=/data/local/tmp/scrcpy-server",
                "app_process",
                "/",
                "com.genymobile.scrcpy.Server",
                "3.1",
                "scid=1234abcd",
                "log_level=info",
                "audio=false",
                "tunnel_forward=true",
                "control=false",
            ]
        )
    }

    /// The scid is emitted before `log_level`, as in scrcpy 3.1's
    /// `execute_server` (`ADD_PARAM("scid=%08x", ...)` first).
    func testLaunchArgumentsEmitTheSessionIDRightAfterTheVersion() throws {
        let arguments = ScrcpyServer.launchArguments(
            serial: "R58M12345",
            scid: 0x0000_0001,
            options: .init()
        )

        let versionIndex = try XCTUnwrap(arguments.firstIndex(of: "3.1"))
        XCTAssertEqual(arguments[versionIndex + 1], "scid=00000001")
        XCTAssertEqual(arguments[versionIndex + 2], "log_level=info")
    }

    func testLaunchArgumentsIncludeTuningOptionsInTheScrcpyOrder() {
        let options = ScrcpyServer.Options(
            logLevel: "debug",
            videoBitRate: 4_000_000,
            maxSize: 1024,
            maxFPS: 30
        )

        XCTAssertEqual(
            ScrcpyServer.launchArguments(
                serial: "R58M12345",
                scid: 0x1234_ABCD,
                options: options
            ),
            [
                "-s", "R58M12345", "shell",
                "CLASSPATH=/data/local/tmp/scrcpy-server",
                "app_process",
                "/",
                "com.genymobile.scrcpy.Server",
                "3.1",
                "scid=1234abcd",
                "log_level=debug",
                "video_bit_rate=4000000",
                "audio=false",
                "max_size=1024",
                "max_fps=30",
                "tunnel_forward=true",
                "control=false",
            ]
        )
    }

    /// The production physical-mirror defaults the checklist measures
    /// against: native size (`max_size` absent), 60 fps cap and 8 Mbps, with
    /// the control socket carrying input (no `control=false`).
    func testPhysicalMirrorOptionsEmitTheTunedDefaults() {
        let arguments = ScrcpyServer.launchArguments(
            serial: "R58M12345",
            scid: 0x1234_ABCD,
            options: .physicalMirror
        )

        XCTAssertEqual(
            ScrcpyServer.Options.physicalMirror,
            ScrcpyServer.Options(videoBitRate: 8_000_000, maxFPS: 60, control: true)
        )
        XCTAssertFalse(
            arguments.contains { $0.hasPrefix("control=") },
            "the shipped path must keep scrcpy's control socket: \(arguments)"
        )
        XCTAssertTrue(
            arguments.contains("video_bit_rate=8000000"),
            "the shipped path must pin the bitrate: \(arguments)"
        )
        XCTAssertTrue(
            arguments.contains("max_fps=60"),
            "the shipped path must cap the frame rate: \(arguments)"
        )
        XCTAssertFalse(
            arguments.contains { $0.hasPrefix("max_size=") },
            "native size means no max_size override: \(arguments)"
        )
    }

    /// `tunnel_forward` is only sent when true; reverse mode is the server
    /// default and must not be named explicitly.
    func testLaunchArgumentsOmitTheTunnelFlagWhenReverseModeIsChosen() {
        let options = ScrcpyServer.Options(tunnelForward: false)
        let arguments = ScrcpyServer.launchArguments(
            serial: "R58M12345",
            scid: 0x1234_ABCD,
            options: options
        )

        XCTAssertFalse(arguments.contains("tunnel_forward=true"))
        XCTAssertFalse(arguments.contains { $0.hasPrefix("tunnel_forward") })
    }

    /// Likewise, `audio=false` and `control=false` are only sent when the
    /// feature is disabled (scrcpy's server defaults are true).
    func testLaunchArgumentsOmitDisabledFlagsWhenTheFeaturesAreEnabled() {
        let options = ScrcpyServer.Options(audio: true, control: true)
        let arguments = ScrcpyServer.launchArguments(
            serial: "R58M12345",
            scid: 0x1234_ABCD,
            options: options
        )

        XCTAssertFalse(arguments.contains("audio=false"))
        XCTAssertFalse(arguments.contains("control=false"))
    }

    /// Forward tunnelling: the client connects to an adb-forwarded local port;
    /// the server listens on the session's abstract socket
    /// `localabstract:scrcpy_<scid>`.
    func testForwardArgumentsTargetTheSessionAbstractSocket() {
        let socket = ScrcpyServer.socketName(for: 0x1234_ABCD)
        XCTAssertEqual(
            ScrcpyServer.forwardArguments(
                serial: "R58M12345",
                port: 27183,
                deviceSocket: socket
            ),
            ["-s", "R58M12345", "forward", "tcp:27183", "localabstract:scrcpy_1234abcd"]
        )
        XCTAssertEqual(
            ScrcpyServer.forwardArguments(
                serial: "R58M12345",
                port: 0,
                deviceSocket: socket
            ),
            ["-s", "R58M12345", "forward", "tcp:0", "localabstract:scrcpy_1234abcd"]
        )
    }

    func testRemoveForwardArguments() {
        XCTAssertEqual(
            ScrcpyServer.removeForwardArguments(serial: "R58M12345", port: 27183),
            ["-s", "R58M12345", "forward", "--remove", "tcp:27183"]
        )
    }

    /// The server unlinks its jar and lingers on its abstract socket if the
    /// client dies before connecting; killing by the session's `scid` can only
    /// reach this mirror session's server (the scid is part of its argv).
    func testStopArgumentsKillOnlyTheSessionsServerProcess() {
        XCTAssertEqual(
            ScrcpyServer.stopArguments(serial: "R58M12345", scid: 0x1234_ABCD),
            ["-s", "R58M12345", "shell", "pkill", "-f", "scid=1234abcd"]
        )
    }

    /// `forward --list` lines are `<serial> tcp:<port> localabstract:<socket>`;
    /// the parser returns only the session socket's ports for the serial.
    func testParseForwardPortsFromAListing() {
        let listing = """
        R58M12345 tcp:27183 localabstract:scrcpy_1234abcd
        emulator-5554 tcp:40001 localabstract:scrcpy_99999999
        R58M12345 tcp:27184 localabstract:scrcpy_1234abcd
        R58M12345 tcp:27185 localabstract:scrcpy
        R58M12345 tcp:99999 localabstract:scrcpy_1234abcd
        malformed line
        """

        XCTAssertEqual(
            ScrcpyServer.parseForwardPorts(
                fromList: listing,
                serial: "R58M12345",
                deviceSocket: "scrcpy_1234abcd"
            ),
            [27183, 27184]
        )
    }

    func testParseForwardPortsIgnoresNonTcpForwards() {
        let listing = "R58M12345 localabstract:scrcpy_1234abcd tcp:27183"

        XCTAssertEqual(
            ScrcpyServer.parseForwardPorts(
                fromList: listing,
                serial: "R58M12345",
                deviceSocket: "scrcpy_1234abcd"
            ),
            []
        )
    }

    func testParseForwardPort() {
        XCTAssertEqual(ScrcpyServer.parseForwardPort("27183\n"), 27183)
        XCTAssertEqual(ScrcpyServer.parseForwardPort("27183"), 27183)
        XCTAssertEqual(ScrcpyServer.parseForwardPort(" 65535 \r\n"), 65535)
    }

    func testParseForwardPortRejectsMalformedOutput() {
        XCTAssertNil(ScrcpyServer.parseForwardPort(""))
        XCTAssertNil(ScrcpyServer.parseForwardPort("adb: error: failed to allocate"))
        XCTAssertNil(ScrcpyServer.parseForwardPort("-1"))
        XCTAssertNil(ScrcpyServer.parseForwardPort("65536"))
        XCTAssertNil(ScrcpyServer.parseForwardPort("0"))
    }

    /// The bundled asset is the pinned v3.1 release, byte for byte: 90,640
    /// bytes of the Apache-2.0 `scrcpy-server-v3.1` GitHub release asset.
    func testBundledServerIsThePinnedAsset() throws {
        let url = try ScrcpyServer.bundledServerURL()
        let data = try Data(contentsOf: url)

        XCTAssertEqual(data.count, 90_640)
        XCTAssertEqual(data.prefix(2), Data([0x50, 0x4B]), "a zip/jar archive starts with PK")
        XCTAssertEqual(
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            "958f0944a62f23b1f33a16e9eb14844c1a04b882ca175a738c16d23cb22b86c0"
        )
    }

    func testBundledLicenseShipsWithTheServer() throws {
        let url = try ScrcpyServer.bundledServerURL()
            .deletingLastPathComponent()
            .appendingPathComponent("LICENSE.scrcpy")
        let text = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(text.contains("Apache License"))
        XCTAssertTrue(text.contains("Version 2.0"))
    }
}
