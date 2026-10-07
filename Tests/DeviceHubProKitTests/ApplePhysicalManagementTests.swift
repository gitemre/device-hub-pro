import XCTest
@testable import DeviceHubProKit

/// The four management commands of the physical right-click menu: `device reboot`, `device rename --name`, `device
/// sysdiagnose --destination` and `manage unpair`. None of them was ever run
/// on a device (a restart, a rename, a sysdiagnose and an unpair change the
/// phone), so their argv is HELP-DERIVED (Xcode 27.0 `devicectl
/// <command> -h`), and their success document is derived from a real capture:
/// `devicectl-simulate-location-clear.json` without its `result`, the shape
/// CoreDevice writes for a command that answers nothing. The failure is the
/// real `process sendMemoryWarning` capture (an error document). devicectl
/// itself is a fake tool: nothing here reaches a device.
final class ApplePhysicalManagementTests: XCTestCase {
    private static let id = ApplePhysicalDeviceTests.coreDeviceIdentifier

    private func makeClient(_ fake: FakeTool) throws -> DevicectlPhysicalClient {
        try DevicectlPhysicalClient(
            devicectlURL: fake.executableURL,
            device: try ApplePhysicalDeviceTests.device(),
            commandTimeout: .seconds(30)
        )
    }

    /// A success document without a `result`, derived from a real capture.
    private func resultlessSuccess() throws -> URL {
        let source = try ApplePhysicalDeviceTests.data("devicectl-simulate-location-clear.json")
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: source) as? [String: Any])
        document["result"] = nil
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("management-success-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: document).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func assertArgv(
        _ argv: [String], words: [String], seconds: Int = 30, tail: [String],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let count = words.count
        guard argv.count >= count + 7 else { return XCTFail("\(argv)", file: file, line: line) }
        XCTAssertEqual(Array(argv.prefix(count)), words, file: file, line: line)
        XCTAssertEqual(Array(argv[count...(count + 2)]), ["--device", Self.id, "--json-output"], file: file, line: line)
        XCTAssertEqual(Array(argv[(count + 4)...(count + 6)]), ["-q", "-t", String(seconds)], file: file, line: line)
        XCTAssertEqual(Array(argv.dropFirst(count + 7)), tail, file: file, line: line)
        ApplePhysicalDeviceTests.assertSafeArguments(argv, file: file, line: line)
    }

    func testEachManagementCommandRunsItsOneShape() async throws {
        let success = try resultlessSuccess()
        let fake = try FakeTool(name: "devicectl", rules: [
            .init("device reboot", jsonOutputFile: success),
            .init("device rename", jsonOutputFile: success),
            .init("manage unpair", jsonOutputFile: success),
        ])
        let client = try makeClient(fake)

        try await client.reboot()
        try await client.rename(to: "Test Phone")
        try await client.unpair()

        let calls = fake.invocations
        XCTAssertEqual(calls.count, 3)
        assertArgv(calls[0], words: ["device", "reboot"], tail: [])
        assertArgv(calls[1], words: ["device", "rename"], tail: ["--name", "Test Phone"])
        assertArgv(calls[2], words: ["manage", "unpair"], tail: [])
    }

    func testAnErrorDocumentIsAFailure() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [
            .init("device reboot", jsonOutputFile: ApplePhysicalDeviceTests.url("devicectl-process-sendMemoryWarning.json"), exitCode: 1),
        ])
        let client = try makeClient(fake)
        do {
            try await client.reboot()
            XCTFail("an error document must fail")
        } catch is DevicectlError {
        }
    }

    func testAResultlessDocumentThatDidNotSucceedIsAFailure() async throws {
        let source = try ApplePhysicalDeviceTests.data("devicectl-simulate-location-clear.json")
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: source) as? [String: Any])
        document["result"] = nil
        var info = try XCTUnwrap(document["info"] as? [String: Any])
        info["outcome"] = "failed"
        document["info"] = info
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("management-failed-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: document).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let fake = try FakeTool(name: "devicectl", rules: [.init("manage unpair", jsonOutputFile: url, exitCode: 1)])
        let client = try makeClient(fake)
        do {
            try await client.unpair()
            XCTFail("a failed outcome must fail")
        } catch is DevicectlJSON.DecodeError {
        }
    }

    /// Every other shape of the four commands, and every other `manage`
    /// word, is refused before devicectl runs.
    func testEveryOtherManagementShapeIsRefused() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [])
        let client = try makeClient(fake)
        let refused: [[String]] = [
            ["device", "reboot", "--style", "userspace"],
            ["device", "reboot", "--wait-for-device"],
            ["device", "rename"],
            ["device", "rename", "Phone"],
            ["device", "rename", "--name"],
            ["device", "rename", "--name", ""],
            ["device", "rename", "--name", "   "],
            ["device", "rename", "--name", "a\nb"],
            ["device", "rename", "--name", "a", "--extra"],
            ["device", "sysdiagnose"],
            ["device", "sysdiagnose", "--gather-full-logs"],
            ["device", "sysdiagnose", "--destination"],
            ["device", "sysdiagnose", "--destination", "-x"],
            ["device", "sysdiagnose", "--destination", "/tmp/a", "--dry-run-only"],
            ["manage", "unpair", "--columns", "*"],
            ["manage", "pair", "--columns", "*"],
            ["manage", "pair", "--device", "x"],
            ["manage", "ddis"],
            ["manage"],
            ["device", "manage", "unpair"],
            ["device", "unpair"],
        ]
        for command in refused {
            do {
                _ = try await client.run(command, as: DevicectlManagementResult.self)
                XCTFail("\(command) must be refused")
            } catch let error as DevicectlClientError {
                XCTAssertEqual(error, .refusedCommand(command.joined(separator: " ")), "\(command)")
            }
        }
        XCTAssertEqual(fake.calls, [], "devicectl never ran")
    }

    func testDeviceNamesMayHaveSpacesAndUnicode() {
        XCTAssertTrue(DevicectlPhysicalClient.isDeviceName("Tester’s iPhone"))
        XCTAssertFalse(DevicectlPhysicalClient.isDeviceName(String(repeating: "a", count: 256)))
    }

    // MARK: - manage pair (the Pair Nearby Device sheet)

    /// SOURCE-DERIVED from `devicectl-list-devices.json`: the test iPhone's
    /// entry with `pairingState` "unpaired" and `transportType`
    /// "localNetwork", the two values CoreDevice documents for a phone found
    /// over the network (`devicectl list devices -h` names neither; no
    /// unpaired device was on hand to capture).
    static func unpairedDevice() throws -> ApplePhysicalDevice {
        var text = try XCTUnwrap(String(data: try ApplePhysicalDeviceTests.data("devicectl-list-devices.json"), encoding: .utf8))
        text = text.replacingOccurrences(of: "\"pairingState\" : \"paired\"", with: "\"pairingState\" : \"unpaired\"")
        text = text.replacingOccurrences(of: "\"transportType\" : \"wired\"", with: "\"transportType\" : \"localNetwork\"")
        let devices = try ApplePhysicalDeviceLister.devices(
            fromListJSON: Data(text.utf8),
            optIn: try ApplePhysicalDeviceTests.optIn(ApplePhysicalDeviceTests.udid)
        )
        return try XCTUnwrap(devices.first)
    }

    func testAnUnpairedPhoneIsAPairCandidateAndAPairedOneIsNot() throws {
        let unpaired = try Self.unpairedDevice()
        XCTAssertFalse(unpaired.isPaired)
        XCTAssertEqual(unpaired.transport, "localNetwork")
        XCTAssertTrue(unpaired.isUnpairedPhone)
        XCTAssertFalse(try ApplePhysicalDeviceTests.device().isUnpairedPhone)
    }

    func testPairRunsItsOneShapeForAnUnpairedDevice() async throws {
        let success = try resultlessSuccess()
        let fake = try FakeTool(name: "devicectl", rules: [.init("manage pair", jsonOutputFile: success)])
        let client = try DevicectlPhysicalClient(
            devicectlURL: fake.executableURL,
            device: try Self.unpairedDevice(),
            commandTimeout: .seconds(30)
        )
        try await client.pair()
        XCTAssertEqual(fake.invocations.count, 1)
        assertArgv(fake.invocations[0], words: ["manage", "pair"], seconds: Int(DevicectlPhysicalClient.pairTimeout.components.seconds), tail: [])
    }

    func testPairIsRefusedForADeviceThatIsAlreadyPaired() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [])
        let client = try makeClient(fake)
        do {
            try await client.pair()
            XCTFail("a paired device is never paired again")
        } catch is DevicectlClientError {
        }
        XCTAssertEqual(fake.calls, [])
    }
}
