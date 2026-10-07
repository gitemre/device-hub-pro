import XCTest
@testable import DeviceHubProKit

/// "The result waits" against a real simulator, behind `DHP_IOS_LIVE=1`:
///
///     DHP_IOS_LIVE=1 swift test --filter BiometricWaitLiveTests
///
/// It creates its own simulator in a private set (deleted afterwards), boots
/// it, enrols Face ID and installs the verifier. A match is requested while
/// no prompt is up, and only then does the verifier start its Authenticate
/// (its launch argument `--authenticate-after`), so the verifier reading
/// "Succeeded" proves the request waited for the prompt and was delivered
/// when it appeared. devicectl cannot see a private set, so the match itself
/// is sent as the Darwin notification the simulator's biometric stack
/// listens to (`com.apple.BiometricKit_Sim.pearl.match`, the one Simulator's
/// Features menu used, measured on an iOS 27.0 simulator); the part under
/// test, the prompt signal and the waiting, is the production code.
final class BiometricWaitLiveTests: XCTestCase {
    static let bundle = IOSVerifierLiveTests.bundle

    func testAMatchRequestedBeforeThePromptIsDeliveredWhenItAppears() async throws {
        let toolchain = try await LiveTestSimulators.toolchain()
        let app = try await iosVerifierApp(toolchain: toolchain)
        let session = try LiveTestSimulators.Session(toolchain: toolchain)
        var reader: VerifierReader?
        do {
            let device = try await session.createDevice(name: "DeviceHubPro-Live-Biometric-Wait")
            let udid = device.udid
            let simctl = session.simctl
            let verifier = VerifierReader(simctl: simctl, udid: udid)
            reader = verifier
            try await simctl.bootStatus(udid: udid, bootIfNeeded: true)
            try await Task.sleep(for: .seconds(10))
            try await simctl.install(udid: udid, app: app)
            _ = try await simctl.launch(udid: udid, bundleIdentifier: Self.bundle, terminateRunning: true)
            _ = try await verifier.waitForDocument(timeout: .seconds(60))

            // Enrol Face ID the way the simulator's own menu did.
            try await simctl.checked([
                "spawn", udid, "notifyutil", "-s", "com.apple.BiometricKit.enrollmentChanged", "1",
                "-p", "com.apple.BiometricKit.enrollmentChanged",
            ])
            let enrolled = try await verifier.wait(for: "advanced.biometrics", bound: .seconds(10)) { $0.hasSuffix(":enrolled") }
            XCTAssertEqual(enrolled?.hasSuffix(":enrolled"), true, "Face ID did not enrol: \(enrolled ?? "no reading")")

            let signal = SimctlBiometricPromptSignal(simctl: simctl, udid: udid)
            let beforeUp = await signal.isPromptUp()
            XCTAssertEqual(beforeUp, false, "no prompt is up yet")

            // 1. Press Matching with no prompt: it waits.
            let sent = SendFlag()
            let request = Task {
                try await BiometricResultWaiter.deliver(signal: signal, timeout: .seconds(60)) {
                    try await simctl.checked(["spawn", udid, "notifyutil", "-p", "com.apple.BiometricKit_Sim.pearl.match"])
                    sent.set()
                }
            }
            try await Task.sleep(for: .seconds(3))
            XCTAssertFalse(sent.value, "nothing is sent while no prompt is up")

            // 2. The app asks for Face ID (its relaunch starts Authenticate after 2 s).
            _ = try await simctl.launch(
                udid: udid,
                bundleIdentifier: Self.bundle,
                options: SimulatorLaunchOptions(arguments: ["--authenticate-after", "2"], terminateRunning: true)
            )
            let outcome = try await request.value
            XCTAssertEqual(outcome, .deliveredAfterPrompt)

            // 3. The verifier reads the success.
            var value: String?
            let deadline = ContinuousClock.now + .seconds(10)
            while ContinuousClock.now < deadline {
                value = try await verifier.document()?.rows["advanced.biometrics"]?.value
                if value?.contains("Succeeded") == true { break }
                try await Task.sleep(for: .milliseconds(200))
            }
            if value?.contains("last match Succeeded") != true {
                throw VerifierReader.Failure.timedOut(
                    label: "biometric wait", id: "advanced.biometrics", expected: "last match Succeeded", last: value
                )
            }

            // The prompt is gone: the state read agrees, and no watcher is left running.
            try await Task.sleep(for: .seconds(2))
            let afterUp = await signal.isPromptUp()
            XCTAssertEqual(afterUp, false)
            let watchers = try await ProcessRunner.run(
                executable: URL(fileURLWithPath: "/usr/bin/pgrep"),
                arguments: ["-f", "spawn \(udid) log stream"],
                timeout: .seconds(10)
            )
            XCTAssertEqual(watchers.exitCode, 1, "a watcher outlived the request: \(watchers.standardOutputText)")
        } catch {
            await reader?.keepEvidence(name: "biometric-wait")
            let leftovers = await session.tearDown()
            XCTAssertTrue(leftovers.isEmpty, "left behind: \(leftovers)")
            throw error
        }
        let leftovers = await session.tearDown()
        XCTAssertTrue(leftovers.isEmpty, "left behind: \(leftovers)")
    }
}

private final class SendFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}
