import Foundation
import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// The iOS captures under `DeviceHubProKitTests/Fixtures/ios27-simulator/`
/// (provenance in `SimctlFixtureTests` and `SimulatorLifecycleFixtureTests`),
/// replayed byte for byte by the stub tools below.
enum SimulatorFixtures {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("DeviceHubProKitTests/Fixtures/ios27-simulator", isDirectory: true)

    static func url(_ name: String, folder: String = "simctl-core") -> URL {
        root.appendingPathComponent(folder).appendingPathComponent(name)
    }

    /// `cat '<fixture>'`, for a stub's `case` arm.
    static func cat(_ name: String, folder: String = "simctl-core") -> String {
        "cat " + quoted(url(name, folder: folder).path)
    }

    /// Copies a screenshot capture to the destination simctl was given
    /// (the last argument of `io <UDID> screenshot --type=png <file>`).
    static func screenshot(_ name: String) -> String {
        "for last; do :; done; cp " + quoted(url(name).path) + " \"$last\""
    }

    /// `cat '<fixture>' >&2`.
    static func catToStderr(_ name: String, folder: String = "simctl-core") -> String {
        cat(name, folder: folder) + " >&2"
    }

    /// The devices of a listing capture, parsed as simctl's own answer.
    static func devices(_ name: String) throws -> [SimulatorDevice] {
        try SimctlParsing.devices(fromListJSON: Data(contentsOf: url(name)))
    }

    /// The first device of a listing capture as an entry, without catalogs.
    static func entry(_ name: String, udid: String) throws -> SimulatorEntry {
        let device = try XCTUnwrap(try devices(name).first { $0.udid == udid })
        return SimulatorEntry(device: device, runtimes: [], deviceTypes: [], defaultDeviceUDIDs: [])
    }

    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The private-set device of the lifecycle captures.
    static let udid = "425BD068-3D87-4F27-BE58-EB56A58B2C3A"
    /// Its clone.
    static let cloneUDID = "B225F7EA-C520-4579-BB1C-5A6E2BB622EC"
}

/// A stub command-line tool (simctl, devicectl): a POSIX sh script that logs
/// every argv (one line, `$*`) and answers with the test's `case` arms.
/// Each arm sees the whole argv joined by spaces, `--set <folder>` included,
/// so arms match on a suffix (`*" boot <UDID>"`). Unmatched calls fail.
struct StubTool {
    let url: URL
    let directory: URL
    let callsURL: URL

    /// Every call's argv, `--set <folder>` dropped, and a screenshot's
    /// temporary destination too (`io <UDID> screenshot --type=png`).
    var calls: [String] {
        let text = (try? String(contentsOf: callsURL, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map { line in
            var call = String(line)
            if call.hasPrefix("--set "), let space = call.dropFirst("--set ".count).firstIndex(of: " ") {
                call = String(call[call.index(after: space)...])
            }
            if let type = call.range(of: " screenshot --type=png ") {
                call = String(call[..<type.upperBound].dropLast())
            }
            return call
        }
    }

    /// Creates `name` in the stub's folder, for an arm that waits on it.
    func signal(_ name: String) {
        FileManager.default.createFile(atPath: directory.appendingPathComponent(name).path, contents: Data())
    }

    /// A path in the stub's folder, for arms.
    func path(_ name: String) -> String {
        directory.appendingPathComponent(name).path
    }
}

extension XCTestCase {
    /// Writes a stub `name` whose `case "$*" in` arms are `arms`.
    func makeStubTool(_ name: String, arms: String) throws -> StubTool {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimulatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let callsURL = directory.appendingPathComponent("calls.log")
        let url = directory.appendingPathComponent(name)
        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" >> \(SimulatorFixtures.quoted(callsURL.path))
        case "$*" in
        \(arms)
          *)
            exit 1 ;;
        esac
        exit 0
        """
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return StubTool(url: url, directory: directory, callsURL: callsURL)
    }

    /// A temporary folder standing in for a device set (or a logs folder),
    /// removed after the test.
    func makeTemporaryFolder(_ label: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimulatorTests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }
}

extension AppleTooling {
    /// Apple tooling on stub tools: a toolchain whose simctl (and devicectl,
    /// when given) are the stubs — overrides, so no version check and no
    /// Xcode — on a temporary device set and logs folder. Nothing reaches
    /// the user's simulators: the stubs answer every call, and the set, its
    /// `device_set.plist` and the logs folder are the test's own.
    static func stubbed(
        simctl: StubTool?,
        devicectl: StubTool? = nil,
        devicesDirectory: URL,
        logsDirectory: URL,
        privateSet: Bool = true
    ) -> AppleTooling {
        let toolchain = AppleToolchain(
            developerDirectory: nil,
            xcodeVersion: "27.0",
            xcodeBuild: "27A266a",
            firstLaunchComplete: true,
            simctl: simctl.map {
                .init(binary: $0.url, installedVersion: nil, expectedVersion: nil, needsFirstLaunch: false, isOverride: true)
            } ?? .missing,
            devicectl: devicectl.map {
                .init(binary: $0.url, installedVersion: nil, expectedVersion: nil, needsFirstLaunch: false, isOverride: true)
            } ?? .missing
        )
        return AppleTooling(
            probe: { toolchain },
            deviceSet: privateSet ? devicesDirectory : nil,
            devicesDirectory: devicesDirectory,
            logsDirectory: logsDirectory
        )
    }
}
