import XCTest
@testable import DeviceHubProKit

/// The argv follows `simctl help launch` on Xcode 27.0 (HELP-DERIVED):
/// `launch [-w | --wait-for-debugger] [--terminate-running-process]
/// <device> <app bundle identifier> [<argv 1> ... <argv n>]`, environment as
/// `SIMCTL_CHILD_` variables of the calling process.
final class SimulatorLaunchOptionsTests: XCTestCase {
    private static let udid = SimctlFixtureTests.udid

    func testCommandArgumentsPutFlagsFirstThenTheDeviceAndTheAppArguments() {
        let options = SimulatorLaunchOptions(
            arguments: ["-FIRDebugEnabled", "--flag", "two words"],
            waitForDebugger: true,
            terminateRunning: true
        )
        let command = options.commandArguments(udid: Self.udid, bundleIdentifier: "com.example.app")
        XCTAssertEqual(command.arguments, [
            "launch", "--wait-for-debugger", "--terminate-running-process", Self.udid, "com.example.app",
            "-FIRDebugEnabled", "--flag", "two words",
        ])
        XCTAssertEqual(command.freeText, [5, 6, 7])
    }

    func testPlainOptionsAddNoFlags() {
        let command = SimulatorLaunchOptions().commandArguments(udid: Self.udid, bundleIdentifier: "b.c")
        XCTAssertEqual(command.arguments, ["launch", Self.udid, "b.c"])
        XCTAssertTrue(command.freeText.isEmpty)
    }

    func testArgumentsAreOnePerLineWithBlankLinesDropped() {
        XCTAssertEqual(
            SimulatorLaunchOptions.parseArguments("-a\n\n  \n--b=c d\r\n-e"),
            ["-a", "--b=c d", "-e"]
        )
        XCTAssertEqual(SimulatorLaunchOptions.argumentsText(["x", "y"]), "x\ny")
    }

    func testStrayTabsAreTrimmedFromLineEnds() throws {
        XCTAssertEqual(SimulatorLaunchOptions.parseArguments("\t-a\t\n\t\n--b c"), ["-a", "--b c"])
        let variables = try SimulatorLaunchOptions.parseEnvironment("\tA=1\t\n\t\nB=2")
        XCTAssertEqual(variables.map(\.key), ["A", "B"])
        XCTAssertEqual(variables.map(\.value), ["1", "2"])
    }

    func testEnvironmentRowsSplitOnTheFirstEquals() throws {
        let variables = try SimulatorLaunchOptions.parseEnvironment("API_URL=https://x.test/?a=b\n\n EMPTY=\n_UNDER9=1")
        XCTAssertEqual(variables, [
            .init(key: "API_URL", value: "https://x.test/?a=b"),
            .init(key: "EMPTY", value: ""),
            .init(key: "_UNDER9", value: "1"),
        ])
        XCTAssertEqual(
            SimulatorLaunchOptions.environmentText(variables),
            "API_URL=https://x.test/?a=b\nEMPTY=\n_UNDER9=1"
        )
    }

    func testEnvironmentKeysAreValidated() {
        XCTAssertThrowsError(try SimulatorLaunchOptions.parseEnvironment("NOEQUALS")) {
            XCTAssertEqual($0 as? SimulatorLaunchOptions.Problem, .missingEquals(line: 1))
        }
        for bad in ["1A=x", "A-B=x", "=x", "A B=x", "\u{00C9}=x"] {
            XCTAssertThrowsError(try SimulatorLaunchOptions.parseEnvironment(bad), bad) {
                guard case .invalidKey? = $0 as? SimulatorLaunchOptions.Problem else { return XCTFail("\($0)") }
            }
        }
        XCTAssertThrowsError(try SimulatorLaunchOptions.parseEnvironment("A=1\nA=2")) {
            XCTAssertEqual($0 as? SimulatorLaunchOptions.Problem, .duplicateKey("A"))
        }
        XCTAssertNil(SimulatorLaunchOptions.validate(key: "Valid_1"))
    }

    func testEnvironmentIsPrefixedForSimctl() {
        let options = SimulatorLaunchOptions(environment: [.init(key: "TOKEN", value: "abc")])
        XCTAssertEqual(options.simctlEnvironment, ["SIMCTL_CHILD_TOKEN": "abc"])
    }

    func testOptionsRoundTripThroughJSON() throws {
        let options = SimulatorLaunchOptions(
            arguments: ["-x"], environment: [.init(key: "K", value: "v")], waitForDebugger: true, terminateRunning: false
        )
        let data = try JSONEncoder().encode(options)
        XCTAssertEqual(try JSONDecoder().decode(SimulatorLaunchOptions.self, from: data), options)
    }

    /// The client builds the argv above, with the app's arguments exempt from
    /// the selector refusal ("all" is an app argument here, not a selector).
    func testClientSendsTheArgvAndRefusesABadKey() async throws {
        let fake = try FakeTool(name: "simctl", rules: [
            .init("launch", stdoutFile: SimctlFixtureTests.url("simctl-core", "simctl-launch-mobilesafari.stdout.txt")),
        ])
        let client = SimctlClient(simctlURL: fake.executableURL)
        let pid = try await client.launch(
            udid: Self.udid,
            bundleIdentifier: "com.apple.mobilesafari",
            options: SimulatorLaunchOptions(
                arguments: ["all", "booted"],
                environment: [.init(key: "MODE", value: "test")],
                terminateRunning: true
            )
        )
        XCTAssertEqual(pid, 76487)
        XCTAssertEqual(
            fake.invocations.first { $0.first == "launch" },
            ["launch", "--terminate-running-process", Self.udid, "com.apple.mobilesafari", "all", "booted"]
        )
        do {
            _ = try await client.launch(
                udid: Self.udid,
                bundleIdentifier: "com.apple.mobilesafari",
                options: SimulatorLaunchOptions(environment: [.init(key: "BAD-KEY", value: "x")])
            )
            XCTFail("expected a refusal")
        } catch let problem as SimulatorLaunchOptions.Problem {
            XCTAssertEqual(problem, .invalidKey("BAD-KEY"))
        }
        XCTAssertEqual(fake.invocations.filter { $0.first == "launch" }.count, 1)
    }
}
