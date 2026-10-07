import ImageIO
import XCTest
@testable import DeviceHubProKit

/// Live checks against the dedicated test iPhone, behind two
/// switches (they skip unless both are set):
///
///     DHP_IOS_DEVICE_LIVE=1 DHP_IPHONE_UDID=<hardware UDID> \
///         swift test --filter ApplePhysicalLiveTests
///
/// Every test opts in with that one UDID only, and refuses to go on unless
/// the lister returns exactly that device as physical, paired and connected.
/// The UDID is read from the environment and is never printed.
///
/// `testTheTestIPhoneAnswersEveryReadOnlyInfoCall` runs the eight read-only
/// `devicectl device info` calls (`DevicectlPhysicalClient`) and checks that
/// they decode; it changes no state on the device.
///
/// `testTheVerifierRoundTripOnTheTestIPhone` is the round trip and
/// needs a third switch, `DHP_IOS_DEVICE_VERIFIER_APP=<path of a signed
/// DeviceHubProVerifier.app>` (built with `ios/verifier/build.sh --device`). It
/// installs the verifier, launches it, copies `Documents/readings.json` out
/// of its container and decodes it, terminates it by pid and takes a
/// screenshot. It leaves the phone as it found it: a verifier that was
/// installed before the test stays installed, otherwise it is uninstalled.
/// It never opens a URL (that would leave Safari in front), never records
/// the screen (the iPhone 12 on iOS 27 reports that unsupported) and runs no
/// other call.
final class ApplePhysicalLiveTests: XCTestCase {
    struct Connected {
        let device: ApplePhysicalDevice
        let client: DevicectlPhysicalClient
    }

    /// The test iPhone and a client for it, or a skip.
    static func connectedTestIPhone() async throws -> Connected {
        let environment = ProcessInfo.processInfo.environment
        guard environment["DHP_IOS_DEVICE_LIVE"] == "1" else {
            throw XCTSkip("physical-iPhone live tests run only with DHP_IOS_DEVICE_LIVE=1")
        }
        guard let udid = environment["DHP_IPHONE_UDID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !udid.isEmpty
        else {
            throw XCTSkip("set DHP_IPHONE_UDID to the test iPhone's hardware UDID")
        }
        let toolchain = await AppleToolchain.probe()
        guard let lister = toolchain.makePhysicalDeviceLister() else {
            throw XCTSkip("devicectl is not usable: \(toolchain.setupAdvice ?? "unknown")")
        }

        // Exactly the named device, physical, paired and connected: anything
        // else stops the run before a single call to the phone.
        let optIn = try XCTUnwrap(PhysicalDeviceOptIn(allowedHardwareUDIDs: [udid]))
        let devices = try await lister.list(optIn: optIn)
        XCTAssertEqual(devices.count, 1, "the lister must return exactly the named device")
        let device = try XCTUnwrap(devices.first)
        // A boolean check, so a failure never prints the UDID.
        XCTAssertTrue(device.hardwareUDID.uppercased() == udid.uppercased(), "the listed device is not the named one")
        try XCTSkipUnless(device.isPaired, "the test iPhone is not paired (state: \(device.pairingState ?? "unknown"))")
        try XCTSkipUnless(
            device.isConnected,
            "the test iPhone is not connected (tunnel: \(device.tunnelState ?? "unknown"))"
        )
        let client = try XCTUnwrap(try toolchain.makeDevicectlPhysicalClient(for: device))
        return Connected(device: device, client: client)
    }

    func testTheTestIPhoneAnswersEveryReadOnlyInfoCall() async throws {
        let connected = try await Self.connectedTestIPhone()
        let device = connected.device
        let client = connected.client

        let details = try await client.details().value
        XCTAssertEqual(details.identifier, device.coreDeviceIdentifier)
        XCTAssertEqual(details.reality, "physical")
        XCTAssertFalse(details.isSimulator)
        XCTAssertNotNil(details.osVersion)
        XCTAssertFalse(details.capabilities.isEmpty)

        let apps = try await client.apps().value
        XCTAssertEqual(apps.deviceIdentifier, device.coreDeviceIdentifier)
        let processes = try await client.processes().value
        XCTAssertFalse(processes.runningProcesses.isEmpty)
        let displays = try await client.displays().value
        XCTAssertFalse(displays.displays.isEmpty)
        let lock = try await client.lockState().value
        XCTAssertNotNil(lock.passcodeRequired)
        let appearance = try await client.appearance().value
        XCTAssertNotNil(appearance.userInterfaceStyle)
        let voiceover = try await client.voiceover().value
        XCTAssertEqual(voiceover.operation, "query")
        let ddi = try await client.ddiServices().value
        XCTAssertNotNil(ddi.ddiMetadata)
    }

    func testTheVerifierRoundTripOnTheTestIPhone() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let appPath = environment["DHP_IOS_DEVICE_VERIFIER_APP"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !appPath.isEmpty
        else {
            throw XCTSkip("set DHP_IOS_DEVICE_VERIFIER_APP to a signed DeviceHubProVerifier.app (ios/verifier/build.sh --device)")
        }
        let app = URL(fileURLWithPath: appPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: app.appendingPathComponent("embedded.mobileprovision").path) else {
            throw XCTSkip("\(appPath) is not a device build (no embedded.mobileprovision)")
        }
        let client = try await Self.connectedTestIPhone().client
        let bundle = IOSVerifierLiveTests.bundle

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("devicehubpro-physical-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let wasInstalled = try await client.apps().value.apps.contains { $0.bundleIdentifier == bundle }
        let started = Date()
        var pid: Int?
        var failure: Error?

        do {
            let installed = try await client.installApp(at: app).value
            XCTAssertEqual(installed.installedApplications.map(\.bundleID), [bundle])

            let listed = try await client.apps().value.apps.first { $0.bundleIdentifier == bundle }
            XCTAssertEqual(listed?.builtByDeveloper, true)
            XCTAssertEqual(listed?.containerAccessible, true, "copy from needs a development build")

            let launched = try await client.launchApp(bundleID: bundle, terminateExisting: true).value
            pid = launched.processIdentifier
            XCTAssertGreaterThan(launched.processIdentifier, 0)
            XCTAssertEqual(launched.launchOptions?.terminateExistingInstances, true)

            // The app writes Documents/readings.json a moment after it starts.
            let readingsFile = scratch.appendingPathComponent("readings.json")
            let document = try await Self.waitForReadings(
                client: client,
                bundle: bundle,
                into: readingsFile,
                launchedAfter: started.addingTimeInterval(-30)
            )
            XCTAssertEqual(document.schema, 1)
            XCTAssertTrue(document.system.hasPrefix("iOS "), "system: \(document.system)")
            XCTAssertFalse(document.rows.isEmpty)
            XCTAssertNotNil(document.rows["display.appearance"])
            let files = try await client.listFiles(domain: .appDataContainer(bundleID: bundle)).value
            XCTAssertTrue(files.files.contains { $0.relativePath == "Documents/readings.json" })

            let terminated = try await client.terminate(pid: launched.processIdentifier).value
            pid = nil
            XCTAssertEqual(terminated.process.processIdentifier, launched.processIdentifier)
            XCTAssertEqual(terminated.signal?.name, "SIGTERM")

            // A screenshot decodes as a PNG of the size devicectl reports.
            let shot = scratch.appendingPathComponent("phone.png")
            let taken = try await client.screenshot(to: shot).value
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(shot as CFURL, nil), "the screenshot is not an image")
            XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.png")
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, taken.width)
            XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, taken.height)
            XCTAssertGreaterThan(taken.width ?? 0, 500)
        } catch {
            failure = error
        }

        // Leave the phone as found, whatever happened above.
        if let pid {
            _ = try? await client.terminate(pid: pid)
        }
        if !wasInstalled {
            do {
                _ = try await client.uninstallApp(bundleID: bundle)
                let stillThere = try await client.apps().value.apps.contains { $0.bundleIdentifier == bundle }
                XCTAssertFalse(stillThere, "the verifier must be uninstalled again")
            } catch {
                XCTFail("could not uninstall the verifier again: \(error)")
            }
        }
        if let failure { throw failure }
    }

    /// Copies `Documents/readings.json` until it is a document the launch
    /// just wrote (its `launchedAt` is not older than `launchedAfter`).
    static func waitForReadings(
        client: DevicectlPhysicalClient,
        bundle: String,
        into destination: URL,
        launchedAfter: Date,
        timeout: Duration = .seconds(45)
    ) async throws -> VerifierReader.Document {
        struct Stamp: Decodable {
            let launchedAt: String
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let deadline = ContinuousClock.now + timeout
        var last = "no attempt"
        while ContinuousClock.now < deadline {
            do {
                _ = try await client.copyFrom(
                    domain: .appDataContainer(bundleID: bundle),
                    source: "Documents/readings.json",
                    to: destination
                )
                let data = try Data(contentsOf: destination)
                let stamp = try JSONDecoder().decode(Stamp.self, from: data)
                if let launched = formatter.date(from: stamp.launchedAt), launched >= launchedAfter {
                    return try JSONDecoder().decode(VerifierReader.Document.self, from: data)
                }
                last = "readings.json still from an older launch"
            } catch {
                last = "\(error)"
            }
            try await Task.sleep(for: .seconds(2))
        }
        throw PhysicalRoundTripError.noReadings(last)
    }
}

private enum PhysicalRoundTripError: Error, CustomStringConvertible {
    case noReadings(String)

    var description: String {
        switch self {
        case .noReadings(let last): return "the verifier's readings.json never arrived (last: \(last))"
        }
    }
}
